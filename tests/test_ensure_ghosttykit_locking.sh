#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/programa-ghosttykit-locking.XXXXXX")"
trap 'pkill -P $$ >/dev/null 2>&1 || true; rm -rf "$TMP_DIR"' EXIT

FAILURES=0

fail() {
  echo "FAIL: $*" >&2
  FAILURES=$((FAILURES + 1))
}

wait_for_file() {
  local path="$1"
  local attempts="${2:-50}"
  local index=0
  while [[ "$index" -lt "$attempts" ]]; do
    [[ -e "$path" ]] && return 0
    sleep 0.05
    index=$((index + 1))
  done
  return 1
}

wait_for_exit() {
  local pid="$1"
  local attempts="${2:-20}"
  local index=0
  while [[ "$index" -lt "$attempts" ]]; do
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid" 2>/dev/null || return $?
      return 0
    fi
    sleep 0.05
    index=$((index + 1))
  done
  return 124
}

make_fixture() {
  local name="$1"
  local fixture="$TMP_DIR/$name"
  local repo="$fixture/repo"
  local bin="$fixture/bin"

  mkdir -p "$repo/scripts" "$repo/ghostty/include" "$bin"
  cp "$ROOT_DIR/scripts/ensure-ghosttykit.sh" "$repo/scripts/ensure-ghosttykit.sh"
  chmod +x "$repo/scripts/ensure-ghosttykit.sh"
  printf '#include "ghostty/include/ghostty.h"\n' > "$repo/ghostty.h"
  printf 'fixture\n' > "$repo/ghostty/include/ghostty.h"

  (
    cd "$repo/ghostty"
    git init -q
    git config user.email test@example.com
    git config user.name "Programa Tests"
    git add include/ghostty.h
    git commit -qm fixture
  )

  cat > "$bin/zig" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$$" >> "${TEST_ZIG_CALL_LOG:?}"
touch "${TEST_ZIG_STARTED:?}"
if [[ "${TEST_BLOCK_ZIG:-0}" == "1" ]]; then
  while [[ ! -e "${TEST_ZIG_RELEASE:?}" ]]; do
    sleep 0.05
  done
fi
mkdir -p macos/GhosttyKit.xcframework/macos-arm64
printf 'archive\n' > macos/GhosttyKit.xcframework/macos-arm64/libghostty.a
EOF

  cat > "$bin/xcrun" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--find" && "${2:-}" == "ranlib" ]]; then
  printf '%s\n' "${TEST_RANLIB:?}"
  exit 0
fi
exit 1
EOF

  cat > "$bin/ranlib" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
  chmod +x "$bin/zig" "$bin/xcrun" "$bin/ranlib"

  printf '%s\n' "$fixture"
}

fixture_key() {
  git -C "$1/repo/ghostty" rev-parse HEAD
}

run_ensure_background() {
  local fixture="$1"
  local block_zig="$2"
  local output="$3"
  local cache="$fixture/cache"
  local started="$fixture/zig-started-$RANDOM"
  local release="$fixture/zig-release"
  local calls="$fixture/zig-calls.log"
  : > "$calls"

  (
    cd "$fixture/repo"
    PATH="$fixture/bin:/usr/bin:/bin" \
    HOME="$fixture/home" \
    PROGRAMA_GHOSTTYKIT_CACHE_DIR="$cache" \
    PROGRAMA_GHOSTTYKIT_LOCK_TIMEOUT="${TEST_LOCK_TIMEOUT:-5}" \
    PROGRAMA_GHOSTTYKIT_LOCK_POLL_INTERVAL="0.05" \
    TEST_ZIG_CALL_LOG="$calls" \
    TEST_ZIG_STARTED="$started" \
    TEST_ZIG_RELEASE="$release" \
    TEST_BLOCK_ZIG="$block_zig" \
    TEST_RANLIB="$fixture/bin/ranlib" \
    ./scripts/ensure-ghosttykit.sh
  ) >"$output" 2>&1 &
  ENSURE_PID=$!
  ENSURE_STARTED="$started"
  ENSURE_CALLS="$calls"
}

test_ready_cache_bypasses_live_build_lock() {
  local fixture key cache_dir lock_dir output pid status
  fixture="$(make_fixture cache-hit)"
  key="$(fixture_key "$fixture")"
  cache_dir="$fixture/cache/$key/GhosttyKit.xcframework"
  lock_dir="$fixture/cache/$key.lock"
  output="$fixture/cache-hit.out"
  mkdir -p "$cache_dir/macos-arm64" "$lock_dir"
  printf 'archive\n' > "$cache_dir/macos-arm64/libghostty.a"
  touch "$fixture/cache/$key/.ready"
  printf 'pid=%s\ntoken=live-owner\n' "$$" > "$lock_dir/owner"

  run_ensure_background "$fixture" 0 "$output"
  pid="$ENSURE_PID"
  status=0
  wait_for_exit "$pid" 8 || status=$?
  if [[ "$status" -eq 124 ]]; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "ready cache hit waited for the build lock instead of returning immediately"
  elif [[ "$status" -ne 0 ]]; then
    fail "ready cache hit failed (status $status): $(cat "$output")"
  elif [[ ! -L "$fixture/repo/GhosttyKit.xcframework" ]]; then
    fail "ready cache hit did not install the project xcframework symlink"
  fi
}

test_live_owner_is_never_stolen() {
  local fixture key lock_dir first_pid second_pid calls expected_token
  fixture="$(make_fixture live-owner)"
  key="$(fixture_key "$fixture")"
  lock_dir="$fixture/cache/$key.lock"

  run_ensure_background "$fixture" 1 "$fixture/first.out"
  first_pid="$ENSURE_PID"
  if ! wait_for_file "$ENSURE_STARTED"; then
    fail "first live-owner builder never entered zig"
    kill "$first_pid" 2>/dev/null || true
    return
  fi
  if [[ ! -f "$lock_dir/owner" ]]; then
    printf 'pid=%s\ntoken=first-owner\n' "$first_pid" > "$lock_dir/owner"
  fi
  expected_token="$(awk -F= '$1 == "token" { print $2; exit }' "$lock_dir/owner")"

  TEST_LOCK_TIMEOUT=0 run_ensure_background "$fixture" 0 "$fixture/second.out"
  second_pid="$ENSURE_PID"
  calls="$ENSURE_CALLS"
  sleep 1.4
  if [[ "$(wc -l < "$calls" | tr -d ' ')" -ne 0 ]]; then
    fail "waiter stole a live GhosttyKit lock and started a concurrent zig build"
  fi
  if [[ -z "$expected_token" ]] || [[ ! -f "$lock_dir/owner" ]] \
    || ! grep -Fq "token=$expected_token" "$lock_dir/owner"; then
    fail "waiter replaced the live GhosttyKit lock owner"
  fi

  touch "$fixture/zig-release"
  kill "$second_pid" 2>/dev/null || true
  wait "$second_pid" 2>/dev/null || true
  wait "$first_pid" 2>/dev/null || true
}

test_dead_owner_recovers_promptly() {
  local fixture key lock_dir output pid status
  fixture="$(make_fixture dead-owner)"
  key="$(fixture_key "$fixture")"
  lock_dir="$fixture/cache/$key.lock"
  output="$fixture/dead-owner.out"
  mkdir -p "$lock_dir"
  printf 'pid=99999999\ntoken=dead-owner\n' > "$lock_dir/owner"

  run_ensure_background "$fixture" 0 "$output"
  pid="$ENSURE_PID"
  status=0
  wait_for_exit "$pid" 10 || status=$?
  if [[ "$status" -eq 124 ]]; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "dead GhosttyKit lock owner was not recovered promptly"
  elif [[ "$status" -ne 0 ]]; then
    fail "dead-owner recovery failed (status $status): $(cat "$output")"
  fi
}

test_old_owner_cannot_release_replacement_lock() {
  local fixture key lock_dir owner_pid
  fixture="$(make_fixture ownership-release)"
  key="$(fixture_key "$fixture")"
  lock_dir="$fixture/cache/$key.lock"

  run_ensure_background "$fixture" 1 "$fixture/owner.out"
  owner_pid="$ENSURE_PID"
  if ! wait_for_file "$ENSURE_STARTED"; then
    fail "ownership-release builder never entered zig"
    kill "$owner_pid" 2>/dev/null || true
    return
  fi

  rm -rf "$lock_dir"
  mkdir -p "$lock_dir"
  touch "$fixture/zig-release"
  wait "$owner_pid" 2>/dev/null || true

  if [[ ! -d "$lock_dir" ]]; then
    fail "old lock owner removed a replacement lock during exit cleanup"
  fi
}

test_ready_cache_bypasses_live_build_lock
test_live_owner_is_never_stolen
test_dead_owner_recovers_promptly
test_old_owner_cannot_release_replacement_lock

if [[ "$FAILURES" -ne 0 ]]; then
  echo "FAIL: $FAILURES GhosttyKit locking regression(s) detected" >&2
  exit 1
fi

echo "PASS: GhosttyKit cache locking preserves live owners and recovers stale owners"
