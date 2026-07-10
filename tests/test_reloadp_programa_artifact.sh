#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/programa-reloadp-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

FAKE_HOME="$TMP_DIR/home"
STUB_BIN="$TMP_DIR/bin"
COMMAND_LOG="$TMP_DIR/commands.log"
APP_PATH="$FAKE_HOME/Library/Developer/Xcode/DerivedData/ProgramaFixture/Build/Products/Release/Programa.app"
APP_EXECUTABLE="$APP_PATH/Contents/MacOS/Programa"

mkdir -p "$(dirname "$APP_EXECUTABLE")" "$STUB_BIN"
printf '#!/usr/bin/env bash\nexit 0\n' > "$APP_EXECUTABLE"
chmod +x "$APP_EXECUTABLE"
: > "$COMMAND_LOG"

write_logging_stub() {
  local name="$1"
  cat > "$STUB_BIN/$name" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s' "$(basename "$0")" >> "${TEST_COMMAND_LOG:?}"
printf ' <%s>' "$@" >> "${TEST_COMMAND_LOG:?}"
printf '\n' >> "${TEST_COMMAND_LOG:?}"
exit 0
EOF
  chmod +x "$STUB_BIN/$name"
}

for command in xcodebuild pkill sleep open; do
  write_logging_stub "$command"
done

cat > "$STUB_BIN/pgrep" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s' "pgrep" >> "${TEST_COMMAND_LOG:?}"
printf ' <%s>' "$@" >> "${TEST_COMMAND_LOG:?}"
printf '\n' >> "${TEST_COMMAND_LOG:?}"
case " $* " in
  *"/Programa.app/Contents/MacOS/Programa"*) exit 0 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$STUB_BIN/pgrep"

export TEST_COMMAND_LOG="$COMMAND_LOG"
set +e
OUTPUT="$({
  cd "$ROOT_DIR"
  HOME="$FAKE_HOME" PATH="$STUB_BIN:/usr/bin:/bin" bash scripts/reloadp.sh
} 2>&1)"
STATUS=$?
set -e

if [[ "$STATUS" -ne 0 ]]; then
  echo "FAIL: reloadp.sh did not locate the built Programa.app artifact" >&2
  echo "$OUTPUT" >&2
  exit 1
fi

if ! grep -Fq "open <-g> <$APP_PATH>" "$COMMAND_LOG"; then
  echo "FAIL: reloadp.sh did not launch the expected Programa.app" >&2
  cat "$COMMAND_LOG" >&2
  exit 1
fi

if ! grep -Fq "$APP_EXECUTABLE" "$COMMAND_LOG"; then
  echo "FAIL: reloadp.sh did not verify the Programa executable" >&2
  cat "$COMMAND_LOG" >&2
  exit 1
fi

if grep -Fq "cmux" "$COMMAND_LOG"; then
  echo "FAIL: reloadp.sh still targets the retired cmux product" >&2
  cat "$COMMAND_LOG" >&2
  exit 1
fi

echo "PASS: reloadp.sh locates, launches, and verifies the Programa Release artifact"
