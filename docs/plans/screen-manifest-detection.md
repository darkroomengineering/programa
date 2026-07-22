# Screen-manifest agent detection — implementation plan

Status: planning only, nothing implemented yet.
Scope: infer agent activity state (`working`/`blocked`/`idle`) for terminal agents that
don't have lifecycle hooks installed, by pattern-matching the visible screen buffer
against per-agent declarative manifests (herdr.dev tier-2 model). Feeds the same
`AgentActivityState` pipeline hooks already use, tagged with a `source` so hook reports
always win.

## 0. Codebase findings this plan is built on

- **`Sources/AgentActivityState.swift`** — `AgentActivityState` is `working | blocked |
  idle` (3 cases only), with a `severity` ordering (`blocked > working > idle`) used for
  worst-of aggregation across a workspace's surfaces (`Workspace.aggregateAgentState`).
  The file's own header comment says this is explicitly "v1 hook-tier scope only... no
  screen-rule fallback (v2, tracked separately)" — this plan is that v2.
- **State storage**: `Workspace.panelAgentStates: [UUID: AgentActivityState]`
  (`Sources/Workspace.swift:111`), mutated exclusively through
  `Workspace.updatePanelAgentState`/`clearPanelAgentState`
  (`Sources/Workspace+SidebarTelemetry.swift:163-182`), which are only ever called from
  `TabManager.updateSurfaceAgentState`/`clearSurfaceAgentState`
  (`Sources/TabManager.swift:1846-1861`), which are only ever called from
  `TerminalController.v2SurfaceReportAgentState`/`v2SurfaceClearAgentState`
  (`Sources/TerminalController+Telemetry.swift:286-329`), which is what
  `CLI/CLI+Hooks.swift`'s `reportAgentState`/`clearAgentState` call over the socket
  (`surface.report_agent_state` / `surface.clear_agent_state`). This is a single funnel —
  good, means one choke point to add a `source` tag at.
- **Wire exposure of `agent_state`**: `surface.list` includes it per-surface as a bare
  string or `null` (`Sources/TerminalController+Surface.swift:48`:
  `"agent_state": v2OrNull(ws.panelAgentStates[panel.id]?.rawValue)`). `surface.wait`'s
  `agent_state` condition and `subscribe`'s `agent_state` event both read off the exact
  same `panelAgentStates` dict (`Sources/TerminalController+SurfaceWait.swift`,
  `Sources/TerminalController+Subscriptions.swift`) via one main-thread mutation point.
  A confirmed-backward-compatible existing test
  (`tests_v2/test_agent_activity_state_socket.py`) asserts `surface.get("agent_state")`
  by exact string equality and that an unrecognized state value is **rejected** — so the
  wire enum of 3 states is load-bearing and should not be casually widened to 4.
- **Native screen-text accessor** (the thing to reuse, per the task's ask): every
  existing "read what's on screen" path funnels through
  `TerminalController.readTerminalTextBase64(terminalPanel:includeScrollback:lineLimit:)`
  (`Sources/TerminalController.swift:2339`), which itself calls
  `ghostty_surface_read_text` (line 2362) — this is the same primitive backing
  `surface.read_text`, `debug.terminal.read_text`, tmux-compat `capture-pane`, and
  `surface.wait`'s `pattern` condition (`v2SurfaceWaitReadText`,
  `TerminalController+SurfaceWait.swift:472`). **Reuse this function directly** — do not
  build a second text-capture path.
- **Existing background-poll precedent** (the pattern to copy for sampling):
  `TerminalController.v2StartOutputPollLoopIfNeeded`
  (`Sources/TerminalController+Subscriptions.swift:387-415`) already does exactly the
  shape this feature needs: a single `Thread.detachNewThread` background loop, sleeping
  at a fixed interval (100ms there), that for each *candidate* surface (there: surfaces
  with an active `output` subscription) does a `v2MainSync` hop to fetch text via
  `v2SurfaceWaitReadText`, then does its work (there: diff+publish) back on the
  background thread. This is the template for the new detection engine's sampling loop,
  just at a slower cadence (500ms–1s) and scoped to a much smaller candidate set
  (recognized-agent surfaces only, not "everything subscribed").
- **Event-driven, already-coalesced title updates**: `GhosttyTitleUpdateDispatcher`
  (`Sources/GhosttyTitleUpdateDispatcher.swift`) coalesces `GHOSTTY_ACTION_SET_TITLE`
  callbacks to at most one post per surface per 50ms, specifically because uncoalesced
  title churn from spinner-heavy CLIs was adding input latency. Two implications: (a)
  this confirms some agent CLIs *do* repaint the title on every frame, so title-string
  recognition is plausible for at least some agents; (b) it's proof the team already
  paid down one instance of exactly the perf tax this feature must not reintroduce —
  follow the same "coalesce, never post on every raw event" discipline.
- **Settings pattern**: `Sources/SettingsModels.swift:138` —
  `enum ClaudeCodeIntegrationSettings { static let hooksEnabledKey = "..."; static let
  defaultHooksEnabled = true; ... }`, consumed in `SettingsView.swift` via
  `@AppStorage(ClaudeCodeIntegrationSettings.hooksEnabledKey)`. New setting follows this
  exact shape.
- **Threading policy** (from root `CLAUDE.md`, "Socket command threading policy"):
  telemetry hot paths must parse/dedupe off-main, mutate main only via
  `DispatchQueue.main.async`, and never `DispatchQueue.main.sync` from a
  high-frequency path. The output-poll precedent above technically does a `v2MainSync`
  hop, but that hop is *from a dedicated background thread*, not from the calling
  socket/telemetry thread, and it does the absolute minimum (one text read) before
  returning — this plan follows that same shape exactly, and keeps regex/classification
  fully off that hop.
- **Test precedent**: `tests_v2/test_agent_activity_state_socket.py` (wire contract),
  `tests_v2/test_agent_state_wait_and_prompt.py` (`surface.wait`/`agent.prompt`),
  `tests_v2/test_socket_event_subscriptions.py` (`subscribe`), and unit-level
  `programaTests/AgentActivityStateTests.swift` (pure Swift, no app launch) are the
  direct structural templates for this feature's tests.

## 1. Architecture decisions

### 1.1 Manifest format: JSON, not TOML

No TOML parser exists anywhere in the codebase (`Package.swift`/pbxproj have no TOML
dependency), while `JSONSerialization`/`Codable` are used pervasively (all of
`CLI+Hooks.swift`'s hook parsing, socket params). Shipping JSON avoids adding a
dependency for a bundled-resource format. herdr.dev's use of TOML is noted but not a
constraint here — the task explicitly allows picking whichever is easiest given existing
parsing support.

### 1.2 Wire states stay at 3 (`working`/`blocked`/`idle`) — manifest "done" collapses to `idle`

The task asks for manifests to classify into `working | blocked | idle | done`. Two
options were considered:

- **(A) Add a 4th case to `AgentActivityState`.** Rejected for v1: it ripples through
  `severity` ordering, the CLI's mirror enum `CLIAgentActivityState` in `CLI+Hooks.swift`
  (comment explicitly says it "mirrors `AgentActivityState`... by raw value only"), every
  `switch` over the 3 known values (sidebar badge rendering, `AppDelegate.swift:5829`'s
  blocked-check, notification logic), `surface.wait`'s documented `agent_state` condition
  values, and the existing wire-contract test that treats the 3-value set as exhaustive
  ("reject an unrecognized state value"). None of these breaks silently, but all of them
  need a coordinated audit — large blast radius for what "done" actually buys.
  Hook-reported state today has no `done` either: a Claude Code `Stop` hook already
  reports plain `.idle`. Adding `done` to inferred-only surfaces would make the two
  detection tiers report structurally different vocabularies for what a hook would call
  the same thing.
- **(B) Manifests keep an internal `done` bucket (useful for pattern-authoring clarity —
  "the agent just finished, as opposed to sitting at a fresh prompt with no history"),
  but the detection engine reports it to the shared pipeline as `.idle`.** Chosen. Zero
  wire changes, zero risk to the existing rejection test, matches hook behavior exactly
  (hooks don't distinguish "just finished" from "idle" either), and is a one-line mapping
  in the engine (`AgentActivityState(fromManifestBucket: .done) == .idle`). If a future
  need for a distinct "just completed" badge emerges, it's a separate, deliberate
  proposal — not smuggled in here.

### 1.3 Source tagging: additive sibling field, not a nested change

`agent_state` stays a bare string (or `null`) on `surface.list`/`surface.wait`/`subscribe`
so the existing exact-string-equality test keeps passing untouched. A new sibling field
`agent_state_source` (`"hooks" | "inferred"`, `null` when `agent_state` itself is `null`)
is added next to it everywhere `agent_state` appears. This is the standard additive-field
pattern already used throughout the v2 API (see `docs/v2-api-migration.md`'s discipline
of never repurposing an existing field shape).

### 1.4 Hooks-always-win: source-tagged storage, not last-write-wins

`Workspace` gains a parallel dict:

```swift
@Published var panelAgentStateSources: [UUID: AgentStateSource] = [:]
```

`AgentStateSource` (new enum, lives in `AgentActivityState.swift` next to the existing
enum):

```swift
enum AgentStateSource: String, Codable, CaseIterable, Sendable {
    case hooks
    case inferred
}
```

`Workspace.updatePanelAgentState(panelId:state:source:)` gets a `source` parameter
(default `.hooks`, so every existing call site — CLI hooks — compiles unchanged and
behaves identically). Precedence rule enforced inside this one function:

- Incoming `source == .hooks` → always write; state and source both update
  unconditionally. Hooks are authoritative the instant they speak.
- Incoming `source == .inferred` → write only if the surface's *current* recorded
  source is `nil` (no report yet) or already `.inferred`. If the current source is
  `.hooks`, the inferred write is silently dropped — the surface already has an
  authoritative hook-reported state and the screen-manifest engine should not even be
  sampling it (see 2.1, Phase A demotion), but this is a belt-and-suspenders guard at the
  storage layer regardless of what the engine does.

v1 does **not** implement a staleness TTL that would let inferred detection take back
over if a hook goes silent mid-session without an explicit `clear_agent_state` (e.g. the
hook process crashes before `SessionEnd` fires). This is called out explicitly in
Risks (§5) as a known v1 limitation with a concrete follow-up shape, not something silently
missing.

### 1.5 Detection engine: two-phase, event/candidate-scoped, never a whole-surface-set poll

**Phase A — recognition (cheap, rare).** A surface becomes a "candidate" for sampling
when a manifest's `recognize` block matches. Recognition is checked, at most, once per
new foreground command on a surface — reusing whatever existing shell-integration
telemetry call already fires when the shell reports a new foreground process (the same
family as `surface.report_shell_state`/`report_pwd`/`report_tty` in
`TerminalController+Telemetry.swift`). **Verify during implementation** whether that
payload carries the resolved command/argv0 string; if it does, recognition is a plain
string/glob match against `recognize.process_names` with zero added polling. If it
doesn't carry a usable command name, fall back to a **one-shot** screen check
(`recognize.screen_patterns`) run once when a surface is newly created/first focused —
still not a continuous poll, just a single check at a natural lifecycle boundary.
A surface already carrying a `.hooks`-sourced state is skipped by Phase A entirely (no
point recognizing/sampling a surface hooks already own).

**Phase B — classification sampling.** Once a surface is a candidate, it's added to the
engine's own small candidate set (typically low single digits — number of concurrently
open un-hooked agent surfaces). A single dedicated background thread (same
`Thread.detachNewThread` shape as `v2StartOutputPollLoopIfNeeded`) wakes every 500ms–1s
and, only for surfaces in the candidate set:

1. `v2MainSync` hop to read text via the existing `readTerminalTextBase64`/
   `v2SurfaceWaitReadText` accessor, bounded to a small tail (e.g. last 60 lines — enough
   for any spinner/prompt UI, far short of full scrollback). This hop does nothing but
   copy a string; no regex, no state mutation, happens on main.
2. Back on the background thread: skip entirely if the text is byte-identical to the
   last sample for that surface (cheap equality check before any regex work).
3. If changed, run the surface's manifest's state-rules through `NSRegularExpression`
   **on this background thread**, in priority order (`blocked` checked first,
   unconditionally — see hysteresis below), first match wins.
4. Resolve via hysteresis (§1.6), and only on an actual resulting state *change*, hop to
   main via `DispatchQueue.main.async` to call
   `TabManager.updateSurfaceAgentState(..., source: .inferred)`.

A candidate is demoted out of the sampling set (back to Phase A/idle) when: the surface
closes, a new foreground command no longer matches the manifest's `recognize` block, or
the surface's text stops matching *any* state pattern for a grace period (e.g. 30s) —
guards against indefinitely sampling a surface where the agent process exited and a
plain shell prompt is left, which generally won't match anything but shouldn't be
sampled forever regardless.

The global setting (§4) is checked once at the top of both phases — disabled means the
engine never even builds a candidate set, i.e. true zero-cost when off.

### 1.6 Hysteresis (anti-flapping)

- **`blocked`**: apply immediately on first match, no dwell. A permission/approval
  prompt is a discrete UI event (a box appears), not a per-frame-varying spinner —
  there's no flapping risk to guard against, and delaying a blocked badge by an extra
  sample is worse than a false positive here (mirrors the existing hook-tier philosophy
  of treating blocked as the one state worth being responsive about, just applied in the
  opposite direction: hooks are conservative about *asserting* blocked, this engine is
  conservative about *delaying* it once a manifest's unambiguous blocked pattern hits).
- **`working` / `idle` / `done`**: require 2 consecutive samples classifying to the same
  bucket before flipping the reported state. At a 500ms–1s cadence this is roughly a
  1–2s dwell — enough to ride out a single spinner-frame's glyph change (e.g. "✻" →
  "✢" between ticks) without a multi-second lag on real transitions.

## 2. Manifest file format spec

### 2.1 Location and precedence

- Bundled (shipped with the app): `Resources/AgentDetection/<agent>.json`, copied into
  the app bundle as a resource folder reference.
- User override: `~/.config/programa/agent-detection/<agent>.json`. If present, it
  **fully replaces** the bundled manifest for that `<agent>` key (no field-level merge —
  simpler mental model, matches "user override" semantics used elsewhere in the config
  system). Loader logs which manifests came from where (useful for `programa doctor`-
  style debugging, if that exists — verify).

### 2.2 Schema (v1)

```json
{
  "version": 1,
  "agent": "claude-code",
  "display_name": "Claude Code",
  "recognize": {
    "process_names": ["claude"],
    "screen_patterns": ["Claude Code v\\d"]
  },
  "states": [
    {
      "bucket": "blocked",
      "priority": 100,
      "anchor_last_n_lines": 12,
      "patterns": [
        "Do you want to .*\\?",
        "❯\\s*1\\.\\s*Yes",
        "\\(y/n\\)"
      ],
      "confidence": "verified",
      "source_notes": "Permission/approval prompt box. Given directly in the feature spec; re-verify wording each Claude Code minor version."
    },
    {
      "bucket": "working",
      "priority": 50,
      "anchor_last_n_lines": 6,
      "patterns": [
        "✻ Thinking…",
        "esc to interrupt",
        "⏺ "
      ],
      "confidence": "verified",
      "source_notes": "Claude Code rotates whimsical verbs (Thinking/Pondering/Crunching/Cerebrating…) before the ellipsis — pattern intentionally matches the fixed '✻ ' + ellipsis shape and the 'esc to interrupt' suffix rather than enumerating every verb, so new verbs don't require a manifest update. '⏺ ' prefixes tool-call result lines."
    },
    {
      "bucket": "done",
      "priority": 10,
      "anchor_last_n_lines": 4,
      "patterns": [
        "✗ Auto-update failed"
      ],
      "confidence": "needs_verification",
      "source_notes": "Auto-update-failed banner sometimes shown near the idle prompt box; only useful as a done/idle-adjacent signal, not a reliable done marker on its own. Verify against a current build."
    },
    {
      "bucket": "idle",
      "priority": 0,
      "anchor_last_n_lines": 4,
      "patterns": [
        "\\n❯\\s*$"
      ],
      "confidence": "verified",
      "source_notes": "Bottom input prompt caret. Verify no leading/trailing box-drawing characters get included by the text accessor at narrow terminal widths."
    }
  ]
}
```

Field notes:
- `patterns` are `NSRegularExpression` (ICU) syntax, matched against the last
  `anchor_last_n_lines` lines of the sampled tail (not the whole 60-line sample) — keeps
  matching cheap and reduces false positives from scrollback-adjacent text.
- `priority` determines check order within one sample (highest first); first matching
  bucket wins for that sample.
- `confidence` / `source_notes` are the "mark uncertain ones" mechanism — greppable,
  contributor-facing, and a natural place to note which Claude Code / Codex / Gemini
  release the pattern was last verified against.
- Authoring guidance (goes in the contributor doc, §2.3): prefer fragments over
  full-line anchors — box-drawing borders and prompt text commonly wrap at narrow
  terminal widths, so `"Do you want to .*\\?"` is more robust than trying to match an
  entire boxed line including its `│`/`╭`/`╰` borders.

### 2.3 Contributor documentation

Extract this schema section (2.1–2.2) into `docs/agent-detection-manifests.md` during
implementation, so contributors adding a manifest for e.g. Aider or Cursor Agent don't
need to read this planning doc. Cross-link from `docs/v2-api-migration.md`'s agent_state
section.

### 2.4 Bundled manifests for v1

| Agent | Depth | Notes |
|---|---|---|
| Claude Code | Solid | Worked example above; spinner/permission/idle-prompt UI is well-documented and given directly in the feature spec. |
| Codex | Solid | Has its own well-known spinner + approval-prompt UI (mirrors `classifyCodexNotification` already in `CLI+Hooks.swift` — read that classifier's string matches for a head start on wording, though it classifies hook JSON payloads, not screen text, so patterns still need independent verification against actual rendered output). |
< /br>| Gemini CLI | Solid | Spinner/prompt UI is stable and public; verify current exact strings against a real session before shipping. |
| OpenCode | Stub | Ships a manifest as a hooks-fallback even though it's already hook-integrated (task requirement) — best-effort only. |
| GitHub Copilot CLI | Stub | Best-effort; UI likely to drift, mark `needs_verification` throughout. |
| Cursor Agent | Stub | Same. |
| Aider | Stub | Same; Aider's simpler prompt style may actually be easier to pattern-match than the TUI-heavy tools — worth a closer pass in a follow-up. |

## 3. Files to create / modify (dependency-ordered)

### Phase 0 — source-tagging plumbing (independently shippable, no behavior change)

1. **Modify** `Sources/AgentActivityState.swift` — add `AgentStateSource` enum (§1.4).
2. **Modify** `Sources/Workspace.swift` — add `@Published var panelAgentStateSources:
   [UUID: AgentStateSource] = [:]` next to `panelAgentStates`.
3. **Modify** `Sources/Workspace+SidebarTelemetry.swift` — `updatePanelAgentState`/
   `clearPanelAgentState` gain the `source` parameter and hooks-win precedence logic
   (§1.4); also clear `panelAgentStateSources` entries wherever `panelAgentStates`
   entries are pruned (line ~322's `validSurfaceIds` filter — mirror it).
4. **Modify** `Sources/TabManager.swift` — `updateSurfaceAgentState`/
   `clearSurfaceAgentState` thread the `source` parameter through (default `.hooks`).
5. **Modify** `Sources/TerminalController+Telemetry.swift` — `v2SurfaceReportAgentState`
   accepts an optional `source` param (defaults `.hooks` so `CLI+Hooks.swift`'s existing
   calls are untouched); response payload gains `"source"`.
6. **Modify** `Sources/TerminalController+Surface.swift` — `surface.list`'s per-surface
   dict gains `"agent_state_source": v2OrNull(...)` next to `"agent_state"`.
7. **Modify** `Sources/TerminalController+SurfaceWait.swift` — `agent_state` wait result
   gains a sibling `"source"` field.
8. **Modify** `Sources/TerminalController+Subscriptions.swift` — `agent_state` event
   frame gains a sibling `"source"` field.
9. **Modify** `docs/v2-api-migration.md` — document the new field under both the
   `surface.wait` and `Socket Event Subscriptions` sections.
10. **New test**: extend `tests_v2/test_agent_activity_state_socket.py` (or a small new
    file) asserting `agent_state_source == "hooks"` after a `surface.report_agent_state`
    call, and that the existing exact-string assertions on `agent_state` are unaffected.

Effort: ~2–3 hours. No dependency on anything else in this plan — can ship and merge
standalone.

### Phase 1 — manifest infrastructure (depends on Phase 0's `AgentStateSource` existing)

11. **New** `Sources/AgentManifest.swift` — `Codable` models: `AgentManifest`,
    `AgentManifestRecognizer` (`process_names`, `screen_patterns`), `AgentManifestState`
    (`bucket`, `priority`, `anchor_last_n_lines`, `patterns`, `confidence`,
    `source_notes`). Include a pure function
    `classify(text: String) -> (bucket: String, matchedPattern: String)?` so it's
    unit-testable with no engine/threading involved.
12. **New** `Sources/AgentManifestLoader.swift` — loads bundled manifests from
    `Bundle.main` resource path `AgentDetection/`, then overlays
    `~/.config/programa/agent-detection/*.json` by `agent` key. Exposes
    `AgentManifestLoader.shared.manifest(forProcessName:) -> AgentManifest?` and
    `manifest(forAgent:) -> AgentManifest?`.
13. **New resource files**: `Resources/AgentDetection/claude-code.json`,
    `codex.json`, `gemini-cli.json`, `opencode.json`, `copilot-cli.json`,
    `cursor-agent.json`, `aider.json`.
14. **Modify** `GhosttyTabs.xcodeproj/project.pbxproj` — register the two new Swift
    files (PBXBuildFile/PBXFileReference/target membership) and add
    `Resources/AgentDetection` as a folder reference in the Copy Bundle Resources build
    phase. **Check this carefully** — CLAUDE.md flags pbxproj registration as an easy
    thing to miss; verify with a clean `xcodebuild` that the JSON files land in
    `<app>.app/Contents/Resources/AgentDetection/`.
15. **New** `programaTests/AgentManifestTests.swift` — pure unit tests: decode each
    bundled manifest, feed known sample strings (the exact worked-example strings from
    §2.2) through `classify(text:)`, assert expected bucket. No app launch, no socket —
    fast CI signal, can be written and run before the engine (item 16) exists at all.

Effort: ~1 day (bulk of it is writing/verifying the Claude Code / Codex / Gemini
manifests against real sessions).

### Phase 2 — detection engine (depends on Phase 0 + Phase 1)

16. **New** `Sources/AgentScreenDetectionEngine.swift` — singleton
    `AgentScreenDetectionEngine.shared`:
    - `noteForegroundCommand(workspaceId:surfaceId:command:)` — Phase A entry point,
      called off-main from the existing shell-integration telemetry handler (item 17).
      Bails immediately if the setting is off or the surface already has a `.hooks`
      source.
    - Internal candidate set (`Set<UUID>` guarded by a lock, mirroring
      `SocketEventBroadcaster`'s `watchedOutputSurfaceIds()` pattern).
    - `startSamplingLoopIfNeeded()` — lazily starts one `Thread.detachNewThread` loop
      (copy `v2StartOutputPollLoopIfNeeded`'s shape), sleeping 500ms–1s, iterating only
      the candidate set, doing the `v2MainSync` read → background regex → hysteresis →
      `DispatchQueue.main.async` mutate sequence from §1.5.
    - Per-surface state: last-sampled text (for the identical-text skip), last N
      classifications (for hysteresis), demotion timer.
17. **Modify** the existing shell-integration telemetry handler (likely in
    `TerminalController+Telemetry.swift`, near `v2SurfaceReportTTY`/whatever handles
    `report_shell_state`) — **research task**: confirm which handler fires on a new
    foreground command and whether its payload carries a usable command/argv0 string;
    call `AgentScreenDetectionEngine.shared.noteForegroundCommand(...)` from there,
    off-main, guarded by the settings check. If no such payload exists, fall back to the
    one-shot-on-focus/create recognition path described in §1.5 instead of modifying
    this handler.
18. **Modify** `Sources/SettingsModels.swift` — add:
    ```swift
    enum AgentScreenDetectionSettings {
        static let enabledKey = "agentScreenDetectionEnabled"
        static let defaultEnabled = true
    }
    ```
19. **Modify** `Sources/SettingsView.swift` — add a `Toggle` bound to
    `@AppStorage(AgentScreenDetectionSettings.enabledKey)`, near the existing Claude Code
    integration toggle, with a short localized description ("Infer agent status from
    terminal screen content for tools without an installed integration").
20. **Modify** `Resources/Localizable.xcstrings` — add the new toggle's label/description
    strings, English + Japanese, per the repo's mandatory localization rule.

Effort: ~1–1.5 days, contingent on the Phase A trigger research in item 17 (could be a
couple hours if `report_shell_state` already carries a command name, half a day+ if the
fallback one-shot path is needed instead).

### Phase 3 — verification

21. Build: `xcodebuild -project GhosttyTabs.xcodeproj -scheme programa -configuration
    Debug -destination 'platform=macOS' -derivedDataPath
    /tmp/programa-screen-manifest build`.
22. **New** `tests_v2/test_agent_screen_manifest_detection.py` — drives a small fake
    "agent" shell script (heredoc'd into the test or a small fixture file) that prints
    known Claude Code manifest strings in sequence with sleeps (idle prompt → working
    spinner lines on a timer → permission-prompt box → back to idle), and asserts via
    `subscribe`/`surface.wait agent_state` that the surface transitions
    `idle → working → blocked → idle` with `agent_state_source == "inferred"` throughout,
    within reasonable timeouts (accounting for the 500ms–1s sample cadence + hysteresis
    dwell). Must run against a **tagged** build's socket per the repo's testing policy
    (`PROGRAMA_SOCKET=/tmp/programa-debug-<tag>.sock`), never an untagged instance.
23. Manual smoke test: `./scripts/reload.sh --tag screen-manifest`, open a real Claude
    Code session in a surface, confirm the sidebar badge reflects inferred state with the
    setting on, confirm it goes fully silent with the setting off, confirm a
    hooks-installed Claude Code session's badge is unaffected (still hook-sourced) even
    with screen detection also enabled.

## 4. Risks / unknowns

1. **Phase A trigger uncertainty (highest risk, blocks item 17's estimate)** — unverified
   whether existing shell-integration telemetry carries a foreground command name.
   Resolve first, before committing to Phase 2's schedule.
2. **Pattern brittleness across CLI versions** — Claude Code/Codex/Gemini update
   spinner/prompt wording across releases; manifests will go stale. Mitigated by
   user-overridable manifests (§2.1) and `confidence`/`source_notes` fields, but this is
   an ongoing maintenance cost, not a one-time build.
3. **ANSI/unicode handling** — not expected to be a real problem: `ghostty_surface_
   read_text` already backs `surface.wait`'s `pattern` condition today, which does the
   same style of regex-over-rendered-text matching in production. Verify narrow-terminal
   line-wrapping doesn't split a pattern's fragment across two lines in practice for the
   solid-tier manifests (Claude Code, Codex, Gemini).
4. **Hooks-silently-die edge case** (§1.4) — no TTL fallback in v1; a surface whose hook
   process crashed mid-session without emitting `SessionEnd` stays on stale hook state
   forever, screen detection never takes back over. Documented, not fixed, in v1. Follow-
   up: a TTL (e.g. no hook activity for 90s + no live PID in `tab.agentPIDs`) that
   demotes a surface's recorded source back to eligible-for-inferred.
5. **Perf regression risk is mostly about scope creep, not the sampling primitive
   itself** — the sampling primitive (background thread + `v2MainSync` text read) is a
   direct copy of the already-shipped, already-perf-reviewed output-poll loop. The actual
   risk is the candidate set silently growing to "every open surface" if Phase A
   recognition is too permissive (e.g. falls back to matching plain shell prompts). Keep
   `recognize` patterns conservative and specific per manifest.

## 5. Delegation

- **Phase 0** (items 1–10): straightforward, single-funnel plumbing change across ~8
  files with a clear existing pattern to extend. Good `implementer` task — one briefing,
  should be a single sitting.
- **Phase 1** (items 11–15): manifest schema + loader is implementer work; the actual
  Claude Code / Codex / Gemini pattern research (verifying real current UI strings) is
  better done interactively/with web research than blind-authored, since it's
  fact-finding about external tools' current behavior, not code-shape work — consider a
  short `explore`/research pass before handing the JSON files to an implementer.
- **Phase 2** (items 16–20): the engine is the most novel piece (new threading model,
  new hysteresis logic) — implementer work, but flag item 17's research sub-task as an
  explicit STOP-and-report checkpoint if the shell-integration payload doesn't carry a
  command name, since that changes the design (candidate recognition path) rather than
  just the effort estimate.
- **Phase 3**: `tester` for the new `tests_v2` file (new test files are a MUST-delegate
  category per this repo's routing table).
- Given this touches 4+ files across telemetry/socket/settings/detection layers and
  introduces a new architectural pattern (screen-manifest inference tier), this qualifies
  for **security-reviewer is not needed** (no auth/payments/crypto surface) but a normal
  code review pass on Phase 2's threading is warranted given the typing-latency
  sensitivity called out in root `CLAUDE.md`.

Plan complete. Delegate to implementer for execution.
