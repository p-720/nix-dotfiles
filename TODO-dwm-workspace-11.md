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
- [ ] After the user rebuilds and logs back in: re-run `/tmp/probe_all` on `:0` and confirm
      the live session shows a single arrange burst too.
