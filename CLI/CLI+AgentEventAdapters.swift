import CryptoKit
import Foundation

/// Provider adapters that translate Claude Code, Codex, and OpenCode hook events into
/// normalized `agent.event` socket calls; call sites live in CLI+Hooks.swift.
extension ProgramaCLI {
    /// Reports a normalized `agent.event` (docs/plans/agent-events.md) alongside the
    /// existing three-state `surface.report_agent_state` calls in CLI+Hooks.swift.
    /// Best-effort like `reportAgentState`/`clearAgentState`: a hook must
    /// never fail the user's tool call because programa's socket is unreachable.
    func reportAgentEvent(
        client: SocketClient,
        provider: String,
        eventType: String,
        workspaceId: String,
        surfaceId: String,
        sessionId: String? = nil,
        pid: Int? = nil,
        transcriptPath: String? = nil
    ) {
        var params: [String: Any] = [
            "provider": provider,
            "event_type": eventType,
            "workspace_id": workspaceId,
            "surface_id": surfaceId,
        ]
        if let sessionId, !sessionId.isEmpty {
            params["session_id"] = sessionId
        }
        if let pid {
            params["pid"] = pid
        }
        if let transcriptPath, !transcriptPath.isEmpty {
            params["transcript_path"] = transcriptPath
        }
        _ = try? client.sendV2(method: V2MethodNames.agentEvent, params: params)
    }

    /// Reports a surface's agent activity state, then a matching `agent.event`, in that
    /// order, with the same workspace/surface ids -- combines the two adjacent calls a hook
    /// call site in CLI+Hooks.swift would otherwise make back-to-back: two socket
    /// sends, in that order, with the same arguments.
    func reportAgentStateAndEvent(
        client: SocketClient,
        provider: String,
        eventType: String,
        workspaceId: String,
        surfaceId: String,
        state: CLIAgentActivityState,
        sessionId: String? = nil,
        pid: Int? = nil,
        transcriptPath: String? = nil
    ) {
        switch eventType {
        case "turn.started", "item.started", "item.completed": emitProgramStatus(state: "working", app: provider)
        case "turn.completed": emitProgramStatus(state: "done", app: provider)
        default: break
        }
        reportAgentState(client: client, workspaceId: workspaceId, surfaceId: surfaceId, state: state, provider: provider, sessionId: sessionId, pid: pid)
        reportAgentEvent(
            client: client, provider: provider, eventType: eventType, workspaceId: workspaceId, surfaceId: surfaceId,
            sessionId: sessionId, pid: pid, transcriptPath: transcriptPath
        )
    }

    /// Claude Code's PostToolUse, and PostToolUseFailure for a tool that failed: a tool finished,
    /// and it is the one hook that ends a stop for input in both modes. While the surface has a
    /// recorded permission request, only the tool call that raised it ends the stop
    /// (`claudeToolEndsStop`); any other finished tool, a parallel helper's included, sends
    /// nothing. It must be synchronous: Claude waits for it before the next tool, so its report
    /// lands before that tool's permission prompt can. PreToolUse is async and could land after
    /// it, so it never resumes. A denied tool fires neither hook; the next turn's
    /// UserPromptSubmit or Stop ends that stop.
    ///
    /// Without native status it reports the resume in full: the signed root `working` record,
    /// `working` and `item.completed`. While Claude reports its own status
    /// (which owns the badge), it tells only event routes the agent resumed. It resolves its
    /// target like the Notification hook, and clears notifications even without a surface.
    /// A helper's child record goes back to `working` here, not at its async PreToolUse, which
    /// could land after the helper's own prompt marked that record blocked.
    func runClaudePostToolUse(_ ctx: AgentHookContext) {
        guard claudeToolEndsStop(rawInput: ctx.rawInput) else { return }
        emitClaudeSubagentStatus(ctx.parsed, scope: ctx.workspaceArg, state: "working")
        let client = ctx.client
        let session = ctx.parsed.sessionId.flatMap { ctx.store.lookup(sessionId: $0) }
        guard let workspaceId = try? resolvePreferredWorkspaceIdForClaudeHook(
            preferred: session?.workspaceId, fallback: ctx.workspaceArg, client: client
        ) else { return }
        defer { _ = try? client.sendV2(method: V2MethodNames.notificationClear, params: ["workspace_id": workspaceId]) }
        guard let surfaceId = try? resolvePreferredSurfaceIdForClaudeHook(
            preferred: session?.surfaceId, fallback: ctx.surfaceArg, workspaceId: workspaceId, client: client
        ) else { return }
        if claudeReportsOwnStatus {
            reportRouteOnlyWorking(
                client: ctx.client, provider: "claude-code", workspaceId: workspaceId, surfaceId: surfaceId,
                sessionId: ctx.parsed.sessionId, pid: session?.pid, resumed: true
            )
        } else {
            reportAgentStateAndEvent(
                client: ctx.client, provider: "claude-code", eventType: "item.completed", workspaceId: workspaceId,
                surfaceId: surfaceId, state: .working, sessionId: ctx.parsed.sessionId, pid: session?.pid
            )
        }
    }

    /// A `working` report with `route_only`: it moves what event routes see of the agent, never
    /// the badge, for a hook whose badge update the program's own status owns. `resumed` lets it
    /// end a stop for input; send it only from a hook that proves the prompt was answered.
    func reportRouteOnlyWorking(
        client: SocketClient,
        provider: String,
        workspaceId: String,
        surfaceId: String,
        sessionId: String? = nil,
        pid: Int? = nil,
        resumed: Bool = false
    ) {
        var flags: [String: Any] = ["route_only": true]
        if resumed { flags["resumed"] = true }
        reportWorking(
            client: client, provider: provider, workspaceId: workspaceId, surfaceId: surfaceId,
            sessionId: sessionId, pid: pid, flags: flags
        )
    }

    /// Claude Code's PreToolUse without native status: a `working` report with `resumed: false`.
    /// It keeps the liveness clock moving where the hooks own the badge (tmux, agent teams) but
    /// never ends a stop for input: the hook is async and can land after its own tool's prompt.
    func reportClaudePreToolUseWorking(
        client: SocketClient, workspaceId: String, surfaceId: String, sessionId: String?, pid: Int?
    ) {
        reportWorking(
            client: client, provider: "claude-code", workspaceId: workspaceId, surfaceId: surfaceId,
            sessionId: sessionId, pid: pid, flags: ["resumed": false]
        )
    }

    private func reportWorking(
        client: SocketClient,
        provider: String,
        workspaceId: String,
        surfaceId: String,
        sessionId: String?,
        pid: Int?,
        flags: [String: Any]
    ) {
        var params: [String: Any] = [
            "workspace_id": workspaceId,
            "surface_id": surfaceId,
            "state": CLIAgentActivityState.working.rawValue,
            "provider": provider,
        ]
        params.merge(flags) { _, flag in flag }
        if let sessionId, !sessionId.isEmpty { params["session_id"] = sessionId }
        if let pid { params["pid"] = pid }
        _ = try? client.sendV2(method: V2MethodNames.surfaceReportAgentState, params: params)
    }

    /// Sends `agent.needs_input` (docs/plans/agent-state-unification.md T2): one atomic
    /// socket call covering the `notification.create_for_target` +
    /// `workspace.set_status` "Needs input" + `surface.report_agent_state` trio a hook
    /// would otherwise send independently for the same "needs input" moment.
    func reportAgentNeedsInput(
        client: SocketClient,
        provider: String,
        workspaceId: String,
        surfaceId: String,
        title: String,
        subtitle: String,
        body: String,
        sessionId: String? = nil,
        pid: Int? = nil,
        kind: String
    ) {
        var params: [String: Any] = [
            "workspace_id": workspaceId,
            "surface_id": surfaceId,
            "provider": provider,
            "title": title,
            "subtitle": subtitle,
            "body": body,
            "kind": kind,
        ]
        if let sessionId, !sessionId.isEmpty { params["session_id"] = sessionId }
        if let pid { params["pid"] = pid }
        _ = try? client.sendV2(method: V2MethodNames.agentNeedsInput, params: params)
    }

    /// Reports the matching `agent.event`, then clears the surface's reported agent
    /// activity state, with the same workspace/surface ids. The event goes first because
    /// `session.exited` alone already clears the state and supervision record, so the one
    /// request that matters lands early when a hook runs under a tight time budget.
    func clearAgentStateAndReportEvent(
        client: SocketClient,
        provider: String,
        eventType: String,
        workspaceId: String,
        surfaceId: String,
        sessionId: String? = nil
    ) {
        emitProgramStatus(state: "clear")
        reportAgentEvent(client: client, provider: provider, eventType: eventType, workspaceId: workspaceId, surfaceId: surfaceId, sessionId: sessionId)
        clearAgentState(client: client, workspaceId: workspaceId, surfaceId: surfaceId)
    }

    /// Maps a classified notification subtitle ("Permission" / "Waiting") to the matching
    /// `agent.event` type. Shared by the Claude Code and Codex notification-hook call sites in CLI+Hooks.swift.
    func reportAgentEventForClassifiedNotificationSubtitle(
        client: SocketClient,
        provider: String,
        subtitle: String,
        workspaceId: String,
        surfaceId: String,
        sessionId: String?
    ) {
        switch subtitle {
        case "Permission":
            reportAgentEvent(client: client, provider: provider, eventType: "request.opened", workspaceId: workspaceId, surfaceId: surfaceId, sessionId: sessionId)
        case "Waiting":
            reportAgentEvent(client: client, provider: provider, eventType: "user-input.requested", workspaceId: workspaceId, surfaceId: surfaceId, sessionId: sessionId)
        default:
            break
        }
    }

    /// One call per classified provider notification (Claude Code and Codex share the
    /// "Permission"/"Waiting" classifier): a blocking subtitle becomes a single
    /// `agent.needs_input` (state + notification + supervision in one hop); anything else
    /// stays a plain notification with an idle state report. The matching `agent.event`
    /// follows in both cases.
    func reportClassifiedAgentNotification(
        client: SocketClient,
        provider: String,
        workspaceId: String,
        surfaceId: String,
        title: String,
        subtitle: String,
        body: String,
        classifiedSubtitle: String,
        sessionId: String?,
        pid: Int?
    ) {
        emitProgramStatusForNotification(app: provider, classifiedSubtitle: classifiedSubtitle, body: body)
        if agentStateForClassifiedNotificationSubtitle(classifiedSubtitle) == .blocked {
            reportAgentNeedsInput(
                client: client,
                provider: provider,
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                title: title,
                subtitle: subtitle,
                body: body,
                sessionId: sessionId,
                pid: pid,
                kind: classifiedSubtitle == "Permission" ? "permission" : "question"
            )
        } else {
            _ = try? client.sendV2(method: V2MethodNames.notificationCreateForTarget, params: [
                "workspace_id": workspaceId,
                "surface_id": surfaceId,
                "title": title,
                "subtitle": subtitle,
                "body": body,
            ])
            reportAgentState(
                client: client,
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                state: .idle,
                provider: provider,
                sessionId: sessionId,
                pid: pid
            )
        }
        reportAgentEventForClassifiedNotificationSubtitle(client: client, provider: provider, subtitle: classifiedSubtitle, workspaceId: workspaceId, surfaceId: surfaceId, sessionId: sessionId)
    }

    /// Claude Code's PermissionRequest: the tool call a permission stop waits on. It reports
    /// nothing (the Notification hook marks the stop); it records the call so that only its own
    /// PostToolUse ends the stop. Claude's Notification carries no agent or tool, and this hook
    /// is the one that names both. One record per surface: a later request replaces it.
    func recordClaudePermissionRequest(rawInput: String) {
        guard let path = ClaudePermissionRequestRecord.filePath(),
              let record = ClaudePermissionRequestRecord(rawInput: rawInput) else { return }
        record.write(to: path)
    }

    /// Whether a finished tool may end the surface's stop for input. With no recorded permission
    /// request (an older Claude Code, a persistent install without the PermissionRequest hook, or
    /// no surface id) every finished tool does. With one, only the call that raised
    /// it does, and that call consumes the record. Two identical calls (same agent, tool and
    /// input) cannot be told apart.
    func claudeToolEndsStop(rawInput: String) -> Bool {
        guard let path = ClaudePermissionRequestRecord.filePath() else { return true }
        switch ClaudePermissionRequestRecord.read(from: path) {
        case .absent:
            return true
        case .present(let recorded) where recorded == ClaudePermissionRequestRecord(rawInput: rawInput):
            unlink(path)
            return true
        case .present, .unreadable:
            return false
        }
    }

    /// The prompt, the turn or the session ended, so no recorded permission request is still up.
    func forgetClaudePermissionRequest() {
        if let path = ClaudePermissionRequestRecord.filePath() { unlink(path) }
    }
}

/// The permission request a Claude Code stop waits on, kept in a small per-surface file under
/// TMPDIR between the PermissionRequest hook and the PostToolUse hook that answers it. The file
/// is read as untrusted input: bounded, owner-only, and any parse failure counts as no match.
struct ClaudePermissionRequestRecord: Equatable {
    let sessionId: String
    /// The payload's `agent_id` for a subagent, `main` for the main agent.
    let owner: String
    let toolName: String
    /// SHA-256 of `tool_input` serialized with sorted keys.
    let inputDigest: String

    enum Stored: Equatable {
        case absent
        case present(ClaudePermissionRequestRecord)
        case unreadable
    }

    private static let maxFileBytes = 4096

    init(sessionId: String, owner: String, toolName: String, inputDigest: String) {
        self.sessionId = sessionId
        self.owner = owner
        self.toolName = toolName
        self.inputDigest = inputDigest
    }

    /// From a hook payload; nil when it is not a JSON object. The digest comes from the raw
    /// `tool_input`, not the compacted copy hooks parse, which truncates and drops fields.
    init?(rawInput: String) {
        guard let data = rawInput.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let agentId = object["agent_id"] as? String
        let toolName = object["tool_name"] as? String ?? ""
        // AskUserQuestion's input is left out: the user's answers may be merged into the input
        // its PostToolUse reports (not captured), and a mismatch would hold the stop until the
        // turn ends. An agent asks one question at a time, so the tool name suffices.
        let input: [Any] = toolName == "AskUserQuestion" ? [] : [object["tool_input"] ?? NSNull()]
        guard JSONSerialization.isValidJSONObject(input),
              let canonical = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]) else { return nil }
        self.init(
            sessionId: object["session_id"] as? String ?? "",
            owner: agentId.flatMap { $0.isEmpty ? nil : $0 } ?? "main",
            toolName: toolName,
            inputDigest: SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
        )
    }

    /// `$TMPDIR/programa-claude-permission-<hash of PROGRAMA_SURFACE_ID>.json`; nil without a
    /// surface id. The id is hashed because it comes from the environment and names a path.
    static func filePath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        guard let surface = environment["PROGRAMA_SURFACE_ID"], !surface.isEmpty else { return nil }
        let directory = environment["TMPDIR"].flatMap { $0.isEmpty ? nil : $0 } ?? NSTemporaryDirectory()
        let name = SHA256.hash(data: Data(surface.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return (directory as NSString).appendingPathComponent("programa-claude-permission-\(name).json")
    }

    /// Writes a temporary 0600 file beside `path` and renames it over `path`, so a reader sees
    /// the old record or the new one, never a partial one. Best-effort: a failure leaves no record.
    func write(to path: String) {
        let fields = ["session_id": sessionId, "owner": owner, "tool_name": toolName, "input_digest": inputDigest]
        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
              data.count <= Self.maxFileBytes else { return }
        let temporary = "\(path).\(getpid()).\(UInt32.random(in: 0...UInt32.max)).tmp"
        let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return }
        let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        close(fd)
        guard written == data.count, rename(temporary, path) == 0 else {
            unlink(temporary)
            return
        }
    }

    /// A missing file, a symlink, or a file another user owns counts as no record: none of them
    /// is one this user's hook wrote. A file of this user's that is not a valid record is
    /// `unreadable`, which matches no tool.
    static func read(from path: String) -> Stored {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return .absent }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == geteuid() else {
            return .absent
        }
        guard (info.st_mode & 0o077) == 0, Int(info.st_size) <= maxFileBytes else { return .unreadable }
        var buffer = [UInt8](repeating: 0, count: maxFileBytes + 1)
        let count = Darwin.read(fd, &buffer, buffer.count)
        guard count > 0, count <= maxFileBytes,
              let object = (try? JSONSerialization.jsonObject(with: Data(buffer.prefix(count)))) as? [String: Any],
              let sessionId = object["session_id"] as? String,
              let owner = object["owner"] as? String,
              let toolName = object["tool_name"] as? String,
              let inputDigest = object["input_digest"] as? String else { return .unreadable }
        return .present(Self(sessionId: sessionId, owner: owner, toolName: toolName, inputDigest: inputDigest))
    }
}
