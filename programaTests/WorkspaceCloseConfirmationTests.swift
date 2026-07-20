import XCTest
@testable import Programa_DEV

/// Regression tests for the close-confirmation-before-tty-attach race
/// (ported from upstream cmux 2e03978ae1, adapted to our shell-integration
/// telemetry signals).
///
/// Right after a terminal is created, no shell-activity state has been
/// reported and no TTY is known for the panel. In that window there is no
/// attached shell whose work could be lost, so closing must never prompt —
/// the raw ghostty needs-confirm fallback can spuriously report true before
/// the tty attaches.
@MainActor
final class WorkspaceCloseConfirmationTests: XCTestCase {
    private func makeWorkspaceWithPanel() throws -> (Workspace, UUID) {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let panelId = try XCTUnwrap(workspace.panels.keys.first)
        return (workspace, panelId)
    }

    func testUnknownActivityWithoutTTYNeverConfirms() throws {
        let (workspace, panelId) = try makeWorkspaceWithPanel()
        XCTAssertNil(workspace.panelShellActivityStates[panelId])
        XCTAssertNil(workspace.surfaceTTYNames[panelId])

        // Even when the ghostty-side fallback claims confirmation is needed,
        // a panel with no reported shell state and no TTY has nothing to lose.
        XCTAssertFalse(
            workspace.panelNeedsConfirmClose(panelId: panelId, fallbackNeedsConfirmClose: true),
            "pre-tty-attach close must not prompt for confirmation"
        )
    }

    func testUnknownActivityWithKnownTTYHonorsFallback() throws {
        let (workspace, panelId) = try makeWorkspaceWithPanel()
        workspace.surfaceTTYNames[panelId] = "/dev/ttys004"

        XCTAssertTrue(
            workspace.panelNeedsConfirmClose(panelId: panelId, fallbackNeedsConfirmClose: true)
        )
        XCTAssertFalse(
            workspace.panelNeedsConfirmClose(panelId: panelId, fallbackNeedsConfirmClose: false)
        )
    }

    func testCommandRunningAlwaysConfirms() throws {
        let (workspace, panelId) = try makeWorkspaceWithPanel()
        workspace.updatePanelShellActivityState(panelId: panelId, state: .commandRunning)

        XCTAssertTrue(
            workspace.panelNeedsConfirmClose(panelId: panelId, fallbackNeedsConfirmClose: false)
        )
    }

    func testPromptIdleNeverConfirms() throws {
        let (workspace, panelId) = try makeWorkspaceWithPanel()
        workspace.updatePanelShellActivityState(panelId: panelId, state: .promptIdle)

        XCTAssertFalse(
            workspace.panelNeedsConfirmClose(panelId: panelId, fallbackNeedsConfirmClose: true)
        )
    }
}
