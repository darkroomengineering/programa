import Foundation
import Darwin

extension ProgramaCLI {
    // MARK: - Integration installer IO shared by the Claude, Codex and OpenCode installers

    /// Expands a leading `~` against `$HOME`. `NSString.expandingTildeInPath` ignores `HOME`
    /// (only `CFFIXED_USER_HOME` redirects it), while Claude Code and Codex honor `HOME`, so an
    /// installer run with an overridden `HOME` must write where the agent will read.
    static func integrationExpandTilde(_ path: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        let env = ProcessInfo.processInfo.environment["HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let home = (env?.isEmpty == false ? env! : NSHomeDirectory())
        return path == "~" ? home : (home as NSString).appendingPathComponent(String(path.dropFirst(2)))
    }

    /// Asks before an integration change is applied. `--yes`/`-y` skips the prompt. A
    /// non-interactive stdin without `--yes`, or an answer other than yes, exits non-zero so a
    /// script or agent never mistakes an aborted install for a successful one.
    func confirmIntegrationChanges() throws {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--yes") || arguments.contains("-y") { return }
        guard isatty(STDIN_FILENO) == 1 else {
            throw CLIError(message: "stdin is not a terminal; pass --yes to apply non-interactively. Nothing was changed.")
        }
        print("Apply these changes? [Y/n] ", terminator: "")
        guard let response = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              response.isEmpty || response == "y" || response == "yes" else {
            throw CLIError(message: "Aborted. Nothing was changed.")
        }
    }

    /// Hook payload from stdin. A TTY stdin carries no payload, and an agent that leaves the pipe
    /// open must not stall its own hook, so reading stops at EOF or after `deadline` seconds.
    func readAgentHookStdin(deadline: TimeInterval = 2) -> String {
        guard isatty(STDIN_FILENO) == 0 else { return "" }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        let end = Date().addingTimeInterval(deadline)
        while true {
            let remainingMs = Int32(max(0, end.timeIntervalSinceNow * 1000))
            guard remainingMs > 0 else { break }
            var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, remainingMs)
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else { break }
            let count = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Claude Code integration (persistent hooks)

    /// The persistent hook command installed into ~/.claude/settings.json (or
    /// $CLAUDE_CONFIG_DIR/settings.json). Unlike the runtime wrapper injected by
    /// Resources/bin/claude (which always runs inside a programa terminal and can
    /// assume programa is reachable), this command runs from *any* terminal, so it
    /// defensively checks both that it's inside a programa surface and that the
    /// programa CLI is on PATH before calling out. Mirrors the codex guard shape.
    private static func claudeHookCommand(_ event: String) -> String {
        "[ -n \"$PROGRAMA_SURFACE_ID\" ] && command -v programa >/dev/null 2>&1 && programa claude-hook \(event) || echo '{}'"
    }

    /// Identifier used to detect programa-owned hooks during install/uninstall.
    private static let claudeHookCommandMarker = "programa claude-hook"

    private struct ClaudeHookEventSpec {
        let name: String
        let event: String
        let timeout: Int
        let isAsync: Bool
    }

    /// The lifecycle events the runtime wrapper's HOOKS_JSON injects
    /// (Resources/bin/claude:207), reproduced here for the persistent file.
    private static let claudeHookEventSpecs: [ClaudeHookEventSpec] = [
        ClaudeHookEventSpec(name: "SessionStart", event: "session-start", timeout: 10, isAsync: false),
        ClaudeHookEventSpec(name: "Stop", event: "stop", timeout: 10, isAsync: false),
        ClaudeHookEventSpec(name: "SessionEnd", event: "session-end", timeout: 1, isAsync: false),
        ClaudeHookEventSpec(name: "Notification", event: "notification", timeout: 10, isAsync: false),
        ClaudeHookEventSpec(name: "UserPromptSubmit", event: "prompt-submit", timeout: 10, isAsync: false),
        ClaudeHookEventSpec(name: "PreToolUse", event: "pre-tool-use", timeout: 5, isAsync: true),
        ClaudeHookEventSpec(name: "SubagentStart", event: "subagent-start", timeout: 5, isAsync: false),
        ClaudeHookEventSpec(name: "SubagentStop", event: "subagent-stop", timeout: 5, isAsync: false)
    ]

    /// Builds the programa-owned hook groups, keyed by Claude Code lifecycle event
    /// name, in Claude Code's settings.json hooks schema (matcher + hooks array).
    private static var claudeHooksPayload: [String: Any] {
        var hooks: [String: Any] = [:]
        for spec in claudeHookEventSpecs {
            var hookEntry: [String: Any] = [
                "type": "command",
                "command": claudeHookCommand(spec.event),
                "timeout": spec.timeout
            ]
            if spec.isAsync {
                hookEntry["async"] = true
            }
            hooks[spec.name] = [[
                "matcher": "",
                "hooks": [hookEntry]
            ] as [String: Any]]
        }
        return hooks
    }

    /// Removes every programa-owned hook from an event's groups, keeping the user's hooks that
    /// share a group with ours, and drops groups left empty. Returns the number of hooks removed.
    private static func claudeRemovingProgramaHooks(_ groups: [[String: Any]]) -> (groups: [[String: Any]], removed: Int) {
        var removed = 0
        let kept: [[String: Any]] = groups.compactMap { group in
            guard let groupHooks = group["hooks"] as? [[String: Any]] else { return group }
            let userHooks = groupHooks.filter { hook in
                (hook["command"] as? String)?.contains(claudeHookCommandMarker) != true
            }
            removed += groupHooks.count - userHooks.count
            if userHooks.count == groupHooks.count { return group }
            guard !userHooks.isEmpty else { return nil }
            var trimmed = group
            trimmed["hooks"] = userHooks
            return trimmed
        }
        return (kept, removed)
    }

    /// Resolves the target settings.json, respecting Claude Code's own
    /// CLAUDE_CONFIG_DIR override.
    private static func claudeSettingsPath() -> String {
        if let override = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return (integrationExpandTilde(override) as NSString).appendingPathComponent("settings.json")
        }
        return integrationExpandTilde("~/.claude/settings.json")
    }

    func runClaudeInstallIntegration() throws {
        let settingsPath = Self.claudeSettingsPath()
        let settingsDir = (settingsPath as NSString).deletingLastPathComponent
        let fm = FileManager.default

        try fm.createDirectory(atPath: settingsDir, withIntermediateDirectories: true, attributes: nil)

        let existingSettingsContent: String?
        if fm.fileExists(atPath: settingsPath) {
            guard let content = try? String(contentsOfFile: settingsPath, encoding: .utf8) else {
                throw CLIError(message: "Could not read \(settingsPath). Check file permissions.")
            }
            existingSettingsContent = content
        } else {
            existingSettingsContent = nil
        }

        // Missing file = empty JSON object. Existing-but-unparsable = stop; never overwrite.
        var existing: [String: Any] = [:]
        if let existingSettingsContent {
            let trimmed = existingSettingsContent.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                guard let data = existingSettingsContent.data(using: .utf8),
                      let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw CLIError(
                        message: "\(settingsPath) is not valid JSON. Fix or remove the file manually, then re-run this command."
                    )
                }
                existing = parsed
            }
        }

        // Strip every programa hook first (including ones a user grouped with their own hooks),
        // then append one fresh programa group, so reinstalling never duplicates.
        var hooks = existing["hooks"] as? [String: Any] ?? [:]
        let programaHooks = Self.claudeHooksPayload
        for (eventName, programaGroups) in programaHooks {
            guard let programaGroupArray = programaGroups as? [[String: Any]] else { continue }
            var eventGroups = Self.claudeRemovingProgramaHooks(hooks[eventName] as? [[String: Any]] ?? []).groups
            eventGroups.append(contentsOf: programaGroupArray)
            hooks[eventName] = eventGroups
        }
        existing["hooks"] = hooks

        let newJsonData = try JSONSerialization.data(withJSONObject: existing, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let newContent = String(data: newJsonData, encoding: .utf8) ?? ""
        let settingsChanged = existingSettingsContent != newContent

        // Also install the `programa` agent skill into ~/.claude/skills (or
        // $CLAUDE_CONFIG_DIR/skills) alongside the hooks, so a fresh Claude
        // Code session inside programa knows it can drive the app. Refs #165.
        let skillPath = Self.agentSkillFilePath(skillsRoot: (settingsDir as NSString).appendingPathComponent("skills"))
        let skillState = agentSkillInstallState(path: skillPath)

        if !settingsChanged && !skillState.changed {
            print("programa Claude Code integration is already installed. Nothing to change.")
            return
        }

        if settingsChanged {
            print("  \(settingsPath):")
            if let existingSettingsContent, !existingSettingsContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                printSimpleDiff(old: existingSettingsContent, new: newContent)
            } else {
                print("    (new file)")
                let lines = newContent.components(separatedBy: "\n")
                for (i, line) in lines.enumerated() {
                    let lineLabel = String(format: "%3d", i + 1)
                    print("    \u{001B}[32m\(lineLabel) +\(line)\u{001B}[0m")
                }
            }
            print("")
        }
        if skillState.changed {
            printAgentSkillDiff(path: skillPath, existing: skillState.existing)
        }

        try confirmIntegrationChanges()

        if settingsChanged {
            try writeClaudeSettings(newJsonData, replacing: existingSettingsContent, at: settingsPath)
        }
        if skillState.changed {
            try writeAgentSkillFile(path: skillPath)
        }

        print("")
        print("Installed. The Claude Code integration now works from any terminal, not just programa's.")
        print("To remove: programa claude uninstall-integration")
    }

    /// Writes settings.json through a symlink (an atomic write to the link path would
    /// replace the user's link with a regular file) and only while the file still holds
    /// the content the change was computed from, under the same sidecar lock the Codex
    /// installer uses, so a concurrent edit is reported instead of overwritten. The file
    /// keeps its permission bits (it can hold `env` API keys, so a user's 0600 must survive);
    /// a new file is created 0600.
    private func writeClaudeSettings(_ data: Data, replacing previous: String?, at path: String) throws {
        let target = try codexResolveConfigTarget(path)
        try withCodexHooksLock(at: (path as NSString).deletingLastPathComponent) {
            guard (try? String(contentsOfFile: target, encoding: .utf8)) == previous else {
                throw CLIError(message: "\(path) changed while the integration was being updated. Re-run this command.")
            }
            var info = stat()
            let mode: mode_t = lstat(target, &info) == 0 ? info.st_mode & 0o7777 : 0o600
            try codexAtomicWrite(data, to: target, mode: mode)
        }
    }

    func runClaudeUninstallIntegration() throws {
        let settingsPath = Self.claudeSettingsPath()
        let settingsDir = (settingsPath as NSString).deletingLastPathComponent
        let skillPath = Self.agentSkillFilePath(skillsRoot: (settingsDir as NSString).appendingPathComponent("skills"))
        let skillContent = agentSkillUninstallState(path: skillPath)
        let fm = FileManager.default

        var hooksRemoval: (newJsonData: Data, newContent: String, oldContent: String)?
        if fm.fileExists(atPath: settingsPath),
           let data = try? Data(contentsOf: URL(fileURLWithPath: settingsPath)),
           var parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           var hooks = parsed["hooks"] as? [String: Any] {
            var removedCount = 0
            for eventName in hooks.keys {
                guard let eventGroups = hooks[eventName] as? [[String: Any]] else { continue }
                let result = Self.claudeRemovingProgramaHooks(eventGroups)
                removedCount += result.removed
                if result.groups.isEmpty {
                    hooks.removeValue(forKey: eventName)
                } else {
                    hooks[eventName] = result.groups
                }
            }
            if removedCount > 0 {
                parsed["hooks"] = hooks
                let newJsonData = try JSONSerialization.data(withJSONObject: parsed, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
                let newContent = String(data: newJsonData, encoding: .utf8) ?? ""
                let oldContent = String(data: data, encoding: .utf8) ?? ""
                hooksRemoval = (newJsonData, newContent, oldContent)
            }
        }

        if hooksRemoval == nil && skillContent == nil {
            print("No programa hooks found.")
            return
        }

        if let hooksRemoval {
            print("  \(settingsPath):")
            printSimpleDiff(old: hooksRemoval.oldContent, new: hooksRemoval.newContent)
            print("")
        }
        if let skillContent {
            printAgentSkillRemovalDiff(path: skillPath, content: skillContent)
        }

        try confirmIntegrationChanges()

        if let hooksRemoval {
            try writeClaudeSettings(hooksRemoval.newJsonData, replacing: hooksRemoval.oldContent, at: settingsPath)
        }
        if skillContent != nil {
            try removeAgentSkillFileIfManaged(path: skillPath)
        }
        print("Removed programa Claude Code integration.")
    }
}
