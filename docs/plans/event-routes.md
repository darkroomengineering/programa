## Functional DAG

```text
prereq ── git checkout -b feat/inc-976-event-routes
prereq ── record the answers to open questions 1-4 in this file
prereq ── P0 scaffold: new Swift files + project.pbxproj entries, contract methods + stub handlers, gen-v2-contract.py

Sources/ProgramaConfig.swift ────────────────────┐
Sources/ProgramaRoutes.swift ────────────────────┼── P1 decode routes ──┐
programaTests/ProgramaRouteDecodingTests.swift ──┘                      │
Sources/RouteMatching.swift ─────────────────────┐                      │
Sources/RouteGate.swift ─────────────────────────┼── P2 match + gate ───┤
programaTests/RouteGateTests.swift ──────────────┘                      │
Sources/TerminalController+Subscriptions.swift ─────────────────────────┼── P3 tap + engine ──┐
Sources/Workspace+SidebarTelemetry.swift ───────────────────────────────┤                     │
Sources/Workspace.swift ────────────────────────────────────────────────┤                     │
Sources/RouteEngine.swift ──────────────────────────────────────────────┤                     │
Sources/TerminalController+Routes.swift ────────────────────────────────┘                     │
Sources/RouteActions.swift ───────────────────────────────────────────────────────────────────┼── P4 notify, review, run ── P5 send + prompt ──┐
Sources/TerminalController+Telemetry.swift ───────────────────────────────────────────────────┤                                                │
Resources/Localizable.xcstrings ──────────────────────────────────────────────────────────────┘                                                │
CLI/Commands/TerminalIOCommands.swift ───────────┐                                                                                             │
docs/programa-json.md ───────────────────────────┼── P6 CLI + docs ────────────────────────────────────────────────────────────────────────────┼── P7 socket E2E ── P8 tagged build + CI green
docs/socket-api.md ──────────────────────────────┘                                                                                             │
tests_v2/test_event_routes.py ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
tests_v2/ci_subset.txt ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

Batches, read off the columns: P1, P2 and P6 run in parallel (disjoint files). P3, P4, P5, P7 and P8 are sequential. P0 is a single-writer prereq because every new Swift file needs four `project.pbxproj` entries (`CLAUDE.md:184`) and parallel writers would conflict in that file. The CLI file in the P6 row is the nearest existing example, not a checked location; P6 confirms where a new verb registers.

# Event routes: run an action when an agent goes blocked, idle, or finishes

Status: P0 to P6 implemented on `franco/inc-976-event-routes` (INC-976); P7's socket test is on the branch and waits on its first CI run; P8 pending. Open questions 1 to 4 decided 2026-11-12 (all as recommended), with the permission-banner refinement to question 2 decided 2026-11-13. Size M, about 5 working days (est., from the task breakdown below, not measured).

## Intent and continuity

Programa pushes `agent_state`, `output`, `workspace_lifecycle` and `needs_input` events to socket subscribers. Turning an event into an action is left to hand-written scripts on top of `programa watch-events`. This plan adds a `routes` block to `programa.json` that the app evaluates itself: each route names a topic pattern, a filter, a rate limit, and one action.

This is a repository-owned plan. Pick up the first incomplete task, read the referenced code before editing, and record evidence beside completed items.

Scope is the macOS app and the `programa` CLI. `core/` (Rust) and `windows/` are untouched: the macOS app does not link the core (`CLAUDE.md:15`).

No script, build or test was run while writing this plan: line budgets and contract checks are named here, not measured.

The route fields follow pmndrs/pine's `docs/references/events.md` (Routes, Filters). Debounce (trailing, last event of a burst), throttle (leading, ignore matches for the window), `whenBusy` (`queue` default, `steer` hands the text to the running work) and the default `key` of `{{topic}}` are pine's. `when` takes pine's syntax, cut to the operators the two ticket examples and their obvious variants need. Two deliberate departures: one action per route (pine allows several and orders them), and no `set`, `publish`, `call` or `trust` (out of scope per the ticket). Like pine, `debounceMs` and `throttleMs` accept a number of milliseconds or a duration string (`"4s"`, `"5m"`).

## Research basis

### 1. The event bus

`SocketEventBroadcaster` (`Sources/TerminalController+Subscriptions.swift:377`) is the only fan-out point. It has no in-process consumer: every `publish*` method returns before building a frame when no socket client subscribes to that class (`:429`, `:447`, `:458`, `:476`).

| Event | Publisher call sites | Frame keys (`docs/socket-api.md:870-898`) |
|---|---|---|
| `agent_state` | `Workspace.updatePanelAgentState` (`Sources/Workspace+SidebarTelemetry.swift:333`), `clearPanelAgentState` (`:361`), sidebar reset (`:531`), surface detach (`Sources/Workspace.swift:670`) | `workspace_id`, `surface_id`, `state` (`working`, `blocked`, `idle`, or null on clear), `source` (`hooks`, `inferred`, `program`, or null), `ts`, `program_status` only when `source` is `program` (`Subscriptions.swift:430-438`) |
| `needs_input` | `v2AgentNeedsInput` (`Sources/TerminalController+Telemetry.swift:527`) | `workspace_id`, `surface_id`, `ts`, and `kind`, `provider`, `title`, `subtitle`, `body` when non-empty (`Subscriptions.swift:448`) |
| `workspace_lifecycle` | `TabManager.swift:748` (created), `:1545` (renamed), `:1825` (closed) | `workspace_id`, `kind`, `title` (string or null), `ts` |
| `output` | 100 ms poll, `v2PollSubscribedOutputOnce` (`Subscriptions.swift:653-685`) | `workspace_id`, `surface_id`, `text` (appended tail, 4000 characters at most), `ts` |

Facts that shape the design:

- A repeated report of the same state from the same writer does not publish (`Workspace+SidebarTelemetry.swift:299-313`). `agent_state` frames are real transitions only.
- The `agent_state` frame carries neither the previous state nor the prompt kind. A session start also reports `idle` (`docs/plans/agent-events.md`, mapping table), so "goes idle" needs the edge. The previous state is in scope at every call site (`current` at `Workspace+SidebarTelemetry.swift:255`; the review nudge already uses the edge at `:327` and `:389`).
- `needs_input` fires on every `agent.needs_input` call whatever the agent-state precedence decides (`docs/socket-api.md:884-890`). Only hook callers of `agent.needs_input` publish it; a `blocked` state from screen detection or OSC 7501 produces `agent_state` only.
- `output` frames exist only for surfaces a socket client names in `subscribe`; the poll loop starts from `v2Subscribe` (`Subscriptions.swift:576-578`).
- Subscribe path: `subscribe` in `contracts/v2/methods.json:2757`, handler `v2Subscribe` (`Subscriptions.swift:537`), CLI `watch-events` (`CLI/Commands/TerminalIOCommands.swift:268`, `CLI/programa.swift:2364-2371`).

### 2. Where `programa.json` is parsed

- Schema: `ProgramaConfigFile` (`Sources/ProgramaConfig.swift:5-8`) with `commands` required and `recipes` optional. `programaTests/ProgramaConfigTests.swift:355` (`testDecodeMissingCommandsKeyThrows`) pins that a file without `commands` fails.
- Parse: `ProgramaConfigStore.parseConfig(at:)` (`ProgramaConfig.swift:562-601`). It is all-or-nothing: one bad entry fails the whole file, and the only report is `NSLog` (`:573`, `:580`, `:598`).
- Reload: `FileWatcher` on the local and the global file calls `loadAll()` (`:615-773`); `loadAll` returns early when commands and recipes are unchanged (`:546-551`).
- Ownership: there is one store per window (`Sources/ProgramaApp.swift:75`, `Sources/AppDelegate.swift:3477`), and each follows the selected workspace's directory (`ProgramaConfig.swift:439-464`). Events come from every workspace, including background ones, so the local config a store holds is not the config of the surface an event came from.
- Trust: a local config runs without a prompt only when `ProgramaDirectoryTrust.trustState` is `.trusted` (`Sources/ProgramaDirectoryTrust.swift:112-129`). The digest covers the whole canonical file (`:214-226`), so a `routes` edit already moves a trusted config to `.changed`. The gate itself is a modal dialog (`Sources/ProgramaConfigExecutor.swift:182-260`, `runModal` at `:412`); a route fires with no person present and cannot prompt. The global file is always trusted (`ProgramaDirectoryTrust.swift:113`).
- Per-element decoding that skips bad entries has a precedent in `ProgramaPaneDefinition.init(from:)` (`ProgramaConfig.swift:329-344`).

### 3. Primitives each action can call

| Action | Existing primitive | Gap |
|---|---|---|
| `notify` | `TerminalNotificationStore.shared.addNotification(tabId:surfaceId:title:subtitle:body:cooldownKey:cooldownInterval:deliversBanner:)` (`Sources/TerminalNotificationStore.swift:315`); title suffix from `TerminalController.v2ResolveNotificationTitle` (`Sources/TerminalController+Notification.swift:13`) | `agent.needs_input` already posts its own unthrottled notification (`TerminalController+Telemetry.swift:519-526`), and `addNotification` replaces the entry for the same workspace and surface (`TerminalNotificationStore.swift:341-347`). The banner claim that exists has one kind for every `needs_input` call (`Subscriptions.swift:36-39`) and is keyed by a `SocketConnection` (`:50`), so it cannot hold back the banner for some calls only. See open question 2. |
| `send`, `prompt` | `Workspace.deliverTextToAgent(_:terminalPanel:)` (`Sources/Workspace.swift:788`): one paste, plus Return only when `canAutoSubmitToAgent` holds (`:778`). `Workspace.sendReviewComments` (`:798`) is the in-app pattern: guard, then deliver, in one main hop. Guards: `terminalPanel.surface.activePromptHold()` and `activeDraftHold()`, as in `v2ApprovalGuardRejection` and `v2DraftGuardRejection` (`Sources/TerminalController+Surface.swift:1368`, `:1391`). | `agent.prompt` blocks its caller for up to the timeout (`Sources/TerminalController+AgentPrompt.swift:55`), so it is not usable from the engine. |
| `whenBusy` | Busy is `ws.panelAgentStates[surfaceId] == .working`, the test `agent.prompt` uses (`TerminalController+AgentPrompt.swift:106`, `:121`). Hold until idle: `AgentStateWaitRegistry.shared.addWaiter(surfaceId:condition:callback:)` (`Sources/TerminalController+SurfaceWait.swift:152`). | No queued-send primitive exists. `steer` is the existing behavior (deliver now). `queue` is new and is modeled in the gate below. |
| `run` | `CanonicalSubprocessRunner.run(executable:arguments:currentDirectory:timeout:stdoutLimit:stderrLimit:environmentOverrides:)` (`Sources/GitMetadataProber.swift:106`): bounded output, timeout, environment overrides. | No pane-job primitive exists. The command path of `programa.json` types into the focused terminal (`ProgramaConfigExecutor.swift:51-52`); typed into an agent surface that would submit a prompt. See open question 3. |
| `review` | `TerminalController.shared.v2ReviewOpen(params:)` (`Sources/TerminalController+Review.swift:169`): probes git off main, returns `unavailable` outside a repo, and with `focus: false` never activates the app or moves focus (`:265-281`). Model call: `Workspace.newReviewSplit` (`Sources/Workspace+Surfaces.swift:460`). | No guard against a second panel: skip when the workspace already has a `ReviewPanel`, the test at `Workspace+SidebarTelemetry.swift:423`. An open panel already refreshes itself on turn edges (`:422`). |

Templating: `ProgramaConfigExecutor.substituteParameters(in:values:)` (`ProgramaConfigExecutor.swift:472`) replaces `{{name}}` and leaves unknown names literal. Routes reuse it. The repo has no expression language and no glob helper.

## Design

### Two designs considered

- **A. Tap inside the broadcaster (chosen).** `SocketEventBroadcaster` builds the frame when a socket subscriber or the route engine wants the class, and hands the same frame to a route tap. One file changes on the publish side, and a route sees the keys `programa watch-events` prints.
- **B. Hooks at the mutation sites.** The engine observes typed model changes at the eight publisher call sites. It gives typed access to everything, but it creates a second event schema beside the wire one and touches four model files.

A hides more behind a smaller surface: publishers keep calling one function, and the engine's public surface is `install`, `ingest`, `snapshot` and `hasNotifyRoute(matching:)`. The ADR at the end records the decision.

### Usage first

```jsonc
// ~/.config/programa/programa.json
{
  "routes": [
    {
      "name": "blocked-question",
      "on": "agent/+/needs_input/question",
      "throttleMs": "5m",
      "notify": { "title": "Agent needs you", "body": "{{body}}" }
    },
    {
      "name": "tests-on-idle",
      "on": "agent/+/state/idle",
      "when": { "previous_state": { "in": ["working", "blocked"] }, "worktree": "true" },
      "debounceMs": 2000,
      "run": { "command": "npm test" }
    },
    {
      "name": "review-on-idle",
      "on": "agent/+/state/idle",
      "when": { "previous_state": { "in": ["working", "blocked"] }, "worktree": "true" },
      "debounceMs": 2000,
      "review": {}
    }
  ]
}
```

### Topics

A topic is `class/id/event/value`. The id level is a UUID, which an author always writes as `+`; the hand-written levels are the class, the event and the value.

| Topic | Source frame | Value level |
|---|---|---|
| `agent/<surface_id>/state/<value>` | `agent_state` | `working`, `blocked`, `idle`, or `none` for a clear |
| `agent/<surface_id>/needs_input/<value>` | `needs_input` | `permission`, `question`, or `unknown` when the call gave no kind |
| `workspace/<workspace_id>/<value>` | `workspace_lifecycle` | `created`, `closed`, `renamed` |

Patterns use MQTT rules: `+` matches exactly one level, `#` is valid only as the last level and matches the rest. `agent/+/state/idle`, `agent/+/needs_input/#`, `workspace/+/closed` and `agent/#` are all valid.

`output` topics are not in v1. Output frames need a per-surface poll that only a socket subscription starts, a `+` pattern would poll every surface's viewport on the main thread every 100 ms, and neither ticket example needs output. A pattern whose class is `surface` is a load issue.

### Fields

A route matches and templates against a flat string map: the frame's keys, plus fields the engine resolves from the model when it ingests the event. Null and empty values are absent keys. Numbers are their decimal string. `program_status` is flattened to `program_status.<key>`.

| Field | Topics | Source |
|---|---|---|
| `workspace_id`, `surface_id`, `state`, `source`, `kind`, `provider`, `title`, `subtitle`, `body`, `ts` | as in the frame | the frame |
| `previous_state` | `agent/+/state/+` | the state before the transition, passed by the four `publishAgentState` call sites; absent when there was none |
| `cwd` | `agent/#` | `Workspace.sidebarResolvedDirectory(for:)` (`Workspace+SidebarTelemetry.swift:723`), resolved with `realpath`; absent when it is not absolute or not an existing directory. `when` and `run` see only the resolved path, so `/allowed/../../elsewhere` or a symlink out of a `cwd` regex's scope cannot pass as the directory it names. |
| `git_branch` | `agent/#` | `workspace.panelGitBranches[surfaceId]?.branch` |
| `worktree` | `agent/#` | `"true"` when the surface's workspace has `worktreeBranch` set, that is, it was created or opened by `worktree.create` or `worktree.open` (`Sources/Workspace.swift:33-35`); else `"false"`. See open question 4. |

The added fields stay inside the app. The wire frames do not change.

### `when`

`when` is an object that maps a field to a value or to conditions, as in pine. Every key must hold (AND). There is no OR across keys and no nesting.

| Value | Holds when |
|---|---|
| string, boolean or number | the field equals it (`true` equals `"true"`) |
| `{ "ne": v }` | the field is absent or not equal to `v` |
| `{ "in": [...] }` | the field equals any element |
| `{ "exists": bool }` | the field is present, or absent for `false` |
| `{ "regex": "...", "flags": "i" }` | the field matches, via `NSRegularExpression`; compiled at load, a bad pattern is a route issue |

Pine's `gt`, `gte`, `lt`, `lte` and `contains` are left out: no v1 field is numeric or a list. An unknown operator is a route issue, so adding one later cannot change what an existing file means. A key whose field is absent fails every condition except `ne` and `exists: false`.

### Evaluation order and the gate

Order: topic match, then `when`, then `key`, then debounce, then throttle, then the action. This is the order of the fields in the ticket.

- `key` is a template over the fields. Default: `{{topic}}`, as in pine. Topics carry the surface or workspace ID and the state, so the default already separates surfaces; `"key": "{{surface_id}}"` makes all states of one surface share a window.
- `debounceMs` handles the last matching event of a burst: each match restarts the timer, and the newest event is handled when the timer runs out. Debounce collapses repeated matching events. It does not cancel on a non-matching event, so an agent that goes idle and then working again inside the window still fires an idle route.
- `throttleMs` admits one fire per window, on the leading edge. Events inside the window are dropped, not queued.
- With both set, debounce produces one candidate per burst and throttle admits or drops the candidate.
- A delivery that takes time (a `run` process, a `send` or `prompt` waiting for the agent) keeps its route busy for that key. Matches during it are dropped and counted. A `prompt` delivery stays in flight until the target surface next reports idle or clears, so a route on `agent/+/state/idle` whose action is `prompt` cannot trigger itself.

One state machine per (route name, key). There are no flags beside it, and an absent entry is the idle state.

```swift
enum RouteGateState: Equatable {
    case debouncing(pending: RouteEvent, deadline: Date, cooldownUntil: Date?)
    case delivering(RouteDelivery, expiresAt: Date, cooldownUntil: Date?)
    case coolingDown(until: Date)
}

enum RouteDelivery: Equatable {
    case running                      // `run`: the process is alive
    case waitingForIdle(RouteEvent)   // `send`/`prompt` with whenBusy queue: the agent is working
    case ownTurn                      // `prompt` delivered: the turn it started is open
}

enum RouteGateInput {
    case matched(RouteEvent, now: Date)
    case wake(now: Date)
    case deliveryEnded(now: Date)
    case turnStarted                  // a `prompt` was submitted
}

enum RouteGateEffect: Equatable {
    case fire(RouteEvent)
    case wake(at: Date)
    case cancelDelivery
    case count(RouteCounter)          // fired, throttled, busy, expired
}

static func reduce(
    _ state: RouteGateState?, _ input: RouteGateInput, route: CompiledRoute
) -> (RouteGateState?, [RouteGateEffect])
```

| State | Input | Next state | Effects |
|---|---|---|---|
| idle | matched, debounce set | `debouncing(e, now + d, nil)` | `wake(now + d)` |
| idle | matched, no debounce | after-fire | `fire(e)`, `count(fired)` |
| `debouncing(p, dl, cu)` | matched | `debouncing(e, now + d, cu)` | `wake(now + d)` |
| `debouncing(p, dl, cu)` | wake, `now < dl` | unchanged | none |
| `debouncing(p, dl, cu)` | wake, `now >= dl`, `cu > now` | `coolingDown(cu)` | `count(throttled)`, `wake(cu)` |
| `debouncing(p, dl, cu)` | wake, `now >= dl`, no live cooldown | after-fire | `fire(p)`, `count(fired)` |
| `coolingDown(u)` | matched, `now >= u` | as idle | as idle |
| `coolingDown(u)` | matched, `now < u`, debounce set | `debouncing(e, now + d, u)` | `wake(now + d)` |
| `coolingDown(u)` | matched, `now < u`, no debounce | unchanged | `count(throttled)` |
| `coolingDown(u)` | wake, `now >= u` | idle | none |
| `delivering(_, exp, cu)` | matched | unchanged | `count(busy)` |
| `delivering(_, exp, cu)` | deliveryEnded | `coolingDown(cu)` if `cu > now`, else idle | `wake(cu)` when cooling |
| `delivering(_, exp, cu)` | wake, `now >= exp` | `coolingDown(cu)` if `cu > now`, else idle | `cancelDelivery`, `count(expired)` |
| `delivering(waitingForIdle, exp, cu)` | turnStarted | `delivering(ownTurn, exp, cu)` | none |
| any other state | turnStarted | unchanged | none |

After-fire: the cooldown is `now + throttleMs` when `throttleMs` is set. `notify` and `review` go straight to `coolingDown` or idle. `run`, `send` and `prompt` go to `delivering` with `expiresAt` (`run.timeoutMs`, default 600000; 600000 fixed for `send` and `prompt`); the executor reports `deliveryEnded` when the process exits, the text is delivered and its turn ends, the delivery is refused, or the surface is gone. Each fire carries an ID, and a `deliveryEnded` from a fire the route no longer holds (it expired) is ignored apart from its error. A cancelled delivery is never followed by `deliveryEnded`.

The reducer takes `now` in its input and never reads the clock, so tests drive it with fixed times. A stale wake is a no-op by the table, so timers need no cancellation tokens. A config reload with a different digest cancels every in-flight delivery and clears every entry.

### Config: schema, reload, errors

- `ProgramaConfigFile` gains `routes` and `routeIssues`. A custom `init(from:)` decodes `routes` element by element with `superDecoder()`, as `ProgramaPaneDefinition` does, so one bad route becomes a `ProgramaRouteIssue(index, name, message)` and every other route, command and recipe still loads.
- `ProgramaRouteDefinition`: `name` (required, unique in the file), `on`, `when`, `debounceMs`, `throttleMs`, `key`, and exactly one action key (`notify`, `send`, `prompt`, `run`, `review`), decoded into a `ProgramaRouteAction` enum. This follows how a command is told apart by `command` versus `workspace` (`ProgramaConfig.swift:98-113`).
- Load-time validation, each failure a route issue: blank or duplicate `name`; an invalid topic pattern (`#` not last, empty level, `surface` class); negative `debounceMs` or `throttleMs`; zero or several action keys; an unknown `whenBusy` value; a `{{field}}` that is not in the field table; a free-text field in `send` or `prompt` text (see Untrusted text); a `prompt` route without `throttleMs`.
- Scope: v1 loads routes from the global file only (open question 1). `ProgramaConfigStore.loadAll` collects the global file's routes and issues, includes them in its change check (`:546-551`), and calls `RouteEngine.shared.install(routes:issues:digest:)`. Every window's store watches the same global file, so `install` ignores a digest it already holds. No new file watcher is added.
- The engine's route source is one tagged value, `.file(digest)` or `.debugOverride`. `debug.routes.load` sets `.debugOverride`, and a file-driven `install` is ignored while it holds; otherwise a new window's store, which runs `loadAll` when it opens (`AppDelegate.swift:3477-3479`), would replace a test's routes mid-run. `debug.routes.load` with `json: null` returns to the file.
- A routes-only file must load, so `commands` becomes optional and defaults to empty. This is an intentional contract change to `testDecodeMissingCommandsKeyThrows` (`ProgramaConfigTests.swift:355`): update the assertion in the same diff and name the change in the PR (open question 5).
- Error reporting: `routes.list` returns each loaded route with its counters and last error, and every issue. When a newly installed digest has issues, the engine posts one notification that names the first issue and the count. `programa routes` prints the same list. The `NSLog` lines stay.

### Engine and threading

- `RouteTap` is a small lock-protected object the broadcaster holds. `wants(_ class:)` reads a set of classes that have at least one compiled route, so a publish with no routes and no subscribers stays as cheap as it is now.
- Each `publish*` builds its frame when `!subs.isEmpty || tap.wants(class)`. `publishAgentState` gains a `previousState` parameter that goes to the tap only. The sidebar-reset call site must capture each surface's state before `panelAgentPresence.removeAll()` (`Workspace+SidebarTelemetry.swift:519-528`); today it keeps only the ids.
- `RouteEngine` is `@MainActor`. The tap always delivers with `DispatchQueue.main.async`, never inline: the three v1 publishers run on the main thread in the middle of a model mutation, and an action must not run inside it. Order is kept because the main queue is FIFO.
- Ingest resolves the added fields, matches the compiled routes, and feeds the reducer. Wakes use `DispatchQueue.main.asyncAfter`.
- `run` and `review` execute on a concurrent utility queue, since both do subprocess I/O and a long `run` must not hold up a `review`. At most 4 `run` processes run at once, app-wide; time spent waiting for a slot counts against the run's timeout, so a run that never gets one times out. `review` takes no slot. `notify`, `send` and `prompt` execute on main.
- `send` and `prompt` wait on their surface's idle report whatever topic fired them, so a route with either action makes the tap build `agent_state` frames. `ingest` matches routes first and then settles the deliveries already held on the event's surface: an idle hands a queued delivery to the executor and ends a prompt's own turn; a clear ends both.
- New code goes in new files. `Sources/TerminalController.swift` is under a line budget (`scripts/check-structural-budgets.py:40`); the two dispatch cases it needs are the only lines added there.

### Actions

- **`notify: { title, subtitle?, body? }`**: `addNotification` for the event's workspace and surface, or an app-level notification when the workspace is closed. All fields may be templated, and an absent field renders empty; the text is display only. `cooldownKey` is not used: the gate is the only throttle. A notification for a `needs_input` call honours `notification.claim_banners` as the built-in one does.
- **Built-in `needs_input` banner:** a question call loses its built-in banner whenever a notify route matches it on topic and `when`, throttled or not, so "once per 5 minutes" is what the person sees. A permission call loses it only when the route fires for that exact call (no debounce or throttle holding it back), so the route's own notification is the one shown; a throttled or debounced route never hides a permission banner. A call with no `kind` follows the question rule. The built-in entry still reaches the list, sidebar and Dock badge.
- **`review: { mode?, baseBranch? }`**: skip when the workspace has a review panel or a route is already opening one there (a claim taken on main before the off-main open and released after it); otherwise `v2ReviewOpen` with the event's ids and `focus: false`. `v2ResolveTabManager` resolves a `workspace_id` in any window through `AppDelegate.tabManagerFor(tabId:)`, so no `window_id` is passed.
- **`run: { command, timeoutMs? }`**: headless, in the event surface's resolved `cwd`, through `CanonicalSubprocessRunner.run` with the user's login shell and `-lc`. The directory is resolved again just before the spawn. A run whose `cwd` does not resolve to an existing absolute directory is refused: `last_error` reads "could not start: the surface's working directory is unknown or does not exist" and the failure notification posts. There is no fallback to the home directory, so a `run` on a `workspace/…` topic, which has no surface `cwd`, is always refused. The command string gets no substitution. Fields arrive as environment variables named `PROGRAMA_ROUTE_<FIELD>` (for example `PROGRAMA_ROUTE_SURFACE_ID`), so no event text is ever parsed by the shell. A non-zero exit or a timeout posts a notification with the output tail and sets the route's last error. Success is silent.
- `surface.report_pwd` rejects a path that is not absolute or has a `.` or `..` component, the lexical half of OSC 7's `validatedReportedDirectory`. It does not check that the directory exists: a shell behind the SSH relay reports a remote path that does not exist on this Mac. The engine-side `realpath` is what keeps such a path out of `when` and `run`.
- **`send: { text, whenBusy? }`** pastes the text and does not submit. **`prompt: { text, whenBusy? }`** pastes and submits through `deliverTextToAgent`, which presses Return only for a known, non-blocked, non-stale agent, so a plain shell never receives a Return. The target is the event's surface.
  - `whenBusy: "queue"` (default): when the surface is `working`, hold one pending delivery per (route, key) and deliver on its next idle report. `"steer"`: deliver now.
  - The engine reads `canAutoSubmitToAgent` in the same hop as the delivery. When it is false nothing is submitted, no turn starts, and the delivery ends at once instead of holding the route as `ownTurn` until expiry.
  - In both modes the engine checks `activePromptHold()` and `activeDraftHold()` in the same main hop as the paste, whatever the two automation settings that relax those checks for socket writes say. A showing approval or sign-in prompt, or a person's unsent typing, refuses the delivery: nothing is sent, the refusal is the route's last error, and the delivery ends. A route never sets `answer_prompt` or `force`.
  - A `prompt` to a surface where `canAutoSubmitToAgent` is false is pasted without Return, its last error reads "pasted without submitting: no agent ready for a prompt", and the delivery ends.
  - `prompt` submits text with no person in the loop, which recipes deliberately never do (`ProgramaConfigExecutor.swift:56-60`). The recipe rule exists because a cloned repo's config is attacker-chosen. A route's text comes only from the global file the user wrote, it carries no free-text event field, and `throttleMs` is mandatory, so the submitted string is the trusted file's own string at a bounded rate.
  - Loop limit: the in-flight rule stops a route from triggering itself. Two routes that prompt on each other's idle edge still alternate, at most once per throttle window each. Mark it with a `SHORTCUT:` comment whose upgrade trigger is the first report of such a loop.

### Untrusted text

v1 has no external sources, and it does not emit a marker. It still needs a rule, because event fields are not all trusted: `title`, `subtitle` and `body` are agent-authored and can carry text the agent read from a web page or an issue.

- Every field has a trust class in code: identifier (`workspace_id`, `surface_id`, `state`, `previous_state`, `source`, `kind`, `worktree`, `ts`) or free text (`title`, `subtitle`, `body`, `provider`, `cwd`, `git_branch`, `program_status.*`). `provider` is free text because the agent's hook chooses it.
- A `when` regex sees at most the first 4096 UTF-16 units of a field.
- One function builds every agent-bound string, for `send` and `prompt`. In v1 it accepts identifier fields only; a free-text placeholder is a load issue. `notify` accepts all fields. `run` accepts none in the command and passes all as environment variables.
- When external sources arrive, that function wraps free text in the marker instead of rejecting it. The marker is not defined here. cc-settings has no convention for one today, and the hook that reads it is the other half of the contract, so the two are designed together in the follow-up. Requirements to carry over: the delimiter holds a per-injection random nonce so content cannot close it; it names the source; and the block is delivered as one bracketed paste so a newline in it cannot submit early.

## Tasks

- [x] **P0: Scaffold (est. 0.25 day, prereq, one writer).** Create empty `Sources/ProgramaRoutes.swift`, `RouteMatching.swift`, `RouteGate.swift`, `RouteEngine.swift`, `RouteActions.swift`, `TerminalController+Routes.swift`, and `programaTests/ProgramaRouteDecodingTests.swift`, `RouteGateTests.swift`, each with its four `project.pbxproj` entries. Add `routes.list` (main thread, with the reason in a comment per the socket threading policy) and `debug.routes.load` (`debug_only: true`) to `contracts/v2/methods.json`, run `python3 scripts/gen-v2-contract.py`, and add the two dispatch cases with stub handlers in `TerminalController+Routes.swift` (`routes.list` returns an empty list, `debug.routes.load` returns `unavailable`) so the build compiles before P3 fills them. Run `python3 scripts/check-structural-budgets.py` before touching `TerminalController.swift`. Done when the tagged build compiles.
- [x] **P1: Decode the routes block (est. 0.5 day).** `ProgramaRouteDefinition`, `ProgramaRouteAction`, `ProgramaRouteIssue`, lossy per-route decoding, load-time validation, optional `commands`, and routes in `loadAll`'s change check. Tests in `ProgramaRouteDecodingTests`: a routes-only file loads; one bad route leaves the others, the commands and the recipes loaded and yields one issue; each validation rule; the digest changes when a route changes. Done when those pass in CI.
- [x] **P2: Topic match, `when`, and the gate reducer (est. 0.75 day).** Pure code, no clock, no AppKit. Tests in `RouteGateTests`: every row of the transition table; `throttleMs: 300000` with matches at 0 s, 60 s and 299 s fires once and a match at 300 s fires again; two keys do not share a window; debounce then throttle; topic patterns with `+` and `#`; each `when` matcher including the absent-key rule.
- [x] **P3: Tap, engine, socket handlers (est. 1 day).** `RouteTap` in the broadcaster, `previousState` at the four `publishAgentState` call sites (`Workspace+SidebarTelemetry.swift:333`, `:361`, `:531`, `Workspace.swift:670`), `RouteEngine` (`install`, `ingest`, `snapshot`), the route source value, field resolution, wake scheduling, `v2RoutesList`, and `v2DebugRoutesLoad`, which runs its JSON text through the P1 parser and installs the result as the debug override. Done when a route loaded through `debug.routes.load` shows a rising `matched` count in `routes.list` after `agent.needs_input` calls.
- [x] **P4: `notify`, `review`, `run` (est. 1 day).** The action executor, the banner rule from open question 2 (under the recommended answer: `hasNotifyRoute(matching:)` and its call at `TerminalController+Telemetry.swift:525`), the failure notification for `run`, and the load-issue notification. Every user-facing string goes in `Resources/Localizable.xcstrings` in English and Japanese. Done when both ticket examples work in a tagged build.
- [x] **P5: `send` and `prompt` with `whenBusy` (est. 0.75 day).** Delivery through `deliverTextToAgent` with both guards, the `waitingForIdle` and `ownTurn` deliveries, expiry, the field trust classes and the single agent-bound text function. Unit tests for the trust rule and for the delivering rows of the table. This task is separable: neither ticket example needs it.
Evidence for P0 to P5: commits `c02173dc` (P0 to P2), `29a05ed5` (P3), `5b262085` (P4) and `64d0212e` (P5, with the P4 security review's M1, M2, L1 and L3 and the permission-banner rule). CI on `5b262085` passed `unit-tests` and `socket-integration-tests`. Both ticket examples, a failing `run`, the four `send`/`prompt` cases and the permission-banner rule were run live on the tagged build `inc-976-event-routes`; agent states were driven with `surface.report_agent_state` on a plain shell, not a real agent CLI.

- [x] **P6: CLI and docs (est. 0.5 day, parallel with P1 and P2).** `programa routes` prints `routes.list`. First find where a new verb registers: `watch-events` is declared in `CLI/Commands/TerminalIOCommands.swift:268` and parsed in `CLI/programa.swift:2364`, and `CLI/programa.swift` is under a line budget (`scripts/check-structural-budgets.py:36`), so keep the new code out of it and run the budget check. Add a `routes` section to `docs/programa-json.md` (schema, topics, fields, `when`, gate semantics, the trust rule), `routes.list` to `docs/socket-api.md`, and a line under "Socket Event Subscriptions" that routes consume the same events. Check `tests/test_cli_registry_behavior.py` for a registry rule on new commands.
- [ ] **P7: Socket E2E (est. 0.5 day).** `tests_v2/test_event_routes.py`, listed in `tests_v2/ci_subset.txt`; a file in no list runs nowhere (`docs/testing-layout.md:54`). See Testing.
- [ ] **P8: Verify.** `./scripts/reload.sh --tag inc-976-event-routes` compiles. CI is green on `unit-tests`, `socket-integration-tests`, `scripts/check-v2-contract.sh` and `python3 scripts/check-structural-budgets.py`. Record the run links here.

## Testing

Tests run in CI only (`CLAUDE.md:215`).

- **`programaTests/`** holds everything that can be reached without a socket, per `docs/testing-layout.md:33-37`: decoding and validation, topic and `when` matching, and the gate reducer. The reducer test with a 300000 ms window and injected times is the proof of "once per 5 minutes".
- **`tests_v2/test_event_routes.py`** proves the wiring with a short window, following `tests_v2/test_notification_claim_banners.py`:
  1. `client.set_app_focus(False)` and `debug.notification.banner_reset`, so focused-panel suppression never hides a banner (`test_notification_claim_banners.py:77-78`).
  2. `debug.routes.load` with one route: `on: "agent/+/needs_input/question"`, `throttleMs: 3000`, a `notify` action. This seam is needed because the test must not write the user's global `programa.json` and cannot wait five minutes.
  3. Three `agent.needs_input` calls with `kind: "question"` on one surface. `needs_input` publishes on every call, so no state transitions are needed.
  4. Wait until `routes.list` shows `matched == 3`, then assert `fired == 1` and `throttled == 2`.
  5. One call on a second surface: `fired == 2`, which proves the per-surface key.
  6. Sleep past the window, one more call on the first surface: `fired == 3`.
  7. One call with `kind: "permission"` on the first surface: the route's `matched` count does not move, and the banner count rises by one. A route for questions must never silence a permission prompt.
  8. Banner arithmetic through `debug.notification.banner_count` (`contracts/v2/methods.json:938`), read after each step: under the recommended answer to open question 2 the count ends at `fired + 1` (three route banners and the permission banner); under the other answer it ends at the number of calls plus `fired`.
  9. `debug.routes.load` with `json: null` at the end, so the next test starts from the file.
- A second case drives real transitions with `surface.report_agent_state` (`working`, then `idle`) and asserts that a route on `agent/+/state/idle` with `"previous_state": { "in": ["working", "blocked"] }` fires once, and does not fire for the `idle` that starts a session.
- Not exercised end to end: a `run` command's process environment on a CI runner beyond exit status, and `prompt` delivery into a real agent CLI. State that in the PR.

## Risks

- **A route runs with no person present.** Mitigations: global-file scope, no free-text fields in agent-bound text or shell strings, both write guards on every delivery, mandatory `throttleMs` on `prompt`.
- **Main-thread cost.** Ingest runs on main for every agent-state transition. It is bounded by the number of routes, and the tap is skipped when no route wants the class. Do not add work to the publish call itself.
- **Line budgets** on `Sources/TerminalController.swift` and `CLI/programa.swift`: free lines first if the two dispatch cases do not fit, and keep the CLI verb out of `programa.swift`.
- **Mandatory `throttleMs` on `prompt`** is a restriction the ticket does not ask for. It bounds token spend when routes loop; drop the rule if it gets in the way.
- **Contract change** to `commands` being required: one existing assertion changes on purpose.
- **Pine parity** is unverified; see Intent and continuity.

## Open questions

Decided 2026-11-12: questions 1 to 4 take the recommended answer (global file only; a matching notify route replaces the built-in banner; `run` is headless; a worktree agent is a workspace from `worktree.create` or `worktree.open`). Questions 5 to 8 keep their defaults.

Questions 1 to 4 block P3 and P4. Questions 5 to 8 have a default this plan follows unless told otherwise.

1. **Which file may define routes?** Recommended: the global `~/.config/programa/programa.json` only in v1. Project-level routes need a way to resolve the config for the event's surface and a new review-and-trust dialog, because the existing gate is a modal a route cannot show and a routes-only file has no entry that would ever show it. The cost of global-only: a per-project test command needs a `cwd` regex in `when`, and routes are not shared through git.
2. **Does a route's `notify` on `needs_input` replace the built-in banner or add to it?** Decided: replace it for the calls a `notify` route matches, and only those; for a permission call, only when the route fires for that exact call (see "Built-in `needs_input` banner" under Actions). `v2AgentNeedsInput` decides the banner at `TerminalController+Telemetry.swift:525`, before the engine's async ingest runs, so P4 adds a synchronous main-actor query there, `RouteEngine.shared.hasNotifyRoute(matching:)`, which builds the event the tap would build and checks topic and `when`. On a match the built-in entry still goes to the list, sidebar and Dock badge without its banner, and the route's throttled notification is the only banner. A permission prompt, or a surface the route's `when` excludes, keeps its built-in banner. The existing claim cannot express this: `NotificationBannerClaims` has one kind for all `needs_input` calls and takes a `SocketConnection` (`Subscriptions.swift:36-61`). Without a replace rule, the built-in banner still fires on every call and a five-minute throttle changes nothing the user sees.
3. **Where does a `run` command run?** Recommended: headless in the event surface's directory, with a notification on failure. The alternative is a visible terminal split per route, which needs pane reuse and pane-cap handling.
4. **What is a "worktree agent"?** Recommended: a surface whose workspace was created or opened by `worktree.create` or `worktree.open` (`worktreeBranch` set). Alternatives: any linked git worktree, which needs a git probe per event, or a helper started by `agent.spawn` (`agentParentWorkspaceId`).
5. **May `commands` become optional** so a routes-only file loads? Default: yes, with the assertion at `ProgramaConfigTests.swift:355` updated in the same diff.
6. **One action per route?** Default: yes, as the ticket words it; the second example is two routes with the same trigger. An ordered `actions` list is additive later and needs a rule for waiting on `run`.
7. **Free-text fields in `send` and `prompt`:** default is to reject them in v1 and agree the marker with the cc-settings hook before any external source ships.
8. **`output` topics:** default is to leave them out of v1.

## Follow-up scope

- Project-level routes behind a review-and-trust dialog.
- External route inputs (folder, webhook) with the untrusted marker and its cc-settings hook.
- `output` topics with an explicit surface selector.
- `previous_state` on the wire `agent_state` frame, for scripts that still use `watch-events`.

Pine's model-call and state-setting route features stay out of scope.

## ADR: the route engine taps the socket event broadcaster

**Status:** Proposed.

**Context.** Routes need the same events socket subscribers get, for every surface, inside the app. `SocketEventBroadcaster` builds frames only when a socket client subscribes, so nothing in the app can observe them today.

**Options considered.**
1. A tap inside `SocketEventBroadcaster`, fed the frame each `publish*` already builds.
2. Hooks at the eight model call sites that publish, with a typed event per site.
3. The engine as a loopback socket client of `subscribe`.

**Decision.** Option 1. A route matches the keys `programa watch-events` prints, the publish side changes in one file, and the engine's surface stays at four functions. Option 2 creates a second event schema that can drift from the wire. Option 3 pays for JSON encoding, socket auth and the drop-oldest queue to move data within one process.

**Consequences.** The broadcaster gains an in-process consumer, so its "cheap when nobody subscribes" property now depends on `RouteTap.wants`. Fields the frame lacks (`previous_state`, `cwd`, `git_branch`, `worktree`) are added inside the app and do not exist on the wire, so the docs must list route fields separately from frame keys. `output` routes need a poll owner before they can exist.

Delegation: `implementer` for P0 to P6, `tester` for `tests_v2/test_event_routes.py`, and `security-reviewer` on P1 (validation), P4 (`run`) and P5 (text delivery) before merge.

Plan complete. Delegate to implementer for execution.
