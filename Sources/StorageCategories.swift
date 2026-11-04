import Foundation

/// Developer caches that Programa storage measures and cleans next to worktrees.
/// Every item here can be rebuilt by its tool; user data (AVDs, archives, source) never is one.
enum StorageCategoryID: String, CaseIterable, Sendable {
    case xcode
    case android
    case packages
}

struct StorageCacheItem: Equatable, Sendable {
    /// Stable across scans, e.g. "xcode.derived_data/MyApp-abcd". `storage clean --item` takes it.
    let id: String
    let category: StorageCategoryID
    let title: String
    let path: String?
    let sizeBytes: Int64
    let sizePartial: Bool
    let lastUsed: Date?
    /// The background pass may remove it without asking once `blocker` is nil.
    let autoCleanable: Bool
    /// Why it must stay right now (for example "xcode_running"); nil means removable.
    let blocker: String?
}

struct StorageCacheCleanOutcome: Equatable, Sendable {
    struct Kept: Equatable, Sendable {
        let item: StorageCacheItem
        let reason: String
    }

    var removed: [StorageCacheItem] = []
    var kept: [Kept] = []
    var reclaimedBytes: Int64 = 0
}

enum StorageCategories {
    /// Blocking; call off the main thread.
    static func scan(
        categories: [StorageCategoryID] = StorageCategoryID.allCases,
        sizeWalkTimeout: TimeInterval = 20
    ) -> [StorageCacheItem] {
        guard !categories.isEmpty else { return [] }
        return scan(categories: categories, sizeWalkTimeout: sizeWalkTimeout, context: .live())
    }

    /// Blocking; call off the main thread. Rechecks each item's blocker right before removing it.
    /// With `automaticOnly`, items that are not `autoCleanable` are kept with reason "manual_only".
    static func clean(
        items: [StorageCacheItem],
        automaticOnly: Bool,
        dryRun: Bool,
        now: Date = Date()
    ) -> StorageCacheCleanOutcome {
        guard !items.isEmpty else { return StorageCacheCleanOutcome() }
        return clean(items: items, automaticOnly: automaticOnly, dryRun: dryRun, now: now, context: .live())
    }

    static func scan(
        categories: [StorageCategoryID] = StorageCategoryID.allCases,
        sizeWalkTimeout: TimeInterval = 20,
        context: StorageCacheContext
    ) -> [StorageCacheItem] {
        categories.flatMap { category in
            switch category {
            case .xcode: StorageXcodeCaches.scan(context, timeout: sizeWalkTimeout)
            case .android: StorageAndroidCaches.scan(context, timeout: sizeWalkTimeout)
            case .packages: StoragePackageCaches.scan(context, timeout: sizeWalkTimeout)
            }
        }
    }

    static func clean(
        items: [StorageCacheItem], automaticOnly: Bool, dryRun: Bool,
        now: Date = Date(), context: StorageCacheContext
    ) -> StorageCacheCleanOutcome {
        var outcome = StorageCacheCleanOutcome()
        var seen = Set<String>()
        for item in items where seen.insert(item.id).inserted {
            // IDs are selectors, never authority to delete a caller-supplied path.
            let current = scan(categories: [item.category], sizeWalkTimeout: 0, context: context.at(now)).first { $0.id == item.id }
            guard let current, current.path == item.path else {
                outcome.kept.append(.init(item: item, reason: "no_longer_eligible"))
                continue
            }
            let fresh = StorageCacheItem(
                id: current.id, category: current.category, title: current.title, path: current.path,
                sizeBytes: item.sizeBytes, sizePartial: item.sizePartial, lastUsed: current.lastUsed,
                autoCleanable: current.autoCleanable, blocker: current.blocker
            )
            if let blocker = fresh.blocker {
                outcome.kept.append(.init(item: fresh, reason: blocker))
                continue
            }
            guard !automaticOnly || fresh.autoCleanable else {
                outcome.kept.append(.init(item: fresh, reason: "manual_only"))
                continue
            }
            guard !dryRun else {
                outcome.removed.append(fresh)
                outcome.reclaimedBytes += fresh.sizeBytes
                continue
            }
            let before = measuredSize(fresh)
            let removed: Bool
            switch item.category {
            case .xcode: removed = StorageXcodeCaches.remove(fresh, context: context)
            case .android: removed = StorageAndroidCaches.remove(fresh, context: context)
            case .packages: removed = StoragePackageCaches.remove(fresh, context: context)
            }
            if removed {
                outcome.removed.append(fresh)
                let after = fresh.path == nil
                    ? scan(categories: [fresh.category], context: context).first(where: { $0.id == fresh.id })?.sizeBytes ?? 0
                    : measuredSize(fresh)
                outcome.reclaimedBytes += max(0, before - after)
            } else {
                outcome.kept.append(.init(item: fresh, reason: "clean_failed"))
            }
        }
        return outcome
    }

    private static func measuredSize(_ item: StorageCacheItem) -> Int64 {
        guard let path = item.path else { return item.sizeBytes }
        guard StorageCacheSupport.directory(path) else { return 0 }
        return item.id == "android.gradle_cache/rest"
            ? StorageAndroidCaches.sizeOfRest(path, timeout: 20).bytes
            : WorktreeStorage.directorySize(atPath: path, timeout: 20).bytes
    }
}
