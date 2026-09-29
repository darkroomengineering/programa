#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <dmg-path> <tag> [output-path] [enclosure-filename]" >&2
  exit 1
fi

DMG_PATH="$1"
TAG="$2"
OUT_PATH="${3:-appcast.xml}"
# The enclosure filename is what Sparkle downloads. It must be unique per build:
# the rolling release reuses one tag and overwrites its assets, so a fixed name is a
# mutable url carrying a content-bound signature, and a client that reads the new
# appcast but is served the previous (still-cached) DMG fails validation with
# SUSparkleErrorDomain 4005. Defaults to the DMG's own name for local/manual runs.
ENCLOSURE_FILENAME="${4:-${ENCLOSURE_FILENAME:-$(basename "$DMG_PATH")}}"

# Refuse to sign an appcast whose enclosure is a mutable filename. The check below only
# verifies the appcast points at whatever name it was handed — passing the unversioned
# programa-macos.dmg would satisfy it and silently reintroduce SUSparkleErrorDomain 4005.
# Set PROGRAMA_ALLOW_MUTABLE_ENCLOSURE=1 only for local experiments that never publish.
if [[ "${PROGRAMA_ALLOW_MUTABLE_ENCLOSURE:-}" != "1" ]]; then
  if [[ ! "$ENCLOSURE_FILENAME" =~ ^programa-macos-[0-9]+\.dmg$ ]]; then
    echo "ERROR: enclosure '$ENCLOSURE_FILENAME' is not a per-build filename." >&2
    echo "       Sparkle signatures are content-bound, so the enclosure url must never be" >&2
    echo "       overwritten by a later ship. Expected programa-macos-<build>.dmg — pass it" >&2
    echo "       as argument 4 (see scripts/sparkle_enclosure.js)." >&2
    exit 1
  fi
fi

if [[ -z "${SPARKLE_PRIVATE_KEY:-}" ]]; then
  echo "SPARKLE_PRIVATE_KEY is required (exported from Sparkle generate_keys)." >&2
  exit 1
fi

# This tool runs next to SPARKLE_PRIVATE_KEY, so it is pinned to an exact commit, not
# just a tag (tags can be moved). Bump both together; the SHA is the tag's commit
# (git ls-remote https://github.com/sparkle-project/Sparkle refs/tags/<version>).
SPARKLE_VERSION="2.9.6"
SPARKLE_COMMIT="ac2def288cbff5cfc7df3ffef6abdf45b72bcb0a"
DOWNLOAD_URL_PREFIX="${DOWNLOAD_URL_PREFIX:-https://github.com/darkroomengineering/programa/releases/download/$TAG/}"
RELEASE_NOTES_URL="${RELEASE_NOTES_URL:-https://github.com/darkroomengineering/programa/releases/tag/$TAG}"

work_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$work_dir"
}
trap cleanup EXIT

echo "Cloning Sparkle ${SPARKLE_VERSION}..."
git clone --depth 1 --branch "$SPARKLE_VERSION" https://github.com/sparkle-project/Sparkle "$work_dir/Sparkle"
sparkle_head="$(git -C "$work_dir/Sparkle" rev-parse HEAD)"
if [[ "$sparkle_head" != "$SPARKLE_COMMIT" ]]; then
  echo "ERROR: Sparkle ${SPARKLE_VERSION} resolved to ${sparkle_head}, expected ${SPARKLE_COMMIT}." >&2
  exit 1
fi

echo "Building Sparkle generate_appcast tool..."
xcodebuild \
  -project "$work_dir/Sparkle/Sparkle.xcodeproj" \
  -scheme generate_appcast \
  -configuration Release \
  -derivedDataPath "$work_dir/build" \
  CODE_SIGNING_ALLOWED=NO \
  build >/dev/null

echo "Building Sparkle sign_update tool..."
xcodebuild \
  -project "$work_dir/Sparkle/Sparkle.xcodeproj" \
  -scheme sign_update \
  -configuration Release \
  -derivedDataPath "$work_dir/build" \
  CODE_SIGNING_ALLOWED=NO \
  build >/dev/null

generate_appcast="$work_dir/build/Build/Products/Release/generate_appcast"
sign_update="$work_dir/build/Build/Products/Release/sign_update"

if [[ ! -x "$generate_appcast" ]]; then
  echo "generate_appcast binary not found at $generate_appcast" >&2
  exit 1
fi
if [[ ! -x "$sign_update" ]]; then
  echo "sign_update binary not found at $sign_update" >&2
  exit 1
fi

archives_dir="$work_dir/archives"
mkdir -p "$archives_dir"
# generate_appcast builds the enclosure url from the archive's filename, so staging the
# DMG under the enclosure name is what pins the url to this build.
cp "$DMG_PATH" "$archives_dir/$ENCLOSURE_FILENAME"
echo "Enclosure: ${DOWNLOAD_URL_PREFIX}${ENCLOSURE_FILENAME}"

key_file="$work_dir/sparkle_ed_key"
# Ensure base64 padding (keys may be stored without trailing '=')
padded_key="$SPARKLE_PRIVATE_KEY"
while (( ${#padded_key} % 4 != 0 )); do
  padded_key="${padded_key}="
done
printf "%s" "$padded_key" > "$key_file"

generated_appcast_path="$archives_dir/$(basename "$OUT_PATH")"

"$generate_appcast" \
  --ed-key-file "$key_file" \
  --download-url-prefix "$DOWNLOAD_URL_PREFIX" \
  --full-release-notes-url "$RELEASE_NOTES_URL" \
  "$archives_dir"

if [[ ! -f "$generated_appcast_path" ]]; then
  fallback_generated_appcast="$(find "$archives_dir" -maxdepth 1 -name '*.xml' | head -n 1)"
  if [[ -n "$fallback_generated_appcast" ]]; then
    generated_appcast_path="$fallback_generated_appcast"
  fi
fi

if [[ ! -f "$generated_appcast_path" ]]; then
  echo "Expected appcast was not generated." >&2
  exit 1
fi

# Check if generate_appcast added the edSignature. If not, use sign_update
# to sign the DMG and inject the signature. generate_appcast silently skips
# signing when the public key derived from the private key doesn't match the
# SUPublicEDKey in the app's Info.plist.
if ! grep -q 'sparkle:edSignature' "$generated_appcast_path"; then
  echo "Warning: generate_appcast did not add edSignature. Using sign_update fallback..."
  SIGNATURE=$("$sign_update" -p --ed-key-file "$key_file" "$DMG_PATH")
  DMG_LENGTH=$(stat -f%z "$DMG_PATH")
  echo "  EdDSA signature: ${SIGNATURE:0:20}..."
  echo "  DMG length: $DMG_LENGTH"

  # Inject sparkle:edSignature and correct length into the enclosure element
  python3 -c "
import sys
xml = open('$generated_appcast_path').read()
sig = '$SIGNATURE'
length = '$DMG_LENGTH'
# Add edSignature to enclosure
xml = xml.replace(
    'type=\"application/octet-stream\"',
    'sparkle:edSignature=\"' + sig + '\" length=\"' + length + '\" type=\"application/octet-stream\"'
)
open('$generated_appcast_path', 'w').write(xml)
print('  Injected edSignature into appcast.xml')
"
fi

cp "$generated_appcast_path" "$OUT_PATH"
echo "Generated appcast at $OUT_PATH"

# Verify the appcast has a signature
if grep -q 'sparkle:edSignature' "$OUT_PATH"; then
  echo "Verified: appcast contains sparkle:edSignature"
else
  echo "ERROR: appcast is missing sparkle:edSignature!" >&2
  exit 1
fi

# The signature is bound to these exact bytes, so the enclosure must point at the
# per-build filename we staged. If it silently fell back to another name, the url
# would be overwritable by the next ship and clients would hit signature mismatches.
if grep -q "url=\"${DOWNLOAD_URL_PREFIX}${ENCLOSURE_FILENAME}\"" "$OUT_PATH"; then
  echo "Verified: enclosure url pins the per-build filename"
else
  echo "ERROR: appcast enclosure does not reference ${ENCLOSURE_FILENAME}" >&2
  grep -o 'url="[^"]*"' "$OUT_PATH" >&2 || true
  exit 1
fi
