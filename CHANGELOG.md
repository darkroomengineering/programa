# Changelog

All notable changes to Programa are documented here.

Programa is a fork of [cmux](https://github.com/manaflow-ai/cmux); for history prior to the fork, see the upstream changelog.

## [Unreleased]

## [0.5.0] - 2026-09-16

### Removed
- SSH remote workspaces and the `programa ssh` command. The remote daemon, its release assets, and the browser proxy routing that went with it are gone; workspaces are local only. See `docs/removed/ssh-remote-workspaces.md`.
- The mobile bridge and the iOS companion app, including the Phone tab in Settings and the iroh transport that shipped inside the app.
- The browser data import wizard, browser extensions, and the React Grab overlay. Design Mode stays and is reachable through the browser automation API.
- AppleScript support, the inline VS Code panel, and custom notification sound files. The system sound picker and the plain "Open in VS Code" menu item remain.
- Every removal is recorded under `docs/removed/`, with the commit to restore from and what we learned while it was in the app.

### Added
- Agent Overview is available from the command palette and an optional configurable shortcut, with name search and All, Needs input, and Failed filters.
- Notifications now include unread filtering, read/unread actions, subtitles, and expandable messages.
- Agent Overview now gives one place to see every Programa workspace, worktree, helper, and terminal. Claude helpers appear and finish automatically; terminal output stays hidden until requested. Users can open terminals, send messages, stop work, review changes, and copy output. New helpers open as nested workspaces in the same folder, or use a separate Git worktree only when they explicitly need one.
- A local Git workspace can now become a persistent worktree folder from its right-click menu. Worktree workspaces created from that menu nest beneath it, can be collapsed, and restore in the same hierarchy without changing or deleting their Git branches.
- Workspace colors are now remembered by local folder and automatically reused when that folder opens in a new workspace.
- New setting, off by default: open a browser split beside the terminal whenever a new agent workspace is created (⌘⇧C, `programa` helper agents, and `race`). Also `automation.openBrowserWithAgentSplits` in settings.json.
- Programa now runs natively on Windows (WinUI 3), sharing workspace, tab, split, and session semantics with the macOS app through a new Rust core. It's a preview: the download is unsigned (no Windows publisher-signing certificate yet), and interactive validation on real Windows hardware (pointer, IME, theme, accessibility) is still pending. Every rolling release now carries both `programa-macos.dmg` and `programa-windows.exe`.
- A shared Rust workspace core (`core/`) now carries the `programad` daemon — PTYs, a session write-ahead log, and socket-based state handoff — as groundwork for a single process that owns sessions across platforms. The daemon can hold the same workspace/pane/surface state the macOS app already keeps in-process, over its own socket. Nothing in the shipping macOS app talks to it yet (#345).
- The socket API's v2 method list now lives in one machine-readable contract; the Swift command catalog, CLI method names, and a typed Python test client are generated from it, and CI fails on any drift between them instead of surfacing it at runtime (#338).
- Claude Code, Codex, and OpenCode hooks now report normalized agent lifecycle events (session start/exit, turn start/complete/abort, permission requests, input requests, item progress) through one `agent.event` method, feeding the same sidebar working/blocked/idle state Programa already showed (#340).

### Changed
- The Windows download is 90 MB instead of 221 MB: the single-file bundle is compressed, only English and Japanese resources ship, and the native libraries are built size-optimized and stripped. Startup-critical terminal code keeps full optimization (#348).
- Removed unused UI helpers, speculative agent lookup state, impossible internal worktree outcomes, and orphan SSH fixtures. Development setup reuses the existing Zig validation; E2E and Depot workflows reuse the checksum-verified GhosttyKit downloader, and Depot preserves failing test exit codes.
- Tagged development builds automatically retain the current build and two recent inactive builds, preserving running apps and concurrent builds during cleanup.
- The releases page now holds one entry, the rolling release. Candidates stay private drafts (one kept for rollback) and milestone tags no longer publish a separate release (#349).
- Added `ProgramaCore`, one seam between the app and git-metadata probes, port scanning, session snapshots, and agent activity. Today's code sits behind it unchanged; later, an out-of-process core can replace it without scattering remote/local branches through the workspace model. Behavior is unchanged (#339).
- The release pipeline now builds, verifies, and publishes the macOS and Windows builds together from one rolling GitHub release, with matching build-specific archives kept for rollback.
- README now leads with what Programa actually is against tmux and cmux, with a refreshed hero screenshot (#343).

### Fixed
- Closing a window keeps its sessions available for reopening from the Dock or New Window. Explicitly closing a workspace still ends its sessions (#336).
- Failed session saves cancel quitting, and replacement instances wait for the previous instance to finish saving before restoring sessions (#336).
- Provider usage uses a compact layout with consistent remaining-capacity bars. Empty window chrome and tab strips support native dragging and the system titlebar double-click action.
- Autosave acknowledges completed disk writes, retries failures, and preserves prompt-save requests during an ongoing write. Saved sessions no longer expire solely because they remained unclaimed for an hour; fresh-shell recovery is labeled explicitly.
- Scrollback restoration tracks effective terminal colors without growing style history. Fully hidden windows can release all idle terminal graphics while retaining their sessions.
- Worktrees keep their requested workspace parent across session restore, and selected Solid Fill rows retain their workspace color rail.
- Terminals no longer break after the Mac sleeps. The session holder measured heartbeat silence on the wall clock, so any sleep longer than six seconds made it declare every terminal dead on wake and start reading the same PTYs the app was using; it now counts awake time only, and the app re-checks its sessions and redraws on wake (#351).
- Fixes from the September 11 audit: browser dialog and element-reference handling, review probes that surfaced git failures instead of empty diffs, update-check timeouts, scrollback privacy across session persistence, CLI authentication for alternate clients, hook installation edge cases, and several test harness races (#334).
- Idle CPU with an open window dropped from roughly 12 to 20 percent of a core to about 1 percent. The workspace pane overlay kept a display-rate animation timeline running for the life of every window; it now mounts one only while an attention flash is animating (#335).
- The dock icon no longer costs 32 MB of resident memory. The light and dark icon assets are declared as 512pt @2x, so AppKit decodes them at 1024 pixels instead of rasterizing a 2048 pixel copy (#335).
- Closing a workspace no longer leaves its Workspace object alive through the sidebar row's hover closure (#335).
- Windows terminal output could be lost right as a shell process exited: ConPTY output now drains through a bounded retry after the child exits instead of stopping early (#341).
- The release step that checks the Windows executable's version and identity now waits for the file to finish writing instead of racing it (#342).
- Pending review comments survive session restore and remain available for retry or copying when the source terminal cannot accept them.
- Incoming notifications no longer reset a valid keyboard selection in the Notifications page.
- Socket and typing-lag CI jobs cache the DerivedData paths they actually build into.
- Release publishing accepts the previous ten-asset candidate manifests again, so the first ship after the remote daemon removal no longer fails.
- Remote and local CLI clients now share the v2 JSON-RPC and `programa-relay-auth` contracts, password-protected sockets work through MCP, and remote bootstrap files, tmux wait signals, relay diagnostics, and downloaded daemon artifacts have bounded ownership and lifetime.
- Session recovery now rejects oversized or structurally invalid snapshots before reconstruction, quarantines corrupt primaries, caps history scanning, elects escrow holders without unlinking live or indeterminate sockets, and terminates timed-out subprocess trees without leaving descendants or pipe readers behind.
- The iOS client now uses device-only Keychain credentials, bounded newline framing, cancellation-safe request and pairing deadlines, settled path selection, server-reconciled CloudKit subscriptions, and a generation-owned reconnect loop. The completed duplicate macOS transport spike has been removed.
- Browser extensions now require explicit permission consent and support revocation; browser downloads, history, review diffs, VS Code discovery output, and automation state enforce bounds while data is read.
- Port settings are validated within the TCP range without trapping arithmetic, managed settings and directory trust mutations are serialized, notification routing explicitly enters the main actor, and TestFlight signing restores the developer state it temporarily changes.
- CI now pins every external action by commit, builds and locates artifacts through job-specific DerivedData paths, enforces the repository's Zig 0.16.0 source of truth, and builds the remote daemon with Go 1.26.7.
- Sparkle is updated to 2.9.6, which hardens delta-update destinations against symlinks, rejects package installation after signing validation fails, and safely moves installer archives.
- Provider usage now completes the Codex app-server handshake before reading limits, verifies Claude's current login before trusting its bounded fresh cache, hides signed-out providers, refreshes whenever its compact sidebar control opens, and sizes the popover to its visible content.
- The provider usage popover no longer reports that Claude and Codex usage could not be read: reading the Codex app server's silent stderr through `FileHandle.bytes` blocked Foundation's shared pipe reader, so both probes timed out together. A signed-out Claude CLI now hides the provider instead of showing an error, and the sidebar help and usage icons sit on a slightly wider pitch.
- Browser context-menu actions no longer crash when a Google redirect contains repeated query parameters.
- Crash recovery no longer opens a second window full of empty workspaces when only some detached terminal sessions can be reattached. The recovery window now contains only live recovered sessions and closes when none recover.
- Closing a window now tears down every timer, observer, task, panel, and workspace it owns, so closed windows cannot keep empty workspaces alive or reappear in a later session snapshot.
- The title-bar hide-sidebar button now always toggles the sidebar belonging to its own window instead of relying on whichever window was last active.
- Provider usage is now available on demand from a sidebar icon and shows every signed-in supported provider, without continuously polling while the popover is closed.
- Browser downloads now keep the completed temporary file available when moving it to the destination fails, so a finalization error cannot silently discard the download.
- An ordinary documentation-only commit on `main` can no longer strand the latest green app revision; it now starts CI and can drive the exact-tip release pipeline.
- Browser automation now reuses element references within a page, caps their count and selector bytes, bounds DOM visits and every snapshot payload field, preserves state across successful tab transfers, and finalizes failed transfers or closed tabs, workspaces, and windows exactly once.
- Revoking a paired mobile device now also blocks connections still being admitted, and disabling the bridge closes active phone sessions.
- An unreadable browser history file no longer causes repeated disk reads on every omnibar keystroke.
- Clearing browser history now stays cleared after a temporary disk deletion failure or app termination.
- Escape now cancels in-progress terminal input for Japanese, Chinese, and Korean keyboards even while the command palette is still opening or has just closed.
- Cmd+D now confirms only the close alert in the window that received the shortcut, so another window's alert can no longer close the wrong tab or steal a split command.
- Concurrent Programa launches now use exact process identities and a durable per-target responsive state so overlapping contenders cannot force-close a healthy instance. Requests keep generation-owned cleanup, recognized stale state is pruned in bounded batches, live requesters are authenticated from running code, and an unresponsive instance can only be force-closed through a Cancel-first data-loss warning.
- Browser imports now treat Unicode domains and their Punycode forms as the same filter, so internationalized domains no longer silently import zero matching cookies or history entries.
- Socket automation no longer hangs on split Unicode requests or unsubscribe races, and malformed telemetry can no longer crash the app or grow retained workspace state without bounds.
- Large command output no longer deadlocks the CLI or background Git checks, and stalled Git probes now time out instead of accumulating work.
- Browser favicons now have strict download and decode limits, so a hostile or broken site cannot consume unbounded memory or restore a stale icon after navigation.
- Restoring a damaged session no longer crashes when two saved panels share an ID, cancelling a system shutdown no longer leaves the next snapshot marked as a clean quit, and the configurable review shortcut works again.
- Browser automation now returns stable workspace and surface references, while obsolete native dialog state and macOS 11 compatibility branches have been removed. CI also fails clearly when a matching prebuilt GhosttyKit checksum is unavailable instead of silently compiling a different dependency from source.
- Closing a terminal tab or a workspace now actually ends the session. Anything running in it, an agent included, was being kept alive in the background after the tab disappeared: invisible, still using memory, and unable to talk back to the app. Quitting still preserves your sessions so they come back on the next launch.
- The app no longer freezes on the first launch after an update while it is restoring your terminals. Restoring a session with a long transcript could wedge the whole app: no window, no input, and force-quitting was the only way out, which lost every session you had open. Long transcripts also come back more smoothly now, instead of stalling the window until they finish.
- `programa` commands typed inside a restored terminal work again after an app update. They were being refused with "Access denied", which silently cut off any agent running in that pane until you opened a fresh one.
- Opening a second window no longer blanks the terminals in your existing window until you resize it; clicking back into the window now redraws it immediately.
- Restored terminals no longer come back garbled right after an app update: no more transcript fragments painted at the wrong column or letters swapped for digits mid-word, and no need to resize the window to fix it.
- Split-pane workspaces no longer show scattered, overlapping garbled text (the repeated corrupted spinner/"thinking" output some of you saw) when restoring a session, especially with uneven splits.
- Running agent sessions no longer get dropped to a bare shell when the app updates and relaunches; a session that's mid-handoff during that restart is now reliably reattached instead of lost, and restoring several sessions after an update no longer repeats a several-second wait for every one of them if a single handoff is stuck.
- A restart after an update no longer kills every terminal when the new app comes up faster than the background session-holder notices the old one is gone. The app now waits out that window instead of giving up, escrow sockets no longer leak into shell processes (which silently delayed that detection), and a session that falls back anyway keeps its reattach records on disk while its process is still alive instead of deleting them.

### Changed
- Provider usage now shows Claude's session and weekly limits plus OpenAI's unified ChatGPT limit, emphasizing remaining capacity, reset timing, and useful plan or credit context instead of model-specific rows.
- Application lifecycle, command-palette state, CLI and hook dispatch, and browser RPC session state now have dedicated owners, with CI line budgets preventing those entrypoints from growing back into cross-feature coordinators.
- The local diagnostics logger now keeps one file handle open between records and reopens it only after rotation, removing repeated directory checks and open/seek/close work from socket and session activity.
- Ghostty is updated to the current upstream implementation with complete Kitty graphics animation and placement support. Programa now builds the fork and helper tools with Zig 0.16.
- Background work is lighter: unchanged config reloads are ignored, idle output polling stops, duplicate update checks are gone, and update logs rotate at 1 MiB.
- Sidebar resizing now uses native macOS pointer capture, so the resize cursor and drag stay stable when crossing terminal or browser content. Command-palette, review-panel, find-field, and workspace telemetry updates also avoid unnecessary whole-window redraws.
- Hidden terminal panes now release their Metal renderer and IOSurface pool after a short idle period while keeping the shell, scrollback, and terminal state alive. Returning to the pane rebuilds its renderer before it becomes visible, so graphics memory scales with the terminals on screen instead of every workspace opened during the session.
- Terminal output subscriptions now take one bounded snapshot per surface and publish only the changed suffix, reducing main-thread work and memory churn for automation clients watching busy terminals.
- Less background churn under agent load: repeated identical progress and port reports no longer redraw workspaces, moving the mouse across a window no longer re-renders its chrome, and scrolling no longer builds debug strings that get thrown away.
- Closing a browser tab now clears its leftover automation state (scripts, dialog queues, download logs), and a browser download wait that times out no longer risks corrupting a file handle.
- The CLI now reconnects automatically instead of exiting when the app restarts (for example after an auto-update) or after an hour of inactivity; use `--no-reconnect` on `watch-events` if you want the old exit-on-disconnect behavior for scripts.
- Every auto-shipped build now carries its own version number (like 0.4.213) instead of every build showing 0.4.0, so you can tell which build you're on.
- Idle CPU use is lower: moving the mouse and checking git status for workspaces you're not looking at no longer do unnecessary background work.

### Added
- Terminal themes are now selectable in Settings with separate light and dark choices. The UI, `programa themes`, and `app.terminalTheme` in `settings.json` share one managed override and apply changes to open terminals without relaunching.
- A local diagnostics log at `~/Library/Logs/Programa/diagnostics.log` now records connection problems (like CLI socket errors) so issues can be diagnosed after the fact. It's a plain file on your machine; nothing in it is ever sent anywhere.

## [0.4.0] - 2026-08-03

### Fixed
- Restarting the app no longer garbles terminals. Restored sessions used to replay whatever escape state a killed program left behind — stuck mouse reporting flooding the prompt with `35;16;54M` noise, a layout broken until you resized the window (and for some people not even then: a shell stranded on the alternate screen, or with wrapping off, stays broken through any resize). The replay now restores the terminal's modes to sane defaults, sizes the grid before replaying instead of after, and leaves programs that genuinely survived the restart untouched.
- External monitors that wake up late no longer leave terminals with a wrong grid. The app now listens for display-configuration changes and re-applies the right scale, instead of trusting whatever screen was attached at window creation.

### Changed
- Hidden windows stop rendering. Minimizing a window, or fully covering it with another app, now tells the renderer to idle instead of drawing frames nobody can see.
- The background port scan runs at a fraction of its old cost: every 10 seconds instead of every 2, and not at all while no Programa window is visible. Prompt-triggered scans are unchanged, so port badges stay fresh while you work.
- The session-keeper process that preserves terminals across updates now cleans up after itself: it hands sessions back on relaunch, drops anything nobody reclaimed, and exits once it holds nothing — instead of accumulating forever. (If you ever saw stray `session-escrow-holder` processes in Activity Monitor, that's what this fixes.)
- Release builds are stripped and dead-code-eliminated, with debug symbols archived separately for crash symbolication — a substantially smaller download.
- Debug-only windows and controllers no longer ship in release builds at all.
- `settings.json` schema now tells the truth: removed three documented keys that nothing ever read, and fixed two browser keys whose documented names never matched what the app parses (`openTerminalLinksInProgramaBrowser`, `interceptTerminalOpenCommandInProgramaBrowser`).

### Added
- Session snapshot history: every launch now archives the previous window/workspace layout into `~/Library/Application Support/programa/session-history/` (best-effort, before anything can overwrite it), keeping the 10 newest. `programa snapshot list` shows archived snapshots (id, saved-at, clean/unclean shutdown, window/workspace/panel counts), and `programa snapshot restore [<id>|latest]` reopens one as new windows without touching anything already open. This recovers layouts previously lost to a cold boot, a forced shutdown, or a launch that skipped restore because it carried an explicit open intent. Also available over the socket as `snapshot.list`/`snapshot.restore`. Session snapshots now also record whether they were saved during an orderly quit.
- `programa worktree open --all`: opens every worktree of the resolved repo as a workspace in one call, instead of one `<path-or-branch>` at a time. Idempotent and never steals focus, same as a single `worktree open`; mutually exclusive with a positional target and with `--focus`.
- `programa race "<prompt>" [--n <count>] [--agent claude|opencode|codex] [--base <ref>] [--prefix <slug>] [--layout <name>]`: fans one prompt across N agents (default 3, max 8), each in its own isolated git worktree/workspace on branch `<prefix>/<index>` (default prefix `race`), then types the agent's launch command with the prompt into that workspace's terminal. v1 spawns the fleet only -- comparing and merging results is manual for now. Never steals focus; a failed index (branch/worktree collision) is reported and skipped without aborting the rest of the fleet.
- `programa.json` recipes: a `recipes` array alongside `commands` lets you share a library of prompt templates for your coding agent via git, reachable from the command palette. A recipe fills in any declared `{{name}}` parameters (prompted one at a time) and types the result into the focused terminal for you to review -- it never auto-submits, so you add your own instruction and press Return. Commands can now declare `parameters` too, substituted into `command` the same way. Both go through the same trust confirmation as every other `programa.json` entry, showing the fully substituted text before anything happens. See `docs/programa-json.md`.

## [0.3.0] - 2026-07-24

### Added
- Detached sessions: terminal processes now survive Programa quitting or crashing. An agent you leave running keeps going, and on the next launch the app reattaches to the live session with its scrollback intact, instead of restoring a dead transcript. Escrow of the PTY to a small detached holder keeps the child alive; reattach hands it back and resumes it live.
- Visual recaps: the markdown viewer now renders mermaid diagrams, GitHub-style callouts (NOTE/TIP/WARNING/…), and before/after code comparisons, and follows the system light/dark appearance natively. An agent can write a styled recap to `.programa/recaps/<name>.md` and open it beside the terminal with `programa recap open <name>`, so you read the important parts instead of scrolling raw output.
- Progress bars: build and install progress reported over OSC 9;4 (npm, cargo, and friends) now shows as a slim bar on the workspace, so you can see a long task moving without watching it.
- Agent diff review panel: open a panel beside an agent's terminal (`programa review open`, or the command palette) showing its worktree diff — uncommitted changes by default, or the whole branch vs a merge-base. Click a line (or shift-click a range) to attach a comment, then "Send to agent" delivers every pending comment back into that terminal's input as `path:line — comment`. Auto-refreshes when the agent finishes working; binary/huge files show as "not diffable" instead of dumping their content. Also available over the socket as `review.open/refresh/comment.add/comment.remove/comment.list/send_comments` for agents/automation.
- Native git worktree workflow: `programa worktree create <branch>` checks out a branch into its own worktree and opens it as a new workspace, placed next to its parent repo's workspace in the sidebar (with a small fork-glyph badge). `programa worktree open`/`remove`/`list` round out the lifecycle; `remove` never deletes the branch, and a dirty worktree requires an explicit `--force`. Also available over the socket as `worktree.create/open/remove/list` for agents/automation. New `worktrees.directory` setting (default `~/.programa/worktrees`) controls where new worktrees are created.
- Named layout configs: `programa layout save <name>` snapshots the current workspace's pane/split layout (geometry, working directories, browser URLs), and `programa layout apply <name>` replays it into a new or existing workspace — also reachable from the command palette as "Apply layout: <name>". `worktree create --layout <name>` applies a saved layout straight into a new worktree's workspace, with relative directories resolved against the worktree root.
- Codex integration now matches Claude Code: "Needs input" notifications, guaranteed cleanup when a session dies without a clean stop, an "Install Codex Integration…" menu item, and `programa codex install-integration` naming (the old install-hooks name still works). Also fixed duplicate desktop notifications for Codex sessions — suppression of raw terminal notifications now applies to any hook-managed agent, not just Claude Code.
- OpenCode integration: session status, "Needs input" and completion notifications now work for OpenCode too, via a small local plugin. "Install OpenCode Integration…" in the File menu (or programa opencode install-integration) shows exactly what will be written and asks first; uninstall is symmetric and never touches a file you've customized.
- File menu: "Install Claude Code Integration…" opens a terminal running `programa claude install-integration`, which shows the exact diff it wants to make to your Claude settings and asks before writing. It durably registers Programa's lifecycle hooks so the integration works from any terminal, not just inside Programa; hooks silently no-op elsewhere. Fully reversible with `programa claude uninstall-integration`; your own hooks are never touched.
- Closing a terminal is now undoable for 5 seconds: Cmd+Shift+T brings it back with its process still running — whether you closed it or an agent did. The confirmation dialog still appears when a command is actively running.
- Sidebar agent status badges (working/blocked/idle) now also work for CLIs with no installed integration — Gemini CLI, GitHub Copilot CLI, Cursor Agent, Aider — by pattern-matching what's visibly on screen against a small per-agent manifest, entirely on-device. A hooks-managed session (Claude Code, Codex, OpenCode) always takes priority: this only kicks in when nothing has reported a real status yet. New "Screen-Based Agent Detection" toggle in Settings → Automation, on by default. Manifests are user-overridable at `~/.config/programa/agent-detection/<agent>.json` for anyone who wants to tune the patterns for their own setup.

### Fixed
- The terminal no longer reserves an empty scrollbar gutter on the right when macOS "Show scroll bars" is set to Always; content uses the full width (Ghostty owns scrollback, so the AppKit scroller was doing nothing).
- The workspace color submenu no longer flickers open and closed while you hover it.
- Detached-session recovery no longer risks silently dropping output after a crash-time WAL rotation, and the session-persistence machinery no longer adds work to the render or keystroke paths.
- Socket telemetry commands no longer pay a full-application main-thread scan on every call, and concurrent socket clients can no longer observe each other's focus intent.

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
