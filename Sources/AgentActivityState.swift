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
