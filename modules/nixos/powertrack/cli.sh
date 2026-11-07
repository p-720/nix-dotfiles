#!/usr/bin/env bash
# powertrack — report the energy totals powertrack-collect keeps.
#
# Deliberately no date arithmetic: the collector stamps every hour bucket with its ISO
# week and month, so any closed period is priced by filtering hourly.tsv on those columns.

set -u

STATE=${POWERTRACK_STATE:-/var/lib/powertrack}
COUNTERS=$STATE/counters
HOURLY=$STATE/hourly.tsv
HISTORY=$STATE/history.tsv

CURRENCY=${PT_CURRENCY:-руб}
ZONES=${PT_ZONES:-}        # name:rate|name:rate, ordered by zone index
ZONE_IDX=${PT_ZONE_IDX:-}  # 24 numbers: hour 0..23 -> 1-based index into ZONES
have_tariff=0
[ -n "$ZONES" ] && have_tariff=1

# KEY matches COL (1=day, 3=ISO week, 4=month); an empty KEY prices everything.
# Rows in are: hour_key<TAB>Wh<TAB>ISO_week<TAB>month
AWK_SUM='
{
  sum += $2
  rows++
  if (n) cost += ($2 / 1000) * rt[zone_of()]
}
END { printf "%.1f\t%.2f\t%d", sum / 1000, cost, rows }
'
AWK_ZONES='
{
  zi = zone_of()
  zk[zi] += $2 / 1000
  zc[zi] += ($2 / 1000) * rt[zi]
}
END { for (i = 1; i <= n; i++) printf "%s\t%.2f\t%.2f\n", nm[i], zk[i], zc[i] }
'
# gawk/mawk both lack closures in a portable way, so the hour->zone lookup is shared as
# one function text spliced in front of each program instead of duplicated.
AWK_PRELUDE='
function zone_of(  h) {
  h = substr($1, 12, 2) + 1
  if (hz[h] + 0 >= 1 && hz[h] + 0 <= n) return hz[h] + 0
  return 1
}
BEGIN {
  FS = "\t"
  n = split(ZONES, z, "|")
  for (i = 1; i <= n; i++) { split(z[i], p, ":"); nm[i] = p[1]; rt[i] = p[2] + 0 }
  split(IDX, hz, " ")
}
{
  if ($1 in seen) next           # a closed row beats the live bucket for the same hour
  seen[$1] = 1
  if (KEY != "" && ((COL == 1 && substr($1, 1, 10) != KEY) || (COL != 1 && $(COL) != KEY))) next
}'

get() { awk -v k="$1" -F= '$1 == k { print $2; exit }' "$COUNTERS" 2>/dev/null; }

if [ ! -r "$COUNTERS" ]; then
  printf 'powertrack: no state under %s — is the powertrack service running?\n' "$STATE" >&2
  exit 1
fi

day=$(get day)
week=$(get week)
month=$(get month)
bucket=$(get bucket)
bucket_uj=$(get bucket_uj)
total_uj=$(get total_uj)

kwh() { awk -v u="${1:-0}" 'BEGIN { printf "%.2f", u / 3.6e12 }'; }
wh() { awk -v u="${1:-0}" 'BEGIN { printf "%.0f", u / 3600000000 }'; }
wh1() { awk -v u="${1:-0}" 'BEGIN { printf "%.1f", u / 3600000000 }'; }
money() { [ "$have_tariff" = 1 ] && printf '%s %s' "$1" "$CURRENCY" || printf '-'; }

hour_rows() {
  [ -r "$HOURLY" ] && cat "$HOURLY"
  # the hour still running: the counters carry it, hourly.tsv only gets it once it closes
  [ -n "$bucket" ] && printf '%s\t%s\t%s\t%s\n' "$bucket" \
    "$(wh1 "$bucket_uj")" "$week" "$month"
}

price() { # col key -> "Wh<TAB>cost<TAB>rows"
  hour_rows | awk -v COL="$1" -v KEY="$2" -v ZONES="$ZONES" -v IDX="$ZONE_IDX" \
    "$AWK_PRELUDE$AWK_SUM"
}

zone_rows() { # col key -> name<TAB>kWh<TAB>cost, one line per tariff zone
  [ "$have_tariff" = 1 ] || return 0
  hour_rows | awk -v COL="$1" -v KEY="$2" -v ZONES="$ZONES" -v IDX="$ZONE_IDX" \
    "$AWK_PRELUDE$AWK_ZONES"
}

report() { # label uj col key note
  local row
  row=$(price "$3" "$4")
  printf '%-6s %10s kWh %14s  %s\n' "$1" "$(kwh "$2")" "$(money "$(cut -f2 <<<"$row")")" "$5"
}

closed() { # kind col n
  local key wh row
  while IFS=$'\t' read -r key _ wh _; do
    [ -n "$wh" ] || continue
    row=$(price "$2" "$key")
    printf '%-12s %10s kWh %14s\n' "$key" \
      "$(awk -v w="$wh" 'BEGIN { printf "%.2f", w / 1000 }')" "$(money "$(cut -f2 <<<"$row")")"
  done < <(tac "$HISTORY" 2>/dev/null | awk -F'\t' -v k="$1" '$2 == k' | head -n "${3:-20}")
}

list() { # kind label col defaultN givenN
  local kind=$1 label=$2 col=$3 n=${5:-$4}
  if [ ! -s "$HISTORY" ]; then
    printf 'no closed %s yet\n' "$label"
    return 0
  fi
  printf '%-12s %12s %16s\n' "$label" 'energy' 'cost'
  closed "$kind" "$col" "$n"
  printf '\n%s\n' 'a period with no row was off, or predates the service'
}

case ${1:-summary} in
  summary)
    printf 'powertrack  %s  cpu=%s gpu=%s base=%sW scale=%s%% eff=%s%%  samples=%s gaps=%s\n' \
      "$(date +'%Y-%m-%d %H:%M')" "$(get cpu)" "$(get gpu)" "$(get base_w)" \
      "$(get scale_pct)" "$(get eff_pct)" "$(get samples)" "$(get skips)"
    printf '%-6s %10s W\n\n' 'now' "$(get watts)"
    report today "$(get day_uj)" 1 "$day" "$day"
    report week "$(get week_uj)" 3 "$week" "$week"
    report month "$(get month_uj)" 4 "$month" "$month"
    row=$(price 1 '')
    printf '%-6s %10s kWh %14s  priced over %s hour buckets\n' 'total' "$(kwh "$total_uj")" \
      "$(money "$(cut -f2 <<<"$row")")" "$(cut -f3 <<<"$row")"
    if [ -n "$(get day)" ]; then
      printf '\n%s %s, today:\n' 'tariff' "$CURRENCY/kWh"
      while IFS=$'\t' read -r name k c; do
        printf '  %-6s %9s kWh %12s %s\n' "$name" "$k" "$c" "$CURRENCY"
      done < <(zone_rows 1 "$day")
    fi
    ;;
  day | week | month)
    case $1 in
      day) list D day 1 7 "${2:-}" ;;
      week) list W week 3 8 "${2:-}" ;;
      month) list M month 4 6 "${2:-}" ;;
    esac
    ;;
  history) tail -n "${2:-40}" "$HISTORY" 2>/dev/null ;;
  json)
    printf '{"watts":%s,"day_wh":%s,"week_wh":%s,"month_wh":%s,"total_wh":%s,"day":"%s","week":"%s","month":"%s","updated":%s}\n' \
      "$(get watts)" "$(wh "$(get day_uj)")" "$(wh "$(get week_uj)")" "$(wh "$(get month_uj)")" \
      "$(wh "$total_uj")" "$day" "$week" "$month" "$(get updated)"
    ;;
  *)
    cat >&2 <<'EOF'
usage: powertrack [summary|day [N]|week [N]|month [N]|history [N]|json]
  summary  live watts + today / ISO week / month / all-time energy and cost, by tariff zone
  day      last N closed days (default 7)
  week     last N closed ISO weeks (default 8)
  month    last N closed months (default 6)
EOF
    exit 2
    ;;
esac
exit 0
