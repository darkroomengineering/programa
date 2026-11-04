import Foundation

struct StorageVolumeCapacity: Equatable, Sendable {
    let availableBytes: Int64
    let totalBytes: Int64

    static func read() -> StorageVolumeCapacity? {
        guard let values = try? FileManager.default.homeDirectoryForCurrentUser.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]
        ), let available = values.volumeAvailableCapacityForImportantUsage,
           let total = values.volumeTotalCapacity else { return nil }
        return StorageVolumeCapacity(availableBytes: available, totalBytes: Int64(total))
    }
}

struct StorageLowDiskWarningState {
    private(set) var isArmed = true

    mutating func check(availableBytes: Int64, thresholdGB: Double, notify: () -> Void) {
        guard thresholdGB.isFinite, thresholdGB > 0, availableBytes >= 0 else { return }
        let freeGB = Double(availableBytes) / 1_000_000_000
        if freeGB > thresholdGB + 5 {
            isArmed = true
        } else if freeGB < thresholdGB, isArmed {
            isArmed = false
            notify()
        }
    }
}

final class StorageLowDiskMonitor: @unchecked Sendable {
    static let shared = StorageLowDiskMonitor()
    static let notificationDestinationKey = "programaDestination"
    static let notificationDestination = "storage"
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var state = StorageLowDiskWarningState()

    private init() {}

    @MainActor
    func start(notify: @escaping @Sendable (StorageVolumeCapacity) -> Void) {
        guard !AppDelegate.detectRunningUnderXCTest(ProcessInfo.processInfo.environment) else { return }
        lock.lock()
        defer { lock.unlock() }
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "programa.storage.free-space", qos: .utility))
        timer.schedule(deadline: .now() + 60, repeating: 15 * 60, leeway: .seconds(60))
        timer.setEventHandler { [weak self] in
            guard let self, let capacity = StorageVolumeCapacity.read() else { return }
            self.state.check(availableBytes: capacity.availableBytes, thresholdGB: ProgramaStorageSettings.lowDiskWarningGB()) {
                notify(capacity)
            }
        }
        timer.resume()
        self.timer = timer
    }
}
