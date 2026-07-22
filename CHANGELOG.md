# Changelog

All notable changes to Programa are documented here.

Programa is a fork of [cmux](https://github.com/manaflow-ai/cmux); for history prior to the fork, see the upstream changelog.

## [Unreleased]

### Added
- Native git worktree workflow: `programa worktree create <branch>` checks out a branch into its own worktree and opens it as a new workspace, placed next to its parent repo's workspace in the sidebar (with a small fork-glyph badge). `programa worktree open`/`remove`/`list` round out the lifecycle; `remove` never deletes the branch, and a dirty worktree requires an explicit `--force`. Also available over the socket as `worktree.create/open/remove/list` for agents/automation. New `worktrees.directory` setting (default `~/.programa/worktrees`) controls where new worktrees are created.
- Named layout configs: `programa layout save <name>` snapshots the current workspace's pane/split layout (geometry, working directories, browser URLs), and `programa layout apply <name>` replays it into a new or existing workspace — also reachable from the command palette as "Apply layout: <name>". `worktree create --layout <name>` applies a saved layout straight into a new worktree's workspace, with relative directories resolved against the worktree root.
- Codex integration now matches Claude Code: "Needs input" notifications, guaranteed cleanup when a session dies without a clean stop, an "Install Codex Integration…" menu item, and `programa codex install-integration` naming (the old install-hooks name still works). Also fixed duplicate desktop notifications for Codex sessions — suppression of raw terminal notifications now applies to any hook-managed agent, not just Claude Code.
- OpenCode integration: session status, "Needs input" and completion notifications now work for OpenCode too, via a small local plugin. "Install OpenCode Integration…" in the File menu (or programa opencode install-integration) shows exactly what will be written and asks first; uninstall is symmetric and never touches a file you've customized.
- File menu: "Install Claude Code Integration…" opens a terminal running `programa claude install-integration`, which shows the exact diff it wants to make to your Claude settings and asks before writing. It durably registers Programa's lifecycle hooks so the integration works from any terminal, not just inside Programa; hooks silently no-op elsewhere. Fully reversible with `programa claude uninstall-integration`; your own hooks are never touched.
- Closing a terminal is now undoable for 5 seconds: Cmd+Shift+T brings it back with its process still running — whether you closed it or an agent did. The confirmation dialog still appears when a command is actively running.
- Sidebar agent status badges (working/blocked/idle) now also work for CLIs with no installed integration — Gemini CLI, GitHub Copilot CLI, Cursor Agent, Aider — by pattern-matching what's visibly on screen against a small per-agent manifest, entirely on-device. A hooks-managed session (Claude Code, Codex, OpenCode) always takes priority: this only kicks in when nothing has reported a real status yet. New "Screen-Based Agent Detection" toggle in Settings → Automation, on by default. Manifests are user-overridable at `~/.config/programa/agent-detection/<agent>.json` for anyone who wants to tune the patterns for their own setup.

### Changed
- CLI target arguments no longer accept bare indexes: anywhere a command takes a window, workspace, pane, or surface, pass a UUID or short ref (workspace:2, surface:4). Indexes shift when things open or close, so agents holding one could hit the wrong target; the error now names the accepted formats. Positional options like reorder --index and browser tab ordinals are unchanged.
- New installs now start with the minimal workspace layout (theme already follows the system). Anyone who previously toggled the mode keeps their stored setting.
- CI and release policy checks now exercise executable helpers and built artifacts instead of asserting source-file text; release binaries are also checked for the expected architecture before signing.
- Debug and settings UI copy is fully localized in English and Japanese, and obsolete cmux branding and unassigned dark app-icon variants have been removed.
- Markdown panels now route full-document rendering through a renderer-neutral boundary while preserving the existing MarkdownUI appearance and macOS 14 support; relative document links and images resolve from the Markdown file's directory.
- Sparkle was upgraded to 2.9.4, with release builds now verifying the embedded framework version and its signed updater components before notarization.
- Second restructuring pass (internal, no behavior change): the remaining god files were split into per-concern files — `ContentView.swift` (7.9k → 5.8k lines), `GhosttyTerminalView.swift` (8.4k → stub, with `GhosttyApp`, `TerminalSurface`, `GhosttyNSView`, and the surface scroll view each in their own file), `Workspace.swift` (5.7k → 2.1k), and the browser Panel/View/Portal trio (13.1k → 6.1k across the three originals). The socket protocol's method list now lives in one `V2CommandCatalog` (the hand-maintained capabilities array is gone), 79 copy-pasted parameter-validation blocks collapsed onto a single helper, and per-command CLI help text moved into the command descriptor table, deleting the duplicate usage switch. Typing-latency-sensitive paths (`hitTest`, `forceRefresh`, key handling) were moved byte-for-byte, and CLI help output is byte-identical to the previous release.
- Whole-codebase restructuring pass (internal, no behavior change): the remote-daemon stack moved out of `Workspace.swift`, browser data-import out of `BrowserPanel.swift`, v2 browser automation out of `TerminalController.swift`, UI-test harnesses out of `AppDelegate.swift`, and `TabManager`/`GhosttyNSView`/`ContentView` split into per-concern files — the largest source files shrank by 3,000–5,000 lines each, cutting incremental build times. The copy-pasted v1 telemetry-handler skeleton, agent-wrapper commands (Go and Swift), and boilerplate settings accessors were each collapsed onto single shared implementations.

### Fixed
- Closing a terminal right after opening it no longer shows a spurious "close tab?" confirmation — before the shell has attached there is nothing to lose, so nothing to confirm. (ported from upstream cmux)
- High-resolution mouse wheels (Logitech free-spin and similar) no longer runaway-scroll in terminals: the 2x precise-delta boost now applies only to gesture-driven devices like trackpads and Magic Mouse. (ported from upstream cmux)
- Restored windows now find their monitor by a stable per-display identity instead of the raw display number, which macOS can silently reassign after unplugging a monitor or sleep/wake — so windows stop landing on the wrong screen or off-screen after display changes. Old saved sessions restore unchanged. (ported from upstream cmux)
- Sidebar titles for split workspaces now keep updating: the focused pane's title changes (Claude Code spinners, OSC titles) reach the sidebar even while the workspace is in the background, and switching panes re-derives the workspace title from the newly focused pane. Previously any workspace with more than one pane had its sidebar title frozen at whatever it was when the split was created.
- Shells and agent CLIs that rewrite the terminal title on every render (progress spinners, Claude Code) no longer flood the app with per-keystroke title updates — updates are coalesced to at most one per surface every 50ms, with the final title always delivered. Debug background logging also moved off the calling thread, so neither path can add typing latency anymore. (ported from upstream cmux)
- The app no longer crashes at launch on macOS 26+ when an SF Symbol is laid out before its window is visible — symbol raster sizes are now driven from an explicit frame instead of unresolved font metrics. (ported from upstream cmux)
- A terminal no longer goes blank until the next tab switch when an OSC completion notification toggles its unread ring — ring-only changes no longer rebind the terminal portal. (ported from upstream cmux)
- tmux-compat format strings now report real session/window identity: stable per-workspace session ids instead of `$0` everywhere, and only the actually-focused window claims `window_active`/`*` flags, so statuslines and scripts parsing across panes see correct state. (ported from upstream cmux)
- The bonsplit debug event log now uses non-throwing file APIs, removing a crash risk if the log file disappears mid-write. An opencode.json parse error also no longer leaks the user's home path into agent output.
- `programa.json`/`cmux.json` command configs now accept `//` and `/* */` comments and trailing commas, so a hand-edited config with a note like `// dev commands` no longer fails to load with a cryptic parse error.
- Release signing now proceeds inside-out without `--deep`, so the bundled `programa` and `ghostty` tools no longer inherit the app's camera, microphone, automation, JIT, or library-validation entitlements; the signed artifact is gated before notarization.
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
- Instant agent on a keystroke: Cmd+Shift+C opens a new workspace in your current project directory with Claude Code already launching. The shortcut is editable in Settings and settings.json, and the command is also in the command palette as "New Claude Code Workspace".
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
