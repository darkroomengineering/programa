import AppKit

/// Classifies a terminal scroll event for the historical precise-delta 2x
/// boost (ported from upstream cmux da4e4bc460).
///
/// Trackpads and Magic Mouse drive a continuous gesture phase; high-res plain
/// wheels (e.g. Logitech free-spin) report precise deltas but leave both
/// `phase` and `momentumPhase` empty. Boosting those stacks on top of the
/// OS's own wheel acceleration and produces runaway scrolling, so only
/// gesture-driven events get the boost.
struct GhosttyTerminalScrollBoost {
    let hasPreciseScrollingDeltas: Bool
    let phase: NSEvent.Phase
    let momentumPhase: NSEvent.Phase

    init(hasPreciseScrollingDeltas: Bool, phase: NSEvent.Phase, momentumPhase: NSEvent.Phase) {
        self.hasPreciseScrollingDeltas = hasPreciseScrollingDeltas
        self.phase = phase
        self.momentumPhase = momentumPhase
    }

    init(event: NSEvent) {
        self.init(
            hasPreciseScrollingDeltas: event.hasPreciseScrollingDeltas,
            phase: event.phase,
            momentumPhase: event.momentumPhase
        )
    }

    var shouldDoublePreciseScrollDelta: Bool {
        guard hasPreciseScrollingDeltas else { return false }
        return !phase.isEmpty || !momentumPhase.isEmpty
    }
}
