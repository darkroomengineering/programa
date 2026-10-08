#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 3 ]]; then
  echo "usage: $0 <app-path> <signing-identity> <app-entitlements>" >&2
  exit 64
fi

app_path="$1"
identity="$2"
app_entitlements="$3"
codesign=(/usr/bin/codesign --force --options runtime --timestamp --sign "$identity")

sign_if_present() {
  local path="$1"
  if [[ -e "$path" ]]; then
    "${codesign[@]}" "$path"
  fi
}

# Apple requires manual signing from the deepest nested code outward. In
# particular, do not use --deep while signing: it would copy the app's broad
# entitlements onto command-line tools and Sparkle helpers.
sparkle="$app_path/Contents/Frameworks/Sparkle.framework/Versions/B"
sign_if_present "$sparkle/XPCServices/Downloader.xpc"
sign_if_present "$sparkle/XPCServices/Installer.xpc"
sign_if_present "$sparkle/Updater.app"
sign_if_present "$sparkle/Autoupdate"
sign_if_present "$app_path/Contents/Frameworks/Sparkle.framework"
sign_if_present "$app_path/Contents/PlugIns/ProgramaDockTilePlugin.plugin"
sign_if_present "$app_path/Contents/Resources/bin/programa"
sign_if_present "$app_path/Contents/Resources/bin/ghostty"
sign_if_present "$app_path/Contents/Resources/bin/programa-mcp"

# Embed a Developer ID provisioning profile if one was supplied via
# PROGRAMA_PROVISION_PROFILE. This is required for restricted entitlements
# (e.g. CloudKit's com.apple.developer.icloud-services /
# icloud-container-identifiers) to survive AMFI's launch-time check: Apple
# evaluates the profile against the app's entitlements both at install time
# and at every launch, so an app carrying a restricted entitlement but no
# embedded profile signs and notarizes fine and is then killed at launch
# (AMFI, POSIX 163). Xcode's normal provisioning flow never sees this
# because CODE_SIGN_ENTITLEMENTS is empty in the project; entitlements are
# applied here, post-build, directly by codesign.
#
# Ordering is load-bearing: this MUST run before the final `codesign` of the
# app bundle below. The code signature seals Contents/embedded.provisionprofile
# like any other bundle resource, so copying the profile in after signing
# would invalidate the seal and `codesign --verify --deep --strict` (or
# Gatekeeper at install time) would reject the app. Do not move this after
# the app is signed, and do not "simplify" it away — that reintroduces the
# exact AMFI-kill failure mode this comment is warning about.
#
# When PROGRAMA_PROVISION_PROFILE is unset or the file doesn't exist, this is
# a no-op here, but not harmless, because the app declares
# restricted entitlements. scripts/verify-provision-profile.sh runs after this
# and fails the build in that case rather than letting an AMFI-killed app ship.
if [[ -n "${PROGRAMA_PROVISION_PROFILE:-}" && -f "${PROGRAMA_PROVISION_PROFILE:-}" ]]; then
  echo "Embedding provisioning profile from $PROGRAMA_PROVISION_PROFILE"
  cp "$PROGRAMA_PROVISION_PROFILE" "$app_path/Contents/embedded.provisionprofile"
fi

"${codesign[@]}" --entitlements "$app_entitlements" "$app_path"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app_path"
