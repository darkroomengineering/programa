import Foundation

struct StorageCacheContext {
    var home: String
    var environment: [String: String]
    var processes: () -> [String]?
    var command: (String, [String], String, TimeInterval) -> String?
    var tools: [String: String]?
    var projectDirectories: [String]
    var now: Date

    init(
        home: String = FileManager.default.homeDirectoryForCurrentUser.path,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        processes: @escaping () -> [String]? = StorageCacheContext.runningProcesses,
        command: @escaping (String, [String], String, TimeInterval) -> String? = StorageCacheContext.run,
        tools: [String: String]? = nil, projectDirectories: [String] = [], now: Date = Date()
    ) {
        self.home = WorktreeStorage.resolvedPath(home)
        self.environment = environment
        self.processes = processes
        self.command = command
        self.tools = tools
        self.projectDirectories = projectDirectories
        self.now = now
    }

    static func live(settings: StorageSettings = .read()) -> Self {
        let directories: [String]
        if Thread.isMainThread {
            directories = MainActor.assumeIsolated { WorktreeStorage.openWorkspaceDirectories() }
        } else {
            directories = DispatchQueue.main.sync { WorktreeStorage.openWorkspaceDirectories() }
        }
        let candidates = directories + WorktreeStorage.programaWorktreeCandidates(in: settings.directory)
        let projects = WorktreeStorage.discoverRepositories(candidateDirectories: candidates)
            .flatMap { $0.worktrees.filter { !$0.isBare }.map(\.path) }
        var environment = ProcessInfo.processInfo.environment
        if let loginShellPATH { environment["PATH"] = loginShellPATH }
        return Self(environment: environment, command: liveCommand(environment: environment), projectDirectories: projects)
    }

    /// Resolved once per app run: a login shell runs the user's rc files, which can take seconds.
    private static let loginShellPATH: String? = {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard let path = run(shell, ["-l", "-c", "printf '%s' \"$PATH\""], "/", 5), !path.isEmpty, !path.contains("\n") else {
            return nil
        }
        return path
    }()

    /// Project directories come from terminal-reported paths, so git runs with the automatic
    /// hardening (`CanonicalSubprocessRunner.runAutomaticGit`). Git gets no environment
    /// overrides: they would be layered over, and could undo, its hardening environment.
    static func liveCommand(environment: [String: String]) -> (String, [String], String, TimeInterval) -> String? {
        { executable, arguments, directory, timeout in
            let stdoutLimit = 4 * 1024 * 1024
            let stderrLimit = 128 * 1024
            let result = (executable as NSString).lastPathComponent == "git"
                ? CanonicalSubprocessRunner.runAutomaticGit(
                    arguments: arguments, currentDirectory: directory, timeout: timeout,
                    stdoutLimit: stdoutLimit, stderrLimit: stderrLimit,
                    executableURL: executable.contains("/") ? URL(fileURLWithPath: executable) : nil
                )
                : CanonicalSubprocessRunner.run(
                    executable: executable, arguments: arguments, currentDirectory: directory,
                    timeout: timeout, stdoutLimit: stdoutLimit, stderrLimit: stderrLimit,
                    environmentOverrides: environment
                )
            return result.outcome == .exited && result.exitStatus == 0 ? result.stdout : nil
        }
    }

    func at(_ date: Date) -> Self { var copy = self; copy.now = date; return copy }
    func path(_ suffix: String) -> String { (home as NSString).appendingPathComponent(suffix) }
    func tool(_ name: String) -> String? {
        if let tools { return tools[name] }
        return CanonicalSubprocessRunner.resolvedExecutableURL(for: name, environment: environment)?.path
    }
    func execute(_ name: String, _ arguments: [String], directory: String? = nil, timeout: TimeInterval = 30) -> String? {
        command(tool(name) ?? name, arguments, directory ?? home, timeout)
    }
    static func run(_ executable: String, _ arguments: [String], _ directory: String, _ timeout: TimeInterval) -> String? {
        let result = CanonicalSubprocessRunner.run(
            executable: executable, arguments: arguments, currentDirectory: directory,
            timeout: timeout, stdoutLimit: 4 * 1024 * 1024, stderrLimit: 128 * 1024
        )
        return result.outcome == .exited && result.exitStatus == 0 ? result.stdout : nil
    }
    static func runningProcesses() -> [String]? {
        run("/bin/ps", ["-axww", "-o", "command="], "/", 10)?.split(whereSeparator: \.isNewline).map(String.init)
    }
}

enum StorageCacheSupport {
    static let idleInterval: TimeInterval = 14 * 24 * 3600

    static func directory(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true, values.isSymbolicLink != true else { return false }
        // Ancestor symlinks can redirect otherwise safe-looking cache paths into user data.
        return lexicalPath(path) == WorktreeStorage.resolvedPath(path)
    }
    /// Removes "." and ".." without touching symlinks. Foundation's standardizing rewrites
    /// /private/var to /var, which would never equal the realpath.
    static func lexicalPath(_ path: String) -> String {
        var components: [Substring] = []
        for component in path.split(separator: "/") {
            if component == "." { continue }
            if component == ".." { _ = components.popLast(); continue }
            components.append(component)
        }
        return "/" + components.joined(separator: "/")
    }
    static func children(_ path: String) -> [String] {
        guard directory(path) else { return [] }
        return ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).sorted()
            .map { (path as NSString).appendingPathComponent($0) }.filter(directory)
    }
    static func modified(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }
    static func lastUsed(_ path: String, timeout: TimeInterval) -> Date? {
        guard let rootDate = modified(path) else { return nil }
        var latest = rootDate
        var failed = false
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.contentModificationDateKey, .isSymbolicLinkKey],
            errorHandler: { _, _ in failed = true; return false }
        ) else { return nil }
        let deadline = ProcessInfo.processInfo.systemUptime + max(0.1, timeout)
        while let url = enumerator.nextObject() as? URL {
            guard ProcessInfo.processInfo.systemUptime < deadline,
                  let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isSymbolicLinkKey]) else { return nil }
            if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            guard let date = values.contentModificationDate else { return nil }
            latest = max(latest, date)
        }
        return failed ? nil : latest
    }
    static func idle(_ date: Date?, now: Date) -> Bool {
        date.map { now.timeIntervalSince($0) >= idleInterval } ?? false
    }
    static func item(
        id: String, category: StorageCategoryID, title: String, path: String,
        automatic: Bool, blocker: String?, timeout: TimeInterval, lastUsed: Date? = nil,
        removal: StorageCacheRemoval = .directory
    ) -> StorageCacheItem {
        let size = timeout > 0 ? WorktreeStorage.directorySize(atPath: path, timeout: timeout) : (bytes: Int64(0), partial: true)
        return StorageCacheItem(id: id, category: category, title: title, path: path,
                                sizeBytes: size.bytes, sizePartial: size.partial,
                                lastUsed: lastUsed ?? modified(path), autoCleanable: automatic, blocker: blocker,
                                removal: removal)
    }
    static func remove(_ path: String?) -> Bool {
        guard let path, directory(path) else { return false }
        do { try FileManager.default.removeItem(atPath: path); return true } catch { return false }
    }
    static func clearContents(_ path: String) -> Bool {
        guard directory(path), let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return false }
        do {
            for name in names { try FileManager.default.removeItem(atPath: (path as NSString).appendingPathComponent(name)) }
            return true
        } catch { return false }
    }
    static func versionOrder(_ lhs: String, _ rhs: String) -> Bool {
        (lhs as NSString).lastPathComponent.compare((rhs as NSString).lastPathComponent, options: .numeric) == .orderedAscending
    }
}
