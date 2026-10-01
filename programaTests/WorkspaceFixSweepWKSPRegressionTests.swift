import XCTest

#if canImport(Programa_DEV)
@testable import Programa_DEV
#elseif canImport(Programa)
@testable import Programa
#endif

/// Red-first regressions for the workspace fix sweep: each test uses only APIs that exist on the
/// pre-fix base commit and fails there.
@MainActor
final class WorkspaceFixSweepWKSPRegressionTests: XCTestCase {
    /// A closed agent pane must not leave a phantom "Needs input" badge on the workspace row.
    func testPermanentCloseClearsAgentPresenceAndSidebarBadge() throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let keep = try XCTUnwrap(workspace.focusedPanelId)
        let agentPanel = try XCTUnwrap(workspace.newTerminalSurfaceInFocusedPane(focus: false)).id
        workspace.updatePanelAgentState(panelId: agentPanel, state: .blocked, source: .hooks)
        XCTAssertNotNil(SidebarAgentIndicator.make(for: workspace))

        XCTAssertTrue(workspace.closePanel(agentPanel, force: true))

        XCTAssertNil(workspace.panelAgentPresence[agentPanel])
        XCTAssertNil(SidebarAgentIndicator.make(for: workspace))
        XCTAssertNotNil(workspace.panels[keep])
    }

    /// Two working agents: the stale flag must come from the freshest report, not from whichever
    /// presence the dictionary happens to iterate last. Repeated over many UUID pairs so every
    /// hash order is exercised.
    func testEqualSeverityStaleFlagFollowsFreshestReportRegardlessOfOrder() {
        let now = Date()
        for _ in 0..<64 {
            let workspace = Workspace()
            defer { workspace.teardownAllPanels() }
            let fresh = UUID()
            let old = UUID()
            workspace.panelAgentPresence = [
                fresh: AgentPresence(state: .working, source: .hooks, lastEventAt: now),
                old: AgentPresence(
                    state: .working,
                    source: .hooks,
                    lastEventAt: now.addingTimeInterval(-AgentPresence.staleThreshold - 60)
                ),
            ]
            XCTAssertEqual(SidebarAgentIndicator.make(for: workspace, now: now)?.isStale, false)
        }
    }
}
