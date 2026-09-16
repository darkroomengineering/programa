#!/usr/bin/env bash
set -euo pipefail

umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAYLOAD_MODULE="${SCRIPT_DIR}/milestone_payload.js"
GH_COMMAND="${GH_BIN:-gh}"
REPOSITORY="${GITHUB_REPOSITORY:-}"
TAG=""
TARGET_SHA=""
BUILD=""
PAYLOAD_DIR=""
TEMP_DIR=""

fail() {
  echo "publish_milestone_release.sh: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage: publish_milestone_release.sh \
  --tag <vMAJOR.MINOR.PATCH> \
  --target-sha <40-lowercase-hex> \
  --build <canonical-positive-decimal> \
  --payload-dir <directory>
EOF
}

cleanup() {
  local status=$?
  trap - EXIT INT TERM
  if [[ -n "${TEMP_DIR}" && -d "${TEMP_DIR}" ]]; then
    rm -rf "${TEMP_DIR}"
  fi
  exit "${status}"
}

file_size() {
  stat -c '%s' "$1" 2>/dev/null || stat -f '%z' "$1"
}

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    fail "neither shasum nor sha256sum is available"
  fi
}

while (($#)); do
  case "$1" in
    --tag|--target-sha|--build|--payload-dir)
      (($# >= 2)) || { usage; fail "$1 requires a value"; }
      case "$1" in
        --tag) [[ -z "${TAG}" ]] || fail "--tag may be supplied only once"; TAG="$2" ;;
        --target-sha) [[ -z "${TARGET_SHA}" ]] || fail "--target-sha may be supplied only once"; TARGET_SHA="$2" ;;
        --build) [[ -z "${BUILD}" ]] || fail "--build may be supplied only once"; BUILD="$2" ;;
        --payload-dir) [[ -z "${PAYLOAD_DIR}" ]] || fail "--payload-dir may be supplied only once"; PAYLOAD_DIR="$2" ;;
      esac
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      fail "unknown argument: $1"
      ;;
  esac
done

[[ "${REPOSITORY}" =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]] || \
  fail "GITHUB_REPOSITORY must be owner/repository"
[[ "${TAG}" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || \
  fail "--tag must be canonical vMAJOR.MINOR.PATCH"
[[ "${TARGET_SHA}" =~ ^[0-9a-f]{40}$ ]] || \
  fail "--target-sha must be 40 lowercase hexadecimal characters"
[[ "${BUILD}" =~ ^[1-9][0-9]*$ ]] || \
  fail "--build must be a canonical positive decimal string"
[[ -n "${PAYLOAD_DIR}" ]] || fail "--payload-dir is required"
[[ -r "${PAYLOAD_MODULE}" ]] || fail "missing milestone payload module"
GH_COMMAND="$(command -v "${GH_COMMAND}")" || fail "GitHub CLI command is unavailable"
command -v node >/dev/null 2>&1 || fail "node is required"

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/programa-milestone-release.XXXXXX")"
trap cleanup EXIT INT TERM

# Verify the complete local handoff before even reading remote release state.
EXPECTED_TSV="${TEMP_DIR}/expected.tsv"
node - "${PAYLOAD_MODULE}" "${PAYLOAD_DIR}" "${BUILD}" "${REPOSITORY}" "${TAG}" > "${EXPECTED_TSV}" <<'NODE'
"use strict";
const [modulePath, directory, build, repository, tag] = process.argv.slice(2);
const { validateMilestonePayloadReferences, verifyMilestonePayload } = require(modulePath);
validateMilestonePayloadReferences({ directory, build, repository, tag, version: tag.slice(1) });
for (const file of verifyMilestonePayload({ directory, build }).files) {
  process.stdout.write(`${file.name}\t${file.size}\t${file.sha256}\n`);
}
NODE

declare -A EXPECTED_SIZE=()
declare -A EXPECTED_SHA=()
while IFS=$'\t' read -r name size sha extra; do
  [[ -n "${name}" && -z "${extra:-}" ]] || fail "local milestone manifest produced invalid metadata"
  EXPECTED_SIZE["${name}"]="${size}"
  EXPECTED_SHA["${name}"]="${sha}"
done < "${EXPECTED_TSV}"

SAFE_ORDER=(
  "programa-macos-${BUILD}.dmg"
  "programa-dSYMs-${BUILD}.zip"
  "programa-windows-${BUILD}.exe"
  "appcast.xml"
  "programa-macos.dmg"
  "programa-windows.exe"
)
for name in "${SAFE_ORDER[@]}"; do
  [[ -n "${EXPECTED_SIZE[${name}]+x}" && -n "${EXPECTED_SHA[${name}]+x}" ]] || \
    fail "local milestone manifest is missing ${name}"
done
[[ "${#EXPECTED_SIZE[@]}" -eq 6 ]] || fail "local milestone manifest must describe exactly six assets"

require_live_tag_target() {
  local live_target
  live_target="$("${GH_COMMAND}" api \
    "repos/${REPOSITORY}/git/ref/tags/${TAG}" \
    --jq .object.sha)" || fail "could not read live tag ref ${TAG}"
  [[ "${live_target}" =~ ^[0-9a-f]{40}$ ]] || fail "live tag ref ${TAG} is not a commit SHA"
  [[ "${live_target}" == "${TARGET_SHA}" ]] || \
    fail "live tag ref ${TAG} targets ${live_target}, expected ${TARGET_SHA}"
}

validate_local_payload_references() {
  node - "${PAYLOAD_MODULE}" "${PAYLOAD_DIR}" "${BUILD}" "${REPOSITORY}" "${TAG}" <<'NODE'
const [modulePath, directory, build, repository, tag] = process.argv.slice(2);
const { validateMilestonePayloadReferences } = require(modulePath);
validateMilestonePayloadReferences({ directory, build, repository, tag, version: tag.slice(1) });
NODE
}

release_value() {
  local field="$1"
  "${GH_COMMAND}" release view "${TAG}" \
    --repo "${REPOSITORY}" \
    --json "${field}" \
    --jq ".${field}"
}

query_assets() {
  local destination="$1"
  "${GH_COMMAND}" release view "${TAG}" \
    --repo "${REPOSITORY}" \
    --json assets \
    --jq '.assets[] | [.id, .name, .state, (.size | tostring), (.digest // "-")] | @tsv' \
    > "${destination}"
}

verify_release_metadata() {
  local expected_draft="$1" expected_latest="$2" expected_immutable="$3"
  local observed state_row state_tag state_draft state_latest
  state_row="$(release_state_row)" || fail "milestone release state is missing or ambiguous"
  IFS=$'\t' read -r state_tag state_draft state_latest <<< "${state_row}"
  [[ "${state_tag}" == "${TAG}" ]] || fail "release state resolved to an unexpected tag"
  [[ "${state_draft}" == "${expected_draft}" ]] || fail "release draft state is inconsistent"
  if [[ "${expected_latest}" != "any" ]]; then
    [[ "${state_latest}" == "${expected_latest}" ]] || fail "release latest state is inconsistent"
  fi
  observed="$(release_value isImmutable)" || fail "could not read release immutable state"
  [[ "${observed}" == "${expected_immutable}" ]] || fail "release immutable state is inconsistent"
  observed="$(release_value name)" || fail "could not read release title"
  [[ "${observed}" == "${TAG}" ]] || fail "release title must equal ${TAG}"
  observed="$(release_value body)" || fail "could not read release notes"
  [[ -n "${observed}" ]] || fail "release notes must be nonempty"
}

release_state_row() {
  local states_file="${TEMP_DIR}/release-states.tsv"
  "${GH_COMMAND}" release list \
    --repo "${REPOSITORY}" \
    --limit 1000 \
    --json tagName,isDraft,isLatest \
    --jq '.[] | [.tagName, .isDraft, .isLatest] | @tsv' > "${states_file}" || \
    fail "could not list milestone releases"
  awk -F '\t' -v expected="${TAG}" '
    $1 == expected { row = $0; matches += 1 }
    END {
      if (matches == 1) print row
      else if (matches > 1) exit 2
      else exit 1
    }
  ' "${states_file}"
}

verify_downloaded_asset() {
  local name="$1" destination="$2" observed_size observed_sha
  rm -f "${destination}/${name}"
  "${GH_COMMAND}" release download "${TAG}" \
    --repo "${REPOSITORY}" \
    --pattern "${name}" \
    --dir "${destination}" || fail "could not download ${TAG}/${name}"
  [[ -f "${destination}/${name}" ]] || fail "authenticated download omitted ${TAG}/${name}"
  observed_size="$(file_size "${destination}/${name}")"
  observed_sha="$(sha256_file "${destination}/${name}")"
  [[ "${observed_size}" == "${EXPECTED_SIZE[${name}]}" ]] || \
    fail "release asset ${name} has unexpected size"
  [[ "${observed_sha}" == "${EXPECTED_SHA[${name}]}" ]] || \
    fail "release asset ${name} has unexpected bytes"
}

declare -A PRESENT=()
inspect_remote_assets() {
  local metadata_file="$1" download_dir="$2" require_complete="${3:-false}"
  local asset_id name state size digest extra
  PRESENT=()
  query_assets "${metadata_file}"
  while IFS=$'\t' read -r asset_id name state size digest extra; do
    [[ -n "${name}" ]] || continue
    [[ -z "${extra:-}" ]] || fail "release asset metadata has unexpected fields"
    [[ -n "${EXPECTED_SIZE[${name}]+x}" ]] || fail "release contains unexpected asset ${name}"
    [[ -z "${PRESENT[${name}]+x}" ]] || fail "release contains duplicate asset metadata for ${name}"
    PRESENT["${name}"]=1
    [[ -n "${asset_id}" && "${state}" == "uploaded" ]] || \
      fail "release asset ${name} is not completely uploaded"
    [[ "${size}" == "${EXPECTED_SIZE[${name}]}" ]] || fail "release asset ${name} has conflicting size"
    if [[ -n "${digest:-}" && "${digest}" != "-" && "${digest}" != "null" ]]; then
      [[ "${digest}" == "sha256:${EXPECTED_SHA[${name}]}" ]] || \
        fail "release asset ${name} has conflicting digest"
    fi
  done < "${metadata_file}"

  if [[ "${require_complete}" == "true" && "${#PRESENT[@]}" -ne 6 ]]; then
    fail "published milestone release has a partial asset set"
  fi

  mkdir -p "${download_dir}"
  for name in "${SAFE_ORDER[@]}"; do
    [[ -n "${PRESENT[${name}]+x}" ]] || continue
    verify_downloaded_asset "${name}" "${download_dir}"
  done
}

RELEASE_EXISTS=false
# The live immutable ref is authoritative for every path, including an
# otherwise-idempotent retry of an already-published release.
require_live_tag_target
if INITIAL_STATE="$(release_state_row)"; then
  RELEASE_EXISTS=true
else
  state_status=$?
  [[ "${state_status}" -eq 1 ]] || fail "milestone release state is ambiguous"
fi

if [[ "${RELEASE_EXISTS}" != "true" ]]; then
  validate_local_payload_references
  "${GH_COMMAND}" release create "${TAG}" \
    --repo "${REPOSITORY}" \
    --draft \
    --target "${TARGET_SHA}" \
    --title "${TAG}" \
    --generate-notes
fi

CURRENT_STATE="$(release_state_row)" || fail "created milestone release state is missing or ambiguous"
IFS=$'\t' read -r current_tag IS_DRAFT IS_LATEST <<< "${CURRENT_STATE}"
[[ "${current_tag}" == "${TAG}" ]] || fail "release state resolved to an unexpected tag"
if [[ "${IS_DRAFT}" == "true" ]]; then
  [[ "${IS_LATEST}" == "false" ]] || fail "draft milestone release must not be latest"
  verify_release_metadata true false false
elif [[ "${IS_DRAFT}" == "false" ]]; then
  verify_release_metadata false any true
else
  fail "release draft state is invalid"
fi

REQUIRE_COMPLETE=false
if [[ "${IS_DRAFT}" == "false" ]]; then
  REQUIRE_COMPLETE=true
fi
inspect_remote_assets \
  "${TEMP_DIR}/existing-assets.tsv" \
  "${TEMP_DIR}/existing-downloads" \
  "${REQUIRE_COMPLETE}"

if [[ "${IS_DRAFT}" == "false" ]]; then
  echo "Milestone release ${TAG} is already published and verified."
  exit 0
fi

# Every existing draft byte is authenticated above. Only absent assets may now be added.
require_live_tag_target
validate_local_payload_references
for name in "${SAFE_ORDER[@]}"; do
  [[ -z "${PRESENT[${name}]+x}" ]] || continue
  "${GH_COMMAND}" release upload "${TAG}" "${PAYLOAD_DIR}/${name}" --repo "${REPOSITORY}"
done

inspect_remote_assets "${TEMP_DIR}/converged-assets.tsv" "${TEMP_DIR}/converged-downloads"
[[ "${#PRESENT[@]}" -eq 6 ]] || fail "draft milestone release did not converge to six assets"

# The immutable tag is checked again after uploads and immediately before publication.
require_live_tag_target
validate_local_payload_references
EXPECTED_PUBLISHED_BODY="${TEMP_DIR}/expected-published-body.md"
"${GH_COMMAND}" release view "${TAG}" --repo "${REPOSITORY}" --json body --jq .body > "${EXPECTED_PUBLISHED_BODY}" || \
  fail "could not snapshot milestone release notes before publication"
[[ -s "${EXPECTED_PUBLISHED_BODY}" ]] || fail "milestone release notes must be nonempty before publication"
"${GH_COMMAND}" release edit "${TAG}" \
  --repo "${REPOSITORY}" \
  --title "${TAG}" \
  --draft=false \
  --latest
verify_release_metadata false true true
FINAL_PUBLISHED_BODY="${TEMP_DIR}/final-published-body.md"
"${GH_COMMAND}" release view "${TAG}" --repo "${REPOSITORY}" --json body --jq .body > "${FINAL_PUBLISHED_BODY}" || \
  fail "could not verify milestone release notes after publication"
cmp -s "${EXPECTED_PUBLISHED_BODY}" "${FINAL_PUBLISHED_BODY}" || fail "milestone release notes changed during publication"
inspect_remote_assets \
  "${TEMP_DIR}/final-assets.tsv" \
  "${TEMP_DIR}/final-downloads" \
  true
echo "Milestone release ${TAG} is published and verified."
