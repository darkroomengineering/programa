# V2 Socket API

**The v1 line protocol (space-delimited commands) was removed on 2026-07-08.** v2 JSON-RPC
is now the only socket protocol. Every consumer (CLI, shell integration, the debug/test
harnesses, and the automated test suites) was migrated to v2 first (see `tests_v2/`), and
a non-JSON line now gets a terse `v1_removed` error from `TerminalController.processCommand`
instead of being dispatched. The method mapping table below is kept for reference when
reading old scripts, commits, or bug reports that mention v1 command names.

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
- v2 methods accept **IDs**; v2 responses may include ephemeral `index` fields for ordering/debugging, but IDs are the stable handles.
- Auth (`auth.login`) is handled as a connection-level preamble before protocol dispatch, not a regular method — it worked the same way for v1 and v2 clients and was unaffected by the v1 removal.

## Method Parity Reference (former v1 name -> v2 method)

System:
- ping -> `system.ping` (liveness; the CLI's `ping` subcommand calls this and prints "PONG" on success)

Windows:
- list_windows -> `window.list`
- current_window -> `window.current`
- focus_window -> `window.focus`
- new_window -> `window.create`
- close_window -> `window.close`
- move_workspace_to_window -> `workspace.move_to_window`

Workspaces:
- list_workspaces -> `workspace.list`
- new_workspace -> `workspace.create`
- select_workspace -> `workspace.select`
- current_workspace -> `workspace.current`
- close_workspace -> `workspace.close`

Surfaces / Splits:
- list_surfaces -> `surface.list`
- focus_surface / focus_surface_by_panel -> `surface.focus`
- new_split -> `surface.split`
- new_surface -> `surface.create`
- close_surface -> `surface.close`
- drag_surface_to_split -> `surface.drag_to_split`
- refresh_surfaces -> `surface.refresh`
- surface_health -> `surface.health`
- trigger_flash -> `surface.trigger_flash` (new in v2)

Surface Telemetry (report_*/ports/git/pr — off-main parse, main.async mutate; see "Socket
command threading policy" in the root `CLAUDE.md`):
- report_tty -> `surface.report_tty`
- ports_kick -> `surface.ports_kick`
- report_pwd -> `surface.report_pwd`
- report_shell_state -> `surface.report_shell_state` (shares the `SocketFastPathState` dedup helper)
- report_git_branch -> `surface.report_git_branch`
- clear_git_branch -> `surface.clear_git_branch`
- report_pr / report_review -> `surface.report_pr`
- clear_pr -> `surface.clear_pr`
- report_ports -> `surface.report_ports`
- clear_ports -> `surface.clear_ports` (omit `surface_id` to clear all ports for the workspace)

Panes:
- list_panes -> `pane.list`
- focus_pane -> `pane.focus`
- list_pane_surfaces -> `pane.surfaces`
- new_pane -> `pane.create`

Input:
- send / send_surface -> `surface.send_text`
- send_key / send_key_surface -> `surface.send_key`

Sidebar Metadata (workspace-scoped — the set_status/log/set_progress/sidebar_state family
mutates a `Tab`/`Workspace`, not a specific surface; mutations are off-main + main.async,
reads use `v2MainSync` like sibling read methods):
- set_status -> `workspace.set_status`
- clear_status -> `workspace.clear_status`
- list_status -> `workspace.list_status`
- log -> `workspace.log`
- clear_log -> `workspace.clear_log`
- list_log -> `workspace.list_log`
- set_progress -> `workspace.set_progress`
- clear_progress -> `workspace.clear_progress`
- sidebar_state -> `workspace.sidebar_state`
- clear_agent_pid -> `workspace.clear_agent_pid`
- set_agent_pid -> `workspace.set_agent_pid`
- report_meta / clear_meta / list_meta -> alias of `workspace.set_status` / `clear_status` / `list_status`
- report_meta_block -> `workspace.report_meta_block`
- clear_meta_block -> `workspace.clear_meta_block`
- list_meta_blocks -> `workspace.list_meta_blocks`
- reset_sidebar -> `workspace.reset_sidebar`
- read_screen -> `surface.read_text` (already covered read_screen's scrollback/lines semantics)

Notifications:
- notify -> `notification.create`
- notify_surface -> `notification.create_for_surface`
- notify_target -> `notification.create_for_target`
- list_notifications -> `notification.list`
- clear_notifications -> `notification.clear` (accepts an optional `workspace_id` to scope the clear to one workspace, matching v1's `--tab=X`; omitting it clears all notifications, matching v1's bare `clear_notifications`)
- set_app_focus -> `app.focus_override.set`
- simulate_app_active -> `app.simulate_active`
- reload_config -> `app.reload_config`

Browser:
- open_browser -> `browser.open_split`
- navigate -> `browser.navigate`
- browser_back -> `browser.back`
- browser_forward -> `browser.forward`
- browser_reload -> `browser.reload`
- get_url -> `browser.url.get`
- focus_webview -> `browser.focus_webview`
- is_webview_focused -> `browser.is_webview_focused`

Debug / Test-only:
- set_shortcut -> `debug.shortcut.set`
- simulate_shortcut -> `debug.shortcut.simulate`
- simulate_type -> `debug.type`
- activate_app -> `debug.app.activate`
- is_terminal_focused -> `debug.terminal.is_focused`
- read_terminal_text -> `debug.terminal.read_text`
- render_stats -> `debug.terminal.render_stats`
- layout_debug -> `debug.layout`
- bonsplit_underflow_count/reset -> `debug.bonsplit_underflow.*`
- empty_panel_count/reset -> `debug.empty_panel.*`
- focus_notification -> `debug.notification.focus`
- flash_count/reset -> `debug.flash.*`
- panel_snapshot/panel_snapshot_reset -> `debug.panel_snapshot.*`
- screenshot -> `debug.window.screenshot`

## Tests

`tests_v2/` (driven by `tests_v2/programa.py`) is the only test suite and the CI gate. The
v1 python suite (`tests/`) was deleted before the protocol itself was removed.
