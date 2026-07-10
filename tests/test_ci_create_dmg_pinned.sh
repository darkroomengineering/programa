#!/usr/bin/env bash
# Executable contract for the release dependency installer.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
NPM_STUB="$TMP_DIR/npm"
NPM_LOG="$TMP_DIR/npm.log"

cat > "$NPM_STUB" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "${TEST_NPM_LOG:?}"
EOF
chmod +x "$NPM_STUB"

CREATE_DMG_VERSION=8.0.0 \
PROGRAMA_NPM_COMMAND="$NPM_STUB" \
TEST_NPM_LOG="$NPM_LOG" \
  "$ROOT_DIR/scripts/install-create-dmg.sh"

EXPECTED_ARGS=$'install\n--global\ncreate-dmg@8.0.0'
if [ "$(cat "$NPM_LOG")" != "$EXPECTED_ARGS" ]; then
  echo "FAIL: installer did not pass the explicit create-dmg version to npm" >&2
  exit 1
fi

rm -f "$NPM_LOG"
if CREATE_DMG_VERSION=latest \
  PROGRAMA_NPM_COMMAND="$NPM_STUB" \
  TEST_NPM_LOG="$NPM_LOG" \
  "$ROOT_DIR/scripts/install-create-dmg.sh" >"$TMP_DIR/invalid.out" 2>&1; then
  echo "FAIL: installer accepted a non-version create-dmg selector" >&2
  exit 1
fi

if [ -e "$NPM_LOG" ]; then
  echo "FAIL: installer invoked npm before rejecting a non-version selector" >&2
  exit 1
fi

echo "PASS: create-dmg installer requires and installs an explicit version"
