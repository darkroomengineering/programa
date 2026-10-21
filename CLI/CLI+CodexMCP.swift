import Foundation

/// Plans registering the bundled `programa-mcp` server with Codex through `codex mcp add`,
/// the same way `programa aside install-mcp` registers Aside. Claude Code needs no
/// registration: the `claude` wrapper passes the server to each session it starts.
/// Pure so the decision table can be exercised without spawning Codex.
struct CodexMCPRegistrationPlan: Equatable {
    static let serverName = "programa"
    static let binaryName = "programa-mcp"

    /// The `codex` invocation to run after consent, or nil when nothing changes.
    let command: [String]?
    /// One line explaining a skipped or required change, for the install preview.
    let note: String?

    /// `registeredCommand` is the command Codex already runs for `programa`: nil when no
    /// such server exists, "" when one exists without a command (an HTTP server). Only a
    /// bare `programa-mcp` entry counts as ours; `codexRegisteredMCPCommand` reports one with
    /// arguments or environment under a different name so uninstall never removes it.
    static func build(
        install: Bool,
        codexExecutable: String?,
        mcpBinary: String?,
        registeredCommand: String?
    ) -> CodexMCPRegistrationPlan {
        guard let codexExecutable else {
            return CodexMCPRegistrationPlan(
                command: nil,
                note: install ? "Codex CLI not found on PATH; skipping its \(serverName) MCP server." : nil
            )
        }
        let registeredIsOurs = registeredCommand.map { ($0 as NSString).lastPathComponent == binaryName } ?? false
        if !install {
            guard registeredIsOurs else { return CodexMCPRegistrationPlan(command: nil, note: nil) }
            return CodexMCPRegistrationPlan(command: [codexExecutable, "mcp", "remove", serverName], note: nil)
        }
        guard let mcpBinary else {
            return CodexMCPRegistrationPlan(command: nil, note: "\(binaryName) not found next to this CLI; skipping the Codex MCP server.")
        }
        if registeredCommand == mcpBinary {
            return CodexMCPRegistrationPlan(command: nil, note: nil)
        }
        if let registeredCommand, !registeredIsOurs {
            let shown = registeredCommand.isEmpty ? "a non-stdio server" : registeredCommand
            return CodexMCPRegistrationPlan(
                command: nil,
                note: "Codex already has an MCP server named \(serverName) (\(shown)); leaving it unchanged."
            )
        }
        return CodexMCPRegistrationPlan(command: [codexExecutable, "mcp", "add", serverName, "--", mcpBinary], note: nil)
    }
}

extension ProgramaCLI {
    func codexMCPRegistrationPlan(install: Bool) -> CodexMCPRegistrationPlan {
        let codexExecutable = resolveCodexExecutable(searchPath: ProcessInfo.processInfo.environment["PATH"])
        return CodexMCPRegistrationPlan.build(
            install: install,
            codexExecutable: codexExecutable,
            mcpBinary: bundledMCPBinaryPath(),
            registeredCommand: codexExecutable.flatMap { codexRegisteredMCPCommand(codexExecutable: $0) }
        )
    }

    /// The executable `programa-mcp` next to this CLI, or nil when there is none.
    func bundledMCPBinaryPath() -> String? {
        let path = resolvedExecutableURL()?
            .deletingLastPathComponent()
            .appendingPathComponent(CodexMCPRegistrationPlan.binaryName, isDirectory: false)
            .path
        return path.flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil }
    }

    private func codexRegisteredMCPCommand(codexExecutable: String) -> String? {
        let result = CLIProcessRunner.runProcess(
            executablePath: codexExecutable,
            arguments: ["mcp", "get", CodexMCPRegistrationPlan.serverName, "--json"],
            timeout: 30
        )
        guard result.status == 0,
              let data = result.stdout.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let transport = root["transport"] as? [String: Any]
        let command = (transport?["command"] as? String) ?? ""
        let customized = ["args", "env", "env_vars"].contains { key in
            switch transport?[key] {
            case let list as [Any]: return !list.isEmpty
            case let map as [String: Any]: return !map.isEmpty
            default: return false
            }
        }
        return customized ? "\(command) with custom arguments or environment" : command
    }

    func printCodexMCPPreview(_ plan: CodexMCPRegistrationPlan) {
        guard plan.command != nil || plan.note != nil else { return }
        print("  Codex MCP server:")
        if let command = plan.command { print("    \(command.joined(separator: " "))") }
        if let note = plan.note { print("    \(note)") }
        print("")
    }

    /// Runs after hooks, trust state and the skill are committed, so a Codex failure here
    /// never leaves those half-written; it only fails the command.
    func applyCodexMCPPlan(_ plan: CodexMCPRegistrationPlan) throws {
        guard let command = plan.command, let executable = command.first else { return }
        let result = CLIProcessRunner.runProcess(executablePath: executable, arguments: Array(command.dropFirst()), timeout: 60)
        guard result.status == 0 else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw CLIError(message: "Codex MCP server change failed (\(result.status)): \(command.joined(separator: " "))\(detail.isEmpty ? "" : "\n\(detail)")")
        }
    }
}
