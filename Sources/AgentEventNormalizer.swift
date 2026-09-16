// Normalizes a provider-native `event_type` string (docs/plans/agent-events.md,
// "Event type → AgentActivityState mapping") into either an AgentActivityState to
// apply or a "clear" instruction. Pure (no networking, no side effects) --
// deliberately trivial to unit test in isolation from the socket/threading plumbing
// in Sources/TerminalController+Telemetry.swift's `v2AgentEvent`.
import Foundation

enum AgentEventNormalizer {
    enum Outcome: Equatable {
        case applyState(AgentActivityState)
        case clearState
    }

    /// Classifies a normalized `event.type` string per the mapping table in
    /// docs/plans/agent-events.md. Returns `nil` for an unrecognized or malformed
    /// event type -- callers should treat that as an invalid-params error, not a
    /// silent no-op.
    static func classify(eventType: String) -> Outcome? {
        switch eventType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "session.started":
            return .applyState(.idle)
        case "turn.started":
            return .applyState(.working)
        case "item.started":
            return .applyState(.working)
        case "item.completed":
            return .applyState(.working)
        case "request.opened":
            return .applyState(.blocked)
        case "request.resolved":
            return .applyState(.working)
        case "user-input.requested":
            return .applyState(.blocked)
        case "user-input.resolved":
            return .applyState(.working)
        case "turn.completed":
            return .applyState(.idle)
        case "turn.aborted":
            return .applyState(.idle)
        case "session.exited":
            return .clearState
        default:
            return nil
        }
    }
}
