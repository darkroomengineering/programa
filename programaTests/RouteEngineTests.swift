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
    var issueReports: [[ProgramaRouteIssue]] = []
    var wentIdle: [RouteFire] = []

    func execute(_ fire: RouteFire, engine: RouteEngine) {
        fires.append(fire)
    }

    func cancel(_ fire: RouteFire) {
        cancelled.append("\(fire.route.name) \(fire.key)")
    }

    func reportLoadIssues(_ issues: [ProgramaRouteIssue]) {
        issueReports.append(issues)
    }

    func targetWentIdle(_ fire: RouteFire, engine: RouteEngine) {
        wentIdle.append(fire)
    }
}

/// Submits every prompt at once, as the real executor does for an agent that can take it.
@MainActor
private final class SubmittingExecutor: RouteActionExecutor {
    var submitted: [String] = []

    func execute(_ fire: RouteFire, engine: RouteEngine) {
        guard case .prompt(let text, _) = fire.route.definition.action else {
            engine.endDelivery(fire)
            return
        }
        submitted.append(text)
        engine.turnStarted(fire)
    }

    func cancel(_ fire: RouteFire) {}
    func reportLoadIssues(_ issues: [ProgramaRouteIssue]) {}
    func targetWentIdle(_ fire: RouteFire, engine: RouteEngine) {}
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
            modelFields: modelFields,
            deferWork: { $0() }
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

    private func needsInput(surface: String, kind: String? = "question", writer: String? = nil) -> RouteEvent {
        var fields = ["workspace_id": "W1", "surface_id": surface]
        fields["kind"] = kind
        return RouteEvent(topic: "agent/\(surface)/needs_input/\(kind ?? "unknown")", fields: fields, writer: writer)
    }

    private func agentState(surface: String, state: String, previous: String? = nil, writer: String? = nil) -> RouteEvent {
        var fields = ["workspace_id": "W1", "surface_id": surface, "state": state]
        fields["previous_state"] = previous
        return RouteEvent(topic: "agent/\(surface)/state/\(state)", fields: fields, writer: writer)
    }

    private let agent = "hooks:claude-code:session-1"

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

    func testALateEndFromAnExpiredDeliveryDoesNotEndTheNextOne() throws {
        let executor = RecordingExecutor()
        let engine = makeEngine()
        engine.executor = executor
        try install(#"{ "name": "test", "on": "agent/+/state/idle", "run": { "command": "true", "timeoutMs": "4s" } }"#, on: engine)

        engine.ingest(agentState(surface: "S1", state: "idle"))
        clock.advance(by: 4)
        let expired = try XCTUnwrap(executor.fires.first)
        XCTAssertEqual(executor.cancelled, ["test agent/S1/state/idle"])

        engine.ingest(agentState(surface: "S1", state: "idle"))
        let current = try XCTUnwrap(executor.fires.last)
        XCTAssertNotEqual(expired.id, current.id)

        engine.endDelivery(expired, error: "timed out after 4 s")
        engine.ingest(agentState(surface: "S1", state: "idle"))
        XCTAssertEqual(
            counters(engine, "test"),
            RouteCounters(matched: 3, fired: 2, busy: 1, expired: 1),
            "the cancelled fire's end must not release the newer delivery"
        )
        XCTAssertEqual(engine.snapshot().routes.first?.lastError, "timed out after 4 s", "its error is still kept")

        engine.endDelivery(current)
        engine.ingest(agentState(surface: "S1", state: "idle"))
        XCTAssertEqual(counters(engine, "test")?.fired, 3)
    }

    func testFireIdsAreUniqueAcrossKeysAndInstalls() throws {
        let executor = RecordingExecutor()
        let engine = makeEngine()
        engine.executor = executor
        let route = #"{ "name": "ask", "on": "agent/#", "notify": { "title": "t" } }"#
        try install(route, on: engine, source: .file(digest: "d1"))
        engine.ingest(needsInput(surface: "S1"))
        engine.ingest(needsInput(surface: "S2"))
        try install(route, on: engine, source: .file(digest: "d2"))
        engine.ingest(needsInput(surface: "S1"))

        XCTAssertEqual(Set(executor.fires.map(\.id)).count, 3)
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

    func testLoadIssuesAreReportedOncePerChangedFile() throws {
        let executor = RecordingExecutor()
        let engine = makeEngine()
        engine.executor = executor
        let broken = try config(#"{ "name": "broken", "on": "agent/#/x", "notify": { "title": "t" } }"#)

        engine.install(routes: broken.routes, issues: broken.routeIssues, source: .file(digest: "d1"))
        engine.install(routes: broken.routes, issues: broken.routeIssues, source: .file(digest: "d1"))
        XCTAssertEqual(executor.issueReports.map { $0.map(\.name) }, [["broken"]], "an unchanged file reports nothing")

        engine.install(routes: [], issues: [], source: .file(digest: "d2"))
        engine.install(routes: broken.routes, issues: broken.routeIssues, source: .debugOverride)
        XCTAssertEqual(executor.issueReports.count, 1, "a clean file and a debug override report nothing")

        engine.install(routes: broken.routes, issues: broken.routeIssues, source: .file(digest: "d3"))
        XCTAssertEqual(executor.issueReports.count, 2, "a changed file reports even while an override masks it")
    }

    // MARK: - Banner decision

    func testANotifyRouteOwnsTheBannerForEveryQuestionItMatches() throws {
        let engine = makeEngine { _ in ["worktree": "true"] }
        try install(#"""
        { "name": "ask", "on": "agent/+/needs_input/question", "when": { "worktree": "true" },
          "throttleMs": "5m", "notify": { "title": "t" } },
        { "name": "review", "on": "agent/+/needs_input/permission", "review": {} }
        """#, on: engine)

        XCTAssertTrue(engine.ingestNeedsInput(needsInput(surface: "S1")))
        XCTAssertTrue(engine.ingestNeedsInput(needsInput(surface: "S1")), "a throttled question still shows no built-in banner")
        XCTAssertEqual(counters(engine, "ask"), RouteCounters(matched: 2, fired: 1, throttled: 1))

        XCTAssertFalse(
            engine.ingestNeedsInput(needsInput(surface: "S1", kind: "permission")),
            "a permission call that only a review route matches keeps its banner"
        )
    }

    func testAPermissionBannerGivesWayOnlyToARouteThatFiresForThatCall() throws {
        let executor = RecordingExecutor()
        let engine = makeEngine()
        engine.executor = executor
        try install(#"""
        { "name": "ask", "on": "agent/+/needs_input/#", "key": "{{surface_id}}", "throttleMs": "5m", "notify": { "title": "t" } }
        """#, on: engine)
        let permission = needsInput(surface: "S1", kind: "permission")

        XCTAssertTrue(engine.ingestNeedsInput(permission), "the route fires for this call, so its banner is the one shown")
        XCTAssertEqual(executor.fires.count, 1, "its notification runs after the call's hop")
        XCTAssertFalse(engine.ingestNeedsInput(permission), "a throttled permission call keeps its built-in banner")
        XCTAssertTrue(engine.ingestNeedsInput(needsInput(surface: "S1")), "a throttled question stays suppressed")
    }

    func testABurstOfPermissionCallsKeepsEveryBannerButTheRoutesOwn() throws {
        // Two calls handled back to back, before any action has run: the second sees the gate the
        // first one moved.
        var deferred: [@MainActor () -> Void] = []
        let clock = clock!
        let engine = RouteEngine(
            now: { clock.now },
            scheduleWake: { date, body in clock.schedule(at: date, body) },
            modelFields: { _ in [:] },
            deferWork: { deferred.append($0) }
        )
        let executor = RecordingExecutor()
        engine.executor = executor
        try install(#"""
        { "name": "ask", "on": "agent/+/needs_input/#", "key": "{{surface_id}}", "throttleMs": "5m", "notify": { "title": "t" } }
        """#, on: engine)

        let first = engine.ingestNeedsInput(needsInput(surface: "S1", kind: "permission"))
        let second = engine.ingestNeedsInput(needsInput(surface: "S1", kind: "permission"))
        deferred.forEach { $0() }

        XCTAssertEqual([first, second], [true, false])
        XCTAssertEqual(executor.fires.count, 1, "one route notification, and the second call keeps its built-in banner")
    }

    func testADebouncedPermissionCallKeepsItsBanner() throws {
        let engine = makeEngine()
        try install(#"{ "name": "ask", "on": "agent/+/needs_input/#", "debounceMs": 1000, "notify": { "title": "t" } }"#, on: engine)

        XCTAssertFalse(engine.ingestNeedsInput(needsInput(surface: "S1", kind: "permission")))
        XCTAssertTrue(engine.ingestNeedsInput(needsInput(surface: "S1")))
    }

    func testACallWithNoKindFollowsThePermissionRule() throws {
        let engine = makeEngine()
        try install(#"{ "name": "ask", "on": "agent/+/needs_input/#", "throttleMs": "5m", "notify": { "title": "t" } }"#, on: engine)
        let kindless = needsInput(surface: "S1", kind: nil)

        XCTAssertTrue(engine.ingestNeedsInput(kindless))
        XCTAssertFalse(engine.ingestNeedsInput(kindless), "a throttled call with no kind keeps its banner")
    }

    func testBannerDecisionChecksWhenAgainstModelFields() throws {
        let engine = makeEngine { _ in ["worktree": "false"] }
        try install(#"{ "name": "ask", "on": "agent/+/needs_input/#", "when": { "worktree": "true" }, "notify": { "title": "t" } }"#, on: engine)

        XCTAssertFalse(engine.ingestNeedsInput(needsInput(surface: "S1")))
    }

    // MARK: - Regex time limit

    func testACatastrophicRegexIsStoppedAndReported() throws {
        let regex = try ProgramaRouteRegex(pattern: "^(a|aa)+$", flags: "")
        let nearMiss = String(repeating: "a", count: 4000) + "b"
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertEqual(regex.evaluate(nearMiss), .timedOut)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1.0, "stopped near its 50 ms limit")
        XCTAssertEqual(regex.evaluate("aaaa"), .matched)

        let engine = makeEngine()
        try install(#"{ "name": "slow", "on": "agent/#", "when": { "body": { "regex": "^(a|aa)+$" } }, "review": {} }"#, on: engine)
        engine.ingest(RouteEvent(topic: "agent/S1/needs_input/question", fields: ["surface_id": "S1", "body": nearMiss]))
        XCTAssertEqual(counters(engine, "slow")?.matched, 0, "a stopped match is no match")
        XCTAssertEqual(
            engine.snapshot().routes.first?.lastError,
            "when.body: the regex ran longer than 50 ms and was stopped; the event did not match"
        )
    }

    // MARK: - Text deliveries

    func testOnlyTheEndOfWorkFromTheSameWriterReleasesAQueuedDelivery() throws {
        let executor = RecordingExecutor()
        let engine = makeEngine()
        engine.executor = executor
        try install(#"{ "name": "s", "on": "agent/+/state/working", "send": { "text": "go" } }"#, on: engine)

        engine.ingest(agentState(surface: "S1", state: "working", previous: "idle", writer: agent))
        let fire = try XCTUnwrap(executor.fires.first)

        engine.ingest(agentState(surface: "S2", state: "idle", previous: "working", writer: agent))
        engine.ingest(agentState(surface: "S1", state: "idle", previous: "working"))
        engine.ingest(agentState(surface: "S1", state: "idle", previous: "working", writer: "hooks:claude-code:other"))
        engine.ingest(agentState(surface: "S1", state: "idle", previous: "blocked", writer: agent))
        XCTAssertEqual(executor.wentIdle, [], "another surface, a keyless report, another writer, or an idle after blocked")

        engine.ingest(agentState(surface: "S1", state: "idle", previous: "working", writer: agent))
        XCTAssertEqual(executor.wentIdle, [fire])
    }

    func testAPermissionPromptHoldsDeliveriesUntilItsWriterWorksAgain() throws {
        let executor = RecordingExecutor()
        let engine = makeEngine()
        engine.executor = executor
        try install(#"{ "name": "s", "on": "agent/+/state/working", "send": { "text": "go" } }"#, on: engine)

        engine.ingest(agentState(surface: "S1", state: "working", previous: "idle", writer: agent))
        engine.ingest(needsInput(surface: "S1", kind: "permission", writer: agent))
        XCTAssertEqual(engine.textDeliveryRefusal(surfaceId: "S1"), "refused: waiting for the agent to resume after it stopped for input")

        // A forged or mistaken report: no session, so it neither resumes the agent nor releases text.
        engine.ingest(agentState(surface: "S1", state: "idle", previous: "blocked"))
        engine.ingest(agentState(surface: "S1", state: "working", previous: "idle"))
        engine.ingest(agentState(surface: "S1", state: "idle", previous: "working"))
        XCTAssertEqual(executor.wentIdle, [])
        XCTAssertNotNil(engine.textDeliveryRefusal(surfaceId: "S1"))

        engine.ingest(agentState(surface: "S1", state: "working", previous: "idle", writer: agent))
        XCTAssertNil(engine.textDeliveryRefusal(surfaceId: "S1"))
        engine.ingest(agentState(surface: "S1", state: "idle", previous: "working", writer: agent))
        XCTAssertEqual(executor.wentIdle.map(\.id), [executor.fires.first?.id])
    }

    func testAProgramPermissionPromptAlsoHoldsDeliveries() throws {
        let engine = makeEngine()
        try install(#"{ "name": "s", "on": "agent/+/needs_input/#", "send": { "text": "go" } }"#, on: engine)
        let blocked = RouteEvent(
            topic: "agent/S1/state/blocked",
            fields: ["surface_id": "S1", "state": "blocked", "program_status.kind": "permission"],
            writer: "program"
        )
        engine.ingest(blocked)
        XCTAssertNotNil(engine.textDeliveryRefusal(surfaceId: "S1"))
        engine.ingest(agentState(surface: "S1", state: "working", previous: "blocked", writer: agent))
        XCTAssertNotNil(engine.textDeliveryRefusal(surfaceId: "S1"), "only the prompt's own writer resumes it")
        engine.ingest(agentState(surface: "S1", state: "working", previous: "blocked", writer: "program"))
        XCTAssertNil(engine.textDeliveryRefusal(surfaceId: "S1"))
    }

    func testAHooksOnlyAgentIgnoresAForgedWorkAndIdleAfterAPermissionPrompt() throws {
        // tmux, or any terminal where only the hooks report: no OSC 7501.
        let executor = RecordingExecutor()
        let engine = makeEngine()
        engine.executor = executor
        try install(#"{ "name": "p", "on": "agent/+/state/working", "throttleMs": "1m", "prompt": { "text": "go" } }"#, on: engine)

        engine.ingest(agentState(surface: "S1", state: "working", previous: "idle", writer: agent))
        engine.ingest(agentState(surface: "S1", state: "blocked", previous: "working", writer: agent))
        engine.ingest(needsInput(surface: "S1", kind: "permission", writer: agent))

        let forger = "hooks:claude-code:made-up"
        engine.ingest(agentState(surface: "S1", state: "working", previous: "blocked", writer: forger))
        engine.ingest(agentState(surface: "S1", state: "idle", previous: "working", writer: forger))
        XCTAssertEqual(executor.wentIdle, [], "a made-up session cannot resume the agent or release the prompt")
        XCTAssertNotNil(engine.textDeliveryRefusal(surfaceId: "S1"))

        // The real order: the person answers, the agent works again, then goes idle.
        engine.ingest(agentState(surface: "S1", state: "working", previous: "idle", writer: agent))
        engine.ingest(agentState(surface: "S1", state: "idle", previous: "working", writer: agent))
        XCTAssertEqual(executor.wentIdle.map(\.id), [executor.fires.first?.id])
    }

    func testAQuestionHoldsTextUntilTheAgentWorksAgain() throws {
        let engine = makeEngine()
        try install(#"{ "name": "s", "on": "agent/#", "send": { "text": "go" } }"#, on: engine)
        engine.ingest(agentState(surface: "S1", state: "working", previous: "idle", writer: agent))
        engine.ingest(agentState(surface: "S1", state: "blocked", previous: "working", writer: agent))
        XCTAssertNotNil(engine.textDeliveryRefusal(surfaceId: "S1"), "any stop for the person, not only a permission prompt")
        engine.ingest(agentState(surface: "S1", state: "working", previous: "blocked", writer: agent))
        XCTAssertNil(engine.textDeliveryRefusal(surfaceId: "S1"))
    }

    func testAStopWithNoKnownWriterResumesOnlyForTheProgram() throws {
        let engine = makeEngine()
        try install(#"{ "name": "s", "on": "agent/#", "send": { "text": "go" } }"#, on: engine)
        engine.ingest(agentState(surface: "S1", state: "blocked"))
        engine.ingest(agentState(surface: "S1", state: "working", previous: "blocked", writer: agent))
        XCTAssertNotNil(engine.textDeliveryRefusal(surfaceId: "S1"), "with no writer to compare, a hook session cannot resume it")
        engine.ingest(agentState(surface: "S1", state: "working", previous: "blocked", writer: "program"))
        XCTAssertNil(engine.textDeliveryRefusal(surfaceId: "S1"))
    }

    func testTheProgramsOwnWorkingResumesAfterAHookReportedPrompt() throws {
        // Programa's hooks report the prompt over the socket; the program's OSC 7501 status owns
        // the presence and reports the work that follows.
        let executor = RecordingExecutor()
        let engine = makeEngine()
        engine.executor = executor
        try install(#"{ "name": "s", "on": "agent/+/state/working", "send": { "text": "go" } }"#, on: engine)

        engine.ingest(agentState(surface: "S1", state: "working", previous: "idle", writer: "program"))
        engine.ingest(needsInput(surface: "S1", kind: "permission", writer: agent))
        XCTAssertNotNil(engine.textDeliveryRefusal(surfaceId: "S1"))

        engine.ingest(agentState(surface: "S1", state: "working", previous: "blocked", writer: "program"))
        XCTAssertNil(engine.textDeliveryRefusal(surfaceId: "S1"))
        engine.ingest(agentState(surface: "S1", state: "idle", previous: "working", writer: "program"))
        XCTAssertEqual(executor.wentIdle.map(\.id), [executor.fires.first?.id])
    }

    func testAClearEndsAQueuedDeliveryWithAnError() throws {
        let executor = RecordingExecutor()
        let engine = makeEngine()
        engine.executor = executor
        try install(#"{ "name": "s", "on": "agent/+/needs_input/#", "send": { "text": "go" } }"#, on: engine)

        engine.ingest(needsInput(surface: "S1"))
        engine.ingest(agentState(surface: "S1", state: "none"))
        XCTAssertEqual(executor.wentIdle, [])
        XCTAssertEqual(engine.snapshot().routes.first?.lastError, "the agent stopped before the text was delivered")

        engine.ingest(needsInput(surface: "S1"))
        XCTAssertEqual(counters(engine, "s")?.fired, 2, "the route is free again")
    }

    func testAPromptTurnEndsOnlyAfterWorkInThatTurn() throws {
        let executor = RecordingExecutor()
        let engine = makeEngine()
        engine.executor = executor
        try install(#"{ "name": "p", "on": "agent/+/state/idle", "throttleMs": "1m", "prompt": { "text": "next" } }"#, on: engine)

        engine.ingest(agentState(surface: "S1", state: "working", previous: "idle", writer: agent))
        engine.ingest(agentState(surface: "S1", state: "idle", previous: "working", writer: agent))
        engine.turnStarted(try XCTUnwrap(executor.fires.first))

        // An idle that arrives before the turn's own `working` (a late report from the work
        // before the prompt) does not end the turn.
        engine.ingest(agentState(surface: "S1", state: "idle", previous: "working", writer: agent))
        engine.ingest(agentState(surface: "S1", state: "working", previous: "idle", writer: agent))
        engine.ingest(agentState(surface: "S1", state: "idle", previous: "working", writer: agent))
        XCTAssertEqual(
            counters(engine, "p"),
            RouteCounters(matched: 3, fired: 1, busy: 2),
            "both idles during the prompt's turn, the one that ends it included, are busy"
        )
        XCTAssertEqual(executor.wentIdle, [], "an own turn is not a queued delivery")

        clock.advance(by: 61)
        engine.ingest(agentState(surface: "S1", state: "working", previous: "idle", writer: agent))
        engine.ingest(agentState(surface: "S1", state: "idle", previous: "working", writer: agent))
        XCTAssertEqual(counters(engine, "p")?.fired, 2, "the turn ended, so the route is free again")
    }

    func testTwoPromptRoutesCannotFeedEachOther() throws {
        let executor = SubmittingExecutor()
        let engine = makeEngine()
        engine.executor = executor
        try install(#"""
        { "name": "a", "on": "agent/+/state/idle", "throttleMs": "1m", "prompt": { "text": "a" } },
        { "name": "b", "on": "agent/+/state/idle", "throttleMs": "1m", "prompt": { "text": "b" } }
        """#, on: engine)

        engine.ingest(agentState(surface: "S1", state: "working", previous: "idle", writer: agent))
        engine.ingest(agentState(surface: "S1", state: "idle", previous: "working", writer: agent))
        XCTAssertEqual(executor.submitted, ["a"], "b sees the idle while a's prompt holds the surface")

        // Past both throttle windows, so only the open turn can stop b.
        clock.advance(by: 61)
        engine.ingest(agentState(surface: "S1", state: "working", previous: "idle", writer: agent))
        engine.ingest(agentState(surface: "S1", state: "idle", previous: "working", writer: agent))
        XCTAssertEqual(executor.submitted, ["a"], "the idle that ends a's turn fires no prompt route")
        XCTAssertEqual(counters(engine, "b")?.busy, 2)

        engine.ingest(agentState(surface: "S1", state: "working", previous: "idle", writer: agent))
        engine.ingest(agentState(surface: "S1", state: "idle", previous: "working", writer: agent))
        XCTAssertEqual(executor.submitted, ["a", "a"], "a person's next turn fires the routes again")
    }

    func testTurnStartedFromAnOldFireIsIgnored() throws {
        let executor = RecordingExecutor()
        let engine = makeEngine()
        engine.executor = executor
        try install(#"{ "name": "p", "on": "agent/+/needs_input/#", "throttleMs": "1m", "prompt": { "text": "go" } }"#, on: engine)

        engine.ingest(needsInput(surface: "S1", writer: agent))
        let first = try XCTUnwrap(executor.fires.first)
        engine.endDelivery(first)
        clock.advance(by: 61)
        engine.ingest(needsInput(surface: "S1", writer: agent))
        engine.turnStarted(first)

        engine.ingest(agentState(surface: "S1", state: "working", previous: "blocked", writer: agent))
        engine.ingest(agentState(surface: "S1", state: "idle", previous: "working", writer: agent))
        XCTAssertEqual(executor.wentIdle.map(\.id), [executor.fires.last?.id], "the newer fire is still waiting, not in a turn")
    }

    func testATextRouteListensForAgentStateWhateverItsTopic() throws {
        let tap = RouteTap()
        let engine = makeEngine(tap: tap)
        try install(#"{ "name": "s", "on": "agent/+/needs_input/#", "send": { "text": "go" } }"#, on: engine)
        XCTAssertTrue(tap.wants(.needsInput))
        XCTAssertTrue(tap.wants(.agentState))
    }

    func testRegexSeesOnlyTheFirst4096Units() throws {
        let regex = try ProgramaRouteRegex(pattern: "needle", flags: "")
        XCTAssertTrue(regex.matches(String(repeating: "a", count: 4090) + "needle"))
        XCTAssertFalse(regex.matches(String(repeating: "a", count: 4091) + "needle"))
    }

    func testCanonicalDirectoryResolvesDotsAndSymlinksAndRejectsTheRest() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: try XCTUnwrap(RouteEngine.canonicalDirectory(fm.temporaryDirectory.path)))
            .appendingPathComponent(UUID().uuidString)
        let inside = root.appendingPathComponent("work/app")
        let outside = root.appendingPathComponent("elsewhere")
        try fm.createDirectory(at: inside, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let link = inside.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: outside)

        XCTAssertEqual(RouteEngine.canonicalDirectory(inside.path + "/../../elsewhere"), outside.path)
        XCTAssertEqual(RouteEngine.canonicalDirectory(link.path), outside.path, "a symlink resolves to where it points")
        XCTAssertNil(RouteEngine.canonicalDirectory(root.appendingPathComponent("missing").path))
        XCTAssertNil(RouteEngine.canonicalDirectory("work/app"), "a relative path is refused")

        let file = root.appendingPathComponent("file")
        try Data().write(to: file)
        XCTAssertNil(RouteEngine.canonicalDirectory(file.path), "a file is not a directory")

        let engine = makeEngine { _ in ["cwd": RouteEngine.canonicalDirectory(link.path) ?? ""] }
        try install(#"{ "name": "work", "on": "agent/#", "when": { "cwd": { "regex": "/work/" } }, "review": {} }"#, on: engine)
        engine.ingest(agentState(surface: "S1", state: "idle"))
        XCTAssertEqual(counters(engine, "work")?.matched, 0, "a cwd regex sees the resolved path, not the link's")
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
