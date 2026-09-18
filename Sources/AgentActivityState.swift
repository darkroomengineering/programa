// Agent status badges (issue #164), v1 hook-tier scope only.
//
// Two-tier status authority per the issue design: lifecycle hooks (Claude Code, Codex,
// OpenCode — already installed via CLI+Hooks.swift) are the single source of truth when
// present. This file only models the hook-driven state; there is no screen-rule fallback
// (v2, tracked separately).
//
// Strict-blocked rule: `.blocked` is only ever set by an explicit hook report of a
// permission/approval/question prompt (see CLI+Hooks.swift's classifyClaudeNotification /
// classifyCodexNotification, and OpenCode's permission.asked event, which is unconditionally
// a permission prompt). Anything ambiguous or unclassified defaults to `.idle` — a false
// "blocked" trains users to ignore the badge.
import Foundation

/// Per-surface agent activity state, reported exclusively by installed lifecycle hooks.
/// A surface with no entry has no hook-managed agent (or hasn't reported yet) and shows
/// no badge at all — distinct from `.idle`, which means a hook explicitly reported rest.
enum AgentActivityState: String, Codable, CaseIterable, Sendable {
    case working
    case blocked
    case idle

    /// Worst-first ordering used to aggregate multiple surfaces into one workspace-level
    /// badge: a single blocked surface makes the whole workspace read as blocked, even if
    /// other surfaces are idle/working.
    fileprivate var severity: Int {
        switch self {
        case .blocked: return 2
        case .working: return 1
        case .idle: return 0
        }
    }

    /// Combines two states, keeping the higher-severity one (blocked > working > idle).
    func aggregating(with other: AgentActivityState) -> AgentActivityState {
        severity >= other.severity ? self : other
    }
}

/// Which tier reported a surface's current `AgentActivityState` (screen-manifest detection,
/// v2 — see docs/plans/screen-manifest-detection.md). Additive sibling to `agent_state`
/// wherever it appears on the wire (`surface.list`/`surface.wait`/`subscribe`) — `agent_state`
/// itself never changes shape, per docs/v2-api-migration.md's "never repurpose an existing
/// field" discipline and the exact-string-equality tests that already assert on it.
///
/// Hooks always win: `Workspace.updatePanelAgentState` (Workspace+SidebarTelemetry.swift)
/// silently drops an `.inferred` write when the surface's currently recorded source is
/// `.hooks` — a hook-managed surface's state is authoritative the instant a hook speaks, and
/// the screen-manifest engine should not even be sampling it (see
/// AgentScreenDetectionEngine.swift's Phase A demotion).
enum AgentStateSource: String, Codable, CaseIterable, Sendable {
    case hooks
    case inferred
}

/// Identifies the process/session behind a reported `AgentPresence`, when known. Hook reports
/// (source `.hooks`) may carry a session id and/or pid; screen-inferred reports (source
/// `.inferred`) never carry one, since there is no session to key on. Used for liveness
/// sweeping (`sweepStaleAgentPIDs`) and future per-session disambiguation.
struct AgentSessionKey: Equatable, Hashable, Sendable, Codable {
    let provider: String
    let sessionId: String?
    let pid: pid_t?
}

/// One surface's agent activity, with the provenance and timestamp needed to unify the
/// three ad hoc "needs-input" signals (issue: agent-state-unification) into a single write
/// path. `Workspace.panelAgentPresence` is the stored source of truth;
/// `panelAgentStates`/`panelAgentStateSources` are derived, read-only mirrors kept for the
/// existing wire shapes and call sites.
struct AgentPresence: Equatable, Sendable {
    var state: AgentActivityState
    var source: AgentStateSource
    var lastEventAt: Date
    var sessionKey: AgentSessionKey?
    /// Set by the watchdog sweep once `isStale` first turns true, and reset by every write.
    /// Staleness itself is computed from `lastEventAt`; this stored flag only makes the
    /// transition a real value change, so the `removeDuplicates` sidebar publisher fires.
    var staleObserved: Bool = false

    /// 10 minutes: a hook-managed agent is expected to report at least once in this window
    /// while non-idle (tool calls, turn boundaries). Idle is the resting value and never
    /// goes stale -- there is nothing pending to time out.
    static let staleThreshold: TimeInterval = 600

    /// True when this presence is non-idle and hasn't been refreshed within `threshold`.
    /// Staleness never clears presence on its own; it only dims/suffixes the indicator.
    func isStale(now: Date, threshold: TimeInterval = AgentPresence.staleThreshold) -> Bool {
        state != .idle && now.timeIntervalSince(lastEventAt) > threshold
    }
}

/// The single derived glyph/label/tint for a workspace's aggregate agent state, replacing the
/// three independent renderings that used to read `panelAgentStates`, `statusEntries["claude_code"]`,
/// and the notification subtitle separately. `TabItemView` is the only consumer.
struct SidebarAgentIndicator: Equatable {
    enum Tint: Equatable {
        case blocked
        case working
        case idle
    }

    let systemImage: String
    let label: String
    let tint: Tint
    let isStale: Bool

    /// Aggregates every surface's presence worst-first (blocked > working > idle), exactly as
    /// `Workspace.aggregateAgentState` does today, and returns `nil` when the workspace has no
    /// presence at all (no badge should render). The stale flag reflects only the presence that
    /// won the aggregation, not every surface.
    @MainActor
    static func make(for workspace: Workspace, now: Date = Date()) -> SidebarAgentIndicator? {
        let winner = workspace.panelAgentPresence.values.reduce(nil as AgentPresence?) { partial, presence in
            guard let partial else { return presence }
            return presence.state.severity >= partial.state.severity ? presence : partial
        }
        guard let winner else { return nil }

        let isStale = winner.isStale(now: now)
        switch winner.state {
        case .blocked:
            return SidebarAgentIndicator(
                systemImage: "exclamationmark.circle.fill",
                label: isStale
                    ? String(localized: "sidebar.agentIndicator.needsInputStale", defaultValue: "Needs input (stale)")
                    : String(localized: "sidebar.agentIndicator.needsInput", defaultValue: "Needs input"),
                tint: .blocked,
                isStale: isStale
            )
        case .working:
            return SidebarAgentIndicator(
                systemImage: "bolt.fill",
                label: isStale
                    ? String(localized: "sidebar.agentIndicator.workingStale", defaultValue: "Working (stale)")
                    : String(localized: "sidebar.agentIndicator.working", defaultValue: "Working"),
                tint: .working,
                isStale: isStale
            )
        case .idle:
            return SidebarAgentIndicator(
                systemImage: "moon.fill",
                label: String(localized: "sidebar.agentIndicator.idle", defaultValue: "Idle"),
                tint: .idle,
                isStale: false
            )
        }
    }
}

extension Workspace {
    /// Worst-of aggregate agent state across every surface in this workspace, or `nil` if
    /// no surface has a hook-managed agent state at all (no badge should render).
    var aggregateAgentState: AgentActivityState? {
        panelAgentStates.values.reduce(nil) { partial, state in
            guard let partial else { return state }
            return partial.aggregating(with: state)
        }
    }

    var hasBlockedAgentSurface: Bool {
        panelAgentStates.values.contains(.blocked)
    }
}
