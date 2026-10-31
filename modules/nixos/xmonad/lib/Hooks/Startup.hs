-- |
module Hooks.Startup where

import Data.Foldable
import XMonad
import qualified XMonad.StackSet as W
import XMonad.Util.SpawnOnce
import XMonad.Actions.SpawnOn

myStartupHook =
  spawnAllOnce
    [ "pasystray",
      "dunst",
      -- must own org.kde.StatusNotifierWatcher before taffybar's SNI tray
      -- widget starts; without it taffybar crashes in SNITray.hs. cache
      -- cleared first: stale item bus names from a dead session make the
      -- watcher hand out bad object paths and kill the tray build again
      "rm -f ~/.cache/status-notifier-item/*.json; status-notifier-watcher",
      -- supervisor loop, not bare spawn: retries the tray before the
      -- watcher owns the name and survives a later taffybar crash. exits
      -- when X goes away so a dead session can't leave a spinner behind
      "while xset q >/dev/null 2>&1; do taffybar; sleep 2; done",
      "flameshot",
      "blueman-applet"
    ]

spawnAllOnce xs =
  forM_ xs spawnOnce
