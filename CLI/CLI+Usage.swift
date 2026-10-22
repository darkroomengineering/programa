import Foundation
import Darwin

/// Token counts in four disjoint buckets: `input` excludes cached and cache-write tokens.
struct AgentTokenUsage: Equatable {
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite = 0

    var total: Int { input + output + cacheRead + cacheWrite }

    static func + (lhs: AgentTokenUsage, rhs: AgentTokenUsage) -> AgentTokenUsage {
        AgentTokenUsage(
            input: lhs.input + rhs.input,
            output: lhs.output + rhs.output,
            cacheRead: lhs.cacheRead + rhs.cacheRead,
            cacheWrite: lhs.cacheWrite + rhs.cacheWrite
        )
    }

    var json: [String: Any] {
        ["input": input, "output": output, "cache_read": cacheRead, "cache_write": cacheWrite, "total": total]
    }
}

/// Sums the token counts an agent wrote to its own transcript. Formats and dedupe rules are
/// documented in docs/agent-usage.md.
enum AgentTranscriptUsage {
    /// Nil when the main transcript cannot be opened.
    static func usage(provider: String, transcriptPath: String) -> AgentTokenUsage? {
        switch provider {
        case "claude-code": return claude(transcriptPath: transcriptPath)
        case "codex": return codex(transcriptPath: transcriptPath)
        default: return nil
        }
    }

    static func claude(transcriptPath: String) -> AgentTokenUsage? {
        var perMessage: [String: AgentTokenUsage] = [:]
        let needle = Data("\"usage\"".utf8)
        for (index, path) in ([transcriptPath] + claudeSubagentTranscripts(of: transcriptPath)).enumerated() {
            let opened = forEachLine(path: path) { line in
                guard line.range(of: needle) != nil,
                      let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      let message = object["message"] as? [String: Any],
                      let usage = message["usage"] as? [String: Any],
                      let id = message["id"] as? String,
                      (message["model"] as? String) != "<synthetic>" else { return }
                let counted = AgentTokenUsage(
                    input: int(usage["input_tokens"]),
                    output: int(usage["output_tokens"]),
                    cacheRead: int(usage["cache_read_input_tokens"]),
                    cacheWrite: int(usage["cache_creation_input_tokens"])
                )
                if counted.total > (perMessage[id]?.total ?? -1) {
                    perMessage[id] = counted
                }
            }
            if index == 0, !opened { return nil }
        }
        return perMessage.values.reduce(AgentTokenUsage(), +)
    }

    static func codex(transcriptPath: String) -> AgentTokenUsage? {
        var perResponse: [String: AgentTokenUsage] = [:]
        var largestRunningTotal: (total: Int, usage: AgentTokenUsage)?
        let recordNeedle = Data("token_usage_record".utf8)
        let countNeedle = Data("token_count".utf8)
        let opened = forEachLine(path: transcriptPath) { line in
            guard line.range(of: recordNeedle) != nil || line.range(of: countNeedle) != nil,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let payload = object["payload"] as? [String: Any] else { return }
            if (object["type"] as? String) == "token_usage_record",
               let responseId = payload["response_id"] as? String,
               let usage = payload["usage"] as? [String: Any] {
                perResponse[responseId] = codexUsage(usage)
            } else if (payload["type"] as? String) == "token_count",
                      let info = payload["info"] as? [String: Any],
                      let running = info["total_token_usage"] as? [String: Any] {
                let total = int(running["total_tokens"])
                if total > (largestRunningTotal?.total ?? -1) {
                    largestRunningTotal = (total, codexUsage(running))
                }
            }
        }
        guard opened else { return nil }
        if perResponse.isEmpty { return largestRunningTotal?.usage ?? AgentTokenUsage() }
        return perResponse.values.reduce(AgentTokenUsage(), +)
    }

    /// Codex counts cached tokens inside `input_tokens`.
    private static func codexUsage(_ usage: [String: Any]) -> AgentTokenUsage {
        let cached = int(usage["cached_input_tokens"])
        return AgentTokenUsage(
            input: max(0, int(usage["input_tokens"]) - cached),
            output: int(usage["output_tokens"]),
            cacheRead: cached,
            cacheWrite: int(usage["cache_write_input_tokens"])
        )
    }

    /// `<dir>/<session>.jsonl` keeps its subagents in `<dir>/<session>/subagents/**/agent-*.jsonl`.
    private static func claudeSubagentTranscripts(of transcriptPath: String) -> [String] {
        guard transcriptPath.hasSuffix(".jsonl") else { return [] }
        let root = String(transcriptPath.dropLast(".jsonl".count)) + "/subagents"
        guard let enumerator = FileManager.default.enumerator(atPath: root) else { return [] }
        return enumerator.compactMap { $0 as? String }
            .filter { $0.hasSuffix(".jsonl") && ($0 as NSString).lastPathComponent.hasPrefix("agent-") }
            .sorted()
            .map { root + "/" + $0 }
    }

    /// Streams the file one line at a time; `body` gets a view of the line buffer that is only
    /// valid during the call. False when the file cannot be opened.
    private static func forEachLine(path: String, _ body: (Data) -> Void) -> Bool {
        guard let file = fopen(path, "r") else { return false }
        defer { fclose(file) }
        var buffer: UnsafeMutablePointer<CChar>?
        var capacity = 0
        defer { free(buffer) }
        while true {
            let length = getline(&buffer, &capacity, file)
            guard length >= 0, let buffer else { break }
            body(Data(bytesNoCopy: buffer, count: length, deallocator: .none))
        }
        return true
    }

    private static func int(_ value: Any?) -> Int {
        (value as? NSNumber)?.intValue ?? 0
    }
}

private struct AgentUsageSession {
    let provider: String
    let sessionId: String
    let workspaceId: String?
    let live: Bool
    let transcriptPath: String?
    let updatedAt: TimeInterval
}

extension ProgramaCLI {
    func usageDescriptors() -> [CommandDescriptor] {
        [
            CommandDescriptor(
                names: ["usage"],
                helpLines: ["usage [--workspace <id|ref>] [--json]"],
                detailedUsage: """
                Usage: programa usage [--workspace <id|ref>] [--json]

                Show the tokens each agent session used, grouped by workspace. Covers Claude Code
                and Codex sessions that Programa's hooks recorded: running sessions, plus the
                last ended session per pane and per directory from the past 7 days.

                Counts come from each agent's own transcript, read when you run the command:
                input (not cached), output, cache read and cache write. No cost is shown;
                the transcripts carry no per-session cost. Sessions whose transcript is missing
                or unreadable are skipped and counted.

                Flags:
                  --workspace <id|ref>   Only this workspace
                  --json                 Print JSON

                Example:
                  programa usage
                  programa usage --workspace workspace:2 --json
                """,
                grammar: CLIArgumentGrammar(valueOptions: ["workspace"], booleanOptions: ["json"]),
                execute: { ctx in try self.runUsage(ctx) }
            ),
        ]
    }

    private func runUsage(_ ctx: CommandContext) throws {
        let (workspaceArg, _) = parseOption(ctx.commandArgs, name: "--workspace")
        let workspaceHandle = try normalizeWorkspaceHandle(workspaceArg, client: ctx.client)
        let tree = try ctx.client.sendV2(method: V2MethodNames.systemTree, params: ["all_windows": true])
        let openWorkspaces = (tree["windows"] as? [[String: Any]] ?? []).flatMap {
            $0["workspaces"] as? [[String: Any]] ?? []
        }
        func idOf(_ workspace: [String: Any]) -> String? { (workspace["id"] as? String)?.lowercased() }

        var sessions = knownAgentUsageSessions()
        if let workspaceHandle {
            let handle = workspaceHandle.lowercased()
            let match = openWorkspaces.first {
                idOf($0) == handle || ($0["ref"] as? String)?.lowercased() == handle
            }
            guard let targetId = match.flatMap(idOf) ?? (isUUID(handle) ? handle : nil) else {
                throw CLIError(message: "usage: workspace not found: \(workspaceHandle)")
            }
            sessions = sessions.filter { $0.workspaceId?.lowercased() == targetId }
        }

        var skipped: [AgentUsageSession] = []
        var rowsByWorkspace: [String: [(AgentUsageSession, AgentTokenUsage)]] = [:]
        var recordedIds: [String: String] = [:]
        for session in sessions {
            guard let path = session.transcriptPath ?? derivedTranscriptPath(session),
                  let usage = AgentTranscriptUsage.usage(provider: session.provider, transcriptPath: path) else {
                skipped.append(session)
                continue
            }
            let key = session.workspaceId?.lowercased() ?? ""
            recordedIds[key] = session.workspaceId
            rowsByWorkspace[key, default: []].append((session, usage))
        }

        let openIds = openWorkspaces.compactMap(idOf)
        let closedIds = rowsByWorkspace.keys.filter { !openIds.contains($0) }.sorted()
        var groups: [(workspace: [String: Any], rows: [(AgentUsageSession, AgentTokenUsage)])] = []
        for id in openIds + closedIds {
            guard let rows = rowsByWorkspace[id] else { continue }
            let workspace = openWorkspaces.first { idOf($0) == id }
                ?? (id.isEmpty ? ["open": false] : ["id": recordedIds[id] ?? id, "open": false])
            groups.append((workspace, rows.sorted { ($0.0.live ? 1 : 0, $0.0.updatedAt) > ($1.0.live ? 1 : 0, $1.0.updatedAt) }))
        }
        let grandTotal = groups.flatMap { $0.rows.map(\.1) }.reduce(AgentTokenUsage(), +)

        if ctx.jsonOutput || ctx.commandArgs.contains("--json") {
            let payload: [String: Any] = [
                "workspaces": groups.map { group -> [String: Any] in
                    var entry: [String: Any] = [
                        "open": group.workspace["open"] as? Bool ?? true,
                        "sessions": group.rows.map { session, usage -> [String: Any] in
                            [
                                "provider": session.provider,
                                "session_id": session.sessionId,
                                "state": session.live ? "live" : "ended",
                                "tokens": usage.json,
                            ]
                        },
                        "tokens": group.rows.map(\.1).reduce(AgentTokenUsage(), +).json,
                    ]
                    for key in ["id", "ref", "title"] {
                        if let value = group.workspace[key] as? String { entry[key] = value }
                    }
                    return entry
                },
                "tokens": grandTotal.json,
                "skipped": skipped.map { ["provider": $0.provider, "session_id": $0.sessionId] },
            ]
            print(jsonString(formatIDs(payload, mode: ctx.idFormat)))
            return
        }

        if groups.isEmpty {
            print("No agent token usage recorded")
        }
        for group in groups {
            let title = (group.workspace["title"] as? String) ?? ""
            let handle: String
            if group.workspace["open"] as? Bool != false {
                handle = textHandle(group.workspace, idFormat: ctx.idFormat)
            } else if let id = group.workspace["id"] as? String {
                handle = "\(id) (closed)"
            } else {
                handle = "No workspace"
            }
            print(title.isEmpty ? handle : "\(handle)  \(title)")
            var lines = [["AGENT", "SESSION", "STATE", "INPUT", "OUTPUT", "CACHE READ", "CACHE WRITE"]]
            for (session, usage) in group.rows {
                lines.append([session.provider, session.sessionId, session.live ? "live" : "ended"] + usageColumns(usage))
            }
            if group.rows.count > 1 {
                lines.append(["total", "", ""] + usageColumns(group.rows.map(\.1).reduce(AgentTokenUsage(), +)))
            }
            printUsageTable(lines)
        }
        if groups.count > 1 {
            print("All workspaces: " + zip(["input", "output", "cache read", "cache write"], usageColumns(grandTotal))
                .map { "\($0) \($1)" }.joined(separator: ", "))
        }
        if !skipped.isEmpty {
            print("Skipped \(skipped.count) session\(skipped.count == 1 ? "" : "s") with a missing or unreadable transcript")
        }
    }

    private func usageColumns(_ usage: AgentTokenUsage) -> [String] {
        [usage.input, usage.output, usage.cacheRead, usage.cacheWrite].map(groupedDigits)
    }

    private func groupedDigits(_ value: Int) -> String {
        let digits = Array(String(value))
        var out = ""
        for (index, digit) in digits.enumerated() {
            if index > 0, (digits.count - index) % 3 == 0 { out.append(",") }
            out.append(digit)
        }
        return out
    }

    /// Text columns left-aligned, number columns (from the fourth on) right-aligned.
    private func printUsageTable(_ lines: [[String]]) {
        let widths = (0..<lines[0].count).map { column in lines.map { $0[column].count }.max() ?? 0 }
        for line in lines {
            let cells = line.enumerated().map { column, cell in
                let pad = String(repeating: " ", count: widths[column] - cell.count)
                return column < 3 ? cell + pad : pad + cell
            }
            print("  " + cells.joined(separator: "  ").replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression))
        }
    }

    /// Live hook records first; an ended record for the same session only fills the gap.
    private func knownAgentUsageSessions() -> [AgentUsageSession] {
        let env = ProcessInfo.processInfo.environment
        let stores: [(provider: String, store: ClaudeHookSessionStore)] = [
            ("claude-code", ClaudeHookSessionStore(processEnv: env)),
            ("codex", ClaudeHookSessionStore(processEnv: env.merging(
                ["PROGRAMA_CLAUDE_HOOK_STATE_PATH": "~/.programa/codex-hook-sessions.json"], uniquingKeysWith: { _, new in new }
            ))),
        ]
        var sessions: [AgentUsageSession] = []
        var seen = Set<String>()
        for (provider, store) in stores {
            for record in store.allSessions() where seen.insert("\(provider)\n\(record.sessionId)").inserted {
                sessions.append(AgentUsageSession(
                    provider: provider, sessionId: record.sessionId, workspaceId: record.workspaceId,
                    live: true, transcriptPath: record.transcriptPath, updatedAt: record.updatedAt
                ))
            }
        }
        for entry in AgentLastSessionStore().entries()
        where ["claude-code", "codex"].contains(entry.provider) && seen.insert("\(entry.provider)\n\(entry.sessionId)").inserted {
            sessions.append(AgentUsageSession(
                provider: entry.provider, sessionId: entry.sessionId, workspaceId: entry.workspaceId,
                live: false, transcriptPath: entry.transcriptPath, updatedAt: entry.endedAt
            ))
        }
        return sessions
    }

    /// For sessions recorded without a transcript path: Claude Code names the file after the
    /// session id, Codex ends the rollout file name with it.
    private func derivedTranscriptPath(_ session: AgentUsageSession) -> String? {
        let id = session.sessionId
        guard !id.isEmpty, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
            return nil
        }
        let env = ProcessInfo.processInfo.environment
        let fileManager = FileManager.default
        func home(_ variable: String, _ fallback: String) -> String {
            let value = env[variable]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return NSString(string: value.isEmpty ? fallback : value).expandingTildeInPath
        }
        switch session.provider {
        case "claude-code":
            let projects = home("CLAUDE_CONFIG_DIR", "~/.claude") + "/projects"
            return ((try? fileManager.contentsOfDirectory(atPath: projects)) ?? [])
                .map { "\(projects)/\($0)/\(id).jsonl" }
                .first { fileManager.fileExists(atPath: $0) }
        case "codex":
            let root = home("CODEX_HOME", "~/.codex") + "/sessions"
            let suffix = "-\(id).jsonl"
            guard let enumerator = fileManager.enumerator(atPath: root) else { return nil }
            return enumerator.compactMap { $0 as? String }.first { $0.hasSuffix(suffix) }.map { "\(root)/\($0)" }
        default:
            return nil
        }
    }
}
