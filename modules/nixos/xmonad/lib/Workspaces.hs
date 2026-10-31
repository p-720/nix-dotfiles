-- |

module Workspaces where
import XMonad.Layout.IndependentScreens
import Data.List (nub)

-- mirrors hyprland: 1-6 on DP-0, 7-12 on HDMI-0
myWorkspaces :: [PhysicalWorkspace] -- < i.e 1_1 1_2 1_3
myWorkspaces =
  withScreen 0 ["1", "2", "3", "4", "5", "6"]
    ++ withScreen 1 ["7", "8", "9", "10", "11", "12"]

myWorkspaces' :: [VirtualWorkspace] -- < i.e 1 2 3 4 5
myWorkspaces' = nub $ map unmarshallW myWorkspaces
