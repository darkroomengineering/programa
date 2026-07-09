#!/usr/bin/env bash
# Regression test for arm64-only GhosttyKit and Release build settings.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

for file in \
  "$ROOT_DIR/.github/workflows/build-ghosttykit.yml" \
  "$ROOT_DIR/scripts/ensure-ghosttykit.sh"
do
  if ! grep -Fq -- '-Dxcframework-target=native' "$file"; then
    echo "FAIL: $file must build GhosttyKit with -Dxcframework-target=native (arm64-only)"
    exit 1
  fi
  if grep -Fq -- '-Dxcframework-target=universal' "$file"; then
    echo "FAIL: $file must not build GhosttyKit as universal"
    exit 1
  fi
done

RELEASE_YML="$ROOT_DIR/.github/workflows/release.yml"

if ! grep -Fq 'ARCHS="arm64"' "$RELEASE_YML"; then
  echo "FAIL: release.yml must build the Release app with ARCHS=\"arm64\" only"
  exit 1
fi

if grep -Fq 'ARCHS="arm64 x86_64"' "$RELEASE_YML"; then
  echo "FAIL: release.yml must not build the Release app as universal (arm64 x86_64)"
  exit 1
fi

for var in APP_ARCHS CLI_ARCHS HELPER_ARCHS; do
  if ! grep -Fq "[[ \"\$${var}\" == \"arm64\" ]]" "$RELEASE_YML"; then
    echo "FAIL: release.yml must verify \$${var} is exactly arm64 (single-arch)"
    exit 1
  fi
done

if ! awk '
  /\/\* Release \*\// { in_release=1; next }
  in_release && /ONLY_ACTIVE_ARCH = YES;/ { saw_yes=1 }
  in_release && /ONLY_ACTIVE_ARCH = NO;/ { saw_no=1 }
  in_release && /name = Release;/ { in_release=0 }
  END { exit !(saw_no && !saw_yes) }
' "$ROOT_DIR/GhosttyTabs.xcodeproj/project.pbxproj"; then
  echo "FAIL: Release configurations in project.pbxproj must use ONLY_ACTIVE_ARCH = NO"
  exit 1
fi

echo "PASS: GhosttyKit builds arm64-only and Release configs build/verify arm64-only"
