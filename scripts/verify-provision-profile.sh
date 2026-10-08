#!/usr/bin/env bash
set -euo pipefail

# Verifies that a signed app bundle's embedded provisioning profile actually
# covers the restricted entitlements the app declares.
#
# Why this is a hard gate and not a report: Apple evaluates the embedded
# profile against the app's entitlements at every launch. An app carrying a
# restricted entitlement (anything under com.apple.developer.*) with no
# profile — or with a profile that does not grant that entitlement — signs
# cleanly, notarizes cleanly, and is then killed by AMFI the moment a user
# opens it (POSIX 163). Notarization does not catch this class of failure;
# only a real launch does, and by then it has shipped to everyone.
#
# The script derives whether a profile is required from the bundle's own
# entitlements (for example CloudKit: com.apple.developer.icloud-services /
# icloud-container-identifiers) rather than from a comment that can go stale.
#
# Exit codes:
#   0  no restricted entitlements and no profile, or profile covers them all
#   1  restricted entitlements with no/expired/corrupt/insufficient profile
#  64  usage error

if [[ "$#" -ne 1 ]]; then
  echo "usage: $0 <app-path>" >&2
  exit 64
fi

app_path="$1"
profile_path="$app_path/Contents/embedded.provisionprofile"

if [[ ! -d "$app_path" ]]; then
  echo "verify-provision-profile: no app bundle at $app_path" >&2
  exit 64
fi

# Read the entitlements actually sealed into the signature, not the source
# .entitlements file — those can differ, and the signature is what AMFI reads.
if ! app_entitlements="$(codesign -d --entitlements - --xml "$app_path" 2>/dev/null)"; then
  echo "verify-provision-profile: could not read entitlements from $app_path." >&2
  echo "The bundle must be signed before this runs; refusing to guess." >&2
  exit 1
fi

if [[ -f "$profile_path" ]]; then
  if ! profile_plist="$(security cms -D -i "$profile_path" 2>/dev/null)"; then
    echo "Embedded provisioning profile is present but could not be decoded (corrupt or unsigned): $profile_path" >&2
    exit 1
  fi
else
  profile_plist=""
fi

python3 - "$app_entitlements" "$profile_plist" <<'PYEOF'
import datetime
import plistlib
import sys

app_xml, profile_xml = sys.argv[1], sys.argv[2]

try:
    app_entitlements = plistlib.loads(app_xml.encode("utf-8")) or {}
except Exception as exc:  # noqa: BLE001 - any parse failure is fatal here
    print(f"Could not parse the app's signed entitlements: {exc}", file=sys.stderr)
    sys.exit(1)

# Most of com.apple.developer.* is App-ID-level capability that Apple gates
# through a provisioning profile, so the namespace is the right starting point
# and unknown keys are treated as restricted — a false positive is a loud,
# one-line fix, a false negative ships an app that dies on launch for everyone.
#
# team-identifier is the one blanket exception. codesign injects it into
# essentially every Developer-ID-signed bundle from the signing certificate, so
# treating it as restricted would fail every build. Verified by sampling signed
# apps: IINA, Dato and Xcode all ship with no embedded profile at all, and Dato
# and Xcode carry other com.apple.developer.* keys (usernotifications.*,
# aps-environment) without one — those are deliberately NOT excluded here, since
# Programa does not use them and guessing wrong in that direction is the
# expensive mistake. If one is ever added and this fires, confirm against Apple's
# capability docs before widening the exception.
IGNORED = {"com.apple.developer.team-identifier"}

restricted = sorted(
    k for k in app_entitlements
    if k.startswith("com.apple.developer.") and k not in IGNORED
)

if not restricted:
    print("No restricted entitlements declared; no provisioning profile required.")
    if profile_xml:
        print("(An embedded profile is present anyway, which is harmless.)")
    sys.exit(0)

print("Restricted entitlements declared by this build:")
for key in restricted:
    print(f"  {key}")

if not profile_xml:
    print("", file=sys.stderr)
    print("FAIL: this build declares restricted entitlements but embeds no", file=sys.stderr)
    print("provisioning profile. It would pass notarization and then be killed", file=sys.stderr)
    print("by AMFI at launch (POSIX 163) for every user.", file=sys.stderr)
    print("", file=sys.stderr)
    print("Set the APPLE_PROVISION_PROFILE_BASE64 secret, or remove the", file=sys.stderr)
    print("restricted entitlements from programa.entitlements.", file=sys.stderr)
    sys.exit(1)

try:
    profile = plistlib.loads(profile_xml.encode("utf-8"))
except Exception as exc:  # noqa: BLE001
    print(f"Embedded provisioning profile is present but unreadable: {exc}", file=sys.stderr)
    sys.exit(1)

name = profile.get("Name", "<unknown>")
expiry = profile.get("ExpirationDate")
granted = profile.get("Entitlements", {}) or {}

print(f"Profile name: {name}")
print(f"Expiration:   {expiry}")

if isinstance(expiry, datetime.datetime):
    now = datetime.datetime.now(expiry.tzinfo) if expiry.tzinfo else datetime.datetime.utcnow()
    if expiry < now:
        print(f"FAIL: provisioning profile '{name}' is EXPIRED.", file=sys.stderr)
        sys.exit(1)
else:
    print("Warning: could not read ExpirationDate from profile; skipping expiry check.", file=sys.stderr)

# Presence, not value equality: the profile grants a capability, while the app's
# own entitlement carries the concrete value (a container id, a domain). A value
# mismatch is worth seeing but is not on its own an AMFI kill; a missing key is.
missing = [key for key in restricted if key not in granted]
if missing:
    print("", file=sys.stderr)
    print(f"FAIL: profile '{name}' does not grant every restricted entitlement", file=sys.stderr)
    print("this build declares. Missing:", file=sys.stderr)
    for key in missing:
        print(f"  {key}", file=sys.stderr)
    print("", file=sys.stderr)
    print("AMFI checks the app's entitlements against this profile at launch,", file=sys.stderr)
    print("so the app would be killed for every user. Regenerate the profile", file=sys.stderr)
    print("against an App ID that has the matching capability enabled.", file=sys.stderr)
    sys.exit(1)

print("Entitlements granted by this profile:")
for key, value in granted.items():
    print(f"  {key} = {value}")

print(f"Provisioning profile verified: {name} covers all {len(restricted)} restricted entitlement(s).")
PYEOF
