#!/usr/bin/env bash
# Idle CPU, idle wakeups and memory of a running terminal app, sampled the way
# the Hotaru vs Ghostty comparison reports them (CPU ms over a 30 s idle window).
#
# Run it from a different terminal app (Terminal.app, or Ghostty when measuring
# Programa) so printing into the measured app does not count as its own work.
# Leave the measured app untouched while it samples. Compare Release builds:
# a Debug build is slower and larger by design.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: scripts/measure-idle.sh <pid | app executable name> [seconds=30] [runs=3]

examples:
  scripts/measure-idle.sh Programa
  scripts/measure-idle.sh "Programa DEV my-tag"
  scripts/measure-idle.sh ghostty 30 5
EOF
  exit 2
}

target="${1:-}"
seconds="${2:-30}"
runs="${3:-3}"
[[ -n "$target" ]] || usage
[[ "$seconds" =~ ^[1-9][0-9]*$ && "$runs" =~ ^[1-9][0-9]*$ ]] || usage

if [[ "$target" =~ ^[0-9]+$ ]]; then
  pid="$target"
else
  pids=$(ps -axo pid=,comm= | awk -v suffix=".app/Contents/MacOS/${target}" '
    { pid = $1; sub(/^ *[0-9]+ /, ""); n = length(suffix)
      if (length($0) >= n && substr($0, length($0) - n + 1) == suffix) print pid }')
  count=$(wc -w <<<"$pids" | tr -d ' ')
  if [[ "$count" != "1" ]]; then
    echo "expected one running '${target}' app process, found ${count}" >&2
    exit 1
  fi
  pid="$pids"
fi
kill -0 "$pid" 2>/dev/null || { echo "no process with pid ${pid}" >&2; exit 1; }

# ps prints CPU time as [[h:]m:]s.cc; convert to integer milliseconds.
cpu_ms() {
  ps -o time= -p "$pid" | awk -F: '{ s = 0; for (i = 1; i <= NF; i++) s = s * 60 + $i; printf "%d\n", s * 1000 + 0.5 }'
}

# top reports cumulative idle wakeups for the process, with a trailing "+" when it grew.
idle_wakeups() {
  top -l 1 -pid "$pid" -stats idlew | awk 'END { gsub(/\+/, "", $1); print $1 }'
}

footprint_mb() {
  footprint -p "$pid" 2>/dev/null | awk '/Footprint:/ { for (i = 1; i <= NF; i++) if ($i == "Footprint:") { print $(i + 1); exit } }'
}

name=$(ps -o comm= -p "$pid")
echo "measuring ${name##*/} (pid ${pid}): ${runs} run(s) of ${seconds} s, keep it idle"

cpu_results=()
wake_results=()
for ((run = 1; run <= runs; run++)); do
  cpu_start=$(cpu_ms)
  wake_start=$(idle_wakeups)
  sleep "$seconds"
  cpu_end=$(cpu_ms)
  wake_end=$(idle_wakeups)
  cpu_results+=("$((cpu_end - cpu_start))")
  wake_results+=("$((wake_end - wake_start))")
done

rss_mib=$(ps -o rss= -p "$pid" | awk '{ printf "%.0f", $1 / 1024 }')

echo
printf '%-5s %14s %20s\n' "run" "idle CPU (ms)" "idle wakeups (/s)"
for ((i = 0; i < runs; i++)); do
  wakes=${wake_results[$i]}
  printf '%-5s %14s %20s\n' "$((i + 1))" "${cpu_results[$i]}" "$(awk -v w="$wakes" -v s="$seconds" 'BEGIN { printf "%d (%.1f)", w, w / s }')"
done
echo
echo "CPU counter resolution is 10 ms; ${seconds} s at 100% of one core is $((seconds * 1000)) ms."
echo "memory: ${rss_mib} MiB resident, $(footprint_mb) MB physical footprint (what Activity Monitor shows)"
