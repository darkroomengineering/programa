import Foundation
import CryptoKit
import Darwin
import TOML

struct ClaudeHookParsedInput {
    let object: [String: Any]?
    let rawFallback: String?
    let sessionId: String?
    let cwd: String?
    let transcriptPath: String?
}

struct ClaudeHookSessionRecord: Codable, Equatable {
    var sessionId: String
    var workspaceId: String
    var surfaceId: String
    var cwd: String?
    var pid: Int?
    var lastSubtitle: String?
    var lastBody: String?
    /// The open AskUserQuestion, from its PreToolUse until Claude resumes. Claude Code
    /// reports that dialog as a generic `permission_prompt`, so this is the only way to
    /// tell a question from a tool-approval prompt.
    var pendingQuestion: String? = nil
    var startedAt: TimeInterval
    var updatedAt: TimeInterval
    var transcriptPath: String? = nil
}

private struct ClaudeHookSessionStoreFile: Codable, Equatable {
    var version: Int = 1
    var sessions: [String: ClaudeHookSessionRecord] = [:]
}

final class ClaudeHookSessionStore {
    private static let defaultStatePath = "~/.programa/claude-hook-sessions.json"
    private static let maxStateAgeSeconds: TimeInterval = 60 * 60 * 24 * 7

    private let statePath: String
    private let fileManager: FileManager
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(
        processEnv: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) {
        if let overridePath = processEnv["PROGRAMA_CLAUDE_HOOK_STATE_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !overridePath.isEmpty {
            self.statePath = NSString(string: overridePath).expandingTildeInPath
        } else {
            self.statePath = NSString(string: Self.defaultStatePath).expandingTildeInPath
        }
        self.fileManager = fileManager
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func lookup(sessionId: String) -> ClaudeHookSessionRecord? {
        let normalized = normalizeSessionId(sessionId)
        guard !normalized.isEmpty else { return nil }
        // Read-only: writers replace the file atomically, so a reader needs no lock and
        // must not rewrite the file (or quarantine one it merely failed to decode).
        var state = (try? loadUnlocked()) ?? ClaudeHookSessionStoreFile()
        pruneExpired(&state)
        return state.sessions[normalized]
    }

    /// Read-only, like `lookup`.
    func allSessions() -> [ClaudeHookSessionRecord] {
        var state = (try? loadUnlocked()) ?? ClaudeHookSessionStoreFile()
        pruneExpired(&state)
        return Array(state.sessions.values)
    }

    func upsert(
        sessionId: String,
        workspaceId: String,
        surfaceId: String,
        cwd: String?,
        pid: Int? = nil,
        lastSubtitle: String? = nil,
        lastBody: String? = nil,
        pendingQuestion: String? = nil,
        transcriptPath: String? = nil
    ) throws {
        let normalized = normalizeSessionId(sessionId)
        guard !normalized.isEmpty else { return }
        try withLockedState { state in
            let now = Date().timeIntervalSince1970
            var record = state.sessions[normalized] ?? ClaudeHookSessionRecord(
                sessionId: normalized,
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                cwd: nil,
                pid: nil,
                lastSubtitle: nil,
                lastBody: nil,
                startedAt: now,
                updatedAt: now
            )
            record.workspaceId = workspaceId
            if !surfaceId.isEmpty {
                record.surfaceId = surfaceId
            }
            if let cwd = normalizeOptional(cwd) {
                record.cwd = cwd
            }
            if let pid {
                record.pid = pid
            }
            if let subtitle = normalizeOptional(lastSubtitle) {
                record.lastSubtitle = subtitle
            }
            if let body = normalizeOptional(lastBody) {
                record.lastBody = body
            }
            if let pendingQuestion = normalizeOptional(pendingQuestion) {
                record.pendingQuestion = pendingQuestion
            }
            if let transcriptPath = normalizeOptional(transcriptPath) {
                record.transcriptPath = transcriptPath
            }
            record.updatedAt = now
            state.sessions[normalized] = record
        }
    }

    func clearPendingQuestion(sessionId: String) throws {
        let normalized = normalizeSessionId(sessionId)
        guard !normalized.isEmpty else { return }
        try withLockedState { state in
            guard state.sessions[normalized] != nil else { return }
            state.sessions[normalized]?.pendingQuestion = nil
        }
    }

    func consume(
        sessionId: String?,
        workspaceId: String?,
        surfaceId: String?
    ) throws -> ClaudeHookSessionRecord? {
        let normalizedSessionId = normalizeOptional(sessionId)
        let normalizedWorkspace = normalizeOptional(workspaceId)
        let normalizedSurface = normalizeOptional(surfaceId)
        return try withLockedState { state in
            // An unrecorded id must not fall back: the surface's newest record may be a newer
            // live session (Claude /clear ends the old id after the new one started).
            if let normalizedSessionId {
                return state.sessions.removeValue(forKey: normalizedSessionId)
            }
            guard let fallback = fallbackRecord(
                sessions: Array(state.sessions.values),
                workspaceId: normalizedWorkspace,
                surfaceId: normalizedSurface
            ) else {
                return nil
            }
            state.sessions.removeValue(forKey: fallback.sessionId)
            return fallback
        }
    }

    private func fallbackRecord(
        sessions: [ClaudeHookSessionRecord],
        workspaceId: String?,
        surfaceId: String?
    ) -> ClaudeHookSessionRecord? {
        if let surfaceId {
            let matches = sessions.filter { $0.surfaceId == surfaceId }
            return matches.max(by: { $0.updatedAt < $1.updatedAt })
        }
        if let workspaceId {
            let matches = sessions.filter { $0.workspaceId == workspaceId }
            if matches.count == 1 {
                return matches[0]
            }
        }
        return nil
    }

    private func withLockedState<T>(_ body: (inout ClaudeHookSessionStoreFile) throws -> T) throws -> T {
        let parentURL = URL(fileURLWithPath: statePath).deletingLastPathComponent()
        try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true, attributes: nil)
        let lockPath = statePath + ".lock"
        let fd = open(lockPath, O_CREAT | O_RDWR, mode_t(S_IRUSR | S_IWUSR))
        if fd < 0 {
            throw CLIError(message: "Failed to open Claude hook state lock: \(lockPath)")
        }
        defer { Darwin.close(fd) }

        if flock(fd, LOCK_EX) != 0 {
            throw CLIError(message: "Failed to lock Claude hook state: \(lockPath)")
        }
        defer { _ = flock(fd, LOCK_UN) }

        let original: ClaudeHookSessionStoreFile
        do {
            original = try loadUnlocked()
        } catch is DecodingError {
            // Keep the unreadable file for inspection instead of silently wiping every
            // other session it may still describe.
            _ = try? fileManager.removeItem(atPath: statePath + ".corrupt")
            try fileManager.moveItem(atPath: statePath, toPath: statePath + ".corrupt")
            original = ClaudeHookSessionStoreFile()
        }
        var state = original
        pruneExpired(&state)
        let result = try body(&state)
        if state != original {
            try saveUnlocked(state)
        }
        return result
    }

    /// An absent file is an empty store. A file that exists but cannot be read throws,
    /// so a writer never overwrites state it could not see.
    private func loadUnlocked() throws -> ClaudeHookSessionStoreFile {
        guard fileManager.fileExists(atPath: statePath) else {
            return ClaudeHookSessionStoreFile()
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: statePath))
        return try decoder.decode(ClaudeHookSessionStoreFile.self, from: data)
    }

    private func saveUnlocked(_ state: ClaudeHookSessionStoreFile) throws {
        let stateURL = URL(fileURLWithPath: statePath)
        let data = try encoder.encode(state)
        try data.write(to: stateURL, options: .atomic)
    }

    private func pruneExpired(_ state: inout ClaudeHookSessionStoreFile) {
        let now = Date().timeIntervalSince1970
        let cutoff = now - Self.maxStateAgeSeconds
        state.sessions = state.sessions.filter { _, record in
            record.updatedAt >= cutoff
        }
    }

    private func normalizeSessionId(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizeOptional(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}

let codexHookWrapperProcessNames: Set<String> = [
    "sh",
    "bash",
    "zsh",
    "env"
]

/// Notification content a provider adapter derives from its hook payload.
struct AgentHookNotification {
    let subtitle: String
    var body: String
    /// Decides whether the notification blocks the agent ("Permission"/"Waiting" do).
    /// Equals `subtitle` except for providers whose notification event is always one kind.
    let classifiedSubtitle: String
}

/// Completion notice a provider adapter derives from its `stop` payload, plus what the
/// session store remembers about it for a later `notification` event.
struct AgentHookCompletion {
    let subtitle: String
    let body: String
    let storedSubtitle: String
    let storedBody: String?
}

/// Per-invocation inputs the shared hook state machine hands to its handlers.
struct AgentHookContext {
    let client: SocketClient
    let parsed: ClaudeHookParsedInput
    let store: ClaudeHookSessionStore
    let workspaceArg: String?
    let surfaceArg: String?
}

/// Everything that differs between the Claude Code, Codex and OpenCode hooks. The
/// shared state machine (`runAgentHook`) drives the socket traffic; a provider only
/// names its identifiers and translates its payloads.
struct AgentHookProvider {
    let commandName: String
    /// Provider name on `agent.event` / `surface.report_agent_state`.
    let provider: String
    /// Notification title.
    let title: String
    /// `workspace.set_status` / `workspace.set_agent_pid` key for the status entry.
    let statusKey: String
    /// Stdout token printed once an event is handled (Codex and OpenCode expect JSON).
    let ack: String
    let helpLine: String
    /// Codex and OpenCode hooks can be invoked from any terminal, so they no-op outside programa.
    let requiresSurfaceEnv: Bool
    /// Fixed store file under ~/.programa; nil honors PROGRAMA_CLAUDE_HOOK_STATE_PATH.
    let stateFileName: String?
    /// When set, `session-end` also finishes this host's helper tasks for the session.
    let taskHost: String?
    /// Re-register the agent pid on every event, not only at session start.
    let refreshesAgentPid: Bool
    let pidKey: (String?) -> String
    let startPid: () -> Int?
    let inferPid: () -> Int?
    let completion: (ClaudeHookParsedInput, ClaudeHookSessionRecord?) -> AgentHookCompletion?
    let notification: (ClaudeHookParsedInput, ClaudeHookSessionRecord?) -> AgentHookNotification
    /// Provider-only events, keyed by subcommand.
    let extraEvents: [String: (AgentHookContext) -> Void]
}

extension ProgramaCLI {
    func runClaudeHook(commandArgs: [String], client: SocketClient) throws {
        try runAgentHook(claudeHookProvider(), commandArgs: commandArgs, client: client)
    }

    /// Codex hook handler. Gracefully no-ops when not running inside programa.
    func runCodexHook(commandArgs: [String], client: SocketClient) throws {
        try runAgentHook(codexHookProvider(), commandArgs: commandArgs, client: client)
    }

    /// OpenCode plugin hook handler. Gracefully no-ops when not running inside programa.
    ///
    /// Unlike claude-hook/codex-hook, OpenCode has no shell-hook config to gate
    /// invocation on $PROGRAMA_SURFACE_ID: the local plugin (`openCodePluginJS`) calls
    /// `programa opencode-hook <event> --cwd ... --session ...` directly, so the guard
    /// lives in the provider (also gated earlier in `run()` and
    /// `validateRegisteredArguments`, before any socket connection is attempted).
    /// The plugin passes `--cwd`/`--session` as CLI args rather than stdin JSON; stdin
    /// is still read and tolerated. A turn ending and permission.asked can fire close
    /// together; the writes are idempotent, so repeated firing is harmless.
    func runOpenCodeHook(commandArgs: [String], client: SocketClient) throws {
        try runAgentHook(openCodeHookProvider(), commandArgs: commandArgs, client: client)
    }

    /// The stdout token an agent hook prints when programa is unreachable, or nil for a
    /// command that is not an agent hook.
    func failOpenHookAck(command: String) -> String? {
        switch command {
        case "claude-hook": return claudeHookProvider().ack
        case "codex-hook": return codexHookProvider().ack
        case "opencode-hook": return openCodeHookProvider().ack
        default: return nil
        }
    }

    private func claudeHookProvider() -> AgentHookProvider {
        AgentHookProvider(
            commandName: "claude-hook",
            provider: "claude-code",
            title: "Claude Code",
            statusKey: "claude_code",
            ack: "OK",
            helpLine: "programa claude-hook <session-start|stop|session-end|notification|prompt-submit|pre-tool-use|subagent-start|subagent-stop> [--workspace <id|index>] [--surface <id|index>]",
            requiresSurfaceEnv: false,
            stateFileName: nil,
            taskHost: "claude",
            refreshesAgentPid: false,
            pidKey: { _ in "claude_code" },
            startPid: {
                guard let raw = ProcessInfo.processInfo.environment["PROGRAMA_CLAUDE_PID"]?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                    let pid = Int(raw),
                    pid > 0 else {
                    return nil
                }
                return pid
            },
            inferPid: { nil },
            completion: { parsed, session in
                self.summarizeClaudeHookStop(parsedInput: parsed, sessionRecord: session).map {
                    AgentHookCompletion(subtitle: $0.subtitle, body: $0.body, storedSubtitle: $0.subtitle, storedBody: $0.body)
                }
            },
            notification: { parsed, session in
                self.savedBodyNotification(self.summarizeAgentHookNotification(parsedInput: parsed, agentName: "Claude"), session: session)
            },
            extraEvents: [
                "pre-tool-use": { self.runClaudePreToolUse($0) },
                "subagent-start": { self.runClaudeSubagentStart($0) },
                "subagent-stop": { self.runClaudeSubagentStop($0) },
            ]
        )
    }

    private func codexHookProvider() -> AgentHookProvider {
        AgentHookProvider(
            commandName: "codex-hook",
            provider: "codex",
            title: "Codex",
            statusKey: "codex",
            ack: "{}",
            helpLine: "programa codex-hook <session-start|prompt-submit|stop|notification|session-end> [--workspace <id>] [--surface <id>]",
            requiresSurfaceEnv: true,
            stateFileName: "codex-hook-sessions.json",
            taskHost: nil,
            refreshesAgentPid: true,
            pidKey: { Self.sessionScopedPIDKey("codex", sessionId: $0) },
            startPid: { self.inferredCodexAgentPID() },
            inferPid: { self.inferredCodexAgentPID() },
            completion: { parsed, session in
                self.plainStopCompletion(
                    name: "Codex",
                    messageKeys: ["last_assistant_message", "lastAssistantMessage"],
                    parsed: parsed,
                    session: session
                )
            },
            notification: { parsed, session in
                self.savedBodyNotification(self.summarizeAgentHookNotification(parsedInput: parsed, agentName: "Codex"), session: session)
            },
            extraEvents: [:]
        )
    }

    private func openCodeHookProvider() -> AgentHookProvider {
        AgentHookProvider(
            commandName: "opencode-hook",
            provider: "opencode",
            title: "OpenCode",
            statusKey: "opencode",
            ack: "{}",
            helpLine: "programa opencode-hook <session-start|prompt-submit|stop|notification|session-end> [--cwd <path>] [--session <id>] [--workspace <id>] [--surface <id>]",
            requiresSurfaceEnv: true,
            stateFileName: "opencode-hook-sessions.json",
            taskHost: nil,
            refreshesAgentPid: true,
            pidKey: { Self.sessionScopedPIDKey("opencode", sessionId: $0) },
            startPid: { self.inferredCodexAgentPID() },
            inferPid: { self.inferredCodexAgentPID() },
            // The turn-end events carry no transcript/message payload, so the completion body
            // stays generic unless a future stdin JSON payload supplies one.
            completion: { parsed, session in
                self.plainStopCompletion(
                    name: "OpenCode",
                    messageKeys: ["message", "last_assistant_message", "lastAssistantMessage", "body", "text"],
                    parsed: parsed,
                    session: session
                )
            },
            // The notification hook only ever fires for permission.asked, so it is always a
            // blocking approval prompt; there is no ambiguous "Attention" case to classify.
            notification: { parsed, _ in
                let message = parsed.object.flatMap {
                    self.firstString(in: $0, keys: ["message", "body", "text", "reason", "description"])
                }
                return AgentHookNotification(
                    subtitle: "Attention",
                    body: message.map { self.normalizedSingleLine($0) } ?? "OpenCode needs your attention",
                    classifiedSubtitle: "Permission"
                )
            },
            extraEvents: [:]
        )
    }

    private static func sessionScopedPIDKey(_ name: String, sessionId: String?) -> String {
        guard let sessionId = sessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionId.isEmpty else {
            return name
        }
        return "\(name).\(sessionId)"
    }

    private func plainStopCompletion(
        name: String,
        messageKeys: [String],
        parsed: ClaudeHookParsedInput,
        session: ClaudeHookSessionRecord?
    ) -> AgentHookCompletion {
        let projectName: String? = (parsed.cwd ?? session?.cwd).flatMap { cwd in
            cwd.isEmpty ? nil : URL(fileURLWithPath: NSString(string: cwd).expandingTildeInPath).lastPathComponent
        }
        let lastMessage = parsed.object.flatMap { firstString(in: $0, keys: messageKeys) }
        var subtitle = "Completed"
        if let projectName, !projectName.isEmpty {
            subtitle = "Completed in \(projectName)"
        }
        return AgentHookCompletion(
            subtitle: subtitle,
            body: lastMessage.map { truncate(normalizedSingleLine($0), maxLength: 200) } ?? "\(name) session completed",
            storedSubtitle: "Completed",
            storedBody: lastMessage.map { truncate($0, maxLength: 200) }
        )
    }

    /// An open AskUserQuestion wins over whatever the notification says. Otherwise a generic
    /// "needs your attention" notification takes the message the preceding hook saved.
    private func savedBodyNotification(
        _ summary: (subtitle: String, body: String),
        session: ClaudeHookSessionRecord?
    ) -> AgentHookNotification {
        var summary = summary
        if let question = session?.pendingQuestion {
            summary = (subtitle: "Waiting", body: question)
        } else if let session,
           let savedBody = session.lastBody, !savedBody.isEmpty,
           summary.body.contains("needs your attention") || summary.body.contains("needs your input") {
            summary = (subtitle: session.lastSubtitle ?? summary.subtitle, body: savedBody)
        }
        return AgentHookNotification(subtitle: summary.subtitle, body: summary.body, classifiedSubtitle: summary.subtitle)
    }

    /// The shared hook state machine: every provider event maps onto the same
    /// `agent.event` / `surface.report_agent_state` reporting. A socket failure that only
    /// means programa is gone or torn down (see `shouldIgnoreClaudeHookTeardownError`)
    /// must never block the agent's next hook, so it still prints the provider's ack.
    func runAgentHook(
        _ hook: AgentHookProvider,
        commandArgs: [String],
        client: SocketClient
    ) throws {
        let env = ProcessInfo.processInfo.environment
        if hook.requiresSurfaceEnv, env["PROGRAMA_SURFACE_ID"] == nil {
            print(hook.ack)
            return
        }

        let rawSubcommand = commandArgs.first?.lowercased() ?? "help"
        let subcommand = ["active": "session-start", "idle": "stop", "notify": "notification"][rawSubcommand] ?? rawSubcommand
        let hookArgs = Array(commandArgs.dropFirst())
        let hookWsFlag = optionValue(hookArgs, name: "--workspace")
        let rawInput = readAgentHookStdin()
        let context = AgentHookContext(
            client: client,
            parsed: parseAgentHookInput(rawInput: rawInput, hookArgs: hookArgs),
            store: ClaudeHookSessionStore(
                processEnv: hook.stateFileName.map {
                    env.merging(["PROGRAMA_CLAUDE_HOOK_STATE_PATH": "~/.programa/\($0)"], uniquingKeysWith: { _, new in new })
                } ?? env
            ),
            workspaceArg: hookWsFlag ?? env["PROGRAMA_WORKSPACE_ID"],
            surfaceArg: optionValue(hookArgs, name: "--surface") ?? (hookWsFlag == nil ? env["PROGRAMA_SURFACE_ID"] : nil)
        )

        do {
            switch subcommand {
            case "session-start": try agentHookSessionStart(hook, context)
            case "prompt-submit": try agentHookPromptSubmit(hook, context)
            case "stop": try agentHookStop(hook, context)
            case "notification": try agentHookNotification(hook, context)
            case "session-end": agentHookSessionEnd(hook, context)
            case "help", "--help", "-h":
                print(hook.helpLine)
                return
            default:
                guard let extra = hook.extraEvents[subcommand] else {
                    throw CLIError(message: "Unknown \(hook.commandName) subcommand: \(subcommand)")
                }
                extra(context)
            }
            print(hook.ack)
        } catch {
            guard shouldIgnoreClaudeHookTeardownError(error) else { throw error }
            print(hook.ack)
        }
    }

    private func agentHookSessionStart(_ hook: AgentHookProvider, _ ctx: AgentHookContext) throws {
        let workspaceId = try resolvePreferredWorkspaceIdForClaudeHook(preferred: nil, fallback: ctx.workspaceArg, client: ctx.client)
        let surfaceId = try resolvePreferredSurfaceIdForClaudeHook(
            preferred: nil, fallback: ctx.surfaceArg, workspaceId: workspaceId, client: ctx.client
        )
        let pid = hook.startPid()
        if let sessionId = ctx.parsed.sessionId {
            try? ctx.store.upsert(
                sessionId: sessionId, workspaceId: workspaceId, surfaceId: surfaceId, cwd: ctx.parsed.cwd, pid: pid,
                transcriptPath: ctx.parsed.transcriptPath
            )
        }
        // Registers the pid for stale-session detection and OSC suppression but sets no
        // visible status: "Running" only appears once a prompt is submitted or work starts.
        if let pid {
            setAgentPid(hook, ctx, workspaceId: workspaceId, sessionId: ctx.parsed.sessionId, pid: pid)
        }
        reportAgentEvent(client: ctx.client, provider: hook.provider, eventType: "session.started", workspaceId: workspaceId, surfaceId: surfaceId, sessionId: ctx.parsed.sessionId, transcriptPath: ctx.parsed.transcriptPath)
    }

    private func agentHookPromptSubmit(_ hook: AgentHookProvider, _ ctx: AgentHookContext) throws {
        let mapped = ctx.parsed.sessionId.flatMap { ctx.store.lookup(sessionId: $0) }
        clearPendingQuestion(ctx, mapped)
        let workspaceId = try resolvePreferredWorkspaceIdForClaudeHook(
            preferred: mapped?.workspaceId, fallback: ctx.workspaceArg, client: ctx.client
        )
        if hook.refreshesAgentPid {
            let pid = mapped?.pid ?? hook.inferPid()
            if let sessionId = ctx.parsed.sessionId, let mapped {
                try? ctx.store.upsert(
                    sessionId: sessionId,
                    workspaceId: workspaceId,
                    surfaceId: mapped.surfaceId,
                    cwd: ctx.parsed.cwd ?? mapped.cwd,
                    pid: pid,
                    transcriptPath: ctx.parsed.transcriptPath
                )
            }
            if let pid {
                setAgentPid(hook, ctx, workspaceId: workspaceId, sessionId: ctx.parsed.sessionId ?? mapped?.sessionId, pid: pid)
            }
        }
        _ = try? ctx.client.sendV2(method: V2MethodNames.notificationClear, params: ["workspace_id": workspaceId])
        let surfaceId = try resolvePreferredSurfaceIdForClaudeHook(
            preferred: mapped?.surfaceId, fallback: ctx.surfaceArg, workspaceId: workspaceId, client: ctx.client
        )
        reportAgentStateAndEvent(client: ctx.client, provider: hook.provider, eventType: "turn.started", workspaceId: workspaceId, surfaceId: surfaceId, state: .working, sessionId: ctx.parsed.sessionId, transcriptPath: ctx.parsed.transcriptPath)
    }

    private func agentHookStop(_ hook: AgentHookProvider, _ ctx: AgentHookContext) throws {
        // The turn ended, not the agent: keep the session and its pid. The Notification
        // hook handles user-facing attention; SessionEnd handles cleanup.
        let mapped = ctx.parsed.sessionId.flatMap { ctx.store.lookup(sessionId: $0) }
        clearPendingQuestion(ctx, mapped)
        let workspaceId = try resolvePreferredWorkspaceIdForClaudeHook(
            preferred: mapped?.workspaceId, fallback: ctx.workspaceArg, client: ctx.client
        )
        let surfaceId = try resolvePreferredSurfaceIdForClaudeHook(
            preferred: mapped?.surfaceId, fallback: ctx.surfaceArg, workspaceId: workspaceId, client: ctx.client
        )
        let pid = mapped?.pid ?? hook.inferPid()
        let completion = hook.completion(ctx.parsed, mapped)

        if let sessionId = ctx.parsed.sessionId, let completion {
            try? ctx.store.upsert(
                sessionId: sessionId,
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                cwd: ctx.parsed.cwd ?? mapped?.cwd,
                pid: pid,
                lastSubtitle: completion.storedSubtitle,
                lastBody: completion.storedBody,
                transcriptPath: ctx.parsed.transcriptPath
            )
        }
        if hook.refreshesAgentPid, let pid {
            setAgentPid(hook, ctx, workspaceId: workspaceId, sessionId: ctx.parsed.sessionId ?? mapped?.sessionId, pid: pid)
        }
        if let completion {
            _ = try? ctx.client.sendV2(method: V2MethodNames.notificationCreateForTarget, params: [
                "workspace_id": workspaceId,
                "surface_id": surfaceId,
                "title": hook.title,
                "subtitle": sanitizeNotificationField(completion.subtitle),
                "body": sanitizeNotificationField(completion.body),
            ])
        }
        try? setAgentStatus(
            client: ctx.client, key: hook.statusKey, workspaceId: workspaceId,
            value: "Idle", icon: "pause.circle.fill", color: "#8E8E93"
        )
        reportAgentStateAndEvent(client: ctx.client, provider: hook.provider, eventType: "turn.completed", workspaceId: workspaceId, surfaceId: surfaceId, state: .idle, sessionId: ctx.parsed.sessionId, transcriptPath: ctx.parsed.transcriptPath)
    }

    private func agentHookNotification(_ hook: AgentHookProvider, _ ctx: AgentHookContext) throws {
        let mapped = ctx.parsed.sessionId.flatMap { ctx.store.lookup(sessionId: $0) }
        let workspaceId = try resolvePreferredWorkspaceIdForClaudeHook(
            preferred: mapped?.workspaceId, fallback: ctx.workspaceArg, client: ctx.client
        )
        var notification = hook.notification(ctx.parsed, mapped)
        if hook.provider == "claude-code", let helper = claudeSubagentTitle(ctx.parsed) {
            emitClaudeSubagentBlocked(ctx.parsed, scope: workspaceId, classifiedSubtitle: notification.classifiedSubtitle, body: notification.body)
            notification.body = "\(helper): \(notification.body)"
        }
        let surfaceId = try resolvePreferredSurfaceIdForClaudeHook(
            preferred: mapped?.surfaceId, fallback: ctx.surfaceArg, workspaceId: workspaceId, client: ctx.client
        )
        let pid = mapped?.pid ?? hook.inferPid()

        if let sessionId = ctx.parsed.sessionId {
            try? ctx.store.upsert(
                sessionId: sessionId,
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                cwd: ctx.parsed.cwd,
                pid: pid,
                lastSubtitle: notification.subtitle,
                lastBody: notification.body,
                transcriptPath: ctx.parsed.transcriptPath
            )
        }
        if hook.refreshesAgentPid, let pid {
            setAgentPid(hook, ctx, workspaceId: workspaceId, sessionId: ctx.parsed.sessionId ?? mapped?.sessionId, pid: pid)
        }
        reportClassifiedAgentNotification(
            client: ctx.client,
            provider: hook.provider,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            title: hook.title,
            subtitle: sanitizeNotificationField(notification.subtitle),
            body: sanitizeNotificationField(notification.body),
            classifiedSubtitle: notification.classifiedSubtitle,
            sessionId: ctx.parsed.sessionId,
            pid: pid
        )
    }

    /// Final cleanup when the agent process exits (also covers a Stop that never fired).
    /// The hook runs under a ~1 s budget, so nothing before the state clear may touch the
    /// socket: the session is consumed from the local store first, and only when that
    /// finds nothing are workspace/surface refs resolved for the fallback match. The
    /// surface's agent state is then cleared before the secondary cleanups.
    private func agentHookSessionEnd(_ hook: AgentHookProvider, _ ctx: AgentHookContext) {
        let sessionId = ctx.parsed.sessionId
        let mapped = sessionId.flatMap { ctx.store.lookup(sessionId: $0) }
        func local(_ raw: String?) -> String? {
            nonEmptyClaudeHookIdentifier(raw).flatMap { isUUID($0) ? $0 : nil }
        }
        let localWorkspaceId = local(mapped?.workspaceId) ?? local(ctx.workspaceArg)
        let localSurfaceId = local(mapped?.surfaceId) ?? local(ctx.surfaceArg)
        var consumed = try? ctx.store.consume(sessionId: sessionId, workspaceId: localWorkspaceId, surfaceId: localSurfaceId)
        if consumed == nil, localWorkspaceId == nil || localSurfaceId == nil {
            let workspaceId = try? resolvePreferredWorkspaceIdForClaudeHook(
                preferred: mapped?.workspaceId, fallback: ctx.workspaceArg, client: ctx.client
            )
            let surfaceId = workspaceId.flatMap {
                try? resolvePreferredSurfaceIdForClaudeHook(
                    preferred: mapped?.surfaceId, fallback: ctx.surfaceArg, workspaceId: $0, client: ctx.client
                )
            }
            consumed = try? ctx.store.consume(sessionId: sessionId, workspaceId: workspaceId, surfaceId: surfaceId)
        }
        recordEndedAgentSession(
            provider: hook.provider, sessionId: sessionId, consumed: consumed, cwd: ctx.parsed.cwd,
            workspaceId: localWorkspaceId, surfaceId: localSurfaceId, transcriptPath: ctx.parsed.transcriptPath
        )

        if let consumed, !consumed.surfaceId.isEmpty {
            clearAgentStateAndReportEvent(client: ctx.client, provider: hook.provider, eventType: "session.exited", workspaceId: consumed.workspaceId, surfaceId: consumed.surfaceId, sessionId: sessionId)
        }
        if let taskHost = hook.taskHost, let sessionId {
            _ = try? ctx.client.sendV2(method: V2MethodNames.agentTaskFinishSession, params: [
                "host": taskHost,
                "session": sessionId,
                "state": "cancelled",
            ])
        }
        if let consumed {
            let workspaceId = consumed.workspaceId
            _ = try? ctx.client.sendV2(method: V2MethodNames.workspaceClearStatus, params: ["workspace_id": workspaceId, "key": hook.statusKey])
            _ = try? ctx.client.sendV2(method: V2MethodNames.workspaceClearAgentPid, params: [
                "workspace_id": workspaceId,
                "key": hook.pidKey(sessionId ?? consumed.sessionId),
            ])
            _ = try? ctx.client.sendV2(method: V2MethodNames.notificationClear, params: ["workspace_id": workspaceId])
        }
    }

    /// Claude resumed (next tool, prompt, or turn end), so its question dialog is closed
    /// and a later `permission_prompt` is a real tool approval.
    private func clearPendingQuestion(_ ctx: AgentHookContext, _ session: ClaudeHookSessionRecord?) {
        guard session?.pendingQuestion != nil, let sessionId = ctx.parsed.sessionId else { return }
        try? ctx.store.clearPendingQuestion(sessionId: sessionId)
    }

    private func setAgentPid(
        _ hook: AgentHookProvider,
        _ ctx: AgentHookContext,
        workspaceId: String,
        sessionId: String?,
        pid: Int
    ) {
        _ = try? ctx.client.sendV2(method: V2MethodNames.workspaceSetAgentPid, params: [
            "workspace_id": workspaceId,
            "key": hook.pidKey(sessionId),
            "pid": pid,
        ])
    }

    /// Claude-only: clears "Needs input" status and notification when Claude resumes work
    /// (e.g. after permission grant). Runs async so it doesn't block tool execution.
    private func runClaudePreToolUse(_ ctx: AgentHookContext) {
        emitClaudeSubagentStatus(ctx.parsed, scope: ctx.workspaceArg, state: "working")
        let client = ctx.client
        let mappedSession = ctx.parsed.sessionId.flatMap { ctx.store.lookup(sessionId: $0) }

        // Deliberately best-effort, for the same reason as the surfaceId resolution
        // further down. A throw here would abort the hook before any of the three
        // independent clears below, while Claude Code continued with a stale red
        // "blocked" badge that nothing would clear.
        //
        // Nothing recovers from that. There is no TTL or watchdog on agent state, and
        // AgentScreenDetectionEngine deliberately refuses to touch a surface a hook has
        // claimed (its `hooksOwned` guard), so the terminal can be visibly running a
        // command while the sidebar still reads "Claude needs your permission" until the
        // session ends.
        //
        // Falling back to the identifiers the Notification hook recorded is the whole
        // point: those are the exact workspace and surface it marked blocked, so they
        // are the right things to clear even when a live re-resolution is unavailable.
        let resolvedWorkspaceId = (try? resolvePreferredWorkspaceIdForClaudeHook(
            preferred: mappedSession?.workspaceId,
            fallback: ctx.workspaceArg,
            client: client
        ))
            ?? nonEmptyClaudeHookIdentifier(mappedSession?.workspaceId).flatMap { isUUID($0) ? $0 : nil }
            ?? nonEmptyClaudeHookIdentifier(ctx.workspaceArg).flatMap { isUUID($0) ? $0 : nil }

        // Only when there is genuinely no workspace to name is there nothing to clear.
        guard let workspaceId = resolvedWorkspaceId else { return }
        let claudePid = mappedSession?.pid

        // AskUserQuestion means Claude is about to ask the user something.
        // Save question text in session so the Notification handler can use it
        // instead of the generic "Claude Code needs your attention".
        if let toolName = ctx.parsed.object?["tool_name"] as? String,
           toolName == "AskUserQuestion",
           let question = describeAskUserQuestion(ctx.parsed.object),
           let sessionId = ctx.parsed.sessionId {
            // Preserve the existing surfaceId from SessionStart; passing ""
            // would overwrite it and cause notifications to target the wrong workspace.
            let existingSurfaceId = ctx.store.lookup(sessionId: sessionId)?.surfaceId ?? ""
            try? ctx.store.upsert(
                sessionId: sessionId,
                workspaceId: workspaceId,
                surfaceId: existingSurfaceId,
                cwd: ctx.parsed.cwd,
                lastSubtitle: "Waiting",
                lastBody: question,
                pendingQuestion: question
            )
            // Don't clear notifications or set status here.
            // The Notification hook fires right after and will use the saved question.
            return
        }
        clearPendingQuestion(ctx, mappedSession)

        // Best-effort, not `try`: a throw would abort the hook before the three clears
        // below and leave the blocked badge lit while Claude runs. Only reportAgentState
        // needs a surface; the notification and status clears are workspace-scoped and
        // must still run.
        let surfaceId = try? resolvePreferredSurfaceIdForClaudeHook(
            preferred: mappedSession?.surfaceId,
            fallback: ctx.surfaceArg,
            workspaceId: workspaceId,
            client: client
        )

        // Clear the badge first, unless Claude reports its own state: this hook is async, and a
        // late "working" would override Claude's idle after an Esc (claudeReportsOwnStatus).
        if let surfaceId, !claudeReportsOwnStatus {
            reportAgentStateAndEvent(client: client, provider: "claude-code", eventType: "item.started", workspaceId: workspaceId, surfaceId: surfaceId, state: .working, sessionId: ctx.parsed.sessionId, pid: claudePid)
        }

        _ = try? client.sendV2(method: V2MethodNames.notificationClear, params: ["workspace_id": workspaceId])

        // The sidebar badge (SidebarAgentIndicator) carries "Working" on its own; the
        // metadata-row status entry is opt-in verbose detail only, and only when there's
        // actual tool text to show -- no generic "Running" row.
        if UserDefaults.standard.bool(forKey: "claudeCodeVerboseStatus"),
           let toolStatus = describeToolUse(ctx.parsed.object) {
            // Best-effort: benign if TabManager is already torn down.
            try? setAgentStatus(
                client: client,
                key: "claude_code",
                workspaceId: workspaceId,
                value: toolStatus,
                icon: "bolt.fill",
                color: "#4C8DFF",
                pid: claudePid
            )
        }
    }

    /// Claude-only: tracks a helper (subagent) as a virtual task record in the sidebar helpers popover.
    private func runClaudeSubagentStart(_ ctx: AgentHookContext) {
        let client = ctx.client
        let mappedSession = ctx.parsed.sessionId.flatMap { ctx.store.lookup(sessionId: $0) }
        guard let externalAgentId = firstString(in: ctx.parsed.object ?? [:], keys: ["agent_id"]),
              let workspaceId = try? resolvePreferredWorkspaceIdForClaudeHook(
                preferred: mappedSession?.workspaceId,
                fallback: ctx.workspaceArg,
                client: client
              ) else {
            return
        }
        let surfaceId = try? resolvePreferredSurfaceIdForClaudeHook(
            preferred: mappedSession?.surfaceId,
            fallback: ctx.surfaceArg,
            workspaceId: workspaceId,
            client: client
        )
        let taskId = claudeSubagentTaskIdentifier(
            scope: ctx.parsed.sessionId ?? workspaceId,
            externalAgentId: externalAgentId
        )
        let agentType = firstString(in: ctx.parsed.object ?? [:], keys: ["agent_type"])
        let description = ctx.parsed.transcriptPath
            .flatMap { ClaudeSubagentTranscript.transcriptPath(sessionTranscriptPath: $0, agentId: externalAgentId) }
            .flatMap(ClaudeSubagentTranscript.description(transcriptPath:))
        var startParams: [String: Any] = [
            "agent_id": taskId,
            "workspace_id": workspaceId,
            "host": "claude",
            "placement": "runs_with_parent",
            "state": "working",
        ]
        if let surfaceId { startParams["surface_id"] = surfaceId }
        if let sessionId = ctx.parsed.sessionId { startParams["session"] = sessionId }
        if let agentType { startParams["role"] = agentType }
        if let task = description ?? agentType { startParams["task"] = task }
        emitClaudeSubagentStatus(ctx.parsed, scope: workspaceId, state: "working")
        do {
            _ = try client.sendV2(method: V2MethodNames.agentTaskStart, params: startParams)
        } catch {
            var updateParams: [String: Any] = ["agent_id": taskId, "state": "working"]
            if let sessionId = ctx.parsed.sessionId { updateParams["session"] = sessionId }
            if let agentType { updateParams["role"] = agentType }
            if let task = description ?? agentType { updateParams["task"] = task }
            _ = try? client.sendV2(method: V2MethodNames.agentTaskUpdate, params: updateParams)
        }
    }

    private func runClaudeSubagentStop(_ ctx: AgentHookContext) {
        let client = ctx.client
        let mappedSession = ctx.parsed.sessionId.flatMap { ctx.store.lookup(sessionId: $0) }
        guard let externalAgentId = firstString(in: ctx.parsed.object ?? [:], keys: ["agent_id"]),
              let workspaceId = try? resolvePreferredWorkspaceIdForClaudeHook(
                preferred: mappedSession?.workspaceId,
                fallback: ctx.workspaceArg,
                client: client
              ) else {
            return
        }
        let taskId = claudeSubagentTaskIdentifier(
            scope: ctx.parsed.sessionId ?? workspaceId,
            externalAgentId: externalAgentId
        )
        let object = ctx.parsed.object ?? [:]
        let agentTranscriptPath = firstString(in: object, keys: ["agent_transcript_path"]).map {
            ($0 as NSString).expandingTildeInPath
        } ?? ctx.parsed.transcriptPath.flatMap {
            ClaudeSubagentTranscript.transcriptPath(sessionTranscriptPath: $0, agentId: externalAgentId)
        }
        let description = agentTranscriptPath.flatMap(ClaudeSubagentTranscript.description(transcriptPath:))
        let report = agentTranscriptPath.flatMap(ClaudeSubagentTranscript.handbackMessage(transcriptPath:))
            ?? firstString(in: object, keys: ["last_assistant_message"])
        // The socket caps a summary at 16 KiB; cut bytes, not characters.
        let summary = report.map { String(decoding: Data($0.utf8.prefix(16_000)), as: UTF8.self) }
        let firstLine = report?.split(whereSeparator: \.isNewline).first { !$0.allSatisfy(\.isWhitespace) }
        let agentType = firstString(in: object, keys: ["agent_type"])
        var finishParams: [String: Any] = ["agent_id": taskId, "state": "completed"]
        if let description { finishParams["task"] = description }
        if let summary { finishParams["summary"] = summary }
        let finished = (try? client.sendV2(method: V2MethodNames.agentTaskFinish, params: finishParams)) != nil
        // Claude Code's internal forks (agent summaries, prompt suggestions, side questions) fire
        // SubagentStop with an empty agent_type and never fire SubagentStart; they get no row.
        guard finished || agentType != nil else { return }
        emitClaudeSubagentStatus(ctx.parsed, scope: workspaceId, state: "done", msg: firstLine.map(String.init))
        if !finished {
            let surfaceId = try? resolvePreferredSurfaceIdForClaudeHook(
                preferred: mappedSession?.surfaceId,
                fallback: ctx.surfaceArg,
                workspaceId: workspaceId,
                client: client
            )
            var completedParams: [String: Any] = [
                "agent_id": taskId,
                "workspace_id": workspaceId,
                "host": "claude",
                "placement": "runs_with_parent",
                "state": "completed",
            ]
            if let surfaceId { completedParams["surface_id"] = surfaceId }
            if let sessionId = ctx.parsed.sessionId { completedParams["session"] = sessionId }
            if let agentType { completedParams["role"] = agentType }
            if let task = description ?? agentType { completedParams["task"] = task }
            if let summary { completedParams["summary"] = summary }
            _ = try? client.sendV2(method: V2MethodNames.agentTaskStart, params: completedParams)
        }
    }

    private func setAgentStatus(
        client: SocketClient,
        key: String,
        workspaceId: String,
        value: String,
        icon: String,
        color: String,
        pid: Int? = nil
    ) throws {
        var params: [String: Any] = [
            "workspace_id": workspaceId,
            "key": key,
            "value": value,
            "icon": icon,
            "color": color,
        ]
        if let pid {
            params["pid"] = pid
        }
        _ = try client.sendV2(method: V2MethodNames.workspaceSetStatus, params: params)
    }

    // MARK: - Agent activity state (issue #164, v1 hook tier)
    //
    // Reports the working/blocked/idle state surfaced as tab/sidebar/menu-bar badges.
    // Hooks are the sole source of truth for this tier — there is no screen-rule fallback,
    // so every call site below maps a concrete, unambiguous hook signal to a state.
    // Strict-blocked rule: only an explicit permission/approval/question signal maps to
    // "blocked"; anything ambiguous (errors, generic "needs attention", unclassified
    // messages) maps to "idle" rather than risk a false blocked badge.
    //
    // `CLIAgentActivityState` mirrors `AgentActivityState` (Sources/AgentActivityState.swift)
    // by raw value only — the `programa-cli` target is a separate build target from the app
    // (GhosttyTabs) and cannot import its types, so both sides agree on the wire format
    // ("working" | "blocked" | "idle") rather than sharing a Swift type.
    enum CLIAgentActivityState: String {
        case working
        case blocked
        case idle
    }

    /// Maps a hook notification's classified subtitle (see classifyAgentNotification) to an
    /// agent activity state. Only "Permission" (approval prompt) and "Waiting"
    /// (AskUserQuestion / idle-prompt) are genuine blocking signals.
    func agentStateForClassifiedNotificationSubtitle(_ subtitle: String) -> CLIAgentActivityState {
        switch subtitle {
        case "Permission", "Waiting":
            return .blocked
        default:
            return .idle
        }
    }

    /// Reports a surface's agent activity state via the socket. Best-effort: benign if the
    /// surface/workspace can't be resolved (e.g. TabManager already torn down).
    /// `sessionId`/`pid`, when present, let the app key this report to a session and
    /// register the pid for stale-session detection/port scanning.
    func reportAgentState(
        client: SocketClient,
        workspaceId: String,
        surfaceId: String,
        state: CLIAgentActivityState,
        provider: String? = nil,
        sessionId: String? = nil,
        pid: Int? = nil
    ) {
        var params: [String: Any] = [
            "workspace_id": workspaceId,
            "surface_id": surfaceId,
            "state": state.rawValue,
        ]
        if let provider { params["provider"] = provider }
        if let sessionId, !sessionId.isEmpty { params["session_id"] = sessionId }
        if let pid { params["pid"] = pid }
        _ = try? client.sendV2(method: V2MethodNames.surfaceReportAgentState, params: params)
    }

    /// Clears a surface's reported agent activity state (hook session-end / process exit).
    func clearAgentState(client: SocketClient, workspaceId: String, surfaceId: String) {
        _ = try? client.sendV2(method: V2MethodNames.surfaceClearAgentState, params: [
            "workspace_id": workspaceId,
            "surface_id": surfaceId,
        ])
    }

    private func resolvePreferredWorkspaceIdForClaudeHook(
        preferred: String?,
        fallback: String?,
        client: SocketClient
    ) throws -> String {
        if let preferred = nonEmptyClaudeHookIdentifier(preferred) {
            if isUUID(preferred) {
                return preferred
            }
            return try resolveWorkspaceIdForClaudeHook(preferred, client: client)
        }
        if let fallback = nonEmptyClaudeHookIdentifier(fallback), isUUID(fallback) {
            return fallback
        }
        return try resolveWorkspaceIdForClaudeHook(fallback, client: client)
    }

    private func resolvePreferredSurfaceIdForClaudeHook(
        preferred: String?,
        fallback: String?,
        workspaceId: String,
        client: SocketClient
    ) throws -> String {
        if let preferred = nonEmptyClaudeHookIdentifier(preferred) {
            if isUUID(preferred) {
                return preferred
            }
            return try resolveSurfaceIdForClaudeHook(preferred, workspaceId: workspaceId, client: client)
        }
        if let fallback = nonEmptyClaudeHookIdentifier(fallback), isUUID(fallback) {
            return fallback
        }
        return try resolveSurfaceIdForClaudeHook(fallback, workspaceId: workspaceId, client: client)
    }

    private func nonEmptyClaudeHookIdentifier(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    // NOTE: despite the "Teardown" name, this is also reused by session-start/active
    // and prompt-submit across all three agent hooks (claude/codex/opencode) to fail
    // open on the same transport-failure fragments — a Programa quit mid-session must
    // not block an agent's next hook invocation.
    private func shouldIgnoreClaudeHookTeardownError(_ error: Error) -> Bool {
        let message = String(describing: error).lowercased()
        let benignFragments = [
            "tabmanager not available",
            "no workspace selected",
            "workspace not found",
            "workspace ref not found",
            "workspace index not found",
            "surface not found",
            "surface ref not found",
            "surface index not found",
            "unable to resolve surface id",
            "panel not found",
            "tab not found",
            "failed to write to socket",
            "socket read error",
            "not connected"
        ]
        return benignFragments.contains { message.contains($0) }
    }

    private func describeAskUserQuestion(_ object: [String: Any]?) -> String? {
        guard let object,
              let input = object["tool_input"] as? [String: Any],
              let questions = input["questions"] as? [[String: Any]],
              let first = questions.first else { return nil }

        var parts: [String] = []

        if let question = first["question"] as? String, !question.isEmpty {
            parts.append(question)
        } else if let header = first["header"] as? String, !header.isEmpty {
            parts.append(header)
        }

        if let options = first["options"] as? [[String: Any]] {
            let labels = options.compactMap { $0["label"] as? String }
            if !labels.isEmpty {
                parts.append(labels.map { "[\($0)]" }.joined(separator: " "))
            }
        }

        if parts.isEmpty { return "Asking a question" }
        return parts.joined(separator: "\n")
    }

    private func describeToolUse(_ object: [String: Any]?) -> String? {
        guard let object, let toolName = object["tool_name"] as? String else { return nil }
        let input = object["tool_input"] as? [String: Any]

        switch toolName {
        case "Read":
            if let path = input?["file_path"] as? String {
                return "Reading \(shortenPath(path))"
            }
            return "Reading file"
        case "Edit":
            if let path = input?["file_path"] as? String {
                return "Editing \(shortenPath(path))"
            }
            return "Editing file"
        case "Write":
            if let path = input?["file_path"] as? String {
                return "Writing \(shortenPath(path))"
            }
            return "Writing file"
        case "Bash":
            if let cmd = input?["command"] as? String {
                let first = cmd.components(separatedBy: .whitespacesAndNewlines).first ?? cmd
                let short = String(first.prefix(30))
                return "Running \(short)"
            }
            return "Running command"
        case "Glob":
            if let pattern = input?["pattern"] as? String {
                return "Searching \(String(pattern.prefix(30)))"
            }
            return "Searching files"
        case "Grep":
            if let pattern = input?["pattern"] as? String {
                return "Grep \(String(pattern.prefix(30)))"
            }
            return "Searching code"
        case "Agent":
            if let desc = input?["description"] as? String {
                return String(desc.prefix(40))
            }
            return "Subagent"
        case "WebFetch":
            return "Fetching URL"
        case "WebSearch":
            if let query = input?["query"] as? String {
                return "Search: \(String(query.prefix(30)))"
            }
            return "Web search"
        default:
            return toolName
        }
    }

    private func shortenPath(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        return name.isEmpty ? String(path.suffix(30)) : name
    }

    private func resolveWorkspaceIdForClaudeHook(_ raw: String?, client: SocketClient) throws -> String {
        try resolveWorkspaceIdAllowingFallback(raw, client: client)
    }

    private func resolveSurfaceIdForClaudeHook(
        _ raw: String?,
        workspaceId: String,
        client: SocketClient
    ) throws -> String {
        try resolveSurfaceIdAllowingFallback(raw, workspaceId: workspaceId, client: client)
    }

    func resolveWorkspaceIdAllowingFallback(
        _ raw: String?,
        client: SocketClient
    ) throws -> String {
        if let raw,
           !raw.isEmpty,
           let candidate = try? resolveWorkspaceId(raw, client: client),
           (try? client.sendV2(method: V2MethodNames.surfaceList, params: ["workspace_id": candidate])) != nil {
            return candidate
        }
        if let callerWorkspaceId = resolveCallerWorkspaceIdByTTY(client: client),
           (try? client.sendV2(method: V2MethodNames.surfaceList, params: ["workspace_id": callerWorkspaceId])) != nil {
            return callerWorkspaceId
        }
        return try resolveWorkspaceId(nil, client: client)
    }

    func resolveSurfaceIdAllowingFallback(
        _ raw: String?,
        workspaceId: String,
        client: SocketClient
    ) throws -> String {
        if let raw,
           !raw.isEmpty,
           let candidate = try? resolveSurfaceId(raw, workspaceId: workspaceId, client: client),
           let listed = try? client.sendV2(method: V2MethodNames.surfaceList, params: ["workspace_id": workspaceId]) {
            let items = listed["surfaces"] as? [[String: Any]] ?? []
            if items.contains(where: {
                ($0["id"] as? String) == candidate || ($0["ref"] as? String) == candidate
            }) {
                return candidate
            }
        }
        if let callerSurfaceId = resolveCallerSurfaceIdByTTY(workspaceId: workspaceId, client: client),
           let listed = try? client.sendV2(method: V2MethodNames.surfaceList, params: ["workspace_id": workspaceId]) {
            let items = listed["surfaces"] as? [[String: Any]] ?? []
            if items.contains(where: {
                ($0["id"] as? String) == callerSurfaceId || ($0["ref"] as? String) == callerSurfaceId
            }) {
                return callerSurfaceId
            }
        }
        return try resolveSurfaceId(nil, workspaceId: workspaceId, client: client)
    }

    private struct CallerTerminalBinding {
        let workspaceId: String
        let surfaceId: String
    }

    private func resolveCallerWorkspaceIdByTTY(client: SocketClient) -> String? {
        resolveCallerTerminalBindingByTTY(client: client)?.workspaceId
    }

    private func resolveCallerSurfaceIdByTTY(workspaceId: String, client: SocketClient) -> String? {
        guard let binding = resolveCallerTerminalBindingByTTY(client: client),
              binding.workspaceId == workspaceId else {
            return nil
        }
        return binding.surfaceId
    }

    private func resolveCallerTerminalBindingByTTY(client: SocketClient) -> CallerTerminalBinding? {
        guard let ttyName = resolveCallerTTYName() else {
            return nil
        }
        guard let payload = try? client.sendV2(method: V2MethodNames.surfaceResolveTty, params: ["tty": ttyName]),
              let workspaceId = normalizedHandleValue(payload["workspace_id"] as? String),
              let surfaceId = normalizedHandleValue(payload["surface_id"] as? String) else {
            return nil
        }
        return CallerTerminalBinding(workspaceId: workspaceId, surfaceId: surfaceId)
    }

    private func resolveCallerTTYName() -> String? {
        let env = ProcessInfo.processInfo.environment
        for key in ["PROGRAMA_CLI_TTY_NAME", "PROGRAMA_TTY_NAME", "TTY", "SSH_TTY"] {
            if let ttyName = normalizedTTYName(env[key]) {
                return ttyName
            }
        }
        for fileDescriptor in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            if let rawTTYName = ttyname(fileDescriptor),
               let ttyName = normalizedTTYName(String(cString: rawTTYName)) {
                return ttyName
            }
        }
        return nil
    }

    private func normalizedTTYName(_ raw: String?) -> String? {
        guard let trimmed = normalizedHandleValue(raw == "not a tty" ? nil : raw) else {
            return nil
        }
        let components = trimmed.split(separator: "/")
        if let last = components.last, !last.isEmpty {
            return String(last)
        }
        return trimmed
    }

    private func normalizedHandleValue(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        return raw
    }

    func parseClaudeHookInput(rawInput: String) -> ClaudeHookParsedInput {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data, options: []),
              let object = json as? [String: Any] else {
            let fallback = trimmed.isEmpty ? nil : truncate(
                normalizedSingleLine(redactClaudeSensitiveSpans(trimmed)),
                maxLength: 180
            )
            return ClaudeHookParsedInput(object: nil, rawFallback: fallback, sessionId: nil, cwd: nil, transcriptPath: nil)
        }

        let sessionId = extractClaudeHookSessionId(from: object)
        let cwd = extractClaudeHookCWD(from: object)
        let transcriptPath = firstString(in: object, keys: ["transcript_path", "transcriptPath"])
        let compactObject = compactClaudeHookObject(object)
        return ClaudeHookParsedInput(
            object: compactObject,
            rawFallback: nil,
            sessionId: sessionId,
            cwd: cwd,
            transcriptPath: transcriptPath
        )
    }

    private func compactClaudeHookObject(_ object: [String: Any]) -> [String: Any] {
        var compact: [String: Any] = [:]

        for key in [
            "tool_name",
            "agent_id",
            "agent_type",
            "last_assistant_message",
            "lastAssistantMessage",
            "event",
            "event_name",
            "hook_event_name",
            "type",
            "kind",
            "notification_type",
            "matcher",
            "reason",
            "message",
            "body",
            "text",
            "prompt",
            "error",
            "description",
        ] {
            if let value = compactClaudeHookStringValue(
                object[key],
                maxLength: claudeHookCompactFieldLimit(for: key)
            ) {
                compact[key] = value
            }
        }

        if let toolInput = object["tool_input"] as? [String: Any] {
            var compactToolInput: [String: Any] = [:]
            for key in ["file_path", "command", "pattern", "description", "query"] {
                if let value = compactClaudeHookToolInputValue(toolInput[key], key: key) {
                    compactToolInput[key] = value
                }
            }
            if let questions = toolInput["questions"] as? [[String: Any]] {
                compactToolInput["questions"] = questions.prefix(1).map { question in
                    var compactQuestion: [String: Any] = [:]
                    if let value = compactClaudeHookStringValue(question["question"], maxLength: 180) {
                        compactQuestion["question"] = value
                    }
                    if let value = compactClaudeHookStringValue(question["header"], maxLength: 80) {
                        compactQuestion["header"] = value
                    }
                    if let options = question["options"] as? [[String: Any]] {
                        let compactOptions: [[String: Any]] = options.compactMap { option in
                            guard let label = compactClaudeHookStringValue(option["label"], maxLength: 60) else {
                                return nil
                            }
                            return ["label": label] as [String: Any]
                        }
                        compactQuestion["options"] = compactOptions
                    }
                    return compactQuestion
                }
            }
            if !compactToolInput.isEmpty {
                compact["tool_input"] = compactToolInput
            }
        }

        for key in ["notification", "data"] {
            guard let nested = object[key] as? [String: Any] else { continue }
            var compactNested: [String: Any] = [:]
            for nestedKey in ["type", "kind", "reason", "message", "body", "text", "prompt", "error", "description"] {
                if let value = compactClaudeHookStringValue(
                    nested[nestedKey],
                    maxLength: claudeHookCompactFieldLimit(for: nestedKey)
                ) {
                    compactNested[nestedKey] = value
                }
            }
            if !compactNested.isEmpty {
                compact[key] = compactNested
            }
        }

        return compact
    }

    private func claudeHookCompactFieldLimit(for key: String) -> Int {
        switch key {
        case "tool_name", "agent_id", "agent_type", "event", "event_name", "hook_event_name", "type", "kind", "notification_type", "matcher", "reason":
            return 80
        case "last_assistant_message", "lastAssistantMessage", "message", "body", "text", "prompt", "error", "description":
            return 240
        default:
            return 160
        }
    }

    private func compactClaudeHookToolInputValue(_ rawValue: Any?, key: String) -> String? {
        switch key {
        case "file_path":
            return compactClaudeHookStringValue(rawValue, maxLength: 240, keepSuffix: true)
        case "command":
            return compactClaudeHookStringValue(rawValue, maxLength: 120)
        case "pattern", "query":
            return compactClaudeHookStringValue(rawValue, maxLength: 120)
        case "description":
            return compactClaudeHookStringValue(rawValue, maxLength: 180)
        default:
            return compactClaudeHookStringValue(rawValue, maxLength: 160)
        }
    }

    private func compactClaudeHookStringValue(
        _ rawValue: Any?,
        maxLength: Int,
        keepSuffix: Bool = false
    ) -> String? {
        guard let rawString = rawValue as? String else { return nil }
        let previewLength = max(maxLength, min(maxLength * 4, 1024))
        let preview = keepSuffix
            ? String(rawString.suffix(previewLength))
            : String(rawString.prefix(previewLength))
        let normalized = normalizedSingleLine(preview)
        guard !normalized.isEmpty else { return nil }
        if keepSuffix, normalized.count > maxLength {
            return "…" + String(normalized.suffix(maxLength - 1))
        }
        return truncate(normalized, maxLength: maxLength)
    }

    private func extractClaudeHookSessionId(from object: [String: Any]) -> String? {
        if let id = firstString(in: object, keys: ["session_id", "sessionId"]) {
            return id
        }

        if let nested = object["notification"] as? [String: Any],
           let id = firstString(in: nested, keys: ["session_id", "sessionId"]) {
            return id
        }
        if let nested = object["data"] as? [String: Any],
           let id = firstString(in: nested, keys: ["session_id", "sessionId"]) {
            return id
        }
        if let session = object["session"] as? [String: Any],
           let id = firstString(in: session, keys: ["id", "session_id", "sessionId"]) {
            return id
        }
        if let context = object["context"] as? [String: Any],
           let id = firstString(in: context, keys: ["session_id", "sessionId"]) {
            return id
        }
        return nil
    }

    private func extractClaudeHookCWD(from object: [String: Any]) -> String? {
        let cwdKeys = ["cwd", "working_directory", "workingDirectory", "project_dir", "projectDir"]
        if let cwd = firstString(in: object, keys: cwdKeys) {
            return cwd
        }
        if let nested = object["notification"] as? [String: Any],
           let cwd = firstString(in: nested, keys: cwdKeys) {
            return cwd
        }
        if let nested = object["data"] as? [String: Any],
           let cwd = firstString(in: nested, keys: cwdKeys) {
            return cwd
        }
        if let context = object["context"] as? [String: Any],
           let cwd = firstString(in: context, keys: cwdKeys) {
            return cwd
        }
        return nil
    }

    private func summarizeClaudeHookStop(
        parsedInput: ClaudeHookParsedInput,
        sessionRecord: ClaudeHookSessionRecord?
    ) -> (subtitle: String, body: String)? {
        let cwd = parsedInput.cwd ?? sessionRecord?.cwd
        let transcriptPath = parsedInput.transcriptPath

        let projectName: String? = {
            guard let cwd = cwd, !cwd.isEmpty else { return nil }
            let path = NSString(string: cwd).expandingTildeInPath
            let tail = URL(fileURLWithPath: path).lastPathComponent
            return tail.isEmpty ? path : tail
        }()

        // Try reading the transcript JSONL for a richer summary.
        let transcript = transcriptPath.flatMap { readTranscriptSummary(path: $0) }

        if let lastMsg = transcript?.lastAssistantMessage {
            var subtitle = "Completed"
            if let projectName, !projectName.isEmpty {
                subtitle = "Completed in \(projectName)"
            }
            return (subtitle, truncate(lastMsg, maxLength: 200))
        }

        // Fallback: use session record data.
        let lastMessage = sessionRecord?.lastBody ?? sessionRecord?.lastSubtitle
        let hasContext = cwd != nil || lastMessage != nil
        guard hasContext else { return nil }

        var body = "Claude session completed"
        if let projectName, !projectName.isEmpty {
            body += " in \(projectName)"
        }
        if let lastMessage, !lastMessage.isEmpty {
            body += ". Last: \(lastMessage)"
        }
        return ("Completed", body)
    }

    private struct TranscriptSummary {
        let lastAssistantMessage: String?
    }

    private func readTranscriptSummary(path: String) -> TranscriptSummary? {
        let expandedPath = NSString(string: path).expandingTildeInPath
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: expandedPath)) else {
            return nil
        }
        guard let content = String(data: data, encoding: .utf8) else { return nil }

        let lines = content.components(separatedBy: "\n")

        var lastAssistantMessage: String?

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let lineData = trimmed.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let message = obj["message"] as? [String: Any],
                  let role = message["role"] as? String,
                  role == "assistant" else {
                continue
            }

            let text = extractMessageText(from: message)
            guard let text, !text.isEmpty else { continue }
            lastAssistantMessage = truncate(normalizedSingleLine(text), maxLength: 120)
        }

        guard lastAssistantMessage != nil else { return nil }
        return TranscriptSummary(lastAssistantMessage: lastAssistantMessage)
    }

    private func extractMessageText(from message: [String: Any]) -> String? {
        if let content = message["content"] as? String {
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let contentArray = message["content"] as? [[String: Any]] {
            let texts = contentArray.compactMap { block -> String? in
                guard (block["type"] as? String) == "text",
                      let text = block["text"] as? String else { return nil }
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let joined = texts.joined(separator: " ")
            return joined.isEmpty ? nil : joined
        }
        return nil
    }

    func summarizeAgentHookNotification(parsedInput: ClaudeHookParsedInput, agentName: String) -> (subtitle: String, body: String) {
        guard let object = parsedInput.object else {
            if let fallback = parsedInput.rawFallback, !fallback.isEmpty {
                return classifyAgentNotification(signal: fallback, message: fallback, agentName: agentName)
            }
            return ("Waiting", "\(agentName) is waiting for your input")
        }

        let nested = (object["notification"] as? [String: Any]) ?? (object["data"] as? [String: Any]) ?? [:]
        let signalParts = [
            firstString(in: object, keys: ["event", "event_name", "hook_event_name", "type", "kind"]),
            firstString(in: object, keys: ["notification_type", "matcher", "reason"]),
            firstString(in: nested, keys: ["type", "kind", "reason"])
        ]
        let messageCandidates = [
            firstString(in: object, keys: ["message", "body", "text", "prompt", "error", "description"]),
            firstString(in: nested, keys: ["message", "body", "text", "prompt", "error", "description"])
        ]
        let message = messageCandidates.compactMap { $0 }.first ?? "\(agentName) needs your input"
        let normalizedMessage = normalizedSingleLine(message)
        let signal = signalParts.compactMap { $0 }.joined(separator: " ")
        var classified = classifyAgentNotification(signal: signal, message: normalizedMessage, agentName: agentName)

        classified.body = truncate(classified.body, maxLength: 180)
        return classified
    }

    private func classifyAgentNotification(signal: String, message: String, agentName: String) -> (subtitle: String, body: String) {
        let lower = "\(signal) \(message)".lowercased()
        if lower.contains("permission") || lower.contains("approve") || lower.contains("approval") || lower.contains("permission_prompt") {
            let body = message.isEmpty ? "Approval needed" : message
            return ("Permission", body)
        }
        if lower.contains("error") || lower.contains("failed") || lower.contains("exception") {
            let body = message.isEmpty ? "\(agentName) reported an error" : message
            return ("Error", body)
        }
        if lower.contains("complet") || lower.contains("finish") || lower.contains("done") || lower.contains("success") {
            let body = message.isEmpty ? "Task completed" : message
            return ("Completed", body)
        }
        if lower.contains("idle") || lower.contains("wait") || lower.contains("input") || lower.contains("idle_prompt") {
            let body = message.isEmpty ? "Waiting for input" : message
            return ("Waiting", body)
        }
        // Use the message directly if it's meaningful (not a generic placeholder).
        if !message.isEmpty, message != "\(agentName) needs your input" {
            return ("Attention", message)
        }
        return ("Attention", "\(agentName) needs your attention")
    }

    private func firstString(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            guard let value = object[key] else { continue }
            if let string = value as? String {
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return nil
    }

    func claudeSubagentTaskIdentifier(scope: String, externalAgentId: String) -> String {
        var bytes = Array(SHA256.hash(data: Data("claude:\(scope):\(externalAgentId)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        )).uuidString
    }

    private func normalizedSingleLine(_ value: String) -> String {
        let collapsed = value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func truncate(_ value: String, maxLength: Int) -> String {
        guard value.count > maxLength else { return value }
        let index = value.index(value.startIndex, offsetBy: max(0, maxLength - 1))
        return String(value[..<index]) + "…"
    }

    private func sanitizeNotificationField(_ value: String) -> String {
        return normalizedSingleLine(value)
            .replacingOccurrences(of: "|", with: "¦")
    }

    private func redactClaudeSensitiveSpans(_ value: String) -> String {
        let patterns: [(pattern: String, replacement: String)] = [
            (#"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#, "<email>"),
            (#"(?:~|/)[^\s\"']+"#, "<path>"),
            (#"\b(?:sk|rk|sess|token|key|secret|api[_-]?key)[A-Za-z0-9._:-]{8,}\b"#, "<token>"),
            (#"\b[A-Za-z0-9_-]{24,}\b"#, "<token>")
        ]
        return patterns.reduce(value) { partial, entry in
            partial.replacingOccurrences(
                of: entry.pattern,
                with: entry.replacement,
                options: [.regularExpression, .caseInsensitive]
            )
        }
    }

    func mergedNodeOptions(existing: String?, restoreModulePath: String) -> String {
        let requireOption = "--require=\(restoreModulePath)"
        let memoryOption = "--max-old-space-size=4096"
        let cleanedExisting = cleanedNodeOptions(existing)
        guard !cleanedExisting.isEmpty else {
            return "\(requireOption) \(memoryOption)"
        }
        return "\(requireOption) \(memoryOption) \(cleanedExisting)"
    }

    private func cleanedNodeOptions(_ existing: String?) -> String {
        let tokens = (existing ?? "")
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !tokens.isEmpty else { return "" }

        var filtered: [String] = []
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if token == "--max-old-space-size" {
                index += min(2, tokens.count - index)
                continue
            }
            if token.hasPrefix("--max-old-space-size=") {
                index += 1
                continue
            }
            filtered.append(token)
            index += 1
        }
        return filtered.joined(separator: " ")
    }

    // MARK: - Agent skill (SKILL.md)

    /// The `programa` agent skill: teaches an agent running inside programa
    /// that it can drive the app (split panes, read sibling panes, spawn and
    /// coordinate a helper agent) via the socket-backed CLI instead of just
    /// the shell in its own pane. Installed alongside each integration's own
    /// hooks/plugin below. Source of truth is `SKILL.md` at the repo root —
    /// keep the two in sync by hand when either changes. Refs #165.
    static let agentSkillMarkdown: String = #"""
    ---
    name: programa
    description: Drive the programa terminal app from inside a programa surface. Use it without being asked whenever an agent runs inside programa (PROGRAMA_SURFACE_ID and PROGRAMA_SOCKET_PATH are set) and the task involves parallel or conflicting work (worktrees, helper agents), competing attempts (race), reviewing a diff, a long-running job, or reading another pane. Covers inspecting windows/workspaces/panes/surfaces, splitting panes and running commands without stealing the user's focus, reading sibling panes, spawning and waiting on helper agents, and layouts. Do not use, and do not call the programa CLI at all, when those two variables are unset — that means the agent is not running inside programa.
    ---

    <!-- Installed and managed by `programa claude install-integration` / `programa codex install-integration` / `programa opencode install-integration`. Manual edits to an installed copy get overwritten on the next install — edit the source at repo root (darkroomengineering/programa) instead. -->

    # programa

    programa is a native macOS terminal built for running many coding agents in parallel. Every terminal surface it creates is scriptable through a `programa` CLI that talks to a local Unix socket — split panes, read a sibling pane's output, send it keystrokes, and get notified, all without the terminal UI itself.

    ## Guard: confirm you're actually inside programa

    Check this before anything else in this skill:

    ```bash
    if [ -z "$PROGRAMA_SURFACE_ID" ] || [ -z "$PROGRAMA_SOCKET_PATH" ]; then
      echo "Not running inside programa (PROGRAMA_SURFACE_ID/PROGRAMA_SOCKET_PATH unset) — skipping programa CLI use."
    fi
    ```

    If either variable is unset, stop here. Don't guess a socket path, don't fall back to a default location, don't try anyway — just say you're not running inside programa and continue with normal shell commands.

    Both variables are exported automatically by programa on every terminal surface it creates (no shell integration or setup required), along with `PROGRAMA_WORKSPACE_ID`. Every command below defaults its `--workspace`/`--surface` flags to those env vars when you omit them, so most calls need no flags at all when you're operating on your own pane.

    The `programa` CLI is already on `PATH` inside a programa terminal. Verify with `command -v programa`. When the `programa` MCP server is connected, its tools (`agent_spawn`, `worktree_create`, `surface_read_text`, ...) do the same things as the CLI.

    ## When to use what

    Reach for these on your own; the user does not need to ask:

    | Situation | Do this |
    |---|---|
    | A helper or a second line of work would edit the same files you are editing | `programa worktree create <branch>`, or `agent_spawn` with `needs_isolation` |
    | A task worth trying several ways, or you are unsure which approach wins | `programa race "<prompt>" --n <count>`, then compare the branches yourself |
    | A diff is ready for review, yours or a helper's | `programa review open`, `review comment add`, `review send` |
    | A build, test run, dev server, or anything over a minute | run it in a split, then `wait-surface` on it |
    | A long or parallel job the user should be able to watch | `programa new-split` (MCP `surface_split`) or `agent_spawn`, then tell the user which pane it is in |
    | The work needs a coordinated team of agents | suggest the user restart with `programa claude-teams`; only the user launches it |
    | A blocking question for the user, from a tool without programa hooks (Claude Code, Codex and OpenCode hooks already send it) | MCP `agent_needs_input` with your `PROGRAMA_WORKSPACE_ID` and `PROGRAMA_SURFACE_ID`, the question as `body`, and `kind` `question` (without MCP: `programa rpc agent.needs_input '{"workspace_id":"…","surface_id":"…","body":"<question>","kind":"question"}'`). `surface_report_agent_state` with `blocked` only sets the badge |
    | Waiting on another agent | `wait-surface --agent-state idle` or `prompt-agent` |
    | The user asks for the same pane arrangement again | `programa layout save` / `layout apply` |
    | You need output from another pane | `read-screen --surface <ref>` |
    | Need another pane's output in your prompt | `programa handoff --from <pane>` |
    | Hand text to another agent's prompt without submitting it | MCP `surface_send_paste`: one paste, Return is never pressed. `send` and `surface_send_text` turn each newline into Return. The write is refused with `draft_in_progress` while the person has unsent input in that pane. Retry after they submit or clear it, or pass `force: true` (`--force` in the CLI) only when the user asked for it. While the agent there waits on a permission or sign-in prompt, every write is refused with `agent_awaiting_approval`: ask the user, and pass `answer_prompt: true` (`--answer-prompt`) only when they told you to answer it. |
    | An agent in a pane exited, or Programa restarted, and its work should continue | `programa resume --surface <ref>` types its resume command at that pane's shell prompt |
    | The user asks for a recap of a change | write `.programa/recaps/<slug>.md`, then `programa recap open <slug>` |

    None of these move the user's focus. Only the focus-changing commands listed below do, so leave those alone unless the user asked to be moved.

    ## Inspecting your surroundings

    Run `programa tree` first — it prints the whole hierarchy (windows → workspaces → panes → surfaces) with markers for where you and the user actually are:

    ```
    $ programa tree
    window window:1 [current] ◀ active
    └── workspace workspace:2 "api-server" [selected] ◀ active
        ├── pane pane:1 [focused] ◀ active
        │   └── surface surface:3 [terminal] "zsh" [selected] ◀ active ◀ here
        └── pane pane:4
            └── surface surface:5 [terminal] "npm run dev"
    ```

    - `◀ active` — the true focused window/workspace/pane/surface path (where the user's cursor is right now)
    - `◀ here` — the surface this `programa tree` call was invoked from (you)
    - `[selected]` / `[focused]` — that level's current UI selection (not necessarily "active" — the user may be in a different window)

    Useful flags and narrower listings:

    ```bash
    programa tree --all                       # every window, not just the current one
    programa tree --workspace workspace:2     # scope to one workspace
    programa --json tree                      # structured JSON (global --json flag goes before the subcommand)
    programa list-workspaces                  # workspaces in the current window
    programa list-panes                       # panes in the current workspace
    programa list-pane-surfaces               # surfaces (tabs) in the focused pane; add --pane <id> for another
    programa identify                         # your own window/workspace/surface IDs as JSON
    programa list-ports                       # listening TCP ports per workspace, plus processes left running
    ```

    ## Splitting panes and running commands without stealing focus

    programa's commands split cleanly into two groups:

    - **Focus-preserving** — safe to call at any time from any agent: `new-split`, `new-pane`, `new-surface`, `send`, `send-key`, `send-panel`, `send-key-panel`, `read-screen` (alias `capture-pane`). None of these move the user's cursor, raise the window, or change the active tab.
    - **Focus-changing** — only call these when you actually mean to move the user's attention: `focus-pane`, `focus-window`, `focus-panel`, `select-workspace`, `next-window`/`previous-window`/`last-window`.

    Create a split without touching focus, then send it a command:

    ```bash
    result=$(programa new-split right)            # prints: OK surface:6 workspace:2
    handle=$(echo "$result" | awk '{print $2}')   # surface:6
    programa send --surface "$handle" "npm run dev\n"
    ```

    `\n` (or `\r`) sends Enter, `\t` sends Tab, inside the text argument to `send`/`send-panel`. Use `send-key` when you need a literal key event instead of typed text (`ctrl+c`, `enter`, arrow keys):

    ```bash
    programa send-key --surface "$handle" ctrl+c
    ```

    `new-pane` / `new-surface` work the same way when you want a brand-new pane or an extra tab rather than splitting the current one:

    ```bash
    programa new-pane --direction down --workspace workspace:2
    programa new-surface --pane pane:4              # new tab in an existing pane
    ```

    A workspace holds at most 4 panes. A split or new pane past that fails with error code `limit_reached` (`data.max_panes` is 4) instead of creating anything. Fall back to `agent_spawn` (a helper gets its own nested workspace) or to a new workspace with `programa new-workspace`.

    ## Reading output from a sibling pane

    `read-screen` (alias `capture-pane`, for tmux muscle memory) returns terminal text as plain text — the visible viewport by default, or scrollback on request:

    ```bash
    programa read-screen --surface "$handle"                          # visible viewport
    programa read-screen --surface "$handle" --scrollback --lines 200 # last 200 lines of scrollback
    ```

    Treat a single read as a snapshot, not a completion signal — use `wait-surface` (below) to know when something finishes.

    `handoff` pastes a pane's last lines into a prompt as context, headed `Context from <pane>:`. It arrives as one paste and Return is never pressed, so the text waits as a draft:

    ```bash
    programa handoff --from "$handle"                                  # last 200 lines into your own pane
    programa handoff --from "$handle" --to surface:4 --lines 50 --note "Why does this fail?"
    ```

    `--lines` defaults to 200 (max 1000) and `--to` to `$PROGRAMA_SURFACE_ID`; `--from` must be a different pane than the target.

    ## Parallel or conflicting work: worktrees

    Two agents editing the same checkout overwrite each other. When a second line of work would touch the files you are touching, give it its own git worktree:

    ```bash
    programa worktree create fix-login --base main   # new branch + worktree, opened as its own workspace
    programa worktree list                           # worktrees of this repo, [open] marks open workspaces
    programa worktree remove fix-login               # removes the worktree (never the branch); add --force if it has uncommitted changes
    ```

    `create` checks out `<branch>` if it already exists, otherwise creates it from `--base` (default `HEAD`). The workspace opens next to its repo in the sidebar without taking focus; pass `--focus` only when the user should jump to it, and `--layout <name>` to apply a saved layout into it. Text output is `OK worktree workspace=<ref> path=<dir> branch=<branch>`; pass that workspace ref to `send --workspace`, `read-screen --workspace`, or `wait-surface --workspace`.

    `programa worktree create --from-issue <number>` reads the GitHub issue with `gh` and names the branch `issue-<number>-<title-slug>` (an explicit `<branch>` still wins); add `--agent <claude|opencode|codex>` to start that agent on the issue in the new workspace.

    Worktrees left behind after merging take disk space. `programa storage scan` lists every worktree in the repos open in programa and under `worktrees.directory`, with its size and either `removable` or why it is kept, plus Xcode, Android and package manager caches grouped by category with sizes, ids, automatic cleanup eligibility and blockers. `programa storage clean` removes the merged worktrees that are clean, hold no ignored env files, are not open in a workspace, have no process inside, and were not used for `worktrees.autoRemoveAfterHours` (default 24); it never passes `--force` and never deletes branches. Flags: `--dry-run` previews removal, `--include-external` includes worktrees outside `worktrees.directory`, `--now` skips the worktree idle wait, `--path <dir>` restricts worktrees to that directory or descendants (repeatable), and `--json` prints the raw result. Cache cleanup is opt-in: `--xcode`, `--android`, `--packages`, or `--caches` for all three. Repeatable `--item <id>` restricts chosen categories to those ids, or selects those ids across categories without category flags. Category and item flags include manual-only caches; running tools block cleanup, and safety is checked again before removal. Node modules, AVDs, available simulators, archives, Products and UserData are excluded. Every 6 hours Programa cleans eligible worktrees unless `worktrees.autoRemoveMerged` is `false`, and eligible unblocked automatic caches unless `storage.autoCleanCaches` is `false` (both default on). Automatic DerivedData, Gradle build/transforms and package cache cleanup requires 14 idle days; pnpm prune, unavailable simulators and CoreSimulator caches need no idle wait.

    ## Spawning a helper agent and coordinating with it

    When the `agent_spawn` tool is available, use it for helper agents. It opens the helper as a nested workspace under the current workspace, keeps the same folder, and does not move the user's focus. Set `needs_isolation` (with `repository_path` and `branch`) when the helper will make conflicting Git changes and needs a separate worktree. Programa then shows the helper's workspace nested under the current one in the sidebar.

    Use a split for a long-running shell command, or as a fallback when `agent_spawn` is unavailable. Launch the command with `send`, then treat it like any other sibling pane:

    ```bash
    result=$(programa new-split right)
    handle=$(echo "$result" | awk '{print $2}')
    programa send --surface "$handle" "claude 'fix the failing test in foo_test.go'\n"   # launch the helper
    programa read-screen --surface "$handle" --scrollback --lines 100                  # check on it later
    programa send --surface "$handle" --answer-prompt "y"                              # approve, only when the user told you to
    ```

    If the helper waits on a permission or sign-in prompt, `send` and `prompt-agent` are refused with `agent_awaiting_approval` and send nothing. Tell the user what the helper is asking and let them answer it in that pane. Pass `--answer-prompt` only when the user told you to approve it for them.

    Surface status through the sidebar and native notifications rather than only printing to your own pane:

    ```bash
    programa set-status build "compiling" --icon hammer --color "#ff9500"
    programa notify --title "Helper agent done" --body "Tests pass, ready for review" --surface "$handle"
    ```

    `set-status` writes a pill into the sidebar tab row — use a unique key per tool (`build`, `claude_code`, ...) so entries don't collide. `notify` fires a native notification and lights up programa's unread ring/tab indicator for that surface.

    ## Competing attempts: race

    When a task has several plausible approaches, race them instead of guessing:

    ```bash
    programa race "fix the flaky upload test" --n 3 --base main
    ```

    `race` creates one worktree and workspace per attempt on branches `<prefix>/<index>` (default prefix `race`, numbering continues after existing branches), then starts the agent in each with your prompt. Flags: `--n <count>` (1-8, default 3), `--agent <claude|opencode|codex>` (default claude), `--base <ref>`, `--prefix <slug>`, `--layout <name>`. It prints one `[<index>] branch=<branch> workspace=<ref>` line per attempt and never takes focus.

    `race` only spawns the attempts. Comparing and merging is up to you: wait for each attempt (`programa wait-surface --workspace <ref> --agent-state idle --timeout 1800`), compare the branches (`git diff main...race/1`), merge the one you pick with normal git, and clean up the rest with `programa worktree remove <branch>`.

    ## Waiting on a server, a test run, or another agent

    For anything that takes more than a minute, run it in a split and block on it instead of sleeping or polling. `wait-surface` waits server-side until a surface's output matches a regex, its process exits, or the agent in it reaches a state:

    ```bash
    programa wait-surface --surface "$handle" --pattern 'BUILD (SUCCEEDED|FAILED)' --timeout 120
    programa wait-surface --surface "$handle" --exit --timeout 600
    programa wait-surface --surface "$handle" --agent-state idle --timeout 300
    programa wait-surface --surface "$handle" --agent-state blocked --timeout 300
    ```

    Exactly one of `--pattern <regex>`, `--exit`, or `--agent-state <idle|working|blocked|any_change>` is required; `--timeout` defaults to 30 seconds. Match on whatever the process actually prints ("PASS", "Server started", a prompt returning), not a fixed sleep. The app answers the moment the condition is met, so output that appears while the call is being issued is not missed. `--workspace <ref>` without `--surface` targets that workspace's focused terminal.

    `--agent-state` watches the lifecycle state that Claude Code, Codex, and OpenCode report through their hooks. A surface that has never reported any state counts as idle for `--agent-state idle`; `blocked`/`working` require an actual report.

    For two cooperating processes, `wait-for` (tmux-compatible) gives you a named rendezvous instead of scraping a log:

    ```bash
    programa wait-for -S build-complete               # in the helper's pane, once it's done
    programa wait-for build-complete --timeout 120    # in the coordinating agent
    ```

    It signals that the other side finished, not whether it succeeded — pair it with a `read-screen` check.

    ## Prompting a helper agent and waiting for it, in one call

    ```bash
    programa prompt-agent --surface "$handle" --timeout 300 "fix the failing test in foo_test.go"
    ```

    It sends the text, waits briefly for the helper to report it started working, then waits for it to go idle again. If the helper never reports any activity, the JSON response carries a `warning` that its hooks may not be installed — check that field if `prompt-agent` returns suspiciously fast. A helper waiting on a permission prompt refuses it with `agent_awaiting_approval` (see above); a helper that is idle or asking a question does not.

    ## Reviewing a diff

    When a diff is ready, open it in the review panel instead of pasting it into chat. The panel opens beside the source terminal without taking focus, and comments go back into that terminal's agent as `path:line — comment`:

    ```bash
    programa review open                                         # uncommitted changes of the focused terminal in this workspace
    programa review open --workspace workspace:5 --mode branch --base-branch main   # a helper's or race attempt's whole branch
    programa review comment add src/upload.ts 42-48 "this retry never backs off"
    programa review comment list
    programa review send --preamble "Fix these before I merge:"
    ```

    `review open` reviews the terminal given by `--surface`, or the focused terminal of the target workspace. `--mode` is `uncommitted` (default) or `branch`; `--base-branch` defaults to `origin/main`. Pass the same `--workspace`/`--surface` to `comment` and `send` so they reach the same panel. `review refresh` reloads the diff after more edits. While the agent there waits on a permission or sign-in prompt, `review send` fails with `agent_awaiting_approval` and keeps the comments; tell the user, and send again after they answer it in that pane.

    Programa checkpoints the repo's files at the start of every agent turn (`refs/programa/checkpoints/...`); the user can revert a turn's file changes from the review panel, which does not rewind your conversation, so re-read files after a revert.

    ## Layouts

    ```bash
    programa layout save fullstack-dev                # current workspace's split geometry and cwds (not running commands)
    programa layout list
    programa layout apply fullstack-dev               # into a new unfocused workspace; --workspace <ref> to reuse one, --cwd <dir> for its root
    ```

    `layout save` refuses to overwrite an existing name without `--force`. `worktree create --layout <name>` and `race --layout <name>` apply a saved layout to each new workspace.

    ## Writing a recap

    When the user asks for a recap or summary of a change, write it as markdown to `.programa/recaps/<slug>.md` (repo root resolved with `git rev-parse --show-toplevel` from your cwd), then open it:

    ```bash
    programa recap open <slug>
    ```

    Use the same panel that renders `programa markdown open` for it, so lean on its formatting:

    - ` ```mermaid ` fenced blocks for flow diagrams (rendered offline, no network call)
    - GitHub-style alerts (`> [!NOTE]`, `> [!TIP]`, `> [!IMPORTANT]`, `> [!WARNING]`, `> [!CAUTION]`) for callouts
    - a `:::compare` block for before/after code, rendered side by side:

      ````
      :::compare
      ```swift before
      old code
      ```
      ```swift after
      new code
      ```
      :::
      ````

    `programa recap list` shows the slugs already saved. Keep the recap itself short and plain, the same way you'd summarize the change in chat.

    ## Browser work

    Do not reach for a Chrome extension. Programa has no built-in browser; browser work goes through Aside.

    - **Previews, smoke tests, screenshots, DOM checks, console errors, logged-in sites, private dashboards, CI logs:** use Aside through its MCP server if it is registered (tools from the `aside` server, or `aside-devtools` for raw Chrome DevTools control), or delegate a whole task from the shell:

      ```bash
      aside "Open the staging dashboard and tell me whether the last deploy is green"
      ```

      `programa aside status` says whether Aside is installed and registered; `programa aside install-mcp` registers it with Claude Code and Codex. Do not run the installer yourself unless the user asks, it edits their agent config.

    ## Reference

    - `--workspace`/`--surface`/`--pane`/`--window` accept either a short ref (`workspace:2`, `surface:4`) or a raw UUID; omitted, they default to `$PROGRAMA_WORKSPACE_ID`/`$PROGRAMA_SURFACE_ID`.
    - `--json` and `--id-format <refs|uuids|both>` are global flags and go before the subcommand: `programa --json tree`, `programa --id-format both list-panes`.
    - Full command list: `programa help`; one command's flags: `programa <command> --help`.
    - Anything not wrapped by a dedicated subcommand is reachable directly: `programa rpc <method> [json-params]` calls any socket API method.
    - `watch-events` streams a live feed of agent-state/output/workspace events over one long-lived connection — it's for dashboards and orchestrators watching many surfaces at once, not for a normal agent loop; use `wait-surface`/`prompt-agent` for "wait for one thing" instead.
    - Longer walkthrough and the full socket API reference: `docs/agent-skill.md` and `docs/socket-api.md` in the programa repo.
    """#

    /// Identifier used to detect programa-owned skill files during uninstall.
    private static let agentSkillMarker = "Installed and managed by `programa"

    /// Skill file path under a given skill-directory root (e.g. `~/.claude/skills`,
    /// `~/.agents/skills`, `$OPENCODE_CONFIG_DIR/skills`): `<root>/programa/SKILL.md`.
    static func agentSkillFilePath(skillsRoot: String) -> String {
        (skillsRoot as NSString).appendingPathComponent("programa/SKILL.md")
    }

    /// Reads the agent skill file at `path` and compares it against the
    /// current `agentSkillMarkdown`, without printing anything. Mirrors the
    /// `hooksChanged`/`configChanged` pure-boolean checks in
    /// `runCodexInstallHooks` so callers can fold this into a single
    /// "anything changed?" check across multiple files before printing any
    /// diffs or asking for confirmation.
    func agentSkillInstallState(path: String) -> (changed: Bool, existing: String?) {
        let fm = FileManager.default
        let existing: String? = fm.fileExists(atPath: path)
            ? (try? String(contentsOfFile: path, encoding: .utf8))
            : nil
        return (existing != Self.agentSkillMarkdown, existing)
    }

    /// Prints the agent skill file's diff, matching the format used for the
    /// caller's own primary-artifact diff (new-file listing vs. unified diff).
    func printAgentSkillDiff(path: String, existing: String?) {
        let new = Self.agentSkillMarkdown
        print("  \(path):")
        if let existing {
            printSimpleDiff(old: existing, new: new)
        } else {
            print("    (new file)")
            let lines = new.components(separatedBy: "\n")
            for (i, line) in lines.enumerated() where !(i == lines.count - 1 && line.isEmpty) {
                let lineLabel = String(format: "%3d", i + 1)
                print("    \u{001B}[32m\(lineLabel) +\(line)\u{001B}[0m")
            }
        }
        print("")
    }

    /// Writes the agent skill file to `path`, creating its parent directory.
    func writeAgentSkillFile(path: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true,
            attributes: nil
        )
        try Self.agentSkillMarkdown.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Checks whether the agent skill file at `path` exists and is
    /// programa-managed, without printing anything. Mirrors the OpenCode
    /// plugin uninstall's marker check: never remove a file that doesn't
    /// look like ours. Returns its content so the caller can print the
    /// removal diff itself before confirming.
    func agentSkillUninstallState(path: String) -> String? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path),
              let content = try? String(contentsOfFile: path, encoding: .utf8),
              content.contains(Self.agentSkillMarker) else {
            return nil
        }
        return content
    }

    func printAgentSkillRemovalDiff(path: String, content: String) {
        print("  \(path):")
        printSimpleDiff(old: content, new: "")
        print("")
    }

    func removeAgentSkillFileIfManaged(path: String) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path),
              let content = try? String(contentsOfFile: path, encoding: .utf8),
              content.contains(Self.agentSkillMarker) else {
            return
        }
        try fm.removeItem(atPath: path)
    }

    /// Print a unified-diff-style view with context lines and line numbers.
    func printSimpleDiff(old: String, new: String, contextLines: Int = 2) {
        let red = "\u{001B}[31m"
        let green = "\u{001B}[32m"
        let dim = "\u{001B}[2m"
        let reset = "\u{001B}[0m"

        let oldLines = old.components(separatedBy: "\n")
        let newLines = new.components(separatedBy: "\n")

        // Simple LCS-based diff: find matching lines
        let lcs = longestCommonSubsequence(oldLines, newLines)
        var oldIdx = 0, newIdx = 0, lcsIdx = 0

        struct DiffLine {
            enum Kind { case context, remove, add }
            let kind: Kind
            let lineNo: Int // 1-based, refers to old line for context/remove, new line for add
            let text: String
        }
        var allDiffs: [DiffLine] = []

        while oldIdx < oldLines.count || newIdx < newLines.count {
            if lcsIdx < lcs.count && oldIdx < oldLines.count && newIdx < newLines.count
                && oldLines[oldIdx] == lcs[lcsIdx] && newLines[newIdx] == lcs[lcsIdx] {
                allDiffs.append(DiffLine(kind: .context, lineNo: newIdx + 1, text: newLines[newIdx]))
                oldIdx += 1; newIdx += 1; lcsIdx += 1
            } else if oldIdx < oldLines.count && (lcsIdx >= lcs.count || oldLines[oldIdx] != lcs[lcsIdx]) {
                allDiffs.append(DiffLine(kind: .remove, lineNo: oldIdx + 1, text: oldLines[oldIdx]))
                oldIdx += 1
            } else if newIdx < newLines.count {
                allDiffs.append(DiffLine(kind: .add, lineNo: newIdx + 1, text: newLines[newIdx]))
                newIdx += 1
            }
        }

        // Find ranges with changes and expand by context
        var changedIndices = Set<Int>()
        for (i, d) in allDiffs.enumerated() where d.kind != .context {
            for j in max(0, i - contextLines)...min(allDiffs.count - 1, i + contextLines) {
                changedIndices.insert(j)
            }
        }

        var lastPrinted = -1
        for i in changedIndices.sorted() {
            if lastPrinted >= 0 && i > lastPrinted + 1 {
                print("    \(dim)...\(reset)")
            }
            let d = allDiffs[i]
            let lineLabel = String(format: "%3d", d.lineNo)
            switch d.kind {
            case .context:
                print("    \(dim)\(lineLabel)  \(d.text)\(reset)")
            case .remove:
                print("    \(red)\(lineLabel) -\(d.text)\(reset)")
            case .add:
                print("    \(green)\(lineLabel) +\(d.text)\(reset)")
            }
            lastPrinted = i
        }
    }

    private func longestCommonSubsequence(_ a: [String], _ b: [String]) -> [String] {
        let m = a.count, n = b.count
        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        for i in 1...m {
            for j in 1...n {
                if a[i - 1] == b[j - 1] {
                    dp[i][j] = dp[i - 1][j - 1] + 1
                } else {
                    dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
                }
            }
        }
        var result: [String] = []
        var i = m, j = n
        while i > 0 && j > 0 {
            if a[i - 1] == b[j - 1] {
                result.append(a[i - 1])
                i -= 1; j -= 1
            } else if dp[i - 1][j] > dp[i][j - 1] {
                i -= 1
            } else {
                j -= 1
            }
        }
        return result.reversed()
    }

    private func inferredCodexAgentPID() -> Int? {
        var candidate = getppid()
        var remainingWrapperSkips = 8

        while candidate > 1, remainingWrapperSkips > 0 {
            guard let processName = processName(for: candidate) else { break }
            if !codexHookWrapperProcessNames.contains(processName) {
                break
            }
            let next = parentPID(of: candidate)
            guard next > 1, next != candidate else { break }
            candidate = next
            remainingWrapperSkips -= 1
        }

        return candidate > 1 ? Int(candidate) : nil
    }

    private func parentPID(of pid: pid_t) -> pid_t {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else {
            return -1
        }
        return info.kp_eproc.e_ppid
    }

    private func processName(for pid: pid_t) -> String? {
        let process = Process()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(pid), "-o", "comm="]
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !output.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: output).lastPathComponent.lowercased()
    }

    // MARK: - OpenCode hooks

    /// Parses stdin JSON; the OpenCode plugin passes `--cwd`/`--session` as flags, which win.
    private func parseAgentHookInput(rawInput: String, hookArgs: [String]) -> ClaudeHookParsedInput {
        let base = parseClaudeHookInput(rawInput: rawInput)
        let cwdArg = optionValue(hookArgs, name: "--cwd")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionArg = optionValue(hookArgs, name: "--session")?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ClaudeHookParsedInput(
            object: base.object,
            rawFallback: base.rawFallback,
            sessionId: (sessionArg?.isEmpty == false ? sessionArg : nil) ?? base.sessionId,
            cwd: (cwdArg?.isEmpty == false ? cwdArg : nil) ?? base.cwd,
            transcriptPath: base.transcriptPath
        )
    }

    /// The local OpenCode plugin programa installs into
    /// ~/.config/opencode/plugins/programa.js (or $OPENCODE_CONFIG_DIR/plugins/programa.js).
    ///
    /// OpenCode has no shell-hook config (unlike Claude Code/Codex): local plugin
    /// files under plugins/ auto-load with no opencode.json edit and no npm install.
    /// One default export serves both plugin APIs: OpenCode v2 calls `setup(ctx)`, v1
    /// (1.3.4 and newer) calls `server(input)`. v1 implementations do not run on v2:
    /// https://github.com/anomalyco/opencode/blob/v2.2.7/services/site/src/docs/content/build/plugins/migrate-v1.mdx
    /// v2 gives plugins no Bun `$`, so both paths spawn the CLI through
    /// `node:child_process`, and `runHook` swallows every failure: a programa CLI
    /// hiccup must never crash the user's opencode session.
    private static let openCodePluginJS: String = {
        """
        // Programa integration for OpenCode. Managed by `programa opencode install-integration`.
        // One file for both plugin APIs: OpenCode v2 calls setup(ctx), v1 (1.3.4 and newer) calls server(input).
        import { spawn } from "node:child_process"

        const runHook = (args) =>
          new Promise((resolve) => {
            let child
            try {
              child = spawn("programa", ["opencode-hook", ...args], { stdio: "ignore" })
            } catch {
              return resolve()
            }
            const timer = setTimeout(() => child.kill(), 10000)
            const done = () => {
              clearTimeout(timer)
              resolve()
            }
            child.once("error", done)
            child.once("close", done)
          })

        // Subagent sessions (parentID set) never report a turn, so they cannot mark the parent idle or
        // become the id `programa resume` reopens. Calls run one at a time, in event order.
        const createIntegration = (directory, lookupParentID) => {
          const parents = new Map()
          let lastRootID
          let queue = Promise.resolve()
          const enqueue = (task) => (queue = queue.then(task).catch(() => {}))
          const call = (event, sessionID) =>
            runHook(sessionID ? [event, "--cwd", directory, "--session", sessionID] : [event, "--cwd", directory])
          const parentOf = (sessionID) => {
            if (!parents.has(sessionID)) {
              parents.set(
                sessionID,
                Promise.resolve()
                  .then(() => lookupParentID(sessionID))
                  .then((parentID) => parentID || undefined, () => undefined),
              )
            }
            return parents.get(sessionID)
          }
          const rootOf = async (sessionID) => {
            let id = sessionID
            for (let depth = 0; depth < 16; depth++) {
              const parentID = await parentOf(id)
              if (!parentID) break
              id = parentID
            }
            return id
          }
          return {
            created(sessionID, parentID) {
              if (sessionID) parents.set(sessionID, Promise.resolve(parentID || undefined))
            },
            start: () => enqueue(() => call("session-start")),
            turn: (event, sessionID) =>
              enqueue(async () => {
                if (!sessionID || (await parentOf(sessionID))) return
                lastRootID = sessionID
                await call(event, sessionID)
              }),
            // A subagent's permission prompt still blocks the user, so it is reported on its root session.
            attention: (sessionID) =>
              enqueue(async () => {
                const rootID = sessionID ? await rootOf(sessionID) : undefined
                if (rootID) lastRootID = rootID
                await call("notification", rootID)
              }),
            end: () => enqueue(() => call("session-end", lastRootID)),
          }
        }

        export default {
          id: "programa",
          setup(ctx) {
            // By default v2 runs plugins in one background service shared by every terminal, started with
            // the environment of whichever terminal launched it, so its PROGRAMA_* variables name the wrong
            // pane. Only a private server (`opencode --standalone`), which the TUI spawns with `serve --stdio`
            // and its own environment, can report for the pane it runs in.
            if (!process.argv.includes("--stdio")) return
            const directory = ctx.location.directory
            const programa = createIntegration(directory, async (sessionID) => {
              const result = await ctx.session.get({ sessionID })
              return (result?.data ?? result)?.parentID
            })
            const controller = new AbortController()
            programa.start()
            const types = [
              "session.created",
              "session.execution.started",
              "session.execution.succeeded",
              "session.execution.failed",
              "session.execution.interrupted",
              "permission.asked",
            ]
            void (async () => {
              try {
                for await (const event of ctx.event.subscribe({ types, signal: controller.signal })) {
                  if (event.location?.directory && event.location.directory !== directory) continue
                  const data = event.data ?? {}
                  if (event.type === "session.created") programa.created(data.sessionID, data.parentID)
                  else if (event.type === "session.execution.started") programa.turn("prompt-submit", data.sessionID)
                  else if (event.type === "permission.asked") programa.attention(data.sessionID)
                  else programa.turn("stop", data.sessionID)
                }
              } catch {}
            })()
            return async () => {
              controller.abort()
              await programa.end()
            }
          },
          async server({ directory, client }) {
            const programa = createIntegration(directory, async (id) => (await client.session.get({ path: { id } }))?.data?.parentID)
            programa.start()
            return {
              "chat.message": async (input) => {
                programa.turn("prompt-submit", input?.sessionID)
              },
              event: async ({ event }) => {
                const properties = event?.properties ?? {}
                if (event?.type === "session.created") programa.created(properties.info?.id ?? properties.sessionID, properties.info?.parentID)
                if (event?.type === "session.idle") programa.turn("stop", properties.sessionID)
                if (event?.type === "permission.asked") programa.attention(properties.sessionID)
              },
              dispose: async () => {
                await programa.end()
              },
            }
          },
        }
        """ + "\n"
    }()

    /// Identifier used to detect programa-owned plugin files during uninstall.
    private static let openCodePluginMarker = "Managed by `programa opencode install-integration`"

    /// OpenCode's global config directory, respecting its own OPENCODE_CONFIG_DIR override.
    static func openCodeConfigDir() -> String {
        if let override = ProcessInfo.processInfo.environment["OPENCODE_CONFIG_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return integrationExpandTilde(override)
        }
        return integrationExpandTilde("~/.config/opencode")
    }

    private static func openCodePluginsDir() -> String {
        (openCodeConfigDir() as NSString).appendingPathComponent("plugins")
    }

    /// OpenCode also discovers skills globally from `~/.claude/skills` and
    /// `~/.agents/skills` (installed by the Claude/Codex integrations above),
    /// so this mainly matters when a user runs only `programa opencode
    /// install-integration` and/or sets OPENCODE_CONFIG_DIR.
    private static func openCodeSkillsDir() -> String {
        (openCodeConfigDir() as NSString).appendingPathComponent("skills")
    }

    func runOpenCodeInstallIntegration() throws {
        let pluginsDir = Self.openCodePluginsDir()
        let pluginPath = (pluginsDir as NSString).appendingPathComponent("programa.js")
        let fm = FileManager.default

        try fm.createDirectory(atPath: pluginsDir, withIntermediateDirectories: true, attributes: nil)

        let existingContent: String? = fm.fileExists(atPath: pluginPath)
            ? (try? String(contentsOfFile: pluginPath, encoding: .utf8))
            : nil
        let newContent = Self.openCodePluginJS
        let pluginChanged = existingContent != newContent

        let skillPath = Self.agentSkillFilePath(skillsRoot: Self.openCodeSkillsDir())
        let skillState = agentSkillInstallState(path: skillPath)
        let mcpPlan = openCodeMCPRegistrationPlan(install: true)

        if !pluginChanged && !skillState.changed && mcpPlan.newConfig == nil {
            if let note = mcpPlan.note { print(note) }
            print("programa OpenCode integration is already installed. Nothing to change.")
            return
        }

        if pluginChanged {
            print("  \(pluginPath):")
            if let existingContent {
                printSimpleDiff(old: existingContent, new: newContent)
            } else {
                print("    (new file)")
                let lines = newContent.components(separatedBy: "\n")
                for (i, line) in lines.enumerated() where !(i == lines.count - 1 && line.isEmpty) {
                    let lineLabel = String(format: "%3d", i + 1)
                    print("    \u{001B}[32m\(lineLabel) +\(line)\u{001B}[0m")
                }
            }
            print("")
        }
        if skillState.changed {
            printAgentSkillDiff(path: skillPath, existing: skillState.existing)
        }
        printOpenCodeMCPPreview(mcpPlan)

        try confirmIntegrationChanges()

        if pluginChanged {
            try newContent.write(toFile: pluginPath, atomically: true, encoding: .utf8)
        }
        if skillState.changed {
            try writeAgentSkillFile(path: skillPath)
        }
        try applyOpenCodeMCPPlan(mcpPlan)

        print("")
        print("Installed. OpenCode picks up local plugins automatically, with no npm install needed.")
        print("To remove: programa opencode uninstall-integration")
    }

    func runOpenCodeUninstallIntegration() throws {
        let pluginsDir = Self.openCodePluginsDir()
        let pluginPath = (pluginsDir as NSString).appendingPathComponent("programa.js")
        let fm = FileManager.default

        let existingPluginContent: String? = fm.fileExists(atPath: pluginPath)
            ? (try? String(contentsOfFile: pluginPath, encoding: .utf8))
            : nil
        if let existingPluginContent, !existingPluginContent.contains(Self.openCodePluginMarker) {
            throw CLIError(
                message: "\(pluginPath) does not look like a programa-managed plugin (missing the marker comment). Refusing to delete it — remove it manually if this is intentional."
            )
        }

        let skillPath = Self.agentSkillFilePath(skillsRoot: Self.openCodeSkillsDir())
        let skillContent = agentSkillUninstallState(path: skillPath)
        let mcpPlan = openCodeMCPRegistrationPlan(install: false)

        if existingPluginContent == nil && skillContent == nil && mcpPlan.newConfig == nil {
            if let note = mcpPlan.note { print(note) }
            print("No OpenCode integration found at \(pluginPath)")
            return
        }

        if let existingPluginContent {
            print("  \(pluginPath):")
            printSimpleDiff(old: existingPluginContent, new: "")
            print("")
        }
        if let skillContent {
            printAgentSkillRemovalDiff(path: skillPath, content: skillContent)
        }
        printOpenCodeMCPPreview(mcpPlan)

        try confirmIntegrationChanges()

        if existingPluginContent != nil {
            try fm.removeItem(atPath: pluginPath)
        }
        if skillContent != nil {
            try removeAgentSkillFileIfManaged(path: skillPath)
        }
        try applyOpenCodeMCPPlan(mcpPlan)
        print("Removed programa OpenCode integration.")
    }

}
