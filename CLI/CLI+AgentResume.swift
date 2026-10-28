import Foundation
import Darwin

/// The last session an agent ended, kept after session-end consumes its live hook record.
struct AgentLastSessionRecord: Codable, Equatable {
    var provider: String
    var sessionId: String
    var cwd: String?
    var workspaceId: String?
    var surfaceId: String?
    var endedAt: TimeInterval
    var transcriptPath: String? = nil
}

private struct AgentLastSessionsFile: Codable, Equatable {
    var version: Int = 1
    var sessions: [AgentLastSessionRecord] = []
}

/// `~/.programa/agent-last-sessions.json`: newest first, at most one entry per surface and
/// per cwd, entries older than 7 days dropped. Shared by every agent provider's hook.
final class AgentLastSessionStore {
    private static let defaultPath = "~/.programa/agent-last-sessions.json"
    private static let maxAgeSeconds: TimeInterval = 60 * 60 * 24 * 7
    private static let maxEntries = 50

    private let path: String
    private let fileManager = FileManager.default

    init(processEnv: [String: String] = ProcessInfo.processInfo.environment) {
        let override = processEnv["PROGRAMA_AGENT_LAST_SESSIONS_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        path = NSString(string: (override?.isEmpty == false ? override : nil) ?? Self.defaultPath).expandingTildeInPath
    }

    /// Read-only: writers replace the file atomically, so a reader needs no lock.
    func entries() -> [AgentLastSessionRecord] {
        pruned(load()?.sessions ?? [])
    }

    func record(_ entry: AgentLastSessionRecord) throws {
        try fileManager.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let lockPath = path + ".lock"
        let fd = open(lockPath, O_CREAT | O_RDWR, mode_t(S_IRUSR | S_IWUSR))
        guard fd >= 0 else { throw CLIError(message: "Failed to open agent session lock: \(lockPath)") }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw CLIError(message: "Failed to lock agent sessions: \(lockPath)") }
        defer { _ = flock(fd, LOCK_UN) }

        // An unreadable file is rebuilt: it only caches ids for `programa resume`.
        let others = (load()?.sessions ?? []).filter { existing in
            existing.sessionId != entry.sessionId
                && (entry.surfaceId == nil || existing.surfaceId != entry.surfaceId)
                && (entry.cwd == nil || existing.cwd != entry.cwd)
        }
        let file = AgentLastSessionsFile(sessions: Array(pruned([entry] + others).prefix(Self.maxEntries)))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(file).write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private func load() -> AgentLastSessionsFile? {
        guard let data = fileManager.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(AgentLastSessionsFile.self, from: data)
    }

    private func pruned(_ sessions: [AgentLastSessionRecord]) -> [AgentLastSessionRecord] {
        let cutoff = Date().timeIntervalSince1970 - Self.maxAgeSeconds
        return sessions.filter { $0.endedAt >= cutoff }.sorted { $0.endedAt > $1.endedAt }
    }
}

extension ProgramaCLI {
    func resumeDescriptors() -> [CommandDescriptor] {
        [
            CommandDescriptor(
                names: ["resume"],
                helpLines: ["resume [--surface <id|ref>] [--workspace <id|ref>] [--session <id> [--provider <name>]] [--print] [--force]"],
                detailedUsage: """
                Usage: programa resume [flags]

                Resume the last agent session that ended in a pane: types the provider's resume
                command into the pane's shell and presses Enter. The pane must be back at its
                shell prompt: resume refuses while an agent or any other program runs there, and
                when the pane has no shell integration to report its prompt (override with --force).

                The session is the newest one that ended in the target surface, or else the
                newest one that ended in the pane's current directory. When the session ran in
                another directory that still exists, the command starts with `cd <dir> &&`.

                Supported agents: Claude Code (`claude --resume <id>`), Codex
                (`codex resume <id>`) and OpenCode (`opencode --session <id>`).

                Flags:
                  --surface <id|ref>     Target pane (default: $PROGRAMA_SURFACE_ID)
                  --workspace <id|ref>   Target the focused pane of this workspace
                  --session <id>         Resume this session id
                  --provider <name>      Agent for a --session id that was never recorded:
                                         claude, codex or opencode
                  --print                Print the command instead of typing it
                  --force                Type the command even when the pane is not known to be
                                         at its shell prompt

                Example:
                  programa resume
                  programa resume --print
                  programa resume --surface surface:3
                  programa resume --session 2f6c1d0e-8f7b-4a51-9c3e-0d4b1a2c3e4f --provider claude
                """,
                grammar: CLIArgumentGrammar(valueOptions: ["surface", "workspace", "session", "provider"], booleanOptions: ["print", "force"]),
                execute: { ctx in try self.runResume(ctx) }
            ),
        ]
    }

    /// Called once from every provider's session-end hook, after the live record is consumed.
    /// The session-start cwd wins over the session-end one: Claude Code only finds a session
    /// by id from the directory it was started in.
    func recordEndedAgentSession(
        provider: String,
        sessionId: String?,
        consumed: ClaudeHookSessionRecord?,
        cwd: String?,
        workspaceId: String?,
        surfaceId: String?,
        transcriptPath: String?
    ) {
        func nonEmpty(_ value: String?) -> String? {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return value
        }
        guard let id = nonEmpty(sessionId) ?? nonEmpty(consumed?.sessionId) else { return }
        try? AgentLastSessionStore().record(AgentLastSessionRecord(
            provider: provider,
            sessionId: id,
            cwd: nonEmpty(consumed?.cwd) ?? nonEmpty(cwd),
            workspaceId: nonEmpty(consumed?.workspaceId) ?? workspaceId,
            surfaceId: nonEmpty(consumed?.surfaceId) ?? surfaceId,
            endedAt: Date().timeIntervalSince1970,
            transcriptPath: nonEmpty(transcriptPath) ?? nonEmpty(consumed?.transcriptPath)
        ))
    }

    private func runResume(_ ctx: CommandContext) throws {
        let (surfaceArg, rem0) = parseOption(ctx.commandArgs, name: "--surface")
        let (workspaceArg, rem1) = parseOption(rem0, name: "--workspace")
        let (sessionArg, rem2) = parseOption(rem1, name: "--session")
        let (providerArg, rem3) = parseOption(rem2, name: "--provider")
        let printOnly = rem3.contains("--print")
        let force = rem3.contains("--force")
        if providerArg != nil, sessionArg == nil {
            throw CLIError(message: "resume: --provider needs --session <id>")
        }
        if let providerArg, !AgentResumeCommand.supportedProviders.contains(providerArg) {
            throw CLIError(message: "resume: unsupported --provider \(providerArg) (supported: \(AgentResumeCommand.supportedProviders.joined(separator: ", ")))")
        }
        let env = ProcessInfo.processInfo.environment
        let surfaceHandle = try normalizeSurfaceHandle(
            surfaceArg ?? (workspaceArg == nil && ctx.windowId == nil ? env["PROGRAMA_SURFACE_ID"] : nil),
            client: ctx.client
        )
        let workspaceHandle = try normalizeWorkspaceHandle(workspaceArg, client: ctx.client)
        guard surfaceHandle != nil || workspaceHandle != nil else {
            throw CLIError(message: "resume needs a target pane: pass --surface <id|ref> or run it inside a Programa pane")
        }

        let tree = try ctx.client.sendV2(method: V2MethodNames.systemTree, params: ["all_windows": true])
        guard let found = resumeTargetSurface(in: tree, surfaceHandle: surfaceHandle, workspaceHandle: workspaceHandle),
              let surfaceId = found.surface["id"] as? String else {
            if let surfaceHandle { throw CLIError(message: "resume: surface not found: \(surfaceHandle)") }
            throw CLIError(message: "resume: workspace not found: \(workspaceHandle ?? "")")
        }
        let (workspace, surface) = found
        let surfaceLabel = (surface["ref"] as? String) ?? surfaceId
        guard (surface["type"] as? String) == "terminal" else {
            throw CLIError(message: "resume: \(surfaceLabel) is not a terminal")
        }
        if !printOnly, let state = surface["agent_state"] as? String {
            throw CLIError(message: "resume: an agent is still running in \(surfaceLabel) (agent_state: \(state)); exit it before resuming")
        }
        if !printOnly, !force, (surface["shell_state"] as? String) != "promptIdle" {
            throw CLIError(message: "resume: the pane is running a program; return to the shell prompt or pass --force")
        }
        let paneDirectory = surface["current_directory"] as? String

        let entries = AgentLastSessionStore().entries()
        let target: AgentResumeTarget
        if let sessionArg {
            let recorded = entries.first { $0.sessionId == sessionArg }
            guard let provider = providerArg ?? recorded?.provider else {
                throw CLIError(message: "resume: session \(sessionArg) isn't recorded; pass --provider")
            }
            target = AgentResumeTarget(provider: provider, sessionId: sessionArg, cwd: recorded?.cwd)
        } else {
            let paneKey = paneDirectory.map(AgentResumeCommand.standardizedPath)
            guard let entry = entries.first(where: { $0.surfaceId == surfaceId })
                ?? entries.first(where: { $0.cwd.map(AgentResumeCommand.standardizedPath) == paneKey && paneKey != nil }) else {
                throw CLIError(message: "resume: no ended agent session recorded for \(surfaceLabel) or its directory")
            }
            target = AgentResumeTarget(provider: entry.provider, sessionId: entry.sessionId, cwd: entry.cwd)
        }
        guard AgentResumeCommand.isSupported(provider: target.provider) else {
            throw CLIError(message: "resume: \(target.provider) sessions cannot be resumed (supported: \(AgentResumeCommand.supportedProviders.joined(separator: ", ")))")
        }
        guard let line = AgentResumeCommand.line(for: target, paneDirectory: paneDirectory) else {
            throw CLIError(message: "resume: invalid session id: \(target.sessionId)")
        }

        if printOnly {
            print(ctx.jsonOutput ? jsonString(["command": line, "provider": target.provider, "session_id": target.sessionId]) : line)
            return
        }
        var params: [String: Any] = ["surface_id": surfaceId]
        if let workspaceId = workspace["id"] as? String { params["workspace_id"] = workspaceId }
        _ = try ctx.client.sendV2(method: V2MethodNames.surfaceSendText, params: params.merging(["text": line]) { _, new in new })
        _ = try ctx.client.sendV2(method: V2MethodNames.surfaceSendKey, params: params.merging(["key": "enter"]) { _, new in new })
        if ctx.jsonOutput {
            print(jsonString(["command": line, "provider": target.provider, "session_id": target.sessionId, "surface_id": surfaceId]))
        } else {
            print("OK \(surfaceLabel): \(line)")
        }
    }

    /// The surface node in a `system.tree` payload matching `surfaceHandle` (id or ref), or the
    /// focused surface of the workspace matching `workspaceHandle`.
    private func resumeTargetSurface(
        in tree: [String: Any],
        surfaceHandle: String?,
        workspaceHandle: String?
    ) -> (workspace: [String: Any], surface: [String: Any])? {
        func matches(_ node: [String: Any], _ handle: String) -> Bool {
            (node["id"] as? String)?.lowercased() == handle.lowercased()
                || (node["ref"] as? String)?.lowercased() == handle.lowercased()
        }
        for window in tree["windows"] as? [[String: Any]] ?? [] {
            for workspace in window["workspaces"] as? [[String: Any]] ?? [] {
                if let workspaceHandle, !matches(workspace, workspaceHandle) { continue }
                let surfaces = (workspace["panes"] as? [[String: Any]] ?? []).flatMap { $0["surfaces"] as? [[String: Any]] ?? [] }
                let found = surfaceHandle.map { handle in surfaces.first { matches($0, handle) } }
                    ?? surfaces.first { ($0["focused"] as? Bool) == true }
                if let found { return (workspace, found) }
            }
        }
        return nil
    }
}
