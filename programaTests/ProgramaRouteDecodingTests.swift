import XCTest

#if canImport(Programa_DEV)
@testable import Programa_DEV
#elseif canImport(Programa)
@testable import Programa
#endif

final class ProgramaRouteDecodingTests: XCTestCase {

    private func decode(_ json: String) throws -> ProgramaConfigFile {
        try JSONDecoder().decode(ProgramaConfigFile.self, from: Data(json.utf8))
    }

    /// Decodes a file whose only route is `route` and returns its single issue message.
    private func issue(
        forRoute route: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> String {
        let config = try decode(#"{ "routes": [ \#(route) ] }"#)
        XCTAssertTrue(config.routes.isEmpty, "the route must not load", file: file, line: line)
        XCTAssertEqual(config.routeIssues.count, 1, "expected one issue", file: file, line: line)
        XCTAssertEqual(config.routeIssues.first?.index, 0, file: file, line: line)
        return config.routeIssues.first?.message ?? ""
    }

    private func assertIssue(
        _ route: String,
        mentions fragment: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let message = try issue(forRoute: route, file: file, line: line)
        XCTAssertTrue(
            message.contains(fragment),
            "Expected the issue to mention \"\(fragment)\", got: \(message)",
            file: file,
            line: line
        )
    }

    private func onlyRoute(_ route: String, file: StaticString = #filePath, line: UInt = #line) throws -> ProgramaRouteDefinition {
        let config = try decode(#"{ "routes": [ \#(route) ] }"#)
        XCTAssertEqual(config.routeIssues, [], file: file, line: line)
        return try XCTUnwrap(config.routes.first, file: file, line: line)
    }

    // MARK: - Loading

    func testRoutesOnlyFileLoads() throws {
        let config = try decode("""
        {
          "routes": [{
            "name": "blocked-question",
            "on": "agent/+/needs_input/question",
            "throttleMs": "5m",
            "notify": { "title": "Agent needs you", "body": "{{body}}" }
          }]
        }
        """)

        XCTAssertEqual(config.commands, [])
        XCTAssertNil(config.recipes)
        XCTAssertEqual(config.routeIssues, [])
        let route = try XCTUnwrap(config.routes.first)
        XCTAssertEqual(route.name, "blocked-question")
        XCTAssertEqual(route.on.text, "agent/+/needs_input/question")
        XCTAssertEqual(route.throttleMs, 300_000)
        XCTAssertNil(route.debounceMs)
        XCTAssertEqual(route.key, "{{topic}}")
        XCTAssertEqual(route.action, .notify(title: "Agent needs you", subtitle: nil, body: "{{body}}"))
    }

    func testFileWithoutRoutesHasNoRoutesAndNoIssues() throws {
        let config = try decode(#"{ "commands": [{ "name": "Build", "command": "make" }] }"#)
        XCTAssertEqual(config.routes, [])
        XCTAssertEqual(config.routeIssues, [])
    }

    func testOneBadRouteLeavesEverythingElseLoaded() throws {
        let config = try decode("""
        {
          "commands": [{ "name": "Build", "command": "make" }],
          "recipes": [{ "name": "Explain", "prompt": "explain this" }],
          "routes": [
            { "name": "first", "on": "agent/+/state/idle", "review": {} },
            { "name": "broken", "on": "agent/#/state", "review": {} },
            { "name": "last", "on": "workspace/+/closed", "notify": { "title": "closed" } }
          ]
        }
        """)

        XCTAssertEqual(config.commands.map(\.name), ["Build"])
        XCTAssertEqual(config.recipes?.map(\.name), ["Explain"])
        XCTAssertEqual(config.routes.map(\.name), ["first", "last"])
        XCTAssertEqual(config.routeIssues.count, 1)
        let issue = try XCTUnwrap(config.routeIssues.first)
        XCTAssertEqual(issue.index, 1)
        XCTAssertEqual(issue.name, "broken")
        XCTAssertTrue(issue.message.contains("'#'"), issue.message)
    }

    func testRoutesThatIsNotAnArrayIsOneIssueAndCommandsStillLoad() throws {
        let config = try decode(#"{ "commands": [{ "name": "Build", "command": "make" }], "routes": {} }"#)
        XCTAssertEqual(config.commands.map(\.name), ["Build"])
        XCTAssertEqual(config.routes, [])
        XCTAssertEqual(config.routeIssues, [ProgramaRouteIssue(index: nil, name: nil, message: "'routes' must be an array")])
    }

    func testTicketExamplesDecode() throws {
        let config = try decode("""
        {
          "routes": [
            {
              "name": "tests-on-idle",
              "on": "agent/+/state/idle",
              "when": { "previous_state": { "in": ["working", "blocked"] }, "worktree": "true" },
              "debounceMs": 2000,
              "run": { "command": "npm test" }
            },
            {
              "name": "review-on-idle",
              "on": "agent/+/state/idle",
              "when": { "previous_state": { "in": ["working", "blocked"] }, "worktree": true },
              "debounceMs": 2000,
              "review": { "mode": "branch", "baseBranch": "origin/main" }
            }
          ]
        }
        """)

        XCTAssertEqual(config.routeIssues, [])
        XCTAssertEqual(config.routes.count, 2)
        let tests = config.routes[0]
        XCTAssertEqual(tests.debounceMs, 2000)
        XCTAssertEqual(tests.action, .run(command: "npm test", timeoutMs: nil))
        XCTAssertEqual(tests.when, [
            ProgramaRouteClause(field: "previous_state", conditions: [.oneOf(["working", "blocked"])]),
            ProgramaRouteClause(field: "worktree", conditions: [.equals("true")]),
        ])
        // A JSON boolean compares as its text, so both spellings decode alike.
        XCTAssertEqual(config.routes[1].when, tests.when)
        XCTAssertEqual(config.routes[1].action, .review(mode: .branch, baseBranch: "origin/main"))
    }

    func testEveryActionDecodes() throws {
        XCTAssertEqual(
            try onlyRoute(#"{ "name": "n", "on": "agent/#", "notify": { "title": "t", "subtitle": "s", "body": "b" } }"#).action,
            .notify(title: "t", subtitle: "s", body: "b")
        )
        XCTAssertEqual(
            try onlyRoute(#"{ "name": "n", "on": "agent/#", "send": { "text": "continue {{surface_id}}" } }"#).action,
            .send(text: "continue {{surface_id}}", whenBusy: .queue)
        )
        XCTAssertEqual(
            try onlyRoute(#"{ "name": "n", "on": "agent/#", "throttleMs": "1m", "prompt": { "text": "go", "whenBusy": "steer" } }"#).action,
            .prompt(text: "go", whenBusy: .steer)
        )
        XCTAssertEqual(
            try onlyRoute(#"{ "name": "n", "on": "agent/#", "run": { "command": "make", "timeoutMs": "30s" } }"#).action,
            .run(command: "make", timeoutMs: 30_000)
        )
        XCTAssertEqual(
            try onlyRoute(#"{ "name": "n", "on": "agent/#", "review": {} }"#).action,
            .review(mode: nil, baseBranch: nil)
        )
    }

    func testDurationsAcceptMillisecondsAndDurationStrings() throws {
        let cases: [(String, Int)] = [
            ("2000", 2000), (#""4s""#, 4000), (#""5m""#, 300_000), (#""250ms""#, 250),
            (#""1.5s""#, 1500), (#""1h""#, 3_600_000), (#""750""#, 750), ("0", 0),
        ]
        for (value, expected) in cases {
            let route = try onlyRoute(#"{ "name": "n", "on": "agent/#", "debounceMs": \#(value), "review": {} }"#)
            XCTAssertEqual(route.debounceMs, expected, "debounceMs: \(value)")
        }
    }

    func testCustomKeyIsKept() throws {
        let route = try onlyRoute(#"{ "name": "n", "on": "agent/#", "key": "{{surface_id}}", "review": {} }"#)
        XCTAssertEqual(route.key, "{{surface_id}}")
    }

    func testWhenOperatorsDecode() throws {
        let route = try onlyRoute("""
        { "name": "n", "on": "agent/#", "review": {},
          "when": {
            "state": { "ne": "working" },
            "kind": { "exists": true },
            "cwd": { "regex": "^/Users/.+/work", "flags": "i" },
            "ts": 3
          } }
        """)
        XCTAssertEqual(route.when.map(\.field), ["cwd", "kind", "state", "ts"])
        XCTAssertEqual(route.when[1].conditions, [.exists(true)])
        XCTAssertEqual(route.when[2].conditions, [.notEquals("working")])
        XCTAssertEqual(route.when[3].conditions, [.equals("3")])
        guard case .matches(let regex) = route.when[0].conditions.first else {
            return XCTFail("expected a regex condition, got \(route.when[0].conditions)")
        }
        XCTAssertEqual(regex.pattern, "^/Users/.+/work")
        XCTAssertTrue(regex.expression.options.contains(.caseInsensitive))
    }

    // MARK: - Validation rules

    func testBlankNameIsAnIssue() throws {
        try assertIssue(#"{ "name": "  ", "on": "agent/#", "review": {} }"#, mentions: "'name' must not be blank")
    }

    func testMissingNameIsAnIssue() throws {
        try assertIssue(#"{ "on": "agent/#", "review": {} }"#, mentions: "missing 'name'")
    }

    func testDuplicateNameKeepsTheFirstRoute() throws {
        let config = try decode("""
        { "routes": [
          { "name": "same", "on": "agent/#", "review": {} },
          { "name": "same", "on": "workspace/#", "review": {} }
        ] }
        """)
        XCTAssertEqual(config.routes.map(\.on.text), ["agent/#"])
        XCTAssertEqual(config.routeIssues.count, 1)
        XCTAssertEqual(config.routeIssues.first?.index, 1)
        XCTAssertEqual(config.routeIssues.first?.name, "same")
        XCTAssertTrue(config.routeIssues.first?.message.contains("already named 'same'") == true)
    }

    func testInvalidTopicPatternsAreIssues() throws {
        try assertIssue(#"{ "name": "n", "on": "agent/#/idle", "review": {} }"#, mentions: "'#' only as the last level")
        try assertIssue(#"{ "name": "n", "on": "agent//state/idle", "review": {} }"#, mentions: "empty level")
        try assertIssue(#"{ "name": "n", "on": "agent/+/state/", "review": {} }"#, mentions: "empty level")
        try assertIssue(#"{ "name": "n", "on": "", "review": {} }"#, mentions: "empty level")
        try assertIssue(#"{ "name": "n", "on": "surface/+/output", "review": {} }"#, mentions: "'surface' topics")
        try assertIssue(#"{ "name": "n", "on": "agent/a+/state", "review": {} }"#, mentions: "mixes a wildcard")
    }

    func testNegativeOrMalformedDurationsAreIssues() throws {
        try assertIssue(#"{ "name": "n", "on": "agent/#", "debounceMs": -1, "review": {} }"#, mentions: "'debounceMs' must not be negative")
        try assertIssue(#"{ "name": "n", "on": "agent/#", "throttleMs": -5, "review": {} }"#, mentions: "'throttleMs' must not be negative")
        try assertIssue(#"{ "name": "n", "on": "agent/#", "throttleMs": "-5s", "review": {} }"#, mentions: "'throttleMs' is not a duration")
        try assertIssue(#"{ "name": "n", "on": "agent/#", "throttleMs": "5 minutes", "review": {} }"#, mentions: "'throttleMs' is not a duration")
        try assertIssue(#"{ "name": "n", "on": "agent/#", "debounceMs": 1.5, "review": {} }"#, mentions: "'debounceMs' must be a whole number")
        try assertIssue(#"{ "name": "n", "on": "agent/#", "run": { "command": "make", "timeoutMs": 0 } }"#, mentions: "'run.timeoutMs' must be above zero")
    }

    func testRouteNeedsExactlyOneAction() throws {
        try assertIssue(#"{ "name": "n", "on": "agent/#" }"#, mentions: "needs one action")
        try assertIssue(
            #"{ "name": "n", "on": "agent/#", "review": {}, "notify": { "title": "t" } }"#,
            mentions: "one action, found notify, review"
        )
    }

    func testUnknownWhenBusyIsAnIssue() throws {
        try assertIssue(
            #"{ "name": "n", "on": "agent/#", "send": { "text": "go", "whenBusy": "later" } }"#,
            mentions: "'send.whenBusy' is 'later'"
        )
    }

    func testUnknownTemplateFieldIsAnIssue() throws {
        try assertIssue(#"{ "name": "n", "on": "agent/#", "key": "{{surface}}", "review": {} }"#, mentions: "'key' names unknown field 'surface'")
        try assertIssue(#"{ "name": "n", "on": "agent/#", "notify": { "title": "{{bdy}}" } }"#, mentions: "'notify.title' names unknown field 'bdy'")
        try assertIssue(#"{ "name": "n", "on": "agent/#", "notify": { "title": "t", "body": "{{program_status.}}" } }"#, mentions: "unknown field")
        XCTAssertNoThrow(try onlyRoute(#"{ "name": "n", "on": "agent/#", "notify": { "title": "{{ title }}", "body": "{{program_status.step}} {{cwd}}" } }"#))
    }

    func testFreeTextFieldInAgentBoundTextIsAnIssue() throws {
        try assertIssue(
            #"{ "name": "n", "on": "agent/#", "send": { "text": "answer: {{body}}" } }"#,
            mentions: "'send.text' names free-text field 'body'"
        )
        try assertIssue(
            #"{ "name": "n", "on": "agent/#", "throttleMs": 1000, "prompt": { "text": "in {{cwd}}" } }"#,
            mentions: "'prompt.text' names free-text field 'cwd'"
        )
        try assertIssue(
            #"{ "name": "n", "on": "agent/#", "throttleMs": 1000, "prompt": { "text": "{{program_status.step}}" } }"#,
            mentions: "free-text field"
        )        // The agent's hook chooses `provider`, so it is free text too.
        try assertIssue(
            #"{ "name": "n", "on": "agent/#", "send": { "text": "from {{provider}}" } }"#,
            mentions: "'send.text' names free-text field 'provider'"
        )
        XCTAssertNoThrow(try onlyRoute(#"{ "name": "n", "on": "agent/#", "notify": { "title": "{{provider}}" } }"#))
    }

    func testRunCommandIsNotTemplated() throws {
        try assertIssue(
            #"{ "name": "n", "on": "agent/#", "run": { "command": "echo {{surface_id}}" } }"#,
            mentions: "'run.command' names field 'surface_id'"
        )
        // Braces that name no field are the shell's business.
        XCTAssertNoThrow(try onlyRoute(#"{ "name": "n", "on": "agent/#", "run": { "command": "echo {{not_a_field}}" } }"#))
    }

    func testTextRoutesCannotFireOnlyOnNeedsInput() throws {
        try assertIssue(
            #"{ "name": "n", "on": "agent/+/needs_input/#", "send": { "text": "go" } }"#,
            mentions: "'send' route cannot fire on needs_input events"
        )
        try assertIssue(
            #"{ "name": "n", "on": "agent/+/needs_input/question", "throttleMs": "1m", "prompt": { "text": "go" } }"#,
            mentions: "'prompt' route cannot fire on needs_input events"
        )
        XCTAssertNoThrow(try onlyRoute(#"{ "name": "n", "on": "agent/#", "send": { "text": "go" } }"#))
        XCTAssertNoThrow(try onlyRoute(#"{ "name": "n", "on": "agent/+/needs_input/#", "notify": { "title": "t" } }"#))
    }

    func testPromptRouteNeedsThrottle() throws {
        try assertIssue(#"{ "name": "n", "on": "agent/#", "prompt": { "text": "go" } }"#, mentions: "needs a 'throttleMs'")
        try assertIssue(#"{ "name": "n", "on": "agent/#", "throttleMs": 0, "prompt": { "text": "go" } }"#, mentions: "needs a 'throttleMs'")
        try assertIssue(
            #"{ "name": "n", "on": "agent/#", "throttleMs": 59999, "prompt": { "text": "go" } }"#,
            mentions: "at least 60000"
        )
        XCTAssertNoThrow(try onlyRoute(#"{ "name": "n", "on": "agent/#", "throttleMs": 60000, "prompt": { "text": "go" } }"#))
    }

    func testWhenRejectsNestedQuantifiers() throws {
        for pattern in ["(a+)+", "(a*)*", "(\\\\w+\\\\s?)*", "((ab)*c)+", "(x+){2,}", "(?:a+)+$"] {
            try assertIssue(
                #"{ "name": "n", "on": "agent/#", "review": {}, "when": { "body": { "regex": "\#(pattern)" } } }"#,
                mentions: "repeats a group that already repeats"
            )
        }
        for pattern in ["(ab)+", "a+b+", "[a+]+", "\\\\(a+\\\\)+", "(a{2})+", "^/Users/me/work(/|$)", "(?i)fix(es)?"] {
            XCTAssertNoThrow(
                try onlyRoute(#"{ "name": "n", "on": "agent/#", "review": {}, "when": { "body": { "regex": "\#(pattern)" } } }"#),
                pattern
            )
        }
    }

    func testWhenRejectsUnknownOperatorsAndBadRegexes() throws {
        try assertIssue(
            #"{ "name": "n", "on": "agent/#", "review": {}, "when": { "ts": { "gt": 3 } } }"#,
            mentions: "'when.ts' uses unknown operator 'gt'"
        )
        try assertIssue(
            #"{ "name": "n", "on": "agent/#", "review": {}, "when": { "cwd": { "regex": "(" } } }"#,
            mentions: "'when.cwd': invalid regex"
        )
        try assertIssue(
            #"{ "name": "n", "on": "agent/#", "review": {}, "when": { "cwd": { "regex": "x", "flags": "g" } } }"#,
            mentions: "unknown regex flag 'g'"
        )
        try assertIssue(
            #"{ "name": "n", "on": "agent/#", "review": {}, "when": { "cwd": { "flags": "i" } } }"#,
            mentions: "'flags' without 'regex'"
        )
        try assertIssue(
            #"{ "name": "n", "on": "agent/#", "review": {}, "when": { "cwd": {} } }"#,
            mentions: "'when.cwd' has no condition"
        )
        try assertIssue(
            #"{ "name": "n", "on": "agent/#", "review": {}, "when": { "cwd": ["a"] } }"#,
            mentions: "'when.cwd' must be"
        )
    }

    func testUnknownReviewModeIsAnIssue() throws {
        try assertIssue(#"{ "name": "n", "on": "agent/#", "review": { "mode": "staged" } }"#, mentions: "'review.mode' is 'staged'")
    }

    func testWrongTypeIsAnIssueNamingThePath() throws {
        try assertIssue(#"{ "name": "n", "on": "agent/#", "notify": { "title": 3 } }"#, mentions: "'notify.title'")
        try assertIssue(#"{ "name": "n", "on": "agent/#", "notify": {} }"#, mentions: "missing 'notify.title'")
        try assertIssue(#""just a string""#, mentions: "'route'")
    }
}

// MARK: - Store: global routes and the change check

@MainActor
final class ProgramaRouteStoreLoadingTests: XCTestCase {

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

    func testGlobalRoutesLoadAndTheDigestChangesWhenARouteChanges() throws {
        let global = try write("""
        { "routes": [{ "name": "r", "on": "agent/+/state/idle", "throttleMs": 1000, "review": {} }] }
        """, to: "global.json")
        let store = ProgramaConfigStore()
        store.routeEngine = RouteEngine()
        store.localConfigPath = nil
        store.globalConfigPath = global.path
        store.loadAll()

        XCTAssertEqual(store.loadedRoutes.map(\.name), ["r"])
        XCTAssertEqual(store.routeIssues, [])
        let firstDigest = try XCTUnwrap(store.routesDigest)
        let revision = store.configRevision

        try """
        { "routes": [{ "name": "r", "on": "agent/+/state/idle", "throttleMs": 2000, "review": {} }] }
        """.write(to: global, atomically: true, encoding: .utf8)
        store.loadAll()

        XCTAssertEqual(store.loadedRoutes.first?.throttleMs, 2000, "a routes-only edit must not be skipped by the change check")
        XCTAssertNotEqual(store.routesDigest, firstDigest)
        XCTAssertEqual(store.configRevision, revision + 1)

        store.loadAll()
        XCTAssertEqual(store.configRevision, revision + 1, "an unchanged reload must not count as a change")
    }

    func testRouteIssuesLoadWithTheGlobalFile() throws {
        let global = try write("""
        { "routes": [{ "name": "bad", "on": "agent/#/x", "review": {} }] }
        """, to: "global.json")
        let store = ProgramaConfigStore()
        store.routeEngine = RouteEngine()
        store.localConfigPath = nil
        store.globalConfigPath = global.path
        store.loadAll()

        XCTAssertEqual(store.loadedRoutes, [])
        XCTAssertEqual(store.routeIssues.map(\.name), ["bad"])
    }

    func testLocalFileRoutesNeverLoad() throws {
        let local = try write("""
        { "commands": [{ "name": "Local", "command": "echo local" }],
          "routes": [{ "name": "local-route", "on": "agent/#", "review": {} }] }
        """, to: "local.json")
        let store = ProgramaConfigStore()
        store.routeEngine = RouteEngine()
        store.localConfigPath = local.path
        store.globalConfigPath = tempRoot.appendingPathComponent("missing.json").path
        store.loadAll()

        XCTAssertEqual(store.loadedCommands.map(\.name), ["Local"])
        XCTAssertEqual(store.loadedRoutes, [])
        XCTAssertNil(store.routesDigest)
    }
}
