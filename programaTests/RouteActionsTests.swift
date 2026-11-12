import XCTest

#if canImport(Programa_DEV)
@testable import Programa_DEV
#elseif canImport(Programa)
@testable import Programa
#endif

/// What the actions asked the app to do.
private final class ActionLog: @unchecked Sendable {
    var notifications: [RouteNotification] = []
    var appNotifications: [(title: String, body: String)] = []
    var reviews: [RouteReviewRequest] = []
    var runs: [RouteRunRequest] = []
    var reviewPanelOpen = false
    var reviewError: String?
    var runResult = CanonicalSubprocessResult(stdout: "", stderr: "", exitStatus: 0, outcome: .exited)
}

@MainActor
final class RouteActionsTests: XCTestCase {

    private let workspaceId = UUID()
    private let surfaceId = UUID()
    private var log: ActionLog!
    private var engine: RouteEngine!

    override func setUp() {
        super.setUp()
        log = ActionLog()
        engine = RouteEngine(modelFields: { _ in [:] })
    }

    /// Off-main work runs inline, so each test sees an action's whole effect when `ingest` returns.
    private func makeActions() -> RouteActions {
        let log = log!
        return RouteActions(environment: RouteActionEnvironment(
            notify: { log.notifications.append($0) },
            postAppNotification: { log.appNotifications.append(($0, $1)) },
            hasReviewPanel: { _ in log.reviewPanelOpen },
            openReview: { request in
                log.reviews.append(request)
                return log.reviewError
            },
            run: { request in
                log.runs.append(request)
                return log.runResult
            },
            offMain: { work in work() },
            onMain: { body in MainActor.assumeIsolated { body() } },
            loginShell: { "/bin/zsh" },
            homeDirectory: "/Users/someone"
        ))
    }

    private func install(_ route: String) throws -> RouteActions {
        let config = try ProgramaConfigStore.decodeConfig(Data(#"{ "routes": [ \#(route) ] }"#.utf8))
        XCTAssertEqual(config.routeIssues, [])
        let actions = makeActions()
        engine.executor = actions
        engine.install(routes: config.routes, issues: config.routeIssues, source: .debugOverride)
        return actions
    }

    private func idle(fields extra: [String: String] = [:]) -> RouteEvent {
        RouteEvent(
            topic: "agent/\(surfaceId.uuidString)/state/idle",
            fields: ["workspace_id": workspaceId.uuidString, "surface_id": surfaceId.uuidString, "state": "idle"]
                .merging(extra) { $1 }
        )
    }

    private var route: RouteEngineSnapshot.Route? { engine.snapshot().routes.first }

    // MARK: - notify

    func testNotifyRendersFieldsAndTargetsTheEventSurface() throws {
        let actions = try install(#"""
        { "name": "n", "on": "agent/#", "notify": { "title": "{{state}} on {{git_branch}}", "subtitle": "{{previous_state}}", "body": "x" } }
        """#)
        withExtendedLifetime(actions) {
            engine.ingest(idle(fields: ["git_branch": "main"]))
        }

        XCTAssertEqual(log.notifications, [RouteNotification(
            workspaceId: workspaceId, surfaceId: surfaceId, title: "idle on main", subtitle: "", body: "x"
        )], "an absent field renders empty")
    }

    // MARK: - review

    func testReviewOpensWithTheEventIds() throws {
        let actions = try install(#"{ "name": "r", "on": "agent/#", "review": { "mode": "branch", "baseBranch": "main" } }"#)
        withExtendedLifetime(actions) { engine.ingest(idle()) }

        XCTAssertEqual(log.reviews, [RouteReviewRequest(workspaceId: workspaceId, surfaceId: surfaceId, mode: .branch, baseBranch: "main")])
        XCTAssertNil(route?.lastError)
    }

    func testReviewSkipsAWorkspaceThatAlreadyShowsOne() throws {
        log.reviewPanelOpen = true
        let actions = try install(#"{ "name": "r", "on": "agent/#", "review": {} }"#)
        withExtendedLifetime(actions) { engine.ingest(idle()) }

        XCTAssertEqual(log.reviews, [])
        XCTAssertEqual(route?.counters.fired, 1)
        XCTAssertNil(route?.lastError)
    }

    func testReviewErrorBecomesTheLastError() throws {
        log.reviewError = "unavailable: Not a git repository: /tmp"
        let actions = try install(#"{ "name": "r", "on": "agent/#", "review": {} }"#)
        withExtendedLifetime(actions) { engine.ingest(idle()) }

        XCTAssertEqual(route?.lastError, "review: unavailable: Not a git repository: /tmp")
    }

    // MARK: - run

    func testRunPassesFieldsAsEnvironmentAndSucceedsSilently() throws {
        let actions = try install(#"{ "name": "t", "on": "agent/#", "run": { "command": "npm test -- {{x}}" } }"#)
        withExtendedLifetime(actions) {
            engine.ingest(idle(fields: ["cwd": "/repo", "program_status.state": "done"]))
            engine.ingest(idle(fields: ["cwd": "/repo"]))
        }

        let request = try XCTUnwrap(log.runs.first)
        XCTAssertEqual(request.shell, "/bin/zsh")
        XCTAssertEqual(request.command, "npm test -- {{x}}", "the command string is never templated")
        XCTAssertEqual(request.directory, "/repo")
        XCTAssertEqual(request.timeout, 600)
        XCTAssertEqual(request.environment["PROGRAMA_ROUTE_STATE"], "idle")
        XCTAssertEqual(request.environment["PROGRAMA_ROUTE_SURFACE_ID"], surfaceId.uuidString)
        XCTAssertEqual(request.environment["PROGRAMA_ROUTE_TOPIC"], "agent/\(surfaceId.uuidString)/state/idle")
        XCTAssertEqual(request.environment["PROGRAMA_ROUTE_PROGRAM_STATUS_STATE"], "done")
        XCTAssertEqual(route?.counters, RouteCounters(matched: 2, fired: 2), "a finished run releases its route")
        XCTAssertNil(route?.lastError)
        XCTAssertEqual(log.notifications, [])
    }

    func testRunWithoutCwdStartsInHome() throws {
        let actions = try install(#"{ "name": "t", "on": "agent/#", "run": { "command": "true", "timeoutMs": "30s" } }"#)
        withExtendedLifetime(actions) { engine.ingest(idle()) }

        XCTAssertEqual(log.runs.first?.directory, "/Users/someone")
        XCTAssertEqual(log.runs.first?.timeout, 30)
    }

    func testFailedRunNotifiesWithTheOutputTailAndSetsTheLastError() throws {
        log.runResult = CanonicalSubprocessResult(
            stdout: "1 passing\n", stderr: "1 failing\n", exitStatus: 2, outcome: .exited
        )
        let actions = try install(#"{ "name": "tests", "on": "agent/#", "run": { "command": "npm test" } }"#)
        withExtendedLifetime(actions) { engine.ingest(idle()) }

        XCTAssertEqual(route?.lastError, "exited with status 2")
        let notification = try XCTUnwrap(log.notifications.first)
        XCTAssertEqual(notification.workspaceId, workspaceId)
        XCTAssertEqual(notification.surfaceId, surfaceId)
        XCTAssertTrue(notification.title.contains("tests"), notification.title)
        XCTAssertTrue(notification.subtitle.contains("2"), notification.subtitle)
        XCTAssertEqual(notification.body, "1 passing\n1 failing")
    }

    func testTimedOutRunIsAFailure() throws {
        log.runResult = CanonicalSubprocessResult(stdout: nil, stderr: nil, exitStatus: nil, outcome: .timedOut)
        let actions = try install(#"{ "name": "slow", "on": "agent/#", "run": { "command": "sleep 9", "timeoutMs": "4s" } }"#)
        withExtendedLifetime(actions) { engine.ingest(idle()) }

        XCTAssertEqual(route?.lastError, "timed out after 4 s")
        XCTAssertEqual(log.notifications.count, 1)
    }

    func testRunFailureMapping() {
        func failure(_ status: Int32?, _ outcome: CanonicalSubprocessResult.Outcome, stdout: String? = "") -> RouteRunFailure? {
            RouteRunFailure(
                CanonicalSubprocessResult(stdout: stdout, stderr: "", exitStatus: status, outcome: outcome),
                timeout: 600
            )
        }
        XCTAssertNil(failure(0, .exited))
        XCTAssertNil(failure(0, .stdoutLimitExceeded, stdout: nil), "a zero exit with too much output is still success")
        XCTAssertEqual(failure(1, .stdoutLimitExceeded, stdout: nil), .exitStatus(1, tail: ""))
        XCTAssertEqual(failure(nil, .launchError("no such file")), .launch("no such file"))
        XCTAssertEqual(
            failure(1, .exited, stdout: String(repeating: "a", count: 1000) + "END"),
            .exitStatus(1, tail: String(repeating: "a", count: RouteRunFailure.outputTailLimit - 3) + "END")
        )
    }

    // MARK: - send, prompt, load issues

    func testSendEndsItsDeliveryAtOnce() throws {
        let actions = try install(#"{ "name": "s", "on": "agent/#", "send": { "text": "hi {{state}}" } }"#)
        withExtendedLifetime(actions) {
            engine.ingest(idle())
            engine.ingest(idle())
        }

        XCTAssertEqual(route?.counters, RouteCounters(matched: 2, fired: 2))
    }

    func testLoadIssuesPostOneAppNotificationNamingTheFirst() {
        let actions = makeActions()
        actions.reportLoadIssues([
            ProgramaRouteIssue(index: 0, name: "first", message: "bad"),
            ProgramaRouteIssue(index: 3, name: nil, message: "worse"),
        ])
        actions.reportLoadIssues([ProgramaRouteIssue(index: 2, name: nil, message: "bad")])

        XCTAssertEqual(log.appNotifications.count, 2)
        XCTAssertTrue(log.appNotifications[0].body.contains("first"), log.appNotifications[0].body)
        XCTAssertTrue(log.appNotifications[0].body.contains("1"), log.appNotifications[0].body)
        XCTAssertTrue(log.appNotifications[1].body.contains("#3"), log.appNotifications[1].body)
    }
}
