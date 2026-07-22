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
- (no v1 equivalent) -> `surface.wait` (new in v2, see "surface.wait" below)
- (no v1 equivalent) -> `agent.prompt` (new in v2, see "agent.prompt" below)
- (no v1 equivalent) -> `subscribe`/`unsubscribe` (new in v2, see "Socket Event Subscriptions" below)

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

## `surface.wait` (#166)

Server-owned, event-driven wait on a single surface: block the connection (with a timeout)
until a condition is met, instead of the caller polling `surface.read_text` in a loop. One
request, one response — no subscription/unsubscribe pair to manage. CLI: `programa
wait-surface`.

Request params (exactly one of `pattern` / `exit` / `agent_state` is required):

| Field | Type | Required | Notes |
|---|---|---|---|
| `workspace_id` / `surface_id` | string (id or ref) | no | Same resolution as other `surface.*` methods; defaults to the current workspace's focused surface. |
| `pattern` | string | one of `pattern`/`exit`/`agent_state` | Regex (ICU/`NSRegularExpression` syntax) matched against the surface's current text (screen + scrollback) on every check. |
| `exit` | bool | one of `pattern`/`exit`/`agent_state` | Wait for the surface's child process to exit. |
| `agent_state` | string | one of `pattern`/`exit`/`agent_state` | Wait for the surface's #164 agent activity state to reach `idle`, `working`, `blocked`, or transition at all (`any_change`). |
| `timeout_ms` | int | no | Default `30000`. Also accepts `timeout` (same units) for convenience. |
| `lines` | int | no | Caps how many trailing lines of scrollback `pattern` rereads per check (default `2000`); does not apply to `exit`/`agent_state`. |

Response (`ok: true`):

```json
{
  "id": "1",
  "ok": true,
  "result": {
    "workspace_id": "...", "workspace_ref": "workspace:1",
    "surface_id": "...", "surface_ref": "surface:2",
    "window_id": "...", "window_ref": "window:1",
    "condition": "pattern",
    "waited": true,
    "match": "BUILD SUCCEEDED"
  }
}
```

- `waited: false` means the condition was already true the instant the call arrived (a marker
  already present in scrollback, the surface had already exited, or its agent_state already
  satisfied the requested condition) — the caller never actually blocked.
- `match` is only present for `pattern` waits and is the substring the regex matched.
- `state` is only present for `agent_state` waits and is the observed value (`"idle"`,
  `"working"`, `"blocked"`, or `null` for "no state reported") at resolution.
- Timeout: `{"ok": false, "error": {"code": "timeout", "message": "...", "data": {"timeout_ms": N}}}`.
- If the target surface doesn't exist (or, for `pattern`/`agent_state`, is closed while the wait
  is in flight), the response is `not_found`, not a timeout — callers shouldn't have to wait out
  the full timeout to learn the surface is gone.

### `agent_state` condition values and the no-state rule

- `idle` — the surface's agent_state is `idle`, **or has never been reported at all**. Most
  terminals never report anything (no agent hooks installed), and a caller waiting for "idle"
  almost always means "not currently busy" — which is true of a bare terminal too. This is the
  one asymmetry versus `working`/`blocked`, which both require an actual explicit report; there
  is nothing to observe in the no-state case for those.
- `working` — the surface's agent_state is `working`.
- `blocked` — the surface's agent_state is `blocked` (a hook reported a permission/approval/
  question prompt — see #164).
- `any_change` — resolves on the *next* agent_state transition after the call arrives (including
  a transition to "no state" on clear/reset). Never counts as already-satisfied at registration
  time, even if the state happens to already differ from some caller-assumed baseline — there is
  nothing to compare against until a transition is actually observed.

Backpressure / disconnect: `surface.wait` holds its socket connection's dedicated thread for up
to `timeout_ms` (each connection is handled on its own thread — see `TerminalController.
handleClient` — so this never blocks other connections or the main thread). If the client
disconnects mid-wait, the in-flight `write()` of the eventual response simply fails and is
ignored; for the `exit`/`agent_state` conditions the registered watcher (in
`SurfaceExitWaitRegistry` / `AgentStateWaitRegistry`) still fires and is still cleaned up (the
callback is a fire-and-forget semaphore signal with nothing left to notify). There is no
server-side cap on concurrent waits; each is an independent blocked thread.

No-missed-events guarantee: the "is the condition already true?" check and "install the watcher"
step happen inside the same synchronous main-thread hop (`v2MainSync`), so a pattern marker
printed the instant the call arrives, a child-exit racing the call, or an agent_state change
racing the call, is always observed — see the doc comments on `SurfaceExitWaitRegistry`,
`AgentStateWaitRegistry`, and `TerminalController.v2SurfaceWait` in
`Sources/TerminalController+SurfaceWait.swift`. The `pattern` condition itself is polled
internally (Ghostty doesn't expose a push-based "surface content changed" callback the way it
does for child-exit) at a fixed ~100ms interval on the connection's own thread; `exit` and
`agent_state` are fully event-driven with no polling — `exit` off the same
`GHOSTTY_ACTION_SHOW_CHILD_EXITED` action that already closes the panel on process exit,
`agent_state` off the single main-thread mutation point for `Workspace.panelAgentStates`
(`Workspace.updatePanelAgentState`/`clearPanelAgentState`, always called from
`TerminalController+Telemetry.swift`'s `v2SurfaceReportAgentState`/`v2SurfaceClearAgentState` via
`DispatchQueue.main.async`).

## `agent.prompt` (#166)

Submit a prompt to an agent surface and wait for it to finish, in one request — built on
`surface.send_text`'s injection path plus `surface.wait`'s `agent_state` condition. CLI: `programa
prompt-agent`.

Request params:

| Field | Type | Required | Notes |
|---|---|---|---|
| `workspace_id` / `surface_id` | string (id or ref) | no | Same resolution as other `surface.*` methods; defaults to the current workspace's focused surface. |
| `text` | string | yes | The prompt. Enter is always submitted after it (trailing whitespace/newlines in `text` are trimmed first, so this never sends a stray blank line) — callers don't pass their own line ending. |
| `timeout_ms` | int | no | Overall budget for the agent to finish. Default `120000`. Also accepts `timeout`. |
| `working_grace_ms` | int | no | How long to wait for the agent to report it started working before giving up on observing that transition. Default `3000`. |

Response (`ok: true`):

```json
{
  "id": "1",
  "ok": true,
  "result": {
    "workspace_id": "...", "workspace_ref": "workspace:1",
    "surface_id": "...", "surface_ref": "surface:2",
    "window_id": "...", "window_ref": "window:1",
    "working_observed": true,
    "final_state": "idle"
  }
}
```

`warning` is present (success, not an error) when the surface never reported any `agent_state` at
all — neither before the prompt was sent nor during the grace window — which usually means agent
hooks were never installed for this surface.

### Semantics (phased, event-driven — no polling)

1. **Send + register, atomically.** The text is sent via the exact same path
   `surface.send_text` uses, and — inside that *same* main-thread hop — the surface's
   `agent_state` at that instant is captured and a watcher for the next `working` transition is
   registered via `AgentStateWaitRegistry`. This closes the race where a hook reacts to the
   injected text before a separately-registered watcher would exist (the same atomic
   check+register pattern `surface.wait` uses).
2. **Grace window (`working_grace_ms`).** Wait for the `working` transition.
   - Observed → go to step 3.
   - Not observed by the time the grace window elapses → there is nothing further useful to
     wait for, so resolve immediately using whatever `agent_state` the surface already has
     (`working_observed: false`). This is deliberately not a hard error: a prompt can finish
     faster than the grace window, or a hook simply may not fire for a trivial prompt.
3. **Wait for idle.** Having observed `working`, wait — for the *remaining* overall
   `timeout_ms` budget — for `agent_state` to reach `idle` (the same no-state-is-idle rule as
   `surface.wait` applies: a hook that clears its own state on session end also counts).
   Resolves with `working_observed: true`.
4. **Timeout.** If step 3's wait exceeds the remaining budget, the call fails with
   `{"code": "timeout", ...}` — the agent started working but never finished in time.

If the surface was already `working` when the prompt was sent (e.g. a second prompt queued while
one is running), step 2 is skipped entirely and the call goes straight to step 3.

## Socket Event Subscriptions (#167)

`subscribe` upgrades the calling connection to receive pushed events — agent state changes
(#164), coalesced surface output, and workspace lifecycle changes — instead of the caller
polling `surface.list`/`workspace.list`. Written before implementation, per the issue's ask that
backpressure/disconnect semantics be specified up front.

**This is not the front door.** `surface.wait` (one-shot conditions) and `agent.prompt` (submit +
wait) cover the common "wait for one thing" case in a single request/response round trip with no
queue/backpressure/reconnect model to manage. `subscribe` is for consumers that need *many*
events over time — dashboards, orchestrators, the menu bar of another machine — so a casual
caller never has to touch subscription machinery. CLI: `programa watch-events` (also positioned
as the advanced path, not the default way to wait for something).

### `subscribe`

| Field | Type | Required | Notes |
|---|---|---|---|
| `classes` | array of string | yes | Any of `agent_state`, `output`, `workspace_lifecycle`. Non-empty. |
| `surface_ids` | array of string (id or ref) | required iff `classes` includes `output` | `output` is opt-in per surface — broadcasting every surface's output to every subscriber by default would be prohibitively expensive. |

Response (`ok: true`): `{"subscription_id": "...", "classes": [...], "surface_ids": [...],
"max_queued_events": 256}`. A second `subscribe` on the same connection replaces the first
subscription (a connection has at most one).

### `unsubscribe`

No params. Tears down any live subscription on the calling connection; `ok: true` even if there
wasn't one, so a client doesn't need to track whether it subscribed.

### Event frames

Pushed events are **not** wrapped in the usual `{"id", "ok", "result"}` v2 envelope (there is no
request they're a response to) — each is its own single-line JSON object with an `"event"` key:

```json
{"event": "agent_state", "workspace_id": "...", "surface_id": "...", "state": "working", "ts": 1737590400.123}
{"event": "output", "workspace_id": "...", "surface_id": "...", "text": "new terminal output...", "ts": 1737590400.223}
{"event": "workspace_lifecycle", "kind": "renamed", "workspace_id": "...", "title": "new title", "ts": 1737590400.323}
{"event": "dropped", "count": 7}
```

- `agent_state.state` is `null` for a transition to "no state" (clear/reset) — same value shape
  as `surface.wait`'s `agent_state` result.
- `output.text` is the *newly appended* tail since the last tick for that surface, capped at
  4000 characters — never the full buffer, and never per-byte (see Backpressure below).
- `workspace_lifecycle.kind` is `created`, `closed`, or `renamed`. `renamed` fires only from the
  explicit rename entry point (tab-bar rename, `workspace.rename`) — not from automatic
  shell-title updates, which would otherwise flood subscribers on every `cd`.

### Backpressure

Each subscription owns a bounded, **drop-oldest** queue of **256 events**, drained on its own
dedicated serial dispatch queue — never on the thread that mutated app state (agent-state
mutation, output polling), so a slow or blocked client socket write never stalls a telemetry
mutation or the main thread. When the queue is full and a new event arrives, the oldest queued
event is evicted to make room (a client that's falling behind gets the *freshest* events, not a
growing backlog). Every time this happens, a `{"event": "dropped", "count": N}` frame is spliced
in ahead of the next real frame, so a client that sees one knows it may have missed events and
should re-sync current state with `surface.list`/`workspace.list` (frames carry `surface_id`/
`workspace_id` specifically so that re-sync is cheap and targeted).

`output` events are coalesced on a shared ~100ms poll tick across all watched surfaces (see
`TerminalController.v2StartOutputPollLoopIfNeeded`) — reusing the same point-in-time text read
`surface.wait`'s `pattern` condition uses, since Ghostty doesn't expose a push-based
"content changed" callback at the app layer. One thread total drives this regardless of
subscriber/surface count, and it is a no-op tick whenever nothing is being watched.

### Disconnect

The first failed `write()` (client gone) tears the subscription down immediately and unregisters
it from the broadcaster — no further events are enqueued for it. A connection's read loop
(`TerminalController.handleClient`) also unconditionally tears down any attached subscription
before closing the socket, covering client-initiated close and app shutdown alike. There is no
server-side cap on concurrent subscriptions.

## Tests

`tests_v2/` (driven by `tests_v2/programa.py`) is the only test suite and the CI gate. The
v1 python suite (`tests/`) was deleted before the protocol itself was removed.
