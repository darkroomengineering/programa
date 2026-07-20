import XCTest
@testable import Programa_DEV

/// Regression tests for the precise-scroll 2x boost gating (ported from
/// upstream cmux da4e4bc460): only gesture-driven precise deltas (trackpad,
/// Magic Mouse) are boosted; high-res mouse wheels report precise deltas
/// with empty phases and must scroll unboosted.
final class GhosttyScrollPreciseBoostTests: XCTestCase {
    func testTrackpadGesturePhaseBoosts() {
        let boost = GhosttyTerminalScrollBoost(
            hasPreciseScrollingDeltas: true,
            phase: .changed,
            momentumPhase: []
        )
        XCTAssertTrue(boost.shouldDoublePreciseScrollDelta)
    }

    func testMomentumPhaseBoosts() {
        let boost = GhosttyTerminalScrollBoost(
            hasPreciseScrollingDeltas: true,
            phase: [],
            momentumPhase: .changed
        )
        XCTAssertTrue(boost.shouldDoublePreciseScrollDelta)
    }

    func testHighResMouseWheelDoesNotBoost() {
        // Precise deltas but no gesture phase: a free-spin high-res wheel.
        let boost = GhosttyTerminalScrollBoost(
            hasPreciseScrollingDeltas: true,
            phase: [],
            momentumPhase: []
        )
        XCTAssertFalse(boost.shouldDoublePreciseScrollDelta)
    }

    func testNonPreciseWheelDoesNotBoost() {
        let boost = GhosttyTerminalScrollBoost(
            hasPreciseScrollingDeltas: false,
            phase: .changed,
            momentumPhase: []
        )
        XCTAssertFalse(boost.shouldDoublePreciseScrollDelta)
    }
}
