#!/usr/bin/env bash
# Installs the zig version Ghostty requires (scripts/required-zig-version.sh) on a
# macOS arm64 machine, for CI and release jobs.
#
# The tarball is checked against the pinned SHA-256 in
# scripts/zig-macos-aarch64.sha256 before it is extracted, every time, including
# when it comes from a CI cache. Unlisted versions fail closed.
#
# Usage: scripts/install-zig.sh [--bin-dir DIR]
#
#   --bin-dir DIR   Directory that receives the `zig` symlink (default /usr/local/bin).
#
# Environment:
#   ZIG_DIST_CACHE_DIR  Where the verified tarball is kept, so CI can cache it
#                       (default ~/.cache/programa-zig-dist).
#   ZIG_INSTALL_ROOT    Where the tarball is extracted
#                       (default ~/.local/share/programa-zig).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
BIN_DIR="/usr/local/bin"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bin-dir)
      BIN_DIR="${2:-}"
      shift 2
      ;;
    -h|--help)
      sed -n '2,17p' "$0"
      exit 0
      ;;
    *)
      echo "install-zig: unknown option: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$BIN_DIR" ]]; then
  echo "install-zig: --bin-dir needs a directory" >&2
  exit 1
fi

ZIG_REQUIRED="$("$SCRIPT_DIR/required-zig-version.sh")"

if command -v zig >/dev/null 2>&1 && [[ "$(zig version 2>/dev/null)" == "$ZIG_REQUIRED" ]]; then
  echo "zig ${ZIG_REQUIRED} already installed at $(command -v zig)"
  exit 0
fi

if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
  echo "install-zig: only macOS arm64 has a pinned checksum (got $(uname -s) $(uname -m))" >&2
  exit 1
fi

EXPECTED_SHA256="$(awk -v v="$ZIG_REQUIRED" '$1 == v { print $2 }' "$SCRIPT_DIR/zig-macos-aarch64.sha256")"
if [[ -z "$EXPECTED_SHA256" ]]; then
  echo "install-zig: no checked-in SHA-256 for zig ${ZIG_REQUIRED}; add it to scripts/zig-macos-aarch64.sha256" >&2
  exit 1
fi

NAME="zig-aarch64-macos-${ZIG_REQUIRED}"
DIST_DIR="${ZIG_DIST_CACHE_DIR:-$HOME/.cache/programa-zig-dist}"
INSTALL_ROOT="${ZIG_INSTALL_ROOT:-$HOME/.local/share/programa-zig}"
TARBALL="$DIST_DIR/$NAME.tar.xz"

sha256_matches() {
  [[ "$(shasum -a 256 "$1" | awk '{ print $1 }')" == "$EXPECTED_SHA256" ]]
}

mkdir -p "$DIST_DIR" "$INSTALL_ROOT"

if [[ -f "$TARBALL" ]] && sha256_matches "$TARBALL"; then
  echo "Using cached zig ${ZIG_REQUIRED} tarball (SHA-256 verified)"
else
  rm -f "$TARBALL"
  PARTIAL="$(mktemp "$DIST_DIR/.${NAME}.XXXXXX")"
  trap 'rm -f "$PARTIAL"' EXIT
  echo "Downloading zig ${ZIG_REQUIRED}"
  curl -fSL --retry 3 --retry-delay 5 \
    "https://ziglang.org/download/${ZIG_REQUIRED}/${NAME}.tar.xz" -o "$PARTIAL"
  if ! sha256_matches "$PARTIAL"; then
    echo "install-zig: SHA-256 mismatch for ${NAME}.tar.xz (expected ${EXPECTED_SHA256})" >&2
    exit 1
  fi
  mv "$PARTIAL" "$TARBALL"
  trap - EXIT
fi

rm -rf "${INSTALL_ROOT:?}/$NAME"
tar -xf "$TARBALL" -C "$INSTALL_ROOT"
ZIG_BIN="$INSTALL_ROOT/$NAME/zig"
if [[ ! -x "$ZIG_BIN" ]]; then
  echo "install-zig: $ZIG_BIN missing after extraction" >&2
  exit 1
fi

# zig resolves its own path through symlinks, so the lib/ next to the real
# binary is found without copying it.
if mkdir -p "$BIN_DIR" 2>/dev/null && [[ -w "$BIN_DIR" ]]; then
  ln -sf "$ZIG_BIN" "$BIN_DIR/zig"
else
  sudo mkdir -p "$BIN_DIR"
  sudo ln -sf "$ZIG_BIN" "$BIN_DIR/zig"
fi

INSTALLED_VERSION="$("$BIN_DIR/zig" version)"
if [[ "$INSTALLED_VERSION" != "$ZIG_REQUIRED" ]]; then
  echo "install-zig: $BIN_DIR/zig reports ${INSTALLED_VERSION}, expected ${ZIG_REQUIRED}" >&2
  exit 1
fi
echo "zig ${INSTALLED_VERSION} installed at $BIN_DIR/zig"
