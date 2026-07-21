// Issue #164 (v1 hook tier): working/blocked/idle agent-state model tests.
//
// Verifies the runtime behavior fed exclusively by lifecycle hooks (Claude Code, Codex,
// OpenCode) — no screen-rule fallback exists yet, so this only exercises the explicit
// report/clear/aggregate state machine, not any heuristic classification.
import XCTest

#if canImport(Programa_DEV)
@testable import Programa_DEV
#elseif canImport(Programa)
@testable import Programa
#endif

@MainActor
final class AgentActivityStateTests: XCTestCase {
    // MARK: - AgentActivityState.aggregating(with:)

    func testAggregatingKeepsWorstOfTwoStates() {
        XCTAssertEqual(AgentActivityState.idle.aggregating(with: .working), .working)
        XCTAssertEqual(AgentActivityState.working.aggregating(with: .blocked), .blocked)
        XCTAssertEqual(AgentActivityState.blocked.aggregating(with: .idle), .blocked)
        XCTAssertEqual(AgentActivityState.idle.aggregating(with: .idle), .idle)
    }

    // MARK: - Workspace-level state (panelAgentStates / aggregateAgentState)

    func testWorkspaceHasNoAggregateStateUntilAgentStateIsReported() {
        let workspace = Workspace(title: "Test")
        XCTAssertNil(workspace.aggregateAgentState)
        XCTAssertFalse(workspace.hasBlockedAgentSurface)
    }

    func testUpdatePanelAgentStateSetsAggregateState() {
        let workspace = Workspace(title: "Test")
        let panelId = UUID()

        workspace.updatePanelAgentState(panelId: panelId, state: .working)
        XCTAssertEqual(workspace.panelAgentStates[panelId], .working)
        XCTAssertEqual(workspace.aggregateAgentState, .working)
        XCTAssertFalse(workspace.hasBlockedAgentSurface)
    }

    func testAggregateAgentStateIsWorstAcrossPanels() {
        let workspace = Workspace(title: "Test")
        let idlePanelId = UUID()
        let blockedPanelId = UUID()

        workspace.updatePanelAgentState(panelId: idlePanelId, state: .idle)
        XCTAssertEqual(workspace.aggregateAgentState, .idle)

        workspace.updatePanelAgentState(panelId: blockedPanelId, state: .blocked)
        XCTAssertEqual(workspace.aggregateAgentState, .blocked)
        XCTAssertTrue(workspace.hasBlockedAgentSurface)

        // Idle panel resolving does not clear the still-blocked one.
        workspace.updatePanelAgentState(panelId: idlePanelId, state: .working)
        XCTAssertEqual(workspace.aggregateAgentState, .blocked)
    }

    func testClearPanelAgentStateRemovesEntry() {
        let workspace = Workspace(title: "Test")
        let panelId = UUID()

        workspace.updatePanelAgentState(panelId: panelId, state: .blocked)
        XCTAssertTrue(workspace.hasBlockedAgentSurface)

        workspace.clearPanelAgentState(panelId: panelId)
        XCTAssertNil(workspace.panelAgentStates[panelId])
        XCTAssertNil(workspace.aggregateAgentState)
    }

    func testPruneSurfaceMetadataDropsStaleAgentStates() {
        let workspace = Workspace(title: "Test")
        let keptPanelId = UUID()
        let staleePanelId = UUID()

        workspace.updatePanelAgentState(panelId: keptPanelId, state: .working)
        workspace.updatePanelAgentState(panelId: staleePanelId, state: .blocked)
        XCTAssertEqual(workspace.panelAgentStates.count, 2)

        workspace.pruneSurfaceMetadata(validSurfaceIds: [keptPanelId])

        XCTAssertEqual(workspace.panelAgentStates, [keptPanelId: .working])
        XCTAssertEqual(workspace.aggregateAgentState, .working)
    }

    func testResetSidebarContextClearsAgentStates() {
        let workspace = Workspace(title: "Test")
        workspace.updatePanelAgentState(panelId: UUID(), state: .blocked)
        XCTAssertTrue(workspace.hasBlockedAgentSurface)

        workspace.resetSidebarContext(reason: "test")

        XCTAssertTrue(workspace.panelAgentStates.isEmpty)
        XCTAssertNil(workspace.aggregateAgentState)
    }

    // MARK: - TabManager.updateSurfaceAgentState / clearSurfaceAgentState

    func testTabManagerUpdateSurfaceAgentStateAppliesToRealPanel() throws {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let panelId = workspace.focusedPanelId else {
            XCTFail("Expected selected workspace with focused panel")
            return
        }

        let applied = manager.updateSurfaceAgentState(tabId: workspace.id, surfaceId: panelId, state: .working)
        XCTAssertTrue(applied)
        XCTAssertEqual(workspace.panelAgentStates[panelId], .working)

        manager.updateSurfaceAgentState(tabId: workspace.id, surfaceId: panelId, state: .blocked)
        XCTAssertEqual(workspace.panelAgentStates[panelId], .blocked)

        manager.clearSurfaceAgentState(tabId: workspace.id, surfaceId: panelId)
        XCTAssertNil(workspace.panelAgentStates[panelId])
    }

    func testTabManagerUpdateSurfaceAgentStateNoOpsForUnknownSurface() throws {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace else {
            XCTFail("Expected selected workspace")
            return
        }

        let applied = manager.updateSurfaceAgentState(tabId: workspace.id, surfaceId: UUID(), state: .working)
        XCTAssertFalse(applied)
        XCTAssertTrue(workspace.panelAgentStates.isEmpty)
    }

    func testTabManagerUpdateSurfaceAgentStateNoOpsForUnknownWorkspace() {
        let manager = TabManager()
        let applied = manager.updateSurfaceAgentState(tabId: UUID(), surfaceId: UUID(), state: .working)
        XCTAssertFalse(applied)
    }
}
