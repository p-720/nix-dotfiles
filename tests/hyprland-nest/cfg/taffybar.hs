{-# LANGUAGE OverloadedStrings #-}

-- Probe config for tests/hyprland-nest, NOT the user's bar.
--
-- One workspaces widget and a clock, bottom, 30px exact. Deliberately minimal:
-- the real config needs a live SNI tray host, PipeWire/WirePlumber, a network
-- reachable wttr.in and this repo's python favicon helper, and it dies on the
-- tray's pattern-match failure the moment any of that is missing. A bar that
-- cannot start cannot be asserted on.
--
-- Only the workspace strip varies with compositor state, so a crop of its left
-- edge is the screenshot signal; the clock sits centred, outside that crop.

module Main (main) where

import qualified GI.Gtk as Gtk
import System.Taffybar.Context (TaffyIO)
import System.Taffybar.SimpleConfig
import System.Taffybar.Widget

main :: IO ()
main = simpleDyreTaffybar probeConfig

probeConfig :: SimpleTaffyConfig
probeConfig =
  defaultSimpleTaffyConfig
    { barHeight = ExactSize 30,
      barPadding = 0,
      barPosition = Bottom,
      widgetSpacing = 8,
      monitorsAction = useAllMonitors,
      startWidgets = [workspacesProbe, clockProbe],
      centerWidgets = [],
      endWidgets = []
    }

workspacesProbe :: TaffyIO Gtk.Widget
workspacesProbe = workspacesNew defaultWorkspacesConfig

clockProbe :: TaffyIO Gtk.Widget
clockProbe = textClockNewWith defaultClockConfig
