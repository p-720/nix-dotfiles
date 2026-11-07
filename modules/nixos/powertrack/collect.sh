#!/usr/bin/env bash
# powertrack-collect — keep a live day/ISO-week/month energy total for this box.
#
# Real measurements only where they exist: CPU package energy from the RAPL counter, GPU
# board power from NVML. Everything else is a documented constant (baseW, psuEfficiency,
# cpuScale) because the machine has no meter, no IPMI and no PSU rail.
#
# All internal maths is integer microjoules so the loop never forks for float arithmetic
# and cannot drift. The service idles at about 5 MB of RSS.

set -u

STATE=${POWERTRACK_STATE:-/var/lib/powertrack}
SAMPLE=${PT_SAMPLE:-10}
GPU_SAMPLE=${PT_GPU_SAMPLE:-20}
GPU_FAILS=${PT_GPU_FAILS:-5}
PERSIST=${PT_PERSIST:-60}
STATUS=${PT_STATUS:-3600}
BASE_W=${PT_BASE_W:-50}
CPU_TDP_W=${PT_CPU_TDP_W:-0}
# RAPL counts what the silicon burns, not what the board feeds it; Vcore VRM loss is
# charged here so the number moves towards wall draw instead of away from it.
CPU_SCALE_PCT=${PT_CPU_SCALE_PCT:-115}
EFF_PCT=${PT_PSU_EFFICIENCY_PCT:-90}
ESTIMATE_CPU=${PT_ESTIMATE_CPU:-0}
NVIDIA_SMI=${PT_NVIDIA_SMI:-nvidia-smi}
GPU_RETRY=${PT_GPU_RETRY:-300}
GPU_DISABLE=${PT_GPU_DISABLE:-0}
RAPL_DIR=${PT_RAPL_DIR:-/sys/class/powercap}
ZONE=${PT_RAPL_ZONE:-}

COUNTERS=$STATE/counters
HOURLY=$STATE/hourly.tsv
HISTORY=$STATE/history.tsv

ONCE=0
[ "${1:-}" = '--once' ] && ONCE=1
mkdir -p "$STATE" 2>/dev/null || true

say() { printf 'powertrack: %s\n' "$*"; }
cw() { awk -v w="$1" 'BEGIN { printf "%d", w * 100 + (w < 0 ? -0.5 : 0.5) }'; }

base_cw=$(cw "$BASE_W")
tdp_cw=$(cw "$CPU_TDP_W")

# ---------------------------------------------------------------- sources ----

# package-0 on purpose: on AMD it already covers cores + uncore + SoC, so reading the
# separate `core` zone as well would double-count the CPU.
zone=''
max_range=0
shopt -s nullglob
for names in "$RAPL_DIR"/intel-rapl*/name; do
  [ -r "$names" ] || continue
  [ "$(cat "$names" 2>/dev/null)" = package-0 ] || continue
  z=${names%/name}
  # zones ship disabled and the counter is unreadable until written (0400 root),
  # so a missing zone is the normal first-run failure, not an error to exit on.
  # the subshell is what silences the message: a failed redirect is reported by bash
  # itself, so `2>/dev/null` on `echo` alone would still print.
  [ "$(cat "$z/enabled" 2>/dev/null)" = 1 ] || { ( echo 1 >"$z/enabled" ) 2>/dev/null || true; }
  if v=$(cat "$z/energy_uj" 2>/dev/null) && [ -n "$v" ]; then
    zone=$z
    max_range=$(cat "$z/max_energy_range_uj" 2>/dev/null || echo 0)
    break
  fi
done
[ -n "$ZONE" ] && zone=$ZONE && max_range=$(cat "$zone/max_energy_range_uj" 2>/dev/null || echo 0)

cpu_mode=none
if [ -n "$zone" ]; then
  cpu_mode=rapl
elif [ "$ESTIMATE_CPU" = 1 ] && [ "$tdp_cw" -gt 0 ]; then
  cpu_mode=est
else
  say "WARNING no readable RAPL zone under $RAPL_DIR: cpu energy excluded (try PT_ESTIMATE_CPU=1 with PT_CPU_TDP_W)"
fi

# A missing gpu source is a state to recover from, not a permanent verdict: NixOS units get
# a minimal PATH, and NVML also refuses before the driver is up, so both cases must heal on
# their own instead of blacking out the biggest consumer until the next reboot.
gpu_off=0
gpu_next=0
if [ "$GPU_DISABLE" = 1 ]; then
  gpu_off=1
  gpu_next=$(($(date +%s) + GPU_RETRY))
  say "gpu sampling disabled by config"
elif ! command -v "$NVIDIA_SMI" >/dev/null 2>&1; then
  gpu_off=1
  gpu_next=$(($(date +%s) + GPU_RETRY))
  say "$NVIDIA_SMI not runnable yet: gpu energy excluded, retrying every ${GPU_RETRY}s"
fi

read_cpu() {
  local v
  v=$(cat "$zone/energy_uj" 2>/dev/null) || return 1
  case $v in '' | *[!0-9]*) return 1 ;; esac
  printf '%s' "$v"
}

read_gpu_cw() {
  local out
  out=$("$NVIDIA_SMI" --query-gpu=power.draw --format=csv,noheader,nounits 2>/dev/null) || return 1
  # sum over GPUs; a non-numeric field ("N/A") fails the sample rather than reading as 0 W
  printf '%s\n' "$out" | awk '
    { gsub(/[^0-9.]/, "") }
    $0 !~ /^[0-9]/ { bad = 1 }
    { s += $0; n++ }
    END { if (bad || n == 0) exit 1; printf "%d", s * 100 + 0.5 }'
}

# cpu user nice system idle iowait irq softirq steal ...
read_stat() {
  local u n s i io irq sirq st
  read -r _ u n s i io irq sirq st _ </proc/stat
  busy=$((u + n + s + irq + sirq + st))
  printf '%s %s' "$busy" "$((busy + i + io))"
}

# ------------------------------------------------------------------ state ----

day='' week='' month='' bucket=''
day_uj=0 week_uj=0 month_uj=0 bucket_uj=0 total_uj=0
samples=0 skips=0 watts=0

if [ -r "$COUNTERS" ]; then
  while IFS='=' read -r k v; do
    case $k in
      day) day=$v ;;
      week) week=$v ;;
      month) month=$v ;;
      bucket) bucket=$v ;;
      day_uj) day_uj=$v ;;
      week_uj) week_uj=$v ;;
      month_uj) month_uj=$v ;;
      bucket_uj) bucket_uj=$v ;;
      total_uj) total_uj=$v ;;
      samples) samples=$v ;;
      skips) skips=$v ;;
    esac
  done <"$COUNTERS"
fi

wh() { awk -v u="$1" 'BEGIN { printf "%.1f", u / 3600000000 }'; }

# The hour bucket closes with the day/week/month keys it ran inside, which is what lets
# the CLI price any closed period straight from hourly.tsv without date arithmetic.
close_bucket() {
  printf '%s\t%s\t%s\t%s\n' "$bucket" "$(wh "$bucket_uj")" "$week" "$month" >>"$HOURLY"
  bucket_uj=0
}

close_period() { # kind key uj
  printf '%s\t%s\t%s\t%s\n' "$2" "$1" "$(wh "$3")" "$(date +%s)" >>"$HISTORY"
  say "closed $1 $2: $(wh "$3") Wh"
}

rollovers() {
  local nd nw nm nb closed_any=0
  read -r nd nw nm nb < <(date +'%Y-%m-%d %G-W%V %Y-%m %Y-%m-%d-%H')
  [ -n "$bucket" ] || { day=$nd week=$nw month=$nm bucket=$nb; return; }
  if [ "$bucket" != "$nb" ]; then close_bucket; closed_any=1; fi
  if [ "$day" != "$nd" ]; then close_period D "$day" "$day_uj"; day_uj=0; closed_any=1; fi
  if [ "$week" != "$nw" ]; then close_period W "$week" "$week_uj"; week_uj=0; closed_any=1; fi
  if [ "$month" != "$nm" ]; then close_period M "$month" "$month_uj"; month_uj=0; closed_any=1; fi
  day=$nd week=$nw month=$nm bucket=$nb
  # a crash between appending a closed period and persisting the reset counters would
  # re-close the same period on restart, so never leave that window open
  [ "$closed_any" = 1 ] && persist
}

persist() {
  {
    printf 'v=1\n'
    printf 'updated=%s\n' "$(date +%s)"
    printf 'day=%s\nweek=%s\nmonth=%s\nbucket=%s\n' "$day" "$week" "$month" "$bucket"
    printf 'day_uj=%s\nweek_uj=%s\nmonth_uj=%s\nbucket_uj=%s\ntotal_uj=%s\n' \
      "$day_uj" "$week_uj" "$month_uj" "$bucket_uj" "$total_uj"
    printf 'watts=%s\nsamples=%s\nskips=%s\n' "$watts" "$samples" "$skips"
    printf 'cpu=%s\ngpu=%s\nbase_w=%s\nscale_pct=%s\neff_pct=%s\n' \
      "$cpu_mode" "$([ "$gpu_off" = 1 ] && echo off || echo on)" "$BASE_W" "$CPU_SCALE_PCT" "$EFF_PCT"
  } >"$STATE/.counters.new" 2>/dev/null && mv -f "$STATE/.counters.new" "$COUNTERS"
}

summary() {
  printf 'cpu %s gpu %s base %sW | today %s Wh | week %s Wh | month %s Wh | total %s kWh | %.1f W | samples %s gaps %s' \
    "$cpu_mode" "$([ "$gpu_off" = 1 ] && echo off || echo on)" "$BASE_W" \
    "$(wh "$day_uj")" "$(wh "$week_uj")" "$(wh "$month_uj")" \
    "$(awk -v u="$total_uj" 'BEGIN { printf "%.3f", u / 3.6e12 }')" \
    "$watts" "$samples" "$skips"
}

stop=0
sleeper=''
# systemd SIGTERMs us; a plain `sleep` in the foreground would make the trap wait up to
# SAMPLE seconds, so the sleeper is backgrounded and killed here instead.
trap 'stop=1; kill "${sleeper:-}" 2>/dev/null' TERM INT
trap 'persist' EXIT

say "start cpu=$cpu_mode gpu=$([ "$gpu_off" = 1 ] && echo off || echo on) base=${BASE_W}W scale=${CPU_SCALE_PCT}% eff=${EFF_PCT}% interval=${SAMPLE}s gpu_interval=${GPU_SAMPLE}s state=$STATE"

prev=$(date +%s)
prev_uj=''
cpu_rate=0
gpu_cw=0
gpu_bad=0
gpu_next=0
last_status=$(date +%s)
last_persist=0

# Seed the RAPL counter before the first pass: this pass's delta then covers a real
# interval. Energy before this point (boot) is not recoverable from the counter.
[ "$cpu_mode" = rapl ] && prev_uj=$(read_cpu) || true
[ "$cpu_mode" = est ] && read -r prev_busy prev_tot < <(read_stat)

while :; do
  sleep "$SAMPLE" & sleeper=$!
  wait "$sleeper" 2>/dev/null || true
  [ "$stop" = 1 ] && break

  now=$(date +%s)
  el=$((now - prev))
  [ "$el" -le 0 ] && el=$SAMPLE
  prev=$now

  cpu_uj=0
  case $cpu_mode in
    rapl)
      if cur=$(read_cpu); then
        if [ -n "$prev_uj" ]; then
          d=$((cur - prev_uj))
          # 65 kJ of counter headroom is >6 kW per interval, so a wrap only happens if
          # this loop stalls; the counter resets under us on overflow reads, so backfill
          # with the last known rate rather than trusting a negative delta.
          if [ "$d" -lt 0 ] || { [ "$max_range" -gt 0 ] && [ "$d" -gt "$max_range" ]; }; then
            d=$((cpu_rate * el))
            skips=$((skips + 1))
          else
            cpu_rate=$((d / el))
          fi
          cpu_uj=$d
        fi
        prev_uj=$cur
      elif [ -n "$prev_uj" ]; then
        cpu_uj=$((cpu_rate * el))
        skips=$((skips + 1))
      fi
      ;;
    est)
      read -r busy tot < <(read_stat)
      if [ -n "${prev_busy:-}" ]; then
        db=$((busy - prev_busy))
        dt=$((tot - prev_tot))
        if [ "$dt" -gt 0 ] && [ "$db" -ge 0 ]; then
          cpu_uj=$(awk -v b="$db" -v t="$dt" -v c="$tdp_cw" -v e="$el" \
            'BEGIN { printf "%d", (b / t) * c * e * 10000 }')
        fi
      fi
      prev_busy=$busy
      prev_tot=$tot
      ;;
  esac

  if [ "$now" -ge "$gpu_next" ]; then
    if [ "$GPU_DISABLE" = 1 ]; then
      gpu_next=$((now + GPU_RETRY))
    elif v=$(read_gpu_cw); then
      [ "$gpu_off" = 1 ] && say "gpu sampling back on"
      gpu_cw=$v
      gpu_bad=0
      gpu_off=0
      gpu_next=$((now + GPU_SAMPLE))
    else
      gpu_bad=$((gpu_bad + 1))
      if [ "$gpu_bad" -lt "$GPU_FAILS" ]; then
        gpu_next=$((now + GPU_SAMPLE))
      else
        # announce the give-up once, or a dead driver logs every retry forever
        [ "$gpu_off" = 0 ] && say "nvidia-smi failed $gpu_bad times in a row: gpu energy excluded, retrying every ${GPU_RETRY}s"
        gpu_off=1
        gpu_cw=0
        gpu_next=$((now + GPU_RETRY))
      fi
    fi
  fi
  gpu_uj=$((gpu_cw * el * 10000))
  base_uj=$((base_cw * el * 10000))

  cpu_uj=$((cpu_uj * CPU_SCALE_PCT / 100))
  dc=$((cpu_uj + gpu_uj + base_uj))
  # DC-side measured/estimated energy divided by PSU efficiency -> wall-side estimate
  wall=$((dc * 100 / EFF_PCT))

  day_uj=$((day_uj + wall))
  week_uj=$((week_uj + wall))
  month_uj=$((month_uj + wall))
  bucket_uj=$((bucket_uj + wall))
  total_uj=$((total_uj + wall))
  samples=$((samples + 1))
  watts=$(awk -v u="$wall" -v e="$el" 'BEGIN { printf "%.1f", u / 1e6 / e }')

  rollovers

  if [ $((now - last_status)) -ge "$STATUS" ]; then
    last_status=$now
    say "$(summary)"
  fi
  if [ $((now - last_persist)) -ge "$PERSIST" ]; then
    last_persist=$now
    persist
  fi
  [ "$ONCE" = 1 ] && break
done

persist
[ "$ONCE" = 1 ] && say "$(summary)"
exit 0
