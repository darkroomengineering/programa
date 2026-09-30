# Inline VS Code (serve-web)

Removed 2026-09-02. Last present at commit 903027ccef. Restore with `git checkout 903027ccef -- Sources/VSCodeIntegration.swift programaTests/ServeWebPortStoreTests.swift`, then re-apply the vscodeInline enum case, panel/menu/palette wiring, and tests removed below (they no longer exist as a clean checkout target since they were edits, not whole-file additions).

## What it did

"Open Folder in VS Code (Inline)" launched `code serve-web` in the background and opened the
resulting web UI inside a Programa browser split, so a VS Code editor could sit next to a
terminal without leaving the app or opening a separate window. It reused the same server
process and port across restarts (persisted to Application Support), reused a persistent
connection token so the browser's auth cookie survived relaunches, and exposed palette
commands to stop and restart the background server. It required the desktop VS Code app to
ship a `code-tunnel` CLI binary; when that binary was missing, the feature was unavailable and
fell back invisibly (the command palette entry and menu item just didn't show/enable).

## How it was wired

- Menu: File > "Open Folder in VS Code (Inline)…" in `Sources/ProgramaApp.swift`.
- Command palette: `palette.openFolderInVSCodeInline` (open-folder panel),
  `palette.vscodeServeWebStop`, `palette.vscodeServeWebRestart`, plus a per-target entry via
  `TerminalDirectoryOpenTarget.vscodeInline` in the generic "open current directory in X" list.
- Settings: none (no toggle; availability was fully derived from whether `code-tunnel` existed
  on disk).
- Localized keys: `menu.file.openFolderInVSCodeInline(.panelTitle/.panelPrompt)`,
  `command.openFolderInVSCodeInline.(title/subtitle)`, `command.vscodeServeWeb(Stop/Restart).title`,
  `menu.openInVSCode` (the inline variant; `menu.openInVSCodeDesktop` for the plain "Open in VS
  Code" case was kept).
- `TerminalDirectoryOpenTarget.vscodeInline` case in `Sources/TerminalDirectoryOpener.swift`
  drove availability detection (required `code-tunnel` to be executable, via
  `VSCodeCLILaunchConfigurationBuilder`) and shared the desktop VS Code's app-bundle candidates.
- `AppDelegate.openDirectoryInInlineVSCode` / `showOpenFolderInInlineVSCodePanel` opened the
  panel and routed the chosen directory into a new browser split.
- `AppDelegate.applicationWillTerminate` called `VSCodeServeWebController.shared.stop()` on quit.
- pbxproj: `VSCodeIntegration.swift` (Sources) and `programaTests/ServeWebPortStoreTests.swift`
  (test Sources) build-phase/file-reference/group entries.
- No socket/CLI/MCP command existed for this feature.

## Files removed and files edited

Removed:
- `Sources/VSCodeIntegration.swift` (`VSCodeServeWebURLBuilder`, `VSCodeCLILaunchConfigurationBuilder`,
  `VSCodeServeWebController`, `ServeWebOutputCollector`, `ServeWebPortStore`)
- `programaTests/ServeWebPortStoreTests.swift`

Edited:
- `Sources/TerminalDirectoryOpener.swift`: dropped the `.vscodeInline` enum case and every
  switch arm referencing it; `isAvailable()` no longer special-cases VS Code CLI-binary
  detection.
- `Sources/ContentView.swift`: dropped the `palette.openFolderInVSCodeInline`,
  `palette.vscodeServeWebStop`, `palette.vscodeServeWebRestart` command-palette contributions,
  their registrations, and the `openFocusedDirectoryInInlineVSCode` /
  `stopInlineVSCodeServeWeb` / `restartInlineVSCodeServeWeb` helpers.
- `Sources/AppDelegate.swift`: dropped `openDirectoryInInlineVSCode`,
  `showOpenFolderInInlineVSCodePanel`, and the `VSCodeServeWebController.shared.stop()` call in
  `applicationWillTerminate`.
- `Sources/ProgramaApp.swift`: dropped the "Open Folder in VS Code (Inline)…" menu button.
- `GhosttyTabs.xcodeproj/project.pbxproj`: dropped 8 entries for the two deleted files.
- `Resources/Localizable.xcstrings`: dropped 8 keys (see above).
- `programaTests/TerminalAndGhosttyTests.swift`: removed
  `testVSCodeInlineRequiresCodeTunnelExecutable` and the `.vscodeInline` assertions inside
  `testAvailableTargetsFallbackToApplicationLookupForVSCodeAliasOutsideApplications`.
- `programaTests/OmnibarAndToolsTests.swift`: removed `VSCodeServeWebURLBuilderTests`,
  `VSCodeCLILaunchConfigurationBuilderTests`, `ServeWebOutputCollectorTests`,
  `VSCodeServeWebControllerTests`.

## What we learned

CHANGELOG.md (0.2.x "Fixed" section) records two shipped bugs this subsystem carried: the
serve-web port and sign-in token did not originally persist across restarts (fixed — port
persisted via `ServeWebPortStore`, connection token persisted to Application Support, both
tagged `#21` in code comments), and the sign-in popup briefly showed `about:blank` before
loading. A review finding ("bounded-input policy is repeatedly applied after allocation") flagged
`VSCodeIntegration.swift:289-307` as one of four call sites that buffer input before enforcing a
size limit — the code as removed did already
carry a `maximumBytes` cap on `ServeWebOutputCollector` (default 1 MiB) with overflow handling,
so this looks like a finding that was addressed after the review; verify the cap in the history
if this is ever rebuilt rather than assuming the cap was always there. The controller used
a generation-counter pattern (`lifecycleGeneration`/`activeLaunchGeneration`) to make
stop-during-launch races safe — worth keeping if this is rebuilt, since serve-web startup was a
multi-second subprocess launch racing against user-triggered stop/restart.

## Why removed and what a future version should do differently

This was a heavyweight, single-purpose integration: a background subprocess, a custom URL
builder, connection-token file management, and a whole browser-embedding code path, all to
avoid alt-tabbing to the desktop VS Code window. It also silently degraded (no error UI) when
`code-tunnel` was missing, which is easy to ship broken without noticing. A future version
should default users to the desktop `.vscode` open target (kept) and only reconsider an inline
browser-embedded editor if there's a concrete user request, at which point it should reuse
Programa's existing browser-split and directory-open primitives rather than re-deriving them.
