// Issue #164 (v1 hook tier): working/blocked/idle agent-state model tests.
//
// Verifies the runtime behavior fed exclusively by lifecycle hooks (Claude Code, Codex,
// OpenCode) — no screen-rule fallback exists yet, so this only exercises the explicit
// report/clear/aggregate state machine, not any heuristic classification.
import XCTest
import AppKit

private final class InferenceTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds: TimeInterval = 0
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return Date(timeIntervalSince1970: seconds) }
    func advance(to value: TimeInterval) { lock.lock(); seconds = value; lock.unlock() }
}

@MainActor
final class InferredAgentCleanupTests: XCTestCase {
    private func manifest() throws -> AgentManifest {
        try JSONDecoder().decode(AgentManifest.self, from: Data("""
        {"version":1,"agent":"test","display_name":"Test","recognize":{"process_names":[],"screen_patterns":["WORK"]},
         "states":[{"bucket":"working","priority":50,"anchor_last_n_lines":6,"patterns":["WORK"],"confidence":"high","source_notes":"fixture"}]}
        """.utf8))
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func infer(_ engine: AgentScreenDetectionEngine, _ workspace: Workspace, _ panel: UUID, _ manifest: AgentManifest) {
        engine.promoteCandidate(surfaceId: panel, workspaceId: workspace.id, manifest: manifest)
        for _ in 0..<2 { engine.processSample(surfaceId: panel, workspaceId: workspace.id, manifest: manifest, text: "WORK") }
    }

    func testGraceExpiryClearsInferenceAndPreservesUnrelatedPanel() async throws {
        let workspace = Workspace()
        let panel = try XCTUnwrap(workspace.focusedPanelId)
        let other = try XCTUnwrap(workspace.newTerminalSurfaceInFocusedPane(focus: false)).id
        workspace.updatePanelAgentState(panelId: other, state: .blocked, source: .hooks)
        let clock = InferenceTestClock()
        let engine = AgentScreenDetectionEngine(now: { clock.now() }, resolveWorkspace: { _, _ in workspace })
        let rule = try manifest()
        infer(engine, workspace, panel, rule)
        await drainMainQueue()
        XCTAssertEqual(workspace.panelAgentStates[panel], .working)
        clock.advance(to: 29)
        engine.processSample(surfaceId: panel, workspaceId: workspace.id, manifest: rule, text: "ordinary shell")
        await drainMainQueue()
        XCTAssertEqual(workspace.panelAgentStateSources[panel], .inferred)
        clock.advance(to: 31)
        engine.processSample(surfaceId: panel, workspaceId: workspace.id, manifest: rule, text: "ordinary shell")
        await drainMainQueue()
        XCTAssertNil(workspace.panelAgentStates[panel])
        XCTAssertNil(workspace.panelAgentStateSources[panel])
        XCTAssertEqual(workspace.panelAgentStates[other], .blocked)
        XCTAssertEqual(workspace.panelAgentStateSources[other], .hooks)
    }

    func testDisableClearsReportedInference() async throws {
        let workspace = Workspace()
        let panel = try XCTUnwrap(workspace.focusedPanelId)
        let engine = AgentScreenDetectionEngine(resolveWorkspace: { _, _ in workspace })
        infer(engine, workspace, panel, try manifest())
        await drainMainQueue()
        XCTAssertEqual(workspace.panelAgentStateSources[panel], .inferred)
        engine.clearAllCandidates()
        await drainMainQueue()
        XCTAssertNil(workspace.panelAgentStates[panel])
        XCTAssertNil(workspace.panelAgentStateSources[panel])
    }

    func testHookReplacementBeforeQueuedCleanupRemainsAuthoritative() async throws {
        let workspace = Workspace()
        let panel = try XCTUnwrap(workspace.focusedPanelId)
        let clock = InferenceTestClock()
        let engine = AgentScreenDetectionEngine(now: { clock.now() }, resolveWorkspace: { _, _ in workspace })
        let rule = try manifest()
        infer(engine, workspace, panel, rule)
        await drainMainQueue()
        clock.advance(to: 31)
        engine.processSample(surfaceId: panel, workspaceId: workspace.id, manifest: rule, text: "ordinary shell")
        workspace.updatePanelAgentState(panelId: panel, state: .blocked, source: .hooks)
        await drainMainQueue()
        XCTAssertEqual(workspace.panelAgentStates[panel], .blocked)
        XCTAssertEqual(workspace.panelAgentStateSources[panel], .hooks)
    }

    func testQueuedInferenceCannotReappearAfterDisable() async throws {
        let workspace = Workspace()
        let panel = try XCTUnwrap(workspace.focusedPanelId)
        let engine = AgentScreenDetectionEngine(resolveWorkspace: { _, _ in workspace })
        infer(engine, workspace, panel, try manifest())
        engine.clearAllCandidates()
        await drainMainQueue()
        XCTAssertNil(workspace.panelAgentStates[panel])
        XCTAssertNil(workspace.panelAgentStateSources[panel])
    }

    func testNewCandidateSurvivesCleanupQueuedForItsPredecessor() async throws {
        let workspace = Workspace()
        let panel = try XCTUnwrap(workspace.focusedPanelId)
        let engine = AgentScreenDetectionEngine(resolveWorkspace: { _, _ in workspace })
        let rule = try manifest()
        infer(engine, workspace, panel, rule)
        await drainMainQueue()
        engine.clearAllCandidates()
        DispatchQueue.main.async {
            XCTAssertEqual(workspace.panelAgentStates[panel], .working,
                           "Old cleanup must not clear the replacement candidate even before its next report is delivered")
        }
        infer(engine, workspace, panel, rule)
        await drainMainQueue()
        XCTAssertEqual(workspace.panelAgentStates[panel], .working)
        XCTAssertEqual(workspace.panelAgentStateSources[panel], .inferred)
    }

    func testCleanupFindsMovedPanelThroughProductionWorkspaceResolver() async throws {
        let original = AppDelegate.shared
        let app = AppDelegate()
        AppDelegate.shared = app
        defer { AppDelegate.shared = original }
        let manager = TabManager()
        app.tabManager = manager
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        app.registerMainWindow(window, windowId: UUID(), tabManager: manager, sidebarState: SidebarState(), sidebarSelectionState: SidebarSelectionState())
        defer { withExtendedLifetime(window) {} }
        let source = try XCTUnwrap(manager.selectedWorkspace)
        let destination = manager.addWorkspace(select: false, autoWelcomeIfNeeded: false)
        let panel = try XCTUnwrap(source.focusedPanelId)
        let engine = AgentScreenDetectionEngine()
        infer(engine, source, panel, try manifest())
        await drainMainQueue()
        XCTAssertEqual(source.panelAgentStateSources[panel], .inferred)
        let transfer = try XCTUnwrap(source.detachSurface(panelId: panel))
        let pane = try XCTUnwrap(destination.bonsplitController.allPaneIds.first)
        XCTAssertEqual(destination.attachDetachedSurface(transfer, inPane: pane, focus: false), panel)
        // Surface metadata is not transferred today; model the inferred state at its new owner
        // through the same public mutation API, then require cleanup to resolve the stable ID.
        destination.updatePanelAgentState(panelId: panel, state: .working, source: .inferred)
        engine.clearAllCandidates()
        await drainMainQueue()
        XCTAssertNil(destination.panelAgentStates[panel])
        XCTAssertNil(destination.panelAgentStateSources[panel])
    }
}

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
