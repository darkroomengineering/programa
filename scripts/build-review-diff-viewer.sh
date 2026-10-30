#!/usr/bin/env bash
# Builds the Pierre review diff viewer (webviews/review-diff) into the checked-in
# Resources/review-diff-viewer bundle.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT/webviews/review-diff"
bun install --frozen-lockfile
bun run build
