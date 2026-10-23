import Foundation

/// An agent session a pane can resume: the provider name as the agent hooks report it
/// (`claude-code`, `codex`, ...), the provider's session id, and the directory it ran in.
/// Persisted in session snapshots, so field names are a stored contract.
struct AgentResumeTarget: Codable, Equatable, Sendable {
    var provider: String
    var sessionId: String
    var cwd: String?
}

/// Builds the shell line that resumes an agent session. Compiled into both the app and the
/// CLI so `programa resume` and the palette action type the same command.
enum AgentResumeCommand {
    /// Providers whose CLI documents resuming by session id: `claude --resume <id>`,
    /// `codex resume [SESSION_ID]` (from `codex resume --help`; Codex hooks report the root
    /// thread id, which is the id it takes), and `opencode --session <id>`
    /// (https://opencode.ai/docs/cli/). OpenCode creates a new session for an id it does not
    /// know instead of failing.
    private static let templates: [String: [String]] = [
        "claude-code": ["claude", "--resume"],
        "claude": ["claude", "--resume"],
        "codex": ["codex", "resume"],
        "opencode": ["opencode", "--session"],
    ]

    static let supportedProviders = ["claude", "codex", "opencode"]

    static func isSupported(provider: String) -> Bool {
        templates[provider] != nil
    }

    /// The command line, or nil when the provider is unsupported or the session id is not a
    /// plain token. The line is typed into a live shell, so anything that could break out of
    /// the quoting or reach the shell as a control key is rejected, never sanitized.
    static func line(
        for target: AgentResumeTarget,
        paneDirectory: String?,
        directoryExists: (String) -> Bool = { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    ) -> String? {
        guard let template = templates[target.provider], isValidSessionId(target.sessionId) else { return nil }
        let command = (template + [shellQuoted(target.sessionId)]).joined(separator: " ")
        guard let cwd = target.cwd, !cwd.isEmpty, !containsControlCharacters(cwd),
              standardizedPath(cwd) != paneDirectory.map(standardizedPath),
              directoryExists(cwd) else {
            return command
        }
        return "cd \(shellQuoted(cwd)) && \(command)"
    }

    static func isValidSessionId(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII
                || scalar == "-" || scalar == "_" || scalar == "." || scalar == ":"
        }
    }

    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func containsControlCharacters(_ value: String) -> Bool {
        value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }

    static func standardizedPath(_ path: String) -> String {
        let resolved = NSString(string: NSString(string: path).expandingTildeInPath).standardizingPath
        return resolved.isEmpty ? path : resolved
    }
}
