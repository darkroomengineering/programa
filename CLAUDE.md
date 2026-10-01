# Programa agent notes

## Initial setup

Run the setup script to initialize submodules and build GhosttyKit:

```bash
./scripts/setup.sh
```

## Repository map

- `Sources/`, `CLI/`, `CLI-MCP/`: the macOS app, the `programa` CLI and the MCP server (Swift).
- `contracts/v2/`: the socket API contract; it generates `Sources/V2CommandCatalog.swift` and `CLI/V2MethodNames.swift`.
- `core/`: the Rust shared core and `programad`, used by the Windows app only (the macOS app does not link it). `cd core && cargo test` (and the same in `core/crates/programa-terminal`) is the one test suite that runs locally.
- `windows/`: the WinUI 3 app, built by `scripts/build-windows.ps1` in the `windows-build` CI job.
- `vendor/bonsplit/`: vendored split/tab library (not a submodule). `ghostty/`: the Ghostty submodule.

## Local dev

After making code changes, always run the reload script with a tag to build the Debug app:

```bash
./scripts/reload.sh --tag fix-zsh-autosuggestions
```

By default, `reload.sh` builds but does **not** launch the app. The script prints the `.app` path so the user can cmd-click to open it. Pass `--launch` to kill any existing instance and open the app automatically:

```bash
./scripts/reload.sh --tag fix-zsh-autosuggestions --launch
```

By default, every `--tag` shares one DerivedData directory (`programa-shared`), so switching tags or re-running the same tag is a warm incremental build instead of a cold one. Tags still get their own bundle id, app name, socket, and log — only the build directory is shared. Pass `--isolated` to give a tag its own DerivedData directory again (today's old default), e.g. when you need two tags to build fully independently:

```bash
./scripts/reload.sh --tag fix-zsh-autosuggestions --isolated
```

Command-line builds via `reload.sh` also pass `COMPILER_INDEX_STORE_ENABLE=NO` to xcodebuild, since a CLI build doesn't need Xcode's editor indexing. This doesn't affect indexing when the project is opened in Xcode.app directly.

`reload.sh` prints an `App path:` line with the absolute path to the built `.app`. Use that path to build a cmd-clickable `file://` URL. Steps:

1. Grab the path from the `App path:` line in `reload.sh` output.
2. Prepend `file://` and URL-encode spaces as `%20`. Do not hardcode any part of the path.
3. Format it as a markdown link using the template for your agent type.

Example (shared DerivedData, the default). If `reload.sh` output contains:
```
App path:
  /Users/someone/Library/Developer/Xcode/DerivedData/programa-shared/Build/Products/Debug/Programa DEV my-tag.app
```

**Claude Code** outputs:
```markdown
=======================================================
[Programa DEV my-tag.app](file:///Users/someone/Library/Developer/Xcode/DerivedData/programa-shared/Build/Products/Debug/Programa%20DEV%20my-tag.app)
=======================================================
```

**Codex** outputs:
```
=======================================================
[my-tag: file:///Users/someone/Library/Developer/Xcode/DerivedData/programa-shared/Build/Products/Debug/Programa%20DEV%20my-tag.app](file:///Users/someone/Library/Developer/Xcode/DerivedData/programa-shared/Build/Products/Debug/Programa%20DEV%20my-tag.app)
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
cd ghostty && zig build -Demit-xcframework=true -Demit-macos-app=false -Dxcframework-target=native -Doptimize=ReleaseFast
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
- `reload.sh` updates `/tmp/programa-cli` and `$HOME/.local/bin/programa-dev` to that CLI. It does not put a `programa` command on `PATH`; `--install-shim` also writes a `programa` shim into the first writable `PATH` directory ahead of the installed app, which then shadows the installed CLI for every shell and agent hook until you delete it

- Implementation: `vendor/bonsplit/Sources/Bonsplit/Public/DebugEventLog.swift`
- Free function `dlog("message")` — logs with timestamp and appends to file in real time
- Entire file is `#if DEBUG`; all call sites must be wrapped in `#if DEBUG` / `#endif`
- 500-entry ring buffer; `DebugEventLog.shared.dump()` writes full buffer to file
- Key events logged in `AppDelegate.swift` (monitor, performKeyEquivalent)
- Mouse/UI events logged inline in views (ContentView, BrowserPanelView, etc.)
- Focus events: `focus.panel`, `focus.bonsplit`, `focus.firstResponder`, `focus.moveFocus`
- Bonsplit events: `tab.select`, `tab.close`, `tab.dragStart`, `tab.drop`, `pane.focus`, `pane.drop`, `divider.dragStart`
- `GhosttyApp.logBackground` background events log to a separate companion file with `-bg` inserted before `.log`, e.g. `/tmp/programa-debug-<tag>-bg.log` (override with `PROGRAMA_DEBUG_BG_LOG`)

## Regression test commit policy

When adding a regression test for a bug fix, use a two-commit structure so CI proves the test catches the bug:

1. **Commit 1:** Add the failing test only (no fix). CI should go red.
2. **Commit 2:** Add the fix. CI should go green.

This makes it visible in the GitHub PR UI (Commits tab, check statuses) that the test genuinely fails without the fix.

## Debug menu

The app has a **Debug** menu in the macOS menu bar (only in DEBUG builds). Use it for visual iteration:

- **Debug > Debug Windows** contains panels for tuning layout, colors, and behavior. Entries are alphabetical with no dividers.
- To add a debug toggle or visual option: create an `NSWindowController` subclass with a `shared` singleton, add it to the "Debug Windows" menu in `Sources/ProgramaApp.swift`, and add a SwiftUI view with `@AppStorage` bindings for live changes.
- When the user says "debug menu" or "debug window", they mean this menu, not `defaults write`.

## Pitfalls

- **Custom UTTypes** for drag-and-drop must be declared in `Resources/Info.plist` under `UTExportedTypeDeclarations` (e.g. `com.splittabbar.tabtransfer`, `com.darkroom.programa.sidebar-tab-reorder`).
- Do not add an app-level display link or manual `ghostty_surface_draw` loop; rely on Ghostty wakeups/renderer to avoid typing lag.
- **Typing-latency-sensitive paths** (read carefully before touching these areas):
  - `WindowTerminalHostView.hitTest()` in `Sources/WindowTerminalHostView.swift`: called on every event including keyboard. Keyboard events (`.keyDown`/`.keyUp`/`.flagsChanged`) take an early `switch currentEvent?.type` fast path; everything else — all pointer events, and an ambiguous/nil `currentEvent` — must fall through to the full divider/sidebar/drag routing below it. Do not add work to that keyboard fast path.
  - `NSWindow.programa_sendEvent` in `Sources/WindowSwizzles.swift`: runs for every event. The hit-view context it caches is only ever read for pointer-down events, so it is computed only for those — do not restore an unconditional hit-test here (#183).
  - `TabItemView` in `Sources/TabItemView.swift`: uses `Equatable` conformance + `.equatable()` to skip body re-evaluation during typing. Do not add `@EnvironmentObject`, `@ObservedObject` (besides `tab`), or `@Binding` properties without updating the `==` function. Do not remove `.equatable()` from the ForEach call site in `Sources/VerticalTabsSidebar.swift`. Do not read `tabManager` or `notificationStore` in the body; use the precomputed `let` parameters instead.
  - `TerminalSurface.forceRefresh()` in `Sources/TerminalSurface.swift`: called on every keystroke. Do not add allocations, file I/O, or formatting here.
- **Terminal find layering contract:** `SurfaceSearchOverlay` must be mounted from `GhosttySurfaceScrollView` in `Sources/GhosttySurfaceScrollView.swift` (AppKit portal layer), not from SwiftUI panel containers such as `Sources/Panels/TerminalPanelView.swift`. Portal-hosted terminal views can sit above SwiftUI during split/workspace churn.
- **Submodule safety:** When modifying a submodule (ghostty), always push the submodule commit to its remote `main` branch BEFORE committing the updated pointer in the parent repo. Never commit on a detached HEAD or temporary branch — the commit will be orphaned and lost. Verify with: `cd <submodule> && git merge-base --is-ancestor HEAD origin/main`. Note: `vendor/bonsplit` is NOT a submodule — it is vendored in-tree (MIT, from the manaflow-ai fork); edit and commit it like any other source directory.
- **All user-facing strings must be localized.** Use `String(localized: "key.name", defaultValue: "English text")` for every string shown in the UI (labels, buttons, menus, dialogs, tooltips, error messages). Keys go in `Resources/Localizable.xcstrings` with translations for all supported languages (currently English and Japanese). Never use bare string literals in SwiftUI `Text()`, `Button()`, alert titles, etc.
- **Shortcut policy:** Every new Programa-owned keyboard shortcut must be added to `KeyboardShortcutSettings`, visible/editable in Settings, supported in `~/.config/programa/settings.json`, and documented in the keyboard shortcut and configuration docs.

## CI gates

These run in CI; run the relevant one before pushing:

- `python3 scripts/check-structural-budgets.py`: line budgets for lifecycle owner files. `CLI/programa.swift`, `CLI/CLI+Hooks.swift`, `Sources/TerminalController.swift` and `Sources/CommandPaletteController.swift` sit at their cap, so free lines (or move code into a new file) before adding any.
- `scripts/check-v2-contract.sh`: v2 socket methods are contract-first. Edit `contracts/v2/methods.json`, then `python3 scripts/gen-v2-contract.py`; never hand-edit the generated Swift.
- `python3 scripts/check-settings-docs.py`: every settings key and shortcut action is documented.
- New Swift files need four `project.pbxproj` entries (PBXBuildFile, PBXFileReference, group child, Sources build phase) or the build fails with "cannot find type in scope".
- Every new chrome or overlay `NSHostingView` sets `safeAreaRegions = []`.
- Files that call `dlog` import `Bonsplit` and wrap the call in `#if DEBUG`.

## Test quality policy

- Do not add tests that only verify source code text, method signatures, AST fragments, or grep-style patterns.
- Do not add tests that read checked-in metadata or project files such as `Resources/Info.plist`, `project.pbxproj`, `.xcconfig`, or source files only to assert that a key, string, plist entry, or snippet exists.
- Tests must verify observable runtime behavior through executable paths (unit/integration/e2e/CLI), not implementation shape.
- For metadata changes, prefer verifying the built app bundle or the runtime behavior that depends on that metadata, not the checked-in source file.
- If a behavior cannot be exercised end-to-end yet, add a small runtime seam or harness first, then test through that seam.
- If no meaningful behavioral or artifact-level test is practical, skip the fake regression test and state that explicitly.

## Socket command threading policy

- Do not use `DispatchQueue.main.sync` for high-frequency socket telemetry commands (`surface.report_*`, `surface.ports_kick`, status/progress/log metadata updates).
- For telemetry hot paths:
  - Parse and validate arguments off-main.
  - Dedupe/coalesce off-main first.
  - Schedule minimal UI/model mutation with `DispatchQueue.main.async` only when needed.
- Commands that directly manipulate AppKit/Ghostty UI state (focus/select/open/close/send key/input, list/current queries requiring exact synchronous snapshot) are allowed to run on main actor.
- If adding a new socket command, default to off-main handling; require an explicit reason in code comments when main-thread execution is necessary.

## Socket focus policy

- Socket/CLI commands must not steal macOS app focus (no app activation/window raising side effects).
- Only explicit focus-intent commands may mutate in-app focus/selection (`window.focus`, `workspace.select/next/previous/last`, `surface.focus`, `pane.focus/last`, browser focus commands).
- All non-focus commands should preserve current user focus context while still applying data/model changes.

## Testing policy

**Never run tests locally.** All tests (E2E, UI, python socket tests) run via GitHub Actions or on the VM. The exceptions touch no app state: `cd core && cargo test` and `node --test scripts/*.test.js`.

- **E2E / UI tests:** trigger `.github/workflows/test-e2e.yml` with `gh workflow run test-e2e.yml -f test_filter=<TestClass[/testMethod]>`. Optional inputs: `-f ref=<branch-or-sha>` (default: the current ref), `-f test_timeout=<seconds>` (default 120), `-f record_video=true`, `-f runner=macos-26|macos-15|macos-14` (default `macos-15`).
- **Unit tests:** run in CI. The `programa-unit` scheme is app-hosted: its default `TEST_HOST` is the untagged Debug app, which opens windows, starts shells and writes preferences, so never run it as is. The only local path is the tagged build-for-testing recipe in `docs/testing-layout.md` ("Running them").
- **Python socket tests (tests_v2/):** these connect to a running Programa instance's socket. Never launch an untagged `Programa DEV.app` to run them. If you must test locally, point both socket variables at a tagged build's socket and drop the production ids; inside a Programa terminal `PROGRAMA_SOCKET_PATH` otherwise still targets the production app:

  ```bash
  unset PROGRAMA_SOCKET; export PROGRAMA_SOCKET_PATH=/tmp/programa-debug-<tag>.sock PROGRAMA_SOCKET=/tmp/programa-debug-<tag>.sock
  unset PROGRAMA_WORKSPACE_ID PROGRAMA_SURFACE_ID PROGRAMA_TAB_ID PROGRAMA_PANEL_ID
  ```
- **Never `open` an untagged `Programa DEV.app`** from DerivedData. It conflicts with the user's running debug instance.

## Ghostty submodule workflow

Ghostty changes must be committed in the `ghostty` submodule and pushed to the Darkroom Engineering ghostty fork.
Keep `docs/ghostty-fork.md` up to date with any fork changes and conflict notes.

In the `ghostty` checkout, `origin` is the Darkroom Engineering fork
(`darkroomengineering/ghostty`). Upstream Ghostty is not configured as a remote by default; add
it yourself (`git remote add upstream https://github.com/ghostty-org/ghostty.git`) when you need
to compare against it.

Branch fork work off the SHA the parent repo pins, not off `origin/main`. The fork's `main` is
far ahead of the pin, and moving the pin to it pulls in unrelated upstream changes.

```bash
cd ghostty
git checkout -b <branch>    # from the pinned commit
git add <files>
git commit -m "..."
git push origin <branch>
```

Push the submodule commit to the fork before committing the new pointer in the parent repo.

Then update the parent repo with the new submodule SHA:

```bash
cd ..
git add ghostty
git commit -m "Update ghostty submodule"
```

## Release

Every commit on `main` that passes `CI` is built, signed, notarized and published to the
single `rolling` GitHub release by `.github/workflows/release.yml`. There is no nightly or
beta channel; fix broken ships forward on `main`. The build number comes from the workflow
run id, not from the committed `CURRENT_PROJECT_VERSION`. Milestone bumps use
`./scripts/bump-version.sh` and a `CHANGELOG.md` entry. macOS ships independently of the
Windows build.

Full details, the required secrets and the release asset layout are in
[docs/release.md](docs/release.md).
