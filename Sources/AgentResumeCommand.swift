import Foundation

/// An agent session a pane can resume: the provider name as the agent hooks report it
/// (`claude-code`, `codex`, ...), the provider's session id, the directory it ran in, and the
/// transcript path its hooks reported. Persisted in session snapshots, so field names are a
/// stored contract; a field added later must stay optional so older snapshots still decode.
struct AgentResumeTarget: Codable, Equatable, Sendable {
    var provider: String
    var sessionId: String
    var cwd: String?
    var transcriptPath: String? = nil
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

    /// Whether `line(for:)` returns a command for the target, without touching the filesystem.
    static func canResume(_ target: AgentResumeTarget) -> Bool {
        isSupported(provider: target.provider) && isValidSessionId(target.sessionId)
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
        guard let cwd = target.cwd, !cwd.isEmpty, !containsUnsafeCharacters(cwd),
              standardizedPath(cwd) != paneDirectory.map(standardizedPath),
              directoryExists(cwd) else {
            return command
        }
        return "cd \(shellQuoted(cwd)) && \(command)"
    }

    /// Claude Code writes a session's transcript only after its first prompt, so a session quit
    /// before one has nothing to resume and `claude --resume <id>` fails with "No conversation
    /// found". Other providers are never reported missing.
    ///
    /// The transcript path Claude's hooks reported is checked exactly, because Claude may have
    /// run with a `CLAUDE_CONFIG_DIR` this process cannot see. Without one (a target saved
    /// before hooks reported it), `transcriptExists` searches the projects roots.
    static func claudeTranscriptIsMissing(
        for target: AgentResumeTarget,
        transcriptExists: (String) -> Bool = { claudeTranscriptExists(sessionId: $0) }
    ) -> Bool {
        guard target.provider == "claude-code" || target.provider == "claude" else { return false }
        if let path = target.transcriptPath?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
            return !isNonEmptyRegularFile(atPath: path)
        }
        return !transcriptExists(target.sessionId)
    }

    /// `$CLAUDE_CONFIG_DIR/projects` when set, then `~/.claude/projects`.
    static func claudeProjectsRoots(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = NSHomeDirectory()
    ) -> [URL] {
        var roots: [URL] = []
        if let configured = environment["CLAUDE_CONFIG_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty {
            roots.append(URL(fileURLWithPath: NSString(string: configured).expandingTildeInPath, isDirectory: true)
                .appendingPathComponent("projects", isDirectory: true))
        }
        let defaultRoot = URL(fileURLWithPath: homeDirectory, isDirectory: true)
            .appendingPathComponent(".claude/projects", isDirectory: true)
        if !roots.contains(where: { $0.standardizedFileURL == defaultRoot.standardizedFileURL }) {
            roots.append(defaultRoot)
        }
        return roots
    }

    /// Whether Claude Code has a non-empty transcript for the session: `<project>/<id>.jsonl`, or
    /// `<project>/<id>/messages/<id>.jsonl`, in any project under any root. Every project
    /// directory is searched instead of deriving Claude's directory name from a cwd, because the
    /// directory a pane reports can differ from the one Claude started in.
    ///
    /// True when no root is a readable directory: an app launched from Finder does not see a
    /// `CLAUDE_CONFIG_DIR` set only in the shell, and an unreadable root is no evidence that the
    /// transcript is missing.
    static func claudeTranscriptExists(sessionId: String, projectsRoots: [URL] = claudeProjectsRoots()) -> Bool {
        guard !sessionId.isEmpty, sessionId != ".", sessionId != "..",
              !sessionId.contains("/"), !sessionId.contains("\\") else { return false }
        var sawReadableRoot = false
        for root in projectsRoots {
            guard let projects = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { continue }
            sawReadableRoot = true
            for project in projects {
                let projectURL = root.appendingPathComponent(project, isDirectory: true)
                let direct = projectURL.appendingPathComponent("\(sessionId).jsonl")
                let nested = projectURL.appendingPathComponent(sessionId, isDirectory: true)
                    .appendingPathComponent("messages", isDirectory: true)
                    .appendingPathComponent("\(sessionId).jsonl")
                if isNonEmptyRegularFile(atPath: direct.path) || isNonEmptyRegularFile(atPath: nested.path) {
                    return true
                }
            }
        }
        return !sawReadableRoot
    }

    static func isNonEmptyRegularFile(atPath path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && info.st_size > 0
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

    /// fish reads `\'` inside single quotes as an escaped quote, so a cwd with a quote or a
    /// backslash cannot be quoted safely for every shell the pane may run.
    private static func containsUnsafeCharacters(_ value: String) -> Bool {
        value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F || $0 == "'" || $0 == "\\" }
    }

    static func standardizedPath(_ path: String) -> String {
        let resolved = NSString(string: NSString(string: path).expandingTildeInPath).standardizingPath
        return resolved.isEmpty ? path : resolved
    }
}
