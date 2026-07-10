#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/programa-ci-unit-runner.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

STUB_XCODEBUILD="$TMP_DIR/xcodebuild"
FAILURES=0

fail() {
  echo "FAIL: $*" >&2
  FAILURES=$((FAILURES + 1))
}

cat > "$STUB_XCODEBUILD" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
count=0
if [[ -f "${TEST_CALL_COUNT:?}" ]]; then
  count="$(cat "$TEST_CALL_COUNT")"
fi

STATEFUL_TEST_CLASS="programaTests/AppDelegateShortcutRoutingTests"
STATEFUL_TEST_SKIP="${STATEFUL_TEST_CLASS}/testCmdWClosesWindowWhenClosingLastSurfaceInLastWorkspace"

log_call() {
  local args="$1"
  count=$((count + 1))
  printf '%s\n' "$count" > "$TEST_CALL_COUNT"
  printf '%s\n' "$args" >> "${TEST_ARGUMENT_LOG:?}"
}

case "${TEST_SCENARIO:?}" in
  split-stateful)
    log_call "$0 -skip-testing:${STATEFUL_TEST_CLASS} -parallel-testing-enabled YES"
    log_call "$0 -only-testing:${STATEFUL_TEST_CLASS} -skip-testing:${STATEFUL_TEST_SKIP} -parallel-testing-enabled NO"
    echo "Test Suite 'All tests' passed"
    exit 0
    ;;
  swiftpm-once)
    log_call "$0"
    if [[ "$count" -eq 1 ]]; then
      echo "error: Could not resolve package dependencies"
      exit 74
    fi
    echo "Test Suite 'All tests' passed"
    exit 0
    ;;
  ordinary-xctest-failure)
    log_call "$0"
    echo "Executed 1 test, with 1 failure (1 unexpected) in 0.001 seconds"
    exit 65
    ;;
  deterministic-xctest-failure)
    log_call "$0"
    echo "Executed 10 tests, with 2 failures (0 unexpected) in 0.010 seconds"
    exit 65
    ;;
  *)
    log_call "$0"
    echo "unknown test scenario" >&2
    exit 2
    ;;
esac
EOF
chmod +x "$STUB_XCODEBUILD"

run_scenario() {
  local scenario="$1"
  local case_dir="$TMP_DIR/$scenario"
  local output="$case_dir/output.log"
  local unit_scope=""
  mkdir -p "$case_dir/home" "$case_dir/swiftpm-cache" "$case_dir/derived/GhosttyTabs-fixture"
  printf 'stale\n' > "$case_dir/swiftpm-cache/stale"
  printf 'stale\n' > "$case_dir/derived/GhosttyTabs-fixture/stale"
  : > "$case_dir/calls"
  : > "$case_dir/arguments"

  if [[ "$scenario" == "split-stateful" ]]; then
    unit_scope="split-stateful"
  fi

  SCENARIO_STATUS=0
  HOME="$case_dir/home" \
  TEST_SCENARIO="$scenario" \
  TEST_CALL_COUNT="$case_dir/calls" \
  TEST_ARGUMENT_LOG="$case_dir/arguments" \
  PROGRAMA_UNIT_TEST_SCOPE="$unit_scope" \
  PROGRAMA_XCODEBUILD_COMMAND="$STUB_XCODEBUILD" \
  PROGRAMA_TEST_OUTPUT_FILE="$output" \
  PROGRAMA_SWIFTPM_CACHE_DIR="$case_dir/swiftpm-cache" \
  PROGRAMA_DERIVED_DATA_DIR="$case_dir/derived" \
  "$ROOT_DIR/scripts/ci-run-unit-tests.sh" > "$case_dir/runner.out" 2>&1 || SCENARIO_STATUS=$?
  SCENARIO_CALLS="$(cat "$case_dir/calls")"
  SCENARIO_DIR="$case_dir"
}

test_retries_one_real_swiftpm_resolution_failure() {
  run_scenario swiftpm-once
  if [[ "$SCENARIO_STATUS" -ne 0 ]]; then
    fail "SwiftPM transient failure did not recover on its single retry (status $SCENARIO_STATUS)"
  fi
  if [[ "$SCENARIO_CALLS" -ne 2 ]]; then
    fail "SwiftPM transient failure invoked xcodebuild $SCENARIO_CALLS times, expected exactly 2"
  fi
  if [[ -e "$SCENARIO_DIR/swiftpm-cache/stale" ]]; then
    fail "SwiftPM retry did not clear its cache before retrying"
  fi
  if [[ -d "$SCENARIO_DIR/derived/GhosttyTabs-fixture" ]]; then
    fail "SwiftPM retry did not clear matching DerivedData before retrying"
  fi
}

test_does_not_retry_ordinary_xctest_failure() {
  run_scenario ordinary-xctest-failure
  if [[ "$SCENARIO_STATUS" -eq 0 ]]; then
    fail "ordinary XCTest failure was reported as success"
  fi
  if [[ "$SCENARIO_CALLS" -ne 1 ]]; then
    fail "ordinary XCTest failure invoked xcodebuild $SCENARIO_CALLS times, expected no retry"
  fi
}

test_propagates_deterministic_expected_failure() {
  run_scenario deterministic-xctest-failure
  if [[ "$SCENARIO_STATUS" -eq 0 ]]; then
    fail "deterministic XCTest assertion failure with '(0 unexpected)' was incorrectly reported as success"
  fi
  if [[ "$SCENARIO_CALLS" -ne 1 ]]; then
    fail "deterministic XCTest failure invoked xcodebuild $SCENARIO_CALLS times, expected no retry"
  fi
}

test_supports_split_stateful_mode() {
  run_scenario split-stateful
  if [[ "$SCENARIO_STATUS" -ne 0 ]]; then
    fail "split-stateful mode reported failure as exit $SCENARIO_STATUS"
  fi
  if [[ "$SCENARIO_CALLS" -ne 2 ]]; then
    fail "split-stateful mode invoked xcodebuild $SCENARIO_CALLS times, expected two runs"
  fi

  local first_args second_args
  first_args="$(sed -n '1p' "$SCENARIO_DIR/arguments")"
  second_args="$(sed -n '2p' "$SCENARIO_DIR/arguments")"

  if ! echo "$first_args" | grep -q -- "programaTests/AppDelegateShortcutRoutingTests"; then
    fail "parallel split pass should skip AppDelegateShortcutRoutingTests"
  fi
  if ! echo "$first_args" | grep -q -- "-parallel-testing-enabled YES"; then
    fail "parallel split pass should enable parallel unit testing"
  fi
  if ! echo "$second_args" | grep -q -- "-only-testing:programaTests/AppDelegateShortcutRoutingTests"; then
    fail "stateful split pass should only run AppDelegateShortcutRoutingTests"
  fi
}

test_retries_one_real_swiftpm_resolution_failure
test_does_not_retry_ordinary_xctest_failure
test_propagates_deterministic_expected_failure
test_supports_split_stateful_mode

if [[ "$FAILURES" -ne 0 ]]; then
  echo "FAIL: $FAILURES CI unit-test runner regression(s) detected" >&2
  exit 1
fi

echo "PASS: CI unit-test runner retries only SwiftPM flakes and propagates test failures"
