# Changelog

All notable changes to Programa are documented here.

Programa is a fork of [cmux](https://github.com/manaflow-ai/cmux); for history prior to the fork, see the upstream changelog.

## [Unreleased]

### Changed
- New installs now start with the minimal workspace layout (theme already follows the system). Anyone who previously toggled the mode keeps their stored setting.
- CI and release policy checks now exercise executable helpers and built artifacts instead of asserting source-file text; release binaries are also checked for the expected architecture before signing.
- Debug and settings UI copy is fully localized in English and Japanese, and obsolete cmux branding and unassigned dark app-icon variants have been removed.
- Markdown panels now route full-document rendering through a renderer-neutral boundary while preserving the existing MarkdownUI appearance and macOS 14 support; relative document links and images resolve from the Markdown file's directory.
- Sparkle was upgraded to 2.9.4, with release builds now verifying the embedded framework version and its signed updater components before notarization.
- Whole-codebase restructuring pass (internal, no behavior change): the remote-daemon stack moved out of `Workspace.swift`, browser data-import out of `BrowserPanel.swift`, v2 browser automation out of `TerminalController.swift`, UI-test harnesses out of `AppDelegate.swift`, and `TabManager`/`GhosttyNSView`/`ContentView` split into per-concern files — the largest source files shrank by 3,000–5,000 lines each, cutting incremental build times. The copy-pasted v1 telemetry-handler skeleton, agent-wrapper commands (Go and Swift), and boilerplate settings accessors were each collapsed onto single shared implementations.

### Fixed
- Debug, Release, and Staging reload entrypoints now prepare GhosttyKit before building; Staging uses the canonical `Programa STAGING` name and `com.darkroom.programa.staging` identity.
- CI now retries only genuine SwiftPM resolution failures and always propagates XCTest failures, including deterministic failures reported as “0 unexpected.”
- CLI command lookup, help, and typed argument validation now complete before opening the app socket, so unknown or malformed invocations cannot connect or trigger focus side effects.
- CLI socket authentication now ignores symlinked, non-regular, foreign-owned, or group/world-accessible password files.
- GhosttyKit cache hits now bypass build locks, stale owners are recovered without stealing live builds, and validated frameworks publish atomically with ownership-safe cleanup.
- Rapid workspace switching and non-focus split reparenting now share one generation-checked focus owner, so delayed callbacks cannot move AppKit input back to a stale workspace or pane.
- Remote agent wrappers now avoid occupied implicit OpenCode ports, keep OMO package metadata isolated from the user's config, and use Programa-owned shim paths. The Release reload helper now locates and launches `Programa.app` after the rebrand.
- Remote-workspace localhost pages now use one browser/proxy alias contract (while accepting the legacy Programa alias), concurrent proxy connections use isolated serial executors so one stalled stream cannot block another, settings files keep applying valid sibling fields when one enum or numeric value is malformed, and browser suggestions contact only the search provider the user selected.
- JSON-RPC now rejects non-object `params` and boolean, fractional, or overflowing integer arguments instead of silently coercing them in workspace, surface, and pane operations. Session autosave change detection now derives from the exact snapshot being written, so same-count metadata and panel-title changes are not skipped.
- Port telemetry from shells and agents (`report_ports`, `clear_ports`) no longer blocks on the app's main thread, so a busy UI can't stall the socket.
- Notifications in multi-window sessions now respect which window owns the tab: the tab in front of you no longer fires an external banner, and background tabs in other windows are no longer misjudged as focused.
- Closing a pane now cleans up everything closing a single surface does — stale unread badges and leaked per-panel state are gone.
- `send`/`send_surface` now refresh the terminal after injecting text (parity with v2 `surface.send_text`), so socket-driven agents see output without a focus change.
- CI: removed a stale release guard that blocked all PRs after the first single-lane auto-ship, and fixed a startup race plus re-run churn in the typing-lag regression job.

## [0.2.0] - 2026-07-02

### Changed
- Completed the rename to **Programa** across the whole app and CLI. The command-line tool is now `programa`, and configuration lives in `~/.config/programa/` (`programa.json`, `settings.json`). Existing `~/.config/cmux` files, project-root `cmux.json`, and saved preferences are migrated automatically, so upgrading keeps your setup.

### Added
- New app icon.
- Setting to disable terminal scrollback persistence.
- Cmd+F find support in Markdown panels.
- `browser.proxy` config key for per-WebView proxy settings.

### Fixed
- Split-pane dividers are now visible on dark themes.
- Browser downloads, including those started from iframes/subframes, now save to ~/Downloads.
- VS Code serve-web port and sign-in now persist across restarts.
- VS Code sign-in popup no longer briefly shows about:blank before loading.
- Color-picker hue indicator no longer jumps while adjusting brightness.

## [0.1.0] - 2026-06-25
- First Programa release: forked from cmux and rebranded under Darkroom Engineering.
- Signed and notarized DMG distributed from the Programa repository with its own
  Sparkle auto-update feed.
