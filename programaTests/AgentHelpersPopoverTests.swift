import XCTest

#if canImport(Programa_DEV)
@testable import Programa_DEV
#elseif canImport(Programa)
@testable import Programa
#endif

@MainActor
final class AgentHelpersPopoverTests: XCTestCase {
    private var workspaceId = UUID()

    override func setUp() async throws {
        workspaceId = UUID()
    }

    override func tearDown() async throws {
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
