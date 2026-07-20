import Foundation

/// Generic, closure-based undo staging for terminal panel closes (issue #140, ported from
/// upstream cmux's task-undo-close-grace-period). Closing a terminal stages it here instead of
/// tearing it down immediately; if nothing restores it within the grace period, `finalize` runs
/// the real teardown.
///
/// This store deliberately knows nothing about `Workspace`/`Panel` types -- callers hand it two
/// closures per staged close (`restore` and `finalize`) that already capture everything they need
/// (the detached panel transfer, the workspace/pane to reattach into, etc). That keeps this type
/// trivially unit-testable without constructing a live `Workspace.DetachedSurfaceTransfer`.
///
/// Owned by `TabManager` (`closedTerminalUndoStore`), not a bare global singleton, since
/// `TabManager` is the single reachable owner from every reopen call site (AppDelegate's shortcut
/// dispatch, ProgramaApp's menu command, ContentView) as well as every close call site
/// (Workspace's confirm-close delegate, `closeRuntimeSurfaceWithConfirmation`, the v2 socket
/// close handler).
@MainActor
final class ClosedTerminalUndoStore {
    static let gracePeriodSeconds: TimeInterval = 5

    private struct Entry {
        let id: UUID
        let restore: () -> Void
        let finalize: () -> Void
        var expirationTask: Task<Void, Never>?
    }

    private var entries: [Entry] = []
    private let gracePeriod: TimeInterval

    init(gracePeriod: TimeInterval = ClosedTerminalUndoStore.gracePeriodSeconds) {
        self.gracePeriod = gracePeriod
    }

    var isEmpty: Bool { entries.isEmpty }

    /// Stages a close for undo. `restore` reattaches the closed panel; `finalize` performs the
    /// real teardown once the grace period elapses without a restore. Returns an opaque id that
    /// can be used to cancel staging early (not currently needed by any caller).
    @discardableResult
    func stage(restore: @escaping () -> Void, finalize: @escaping () -> Void) -> UUID {
        let id = UUID()
        let capturedGracePeriod = gracePeriod
        let task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, capturedGracePeriod) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.expire(id: id)
            }
        }
        entries.append(Entry(id: id, restore: restore, finalize: finalize, expirationTask: task))
        return id
    }

    /// Restores the most recently staged close, cancelling its expiration timer. Returns false
    /// when there is nothing staged.
    @discardableResult
    func restoreMostRecent() -> Bool {
        guard let entry = entries.popLast() else { return false }
        entry.expirationTask?.cancel()
        entry.restore()
        return true
    }

    private func expire(id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let entry = entries.remove(at: index)
        entry.finalize()
    }

    /// Immediately finalizes every staged close, cancelling their timers. Call on app termination
    /// so a staged close doesn't outlive the process it's tracking, and in tests to avoid leaking
    /// timers across cases.
    func expireAll() {
        let pending = entries
        entries.removeAll()
        for entry in pending {
            entry.expirationTask?.cancel()
            entry.finalize()
        }
    }
}
