// Session-restore history (docs/plans/snapshot-restore.md): v2 socket handlers for
// `snapshot.list`/`snapshot.restore`. The archive itself is written by
// `SessionPersistenceStore.rotateIntoHistory()` at launch, so these handlers only ever
// read `session-history/*.json` and (for restore) create windows from what they find --
// they never touch the live `session-<bundleId>.json` file. Mirrors
// `TerminalController+Worktree.swift`'s `V2CallResult`/`v2MainSync` shape.
import Foundation

extension TerminalController {
    // MARK: - V2 Snapshot Methods

    nonisolated func v2SnapshotList(params _: [String: Any]) -> V2CallResult {
        let isoFormatter = ISO8601DateFormatter()
        let payloads = SessionPersistenceStore.historyFileURLs().compactMap { url -> [String: Any]? in
            guard let data = try? Data(contentsOf: url),
                  let snapshot = SessionPersistenceStore.decodeSnapshot(from: data) else {
                return nil
            }
            return v2SnapshotListEntry(
                id: v2SnapshotHistoryId(for: url),
                snapshot: snapshot,
                isoFormatter: isoFormatter
            )
        }
        return .ok(["snapshots": payloads])
    }

    nonisolated func v2SnapshotRestore(params: [String: Any]) -> V2CallResult {
        let requestedId = v2String(params, "id")
        let entries = SessionPersistenceStore.historyFileURLs()

        let targetURL: URL?
        if let requestedId, requestedId.lowercased() != "latest" {
            targetURL = entries.first { v2SnapshotHistoryId(for: $0) == requestedId }
        } else {
            targetURL = SessionPersistenceStore.ownedHistoryFileURLs().first
        }

        guard let targetURL else {
            return .err(code: "not_found", message: "No archived snapshot found", data: nil)
        }
        guard let data = try? Data(contentsOf: targetURL),
              let snapshot = SessionPersistenceStore.decodeSnapshot(from: data) else {
            return .err(code: "not_found", message: "Archived snapshot is unreadable or corrupt", data: nil)
        }
        guard snapshot.version == SessionSnapshotSchema.currentVersion else {
            return .err(
                code: "version_mismatch",
                message: "Archived snapshot version \(snapshot.version) does not match the current schema version \(SessionSnapshotSchema.currentVersion)",
                data: nil
            )
        }
        guard !snapshot.windows.isEmpty else {
            return .err(code: "not_found", message: "Archived snapshot has no windows to restore", data: nil)
        }

        let windowsToRestore: [SessionWindowSnapshot] = SessionPersistenceStore.windowsToRestore(from: snapshot)
        let workspaceCount = windowsToRestore.reduce(0) { $0 + $1.tabManager.workspaces.count }
        let panelCount = windowsToRestore.reduce(0) { total, window in
            total + window.tabManager.workspaces.reduce(0) { $0 + $1.panels.count }
        }
        v2MainSync {
            for windowSnapshot in windowsToRestore {
                _ = AppDelegate.shared?.createMainWindow(sessionWindowSnapshot: windowSnapshot)
            }
        }

        return .ok([
            "restored": [
                "windows": windowsToRestore.count,
                "workspaces": workspaceCount,
                "panels": panelCount
            ]
        ])
    }

    // MARK: - Shared helpers

    private nonisolated func v2SnapshotHistoryId(for url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    private nonisolated func v2SnapshotListEntry(
        id: String,
        snapshot: AppSessionSnapshot,
        isoFormatter: ISO8601DateFormatter
    ) -> [String: Any] {
        let workspaceCount = snapshot.windows.reduce(0) { $0 + $1.tabManager.workspaces.count }
        let panelCount = snapshot.windows.reduce(0) { total, window in
            total + window.tabManager.workspaces.reduce(0) { $0 + $1.panels.count }
        }
        return [
            "id": id,
            "saved_at": isoFormatter.string(from: Date(timeIntervalSince1970: snapshot.createdAt)),
            "created_at": snapshot.createdAt,
            "clean_shutdown": v2OrNull(snapshot.cleanShutdown),
            "window_count": snapshot.windows.count,
            "workspace_count": workspaceCount,
            "panel_count": panelCount
        ]
    }
}
