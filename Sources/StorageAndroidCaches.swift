import Foundation

enum StorageAndroidCaches {
    private static func blocker(_ context: StorageCacheContext) -> String? {
        guard let processes = context.processes() else { return "gradle_running" }
        return processes.contains { line in
            let lower = line.lowercased()
            return lower.contains("gradle") || lower.contains("android studio")
        } ? "gradle_running" : nil
    }

    static func scan(_ context: StorageCacheContext, timeout: TimeInterval) -> [StorageCacheItem] {
        let blocked = blocker(context)
        var items: [StorageCacheItem] = []
        let gradle = context.environment["GRADLE_USER_HOME"] ?? context.path(".gradle")
        let caches = (gradle as NSString).appendingPathComponent("caches")
        for path in StorageCacheSupport.children(caches) {
            let name = (path as NSString).lastPathComponent
            let eligible = name.hasPrefix("build-cache-") || name.hasPrefix("transforms-")
            guard eligible else { continue }
            let date = StorageCacheSupport.lastUsed(path, timeout: max(timeout, 20))
            items.append(StorageCacheSupport.item(
                id: "android.gradle_cache/" + name, category: .android, title: "Gradle: " + name,
                path: path, automatic: eligible && StorageCacheSupport.idle(date, now: context.now),
                blocker: blocked, timeout: timeout, lastUsed: date
            ))
        }
        if let names = try? FileManager.default.contentsOfDirectory(atPath: caches),
           names.contains(where: { !$0.hasPrefix("build-cache-") && !$0.hasPrefix("transforms-") }),
           StorageCacheSupport.directory(caches) {
            let size = timeout > 0 ? sizeOfRest(caches, timeout: timeout) : (bytes: Int64(0), partial: true)
            items.append(StorageCacheItem(
                id: "android.gradle_cache/rest", category: .android,
                title: String(localized: "storage.cache.gradleOther", defaultValue: "Other Gradle caches"),
                path: caches, sizeBytes: size.bytes, sizePartial: size.partial,
                lastUsed: StorageCacheSupport.modified(caches), autoCleanable: false, blocker: blocked
            ))
        }
        let distributions = StorageCacheSupport.children((gradle as NSString).appendingPathComponent("wrapper/dists"))
            .sorted(by: StorageCacheSupport.versionOrder)
        for path in distributions.dropLast() {
            items.append(StorageCacheSupport.item(
                id: "android.gradle_dist/" + (path as NSString).lastPathComponent, category: .android,
                title: "Gradle: " + (path as NSString).lastPathComponent, path: path,
                automatic: false, blocker: blocked, timeout: timeout
            ))
        }
        items += projectBuilds(context, timeout: timeout, blocker: blocked)
        items += systemImages(context, timeout: timeout, blocker: blocked)
        return items
    }

    private static func projectBuilds(_ context: StorageCacheContext, timeout: TimeInterval, blocker: String?) -> [StorageCacheItem] {
        var items: [StorageCacheItem] = []
        var seen = Set<String>()
        for root in context.projectDirectories where StorageCacheSupport.directory(root) {
            guard let enumerator = FileManager.default.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { continue }
            let deadline = ProcessInfo.processInfo.systemUptime + max(20, timeout)
            while let url = enumerator.nextObject() as? URL {
                if ProcessInfo.processInfo.systemUptime >= deadline { break }
                let name = url.lastPathComponent
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values?.isSymbolicLink == true || ["node_modules", "build"].contains(name) {
                    enumerator.skipDescendants()
                    continue
                }
                guard name == "build.gradle" || name == "build.gradle.kts" else { continue }
                let path = url.deletingLastPathComponent().appendingPathComponent("build").path
                guard seen.insert(path).inserted, StorageCacheSupport.directory(path),
                      safeBuild(path, context: context) else { continue }
                items.append(StorageCacheSupport.item(
                    id: "android.project_build/" + path, category: .android,
                    title: String(localized: "storage.cache.androidBuild", defaultValue: "Android build output") + ": " + url.deletingLastPathComponent().lastPathComponent,
                    path: path, automatic: false, blocker: blocker, timeout: timeout
                ))
            }
        }
        return items
    }

    private static func safeBuild(_ path: String, context: StorageCacheContext) -> Bool {
        guard let tracked = context.execute("git", ["ls-files", "-z", "--", path], directory: (path as NSString).deletingLastPathComponent),
              tracked.isEmpty else { return false }
        var failed = false
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.isSymbolicLinkKey],
            errorHandler: { _, _ in failed = true; return false }
        ) else { return false }
        let deadline = ProcessInfo.processInfo.systemUptime + 20
        while let url = enumerator.nextObject() as? URL {
            if ProcessInfo.processInfo.systemUptime >= deadline || url.lastPathComponent.hasPrefix(".env") || url.lastPathComponent == ".git" { return false }
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true { enumerator.skipDescendants() }
        }
        return !failed
    }

    private static func systemImages(_ context: StorageCacheContext, timeout: TimeInterval, blocker: String?) -> [StorageCacheItem] {
        let sdk = context.environment["ANDROID_HOME"] ?? context.environment["ANDROID_SDK_ROOT"] ?? context.path("Library/Android/sdk")
        let avdRoot = context.environment["ANDROID_AVD_HOME"] ?? context.path(".android/avd")
        var references = Set<String>()
        // An unreadable AVD config means its image reference is unknown: retain every image.
        let avdNames: [String]
        if FileManager.default.fileExists(atPath: avdRoot) {
            guard StorageCacheSupport.directory(avdRoot), let names = try? FileManager.default.contentsOfDirectory(atPath: avdRoot) else { return [] }
            avdNames = names
        } else { avdNames = [] }
        var avds = Set(avdNames.filter { $0.hasSuffix(".avd") }.map { (avdRoot as NSString).appendingPathComponent($0) })
        for name in avdNames where name.hasSuffix(".ini") {
            guard let registration = try? String(contentsOfFile: (avdRoot as NSString).appendingPathComponent(name), encoding: .utf8) else { return [] }
            var absolute: String?
            var relative: String?
            for line in registration.split(whereSeparator: \.isNewline) {
                let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2, !parts[1].isEmpty else { continue }
                if parts[0] == "path", parts[1].hasPrefix("/") { absolute = parts[1] }
                if parts[0] == "path.rel", !parts[1].hasPrefix("/") { relative = parts[1] }
            }
            guard let avd = absolute ?? relative.map({ ((avdRoot as NSString).deletingLastPathComponent as NSString).appendingPathComponent($0) }) else { return [] }
            avds.insert(avd)
        }
        for avd in avds {
            guard StorageCacheSupport.directory(avd) else { return [] }
            guard let config = try? String(contentsOfFile: (avd as NSString).appendingPathComponent("config.ini"), encoding: .utf8) else { return [] }
            var found = false
            for line in config.split(whereSeparator: \.isNewline) {
                let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2, parts[0] == "image.sysdir.1", !parts[1].isEmpty else { continue }
                let raw = parts[1].hasPrefix("/") ? parts[1] : (sdk as NSString).appendingPathComponent(parts[1])
                references.insert(WorktreeStorage.resolvedPath(raw)); found = true
            }
            if !found { return [] }
        }
        let root = (sdk as NSString).appendingPathComponent("system-images")
        return StorageCacheSupport.children(root).flatMap(StorageCacheSupport.children).flatMap(StorageCacheSupport.children)
            .filter { !references.contains(WorktreeStorage.resolvedPath($0)) }
            .map { path in
                StorageCacheSupport.item(
                    id: "android.system_image/" + path, category: .android,
                    title: String(localized: "storage.cache.androidImage", defaultValue: "Android system image") + ": " + path.replacingOccurrences(of: root + "/", with: ""),
                    path: path, automatic: false, blocker: blocker, timeout: timeout
                )
            }
    }

    static func remove(_ item: StorageCacheItem, context: StorageCacheContext) -> Bool {
        guard blocker(context) == nil else { return false }
        if item.id.hasPrefix("android.project_build/"), let path = item.path, !safeBuild(path, context: context) { return false }
        if item.id.hasPrefix("android.system_image/"), !systemImages(context, timeout: 0, blocker: nil).contains(where: { $0.id == item.id && $0.path == item.path }) { return false }
        if item.id == "android.gradle_cache/rest" {
            guard let path = item.path, StorageCacheSupport.directory(path),
                  let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return false }
            do {
                for name in names where !name.hasPrefix("build-cache-") && !name.hasPrefix("transforms-") {
                    try FileManager.default.removeItem(atPath: (path as NSString).appendingPathComponent(name))
                }
                return true
            } catch { return false }
        }
        return StorageCacheSupport.remove(item.path)
    }

    static func sizeOfRest(_ path: String, timeout: TimeInterval) -> (bytes: Int64, partial: Bool) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return (0, true) }
        var bytes: Int64 = 0
        var partial = false
        for name in names where !name.hasPrefix("build-cache-") && !name.hasPrefix("transforms-") {
            let child = (path as NSString).appendingPathComponent(name)
            if StorageCacheSupport.directory(child) {
                let size = WorktreeStorage.directorySize(atPath: child, timeout: timeout)
                bytes += size.bytes; partial = partial || size.partial
            } else if let values = try? URL(fileURLWithPath: child).resourceValues(forKeys: [.isSymbolicLinkKey, .totalFileAllocatedSizeKey]), values.isSymbolicLink != true {
                bytes += Int64(values.totalFileAllocatedSize ?? 0)
            } else { partial = true }
        }
        return (bytes, partial)
    }
}
