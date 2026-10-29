#!/bin/bash
# Sample a running process's CPU and RSS.
#
#   scripts/measure.sh <process-name> <seconds> [label]
#   scripts/measure.sh Anchor 180 "idle after window checks"
#
# Derive interval CPU from cumulative cputime and monotonic elapsed time,
# retaining ps's CPU-time precision. Abort if the unique matching pid changes;
# rebuilding or relaunching during a run invalidates the measurement.
# RSS comes from ps in KiB and is reported here in MiB. It is a different
# counter from physical footprint; neither alone describes all memory use.
#
# Let the app settle 5+ minutes before sampling so launch activity does not
# dominate an idle measurement.
set -uo pipefail

name="${1:?usage: measure.sh <process-name> <seconds> [label]}"
duration="${2:?usage: measure.sh <process-name> <seconds> [label]}"
label="${3:-}"
interval=2

[[ "$duration" =~ ^[0-9]+$ ]] && (( duration >= interval )) || {
  echo "duration must be an integer of at least ${interval} seconds" >&2; exit 1;
}
for dependency in python3 bc; do
  command -v "$dependency" >/dev/null || { echo "missing dependency: $dependency" >&2; exit 1; }
done

pid="$(pgrep -x "$name")"
[[ -n "$pid" ]] || { echo "no process named '$name' is running" >&2; exit 1; }
[[ "$pid" != *$'\n'* ]] || { echo "multiple processes named '$name' are running; close extra copies" >&2; exit 1; }

# ps etime -> seconds, accepting [[dd-]hh:]mm:ss
uptime_s=$(ps -o etime= -p "$pid" | tr -d ' ' | awk -F'[-:]' '{
  if (NF==4) print $1*86400+$2*3600+$3*60+$4;
  else if (NF==3) print $1*3600+$2*60+$3;
  else print $1*60+$2 }')
if (( uptime_s < 300 )); then
  echo "WARNING: $name has only been up ${uptime_s}s. Launch transients will skew this." >&2
fi

# macOS `date` has no %N, so `date +%s.%N` yields "1787610000.N" and every
# elapsed-time computation built on it is malformed. python gives real
# sub-second resolution.
now_s() { python3 -c 'import time; print(f"{time.monotonic():.3f}")'; }

cputime_s() { ps -o cputime= -p "$1" 2>/dev/null | tr -d ' ' | awk -F'[:]' '{
  if (NF==3) printf "%.2f", $1*3600+$2*60+$3; else printf "%.2f", $1*60+$2 }'; }

echo "measuring $name (pid $pid) for ${duration}s${label:+ — $label}"

prev_cpu="$(cputime_s "$pid")"; prev_t="$(now_s)"
samples=(); rss_samples=()
deadline=$(( $(date +%s) + duration ))

while (( $(date +%s) < deadline )); do
  sleep "$interval"
  now_pid="$(pgrep -x "$name")"
  if [[ "$now_pid" != "$pid" ]]; then
    echo "ABORT: pid changed $pid -> ${now_pid:-<gone>} mid-run. Measurement discarded." >&2
    exit 2
  fi
  cur_cpu="$(cputime_s "$pid")"; cur_t="$(now_s)"
  [[ -n "$cur_cpu" ]] || { echo "ABORT: process vanished" >&2; exit 2; }
  pct=$(echo "scale=4; ($cur_cpu - $prev_cpu) / ($cur_t - $prev_t) * 100" | bc -l)
  samples+=("$pct")
  rss_samples+=("$(ps -o rss= -p "$pid" | tr -d ' ')")
  prev_cpu="$cur_cpu"; prev_t="$cur_t"
done

printf '%s\n' "${samples[@]}" | sort -n | awk '
  { v[NR] = $1; s += $1 }
  END {
    mean   = s / NR
    median = (NR % 2) ? v[int(NR/2) + 1] : (v[NR/2] + v[NR/2 + 1]) / 2
    idx    = int(NR * 0.9); if (idx < NR * 0.9) idx++; if (idx < 1) idx = 1
    printf "\nCPU%%   mean %.2f   median %.2f   p90 %.2f   max %.2f   (%d samples)\n", \
           mean, median, v[idx], v[NR], NR
  }'

printf '%s\n' "${rss_samples[@]}" | sort -n | awk '
  { v[NR] = $1; s += $1 }
  END { printf "RSS    mean %.1f MiB   max %.1f MiB\n", (s/NR)/1024, v[NR]/1024 }'
