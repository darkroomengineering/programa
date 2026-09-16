# Agent events: normalized lifecycle schema

## Where we actually are (read this before assuming greenfield)

Programa already ships a two-tier agent-state system (issue #164,
`docs/plans/screen-manifest-detection.md`):

- **Hook tier** — Claude Code, Codex, and OpenCode each get an installer
  (`CLI/CLI+Hooks.swift`: `runClaudeInstallIntegration`, Codex's
  `codexRewriteHooks`, `runOpenCodeInstallIntegration`) that wires provider
  hooks to `programa claude-hook|codex-hook|opencode-hook <event>`
  (`CLI/CLI+HookCommands.swift`, dispatched in `CLI/programa.swift`). Each
  hook handler (`runClaudeHook`, `runCodexHook`, `runOpenCodeHook` in
  `CLI/CLI+Hooks.swift`) reads the provider's hook JSON off stdin, classifies
  it by hand (`classifyClaudeNotification`, `classifyCodexNotification`,
  OpenCode's inline `permission.asked` check), and calls the v2 method
  `surface.report_agent_state` with a **three-value** state
  (`working|blocked|idle`) and `source: "hooks"`.
- **Screen-manifest tier** — `Sources/AgentScreenDetectionEngine.swift`
  samples visible terminal text against `Resources/AgentDetection/*.json`
  manifests and reports the same three-value state with
  `source: "inferred"`.
- **Precedence** — `Workspace.updatePanelAgentState`
  (`Sources/Workspace+SidebarTelemetry.swift:255`) already implements
  hooks-always-win: an `.inferred` write is silently dropped whenever the
  surface's current source is `.hooks`; a `.hooks` write always wins.
  `AgentStateSource` (`Sources/AgentActivityState.swift:51`) is the existing
  source tag. **This precedence rule is not new — it is the thing we must
  keep working, not build.**

So "hooks beat screen-scraping" already ships. What is missing, and what
this plan actually adds, is the *richness* of what a hook reports. Today a
hook collapses a rich lifecycle (session start, turn start, tool calls,
permission prompts, turn end) into one of three buckets by string-matching a
notification subtitle. There is no turn-progress signal, no structured
event log, no single normalized shape a future consumer (a sidebar timeline,
a `subscribe` stream, a status API) can read across providers. That is the
gap the t3code reference design (`git show
origin/docs/rust-core-spike:docs/plans/t3code-inventory.md`, "provider
events" section) closes, and what `docs/plans/rust-core-spike.md`'s watch
list flags as worth adopting piecemeal now rather than waiting for a Rust
core.

## Provider coverage (checked against current docs)

| Provider | Channel | Events available | Adapter plan |
|---|---|---|---|
| Claude Code | Hooks (`settings.json` `hooks` block; already installed by `runClaudeInstallIntegration`) | `SessionStart`, `SessionEnd`, `UserPromptSubmit`, `PreToolUse`/`PostToolUse`, `PermissionRequest`, `Notification` (matcher `permission_prompt` / `idle_prompt` / `agent_needs_input` / `agent_completed`), `Stop`, `SubagentStart`/`SubagentStop`. Full names verified against [code.claude.com/docs/en/hooks](https://code.claude.com/docs/en/hooks) (redirected from the old docs.claude.com URL). | Full mapping — richest channel. Extend the existing `runClaudeHook` cases to also emit normalized `agent.event` calls (see below); no new subprocess. |
| Codex | `notify` (config.toml, one event: `agent-turn-complete`, payload has `thread-id`/`turn-id`/`cwd`/`last-assistant-message` — [learn.chatgpt.com/docs/config-file/config-advanced](https://learn.chatgpt.com/docs/config-file/config-advanced)) plus a separate, less standardized `hooks.json` mechanism (`PreToolUse`/`PermissionRequest`/`Stop`/session events — [learn.chatgpt.com/codex/hooks](https://learn.chatgpt.com/codex/hooks)) that Programa's `codexRewriteHooks` already installs against. Treat `hooks.json` as the primary channel since it is what's already wired; `notify`'s `agent-turn-complete` is the only channel-agnostic signal if hooks.json is unavailable in a given Codex build — map it to `turn.completed` only. | Partial — turn/session/permission events map; no per-tool-call `item.*` detail from `notify`, best-effort detail from `hooks.json`. |
| OpenCode | Plugin event hooks (`.opencode/plugins/*.js`, already installed by `runOpenCodeInstallIntegration`) — `session.created`, `session.idle`, `session.error`, `session.updated`, `permission.asked`, `permission.replied`, `tool.execute.before`/`.after`, `message.updated` ([opencode.ai/docs/plugins](https://opencode.ai/docs/plugins)). | Full mapping — session/turn/permission/tool events all present. |
| Cursor CLI/Agent | `.cursor/hooks/*` local hooks (`onPreEdit`/`onPostEdit`/`onPreCommit`/`onApprove`) plus Cloud Agent webhooks (`statusChange`, only `ERROR`/`FINISHED` — [cursor.com/docs/cloud-agent/api/webhooks](https://cursor.com/docs/cloud-agent/api/webhooks)). No session/turn granularity, no permission-prompt event distinct from edit approval. | No adapter in this pass — too coarse to map to `request.opened/resolved` or `user-input.*` reliably. Screen manifest (`Resources/AgentDetection/cursor-agent.json`, already shipped) stays authoritative. |
| Gemini CLI | Hooks (`~/.gemini/settings.json` or project config — [geminicli.com/docs/hooks/reference](https://geminicli.com/docs/hooks/reference/)) — `SessionStart`/`SessionEnd`, `BeforeAgent`/`AfterAgent` (turn boundaries), `BeforeTool`/`AfterTool`, `Notification` (observability only — cannot act on or reliably distinguish permission prompts, per the docs). | No adapter in this pass: `Notification` is documented as observation-only for tool confirmations, so we cannot get a trustworthy `request.opened` signal yet. Screen manifest (`gemini-cli.json`, already shipped) stays authoritative. Revisit if Gemini CLI's `Notification` payload gains a stable permission-type field. |

Providers with no channel (or a channel too coarse to trust for
`blocked`/`waiting-for-input`) keep the screen manifest as their only
source, exactly as documented in `docs/agent-detection-manifests.md`. That
document's "programa's agent-state detection reads a pane's own lifecycle
hooks when available... and otherwise falls back to regex-matching" stays
true; this plan does not change it for Cursor or Gemini CLI.

## Normalized event schema

One shape, `agent.event`, used by every adapter. Field names keep t3code's
vocabulary where it fits so a later port to a shared core needs no
translation layer.

```jsonc
{
  "provider": "claude-code" | "codex" | "opencode",
  "session_id": "string",          // provider's own session/thread id
  "surface": { "workspace_id": "uuid", "surface_id": "uuid" }, // routing, same as surface.report_agent_state
  "event": {
    "type": "session.started" | "session.exited"
           | "turn.started" | "turn.completed" | "turn.aborted"
           | "request.opened" | "request.resolved"      // permission/approval prompts
           | "user-input.requested" | "user-input.resolved" // free-text "waiting on you" prompts
           | "item.started" | "item.completed",          // individual tool calls, for future turn-progress UI
    "turn_id": "string?",           // present on turn.*/request.*/item.* when the provider gives one
    "item_id": "string?",           // present on item.*
    "label": "string?",             // human-readable summary (tool name, question text) for future UI, never used for state classification
    "resolution": "approved" | "denied" | "answered" | null // request.resolved / user-input.resolved only
  }
}
```

Rationale for keeping it flat and small: the only consumer today is the
existing `AgentActivityState` funnel. `label`/`item_id`/`resolution` are
carried through and stored (see below) so a future richer UI does not
require a wire change, but nothing in this pass classifies state from
`label` text — classification stays on `event.type`, which is provider-
normalized before it reaches the socket, not on free-text sniffing (that
free-text sniffing is exactly what `classifyClaudeNotification` /
`classifyCodexNotification` do today, and is the brittleness this schema
replaces for the providers listed as "full mapping" above).

### Event type → `AgentActivityState` mapping

| event.type | AgentActivityState | Notes |
|---|---|---|
| `session.started` | `.idle` | Same effect as today's `SessionStart`/`session-start` case. |
| `turn.started` | `.working` | Replaces `UserPromptSubmit`/`prompt-submit`'s effect. |
| `item.started` (a tool call begins) | `.working` | No-op if already `.working`; exists for future turn-progress display, not required for the coarse wire value. |
| `item.completed` | `.working` | Same. |
| `request.opened` | `.blocked` | Replaces the `classify*Notification` "Permission" bucket — now driven by the provider's own permission-request event instead of subtitle text matching. |
| `request.resolved` | `.working` | Approval/denial answered; the agent resumes. |
| `user-input.requested` | `.blocked` | Replaces the `classify*Notification` "Waiting" bucket. |
| `user-input.resolved` | `.working` | |
| `turn.completed` | `.idle` | Replaces `Stop`/`stop`'s effect. |
| `turn.aborted` | `.idle` | Interrupted/cancelled turn. |
| `session.exited` | *(clear)* | Calls `surface.clear_agent_state`'s existing effect, same as today's `SessionEnd`/`session-end`. |

This table is intentionally a strict superset of the existing 3-state
mapping — no wire value changes, no new `AgentActivityState` case. The win
is that the classification now happens once, in the normalizer
(`Sources/AgentEventNormalizer.swift`, new), driven by an explicit
provider-native event name, instead of three near-duplicate regex/keyword
classifiers scattered across `CLI+Hooks.swift`.

### Precedence (unchanged, restated for this feature)

`agent.event` reports flow through the exact same
`updatePanelAgentState(source: .hooks)` path `surface.report_agent_state`
already uses. A structured event **always** beats the screen manifest,
because the screen manifest only ever writes `source: .inferred`, and
`.inferred` writes are dropped once a surface has ever seen `.hooks`
(`Workspace+SidebarTelemetry.swift:259`). Providers with an adapter in this
pass therefore stop needing the screen manifest at all once their hooks are
installed; providers without one (Cursor, Gemini CLI, and anything future)
keep the manifest as their only source, exactly as before.

## Wire path

One v2 method, `agent.event`, replacing the ad hoc classification call
sites (not `surface.report_agent_state`'s existing wire shape, which stays
for backward compatibility and for any caller that only has a bare
tri-state to report):

```
agent.event {
  provider: string,
  session_id: string,
  workspace_id: uuid?,      // same optional-with-env-fallback resolution as every other surface.* call
  surface_id: uuid?,
  event_type: string,       // one of the event.type values above
  turn_id: string?,
  item_id: string?,
  label: string?,
  resolution: string?
} -> { workspace_id, workspace_ref, surface_id, surface_ref, state, source: "hooks" }
```

A tiny CLI verb, `programa agent-event --provider <p> --event <event_type> [--session-id <id>] [--turn-id <id>] [--item-id <id>] [--label <text>] [--resolution <r>] [--workspace <id|ref>] [--surface <id|ref>]`, is the one thing every provider hook shells out to — no interpreter required, matching Claude/Codex/OpenCode's existing `command`-type hook wiring. Internally, the existing `runClaudeHook`/`runCodexHook`/`runOpenCodeHook` handlers (which already parse each provider's native hook JSON in-process) are extended to build the same normalized params and call the socket directly — they do not need to spawn `programa agent-event` as a second process, since they already are `programa`. `programa agent-event` itself exists for: (a) provider adapters we install fresh (Codex `hooks.json`, OpenCode plugin) where the installed hook command needs a single fixed CLI invocation rather than a stdin-parsing subcommand, and (b) a documented, testable entry point that `tests_v2` and future adapters can call directly.

## Threading and dedupe

`agent.event`'s handler follows the same shape as `v2SurfaceReportAgentState`
(`Sources/TerminalController+Telemetry.swift:279`, itself following
CLAUDE.md's socket command threading policy): parse and validate every
param off-main (UUID lookups, event-type parsing, normalization to
`AgentActivityState`), then a single `DispatchQueue.main.async` mutation via
the existing `v2ScheduleSurfaceTelemetryMutation` helper. No
`DispatchQueue.main.sync`. No focus side effects — this is a report, not a
focus-intent command, so it is exempt from the socket focus policy's
explicit-intent allowlist.

## What stays out of scope for this pass

- No new `AgentActivityState` wire value. Turn-progress detail
  (`item.*`, `label`) is accepted and normalized today but not yet
  surfaced anywhere beyond being available for a future `subscribe`
  payload extension — adding that payload is left for a follow-up so this
  pass doesn't also have to re-litigate `subscribe`'s frame shape.
- No Cursor or Gemini CLI adapter (see coverage table) — their channels are
  currently too coarse or observation-only for a trustworthy
  `request.opened`/`user-input.requested` signal.
- No change to `AgentSupervisionRegistry`/`agent.task.*` — that system stays
  as-is; `v2SurfaceReportAgentState` already keeps it in sync today and the
  new `agent.event` handler does the same via the identical
  `updateActiveSurface` call.
