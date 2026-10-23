import XCTest

#if canImport(Programa_DEV)
@testable import Programa_DEV
#elseif canImport(Programa)
@testable import Programa
#endif

@MainActor
final class AgentHelpersPopoverTests: XCTestCase {
    private var workspaceId = UUID()
    private var surfaceId = UUID()

    override func setUp() async throws {
        workspaceId = UUID()
        surfaceId = UUID()
    }

    override func tearDown() async throws {
        AgentSupervisionRegistry.shared.syncTerminalHelpers(workspaceId: workspaceId, surfaceId: surfaceId, children: [])
        AgentSupervisionRegistry.shared.discardFinishedHelpers(workspaceId: workspaceId)
        for record in AgentSupervisionRegistry.shared.records(workspaceIds: [workspaceId]) {
            AgentSupervisionRegistry.shared.discard(id: record.id)
        }
    }

    @discardableResult
    private func startHelper(
        task: String?, role: String?, state: AgentTaskState, at seconds: TimeInterval,
        placement: AgentTaskPlacement = .runsWithParent
    ) throws -> AgentTaskRecord {
        try AgentSupervisionRegistry.shared.start(
            host: "claude", task: task, role: role, state: state, placement: placement,
            workspaceId: workspaceId, now: Date(timeIntervalSince1970: seconds)
        )
    }

    func testModelSplitsRunningFromFinishedNewestFirstAndSkipsSpawnedWorkspaces() throws {
        let running = try startHelper(task: "Fix restore race", role: "implementer", state: .working, at: 100)
        let older = try startHelper(task: "Plan sidebar cut", role: "planner", state: .working, at: 110)
        let newer = try startHelper(task: "Map callers", role: "explore", state: .working, at: 120)
        try startHelper(task: "Nested", role: "codex", state: .working, at: 130, placement: .nestedWorkspace)
        try AgentSupervisionRegistry.shared.finish(id: older.id, now: Date(timeIntervalSince1970: 200))
        try AgentSupervisionRegistry.shared.finish(id: newer.id, state: .failed, now: Date(timeIntervalSince1970: 300))

        let model = AgentHelpersModel(workspaceId: workspaceId)
        model.refresh()

        XCTAssertEqual(model.running.map(\.id), [running.id])
        XCTAssertEqual(model.finished.map(\.id), [newer.id, older.id])
        XCTAssertEqual(model.finished.map(\.state), [.failed, .done])
        XCTAssertEqual(model.finished.last?.duration(now: .distantFuture), 90)
    }

    func testClearFinishedKeepsRunningHelpersAndUpdatesTheSidebarCounts() throws {
        try startHelper(task: "Fix restore race", role: "implementer", state: .working, at: 100)
        try startHelper(task: "Plan sidebar cut", role: "planner", state: .completed, at: 110)
        try startHelper(task: "Port the parser", role: "implementer", state: .failed, at: 120)
        XCTAssertEqual(AgentSupervisionRegistry.shared.finishedHelperCounts[workspaceId], 2)

        let model = AgentHelpersModel(workspaceId: workspaceId)
        model.clearFinished()

        XCTAssertEqual(model.running.count, 1)
        XCTAssertEqual(model.finished, [])
        XCTAssertNil(AgentSupervisionRegistry.shared.finishedHelperCounts[workspaceId])
        XCTAssertEqual(AgentSupervisionRegistry.shared.runningHelperCounts[workspaceId], 1)
    }

    private func child(
        _ id: String, _ state: ProgramStatusState, title: String? = nil, app: String? = nil,
        progress: Int? = nil, at seconds: TimeInterval
    ) -> ProgramStatusRecord {
        ProgramStatusRecord(
            id: id, state: state, kind: nil, progress: progress, app: app, title: title, msg: nil,
            updatedAt: Date(timeIntervalSince1970: seconds)
        )
    }

    private func terminalHelpers() -> [AgentTaskRecord] {
        AgentSupervisionRegistry.shared.helperRecords(workspaceId: workspaceId, surfaceIds: [surfaceId])
    }

    func testTerminalChildRecordsBecomeHelpersAndReportBlockedOnce() {
        let registry = AgentSupervisionRegistry.shared
        var blocked = registry.syncTerminalHelpers(workspaceId: workspaceId, surfaceId: surfaceId, children: [
            child("deploy/us-east", .working, title: "US East", app: "deployer", progress: 40, at: 100),
            child("deploy/eu-west", .blocked, app: "deployer", at: 100),
        ])
        XCTAssertEqual(blocked.map(\.task), ["eu-west"])
        XCTAssertEqual(registry.runningHelperCounts[workspaceId], 2)
        let usEast = terminalHelpers().first { $0.task == "US East" }
        XCTAssertEqual(usEast?.progress, 40)
        XCTAssertEqual(usEast?.role, "deployer")
        XCTAssertTrue(registry.records(workspaceIds: [workspaceId]).isEmpty, "child records stay off the socket")

        blocked = registry.syncTerminalHelpers(workspaceId: workspaceId, surfaceId: surfaceId, children: [
            child("deploy/us-east", .done, title: "US East", app: "deployer", at: 150),
            child("deploy/eu-west", .blocked, app: "deployer", at: 160),
        ])
        XCTAssertTrue(blocked.isEmpty, "a helper that stays blocked is not reported again")
        let finished = terminalHelpers().first { $0.task == "US East" }
        XCTAssertEqual(finished?.state, .completed)
        XCTAssertEqual(finished?.startedAt, Date(timeIntervalSince1970: 100))
        XCTAssertNil(finished?.progress)
        XCTAssertEqual(registry.finishedHelperCounts[workspaceId], 1)
    }

    func testChildNamedAfterASocketHelperUpdatesItInsteadOfAddingARow() throws {
        let helper = try startHelper(task: "Review the diff", role: "reviewer", state: .working, at: 100)
        AgentSupervisionRegistry.shared.syncTerminalHelpers(workspaceId: workspaceId, surfaceId: surfaceId, children: [
            child("agents/\(helper.id.uuidString.replacingOccurrences(of: "-", with: ""))", .blocked, title: "Review the diff", app: "claude-code", at: 120),
        ])
        XCTAssertEqual(terminalHelpers().map(\.id), [helper.id])
        XCTAssertEqual(AgentSupervisionRegistry.shared.record(id: helper.id)?.state, .blocked)

        AgentSupervisionRegistry.shared.syncTerminalHelpers(workspaceId: workspaceId, surfaceId: surfaceId, children: [
            child("agents/\(helper.id.uuidString)", .done, app: "claude-code", at: 130),
        ])
        XCTAssertEqual(
            AgentSupervisionRegistry.shared.record(id: helper.id)?.state, .blocked,
            "only the hook's socket report finishes a socket helper, since it carries the report"
        )
    }

    func testChildInAnotherWorkspaceLeavesASocketHelperAlone() throws {
        let helper = try startHelper(task: "Review the diff", role: "reviewer", state: .working, at: 100)
        let otherWorkspaceId = UUID()
        let otherSurfaceId = UUID()
        defer {
            AgentSupervisionRegistry.shared.syncTerminalHelpers(
                workspaceId: otherWorkspaceId, surfaceId: otherSurfaceId, children: []
            )
        }
        AgentSupervisionRegistry.shared.syncTerminalHelpers(workspaceId: otherWorkspaceId, surfaceId: otherSurfaceId, children: [
            child("agents/\(helper.id.uuidString)", .blocked, title: "Spoofed", at: 120),
        ])
        XCTAssertEqual(AgentSupervisionRegistry.shared.record(id: helper.id)?.state, .working)
        XCTAssertEqual(
            AgentSupervisionRegistry.shared.helperRecords(workspaceId: otherWorkspaceId, surfaceIds: [otherSurfaceId]).map(\.task),
            ["Spoofed"]
        )
    }

    func testClearFinishedAlsoDropsFinishedTerminalHelpers() {
        AgentSupervisionRegistry.shared.syncTerminalHelpers(workspaceId: workspaceId, surfaceId: surfaceId, children: [
            child("build", .done, at: 100),
            child("test", .error, at: 100),
            child("lint", .working, at: 100),
        ])
        XCTAssertEqual(AgentSupervisionRegistry.shared.finishedHelperCounts[workspaceId], 2)

        AgentHelpersModel(workspaceId: workspaceId).clearFinished()

        XCTAssertEqual(terminalHelpers().map(\.task), ["lint"])
        XCTAssertNil(AgentSupervisionRegistry.shared.finishedHelperCounts[workspaceId])
    }

    func testSnapshotTitlesPreferTheTaskAndHideARoleThatRepeatsIt() throws {
        let described = AgentHelperSnapshot(try startHelper(task: "Review commit", role: "reviewer", state: .working, at: 1))
        XCTAssertEqual(described.title, "Review commit")
        XCTAssertEqual(described.role, "reviewer")

        let typeOnly = AgentHelperSnapshot(try startHelper(task: "planner", role: "planner", state: .working, at: 2))
        XCTAssertEqual(typeOnly.title, "planner")
        XCTAssertNil(typeOnly.role)

        let unnamed = AgentHelperSnapshot(try startHelper(task: nil, role: nil, state: .working, at: 3))
        XCTAssertEqual(unnamed.title, "Helper")
    }

    func testStatesUsePlainLabels() {
        XCTAssertEqual(AgentHelperState(.working).label, "Working")
        XCTAssertEqual(AgentHelperState(.blocked).label, "Needs input")
        XCTAssertEqual(AgentHelperState(.completed).label, "Done")
        XCTAssertEqual(AgentHelperState(.cancelled).label, "Stopped")
        XCTAssertEqual(AgentHelperState(.failed).label, "Failed")
    }

    func testReportFileNameIsReadableAndSafe() {
        XCTAssertEqual(AgentHelpersFormatting.reportFileName(title: "Review durable-agents commit"),
                       "Review durable-agents commit.md")
        XCTAssertEqual(AgentHelpersFormatting.reportFileName(title: "../../etc/passwd: fix"), "etc passwd fix.md")
        XCTAssertEqual(AgentHelpersFormatting.reportFileName(title: "///"), "Helper report.md")
    }
}
