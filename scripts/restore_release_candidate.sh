#!/usr/bin/env bash
set -euo pipefail

umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_MODULE="${SCRIPT_DIR}/rolling_release_state.js"
MILESTONE_MODULE="${SCRIPT_DIR}/milestone_payload.js"
SEAL_NAME="programa-release-candidate.json"
GH_COMMAND="${GH_BIN:-gh}"
REPOSITORY="${GITHUB_REPOSITORY:-}"
CANDIDATE_PREFIX=""
DESTINATION_TAG=""
TARGET_SHA=""
BUILD=""
VERSION=""
OUTPUT_DIR=""
TEMP_DIR=""

fail() {
  echo "restore_release_candidate.sh: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage: restore_release_candidate.sh \
  --candidate-prefix milestone-candidate- \
  --destination-tag vMAJOR.MINOR.PATCH \
  --target-sha <40-lowercase-hex> \
  --build <canonical-positive-decimal> \
  --version <MAJOR.MINOR.PATCH> \
  --output-dir <existing-empty-directory>
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
    --candidate-prefix|--destination-tag|--target-sha|--build|--version|--output-dir)
      (($# >= 2)) || { usage; fail "$1 requires a value"; }
      case "$1" in
        --candidate-prefix) [[ -z "${CANDIDATE_PREFIX}" ]] || fail "--candidate-prefix may be supplied only once"; CANDIDATE_PREFIX="$2" ;;
        --destination-tag) [[ -z "${DESTINATION_TAG}" ]] || fail "--destination-tag may be supplied only once"; DESTINATION_TAG="$2" ;;
        --target-sha) [[ -z "${TARGET_SHA}" ]] || fail "--target-sha may be supplied only once"; TARGET_SHA="$2" ;;
        --build) [[ -z "${BUILD}" ]] || fail "--build may be supplied only once"; BUILD="$2" ;;
        --version) [[ -z "${VERSION}" ]] || fail "--version may be supplied only once"; VERSION="$2" ;;
        --output-dir) [[ -z "${OUTPUT_DIR}" ]] || fail "--output-dir may be supplied only once"; OUTPUT_DIR="$2" ;;
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

[[ "${REPOSITORY}" =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]] || fail "GITHUB_REPOSITORY must be owner/repository"
[[ "${CANDIDATE_PREFIX}" == "milestone-candidate-" ]] || fail "milestone restore requires milestone-candidate-"
[[ "${DESTINATION_TAG}" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || fail "destination tag must be canonical vMAJOR.MINOR.PATCH"
[[ "${VERSION}" == "${DESTINATION_TAG#v}" ]] || fail "version must equal the destination tag semver"
[[ "${TARGET_SHA}" =~ ^[0-9a-f]{40}$ ]] || fail "target SHA must be 40 lowercase hexadecimal characters"
[[ "${BUILD}" =~ ^[1-9][0-9]*$ ]] || fail "build must be a canonical positive decimal string"
[[ -d "${OUTPUT_DIR}" && ! -L "${OUTPUT_DIR}" ]] || fail "output path must be a real directory"
[[ -z "$(find "${OUTPUT_DIR}" -mindepth 1 -maxdepth 1 -print -quit)" ]] || fail "output directory must be empty"
[[ -r "${STATE_MODULE}" && -r "${MILESTONE_MODULE}" ]] || fail "release validation modules are unavailable"
GH_COMMAND="$(command -v "${GH_COMMAND}")" || fail "GitHub CLI command is unavailable"
command -v node >/dev/null 2>&1 || fail "node is required"

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/programa-restore-candidate.XXXXXX")"
trap cleanup EXIT INT TERM
RELEASES_TSV="${TEMP_DIR}/releases.tsv"
"${GH_COMMAND}" api --paginate \
  "repos/${REPOSITORY}/releases?per_page=100" \
  --jq '.[] | [.tag_name, .draft] | @tsv' > "${RELEASES_TSV}"

release_value() {
  local tag="$1" field="$2"
  "${GH_COMMAND}" release view "${tag}" --repo "${REPOSITORY}" --json "${field}" --jq ".${field}"
}

query_assets() {
  local tag="$1" output="$2"
  "${GH_COMMAND}" release view "${tag}" \
    --repo "${REPOSITORY}" \
    --json assets \
    --jq '.assets[] | [.id, .name, .state, (.size | tostring), (.digest // "-")] | @tsv' > "${output}"
}

asset_metadata_line() {
  local wanted="$1" metadata="$2"
  awk -F '\t' -v expected="${wanted}" '
    $2 == expected { print; matches += 1 }
    END { if (matches > 1) exit 2 }
  ' "${metadata}"
}

verify_asset() {
  local tag="$1" name="$2" expected_size="$3" expected_sha="$4" metadata="$5" destination="$6"
  local line asset_id stored_name state size digest extra observed_size observed_sha
  line="$(asset_metadata_line "${name}" "${metadata}")" || fail "candidate ${tag} has duplicate asset metadata for ${name}"
  [[ -n "${line}" ]] || fail "sealed candidate ${tag} is missing ${name}"
  IFS=$'\t' read -r asset_id stored_name state size digest extra <<< "${line}"
  [[ -z "${extra:-}" && -n "${asset_id}" && "${stored_name}" == "${name}" ]] || fail "candidate ${tag}/${name} has malformed metadata"
  [[ "${state}" == "uploaded" && "${size}" =~ ^[1-9][0-9]*$ ]] || fail "candidate ${tag}/${name} is not completely uploaded"
  if [[ -n "${expected_size}" ]]; then
    [[ "${size}" == "${expected_size}" ]] || fail "candidate ${tag}/${name} has conflicting size"
  fi
  if [[ -n "${digest}" && "${digest}" != "-" && "${digest}" != "null" ]]; then
    [[ "${digest}" =~ ^sha256:[0-9a-f]{64}$ ]] || fail "candidate ${tag}/${name} has malformed digest metadata"
    if [[ -n "${expected_sha}" ]]; then
      [[ "${digest}" == "sha256:${expected_sha}" ]] || fail "candidate ${tag}/${name} has conflicting digest"
    fi
  fi
  mkdir -p "${destination}"
  rm -f "${destination}/${name}"
  "${GH_COMMAND}" release download "${tag}" --repo "${REPOSITORY}" --pattern "${name}" --dir "${destination}" || \
    fail "could not download candidate ${tag}/${name}"
  [[ -f "${destination}/${name}" && ! -L "${destination}/${name}" ]] || fail "candidate download omitted ${tag}/${name}"
  observed_size="$(file_size "${destination}/${name}")"
  observed_sha="$(sha256_file "${destination}/${name}")"
  [[ "${observed_size}" == "${size}" ]] || fail "downloaded candidate ${tag}/${name} disagrees with remote size"
  if [[ -n "${digest}" && "${digest}" != "-" && "${digest}" != "null" ]]; then
    [[ "${digest}" == "sha256:${observed_sha}" ]] || fail "downloaded candidate ${tag}/${name} disagrees with remote digest"
  fi
  if [[ -n "${expected_size}" ]]; then
    [[ "${observed_size}" == "${expected_size}" && "${observed_sha}" == "${expected_sha}" ]] || \
      fail "downloaded candidate ${tag}/${name} disagrees with its seal"
  fi
}

attest_file() {
  local file="$1"
  "${GH_COMMAND}" attestation verify "${file}" \
    --repo "${REPOSITORY}" \
    --signer-workflow "${REPOSITORY}/.github/workflows/release.yml" \
    --source-ref "refs/tags/${DESTINATION_TAG}" \
    --source-digest "${TARGET_SHA}" \
    --deny-self-hosted-runners
}

SEALED_COUNT=0
SELECTED_PAYLOAD=""
while IFS=$'\t' read -r tag is_draft _is_latest; do
  [[ "${tag}" =~ ^${CANDIDATE_PREFIX}${BUILD}-[0-9]{3}$ ]] || continue
  [[ "${is_draft}" == "true" ]] || fail "milestone candidate ${tag} must remain a draft"
  candidate_dir="${TEMP_DIR}/candidate-${tag##*-}"
  metadata="${candidate_dir}/assets.tsv"
  seal_dir="${candidate_dir}/seal"
  payload_dir="${candidate_dir}/payload"
  mkdir -p "${candidate_dir}"
  query_assets "${tag}" "${metadata}"
  seal_line="$(asset_metadata_line "${SEAL_NAME}" "${metadata}")" || fail "candidate ${tag} has duplicate seal assets"
  [[ -n "${seal_line}" ]] || continue

  SEALED_COUNT=$((SEALED_COUNT + 1))
  verify_asset "${tag}" "${SEAL_NAME}" "" "" "${metadata}" "${seal_dir}"
  normalized="${candidate_dir}/manifest.json"
  node - "${STATE_MODULE}" "${seal_dir}/${SEAL_NAME}" "${TARGET_SHA}" "${VERSION}" "${BUILD}" > "${normalized}" <<'NODE'
"use strict";
const fs = require("node:fs");
const [modulePath, sealPath, targetSha, version, build] = process.argv.slice(2);
const { validateCandidateManifest } = require(modulePath);
const manifest = validateCandidateManifest(JSON.parse(fs.readFileSync(sealPath, "utf8")));
if (!manifest.sealed) throw new TypeError("candidate seal must declare sealed: true");
if (manifest.schemaVersion !== 2) {
  throw new TypeError("milestone candidate must use the current schema version 2");
}
if (manifest.targetSha !== targetSha || manifest.version !== version || manifest.build !== build) {
  throw new TypeError("candidate seal identity does not match the requested milestone");
}
process.stdout.write(`${JSON.stringify(manifest)}\n`);
NODE

  [[ "$(release_value "${tag}" tagName)" == "${tag}" ]] || fail "candidate ${tag} tag metadata conflicts"
  [[ "$(release_value "${tag}" isDraft)" == "true" ]] || fail "candidate ${tag} is not a draft"
  [[ "$(release_value "${tag}" isImmutable)" == "false" ]] || fail "candidate ${tag} draft unexpectedly reports immutable"
  [[ "$(release_value "${tag}" targetCommitish)" == "${TARGET_SHA}" ]] || fail "candidate ${tag} target conflicts"
  [[ "$(release_value "${tag}" name)" == "Candidate ${BUILD}" ]] || fail "candidate ${tag} title conflicts"
  [[ "$(release_value "${tag}" body)" == "candidate" ]] || fail "candidate ${tag} notes conflict"

  expected_tsv="${candidate_dir}/expected.tsv"
  node - "${normalized}" > "${expected_tsv}" <<'NODE'
const manifest = require(process.argv[2]);
for (const asset of manifest.assets) {
  process.stdout.write(`${asset.name}\t${asset.size}\t${asset.sha256}\n`);
}
NODE
  cut -f2 "${metadata}" | LC_ALL=C sort > "${candidate_dir}/actual-names"
  { cut -f1 "${expected_tsv}"; printf '%s\n' "${SEAL_NAME}"; } | LC_ALL=C sort > "${candidate_dir}/expected-names"
  cmp -s "${candidate_dir}/actual-names" "${candidate_dir}/expected-names" || fail "sealed candidate ${tag} does not contain the exact payload set plus seal"

  while IFS=$'\t' read -r name size sha extra; do
    [[ -n "${name}" && -z "${extra:-}" ]] || fail "candidate ${tag} seal produced malformed asset metadata"
    verify_asset "${tag}" "${name}" "${size}" "${sha}" "${metadata}" "${payload_dir}"
  done < "${expected_tsv}"

  node - "${STATE_MODULE}" "${normalized}" "${payload_dir}/appcast.xml" \
    "${REPOSITORY}" "${DESTINATION_TAG}" <<'NODE'
const fs = require("node:fs");
const [modulePath, manifestPath, appcastPath, repository, tag] = process.argv.slice(2);
const { validateReleasePayloadReferences } = require(modulePath);
validateReleasePayloadReferences({
  appcastXml: fs.readFileSync(appcastPath, "utf8"),
  repository,
  tag,
  manifest: require(manifestPath),
});
NODE

  attest_file "${seal_dir}/${SEAL_NAME}"
  while IFS=$'\t' read -r name _size _sha _extra; do
    attest_file "${payload_dir}/${name}"
  done < "${expected_tsv}"
  SELECTED_PAYLOAD="${payload_dir}"
done < "${RELEASES_TSV}"

if ((SEALED_COUNT == 0)); then
  echo "restore_release_candidate.sh: no sealed milestone candidate exists for build ${BUILD}" >&2
  exit 3
fi
((SEALED_COUNT == 1)) || fail "duplicate sealed milestone candidate identities exist for build ${BUILD}"
[[ -n "${SELECTED_PAYLOAD}" ]] || fail "sealed milestone candidate was not selected"

while IFS= read -r name; do
  cp "${SELECTED_PAYLOAD}/${name}" "${OUTPUT_DIR}/${name}"
done < <(find "${SELECTED_PAYLOAD}" -mindepth 1 -maxdepth 1 -type f -exec basename {} \; | LC_ALL=C sort)
node - "${MILESTONE_MODULE}" "${OUTPUT_DIR}" "${BUILD}" <<'NODE'
const [modulePath, directory, build] = process.argv.slice(2);
const { verifyMilestonePayload, writeMilestoneManifest } = require(modulePath);
writeMilestoneManifest({ directory, build });
verifyMilestonePayload({ directory, build });
NODE

echo "Restored sealed milestone candidate for ${DESTINATION_TAG} build ${BUILD}."
