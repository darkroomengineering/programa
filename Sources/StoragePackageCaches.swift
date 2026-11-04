import Foundation

enum StoragePackageCaches {
    private struct Cache {
        let manager: String
        let id: String
        let path: String
    }

    private static func caches(_ context: StorageCacheContext) -> [Cache] {
        var result: [Cache] = []
        func add(_ manager: String, _ id: String, _ path: String) {
            guard path.hasPrefix("/"), StorageCacheSupport.directory(path),
                  !WorktreeStorage.isPath(context.home, equalToOrInside: path, caseInsensitive: true),
                  path != "/", path != "/private", path != "/Users", path != "/Library" else { return }
            let components = (path as NSString).pathComponents.map { $0.lowercased() }
            guard components.contains(where: { $0 == "cache" || $0 == "caches" || $0 == "_cacache" || $0 == "store" || $0.hasSuffix("-cache") }),
                  ![context.path(".cache"), context.path("Library/Caches"), "/Library/Caches", "/System/Library/Caches"].contains(path) else { return }
            guard !context.projectDirectories.contains(where: { WorktreeStorage.isPath(path, equalToOrInside: $0, caseInsensitive: true) }) else { return }
            var ancestor = path
            while ancestor != "/" {
                if FileManager.default.fileExists(atPath: (ancestor as NSString).appendingPathComponent(".git")) { return }
                ancestor = (ancestor as NSString).deletingLastPathComponent
            }
            result.append(Cache(manager: manager, id: id, path: path))
        }
        add("bun", "bun", context.environment["BUN_INSTALL_CACHE_DIR"] ?? context.path(".bun/install/cache"))
        var npm = context.path(".npm/_cacache")
        if context.tool("npm") != nil, let output = context.execute("npm", ["config", "get", "cache"]) {
            let root = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if root.hasPrefix("/"), !root.contains("\n") { npm = (root as NSString).appendingPathComponent("_cacache") }
        }
        add("npm", "npm", npm)
        if context.tool("pnpm") != nil, let output = context.execute("pnpm", ["store", "path"]) {
            add("pnpm", "pnpm", output.trimmingCharacters(in: .whitespacesAndNewlines))
        } else if context.tool("pnpm") == nil {
            for path in [context.path("Library/pnpm/store"), context.path(".local/share/pnpm/store")] {
                add("pnpm", "pnpm/" + path, path)
            }
        }
        if context.tool("yarn") != nil, let output = context.execute("yarn", ["cache", "dir"]) {
            add("yarn", "yarn_classic", output.trimmingCharacters(in: .whitespacesAndNewlines))
        } else if context.tool("yarn") == nil {
            for path in [context.path("Library/Caches/Yarn"), context.path(".cache/yarn")] {
                add("yarn", "yarn_classic/" + path, path)
            }
        }
        let berry = context.path(".yarn/berry/cache")
        if context.tool("yarn") == nil {
            add("yarn", "yarn_berry", berry)
        } else if let version = context.execute("yarn", ["--version"]),
                  let major = Int(version.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".").first ?? ""), major >= 2,
                  let global = context.execute("yarn", ["config", "get", "globalFolder"]),
                  (global.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).appendingPathComponent("cache") == berry {
            add("yarn", "yarn_berry", berry)
        }
        return result
    }

    static func blocker(manager: String, context: StorageCacheContext) -> String? {
        guard let processes = context.processes() else { return "install_running" }
        let running = processes.contains { line in
            let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let managerIndex = tokens.firstIndex(where: {
                let name = ($0 as NSString).lastPathComponent.lowercased()
                return name == manager || name == manager + ".js" || name == manager + ".cjs" || name == manager + "-cli.js"
                    || manager == "yarn" && name.hasPrefix("yarn-") && (name.hasSuffix(".cjs") || name.hasSuffix(".js"))
            }) else { return false }
            let arguments = tokens.dropFirst(managerIndex + 1)
            return manager == "yarn" && arguments.allSatisfy { $0.hasPrefix("-") }
                || arguments.contains { ["install", "add", "i", "ci"].contains($0.lowercased()) }
        }
        return running ? "install_running" : nil
    }

    static func scan(_ context: StorageCacheContext, timeout: TimeInterval) -> [StorageCacheItem] {
        caches(context).map { cache in
            let date = StorageCacheSupport.lastUsed(cache.path, timeout: max(timeout, 20))
            return StorageCacheSupport.item(
                id: "packages." + cache.id, category: .packages,
                title: cache.id.hasPrefix("yarn_berry") ? "Yarn Berry" : cache.manager,
                path: cache.path, automatic: cache.manager == "pnpm" && context.tool("pnpm") != nil || StorageCacheSupport.idle(date, now: context.now),
                blocker: blocker(manager: cache.manager, context: context), timeout: timeout, lastUsed: date
            )
        }
    }

    static func remove(_ item: StorageCacheItem, context: StorageCacheContext) -> Bool {
        guard let cache = caches(context).first(where: { "packages." + $0.id == item.id && $0.path == item.path }),
              blocker(manager: cache.manager, context: context) == nil else { return false }
        guard context.tool(cache.manager) != nil else { return StorageCacheSupport.clearContents(cache.path) }
        let arguments: [String]
        switch cache.manager {
        case "bun": arguments = ["pm", "cache", "rm"]
        case "npm": arguments = ["cache", "clean", "--force"]
        case "pnpm": arguments = ["store", "prune"]
        default: arguments = item.id == "packages.yarn_berry" ? ["cache", "clean", "--mirror"] : ["cache", "clean"]
        }
        return context.execute(cache.manager, arguments, timeout: 120) != nil
    }
}
