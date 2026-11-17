import AppKit
import SwiftUI

/// One archive in `session-history/` that `SessionPersistenceStore.restorableHistorySnapshot` accepts.
struct SessionHistorySummary: Hashable, Sendable {
    let url: URL
    let savedAt: Date
    /// Counted from the windows a restore actually opens, after the `windowsToRestore` clamp.
    let workspaceCount: Int
}

/// The saved sessions the palette's "Restore Previous Session…" picker lists, newest first.
/// Covers every bundle's archives, like `snapshot.list`. Archives are decoded off the main
/// thread and cached by modification date, so reopening the picker only reads new files.
@MainActor
final class SessionHistoryStore: ObservableObject {
    static let shared = SessionHistoryStore()

    /// `nil` until the first scan finishes.
    @Published private(set) var summaries: [SessionHistorySummary]?

    fileprivate struct CachedArchive: Sendable {
        let modifiedAt: Date?
        let summary: SessionHistorySummary?
    }

    private var cache: [URL: CachedArchive] = [:]
    private var scanTask: Task<Void, Never>?

    func refresh() {
        scanTask?.cancel()
        let cache = cache
        scanTask = Task {
            let result = await Self.scan(cache: cache)
            guard !Task.isCancelled else { return }
            self.cache = result.cache
            summaries = result.summaries
        }
    }

    private nonisolated static func scan(
        cache: [URL: CachedArchive]
    ) async -> (summaries: [SessionHistorySummary], cache: [URL: CachedArchive]) {
        var nextCache: [URL: CachedArchive] = [:]
        var summaries: [SessionHistorySummary] = []
        for url in SessionPersistenceStore.historyFileURLs() {
            if Task.isCancelled { break }
            let modifiedAt = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            let archive: CachedArchive
            if let cached = cache[url], cached.modifiedAt == modifiedAt {
                archive = cached
            } else {
                archive = CachedArchive(modifiedAt: modifiedAt, summary: summary(of: url))
            }
            nextCache[url] = archive
            if let summary = archive.summary { summaries.append(summary) }
        }
        return (summaries.sorted { $0.savedAt > $1.savedAt }, nextCache)
    }

    private nonisolated static func summary(of url: URL) -> SessionHistorySummary? {
        guard case .success(let snapshot) = SessionPersistenceStore.restorableHistorySnapshot(at: url) else {
            return nil
        }
        let windows = SessionPersistenceStore.windowsToRestore(from: snapshot)
        return SessionHistorySummary(
            url: url,
            savedAt: Date(timeIntervalSince1970: snapshot.createdAt),
            workspaceCount: windows.reduce(0) { $0 + $1.tabManager.workspaces.count }
        )
    }
}

extension CommandPaletteView {
    func beginSessionRestorePickFlow() {
        switcherPicker = .sessionRestore
        sessionHistoryStore.refresh()
        resetCommandPaletteListState(initialQuery: "")
    }

    var sessionRestoreEmptyStateText: String {
        switch sessionHistoryStore.summaries {
        case nil:
            return String(localized: "commandPalette.search.sessionRestoreLoading", defaultValue: "Loading saved sessions…")
        case let summaries? where summaries.isEmpty:
            return String(localized: "commandPalette.search.sessionRestoreNone", defaultValue: "No saved sessions yet.")
        default:
            return String(localized: "commandPalette.search.sessionRestoreEmpty", defaultValue: "No saved sessions match your search.")
        }
    }

    func sessionRestoreEntriesFingerprint() -> Int {
        var hasher = Hasher()
        hasher.combine("sessionRestore")
        hasher.combine(sessionHistoryStore.summaries)
        return hasher.finalize()
    }

    func sessionRestoreEntries() -> [CommandPaletteCommand] {
        (sessionHistoryStore.summaries ?? []).enumerated().map { index, summary in
            let title = summary.savedAt.formatted(date: .abbreviated, time: .shortened)
            let url = summary.url
            return CommandPaletteCommand(
                id: "sessionRestore." + url.deletingPathExtension().lastPathComponent,
                rank: index,
                title: title,
                subtitle: Self.sessionWorkspaceCountText(summary.workspaceCount),
                shortcutHint: nil,
                kindLabel: nil,
                keywords: ["session", "restore", "snapshot", title],
                dismissOnRun: true,
                action: {
                    restoreSavedSession(at: url)
                }
            )
        }
    }

    private static func sessionWorkspaceCountText(_ count: Int) -> String {
        count == 1
            ? String(localized: "commandPalette.sessionRestore.workspaces.one", defaultValue: "1 workspace")
            : String(
                format: String(localized: "commandPalette.sessionRestore.workspaces.other", defaultValue: "%lld workspaces"),
                count
            )
    }

    /// Re-reads the archive, which may have been pruned or replaced since the picker listed it.
    private func restoreSavedSession(at url: URL) {
        Task {
            let result = await Self.loadRestorableSession(at: url)
            switch result {
            case .success(let snapshot):
                for window in SessionPersistenceStore.windowsToRestore(from: snapshot) {
                    _ = AppDelegate.shared?.createMainWindow(sessionWindowSnapshot: window)
                }
            case .failure(let failure):
                Self.showLayoutAlert(
                    title: String(localized: "sessionRestore.failed.title", defaultValue: "Session Can't Be Restored"),
                    message: Self.sessionRestoreFailureMessage(failure)
                )
            }
        }
    }

    private nonisolated static func loadRestorableSession(
        at url: URL
    ) async -> Result<AppSessionSnapshot, SessionPersistenceStore.HistorySnapshotRestoreFailure> {
        SessionPersistenceStore.restorableHistorySnapshot(at: url)
    }

    private static func sessionRestoreFailureMessage(
        _ failure: SessionPersistenceStore.HistorySnapshotRestoreFailure
    ) -> String {
        switch failure {
        case .unreadable:
            return String(localized: "sessionRestore.failed.unreadable", defaultValue: "This saved session can't be read. It may have been deleted or damaged.")
        case .versionMismatch:
            return String(localized: "sessionRestore.failed.versionMismatch", defaultValue: "This saved session was written by a different version of Programa.")
        case .noWindows:
            return String(localized: "sessionRestore.failed.noWindows", defaultValue: "This saved session has no windows to restore.")
        }
    }
}
