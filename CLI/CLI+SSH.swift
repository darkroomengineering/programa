import Foundation
import CryptoKit
import Darwin
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
#if canImport(Security)
import Security
#endif

extension ProgramaCLI {
    private func generateRemoteRelayPort() -> Int {
        // Random port in the ephemeral range (49152-65535)
        Int.random(in: 49152...65535)
    }

    private func randomHex(byteCount: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw CLIError(message: "failed to generate SSH relay credential")
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    func runSSH(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let sshStartedAt = Date()
        // Use the socket path from this invocation (supports --socket overrides).
        let localSocketPath = client.socketPath
        let remoteRelayPort = generateRemoteRelayPort()
        let relayID = UUID().uuidString.lowercased()
        let relayToken = try randomHex(byteCount: 32)
        let sshOptions = try parseSSHCommandOptions(commandArgs, localSocketPath: localSocketPath, remoteRelayPort: remoteRelayPort)
        func logSSHTiming(_ stage: String, extra: String = "") {
            let elapsedMs = Int(Date().timeIntervalSince(sshStartedAt) * 1000)
            let suffix = extra.isEmpty ? "" : " \(extra)"
            cliDebugLog(
                "cli.ssh.timing target=\(sshOptions.destination) relayPort=\(sshOptions.remoteRelayPort) " +
                "stage=\(stage) elapsedMs=\(elapsedMs)\(suffix)"
            )
        }

        logSSHTiming("parsed")
        let terminfoSource = localXtermGhosttyTerminfoSource()
        cliDebugLog(
            "cli.ssh.timing target=\(sshOptions.destination) relayPort=\(sshOptions.remoteRelayPort) " +
            "stage=terminfo elapsedMs=0 mode=deferred term=xterm-256color " +
            "source=\(terminfoSource == nil ? 0 : 1)"
        )
        let shellFeaturesValue = scopedGhosttyShellFeaturesValue()
        let remoteSSHOptions = effectiveSSHOptions(
            sshOptions.sshOptions,
            remoteRelayPort: sshOptions.remoteRelayPort
        )
        let initialSSHCommand = buildSSHCommandText(sshOptions)
        let remoteTerminalBootstrapScript = sshOptions.extraArguments.isEmpty
            ? buildInteractiveRemoteShellScript(
                remoteRelayPort: sshOptions.remoteRelayPort,
                shellFeatures: shellFeaturesValue,
                terminfoSource: terminfoSource
            )
            : nil
        let remoteTerminalSSHCommand = buildSSHCommandText(
            sshOptions,
            remoteBootstrapScript: remoteTerminalBootstrapScript
        )
        let deferredRemoteReconnectToken = UUID().uuidString.lowercased()
        let deferredRemoteReconnectCommand = deferredRemoteReconnectLocalCommand(
            in: remoteSSHOptions,
            localCLIPath: resolvedExecutableURL()?.path,
            foregroundAuthToken: deferredRemoteReconnectToken
        )
        let configuredForegroundAuthToken = deferredRemoteReconnectCommand == nil ? nil : deferredRemoteReconnectToken
        let startupInitialSSHCommand = buildSSHCommandText(
            sshOptions,
            localCommand: deferredRemoteReconnectCommand
        )
        let startupRemoteTerminalSSHCommand = buildSSHCommandText(
            sshOptions,
            remoteBootstrapScript: remoteTerminalBootstrapScript,
            localCommand: deferredRemoteReconnectCommand
        )
        let initialSSHStartupCommand: String
        let remoteTerminalSSHStartupCommand: String
        if let remoteTerminalBootstrapScript, !remoteTerminalBootstrapScript.isEmpty {
            let bootstrapSSHStartupCommand = try buildBootstrapSSHStartupCommand(
                options: sshOptions,
                remoteBootstrapScript: remoteTerminalBootstrapScript,
                shellFeatures: shellFeaturesValue,
                remoteRelayPort: sshOptions.remoteRelayPort,
                localCommand: deferredRemoteReconnectCommand
            )
            initialSSHStartupCommand = bootstrapSSHStartupCommand
            remoteTerminalSSHStartupCommand = bootstrapSSHStartupCommand
        } else {
            initialSSHStartupCommand = try buildSSHStartupCommand(
                sshCommand: startupInitialSSHCommand,
                shellFeatures: "",
                remoteRelayPort: sshOptions.remoteRelayPort
            )
            remoteTerminalSSHStartupCommand = try buildSSHStartupCommand(
                sshCommand: startupRemoteTerminalSSHCommand,
                shellFeatures: shellFeaturesValue,
                remoteRelayPort: sshOptions.remoteRelayPort
            )
        }
        cliDebugLog(
            "cli.ssh.start target=\(sshOptions.destination) port=\(sshOptions.port.map(String.init) ?? "nil") " +
            "relayPort=\(sshOptions.remoteRelayPort) localSocket=\(sshOptions.localSocketPath) " +
            "controlPath=\(sshOptionValue(named: "ControlPath", in: remoteSSHOptions) ?? "nil") " +
            "workspaceName=\(sshOptions.workspaceName?.replacingOccurrences(of: " ", with: "_") ?? "nil") " +
            "extraArgs=\(sshOptions.extraArguments.count)"
        )

        let workspaceCreateParams: [String: Any] = [
            "initial_command": initialSSHStartupCommand,
        ]

        let workspaceCreateStartedAt = Date()
        let workspaceCreate = try client.sendV2(method: "workspace.create", params: workspaceCreateParams)
        guard let workspaceId = workspaceCreate["workspace_id"] as? String, !workspaceId.isEmpty else {
            throw CLIError(message: "workspace.create did not return workspace_id")
        }
        let workspaceWindowId = (workspaceCreate["window_id"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        cliDebugLog(
            "cli.ssh.workspace.created workspace=\(String(workspaceId.prefix(8))) " +
            "window=\(workspaceWindowId.map { String($0.prefix(8)) } ?? "nil")"
        )
        cliDebugLog(
            "cli.ssh.timing target=\(sshOptions.destination) relayPort=\(sshOptions.remoteRelayPort) " +
            "workspace=\(String(workspaceId.prefix(8))) stage=workspace.create elapsedMs=\(Int(Date().timeIntervalSince(workspaceCreateStartedAt) * 1000))"
        )
        let configuredPayload: [String: Any]
        do {
            if let workspaceName = sshOptions.workspaceName?.trimmingCharacters(in: .whitespacesAndNewlines),
               !workspaceName.isEmpty {
                _ = try client.sendV2(method: "workspace.rename", params: [
                    "workspace_id": workspaceId,
                    "title": workspaceName,
                ])
            }

            var configureParams: [String: Any] = [
                "workspace_id": workspaceId,
                "destination": sshOptions.destination,
                "auto_connect": deferredRemoteReconnectCommand == nil,
            ]
            if let configuredForegroundAuthToken {
                configureParams["foreground_auth_token"] = configuredForegroundAuthToken
            }
            if let port = sshOptions.port {
                configureParams["port"] = port
            }
            if let identityFile = normalizedSSHIdentityPath(sshOptions.identityFile) {
                configureParams["identity_file"] = identityFile
            }
            if !remoteSSHOptions.isEmpty {
                configureParams["ssh_options"] = remoteSSHOptions
            }
            if sshOptions.remoteRelayPort > 0 {
                configureParams["relay_port"] = sshOptions.remoteRelayPort
                configureParams["relay_id"] = relayID
                configureParams["relay_token"] = relayToken
                configureParams["local_socket_path"] = sshOptions.localSocketPath
            }
            configureParams["terminal_startup_command"] = remoteTerminalSSHStartupCommand

            cliDebugLog(
                "cli.ssh.remote.configure workspace=\(String(workspaceId.prefix(8))) " +
                "target=\(sshOptions.destination) relayPort=\(sshOptions.remoteRelayPort) " +
                "controlPath=\(sshOptionValue(named: "ControlPath", in: remoteSSHOptions) ?? "nil") " +
                "deferredReconnect=\(deferredRemoteReconnectCommand == nil ? 0 : 1) " +
                "sshOptions=\(remoteSSHOptions.joined(separator: "|"))"
            )
            let configureStartedAt = Date()
            configuredPayload = try client.sendV2(method: "workspace.remote.configure", params: configureParams)
            var selectParams: [String: Any] = ["workspace_id": workspaceId]
            if let workspaceWindowId, !workspaceWindowId.isEmpty {
                selectParams["window_id"] = workspaceWindowId
            }
            // `programa ssh` is an explicit "open this remote workspace now" action,
            // so we intentionally select the newly created workspace after wiring
            // up the remote connection — unless --no-focus is passed.
            if !sshOptions.noFocus {
                _ = try client.sendV2(method: "workspace.select", params: selectParams)
            }
            let remoteState = ((configuredPayload["remote"] as? [String: Any])?["state"] as? String) ?? "unknown"
            cliDebugLog(
                "cli.ssh.remote.configure.ok workspace=\(String(workspaceId.prefix(8))) state=\(remoteState)"
            )
            cliDebugLog(
                "cli.ssh.timing target=\(sshOptions.destination) relayPort=\(sshOptions.remoteRelayPort) " +
                "workspace=\(String(workspaceId.prefix(8))) stage=workspace.remote.configure elapsedMs=\(Int(Date().timeIntervalSince(configureStartedAt) * 1000))"
            )
        } catch {
            cliDebugLog(
                "cli.ssh.remote.configure.error workspace=\(String(workspaceId.prefix(8))) error=\(String(describing: error))"
            )
            do {
                _ = try client.sendV2(method: "workspace.close", params: ["workspace_id": workspaceId])
            } catch {
                let warning = "Warning: failed to rollback workspace \(workspaceId): \(error)\n"
                FileHandle.standardError.write(Data(warning.utf8))
            }
            throw error
        }

        var payload = configuredPayload

        payload["ssh_command"] = initialSSHCommand
        payload["ssh_startup_command"] = initialSSHStartupCommand
        payload["ssh_terminal_command"] = remoteTerminalSSHCommand
        payload["ssh_terminal_startup_command"] = remoteTerminalSSHStartupCommand
        payload["ssh_env_overrides"] = [
            "GHOSTTY_SHELL_FEATURES": shellFeaturesValue,
        ]
        payload["remote_relay_port"] = remoteRelayPort
        logSSHTiming("complete", extra: "workspace=\(String(workspaceId.prefix(8)))")
        if jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
        } else {
            let workspaceHandle = formatHandle(payload, kind: "workspace", idFormat: idFormat) ?? workspaceId
            let remote = payload["remote"] as? [String: Any]
            let state = (remote?["state"] as? String) ?? "unknown"
            print("OK workspace=\(workspaceHandle) target=\(sshOptions.destination) state=\(state)")
        }
    }

    private func parseSSHCommandOptions(_ commandArgs: [String], localSocketPath: String = "", remoteRelayPort: Int = 0) throws -> SSHCommandOptions {
        var destination: String?
        var port: Int?
        var identityFile: String?
        var workspaceName: String?
        var noFocus = false
        var sshOptions: [String] = []
        var extraArguments: [String] = []

        var passthrough = false
        var index = 0
        while index < commandArgs.count {
            let arg = commandArgs[index]
            if passthrough {
                extraArguments.append(arg)
                index += 1
                continue
            }

            switch arg {
            case "--":
                passthrough = true
                index += 1
            case "--port":
                guard index + 1 < commandArgs.count else {
                    throw CLIError(message: "ssh: --port requires a value")
                }
                guard let parsed = Int(commandArgs[index + 1]), parsed > 0, parsed <= 65535 else {
                    throw CLIError(message: "ssh: --port must be 1-65535")
                }
                port = parsed
                index += 2
            case "--identity":
                guard index + 1 < commandArgs.count else {
                    throw CLIError(message: "ssh: --identity requires a path")
                }
                identityFile = commandArgs[index + 1]
                index += 2
            case "--name":
                guard index + 1 < commandArgs.count else {
                    throw CLIError(message: "ssh: --name requires a workspace title")
                }
                workspaceName = commandArgs[index + 1]
                index += 2
            case "--no-focus":
                noFocus = true
                index += 1
            case "--ssh-option":
                guard index + 1 < commandArgs.count else {
                    throw CLIError(message: "ssh: --ssh-option requires a value")
                }
                let value = commandArgs[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty {
                    sshOptions.append(value)
                }
                index += 2
            default:
                if arg.hasPrefix("--") {
                    throw CLIError(message: "ssh: unknown flag '\(arg)'")
                }
                if destination == nil {
                    if arg.hasPrefix("-") {
                        throw CLIError(
                            message: "ssh: destination must be <user@host>. Use --port/--identity/--ssh-option for SSH flags and `--` for remote command args."
                        )
                    }
                    destination = arg
                } else {
                    extraArguments.append(arg)
                }
                index += 1
            }
        }

        guard let destination else {
            throw CLIError(message: "ssh requires a destination (example: programa ssh user@host)")
        }

        // #4948: accept bracketed IPv6 destinations (e.g. `[::1]`, `user@[2001:db8::1]:2222`).
        // ssh needs the host unbracketed; an inline `:port` after the bracket maps to --port.
        // Only bracketed forms are rewritten — plain `user@host` and bare IPv6 pass through.
        let (resolvedDestination, inlinePort) = Self.normalizeSSHDestination(destination)
        if let inlinePort, port == nil {
            port = inlinePort
        }

        return SSHCommandOptions(
            destination: resolvedDestination,
            port: port,
            identityFile: identityFile,
            workspaceName: workspaceName,
            noFocus: noFocus,
            sshOptions: sshOptions,
            extraArguments: extraArguments,
            localSocketPath: localSocketPath,
            remoteRelayPort: remoteRelayPort
        )
    }

    /// Normalizes an SSH destination: unwraps a bracketed IPv6 literal and extracts an
    /// inline port. Returns `(destination, port?)`. Only bracketed forms are altered;
    /// `user@host`, plain hostnames, and bare IPv6 (`2001:db8::1`) pass through unchanged.
    static func normalizeSSHDestination(_ raw: String) -> (String, Int?) {
        let userPrefix: String
        let hostPart: String
        if let atIdx = raw.firstIndex(of: "@") {
            userPrefix = String(raw[...atIdx]) // includes the trailing "@"
            hostPart = String(raw[raw.index(after: atIdx)...])
        } else {
            userPrefix = ""
            hostPart = raw
        }
        guard hostPart.hasPrefix("["), let closeIdx = hostPart.firstIndex(of: "]") else {
            return (raw, nil)
        }
        let inner = String(hostPart[hostPart.index(after: hostPart.startIndex)..<closeIdx])
        let afterBracket = String(hostPart[hostPart.index(after: closeIdx)...])
        var port: Int?
        if afterBracket.hasPrefix(":") {
            guard let parsed = Int(afterBracket.dropFirst()), parsed > 0, parsed <= 65535 else {
                return (raw, nil) // invalid inline port — leave unchanged so ssh surfaces a clear error
            }
            port = parsed
        } else if !afterBracket.isEmpty {
            return (raw, nil) // unexpected trailing content — don't touch
        }
        return (userPrefix + inner, port)
    }

    func buildSSHCommandText(
        _ options: SSHCommandOptions,
        remoteBootstrapScript: String? = nil,
        localCommand: String? = nil
    ) -> String {
        var parts = baseSSHArguments(options, localCommand: localCommand)
        let trimmedRemoteBootstrap = remoteBootstrapScript?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if options.extraArguments.isEmpty {
            if let trimmedRemoteBootstrap, !trimmedRemoteBootstrap.isEmpty {
                let remoteCommand = sshPercentEscapedRemoteCommand(
                    encodedRemoteBootstrapCommand(
                        trimmedRemoteBootstrap,
                        remoteRelayPort: options.remoteRelayPort
                    )
                )
                parts += ["-o", "RemoteCommand=\(remoteCommand)"]
            }
            if !hasSSHOptionKey(options.sshOptions, key: "RequestTTY") {
                parts.append("-tt")
            }
            parts.append(options.destination)
        } else {
            parts.append(options.destination)
            parts.append(contentsOf: options.extraArguments)
        }
        return parts.map(shellQuote).joined(separator: " ")
    }

    func buildBootstrapSSHStartupCommand(
        options: SSHCommandOptions,
        remoteBootstrapScript: String,
        shellFeatures: String,
        remoteRelayPort: Int,
        localCommand: String? = nil
    ) throws -> String {
        let commandSnippet = buildSSHBootstrapCommandSnippet(
            options: options,
            remoteBootstrapScript: remoteBootstrapScript,
            localCommand: localCommand
        )
        return try buildSSHStartupCommand(
            sshCommand: commandSnippet,
            shellFeatures: shellFeatures,
            remoteRelayPort: remoteRelayPort,
            isShellSnippet: true
        )
    }

    private func buildSSHBootstrapCommandSnippet(
        options: SSHCommandOptions,
        remoteBootstrapScript: String,
        localCommand: String? = nil
    ) -> String {
        let encodedBootstrapScript = Data(remoteBootstrapScript.utf8).base64EncodedString()
        let installSSHPrefix = baseSSHArguments(options, localCommand: localCommand).map(shellQuote).joined(separator: " ")
        let sessionSSHPrefix = baseSSHArguments(options).map(shellQuote).joined(separator: " ")
        let remoteCommandTemplate = sshPercentEscapedRemoteCommand(
            stagedRemoteBootstrapCommandShell(
                remoteRelayPort: options.remoteRelayPort
            )
        )
        let remoteBootstrapInstallCommand = "/bin/sh -c " + shellQuote(
            remoteBootstrapInstallShell(remoteRelayPort: options.remoteRelayPort)
        )
        var lines: [String] = [
            "programa_workspace_id=\"${PROGRAMA_WORKSPACE_ID:-}\"",
            "programa_surface_id=\"${PROGRAMA_SURFACE_ID:-}\"",
            "programa_remote_bootstrap_b64=\(shellQuote(encodedBootstrapScript))",
            "programa_remote_bootstrap=\"$(printf %s \"$programa_remote_bootstrap_b64\" | base64 -d 2>/dev/null || printf %s \"$programa_remote_bootstrap_b64\" | base64 -D 2>/dev/null)\"",
            "programa_remote_bootstrap=\"$(printf '%s' \"$programa_remote_bootstrap\" | sed \"s/__PROGRAMA_WORKSPACE_ID__/$programa_workspace_id/g; s/__PROGRAMA_SURFACE_ID__/$programa_surface_id/g\")\"",
            "if ! printf '%s' \"$programa_remote_bootstrap\" | command \(installSSHPrefix) -T \(shellQuote(options.destination)) \(shellQuote(remoteBootstrapInstallCommand)); then",
            "  exit 1",
            "fi",
            "programa_remote_command_template=\(shellQuote(remoteCommandTemplate))",
            "programa_remote_command=\"$(printf '%s' \"$programa_remote_command_template\" | sed \"s/__PROGRAMA_WORKSPACE_ID__/$programa_workspace_id/g; s/__PROGRAMA_SURFACE_ID__/$programa_surface_id/g\")\"",
        ]

        var sshInvocation = "command \(sessionSSHPrefix) -o \"RemoteCommand=$programa_remote_command\""
        if !hasSSHOptionKey(options.sshOptions, key: "RequestTTY") {
            sshInvocation += " -tt"
        }
        sshInvocation += " " + shellQuote(options.destination)
        lines.append(sshInvocation)
        return lines.joined(separator: "\n")
    }

    private func stagedRemoteBootstrapCommandShell(
        remoteRelayPort: Int
    ) -> String {
        var lines = remoteBootstrapTTYCaptureLines(remoteRelayPort: remoteRelayPort, includeRelayRPC: true)
        lines.append("/bin/sh \"$HOME/.programa/relay/\(remoteRelayPort).bootstrap.sh\"")
        return lines.joined(separator: "\n")
    }

    private func remoteBootstrapInstallShell(remoteRelayPort: Int) -> String {
        [
            "set -eu",
            "umask 077",
            "programa_bootstrap_path=\"$HOME/.programa/relay/\(remoteRelayPort).bootstrap.sh\"",
            "mkdir -p \"$HOME/.programa/relay\"",
            "cat > \"$programa_bootstrap_path\"",
            "chmod 700 \"$programa_bootstrap_path\" >/dev/null 2>&1 || true",
        ].joined(separator: "\n")
    }

    private func runtimeEncodedRemoteBootstrapCommandShell(
        base64Placeholder: String,
        remoteRelayPort: Int
    ) -> String {
        var lines = remoteBootstrapTTYCaptureLines(remoteRelayPort: remoteRelayPort, includeRelayRPC: false)
        lines += [
            "programa_tmp=$(mktemp \"${TMPDIR:-/tmp}/cmux-ssh-bootstrap.XXXXXX\") || exit 1",
            "(printf %s '\(base64Placeholder)' | base64 -d 2>/dev/null || printf %s '\(base64Placeholder)' | base64 -D 2>/dev/null) > \"$programa_tmp\" || { rm -f \"$programa_tmp\"; exit 1; }",
            "chmod 700 \"$programa_tmp\" >/dev/null 2>&1 || true",
            "/bin/sh \"$programa_tmp\"",
            "programa_status=$?",
            "rm -f \"$programa_tmp\"",
            "exit $programa_status",
        ]
        return lines.joined(separator: "\n")
    }

    private func remoteBootstrapTTYCaptureLines(
        remoteRelayPort: Int,
        includeRelayRPC: Bool
    ) -> [String] {
        guard remoteRelayPort > 0 else { return [] }

        var lines: [String] = [
            "programa_bootstrap_tty=\"$(tty 2>/dev/null || true)\"",
            "programa_bootstrap_tty=\"${programa_bootstrap_tty##*/}\"",
            "if [ -n \"$programa_bootstrap_tty\" ] && [ \"$programa_bootstrap_tty\" != \"not a tty\" ]; then",
            "  mkdir -p \"$HOME/.programa/relay\" >/dev/null 2>&1 || true",
            "  printf '%s' \"$programa_bootstrap_tty\" > \"$HOME/.programa/relay/\(remoteRelayPort).tty\" 2>/dev/null || true",
            "  export PROGRAMA_BOOTSTRAP_TTY=\"$programa_bootstrap_tty\"",
        ]

        if includeRelayRPC {
            lines += [
                "  programa_relay_cli=\"$HOME/.programa/bin/programa\"",
                "  if [ ! -x \"$programa_relay_cli\" ]; then programa_relay_cli=\"$(command -v programa 2>/dev/null || true)\"; fi",
                "  if [ -n \"$programa_relay_cli\" ]; then",
                "    programa_relay_report_tty='{\"workspace_id\":\"__PROGRAMA_WORKSPACE_ID__\",\"tty_name\":\"'$programa_bootstrap_tty'\"}'",
                "    programa_relay_ports_kick='{\"workspace_id\":\"__PROGRAMA_WORKSPACE_ID__\",\"reason\":\"command\"}'",
                "    if [ -n \"__PROGRAMA_SURFACE_ID__\" ]; then",
                "      programa_relay_report_tty='{\"workspace_id\":\"__PROGRAMA_WORKSPACE_ID__\",\"surface_id\":\"__PROGRAMA_SURFACE_ID__\",\"tty_name\":\"'$programa_bootstrap_tty'\"}'",
                "      programa_relay_ports_kick='{\"workspace_id\":\"__PROGRAMA_WORKSPACE_ID__\",\"surface_id\":\"__PROGRAMA_SURFACE_ID__\",\"reason\":\"command\"}'",
                "    fi",
                "    PROGRAMA_SOCKET_PATH=\"127.0.0.1:\(remoteRelayPort)\" PROGRAMA_SOCKET=\"127.0.0.1:\(remoteRelayPort)\" \"$programa_relay_cli\" rpc surface.report_tty \"$programa_relay_report_tty\" >/dev/null 2>&1 || true",
                "    PROGRAMA_SOCKET_PATH=\"127.0.0.1:\(remoteRelayPort)\" PROGRAMA_SOCKET=\"127.0.0.1:\(remoteRelayPort)\" \"$programa_relay_cli\" rpc surface.ports_kick \"$programa_relay_ports_kick\" >/dev/null 2>&1 || true",
                "    unset programa_relay_cli programa_relay_report_tty programa_relay_ports_kick",
                "  fi",
            ]
        }

        lines.append("fi")
        return lines
    }

    private func effectiveSSHOptions(_ options: [String], remoteRelayPort: Int? = nil) -> [String] {
        var merged = sshOptionsWithControlSocketDefaults(options, remoteRelayPort: remoteRelayPort)
        if !hasSSHOptionKey(merged, key: "StrictHostKeyChecking") {
            merged.append("StrictHostKeyChecking=accept-new")
        }
        return merged
    }

    func buildInteractiveRemoteShellScript(
        remoteRelayPort: Int,
        shellFeatures: String,
        terminfoSource: String? = nil
    ) -> String {
        let remoteTerminalLines = interactiveRemoteTerminalSetupLines(terminfoSource: terminfoSource)
        let remoteEnvExportLines = interactiveRemoteShellExportLines(shellFeatures: shellFeatures)
        let shellStateDir = shellStateDirForRemoteRelayPort(remoteRelayPort)
        let remoteCallerExportLines = [
            "if [ -n '__PROGRAMA_WORKSPACE_ID__' ]; then export PROGRAMA_WORKSPACE_ID='__PROGRAMA_WORKSPACE_ID__'; fi",
            "if [ -n '__PROGRAMA_WORKSPACE_ID__' ]; then export PROGRAMA_TAB_ID='__PROGRAMA_WORKSPACE_ID__'; fi",
            "if [ -n '__PROGRAMA_SURFACE_ID__' ]; then export PROGRAMA_SURFACE_ID='__PROGRAMA_SURFACE_ID__'; export PROGRAMA_PANEL_ID='__PROGRAMA_SURFACE_ID__'; fi",
        ]
        let relaySocket = remoteRelayPort > 0 ? "127.0.0.1:\(remoteRelayPort)" : nil
        var commonShellExportLines = remoteTerminalLines
        commonShellExportLines.append(contentsOf: remoteEnvExportLines)
        commonShellExportLines.append("export PATH=\"$HOME/.programa/bin:$PATH\"")
        commonShellExportLines.append("export PROGRAMA_BUNDLED_CLI_PATH=\"$HOME/.programa/bin/programa\"")
        commonShellExportLines.append("export PROGRAMA_SHELL_INTEGRATION_DIR=\"\(shellStateDir)\"")
        if let relaySocket {
            commonShellExportLines.append("export PROGRAMA_SOCKET_PATH=\(relaySocket)")
            commonShellExportLines.append("export PROGRAMA_SOCKET=\(relaySocket)")
        }
        commonShellExportLines.append(contentsOf: remoteCallerExportLines)
        commonShellExportLines.append(contentsOf: [
            "hash -r >/dev/null 2>&1 || true",
            "rehash >/dev/null 2>&1 || true",
        ])
        var zshShellLines = commonShellExportLines
        zshShellLines.append(
            #"if [ "${PROGRAMA_SHELL_INTEGRATION:-1}" != "0" ] && [ -r "${PROGRAMA_SHELL_INTEGRATION_DIR}/programa-zsh-integration.zsh" ]; then . "${PROGRAMA_SHELL_INTEGRATION_DIR}/programa-zsh-integration.zsh"; fi"#
        )
        var bashShellLines = commonShellExportLines
        bashShellLines.append(
            #"if [ "${PROGRAMA_SHELL_INTEGRATION:-1}" != "0" ] && [ -r "${PROGRAMA_SHELL_INTEGRATION_DIR}/programa-bash-integration.bash" ]; then . "${PROGRAMA_SHELL_INTEGRATION_DIR}/programa-bash-integration.bash"; fi"#
        )
        let zshBootstrap = RemoteRelayZshBootstrap(shellStateDir: shellStateDir)
        let zshEnvLines = zshBootstrap.zshEnvLines
        let zshProfileLines = zshBootstrap.zshProfileLines
        let zshRCLines = zshBootstrap.zshRCLines(commonShellLines: zshShellLines)
        let zshLoginLines = zshBootstrap.zshLoginLines
        let bundledZshIntegration = bundledShellIntegrationScript(named: "programa-zsh-integration.zsh")
        let bundledBashIntegration = bundledShellIntegrationScript(named: "programa-bash-integration.bash")
        let bashRCLines = [
            "if [ -f \"$HOME/.bash_profile\" ]; then . \"$HOME/.bash_profile\"; elif [ -f \"$HOME/.bash_login\" ]; then . \"$HOME/.bash_login\"; elif [ -f \"$HOME/.profile\" ]; then . \"$HOME/.profile\"; fi",
            "[ -f \"$HOME/.bashrc\" ] && . \"$HOME/.bashrc\"",
        ] + bashShellLines
        let relayWarmupLines = interactiveRemoteRelayWarmupLines(remoteRelayPort: remoteRelayPort)

        var outerLines: [String] = [
            "mkdir -p \"$HOME/.programa/relay\"",
            "programa_shell_dir=\"\(shellStateDir)\"",
            "mkdir -p \"$programa_shell_dir\"",
        ]
        if let bundledZshIntegration {
            outerLines += [
                "cat > \"$programa_shell_dir/programa-zsh-integration.zsh\" <<'CMUXCMUXZSH'",
                bundledZshIntegration,
                "CMUXCMUXZSH",
            ]
        }
        if let bundledBashIntegration {
            outerLines += [
                "cat > \"$programa_shell_dir/programa-bash-integration.bash\" <<'CMUXCMUXBASH'",
                bundledBashIntegration,
                "CMUXCMUXBASH",
            ]
        }
        outerLines.append(contentsOf: commonShellExportLines)
        outerLines += [
            "PROGRAMA_LOGIN_SHELL=\"${SHELL:-/bin/zsh}\"",
            "case \"${PROGRAMA_LOGIN_SHELL##*/}\" in",
            "  zsh)",
            "    cat > \"$programa_shell_dir/.zshenv\" <<'CMUXZSHENV'",
        ]
        outerLines.append(contentsOf: zshEnvLines)
        outerLines += [
            "CMUXZSHENV",
            "    cat > \"$programa_shell_dir/.zprofile\" <<'CMUXZSHPROFILE'",
        ]
        outerLines.append(contentsOf: zshProfileLines)
        outerLines += [
            "CMUXZSHPROFILE",
            "    cat > \"$programa_shell_dir/.zshrc\" <<'CMUXZSHRC'",
        ]
        outerLines.append(contentsOf: zshRCLines)
        outerLines += [
            "CMUXZSHRC",
            "    cat > \"$programa_shell_dir/.zlogin\" <<'CMUXZSHLOGIN'",
        ]
        outerLines.append(contentsOf: zshLoginLines)
        outerLines += [
            "CMUXZSHLOGIN",
            "    chmod 600 \"$programa_shell_dir/.zshenv\" \"$programa_shell_dir/.zprofile\" \"$programa_shell_dir/.zshrc\" \"$programa_shell_dir/.zlogin\" >/dev/null 2>&1 || true",
        ]
        outerLines.append(contentsOf: relayWarmupLines.map { "    " + $0 })
        outerLines += [
            "    export PROGRAMA_REAL_ZDOTDIR=\"${ZDOTDIR:-$HOME}\"",
            "    export ZDOTDIR=\"$programa_shell_dir\"",
            "    exec \"$PROGRAMA_LOGIN_SHELL\" -il",
            "    ;;",
            "  bash)",
            "    cat > \"$programa_shell_dir/.bashrc\" <<'CMUXBASHRC'",
        ]
        outerLines.append(contentsOf: bashRCLines)
        outerLines += [
            "CMUXBASHRC",
            "    chmod 600 \"$programa_shell_dir/.bashrc\" >/dev/null 2>&1 || true",
        ]
        outerLines.append(contentsOf: relayWarmupLines.map { "    " + $0 })
        outerLines += [
            "    exec \"$PROGRAMA_LOGIN_SHELL\" --rcfile \"$programa_shell_dir/.bashrc\" -i",
            "    ;;",
            "  *)",
        ]
        outerLines.append(contentsOf: commonShellExportLines)
        outerLines.append(contentsOf: relayWarmupLines)
        outerLines += [
            "exec \"$PROGRAMA_LOGIN_SHELL\" -i",
            ";;",
            "esac",
        ]

        return outerLines.joined(separator: "\n")
    }

    private func shellStateDirForRemoteRelayPort(_ remoteRelayPort: Int) -> String {
        "$HOME/.programa/relay/\(max(remoteRelayPort, 0)).shell"
    }

    private func bundledShellIntegrationScript(named fileName: String) -> String? {
        let fileManager = FileManager.default
        var candidates: [URL] = []

        if let executableURL = resolvedExecutableURL() {
            var current = executableURL.deletingLastPathComponent().standardizedFileURL
            while true {
                if current.lastPathComponent == "Contents" {
                    candidates.append(
                        current
                            .appendingPathComponent("Resources", isDirectory: true)
                            .appendingPathComponent("shell-integration", isDirectory: true)
                            .appendingPathComponent(fileName, isDirectory: false)
                    )
                }

                let projectMarker = current.appendingPathComponent("GhosttyTabs.xcodeproj/project.pbxproj", isDirectory: false)
                if fileManager.fileExists(atPath: projectMarker.path) {
                    candidates.append(
                        current
                            .appendingPathComponent("Resources", isDirectory: true)
                            .appendingPathComponent("shell-integration", isDirectory: true)
                            .appendingPathComponent(fileName, isDirectory: false)
                    )
                    break
                }

                guard let parent = parentSearchURL(for: current) else {
                    break
                }
                current = parent
            }
        }

        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(
                resourceURL
                    .appendingPathComponent("shell-integration", isDirectory: true)
                    .appendingPathComponent(fileName, isDirectory: false)
            )
        }

        for url in candidates {
            guard fileManager.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url),
                  let contents = String(data: data, encoding: .utf8) else {
                continue
            }
            return contents
        }

        return nil
    }

    func buildInteractiveRemoteShellCommand(
        remoteRelayPort: Int,
        shellFeatures: String,
        terminfoSource: String? = nil
    ) -> String {
        let script = buildInteractiveRemoteShellScript(
            remoteRelayPort: remoteRelayPort,
            shellFeatures: shellFeatures,
            terminfoSource: terminfoSource
        )
        return "/bin/sh -c \(shellQuote(script))"
    }

    private func interactiveRemoteTerminalSetupLines(terminfoSource: String?) -> [String] {
        var lines: [String] = [
            "programa_term='xterm-256color'",
            "if command -v infocmp >/dev/null 2>&1 && infocmp xterm-ghostty >/dev/null 2>&1; then",
            "  programa_term='xterm-ghostty'",
            "fi",
            "export TERM=\"$programa_term\"",
        ]
        guard let terminfoSource else { return lines }
        let trimmedTerminfoSource = terminfoSource.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTerminfoSource.isEmpty else { return lines }
        lines += [
            "if [ \"$programa_term\" != 'xterm-ghostty' ]; then",
            "  (",
            "    command -v tic >/dev/null 2>&1 || exit 0",
            "    mkdir -p \"$HOME/.terminfo\" 2>/dev/null || exit 0",
            "    cat <<'CMUXTERMINFO' | tic -x - >/dev/null 2>&1",
            trimmedTerminfoSource,
            "CMUXTERMINFO",
            "  ) >/dev/null 2>&1 &",
            "fi",
        ]
        return lines
    }

    private func interactiveRemoteShellExportLines(shellFeatures: String) -> [String] {
        let environment = ProcessInfo.processInfo.environment
        let colorTerm = Self.normalizedEnvValue(environment["COLORTERM"]) ?? "truecolor"
        let termProgram = Self.normalizedEnvValue(environment["TERM_PROGRAM"]) ?? "ghostty"
        let termProgramVersion = Self.normalizedEnvValue(environment["TERM_PROGRAM_VERSION"])
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? ""
        let trimmedShellFeatures = shellFeatures.trimmingCharacters(in: .whitespacesAndNewlines)

        var exports: [String] = [
            "export COLORTERM=\(shellQuote(colorTerm))",
            "export TERM_PROGRAM=\(shellQuote(termProgram))",
        ]
        if !termProgramVersion.isEmpty {
            exports.append("export TERM_PROGRAM_VERSION=\(shellQuote(termProgramVersion))")
        }
        if !trimmedShellFeatures.isEmpty {
            exports.append("export GHOSTTY_SHELL_FEATURES=\(shellQuote(trimmedShellFeatures))")
        }
        return exports
    }

    private func interactiveRemoteRelayWarmupLines(remoteRelayPort: Int) -> [String] {
        guard remoteRelayPort > 0 else {
            return []
        }
        return [
            "programa_relay_cli=\"${PROGRAMA_BUNDLED_CLI_PATH:-$HOME/.programa/bin/programa}\"",
            "if [ ! -x \"$programa_relay_cli\" ]; then programa_relay_cli=\"$(command -v programa 2>/dev/null || true)\"; fi",
            "programa_relay_tty=\"${PROGRAMA_BOOTSTRAP_TTY:-}\"",
            "if [ -z \"$programa_relay_tty\" ]; then programa_relay_tty=\"$(tty 2>/dev/null || true)\"; fi",
            "programa_relay_tty=\"${programa_relay_tty##*/}\"",
            "if [ -n \"$programa_relay_tty\" ] && [ \"$programa_relay_tty\" != \"not a tty\" ]; then",
            "  mkdir -p \"$HOME/.programa/relay\" >/dev/null 2>&1 || true",
            "  printf '%s' \"$programa_relay_tty\" > \"$HOME/.programa/relay/\(remoteRelayPort).tty\" 2>/dev/null || true",
            "fi",
            "if [ -n \"$programa_relay_cli\" ] && [ -n \"$PROGRAMA_WORKSPACE_ID\" ] && [ -n \"$programa_relay_tty\" ] && [ \"$programa_relay_tty\" != \"not a tty\" ]; then",
            "  programa_relay_report_tty=\"{\\\"workspace_id\\\":\\\"$PROGRAMA_WORKSPACE_ID\\\",\\\"tty_name\\\":\\\"$programa_relay_tty\\\"}\"",
            "  programa_relay_ports_kick=\"{\\\"workspace_id\\\":\\\"$PROGRAMA_WORKSPACE_ID\\\",\\\"reason\\\":\\\"command\\\"}\"",
            "  if [ -n \"$PROGRAMA_SURFACE_ID\" ]; then",
            "    programa_relay_report_tty=\"{\\\"workspace_id\\\":\\\"$PROGRAMA_WORKSPACE_ID\\\",\\\"surface_id\\\":\\\"$PROGRAMA_SURFACE_ID\\\",\\\"tty_name\\\":\\\"$programa_relay_tty\\\"}\"",
            "    programa_relay_ports_kick=\"{\\\"workspace_id\\\":\\\"$PROGRAMA_WORKSPACE_ID\\\",\\\"surface_id\\\":\\\"$PROGRAMA_SURFACE_ID\\\",\\\"reason\\\":\\\"command\\\"}\"",
            "  fi",
            "  \"$programa_relay_cli\" rpc surface.report_tty \"$programa_relay_report_tty\" >/dev/null 2>&1 || true",
            "  \"$programa_relay_cli\" rpc surface.ports_kick \"$programa_relay_ports_kick\" >/dev/null 2>&1 || true",
            "fi",
            "unset PROGRAMA_BOOTSTRAP_TTY programa_relay_cli programa_relay_tty programa_relay_report_tty programa_relay_ports_kick",
        ]
    }

    private func baseSSHArguments(_ options: SSHCommandOptions, localCommand: String? = nil) -> [String] {
        let effectiveSSHOptions = effectiveSSHOptions(
            options.sshOptions,
            remoteRelayPort: options.remoteRelayPort
        )
        var parts: [String] = ["ssh"]
        if !hasSSHOptionKey(effectiveSSHOptions, key: "ConnectTimeout") {
            parts += ["-o", "ConnectTimeout=6"]
        }
        if !hasSSHOptionKey(effectiveSSHOptions, key: "ServerAliveInterval") {
            parts += ["-o", "ServerAliveInterval=20"]
        }
        if !hasSSHOptionKey(effectiveSSHOptions, key: "ServerAliveCountMax") {
            parts += ["-o", "ServerAliveCountMax=2"]
        }
        if !hasSSHOptionKey(effectiveSSHOptions, key: "SetEnv") {
            parts += ["-o", "SetEnv COLORTERM=truecolor"]
        }
        if !hasSSHOptionKey(effectiveSSHOptions, key: "SendEnv") {
            parts += ["-o", "SendEnv TERM_PROGRAM TERM_PROGRAM_VERSION"]
        }
        if let port = options.port {
            parts += ["-p", String(port)]
        }
        if let identityFile = normalizedSSHIdentityPath(options.identityFile) {
            parts += ["-i", identityFile]
        }
        for option in effectiveSSHOptions {
            parts += ["-o", option]
        }
        if let localCommand, !localCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let escapedLocalCommand = localCommand.replacingOccurrences(of: "%", with: "%%")
            parts += ["-o", "PermitLocalCommand=yes"]
            parts += ["-o", "LocalCommand=\(escapedLocalCommand)"]
        }
        return parts
    }

    private func localXtermGhosttyTerminfoSource() -> String? {
        let result = runProcess(
            executablePath: "/usr/bin/infocmp",
            arguments: ["-0", "-x", "xterm-ghostty"]
        )
        guard result.status == 0 else { return nil }
        let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? nil : output
    }

    private func sshOptionsWithControlSocketDefaults(
        _ options: [String],
        remoteRelayPort: Int? = nil
    ) -> [String] {
        var merged: [String] = []
        for option in options {
            let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            merged.append(trimmed)
        }
        if !hasSSHOptionKey(merged, key: "ControlMaster") {
            merged.append("ControlMaster=auto")
        }
        if !hasSSHOptionKey(merged, key: "ControlPersist") {
            merged.append("ControlPersist=600")
        }
        if !hasSSHOptionKey(merged, key: "ControlPath") {
            merged.append("ControlPath=\(defaultSSHControlPathTemplate(remoteRelayPort: remoteRelayPort))")
        }
        return merged
    }

    private func scopedGhosttyShellFeaturesValue() -> String {
        let rawExisting = ProcessInfo.processInfo.environment["GHOSTTY_SHELL_FEATURES"] ?? ""
        var seen: Set<String> = []
        var merged: [String] = []

        for token in rawExisting.split(separator: ",") {
            let feature = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !feature.isEmpty else { continue }
            if seen.insert(feature).inserted {
                merged.append(feature)
            }
        }

        for required in ["ssh-env", "ssh-terminfo"] {
            if seen.insert(required).inserted {
                merged.append(required)
            }
        }

        return merged.joined(separator: ",")
    }

    func encodedRemoteBootstrapCommand(
        _ remoteBootstrapScript: String,
        remoteRelayPort: Int
    ) -> String {
        let encodedScript = Data(remoteBootstrapScript.utf8).base64EncodedString()
        let encodedLiteral = shellQuote(encodedScript)
        var lines = remoteBootstrapTTYCaptureLines(remoteRelayPort: remoteRelayPort, includeRelayRPC: false)
        lines += [
            "programa_tmp=$(mktemp \"${TMPDIR:-/tmp}/cmux-ssh-bootstrap.XXXXXX\") || exit 1",
            "(printf %s \(encodedLiteral) | base64 -d 2>/dev/null || printf %s \(encodedLiteral) | base64 -D 2>/dev/null) > \"$programa_tmp\" || { rm -f \"$programa_tmp\"; exit 1; }",
            "chmod 700 \"$programa_tmp\" >/dev/null 2>&1 || true",
            "/bin/sh \"$programa_tmp\"",
            "programa_status=$?",
            "rm -f \"$programa_tmp\"",
            "exit $programa_status",
        ]
        return lines.joined(separator: "\n")
    }

    func sshPercentEscapedRemoteCommand(_ remoteCommand: String) -> String {
        remoteCommand.replacingOccurrences(of: "%", with: "%%")
    }

    func buildSSHStartupCommand(
        sshCommand: String,
        shellFeatures: String,
        remoteRelayPort: Int,
        isShellSnippet: Bool = false
    ) throws -> String {
        let trimmedFeatures = shellFeatures.trimmingCharacters(in: .whitespacesAndNewlines)
        let shellFeaturesBootstrap: String = trimmedFeatures.isEmpty
            ? ""
            : "export GHOSTTY_SHELL_FEATURES=\(shellQuote(trimmedFeatures))"
        let lifecycleCleanup = buildSSHSessionEndShellCommand(remoteRelayPort: remoteRelayPort)
        var scriptLines: [String] = []
        if !shellFeaturesBootstrap.isEmpty {
            scriptLines.append(shellFeaturesBootstrap)
        }
        scriptLines += [
            "PROGRAMA_SSH_SESSION_ENDED=0",
            "programa_ssh_session_end() { if [ \"${PROGRAMA_SSH_SESSION_ENDED:-0}\" = 1 ]; then return; fi; PROGRAMA_SSH_SESSION_ENDED=1; \(lifecycleCleanup); }",
            "trap 'programa_ssh_session_end' EXIT HUP INT TERM",
        ]
        if isShellSnippet {
            scriptLines.append(sshCommand)
        } else {
            scriptLines.append("command \(sshCommand)")
        }
        scriptLines += [
            "programa_ssh_status=$?",
            "trap - EXIT HUP INT TERM",
            "programa_ssh_session_end",
            "exit $programa_ssh_status",
        ]
        let script = scriptLines.joined(separator: "\n")
        return try writeSSHStartupScript(script, remoteRelayPort: remoteRelayPort)
    }

    private func writeSSHStartupScript(_ scriptBody: String, remoteRelayPort: Int) throws -> String {
        let tempDir = FileManager.default.temporaryDirectory
        let scriptURL = tempDir.appendingPathComponent(
            "cmux-ssh-startup-\(remoteRelayPort)-\(UUID().uuidString.lowercased()).sh"
        )
        let script = "#!/bin/sh\n\(scriptBody)\n"
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        return shellQuote(scriptURL.path)
    }

    private func buildSSHSessionEndShellCommand(remoteRelayPort: Int) -> String {
        [
            "if [ -n \"${PROGRAMA_BUNDLED_CLI_PATH:-}\" ]",
            "&& [ -x \"${PROGRAMA_BUNDLED_CLI_PATH}\" ]",
            "&& [ -n \"${PROGRAMA_SOCKET_PATH:-}\" ]",
            "&& [ -n \"${PROGRAMA_WORKSPACE_ID:-}\" ]",
            "&& [ -n \"${PROGRAMA_SURFACE_ID:-}\" ]; then",
            "\"${PROGRAMA_BUNDLED_CLI_PATH}\" --socket \"${PROGRAMA_SOCKET_PATH}\" ssh-session-end --relay-port \(remoteRelayPort) --workspace \"${PROGRAMA_WORKSPACE_ID}\" --surface \"${PROGRAMA_SURFACE_ID}\" >/dev/null 2>&1 || true;",
            "elif command -v cmux >/dev/null 2>&1",
            "&& [ -n \"${PROGRAMA_WORKSPACE_ID:-}\" ]",
            "&& [ -n \"${PROGRAMA_SURFACE_ID:-}\" ]; then",
            "cmux ssh-session-end --relay-port \(remoteRelayPort) --workspace \"${PROGRAMA_WORKSPACE_ID}\" --surface \"${PROGRAMA_SURFACE_ID}\" >/dev/null 2>&1 || true;",
            "fi",
        ].joined(separator: " ")
    }

    func runSSHSessionEnd(commandArgs: [String], client: SocketClient) throws {
        guard let relayPortRaw = optionValue(commandArgs, name: "--relay-port"),
              let relayPort = Int(relayPortRaw),
              relayPort > 0 else {
            throw CLIError(message: "ssh-session-end requires --relay-port <port>")
        }
        let workspaceRaw = optionValue(commandArgs, name: "--workspace") ?? ProcessInfo.processInfo.environment["PROGRAMA_WORKSPACE_ID"]
        let surfaceRaw = optionValue(commandArgs, name: "--surface") ?? ProcessInfo.processInfo.environment["PROGRAMA_SURFACE_ID"]
        guard let workspaceRaw,
              let workspaceId = try normalizeWorkspaceHandle(workspaceRaw, client: client),
              !workspaceId.isEmpty else {
            throw CLIError(message: "ssh-session-end requires --workspace or PROGRAMA_WORKSPACE_ID")
        }
        guard let surfaceRaw,
              let surfaceId = try normalizeSurfaceHandle(surfaceRaw, client: client, workspaceHandle: workspaceId),
              !surfaceId.isEmpty else {
            throw CLIError(message: "ssh-session-end requires --surface or PROGRAMA_SURFACE_ID")
        }
        _ = try client.sendV2(method: "workspace.remote.terminal_session_end", params: [
            "workspace_id": workspaceId,
            "surface_id": surfaceId,
            "relay_port": relayPort,
        ])
    }

    func runRemoteDaemonStatus(commandArgs: [String], jsonOutput: Bool) throws {
        let requestedOS = optionValue(commandArgs, name: "--os")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedArch = optionValue(commandArgs, name: "--arch")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let info = resolvedVersionInfo()
        let manifest = remoteDaemonManifest()
        let platform = defaultRemoteDaemonPlatform(requestedOS: requestedOS, requestedArch: requestedArch)
        let cacheURL = remoteDaemonCacheURL(version: manifest?.appVersion ?? remoteDaemonVersionString(from: info), goOS: platform.goOS, goArch: platform.goArch)
        let cacheExists = FileManager.default.fileExists(atPath: cacheURL.path)
        let cacheSHA = cacheExists ? try? sha256Hex(forFile: cacheURL) : nil
        let entry = manifest?.entry(goOS: platform.goOS, goArch: platform.goArch)
        let cacheVerified = (entry != nil && cacheSHA?.lowercased() == entry?.sha256.lowercased())
        let releaseTag = manifest?.releaseTag ?? "unknown"
        let assetName = entry?.assetName ?? "unknown"
        let downloadURL = entry?.downloadURL ?? "unknown"
        let checksumsAssetName = manifest?.checksumsAssetName ?? "unknown"
        let checksumsURL = manifest?.checksumsURL ?? "unknown"
        let downloadCommand = "gh release download \(releaseTag) --repo darkroomengineering/programa --pattern \(assetName)"
        let downloadChecksumsCommand = "gh release download \(releaseTag) --repo darkroomengineering/programa --pattern \(checksumsAssetName)"
        let checksumVerifyCommand = "shasum -a 256 -c \(checksumsAssetName) --ignore-missing"
        let signerWorkflow = "darkroomengineering/programa/.github/workflows/release.yml"
        let verifyCommand = "gh attestation verify ./\(assetName) --repo darkroomengineering/programa --signer-workflow \(signerWorkflow)"

        let payload: [String: Any] = [
            "app_version": remoteDaemonVersionString(from: info),
            "build": info["CFBundleVersion"] ?? NSNull(),
            "commit": info["ProgramaCommit"] ?? NSNull(),
            "manifest_present": manifest != nil,
            "release_tag": releaseTag,
            "release_url": manifest?.releaseURL ?? NSNull(),
            "target_goos": platform.goOS,
            "target_goarch": platform.goArch,
            "asset_name": assetName,
            "download_url": downloadURL,
            "checksums_asset_name": checksumsAssetName,
            "checksums_url": checksumsURL,
            "expected_sha256": entry?.sha256 ?? NSNull(),
            "cache_path": cacheURL.path,
            "cache_exists": cacheExists,
            "cache_sha256": cacheSHA ?? NSNull(),
            "cache_verified": cacheVerified,
            "dev_local_build_fallback": ProcessInfo.processInfo.environment["PROGRAMA_REMOTE_DAEMON_ALLOW_LOCAL_BUILD"] == "1",
            "download_command": downloadCommand,
            "download_checksums_command": downloadChecksumsCommand,
            "checksum_verify_command": checksumVerifyCommand,
            "attestation_verify_command": verifyCommand,
        ]

        if jsonOutput {
            print(jsonString(payload))
            return
        }

        print("app version: \(payload["app_version"] as? String ?? "unknown")")
        if let build = payload["build"] as? String {
            print("build: \(build)")
        }
        if let commit = payload["commit"] as? String {
            print("commit: \(commit)")
        }
        print("manifest: \(manifest != nil ? "present" : "missing")")
        print("platform: \(platform.goOS)/\(platform.goArch)")
        print("release: \(releaseTag)")
        print("asset: \(assetName)")
        print("download url: \(downloadURL)")
        print("checksums asset: \(checksumsAssetName)")
        print("checksums: \(checksumsURL)")
        if let expectedSHA = entry?.sha256 {
            print("expected sha256: \(expectedSHA)")
        }
        print("cache: \(cacheURL.path)")
        print("cache exists: \(cacheExists ? "yes" : "no")")
        if let cacheSHA {
            print("cache sha256: \(cacheSHA)")
        }
        print("cache verified: \(cacheVerified ? "yes" : "no")")
        print("download command: \(downloadCommand)")
        print("download checksums: \(downloadChecksumsCommand)")
        print("verify checksum: \(checksumVerifyCommand)")
        print("attestation verify: \(verifyCommand)")
        if manifest == nil {
            print("note: this build has no embedded remote daemon manifest. Set PROGRAMA_REMOTE_DAEMON_ALLOW_LOCAL_BUILD=1 only for dev builds.")
        }
    }

    private func defaultRemoteDaemonPlatform(requestedOS: String?, requestedArch: String?) -> (goOS: String, goArch: String) {
        let normalizedOS = requestedOS?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let normalizedArch = requestedArch?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let goOS = (normalizedOS?.isEmpty == false ? normalizedOS! : hostGoOS())
        let goArch = (normalizedArch?.isEmpty == false ? normalizedArch! : hostGoArch())
        return (goOS, goArch)
    }

    private func hostGoOS() -> String {
#if os(macOS)
        return "darwin"
#elseif os(Linux)
        return "linux"
#else
        return "unknown"
#endif
    }

    private func hostGoArch() -> String {
#if arch(arm64)
        return "arm64"
#elseif arch(x86_64)
        return "amd64"
#else
        return "unknown"
#endif
    }

    private func remoteDaemonManifest() -> RemoteDaemonManifest? {
        for plistURL in candidateInfoPlistURLs() {
            guard let raw = NSDictionary(contentsOf: plistURL) as? [String: Any],
                  let rawManifest = raw["CMUXRemoteDaemonManifestJSON"] as? String,
                  let data = rawManifest.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
                  let manifest = try? JSONDecoder().decode(RemoteDaemonManifest.self, from: data) else {
                continue
            }
            return manifest
        }
        return nil
    }

    private func remoteDaemonVersionString(from info: [String: String]) -> String {
        info["CFBundleShortVersionString"] ?? "dev"
    }

    private func remoteDaemonCacheURL(version: String, goOS: String, goArch: String) -> URL {
        let root: URL
        do {
            root = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        } catch {
            return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("cmux-remote-daemons", isDirectory: true)
                .appendingPathComponent(version, isDirectory: true)
                .appendingPathComponent("\(goOS)-\(goArch)", isDirectory: true)
                .appendingPathComponent("programad-remote", isDirectory: false)
        }
        return root
            .appendingPathComponent("programa", isDirectory: true)
            .appendingPathComponent("remote-daemons", isDirectory: true)
            .appendingPathComponent(version, isDirectory: true)
            .appendingPathComponent("\(goOS)-\(goArch)", isDirectory: true)
            .appendingPathComponent("programad-remote", isDirectory: false)
    }

    private func sha256Hex(forFile url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func hasSSHOptionKey(_ options: [String], key: String) -> Bool {
        let loweredKey = key.lowercased()
        for option in options {
            let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let token = trimmed.split(whereSeparator: { $0 == "=" || $0.isWhitespace }).first.map(String.init)?.lowercased()
            if token == loweredKey {
                return true
            }
        }
        return false
    }

    private func deferredRemoteReconnectLocalCommand(
        in options: [String],
        localCLIPath: String?,
        foregroundAuthToken: String
    ) -> String? {
        guard shouldDeferRemoteReconnect(in: options) else { return nil }
        let preferredCLIPath = localCLIPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        let escapedForegroundAuthToken = foregroundAuthToken
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return [
            preferredCLIPath.map { "programa_reconnect_cli=\(shellQuote($0));" } ?? "programa_reconnect_cli=\"\";",
            "programa_reconnect_socket=\"${PROGRAMA_SOCKET_PATH:-${PROGRAMA_SOCKET:-}}\";",
            "if [ -z \"$programa_reconnect_cli\" ] && [ -n \"${PROGRAMA_BUNDLED_CLI_PATH:-}\" ]; then programa_reconnect_cli=\"$PROGRAMA_BUNDLED_CLI_PATH\"; fi;",
            "if [ ! -x \"$programa_reconnect_cli\" ]; then programa_reconnect_cli=\"$(command -v cmux 2>/dev/null || true)\"; fi;",
            "if [ -n \"${PROGRAMA_WORKSPACE_ID:-}\" ]; then",
            "if [ -z \"$programa_reconnect_socket\" ]; then printf '%s\\n' 'cmux: deferred SSH reconnect skipped, local cmux socket not found' >&2;",
            "elif [ -z \"$programa_reconnect_cli\" ] || [ ! -x \"$programa_reconnect_cli\" ]; then printf '%s\\n' 'cmux: deferred SSH reconnect skipped, local cmux CLI not found' >&2;",
            "else",
            "programa_reconnect_payload=\"{\\\"workspace_id\\\":\\\"$PROGRAMA_WORKSPACE_ID\\\",\\\"foreground_auth_token\\\":\\\"\(escapedForegroundAuthToken)\\\"}\";",
            "\"$programa_reconnect_cli\" --socket \"$programa_reconnect_socket\" rpc workspace.remote.foreground_auth_ready \"$programa_reconnect_payload\" >/dev/null 2>&1 || true;",
            "unset programa_reconnect_payload;",
            "fi;",
            "fi;",
            "unset programa_reconnect_socket programa_reconnect_cli;",
        ].joined(separator: " ")
    }

    private func shouldDeferRemoteReconnect(in options: [String]) -> Bool {
        guard !hasSSHOptionKey(options, key: "LocalCommand"),
              !hasSSHOptionKey(options, key: "PermitLocalCommand") else {
            return false
        }

        guard let controlPath = sshOptionValue(named: "ControlPath", in: options)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !controlPath.isEmpty,
              controlPath.lowercased() != "none" else {
            return false
        }

        let controlMaster = sshOptionValue(named: "ControlMaster", in: options)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? "auto"
        switch controlMaster {
        case "no", "false", "off":
            return false
        default:
            return true
        }
    }

    private func defaultSSHControlPathTemplate(remoteRelayPort: Int? = nil) -> String {
        if let remoteRelayPort, remoteRelayPort > 0 {
            return "/tmp/programa-ssh-\(getuid())-\(remoteRelayPort)-%C"
        }
        return "/tmp/programa-ssh-\(getuid())-%C"
    }

    private func normalizedSSHIdentityPath(_ rawPath: String?) -> String? {
        guard let rawPath else { return nil }
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("~") {
            let expanded = (trimmed as NSString).expandingTildeInPath
            if !expanded.isEmpty {
                return expanded
            }
        }
        return trimmed
    }

    private func shellQuote(_ value: String) -> String {
        let safePattern = "^[A-Za-z0-9_@%+=:,./-]+$"
        if value.range(of: safePattern, options: .regularExpression) != nil {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private func sshOptionValue(named key: String, in options: [String]) -> String? {
        let loweredKey = key.lowercased()
        for option in options {
            let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(
                maxSplits: 1,
                omittingEmptySubsequences: true,
                whereSeparator: { $0 == "=" || $0.isWhitespace }
            )
            if parts.count == 2, parts[0].lowercased() == loweredKey {
                let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty {
                    return value
                }
            }
        }
        return nil
    }

    private func cliDebugLog(_ message: @autoclosure () -> String) {
#if DEBUG
        let trimmedExplicit = ProcessInfo.processInfo.environment["PROGRAMA_DEBUG_LOG"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let path: String? = {
            if let trimmedExplicit, !trimmedExplicit.isEmpty {
                return trimmedExplicit
            }
            guard let marker = try? String(contentsOfFile: "/tmp/programa-last-debug-log-path", encoding: .utf8) else {
                return nil
            }
            let trimmedMarker = marker.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedMarker.isEmpty ? nil : trimmedMarker
        }()
        guard let path else { return }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(timestamp) [programa-cli] \(message())\n"
        guard let data = line.data(using: .utf8) else { return }
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            return
        }
#endif
    }

    private func runProcess(
        executablePath: String,
        arguments: [String],
        stdinText: String? = nil,
        timeout: TimeInterval? = nil
    ) -> (status: Int32, stdout: String, stderr: String) {
        let result = CLIProcessRunner.runProcess(
            executablePath: executablePath,
            arguments: arguments,
            stdinText: stdinText,
            timeout: timeout
        )
        return (result.status, result.stdout, result.stderr)
    }

    /// Subcommand help text for SSH commands, split out of the
    /// central `subcommandUsage` switch (programa.swift) so each domain's
    /// help text lives next to its command descriptors. Refs #101.
    func sshSubcommandUsage(_ command: String) -> String? {
        switch command {
        case "ssh":
            return """
            Usage: programa ssh <destination> [flags] [-- <remote-command-args>]

            Create a new workspace, mark it as remote-SSH, and start an SSH session in that workspace.
            programa will also establish a local SSH proxy endpoint so browser traffic can egress from the remote host.

            Flags:
              --name <title>          Optional workspace title
              --port <n>              SSH port
              --identity <path>       SSH identity file path
              --ssh-option <opt>      Extra SSH -o option (repeatable)
              --no-focus              Create workspace without switching to it

            Example:
              programa ssh dev@my-host
              programa ssh dev@my-host --name "gpu-box" --port 2222 --identity ~/.ssh/id_ed25519
              programa ssh dev@my-host --ssh-option UserKnownHostsFile=/dev/null --ssh-option StrictHostKeyChecking=no
            """
        case "remote-daemon-status":
            return """
            Usage: programa remote-daemon-status [--os <darwin|linux>] [--arch <arm64|amd64>]

            Show the embedded programad-remote release manifest, local cache status, checksum verification state,
            and the GitHub attestation verification command for a target platform.

            Example:
              programa remote-daemon-status
              programa remote-daemon-status --os linux --arch arm64
            """
        default:
            return nil
        }
    }

    /// SSH-related command descriptors, split out of the central
    /// `commandDescriptors()` array (programa.swift) so they live next to
    /// their implementation. Refs #101.
    func sshDescriptors() -> [CommandDescriptor] {
        [
            CommandDescriptor(
                names: ["ssh"],
                helpLines: ["ssh <destination> [--name <title>] [--port <n>] [--identity <path>] [--ssh-option <opt>] [--no-focus] [-- <remote-command-args>]"],
                execute: { ctx in
                    try self.runSSH(commandArgs: ctx.commandArgs, client: ctx.client, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat)
                }
            ),
            CommandDescriptor(
                names: ["ssh-session-end"],
                helpLines: [],
                execute: { ctx in
                    try self.runSSHSessionEnd(commandArgs: ctx.commandArgs, client: ctx.client)
                }
            ),
            CommandDescriptor(
                names: ["remote-daemon-status"],
                helpLines: ["remote-daemon-status [--os <darwin|linux>] [--arch <arm64|amd64>]"],
                connectionPolicy: .local,
                execute: nil
            ),
        ]
    }
}
