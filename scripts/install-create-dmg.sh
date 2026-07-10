#!/usr/bin/env bash
set -euo pipefail

VERSION="${CREATE_DMG_VERSION:-}"
NPM_COMMAND="${PROGRAMA_NPM_COMMAND:-npm}"

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$ ]]; then
  echo "CREATE_DMG_VERSION must be an explicit version (for example, 8.0.0)" >&2
  exit 1
fi

"$NPM_COMMAND" install --global "create-dmg@$VERSION"
