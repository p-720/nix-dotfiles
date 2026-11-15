# TODO: native Haskell PomoTask widget for taffybar

## Goal

Put the PomoTask timer back on the primary bar as a native Haskell widget: one
long-lived TLS WebSocket inside taffybar, zero subprocesses, zero polls while idle.

## Decisions taken (from the user)

- pomotask only; `polypomo` and its `streamingCommand` stay untouched.
- click 1 = stop timer, click 3 = open the rofi launcher, scroll = shift elapsed ±60 s.
- both bars (the first cut was primary-only, changed on request), widget hidden when no
  timer is running — one shared connection, see task 4a.
- new Haskell deps in the dyre ghc env are OK (user runs `rebuild-default`; I cannot activate).
- show the running habit/task title (cached `GET /api/habits`).

## Facts established during analysis

- Server: self-hosted pomotasker (`p-720/todolist-web`) at `https://ug.kyrgyzstan.kg/pomotask`.
  Timer state is **WS-only**: `timer:sync` on connect, `timer:update`/`timer:stop` broadcast to
  every client of the user; titles come from `GET /api/habits` with `Authorization: Bearer`.
- Key file `~/Dropbox/pomotask` (one `pomo_...` line), same as the rofi backend.
- Measured live: TLS 0.22 s, WS upgrade 0.08 s, `timer:sync` at 0.30 s total.
- nixpkgs has **no `websocket`/`wuss`** client → hand-roll RFC 6455 framing on top of
  `crypton-connection` 0.4.5 (`connectTo`, `connectionGetExact`, `connectionGetChunk`,
  `connectionPut`, `connectionWaitForInput`, `TLSSettingsSimple`).
- Already built in the store (no long compile): `tls 2.1.8`, `crypton-connection 0.4.5`,
  `aeson 2.2.4.1`, `base64-bytestring 1.2.1.0`, `random 1.2.1.3`, `crypton-x509*`.
- Build path: ghc env option is `modules.taffybar.ghcEnv`, put on PATH by
  `modules/nixos/dwm/default.nix:92`; config name for this machine is `mysystem`.
- `.pomotask` CSS class already exists (`taffybar.css:102`, bg `#313244`).

## Tasks

### 1. ghc env gets the network deps

- [x] Add `crypton-connection`, `aeson`, `base64-bytestring`, `random` to the
      `ghcWithPackages` list in `modules/nixos/taffybar/ghc-env.nix`.
- [x] `nix build --impure .#nixosConfigurations.mysystem.config.modules.taffybar.ghcEnv`
      succeeds and reports the new store path.

### 2. Wire the client (pure, testable core first)

- [x] `PomoTimer` record (running, mode, startTimeMs, elapsedBeforeMs, name, activeHabitId)
      plus a `TimerMode` (Stopwatch | Timed) parsed from the server's `"stopwatch"`/`"timed"`.
- [x] `renderPomo :: PomoTimer -> Map Int Text -> Int -> Text` — pure; stopwatch
      `"<title> ⏱ 12:34"`, timed `"<title> ⏲ 04:21"` (25 min budget, remaining),
      `""` when not running. Elapsed always recomputed from `startTimeMs`, never stored.
- [x] RFC 6455 codec: client→server masked text frames, server→client unmasked,
      16/64-bit extended lengths, ping→pong, close→stop, continuation frames appended,
      **leftover bytes carried across reads** (server may coalesce two frames in one chunk).
- [x] Handshake writer/parser: `GET /pomotask/ws?key=…` + `Sec-WebSocket-Key`, accept `101`,
      consume exactly the header block, keep the socket rest for frames.
- [x] HTTPS one-shot `GET /api/habits` → `Map habitId description` (aeson, `Connection: close`),
      TTL 600 s, last-good map kept on failure.

### 3. Live check of the raw client against the real server

Harness = `/tmp/pomo/extract.py` slices the client section out of `taffybar.hs` into a
GTK-free `Client.hs` (same source text; the widget, `PomoGui` and `pomoRender` are cut by
name and stubbed), so the tested code is the shipped code and the build takes seconds
instead of linking all of gi-gtk. Re-run extract.py after editing the client section.

- [x] 60 checks, all passing: 7-bit/16-bit/64-bit lengths, coalesced frames, truncated
      header and body, masked decode, masked encode, continuation glue, all render cases,
      the `null` clears vs absent keeps merge rule, both outbound payloads.
- [x] Live against `ug.kyrgyzstan.kg`: `timer:sync` received and parsed, `ping` →
      `{"type":"pong","user":"p720"}` (that round trip is also an outbound write against the
      real server), `GET /api/habits` → 36 titles in ~130 ms, connect + upgrade 160–400 ms.
- [x] Outbound frames checked against a **second, independent** RFC 6455 implementation:
      `/tmp/pomo/fake-ws.js` (no npm deps) runs a real websocket server on 127.0.0.1:14455,
      unmasks our frames and echoes what it parsed — mask bit seen on the wire, `timer:stop`
      and the shift snapshot arrive intact, control ping answered with pong.
- [x] Mock-server test for the codec dropped as redundant: the codec is pure over a buffer,
      so those cases are unit-tested directly. The node server stayed, it covers the wire.
- [x] Scheme now decides transport: `peTls` on `PomoEndpoint`, `https://` → TLS, `http://` →
      plain TCP (port defaults 443/80). Without this the advertised
      `POMOTASK_BASE=http://127.0.0.1:3000` override could never have worked.

Four bugs found by the harness and fixed in `taffybar.hs`:
`pomoFrameLength` forced `b1` before its length guard (a 1-byte TLS record threw),
the countdown glyph was `'\127813'` (chess bishop, not ⏲ `U+23F2`), the frame mask was read
at byte 2 instead of after the extended-length field, and the stopwatch printed `1m 04s`
instead of the agreed `mm:ss`. A fifth gap came from reading the plan back: `pomoConnect`
forced TLS, so the `http://` testing override was dead.

Harness files, all in `/tmp/pomo` (not committed, and `/tmp` is wiped on reboot — the set
is small enough to regenerate from this file): `extract.py` (slices `Client.hs`),
`Main.hs` (the checks), `fake-ws.js` (the second websocket implementation).
Run: `python3 extract.py && ghc -threaded Main.hs Client.hs -o client-test`, then start
`node fake-ws.js` and `./client-test`. The ghc env store path is deterministic but does get
GC'd after a rebuild — resolve it with `nix build --impure --no-link --print-out-paths
.#nixosConfigurations.mysystem.config.modules.taffybar.ghcEnv` (which is what `build.sh` does).

### 4. The widget in `taffybar.hs`

- [x] `pomotaskWidget :: TaffyIO Gtk.Widget` — event box, class `module` + `pomotask`,
      reuses `padded`/`addWorkspaceScroll` like the other modules; hidden when idle.
- [x] Supervisor thread: connect → read loop → apply state → backoff 2 s doubling to 30 s on
      any error/EOF; `connectionWaitForInput` so a 90 s silence forces a reconnect.
      Outbound `{"type":"ping"}` every 30 s keeps the tunnel warm.
- [x] Render path: state change or the 1 s tick (only while running, sleeping to the next
      whole second instead of a fixed 1 s poll) → render text → `postGUIASync`
      `labelSetText` + `widgetQueueResize` **only when the string actually changed**.
- [x] Buttons: 1 → `{"type":"timer:stop"}` when running; 3 → spawn
      `~/.config/rofi/launchers/colorful/pomotask.sh`; scroll up/down → send a **full**
      `timer:update` snapshot with `elapsedBefore` shifted ±60 s (partial updates leave the
      snapshot mergeable but ambiguous). Both bars carry the same handlers.
- [x] Habit titles fetched lazily on an unknown `activeHabitId`, TTL 600 s, off the GUI thread.
- [x] Missing key file / unparseable key → no thread started, widget stays hidden, one
      stderr line. The bar must never spin or crash-loop on a bad config.
- [x] Replace the stale "deliberately no pomotask widget" comment block; wire `pomotaskWidget`.
      Layout as it now stands: `centerWidgets = [pomotaskWidget, clockWidget]` on both bars
      (the center calendar, `gcalWidget` → `taffybar_gcal.sh` → "No current event", is gone,
      definition deleted, script left in `configs/waybar/`), and the primary keeps polypomo,
      weather, mic and the audio slider on the right. The center group collapses to just the
      clock while no timer runs, since the module hides itself when idle.
- [x] `POMOTASK_BASE` / `POMOTASK_KEY_FILE` env overrides, matching the rofi backend, so the
      widget can be pointed at a local server for testing.

### 4a. Both monitors

`pomotaskWidget` is now in `secondaryBarConfig.endWidgets` too, but a second call
must not mean a second socket: two connections would double the traffic and let the
two labels disagree for a frame about a stop one of them just sent. So:

- `pomoShared` (a `NOINLINE` `unsafePerformIO` CAF, same pattern as `processGroups`)
  holds the one `PomoVar` + `PomoRefs`, reads the key file once, and forks the
  supervisor once.
- `prGuis :: IORef [PomoGui]` in `PomoRefs` is the widget registry; `pomoRender`
  iterates it under a single `postGUIASync`, keeping one `prShown` cache for both bars.
- `pomoAttach` is the join-late path: a widget registered after the connection started
  is filled in from the current state directly, because `pomoRender` skips work when the
  text has not changed and an empty second-monitor label would otherwise stay empty until
  the next title change.
- `pomoStep` / `pomoConnected` / `pomoSupervisor` lost their `PomoGui` argument.

### 5. Compile + deploy verification

- [x] `taffybar.hs` compiles clean with the new ghc env (`-fno-code` typecheck, then the
      harness links against the same client code).
- [x] Nix wiring: `modules.taffybar.barEnv` (glibc locale archive + `LANG`/`LC_ALL`) spliced
      at the launch in `modules/nixos/dwm/default.nix`. No CA setup: validation runs against
      the tls library's compiled-in trust store
      (`settingDisableCertificateValidation def == False`, checked in ghci).
- [x] `build.sh` no longer hardcodes the ghc store path — resolves
      `.#nixosConfigurations.mysystem.config.modules.taffybar.ghcEnv`, `$1` overrides.
- [x] Config still evaluates: `extraSessionCommands` renders the bar launch with the ghc env
      on PATH and the locale archive set.
- [ ] Live smoke test of click-to-stop and scroll ±60 s — needs a rebuild and a re-login
      first, and it writes to the pomotasker DB, so it goes through `ask_human`.
- [x] Recorded in root `TODO.md`; activation needs `rebuild-default` + a re-login for the
      new bar env.

## Notes / risks

- **TLS 1.3 quirk**: with `pomoTlsSettings = def`, crypton insists on the kem/extended-main-
  secret exchange, so servers that do not advertise it die at `HandshakeFailed
  (Error_Protocol "peer does not support Extended Main Secret")` before any cert check
  (reproduced against badssl.com and pgp.mit.edu). `ug.kyrgyzstan.kg` negotiates fine. If the
  widget ever goes missing, look for that line on stderr; the knob is `TLSSettings` with an
  explicit `psCiphers`/`psVersions` that allows TLS 1.2.
- SNI turned out to be fine on `def`: it comes from `defaultParamsClient`, not from the third
  `TLSSettingsSimple` flag (noted inline where the settings are defined).
- While the web app is open it is the timer's source of truth and rebroadcasts, so a scroll
  adjustment can be overwritten by it. Server merges `timer:update` data into its snapshot.
- `scroll ±60 s` sets `startTime` to *now* and puts the whole elapsed value in
  `elapsedBefore` — that is what the web client sends too, so the total keeps matching.
- No `websocket`/`wuss` in nixpkgs; the frame codec stays one ~100-line block with why-comments.
- Out of scope, logged only: `modules/nixos/dwl/default.nix:40` runs `timeout 1
  polybar-pomotask.py` (nix-shell shebang) on every dwl status refresh — same nix-spawn bug,
  different bar. Waybar config left alone.
