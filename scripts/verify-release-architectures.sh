#!/usr/bin/env bash
set -euo pipefail

EXPECTED_ARCHITECTURES="${EXPECTED_ARCHITECTURES:-arm64}"
LIPO_COMMAND="${PROGRAMA_LIPO_COMMAND:-lipo}"

if [ "$#" -eq 0 ]; then
  echo "usage: $0 <Mach-O binary or archive> [...]" >&2
  exit 2
fi

for artifact in "$@"; do
  if [ ! -f "$artifact" ]; then
    echo "release architecture check: missing artifact: $artifact" >&2
    exit 1
  fi

  architectures="$("$LIPO_COMMAND" -archs "$artifact")"
  echo "$artifact architectures: $architectures"
  if [ "$architectures" != "$EXPECTED_ARCHITECTURES" ]; then
    echo "release architecture check: expected '$EXPECTED_ARCHITECTURES', got '$architectures': $artifact" >&2
    exit 1
  fi
done
