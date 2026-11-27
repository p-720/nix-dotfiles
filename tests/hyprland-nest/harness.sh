#!/usr/bin/env bash
# tests/hyprland-nest/harness.sh — nested Hyprland 0.56.2 + taffybar 7.4.4 regression harness.
#
# Boot Hyprland as a Wayland client of a headless labwc parent, drive it with
# hyprctl, attach taffybar to it as a real layer-shell bar, then assert on what
# the bar needs from the compositor: layer surfaces per output, exclusive zones,
# empty persistent workspaces, specials, `dispatch workspace m±1`, real pixels.
#
#   ./harness.sh pins        show the resolved binaries and where each came from
#   ./harness.sh up          parent + child + headless outputs (prints child socket)
#   ./harness.sh taffy       launch taffybar (probe config) into the child
#   ./harness.sh taffy-real  launch taffybar with the REPO's taffybar.hs + CSS
#   ./harness.sh assert      PASS/FAIL regression checks; exit code = failures
#   ./harness.sh down        kill everything this harness recorded
#   ./harness.sh all         up -> taffy -> assert -> down
#
# REAL=1 makes taffy/all use the live config instead of the probe one: it exports
# the module's own barEnv, puts its ghcEnv on PATH, stubs the helpers that mutate
# real state, and runs the probe assertions plus 8 more that only the live config
# can be graded on (see real_checks). Which config the running bar used is
# remembered in $RUN/bar-mode, so a bare `./harness.sh assert` grades whichever
# bar is up. 11 checks in probe mode, 19 in real mode.
#
# Safety invariants — the live session (Hyprland on Xwayland :0, runtime dir
# /run/user/1000) is never written to and never addressed:
#   * private HOME + XDG_RUNTIME_DIR under $RUN, HYPRLAND_NO_SD_VARS=1 so the
#     child never runs `systemctl --user import-environment`, and a private bus
#   * DISPLAY is never exported; preflight refuses to start with DISPLAY=:0
#   * every pid is recorded and killed by number; the /proc fallback only trusts
#     processes carrying this harness's own env marker
#   * artifacts go to this dir's art/ and logs/ (gitignored), session state goes
#     to $RUN (/tmp/hyprland-nest) — the repo checkout is not a runtime dir
set -euo pipefail

HERE=$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)
REPO=$(cd -- "$HERE/../.." && pwd)
ART=$HERE/art
LOGS=$HERE/logs
CFG=$HERE/cfg

RUN=${NEST_ROOT:-/tmp/hyprland-nest}
RUN_XDGR=$RUN/xdgr
RUN_HOME=$RUN/home
PIDS=$RUN/pids
PINS_CACHE=${PINS_CACHE:-$RUN/pins.env}

# MUST be a GBM render node: aquamarine takes its DRM node from the parent's
# zwp_linux_dmabuf_v1 main_device feedback, and renderD129 (nvidia) has no GBM.
RENDER=${RENDER_NODE:-/dev/dri/renderD128}
OUTPUTS=${OUTPUTS:-"headless-1 headless-2"}
OUT_W=${OUT_W:-1280}
OUT_H=${OUT_H:-800}
# Real sessions lay outputs out side by side (x=0, x=OUT_W). `output create
# headless` leaves every output at 0x0, and per-bar monitor matching keyed on
# the layout position cannot resolve two monitors that both live at x=0, so the
# harness lays them out the way a real desktop is, unless OUT_REPOS=0.
OUT_REPOS=${OUT_REPOS:-1}
MOVE_BAND_W=${MOVE_BAND_W:-700}
# The memory module's plate is this colour in the live CSS; its left edge is the
# ruler the workspace-move test reads. See purple_first.
MEMORY_COLOR=${MEMORY_COLOR:-'#9b59b6'}
COLOR_FUZZ=${COLOR_FUZZ:-12%}
BAND_H=${BAND_H:-30}
STRIP_W=${STRIP_W:-400}
# identify %[mean] is 16-bit: a black buffer is 0. 3000 (~4.6%) clears any
# dithered-black floor and stays far below a painted bar (measured ~10800).
BAND_MEAN_MIN=${BAND_MEAN_MIN:-3000}
# Measured: 227 distinct colours with the bar up, 70 for the same crop of the
# bare compositor background. 150 sits between the two, so this cannot pass on
# an unpainted band; the band's exact geometry is check 1's job.
BAND_COLORS_MIN=${BAND_COLORS_MIN:-150}
REACT_MIN_PX=${REACT_MIN_PX:-25}

# Real-config mode. The live config is not sandbox-friendly: at start-up the
# primary bar execs polypomo with --saveto into this repo's sqlite history, and
# the mic slider polls wpctl four times a second. HOME is already private; the
# helpers reachable through PATH get logging no-op stubs, and the mtime of the
# file the config writes to is asserted afterwards.
REAL=${REAL:-0}
REPO_HS=$REPO/modules/nixos/taffybar/taffybar.hs
REPO_CSS=$REPO/modules/nixos/taffybar/taffybar.css
SHIM=$RUN/shim
BAR_MODE_FILE=$RUN/bar-mode
SQLITE_GUARD_FILE=$RUN/sqlite-guard
BAR_MODE=probe

EXPECTED_HYPRLAND=${EXPECTED_HYPRLAND:-0.56.2}
EXPECTED_LABWC=${EXPECTED_LABWC:-0.9.7}
EXPECTED_TAFFYBAR=${EXPECTED_TAFFYBAR:-7.4.4}
# Last resort, measured from the run that established the facts these assertions
# guard. Used only when nix cannot resolve the same versions (offline eval, no
# network); they fail loudly instead of silently testing a different build.
FALLBACK_HYPRLAND=${FALLBACK_HYPRLAND:-/nix/store/9xw778lhb3b9pah8nizyyh9rxmli12hf-hyprland-0.56.2}
FALLBACK_LABWC=${FALLBACK_LABWC:-/nix/store/ghqw9zrm1s3njcirz5pfyrj41qccpvw7-labwc-0.9.7}
FALLBACK_TAFFYBAR=${FALLBACK_TAFFYBAR:-/nix/store/a42rxnm1ssb2rjg8qjyb7k6naja8v623-taffybar-with-packages-7.4.4}

mkdir -p "$ART" "$LOGS" "$CFG" "$RUN_XDGR" "$RUN_HOME/.config/taffybar" "$PIDS"
chmod 700 "$RUN_XDGR" "$RUN_HOME"

# ---------- helpers ----------
log()  { printf '%s\n' "$*"; }
warn() { printf 'WARN  %s\n' "$*" >&2; }
die()  { printf 'harness: %s\n' "$*" >&2; exit 1; }

# Poll instead of blind sleeps: these waits are the whole runtime, and a fixed
# sleep either burns a minute or races the slow path (first dyre compile).
wait_for() { # wait_for <desc> <seconds> <predicate...>
  local desc=$1 limit=$2; shift 2
  local i
  for ((i = 0; i < limit; i++)); do
    if "$@" >/dev/null 2>&1; then log "      ok: $desc (${i}s)"; return 0; fi
    sleep 1
  done
  warn "TIMEOUT after ${limit}s: $desc"
  return 1
}

# ---------- assertions ----------
CHECKS=0
FAILS=0
FAILED=()
check() { # check <name> <0-pass-1-fail> <detail>
  local name=$1 ok=$2 detail=${3:-}
  CHECKS=$((CHECKS + 1))
  if [ "$ok" = 0 ]; then
    printf 'PASS  %-34s %s\n' "$name" "$detail"
  else
    printf 'FAIL  %-34s %s\n' "$name" "$detail"
    FAILS=$((FAILS + 1))
    FAILED+=("$name")
  fi
}
info() { printf 'INFO  %-34s %s\n' "$1" "${2:-}"; }

# grep -c prints 0 and exits nonzero when nothing matches, which is both a set -e
# abort and a doubled "0\n0" under a `|| echo 0`. One place that gets it right.
count() { # count <regex> <file> -> matching line count, 0 when there is none
  local n
  n=$(grep -Ec -- "$1" "$2" 2>/dev/null) || n=0
  printf '%s\n' "${n:-0}"
}

# ---------- pins ----------
# One nix eval for all three binaries — two nixpkgs instances plus the taffybar
# overlay is ~15 s of evaluation and the harness gets re-run a lot, so the
# result is cached in $RUN/pins.env. REPIN=1 forces a fresh resolve.
resolve_pins() {
  local exprfile=$LOGS/pins-expr.nix out path p
  # A heredoc inside $( ) mis-parses apostrophes in its body on bash 5.3, so the
  # expression goes to a file (and stays there, as a debuggable artifact).
  cat > "$exprfile" <<EOF
let
  # The live system's hypr stack comes from nixos-unstable (flake.nix: hyprland =
  # final.unstable.hyprland); this repo's own nixpkgs input is a stable branch.
  f = builtins.getFlake "$REPO";
  unstable = f.inputs.nixos-unstable.legacyPackages.x86_64-linux;
  stable = f.inputs.nixpkgs.legacyPackages.x86_64-linux;
  # taffybar-with-packages — the wrapper that carries ghc so dyre can recompile
  # a config — only exists with the upstream taffybar flake overlay applied.
  withTaffybar = import f.inputs.nixpkgs {
    system = "x86_64-linux";
    overlays = [ f.inputs.taffybar.overlays.default ];
  };
in {
  hyprland = [ unstable.hyprland.version unstable.hyprland.outPath ];
  labwc = [ stable.labwc.version stable.labwc.outPath ];
  taffybar = [ withTaffybar.taffybar.version withTaffybar.taffybar.outPath ];
  # Buildable form of the same three pins. `nix eval` only plans an output path;
  # realizing is what puts bytes in the store, and a gc can take them back.
  build = { hyprland = unstable.hyprland; labwc = stable.labwc; taffybar = withTaffybar.taffybar; };
}
EOF
  out=$(timeout "${PIN_TIMEOUT:-300}" nix eval --impure --json --file "$exprfile" 2>"$LOGS/pins-nix.err") \
    || { warn "nix eval failed (logs/pins-nix.err)"; return 1; }
  jq -r '
    "HYPRLAND_RESOLVED=\"\(.hyprland[1])\"\nHYPRLAND_VER=\"\(.hyprland[0])\"\n" +
    "LABWC_RESOLVED=\"\(.labwc[1])\"\nLABWC_VER=\"\(.labwc[0])\"\n" +
    "TAFFYBAR_RESOLVED=\"\(.taffybar[1])\"\nTAFFYBAR_VER=\"\(.taffybar[0])\""
  ' <<<"$out" > "$PINS_CACHE.tmp"
  # nix eval only plans paths. A gc can take one back, and pin() then dies on a
  # pin it just printed (the hardcoded fallback is a store path too, so GC eats it
  # just as easily) — so realize the missing ones here rather than warn and hope.
  for pair in "HYPRLAND:hyprland" "LABWC:labwc" "TAFFYBAR:taffybar"; do
    p=${pair%%:*}; attr=${pair##*:}
    path=$(awk -v k="${p}_RESOLVED" -F'=' '$1==k{gsub(/"/,""); print $2}' "$PINS_CACHE.tmp")
    if [ -n "$path" ] && [ ! -e "$path" ]; then
      log "  realizing $p (nix eval gave a path with no bytes: $path)"
      timeout "${PIN_BUILD_TIMEOUT:-900}" nix build --impure --no-link --file "$exprfile" "build.$attr" \
        > /dev/null 2>>"$LOGS/pins-nix.err" || warn "nix build of $p failed (logs/pins-nix.err)"
      [ -e "$path" ] || warn "resolved $p path still not in store: $path"
    fi
  done
  mv "$PINS_CACHE.tmp" "$PINS_CACHE"
  log "pins: resolved by nix against $REPO, cached in $PINS_CACHE"
}

# A resolved path is trusted only when its version matches what these facts were
# written against: this repo's nixpkgs evaluates hyprland to 0.55.2 and
# nixos-unstable evaluates labwc to 0.20.2, and either would silently change
# which build the assertions describe.
pin() { # pin <NAME> <expected> <resolved> <ver> <source> <fallback> <bin>
  local name=$1 expected=$2 resolved=$3 ver=$4 source=$5 fallback=$6 bin=$7 use why
  if [ -n "$resolved" ] && [ "$ver" = "$expected" ] && [ -x "$resolved/$bin" ]; then
    use=$resolved
    why="nix: $source -> $ver"
  elif [ -x "$fallback/$bin" ]; then
    use=$fallback
    why="FALLBACK store path (nix gave '${ver:-nothing}' from $source, wanted $expected)"
  else
    die "$name: nothing usable. nix gave version '${ver:-nothing}' at '${resolved:-nothing}'; fallback $fallback has no $bin"
  fi
  printf -v "PIN_$name" '%s' "$use"
  printf -v "PIN_${name}_WHY" '%s' "$why"
}

load_pins() {
  # Idempotent: `all` loads pins, then each phase loads them again.
  [ -n "${PIN_HYPRLAND:-}" ] && return 0
  local HYPRLAND_RESOLVED= HYPRLAND_VER= LABWC_RESOLVED= LABWC_VER= TAFFYBAR_RESOLVED= TAFFYBAR_VER=
  if [ -f "$PINS_CACHE" ] && [ "${REPIN:-0}" != 1 ]; then
    # shellcheck disable=SC1090
    . "$PINS_CACHE"
    log "pins: cached from $PINS_CACHE (REPIN=1 to re-resolve)"
  else
    resolve_pins || warn "using the hardcoded store paths"
    # shellcheck disable=SC1090
    [ -f "$PINS_CACHE" ] && . "$PINS_CACHE"
  fi
  pin HYPRLAND "$EXPECTED_HYPRLAND" "${HYPRLAND_RESOLVED:-}" "${HYPRLAND_VER:-}" \
    "inputs.nixos-unstable -> hyprland" "$FALLBACK_HYPRLAND" bin/hyprland
  pin LABWC "$EXPECTED_LABWC" "${LABWC_RESOLVED:-}" "${LABWC_VER:-}" \
    "inputs.nixpkgs -> labwc" "$FALLBACK_LABWC" bin/labwc
  pin TAFFYBAR "$EXPECTED_TAFFYBAR" "${TAFFYBAR_RESOLVED:-}" "${TAFFYBAR_VER:-}" \
    "inputs.nixpkgs + inputs.taffybar overlay -> taffybar" "$FALLBACK_TAFFYBAR" bin/taffybar
  HL=${HL:-$PIN_HYPRLAND}
  LABWC=${LABWC:-$PIN_LABWC}
  TAFFY=${TAFFY:-$PIN_TAFFYBAR}
  export HL LABWC TAFFY
}

show_pins() {
  load_pins
  printf 'hyprland  %s\n    %s\n' "$HL" "$PIN_HYPRLAND_WHY"
  printf 'labwc     %s\n    %s\n' "$LABWC" "$PIN_LABWC_WHY"
  printf 'taffybar  %s\n    %s\n' "$TAFFY" "$PIN_TAFFYBAR_WHY"
}

# ---------- private session env ----------
preflight() {
  local c
  for c in jq grim magick identify compare foot ss stdbuf setsid dbus-daemon timeout readlink; do
    command -v "$c" >/dev/null || die "missing '$c' on PATH (try: nix shell nixpkgs#jq nixpkgs#grim nixpkgs#imagemagick nixpkgs#foot nixpkgs#iproute2 nixpkgs#dbus)"
  done
  [ -e "$RENDER" ] || die "no render node at $RENDER (a GBM render node is required; RENDER_NODE=... to override)"
  # Our own runtime dir must never land in the live session's, which is the one
  # place "just inherit it" would actually hurt.
  case "$RUN_XDGR" in
    /run/user/*) die "NEST_ROOT would put the private runtime dir inside a live session: $RUN_XDGR" ;;
  esac
  # $REPO_HS is the user's live bar: ~/.config/taffybar/taffybar.hs is an
  # out-of-store symlink to it. If the probe's text ever lands there the bar is
  # silently replaced, so refuse before touching anything. It has happened.
  if rg -q 'Probe config for tests/hyprland-nest' "$REPO_HS" 2>/dev/null; then
    die "$REPO_HS holds cfg/taffybar.hs's probe text, not the user's config. Restore it first."
  fi
  # Anything inherited from the live session would let the child find the user's
  # bus or socket. All of it is overwritten below, so it is reported and dropped
  # rather than refused — but only when it really was somebody else's.
  if [ "${XDG_RUNTIME_DIR:-}" != "$RUN_XDGR" ] || [ "${DBUS_SESSION_BUS_ADDRESS:-}" != "unix:path=$RUN_XDGR/bus" ]; then
    info "inherited session vars dropped" "DISPLAY=${DISPLAY:-unset} XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-unset} DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS:-unset} WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-unset} HOME=$HOME"
  fi
  unset DISPLAY WAYLAND_DISPLAY WAYLAND_SOCKET DBUS_SESSION_BUS_ADDRESS XDG_SEAT \
    XDG_SESSION_ID XDG_CURRENT_DESKTOP XDG_SESSION_PATH HYPRLAND_INSTANCE_SIGNATURE || true
  export XDG_RUNTIME_DIR=$RUN_XDGR HOME=$RUN_HOME
  export XDG_CONFIG_HOME=$RUN_HOME/.config XDG_DATA_HOME=$RUN_HOME/.local/share
  export XDG_CACHE_HOME=$RUN_HOME/.cache XDG_STATE_HOME=$RUN_HOME/.local/state
  export HYPRLAND_NO_SD_VARS=1 HYPRLAND_NO_CRASHREPORTER=1
  export WLR_BACKENDS=headless WLR_RENDER_DRM_DEVICE=$RENDER WLR_RENDERER_ALLOW_SOFTWARE=1
  export LANG=C.UTF-8 LC_ALL=C.UTF-8
}

# hyprctl resolves its instance from $XDG_RUNTIME_DIR/hypr/<sig>, and <sig>
# changes every boot, so it is discovered (newest socket dir), never hardcoded.
newsig() {
  find "$XDG_RUNTIME_DIR/hypr" -maxdepth 1 -type d -name '*[!/.lock]' -printf '%T@ %f\n' 2>/dev/null \
    | sort -n | tail -n1 | cut -d' ' -f2
}
hctl() {
  local sig
  sig=$(newsig)
  [ -n "$sig" ] || { warn "no live hyprland instance under $XDG_RUNTIME_DIR/hypr"; return 1; }
  HYPRLAND_INSTANCE_SIGNATURE=$sig hyprctl "$@"
}

savepid() { echo "$2" > "$PIDS/$1"; }
getpid()  { cat "$PIDS/$1" 2>/dev/null || true; }

# hyprland's launcher pid is not the server pid (the watchdog re-execs with the
# same argv), so recorded pids alone leak orphans. pgrep -f matches the command
# line of the shell running it and self-SIGTERMs the harness, so this walks
# /proc itself and only reports a pid when BOTH hold: argv names one of our own
# paths, and the process carries HYPRLAND_NO_SD_VARS=1 — which only this
# harness exports, so the scan can never reach the user's bar or compositor.
mine() {
  local d p c marker cfgp busp runp taffybin hlbin labwcbin
  cfgp=$CFG/hyprland.conf
  busp=$RUN_XDGR/bus
  runp=$RUN
  # argv alone is not enough here: the user's own bar runs from this exact store
  # path, and a leaked labwc looks like any other. The env marker below is what
  # keeps the scan off the user's processes — only this harness exports it.
  taffybin=${TAFFY:-$FALLBACK_TAFFYBAR}/bin/taffybar
  hlbin=${HL:-$FALLBACK_HYPRLAND}/bin/hyprland
  labwcbin=${LABWC:-$FALLBACK_LABWC}/bin/labwc
  for d in /proc/[0-9]*; do
    p=${d#/proc/}
    [ "$p" = "$$" ] && continue
    [ -r "$d/cmdline" ] || continue
    c=$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null) || continue
    case "$c" in
      *harness.sh*) continue ;;                       # never our own driver
      *"$cfgp"*|*"$busp"*|*"$runp"*|*"$taffybin"*|*"$hlbin"*|*"$labwcbin"*) ;; # ours by argv
      *) continue ;;
    esac
    [ -r "$d/environ" ] || continue
    marker=$(tr '\0' '\n' < "$d/environ" 2>/dev/null | grep -c '^HYPRLAND_NO_SD_VARS=1$' || true)
    [ "${marker:-0}" -gt 0 ] || continue
    echo "$p"
  done
}

outputs_ready() {
  local have o
  have=$(hctl -j monitors 2>/dev/null | jq -r '.[].name' 2>/dev/null | tr '\n' ' ')
  [ -n "${have// /}" ] || return 1
  for o in $OUTPUTS; do
    case " $have " in *" $o "*) ;; *) return 1 ;; esac
  done
}
client_count() { hctl -j clients 2>/dev/null | jq 'length'; }
two_clients() {
  local n
  n=$(client_count)
  [ "${n:-0}" -ge 2 ]
}
bar_surfaces() {
  hctl -j layers 2>/dev/null | jq -e '[.. | objects | select(.namespace? == "taffybar")] | length > 0' \
    >/dev/null
}

# The dyred parent waits on the bar it launches, so a parent that is gone with
# no compiled bar process anywhere means the compile failed or the bar died —
# worth knowing after two seconds rather than after a 20-minute poll timeout.
# /proc is scanned by hand because pgrep -f matches the shell running it.
bar_dead() { # bar_dead <pid> -> 0 when neither the dyre parent nor its child lives
  local p=$1 d c
  [ -n "$p" ] || return 1
  kill -0 "$p" 2>/dev/null && return 1
  for d in /proc/[0-9]*; do
    c=$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null) || continue
    case "$c" in *taffybar-linux-x86_64*) return 1 ;; esac
  done
  return 0
}

taffy_wait() { # taffy_wait <seconds>
  local limit=$1 i
  for ((i = 0; i < limit; i++)); do
    if bar_surfaces; then log "      ok: taffybar layer surfaces (${i}s)"; return 0; fi
    if bar_dead "$(getpid taffybar)"; then
      warn "taffybar is gone without ever mapping a layer surface (see logs/taffybar.out)"
      return 1
    fi
    sleep 1
  done
  warn "TIMEOUT after ${limit}s: taffybar layer surfaces"
  return 1
}

# ---------- real-config mode ----------
# ghc for dyre's run-time recompile. Resolved from the same module attribute the
# live system launches the bar with. oldpc, not mysystem: mysystem's evaluation
# dies on an unrelated /mnt/md127 ssh key path, which is not this test's bug.
resolve_ghcenv() {
  [ -n "${GHCENV:-}" ] && return 0
  if [ -f "$RUN/ghcenv" ] && [ "${REPIN:-0}" != 1 ] && [ -x "$(cat "$RUN/ghcenv")/bin/ghc" ]; then
    GHCENV=$(cat "$RUN/ghcenv")
    log "  ghcEnv: cached $GHCENV"
    return 0
  fi
  local out
  out=$(timeout "${GHCENV_TIMEOUT:-1800}" nix build --impure --no-link --print-out-paths \
    "$REPO/.?submodules=1#nixosConfigurations.oldpc.config.modules.taffybar.ghcEnv" \
    2>"$LOGS/ghcenv-nix.err" | tail -1) || { warn "nix build of modules.taffybar.ghcEnv failed (logs/ghcenv-nix.err)"; return 1; }
  [ -x "$out/bin/ghc" ] || { warn "ghcEnv has no ghc: $out"; return 1; }
  GHCENV=$out
  echo "$GHCENV" > "$RUN/ghcenv"
  log "  ghcEnv: $GHCENV"
}

# Each stub logs the argv it was called with and then fails. Lying about a
# volume would put invented pixels into the screenshots; the claim under test is
# that the bar survives with no PipeWire, not that it looks like it has one.
realbar_shims() {
  local s
  mkdir -p "$SHIM"
  : > "$LOGS/realbar-shims.log"
  for s in polypomo wpctl pactl systemd-inhibit setpriv; do
    cat > "$SHIM/$s" <<EOF
#!/bin/sh
# no-op stand-in installed by tests/hyprland-nest. argv goes to the log.
printf '%s %s\n' "$s" "\$*" >> "$LOGS/realbar-shims.log" 2>/dev/null
exit 1
EOF
    chmod +x "$SHIM/$s"
  done
  # Pass-through loggers, not stubs, for the two helpers that really do work: the
  # weather module shells out to curl and the favicon helper is python3. The
  # claim here is "we know what the bar called", not "we faked it", so the real
  # binary still runs; the store path is written into the shim while $SHIM is not
  # yet on PATH, so it cannot point back at the shim.
  for s in curl python3; do
    local realbin
    realbin=$(command -v "$s" || true)
    [ -n "$realbin" ] || continue
    cat > "$SHIM/$s" <<EOF
#!/bin/sh
# pass-through logger from tests/hyprland-nest: logs argv, then runs the real one.
printf '%s %s\n' "$s" "\$*" >> "$LOGS/realbar-shims.log" 2>/dev/null
exec "$realbin" "\$@"
EOF
    chmod +x "$SHIM/$s"
  done
  info "path shims" "$(ls "$SHIM" | tr '\n' ' ') -> logs/realbar-shims.log"
}

realbar_setup() {
  [ -r "$REPO_HS" ] || die "no real config at $REPO_HS"
  BAR_MODE=real
  echo real > "$BAR_MODE_FILE"

  # Out-of-store symlinks, the same way home.file does it in
  # modules/nixos/taffybar/default.nix. Both repo files are live: never copied
  # over, never edited, never sed'd in place.
  mkdir -p "$RUN_HOME/.config/taffybar"
  ln -sfn "$REPO_HS"  "$RUN_HOME/.config/taffybar/taffybar.hs"
  # REAL_CSS=none links an empty stylesheet instead of the repo one. That is the
  # control that separates "barHeight = ExactSize 30" from "the CSS is what
  # makes the bar come out 30 tall": with no stylesheet GTK sizes the toplevel
  # to its children, which is how the probe bar reached 41 px.
  local css_target=$REPO_CSS
  [ "${REAL_CSS:-repo}" = none ] && css_target=/dev/null
  ln -sfn "$css_target" "$RUN_HOME/.config/taffybar/taffybar.css"
  info "config links" "$(ls -l "$RUN_HOME/.config/taffybar/" | awk 'NR>1{print $9" "$10" "$11" "}')"

  # TAFFYBAR_CSS_PATHS is deliberately NOT exported: it is unset on the live
  # system too, so the repo CSS reaches the bar through the config's own
  # getTaffyFile "taffybar.css" provider (priority 100), not the env var the
  # probe mode uses.
  export TAFFYBAR_LOG=1
  unset TAFFYBAR_CSS_PATHS || true

  # The env the live launcher exports (modules.taffybar.barEnv): without
  # LOCALE_ARCHIVE, gi marshals String through the locale codeset and the glyphs
  # the config draws come out empty.
  local barenv
  barenv=$(timeout "${BARENV_TIMEOUT:-600}" nix eval --impure --raw \
    "$REPO/.?submodules=1#nixosConfigurations.oldpc.config.modules.taffybar.barEnv" \
    2>"$LOGS/barenv-nix.err" | tail -1) || barenv=
  if [ -n "$barenv" ]; then
    eval "export $barenv"
    info "barEnv (from the module)" "$barenv"
  else
    warn "could not eval modules.taffybar.barEnv; keeping preflight's LANG/LC_ALL"
  fi

  # ghcEnv first, like the waylandLaunch script does (dyre shells out to ghc to
  # recompile the config), then the shims, then the inherited PATH.
  resolve_ghcenv || die "no ghc env for dyre: the real config cannot compile"
  realbar_shims
  export PATH=$GHCENV/bin:$SHIM:$PATH

  # Record whatever the config asks polypomo to write, so the guard afterwards
  # is about the file the config actually names rather than one typed by hand.
  local guard
  guard=$(sed -n 's/.*--saveto \([^" ]*\).*/\1/p' "$REPO_HS" | head -1)
  if [ -n "$guard" ]; then
    echo "$guard" > "$SQLITE_GUARD_FILE"
    stat -c '%Y-%s' "$guard" > "$RUN/sqlite-mtime0" 2>/dev/null || echo missing > "$RUN/sqlite-mtime0"
    info "sqlite guard" "$guard mtime-size=$(cat "$RUN/sqlite-mtime0")"
  else
    warn "no --saveto path in $REPO_HS; nothing to guard"
  fi

  # The secondary bar's tray path dies on a failed SNI host registration. On the
  # live system gtk-sni-tray.service puts a watcher on the bus before the bar
  # starts; the unit orders the bar after it for exactly that reason.
  if command -v status-notifier-watcher >/dev/null; then
    setsid nohup status-notifier-watcher > "$LOGS/sni-watcher.out" 2>&1 < /dev/null &
    savepid sniwatcher $!
    sleep 1
    info "sni watcher" "pid=$(getpid sniwatcher) bus=$DBUS_SESSION_BUS_ADDRESS"
  else
    warn "no status-notifier-watcher on PATH; the tray path may take the bar down"
  fi

  # Dyre asks "did the config change?" by comparing mtimes, and getModificationTime
  # follows symlinks: that is the repo file's mtime, not the link's. A binary
  # compiled after the last edit therefore never recompiles, and the run grades a
  # stale bar — which is exactly what happened on the first real run here. Real
  # mode compiles from scratch so the assertion always describes the repo file.
  if [ "${REAL_CLEAN:-1}" = 1 ]; then
    rm -rf "$RUN_HOME/.cache/taffybar" "$RUN_HOME/.local/lib/taffybar" "$RUN_HOME/.local/share/taffybar"
    info "dyre cache" "cleared (REAL_CLEAN=0 keeps ghc's objects; the staleness rule below still applies)"
  fi
  # Not "REAL_CLEAN=0 means trust the binary": a binary older than the config is
  # the one bug that makes every pixel assertion describe a different program. The
  # runs that looked best here were graded against exactly such a binary.
  local bin=$RUN_HOME/.cache/taffybar/taffybar-linux-x86_64.taffybar-wrapped
  if [ -e "$bin" ] && [ "$bin" -ot "$REPO_HS" ]; then
    warn "dyred binary ($(stat -c %y "$bin" | cut -d. -f1)) is older than taffybar.hs ($(stat -c %y "$REPO_HS" | cut -d. -f1)); deleting it"
    rm -f "$bin"
  fi

  # A cold dyred compile of a 1800-line config is minutes, not the probe's 13 s.
  BAR_LIMIT=${BAR_LIMIT:-1200}
}

# ---------- band measurement ----------
# Height the bar's own layer surface got, so crops follow the bar instead of
# assuming the probe's 30 px.
band_h_px() {
  hctl -j layers 2>/dev/null \
    | jq -r '[.. | objects | select(.namespace? == "taffybar") | .h] | max // 0'
}

strip_crop() { # <output> <png> <band-height> [width]
  local o=$1 out=$2 bh=$3 w=${4:-$MOVE_BAND_W}
  timeout 15 grim -o "$o" "$ART/.full-$o.png" || return 1
  magick "$ART/.full-$o.png" -crop "${w}x${bh}+0+$((OUT_H - bh))" +repage "$out"
}

# Leftmost column of the memory plate. It is the first solid block to the right
# of the workspace buttons on both bars, so its column index measures "how many
# workspace buttons does this bar have" without reading any text.
purple_first() { # <png> -> column index, or -1
  local img=$1 col
  [ -s "$img" ] || { printf '%s\n' -1; return; }
  col=$(magick "$img" -fuzz "$COLOR_FUZZ" -fill '#00ff00' -opaque "$MEMORY_COLOR" \
        -fill '#000000' +opaque '#00ff00' -fill '#ffffff' -opaque '#00ff00' \
        -scale 'x1!' -depth 8 txt:- 2>/dev/null \
        | awk -F'[,:]' 'NR>1 { gsub(/[^0-9]/, "", $3); if ($3+0 > 128) { print $1; exit } }')
  printf '%s\n' "${col:--1}"
}

# ---------- phases ----------
up() {
  preflight
  load_pins
  # Two harness compositors at once would let the assertions read the wrong
  # instance (newsig picks the newest socket dir), so the old one goes first.
  local strays
  strays=$(mine | tr '\n' ' ')
  if [ -n "${strays// /}" ]; then
    warn "harness instance already running ($strays) — taking it down first"
    down
  fi
  rm -f "$RUN_XDGR"/wayland-*.lock
  rm -rf "$RUN_XDGR"/hypr

  # 0. taffybar dials unix:path=$XDG_RUNTIME_DIR/bus (GTK settings, SNI); a bus
  #    inside the private runtime dir keeps the user's real one out of it.
  if [ ! -S "$RUN_XDGR/bus" ]; then
    setsid nohup dbus-daemon --session --address=unix:path="$RUN_XDGR/bus" > "$LOGS/bus.out" 2>&1 < /dev/null &
    savepid bus $!
    wait_for "private dbus bus" 20 test -S "$RUN_XDGR/bus" \
      || die "private bus never appeared: $(tail -5 "$LOGS/bus.out" 2>/dev/null)"
  fi
  export DBUS_SESSION_BUS_ADDRESS=unix:path="$RUN_XDGR/bus"

  # 1. parent: labwc (wlroots) headless. A parent must advertise
  #    zwp_linux_dmabuf_v1 >= 4 and actually send main_device or aquamarine
  #    finds no allocator; sway boots fine and still fails the child that way.
  log "  starting parent labwc ($LABWC)"
  stdbuf -o0 -e0 setsid nohup "$LABWC/bin/labwc" > "$LOGS/parent.out" 2>&1 < /dev/null &
  savepid parent $!
  parent_socket() {
    find "$RUN_XDGR" -maxdepth 1 -name 'wayland-*' ! -name '*.lock' -printf '%T@ %f\n' 2>/dev/null \
      | sort -n | tail -1 | cut -d' ' -f2
  }
  parent_ready() { [ -n "$(parent_socket)" ]; }
  wait_for "parent wayland socket" 30 parent_ready \
    || die "labwc produced no wayland socket: $(tail -20 "$LOGS/parent.out" 2>/dev/null)"
  export WAYLAND_DISPLAY=$(parent_socket)
  echo "parent=labwc pid=$(getpid parent) socket=$WAYLAND_DISPLAY"

  # 2. child: Hyprland as a client of that parent.
  child_socket() { sed -n 's/.*Running on WAYLAND_DISPLAY: \([^ ]*\).*/\1/p' "$LOGS/child.out" | tail -1; }
  child_ready() { [ -n "$(child_socket)" ]; }
  log "  starting child hyprland ($HL)"
  stdbuf -o0 -e0 setsid nohup "$HL/bin/hyprland" --config "$CFG/hyprland.conf" > "$LOGS/child.out" 2>&1 < /dev/null &
  savepid child $!
  wait_for "child hyprland on its own wayland socket" 60 child_ready \
    || die "child never printed its WAYLAND_DISPLAY: $(tail -30 "$LOGS/child.out" 2>/dev/null)"
  export CHILD_SOCKET=$(child_socket)
  echo "CHILD_SOCKET=$CHILD_SOCKET" > "$PIDS/env"
  echo "child=hyprland pid=$(getpid child) socket=$CHILD_SOCKET sig=$(newsig)"
  # the exact line a parent without working dmabuf produces
  grep -c 'Cannot open backend: no allocator available' "$LOGS/child.out" | sed 's/^/allocator failures: /' || true

  # 3. headless outputs. The nested parent never sends xdg_toplevel.configure,
  #    so aquamarine's WAYLAND-1 output gets no modes, Hyprland times out into
  #    its FALLBACK monitor and tears that down again. The outputs we drive are
  #    created explicitly, and they must exist before taffybar starts: the bar
  #    set is built at start-up, and hot-plugging tears the bars down.
  local o
  for o in $OUTPUTS; do hctl output create headless "$o"; done
  wait_for "$OUTPUTS in hyprctl monitors" 30 outputs_ready \
    || die "outputs never appeared: $(hctl -j monitors 2>/dev/null | jq -c '.[] | {name}' | tr '\n' ' ')"

  # The layout the outputs actually got. `output create headless` parks them all
  # at 0x0, and this repo's bar matches a bar to its monitor by layout position,
  # so co-located outputs cannot show whether that match is per-bar or global.
  # The named monitor= rules in cfg/hyprland.conf space them out; there is no
  # working runtime form (`hyprctl monitor name,desc` answers "unknown
  # request"), so this verifies instead of trying, and says so if the rules
  # stop applying rather than letting the per-bar assertion degrade quietly.
  if [ "$OUT_REPOS" = 1 ]; then
    local nout ndist
    nout=$(set -- $OUTPUTS; echo $#)
    info "layout" "$(hctl -j monitors 2>/dev/null | jq -c '[.[] | {name, x, y}]' | tr '\n' ' ')"
    ndist=$(hctl -j monitors 2>/dev/null | jq -r --arg o "$OUTPUTS" '[$o | split(" ")[]] as $names | [.[] | select(.name as $n | $names | index($n)) | .x] | unique | length')
    [ "${ndist:-0}" = "$nout" ] || warn "outputs are not side by side (want $nout distinct x, got ${ndist:-0}): per-bar monitor matching is unmeasurable, check the monitor= rules in $CFG/hyprland.conf"
  fi
  # Persistent workspace rules only fire when their monitor arrives; the reload
  # re-reads them after the hotplug so the empty workspaces materialise.
  hctl reload >/dev/null 2>&1 || true
  sleep 2

  # Hard stop, not a warning: a config error draws Hyprland's error bar, which
  # reserves space on a monitor and would quietly falsify the exclusive-zone
  # assertion below.
  local cfgerr
  cfgerr=$(hctl configerrors 2>/dev/null || true)
  if [ -n "${cfgerr// /}" ]; then
    printf '%s\n' "$cfgerr" >&2
    die "hyprland reports config errors — fix $CFG/hyprland.conf before trusting any measurement"
  fi

  # one window on each of two workspaces, so the strip has content to render
  hctl dispatch exec "[workspace 3] foot" >/dev/null
  hctl dispatch exec "[workspace 5] foot" >/dev/null
  wait_for "two foot clients mapped" 25 two_clients || warn "expected 2 foot clients, got ${client_count:-0}"
  sleep 2
}

loadenv() { set +u; . "$PIDS/env" 2>/dev/null; export CHILD_SOCKET; set -u; }

into_child() { # export the child's socket for any Wayland client we spawn
  loadenv
  [ -n "${CHILD_SOCKET:-}" ] || die "no CHILD_SOCKET recorded — run 'up' first"
  export WAYLAND_DISPLAY=$CHILD_SOCKET
  export HYPRLAND_INSTANCE_SIGNATURE=$(newsig)
  unset DISPLAY || true
}

taffy() {
  preflight
  load_pins
  into_child
  export GDK_BACKEND=wayland XDG_SESSION_TYPE=wayland
  export DBUS_SESSION_BUS_ADDRESS=unix:path="$RUN_XDGR/bus"
  # icons/schemas come from the system profile; read-only, never the user's
  export XDG_DATA_DIRS=${XDG_DATA_DIRS:-/run/current-system/sw/share}
  local limit=300 what=cfg/taffybar.hs
  if [ "$REAL" = 1 ]; then
    realbar_setup
    # A cold dyred compile of the live config is minutes, not the probe's 13 s.
    limit=${BAR_LIMIT:-1200}
    what="the repo's taffybar.hs (CSS: $REPO_CSS)"
  else
    BAR_MODE=probe
    echo probe > "$BAR_MODE_FILE"
    # The probe config, not the user's: the real bar needs a live SNI host,
    # PipeWire and network widgets, and dies on its tray path without them.
    cp "$CFG/taffybar.hs" "$RUN_HOME/.config/taffybar/taffybar.hs"
    # Read at bar start-up, not compile time, so the repo path never gets baked
    # into the dyred binary and the config stays the same file everywhere.
    export TAFFYBAR_CSS_PATHS=$CFG/taffybar.css
  fi
  log "  starting taffybar ($TAFFY) with $what (a cold first run compiles via ghc+dyre)"
  setsid nohup "$TAFFY/bin/taffybar" > "$LOGS/taffybar.out" 2>&1 < /dev/null &
  savepid taffybar $!
  # Layer surfaces are the observable "the bar is up" signal; polling replaces
  # the old fixed 55 s sleep, which was too short on a cold compile and wasted a
  # minute on a warm one.
  taffy_wait "$limit" \
    || { warn "no taffybar layer surfaces after ${limit}s"; warn "tail of logs/taffybar.out:"; tail -40 "$LOGS/taffybar.out" >&2 || true; return 1; }
}

# Everything the live config can be graded on and the probe cannot: what it
# logged about its own monitor matching, whether a fallback took over, whether
# any X11 path woke up, and whether the per-bar workspace filter moves with the
# compositor. The probe bar logs nothing, matches no monitors and filters
# nothing, so none of this is observable from it.
# Surface presence is not readiness: a cold dyred compile maps its layer window
# seconds before the widgets are painted, and the first runs of this section
# asserted against a half-built bar. "The band stopped changing" is no good
# either — the clock ticks and the memory module re-renders, so it never settles —
# so the gate waits for the same thing the move checks measure: a memory plate.
realbar_wait_widgets() {
  local w1=${OUTPUTS%% *} w2=${OUTPUTS##* } bh c1 c2
  bh=$(band_h_px); bh=${bh:-30}
  # 420 px contains the plate on either bar (measured col 338 and 251) and leaves
  # the centred clock out of every sample.
  local ready_w=${READY_BAND_W:-420} t0=$SECONDS
  while :; do
    strip_crop "$w1" "$ART/.ready-1.png" "$bh" "$ready_w" || true
    strip_crop "$w2" "$ART/.ready-2.png" "$bh" "$ready_w" || true
    c1=$(purple_first "$ART/.ready-1.png"); c2=$(purple_first "$ART/.ready-2.png")
    if [ "$c1" != -1 ] && [ "$c2" != -1 ]; then
      info "bar widgets built" "memory plate on both bands (col $c1 / $c2) after $((SECONDS-t0))s"
      return 0
    fi
    bar_dead "$(getpid taffybar)" && { warn "bar died while its widgets were being built"; return 1; }
    [ $((SECONDS-t0)) -ge "${WIDGET_LIMIT:-60}" ] && { warn "no memory plate on both bands after $((SECONDS-t0))s (c1=$c1 c2=$c2)"; return 1; }
    sleep 2
  done
}

real_checks() {
  local log=$LOGS/taffybar.out
  local json bars n_bars distinct first second unresolved refresh_failed x11 other
  local w1=${OUTPUTS%% *} w2=${OUTPUTS##* }
  local bh active target a1 a2 b1 b2 c1 c2 d1 d2 ae1 ae2 after
  local mvmin=${MOVE_MIN_PX:-10}

  realbar_wait_widgets || true

  # ---- what the config said about itself ----
  info "bar log lines" "$(count "^taffybar: " "$log") taffybar: line(s) in logs/taffybar.out"
  grep '^taffybar: ' "$log" 2>/dev/null | sed 's/^/      /' || true
  info "other bar stderr" "$(grep -vc '^taffybar: ' "$log" 2>/dev/null || echo 0) non-taffybar line(s); first 25:"
  grep -v '^taffybar: ' "$log" 2>/dev/null | head -25 | sed 's/^/      /' || true

  # ---- 1. the two bars named two different monitors ----
  # This was written to be the point of the run, and it is only observable when the
  # config logs at all: the repo config emits no trail, so this is reported as a
  # skip rather than let pass on an empty grep. The per-monitor split is asserted in
  # pixels (move-reacts-both-bars) whenever a plate exists to measure.
  n_bars=$(count "^taffybar: bar monitor: " "$log")
  bars=$(sed -n 's/^taffybar: bar monitor: //p' "$log" | sort -u)
  distinct=$(printf '%s\n' "$bars" | grep -c . || true)
  first=$(printf '%s\n' "$bars" | head -1)
  second=$(printf '%s\n' "$bars" | sed -n '2p')
  if [ "$(count '^taffybar: ' "$log")" = 0 ]; then
    warn "bar-monitor-distinct SKIPPED: the config logs nothing, so stderr cannot show which monitor each bar resolved (see move-reacts-both-bars for the pixel version)"
  else
    check "bar-monitor-distinct" \
      "$([ "${distinct:-0}" = 2 ] && printf '%s\n' "$bars" | grep -qx "$w1" && printf '%s\n' "$bars" | grep -qx "$w2" && echo 0 || echo 1)" \
      "lines=$n_bars distinct=${distinct:-0} [${first:-none}, ${second:-none}] want [$w1, $w2]"
  fi
  info "geometry match lines" "$(sed -n 's/^taffybar: monitor /monitor /p' "$log" | tr '\n' ';')"

  # ---- 2. no fallback took over ----
  unresolved=$(count 'bar monitor unresolved' "$log")
  refresh_failed=$(count 'workspace monitor refresh failed' "$log")
  check "no-bar-monitor-unresolved" "$([ "$unresolved" = 0 ] && echo 0 || echo 1)" "count=$unresolved (the numeric 1-6/7-12 split would have hidden a broken match)"
  check "no-workspace-refresh-failed" "$([ "$refresh_failed" = 0 ] && echo 0 || echo 1)" "count=$refresh_failed"

  # ---- 2b. the dispatch the scroll path sends actually lands ----
  # Hyprland 0.56.2 parses `dispatch <rest>` as Lua when the config is Lua — so the
  # documented `dispatch workspace m+1` is a Lua syntax error there (hyprctl fails
  # it too) and only `hl.dsp.focus({workspace="m+1"})` lands. With a hyprlang
  # config — what this harness boots — it is the other way round. Scroll cannot be
  # injected here, so this pins the assumption instead of measuring it: whichever
  # spelling this compositor accepts must be one the config will try. The forms
  # mirror workspaceSwitchForms in taffybar.hs; checks 30–32 of
  # tests/taffybar-workspace-filter pin those bytes from the Haskell side.
  sig=$(newsig)
  sock="$XDG_RUNTIME_DIR/hypr/$sig/.socket.sock"
  send_cmd() { # send_cmd <command bytes> -> first line of the reply
    [ -S "$sock" ] || { printf 'no command socket at %s\n' "$sock"; return; }
    python3 -c '
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sys.argv[1])
s.sendall(sys.argv[2].encode())
s.shutdown(1)
print(s.recv(2048).decode(errors="replace")[:120])
' "$sock" "$1" 2>&1 | tr -d '\n'
  }
  lua_reply=$(send_cmd 'dispatch hl.dsp.focus({workspace="m+1"})')
  legacy_reply=$(send_cmd 'dispatch workspace m+1')
  check "dispatch-payload-lands" \
    "$( { printf '%s' "$lua_reply" | rg -q '^ok' || printf '%s' "$legacy_reply" | rg -q '^ok'; } && echo 0 || echo 1)" \
    "lua form -> ${lua_reply:0:60} | legacy form -> ${legacy_reply:0:60} (the config tries both and caches the winner)"

  # ---- 3. nothing X11 woke up ----
  x11=$(count 'X11|BadAtom|cannot open display|NullPtr|callStack' "$log")
  check "no-x11-exception-text" "$([ "$x11" = 0 ] && echo 0 || echo 1)" "matches=$x11"
  [ "$x11" = 0 ] || grep -En 'X11|BadAtom|cannot open display|NullPtr|callStack' "$log" | head -10 | sed 's/^/      /'

  # ---- 4. polypomo never wrote through the shims ----
  local guard base now
  guard=$(cat "$SQLITE_GUARD_FILE" 2>/dev/null || true)
  if [ -n "$guard" ] && [ -f "$RUN/sqlite-mtime0" ]; then
    base=$(cat "$RUN/sqlite-mtime0")
    now=$(stat -c '%Y-%s' "$guard" 2>/dev/null || echo missing)
    info "sqlite guard" "$guard before=$base after=$now"
    check "polypomo-sqlite-untouched" "$([ "$base" = "$now" ] && echo 0 || echo 1)" "mtime+size unchanged (before=$base after=$now)"
  elif [ -n "$guard" ]; then
    check "polypomo-sqlite-untouched" 1 "no baseline recorded for $guard"
  fi

  # ---- 5. the filter reacts to a workspace changing monitor, in pixels ----
  bh=$(band_h_px)
  case "${bh:-}" in ''|*[!0-9]*) bh=$BAND_H ;; esac
  info "band height (measured)" "${bh}px per layer surface (barHeight asks for 30; every crop below follows this)"

  json=$(hctl -j workspaces)
  active=$(jq -r --arg o "$w1" 'map(select(.name == $o)) | .[0].activeWorkspace.name // empty' <<<"$(hctl -j monitors)")
  # A numbered workspace on bar 1 that is not the one bar 1 has active: moving
  # the active workspace also moves focus, which repaints plates for a reason
  # that has nothing to do with the filter. Prefer one holding no windows.
  target=$(jq -r --arg o "$w1" --arg a "${active:-}" \
    '[.[] | select(.monitor == $o and (.name | test("^[0-9]+$")) and .name != $a)] | sort_by(.windows == 0) | .[-1].name // empty' <<<"$json")
  if [ -z "$target" ]; then
    check "move-reacts-both-bars" 1 "no numbered non-active workspace on $w1 to move"
    return
  fi

  strip_crop "$w1" "$ART/real-move-1-before.png" "$bh" \
    || { check "move-reacts-both-bars" 1 "grim failed on $w1"; return; }
  strip_crop "$w2" "$ART/real-move-2-before.png" "$bh" \
    || { check "move-reacts-both-bars" 1 "grim failed on $w2"; return; }
  a1=$(purple_first "$ART/real-move-1-before.png")
  a2=$(purple_first "$ART/real-move-2-before.png")
  info "memory plate before move" "$w1 col=$a1 $w2 col=$a2 (left edge of $MEMORY_COLOR)"
  check "memory-plate-found" "$([ "$a1" != -1 ] && [ "$a2" != -1 ] && echo 0 || echo 1)" "$w1=$a1 $w2=$a2 (want a $MEMORY_COLOR column on both bars)"
  [ "$a1" != -1 ] && [ "$a2" != -1 ] || return

  # 0.56.2 has no `moveworkspace` dispatcher — hyprctl answers "Invalid
  # dispatcher" and exits 0 (README trap 11: nothing is trustworthy from a
  # dispatch's exit status), so each candidate name is verified by reading the
  # workspace's monitor back before trusting it. moveworkspacetomonitor is the
  # name this build registers.
  local cand disp="" movedisp=""
  for cand in moveworkspacetomonitor moveworkspace; do
    hctl dispatch "$cand" "$target" "$w2" >"$LOGS/move.out" 2>&1 || true
    sleep 3
    after=$(jq -r --arg n "$target" 'map(select(.name == $n)) | .[0].monitor // "gone"' <<<"$(hctl -j workspaces)")
    [ "$after" = "$w2" ] && { disp=$cand; break; }
  done
  movedisp=$disp
  info "move step" "dispatch ${movedisp:-<none worked>} $target $w2 -> hyprctl monitor=${after:-?} (was $w1); hyprctl said: $(tr '\n' ' ' < "$LOGS/move.out" 2>/dev/null)"
  if [ -z "$movedisp" ]; then
    check "move-reacts-both-bars" 1 "no workspace-move dispatcher worked (monitor=${after:-?}); dispatch said: $(tr '\n' ' ' < "$LOGS/move.out" 2>/dev/null)"
    return
  fi

  # The filter is event-driven with a 15 s poll as a backstop, so give it room
  # instead of assuming a frame time, and report how long it actually took.
  local t=0 y1 y2
  for ((t = 0; t < 30; t++)); do
    strip_crop "$w1" "$ART/real-move-1-after.png" "$bh" || true
    strip_crop "$w2" "$ART/real-move-2-after.png" "$bh" || true
    y1=$(purple_first "$ART/real-move-1-after.png")
    y2=$(purple_first "$ART/real-move-2-after.png")
    [ "${y1:-$a1}" != "$a1" ] && break
    sleep 1
  done
  b1=$y1
  b2=$y2
  info "filter refresh latency" "${t}s for $w1's plate to move (event-driven, 15s poll backstop)"
  # Bar 1 loses a button, so its plate slides left; bar 2 gains one, so its
  # plate slides right. Both deltas are a button width, and positive here.
  d1=$((a1 - b1))
  d2=$((b2 - a2))
  ae1=$(compare -metric AE "$ART/real-move-1-before.png" "$ART/real-move-1-after.png" null: 2>&1 || true)
  ae2=$(compare -metric AE "$ART/real-move-2-before.png" "$ART/real-move-2-after.png" null: 2>&1 || true)
  info "memory plate after move" "$w1 col=$b1 shift=${d1}px  $w2 col=$b2 shift=${d2}px"
  info "left-strip changed pixels" "$w1=${ae1%% *} $w2=${ae2%% *}"
  check "move-reacts-both-bars" \
    "$(awk -v a="$d1" -v b="$d2" -v mn="$mvmin" 'BEGIN { print (a >= mn && b >= mn) ? 0 : 1 }')" \
    "$w1 lost workspace $target (plate slid left ${d1}px), $w2 gained it (plate slid right ${d2}px); want >=${mvmin}px on both"
  check "move-shift-symmetric" \
    "$(awk -v a="$d1" -v b="$d2" 'BEGIN { d = a - b; if (d < 0) d = -d; print d <= 10 ? 0 : 1 }')" \
    "button-width deltas ${d1}px vs ${d2}px (want within 10px)"
  magick "$ART/real-move-1-before.png" "$ART/real-move-1-after.png" +append "$ART/real-move-bar1.png" 2>/dev/null || true
  magick "$ART/real-move-2-before.png" "$ART/real-move-2-after.png" +append "$ART/real-move-bar2.png" 2>/dev/null || true

  # Back again: the columns must return, or the "shift" was a redraw artefact.
  hctl dispatch "$movedisp" "$target" "$w1" >/dev/null 2>&1 || true
  sleep 5
  strip_crop "$w1" "$ART/real-move-1-back.png" "$bh" || true
  strip_crop "$w2" "$ART/real-move-2-back.png" "$bh" || true
  c1=$(purple_first "$ART/real-move-1-back.png")
  c2=$(purple_first "$ART/real-move-2-back.png")
  check "move-reversible" \
    "$(awk -v x="$c1" -v a="$a1" -v y="$c2" -v b="$a2" 'BEGIN { d1 = x - a; if (d1 < 0) d1 = -d1; d2 = y - b; if (d2 < 0) d2 = -d2; print (d1 <= 2 && d2 <= 2) ? 0 : 1 }')" \
    "after moving $target back: $w1 col=$c1 $w2 col=$c2 (started at $a1/$a2, want within 2px)"
}

assert() {
  preflight
  into_child
  BAR_MODE=$(cat "$BAR_MODE_FILE" 2>/dev/null || echo probe)
  local o n json res before after back mean colors special ae ae2 active hlsocks
  local strip_a=$ART/react-a.png strip_b=$ART/react-b.png strip_c=$ART/react-c.png
  local o_first=${OUTPUTS%% *} o_last=${OUTPUTS##* }

  # ---- 1. one taffybar layer surface per output ----
  json=$(hctl -j layers) || die "hyprctl -j layers failed"
  echo "$json" > "$ART/layers.json"
  info "layer surfaces" "$(jq -c 'to_entries[] | {out: .key, bars: [.value.levels | to_entries[] | .value[] | {ns: .namespace, x, y, w, h} | select(.ns == "taffybar")]}' <<<"$json" | tr '\n' ' ')"
  for o in $OUTPUTS; do
    n=$(jq --arg o "$o" '[(.[$o].levels // {}) | to_entries[] | .value[] | select(.namespace == "taffybar")] | length' <<<"$json")
    check "layer-per-output:$o" "$([ "$n" = 1 ] && echo 0 || echo 1)" "namespace=taffybar surfaces=$n want=1"
  done

  # ---- 2. exclusive zone reserved per output ----
  json=$(hctl -j monitors) || die "hyprctl -j monitors failed"
  echo "$json" > "$ART/monitors.json"
  info "monitors" "$(jq -c '.[] | {name, width, height, reserved}' <<<"$json" | tr '\n' ' ')"
  if [ "$BAR_MODE" = real ]; then
    # 30 px is the probe's expectation. The live CSS is not the flattening one,
    # so what the live config promises is only that both bars reserve the same
    # zone; its size is this run's measurement, not its assertion.
    local r1 r2
    r1=$(jq -r --arg o "$o_first" 'map(select(.name == $o)) | .[0].reserved | @csv' <<<"$json")
    r2=$(jq -r --arg o "$o_last" 'map(select(.name == $o)) | .[0].reserved | @csv' <<<"$json")
    check "reserved-zone-equal" "$([ -n "$r1" ] && [ "$r1" = "$r2" ] && echo 0 || echo 1)" "$o_first=[$r1] $o_last=[$r2]"
    info "reserved height (measured)" "bottom zone $(awk -F, '{print $4+0}' <<<"$r1")px per output; barHeight asks for 30"
  else
    for o in $OUTPUTS; do
      res=$(jq -r --arg o "$o" 'map(select(.name == $o)) | .[0].reserved | @csv' <<<"$json")
      check "reserved-zone:$o" "$([ "$res" = "0,0,0,30" ] && echo 0 || echo 1)" "reserved=[$res] want=[0,0,0,30]"
    done
  fi

  # ---- 3. empty persistent workspaces are listed ----
  json=$(hctl -j workspaces) || die "hyprctl -j workspaces failed"
  echo "$json" > "$ART/workspaces.json"
  local empty_total empty_by_mon
  empty_total=$(jq '[.[] | select(.windows == 0 and (.name | test("^[0-9]+$")))] | length' <<<"$json")
  empty_by_mon=$(jq -c 'group_by(.monitor) | map({mon: .[0].monitor, listed: length, empty: (map(select(.windows == 0 and (.name | test("^[0-9]+$"))) | length) | length)})' <<<"$json")
  info "numbered workspaces" "$empty_by_mon"
  check "persistent-workspaces-listed" "$([ "${empty_total:-0}" -gt 0 ] && echo 0 || echo 1)" "numbered workspaces with windows==0: $empty_total (want >0)"

  # ---- 4. specials appear in the same list, and are identifiable ----
  hctl dispatch togglespecialworkspace test >/dev/null
  sleep 2
  json=$(hctl -j workspaces)
  echo "$json" > "$ART/workspaces-special.json"
  special=$(jq -c '[.[] | select((.id < 0) or ((.name // "") | startswith("special:")) or ((.special_name // "") != ""))]' <<<"$json")
  info "special entries" "$special"
  special_detail=$(jq -r '"count=\(length) first=" + ((.[0] // {}) | "id=\(.id // "-") name=\(.name // "-") special_name=\(.special_name // "-")")' <<<"$special")
  check "specials-listed" "$(echo "$special" | jq -e 'length > 0' >/dev/null && echo 0 || echo 1)" "togglespecialworkspace test -> $special_detail"

  # ---- 5. `dispatch workspace m±1` changes the active workspace of that monitor ----
  # `dispatch -m <mon> workspace N` is not valid hyprctl syntax in 0.56.2
  # (prints usage, rc 1), so the monitor is focused first. Without focusmonitor
  # the switch lands on whichever monitor holds focus.
  hctl dispatch focusmonitor headless-1 >/dev/null
  sleep 2
  before=$(jq -r 'map(select(.name == "headless-1")) | .[0].activeWorkspace.name' <<<"$(hctl -j monitors)")
  hctl dispatch workspace m+1 >/dev/null
  sleep 3
  after=$(jq -r 'map(select(.name == "headless-1")) | .[0].activeWorkspace.name' <<<"$(hctl -j monitors)")
  check "workspace-m+1-active" "$([ -n "$before" ] && [ -n "$after" ] && [ "$before" != "$after" ] && echo 0 || echo 1)" "headless-1 activeWorkspace $before -> $after"
  hctl dispatch workspace m-1 >/dev/null
  sleep 3
  back=$(jq -r 'map(select(.name == "headless-1")) | .[0].activeWorkspace.name' <<<"$(hctl -j monitors)")
  check "workspace-m-1-active" "$([ -n "$before" ] && [ "$before" = "$back" ] && echo 0 || echo 1)" "headless-1 activeWorkspace $after -> $back (want $before)"

  # ---- 6. the bar band is real pixels, and reacts to window state ----
  for o in $OUTPUTS; do
    if ! timeout 15 grim -o "$o" "$ART/$o.png"; then
      check "band-not-black:$o" 1 "grim failed for $o"
      continue
    fi
    magick "$ART/$o.png" -crop "${OUT_W}x${BAND_H}+0+$((OUT_H - BAND_H))" +repage "$ART/$o-band.png"
    mean=$(identify -format '%[mean]' "$ART/$o-band.png")
    colors=$(identify -format '%k' "$ART/$o-band.png")
    info "frame stats:$o" "$(identify -format 'full %wx%h mean=%[mean]' "$ART/$o.png") | $(identify -format 'band %wx%h mean=%[mean] entropy=%[entropy] colors=%k' "$ART/$o-band.png")"
    check "band-not-black:$o" "$(awk -v m="$mean" -v mn="$BAND_MEAN_MIN" -v c="$colors" -v cc="$BAND_COLORS_MIN" 'BEGIN { print (m > mn && c > cc) ? 0 : 1 }')" "band mean=$mean (>$BAND_MEAN_MIN) colors=$colors (>$BAND_COLORS_MIN)"
  done

  # The full band is a useless diff target: the clock redraws every second, so
  # pixels move with no compositor change at all. Crop the left strip, which is
  # workspace buttons only, and drive it by opening then moving a window.
  timeout 15 grim -o headless-1 "$ART/react-0.png"
  magick "$ART/react-0.png" -crop "${STRIP_W}x${BAND_H}+0+$((OUT_H - BAND_H))" +repage "$strip_a"
  active=$(jq -r 'map(select(.name == "headless-1")) | .[0].activeWorkspace.name' <<<"$(hctl -j monitors)")
  hctl dispatch exec "[workspace ${active:-1}] foot" >/dev/null
  sleep 4
  timeout 15 grim -o headless-1 "$ART/react-1.png"
  magick "$ART/react-1.png" -crop "${STRIP_W}x${BAND_H}+0+$((OUT_H - BAND_H))" +repage "$strip_b"
  ae=$(compare -metric AE "$strip_a" "$strip_b" null: 2>&1 || true)
  # then move that window off the workspace, which takes its button away again.
  # 0.56's `movewindow` only takes directions and mon: — the workspace form is
  # `movetoworkspace`, and it needs a focused window, which nothing has set in a
  # nested instance with no keyboard and no pointer: focuswindow first.
  local target
  if [[ "${active:-}" =~ ^[0-9]+$ ]]; then
    target=$((active + 1))
    hctl dispatch focuswindow class:foot >/dev/null 2>&1
    hctl dispatch movetoworkspace "$target" >/dev/null 2>&1
    info "move step" "focuswindow class:foot + movetoworkspace $target"
  else
    info "move step" "active workspace '${active:-?}' is not numbered; fell back to closeactive"
    hctl dispatch closeactive >/dev/null
  fi
  sleep 4
  timeout 15 grim -o headless-1 "$ART/react-2.png"
  magick "$ART/react-2.png" -crop "${STRIP_W}x${BAND_H}+0+$((OUT_H - BAND_H))" +repage "$strip_c"
  ae2=$(compare -metric AE "$strip_b" "$strip_c" null: 2>&1 || true)
  info "strip deltas (px)" "open=${ae%% *} moved=${ae2%% *}"
  check "band-reacts-to-window" "$(awk -v a="${ae%% *}" -v b="${ae2%% *}" -v mn="$REACT_MIN_PX" 'BEGIN { print ((a + 0) > mn || (b + 0) > mn) ? 0 : 1 }')" "changed pixels open=${ae%% *} move=${ae2%% *} (want >$REACT_MIN_PX in at least one)"
  magick "$strip_a" "$strip_b" "$strip_c" -append "$ART/react-strip-states.png" 2>/dev/null || true

  # The nested instance has no keyboard and no pointer, which is why nothing here
  # can test pointer-driven behaviour; printed so the limitation is visible.
  info "input devices" "$(hctl devices 2>/dev/null | tr -s '\n' ' ' | cut -c1-160)"

  # ---- extra evidence, deliberately not an assertion ----
  # taffybar's Hyprland backend connects to the child's own event socket. Without
  # log lines at default verbosity, join taffybar's ESTAB unix socket peer inodes
  # against the fds of the harness hyprlands: >0 means a live compositor
  # connection, not hyprctl subprocesses.
  local tp p peer joined n_estab
  tp=$(getpid taffybar)
  if [ -n "$tp" ]; then
    ss -xlp 2>/dev/null | grep -o "[^ ]*$RUN_XDGR/hypr/[^ ]*/\.socket2\.sock" | head -1 | sed 's/^/      listener: /'
    hlsocks=$ART/.hlsocks
    : > "$hlsocks"
    for p in $(getpid child) $(mine); do
      [ -n "$p" ] || continue
      find /proc/$p/fd -type l -printf '%l\n' 2>/dev/null | grep -o 'socket:\[[0-9]*\]' | grep -o '[0-9]\+' >> "$hlsocks" || true
    done
    sort -u -o "$hlsocks" "$hlsocks"
    n_estab=$(ss -xp 2>/dev/null | grep "pid=$tp," | grep -c ESTAB || true)
    joined=0
    while read -r line; do
      peer=$(echo "$line" | awk '{print $8}')
      case "$peer" in *[!0-9]*) continue ;; esac
      grep -qx "$peer" "$hlsocks" && joined=$((joined + 1))
    done < <(ss -xp 2>/dev/null | grep "pid=$tp," | grep ESTAB || true)
    info "taffybar direct-socket joins" "$joined ESTAB of $n_estab (hyprland event socket, not hyprctl)"
  fi

  if [ "$BAR_MODE" = real ]; then
    real_checks
  fi

  return "$FAILS"
}

down() {
  local f p left
  for f in "$PIDS"/*; do
    p=$(cat "$f" 2>/dev/null || true)
    [ -n "$p" ] && kill "$p" 2>/dev/null || true
  done
  for p in $(mine); do kill "$p" 2>/dev/null || true; done
  sleep 3
  for f in "$PIDS"/*; do
    p=$(cat "$f" 2>/dev/null || true)
    [ -n "$p" ] && kill -9 "$p" 2>/dev/null || true
  done
  for p in $(mine); do kill -9 "$p" 2>/dev/null || true; done
  rm -f "$RUN_XDGR"/wayland-*.lock "$RUN_XDGR/bus"
  # Stale socket dirs would let newsig() pick a dead instance for a later phase.
  rm -rf "$RUN_XDGR"/hypr
  left=$(mine | tr '\n' ' ')
  if [ -n "${left// /}" ]; then
    warn "still alive after kill: $left"
  else
    echo "down: recorded pids + marker-checked strays killed, nothing left"
  fi
  rm -f "$PIDS"/*
}

# ---------- entry ----------
cmd=${1:-all}
case "$cmd" in
  pins) show_pins ;;
  up) up ;;
  taffy) taffy ;;
  taffy-real) REAL=1; taffy ;;
  assert) assert ;;
  down) preflight; down ;;
  all)
    # A half-finished `all` must not leave a compositor running for the next
    # session to find; each phase is also idempotent about strays, so this is a
    # convenience, not the only line of defence.
    trap 'warn "run aborted — taking the harness down"; down' ERR
    load_pins
    up
    taffy
    rc=0
    assert || rc=$?
    trap - ERR
    down
    printf '\n# checks=%d failed=%d%s\n' "$CHECKS" "$FAILS" "${FAILED:+ (${FAILED[*]})}"
    exit "$rc"
    ;;
  *) die "unknown phase '$cmd' (pins|up|taffy|taffy-real|assert|down|all)" ;;
esac
