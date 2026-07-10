#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -lt 2 ]]; then
  echo "usage: $0 <app-path> <embedded-tool> [embedded-tool ...]" >&2
  exit 64
fi

app_path="$1"
shift

sensitive_keys=(
  com.apple.security.cs.disable-library-validation
  com.apple.security.cs.allow-unsigned-executable-memory
  com.apple.security.cs.allow-jit
  com.apple.security.device.camera
  com.apple.security.device.audio-input
  com.apple.security.automation.apple-events
)

app_entitlements="$(/usr/bin/codesign -d --entitlements :- "$app_path" 2>/dev/null)"
for key in "${sensitive_keys[@]}"; do
  if [[ "$app_entitlements" != *"<key>$key</key>"* ]]; then
    echo "missing required app entitlement: $key" >&2
    exit 1
  fi
done

for tool in "$@"; do
  tool_entitlements="$(/usr/bin/codesign -d --entitlements :- "$tool" 2>/dev/null)"
  for key in "${sensitive_keys[@]}"; do
    if [[ "$tool_entitlements" == *"<key>$key</key>"* ]]; then
      echo "embedded tool has app-only entitlement $key: $tool" >&2
      exit 1
    fi
  done
done

echo "Release entitlement boundaries verified."
