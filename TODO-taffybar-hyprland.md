# TODO: taffybar as the Hyprland bar (waybar retires on this box)

## Goal

One bar, one config, two sessions: taffybar draws under dwm on X11 exactly as it
does today, and under Hyprland it draws the same bar with Hyprland's own
workspaces — per-monitor, firefox favicons and all. No waybar in the hyprland
session on this host.

## Decisions taken (from the user)

- taffybar replaces waybar on hyprland; **only** the workspace module differs, every
  other module stays as it is on dwm.
- keep the `hyprland` module's firefox-icon behaviour (favicon per tab, per-workspace icon
  strip), i.e. the widget we already have, not waybar's `wlr/workspaces`.
- one binary, one `taffybar.hs`, backend chosen at runtime by the library's own detection;
  each session *forces* its backend so a silent mis-detection is impossible.
- per-monitor workspace split follows **compositor geometry**, not monitor id, not GDK index.
- bar launch moves from a session-script loop (dwm) to a systemd user unit (hyprland),
  because Wayland gives the bar no session script to loop off.
- nested-Hyprland harness first, before trusting any claim about how the bar behaves there.

## Facts established (measured, not assumed)

- taffybar 7.4.4 (our flake overlay) has a Wayland backend: gtk-layer-shell, namespace
  `taffybar`, and Hyprland-side widgets in `System.Taffybar.Hyprland` /
  `Information.Hyprland`. `defaultOnWorkspaceClick` already branches on `backend`.
- `gdk_display_get_primary_monitor` returns **NULL** on Wayland (GTK3 `gdkdisplay.c`), and
  GDK's Wayland monitor array is `wl_output` announcement order — it renumbers on hotplug.
  So neither "monitor 0" nor GDK's primary can decide which bar is the primary bar.
- live `hyprctl -j` on this box: `DP-5 id=1 x=0 2560x1080` holds workspaces 1–6 and
  `HDMI-A-3 id=0 x=2560 1920x1080` holds 7–12. **id order is the opposite of layout
  order**, which is exactly the trap geometry avoids.
- empty persistent workspaces DO appear in `hyprctl -j workspaces` (`windows:0`), so the
  library's provider gives us 1–6/7–12 buttons with nothing synthesized. Note `workspace=12`
  is only listed once it exists: `lua/conf/workspaces_and_monitors.lua` gives it
  `on_created_empty` but not `persistent=true`, unlike `configs/hypr/conf.d`.
- the harness (nested Hyprland 0.56.2 under labwc) proved one layer surface per output with
  `reserved:[0,0,0,30]` and real (non-black) pixels; the nested *parent* output is unusable,
  outputs must come from `hyprctl output create headless`. `tests/hyprland-nest/` now carries
  that harness with 11 assertions.
- **`barHeight = ExactSize 30` is not enough on layer-shell**: the probe bar came out 41 px
  and `hyprctl -j monitors` reserved 41, because GTK will not shrink the toplevel under the
  children's natural height (vendor CSS fonts + theme padding). A flattened CSS got it to
  exactly 30. The real CSS's number is measured in task 5.
- `ExecStart` cannot take `VAR=val` prefixes (systemd rejects them: "Neither a valid
  executable name nor an absolute path"), so the unit runs a `writeShellScript`; a bare
  assignment line inside that script would never reach the bar, hence `export`.
- `StartLimit*` are ignored in `[Service]` ("unknown key, ignoring") — they belong in `[Unit]`.
- this box builds as **`oldpc`** (`rebuild-default` → `#oldpc`), not `mysystem`; `mysystem`
  evaluation currently fails on `/mnt/md127/backup_arch/.ssh/id_rsa` (pre-existing, unrelated).
- Dyre does **not** prompt when stdin is not a tty: with a changed config it printed
  "Configuration changed. Recompiling" and launched. A failing *compile* still means a
  Restart=always loop, which is what `StartLimitBurst` bounds.
- `~/.config/taffybar/*` are out-of-store symlinks to `/etc/nixos`, so any bar started from
  the user's HOME (including test runs) runs the working-tree config. Watch that in tests.

## Tasks

### 1. Session branch in `taffybar.hs`

- [x] `sessionIsHyprland` from `asks backend` — the library's own decision, no env sniffing.
- [x] Hyprland plumbing section: parked `HyprlandClient` (widget constructors are `IO`, the
      client is only reachable from `TaffyIO`), workspace→monitor table kept by us, refreshed
      from the Hyprland event socket (`relevantWorkspaceEvent`) with a 15 s poll behind it.
- [x] `isPrimaryMonitor` branches: Wayland matches the bar's GDK monitor geometry against
      `hyprctl -j monitors` and calls layout `x == 0` primary; X11 keeps GDK's primary.
- [x] `barScopedWorkspaces` replaces the numeric-only filter: show a workspace when
      `table[workspace] == thisBar'sMonitor`, specials always hidden, and fall back to the old
      numeric split while the compositor has told us nothing yet.
- [x] `attachMonitorName` resolves each bar's monitor from its own window
      (`displayGetMonitorAtWindow` → geometry → name), retrying until the bar is realized.
- [x] bar-wide scroll uses `hyprctl dispatch workspace m±1` under Hyprland, EWMH
      `switchOneWorkspace` under X11 (same code path as before on X11).
- [x] `TAFFYBAR_LOG=1` stderr trail: backend, per-monitor geometry match, resolved bar
      monitor, and every fallback taken.

### 2. Filter logic proven against real 0.56.2 JSON

- [x] 21 assertions in `/tmp/filtcheck` (transcribed parse + matcher + filter) run against
      live `hyprctl -j monitors`/`workspaces`: parse, position match, reorder/hotplug, size
      fallback when scaled origins differ, no bogus match, primary 1–6, secondary 7–12,
      specials hidden, no overlap, live `moveworkspace` moves the button, unresolved-monitor
      and empty-table fall back to numeric. All pass.
- [x] The cases live in `tests/taffybar-workspace-filter/` (`./run.sh`, 23 assertions,
      fixtures are scrubbed `hyprctl -j` output from this box). It is a transcription of
      pure code in a `Main` module, so it documents intent rather than catching drift —
      README says which commit has to move with it.

### 3. CSS

- [x] Fixed the selectors that never matched: taffybar 7 puts the workspace state class on
      the contents box itself, so `.active .contents` needed an ancestor with `.active` and
      drew nothing — the active/urgent plate and its dark label were invisible. Now
      `.workspace-button box.active` (#51afef) / `box.urgent` (#7bc275), with the padding that
      gives the plate waybar's extent.
- [x] Focused-window marking: icons other than the focused one dim to `.55`, the focused one
      gets an inset `#51afef` underline.
- [x] No Wayland-only CSS needed: with the repo CSS loaded, the real config's bar
      reserves `[0,0,0,30]` on both outputs (measured; the probe's 41 px came from the
      probe's own font metrics, and an empty stylesheet also measures 30 here).

### 4. Service and session wiring

- [x] `modules.taffybar.waylandBar.enable` + `systemd.user.services.taffybar`
      (`ConditionEnvironment` `WAYLAND_DISPLAY` **and** `HYPRLAND_INSTANCE_SIGNATURE`,
      `Restart=always`, `RestartSec=2`, burst 10/60 s, `Requires` the SNI watcher,
      `GDK_BACKEND=wayland`, `GDK_PIXBUF_MODULE_FILE` from `pkgs.gdk-pixbuf`'s
      `2.10.0/loaders.cache`).
- [x] `GDK_BACKEND=x11` on the dwm launch prefix, so neither session can guess wrong.
- [x] Enabled on `oldpc` (this box) and `main`; `laptop` evaluates with the unit absent.
- [x] `configs/hypr/lua/conf/exec.lua` no longer launches waybar; `SUPER+ALT+B` now restarts
      `taffybar` (it restarted a unit that never existed).
- [x] harness `GDK_PIXBUF_MODULE_FILE` nuance recorded: that cache carries no PNG loader —
      PNG rides a built-in loader, so the var is about the *other* ten loaders.

### 5. Verification before the user rebuilds

- [x] `ghc -fno-code` with the deployed ghc env: clean (pre-existing deprecation warnings only).
- [x] nested harness + real config/CSS (`REAL=1 ./tests/hyprland-nest/harness.sh all`):
      **19 checks, 0 failures**, fresh cold dyred compile. Numbers below.
- [x] dwm regression on the `:2` Xvfb rig: geometry/strut/scroll/overlays identical on
      HEAD vs new; one real regression found and fixed (`multiMonitor`). Numbers below.
- [ ] user-side smoke test after `rebuild-default` + re-login (see checklist).

## Verification results

### Real config under nested Hyprland (`REAL=1 ./harness.sh all`, exit 0, 19/19)

- layer surfaces `x=0|1280 y=770 w=1280 h=30`, one per output, namespace `taffybar`; \
  `hyprctl -j monitors` reserves **`[0,0,0,30]` on both** — the bar is 30 px, as asked.
- the config's own trail, verbatim:
  ```
  taffybar: backend: wayland/hyprland
  taffybar: monitor 0 -> headless-1 x=0
  taffybar: monitor 1 -> headless-2 x=1280
  taffybar: bar monitor: headless-1
  taffybar: bar monitor: headless-2
  ```
  `no-bar-monitor-unresolved` (0 fallbacks taken), `no-workspace-refresh-failed`,
  `no-x11-exception-text` all pass.
- **the per-monitor filter, end to end**: `memory-plate-found` puts the `#9b59b6` module at
  col 338 (headless-1) / 251 (headless-2). `hyprctl dispatch moveworkspacetomonitor 6
  headless-2` → plate slides to 305 / 284, i.e. **33 px left on one bar and 33 px right on
  the other, symmetric, reversible**, with **0 s** latency (event socket, 15 s poll behind
  it). That is workspace 6's button crossing bars, measured.
- band pixels real (mean 10928 / 502 colours; 10759 / 530), `band-reacts-to-window` 3291 px
  on open, 9627 px on move. `polypomo-sqlite-untouched` before/after identical.
- stubs that were actually hit: `wpctl` (mic slider polls), `setpriv` (polypomo chain),
  `status-notifier-watcher` on a private bus for the tray. Not hit: `curl` (wttr), `python3`
  (favicon helper). `pomotask` hid itself for want of an API key, as designed.
- **those stubs bound what is proven**: `setpriv` stubbed ⇒ `polypomo` never ran ⇒ the
  untouched `time.sqlite` is a fact about the stub; `wpctl` stubbed ⇒ the sliders are empty
  troughs and a wrong argv would pass unseen; `systemd-inhibit` is exec'd by store path, so
  no PATH shim can intercept it; the tray only survives because a watcher was put on the
  private bus. Favicons, tray contents, wttr and pomotask with a real key stay live checks.
- reproduced four times (20:04, 20:11, 20:16, 20:22) with the dyred cache cleared each
  time; plate columns 338/251 → 305/284 identical across all four. The harness's readiness
  gate was fixed along the way — pixel stability cannot work while the clock ticks, so it
  now waits on the plate itself.

### dwm `:2` rig, HEAD vs new

| | bar window | strut | measured H | exact `#51afef` px | scroll click5/click4 |
|---|---|---|---|---|---|
| HEAD hs + HEAD css | 1553x30+0+770 DOCK+BELOW | bottom 30 | **30** | 1562 | switches at all 7 x probed |
| HEAD hs + new css | same | same | 30 | 1562 | unchanged |
| new hs + new css | 1328x30+0+770 | same | 30 | 1562 | switches over workspaces and over the clock |

- X11 never drifts to Wayland: `_GTK_LAYER_SHELL_SHELL_PROTOCOL` absent, zero
  layer-shell/wayland lines in any log, and the config logs `backend: x11`.
- overlays unchanged: after `super+c` the client is at `X=50` with `_DWM_SPECIAL_TAG=19`
  and absent from `_NET_CLIENT_LIST`; hiding moves it to `X=-2510` (moved, not unmapped).
  `F12`/alacritty could not be driven (xdotool F-key flakiness, per AGENTS.md).
- the only real pixel delta of the CSS rewrite is **icon dimming**: 455 of 12600 strip px,
  one icon slot, `(41,88,120)` → `(59,127,173)` = `0.55·icon + 0.45·plate`. `.inactive`,
  `.normal` and `.minimized` all reach `.window-icon`; the focused one stays full.
- **refuted by measurement**: the plate always drew — `.active .contents` matches, and
  `.contents.active` draws **0 px**, so the state class sits on a box that *wraps* the
  contents. `box.active` paints the identical 101x30 region, so the plate rewrite is a
  naming change, not a fix. An inset `#51afef` underline is invisible inside the active
  plate, hence `#2a2e38`.
- **real regression found and fixed**: `barScopedWorkspaces` narrowed the primary bar to
  `1-5` on a *single*-screen X11 session where HEAD showed `1-11`. Now gated on
  `multiMonitor`; `tests/taffybar-workspace-filter` checks 22-23 pin both cases.

### Filter logic (`tests/taffybar-workspace-filter/run.sh`)

23 assertions, 0 failures, against live 0.56.2 JSON: parse, position match, reorder,
size-only fallback, no bogus match, `1-6` / `7-12`, no overlap, no specials, live move,
empty-table / unresolved-monitor / mid-drag rows, single-monitor fallback `1-11`.

### Incident worth remembering

A real-mode attempt copied `tests/hyprland-nest/cfg/taffybar.hs` over
`modules/nixos/taffybar/taffybar.hs` at 19:46 and left it there ~2 h. Nothing live was
affected (no bar restarted in the window, and `~/.cache/taffybar` still held the 17:55
build of the real config), but the tree was restored from the typecheck copy. `preflight`
now dies if the probe's text is at the repo path, and the harness README opens with the
rule. The damage outlived the file: that lane's final report retracted the per-monitor
evidence as "a stale dyred binary", because the one cold run it trusted started at 19:52 —
inside the probe window — and so saw two identical bars, no memory plate and no `taffybar:`
trail. That evidence re-does itself identically four times on the restored tree.

## Deploy / smoke checklist (user runs `rebuild-default`, then logs out and in)

1. `systemctl --user status taffybar` — active, not cycling; `journalctl --user -u taffybar`
   quiet. `SUPER+ALT+B` restarts it.
2. `hyprctl -j monitors | rg reserved` — same 30 px (or whatever task 5 settled on) on both
   outputs, `namespace taffybar` in `hyprctl -j layers`.
3. Workspaces: DP-5 shows 1–6, HDMI-A-3 shows 7–12, dragging a workspace to the other output
   moves its button within a second or two, no `special:` buttons.
4. Click a workspace button (upstream's Hyprland click path) and scroll over an empty part of
   the bar: both change the active workspace on that output only.
5. Favicons still appear in the workspace strip (PNG via built-in loader, svg via
   ImageMagick in `ff-favicon.py`), tray appears (watcher `Requires=` ordering), sliders move.
6. In dwm (if ever booted there): bar looks as before plus the now-visible active plate;
   scroll still switches desktops.

## Open

- Not covered by any rig: `:hover` (the rig's `XQueryPointer` returns `WINDOW=0` over the
  bar, so GTK never enters hover — both spellings of the rule are equally unproven), the
  green `.urgent` plate, and the `visible`/`hidden`/`empty` states. Cheap to settle by
  hand in the live session: put a window urgent, watch the button.
- Favicons, tray contents and the network widgets (wttr, pomotask with a real key) were
  deliberately stubbed or absent in every harness run; those are live-session checks.
- Icon fallback table: no `FFPWA-*`/`brave-*` windows were open during analysis and
  `~/.local/share/applications` has no matching `.desktop` files, so the misses are still
  unmeasured. Decide from the live smoke test; the hook is wired
  (`getWindowIconPixbuf = faviconWindowIcon`), it just needs
  `addCustomIconsToDefaultWithFallbackByPath` if misses show.
- `hosts/main/configuration.nix:296` still `mkForce "none+dwm"` while `hosts/common.nix:96`
  says `"hyprland"`: fine for this box (`oldpc` gets `hyprland`), wrong if that box is meant
  to boot into Hyprland. Not touched.
- Unrelated live bug the nix lane found: `modules/nixos/darkman/default.nix:71-79` mixes
  `Unit = {…}` with `serviceConfig.Environment`, and systemd drops `[serviceConfig]` —
  darkman's `NIX_GSETTINGS_OVERRIDES_DIR` is dead in the running unit.
