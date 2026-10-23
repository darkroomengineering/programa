import Foundation

/// OSC 7501 (Program Status Protocol) emission from Programa's own agent hooks. The hook
/// writes the sequence to the agent's terminal in addition to its socket reports, so a
/// terminal that understands the protocol sees the same state over SSH or without a socket.
/// Every failure is silent: a hook must never fail or slow the agent.
enum ProgramStatusSequence {
    /// The whole sequence stays within one tty write (macOS `PIPE_BUF`).
    static let maxBytes = 512

    /// Raw bytes of a child record's title, well under the protocol's 192 so `msg` keeps room.
    static let maxTitleBytes = 96

    /// Builds `ESC ] 7501 ; key=value:key=value ESC \`. `title` and `msg` are stripped of
    /// control characters and truncated on a UTF-8 boundary so the full sequence is
    /// <= `maxBytes`. `id` must already be a valid record id (`segment(/segment)*`).
    static func build(
        state: String,
        kind: String? = nil,
        app: String? = nil,
        msg: String? = nil,
        id: String? = nil,
        title: String? = nil
    ) -> [UInt8] {
        var fields = ["state=\(state)"]
        if let id, !id.isEmpty { fields.append("id=\(id)") }
        if let kind, !kind.isEmpty { fields.append("kind=\(kind)") }
        if let app, isValidApp(app) { fields.append("app=\(app)") }
        if let title {
            let bytes = truncatedUTF8(sanitized(title), maxBytes: maxTitleBytes)
            if !bytes.isEmpty { fields.append("title=\(Data(bytes).base64EncodedString())") }
        }

        let prefix = Array("\u{1B}]7501;".utf8)
        let suffix = Array("\u{1B}\\".utf8)
        var body = Array(fields.joined(separator: ":").utf8)

        if let msg {
            let clean = sanitized(msg)
            // ":msg=" costs 5 bytes; base64 expands n bytes to 4*ceil(n/3).
            let room = maxBytes - prefix.count - suffix.count - body.count - 5
            let rawBudget = (room / 4) * 3
            if rawBudget > 0 {
                let bytes = truncatedUTF8(clean, maxBytes: rawBudget)
                if !bytes.isEmpty {
                    body += Array(":msg=\(Data(bytes).base64EncodedString())".utf8)
                }
            }
        }
        return prefix + body + suffix
    }

    /// `[A-Za-z0-9_.+-]{1,32}`
    static func isValidApp(_ app: String) -> Bool {
        guard (1...32).contains(app.utf8.count) else { return false }
        return app.utf8.allSatisfy { byte in
            switch byte {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x5F, 0x2E, 0x2B, 0x2D: return true
            default: return false
            }
        }
    }

    /// Newlines and tabs become a space; other C0, DEL and C1 controls are dropped.
    static func sanitized(_ value: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x09, 0x0A, 0x0D: out.append(" ")
            case 0x00...0x1F, 0x7F, 0x80...0x9F: continue
            default: out.append(scalar)
            }
        }
        return String(out)
    }

    /// Longest prefix of `value`'s UTF-8 that is <= `maxBytes` and ends on a scalar boundary.
    static func truncatedUTF8(_ value: String, maxBytes: Int) -> [UInt8] {
        var result: [UInt8] = []
        for scalar in value.unicodeScalars {
            let encoded = Array(String(scalar).utf8)
            if result.count + encoded.count > maxBytes { break }
            result += encoded
        }
        return result
    }
}

extension ProgramaCLI {
    /// Emits one OSC 7501 status report to the agent's terminal. No-op unless
    /// `PROGRAMA_SURFACE_ID` is set (also true over SSH when forwarded) and not inside tmux.
    func emitProgramStatus(
        state: String,
        kind: String? = nil,
        app: String? = nil,
        msg: String? = nil,
        id: String? = nil,
        title: String? = nil
    ) {
        let env = ProcessInfo.processInfo.environment
        guard let surface = env["PROGRAMA_SURFACE_ID"], !surface.isEmpty else { return }
        if env["TMUX"] != nil { return }
        let bytes = ProgramStatusSequence.build(state: state, kind: kind, app: app, msg: msg, id: id, title: title)
        guard let fd = openProgramStatusTTY(env: env) else { return }
        defer { close(fd) }
        // A background hook process on a TOSTOP terminal would otherwise be stopped by SIGTTOU.
        let previous = signal(SIGTTOU, SIG_IGN)
        defer { _ = signal(SIGTTOU, previous) }
        _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }

    /// First tty that opens: /dev/tty, the raw TTY / SSH_TTY path, then ttyname() of fds 0-2.
    /// Deliberately not `normalizedTTYName`, which strips `/dev/pts/3` to `3`.
    private func openProgramStatusTTY(env: [String: String]) -> Int32? {
        let flags = O_WRONLY | O_NOCTTY | O_NONBLOCK | O_CLOEXEC
        var candidates = ["/dev/tty"]
        for key in ["TTY", "SSH_TTY"] {
            if let path = env[key], path.hasPrefix("/dev/") { candidates.append(path) }
        }
        for fd in 0...2 {
            if let name = ttyname(Int32(fd)) { candidates.append(String(cString: name)) }
        }
        for path in candidates {
            let fd = open(path, flags)
            if fd >= 0 { return fd }
        }
        return nil
    }

    /// Fail-open path (socket unreachable): the only code that runs for the hook, so it maps
    /// the subcommand to a status report itself, then returns the provider's ack.
    func failOpenHookAckEmittingProgramStatus(command: String, commandArgs: [String]) -> String? {
        guard let ack = failOpenHookAck(command: command) else { return nil }
        let app: String
        switch command {
        case "claude-hook": app = "claude-code"
        case "codex-hook": app = "codex"
        case "opencode-hook": app = "opencode"
        default: return ack
        }
        let raw = commandArgs.first?.lowercased() ?? ""
        let subcommand = ["active": "session-start", "idle": "stop", "notify": "notification"][raw] ?? raw
        let scope = ProcessInfo.processInfo.environment["PROGRAMA_WORKSPACE_ID"]
        switch subcommand {
        case "subagent-start" where command == "claude-hook":
            emitClaudeSubagentStatus(parseClaudeHookInput(rawInput: readAgentHookStdin()), scope: scope, state: "working")
        case "subagent-stop" where command == "claude-hook":
            emitClaudeSubagentStatus(parseClaudeHookInput(rawInput: readAgentHookStdin()), scope: scope, state: "done")
        case "pre-tool-use" where command == "claude-hook":
            emitProgramStatus(state: "working", app: app)
            emitClaudeSubagentStatus(parseClaudeHookInput(rawInput: readAgentHookStdin()), scope: scope, state: "working")
        case "prompt-submit", "pre-tool-use":
            emitProgramStatus(state: "working", app: app)
        case "stop":
            emitProgramStatus(state: "done", app: app)
        case "session-end":
            emitProgramStatus(state: "clear")
        case "notification":
            let parsed = parseClaudeHookInput(rawInput: readAgentHookStdin())
            let subtitle: String
            let body: String
            switch command {
            case "claude-hook":
                (subtitle, body) = summarizeAgentHookNotification(parsedInput: parsed, agentName: "Claude")
            case "codex-hook":
                (subtitle, body) = summarizeAgentHookNotification(parsedInput: parsed, agentName: "Codex")
            default:
                let message = ["message", "body", "text", "reason", "description"]
                    .lazy.compactMap { parsed.object?[$0] as? String }.first { !$0.isEmpty }
                let fallback = command == "opencode-hook" ? "OpenCode needs your attention" : "Agent needs your attention"
                (subtitle, body) = ("Permission", message ?? fallback)
            }
            emitProgramStatusForNotification(app: app, classifiedSubtitle: subtitle, body: body)
            if command == "claude-hook" {
                emitClaudeSubagentBlocked(parsed, scope: scope, classifiedSubtitle: subtitle, body: body)
            }
        default:
            break
        }
        return ack
    }

    /// The task description Claude gave a subagent, or its agent type; nil when the hook did
    /// not fire inside a subagent.
    func claudeSubagentTitle(_ parsed: ClaudeHookParsedInput) -> String? {
        guard let agentId = parsed.object?["agent_id"] as? String, !agentId.isEmpty else { return nil }
        return parsed.transcriptPath
            .flatMap { ClaudeSubagentTranscript.transcriptPath(sessionTranscriptPath: $0, agentId: agentId) }
            .flatMap(ClaudeSubagentTranscript.description(transcriptPath:))
            ?? (parsed.object?["agent_type"] as? String)
    }

    /// Reports a Claude Code subagent as the child record `agents/<task id>`, the id its socket
    /// record uses (as 32 hex digits), so the app merges the two and a terminal without the socket still sees
    /// each helper. `scope` is the workspace id the hooks fall back to without a session id.
    func emitClaudeSubagentStatus(
        _ parsed: ClaudeHookParsedInput,
        scope: String?,
        state: String,
        kind: String? = nil,
        msg: String? = nil
    ) {
        guard let agentId = parsed.object?["agent_id"] as? String, !agentId.isEmpty,
              let scope = parsed.sessionId ?? scope else { return }
        // A UUID is 36 characters and an id segment at most 32, so the dashes go.
        let taskId = claudeSubagentTaskIdentifier(scope: scope, externalAgentId: agentId)
            .replacingOccurrences(of: "-", with: "")
        emitProgramStatus(
            state: state,
            kind: kind,
            app: "claude-code",
            msg: msg,
            id: "agents/\(taskId)",
            title: claudeSubagentTitle(parsed)
        )
    }

    /// Permission -> blocked/permission, Waiting -> blocked/question, anything else -> idle.
    func emitProgramStatusForNotification(app: String, classifiedSubtitle: String, body: String) {
        switch classifiedSubtitle {
        case "Permission": emitProgramStatus(state: "blocked", kind: "permission", app: app, msg: body)
        case "Waiting": emitProgramStatus(state: "blocked", kind: "question", app: app, msg: body)
        default: emitProgramStatus(state: "idle", app: app, msg: body)
        }
    }

    /// A subagent's permission prompt or question marks its own child record blocked.
    func emitClaudeSubagentBlocked(
        _ parsed: ClaudeHookParsedInput,
        scope: String?,
        classifiedSubtitle: String,
        body: String
    ) {
        let kind: String
        switch classifiedSubtitle {
        case "Permission": kind = "permission"
        case "Waiting": kind = "question"
        default: return
        }
        emitClaudeSubagentStatus(parsed, scope: scope, state: "blocked", kind: kind, msg: body)
    }
}
