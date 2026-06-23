#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ -n "${GHOSTTY_SHA:-}" ]; then
  GHOSTTY_SHA="$GHOSTTY_SHA"
else
  if [ ! -d "$REPO_ROOT/ghostty" ] || ! git -C "$REPO_ROOT/ghostty" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "Missing ghostty submodule. Run ./scripts/setup.sh or git submodule update --init --recursive first." >&2
    exit 1
  fi
  GHOSTTY_SHA="$(git -C "$REPO_ROOT/ghostty" rev-parse HEAD)"
fi

TAG="xcframework-$GHOSTTY_SHA"
ARCHIVE_NAME="${GHOSTTYKIT_ARCHIVE_NAME:-GhosttyKit.xcframework.tar.gz}"
OUTPUT_DIR="${GHOSTTYKIT_OUTPUT_DIR:-GhosttyKit.xcframework}"
CHECKSUMS_FILE="${GHOSTTYKIT_CHECKSUMS_FILE:-$SCRIPT_DIR/ghosttykit-checksums.txt}"
DOWNLOAD_URL="${GHOSTTYKIT_URL:-https://github.com/darkroomengineering/ghostty/releases/download/$TAG/$ARCHIVE_NAME}"
DOWNLOAD_RETRIES="${GHOSTTYKIT_DOWNLOAD_RETRIES:-30}"
DOWNLOAD_RETRY_DELAY="${GHOSTTYKIT_DOWNLOAD_RETRY_DELAY:-20}"

_fallback_source_build() {
  echo "Prebuilt GhosttyKit unavailable, falling back to source build via ensure-ghosttykit.sh"
  "$SCRIPT_DIR/ensure-ghosttykit.sh"
  # ensure-ghosttykit.sh leaves a symlink at $REPO_ROOT/GhosttyKit.xcframework.
  # If OUTPUT_DIR differs from repo-root default, copy/link it there as well.
  if [ ! -e "$OUTPUT_DIR" ] && [ -e "$REPO_ROOT/GhosttyKit.xcframework" ]; then
    ln -sfn "$REPO_ROOT/GhosttyKit.xcframework" "$OUTPUT_DIR"
  fi
  if [ ! -e "$OUTPUT_DIR" ]; then
    echo "Source build did not produce $OUTPUT_DIR" >&2
    exit 1
  fi
  echo "Source build complete: $OUTPUT_DIR is ready"
}

if [ ! -f "$CHECKSUMS_FILE" ]; then
  echo "Missing checksum file: $CHECKSUMS_FILE" >&2
  exit 1
fi

EXPECTED_SHA256="$(
  awk -v sha="$GHOSTTY_SHA" '
    $1 == sha {
      print $2
      found = 1
      exit
    }
    END {
      if (!found) {
        exit 1
      }
    }
  ' "$CHECKSUMS_FILE" || true
)"

if [ -z "$EXPECTED_SHA256" ]; then
  echo "Missing pinned GhosttyKit checksum for ghostty $GHOSTTY_SHA in $CHECKSUMS_FILE" >&2
  _fallback_source_build
  exit 0
fi

echo "Downloading $ARCHIVE_NAME for ghostty $GHOSTTY_SHA"
if ! curl --fail --show-error --location \
  --retry "$DOWNLOAD_RETRIES" \
  --retry-delay "$DOWNLOAD_RETRY_DELAY" \
  --retry-all-errors \
  -o "$ARCHIVE_NAME" \
  "$DOWNLOAD_URL"; then
  echo "curl download failed for $DOWNLOAD_URL" >&2
  _fallback_source_build
  exit 0
fi

ACTUAL_SHA256="$(shasum -a 256 "$ARCHIVE_NAME" | awk '{print $1}')"
if [ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]; then
  echo "$ARCHIVE_NAME checksum mismatch" >&2
  echo "Expected: $EXPECTED_SHA256" >&2
  echo "Actual:   $ACTUAL_SHA256" >&2
  rm -f "$ARCHIVE_NAME"
  _fallback_source_build
  exit 0
fi

rm -rf "$OUTPUT_DIR"
tar xzf "$ARCHIVE_NAME"
rm "$ARCHIVE_NAME"
test -d "$OUTPUT_DIR"

echo "Verified and extracted $OUTPUT_DIR"
