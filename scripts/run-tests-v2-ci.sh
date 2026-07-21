#!/usr/bin/env bash
set -euo pipefail

# CI runner for a curated stable subset of tests_v2 (see tests_v2/ci_subset.txt).
#
# Unlike scripts/run-tests-v2.sh (which is guarded to only run on the cmux-vm
# and runs the entire tests_v2 suite), this script is intended to run as a
# required PR-gating job on GitHub-hosted macOS runners. It expects the
# `programa` scheme to already be built (see the `tests-v2-subset` job in
# .github/workflows/ci.yml) and locates the built app in DerivedData rather
# than building it itself.

cd "$(dirname "$0")/.."

RUN_TAG="ci-v2"
SUBSET_FILE="tests_v2/ci_subset.txt"

APP="$(find "$HOME/Library/Developer/Xcode/DerivedData" -path "*/Build/Products/Debug/Programa DEV.app" -print -quit 2>/dev/null || true)"
if [ -z "$APP" ] || [ ! -d "$APP" ]; then
  echo "ERROR: Programa DEV.app not found in DerivedData" >&2
  exit 1
fi

if [ ! -f "$SUBSET_FILE" ]; then
  echo "ERROR: Subset file not found: $SUBSET_FILE" >&2
  exit 1
fi

cleanup() {
  pkill -x "Programa DEV" || true
  pkill -x "Programa" || true
  rm -f /tmp/programa*.sock || true
}

launch_and_wait() {
  cleanup
  # Wait briefly for the previous instance to fully terminate; LaunchServices can flake if we
  # relaunch too quickly.
  for _ in {1..50}; do
    pgrep -x "Programa DEV" >/dev/null 2>&1 || break
    sleep 0.1
  done

  # Force socket mode for deterministic automation runs, independent of prior user settings.
  defaults write com.darkroom.programa.debug socketControlMode -string full >/dev/null 2>&1 || true

  # Launch the app binary directly (not `open`, which can silently flake on CI runners) with
  # UI test mode enabled so startup follows deterministic test codepaths.
  PROGRAMA_TAG="$RUN_TAG" PROGRAMA_UI_TEST_MODE=1 "$APP/Contents/MacOS/Programa DEV" >/dev/null 2>&1 &

  SOCK=""
  for _ in {1..120}; do
    SOCK=$(ls -t /tmp/programa-debug*.sock /tmp/programa*.sock 2>/dev/null | head -1 || true)
    if [ -n "$SOCK" ] && [ -S "$SOCK" ]; then
      break
    fi
    sleep 0.25
  done

  if [ -z "$SOCK" ] || [ ! -S "$SOCK" ]; then
    echo "ERROR: Socket not ready (looked for /tmp/programa*.sock)" >&2
    exit 1
  fi
  export PROGRAMA_SOCKET_PATH="$SOCK"
  export PROGRAMA_SOCKET="$SOCK"

  echo "== wait ready =="
  python3 - <<'PY'
import time
import os
import sys

sys.path.insert(0, os.path.join(os.getcwd(), "tests_v2"))
from cmux import cmux  # type: ignore

deadline = time.time() + 30.0
last = None
client = None
while time.time() < deadline:
    try:
        client = cmux()
        client.connect()
        break
    except Exception as e:
        last = e
        time.sleep(0.1)
else:
    raise SystemExit(f"ERROR: Socket path exists but connect keeps failing: {last}")

workspace_ready = False
while time.time() < deadline:
    try:
        _ = client.current_workspace()
        # Many focus-sensitive tests require the main window to be key.
        try:
            client.activate_app()
        except Exception:
            pass
        workspace_ready = True
        break
    except Exception as e:
        last = e
        time.sleep(0.1)

if not workspace_ready:
    print(f"WARN: continuing without workspace-ready state: {last}")

# Use a fresh connection to avoid stale-listener races where the first connection succeeds but
# immediate reconnects fail with ECONNREFUSED.
probe_deadline = time.time() + 10.0
while time.time() < probe_deadline:
    probe = None
    try:
        probe = cmux()
        probe.connect()
        if not probe.ping():
            raise RuntimeError("ping returned false")
        print("ready")
        break
    except Exception as e:
        last = e
        time.sleep(0.1)
    finally:
        if probe is not None:
            try:
                probe.close()
            except Exception:
                pass
else:
    raise SystemExit(f"ERROR: Ready-check reconnect/ping failed: {last}")

# Force a single fresh workspace so startup-state restoration doesn't leave tests
# focused on non-terminal panels (which breaks read_screen/read_terminal_text assumptions)
# or with extra pre-existing workspaces that make ordering-dependent tests flaky.
bootstrap_last = None
for _ in range(3):
    try:
        existing_ids = []
        try:
            existing_ids = [row[1] for row in client.list_workspaces() if len(row) >= 2]
        except Exception:
            existing_ids = []

        ws_id = client.new_workspace()
        client.select_workspace(ws_id)

        for old_id in existing_ids:
            if old_id == ws_id:
                continue
            try:
                client.close_workspace(old_id)
            except Exception:
                pass

        surfaces = client.list_surfaces()
        if not surfaces:
            raise RuntimeError("new workspace has no surfaces")
        client.focus_surface(surfaces[0][1])
        break
    except Exception as e:
        bootstrap_last = e
        time.sleep(0.2)
else:
    raise SystemExit(f"ERROR: Failed to bootstrap fresh terminal workspace: {bootstrap_last}")

window_last = None
window_deadline = time.time() + 10.0
while time.time() < window_deadline:
    try:
        health = client.surface_health()
        if any(bool(row.get("in_window")) for row in health):
            break
        client.activate_app()
    except Exception as e:
        window_last = e
    time.sleep(0.1)
else:
    print(f"WARN: no in-window terminal surface detected before test start: {window_last}")

if client is not None:
    try:
        client.close()
    except Exception:
        pass
PY
}

run_test_with_retry() {
  local f="$1"
  local attempts=3
  local n=1

  while [ "$n" -le "$attempts" ]; do
    echo "RUN  $f (attempt $n/$attempts)"
    if python3 "$f"; then
      return 0
    fi

    if [ "$n" -ge "$attempts" ]; then
      return 1
    fi

    echo "WARN: attempt $n failed for $f; relaunching and retrying" >&2
    echo "== relaunch (retry) =="
    launch_and_wait
    n=$((n + 1))
  done

  return 1
}

echo "== tests (v2 CI subset) =="
fail=0
while IFS= read -r base; do
  [ -z "$base" ] && continue
  case "$base" in
    \#*) continue ;;
  esac

  f="tests_v2/$base"
  if [ ! -f "$f" ]; then
    echo "ERROR: Listed test file not found: $f" >&2
    fail=1
    break
  fi

  echo "== launch ($base) =="
  launch_and_wait
  if ! run_test_with_retry "$f"; then
    echo "FAIL $f" >&2
    fail=1
    break
  fi
done < "$SUBSET_FILE"

echo "== cleanup =="
cleanup

exit "$fail"
