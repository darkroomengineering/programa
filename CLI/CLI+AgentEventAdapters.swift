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
    /// and it is the one hook that ends a stop for input in both modes. It ends the stop only
    /// once no agent on the surface still has a permission request open (`claudeToolEndsStop`);
    /// while another agent's request is up it sends nothing. It must be synchronous: Claude waits
    /// for it before the next tool, so its report lands before that tool's permission prompt can.
    /// PreToolUse is async and could land after it, so it never resumes. A denied tool fires
    /// neither hook; that agent's next finished tool, the next UserPromptSubmit or the turn's Stop
    /// ends that stop.
    ///
    /// Without native status it reports the resume in full: the signed root `working` record,
    /// `working` and `item.completed`. While Claude reports its own status
    /// (which owns the badge), it tells only event routes the agent resumed. It resolves its
    /// target like the Notification hook, and clears notifications even without a surface.
    /// A helper's child record goes back to `working` here, not at its async PreToolUse, which
    /// could land after the helper's own prompt marked that record blocked.
    func runClaudePostToolUse(_ ctx: AgentHookContext) {
        if let sessionId = ctx.parsed.sessionId { try? ctx.store.clearPendingQuestion(sessionId: sessionId) }
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

    /// Claude Code's PermissionRequest: an agent's tool call waits on the user. It reports nothing
    /// (the Notification hook marks the stop); it records that this agent has a request open, so
    /// that no other agent's finished tool ends the stop while it is up. Claude's Notification
    /// carries no agent, and this hook is the one that names it. A later request from the same
    /// agent replaces its record: that agent's tools run one at a time, so the earlier request
    /// was already answered.
    func recordClaudePermissionRequest(rawInput: String) {
        guard let request = ClaudePermissionRequest(rawInput: rawInput),
              case .trusted(let directory) = ClaudePermissionRequest.openDirectory(create: true) else { return }
        defer { close(directory) }
        request.write(in: directory)
    }

    /// Whether a finished tool may end the surface's stop for input. The agent that ran it has
    /// moved past any request it raised (a denied tool fires no hook, so its next tool counts too),
    /// so its own record goes first. The stop then ends only if no agent still has a request open.
    /// With no records at all (an older Claude Code, a persistent install without the
    /// PermissionRequest hook, or no surface id) every finished tool ends it. A directory that
    /// fails its ownership checks holds the stop.
    func claudeToolEndsStop(rawInput: String) -> Bool {
        switch ClaudePermissionRequest.openDirectory(create: false) {
        case .missing:
            return true
        case .untrusted:
            return false
        case .trusted(let directory):
            defer { close(directory) }
            if let request = ClaudePermissionRequest(rawInput: rawInput) {
                unlinkat(directory, request.fileName, 0)
            }
            return ClaudePermissionRequest.recordNames(in: directory)?.isEmpty == true
        }
    }

    /// Claude Code's SubagentStop: the helper ended, so a request it raised, say for a tool the
    /// user denied, is no longer up. It only drops that record; the next finished tool decides
    /// whether the stop ends. Without an `agent_id` it drops nothing.
    func forgetClaudeSubagentPermissionRequest(rawInput: String) {
        guard let request = ClaudePermissionRequest(rawInput: rawInput), request.owner != "main",
              case .trusted(let directory) = ClaudePermissionRequest.openDirectory(create: false) else { return }
        defer { close(directory) }
        unlinkat(directory, request.fileName, 0)
    }

    /// The prompt, the turn or the session ended, so none of this session's requests is still
    /// up. Only the reporting session's records go: a nested `claude -p` in the same terminal
    /// must not drop its parent's.
    func forgetClaudePermissionRequests(rawInput: String) {
        guard let request = ClaudePermissionRequest(rawInput: rawInput),
              case .trusted(let directory) = ClaudePermissionRequest.openDirectory(create: false) else { return }
        defer { close(directory) }
        let prefix = ClaudePermissionRequest.sessionPrefix(request.sessionId)
        for name in ClaudePermissionRequest.recordNames(in: directory) ?? [] where name.hasPrefix(prefix) {
            unlinkat(directory, name, 0)
        }
    }
}

/// An open Claude Code permission request, kept as one small file per (session, agent) in a
/// per-surface directory under TMPDIR between the PermissionRequest hook and that agent's next
/// finished tool. Only file names are ever read back: `<session hash>-<session and agent hash>.json`.
/// The directory is trusted only when it is a real directory this user owns with no group or
/// other access, since its contents decide whether a stop for input ends.
struct ClaudePermissionRequest {
    let sessionId: String
    /// The payload's `agent_id` for a subagent, `main` for the main agent.
    let owner: String
    let toolName: String

    enum Directory {
        /// No surface id, or no request was ever recorded for the surface.
        case missing
        /// It exists but is not one this user's hook made; it holds the stop.
        case untrusted
        case trusted(Int32)
    }

    /// From a hook payload; nil when it is not a JSON object.
    init?(rawInput: String) {
        guard let data = rawInput.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        sessionId = object["session_id"] as? String ?? ""
        owner = (object["agent_id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "main"
        toolName = object["tool_name"] as? String ?? ""
    }

    private static func hexDigest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// The file name prefix all of one session's records share.
    static func sessionPrefix(_ sessionId: String) -> String { "\(hexDigest(sessionId))-" }

    var fileName: String { "\(Self.sessionPrefix(sessionId))\(Self.hexDigest("\(sessionId)\0\(owner)")).json" }

    /// `$TMPDIR/programa-claude-permission-<hash of PROGRAMA_SURFACE_ID>`; nil without a surface
    /// id. The id is hashed because it comes from the environment and names a path.
    static func directoryPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        guard let surface = environment["PROGRAMA_SURFACE_ID"], !surface.isEmpty else { return nil }
        let base = environment["TMPDIR"].flatMap { $0.isEmpty ? nil : $0 } ?? NSTemporaryDirectory()
        return (base as NSString).appendingPathComponent("programa-claude-permission-\(hexDigest(surface))")
    }

    /// Opens the surface's directory without following a symlink, and checks the opened
    /// directory itself, so the checks and every later `*at` call see the same directory.
    /// Only PermissionRequest creates it, and nothing removes it: removing it could make a
    /// concurrent request's write fail, which would end a stop early.
    static func openDirectory(create: Bool) -> Directory {
        guard let path = directoryPath() else { return .missing }
        if create, mkdir(path, 0o700) != 0, errno != EEXIST { return .untrusted }
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return errno == ENOENT ? .missing : .untrusted }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid(),
              (info.st_mode & 0o077) == 0 else {
            close(fd)
            return .untrusted
        }
        return .trusted(fd)
    }

    /// The record files in the directory, by name; temporary files are skipped. Nil when the
    /// directory cannot be listed, which callers treat as a request still open.
    static func recordNames(in directory: Int32) -> [String]? {
        let listing = dup(directory)
        guard listing >= 0 else { return nil }
        guard let stream = fdopendir(listing) else {
            close(listing)
            return nil
        }
        defer { closedir(stream) }
        rewinddir(stream)
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else { break }
            var raw = entry.pointee.d_name
            let length = Int(entry.pointee.d_namlen)
            let name = withUnsafeBytes(of: &raw) { String(decoding: $0.prefix(length), as: UTF8.self) }
            if name.hasSuffix(".json") { names.append(name) }
        }
        return errno == 0 ? names : nil
    }

    /// Writes a temporary 0600 file in the directory and renames it over this agent's record, so
    /// the record appears whole or not at all. Best-effort: a failure leaves no record.
    func write(in directory: Int32) {
        let fields = ["session_id": sessionId, "owner": owner, "tool_name": toolName]
        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) else { return }
        let temporary = "\(fileName).\(getpid()).\(UInt32.random(in: 0...UInt32.max)).tmp"
        let fd = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return }
        let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        close(fd)
        guard written == data.count, renameat(directory, temporary, directory, fileName) == 0 else {
            unlinkat(directory, temporary, 0)
            return
        }
    }
}
