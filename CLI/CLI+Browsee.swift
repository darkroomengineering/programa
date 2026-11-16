import Foundation
import Darwin

/// browsee, Darkroom's agent browser: where its app, its stdio MCP helper (`browsee-mcp`) and
/// its MCP socket live. Pure so lookups can be tested without the real filesystem.
enum BrowseeApp {
    static let bundleIdentifier = "com.darkroom.browsee"
    static let serverName = "browsee"
    /// The session every agent shares when it is not in a pane. Codex hands stdio servers a
    /// filtered environment without `PROGRAMA_SURFACE_ID`, so all its panes share this one.
    static let sharedSession = "programa"
    /// Kept under Codex's default 10 s MCP startup timeout, so a launch that never finishes
    /// reports this command's error instead of the client's timeout.
    static let launchWait: TimeInterval = 8
    static let socketRelativePath = "Library/Application Support/browsee/mcp.sock"
    /// macOS `sun_path` holds 104 bytes including the terminating NUL.
    static let sunPathBytes = 104

    static func appPath(home: String?, fileExists: (String) -> Bool) -> String? {
        var candidates = ["/Applications/browsee.app"]
        if let home, !home.isEmpty {
            candidates.insert((home as NSString).appendingPathComponent("Applications/browsee.app"), at: 0)
        }
        return candidates.first { fileExists(helperPath(app: $0)) }
    }

    static func helperPath(app: String) -> String {
        (app as NSString).appendingPathComponent("Contents/MacOS/browsee-mcp")
    }

    /// browsee moves a socket whose path does not fit `sun_path` to a hashed name under
    /// `/tmp/browsee-<uid>/`; nil then, and the caller skips the probe.
    // SHORTCUT: no probe for home folders longer than ~50 bytes. ceiling: such a user gets
    // browsee-mcp's own "is browsee running?" error instead of a launch. upgrade: read the
    // fallback path from the link contract once browsee publishes it (H1).
    static func socketPath(home: String) -> String? {
        let path = (home as NSString).appendingPathComponent(socketRelativePath)
        return path.utf8.count < sunPathBytes ? path : nil
    }

    /// `programa-<surface id>` inside a Programa pane, so each pane's agent sees only the tabs
    /// it opened; `sharedSession` elsewhere. browsee accepts 1-128 letters, digits, `-`, `_`, `.`.
    static func session(explicit: String?, environment: [String: String]) -> String {
        if let explicit, !explicit.isEmpty { return explicit }
        guard let surface = environment["PROGRAMA_SURFACE_ID"], !surface.isEmpty else { return sharedSession }
        let candidate = "\(sharedSession)-\(surface)"
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        guard candidate.count <= 128, candidate.unicodeScalars.allSatisfy(allowed.contains) else { return sharedSession }
        return candidate
    }
}

/// The `claude mcp` and `codex mcp` commands that register or remove the `browsee` server.
/// The server runs this CLI's `browsee mcp`, which starts browsee when it is closed and then
/// becomes `browsee-mcp`. Pure so the exact argv can be tested without spawning a process.
struct BrowseeMCPPlan {
    let claudeCommands: [[String]]
    let codexCommands: [[String]]

    static func build(programaCLI: String, claudeExecutable: String?, codexExecutable: String?, install: Bool) -> BrowseeMCPPlan {
        let name = BrowseeApp.serverName
        let server = [programaCLI, "browsee", "mcp"]
        var claudeCommands: [[String]] = []
        var codexCommands: [[String]] = []
        if let claude = claudeExecutable {
            claudeCommands.append(install
                ? [claude, "mcp", "add", "--scope", "user", "--transport", "stdio", name, "--"] + server
                : [claude, "mcp", "remove", "--scope", "user", name])
        }
        if let codex = codexExecutable {
            codexCommands.append(install
                ? [codex, "mcp", "add", name, "--"] + server + ["--session", BrowseeApp.sharedSession]
                : [codex, "mcp", "remove", name])
        }
        return BrowseeMCPPlan(claudeCommands: claudeCommands, codexCommands: codexCommands)
    }
}

extension ProgramaCLI {
    private var browseeHome: String { Self.integrationExpandTilde("~") }

    private func browseeAppPath() -> String? {
        BrowseeApp.appPath(home: browseeHome) { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Whether browsee's MCP socket accepts a connection, which is what "running" means. The
    /// probe closes without a session header; browsee drops such a connection.
    private func browseeSocketAccepts(_ path: String) -> Bool {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return false }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
    }

    /// `open -g -b`: LaunchServices starts browsee in the background without raising a window.
    private func launchBrowseeInBackground() throws {
        let opener: String = {
            #if DEBUG
            // Tests replace the opener so they never start a real browsee. Release builds ignore it.
            if let fake = ProcessInfo.processInfo.environment["PROGRAMA_BROWSEE_OPEN_FOR_TESTING"], !fake.isEmpty {
                return fake
            }
            #endif
            return "/usr/bin/open"
        }()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: opener)
        process.arguments = ["-g", "-b", BrowseeApp.bundleIdentifier]
        // stdout is the MCP channel of the agent that started this command; keep it clean.
        process.standardOutput = FileHandle.standardError
        process.standardError = FileHandle.standardError
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CLIError(message: "Could not start browsee: open exited with status \(process.terminationStatus).")
        }
    }

    /// Becomes `browsee-mcp --session <id>` with this process's stdio. Starts browsee in the
    /// background first when its socket does not answer. Writes nothing to stdout.
    private func runBrowseeMCPServer(explicitSession: String?) throws {
        guard let app = browseeAppPath() else {
            throw CLIError(message: "browsee is not installed: no browsee.app in ~/Applications or /Applications.")
        }
        if let socketPath = BrowseeApp.socketPath(home: browseeHome), !browseeSocketAccepts(socketPath) {
            try launchBrowseeInBackground()
            let deadline = Date().addingTimeInterval(BrowseeApp.launchWait)
            var running = false
            while !running, Date() < deadline {
                usleep(200_000)
                running = browseeSocketAccepts(socketPath)
            }
            guard running else {
                throw CLIError(message: "browsee did not start within \(Int(BrowseeApp.launchWait)) seconds. Open browsee, then restart this agent.")
            }
        }
        let helper = BrowseeApp.helperPath(app: app)
        let session = BrowseeApp.session(explicit: explicitSession, environment: ProcessInfo.processInfo.environment)
        // main() ignores SIGPIPE, and an ignored signal stays ignored across exec.
        signal(SIGPIPE, SIG_DFL)
        let argv = [helper, "--session", session].map { strdup($0) } + [nil]
        execv(helper, argv)
        let reason = String(cString: strerror(errno))
        argv.forEach { free($0) }
        throw CLIError(message: "Could not run \(helper): \(reason)")
    }

    private func browseeIsRegistered(executable: String) -> Bool {
        let result = CLIProcessRunner.runProcess(
            executablePath: executable,
            arguments: ["mcp", "get", BrowseeApp.serverName],
            timeout: 30
        )
        return result.status == 0
    }

    private func browseePrintClientStatus(_ client: String, executable: String?) {
        guard let executable else { return print("\(client): not found") }
        let registered = browseeIsRegistered(executable: executable)
        print("\(client): \(executable): browsee \(registered ? "registered" : "not registered")")
    }

    func runBrowsee(arguments: [String]) throws {
        let subcommand = arguments.first?.lowercased() ?? "help"
        let skipConfirm = arguments.contains("--yes") || arguments.contains("-y")
        let searchPath = ProcessInfo.processInfo.environment["PATH"]

        switch subcommand {
        case "mcp":
            try runBrowseeMCPServer(explicitSession: optionValue(arguments, name: "--session"))

        case "status":
            let app = browseeAppPath()
            print("browsee: \(app ?? "not found, install browsee.app in /Applications")")
            if let socketPath = BrowseeApp.socketPath(home: browseeHome) {
                print("Running: \(browseeSocketAccepts(socketPath) ? "yes" : "no") (\(socketPath))")
            }
            browseePrintClientStatus("Claude Code", executable: resolveClaudeExecutable(searchPath: searchPath))
            browseePrintClientStatus("Codex", executable: resolveCodexExecutable(searchPath: searchPath))
            print("Agents reach browsee only while \"Let other apps control my tabs\" is on in browsee > Settings > Agents.")

        case "install-mcp", "uninstall-mcp":
            let install = subcommand == "install-mcp"
            // Removal only needs the client CLIs; browsee may already be gone.
            if install, browseeAppPath() == nil {
                throw CLIError(message: "browsee not found. Install browsee.app in /Applications, then re-run this command.")
            }
            guard let programaCLI = resolvedExecutableURL()?.path else {
                throw CLIError(message: "Could not resolve the path of this programa CLI.")
            }
            let claudeExecutable = resolveClaudeExecutable(searchPath: searchPath)
            let codexExecutable = resolveCodexExecutable(searchPath: searchPath)
            if claudeExecutable == nil { print("Claude Code: not found, skipping") }
            if codexExecutable == nil { print("Codex: not found, skipping") }
            guard claudeExecutable != nil || codexExecutable != nil else {
                throw CLIError(message: "Neither Claude Code nor Codex CLI was found on PATH.")
            }
            let plan = BrowseeMCPPlan.build(
                programaCLI: programaCLI,
                claudeExecutable: claudeExecutable,
                codexExecutable: codexExecutable,
                install: install
            )
            let pending = plan.claudeCommands.map { (client: "Claude Code", command: $0) }
                + plan.codexCommands.map { (client: "Codex", command: $0) }

            print("")
            print("The following commands will run:")
            for entry in pending {
                print("  \(entry.command.joined(separator: " "))")
            }
            if !skipConfirm {
                print("Apply these changes? [Y/n] ", terminator: "")
                // EOF (closed or non-interactive stdin) counts as "no": never fail open.
                guard let response = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
                    print("")
                    print("Aborted (no confirmation on stdin; pass --yes to skip the prompt).")
                    return
                }
                if !response.isEmpty && response != "y" && response != "yes" {
                    print("Aborted.")
                    return
                }
            }

            var failures: [String] = []
            for entry in pending {
                guard let executable = entry.command.first else { continue }
                let registered = browseeIsRegistered(executable: executable)
                if install == registered {
                    print("\(entry.client): browsee \(registered ? "already registered" : "not registered"), skipping")
                    continue
                }
                print("Running: \(entry.command.joined(separator: " "))")
                let result = CLIProcessRunner.runProcess(
                    executablePath: executable,
                    arguments: Array(entry.command.dropFirst()),
                    timeout: 60
                )
                if result.status != 0 {
                    // Keep going so one client's failure never leaves the other untouched.
                    let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    failures.append("\(entry.client): exit \(result.status)\(detail.isEmpty ? "" : ": \(detail)")")
                }
            }
            print("")
            guard failures.isEmpty else {
                throw CLIError(message: (install ? "Some registrations failed:\n  " : "Some removals failed:\n  ") + failures.joined(separator: "\n  "))
            }
            if install {
                print("Installed. Turn on \"Let other apps control my tabs\" in browsee > Settings > Agents, then start a new agent.")
            } else {
                print("Removed.")
            }

        default:
            print("Usage: programa browsee <status|install-mcp|uninstall-mcp|mcp> [--session ID] [--yes]")
            throw CLIError(message: "Unknown browsee subcommand: \(subcommand)")
        }
    }
}
