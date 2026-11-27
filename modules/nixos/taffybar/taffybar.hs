{-# LANGUAGE OverloadedStrings #-}

import Control.Applicative ((<|>))
import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (MVar, modifyMVar_, newEmptyMVar, newMVar, readMVar, swapMVar, tryPutMVar, tryReadMVar, tryTakeMVar, withMVar)
import Control.Concurrent.STM (atomically, newBroadcastTChanIO, readTChan, writeTChan)
import Control.Concurrent.STM.TChan (TChan)
import Control.Exception (IOException, SomeException, bracket, catch, finally, try)
import Control.Exception.Enclosed (catchAny)
import Control.Monad (foldM, forM_, forever, replicateM, unless, void, when)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Reader (ask, asks, runReaderT)
import Data.Aeson (FromJSON (..), Object, Value (..), eitherDecode, encode, object, (.=), (.:), (.:?), withObject)
import qualified Data.Aeson.Key as AK
import qualified Data.Aeson.KeyMap as KM
import Data.Bits (shiftR, testBit, xor, (.&.), (.|.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Base64 as B64
import qualified Data.ByteString.Char8 as BC
import qualified Data.ByteString.Lazy as BL
import Data.Char (isAlphaNum, isSpace, ord)
import Data.Default (def)
import Data.Foldable (toList)
import Data.GI.Base (unsafeCastTo)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (dropWhileEnd, find, isPrefixOf, stripPrefix)
import Data.Maybe (fromMaybe, listToMaybe)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Word (Word8)
import qualified Data.Map.Strict as M
import GHC.IO.Encoding (setLocaleEncoding)
import GHC.Int (Int32)
import Numeric (readHex)
import Data.Unique (Unique, newUnique)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import qualified GI.Gdk as Gdk
import qualified GI.Gdk.Structs.EventButton as GdkButton
import qualified GI.Gdk.Structs.EventMotion as GdkMotion
import qualified GI.Gdk.Structs.EventScroll as GdkScroll
import qualified GI.Gdk.Structs.Rectangle as GdkRectangle
import qualified GI.Gtk as Gtk
import qualified Network.Connection as NC
import qualified StatusNotifier.Tray as Tray
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))
import System.IO (hClose, hFlush, hIsEOF, hPutStr, hPutStrLn, hSetEncoding, stderr, stdout, utf8)
import System.IO.Unsafe (unsafePerformIO)
import System.Posix.Process (exitImmediately)
import System.Posix.Signals (Handler (Catch), installHandler, sigTERM, signalProcessGroup)
import System.Process
import System.Random (randomIO)
import System.Taffybar (dyreTaffybar, getTaffyFile)
import Graphics.UI.GIGtkStrut (strutMonitor)
import qualified System.Taffybar.Context as C (strutConfig)
import System.Taffybar.Context (Backend (..), Context (..), TaffyIO, backend)
import System.Taffybar.Information.Audio (AudioInfo (..), defaultAudioPulseSink, defaultAudioWirePlumberNode, getAudioInfoChanAndVar)
import System.Taffybar.Information.WirePlumber
  ( WirePlumberInfo (..),
    adjustWirePlumberVolume,
    getWirePlumberInfoChanAndVar,
    setWirePlumberVolume,
    toggleWirePlumberMute,
  )
import System.Taffybar.Hyprland
  ( getHyprlandClient,
    getHyprlandEventChan,
  )
import System.Taffybar.Information.EWMHDesktopInfo (getWorkspaceNames, switchOneWorkspace, withX11Context)
import System.Taffybar.Information.Hyprland
  ( HyprlandClient,
    HyprlandError,
    hyprCommand,
    hyprCommandJson,
    runHyprlandCommandJson,
    runHyprlandCommandRaw,
    subscribeHyprlandEvents,
  )
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
      startupHook = do
        attachBarScroll
        startHyprlandWatchers
    }

primaryBarConfig :: SimpleTaffyConfig
primaryBarConfig =
  baseBarConfig
    { barCssClasses = ["primary"],
      startWidgets = [workspacesWidget True, inhibitorWidget, memoryWidget],
      centerWidgets = [pomotaskWidget, clockWidget],
      endWidgets = [audioSliderWidget, micSliderWidget, weatherWidget, polypomoWidget]
    }

secondaryBarConfig :: SimpleTaffyConfig
secondaryBarConfig =
  baseBarConfig
    { barCssClasses = ["secondary"],
      startWidgets = [workspacesWidget False, inhibitorWidget, memoryWidget, diskWidget],
      centerWidgets = [pomotaskWidget, clockWidget],
      endWidgets = [trayWidget, audioSliderWidget, micSliderWidget]
    }

isPrimaryMonitor :: Int -> TaffyIO Bool
isPrimaryMonitor monitorIndex = do
  hyprland <- sessionIsHyprland
  if hyprland
    then do
      -- The Wayland backend implements neither the EWMH desktop properties nor
      -- gdk_display_get_primary_monitor (GTK returns NULL there), and GDK's
      -- monitor array is wl_output arrival order, renumbered on hotplug. The
      -- compositor's layout x is the only stable idea of "left monitor".
      boxes <- hyprMonitorBoxes
      own <- liftIO (gdkMonitorBox monitorIndex)
      case own >>= matchMonitorBox boxes of
        Just (x, _, _, _, name) -> do
          liftIO $ barLog ("monitor " ++ show monitorIndex ++ " -> " ++ T.unpack name ++ " x=" ++ show x)
          pure (x == 0)
        Nothing -> do
          liftIO $ barLog ("monitor " ++ show monitorIndex ++ " unmatched: primary is index 0")
          pure (monitorIndex == 0)
    else liftIO $ do
      maybeDisplay <- Gdk.displayGetDefault
      case maybeDisplay of
        Nothing -> pure (monitorIndex == 0)
        Just display -> do
          maybePrimary <- Gdk.displayGetPrimaryMonitor display
          maybeMonitor <- Gdk.displayGetMonitor display (fromIntegral monitorIndex)
          pure $ case (maybePrimary, maybeMonitor) of
            (Just primary, Just monitor) -> primary == monitor
            _ -> monitorIndex == 0

-- Hyprland plumbing. The library picks the backend itself and swaps the
-- workspace provider, but everything hand-written in this config was X11-only:
-- the visibility filter, bar scroll and the primary test all read state Hyprland
-- never exposes. All of it keys off the compositor's IPC instead.

-- | Workspace name -> monitor name. The workspace widget's visibility filter is
-- a pure function, and the Hyprland provider is process-global (first caller
-- wins its config), so per-bar filtering has to consult state we keep ourselves.
{-# NOINLINE wsMonitorVar #-}
wsMonitorVar :: MVar (M.Map T.Text T.Text)
wsMonitorVar = unsafePerformIO (newMVar M.empty)

-- | Widget constructors run in IO, not TaffyIO, and the Hyprland client is only
-- reachable from TaffyIO, so the startup hook parks it here for them. Empty
-- until then, which is also how the X11 path is told apart from Hyprland.
{-# NOINLINE hyprClientVar #-}
hyprClientVar :: MVar HyprlandClient
hyprClientVar = unsafePerformIO newEmptyMVar

-- | `TAFFYBAR_LOG=1` mirrors the compositor decisions to stderr: which backend
-- was picked, which monitor each bar matched, and every time a fallback took
-- over. Bar-to-monitor matching is otherwise only visible as wrong pixels.
{-# NOINLINE barLogOn #-}
barLogOn :: Bool
barLogOn = unsafePerformIO ((== Just "1") <$> lookupEnv "TAFFYBAR_LOG")

barLog :: String -> IO ()
barLog msg =
  when barLogOn $ do
    hPutStrLn stderr ("taffybar: " ++ msg)
    hFlush stderr

sessionIsHyprland :: TaffyIO Bool
sessionIsHyprland = asks ((== BackendWayland) . backend)

data HyprMonitor = HyprMonitor
  { hmName :: T.Text,
    hmX :: Int,
    hmY :: Int,
    hmW :: Int,
    hmH :: Int
  }
  deriving (Show)

instance FromJSON HyprMonitor where
  parseJSON = withObject "HyprMonitor" $ \o ->
    HyprMonitor
      <$> o .: "name"
      <*> o .: "x"
      <*> o .: "y"
      <*> o .: "width"
      <*> o .: "height"

data HyprWorkspaceRow = HyprWorkspaceRow
  { hwName :: T.Text,
    hwMonitor :: T.Text
  }
  deriving (Show)

-- | monitor is absent while a workspace is being dragged between outputs; an
-- empty string just means "not filterable yet" and falls back to the numeric split.
instance FromJSON HyprWorkspaceRow where
  parseJSON = withObject "HyprWorkspaceRow" $ \o -> do
    name <- o .: "name"
    monitor <- o .:? "monitor"
    pure HyprWorkspaceRow {hwName = name, hwMonitor = fromMaybe "" monitor}

hyprMonitorsIO :: HyprlandClient -> IO (Either HyprlandError [HyprMonitor])
hyprMonitorsIO client = runHyprlandCommandJson client (hyprCommandJson ["monitors"])

hyprWorkspacesIO :: HyprlandClient -> IO (Either HyprlandError [HyprWorkspaceRow])
hyprWorkspacesIO client = runHyprlandCommandJson client (hyprCommandJson ["workspaces"])

hyprMonitorBoxes :: TaffyIO [(Int, Int, Int, Int, T.Text)]
hyprMonitorBoxes = do
  client <- getHyprlandClient
  result <- liftIO (hyprMonitorsIO client)
  pure $ case result of
    Right monitors -> [(hmX m, hmY m, hmW m, hmH m, hmName m) | m <- monitors]
    Left _ -> []

-- | (x, y, w, h) in compositor layout space.
gdkMonitorBox :: Int -> IO (Maybe (Int, Int, Int, Int))
gdkMonitorBox index = do
  maybeDisplay <- Gdk.displayGetDefault
  case maybeDisplay of
    Nothing -> pure Nothing
    Just display -> do
      maybeMonitor <- Gdk.displayGetMonitor display (fromIntegral index)
      maybe (pure Nothing) monitorBox maybeMonitor

monitorBox :: Gdk.Monitor -> IO (Maybe (Int, Int, Int, Int))
monitorBox monitor = do
  rect <- Gdk.monitorGetGeometry monitor
  x <- GdkRectangle.getRectangleX rect
  y <- GdkRectangle.getRectangleY rect
  w <- GdkRectangle.getRectangleWidth rect
  h <- GdkRectangle.getRectangleHeight rect
  pure (Just (fromIntegral x, fromIntegral y, fromIntegral w, fromIntegral h))

-- | Prefer exact position; fall back to size, since a scaled monitor reports a
-- different origin to GTK than it does to Hyprland.
matchMonitorBox ::
  [(Int, Int, Int, Int, T.Text)] ->
  (Int, Int, Int, Int) ->
  Maybe (Int, Int, Int, Int, T.Text)
matchMonitorBox boxes (x, y, w, h) =
  case [b | b <- boxes, matchesPosition b] of
    (b:_) -> Just b
    [] -> listToMaybe [b | b <- boxes, matchesSize b]
  where
    matchesPosition (bx, by, _, _, _) = bx == x && by == y
    matchesSize (_, _, bw, bh, _) = bw == w && bh == h

-- | The monitor this bar is being put on, read from the strut taffybar will put
-- it on. Asking GTK which monitor a window sits on is a guess here: a
-- layer-shell surface has no global position, and on Wayland
-- `gdk_display_get_monitor_at_window` falls back to whatever the pointer is
-- over — measured live, both bars were told DP-5 (0,0,2560,1080) that way and
-- both drew the primary's workspaces. The strut index is what actually decides
-- placement, so it cannot disagree with where the bar ends up.
barStrutMonitorBox :: TaffyIO (Maybe (Int, Int, Int, Int))
barStrutMonitorBox = do
  context <- ask
  case contextBarConfig context of
    Nothing -> pure Nothing
    Just barConfig -> case strutMonitor (C.strutConfig barConfig) of
      Nothing -> pure Nothing
      Just index -> liftIO (gdkMonitorBox (fromIntegral index))

-- | Which Hyprland monitor this widget's bar is drawn on.
widgetMonitorName :: Gtk.Widget -> TaffyIO (Maybe T.Text)
widgetMonitorName widget = do
  boxes <- hyprMonitorBoxes
  if null boxes
    then liftIO (barLog "hypr boxes empty") >> pure Nothing
    else do
      strutBox <- barStrutMonitorBox
      own <- liftIO widgetMonitorBox
      -- Both coordinate spaces in one line: the strut box is what the fix
      -- depends on, the at-window box is what the fallback used to trust.
      liftIO $
        barLog
          ( "strut box "
              ++ show strutBox
              ++ " | at-window "
              ++ show own
              ++ " | hypr "
              ++ show boxes
          )
      let matched = snd5 <$> ((strutBox <|> own) >>= matchMonitorBox boxes)
      liftIO $ barLog ("matched " ++ show matched)
      pure matched
  where
    snd5 (_, _, _, _, name) = name
    widgetMonitorBox = do
      maybeWindow <- Gtk.widgetGetWindow widget
      case maybeWindow of
        Nothing -> pure Nothing
        Just window -> do
          display <- Gdk.windowGetDisplay window
          -- GTK types this non-nullable but can still hand back NULL; the
          -- catch is what keeps a missing monitor from killing the retry loop.
          catchAny
            ( do
                monitor <- Gdk.displayGetMonitorAtWindow display window
                monitorBox monitor
            )
            (\_ -> pure Nothing)

-- | Fill in the bar's monitor once its window exists; the widget is built before
-- the bar window is realized, and nothing announces that it finally is.
attachMonitorName :: Gtk.Widget -> MVar T.Text -> TaffyIO ()
attachMonitorName widget own = do
  context <- ask
  void $ liftIO $ forkIO $ tryTimes context (40 :: Int)
  where
    tryTimes _ 0 = barLog "bar monitor unresolved: workspaces split numerically"
    tryTimes context n = do
      name <- runReaderT (widgetMonitorName widget) context
      case name of
        Just found -> do
          tryPutMVar own found
          barLog ("bar monitor: " ++ T.unpack found)
        Nothing -> threadDelay 500000 >> tryTimes context (n - 1)

-- | Filter the workspace list down to the one bar's monitor. Falls back to the
-- old numeric 1-6 / 7-12 split whenever the compositor has not told us where
-- this bar or this workspace lives.
{-# NOINLINE barScopedWorkspaces #-}
barScopedWorkspaces :: MVar T.Text -> Bool -> Bool -> WorkspaceInfo -> Bool
barScopedWorkspaces own isPrimary multiMonitor ws
  | workspaceIsSpecial ws = False
  | Just monitor <- ownMonitor, Just workspaceMonitor <- M.lookup name table, not (T.null workspaceMonitor) =
      workspaceMonitor == monitor
  | otherwise = numericSplit
  where
    ownMonitor = unsafePerformIO (tryReadMVar own)
    table = unsafePerformIO (readMVar wsMonitorVar)
    name = workspaceName (workspaceIdentity ws)
    numericSplit = maybe False underLimit (workspaceNumericId (workspaceIdentity ws))
    -- one bar covers the whole desktop when there is only one screen, so the
    -- primary split only narrows to 1-5 once a second bar exists to hold 6-12
    underLimit n
      | isPrimary && multiMonitor = n < 6
      | isPrimary = n < 12
      | otherwise = n >= 6 && n < 12

refreshWorkspaceMonitors :: HyprlandClient -> IO ()
refreshWorkspaceMonitors client = do
  result <- hyprWorkspacesIO client
  case result of
    Right rows -> modifyMVar_ wsMonitorVar (\_ -> pure (rowsToMap rows))
    Left err -> barLog ("workspace monitor refresh failed: " ++ show err)
  where
    rowsToMap = foldr (\row acc -> M.insert (hwName row) (hwMonitor row) acc) M.empty

-- | Workspace events worth re-reading the workspace list for. activewindow and
-- friends fire on every mouse move, so the list stays deliberately narrow.
relevantWorkspaceEvent :: T.Text -> Bool
relevantWorkspaceEvent line =
  any (`T.isPrefixOf` line) $ T.words
    "workspace workspacev2 focusedmon moveworkspace movewindow openwindow closewindow createworkspace destroyworkspace renameworkspace monitoradded monitorremoved workspacerule"

startHyprlandWatchers :: TaffyIO ()
startHyprlandWatchers = do
  hyprland <- sessionIsHyprland
  liftIO $ barLog ("backend: " ++ (if hyprland then "wayland/hyprland" else "x11"))
  when hyprland $ do
    client <- getHyprlandClient
    void $ liftIO $ tryPutMVar hyprClientVar client
    liftIO $ refreshWorkspaceMonitors client
    events <- getHyprlandEventChan
    subscription <- liftIO $ subscribeHyprlandEvents events
    void $ liftIO $ forkIO $ forever $ do
      line <- atomically (readTChan subscription)
      when (relevantWorkspaceEvent line) $ refreshWorkspaceMonitors client
    -- the event socket is dropped on a compositor reload; a slow poll means a
    -- missed burst costs 15 s of stale filtering, not a permanently wrong bar
    void $ liftIO $ forkIO $ forever $ do
      threadDelay 15000000
      refreshWorkspaceMonitors client


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

workspacesWidget :: Bool -> TaffyIO Gtk.Widget
workspacesWidget isPrimary = do
  ownMonitor <- liftIO newEmptyMVar
  multiMonitor <- liftIO $ do
    maybeDisplay <- Gdk.displayGetDefault
    maybe (pure False) (fmap (> 1) . Gdk.displayGetNMonitors) maybeDisplay
  widget <-
    workspacesNew
      defaultWorkspacesConfig
        { showWorkspaceFn = barScopedWorkspaces ownMonitor isPrimary multiMonitor,
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
  attachMonitorName widget ownMonitor
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
      step <- scrollStep event
      case step of
        Just True -> void (adjustWirePlumberVolume nodeSpec 2) >> forkIO refresh >> pure True
        Just False -> void (adjustWirePlumberVolume nodeSpec (-2)) >> forkIO refresh >> pure True
        Nothing -> pure False
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

weatherWidget :: TaffyIO Gtk.Widget
weatherWidget =
  textWttrNew "https://wttr.in/Moscow?format=%c%t%20(%f)" 600
    >>= moduleWrap "weather"

-- PomoTask: the self-hosted pomotasker timer (habits + pomodoro) that the rofi
-- launcher and the PWA also drive. Its live state exists only on the server
-- and is only readable over the websocket (there is no REST endpoint for it),
-- so this keeps one long-lived WSS open inside the bar instead of the old
-- python child: no nix-shell re-evaluation per spawn, and while nothing is
-- running the thread just blocks in the socket read rather than waking every
-- second. The polybar-pomotask.py path also kept re-running a finished stream.
--
-- Elapsed time is always recomputed from the server's startTime, so a running
-- countdown keeps advancing across a dropped connection or a stalled relay.

data PomoMode = PomoStopwatch | PomoTimed deriving (Eq, Show)

-- mirrors the server snapshot; every field is the server's, no local guessing
data PomoTimer = PomoTimer
  { pomoRunning :: Bool,
    pomoMode :: PomoMode,
    pomoName :: Maybe T.Text,
    pomoHabitId :: Maybe Int,
    pomoStartMs :: Maybe Int,
    pomoElapsedBefore :: Int
  }

emptyPomoTimer :: PomoTimer
emptyPomoTimer = PomoTimer False PomoStopwatch Nothing Nothing Nothing 0

-- wall time, not a monotonic clock: the server's timeline is epoch-ms, so a
-- local monotonic base would drift away from every other client on an NTP step
pomoNowMs :: IO Int
pomoNowMs = fmap (\t -> floor (t * 1000) :: Int) getPOSIXTime

pomoElapsedMs :: PomoTimer -> Int -> Int
pomoElapsedMs s nowMs =
  pomoElapsedBefore s + case pomoStartMs s of
    Just ms | pomoRunning s -> max 0 (nowMs - ms)
    _ -> 0

-- the app's pomodoro budget is fixed and the state only carries a mode flag
pomoPomodoroMs :: Int
pomoPomodoroMs = 1500 * 1000

pomoTrimTitle :: T.Text -> T.Text
pomoTrimTitle t =
  let limit = 24 in if T.length t > limit then T.take (limit - 1) t <> "…" else t

-- Glyphs match the waybar/polybar modules: 23F0 stopwatch, 1F345 pomodoro.
-- ⏱ counts up, ⏲ counts down against the app's fixed 25-minute pomodoro.
-- Same digit layout the polybar module used, so the bar does not change shape
-- when the timer moves onto it.
pomoClockText :: PomoTimer -> Int -> T.Text
pomoClockText s nowMs = glyph <> T.pack (pomoDurationText shown padded)
  where
    elapsed = pomoElapsedMs s nowMs
    (glyph, shown, padded) = case pomoMode s of
      PomoStopwatch -> (T.singleton '\128354', elapsed, False)
      PomoTimed -> (T.singleton '\9202', max 0 (pomoPomodoroMs - elapsed), True)

pomoDurationText :: Int -> Bool -> String
pomoDurationText ms pad
  | h > 0 = printf "%d:%02d:%02d" h m s
  | pad = printf "%02d:%02d" m s
  | otherwise = printf "%d:%02d" m s
  where
    totalSec = ms `div` 1000
    h = totalSec `div` 3600
    m = (totalSec `mod` 3600) `div` 60
    s = totalSec `mod` 60

-- "" means nothing to show, which is what hides the module.
renderPomo :: PomoTimer -> M.Map Int T.Text -> Int -> T.Text
renderPomo s titles nowMs
  | not (pomoRunning s) = T.empty
  | otherwise = title <> separator <> pomoClockText s nowMs
  where
    title = case pomoName s of
      Just n | not (T.null (T.strip n)) -> pomoTrimTitle n
      _ -> maybe T.empty pomoTrimTitle (flip M.lookup titles =<< pomoHabitId s)
    separator = if T.null title then T.empty else T.singleton ' '

-- The server merges {...snapshot, ...data} into its own state, so a key sent
-- as null clears a field while an absent key must not. That distinction is the
-- reason this reads Values instead of a Maybe-record.
pomoApply :: Object -> PomoTimer -> PomoTimer
pomoApply o s =
  s
    { pomoRunning = pick asBool "running" (pomoRunning s),
      pomoMode = case at "mode" of
        Just v -> maybe (pomoMode s) id (asMode v)
        Nothing -> pomoMode s,
      pomoName = pick asText "name" (pomoName s),
      pomoHabitId = pick asNumber "activeHabitId" (pomoHabitId s),
      pomoStartMs = pick asNumber "startTime" (pomoStartMs s),
      pomoElapsedBefore = pick asInt "elapsedBefore" (pomoElapsedBefore s)
    }
  where
    at key = pomoAt key o
    pick f key d = case at key of
      Nothing -> d
      Just v -> f v
    asBool (Bool b) = b
    asBool _ = False
    asInt (Number n) = truncate n
    asInt Null = 0
    asInt _ = 0
    asNumber (Number n) = Just (truncate n)
    asNumber _ = Nothing
    asText (String t) = Just t
    asText _ = Nothing
    asMode (String t) = Just (if t == "timed" then PomoTimed else PomoStopwatch)
    asMode _ = Nothing

pomoAt :: T.Text -> Object -> Maybe Value
pomoAt key = KM.lookup (AK.fromText key)

pomoPingPayload :: ByteString
pomoPingPayload = BL.toStrict (encode (object ["type" .= ("ping" :: T.Text)]))

pomoStopPayload :: ByteString
pomoStopPayload = BL.toStrict (encode (object ["type" .= ("timer:stop" :: T.Text)]))

-- A full snapshot, not a patch: the server merges patches, so sending only
-- elapsedBefore would leave it inconsistent with the startTime every other
-- client keeps using to compute elapsed.
pomoShiftPayload :: PomoTimer -> Int -> Int -> ByteString
pomoShiftPayload st shiftMs nowMs =
  BL.toStrict $ encode $ object
    [ "type" .= ("timer:update" :: T.Text),
      "data" .= object
        [ "activeHabitId" .= pomoHabitId st,
          "name" .= pomoName st,
          "mode" .= (modeText :: T.Text),
          "running" .= pomoRunning st,
          "startTime" .= (Just nowMs :: Maybe Int),
          "elapsedBefore" .= (max 0 (pomoElapsedMs st nowMs + shiftMs) :: Int)
        ]
    ]
  where
    modeText = case pomoMode st of
      PomoTimed -> "timed"
      _ -> "stopwatch"

-- --- minimal RFC 6455 client: nixpkgs has no websocket client library (the
-- hs-websocket package is gone and wuss needs the missing `websockets`), so
-- the framing lives here over crypton-connection. Text frames, ping/pong and
-- close only -- enough for a two-message protocol and nothing else. ---

data PomoConn = PomoConn
  { pcConn :: NC.Connection,
    pcBuf :: IORef BS.ByteString,
    pcPartial :: IORef BS.ByteString
  }

pomoXorMask :: BS.ByteString -> BS.ByteString -> BS.ByteString
pomoXorMask mask body = BS.pack (zipWith xor (cycle (BS.unpack mask)) (BS.unpack body))

pomoBe :: Int -> Int -> BS.ByteString
pomoBe value bytes =
  BS.pack [fromIntegral (value `shiftR` (8 * (bytes - i - 1))) | i <- [0 .. bytes - 1]]

pomoBeToInt :: BS.ByteString -> Int
pomoBeToInt = BS.foldl (\acc w -> acc * 256 + fromIntegral w) 0

-- opcode 0x1 text, 0xa pong; every client frame must be masked
pomoEncodeFrame :: Word8 -> BS.ByteString -> IO BS.ByteString
pomoEncodeFrame opcode body = do
  mask <- BS.pack <$> replicateM 4 (randomIO :: IO Word8)
  let n = BS.length body
      lengthField
        | n < 126 = BS.singleton (0x80 .|. fromIntegral n)
        | n < 65536 = BS.cons 0xfe (pomoBe n 2)
        | otherwise = BS.cons 0xff (pomoBe n 8)
  pure (BS.cons (0x80 .|. opcode) lengthField <> mask <> pomoXorMask mask body)

-- The frame parser is pure over a buffer: nixpkgs has no websocket client, so
-- the framing is ours, and keeping it out of the socket code is what makes the
-- coalesced/split/extended-length cases testable without a server.
--
-- Never drop the tail: the server can coalesce two messages into one TLS
-- record, so the reader must know exactly where one frame ends.
pomoFrameLength :: BS.ByteString -> Maybe Int
pomoFrameLength bs
  -- the guard below evaluates b1 through headerNeed, so the short-buffer case
  -- has to be settled first or a one-byte TLS record crashes instead of waiting
  | BS.length bs < 2 = Nothing
  | BS.length bs < headerNeed = Nothing
  | BS.length bs < total = Nothing
  | otherwise = Just total
  where
    b1 = BS.index bs 1
    len0 = b1 .&. 0x7f
    lenBytes = case len0 of
      126 -> 2
      127 -> 8
      _ -> 0
    maskLen = if testBit b1 7 then 4 else 0
    headerNeed = 2 + lenBytes
    plen
      | lenBytes == 0 = fromIntegral len0
      | otherwise = pomoBeToInt (BS.take lenBytes (BS.drop 2 bs))
    total = headerNeed + maskLen + plen

-- (fin, opcode, payload); the caller drops pomoFrameLength bytes from its
-- buffer, which is why Nothing here means "parser bug", not "no data yet".
pomoDecodeFrame :: BS.ByteString -> Maybe (Bool, Word8, BS.ByteString)
pomoDecodeFrame bs = do
  total <- pomoFrameLength bs
  let b0 = BS.index bs 0
      b1 = BS.index bs 1
      len0 = b1 .&. 0x7f
      lenBytes = case len0 of
        126 -> 2
        127 -> 8
        _ -> 0
      maskLen = if testBit b1 7 then 4 else 0
      payloadStart = 2 + lenBytes + maskLen
      -- the mask sits after the extended length field, not right after the
      -- two-byte header
      mask = BS.take maskLen (BS.drop (2 + lenBytes) bs)
      payload = BS.take (total - payloadStart) (BS.drop payloadStart bs)
  pure (testBit b0 7, b0 .&. 0x0f, if maskLen == 0 then payload else pomoXorMask mask payload)

-- Never drop the tail: the server can coalesce two messages into one TLS
-- record, and a reader that assumed one record per frame would lose the second.
pomoRecvFrame :: PomoConn -> IO (Bool, Word8, BS.ByteString)
pomoRecvFrame pc = do
  buf <- readIORef (pcBuf pc)
  case pomoDecodeFrame buf of
    Just frame -> do
      case pomoFrameLength buf of
        Nothing -> ioError (userError "pomotask: frame length disagreed with the parser")
        Just total -> writeIORef (pcBuf pc) (BS.drop total buf)
      pure frame
    Nothing -> do
      chunk <- pomoGetChunk (pcConn pc)
      if BS.null chunk
        then ioError (userError "pomotask: socket reached EOF")
        else do
          writeIORef (pcBuf pc) (buf `BS.append` chunk)
          pomoRecvFrame pc

-- EOF arrives as an exception from the TLS layer, and the supervisor's job is
-- to reconnect on any of them, so it is swallowed into the empty-chunk signal.
pomoGetChunk :: NC.Connection -> IO BS.ByteString
pomoGetChunk conn = NC.connectionGetChunk conn `catchAny` (\_ -> pure BS.empty)

-- A fragmented message must be glued, not skipped: a proxy that fragments
-- would otherwise make the state silently stale.
pomoTextPart :: PomoConn -> Bool -> BS.ByteString -> IO BS.ByteString
pomoTextPart pc fin part =
  if fin
    then do
      prev <- readIORef (pcPartial pc)
      writeIORef (pcPartial pc) BS.empty
      pure (prev `BS.append` part)
    else do
      modifyIORef' (pcPartial pc) (<> part)
      pure BS.empty

pomoTlsSettings :: NC.TLSSettings
-- `def` is TLSSettingsSimple False False False with ciphersuite_default. The
-- third flag looks like the SNI switch but crypton-connection ignores it: SNI
-- and the hostname the certificate is checked against both come from
-- defaultParamsClient, so leaving validation enabled here is what we want.
pomoTlsSettings = def

pomoConnect :: NC.ConnectionContext -> PomoEndpoint -> IO NC.Connection
pomoConnect ctx ep =
  NC.connectTo
    ctx
    ( NC.ConnectionParams
        (peHost ep)
        (fromIntegral (pePort ep))
        -- Nothing here is crypton-connection's plain TCP; the base URL's scheme
        -- decides, so POMOTASK_BASE=http://127.0.0.1:3000 reaches a local server
        (if peTls ep then Just pomoTlsSettings else Nothing)
        Nothing
    )

-- Not in scope: verifying Sec-WebSocket-Accept. The key is random per
-- connection, so a proxy replaying an old upgrade would desync framing, and
-- the supervisor reconnects and resyncs from timer:sync anyway -- cheaper than
-- dragging in a SHA-1 dependency for a bar widget.
pomoOpenWs :: NC.ConnectionContext -> PomoEndpoint -> String -> IO PomoConn
pomoOpenWs ctx ep key = do
  conn <- pomoConnect ctx ep
  wsKey <- pomoWsKey
  NC.connectionPut conn (BC.pack (pomoWsRequest ep key wsKey))
  status <- pomoReadLine conn
  unless ("101" `BC.isInfixOf` status) $
    ioError (userError ("pomotask: websocket handshake rejected: " ++ BC.unpack status))
  pomoSkipHeaders conn
  PomoConn conn <$> newIORef BS.empty <*> newIORef BS.empty
  where
    pomoSkipHeaders c = do
      line <- pomoReadLine c
      -- the line arrives with its LF trimmed, so a blank header line is "\r"
      if BS.null line || line == BC.pack "\r"
        then pure ()
        else pomoSkipHeaders c

pomoWsRequest :: PomoEndpoint -> String -> String -> String
pomoWsRequest ep key wsKey =
  concat
    [ "GET ", pePrefix ep, "/ws?key=", pomoQueryValue key, " HTTP/1.1\r\n",
      "Host: ", peHost ep, "\r\n",
      "Upgrade: websocket\r\n",
      "Connection: Upgrade\r\n",
      "Sec-WebSocket-Key: ", wsKey, "\r\n",
      "Sec-WebSocket-Version: 13\r\n\r\n"
  ]

pomoReadLine :: NC.Connection -> IO BS.ByteString
pomoReadLine conn =
  NC.connectionGetLine 4096 conn `catchAny` (\_ -> ioError (userError "pomotask: handshake read failed"))

pomoWsKey :: IO String
pomoWsKey = do
  bytes <- BS.pack <$> replicateM 16 (randomIO :: IO Word8)
  pure (BC.unpack (B64.encode bytes))

pomoQueryValue :: String -> String
pomoQueryValue = concatMap safe
  where
    safe c
      | isAlphaNum c || c `elem` ("-._~" :: String) = [c]
      | otherwise = printf "%%%02X" (ord c :: Int)

-- One-shot HTTPS GET. Connection: close means the body ends at EOF, which
-- avoids tracking Content-Length here; chunked still has to be undone because
-- express streams some responses rather than buffering them.
pomoHttpGet :: NC.ConnectionContext -> PomoEndpoint -> String -> String -> IO BS.ByteString
pomoHttpGet ctx ep key path =
  bracket (pomoConnect ctx ep) (\conn -> catchAny (NC.connectionClose conn) (\_ -> pure ())) $ \conn -> do
    NC.connectionPut conn (BC.pack request)
    raw <- pomoReadUntilClose conn BS.empty
    pure (pomoHttpBody raw)
  where
    request =
      concat
        [ "GET ", path, " HTTP/1.1\r\n",
          "Host: ", peHost ep, "\r\n",
          "Authorization: Bearer ", key, "\r\n",
          "Accept: application/json\r\n",
          "Connection: close\r\n\r\n"
      ]

pomoReadUntilClose :: NC.Connection -> BS.ByteString -> IO BS.ByteString
pomoReadUntilClose conn acc = do
  chunk <- pomoGetChunk conn
  if BS.null chunk then pure acc else pomoReadUntilClose conn (acc `BS.append` chunk)

pomoHttpBody :: BS.ByteString -> BS.ByteString
pomoHttpBody raw = case pomoIndexOfDoubleCrlf raw of
  Nothing -> BS.empty
  Just i ->
    let headers = BS.take i raw
        body = BS.drop (i + 4) raw
    in if "chunked" `BC.isInfixOf` headers
         then maybe BS.empty id (pomoDechunk body)
         else body

pomoIndexOfDoubleCrlf :: BS.ByteString -> Maybe Int
pomoIndexOfDoubleCrlf bs = go 0
  where
    go i
      | i + 3 >= BS.length bs = Nothing
      | BS.index bs i == 13 && BS.index bs (i + 1) == 10 && BS.index bs (i + 2) == 13 && BS.index bs (i + 3) == 10 = Just i
      | otherwise = go (i + 1)

pomoBreakCrLf :: BS.ByteString -> Maybe (BS.ByteString, BS.ByteString)
pomoBreakCrLf s = case BC.break (== '\r') s of
  (line, rest) | BS.length rest >= 2 -> Just (line, BS.drop 2 rest)
  _ -> Nothing

pomoDechunk :: BS.ByteString -> Maybe BS.ByteString
pomoDechunk = go BS.empty
  where
    go acc s = case pomoBreakCrLf s of
      Nothing -> Nothing
      Just (line, rest) -> case pomoReadHex (takeWhile (/= ';') (BC.unpack line)) of
        Just 0 -> Just acc
        Just n
          | BS.length rest >= n -> go (acc `BS.append` BS.take n rest) (BS.drop 2 (BS.drop n rest))
          | otherwise -> Nothing
        Nothing -> Nothing
    -- chunk extensions are not expected from this server, so they are trimmed
    -- rather than parsed
    pomoReadHex s = case readHex s of
      [(n, "")] -> Just (n :: Int)
      _ -> Nothing

-- Any {id, description} pair in the response is a habit title. The endpoint
-- nests habits under groups and the shape has already been reorganised once,
-- so scanning outlives another reshuffle; extra ids (archived habits) are
-- harmless because they are only ever looked up by the running timer.
pomoHabitTitles :: BS.ByteString -> M.Map Int T.Text
pomoHabitTitles body = case eitherDecode (BL.fromStrict body) of
  Right v -> M.fromList (pomoCollectPairs v)
  Left _ -> M.empty
  where
    pomoCollectPairs (Object o) = pair ++ concatMap pomoCollectPairs (KM.elems o)
      where
        pair = case (pomoAt "id" o, pomoAt "description" o) of
          (Just (Number i), Just (String d)) | not (T.null (T.strip d)) -> [(truncate i, d)]
          _ -> []
    pomoCollectPairs (Array xs) = concatMap pomoCollectPairs (toList xs)
    pomoCollectPairs _ = []

pomoHabits :: PomoVar -> IO (M.Map Int T.Text)
pomoHabits env =
  pomoHabitTitles <$> pomoHttpGet (pvCtx env) (pvEndpoint env) (pvKey env) (pePrefix (pvEndpoint env) ++ "/api/habits")

data PomoEndpoint = PomoEndpoint
  { peHost :: String,
    pePort :: Int,
    pePrefix :: String,
    peTls :: Bool
  }
  deriving (Eq, Show)

parsePomoBase :: String -> Maybe PomoEndpoint
parsePomoBase raw = case stripPrefix "https://" t0 of
  Just rest -> endpoint True rest
  Nothing -> case stripPrefix "http://" t0 of
    -- the rofi backend's local server is plain http, and a bar widget that
    -- forced TLS there would just sit hidden with a handshake error
    Just rest -> endpoint False rest
    Nothing -> endpoint True t0
  where
    t0 = pomoTrimTrailingSlashes raw
    endpoint secure rest =
      let (authority, path) = break (== '/') rest
          (hostText, portText) = span (/= ':') authority
          port = case portText of
            (':':ns) -> readMaybe ns
            _ -> Nothing
      in if null hostText
           then Nothing
           else Just PomoEndpoint
                { peHost = hostText,
                  pePort = fromMaybe (if secure then 443 else 80) port,
                  pePrefix = if null path then "/pomotask" else path,
                  peTls = secure
                }

pomoTrimTrailingSlashes :: String -> String
pomoTrimTrailingSlashes = dropWhileEnd (== '/')

pomotaskDefaultBase :: String
pomotaskDefaultBase = "https://ug.kyrgyzstan.kg/pomotask"

pomotaskLauncher :: String
pomotaskLauncher = "~/.config/rofi/launchers/colorful/pomotask.sh"

pomotaskKeyFile :: IO (Maybe FilePath)
pomotaskKeyFile = do
  home <- lookupEnv "HOME"
  pure (fmap (\h -> h ++ "/Dropbox/pomotask") home)

-- The rofi backend accepts any file that starts with pomo_; keeping the same
-- check here means a half-written or wrong-format file stays a hidden widget
-- instead of a thread that reconnects forever against a 401.
pomoReadKey :: FilePath -> IO (Maybe String)
pomoReadKey path = do
  content <- try (readFile path) :: IO (Either IOException String)
  case content of
    Left _ -> pure Nothing
    Right s ->
      let k = pomoTrimStr s in pure (if "pomo_" `isPrefixOf` k then Just k else Nothing)

pomoTrimStr :: String -> String
pomoTrimStr = dropWhile isSpace . dropWhileEnd isSpace

pomotaskConfig :: IO (Maybe PomoVar)
pomotaskConfig = do
  base <- lookupEnv "POMOTASK_BASE"
  keyFileEnv <- lookupEnv "POMOTASK_KEY_FILE"
  keyFilePath <- maybe pomotaskKeyFile (pure . Just) keyFileEnv
  mkey <- maybe (pure Nothing) pomoReadKey keyFilePath
  case parsePomoBase (fromMaybe pomotaskDefaultBase base) of
    Nothing -> do
      hPutStrLn stderr "pomotask: POMOTASK_BASE is unparseable, widget left hidden"
      pure Nothing
    Just endpoint -> case mkey of
      Nothing -> do
        hPutStrLn stderr "pomotask: no pomo_ API key, widget left hidden"
        pure Nothing
      Just key ->
        Just <$> (PomoVar <$> NC.initConnectionContext <*> pure endpoint <*> pure key)

data PomoVar = PomoVar
  { pvCtx :: NC.ConnectionContext,
    pvEndpoint :: PomoEndpoint,
    pvKey :: String
  }

data PomoGui = PomoGui
  { pgBox :: Gtk.Widget,
    pgLabel :: Gtk.Label
  }

data PomoRefs = PomoRefs
  { prTimer :: IORef PomoTimer,
    prTitles :: IORef (M.Map Int T.Text),
    prTitlesAt :: IORef Int,
    prShown :: IORef T.Text,
    prLastPing :: IORef Int,
    prLastMsg :: IORef Int,
    prFetchGate :: MVar (),
    prGuis :: IORef [PomoGui]
  }

pomoTickMs, pomoPingMs, pomoSilenceMs, pomoRetryMs, pomoMaxBackoffMs, pomoTitleRetryMs :: Int
pomoTickMs = 1000

-- Cloudflare's edge drops an idle websocket well before this; the interval is
-- a keepalive, and a pong (or any message) is what proves the socket is alive.
pomoPingMs = 30000

-- two missed pings: past this the socket is half-open (suspend, IP change) and
-- nothing will arrive until we reconnect
pomoSilenceMs = 120000
pomoRetryMs = 2000
pomoMaxBackoffMs = 30000
pomoTitleRetryMs = 60000

-- One connection and one timer state for the whole bar process, shared by every
-- monitor's widget: a socket per widget would double the traffic and let the two
-- labels disagree for a frame about a stop one of them just sent. unsafePerformIO
-- so it exists as a CAF before any widget asks, same pattern as processGroups.
{-# NOINLINE pomoShared #-}
pomoShared :: Maybe (PomoVar, PomoRefs)
pomoShared = unsafePerformIO $ do
  conf <- pomotaskConfig
  case conf of
    Nothing -> pure Nothing
    Just env -> do
      now <- pomoNowMs
      refs <-
        PomoRefs
          <$> newIORef emptyPomoTimer
          <*> newIORef M.empty
          <*> newIORef now
          <*> newIORef T.empty
          <*> newIORef now
          <*> newIORef now
          <*> newMVar ()
          <*> newIORef []
      -- started here rather than per widget: this action is what makes it once
      void $ forkIO (pomoSupervisor env refs)
      pure (Just (env, refs))

-- Only ever called from the one socket loop thread, so the shown-text cache is
-- race-free; it is what stops a per-second tick from asking GTK to resize the
-- bars for a string that did not change.
pomoRender :: PomoRefs -> IO ()
pomoRender refs = do
  st <- readIORef (prTimer refs)
  titles <- readIORef (prTitles refs)
  now <- pomoNowMs
  let txt = renderPomo st titles now
  shown <- readIORef (prShown refs)
  when (txt /= shown) $ do
    writeIORef (prShown refs) txt
    guis <- readIORef (prGuis refs)
    postGUIASync (mapM_ (applyPomoText txt) guis)

-- Must run on the GUI thread: pomoRender reaches it through postGUIASync,
-- pomotaskWidget calls it directly because widget construction is already there.
applyPomoText :: T.Text -> PomoGui -> IO ()
applyPomoText txt gui = do
  Gtk.labelSetText (pgLabel gui) txt
  Gtk.widgetSetVisible (pgBox gui) (not (T.null (T.strip txt)))
  Gtk.widgetQueueResize (pgBox gui)

pomoAttach :: PomoGui -> PomoRefs -> IO ()
pomoAttach gui refs = do
  st <- readIORef (prTimer refs)
  titles <- readIORef (prTitles refs)
  now <- pomoNowMs
  modifyIORef' (prGuis refs) (gui :)
  -- a widget registered after the connection started has to be filled in at
  -- once: pomoRender skips work when the text has not changed, so an empty
  -- second-monitor label would stay empty until the next title change
  applyPomoText (renderPomo st titles now) gui

pomoTitlesNeeded :: PomoTimer -> M.Map Int T.Text -> Bool
pomoTitlesNeeded s titles = case pomoHabitId s of
  Just hid -> not (M.member hid titles)
  Nothing -> False

-- force=True is the connect-time fetch, so a title is usually ready before the
-- first second of a timer is rendered. The gate keeps 1-second ticks from
-- turning a failed fetch into a request loop.
pomoFetchTitles :: PomoVar -> PomoRefs -> Bool -> IO ()
pomoFetchTitles env refs force = do
  st <- readIORef (prTimer refs)
  titles <- readIORef (prTitles refs)
  at <- readIORef (prTitlesAt refs)
  now <- pomoNowMs
  token <-
    if force || ((pomoTitlesNeeded st titles || force) && now - at >= pomoTitleRetryMs)
      then tryTakeMVar (prFetchGate refs)
      else pure Nothing
  case token of
    Nothing -> pure ()
    Just () -> void $ forkIO $ do
      result <- (Right <$> pomoHabits env) `catch` (\(e :: SomeException) -> pure (Left e))
      case result of
        -- keep the last good titles: an offline bar still knows the name
        Right m -> modifyIORef' (prTitles refs) (M.union m)
        Left e -> hPutStrLn stderr ("pomotask: habits fetch failed: " ++ show e)
      pomoNowMs >>= writeIORef (prTitlesAt refs)
      void (tryPutMVar (prFetchGate refs) ())

-- The server broadcasts every client's message verbatim to that user's other
-- clients, including the sender, so a stop from rofi, the phone or the web app
-- arrives as a raw timer:stop carrying no data. Our state has to normalise to
-- stopped the same way the server does, or the label keeps counting.
pomoApplyMessage :: PomoVar -> PomoRefs -> BS.ByteString -> IO ()
pomoApplyMessage env refs raw = case eitherDecode (BL.fromStrict raw) of
  Right (Object o) -> case pomoAt "type" o of
    Just (String t)
      | t == "timer:sync" || t == "timer:update" -> pomoMergeData refs o
      | t == "timer:stop" -> do
          writeIORef (prTimer refs) emptyPomoTimer
          pomoMergeData refs o
      | t == "pong" -> pure ()
      | otherwise -> pure ()
    _ -> pure ()
  Right _ -> pure ()
  Left _ -> pure ()

pomoMergeData :: PomoRefs -> Object -> IO ()
pomoMergeData refs o = case pomoAt "data" o of
  Just (Object d) -> modifyIORef' (prTimer refs) (pomoApply d)
  _ -> pure ()

pomoHandleFrame :: PomoVar -> PomoRefs -> PomoConn -> Bool -> Word8 -> BS.ByteString -> IO ()
pomoHandleFrame env refs pc fin opcode payload = do
  now <- pomoNowMs
  writeIORef (prLastMsg refs) now
  case opcode of
    0x8 -> ioError (userError "pomotask: server closed the websocket")
    -- reply to a control ping even though the protocol uses an app-level one
    0x9 -> NC.connectionPut (pcConn pc) =<< pomoEncodeFrame 0xa payload
    0xa -> pure ()
    0x1 -> pomoHandleText env refs pc fin payload
    0x0 -> pomoHandleText env refs pc fin payload
    _ -> pure ()

pomoHandleText :: PomoVar -> PomoRefs -> PomoConn -> Bool -> BS.ByteString -> IO ()
pomoHandleText env refs pc fin payload = do
  text <- pomoTextPart pc fin payload
  unless (BS.null text) $ do
    pomoApplyMessage env refs text
    pomoFetchTitles env refs False

-- The read is what paces the loop: while a timer runs the wait is one second
-- (a redraw has to happen anyway), and while idle it is only as long as it
-- takes to owe a ping or to declare the socket dead. No timer, no waking.
pomoWaitMs :: PomoTimer -> PomoRefs -> IO Int
pomoWaitMs st refs = do
  now <- pomoNowMs
  lastPing <- readIORef (prLastPing refs)
  lastMsg <- readIORef (prLastMsg refs)
  let candidates =
        pomoTickMs
          : [ pomoPingMs - (now - lastPing),
              pomoSilenceMs - (now - lastMsg)
            ] ++ [pomoTickMs | pomoRunning st]
  pure (max 1 (minimum candidates))

pomoStep :: PomoVar -> PomoRefs -> PomoConn -> IO ()
pomoStep env refs pc = do
  st <- readIORef (prTimer refs)
  buffered <- (not . BS.null) <$> readIORef (pcBuf pc)
  got <-
    if buffered
      then pure True
      else do
        wait <- pomoWaitMs st refs
        NC.connectionWaitForInput (pcConn pc) wait
  when got $ do
    (fin, opcode, payload) <- pomoRecvFrame pc
    pomoHandleFrame env refs pc fin opcode payload
  when (not got) $ do
    now <- pomoNowMs
    lastPing <- readIORef (prLastPing refs)
    when (now - lastPing >= pomoPingMs) $ do
      writeIORef (prLastPing refs) now
      NC.connectionPut (pcConn pc) =<< pomoEncodeFrame 0x01 pomoPingPayload
    lastMsg <- readIORef (prLastMsg refs)
    when (now - lastMsg >= pomoSilenceMs) $
      ioError (userError "pomotask: no server traffic, reconnecting")
  pomoRender refs

pomoConnected :: PomoVar -> PomoRefs -> PomoConn -> IO ()
pomoConnected env refs pc = do
  now <- pomoNowMs
  writeIORef (prLastMsg refs) now
  writeIORef (prLastPing refs) now
  pomoFetchTitles env refs True
  pomoRender refs
  forever (pomoStep env refs pc)

-- Any exception ends the connection: the read path turns EOF into an error,
-- framing corruption throws from the TLS layer, and a half-open socket is
-- detected by pomoWaitMs going silent. Every reconnect re-syncs the timer from
-- the server's timer:sync, so a lost frame can never leave the label wrong.
pomoSupervisor :: PomoVar -> PomoRefs -> IO ()
pomoSupervisor env refs = pomoLoop pomoRetryMs
  where
    pomoLoop backoffMs = do
      openedAt <- pomoNowMs
      outcome <-
        try
          ( pomoOpenWs (pvCtx env) (pvEndpoint env) (pvKey env)
              >>= pomoConnected env refs
          ) ::
          IO (Either SomeException ())
      case outcome of
        Left err -> hPutStrLn stderr ("pomotask: " ++ show err)
        Right () -> pure ()
      now <- pomoNowMs
      -- a long-lived connection that then dropped is a normal drop, not a
      -- endpoint problem, so the retry clock restarts at the floor
      let next = if now - openedAt > 10000 then pomoRetryMs else min pomoMaxBackoffMs (backoffMs * 2)
      threadDelay (next * 1000)
      pomoLoop next

-- A click sends its own short-lived connection: the loop thread owns the
-- long-lived one and blocking in its read is exactly what keeps the bar idle,
-- so writes are not routed through it.
pomoSend :: PomoVar -> ByteString -> IO ()
pomoSend env payload = do
  outcome <- (Right <$> pomoSendOnce) `catch` (\(e :: SomeException) -> pure (Left e))
  case outcome of
    Right () -> pure ()
    Left err -> do
      -- one retry a second apart: the prod nginx sometimes 301s mid-reload and
      -- the rofi backend found its first attempt after every reload failing
      hPutStrLn stderr ("pomotask: send failed, retrying: " ++ show err)
      threadDelay 1000000
      catchAny pomoSendOnce (\e -> hPutStrLn stderr ("pomotask: send failed: " ++ show e))
  where
    pomoSendOnce = do
      pc <- pomoOpenWs (pvCtx env) (pvEndpoint env) (pvKey env)
      NC.connectionPut (pcConn pc) =<< pomoEncodeFrame 0x01 payload
      -- the server relays on receipt; closing immediately risks a reset before
      -- the peer has read, which would drop a stop with no error anywhere
      threadDelay 150000
      catchAny (NC.connectionClose (pcConn pc)) (\_ -> pure ())

pomoStop :: PomoVar -> PomoRefs -> IO ()
pomoStop env refs = do
  st <- readIORef (prTimer refs)
  when (pomoRunning st) $ void $ forkIO (pomoSend env pomoStopPayload)

pomoAdjust :: PomoVar -> PomoRefs -> Int -> IO ()
pomoAdjust env refs shiftMs = do
  st <- readIORef (prTimer refs)
  when (pomoRunning st) $ do
    now <- pomoNowMs
    void $ forkIO (pomoSend env (pomoShiftPayload st shiftMs now))

-- Click 1 stops the timer, click 3 opens the rofi task picker. Scroll is
-- +/-1 minute: the way the phone app corrects a timer you started late.
--
-- The module is hidden while idle, so click 3 is only reachable with a timer
-- running; the picker itself is on MODKEY+p/z in dwm for starting one.
pomotaskWidget :: TaffyIO Gtk.Widget
pomotaskWidget = do
  box <- liftIO Gtk.eventBoxNew
  _ <- widgetSetClassGI box "module"
  _ <- widgetSetClassGI box "pomotask"
  label <- liftIO $ Gtk.labelNew (Just T.empty)
  inner <- liftIO $ padded label
  liftIO $ do
    Gtk.containerAdd box inner
    Gtk.widgetShowAll box
    Gtk.widgetSetVisible box False
  -- referenced from both bar configs; pomoShared does the key-file read, the
  -- connection and the supervisor thread once, so the second monitor costs a
  -- label and a handler
  case pomoShared of
    Nothing -> Gtk.toWidget box
    Just (env, refs) -> do
      gui <- liftIO $ PomoGui <$> Gtk.toWidget box <*> pure label
      liftIO $ pomoAttach gui refs
      liftIO $ do
        -- deliberately no addWorkspaceScroll: scroll adjusts the timer, and
        -- the first handler installed on the box would win the event and turn
        -- the scroll into a workspace switch instead
        Gtk.widgetAddEvents box [Gdk.EventMaskScrollMask]
        void $ Gtk.onWidgetScrollEvent box $ \event -> do
          step <- scrollStep event
          case step of
            Just True -> pomoAdjust env refs 60000 >> pure True
            Just False -> pomoAdjust env refs (-60000) >> pure True
            Nothing -> pure False
        void $ Gtk.onWidgetButtonPressEvent box $ \event -> do
          button <- GdkButton.getEventButtonButton event
          case button of
            1 -> pomoStop env refs
            3 -> void $ forkIO (void (spawnCommand pomotaskLauncher) :: IO ())
            _ -> pure ()
          pure True
      Gtk.toWidget box

-- polypomo stays as it is: a local pomodoro with its own sqlite history and
-- socket actions, which the bar only ever tails.
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

-- Hyprland 0.56.2 parses the remainder of `dispatch <rest>` as Lua when the config
-- is Lua, so the documented `dispatch workspace m+1` is a Lua syntax error there —
-- hyprctl fails it too. Measured both ways: the live session (Lua config) takes
-- only `hl.dsp.focus({workspace="m+1"})`; the nested harness (hyprlang config)
-- takes only the legacy form and answers "Invalid dispatcher" to the Lua one. So
-- try both and remember the one that answers ok. Pure so
-- tests/taffybar-workspace-filter can pin the bytes.
workspaceSwitchForms :: Bool -> [[String]]
workspaceSwitchForms previous = [["dispatch", luaCall], ["dispatch", "workspace", step]]
  where
    step = if previous then "m-1" else "m+1"
    luaCall = "hl.dsp.focus({workspace=\"" ++ step ++ "\"})"

-- | Remembered index into `workspaceSwitchForms` for this session.
{-# NOINLINE dispatchFormRef #-}
dispatchFormRef :: IORef Int
dispatchFormRef = unsafePerformIO (newIORef 0)

-- | Fire the first dispatch spelling Hyprland answers `ok` to, and cache which
-- index that was so later scrolls cost one round trip. The command socket replies
-- `ok` even when its own Lua snippet rejected the command, so ok-ness is decided
-- by prefix here rather than by the socket succeeding.
dispatchWorkspace :: HyprlandClient -> Bool -> IO ()
dispatchWorkspace client previous = go 0 (workspaceSwitchForms previous)
  where
    go _ [] = pure ()
    go i (form:rest) = do
      reply <- runHyprlandCommandRaw client (hyprCommand form)
      if replyIsOk reply
        then do
          writeIORef dispatchFormRef i
          barLog ("dispatch form " ++ show i ++ " accepted: " ++ dispatchReplyText reply)
        else do
          barLog ("dispatch form " ++ show i ++ " refused: " ++ dispatchReplyText reply)
          go (i + 1) rest

replyIsOk :: Either HyprlandError ByteString -> Bool
replyIsOk (Left _) = False
replyIsOk (Right out) = BS.isPrefixOf "ok" out

dispatchReplyText :: Either HyprlandError BS.ByteString -> String
dispatchReplyText (Left err) = "left " ++ show err
dispatchReplyText (Right out)
  | BS.isInfixOf "error:" out = "rejected: " ++ show (BS.take 160 out)
  | otherwise = "ok " ++ show (BS.take 40 out)

-- The wheel arrives differently per backend: X11 (dwm) turns it into a discrete
-- scroll event, Hyprland into a smooth one whose direction field comes back
-- ScrollDirectionSmooth. So a handler that matches only Up/Down switches
-- workspaces under dwm and silently does nothing under Hyprland. Just True =
-- wheel up, Just False = wheel down.
smoothStep :: Double -> Double -> Maybe Bool
smoothStep dx dy
  | abs dy < abs dx = Nothing -- a mostly-sideways swipe is not a wheel step
  | dy < 0 = Just True
  | dy > 0 = Just False
  | otherwise = Nothing

-- A wheel notch under Hyprland arrives as *two* scroll events, measured back to
-- back: a discrete one (ScrollDirectionDown, dy=0) and a smooth one
-- (ScrollDirectionSmooth, dy=1.5). Acting on both switches two workspaces per
-- notch. X11 sends discrete only, so discrete is the canonical spelling and
-- smooth is only trusted while no discrete event has been seen — a touchpad, or a
-- compositor that never sends axis_discrete.
{-# NOINLINE sawDiscreteScroll #-}
sawDiscreteScroll :: IORef Bool
sawDiscreteScroll = unsafePerformIO (newIORef False)

scrollStep :: GdkScroll.EventScroll -> IO (Maybe Bool)
scrollStep event = do
  direction <- GdkScroll.getEventScrollDirection event
  case direction of
    Gdk.ScrollDirectionUp -> discreteStep (Just True)
    Gdk.ScrollDirectionLeft -> discreteStep (Just True)
    Gdk.ScrollDirectionDown -> discreteStep (Just False)
    Gdk.ScrollDirectionRight -> discreteStep (Just False)
    Gdk.ScrollDirectionSmooth -> do
      discreteSeen <- readIORef sawDiscreteScroll
      if discreteSeen
        then pure Nothing
        else do
          dx <- GdkScroll.getEventScrollDeltaX event
          dy <- GdkScroll.getEventScrollDeltaY event
          pure (smoothStep dx dy)
    _ -> pure Nothing
  where
    discreteStep step = writeIORef sawDiscreteScroll True >> pure step

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
      step <- scrollStep event
      direction <- GdkScroll.getEventScrollDirection event
      dy <- GdkScroll.getEventScrollDeltaY event
      liftIO $ barLog ("scroll dir=" ++ show direction ++ " dy=" ++ show dy ++ " -> " ++ show step)
      case step of
        Just previous -> switchWorkspace previous
        Nothing -> pure False
  where
    switchWorkspace previous =
      catchAny
        ( do
          client <- tryReadMVar hyprClientVar
          case client of
            Just hyprland -> dispatchWorkspace hyprland previous
            Nothing ->
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
          step <- scrollStep event
          case step of
            Just True -> spawnCommand upAction >> pure True
            Just False -> spawnCommand downAction >> pure True
            Nothing -> pure False
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
