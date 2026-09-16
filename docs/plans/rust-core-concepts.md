# Programa concept inventory

What a replacement core (any toolkit, any terminal engine) has to reproduce. Companion to `rust-core-spike.md`. Generated 2026-09-15 from a read-only pass over the repo.

Read-only research pass over `/Users/frz/Developer/@darkroom/programa`. Each section names the
owning source files and the external contract (CLI/socket/MCP/settings/shortcut names) so a
Rust/cross-platform core spec can enumerate what has to be reimplemented.

## 1. Object model

Nesting: `window` (native macOS window) -> `workspace` (sidebar entry, often called "tab" in the
UI) -> `pane` (a split region from vendor/bonsplit) -> `surface` (a tab within a pane: terminal or
browser). `panel` is the internal implementation term for what the public API calls `surface`
(`docs/agent-browser-port-spec.md:30-40`).

- **Window**: `Sources/AppDelegate.swift`, `Sources/WindowAccessor.swift`, `Sources/MainWindowHostingView.swift`, `Sources/WindowChrome.swift`, `Sources/WindowSwizzles.swift`, `Sources/TerminalController+Window.swift`.
- **Workspace**: `Sources/Workspace.swift` (`final class Workspace: Identifiable, ObservableObject`, `let id: UUID`, `Sources/Workspace.swift:14-15`), plus `Workspace+Bonsplit.swift`, `Workspace+FocusGeometry.swift`, `Workspace+Layout.swift`, `Workspace+Persistence.swift`, `Workspace+SidebarTelemetry.swift`, `Workspace+Surfaces.swift`, `Workspace+Theme.swift`. Owned by `Sources/TabManager.swift` (`class TabManager: ObservableObject`, `@Published var tabs: [Workspace]`, `Sources/TabManager.swift:593,624`) — the manager's own vocabulary is "tabs" even though the public/UI concept is "workspace." Sidebar rendering: `Sources/VerticalTabsSidebar.swift`, `Sources/TabItemView.swift`, `Sources/WorkspaceSidebarModels.swift`.
- **Pane / split tree**: `vendor/bonsplit` (in-tree, MIT, not a git submodule — edit/commit like normal source per `CLAUDE.md`). Public types: `vendor/bonsplit/Sources/Bonsplit/Public/Types/PaneID.swift` (`struct PaneID: Hashable, Codable, Sendable` wrapping a `UUID`), `TabID.swift` (wraps a `UUID`, internal `id` — `Tab` here is bonsplit's own generic split-tree leaf, not `Workspace`), `SplitOrientation.swift`, `NavigationDirection.swift`, `LayoutSnapshot.swift`, `TabContextAction.swift`. Controller: `vendor/bonsplit/Sources/Bonsplit/Public/BonsplitController.swift`, `BonsplitConfiguration.swift`, `BonsplitDelegate.swift`, `BonsplitView.swift`. App-side glue: `Sources/TerminalController+Pane.swift`, `Sources/TabManager+Splits.swift`.
- **Surface**: `Sources/TerminalSurface.swift` wraps a Ghostty `ghostty_surface_new` C surface tied synchronously (main actor) to a specific `NSView*` (`docs/plans/detached-sessions.md:94-99`). Panel protocol (`Panel`, `@MainActor`, `ObservableObject`, `Identifiable`) with `PanelType` enum (`.terminal`, `.browser`, `.markdown`, and a planned `.review`) at `Sources/Panels/Panel.swift:7`. `Sources/Panels/TerminalPanel.swift`, `BrowserPanel.swift`, `MarkdownPanel.swift`, `ReviewPanel.swift` (see §5).
- **Sidebar**: `Sources/VerticalTabsSidebar.swift`, `Sources/ContentView+SidebarResizer.swift`, `Sources/WorkspaceSidebarModels.swift`.

**IDs and refs.** Internally everything is a `UUID`. The external (socket/CLI/MCP) contract never
exposes raw UUIDs as the primary handle; it issues short ordinal "handle refs" of the form
`window:1`, `workspace:1`, `pane:1`, `surface:1` (`enum V2HandleKind: window, workspace, pane,
surface`, `Sources/TerminalController.swift:177-182`, ref store `V2HandleRefStore` at
`Sources/TerminalController.swift:184+`). There is also a `tab:` ref alias that is literally the
`surface:` ref with the prefix swapped (`v2TabRef`, `Sources/TerminalController.swift:2396-2400`)
— kept for the historical v1 "panel"/"tab" vocabulary in tmux-compat commands. Refs are assigned
lazily/on first issuance and are stable for the life of the running app (not persisted across
restart — a fresh launch restarts ordinals at 1).

**Focus and selection.** `TabManager.selectedTabId: UUID?` tracks the selected workspace
(`Sources/TabManager.swift:642`). Per-workspace pane/surface focus is tracked inside `Workspace`
(`Workspace+FocusGeometry.swift`) and surfaced over the socket via `surface.focus`/`pane.focus`.
Socket/CLI focus is gated: only methods in `focusIntentV2Methods` may move macOS app focus or
raise the window (`docs/mcp-server.md:107-115`; enforced in `Sources/TerminalController.swift`,
consulted via `v2FocusAllowed()`), regardless of what a client asks for — see §3's focus policy
and §5's `focus_` MCP tool naming.

## 2. Sessions

Two independent mechanisms, deliberately not merged (`docs/plans/snapshot-restore.md:87-94`):

**Layout/state snapshot** (`docs/plans/snapshot-restore.md`, `Sources/SessionPersistence.swift`,
`Sources/TabManager+SessionPersistence.swift`, `Sources/Workspace+Layout.swift`) — captures
window/workspace/pane geometry, cwd, titles, and scrollback-as-text, and replays it on next
launch into **brand-new** shell processes (not a live reconnect). Live file:
`~/Library/Application Support/programa/session-<bundleId>.json`. History archive (added by the
snapshot-restore feature): copied (never moved) into `session-history/<timestamp>-<bundleId>.json`
once per launch, pruned to 10 newest, deduped by byte-identical content. Records a
`cleanShutdown: Bool?` flag (`true` only from orderly-quit paths). Socket: `snapshot.list`,
`snapshot.restore`. CLI: `programa snapshot list [--json]`, `programa snapshot restore
[<id>|latest]`.

**Process survival / detached sessions** (`docs/plans/detached-sessions.md`, shipped 0.3.0,
2026-07-24; `Sources/SessionEscrow.swift`, `session_escrow_shim.c`/`.h`) — "escrow the dup, don't
move the custody." At PTY creation the app `dup()`s the Ghostty PTY master fd and sends it once
via `SCM_RIGHTS` to a small detached "holder" process (the same app binary launched in a hidden
mode, `SessionEscrowHolder.runIfRequested()`, spawned with `posix_spawn` + `POSIX_SPAWN_SETSID` +
`POSIX_SPAWN_CLOEXEC_DEFAULT` so it survives app death and doesn't accidentally inherit every
other surface's fd). If the app quits or crashes, the escrowed dup keeps the PTY pair alive (child
never gets SIGHUP); the holder detects app death (kqueue `EVFILT_PROC` + heartbeat) and drains
PTY output into an append-only WAL (`SessionWALStore`/`SessionWALPaths`) so the child never blocks
on a full PTY buffer. On relaunch the app retrieves the fd back over `SCM_RIGHTS` (token-gated),
replays the WAL tail through Ghostty's own VT parser, and re-applies size/`SIGWINCH`
(tmux-style idempotent attach). Ghostty-fork dependency: read-only child PID / PTY path / PTY
master-fd accessors, and surface revival through an existing fd+pid without Ghostty taking
ownership or signaling that process (`docs/ghostty-fork.md` §10, `96316fc50`/`bccfc8333`; see §8
of this inventory). Note a caution flagged in memory: `[[scm-rights-sender-close-race]]` — never
close the sender's fd right after `sendmsg`.

**What survives an app restart today:** with escrow, the live child process and PTY (detached
sessions). Without/before escrow completes for a given surface, only layout/cwd/scrollback text
survives (snapshot). Neither mechanism persists env vars, command line, or focus state
(`v2-api-migration.md`/`layout.save` explicitly excludes "command/env/focus, which have no live
'what's running' signal").

## 3. Socket API v2 (`docs/v2-api-migration.md`, `tests_v2/`)

JSON-RPC-shaped, one JSON object per line, `{"id","method","params"}` -> `{"id","ok","result"}` /
`{"id","ok":false,"error":{"code","message"}}`. `auth.login` is a connection preamble, not a
regular method (password-mode socket access, see `automation.socketPassword` in §7). v1
line-protocol was removed 2026-07-08; a non-JSON line now gets `v1_removed`.

Full v2 method list by area (authoritative source: `Sources/V2CommandCatalog.swift`):

- **System**: `system.ping`, `system.identify`, `system.capabilities`, `rpc` (raw passthrough — CLI `programa rpc`).
- **Window**: `window.list`, `window.current`, `window.focus` (focus-intent), `window.create`, `window.close`.
- **Workspace**: `workspace.list`, `workspace.create`, `workspace.select` (focus-intent), `workspace.current`, `workspace.close`, `workspace.move_to_window`, `workspace.next`/`workspace.previous`/`workspace.last` (focus-intent), `workspace.rename`.
- **Worktree** (`docs/plans/worktree-and-layouts.md`): `worktree.create`, `worktree.open` (focus-intent, opt-in `focus`), `worktree.remove`, `worktree.list`. Params/errors detailed in `docs/mcp-server.md`/`v2-api-migration.md:458-511`.
- **Layout**: `layout.save`, `layout.apply`, `layout.list`.
- **Snapshot**: `snapshot.list`, `snapshot.restore` (see §2).
- **Agent detection**: `agent.detection.list`, `agent.detection.classify` (see §5).
- **Surface / split**: `surface.list`, `surface.focus` (focus-intent), `surface.split`, `surface.create`, `surface.close`, `surface.drag_to_split`, `surface.refresh`, `surface.health`, `surface.trigger_flash`, `surface.wait` (event-driven one-shot wait — see below), `surface.read_text`, `surface.send_text`, `surface.send_key`.
- **Surface telemetry** (`surface.report_tty`, `surface.ports_kick`, `surface.report_pwd`, `surface.report_shell_state`, `surface.report_git_branch`, `surface.clear_git_branch`, `surface.report_pr`, `surface.clear_pr`, `surface.report_ports`, `surface.clear_ports`) — hot-path threading policy from `CLAUDE.md`: parse/validate/dedupe off-main, only the minimal model mutation hops to `DispatchQueue.main.async`.
- **Pane**: `pane.list`, `pane.focus` (focus-intent), `pane.surfaces`, `pane.create`, `pane.last` (focus-intent, MCP-exposed).
- **Sidebar metadata** (workspace-scoped): `workspace.set_status`/`clear_status`/`list_status`, `workspace.log`/`clear_log`/`list_log`, `workspace.set_progress`/`clear_progress`, `workspace.sidebar_state`, `workspace.clear_agent_pid`/`set_agent_pid`, `workspace.report_meta_block`/`clear_meta_block`/`list_meta_blocks`, `workspace.reset_sidebar`.
- **Notification**: `notification.create`, `notification.create_for_surface`, `notification.create_for_target`, `notification.list`, `notification.clear`.
- **App**: `app.focus_override.set`, `app.simulate_active`, `app.reload_config`, `app.browsers` (lists installed/running browsers + system default; see `Sources/Panels/BrowserAvailability.swift`).
- **Browser**: `browser.open_split` (focus-intent varies), `browser.navigate`, `browser.back`, `browser.forward`, `browser.reload`, `browser.url.get`, `browser.focus_webview` (focus-intent), `browser.is_webview_focused`, `browser.focus` (focus-intent, element-level), `browser.tab.switch` (focus-intent). Full agent-browser-shaped surface (`browser.snapshot`, `.click`, `.fill`, `.screenshot`, `.console.list`, `.tab.new/close`, etc.) documented in `docs/aside-browser.md` and `docs/agent-browser-port-spec.md`; Playwright-shaped network/viewport/raw-input methods return `not_supported` (no CDP under `WKWebView`).
- **Review** (`review.*`, docs/plans/diff-review-panel.md — see §5): `review.open` (focus-intent, opt-in), `review.refresh`, `review.comment.add`, `review.comment.remove`, `review.comment.list`, `review.send_comments`.
- **Markdown**: `markdown.open` (app-chrome, not MCP-exposed).
- **Subscriptions**: `subscribe` (`classes`: `agent_state`|`output`|`workspace_lifecycle`; `surface_ids` required for `output`), `unsubscribe`. Push frames use a bare `{"event": ...}` shape, not the request/response envelope; 256-event drop-oldest queue per subscription with a `{"event":"dropped","count"}` marker frame.
- **Debug/test-only** (`debug.*`, DEBUG builds, not MCP-exposed): `debug.shortcut.set`/`simulate`, `debug.type`, `debug.app.activate`, `debug.terminal.is_focused`/`read_text`/`render_stats`, `debug.layout`, `debug.bonsplit_underflow.count/reset`, `debug.empty_panel.count/reset`, `debug.notification.focus`, `debug.flash.count/reset`, `debug.panel_snapshot.snapshot/reset`, `debug.window.screenshot`.

**`surface.wait`** (#166): server-owned, event-driven, one request/response wait on `pattern`
(regex vs current screen+scrollback, polled ~100ms), `exit` (child process exit, fully
event-driven off `GHOSTTY_ACTION_SHOW_CHILD_EXITED`), or `agent_state` (idle/working/blocked/
any_change, event-driven off the single main-thread mutation point for
`Workspace.panelAgentStates`). No-missed-events guarantee via a synchronous main-thread hop
(`v2MainSync`) that checks-then-registers atomically. CLI: `programa wait-surface`.

**`agent.prompt`** (#166): submit a prompt (`surface.send_text`'s path) + wait for the agent to go
idle, phased: send+register atomically, wait `working_grace_ms` for a `working` transition
(non-fatal if not observed), then wait the remaining `timeout_ms` for `idle`. CLI: `programa
prompt-agent`.

**Threading/focus policy** (from root `CLAUDE.md`, cross-referenced throughout
`v2-api-migration.md`): telemetry hot-path commands must not use `DispatchQueue.main.sync`; only
`focusIntentV2Methods` may mutate in-app focus/window activation; everything else must preserve
the user's current focus while still applying data/model mutations.

## 4. CLI and MCP server

**CLI** (`CLI/programa.swift`, dispatcher `CLI/CLICommandDispatcher.swift`, custom argument
parser — not Swift ArgumentParser). Socket path resolution: `PROGRAMA_SOCKET_PATH` env var, else a
DEBUG-only hint file at `/tmp/programa-last-socket-path`, else `/tmp/programa-debug.sock`
(DEBUG) / `/tmp/programa.sock` (release). Full top-level command name list, in the order declared
in `commandDescriptors()` (`CLI/programa.swift`, one `CommandDescriptor` per name group):
`welcome`, `shortcuts`, `feedback`, `themes`, `claude-teams`, `omo`, `omx`, `omc`, `codex`,
`claude`, `opencode`, `aside`, `ping`, `version`, `capabilities`, `rpc`, `identify`,
`list-windows`, `current-window`, `new-window`, `focus-window`, `close-window`,
`move-workspace-to-window`, `reorder-workspace`, `workspace-action`, `worktree`,
`agent-detection`, `race`, `layout`, `snapshot`, `list-workspaces`, `new-workspace`, `new-split`,
`list-panes`, `list-pane-surfaces`, `focus-pane`, `new-pane`, `new-surface`, `close-surface`,
`move-surface`, `reorder-surface`, `tab-action`, `rename-tab`, `drag-surface-to-split`,
`refresh-surfaces`, `reload-config`, `surface-health`, `debug-terminals`, `trigger-flash`,
`list-panels`, `focus-panel`, `close-workspace`, `select-workspace`, `rename-workspace` (alias
`rename-window`), `current-workspace`, `read-screen`, `wait-surface`, `prompt-agent`,
`watch-events`, `send`, `send-key`, `send-panel`, `send-key-panel`, `notify`,
`list-notifications`, `clear-notifications`, `set-status`, `clear-status`, `list-status`,
`set-progress`, `clear-progress`, `log`, `clear-log`, `list-log`, `sidebar-state`,
`set-app-focus`, `simulate-app-active`, `__tmux-compat` (family of tmux-compatibility commands,
`CLI/CLI+TmuxCompat.swift`), `markdown`, `review`, `recap`, `browser` (with legacy flat aliases
`open-browser`, `navigate`, `browser-back`, `browser-forward`, `browser-reload`, `get-url`,
`focus-webview`, `is-webview-focused`), `help`. Command families with their own subcommand sets:
`CLI/CLI+Aside.swift`, `CLI/CLI+Browser.swift` (49-verb agent-browser-shaped surface — see
`docs/agent-browser-port-spec.md`), `CLI/CLI+Review.swift`, `CLI/CLI+Markdown.swift`,
`CLI/CLI+Recap.swift`, `CLI/CLI+Themes.swift`, `CLI/CLI+AgentWrappers.swift` (`claude`, `codex`,
`opencode` install/uninstall-integration), `CLI/CLI+Hooks.swift`/`CLI/CLI+HookCommands.swift`.
Notifications CLI subset is also documented standalone in `docs/notifications.md`: `programa
notify --title <text> [--subtitle][--body][--tab][--panel]`, `list-notifications`,
`clear-notifications`, `set-status <key> <value>`, `clear-status <key>`, `ping`.

**MCP server** (`docs/mcp-server.md`, binary `programa-mcp`, `CLI-MCP/programa-mcp.swift`,
`CLI-MCP/MCPServer+Capabilities.swift`, `CLI-MCP/MCPSocketBridge.swift`,
`CLI-MCP/ToolCatalog.swift`, `CLI-MCP/ResourceCatalog.swift`, `CLI-MCP/MCPErrorMapping.swift`).
Separate binary embedded at `Contents/Resources/bin/programa-mcp` inside the app bundle; talks to
the running app over the same v2 socket. 187 tools, one per exposed socket method with `.` ->
`_` (`surface.read_text` -> `surface_read_text`, `review.comment.add` -> `review_comment_add`).
Thirteen tools carry an explicit `focus_` prefix because they are allowed to move macOS focus:
`focus_window`, `focus_workspace_select`, `focus_workspace_next`, `focus_workspace_previous`,
`focus_workspace_last`, `focus_surface`, `focus_pane`, `focus_pane_last`, `focus_review_open`,
`focus_worktree_open`, `focus_browser_webview`, `focus_browser_element`,
`focus_browser_tab_switch` (`worktree_create` is a deliberate exception: it drops the underlying
method's `focus` param entirely). Not exposed: `debug.*` (DEBUG-only, UI-test hooks) and app-chrome
methods (`auth.login`, `settings.open`, `feedback.*`, `markdown.open`, `app.*`). Resources:
`programa://tree` (full window/workspace/pane/surface tree) and
`programa://surface/{surface_id}/text` (optionally `?lines=n`, capped at 10,000 lines). Auth: set
`PROGRAMA_SOCKET_PATH` to target a specific instance, `PROGRAMA_SOCKET_PASSWORD` if
password-mode socket access is enabled (`automation.socketPassword`).

## 5. Agent integration

**Agent detection** (`docs/agent-detection-manifests.md`, `docs/plans/screen-manifest-detection.md`,
`Sources/AgentManifest.swift`, `Sources/AgentManifestLoader.swift`,
`Sources/AgentScreenDetectionEngine.swift`, `Sources/AgentActivityState.swift`,
`Sources/AgentSupervision.swift`, `Sources/AgentRPCDispatcher.swift`). Two tiers: (1) lifecycle
hooks installed for agents that support them (Claude Code, Codex, OpenCode — always wins over
inference), (2) a screen-manifest fallback that regex-matches the visible terminal screen against
a declarative JSON manifest per agent to infer `working`/`blocked`/`idle`/`done` (mapped to the
3-value wire enum, `done` folds into `idle`). Bundled manifests:
`Resources/AgentDetection/<agent>.json` for the seven ids `claude-code`, `codex`, `gemini-cli`,
`opencode`, `copilot-cli`, `cursor-agent`, `aider`. User overrides (full replace, no merge):
`~/.config/programa/agent-detection/<agent-id>.json`. Schema v1: `agent`, `display_name`,
`recognize.process_names`/`screen_patterns`, `states[].bucket/priority/anchor_last_n_lines/
patterns/confidence/source_notes`. CLI: `programa agent-detection list|scaffold|test`. Socket:
`agent.detection.list`, `agent.detection.classify`.

**Notifications** (`docs/notifications.md`, `Sources/NotificationsPage.swift`,
`Sources/TerminalNotificationStore.swift`, `Sources/AgentOverviewWindow.swift`). Notification
panel + macOS system notifications. Env vars set in every child shell:
`PROGRAMA_SOCKET_PATH`, `PROGRAMA_TAB_ID`, `PROGRAMA_PANEL_ID`, `PROGRAMA_DEFAULT_BROWSER`,
`PROGRAMA_DEFAULT_BROWSER_BUNDLE_ID`. Settings: `notifications.showInMenuBar`, `.sound`,
`.command`, `.longCommandThresholdSeconds` (see §7). Integration recipes documented for Claude
Code hooks, GitHub Copilot CLI hooks (`~/.copilot/config.json` or `.github/hooks/notify.json`),
OpenAI Codex (`~/.codex/config.toml` `notify` array), and an OpenCode plugin
(`.opencode/plugins/programa-notify.js`).

**Attention/status/progress metadata**: workspace-scoped sidebar metadata methods (`workspace.
set_status/log/set_progress/sidebar_state` family, §3) mutate a `Tab`/`Workspace` (not a specific
surface). `Workspace.panelAgentStates: [UUID: AgentActivityState]`
(`Workspace.swift:111`) is the single source of truth for per-surface agent activity, mutated only
via `Workspace+SidebarTelemetry.swift`'s `updatePanelAgentState`/`clearPanelAgentState`
(`:163`/`:180`), which fan out to `AgentStateWaitRegistry` (backs `surface.wait`/`agent.prompt`)
and `SocketEventBroadcaster` (backs `subscribe`).

**Provider usage display**: `Sources/ClaudeQuotaMonitor.swift` reads
`~/.claude/tmp/rate-limits.json` to show Claude Code 5h/7d rate-limit headroom in the sidebar
footer; gated by `sidebarAppearance.showClaudeQuota` (§7).

**Diff review panel** (`docs/plans/diff-review-panel.md`, status "proposed" per the plan doc
but the `review.*` socket family and `Sources/Panels/ReviewPanel.swift` /
`ReviewPanelView.swift` / `Sources/ReviewComment.swift` / `ReviewCommentSerializer.swift` /
`ReviewDiffParser.swift` / `ReviewDiffProber.swift` exist in-tree — cross-check `PanelType` for
current `.review` case status before assuming it's fully live). Shows a terminal surface's
worktree git diff (`"uncommitted"` vs `HEAD`, or `"branch"` vs merge-base) beside the pane, with
line comments serialized as `path:start-end — text` and sent back into the source terminal's
input. Read-only w.r.t. git — never mutates worktree/index/branches. CLI: `programa review
open|refresh|comment|send`. Socket family listed in §3.

## 6. Browser panel

**Two distinct browser surfaces** (`docs/aside-browser.md`): Programa's embedded panel
(`WKWebView`-based, per-workspace profile, socket-driven `browser.*`) for local
previews/smoke-tests/DOM inspection that an agent reads back without leaving the pane; and Aside
(`aside.com`, Chromium-based, external app) for logged-in/private-session work, registered as an
MCP server for Claude Code/Codex via `programa aside install-mcp`.

Embedded browser source: `Sources/Panels/BrowserPanel.swift` + companions
(`+Automation.swift`, `+DeveloperTools.swift`, `+Focus.swift`, `+Navigation.swift`, `+Theme.swift`,
`+WorkspaceLifecycle.swift`), `BrowserPanelSupport.swift`, `BrowserPanelView.swift`,
`BrowserPanelWebDelegates.swift`, `BrowserAvailability.swift` (backs `app.browsers`),
`BrowserHistoryStore.swift`, `BrowserProfileStore.swift`, `BrowserSettings.swift`,
`BrowserToolbarViews.swift`, `BrowserUserProxySettings.swift`, `BrowserWebDialogPresenter.swift`,
`Omnibar.swift`/`OmnibarSuggestionsView.swift`/`OmnibarTextField.swift`, `InspectorDock.swift`,
`DesignMode.swift`. Depends on WebKit (`WKWebView`) — there is no Chrome DevTools Protocol
underneath, so Playwright-shaped tools (`browser_viewport_set`, `browser_network_route`,
`browser_input_mouse`, etc.) return `not_supported` deliberately rather than failing as unknown
tools (`docs/mcp-server.md:135-141`). `docs/agent-browser-port-spec.md` is a historical porting-gap
tracker against `vercel-labs/agent-browser`'s CLI/protocol surface (its "keep v1 working" framing
is stale — see the doc's own 2026-07-08 historical note — but its "Concepts (Canonical Terms)"
section §30-40 is the accurate current terminology, and its counted command/flag/protocol-action
inventory is useful as an upper bound on what a full port would need).

## 7. Configuration

**`settings.json`** (`docs/settings-json.md`, `~/.config/programa/settings.json`, schema
`Resources/settings.schema.json`, JSONC with `//` comments, reloads on file change, a
file-set key wins over the Settings UI until removed). Top-level sections and every key:
- `app`: `appearance`, `terminalTheme`, `terminalOpacity`, `terminalBlur`, `terminalFont`,
  `newWorkspacePlacement`, `minimalMode`, `preferredEditor`, `reorderOnNotification`,
  `warnBeforeQuit`, `commandPaletteSearchesAllSurfaces`.
- `notifications`: `showInMenuBar`, `sound`, `command`, `longCommandThresholdSeconds`.
- `workspaceColors`: `indicatorStyle`, `selectionColor`, `notificationBadgeColor`, `colors`.
- `sidebarAppearance`: `matchTerminalBackground`, `tintColor`, `lightModeTintColor`,
  `darkModeTintColor`, `tintOpacity`, `showClaudeQuota`.
- `automation`: `socketControlMode` (`off|cmuxOnly|automation|password|allowAll|openAccess|
  fullOpenAccess|notifications|full`), `socketPassword`, `claudeCodeIntegration`,
  `openBrowserWithAgentSplits`, `claudeBinaryPath`, `portBase`, `portRange`.
- `customCommands`: `trustedDirectories`.
- `browser`: `defaultSearchEngine`, `showSearchSuggestions`, `theme`,
  `openTerminalLinksInProgramaBrowser`, `interceptTerminalOpenCommandInProgramaBrowser`,
  `hostsToOpenInEmbeddedBrowser`, `urlsToAlwaysOpenExternally`, `externalBrowser`,
  `insecureHttpHostsAllowedInEmbeddedBrowser`, `proxy`.
- `worktrees`: `directory` (default `~/.programa/worktrees`).
- `shortcuts`: `showModifierHoldHints`, `bindings` (keyed by Programa action id; string or array
  for a chord). Special-cased action id in the doc: `openAgentOverview` (unbound by default).
Swift source of truth: `Sources/ProgramaSettingsFileStore.swift`,
`Sources/KeyboardShortcutSettings.swift`.

**`programa.json`** (`docs/programa-json.md`, `Sources/ProgramaConfig.swift`,
`Sources/ProgramaConfigExecutor.swift`). Command-palette entries, walked up from the focused
workspace's cwd plus a global `~/.config/programa/programa.json` fallback (legacy names
`cmux.json`/`~/.config/cmux/cmux.json` still read). Two entry kinds: `commands` (either a
`workspace` command — opens/recreates a named workspace with a saved layout — or a `command`
command — types+submits shell text) and `recipes` (fills a prompt template and types it into the
focused terminal **without** auto-submitting, so a cloned repo can't fire attacker-chosen text
straight at an agent). Untrusted by default: every command/recipe is confirmed until the user
trusts the source directory (`customCommands.trustedDirectories`). Parameter substitution:
`{{name}}` placeholders, unresolved ones left literal, values not shell-quoted (the confirmation
dialog is the control, not escaping).

**Keyboard shortcuts** (`docs/keyboard-shortcuts.md`, `Sources/KeyboardShortcutSettings.swift`,
`Sources/WorkspaceShortcutMapper.swift`). Every shortcut editable in Settings and via
`shortcuts.bindings`. Full default table spans workspaces, surfaces, split panes, browser,
notifications, find, terminal, window, and review; several actions ship intentionally unbound
(`openAgentOverview`, review-panel-open, git-worktree/layout commands — CLI/palette only "by
design, not an oversight").

**Terminal themes** (`docs/terminal-themes.md`). Reads Ghostty's bundled theme catalog plus user
theme directories (`GHOSTTY_RESOURCES_DIR`, `XDG_DATA_DIRS`); ships two Programa-specific themes,
**Min Light** and **Min Dark** (Min Theme VS Code extension style). CLI: `programa themes
list|set|clear`. Managed block written into `~/Library/Application Support/
com.darkroom.programa/config.ghostty`, field-by-field (never captures a field it doesn't
explicitly manage). Mirrors the four `app.terminalTheme/terminalOpacity/terminalBlur/
terminalFont` settings.json keys.

**Localization**: `Resources/Localizable.xcstrings`, source language `en`, translated languages
present: `en`, `ja` (English and Japanese — matches `CLAUDE.md`'s "currently English and
Japanese"). Every user-facing string must use `String(localized:defaultValue:)` per project
convention — no bare literals.

## 8. Ghostty fork delta (`docs/ghostty-fork.md`)

Fork head as of this inventory: `bccfc8333` on Darkroom Engineering's `ghostty` fork `main`,
reconciled with upstream `ghostty-org/ghostty` `main` at `c8634f3fce1` (2026-08-21), Zig 0.16.0.
Every item below is something a non-Ghostty (e.g. a Rust-native terminal-emulation) core would
have to reimplement or find an equivalent for:

1. **macOS display-link restart on display change** (`src/renderer/generic.zig`) — prevents a
   stuck-vsync state after a `CGDisplay` ID change.
2. **Resize stale-frame mitigation** (`pkg/macos/animation.zig`, `src/Surface.zig`,
   `src/apprt/embedded.zig`, `src/renderer/Metal.zig`, `src/renderer/generic.zig`,
   `src/renderer/metal/IOSurfaceLayer.zig`) — replays the last frame with correct anchoring during
   a live resize to avoid transient blank/scaled frames.
3. **OSC 99 (kitty) notification parser** (`src/terminal/osc.zig`,
   `src/terminal/osc/parsers/kitty_notification.zig`).
4. **Programa theme-picker helper hooks** (`build.zig`, `src/cli/list_themes.zig`,
   `src/main_ghostty.zig`) — a `zig build cli-helper` step and env-var-driven live-preview mode
   for `+list-themes` that writes Programa's managed theme override and posts a reload
   notification.
5. **DECRPM mode 2031 color-scheme reporting fixes** (`src/Surface.zig`,
   `src/termio/stream_handler.zig`).
6. **Re-exported selection C API** (`include/ghostty.h`, `src/Surface.zig`,
   `src/apprt/embedded.zig`) — `ghostty_surface_select_cursor_cell`,
   `ghostty_surface_clear_selection`, restored after upstream removed them; backs keyboard copy
   mode.
7. **`macos-background-from-layer` config flag** (`src/config/Config.zig`,
   `src/renderer/generic.zig`) — lets the host app supply terminal background via
   `CALayer.backgroundColor` instead of a Metal fill, avoiding alpha double-stacking during
   resizes.
8. **Occluded-surface frame-generation throttle** (`src/renderer/Thread.zig`, current shape
   `08bac45e9`) — `updateFrame` runs unthrottled while visible, at most once per 250ms while
   occluded, instead of a hard skip (a prior hard-skip attempt, `c25020f99`, deadlocked
   `ghostty_surface_read_text` on CI's permanently-occluded virtual display because
   `scrollbar_dirty` is only cleared inside `drawFrame`, which is also gated off while invisible).
9. **Offscreen renderer-realization API** (`include/ghostty.h`, `src/apprt/embedded.zig`,
   `src/renderer/Thread.zig`, `src/renderer/message.zig`) — `ghostty_surface_set_renderer_realized`
   lets the embedder release an occluded surface's Metal swap chain/IOSurfaces while keeping
   PTY/terminal state/scrollback alive, non-blocking mailbox push with an enqueue-result return.
10. **Session introspection and revival APIs** (`include/ghostty.h`, `src/Surface.zig`,
    `src/apprt/embedded.zig`, `src/termio/Exec.zig`) — read-only child PID / PTY path / PTY
    master-fd accessors, and surface revival through an existing fd+pid without Ghostty taking
    ownership/signaling — this is what §2's escrow-based detached sessions depend on. Also: the
    `ghostty_surface_set_pty_tee_cb` callback (runs pre-VT-parse) backs the session WAL and
    superseded an older Programa-only output-tap export (intentionally not restored).

Also upstreamed (no longer fork-only): cursor-click-to-move honoring OSC 133. Dropped as
superseded: several zsh prompt-redraw patches (upstream's newer prompt-marking made them
redundant after the 2026-03-30 rebase); an older initial-focus-seeding/DECSET 1004 patch
(replaced by post-create focus synchronization, which the current fork preserves as items 6/10's
neighbor behavior — surfaces start Ghostty-default-focused, host focus callback reports real
transitions, enabling DECSET 1004 immediately reports current state).

## 9. Rendering/perf design decisions worth keeping

- **Renderer realization + idle reclaim**: item 9 above — release Metal swap chain/IOSurfaces for
  occluded surfaces while keeping PTY/terminal state alive; `Sources/RendererRealization.swift`
  is the app-side driver.
- **Occluded-render throttle**: item 8 above, 250ms/4Hz cap instead of a hard skip, because a hard
  skip starves state machines (like the scrollbar dirty/clear split) that live partly inside the
  throttled call.
- **Portal layering contract** (`CLAUDE.md` pitfalls): `SurfaceSearchOverlay` must mount from
  `GhosttySurfaceScrollView` (`Sources/GhosttyTerminalView.swift`, the AppKit portal layer), not
  from SwiftUI panel containers (`Sources/Panels/TerminalPanelView.swift`) — portal-hosted
  terminal views can sit above SwiftUI during split/workspace churn. Portal registry:
  `Sources/HostedViewPortalRegistry.swift`, `Sources/TerminalWindowPortal.swift`,
  `Sources/TerminalWindowPortalRegistry.swift`, `Sources/WindowPaneChromePortal.swift`,
  `vendor/bonsplit/Sources/Bonsplit/Public/BonsplitPaneChromePortalBridge.swift`.
- **Typing-latency-sensitive paths** (`CLAUDE.md`, must-not-regress list): no app-level display
  link or manual `ghostty_surface_draw` loop (rely on Ghostty's own wakeup/renderer);
  `WindowTerminalHostView.hitTest()` (`Sources/WindowTerminalHostView.swift`) takes a keyboard-event
  fast path that must stay free of added work; `NSWindow.programa_sendEvent`
  (`Sources/WindowSwizzles.swift`) computes its cached hit-view context only for pointer-down
  events; `TabItemView` (`Sources/ContentView.swift`) relies on `Equatable` + `.equatable()` to
  skip SwiftUI body re-evaluation during typing — no new `@EnvironmentObject`/`@ObservedObject`/
  `@Binding` without updating `==`; `TerminalSurface.forceRefresh()`
  (`Sources/GhosttyTerminalView.swift`) runs on every keystroke and must stay allocation/IO-free.
- **Socket command threading policy** (`CLAUDE.md`): telemetry hot-path commands
  (`surface.report_*`, `surface.ports_kick`, status/progress/log metadata) must not use
  `DispatchQueue.main.sync`; parse/validate/dedupe off-main, minimal main-thread mutation only.

## 10. Release/update

Single auto-ship lane (`CLAUDE.md`, `.github/workflows/release.yml`): every commit on `main` that
passes `CI` is built, signed, notarized, and published as the latest GitHub release, triggered by
`workflow_run` on `CI` success. No nightly/beta channel — fix-forward on `main`. Auto-ship builds
get a monotonic build number from the CI run ID plus a version string with the patch component
replaced by the run number (e.g. `0.4.213`), injected into `Info.plist` at build time (never
committed). Published to a single reused `rolling` GitHub release (title = effective version,
marked latest, overwritten each ship). Each ship also promotes one sealed
`rolling-candidate-<build>` prerelease into that ship's permanent `vX.Y.Z`-independent archive
tag, then prunes older promoted candidates to the two newest (rollback window). Milestone
major/minor bumps remain manual (`scripts/bump-version.sh`), optionally tagged `vX.Y.Z` (also
built by the same workflow on tag push). Diagnostics log:
`~/Library/Logs/Programa/diagnostics.log`, always-on since a prior PR (per team memory
`[[release-diagnostics-log]]` — ask for it first on release bug reports); `programa-update.log`
for update-flow-specific bugs. (Sparkle is the updater: `Sources/Update/UpdateController.swift` drives `SPUUpdater` with a custom delegate and UI in `Sources/Update/`; the feed points at the GitHub `rolling` release described in CLAUDE.md.)

## 11. Things removed on purpose (`docs/removed/*.md`)

Reductive pass of 2026-09-02, base commit `903027ccef`. Every entry names the commit to restore
from (`git checkout 903027ccef -- <paths>`) and a "what we learned" section (not reproduced here
— read the individual file before re-adding).

- **`applescript.md`** — AppleScript support (`Sources/AppleScriptSupport.swift`,
  `Resources/programa.sdef`).
- **`browser-data-import.md`** — browser data import wizard.
- **`browser-developer-tools.md`** — **not actually removed**; scoped for the same pass but the
  implementer stopped and reported back instead of guessing. The hosted inspector dock is still
  live (`Sources/Panels/InspectorDock.swift`).
- **`browser-extensions.md`** — browser extension support
  (`BrowserExtensionManager.swift`, `BrowserExtensionAdapters.swift`).
- **`browser-react-grab.md`** — React Grab (`Sources/Panels/ReactGrab.swift`).
- **`custom-notification-sounds.md`** — custom notification sound files.
- **`inline-vscode.md`** — inline VS Code / `serve-web` integration
  (`Sources/VSCodeIntegration.swift`).
- **`mobile-bridge-and-ios.md`** — Mobile Bridge and an iOS companion app
  (`Sources/MobileBridge`, `ios/`, `vendor/CmuxIrohTransport`, `vendor/CMUXMobileCore`, iOS
  TestFlight CI workflows).
- **`ssh-remote-workspaces.md`** — SSH remote workspaces: the largest removal, a full remote
  daemon/session/proxy stack (`Sources/Workspace+Remote.swift` and ~15 sibling files,
  `CLI/CLI+SSH.swift`, a `daemon/` directory, `docs/remote-daemon-spec.md`, ~15 `tests_v2/
  test_ssh_remote_*.py` files). Notable because `docs/plans/detached-sessions.md` explicitly
  models its local escrow design on this removed feature's `session.*` naming/resize semantics —
  the removed remote daemon is still a live design reference even though its code is gone.

Core kept per the removal pass's own summary (`docs/removed/README.md`): the Ghostty terminal,
workspaces and splits, the sidebar, agent status detection and hooks, notifications, the browser
panel and its automation API, the diff review panel, worktrees and race, layouts, the markdown
recap panel, the CLI, socket API, and MCP server, updates, session persistence and escrow, the
Claude quota footer, and the local tmux-compat CLI — i.e. everything covered in §1-§10 above is
the deliberately-retained surface a cross-platform core spec should target.
