import XCTest

#if canImport(Programa_DEV)
@testable import Programa_DEV
#elseif canImport(Programa)
@testable import Programa
#endif

/// Unit tests for the generic undo-staging engine behind issue #140's terminal-close undo
/// window. Deliberately exercised through the closure-based `stage(restore:finalize:)` API only
/// -- no `Workspace`/`Panel` construction needed, matching the store's design goal of being
/// testable without a live terminal.
@MainActor
final class ClosedTerminalUndoStoreTests: XCTestCase {
    func testRestoreMostRecentOnEmptyStoreReturnsFalse() {
        let store = ClosedTerminalUndoStore(gracePeriod: 5)
        XCTAssertFalse(store.restoreMostRecent())
    }

    func testStageThenRestoreMostRecentRunsRestoreAndCancelsExpiry() async {
        let store = ClosedTerminalUndoStore(gracePeriod: 5)
        var restoreCount = 0
        var finalizeCount = 0
        store.stage(restore: { restoreCount += 1 }, finalize: { finalizeCount += 1 })

        XCTAssertTrue(store.restoreMostRecent())
        XCTAssertEqual(restoreCount, 1)

        // The 5s grace period would otherwise still be pending; give the (already-cancelled)
        // timer a moment to prove it does not also fire finalize.
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(finalizeCount, 0)
    }

    func testRestoreMostRecentPopsNewestFirst() {
        let store = ClosedTerminalUndoStore(gracePeriod: 5)
        var restoredOrder: [Int] = []
        store.stage(restore: { restoredOrder.append(1) }, finalize: {})
        store.stage(restore: { restoredOrder.append(2) }, finalize: {})

        XCTAssertTrue(store.restoreMostRecent())
        XCTAssertEqual(restoredOrder, [2])

        XCTAssertTrue(store.restoreMostRecent())
        XCTAssertEqual(restoredOrder, [2, 1])

        XCTAssertFalse(store.restoreMostRecent())
    }

    func testExpiryFinalizesAfterGracePeriodElapses() async {
        let store = ClosedTerminalUndoStore(gracePeriod: 0.05)
        var restoreCount = 0
        var finalizeCount = 0
        store.stage(restore: { restoreCount += 1 }, finalize: { finalizeCount += 1 })

        // Loaded CI runners can starve the expiry timer far past the grace
        // period; poll with a generous ceiling instead of a fixed sleep.
        for _ in 0..<50 where finalizeCount == 0 {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        XCTAssertEqual(finalizeCount, 1)
        XCTAssertEqual(restoreCount, 0)
        // Once expired, it's gone -- nothing left to restore.
        XCTAssertFalse(store.restoreMostRecent())
    }

    func testExpireAllFinalizesEveryPendingEntryImmediately() {
        let store = ClosedTerminalUndoStore(gracePeriod: 5)
        var finalizeCount = 0
        store.stage(restore: {}, finalize: { finalizeCount += 1 })
        store.stage(restore: {}, finalize: { finalizeCount += 1 })
        XCTAssertFalse(store.isEmpty)

        store.expireAll()

        XCTAssertEqual(finalizeCount, 2)
        XCTAssertTrue(store.isEmpty)
        XCTAssertFalse(store.restoreMostRecent())
    }
}
