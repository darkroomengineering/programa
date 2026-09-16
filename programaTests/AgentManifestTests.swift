// Screen-manifest agent detection (docs/plans/screen-manifest-detection.md), Phase 1: pure unit
// tests for AgentManifest decoding + classification. No app launch, no socket, no engine/thread
// dependency -- classify(text:) is a pure function by design specifically so this is possible.
import XCTest

#if canImport(Programa_DEV)
@testable import Programa_DEV
#elseif canImport(Programa)
@testable import Programa
#endif

final class AgentManifestTests: XCTestCase {
    override func setUp() {
        super.setUp()
        AgentManifestLoader.shared.resetForTesting()
    }

    // MARK: - Loader

    func testAllBundledManifestsDecodeSuccessfully() {
        let manifests = AgentManifestLoader.shared.allManifests()
        let loadedAgentIds = Set(manifests.map { $0.agent })
        for expectedAgentId in AgentManifestLoader.bundledAgentIds {
            XCTAssertTrue(
                loadedAgentIds.contains(expectedAgentId),
                "expected bundled manifest for \(expectedAgentId) to decode and load"
            )
        }
    }

    func testManifestLookupByAgentId() {
        let manifest = AgentManifestLoader.shared.manifest(forAgent: "claude-code")
        XCTAssertEqual(manifest?.displayName, "Claude Code")
    }

    func testManifestPreservesProcessNames() throws {
        let manifest = try XCTUnwrap(AgentManifestLoader.shared.manifest(forAgent: "claude-code"))
        XCTAssertEqual(manifest.agent, "claude-code")
        XCTAssertTrue(manifest.recognize.processNames.contains("claude"))
    }

    func testAllManifestEntriesReportBundledSourceByDefault() throws {
        // No user override is present in the test environment, so every bundled agent id must
        // report source .bundled -- this is the property `agent.detection.list`'s
        // `shadows_bundled` flag (and `agent-detection scaffold`'s bundled-id guard) depend on.
        let entries = AgentManifestLoader.shared.allManifestEntries()
        let claudeEntry = try XCTUnwrap(entries.first { $0.manifest.agent == "claude-code" })
        XCTAssertEqual(claudeEntry.source, .bundled)

        let entryAgentIds = Set(entries.map(\.manifest.agent))
        for expectedAgentId in AgentManifestLoader.bundledAgentIds {
            XCTAssertTrue(entryAgentIds.contains(expectedAgentId))
        }
    }

    // MARK: - Claude Code classification (worked example from the plan)

    func testClaudeCodeClassifiesBlockedPermissionPrompt() throws {
        let manifest = try XCTUnwrap(AgentManifestLoader.shared.manifest(forAgent: "claude-code"))
        let text = "Some tool output\nDo you want to proceed?\n❯ 1. Yes\n  2. No"
        let result = manifest.classify(text: text)
        XCTAssertEqual(result?.bucket, "blocked")
    }

    func testClaudeCodeClassifiesWorkingSpinner() throws {
        let manifest = try XCTUnwrap(AgentManifestLoader.shared.manifest(forAgent: "claude-code"))
        let text = "✻ Thinking…\n(esc to interrupt)"
        let result = manifest.classify(text: text)
        XCTAssertEqual(result?.bucket, "working")
    }

    func testClaudeCodeClassifiesIdlePrompt() throws {
        let manifest = try XCTUnwrap(AgentManifestLoader.shared.manifest(forAgent: "claude-code"))
        let text = "Some previous output\n❯ "
        let result = manifest.classify(text: text)
        XCTAssertEqual(result?.bucket, "idle")
    }

    func testClaudeCodeReturnsNilForUnrelatedText() throws {
        let manifest = try XCTUnwrap(AgentManifestLoader.shared.manifest(forAgent: "claude-code"))
        let text = "$ ls -la\ntotal 0\ndrwxr-xr-x  2 user  staff  64 Jan  1 00:00 .\n"
        XCTAssertNil(manifest.classify(text: text))
    }

    func testClaudeCodeBlockedTakesPriorityOverWorking() throws {
        // Both a blocked pattern and a working pattern present in the same sample -- priority
        // ordering (blocked=100 > working=50) must resolve to blocked, not working.
        let manifest = try XCTUnwrap(AgentManifestLoader.shared.manifest(forAgent: "claude-code"))
        let text = "✻ Thinking…\nDo you want to proceed?\n❯ 1. Yes"
        let result = manifest.classify(text: text)
        XCTAssertEqual(result?.bucket, "blocked")
    }

    // MARK: - AgentActivityState(manifestBucket:) mapping

    func testManifestBucketMapping() {
        XCTAssertEqual(AgentActivityState(manifestBucket: "working"), .working)
        XCTAssertEqual(AgentActivityState(manifestBucket: "blocked"), .blocked)
        XCTAssertEqual(AgentActivityState(manifestBucket: "idle"), .idle)
        XCTAssertEqual(AgentActivityState(manifestBucket: "done"), .idle)
        XCTAssertNil(AgentActivityState(manifestBucket: "not-a-real-bucket"))
    }

    // MARK: - Other solid-tier manifests

    func testCodexClassifiesBlockedAllowCommandPrompt() throws {
        let manifest = try XCTUnwrap(AgentManifestLoader.shared.manifest(forAgent: "codex"))
        let text = "Allow command?\n(y/n)"
        XCTAssertEqual(manifest.classify(text: text)?.bucket, "blocked")
    }

    func testGeminiCliClassifiesWorkingSpinner() throws {
        let manifest = try XCTUnwrap(AgentManifestLoader.shared.manifest(forAgent: "gemini-cli"))
        let text = "⠙ generating (esc to cancel)"
        XCTAssertEqual(manifest.classify(text: text)?.bucket, "working")
    }

    // MARK: - `programa agent-detection scaffold` output shape
    //
    // The CLI target can't import `AgentManifest` (separate target), so its scaffold generator
    // (CLI/programa.swift's `agentDetectionScaffoldJSON`) hand-assembles JSON matching this
    // schema rather than encoding a shared type. This test decodes a JSON string shaped exactly
    // like that generator's output through the real `AgentManifest` Codable type, so a schema
    // drift between the two would fail here instead of only surfacing as a runtime loader
    // failure for a user's freshly scaffolded file.

    private static let scaffoldShapedJSON = """
    {
      "version": 1,
      "agent": "my-test-agent",
      "display_name": "My Test Agent",
      "recognize": {
        "process_names": ["my-test-agent"],
        "screen_patterns": []
      },
      "states": [
        {
          "bucket": "blocked",
          "priority": 100,
          "anchor_last_n_lines": 12,
          "patterns": [],
          "confidence": "low",
          "source_notes": "TODO: fill in a blocked pattern.\\nCaptured screen for reference:\\nsome \\"quoted\\" text\\nand a second line"
        },
        {
          "bucket": "working",
          "priority": 50,
          "anchor_last_n_lines": 6,
          "patterns": [],
          "confidence": "low",
          "source_notes": "TODO: fill in a working pattern."
        },
        {
          "bucket": "idle",
          "priority": 0,
          "anchor_last_n_lines": 4,
          "patterns": [],
          "confidence": "low",
          "source_notes": "TODO: fill in an idle pattern."
        }
      ]
    }
    """

    func testScaffoldShapedManifestDecodesCleanly() throws {
        let data = try XCTUnwrap(Self.scaffoldShapedJSON.data(using: .utf8))
        let manifest = try JSONDecoder().decode(AgentManifest.self, from: data)

        XCTAssertEqual(manifest.version, 1)
        XCTAssertEqual(manifest.agent, "my-test-agent")
        XCTAssertEqual(manifest.displayName, "My Test Agent")
        XCTAssertEqual(manifest.recognize.processNames, ["my-test-agent"])
        XCTAssertEqual(manifest.recognize.screenPatterns, [])
        XCTAssertEqual(manifest.states.map(\.bucket), ["blocked", "working", "idle"])
        XCTAssertEqual(manifest.states.map(\.priority), [100, 50, 0])
        XCTAssertTrue(manifest.states.allSatisfy { $0.patterns.isEmpty })
        XCTAssertTrue(manifest.states.allSatisfy { $0.confidence == "low" })
    }

    func testScaffoldShapedManifestWithEmptyPatternsNeverMatches() throws {
        // Confirms the safety property the scaffold generator relies on: a state with an empty
        // `patterns` array can never match, so a freshly scaffolded (unfilled) manifest is inert
        // rather than a false-positive machine. See `AgentManifest.classify(text:)`'s inner
        // `for pattern in stateRule.patterns` loop, which simply never executes when empty.
        let data = try XCTUnwrap(Self.scaffoldShapedJSON.data(using: .utf8))
        let manifest = try JSONDecoder().decode(AgentManifest.self, from: data)

        let samples = [
            "Do you want to proceed?\n❯ 1. Yes\n  2. No",
            "✻ Thinking…\n(esc to interrupt)",
            "Some previous output\n$ ",
            ""
        ]
        for sample in samples where !sample.isEmpty {
            XCTAssertNil(manifest.classify(text: sample), "expected no bucket for empty-patterns manifest, sample: \(sample)")
        }
    }
}
