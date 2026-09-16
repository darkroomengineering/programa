#!/usr/bin/env bash
set -euo pipefail

readonly SEAL_NAME="programa-release-candidate.json"
readonly EXPECTED_ASSET_COUNT=6

die() {
  echo "publish_release_candidate: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
usage: publish_release_candidate.sh \
  --candidate-prefix <safe-prefix> \
  --destination-tag <safe-release-tag> \
  --candidate-tag <candidate-prefix><build>[-<three-digit-attempt>] \
  --target-sha <40-lowercase-hex> \
  --build <canonical-positive-decimal> \
  --version <major.minor.build> \
  --seal-output <safe-local-path> \
  [--prepare-only] \
  --asset-role <immutable|appcast|stable-alias>=<path> [--asset-role ...]
EOF
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
    die "neither shasum nor sha256sum is available"
  fi
}

candidate_prefix=""
destination_tag=""
candidate_tag=""
target_sha=""
build=""
version=""
seal_output=""
prepare_only=false
asset_specs=()
seen_candidate_prefix=0
seen_destination_tag=0
seen_candidate_tag=0
seen_target_sha=0
seen_build=0
seen_version=0
seen_seal_output=0

while (($#)); do
  case "$1" in
    --prepare-only)
      [[ "${prepare_only}" == "false" ]] || die "--prepare-only may be supplied only once"
      prepare_only=true
      shift
      ;;
    --candidate-prefix|--destination-tag|--candidate-tag|--target-sha|--build|--version|--seal-output|--asset-role)
      (($# >= 2)) || { usage; die "$1 requires a value"; }
      case "$1" in
        --candidate-prefix)
          ((seen_candidate_prefix == 0)) || die "--candidate-prefix may be supplied only once"
          candidate_prefix="$2"
          seen_candidate_prefix=1
          ;;
        --destination-tag)
          ((seen_destination_tag == 0)) || die "--destination-tag may be supplied only once"
          destination_tag="$2"
          seen_destination_tag=1
          ;;
        --candidate-tag)
          ((seen_candidate_tag == 0)) || die "--candidate-tag may be supplied only once"
          candidate_tag="$2"
          seen_candidate_tag=1
          ;;
        --target-sha)
          ((seen_target_sha == 0)) || die "--target-sha may be supplied only once"
          target_sha="$2"
          seen_target_sha=1
          ;;
        --build)
          ((seen_build == 0)) || die "--build may be supplied only once"
          build="$2"
          seen_build=1
          ;;
        --version)
          ((seen_version == 0)) || die "--version may be supplied only once"
          version="$2"
          seen_version=1
          ;;
        --seal-output)
          ((seen_seal_output == 0)) || die "--seal-output may be supplied only once"
          seal_output="$2"
          seen_seal_output=1
          ;;
        --asset-role) asset_specs+=("$2") ;;
      esac
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage
      die "unknown argument: $1"
      ;;
  esac
done

[[ -n "${GITHUB_REPOSITORY:-}" ]] || die "GITHUB_REPOSITORY is required"
[[ "${GITHUB_REPOSITORY}" =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]] || die "GITHUB_REPOSITORY must be owner/repository"
[[ "${build}" =~ ^[1-9][0-9]*$ ]] || die "build must be a canonical positive decimal string"
[[ "${candidate_prefix}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*-$ ]] || die "candidate prefix must be safe and end with a hyphen"
[[ "${destination_tag}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "destination tag must be safe"
if [[ "${destination_tag}" == "rolling" ]]; then
  [[ "${candidate_prefix}" == "rolling-candidate-" ]] || die "rolling candidates must use rolling-candidate-"
  [[ "${candidate_tag}" == "${candidate_prefix}${build}" ]] || die "rolling candidate tag must be ${candidate_prefix}${build}"
elif [[ "${candidate_prefix}" == "rolling-candidate-" && "${destination_tag}" == "${candidate_prefix}${build}" ]]; then
  # Archive candidates publish to their own permanent build tag instead of
  # the mutable rolling tag or a milestone semver tag.
  [[ "${candidate_tag}" == "${destination_tag}" ]] || \
    die "archive candidate tag must equal its destination tag ${destination_tag}"
else
  [[ "${destination_tag}" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || \
    die "non-rolling destination must be a canonical milestone tag"
  [[ "${version}" == "${destination_tag#v}" ]] || die "milestone version must equal the destination tag semver"
  [[ "${candidate_prefix}" == "milestone-candidate-" ]] || die "milestone candidates must use milestone-candidate-"
  [[ "${candidate_tag}" =~ ^${candidate_prefix}${build}-[0-9]{3}$ ]] || \
    die "milestone candidate tag must be ${candidate_prefix}${build}-<three-digit-attempt>"
fi
[[ "${target_sha}" =~ ^[0-9a-f]{40}$ ]] || die "target SHA must be 40 lowercase hexadecimal characters"
[[ "${version}" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || die "version must be a canonical major.minor.build value"
[[ -n "${seal_output}" ]] || die "--seal-output is required"
[[ "${seal_output}" != *$'\n'* && "${seal_output}" != *$'\r'* && "${seal_output}" != *$'\t'* ]] || \
  die "seal output path contains unsupported control characters"
seal_output_name="${seal_output##*/}"
[[ "${seal_output_name}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && "${seal_output_name}" != "." && "${seal_output_name}" != ".." ]] || \
  die "seal output path must end in a safe filename"
seal_output_parent="${seal_output%/*}"
[[ "${seal_output_parent}" != "${seal_output}" ]] || seal_output_parent="."
[[ -d "${seal_output_parent}" && ! -L "${seal_output_parent}" ]] || die "seal output parent must be a real directory"
[[ ! -L "${seal_output}" && ! -d "${seal_output}" ]] || die "seal output must not be a symlink or directory"
((${#asset_specs[@]} == EXPECTED_ASSET_COUNT)) || die "exactly ${EXPECTED_ASSET_COUNT} payload assets are required"

gh_command="${GH_BIN-gh}"
[[ -n "${gh_command}" ]] || die "GH_BIN must not be empty"
command -v "${gh_command}" >/dev/null 2>&1 || die "GitHub CLI command is unavailable: ${gh_command}"
command -v node >/dev/null 2>&1 || die "node is required"

umask 077
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/programa-release-candidate.XXXXXX")" || die "could not create private temporary directory"
cleanup() {
  rm -rf -- "${temp_dir}"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

roles=()
paths=()
names=()
sizes=()
hashes=()

for spec in "${asset_specs[@]}"; do
  [[ "${spec}" == *=* ]] || die "asset role must use role=path: ${spec}"
  role="${spec%%=*}"
  path="${spec#*=}"
  case "${role}" in
    immutable|appcast|stable-alias) ;;
    *) die "invalid asset role: ${role}" ;;
  esac
  [[ -n "${path}" ]] || die "asset path must not be empty"
  [[ "${path}" != *$'\n'* && "${path}" != *$'\r'* && "${path}" != *$'\t'* ]] || die "asset path contains unsupported control characters"
  [[ -f "${path}" && -r "${path}" ]] || die "asset must be a readable regular file: ${path}"

  name="${path##*/}"
  [[ -n "${name}" && "${name}" != "." && "${name}" != ".." && "${name}" != *'\'* ]] || die "asset name is not a safe basename: ${name}"
  for existing_name in "${names[@]:-}"; do
    [[ "${existing_name}" != "${name}" ]] || die "duplicate asset name: ${name}"
  done

  size="$(file_size "${path}")" || die "could not determine asset size: ${path}"
  [[ "${size}" =~ ^[1-9][0-9]*$ ]] || die "asset must be non-empty: ${path}"
  ((size <= 9007199254740991)) || die "asset size exceeds JavaScript's safe integer range: ${path}"
  hash="$(sha256_file "${path}")" || die "could not hash asset: ${path}"
  [[ "${hash}" =~ ^[0-9a-f]{64}$ ]] || die "hashing tool returned an invalid SHA-256 for ${path}"

  roles+=("${role}")
  paths+=("${path}")
  names+=("${name}")
  sizes+=("${size}")
  hashes+=("${hash}")
done

manifest_input="${temp_dir}/manifest-assets.tsv"
: > "${manifest_input}"
for ((index = 0; index < EXPECTED_ASSET_COUNT; index++)); do
  printf '%s\t%s\t%s\t%s\n' \
    "${names[index]}" "${roles[index]}" "${sizes[index]}" "${hashes[index]}" >> "${manifest_input}"
done

manifest_path="${temp_dir}/${SEAL_NAME}"
state_module="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/rolling_release_state.js"
appcast_path=""
for ((index = 0; index < EXPECTED_ASSET_COUNT; index++)); do
  case "${names[index]}" in
    appcast.xml) appcast_path="${paths[index]}" ;;
  esac
done
[[ -n "${appcast_path}" ]] || die "payload set is missing appcast.xml"

node - \
  "${state_module}" \
  "${manifest_input}" \
  "${manifest_path}" \
  "${target_sha}" \
  "${version}" \
  "${build}" \
  "${appcast_path}" \
  "${GITHUB_REPOSITORY}" \
  "${destination_tag}" <<'NODE'
"use strict";

const fs = require("node:fs");
const [
  stateModulePath,
  inputPath,
  outputPath,
  targetSha,
  version,
  build,
  appcastPath,
  repository,
  destinationTag,
] = process.argv.slice(2);
const { createCandidateManifest, validateReleasePayloadReferences } = require(stateModulePath);

if (typeof createCandidateManifest !== "function") {
  throw new Error("rolling_release_state.js does not export createCandidateManifest");
}
if (typeof validateReleasePayloadReferences !== "function") {
  throw new Error("rolling_release_state.js does not export validateReleasePayloadReferences");
}

const assets = fs.readFileSync(inputPath, "utf8").trimEnd().split("\n").map((line) => {
  const fields = line.split("\t");
  if (fields.length !== 4) throw new Error("invalid manifest asset input");
  const [name, role, size, sha256] = fields;
  return { name, role, size: Number(size), sha256 };
});

const manifest = createCandidateManifest({
  schemaVersion: 2,
  sealed: true,
  targetSha,
  version,
  build,
  assets,
});

validateReleasePayloadReferences({
  appcastXml: fs.readFileSync(appcastPath, "utf8"),
  repository,
  tag: destinationTag,
  manifest,
});

fs.writeFileSync(outputPath, `${JSON.stringify(manifest)}\n`, { mode: 0o600 });
NODE

manifest_size="$(file_size "${manifest_path}")" || die "could not determine candidate seal size"
manifest_hash="$(sha256_file "${manifest_path}")" || die "could not hash candidate seal"

write_seal_output() {
  [[ ! -L "${seal_output}" && ! -d "${seal_output}" ]] || die "seal output became unsafe"
  cp "${manifest_path}" "${seal_output}" || die "could not write local candidate seal"
  chmod 600 "${seal_output}" || die "could not protect local candidate seal"
  cmp -s "${manifest_path}" "${seal_output}" || die "local candidate seal bytes differ"
}

verify_prepared_seal_output() {
  [[ -f "${seal_output}" && ! -L "${seal_output}" ]] || die "prepared candidate seal is unavailable"
  cmp -s "${manifest_path}" "${seal_output}" || die "prepared candidate seal bytes conflict"
}

if [[ "${prepare_only}" == "true" ]]; then
  write_seal_output
  echo "Candidate ${candidate_tag} local seal is prepared."
  exit 0
fi

# A normal invocation consumes an existing prepared seal without rewriting it.
# One-shot callers get the same bytes written before the first candidate mutation.
if [[ -e "${seal_output}" ]]; then
  verify_prepared_seal_output
else
  write_seal_output
fi

expected_title="Candidate ${build}"
expected_body="candidate"

release_value() {
  local field="$1"
  "${gh_command}" release view "${candidate_tag}" --repo "${GITHUB_REPOSITORY}" --json "${field}" --jq ".${field}"
}

verify_release_metadata() {
  local observed
  observed="$(release_value databaseId)" || die "could not read candidate release database ID"
  [[ -n "${observed}" ]] || die "candidate release has no authenticated ID"
  observed="$(release_value tagName)" || die "could not read candidate tag metadata"
  [[ "${observed}" == "${candidate_tag}" ]] || die "candidate release tag does not match"
  observed="$(release_value isDraft)" || die "could not read candidate draft state"
  [[ "${observed}" == "true" ]] || die "candidate release is not a draft"
  observed="$(release_value targetCommitish)" || die "could not read candidate target"
  [[ "${observed}" == "${target_sha}" ]] || die "candidate release target does not match"
  observed="$(release_value name)" || die "could not read candidate title"
  [[ "${observed}" == "${expected_title}" ]] || die "candidate release title does not match"
  observed="$(release_value body)" || die "could not read candidate notes"
  [[ "${observed}" == "${expected_body}" ]] || die "candidate release notes do not match"
}

if release_id="$(release_value databaseId 2>"${temp_dir}/release-view.err")"; then
  [[ -n "${release_id}" ]] || die "candidate release has no authenticated ID"
else
  "${gh_command}" release create "${candidate_tag}" \
    --draft \
    --target "${target_sha}" \
    --title "${expected_title}" \
    --notes "${expected_body}" \
    --repo "${GITHUB_REPOSITORY}"
fi
verify_release_metadata

list_assets() {
  "${gh_command}" release view "${candidate_tag}" \
    --repo "${GITHUB_REPOSITORY}" \
    --json assets \
    --jq '.assets[] | [.id, .name, .state, (.size | tostring), (.digest // "")] | @tsv'
}

is_expected_name() {
  local candidate_name="$1" expected_name
  [[ "${candidate_name}" == "${SEAL_NAME}" ]] && return 0
  for expected_name in "${names[@]}"; do
    [[ "${candidate_name}" != "${expected_name}" ]] || return 0
  done
  return 1
}

refresh_asset_listing() {
  local asset_id asset_name asset_state asset_size asset_digest extra
  list_assets > "${temp_dir}/assets.tsv" || die "could not read candidate assets"
  : > "${temp_dir}/seen-assets"
  while IFS=$'\t' read -r asset_id asset_name asset_state asset_size asset_digest extra; do
    [[ -n "${asset_name}" ]] || continue
    [[ -z "${extra:-}" ]] || die "candidate asset metadata has unexpected fields"
    is_expected_name "${asset_name}" || die "candidate contains unexpected asset: ${asset_name}"
    if grep -Fqx "${asset_name}" "${temp_dir}/seen-assets"; then
      die "candidate contains duplicate asset metadata: ${asset_name}"
    fi
    printf '%s\n' "${asset_name}" >> "${temp_dir}/seen-assets"
  done < "${temp_dir}/assets.tsv"
}

asset_metadata() {
  local wanted="$1" asset_id asset_name asset_state asset_size asset_digest extra matches=0
  while IFS=$'\t' read -r asset_id asset_name asset_state asset_size asset_digest extra; do
    [[ "${asset_name}" == "${wanted}" ]] || continue
    ((matches += 1))
    printf '%s\t%s\t%s\t%s\n' "${asset_id}" "${asset_state}" "${asset_size}" "${asset_digest}"
  done < "${temp_dir}/assets.tsv"
  ((matches <= 1)) || die "candidate contains duplicate asset metadata: ${wanted}"
  ((matches == 1))
}

verify_asset() {
  local name="$1" expected_path="$2" expected_size="$3" expected_hash="$4"
  local metadata asset_id state size digest download_dir downloaded observed_size observed_hash

  refresh_asset_listing
  metadata="$(asset_metadata "${name}")" || die "candidate asset is missing after upload: ${name}"
  IFS=$'\t' read -r asset_id state size digest <<< "${metadata}"
  [[ -n "${asset_id}" ]] || die "candidate asset has no authenticated ID: ${name}"
  [[ "${state}" == "uploaded" ]] || die "candidate asset is not uploaded: ${name}"
  [[ "${size}" == "${expected_size}" ]] || die "candidate asset size conflicts: ${name}"
  if [[ -n "${digest}" ]]; then
    [[ "${digest}" == "sha256:${expected_hash}" ]] || die "candidate asset digest conflicts: ${name}"
  fi

  verify_release_metadata
  download_dir="$(mktemp -d "${temp_dir}/download.XXXXXX")" || die "could not create asset verification directory"
  "${gh_command}" release download "${candidate_tag}" \
    --pattern "${name}" \
    --dir "${download_dir}" \
    --repo "${GITHUB_REPOSITORY}" || die "could not download candidate asset: ${name}"
  downloaded="${download_dir}/${name}"
  [[ -f "${downloaded}" && -r "${downloaded}" ]] || die "downloaded candidate asset is unavailable: ${name}"
  observed_size="$(file_size "${downloaded}")" || die "could not determine downloaded asset size: ${name}"
  [[ "${observed_size}" == "${expected_size}" ]] || die "downloaded candidate asset size conflicts: ${name}"
  observed_hash="$(sha256_file "${downloaded}")" || die "could not hash downloaded candidate asset: ${name}"
  [[ "${observed_hash}" == "${expected_hash}" ]] || die "downloaded candidate asset bytes conflict: ${name}"
  cmp -s "${downloaded}" "${expected_path}" || die "downloaded candidate asset bytes differ: ${name}"
}

upload_or_verify_payload() {
  local index="$1" metadata
  refresh_asset_listing
  if metadata="$(asset_metadata "${names[index]}")"; then
    verify_asset "${names[index]}" "${paths[index]}" "${sizes[index]}" "${hashes[index]}"
    return
  fi

  verify_release_metadata
  "${gh_command}" release upload "${candidate_tag}" "${paths[index]}" --repo "${GITHUB_REPOSITORY}" || \
    die "could not upload candidate asset: ${names[index]}"
  verify_asset "${names[index]}" "${paths[index]}" "${sizes[index]}" "${hashes[index]}"
}

upload_payload_named() {
  local wanted="$1" index
  for ((index = 0; index < EXPECTED_ASSET_COUNT; index++)); do
    if [[ "${names[index]}" == "${wanted}" ]]; then
      upload_or_verify_payload "${index}"
      return
    fi
  done
  die "validated manifest is missing payload: ${wanted}"
}

refresh_asset_listing
if asset_metadata "${SEAL_NAME}" >/dev/null; then
  verify_asset "${SEAL_NAME}" "${manifest_path}" "${manifest_size}" "${manifest_hash}"
  for ((index = 0; index < EXPECTED_ASSET_COUNT; index++)); do
    verify_asset "${names[index]}" "${paths[index]}" "${sizes[index]}" "${hashes[index]}"
  done
  verify_release_metadata
  verify_prepared_seal_output
  echo "Candidate ${candidate_tag} is already sealed and verified."
  exit 0
fi

# Reject every conflicting existing payload before adding anything to a partial draft.
for ((index = 0; index < EXPECTED_ASSET_COUNT; index++)); do
  refresh_asset_listing
  if asset_metadata "${names[index]}" >/dev/null; then
    verify_asset "${names[index]}" "${paths[index]}" "${sizes[index]}" "${hashes[index]}"
  fi
done

# Keep retry progress deterministic. Runtime payloads precede symbols and aliases.
upload_payload_named "programa-macos-${build}.dmg"
upload_payload_named "programa-dSYMs-${build}.zip"
upload_payload_named "programa-windows-${build}.exe"
upload_payload_named "appcast.xml"
upload_payload_named "programa-macos.dmg"
upload_payload_named "programa-windows.exe"

verify_release_metadata
refresh_asset_listing
if asset_metadata "${SEAL_NAME}" >/dev/null; then
  die "candidate seal appeared unexpectedly"
fi

# Upload from the temp copy: gh names the asset after the local file, and the
# --seal-output path is caller-chosen. The bytes were verified identical above.
"${gh_command}" release upload "${candidate_tag}" "${manifest_path}" --repo "${GITHUB_REPOSITORY}" || \
  die "could not upload candidate seal"
verify_asset "${SEAL_NAME}" "${manifest_path}" "${manifest_size}" "${manifest_hash}"

refresh_asset_listing
asset_total="$(wc -l < "${temp_dir}/seen-assets" | tr -d '[:space:]')"
((asset_total == EXPECTED_ASSET_COUNT + 1)) || die "sealed candidate does not contain the exact payload set"
verify_release_metadata
echo "Candidate ${candidate_tag} is sealed and verified."
