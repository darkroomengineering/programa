import Foundation

/// Owns provider selection and the install/uninstall transaction boundary. Provider-specific
/// mutation code remains beside each provider's filesystem format in CLI+Hooks.swift.
struct HookInstallationCoordinator {
    enum Provider: String, Equatable { case codex, claude, opencode }
    enum Action: Equatable { case install, uninstall }
    struct Request: Equatable {
        let provider: Provider
        let action: Action
    }
    let cli: ProgramaCLI
    static func request(command: String, arguments: [String]) throws -> Request? {
        guard let provider = Provider(rawValue: command) else { return nil }
        let subcommand = arguments.first?.lowercased() ?? "help"
        switch (provider, subcommand) {
        case (.codex, "install-hooks"), (.codex, "install-integration"):
            return Request(provider: provider, action: .install)
        case (.codex, "uninstall-hooks"), (.codex, "uninstall-integration"):
            return Request(provider: provider, action: .uninstall)
        case (.claude, "install-integration"), (.opencode, "install-integration"):
            return Request(provider: provider, action: .install)
        case (.claude, "uninstall-integration"), (.opencode, "uninstall-integration"):
            return Request(provider: provider, action: .uninstall)
        case (.codex, _):
            return nil
        case (.claude, _):
            print("Usage: programa claude <install-integration|uninstall-integration>")
            throw CLIError(message: "Unknown claude subcommand: \(subcommand)")
        case (.opencode, _):
            print("Usage: programa opencode <install-integration|uninstall-integration>")
            throw CLIError(message: "Unknown opencode subcommand: \(subcommand)")
        }
    }

    @discardableResult
    func dispatch(command: String, arguments: [String]) throws -> Bool {
        guard let request = try Self.request(command: command, arguments: arguments) else { return false }
        switch (request.provider, request.action) {
        case (.codex, .install): try cli.runCodexHooksMutation(install: true)
        case (.codex, .uninstall): try cli.runCodexHooksMutation(install: false)
        case (.claude, .install): try cli.runClaudeInstallIntegration()
        case (.claude, .uninstall): try cli.runClaudeUninstallIntegration()
        case (.opencode, .install): try cli.runOpenCodeInstallIntegration()
        case (.opencode, .uninstall): try cli.runOpenCodeUninstallIntegration()
        }
        return true
    }
}

extension ProgramaCLI {
    func runCodexHooksMutation(install: Bool) throws {
        let paths = try codexPaths()
        try withCodexHooksLock(at: paths.lockHome) {
            let hooksSnapshot = try codexReadRegularFile(paths.hooks, limit: Self.codexMaximumFileBytes, refuseSymlink: true)
            let previousRoot = try codexHooksRoot(from: hooksSnapshot?.data, path: paths.hooks)
            let nextRoot = try codexRewriteHooks(previousRoot, install: install)
            let nextHooksData: Data? = install || hooksSnapshot != nil ? try codexEncodeHooks(nextRoot) : nil
            let hooksChanged: Bool
            if install {
                hooksChanged = hooksSnapshot?.data != nextHooksData
            } else if hooksSnapshot != nil {
                hooksChanged = try codexEncodeHooks(previousRoot) != nextHooksData
            } else {
                hooksChanged = false
            }

            let hooksKeyPath = paths.hooks
            let desired = install ? try codexExpectedTrustEntries(hooksPath: hooksKeyPath, root: nextRoot) : [:]
            let edit = CodexTrustEdit(
                configPath: paths.configTarget,
                configLinkPath: paths.configLink,
                hooksKeyPrefix: hooksKeyPath + ":",
                desired: desired,
                removalKeys: codexOwnedEntryKeys(hooksPath: hooksKeyPath, root: previousRoot),
                ownedHashes: try codexOwnedTrustHashes()
            )
            let preparedConfig = try codexPrepareConfig(edit)
            let existingConfig = preparedConfig.snapshot.flatMap { String(data: $0.data, encoding: .utf8) } ?? ""
            let renderedConfig = String(data: preparedConfig.rendered, encoding: .utf8) ?? ""
            let configChanged = (preparedConfig.snapshot?.data ?? Data()) != preparedConfig.rendered

            let skillPath = Self.agentSkillFilePath(
                skillsRoot: NSString(string: "~/.agents/skills").expandingTildeInPath
            )
            let skillInstall = install ? agentSkillInstallState(path: skillPath) : nil
            let skillUninstall = install ? nil : agentSkillUninstallState(path: skillPath)
            let skillChanged = skillInstall?.changed == true || skillUninstall != nil

            if !hooksChanged && !configChanged && !skillChanged {
                print(install ? "programa hooks are already installed. Nothing to change." : "No programa hooks found.")
                return
            }

            if hooksChanged {
                print("  \(paths.hooks):")
                if let old = hooksSnapshot.flatMap({ String(data: $0.data, encoding: .utf8) }), let nextHooksData {
                    printSimpleDiff(old: old, new: String(data: nextHooksData, encoding: .utf8) ?? "")
                } else {
                    print("    (new file)")
                }
                print("")
            }
            if configChanged {
                print("  \(paths.configLink):")
                if existingConfig.isEmpty { print("    (new file)") }
                printSimpleDiff(old: existingConfig, new: renderedConfig)
                print("")
            }
            if let skillInstall, skillInstall.changed {
                printAgentSkillDiff(path: skillPath, existing: skillInstall.existing)
            } else if let skillUninstall {
                printAgentSkillRemovalDiff(path: skillPath, content: skillUninstall)
            }

            let skipConfirm = ProcessInfo.processInfo.arguments.contains("--yes")
                || ProcessInfo.processInfo.arguments.contains("-y")
            if !skipConfirm {
                print("Apply these changes? [Y/n] ", terminator: "")
                guard let response = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                      response.isEmpty || response == "y" || response == "yes" else {
                    print("Aborted.")
                    return
                }
            }

            let freshHooks = try codexReadRegularFile(paths.hooks, limit: Self.codexMaximumFileBytes, refuseSymlink: true)
            guard freshHooks == hooksSnapshot else {
                throw CodexHooksError(message: "\(paths.hooks) changed while awaiting confirmation; retry the command")
            }
            if hooksChanged {
                if let nextHooksData {
                    try codexAtomicWrite(nextHooksData, to: paths.hooks, mode: hooksSnapshot?.mode ?? 0o600)
                } else {
                    try codexRestoreFile(nil, at: paths.hooks)
                }
            }
            do {
                try codexCommitConfig(preparedConfig)
            } catch {
                guard hooksChanged else { throw error }
                do {
                    try codexRestoreFile(hooksSnapshot, at: paths.hooks)
                } catch let rollbackError {
                    throw CodexHooksError(message: "Codex config update failed: \(error.localizedDescription); restoring hooks.json also failed: \(rollbackError.localizedDescription)")
                }
                throw error
            }

            // The shared skill is deliberately last: hooks.json and trust state
            // must commit together before any adjacent integration is changed.
            if install, skillInstall?.changed == true {
                try writeAgentSkillFile(path: skillPath)
            } else if !install, skillUninstall != nil {
                try removeAgentSkillFileIfManaged(path: skillPath)
            }

            print("")
            if install {
                print("Installed. Codex trusts programa hooks inside programa; they silently no-op elsewhere.")
                print("To remove: programa codex uninstall-hooks")
            } else {
                print("Removed programa Codex hooks and their trust entries.")
            }
        }
    }

}
