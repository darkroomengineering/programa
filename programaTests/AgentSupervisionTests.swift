import Combine
import XCTest

#if canImport(Programa_DEV)
@testable import Programa_DEV
#elseif canImport(Programa)
@testable import Programa
#endif

@MainActor
final class AgentSupervisionRegistryTests: XCTestCase {
    func testLifecycleKeepsTypedStateAndTimestamps() throws {
        let registry = AgentSupervisionRegistry(capacity: 4)
        let workspaceId = UUID()
        let startedAt = Date(timeIntervalSince1970: 100)
        let updatedAt = Date(timeIntervalSince1970: 110)
        let endedAt = Date(timeIntervalSince1970: 120)

        let started = try registry.start(
            host: "codex",
            task: "Review the API",
            role: "reviewer",
            placement: .nestedWorkspace,
            workspaceId: workspaceId,
            surfaceId: UUID(),
            now: startedAt
        )
        XCTAssertEqual(started.state, .working)
        XCTAssertTrue(started.hasIndependentOutput)

        let updated = try registry.update(id: started.id, state: .blocked, now: updatedAt)
        XCTAssertEqual(updated.state, .blocked)
        XCTAssertEqual(updated.startedAt, startedAt)
        XCTAssertEqual(updated.updatedAt, updatedAt)

        let finished = try registry.finish(id: started.id, state: .completed, now: endedAt)
        XCTAssertEqual(finished.state, .completed)
        XCTAssertEqual(finished.endedAt, endedAt)
    }

    func testFinishRecordsTheReportAndFinalTaskWithoutLosingTheRole() throws {
        let registry = AgentSupervisionRegistry(capacity: 4)
        let started = try registry.start(
            host: "claude",
            task: "planner",
            role: "planner",
            placement: .runsWithParent,
            workspaceId: UUID()
        )
        XCTAssertNil(started.summary)

        let finished = try registry.finish(id: started.id, task: "Plan the sidebar cut", summary: "Found 3 call sites.")
        XCTAssertEqual(finished.task, "Plan the sidebar cut")
        XCTAssertEqual(finished.role, "planner")
        XCTAssertEqual(finished.summary, "Found 3 call sites.")
        XCTAssertEqual(finished.payload()["summary"] as? String, "Found 3 call sites.")
    }

    func testDiscardFinishedHelpersClearsOnlyThatWorkspacesFinishedInProcessHelpers() throws {
        let registry = AgentSupervisionRegistry(capacity: 8)
        let workspaceId = UUID()
        let otherWorkspaceId = UUID()
        func start(_ state: AgentTaskState, in workspace: UUID, placement: AgentTaskPlacement = .runsWithParent) throws -> AgentTaskRecord {
            try registry.start(host: "claude", state: state, placement: placement, workspaceId: workspace)
        }
        let running = try start(.working, in: workspaceId)
        _ = try start(.failed, in: workspaceId)
        _ = try start(.completed, in: workspaceId)
        let spawned = try start(.completed, in: workspaceId, placement: .nestedWorkspace)
        let elsewhere = try start(.completed, in: otherWorkspaceId)
        XCTAssertEqual(registry.finishedHelperCounts, [workspaceId: 2, otherWorkspaceId: 1])

        XCTAssertEqual(registry.discardFinishedHelpers(workspaceId: workspaceId), 2)
        XCTAssertEqual(Set(registry.records().map(\.id)), [running.id, spawned.id, elsewhere.id])
        XCTAssertEqual(registry.finishedHelperCounts, [otherWorkspaceId: 1])
        XCTAssertEqual(registry.discardFinishedHelpers(workspaceId: workspaceId), 0)
    }

    func testRunsWithParentNeverClaimsIndependentOutput() throws {
        let registry = AgentSupervisionRegistry(capacity: 2)
        let record = try registry.start(
            host: "claude",
            placement: .runsWithParent,
            workspaceId: UUID(),
            surfaceId: UUID()
        )

        XCTAssertFalse(record.hasIndependentOutput)
        XCTAssertEqual(record.payload()["output_location"] as? String, "runs_with_parent")
    }

    func testCapacityEvictsFinishedRecordBeforeOlderRunningWork() throws {
        let registry = AgentSupervisionRegistry(capacity: 2)
        let workspaceId = UUID()
        let running = try registry.start(
            host: "codex",
            placement: .runsWithParent,
            workspaceId: workspaceId,
            now: Date(timeIntervalSince1970: 1)
        )
        let finished = try registry.start(
            host: "codex",
            state: .completed,
            placement: .runsWithParent,
            workspaceId: workspaceId,
            now: Date(timeIntervalSince1970: 2)
        )
        let newest = try registry.start(
            host: "codex",
            placement: .runsWithParent,
            workspaceId: workspaceId,
            now: Date(timeIntervalSince1970: 3)
        )

        XCTAssertNotNil(registry.record(id: running.id))
        XCTAssertNil(registry.record(id: finished.id))
        XCTAssertNotNil(registry.record(id: newest.id))
        XCTAssertEqual(registry.records().count, 2)
    }

    func testCapacityNeverEvictsActiveHelpers() throws {
        let registry = AgentSupervisionRegistry(capacity: 1)
        let active = try registry.start(
            host: "codex",
            placement: .runsWithParent,
            workspaceId: UUID()
        )

        XCTAssertThrowsError(try registry.start(
            host: "claude",
            placement: .runsWithParent,
            workspaceId: UUID()
        )) { error in
            XCTAssertEqual(error as? AgentSupervisionRegistryError, .capacityReached)
        }
        XCTAssertEqual(registry.record(id: active.id)?.state, .working)
    }

    func testFullRegistryEvictsOldestUnfinishedRecordOfAClosedWorkspace() throws {
        let liveWorkspaceId = UUID()
        let registry = AgentSupervisionRegistry(capacity: 3) { $0 == liveWorkspaceId }
        let live = try registry.start(
            host: "codex",
            placement: .runsWithParent,
            workspaceId: liveWorkspaceId,
            now: Date(timeIntervalSince1970: 0)
        )
        let dead = try (1...2).map { second in
            try registry.start(
                host: "codex",
                placement: .runsWithParent,
                workspaceId: UUID(),
                now: Date(timeIntervalSince1970: TimeInterval(second))
            )
        }

        let newest = try registry.start(host: "claude", placement: .runsWithParent, workspaceId: liveWorkspaceId)
        _ = try registry.start(host: "claude", placement: .runsWithParent, workspaceId: liveWorkspaceId)

        XCTAssertNil(registry.record(id: dead[0].id))
        XCTAssertNil(registry.record(id: dead[1].id))
        XCTAssertEqual(registry.record(id: live.id)?.state, .working)
        XCTAssertNotNil(registry.record(id: newest.id))
        XCTAssertThrowsError(try registry.start(host: "claude", placement: .runsWithParent, workspaceId: liveWorkspaceId)) { error in
            XCTAssertEqual(error as? AgentSupervisionRegistryError, .capacityReached)
        }
    }

    func testSweepPrunesRecordsOfAClosedWorkspace() throws {
        let manager = TabManager()
        guard let kept = manager.selectedWorkspace else {
            return XCTFail("Expected selected workspace")
        }
        let closed = manager.addWorkspace(select: true)
        let registry = AgentSupervisionRegistry.shared
        let keptHelper = try registry.start(host: "codex", placement: .runsWithParent, workspaceId: kept.id)
        let closedHelper = try registry.start(host: "codex", placement: .runsWithParent, workspaceId: closed.id)
        defer { [keptHelper, closedHelper].forEach { registry.discard(id: $0.id) } }

        manager.closeWorkspace(closed)
        manager.sweepStaleAgentPIDsForTesting()

        XCTAssertNil(registry.record(id: closedHelper.id))
        XCTAssertNil(registry.runningHelperCounts[closed.id])
        XCTAssertEqual(registry.record(id: keptHelper.id)?.state, .working)
    }

    func testMovingWorkspaceWithoutSurfaceClearsOldSurface() throws {
        let originalWorkspace = UUID()
        let nextWorkspace = UUID()
        let registry = AgentSupervisionRegistry(capacity: 2)
        let started = try registry.start(
            host: "codex",
            placement: .nestedWorkspace,
            workspaceId: originalWorkspace,
            surfaceId: UUID()
        )

        let moved = try registry.update(id: started.id, workspaceId: nextWorkspace)

        XCTAssertEqual(moved.workspaceId, nextWorkspace)
        XCTAssertNil(moved.surfaceId)
        XCTAssertFalse(moved.hasIndependentOutput)
    }

    func testSessionFinishCancelsOnlyMatchingActiveHelpers() throws {
        let registry = AgentSupervisionRegistry(capacity: 4)
        let workspaceId = UUID()
        let matching = try registry.start(
            host: "claude",
            session: "session-one",
            placement: .runsWithParent,
            workspaceId: workspaceId
        )
        let other = try registry.start(
            host: "claude",
            session: "session-two",
            placement: .runsWithParent,
            workspaceId: workspaceId
        )

        let finished = try registry.finishSession(host: "claude", session: "session-one")

        XCTAssertEqual(finished.map(\.id), [matching.id])
        XCTAssertEqual(registry.record(id: matching.id)?.state, .cancelled)
        XCTAssertEqual(registry.record(id: other.id)?.state, .working)
    }

    func testRunningHelperCountsTrackOnlyUnfinishedInProcessHelpers() throws {
        let registry = AgentSupervisionRegistry(capacity: 8)
        let workspaceId = UUID()
        let otherWorkspaceId = UUID()
        let first = try registry.start(host: "claude", session: "s1", placement: .runsWithParent, workspaceId: workspaceId)
        _ = try registry.start(host: "claude", session: "s1", placement: .runsWithParent, workspaceId: workspaceId)
        _ = try registry.start(host: "codex", placement: .nestedWorkspace, workspaceId: workspaceId)
        _ = try registry.start(host: "claude", session: "s2", placement: .runsWithParent, workspaceId: otherWorkspaceId)
        XCTAssertEqual(registry.runningHelperCounts, [workspaceId: 2, otherWorkspaceId: 1])

        try registry.finish(id: first.id)
        XCTAssertEqual(registry.runningHelperCounts[workspaceId], 1)

        _ = try registry.finishSession(host: "claude", session: "s1")
        XCTAssertNil(registry.runningHelperCounts[workspaceId])
        XCTAssertEqual(registry.runningHelperCounts, [otherWorkspaceId: 1])
    }

    func testCountPublishesOnlyWhenItChanges() throws {
        let registry = AgentSupervisionRegistry(capacity: 4)
        let workspaceId = UUID()
        var publishCount = 0
        let subscription = registry.objectWillChange.sink { publishCount += 1 }
        defer { subscription.cancel() }

        let helper = try registry.start(host: "claude", placement: .runsWithParent, workspaceId: workspaceId)
        XCTAssertEqual(publishCount, 1)
        _ = try registry.update(id: helper.id, state: .blocked)
        _ = try registry.update(id: helper.id, state: .working)
        XCTAssertEqual(publishCount, 1, "state changes that keep the helper running must not re-render the sidebar")
        try registry.finish(id: helper.id)
        XCTAssertEqual(publishCount, 2)
    }

    func testDeadParentPidFinishesItsHelpersAndClearsTheCount() throws {
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
        XCTAssertEqual(errno, ESRCH, "fixture precondition: deadPid must already be gone")

        let parentPanelId = UUID()
        workspace.updatePanelAgentState(
            panelId: parentPanelId,
            state: .idle,
            source: .hooks,
            sessionKey: AgentSessionKey(provider: "claude-code", sessionId: "parent-session", pid: deadPid)
        )
        let registry = AgentSupervisionRegistry.shared
        let helpers = try (0..<2).map { _ in
            try registry.start(
                host: "claude",
                session: "parent-session",
                placement: .runsWithParent,
                workspaceId: workspace.id,
                surfaceId: parentPanelId
            )
        }
        defer { helpers.forEach { registry.discard(id: $0.id) } }
        XCTAssertEqual(registry.runningHelperCounts[workspace.id], 2)

        manager.sweepStaleAgentPIDsForTesting()

        XCTAssertNil(registry.runningHelperCounts[workspace.id])
        XCTAssertEqual(helpers.map { registry.record(id: $0.id)?.state }, [.cancelled, .cancelled])
    }

    func testSurfaceTeardownFinishesSpawnedHelperButNotSharedHelper() throws {
        let registry = AgentSupervisionRegistry(capacity: 4)
        let workspaceId = UUID()
        let surfaceId = UUID()
        let spawned = try registry.start(
            host: "codex",
            placement: .nestedWorkspace,
            workspaceId: workspaceId,
            surfaceId: surfaceId
        )
        let shared = try registry.start(
            host: "claude",
            placement: .runsWithParent,
            workspaceId: workspaceId,
            surfaceId: surfaceId
        )

        let finished = try registry.finishActiveSurface(
            workspaceId: workspaceId,
            surfaceId: surfaceId
        )

        XCTAssertEqual(finished.map(\.id), [spawned.id])
        XCTAssertEqual(registry.record(id: spawned.id)?.state, .completed)
        XCTAssertEqual(registry.record(id: shared.id)?.state, .working)
    }

    func testConcreteHelperCanMoveFromIdleBackToWorking() throws {
        let registry = AgentSupervisionRegistry(capacity: 2)
        let workspaceId = UUID()
        let surfaceId = UUID()
        let helper = try registry.start(
            host: "codex",
            placement: .nestedWorkspace,
            workspaceId: workspaceId,
            surfaceId: surfaceId
        )

        _ = try registry.updateActiveSurface(
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            state: .idle
        )
        XCTAssertEqual(registry.record(id: helper.id)?.state, .idle)
        _ = try registry.updateActiveSurface(
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            state: .working
        )

        XCTAssertEqual(registry.record(id: helper.id)?.state, .working)
    }

    func testAggregateTaskStateUsesOneWorstFirstRule() throws {
        let registry = AgentSupervisionRegistry(capacity: 8)
        let workspace = Workspace()

        func aggregate() -> AgentTaskState? {
            AgentSupervisionMetadata.aggregateTaskState(
                for: workspace,
                records: registry.records(workspaceIds: [workspace.id])
            )
        }

        XCTAssertNil(aggregate())
        let statesInIncreasingPriority: [AgentTaskState] = [
            .completed, .idle, .cancelled, .failed, .working,
        ]
        for state in statesInIncreasingPriority {
            _ = try registry.start(
                host: "codex",
                state: state,
                placement: .runsWithParent,
                workspaceId: workspace.id
            )
            XCTAssertEqual(aggregate(), state)
            XCTAssertEqual(AgentSupervisionMetadata.aggregateState(
                for: workspace,
                records: registry.records(workspaceIds: [workspace.id])
            ), state.rawValue)
        }

        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        workspace.updatePanelAgentState(panelId: panelId, state: .blocked)
        XCTAssertEqual(aggregate(), .blocked)
    }

    /// Verifies `aggregateTaskState` reads agent activity state through the
    /// `ProgramaCore` seam (`docs/plans/core-seam.md`) rather than reading
    /// `Workspace.aggregateAgentState` directly: a fake core reports a state
    /// the real workspace does not have, and that fake's answer -- not the
    /// workspace's real (empty) state -- must be what wins the worst-first
    /// aggregation.
    func testAggregateTaskStateReadsAgentActivityThroughCoreSeam() throws {
        let registry = AgentSupervisionRegistry(capacity: 8)
        let workspace = Workspace()
        // The real workspace has no hook-managed agent state at all.
        XCTAssertNil(workspace.aggregateAgentState)

        let fakeAgentActivity = FakeAgentActivityReporting(stubbedState: .blocked)
        let fakeCore = FakeProgramaCore(agentActivity: fakeAgentActivity)
        let result = AgentSupervisionMetadata.aggregateTaskState(
            for: workspace,
            records: registry.records(workspaceIds: [workspace.id]),
            core: fakeCore
        )

        XCTAssertEqual(result, .blocked)
        XCTAssertEqual(fakeAgentActivity.recordedWorkspaceIds, [workspace.id])
    }
}

/// Records every seam call it receives instead of touching real
/// subprocesses/sockets/AppKit state -- see `docs/plans/core-seam.md`.
private final class FakeProgramaCore: ProgramaCoreProviding {
    let git: ProgramaCore.GitMetadataProbing = FakeGitMetadataProbe()
    let ports: ProgramaCore.PortScanning = FakePortScanning()
    let sessionSnapshots: ProgramaCore.SessionSnapshotting = FakeSessionSnapshotting()
    let agentActivity: ProgramaCore.AgentActivityReporting

    init(agentActivity: ProgramaCore.AgentActivityReporting) {
        self.agentActivity = agentActivity
    }
}

private final class FakeAgentActivityReporting: ProgramaCore.AgentActivityReporting {
    let stubbedState: AgentActivityState?
    private(set) var recordedWorkspaceIds: [UUID] = []

    init(stubbedState: AgentActivityState?) {
        self.stubbedState = stubbedState
    }

    @MainActor
    func aggregateState(for workspace: Workspace) -> AgentActivityState? {
        recordedWorkspaceIds.append(workspace.id)
        return stubbedState
    }
}

private struct FakeGitMetadataProbe: ProgramaCore.GitMetadataProbing {
    func probeInitialWorkspaceGitMetadata(
        directory: String
    ) -> GitMetadataProber.InitialWorkspaceGitMetadataSnapshot {
        GitMetadataProber.InitialWorkspaceGitMetadataSnapshot(
            branch: nil,
            isDirty: false,
            pullRequest: .notFound
        )
    }
}

private struct FakePortScanning: ProgramaCore.PortScanning {
    func registerTTY(workspaceId: UUID, panelId: UUID, ttyName: String) {}
    func unregisterPanel(workspaceId: UUID, panelId: UUID) {}
    func kick(workspaceId: UUID, panelId: UUID) {}
    @MainActor func refreshAgentPorts(workspaceId: UUID, agentPIDs: Set<Int>) {}
}

private struct FakeSessionSnapshotting: ProgramaCore.SessionSnapshotting {
    func loadWithHistoryFallback() -> AppSessionSnapshot? { nil }
    func save(_ snapshot: AppSessionSnapshot) -> Bool { true }
}

@MainActor
final class AgentSupervisionCommandTests: XCTestCase {
    override func tearDown() {
        AgentSupervisionRegistry.shared.removeAll()
        super.tearDown()
    }

    func testSpawnCreatesUnfocusedNestedWorkspaceWithAutomaticTitle() {
        let controller = TerminalController.shared
        let originalManager = controller.tabManager
        let manager = TabManager(initialWorkingDirectory: "/tmp/programa-agent-parent")
        controller.tabManager = manager
        defer { controller.tabManager = originalManager }

        guard let parent = manager.selectedWorkspace else {
            return XCTFail("Expected the initial workspace")
        }
        let selectedBeforeSpawn = manager.selectedTabId
        let result = controller.v2AgentSpawn(params: [
            "parent_workspace_id": parent.id.uuidString,
            "host": "codex",
            "task": "Review ticket 42",
        ])

        guard case .ok(let rawPayload) = result,
              let payload = rawPayload as? [String: Any],
              let workspaceIdRaw = payload["workspace_id"] as? String,
              let workspaceId = UUID(uuidString: workspaceIdRaw),
              let child = manager.tabs.first(where: { $0.id == workspaceId }) else {
            return XCTFail("Expected a spawned child workspace")
        }
        XCTAssertEqual(manager.selectedTabId, selectedBeforeSpawn)
        XCTAssertEqual(child.agentParentWorkspaceId, parent.id)
        XCTAssertEqual(child.currentDirectory, parent.currentDirectory)
        XCTAssertEqual(child.title, "Review ticket 42")
        XCTAssertEqual(child.automaticAgentTitle, "Review ticket 42")
        XCTAssertNil(child.customTitle)
        XCTAssertNil(child.worktreeParentWorkspaceId)

        child.applyProcessTitle("codex shell")
        XCTAssertEqual(child.title, "Review ticket 42")
        child.setCustomTitle("Manual review")
        XCTAssertEqual(child.title, "Manual review")
        child.setCustomTitle(nil)
        XCTAssertEqual(child.title, "Review ticket 42")
    }

    func testSpawnRequiresExplicitWorktreeInputsForIsolation() {
        let controller = TerminalController.shared
        let result = controller.v2AgentSpawn(params: [
            "parent_workspace_id": UUID().uuidString,
            "needs_isolation": true,
        ])

        guard case .err(let code, let message, let data) = result else {
            return XCTFail("Expected isolation validation to fail")
        }
        XCTAssertEqual(code, "invalid_params")
        XCTAssertTrue(message.contains("repository_path and branch"))
        XCTAssertEqual((data as? [String: String])?["use_method"], "worktree.create")

        let originalManager = controller.tabManager
        let manager = TabManager(initialWorkingDirectory: "/tmp/programa-agent-isolation-parent")
        controller.tabManager = manager
        defer { controller.tabManager = originalManager }
        guard let parent = manager.selectedWorkspace else {
            return XCTFail("Expected the initial workspace")
        }
        let explicitResult = controller.v2AgentSpawn(params: [
            "parent_workspace_id": parent.id.uuidString,
            "needs_isolation": true,
            "repository_path": "/tmp/programa-agent-not-a-repository-\(UUID().uuidString)",
            "branch": "helper/review",
        ])
        guard case .err(let explicitCode, _, _) = explicitResult else {
            return XCTFail("Expected invalid repository validation")
        }
        XCTAssertEqual(explicitCode, "not_a_git_repo")
    }

    func testWorkspaceListIncludesHierarchyAndHelperMetadata() throws {
        let controller = TerminalController.shared
        let originalManager = controller.tabManager
        let manager = TabManager(initialWorkingDirectory: "/tmp/programa-agent-metadata")
        controller.tabManager = manager
        defer { controller.tabManager = originalManager }
        guard let workspace = manager.selectedWorkspace else {
            return XCTFail("Expected the initial workspace")
        }
        workspace.agentParentWorkspaceId = UUID()
        _ = try AgentSupervisionRegistry.shared.start(
            host: "codex",
            task: "Check metadata",
            placement: .runsWithParent,
            workspaceId: workspace.id
        )

        let result = controller.v2WorkspaceList(params: [:])
        guard case .ok(let rawPayload) = result,
              let payload = rawPayload as? [String: Any],
              let workspaces = payload["workspaces"] as? [[String: Any]],
              let summary = workspaces.first(where: { $0["id"] as? String == workspace.id.uuidString }) else {
            return XCTFail("Expected workspace metadata")
        }
        XCTAssertEqual(summary["current_directory"] as? String, workspace.currentDirectory)
        XCTAssertEqual(summary["agent_parent_workspace_id"] as? String, workspace.agentParentWorkspaceId?.uuidString)
        XCTAssertEqual(summary["agent_state"] as? String, AgentTaskState.working.rawValue)
        XCTAssertEqual(summary["agent_state_source"] as? String, "helpers")
        XCTAssertEqual(summary["helper_count"] as? Int, 1)
    }
}
