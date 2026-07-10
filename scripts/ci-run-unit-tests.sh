#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
XCODEBUILD_COMMAND="${PROGRAMA_XCODEBUILD_COMMAND:-xcodebuild}"
SOURCE_PACKAGES_DIR="${PROGRAMA_SOURCE_PACKAGES_DIR:-$ROOT_DIR/.ci-source-packages}"
OUTPUT_FILE="${PROGRAMA_TEST_OUTPUT_FILE:-/tmp/test-output.txt}"
SWIFTPM_CACHE_DIR="${PROGRAMA_SWIFTPM_CACHE_DIR:-$HOME/Library/Caches/org.swift.swiftpm}"
DERIVED_DATA_DIR="${PROGRAMA_DERIVED_DATA_DIR:-$HOME/Library/Developer/Xcode/DerivedData}"

run_unit_tests() {
  "$XCODEBUILD_COMMAND" \
    -project "$ROOT_DIR/GhosttyTabs.xcodeproj" \
    -scheme programa-unit \
    -configuration Debug \
    -clonedSourcePackagesDirPath "$SOURCE_PACKAGES_DIR" \
    -disableAutomaticPackageResolution \
    -destination "platform=macOS" \
    -parallel-testing-enabled NO \
    -skip-testing:programaTests/AppDelegateShortcutRoutingTests/testCmdWClosesWindowWhenClosingLastSurfaceInLastWorkspace \
    test 2>&1
}

set +e
run_unit_tests | tee "$OUTPUT_FILE"
EXIT_CODE=${PIPESTATUS[0]}
OUTPUT="$(cat "$OUTPUT_FILE")"
set -e

if [[ "$EXIT_CODE" -ne 0 ]] && grep -q "Could not resolve package dependencies" <<< "$OUTPUT"; then
  echo "SwiftPM package resolution failed, clearing caches and retrying once"
  rm -rf "$SWIFTPM_CACHE_DIR"
  mkdir -p "$SWIFTPM_CACHE_DIR"
  if [[ -d "$DERIVED_DATA_DIR" ]]; then
    find "$DERIVED_DATA_DIR" -maxdepth 1 -type d -name 'GhosttyTabs-*' -exec rm -rf {} +
  fi

  set +e
  run_unit_tests | tee "$OUTPUT_FILE"
  EXIT_CODE=${PIPESTATUS[0]}
  OUTPUT="$(cat "$OUTPUT_FILE")"
  set -e
fi

if [[ "$EXIT_CODE" -ne 0 ]]; then
  echo "Unit tests failed with exit code $EXIT_CODE"
  exit "$EXIT_CODE"
fi
