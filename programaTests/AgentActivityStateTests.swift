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

    // MARK: - T8: AgentPresence / SidebarAgentIndicator (agent-state-unification)

    /// Fixture mirroring `testFocusPanelDismissesUnreadNotificationWithDismissFlash`
    /// (TabManagerUnitTests.swift): wires a fresh `TabManager` and `TerminalNotificationStore.shared`
    /// through `AppDelegate.shared` and marks the app focused, since
    /// `dismissNotificationOnDirectInteraction` requires both a selected workspace and an
    /// active app to do anything.
    private func makeNotificationFixture() throws -> (manager: TabManager, workspace: Workspace, panelId: UUID, cleanup: () -> Void) {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = TabManager()
        let store = TerminalNotificationStore.shared

        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        let originalAppFocusOverride = AppFocusState.overrideIsFocused

        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, _ in }
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store
        AppFocusState.overrideIsFocused = true

        let cleanup = {
            store.replaceNotificationsForTesting([])
            store.resetNotificationDeliveryHandlerForTesting()
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
            AppFocusState.overrideIsFocused = originalAppFocusOverride
        }

        // Notify the pane that is NOT focused: for the focused pane the store suppresses
        // external delivery and sets the focused-read indicator instead, which is a different
        // path from the "agent asks in a background pane" case these tests model.
        guard let workspace = manager.selectedWorkspace,
              let focusedPanelId = workspace.focusedPanelId,
              let rightPanel = workspace.newTerminalSplit(from: focusedPanelId, orientation: .horizontal) else {
            cleanup()
            XCTFail("Expected split terminal panels")
            throw XCTSkip("fixture setup failed")
        }
        workspace.focusPanel(rightPanel.id)
        return (manager, workspace, focusedPanelId, cleanup)
    }

    /// Models what `agent.needs_input` does in one hop (docs/plans/agent-state-unification.md
    /// T2/T8 item 1): write blocked presence with `.hooks` source and a session key, then post
    /// exactly one unread notification for the same surface. Exercised directly against the
    /// presence/notification seams since the socket handler itself has no unit-test harness.
    func testAgentNeedsInputWritesBlockedPresenceAndSingleNotification() throws {
        let fixture = try makeNotificationFixture()
        defer { fixture.cleanup() }
        let sessionKey = AgentSessionKey(provider: "claude-code", sessionId: "sess-1", pid: nil)

        fixture.workspace.updatePanelAgentState(panelId: fixture.panelId, state: .blocked, source: .hooks, sessionKey: sessionKey)
        TerminalNotificationStore.shared.addNotification(
            tabId: fixture.workspace.id,
            surfaceId: fixture.panelId,
            title: "Needs input",
            subtitle: "",
            body: "Approve this tool call?"
        )

        XCTAssertEqual(fixture.workspace.panelAgentPresence[fixture.panelId]?.state, .blocked)
        XCTAssertEqual(fixture.workspace.panelAgentPresence[fixture.panelId]?.source, .hooks)
        XCTAssertEqual(fixture.workspace.panelAgentPresence[fixture.panelId]?.sessionKey, sessionKey)
        XCTAssertEqual(TerminalNotificationStore.shared.unreadCount(forTabId: fixture.workspace.id), 1)
        XCTAssertTrue(TerminalNotificationStore.shared.hasUnreadNotification(forTabId: fixture.workspace.id, surfaceId: fixture.panelId))

        let indicator = SidebarAgentIndicator.make(for: fixture.workspace, now: Date())
        XCTAssertEqual(indicator?.systemImage, "exclamationmark.circle.fill")
        XCTAssertEqual(indicator?.tint, .blocked)
        XCTAssertEqual(indicator?.label, String(localized: "sidebar.agentIndicator.needsInput", defaultValue: "Needs input"))
        XCTAssertFalse(indicator?.isStale ?? true)

        XCTAssertNil(fixture.workspace.statusEntries["claude_code"])
    }

    /// TabItemView.swift's row-click path and `dismissNotificationOnDirectInteraction` both
    /// carry a comment saying focus must never clear `panelAgentPresence` -- verify the
    /// behavior the comment promises, not just its presence.
    func testDismissNotificationOnDirectInteractionClearsUnreadButKeepsBlockedPresence() throws {
        let fixture = try makeNotificationFixture()
        defer { fixture.cleanup() }
        let sessionKey = AgentSessionKey(provider: "claude-code", sessionId: "sess-1", pid: nil)
        fixture.workspace.updatePanelAgentState(panelId: fixture.panelId, state: .blocked, source: .hooks, sessionKey: sessionKey)
        TerminalNotificationStore.shared.addNotification(
            tabId: fixture.workspace.id,
            surfaceId: fixture.panelId,
            title: "Needs input",
            subtitle: "",
            body: "Approve this tool call?"
        )
        XCTAssertEqual(TerminalNotificationStore.shared.unreadCount(forTabId: fixture.workspace.id), 1)

        let dismissed = fixture.manager.dismissNotificationOnDirectInteraction(tabId: fixture.workspace.id, surfaceId: fixture.panelId)
        XCTAssertTrue(dismissed)
        XCTAssertEqual(TerminalNotificationStore.shared.unreadCount(forTabId: fixture.workspace.id), 0)

        XCTAssertEqual(fixture.workspace.panelAgentPresence[fixture.panelId]?.state, .blocked)
        XCTAssertEqual(fixture.workspace.panelAgentPresence[fixture.panelId]?.source, .hooks)
        let indicator = SidebarAgentIndicator.make(for: fixture.workspace, now: Date())
        XCTAssertEqual(indicator?.label, String(localized: "sidebar.agentIndicator.needsInput", defaultValue: "Needs input"))
    }

    /// A hook reporting `working` after `blocked` (the pre-tool-use / Stop / turn.completed
    /// resume path) must clear blocked while keeping the `.hooks` source, per the clearing
    /// rules in section 3 of the plan.
    func testWorkingReportAfterBlockedClearsBlockedKeepsHooksSource() {
        let workspace = Workspace(title: "Test")
        let panelId = UUID()
        let sessionKey = AgentSessionKey(provider: "claude-code", sessionId: "sess-2", pid: nil)

        workspace.updatePanelAgentState(panelId: panelId, state: .blocked, source: .hooks, sessionKey: sessionKey)
        workspace.updatePanelAgentState(panelId: panelId, state: .working, source: .hooks)

        XCTAssertEqual(workspace.panelAgentPresence[panelId]?.state, .working)
        XCTAssertEqual(workspace.panelAgentPresence[panelId]?.source, .hooks)
        let indicator = SidebarAgentIndicator.make(for: workspace, now: Date())
        XCTAssertEqual(indicator?.tint, .working)
        XCTAssertEqual(indicator?.label, String(localized: "sidebar.agentIndicator.working", defaultValue: "Working"))
    }

    /// `agent.event` `session.exited` calls `clearPanelAgentState` -- the indicator must
    /// disappear entirely (no badge), not degrade to idle.
    func testClearPanelAgentStateRemovesIndicatorEntirely() {
        let workspace = Workspace(title: "Test")
        let panelId = UUID()

        workspace.updatePanelAgentState(panelId: panelId, state: .blocked, source: .hooks)
        XCTAssertNotNil(SidebarAgentIndicator.make(for: workspace, now: Date()))

        workspace.clearPanelAgentState(panelId: panelId)

        XCTAssertNil(workspace.panelAgentPresence[panelId])
        XCTAssertNil(SidebarAgentIndicator.make(for: workspace, now: Date()))
    }

    /// Staleness (plan section 1's `isStale`, threshold 600s): a presence untouched for 11
    /// minutes reads stale with a suffixed label for both non-idle states; idle never goes
    /// stale, since it's already the resting value.
    func testStalePresenceReportsStaleAndSuffixesLabelForNonIdleStates() {
        let workspace = Workspace(title: "Test")
        let blockedPanelId = UUID()
        let workingPanelId = UUID()
        let idlePanelId = UUID()
        let now = Date()
        let elevenMinutesAgo = now.addingTimeInterval(-660)

        workspace.updatePanelAgentState(panelId: blockedPanelId, state: .blocked, source: .hooks, at: elevenMinutesAgo)
        XCTAssertTrue(workspace.panelAgentPresence[blockedPanelId]!.isStale(now: now))
        let blockedIndicator = SidebarAgentIndicator.make(for: workspace, now: now)
        XCTAssertTrue(blockedIndicator?.isStale ?? false)
        XCTAssertEqual(
            blockedIndicator?.label,
            String(localized: "sidebar.agentIndicator.needsInputStale", defaultValue: "Needs input (stale)")
        )
        workspace.clearPanelAgentState(panelId: blockedPanelId)

        workspace.updatePanelAgentState(panelId: workingPanelId, state: .working, source: .hooks, at: elevenMinutesAgo)
        let workingIndicator = SidebarAgentIndicator.make(for: workspace, now: now)
        XCTAssertTrue(workingIndicator?.isStale ?? false)
        XCTAssertEqual(
            workingIndicator?.label,
            String(localized: "sidebar.agentIndicator.workingStale", defaultValue: "Working (stale)")
        )
        workspace.clearPanelAgentState(panelId: workingPanelId)

        workspace.updatePanelAgentState(panelId: idlePanelId, state: .idle, source: .hooks, at: elevenMinutesAgo)
        XCTAssertFalse(workspace.panelAgentPresence[idlePanelId]!.isStale(now: now))
        let idleIndicator = SidebarAgentIndicator.make(for: workspace, now: now)
        XCTAssertFalse(idleIndicator?.isStale ?? true)
        XCTAssertEqual(idleIndicator?.label, String(localized: "sidebar.agentIndicator.idle", defaultValue: "Idle"))
    }

    /// A repeated identical (state, source) write only refreshes `lastEventAt` (see the
    /// "same state from the same writer" branch in `updatePanelAgentState`) -- a long-running
    /// agent that keeps reporting the same state must not read as stale at the threshold.
    func testRepeatedIdenticalWriteRefreshesStalenessClock() {
        let workspace = Workspace(title: "Test")
        let panelId = UUID()
        let now = Date()
        let elevenMinutesAgo = now.addingTimeInterval(-660)

        workspace.updatePanelAgentState(panelId: panelId, state: .blocked, source: .hooks, at: elevenMinutesAgo)
        XCTAssertTrue(workspace.panelAgentPresence[panelId]!.isStale(now: now))

        workspace.updatePanelAgentState(panelId: panelId, state: .blocked, source: .hooks, at: now)
        XCTAssertFalse(workspace.panelAgentPresence[panelId]!.isStale(now: now))
    }

    /// Watchdog (plan section 4): `sweepStaleAgentPIDsForTesting` (test seam added to
    /// TabManager+GitMetadataPolling.swift) clears presence whose reported pid has exited,
    /// and leaves presence whose pid is still alive untouched.
    func testWatchdogClearsPresenceForDeadPidAndKeepsAlivePresence() throws {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace else {
            XCTFail("Expected selected workspace")
            return
        }

        let deadProcess = Process()
        deadProcess.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try deadProcess.run()
        deadProcess.waitUntilExit()
        let deadPid = deadProcess.processIdentifier
        errno = 0
        XCTAssertEqual(kill(deadPid, 0), -1)
        XCTAssertEqual(errno, ESRCH, "fixture precondition: deadPid must already be gone, or this test proves nothing")

        let deadPanelId = UUID()
        let alivePanelId = UUID()
        workspace.updatePanelAgentState(
            panelId: deadPanelId,
            state: .working,
            source: .hooks,
            sessionKey: AgentSessionKey(provider: "claude-code", sessionId: nil, pid: deadPid)
        )
        workspace.updatePanelAgentState(
            panelId: alivePanelId,
            state: .working,
            source: .hooks,
            sessionKey: AgentSessionKey(provider: "claude-code", sessionId: nil, pid: getpid())
        )

        manager.sweepStaleAgentPIDsForTesting()

        XCTAssertNil(workspace.panelAgentPresence[deadPanelId])
        XCTAssertEqual(workspace.panelAgentPresence[alivePanelId]?.state, .working)
        XCTAssertEqual(workspace.panelAgentPresence[alivePanelId]?.sessionKey?.pid, getpid())
    }

    /// Hooks-win guard: an `.inferred` write against a `.hooks`-owned surface is dropped
    /// outright, and critically does not even move `lastEventAt` -- the staleness clock keeps
    /// ticking from the last real hook event. `.inferred` writes also never carry a session key,
    /// even on a fresh (non-hooks) surface, since there is no session to key on.
    func testInferredWriteAgainstHooksPresenceIsDroppedAndNeverCarriesSessionKey() {
        let workspace = Workspace(title: "Test")
        let hooksPanelId = UUID()
        let now = Date()
        let sessionKey = AgentSessionKey(provider: "claude-code", sessionId: "sess-3", pid: nil)

        workspace.updatePanelAgentState(panelId: hooksPanelId, state: .working, source: .hooks, sessionKey: sessionKey, at: now)
        let originalLastEventAt = workspace.panelAgentPresence[hooksPanelId]!.lastEventAt

        workspace.updatePanelAgentState(panelId: hooksPanelId, state: .blocked, source: .inferred, at: now.addingTimeInterval(5))

        XCTAssertEqual(workspace.panelAgentPresence[hooksPanelId]?.state, .working)
        XCTAssertEqual(workspace.panelAgentPresence[hooksPanelId]?.source, .hooks)
        XCTAssertEqual(workspace.panelAgentPresence[hooksPanelId]?.lastEventAt, originalLastEventAt)
        XCTAssertEqual(workspace.panelAgentPresence[hooksPanelId]?.sessionKey, sessionKey)

        let freshPanelId = UUID()
        workspace.updatePanelAgentState(panelId: freshPanelId, state: .working, source: .inferred, sessionKey: sessionKey, at: now)
        XCTAssertNil(workspace.panelAgentPresence[freshPanelId]?.sessionKey)
    }

    /// Aggregation (worst-first): a blocked surface wins the workspace-level indicator over an
    /// idle one, and the stale flag reflects only the winning surface's own staleness, not any
    /// other surface's.
    func testAggregationPicksBlockedOverIdleAndStaleFlagFollowsWinnerOnly() {
        let workspace = Workspace(title: "Test")
        let idlePanelId = UUID()
        let blockedPanelId = UUID()
        let now = Date()
        let elevenMinutesAgo = now.addingTimeInterval(-660)

        workspace.updatePanelAgentState(panelId: idlePanelId, state: .idle, source: .hooks, at: now)
        workspace.updatePanelAgentState(panelId: blockedPanelId, state: .blocked, source: .hooks, at: elevenMinutesAgo)

        let staleIndicator = SidebarAgentIndicator.make(for: workspace, now: now)
        XCTAssertEqual(staleIndicator?.tint, .blocked)
        XCTAssertTrue(staleIndicator?.isStale ?? false)
        XCTAssertEqual(
            staleIndicator?.label,
            String(localized: "sidebar.agentIndicator.needsInputStale", defaultValue: "Needs input (stale)")
        )

        // Refresh the winning (blocked) surface only; the idle surface stays untouched (idle
        // never goes stale regardless). The indicator must flip back to non-stale.
        workspace.updatePanelAgentState(panelId: blockedPanelId, state: .blocked, source: .hooks, at: now)
        let freshIndicator = SidebarAgentIndicator.make(for: workspace, now: now)
        XCTAssertEqual(freshIndicator?.tint, .blocked)
        XCTAssertFalse(freshIndicator?.isStale ?? true)
    }
}
