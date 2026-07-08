# Changelog

All notable changes to Programa are documented here.

Programa is a fork of [cmux](https://github.com/manaflow-ai/cmux); for history prior to the fork, see the upstream changelog.

## [Unreleased]

### Changed
- New installs now start with the minimal workspace layout (theme already follows the system). Anyone who previously toggled the mode keeps their stored setting.
- Whole-codebase restructuring pass (internal, no behavior change): the remote-daemon stack moved out of `Workspace.swift`, browser data-import out of `BrowserPanel.swift`, v2 browser automation out of `TerminalController.swift`, UI-test harnesses out of `AppDelegate.swift`, and `TabManager`/`GhosttyNSView`/`ContentView` split into per-concern files — the largest source files shrank by 3,000–5,000 lines each, cutting incremental build times. The copy-pasted v1 telemetry-handler skeleton, agent-wrapper commands (Go and Swift), and boilerplate settings accessors were each collapsed onto single shared implementations.

### Fixed
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
