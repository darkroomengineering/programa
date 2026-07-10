#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/programa-reload-entrypoints.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

FAKE_HOME="$TMP_DIR/home"
STUB_BIN="$TMP_DIR/bin"
COMMAND_LOG="$TMP_DIR/commands.log"
ENSURE_MARKER="$TMP_DIR/ghosttykit-ready"
FAILURES=0

mkdir -p "$FAKE_HOME" "$STUB_BIN"
: > "$COMMAND_LOG"

fail() {
  echo "FAIL: $*" >&2
  FAILURES=$((FAILURES + 1))
}

cat > "$STUB_BIN/ensure-ghosttykit" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'ensure-ghosttykit\n' >> "${TEST_COMMAND_LOG:?}"
touch "${TEST_ENSURE_MARKER:?}"
EOF

cat > "$STUB_BIN/xcodebuild" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'xcodebuild <%s>\n' "$*" >> "${TEST_COMMAND_LOG:?}"
if [[ "${TEST_REQUIRE_ENSURE:-0}" == "1" && ! -f "${TEST_ENSURE_MARKER:?}" ]]; then
  echo "error: GhosttyKit dependency was not prepared before xcodebuild" >&2
  exit 42
fi

configuration="Debug"
derived_data=""
args=("$@")
index=0
while [[ "$index" -lt "${#args[@]}" ]]; do
  case "${args[$index]}" in
    -configuration)
      configuration="${args[$((index + 1))]}"
      index=$((index + 2))
      ;;
    -derivedDataPath)
      derived_data="${args[$((index + 1))]}"
      index=$((index + 2))
      ;;
    *)
      index=$((index + 1))
      ;;
  esac
done

if [[ -z "$derived_data" ]]; then
  derived_data="$HOME/Library/Developer/Xcode/DerivedData/ProgramaFixture"
fi
if [[ "$configuration" == "Debug" ]]; then
  product_name="Programa DEV"
  bundle_id="com.darkroom.programa.debug"
else
  product_name="Programa"
  bundle_id="com.darkroom.programa"
fi

app="$derived_data/Build/Products/$configuration/$product_name.app"
mkdir -p "$app/Contents/MacOS"
printf '#!/usr/bin/env bash\nexit 0\n' > "$app/Contents/MacOS/$product_name"
chmod +x "$app/Contents/MacOS/$product_name"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>$product_name</string>
<key>CFBundleDisplayName</key><string>$product_name</string>
<key>CFBundleIdentifier</key><string>$bundle_id</string>
</dict></plist>
PLIST
echo "** BUILD SUCCEEDED **"
EOF

cat > "$STUB_BIN/log-command" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s' "$(basename "$0")" >> "${TEST_COMMAND_LOG:?}"
printf ' <%s>' "$@" >> "${TEST_COMMAND_LOG:?}"
printf '\n' >> "${TEST_COMMAND_LOG:?}"
exit 0
EOF

for command in open pkill pgrep sleep lsof; do
  cp "$STUB_BIN/log-command" "$STUB_BIN/$command"
done
chmod +x "$STUB_BIN/ensure-ghosttykit" "$STUB_BIN/xcodebuild" "$STUB_BIN/log-command" \
  "$STUB_BIN/open" "$STUB_BIN/pkill" "$STUB_BIN/pgrep" "$STUB_BIN/sleep" "$STUB_BIN/lsof"

run_entrypoint() {
  local require_ensure="$1"
  shift
  (
    cd "$ROOT_DIR"
    HOME="$FAKE_HOME" \
    PATH="$STUB_BIN:/usr/bin:/bin" \
    TEST_COMMAND_LOG="$COMMAND_LOG" \
    TEST_ENSURE_MARKER="$ENSURE_MARKER" \
    TEST_REQUIRE_ENSURE="$require_ensure" \
    PROGRAMA_ENSURE_GHOSTTYKIT_COMMAND="$STUB_BIN/ensure-ghosttykit" \
    PROGRAMA_SKIP_ZIG_BUILD=1 \
    "$@"
  )
}

test_staging_uses_canonical_artifact_and_bundle_identity() {
  local derived output status app bundle_id
  derived="$TMP_DIR/staging-derived"
  output="$TMP_DIR/staging-artifact.out"
  rm -f "$ENSURE_MARKER"

  status=0
  run_entrypoint 0 bash scripts/reloads.sh \
    --tag fixture --derived-data "$derived" >"$output" 2>&1 || status=$?
  if [[ "$status" -ne 0 ]]; then
    fail "staging reload could not discover the canonical Programa.app artifact: $(cat "$output")"
    return
  fi

  app="$derived/Build/Products/Release/Programa STAGING fixture.app"
  if [[ ! -d "$app" ]]; then
    fail "staging reload did not produce canonical artifact $app"
    return
  fi
  bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "$bundle_id" != "com.darkroom.programa.staging.fixture" ]]; then
    fail "staging artifact bundle id was '$bundle_id', expected com.darkroom.programa.staging.fixture"
  fi
  if ! grep -Fq "open <-g> <$app>" "$COMMAND_LOG"; then
    fail "staging reload did not launch the canonical staging artifact"
  fi
}

assert_cold_entrypoint_prepares_dependency() {
  local label="$1"
  shift
  local output="$TMP_DIR/$label-cold.out"
  local status=0
  rm -f "$ENSURE_MARKER"
  : > "$COMMAND_LOG"

  run_entrypoint 1 "$@" >"$output" 2>&1 || status=$?
  if [[ "$status" -ne 0 ]]; then
    fail "$label did not prepare GhosttyKit before xcodebuild (status $status): $(cat "$output")"
    return
  fi
  if [[ ! -f "$ENSURE_MARKER" ]]; then
    fail "$label completed without invoking dependency preparation"
  fi
}

test_cold_entrypoints_prepare_dependency() {
  assert_cold_entrypoint_prepares_dependency \
    debug bash scripts/reload.sh --tag fixture-debug --derived-data "$TMP_DIR/debug-derived"
  assert_cold_entrypoint_prepares_dependency \
    release bash scripts/reloadp.sh
  assert_cold_entrypoint_prepares_dependency \
    staging bash scripts/reloads.sh --tag fixture-cold --derived-data "$TMP_DIR/staging-cold-derived"
}

test_staging_uses_canonical_artifact_and_bundle_identity
test_cold_entrypoints_prepare_dependency

if [[ "$FAILURES" -ne 0 ]]; then
  echo "FAIL: $FAILURES reload entrypoint regression(s) detected" >&2
  exit 1
fi

echo "PASS: reload entrypoints prepare dependencies and use canonical Programa artifacts"
