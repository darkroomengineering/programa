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

    func testManifestLookupByProcessName() {
        let manifest = AgentManifestLoader.shared.manifest(forProcessName: "claude")
        XCTAssertEqual(manifest?.agent, "claude-code")
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
}
