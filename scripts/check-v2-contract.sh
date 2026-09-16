#!/bin/bash
# Regenerates the v2 contract's derived files into a temp dir and diffs them against the
# checked-in copies. Exits 1 on any drift, so CI catches a contract/handler/generator that
# fell out of sync before it ships.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

python3 scripts/gen-v2-contract.py --out-dir "$TMP_DIR" > /dev/null

STATUS=0

check_file() {
    local rel_path="$1"
    if ! diff -u "$rel_path" "$TMP_DIR/$rel_path" > /tmp/v2-contract-diff.$$ 2>&1; then
        echo "DRIFT: $rel_path does not match what scripts/gen-v2-contract.py produces." >&2
        echo "Run: python3 scripts/gen-v2-contract.py" >&2
        cat /tmp/v2-contract-diff.$$ >&2
        STATUS=1
    fi
    rm -f /tmp/v2-contract-diff.$$
}

check_file "Sources/V2CommandCatalog.swift"
check_file "tests_v2/programa_v2.py"
check_file "CLI/V2MethodNames.swift"

if [ "$STATUS" -eq 0 ]; then
    echo "v2 contract check: OK (Sources/V2CommandCatalog.swift, tests_v2/programa_v2.py, CLI/V2MethodNames.swift all match contracts/v2/methods.json)"
fi

exit "$STATUS"
