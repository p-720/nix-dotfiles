# TODO: dwm workspace 11 order + reflow

Measured on the live session (`/tmp/p8.log`, probe = `/tmp/probe_all.c`): arriving at 11
from workspace 8 on the same monitor ran **two** layouts - tile (firefox 1340 master,
telegram 572 slave) then ff-tg (firefox 384, telegram 1536). Leaving 11 was one pass.

## Tasks

### 1. Layout must follow the view before the arrange (config.h)

- [ ] `claimtag()` picks each monitor's layout from the tagset it is about to display, so
      `view()`'s own arrange already runs ff-tg instead of tile.
- [ ] `viewtag()` stops arranging a second time when `view()` already arranged.
- [ ] `toggleviewtag()` / `tagclientto()` sync the layout the same way.

### 2. Hidden-workspace order (patch parkorder.diff)

- [ ] `showhide()` parks hidden clients at `c->x - 2 * sw` instead of `-2 * WIDTH(c)`.
      taffybar 7.4.4 sorts a workspace's window icons by real x
      (`Information/Workspaces/Support.hs:69`), and parking by width listed telegram
      (-3080) before firefox (-776) while workspace 11 was hidden.

### 3. No X round trips inside arrange (patch classcache.diff)

- [ ] Cache WM_CLASS on `Client` once in `manage()` (`c->clas`).
- [ ] `telegram()`, `hasclass()`/`pairpresent()`, `clientclassis()` read the cache.
      Each `XGetClassHint` inside arrange flushes the queued ConfigureWindow requests,
      which is what made the intermediate tile geometry visible as separate steps.
- [ ] `viewtag()` asks for firefox and telegram presence in one scan instead of two.

### 4. telegram() geometry

- [ ] Hand borders back like `tile()` does: pass `w - 2*bw`, `h - 2*bw`. The pair was 4px
      taller than the work area (h=1050 while tile gave 1046).
- [ ] Drop the trailing `restack()`: dwm 6.6 `arrange()` restacks after the layout runs.
- [ ] Pass `interact = 0` like `tile()`.

### 5. Verify (done)

- [x] Every patch applies to a fresh copy of the dwm 6.6 source, in `default.nix` order.
- [x] `nix build --impure .#nixosConfigurations.mysystem.config...dwm.package` ->
      `/nix/store/p0dcpwd6cx5aflas2jk9pqrd2yab7fb1-dwm-6.6`.
- [x] Headless `:2` rig A/B (`/tmp/rig_test.sh`, logs `/tmp/rig_old.log`,
      `/tmp/rig_new.log`): `xterm -class Firefox` + `xterm -class Telegram` reproduce the
      pair, because WM_CLASS drives both the rules and ff-tg.
      - old dwm, arriving at 11: un-park -> **tile** (Telegram 892 master, Firefox 380
        slave) -> ff-tg (256 / 1024). Parked: Telegram -2056, Firefox -520.
      - new dwm, arriving at 11: **one** arrange (Firefox 252x796 left, Telegram 1020x796
        right). Parked: Firefox -2560, Telegram -2304 - same order as on screen.
### 6. Follow-up: ff-tg bled onto the other workspaces of that monitor (fixed)

`claimtag`'s sync ran before `view()`, so it still saw workspace 11 in the tagset that
`view()` was about to replace: leaving 11 for workspace 8 left the monitor on ff-tg and
cut firefox windows to the 20% column. `viewtag` now syncs the destination monitor with
the view `view()` installs.

### 7. Follow-up: ghost column when a special is open on 11 (fixed)

`telegram()` counted the floating overlay as a tiled client and reserved a column for a
window the layout never places. Floating clients are skipped now.

Rig A/B for both (`/tmp/rig_test3.sh`), old build vs new:

| | committed build | fixed build |
|---|---|---|
| workspace 8, firefox alone | 256 wide (ff-tg column) | 1280 wide (tile) |
| 11 with a floating client | telegram 628 + dead 388 column | telegram 1020, no reserved column |

### 8. Still open

- [ ] After the user rebuilds and logs back in with the fix: re-run `/tmp/probe_all` on `:0`
      and confirm the live burst is a single arrange and workspaces 9 / 12 tile normally.
