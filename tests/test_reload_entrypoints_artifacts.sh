#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/programa-reload-entrypoints.XXXXXX")"
TMP_DIR="$(cd "$TMP_DIR" && pwd -P)"
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

# Each fixture owns a unique compatibility path and a short HOME (Unix socket
# paths on macOS are limited to 104 bytes). Never inspect a real app's sockets.
python3 - "$ROOT_DIR" "$STUB_BIN" <<'PY' || FAILURES=$((FAILURES + 1))
from pathlib import Path
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import uuid

root, stub_bin = map(Path, sys.argv[1:])
failures = []

def check(condition, message):
    if not condition:
        failures.append(message)
        print(f"FAIL: {message}", file=sys.stderr)

with tempfile.TemporaryDirectory(prefix="pr-", dir="/tmp") as temporary:
    fixture = Path(temporary)
    tag_prefix = "rt-" + uuid.uuid4().hex[:8]
    home = fixture / "h"
    home.mkdir()
    environment = dict(os.environ, HOME=str(home), PATH=f"{stub_bin}:/usr/bin:/bin",
                       TEST_COMMAND_LOG=str(fixture / "commands"),
                       TEST_ENSURE_MARKER=str(fixture / "ready"),
                       TEST_REQUIRE_ENSURE="1", PROGRAMA_SKIP_ZIG_BUILD="1",
                       PROGRAMA_ENSURE_GHOSTTYKIT_COMMAND=str(stub_bin / "ensure-ghosttykit"))

    def build(tag):
        result = subprocess.run(["bash", "scripts/reload.sh", "--tag", tag,
                                 "--derived-data", str(fixture / tag)],
                                cwd=root, env=environment, capture_output=True, text=True)
        check(result.returncode == 0, f"build-only {tag} failed: {result.stdout}{result.stderr}")
        return fixture / tag

    for kind in ("directory", "file", "absent", "symlink"):
        tag = f"{tag_prefix}-{kind}"
        compatibility = Path(f"/tmp/programa-{tag}")
        target = fixture / f"{kind}-target"
        # Refuse to claim an unexpected pre-existing path, even with unique tags.
        if os.path.lexists(compatibility):
            raise RuntimeError(f"fixture path already exists: {compatibility}")
        try:
            if kind == "directory":
                compatibility.mkdir()
                (compatibility / "sentinel").write_text("preserve directory")
            elif kind == "file":
                compatibility.write_text("preserve file")
            elif kind == "symlink":
                target.mkdir()
                (target / "sentinel").write_text("preserve target")
                compatibility.symlink_to(target, target_is_directory=True)
            derived = build(tag)
            if kind == "directory":
                check(not compatibility.is_symlink() and compatibility.is_dir()
                      and (compatibility / "sentinel").exists(),
                      "build-only must preserve a real compatibility directory and its contents")
            elif kind == "file":
                check(not compatibility.is_symlink() and compatibility.is_file()
                      and compatibility.read_text() == "preserve file",
                      "build-only must preserve a regular file at the compatibility path")
            else:
                check(compatibility.is_symlink() and compatibility.resolve() == derived.resolve(),
                      f"build-only must create or replace the {kind} compatibility link")
                if kind == "symlink":
                    check((target / "sentinel").read_text() == "preserve target",
                          "replacing a compatibility symlink must preserve its old target")
        finally:
            if compatibility.is_symlink() or compatibility.is_file():
                compatibility.unlink()
            elif compatibility.is_dir():
                shutil.rmtree(compatibility)

    tag = f"{tag_prefix}-socket"
    compatibility = Path(f"/tmp/programa-{tag}")
    ui_socket = Path(f"/tmp/programa-debug-{tag}.sock")
    daemon_socket = home / "Library/Application Support/programa" / f"programad-dev-{tag}.sock"
    daemon_socket.parent.mkdir(parents=True, exist_ok=True)
    if any(os.path.lexists(path) for path in (compatibility, ui_socket, daemon_socket)):
        raise RuntimeError("socket fixture path already exists")
    ready = fixture / "listeners-ready"
    server = subprocess.Popen([sys.executable, "-c", '''
import pathlib, signal, socket, sys
listeners = []
for path in sys.argv[2:]:
    listener = socket.socket(socket.AF_UNIX)
    listener.bind(path)
    listener.listen(8)
    listeners.append(listener)
pathlib.Path(sys.argv[1]).touch()
signal.pause()
''', str(ready), str(ui_socket), str(daemon_socket)])
    try:
        import time
        deadline = time.monotonic() + 5
        while not ready.exists() and server.poll() is None and time.monotonic() < deadline:
            time.sleep(0.01)
        if not ready.exists():
            raise RuntimeError("disposable socket listeners did not become ready")
        # lsof may only identify this fixture's daemon holder, never other PIDs.
        socket_bin = fixture / "bin"
        socket_bin.mkdir()
        lsof = socket_bin / "lsof"
        lsof.write_text(f'#!/bin/sh\n[ "$2" = "{daemon_socket}" ] && echo {server.pid}\n')
        lsof.chmod(0o755)
        environment["PATH"] = f"{socket_bin}:{stub_bin}:/usr/bin:/bin"
        build(tag)
        check(server.poll() is None, "build-only must not terminate the tagged daemon socket holder")
        for path in (ui_socket, daemon_socket):
            try:
                with socket.socket(socket.AF_UNIX) as client:
                    client.settimeout(1)
                    client.connect(str(path))
            except OSError as error:
                check(False, f"build-only must leave {path.name} connectable: {error}")
    finally:
        if server.poll() is None:
            server.terminate()
        server.wait(timeout=5)
        for path in (ui_socket, daemon_socket, compatibility):
            if os.path.lexists(path):
                path.unlink()

if failures:
    raise SystemExit(1)
print("PASS: build-only reload preserves existing data and live tagged sockets")
PY

# Exercise retention against disposable build trees, never the developer's caches.
python3 - "$ROOT_DIR/scripts/tagged-build-cache.py" "$TMP_DIR" <<'PY' || FAILURES=$((FAILURES + 1))
import fcntl
import importlib.util
import os
from pathlib import Path
import subprocess
import sys

helper, temporary = sys.argv[1:]
spec = importlib.util.spec_from_file_location("tagged_cache", helper)
cache = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cache)
fixture_home = Path(temporary) / "retention-home"
root = fixture_home / "Library/Developer/Xcode/DerivedData"
root.mkdir(parents=True)

def build(tag, timestamp):
    path = root / f"programa-{tag}"
    debug = path / "Build/Products/Debug"
    debug.mkdir(parents=True)
    (debug / "artifact").write_text("rebuildable")
    os.utime(debug, (timestamp, timestamp))
    return path

current = build("current", 1)
active = build("active", 2)
old = build("old", 3)
recent = [build("recent-a", 4), build("recent-b", 5)]
unknown = root / "programa-not-a-build"
unknown.mkdir()
outside = Path(temporary) / "outside-cache"
outside.mkdir()
(outside / "precious").write_text("preserve")
link = root / "programa-linked"
link.symlink_to(outside, target_is_directory=True)
cache.prune(root, current, commands=lambda: f"/tmp/{active.name}/Build/Products/Debug/App")
assert not old.exists(), "old inactive cache should be removed"
assert all(path.exists() for path in [current, active, unknown, *recent])
assert link.is_symlink() and (outside / "precious").read_text() == "preserve"

# A process-inspection failure must not remove even an eligible directory.
old = build("old", 0)
def unavailable():
    raise OSError("process table unavailable")
try:
    cache.prune(root, current, commands=unavailable)
except OSError:
    pass
else:
    raise AssertionError("process failure must stop cleanup")
assert old.exists()

environment = dict(os.environ, HOME=str(fixture_home))
command = [sys.executable, helper, "current", str(current), sys.executable, "-c"]
failed = subprocess.run(command + ["raise SystemExit(7)"], env=environment)
assert failed.returncode == 7 and old.exists(), "failed builds must not prune"

# Another managed build's shared lock defers cleanup without failing reload.
with (root / ".programa-tagged-builds.lock").open("a+") as lock:
    fcntl.flock(lock, fcntl.LOCK_SH)
    completed = subprocess.run(command + ["pass"], env=environment, capture_output=True, text=True)
    assert completed.returncode == 0, completed.stderr
    assert "deferred" in completed.stdout and old.exists()

# Once the concurrent build finishes, successful reload runs retention.
completed = subprocess.run(command + ["pass"], env=environment, capture_output=True, text=True)
assert completed.returncode == 0, completed.stderr
assert current.exists() and not old.exists()
print("PASS: tagged build retention preserves active, current, recent, and unknown data")
PY

if [[ "$FAILURES" -ne 0 ]]; then
  echo "FAIL: $FAILURES reload entrypoint regression(s) detected" >&2
  exit 1
fi

echo "PASS: reload entrypoints prepare dependencies and use canonical Programa artifacts"
