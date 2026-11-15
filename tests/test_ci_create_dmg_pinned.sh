#!/usr/bin/env bash
# Executable contract for the release dependency installer.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
BUN_STUB="$TMP_DIR/bun"
BUN_LOG="$TMP_DIR/bun.log"
BUN_CWD="$TMP_DIR/bun.cwd"

cat > "$BUN_STUB" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$PWD" > "${TEST_BUN_CWD:?}"
printf '%s\n' "$@" > "${TEST_BUN_LOG:?}"
EOF
chmod +x "$BUN_STUB"

CREATE_DMG_VERSION=8.1.0 \
PROGRAMA_BUN_COMMAND="$BUN_STUB" \
TEST_BUN_LOG="$BUN_LOG" \
TEST_BUN_CWD="$BUN_CWD" \
  "$ROOT_DIR/scripts/install-create-dmg.sh"

BUN_CALL=()
while IFS= read -r argument; do BUN_CALL+=("$argument"); done < "$BUN_LOG"
if [[ " ${BUN_CALL[*]} " != *" install "* || " ${BUN_CALL[*]} " != *" --frozen-lockfile "* || " ${BUN_CALL[*]} " != *" --ignore-scripts "* ]]; then
  echo "FAIL: installer did not use a frozen local Bun install with lifecycle scripts disabled" >&2
  exit 1
fi
if [[ " ${BUN_CALL[*]} " == *" --global "* || " ${BUN_CALL[*]} " == *" add "* || " ${BUN_CALL[*]} " == *" create-dmg@"* ]]; then
  echo "FAIL: installer used global or range-based package resolution" >&2
  exit 1
fi

INSTALL_DIR="$(cat "$BUN_CWD")"
for ((index = 0; index < ${#BUN_CALL[@]}; index += 1)); do
  if [[ "${BUN_CALL[index]}" == "--cwd" ]]; then
    INSTALL_DIR="${BUN_CALL[index + 1]:-}"
  fi
done
[[ -f "${INSTALL_DIR}/package.json" && -f "${INSTALL_DIR}/bun.lock" ]] || {
  echo "FAIL: Bun install directory lacks package.json or committed bun.lock" >&2
  exit 1
}
node - "${INSTALL_DIR}/package.json" "${INSTALL_DIR}/bun.lock" 8.1.0 <<'NODE'
const fs = require("node:fs");
const [packagePath, lockPath, expectedVersion] = process.argv.slice(2);
const packageJson = JSON.parse(fs.readFileSync(packagePath, "utf8"));
const declared = packageJson.dependencies?.["create-dmg"] ?? packageJson.devDependencies?.["create-dmg"];
if (declared !== expectedVersion) process.exit(1);
const lock = fs.readFileSync(lockPath, "utf8");
if (!lock.includes(`create-dmg@${expectedVersion}`)) process.exit(1);
if (!/sha512-[A-Za-z0-9+/]+={0,2}/.test(lock)) process.exit(1);
NODE

for invalid_version in latest 8.0.1; do
  rm -f "$BUN_LOG"
  if CREATE_DMG_VERSION="${invalid_version}" \
    PROGRAMA_BUN_COMMAND="$BUN_STUB" \
    TEST_BUN_LOG="$BUN_LOG" \
    TEST_BUN_CWD="$BUN_CWD" \
    "$ROOT_DIR/scripts/install-create-dmg.sh" >"$TMP_DIR/invalid.out" 2>&1; then
    echo "FAIL: installer accepted create-dmg version ${invalid_version}" >&2
    exit 1
  fi

  if [ -e "$BUN_LOG" ]; then
    echo "FAIL: installer invoked Bun before rejecting create-dmg version ${invalid_version}" >&2
    exit 1
  fi
done

echo "PASS: create-dmg installer uses an integrity-locked local Bun install with scripts disabled"
