// v2 socket handlers for `storage.scan` / `storage.clean` (git worktree disk usage). Git and
// filesystem work runs on the socket thread through WorktreeStorage; v2MainSync is used only to
// snapshot the directories open in workspaces.
import Foundation

extension TerminalController {
    nonisolated func v2StorageScan(params: [String: Any]) -> V2CallResult {
        let openDirectories = v2MainSync { WorktreeStorage.openWorkspaceDirectories() }
        let entries = WorktreeStorage.scanAll(openDirectories: openDirectories)
        let policy = WorktreeRemovalPolicy.automatic(gracePeriodHours: ProgramaWorktreeSettings.autoRemoveAfterHours())
        let now = Date()
        let formatter = ISO8601DateFormatter()

        var payloads: [[String: Any]] = []
        var totalBytes: Int64 = 0
        var reclaimableBytes: Int64 = 0
        for entry in entries {
            let blocker = entry.removalBlocker(policy: policy, now: now)
            totalBytes += entry.sizeBytes
            if blocker == nil {
                reclaimableBytes += entry.sizeBytes
            }
            payloads.append([
                "repo_root": entry.repoRoot,
                "path": entry.path,
                "branch": v2OrNull(entry.branch),
                "size_bytes": entry.sizeBytes,
                "size_partial": entry.sizePartial,
                "last_modified": v2OrNull(entry.lastModified.map { formatter.string(from: $0) }),
                "programa_created": entry.isProgramaCreated,
                "dirty": v2OrNull(entry.isDirty),
                "ignored_env_files": v2OrNull(entry.hasIgnoredEnvFiles),
                "merged": v2OrNull(entry.isMerged),
                "open_in_workspace": entry.isOpenInWorkspace,
                "process_running": entry.isProcessRunningInside,
                "removable": blocker == nil,
                "blocker": v2OrNull(blocker?.rawValue),
            ])
        }
        return .ok([
            "worktrees": payloads,
            "total_bytes": totalBytes,
            "reclaimable_bytes": reclaimableBytes,
        ])
    }

    nonisolated func v2StorageClean(params: [String: Any]) -> V2CallResult {
        let dryRun = v2Bool(params, "dry_run") ?? true
        let includeExternal = v2Bool(params, "include_external") ?? false
        let ignoreGracePeriod = v2Bool(params, "ignore_grace_period") ?? false
        let policy = WorktreeRemovalPolicy(
            gracePeriod: ignoreGracePeriod ? nil : ProgramaWorktreeSettings.autoRemoveAfterHours() * 3600,
            includeExternal: includeExternal
        )

        WorktreeStorage.passLock.lock()
        defer { WorktreeStorage.passLock.unlock() }
        let entries = WorktreeStorage.scanAll(
            openDirectories: v2MainSync { WorktreeStorage.openWorkspaceDirectories() }
        )
        let outcome = WorktreeStorage.clean(
            entries: entries,
            policy: policy,
            now: Date(),
            dryRun: dryRun,
            openDirectories: { self.v2MainSync { WorktreeStorage.openWorkspaceDirectories() } },
            processCwds: WorktreeStorage.processWorkingDirectories
        )

        let kept: [[String: Any]] = outcome.kept.map { kept in
            var payload: [String: Any] = ["path": kept.entry.path, "blocker": kept.reason.code]
            if case .gitRefused(let message) = kept.reason {
                payload["message"] = message
            }
            return payload
        }
        return .ok([
            "removed": outcome.removed.map(\.path),
            "kept": kept,
            "reclaimed_bytes": outcome.reclaimedBytes,
            "dry_run": dryRun,
        ])
    }
}
