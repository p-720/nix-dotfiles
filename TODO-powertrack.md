# TODO — powertrack

## Goal

A tiny (about 5 MB RSS) systemd service that samples this machine's power draw, integrates it to
kWh, keeps live daily/weekly/monthly totals, and appends every closed period to a small history
file that a `powertrack` CLI can report on.

Status: **done**, enabled for `hosts/main`. Not running until you `rebuild-default` — and see
Notes first, the new files must stay tracked in git for the flake to see them.

## Measurement reality (why the numbers are "measured + estimated")

Inspected on this box: no wall meter, no IPMI, no battery, no PSU sensor. What the kernel/driver
actually gives us:

| source                      | path                                                         | quality                                     |
| --------------------------- | ------------------------------------------------------------ | ------------------------------------------- |
| CPU package (incl. SoC)     | `/sys/class/powercap/intel-rapl:0/energy_uj`                 | **measured** (µJ counter, 0400 root, ~11 min wrap) |
| GPU board (RTX 3090)        | `nvidia-smi --query-gpu=power.draw` (30 ms, NVML)            | **measured** (whole board incl. memory)              |
| board/RAM/NVMe/fans/chipset | none                                                         | **estimated** constant `baseW`                       |
| PSU AC→DC loss              | none                                                         | **estimated** `psuEfficiency`                        |

`gigabyte_wmi`, `k10temp`, `nvme` expose temperature only — no power rails. So the reported kWh is
"measured CPU + measured GPU + fixed base, scaled for VRM loss, divided by PSU efficiency". Stable
and trend-accurate; it is not a meter.

## Tasks

### 1. Collector (`modules/nixos/powertrack/collect.sh`)

- [x] Enable the RAPL zone once, then loop every `sampleSec` (10 s default): read the `package-0`
      energy counter, take the µJ delta, treat wrap/overflow reads as unknown and backfill with the
      last known rate.
- [x] GPU sample every `gpuSampleSec` (20 s default) via NVML, integrated with the held value
      between samples; stops trying after `gpuFailLimit` consecutive failures and logs once.
- [x] `baseW` constant plus an opt-in CPU estimate (`/proc/stat` busy fraction × `cpuTdpW`) for
      hosts with no RAPL zone, so the module stays portable to `laptop`/`oldpc`.
- [x] Integrate in integer µJ with shell arithmetic only (`centiW × sec × 10000 = µJ`): no float
      maths, no drift, one `date` per pass.
- [x] Rollover on `date +%Y-%m-%d` / `+%G-W%V` / `+%Y-%m`: append the closed period to
      `history.tsv` (`key kind Wh ended`), then reset. Day, ISO week and month roll independently,
      and periods closed while the box was off still get their stored energy.
- [x] Persist counters atomically (tmp + rename) every `persistSec` (60 s default), on every
      period close, and on SIGTERM.
- [x] One journald status line per `statusSec` (1 h default) + one line per closed period. No
      per-sample log: `hourly.tsv` (~9 KB/yr) + `history.tsv` (~1 KB/yr) are the record.
- [x] Counters survive reboot; the boot gap is not credited (machine off ≈ no consumption).
- [x] `--once` flag for a single pass (smoke test / cron mode).

### 2. Hour buckets + tariff (added after your Moscow 3-zone answer)

- [x] Close an hour bucket every clock hour into `hourly.tsv`
      (`hour_key Wh ISO_week month`), stamped with the week/month the hour ran *inside*. That is
      what lets the CLI price any closed period without date arithmetic, and it keeps pricing
      correct across reboots and offline gaps.
- [x] `tariff.zones` (name, rate, hours) defaulting to the Moscow tariff: T1 12.39 for 7-10/17-21,
      T3 8.9 for 10-17/21-23, T2 4.85 for 23-7.
- [x] Bake hour→zone as a 24-number table in the CLI wrapper so pricing is a table lookup.
- [x] Refuse to evaluate when the zones do not cover hours 0..23 exactly once (throws, listing the
      bad hours) — a silently mispriced kWh is worse than a failed build.

### 3. CLI (`modules/nixos/powertrack/cli.sh` → `powertrack`)

- [x] `powertrack` — current watts, today, this ISO week, this month, total, and the tariff-zone
      split for today.
- [x] `powertrack day|week|month [N]` — last N closed periods with kWh and cost.
- [x] `powertrack history [N]`, `powertrack json` (for a bar widget or dashboard later).
- [x] `-` in cost columns when `tariff.enable = false`; `tariff.currency` names the unit.

### 4. NixOS module (`modules/nixos/powertrack/default.nix`)

- [x] `modules.powertrack.*` following the local `modules.*` convention (auto-imported).
- [x] Options: `stateDir`, `sampleInterval`, `gpuSampleInterval`, `statusInterval`,
      `persistInterval`, `basePowerW`, `cpuScalePercent`, `psuEfficiencyPercent`,
      `estimateCpuPower`, `cpuTdpW`, `gpu.enable`, `gpuFailLimit`, `nvidiaSmi`, `package`,
      `tariff.enable/currency/zones`.
- [x] systemd unit: root (RAPL `energy_uj` is 0400 root), `Type=simple`, `Restart=always`,
      `StateDirectory=powertrack` at 0755 so the CLI reads it as you, `ProtectSystem=strict`,
      `ProtectHome`, `NoNewPrivileges`, `PrivateTmp`, `TasksMax=64`, `ReadWritePaths=stateDir`.
      Deliberately *not* `ProtectKernelTunables`: it read-only binds the `/sys` paths the
      collector has to write.
- [x] `powertrack` CLI into `environment.systemPackages`.
- [x] Enabled for `hosts/main/configuration.nix` only.
- [x] Option types that fail at eval instead of runtime: `types.ints.positive` for intervals,
      `types.ints.between 1 100` for the PSU divisor (it is a divisor), `ints.between 0 23` for
      tariff hours.

### 5. Verification

- [x] Package builds from the real system config
      (`nix build …nixosConfigurations.mysystem.config.modules.powertrack.package`), and the real
      config evaluates with the module auto-imported and `enable = true` in `hosts/main`.
- [x] Real config check: unit ExecStart/StateDirectory/protect flags correct, tariff zones correct,
      CLI present in `environment.systemPackages`, zone table baked as
      `3 3 3 3 3 3 3 1 1 1 2 2 2 2 2 2 2 1 1 1 1 2 2 3`.
- [x] Integration math: fake RAPL counter + fake NVML at a known 1 W / 100 W / 50 W → every pass
      credited exactly 152 J; 3 passes → 456000000 µJ.
- [x] Rollover: counters preseeded in a closed day/week/month/hour closed `D 2026-11-05 4.0 Wh`,
      `W 2026-W44 8.0 Wh`, `M 2026-10 12.0 Wh`, and the hour row kept the **old** week/month tags.
- [x] Counter wrap/backfill: a backwards counter read produced `gaps 1`, no negative energy,
      monotonic totals.
- [x] SIGTERM: trap persists within ~100 ms of the signal, not after the sleep interval.
- [x] Tariff arithmetic: fixture day 4 kWh over hours 02/08/12/23 → 30.99 руб; total across two
      weeks → 50.26 руб over 9 buckets; per-zone split T1 12.39 / T3 4.45 / T2 2.42.
- [x] Bad tariff config fails at eval with "must charge every local hour 0..23 exactly once.
      Bad hours: 0 1 2 … 23".

### 6. gpu source (added after the gpu=off report)

- [x] Absolute, driver-matched `nvidia-smi` path baked into the unit (`PT_NVIDIA_SMI`); verified the
      baked path is the one `/run/current-system/sw/bin/nvidia-smi` resolves to, and that running the
      collector with it reports `gpu=on`.
- [x] gpu failure is now a state to recover from: after `gpuFailLimit` consecutive failures it backs
      off to `gpuRetryInterval` (300 s default) and logs the give-up **once**, then logs
      "gpu sampling back on" when a probe succeeds — no restart needed.
- [x] Tested both directions without restarting the collector: working gpu → broken → heals itself
      (watts back from 52 W to 152 W), and binary absent at startup → appears → heals itself.
- [x] Memory: collector `VmRSS` peak **5.3 MB** over 8 s. Note the honest caveat: each GPU sample
      briefly spawns `nvidia-smi` (~23 MB for ~30 ms, about 0.15% of the time). Set
      `gpu.enable = false` if the 3090's share can be left out; it is the second-biggest consumer
      on this box.
- [x] Degrades clean as a non-root user (real sysfs): warns once, keeps running on
      gpu + base, no crash, no leaked `Permission denied` from the shell.

## Notes

- **gpu=off follow-up:** the service logged `no nvidia-smi in PATH`. NixOS systemd units get a
  minimal PATH (coreutils, findutils, grep, sed, systemd) — `/run/current-system/sw/bin` is not on
  it, so my "the driver binary is already on the service PATH" assumption was wrong. Now the unit
  gets `PT_NVIDIA_SMI` baked as `${config.hardware.nvidia.package.bin}/bin/nvidia-smi` (same store
  path `/run/current-system/sw/bin/nvidia-smi` points at, and version-matched by construction), and
  gpu sampling re-probes instead of quitting for the session.

- **Deployment gotcha:** `rebuild-default` reads the flake from the git tree, and untracked files
  are invisible to it — the eval failed with "The option `modules.powertrack' does not exist" until
  `git add modules/nixos/powertrack`. They are staged now; do not `git reset` them away before a
  rebuild, or commit them.
- RAPL `max_energy_range_uj` here is 65.5 kJ → the counter wraps in ~3.6 min at 300 W. A 10 s
  sample is ~20× inside that, and wrap is still handled because the delta check catches it.
- `package-0` already includes cores + uncore + SoC on AMD, so the module deliberately reads only
  `package-*` zones; adding the separate `core` zone would double-count the CPU.
- `energy_uj` is root-only, so there is no DynamicUser option worth a udev rule for one root process.
- nixpkgs 26.05 dropped `types.secs`, `types.positiveInt`, `lib.takeWhile`, `lib.compare` and
  `lib.findIndex`; the module avoids all of them (caught by eval, not by reading docs).
- Files: `modules/nixos/powertrack/{default.nix,collect.sh,cli.sh}`, one line enabled in
  `hosts/main/configuration.nix`.
