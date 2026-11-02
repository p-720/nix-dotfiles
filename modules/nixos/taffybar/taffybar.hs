{-# LANGUAGE OverloadedStrings #-}

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (MVar, modifyMVar_, newMVar, readMVar, swapMVar, withMVar)
import Control.Concurrent.STM (atomically, newBroadcastTChanIO, writeTChan)
import Control.Concurrent.STM.TChan (TChan)
import Control.Exception (finally)
import Control.Exception.Enclosed (catchAny)
import Control.Monad (foldM, forM_, forever, unless, void, when)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Reader (ask)
import Data.GI.Base (unsafeCastTo)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.List (stripPrefix)
import Data.Time.Clock.POSIX (getPOSIXTime)
import qualified Data.Map.Strict as M
import GHC.IO.Encoding (setLocaleEncoding)
import GHC.Int (Int32)
import Data.Unique (Unique, newUnique)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import qualified GI.Gdk as Gdk
import qualified GI.Gdk.Structs.EventButton as GdkButton
import qualified GI.Gdk.Structs.EventMotion as GdkMotion
import qualified GI.Gdk.Structs.EventScroll as GdkScroll
import qualified GI.Gdk.Structs.Rectangle as GdkRectangle
import qualified GI.Gtk as Gtk
import qualified StatusNotifier.Tray as Tray
import System.Exit (ExitCode (..))
import System.IO (hClose, hFlush, hIsEOF, hPutStr, hSetEncoding, stdout, utf8)
import System.IO.Unsafe (unsafePerformIO)
import System.Posix.Process (exitImmediately)
import System.Posix.Signals (Handler (Catch), installHandler, sigTERM, signalProcessGroup)
import System.Process
import System.Taffybar (dyreTaffybar, getTaffyFile)
import System.Taffybar.Context (Context (..), TaffyIO)
import System.Taffybar.Information.Audio (AudioInfo (..), defaultAudioPulseSink, defaultAudioWirePlumberNode, getAudioInfoChanAndVar)
import System.Taffybar.Information.WirePlumber
  ( WirePlumberInfo (..),
    adjustWirePlumberVolume,
    getWirePlumberInfoChanAndVar,
    setWirePlumberVolume,
    toggleWirePlumberMute,
  )
import System.Taffybar.Information.EWMHDesktopInfo (getWorkspaceNames, switchOneWorkspace, withX11Context)
import System.Taffybar.Information.Memory (MemoryInfo (..), parseMeminfo)
import System.Taffybar.Information.X11DesktopInfo (DisplayName (..))
import System.Taffybar.SimpleConfig
import System.Taffybar.Util (getPixbufFromFilePath, postGUIASync)
import System.Taffybar.Widget
import System.Taffybar.Information.Workspaces.Model (WindowInfo(..), WorkspaceInfo(..), WorkspaceIdentity(..))
import System.Taffybar.Widget.Workspaces (WindowIconPixbufGetter, defaultGetWindowIconPixbuf, scaledWindowIconPixbufGetter)
import System.Taffybar.Widget.Audio (audioNewWith, defaultAudioWidgetConfig)
import System.Taffybar.Widget.Generic.ChannelWidget (channelWidgetNew)
import System.Taffybar.Widget.Generic.PollingLabel (pollingLabelNew)
import System.Taffybar.Widget.WttrIn (textWttrNew)
import Text.Printf (printf)
import Text.Read (readMaybe)

main :: IO ()
main = do
  setLocaleEncoding utf8
  installTerminationHandler
  -- The library adds taffybar.css at FALLBACK priority (800), where the
  -- system GTK theme wins every cascade conflict; its trough min-heights
  -- squash the slider fills to 2px. Load the same file again at SCHEMA
  -- priority (100) so our CSS is authoritative, as the file intends.
  Gtk.init Nothing
  cssPath <- getTaffyFile "taffybar.css"
  provider <- Gtk.cssProviderNew
  Gtk.cssProviderLoadFromPath provider (T.pack cssPath)
  Just scr <- Gdk.screenGetDefault
  Gtk.styleContextAddProviderForScreen scr provider 100
  dyreTaffybar
    ( toTaffybarConfigPerMonitor baseBarConfig $ \monitorIndex -> do
        primary <- isPrimaryMonitor monitorIndex
        pure $
          SimpleMonitorConfig
            (if primary then "primary" else "secondary")
            (if primary then primaryBarConfig else secondaryBarConfig)
    )
    `finally` terminateAllProcesses

baseBarConfig :: SimpleTaffyConfig
baseBarConfig =
  defaultSimpleTaffyConfig
    { barHeight = ExactSize 30,
      barPadding = 0,
      barPosition = Bottom,
      widgetSpacing = 8,
      monitorsAction = useAllMonitors,
      startupHook = attachBarScroll
    }

primaryBarConfig :: SimpleTaffyConfig
primaryBarConfig =
  baseBarConfig
    { barCssClasses = ["primary"],
      startWidgets = [workspacesWidget Nothing, inhibitorWidget, memoryWidget],
      centerWidgets = [gcalWidget, clockWidget],
      endWidgets = [audioSliderWidget, micSliderWidget, weatherWidget, polypomoWidget, pomotaskWidget]
    }

secondaryBarConfig :: SimpleTaffyConfig
secondaryBarConfig =
  baseBarConfig
    { barCssClasses = ["secondary"],
      startWidgets = [workspacesWidget (Just (\ws -> maybe False (\n -> n >= 6 && n < 12) (workspaceNumericId (workspaceIdentity ws)))), inhibitorWidget, memoryWidget, diskWidget, pomotaskWidget],
      centerWidgets = [gcalWidget, clockWidget],
      endWidgets = [trayWidget, audioSliderWidget, micSliderWidget]
    }

isPrimaryMonitor :: Int -> TaffyIO Bool
isPrimaryMonitor monitorIndex = liftIO $ do
  maybeDisplay <- Gdk.displayGetDefault
  case maybeDisplay of
    Nothing -> pure (monitorIndex == 0)
    Just display -> do
      maybePrimary <- Gdk.displayGetPrimaryMonitor display
      maybeMonitor <- Gdk.displayGetMonitor display (fromIntegral monitorIndex)
      pure $ case (maybePrimary, maybeMonitor) of
        (Just primary, Just monitor) -> primary == monitor
        _ -> monitorIndex == 0

-- Browsers advertise the *browser* icon for every tab, so resolve the page
-- favicon from Firefox's own places/favicons dbs (see ff-favicon.py).

{-# NOINLINE faviconPaths #-}
faviconPaths :: MVar (M.Map T.Text (Maybe FilePath))
faviconPaths = unsafePerformIO (newMVar M.empty)

faviconHelper :: FilePath
faviconHelper = "/etc/nixos/configs/taffybar/ff-favicon.py"

-- Window titles change with every tab, so the cache is a plain bounded map:
-- dropping it wholesale is cheaper than tracking recency for a bar widget.
faviconPathFor :: T.Text -> IO (Maybe FilePath)
faviconPathFor title = do
  cache <- readMVar faviconPaths
  case M.lookup title cache of
    Just hit -> pure hit
    Nothing -> do
      found <- query
      modifyMVar_ faviconPaths $ \m ->
        let m' = M.insert title found m
        in pure (if M.size m' > 400 then M.empty else m')
      pure found
  where
    query = do
      (code, out, _) <- readProcessWithExitCode "python3" [faviconHelper, T.unpack title] ""
      let path = T.strip (T.pack out)
      pure $ if code == ExitSuccess && not (T.null path)
        then Just (T.unpack path)
        else Nothing

isBrowserWindow :: WindowInfo -> Bool
isBrowserWindow win = any browserClass (windowClassHints win)
  where
    browserClass hint =
      let h = T.toLower hint
      in "firefox" `T.isInfixOf` h || "navigator" `T.isInfixOf` h

faviconWindowIcon :: WindowIconPixbufGetter
faviconWindowIcon = scaledWindowIconPixbufGetter unscaled
  where
    unscaled size win
      | not (isBrowserWindow win) = defaultGetWindowIconPixbuf size win
      | otherwise = do
          mpath <- liftIO $ faviconPathFor (windowTitle win)
          case mpath of
            Nothing -> defaultGetWindowIconPixbuf size win
            Just path -> do
              mpix <- liftIO $ getPixbufFromFilePath path
              maybe (defaultGetWindowIconPixbuf size win) (pure . Just) mpix

workspacesWidget :: Maybe (WorkspaceInfo -> Bool) -> TaffyIO Gtk.Widget
workspacesWidget visibleOverride = do
  visible <- case visibleOverride of
    Just f -> pure f
    Nothing -> do
      monitors <- liftIO $ do
        maybeDisplay <- Gdk.displayGetDefault
        maybe (pure 1) Gdk.displayGetNMonitors maybeDisplay
      pure $ if monitors > 1
        then \ws -> maybe False (< 6) (workspaceNumericId (workspaceIdentity ws))
        else \ws -> maybe False (< 12) (workspaceNumericId (workspaceIdentity ws))
  widget <-
    workspacesNew
      defaultWorkspacesConfig
        { showWorkspaceFn = visible,
          urgentWorkspaceState = True,
          iconSize = Just 18,
          maxIcons = Just 4,
          widgetGap = 4,
          getWindowIconPixbuf = faviconWindowIcon
        }
  -- the icon strip can outgrow its allocation while app icons load; the
  -- margin keeps the next module out of the overflow instead of under it
  liftIO $ do
    Gtk.widgetSetMarginEnd widget 16
    addWorkspaceScroll widget
  pure widget

inhibitorWidget :: TaffyIO Gtk.Widget
inhibitorWidget = do
  box <- liftIO Gtk.eventBoxNew
  _ <- widgetSetClassGI box "module"
  _ <- widgetSetClassGI box "idle_inhibitor"
  liftIO $ addWorkspaceScroll box
  label <- liftIO $ Gtk.labelNew (Just (T.pack "\xF070"))
  inner <- liftIO $ padded label
  liftIO $ do
    Gtk.containerAdd box inner
    -- single fixed-size glyph: reserve the waybar block so the eye is centred
    -- instead of squeezed into the label's own width
    Gtk.widgetSetSizeRequest box 40 (-1)
    _ <- addClassIfMissing "idle-inhibitor-inactive" box
    Gtk.widgetShowAll box
  stateVar <- liftIO $ newMVar Nothing
  _ <- liftIO $
    Gtk.onWidgetButtonPressEvent box $ \event ->
      catchAny
        ( do
            button <- GdkButton.getEventButtonButton event
            when (button == 1) $
              modifyMVar_ stateVar $ \current ->
                case current of
                  Nothing -> do
                    (_, _, _, processHandle) <-
                      createProcess
                        ( proc
                            "/run/current-system/sw/bin/systemd-inhibit"
                            [ "--what=idle",
                              "--who=taffybar",
                              "--why=Idle inhibitor toggled from the bar",
                              "--mode=block",
                              "sleep",
                              "infinity"
                            ]
                        )
                          { create_group = True
                          }
                    key <- registerProcess processHandle
                    postGUIASync $ do
                      Gtk.labelSetText label (T.pack "\xF06E")
                      _ <- addClassIfMissing "idle-inhibitor-active" box
                      removeClassIfPresent "idle-inhibitor-inactive" box
                      Gtk.widgetQueueResize box
                    pure (Just (key, processHandle))
                  Just (key, processHandle) -> do
                    catchAny
                      (killProcessGroup processHandle >> void (waitForProcess processHandle))
                      (\_ -> pure ())
                    forgetProcess key
                    postGUIASync $ do
                      Gtk.labelSetText label (T.pack "\xF070")
                      _ <- addClassIfMissing "idle-inhibitor-inactive" box
                      removeClassIfPresent "idle-inhibitor-active" box
                      Gtk.widgetQueueResize box
                    pure Nothing
            pure True
        )
        (\_ -> pure True)
  Gtk.toWidget box

memoryWidget :: TaffyIO Gtk.Widget
memoryWidget = do
  widget <-
    pollingLabelNew 2 $ do
      info <- parseMeminfo
      let gib :: Double -> String
          gib value = printf "%.1f" (value / 1024)
      pure $
        T.pack $
          printf
            "\xF035B %s/%s \xF04E2 %s/%s"
            (gib (memoryUsed info))
            (gib (memoryTotal info))
            (gib (memorySwapUsed info))
            (gib (memorySwapTotal info))
  moduleWrap "memory" widget

diskWidget :: TaffyIO Gtk.Widget
diskWidget =
  diskUsageLabelNewWith
    defaultDiskUsageWidgetConfig
      { diskUsageFormat = "\xF0C7 $usedPercent$%"
      }
    >>= moduleWrap "disk"

audioWidget :: TaffyIO Gtk.Widget
audioWidget = do
  widget <- audioNewWith defaultAudioWidgetConfig >>= moduleWrap "pulseaudio"
  (chan, stateVar) <- getAudioInfoChanAndVar defaultAudioPulseSink defaultAudioWirePlumberNode
  let updateMuted maybeInfo = postGUIASync $
        case maybeInfo >>= audioMuted of
          Just True -> addClassIfMissing "muted" widget
          _ -> removeClassIfPresent "muted" widget
  liftIO $ readMVar stateVar >>= updateMuted
  _ <- channelWidgetNew widget chan updateMuted
  pure widget

-- Waybar-style volume slider: drag to set, scroll to step, left-click sets
-- the volume at the pointer position, right-click toggles mute. Built on the
-- WirePlumber node channel because the unified AudioInfo only models the
-- default sink, so the mic needs its own source node (@DEFAULT_AUDIO_SOURCE@)
-- anyway.
--
-- The info source's third component is a `refresh` action: the sink is
-- event-driven (no-op), the mic is poll-fed, so after every local change we
-- read the value back and push it — otherwise our own scrolls would show up
-- up to a poll interval late.
data SliderDrag
  = DragIdle
  | SliderDragging
    { dragStartX :: Double,
      dragMoved :: Bool
    }

-- The mic is fed by a wpctl poll loop, not a second WpCore: libwireplumber
-- segfaults when a process opens a second WpCore (journal crashloop:
-- wp_core_new -> strlen on a bad pointer). One core per process; wpctl is
-- already how the slider's own actions set values.
wirePlumberInfoSource :: TaffyIO (TChan (Maybe WirePlumberInfo), MVar (Maybe WirePlumberInfo), IO ())
wirePlumberInfoSource = do
  (chan, var) <- getWirePlumberInfoChanAndVar "@DEFAULT_AUDIO_SINK@"
  pure (chan, var, pure ())

micInfoSource :: TaffyIO (TChan (Maybe WirePlumberInfo), MVar (Maybe WirePlumberInfo), IO ())
micInfoSource = liftIO $ do
  chan <- newBroadcastTChanIO
  var <- newMVar (Nothing :: Maybe WirePlumberInfo)
  let readBack = readWpctlVolume "@DEFAULT_AUDIO_SOURCE@" chan var
  forkIO (pollWpctlVolume "@DEFAULT_AUDIO_SOURCE@" chan var)
  pure (chan, var, readBack)

readWpctlVolume :: String -> TChan (Maybe WirePlumberInfo) -> MVar (Maybe WirePlumberInfo) -> IO ()
readWpctlVolume nodeSpec chan var = do
  (ecode, out, _) <- readProcessWithExitCode "wpctl" ["get-volume", nodeSpec] ""
  when (ecode == ExitSuccess) $
    case parseWpctlVolume out of
      Nothing -> pure ()
      Just (vol, muted) -> do
        let info = Just (WirePlumberInfo vol muted (T.pack nodeSpec))
        old <- swapMVar var info
        when (old /= info) $ atomically (writeTChan chan info)

pollWpctlVolume :: String -> TChan (Maybe WirePlumberInfo) -> MVar (Maybe WirePlumberInfo) -> IO ()
pollWpctlVolume nodeSpec chan var = forever $ do
  readWpctlVolume nodeSpec chan var
  threadDelay 250_000

-- wpctl get-volume output: "Volume: 0.94" or "Volume: 0.94 [MUTED]"
parseWpctlVolume :: String -> Maybe (Double, Bool)
parseWpctlVolume s =
  case stripPrefix "Volume: " s of
    Nothing -> Nothing
    Just rest -> do
      let (numStr, suffix) = span (/= ' ') (dropWhile (== ' ') rest)
      vol <- readMaybe numStr :: Maybe Double
      pure (vol, "[MUTED]" `elem` words suffix)

-- iconOn/iconOff are Nerd-Font (FontAwesome) glyph codepoints shown next to
-- the trough; the off glyph appears while muted.
volumeSlider :: T.Text -> TaffyIO (TChan (Maybe WirePlumberInfo), MVar (Maybe WirePlumberInfo), IO ()) -> String -> T.Text -> Char -> Char -> TaffyIO Gtk.Widget
volumeSlider klass infoSource nodeSpec title iconOn iconOff = do
  (chan, stateVar, refresh) <- infoSource
  box <- liftIO Gtk.eventBoxNew
  _ <- widgetSetClassGI box "module"
  _ <- widgetSetClassGI box klass
  inner <- liftIO $ Gtk.boxNew Gtk.OrientationHorizontal 6
  iconLabel <- liftIO $ Gtk.labelNew (Just (T.singleton iconOn))
  pctLabel <- liftIO $ Gtk.labelNew (Just T.empty)
  progress <- liftIO Gtk.progressBarNew
  dragRef <- liftIO (newIORef DragIdle)
  lastSetRef <- liftIO (newIORef (0 :: Double))
  alignment <- liftIO $ do
    a <- Gtk.alignmentNew 0.5 0.5 0 0
    -- 7px of vertical padding keeps the 16px trough centred in the 30px bar
    Gtk.alignmentSetPadding a 0 0 7 7
    pure a
  -- the event x is in the toplevel bar window's coordinate space (the event
  -- box is windowless), so a module-local offset misses every module to the
  -- left of the slider. Work in root coordinates instead: the trough's root
  -- x is the toplevel window's origin plus the allocation.x summed up the
  -- parent chain, and the click's root x needs no translation at all
  -- walkUp sums allocation.x from a widget up to (and including) the
  -- toplevel; the toplevel's own x is 0 so it adds nothing. Concrete
  -- Gtk.Widget (not a class constraint): widgetGetParent returns the
  -- Widget newtype, so a polymorphic helper would be pinned to it.
  let walkUp w acc = do
            r <- Gtk.widgetGetAllocation w
            x <- GdkRectangle.getRectangleX r
            p <- Gtk.widgetGetParent w
            case p of
              Nothing -> pure (acc + fromIntegral x)
              Just p' -> walkUp p' (acc + fromIntegral x)
      setFromX :: Double -> IO ()
      setFromX rootX = do
        rProg <- Gtk.widgetGetAllocation progress
        xProg <- GdkRectangle.getRectangleX rProg
        pProg <- Gtk.widgetGetParent progress
        offTop <- case pProg of
          Nothing -> pure (fromIntegral xProg)
          Just w0 -> walkUp w0 (fromIntegral xProg)
        top <- Gtk.widgetGetToplevel progress
        topWin <- Gtk.widgetGetWindow top
        widthRaw <- GdkRectangle.getRectangleWidth rProg
        case topWin of
          Nothing -> pure ()
          Just win -> do
            (ox, _, _) <- Gdk.windowGetOrigin win
            -- +18 render offset: the trough paints ~18px left of where the
            -- allocation sum puts it (a click at the visual centre read 28%,
            -- not 50%), so shift the mapping right to land the fill under the
            -- cursor. Calibrated from a centre click; one number, nudge if off.
            let width = fromIntegral widthRaw :: Double
                troughX = (fromIntegral ox + fromIntegral offTop) :: Double
                renderOff = 18.0
                pct = round (min 1 (max 0 ((rootX + renderOff - troughX) / max width 1)) * 100)
            void $ setWirePlumberVolume nodeSpec pct
      -- one wpctl per motion event would flood PipeWire; ~20/s is plenty
      -- (POSIX time, not a monotonic clock: NTP steps don't matter for a throttle)
      throttled action = do
        posixNow <- getPOSIXTime
        let now = realToFrac posixNow :: Double
        last <- readIORef lastSetRef
        if now - last > 0.05
          then do
            writeIORef lastSetRef now
            action
          else pure ()
  liftIO $ do
    Gtk.progressBarSetInverted progress False
    -- waybar slider dimensions: 80x10 trough (see taffybar.css)
    Gtk.widgetSetSizeRequest progress 80 16
    Gtk.containerAdd alignment progress
    Gtk.boxPackStart inner iconLabel False False 0
    Gtk.boxPackStart inner alignment False False 0
    Gtk.boxPackStart inner pctLabel False False 0
    Gtk.containerAdd box inner
    Gtk.widgetShowAll box
    Gtk.widgetAddEvents box
      [ Gdk.EventMaskScrollMask
      , Gdk.EventMaskButtonPressMask
      , Gdk.EventMaskButtonReleaseMask
      , Gdk.EventMaskPointerMotionMask
      ]
  let update info = postGUIASync $
        case info of
          Nothing -> do
            Gtk.progressBarSetFraction progress 0
            Gtk.labelSetText pctLabel T.empty
          Just i -> do
            let v = round (wirePlumberVolume i * 100)
                muted = wirePlumberMuted i
            Gtk.progressBarSetFraction progress (min 1 $ max 0 (fromIntegral v / 100.0))
            Gtk.labelSetText pctLabel (T.pack (show v ++ "%"))
            Gtk.labelSetText iconLabel (T.singleton (if muted then iconOff else iconOn))
            let tip =
                  title
                    <> T.pack (" " ++ show v ++ "%")
                    <> if muted then T.pack " (muted)" else (T.empty :: T.Text)
            Gtk.widgetSetTooltipText box (Just tip)
            if muted
              then addClassIfMissing "muted" box
              else removeClassIfPresent "muted" box
  liftIO $ readMVar stateVar >>= update
  _ <- channelWidgetNew box chan update
  -- scroll steps the volume; returning True keeps the bar's workspace-scroll
  -- handler on the top-level window from also firing
  _ <- liftIO $
    Gtk.onWidgetScrollEvent box $ \event -> do
      direction <- GdkScroll.getEventScrollDirection event
      case direction of
        Gdk.ScrollDirectionUp -> void (adjustWirePlumberVolume nodeSpec 2) >> forkIO refresh >> pure True
        Gdk.ScrollDirectionDown -> void (adjustWirePlumberVolume nodeSpec (-2)) >> forkIO refresh >> pure True
        _ -> pure False
  -- dragging across the module sets the volume from the pointer position
  _ <- liftIO $
    Gtk.onWidgetMotionNotifyEvent box $ \event -> do
      st <- readIORef dragRef
      x <- GdkMotion.getEventMotionXRoot event
      case st of
        SliderDragging _ True -> do
          throttled (setFromX x >> void (forkIO refresh))
          pure True
        SliderDragging sx _ | abs (x - sx) > 3 -> do
          writeIORef dragRef (SliderDragging sx True)
          throttled (setFromX x >> void (forkIO refresh))
          pure True
        _ -> pure False
  -- right-click mutes on press, so it doesn't wait for the release
  _ <- liftIO $
    Gtk.onWidgetButtonPressEvent box $ \event -> do
      button <- GdkButton.getEventButtonButton event
      case button of
        1 -> do
          x <- GdkButton.getEventButtonXRoot event
          writeIORef dragRef (SliderDragging x False)
          pure True
        3 -> void (toggleWirePlumberMute nodeSpec) >> forkIO refresh >> pure True
        _ -> pure False
  -- a left-click without movement sets the volume at the pointer position
  _ <- liftIO $
    Gtk.onWidgetButtonReleaseEvent box $ \event -> do
      button <- GdkButton.getEventButtonButton event
      if button == 1
        then do
          st <- readIORef dragRef
          writeIORef dragRef DragIdle
          x <- GdkButton.getEventButtonXRoot event
          case st of
            SliderDragging _ False -> setFromX x >> void (forkIO refresh)
            _ -> pure ()
          pure True
        else pure False
  liftIO $ Gtk.toWidget box

-- Glyphs (FontAwesome set, present in Nerd Fonts): f028 volume-up,
-- f6a9 volume-mute, f130 mic, f131 mic-mute.
audioSliderWidget :: TaffyIO Gtk.Widget
audioSliderWidget = volumeSlider "volume-slider" wirePlumberInfoSource "@DEFAULT_AUDIO_SINK@" "Volume" '\xf028' '\xf6a9'

micSliderWidget :: TaffyIO Gtk.Widget
micSliderWidget = volumeSlider "mic-slider" micInfoSource "@DEFAULT_AUDIO_SOURCE@" "Microphone" '\xf130' '\xf131'

clockWidget :: TaffyIO Gtk.Widget
clockWidget =
  textClockNewWith
    defaultClockConfig
      { clockFormatString = "%a, %d %b %H:%M"
      }
    >>= moduleWrap "clock"

gcalWidget :: TaffyIO Gtk.Widget
gcalWidget =
  commandRunnerNew
    300
    "bash"
    ["-c", "/etc/nixos/configs/waybar/taffybar_gcal.sh"]
    "No current event"
    >>= moduleWrap "gcal"

weatherWidget :: TaffyIO Gtk.Widget
weatherWidget =
  textWttrNew "https://wttr.in/Moscow?format=%c%t%20(%f)" 600
    >>= moduleWrap "weather"

pomotaskWidget :: TaffyIO Gtk.Widget
pomotaskWidget =
  streamingCommand
    "pomotask"
    -- setpriv pdeathsig: pkill taffybar reparents children instead of reaping
    -- them, so a plain child leaks a timer process on every bar restart
    "exec setpriv --pdeathsig TERM /etc/nixos/configs/waybar/polybar-pomotask.py"
    [(1, "/etc/nixos/configs/waybar/polybar-pomotask.py --stop")]
    Nothing

polypomoWidget :: TaffyIO Gtk.Widget
polypomoWidget =
  streamingCommand
    "polypomo"
    "exec setpriv --pdeathsig TERM /home/andrew/.config/polybar/polypomo --saveto /etc/nixos/configs/polybar/time.sqlite"
    [ (1, "~/.config/polybar/polypomo toggle"),
      (2, "~/.config/polybar/polypomo time -1410"),
      (3, "~/.config/polybar/polypomo end")
    ]
    Nothing

trayWidget :: TaffyIO Gtk.Widget
trayWidget = do
  widget <-
    sniTrayNewFromParams
      Tray.defaultTrayParams
        { Tray.trayImageSize = Tray.TrayImageSize 18
        }
  -- the tray box is built with spacing 0 and exposes no spacing knob in
  -- TrayParams; cast back to its real Box type and set it there
  liftIO $ do
    trayBox <- unsafeCastTo Gtk.Box widget
    Gtk.boxSetSpacing trayBox 10
  moduleWrap "tray" widget

data TrackedProcess = TrackedProcess
  { trackedKey :: Unique,
    trackedHandle :: ProcessHandle
  }

{-# NOINLINE processGroups #-}
processGroups :: MVar [TrackedProcess]
processGroups = unsafePerformIO (newMVar [])

registerProcess :: ProcessHandle -> IO Unique
registerProcess handle = do
  key <- newUnique
  modifyMVar_ processGroups (pure . (TrackedProcess key handle :))
  pure key

forgetProcess :: Unique -> IO ()
forgetProcess key =
  modifyMVar_ processGroups (pure . filter ((/= key) . trackedKey))

killProcessGroup :: ProcessHandle -> IO ()
killProcessGroup handle = do
  maybePid <- getPid handle
  case maybePid of
    Just pid -> signalProcessGroup sigTERM pid
    Nothing -> pure ()

terminateAllProcesses :: IO ()
terminateAllProcesses =
  withMVar processGroups (mapM_ (killProcessGroup . trackedHandle))

-- pkill taffybar sends SIGTERM, which GTK never sees, so the stream children
-- are reparented instead of reaped; kill their process groups explicitly.
installTerminationHandler :: IO ()
installTerminationHandler =
  void $
    installHandler
      sigTERM
      (Catch (terminateAllProcesses >> exitImmediately ExitSuccess))
      Nothing

attachBarScroll :: TaffyIO ()
attachBarScroll = do
  context <- ask
  liftIO $ void $ forkIO $ loop (existingWindows context) []
  where
    loop windowsVar attached = do
      windows <- readMVar windowsVar
      attached' <-
        foldM
          ( \acc (_, window) ->
              if window `elem` acc
                then pure acc
                else do
                  -- GTK calls must happen on the GUI thread, not this poller
                  postGUIASync $ addWorkspaceScroll window
                  pure (window : acc)
          )
          attached
          windows
      threadDelay 1000000
      loop windowsVar attached'

addWorkspaceScroll :: Gtk.IsWidget widget => widget -> IO ()
addWorkspaceScroll widget = do
  Gtk.widgetAddEvents widget [Gdk.EventMaskScrollMask]
  void $
    Gtk.onWidgetScrollEvent widget $ \event -> do
      direction <- GdkScroll.getEventScrollDirection event
      case direction of
        Gdk.ScrollDirectionUp -> switchWorkspace True
        Gdk.ScrollDirectionLeft -> switchWorkspace True
        Gdk.ScrollDirectionDown -> switchWorkspace False
        Gdk.ScrollDirectionRight -> switchWorkspace False
        _ -> pure False
  where
    switchWorkspace previous =
      catchAny
        ( do
            withX11Context DefaultDisplay $ do
              names <- getWorkspaceNames
              switchOneWorkspace previous (max 0 (length names - 1))
            pure True
        )
        (\_ -> pure True)

padded :: Gtk.IsWidget widget => widget -> IO Gtk.Widget
padded child = do
  alignment <- Gtk.alignmentNew 0.5 0.5 1 1
  Gtk.alignmentSetPadding alignment 0 0 12 12
  Gtk.containerAdd alignment child
  Gtk.widgetShowAll alignment
  Gtk.toWidget alignment

moduleWrap :: T.Text -> Gtk.Widget -> TaffyIO Gtk.Widget
moduleWrap klass child = do
  box <- liftIO Gtk.eventBoxNew
  _ <- widgetSetClassGI box "module"
  _ <- widgetSetClassGI box klass
  liftIO $ addWorkspaceScroll box
  inner <- liftIO $ padded child
  liftIO $ do
    Gtk.containerAdd box inner
    Gtk.widgetShowAll box
  Gtk.toWidget box

streamingCommand ::
  T.Text ->
  String ->
  [(Int, String)] ->
  Maybe (String, String) ->
  TaffyIO Gtk.Widget
streamingCommand klass command buttons scrollActions = do
  box <- liftIO Gtk.eventBoxNew
  _ <- widgetSetClassGI box "module"
  _ <- widgetSetClassGI box klass
  liftIO $ addWorkspaceScroll box
  label <- liftIO $ Gtk.labelNew Nothing
  inner <- liftIO $ padded label
  liftIO $ do
    -- width-chars keeps the empty module from requisitioning zero width, but
    -- unlike a size request it still lets the first stream line grow the box
    Gtk.labelSetWidthChars label 2
    Gtk.containerAdd box inner
    Gtk.widgetShowAll box
    -- an idle pomodoro has no text; leaving its block visible is just an
    -- empty coloured square
    Gtk.widgetSetVisible box False
  _ <- liftIO $
    Gtk.onWidgetButtonPressEvent box $ \event -> do
      button <- GdkButton.getEventButtonButton event
      forM_ buttons $ \(wanted, action) ->
        when (fromIntegral button == wanted) $ void $ spawnCommand action
      pure True
  liftIO $
    forM_ scrollActions $ \(upAction, downAction) ->
      void $
        Gtk.onWidgetScrollEvent box $ \event -> do
          direction <- GdkScroll.getEventScrollDirection event
          case direction of
            Gdk.ScrollDirectionUp -> spawnCommand upAction >> pure True
            Gdk.ScrollDirectionDown -> spawnCommand downAction >> pure True
            _ -> pure False
  _ <- liftIO $
    forkIO $
      forever $ do
        catchAny (runStream box label) (\_ -> pure ())
        threadDelay 2000000
  Gtk.toWidget box
  where
    runStream box label = do
      (_, maybeOut, _, processHandle) <-
        createProcess (proc "bash" ["-c", command]) {std_out = CreatePipe, std_err = NoStream, create_group = True}
      key <- registerProcess processHandle
      let runChild =
            case maybeOut of
              Nothing -> pure ()
              Just out -> do
                hSetEncoding out utf8
                let loop = do
                      endOfFile <- hIsEOF out
                      unless endOfFile $ do
                        line <- TIO.hGetLine out
                        postGUIASync $ do
                          let text = T.dropWhileEnd (== '\r') line
                          Gtk.labelSetText label text
                          Gtk.widgetSetVisible box (not (T.null (T.strip text)))
                          Gtk.widgetQueueResize box
                        loop
                catchAny loop (\_ -> void $ terminateProcess processHandle)
                hClose out
      runChild `finally` forgetProcess key
      void $ waitForProcess processHandle
