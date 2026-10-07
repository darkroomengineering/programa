#!/usr/bin/env bash
set -euo pipefail

app_path="${1:-}"
surface="${2:-}"
run_count="${3:-3}"

if [[ ! -d "$app_path" || "$run_count" != "3" ]]; then
  echo "usage: $0 <Programa DEV.app> <window|sidebar|tabBar|overlays> [3]" >&2
  exit 2
fi

case "$surface" in
  window) override_key="PROGRAMA_TEST_FORCE_WINDOW_GLASS" ;;
  sidebar) override_key="PROGRAMA_TEST_FORCE_SIDEBAR_GLASS" ;;
  tabBar) override_key="PROGRAMA_TEST_FORCE_TAB_BAR_GLASS" ;;
  overlays) override_key="PROGRAMA_TEST_FORCE_OVERLAY_GLASS" ;;
  *) echo "Unknown glass surface: $surface" >&2; exit 2 ;;
esac

executable="$app_path/Contents/MacOS/Programa DEV"
results_file="${RUNNER_TEMP:-/tmp}/programa-glass-${surface}-results.tsv"
: > "$results_file"
app_pid=""

cleanup() {
  if [[ -n "$app_pid" ]]; then
    kill "$app_pid" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

run_sample() {
  local state="$1"
  local ordinal="$2"
  local enabled=0
  if [[ "$state" == "on" ]]; then enabled=1; fi

  local tag="ci-glass-${surface}-${state}-${ordinal}"
  local socket_path="/tmp/programa-debug-${tag}.sock"
  local app_log="${RUNNER_TEMP:-/tmp}/${tag}-app.log"
  local harness_log="${RUNNER_TEMP:-/tmp}/${tag}-lag.log"

  rm -f "$socket_path" "/tmp/programa-${tag}.sock"
  env \
    PROGRAMA_TAG="$tag" \
    PROGRAMA_SOCKET_PATH="$socket_path" \
    PROGRAMA_UI_TEST_MODE=1 \
    "$override_key=$enabled" \
    "$executable" > "$app_log" 2>&1 &
  app_pid=$!

  for _ in {1..240}; do
    [[ -S "$socket_path" ]] && break
    sleep 0.25
  done
  if [[ ! -S "$socket_path" ]]; then
    tail -80 "$app_log" >&2 || true
    return 1
  fi

  PROGRAMA_SOCKET_PATH="$socket_path" \
  PROGRAMA_LAG_MAX_P95_RATIO=1000 \
  PROGRAMA_LAG_MAX_AVG_RATIO=1000 \
  PROGRAMA_LAG_MAX_P95_DELTA_MS=100000 \
  PROGRAMA_LAG_MAX_AVG_DELTA_MS=100000 \
  PROGRAMA_LAG_MAX_CHURN_P95_MS=100000 \
  PROGRAMA_LAG_KEY_EVENTS=180 \
  PROGRAMA_LAG_KEY_COMBO="${PROGRAMA_LAG_KEY_COMBO:-up}" \
  python3 tests_v2/test_workspace_churn_up_arrow_lag.py | tee "$harness_log"

  local p95_values
  p95_values="$(awk '
    /^Baseline$/ { section = "baseline"; next }
    /^After workspace churn$/ { section = "churn"; next }
    section != "" && $1 == "p95_ms:" { print $2; section = "" }
  ' "$harness_log" | tr '\n' ' ')"
  local baseline_p95 churn_p95
  read -r baseline_p95 churn_p95 <<< "$p95_values"
  if [[ -z "${baseline_p95:-}" || -z "${churn_p95:-}" ]]; then
    echo "Could not parse p95 values from $harness_log" >&2
    return 1
  fi
  printf '%s\t%s\t%s\t%s\n' "$state" "$ordinal" "$baseline_p95" "$churn_p95" >> "$results_file"

  kill "$app_pid" >/dev/null 2>&1 || true
  wait "$app_pid" >/dev/null 2>&1 || true
  app_pid=""
  rm -f "$socket_path" "/tmp/programa-${tag}.sock"
}

for state in off on; do
  for ordinal in 1 2 3; do
    run_sample "$state" "$ordinal"
  done
done

median_for() {
  local state="$1"
  local column="$2"
  awk -v state="$state" -v column="$column" '$1 == state { print $column }' "$results_file" | sort -n | sed -n '2p'
}

off_baseline="$(median_for off 3)"
on_baseline="$(median_for on 3)"
off_churn="$(median_for off 4)"
on_churn="$(median_for on 4)"
baseline_ratio="$(awk -v on="$on_baseline" -v off="$off_baseline" 'BEGIN { printf "%.4f", on / off }')"
churn_ratio="$(awk -v on="$on_churn" -v off="$off_churn" 'BEGIN { printf "%.4f", on / off }')"
gate_result="$(awk -v baseline="$baseline_ratio" -v churn="$churn_ratio" 'BEGIN { print (baseline <= 1.15 && churn <= 1.15) ? "PASS" : "FAIL" }')"

summary_file="${GITHUB_STEP_SUMMARY:-/dev/stdout}"
{
  echo "## Liquid Glass report-only gate: $surface"
  echo
  echo "| State | Run | Up-arrow p95 (ms) | Churn p95 (ms) |"
  echo "| --- | ---: | ---: | ---: |"
  awk '{ printf "| %s | %s | %s | %s |\n", $1, $2, $3, $4 }' "$results_file"
  echo
  echo "| Metric | OFF median | ON median | ON/OFF |"
  echo "| --- | ---: | ---: | ---: |"
  echo "| Up-arrow p95 | $off_baseline | $on_baseline | ${baseline_ratio}x |"
  echo "| Churn p95 | $off_churn | $on_churn | ${churn_ratio}x |"
  echo
  echo "Report-only result at the 1.15x phase threshold: **$gate_result**"
} | tee -a "$summary_file"

echo "results_file=$results_file"
