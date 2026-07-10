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

"${codesign[@]}" --entitlements "$app_entitlements" "$app_path"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app_path"
