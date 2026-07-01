#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

PROJECT="GhosttyTabs.xcodeproj"
SCHEME="programa-unit"
CONFIGURATION="${PROGRAMA_TEST_CONFIGURATION:-Debug}"
DESTINATION="${PROGRAMA_TEST_DESTINATION:-platform=macOS}"

# Default to `test` when no explicit xcodebuild action is provided.
if [ "$#" -eq 0 ]; then
  set -- test
fi

exec xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "$DESTINATION" \
  "$@"
