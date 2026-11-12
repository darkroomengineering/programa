import XCTest

#if canImport(Programa_DEV)
@testable import Programa_DEV
#elseif canImport(Programa)
@testable import Programa
#endif

/// A clock the test moves by hand and the wakes the engine asked for.
@MainActor
private final class ManualClock {
    var now = Date(timeIntervalSince1970: 1_000_000)
    private var wakes: [(at: Date, body: @MainActor () -> Void)] = []

    func schedule(at date: Date, _ body: @escaping @MainActor () -> Void) {
        wakes.append((date, body))
    }

    /// Moves the clock and runs every wake that is due, in time order.
    func advance(by seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
        runDueWakes()
    }

    /// Runs every wake due at or before `now`.
    func runDueWakes() {
        while let index = wakes.indices.filter({ wakes[$0].at <= now }).min(by: { wakes[$0].at < wakes[$1].at }) {
            wakes.remove(at: index).body()
        }
    }

    /// Runs the earliest wake whatever the clock says, as a timer that fires a moment early.
    func runEarliestWakeEarly() {
        guard let index = wakes.indices.min(by: { wakes[$0].at < wakes[$1].at }) else { return }
        wakes.remove(at: index).body()
    }
}

@MainActor
private final class RecordingExecutor: RouteActionExecutor {
    var fires: [RouteFire] = []
    var cancelled: [String] = []

    func execute(_ fire: RouteFire) {
        fires.append(fire)
    }

    func cancel(routeName: String, key: String) {
        cancelled.append("\(routeName) \(key)")
    }
}

@MainActor
final class RouteEngineTests: XCTestCase {

    private var clock: ManualClock!

    override func setUp() {
        super.setUp()
        clock = ManualClock()
    }

    private func makeEngine(
        tap: RouteTap? = nil,
        modelFields: @escaping @MainActor (RouteEvent) -> [String: String] = { _ in [:] }
    ) -> RouteEngine {
        let clock = clock!
        return RouteEngine(
            tap: tap,
            now: { clock.now },
            scheduleWake: { date, body in clock.schedule(at: date, body) },
            modelFields: modelFields
        )
    }

    private func config(_ routes: String, file: StaticString = #filePath, line: UInt = #line) throws -> ProgramaConfigFile {
        try ProgramaConfigStore.decodeConfig(Data(#"{ "routes": [ \#(routes) ] }"#.utf8))
    }

    private func install(
        _ routes: String,
        on engine: RouteEngine,
        source: RouteSource = .file(digest: "d1"),
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let config = try config(routes)
        XCTAssertEqual(config.routeIssues, [], file: file, line: line)
        engine.install(routes: config.routes, issues: config.routeIssues, source: source)
    }

    private func needsInput(surface: String, kind: String = "question") -> RouteEvent {
        RouteEvent(
            topic: "agent/\(surface)/needs_input/\(kind)",
            fields: ["workspace_id": "W1", "surface_id": surface, "kind": kind]
        )
    }

    private func agentState(surface: String, state: String, previous: String? = nil) -> RouteEvent {
        var fields = ["workspace_id": "W1", "surface_id": surface, "state": state]
        fields["previous_state"] = previous
        return RouteEvent(topic: "agent/\(surface)/state/\(state)", fields: fields)
    }

    private func counters(_ engine: RouteEngine, _ name: String, file: StaticString = #filePath, line: UInt = #line) -> RouteCounters? {
        let route = engine.snapshot().routes.first { $0.name == name }
        XCTAssertNotNil(route, "no route named \(name)", file: file, line: line)
        return route?.counters
    }

    // MARK: - Matching and counters

    func testIngestCountsMatchesAndFiresOnlyMatchingTopics() throws {
        let engine = makeEngine()
        try install(#"{ "name": "ask", "on": "agent/+/needs_input/#", "notify": { "title": "t" } }"#, on: engine)

        engine.ingest(needsInput(surface: "S1"))
        engine.ingest(needsInput(surface: "S1", kind: "permission"))
        engine.ingest(needsInput(surface: "S2"))
        engine.ingest(agentState(surface: "S1", state: "idle"))

        XCTAssertEqual(counters(engine, "ask"), RouteCounters(matched: 3, fired: 3))
    }

    func testWhenFiltersOnFieldsTheModelAdds() throws {
        let engine = makeEngine { event in
            event.fields["surface_id"] == "S1" ? ["worktree": "true"] : ["worktree": "false"]
        }
        try install(#"""
        { "name": "idle", "on": "agent/+/state/idle",
          "when": { "previous_state": { "in": ["working", "blocked"] }, "worktree": "true" },
          "review": {} }
        """#, on: engine)

        engine.ingest(agentState(surface: "S1", state: "idle"))
        engine.ingest(agentState(surface: "S1", state: "idle", previous: "working"))
        engine.ingest(agentState(surface: "S2", state: "idle", previous: "working"))

        XCTAssertEqual(counters(engine, "idle")?.matched, 1, "a session-start idle and a non-worktree surface do not match")
    }

    func testFrameFieldsWinOverModelFields() throws {
        let executor = RecordingExecutor()
        let engine = makeEngine { _ in ["surface_id": "model", "cwd": "/repo"] }
        engine.executor = executor
        try install(#"{ "name": "ask", "on": "agent/#", "notify": { "title": "t" } }"#, on: engine)

        engine.ingest(needsInput(surface: "S1"))

        XCTAssertEqual(executor.fires.first?.event.fields["surface_id"], "S1")
        XCTAssertEqual(executor.fires.first?.event.fields["cwd"], "/repo")
    }

    // MARK: - Keys

    func testDefaultKeyIsTheTopicSoEachSurfaceHasItsOwnWindow() throws {
        let executor = RecordingExecutor()
        let engine = makeEngine()
        engine.executor = executor
        try install(#"{ "name": "ask", "on": "agent/+/needs_input/question", "throttleMs": 3000, "notify": { "title": "t" } }"#, on: engine)

        for _ in 0..<3 { engine.ingest(needsInput(surface: "S1")) }
        XCTAssertEqual(counters(engine, "ask"), RouteCounters(matched: 3, fired: 1, throttled: 2))

        engine.ingest(needsInput(surface: "S2"))
        XCTAssertEqual(counters(engine, "ask")?.fired, 2)
        XCTAssertEqual(executor.fires.map(\.key), ["agent/S1/needs_input/question", "agent/S2/needs_input/question"])

        clock.advance(by: 3)
        engine.ingest(needsInput(surface: "S1"))
        XCTAssertEqual(counters(engine, "ask")?.fired, 3, "the window reopens after throttleMs")
    }

    func testCustomKeySharesOneWindowAcrossStatesOfASurface() throws {
        let engine = makeEngine()
        try install(#"""
        { "name": "by-surface", "on": "agent/+/state/+", "key": "{{surface_id}}", "throttleMs": "5m", "review": {} },
        { "name": "by-topic", "on": "agent/+/state/+", "throttleMs": "5m", "review": {} }
        """#, on: engine)

        engine.ingest(agentState(surface: "S1", state: "working"))
        engine.ingest(agentState(surface: "S1", state: "idle"))

        XCTAssertEqual(counters(engine, "by-surface"), RouteCounters(matched: 2, fired: 1, throttled: 1))
        XCTAssertEqual(counters(engine, "by-topic"), RouteCounters(matched: 2, fired: 2))
    }

    func testKeyRendersModelFields() throws {
        let executor = RecordingExecutor()
        let engine = makeEngine { _ in ["git_branch": "main"] }
        engine.executor = executor
        try install(#"{ "name": "branch", "on": "agent/+/state/idle", "key": "{{git_branch}}-{{state}}", "throttleMs": 1000, "review": {} }"#, on: engine)

        engine.ingest(agentState(surface: "S1", state: "idle"))
        engine.ingest(agentState(surface: "S2", state: "idle"))

        XCTAssertEqual(executor.fires.map(\.key), ["main-idle"])
        XCTAssertEqual(counters(engine, "branch")?.throttled, 1, "two surfaces on one branch share the key")
    }

    // MARK: - Wakes

    func testDebounceFiresTheLastEventOfABurstThroughTheScheduler() throws {
        let executor = RecordingExecutor()
        let engine = makeEngine()
        engine.executor = executor
        try install(#"{ "name": "settle", "on": "agent/+/state/idle", "debounceMs": 2000, "review": {} }"#, on: engine)

        engine.ingest(agentState(surface: "S1", state: "idle", previous: "working"))
        clock.advance(by: 1)
        engine.ingest(agentState(surface: "S1", state: "idle", previous: "blocked"))
        clock.advance(by: 1.5)
        XCTAssertEqual(counters(engine, "settle")?.fired, 0, "the first wake is stale once the second match moved the deadline")

        clock.advance(by: 0.5)
        XCTAssertEqual(counters(engine, "settle"), RouteCounters(matched: 2, fired: 1))
        XCTAssertEqual(executor.fires.first?.event.fields["previous_state"], "blocked")
    }

    func testThrottleCooldownWakeReturnsTheGateToIdle() throws {
        let engine = makeEngine()
        try install(#"{ "name": "both", "on": "agent/+/state/idle", "debounceMs": 1000, "throttleMs": 10000, "review": {} }"#, on: engine)

        engine.ingest(agentState(surface: "S1", state: "idle"))
        clock.advance(by: 1)
        XCTAssertEqual(counters(engine, "both")?.fired, 1)

        engine.ingest(agentState(surface: "S1", state: "idle"))
        clock.advance(by: 1)
        XCTAssertEqual(counters(engine, "both")?.throttled, 1, "a debounced candidate inside the window is dropped")

        clock.advance(by: 9)
        engine.ingest(agentState(surface: "S1", state: "idle"))
        clock.advance(by: 1)
        XCTAssertEqual(counters(engine, "both")?.fired, 2)
    }

    func testAnEarlyTimerStillFiresTheDebouncedEvent() throws {
        let engine = makeEngine()
        try install(#"{ "name": "settle", "on": "agent/+/state/idle", "debounceMs": 2000, "review": {} }"#, on: engine)

        engine.ingest(agentState(surface: "S1", state: "idle"))
        clock.now = clock.now.addingTimeInterval(1.999)
        clock.runEarliestWakeEarly()

        XCTAssertEqual(counters(engine, "settle")?.fired, 1)
    }

    // MARK: - Deliveries

    func testWithoutAnExecutorADeliveryEndsAtOnce() throws {
        let engine = makeEngine()
        try install(#"{ "name": "test", "on": "agent/+/state/idle", "run": { "command": "true" } }"#, on: engine)

        engine.ingest(agentState(surface: "S1", state: "idle"))
        engine.ingest(agentState(surface: "S1", state: "idle"))

        XCTAssertEqual(counters(engine, "test"), RouteCounters(matched: 2, fired: 2))
    }

    func testADeliveryHoldsItsRouteUntilTheExecutorEndsIt() throws {
        let executor = RecordingExecutor()
        let engine = makeEngine()
        engine.executor = executor
        try install(#"{ "name": "test", "on": "agent/+/state/idle", "run": { "command": "true" } }"#, on: engine)

        engine.ingest(agentState(surface: "S1", state: "idle"))
        engine.ingest(agentState(surface: "S1", state: "idle"))
        XCTAssertEqual(counters(engine, "test"), RouteCounters(matched: 2, fired: 1, busy: 1))

        engine.endDelivery(try XCTUnwrap(executor.fires.first), error: "exit 1")
        engine.ingest(agentState(surface: "S1", state: "idle"))
        XCTAssertEqual(counters(engine, "test")?.fired, 2)
        XCTAssertEqual(engine.snapshot().routes.first?.lastError, "exit 1")
    }

    func testAnExpiredDeliveryIsCancelled() throws {
        let executor = RecordingExecutor()
        let engine = makeEngine()
        engine.executor = executor
        try install(#"{ "name": "test", "on": "agent/+/state/idle", "run": { "command": "true", "timeoutMs": "4s" } }"#, on: engine)

        engine.ingest(agentState(surface: "S1", state: "idle"))
        clock.advance(by: 4)

        XCTAssertEqual(counters(engine, "test")?.expired, 1)
        XCTAssertEqual(executor.cancelled, ["test agent/S1/state/idle"])
    }

    func testReinstallCancelsDeliveriesAndIgnoresTheirLateEnd() throws {
        let executor = RecordingExecutor()
        let engine = makeEngine()
        engine.executor = executor
        let route = #"{ "name": "test", "on": "agent/+/state/idle", "run": { "command": "true" } }"#
        try install(route, on: engine, source: .file(digest: "d1"))
        engine.ingest(agentState(surface: "S1", state: "idle"))
        let staleFire = try XCTUnwrap(executor.fires.first)

        try install(route, on: engine, source: .file(digest: "d2"))
        XCTAssertEqual(executor.cancelled, ["test agent/S1/state/idle"])

        engine.ingest(agentState(surface: "S1", state: "idle"))
        engine.endDelivery(staleFire)
        engine.ingest(agentState(surface: "S1", state: "idle"))
        XCTAssertEqual(counters(engine, "test"), RouteCounters(matched: 2, fired: 1, busy: 1), "a fire from the old route set ends nothing")
    }

    // MARK: - Sources

    func testAFileInstallWithTheDigestAlreadyHeldKeepsCounters() throws {
        let engine = makeEngine()
        let route = #"{ "name": "ask", "on": "agent/#", "notify": { "title": "t" } }"#
        try install(route, on: engine, source: .file(digest: "d1"))
        engine.ingest(needsInput(surface: "S1"))

        try install(route, on: engine, source: .file(digest: "d1"))
        XCTAssertEqual(counters(engine, "ask")?.matched, 1)

        try install(route, on: engine, source: .file(digest: "d2"))
        XCTAssertEqual(counters(engine, "ask")?.matched, 0)
    }

    func testADebugOverrideMasksTheFileUntilCleared() throws {
        let engine = makeEngine()
        try install(#"{ "name": "file-a", "on": "agent/#", "notify": { "title": "t" } }"#, on: engine, source: .file(digest: "a"))

        let override = try config(#"""
        { "name": "override", "on": "agent/+/needs_input/#", "notify": { "title": "t" } },
        { "name": "broken", "on": "agent/#/x", "notify": { "title": "t" } }
        """#)
        engine.install(routes: override.routes, issues: override.routeIssues, source: .debugOverride)
        XCTAssertEqual(engine.snapshot().source, .debugOverride)
        XCTAssertEqual(engine.snapshot().routes.map(\.name), ["override"])
        XCTAssertEqual(engine.snapshot().issues.map(\.name), ["broken"])

        try install(#"{ "name": "file-b", "on": "agent/#", "notify": { "title": "t" } }"#, on: engine, source: .file(digest: "b"))
        XCTAssertEqual(engine.snapshot().routes.map(\.name), ["override"], "a file reload must not replace a test's routes")

        engine.clearDebugOverride()
        XCTAssertEqual(engine.snapshot().source, .file(digest: "b"))
        XCTAssertEqual(engine.snapshot().routes.map(\.name), ["file-b"])
        XCTAssertEqual(engine.snapshot().issues, [])
    }

    func testInstallTellsTheTapWhichClassesToBuild() throws {
        let tap = RouteTap()
        let engine = makeEngine(tap: tap)
        try install(#"{ "name": "idle", "on": "agent/+/state/idle", "review": {} }"#, on: engine)
        XCTAssertTrue(tap.wants(.agentState))
        XCTAssertFalse(tap.wants(.needsInput))
        XCTAssertFalse(tap.wants(.workspaceLifecycle))
        XCTAssertFalse(tap.wants(.output))

        engine.install(routes: [], issues: [], source: .file(digest: "empty"))
        XCTAssertFalse(tap.wants(.agentState))
    }

    func testEventClassesCoverEveryClassAPatternCanMatch() throws {
        func classes(_ patterns: String...) throws -> Set<SocketEventClass> {
            RouteEngine.eventClasses(for: try patterns.map(ProgramaRouteTopicPattern.init(parsing:)))
        }
        XCTAssertEqual(try classes("agent/#"), [.agentState, .needsInput])
        XCTAssertEqual(try classes("agent/+/needs_input/question"), [.needsInput])
        XCTAssertEqual(try classes("+/+/state/idle"), [.agentState])
        XCTAssertEqual(try classes("workspace/+/closed"), [.workspaceLifecycle])
        XCTAssertEqual(try classes("#"), [.agentState, .needsInput, .workspaceLifecycle])
        XCTAssertEqual(try classes("+/#"), [.agentState, .needsInput, .workspaceLifecycle])
        XCTAssertEqual(try classes("agent/+/state"), [])
    }
}

// MARK: - Frames

final class RouteEventFrameTests: XCTestCase {

    func testAgentStateFrameFlattensToRouteFields() throws {
        let event = try XCTUnwrap(RouteEvent(
            frame: [
                "event": "agent_state",
                "workspace_id": "W1",
                "surface_id": "S1",
                "state": NSNull(),
                "source": NSNull(),
                "ts": 1_700_000_000.5,
                "program_status": [
                    "state": "running",
                    "kind": NSNull(),
                    "progress": 0.25,
                    "has_message": true,
                    "updated_at": 1_700_000_000.0,
                ] as [String: Any],
            ],
            previousState: .working
        ))

        XCTAssertEqual(event.topic, "agent/S1/state/none", "a clear has the value none")
        XCTAssertEqual(event.fields, [
            "workspace_id": "W1",
            "surface_id": "S1",
            "ts": "1700000000.5",
            "previous_state": "working",
            "program_status.state": "running",
            "program_status.progress": "0.25",
            "program_status.has_message": "true",
            "program_status.updated_at": "1700000000.0",
        ])
    }

    func testNeedsInputFrameWithoutKindIsUnknown() throws {
        let event = try XCTUnwrap(RouteEvent(frame: [
            "event": "needs_input", "workspace_id": "W1", "surface_id": "S1", "title": "Claude", "ts": 1.0,
        ]))
        XCTAssertEqual(event.topic, "agent/S1/needs_input/unknown")
        XCTAssertEqual(event.fields["title"], "Claude")
        XCTAssertNil(event.fields["previous_state"])
    }

    func testWorkspaceLifecycleFrameTopic() throws {
        let event = try XCTUnwrap(RouteEvent(frame: [
            "event": "workspace_lifecycle", "workspace_id": "W1", "kind": "closed", "title": NSNull(), "ts": 1.0,
        ]))
        XCTAssertEqual(event.topic, "workspace/W1/closed")
        XCTAssertNil(event.fields["title"])
    }

    func testOutputFramesAreNotRouted() {
        XCTAssertNil(RouteEvent(frame: ["event": "output", "workspace_id": "W1", "surface_id": "S1", "text": "x"]))
    }
}

// MARK: - Route source

@MainActor
final class RouteEngineSourceTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private func write(_ text: String, to name: String) throws -> URL {
        let url = tempRoot.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testOnlyTheGlobalFileInstallsRoutesAndEveryWindowSharesThem() throws {
        let global = try write("""
        { "routes": [{ "name": "global-route", "on": "agent/+/needs_input/#", "notify": { "title": "t" } }] }
        """, to: "global.json")
        let local = try write("""
        { "routes": [{ "name": "local-route", "on": "agent/#", "notify": { "title": "t" } }] }
        """, to: "local.json")
        let engine = RouteEngine(modelFields: { _ in [:] })

        let firstWindow = ProgramaConfigStore()
        firstWindow.routeEngine = engine
        firstWindow.localConfigPath = local.path
        firstWindow.globalConfigPath = global.path
        firstWindow.loadAll()
        XCTAssertEqual(engine.snapshot().routes.map(\.name), ["global-route"])

        engine.ingest(RouteEvent(topic: "agent/S1/needs_input/question", fields: [:]))
        let secondWindow = ProgramaConfigStore()
        secondWindow.routeEngine = engine
        secondWindow.localConfigPath = nil
        secondWindow.globalConfigPath = global.path
        secondWindow.loadAll()
        XCTAssertEqual(engine.snapshot().routes.first?.counters.matched, 1, "a second window's load of the same file keeps the counters")
    }
}
