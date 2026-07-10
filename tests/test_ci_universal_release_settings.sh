#!/usr/bin/env bash
# Executable contract for release artifact architecture verification.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
LIPO_STUB="$TMP_DIR/lipo"

cat > "$LIPO_STUB" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "$1" != "-archs" ] || [ "$#" -ne 2 ]; then
  echo "unexpected lipo invocation" >&2
  exit 2
fi
cat "$2"
EOF
chmod +x "$LIPO_STUB"

printf 'arm64' > "$TMP_DIR/app"
printf 'arm64' > "$TMP_DIR/cli"
printf 'arm64' > "$TMP_DIR/helper"

PROGRAMA_LIPO_COMMAND="$LIPO_STUB" \
  "$ROOT_DIR/scripts/verify-release-architectures.sh" \
  "$TMP_DIR/app" "$TMP_DIR/cli" "$TMP_DIR/helper"

printf 'arm64 x86_64' > "$TMP_DIR/helper"
if PROGRAMA_LIPO_COMMAND="$LIPO_STUB" \
  "$ROOT_DIR/scripts/verify-release-architectures.sh" \
  "$TMP_DIR/app" "$TMP_DIR/cli" "$TMP_DIR/helper" >"$TMP_DIR/wrong.out" 2>&1; then
  echo "FAIL: verifier accepted an artifact with unexpected architectures" >&2
  exit 1
fi

if ! grep -Fq "expected 'arm64', got 'arm64 x86_64'" "$TMP_DIR/wrong.out"; then
  echo "FAIL: verifier did not identify the architecture mismatch" >&2
  exit 1
fi

if PROGRAMA_LIPO_COMMAND="$LIPO_STUB" \
  "$ROOT_DIR/scripts/verify-release-architectures.sh" "$TMP_DIR/missing" >"$TMP_DIR/missing.out" 2>&1; then
  echo "FAIL: verifier accepted a missing artifact" >&2
  exit 1
fi

echo "PASS: release artifact verifier enforces exact architectures"
