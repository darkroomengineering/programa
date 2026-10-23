import Foundation
import Darwin

extension ProgramaCLI {
    private func isProgramaClaudeWrapper(at path: String) -> Bool {
        guard let data = FileManager.default.contents(atPath: path) else { return false }
        let prefixData = data.prefix(512)
        guard let prefix = String(data: prefixData, encoding: .utf8) else { return false }
        return prefix.contains("programa claude wrapper - injects hooks and session tracking")
    }

    func resolveExecutableInSearchPath(
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

    func resolveClaudeExecutable(searchPath: String?) -> String? {
        resolveExecutableInSearchPath(
            "claude",
            searchPath: searchPath,
            skip: { self.isProgramaClaudeWrapper(at: $0) }
        )
    }

    /// Resolves the `codex` CLI executable from PATH. Unlike Claude, Programa does not
    /// ship a codex wrapper, so no skip predicate is needed.
    func resolveCodexExecutable(searchPath: String?) -> String? {
        resolveExecutableInSearchPath("codex", searchPath: searchPath)
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

    /// Configures the tmux-compat environment for an agent wrapper command
    /// (claude-teams), then optionally layers on the NODE_OPTIONS restore
    /// module (silently skipped if the module file can't be created).
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
            .appendingPathComponent("programa-claude-node-options", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: nil)
        let restoreModuleURL = root.appendingPathComponent("restore-node-options.cjs", isDirectory: false)
        try writeShimIfChanged(Self.claudeNodeOptionsRestoreModule, to: restoreModuleURL)
        return restoreModuleURL
    }

    /// Everything that differs between agent wrapper commands. runAgentWrapper
    /// implements their shared shape once; each run* function just builds a config.
    private struct AgentWrapperConfig {
        /// Bare command name: used for the execvp fallback and error messages
        /// (e.g. "claude").
        let execName: String
        /// Resolves the real executable path given the launcher environment
        /// (already carrying PROGRAMA_SOCKET/PROGRAMA_SOCKET_PATH/
        /// PROGRAMA_SOCKET_PASSWORD).
        let resolveExecutable: (_ launcherEnvironment: [String: String]) -> String?
        /// Creates the tool's shim directory.
        let createShimDir: () throws -> URL
        let tmuxPathPrefix: String
        let programaBinEnvVar: String
        let termOverrideEnvVar: String
        /// Extra env vars to set, computed from the launcher environment.
        let extraEnvVars: (_ launcherEnvironment: [String: String]) -> [(key: String, value: String)]
        /// Whether the wrapped tool is Claude Code and needs the NODE_OPTIONS
        /// restore module configured.
        let needsClaudeNodeOptionsRestore: Bool
        /// Transforms the raw CLI args before exec (claude-teams injects
        /// --teammate-mode).
        let buildLaunchArguments: (_ commandArgs: [String], _ launcherEnvironment: [String: String]) -> [String]
    }

    /// Implements the shared shape of `programa claude-teams`: build the
    /// launcher environment, resolve the real executable, create shim scripts,
    /// gather focused-terminal context, configure environment variables, and exec.
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

        let shimDirectory = try config.createShimDir()
        let executablePath = resolvedExecutableURL()?.path ?? (args.first ?? "programa")
        let focusedContext = tmuxCompatFocusedContext(
            processEnvironment: launcherEnvironment,
            explicitPassword: explicitPassword
        )

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
        throw CLIError(message: "Failed to launch \(config.execName): \(String(cString: strerror(code)))")
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
                execName: "claude",
                resolveExecutable: { launcherEnvironment in
                    let bundledClaudePath = resolvedExecutableURL()?
                        .deletingLastPathComponent()
                        .appendingPathComponent("claude", isDirectory: false)
                        .path
                    return resolveClaudeExecutable(searchPath: launcherEnvironment["PATH"])
                        ?? {
                            guard let bundledClaudePath,
                                  FileManager.default.isExecutableFile(atPath: bundledClaudePath) else { return nil }
                            return bundledClaudePath
                        }()
                },
                createShimDir: { try self.createClaudeTeamsShimDirectory() },
                tmuxPathPrefix: "programa-claude-teams",
                programaBinEnvVar: "PROGRAMA_CLAUDE_TEAMS_PROGRAMA_BIN",
                termOverrideEnvVar: "PROGRAMA_CLAUDE_TEAMS_TERM",
                extraEnvVars: { _ in
                    [(key: "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS", value: "1")]
                },
                needsClaudeNodeOptionsRestore: true,
                buildLaunchArguments: { commandArgs, _ in
                    claudeTeamsLaunchArguments(commandArgs: commandArgs)
                }
            )
        )
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

    func agentWrapperSubcommandUsage(_ command: String) -> String? {
        switch command {
        case "claude-teams":
            return String(localized: "cli.claude-teams.usage", defaultValue: """
            Usage: programa claude-teams [claude-args...]

            Launch Claude Code with agent teams enabled.

            This command:
              - defaults Claude teammate mode to auto
              - sets a tmux-like environment so Claude can open Programa helper workspaces
              - sets CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1
              - prepends a private tmux shim to PATH
              - forwards all remaining arguments to claude

            The tmux shim turns supported tmux window/pane commands into nested helper
            workspaces in the current Programa window.

            Examples:
              programa claude-teams
              programa claude-teams --continue
              programa claude-teams --model sonnet
            """)
        default:
            return nil
        }
    }
}
