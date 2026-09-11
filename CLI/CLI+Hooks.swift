import Foundation
import CryptoKit
import Darwin
import TOML
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
#if canImport(Security)
import Security
#endif

struct ClaudeHookParsedInput {
    let object: [String: Any]?
    let rawFallback: String?
    let sessionId: String?
    let cwd: String?
    let transcriptPath: String?
}

struct ClaudeHookSessionRecord: Codable {
    var sessionId: String
    var workspaceId: String
    var surfaceId: String
    var cwd: String?
    var pid: Int?
    var lastSubtitle: String?
    var lastBody: String?
    var startedAt: TimeInterval
    var updatedAt: TimeInterval
}

private struct ClaudeHookSessionStoreFile: Codable {
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

    func lookup(sessionId: String) throws -> ClaudeHookSessionRecord? {
        let normalized = normalizeSessionId(sessionId)
        guard !normalized.isEmpty else { return nil }
        return try withLockedState { state in
            state.sessions[normalized]
        }
    }

    func upsert(
        sessionId: String,
        workspaceId: String,
        surfaceId: String,
        cwd: String?,
        pid: Int? = nil,
        lastSubtitle: String? = nil,
        lastBody: String? = nil
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
            record.updatedAt = now
            state.sessions[normalized] = record
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
            if let normalizedSessionId,
               let removed = state.sessions.removeValue(forKey: normalizedSessionId) {
                return removed
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

        var state = loadUnlocked()
        pruneExpired(&state)
        let result = try body(&state)
        try saveUnlocked(state)
        return result
    }

    private func loadUnlocked() -> ClaudeHookSessionStoreFile {
        guard fileManager.fileExists(atPath: statePath) else {
            return ClaudeHookSessionStoreFile()
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: statePath)),
              let decoded = try? decoder.decode(ClaudeHookSessionStoreFile.self, from: data) else {
            return ClaudeHookSessionStoreFile()
        }
        return decoded
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

extension ProgramaCLI {
    func runClaudeHook(
        commandArgs: [String],
        client: SocketClient
    ) throws {
        let subcommand = commandArgs.first?.lowercased() ?? "help"
        let hookArgs = Array(commandArgs.dropFirst())
        let hookWsFlag = optionValue(hookArgs, name: "--workspace")
        let workspaceArg = hookWsFlag ?? ProcessInfo.processInfo.environment["PROGRAMA_WORKSPACE_ID"]
        let surfaceArg = optionValue(hookArgs, name: "--surface") ?? (hookWsFlag == nil ? ProcessInfo.processInfo.environment["PROGRAMA_SURFACE_ID"] : nil)
        let rawInput = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let parsedInput = parseClaudeHookInput(rawInput: rawInput)
        let sessionStore = ClaudeHookSessionStore()

        switch subcommand {
        case "session-start", "active":
            // Wrapped in do/catch like "stop"/"idle": a Programa quit mid-session
            // must not block the agent's next hook invocation on a dead socket.
            do {
                let workspaceId = try resolvePreferredWorkspaceIdForClaudeHook(
                    preferred: nil,
                    fallback: workspaceArg,
                    client: client
                )
                let surfaceId = try resolvePreferredSurfaceIdForClaudeHook(
                    preferred: nil,
                    fallback: surfaceArg,
                    workspaceId: workspaceId,
                    client: client
                )
                let claudePid: Int? = {
                    guard let raw = ProcessInfo.processInfo.environment["PROGRAMA_CLAUDE_PID"]?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                        let pid = Int(raw),
                        pid > 0 else {
                        return nil
                    }
                    return pid
                }()
                if let sessionId = parsedInput.sessionId {
                    try? sessionStore.upsert(
                        sessionId: sessionId,
                        workspaceId: workspaceId,
                        surfaceId: surfaceId,
                        cwd: parsedInput.cwd,
                        pid: claudePid
                    )
                }
                // Register PID for stale-session detection and OSC suppression,
                // but don't set a visible status. "Running" only appears when the
                // user submits a prompt (UserPromptSubmit) or Claude starts working
                // (PreToolUse).
                if let claudePid {
                    _ = try? client.sendV2(method: "workspace.set_agent_pid", params: [
                        "workspace_id": workspaceId,
                        "key": "claude_code",
                        "pid": claudePid,
                    ])
                }
                print("OK")
            } catch {
                if shouldIgnoreClaudeHookTeardownError(error) {
                    print("OK")
                    return
                }
                throw error
            }

        case "stop", "idle":
            do {
                // Turn ended. Don't consume session or clear PID — Claude is still alive.
                // Notification hook handles user-facing notifications; SessionEnd handles cleanup.
                let mappedSession = parsedInput.sessionId.flatMap { try? sessionStore.lookup(sessionId: $0) }
                let workspaceId = try resolvePreferredWorkspaceIdForClaudeHook(
                    preferred: mappedSession?.workspaceId,
                    fallback: workspaceArg,
                    client: client
                )
                let surfaceId = try resolvePreferredSurfaceIdForClaudeHook(
                    preferred: mappedSession?.surfaceId,
                    fallback: surfaceArg,
                    workspaceId: workspaceId,
                    client: client
                )

                // Update session with transcript summary and send completion notification.
                let completion = summarizeClaudeHookStop(
                    parsedInput: parsedInput,
                    sessionRecord: mappedSession
                )
                if let sessionId = parsedInput.sessionId, let completion {
                    try? sessionStore.upsert(
                        sessionId: sessionId,
                        workspaceId: workspaceId,
                        surfaceId: surfaceId,
                        cwd: parsedInput.cwd,
                        lastSubtitle: completion.subtitle,
                        lastBody: completion.body
                    )
                }

                if let completion {
                    _ = try? client.sendV2(method: "notification.create_for_target", params: [
                        "workspace_id": workspaceId,
                        "surface_id": surfaceId,
                        "title": "Claude Code",
                        "subtitle": sanitizeNotificationField(completion.subtitle),
                        "body": sanitizeNotificationField(completion.body),
                    ])
                }

                try? setClaudeStatus(
                    client: client,
                    workspaceId: workspaceId,
                    value: "Idle",
                    icon: "pause.circle.fill",
                    color: "#8E8E93"
                )
                reportAgentState(client: client, workspaceId: workspaceId, surfaceId: surfaceId, state: .idle)
                print("OK")
            } catch {
                if shouldIgnoreClaudeHookTeardownError(error) {
                    print("OK")
                    return
                }
                throw error
            }

        case "prompt-submit":
            // Wrapped in do/catch like "stop"/"idle": a Programa quit mid-session
            // must not block the agent's next prompt on a dead socket.
            do {
                let mappedSession = parsedInput.sessionId.flatMap { try? sessionStore.lookup(sessionId: $0) }
                let workspaceId = try resolvePreferredWorkspaceIdForClaudeHook(
                    preferred: mappedSession?.workspaceId,
                    fallback: workspaceArg,
                    client: client
                )
                let surfaceId = try resolvePreferredSurfaceIdForClaudeHook(
                    preferred: mappedSession?.surfaceId,
                    fallback: surfaceArg,
                    workspaceId: workspaceId,
                    client: client
                )
                _ = try client.sendV2(method: "notification.clear", params: ["workspace_id": workspaceId])
                try setClaudeStatus(
                    client: client,
                    workspaceId: workspaceId,
                    value: "Running",
                    icon: "bolt.fill",
                    color: "#4C8DFF"
                )
                reportAgentState(client: client, workspaceId: workspaceId, surfaceId: surfaceId, state: .working)
                print("OK")
            } catch {
                if shouldIgnoreClaudeHookTeardownError(error) {
                    print("OK")
                    return
                }
                throw error
            }

        case "notification", "notify":
            var summary = summarizeClaudeHookNotification(parsedInput: parsedInput)

            let mappedSession = parsedInput.sessionId.flatMap { try? sessionStore.lookup(sessionId: $0) }
            let workspaceId = try resolvePreferredWorkspaceIdForClaudeHook(
                preferred: mappedSession?.workspaceId,
                fallback: workspaceArg,
                client: client
            )
            if let mappedSession,
               let savedBody = mappedSession.lastBody, !savedBody.isEmpty,
               summary.body.contains("needs your attention") || summary.body.contains("needs your input") {
                summary = (subtitle: mappedSession.lastSubtitle ?? summary.subtitle, body: savedBody)
            }

            let surfaceId = try resolvePreferredSurfaceIdForClaudeHook(
                preferred: mappedSession?.surfaceId,
                fallback: surfaceArg,
                workspaceId: workspaceId,
                client: client
            )

            let title = "Claude Code"
            let subtitle = sanitizeNotificationField(summary.subtitle)
            let body = sanitizeNotificationField(summary.body)

            if let sessionId = parsedInput.sessionId {
                try? sessionStore.upsert(
                    sessionId: sessionId,
                    workspaceId: workspaceId,
                    surfaceId: surfaceId,
                    cwd: parsedInput.cwd,
                    lastSubtitle: summary.subtitle,
                    lastBody: summary.body
                )
            }

            _ = try? client.sendV2(method: "notification.create_for_target", params: [
                "workspace_id": workspaceId,
                "surface_id": surfaceId,
                "title": title,
                "subtitle": subtitle,
                "body": body,
            ])
            _ = try? setClaudeStatus(
                client: client,
                workspaceId: workspaceId,
                value: "Needs input",
                icon: "bell.fill",
                color: "#4C8DFF"
            )
            reportAgentState(
                client: client,
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                state: agentStateForClassifiedNotificationSubtitle(summary.subtitle)
            )
            print("OK")

        case "subagent-start":
            let mappedSession = parsedInput.sessionId.flatMap { try? sessionStore.lookup(sessionId: $0) }
            guard let externalAgentId = firstString(in: parsedInput.object ?? [:], keys: ["agent_id"]),
                  let workspaceId = try? resolvePreferredWorkspaceIdForClaudeHook(
                    preferred: mappedSession?.workspaceId,
                    fallback: workspaceArg,
                    client: client
                  ) else {
                print("OK")
                return
            }
            let surfaceId = try? resolvePreferredSurfaceIdForClaudeHook(
                preferred: mappedSession?.surfaceId,
                fallback: surfaceArg,
                workspaceId: workspaceId,
                client: client
            )
            let taskId = claudeSubagentTaskIdentifier(
                scope: parsedInput.sessionId ?? workspaceId,
                externalAgentId: externalAgentId
            )
            let agentType = firstString(in: parsedInput.object ?? [:], keys: ["agent_type"])
            var startParams: [String: Any] = [
                "agent_id": taskId,
                "workspace_id": workspaceId,
                "host": "claude",
                "placement": "runs_with_parent",
                "state": "working",
            ]
            if let surfaceId { startParams["surface_id"] = surfaceId }
            if let sessionId = parsedInput.sessionId { startParams["session"] = sessionId }
            if let agentType {
                startParams["role"] = agentType
                startParams["task"] = agentType
            }
            do {
                _ = try client.sendV2(method: "agent.task.start", params: startParams)
            } catch {
                var updateParams: [String: Any] = ["agent_id": taskId, "state": "working"]
                if let sessionId = parsedInput.sessionId { updateParams["session"] = sessionId }
                if let agentType {
                    updateParams["role"] = agentType
                    updateParams["task"] = agentType
                }
                _ = try? client.sendV2(method: "agent.task.update", params: updateParams)
            }
            print("OK")

        case "subagent-stop":
            let mappedSession = parsedInput.sessionId.flatMap { try? sessionStore.lookup(sessionId: $0) }
            guard let externalAgentId = firstString(in: parsedInput.object ?? [:], keys: ["agent_id"]),
                  let workspaceId = try? resolvePreferredWorkspaceIdForClaudeHook(
                    preferred: mappedSession?.workspaceId,
                    fallback: workspaceArg,
                    client: client
                  ) else {
                print("OK")
                return
            }
            let taskId = claudeSubagentTaskIdentifier(
                scope: parsedInput.sessionId ?? workspaceId,
                externalAgentId: externalAgentId
            )
            if (try? client.sendV2(method: "agent.task.finish", params: [
                "agent_id": taskId,
                "state": "completed",
            ])) == nil {
                let surfaceId = try? resolvePreferredSurfaceIdForClaudeHook(
                    preferred: mappedSession?.surfaceId,
                    fallback: surfaceArg,
                    workspaceId: workspaceId,
                    client: client
                )
                let agentType = firstString(in: parsedInput.object ?? [:], keys: ["agent_type"])
                var completedParams: [String: Any] = [
                    "agent_id": taskId,
                    "workspace_id": workspaceId,
                    "host": "claude",
                    "placement": "runs_with_parent",
                    "state": "completed",
                ]
                if let surfaceId { completedParams["surface_id"] = surfaceId }
                if let sessionId = parsedInput.sessionId { completedParams["session"] = sessionId }
                if let agentType {
                    completedParams["role"] = agentType
                    completedParams["task"] = agentType
                }
                _ = try? client.sendV2(method: "agent.task.start", params: completedParams)
            }
            print("OK")

        case "session-end":
            // Final cleanup when Claude process exits.
            // Only clear when we are the primary cleanup path (Stop didn't fire first).
            // If Stop already consumed the session, consumedSession is nil and we skip
            // to avoid wiping the completion notification that Stop just delivered.
            if let sessionId = parsedInput.sessionId {
                _ = try? client.sendV2(method: "agent.task.finish_session", params: [
                    "host": "claude",
                    "session": sessionId,
                    "state": "cancelled",
                ])
            }
            let mappedSession = parsedInput.sessionId.flatMap { try? sessionStore.lookup(sessionId: $0) }
            let fallbackWorkspaceId = try? resolvePreferredWorkspaceIdForClaudeHook(
                preferred: mappedSession?.workspaceId,
                fallback: workspaceArg,
                client: client
            )
            let fallbackSurfaceId: String? = {
                guard let fallbackWorkspaceId else { return nil }
                return try? resolvePreferredSurfaceIdForClaudeHook(
                    preferred: mappedSession?.surfaceId,
                    fallback: surfaceArg,
                    workspaceId: fallbackWorkspaceId,
                    client: client
                )
            }()
            let consumedSession = try? sessionStore.consume(
                sessionId: parsedInput.sessionId,
                workspaceId: fallbackWorkspaceId,
                surfaceId: fallbackSurfaceId
            )
            if let consumedSession {
                let workspaceId = consumedSession.workspaceId
                _ = try? clearClaudeStatus(client: client, workspaceId: workspaceId)
                _ = try? client.sendV2(method: "workspace.clear_agent_pid", params: ["workspace_id": workspaceId, "key": "claude_code"])
                _ = try? client.sendV2(method: "notification.clear", params: ["workspace_id": workspaceId])
                if !consumedSession.surfaceId.isEmpty {
                    clearAgentState(client: client, workspaceId: workspaceId, surfaceId: consumedSession.surfaceId)
                }
            }
            print("OK")

        case "pre-tool-use":
            // Clears "Needs input" status and notification when Claude resumes work
            // (e.g. after permission grant). Runs async so it doesn't block tool execution.
            let mappedSession = parsedInput.sessionId.flatMap { try? sessionStore.lookup(sessionId: $0) }

            // Deliberately best-effort, for the same reason as the surfaceId resolution
            // further down. A throw here used to abort the hook before any of the three
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
                fallback: workspaceArg,
                client: client
            ))
                ?? nonEmptyClaudeHookIdentifier(mappedSession?.workspaceId).flatMap { isUUID($0) ? $0 : nil }
                ?? nonEmptyClaudeHookIdentifier(workspaceArg).flatMap { isUUID($0) ? $0 : nil }

            // Only when there is genuinely no workspace to name is there nothing to clear.
            guard let workspaceId = resolvedWorkspaceId else {
                print("OK")
                return
            }
            let claudePid = mappedSession?.pid

            // AskUserQuestion means Claude is about to ask the user something.
            // Save question text in session so the Notification handler can use it
            // instead of the generic "Claude Code needs your attention".
            if let toolName = parsedInput.object?["tool_name"] as? String,
               toolName == "AskUserQuestion",
               let question = describeAskUserQuestion(parsedInput.object),
               let sessionId = parsedInput.sessionId {
                // Preserve the existing surfaceId from SessionStart; passing ""
                // would overwrite it and cause notifications to target the wrong workspace.
                let existingSurfaceId = (try? sessionStore.lookup(sessionId: sessionId))?.surfaceId ?? ""
                try? sessionStore.upsert(
                    sessionId: sessionId,
                    workspaceId: workspaceId,
                    surfaceId: existingSurfaceId,
                    cwd: parsedInput.cwd,
                    lastSubtitle: "Waiting",
                    lastBody: question
                )
                // Don't clear notifications or set status here.
                // The Notification hook fires right after and will use the saved question.
                print("OK")
                return
            }

            // Best-effort, and deliberately not `try`: a throw here aborted the whole hook
            // before any of the three clears below, stranding the red "blocked" badge lit
            // while Claude was already running again. Hook failures don't block tool
            // execution, so the user saw Claude working under a permission badge that
            // nothing would ever clear. Only reportAgentState needs a surface; the
            // notification and status clears are workspace-scoped and must still run.
            let surfaceId = try? resolvePreferredSurfaceIdForClaudeHook(
                preferred: mappedSession?.surfaceId,
                fallback: surfaceArg,
                workspaceId: workspaceId,
                client: client
            )

            // Clear the badge first: it is the indicator a user reads as "Claude is stuck",
            // and it is the only one of the three that can't be re-derived from anything else.
            if let surfaceId {
                reportAgentState(client: client, workspaceId: workspaceId, surfaceId: surfaceId, state: .working)
            }

            _ = try? client.sendV2(method: "notification.clear", params: ["workspace_id": workspaceId])

            let statusValue: String
            if UserDefaults.standard.bool(forKey: "claudeCodeVerboseStatus"),
               let toolStatus = describeToolUse(parsedInput.object) {
                statusValue = toolStatus
            } else {
                statusValue = "Running"
            }
            // Best-effort: benign if TabManager is already torn down.
            try? setClaudeStatus(
                client: client,
                workspaceId: workspaceId,
                value: statusValue,
                icon: "bolt.fill",
                color: "#4C8DFF",
                pid: claudePid
            )
            print("OK")

        case "help", "--help", "-h":
            print(
                """
                programa claude-hook <session-start|stop|session-end|notification|prompt-submit|pre-tool-use|subagent-start|subagent-stop> [--workspace <id|index>] [--surface <id|index>]
                """
            )

        default:
            throw CLIError(message: "Unknown claude-hook subcommand: \(subcommand)")
        }
    }

    private func setClaudeStatus(
        client: SocketClient,
        workspaceId: String,
        value: String,
        icon: String,
        color: String,
        pid: Int? = nil
    ) throws {
        var params: [String: Any] = [
            "workspace_id": workspaceId,
            "key": "claude_code",
            "value": value,
            "icon": icon,
            "color": color,
        ]
        if let pid {
            params["pid"] = pid
        }
        _ = try client.sendV2(method: "workspace.set_status", params: params)
    }

    private func clearClaudeStatus(client: SocketClient, workspaceId: String) throws {
        _ = try client.sendV2(method: "workspace.clear_status", params: ["workspace_id": workspaceId, "key": "claude_code"])
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
    private enum CLIAgentActivityState: String {
        case working
        case blocked
        case idle
    }

    /// Maps a hook notification's classified subtitle (see classifyClaudeNotification /
    /// classifyCodexNotification) to an agent activity state. Only "Permission" (approval
    /// prompt) and "Waiting" (AskUserQuestion / idle-prompt) are genuine blocking signals.
    private func agentStateForClassifiedNotificationSubtitle(_ subtitle: String) -> CLIAgentActivityState {
        switch subtitle {
        case "Permission", "Waiting":
            return .blocked
        default:
            return .idle
        }
    }

    /// Reports a surface's agent activity state via the socket. Best-effort: benign if the
    /// surface/workspace can't be resolved (e.g. TabManager already torn down).
    private func reportAgentState(
        client: SocketClient,
        workspaceId: String,
        surfaceId: String,
        state: CLIAgentActivityState
    ) {
        _ = try? client.sendV2(method: "surface.report_agent_state", params: [
            "workspace_id": workspaceId,
            "surface_id": surfaceId,
            "state": state.rawValue,
        ])
    }

    /// Clears a surface's reported agent activity state (hook session-end / process exit).
    private func clearAgentState(client: SocketClient, workspaceId: String, surfaceId: String) {
        _ = try? client.sendV2(method: "surface.clear_agent_state", params: [
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
    // not block an agent's next hook invocation. Kept as-is (no rename) per scope.
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
           (try? client.sendV2(method: "surface.list", params: ["workspace_id": candidate])) != nil {
            return candidate
        }
        if let callerWorkspaceId = resolveCallerWorkspaceIdByTTY(client: client),
           (try? client.sendV2(method: "surface.list", params: ["workspace_id": callerWorkspaceId])) != nil {
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
           let listed = try? client.sendV2(method: "surface.list", params: ["workspace_id": workspaceId]) {
            let items = listed["surfaces"] as? [[String: Any]] ?? []
            if items.contains(where: {
                ($0["id"] as? String) == candidate || ($0["ref"] as? String) == candidate
            }) {
                return candidate
            }
        }
        if let callerSurfaceId = resolveCallerSurfaceIdByTTY(workspaceId: workspaceId, client: client),
           let listed = try? client.sendV2(method: "surface.list", params: ["workspace_id": workspaceId]) {
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
        guard let payload = try? client.sendV2(method: "debug.terminals") else {
            return nil
        }
        let terminals = payload["terminals"] as? [[String: Any]] ?? []
        for terminal in terminals {
            guard normalizedTTYName(terminal["tty"] as? String) == ttyName,
                  let workspaceId = normalizedHandleValue(terminal["workspace_id"] as? String),
                  let surfaceId = normalizedHandleValue(terminal["surface_id"] as? String) else {
                continue
            }
            return CallerTerminalBinding(workspaceId: workspaceId, surfaceId: surfaceId)
        }
        return nil
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

    private func parseClaudeHookInput(rawInput: String) -> ClaudeHookParsedInput {
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

    private func summarizeClaudeHookNotification(parsedInput: ClaudeHookParsedInput) -> (subtitle: String, body: String) {
        guard let object = parsedInput.object else {
            if let fallback = parsedInput.rawFallback, !fallback.isEmpty {
                return classifyClaudeNotification(signal: fallback, message: fallback)
            }
            return ("Waiting", "Claude is waiting for your input")
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
        let message = messageCandidates.compactMap { $0 }.first ?? "Claude needs your input"
        let normalizedMessage = normalizedSingleLine(message)
        let signal = signalParts.compactMap { $0 }.joined(separator: " ")
        var classified = classifyClaudeNotification(signal: signal, message: normalizedMessage)

        classified.body = truncate(classified.body, maxLength: 180)
        return classified
    }

    private func classifyClaudeNotification(signal: String, message: String) -> (subtitle: String, body: String) {
        let lower = "\(signal) \(message)".lowercased()
        if lower.contains("permission") || lower.contains("approve") || lower.contains("approval") || lower.contains("permission_prompt") {
            let body = message.isEmpty ? "Approval needed" : message
            return ("Permission", body)
        }
        if lower.contains("error") || lower.contains("failed") || lower.contains("exception") {
            let body = message.isEmpty ? "Claude reported an error" : message
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
        if !message.isEmpty, message != "Claude needs your input" {
            return ("Attention", message)
        }
        return ("Attention", "Claude needs your attention")
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

    private func claudeSubagentTaskIdentifier(scope: String, externalAgentId: String) -> String {
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

    // MARK: - Codex hooks

    static let codexMaximumFileBytes = 16 * 1024 * 1024
    private static let codexTrustBlockStart = "# >>> programa managed codex hook trust v1 >>>"
    private static let codexTrustBlockEnd = "# <<< programa managed codex hook trust v1 <<<"
    private static let codexLegacyTrustBlockStart = "# >>> programa codex hook trust >>>"
    private static let codexLegacyTrustBlockEnd = "# <<< programa codex hook trust <<<"

    private struct CodexHookSpec {
        let event: String
        let label: String
        let commandEvent: String
        let timeout: Int
    }

    private static let codexHookSpecs = [
        CodexHookSpec(event: "SessionStart", label: "session_start", commandEvent: "session-start", timeout: 10),
        CodexHookSpec(event: "UserPromptSubmit", label: "user_prompt_submit", commandEvent: "prompt-submit", timeout: 10),
        CodexHookSpec(event: "Stop", label: "stop", commandEvent: "stop", timeout: 10),
        CodexHookSpec(event: "PermissionRequest", label: "permission_request", commandEvent: "notification", timeout: 10),
        CodexHookSpec(event: "SessionEnd", label: "session_end", commandEvent: "session-end", timeout: 1),
    ]
    private static let codexOwnedCommandEventByHookEvent: [String: String] = {
        var result = Dictionary(uniqueKeysWithValues: codexHookSpecs.map { ($0.event, $0.commandEvent) })
        result["Notification"] = "notification"
        return result
    }()

    struct CodexFileSnapshot: Equatable {
        let data: Data
        let mode: mode_t
    }

    struct CodexPaths {
        let home: String
        let lockHome: String
        let hooks: String
        let configLink: String
        let configTarget: String
    }

    struct CodexTrustEdit {
        let configPath: String
        let configLinkPath: String
        let hooksKeyPrefix: String
        let desired: [String: String]
        let removalKeys: Set<String>
        let ownedHashes: Set<String>
    }

    struct CodexPreparedConfig {
        let edit: CodexTrustEdit
        let snapshot: CodexFileSnapshot?
        let rendered: Data
    }

    private struct CodexTOMLAssignment {
        let path: [String]
        let lineRange: Range<String.Index>
        let valueRange: Range<String.Index>?
        let hasInlineComment: Bool
    }

    private struct CodexTOMLSection {
        let path: [String]
        let headerRange: Range<String.Index>
        let bodyRange: Range<String.Index>
        let fullRange: Range<String.Index>
        let hasInlineComment: Bool
    }

    private struct CodexTOMLSourceMap {
        let assignments: [CodexTOMLAssignment]
        let sections: [CodexTOMLSection]
    }

    private struct CodexSourceSplice {
        let range: Range<String.Index>
        let replacement: String
    }

    private enum CodexTOMLStringMode {
        case none
        case basic
        case literal
        case multilineBasic
        case multilineLiteral
    }

    private struct CodexTOMLLine {
        let range: Range<String.Index>
        let contentRange: Range<String.Index>
        let text: String
        let startsInString: Bool
    }

    private indirect enum CodexTOMLValue: Decodable, Equatable {
        case string(String)
        case integer(Int64)
        case float(Double)
        case boolean(Bool)
        case offsetDateTime(Date)
        case localDateTime(LocalDateTime)
        case localDate(LocalDate)
        case localTime(LocalTime)
        case array([CodexTOMLValue])
        case table([String: CodexTOMLValue])
        case null

        private struct Key: CodingKey {
            let stringValue: String
            let intValue: Int? = nil
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { return nil }
        }

        init(from decoder: Decoder) throws {
            if let container = try? decoder.container(keyedBy: Key.self) {
                var result: [String: CodexTOMLValue] = [:]
                for key in container.allKeys {
                    result[key.stringValue] = try container.decode(CodexTOMLValue.self, forKey: key)
                }
                self = .table(result)
                return
            }
            if var container = try? decoder.unkeyedContainer() {
                var result: [CodexTOMLValue] = []
                while !container.isAtEnd {
                    result.append(try container.decode(CodexTOMLValue.self))
                }
                self = .array(result)
                return
            }
            let container = try decoder.singleValueContainer()
            if container.decodeNil() { self = .null; return }
            if let value = try? container.decode(Bool.self) { self = .boolean(value); return }
            if let value = try? container.decode(Int64.self) { self = .integer(value); return }
            if let value = try? container.decode(Double.self) { self = .float(value); return }
            if let value = try? container.decode(String.self) { self = .string(value); return }
            if let value = try? container.decode(Date.self) { self = .offsetDateTime(value); return }
            if let value = try? container.decode(LocalDateTime.self) { self = .localDateTime(value); return }
            if let value = try? container.decode(LocalDate.self) { self = .localDate(value); return }
            if let value = try? container.decode(LocalTime.self) { self = .localTime(value); return }
            throw DecodingError.typeMismatch(
                CodexTOMLValue.self,
                .init(codingPath: decoder.codingPath, debugDescription: "Unsupported TOML value")
            )
        }

        var tableValue: [String: CodexTOMLValue]? {
            guard case .table(let value) = self else { return nil }
            return value
        }

        var stringValue: String? {
            guard case .string(let value) = self else { return nil }
            return value
        }
    }

    struct CodexHooksError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Each installed hook gracefully no-ops outside a programa surface.
    private static func codexHookCommand(_ event: String) -> String {
        "[ -n \"$PROGRAMA_SURFACE_ID\" ] && command -v programa >/dev/null 2>&1 && programa codex-hook \(event) || echo '{}'"
    }

    func codexPaths() throws -> CodexPaths {
        let environment = ProcessInfo.processInfo.environment
        let override = environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let explicit = override?.isEmpty == false
        let rawHome = explicit ? override! : NSString(string: "~/.codex").expandingTildeInPath
        let expanded = NSString(string: rawHome).expandingTildeInPath
        let absolute = expanded.hasPrefix("/")
            ? URL(fileURLWithPath: expanded).standardizedFileURL.path
            : URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(expanded).standardizedFileURL.path
        try FileManager.default.createDirectory(atPath: absolute, withIntermediateDirectories: true, attributes: nil)
        guard let resolvedHome = absolute.withCString({ realpath($0, nil) }) else {
            throw codexPOSIXError("resolve", path: absolute)
        }
        defer { free(resolvedHome) }
        let canonicalHome = String(cString: resolvedHome)
        let home = explicit ? canonicalHome : absolute
        let hooks = (home as NSString).appendingPathComponent("hooks.json")
        let configLink = (home as NSString).appendingPathComponent("config.toml")
        let configTarget = try codexResolveConfigTarget(configLink)
        return CodexPaths(home: home, lockHome: canonicalHome, hooks: hooks, configLink: configLink, configTarget: configTarget)
    }

    private func codexResolveConfigTarget(_ path: String) throws -> String {
        var info = stat()
        let result = path.withCString { Darwin.lstat($0, &info) }
        if result != 0 {
            if errno == ENOENT { return path }
            throw codexPOSIXError("inspect", path: path)
        }
        guard (info.st_mode & S_IFMT) == S_IFLNK else { return path }
        guard let resolved = path.withCString({ realpath($0, nil) }) else {
            throw CodexHooksError(message: "\(path) is a dangling symlink; refusing to replace it")
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    func withCodexHooksLock<T>(at home: String, _ body: () throws -> T) throws -> T {
        let path = (home as NSString).appendingPathComponent(".programa-hooks.lock")
        let descriptor = path.withCString { Darwin.open($0, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600) }
        guard descriptor >= 0 else { throw codexPOSIXError("open lock", path: path) }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw CodexHooksError(message: "\(path) is not a regular lock file")
        }
        guard flock(descriptor, LOCK_EX) == 0 else { throw codexPOSIXError("lock", path: path) }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    func codexReadRegularFile(_ path: String, limit: Int, refuseSymlink: Bool) throws -> CodexFileSnapshot? {
        if refuseSymlink {
            var linkInfo = stat()
            let result = path.withCString { Darwin.lstat($0, &linkInfo) }
            if result == 0 {
                if (linkInfo.st_mode & S_IFMT) == S_IFLNK {
                    throw CodexHooksError(message: "refusing to read symlink \(path)")
                }
            } else if errno != ENOENT {
                throw codexPOSIXError("inspect", path: path)
            }
        }
        let descriptor = path.withCString { Darwin.open($0, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW) }
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw codexPOSIXError("open", path: path)
        }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw codexPOSIXError("inspect", path: path) }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw CodexHooksError(message: "\(path) is not a regular file; refusing to read it")
        }
        guard info.st_size >= 0, info.st_size <= Int64(limit) else {
            throw CodexHooksError(message: "\(path) exceeds 16 MiB")
        }
        var data = Data()
        data.reserveCapacity(Int(info.st_size))
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw codexPOSIXError("read", path: path)
            }
            data.append(buffer, count: count)
            guard data.count <= limit else { throw CodexHooksError(message: "\(path) exceeds 16 MiB") }
        }
        return CodexFileSnapshot(data: data, mode: info.st_mode & 0o777)
    }

    func codexHooksRoot(from data: Data?, path: String) throws -> [String: Any] {
        guard let data else { return [:] }
        let value: Any
        do { value = try JSONSerialization.jsonObject(with: data) }
        catch { throw CodexHooksError(message: "\(path) is not valid JSON: \(error.localizedDescription)") }
        guard let root = value as? [String: Any] else {
            throw CodexHooksError(message: "\(path) must contain a JSON object")
        }
        return root
    }

    func codexRewriteHooks(_ source: [String: Any], install: Bool) throws -> [String: Any] {
        var root = source
        let rawHooks = root["hooks"]
        guard rawHooks == nil || rawHooks is [String: Any] else {
            throw CodexHooksError(message: "hooks.json hooks must be an object")
        }
        if rawHooks == nil, !install { return root }
        var hooks = rawHooks as? [String: Any] ?? [:]
        for event in Array(hooks.keys) {
            guard let rawGroups = hooks[event] as? [Any] else {
                throw CodexHooksError(message: "hooks.json event \(event) must be an array")
            }
            var rewritten: [[String: Any]] = []
            for (groupIndex, rawGroup) in rawGroups.enumerated() {
                guard var group = rawGroup as? [String: Any] else {
                    throw CodexHooksError(message: "hooks.json \(event) group \(groupIndex) must be an object")
                }
                guard let rawHandlers = group["hooks"] as? [Any] else {
                    throw CodexHooksError(message: "hooks.json \(event) group \(groupIndex).hooks must be an array")
                }
                var handlers: [[String: Any]] = []
                for (handlerIndex, rawHandler) in rawHandlers.enumerated() {
                    guard let handler = rawHandler as? [String: Any] else {
                        throw CodexHooksError(message: "hooks.json \(event) handler \(handlerIndex) must be an object")
                    }
                    if let command = handler["command"], !(command is String) {
                        throw CodexHooksError(message: "hooks.json \(event) handler \(handlerIndex).command must be a string")
                    }
                    if !codexIsOwnedHandler(handler, event: event) { handlers.append(handler) }
                }
                if !handlers.isEmpty {
                    group["hooks"] = handlers
                    rewritten.append(group)
                }
            }
            if rewritten.isEmpty { hooks.removeValue(forKey: event) }
            else { hooks[event] = rewritten }
        }
        if install {
            for spec in Self.codexHookSpecs {
                var groups = hooks[spec.event] as? [[String: Any]] ?? []
                groups.append(["hooks": [[
                    "type": "command",
                    "command": Self.codexHookCommand(spec.commandEvent),
                    "timeout": spec.timeout,
                ] as [String: Any]]])
                hooks[spec.event] = groups
            }
        }
        root["hooks"] = hooks
        try codexValidateForeignHandlerPositions(before: source, after: root)
        return root
    }

    private func codexValidateForeignHandlerPositions(
        before: [String: Any],
        after: [String: Any]
    ) throws {
        for spec in Self.codexHookSpecs {
            let oldPositions = codexForeignHandlerPositions(root: before, event: spec.event)
            let newPositions = codexForeignHandlerPositions(root: after, event: spec.event)
            guard oldPositions.count == newPositions.count else {
                throw CodexHooksError(message: "rewriting \(spec.event) would change the foreign handler set; refusing to reuse Codex trust positions")
            }
            for (index, pair) in zip(oldPositions, newPositions).enumerated() where pair.0 != pair.1 {
                throw CodexHooksError(
                    message: "rewriting \(spec.event) would move foreign handler \(index) from \(pair.0.0):\(pair.0.1) to \(pair.1.0):\(pair.1.1); refusing to reuse Codex trust positions"
                )
            }
        }
    }

    private func codexForeignHandlerPositions(root: [String: Any], event: String) -> [(Int, Int)] {
        guard let hooks = root["hooks"] as? [String: Any],
              let groups = hooks[event] as? [[String: Any]] else { return [] }
        var positions: [(Int, Int)] = []
        for (groupIndex, group) in groups.enumerated() {
            guard let handlers = group["hooks"] as? [[String: Any]] else { continue }
            for (handlerIndex, handler) in handlers.enumerated() where !codexIsOwnedHandler(handler, event: event) {
                positions.append((groupIndex, handlerIndex))
            }
        }
        return positions
    }

    private func codexIsOwnedHandler(_ handler: [String: Any], event: String) -> Bool {
        guard let commandEvent = Self.codexOwnedCommandEventByHookEvent[event],
              let command = handler["command"] as? String else { return false }
        return command == Self.codexHookCommand(commandEvent)
            || command == "programa codex-hook \(commandEvent)"
    }

    func codexEncodeHooks(_ root: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(root) else {
            throw CodexHooksError(message: "merged hooks.json is not serializable")
        }
        var data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        data.append(0x0A)
        return data
    }

    func codexExpectedTrustEntries(hooksPath: String, root: [String: Any]) throws -> [String: String] {
        var result: [String: String] = [:]
        for spec in Self.codexHookSpecs {
            let entry = try codexOwnedHookEntry(root: root, spec: spec)
            let key = "\(hooksPath):\(spec.label):\(entry.groupIndex):\(entry.handlerIndex)"
            result[key] = try codexTrustHash(label: spec.label, group: entry.group, handler: entry.handler)
        }
        return result
    }

    private func codexOwnedHookEntry(
        root: [String: Any],
        spec: CodexHookSpec
    ) throws -> (groupIndex: Int, handlerIndex: Int, group: [String: Any], handler: [String: Any]) {
        guard let hooks = root["hooks"] as? [String: Any],
              let groups = hooks[spec.event] as? [[String: Any]] else {
            throw CodexHooksError(message: "installed Codex hook for \(spec.event) is missing")
        }
        for (groupIndex, group) in groups.enumerated() {
            guard let handlers = group["hooks"] as? [[String: Any]] else { continue }
            for (handlerIndex, handler) in handlers.enumerated() where codexIsOwnedHandler(handler, event: spec.event) {
                return (groupIndex, handlerIndex, group, handler)
            }
        }
        throw CodexHooksError(message: "installed Codex hook for \(spec.event) is missing")
    }

    func codexOwnedEntryKeys(hooksPath: String, root: [String: Any]) -> Set<String> {
        guard let hooks = root["hooks"] as? [String: Any] else { return [] }
        let labels = Dictionary(uniqueKeysWithValues: Self.codexHookSpecs.map { ($0.event, $0.label) })
        var keys: Set<String> = []
        for (event, rawGroups) in hooks {
            guard let label = labels[event], let groups = rawGroups as? [[String: Any]] else { continue }
            for (groupIndex, group) in groups.enumerated() {
                guard let handlers = group["hooks"] as? [[String: Any]] else { continue }
                for (handlerIndex, handler) in handlers.enumerated() where codexIsOwnedHandler(handler, event: event) {
                    keys.insert("\(hooksPath):\(label):\(groupIndex):\(handlerIndex)")
                }
            }
        }
        return keys
    }

    func codexOwnedTrustHashes() throws -> Set<String> {
        var hashes: Set<String> = []
        for spec in Self.codexHookSpecs {
            let group: [String: Any] = [:]
            let handler: [String: Any] = [
                "type": "command",
                "command": Self.codexHookCommand(spec.commandEvent),
                "timeout": spec.timeout,
            ]
            hashes.insert(try codexTrustHash(label: spec.label, group: group, handler: handler))
        }
        return hashes
    }

    private func codexTrustHash(label: String, group: [String: Any], handler: [String: Any]) throws -> String {
        guard (handler["type"] as? String) == "command",
              let command = handler["command"] as? String else {
            throw CodexHooksError(message: "Codex hook \(label) must be a command handler")
        }
        let asynchronous: Bool
        if let value = handler["async"] {
            guard let value = value as? Bool else { throw CodexHooksError(message: "Codex hook async must be a boolean") }
            asynchronous = value
        } else {
            asynchronous = false
        }
        var normalized: [String: Any] = [
            "async": asynchronous,
            "command": command,
            "timeout": try codexNormalizedTimeout(label: label, value: handler["timeout"]),
            "type": "command",
        ]
        if let status = handler["statusMessage"] {
            guard let status = status as? String else { throw CodexHooksError(message: "Codex hook statusMessage must be a string") }
            normalized["statusMessage"] = status
        }
        if let rawLimit = handler["additionalContextLimit"] {
            let limit = try codexInteger(rawLimit, field: "additionalContextLimit")
            if ["pre_tool_use", "post_tool_use", "session_start", "user_prompt_submit", "subagent_start"].contains(label),
               limit != 2_500 {
                normalized["additionalContextLimit"] = limit
            }
        }
        var identity: [String: Any] = ["event_name": label, "hooks": [normalized]]
        if label != "user_prompt_submit", label != "stop", let matcher = group["matcher"] {
            guard let matcher = matcher as? String else { throw CodexHooksError(message: "Codex hook matcher must be a string") }
            identity["matcher"] = matcher
        }
        let data = try JSONSerialization.data(withJSONObject: identity, options: [.sortedKeys, .withoutEscapingSlashes])
        return "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func codexNormalizedTimeout(label: String, value: Any?) throws -> Int {
        let fallback = label == "session_end" ? 1 : 600
        let timeout = value == nil ? fallback : try codexInteger(value!, field: "timeout")
        return label == "session_end" ? min(max(timeout, 1), 3) : max(timeout, 1)
    }

    private func codexInteger(_ value: Any, field: String) throws -> Int {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            throw CodexHooksError(message: "Codex hook \(field) must be an integer")
        }
        let double = number.doubleValue
        guard double.rounded() == double, double >= Double(Int.min), double <= Double(Int.max) else {
            throw CodexHooksError(message: "Codex hook \(field) must be an integer")
        }
        return number.intValue
    }

    func codexPrepareConfig(_ edit: CodexTrustEdit) throws -> CodexPreparedConfig {
        let snapshot = try codexReadRegularFile(edit.configPath, limit: Self.codexMaximumFileBytes, refuseSymlink: true)
        let original = try codexUTF8(snapshot?.data ?? Data(), path: edit.configPath)
        let rendered = try codexRenderConfig(original, edit: edit)
        try codexProbeWritableDirectory((edit.configPath as NSString).deletingLastPathComponent)
        return CodexPreparedConfig(edit: edit, snapshot: snapshot, rendered: Data(rendered.utf8))
    }

    func codexCommitConfig(_ prepared: CodexPreparedConfig) throws {
        let resolvedTarget = try codexResolveConfigTarget(prepared.edit.configLinkPath)
        guard resolvedTarget == prepared.edit.configPath else {
            throw CodexHooksError(message: "\(prepared.edit.configLinkPath) changed targets during installation; retry the command")
        }
        let current = try codexReadRegularFile(prepared.edit.configPath, limit: Self.codexMaximumFileBytes, refuseSymlink: true)
        let rendered: Data
        if current == prepared.snapshot {
            rendered = prepared.rendered
        } else {
            let fresh = try codexUTF8(current?.data ?? Data(), path: prepared.edit.configPath)
            rendered = Data(try codexRenderConfig(fresh, edit: prepared.edit).utf8)
        }
        guard (current?.data ?? Data()) != rendered else { return }
        try codexAtomicWrite(rendered, to: prepared.edit.configPath, mode: current?.mode ?? 0o600)
    }

    private func codexRenderConfig(_ source: String, edit: CodexTrustEdit) throws -> String {
        let originalTree = try codexParseTOML(source, path: edit.configPath)
        let newline = codexNewline(in: source)
        var working = try codexRemovingManagedBlocks(source, edit: edit)
        let baseTree = try codexParseTOML(working, path: edit.configPath)
        try codexValidateTrustShape(baseTree, path: edit.configPath)
        let map = try codexTOMLSourceMap(working)
        var splices: [CodexSourceSplice] = []

        if baseTree.tableValue?["features"]?.tableValue?["codex_hooks"] != nil {
            let matches = map.assignments.filter { $0.path == ["features", "codex_hooks"] }
            guard matches.count == 1, matches[0].valueRange != nil, !matches[0].hasInlineComment else {
                throw CodexHooksError(message: "codex_hooks in \(edit.configPath) uses an inline or multiline form that cannot be edited safely")
            }
            splices.append(.init(range: matches[0].lineRange, replacement: ""))
        }

        let state = baseTree.tableValue?["hooks"]?.tableValue?["state"]?.tableValue ?? [:]
        let ownedFromHashes = Set(state.compactMap { key, value -> String? in
            guard key.hasPrefix(edit.hooksKeyPrefix),
                  let hash = value.tableValue?["trusted_hash"]?.stringValue,
                  edit.ownedHashes.contains(hash) else { return nil }
            return key
        })
        let removable = edit.removalKeys.union(ownedFromHashes).subtracting(edit.desired.keys)
        let statePrefix = ["hooks", "state"]
        for key in removable {
            guard state[key] != nil else { continue }
            let path = statePrefix + [key]
            let sections = map.sections.filter { $0.path == path }
            if sections.count == 1 {
                try codexValidateRemovableTrustSection(sections[0], key: key, map: map, source: working)
                splices.append(.init(range: sections[0].fullRange, replacement: ""))
                continue
            }
            let assignments = map.assignments.filter { $0.path.starts(with: path) }
            guard assignments.count == 1,
                  assignments[0].path == path + ["trusted_hash"],
                  assignments[0].valueRange != nil,
                  !assignments[0].hasInlineComment else {
                throw CodexHooksError(message: "trust entry \(key) in \(edit.configPath) is inline and cannot be removed safely")
            }
            splices.append(.init(range: assignments[0].lineRange, replacement: ""))
        }

        var appendDesired = edit.desired
        for (key, hash) in edit.desired where state[key] != nil {
            let path = statePrefix + [key]
            let sections = map.sections.filter { $0.path == path }
            if sections.count == 1 {
                let hashAssignments = map.assignments.filter { $0.path == path + ["trusted_hash"] }
                if hashAssignments.count == 1, let valueRange = hashAssignments[0].valueRange {
                    splices.append(.init(range: valueRange, replacement: try codexTOMLQuoted(hash)))
                } else if hashAssignments.isEmpty {
                    splices.append(.init(
                        range: sections[0].bodyRange.lowerBound..<sections[0].bodyRange.lowerBound,
                        replacement: "trusted_hash = \(try codexTOMLQuoted(hash))\(newline)"
                    ))
                } else {
                    throw CodexHooksError(message: "trusted_hash for \(key) in \(edit.configPath) cannot be edited safely")
                }
                appendDesired.removeValue(forKey: key)
                continue
            }
            let dotted = map.assignments.filter { $0.path == path + ["trusted_hash"] }
            guard dotted.count == 1, let valueRange = dotted[0].valueRange else {
                throw CodexHooksError(message: "trust entry \(key) in \(edit.configPath) is inline and cannot be edited safely")
            }
            splices.append(.init(range: valueRange, replacement: try codexTOMLQuoted(hash)))
            appendDesired.removeValue(forKey: key)
        }

        working = try codexApplySplices(splices, to: working)
        if !appendDesired.isEmpty {
            if let hooks = baseTree.tableValue?["hooks"], hooks.tableValue == nil {
                throw CodexHooksError(message: "hooks in \(edit.configPath) is not a table")
            }
            if map.assignments.contains(where: { $0.path == ["hooks"] || $0.path == ["hooks", "state"] }) {
                throw CodexHooksError(message: "inline hooks/state in \(edit.configPath) cannot be extended safely")
            }
            if !working.isEmpty && !working.hasSuffix("\n") { working += newline }
            if !working.isEmpty && !working.hasSuffix(newline + newline) { working += newline }
            working += Self.codexTrustBlockStart + newline
            for (key, hash) in appendDesired.sorted(by: { $0.key < $1.key }) {
                working += "[hooks.state.\(try codexTOMLQuoted(key))]\(newline)"
                working += "trusted_hash = \(try codexTOMLQuoted(hash))\(newline)\(newline)"
            }
            working += Self.codexTrustBlockEnd + newline
        }

        let renderedTree = try codexParseTOML(working, path: edit.configPath)
        try codexVerifyRenderedConfig(original: originalTree, rendered: renderedTree, edit: edit)
        return working
    }

    private func codexValidateTrustShape(_ root: CodexTOMLValue, path: String) throws {
        guard let table = root.tableValue else { throw CodexHooksError(message: "\(path) must contain a TOML table") }
        if let hooks = table["hooks"] {
            guard let hooksTable = hooks.tableValue else {
                throw CodexHooksError(message: "hooks in \(path) is not a table, so Codex cannot read trust state")
            }
            if let state = hooksTable["state"], state.tableValue == nil {
                throw CodexHooksError(message: "hooks.state in \(path) is not a table")
            }
        }
    }

    private func codexVerifyRenderedConfig(
        original: CodexTOMLValue,
        rendered: CodexTOMLValue,
        edit: CodexTrustEdit
    ) throws {
        guard var originalRoot = original.tableValue, var renderedRoot = rendered.tableValue else {
            throw CodexHooksError(message: "Codex config must be a TOML table")
        }
        var originalFeatures = originalRoot["features"]?.tableValue ?? [:]
        var renderedFeatures = renderedRoot["features"]?.tableValue ?? [:]
        originalFeatures.removeValue(forKey: "codex_hooks")
        renderedFeatures.removeValue(forKey: "codex_hooks")
        guard originalFeatures == renderedFeatures else {
            throw CodexHooksError(message: "Codex config feature verification failed; refusing to write")
        }
        originalRoot.removeValue(forKey: "features")
        renderedRoot.removeValue(forKey: "features")

        var originalHooks = originalRoot["hooks"]?.tableValue ?? [:]
        var renderedHooks = renderedRoot["hooks"]?.tableValue ?? [:]
        let originalState = originalHooks.removeValue(forKey: "state")?.tableValue ?? [:]
        let renderedState = renderedHooks.removeValue(forKey: "state")?.tableValue ?? [:]
        guard originalHooks == renderedHooks else {
            throw CodexHooksError(message: "Codex config hooks verification failed; refusing to write")
        }
        originalRoot.removeValue(forKey: "hooks")
        renderedRoot.removeValue(forKey: "hooks")
        guard originalRoot == renderedRoot else {
            throw CodexHooksError(message: "Codex config changed outside Programa-owned state; refusing to write")
        }

        let ignored = edit.removalKeys.union(edit.desired.keys)
        let foreignOriginal = originalState.filter { key, value in
            guard key.hasPrefix(edit.hooksKeyPrefix) else { return true }
            if ignored.contains(key) { return false }
            let hash = value.tableValue?["trusted_hash"]?.stringValue
            return hash == nil || !edit.ownedHashes.contains(hash!)
        }
        let foreignRendered = renderedState.filter { key, _ in foreignOriginal[key] != nil }
        guard foreignOriginal == foreignRendered else {
            throw CodexHooksError(message: "foreign Codex trust state changed; refusing to write")
        }
        for (key, hash) in edit.desired {
            guard renderedState[key]?.tableValue?["trusted_hash"]?.stringValue == hash else {
                throw CodexHooksError(message: "Codex trust entry \(key) did not render correctly")
            }
        }
        for key in edit.removalKeys where edit.desired[key] == nil {
            guard renderedState[key] == nil else {
                throw CodexHooksError(message: "stale Codex trust entry \(key) was not removed")
            }
        }
    }

    private func codexParseTOML(_ source: String, path: String) throws -> CodexTOMLValue {
        let decoder = TOMLDecoder()
        decoder.limits = .init(
            maxInputSize: Self.codexMaximumFileBytes,
            maxDepth: 128,
            maxTableKeys: 100_000,
            maxArrayLength: 100_000,
            maxStringLength: Self.codexMaximumFileBytes
        )
        do { return .table(try decoder.decode([String: CodexTOMLValue].self, from: source)) }
        catch { throw CodexHooksError(message: "\(path) is not valid TOML: \(error.localizedDescription)") }
    }

    private func codexRemovingManagedBlocks(_ source: String, edit: CodexTrustEdit) throws -> String {
        let lines = codexTOMLLines(source)
        let starts = lines.filter { line in
            !line.startsInString && [Self.codexTrustBlockStart, Self.codexLegacyTrustBlockStart].contains(line.text)
        }
        let ends = lines.filter { line in
            !line.startsInString && [Self.codexTrustBlockEnd, Self.codexLegacyTrustBlockEnd].contains(line.text)
        }
        guard starts.count <= 1, ends.count <= 1 else {
            throw CodexHooksError(message: "Codex config contains duplicate Programa trust blocks")
        }
        guard starts.count == ends.count else {
            throw CodexHooksError(message: "Codex config contains an unmatched Programa trust marker")
        }
        guard let start = starts.first, let end = ends.first else { return source }
        let expectedEnd = start.text == Self.codexTrustBlockStart
            ? Self.codexTrustBlockEnd
            : Self.codexLegacyTrustBlockEnd
        guard end.text == expectedEnd, start.range.lowerBound < end.range.lowerBound else {
            throw CodexHooksError(message: "Codex config contains mismatched Programa trust markers")
        }
        let interior = String(source[start.range.upperBound..<end.range.lowerBound])
        try codexValidateManagedTrustBlock(interior, edit: edit)
        var result = source
        result.removeSubrange(start.range.lowerBound..<end.range.upperBound)
        return result
    }

    private func codexValidateManagedTrustBlock(_ source: String, edit: CodexTrustEdit) throws {
        let tree = try codexParseTOML(source, path: edit.configPath)
        let state = tree.tableValue?["hooks"]?.tableValue?["state"]?.tableValue ?? [:]
        let map = try codexTOMLSourceMap(source)
        guard !state.isEmpty, map.sections.count == state.count else {
            throw CodexHooksError(message: "Programa trust block contains unrecognized content")
        }
        for line in codexTOMLLines(source) {
            let recognized = map.sections.contains { $0.headerRange == line.range }
                || map.assignments.contains { $0.lineRange == line.range }
            guard recognized || line.text.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw CodexHooksError(message: "Programa trust block contains comments or unrecognized content")
            }
        }
        for section in map.sections {
            guard section.path.count == 3,
                  section.path[0] == "hooks",
                  section.path[1] == "state" else {
                throw CodexHooksError(message: "Programa trust block contains an unrecognized table")
            }
            let key = section.path[2]
            try codexValidateRemovableTrustSection(section, key: key, map: map, source: source)
            guard key.hasPrefix(edit.hooksKeyPrefix),
                  let hash = state[key]?.tableValue?["trusted_hash"]?.stringValue,
                  edit.removalKeys.contains(key)
                    || edit.desired[key] == hash
                    || edit.ownedHashes.contains(hash) else {
                throw CodexHooksError(message: "Programa trust block contains an unrecognized trust entry")
            }
        }
    }

    private func codexValidateRemovableTrustSection(
        _ section: CodexTOMLSection,
        key: String,
        map: CodexTOMLSourceMap,
        source: String
    ) throws {
        guard !section.hasInlineComment else {
            throw CodexHooksError(message: "trust entry \(key) has a comment that Programa cannot remove safely")
        }
        let expectedPath = section.path + ["trusted_hash"]
        let assignments = map.assignments.filter {
            $0.lineRange.lowerBound >= section.bodyRange.lowerBound
                && $0.lineRange.upperBound <= section.bodyRange.upperBound
        }
        guard assignments.count == 1,
              assignments[0].path == expectedPath,
              assignments[0].valueRange != nil,
              !assignments[0].hasInlineComment else {
            throw CodexHooksError(message: "trust entry \(key) contains fields or comments that Programa cannot remove safely")
        }
        for line in codexTOMLLines(source) {
            guard line.range.lowerBound >= section.bodyRange.lowerBound,
                  line.range.upperBound <= section.bodyRange.upperBound else { continue }
            if line.range == assignments[0].lineRange { continue }
            guard line.text.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw CodexHooksError(message: "trust entry \(key) contains unrecognized content that Programa cannot remove safely")
            }
        }
    }

    private func codexTOMLLines(_ source: String) -> [CodexTOMLLine] {
        var result: [CodexTOMLLine] = []
        var mode = CodexTOMLStringMode.none
        var cursor = source.startIndex
        while cursor < source.endIndex {
            let newline = source[cursor...].firstIndex(of: "\n")
            let contentEndWithCR = newline ?? source.endIndex
            let lineEnd = newline.map { source.index(after: $0) } ?? source.endIndex
            let contentEnd: String.Index
            if contentEndWithCR > cursor,
               source[source.index(before: contentEndWithCR)] == "\r" {
                contentEnd = source.index(before: contentEndWithCR)
            } else {
                contentEnd = contentEndWithCR
            }
            let startsInString = mode != .none
            let text = String(source[cursor..<contentEnd])
            result.append(.init(
                range: cursor..<lineEnd,
                contentRange: cursor..<contentEnd,
                text: text,
                startsInString: startsInString
            ))
            mode = codexAdvanceStringMode(in: text, from: mode)
            cursor = lineEnd
        }
        return result
    }

    private func codexAdvanceStringMode(
        in line: String,
        from initial: CodexTOMLStringMode
    ) -> CodexTOMLStringMode {
        var mode = initial
        var cursor = line.startIndex
        while cursor < line.endIndex {
            let suffix = line[cursor...]
            switch mode {
            case .none:
                if line[cursor] == "#" { return .none }
                if suffix.hasPrefix("\"\"\"") {
                    mode = .multilineBasic
                    cursor = line.index(cursor, offsetBy: 3)
                } else if suffix.hasPrefix("'''") {
                    mode = .multilineLiteral
                    cursor = line.index(cursor, offsetBy: 3)
                } else if line[cursor] == "\"" {
                    mode = .basic
                    cursor = line.index(after: cursor)
                } else if line[cursor] == "'" {
                    mode = .literal
                    cursor = line.index(after: cursor)
                } else {
                    cursor = line.index(after: cursor)
                }
            case .basic:
                if line[cursor] == "\\" {
                    cursor = line.index(after: cursor)
                    if cursor < line.endIndex { cursor = line.index(after: cursor) }
                } else {
                    if line[cursor] == "\"" { mode = .none }
                    cursor = line.index(after: cursor)
                }
            case .literal:
                if line[cursor] == "'" { mode = .none }
                cursor = line.index(after: cursor)
            case .multilineBasic:
                if suffix.hasPrefix("\"\"\"") {
                    mode = .none
                    cursor = line.index(cursor, offsetBy: 3)
                } else if line[cursor] == "\\" {
                    cursor = line.index(after: cursor)
                    if cursor < line.endIndex { cursor = line.index(after: cursor) }
                } else {
                    cursor = line.index(after: cursor)
                }
            case .multilineLiteral:
                if suffix.hasPrefix("'''") {
                    mode = .none
                    cursor = line.index(cursor, offsetBy: 3)
                } else {
                    cursor = line.index(after: cursor)
                }
            }
        }
        return mode
    }

    private func codexNewline(in source: String) -> String {
        guard let newline = source.firstIndex(of: "\n") else { return "\n" }
        return newline > source.startIndex && source[source.index(before: newline)] == "\r" ? "\r\n" : "\n"
    }

    private func codexTOMLSourceMap(_ source: String) throws -> CodexTOMLSourceMap {
        struct Header {
            let path: [String]
            let range: Range<String.Index>
            let bodyStart: String.Index
            let hasInlineComment: Bool
        }
        var headers: [Header] = []
        var assignments: [CodexTOMLAssignment] = []
        var currentTable: [String] = []
        for line in codexTOMLLines(source) where !line.startsInString {
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                if let header = try codexParseTableHeader(trimmed) {
                    currentTable = header.path
                    headers.append(.init(
                        path: header.path,
                        range: line.range,
                        bodyStart: line.range.upperBound,
                        hasInlineComment: header.hasInlineComment
                    ))
                }
            } else if !trimmed.isEmpty, !trimmed.hasPrefix("#"),
                      let assignment = try codexParseAssignment(source, line: line) {
                assignments.append(.init(
                    path: currentTable + assignment.path,
                    lineRange: line.range,
                    valueRange: assignment.valueRange,
                    hasInlineComment: assignment.hasInlineComment
                ))
            }
        }
        let sections = headers.enumerated().map { index, header in
            let end = index + 1 < headers.count ? headers[index + 1].range.lowerBound : source.endIndex
            return CodexTOMLSection(
                path: header.path,
                headerRange: header.range,
                bodyRange: header.bodyStart..<end,
                fullRange: header.range.lowerBound..<end,
                hasInlineComment: header.hasInlineComment
            )
        }
        return CodexTOMLSourceMap(assignments: assignments, sections: sections)
    }

    private func codexParseTableHeader(_ line: String) throws -> (path: [String], hasInlineComment: Bool)? {
        let arrayTable = line.hasPrefix("[[")
        let opening = arrayTable ? 2 : 1
        let start = line.index(line.startIndex, offsetBy: opening)
        var quote: Character?
        var escaped = false
        var cursor = start
        while cursor < line.endIndex {
            let character = line[cursor]
            if escaped { escaped = false; cursor = line.index(after: cursor); continue }
            if quote == "\"", character == "\\" { escaped = true; cursor = line.index(after: cursor); continue }
            if character == "\"" || character == "'" {
                if quote == character { quote = nil } else if quote == nil { quote = character }
                cursor = line.index(after: cursor)
                continue
            }
            if character == "]", quote == nil {
                let closeEnd = line.index(after: cursor)
                if arrayTable {
                    guard closeEnd < line.endIndex, line[closeEnd] == "]" else { return nil }
                }
                let suffixStart = arrayTable ? line.index(after: closeEnd) : closeEnd
                let suffix = line[suffixStart...].trimmingCharacters(in: .whitespaces)
                guard suffix.isEmpty || suffix.hasPrefix("#") else { return nil }
                return (try codexParseKeyPath(String(line[start..<cursor])), suffix.hasPrefix("#"))
            }
            cursor = line.index(after: cursor)
        }
        return nil
    }

    private func codexParseAssignment(
        _ source: String,
        line: CodexTOMLLine
    ) throws -> (path: [String], valueRange: Range<String.Index>?, hasInlineComment: Bool)? {
        let content = source[line.contentRange]
        var quote: Character?
        var escaped = false
        for index in content.indices {
            let character = source[index]
            if escaped { escaped = false; continue }
            if quote == "\"", character == "\\" { escaped = true; continue }
            if character == "\"" || character == "'" {
                if quote == character { quote = nil } else if quote == nil { quote = character }
                continue
            }
            if character == "=", quote == nil {
                let path = try codexParseKeyPath(String(source[line.contentRange.lowerBound..<index]))
                var valueStart = source.index(after: index)
                while valueStart < line.contentRange.upperBound, source[valueStart].isWhitespace {
                    valueStart = source.index(after: valueStart)
                }
                let scalar = codexScalarRange(in: source, from: valueStart, to: line.contentRange.upperBound)
                guard let scalar else { return (path, nil, false) }
                var suffix = scalar.upperBound
                while suffix < line.contentRange.upperBound, source[suffix].isWhitespace {
                    suffix = source.index(after: suffix)
                }
                let hasComment = suffix < line.contentRange.upperBound && source[suffix] == "#"
                guard suffix == line.contentRange.upperBound || hasComment else { return (path, nil, false) }
                return (path, scalar, hasComment)
            }
        }
        return nil
    }

    private func codexScalarRange(
        in source: String,
        from start: String.Index,
        to end: String.Index
    ) -> Range<String.Index>? {
        guard start < end else { return nil }
        if source[start...].hasPrefix("\"\"\"") || source[start...].hasPrefix("'''")
            || source[start] == "[" || source[start] == "{" {
            return nil
        }
        if source[start] == "\"" || source[start] == "'" {
            let quote = source[start]
            var escaped = false
            var cursor = source.index(after: start)
            while cursor < end {
                let character = source[cursor]
                if escaped { escaped = false; cursor = source.index(after: cursor); continue }
                if quote == "\"", character == "\\" { escaped = true; cursor = source.index(after: cursor); continue }
                cursor = source.index(after: cursor)
                if character == quote { return start..<cursor }
            }
            return nil
        }
        var cursor = start
        while cursor < end, !source[cursor].isWhitespace, source[cursor] != "#" {
            cursor = source.index(after: cursor)
        }
        return cursor > start ? start..<cursor : nil
    }

    private func codexParseKeyPath(_ source: String) throws -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        func finish() throws {
            let token = current.trimmingCharacters(in: .whitespaces)
            guard !token.isEmpty else { throw CodexHooksError(message: "invalid empty TOML key") }
            let decoder = TOMLDecoder()
            let decoded = try decoder.decode([String: Int].self, from: "\(token) = 1")
            guard let key = decoded.keys.first else { throw CodexHooksError(message: "invalid TOML key \(token)") }
            tokens.append(key)
            current = ""
        }
        for character in source {
            if escaped { current.append(character); escaped = false; continue }
            if quote == "\"", character == "\\" { current.append(character); escaped = true; continue }
            if character == "\"" || character == "'" {
                current.append(character)
                if quote == character { quote = nil } else if quote == nil { quote = character }
                continue
            }
            if character == ".", quote == nil { try finish() }
            else { current.append(character) }
        }
        try finish()
        return tokens
    }

    private func codexApplySplices(_ splices: [CodexSourceSplice], to source: String) throws -> String {
        let sorted = splices.sorted {
            source.distance(from: source.startIndex, to: $0.range.lowerBound)
                > source.distance(from: source.startIndex, to: $1.range.lowerBound)
        }
        var result = source
        var previousLower = source.endIndex
        for splice in sorted {
            guard splice.range.upperBound <= previousLower else {
                throw CodexHooksError(message: "overlapping Codex config edits; refusing to write")
            }
            result.replaceSubrange(splice.range, with: splice.replacement)
            previousLower = splice.range.lowerBound
        }
        return result
    }

    private func codexTOMLQuoted(_ value: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [value], options: [.withoutEscapingSlashes])
        let encoded = String(decoding: data, as: UTF8.self)
        return String(encoded.dropFirst().dropLast())
    }

    private func codexUTF8(_ data: Data, path: String) throws -> String {
        guard let value = String(data: data, encoding: .utf8) else {
            throw CodexHooksError(message: "\(path) is not valid UTF-8")
        }
        return value
    }

    private func codexProbeWritableDirectory(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: nil)
        let probe = (path as NSString).appendingPathComponent(".programa-preflight-\(UUID().uuidString)")
        let descriptor = probe.withCString { Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600) }
        guard descriptor >= 0 else { throw codexPOSIXError("preflight write access to", path: path) }
        Darwin.close(descriptor)
        guard unlink(probe) == 0 else { throw codexPOSIXError("remove preflight", path: probe) }
    }

    func codexAtomicWrite(_ data: Data, to path: String, mode: mode_t) throws {
        var targetInfo = stat()
        if path.withCString({ Darwin.lstat($0, &targetInfo) }) == 0 {
            guard (targetInfo.st_mode & S_IFMT) == S_IFREG else {
                throw CodexHooksError(message: "refusing to replace non-regular file \(path)")
            }
        } else if errno != ENOENT {
            throw codexPOSIXError("inspect", path: path)
        }
        let parent = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true, attributes: nil)
        let directoryDescriptor = try codexOpenDirectory(parent)
        defer { Darwin.close(directoryDescriptor) }
        let name = (path as NSString).lastPathComponent
        let temporary = (parent as NSString).appendingPathComponent(".\(name).programa-\(UUID().uuidString)")
        let descriptor = temporary.withCString { Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode) }
        guard descriptor >= 0 else { throw codexPOSIXError("create", path: temporary) }
        var shouldRemove = true
        var descriptorIsOpen = true
        defer {
            if descriptorIsOpen { Darwin.close(descriptor) }
            if shouldRemove { unlink(temporary) }
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw codexPOSIXError("write", path: temporary)
                }
                offset += count
            }
        }
        guard fchmod(descriptor, mode) == 0 else { throw codexPOSIXError("set mode", path: temporary) }
        guard fsync(descriptor) == 0 else { throw codexPOSIXError("sync", path: temporary) }
        guard Darwin.close(descriptor) == 0 else { throw codexPOSIXError("close", path: temporary) }
        descriptorIsOpen = false
        var replacementInfo = stat()
        if path.withCString({ Darwin.lstat($0, &replacementInfo) }) == 0,
           (replacementInfo.st_mode & S_IFMT) != S_IFREG {
            throw CodexHooksError(message: "refusing to replace non-regular file \(path)")
        }
        guard rename(temporary, path) == 0 else { throw codexPOSIXError("replace", path: path) }
        shouldRemove = false
        codexSyncDirectoryAfterCommit(directoryDescriptor, path: parent)
    }

    func codexRestoreFile(_ snapshot: CodexFileSnapshot?, at path: String) throws {
        if let snapshot {
            try codexAtomicWrite(snapshot.data, to: path, mode: snapshot.mode)
            return
        }
        let parent = (path as NSString).deletingLastPathComponent
        let directoryDescriptor = try codexOpenDirectory(parent)
        defer { Darwin.close(directoryDescriptor) }
        if unlink(path) != 0 {
            if errno == ENOENT { return }
            throw codexPOSIXError("remove", path: path)
        }
        codexSyncDirectoryAfterCommit(directoryDescriptor, path: parent)
    }

    private func codexOpenDirectory(_ path: String) throws -> Int32 {
        let descriptor = path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC) }
        guard descriptor >= 0 else { throw codexPOSIXError("open directory", path: path) }
        return descriptor
    }

    private func codexSyncDirectoryAfterCommit(_ descriptor: Int32, path: String) {
        guard fsync(descriptor) != 0 else { return }
        let message = "warning: committed Codex hook change, but syncing directory \(path) failed: \(String(cString: strerror(errno)))\n"
        FileHandle.standardError.write(Data(message.utf8))
    }

    private func codexPOSIXError(_ action: String, path: String) -> Error {
        let code = errno
        return CodexHooksError(message: "\(action) \(path): \(String(cString: strerror(code)))")
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
    description: Drive the programa terminal app from inside a programa surface — inspect windows/workspaces/panes/surfaces, split panes and run commands without stealing the user's focus, read output from sibling panes, spawn and coordinate a helper agent, and wait on it. Use whenever an agent is running inside programa (PROGRAMA_SURFACE_ID and PROGRAMA_SOCKET_PATH are set) and needs to control the app itself, not just the shell inside one pane. Do not use, and do not call the programa CLI at all, when those two variables are unset — that means the agent is not running inside programa.
    ---

    <!-- Installed and managed by `programa claude install-integration` / `programa codex install-hooks` / `programa opencode install-integration`. Manual edits to an installed copy get overwritten on the next install — edit the source at repo root (darkroomengineering/programa) instead. -->

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

    The `programa` CLI is already on `PATH` inside a programa terminal. Verify with `command -v programa`.

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

    Useful flags:

    ```bash
    programa tree --all                       # every window, not just the current one
    programa tree --workspace workspace:2     # scope to one workspace
    programa --json tree                      # structured JSON (global --json flag goes before the subcommand)
    ```

    Narrower listings, when you don't need the whole tree:

    ```bash
    programa list-workspaces          # workspaces in the current window
    programa list-panes               # panes in the current workspace
    programa list-pane-surfaces       # surfaces (tabs) in the focused pane; add --pane <id> for another
    programa identify                 # your own window/workspace/surface IDs as JSON
    ```

    All of the above default to your own window/workspace via the env vars when you don't pass `--workspace`/`--window`.

    ## Splitting panes and running commands without stealing focus

    programa's commands split cleanly into two groups:

    - **Focus-preserving** — safe to call at any time from any agent: `new-split`, `new-pane`, `new-surface`, `send`, `send-key`, `send-panel`, `send-key-panel`, `read-screen` (alias `capture-pane`). None of these move the user's cursor, raise the window, or change the active tab.
    - **Focus-changing** — only call these when you actually mean to move the user's attention: `focus-pane`, `focus-window`, `focus-panel`, `select-workspace`, `next-window`/`previous-window`/`last-window`.

    Create a split without touching focus:

    ```bash
    programa new-split right                        # split the current pane
    programa new-split down --workspace workspace:2  # split in a different workspace
    ```

    Text output is `OK surface:6 workspace:2` — the new surface's handle. Send it a command without focusing it:

    ```bash
    result=$(programa new-split right)
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

    ## Reading output from a sibling pane

    `read-screen` (alias `capture-pane`, for tmux muscle memory) returns terminal text as plain text — the visible viewport by default, or scrollback on request:

    ```bash
    programa read-screen --surface "$handle"                          # visible viewport
    programa read-screen --surface "$handle" --scrollback --lines 200 # last 200 lines of scrollback
    ```

    Use this to check a build log, a test runner, or another agent's output without switching to its pane. Treat a single read as a snapshot, not a completion signal — poll it (see "Waiting" below) if you need to know when something finishes.

    ## Spawning a helper agent and coordinating with it

    When the `agent_spawn` tool is available, use it for helper agents. It opens the helper as a nested workspace under the current workspace, keeps the same folder, and does not move the user's focus. Set `needs_isolation` only when the helper will make conflicting Git changes and genuinely needs a separate worktree. Programa then shows the helper in Agent Overview automatically.

    Use a split for a long-running shell command, or as a fallback when `agent_spawn` is unavailable. Launch the command with `send`, then treat it like any other sibling pane: read its output, send follow-up input, and report through the sidebar instead of the pane the user isn't looking at.

    ```bash
    # 1. Split and capture the new surface's handle
    result=$(programa new-split right)
    handle=$(echo "$result" | awk '{print $2}')

    # 2. Launch the helper agent in it
    programa send --surface "$handle" "claude 'fix the failing test in foo_test.go'\n"

    # 3. Check on it later without focusing it
    programa read-screen --surface "$handle" --scrollback --lines 100

    # 4. Answer it if it's waiting on you
    programa send --surface "$handle" "yes\n"
    ```

    Surface status through the sidebar and native notifications rather than only printing to your own pane:

    ```bash
    programa set-status build "compiling" --icon hammer --color "#ff9500"
    programa notify --title "Helper agent done" --body "Tests pass, ready for review" --surface "$handle"
    ```

    `set-status` writes a pill into the sidebar tab row — use a unique key per tool (`build`, `claude_code`, ...) so entries don't collide. `notify` fires a native notification and lights up programa's unread ring/tab indicator for that surface.

    ## Waiting on a server, a test run, or another agent

    `wait-surface` blocks server-side until a surface's output matches a regex or its process exits, so you don't have to poll:

    ```bash
    # Block until the build in a sibling pane finishes, up to 2 minutes
    programa wait-surface --surface "$handle" --pattern 'BUILD (SUCCEEDED|FAILED)' --timeout 120

    # Block until the process in a surface exits
    programa wait-surface --surface "$handle" --exit --timeout 600
    ```

    Exactly one of `--pattern <regex>` or `--exit` is required. Match on whatever the process actually prints ("PASS", "Server started", a prompt returning), not a fixed sleep duration. The wait is answered by the app the moment the condition is met — there is no missed-event window even if the output appears while the call is being issued.

    `wait-surface` also has a third condition, `--agent-state <idle|working|blocked|any_change>`, for a sibling pane running another agent whose lifecycle hooks report status automatically (Claude Code/Codex/OpenCode installs wire this up for you, no extra setup) — block on what the agent is *doing*, not what it prints:

    ```bash
    # Block until the agent in the helper pane goes idle (or has no state at all -- see below)
    programa wait-surface --surface "$handle" --agent-state idle --timeout 300

    # Block until it flags something it needs you for
    programa wait-surface --surface "$handle" --agent-state blocked --timeout 300
    ```

    A surface that has never reported any state counts as idle for `--agent-state idle` (most panes have no agent hooks installed, and "idle" almost always means "not currently busy" — which is true of a bare terminal too). `blocked`/`working` require an actual report; there's nothing to observe otherwise.

    For two cooperating processes, `wait-for` (tmux-compatible) gives you a named rendezvous instead of scraping a log — one side signals, the other blocks until it does:

    ```bash
    # In the helper agent's pane, once it's done:
    programa wait-for -S build-complete

    # In the coordinating agent:
    programa wait-for build-complete --timeout 120
    ```

    This is a filesystem-based signal, not a verdict on *why* the other side signaled — pair it with a `read-screen` check if you need to confirm success vs. failure.

    ## Prompting a helper agent and waiting for it, in one call

    `prompt-agent` combines "send a prompt" and "wait for it to finish" into a single request — for the common case of the coordinating loop in "Spawning a helper agent" above:

    ```bash
    programa prompt-agent --surface "$handle" --timeout 300 "fix the failing test in foo_test.go"
    ```

    It sends the text, waits (briefly) for the helper to report it started working, then waits for it to go idle again. If the helper never reports any activity at all, the JSON response carries a `warning` noting its hooks may not be installed, rather than hanging or failing outright — check that field if `prompt-agent` returns suspiciously fast.

    ## Reference

    - `--workspace`/`--surface`/`--pane`/`--window` accept either a short ref (`workspace:2`, `surface:4`) or a raw UUID; omitted, they default to `$PROGRAMA_WORKSPACE_ID`/`$PROGRAMA_SURFACE_ID`.
    - `--json` and `--id-format <refs|uuids|both>` are global flags and go before the subcommand: `programa --json tree`, `programa --id-format both list-panes`.
    - Full command list: `programa help`.
    - Anything not wrapped by a dedicated subcommand is reachable directly: `programa rpc <method> [json-params]` calls any socket API method.
    - `watch-events` streams a live feed of agent-state/output/workspace events over one long-lived connection — it's for dashboards and orchestrators watching many surfaces at once, not for a normal agent loop; use `wait-surface`/`prompt-agent` for "wait for one thing" instead.
    - Longer walkthrough and the full socket API reference: `docs/agent-skill.md` and `docs/v2-api-migration.md` in the programa repo.
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

    /// Resolves the target settings.json, respecting Claude Code's own
    /// CLAUDE_CONFIG_DIR override.
    private static func claudeSettingsPath() -> String {
        if let override = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            let expanded = NSString(string: override).expandingTildeInPath
            return (expanded as NSString).appendingPathComponent("settings.json")
        }
        return NSString(string: "~/.claude/settings.json").expandingTildeInPath
    }

    func runClaudeInstallIntegration() throws {
        let skipConfirm = ProcessInfo.processInfo.arguments.contains("--yes")
            || ProcessInfo.processInfo.arguments.contains("-y")
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

        var hooks = existing["hooks"] as? [String: Any] ?? [:]
        let programaHooks = Self.claudeHooksPayload
        for (eventName, programaGroups) in programaHooks {
            guard let programaGroupArray = programaGroups as? [[String: Any]] else { continue }
            var eventGroups = hooks[eventName] as? [[String: Any]] ?? []
            eventGroups.removeAll { group in
                guard let groupHooks = group["hooks"] as? [[String: Any]] else { return false }
                return groupHooks.allSatisfy { hook in
                    (hook["command"] as? String)?.contains(Self.claudeHookCommandMarker) == true
                }
            }
            eventGroups.append(contentsOf: programaGroupArray)
            hooks[eventName] = eventGroups
        }
        existing["hooks"] = hooks

        let newJsonData = try JSONSerialization.data(withJSONObject: existing, options: [.prettyPrinted, .sortedKeys])
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

        if !skipConfirm {
            print("Apply these changes? [Y/n] ", terminator: "")
            if let response = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
               !response.isEmpty && response != "y" && response != "yes" {
                print("Aborted.")
                return
            }
        }

        if settingsChanged {
            try newJsonData.write(to: URL(fileURLWithPath: settingsPath), options: .atomic)
        }
        if skillState.changed {
            try writeAgentSkillFile(path: skillPath)
        }

        print("")
        print("Installed. The Claude Code integration now works from any terminal, not just programa's.")
        print("To remove: programa claude uninstall-integration")
    }

    func runClaudeUninstallIntegration() throws {
        let skipConfirm = ProcessInfo.processInfo.arguments.contains("--yes")
            || ProcessInfo.processInfo.arguments.contains("-y")
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
                guard var eventGroups = hooks[eventName] as? [[String: Any]] else { continue }
                let before = eventGroups.count
                eventGroups.removeAll { group in
                    guard let groupHooks = group["hooks"] as? [[String: Any]] else { return false }
                    return groupHooks.allSatisfy { hook in
                        (hook["command"] as? String)?.contains(Self.claudeHookCommandMarker) == true
                    }
                }
                removedCount += before - eventGroups.count
                if eventGroups.isEmpty {
                    hooks.removeValue(forKey: eventName)
                } else {
                    hooks[eventName] = eventGroups
                }
            }
            if removedCount > 0 {
                parsed["hooks"] = hooks
                let newJsonData = try JSONSerialization.data(withJSONObject: parsed, options: [.prettyPrinted, .sortedKeys])
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

        if !skipConfirm {
            print("Apply these changes? [Y/n] ", terminator: "")
            if let response = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
               !response.isEmpty && response != "y" && response != "yes" {
                print("Aborted.")
                return
            }
        }

        if let hooksRemoval {
            try hooksRemoval.newJsonData.write(to: URL(fileURLWithPath: settingsPath), options: .atomic)
        }
        if skillContent != nil {
            try removeAgentSkillFileIfManaged(path: skillPath)
        }
        print("Removed programa Claude Code integration.")
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

    /// Codex hook handler. Gracefully no-ops when not running inside programa.
    func runCodexHook(
        commandArgs: [String],
        client: SocketClient
    ) throws {
        let env = ProcessInfo.processInfo.environment

        // Graceful no-op: if not inside programa, exit silently with valid JSON
        guard env["PROGRAMA_SURFACE_ID"] != nil else {
            print("{}")
            return
        }

        let subcommand = commandArgs.first?.lowercased() ?? "help"
        let hookArgs = Array(commandArgs.dropFirst())
        let hookWsFlag = optionValue(hookArgs, name: "--workspace")
        let workspaceArg = hookWsFlag ?? env["PROGRAMA_WORKSPACE_ID"]
        let surfaceArg = optionValue(hookArgs, name: "--surface") ?? (hookWsFlag == nil ? env["PROGRAMA_SURFACE_ID"] : nil)
        let rawInput = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let parsedInput = parseClaudeHookInput(rawInput: rawInput)
        let sessionStore = ClaudeHookSessionStore(
            processEnv: env.merging(
                ["PROGRAMA_CLAUDE_HOOK_STATE_PATH": "~/.programa/codex-hook-sessions.json"],
                uniquingKeysWith: { _, new in new }
            )
        )

        switch subcommand {
        case "session-start":
            // Wrapped in do/catch like "stop": a Programa quit mid-session must
            // not block the agent's next hook invocation on a dead socket.
            do {
                let workspaceId = try resolvePreferredWorkspaceIdForClaudeHook(
                    preferred: nil,
                    fallback: workspaceArg,
                    client: client
                )
                let surfaceId = try resolvePreferredSurfaceIdForClaudeHook(
                    preferred: nil,
                    fallback: surfaceArg,
                    workspaceId: workspaceId,
                    client: client
                )
                let agentPIDKey = codexAgentPIDKey(sessionId: parsedInput.sessionId)
                let codexPid = inferredCodexAgentPID()
                if let sessionId = parsedInput.sessionId {
                    try? sessionStore.upsert(
                        sessionId: sessionId,
                        workspaceId: workspaceId,
                        surfaceId: surfaceId,
                        cwd: parsedInput.cwd,
                        pid: codexPid
                    )
                }
                if let codexPid {
                    _ = try? client.sendV2(method: "workspace.set_agent_pid", params: [
                        "workspace_id": workspaceId,
                        "key": agentPIDKey,
                        "pid": codexPid,
                    ])
                }
                print("{}")
            } catch {
                if shouldIgnoreClaudeHookTeardownError(error) {
                    print("{}")
                    return
                }
                throw error
            }

        case "prompt-submit":
            // Wrapped in do/catch like "stop": a Programa quit mid-session must
            // not block the agent's next prompt on a dead socket.
            do {
                let mappedSession = parsedInput.sessionId.flatMap { try? sessionStore.lookup(sessionId: $0) }
                let workspaceId = try resolvePreferredWorkspaceIdForClaudeHook(
                    preferred: mappedSession?.workspaceId,
                    fallback: workspaceArg,
                    client: client
                )
                let agentPIDKey = codexAgentPIDKey(sessionId: parsedInput.sessionId ?? mappedSession?.sessionId)
                let codexPid = mappedSession?.pid ?? inferredCodexAgentPID()
                if let sessionId = parsedInput.sessionId, let mappedSession {
                    try? sessionStore.upsert(
                        sessionId: sessionId,
                        workspaceId: workspaceId,
                        surfaceId: mappedSession.surfaceId,
                        cwd: parsedInput.cwd ?? mappedSession.cwd,
                        pid: codexPid
                    )
                }
                if let codexPid {
                    _ = try? client.sendV2(method: "workspace.set_agent_pid", params: [
                        "workspace_id": workspaceId,
                        "key": agentPIDKey,
                        "pid": codexPid,
                    ])
                }
                _ = try? client.sendV2(method: "notification.clear", params: ["workspace_id": workspaceId])
                try setCodexStatus(
                    client: client,
                    workspaceId: workspaceId,
                    value: "Running",
                    icon: "bolt.fill",
                    color: "#4C8DFF"
                )
                let promptSubmitSurfaceId = try resolvePreferredSurfaceIdForClaudeHook(
                    preferred: mappedSession?.surfaceId,
                    fallback: surfaceArg,
                    workspaceId: workspaceId,
                    client: client
                )
                reportAgentState(client: client, workspaceId: workspaceId, surfaceId: promptSubmitSurfaceId, state: .working)
                print("{}")
            } catch {
                if shouldIgnoreClaudeHookTeardownError(error) {
                    print("{}")
                    return
                }
                throw error
            }

        case "stop":
            do {
                let mappedSession = parsedInput.sessionId.flatMap { try? sessionStore.lookup(sessionId: $0) }
                let workspaceId = try resolvePreferredWorkspaceIdForClaudeHook(
                    preferred: mappedSession?.workspaceId,
                    fallback: workspaceArg,
                    client: client
                )
                let surfaceId = try resolvePreferredSurfaceIdForClaudeHook(
                    preferred: mappedSession?.surfaceId,
                    fallback: surfaceArg,
                    workspaceId: workspaceId,
                    client: client
                )
                let agentPIDKey = codexAgentPIDKey(sessionId: parsedInput.sessionId ?? mappedSession?.sessionId)

                // Build completion notification from Codex stop payload
                let lastMessage = parsedInput.object?["last_assistant_message"] as? String
                    ?? parsedInput.object?["lastAssistantMessage"] as? String
                let cwd = parsedInput.cwd ?? mappedSession?.cwd
                let codexPid = mappedSession?.pid ?? inferredCodexAgentPID()
                let projectName: String? = {
                    guard let cwd, !cwd.isEmpty else { return nil }
                    return URL(fileURLWithPath: NSString(string: cwd).expandingTildeInPath).lastPathComponent
                }()

                if let sessionId = parsedInput.sessionId {
                    try? sessionStore.upsert(
                        sessionId: sessionId,
                        workspaceId: workspaceId,
                        surfaceId: surfaceId,
                        cwd: cwd,
                        pid: codexPid,
                        lastSubtitle: "Completed",
                        lastBody: lastMessage.map { truncate($0, maxLength: 200) }
                    )
                }
                if let codexPid {
                    _ = try? client.sendV2(method: "workspace.set_agent_pid", params: [
                        "workspace_id": workspaceId,
                        "key": agentPIDKey,
                        "pid": codexPid,
                    ])
                }

                // Send completion notification
                var subtitle = "Completed"
                if let projectName, !projectName.isEmpty {
                    subtitle = "Completed in \(projectName)"
                }
                let body = sanitizeNotificationField(
                    lastMessage.map { truncate(normalizedSingleLine($0), maxLength: 200) }
                        ?? "Codex session completed"
                )
                _ = try? client.sendV2(method: "notification.create_for_target", params: [
                    "workspace_id": workspaceId,
                    "surface_id": surfaceId,
                    "title": "Codex",
                    "subtitle": sanitizeNotificationField(subtitle),
                    "body": body,
                ])

                try? setCodexStatus(
                    client: client,
                    workspaceId: workspaceId,
                    value: "Idle",
                    icon: "pause.circle.fill",
                    color: "#8E8E93"
                )
                reportAgentState(client: client, workspaceId: workspaceId, surfaceId: surfaceId, state: .idle)
                print("{}")
            } catch {
                if shouldIgnoreClaudeHookTeardownError(error) {
                    print("{}")
                    return
                }
                throw error
            }

        case "notification", "notify":
            var summary = summarizeCodexHookNotification(parsedInput: parsedInput)

            let mappedSession = parsedInput.sessionId.flatMap { try? sessionStore.lookup(sessionId: $0) }
            let workspaceId = try resolvePreferredWorkspaceIdForClaudeHook(
                preferred: mappedSession?.workspaceId,
                fallback: workspaceArg,
                client: client
            )
            if let mappedSession,
               let savedBody = mappedSession.lastBody, !savedBody.isEmpty,
               summary.body.contains("needs your attention") || summary.body.contains("needs your input") {
                summary = (subtitle: mappedSession.lastSubtitle ?? summary.subtitle, body: savedBody)
            }

            let surfaceId = try resolvePreferredSurfaceIdForClaudeHook(
                preferred: mappedSession?.surfaceId,
                fallback: surfaceArg,
                workspaceId: workspaceId,
                client: client
            )
            let agentPIDKey = codexAgentPIDKey(sessionId: parsedInput.sessionId ?? mappedSession?.sessionId)
            let codexPid = mappedSession?.pid ?? inferredCodexAgentPID()

            let title = "Codex"
            let subtitle = sanitizeNotificationField(summary.subtitle)
            let body = sanitizeNotificationField(summary.body)

            if let sessionId = parsedInput.sessionId {
                try? sessionStore.upsert(
                    sessionId: sessionId,
                    workspaceId: workspaceId,
                    surfaceId: surfaceId,
                    cwd: parsedInput.cwd,
                    pid: codexPid,
                    lastSubtitle: summary.subtitle,
                    lastBody: summary.body
                )
            }
            if let codexPid {
                _ = try? client.sendV2(method: "workspace.set_agent_pid", params: [
                    "workspace_id": workspaceId,
                    "key": agentPIDKey,
                    "pid": codexPid,
                ])
            }

            _ = try? client.sendV2(method: "notification.create_for_target", params: [
                "workspace_id": workspaceId,
                "surface_id": surfaceId,
                "title": title,
                "subtitle": subtitle,
                "body": body,
            ])
            _ = try? setCodexStatus(
                client: client,
                workspaceId: workspaceId,
                value: "Needs input",
                icon: "bell.fill",
                color: "#4C8DFF"
            )
            reportAgentState(
                client: client,
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                state: agentStateForClassifiedNotificationSubtitle(summary.subtitle)
            )
            print("{}")

        case "session-end":
            // Final cleanup when Codex process exits (e.g. Ctrl+C or kill), covering
            // the case where Stop never fires. If Stop already consumed the session,
            // consumedSession is nil here and we skip to avoid wiping the completion
            // notification that Stop just delivered.
            let mappedSession = parsedInput.sessionId.flatMap { try? sessionStore.lookup(sessionId: $0) }
            let fallbackWorkspaceId = try? resolvePreferredWorkspaceIdForClaudeHook(
                preferred: mappedSession?.workspaceId,
                fallback: workspaceArg,
                client: client
            )
            let fallbackSurfaceId: String? = {
                guard let fallbackWorkspaceId else { return nil }
                return try? resolvePreferredSurfaceIdForClaudeHook(
                    preferred: mappedSession?.surfaceId,
                    fallback: surfaceArg,
                    workspaceId: fallbackWorkspaceId,
                    client: client
                )
            }()
            let consumedSession = try? sessionStore.consume(
                sessionId: parsedInput.sessionId,
                workspaceId: fallbackWorkspaceId,
                surfaceId: fallbackSurfaceId
            )
            if let consumedSession {
                let workspaceId = consumedSession.workspaceId
                let agentPIDKey = codexAgentPIDKey(sessionId: parsedInput.sessionId ?? consumedSession.sessionId)
                _ = try? clearCodexStatus(client: client, workspaceId: workspaceId)
                _ = try? client.sendV2(method: "workspace.clear_agent_pid", params: ["workspace_id": workspaceId, "key": agentPIDKey])
                _ = try? client.sendV2(method: "notification.clear", params: ["workspace_id": workspaceId])
                if !consumedSession.surfaceId.isEmpty {
                    clearAgentState(client: client, workspaceId: workspaceId, surfaceId: consumedSession.surfaceId)
                }
            }
            print("{}")

        case "help", "--help", "-h":
            print("programa codex-hook <session-start|prompt-submit|stop|notification|session-end> [--workspace <id>] [--surface <id>]")

        default:
            throw CLIError(message: "Unknown codex-hook subcommand: \(subcommand)")
        }
    }

    private func summarizeCodexHookNotification(parsedInput: ClaudeHookParsedInput) -> (subtitle: String, body: String) {
        guard let object = parsedInput.object else {
            if let fallback = parsedInput.rawFallback, !fallback.isEmpty {
                return classifyCodexNotification(signal: fallback, message: fallback)
            }
            return ("Waiting", "Codex is waiting for your input")
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
        let message = messageCandidates.compactMap { $0 }.first ?? "Codex needs your input"
        let normalizedMessage = normalizedSingleLine(message)
        let signal = signalParts.compactMap { $0 }.joined(separator: " ")
        var classified = classifyCodexNotification(signal: signal, message: normalizedMessage)

        classified.body = truncate(classified.body, maxLength: 180)
        return classified
    }

    private func classifyCodexNotification(signal: String, message: String) -> (subtitle: String, body: String) {
        let lower = "\(signal) \(message)".lowercased()
        if lower.contains("permission") || lower.contains("approve") || lower.contains("approval") || lower.contains("permission_prompt") {
            let body = message.isEmpty ? "Approval needed" : message
            return ("Permission", body)
        }
        if lower.contains("error") || lower.contains("failed") || lower.contains("exception") {
            let body = message.isEmpty ? "Codex reported an error" : message
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
        if !message.isEmpty, message != "Codex needs your input" {
            return ("Attention", message)
        }
        return ("Attention", "Codex needs your attention")
    }

    private func setCodexStatus(
        client: SocketClient,
        workspaceId: String,
        value: String,
        icon: String,
        color: String
    ) throws {
        _ = try client.sendV2(method: "workspace.set_status", params: [
            "workspace_id": workspaceId,
            "key": "codex",
            "value": value,
            "icon": icon,
            "color": color,
        ])
    }

    private func clearCodexStatus(client: SocketClient, workspaceId: String) throws {
        _ = try client.sendV2(method: "workspace.clear_status", params: ["workspace_id": workspaceId, "key": "codex"])
    }

    private func codexAgentPIDKey(sessionId: String?) -> String {
        guard let sessionId = sessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionId.isEmpty else {
            return "codex"
        }
        return "codex.\(sessionId)"
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

    private func parseOpenCodeHookInput(hookArgs: [String]) -> ClaudeHookParsedInput {
        let rawInput = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
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

    /// OpenCode plugin hook handler. Gracefully no-ops when not running inside programa.
    ///
    /// Unlike claude-hook/codex-hook, OpenCode has no shell-hook config to gate
    /// invocation on $PROGRAMA_SURFACE_ID — the local plugin (embedded as
    /// `openCodePluginJS` below) calls `programa opencode-hook <event> --cwd ... --session ...`
    /// directly via Bun's `$`, so this function carries its own guard, mirroring
    /// codex-hook's belt-and-suspenders pattern (also gated earlier in `run()` and
    /// `validateRegisteredArguments` before any socket connection is attempted).
    ///
    /// The plugin passes `--cwd`/`--session` as CLI args rather than stdin JSON;
    /// stdin is still read and tolerated (ignored if empty/absent) for parity with
    /// the other hook handlers and in case a richer payload is added later.
    ///
    /// session.idle and permission.asked can fire close together on OpenCode's event
    /// bus; the status/notification writes below are idempotent (same as
    /// claude-hook/codex-hook), so repeated firing is harmless.
    func runOpenCodeHook(
        commandArgs: [String],
        client: SocketClient
    ) throws {
        let env = ProcessInfo.processInfo.environment

        guard env["PROGRAMA_SURFACE_ID"] != nil else {
            print("{}")
            return
        }

        let subcommand = commandArgs.first?.lowercased() ?? "help"
        let hookArgs = Array(commandArgs.dropFirst())
        let hookWsFlag = optionValue(hookArgs, name: "--workspace")
        let workspaceArg = hookWsFlag ?? env["PROGRAMA_WORKSPACE_ID"]
        let surfaceArg = optionValue(hookArgs, name: "--surface") ?? (hookWsFlag == nil ? env["PROGRAMA_SURFACE_ID"] : nil)
        let parsedInput = parseOpenCodeHookInput(hookArgs: hookArgs)
        let sessionStore = ClaudeHookSessionStore(
            processEnv: env.merging(
                ["PROGRAMA_CLAUDE_HOOK_STATE_PATH": "~/.programa/opencode-hook-sessions.json"],
                uniquingKeysWith: { _, new in new }
            )
        )

        switch subcommand {
        case "session-start":
            // Wrapped in do/catch like "stop": a Programa quit mid-session must
            // not block the agent's next hook invocation on a dead socket.
            do {
                let workspaceId = try resolvePreferredWorkspaceIdForClaudeHook(
                    preferred: nil,
                    fallback: workspaceArg,
                    client: client
                )
                let surfaceId = try resolvePreferredSurfaceIdForClaudeHook(
                    preferred: nil,
                    fallback: surfaceArg,
                    workspaceId: workspaceId,
                    client: client
                )
                let agentPIDKey = opencodeAgentPIDKey(sessionId: parsedInput.sessionId)
                let opencodePid = inferredCodexAgentPID()
                if let sessionId = parsedInput.sessionId {
                    try? sessionStore.upsert(
                        sessionId: sessionId,
                        workspaceId: workspaceId,
                        surfaceId: surfaceId,
                        cwd: parsedInput.cwd,
                        pid: opencodePid
                    )
                }
                if let opencodePid {
                    _ = try? client.sendV2(method: "workspace.set_agent_pid", params: [
                        "workspace_id": workspaceId,
                        "key": agentPIDKey,
                        "pid": opencodePid,
                    ])
                }
                print("{}")
            } catch {
                if shouldIgnoreClaudeHookTeardownError(error) {
                    print("{}")
                    return
                }
                throw error
            }

        case "prompt-submit":
            // Wrapped in do/catch like "stop": a Programa quit mid-session must
            // not block the agent's next prompt on a dead socket.
            do {
                let mappedSession = parsedInput.sessionId.flatMap { try? sessionStore.lookup(sessionId: $0) }
                let workspaceId = try resolvePreferredWorkspaceIdForClaudeHook(
                    preferred: mappedSession?.workspaceId,
                    fallback: workspaceArg,
                    client: client
                )
                let agentPIDKey = opencodeAgentPIDKey(sessionId: parsedInput.sessionId ?? mappedSession?.sessionId)
                let opencodePid = mappedSession?.pid ?? inferredCodexAgentPID()
                if let sessionId = parsedInput.sessionId, let mappedSession {
                    try? sessionStore.upsert(
                        sessionId: sessionId,
                        workspaceId: workspaceId,
                        surfaceId: mappedSession.surfaceId,
                        cwd: parsedInput.cwd ?? mappedSession.cwd,
                        pid: opencodePid
                    )
                }
                if let opencodePid {
                    _ = try? client.sendV2(method: "workspace.set_agent_pid", params: [
                        "workspace_id": workspaceId,
                        "key": agentPIDKey,
                        "pid": opencodePid,
                    ])
                }
                _ = try? client.sendV2(method: "notification.clear", params: ["workspace_id": workspaceId])
                try setOpenCodeStatus(
                    client: client,
                    workspaceId: workspaceId,
                    value: "Running",
                    icon: "bolt.fill",
                    color: "#4C8DFF"
                )
                let promptSubmitSurfaceId = try resolvePreferredSurfaceIdForClaudeHook(
                    preferred: mappedSession?.surfaceId,
                    fallback: surfaceArg,
                    workspaceId: workspaceId,
                    client: client
                )
                reportAgentState(client: client, workspaceId: workspaceId, surfaceId: promptSubmitSurfaceId, state: .working)
                print("{}")
            } catch {
                if shouldIgnoreClaudeHookTeardownError(error) {
                    print("{}")
                    return
                }
                throw error
            }

        case "stop":
            do {
                let mappedSession = parsedInput.sessionId.flatMap { try? sessionStore.lookup(sessionId: $0) }
                let workspaceId = try resolvePreferredWorkspaceIdForClaudeHook(
                    preferred: mappedSession?.workspaceId,
                    fallback: workspaceArg,
                    client: client
                )
                let surfaceId = try resolvePreferredSurfaceIdForClaudeHook(
                    preferred: mappedSession?.surfaceId,
                    fallback: surfaceArg,
                    workspaceId: workspaceId,
                    client: client
                )
                let agentPIDKey = opencodeAgentPIDKey(sessionId: parsedInput.sessionId ?? mappedSession?.sessionId)
                let cwd = parsedInput.cwd ?? mappedSession?.cwd
                let opencodePid = mappedSession?.pid ?? inferredCodexAgentPID()
                let projectName: String? = {
                    guard let cwd, !cwd.isEmpty else { return nil }
                    return URL(fileURLWithPath: NSString(string: cwd).expandingTildeInPath).lastPathComponent
                }()
                // OpenCode's session.idle event carries no transcript/message payload
                // (unlike Claude/Codex Stop hooks), so the completion body stays generic
                // unless a future stdin JSON payload supplies one.
                let lastMessage = parsedInput.object.flatMap {
                    firstString(in: $0, keys: ["message", "last_assistant_message", "lastAssistantMessage", "body", "text"])
                }

                if let sessionId = parsedInput.sessionId {
                    try? sessionStore.upsert(
                        sessionId: sessionId,
                        workspaceId: workspaceId,
                        surfaceId: surfaceId,
                        cwd: cwd,
                        pid: opencodePid,
                        lastSubtitle: "Completed",
                        lastBody: lastMessage.map { truncate($0, maxLength: 200) }
                    )
                }
                if let opencodePid {
                    _ = try? client.sendV2(method: "workspace.set_agent_pid", params: [
                        "workspace_id": workspaceId,
                        "key": agentPIDKey,
                        "pid": opencodePid,
                    ])
                }

                var subtitle = "Completed"
                if let projectName, !projectName.isEmpty {
                    subtitle = "Completed in \(projectName)"
                }
                let body = sanitizeNotificationField(
                    lastMessage.map { truncate(normalizedSingleLine($0), maxLength: 200) }
                        ?? "OpenCode session completed"
                )
                _ = try? client.sendV2(method: "notification.create_for_target", params: [
                    "workspace_id": workspaceId,
                    "surface_id": surfaceId,
                    "title": "OpenCode",
                    "subtitle": sanitizeNotificationField(subtitle),
                    "body": body,
                ])

                try? setOpenCodeStatus(
                    client: client,
                    workspaceId: workspaceId,
                    value: "Idle",
                    icon: "pause.circle.fill",
                    color: "#8E8E93"
                )
                reportAgentState(client: client, workspaceId: workspaceId, surfaceId: surfaceId, state: .idle)
                print("{}")
            } catch {
                if shouldIgnoreClaudeHookTeardownError(error) {
                    print("{}")
                    return
                }
                throw error
            }

        case "notification", "notify":
            let mappedSession = parsedInput.sessionId.flatMap { try? sessionStore.lookup(sessionId: $0) }
            let workspaceId = try resolvePreferredWorkspaceIdForClaudeHook(
                preferred: mappedSession?.workspaceId,
                fallback: workspaceArg,
                client: client
            )
            let surfaceId = try resolvePreferredSurfaceIdForClaudeHook(
                preferred: mappedSession?.surfaceId,
                fallback: surfaceArg,
                workspaceId: workspaceId,
                client: client
            )
            let agentPIDKey = opencodeAgentPIDKey(sessionId: parsedInput.sessionId ?? mappedSession?.sessionId)
            let opencodePid = mappedSession?.pid ?? inferredCodexAgentPID()

            // permission.asked carries no message payload from the plugin either;
            // tolerate a stdin-supplied one for future-proofing, else use a generic message.
            let messageFromInput = parsedInput.object.flatMap {
                firstString(in: $0, keys: ["message", "body", "text", "reason", "description"])
            }
            let subtitle = "Attention"
            let body = messageFromInput.map { normalizedSingleLine($0) } ?? "OpenCode needs your attention"

            if let sessionId = parsedInput.sessionId {
                try? sessionStore.upsert(
                    sessionId: sessionId,
                    workspaceId: workspaceId,
                    surfaceId: surfaceId,
                    cwd: parsedInput.cwd,
                    pid: opencodePid,
                    lastSubtitle: subtitle,
                    lastBody: body
                )
            }
            if let opencodePid {
                _ = try? client.sendV2(method: "workspace.set_agent_pid", params: [
                    "workspace_id": workspaceId,
                    "key": agentPIDKey,
                    "pid": opencodePid,
                ])
            }

            _ = try? client.sendV2(method: "notification.create_for_target", params: [
                "workspace_id": workspaceId,
                "surface_id": surfaceId,
                "title": "OpenCode",
                "subtitle": sanitizeNotificationField(subtitle),
                "body": sanitizeNotificationField(body),
            ])
            _ = try? setOpenCodeStatus(
                client: client,
                workspaceId: workspaceId,
                value: "Needs input",
                icon: "bell.fill",
                color: "#4C8DFF"
            )
            // OpenCode's notification hook is only ever invoked for permission.asked (see
            // openCodePluginJS below) — unlike Claude/Codex, there's no ambiguous "Attention"
            // catch-all to classify, so this is unconditionally a blocking approval prompt.
            reportAgentState(client: client, workspaceId: workspaceId, surfaceId: surfaceId, state: .blocked)
            print("{}")

        case "session-end":
            let mappedSession = parsedInput.sessionId.flatMap { try? sessionStore.lookup(sessionId: $0) }
            let fallbackWorkspaceId = try? resolvePreferredWorkspaceIdForClaudeHook(
                preferred: mappedSession?.workspaceId,
                fallback: workspaceArg,
                client: client
            )
            let fallbackSurfaceId: String? = {
                guard let fallbackWorkspaceId else { return nil }
                return try? resolvePreferredSurfaceIdForClaudeHook(
                    preferred: mappedSession?.surfaceId,
                    fallback: surfaceArg,
                    workspaceId: fallbackWorkspaceId,
                    client: client
                )
            }()
            let consumedSession = try? sessionStore.consume(
                sessionId: parsedInput.sessionId,
                workspaceId: fallbackWorkspaceId,
                surfaceId: fallbackSurfaceId
            )
            if let consumedSession {
                let workspaceId = consumedSession.workspaceId
                let agentPIDKey = opencodeAgentPIDKey(sessionId: parsedInput.sessionId ?? consumedSession.sessionId)
                _ = try? clearOpenCodeStatus(client: client, workspaceId: workspaceId)
                _ = try? client.sendV2(method: "workspace.clear_agent_pid", params: ["workspace_id": workspaceId, "key": agentPIDKey])
                _ = try? client.sendV2(method: "notification.clear", params: ["workspace_id": workspaceId])
                if !consumedSession.surfaceId.isEmpty {
                    clearAgentState(client: client, workspaceId: workspaceId, surfaceId: consumedSession.surfaceId)
                }
            }
            print("{}")

        case "help", "--help", "-h":
            print("programa opencode-hook <session-start|prompt-submit|stop|notification|session-end> [--cwd <path>] [--session <id>] [--workspace <id>] [--surface <id>]")

        default:
            throw CLIError(message: "Unknown opencode-hook subcommand: \(subcommand)")
        }
    }

    private func setOpenCodeStatus(
        client: SocketClient,
        workspaceId: String,
        value: String,
        icon: String,
        color: String
    ) throws {
        _ = try client.sendV2(method: "workspace.set_status", params: [
            "workspace_id": workspaceId,
            "key": "opencode",
            "value": value,
            "icon": icon,
            "color": color,
        ])
    }

    private func clearOpenCodeStatus(client: SocketClient, workspaceId: String) throws {
        _ = try client.sendV2(method: "workspace.clear_status", params: ["workspace_id": workspaceId, "key": "opencode"])
    }

    private func opencodeAgentPIDKey(sessionId: String?) -> String {
        guard let sessionId = sessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionId.isEmpty else {
            return "opencode"
        }
        return "opencode.\(sessionId)"
    }

    /// The local OpenCode plugin programa installs into
    /// ~/.config/opencode/plugins/programa.js (or $OPENCODE_CONFIG_DIR/plugins/programa.js).
    ///
    /// OpenCode has no shell-hook config (unlike Claude Code/Codex): local plugin
    /// files under plugins/ auto-load with no opencode.json edit and no npm install.
    /// The exported function runs once at process boot (`{ directory, worktree, $ }`,
    /// Bun's `$`) and returns the lifecycle hooks object. `.quiet().nothrow()` on
    /// every `$` call is load-bearing — Bun's `$` throws on non-zero exit by default,
    /// and a programa CLI hiccup must never crash the user's opencode session.
    private static let openCodePluginJS: String = {
        """
        // Programa integration for OpenCode. Managed by `programa opencode install-integration`.
        export const ProgramaPlugin = async ({ directory, worktree, $ }) => {
          const hook = (event, extra = []) =>
            $`programa opencode-hook ${event} --cwd ${directory} ${extra}`.quiet().nothrow()
          await hook("session-start")
          return {
            "chat.message": async (input) => {
              await hook("prompt-submit", ["--session", input?.sessionID ?? ""])
            },
            event: async ({ event }) => {
              if (event?.type === "session.idle") await hook("stop", ["--session", event.properties?.sessionID ?? ""])
              if (event?.type === "permission.asked") await hook("notification", ["--session", event.properties?.sessionID ?? ""])
            },
            dispose: async () => { await hook("session-end") },
          }
        }
        """ + "\n"
    }()

    /// Identifier used to detect programa-owned plugin files during uninstall.
    private static let openCodePluginMarker = "Managed by `programa opencode install-integration`"

    /// Resolves the target plugins directory, respecting OpenCode's own
    /// OPENCODE_CONFIG_DIR override.
    private static func openCodePluginsDir() -> String {
        if let override = ProcessInfo.processInfo.environment["OPENCODE_CONFIG_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            let expanded = NSString(string: override).expandingTildeInPath
            return (expanded as NSString).appendingPathComponent("plugins")
        }
        return NSString(string: "~/.config/opencode/plugins").expandingTildeInPath
    }

    /// Resolves the target skills directory, respecting the same
    /// OPENCODE_CONFIG_DIR override as `openCodePluginsDir()`. OpenCode also
    /// discovers skills globally from `~/.claude/skills` and
    /// `~/.agents/skills` (installed by the Claude/Codex integrations above),
    /// so this mainly matters when a user runs only `programa opencode
    /// install-integration` and/or sets OPENCODE_CONFIG_DIR.
    private static func openCodeSkillsDir() -> String {
        if let override = ProcessInfo.processInfo.environment["OPENCODE_CONFIG_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            let expanded = NSString(string: override).expandingTildeInPath
            return (expanded as NSString).appendingPathComponent("skills")
        }
        return NSString(string: "~/.config/opencode/skills").expandingTildeInPath
    }

    func runOpenCodeInstallIntegration() throws {
        let skipConfirm = ProcessInfo.processInfo.arguments.contains("--yes")
            || ProcessInfo.processInfo.arguments.contains("-y")
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

        if !pluginChanged && !skillState.changed {
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

        if !skipConfirm {
            print("Apply these changes? [Y/n] ", terminator: "")
            if let response = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
               !response.isEmpty && response != "y" && response != "yes" {
                print("Aborted.")
                return
            }
        }

        if pluginChanged {
            try newContent.write(toFile: pluginPath, atomically: true, encoding: .utf8)
        }
        if skillState.changed {
            try writeAgentSkillFile(path: skillPath)
        }

        print("")
        print("Installed. OpenCode picks up local plugins automatically — no opencode.json edit or npm install needed.")
        print("To remove: programa opencode uninstall-integration")
    }

    func runOpenCodeUninstallIntegration() throws {
        let skipConfirm = ProcessInfo.processInfo.arguments.contains("--yes")
            || ProcessInfo.processInfo.arguments.contains("-y")
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

        if existingPluginContent == nil && skillContent == nil {
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

        if !skipConfirm {
            print("Apply these changes? [Y/n] ", terminator: "")
            if let response = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
               !response.isEmpty && response != "y" && response != "yes" {
                print("Aborted.")
                return
            }
        }

        if existingPluginContent != nil {
            try fm.removeItem(atPath: pluginPath)
        }
        if skillContent != nil {
            try removeAgentSkillFileIfManaged(path: skillPath)
        }
        print("Removed programa OpenCode integration.")
    }

}
