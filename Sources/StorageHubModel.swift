import AppKit
import Combine
import Foundation

struct StorageConfirmationItem: Equatable, Sendable {
    let name: String
    let path: String?
    let sizeBytes: Int64
}

struct StorageConfirmationSummary: Equatable, Sendable {
    let items: [StorageConfirmationItem]
    var totalBytes: Int64 { items.reduce(0) { $0 + $1.sizeBytes } }

    init(worktreeOutcome: WorktreeStorage.CleanOutcome, cacheOutcome: StorageCacheCleanOutcome) {
        items = worktreeOutcome.removed.map {
            StorageConfirmationItem(name: $0.branch ?? ($0.path as NSString).lastPathComponent, path: $0.path, sizeBytes: $0.sizeBytes)
        } + cacheOutcome.removed.map {
            StorageConfirmationItem(name: $0.title, path: $0.path, sizeBytes: $0.sizeBytes)
        }
    }
}

struct StorageHubSnapshot: Sendable {
    let scannedAt: Date
    let worktrees: [WorktreeStorageEntry]
    let caches: [StorageCacheItem]
    let worktreePreview: WorktreeStorage.CleanOutcome

    var reclaimableBytes: Int64 {
        worktreePreview.reclaimedBytes + caches.filter { $0.blocker == nil }.reduce(0) { $0 + $1.sizeBytes }
    }
}

struct StorageCleanPreview: Sendable {
    let worktrees: WorktreeStorage.CleanOutcome
    let caches: StorageCacheCleanOutcome
    var summary: StorageConfirmationSummary { StorageConfirmationSummary(worktreeOutcome: worktrees, cacheOutcome: caches) }
}

@MainActor
final class StorageHubModel: ObservableObject {
    static let shared = StorageHubModel()
    @Published private(set) var snapshot: StorageHubSnapshot?
    @Published private(set) var isRunning = false
    @Published private(set) var preview: StorageCleanPreview?
    @Published private(set) var result: StorageCleanPreview?
    @Published private(set) var requestedWindowID: ObjectIdentifier?
    @Published private(set) var capacity: StorageVolumeCapacity?

    private var visibleClients = Set<UUID>()
    private let queue = DispatchQueue(label: "com.darkroom.programa.storage-hub", qos: .utility)
    nonisolated private static let manualPolicy = WorktreeRemovalPolicy(gracePeriod: nil, includeExternal: false)

    var cachedReclaimableBytes: Int64? { snapshot?.reclaimableBytes }

    func requestOpen(window: NSWindow) {
        requestedWindowID = ObjectIdentifier(window)
    }

    func consumeOpenRequest(window: NSWindow) -> Bool {
        guard requestedWindowID == ObjectIdentifier(window) else { return false }
        requestedWindowID = nil
        return true
    }

    func opened(client: UUID) {
        visibleClients.insert(client)
        refresh()
    }

    func closed(client: UUID) {
        visibleClients.remove(client)
        if visibleClients.isEmpty { preview = nil }
    }

    func refresh() {
        guard !visibleClients.isEmpty, !isRunning else { return }
        let needsScan = snapshot.map { Date().timeIntervalSince($0.scannedAt) > 300 } ?? true
        isRunning = true
        let openDirectories = WorktreeStorage.openWorkspaceDirectories()
        queue.async {
            let capacity = StorageVolumeCapacity.read()
            let scanned = needsScan ? Self.scan(openDirectories: openDirectories) : nil
            DispatchQueue.main.async {
                self.capacity = capacity
                if let scanned { self.snapshot = scanned }
                self.isRunning = false
            }
        }
    }

    func prepareClean(category: StorageCategoryID? = nil) {
        guard !visibleClients.isEmpty, !isRunning else { return }
        isRunning = true
        preview = nil
        result = nil
        let openDirectories = WorktreeStorage.openWorkspaceDirectories()
        queue.async {
            WorktreeStorage.passLock.lock()
            let worktreeEntries = category == nil ? WorktreeStorage.scanAll(openDirectories: openDirectories) : []
            let cacheItems = category.map { StorageCategories.scan(categories: [$0]) } ?? []
            let prepared = StorageCleanPreview(
                worktrees: WorktreeStorage.clean(
                    entries: worktreeEntries, policy: Self.manualPolicy, now: Date(), dryRun: true,
                    openDirectories: { openDirectories }, processCwds: WorktreeStorage.processWorkingDirectories
                ),
                caches: StorageCategories.clean(items: cacheItems, automaticOnly: false, dryRun: true)
            )
            WorktreeStorage.passLock.unlock()
            DispatchQueue.main.async {
                if !self.visibleClients.isEmpty { self.preview = prepared }
                self.isRunning = false
            }
        }
    }

    func cancelConfirmation() { preview = nil }

    func confirmClean() {
        guard !visibleClients.isEmpty, !isRunning, let preview, !preview.summary.items.isEmpty else { return }
        self.preview = nil
        isRunning = true
        queue.async {
            WorktreeStorage.passLock.lock()
            // Reclassify only the confirmed worktrees, retaining the exact path and HEAD allowlist.
            let refreshed = preview.worktrees.removed.isEmpty ? [] : WorktreeStorage.scan(
                repositories: WorktreeStorage.discoverRepositories(candidateDirectories: preview.worktrees.removed.map(\.repoRoot)),
                programaDirectory: ProgramaWorktreeSettings.resolvedDirectory(),
                openDirectories: Self.currentOpenDirectories(), processCwds: WorktreeStorage.processWorkingDirectories()
            ).filter { entry in
                preview.worktrees.removed.contains { $0.path == entry.path && $0.headSHA == entry.headSHA }
            }
            var worktreeOutcome = WorktreeStorage.clean(
                entries: refreshed, policy: Self.manualPolicy, now: Date(), dryRun: false,
                openDirectories: Self.currentOpenDirectories, processCwds: WorktreeStorage.processWorkingDirectories
            )
            worktreeOutcome.kept += preview.worktrees.kept
            for entry in preview.worktrees.removed where !refreshed.contains(where: { $0.path == entry.path }) {
                worktreeOutcome.kept.append(WorktreeStorage.KeptWorktree(entry: entry, reason: .blocker(.statusUnknown)))
            }
            var cacheOutcome = StorageCategories.clean(items: preview.caches.removed, automaticOnly: false, dryRun: false)
            cacheOutcome.kept += preview.caches.kept
            let outcome = StorageCleanPreview(worktrees: worktreeOutcome, caches: cacheOutcome)
            WorktreeStorage.passLock.unlock()
            let capacity = StorageVolumeCapacity.read()
            DispatchQueue.main.async {
                self.result = outcome
                self.capacity = capacity
                self.snapshot = nil
                self.isRunning = false
                self.refresh()
            }
        }
    }

    nonisolated private static func currentOpenDirectories() -> [String] {
        DispatchQueue.main.sync { MainActor.assumeIsolated { WorktreeStorage.openWorkspaceDirectories() } }
    }

    nonisolated private static func scan(openDirectories: [String]) -> StorageHubSnapshot {
        WorktreeStorage.passLock.lock()
        defer { WorktreeStorage.passLock.unlock() }
        let entries = WorktreeStorage.scanAll(openDirectories: openDirectories)
        return StorageHubSnapshot(
            scannedAt: Date(), worktrees: entries, caches: StorageCategories.scan(),
            worktreePreview: WorktreeStorage.clean(
                entries: entries, policy: manualPolicy, now: Date(), dryRun: true,
                openDirectories: { openDirectories }, processCwds: WorktreeStorage.processWorkingDirectories
            )
        )
    }
}
