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
    # Log the arguments the runner actually passed; the runner is expected to
    # invoke xcodebuild once per pass (parallel, then stateful).
    log_call "$0 $*"
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

test_display_readiness_exhaustion_cannot_report_success() {
  # Execute the workflow's actual shell so a green CI result requires tests to
  # have run. The fixture never creates a ready display or launches a real app.
  if ! python3 - "$ROOT_DIR/.github/workflows/ci.yml" "$TMP_DIR/display-readiness" <<'PY'
import os
from pathlib import Path
import subprocess
import sys

workflow = Path(sys.argv[1]).read_text().splitlines()
fixture = Path(sys.argv[2])
step_name = "- name: Run display resolution churn UI regression"
matches = [index for index, line in enumerate(workflow) if line.strip() == step_name]
if len(matches) != 1:
    raise SystemExit("Expected exactly one display resolution regression step")
step_indent = len(workflow[matches[0]]) - len(workflow[matches[0]].lstrip())
start = None
for index in range(matches[0] + 1, len(workflow)):
    line = workflow[index]
    line_indent = len(line) - len(line.lstrip())
    if line.strip() and line_indent <= step_indent:
        break
    if line_indent == step_indent + 2 and line.strip() == "run: |":
        start = index
        break
if start is None:
    raise SystemExit("Display resolution step must contain a literal shell block")
indent = len(workflow[start]) - len(workflow[start].lstrip()) + 2
block = []
for line in workflow[start + 1:]:
    if line.strip() and len(line) - len(line.lstrip()) < indent:
        break
    block.append(line[indent:])

bin_dir = fixture / "bin"
scripts = fixture / "scripts"
temporary = fixture / "tmp"
for directory in (bin_dir, scripts, temporary):
    directory.mkdir(parents=True)

# The step now attaches to the job's persistent virtual display instead of
# creating a second one, so it requires that display's ID file to already
# exist (written by the earlier "Create persistent virtual display" step).
(temporary / "programa-vdisplay-persistent.id").write_text("1\n")

def executable(path, body):
    path.write_text("#!/bin/bash\nset -euo pipefail\n" + body)
    path.chmod(0o755)

executable(bin_dir / "clang", '''
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "-o" ]]; then
    shift
    printf '#!/bin/bash\\nexit 0\\n' > "$1"
    chmod +x "$1"
    exit 0
  fi
  shift
done
exit 2
''')
executable(bin_dir / "sleep", "exit 0\n")
executable(bin_dir / "pkill", "exit 0\n")
executable(bin_dir / "uuidgen", "echo fixture-display\n")
executable(bin_dir / "xcodebuild", 'echo call >> "$TEST_DISPLAY_CALLS"\nexit 0\n')
executable(scripts / "locate-built-app.sh", 'printf "%s\\n" "$TEST_DISPLAY_APP"\n')
app = fixture / "Fixture.app"
(app / "Contents/MacOS").mkdir(parents=True)
executable(app / "Contents/MacOS/Programa DEV", "exit 0\n")

# Remap every absolute workflow scratch path, including cleanup targets, into
# this fixture, while preserving the workflow's shell quoting.
shell = "\n".join(block).replace("/tmp/", "${TEST_DISPLAY_TMP}/") + "\n"
script = fixture / "display-step.sh"
script.write_text(shell)
calls = fixture / "xcodebuild-calls"
environment = os.environ.copy()
environment.update({
    "PATH": f"{bin_dir}:/usr/bin:/bin",
    "TEST_DISPLAY_TMP": str(temporary),
    "TEST_DISPLAY_CALLS": str(calls),
    "TEST_DISPLAY_APP": str(app),
    "PROGRAMA_DERIVED_DATA_DIR": str(fixture / "derived"),
})
result = subprocess.run(
    ["/bin/bash", str(script)], cwd=fixture, env=environment,
    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=15,
)
(fixture / "output.log").write_text(result.stdout)
if result.stdout.count("ERROR: Virtual display not ready after 12s") != 2:
    raise SystemExit("Fixture did not exercise both display readiness attempts:\n" + result.stdout)
if calls.exists() and calls.read_text().strip():
    raise SystemExit("Unready display must not invoke xcodebuild")
if result.returncode == 0:
    raise SystemExit("Display readiness exhausted both attempts without tests, but CI reported success")
PY
  then
    fail "display readiness exhaustion did not fail safely before invoking tests"
  fi
}

test_retries_one_real_swiftpm_resolution_failure
test_does_not_retry_ordinary_xctest_failure
test_propagates_deterministic_expected_failure
test_supports_split_stateful_mode
test_display_readiness_exhaustion_cannot_report_success

if [[ "$FAILURES" -ne 0 ]]; then
  echo "FAIL: $FAILURES CI unit-test runner regression(s) detected" >&2
  exit 1
fi

echo "PASS: CI unit-test runner retries only SwiftPM flakes and propagates test failures"
