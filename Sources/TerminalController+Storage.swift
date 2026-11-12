// v2 socket handlers for `storage.scan` / `storage.clean`. Git and
// filesystem work runs on the socket thread through WorktreeStorage; v2MainSync is used only to
// snapshot the directories open in workspaces.
import Foundation

private enum StorageTimestamp {
    /// ISO8601DateFormatter is thread-safe; the handlers run on the socket thread.
    static let formatter = ISO8601DateFormatter()
}

extension TerminalController {
    nonisolated func v2StorageScan(params: [String: Any]) -> V2CallResult {
        let settings = StorageSettings.read()
        let openDirectories = v2MainSync { WorktreeStorage.openWorkspaceDirectories() }
        let entries = WorktreeStorage.scanAll(openDirectories: openDirectories, programaDirectory: settings.directory)
        let policy = WorktreeRemovalPolicy.manual(gracePeriodHours: settings.autoRemoveAfterHours)
        let now = Date()

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
                "last_modified": v2OrNull(entry.lastModified.map(StorageTimestamp.formatter.string(from:))),
                "programa_created": entry.isProgramaCreated,
                "dirty": v2OrNull(entry.isDirty),
                "ignored_env_files": v2OrNull(entry.hasIgnoredEnvFiles),
                "ignored_files": v2OrNull(entry.hasIgnoredFiles),
                "merged": v2OrNull(entry.isMerged),
                "open_in_workspace": entry.isOpenInWorkspace,
                "process_running": entry.isProcessRunningInside,
                "removable": blocker == nil,
                "blocker": v2OrNull(blocker?.rawValue),
            ])
        }
        let caches = StorageCategories.scan(settings: settings)
        var cacheTotals: [String: Any] = [:]
        for category in StorageCategoryID.allCases {
            let items = caches.filter { $0.category == category }
            cacheTotals[category.rawValue] = [
                "total_bytes": items.reduce(Int64(0)) { $0 + $1.sizeBytes },
                "reclaimable_bytes": items.filter { $0.autoCleanable && $0.blocker == nil }.reduce(Int64(0)) { $0 + $1.sizeBytes },
                "size_partial": items.contains { $0.sizePartial },
            ]
        }
        return .ok([
            "worktrees": payloads,
            "total_bytes": totalBytes,
            "reclaimable_bytes": reclaimableBytes,
            "caches": caches.map(v2StorageCachePayload),
            "cache_totals": cacheTotals,
        ])
    }

    nonisolated func v2StorageClean(params: [String: Any]) -> V2CallResult {
        for key in ["categories", "items", "paths"] {
            if let value = params[key], !(value is [String]) { return v2InvalidParam(key) }
        }
        let categoryNames = params["categories"] as? [String] ?? []
        let categories = categoryNames.compactMap(StorageCategoryID.init(rawValue:))
        guard categories.count == categoryNames.count else { return v2InvalidParam("categories") }
        let itemIDs = params["items"] as? [String] ?? []
        guard itemIDs.allSatisfy({ !$0.isEmpty && !$0.contains("\0") }) else { return v2InvalidParam("items") }
        let rawPaths = params["paths"] as? [String] ?? []
        guard rawPaths.allSatisfy({ $0.hasPrefix("/") && !$0.contains("\0") }) else { return v2InvalidParam("paths") }
        let paths = rawPaths.map(WorktreeStorage.resolvedPath)
        let dryRun = v2Bool(params, "dry_run") ?? true
        let includeExternal = v2Bool(params, "include_external") ?? false
        let ignoreGracePeriod = v2Bool(params, "ignore_grace_period") ?? false
        WorktreeStorage.passLock.lock()
        defer { WorktreeStorage.passLock.unlock() }
        let settings = StorageSettings.read()
        let policy = WorktreeRemovalPolicy.manual(
            gracePeriodHours: ignoreGracePeriod ? nil : settings.autoRemoveAfterHours,
            includeExternal: includeExternal
        )

        let entries = WorktreeStorage.scanAll(
            openDirectories: v2MainSync { WorktreeStorage.openWorkspaceDirectories() },
            programaDirectory: settings.directory
        ).filter { entry in
            paths.isEmpty || paths.contains { WorktreeStorage.isPath(WorktreeStorage.resolvedPath(entry.path), equalToOrInside: $0, caseInsensitive: false) }
        }
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
        let cacheCategories = categories.isEmpty && !itemIDs.isEmpty ? StorageCategoryID.allCases : categories
        let cacheItems = StorageCategories.scan(categories: cacheCategories, settings: settings).filter {
            itemIDs.isEmpty || itemIDs.contains($0.id)
        }
        let cacheOutcome = StorageCategories.clean(items: cacheItems, automaticOnly: false, dryRun: dryRun, settings: settings)
        return .ok([
            "removed": outcome.removed.map(\.path),
            "kept": kept,
            "reclaimed_bytes": outcome.reclaimedBytes,
            "dry_run": dryRun,
            "caches_removed": cacheOutcome.removed.map(v2StorageCachePayload),
            "caches_kept": cacheOutcome.kept.map { kept -> [String: Any] in
                var payload = v2StorageCachePayload(kept.item)
                payload["blocker"] = kept.reason
                return payload
            },
            "caches_reclaimed_bytes": cacheOutcome.reclaimedBytes,
        ])
    }

    private nonisolated func v2StorageCachePayload(_ item: StorageCacheItem) -> [String: Any] {
        [
            "id": item.id,
            "category": item.category.rawValue,
            "title": item.title,
            "path": v2OrNull(item.path),
            "size_bytes": item.sizeBytes,
            "size_partial": item.sizePartial,
            "last_used": v2OrNull(item.lastUsed.map(StorageTimestamp.formatter.string(from:))),
            "auto_cleanable": item.autoCleanable,
            "blocker": v2OrNull(item.blocker),
        ]
    }
}
