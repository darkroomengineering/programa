#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CLASSIFIER="${REPO_ROOT}/scripts/classify_ci_changes.sh"

if [[ ! -f "${CLASSIFIER}" ]]; then
  echo "FAIL: missing CI change classifier at scripts/classify_ci_changes.sh" >&2
  exit 1
fi

run_case() {
  local name="$1"
  local expected_app="$2"
  local changed_paths="$3"
  local output
  local expected

  if ! output="$(printf '%s' "${changed_paths}" | bash "${CLASSIFIER}")"; then
    echo "FAIL: ${name}: classifier exited non-zero" >&2
    exit 1
  fi

  printf -v expected 'run_app_jobs=%s' "${expected_app}"

  if [[ "${output}" != "${expected}" ]]; then
    echo "FAIL: ${name}: unexpected classifier output" >&2
    printf 'expected:\n%s\n' "${expected}" >&2
    printf 'actual:\n%s\n' "${output}" >&2
    exit 1
  fi
}

run_case \
  "app path only" \
  true \
  $'Sources/TerminalController.swift\n'

run_case \
  "app icon asset" \
  true \
  $'Assets.xcassets/AppIcon.appiconset/icon.png\n'

run_case \
  "non-localization bundled image" \
  true \
  $'Resources/ghostty/themes/preview.png\n'

run_case \
  "documentation, other workflows and legacy strings only" \
  false \
  $'docs/socket-control.md\nREADME.md\n.github/workflows/release.yml\n.github/pull_request_template.md\nResources/ja.lproj/Localizable.strings\n'

run_case \
  "string catalog compiles into the app" \
  true \
  $'docs/socket-control.md\nResources/Localizable.xcstrings\n'

run_case \
  "main CI workflow runs the jobs it edits" \
  true \
  $'README.md\n.github/workflows/ci.yml\n'

run_case \
  "empty changed path set" \
  true \
  ""

echo "CI change classification behavior: PASS"
