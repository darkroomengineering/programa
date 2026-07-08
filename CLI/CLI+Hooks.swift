import Foundation
import CryptoKit
import Darwin
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
#if canImport(Security)
import Security
#endif

extension CMUXCLI {
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

        if !hooksChanged && !configChanged {
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

        guard fm.fileExists(atPath: hooksPath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: hooksPath)),
              var parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("No hooks.json found at \(hooksPath)")
            return
        }

        guard var hooks = parsed["hooks"] as? [String: Any] else {
            print("No hooks section found in \(hooksPath)")
            return
        }

        // Build the new state without programa hooks
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

        // Build config.toml without codex_hooks
        let existingConfigContent: String = fm.fileExists(atPath: configPath)
            ? ((try? String(contentsOfFile: configPath, encoding: .utf8)) ?? "")
            : ""
        let newConfigContent = buildConfigWithoutCodexHooks(existingConfigContent)
        let configChanged = existingConfigContent != newConfigContent

        if removedCount == 0 && !configChanged {
            print("No programa hooks found.")
            return
        }

        parsed["hooks"] = hooks
        let newJsonData = try JSONSerialization.data(withJSONObject: parsed, options: [.prettyPrinted, .sortedKeys])
        let newHooksContent = String(data: newJsonData, encoding: .utf8) ?? ""
        let oldHooksContent = String(data: data, encoding: .utf8) ?? ""

        // Show diff and ask for confirmation
        if removedCount > 0 {
            print("  \(hooksPath):")
            printSimpleDiff(old: oldHooksContent, new: newHooksContent)
            print("")
        }

        if configChanged {
            print("  \(configPath):")
            printSimpleDiff(old: existingConfigContent, new: newConfigContent)
            print("")
        }

        if !skipConfirm {
            print("Apply these changes? [Y/n] ", terminator: "")
            if let response = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
               !response.isEmpty && response != "y" && response != "yes" {
                print("Aborted.")
                return
            }
        }

        if removedCount > 0 {
            try newJsonData.write(to: URL(fileURLWithPath: hooksPath), options: .atomic)
        }
        if configChanged {
            try newConfigContent.write(toFile: configPath, atomically: true, encoding: .utf8)
        }
        print("Removed programa Codex hooks.")
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

        case "help", "--help", "-h":
            print("programa codex-hook <session-start|prompt-submit|stop> [--workspace <id>] [--surface <id>]")

        default:
            throw CLIError(message: "Unknown codex-hook subcommand: \(subcommand)")
        }
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
}
