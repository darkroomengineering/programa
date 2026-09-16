// docs/plans/agent-events.md: unit tests for the pure event-type -> AgentActivityState
// normalizer that backs the `agent.event` v2 method (Sources/TerminalController+Telemetry.swift's
// v2AgentEvent). Exercises the "Event type -> AgentActivityState mapping" table exactly —
// event in, Outcome out, no socket/threading plumbing involved.
import XCTest

#if canImport(Programa_DEV)
@testable import Programa_DEV
#elseif canImport(Programa)
@testable import Programa
#endif

final class AgentEventNormalizerTests: XCTestCase {
    func testSessionStartedAppliesIdle() {
        XCTAssertEqual(AgentEventNormalizer.classify(eventType: "session.started"), .applyState(.idle))
    }

    func testTurnStartedAppliesWorking() {
        XCTAssertEqual(AgentEventNormalizer.classify(eventType: "turn.started"), .applyState(.working))
    }

    func testItemStartedAppliesWorking() {
        XCTAssertEqual(AgentEventNormalizer.classify(eventType: "item.started"), .applyState(.working))
    }

    func testItemCompletedAppliesWorking() {
        XCTAssertEqual(AgentEventNormalizer.classify(eventType: "item.completed"), .applyState(.working))
    }

    func testRequestOpenedAppliesBlocked() {
        XCTAssertEqual(AgentEventNormalizer.classify(eventType: "request.opened"), .applyState(.blocked))
    }

    func testRequestResolvedAppliesWorking() {
        XCTAssertEqual(AgentEventNormalizer.classify(eventType: "request.resolved"), .applyState(.working))
    }

    func testUserInputRequestedAppliesBlocked() {
        XCTAssertEqual(AgentEventNormalizer.classify(eventType: "user-input.requested"), .applyState(.blocked))
    }

    func testUserInputResolvedAppliesWorking() {
        XCTAssertEqual(AgentEventNormalizer.classify(eventType: "user-input.resolved"), .applyState(.working))
    }

    func testTurnCompletedAppliesIdle() {
        XCTAssertEqual(AgentEventNormalizer.classify(eventType: "turn.completed"), .applyState(.idle))
    }

    func testTurnAbortedAppliesIdle() {
        XCTAssertEqual(AgentEventNormalizer.classify(eventType: "turn.aborted"), .applyState(.idle))
    }

    func testSessionExitedClearsState() {
        XCTAssertEqual(AgentEventNormalizer.classify(eventType: "session.exited"), .clearState)
    }

    func testUnrecognizedEventTypeReturnsNil() {
        XCTAssertNil(AgentEventNormalizer.classify(eventType: "bogus.event"))
        XCTAssertNil(AgentEventNormalizer.classify(eventType: ""))
    }

    func testClassifyIsCaseAndWhitespaceInsensitive() {
        // Matches the real function's `.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()`
        // normalization, so hook adapters that pass through provider-native casing still classify.
        XCTAssertEqual(AgentEventNormalizer.classify(eventType: "  Session.Started  "), .applyState(.idle))
        XCTAssertEqual(AgentEventNormalizer.classify(eventType: "REQUEST.OPENED"), .applyState(.blocked))
    }
}
