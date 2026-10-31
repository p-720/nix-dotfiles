--
module Layouts where

import XMonad
import DragSplit (dragSplit)
import XMonad.Hooks.ManageDocks
import XMonad.Layout.BoringWindows
import XMonad.Layout.Minimize
import XMonad.Layout.NoBorders
import XMonad.Layout.PerWorkspace
import XMonad.Layout.SimplestFloat (simplestFloat)
import XMonad.Layout.Tabbed
import XMonad.Layout.ThreeColumns

myTabConfig =
  def
    { activeColor = "#556064",
      inactiveColor = "#2F3D44",
      urgentColor = "#FDF6E3",
      activeBorderColor = "#454948",
      inactiveBorderColor = "#454948",
      urgentBorderColor = "#268BD2",
      activeTextColor = "#80FFF9",
      inactiveTextColor = "#1ABC9C",
      urgentTextColor = "#1ABC9C",
      fontName = "xft:Noto Sans CJK:size=10:antialias=true"
    }

modifiers = lessBorders Screen . avoidStrutsOn [D] . (minimize . boringAuto)

-- separate binding on purpose: no signature + monomorphism restriction means
-- each modifiers* alias pins one concrete layout type
modifiersFfTg = lessBorders Screen . avoidStrutsOn [D] . (minimize . boringAuto)

-- hyprland ran the master layout (mfact 0.70, master on the left);
-- Tall is the same shape, mirror tiled flips it for emacs-style frames.
-- workspace 11 is hyprland's "ff-tg": firefox 20% on the left, telegram
-- taking the larger slice of the rest
-- the corner handle drags the split, so a corner resize stays tiled and
-- the neighbouring window reflows instead of leaving a hole
myLayout =
  dragSplit $
    onWorkspace "1_11" (modifiersFfTg (ThreeCol 1 delta 0.2 ||| Full)) $
      modifiers (tiled ||| Mirror tiled ||| tabbedBottom shrinkText myTabConfig ||| simplestFloat)
        ||| Full
  where
    tiled = Tall nmaster delta ratio

    nmaster = 1
    ratio = 0.70
    delta = 3 / 100
