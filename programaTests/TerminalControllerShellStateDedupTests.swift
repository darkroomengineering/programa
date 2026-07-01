import XCTest

#if canImport(Programa_DEV)
@testable import Programa_DEV
#elseif canImport(Programa)
@testable import Programa
#endif

/// Regression guard for the #6618 shellState dedup race.
///
/// `SocketFastPathState.shouldPublishShellActivity` must NOT record the state it
/// reads. Recording happens only via `recordShellActivity`, called after the
/// update is confirmed applied on the main thread. The old implementation wrote
/// on read, so a report that was never applied (panel absent) would suppress the
/// next identical report — losing the activity update permanently.
final class TerminalControllerShellStateDedupTests: XCTestCase {
    func testShouldPublishDoesNotSuppressUntilActivityRecorded() {
        let state = TerminalController.SocketFastPathState()
        let workspaceId = UUID()
        let panelId = UUID()
        let activity: Workspace.PanelShellActivityState = .commandRunning

        // 1. First observation of a state is always worth publishing.
        XCTAssertTrue(
            state.shouldPublishShellActivity(
                workspaceId: workspaceId,
                panelId: panelId,
                state: activity
            ),
            "First state report should be publishable"
        )

        // 2. Simulate the apply failing (panel absent): recordShellActivity is NOT called.

        // 3. The identical state must STILL be publishable, because nothing was
        //    recorded — this is the regression. Write-on-read would return false here.
        XCTAssertTrue(
            state.shouldPublishShellActivity(
                workspaceId: workspaceId,
                panelId: panelId,
                state: activity
            ),
            "Identical state must remain publishable until it is recorded as applied"
        )

        // 4. After recording the applied state, the identical report is deduped.
        state.recordShellActivity(
            workspaceId: workspaceId,
            panelId: panelId,
            state: activity
        )
        XCTAssertFalse(
            state.shouldPublishShellActivity(
                workspaceId: workspaceId,
                panelId: panelId,
                state: activity
            ),
            "Once recorded, an identical state should be deduped"
        )
    }
}
