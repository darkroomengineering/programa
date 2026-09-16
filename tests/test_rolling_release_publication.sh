#!/usr/bin/env bash
set -euo pipefail

# Black-box contracts exercised by this harness:
#
#   GH_BIN=/path/to/gh GITHUB_REPOSITORY=owner/repo \
#     scripts/publish_release_candidate.sh \
#       --candidate-tag rolling-candidate-<build> \
#       --target-sha <sha> --build <positive-decimal> --version <version> \
#       --seal-output <local-path> \
#       --asset-role <role>=<path> [--asset-role ...]
#
# Passing --prepare-only computes and writes the exact seal, then exits with no
# GitHub mutation. A later normal invocation with that existing --seal-output
# must verify the prepared bytes against the current payload before creating or
# changing a candidate. It uploads every payload before uploading that exact
# prepared seal last. This two-phase contract applies to rolling and milestone
# candidates through the same CLI.
#
# The candidate publisher creates or resumes a draft release at the requested
# tag. It uploads only absent assets whose bytes match the request, rejects an
# existing name with different state/size/digest, and uploads the generated
# programa-release-candidate.json manifest last. That manifest is the seal and
# must also be written byte-for-byte to the requested local output path. It
# has the authoritative state-module shape `{schemaVersion:2,sealed:true,
# targetSha,version,build,assets:[{name,role,size,sha256}]}`. Manifest sha256
# values are bare lowercase hex; GitHub asset metadata uses `sha256:<hex>`.
# Payload appcast URLs bind to the requested destination
# tag. Archive candidates use their permanent build tag; legacy rolling
# candidate coverage still verifies an explicitly requested `rolling` target.
#
#   GH_BIN=/path/to/gh GITHUB_REPOSITORY=owner/repo \
#     scripts/publish_rolling_release.sh \
#       --candidate-prefix rolling-candidate- --rolling-tag rolling \
#       --reconciler-target-sha <checked-out-trigger-sha>
#
# GitHub Actions serializes reconciler jobs externally. The helper creates no
# persistent lock. It discovers the greatest sealed decimal build, validates
# and downloads every candidate
# asset through authenticated gh calls, then reconciles the rolling release.
# Before mutation it verifies the seal and all payload attestations against the release
# workflow on refs/heads/main with self-hosted runners denied, and requires a
# completed successful main-branch push CI run for the sealed target SHA.
# Rolling's published build is a high-water mark: lower candidates cannot move
# it backward, while an equal-build candidate repairs drift. Every mutation is
# retry-safe. Candidates never leave draft state and are never published to the
# releases page. Repository release immutability must remain disabled because
# rolling is intentionally reused; candidate integrity comes from its sealed
# bytes and attestations instead. Rolling reconciles appcast.xml and the stable
# macOS and Windows aliases; build-specific payloads remain on the draft
# candidate and are never copied into rolling. Metadata and latest status
# change before the rolling ref moves. Rolling must already exist as the
# legacy mutable release; missing or immutable state fails. After promotion,
# every other draft candidate at or below the finalized build is deleted,
# keeping exactly the just-promoted candidate draft as a private rollback
# archive (retention 1) so the releases page never shows more than the one
# `rolling` entry.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CANDIDATE_HELPER="${ROOT_DIR}/scripts/publish_release_candidate.sh"
ROLLING_HELPER="${ROOT_DIR}/scripts/publish_rolling_release.sh"

[[ -x "${CANDIDATE_HELPER}" ]] || {
  echo "FAIL: missing executable candidate publisher at scripts/publish_release_candidate.sh" >&2
  exit 1
}
[[ -x "${ROLLING_HELPER}" ]] || {
  echo "FAIL: missing executable state-aware reconciler at scripts/publish_rolling_release.sh" >&2
  exit 1
}

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/programa-candidate-publication.XXXXXX")"
cleanup_harness() {
  local status=$?
  # A helper call that fails under `set -e` would otherwise exit this harness
  # silently; echo the captured helper output so CI logs show the cause.
  if [[ "${status}" -ne 0 && -s "${TMP_DIR}/run.out" ]]; then
    echo "--- last helper output (exit ${status}) ---" >&2
    cat "${TMP_DIR}/run.out" >&2
  fi
  rm -rf "${TMP_DIR}"
}
trap cleanup_harness EXIT
STATE_DIR="${TMP_DIR}/state"
FIXTURE_DIR="${TMP_DIR}/fixtures"
FAKE_GH="${TMP_DIR}/gh"
RUN_OUTPUT="${TMP_DIR}/run.out"
REPOSITORY="darkroomengineering/programa"
SEAL_NAME="programa-release-candidate.json"
ED25519_SIGNATURE="AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQ=="

fail() { echo "FAIL: $*" >&2; exit 1; }
sha256_file() { shasum -a 256 "$1" | awk '{print $1}'; }
digest_file() { printf 'sha256:%s' "$(sha256_file "$1")"; }
file_size() { stat -c '%s' "$1" 2>/dev/null || stat -f '%z' "$1"; }
target_sha_for() { printf '%040x' "$1"; }
release_dir() { printf '%s/releases/%s' "${STATE_DIR}" "$1"; }
asset_dir() { printf '%s/assets/%s' "$(release_dir "$1")" "$2"; }

write_release() {
  local tag="$1" target_sha="$2" draft="$3" latest="$4" title="$5" body="$6" prerelease="${7:-false}" dir
  dir="$(release_dir "${tag}")"
  mkdir -p "${dir}/assets"
  printf '%s\n' "${tag}" > "${dir}/tag"
  printf '%s\n' "${target_sha}" > "${dir}/target_sha"
  printf '%s\n' "${draft}" > "${dir}/draft"
  printf 'false\n' > "${dir}/immutable"
  printf '%s\n' "${latest}" > "${dir}/latest"
  printf '%s\n' "${prerelease}" > "${dir}/prerelease"
  printf '%s\n' "${title}" > "${dir}/title"
  printf '%s\n' "${body}" > "${dir}/body"
}

write_asset() {
  local tag="$1" name="$2" source="$3" dir
  dir="$(asset_dir "${tag}" "${name}")"
  mkdir -p "${dir}"
  if [[ -f "${STATE_DIR}/next_asset_id" ]]; then
    local asset_id
    asset_id="$(cat "${STATE_DIR}/next_asset_id")"
    printf '%s\n' "$((asset_id + 1))" > "${STATE_DIR}/next_asset_id"
    printf '%s\n' "${asset_id}" > "${dir}/id"
  fi
  cp "${source}" "${dir}/bytes"
  printf 'uploaded\n' > "${dir}/state"
  file_size "${source}" > "${dir}/size"
  printf '%s\n' "$(digest_file "${source}")" > "${dir}/digest"
}

assert_file_equals() {
  local file="$1" expected="$2" actual
  [[ -f "${file}" ]] || fail "missing ${file#${STATE_DIR}/}"
  actual="$(cat "${file}")"
  [[ "${actual}" == "${expected}" ]] || fail "${file#${STATE_DIR}/} was '${actual}', expected '${expected}'"
}
assert_release_exists() { [[ -d "$(release_dir "$1")" ]] || fail "missing release $1"; }
assert_release_absent() { [[ ! -d "$(release_dir "$1")" ]] || fail "release $1 still exists"; }
assert_asset_count() {
  local tag="$1" expected="$2" actual
  actual="$(find "$(release_dir "${tag}")/assets" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
  [[ "${actual}" == "${expected}" ]] || fail "release ${tag} has ${actual} assets, expected ${expected}"
}
assert_asset_equals() {
  cmp -s "$(asset_dir "$1" "$2")/bytes" "$3" || fail "$1/$2 does not contain the expected bytes"
}
assert_no_asset_write() {
  if grep -Eq "^mutation (delete-asset|upload-asset) rolling $1$" "${STATE_DIR}/operations.log"; then
    fail "converged retry wrote rolling asset $1"
  fi
}

reset_state() {
  rm -rf "${STATE_DIR}"
  mkdir -p "${STATE_DIR}/releases"
  : > "${STATE_DIR}/operations.log"
  printf '1000\n' > "${STATE_DIR}/next_asset_id"
  printf '500\n' > "${STATE_DIR}/next_release_id"
}

make_fixture() {
  local build="$1" version="$2" destination="${3:-rolling}" dir="${FIXTURE_DIR}/$1"
  mkdir -p "${dir}"
  printf 'enclosure-%s\n' "${build}" > "${dir}/programa-macos-${build}.dmg"
  printf 'dsym-%s\n' "${build}" > "${dir}/programa-dSYMs-${build}.zip"
  printf 'windows-%s\n' "${build}" > "${dir}/programa-windows-${build}.exe"
  cp "${dir}/programa-macos-${build}.dmg" "${dir}/programa-macos.dmg"
  cp "${dir}/programa-windows-${build}.exe" "${dir}/programa-windows.exe"
  local enclosure_size
  enclosure_size="$(file_size "${dir}/programa-macos-${build}.dmg")"
  cat > "${dir}/appcast.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel><item><title>${version}</title>
    <sparkle:version>${build}</sparkle:version>
    <enclosure url="https://github.com/${REPOSITORY}/releases/download/${destination}/programa-macos-${build}.dmg" length="${enclosure_size}" sparkle:edSignature="${ED25519_SIGNATURE}" />
  </item></channel>
</rss>
EOF
}

poison_appcast_url() {
  local build="$1" file="${FIXTURE_DIR}/$1/appcast.xml"
  cat > "${file}" <<EOF
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
  <description>harmless https://github.com/${REPOSITORY}/releases/download/rolling/ text</description>
  <item><sparkle:version>${build}</sparkle:version><enclosure url="https://github.com/attacker/example/releases/download/not-rolling/programa-macos-${build}.dmg" length="$(file_size "${FIXTURE_DIR}/$1/programa-macos-$1.dmg")" sparkle:edSignature="${ED25519_SIGNATURE}" /></item>
</channel></rss>
EOF
}

write_invalid_appcast_item() {
  local build="$1" shape="$2" file="${FIXTURE_DIR}/$1/appcast.xml" version enclosure item
  version="<sparkle:version>${build}</sparkle:version>"
  enclosure="<enclosure url=\"https://github.com/${REPOSITORY}/releases/download/rolling/programa-macos-${build}.dmg\" length=\"$(file_size "${FIXTURE_DIR}/$1/programa-macos-$1.dmg")\" sparkle:edSignature=\"${ED25519_SIGNATURE}\" />"
  case "${shape}" in
    missing-version) item="${enclosure}" ;;
    duplicate-version) item="${version}${version}${enclosure}" ;;
    duplicate-enclosure) item="${version}${enclosure}${enclosure}" ;;
    mismatched-enclosure) item="${version}<enclosure url=\"https://github.com/${REPOSITORY}/releases/download/rolling/programa-macos-$((build + 1)).dmg\" length=\"$(file_size "${FIXTURE_DIR}/$1/programa-macos-$1.dmg")\" sparkle:edSignature=\"${ED25519_SIGNATURE}\" />" ;;
    *) fail "unknown invalid appcast shape ${shape}" ;;
  esac
  printf '<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>%s</item></channel></rss>\n' \
    "${item}" > "${file}"
}

fixture_roles() {
  local build="$1" dir="${FIXTURE_DIR}/$1"
  printf '%s\n' \
    "immutable=${dir}/programa-macos-${build}.dmg" \
    "immutable=${dir}/programa-dSYMs-${build}.zip" \
    "immutable=${dir}/programa-windows-${build}.exe" \
    "appcast=${dir}/appcast.xml" \
    "stable-alias=${dir}/programa-macos.dmg" \
    "stable-alias=${dir}/programa-windows.exe"
}

seal_output_for() { printf '%s/candidate-seal-%s.json' "${TMP_DIR}" "$1"; }

invoke_candidate() {
  local build="$1" version="$2" failure="${3:-}" prefix="${4:-rolling-candidate-}" destination="${5:-rolling}" attempt="${6:-}" role seal_output candidate_tag
  candidate_tag="${prefix}${build}${attempt:+-${attempt}}"
  seal_output="$(seal_output_for "${candidate_tag}")"
  rm -f "${seal_output}"
  local args=(--candidate-prefix "${prefix}" --destination-tag "${destination}" --candidate-tag "${candidate_tag}" --target-sha "$(target_sha_for "${build}")" --build "${build}" --version "${version}" --seal-output "${seal_output}")
  while IFS= read -r role; do args+=(--asset-role "${role}"); done < <(fixture_roles "${build}")
  GH_BIN="${FAKE_GH}" GITHUB_REPOSITORY="${REPOSITORY}" FAKE_GH_STATE_DIR="${STATE_DIR}" \
  FAKE_GH_FAIL_POINT="${failure}" FAKE_GH_CORRUPT_UPLOAD="${FAKE_GH_CORRUPT_UPLOAD:-}" \
    "${CANDIDATE_HELPER}" "${args[@]}" > "${RUN_OUTPUT}" 2>&1
}

prepare_candidate() {
  local build="$1" version="$2" prefix="${3:-rolling-candidate-}" destination="${4:-rolling}" attempt="${5:-}" role seal_output candidate_tag
  candidate_tag="${prefix}${build}${attempt:+-${attempt}}"
  seal_output="$(seal_output_for "${candidate_tag}")"
  rm -f "${seal_output}"
  local args=(--prepare-only --candidate-prefix "${prefix}" --destination-tag "${destination}" --candidate-tag "${candidate_tag}" --target-sha "$(target_sha_for "${build}")" --build "${build}" --version "${version}" --seal-output "${seal_output}")
  while IFS= read -r role; do args+=(--asset-role "${role}"); done < <(fixture_roles "${build}")
  GH_BIN="${FAKE_GH}" GITHUB_REPOSITORY="${REPOSITORY}" FAKE_GH_STATE_DIR="${STATE_DIR}" \
    "${CANDIDATE_HELPER}" "${args[@]}" > "${RUN_OUTPUT}" 2>&1
}

stage_prepared_candidate() {
  local build="$1" version="$2" prefix="${3:-rolling-candidate-}" destination="${4:-rolling}" attempt="${5:-}" role seal_output candidate_tag
  candidate_tag="${prefix}${build}${attempt:+-${attempt}}"
  seal_output="$(seal_output_for "${candidate_tag}")"
  [[ -f "${seal_output}" ]] || fail "prepared seal is missing for ${candidate_tag}"
  local args=(--candidate-prefix "${prefix}" --destination-tag "${destination}" --candidate-tag "${candidate_tag}" --target-sha "$(target_sha_for "${build}")" --build "${build}" --version "${version}" --seal-output "${seal_output}")
  while IFS= read -r role; do args+=(--asset-role "${role}"); done < <(fixture_roles "${build}")
  GH_BIN="${FAKE_GH}" GITHUB_REPOSITORY="${REPOSITORY}" FAKE_GH_STATE_DIR="${STATE_DIR}" \
    "${CANDIDATE_HELPER}" "${args[@]}" > "${RUN_OUTPUT}" 2>&1
}

invoke_rolling() {
  local stop_after="${1:-}" fail_point="${2:-}" reconciler_target="${3:-$(cat "${STATE_DIR}/main_sha")}"
  GH_BIN="${FAKE_GH}" GITHUB_REPOSITORY="${REPOSITORY}" FAKE_GH_STATE_DIR="${STATE_DIR}" \
  FAKE_GH_STOP_AFTER_MUTATION="${stop_after}" FAKE_GH_FAIL_POINT="${fail_point}" \
  FAKE_GH_EXPOSE_MILESTONE_APPCAST="${FAKE_GH_EXPOSE_MILESTONE_APPCAST:-}" \
  FAKE_GH_EXPOSE_MILESTONE_BEFORE_METADATA="${FAKE_GH_EXPOSE_MILESTONE_BEFORE_METADATA:-}" \
  FAKE_GH_DUPLICATE_APPCAST_TAG="${FAKE_GH_DUPLICATE_APPCAST_TAG:-}" \
  FAKE_GH_ADVANCE_MAIN_AFTER_ARCHIVE="${FAKE_GH_ADVANCE_MAIN_AFTER_ARCHIVE:-}" \
  FAKE_GH_ADVANCE_MAIN_BEFORE_METADATA="${FAKE_GH_ADVANCE_MAIN_BEFORE_METADATA:-}" \
  FAKE_GH_ADVANCE_MAIN_DURING_NOTES="${FAKE_GH_ADVANCE_MAIN_DURING_NOTES:-}" \
  FAKE_GH_SWAP_SEAL_ON_PUBLISH="${FAKE_GH_SWAP_SEAL_ON_PUBLISH:-}" \
  FAKE_GH_FAIL_ATTESTATION="${FAKE_GH_FAIL_ATTESTATION:-}" FAKE_GH_CI_RESULT="${FAKE_GH_CI_RESULT:-success}" \
    "${ROLLING_HELPER}" --candidate-prefix rolling-candidate- --rolling-tag rolling \
      --reconciler-target-sha "${reconciler_target}" > "${RUN_OUTPUT}" 2>&1
}

cat > "${FAKE_GH}" <<'FAKE_GH_EOF'
#!/usr/bin/env bash
set -euo pipefail
STATE_DIR="${FAKE_GH_STATE_DIR:?}"
RELEASES="${STATE_DIR}/releases"
LOG="${STATE_DIR}/operations.log"
release_dir() { printf '%s/%s' "${RELEASES}" "$1"; }
asset_dir() { printf '%s/assets/%s' "$(release_dir "$1")" "$2"; }
file_size() { stat -c '%s' "$1" 2>/dev/null || stat -f '%z' "$1"; }
digest_file() { printf 'sha256:%s' "$(shasum -a 256 "$1" | awk '{print $1}')"; }
log() { printf '%s\n' "$*" >> "${LOG}"; }
next_id() { local file="$1" value; value="$(cat "${file}")"; printf '%s\n' "$((value + 1))" > "${file}"; printf '%s' "${value}"; }
maybe_fail() { [[ "${FAKE_GH_FAIL_POINT:-}" != "$1" ]] || { echo "injected failure: $1" >&2; exit 42; }; }
mutation() {
  local operation="$*" count
  count="$(( $(cat "${STATE_DIR}/mutation_count" 2>/dev/null || echo 0) + 1 ))"
  printf '%s\n' "${count}" > "${STATE_DIR}/mutation_count"
  log "mutation ${operation}"
  if [[ -n "${FAKE_GH_STOP_AFTER_MUTATION:-}" && "${count}" == "${FAKE_GH_STOP_AFTER_MUTATION}" ]]; then
    echo "hard stop after public mutation ${count}: ${operation}" >&2; exit 97
  fi
}

release_create() {
  local tag="$1"; shift
  local draft=false prerelease=false target="" title="" notes=""
  while (($#)); do case "$1" in
    --draft) draft=true; shift ;; --target) target="$2"; shift 2 ;; --title) title="$2"; shift 2 ;;
    --prerelease) prerelease=true; shift ;;
    --notes) notes="$2"; shift 2 ;; --notes-file) notes="$(cat "$2")"; shift 2 ;; --repo) shift 2 ;; *) shift ;;
  esac; done
  [[ ! -e "$(release_dir "${tag}")" ]] || { echo "release exists" >&2; exit 1; }
  local dir="$(release_dir "${tag}")"; mkdir -p "${dir}/assets"
  next_id "${STATE_DIR}/next_release_id" > "${dir}/id"
  printf '%s\n' "${tag}" > "${dir}/tag"; printf '%s\n' "${target}" > "${dir}/target_sha"
  printf '%s\n' "${draft}" > "${dir}/draft"; printf 'false\n' > "${dir}/latest"
  printf '%s\n' "${prerelease}" > "${dir}/prerelease"
  printf 'false\n' > "${dir}/immutable"
  printf '%s\n' "${title}" > "${dir}/title"; printf '%s\n' "${notes}" > "${dir}/body"
  mutation "create-release ${tag} draft=${draft}"
}

release_list() {
  local dir include_prerelease=false limit=999999 argument
  while (($#)); do
    argument="$1"
    case "${argument}" in
      --limit) limit="$2"; shift 2 ;;
      *isPrerelease*) include_prerelease=true; shift ;;
      *) shift ;;
    esac
  done
  log "list-releases"
  for dir in "${RELEASES}"/*; do [[ -d "${dir}" ]] || continue
    if [[ "${include_prerelease}" == true ]]; then
      printf '%s\t%s\t%s\t%s\n' "$(cat "${dir}/tag")" "$(cat "${dir}/draft")" \
        "$(cat "${dir}/latest")" "$(cat "${dir}/prerelease")"
    else
      printf '%s\t%s\t%s\n' "$(cat "${dir}/tag")" "$(cat "${dir}/draft")" "$(cat "${dir}/latest")"
    fi
  done | LC_ALL=C sort -k1,1 | awk -v limit="${limit}" 'NR <= limit'
}

release_view() {
  local tag="$1"; shift; local query="" template=""
  while (($#)); do case "$1" in
    --jq) query="$2"; shift 2 ;; --template) template="$2"; shift 2 ;;
    --json|--repo) shift 2 ;; *) shift ;;
  esac; done
  local dir="$(release_dir "${tag}")"; [[ -d "${dir}" ]] || { echo "release not found" >&2; exit 1; }
  log "view-release ${tag}"
  if [[ -n "${template}" ]]; then
    [[ "${template}" == '{{.body}}' ]] || { echo "unsupported release view template: ${template}" >&2; exit 2; }
    cat "${dir}/body"
    return
  fi
  case "${query}" in
    .databaseId|.id) cat "${dir}/id" ;; .tagName) cat "${dir}/tag" ;; .isDraft) cat "${dir}/draft" ;; .isImmutable) cat "${dir}/immutable" ;;
    .isPrerelease) cat "${dir}/prerelease" ;;
    .isLatest) echo "unknown JSON field: isLatest" >&2; exit 2 ;; .targetCommitish) cat "${dir}/target_sha" ;;
    .name) cat "${dir}/title" ;; .body) cat "${dir}/body"; printf '\n' ;;
    *assets*'@tsv'*)
      if [[ "${tag}" == rolling && -f "${dir}/assets/appcast.xml/bytes" ]]; then
        build="$(sed -n 's|.*<sparkle:version>\([0-9][0-9]*\)</sparkle:version>.*|\1|p' "${dir}/assets/appcast.xml/bytes" | head -1)"
        log "verify-rolling rolling ${build}"
        maybe_fail "verify:rolling"
      fi
      local asset; for asset in "${dir}/assets"/*; do [[ -d "${asset}" ]] || continue
        printf '%s\t%s\t%s\t%s\t%s\n' "$(cat "${asset}/id")" "$(basename "${asset}")" \
          "$(cat "${asset}/state")" "$(cat "${asset}/size")" "$(cat "${asset}/digest")"
        if [[ "${tag}" == "${FAKE_GH_DUPLICATE_APPCAST_TAG:-}" && "$(basename "${asset}")" == appcast.xml ]]; then
          printf '%s\t%s\t%s\t%s\t%s\n' "$(cat "${asset}/id")" "$(basename "${asset}")" \
            "$(cat "${asset}/state")" "$(cat "${asset}/size")" "$(cat "${asset}/digest")"
        fi
      done | LC_ALL=C sort -k2,2 ;;
    *) printf '%s\t%s\t%s\t%s\t%s\n' "$(cat "${dir}/id")" "${tag}" "$(cat "${dir}/draft")" \
      "$(cat "${dir}/latest")" "$(cat "${dir}/target_sha")" ;;
  esac
}

release_upload() {
  local tag="$1"; shift; local files=() clobber=false
  while (($#)); do case "$1" in --clobber) clobber=true; shift ;; --repo) shift 2 ;; *) files+=("$1"); shift ;; esac; done
  local file name dir corrupt="${FAKE_GH_CORRUPT_UPLOAD:-}"
  [[ "$(cat "$(release_dir "${tag}")/immutable")" == false ]] || { echo "release is immutable" >&2; exit 1; }
  for file in "${files[@]}"; do
    name="$(basename "${file}")"; dir="$(asset_dir "${tag}" "${name}")"
    if [[ -d "${dir}" && "${clobber}" != true ]]; then echo "asset already exists: ${name}" >&2; exit 1; fi
    if [[ -d "${dir}" ]]; then rm -rf "${dir}"; mutation "delete-asset ${tag} ${name}"; fi
    maybe_fail "upload:${tag}:${name}"
    mkdir -p "${dir}"; next_id "${STATE_DIR}/next_asset_id" > "${dir}/id"; cp "${file}" "${dir}/bytes"
    printf 'uploaded\n' > "${dir}/state"; file_size "${file}" > "${dir}/size"
    printf '%s\n' "$(digest_file "${file}")" > "${dir}/digest"
    case "${corrupt}" in state:${name}) printf 'open\n' > "${dir}/state" ;; size:${name}) printf '1\n' > "${dir}/size" ;;
      digest:${name}) printf 'sha256:deadbeef\n' > "${dir}/digest" ;; esac
    mutation "upload-asset ${tag} ${name}"
    if [[ "${tag}" == rolling && "${name}" == programa-dSYMs-*.zip && -n "${FAKE_GH_EXPOSE_MILESTONE_APPCAST:-}" ]]; then
      milestone_asset="$(asset_dir v0.63.0 appcast.xml)"
      cp "${FAKE_GH_EXPOSE_MILESTONE_APPCAST}" "${milestone_asset}/bytes"
      file_size "${FAKE_GH_EXPOSE_MILESTONE_APPCAST}" > "${milestone_asset}/size"
      printf '%s\n' "$(digest_file "${FAKE_GH_EXPOSE_MILESTONE_APPCAST}")" > "${milestone_asset}/digest"
      log "milestone-appcast-advanced"
    fi
    if [[ "${tag}" == rolling && "${name}" == programa-windows.exe && -n "${FAKE_GH_EXPOSE_MILESTONE_BEFORE_METADATA:-}" ]]; then
      milestone_asset="$(asset_dir v0.63.0 appcast.xml)"
      cp "${FAKE_GH_EXPOSE_MILESTONE_BEFORE_METADATA}" "${milestone_asset}/bytes"
      file_size "${FAKE_GH_EXPOSE_MILESTONE_BEFORE_METADATA}" > "${milestone_asset}/size"
      printf '%s\n' "$(digest_file "${FAKE_GH_EXPOSE_MILESTONE_BEFORE_METADATA}")" > "${milestone_asset}/digest"
      log "milestone-appcast-advanced-before-metadata"
    fi
  done
}

release_download() {
  local tag="$1"; shift; local pattern="" destination="."
  while (($#)); do case "$1" in -p|--pattern) pattern="$2"; shift 2 ;; -D|--dir) destination="$2"; shift 2 ;;
    --repo) shift 2 ;; *) shift ;; esac; done
  maybe_fail "download:${tag}:${pattern}"; mkdir -p "${destination}"
  cp "$(asset_dir "${tag}" "${pattern}")/bytes" "${destination}/${pattern}"
  log "authenticated-download ${tag} ${pattern}"
  if [[ "${tag}" == rolling && "${pattern}" == programa-windows.exe && -n "${FAKE_GH_ADVANCE_MAIN_BEFORE_METADATA:-}" && \
    ! -f "${STATE_DIR}/main_advanced_before_metadata" ]] && \
    grep -Fq 'mutation upload-asset rolling programa-windows.exe' "${LOG}"; then
    printf '%s\n' "${FAKE_GH_ADVANCE_MAIN_BEFORE_METADATA}" > "${STATE_DIR}/main_sha"
    : > "${STATE_DIR}/main_advanced_before_metadata"
    log "main-advanced-before-metadata ${FAKE_GH_ADVANCE_MAIN_BEFORE_METADATA}"
  fi
}

release_delete_asset() {
  local tag="$1" name="$2"
  [[ "$(cat "$(release_dir "${tag}")/immutable")" == false ]] || { echo "release is immutable" >&2; exit 1; }
  rm -rf "$(asset_dir "${tag}" "${name}")"; mutation "delete-asset ${tag} ${name}"
}
release_edit() {
  local tag="$1"; shift; local dir="$(release_dir "${tag}")" title="" body="" draft="" latest="" prerelease="" seal_dir=""
  local was_draft; was_draft="$(cat "${dir}/draft")"
  while (($#)); do case "$1" in
    --title) title="$2"; shift 2 ;; --notes) body="$2"; shift 2 ;; --notes-file) body="$(cat "$2")"; shift 2 ;;
    --draft) draft=false; shift ;; --draft=*) draft="${1#--draft=}"; shift ;;
    --prerelease) prerelease=true; shift ;; --prerelease=*) prerelease="${1#--prerelease=}"; shift ;;
    --latest) latest=true; shift ;; --latest=*) latest="${1#--latest=}"; shift ;; --repo) shift 2 ;; *) shift ;;
  esac; done
  [[ -z "${title}" ]] || printf '%s\n' "${title}" > "${dir}/title"
  [[ -z "${body}" ]] || printf '%s\n' "${body}" > "${dir}/body"
  [[ -z "${draft}" ]] || printf '%s\n' "${draft}" > "${dir}/draft"
  [[ -z "${prerelease}" ]] || printf '%s\n' "${prerelease}" > "${dir}/prerelease"
  if [[ -n "${latest}" ]]; then
    if [[ "${latest}" == true ]]; then
      local other; for other in "${RELEASES}"/*; do [[ -d "${other}" ]] && printf 'false\n' > "${other}/latest"; done
    fi
    printf '%s\n' "${latest}" > "${dir}/latest"
  fi
  mutation "edit-release ${tag} draft=$(cat "${dir}/draft") latest=$(cat "${dir}/latest") prerelease=$(cat "${dir}/prerelease")"
  if [[ "${tag}" == rolling-candidate-* && "${was_draft}" == true && "$(cat "${dir}/draft")" == false ]]; then
    if [[ -n "${FAKE_GH_EXPOSE_MILESTONE_APPCAST:-}" ]]; then
      milestone_asset="$(asset_dir v0.63.0 appcast.xml)"
      cp "${FAKE_GH_EXPOSE_MILESTONE_APPCAST}" "${milestone_asset}/bytes"
      file_size "${FAKE_GH_EXPOSE_MILESTONE_APPCAST}" > "${milestone_asset}/size"
      printf '%s\n' "$(digest_file "${FAKE_GH_EXPOSE_MILESTONE_APPCAST}")" > "${milestone_asset}/digest"
      log "milestone-appcast-advanced"
    fi
    if [[ -n "${FAKE_GH_ADVANCE_MAIN_AFTER_ARCHIVE:-}" ]]; then
      printf '%s\n' "${FAKE_GH_ADVANCE_MAIN_AFTER_ARCHIVE}" > "${STATE_DIR}/main_sha"
      log "main-advanced-after-archive ${FAKE_GH_ADVANCE_MAIN_AFTER_ARCHIVE}"
    fi
    if [[ "${FAKE_GH_SWAP_SEAL_ON_PUBLISH:-}" == "${tag}" ]]; then
      seal_dir="$(asset_dir "${tag}" programa-release-candidate.json)"
      printf '{"swapped":true}\n' > "${seal_dir}/bytes"
      file_size "${seal_dir}/bytes" > "${seal_dir}/size"
      printf '%s\n' "$(digest_file "${seal_dir}/bytes")" > "${seal_dir}/digest"
      log "seal-swapped-on-publish ${tag}"
    fi
  fi
}
release_delete() {
  local tag="$1"; shift
  local yes=false cleanup_tag=false repo=""
  while (($#)); do case "$1" in
    --repo) repo="$2"; shift 2 ;; --yes) yes=true; shift ;; --cleanup-tag) cleanup_tag=true; shift ;;
    *) echo "unsupported fake gh release delete argument: $1" >&2; exit 2 ;;
  esac; done
  [[ -n "${repo}" && "${yes}" == true ]] || { echo "release delete missing required flags" >&2; exit 2; }
  [[ "$(cat "$(release_dir "${tag}")/immutable")" == false ]] || { echo "release is immutable" >&2; exit 1; }
  rm -rf "$(release_dir "${tag}")"; mutation "delete-release ${tag} cleanup-tag=${cleanup_tag}"
}

attestation_verify() {
  local file="$1"; shift
  local repo="" signer_workflow="" source_ref="" source_digest="" deny_self_hosted=false name expected_digest
  while (($#)); do case "$1" in
    --repo) repo="$2"; shift 2 ;; --signer-workflow) signer_workflow="$2"; shift 2 ;;
    --source-ref) source_ref="$2"; shift 2 ;; --deny-self-hosted-runners) deny_self_hosted=true; shift ;;
    --source-digest) source_digest="$2"; shift 2 ;;
    *) echo "unsupported fake gh attestation argument: $1" >&2; exit 2 ;;
  esac; done
  [[ "${repo}" == darkroomengineering/programa ]] || { echo "attestation repo constraint missing" >&2; exit 2; }
  [[ "${signer_workflow}" == darkroomengineering/programa/.github/workflows/release.yml ]] || { echo "attestation signer workflow constraint missing" >&2; exit 2; }
  [[ "${source_ref}" == "${FAKE_GH_EXPECT_SOURCE_REF:-refs/heads/main}" ]] || { echo "attestation source ref constraint missing" >&2; exit 2; }
  expected_digest="$(cat "${STATE_DIR}/main_sha")"
  [[ "${source_digest}" == "${expected_digest}" ]] || { echo "attestation source digest constraint missing or stale" >&2; exit 2; }
  [[ "${deny_self_hosted}" == true ]] || { echo "self-hosted runners were not denied" >&2; exit 2; }
  name="$(basename "${file}")"; log "attestation-verify ${name} source=${source_digest}"
  if [[ "${name}" == programa-release-candidate.json ]] && grep -Fq '"swapped":true' "${file}"; then
    echo "published seal does not match its attestation" >&2
    exit 42
  fi
  if [[ "${FAKE_GH_FAIL_ATTESTATION:-}" == "${name}" ]]; then echo "injected attestation failure: ${name}" >&2; exit 42; fi
}

api_command() {
  local endpoint="" method=GET ref="" sha="" target="" previous="" tag_name="" head_sha="" query="" notes_start=""
  while (($#)); do case "$1" in
    --paginate) shift ;;
    -X|--method) method="$2"; shift 2 ;; -f|-F)
    case "$2" in ref=*) ref="${2#ref=}" ;; sha=*) sha="${2#sha=}" ;;
      target_commitish=*) target="${2#target_commitish=}" ;; previous_tag_name=*) previous="${2#previous_tag_name=}" ;;
      tag_name=*) tag_name="${2#tag_name=}" ;; head_sha=*) head_sha="${2#head_sha=}" ;; esac; shift 2 ;;
    --jq) query="$2"; shift 2 ;; --repo) shift 2 ;;
    *) [[ -z "${endpoint}" ]] && endpoint="$1"; shift ;;
  esac; done
  if [[ -z "${head_sha}" && "${endpoint}" == *head_sha=* ]]; then
    head_sha="${endpoint#*head_sha=}"; head_sha="${head_sha%%&*}"
  fi
  case "${endpoint}:${method}" in
    */immutable-releases:*)
      log "forbidden-immutable-releases-endpoint"
      echo "the workflow token has no Administration permission" >&2
      exit 86 ;;
    */releases\?per_page=100:GET)
      local release
      log "api-list-releases-paginated"
      # One paginated REST snapshot supplies every release-state field needed
      # for discovery and verification: tag, draft, prerelease, immutable, SHA.
      for release in "${RELEASES}"/*; do
        [[ -d "${release}" ]] || continue
        printf '%s\t%s\t%s\t%s\t%s\n' \
          "$(cat "${release}/tag")" \
          "$(cat "${release}/draft")" \
          "$(cat "${release}/prerelease")" \
          "$(cat "${release}/immutable")" \
          "$(cat "${release}/target_sha")"
      done | LC_ALL=C sort -k1,1 ;;
    */git/ref/heads/main:GET|*/git/refs/heads/main:GET)
      local current_main; current_main="$(cat "${STATE_DIR}/main_sha")"
      printf '%s\n' "${current_main}"; log "read-main-ref ${current_main}" ;;
    */git/ref/tags/*:GET)
      local tag="${endpoint##*/tags/}" observed
      [[ ! -f "$(release_dir "${tag}")/missing_ref" ]] || { echo "ref not found" >&2; exit 1; }
      observed="$(cat "$(release_dir "${tag}")/target_sha")"
      printf '%s\n' "${observed}"; log "read-ref ${tag} ${observed}" ;;
    */git/refs/tags/*:PATCH)
      local tag="${endpoint##*/tags/}"
      [[ ! -f "$(release_dir "${tag}")/missing_ref" ]] || { echo "ref not found" >&2; exit 1; }
      printf '%s\n' "${sha}" > "$(release_dir "${tag}")/target_sha"
      mutation "move-ref ${tag} ${sha}" ;;
    */git/refs:POST)
      [[ "${ref}" == refs/tags/* ]] || { echo "unsupported ref create: ${ref}" >&2; exit 2; }
      local created_tag="${ref#refs/tags/}"
      printf '%s\n' "${sha}" > "$(release_dir "${created_tag}")/target_sha"
      rm -f "$(release_dir "${created_tag}")/missing_ref"
      mutation "move-ref ${created_tag} ${sha}" ;;
    */releases/generate-notes:POST)
      [[ -n "${tag_name}" ]] || { echo "generate-notes requires tag_name" >&2; exit 2; }
      log "generate-notes tag=${tag_name} target=${target} previous=${previous}"
      notes_start="${previous}"
      if [[ "${previous}" == rolling && -d "$(release_dir rolling)" ]]; then
        notes_start="$(cat "$(release_dir rolling)/target_sha")"
      fi
      printf 'Generated notes from %s to %s\n' "${notes_start}" "${target}"
      if [[ -n "${FAKE_GH_ADVANCE_MAIN_DURING_NOTES:-}" ]]; then
        printf '%s\n' "${FAKE_GH_ADVANCE_MAIN_DURING_NOTES}" > "${STATE_DIR}/main_sha"
        log "main-advanced-during-notes ${FAKE_GH_ADVANCE_MAIN_DURING_NOTES}"
      fi ;;
    */actions/workflows/*ci.yml/runs*:GET|*/actions/runs*:GET)
      [[ "${head_sha}" =~ ^[a-f0-9]{40}$ ]] || { echo "workflow-runs query requires sealed head_sha" >&2; exit 2; }
      log "ci-runs head=${head_sha}"
      if [[ -n "${query}" ]]; then
        [[ "${FAKE_GH_CI_RESULT:-success}" == success ]] && printf '1\n' || printf '0\n'
      elif [[ "${FAKE_GH_CI_RESULT:-success}" == success ]]; then
        printf '{"workflow_runs":[{"status":"completed","conclusion":"success","event":"push","head_branch":"main","head_sha":"%s","path":".github/workflows/ci.yml"}]}\n' "${head_sha}"
      else
        printf '{"workflow_runs":[]}\n'
      fi ;;
    *) echo "unsupported fake gh api: ${method} ${endpoint}" >&2; exit 2 ;;
  esac
}

command="${1:-}"; shift || true
case "${command}" in
  release) sub="${1:-}"; shift || true; case "${sub}" in
    create) release_create "$@" ;; list) release_list "$@" ;; view) release_view "$@" ;; upload) release_upload "$@" ;;
    download) release_download "$@" ;; delete-asset) release_delete_asset "$@" ;; edit) release_edit "$@" ;;
    delete) release_delete "$@" ;; *) echo "unsupported fake gh release command: ${sub}" >&2; exit 2 ;; esac ;;
  attestation) sub="${1:-}"; shift || true; [[ "${sub}" == verify ]] || { echo "unsupported fake gh attestation command" >&2; exit 2; }; attestation_verify "$@" ;;
  api) api_command "$@" ;; *) echo "unsupported fake gh command: ${command}" >&2; exit 2 ;;
esac
FAKE_GH_EOF
chmod +x "${FAKE_GH}"

for build in 100 101 102 103 104 105 200 201; do make_fixture "${build}" "0.64.73"; done

seed_sealed_candidate() {
  local build="$1" version="${2:-0.64.73}" refresh_fixture="${3:-true}" dir role path name size digest entries=""
  local tag="rolling-candidate-${build}"
  # Archived payload URLs are self-contained at the candidate's permanent tag;
  # rolling contains only the mutable feed and stable DMG alias.
  [[ "${refresh_fixture}" != true ]] || make_fixture "${build}" "${version}" "${tag}"
  write_release "${tag}" "$(target_sha_for "${build}")" true false "Candidate ${build}" candidate
  printf '%s\n' "$((build + 500))" > "$(release_dir "${tag}")/id"
  while IFS='=' read -r role path; do
    name="$(basename "${path}")"; write_asset "${tag}" "${name}" "${path}"
    printf '%s\n' "$((build * 10 + ${#entries}))" > "$(asset_dir "${tag}" "${name}")/id"
    size="$(file_size "${path}")"; digest="$(sha256_file "${path}")"; [[ -z "${entries}" ]] || entries+=","
    entries+="{\"name\":\"${name}\",\"role\":\"${role}\",\"size\":${size},\"sha256\":\"${digest}\"}"
  done < <(fixture_roles "${build}")
  dir="${TMP_DIR}/seal-${build}.json"
  printf '{"schemaVersion":2,"sealed":true,"targetSha":"%s","version":"%s","build":"%s","assets":[%s]}\n' \
    "$(target_sha_for "${build}")" "${version}" "${build}" "${entries}" > "${dir}"
  write_asset "${tag}" "${SEAL_NAME}" "${dir}"
  printf '%s\n' "$((build * 10 + 9))" > "$(asset_dir "${tag}" "${SEAL_NAME}")/id"
  printf '%s\n' "$(target_sha_for "${build}")" > "${STATE_DIR}/main_sha"
}

stage_archive_candidate() {
  local build="$1" version="${2:-0.64.73}"
  local tag="rolling-candidate-${build}"
  make_fixture "${build}" "${version}" "${tag}"
  invoke_candidate "${build}" "${version}" "" rolling-candidate- "${tag}"
  printf '%s\n' "$(target_sha_for "${build}")" > "${STATE_DIR}/main_sha"
}

seed_rolling() {
  local build="$1" draft="${2:-false}" latest="${3:-true}" role path
  write_release rolling "$(target_sha_for "${build}")" "${draft}" "${latest}" "Rolling 0.64.73" "notes-${build}"
  printf '42\n' > "$(release_dir rolling)/id"
  while IFS='=' read -r role path; do write_asset rolling "$(basename "${path}")" "${path}"; done < <(fixture_roles "${build}")
}

seed_release_decoys() {
  local count="$1" index tag
  for ((index = 1; index <= count; index += 1)); do
    printf -v tag 'archive-decoy-%04d' "${index}"
    write_release "${tag}" "$(target_sha_for "$((1000 + index))")" true false "Decoy ${index}" decoy
  done
}

seed_milestone() {
  local build="$1"
  local source="${2:-${FIXTURE_DIR}/${build}/appcast.xml}"
  write_release v0.63.0 "$(target_sha_for "${build}")" false false 'Milestone 0.63.0' milestone
  printf '63\n' > "$(release_dir v0.63.0)/id"
  write_asset v0.63.0 appcast.xml "${source}"
}

seed_milestone_tag() {
  local tag="$1" build="$2"
  local source="${3:-${FIXTURE_DIR}/${build}/appcast.xml}"
  write_release "${tag}" "$(target_sha_for "${build}")" false false "Milestone ${tag#v}" milestone
  write_asset "${tag}" appcast.xml "${source}"
}

assert_candidate_sealed() {
  local build="$1" version="${2:-0.64.73}" seal local_seal
  local tag="${3:-rolling-candidate-${build}}"
  seal="$(asset_dir "${tag}" "${SEAL_NAME}")/bytes"; assert_release_exists "${tag}"
  local_seal="$(seal_output_for "${tag}")"
  assert_file_equals "$(release_dir "${tag}")/draft" true; [[ -f "${seal}" ]] || fail "candidate ${build} is not sealed"
  [[ -f "${local_seal}" ]] || fail "candidate ${build} did not write its requested local seal output"
  cmp -s "${local_seal}" "${seal}" || fail "candidate ${build} local seal bytes differ from the uploaded seal"
  assert_file_equals "$(release_dir "${tag}")/target_sha" "$(target_sha_for "${build}")"
  node -e '
    const fs = require("node:fs"); const crypto = require("node:crypto");
    const [seal, build, version, assetRoot] = process.argv.slice(1);
    const value = JSON.parse(fs.readFileSync(seal, "utf8"));
    if (Object.keys(value).sort().join(",") !== "assets,build,schemaVersion,sealed,targetSha,version") process.exit(1);
    const expectedSha = BigInt(build).toString(16).padStart(40, "0");
    if (value.schemaVersion !== 2 || value.sealed !== true || value.build !== build || value.version !== version || value.targetSha !== expectedSha) process.exit(1);
    if (!Array.isArray(value.assets) || value.assets.length !== 6) process.exit(1);
    const expected = new Map([
      [`programa-macos-${build}.dmg`, "immutable"], [`programa-dSYMs-${build}.zip`, "immutable"],
      [`programa-windows-${build}.exe`, "immutable"], ["appcast.xml", "appcast"],
      ["programa-macos.dmg", "stable-alias"], ["programa-windows.exe", "stable-alias"],
    ]);
    for (const a of value.assets) {
      if (Object.keys(a).sort().join(",") !== "name,role,sha256,size") process.exit(1);
      const bytes = fs.readFileSync(`${assetRoot}/${a.name}/bytes`);
      if (expected.get(a.name) !== a.role || a.size !== bytes.length || a.sha256 !== crypto.createHash("sha256").update(bytes).digest("hex")) process.exit(1);
      expected.delete(a.name);
    }
    if (expected.size !== 0) process.exit(1);
  ' "${seal}" "${build}" "${version}" "$(release_dir "${tag}")/assets" || fail "candidate ${build} seal has invalid contents"
}

assert_rolling_converged() {
  local build="$1"
  assert_release_exists rolling; assert_file_equals "$(release_dir rolling)/target_sha" "$(target_sha_for "${build}")"
  assert_file_equals "$(release_dir rolling)/draft" false; assert_file_equals "$(release_dir rolling)/latest" true
  assert_asset_equals rolling appcast.xml "${FIXTURE_DIR}/${build}/appcast.xml"
  assert_asset_equals rolling programa-macos.dmg "${FIXTURE_DIR}/${build}/programa-macos.dmg"
  assert_asset_equals rolling programa-windows.exe "${FIXTURE_DIR}/${build}/programa-windows.exe"
}

# Candidates are never published: the just-promoted one is retained only as a
# draft (a private rollback archive invisible on the releases page).
assert_published_archive() {
  local build="$1"
  local tag="rolling-candidate-${build}"
  assert_release_exists "${tag}"
  assert_file_equals "$(release_dir "${tag}")/draft" true
  assert_asset_count "${tag}" 7
}

# A prepared seal is a durable handoff between build and staging. Preparation
# is local-only, while staging authenticates those exact bytes before the first
# candidate mutation and makes the seal the final upload.
reset_state
make_fixture 104 0.64.73 rolling
prepare_candidate 104 0.64.73
rolling_prepared_seal="$(seal_output_for rolling-candidate-104)"
[[ -s "${rolling_prepared_seal}" ]] || fail "rolling prepare did not write a seal"
! grep -q '^mutation ' "${STATE_DIR}/operations.log" || fail "rolling seal preparation mutated GitHub"
cp "${rolling_prepared_seal}" "${TMP_DIR}/rolling-prepared-seal.snapshot"
: > "${STATE_DIR}/operations.log"
stage_prepared_candidate 104 0.64.73
assert_candidate_sealed 104 0.64.73
cmp -s "${TMP_DIR}/rolling-prepared-seal.snapshot" "${rolling_prepared_seal}" || fail "rolling staging rewrote the prepared seal"
grep '^mutation upload-asset rolling-candidate-104 ' "${STATE_DIR}/operations.log" > "${TMP_DIR}/rolling-prepared-uploads"
[[ "$(wc -l < "${TMP_DIR}/rolling-prepared-uploads" | tr -d ' ')" == 7 ]] || fail "rolling prepared staging did not upload the exact payload set plus seal"
! sed -n '1,6p' "${TMP_DIR}/rolling-prepared-uploads" | grep -Fq " ${SEAL_NAME}" || fail "rolling prepared seal was uploaded before all payloads"
[[ "$(tail -1 "${TMP_DIR}/rolling-prepared-uploads")" == *" ${SEAL_NAME}" ]] || fail "rolling prepared seal was not uploaded last"

reset_state
make_fixture 201 1.2.3 v1.2.3
prepare_candidate 201 1.2.3 milestone-candidate- v1.2.3 009
milestone_prepared_seal="$(seal_output_for milestone-candidate-201-009)"
[[ -s "${milestone_prepared_seal}" ]] || fail "milestone prepare did not write a seal"
! grep -q '^mutation ' "${STATE_DIR}/operations.log" || fail "milestone seal preparation mutated GitHub"
cp "${milestone_prepared_seal}" "${TMP_DIR}/milestone-prepared-seal.snapshot"
: > "${STATE_DIR}/operations.log"
stage_prepared_candidate 201 1.2.3 milestone-candidate- v1.2.3 009
assert_candidate_sealed 201 1.2.3 milestone-candidate-201-009
cmp -s "${TMP_DIR}/milestone-prepared-seal.snapshot" "${milestone_prepared_seal}" || fail "milestone staging rewrote the prepared seal"
grep '^mutation upload-asset milestone-candidate-201-009 ' "${STATE_DIR}/operations.log" > "${TMP_DIR}/milestone-prepared-uploads"
[[ "$(wc -l < "${TMP_DIR}/milestone-prepared-uploads" | tr -d ' ')" == 7 ]] || fail "milestone prepared staging did not upload the exact payload set plus seal"
! sed -n '1,6p' "${TMP_DIR}/milestone-prepared-uploads" | grep -Fq " ${SEAL_NAME}" || fail "milestone prepared seal was uploaded before all payloads"
[[ "$(tail -1 "${TMP_DIR}/milestone-prepared-uploads")" == *" ${SEAL_NAME}" ]] || fail "milestone prepared seal was not uploaded last"

# Both kinds of stale handoff fail before candidate mutation: altered seal
# bytes and payload bytes that no longer match the seal prepared for them.
reset_state
make_fixture 105 0.64.73 rolling
prepare_candidate 105 0.64.73
printf ' ' >> "$(seal_output_for rolling-candidate-105)"
: > "${STATE_DIR}/operations.log"
if stage_prepared_candidate 105 0.64.73; then fail "rolling staging accepted modified prepared seal bytes"; fi
! grep -q '^mutation ' "${STATE_DIR}/operations.log" || fail "modified rolling prepared seal mutated candidate state"
assert_release_absent rolling-candidate-105

reset_state
make_fixture 201 1.2.3 v1.2.3
prepare_candidate 201 1.2.3 milestone-candidate- v1.2.3 010
printf 'changed-after-prepare\n' >> "${FIXTURE_DIR}/201/programa-dSYMs-201.zip"
: > "${STATE_DIR}/operations.log"
if stage_prepared_candidate 201 1.2.3 milestone-candidate- v1.2.3 010; then fail "milestone staging accepted payload bytes that differ from its prepared seal"; fi
! grep -q '^mutation ' "${STATE_DIR}/operations.log" || fail "stale milestone prepared seal mutated candidate state"
assert_release_absent milestone-candidate-201-010

# Candidate seal is last; verification downloads are authenticated; payload URLs remain stable.
reset_state
invoke_candidate 100 0.64.73
assert_candidate_sealed 100 0.64.73
last_upload="$(grep 'mutation upload-asset rolling-candidate-100' "${STATE_DIR}/operations.log" | tail -1)"
[[ "${last_upload}" == *" ${SEAL_NAME}" ]] || fail "candidate seal was not uploaded last"
grep -Fq 'authenticated-download rolling-candidate-100' "${STATE_DIR}/operations.log" || fail "candidate was not downloaded for verification"
candidate_appcast="$(asset_dir rolling-candidate-100 appcast.xml)/bytes"
grep -Fq '/releases/download/rolling/' "${candidate_appcast}" || fail "candidate appcast does not target rolling"
! grep -Fq '/releases/download/rolling-candidate-' "${candidate_appcast}" || fail "candidate appcast exposes candidate URL"

# Decoy rolling text cannot conceal an operative URL to another repository or tag.
for poisoned_payload in appcast; do
  reset_state; make_fixture 105 0.64.73
  case "${poisoned_payload}" in appcast) poison_appcast_url 105 ;; esac
  if invoke_candidate 105 0.64.73; then fail "candidate staging accepted poisoned ${poisoned_payload} URL"; fi
  [[ ! -d "$(asset_dir rolling-candidate-105 "${SEAL_NAME}")" ]] || fail "poisoned ${poisoned_payload} candidate was sealed"
done
make_fixture 105 0.64.73

# Sparkle 2.9.4 publishes the build as an item child. Candidate validation
# rejects missing or ambiguous item associations and URL/build disagreement.
for invalid_shape in missing-version duplicate-version duplicate-enclosure mismatched-enclosure; do
  reset_state; make_fixture 105 0.64.73; write_invalid_appcast_item 105 "${invalid_shape}"
  if invoke_candidate 105 0.64.73; then fail "candidate staging accepted ${invalid_shape} appcast item"; fi
  [[ ! -d "$(asset_dir rolling-candidate-105 "${SEAL_NAME}")" ]] || fail "${invalid_shape} appcast candidate was sealed"
done
make_fixture 105 0.64.73

# Retry adds only missing assets and never clobbers existing exact bytes.
reset_state
if invoke_candidate 101 0.64.73 'upload:rolling-candidate-101:appcast.xml'; then fail "candidate interruption was not propagated"; fi
: > "${STATE_DIR}/operations.log"; invoke_candidate 101 0.64.73; assert_candidate_sealed 101 0.64.73
for present in programa-dSYMs-101.zip programa-macos-101.dmg programa-windows-101.exe; do
  ! grep -Eq "(delete-asset|upload-asset) rolling-candidate-101 ${present}$" "${STATE_DIR}/operations.log" || fail "retry clobbered ${present}"
done

# Reconciliation validates operative URLs again instead of trusting a sealed decoy.
for poisoned_payload in appcast; do
  reset_state; make_fixture 105 0.64.73 rolling-candidate-105
  case "${poisoned_payload}" in appcast) poison_appcast_url 105 ;; esac
  seed_sealed_candidate 105 0.64.73 false; seed_rolling 104
  : > "${STATE_DIR}/operations.log"
  if invoke_rolling; then fail "reconciliation accepted poisoned ${poisoned_payload} URL"; fi
  assert_rolling_converged 104; assert_release_exists rolling-candidate-105
  ! grep -Eq '^mutation (upload-asset|delete-asset|edit-release|move-ref) rolling ' "${STATE_DIR}/operations.log" || \
    fail "poisoned ${poisoned_payload} mutated rolling"
done

# A sealed candidate whose stored metadata later becomes corrupt cannot mutate rolling.
for field in state size digest; do
  reset_state; seed_sealed_candidate 102; seed_rolling 101
  case "${field}" in
    state) printf 'open\n' > "$(asset_dir rolling-candidate-102 programa-dSYMs-102.zip)/state" ;;
    size) printf '1\n' > "$(asset_dir rolling-candidate-102 programa-dSYMs-102.zip)/size" ;;
    digest) printf 'sha256:deadbeef\n' > "$(asset_dir rolling-candidate-102 programa-dSYMs-102.zip)/digest" ;;
  esac
  : > "${STATE_DIR}/operations.log"
  if invoke_rolling; then fail "promotion accepted corrupt candidate ${field}"; fi
  assert_rolling_converged 101; assert_release_exists rolling-candidate-102
  ! grep -Eq '^mutation (upload-asset|delete-asset|edit-release|move-ref) rolling ' "${STATE_DIR}/operations.log" || \
    fail "corrupt candidate ${field} mutated rolling"
done

# Conflicting bytes and corrupt state/size/digest block the seal.
reset_state
write_release rolling-candidate-102 "$(target_sha_for 102)" true false 'Candidate 102' candidate; printf '502\n' > "$(release_dir rolling-candidate-102)/id"
wrong="${TMP_DIR}/wrong"; printf 'wrong\n' > "${wrong}"; write_asset rolling-candidate-102 programa-dSYMs-102.zip "${wrong}"
if invoke_candidate 102 0.64.73; then fail "conflicting candidate bytes were accepted"; fi
[[ ! -d "$(asset_dir rolling-candidate-102 "${SEAL_NAME}")" ]] || fail "conflicting candidate was sealed"
for corruption in state:programa-dSYMs-103.zip size:programa-dSYMs-103.zip digest:programa-dSYMs-103.zip; do
  reset_state
  if FAKE_GH_CORRUPT_UPLOAD="${corruption}" invoke_candidate 103 0.64.73; then fail "candidate with corrupt ${corruption%%:*} was sealed"; fi
  [[ ! -d "$(asset_dir rolling-candidate-103 "${SEAL_NAME}")" ]] || fail "corrupt candidate was sealed"
done

# The candidate seal and every downloaded payload must pass the exact
# release-workflow attestation policy and the sealed SHA must have successful CI
# before the first rolling mutation. Candidates never publish, so each is
# attested exactly once.
reset_state
seed_sealed_candidate 103; seed_rolling 102; : > "${STATE_DIR}/operations.log"; invoke_rolling
assert_rolling_converged 103
expected_attestations="$(while IFS='=' read -r role path; do basename "${path}"; done < <(fixture_roles 103) | LC_ALL=C sort)"
expected_attestations="$(printf '%s\n%s\n' "${expected_attestations}" "${SEAL_NAME}" | LC_ALL=C sort)"
actual_attestations="$(sed -n 's/^attestation-verify \([^ ]*\) source=.*/\1/p' "${STATE_DIR}/operations.log" | LC_ALL=C sort)"
[[ "${actual_attestations}" == "${expected_attestations}" ]] || \
  fail "reconciler did not attest every payload plus the seal exactly once"
expected_source="$(target_sha_for 103)"
source_digest_count="$(grep -Fxc "attestation-verify programa-macos-103.dmg source=${expected_source}" "${STATE_DIR}/operations.log")"
[[ "${source_digest_count}" == 1 ]] || fail "payload attestation was not bound to the selected target SHA"
grep -Fxq "attestation-verify ${SEAL_NAME} source=${expected_source}" "${STATE_DIR}/operations.log" || \
  fail "candidate seal attestation was not bound to the selected target SHA"
last_attestation_line="$(grep -n '^attestation-verify ' "${STATE_DIR}/operations.log" | tail -1 | cut -d: -f1)"
ci_line="$(grep -n "^ci-runs head=$(target_sha_for 103)$" "${STATE_DIR}/operations.log" | tail -1 | cut -d: -f1)"
first_rolling_mutation="$(grep -n -E '^mutation (delete-asset|upload-asset|edit-release|move-ref) rolling ' "${STATE_DIR}/operations.log" | head -1 | cut -d: -f1)"
[[ -n "${last_attestation_line}" && -n "${ci_line}" && -n "${first_rolling_mutation}" ]] || \
  fail "provenance ordering evidence is incomplete"
(( last_attestation_line < first_rolling_mutation && ci_line < first_rolling_mutation )) || fail "rolling mutated before provenance gates completed"
! grep -Eq '^mutation edit-release rolling-candidate-103 draft=false' "${STATE_DIR}/operations.log" || \
  fail "reconciler published the selected candidate; candidates must stay drafts"

# One failed payload attestation blocks every rolling mutation and retains the seal.
reset_state
seed_sealed_candidate 103; seed_rolling 102; : > "${STATE_DIR}/operations.log"
if FAKE_GH_FAIL_ATTESTATION=programa-dSYMs-103.zip invoke_rolling; then fail "failed payload attestation was ignored"; fi
assert_rolling_converged 102; assert_release_exists rolling-candidate-103
! grep -Eq '^mutation (upload-asset|delete-asset|edit-release|move-ref) rolling ' "${STATE_DIR}/operations.log" || fail "attestation failure mutated rolling"

reset_state
seed_sealed_candidate 103; seed_rolling 102; : > "${STATE_DIR}/operations.log"
if FAKE_GH_FAIL_ATTESTATION="${SEAL_NAME}" invoke_rolling; then fail "failed candidate seal attestation was ignored"; fi
assert_rolling_converged 102; assert_release_exists rolling-candidate-103
! grep -Eq '^mutation (upload-asset|delete-asset|edit-release|move-ref) rolling ' "${STATE_DIR}/operations.log" || fail "seal attestation failure mutated rolling"

# A matching SHA without completed successful main-push CI is not promotable.
reset_state
seed_sealed_candidate 103; seed_rolling 102; : > "${STATE_DIR}/operations.log"
if FAKE_GH_CI_RESULT=none invoke_rolling; then fail "candidate without successful CI was promoted"; fi
grep -Fq "ci-runs head=$(target_sha_for 103)" "${STATE_DIR}/operations.log" || fail "sealed target SHA was not queried in Actions"
assert_rolling_converged 102; assert_release_exists rolling-candidate-103
! grep -Eq '^mutation (upload-asset|delete-asset|edit-release|move-ref) rolling ' "${STATE_DIR}/operations.log" || fail "missing CI mutated rolling"

# The sealed target must still be the current main tip before any public state
# changes. A successful historical CI run for an older SHA is not sufficient.
reset_state
seed_sealed_candidate 103; seed_rolling 102
printf '%s\n' "$(target_sha_for 104)" > "${STATE_DIR}/main_sha"
: > "${STATE_DIR}/operations.log"
if invoke_rolling; then fail "candidate whose target is no longer main was promoted"; fi
grep -Fq "read-main-ref $(target_sha_for 104)" "${STATE_DIR}/operations.log" || fail "reconciler did not verify the current main ref"
assert_rolling_converged 102; assert_release_exists rolling-candidate-103
! grep -Eq '^mutation (upload-asset|delete-asset|edit-release|move-ref) rolling ' "${STATE_DIR}/operations.log" || \
  fail "stale-main candidate mutated rolling"

# A reconciler run belongs to one checked-out trigger SHA. It validates every
# visible seal but selects the candidate bound to this run, not the global max.
reset_state
seed_sealed_candidate 103; seed_sealed_candidate 104; seed_rolling 102
printf '%s\n' "$(target_sha_for 103)" > "${STATE_DIR}/main_sha"
: > "${STATE_DIR}/operations.log"
invoke_rolling '' '' "$(target_sha_for 103)"
assert_rolling_converged 103; assert_published_archive 103; assert_release_exists rolling-candidate-104
grep -Fq 'authenticated-download rolling-candidate-103 programa-release-candidate.json' "${STATE_DIR}/operations.log" || \
  fail "matching candidate seal was not validated"
grep -Fq 'authenticated-download rolling-candidate-104 programa-release-candidate.json' "${STATE_DIR}/operations.log" || \
  fail "nonmatching candidate seal was not validated"

# Highest sealed decimal build wins; stale lower drafts prune; higher drafts remain.
reset_state
seed_sealed_candidate 100; seed_sealed_candidate 101; seed_sealed_candidate 103
write_release rolling-candidate-099 "$(target_sha_for 99)" true false 'stale lower draft' stale; printf '599\n' > "$(release_dir rolling-candidate-099)/id"
write_release rolling-candidate-104 "$(target_sha_for 104)" true false 'higher draft' pending; printf '604\n' > "$(release_dir rolling-candidate-104)/id"
seed_rolling 100; invoke_rolling; assert_rolling_converged 103
assert_release_absent rolling-candidate-099; assert_release_absent rolling-candidate-100
assert_release_absent rolling-candidate-101; assert_published_archive 103; assert_release_exists rolling-candidate-104

# Promotion deletes every draft candidate at or below the finalized build
# except the one just selected: retention is always exactly one candidate
# draft (the private rollback archive), regardless of how many stale drafts
# accumulated. A candidate strictly above the finalized build survives, and
# deletion goes through --cleanup-tag so the tag is removed too.
reset_state
seed_sealed_candidate 103
write_release rolling-candidate-050 "$(target_sha_for 50)" true false 'Candidate 50' candidate
write_release rolling-candidate-060 "$(target_sha_for 60)" true false 'Candidate 60' candidate
write_release rolling-candidate-070 "$(target_sha_for 70)" true false 'Candidate 70' candidate
write_release rolling-candidate-104 "$(target_sha_for 104)" true false 'Candidate 104' candidate
seed_rolling 100
: > "${STATE_DIR}/operations.log"
invoke_rolling
assert_rolling_converged 103; assert_published_archive 103
assert_release_absent rolling-candidate-050
assert_release_absent rolling-candidate-060
assert_release_absent rolling-candidate-070
assert_release_exists rolling-candidate-104
grep -Fq 'mutation delete-release rolling-candidate-050 cleanup-tag=true' "${STATE_DIR}/operations.log" || \
  fail "retention did not delete an older candidate draft with --cleanup-tag"
grep -Fq 'mutation delete-release rolling-candidate-060 cleanup-tag=true' "${STATE_DIR}/operations.log" || \
  fail "retention did not delete an older candidate draft with --cleanup-tag"
grep -Fq 'mutation delete-release rolling-candidate-070 cleanup-tag=true' "${STATE_DIR}/operations.log" || \
  fail "retention did not delete the candidate draft just below the finalized build"
! grep -Fq 'mutation delete-release rolling-candidate-104' "${STATE_DIR}/operations.log" || \
  fail "retention deleted a candidate draft above the finalized build"
! grep -Fq 'mutation delete-release rolling-candidate-103' "${STATE_DIR}/operations.log" || \
  fail "retention deleted the just-promoted candidate draft"

# Lower candidates cannot regress rolling's high-water build.
reset_state
seed_sealed_candidate 103; seed_rolling 200; : > "${STATE_DIR}/operations.log"; invoke_rolling; assert_rolling_converged 200
assert_file_equals "$(release_dir rolling)/title" 'Rolling 0.64.73'
assert_file_equals "$(release_dir rolling)/body" 'notes-200'
! grep -Eq 'mutation (upload-asset|delete-asset|move-ref) rolling ' "${STATE_DIR}/operations.log" || fail "older candidate mutated newer rolling"

# An advertised public appcast is authoritative: failed authenticated download
# or malformed XML blocks promotion instead of being treated as absent.
reset_state
seed_sealed_candidate 103; seed_rolling 102; seed_milestone 101; : > "${STATE_DIR}/operations.log"
if invoke_rolling '' 'download:v0.63.0:appcast.xml'; then fail "unavailable milestone appcast was treated as absent"; fi
assert_rolling_converged 102; assert_release_exists rolling-candidate-103
! grep -Eq '^mutation (upload-asset|delete-asset|edit-release|move-ref) rolling ' "${STATE_DIR}/operations.log" || fail "download failure mutated rolling"

malformed_appcast="${TMP_DIR}/malformed-public-appcast.xml"; printf '<rss><channel><item>\n' > "${malformed_appcast}"
reset_state
seed_sealed_candidate 103; seed_rolling 102; seed_milestone 101 "${malformed_appcast}"; : > "${STATE_DIR}/operations.log"
if invoke_rolling; then fail "malformed milestone appcast was treated as absent"; fi
assert_rolling_converged 102; assert_release_exists rolling-candidate-103
! grep -Eq '^mutation (upload-asset|delete-asset|edit-release|move-ref) rolling ' "${STATE_DIR}/operations.log" || fail "malformed public appcast mutated rolling"

# Build order, not semantic milestone tag order, defines the public high-water.
# Every advertised milestone appcast must be authenticated and parsed.
reset_state
seed_sealed_candidate 103; seed_rolling 102
seed_milestone_tag v9.0.0 101
seed_milestone_tag v1.0.0 200
: > "${STATE_DIR}/operations.log"; invoke_rolling
assert_rolling_converged 102; assert_release_absent rolling-candidate-103
grep -Fq 'authenticated-download v1.0.0 appcast.xml' "${STATE_DIR}/operations.log" || fail "lower-semver milestone appcast was not inspected"
! grep -Eq '^mutation (upload-asset|delete-asset|edit-release|move-ref) rolling ' "${STATE_DIR}/operations.log" || fail "candidate below an older-tag milestone build mutated rolling"

reset_state
seed_sealed_candidate 103; seed_rolling 102
seed_milestone_tag v9.0.0 101
seed_milestone_tag v1.0.0 100 "${malformed_appcast}"
: > "${STATE_DIR}/operations.log"
if invoke_rolling; then fail "malformed lower-semver milestone appcast was ignored"; fi
assert_rolling_converged 102; assert_release_exists rolling-candidate-103
! grep -Eq '^mutation (upload-asset|delete-asset|edit-release|move-ref) rolling ' "${STATE_DIR}/operations.log" || fail "malformed lower-semver milestone mutated rolling"

reset_state
seed_sealed_candidate 103; seed_rolling 102
seed_milestone_tag v9.0.0 101
seed_milestone_tag v1.0.0 100
: > "${STATE_DIR}/operations.log"
if invoke_rolling '' 'download:v1.0.0:appcast.xml'; then fail "unreadable lower-semver milestone appcast was ignored"; fi
assert_rolling_converged 102; assert_release_exists rolling-candidate-103
! grep -Eq '^mutation (upload-asset|delete-asset|edit-release|move-ref) rolling ' "${STATE_DIR}/operations.log" || fail "unreadable lower-semver milestone mutated rolling"

# Any published non-draft release that advertises appcast.xml contributes,
# regardless of its tag. Releases without appcast.xml are not public feed state.
reset_state
seed_sealed_candidate 103; seed_rolling 102
seed_milestone_tag customer-preview-2026 200
: > "${STATE_DIR}/operations.log"; invoke_rolling
assert_rolling_converged 102; assert_release_absent rolling-candidate-103
grep -Fq 'authenticated-download customer-preview-2026 appcast.xml' "${STATE_DIR}/operations.log" || \
  fail "arbitrary-tag advertised appcast was not inspected"
! grep -Eq '^mutation (upload-asset|delete-asset|edit-release|move-ref) rolling ' "${STATE_DIR}/operations.log" || \
  fail "candidate below arbitrary-tag high-water mutated rolling"

reset_state
seed_sealed_candidate 103; seed_rolling 102
seed_milestone_tag customer-preview-2026 100 "${malformed_appcast}"
: > "${STATE_DIR}/operations.log"
if invoke_rolling; then fail "malformed arbitrary-tag appcast was ignored"; fi
assert_rolling_converged 102; assert_release_exists rolling-candidate-103
! grep -Eq '^mutation (upload-asset|delete-asset|edit-release|move-ref) rolling ' "${STATE_DIR}/operations.log" || \
  fail "malformed arbitrary-tag appcast mutated rolling"

reset_state
seed_sealed_candidate 103; seed_rolling 102
seed_milestone_tag customer-preview-2026 100
: > "${STATE_DIR}/operations.log"
if invoke_rolling '' 'download:customer-preview-2026:appcast.xml'; then fail "unreadable arbitrary-tag appcast was ignored"; fi
assert_rolling_converged 102; assert_release_exists rolling-candidate-103
! grep -Eq '^mutation (upload-asset|delete-asset|edit-release|move-ref) rolling ' "${STATE_DIR}/operations.log" || \
  fail "unreadable arbitrary-tag appcast mutated rolling"

reset_state
seed_sealed_candidate 103; seed_rolling 102
seed_milestone_tag customer-preview-2026 100
: > "${STATE_DIR}/operations.log"
if FAKE_GH_DUPLICATE_APPCAST_TAG=customer-preview-2026 invoke_rolling; then fail "duplicate arbitrary-tag appcast was ignored"; fi
assert_rolling_converged 102; assert_release_exists rolling-candidate-103
! grep -Eq '^mutation (upload-asset|delete-asset|edit-release|move-ref) rolling ' "${STATE_DIR}/operations.log" || \
  fail "duplicate arbitrary-tag appcast mutated rolling"

reset_state
seed_sealed_candidate 103; seed_rolling 102
write_release archive-without-feed "$(target_sha_for 99)" false false archive archive
: > "${STATE_DIR}/operations.log"; invoke_rolling
assert_rolling_converged 103; assert_published_archive 103

# A promotion seals its build-specific payload in-place before either mutable
# rolling alias changes. Repeated promotions replace only the feed and two aliases, so
# the rolling release's asset count remains bounded while both archives retain
# the exact bytes that older clients may still download.
reset_state
seed_rolling 100
seed_release_decoys 1005
initial_rolling_asset_count="$(find "$(release_dir rolling)/assets" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
stage_archive_candidate 101
stage_archive_candidate 103
prepublication_seal_103="${TMP_DIR}/prepublication-seal-103.json"
cp "$(asset_dir rolling-candidate-103 "${SEAL_NAME}")/bytes" "${prepublication_seal_103}"
: > "${STATE_DIR}/operations.log"
invoke_rolling
assert_published_archive 103
assert_release_absent rolling-candidate-101
assert_rolling_converged 103
assert_asset_count rolling "${initial_rolling_asset_count}"
cmp -s "${prepublication_seal_103}" "$(asset_dir rolling-candidate-103 "${SEAL_NAME}")/bytes" || \
  fail "published archive seal differs from the selected pre-publication seal"
! grep -Fq 'forbidden-immutable-releases-endpoint' "${STATE_DIR}/operations.log" || \
  fail "publisher called the Administration-only immutable-releases endpoint"
! grep -Eq '^view-release archive-decoy-' "${STATE_DIR}/operations.log" || \
  fail "publisher performed per-release views for paginated historical decoys"
! grep -Eq '^mutation edit-release rolling-candidate-(101|103) draft=false' "${STATE_DIR}/operations.log" || \
  fail "promotion published the selected candidate; candidates must stay drafts"
! grep -Eq '^mutation (upload-asset|delete-asset) rolling-candidate-103 ' "${STATE_DIR}/operations.log" || \
  fail "promotion rewrote selected archive assets"
if grep -E '^mutation (upload-asset|delete-asset) rolling ' "${STATE_DIR}/operations.log" | \
  grep -Ev ' rolling (appcast.xml|programa-macos.dmg|programa-windows.exe)$'; then
  fail "promotion copied build-specific assets into rolling"
fi

stage_archive_candidate 104
: > "${STATE_DIR}/operations.log"
invoke_rolling
assert_published_archive 103
assert_published_archive 104
assert_rolling_converged 104
assert_asset_count rolling "${initial_rolling_asset_count}"
! grep -Fq 'forbidden-immutable-releases-endpoint' "${STATE_DIR}/operations.log" || \
  fail "repeated publisher called the Administration-only immutable-releases endpoint"
! grep -Eq '^view-release archive-decoy-' "${STATE_DIR}/operations.log" || \
  fail "repeated publisher performed per-release views for paginated historical decoys"
! grep -Eq '^mutation (upload-asset|delete-asset) rolling-candidate-104 ' "${STATE_DIR}/operations.log" || \
  fail "repeated promotion rewrote selected archive assets"
if grep -E '^mutation (upload-asset|delete-asset) rolling ' "${STATE_DIR}/operations.log" | \
  grep -Ev ' rolling (appcast.xml|programa-macos.dmg|programa-windows.exe)$'; then
  fail "repeated promotion grew rolling with build-specific assets"
fi

# Equal build repairs only the mutable feed and stable DMG alias. Existing
# build-specific rolling assets are legacy compatibility state and are neither
# added nor rewritten by new promotions.
reset_state
seed_sealed_candidate 103; seed_rolling 103
rm -rf "$(asset_dir rolling appcast.xml)"
printf 'wrong stable\n' > "$(asset_dir rolling programa-macos.dmg)/bytes"; printf 'sha256:wrong\n' > "$(asset_dir rolling programa-macos.dmg)/digest"
printf 'wrong dsym\n' > "$(asset_dir rolling programa-dSYMs-103.zip)/bytes"; printf 'sha256:wrong\n' > "$(asset_dir rolling programa-dSYMs-103.zip)/digest"
: > "${STATE_DIR}/operations.log"; invoke_rolling; assert_rolling_converged 103
assert_file_equals "$(asset_dir rolling programa-dSYMs-103.zip)/digest" 'sha256:wrong'
! grep -Eq '^mutation (upload-asset|delete-asset) rolling programa-dSYMs-103.zip$' "${STATE_DIR}/operations.log" || \
  fail "equal-build repair rewrote a legacy build-specific rolling asset"

# Hard-stop after every observed public mutation; retry converges without rollback.
reset_state
seed_sealed_candidate 102; seed_rolling 101; invoke_rolling; mutation_total="$(cat "${STATE_DIR}/mutation_count")"
(( mutation_total > 0 )) || fail "promotion performed no public mutations"
ref_moved_retry_observed=false
for stop_after in $(seq 1 "${mutation_total}"); do
  reset_state; seed_sealed_candidate 102; seed_rolling 101
  if invoke_rolling "${stop_after}"; then fail "hard stop ${stop_after} was not propagated"; fi
  preserve_published_metadata=false
  if [[ "$(cat "$(release_dir rolling)/target_sha")" == "$(target_sha_for 102)" ]]; then
    preserve_published_metadata=true
    ref_moved_retry_observed=true
    published_title_before_retry="$(cat "$(release_dir rolling)/title")"
    published_body_before_retry="$(cat "$(release_dir rolling)/body")"
    [[ -n "${published_body_before_retry}" ]] || fail "ref moved without nonempty release notes"
    [[ "${published_body_before_retry}" != "Generated notes from $(target_sha_for 102) to $(target_sha_for 102)" ]] || \
      fail "first publication already contained selected-to-selected notes"
  fi
  assert_release_exists rolling-candidate-102
  rm -f "${STATE_DIR}/mutation_count"; invoke_rolling
  assert_rolling_converged 102; assert_published_archive 102
  if [[ "${preserve_published_metadata}" == true ]]; then
    assert_file_equals "$(release_dir rolling)/title" "${published_title_before_retry}"
    assert_file_equals "$(release_dir rolling)/body" "${published_body_before_retry}"
  fi
  verify_line="$(grep -n 'verify-rolling rolling 102' "${STATE_DIR}/operations.log" | tail -1 | cut -d: -f1)"
  [[ -n "${verify_line}" ]] || fail "retry omitted final rolling verification"
  ! grep -Fq 'mutation delete-release rolling-candidate-102' "${STATE_DIR}/operations.log" || \
    fail "retry deleted the selected published archive"
done
[[ "${ref_moved_retry_observed}" == true ]] || fail "hard-stop matrix never exercised retry after the rolling ref moved"

# A milestone that advances after archive publication is a second high-water gate.
# It must stop aliases, metadata, and the ref while retaining the candidate.
reset_state
seed_sealed_candidate 103; seed_rolling 102; seed_milestone 101; : > "${STATE_DIR}/operations.log"
FAKE_GH_EXPOSE_MILESTONE_APPCAST="${FIXTURE_DIR}/104/appcast.xml" invoke_rolling || race_status=$?
[[ "${race_status:-0}" -ne 0 ]] || fail "higher milestone race did not stop reconciliation"
grep -Fq 'milestone-appcast-advanced' "${STATE_DIR}/operations.log" || fail "milestone race hook was not reached"
assert_asset_equals rolling appcast.xml "${FIXTURE_DIR}/102/appcast.xml"
assert_asset_equals rolling programa-macos.dmg "${FIXTURE_DIR}/102/programa-macos.dmg"
assert_file_equals "$(release_dir rolling)/title" 'Rolling 0.64.73'
assert_file_equals "$(release_dir rolling)/body" 'notes-102'
assert_file_equals "$(release_dir rolling)/target_sha" "$(target_sha_for 102)"
assert_release_exists rolling-candidate-103
hook_line="$(grep -n 'milestone-appcast-advanced' "${STATE_DIR}/operations.log" | tail -1 | cut -d: -f1)"
if tail -n "+${hook_line}" "${STATE_DIR}/operations.log" | grep -Eq '^mutation (delete-asset|upload-asset) rolling (appcast.xml|programa-macos.dmg|programa-windows.exe)$|^mutation (edit-release|move-ref) rolling'; then
  fail "milestone race mutated aliases, metadata, or ref"
fi

# Main can advance after the initial provenance gate. A recheck after
# archive publication must stop before appcast or stable-alias mutation.
reset_state
seed_sealed_candidate 103; seed_rolling 102; : > "${STATE_DIR}/operations.log"
unset archive_main_race_status
FAKE_GH_ADVANCE_MAIN_AFTER_ARCHIVE="$(target_sha_for 104)" invoke_rolling || archive_main_race_status=$?
[[ "${archive_main_race_status:-0}" -ne 0 ]] || fail "post-archive main advancement did not stop reconciliation"
grep -Fq "main-advanced-after-archive $(target_sha_for 104)" "${STATE_DIR}/operations.log" || fail "post-archive main race hook was not reached"
assert_asset_equals rolling appcast.xml "${FIXTURE_DIR}/102/appcast.xml"
assert_asset_equals rolling programa-macos.dmg "${FIXTURE_DIR}/102/programa-macos.dmg"
assert_file_equals "$(release_dir rolling)/title" 'Rolling 0.64.73'
assert_file_equals "$(release_dir rolling)/target_sha" "$(target_sha_for 102)"
assert_release_exists rolling-candidate-103
archive_main_hook_line="$(grep -n 'main-advanced-after-archive' "${STATE_DIR}/operations.log" | tail -1 | cut -d: -f1)"
if tail -n "+${archive_main_hook_line}" "${STATE_DIR}/operations.log" | grep -Eq '^mutation (delete-asset|upload-asset) rolling (appcast.xml|programa-macos.dmg|programa-windows.exe)$|^mutation (edit-release|move-ref) rolling'; then
  fail "post-archive main race mutated aliases, metadata, or ref"
fi

# A final high-water check immediately before publication prevents metadata,
# latest status, and the ref from advancing after aliases were reconciled.
reset_state
seed_sealed_candidate 103; seed_rolling 102; seed_milestone 101; : > "${STATE_DIR}/operations.log"
FAKE_GH_EXPOSE_MILESTONE_BEFORE_METADATA="${FIXTURE_DIR}/104/appcast.xml" invoke_rolling || final_race_status=$?
[[ "${final_race_status:-0}" -ne 0 ]] || fail "pre-publication milestone race did not stop reconciliation"
grep -Fq 'milestone-appcast-advanced-before-metadata' "${STATE_DIR}/operations.log" || fail "pre-publication race hook was not reached"
assert_file_equals "$(release_dir rolling)/title" 'Rolling 0.64.73'
assert_file_equals "$(release_dir rolling)/body" 'notes-102'
assert_file_equals "$(release_dir rolling)/latest" true
assert_file_equals "$(release_dir rolling)/target_sha" "$(target_sha_for 102)"
assert_release_exists rolling-candidate-103
final_hook_line="$(grep -n 'milestone-appcast-advanced-before-metadata' "${STATE_DIR}/operations.log" | tail -1 | cut -d: -f1)"
if tail -n "+${final_hook_line}" "${STATE_DIR}/operations.log" | grep -Eq '^mutation (edit-release|move-ref) rolling'; then
  fail "pre-publication race changed metadata, latest status, or ref"
fi

# Main can also advance after alias bytes verify. The final pre-publication
# recheck must preserve metadata, latest status, and the tag ref.
reset_state
seed_sealed_candidate 103; seed_rolling 102; : > "${STATE_DIR}/operations.log"
unset final_main_race_status
FAKE_GH_ADVANCE_MAIN_BEFORE_METADATA="$(target_sha_for 104)" invoke_rolling || final_main_race_status=$?
[[ "${final_main_race_status:-0}" -ne 0 ]] || fail "pre-metadata main advancement did not stop reconciliation"
grep -Fq "main-advanced-before-metadata $(target_sha_for 104)" "${STATE_DIR}/operations.log" || fail "pre-metadata main race hook was not reached"
assert_asset_equals rolling appcast.xml "${FIXTURE_DIR}/103/appcast.xml"
assert_asset_equals rolling programa-macos.dmg "${FIXTURE_DIR}/103/programa-macos.dmg"
assert_file_equals "$(release_dir rolling)/title" 'Rolling 0.64.73'
assert_file_equals "$(release_dir rolling)/body" 'notes-102'
assert_file_equals "$(release_dir rolling)/latest" true
assert_file_equals "$(release_dir rolling)/target_sha" "$(target_sha_for 102)"
assert_release_exists rolling-candidate-103
final_main_hook_line="$(grep -n 'main-advanced-before-metadata' "${STATE_DIR}/operations.log" | tail -1 | cut -d: -f1)"
if tail -n "+${final_main_hook_line}" "${STATE_DIR}/operations.log" | grep -Eq '^mutation (edit-release|move-ref) rolling'; then
  fail "pre-metadata main race changed metadata, latest status, or ref"
fi

# Notes generation is an external call and can race with main advancing. The
# publisher must recheck main after notes return and before metadata/ref writes.
reset_state
seed_sealed_candidate 103; seed_rolling 102; : > "${STATE_DIR}/operations.log"
unset notes_main_race_status
FAKE_GH_ADVANCE_MAIN_DURING_NOTES="$(target_sha_for 104)" invoke_rolling || notes_main_race_status=$?
[[ "${notes_main_race_status:-0}" -ne 0 ]] || fail "main advancement during notes did not stop publication"
grep -Fq "main-advanced-during-notes $(target_sha_for 104)" "${STATE_DIR}/operations.log" || fail "notes main-race hook was not reached"
assert_file_equals "$(release_dir rolling)/title" 'Rolling 0.64.73'
assert_file_equals "$(release_dir rolling)/body" 'notes-102'
assert_file_equals "$(release_dir rolling)/target_sha" "$(target_sha_for 102)"
assert_release_exists rolling-candidate-103
notes_main_hook_line="$(grep -n 'main-advanced-during-notes' "${STATE_DIR}/operations.log" | tail -1 | cut -d: -f1)"
if tail -n "+${notes_main_hook_line}" "${STATE_DIR}/operations.log" | grep -Eq '^mutation (edit-release|move-ref) rolling'; then
  fail "notes main race changed metadata or ref"
fi

# Generated notes use the rolling SHA observed at start; metadata/latest precede the final ref move.
reset_state
seed_sealed_candidate 103; seed_rolling 102; invoke_rolling
grep -Fq "generate-notes tag=rolling-next target=$(target_sha_for 103) previous=rolling" "${STATE_DIR}/operations.log" || fail "existing rolling notes used the wrong tags"
read_ref_line="$(grep -n "read-ref rolling $(target_sha_for 102)" "${STATE_DIR}/operations.log" | head -1 | cut -d: -f1)"
notes_line="$(grep -n 'generate-notes tag=rolling-next' "${STATE_DIR}/operations.log" | head -1 | cut -d: -f1)"
(( read_ref_line < notes_line )) || fail "notes were generated before reading the starting rolling ref"
metadata_line="$(grep -n 'mutation edit-release rolling' "${STATE_DIR}/operations.log" | tail -1 | cut -d: -f1)"
tag_line="$(grep -n "mutation move-ref rolling $(target_sha_for 103)" "${STATE_DIR}/operations.log" | tail -1 | cut -d: -f1)"
(( metadata_line < tag_line )) || fail "rolling tag moved before metadata/latest"

# Rolling is a pre-existing legacy mutable release. Missing or immutable state
# cannot be bootstrapped/repaired by the reconciler.
reset_state
seed_sealed_candidate 100; : > "${STATE_DIR}/operations.log"
if invoke_rolling; then fail "missing legacy rolling release was bootstrapped"; fi
assert_release_absent rolling; assert_release_exists rolling-candidate-100
! grep -Eq '^mutation (create-release|upload-asset|edit-release|move-ref) rolling' "${STATE_DIR}/operations.log" || \
  fail "missing rolling release caused public mutation"

reset_state
seed_sealed_candidate 101; seed_rolling 100
printf 'true\n' > "$(release_dir rolling)/immutable"
: > "${STATE_DIR}/operations.log"
if invoke_rolling; then fail "immutable rolling release was accepted"; fi
assert_rolling_converged 100; assert_release_exists rolling-candidate-101
! grep -Eq '^mutation (upload-asset|delete-asset|edit-release|move-ref) rolling ' "${STATE_DIR}/operations.log" || \
  fail "immutable rolling release was mutated"

# Fully converged retry performs no asset writes.
reset_state; seed_sealed_candidate 100; seed_rolling 100; : > "${STATE_DIR}/operations.log"; rm -f "${STATE_DIR}/mutation_count"; invoke_rolling; assert_rolling_converged 100
while IFS='=' read -r role path; do assert_no_asset_write "$(basename "${path}")"; done < <(fixture_roles 100)

echo "PASS: sealed-archive-backed rolling publication is bounded, monotonic, and retry-convergent"
