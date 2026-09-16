import XCTest

#if canImport(Programa_DEV)
@testable import Programa_DEV
#elseif canImport(Programa)
@testable import Programa
#endif

/// Regression coverage for the sleep/wake escrow bug: the holder used to
/// measure heartbeat staleness with `Date()` (wall clock), so any system
/// sleep longer than `SessionEscrowPolicy.heartbeatStaleAfter` made it
/// declare every escrowed PTY dead the instant the Mac woke back up -- the
/// app was suspended too, so no heartbeat could possibly have arrived
/// during the sleep window either. The fix moved the comparison onto
/// `ProcessInfo.systemUptime` (pauses across sleep). These tests exercise
/// the factored-out comparison directly (an executable seam,
/// `SessionEscrowPolicy.isConnectionStale`), not the real socket read loop,
/// which needs a live holder process to drive.
final class SessionEscrowWakeRecoveryTests: XCTestCase {
    /// A long *wall-clock* gap that only reflects elapsed sleep time must
    /// NOT be seen as staleness once measured on the sleep-pausing clock:
    /// the two systemUptime readings here are only 1s apart, standing in
    /// for "the machine was asleep for hours, but awake for only 1s since
    /// the last heartbeat."
    func testGapThatOnlyReflectsSleepIsNotStale() {
        let lastActivity: TimeInterval = 1_000
        let now: TimeInterval = 1_001 // 1s of *awake* time elapsed.
        XCTAssertFalse(
            SessionEscrowPolicy.isConnectionStale(lastActivitySystemUptime: lastActivity, nowSystemUptime: now),
            "a 1s awake gap must never be treated as a dead connection"
        )
    }

    /// A genuine gap while the machine stayed awake (no heartbeat arrived,
    /// nothing to blame on sleep) must still be caught -- this is the
    /// backstop `heartbeatStaleAfter` exists for in the first place, and
    /// the fix must not have weakened it.
    func testGenuineAwakeGapIsStillStale() {
        let lastActivity: TimeInterval = 1_000
        let now: TimeInterval = 1_000 + SessionEscrowPolicy.heartbeatStaleAfter + 1
        XCTAssertTrue(
            SessionEscrowPolicy.isConnectionStale(lastActivitySystemUptime: lastActivity, nowSystemUptime: now),
            "a genuine awake gap past heartbeatStaleAfter must still be detected as dead"
        )
    }

    func testExactBoundaryIsStale() {
        let lastActivity: TimeInterval = 500
        let now: TimeInterval = 500 + SessionEscrowPolicy.heartbeatStaleAfter
        XCTAssertTrue(
            SessionEscrowPolicy.isConnectionStale(lastActivitySystemUptime: lastActivity, nowSystemUptime: now)
        )
    }

    func testJustBelowBoundaryIsNotStale() {
        let lastActivity: TimeInterval = 500
        let now: TimeInterval = 500 + SessionEscrowPolicy.heartbeatStaleAfter - 0.01
        XCTAssertFalse(
            SessionEscrowPolicy.isConnectionStale(lastActivitySystemUptime: lastActivity, nowSystemUptime: now)
        )
    }

    /// `SessionEscrowClient.notifySystemDidWake()` -- the app-side half of
    /// wake recovery, invoked from `AppDelegate`'s `didWakeNotification`
    /// handler -- must be safe to call with no active connection (the
    /// common case: most launches never escrow anything) and must not
    /// block or crash under `SessionMachineryGate.isUnitTesting`.
    func testNotifySystemDidWakeIsSafeWithNoConnection() {
        SessionEscrowClient.shared.notifySystemDidWake()
        // No assertion beyond "did not crash / did not hang" -- this is the
        // executable seam the wake handler drives; the method is a no-op
        // under the unit-test gate by design (see SessionMachineryGate).
    }
}
