#!/usr/bin/env bash
# Prints a short hash of the sources that go into the macOS app bundle, as they are on
# disk: committing or staging changes nothing, only file contents do. The app build
# stores it in Info.plist as ProgramaSourceFingerprint, and tests_v2/programa_client.py
# compares it against the checkout to refuse driving a stale build. Both sides must call
# this script so the hashes agree. Read-only: it never writes to the index or objects.
set -euo pipefail
export LC_ALL=C

ROOT="${1:-$(git -C "$(dirname "$0")/.." rev-parse --show-toplevel)}"
cd "$ROOT"

# Test and doc edits must not mark a running build stale, so only app inputs count.
PATHS=(
  Sources CLI CLI-MCP vendor Resources GhosttyTabs.xcodeproj
  ghostty.h programa-Bridging-Header.h programa.entitlements
  session_escrow_shim.c session_escrow_shim.h
)

LIST="$(mktemp)"
trap 'rm -f "$LIST"' EXIT

# Regular files on disk, tracked or untracked. Deleted files and submodule gitlinks
# are directories or missing, so hash-object cannot read them.
git ls-files -co --exclude-standard -- "${PATHS[@]}" | sort -u | while IFS= read -r path; do
  [[ -f "$path" ]] && printf '%s\n' "$path"
done > "$LIST"

{
  paste "$LIST" <(git hash-object --stdin-paths < "$LIST")
  # The ghostty submodule: its checked-out commit (the pin when not initialized)
  # and any changes to its tracked files. An uninitialized submodule is an empty
  # directory inside this repo, where `git -C ghostty` would answer for the parent,
  # so check that ghostty is its own work tree first. A clean checkout of the pin
  # and an uninitialized one must hash the same: CI jobs check out without submodules.
  if [[ "$(git -C ghostty rev-parse --show-toplevel 2>/dev/null)" == "$(git rev-parse --show-toplevel)/ghostty" ]]; then
    git -C ghostty rev-parse HEAD
    git -C ghostty diff HEAD --binary --no-ext-diff --no-color
  else
    git rev-parse HEAD:ghostty
  fi
} | shasum -a 256 | cut -c1-12
