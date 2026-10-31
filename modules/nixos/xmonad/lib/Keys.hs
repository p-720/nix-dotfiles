{-# OPTIONS_GHC -Wno-deferred-out-of-scope-variables #-}

module Keys where

import Data.List (find)
import qualified Data.Map as M
import Data.Map.Merge.Lazy
import qualified Debug.Trace as Debug
import Hooks.Specials (specialSites, toggleSpecial)
import DragSplit (splitResize)
import Scratchpads (myScratchpads)
import Workspaces
import XMonad
import XMonad.Actions.AfterDrag
import XMonad.Actions.CopyWindow (copy, killAllOtherCopies)
import XMonad.Actions.CycleRecentWS
import XMonad.Actions.CycleWS (nextWS, prevWS, shiftToNext, shiftToPrev)
import XMonad.Actions.FloatSnap
import XMonad.Actions.Minimize
-- import XMonad.Actions.MouseGestures
import XMonad.Actions.OnScreen (greedyViewOnScreen, viewOnScreen)
import XMonad.Actions.Submap
import qualified XMonad.Layout.BoringWindows as BW
import XMonad.Layout.IndependentScreens
import qualified XMonad.Prelude as L
import qualified XMonad.StackSet as W
import XMonad.Util.EZConfig
import XMonad.Util.NamedScratchpad
import XMonad.Util.Run

sendMouseClickToWindow :: Window -> X ()
sendMouseClickToWindow win =
  safeSpawn
    "xdotool"
    ["click", "--window", show win, show button2]

-- mod+RMB on a tiled window drags the split like hyprland: the grabbed
-- window grows in the drag direction and the neighbour reflows, no floating
resizeWithModRmb :: Window -> X ()
resizeWithModRmb w = do
  floatingWin <- gets (M.member w . W.floating . windowset)
  if floatingWin
    then focus w >> mouseResizeWindow w >> ifClick (snapMagicResize [R, D] (Just 50) (Just 50) w)
    else do
      inMaster <- gets (maybe False ((== w) . head . W.integrate) . W.stack . W.workspace . W.current . windowset)
      screenWidth <- gets (rect_width . screenRect . W.screenDetail . W.current . windowset)
      focus w
      splitResize (fromIntegral screenWidth * 3 `div` 100) inMaster

myMouseBindings XConfig {XMonad.modMask = modm} =
  M.fromList
    -- mod-button1, Set the window to floating mode and move by dragging
    [ ((modm, button1), \w -> focus w >> mouseMoveWindow w >> ifClick (snapMagicMove (Just 50) (Just 50) w)),
      ((modm, button3), resizeWithModRmb),
      ((modm, button4), \w -> focus w >> windows W.focusDown),
      ((modm .|. mod1Mask, button4), \w -> focus w >> windows W.swapDown),
      ((modm .|. mod1Mask, button5), \w -> focus w >> windows W.swapUp),
      ((modm, button5), \w -> focus w >> windows W.focusUp)
    ]

functionKeys =
  [ ("<XF86AudioRaiseVolume>", spawn "pactl set-sink-volume @DEFAULT_SINK@ +10%"),
    ("<XF86AudioLowerVolume>", spawn "pactl set-sink-volume @DEFAULT_SINK@ -10%"),
    ("<XF86AudioMute>", spawn "pactl set-sink-mute @DEFAULT_SINK@ toggle"),
    ("<XF86AudioMicMute>", spawn "pactl set-source-mute @DEFAULT_SOURCE@ toggle"),
    ("<XF86MonBrightnessUp>", spawn "brightnessctl s +10%"),
    ("<XF86MonBrightnessDown>", spawn "brightnessctl s 10%-"),
    ("<XF86AudioPlay>", spawn "playerctl play-pause"),
    ("<XF86AudioPause>", spawn "playerctl play-pause"),
    ("<XF86AudioNext>", spawn "playerctl next"),
    ("<XF86AudioPrev>", spawn "playerctl previous")
  ]

screenshotAndRecordKeys =
  [ ("<Print>", spawn "flameshot gui --delay=1000"),
    ("C-<Print>", spawn "fish -c 'flameshot full -c'"),
    ("S-<Print>", spawn "fish -c 'flameshot_screen'"),
    ("C-S-<Print>", spawn "sh -c '~/.config/i3/screenshot_window.sh activewindow'"),
    ("<Scroll_Lock>", spawn "fish -c 'record_screen_replay_sound'"),
    ("S-<Scroll_Lock>", spawn "fish -c 'trim_last_replay'"),
    ("C-<Scroll_Lock>", spawn "fish -c 'copy_last_replay'"),
    ("C-S-<Scroll_Lock>", spawn "fish -c 'record_screen_replay_sound_stop'"),
    ("<Pause>", spawn "fish -c 'record'"),
    ("S-<Pause>", spawn "fish -c 'trim_video_from_clipboard'"),
    ("C-S-u", spawn "fish -c 'shorten-url'")
  ]

keysP =
  functionKeys
    ++ screenshotAndRecordKeys
    ++ [
         -- hyprland binds SUPER+Return and SUPER+Q both to the terminal
         ("M-<Return>", spawn "/etc/nixos/bin/xterm-foot"),
         ("M-q", spawn "/etc/nixos/bin/xterm-foot"),
         -- hyprland puts reload on SUPER+SHIFT+R; this also replaces the
         -- xmonad default mod-q action that SUPER+Q just took over
         ("M-S-r", spawn "xmonad --recompile && xmonad --restart"),
         ("M-E", spawn "nautilus"),
         ("M-d", spawn "~/.config/rofi/launchers/colorful/launcher.sh"),
         ("M-P", spawn "~/.config/rofi/launchers/colorful/pomotask.sh"),
         ("M-bracketright", spawn "~/.config/polybar/light_control.sh"),
         ("M-f", toggleFull),
         -- hyprland: resize to the monitor and center, leaving the bar visible
         ("M-bracketleft", withFocused $ \w -> windows $ \sw -> W.float w (W.RationalRect 0 0 1 0.97) sw),
         -- hyprland: pin, i.e. copy this window to every workspace
         ("M-period", windows $ \sw -> foldr copy sw myWorkspaces),
         ("M-S-l", spawn "i3lock -c 000000"),
         ("M-c", namedScratchpadAction myScratchpads "calc"),
         ("M-M1-t", namedScratchpadAction myScratchpads "chat"),
         ("<F12>", namedScratchpadAction myScratchpads "term"),
         -- hyprland special workspaces
         ("M-s", namedScratchpadAction myScratchpads "default"),
         ("M-n", namedScratchpadAction myScratchpads "emacs"),
         ("M-x", kill),
         ("M-j", windows W.focusDown),
         ("M-k", windows W.focusUp),
         ("M-r", submap resizeSubmap),
         ("M-z", withLastMinimized' toggleMaximization),
         ("M-t", withFocused toggleFloat),
         ("M-e", spawn "emacsclient --eval \"(emacs-everywhere)\""),
         ("M-S-n", spawn "emacsclient --eval \"(emacs-everywhere-note)\""),
         ("M-a", windows copyToSecondScreen),
         ("M-S-a", killAllOtherCopies),
         -- supervisor loop in Startup.hs respawns it
         ("M-S-t", spawn "pkill taffybar")
       ]
    ++ specialKeys

-- hyprland special workspaces, same keys
specialKeys =
  [ (key, toggleSpecial name url)
    | ((name, url), key) <-
        zip specialSites ["M-g", "M-o", "M-u", "M-i", "M-b", "M-m"]
  ]

-- hyprland SUPER+F fullscreens the focused window; here that is the Full
-- layout, and pressing again drops back to whichever layout was before
toggleFull = do
  desc <- gets (description . W.layout . W.workspace . W.current . windowset)
  if desc == "Full"
    then sendMessage NextLayout
    else sendMessage (JumpToLayout "Full")

shiftThenView i = W.view i . W.shift i

-- hyprland's resize submap: no modifiers, arrows or hjkl grow/shrink,
-- any unbound key (Esc) drops out of it
resizeSubmap =
  M.fromList
    [ ((0, xK_Right), sendMessage Expand),
      ((0, xK_l), sendMessage Expand),
      ((0, xK_Left), sendMessage Shrink),
      ((0, xK_h), sendMessage Shrink),
      ((0, xK_Down), sendMessage (IncMasterN 1)),
      ((0, xK_j), sendMessage (IncMasterN 1)),
      ((0, xK_Up), sendMessage (IncMasterN (-1))),
      ((0, xK_k), sendMessage (IncMasterN (-1)))
    ]

screenShiftThenView :: PhysicalWorkspace -> WindowSet -> WindowSet
screenShiftThenView i = viewOnScreen (unmarshallS i) i . W.shift i

screenView i =
  viewOnScreen (unmarshallS i) i -- < https://xmonad.github.io/xmonad-docs/xmonad-contrib/XMonad-Actions-OnScreen.html

-- hyprland: SUPER+<n> views n on the monitor that owns it (1-6 left, 7-12 right)
workspaceKeys = [xK_1 .. xK_9] ++ [xK_0, xK_minus, xK_equal]

windowsKeysForSwitchingAndMovingOnWorkspaces =
  [ ((m .|. mod4Mask, k), windows $ f i)
    | (i, k) <- zip myWorkspaces workspaceKeys,
      (f, m) <- [(screenView, 0), (screenShiftThenView, shiftMask)]
  ]

monitorsKeysForSwitchingAndMoving =
  [ ((m .|. mod4Mask, key), screenWorkspace sc >>= flip whenJust (windows . f))
    | (key, sc) <- zip [xK_h, xK_l] [0 ..],
      (f, m) <- [(W.view, 0), (shiftThenView, mod1Mask)]
  ]

-- hyprland: ALT+SUPER+1/0 send the current workspace to monitor 0, 2/9 to 1
moveWorkspaceToScreen s ws = viewOnScreen s (W.currentTag ws) ws

workspaceToScreenKeys =
  [ ((mod4Mask .|. mod1Mask, key), windows $ moveWorkspaceToScreen sc)
    | (key, sc) <- [(xK_1, 0), (xK_0, 0), (xK_2, 1), (xK_9, 1)]
  ]

windowSnappingKeys =
  [ ((mod4Mask, xK_Left), withFocused $ snapMove L Nothing),
    ((mod4Mask, xK_Right), withFocused $ snapMove R Nothing),
    ((mod4Mask, xK_Up), withFocused $ snapMove U Nothing),
    ((mod4Mask, xK_Down), withFocused $ snapMove D Nothing)
  ]

keys =
  windowsKeysForSwitchingAndMovingOnWorkspaces
    ++ monitorsKeysForSwitchingAndMoving
    ++ workspaceToScreenKeys
    ++ windowSnappingKeys
    ++ [ ((mod4Mask .|. mod1Mask, xK_j), windows W.swapDown),
         ((mod4Mask .|. mod1Mask, xK_k), windows W.swapUp),
         ((mod4Mask, xK_Tab), nextWS),
         ((mod4Mask .|. shiftMask, xK_Tab), prevWS)
       ]

toggleMaximization :: Maybe Window -> X ()
toggleMaximization window =
  case window of
    Nothing -> withFocused minimizeWindow
    Just w -> maximizeWindowAndFocus w

toggleFloat w =
  windows
    ( \s ->
        if M.member w (W.floating s)
          then W.sink w s
          else W.float w (W.RationalRect 0.15 0.15 0.65 0.65) s
    )

-- every window also gets a copy on the second monitor's workspaces
copyToSecondScreen s =
  foldr copy s (filter ((== 1) . unmarshallS) myWorkspaces)

myKeys :: XConfig a -> XConfig a
myKeys c =
  c {mouseBindings = myMouseBindings}
    `additionalKeysP` Keys.keysP
      `additionalKeys` Keys.keys
      `removeKeysP` ["<Insert>"]
