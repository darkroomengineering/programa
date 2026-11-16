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

    /// The sockets whose answer means browsee runs. A socket path that does not fit `sun_path`
    /// moves to a hashed name in browsee's fallback folder, `/tmp/browsee-<uid>/` (`socket_path`
    /// in browsee-mcp). Only browsee's MCP sockets live there, so any socket in it counts.
    static func probePaths(home: String, fallbackFolder: String, listFolder: (String) -> [String]) -> [String] {
        let natural = (home as NSString).appendingPathComponent(socketRelativePath)
        if natural.utf8.count < sunPathBytes { return [natural] }
        return listFolder(fallbackFolder)
            .filter { $0.hasSuffix(".sock") }
            .sorted()
            .map { (fallbackFolder as NSString).appendingPathComponent($0) }
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

/// A `browsee` server as Claude Code or Codex has it registered.
struct BrowseeRegistration: Equatable {
    let command: String
    let args: [String]
    /// The entry sets environment variables of its own; ours sets none.
    let hasEnvironment: Bool

    init(command: String, args: [String], hasEnvironment: Bool = false) {
        self.command = command
        self.args = args
        self.hasEnvironment = hasEnvironment
    }

    /// Claude Code's `mcpServers.browsee` entry or Codex's `transport`. An HTTP server has no command.
    init(entry: [String: Any]) {
        command = entry["command"] as? String ?? ""
        args = entry["args"] as? [String] ?? []
        hasEnvironment = ["env", "env_vars"].contains { key in
            switch entry[key] {
            case let list as [Any]: return !list.isEmpty
            case let map as [String: Any]: return !map.isEmpty
            default: return false
            }
        }
    }

    var shown: String {
        guard !command.isEmpty else { return "a non-stdio server" }
        return ([command] + args).joined(separator: " ") + (hasEnvironment ? " (with its own environment)" : "")
    }
}

enum BrowseeClient: String {
    case claude = "Claude Code"
    case codex = "Codex"
}

/// What `install-mcp` or `uninstall-mcp` does for one client: the commands to run in order, and
/// the line the preview shows. The server runs this CLI's `browsee mcp`, which starts browsee
/// when it is closed and then becomes `browsee-mcp`. Pure so the decision table and the exact
/// argv can be tested without spawning a process.
struct BrowseeMCPStep: Equatable {
    let commands: [[String]]
    let summary: String

    static func desired(_ client: BrowseeClient, programaCLI: String) -> BrowseeRegistration {
        let args = ["browsee", "mcp"] + (client == .codex ? ["--session", BrowseeApp.sharedSession] : [])
        return BrowseeRegistration(command: programaCLI, args: args)
    }

    /// An entry that runs anything else, an older Programa included, is replaced: removed, then
    /// added again, because `claude mcp add` refuses a name that exists.
    static func build(
        _ client: BrowseeClient,
        executable: String,
        programaCLI: String,
        existing: BrowseeRegistration?,
        install: Bool
    ) -> BrowseeMCPStep {
        let name = BrowseeApp.serverName
        let remove = client == .claude
            ? [executable, "mcp", "remove", "--scope", "user", name]
            : [executable, "mcp", "remove", name]
        guard install else {
            guard let existing else { return BrowseeMCPStep(commands: [], summary: "browsee not registered, skipping") }
            return BrowseeMCPStep(commands: [remove], summary: "remove browsee: \(existing.shown)")
        }
        let wanted = desired(client, programaCLI: programaCLI)
        let server = [wanted.command] + wanted.args
        let add = client == .claude
            ? [executable, "mcp", "add", "--scope", "user", "--transport", "stdio", name, "--"] + server
            : [executable, "mcp", "add", name, "--"] + server
        guard let existing else { return BrowseeMCPStep(commands: [add], summary: "add browsee: \(wanted.shown)") }
        if existing == wanted { return BrowseeMCPStep(commands: [], summary: "browsee already registered, skipping") }
        return BrowseeMCPStep(commands: [remove, add], summary: "replace browsee: \(existing.shown) -> \(wanted.shown)")
    }
}

extension ProgramaCLI {
    private var browseeHome: String { Self.integrationExpandTilde("~") }

    private var browseeFallbackFolder: String {
        #if DEBUG
        // Tests keep their sockets out of the real fallback folder. Release builds ignore it.
        if let folder = ProcessInfo.processInfo.environment["PROGRAMA_BROWSEE_SOCKET_FOLDER_FOR_TESTING"], !folder.isEmpty {
            return folder
        }
        #endif
        return "/tmp/browsee-\(geteuid())"
    }

    /// The folder's entries, or none unless it is a directory this user owns, as browsee requires.
    private func browseeOwnedFolderEntries(_ folder: String) -> [String] {
        var info = stat()
        guard lstat(folder, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid() else { return [] }
        return (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
    }

    private func browseeIsRunning() -> Bool {
        BrowseeApp.probePaths(home: browseeHome, fallbackFolder: browseeFallbackFolder, listFolder: browseeOwnedFolderEntries)
            .contains { browseeSocketAccepts($0) }
    }

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
        if !browseeIsRunning() {
            try launchBrowseeInBackground()
            let deadline = Date().addingTimeInterval(BrowseeApp.launchWait)
            var running = false
            while !running, Date() < deadline {
                usleep(200_000)
                running = browseeIsRunning()
            }
            guard running else {
                throw CLIError(message: "browsee did not start within \(Int(BrowseeApp.launchWait)) seconds. Open browsee, then restart this agent.")
            }
        }
        let helper = BrowseeApp.helperPath(app: app)
        let session = BrowseeApp.session(explicit: explicitSession, environment: ProcessInfo.processInfo.environment)
        // main() ignores SIGPIPE, and an ignored signal stays ignored across exec.
        signal(SIGPIPE, SIG_DFL)
        let arguments: [String] = [helper, "--session", session]
        let argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        execv(helper, argv)
        let reason = String(cString: strerror(errno))
        argv.forEach { free($0) }
        throw CLIError(message: "Could not run \(helper): \(reason)")
    }

    /// Read from Claude Code's user config, not `claude mcp get`: that command health-checks the
    /// server, and starting ours starts browsee.
    private func claudeBrowseeRegistration() -> BrowseeRegistration? {
        let configured = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = configured.flatMap { $0.isEmpty ? nil : Self.integrationExpandTilde($0) } ?? browseeHome
        let path = (folder as NSString).appendingPathComponent(".claude.json")
        guard let data = FileManager.default.contents(atPath: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = (root["mcpServers"] as? [String: Any])?[BrowseeApp.serverName] as? [String: Any] else { return nil }
        return BrowseeRegistration(entry: entry)
    }

    private func codexBrowseeRegistration(executable: String) -> BrowseeRegistration? {
        let result = CLIProcessRunner.runProcess(
            executablePath: executable,
            arguments: ["mcp", "get", BrowseeApp.serverName, "--json"],
            timeout: 30
        )
        guard result.status == 0,
              let data = result.stdout.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return BrowseeRegistration(entry: root["transport"] as? [String: Any] ?? [:])
    }

    private func browseeRegistration(_ client: BrowseeClient, executable: String) -> BrowseeRegistration? {
        client == .claude ? claudeBrowseeRegistration() : codexBrowseeRegistration(executable: executable)
    }

    private func browseePrintClientStatus(_ client: BrowseeClient, executable: String?, programaCLI: String?) {
        guard let executable else { return print("\(client.rawValue): not found") }
        let state: String
        switch browseeRegistration(client, executable: executable) {
        case nil: state = "not registered"
        case let existing? where programaCLI.map({ BrowseeMCPStep.desired(client, programaCLI: $0) }) == existing:
            state = "registered"
        case let existing?: state = "registered, but runs \(existing.shown); run install-mcp to update it"
        }
        print("\(client.rawValue): \(executable): browsee \(state)")
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
            print("Running: \(browseeIsRunning() ? "yes" : "no")")
            let programaCLI = resolvedExecutableURL()?.path
            browseePrintClientStatus(.claude, executable: resolveClaudeExecutable(searchPath: searchPath), programaCLI: programaCLI)
            browseePrintClientStatus(.codex, executable: resolveCodexExecutable(searchPath: searchPath), programaCLI: programaCLI)
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
            let clients: [(BrowseeClient, String?)] = [(.claude, claudeExecutable), (.codex, codexExecutable)]
            let steps = clients.compactMap { client, executable in
                executable.map { executable in
                    (client: client, step: BrowseeMCPStep.build(
                        client,
                        executable: executable,
                        programaCLI: programaCLI,
                        existing: browseeRegistration(client, executable: executable),
                        install: install
                    ))
                }
            }

            print("")
            for entry in steps {
                print("\(entry.client.rawValue): \(entry.step.summary)")
                for command in entry.step.commands {
                    print("  \(command.joined(separator: " "))")
                }
            }
            guard steps.contains(where: { !$0.step.commands.isEmpty }) else {
                print("Nothing to do.")
                return
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
            for entry in steps {
                for command in entry.step.commands {
                    guard let executable = command.first else { continue }
                    print("Running: \(command.joined(separator: " "))")
                    let result = CLIProcessRunner.runProcess(
                        executablePath: executable,
                        arguments: Array(command.dropFirst()),
                        timeout: 60
                    )
                    guard result.status == 0 else {
                        // Skip this client's later commands, but keep going with the other client.
                        let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                        failures.append("\(entry.client.rawValue): exit \(result.status)\(detail.isEmpty ? "" : ": \(detail)")")
                        break
                    }
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
