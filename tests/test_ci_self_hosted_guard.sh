#!/usr/bin/env bash
# Regression test: ensures CI jobs use GitHub-hosted runners (macos-15 / macos-14).
# Updated from WarpBuild runner check after migrating off Depot/WarpBuild.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CI_FILE="$ROOT_DIR/.github/workflows/ci.yml"
GHOSTTYKIT_FILE="$ROOT_DIR/.github/workflows/build-ghosttykit.yml"
COMPAT_FILE="$ROOT_DIR/.github/workflows/ci-macos-compat.yml"

check_github_runner() {
  local file="$1" job="$2"
  if ! awk -v job="$job" '
    $0 ~ "^  "job":" { in_job=1; next }
    in_job && /^  [^[:space:]]/ { in_job=0 }
    in_job && /runs-on:.*macos-1[45]/ { saw_runner=1 }
    in_job && /os: macos-1[45]/ { saw_runner=1 }
    END { exit !(saw_runner) }
  ' "$file"; then
    echo "FAIL: $job in $(basename "$file") must use a GitHub-hosted runner (macos-15 or macos-14)"
    exit 1
  fi
  echo "PASS: $job GitHub-hosted runner is present"
}

# ci.yml jobs
check_github_runner "$CI_FILE" "tests"
check_github_runner "$CI_FILE" "tests-build-and-lag"
check_github_runner "$CI_FILE" "ui-regressions"

# build-ghosttykit.yml
check_github_runner "$GHOSTTYKIT_FILE" "build-ghosttykit"

# ci-macos-compat.yml (uses matrix.os with GitHub-hosted runners)
check_github_runner "$COMPAT_FILE" "compat-tests"
