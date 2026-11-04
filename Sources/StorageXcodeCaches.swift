import Foundation

enum StorageXcodeCaches {
    private struct Device: Decodable {
        let udid: String
        let isAvailable: Bool?
        let state: String?
    }
    private struct Devices: Decodable { let devices: [String: [Device]] }

    private static func devices(_ context: StorageCacheContext, unavailable: Bool) -> [Device]? {
        let arguments = ["simctl", "list", "devices"] + (unavailable ? ["unavailable"] : []) + ["-j"]
        guard let output = context.execute("xcrun", arguments), let data = output.data(using: .utf8),
              let response = try? JSONDecoder().decode(Devices.self, from: data) else { return nil }
        return response.devices.values.flatMap { $0 }
    }

    private static func running(_ context: StorageCacheContext) -> Bool {
        guard let processes = context.processes() else { return true }
        return processes.contains { line in
            line.lowercased().split(whereSeparator: \.isWhitespace).contains { token in
                token.hasSuffix("/xcode") || token == "xcode" || token.hasSuffix("/xcodebuild") || token == "xcodebuild"
            }
        }
    }

    static func scan(_ context: StorageCacheContext, timeout: TimeInterval) -> [StorageCacheItem] {
        let blocker: String? = running(context) ? "xcode_running" : nil
        var items: [StorageCacheItem] = []
        for path in StorageCacheSupport.children(context.path("Library/Developer/Xcode/DerivedData")) {
            let name = (path as NSString).lastPathComponent
            guard let separator = name.lastIndex(of: "-"), separator != name.startIndex,
                  name.index(after: separator) != name.endIndex else { continue }
            let date = StorageCacheSupport.lastUsed(path, timeout: max(timeout, 20)).map { activity in
                [activity, StorageCacheSupport.modified(path), StorageCacheSupport.modified((path as NSString).appendingPathComponent("info.plist"))].compactMap { $0 }.max() ?? activity
            }
            items.append(StorageCacheSupport.item(
                id: "xcode.derived_data/" + (path as NSString).lastPathComponent, category: .xcode,
                title: String(localized: "storage.cache.derivedData", defaultValue: "Derived Data") + ": " + (path as NSString).lastPathComponent,
                path: path, automatic: StorageCacheSupport.idle(date, now: context.now), blocker: blocker,
                timeout: timeout, lastUsed: date
            ))
        }
        let all = devices(context, unavailable: false)
        let simulatorBlocker = blocker ?? (all == nil || all!.contains { $0.state == "Booted" } ? "xcode_running" : nil)
        let caches = context.path("Library/Developer/CoreSimulator/Caches")
        if StorageCacheSupport.directory(caches) {
            items.append(StorageCacheSupport.item(
                id: "xcode.simulator_caches", category: .xcode,
                title: String(localized: "storage.cache.simulatorCaches", defaultValue: "Simulator caches"),
                path: caches, automatic: true, blocker: simulatorBlocker, timeout: timeout
            ))
        }
        if let unavailable = devices(context, unavailable: true) {
            let paths = unavailable.filter { $0.isAvailable == false && UUID(uuidString: $0.udid) != nil }
                .map { context.path("Library/Developer/CoreSimulator/Devices/" + $0.udid) }
                .filter(StorageCacheSupport.directory)
            if !paths.isEmpty {
                let sizes = paths.map { timeout > 0 ? WorktreeStorage.directorySize(atPath: $0, timeout: timeout) : (bytes: Int64(0), partial: true) }
                items.append(StorageCacheItem(
                    id: "xcode.unavailable_simulators", category: .xcode,
                    title: String(localized: "storage.cache.unavailableSimulators", defaultValue: "Unavailable simulators"),
                    path: nil, sizeBytes: sizes.reduce(0) { $0 + $1.bytes }, sizePartial: sizes.contains { $0.partial },
                    lastUsed: paths.compactMap(StorageCacheSupport.modified).max(), autoCleanable: true, blocker: simulatorBlocker
                ))
            }
        }
        for platform in ["iOS", "watchOS", "tvOS", "visionOS"] {
            let versions = StorageCacheSupport.children(context.path("Library/Developer/Xcode/\(platform) DeviceSupport"))
                .sorted(by: StorageCacheSupport.versionOrder)
            for path in versions.dropLast() {
                items.append(StorageCacheSupport.item(
                    id: "xcode.device_support/\(platform)/" + (path as NSString).lastPathComponent,
                    category: .xcode, title: platform + " " + (path as NSString).lastPathComponent,
                    path: path, automatic: false, blocker: blocker, timeout: timeout
                ))
            }
        }
        return items
    }

    static func remove(_ item: StorageCacheItem, context: StorageCacheContext) -> Bool {
        guard !running(context) else { return false }
        if item.id == "xcode.unavailable_simulators" || item.id == "xcode.simulator_caches" {
            guard let all = devices(context, unavailable: false), !all.contains(where: { $0.state == "Booted" }) else { return false }
        }
        if item.id == "xcode.unavailable_simulators" {
            // simctl always targets the real user device set; injected homes must never invoke it.
            guard context.home == WorktreeStorage.resolvedPath(FileManager.default.homeDirectoryForCurrentUser.path) else { return false }
            return context.execute("xcrun", ["simctl", "delete", "unavailable"], timeout: 120) != nil
        }
        return StorageCacheSupport.remove(item.path)
    }
}
