-- |

module Scratchpads where
import XMonad.Util.NamedScratchpad
import XMonad
import XMonad.Hooks.ManageHelpers
import qualified XMonad.StackSet as W

myScratchpads =
  [ NS "calc" "speedcrunch" (className =? "SpeedCrunch") (doRectFloat (W.RationalRect 0.8 0.20 0.2 0.6)),
    NS "chat" "chatterino" (className =? "chatterino") (doRectFloat (W.RationalRect 0.85 0.20 0.15 0.6)),
    -- hyprland special:alacritty (F12). bin/xterm-foot styles xterm like the
    -- foot config; its own class so normal terminals are never adopted
    NS
      "term"
      "/etc/nixos/bin/xterm-foot -name scratchpad-term -class ScratchpadTerm"
      (className =? "ScratchpadTerm")
      (doRectFloat (W.RationalRect 0.1 0.1 0.8 0.8)),
    -- hyprland special:emacs (M-n): named frame so the hook finds it again
    NS "emacs" "emacsclient -c -F '((name . \"emacs-todo\"))'" (title =? "emacs-todo") (doRectFloat (W.RationalRect 0.02 0.03 0.96 0.94)),
    -- hyprland special:default (M-s) held qbittorrent
    NS "default" "qbittorrent" (className =? "qBittorrent") (doRectFloat (W.RationalRect 0.04 0.07 0.92 0.86))
  ]
