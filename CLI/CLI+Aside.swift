import Foundation
import Darwin

/// Locates the Aside CLI (https://docs.aside.com) on disk. Pure and process-free so
/// it can be unit tested without touching the real filesystem.
struct AsideCLILocator {
    static func resolve(environment: [String: String], fileExists: (String) -> Bool) -> String? {
        if let home = environment["HOME"], !home.isEmpty {
            let localBin = (home as NSString).appendingPathComponent(".local/bin/aside")
            if fileExists(localBin) {
                return localBin
            }
            let cliApp = (home as NSString).appendingPathComponent(".aside/cli/Aside CLI.app/Contents/MacOS/aside")
            if fileExists(cliApp) {
                return cliApp
            }
        }
        let entries = environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        for entry in entries where !entry.isEmpty {
            let candidate = (entry as NSString).appendingPathComponent("aside")
            if fileExists(candidate) {
                return candidate
            }
        }
        return nil
    }
}

/// Builds the command plan for registering/removing Aside's MCP server(s) with
/// Claude Code and Codex. Pure so the exact argv can be unit tested without
/// spawning a process.
struct AsideMCPPlan {
    let claudeCommands: [[String]]
    let codexCommands: [[String]]

    /// `--autoConnect` makes chrome-devtools-mcp read `<userDataDir>/DevToolsActivePort` and
    /// attach to the running Aside. Without it, `--userDataDir` launches a new Chrome on
    /// Aside's profile instead.
    static func devToolsServerCommand(asideUserDataDir: String) -> [String] {
        ["npx", "-y", "chrome-devtools-mcp@latest", "--autoConnect", "--userDataDir", asideUserDataDir]
    }

    static func build(
        asidePath: String,
        asideUserDataDir: String,
        claudeExecutable: String?,
        codexExecutable: String?,
        withDevTools: Bool,
        install: Bool
    ) -> AsideMCPPlan {
        var claudeCommands: [[String]] = []
        var codexCommands: [[String]] = []
        let devToolsCommand = devToolsServerCommand(asideUserDataDir: asideUserDataDir)

        if let claude = claudeExecutable {
            if install {
                claudeCommands.append([
                    claude, "mcp", "add", "--scope", "user", "--transport", "stdio", "aside", "--", asidePath, "mcp",
                ])
                if withDevTools {
                    claudeCommands.append(
                        [claude, "mcp", "add", "--scope", "user", "--transport", "stdio", "aside-devtools", "--"] + devToolsCommand
                    )
                }
            } else {
                claudeCommands.append([claude, "mcp", "remove", "--scope", "user", "aside"])
                claudeCommands.append([claude, "mcp", "remove", "--scope", "user", "aside-devtools"])
            }
        }

        if let codex = codexExecutable {
            if install {
                codexCommands.append([codex, "mcp", "add", "aside", "--", asidePath, "mcp"])
                if withDevTools {
                    codexCommands.append([codex, "mcp", "add", "aside-devtools", "--"] + devToolsCommand)
                }
            } else {
                codexCommands.append([codex, "mcp", "remove", "aside"])
                codexCommands.append([codex, "mcp", "remove", "aside-devtools"])
            }
        }

        return AsideMCPPlan(claudeCommands: claudeCommands, codexCommands: codexCommands)
    }
}

/// Chrome's `DevToolsActivePort` file: the port on the first line, the browser target path on
/// the second. Aside writes it to its user data dir while remote debugging is on, and it can
/// outlive the browser, so a parsed port still needs a live listener.
enum AsideDevToolsActivePort {
    static func parse(_ content: String) -> (port: Int, path: String)? {
        let lines = content.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.count >= 2,
              let port = Int(lines[0]), (1...65535).contains(port),
              lines[1].hasPrefix("/") else { return nil }
        return (port, lines[1])
    }
}

/// Plans Programa's entry in Aside's own MCP client settings, `mcp.servers.programa` in
/// `~/.aside/u/<account>/settings.json`. Pure: takes the parsed settings and returns the
/// settings to write, or nil when nothing changes.
enum AsideProgramaRegistration {
    static let serverName = CodexMCPRegistrationPlan.serverName

    /// Aside validates `env` as a string map. A file that fails validation is rewritten by Aside
    /// from its in-memory copy on its next save, which drops every external edit.
    static func entry(mcpBinary: String) -> [String: Any] {
        ["enabled": true, "transport": "stdio", "command": mcpBinary, "args": [String](), "env": [String: String]()]
    }

    /// Only a `programa-mcp` command without arguments or environment counts as ours, so a
    /// user's own `programa` server is never replaced or removed.
    static func isOurs(_ server: Any?) -> Bool {
        guard let server = server as? [String: Any],
              let command = server["command"] as? String,
              (command as NSString).lastPathComponent == CodexMCPRegistrationPlan.binaryName else { return false }
        return ["args", "env"].allSatisfy { key in
            switch server[key] {
            case let list as [Any]: return list.isEmpty
            case let map as [String: Any]: return map.isEmpty
            default: return true
            }
        }
    }

    static func apply(install: Bool, settings: [String: Any], mcpBinary: String) -> (settings: [String: Any]?, note: String?) {
        if let raw = settings["mcp"], !(raw is [String: Any]) {
            return (nil, "Aside's \"mcp\" setting is not an object; leaving it unchanged.")
        }
        var mcp = settings["mcp"] as? [String: Any] ?? [:]
        if let raw = mcp["servers"], !(raw is [String: Any]) {
            return (nil, "Aside's \"mcp.servers\" setting is not an object; leaving it unchanged.")
        }
        var servers = mcp["servers"] as? [String: Any] ?? [:]
        let existing = servers[serverName]
        if existing != nil, !isOurs(existing) {
            return (nil, install ? "Aside already has an MCP server named \(serverName); leaving it unchanged." : nil)
        }
        var updated = settings
        if install {
            let desired = entry(mcpBinary: mcpBinary)
            if let existing = existing as? NSDictionary, existing.isEqual(to: desired) { return (nil, nil) }
            servers[serverName] = desired
        } else {
            guard existing != nil else { return (nil, nil) }
            servers.removeValue(forKey: serverName)
            if var inventories = mcp["inventories"] as? [String: Any] {
                inventories.removeValue(forKey: serverName)
                mcp["inventories"] = inventories
            }
        }
        mcp["servers"] = servers
        updated["mcp"] = mcp
        return (updated, nil)
    }
}

/// A computed change to Aside's settings file, written only while the file still holds `original`.
struct AsideSettingsChange {
    let path: String
    let original: Data
    let updated: Data
    let summary: String
}

extension ProgramaCLI {
    static var asideUserDataDir: String {
        integrationExpandTilde("~/Library/Application Support/Aside")
    }

    /// Report-only probe of Aside's Chrome DevTools Protocol endpoint. Returns
    /// `ws://127.0.0.1:<port><path>` from Aside's `DevToolsActivePort` when that port accepts a
    /// connection, nil when remote debugging is off or Aside is not running.
    func asideDevToolsEndpoint(timeout: TimeInterval = 1) -> String? {
        let portFile = (Self.asideUserDataDir as NSString).appendingPathComponent("DevToolsActivePort")
        guard let content = try? String(contentsOfFile: portFile, encoding: .utf8),
              let active = AsideDevToolsActivePort.parse(content),
              asideLoopbackPortIsOpen(active.port, timeout: timeout) else { return nil }
        return "ws://127.0.0.1:\(active.port)\(active.path)"
    }

    /// A TCP connect only, never a WebSocket handshake, so the probe cannot trigger Aside's
    /// remote debugging consent prompt.
    private func asideLoopbackPortIsOpen(_ port: Int, timeout: TimeInterval) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        guard poll(&pollDescriptor, 1, Int32(timeout * 1000)) == 1 else { return false }
        var socketError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        return getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0 && socketError == 0
    }

    /// The signed-in account's settings file, or a note explaining why there is none. Reads
    /// only `currentAccountId` from `accounts.json`; the rest of that file holds tokens.
    private func asideAccountSettingsPath() -> (path: String?, note: String?) {
        let asideHome = Self.integrationExpandTilde("~/.aside")
        guard FileManager.default.fileExists(atPath: asideHome) else {
            return (nil, "\(asideHome) not found, skipping (open Aside once to create it)")
        }
        let accountsPath = (asideHome as NSString).appendingPathComponent("accounts.json")
        guard let data = FileManager.default.contents(atPath: accountsPath),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accountID = (root["currentAccountId"] as? Int).map(String.init) ?? root["currentAccountId"] as? String else {
            return (nil, "no signed-in Aside account in \(accountsPath), skipping")
        }
        let settingsPath = (asideHome as NSString).appendingPathComponent("u/\(accountID)/settings.json")
        guard FileManager.default.fileExists(atPath: settingsPath) else {
            return (nil, "\(settingsPath) not found, skipping (open Aside once to create it)")
        }
        return (settingsPath, nil)
    }

    private func asideProgramaMCPBinary() -> String? {
        if let bundled = bundledMCPBinaryPath() { return bundled }
        let installed = "/Applications/Programa.app/Contents/Resources/bin/\(CodexMCPRegistrationPlan.binaryName)"
        return FileManager.default.isExecutableFile(atPath: installed) ? installed : nil
    }

    /// Aside's `programa` server entry, or a note when the settings cannot be read.
    private func asideProgramaServer() -> (server: Any?, note: String?) {
        let located = asideAccountSettingsPath()
        guard let path = located.path else { return (nil, located.note) }
        guard let data = FileManager.default.contents(atPath: path),
              let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, "\(path) is not valid JSON")
        }
        let servers = (settings["mcp"] as? [String: Any])?["servers"] as? [String: Any]
        return (servers?[AsideProgramaRegistration.serverName], nil)
    }

    private func asideSettingsChange(install: Bool) -> (change: AsideSettingsChange?, note: String?) {
        let located = asideAccountSettingsPath()
        guard let path = located.path else { return (nil, located.note) }
        let mcpBinary = asideProgramaMCPBinary()
        if install, mcpBinary == nil {
            return (nil, "\(CodexMCPRegistrationPlan.binaryName) not found next to this CLI or in /Applications/Programa.app, skipping")
        }
        guard let original = FileManager.default.contents(atPath: path),
              let settings = try? JSONSerialization.jsonObject(with: original) as? [String: Any] else {
            return (nil, "\(path) is not valid JSON, leaving it unchanged")
        }
        let planned = AsideProgramaRegistration.apply(install: install, settings: settings, mcpBinary: mcpBinary ?? "")
        guard let updatedSettings = planned.settings,
              let updated = try? JSONSerialization.data(
                withJSONObject: updatedSettings,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
              ) else { return (nil, planned.note) }
        let key = "mcp.servers.\(AsideProgramaRegistration.serverName)"
        let summary = install ? "set \(key) in \(path) to \(mcpBinary ?? "")" : "remove \(key) from \(path)"
        return (AsideSettingsChange(path: path, original: original, updated: updated, summary: summary), nil)
    }

    /// Holds Aside's own lock (`proper-lockfile` creates `settings.json.lock` as a directory) and
    /// writes only while the file still holds the bytes the change was computed from.
    private func applyAsideSettingsChange(_ change: AsideSettingsChange) throws {
        let target = try codexResolveConfigTarget(change.path)
        let lock = target + ".lock"
        guard mkdir(lock, 0o755) == 0 else {
            if errno == EEXIST {
                throw CLIError(message: "Aside is writing \(change.path) right now. Re-run this command.")
            }
            throw CLIError(message: "Could not lock \(change.path): \(String(cString: strerror(errno)))")
        }
        defer { rmdir(lock) }
        guard FileManager.default.contents(atPath: target) == change.original else {
            throw CLIError(message: "\(change.path) changed while Programa was being registered. Re-run this command.")
        }
        do {
            try codexAtomicWrite(change.updated, to: target, mode: 0o600)
        } catch {
            throw CLIError(message: error.localizedDescription)
        }
    }

    private func asideResolveClients(environment: [String: String]) -> (claude: String?, codex: String?) {
        let searchPath = environment["PATH"]
        return (
            resolveClaudeExecutable(searchPath: searchPath),
            resolveCodexExecutable(searchPath: searchPath)
        )
    }

    private func asideIsRegistered(executable: String, serverName: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["mcp", "get", serverName]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func asideRunCommand(_ command: [String]) throws {
        guard let executable = command.first else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(command.dropFirst())
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CLIError(message: "Command failed (\(process.terminationStatus)): \(command.joined(separator: " "))")
        }
    }

    func runAside(arguments: [String]) throws {
        let subcommand = arguments.first?.lowercased() ?? "help"
        let withDevTools = arguments.contains("--with-devtools")
        let skipConfirm = arguments.contains("--yes") || arguments.contains("-y")
        let environment = ProcessInfo.processInfo.environment

        let asidePath = AsideCLILocator.resolve(environment: environment) { FileManager.default.isExecutableFile(atPath: $0) }
        let (claudeExecutable, codexExecutable) = asideResolveClients(environment: environment)

        switch subcommand {
        case "status":
            if let asidePath {
                print("Aside CLI: \(asidePath)")
            } else {
                print("Aside CLI: not found, install from https://docs.aside.com/help/developers")
            }
            if let endpoint = asideDevToolsEndpoint() {
                print("DevTools: \(endpoint)")
            } else {
                print("DevTools: remote debugging is off. Turn it on in Aside at chrome://inspect/#remote-debugging")
            }
            let asideServer = asideProgramaServer()
            if let note = asideServer.note {
                print("Aside MCP client: \(note)")
            } else if let server = asideServer.server {
                let command = (server as? [String: Any])?["command"] as? String ?? "a non-stdio server"
                let owner = AsideProgramaRegistration.isOurs(server) ? "" : " (not managed by Programa)"
                print("Aside MCP client: programa registered: \(command)\(owner)")
            } else {
                print("Aside MCP client: programa not registered")
            }
            if let claudeExecutable {
                let registered = asideIsRegistered(executable: claudeExecutable, serverName: "aside")
                print("Claude Code: \(claudeExecutable): aside \(registered ? "registered" : "not registered")")
            } else {
                print("Claude Code: not found")
            }
            if let codexExecutable {
                let registered = asideIsRegistered(executable: codexExecutable, serverName: "aside")
                print("Codex: \(codexExecutable): aside \(registered ? "registered" : "not registered")")
            } else {
                print("Codex: not found")
            }
            return

        case "install-mcp", "uninstall-mcp":
            let install = subcommand == "install-mcp"
            // Removal only needs the client CLIs; the Aside binary may already be gone.
            if install, asidePath == nil {
                throw CLIError(message: "Aside CLI not found. Install it from https://docs.aside.com/help/developers")
            }
            let planAsidePath = asidePath ?? "aside"
            print("Aside CLI: \(asidePath ?? "not found")")
            if let endpoint = asideDevToolsEndpoint() {
                print("DevTools: \(endpoint)")
            }
            if claudeExecutable == nil {
                print("Claude Code: not found, skipping")
            }
            if codexExecutable == nil {
                print("Codex: not found, skipping")
            }

            let asideSettings = asideSettingsChange(install: install)
            if let note = asideSettings.note {
                print("Aside MCP client: \(note)")
            }
            if claudeExecutable == nil, codexExecutable == nil, asideSettings.change == nil {
                throw CLIError(message: "Neither Claude Code nor Codex CLI was found on PATH, and Aside's own settings need no change.")
            }

            let plan = AsideMCPPlan.build(
                asidePath: planAsidePath,
                asideUserDataDir: Self.asideUserDataDir,
                claudeExecutable: claudeExecutable,
                codexExecutable: codexExecutable,
                withDevTools: withDevTools,
                install: install
            )

            var pendingCommands: [(client: String, serverName: String, command: [String])] = []
            for command in plan.claudeCommands {
                let serverName = command.contains("aside-devtools") ? "aside-devtools" : "aside"
                pendingCommands.append((client: "Claude Code", serverName: serverName, command: command))
            }
            for command in plan.codexCommands {
                let serverName = command.contains("aside-devtools") ? "aside-devtools" : "aside"
                pendingCommands.append((client: "Codex", serverName: serverName, command: command))
            }

            guard !pendingCommands.isEmpty || asideSettings.change != nil else {
                print("Nothing to do.")
                return
            }

            print("")
            print("The following commands will run:")
            for entry in pendingCommands {
                print("  \(entry.command.joined(separator: " "))")
            }
            if let change = asideSettings.change {
                print("  \(change.summary)")
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
            for entry in pendingCommands {
                guard let executable = entry.command.first else { continue }
                let registered = asideIsRegistered(executable: executable, serverName: entry.serverName)
                if install, registered {
                    print("\(entry.client): \(entry.serverName) already registered, skipping")
                    continue
                }
                if !install, !registered {
                    print("\(entry.client): \(entry.serverName) not registered, skipping")
                    continue
                }
                print("Running: \(entry.command.joined(separator: " "))")
                do {
                    try asideRunCommand(entry.command)
                } catch {
                    // Keep going so one client's failure never leaves the other client's
                    // registration untouched; report everything at the end.
                    failures.append("\(entry.client) \(entry.serverName): \(error)")
                }
            }
            if let change = asideSettings.change {
                print("Aside MCP client: \(change.summary)")
                do {
                    try applyAsideSettingsChange(change)
                    print("Aside reads its MCP servers when it starts; quit and reopen Aside to apply.")
                } catch {
                    failures.append("Aside \(AsideProgramaRegistration.serverName): \(error)")
                }
            }
            print("")
            if failures.isEmpty {
                print(install ? "Installed." : "Removed.")
                return
            }
            throw CLIError(message: (install ? "Some registrations failed:\n  " : "Some removals failed:\n  ") + failures.joined(separator: "\n  "))

        default:
            print("Usage: programa aside <status|install-mcp|uninstall-mcp> [--with-devtools] [--yes]")
            throw CLIError(message: "Unknown aside subcommand: \(subcommand)")
        }
    }
}
