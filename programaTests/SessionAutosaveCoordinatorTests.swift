import XCTest

#if canImport(Programa_DEV)
@testable import Programa_DEV
#elseif canImport(Programa)
@testable import Programa
#endif

/// Drives `SessionAutosaveCoordinator` directly with fake injected dependencies to exercise the
/// stateful orchestration (timer/debounce/deferred-retry behaviour) that GitHub issue #187's
/// extraction out of `AppDelegate` makes testable for the first time. See
/// `SessionPersistenceTests` for the pure static helpers this coordinator also exposes.
final class SessionAutosaveCoordinatorTests: XCTestCase {
    private static let fakeSnapshot = AppSessionSnapshot(
        version: SessionSnapshotSchema.currentVersion,
        createdAt: 0,
        windows: [],
        cleanShutdown: false
    )

    @MainActor
    func testPendingWritePreventsDuplicateAutosavesUntilCompletion() throws {
        var completions: [SessionAutosaveCoordinator.SaveCompletion] = []
        let coordinator = SessionAutosaveCoordinator(
            sessionPersistenceQueue: DispatchQueue(label: "test.session-autosave.pending"),
            snapshotProvider: { _ in Self.fakeSnapshot },
            saveSnapshot: { _, _, completion in completions.append(completion) },
            isTerminating: { false },
            isRunningUnderXCTest: { true }
        )
        defer { coordinator.stopSessionAutosaveTimer() }

        coordinator.runSessionAutosaveTick(source: "first")
        coordinator.runSessionAutosaveTick(source: "while-pending")
        XCTAssertEqual(completions.count, 1, "An unfinished disk write must remain the only active save")
        let completion = try XCTUnwrap(completions.first)
        completion(true)
        coordinator.runSessionAutosaveTick(source: "after-success")
        XCTAssertEqual(completions.count, 1, "Only a successful completion may suppress an unchanged snapshot")
    }

    @MainActor
    func testPromptSaveDuringPendingWritePersistsNewContentAfterCompletionWithoutAnotherTick() throws {
        var snapshot = Self.fakeSnapshot
        var savedSnapshots: [AppSessionSnapshot] = []
        var pendingCompletion: SessionAutosaveCoordinator.SaveCompletion?
        let latestSaved = expectation(description: "prompted content is saved after the pending write")
        let coordinator = SessionAutosaveCoordinator(
            sessionPersistenceQueue: DispatchQueue(label: "test.session-autosave.pending-prompt"),
            snapshotProvider: { _ in snapshot },
            saveSnapshot: { _, candidate, completion in
                guard let candidate else { return XCTFail("Expected a snapshot") }
                savedSnapshots.append(candidate)
                if savedSnapshots.count == 1 {
                    pendingCompletion = completion
                } else {
                    completion(true)
                    latestSaved.fulfill()
                }
            },
            isTerminating: { false },
            isRunningUnderXCTest: { true }
        )
        defer { coordinator.stopSessionAutosaveTimer() }

        coordinator.runSessionAutosaveTick(source: "first")
        snapshot.cleanShutdown = true
        coordinator.requestPromptSave(source: "content-changed", after: 0)
        let promptDispatched = expectation(description: "main queue processed the prompt while the write is pending")
        DispatchQueue.main.async { promptDispatched.fulfill() }
        wait(for: [promptDispatched], timeout: 2)
        XCTAssertEqual(savedSnapshots.count, 1, "The pending write must finish before the prompted save begins")

        let completion = try XCTUnwrap(pendingCompletion)
        completion(true)
        wait(for: [latestSaved], timeout: 2)
        XCTAssertEqual(savedSnapshots.count, 2, "The prompt must survive an in-flight write without needing another timer tick")
        XCTAssertEqual(savedSnapshots.last?.cleanShutdown, true, "The follow-up save must capture the newer content")
    }

    @MainActor
    func testFailedCompletionAllowsUnchangedRetryAndSuccessSuppressesFurtherWrites() throws {
        var completions: [SessionAutosaveCoordinator.SaveCompletion] = []
        let coordinator = SessionAutosaveCoordinator(
            sessionPersistenceQueue: DispatchQueue(label: "test.session-autosave.failed-completion"),
            snapshotProvider: { _ in Self.fakeSnapshot },
            saveSnapshot: { _, _, completion in completions.append(completion) },
            isTerminating: { false },
            isRunningUnderXCTest: { true }
        )
        defer { coordinator.stopSessionAutosaveTimer() }

        coordinator.runSessionAutosaveTick(source: "first")
        let failed = try XCTUnwrap(completions.first)
        failed(false)
        coordinator.runSessionAutosaveTick(source: "retry-unchanged")
        XCTAssertEqual(completions.count, 2, "A failed disk write must not mark unchanged content as persisted")
        let retried = try XCTUnwrap(completions.dropFirst().first)
        retried(true)
        coordinator.runSessionAutosaveTick(source: "after-recovery")
        XCTAssertEqual(completions.count, 2, "Successfully retried content should regain normal write deduplication")
    }

    @MainActor
    func testStoppedLifecycleCompletionCannotReleaseNewWriteOrCacheOldSnapshot() throws {
        var snapshot = Self.fakeSnapshot
        var completions: [SessionAutosaveCoordinator.SaveCompletion] = []
        let coordinator = SessionAutosaveCoordinator(
            sessionPersistenceQueue: DispatchQueue(label: "test.session-autosave.stale-completion"),
            snapshotProvider: { _ in snapshot },
            saveSnapshot: { _, _, completion in completions.append(completion) },
            isTerminating: { false },
            isRunningUnderXCTest: { true }
        )
        defer { coordinator.stopSessionAutosaveTimer() }

        coordinator.runSessionAutosaveTick(source: "old-lifecycle")
        let oldCompletion = try XCTUnwrap(completions.first)
        coordinator.stopSessionAutosaveTimer()
        snapshot.cleanShutdown = true
        coordinator.runSessionAutosaveTick(source: "new-lifecycle")
        let newCompletion = try XCTUnwrap(completions.dropFirst().first)
        oldCompletion(true)
        coordinator.runSessionAutosaveTick(source: "new-still-pending")
        XCTAssertEqual(completions.count, 2, "A late completion must not release another write's in-flight protection")

        newCompletion(false)
        snapshot = Self.fakeSnapshot
        coordinator.runSessionAutosaveTick(source: "retry-old-content")
        XCTAssertEqual(completions.count, 3, "A completion invalidated by stop must not cache its old snapshot identity")
        let finalCompletion = try XCTUnwrap(completions.dropFirst(2).first)
        finalCompletion(true)
    }

    @MainActor
    func testAutosaveTickDefersDuringTypingQuietPeriodInsteadOfSaving() {
        var snapshotCallCount = 0
        var saveCallCount = 0
        let coordinator = SessionAutosaveCoordinator(
            sessionPersistenceQueue: DispatchQueue(label: "test.session-autosave.quiet-period"),
            snapshotProvider: { _ in
                snapshotCallCount += 1
                return Self.fakeSnapshot
            },
            saveSnapshot: { _, _, completion in
                saveCallCount += 1
                completion(true)
            },
            isTerminating: { false },
            isRunningUnderXCTest: { true }
        )

        coordinator.recordTypingActivity()
        coordinator.runSessionAutosaveTick(source: "test")

        XCTAssertEqual(
            snapshotCallCount,
            0,
            "a tick during the typing quiet period should defer before ever building a snapshot"
        )
        XCTAssertEqual(
            saveCallCount,
            0,
            "a tick during the typing quiet period should defer rather than save"
        )
    }

    @MainActor
    func testDeferredAutosaveRetryIsScheduledOnceNotRepeatedlyPerQuietPeriod() {
        var saveCallCount = 0
        let coordinator = SessionAutosaveCoordinator(
            sessionPersistenceQueue: DispatchQueue(label: "test.session-autosave.deferred-retry"),
            snapshotProvider: { _ in Self.fakeSnapshot },
            saveSnapshot: { _, _, completion in
                saveCallCount += 1
                completion(true)
            },
            isTerminating: { false },
            isRunningUnderXCTest: { true }
        )

        coordinator.recordTypingActivity()
        // Two ticks land back-to-back inside the same quiet period. Only one deferred retry
        // should ever be scheduled; the second call must not queue a duplicate.
        coordinator.runSessionAutosaveTick(source: "first")
        coordinator.runSessionAutosaveTick(source: "second")

        let retryFired = expectation(description: "deferred retry executes after the quiet period elapses")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            retryFired.fulfill()
        }
        wait(for: [retryFired], timeout: 3.0)

        XCTAssertEqual(
            saveCallCount,
            1,
            "the deferred retry should fire and save exactly once, not once per queued tick"
        )
    }

    @MainActor
    func testAutosaveTickSkipsWriteWhenFingerprintUnchanged() {
        var saveCallCount = 0
        let coordinator = SessionAutosaveCoordinator(
            sessionPersistenceQueue: DispatchQueue(label: "test.session-autosave.fingerprint"),
            snapshotProvider: { _ in Self.fakeSnapshot },
            saveSnapshot: { _, _, completion in
                saveCallCount += 1
                completion(true)
            },
            isTerminating: { false },
            isRunningUnderXCTest: { true }
        )

        coordinator.runSessionAutosaveTick(source: "first")
        XCTAssertEqual(saveCallCount, 1, "the first tick with no prior fingerprint should save")

        coordinator.runSessionAutosaveTick(source: "second")
        XCTAssertEqual(
            saveCallCount,
            1,
            "a second tick with an unchanged fingerprint should skip the write"
        )
    }

    @MainActor
    func testAutosaveTickDoesNotSaveWhileTerminating() {
        var snapshotCallCount = 0
        var saveCallCount = 0
        let coordinator = SessionAutosaveCoordinator(
            sessionPersistenceQueue: DispatchQueue(label: "test.session-autosave.terminating"),
            snapshotProvider: { _ in
                snapshotCallCount += 1
                return Self.fakeSnapshot
            },
            saveSnapshot: { _, _, completion in
                saveCallCount += 1
                completion(true)
            },
            isTerminating: { true },
            isRunningUnderXCTest: { true }
        )

        coordinator.runSessionAutosaveTick(source: "terminating")

        XCTAssertEqual(snapshotCallCount, 0, "a tick while terminating should bail before building a snapshot")
        XCTAssertEqual(saveCallCount, 0, "a tick while terminating should never save")
    }

    @MainActor
    func testRequestPromptSaveCoalescesBurstIntoSingleSave() {
        var saveCallCount = 0
        let saved = expectation(description: "prompt save ran")
        let coordinator = SessionAutosaveCoordinator(
            sessionPersistenceQueue: DispatchQueue(label: "test.session-autosave.prompt-save"),
            snapshotProvider: { _ in Self.fakeSnapshot },
            saveSnapshot: { _, _, completion in
                saveCallCount += 1
                saved.fulfill()
                completion(true)
            },
            isTerminating: { false },
            isRunningUnderXCTest: { true }
        )

        // A burst — one request per pane finishing escrow registration during a
        // multi-pane restore — must fold into a single scheduled snapshot build.
        for _ in 0..<5 {
            coordinator.requestPromptSave(source: "test", after: 0.05)
        }

        wait(for: [saved], timeout: 2.0)
        // Let any erroneously-scheduled extra ticks fire before counting.
        let settle = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { settle.fulfill() }
        wait(for: [settle], timeout: 2.0)
        XCTAssertEqual(
            saveCallCount,
            1,
            "a burst of prompt-save requests must coalesce into exactly one save"
        )
    }
}
