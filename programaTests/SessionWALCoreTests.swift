import XCTest

#if canImport(Programa_DEV)
@testable import Programa_DEV
#elseif canImport(Programa)
@testable import Programa
#endif

final class SessionWALCoreTests: XCTestCase {
    private var temporaryRoot: URL!
    private var policyPaths: SessionScrollbackPolicyPaths!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("programa-session-wal-core-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        policyPaths = SessionScrollbackPolicyPaths(snapshotFileURL: temporaryRoot.appendingPathComponent("snapshot.json"))
        _ = try SessionScrollbackPolicyStore.transition(enabled: true, at: policyPaths)
    }

    override func tearDownWithError() throws {
        if let temporaryRoot {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
        temporaryRoot = nil
    }

    func testDoubleBufferAppendDrainAndOverflowPreserveNewestBytes() {
        let ring = SessionWALRingBuffer(capacity: 8)

        append(Array("abc".utf8), to: ring)
        XCTAssertEqual(ring.drain(), Array("abc".utf8))
        XCTAssertNil(ring.drain())

        append(Array("0123456789".utf8), to: ring)
        XCTAssertEqual(ring.drain(), Array("23456789".utf8))
    }

    func testAppendRotatesAndPersistsGenerationBeforeFrameCapture() throws {
        let paths = makePaths()
        try seedMeta(at: paths)

        let initial = try SessionWALCore.append(
            Data("abcd".utf8),
            to: paths,
            walCapBytes: 6,
            synchronize: true
        )
        XCTAssertFalse(initial.didRotate)
        XCTAssertEqual(initial.currentWalSize, 4)
        XCTAssertEqual(initial.walGeneration, 0)

        let rotated = try SessionWALCore.append(
            Data("efg".utf8),
            to: paths,
            walCapBytes: 6,
            synchronize: true
        )
        XCTAssertTrue(rotated.didRotate)
        XCTAssertEqual(rotated.currentWalSize, 3)
        XCTAssertEqual(rotated.walGeneration, 1)
        XCTAssertEqual(try Data(contentsOf: paths.walRotatedURL), Data("abcd".utf8))
        XCTAssertEqual(try Data(contentsOf: paths.walURL), Data("efg".utf8))
        XCTAssertEqual(SessionWALCore.readMeta(at: paths)?.walGeneration, 1)

        try writeFrame("FRAME", offset: rotated.currentWalSize, generation: 1, at: paths)
        _ = try SessionWALCore.append(
            Data("hi".utf8),
            to: paths,
            walCapBytes: 6,
            synchronize: true
        )
        XCTAssertEqual(
            SessionWALCore.readFrameAndDelta(at: paths, walCapBytes: 6),
            "FRAMEhi",
            "A frame captured after rotation must replay from the new WAL generation and offset"
        )
    }

    func testRotationAfterFrameInvalidatesOffsetEvenWhenNewWALRegrowsPastIt() throws {
        let paths = makePaths()
        try seedMeta(at: paths)

        let beforeFrame = try SessionWALCore.append(
            Data("old".utf8),
            to: paths,
            walCapBytes: 6,
            synchronize: true
        )
        try writeFrame(
            "OLD-FRAME",
            offset: beforeFrame.currentWalSize,
            generation: beforeFrame.walGeneration,
            at: paths
        )

        let afterFrame = try SessionWALCore.append(
            Data("new!".utf8),
            to: paths,
            walCapBytes: 6,
            synchronize: true
        )
        XCTAssertTrue(afterFrame.didRotate)
        XCTAssertEqual(afterFrame.walGeneration, 1)
        XCTAssertGreaterThanOrEqual(
            afterFrame.currentWalSize,
            beforeFrame.currentWalSize,
            "The replacement WAL deliberately regrows beyond the stale frame offset"
        )
        XCTAssertNil(
            SessionWALCore.readFrameAndDelta(at: paths, walCapBytes: 6),
            "Generation mismatch must reject a numerically valid offset from the wrong WAL"
        )
    }

    func testOffsetAndDeltaReplayUsesOnlyBytesWrittenAfterFrame() throws {
        let paths = makePaths()
        try seedMeta(at: paths)

        let beforeFrame = try SessionWALCore.append(
            Data("prompt> ".utf8),
            to: paths,
            walCapBytes: 64,
            synchronize: true
        )
        try writeFrame(
            "VISIBLE-SCREEN",
            offset: beforeFrame.currentWalSize,
            generation: beforeFrame.walGeneration,
            at: paths
        )
        _ = try SessionWALCore.append(
            Data("command output".utf8),
            to: paths,
            walCapBytes: 64,
            synchronize: true
        )

        XCTAssertEqual(
            SessionWALCore.readFrameAndDelta(at: paths, walCapBytes: 64),
            "VISIBLE-SCREENcommand output"
        )
    }

    /// Reproduces the corrupted-restore symptom (transcript fragments at wrong
    /// columns, mid-word garbage like "m0de"): the WAL delta returned by
    /// `readFrameAndDelta` is a raw byte slice, so a `walOffset` that lands
    /// mid-escape-sequence or mid-UTF-8-scalar leaks the orphaned tail bytes
    /// into the replayed text instead of being trimmed.
    func testFrameAndDeltaTrimsLeadingPartialEscapeAndUTF8() throws {
        // Scenario 1: walOffset lands inside a CSI parameter run. The full WAL
        // is a single (otherwise complete) SGR color-set sequence followed by
        // plain content; offset 3 sits right after "ESC[3", so the delta's
        // first bytes are the orphaned tail "8;5;196m" of that sequence.
        let csiPaths = makePaths()
        try seedMeta(at: csiPaths)
        let walText = "\u{001B}[38;5;196mVISIBLE"
        try Data(walText.utf8).write(to: csiPaths.walURL)
        try writeFrame("HELLO", offset: 3, generation: 0, at: csiPaths)

        let csiReplayed = SessionWALCore.readFrameAndDelta(at: csiPaths, walCapBytes: 4096)
        XCTAssertEqual(
            csiReplayed,
            "HELLOVISIBLE",
            "A delta beginning mid-CSI-sequence must drop the orphaned parameter/final bytes, not leak them as literal text"
        )
        XCTAssertFalse(
            (csiReplayed ?? "").contains("8;5;196m"),
            "The orphaned CSI parameter tail must never appear as literal replayed text"
        )

        // Scenario 2: walOffset lands inside a multi-byte UTF-8 scalar. "é" is
        // encoded as the two bytes 0xC3 0xA9; offset 2 sits between them, so
        // the delta's first byte is a lone UTF-8 continuation byte.
        let utf8Paths = makePaths()
        try seedMeta(at: utf8Paths)
        let utf8WalText = "x\u{00E9}post"
        try Data(utf8WalText.utf8).write(to: utf8Paths.walURL)
        try writeFrame("PRE", offset: 2, generation: 0, at: utf8Paths)

        let utf8Replayed = SessionWALCore.readFrameAndDelta(at: utf8Paths, walCapBytes: 4096)
        XCTAssertEqual(
            utf8Replayed,
            "PREpost",
            "A delta beginning mid-UTF-8-scalar must drop the orphaned continuation byte, not decode it as U+FFFD"
        )
        XCTAssertFalse(
            (utf8Replayed ?? "").contains("\u{FFFD}"),
            "No replacement character should appear at a UTF-8 seam that was safely trimmed"
        )

        // Scenario 3: the delta legitimately begins with a long digit run
        // that is syntactically indistinguishable from a torn CSI parameter
        // list until a 0x40-0x7E byte ('M' of "Main") turns up -- but that
        // byte lands past the bounded scan window (csiTailScanCapBytes = 16;
        // "12345678901234567;89 " is 21 bytes), so the trim must not fire
        // and the full delta must survive untouched.
        let longDigitPaths = makePaths()
        try seedMeta(at: longDigitPaths)
        let longDigitText = "12345678901234567;89 Main"
        try Data(longDigitText.utf8).write(to: longDigitPaths.walURL)
        try writeFrame("F", offset: 0, generation: 0, at: longDigitPaths)

        let longDigitReplayed = SessionWALCore.readFrameAndDelta(at: longDigitPaths, walCapBytes: 4096)
        XCTAssertEqual(
            longDigitReplayed,
            "F" + longDigitText,
            "A delta whose leading run exceeds the bounded CSI-tail scan window must survive untrimmed, even though it is syntactically ambiguous with a torn escape"
        )

        // Scenario 4: the two trim causes must be mutually exclusive. The
        // cut lands inside a multi-byte UTF-8 character ("é"), and what
        // follows ("123Main") looks exactly like a torn CSI parameter run on
        // its own (digits ending in 'M', a plausible final byte) -- but
        // since the UTF-8 continuation-byte skip already consumed a byte,
        // the CSI scan must not run at all. If it ran anyway it would
        // additionally eat "123M" (finding 'M' as a bogus CSI final byte),
        // leaving only "ain".
        let mixedPaths = makePaths()
        try seedMeta(at: mixedPaths)
        let mixedWalText = "x\u{00E9}123Main"
        try Data(mixedWalText.utf8).write(to: mixedPaths.walURL)
        try writeFrame("F", offset: 2, generation: 0, at: mixedPaths)

        let mixedReplayed = SessionWALCore.readFrameAndDelta(at: mixedPaths, walCapBytes: 4096)
        XCTAssertEqual(
            mixedReplayed,
            "F123Main",
            "A cut inside a UTF-8 character must only trim the continuation byte -- the CSI-tail scan must not also run and eat legitimate text that follows"
        )
    }

    /// Reproduces the fallback-path variant of the corrupted-restore symptom:
    /// `readFallbackScrollbackText`'s plain-tail fallback (no usable frame --
    /// e.g. a session younger than the periodic frame-capture interval, or a
    /// walGeneration mismatch after rotation) concatenates the rotated +
    /// current WAL files and caps the result with a raw `.suffix(walCapBytes)`
    /// cut, exactly like `readFrameAndDelta`'s offset/cap cuts -- but unlike
    /// that path, it did not trim the result, so a cap-cut landing mid-escape
    /// or mid-UTF-8 leaked literal garbage into the replayed scrollback.
    func testFallbackScrollbackTextTrimsLeadingPartialEscapeAndUTF8() {
        // The cap lands inside a CSI parameter run: capping to the last 8
        // bytes of "\u{1B}[38;5;196mVISIBLE" leaves "196mVISIBLE" as the raw
        // suffix... construct the combined bytes directly so the cut point is
        // exact and lands mid-sequence.
        let csiCombined = Data("\u{001B}[38;5;196mVISIBLE".utf8)
        let csiReplayed = SessionWALCore.decodeFallbackScrollbackText(
            rotated: nil,
            current: csiCombined,
            walCapBytes: Int64(csiCombined.count - 3)
        )
        XCTAssertEqual(
            csiReplayed,
            "VISIBLE",
            "A cap cut landing mid-CSI-sequence must drop the orphaned parameter/final bytes, not leak them as literal text"
        )
        XCTAssertFalse(
            (csiReplayed ?? "").contains(";196m"),
            "The orphaned CSI parameter tail must never appear as literal replayed text"
        )

        // The cap lands inside a multi-byte UTF-8 scalar: "é" is 0xC3 0xA9;
        // capping to the last 5 bytes of "x\u{00E9}post" leaves a lone
        // continuation byte at the front.
        let utf8Combined = Data("x\u{00E9}post".utf8)
        let utf8Replayed = SessionWALCore.decodeFallbackScrollbackText(
            rotated: nil,
            current: utf8Combined,
            walCapBytes: Int64(utf8Combined.count - 2)
        )
        XCTAssertEqual(
            utf8Replayed,
            "post",
            "A cap cut landing mid-UTF-8-scalar must drop the orphaned continuation byte, not decode it as U+FFFD"
        )
        XCTAssertFalse(
            (utf8Replayed ?? "").contains("\u{FFFD}"),
            "No replacement character should appear at a UTF-8 seam that was safely trimmed"
        )

        // Rotated + current concatenation still combines and caps correctly
        // when no trim is needed at all.
        let untrimmedReplayed = SessionWALCore.decodeFallbackScrollbackText(
            rotated: Data("rotated-".utf8),
            current: Data("current".utf8),
            walCapBytes: 4096
        )
        XCTAssertEqual(untrimmedReplayed, "rotated-current")

        // Uncut data must never be trimmed, even when its genuine leading
        // bytes are indistinguishable from a torn CSI tail: "196mVISIBLE"
        // under a cap larger than the data starts at a real stream beginning
        // and must survive intact.
        let tornLookalike = SessionWALCore.decodeFallbackScrollbackText(
            rotated: nil,
            current: Data("196mVISIBLE".utf8),
            walCapBytes: 4096
        )
        XCTAssertEqual(
            tornLookalike,
            "196mVISIBLE",
            "The torn-CSI heuristic must only run when a suffix cut actually occurred"
        )

        // No bytes at all (never-written session) yields nil, not "".
        XCTAssertNil(SessionWALCore.decodeFallbackScrollbackText(rotated: nil, current: nil, walCapBytes: 4096))
    }

    private func makePaths() -> SessionWALPaths {
        SessionWALPaths(
            sessionDirectory: temporaryRoot.appendingPathComponent(UUID().uuidString, isDirectory: true),
            policyPaths: policyPaths
        )
    }

    func testDisabledPolicySuppressesContentButPreservesSessionMetadata() throws {
        let paths = makePaths()
        let policy = try SessionScrollbackPolicyStore.transition(enabled: false, at: policyPaths)
        try seedMeta(at: paths, generation: 7)
        try attemptContentWrite(at: paths, generation: policy.generation)
        XCTAssertEqual(SessionWALCore.readMeta(at: paths)?.walGeneration, 7)
        assertNoContent(at: paths)
    }

    func testReenabledPolicyRejectsContentCapturedBeforeDisable() throws {
        let paths = makePaths()
        let previous = try SessionScrollbackPolicyStore.read(at: policyPaths)
        _ = try SessionScrollbackPolicyStore.transition(enabled: false, at: policyPaths)
        let current = try SessionScrollbackPolicyStore.transition(enabled: true, at: policyPaths)
        XCTAssertNotEqual(previous.generation, current.generation)
        try seedMeta(at: paths)
        try attemptContentWrite(at: paths, generation: previous.generation)
        assertNoContent(at: paths)

        try attemptContentWrite(at: paths, generation: current.generation)
        XCTAssertEqual(try Data(contentsOf: paths.walURL), Data("PRIVATE-WAL".utf8))
        XCTAssertEqual(try String(contentsOf: paths.frameURL, encoding: .utf8), "PRIVATE-FRAME")
    }

    private func attemptContentWrite(at paths: SessionWALPaths, generation: UUID) throws {
        _ = try SessionWALCore.append(Data("PRIVATE-WAL".utf8), to: paths,
                                      synchronize: true, capturedGeneration: generation)
        try SessionWALCore.writeFrame("PRIVATE-FRAME", meta: SessionFrameMeta(
            sessionId: paths.sessionDirectory.lastPathComponent, capturedAt: Date(),
            walOffset: 0, walGeneration: 0
        ), to: paths, capturedGeneration: generation)
    }

    private func assertNoContent(at paths: SessionWALPaths, file: StaticString = #filePath, line: UInt = #line) {
        for url in [paths.walURL, paths.walRotatedURL, paths.frameURL, paths.frameNextURL, paths.frameMetaURL] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                           "Disabled or stale content must never reach \(url.lastPathComponent)", file: file, line: line)
        }
    }

    private func seedMeta(at paths: SessionWALPaths, generation: Int = 0) throws {
        let meta = SessionWALMeta(
            sessionId: paths.sessionDirectory.lastPathComponent,
            childPID: nil,
            ptyPath: nil,
            workingDirectory: "/tmp",
            lastHeartbeatAt: Date(timeIntervalSince1970: 1_700_000_000),
            walGeneration: generation,
            escrowed: nil,
            escrowSocketPath: nil,
            escrowToken: nil
        )
        try SessionWALCore.persistMeta(meta, to: paths)
    }

    private func writeFrame(
        _ text: String,
        offset: Int64,
        generation: Int,
        at paths: SessionWALPaths
    ) throws {
        try SessionWALCore.writeFrame(
            text,
            meta: SessionFrameMeta(
                sessionId: paths.sessionDirectory.lastPathComponent,
                capturedAt: Date(timeIntervalSince1970: 1_700_000_001),
                walOffset: offset,
                walGeneration: generation
            ),
            to: paths
        )
    }

    private func append(_ bytes: [UInt8], to ring: SessionWALRingBuffer) {
        bytes.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            ring.append(baseAddress, buffer.count)
        }
    }
}

// Deferred-revive escrow stamp (2026-08-20 update-reset fix): a revived panel in
// a hidden tab escrows its fd at construction, before the WAL writer's full
// registration. The stamp must create the session's meta.json on its own and
// record every field the next launch's reattach guard requires
// (escrowed/socketPath/token/childPID) — a missing one degrades to
// "not_escrowed" and the agent dies at the next update.
final class SessionWALDeferredReviveEscrowTests: XCTestCase {
    func testStampWritesRetrievableEscrowMetaWithoutFullRegistration() {
        let store = SessionWALStore.shared
        let sessionId = UUID().uuidString
        defer { store.unregister(surface: nil, surfaceId: sessionId, deleteDirectory: true) }

        store.stampDeferredReviveEscrow(
            surfaceId: sessionId,
            socketPath: "/tmp/test-escrow.sock",
            token: "deadbeefcafe",
            childPID: 4242,
            workingDirectory: "/tmp"
        )

        // Writes land asynchronously on the store's write queue; poll briefly.
        let deadline = Date().addingTimeInterval(3)
        var meta: SessionWALMeta?
        while Date() < deadline {
            meta = store.readMeta(sessionId: sessionId)
            if meta?.escrowed == true { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        XCTAssertEqual(meta?.escrowed, true, "stamp must persist escrowed=true without a prior register()")
        XCTAssertEqual(meta?.escrowSocketPath, "/tmp/test-escrow.sock")
        XCTAssertEqual(meta?.escrowToken, "deadbeefcafe")
        XCTAssertEqual(meta?.childPID, 4242, "reattach's guard requires childPID; the stamp must record it")
    }
}

// Issue #307 orphan-reconciliation fix: `escrowedSessionIds(excluding:)` is the
// enumeration primitive `AppDelegate.reconcileOrphanedEscrowedSessions` uses to
// find escrow-claimed session directories the coarse-snapshot restore never
// looked up. Follows `SessionWALDeferredReviveEscrowTests`'s own harness pattern
// above: real app-support sessions root, random UUID fixture ids (so runs never
// collide with each other or with any real session directory), explicit
// synchronous cleanup rather than the async `unregister` (which is a no-op here
// since these fixtures never go through `register`/`startWriter`).
final class SessionWALEscrowedSessionIdsTests: XCTestCase {
    private var fixtureSessionIds: [String] = []

    override func tearDownWithError() throws {
        for sessionId in fixtureSessionIds {
            if let paths = SessionWALPaths.make(sessionId: sessionId) {
                try? FileManager.default.removeItem(at: paths.sessionDirectory)
            }
        }
        fixtureSessionIds = []
    }

    func testEscrowedSessionIdsReturnsOnlyTrueEscrowedNonExcludedFixtures() throws {
        let escrowedId = UUID().uuidString
        let notEscrowedId = UUID().uuidString
        let missingEscrowedId = UUID().uuidString
        let excludedEscrowedId = UUID().uuidString
        fixtureSessionIds = [escrowedId, notEscrowedId, missingEscrowedId, excludedEscrowedId]

        try seedEscrowMeta(sessionId: escrowedId, escrowed: true)
        try seedEscrowMeta(sessionId: notEscrowedId, escrowed: false)
        try seedEscrowMeta(sessionId: missingEscrowedId, escrowed: nil)
        try seedEscrowMeta(sessionId: excludedEscrowedId, escrowed: true)

        let result = SessionWALStore.shared.escrowedSessionIds(excluding: [excludedEscrowedId])
        let resultById = Dictionary(uniqueKeysWithValues: result.map { ($0.sessionId, $0.meta) })

        XCTAssertTrue(resultById.keys.contains(escrowedId), "a true-escrowed, non-excluded session must be returned")
        XCTAssertEqual(resultById[escrowedId]?.escrowed, true)
        XCTAssertFalse(resultById.keys.contains(notEscrowedId), "escrowed=false must be filtered out")
        XCTAssertFalse(resultById.keys.contains(missingEscrowedId), "escrowed=nil (missing) must be filtered out")
        XCTAssertFalse(resultById.keys.contains(excludedEscrowedId), "an excluded id must be filtered out even though it's escrowed=true")
    }

    private func seedEscrowMeta(sessionId: String, escrowed: Bool?) throws {
        guard let paths = SessionWALPaths.make(sessionId: sessionId) else {
            XCTFail("could not build SessionWALPaths for fixture session")
            return
        }
        let meta = SessionWALMeta(
            sessionId: sessionId,
            childPID: escrowed == true ? 4242 : nil,
            ptyPath: nil,
            workingDirectory: "/tmp",
            lastHeartbeatAt: Date(),
            walGeneration: 0,
            escrowed: escrowed,
            escrowSocketPath: escrowed == true ? "/tmp/test-escrow-\(sessionId).sock" : nil,
            escrowToken: escrowed == true ? "deadbeefcafe" : nil
        )
        _ = try SessionWALCore.persistMeta(meta, to: paths)
    }
}
