import XCTest

#if canImport(Programa_DEV)
@testable import Programa_DEV
#elseif canImport(Programa)
@testable import Programa
#endif

// MARK: - Topic patterns and `when`

final class RouteMatchingTests: XCTestCase {

    private func route(_ json: String, file: StaticString = #filePath, line: UInt = #line) throws -> ProgramaRouteDefinition {
        let config = try JSONDecoder().decode(ProgramaConfigFile.self, from: Data(#"{ "routes": [ \#(json) ] }"#.utf8))
        XCTAssertEqual(config.routeIssues, [], file: file, line: line)
        return try XCTUnwrap(config.routes.first, file: file, line: line)
    }

    private func pattern(_ text: String) throws -> ProgramaRouteTopicPattern {
        try ProgramaRouteTopicPattern(parsing: text)
    }

    func testSingleLevelWildcard() throws {
        let idle = try pattern("agent/+/state/idle")
        XCTAssertTrue(idle.matches(topic: "agent/S1/state/idle"))
        XCTAssertFalse(idle.matches(topic: "agent/S1/state/working"))
        XCTAssertFalse(idle.matches(topic: "agent/S1/needs_input/idle"))
        XCTAssertFalse(idle.matches(topic: "agent/S1/extra/state/idle"), "+ matches exactly one level")
        XCTAssertFalse(idle.matches(topic: "agent/S1/state/idle/more"))
        XCTAssertFalse(idle.matches(topic: "agent/S1/state"))

        let closed = try pattern("workspace/+/closed")
        XCTAssertTrue(closed.matches(topic: "workspace/W1/closed"))
        XCTAssertFalse(closed.matches(topic: "workspace/W1/created"))
    }

    func testMultiLevelWildcard() throws {
        let needsInput = try pattern("agent/+/needs_input/#")
        XCTAssertTrue(needsInput.matches(topic: "agent/S1/needs_input/question"))
        XCTAssertTrue(needsInput.matches(topic: "agent/S1/needs_input/permission"))
        XCTAssertFalse(needsInput.matches(topic: "agent/S1/state/idle"))

        let agent = try pattern("agent/#")
        XCTAssertTrue(agent.matches(topic: "agent/S1/state/idle"))
        XCTAssertTrue(agent.matches(topic: "agent/S1/needs_input/unknown"))
        XCTAssertTrue(agent.matches(topic: "agent"), "MQTT: a/# also matches its parent level")
        XCTAssertFalse(agent.matches(topic: "workspace/W1/closed"))

        let everything = try pattern("#")
        XCTAssertTrue(everything.matches(topic: "workspace/W1/renamed"))
        XCTAssertTrue(everything.matches(topic: "agent/S1/state/none"))
    }

    func testLiteralPatternMatchesOnlyItself() throws {
        let exact = try pattern("agent/S1/state/blocked")
        XCTAssertTrue(exact.matches(topic: "agent/S1/state/blocked"))
        XCTAssertFalse(exact.matches(topic: "agent/S2/state/blocked"))
    }

    func testEqualityMatchesStringsBooleansAndNumbers() throws {
        let condition = ProgramaRouteCondition.equals("true")
        XCTAssertTrue(condition.holds(for: "true"))
        XCTAssertFalse(condition.holds(for: "false"))
        XCTAssertFalse(condition.holds(for: nil))

        let numeric = try route(#"{ "name": "n", "on": "agent/#", "review": {}, "when": { "ts": 42, "worktree": true } }"#)
        XCTAssertTrue(numeric.matches(RouteEvent(topic: "agent/S/state/idle", fields: ["ts": "42", "worktree": "true"])))
        XCTAssertFalse(numeric.matches(RouteEvent(topic: "agent/S/state/idle", fields: ["ts": "43", "worktree": "true"])))
    }

    func testNotEqualsHoldsForAbsentFields() {
        let condition = ProgramaRouteCondition.notEquals("working")
        XCTAssertTrue(condition.holds(for: "idle"))
        XCTAssertFalse(condition.holds(for: "working"))
        XCTAssertTrue(condition.holds(for: nil))
    }

    func testInMatchesAnyElement() {
        let condition = ProgramaRouteCondition.oneOf(["working", "blocked"])
        XCTAssertTrue(condition.holds(for: "working"))
        XCTAssertTrue(condition.holds(for: "blocked"))
        XCTAssertFalse(condition.holds(for: "idle"))
        XCTAssertFalse(condition.holds(for: nil))
    }

    func testExists() {
        XCTAssertTrue(ProgramaRouteCondition.exists(true).holds(for: "x"))
        XCTAssertFalse(ProgramaRouteCondition.exists(true).holds(for: nil))
        XCTAssertTrue(ProgramaRouteCondition.exists(false).holds(for: nil))
        XCTAssertFalse(ProgramaRouteCondition.exists(false).holds(for: "x"))
    }

    func testRegexSearchesAndHonorsFlags() throws {
        let sensitive = ProgramaRouteCondition.matches(try ProgramaRouteRegex(pattern: "/work/", flags: ""))
        XCTAssertTrue(sensitive.holds(for: "/Users/a/work/app"), "a regex matches anywhere in the value")
        XCTAssertFalse(sensitive.holds(for: "/Users/a/WORK/app"))
        XCTAssertFalse(sensitive.holds(for: nil))

        let insensitive = ProgramaRouteCondition.matches(try ProgramaRouteRegex(pattern: "^/users/.+/work", flags: "i"))
        XCTAssertTrue(insensitive.holds(for: "/Users/a/WORK/app"))
        XCTAssertFalse(insensitive.holds(for: "/tmp/work"))
    }

    func testAbsentFieldFailsEveryConditionButNotEqualsAndExistsFalse() throws {
        let regex = try ProgramaRouteRegex(pattern: ".*", flags: "")
        let failing: [ProgramaRouteCondition] = [.equals(""), .oneOf([""]), .exists(true), .matches(regex)]
        for condition in failing {
            XCTAssertFalse(condition.holds(for: nil), "\(condition)")
        }
        XCTAssertTrue(ProgramaRouteCondition.notEquals("x").holds(for: nil))
        XCTAssertTrue(ProgramaRouteCondition.exists(false).holds(for: nil))
    }

    func testEmptyValueIsAnAbsentField() {
        let event = RouteEvent(topic: "agent/S/state/idle", fields: ["body": "", "state": "idle"])
        XCTAssertNil(event.fields["body"])
        XCTAssertEqual(event.values["topic"], "agent/S/state/idle")
    }

    func testRouteNeedsTopicAndEveryWhenClause() throws {
        let idleAfterWork = try route("""
        { "name": "n", "on": "agent/+/state/idle", "review": {},
          "when": { "previous_state": { "in": ["working", "blocked"] }, "worktree": "true" } }
        """)
        let fields = ["previous_state": "working", "worktree": "true", "state": "idle"]
        XCTAssertTrue(idleAfterWork.matches(RouteEvent(topic: "agent/S/state/idle", fields: fields)))
        XCTAssertFalse(
            idleAfterWork.matches(RouteEvent(topic: "agent/S/state/working", fields: fields)),
            "the topic must match before when is read"
        )
        var notWorktree = fields
        notWorktree["worktree"] = "false"
        XCTAssertFalse(idleAfterWork.matches(RouteEvent(topic: "agent/S/state/idle", fields: notWorktree)))
        var sessionStart = fields
        sessionStart.removeValue(forKey: "previous_state")
        XCTAssertFalse(
            idleAfterWork.matches(RouteEvent(topic: "agent/S/state/idle", fields: sessionStart)),
            "the idle a session starts with has no previous state"
        )
    }

    func testWhenCanNameTheTopic() throws {
        let route = try route(#"{ "name": "n", "on": "agent/#", "review": {}, "when": { "topic": { "regex": "/needs_input/" } } }"#)
        XCTAssertTrue(route.matches(RouteEvent(topic: "agent/S/needs_input/question", fields: [:])))
        XCTAssertFalse(route.matches(RouteEvent(topic: "agent/S/state/idle", fields: [:])))
    }
}

// MARK: - The gate reducer

final class RouteGateTests: XCTestCase {

    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func at(_ seconds: TimeInterval) -> Date {
        t0.addingTimeInterval(seconds)
    }

    private func event(_ id: String = "e") -> RouteEvent {
        RouteEvent(topic: "agent/S1/needs_input/question", fields: ["surface_id": "S1", "body": id])
    }

    private func compiled(
        debounceMs: Int? = nil,
        throttleMs: Int? = nil,
        action: ProgramaRouteAction = .notify(title: "t", subtitle: nil, body: nil)
    ) throws -> CompiledRoute {
        CompiledRoute(ProgramaRouteDefinition(
            name: "r",
            on: try ProgramaRouteTopicPattern(parsing: "agent/#"),
            when: [],
            debounceMs: debounceMs,
            throttleMs: throttleMs,
            key: ProgramaRouteDefinition.defaultKey,
            action: action
        ))
    }

    private var run: ProgramaRouteAction { .run(command: "make", timeoutMs: nil) }

    private func reduce(
        _ state: RouteGateState?,
        _ input: RouteGateInput,
        _ route: CompiledRoute
    ) -> (RouteGateState?, [RouteGateEffect]) {
        RouteGate.reduce(state, input, route: route)
    }

    // MARK: Transition table, row by row

    func testIdleMatchWithDebounceStartsDebouncing() throws {
        let (state, effects) = reduce(nil, .matched(event(), now: at(0)), try compiled(debounceMs: 2000))
        XCTAssertEqual(state, .debouncing(pending: event(), deadline: at(2), cooldownUntil: nil))
        XCTAssertEqual(effects, [.wake(at: at(2))])
    }

    func testIdleMatchWithoutDebounceFires() throws {
        let (state, effects) = reduce(nil, .matched(event(), now: at(0)), try compiled())
        XCTAssertNil(state, "no throttle and no delivery: straight back to idle")
        XCTAssertEqual(effects, [.fire(event()), .count(.fired)])
    }

    func testFireWithThrottleCoolsDownAndSchedulesTheEnd() throws {
        let (state, effects) = reduce(nil, .matched(event(), now: at(0)), try compiled(throttleMs: 5000))
        XCTAssertEqual(state, .coolingDown(until: at(5)))
        XCTAssertEqual(effects, [.fire(event()), .count(.fired), .wake(at: at(5))])
    }

    func testDebouncingMatchRestartsTheTimerWithTheNewestEvent() throws {
        let start = RouteGateState.debouncing(pending: event("old"), deadline: at(2), cooldownUntil: at(9))
        let (state, effects) = reduce(start, .matched(event("new"), now: at(1)), try compiled(debounceMs: 2000))
        XCTAssertEqual(state, .debouncing(pending: event("new"), deadline: at(3), cooldownUntil: at(9)))
        XCTAssertEqual(effects, [.wake(at: at(3))])
    }

    func testDebouncingEarlyWakeIsANoOp() throws {
        let start = RouteGateState.debouncing(pending: event(), deadline: at(2), cooldownUntil: nil)
        let (state, effects) = reduce(start, .wake(now: at(1.5)), try compiled(debounceMs: 2000))
        XCTAssertEqual(state, start)
        XCTAssertEqual(effects, [])
    }

    func testDebouncingWakeUnderLiveCooldownDropsTheCandidate() throws {
        let start = RouteGateState.debouncing(pending: event(), deadline: at(2), cooldownUntil: at(10))
        let (state, effects) = reduce(start, .wake(now: at(2)), try compiled(debounceMs: 2000, throttleMs: 10_000))
        XCTAssertEqual(state, .coolingDown(until: at(10)))
        XCTAssertEqual(effects, [.count(.throttled), .wake(at: at(10))])
    }

    func testDebouncingWakeWithoutLiveCooldownFiresThePendingEvent() throws {
        let route = try compiled(debounceMs: 2000, throttleMs: 10_000)
        let expired = RouteGateState.debouncing(pending: event("p"), deadline: at(2), cooldownUntil: at(1))
        let (state, effects) = reduce(expired, .wake(now: at(2)), route)
        XCTAssertEqual(state, .coolingDown(until: at(12)))
        XCTAssertEqual(effects, [.fire(event("p")), .count(.fired), .wake(at: at(12))])

        let none = RouteGateState.debouncing(pending: event("p"), deadline: at(2), cooldownUntil: nil)
        XCTAssertEqual(reduce(none, .wake(now: at(2.5)), route).1, [.fire(event("p")), .count(.fired), .wake(at: at(12.5))])
    }

    func testCoolingDownMatchAfterTheWindowActsAsIdle() throws {
        let start = RouteGateState.coolingDown(until: at(5))
        let fired = reduce(start, .matched(event(), now: at(5)), try compiled(throttleMs: 5000))
        XCTAssertEqual(fired.0, .coolingDown(until: at(10)))
        XCTAssertEqual(fired.1, [.fire(event()), .count(.fired), .wake(at: at(10))])

        let debounced = reduce(start, .matched(event(), now: at(6)), try compiled(debounceMs: 1000, throttleMs: 5000))
        XCTAssertEqual(debounced.0, .debouncing(pending: event(), deadline: at(7), cooldownUntil: nil))
        XCTAssertEqual(debounced.1, [.wake(at: at(7))])
    }

    func testCoolingDownMatchInsideTheWindowWithDebounceKeepsTheCooldown() throws {
        let (state, effects) = reduce(
            .coolingDown(until: at(5)),
            .matched(event(), now: at(1)),
            try compiled(debounceMs: 1000, throttleMs: 5000)
        )
        XCTAssertEqual(state, .debouncing(pending: event(), deadline: at(2), cooldownUntil: at(5)))
        XCTAssertEqual(effects, [.wake(at: at(2))])
    }

    func testCoolingDownMatchInsideTheWindowWithoutDebounceIsThrottled() throws {
        let start = RouteGateState.coolingDown(until: at(5))
        let (state, effects) = reduce(start, .matched(event(), now: at(4.999)), try compiled(throttleMs: 5000))
        XCTAssertEqual(state, start)
        XCTAssertEqual(effects, [.count(.throttled)])
    }

    func testCoolingDownWakeClearsTheEntryOnlyOnceTheWindowEnds() throws {
        let start = RouteGateState.coolingDown(until: at(5))
        let route = try compiled(throttleMs: 5000)
        XCTAssertEqual(reduce(start, .wake(now: at(4)), route).0, start)
        let (state, effects) = reduce(start, .wake(now: at(5)), route)
        XCTAssertNil(state)
        XCTAssertEqual(effects, [])
    }

    func testDeliveringMatchIsCountedBusy() throws {
        let start = RouteGateState.delivering(.running, expiresAt: at(600), cooldownUntil: nil)
        let (state, effects) = reduce(start, .matched(event(), now: at(1)), try compiled(action: run))
        XCTAssertEqual(state, start)
        XCTAssertEqual(effects, [.count(.busy)])
    }

    func testDeliveryEndedCoolsDownWhileTheWindowLastsElseGoesIdle() throws {
        let route = try compiled(throttleMs: 10_000, action: run)
        let start = RouteGateState.delivering(.running, expiresAt: at(600), cooldownUntil: at(10))

        let cooling = reduce(start, .deliveryEnded(now: at(3)), route)
        XCTAssertEqual(cooling.0, .coolingDown(until: at(10)))
        XCTAssertEqual(cooling.1, [.wake(at: at(10))])

        let idle = reduce(start, .deliveryEnded(now: at(10)), route)
        XCTAssertNil(idle.0)
        XCTAssertEqual(idle.1, [])

        let unthrottled = RouteGateState.delivering(.running, expiresAt: at(600), cooldownUntil: nil)
        XCTAssertNil(reduce(unthrottled, .deliveryEnded(now: at(3)), try compiled(action: run)).0)
    }

    func testDeliveringExpiryCancelsTheDelivery() throws {
        let route = try compiled(throttleMs: 900_000, action: run)
        let start = RouteGateState.delivering(.running, expiresAt: at(600), cooldownUntil: at(900))

        XCTAssertEqual(reduce(start, .wake(now: at(599)), route).0, start, "an early wake is a no-op")
        XCTAssertEqual(reduce(start, .wake(now: at(599)), route).1, [])

        let cooling = reduce(start, .wake(now: at(600)), route)
        XCTAssertEqual(cooling.0, .coolingDown(until: at(900)))
        XCTAssertEqual(cooling.1, [.cancelDelivery, .count(.expired), .wake(at: at(900))])

        let unthrottled = RouteGateState.delivering(.running, expiresAt: at(600), cooldownUntil: nil)
        let idle = reduce(unthrottled, .wake(now: at(600)), try compiled(action: run))
        XCTAssertNil(idle.0)
        XCTAssertEqual(idle.1, [.cancelDelivery, .count(.expired)])
    }

    func testStaleInputsAreNoOps() throws {
        let route = try compiled(debounceMs: 1000, throttleMs: 5000)
        XCTAssertNil(reduce(nil, .wake(now: at(1)), route).0)
        XCTAssertEqual(reduce(nil, .wake(now: at(1)), route).1, [])
        XCTAssertNil(reduce(nil, .deliveryEnded(now: at(1)), route).0)

        let debouncing = RouteGateState.debouncing(pending: event(), deadline: at(2), cooldownUntil: nil)
        XCTAssertEqual(reduce(debouncing, .deliveryEnded(now: at(1)), route).0, debouncing)
        let cooling = RouteGateState.coolingDown(until: at(5))
        XCTAssertEqual(reduce(cooling, .deliveryEnded(now: at(1)), route).0, cooling)
        XCTAssertEqual(reduce(cooling, .deliveryEnded(now: at(1)), route).1, [])
    }

    // MARK: Actions that hold the route

    func testRunFiresIntoDeliveringUntilItsTimeout() throws {
        let (state, effects) = reduce(nil, .matched(event(), now: at(0)), try compiled(throttleMs: 1000, action: run))
        XCTAssertEqual(state, .delivering(.running, expiresAt: at(600), cooldownUntil: at(1)))
        XCTAssertEqual(effects, [.fire(event()), .count(.fired), .wake(at: at(600))])

        let custom = try compiled(action: .run(command: "make", timeoutMs: 30_000))
        XCTAssertEqual(reduce(nil, .matched(event(), now: at(0)), custom).0, .delivering(.running, expiresAt: at(30), cooldownUntil: nil))
    }

    func testSendAndPromptHoldTheRouteWithTheirEvent() throws {
        let send = try compiled(action: .send(text: "go", whenBusy: .queue))
        XCTAssertEqual(
            reduce(nil, .matched(event(), now: at(0)), send).0,
            .delivering(.waitingForIdle(event()), expiresAt: at(600), cooldownUntil: nil)
        )
        let prompt = try compiled(throttleMs: 60_000, action: .prompt(text: "go", whenBusy: .steer))
        XCTAssertEqual(
            reduce(nil, .matched(event(), now: at(0)), prompt).0,
            .delivering(.waitingForIdle(event()), expiresAt: at(600), cooldownUntil: at(60))
        )
    }

    func testReviewDoesNotHoldTheRoute() throws {
        let review = try compiled(action: .review(mode: nil, baseBranch: nil))
        XCTAssertNil(review.deliveryTimeout)
        XCTAssertNil(reduce(nil, .matched(event(), now: at(0)), review).0)
    }

    // MARK: Sequences

    /// Runs inputs through the reducer the way the engine will: one state per key, and every
    /// wake the reducer schedules delivered at its time, in time order with the matches.
    private final class Driver {
        let route: CompiledRoute
        var states: [String: RouteGateState] = [:]
        var fired: [String: [RouteEvent]] = [:]
        var counters: [RouteCounter: Int] = [:]
        private var wakes: [(key: String, at: Date)] = []

        init(_ route: CompiledRoute) {
            self.route = route
        }

        func match(_ event: RouteEvent, key: String, at now: Date) {
            runWakes(through: now)
            apply(.matched(event, now: now), key: key)
        }

        func runWakes(through now: Date) {
            while let next = wakes.enumerated().filter({ $0.element.at <= now }).min(by: { $0.element.at < $1.element.at }) {
                wakes.remove(at: next.offset)
                apply(.wake(now: next.element.at), key: next.element.key)
            }
        }

        private func apply(_ input: RouteGateInput, key: String) {
            let (next, effects) = RouteGate.reduce(states[key], input, route: route)
            states[key] = next
            for effect in effects {
                switch effect {
                case .fire(let event): fired[key, default: []].append(event)
                case .wake(let date): wakes.append((key: key, at: date))
                case .count(let counter): counters[counter, default: 0] += 1
                case .cancelDelivery: break
                }
            }
        }
    }

    func testThrottleOfFiveMinutesFiresOncePerWindow() throws {
        let driver = Driver(try compiled(throttleMs: 300_000))
        for second in [0.0, 60, 299] {
            driver.match(event("\(second)"), key: "k", at: at(second))
        }
        XCTAssertEqual(driver.fired["k"], [event("0.0")], "matches at 0 s, 60 s and 299 s fire once")
        XCTAssertEqual(driver.counters[.throttled], 2)

        driver.match(event("300"), key: "k", at: at(300))
        XCTAssertEqual(driver.fired["k"], [event("0.0"), event("300")], "a match at 300 s fires again")
        XCTAssertEqual(driver.counters[.fired], 2)
    }

    func testTwoKeysDoNotShareAWindow() throws {
        let driver = Driver(try compiled(throttleMs: 300_000))
        driver.match(event("a1"), key: "agent/S1/needs_input/question", at: at(0))
        driver.match(event("b1"), key: "agent/S2/needs_input/question", at: at(10))
        driver.match(event("a2"), key: "agent/S1/needs_input/question", at: at(20))

        XCTAssertEqual(driver.fired["agent/S1/needs_input/question"], [event("a1")])
        XCTAssertEqual(driver.fired["agent/S2/needs_input/question"], [event("b1")])
        XCTAssertEqual(driver.counters[.throttled], 1)
    }

    func testDebounceThenThrottle() throws {
        let driver = Driver(try compiled(debounceMs: 2000, throttleMs: 10_000))

        // A burst at 0 s and 1 s: one candidate, the newest, handled at 3 s. Cooldown to 13 s.
        driver.match(event("burst-1"), key: "k", at: at(0))
        driver.match(event("burst-2"), key: "k", at: at(1))
        driver.runWakes(through: at(3))
        XCTAssertEqual(driver.fired["k"], [event("burst-2")])

        // The next burst settles at 7 s, inside the window: throttle drops the candidate.
        driver.match(event("inside"), key: "k", at: at(5))
        driver.runWakes(through: at(7))
        XCTAssertEqual(driver.fired["k"]?.count, 1)
        XCTAssertEqual(driver.counters[.throttled], 1)

        // After the window: debounce again, then fire.
        driver.match(event("after"), key: "k", at: at(14))
        driver.runWakes(through: at(15.9))
        XCTAssertEqual(driver.fired["k"]?.count, 1, "still debouncing")
        driver.runWakes(through: at(16))
        XCTAssertEqual(driver.fired["k"], [event("burst-2"), event("after")])
        XCTAssertEqual(driver.counters[.fired], 2)
    }

    func testDebounceFiresTheLastEventOnceTheBurstGoesQuiet() throws {
        let driver = Driver(try compiled(debounceMs: 2000))
        driver.match(event("idle"), key: "k", at: at(0))
        driver.runWakes(through: at(1.9))
        XCTAssertNil(driver.fired["k"])
        driver.runWakes(through: at(2))
        XCTAssertEqual(driver.fired["k"], [event("idle")])
        XCTAssertNil(driver.states["k"])
    }

    func testRunRouteDropsMatchesWhileItsProcessRuns() throws {
        let driver = Driver(try compiled(action: run))
        driver.match(event("1"), key: "k", at: at(0))
        driver.match(event("2"), key: "k", at: at(30))
        XCTAssertEqual(driver.fired["k"], [event("1")])
        XCTAssertEqual(driver.counters[.busy], 1)

        driver.runWakes(through: at(600))
        XCTAssertEqual(driver.counters[.expired], 1)
        XCTAssertNil(driver.states["k"])
    }
}
