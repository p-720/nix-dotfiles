# model-slot

Serializes requests to a single local model endpoint across every pi process on this machine, so
several T3 threads (and their subagents) queue for one GPU instead of stampeding it.

Nothing in T3 Code is changed. This is a pi extension plus a broker daemon.

## Pieces

- `index.ts` - the extension: attaches each pi process to the broker, waits for a slot before every
  provider request, tracks thread families, registers `ask_human` and `/slot`.
- `client.ts` - the broker client and the shared endpoint identity rule.
- `slotd.mts` - the broker: one per machine, unix socket, newline-delimited JSON. Started detached by
  the first gated pi, exits ~30s after the last one detaches.
- `config.json` - knobs below.
- `test/` - `node --test test/daemon.test.mts test/gate.test.mts test/ask-human.test.mts`
  (`gate.test.mts` spawns real pi processes against a scripted endpoint; takes ~10s).

## config.json

| key | default | meaning |
| --- | --- | --- |
| `endpoints` | `[]` | base URLs to arbitrate. A request is gated when the model's base URL matches one. |
| `maxConcurrent` | 1 | in-flight requests per endpoint. An endpoint entry may override it as `{ "url": ..., "maxConcurrent": 2 }`. |
| `familyIdleGraceMs` | 10000 | how long an endpoint stays owned by the family that last used it. |
| `humanHoldMs` | 180000 | how long a slot stays reserved while a thread waits for a human. |
| `notifyAfterMs` | 180000 | wait this long queued before telling the user. |
| `leaseTtlMs` | 30000 | drop a client that stops heartbeating and give its slot back. |

Environment overrides, mostly for testing: `PI_SLOT_SOCKET`, `PI_SLOT_CONFIG`, `PI_SLOT_MAX`,
`PI_SLOT_GRACE_MS`, `PI_SLOT_TTL_MS`, `PI_SLOT_HOLD_MS`, `PI_SLOT_CHILD_CLAIM_MS`,
`PI_SLOT_IDLE_EXIT_MS`, `PI_SLOT_SWEEP_MS`, `PI_SLOT_DAEMON`.

`~/.pi/agent/models.json` is not read here: the gate matches the model's own base URL, so a model you
do not want gated just needs a different `baseUrl`.

## Rules the broker enforces

- One request per slot per endpoint.
- While a family (a thread plus the subagents it delegated) has work running or queued, no other
  family takes an empty slot. A family never preempts a request already in flight.
- A delegated child inherits its parent's family, so it is served before unrelated threads that
  queued earlier. The child is recognized by the `childThreadId` in the delegation result, by its own
  thread id when it announces one, or - when it announces nothing - by being the process that shows up
  right after the delegation started.
- A thread waiting on a human keeps the slot for `humanHoldMs`.
- A delegation whose child never shows up stops reserving after `PI_SLOT_CHILD_CLAIM_MS`, so a lost
  child cannot idle the GPU.

## Looking at it

- `/slot` inside pi: holders, queue, families, and which process holds what.
- `node ~/.pi/agent/extensions/model-slot/slotd.mts status` from a shell.
- `<socket>.json` (default `/run/user/1000/pi-model-slot.sock.json`) is a live mirror for anything else.

## Turning it off

Delete or move `~/.pi/agent/extensions/model-slot`, or set `endpoints` to `[]`. If the broker cannot be
reached, pi runs ungated rather than blocking the turn.
