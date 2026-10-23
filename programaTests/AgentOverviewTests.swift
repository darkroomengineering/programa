import XCTest

#if canImport(Programa_DEV)
@testable import Programa_DEV
#elseif canImport(Programa)
@testable import Programa
#endif

final class AgentOverviewHierarchyTests: XCTestCase {
    func testWorktreeFolderScopeIncludesWorktreesAndNestedHelpers() {
        let folder = UUID()
        let worktree = UUID()
        let helper = UUID()
        let unrelated = UUID()
        let nodes = [
            AgentOverviewHierarchyNode(
                id: folder,
                worktreeParentId: nil,
                agentParentId: nil,
                isWorktreeFolder: true
            ),
            AgentOverviewHierarchyNode(
                id: worktree,
                worktreeParentId: folder,
                agentParentId: nil,
                isWorktreeFolder: false
            ),
            AgentOverviewHierarchyNode(
                id: helper,
                worktreeParentId: nil,
                agentParentId: worktree,
                isWorktreeFolder: false
            ),
            AgentOverviewHierarchyNode(
                id: unrelated,
                worktreeParentId: nil,
                agentParentId: nil,
                isWorktreeFolder: false
            ),
        ]

        XCTAssertEqual(
            AgentOverviewHierarchy.scopedIds(nodes, rootId: folder),
            [folder, worktree, helper]
        )
    }

    func testNormalWorkspaceScopeIncludesOnlyItsAgentDescendants() {
        let workspace = UUID()
        let helper = UUID()
        let worktree = UUID()
        let nodes = [
            AgentOverviewHierarchyNode(
                id: workspace,
                worktreeParentId: nil,
                agentParentId: nil,
                isWorktreeFolder: false
            ),
            AgentOverviewHierarchyNode(
                id: helper,
                worktreeParentId: nil,
                agentParentId: workspace,
                isWorktreeFolder: false
            ),
            AgentOverviewHierarchyNode(
                id: worktree,
                worktreeParentId: workspace,
                agentParentId: nil,
                isWorktreeFolder: false
            ),
        ]

        XCTAssertEqual(
            AgentOverviewHierarchy.scopedIds(nodes, rootId: workspace),
            [workspace, helper]
        )
    }
}

final class AgentOverviewPresentationTests: XCTestCase {
    func testFilteringPreservesDefaultHierarchyAndMatchesChildrenWithinWorkspaceContext() {
        let terminal = AgentOverviewTerminalSnapshot(id: UUID(), title: "Compiler", state: .needsInput)
        let helper = AgentOverviewHelperSnapshot(id: UUID(), title: "Reviewer", state: .failed,
                                                surfaceId: nil, hasIndependentOutput: false,
                                                runsWithParent: true, depth: 1)
        let workspace = AgentOverviewWorkspaceSnapshot(id: UUID(), title: "Pokefolio", state: .working,
                                                      branchOrPullRequest: nil, folder: "repo", depth: 2,
                                                      terminals: [terminal], helpers: [helper])
        let windows = [AgentOverviewWindowSnapshot(id: UUID(), index: 0, workspaces: [workspace])]
        XCTAssertEqual(AgentOverviewFilter.all.apply(to: windows, search: "  "), windows)

        let attention = AgentOverviewFilter.needsInput.apply(to: windows, search: " POKE ")
        XCTAssertEqual(attention.first?.workspaces.first?.terminals, [terminal])
        XCTAssertEqual(attention.first?.workspaces.first?.helpers, [])
        let failures = AgentOverviewFilter.failed.apply(to: windows, search: "reviewer")
        XCTAssertEqual(failures.first?.workspaces.first?.helpers, [helper])
        XCTAssertEqual(failures.first?.workspaces.first?.terminals, [])
        XCTAssertTrue(AgentOverviewFilter.all.apply(to: windows, search: "unmatched").isEmpty)
    }

    func testHelpersMatchSearchByAgentTypeAndOnlyDoneOrStoppedOnesFold() {
        let startedAt = Date(timeIntervalSince1970: 1_000)
        func helper(_ title: String, _ state: AgentOverviewFriendlyState, endedAt: Date? = nil) -> AgentOverviewHelperSnapshot {
            AgentOverviewHelperSnapshot(id: UUID(), title: title, state: state, surfaceId: nil,
                                        hasIndependentOutput: false, runsWithParent: true, depth: 0,
                                        role: "implementer", startedAt: startedAt, endedAt: endedAt)
        }
        let running = helper("Fix restore race", .working)
        let done = helper("Plan sidebar cut", .done, endedAt: startedAt.addingTimeInterval(220))
        let failed = helper("Port the parser", .failed, endedAt: startedAt.addingTimeInterval(5))
        let workspace = AgentOverviewWorkspaceSnapshot(id: UUID(), title: "Programa", state: .working,
                                                      branchOrPullRequest: nil, folder: "repo", depth: 0,
                                                      terminals: [], helpers: [running, done, failed])
        let windows = [AgentOverviewWindowSnapshot(id: UUID(), index: 0, workspaces: [workspace])]

        XCTAssertEqual(AgentOverviewFilter.all.apply(to: windows, search: "IMPLEMENTER").first?.workspaces.first?.helpers,
                       [running, done, failed])
        XCTAssertEqual([running, done, failed].map(\.isSettled), [false, true, false])
        XCTAssertEqual(done.duration(now: startedAt.addingTimeInterval(9_999)), 220)
        XCTAssertEqual(running.duration(now: startedAt.addingTimeInterval(72)), 72)
    }

    func testTaskStatesUsePlainUserFacingLabels() {
        XCTAssertEqual(AgentOverviewFriendlyState.from(activityState: nil).label, "Idle")
        XCTAssertEqual(AgentOverviewFriendlyState.from(taskState: .working).label, "Working")
        XCTAssertEqual(AgentOverviewFriendlyState.from(taskState: .blocked).label, "Needs input")
        XCTAssertEqual(AgentOverviewFriendlyState.from(taskState: .completed).label, "Done")
        XCTAssertEqual(AgentOverviewFriendlyState.from(taskState: .cancelled).label, "Stopped")
        XCTAssertEqual(AgentOverviewFriendlyState.from(taskState: .failed).label, "Failed")
    }

    func testFolderPresentationKeepsOnlyTheUsefulTail() {
        XCTAssertEqual(
            AgentOverviewFormatting.shortenedFolder("/Users/example/Developer/programa"),
            "…/Developer/programa"
        )
    }
}

final class AgentOverviewOutputGateTests: XCTestCase {
    func testRunsWithParentHelperNeverEnablesOutput() {
        let workspaceId = UUID()
        let helperId = UUID()
        var gate = AgentOverviewOutputGate()
        gate.isWindowVisible = true
        gate.select(
            .helper(
                workspaceId: workspaceId,
                helperId: helperId,
                surfaceId: UUID(),
                hasIndependentOutput: false
            )
        )
        gate.showOutput()

        XCTAssertFalse(gate.isOutputVisible)
        XCTAssertNil(gate.readLineLimit)
    }

    func testReportedHelperCannotControlItsAssociatedTerminal() {
        let selection = AgentOverviewSelection.helper(
            workspaceId: UUID(),
            helperId: UUID(),
            surfaceId: UUID(),
            hasIndependentOutput: true
        )

        XCTAssertFalse(selection.allowsTerminalControl)
        XCTAssertNotNil(selection.outputSurfaceId)
    }

    func testOutputRequiresVisibilityAndIsAlwaysLimitedToTwoHundredLines() {
        let workspaceId = UUID()
        let panelId = UUID()
        var gate = AgentOverviewOutputGate()
        gate.select(.terminal(workspaceId: workspaceId, panelId: panelId))
        gate.showOutput()

        XCTAssertNil(gate.readLineLimit)

        gate.isWindowVisible = true
        XCTAssertEqual(gate.readLineLimit, 200)

        gate.hideOutput()
        XCTAssertNil(gate.readLineLimit)
    }

    func testSelectionChangeRequiresOutputToBeOpenedAgain() {
        let workspaceId = UUID()
        var gate = AgentOverviewOutputGate()
        gate.isWindowVisible = true
        gate.select(.terminal(workspaceId: workspaceId, panelId: UUID()))
        gate.showOutput()
        XCTAssertEqual(gate.readLineLimit, 200)

        gate.select(.workspace(workspaceId))

        XCTAssertFalse(gate.isOutputVisible)
        XCTAssertNil(gate.readLineLimit)
    }

    func testDisappearedSelectionClearsOutputAndSelection() {
        let selection = AgentOverviewSelection.terminal(workspaceId: UUID(), panelId: UUID())
        var gate = AgentOverviewOutputGate()
        gate.isWindowVisible = true
        gate.select(selection)
        gate.showOutput()

        gate.reconcile(availableSelections: [])

        XCTAssertNil(gate.selection)
        XCTAssertFalse(gate.isOutputVisible)
        XCTAssertNil(gate.readLineLimit)
    }

    func testOutputRefreshesAtMostOncePerSecond() {
        var gate = AgentOverviewOutputRefreshGate()
        let start = Date(timeIntervalSince1970: 100)

        XCTAssertTrue(gate.shouldRead(now: start))
        XCTAssertFalse(gate.shouldRead(now: start.addingTimeInterval(0.999)))
        XCTAssertTrue(gate.shouldRead(now: start.addingTimeInterval(1)))
    }
}
