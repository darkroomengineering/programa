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

/// The Claude transcript title reader the Claude hooks use to name a pane (compiled into the
/// app and the CLI; the CLI has no test target of its own).
final class ClaudeTranscriptTitleTests: XCTestCase {
    private func transcript(_ lines: [String]) -> Data {
        Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    private func ai(_ title: String) -> String {
        #"{"type":"ai-title","aiTitle":"\#(title)","sessionId":"s1"}"#
    }

    private func custom(_ title: String) -> String {
        #"{"type":"custom-title","customTitle":"\#(title)","sessionId":"s1"}"#
    }

    /// Carries the `ai-title` marker text without being a title line.
    private let noise = #"{"type":"user","tool":{"type":"ai-title"}}"#

    func testCustomTitleBeatsAITitleEvenWhenTheAITitleIsNewer() {
        let data = transcript([noise, custom("Reviewing proposal"), ai("Drive capital proposal"), noise])
        XCTAssertEqual(ClaudeTranscriptTitle.latestTitle(in: data), "Reviewing proposal")
    }

    func testLatestTitleOfEachKindWins() {
        XCTAssertEqual(
            ClaudeTranscriptTitle.latestTitle(in: transcript([ai("First"), noise, ai("Second")])),
            "Second"
        )
        XCTAssertEqual(
            ClaudeTranscriptTitle.latestTitle(in: transcript([custom("Old name"), ai("Topic"), custom("New name")])),
            "New name"
        )
    }

    func testNoTitleLinesAndGarbageReturnNil() {
        XCTAssertNil(ClaudeTranscriptTitle.latestTitle(in: Data()))
        XCTAssertNil(ClaudeTranscriptTitle.latestTitle(in: transcript([noise, "not json at all", "{"])))
        XCTAssertNil(ClaudeTranscriptTitle.latestTitle(in: transcript([#"{"type":"ai-title","aiTitle":"   "}"#])))
        XCTAssertNil(ClaudeTranscriptTitle.latestTitle(in: transcript([#"{"type":"ai-title","aiTitle":42}"#])))
    }

    func testMalformedNewestTitleLineFallsBackToAnOlderOne() {
        let data = transcript([ai("Good topic"), #"{"type":"ai-title","aiTitle":"cut off"#])
        XCTAssertEqual(ClaudeTranscriptTitle.latestTitle(in: data), "Good topic")
    }

    func testTitlesAreTrimmedAndKeepEscapedCharacters() {
        let data = transcript([#"{"type":"custom-title","customTitle":"  Fix \"quotes\" and café  "}"#])
        XCTAssertEqual(ClaudeTranscriptTitle.latestTitle(in: data), #"Fix "quotes" and café"#)
    }

    func testMissingFileReturnsNil() {
        let path = NSTemporaryDirectory() + "claude-transcript-\(UUID().uuidString).jsonl"
        XCTAssertNil(ClaudeTranscriptTitle.latestTitle(atPath: path))
    }

    func testTailReadSeesRecentTitlesOnlyAndWholeFileReadSeesAll() throws {
        let path = NSTemporaryDirectory() + "claude-transcript-\(UUID().uuidString).jsonl"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let filler = #"{"type":"assistant","message":"\#(String(repeating: "x", count: 200))"}"#
        var lines = [custom("Too old to see")]
        lines += Array(repeating: filler, count: 200)
        lines += [ai("Recent topic")]
        lines += Array(repeating: filler, count: 5)
        try transcript(lines).write(to: URL(fileURLWithPath: path))

        XCTAssertEqual(ClaudeTranscriptTitle.latestTitle(atPath: path, tailBytes: 4 * 1024), "Recent topic")
        XCTAssertEqual(ClaudeTranscriptTitle.latestTitle(atPath: path), "Too old to see")
    }
}
