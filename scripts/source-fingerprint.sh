#!/usr/bin/env bash
# Prints a short hash of the sources that go into the macOS app bundle, including
# uncommitted and untracked changes. The app build stores it in Info.plist as
# ProgramaSourceFingerprint, and tests_v2/programa_client.py compares it against the
# checkout to refuse driving a stale build. Both sides must call this script so the
# hashes agree. Read-only: it never writes to the index or the object store.
set -euo pipefail

ROOT="${1:-$(git -C "$(dirname "$0")/.." rev-parse --show-toplevel)}"

# Test and doc edits must not mark a running build stale, so only app inputs count.
PATHS=(
  Sources CLI CLI-MCP vendor Resources ghostty GhosttyTabs.xcodeproj
  ghostty.h programa-Bridging-Header.h programa.entitlements
  session_escrow_shim.c session_escrow_shim.h
)

{
  git -C "$ROOT" ls-tree -r HEAD -- "${PATHS[@]}"
  git -C "$ROOT" diff HEAD --binary --no-ext-diff --no-color --ignore-submodules=untracked -- "${PATHS[@]}"
  git -C "$ROOT" ls-files --others --exclude-standard -z -- "${PATHS[@]}" \
    | (cd "$ROOT" && xargs -0 shasum -a 256 /dev/null)
} | shasum -a 256 | cut -c1-12
