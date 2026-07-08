import Foundation
import CryptoKit
import Darwin
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
#if canImport(Security)
import Security
#endif

extension CMUXCLI {
    private func isProgramaClaudeWrapper(at path: String) -> Bool {
        guard let data = FileManager.default.contents(atPath: path) else { return false }
        let prefixData = data.prefix(512)
        guard let prefix = String(data: prefixData, encoding: .utf8) else { return false }
        return prefix.contains("cmux claude wrapper - injects hooks and session tracking")
    }

    private func resolveExecutableInSearchPath(
        _ name: String,
        searchPath: String?,
        skip: ((String) -> Bool)? = nil
    ) -> String? {
        let entries = searchPath?.split(separator: ":").map(String.init) ?? []
        for entry in entries where !entry.isEmpty {
            let candidate = URL(fileURLWithPath: entry, isDirectory: true)
                .appendingPathComponent(name, isDirectory: false)
                .path
            guard FileManager.default.isExecutableFile(atPath: candidate) else { continue }
            if let skip, skip(candidate) { continue }
            return candidate
        }
        return nil
    }

    private func resolveClaudeExecutable(searchPath: String?) -> String? {
        resolveExecutableInSearchPath(
            "claude",
            searchPath: searchPath,
            skip: { self.isProgramaClaudeWrapper(at: $0) }
        )
    }

    private func claudeTeamsHasExplicitTeammateMode(commandArgs: [String]) -> Bool {
        commandArgs.contains { arg in
            arg == "--teammate-mode" || arg.hasPrefix("--teammate-mode=")
        }
    }

    private func claudeTeamsLaunchArguments(commandArgs: [String]) -> [String] {
        guard !claudeTeamsHasExplicitTeammateMode(commandArgs: commandArgs) else {
            return commandArgs
        }
        return ["--teammate-mode", "auto"] + commandArgs
    }

    private static let claudeNodeOptionsRestoreModule = """
    const hadOriginalNodeOptions = process.env.PROGRAMA_ORIGINAL_NODE_OPTIONS_PRESENT === "1";
    if (hadOriginalNodeOptions) {
        process.env.NODE_OPTIONS = process.env.PROGRAMA_ORIGINAL_NODE_OPTIONS ?? "";
    } else {
        delete process.env.NODE_OPTIONS;
    }
    delete process.env.PROGRAMA_ORIGINAL_NODE_OPTIONS;
    delete process.env.PROGRAMA_ORIGINAL_NODE_OPTIONS_PRESENT;
    """

    /// Configures the shared tmux-compat environment for an agent wrapper
    /// command (claude-teams, omo, omx, omc), then optionally layers on the
    /// NODE_OPTIONS restore module. claude-teams and omc both wrap Claude
    /// Code and need that module configured identically (silently skipped
    /// if the module file can't be created).
    private func configureAgentWrapperEnvironment(
        processEnvironment: [String: String],
        shimDirectory: URL,
        executablePath: String,
        socketPath: String,
        explicitPassword: String?,
        focusedContext: TmuxCompatFocusedContext?,
        tmuxPathPrefix: String,
        programaBinEnvVar: String,
        termOverrideEnvVar: String,
        extraEnvVars: [(key: String, value: String)],
        needsClaudeNodeOptionsRestore: Bool
    ) {
        configureTmuxCompatEnvironment(
            processEnvironment: processEnvironment,
            shimDirectory: shimDirectory,
            executablePath: executablePath,
            socketPath: socketPath,
            explicitPassword: explicitPassword,
            focusedContext: focusedContext,
            tmuxPathPrefix: tmuxPathPrefix,
            programaBinEnvVar: programaBinEnvVar,
            termOverrideEnvVar: termOverrideEnvVar,
            extraEnvVars: extraEnvVars
        )
        guard needsClaudeNodeOptionsRestore else { return }
        guard let restoreModuleURL = try? createClaudeNodeOptionsRestoreModule() else {
            unsetenv("PROGRAMA_ORIGINAL_NODE_OPTIONS_PRESENT")
            unsetenv("PROGRAMA_ORIGINAL_NODE_OPTIONS")
            return
        }
        if let existing = processEnvironment["NODE_OPTIONS"] {
            setenv("PROGRAMA_ORIGINAL_NODE_OPTIONS_PRESENT", "1", 1)
            setenv("PROGRAMA_ORIGINAL_NODE_OPTIONS", existing, 1)
        } else {
            setenv("PROGRAMA_ORIGINAL_NODE_OPTIONS_PRESENT", "0", 1)
            unsetenv("PROGRAMA_ORIGINAL_NODE_OPTIONS")
        }
        setenv(
            "NODE_OPTIONS",
            mergedNodeOptions(
                existing: processEnvironment["NODE_OPTIONS"],
                restoreModulePath: restoreModuleURL.path
            ),
            1
        )
    }

    private func createClaudeTeamsShimDirectory() throws -> URL {
        let script = """
        #!/usr/bin/env bash
        set -euo pipefail
        exec "${PROGRAMA_CLAUDE_TEAMS_PROGRAMA_BIN:-programa}" __tmux-compat "$@"
        """
        return try createTmuxCompatShimDirectory(
            directoryName: "claude-teams-bin",
            tmuxShimScript: script
        )
    }

    private func createClaudeNodeOptionsRestoreModule() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("cmux-claude-node-options", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: nil)
        let restoreModuleURL = root.appendingPathComponent("restore-node-options.cjs", isDirectory: false)
        try writeShimIfChanged(Self.claudeNodeOptionsRestoreModule, to: restoreModuleURL)
        return restoreModuleURL
    }

    /// Everything that differs between the four agent wrapper commands
    /// (claude-teams, omo, omx, omc). runAgentWrapper implements their
    /// shared shape once; each run* function below just builds a config.
    private struct AgentWrapperConfig {
        /// Name used in "programa <cmdLabel>" messages.
        let cmdLabel: String
        /// Bare command name: used for the execvp fallback, the not-found
        /// `which` check, and error messages (e.g. "claude").
        let execName: String
        /// Resolves the real executable path given the launcher environment
        /// (already carrying PROGRAMA_SOCKET/PROGRAMA_SOCKET_PATH/
        /// PROGRAMA_SOCKET_PASSWORD).
        let resolveExecutable: (_ launcherEnvironment: [String: String]) -> String?
        /// When non-nil, a nil resolveExecutable result triggers a `which`
        /// check; if that also fails, throws CLIError with this hint. nil
        /// (claude-teams) means no early not-found check is performed --
        /// claude-teams instead falls through to the generic exec-failure
        /// error below.
        let notFoundInstallHint: String?
        /// Runs after the not-found check (if any), before shim directory
        /// creation. Only omo uses this (oh-my-opencode plugin setup).
        let preLaunch: (() throws -> Void)?
        /// Creates the tool's shim directory.
        let createShimDir: () throws -> URL
        /// Runs after focused-context lookup, before configureEnvironment.
        /// Returns env vars to merge into the launcher environment (e.g.
        /// omo's resolved OPENCODE_PORT). Only omo uses this.
        let beforeConfigure: ((_ launcherEnvironment: [String: String]) -> [String: String])?
        let tmuxPathPrefix: String
        let programaBinEnvVar: String
        let termOverrideEnvVar: String
        /// Extra env vars to set, computed from the (possibly beforeConfigure-
        /// augmented) launcher environment.
        let extraEnvVars: (_ launcherEnvironment: [String: String]) -> [(key: String, value: String)]
        /// claude-teams and omc both wrap Claude Code and need the
        /// NODE_OPTIONS restore module configured.
        let needsClaudeNodeOptionsRestore: Bool
        /// Transforms the raw CLI args before exec. claude-teams injects
        /// --teammate-mode; omo injects a default --port. omx/omc pass
        /// commandArgs through unchanged.
        let buildLaunchArguments: (_ commandArgs: [String], _ launcherEnvironment: [String: String]) -> [String]
        /// Extra text appended (after a blank line) to the exec-failure
        /// message. nil for claude-teams.
        let execFailureHint: String?
    }

    /// Implements the shared shape of `programa claude-teams`, `programa
    /// omo`, `programa omx`, and `programa omc`: build the launcher
    /// environment, resolve the real executable, optionally check it's
    /// installed and run tool-specific setup, create shim scripts, gather
    /// focused-terminal context, configure environment variables, and exec.
    private func runAgentWrapper(
        commandArgs: [String],
        socketPath: String,
        explicitPassword: String?,
        config: AgentWrapperConfig
    ) throws {
        var launcherEnvironment = ProcessInfo.processInfo.environment
        launcherEnvironment["PROGRAMA_SOCKET_PATH"] = socketPath
        launcherEnvironment["PROGRAMA_SOCKET"] = socketPath
        if let explicitPassword,
           !explicitPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            launcherEnvironment["PROGRAMA_SOCKET_PASSWORD"] = explicitPassword
        }

        let resolvedExecutablePath = config.resolveExecutable(launcherEnvironment)

        if resolvedExecutablePath == nil, let hint = config.notFoundInstallHint {
            let checkProcess = Process()
            checkProcess.executableURL = URL(fileURLWithPath: "/usr/bin/which")
            checkProcess.arguments = [config.execName]
            checkProcess.standardOutput = Pipe()
            checkProcess.standardError = Pipe()
            try? checkProcess.run()
            checkProcess.waitUntilExit()
            if checkProcess.terminationStatus != 0 {
                throw CLIError(message: "\(config.execName) is not installed. Install it first:\n  \(hint)\n\nThen run: programa \(config.cmdLabel)")
            }
        }

        if let preLaunch = config.preLaunch {
            try preLaunch()
        }

        let shimDirectory = try config.createShimDir()
        let executablePath = resolvedExecutableURL()?.path ?? (args.first ?? "programa")
        let focusedContext = tmuxCompatFocusedContext(
            processEnvironment: launcherEnvironment,
            explicitPassword: explicitPassword
        )

        if let beforeConfigure = config.beforeConfigure {
            for (key, value) in beforeConfigure(launcherEnvironment) {
                launcherEnvironment[key] = value
            }
        }

        configureAgentWrapperEnvironment(
            processEnvironment: launcherEnvironment,
            shimDirectory: shimDirectory,
            executablePath: executablePath,
            socketPath: socketPath,
            explicitPassword: explicitPassword,
            focusedContext: focusedContext,
            tmuxPathPrefix: config.tmuxPathPrefix,
            programaBinEnvVar: config.programaBinEnvVar,
            termOverrideEnvVar: config.termOverrideEnvVar,
            extraEnvVars: config.extraEnvVars(launcherEnvironment),
            needsClaudeNodeOptionsRestore: config.needsClaudeNodeOptionsRestore
        )

        let launchPath = resolvedExecutablePath ?? config.execName
        let launchArguments = config.buildLaunchArguments(commandArgs, launcherEnvironment)
        var argv = ([launchPath] + launchArguments).map { strdup($0) }
        defer {
            for item in argv {
                free(item)
            }
        }
        argv.append(nil)

        if resolvedExecutablePath != nil {
            execv(launchPath, &argv)
        } else {
            execvp(config.execName, &argv)
        }
        let code = errno
        let hintSuffix = config.execFailureHint.map { "\n\n\($0)" } ?? ""
        throw CLIError(message: "Failed to launch \(config.execName): \(String(cString: strerror(code)))\(hintSuffix)")
    }

    func runClaudeTeams(
        commandArgs: [String],
        socketPath: String,
        explicitPassword: String?
    ) throws {
        try runAgentWrapper(
            commandArgs: commandArgs,
            socketPath: socketPath,
            explicitPassword: explicitPassword,
            config: AgentWrapperConfig(
                cmdLabel: "claude-teams",
                execName: "claude",
                resolveExecutable: { launcherEnvironment in
                    let bundledClaudePath = resolvedExecutableURL()?
                        .deletingLastPathComponent()
                        .appendingPathComponent("claude", isDirectory: false)
                        .path
                    // Check custom path from Settings > Automation > Claude Code.
                    // Try env var first (set by the app per-session), then UserDefaults.
                    let candidates = [
                        launcherEnvironment["PROGRAMA_CUSTOM_CLAUDE_PATH"],
                        UserDefaults.standard.string(forKey: "claudeCodeCustomClaudePath"),
                    ]
                    for raw in candidates {
                        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
                              !trimmed.isEmpty else { continue }
                        var isDir: ObjCBool = false
                        guard FileManager.default.fileExists(atPath: trimmed, isDirectory: &isDir),
                              !isDir.boolValue,
                              FileManager.default.isExecutableFile(atPath: trimmed),
                              !isProgramaClaudeWrapper(at: trimmed) else { continue }
                        return trimmed
                    }
                    return resolveClaudeExecutable(searchPath: launcherEnvironment["PATH"])
                        ?? {
                            guard let bundledClaudePath,
                                  FileManager.default.isExecutableFile(atPath: bundledClaudePath) else { return nil }
                            return bundledClaudePath
                        }()
                },
                notFoundInstallHint: nil,
                preLaunch: nil,
                createShimDir: { try self.createClaudeTeamsShimDirectory() },
                beforeConfigure: nil,
                tmuxPathPrefix: "cmux-claude-teams",
                programaBinEnvVar: "PROGRAMA_CLAUDE_TEAMS_PROGRAMA_BIN",
                termOverrideEnvVar: "PROGRAMA_CLAUDE_TEAMS_TERM",
                extraEnvVars: { _ in
                    [(key: "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS", value: "1")]
                },
                needsClaudeNodeOptionsRestore: true,
                buildLaunchArguments: { commandArgs, _ in
                    claudeTeamsLaunchArguments(commandArgs: commandArgs)
                },
                execFailureHint: nil
            )
        )
    }

    // MARK: - programa omo (OpenCode + oh-my-openagent)

    /// Creates a shim directory containing a `tmux` shim that answers
    /// `-V`/`-v` locally (no live socket connection needed just to probe
    /// the tmux version) and forwards everything else to `programa
    /// __tmux-compat`. Shared by omo, omx, and omc; claude-teams uses its
    /// own simpler shim with no -V/-v handling (createClaudeTeamsShimDirectory).
    private func createVFlagTmuxShimDirectory(
        directoryName: String,
        programaBinEnvVar: String,
        versionCheckComment: String = ""
    ) throws -> URL {
        let tmuxScript = """
        #!/usr/bin/env bash
        set -euo pipefail
        \(versionCheckComment)case "${1:-}" in
          -V|-v) echo "tmux 3.4"; exit 0 ;;
        esac
        exec "${\(programaBinEnvVar):-programa}" __tmux-compat "$@"
        """
        return try createTmuxCompatShimDirectory(
            directoryName: directoryName,
            tmuxShimScript: tmuxScript
        )
    }

    private func createOMOShimDirectory() throws -> URL {
        // tmux shim: redirects tmux commands to programa __tmux-compat
        // Handle -V locally (no socket needed) since __tmux-compat requires a connection.
        let root = try createVFlagTmuxShimDirectory(
            directoryName: "omo-bin",
            programaBinEnvVar: "PROGRAMA_OMO_PROGRAMA_BIN",
            versionCheckComment: "# Only match -V/-v as the first arg (top-level tmux flag).\n# -v inside subcommands (e.g. split-window -v) is a vertical split flag.\n"
        )

        // terminal-notifier shim: intercepts macOS notifications and routes to programa notify
        let notifierURL = root.appendingPathComponent("terminal-notifier", isDirectory: false)
        let notifierScript = """
        #!/usr/bin/env bash
        # Intercept terminal-notifier calls and route through programa notify.
        # oh-my-openagent calls: terminal-notifier -title <t> -message <m> [-activate <id>]
        TITLE="" BODY=""
        while [[ $# -gt 0 ]]; do
          case "$1" in
            -title)   TITLE="$2"; shift 2 ;;
            -message) BODY="$2"; shift 2 ;;
            *)        shift ;;
          esac
        done
        exec "${PROGRAMA_OMO_PROGRAMA_BIN:-programa}" notify --title "${TITLE:-OpenCode}" --body "${BODY:-}"
        """
        try writeShimIfChanged(notifierScript, to: notifierURL)

        return root
    }

    func writeShimIfChanged(_ script: String, to url: URL) throws {
        let normalized = script.trimmingCharacters(in: .whitespacesAndNewlines)
        let fileManager = FileManager.default
        let existing = try? String(contentsOf: url, encoding: .utf8)
        guard existing?.trimmingCharacters(in: .whitespacesAndNewlines) != normalized else {
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return
        }
        let directoryURL = url.deletingLastPathComponent()
        let tempURL = directoryURL.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try script.write(to: tempURL, atomically: false, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempURL.path)
        do {
            if fileManager.fileExists(atPath: url.path) {
                _ = try fileManager.replaceItemAt(url, withItemAt: tempURL)
            } else {
                try fileManager.moveItem(at: tempURL, to: url)
            }
        } catch {
            let current = try? String(contentsOf: url, encoding: .utf8)
            if current?.trimmingCharacters(in: .whitespacesAndNewlines) == normalized {
                try? fileManager.removeItem(at: tempURL)
                return
            }
            if fileManager.fileExists(atPath: url.path) {
                do {
                    _ = try fileManager.replaceItemAt(url, withItemAt: tempURL)
                    return
                } catch {}
            }
            try? fileManager.removeItem(at: tempURL)
            throw error
        }
    }

    private static let omoPluginName = "oh-my-opencode"

    private func resolveExecutableInPath(_ name: String) -> String? {
        let entries = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        for entry in entries where !entry.isEmpty {
            let candidate = URL(fileURLWithPath: entry, isDirectory: true)
                .appendingPathComponent(name, isDirectory: false)
                .path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private func omoUserConfigDir() -> URL {
        let homePath = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        return URL(fileURLWithPath: homePath, isDirectory: true)
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("opencode", isDirectory: true)
    }

    private func omoShadowConfigDir() -> URL {
        let homePath = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        return URL(fileURLWithPath: homePath, isDirectory: true)
            .appendingPathComponent(".programa", isDirectory: true)
            .appendingPathComponent("omo-config", isDirectory: true)
    }

    private func omoFileType(at url: URL) -> FileAttributeType? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attrs?[.type] as? FileAttributeType
    }

    private func omoEnsureShadowPackageManifest(at shadowPackageURL: URL) throws {
        let fm = FileManager.default
        if omoFileType(at: shadowPackageURL) == .typeSymbolicLink {
            try? fm.removeItem(at: shadowPackageURL)
        }

        // Keep the shadow package isolated from stale/yanked pins in the user's
        // opencode package.json. bun will update this manifest with the resolved
        // oh-my-opencode version when installation succeeds.
        let packageManifest: [String: Any] = [
            "dependencies": [
                Self.omoPluginName: "latest"
            ],
            "name": "cmux-omo-shadow",
            "private": true
        ]
        let output = try JSONSerialization.data(withJSONObject: packageManifest, options: [.prettyPrinted, .sortedKeys])
        let existing = try? Data(contentsOf: shadowPackageURL)
        if existing != output {
            try output.write(to: shadowPackageURL, options: .atomic)
        }
    }

    private func omoEnsureShadowNodeModulesSymlink(
        shadowNodeModules: URL,
        userNodeModules: URL
    ) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: userNodeModules.path) else { return }

        if let type = omoFileType(at: shadowNodeModules) {
            if type == .typeSymbolicLink {
                let target = try? fm.destinationOfSymbolicLink(atPath: shadowNodeModules.path)
                if target != userNodeModules.path {
                    try? fm.removeItem(at: shadowNodeModules)
                } else {
                    return
                }
            } else {
                return
            }
        }

        if !fm.fileExists(atPath: shadowNodeModules.path) {
            try fm.createSymbolicLink(at: shadowNodeModules, withDestinationURL: userNodeModules)
        }
    }

    private func omoRunPackageInstall(
        executablePath: String,
        arguments: [String],
        currentDirectoryURL: URL
    ) throws -> Int32 {
        let process = Process()
        process.currentDirectoryURL = currentDirectoryURL
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardOutput = FileHandle.standardError
        process.standardError = FileHandle.standardError
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func omoRequestedPort(from commandArgs: [String]) -> String? {
        for (index, arg) in commandArgs.enumerated() {
            if arg == "--port" {
                let nextIndex = commandArgs.index(after: index)
                guard nextIndex < commandArgs.endIndex else { return nil }
                let value = commandArgs[nextIndex].trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            }

            if arg.hasPrefix("--port=") {
                let value = String(arg.dropFirst("--port=".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            }
        }

        return nil
    }

    private func omoBindableLoopbackPort(_ port: UInt16) -> UInt16? {
        let socketDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else { return nil }
        defer { close(socketDescriptor) }

        var reuseAddress: Int32 = 1
        _ = setsockopt(
            socketDescriptor,
            SOL_SOCKET,
            SO_REUSEADDR,
            &reuseAddress,
            socklen_t(MemoryLayout<Int32>.size)
        )

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.stride)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.stride))
            }
        }
        guard bindResult == 0 else { return nil }

        if port != 0 {
            return port
        }

        var boundAddress = address
        var boundAddressLength = socklen_t(MemoryLayout<sockaddr_in>.stride)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socketDescriptor, $0, &boundAddressLength)
            }
        }
        guard nameResult == 0 else { return nil }

        return UInt16(bigEndian: boundAddress.sin_port)
    }

    private func omoResolvedPort(
        commandArgs: [String],
        processEnvironment: [String: String]
    ) -> String {
        if let requestedPort = omoRequestedPort(from: commandArgs) {
            return requestedPort
        }

        if let environmentPort = processEnvironment["OPENCODE_PORT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           let parsedEnvironmentPort = UInt16(environmentPort),
           parsedEnvironmentPort != 0,
           omoBindableLoopbackPort(parsedEnvironmentPort) != nil {
            return environmentPort
        }

        if let preferredPort = omoBindableLoopbackPort(4096) {
            return String(preferredPort)
        }

        if let fallbackPort = omoBindableLoopbackPort(0) {
            return String(fallbackPort)
        }

        return "4096"
    }

    /// Creates a shadow config directory that layers oh-my-opencode on top of the user's
    /// existing opencode config without modifying the original. Sets OPENCODE_CONFIG_DIR
    /// to point at the shadow directory.
    private func omoEnsurePlugin() throws {
        let userDir = omoUserConfigDir()
        let shadowDir = omoShadowConfigDir()
        let fm = FileManager.default

        try fm.createDirectory(at: shadowDir, withIntermediateDirectories: true, attributes: nil)

        // Read the user's opencode.json (if any), add the plugin, write to shadow dir
        let userJsonURL = userDir.appendingPathComponent("opencode.json")
        let shadowJsonURL = shadowDir.appendingPathComponent("opencode.json")

        var config: [String: Any]
        if let data = try? Data(contentsOf: userJsonURL) {
            guard let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CLIError(message: "Failed to parse \(userJsonURL.path). Fix the JSON syntax and retry.")
            }
            config = existing
        } else {
            config = [:]
        }

        var plugins = (config["plugin"] as? [String]) ?? []
        let alreadyPresent = plugins.contains {
            $0 == Self.omoPluginName || $0.hasPrefix("\(Self.omoPluginName)@")
        }
        if !alreadyPresent {
            plugins.append(Self.omoPluginName)
        }
        config["plugin"] = plugins

        let output = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        try output.write(to: shadowJsonURL, options: .atomic)

        // Symlink node_modules from the user's config dir so installed packages resolve
        let shadowNodeModules = shadowDir.appendingPathComponent("node_modules")
        let userNodeModules = userDir.appendingPathComponent("node_modules")
        try omoEnsureShadowNodeModulesSymlink(shadowNodeModules: shadowNodeModules, userNodeModules: userNodeModules)

        // The shadow config owns its own package metadata so yanked/stale pins in the
        // user's opencode package.json/bun.lock cannot poison plugin installation.
        let shadowPackageURL = shadowDir.appendingPathComponent("package.json")
        let shadowBunLockURL = shadowDir.appendingPathComponent("bun.lock")
        try omoEnsureShadowPackageManifest(at: shadowPackageURL)
        if omoFileType(at: shadowBunLockURL) == .typeSymbolicLink {
            try? fm.removeItem(at: shadowBunLockURL)
        }

        // Copy oh-my-opencode plugin config (jsonc) if the user has one
        for filename in ["oh-my-opencode.json", "oh-my-opencode.jsonc"] {
            let userFile = userDir.appendingPathComponent(filename)
            let shadowFile = shadowDir.appendingPathComponent(filename)
            if fm.fileExists(atPath: userFile.path) && !fm.fileExists(atPath: shadowFile.path) {
                try fm.createSymbolicLink(at: shadowFile, withDestinationURL: userFile)
            }
        }

        // Install the package if not available via the symlinked node_modules
        let pluginPackageDir = shadowNodeModules.appendingPathComponent(Self.omoPluginName)
        if !fm.fileExists(atPath: pluginPackageDir.path) {
            let installDir = shadowDir
            if let bunPath = resolveExecutableInPath("bun") {
                FileHandle.standardError.write("Installing oh-my-opencode plugin (this may take a minute on first run)...\n".data(using: .utf8)!)
                let installArguments = ["add", Self.omoPluginName]
                let firstAttemptStatus = try omoRunPackageInstall(
                    executablePath: bunPath,
                    arguments: installArguments,
                    currentDirectoryURL: installDir
                )
                if firstAttemptStatus != 0 {
                    FileHandle.standardError.write("Retrying oh-my-opencode install with a clean shadow package state...\n".data(using: .utf8)!)
                    try? fm.removeItem(at: shadowBunLockURL)
                    try? fm.removeItem(at: shadowNodeModules)
                    try omoEnsureShadowNodeModulesSymlink(shadowNodeModules: shadowNodeModules, userNodeModules: userNodeModules)
                    let retryStatus = try omoRunPackageInstall(
                        executablePath: bunPath,
                        arguments: installArguments,
                        currentDirectoryURL: installDir
                    )
                    if retryStatus != 0 {
                        throw CLIError(message: "Failed to install oh-my-opencode. Try manually: npm install -g oh-my-opencode")
                    }
                }
            } else if let npmPath = resolveExecutableInPath("npm") {
                FileHandle.standardError.write("Installing oh-my-opencode plugin (this may take a minute on first run)...\n".data(using: .utf8)!)
                let status = try omoRunPackageInstall(
                    executablePath: npmPath,
                    arguments: ["install", Self.omoPluginName],
                    currentDirectoryURL: installDir
                )
                if status != 0 {
                    throw CLIError(message: "Failed to install oh-my-opencode. Try manually: npm install -g oh-my-opencode")
                }
            } else {
                throw CLIError(message: "Neither bun nor npm found in PATH. Install oh-my-opencode manually: bunx oh-my-opencode install")
            }
            FileHandle.standardError.write("oh-my-opencode plugin installed\n".data(using: .utf8)!)
        }

        // Ensure tmux mode is enabled in oh-my-opencode config.
        // Without this, the TmuxSessionManager won't spawn visual panes even though
        // $TMUX is set (tmux.enabled defaults to false).
        let omoConfigURL = shadowDir.appendingPathComponent("oh-my-opencode.json")
        var omoConfig: [String: Any]
        if let data = try? Data(contentsOf: omoConfigURL),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            omoConfig = existing
        } else {
            // Check if user has a config we symlinked, read from source
            let userOmoConfig = userDir.appendingPathComponent("oh-my-opencode.json")
            if let data = try? Data(contentsOf: userOmoConfig),
               let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                omoConfig = existing
                // Remove the symlink so we can write our own copy
                try? fm.removeItem(at: omoConfigURL)
            } else {
                omoConfig = [:]
            }
        }
        var tmuxConfig = (omoConfig["tmux"] as? [String: Any]) ?? [:]
        var needsWrite = false
        if tmuxConfig["enabled"] as? Bool != true {
            tmuxConfig["enabled"] = true
            needsWrite = true
        }
        // Lower the default min widths so agent panes spawn in normal-sized windows.
        // oh-my-openagent defaults: main_pane_min_width=120, agent_pane_min_width=40,
        // requiring 161+ columns. Most terminal windows are narrower.
        if tmuxConfig["main_pane_min_width"] == nil {
            tmuxConfig["main_pane_min_width"] = 60
            needsWrite = true
        }
        if tmuxConfig["agent_pane_min_width"] == nil {
            tmuxConfig["agent_pane_min_width"] = 30
            needsWrite = true
        }
        if tmuxConfig["main_pane_size"] == nil {
            tmuxConfig["main_pane_size"] = 50
            needsWrite = true
        }
        if needsWrite {
            omoConfig["tmux"] = tmuxConfig
            // Remove symlink if it exists (we need a real file)
            if let attrs = try? fm.attributesOfItem(atPath: omoConfigURL.path),
               attrs[.type] as? FileAttributeType == .typeSymbolicLink {
                try? fm.removeItem(at: omoConfigURL)
            }
            let output = try JSONSerialization.data(withJSONObject: omoConfig, options: [.prettyPrinted, .sortedKeys])
            try output.write(to: omoConfigURL, options: .atomic)
        }

        // Point OpenCode at the shadow config
        setenv("OPENCODE_CONFIG_DIR", shadowDir.path, 1)
    }

    func runOMO(
        commandArgs: [String],
        socketPath: String,
        explicitPassword: String?
    ) throws {
        try runAgentWrapper(
            commandArgs: commandArgs,
            socketPath: socketPath,
            explicitPassword: explicitPassword,
            config: AgentWrapperConfig(
                cmdLabel: "omo",
                execName: "opencode",
                resolveExecutable: { launcherEnvironment in
                    resolveExecutableInSearchPath("opencode", searchPath: launcherEnvironment["PATH"])
                },
                notFoundInstallHint: "npm install -g opencode-ai\n  # or\n  bun install -g opencode-ai",
                // Ensure oh-my-opencode plugin is registered and installed.
                preLaunch: { try self.omoEnsurePlugin() },
                createShimDir: { try self.createOMOShimDirectory() },
                beforeConfigure: { launcherEnvironment in
                    // oh-my-openagent needs the OpenCode API server running to attach
                    // subagent sessions to tmux panes. Prefer the historic default port
                    // when it is available, otherwise fall back to a free loopback port.
                    let openCodePort = omoResolvedPort(
                        commandArgs: commandArgs,
                        processEnvironment: launcherEnvironment
                    )
                    return ["OPENCODE_PORT": openCodePort]
                },
                tmuxPathPrefix: "cmux-omo",
                programaBinEnvVar: "PROGRAMA_OMO_PROGRAMA_BIN",
                termOverrideEnvVar: "PROGRAMA_OMO_TERM",
                extraEnvVars: { launcherEnvironment in
                    [(key: "OPENCODE_PORT", value: launcherEnvironment["OPENCODE_PORT"] ?? "")]
                },
                needsClaudeNodeOptionsRestore: false,
                buildLaunchArguments: { commandArgs, launcherEnvironment in
                    var effectiveArgs = commandArgs
                    if omoRequestedPort(from: commandArgs) == nil {
                        effectiveArgs.append("--port")
                        effectiveArgs.append(launcherEnvironment["OPENCODE_PORT"] ?? "")
                    }
                    return effectiveArgs
                },
                execFailureHint: "Is opencode installed? Install with:\n  npm install -g opencode-ai"
            )
        )
    }

    // MARK: - programa omx (Oh My Codex)

    private func createOMXShimDirectory() throws -> URL {
        try createVFlagTmuxShimDirectory(
            directoryName: "omx-bin",
            programaBinEnvVar: "PROGRAMA_OMX_PROGRAMA_BIN"
        )
    }

    func runOMX(
        commandArgs: [String],
        socketPath: String,
        explicitPassword: String?
    ) throws {
        try runAgentWrapper(
            commandArgs: commandArgs,
            socketPath: socketPath,
            explicitPassword: explicitPassword,
            config: AgentWrapperConfig(
                cmdLabel: "omx",
                execName: "omx",
                resolveExecutable: { launcherEnvironment in
                    resolveExecutableInSearchPath("omx", searchPath: launcherEnvironment["PATH"])
                },
                notFoundInstallHint: "npm install -g oh-my-codex",
                preLaunch: nil,
                createShimDir: { try self.createOMXShimDirectory() },
                beforeConfigure: nil,
                tmuxPathPrefix: "cmux-omx",
                programaBinEnvVar: "PROGRAMA_OMX_PROGRAMA_BIN",
                termOverrideEnvVar: "PROGRAMA_OMX_TERM",
                extraEnvVars: { _ in [] },
                needsClaudeNodeOptionsRestore: false,
                buildLaunchArguments: { commandArgs, _ in commandArgs },
                execFailureHint: "Is oh-my-codex installed? Install with:\n  npm install -g oh-my-codex"
            )
        )
    }

    // MARK: - programa omc (Oh My Claude Code)

    private func createOMCShimDirectory() throws -> URL {
        try createVFlagTmuxShimDirectory(
            directoryName: "omc-bin",
            programaBinEnvVar: "PROGRAMA_OMC_PROGRAMA_BIN"
        )
    }

    func runOMC(
        commandArgs: [String],
        socketPath: String,
        explicitPassword: String?
    ) throws {
        try runAgentWrapper(
            commandArgs: commandArgs,
            socketPath: socketPath,
            explicitPassword: explicitPassword,
            config: AgentWrapperConfig(
                cmdLabel: "omc",
                execName: "omc",
                resolveExecutable: { launcherEnvironment in
                    resolveExecutableInSearchPath("omc", searchPath: launcherEnvironment["PATH"])
                },
                notFoundInstallHint: "npm install -g oh-my-claude-sisyphus",
                preLaunch: nil,
                createShimDir: { try self.createOMCShimDirectory() },
                beforeConfigure: nil,
                tmuxPathPrefix: "cmux-omc",
                programaBinEnvVar: "PROGRAMA_OMC_PROGRAMA_BIN",
                termOverrideEnvVar: "PROGRAMA_OMC_TERM",
                extraEnvVars: { _ in [] },
                // omc wraps Claude Code, so it needs the same NODE_OPTIONS restore module.
                needsClaudeNodeOptionsRestore: true,
                buildLaunchArguments: { commandArgs, _ in commandArgs },
                execFailureHint: "Is oh-my-claude-sisyphus installed? Install with:\n  npm install -g oh-my-claude-sisyphus"
            )
        )
    }
}
