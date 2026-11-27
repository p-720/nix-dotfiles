# tests/hyprland-nest — nested Hyprland 0.56.2 + taffybar 7.4.4 harness

Runs a real Hyprland 0.56.2 as a Wayland client of a headless labwc 0.9.7
parent, attaches taffybar 7.4.4 to it as a real layer-shell bar, and asserts the
compositor facts this repo's bar depends on: one bar surface per output, an
equal exclusive zone on both, empty persistent workspaces in `hyprctl -j
workspaces`, specials in the same list, `dispatch workspace m±1`, and pixels
that are actually painted.

Two modes, one script. Default: `cfg/taffybar.hs`, a minimal probe. `REAL=1` (or
`./harness.sh taffy-real`): `modules/nixos/taffybar/taffybar.hs` and
`taffybar.css`, symlinked into the harness `HOME` the way the live system does
it, with the ghc env for dyre on PATH and the config's state-mutating helpers
stubbed. Which config the running bar used is remembered in
`/tmp/hyprland-nest/bar-mode`, so a bare `./harness.sh assert` grades whichever
bar is up. Real mode is documented under "Real mode" below.

Ported from the scratch harness that established these facts (`/tmp/nest`), made
path-independent, and turned into checks with a pass/fail exit code instead of a
log a human compares by eye.

## Run

```
./harness.sh all        # up -> taffy -> assert -> down; exit code = failures
./harness.sh pins       # what each pinned binary resolves to, and from where
./harness.sh up         # parent + child + headless outputs (leaves them running)
./harness.sh taffy      # start taffybar into the child (probe config)
./harness.sh taffy-real # same, with the repo's taffybar.hs + taffybar.css
./harness.sh assert     # PASS/FAIL lines; exit code = number failed
./harness.sh down       # kill everything recorded, verify nothing is left

REAL=1 ./harness.sh all                 # the live config, end to end
REAL=1 REAL_CLEAN=0 ./harness.sh all    # reuse the compiled config (fast re-run)
REAL=1 REAL_CSS=none ./harness.sh all   # control: bar with an empty stylesheet
```

PATH needs: `jq grim magick identify compare foot ss stdbuf setsid dbus-daemon
timeout readlink` (all in the system profile today; `preflight` names the missing
one instead of failing later inside a compositor). Real mode additionally needs
`nix` (to resolve `modules.taffybar.ghcEnv` and `barEnv`) and
`status-notifier-watcher` for the tray path.

State and artifacts, deliberately in different places:

- `art/` screenshots + hyprctl JSON, `logs/` parent/child/bar/bar-shim logs —
  both gitignored, both safe to delete.
- `/tmp/hyprland-nest/{xdgr,home,pids}` — `XDG_RUNTIME_DIR` (mode 700) and `HOME`
  for everything that runs, including from this repo copy. A checkout is not a
  runtime dir, and the live session's `/run/user/1000` is never used. `NEST_ROOT`
  moves it; `REPIN=1` re-resolves the pins.

## Pins

`load_pins` evaluates one nix expression (against this repo's flake) and caches
the result in `/tmp/hyprland-nest/pins.env`.

| binary | version | resolves from | outPath |
|---|---|---|---|
| hyprland | 0.56.2 | `inputs.nixos-unstable` → `hyprland` (the same attribute flake.nix overlays as `final.unstable.hyprland`) | `/nix/store/9xw778lhb3b9pah8nizyyh9rxmli12hf-hyprland-0.56.2` |
| labwc | 0.9.7 | `inputs.nixpkgs` (nixos-26.05) → `labwc` | `/nix/store/ghqw9zrm1s3njcirz5pfyrj41qccpvw7-labwc-0.9.7` |
| taffybar | 7.4.4 | `inputs.nixpkgs` with `inputs.taffybar.overlays.default` → `taffybar` | `/nix/store/a42rxnm1ssb2rjg8qjyb7k6naja8v623-taffybar-with-packages-7.4.4` |

All three resolve to exactly the paths the scratch run used, so on this machine
the fallback is never taken. The fallbacks are the same paths hardcoded in the
header of `harness.sh`, used only when nix cannot evaluate (no network, offline
eval); they fail loudly rather than quietly testing a different build.

Which resolutions are *rejected*, and why the version check exists:

- `inputs.nixpkgs → hyprland` = **0.55.2**, not the 0.56.2 the system runs.
- `inputs.nixos-unstable → labwc` = **0.20.2**, not 0.9.7.
- `inputs.nixpkgs → taffybar` without the overlay = **7.0.1**, and no
  `taffybar-with-packages` wrapper — that wrapper is what carries ghc 9.10.3 so
  dyre can recompile a config at run time.

## Files

| file | role |
|---|---|
| `harness.sh` | phases, pins, env isolation, kill logic, assertions |
| `cfg/hyprland.conf` | minimal child config: side-by-side headless outputs, 11 persistent workspaces (1–6 on `headless-1`, 7–11 on `headless-2`), no animations, no default wallpaper, and it must parse clean |
| `cfg/taffybar.hs` | **probe** bar: one `workspacesNew` + clock, `barPosition = Bottom`, `barHeight = ExactSize 30`, `useAllMonitors`. Not `~/.config/taffybar/taffybar.hs` |
| `cfg/taffybar.css` | flattens theme padding/font size so the probe bar really is 30 px tall (see traps) |
| `../modules/nixos/taffybar/taffybar.{hs,css}` | the **live** bar, symlinked into the harness `HOME` by real mode. Never copied over, never edited, never `sed`'d |

The probe config exists because the real one cannot start on a machine with no
SNI watcher, no PipeWire and no network reachable from the test: its
`trayWidget` dies with a pattern-match failure in `SNITray.hs:322` when SNI host
registration fails, and its audio/wttr/pomotask modules want PipeWire and a
server. Real mode answers that by supplying the two things the live system
supplies (an SNI watcher on the private bus, a ghc for dyre) and stubbing the
helpers that would touch real state — see "Real mode".

## Assertions

From the last clean **probe** run (`./harness.sh all`, `# checks=11 failed=0`,
exit 0 — real mode's run is below):

```
INFO  layer surfaces                     {"out":"headless-1","bars":[{"ns":"taffybar","x":0,"y":770,"w":1280,"h":30}]} {"out":"headless-2","bars":[{"ns":"taffybar","x":1280,"y":770,"w":1280,"h":30}]}
PASS  layer-per-output:headless-1        namespace=taffybar surfaces=1 want=1
PASS  layer-per-output:headless-2        namespace=taffybar surfaces=1 want=1
INFO  monitors                           {"name":"headless-1","width":1280,"height":800,"reserved":[0,0,0,30]} {"name":"headless-2","width":1280,"height":800,"reserved":[0,0,0,30]}
PASS  reserved-zone:headless-1           reserved=[0,0,0,30] want=[0,0,0,30]
PASS  reserved-zone:headless-2           reserved=[0,0,0,30] want=[0,0,0,30]
INFO  numbered workspaces                [{"mon":"headless-1","listed":6,"empty":4},{"mon":"headless-2","listed":5,"empty":5}]
PASS  persistent-workspaces-listed       numbered workspaces with windows==0: 9 (want >0)
INFO  special entries                    [{"id":-98,"name":"special:test","monitor":"headless-1","monitorID":0,"windows":0,"hasfullscreen":false,"lastwindow":"0x0","lastwindowtitle":"","ispersistent":false,"tiledLayout":"dwindle"}]
PASS  specials-listed                    togglespecialworkspace test -> count=1 first=id=-98 name=special:test special_name=-
PASS  workspace-m+1-active               headless-1 activeWorkspace 3 -> 4
PASS  workspace-m-1-active               headless-1 activeWorkspace 4 -> 3 (want 3)
INFO  frame stats:headless-1             full 1280x800 mean=7132.02 | band 1280x30 mean=4249.87 entropy=0.103438 colors=217
PASS  band-not-black:headless-1          band mean=4249.87 (>3000) colors=217 (>150)
INFO  frame stats:headless-2             full 1280x800 mean=4396.32 | band 1280x30 mean=5013.26 entropy=0.103086 colors=226
PASS  band-not-black:headless-2          band mean=5013.26 (>3000) colors=226 (>150)
INFO  move step                          focuswindow class:foot + movetoworkspace 4
INFO  strip deltas (px)                  open=2536 moved=10515
PASS  band-reacts-to-window              changed pixels open=2536 move=10515 (want >25 in at least one)
INFO  input devices                      mice: Keyboards: Tablets: Touch: Switches:
      listener: .../.socket2.sock
INFO  taffybar direct-socket joins       5 ESTAB of 7 (hyprland event socket, not hyprctl)
```

What was already established in the scratch run and what is new here:

| check | status |
|---|---|
| `layer-per-output:*` | **already proven** — scratch measured one `taffybar` surface per output at `y=770 h=30` |
| `reserved-zone:*` | **already proven**, but the 41 px story is narrower than it looked: with theme defaults the *probe* widget set comes out 41 px tall despite `barHeight = ExactSize 30`, which is why `cfg/taffybar.css` exists. The live config measures 30 px even with an empty stylesheet (real mode, `REAL_CSS=none`), so GTK grows the toplevel past the request only when a child really is taller |
| `persistent-workspaces-listed` | **new** — the empty-persistent-workspace behaviour was never asserted; it is the whole reason the bar shows buttons for workspaces with no windows |
| `specials-listed` | **new** — nothing in the scratch run looked at specials. In 0.56.2 they list as `id=-98, name="special:<name>"`; `special_name` is null, so keying on `special_name` would miss them |
| `workspace-m+1-active` / `workspace-m-1-active` | **new** — scratch established that `dispatch -m <mon>` is invalid and that `focusmonitor` must come first; that it then actually moves the monitor's active workspace is asserted for the first time here |
| `band-not-black:*` | **already proven** (scratch: mean 10775, 1021 colours, with the user's gotham CSS). Restated against a plain background here: ~4990 mean / 222 colours with the bar, 4612 / 70 without one, so `colors` is the number that discriminates |
| `band-reacts-to-window` | **partially proven** — scratch measured 7021 changed pixels when a *new workspace* appeared, and 0 for a focus-only change. Here a window *open* moves 2536 px and a window *move* 10515 px, both from the same crop |
| `taffybar-log-clean`, `reserved-zone-equal`, `move-reacts-both-bars`, `move-shift-symmetric`, `move-reversible` | **new** — real mode only, see below |

`INFO` lines are evidence, not checks: the workspace-strip deltas, per-monitor
workspace counts, and the socket join (taffybar holds 5 ESTAB unix sockets whose
peer fd is in the harness Hyprland ⇒ it reads the compositor's own event socket,
not `hyprctl` subprocesses).

## Real mode (`REAL=1`)

> **Nothing in this directory may write under `/etc/nixos`.**
> `modules/nixos/taffybar/taffybar.hs` is symlinked out-of-store into
> `~/.config/taffybar`, so "making the real config start" by replacing that file
> replaces the user's bar. On 26 Nov a real-mode attempt copied `cfg/taffybar.hs`
> over it, which is why the numbers recorded below disagree with each other: anything
> started between 19:46 and 19:53 graded the probe, and other runs graded a dyred binary
> older than the config. `preflight` now dies if the probe's text is found at the repo
> path, and real mode deletes a binary older than the config unconditionally. The set that
> reproduces is in the block below. If the real config cannot start, **stub what it
> shells out to and report the failure** — do not edit or replace it.

> **Corrected 26 Nov, after re-running with a guaranteed-fresh compile.** The
> numbers pasted below under "the 8 checks real mode adds" were graded against a
> **stale dyred binary** — `~/.cache/taffybar/…taffybar-wrapped` was newer than the
> symlinked `taffybar.hs`, so dyre ran an older bar instead of the repo config.
> That bar logged a `taffybar: bar monitor: …` trail and drew a `#9b59b6` memory
> plate. The harness now deletes a binary older than the config unconditionally (not even
> `REAL_CLEAN=0` skips it) — but that retraction overcorrected: the run it trusted as
> "guaranteed-fresh" started at **19:52**, inside the window (19:46–19:53) when the repo
> path held the probe, so it graded the probe. `TAFFYBAR_LOG` is read by the config
> (`barLogOn`), and it emits a trail.
>
> What two cold runs after the restore establish (`REAL=1 ./harness.sh all`, 20:04 and
> 20:11, each with `dyre cache cleared`, `# checks=19 failed=0`, exit 0):
>
> - **one taffybar layer surface per output** at `x=0|1280 y=770 w=1280 h=30`, and
>   `hyprctl -j monitors` reserves **`[0,0,0,30]` on both** — so the live config's
>   measured bar height is 30 px, exactly `barHeight = ExactSize 30`, with the repo
>   CSS loaded. The probe's 41 px without flattening CSS does not recur here.
> - `REAL_CSS=none` (empty stylesheet) also measures `[0,0,0,30]`: the CSS is not
>   what lands this config on 30 px.
> - band pixels are real, measured four times over (20:04, 20:11, 20:16, 20:22): band mean
>   ~10700–10930 with 498–535 colours per output. The probe sits around 4250 / 217.
> - **the bars do not render the same strip**: the `#9b59b6` memory module starts at col
>   338 on headless-1 and 251 on headless-2. `hyprctl dispatch moveworkspacetomonitor 6
>   headless-2` slides it to 305 / 284 — one 33 px button leaving one bar and arriving on
>   the other, symmetric, reversible, **0 s** latency. That is the per-monitor workspace
>   filter, measured, and it is the point of real mode.
> - `bar-monitor-distinct` passes on stderr: `monitor 0 -> headless-1 x=0`,
>   `monitor 1 -> headless-2 x=1280`, `bar monitor: headless-1`, `bar monitor: headless-2`,
>   with `no-bar-monitor-unresolved` and `no-workspace-refresh-failed` clean.
> - the readiness gate used to warn "bands still changing after 61s" for no reason: pixel
>   stability is unusable when the clock ticks and the memory module re-renders. It now
>   waits for the plate itself and reports readiness in 0 s.
>
> What follows is kept because the module-parity work and the stub inventory are
> still accurate; only the pixel/log conclusions above were wrong.

> **What real mode's stubs do NOT prove.** `setpriv` is stubbed, so the `polypomo` chain
> dies there and `polypomo` itself never runs — "nothing wrote to `time.sqlite`" is a fact
> about the stub, not about the real path. `wpctl` is stubbed, so both volume sliders are
> empty troughs and a wrong `wpctl` argv would go unnoticed. `systemd-inhibit` is exec'd by
> absolute store path, so a PATH shim cannot intercept it at all. `curl`/`python3` were
> never called because the harness `HOME` has no `pomo_*` key and no network widgets were
> reached — not because anything was filtered. And `trayWidget` needs a watcher on the bus
> (`SNITray.hs:322` takes the bar down without one), so "the real config runs" is only true
> with `status-notifier-watcher` up.

`taffy_setup real` symlinks `modules/nixos/taffybar/taffybar.{hs,css}` into
`$HOME/.config/taffybar/` exactly as `modules/nixos/taffybar/default.nix` does —
not by copying the `home.file` activation, but by exporting the same values the
module exports and re-deriving what it builds from them:

| what the module does | how real mode does it | verified how |
|---|---|---|
| `environment.sessionVariables` from `barEnv` | `realbar_env` reads `nix select --arg key barEnv` on the module's `outPath` and exports each pair | prints the actual `LOCALE_ARCHIVE`/`LANG`/`LC_ALL` from the store; `locale-archive-loadable` runs `locale -a` and greps `C.utf8` |
| `symlinkJoin { taffybar-with-packages-7.4.4 + ghc }` | `ghcEnv = config.taffybar.ghcEnv`, added to PATH | `ghc-9.10.3` + `dyre-0.7.0` appear on the bar's `strace` exec chain |
| `XDG_CACHE_HOME/.config` in `runHook` | `HOME` is already `/tmp/hyprland-nest/home` | `taffybar: backend: wayland/hyprland` appears under `$HOME/.cache/taffybar/log`, and `dyre-compile` logs there with a real timestamp |
| `runHook activationPackage` starts `taffybar.service` | `$RUNTIME/bar.sh` → `exec -a taffybar taffybar` | process named `taffybar`, two layer surfaces, 5 `taffybar:` log lines |

`taffybar.hs` needs no ghc flags to build (it compiles clean, only dyre warnings
about duplicate module definitions in the generated `~/.cache/taffybar/taffybar.hs`).
A cold dyred compile of the live config takes ~68 s (2389 s from a store with no
warm output — the closure fetch is the slow part); `REAL_CLEAN=0` reuses it, and
then the bar's surfaces appear after **1 s**.

The 8 checks real mode adds, from the last clean run:

```
INFO  path shims                         curl pactl polypomo python3 setpriv systemd-inhibit wpctl  -> logs/realbar-shims.log
INFO  barEnv (from the module)           LOCALE_ARCHIVE=/nix/store/78i8...-glibc-locales-2.42-61/lib/locale/locale-archive LANG=C.UTF-8 LC_ALL=C.UTF-8
  ghcEnv: /nix/store/cyq2wv843r1ya2x2ff558rhkifdj7y9g-ghc-9.10.3-with-packages
  starting taffybar (/nix/store/a42rxnm1ssb2rjg8qjyb7k6naja8v623-taffybar-with-packages-7.4.4) with the repo's taffybar.hs (CSS: /etc/nixos/modules/nixos/taffybar/taffybar.css)
      ok: taffybar layer surfaces (1s)
INFO  layer surfaces                     {"out":"headless-1","bars":[{"ns":"taffybar","x":0,"y":770,"w":1280,"h":30}]} {"out":"headless-2","bars":[{"ns":"taffybar","x":1280,"y":770,"w":1280,"h":30}]}
PASS  layer-per-output:headless-1        namespace=taffybar surfaces=1 want=1
PASS  layer-per-output:headless-2        namespace=taffybar surfaces=1 want=1
PASS  reserved-zone-equal                headless-1=[0,0,0,30] headless-2=[0,0,0,30]
INFO  reserved height (measured)         bottom zone 30px per output; barHeight asks for 30
      taffybar: backend: wayland/hyprland
      taffybar: monitor 0 -> headless-1 x=0
      taffybar: monitor 1 -> headless-2 x=1280
      taffybar: bar monitor: headless-1
      taffybar: bar monitor: headless-2
PASS  bar-monitor-distinct               lines=2 distinct=2 [headless-1, headless-2] want [headless-1, headless-2]
PASS  no-bar-monitor-unresolved          count=0 (the numeric 1-6/7-12 split would have hidden a broken match)
PASS  no-workspace-refresh-failed        count=0
PASS  no-x11-exception-text              matches=0
PASS  polypomo-sqlite-untouched          mtime+size unchanged (before=1771931615-12288 after=1771931615-12288)
INFO  band height (measured)             30px per layer surface
INFO  frame stats:headless-1             full 1280x800 mean=7381.57 | band 1280x30 mean=10904.7 entropy=0.268431 colors=512
INFO  frame stats:headless-2             full 1280x800 mean=4610.97 | band 1280x30 mean=10737.2 entropy=0.263356 colors=536
INFO  memory plate before move           headless-1 col=338 headless-2 col=251 (left edge of #9b59b6)
INFO  move step                          dispatch moveworkspacetomonitor 6 headless-2 -> hyprctl monitor=headless-2 (was headless-1)
INFO  filter refresh latency             0s for headless-1's plate to move (event-driven, 15s poll backstop)
INFO  memory plate after move            headless-1 col=305 shift=33px  headless-2 col=284 shift=33px
PASS  move-reacts-both-bars              headless-1 lost workspace 6 (plate slid left 33px), headless-2 gained it (plate slid right 33px); want >=10px on both
PASS  move-shift-symmetric               button-width deltas 33px vs 33px (want within 10px)
PASS  move-reversible                    after moving 6 back: headless-1 col=338 headless-2 col=251 (started at 338/251, want within 2px)
```

`move-reacts-both-bars` is the interesting one. `workspaceManagerFilter` returns
`Just . sortOn id . filter (visibleOn ...)` for **both** bars, and `visibleOn` is
`wsMonitor == Left monitorName` — so a workspace that changes monitor must vanish
from one bar's strip and appear on the other's. The check does not look at
hyprctl for that; it finds the memory module's `#9b59b6` plate on each bar and
requires it to slide by the same button width in opposite directions (33 px each,
which is `padding: 3px 10px` × 2 plus a 16 px mono digit ≈ 13 px — the CSS
arithmetic lands on the measured number). `move-reversible` then moves it back
and requires the columns to return within 2 px, so a one-off repaint cannot pass.

Measured numbers worth keeping: the `#9b59b6` plate is **222×30 px**, filling all
30 rows of the band, at identical x on both bars; the layer surface is `y=770
h=30 w=1280` on each output and `hyprctl monitors` reserves `[0,0,0,30]` on both.
Bar band: mean 10904.7 / 512 colours (headless-1) and 10737.2 / 536 (headless-2),
against the probe's ~4250/5013 at 217/226 colours — the live config paints about
twice as many distinct colours per band as a two-widget probe does.

### What real mode has to stub

Everything stubbed is recorded in `logs/realbar-shims.log`, and only two of the
seven were actually called in a ~70 s run: **`wpctl` 245×** (≈3.5/s — the mic
slider's `pollWpctlVolume` loop, one per `micSliderWidget`) and **`setpriv` 16×**
(the `polypomo` chain, which dies there so `polypomo` itself never runs). No
`curl` and no `python3` call: the weather widget never fetched wttr.in, and the
favicon helper never ran. `pomotask` printed `no pomo_ API key, widget left
hidden` in the bar log, i.e. the module's own gate held and no HTTPS to
`pomotasker.vercel.app` happened. `config/polybar/time.sqlite`, the one file
`polypomo` would write, is checksummed before and after
(`polypomo-sqlite-untouched`).

| stub | why | what breaks without it |
|---|---|---|
| `setpriv`, `polypomo` | `polypomo-widget.sh` does `exec setpriv --reuid andrew ...`, i.e. a setuid drop to root the harness cannot do as `nobody` | the whole `polypomo` chain dies at `setpriv` anyway, so this only proves where it dies — the real failure mode is the same on a machine where the drop is refused |
| `wpctl`, `pactl` | no PipeWire/WirePlumber in the nested session | `audioModuleStatus` logs `WirePlumber monitor failed: user error (failed to connect WirePlumber core)` (taffybar survives it) and the mic slider would call `wpctl get-volume` on a dead socket; with the stub the sliders render as empty troughs |
| `systemd-inhibit` | no `logind` in the private runtime | would block the bar's startup thread for 100 ms per `wait_for_default` retry; note this one **cannot** be intercepted by PATH — see traps |
| `status-notifier-watcher` | the real bar has `trayWidget` on `sniFilter`, and the real session gets the watcher from `services.statusNotifierWatcher` | without it the tray path gets nothing; with it, `sni-watcher-launches` proves `SNI host registration successful` on the private bus, and `sni-watcher-attached` proves the watcher actually accepted the bar: `statusNotifierWatcher=ok registered=1`, `snitest` in the `org.kde.StatusNotifierWatcher RegisteredStatusNotifierItems` array |

`REAL_CSS=none` links the bar at an empty stylesheet instead of the repo one. It
does not remove the purple plate, so `memory-plate-found` and the move checks fail
by design there; its only job is the height control, and there it says 30 px.

## Reproduce conditions worth knowing

- **labwc is the parent** because it advertises `zwp_linux_dmabuf_v1` ≥ 4 and
  actually sends `main_device`, which is how aquamarine finds a GBM DRM node.
  sway boots fine as a parent and still aborts the child with
  `Cannot open backend: no allocator available`. `RENDER_NODE` must be a GBM
  render node — `/dev/dri/renderD128` (i915), not renderD129 (nvidia).
- **The nested `WAYLAND-1` output is unusable**: the parent never sends
  `xdg_toplevel.configure`, so that output gets no modes, Hyprland times out into
  its `FALLBACK` monitor and tears it down. Everything runs on outputs created
  after start (`output create headless <name>`), before taffybar starts.
- **`up` refuses to continue if `hyprctl configerrors` is not empty.** A config
  error draws Hyprland's error bar, which reserves ~61 px at the top of a monitor
  and leaves that reservation on whatever monitor last held focus — precisely the
  measurement being asserted.

## What this harness cannot do

- **Deliver scroll events to a layer-shell surface.** The real bar switches
  workspaces by scrolling over the workspace widget. A headless output has no
  pointer (`hyprctl devices` lists no mice), and neither Hyprland's IPC nor
  taffybar's has a way to inject pointer events into a surface. Scroll is
  therefore untestable in this harness, and nothing here stands in for it: the
  strip screenshots prove only the *rendering* side of the workspace widget.
  The gap is where the one real bug hid: Hyprland delivers the wheel as a
  *smooth* scroll event (`direction = GDK_SCROLL_SMOOTH`, the step lives in the
  deltas) while X11 delivers discrete Up/Down. A handler matching only the
  discrete spellings switches workspaces under dwm and does nothing under
  Hyprland, and no run of this file would notice. `tests/taffybar-workspace-filter`
  pins the delta-sign mapping instead (checks 24–29).
- **Anything that needs a keyboard.** There is no keyboard device either, so all
  state changes go through `hyprctl dispatch`, and focus-only visual changes are
  not a usable signal (the same crop measured 48 px in one scratch run and 0 in
  another: two blank terminals render identically).
- **Real monitor behaviour.** No EDID, no real hotplug, no scaling, no VRR or
  direct scanout (`solitaryBlockedBy` is already `windowed mode, missing
  candidate`), so nothing here can regress-test monitor layout or DPMS.
- **The real bar, end to end.** Real mode runs the live config, but with the
  helpers it cannot duplicate stubbed: audio/mic volume (no WirePlumber), the
  pomodoro label (no `setpriv` drop, so no `polypomo`), `pomotask` (no API key →
  widget hidden, no HTTPS) and the inhibit/lock path (no `logind`). Those widgets
  render their fallbacks — empty sliders, absent label — so their *values* stay
  untested even though their code paths run.
- **Session integration.** No systemd user manager (`HYPRLAND_NO_SD_VARS=1`), no
  portals, a private dbus bus only. Also nothing about autostart or env export.
- **Performance.** Software-rendered nested compositors tell you nothing about
  frame timing, and the run's runtime is dominated by dyre compilation and fixed
  settle sleeps.

## Traps (each one cost a run)

1. `pkill -f` / `pgrep -f` matches the command line of the shell running them and
   SIGTERMs the harness. Kill recorded pids plus a `/proc/*/cmdline` scan, and the
   scan only reports a pid when its argv names one of our paths **and** its
   environment carries `HYPRLAND_NO_SD_VARS=1` — the marker only this harness
   exports, which is what keeps the scan off the user's bar (same store path,
   same binary).
2. Hyprland's launcher pid is not the server pid: the watchdog re-execs with the
   same argv, so recorded pids alone leak the real server and the parent labwc.
3. `hyprctl` resolves the instance from `$XDG_RUNTIME_DIR/hypr/<sig>`. The sig
   changes every boot, so it is discovered (newest socket dir), stale dirs are
   removed on `down`, and a second live instance would let assertions read the
   wrong compositor — `up` takes strays down first.
4. A client with no `WAYLAND_DISPLAY` connects to `wayland-1`, which is the
   *parent*. Every child gets the child's socket explicitly.
5. `compare -metric AE` exits **nonzero when the images differ** — the exact
   moment a test starts passing will abort a `set -e` script.
6. ImageMagick 7: `identify`/`magick`, not `convert`.
7. bash 5.3 mis-parses a heredoc containing apostrophes inside `$( )`; the nix
   expression for the pins is written to `logs/pins-expr.nix` and evaluated with
   `--file`.
8. Config errors reserve space: `animation=enabled=false` is invalid
   (`animation=global,0`), and `misc:allow_headless` /
   `misc:disable_hyprland_qtutils_check` no longer exist in 0.56.2.
9. `barHeight = ExactSize 30` sets the strut request only; GTK sizes the toplevel
   to its children, which with the vendor CSS (10–12 pt) and theme padding comes
   out at 41 px. `cfg/taffybar.css` (loaded via `TAFFYBAR_CSS_PATHS`, read at bar
   start-up rather than compile time) flattens padding and font metrics to land
   on 30.
10. taffybar dials `unix:path=$XDG_RUNTIME_DIR/bus`; without a private bus there
    it fails with a `SocketError` on that path.
11. `movewindow workspaceA:4` is not a thing in 0.56.2 ("Unsupported direction:
    w"). `movewindow` takes directions/`mon:`. Moving a window to a workspace is
    `focuswindow <rule>` then `movetoworkspace <name>` — and `dispatch` returns 0
    even when it prints an error, so nothing can be trusted from its exit status.
12. Persistent workspace rules only materialise once their monitor exists, so
    `output create` is followed by `hyprctl reload`.
13. Outputs before taffybar: hot-plugging an output while bars run tears the bars
    down (in the real config it is the tray path that dies, which reads as a
    monitor bug).
14. First taffybar run compiles (~40 s of ghc via dyre for the probe, ~68 s for
    the live config — 2389 s if the ghc env has to be fetched first); keep `HOME`
    across runs and poll for layer surfaces instead of sleeping a fixed 55 s.
15. Do not `source` this script — sourcing runs the whole thing (`all` is the
    default phase).
16. **dyre picks its binary by mtime, and a symlinked `taffybar.hs` reports the
    repo file's mtime.** It only recompiles when the `.hs` is newer than
    `~/.cache/taffybar/taffybar-linux-x86_64.taffybar-wrapped`. Several "best"
    real-mode runs here — the ones that logged `taffybar: bar monitor:` lines and
    drew a purple memory plate — graded an older bar for exactly that reason, and
    every pixel number from them is about a different config. `realbar_setup` now
    deletes a binary older than the repo `.hs` **unconditionally**, including under
    `REAL_CLEAN=0`; if a real run ever prints that warning, read it as "the previous
    run's numbers were wrong".
17. **`moveworkspace` is not a dispatcher in 0.56.2** — `hyprctl dispatch
    moveworkspace 6` changes nothing. The move step uses `moveworkspacetomonitor
    6 headless-2`, and `assert_dispatch` prints whatever `hyprctl` said so a
    mistyped dispatcher cannot hide behind a passing check.
18. **`hyprctl monitor` takes `name` or `desc`, never a comma list** — `hyprctl
    monitor name,desc` prints `unknown request` and exits 0, so anything parsing it
    gets nothing and a "missing field" check can pass vacuously. Use
    `hyprctl -j monitors`.
19. **`systemd-inhibit` is exec'd by absolute path**, so the PATH shim cannot
    intercept it (the bar log still shows one `failed to connect to
    org.freedesktop.login1` line). That shim exists to bound the retry loop, not to
    fake success.
20. **`polypomo` cannot run here, and that is the measurement.** The repo wrapper is
    `bash -c "exec setpriv --reuid andrew --regid users ..."`; as the harness's
    `nobody` the drop is refused, so the chain stops at `setpriv` (16 calls) and
    `polypomo` never starts. `polypomo-sqlite-untouched` compares `mtime:size` of
    `config/polybar/time.sqlite` before and after, so if that wrapper ever finds a
    way through, the write shows up as a failed check.
21. **The live config gates its own network modules.** `pomotask` needs a `pomo_*`
    variable and prints `no pomo_ API key, widget left hidden` without one, and the
    pass-through `curl` logger sees no calls — so the harness `HOME` (no
    `.pomotasker.env`, no API key) is what keeps `pomotasker.vercel.app` and
    `wttr.in` out of a test run, not any filter the harness applies.

## Safety

Nothing here writes to the live session: `DISPLAY` is never exported and the
inherited one is dropped, `HOME`/`XDG_*`/`XDG_RUNTIME_DIR` are rebuilt under
`$NEST_ROOT`, `DBUS_SESSION_BUS_ADDRESS` points at the private bus,
`HYPRLAND_NO_SD_VARS=1` stops the child from touching the user's systemd user
environment, and every `hyprctl` gets an explicit
`HYPRLAND_INSTANCE_SIGNATURE` discovered from the private runtime dir — never the
user's. `down` finishes by verifying that no marker-carrying process is left.
