#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <app-path> <expected-sparkle-version>" >&2
  exit 64
fi

app_path="$1"
expected_version="$2"
framework_path="$app_path/Contents/Frameworks/Sparkle.framework"
framework_version_path="$framework_path/Versions/Current"
framework_plist="$framework_version_path/Resources/Info.plist"

if [[ ! -d "$app_path" ]]; then
  echo "App bundle not found: $app_path" >&2
  exit 1
fi
if [[ ! -f "$framework_plist" ]]; then
  echo "Embedded Sparkle framework Info.plist not found: $framework_plist" >&2
  exit 1
fi

actual_version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$framework_plist")
if [[ "$actual_version" != "$expected_version" ]]; then
  echo "Embedded Sparkle version mismatch: expected $expected_version, found $actual_version" >&2
  exit 1
fi

components=(
  "$framework_path"
  "$framework_version_path/Updater.app"
  "$framework_version_path/XPCServices/Downloader.xpc"
  "$framework_version_path/XPCServices/Installer.xpc"
)

for component in "${components[@]}"; do
  if [[ ! -e "$component" ]]; then
    echo "Embedded Sparkle component not found: $component" >&2
    exit 1
  fi
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$component"
done

/usr/bin/codesign --verify --deep --strict --verbose=2 "$app_path"
echo "Verified embedded Sparkle $actual_version and deep signatures in $app_path"
