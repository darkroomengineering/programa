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

struct StorageLiveSession: Sendable, Identifiable {
    struct HeavyFolder: Sendable {
        let name: String
        let bytes: Int64
    }

    var id: String { path }
    let title: String
    let path: String
    var sizeBytes: Int64 = 0
    var sizePartial = true
    var isMeasured = false
    var heavyFolders: [HeavyFolder] = []
}

enum StorageLiveSessions {
    static func sessions(from workspaces: [(title: String, path: String)], homePath: String) -> [StorageLiveSession] {
        let home = WorktreeStorage.resolvedPath(homePath)
        var paths: [String] = []
        var titles: [String: [String]] = [:]
        for workspace in workspaces where !workspace.path.isEmpty {
            let path = WorktreeStorage.resolvedPath(workspace.path)
            guard path != home, path != "/" else { continue }
            if titles[path] == nil { paths.append(path) }
            titles[path, default: []].append(workspace.title)
        }
        return paths.map { StorageLiveSession(title: titles[$0, default: []].joined(separator: ", "), path: $0) }
    }

    static func heavyFolders(in path: String, minimumBytes: Int64 = 50_000_000) -> [StorageLiveSession.HeavyFolder] {
        let names = ["node_modules", ".build", "build", "dist", ".next", "target", "Pods", "DerivedData"]
        return names.compactMap { name -> StorageLiveSession.HeavyFolder? in
            let url = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent(name, isDirectory: true)
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true else { return nil }
            let size = WorktreeStorage.directorySize(atPath: url.path, timeout: 3)
            guard size.bytes >= minimumBytes else { return nil }
            return StorageLiveSession.HeavyFolder(name: name, bytes: size.bytes)
        }.sorted { $0.bytes > $1.bytes }
    }
}

@MainActor
final class StorageHubModel: ObservableObject {
    static let shared = StorageHubModel()
    @Published private(set) var snapshot: StorageHubSnapshot?
    private enum Presentation {
        case empty
        case confirmation(StorageCleanPreview)
        case result(StorageCleanPreview)
    }
    private enum Operation {
        case idle(Presentation)
        case scanning(UUID, Presentation)
        case preparing(UUID)
        case cancelledPreparation(UUID)
        case cleaning(UUID)
    }
    @Published private var operation: Operation = .idle(.empty)
    var isRunning: Bool {
        if case .idle = operation { return false }
        return true
    }
    private var presentation: Presentation {
        switch operation {
        case .idle(let presentation), .scanning(_, let presentation): return presentation
        case .preparing, .cancelledPreparation, .cleaning: return .empty
        }
    }
    var preview: StorageCleanPreview? {
        if case .confirmation(let preview) = presentation { return preview }
        return nil
    }
    var result: StorageCleanPreview? {
        if case .result(let result) = presentation { return result }
        return nil
    }
    @Published private(set) var requestedWindowID: ObjectIdentifier?
    @Published private(set) var capacity: StorageVolumeCapacity?
    @Published private(set) var liveSessions: [StorageLiveSession] = []

    private struct LiveSessionSize: Sendable {
        let measuredAt: Date
        let bytes: Int64
        let partial: Bool
        let heavyFolders: [StorageLiveSession.HeavyFolder]
    }
    private var liveSessionCache: [String: LiveSessionSize] = [:]
    private var liveSessionSources: [StorageLiveSession] = []
    private var isRefreshingLiveSessions = false
    private var liveSessionsRefreshPending = false
    private var liveSessionSourcesToken = UUID()
    private var liveSessionMeasurementToken = UUID()
    private var visibleClients = Set<UUID>()
    private let queue = DispatchQueue(label: "com.darkroom.programa.storage-hub", qos: .utility)
    // Separate from `queue` so slow session measuring never delays scans or cleans.
    private let liveSessionQueue = DispatchQueue(label: "com.darkroom.programa.storage-hub.live-sessions", qos: .utility)
    nonisolated private static let manualPolicy = WorktreeRemovalPolicy.manual(gracePeriodHours: nil)

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
        if visibleClients.isEmpty {
            cancelConfirmation()
            liveSessionSourcesToken = UUID()
        }
    }

    func refresh() {
        guard !visibleClients.isEmpty else { return }
        var workspaces: [(title: String, path: String)] = []
        if let appDelegate = AppDelegate.shared {
            for context in appDelegate.mainWindowContexts.values {
                for workspace in context.tabManager.tabs {
                    workspaces.append((workspace.customTitle ?? workspace.title, workspace.currentDirectory))
                }
            }
        }
        let homePath = NSHomeDirectory()
        let rawWorkspaces = workspaces
        let sourcesToken = UUID()
        liveSessionSourcesToken = sourcesToken
        // realpath can block on a stalled network mount, so resolve off the main actor.
        liveSessionQueue.async {
            let sources = StorageLiveSessions.sessions(from: rawWorkspaces, homePath: homePath)
            DispatchQueue.main.async {
                guard self.liveSessionSourcesToken == sourcesToken else { return }
                self.liveSessionSources = sources
                self.refreshLiveSessions()
            }
        }
        guard !isRunning else { return }
        let needsScan = snapshot.map { Date().timeIntervalSince($0.scannedAt) > 300 } ?? true
        let token = UUID()
        operation = .scanning(token, presentation)
        let openDirectories = WorktreeStorage.openWorkspaceDirectories()
        queue.async {
            let capacity = StorageVolumeCapacity.read()
            let scanned = needsScan ? Self.scan(openDirectories: openDirectories) : nil
            DispatchQueue.main.async {
                guard case .scanning(let currentToken, let presentation) = self.operation,
                      currentToken == token else { return }
                self.capacity = capacity
                if let scanned { self.snapshot = scanned }
                self.operation = .idle(presentation)
            }
        }
    }

    private func refreshLiveSessions() {
        let paths = Set(liveSessionSources.map(\.path))
        liveSessionCache = liveSessionCache.filter { paths.contains($0.key) }
        publishLiveSessions()
        guard !isRefreshingLiveSessions else {
            liveSessionsRefreshPending = true
            return
        }
        let now = Date()
        let stalePaths = liveSessionSources.map(\.path).filter {
            guard let cached = liveSessionCache[$0] else { return true }
            return now.timeIntervalSince(cached.measuredAt) >= 120
        }
        guard !stalePaths.isEmpty else { return }
        isRefreshingLiveSessions = true
        let token = UUID()
        liveSessionMeasurementToken = token
        liveSessionQueue.async {
            var measured: [String: LiveSessionSize] = [:]
            for path in stalePaths {
                let size = WorktreeStorage.directorySize(atPath: path, timeout: 5)
                let heavyFolders = StorageLiveSessions.heavyFolders(in: path)
                measured[path] = LiveSessionSize(
                    measuredAt: Date(), bytes: size.bytes, partial: size.partial, heavyFolders: heavyFolders
                )
            }
            let results = measured
            DispatchQueue.main.async {
                guard self.liveSessionMeasurementToken == token else { return }
                let currentPaths = Set(self.liveSessionSources.map(\.path))
                self.liveSessionCache.merge(results.filter { currentPaths.contains($0.key) }) { _, new in new }
                self.isRefreshingLiveSessions = false
                self.publishLiveSessions()
                if self.liveSessionsRefreshPending {
                    self.liveSessionsRefreshPending = false
                    self.refreshLiveSessions()
                }
            }
        }
    }

    private func publishLiveSessions() {
        liveSessions = liveSessionSources.map { session in
            var measured = session
            if let cached = liveSessionCache[session.path] {
                measured.sizeBytes = cached.bytes
                measured.sizePartial = cached.partial
                measured.heavyFolders = cached.heavyFolders
                measured.isMeasured = true
            }
            return measured
        }.sorted {
            $0.sizeBytes == $1.sizeBytes ? $0.path < $1.path : $0.sizeBytes > $1.sizeBytes
        }
    }

    func prepareClean(category: StorageCategoryID? = nil) {
        guard !visibleClients.isEmpty, !isRunning else { return }
        let token = UUID()
        operation = .preparing(token)
        let openDirectories = WorktreeStorage.openWorkspaceDirectories()
        queue.async {
            WorktreeStorage.passLock.lock()
            let settings = StorageSettings.read()
            let worktreeEntries = category == nil
                ? WorktreeStorage.scanAll(openDirectories: openDirectories, programaDirectory: settings.directory) : []
            let cacheItems = category.map { StorageCategories.scan(categories: [$0], settings: settings) } ?? []
            let prepared = StorageCleanPreview(
                worktrees: WorktreeStorage.clean(
                    entries: worktreeEntries, policy: Self.manualPolicy, now: Date(), dryRun: true,
                    openDirectories: { openDirectories }, processCwds: WorktreeStorage.processWorkingDirectories
                ),
                caches: StorageCategories.clean(items: cacheItems, automaticOnly: false, dryRun: true, settings: settings)
            )
            WorktreeStorage.passLock.unlock()
            DispatchQueue.main.async {
                switch self.operation {
                case .preparing(let currentToken) where currentToken == token:
                    self.operation = .idle(self.visibleClients.isEmpty ? .empty : .confirmation(prepared))
                case .cancelledPreparation(let currentToken) where currentToken == token:
                    self.operation = .idle(.empty)
                default: return
                }
            }
        }
    }

    func cancelConfirmation() {
        switch operation {
        case .preparing(let token): operation = .cancelledPreparation(token)
        case .idle(.confirmation): operation = .idle(.empty)
        case .scanning(let token, .confirmation): operation = .scanning(token, .empty)
        default: break
        }
    }

    func confirmClean() {
        guard !visibleClients.isEmpty, !isRunning, let preview, !preview.summary.items.isEmpty else { return }
        let token = UUID()
        operation = .cleaning(token)
        queue.async {
            WorktreeStorage.passLock.lock()
            let settings = StorageSettings.read()
            // Reclassify only the confirmed worktrees, retaining the exact path and HEAD allowlist.
            let refreshed = preview.worktrees.removed.isEmpty ? [] : WorktreeStorage.scan(
                repositories: WorktreeStorage.discoverRepositories(candidateDirectories: preview.worktrees.removed.map(\.repoRoot)),
                programaDirectory: settings.directory,
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
            var cacheOutcome = StorageCategories.clean(items: preview.caches.removed, automaticOnly: false, dryRun: false, settings: settings)
            cacheOutcome.kept += preview.caches.kept
            let outcome = StorageCleanPreview(worktrees: worktreeOutcome, caches: cacheOutcome)
            WorktreeStorage.passLock.unlock()
            let capacity = StorageVolumeCapacity.read()
            DispatchQueue.main.async {
                guard case .cleaning(let currentToken) = self.operation, currentToken == token else { return }
                self.operation = .idle(.result(outcome))
                self.capacity = capacity
                self.snapshot = nil
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
        let settings = StorageSettings.read()
        let entries = WorktreeStorage.scanAll(openDirectories: openDirectories, programaDirectory: settings.directory)
        return StorageHubSnapshot(
            scannedAt: Date(), worktrees: entries, caches: StorageCategories.scan(settings: settings),
            worktreePreview: WorktreeStorage.clean(
                entries: entries, policy: manualPolicy, now: Date(), dryRun: true,
                openDirectories: { openDirectories }, processCwds: WorktreeStorage.processWorkingDirectories
            )
        )
    }
}
