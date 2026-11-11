import Darwin
import Foundation
import Bonsplit

/// Called on Ghostty's I/O thread; never perform launchctl work on the UI thread.
enum PaneLaunchdSpawner {
    static var enabled: Bool { ProcessInfo.processInfo.environment["PROGRAMA_PANE_LAUNCHD"] != "0" }
    static var labelPrefix: String {
        "com.darkroom.programa.pane.\(Bundle.main.bundleIdentifier ?? "programa")."
    }

    static func label(surfaceID: UUID) -> String { labelPrefix + surfaceID.uuidString.lowercased() }

    static func spawn(
        userdata: UnsafeMutableRawPointer?,
        argv: UnsafePointer<UnsafePointer<CChar>?>?,
        envp: UnsafePointer<UnsafePointer<CChar>?>?,
        cwd: UnsafePointer<CChar>?,
        tty: UnsafePointer<CChar>?
    ) -> Int64 {
        guard enabled else { return -1 }
        guard !Thread.isMainThread else {
            dilog("pane-launchd", "fallback: spawn callback invoked on main thread")
            return -1
        }
        guard
              let identity = GhosttySurfaceUserdataRegistry.resolve(from: userdata),
              let argv, let envp, let tty,
              let cli = Bundle.main.resourceURL?.appendingPathComponent("bin/programa").path,
              FileManager.default.isExecutableFile(atPath: cli) else {
            dilog("pane-launchd", "fallback: missing spawn context, arguments, tty, or bundled CLI")
            return -1
        }
        let start = DispatchTime.now().uptimeNanoseconds
        var directory: URL?
        var bootstrappedLabel: String?
        var committed = false
        defer {
            let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            dilog("pane-launchd", "surface=\(identity.surfaceId) bootstrap_ms=\(String(format: "%.2f", milliseconds)) outcome=\(committed ? "started" : "fallback")")
            if !committed, let directory { try? FileManager.default.removeItem(at: directory) }
            if !committed {
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 6) { sweepStaleJobs() }
            }
        }
        do {
            let dir = try privateDirectory()
            directory = dir
            let label = label(surfaceID: identity.surfaceId)
            let domain = "gui/\(getuid())"
            let environment = environmentDictionary(envp)
                .merging(["PROGRAMA_PANE_JOB_HANDSHAKE_DIR": dir.path]) { _, new in new }
            var plist: [String: Any] = [
                "Label": label,
                "ProgramArguments": [cli, "__pane-job", String(cString: tty), "--"] + strings(argv),
                "RunAtLoad": true,
                "EnvironmentVariables": environment,
            ]
            plist["WorkingDirectory"] = cwd.map { String(cString: $0) } ?? FileManager.default.currentDirectoryPath
            let plistURL = dir.appendingPathComponent("job.plist")
            try writePrivate(PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0), to: plistURL)
            let status = launchctl(["bootstrap", domain, plistURL.path])
            // Environment values can contain credentials; discard them as soon as bootstrap returns.
            try FileManager.default.removeItem(at: plistURL)
            guard status == 0 else { throw SpawnError.bootstrap(status) }
            bootstrappedLabel = label
            // Each exec of the bundled CLI can take seconds: code-signing checks on first launch,
            // and over a second apiece on a saturated machine. The leader and its child each get 5 s.
            guard let root = waitForPID(at: dir.appendingPathComponent("leader"), timeout: 5) else { throw SpawnError.handshake }
            // The handshake folder is writable by any same-user process, so trust only the pid launchd reports for this job.
            guard launchdPID(label: label, scratch: dir) == root else { throw SpawnError.handshake }
            TerminalController.registerRevivedRoot(root)
            do {
                guard watchExit(pid: root, label: label, directory: dir) else { throw SpawnError.handshake }
                try publishGate(at: dir.appendingPathComponent("prepare"))
                guard waitForPID(at: dir.appendingPathComponent("ready"), timeout: 5) == root else { throw SpawnError.handshake }
                try publishGate(at: dir.appendingPathComponent("go"))
            } catch {
                TerminalController.unregisterRevivedRoot(root)
                throw error
            }
            committed = true
            return Int64(root)
        } catch {
            // No job stage touches the tty before `go`, so removing the job lets Ghostty spawn directly.
            if let directory { try? FileManager.default.removeItem(at: directory) }
            if let bootstrappedLabel { _ = launchctl(["bootout", "gui/\(getuid())/\(bootstrappedLabel)"]) }
            dilog("pane-launchd", "fallback error=\(error) dir=\(directory?.path ?? "none")")
            return -1
        }
    }

    private enum SpawnError: Error { case bootstrap(Int32), handshake, posix(Int32) }

    private static func launchdPID(label: String, scratch: URL) -> pid_t? {
        let output = scratch.appendingPathComponent("job-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: output) }
        guard launchctl(["print", "gui/\(getuid())/\(label)"], output: output) == 0,
              let text = try? String(contentsOf: output, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0] == "pid", let pid = Int32(parts[1]) { return pid }
        }
        return nil
    }

    private static func waitForPID(at url: URL, timeout seconds: UInt64) -> pid_t? {
        let deadline = DispatchTime.now().uptimeNanoseconds + seconds * 1_000_000_000
        repeat {
            if let text = try? String(contentsOf: url, encoding: .utf8),
               let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 { return pid }
            usleep(2_000)
        } while DispatchTime.now().uptimeNanoseconds < deadline
        return nil
    }

    private static func strings(_ values: UnsafePointer<UnsafePointer<CChar>?>) -> [String] {
        var result: [String] = []
        var index = 0
        while let value = values[index] {
            result.append(String(cString: value))
            index += 1
        }
        return result
    }

    static func environmentDictionary(_ envp: UnsafePointer<UnsafePointer<CChar>?>) -> [String: String] {
        var result: [String: String] = [:]
        for entry in strings(envp) {
            guard let separator = entry.firstIndex(of: "=") else { continue }
            result[String(entry[..<separator])] = String(entry[entry.index(after: separator)...])
        }
        return result
    }

    private static func privateDirectory() throws -> URL {
        let parent = NSTemporaryDirectory()
        var template = Array((parent + "programa-pane-job.XXXXXX").utf8CString)
        // Read the name back from `template`, not mkdtemp's return value: that pointer
        // aliases the array, which the optimizer may free once it is no longer used.
        let created = template.withUnsafeMutableBufferPointer { mkdtemp($0.baseAddress!) != nil }
        guard created else { throw SpawnError.posix(errno) }
        let path = String(cString: template)
        guard path.hasPrefix(parent), path.count > parent.count else { throw SpawnError.handshake }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private static func writePrivate(_ data: Data, to url: URL) throws {
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw SpawnError.posix(errno) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try handle.write(contentsOf: data)
        try handle.close()
    }

    private static func publishGate(at url: URL) throws {
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw SpawnError.posix(errno) }
        // The empty gate is complete at open; errors after publication cannot trigger fallback.
        close(fd)
    }

    static func monitorRevivedRoot(_ pid: pid_t, surfaceID: UUID) {
        DispatchQueue.global(qos: .utility).async {
            _ = watchExit(pid: pid, label: label(surfaceID: surfaceID), directory: nil)
        }
    }

    private static func watchExit(pid: pid_t, label: String, directory: URL?) -> Bool {
        let registered = DispatchSemaphore(value: 0)
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global(qos: .utility))
        source.setRegistrationHandler { registered.signal() }
        source.setEventHandler {
            TerminalController.unregisterRevivedRoot(pid)
            source.setEventHandler(handler: nil)
            source.cancel()
            _ = launchctl(["bootout", "gui/\(getuid())/\(label)"])
            if let directory { try? FileManager.default.removeItem(at: directory) }
        }
        source.resume()
        return registered.wait(timeout: .now() + 1) == .success
    }

    static func sweepStaleJobs() {
        guard enabled else { return }
        DispatchQueue.global(qos: .utility).async {
            do {
                let dir = try privateDirectory()
                defer { try? FileManager.default.removeItem(at: dir) }
                let output = dir.appendingPathComponent("jobs")
                guard launchctl(["list"], output: output) == 0,
                      let listing = try? String(contentsOf: output, encoding: .utf8) else { return }
                for line in listing.split(separator: "\n") {
                    let columns = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
                    guard columns.count == 3, columns[0] == "-", columns[2].hasPrefix(labelPrefix) else { continue }
                    _ = launchctl(["bootout", "gui/\(getuid())/\(columns[2])"])
                }
            } catch { dilog("pane-launchd", "sweep error=\(error)") }
        }
    }

    private static func launchctl(_ arguments: [String], output: URL? = nil) -> Int32 {
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { return -1 }
        defer { posix_spawn_file_actions_destroy(&actions) }
        let fd = output.map { Darwin.open($0.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600) }
            ?? Darwin.open("/dev/null", O_WRONLY)
        guard fd >= 0 else { return -1 }
        defer { close(fd) }
        guard posix_spawn_file_actions_adddup2(&actions, fd, STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, fd, STDERR_FILENO) == 0 else { return -1 }
        let storage = (["/bin/launchctl"] + arguments).map { strdup($0) }
        defer { storage.forEach { free($0) } }
        guard storage.allSatisfy({ $0 != nil }) else { return -1 }
        var argv = storage + [nil]
        var pid: pid_t = 0
        let result = argv.withUnsafeMutableBufferPointer {
            posix_spawn(&pid, "/bin/launchctl", &actions, nil, $0.baseAddress!, environ)
        }
        guard result == 0 else { return result }
        var status: Int32 = 0
        let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        while true {
            let waited = waitpid(pid, &status, WNOHANG)
            if waited == pid { return status }
            if waited == -1, errno != EINTR { return -1 }
            if DispatchTime.now().uptimeNanoseconds >= deadline {
                kill(pid, SIGKILL)
                while waitpid(pid, &status, 0) == -1, errno == EINTR {}
                return -1
            }
            usleep(2_000)
        }
    }
}
