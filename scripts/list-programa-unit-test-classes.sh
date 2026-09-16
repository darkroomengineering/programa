#!/usr/bin/env bash
# Deterministic, sorted list of programaTests XCTestCase class names.
# Used by ci-run-unit-tests.sh to split the suite into alphabetical shards
# without needing a built test bundle to enumerate classes from.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TESTS_DIR="$ROOT_DIR/programaTests"

grep -rhoE 'class[[:space:]]+[A-Za-z0-9_]+[[:space:]]*:[[:space:]]*XCTestCase' \
  "$TESTS_DIR" --include='*.swift' \
  | sed -E 's/^class[[:space:]]+([A-Za-z0-9_]+).*/\1/' \
  | sort -u
