# TODO

## Goal

Make taffybar look like waybar and carry the same modules that have taffybar equivalents, including the custom modules, with per-monitor layouts.

## Tasks

### 1. Taffybar module layout

- [x] Rewrite `modules/nixos/taffybar/taffybar.hs` with per-monitor configs.
- [x] Primary monitor (LG): workspaces, idle inhibitor, memory / gcal, clock / pomotask, polypomo, weather, pulseaudio.
- [x] Secondary monitor (AOC): workspaces, idle inhibitor, memory, disk / gcal, clock / pomotask, pulseaudio, tray.
- [x] Remove the static "DONT FORGET TO START THE EMACS TIMER" label.
- [x] Skip waybar modules with no taffybar widget: submap, Hyprland language, pulseaudio slider.

### 2. Port custom modules

- [x] Add an adapter script that runs `waybar_gcal.sh` and emits Pango markup with waybar's now/none colors.
- [x] Wrap `polybar-pomotask.py` in a streaming label; left click runs `--stop`.
- [x] Wrap polypomo in a streaming label; left click toggles, right ends, middle/scroll adjust time.
- [x] Use the built-in wttr.in widget with waybar's Moscow format and a 10 minute interval.

### 3. Style

- [x] Replace `modules/nixos/taffybar/taffybar.css` with the waybar look: 16px ShureTechMono Nerd Font, black 50% bar, 30px height, no outer margin/rounding.
- [x] Workspaces: transparent buttons, 3px 10px padding, active `#51afef`, urgent `#7bc275`, hover `#5cEfFF`, dark text on those states.
- [x] Module blocks: real 12px interior padding; memory `#9b59b6`, disk `#964B00`, pomotask `#313244`, others transparent.
- [x] Dark tooltip with green border and 15px text.

### 4. Verify

- [x] Rebuild/restart taffybar with dyre, check compile and runtime logs.
- [x] Confirm bars on both monitors, module presence, and pixel colors with screenshots.
- [x] Restore the xmonad supervisor loop after testing.

### 5. Review

- [ ] Run a full quality pass for compile/runtime issues, missing classes, and leftover dead config.

## Extras

- [x] Switch audio from the legacy PulseAudio widget to the unified Audio widget (WirePlumber/PipeWire).
- [x] Add tray icon spacing.
- [x] Scroll over any part of the bar switches workspaces.

## Notes

- Taffybar 7.4.4 from the flake input, X11/xmonad session.
- Primary monitor is DP-0 (2560x1080), secondary is HDMI-0 (1920x1080).
- The gotham palette import will be dropped; waybar colors replace it.
- Inactive waybar custom modules (`emacs_todo`, `claude`, `wireguard`, `bluetooth`) are not in the active bars and are not ported.
