#!/usr/bin/env bash
set -euo pipefail

# CI runner for a curated stable subset of tests_v2 (see tests_v2/ci_subset.txt).
#
# Unlike scripts/run-tests-v2.sh (which is guarded to only run on the programa-vm
# and runs the entire tests_v2 suite), this script is intended to run as a
# required PR-gating job on GitHub-hosted macOS runners. It expects the
# `programa` scheme to already be built (see the `socket-integration-tests` job in
# .github/workflows/ci.yml) and locates the built app in DerivedData rather
# than building it itself.

cd "$(dirname "$0")/.."

RUN_TAG="ci-v2"
SUBSET_FILE="tests_v2/ci_subset.txt"
APP_PID=""
APP_LOG="/tmp/programa-v2-ci-stdout.log"
APP_LOCATOR="$PWD/scripts/locate-built-app.sh"
DERIVED_DATA_ROOT="${PROGRAMA_DERIVED_DATA_DIR:-}"

if [[ -z "$DERIVED_DATA_ROOT" || "$DERIVED_DATA_ROOT" != /* ]]; then
  echo "ERROR: PROGRAMA_DERIVED_DATA_DIR must be the absolute DerivedData path built by this CI job" >&2
  exit 1
fi

report_failure() {
  local status="$?"
  echo "--- Programa process ---" >&2
  if [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null; then
    echo "App PID $APP_PID is still alive" >&2
  elif [ -n "$APP_PID" ]; then
    set +e
    wait "$APP_PID"
    local app_status="$?"
    set -e
    echo "App PID $APP_PID exited with status $app_status" >&2
  else
    echo "App PID was not captured" >&2
  fi
  echo "--- Programa stdout/stderr ---" >&2
  tail -200 "$APP_LOG" 2>/dev/null >&2 || true
  echo "--- Programa debug log ---" >&2
  tail -100 "/tmp/programa-debug-$RUN_TAG.log" 2>/dev/null >&2 || true
  return "$status"
}

trap report_failure ERR

APP="$($APP_LOCATOR \
  --configuration Debug \
  --primary "Programa DEV" \
  --derived-data-root "$DERIVED_DATA_ROOT")"

# Tests locate the programa CLI via PROGRAMA_CLI; the fallback search paths are
# VM-shaped and never match on a CI runner. The CLI ships inside the app bundle.
PROGRAMA_CLI="$APP/Contents/Resources/bin/programa"
if [ ! -x "$PROGRAMA_CLI" ]; then
  echo "ERROR: CLI binary not found or not executable at $PROGRAMA_CLI" >&2
  exit 1
fi
export PROGRAMA_CLI

# test_mcp_server_e2e.py looks in DerivedData paths a CI runner does not use, so hand it the
# binary shipped inside the app bundle.
PROGRAMA_MCP_BIN="$APP/Contents/Resources/bin/programa-mcp"
if [ ! -x "$PROGRAMA_MCP_BIN" ]; then
  echo "ERROR: programa-mcp binary not found or not executable at $PROGRAMA_MCP_BIN" >&2
  exit 1
fi
export PROGRAMA_MCP_BIN

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
  : > "$APP_LOG"
  PROGRAMA_TAG="$RUN_TAG" PROGRAMA_UI_TEST_MODE=1 "$APP/Contents/MacOS/Programa DEV" >"$APP_LOG" 2>&1 &
  APP_PID=$!

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
from programa_client import ProgramaClient  # type: ignore

deadline = time.time() + 30.0
last = None
client = None
while time.time() < deadline:
    try:
        client = ProgramaClient()
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
        probe = ProgramaClient()
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
