# /etc/nixos — agent notes

## Testing X11/dwm changes: headless rig on `:2`

Test windows must never hit the live display `:0` — they appear as tiled
windows in the user's real dwm. Use a headless Xvfb on `:2` (no visible
window at all):

No nested servers either: Xephyr/Xnest need a host X server, so their window
lands on the user's live desktop.

Apps that reuse a running instance cross displays. `firefox --new-window` hands
the request to the instance already on `:0`, so the window opens in the user's
dwm even when launched with `DISPLAY=:2`. Shim the spawn instead: put
`/tmp/rigbin/firefox` containing
`exec /run/current-system/sw/bin/firefox --profile /tmp/ffrig "$@"` ahead of
the rig dwm's PATH (`PATH=/tmp/rigbin:/etc/nixos/bin:$PATH`; `/etc/nixos/bin`
must be there or `dwm-overlay` never spawns). Firefox maps no window at all
under Xvfb, so the six firefox overlays are only testable on the real session.

```sh
rm -f /tmp/.X2-lock /tmp/xauth_v2
xauth -f /tmp/xauth_v2 generate :2 MIT-MAGIC-COOKIE-1 2>/dev/null
setsid nohup Xvfb :2 -screen 0 1280x800x24 -nolisten tcp -auth /tmp/xauth_v2 > /tmp/xvfb2.log 2>&1 < /dev/null &
sleep 4
export XAUTHORITY=/tmp/xauth_v2 DISPLAY=:2
setxkbmap us    # mandatory: fresh servers have an empty keymap, dwm key grabs then never match
setsid nohup <dwm-binary> > /tmp/nd_v2.log 2>&1 < /dev/null &
sleep 2
setsid nohup emacs -Q > /tmp/em_v2.log 2>&1 < /dev/null &  # test client
sleep 10
```

Inspect by window attributes, not pixels:

- clients: `xprop -root _NET_CLIENT_LIST` (overlay windows are excluded from it
  on purpose, so their absence is the check, not a bug)
- per window: `xdotool getwindowgeometry --shell <win>` → `X`, `Y`, `WIDTH`,
  `HEIGHT`, `SCREEN` (`xwininfo` is not installed on this system)
- per window state: `xprop -id <win> _NET_WM_STATE _DWM_SPECIAL_TAG WM_CLASS`
- pid of a test window: `xdotool getwindowpid <win>` (wrapped binaries report a
  truncated `comm`, e.g. `.speedcrunch-wr`, so `pgrep -x speedcrunch` misses them)
- keys: `xdotool key super+c` (overlay tag 19). Prefer MODKEY bindings;
  xdotool's F-key remapping is flaky on fresh servers.

dwm specifics for this tree:

- Hidden overlay windows are **moved off-screen** by `showhide`, not unmapped;
  `ISVISIBLE` is tag-based. Debug borders via server geometry (`xwininfo`),
  never via tags or cached client x/y (stale after showhide moves).
- Overlay tags: F12=alacritty(13) … super+c=speedcrunch(19); config in
  `configs/dwm/config.h` (`specialcmds[]`, `togglespecial`).

## Building dwm without a system switch

```sh
cd /etc/nixos
nix build --impure --json \
  .#nixosConfigurations.mysystem.config.services.xserver.windowManager.dwm.package
# → outputs.out = the dwm store path; point the rig at <out>/bin/dwm
```

`--impure` is always required (config references absolute /etc/nixos paths).
The nixosConfigurations name is `mysystem`, not the hostname.

Before building, verify every patch applies to a fresh source copy
(`/nix/store/ql46y2s4…-source`, rw-copied to /tmp/dwmk):

```sh
for p in modules/nixos/dwm/patches/*.diff; do
  patch -p1 --batch --dry-run -d /tmp/dwmk < $p || echo "FAIL $p"
done
```

Unified-diff hunk headers must count exactly: ctx+del = old count,
ctx+add = new count. `patch` calls any mismatch "malformed patch".

## Deployment

The user rebuilds: `fish -c 'rebuild-default'`. Activation needs root and
there is no passwordless sudo — do not try to switch the system yourself.
A new dwm binary takes effect at the user's next login; say so.

## Process-kill gotchas

- `pgrep -f <pattern>` matches your own shell when the pattern string occurs
  in your command line — it SIGTERMs the running command (exit 143).
- After exec, cmdlines are bare: match `pgrep -x emacs`, not
  `pgrep -f "bin/emacs"`.
- `pgrep -x emacs` also matches the user's real `emacs --fg-daemon` from
  their live session. Before killing, verify each PID belongs to the rig
  (e.g. `tr -d0 \</proc/PID/environ` contains `DISPLAY=:2`), and kill only
  those.
- Xvfb `-screen` takes the screen number first: `-screen 0 1280x800x24`.
- Xvfb's own environ has no `DISPLAY`, so the environ check misses it: kill the
  rig Xvfb by the PID you recorded when starting it.
