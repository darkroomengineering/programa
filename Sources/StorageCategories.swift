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
        []
    }

    /// Blocking; call off the main thread. Rechecks each item's blocker right before removing it.
    /// With `automaticOnly`, items that are not `autoCleanable` are kept with reason "manual_only".
    static func clean(
        items: [StorageCacheItem],
        automaticOnly: Bool,
        dryRun: Bool,
        now: Date = Date()
    ) -> StorageCacheCleanOutcome {
        StorageCacheCleanOutcome()
    }
}
