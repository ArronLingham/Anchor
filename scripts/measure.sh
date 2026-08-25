#!/bin/bash
# Sample a running process's CPU and RSS.
#
#   scripts/measure.sh <process-name> <seconds> [label]
#   scripts/measure.sh Anchor 180 "claude-usage-watcher"
#
# Two things this gets right that a naive `ps %cpu` loop does not:
#
#   * `ps -o %cpu` reports CPU time over the process's WHOLE LIFETIME, not
#     current load. For a long-lived menu-bar app it converges on a number that
#     says nothing about now. This samples cputime and divides by elapsed wall
#     time between ticks, which is actual instantaneous CPU.
#
#   * It aborts if the pid changes mid-run. Two measurements in this project
#     were silently garbage because the app was rebuilt and relaunched under the
#     sampler, and the numbers were quoted for weeks before anyone noticed.
#
# RSS is `ps` RSS, which is what every figure in CLAUDE.md's table was taken
# with. Do not swap it for top's MEM column — that counts shared and
# compressed pages differently and is not comparable to those rows.
#
# Let the app settle 5+ minutes before sampling: launch transients hit ~28% and
# destroy the mean.
set -uo pipefail

name="${1:?usage: measure.sh <process-name> <seconds> [label]}"
duration="${2:?usage: measure.sh <process-name> <seconds> [label]}"
label="${3:-}"
interval=2

pid="$(pgrep -x "$name" | head -1)"
[[ -n "$pid" ]] || { echo "no process named '$name' is running" >&2; exit 1; }

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
  now_pid="$(pgrep -x "$name" | head -1)"
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
    idx    = int(NR * 0.9); if (idx < 1) idx = 1
    printf "\nCPU%%   mean %.2f   median %.2f   p90 %.2f   max %.2f   (%d samples)\n", \
           mean, median, v[idx], v[NR], NR
  }'

printf '%s\n' "${rss_samples[@]}" | sort -n | awk '
  { v[NR] = $1; s += $1 }
  END { printf "RSS    mean %.1f MB   max %.1f MB\n", (s/NR)/1024, v[NR]/1024 }'
