#!/usr/bin/env bash
set -euo pipefail

umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_MODULE="${SCRIPT_DIR}/rolling_release_state.js"
GH_BIN="${GH_BIN:-gh}"
REPOSITORY="${GITHUB_REPOSITORY:-}"
CANDIDATE_PREFIX=""
ROLLING_TAG=""
RECONCILER_TARGET_SHA=""
SEAL_NAME="programa-release-candidate.json"
TEMP_DIR=""

usage() {
  cat >&2 <<'EOF'
Usage: publish_rolling_release.sh \
  --candidate-prefix <prefix> \
  --rolling-tag <tag> \
  --reconciler-target-sha <40-lowercase-hex>
EOF
}

fail() {
  echo "publish_rolling_release.sh: $*" >&2
  exit 1
}

cleanup() {
  local status=$?
  trap - EXIT INT TERM
  if [[ -n "${TEMP_DIR}" && -d "${TEMP_DIR}" ]]; then
    rm -rf "${TEMP_DIR}"
  fi
  exit "${status}"
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

file_size() {
  stat -c '%s' "$1" 2>/dev/null || stat -f '%z' "$1"
}

query_assets() {
  local tag="$1" output="$2"
  "${GH_BIN}" release view "${tag}" \
    --repo "${REPOSITORY}" \
    --json assets \
    --jq '.assets[] | [.id, .name, .state, .size, (.digest // "-")] | @tsv' > "${output}"
}

asset_metadata_line() {
  local name="$1" metadata_file="$2"
  awk -F '\t' -v expected="${name}" '
    $2 == expected { print; matches += 1 }
    END { if (matches > 1) exit 2 }
  ' "${metadata_file}"
}

verify_asset_strict() {
  local tag="$1" name="$2" expected_size="$3" expected_sha="$4"
  local metadata_file="$5" download_dir="$6"
  local line asset_id stored_name state size digest downloaded actual_size actual_sha

  line="$(asset_metadata_line "${name}" "${metadata_file}")" || \
    fail "release ${tag} has duplicate metadata for ${name}"
  [[ -n "${line}" ]] || fail "release ${tag} is missing asset ${name}"
  IFS=$'\t' read -r asset_id stored_name state size digest <<< "${line}"
  [[ -n "${asset_id}" && "${stored_name}" == "${name}" ]] || \
    fail "release ${tag} has malformed metadata for ${name}"
  [[ "${state}" == "uploaded" ]] || fail "release ${tag} asset ${name} is not uploaded"

  mkdir -p "${download_dir}"
  downloaded="${download_dir}/${name}"
  rm -f "${downloaded}"
  "${GH_BIN}" release download "${tag}" \
    --repo "${REPOSITORY}" \
    --pattern "${name}" \
    --dir "${download_dir}"
  [[ -f "${downloaded}" ]] || fail "authenticated download omitted ${tag}/${name}"

  actual_size="$(file_size "${downloaded}")"
  actual_sha="$(sha256_file "${downloaded}")"
  [[ "${size}" == "${actual_size}" ]] || fail "release ${tag} asset ${name} has incorrect size metadata"
  if [[ -n "${digest:-}" && "${digest}" != "-" && "${digest}" != "null" ]]; then
    [[ "${digest}" == "sha256:${actual_sha}" ]] || \
      fail "release ${tag} asset ${name} has incorrect digest metadata"
  fi
  if [[ -n "${expected_size}" ]]; then
    [[ "${actual_size}" == "${expected_size}" ]] || \
      fail "release ${tag} asset ${name} has unexpected bytes"
  fi
  if [[ -n "${expected_sha}" ]]; then
    [[ "${actual_sha}" == "${expected_sha}" ]] || \
      fail "release ${tag} asset ${name} failed authenticated SHA-256 verification"
  fi
}

asset_matches() {
  local tag="$1" name="$2" expected_size="$3" expected_sha="$4"
  local metadata_file="$5" download_dir="$6"
  local line asset_id stored_name state size digest downloaded actual_size actual_sha

  line="$(asset_metadata_line "${name}" "${metadata_file}")" || return 1
  [[ -n "${line}" ]] || return 1
  IFS=$'\t' read -r asset_id stored_name state size digest <<< "${line}"
  [[ -n "${asset_id}" && "${stored_name}" == "${name}" ]] || return 1
  [[ "${state}" == "uploaded" && "${size}" == "${expected_size}" ]] || return 1
  if [[ -n "${digest:-}" && "${digest}" != "-" && "${digest}" != "null" ]]; then
    [[ "${digest}" == "sha256:${expected_sha}" ]] || return 1
  fi

  mkdir -p "${download_dir}"
  downloaded="${download_dir}/${name}"
  rm -f "${downloaded}"
  if ! "${GH_BIN}" release download "${tag}" \
    --repo "${REPOSITORY}" \
    --pattern "${name}" \
    --dir "${download_dir}"; then
    return 1
  fi
  [[ -f "${downloaded}" ]] || return 1
  actual_size="$(file_size "${downloaded}")"
  actual_sha="$(sha256_file "${downloaded}")"
  [[ "${actual_size}" == "${expected_size}" && "${actual_sha}" == "${expected_sha}" ]]
}

download_appcast_if_present() {
  local tag="$1" metadata_file="$2" download_dir="$3"
  local line
  line="$(asset_metadata_line appcast.xml "${metadata_file}")" || \
    fail "release ${tag} has duplicate metadata for appcast.xml"
  [[ -n "${line}" ]] || return 1
  verify_asset_strict "${tag}" appcast.xml "" "" "${metadata_file}" "${download_dir}"
}

build_is_at_most() {
  node -e 'process.exit(BigInt(process.argv[1]) <= BigInt(process.argv[2]) ? 0 : 1)' "$1" "$2"
}

require_selected_target_is_current_main() {
  local checkpoint="$1" current_main
  current_main="$("${GH_BIN}" api \
    "repos/${REPOSITORY}/git/ref/heads/main" \
    --jq .object.sha)" || fail "could not read current main ref at ${checkpoint}"
  [[ "${current_main}" =~ ^[0-9a-f]{40}$ ]] || \
    fail "current main ref did not resolve to a commit SHA at ${checkpoint}"
  [[ "${current_main}" == "${SELECTED_TARGET}" ]] || \
    fail "candidate target ${SELECTED_TARGET} is no longer current main ${current_main} at ${checkpoint}"
}

query_releases_paginated() {
  local output="$1"
  "${GH_BIN}" api --paginate \
    "repos/${REPOSITORY}/releases?per_page=100" \
    --jq '.[] | [.tag_name, .draft, .prerelease, .immutable, .target_commitish] | @tsv' \
    > "${output}"
}

# Candidates never leave draft state (see the promotion path below), so they
# are never on the public releases page. This is the sole candidate cleanup:
# every draft candidate at or below the finalized build is deleted except
# skip_tag (the just-promoted one), which keeps exactly one candidate draft
# around as the rollback archive for the next build.
prune_candidates() {
  local finalized_build="$1" skip_tag="${2:-}"
  local tag is_draft is_prerelease is_immutable target suffix
  while IFS=$'\t' read -r tag is_draft is_prerelease is_immutable target; do
    [[ "${is_draft}" == "true" && "${tag}" == "${CANDIDATE_PREFIX}"* ]] || continue
    [[ "${tag}" != "${skip_tag}" ]] || continue
    suffix="${tag#"${CANDIDATE_PREFIX}"}"
    [[ "${suffix}" =~ ^[0-9]+$ ]] || continue
    suffix="$((10#${suffix}))"
    if build_is_at_most "${suffix}" "${finalized_build}"; then
      "${GH_BIN}" release delete "${tag}" --repo "${REPOSITORY}" --yes --cleanup-tag
    fi
  done < "${RELEASE_LIST}"
}

snapshot_public_high_water() {
  local snapshot_name="$1" snapshot_dir releases metadata appcast_paths
  local release_tag is_draft is_prerelease is_immutable release_target release_index release_metadata release_appcast
  snapshot_dir="${TEMP_DIR}/public-snapshot-${snapshot_name}"
  releases="${snapshot_dir}/releases.tsv"
  metadata="${snapshot_dir}/rolling-assets.tsv"
  appcast_paths="${snapshot_dir}/published-appcast-paths.txt"
  mkdir -p "${snapshot_dir}"
  : > "${appcast_paths}"

  query_releases_paginated "${releases}"

  if awk -F '\t' -v expected="${ROLLING_TAG}" \
    '$1 == expected && $2 == "false" { found = 1 } END { exit !found }' "${releases}"; then
    query_assets "${ROLLING_TAG}" "${metadata}"
  else
    : > "${metadata}"
  fi

  release_index=0
  while IFS=$'\t' read -r release_tag is_draft is_prerelease is_immutable release_target; do
    [[ "${is_draft}" == "false" ]] || continue

    # Candidates never leave draft state (enforced below), so none can reach
    # this point — draft releases are already skipped above. Arbitrary
    # prereleases are not public feed high-water.
    # Rolling assets and published non-prerelease appcasts remain authoritative.
    [[ "${is_prerelease}" == "false" ]] || continue
    release_index=$((release_index + 1))
    release_metadata="${snapshot_dir}/release-${release_index}-assets.tsv"
    release_appcast="${snapshot_dir}/release-${release_index}-appcast/appcast.xml"
    if [[ "${release_tag}" == "${ROLLING_TAG}" ]]; then
      release_metadata="${metadata}"
    else
      query_assets "${release_tag}" "${release_metadata}"
    fi
    if download_appcast_if_present \
      "${release_tag}" "${release_metadata}" "$(dirname "${release_appcast}")"; then
      printf '%s\n' "${release_appcast}" >> "${appcast_paths}"
    fi
  done < "${releases}"

  node - "${STATE_MODULE}" "${metadata}" "${appcast_paths}" <<'NODE'
const fs = require("node:fs");
const [modulePath, metadataPath, appcastPathsPath] = process.argv.slice(2);
const { derivePublicHighWater } = require(modulePath);
const names = fs.readFileSync(metadataPath, "utf8").split(/\n/).filter(Boolean).map((line) => line.split("\t")[1]);
const publishedAppcastXmls = fs.readFileSync(appcastPathsPath, "utf8")
  .split(/\n/)
  .filter(Boolean)
  .map((path) => fs.readFileSync(path, "utf8"));
const build = derivePublicHighWater({
  rollingAssetNames: names,
  rollingAppcastXml: null,
  publishedMilestoneAppcastXmls: publishedAppcastXmls,
});
if (build !== null) process.stdout.write(build);
NODE
}

promotion_action_for() {
  local high_water="$1"
  node - "${STATE_MODULE}" "${SELECTED_MANIFEST}" "${high_water}" <<'NODE'
const [modulePath, manifestPath, highWaterValue] = process.argv.slice(2);
const { assertCandidateMayPromote } = require(modulePath);
const candidate = require(manifestPath);
const highWater = highWaterValue || null;
try {
  process.stdout.write(assertCandidateMayPromote(candidate, highWater));
} catch (error) {
  if (highWater !== null && BigInt(candidate.build) < BigInt(highWater)) {
    process.stdout.write("reject");
  } else {
    throw error;
  }
}
NODE
}

reconcile_role() {
  local expected_role="$1" name role size sha current_metadata
  while IFS=$'\t' read -r name role size sha; do
    [[ "${role}" == "${expected_role}" ]] || continue
    current_metadata="${TEMP_DIR}/rolling-current-${name}.tsv"
    query_assets "${ROLLING_TAG}" "${current_metadata}"
    if asset_matches "${ROLLING_TAG}" "${name}" "${size}" "${sha}" \
      "${current_metadata}" "${TEMP_DIR}/rolling-match-${name}"; then
      continue
    fi

    "${GH_BIN}" release upload "${ROLLING_TAG}" \
      "${SELECTED_PAYLOAD_DIR}/${name}" \
      --repo "${REPOSITORY}" \
      --clobber
    query_assets "${ROLLING_TAG}" "${current_metadata}"
    verify_asset_strict "${ROLLING_TAG}" "${name}" "${size}" "${sha}" \
      "${current_metadata}" "${TEMP_DIR}/rolling-upload-verification-${name}"
  done < "${PROMOTION_ORDER}"
}

verify_rolling_aliases() {
  local metadata="$1" destination="$2" name role size sha
  while IFS=$'\t' read -r name role size sha; do
    [[ "${role}" == "appcast" || "${role}" == "stable-alias" ]] || continue
    verify_asset_strict "${ROLLING_TAG}" "${name}" "${size}" "${sha}" \
      "${metadata}" "${destination}-${name}"
  done < "${PROMOTION_ORDER}"
}

while (($#)); do
  case "$1" in
    --candidate-prefix)
      [[ "$#" -ge 2 ]] || { usage; fail "--candidate-prefix requires a value"; }
      CANDIDATE_PREFIX="$2"
      shift 2
      ;;
    --rolling-tag)
      [[ "$#" -ge 2 ]] || { usage; fail "--rolling-tag requires a value"; }
      ROLLING_TAG="$2"
      shift 2
      ;;
    --reconciler-target-sha)
      [[ "$#" -ge 2 ]] || { usage; fail "--reconciler-target-sha requires a value"; }
      [[ -z "${RECONCILER_TARGET_SHA}" ]] || fail "--reconciler-target-sha may be supplied only once"
      RECONCILER_TARGET_SHA="$2"
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

[[ -n "${REPOSITORY}" ]] || fail "GITHUB_REPOSITORY is required"
[[ -n "${CANDIDATE_PREFIX}" ]] || fail "--candidate-prefix is required"
[[ -n "${ROLLING_TAG}" ]] || fail "--rolling-tag is required"
[[ "${RECONCILER_TARGET_SHA}" =~ ^[0-9a-f]{40}$ ]] || \
  fail "--reconciler-target-sha must be 40 lowercase hexadecimal characters"
[[ "${CANDIDATE_PREFIX}" =~ ^[A-Za-z0-9._-]+$ ]] || fail "candidate prefix contains unsafe characters"
[[ "${ROLLING_TAG}" =~ ^[A-Za-z0-9._-]+$ ]] || fail "rolling tag contains unsafe characters"
[[ -r "${STATE_MODULE}" ]] || fail "missing state module: ${STATE_MODULE}"
GH_BIN="$(command -v "${GH_BIN}")" || fail "GH_BIN is not executable"
command -v node >/dev/null || fail "node is required"

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/programa-rolling-reconciler.XXXXXX")"
trap cleanup EXIT INT TERM
RELEASE_LIST="${TEMP_DIR}/releases.tsv"
CANDIDATES_JSONL="${TEMP_DIR}/candidates.jsonl"
: > "${CANDIDATES_JSONL}"

query_releases_paginated "${RELEASE_LIST}"

ROLLING_EXISTS=false
ROLLING_PUBLISHED_AT_START=false
ROLLING_IMMUTABLE_AT_START=""
candidate_index=0
sealed_candidate_count=0
while IFS=$'\t' read -r tag is_draft is_prerelease is_immutable candidate_target; do
  if [[ "${tag}" == "${ROLLING_TAG}" ]]; then
    ROLLING_EXISTS=true
    ROLLING_IMMUTABLE_AT_START="${is_immutable}"
    if [[ "${is_draft}" == "false" ]]; then
      ROLLING_PUBLISHED_AT_START=true
    fi
  fi
  [[ "${tag}" == "${CANDIDATE_PREFIX}"* ]] || continue
  candidate_suffix="${tag#"${CANDIDATE_PREFIX}"}"
  [[ "${candidate_suffix}" =~ ^[1-9][0-9]*$ ]] || continue
  # Candidates are never published: they stay drafts for their whole
  # lifecycle and are deleted once superseded (see prune_candidates), so the
  # releases page never carries more than the one `rolling` entry. A
  # non-draft candidate here means an old workflow version leaked one onto
  # the public page; fail loudly rather than silently treat it as valid
  # archived state.
  [[ "${is_draft}" == "true" ]] || \
    fail "candidate ${tag} is not a draft; published rolling candidates are no longer supported"

  candidate_index=$((candidate_index + 1))
  candidate_dir="${TEMP_DIR}/candidate-${candidate_index}"
  candidate_metadata="${candidate_dir}/assets.tsv"
  mkdir -p "${candidate_dir}"
  query_assets "${tag}" "${candidate_metadata}"
  seal_line="$(asset_metadata_line "${SEAL_NAME}" "${candidate_metadata}")" || \
    fail "candidate ${tag} has duplicate seal assets"
  if [[ -z "${seal_line}" ]]; then
    [[ "${is_draft}" == "true" ]] || fail "published archive ${tag} is missing its seal"
    continue
  fi

  verify_asset_strict "${tag}" "${SEAL_NAME}" "" "" \
    "${candidate_metadata}" "${candidate_dir}/seal"
  normalized_manifest="${candidate_dir}/manifest.json"
  node - "${STATE_MODULE}" "${candidate_dir}/seal/${SEAL_NAME}" > "${normalized_manifest}" <<'NODE'
const fs = require("node:fs");
const [modulePath, manifestPath] = process.argv.slice(2);
const { validateCandidateManifest } = require(modulePath);
const value = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
const manifest = validateCandidateManifest(value);
if (!manifest.sealed) throw new TypeError("candidate seal must declare sealed: true");
process.stdout.write(`${JSON.stringify(manifest)}\n`);
NODE
  sealed_candidate_count=$((sealed_candidate_count + 1))

  IFS=$'\t' read -r manifest_build manifest_target manifest_version < <(
    node -e '
      const value = require(process.argv[1]);
      process.stdout.write(`${value.build}\t${value.targetSha}\t${value.version}\n`);
    ' "${normalized_manifest}"
  )
  [[ "${tag}" == "${CANDIDATE_PREFIX}${manifest_build}" ]] || \
    fail "candidate tag ${tag} disagrees with sealed build ${manifest_build}"
  [[ "${candidate_target}" == "${manifest_target}" ]] || \
    fail "candidate ${tag} target disagrees with its seal"
  if [[ "${manifest_target}" == "${RECONCILER_TARGET_SHA}" ]]; then
    cat "${normalized_manifest}" >> "${CANDIDATES_JSONL}"
  fi
done < "${RELEASE_LIST}"

SELECTED_MANIFEST="${TEMP_DIR}/selected-manifest.json"
node - "${STATE_MODULE}" "${CANDIDATES_JSONL}" > "${SELECTED_MANIFEST}" <<'NODE'
const fs = require("node:fs");
const [modulePath, candidatesPath] = process.argv.slice(2);
const { selectPromotionCandidate } = require(modulePath);
const lines = fs.readFileSync(candidatesPath, "utf8").split(/\n/).filter(Boolean);
const selected = selectPromotionCandidate(lines.map((line) => JSON.parse(line)));
if (selected !== null) process.stdout.write(`${JSON.stringify(selected)}\n`);
NODE

if [[ ! -s "${SELECTED_MANIFEST}" ]]; then
  if ((sealed_candidate_count > 0)); then
    UNMATCHED_CURRENT_MAIN="$("${GH_BIN}" api \
      "repos/${REPOSITORY}/git/ref/heads/main" \
      --jq .object.sha)" || \
      fail "could not read current main ref while diagnosing an unmatched reconciler target"
    [[ "${UNMATCHED_CURRENT_MAIN}" == "${RECONCILER_TARGET_SHA}" ]] || \
      fail "reconciler target ${RECONCILER_TARGET_SHA} is no longer current main ${UNMATCHED_CURRENT_MAIN}"
    fail "no sealed candidate matches reconciler target ${RECONCILER_TARGET_SHA}"
  fi
  exit 0
fi

IFS=$'\t' read -r SELECTED_BUILD SELECTED_TARGET SELECTED_VERSION < <(
  node -e '
    const value = require(process.argv[1]);
    process.stdout.write(`${value.build}\t${value.targetSha}\t${value.version}\n`);
  ' "${SELECTED_MANIFEST}"
)
SELECTED_TAG="${CANDIDATE_PREFIX}${SELECTED_BUILD}"
[[ "${SELECTED_TARGET}" == "${RECONCILER_TARGET_SHA}" ]] || \
  fail "selected candidate target ${SELECTED_TARGET} does not match reconciler target ${RECONCILER_TARGET_SHA}"
SELECTED_STATE_ROW="$(awk -F '\t' -v expected="${SELECTED_TAG}" '
  $1 == expected { print; matches += 1 }
  END { if (matches != 1) exit 2 }
' "${RELEASE_LIST}")" || fail "selected candidate release state is missing or ambiguous"
IFS=$'\t' read -r \
  selected_state_tag \
  SELECTED_INITIAL_DRAFT \
  SELECTED_INITIAL_PRERELEASE \
  SELECTED_INITIAL_IMMUTABLE \
  selected_state_target <<< "${SELECTED_STATE_ROW}"
[[ "${selected_state_tag}" == "${SELECTED_TAG}" ]] || fail "selected candidate state resolved to an unexpected tag"
[[ "${SELECTED_INITIAL_DRAFT}" == "true" ]] || \
  fail "selected candidate ${SELECTED_TAG} is not a draft; published rolling candidates are no longer supported"
[[ "${selected_state_target}" == "${SELECTED_TARGET}" ]] || fail "selected candidate state has an unexpected target"
PROMOTION_ORDER="${TEMP_DIR}/promotion-order.tsv"
node - "${STATE_MODULE}" "${SELECTED_MANIFEST}" > "${PROMOTION_ORDER}" <<'NODE'
const [modulePath, manifestPath] = process.argv.slice(2);
const { getPromotionOrder } = require(modulePath);
const manifest = require(manifestPath);
for (const asset of getPromotionOrder(manifest)) {
  process.stdout.write(`${asset.name}\t${asset.role}\t${asset.size}\t${asset.sha256}\n`);
}
NODE

SELECTED_METADATA="${TEMP_DIR}/selected-assets.tsv"
query_assets "${SELECTED_TAG}" "${SELECTED_METADATA}"
cut -f2 "${SELECTED_METADATA}" | LC_ALL=C sort > "${TEMP_DIR}/candidate-actual-names.txt"
cut -f1 "${PROMOTION_ORDER}" > "${TEMP_DIR}/candidate-expected-names.txt"
printf '%s\n' "${SEAL_NAME}" >> "${TEMP_DIR}/candidate-expected-names.txt"
LC_ALL=C sort "${TEMP_DIR}/candidate-expected-names.txt" > "${TEMP_DIR}/candidate-expected-names.sorted.txt"
cmp -s "${TEMP_DIR}/candidate-actual-names.txt" "${TEMP_DIR}/candidate-expected-names.sorted.txt" || \
  fail "candidate ${SELECTED_TAG} does not contain exactly six payloads plus its seal"

SELECTED_PAYLOAD_DIR="${TEMP_DIR}/selected-payload"
while IFS=$'\t' read -r name role size sha; do
  verify_asset_strict "${SELECTED_TAG}" "${name}" "${size}" "${sha}" \
    "${SELECTED_METADATA}" "${SELECTED_PAYLOAD_DIR}"
done < "${PROMOTION_ORDER}"
verify_asset_strict "${SELECTED_TAG}" "${SEAL_NAME}" "" "" \
  "${SELECTED_METADATA}" "${TEMP_DIR}/selected-seal-verification"
SELECTED_SEAL_PATH="${TEMP_DIR}/selected-seal-verification/${SEAL_NAME}"
SELECTED_SEAL_SIZE="$(file_size "${SELECTED_SEAL_PATH}")"
SELECTED_SEAL_SHA="$(sha256_file "${SELECTED_SEAL_PATH}")"

node - \
  "${STATE_MODULE}" \
  "${SELECTED_MANIFEST}" \
  "${SELECTED_PAYLOAD_DIR}/appcast.xml" \
  "${REPOSITORY}" \
  "${SELECTED_TAG}" <<'NODE'
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

require_selected_target_is_current_main "initial provenance gate"

"${GH_BIN}" attestation verify \
  "${SELECTED_SEAL_PATH}" \
  --repo "${REPOSITORY}" \
  --signer-workflow "${REPOSITORY}/.github/workflows/release.yml" \
  --source-ref refs/heads/main \
  --source-digest "${SELECTED_TARGET}" \
  --deny-self-hosted-runners

while IFS=$'\t' read -r name role size sha; do
  "${GH_BIN}" attestation verify "${SELECTED_PAYLOAD_DIR}/${name}" \
    --repo "${REPOSITORY}" \
    --signer-workflow "${REPOSITORY}/.github/workflows/release.yml" \
    --source-ref refs/heads/main \
    --source-digest "${SELECTED_TARGET}" \
    --deny-self-hosted-runners
done < "${PROMOTION_ORDER}"

CI_MATCH_COUNT="$("${GH_BIN}" api \
  "repos/${REPOSITORY}/actions/workflows/ci.yml/runs" \
  -X GET \
  -f "head_sha=${SELECTED_TARGET}" \
  -f branch=main \
  -f event=push \
  -f status=completed \
  --jq "[.workflow_runs[] | select(.head_sha == \"${SELECTED_TARGET}\" and .head_branch == \"main\" and .event == \"push\" and .status == \"completed\" and .conclusion == \"success\")] | length")"
[[ "${CI_MATCH_COUNT}" =~ ^[1-9][0-9]*$ ]] || \
  fail "candidate target ${SELECTED_TARGET} has no completed successful main-branch push CI run"

HIGH_WATER="$(snapshot_public_high_water initial)"
PROMOTION_ACTION="$(promotion_action_for "${HIGH_WATER}")"

if [[ "${PROMOTION_ACTION}" == "reject" ]]; then
  prune_candidates "${HIGH_WATER}"
  exit 0
fi
[[ "${PROMOTION_ACTION}" == "repair" || "${PROMOTION_ACTION}" == "promote" ]] || \
  fail "state module returned an unknown promotion action"

[[ "${ROLLING_EXISTS}" == "true" && "${ROLLING_PUBLISHED_AT_START}" == "true" ]] || \
  fail "rolling must already exist as a published legacy mutable release"
[[ "${ROLLING_IMMUTABLE_AT_START}" == "false" ]] || \
  fail "rolling must remain a legacy mutable release"

RACE_HIGH_WATER="$(snapshot_public_high_water post-candidate-verification)"
RACE_ACTION="$(promotion_action_for "${RACE_HIGH_WATER}")"
if [[ "${RACE_ACTION}" == "reject" ]]; then
  fail "public high-water advanced to ${RACE_HIGH_WATER} during candidate verification"
fi
[[ "${RACE_ACTION}" == "repair" || "${RACE_ACTION}" == "promote" ]] || \
  fail "state module returned an unknown post-candidate-verification promotion action"
require_selected_target_is_current_main "alias publication gate"
reconcile_role appcast
reconcile_role stable-alias

CONVERGED_METADATA="${TEMP_DIR}/rolling-converged-assets.tsv"
query_assets "${ROLLING_TAG}" "${CONVERGED_METADATA}"
verify_rolling_aliases "${CONVERGED_METADATA}" "${TEMP_DIR}/rolling-prepublish-verification"

STARTING_REF=""
if STARTING_REF="$("${GH_BIN}" api "repos/${REPOSITORY}/git/ref/tags/${ROLLING_TAG}" --jq .object.sha 2>/dev/null)"; then
  [[ "${STARTING_REF}" =~ ^[0-9a-f]{40}$ ]] || fail "rolling ref did not resolve to a commit SHA"
elif [[ "${ROLLING_PUBLISHED_AT_START}" == "true" ]]; then
  fail "published rolling release has no readable git ref"
fi

PRESERVE_PUBLISHED_METADATA=false
PUBLISHED_BODY="${TEMP_DIR}/published-body.md"
if [[ "${ROLLING_PUBLISHED_AT_START}" == "true" && "${STARTING_REF}" == "${SELECTED_TARGET}" ]]; then
  published_states="${TEMP_DIR}/published-rolling-states.tsv"
  query_releases_paginated "${published_states}" || \
    fail "could not enumerate releases while preserving published rolling metadata"
  published_state="$(awk -F '\t' -v expected="${ROLLING_TAG}" '
    $1 == expected { row = $0; matches += 1 }
    END {
      if (matches == 1) print row
      else exit 2
    }
  ' "${published_states}")" || fail "published rolling release state is missing or ambiguous"
  IFS=$'\t' read -r \
    published_tag \
    published_draft \
    published_prerelease \
    published_immutable \
    published_target <<< "${published_state}"
  [[ "${published_tag}" == "${ROLLING_TAG}" ]] || fail "published rolling state resolved to an unexpected tag"
  published_title="$("${GH_BIN}" release view "${ROLLING_TAG}" \
    --repo "${REPOSITORY}" --json name --jq .name)" || fail "could not read published rolling title"
  "${GH_BIN}" release view "${ROLLING_TAG}" \
    --repo "${REPOSITORY}" --json body --template '{{.body}}' > "${PUBLISHED_BODY}" || \
    fail "could not read published rolling notes"
  [[ "${published_title}" == "Rolling ${SELECTED_VERSION}" ]] || \
    fail "published rolling title conflicts with the selected candidate"
  [[ "${published_draft}" == "false" ]] || fail "published rolling release is still a draft"
  [[ "${published_prerelease}" == "false" ]] || fail "published rolling release is a prerelease"
  [[ "${published_immutable}" == "false" ]] || fail "published rolling release became immutable"
  [[ -n "${published_target}" ]] || fail "published rolling release has no target"
  [[ -s "${PUBLISHED_BODY}" ]] || fail "published rolling release notes are empty"
  if grep -Fq "${SELECTED_TARGET} to ${SELECTED_TARGET}" "${PUBLISHED_BODY}" || \
    grep -Fq "${SELECTED_TARGET}...${SELECTED_TARGET}" "${PUBLISHED_BODY}"; then
    fail "published rolling release notes contain a selected-to-selected comparison"
  fi
  PRESERVE_PUBLISHED_METADATA=true
fi

FINAL_HIGH_WATER="$(snapshot_public_high_water pre-publication)"
FINAL_ACTION="$(promotion_action_for "${FINAL_HIGH_WATER}")"
if [[ "${FINAL_ACTION}" == "reject" ]]; then
  fail "public high-water advanced to ${FINAL_HIGH_WATER} before rolling publication"
fi
[[ "${FINAL_ACTION}" == "repair" || "${FINAL_ACTION}" == "promote" ]] || \
  fail "state module returned an unknown pre-publication promotion action"
require_selected_target_is_current_main "release metadata publication gate"

NOTES_FILE="${TEMP_DIR}/release-notes.md"
RAW_NOTES_FILE="${TEMP_DIR}/release-notes.raw.md"
if [[ "${PRESERVE_PUBLISHED_METADATA}" == "true" ]]; then
  cp "${PUBLISHED_BODY}" "${NOTES_FILE}"
else
  GENERATE_NOTES_ARGS=(
    "repos/${REPOSITORY}/releases/generate-notes"
    -X POST
    -f tag_name=rolling-next
    -f "target_commitish=${SELECTED_TARGET}"
  )
  if [[ "${ROLLING_PUBLISHED_AT_START}" == "true" ]]; then
    GENERATE_NOTES_ARGS+=(-f "previous_tag_name=${ROLLING_TAG}")
  fi
  GENERATE_NOTES_ARGS+=(--jq .body)
  "${GH_BIN}" api "${GENERATE_NOTES_ARGS[@]}" > "${RAW_NOTES_FILE}"
  node - \
    "${RAW_NOTES_FILE}" \
    "${NOTES_FILE}" \
    "${ROLLING_PUBLISHED_AT_START}" \
    "${ROLLING_TAG}" \
    "${STARTING_REF}" \
    "${SELECTED_TARGET}" <<'NODE'
const fs = require("node:fs");
const [sourcePath, destinationPath, hadRolling, rollingTag, startingSha, targetSha] = process.argv.slice(2);
let notes = fs.readFileSync(sourcePath, "utf8");
if (hadRolling === "true") {
  const generatedCompare = `/compare/${rollingTag}...rolling-next`;
  const immutableCompare = `/compare/${startingSha}...${targetSha}`;
  notes = notes.split(generatedCompare).join(immutableCompare);
}
fs.writeFileSync(destinationPath, notes);
NODE
fi

if [[ "${PRESERVE_PUBLISHED_METADATA}" != "true" ]]; then
  require_selected_target_is_current_main "post-notes release metadata publication gate"
  "${GH_BIN}" release edit "${ROLLING_TAG}" \
    --repo "${REPOSITORY}" \
    --title "Rolling ${SELECTED_VERSION}" \
    --notes-file "${NOTES_FILE}" \
    --draft=false \
    --latest
fi

if [[ "${STARTING_REF}" != "${SELECTED_TARGET}" ]]; then
  require_selected_target_is_current_main "rolling ref publication gate"
  # Rolling is required (lines 597-598) to already exist as a published
  # release before this point, so its tag ref is always present; a PATCH
  # failure here is a real error and must propagate, never be silently
  # retried as "create instead of move" (that masked genuine failures,
  # including hard-stop injection, as false success).
  "${GH_BIN}" api "repos/${REPOSITORY}/git/refs/tags/${ROLLING_TAG}" \
    -X PATCH \
    -f "sha=${SELECTED_TARGET}" \
    -F force=true >/dev/null
fi

FINAL_METADATA="${TEMP_DIR}/rolling-final-assets.tsv"
query_assets "${ROLLING_TAG}" "${FINAL_METADATA}"
verify_rolling_aliases "${FINAL_METADATA}" "${TEMP_DIR}/rolling-final-verification"

FINAL_TITLE="$("${GH_BIN}" release view "${ROLLING_TAG}" --repo "${REPOSITORY}" --json name --jq .name)"
FINAL_RELEASE_LIST="${TEMP_DIR}/final-releases.tsv"
query_releases_paginated "${FINAL_RELEASE_LIST}"
FINAL_RELEASE_ROW="$(awk -F '\t' -v expected="${ROLLING_TAG}" '
  $1 == expected { print; matches += 1 }
  END { if (matches != 1) exit 2 }
' "${FINAL_RELEASE_LIST}")" || fail "rolling release was missing or duplicated during final verification"
IFS=$'\t' read -r \
  final_tag \
  FINAL_DRAFT \
  FINAL_PRERELEASE \
  FINAL_IMMUTABLE \
  FINAL_TARGET <<< "${FINAL_RELEASE_ROW}"
FINAL_BODY="${TEMP_DIR}/final-body.md"
"${GH_BIN}" release view "${ROLLING_TAG}" --repo "${REPOSITORY}" --json body --template '{{.body}}' > "${FINAL_BODY}"
FINAL_REF="$("${GH_BIN}" api "repos/${REPOSITORY}/git/ref/tags/${ROLLING_TAG}" --jq .object.sha)"
[[ "${FINAL_TITLE}" == "Rolling ${SELECTED_VERSION}" ]] || fail "rolling release title did not converge"
[[ "${final_tag}" == "${ROLLING_TAG}" ]] || fail "rolling release resolved to an unexpected tag"
[[ "${FINAL_DRAFT}" == "false" ]] || fail "rolling release is still a draft"
[[ "${FINAL_PRERELEASE}" == "false" ]] || fail "rolling release is still a prerelease"
[[ "${FINAL_IMMUTABLE}" == "false" ]] || fail "rolling release became immutable"
[[ -n "${FINAL_TARGET}" ]] || fail "rolling release has no target"
cmp -s "${FINAL_BODY}" "${NOTES_FILE}" || fail "rolling release notes did not converge"
[[ "${FINAL_REF}" == "${SELECTED_TARGET}" ]] || fail "rolling ref did not converge"

prune_candidates "${SELECTED_BUILD}" "${SELECTED_TAG}"
