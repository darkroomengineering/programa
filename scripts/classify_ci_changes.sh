#!/usr/bin/env bash
set -euo pipefail

RUN_APP_JOBS=false
SAW_CHANGED_PATH=false

while IFS= read -r path || [[ -n "$path" ]]; do
  [[ -z "$path" ]] && continue
  SAW_CHANGED_PATH=true

  case "$path" in
    # String catalogs compile into the app, so a malformed catalog must build.
    Resources/*.xcstrings|Resources/*/*.xcstrings)
      RUN_APP_JOBS=true
      ;;
    # Legacy .strings resources are scoped out per request
    Resources/*.strings|Resources/*/*.strings)
      continue
      ;;
    # Explicitly skip doc-only translation assets
    Resources/*.lproj/*)
      continue
      ;;
    # Images here are build inputs, not documentation assets.
    Resources/**|Assets.xcassets/**)
      RUN_APP_JOBS=true
      ;;
    # Documentation and prose
    *.md|docs/*|plans/*|AGENTS.md|CHANGELOG.md|TODO.md|README.md|LICENSE*|THIRD_PARTY_LICENSES.md|.editorconfig|.gitattributes|.gitignore|*.png|*.jpg|*.jpeg|*.gif|*.webp|*.svg)
      continue
      ;;
    # The main CI workflow runs the jobs it defines, so an edit to it must
    # exercise them instead of merging unrun.
    .github/workflows/ci.yml)
      RUN_APP_JOBS=true
      ;;
    # Other repository metadata / workflow edits are not app/runtime changes
    .github/*)
      continue
      ;;
    *)
      RUN_APP_JOBS=true
      ;;
  esac
done

if [[ "$SAW_CHANGED_PATH" == "false" ]]; then
  RUN_APP_JOBS=true
fi

printf 'run_app_jobs=%s\n' "$RUN_APP_JOBS"
