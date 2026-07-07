# Programa agent notes

## Initial setup

Run the setup script to initialize submodules and build GhosttyKit:

```bash
./scripts/setup.sh
```

## Local dev

After making code changes, always run the reload script with a tag to build the Debug app:

```bash
./scripts/reload.sh --tag fix-zsh-autosuggestions
```

By default, `reload.sh` builds but does **not** launch the app. The script prints the `.app` path so the user can cmd-click to open it. Pass `--launch` to kill any existing instance and open the app automatically:

```bash
./scripts/reload.sh --tag fix-zsh-autosuggestions --launch
```

`reload.sh` prints an `App path:` line with the absolute path to the built `.app`. Use that path to build a cmd-clickable `file://` URL. Steps:

1. Grab the path from the `App path:` line in `reload.sh` output.
2. Prepend `file://` and URL-encode spaces as `%20`. Do not hardcode any part of the path.
3. Format it as a markdown link using the template for your agent type.

Example. If `reload.sh` output contains:
```
App path:
  /Users/someone/Library/Developer/Xcode/DerivedData/programa-my-tag/Build/Products/Debug/Programa DEV my-tag.app
```

**Claude Code** outputs:
```markdown
=======================================================
[Programa DEV my-tag.app](file:///Users/someone/Library/Developer/Xcode/DerivedData/programa-my-tag/Build/Products/Debug/Programa%20DEV%20my-tag.app)
=======================================================
```

**Codex** outputs:
```
=======================================================
[my-tag: file:///Users/someone/Library/Developer/Xcode/DerivedData/programa-my-tag/Build/Products/Debug/Programa%20DEV%20my-tag.app](file:///Users/someone/Library/Developer/Xcode/DerivedData/programa-my-tag/Build/Products/Debug/Programa%20DEV%20my-tag.app)
=======================================================
```

Never use `/tmp/programa-<tag>/...` app links in chat output.

After making code changes, always use `reload.sh --tag` to build. **Never run bare `xcodebuild` or `open` an untagged `Programa DEV.app`.** Untagged builds share the default debug socket and bundle ID with other agents, causing conflicts and stealing focus.

```bash
./scripts/reload.sh --tag <your-branch-slug>
```

If you only need to verify the build compiles (no launch), use a tagged derivedDataPath:

```bash
xcodebuild -project GhosttyTabs.xcodeproj -scheme programa -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/programa-<your-tag> build
```

When rebuilding GhosttyKit.xcframework, always use Release optimizations:

```bash
cd ghostty && zig build -Demit-xcframework=true -Dxcframework-target=universal -Doptimize=ReleaseFast
```

When rebuilding programad for release/bundling, always use ReleaseFast:

```bash
cd programad && zig build -Doptimize=ReleaseFast
```

`reload` = build the Debug app (tag required). Pass `--launch` to also kill existing and open:

```bash
./scripts/reload.sh --tag <tag>
./scripts/reload.sh --tag <tag> --launch
```

`reloadp` = kill and launch the Release app:

```bash
./scripts/reloadp.sh
```

`reloads` = kill and launch the Release app as "Programa STAGING" (isolated from production Programa):

```bash
./scripts/reloads.sh
```

`reload2` = reload both Debug and Release (tag required for Debug reload):

```bash
./scripts/reload2.sh --tag <tag>
```

For parallel/isolated builds (e.g., testing a feature alongside the main app), use `--tag` with a short descriptive name:

```bash
./scripts/reload.sh --tag fix-blur-effect
```

This creates an isolated app with its own name, bundle ID, socket, and derived data path so it runs side-by-side with the main app. Important: use a non-`/tmp` derived data path if you need xcframework resolution (the script handles this automatically).

Before launching a new tagged run, clean up any older tags you started in this session (quit old tagged app + remove its `/tmp` socket/derived data).

## Debug event log

All debug events (keys, mouse, focus, splits, tabs) go to a unified log in DEBUG builds:

```bash
tail -f "$(cat /tmp/programa-last-debug-log-path 2>/dev/null || echo /tmp/programa-debug.log)"
```

- Untagged Debug app: `/tmp/programa-debug.log`
- Tagged Debug app (`./scripts/reload.sh --tag <tag>`): `/tmp/programa-debug-<tag>.log`
- `reload.sh` writes the current path to `/tmp/programa-last-debug-log-path`
- `reload.sh` writes the selected dev CLI path to `/tmp/programa-last-cli-path`
- `reload.sh` updates `/tmp/programa-cli` and `$HOME/.local/bin/programa-dev` to that CLI

- Implementation: `vendor/bonsplit/Sources/Bonsplit/Public/DebugEventLog.swift`
- Free function `dlog("message")` — logs with timestamp and appends to file in real time
- Entire file is `#if DEBUG`; all call sites must be wrapped in `#if DEBUG` / `#endif`
- 500-entry ring buffer; `DebugEventLog.shared.dump()` writes full buffer to file
- Key events logged in `AppDelegate.swift` (monitor, performKeyEquivalent)
- Mouse/UI events logged inline in views (ContentView, BrowserPanelView, etc.)
- Focus events: `focus.panel`, `focus.bonsplit`, `focus.firstResponder`, `focus.moveFocus`
- Bonsplit events: `tab.select`, `tab.close`, `tab.dragStart`, `tab.drop`, `pane.focus`, `pane.drop`, `divider.dragStart`

## Regression test commit policy

When adding a regression test for a bug fix, use a two-commit structure so CI proves the test catches the bug:

1. **Commit 1:** Add the failing test only (no fix). CI should go red.
2. **Commit 2:** Add the fix. CI should go green.

This makes it visible in the GitHub PR UI (Commits tab, check statuses) that the test genuinely fails without the fix.

## Debug menu

The app has a **Debug** menu in the macOS menu bar (only in DEBUG builds). Use it for visual iteration:

- **Debug > Debug Windows** contains panels for tuning layout, colors, and behavior. Entries are alphabetical with no dividers.
- To add a debug toggle or visual option: create an `NSWindowController` subclass with a `shared` singleton, add it to the "Debug Windows" menu in `Sources/programaApp.swift`, and add a SwiftUI view with `@AppStorage` bindings for live changes.
- When the user says "debug menu" or "debug window", they mean this menu, not `defaults write`.

## Pitfalls

- **Custom UTTypes** for drag-and-drop must be declared in `Resources/Info.plist` under `UTExportedTypeDeclarations` (e.g. `com.splittabbar.tabtransfer`, `com.darkroom.programa.sidebar-tab-reorder`).
- Do not add an app-level display link or manual `ghostty_surface_draw` loop; rely on Ghostty wakeups/renderer to avoid typing lag.
- **Typing-latency-sensitive paths** (read carefully before touching these areas):
  - `WindowTerminalHostView.hitTest()` in `TerminalWindowPortal.swift`: called on every event including keyboard. All divider/sidebar/drag routing is gated to pointer events only. Do not add work outside the `isPointerEvent` guard.
  - `TabItemView` in `ContentView.swift`: uses `Equatable` conformance + `.equatable()` to skip body re-evaluation during typing. Do not add `@EnvironmentObject`, `@ObservedObject` (besides `tab`), or `@Binding` properties without updating the `==` function. Do not remove `.equatable()` from the ForEach call site. Do not read `tabManager` or `notificationStore` in the body; use the precomputed `let` parameters instead.
  - `TerminalSurface.forceRefresh()` in `GhosttyTerminalView.swift`: called on every keystroke. Do not add allocations, file I/O, or formatting here.
- **Terminal find layering contract:** `SurfaceSearchOverlay` must be mounted from `GhosttySurfaceScrollView` in `Sources/GhosttyTerminalView.swift` (AppKit portal layer), not from SwiftUI panel containers such as `Sources/Panels/TerminalPanelView.swift`. Portal-hosted terminal views can sit above SwiftUI during split/workspace churn.
- **Submodule safety:** When modifying a submodule (ghostty, vendor/bonsplit, etc.), always push the submodule commit to its remote `main` branch BEFORE committing the updated pointer in the parent repo. Never commit on a detached HEAD or temporary branch — the commit will be orphaned and lost. Verify with: `cd <submodule> && git merge-base --is-ancestor HEAD origin/main`.
- **All user-facing strings must be localized.** Use `String(localized: "key.name", defaultValue: "English text")` for every string shown in the UI (labels, buttons, menus, dialogs, tooltips, error messages). Keys go in `Resources/Localizable.xcstrings` with translations for all supported languages (currently English and Japanese). Never use bare string literals in SwiftUI `Text()`, `Button()`, alert titles, etc.
- **Shortcut policy:** Every new Programa-owned keyboard shortcut must be added to `KeyboardShortcutSettings`, visible/editable in Settings, supported in `~/.config/programa/settings.json`, and documented in the keyboard shortcut and configuration docs.

## Test quality policy

- Do not add tests that only verify source code text, method signatures, AST fragments, or grep-style patterns.
- Do not add tests that read checked-in metadata or project files such as `Resources/Info.plist`, `project.pbxproj`, `.xcconfig`, or source files only to assert that a key, string, plist entry, or snippet exists.
- Tests must verify observable runtime behavior through executable paths (unit/integration/e2e/CLI), not implementation shape.
- For metadata changes, prefer verifying the built app bundle or the runtime behavior that depends on that metadata, not the checked-in source file.
- If a behavior cannot be exercised end-to-end yet, add a small runtime seam or harness first, then test through that seam.
- If no meaningful behavioral or artifact-level test is practical, skip the fake regression test and state that explicitly.

## Socket command threading policy

- Do not use `DispatchQueue.main.sync` for high-frequency socket telemetry commands (`report_*`, `ports_kick`, status/progress/log metadata updates).
- For telemetry hot paths:
  - Parse and validate arguments off-main.
  - Dedupe/coalesce off-main first.
  - Schedule minimal UI/model mutation with `DispatchQueue.main.async` only when needed.
- Commands that directly manipulate AppKit/Ghostty UI state (focus/select/open/close/send key/input, list/current queries requiring exact synchronous snapshot) are allowed to run on main actor.
- If adding a new socket command, default to off-main handling; require an explicit reason in code comments when main-thread execution is necessary.

## Socket focus policy

- Socket/CLI commands must not steal macOS app focus (no app activation/window raising side effects).
- Only explicit focus-intent commands may mutate in-app focus/selection (`window.focus`, `workspace.select/next/previous/last`, `surface.focus`, `pane.focus/last`, browser focus commands, and v1 focus equivalents).
- All non-focus commands should preserve current user focus context while still applying data/model changes.

## Testing policy

**Never run tests locally.** All tests (E2E, UI, python socket tests) run via GitHub Actions or on the VM.

- **E2E / UI tests:** trigger via `gh workflow run test-e2e.yml` (see programa-hq CLAUDE.md for details)
- **Unit tests:** `xcodebuild -scheme programa-unit` is safe (no app launch), but prefer CI
- **Python socket tests (tests_v2/):** these connect to a running Programa instance's socket. Never launch an untagged `Programa DEV.app` to run them. If you must test locally, use a tagged build's socket (`/tmp/programa-debug-<tag>.sock`) with `PROGRAMA_SOCKET=/tmp/programa-debug-<tag>.sock`
- **Never `open` an untagged `Programa DEV.app`** from DerivedData. It conflicts with the user's running debug instance.

## Ghostty submodule workflow

Ghostty changes must be committed in the `ghostty` submodule and pushed to the Darkroom Engineering ghostty fork.
Keep `docs/ghostty-fork.md` up to date with any fork changes and conflict notes.

```bash
cd ghostty
git remote -v  # origin = upstream, darkroom = fork
git checkout -b <branch>
git add <files>
git commit -m "..."
git push darkroom <branch>
```

To keep the fork up to date with upstream:

```bash
cd ghostty
git fetch origin
git checkout main
git merge origin/main
git push darkroom main
```

Then update the parent repo with the new submodule SHA:

```bash
cd ..
git add ghostty
git commit -m "Update ghostty submodule"
```

## Release

Single lane: every commit on `main` that passes the `CI` workflow is automatically built,
signed, notarized, and published as the latest GitHub release via `.github/workflows/release.yml`
(triggered by `workflow_run` on `CI` completing with `conclusion: success`, on `branches: [main]`).
There is no nightly/beta channel — if something ships broken, fix it forward on `main` and the
next green CI run auto-ships the fix. Auto-ship builds get a monotonic build number derived from
the run ID (injected into `Info.plist` at build time, never committed) and publish to a single,
reused `rolling` GitHub release that is overwritten each ship and marked "latest" — so the
releases page stays clean (one `rolling` entry plus permanent milestone `v*` tags) and
`releases/latest/download/*` always resolves to the newest green build.

Milestone marketing-version bumps (e.g. `0.15.0` → `0.16.0`) are still done manually and can
optionally be tagged as a `vX.Y.Z` marker, which the same `release.yml` also builds on tag push:

```bash
./scripts/bump-version.sh          # bump minor (0.15.0 → 0.16.0)
./scripts/bump-version.sh patch    # bump patch (0.15.0 → 0.15.1)
./scripts/bump-version.sh major    # bump major (0.15.0 → 1.0.0)
./scripts/bump-version.sh 1.0.0    # set specific version
```

This updates both `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` (build number). Then update
`CHANGELOG.md` (the docs changelog page at `web/app/docs/changelog/page.tsx` reads from it), commit,
and optionally tag:

```bash
git tag vX.Y.Z
git push origin vX.Y.Z
gh run watch --repo darkroomengineering/programa
```

Tagging is now optional — it exists only to mark a milestone version in the release history; it is
not required to ship. Regular pushes to `main` ship automatically.

Notes:
- Requires GitHub secrets: `APPLE_CERTIFICATE_BASE64`, `APPLE_CERTIFICATE_PASSWORD`,
  `APPLE_SIGNING_IDENTITY`, `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD`, `APPLE_TEAM_ID`.
- The release asset is `programa-macos.dmg` attached to each release.
- README download button points to `releases/latest/download/programa-macos.dmg`.
- Versioning: bump the minor version for milestone tags unless explicitly asked otherwise.
- Changelog: update `CHANGELOG.md`; docs changelog is rendered from it.
- `workflow_dispatch` on `release.yml` still runs a dry-run build that uploads an artifact instead
  of publishing.
