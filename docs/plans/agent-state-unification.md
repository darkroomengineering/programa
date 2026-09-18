# Agent state unification

One source of truth for agent working/blocked/idle, one sidebar indicator, one write
path for "needs input", and a watchdog that retires state nobody is maintaining.

## Functional DAG

```
hook events (CLI/CLI+Hooks.swift) ─────────────┐
screen inference (AgentScreenDetectionEngine) ─┼─> Workspace.updatePanelAgentState
watchdog tick (agentPIDSweepTimer) ────────────┘        │  (single funnel)
                                                        v
                                          Workspace.panelAgentPresence
                                             (state, source, lastEventAt,
                                              sessionKey, isStale)
                                                        │
                        ┌───────────────────────────────┼───────────────────────────┐
                        v                               v                           v
          SidebarAgentIndicator.make()      panelAgentStates (derived,     AgentOverviewFriendlyState
                        │                    wire + surface.wait)              .from(presence:)
                        v                               │                           │
                 TabItemView row                        │                           │
                        │                               │                           │
                        └──────────────> verification: T8 tests + tagged build <─────┘
                                                        ^
        TerminalNotificationStore <── agent.needs_input ─┘ (atomic state+notification write)
```

Parallel batches read off the columns: T1 alone; then T2 and T4 together; then T3, T5,
T6, T7 together; then T8.

## 1. Target design

**Keep `AgentActivityState`** (Sources/AgentActivityState.swift:18-21) as the three-value
enum. It is on the wire (`agent_state` in `surface.list`, `system.snapshot`,
`surface.wait`), string-asserted in tests, and documented. Renaming it buys nothing.
Add the context around it instead.

New value type in the same file (no new Swift file, so no pbxproj entries):

```swift
struct AgentPresence: Equatable, Sendable {
    var state: AgentActivityState
    var source: AgentStateSource
    var lastEventAt: Date
    var sessionKey: AgentSessionKey?   // provider + hook session id + pid
    func isStale(now: Date, threshold: TimeInterval = 600) -> Bool
}
```

`isStale` is true when `state != .idle` and `now - lastEventAt > threshold`. Idle never
goes stale; it is already the resting value.

**Storage.** `Workspace.panelAgentPresence: [UUID: AgentPresence]` becomes the stored
`@Published` property (Sources/Workspace.swift:170-175). `panelAgentStates` and
`panelAgentStateSources` become computed read-only mirrors over it, so the two can never
diverge. Internal writers that mutate the dictionaries directly must move to presence:
Workspace+SidebarTelemetry.swift:264-265, :282-283, :314-315, :450 and :453.
`sidebarRenderStateObservationPublisher` (Workspace.swift:220-232) swaps its two
`sidebarObservationSignal` entries for one on `$panelAgentPresence`; `AgentPresence`
must be `Equatable` for that helper.

**Derived indicator.** One function, next to the presence type:

```swift
struct SidebarAgentIndicator: Equatable {
    let systemImage: String
    let label: String      // localized, short
    let tint: IndicatorTint   // .blocked / .working / .idle / .stale
    let isStale: Bool
    static func make(for workspace: Workspace, now: Date) -> SidebarAgentIndicator?
}
```

It aggregates worst-first exactly as `aggregateAgentState` does today
(AgentActivityState.swift:59-64), returns `nil` when no surface has presence, and is the
only place that picks a glyph or a word for agent state. Labels: "Needs input",
"Working", "Idle", and for stale "Needs input (stale)" / "Working (stale)". Stale renders
the same glyph at reduced opacity with the suffixed label; it does not clear.

**TabItemView changes** (Sources/TabItemView.swift):

| Element | Today | After |
|---|---|---|
| Agent badge, :273-305 rendered :450-456 | own glyph/color/label switches | reads `SidebarAgentIndicator`, adds the short label text next to the glyph |
| Notification subtitle, :519-526 fed by `latestNotificationText` :361-362 | shows the hook notification body, including "needs your permission" text | keeps rendering notifications, but the hook stops posting agent-state phrasing into `subtitle`; body text stays |
| Metadata rows, :528-547 via `tab.sidebarStatusEntriesInDisplayOrder()` | shows the `claude_code` status entry "Running"/"Waiting"/"Needs input" | the `claude_code` key stops carrying agent state (T3); progress, ports, PR rows unchanged |

Unread count badge (:432-441), log row (:550-562), progress (:565-586), branch rows stay
untouched. TabItemView's `Equatable` conformance (:82-101) and `.equatable()` call site
stay as they are: the indicator is derived from `tab`, which is already compared by
identity, and `panelAgentPresence` drives the existing `.onReceive` at :763. Do not add
an `@ObservedObject` or `@Binding` for this.

## 2. Writer unification

Today a "needs input" hook does three independent socket calls:
`notification.create_for_target` (CLI+Hooks.swift:423-429), `workspace.set_status` with
value "Needs input" (:430-436), `surface.report_agent_state` (:437-442) plus
`agent.event` (:443). Any one can fail alone, which is the clunkiness.

Add one method, `agent.needs_input`, handled in
Sources/TerminalController+Telemetry.swift next to `v2AgentEvent` (:336-392). Params:
`workspace_id`, `surface_id`, `provider`, `title`, `subtitle`, `body`, optional
`session_id`, optional `pid`, optional `kind` ("permission" | "question"). It performs,
in one scheduled mutation: write presence `.blocked` with `source: .hooks`,
`lastEventAt: now`, `sessionKey`; then `TerminalNotificationStore.addNotification` on
main; then `AgentSupervisionRegistry.updateActiveSurface(.blocked)`. Notification
creation must stay on main (it drives AppKit), so the handler parses and resolves
off-main and hops once, per the socket threading policy.

Backward compatibility. `surface.report_agent_state`, `agent.event`,
`notification.create_for_target`, `workspace.set_status` all keep working unchanged;
`agent.needs_input` is additive. Installed hook configuration on user machines only
names CLI subcommands (`programa claude-hook notification`, `codex-hook`,
`opencode-hook`; the frozen subcommand lists are in CLI/programa.swift:6522-6541 and the
installer writes them via CLI/HookInstallationCoordinator.swift and Resources/bin/claude).
Those subcommands and their arguments do not change, so no reinstall is needed. Both
`surface.report_agent_state` and `agent.event` gain optional `session_id` and `pid`
params; older CLI builds simply omit them and get `sessionKey == nil`.

CLI call sites to convert to `agent.needs_input` (each replaces the create+status+state
trio): Claude notification CLI+Hooks.swift:386-444; Codex notification around :3517-3540;
OpenCode permission around :3993-4010. The pid comes from
`ClaudeHookSessionStore.lookup(...)?.pid`, already read at :612 and :3423.

`setClaudeStatus` (:689-708) stops being called with agent-state values: drop the
"Needs input" call at :430-436 and change the pre-tool-use call at :659-674 to keep only
the verbose tool description when `claudeCodeVerboseStatus` is on, otherwise send
nothing. The pid registration that call carried moves into `agent.needs_input` and
`surface.report_agent_state` via the new `pid` param, so PID-based port scanning and the
liveness sweep keep working.

Contract work: add the method and the two new optional params to
contracts/v2/methods.json, register the name in CLI/V2MethodNames.swift and
Sources/V2CommandCatalog.swift:126 area, dispatch in Sources/TerminalController.swift
near :2177, then run `scripts/check-v2-contract.sh`.

## 3. Clearing rules

Blocked clears only on a real resume signal:

- a hook reports `working` or `idle` for that surface (pre-tool-use at :651-655, Stop,
  turn.completed, request.resolved, user-input.resolved);
- `session.exited` / session-end clears presence entirely (:571-576);
- the surface is destroyed, or `resetSidebarContext` runs (:291-324).

Focus does not clear it. `TabManager.dismissNotificationOnDirectInteraction`
(Sources/TabManager.swift:3032-3048) keeps its current body verbatim: it marks
notifications read, clears the focused-read indicator, flashes the panel. It must not
touch `panelAgentPresence`. Add a one-line comment saying so, since that is exactly the
mistake the next reader will make. Same for the row click path at TabItemView.swift:1268.

## 4. Watchdog

Liveness source: `Workspace.agentPIDs` (Workspace.swift:183), keyed by status key and
populated from the hook `pid`; `sweepStaleAgentPIDs`
(Sources/TabManager+GitMetadataPolling.swift:213-241) already probes it with `kill(pid, 0)`
on a 30 second `DispatchSource` timer (:15-25).

Extend that same sweep, no new timer:

1. Presence whose `sessionKey.pid` is gone (ESRCH) is cleared outright, same as the
   status entry is today.
2. Presence with `state != .idle` and `now - lastEventAt > 600` is marked stale in place
   (`isStale` is computed, so nothing is written; the sweep only needs to nudge the
   publisher once per transition so the row redraws). Stale never clears on its own.
3. When a workspace has no live agent PID and no presence left, existing notification
   cleanup at :238 is unchanged.

The probe loop stays off-main where it is today (timer on the utility queue) and the
mutation hop to main stays a single `DispatchQueue.main.async`, per the threading policy.

Relaunch: **start clean**, do not persist presence. Presence is already non-persisted,
and a restored workspace has no process re-reporting into it, so a persisted "blocked"
would be a badge with no writer and no clear path. PTYs that survive through session
escrow re-report on their next hook event, which is at worst one turn away. The cost is
an empty badge for a few seconds; the alternative is a red badge that lies.

## 5. Screen inference

`AgentScreenDetectionEngine` stays, unchanged in behavior. It writes through the same
funnel with `source: .inferred`, so it now produces `AgentPresence` with
`lastEventAt = now` for free. The hooks-win guards at :163, :204, :259-261 and in
`updatePanelAgentState` (:259-261) are unchanged. Two notes for the implementer:
inferred presence uses the same 10 minute staleness rule, and inferred writes must never
carry a `sessionKey` (there is no session to key on).

## 6. Task DAG

Build check for every task:
`PROGRAMA_SKIP_ZIG_BUILD=1 ./scripts/reload.sh --tag agent-presence`, expect
`** BUILD SUCCEEDED **` and an `App path:` line. Test-compile check:
`xcodebuild -project GhosttyTabs.xcodeproj -scheme programa-unit -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/programa-agent-presence build-for-testing`.
Tests run on CI only.

| # | Task | Files (verified line ranges) | Depends on |
|---|---|---|---|
| T1 | `AgentPresence`, `SidebarAgentIndicator`, presence-backed storage with derived mirrors | AgentActivityState.swift:18-69; Workspace.swift:168-175, 220-232; Workspace+SidebarTelemetry.swift:255-289, 313-319, 449-453 | — |
| T2 | `agent.needs_input` handler; optional `session_id`/`pid` on the two existing methods; contract + catalog + dispatch | TerminalController+Telemetry.swift:279-392; TerminalController+Notification.swift:87-120; TerminalController.swift:2177; V2CommandCatalog.swift:126; CLI/V2MethodNames.swift:154-157; contracts/v2/methods.json:76, 6380 | T1 |
| T3 | CLI writers: one call per needs-input; stop writing agent state into `workspace.set_status` | CLI+Hooks.swift:386-444, 430-436, 571-576, 651-675, 3517-3540, 3993-4010; CLI+AgentEventAdapters.swift:39-87 | T2 |
| T4 | Sidebar row: single indicator with glyph + label; remove the duplicate signals | TabItemView.swift:262-305, 450-456, 519-526, 528-547 | T1 |
| T5 | Watchdog in the existing sweep | TabManager+GitMetadataPolling.swift:13-26, 213-241 | T1 |
| T6 | Clearing rules and comments | TabManager.swift:3032-3048; TabItemView.swift:1268 | T1 |
| T7 | Agent Overview reads presence | AgentOverviewWindow.swift:24-30, 211-221, 445-463 | T1 |
| T8 | Tests, localization, docs | below | T3-T7 |

T2 and T4 run in parallel after T1. T3, T5, T6, T7 run in parallel after that. Give each
parallel writer its own worktree; T3 and T4 touch disjoint files.

## 7. Tests

All behavioral, through the workspace and socket seams, per the repo test policy. Add to
programaTests/AgentActivityStateTests.swift and NotificationAndMenuBarTests.swift, plus a
tests_v2 socket case for the new method.

1. `agent.needs_input` leaves presence `.blocked` and exactly one unread notification for
   the same surface; no `claude_code` status entry mentioning agent state.
2. Marking the workspace read (`dismissNotificationOnDirectInteraction`) drops the unread
   count to zero and leaves presence `.blocked`.
3. A following `surface.report_agent_state` with `working` clears blocked; presence
   source stays `.hooks`.
4. `agent.event` `session.exited` clears presence and the indicator returns `nil`.
5. Watchdog: presence with `lastEventAt` 11 minutes back reports `isStale`, still
   `.blocked`; with a dead pid it is cleared. Inject the clock through the existing
   `now` seam pattern used by `AgentScreenDetectionEngine.init`.
6. Restore: a restored session snapshot yields no presence and no badge.
7. An `.inferred` write against a `.hooks`-owned surface is dropped, and `lastEventAt`
   does not move.

Regression tests for the reliability bugs use the two-commit structure from CLAUDE.md:
failing test first, fix second.

## 8. Risks, rollback, docs

- **Derived-mirror risk.** Making `panelAgentStates` computed touches `surface.wait`,
  `surface.list`, `system.snapshot`, and AgentSupervision. Mitigation: keep the mirrors
  byte-identical in shape and run the existing agent-state socket tests before T2 lands.
- **Losing the status line.** Some users read "Running" in the metadata row. The new row
  label replaces it. If that reads as a regression, T3 is a one-commit revert of the CLI
  side; the app keeps working.
- **PID plumbing.** Dropping the "Needs input" `set_status` call also dropped its pid
  registration. If T3 lands without T2's `pid` param, port scanning for that agent goes
  dark. Land T2 first, and verify a workspace still lists agent ports after a Claude turn.
- **Staleness false positives.** A genuinely long tool call with no intermediate hook
  event would mark stale at 10 minutes. It renders as a dimmed suffix, not a clear, so
  the cost is cosmetic.

Docs to update: docs/notifications.md (the needs-input lifecycle and what the sidebar
now shows), docs/agent-detection-manifests.md (inferred tier feeds presence),
docs/plans/agent-events.md (new method alongside the event mapping), docs/v2-api-migration.md
(method list), contracts/v2/methods.json, and the generated Python client
tests_v2/programa_v2.py via `scripts/gen-v2-contract.py`.

Plan complete. Delegate to implementer for execution.
