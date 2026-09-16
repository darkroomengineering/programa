#!/usr/bin/env bash
set -euo pipefail

# Black-box contract for scripts/publish_milestone_release.sh:
#
#   GH_BIN=/path/to/gh GITHUB_REPOSITORY=owner/repo \
#     scripts/publish_milestone_release.sh \
#       --tag vX.Y.Z --target-sha <40-lowercase-hex> \
#       --build <canonical-positive-decimal> --payload-dir <directory>
#
# External workflow concurrency serializes calls. The helper verifies the local
# milestone manifest before GitHub mutation, then converges one permanent
# release without overwriting conflicting public bytes.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="${ROOT_DIR}/scripts/publish_milestone_release.sh"
MODULE="${ROOT_DIR}/scripts/milestone_payload.js"
REPOSITORY="darkroomengineering/programa"
TAG="v1.2.3"
BUILD="41"
TARGET_SHA="$(printf '%040x' 41)"
MANIFEST_NAME="programa-milestone-payload.json"
ED25519_SIGNATURE="AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQ=="

[[ -x "${HELPER}" ]] || { echo "FAIL: missing executable milestone publisher" >&2; exit 1; }
[[ -r "${MODULE}" ]] || { echo "FAIL: missing milestone payload module" >&2; exit 1; }

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/programa-milestone-publication.XXXXXX")"
trap 'rm -rf "${TMP_DIR}"' EXIT
STATE_DIR="${TMP_DIR}/state"
FAKE_GH="${TMP_DIR}/gh"
RUN_OUTPUT="${TMP_DIR}/run.out"

fail() { echo "FAIL: $*" >&2; exit 1; }
file_size() { stat -c '%s' "$1" 2>/dev/null || stat -f '%z' "$1"; }
sha256_file() { shasum -a 256 "$1" | awk '{print $1}'; }
release_dir() { printf '%s/releases/%s' "${STATE_DIR}" "$1"; }
asset_dir() { printf '%s/assets/%s' "$(release_dir "$1")" "$2"; }

payload_names() {
  local build="$1"
  printf '%s\n' \
    "programa-macos-${build}.dmg" \
    "programa-dSYMs-${build}.zip" \
    "programa-windows-${build}.exe" \
    appcast.xml \
    programa-macos.dmg \
    programa-windows.exe
}

prepare_payload() {
  local directory="$1" build="$2" index=0 name release_url enclosure_size
  mkdir -p "${directory}"
  while IFS= read -r name; do
    printf 'payload-%s-%s\n' "${index}" "${name}" > "${directory}/${name}"
    index=$((index + 1))
  done < <(payload_names "${build}")
  cp "${directory}/programa-macos-${build}.dmg" "${directory}/programa-macos.dmg"
  cp "${directory}/programa-windows-${build}.exe" "${directory}/programa-windows.exe"
  release_url="https://github.com/${REPOSITORY}/releases/download/${TAG}"
  enclosure_size="$(file_size "${directory}/programa-macos-${build}.dmg")"
  cat > "${directory}/appcast.xml" <<EOF
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
  <sparkle:version>${build}</sparkle:version>
  <enclosure url="${release_url}/programa-macos-${build}.dmg" length="${enclosure_size}" sparkle:edSignature="${ED25519_SIGNATURE}" />
</item></channel></rss>
EOF
  node - "${MODULE}" "${directory}" "${build}" <<'NODE'
const [modulePath, directory, build] = process.argv.slice(2);
require(modulePath).writeMilestoneManifest({ directory, build });
NODE
}

rehash_manifest() {
  local directory="$1"
  node - "${directory}" "${MANIFEST_NAME}" <<'NODE'
const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");
const [directory, manifestName] = process.argv.slice(2);
const manifestPath = path.join(directory, manifestName);
const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
for (const file of manifest.files) {
  const bytes = fs.readFileSync(path.join(directory, file.name));
  file.size = bytes.length;
  file.sha256 = crypto.createHash("sha256").update(bytes).digest("hex");
}
fs.writeFileSync(manifestPath, `${JSON.stringify(manifest)}\n`);
NODE
}

reset_state() {
  rm -rf "${STATE_DIR}"
  mkdir -p "${STATE_DIR}/releases"
  : > "${STATE_DIR}/operations.log"
  printf '100\n' > "${STATE_DIR}/next_asset_id"
  printf '%s\n' "${TARGET_SHA}" > "${STATE_DIR}/tag_ref"
}

write_release() {
  local tag="$1" target="$2" draft="$3" latest="$4" title="$5" body="$6" dir
  dir="$(release_dir "${tag}")"; mkdir -p "${dir}/assets"
  printf '%s\n' "${target}" > "${dir}/target"
  printf '%s\n' "${draft}" > "${dir}/draft"
  [[ "${draft}" == true ]] && printf 'false\n' > "${dir}/immutable" || printf 'true\n' > "${dir}/immutable"
  printf '%s\n' "${latest}" > "${dir}/latest"
  printf '%s\n' "${title}" > "${dir}/title"
  printf '%s\n' "${body}" > "${dir}/body"
}

write_asset() {
  local tag="$1" name="$2" source="$3" dir id
  dir="$(asset_dir "${tag}" "${name}")"; mkdir -p "${dir}"
  id="$(cat "${STATE_DIR}/next_asset_id")"; printf '%s\n' "$((id + 1))" > "${STATE_DIR}/next_asset_id"
  printf '%s\n' "${id}" > "${dir}/id"; cp "${source}" "${dir}/bytes"
  printf 'uploaded\n' > "${dir}/state"; file_size "${source}" > "${dir}/size"
  printf 'sha256:%s\n' "$(sha256_file "${source}")" > "${dir}/digest"
}

invoke() {
  local payload_dir="$1" stop_after="${2:-}" build="${3:-${BUILD}}"
  GH_BIN="${FAKE_GH}" GITHUB_REPOSITORY="${REPOSITORY}" FAKE_GH_STATE_DIR="${STATE_DIR}" \
    FAKE_GH_STOP_AFTER_MUTATION="${stop_after}" FAKE_GH_DUPLICATE_ASSET="${FAKE_GH_DUPLICATE_ASSET:-}" \
    "${HELPER}" --tag "${TAG}" --target-sha "${TARGET_SHA}" --build "${build}" \
      --payload-dir "${payload_dir}" > "${RUN_OUTPUT}" 2>&1
}

cat > "${FAKE_GH}" <<'FAKE'
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
mutation() {
  local count
  count="$(( $(cat "${STATE_DIR}/mutation_count" 2>/dev/null || echo 0) + 1 ))"
  printf '%s\n' "${count}" > "${STATE_DIR}/mutation_count"; log "mutation $*"
  if [[ -n "${FAKE_GH_STOP_AFTER_MUTATION:-}" && "${count}" == "${FAKE_GH_STOP_AFTER_MUTATION}" ]]; then
    echo "hard stop after mutation ${count}" >&2; exit 97
  fi
}
next_asset_id() { local id; id="$(cat "${STATE_DIR}/next_asset_id")"; printf '%s\n' "$((id + 1))" > "${STATE_DIR}/next_asset_id"; printf '%s' "${id}"; }

release_view() {
  local tag="$1"; shift; local query="" dir
  while (($#)); do case "$1" in --jq) query="$2"; shift 2 ;; --json|--repo) shift 2 ;; *) shift ;; esac; done
  dir="$(release_dir "${tag}")"; [[ -d "${dir}" ]] || { echo "release not found" >&2; exit 1; }
  log "view-release ${tag} query=${query}"
  case "${query}" in
    .targetCommitish) cat "${dir}/target" ;; .name) cat "${dir}/title" ;; .body) cat "${dir}/body" ;;
    .isDraft) cat "${dir}/draft" ;; .isImmutable) cat "${dir}/immutable" ;; .isLatest) echo "unknown JSON field: isLatest" >&2; exit 2 ;;
    *assets*'@tsv'*)
      local asset
      for asset in "${dir}/assets"/*; do
        [[ -d "${asset}" ]] || continue
        printf '%s\t%s\t%s\t%s\t%s\n' "$(cat "${asset}/id")" "$(basename "${asset}")" \
          "$(cat "${asset}/state")" "$(cat "${asset}/size")" "$(cat "${asset}/digest")"
        if [[ "$(basename "${asset}")" == "${FAKE_GH_DUPLICATE_ASSET:-}" ]]; then
          printf '%s\t%s\t%s\t%s\t%s\n' "$(cat "${asset}/id")" "$(basename "${asset}")" \
            "$(cat "${asset}/state")" "$(cat "${asset}/size")" "$(cat "${asset}/digest")"
        fi
      done | LC_ALL=C sort -k2,2 ;;
    *) printf '%s\t%s\t%s\t%s\n' "$(cat "${dir}/target")" "$(cat "${dir}/title")" "$(cat "${dir}/draft")" "$(cat "${dir}/latest")" ;;
  esac
}

release_list() {
  local release
  while (($#)); do case "$1" in --repo|--limit|--json|--jq) shift 2 ;; *) shift ;; esac; done
  for release in "${RELEASES}"/*; do
    [[ -d "${release}" ]] || continue
    printf '%s\t%s\t%s\n' "$(basename "${release}")" "$(cat "${release}/draft")" "$(cat "${release}/latest")"
  done | LC_ALL=C sort -k1,1
}

release_create() {
  local tag="$1"; shift; local target="" title="" notes="" draft=false generate=false dir
  while (($#)); do case "$1" in --target) target="$2"; shift 2 ;; --title) title="$2"; shift 2 ;;
    --notes) notes="$2"; shift 2 ;; --notes-file) notes="$(cat "$2")"; shift 2 ;;
    --generate-notes) generate=true; shift ;; --draft) draft=true; shift ;; --repo) shift 2 ;; *) shift ;; esac; done
  [[ ! -e "$(release_dir "${tag}")" ]] || { echo "release exists" >&2; exit 1; }
  [[ "${generate}" == true ]] && notes="generated notes for ${tag}"
  dir="$(release_dir "${tag}")"; mkdir -p "${dir}/assets"
  printf '%s\n' "${target}" > "${dir}/target"; printf '%s\n' "${title}" > "${dir}/title"
  printf '%s\n' "${notes}" > "${dir}/body"; printf '%s\n' "${draft}" > "${dir}/draft"; printf 'false\n' > "${dir}/latest"
  printf 'false\n' > "${dir}/immutable"
  mutation "create-release ${tag} draft=${draft}"
}

release_upload() {
  local tag="$1"; shift; local file name dir
  while (($#)); do case "$1" in --repo) shift 2 ;; --clobber) shift ;; *) file="$1"; shift ;; esac; done
  name="$(basename "${file}")"; dir="$(asset_dir "${tag}" "${name}")"
  [[ ! -d "${dir}" ]] || { echo "asset exists" >&2; exit 1; }
  mkdir -p "${dir}"; next_asset_id > "${dir}/id"; cp "${file}" "${dir}/bytes"
  printf 'uploaded\n' > "${dir}/state"; file_size "${file}" > "${dir}/size"; digest_file "${file}" > "${dir}/digest"
  mutation "upload-asset ${tag} ${name}"
}

release_download() {
  local tag="$1"; shift; local pattern="" destination="."
  while (($#)); do case "$1" in --pattern|-p) pattern="$2"; shift 2 ;; --dir|-D) destination="$2"; shift 2 ;; --repo) shift 2 ;; *) shift ;; esac; done
  mkdir -p "${destination}"; cp "$(asset_dir "${tag}" "${pattern}")/bytes" "${destination}/${pattern}"
  log "authenticated-download ${tag} ${pattern}"
}

release_edit() {
  local tag="$1"; shift; local dir title="" draft="" latest=""
  dir="$(release_dir "${tag}")"
  while (($#)); do case "$1" in --title) title="$2"; shift 2 ;; --draft|--draft=false) draft=false; shift ;; --latest|--latest=true) latest=true; shift ;; --repo) shift 2 ;; *) shift ;; esac; done
  [[ -z "${title}" ]] || printf '%s\n' "${title}" > "${dir}/title"
  [[ -z "${draft}" ]] || printf '%s\n' "${draft}" > "${dir}/draft"
  [[ "${draft}" != false ]] || printf 'true\n' > "${dir}/immutable"
  if [[ "${latest}" == true ]]; then
    local other; for other in "${RELEASES}"/*; do [[ -d "${other}" ]] && printf 'false\n' > "${other}/latest"; done
    printf 'true\n' > "${dir}/latest"
  fi
  mutation "edit-release ${tag} draft=$(cat "${dir}/draft") latest=$(cat "${dir}/latest")"
}

api_command() {
  local endpoint="$1"; shift; local target="" tag="" query=""
  while (($#)); do case "$1" in -f|-F) case "$2" in target_commitish=*) target="${2#*=}" ;; tag_name=*) tag="${2#*=}" ;; esac; shift 2 ;; -X|--method) shift 2 ;; --jq) query="$2"; shift 2 ;; *) shift ;; esac; done
  case "${endpoint}" in
    */git/ref/tags/*) cat "${STATE_DIR}/tag_ref"; log "read-tag-ref $(cat "${STATE_DIR}/tag_ref")" ;;
    */releases/generate-notes) printf 'generated notes for %s at %s\n' "${tag}" "${target}" ;;
    *) echo "unsupported api ${endpoint}" >&2; exit 2 ;;
  esac
}

command="$1"; shift
case "${command}" in
  release) sub="$1"; shift; case "${sub}" in view) release_view "$@" ;; list) release_list "$@" ;; create) release_create "$@" ;; upload) release_upload "$@" ;; download) release_download "$@" ;; edit) release_edit "$@" ;; *) exit 2 ;; esac ;;
  api) api_command "$@" ;; *) echo "unsupported gh command ${command}" >&2; exit 2 ;;
esac
FAKE
chmod +x "${FAKE_GH}"

assert_converged() {
  local payload_dir="$1" expected_advisory_target="${2:-${TARGET_SHA}}" name
  [[ "$(cat "$(release_dir "${TAG}")/target")" == "${expected_advisory_target}" ]] || fail "advisory targetCommitish changed unexpectedly"
  [[ "$(cat "$(release_dir "${TAG}")/title")" == "${TAG}" ]] || fail "title did not converge"
  [[ "$(cat "$(release_dir "${TAG}")/draft")" == false ]] || fail "release remains draft"
  [[ "$(cat "$(release_dir "${TAG}")/immutable")" == true ]] || fail "published release is not immutable"
  [[ "$(cat "$(release_dir "${TAG}")/latest")" == true ]] || fail "release is not latest"
  [[ -s "$(release_dir "${TAG}")/body" ]] || fail "generated notes are missing"
  while IFS= read -r name; do
    cmp -s "${payload_dir}/${name}" "$(asset_dir "${TAG}" "${name}")/bytes" || fail "remote bytes differ for ${name}"
  done < <(payload_names "${BUILD}")
  [[ "$(find "$(release_dir "${TAG}")/assets" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" == 6 ]] || fail "remote asset set is not exact"
}

PAYLOAD="${TMP_DIR}/payload-41"
prepare_payload "${PAYLOAD}" "${BUILD}"

# The immutable tag must still resolve to the requested target before any
# release mutation, even if a matching candidate payload exists locally.
reset_state
printf '%040x\n' 42 > "${STATE_DIR}/tag_ref"
if invoke "${PAYLOAD}"; then fail "publisher accepted a tag ref at another target"; fi
grep -Fq "read-tag-ref $(printf '%040x' 42)" "${STATE_DIR}/operations.log" || fail "publisher did not read the live tag ref"
! grep -q '^mutation ' "${STATE_DIR}/operations.log" || fail "tag-ref mismatch mutated release"

# GitHub may report the advisory targetCommitish as `main` even though the
# immutable tag ref resolves to the authenticated target SHA. Matching partial
# draft bytes remain resumable in that state.
reset_state
write_release "${TAG}" main true false "${TAG}" generated
write_asset "${TAG}" "programa-macos-${BUILD}.dmg" "${PAYLOAD}/programa-macos-${BUILD}.dmg"
write_asset "${TAG}" "programa-dSYMs-${BUILD}.zip" "${PAYLOAD}/programa-dSYMs-${BUILD}.zip"
: > "${STATE_DIR}/operations.log"
invoke "${PAYLOAD}"
assert_converged "${PAYLOAD}" main
grep -Fq "read-tag-ref ${TARGET_SHA}" "${STATE_DIR}/operations.log" || fail "advisory-main recovery did not authenticate the live tag ref"
[[ "$(grep -c '^authenticated-download ' "${STATE_DIR}/operations.log")" -ge 4 ]] || fail "advisory-main recovery did not verify exact remote bytes"

# Local manifest verification runs before GitHub mutation.
reset_state
cp -R "${PAYLOAD}" "${TMP_DIR}/tampered-local"
printf 'tamper\n' >> "${TMP_DIR}/tampered-local/programa-macos.dmg"
if invoke "${TMP_DIR}/tampered-local"; then fail "tampered local payload passed verification"; fi
[[ ! -s "${STATE_DIR}/operations.log" ]] || fail "local verification failure mutated GitHub"

# Matching file-manifest hashes cannot bless semantically invalid release
# payloads. Appcast references must match the tag, build, signature, and
# enclosure length before GitHub mutation.
for semantic_conflict in appcast-url; do
  semantic_dir="${TMP_DIR}/semantic-${semantic_conflict}"
  cp -R "${PAYLOAD}" "${semantic_dir}"
  case "${semantic_conflict}" in
    appcast-url)
      cat > "${semantic_dir}/appcast.xml" <<EOF
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
  <sparkle:version>${BUILD}</sparkle:version>
  <enclosure url="https://github.com/attacker/programa/releases/download/${TAG}/programa-macos-${BUILD}.dmg" length="$(file_size "${semantic_dir}/programa-macos-${BUILD}.dmg")" sparkle:edSignature="${ED25519_SIGNATURE}" />
</item></channel></rss>
EOF
      ;;
  esac
  rehash_manifest "${semantic_dir}"
  reset_state
  if invoke "${semantic_dir}"; then fail "${semantic_conflict} passed semantic validation"; fi
  ! grep -q '^mutation ' "${STATE_DIR}/operations.log" || fail "${semantic_conflict} mutated GitHub"
done

# Fresh publication converges with aliases last and authenticated verification.
reset_state; invoke "${PAYLOAD}"; assert_converged "${PAYLOAD}"
uploads="$(sed -n 's/^mutation upload-asset [^ ]* //p' "${STATE_DIR}/operations.log")"
[[ "$(printf '%s\n' "${uploads}" | tail -3)" == $'appcast.xml\nprograma-macos.dmg\nprograma-windows.exe' ]] || fail "appcast and stable aliases were not uploaded last"
[[ "$(grep -c '^authenticated-download ' "${STATE_DIR}/operations.log")" -ge 6 ]] || fail "remote payloads were not authenticated-download verified"
grep -Fq "view-release ${TAG} query=.isImmutable" "${STATE_DIR}/operations.log" || fail "publisher did not require immutable published state"

# A published exact release is idempotent.
: > "${STATE_DIR}/operations.log"; rm -f "${STATE_DIR}/mutation_count"; invoke "${PAYLOAD}"; assert_converged "${PAYLOAD}"
[[ ! -s "${STATE_DIR}/operations.log" || -z "$(grep '^mutation ' "${STATE_DIR}/operations.log" || true)" ]] || fail "idempotent retry mutated release"

# A permanent milestone can stop being latest when a newer milestone ships.
# Exact retries accept that state and never make the old release latest again.
printf 'false\n' > "$(release_dir "${TAG}")/latest"
: > "${STATE_DIR}/operations.log"; rm -f "${STATE_DIR}/mutation_count"
invoke "${PAYLOAD}"
[[ "$(cat "$(release_dir "${TAG}")/latest")" == false ]] || fail "published retry made an old milestone latest again"
! grep -q '^mutation ' "${STATE_DIR}/operations.log" || fail "published non-latest retry mutated release"

# Exact published bytes do not bypass authentication of the immutable tag.
printf '%040x\n' 42 > "${STATE_DIR}/tag_ref"
: > "${STATE_DIR}/operations.log"; rm -f "${STATE_DIR}/mutation_count"
if invoke "${PAYLOAD}"; then fail "published exact retry accepted a moved live tag"; fi
grep -Fq "read-tag-ref $(printf '%040x' 42)" "${STATE_DIR}/operations.log" || fail "published retry did not authenticate the live tag ref"
! grep -q '^mutation ' "${STATE_DIR}/operations.log" || fail "published retry with moved tag mutated release"

# Hard stop after an early upload leaves a resumable draft.
reset_state
if invoke "${PAYLOAD}" 2; then fail "early hard stop was not propagated"; fi
[[ "$(cat "$(release_dir "${TAG}")/draft")" == true ]] || fail "early interruption did not preserve draft"
rm -f "${STATE_DIR}/mutation_count"; invoke "${PAYLOAD}"; assert_converged "${PAYLOAD}"

# Hard stop after every upload but before finalize resumes without clobber.
reset_state
if invoke "${PAYLOAD}" 7; then fail "pre-finalize hard stop was not propagated"; fi
[[ "$(cat "$(release_dir "${TAG}")/draft")" == true ]] || fail "complete interrupted release was published"
[[ "$(find "$(release_dir "${TAG}")/assets" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" == 6 ]] || fail "pre-finalize stop did not occur after all uploads"
: > "${STATE_DIR}/operations.log"; rm -f "${STATE_DIR}/mutation_count"; invoke "${PAYLOAD}"; assert_converged "${PAYLOAD}"
! grep -q '^mutation upload-asset ' "${STATE_DIR}/operations.log" || fail "complete draft retry reuploaded assets"

# Partial published releases are never repaired in place.
reset_state; write_release "${TAG}" "${TARGET_SHA}" false true "${TAG}" generated
write_asset "${TAG}" "programa-macos-${BUILD}.dmg" "${PAYLOAD}/programa-macos-${BUILD}.dmg"
: > "${STATE_DIR}/operations.log"
if invoke "${PAYLOAD}"; then fail "partial published release was repaired"; fi
! grep -q '^mutation ' "${STATE_DIR}/operations.log" || fail "partial published release was mutated"

# Partial drafts reject unexpected, duplicate, and wrong-byte assets.
for conflict in unexpected duplicate wrong-bytes; do
  reset_state; write_release "${TAG}" "${TARGET_SHA}" true false "${TAG}" generated
  case "${conflict}" in
    unexpected) write_asset "${TAG}" unexpected.bin "${PAYLOAD}/appcast.xml" ;;
    duplicate) write_asset "${TAG}" appcast.xml "${PAYLOAD}/appcast.xml" ;;
    wrong-bytes) printf 'wrong\n' > "${TMP_DIR}/wrong"; write_asset "${TAG}" appcast.xml "${TMP_DIR}/wrong" ;;
  esac
  : > "${STATE_DIR}/operations.log"
  duplicate_name=""; [[ "${conflict}" != duplicate ]] || duplicate_name=appcast.xml
  if FAKE_GH_DUPLICATE_ASSET="${duplicate_name}" invoke "${PAYLOAD}"; then
    fail "${conflict} draft state was accepted"
  fi
  ! grep -q '^mutation ' "${STATE_DIR}/operations.log" || fail "${conflict} draft state was mutated"
done

# Same tag with different bytes or build never mutates the permanent release.
reset_state; invoke "${PAYLOAD}"; assert_converged "${PAYLOAD}"
DIFFERENT="${TMP_DIR}/different"; cp -R "${PAYLOAD}" "${DIFFERENT}"
rm -f "${DIFFERENT}/${MANIFEST_NAME}"
printf 'different\n' > "${DIFFERENT}/appcast.xml"
node - "${MODULE}" "${DIFFERENT}" "${BUILD}" <<'NODE'
const [modulePath, directory, build] = process.argv.slice(2);
require(modulePath).writeMilestoneManifest({ directory, build });
NODE
: > "${STATE_DIR}/operations.log"
if invoke "${DIFFERENT}"; then fail "same tag accepted different payload bytes"; fi
! grep -q '^mutation ' "${STATE_DIR}/operations.log" || fail "different-byte retry mutated release"

PAYLOAD_42="${TMP_DIR}/payload-42"; prepare_payload "${PAYLOAD_42}" 42
: > "${STATE_DIR}/operations.log"
if invoke "${PAYLOAD_42}" '' 42; then fail "same tag accepted a different build"; fi
! grep -q '^mutation ' "${STATE_DIR}/operations.log" || fail "different-build retry mutated release"

echo "PASS: milestone publication is exact, permanent, and retry-convergent"
