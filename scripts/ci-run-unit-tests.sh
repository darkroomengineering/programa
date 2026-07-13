#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
XCODEBUILD_COMMAND="${PROGRAMA_XCODEBUILD_COMMAND:-xcodebuild}"
SOURCE_PACKAGES_DIR="${PROGRAMA_SOURCE_PACKAGES_DIR:-$ROOT_DIR/.ci-source-packages}"
OUTPUT_FILE="${PROGRAMA_TEST_OUTPUT_FILE:-/tmp/test-output.txt}"
SWIFTPM_CACHE_DIR="${PROGRAMA_SWIFTPM_CACHE_DIR:-$HOME/Library/Caches/org.swift.swiftpm}"
DERIVED_DATA_DIR="${PROGRAMA_DERIVED_DATA_DIR:-$HOME/Library/Developer/Xcode/DerivedData}"
TEST_SCOPE="${PROGRAMA_UNIT_TEST_SCOPE:-serial}"
STATEFUL_TEST_CLASS="programaTests/AppDelegateShortcutRoutingTests"
STATEFUL_TEST_SKIP="${STATEFUL_TEST_CLASS}/testCmdWClosesWindowWhenClosingLastSurfaceInLastWorkspace"

run_unit_tests() {
  local mode="${1:-serial}"
  local -a xcode_args=(
    "$XCODEBUILD_COMMAND"
    -project "$ROOT_DIR/GhosttyTabs.xcodeproj"
    -scheme programa-unit
    -configuration Debug
    -clonedSourcePackagesDirPath "$SOURCE_PACKAGES_DIR"
    -disableAutomaticPackageResolution
    -destination "platform=macOS"
  )

  case "$mode" in
    parallel)
      xcode_args+=("-skip-testing:${STATEFUL_TEST_CLASS}")
      xcode_args+=("-parallel-testing-enabled" "YES")
      ;;
    stateful)
      xcode_args+=("-only-testing:${STATEFUL_TEST_CLASS}")
      xcode_args+=("-skip-testing:${STATEFUL_TEST_SKIP}")
      xcode_args+=("-parallel-testing-enabled" "NO")
      ;;
    serial|*)
      xcode_args+=("-skip-testing:${STATEFUL_TEST_SKIP}")
      xcode_args+=("-parallel-testing-enabled" "NO")
      ;;
  esac

  "${xcode_args[@]}" test 2>&1
}

run_unit_tests_with_retry() {
  local mode="${1:-serial}"
  local attempt=0

  while true; do
    set +e
    run_unit_tests "$mode" | tee "$OUTPUT_FILE"
    EXIT_CODE=${PIPESTATUS[0]}
    OUTPUT="$(cat "$OUTPUT_FILE")"
    set -e

    if [[ "$EXIT_CODE" -eq 0 ]]; then
      return 0
    fi

    if [[ "$EXIT_CODE" -ne 0 ]] && (( attempt == 0 )) && \
      grep -q "Could not resolve package dependencies" <<< "$OUTPUT"; then
      echo "SwiftPM package resolution failed, clearing caches and retrying once"
      rm -rf "$SWIFTPM_CACHE_DIR"
      mkdir -p "$SWIFTPM_CACHE_DIR"
      if [[ -d "$DERIVED_DATA_DIR" ]]; then
        find "$DERIVED_DATA_DIR" -maxdepth 1 -type d -name 'GhosttyTabs-*' -exec rm -rf {} +
      fi
      attempt=1
      continue
    fi

    return "$EXIT_CODE"
  done
}

run_suite() {
  local mode="${1:-serial}"
  local label="${2:-Unit tests}"
  local exit_code=0

  # Capture the status directly; `$?` after a branchless `if` is always 0,
  # which silently turned test failures into successes.
  run_unit_tests_with_retry "$mode" || exit_code=$?

  if [[ "$exit_code" -ne 0 ]]; then
    echo "${label} failed with exit code $exit_code"
    exit "$exit_code"
  fi
}

if [[ "$TEST_SCOPE" == "split-stateful" ]]; then
  run_suite parallel "Stateful-free unit tests"
  run_suite stateful "Stateful unit tests"
else
  run_suite serial "Unit tests"
fi
