#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: PROGRAMA_SOCKET_PATH=/tmp/programa-debug-<tag>.sock $0 <window|sidebar|tabBar|overlays> [output-directory]" >&2
}

surface="${1:-}"
output_dir="${2:-/tmp/programa-glass-memory}"
socket_path="${PROGRAMA_SOCKET_PATH:-}"

case "$surface" in
  window|sidebar|tabBar|overlays) ;;
  *) usage; exit 2 ;;
esac

if [[ -z "$socket_path" || ! -S "$socket_path" ]]; then
  echo "PROGRAMA_SOCKET_PATH must point to a running tagged Debug app socket" >&2
  exit 2
fi

pid="$(lsof -t "$socket_path" | head -n 1)"
if [[ -z "$pid" ]]; then
  echo "No Programa process owns $socket_path" >&2
  exit 1
fi

mkdir -p "$output_dir"

set_surface() {
  local target="$1"
  local enabled="$2"
  local response
  response="$(printf '{"id":1,"method":"debug.glass.set","params":{"surface":"%s","enabled":%s}}\n' "$target" "$enabled" | nc -w 2 -U "$socket_path")"
  if ! printf '%s\n' "$response" | grep -Eq '"ok"[[:space:]]*:[[:space:]]*true'; then
    echo "debug.glass.set failed: $response" >&2
    exit 1
  fi
}

capture() {
  local state="$1"
  local prefix="$output_dir/${surface}-${state}"
  footprint --pid "$pid" --format bytes --noCategories --json "$prefix.json" > "$prefix.txt"
  echo "$state snapshot: $prefix.txt"
  jq -r '"  total footprint: \(.["total footprint"]) B"' "$prefix.json"
}

for candidate in window sidebar tabBar overlays; do
  set_surface "$candidate" false
done
sleep 2
capture off

set_surface "$surface" true
sleep 2
capture on

set_surface "$surface" false

off_total="$(jq -r '.["total footprint"]' "$output_dir/${surface}-off.json")"
on_total="$(jq -r '.["total footprint"]' "$output_dir/${surface}-on.json")"
delta_bytes="$((on_total - off_total))"
ratio="$(awk -v on="$on_total" -v off="$off_total" 'BEGIN { printf "%.4f", on / off }')"

echo "OFF total: $off_total B"
echo "ON total:  $on_total B"
echo "ON - OFF:  $delta_bytes B"
echo "ON / OFF:  ${ratio}x"
echo "Snapshots are report-only in Phase 1; compare equal-idle-state deltas for later phase gates."
