# V2 Socket API + Test Migration

This doc tracks the migration from the existing v1 line protocol (space-delimited commands) to a v2 JSON protocol intended for LLM agents.

## Goals

- Add a **v2 JSON socket protocol** (handle-based: `window_id`, `workspace_id`, `pane_id`, `surface_id`).
- Keep **v1 fully working** until v2 reaches feature parity.
- Re-implement the existing automated test suite to use **v2**.
- Run both suites:
  - v1 tests (existing `tests/`)
  - v2 tests (new `tests_v2/`)

## Non-Goals (for initial parity)

- Removing v1.
- Changing existing v1 behaviors/output formats.

## Status

- [x] Implement v2 request/response envelope (JSON, newline-delimited)
- [x] Implement v2 core methods (workspaces/surfaces/panes/input/notifications/browser)
- [x] Implement v2 multi-window methods (windows + cross-window workspace moves)
- [x] Add `surface.trigger_flash` (agent-visible highlight for a surface)
- [x] Implement v2 debug/test methods (simulate typing, render stats, screenshots, etc.)
- [x] Add `tests_v2/` using v2 client
- [x] Add runners for v1 + v2 suites on the VM (`./scripts/run-tests-v1.sh`, `./scripts/run-tests-v2.sh`)
- [x] Verify v1 suite passes (VM)
- [x] Verify v2 suite passes (VM)
- [x] Add remaining v2 methods for full v1 parity (surface telemetry + sidebar metadata
      family + `app.reload_config` + `workspace.clear_agent_pid`) — v1 handlers are
      untouched; this only adds v2 adapters. **v1 removal is planned in a follow-up PR**
      once consumers (shell integration, `tests/`) migrate to v2.

Notes:
- A close-top nested split sequence (T-shape) could leave terminal views detached from the window until the user switched workspaces.
  Fix: a debounced post-close reattach pass (see `Sources/Workspace.swift`, `Sources/Panels/TerminalPanel.swift`).

## V2 Protocol Sketch

Each request is one JSON object per line:

```json
{"id":"1","method":"workspace.list","params":{}}
```

Each response is one JSON object per line:

```json
{"id":"1","ok":true,"result":{...}}
```

Errors:

```json
{"id":"1","ok":false,"error":{"code":"not_found","message":"workspace not found"}}
```

Notes:
- `id` is echoed back when present (string or number).
- v2 methods should accept **IDs**; v2 responses may include ephemeral `index` fields for ordering/debugging, but IDs are the stable handles.

## Method Parity Checklist (v1 -> v2)

Windows:
- [x] list_windows -> `window.list`
- [x] current_window -> `window.current`
- [x] focus_window -> `window.focus`
- [x] new_window -> `window.create`
- [x] close_window -> `window.close`
- [x] move_workspace_to_window -> `workspace.move_to_window`

Workspaces:
- [x] list_workspaces -> `workspace.list`
- [x] new_workspace -> `workspace.create`
- [x] select_workspace -> `workspace.select`
- [x] current_workspace -> `workspace.current`
- [x] close_workspace -> `workspace.close`

Surfaces / Splits:
- [x] list_surfaces -> `surface.list`
- [x] focus_surface / focus_surface_by_panel -> `surface.focus`
- [x] new_split -> `surface.split`
- [x] new_surface -> `surface.create`
- [x] close_surface -> `surface.close`
- [x] drag_surface_to_split -> `surface.drag_to_split`
- [x] refresh_surfaces -> `surface.refresh`
- [x] surface_health -> `surface.health`
- [x] trigger_flash -> `surface.trigger_flash` (new in v2)

Surface Telemetry (report_*/ports/git/pr — off-main parse, main.async mutate; see "Socket
command threading policy" in the root `CLAUDE.md`):
- [x] report_tty -> `surface.report_tty`
- [x] ports_kick -> `surface.ports_kick`
- [x] report_pwd -> `surface.report_pwd`
- [x] report_shell_state -> `surface.report_shell_state` (reuses the v1 `SocketFastPathState` dedup)
- [x] report_git_branch -> `surface.report_git_branch`
- [x] clear_git_branch -> `surface.clear_git_branch`
- [x] report_pr / report_review -> `surface.report_pr`
- [x] clear_pr -> `surface.clear_pr`
- [x] report_ports -> `surface.report_ports`
- [x] clear_ports -> `surface.clear_ports` (omit `surface_id` to clear all ports for the workspace)

Panes:
- [x] list_panes -> `pane.list`
- [x] focus_pane -> `pane.focus`
- [x] list_pane_surfaces -> `pane.surfaces`
- [x] new_pane -> `pane.create`

Input:
- [x] send / send_surface -> `surface.send_text`
- [x] send_key / send_key_surface -> `surface.send_key`

Sidebar Metadata (workspace-scoped — v1's set_status/log/set_progress/sidebar_state family
mutate a `Tab`/`Workspace`, not a specific surface; mutations are off-main + main.async,
reads use `v2MainSync` like sibling read methods):
- [x] set_status -> `workspace.set_status`
- [x] clear_status -> `workspace.clear_status`
- [x] list_status -> `workspace.list_status`
- [x] log -> `workspace.log`
- [x] clear_log -> `workspace.clear_log`
- [x] list_log -> `workspace.list_log`
- [x] set_progress -> `workspace.set_progress`
- [x] clear_progress -> `workspace.clear_progress`
- [x] sidebar_state -> `workspace.sidebar_state`
- [x] clear_agent_pid -> `workspace.clear_agent_pid`

Notifications:
- [x] notify -> `notification.create`
- [x] notify_surface -> `notification.create_for_surface`
- [x] notify_target -> `notification.create_for_target`
- [x] list_notifications -> `notification.list`
- [x] clear_notifications -> `notification.clear`
- [x] set_app_focus -> `app.focus_override.set`
- [x] simulate_app_active -> `app.simulate_active`
- [x] reload_config -> `app.reload_config`

Browser:
- [x] open_browser -> `browser.open_split`
- [x] navigate -> `browser.navigate`
- [x] browser_back -> `browser.back`
- [x] browser_forward -> `browser.forward`
- [x] browser_reload -> `browser.reload`
- [x] get_url -> `browser.url.get`
- [x] focus_webview -> `browser.focus_webview`
- [x] is_webview_focused -> `browser.is_webview_focused`

Debug / Test-only:
- [x] set_shortcut -> `debug.shortcut.set`
- [x] simulate_shortcut -> `debug.shortcut.simulate`
- [x] simulate_type -> `debug.type`
- [x] activate_app -> `debug.app.activate`
- [x] is_terminal_focused -> `debug.terminal.is_focused`
- [x] read_terminal_text -> `debug.terminal.read_text`
- [x] render_stats -> `debug.terminal.render_stats`
- [x] layout_debug -> `debug.layout`
- [x] bonsplit_underflow_count/reset -> `debug.bonsplit_underflow.*`
- [x] empty_panel_count/reset -> `debug.empty_panel.*`
- [x] focus_notification -> `debug.notification.focus`
- [x] flash_count/reset -> `debug.flash.*`
- [x] panel_snapshot/panel_snapshot_reset -> `debug.panel_snapshot.*`
- [x] screenshot -> `debug.window.screenshot`

## Test Migration

The v1 python suite (`tests/`, driven by `tests/cmux.py`) has been deleted now that `tests_v2/`
has full protocol parity. Only CI-infrastructure guard scripts and the two CI-wired tests ported
onto the v2 client remain in `tests/`.

v2 suite lives in `tests_v2/` and should:
- use a v2 JSON client (`tests_v2/programa.py`)
- avoid depending on v1 text output formats

VM runner:
- v2: `ssh programa-vm 'cd /Users/programa/GhosttyTabs && ./scripts/run-tests-v2.sh'`

## Open Questions

- Should v2 require explicit `workspace_id`/`surface_id` for all operations, or default to the currently-focused ones?
- For move/reorder operations (future): what are the policies for empty workspaces/windows?
