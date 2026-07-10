#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

hash_stdin() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    sha256sum | awk '{print $1}'
  fi
}

hash_file() {
  local path="$1"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{print $1}'
  else
    sha256sum "$path" | awk '{print $1}'
  fi
}

validate_bridge_header() {
  local path="$1"
  python3 - "$path" <<'PY'
from pathlib import Path
import sys

text = Path(sys.argv[1]).read_text()
required = '#include "ghostty/include/ghostty.h"'
if required not in text:
    raise SystemExit(1)
PY
}

if [[ ! -d "$PROJECT_DIR/ghostty" ]]; then
  echo "error: ghostty submodule is missing. Run ./scripts/setup.sh first." >&2
  exit 1
fi

if ! command -v zig >/dev/null 2>&1; then
  echo "Error: zig is not installed." >&2
  echo "Install via: brew install zig" >&2
  exit 1
fi

if [[ ! -f "$PROJECT_DIR/ghostty/include/ghostty.h" ]]; then
  echo "error: ghostty/include/ghostty.h is missing. Run ./scripts/setup.sh first." >&2
  exit 1
fi

if ! validate_bridge_header "$PROJECT_DIR/ghostty.h"; then
  echo "error: ghostty.h no longer points at ghostty/include/ghostty.h." >&2
  echo "Restore the bridge header so Xcode uses Ghostty's canonical C API." >&2
  exit 1
fi

GHOSTTY_SHA="$(git -C ghostty rev-parse HEAD)"
GHOSTTY_KEY="$GHOSTTY_SHA"
UNTRACKED_FILES="$(git -C ghostty ls-files --others --exclude-standard)"
if ! git -C ghostty diff --quiet --ignore-submodules=all HEAD -- || [[ -n "$UNTRACKED_FILES" ]]; then
  DIRTY_HASH="$(
    {
      printf 'head=%s\n' "$GHOSTTY_SHA"
      git -C ghostty diff --binary HEAD -- .
      if [[ -n "$UNTRACKED_FILES" ]]; then
        printf '\n--untracked--\n'
        while IFS= read -r path; do
          [[ -n "$path" ]] || continue
          printf 'path=%s\n' "$path"
          hash_file "$PROJECT_DIR/ghostty/$path"
        done <<< "$UNTRACKED_FILES"
      fi
    } | hash_stdin
  )"
  GHOSTTY_KEY="${GHOSTTY_SHA}-dirty-${DIRTY_HASH}"
fi

CACHE_ROOT="${PROGRAMA_GHOSTTYKIT_CACHE_DIR:-$HOME/.cache/programa/ghosttykit}"
CACHE_DIR="$CACHE_ROOT/$GHOSTTY_KEY"
CACHE_XCFRAMEWORK="$CACHE_DIR/GhosttyKit.xcframework"
LOCAL_XCFRAMEWORK="$PROJECT_DIR/ghostty/macos/GhosttyKit.xcframework"
LOCAL_KEY_STAMP="$LOCAL_XCFRAMEWORK/.ghostty_state_key"
LEGACY_LOCAL_SHA_STAMP="$LOCAL_XCFRAMEWORK/.ghostty_sha"
LOCK_DIR="$CACHE_ROOT/$GHOSTTY_KEY.lock"

mkdir -p "$CACHE_ROOT"

echo "==> Ghostty build key: $GHOSTTY_KEY"

LOCK_TIMEOUT="${PROGRAMA_GHOSTTYKIT_LOCK_TIMEOUT:-300}"
LOCK_POLL_INTERVAL="${PROGRAMA_GHOSTTYKIT_LOCK_POLL_INTERVAL:-1}"
# Legacy lock directories have no owner metadata. Give an older in-flight script
# the full historical build window before treating such a directory as abandoned.
MALFORMED_LOCK_GRACE=300
LOCK_OWNER_FILE="$LOCK_DIR/owner"
LOCK_TOKEN=""
PUBLISH_TMP_DIR=""

find_macos_archive() {
  local framework="$1"
  local candidate=""
  for candidate in "$framework"/macos-*/libghostty.a; do
    if [[ -f "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

cache_is_ready() {
  [[ -f "$CACHE_DIR/.ready" ]] || return 1
  [[ -d "$CACHE_XCFRAMEWORK" ]] || return 1
  find_macos_archive "$CACHE_XCFRAMEWORK" >/dev/null
}

lock_owner_value() {
  local key="$1"
  [[ -f "$LOCK_OWNER_FILE" ]] || return 1
  awk -F= -v key="$key" '$1 == key { print substr($0, index($0, "=") + 1); exit }' "$LOCK_OWNER_FILE"
}

lock_age_seconds() {
  local modified now
  modified="$(stat -f '%m' "$LOCK_DIR" 2>/dev/null || stat -c '%Y' "$LOCK_DIR" 2>/dev/null || true)"
  [[ "$modified" =~ ^[0-9]+$ ]] || return 1
  now="$(date +%s)"
  printf '%s\n' "$((now - modified))"
}

reap_lock_if_stale() {
  local owner_pid owner_token age reap_dir moved_token
  owner_pid="$(lock_owner_value pid 2>/dev/null || true)"
  owner_token="$(lock_owner_value token 2>/dev/null || true)"

  if [[ "$owner_pid" =~ ^[0-9]+$ ]] && [[ -n "$owner_token" ]]; then
    if kill -0 "$owner_pid" 2>/dev/null; then
      return 1
    fi
    echo "==> Recovering GhosttyKit cache lock from dead owner pid $owner_pid..."
  else
    age="$(lock_age_seconds 2>/dev/null || echo 0)"
    if (( age < MALFORMED_LOCK_GRACE )); then
      return 1
    fi
    echo "==> Recovering malformed GhosttyKit cache lock..."
  fi

  reap_dir="$LOCK_DIR.reap.$$.$RANDOM"
  if mv "$LOCK_DIR" "$reap_dir" 2>/dev/null; then
    moved_token="$(awk -F= '$1 == "token" { print substr($0, index($0, "=") + 1); exit }' "$reap_dir/owner" 2>/dev/null || true)"
    if [[ "$moved_token" == "$owner_token" ]]; then
      rm -rf "$reap_dir"
      return 0
    fi
    # Ownership changed after inspection. Restore the directory rather than
    # deleting a successor's lock.
    if [[ ! -e "$LOCK_DIR" ]]; then
      mv "$reap_dir" "$LOCK_DIR" 2>/dev/null || true
    fi
  fi
  return 1
}

release_lock() {
  local current_token release_dir moved_token
  [[ -n "$LOCK_TOKEN" && -d "$LOCK_DIR" ]] || return 0
  current_token="$(lock_owner_value token 2>/dev/null || true)"
  [[ "$current_token" == "$LOCK_TOKEN" ]] || return 0

  release_dir="$LOCK_DIR.release.$$.$RANDOM"
  if ! mv "$LOCK_DIR" "$release_dir" 2>/dev/null; then
    return 0
  fi
  moved_token="$(awk -F= '$1 == "token" { print substr($0, index($0, "=") + 1); exit }' "$release_dir/owner" 2>/dev/null || true)"
  if [[ "$moved_token" == "$LOCK_TOKEN" ]]; then
    rm -rf "$release_dir"
  elif [[ ! -e "$LOCK_DIR" ]]; then
    mv "$release_dir" "$LOCK_DIR" 2>/dev/null || true
  fi
}

cleanup() {
  if [[ -n "$PUBLISH_TMP_DIR" && -d "$PUBLISH_TMP_DIR" ]]; then
    rm -rf "$PUBLISH_TMP_DIR"
  fi
  release_lock
}
trap cleanup EXIT

acquire_lock() {
  local lock_start candidate_dir candidate_name
  lock_start=$SECONDS
  while true; do
    LOCK_TOKEN="$$-$(date +%s)-$RANDOM"
    candidate_dir="$CACHE_ROOT/.${GHOSTTY_KEY}.lock-candidate.$LOCK_TOKEN"
    candidate_name="$(basename "$candidate_dir")"
    mkdir "$candidate_dir"
    printf 'pid=%s\ntoken=%s\nstarted_at=%s\n' "$$" "$LOCK_TOKEN" "$(date +%s)" > "$candidate_dir/owner"
    if mv "$candidate_dir" "$LOCK_DIR" 2>/dev/null \
      && [[ "$(lock_owner_value token 2>/dev/null || true)" == "$LOCK_TOKEN" ]]; then
      return 0
    fi
    # If another process won, macOS mv may have nested our candidate inside its
    # directory. Remove only our token-named candidate and leave the owner intact.
    rm -rf "$candidate_dir" "$LOCK_DIR/$candidate_name"
    LOCK_TOKEN=""

    if reap_lock_if_stale; then
      continue
    fi
    if (( SECONDS - lock_start > LOCK_TIMEOUT )); then
      echo "error: timed out waiting for live GhosttyKit cache lock after ${LOCK_TIMEOUT}s" >&2
      return 1
    fi
    echo "==> Waiting for GhosttyKit cache lock for $GHOSTTY_KEY..."
    sleep "$LOCK_POLL_INTERVAL"
  done
}

prepare_archive_index() {
  local framework="$1"
  local archive
  if ! archive="$(find_macos_archive "$framework")"; then
    echo "error: GhosttyKit.xcframework has no macOS libghostty.a" >&2
    return 1
  fi
  echo "==> Refreshing libghostty archive index..."
  if ! command -v xcrun >/dev/null 2>&1; then
    echo "error: xcrun is required to refresh libghostty archive index." >&2
    return 1
  fi
  if ! XCODE_RANLIB="$(xcrun --find ranlib 2>/dev/null)"; then
    echo "error: could not locate ranlib via xcrun." >&2
    return 1
  fi
  "$XCODE_RANLIB" "$archive"
}

if cache_is_ready; then
  echo "==> Reusing ready cached GhosttyKit.xcframework"
else
  acquire_lock

  # Another process may have published the cache while this process waited.
  if cache_is_ready; then
    echo "==> Reusing ready cached GhosttyKit.xcframework"
  else
    SOURCE_XCFRAMEWORK=""
    if [[ -d "$CACHE_XCFRAMEWORK" ]]; then
      # Upgrade cache entries created before atomic readiness stamps were introduced.
      echo "==> Validating existing GhosttyKit cache entry"
      SOURCE_XCFRAMEWORK="$CACHE_XCFRAMEWORK"
    fi

    if [[ -z "$SOURCE_XCFRAMEWORK" ]]; then
      LOCAL_KEY=""
      if [[ -f "$LOCAL_KEY_STAMP" ]]; then
        LOCAL_KEY="$(cat "$LOCAL_KEY_STAMP")"
      elif [[ -f "$LEGACY_LOCAL_SHA_STAMP" ]]; then
        LOCAL_KEY="$(cat "$LEGACY_LOCAL_SHA_STAMP")"
      fi

      if [[ -d "$LOCAL_XCFRAMEWORK" && "$LOCAL_KEY" == "$GHOSTTY_KEY" ]]; then
        echo "==> Seeding cache from existing local GhosttyKit.xcframework (build key matches)"
      else
        echo "==> Building GhosttyKit.xcframework (this may take a few minutes)..."
        (
          cd ghostty
          zig build -Demit-xcframework=true -Demit-macos-app=false -Dxcframework-target=native -Doptimize=ReleaseFast
        )
        echo "$GHOSTTY_KEY" > "$LOCAL_KEY_STAMP"
        echo "$GHOSTTY_SHA" > "$LEGACY_LOCAL_SHA_STAMP"
      fi

      if [[ ! -d "$LOCAL_XCFRAMEWORK" ]]; then
        echo "Error: GhosttyKit.xcframework not found at $LOCAL_XCFRAMEWORK" >&2
        exit 1
      fi
      SOURCE_XCFRAMEWORK="$LOCAL_XCFRAMEWORK"
    fi

    PUBLISH_TMP_DIR="$(mktemp -d "$CACHE_ROOT/.ghosttykit-tmp.XXXXXX")"
    cp -R "$SOURCE_XCFRAMEWORK" "$PUBLISH_TMP_DIR/GhosttyKit.xcframework"
    prepare_archive_index "$PUBLISH_TMP_DIR/GhosttyKit.xcframework"
    touch "$PUBLISH_TMP_DIR/.ready"

    # Ready cache readers only observe the old complete entry or this complete new one.
    rm -rf "$CACHE_DIR"
    mv "$PUBLISH_TMP_DIR" "$CACHE_DIR"
    PUBLISH_TMP_DIR=""
    echo "==> Cached GhosttyKit.xcframework at $CACHE_XCFRAMEWORK"
  fi
fi

echo "==> Creating symlink for GhosttyKit.xcframework..."
ln -sfn "$CACHE_XCFRAMEWORK" GhosttyKit.xcframework
