import Foundation
import CryptoKit
import Darwin
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
        let parentURL = stateURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true, attributes: nil)
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
                print("OK")
            } catch {
                if shouldIgnoreClaudeHookTeardownError(error) {
                    print("OK")
                    return
                }
                throw error
            }

        case "prompt-submit":
            let mappedSession = parsedInput.sessionId.flatMap { try? sessionStore.lookup(sessionId: $0) }
            let workspaceId = try resolvePreferredWorkspaceIdForClaudeHook(
                preferred: mappedSession?.workspaceId,
                fallback: workspaceArg,
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
            print("OK")

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
            print("OK")

        case "session-end":
            // Final cleanup when Claude process exits.
            // Only clear when we are the primary cleanup path (Stop didn't fire first).
            // If Stop already consumed the session, consumedSession is nil and we skip
            // to avoid wiping the completion notification that Stop just delivered.
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
            }
            print("OK")

        case "pre-tool-use":
            // Clears "Needs input" status and notification when Claude resumes work
            // (e.g. after permission grant). Runs async so it doesn't block tool execution.
            let mappedSession = parsedInput.sessionId.flatMap { try? sessionStore.lookup(sessionId: $0) }
            let workspaceId = try resolvePreferredWorkspaceIdForClaudeHook(
                preferred: mappedSession?.workspaceId,
                fallback: workspaceArg,
                client: client
            )
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
                programa claude-hook <session-start|stop|session-end|notification|prompt-submit|pre-tool-use> [--workspace <id|index>] [--surface <id|index>]
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
        case "tool_name", "event", "event_name", "hook_event_name", "type", "kind", "notification_type", "matcher", "reason":
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

    /// The hooks.json content that programa installs into ~/.codex/.
    /// Each hook calls `programa codex-hook <event>` which gracefully no-ops
    /// when not running inside programa. The command checks for programa on PATH
    /// first so it silently succeeds even when programa is not installed
    /// (e.g. user opened codex in a non-programa terminal).
    private static func codexHookCommand(_ event: String) -> String {
        "[ -n \"$PROGRAMA_SURFACE_ID\" ] && command -v programa >/dev/null 2>&1 && programa codex-hook \(event) || echo '{}'"
    }

    private static let codexHooksJSON: [String: Any] = [
        "hooks": [
            "SessionStart": [[
                "hooks": [[
                    "type": "command",
                    "command": codexHookCommand("session-start"),
                    "timeout": 10
                ] as [String: Any]]
            ] as [String: Any]],
            "UserPromptSubmit": [[
                "hooks": [[
                    "type": "command",
                    "command": codexHookCommand("prompt-submit"),
                    "timeout": 10
                ] as [String: Any]]
            ] as [String: Any]],
            "Stop": [[
                "hooks": [[
                    "type": "command",
                    "command": codexHookCommand("stop"),
                    "timeout": 10
                ] as [String: Any]]
            ] as [String: Any]],
            "Notification": [[
                "hooks": [[
                    "type": "command",
                    "command": codexHookCommand("notification"),
                    "timeout": 10
                ] as [String: Any]]
            ] as [String: Any]],
            "SessionEnd": [[
                "hooks": [[
                    "type": "command",
                    "command": codexHookCommand("session-end"),
                    "timeout": 1
                ] as [String: Any]]
            ] as [String: Any]]
        ] as [String: Any]
    ]

    /// Identifier used to detect programa-owned hooks during uninstall.
    private static let codexHookCommandMarker = "programa codex-hook"

    func runCodexInstallHooks() throws {
        let skipConfirm = ProcessInfo.processInfo.arguments.contains("--yes")
            || ProcessInfo.processInfo.arguments.contains("-y")
        let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
            ?? NSString(string: "~/.codex").expandingTildeInPath
        let hooksPath = (codexHome as NSString).appendingPathComponent("hooks.json")
        let configPath = (codexHome as NSString).appendingPathComponent("config.toml")
        let fm = FileManager.default

        // Ensure ~/.codex/ exists
        try fm.createDirectory(atPath: codexHome, withIntermediateDirectories: true, attributes: nil)

        // Read existing state
        let existingHooksContent: String? = fm.fileExists(atPath: hooksPath)
            ? (try? String(contentsOfFile: hooksPath, encoding: .utf8))
            : nil

        // Build merged hooks
        var existing: [String: Any] = [:]
        if let existingHooksContent,
           let data = existingHooksContent.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            existing = parsed
        }

        var hooks = existing["hooks"] as? [String: Any] ?? [:]
        let programaHooks = Self.codexHooksJSON["hooks"] as! [String: Any]
        for (eventName, programaGroups) in programaHooks {
            guard let programaGroupArray = programaGroups as? [[String: Any]] else { continue }
            var eventGroups = hooks[eventName] as? [[String: Any]] ?? []
            eventGroups.removeAll { group in
                guard let groupHooks = group["hooks"] as? [[String: Any]] else { return false }
                return groupHooks.allSatisfy { hook in
                    (hook["command"] as? String)?.contains(Self.codexHookCommandMarker) == true
                }
            }
            eventGroups.append(contentsOf: programaGroupArray)
            hooks[eventName] = eventGroups
        }
        existing["hooks"] = hooks
        let newJsonData = try JSONSerialization.data(withJSONObject: existing, options: [.prettyPrinted, .sortedKeys])
        let newHooksContent = String(data: newJsonData, encoding: .utf8) ?? ""

        // Build new config.toml content
        let existingConfigContent: String = fm.fileExists(atPath: configPath)
            ? ((try? String(contentsOfFile: configPath, encoding: .utf8)) ?? "")
            : ""
        let newConfigContent = buildConfigWithCodexHooks(existingConfigContent)

        // Check if anything would change
        let hooksChanged = existingHooksContent != newHooksContent
        let configChanged = existingConfigContent != newConfigContent

        // Also install the `programa` agent skill into $HOME/.agents/skills —
        // the user-level location Codex (and OpenCode) scan for skills — so a
        // fresh Codex session inside programa knows it can drive the app.
        // This is $HOME-relative, not $CODEX_HOME-relative: it's the shared
        // cross-tool ".agents/skills" convention, not a Codex-specific path.
        // Refs #165.
        let skillPath = Self.agentSkillFilePath(
            skillsRoot: NSString(string: "~/.agents/skills").expandingTildeInPath
        )
        let skillState = agentSkillInstallState(path: skillPath)

        if !hooksChanged && !configChanged && !skillState.changed {
            print("programa hooks are already installed. Nothing to change.")
            return
        }

        // Show diff and ask for confirmation
        if hooksChanged {
            print("  \(hooksPath):")
            if let existingHooksContent {
                printSimpleDiff(old: existingHooksContent, new: newHooksContent)
            } else {
                print("    (new file)")
                let lines = newHooksContent.components(separatedBy: "\n")
                for (i, line) in lines.enumerated() {
                    let lineLabel = String(format: "%3d", i + 1)
                    print("    \u{001B}[32m\(lineLabel) +\(line)\u{001B}[0m")
                }
            }
            print("")
        }

        if configChanged {
            print("  \(configPath):")
            if existingConfigContent.isEmpty {
                print("    (new file)")
                let lines = newConfigContent.components(separatedBy: "\n")
                for (i, line) in lines.enumerated() where !line.isEmpty {
                    let lineLabel = String(format: "%3d", i + 1)
                    print("    \u{001B}[32m\(lineLabel) +\(line)\u{001B}[0m")
                }
            } else {
                printSimpleDiff(old: existingConfigContent, new: newConfigContent)
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

        // Apply changes
        if hooksChanged {
            try newJsonData.write(to: URL(fileURLWithPath: hooksPath), options: .atomic)
        }
        if configChanged {
            try newConfigContent.write(toFile: configPath, atomically: true, encoding: .utf8)
        }
        if skillState.changed {
            try writeAgentSkillFile(path: skillPath)
        }

        print("")
        print("Installed. Hooks activate inside programa and silently no-op elsewhere.")
        print("To remove: programa codex uninstall-hooks")
    }

    func runCodexUninstallHooks() throws {
        let skipConfirm = ProcessInfo.processInfo.arguments.contains("--yes")
            || ProcessInfo.processInfo.arguments.contains("-y")
        let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
            ?? NSString(string: "~/.codex").expandingTildeInPath
        let hooksPath = (codexHome as NSString).appendingPathComponent("hooks.json")
        let configPath = (codexHome as NSString).appendingPathComponent("config.toml")
        let fm = FileManager.default

        // Hooks removal, computed as an optional so a missing/malformed
        // hooks.json doesn't short-circuit the skill-file cleanup below.
        var hooksRemoval: (newJsonData: Data, newHooksContent: String, oldHooksContent: String)?
        if fm.fileExists(atPath: hooksPath),
           let data = try? Data(contentsOf: URL(fileURLWithPath: hooksPath)),
           var parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           var hooks = parsed["hooks"] as? [String: Any] {
            var removedCount = 0
            for eventName in hooks.keys {
                guard var eventGroups = hooks[eventName] as? [[String: Any]] else { continue }
                let before = eventGroups.count
                eventGroups.removeAll { group in
                    guard let groupHooks = group["hooks"] as? [[String: Any]] else { return false }
                    return groupHooks.allSatisfy { hook in
                        (hook["command"] as? String)?.contains(Self.codexHookCommandMarker) == true
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
                let newHooksContent = String(data: newJsonData, encoding: .utf8) ?? ""
                let oldHooksContent = String(data: data, encoding: .utf8) ?? ""
                hooksRemoval = (newJsonData, newHooksContent, oldHooksContent)
            }
        }

        // Build config.toml without codex_hooks
        let existingConfigContent: String = fm.fileExists(atPath: configPath)
            ? ((try? String(contentsOfFile: configPath, encoding: .utf8)) ?? "")
            : ""
        let newConfigContent = buildConfigWithoutCodexHooks(existingConfigContent)
        let configChanged = existingConfigContent != newConfigContent

        let skillPath = Self.agentSkillFilePath(
            skillsRoot: NSString(string: "~/.agents/skills").expandingTildeInPath
        )
        let skillContent = agentSkillUninstallState(path: skillPath)

        if hooksRemoval == nil && !configChanged && skillContent == nil {
            print("No programa hooks found.")
            return
        }

        // Show diff and ask for confirmation
        if let hooksRemoval {
            print("  \(hooksPath):")
            printSimpleDiff(old: hooksRemoval.oldHooksContent, new: hooksRemoval.newHooksContent)
            print("")
        }

        if configChanged {
            print("  \(configPath):")
            printSimpleDiff(old: existingConfigContent, new: newConfigContent)
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
            try hooksRemoval.newJsonData.write(to: URL(fileURLWithPath: hooksPath), options: .atomic)
        }
        if configChanged {
            try newConfigContent.write(toFile: configPath, atomically: true, encoding: .utf8)
        }
        if skillContent != nil {
            try removeAgentSkillFileIfManaged(path: skillPath)
        }
        print("Removed programa Codex hooks.")
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

    Split a pane, launch an agent CLI into it with `send`, then treat it like any other sibling pane: read its output, send it follow-up input, report on it through the sidebar instead of the pane the user isn't looking at.

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

    There's no blocking "wait until this surface goes idle" primitive yet — poll for now:

    ```bash
    until programa read-screen --surface "$handle" --lines 1 | grep -q '\$ *$'; do
      sleep 2
    done
    ```

    Match on whatever the process actually prints ("PASS", "Server started", a prompt returning), not a fixed sleep duration.

    For two cooperating processes, `wait-for` (tmux-compatible) gives you a named rendezvous instead of scraping a log — one side signals, the other blocks until it does:

    ```bash
    # In the helper agent's pane, once it's done:
    programa wait-for -S build-complete

    # In the coordinating agent:
    programa wait-for build-complete --timeout 120
    ```

    This is a filesystem-based signal, not a verdict on *why* the other side signaled — pair it with a `read-screen` check if you need to confirm success vs. failure.

    A first-class "block until a surface's process changes state" primitive is planned but not shipped. Don't call `surface.wait` or `programa wait` today — they don't exist yet. Poll or use `wait-for` until that lands.

    ## Reference

    - `--workspace`/`--surface`/`--pane`/`--window` accept either a short ref (`workspace:2`, `surface:4`) or a raw UUID; omitted, they default to `$PROGRAMA_WORKSPACE_ID`/`$PROGRAMA_SURFACE_ID`.
    - `--json` and `--id-format <refs|uuids|both>` are global flags and go before the subcommand: `programa --json tree`, `programa --id-format both list-panes`.
    - Full command list: `programa help`.
    - Anything not wrapped by a dedicated subcommand is reachable directly: `programa rpc <method> [json-params]` calls any socket API method.
    - Longer walkthrough and the full socket API reference: `docs/agent-skill.md` and `docs/v2-api-migration.md` in the programa repo.

    """#

    /// Identifier used to detect programa-owned skill files during uninstall.
    private static let agentSkillMarker = "Installed and managed by `programa"

    /// Skill file path under a given skill-directory root (e.g. `~/.claude/skills`,
    /// `~/.agents/skills`, `$OPENCODE_CONFIG_DIR/skills`): `<root>/programa/SKILL.md`.
    private static func agentSkillFilePath(skillsRoot: String) -> String {
        (skillsRoot as NSString).appendingPathComponent("programa/SKILL.md")
    }

    /// Reads the agent skill file at `path` and compares it against the
    /// current `agentSkillMarkdown`, without printing anything. Mirrors the
    /// `hooksChanged`/`configChanged` pure-boolean checks in
    /// `runCodexInstallHooks` so callers can fold this into a single
    /// "anything changed?" check across multiple files before printing any
    /// diffs or asking for confirmation.
    private func agentSkillInstallState(path: String) -> (changed: Bool, existing: String?) {
        let fm = FileManager.default
        let existing: String? = fm.fileExists(atPath: path)
            ? (try? String(contentsOfFile: path, encoding: .utf8))
            : nil
        return (existing != Self.agentSkillMarkdown, existing)
    }

    /// Prints the agent skill file's diff, matching the format used for the
    /// caller's own primary-artifact diff (new-file listing vs. unified diff).
    private func printAgentSkillDiff(path: String, existing: String?) {
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
    private func writeAgentSkillFile(path: String) throws {
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
    private func agentSkillUninstallState(path: String) -> String? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path),
              let content = try? String(contentsOfFile: path, encoding: .utf8),
              content.contains(Self.agentSkillMarker) else {
            return nil
        }
        return content
    }

    private func printAgentSkillRemovalDiff(path: String, content: String) {
        print("  \(path):")
        printSimpleDiff(old: content, new: "")
        print("")
    }

    private func removeAgentSkillFileIfManaged(path: String) throws {
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

    /// The six lifecycle events the runtime wrapper's HOOKS_JSON injects
    /// (Resources/bin/claude:207), reproduced here for the persistent file.
    private static let claudeHookEventSpecs: [ClaudeHookEventSpec] = [
        ClaudeHookEventSpec(name: "SessionStart", event: "session-start", timeout: 10, isAsync: false),
        ClaudeHookEventSpec(name: "Stop", event: "stop", timeout: 10, isAsync: false),
        ClaudeHookEventSpec(name: "SessionEnd", event: "session-end", timeout: 1, isAsync: false),
        ClaudeHookEventSpec(name: "Notification", event: "notification", timeout: 10, isAsync: false),
        ClaudeHookEventSpec(name: "UserPromptSubmit", event: "prompt-submit", timeout: 10, isAsync: false),
        ClaudeHookEventSpec(name: "PreToolUse", event: "pre-tool-use", timeout: 5, isAsync: true)
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
    private func printSimpleDiff(old: String, new: String, contextLines: Int = 2) {
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

    /// Returns config.toml content with codex_hooks = true under [features].
    private func buildConfigWithCodexHooks(_ content: String) -> String {
        var lines = content.components(separatedBy: "\n")

        // Check if codex_hooks key already exists (exact key match at line start)
        if let idx = lines.firstIndex(where: { isTomlKey($0, key: "codex_hooks") }) {
            lines[idx] = "codex_hooks = true"
            return lines.joined(separator: "\n")
        }

        // Find [features] section and insert after it (first occurrence only)
        if let idx = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "[features]" }) {
            lines.insert("codex_hooks = true", at: idx + 1)
            return lines.joined(separator: "\n")
        }

        // No [features] section, append one
        var result = content
        if !result.isEmpty && !result.hasSuffix("\n") {
            result += "\n"
        }
        result += "\n[features]\ncodex_hooks = true\n"
        return result
    }

    /// Returns config.toml content with codex_hooks removed from [features].
    private func buildConfigWithoutCodexHooks(_ content: String) -> String {
        var lines = content.components(separatedBy: "\n")

        // Remove the codex_hooks line
        lines.removeAll { isTomlKey($0, key: "codex_hooks") }

        // If [features] section is now empty (only has the header, nothing before next section or EOF),
        // remove the header too
        if let idx = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "[features]" }) {
            let nextNonEmpty = lines[(idx + 1)...].firstIndex(where: {
                !$0.trimmingCharacters(in: .whitespaces).isEmpty
            })
            let sectionEmpty = nextNonEmpty == nil || lines[nextNonEmpty!].trimmingCharacters(in: .whitespaces).hasPrefix("[")
            if sectionEmpty {
                lines.remove(at: idx)
            }
        }

        return lines.joined(separator: "\n")
    }

    /// Check if a TOML line sets a specific key (ignoring comments and whitespace).
    private func isTomlKey(_ line: String, key: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("#") else { return false }
        guard trimmed.hasPrefix(key) else { return false }
        let rest = trimmed.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
        return rest.hasPrefix("=")
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

        case "prompt-submit":
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
            print("{}")

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
            print("{}")

        case "session-end":
            do {
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
                }
                print("{}")
            } catch {
                if shouldIgnoreClaudeHookTeardownError(error) {
                    print("{}")
                    return
                }
                throw error
            }

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

        case "prompt-submit":
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
            print("{}")

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
            print("{}")

        case "session-end":
            do {
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
                }
                print("{}")
            } catch {
                if shouldIgnoreClaudeHookTeardownError(error) {
                    print("{}")
                    return
                }
                throw error
            }

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

    /// Subcommand help text for Hooks commands, split out of the
    /// central `subcommandUsage` switch (programa.swift) so each domain's
    /// help text lives next to its command descriptors. Refs #101.
    func hooksSubcommandUsage(_ command: String) -> String? {
        switch command {
        case "claude-hook":
            return """
            Usage: programa claude-hook <session-start|active|stop|idle|notification|notify|prompt-submit> [flags]

            Hook for Claude Code integration. Reads JSON from stdin.

            Subcommands:
              session-start   Signal that a Claude session has started
              active          Alias for session-start
              stop            Signal that a Claude session has stopped
              idle            Alias for stop
              notification    Forward a Claude notification
              notify          Alias for notification
              prompt-submit   Clear notification and set Running on user prompt

            Flags:
              --workspace <id|ref>   Target workspace (default: $PROGRAMA_WORKSPACE_ID)
              --surface <id|ref>     Target surface (default: $PROGRAMA_SURFACE_ID)

            Example:
              echo '{"session_id":"abc"}' | programa claude-hook session-start
              echo '{}' | programa claude-hook stop
            """
        case "codex":
            return """
            Usage: programa codex <install-hooks|uninstall-hooks>

            Manage Codex CLI hooks integration.

            Subcommands:
              install-hooks     Install programa hooks into ~/.codex/hooks.json,
                                 plus the agent skill into ~/.agents/skills/programa/
              uninstall-hooks   Remove programa hooks from ~/.codex/hooks.json,
                                 plus the agent skill if programa-managed
            """
        case "codex-hook":
            return """
            Usage: programa codex-hook <session-start|prompt-submit|stop|notification|session-end> [flags]

            Hook for Codex CLI integration. Reads JSON from stdin.
            Gracefully no-ops when not running inside programa.

            Subcommands:
              session-start   Register a Codex session
              prompt-submit   Set Running status on user prompt
              stop            Send completion notification, set Idle
              notification    Send an attention-classified notification, set Needs input
              session-end     Final cleanup when the Codex process exits (Ctrl+C/kill)

            Flags:
              --workspace <id|ref>   Target workspace (default: $PROGRAMA_WORKSPACE_ID)
              --surface <id|ref>     Target surface (default: $PROGRAMA_SURFACE_ID)
            """
        case "opencode":
            return """
            Usage: programa opencode <install-integration|uninstall-integration>

            Manage Programa's OpenCode plugin integration.

            Subcommands:
              install-integration     Install programa's plugin into ~/.config/opencode/plugins/programa.js,
                                       plus the agent skill into ~/.config/opencode/skills/programa/
              uninstall-integration   Remove programa's plugin (refuses if you've customized the file),
                                       plus the agent skill if programa-managed
            """
        case "opencode-hook":
            return """
            Usage: programa opencode-hook <session-start|prompt-submit|stop|notification|session-end> [flags]

            Hook for the OpenCode plugin integration. Reads --cwd/--session flags passed
            by the plugin (stdin JSON is tolerated but not required). Gracefully no-ops
            when not running inside programa.

            Subcommands:
              session-start   Register an OpenCode session (plugin boot)
              prompt-submit   Set Running status on user prompt (chat.message)
              stop            Send completion notification, set Idle (session.idle)
              notification    Send an attention notification, set Needs input (permission.asked)
              session-end     Final cleanup when the OpenCode plugin disposes

            Flags:
              --cwd <path>           Working directory reported by the plugin
              --session <id>         OpenCode session id, when available
              --workspace <id|ref>   Target workspace (default: $PROGRAMA_WORKSPACE_ID)
              --surface <id|ref>     Target surface (default: $PROGRAMA_SURFACE_ID)
            """
        default:
            return nil
        }
    }

    /// Hook command descriptors, split out of the central
    /// `commandDescriptors()` array (programa.swift) so they live next to
    /// their implementation. Refs #101.
    func hooksDescriptors() -> [CommandDescriptor] {
        [
            CommandDescriptor(
                names: ["claude-hook"],
                helpLines: ["claude-hook <session-start|stop|notification> [--workspace <id|ref>] [--surface <id|ref>]"],
                execute: { ctx in
                    try self.runClaudeHook(commandArgs: ctx.commandArgs, client: ctx.client)
                }
            ),
            CommandDescriptor(
                names: ["codex-hook"],
                helpLines: [],
                execute: { ctx in
                    try self.runCodexHook(commandArgs: ctx.commandArgs, client: ctx.client)
                }
            ),
            CommandDescriptor(
                names: ["opencode-hook"],
                helpLines: [],
                execute: { ctx in
                    try self.runOpenCodeHook(commandArgs: ctx.commandArgs, client: ctx.client)
                }
            ),
        ]
    }
}
