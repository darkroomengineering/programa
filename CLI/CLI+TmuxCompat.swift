import Foundation
import CryptoKit
import Darwin
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
#if canImport(Security)
import Security
#endif

extension ProgramaCLI {
    /// The 23 tmux-emulation command names, all dispatched through the same
    /// `runTmuxCompatCommand`. Help text preserves the original grouped
    /// layout, including the two pipe-separated combo lines
    /// ("next-window | previous-window | last-window" and
    /// "bind-key | unbind-key | copy-mode") that documented three names on
    /// one line while still being three independently-dispatchable commands.
    static func tmuxCompatDescriptors(
        runTmuxCompatCommand: @escaping (CommandContext) throws -> Void
    ) -> [CommandDescriptor] {
        [
            CommandDescriptor(names: ["capture-pane"], helpLines: ["capture-pane [--workspace <id|ref>] [--surface <id|ref>] [--scrollback] [--lines <n>]"], execute: runTmuxCompatCommand),
            CommandDescriptor(names: ["resize-pane"], helpLines: ["resize-pane --pane <id|ref> [--workspace <id|ref>] (-L|-R|-U|-D) [--amount <n>]"], execute: runTmuxCompatCommand),
            CommandDescriptor(names: ["pipe-pane"], helpLines: ["pipe-pane --command <shell-command> [--workspace <id|ref>] [--surface <id|ref>]"], execute: runTmuxCompatCommand),
            CommandDescriptor(names: ["wait-for"], helpLines: ["wait-for [-S|--signal] <name> [--timeout <seconds>]"], execute: runTmuxCompatCommand),
            CommandDescriptor(names: ["swap-pane"], helpLines: ["swap-pane --pane <id|ref> --target-pane <id|ref> [--workspace <id|ref>]"], grammar: CLIArgumentGrammar(valueOptions: ["pane", "target-pane", "workspace"], requiredOptions: ["pane", "target-pane"]), execute: runTmuxCompatCommand),
            CommandDescriptor(names: ["break-pane"], helpLines: ["break-pane [--workspace <id|ref>] [--pane <id|ref>] [--surface <id|ref>] [--no-focus]"], grammar: CLIArgumentGrammar(valueOptions: ["workspace", "pane", "surface"], booleanOptions: ["no-focus"]), execute: runTmuxCompatCommand),
            CommandDescriptor(names: ["join-pane"], helpLines: ["join-pane --target-pane <id|ref> [--workspace <id|ref>] [--pane <id|ref>] [--surface <id|ref>] [--no-focus]"], grammar: CLIArgumentGrammar(valueOptions: ["target-pane", "workspace", "pane", "surface"], booleanOptions: ["no-focus"], requiredOptions: ["target-pane"]), execute: runTmuxCompatCommand),
            CommandDescriptor(names: ["next-window", "previous-window", "last-window"], helpLines: ["next-window | previous-window | last-window"], grammar: CLIArgumentGrammar(), execute: runTmuxCompatCommand),
            CommandDescriptor(names: ["last-pane"], helpLines: ["last-pane [--workspace <id|ref>]"], grammar: CLIArgumentGrammar(valueOptions: ["workspace"]), execute: runTmuxCompatCommand),
            CommandDescriptor(names: ["find-window"], helpLines: ["find-window [--content] [--select] <query>"], grammar: CLIArgumentGrammar(booleanOptions: ["content", "select"], minPositionals: 1, maxPositionals: nil), execute: runTmuxCompatCommand),
            CommandDescriptor(names: ["clear-history"], helpLines: ["clear-history [--workspace <id|ref>] [--surface <id|ref>]"], grammar: CLIArgumentGrammar(valueOptions: ["workspace", "surface"]), execute: runTmuxCompatCommand),
            CommandDescriptor(names: ["set-hook"], helpLines: ["set-hook [--list] [--unset <event>] | <event> <command>"], execute: runTmuxCompatCommand),
            CommandDescriptor(names: ["popup"], helpLines: ["popup"], execute: runTmuxCompatCommand),
            CommandDescriptor(names: ["bind-key", "unbind-key", "copy-mode"], helpLines: ["bind-key | unbind-key | copy-mode"], execute: runTmuxCompatCommand),
            CommandDescriptor(names: ["set-buffer"], helpLines: ["set-buffer [--name <name>] <text>"], grammar: CLIArgumentGrammar(valueOptions: ["name"], minPositionals: 1, maxPositionals: nil), execute: runTmuxCompatCommand),
            CommandDescriptor(names: ["list-buffers"], helpLines: ["list-buffers"], grammar: CLIArgumentGrammar(), execute: runTmuxCompatCommand),
            CommandDescriptor(names: ["paste-buffer"], helpLines: ["paste-buffer [--name <name>] [--workspace <id|ref>] [--surface <id|ref>]"], grammar: CLIArgumentGrammar(valueOptions: ["name", "workspace", "surface"]), execute: runTmuxCompatCommand),
            CommandDescriptor(names: ["respawn-pane"], helpLines: ["respawn-pane [--workspace <id|ref>] [--surface <id|ref>] [--command <cmd>]"], grammar: CLIArgumentGrammar(valueOptions: ["workspace", "surface", "command"]), execute: runTmuxCompatCommand),
            CommandDescriptor(names: ["display-message"], helpLines: ["display-message [-p|--print] <text>"], execute: runTmuxCompatCommand),
        ]
    }

    private struct TmuxParsedArguments {
        var flags: Set<String> = []
        var options: [String: [String]] = [:]
        var positional: [String] = []

        func hasFlag(_ flag: String) -> Bool {
            flags.contains(flag)
        }

        func value(_ flag: String) -> String? {
            options[flag]?.last
        }
    }

    private func parseTmuxArguments(
        _ args: [String],
        valueFlags: Set<String>,
        boolFlags: Set<String>
    ) throws -> TmuxParsedArguments {
        var parsed = TmuxParsedArguments()
        var index = 0
        var pastTerminator = false

        while index < args.count {
            let arg = args[index]
            if pastTerminator {
                parsed.positional.append(arg)
                index += 1
                continue
            }
            if arg == "--" {
                pastTerminator = true
                index += 1
                continue
            }
            if !arg.hasPrefix("-") || arg == "-" {
                parsed.positional.append(arg)
                index += 1
                continue
            }
            if arg.hasPrefix("--") {
                parsed.positional.append(arg)
                index += 1
                continue
            }

            let cluster = Array(arg.dropFirst())
            var cursor = 0
            var recognizedArgument = false
            while cursor < cluster.count {
                let flag = "-" + String(cluster[cursor])
                if boolFlags.contains(flag) {
                    parsed.flags.insert(flag)
                    cursor += 1
                    recognizedArgument = true
                    continue
                }
                if valueFlags.contains(flag) {
                    let remainder = String(cluster.dropFirst(cursor + 1))
                    let value: String
                    if !remainder.isEmpty {
                        value = remainder
                    } else {
                        guard index + 1 < args.count else {
                            throw CLIError(message: "\(flag) requires a value")
                        }
                        index += 1
                        value = args[index]
                    }
                    parsed.options[flag, default: []].append(value)
                    recognizedArgument = true
                    cursor = cluster.count
                    continue
                }

                recognizedArgument = false
                break
            }

            if !recognizedArgument {
                parsed.positional.append(arg)
            }
            index += 1
        }

        return parsed
    }

    private func splitTmuxCommand(_ args: [String]) throws -> (command: String, args: [String]) {
        var index = 0
        let globalValueFlags: Set<String> = ["-L", "-S", "-f"]
        let globalBoolFlags: Set<String> = ["-V", "-v"]

        while index < args.count {
            let arg = args[index]
            if !arg.hasPrefix("-") || arg == "-" {
                return (arg.lowercased(), Array(args.dropFirst(index + 1)))
            }
            if arg == "--" {
                break
            }
            // Handle -V (version) as a pseudo-command
            if globalBoolFlags.contains(arg) {
                return (arg, [])
            }
            if let flag = globalValueFlags.first(where: { arg == $0 || arg.hasPrefix($0) }) {
                if arg == flag {
                    index += 1
                }
            }
            index += 1
        }

        throw CLIError(message: "tmux shim requires a command")
    }

    private func normalizedTmuxTarget(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func tmuxWindowSelector(from raw: String?) -> String? {
        guard let trimmed = normalizedTmuxTarget(raw) else { return nil }
        if trimmed.hasPrefix("%") || trimmed.hasPrefix("pane:") {
            return nil
        }
        if let dot = trimmed.lastIndex(of: ".") {
            return String(trimmed[..<dot])
        }
        return trimmed
    }

    private func tmuxPaneSelector(from raw: String?) -> String? {
        guard let trimmed = normalizedTmuxTarget(raw) else { return nil }
        if trimmed.hasPrefix("%") {
            return String(trimmed.dropFirst())
        }
        if trimmed.hasPrefix("pane:") {
            return trimmed
        }
        if let dot = trimmed.lastIndex(of: ".") {
            return String(trimmed[trimmed.index(after: dot)...])
        }
        return nil
    }

    private func tmuxWorkspaceItems(client: SocketClient) throws -> [[String: Any]] {
        let payload = try client.sendV2(method: V2MethodNames.workspaceList)
        return payload["workspaces"] as? [[String: Any]] ?? []
    }

    private func tmuxIsClaudeTeamWorkspace(_ item: [String: Any]) -> Bool {
        guard let workspaceId = item["id"] as? String,
              let helpers = item["helpers"] as? [[String: Any]] else { return false }
        return helpers.contains { helper in
            helper["host"] as? String == "claude-teams"
                && helper["workspace_id"] as? String == workspaceId
        }
    }

    private func tmuxTeamWorkspaceIds(
        containing workspaceId: String,
        workspaceItems: [[String: Any]]
    ) -> [String] {
        let orderedIds = workspaceItems.compactMap { $0["id"] as? String }
        let liveWorkspaceIds = Set(orderedIds)
        let teamWorkspaceIds = Set(workspaceItems.compactMap { item in
            tmuxIsClaudeTeamWorkspace(item) ? item["id"] as? String : nil
        })
        let orderById = Dictionary(uniqueKeysWithValues: orderedIds.enumerated().map { ($0.element, $0.offset) })
        let parentById: [String: String] = Dictionary(uniqueKeysWithValues: workspaceItems.compactMap { item in
            guard let id = item["id"] as? String,
                  teamWorkspaceIds.contains(id),
                  let parentId = item["agent_parent_workspace_id"] as? String,
                  liveWorkspaceIds.contains(parentId) else {
                return nil
            }
            return (id, parentId)
        })

        var lineage = [workspaceId]
        var lineageIndex = [workspaceId: 0]
        var rootWorkspaceId = workspaceId
        while let parentId = parentById[rootWorkspaceId] {
            if let cycleStart = lineageIndex[parentId] {
                rootWorkspaceId = lineage[cycleStart...].min {
                    orderById[$0, default: .max] < orderById[$1, default: .max]
                } ?? parentId
                break
            }
            lineageIndex[parentId] = lineage.count
            lineage.append(parentId)
            rootWorkspaceId = parentId
        }

        var workspaceIds: [String] = []
        var visited: Set<String> = []
        func appendSubtree(parentId: String) {
            guard visited.insert(parentId).inserted else { return }
            workspaceIds.append(parentId)
            for childId in orderedIds where parentById[childId] == parentId {
                appendSubtree(parentId: childId)
            }
        }
        appendSubtree(parentId: rootWorkspaceId)
        return workspaceIds
    }

    private func tmuxDescendantWorkspaceIds(
        of workspaceId: String,
        workspaceItems: [[String: Any]]
    ) -> [String] {
        let orderedIds = workspaceItems.compactMap { $0["id"] as? String }
        let teamWorkspaceIds = Set(workspaceItems.compactMap { item in
            tmuxIsClaudeTeamWorkspace(item) ? item["id"] as? String : nil
        })
        let parentById: [String: String] = Dictionary(uniqueKeysWithValues: workspaceItems.compactMap { item in
            guard let id = item["id"] as? String,
                  teamWorkspaceIds.contains(id),
                  let parentId = item["agent_parent_workspace_id"] as? String else {
                return nil
            }
            return (id, parentId)
        })
        var descendants: [String] = []
        var visited: Set<String> = [workspaceId]
        func appendDescendants(parentId: String) {
            for childId in orderedIds where parentById[childId] == parentId {
                guard visited.insert(childId).inserted else { continue }
                appendDescendants(parentId: childId)
                descendants.append(childId)
            }
        }
        appendDescendants(parentId: workspaceId)
        return descendants
    }

    private func tmuxFinishLiveAgents(workspaceId: String, client: SocketClient) {
        guard let payload = try? client.sendV2(method: V2MethodNames.agentTaskList, params: [
            "workspace_id": workspaceId,
            "include_finished": false,
        ]), let agents = payload["agents"] as? [[String: Any]] else {
            return
        }
        for agent in agents {
            guard let agentId = agent["id"] as? String else { continue }
            _ = try? client.sendV2(method: V2MethodNames.agentTaskFinish, params: [
                "agent_id": agentId,
                "state": "cancelled",
            ])
        }
    }

    private func tmuxCloseHelperWorkspace(workspaceId: String, client: SocketClient) throws {
        tmuxFinishLiveAgents(workspaceId: workspaceId, client: client)
        _ = try client.sendV2(method: V2MethodNames.workspaceClose, params: ["workspace_id": workspaceId])
    }

    private func tmuxCallerWorkspaceHandle() -> String? {
        normalizedTmuxTarget(ProcessInfo.processInfo.environment["PROGRAMA_WORKSPACE_ID"])
    }

    private func tmuxCallerPaneHandle() -> String? {
        guard let pane = normalizedTmuxTarget(ProcessInfo.processInfo.environment["TMUX_PANE"])
            ?? normalizedTmuxTarget(ProcessInfo.processInfo.environment["PROGRAMA_PANE_ID"]) else {
            return nil
        }
        return pane.hasPrefix("%") ? String(pane.dropFirst()) : pane
    }

    private func tmuxCallerSurfaceHandle() -> String? {
        normalizedTmuxTarget(ProcessInfo.processInfo.environment["PROGRAMA_SURFACE_ID"])
    }

    private func tmuxResolvedCallerWorkspaceId(client: SocketClient) -> String? {
        guard let callerWorkspace = tmuxCallerWorkspaceHandle() else {
            return nil
        }
        return try? resolveWorkspaceId(callerWorkspace, client: client)
    }

    private func tmuxCanonicalPaneId(
        _ handle: String,
        workspaceId: String,
        client: SocketClient
    ) throws -> String {
        if isUUID(handle) {
            return handle
        }

        let payload = try client.sendV2(method: V2MethodNames.paneList, params: ["workspace_id": workspaceId])
        let panes = payload["panes"] as? [[String: Any]] ?? []
        for pane in panes {
            if (pane["ref"] as? String) == handle || (pane["id"] as? String) == handle {
                if let id = pane["id"] as? String {
                    return id
                }
            }
        }

        if let index = Int(handle) {
            for pane in panes where intFromAny(pane["index"]) == index {
                if let id = pane["id"] as? String {
                    return id
                }
            }
        }

        throw CLIError(message: "Pane target not found")
    }

    private func tmuxCanonicalSurfaceId(
        _ handle: String,
        workspaceId: String,
        client: SocketClient
    ) throws -> String {
        let payload = try client.sendV2(method: V2MethodNames.surfaceList, params: ["workspace_id": workspaceId])
        let surfaces = payload["surfaces"] as? [[String: Any]] ?? []
        for surface in surfaces {
            if (surface["ref"] as? String) == handle || (surface["id"] as? String) == handle {
                if let id = surface["id"] as? String {
                    return id
                }
            }
        }

        if let index = Int(handle) {
            for surface in surfaces where intFromAny(surface["index"]) == index {
                if let id = surface["id"] as? String {
                    return id
                }
            }
        }

        throw CLIError(message: "Surface target not found")
    }

    private func tmuxWorkspaceIdForPaneHandle(_ handle: String, client: SocketClient) throws -> String? {
        guard isUUID(handle) || isHandleRef(handle) else {
            return nil
        }

        let workspaces = try tmuxWorkspaceItems(client: client)
        for workspace in workspaces {
            guard let workspaceId = workspace["id"] as? String else { continue }
            let payload = try client.sendV2(method: V2MethodNames.paneList, params: ["workspace_id": workspaceId])
            let panes = payload["panes"] as? [[String: Any]] ?? []
            if panes.contains(where: { ($0["id"] as? String) == handle || ($0["ref"] as? String) == handle }) {
                return workspaceId
            }
        }

        return nil
    }

    private func tmuxFocusedPaneId(workspaceId: String, client: SocketClient) throws -> String {
        let payload = try client.sendV2(method: V2MethodNames.surfaceCurrent, params: ["workspace_id": workspaceId])
        if let paneId = payload["pane_id"] as? String {
            return paneId
        }
        if let paneRef = payload["pane_ref"] as? String {
            return try tmuxCanonicalPaneId(paneRef, workspaceId: workspaceId, client: client)
        }
        throw CLIError(message: "Pane target not found")
    }

    private func tmuxResolveWorkspaceTarget(_ raw: String?, client: SocketClient) throws -> String {
        guard var token = normalizedTmuxTarget(raw) else {
            if let callerWorkspace = tmuxCallerWorkspaceHandle() {
                return try resolveWorkspaceId(callerWorkspace, client: client)
            }
            return try resolveWorkspaceId(nil, client: client)
        }

        if token == "!" || token == "^" || token == "-" {
            let payload = try client.sendV2(method: V2MethodNames.workspaceLast)
            if let workspaceId = payload["workspace_id"] as? String {
                return workspaceId
            }
            throw CLIError(message: "Previous workspace not found")
        }

        if let dot = token.lastIndex(of: ".") {
            token = String(token[..<dot])
        }
        if let colon = token.lastIndex(of: ":") {
            let prefix = String(token[..<colon])
            let suffix = String(token[token.index(after: colon)...])
            if !prefix.isEmpty {
                // Session-qualified target (tmux "session:window"). Programa has
                // no session concept — a tmux "session" created via new-session
                // becomes a single workspace titled with the session name — so
                // try increasingly narrow interpretations before giving up.
                let original = token
                let items = try tmuxWorkspaceItems(client: client)

                // 1. The full original token might legitimately be a workspace
                //    title containing a colon.
                if let match = items.first(where: {
                    (($0["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == original
                }), let id = match["id"] as? String {
                    return id
                }

                // 2. The session component alone matches a workspace title, and
                //    the window component is tmux's base-index for "the
                //    session's first window" (0 or 1).
                if (suffix == "0" || suffix == "1"),
                   let match = items.first(where: {
                       (($0["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == prefix
                   }), let id = match["id"] as? String {
                    return id
                }

                throw CLIError(message: "Workspace target not found: '\(original)'. Programa has no tmux sessions; a session-qualified target like 'name:2' cannot be resolved — target the window by its own name or index.")
            }
            token = suffix
        }
        if token.hasPrefix("@") {
            token = String(token.dropFirst())
        }

        if let resolvedHandle = try? normalizeWorkspaceHandle(token, client: client, allowCurrent: true) {
            return try resolveWorkspaceId(resolvedHandle, client: client)
        }

        let needle = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let items = try tmuxWorkspaceItems(client: client)
        if let match = items.first(where: {
            (($0["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == needle
        }), let id = match["id"] as? String {
            return id
        }

        throw CLIError(message: "Workspace target not found: \(token)")
    }

    private func tmuxResolvePaneTarget(_ raw: String?, client: SocketClient) throws -> (workspaceId: String, paneId: String) {
        let paneSelector = tmuxPaneSelector(from: raw)
        let workspaceSelector = tmuxWindowSelector(from: raw)
        let workspaceId: String = {
            if let workspaceSelector {
                return (try? tmuxResolveWorkspaceTarget(workspaceSelector, client: client)) ?? ""
            }
            if let paneSelector,
               let workspaceId = try? tmuxWorkspaceIdForPaneHandle(paneSelector, client: client) {
                return workspaceId
            }
            return (try? tmuxResolveWorkspaceTarget(nil, client: client)) ?? ""
        }()
        guard !workspaceId.isEmpty else {
            throw CLIError(message: "Workspace target not found")
        }
        let paneId: String
        if let paneSelector {
            paneId = try tmuxCanonicalPaneId(paneSelector, workspaceId: workspaceId, client: client)
        } else if tmuxResolvedCallerWorkspaceId(client: client) == workspaceId,
                  let callerPane = tmuxCallerPaneHandle(),
                  let callerPaneId = try? tmuxCanonicalPaneId(callerPane, workspaceId: workspaceId, client: client) {
            paneId = callerPaneId
        } else {
            paneId = try tmuxFocusedPaneId(workspaceId: workspaceId, client: client)
        }
        return (workspaceId, paneId)
    }

    private func tmuxSelectedSurfaceId(
        workspaceId: String,
        paneId: String,
        client: SocketClient
    ) throws -> String {
        let payload = try client.sendV2(
            method: V2MethodNames.paneSurfaces,
            params: ["workspace_id": workspaceId, "pane_id": paneId]
        )
        let surfaces = payload["surfaces"] as? [[String: Any]] ?? []
        if let selected = surfaces.first(where: { ($0["selected"] as? Bool) == true }),
           let id = selected["id"] as? String {
            return id
        }
        if let first = surfaces.first?["id"] as? String {
            return first
        }
        throw CLIError(message: "Pane has no surface to target")
    }

    private func tmuxResolveSurfaceTarget(
        _ raw: String?,
        client: SocketClient
    ) throws -> (workspaceId: String, paneId: String?, surfaceId: String) {
        if tmuxPaneSelector(from: raw) != nil {
            let resolved = try tmuxResolvePaneTarget(raw, client: client)
            // When the target pane matches the caller's pane, prefer the caller's
            // exact surface (PROGRAMA_SURFACE_ID) over the pane's currently selected
            // surface. The selected surface can change (e.g. tab switches) after
            // claude-teams started, but the caller surface stays fixed.
            let callerPane = tmuxCallerPaneHandle()
            let callerSurface = tmuxCallerSurfaceHandle()
            let canonicalCallerPane = callerPane.flatMap { try? tmuxCanonicalPaneId($0, workspaceId: resolved.workspaceId, client: client) }
            let paneMatch = callerPane != nil && (resolved.paneId == callerPane! || resolved.paneId == canonicalCallerPane)
            if paneMatch,
               let callerSurface,
               let surfaceId = try? tmuxCanonicalSurfaceId(
                    callerSurface,
                    workspaceId: resolved.workspaceId,
                    client: client
               ) {
                return (resolved.workspaceId, resolved.paneId, surfaceId)
            }
            let surfaceId = try tmuxSelectedSurfaceId(
                workspaceId: resolved.workspaceId,
                paneId: resolved.paneId,
                client: client
            )
            return (resolved.workspaceId, resolved.paneId, surfaceId)
        }

        let workspaceId = try tmuxResolveWorkspaceTarget(tmuxWindowSelector(from: raw), client: client)
        if tmuxWindowSelector(from: raw) == nil,
           tmuxResolvedCallerWorkspaceId(client: client) == workspaceId,
           let callerSurface = tmuxCallerSurfaceHandle(),
           let surfaceId = try? tmuxCanonicalSurfaceId(
                callerSurface,
                workspaceId: workspaceId,
                client: client
           ) {
            return (workspaceId, nil, surfaceId)
        }
        let surfaceId = try resolveSurfaceId(nil, workspaceId: workspaceId, client: client)
        return (workspaceId, nil, surfaceId)
    }

    private func tmuxRenderFormat(
        _ format: String?,
        context: [String: String],
        fallback: String
    ) -> String {
        guard let format, !format.isEmpty else { return fallback }
        var rendered = format
        for (key, value) in context {
            rendered = rendered.replacingOccurrences(of: "#{\(key)}", with: value)
        }
        rendered = rendered.replacingOccurrences(
            of: "#\\{[^}]+\\}",
            with: "",
            options: .regularExpression
        )
        let trimmed = rendered.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private func tmuxFormatContext(
        workspaceId: String,
        paneId: String? = nil,
        surfaceId: String? = nil,
        client: SocketClient
    ) throws -> [String: String] {
        let canonicalWorkspaceId = try resolveWorkspaceId(workspaceId, client: client)
        var context: [String: String] = [
            "session_name": "programa",
            "window_id": "@\(canonicalWorkspaceId)",
            "window_uuid": canonicalWorkspaceId
        ]

        let workspaceItems = try tmuxWorkspaceItems(client: client)
        if let workspace = workspaceItems.first(where: {
            ($0["id"] as? String) == canonicalWorkspaceId || ($0["ref"] as? String) == workspaceId
        }) {
            if let index = intFromAny(workspace["index"]) {
                context["window_index"] = String(index)
            }
            let title = ((workspace["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty {
                context["window_name"] = title
            }
        }

        let currentPayload = try client.sendV2(method: V2MethodNames.surfaceCurrent, params: ["workspace_id": canonicalWorkspaceId])
        let resolvedPaneId: String? = try {
            if let paneId {
                return try tmuxCanonicalPaneId(paneId, workspaceId: canonicalWorkspaceId, client: client)
            }
            if let currentPaneId = currentPayload["pane_id"] as? String {
                return currentPaneId
            }
            if let currentPaneRef = currentPayload["pane_ref"] as? String {
                return try tmuxCanonicalPaneId(currentPaneRef, workspaceId: canonicalWorkspaceId, client: client)
            }
            return nil
        }()
        let resolvedSurfaceId: String? = try {
            if let surfaceId {
                return try tmuxCanonicalSurfaceId(surfaceId, workspaceId: canonicalWorkspaceId, client: client)
            }
            if let resolvedPaneId {
                return try tmuxSelectedSurfaceId(
                    workspaceId: canonicalWorkspaceId,
                    paneId: resolvedPaneId,
                    client: client
                )
            }
            return currentPayload["surface_id"] as? String
        }()

        if let resolvedPaneId {
            context["pane_id"] = "%\(resolvedPaneId)"
            context["pane_uuid"] = resolvedPaneId
            let panePayload = try client.sendV2(method: V2MethodNames.paneList, params: ["workspace_id": canonicalWorkspaceId])
            let panes = panePayload["panes"] as? [[String: Any]] ?? []
            if let pane = panes.first(where: { ($0["id"] as? String) == resolvedPaneId }),
               let index = intFromAny(pane["index"]) {
                context["pane_index"] = String(index)
            }
        }

        if let resolvedSurfaceId {
            context["surface_id"] = resolvedSurfaceId
            let surfacePayload = try client.sendV2(method: V2MethodNames.surfaceList, params: ["workspace_id": canonicalWorkspaceId])
            let surfaces = surfacePayload["surfaces"] as? [[String: Any]] ?? []
            if let surface = surfaces.first(where: { ($0["id"] as? String) == resolvedSurfaceId }) {
                let title = ((surface["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty {
                    context["pane_title"] = title
                    context["window_name"] = context["window_name"] ?? title
                }
            }
        }

        return context
    }

    /// Enrich a tmux format context dictionary with pane geometry data from the
    /// enriched pane.list response. Computes character-cell positions from pixel
    /// frames and cell dimensions so tmux format variables like #{pane_width},
    /// #{pane_height}, #{pane_left}, #{pane_top}, #{window_width}, #{window_height}
    /// render correctly.
    private func tmuxEnrichContextWithGeometry(
        _ context: inout [String: String],
        pane: [String: Any],
        containerFrame: [String: Any]?
    ) {
        let isFocused = (pane["focused"] as? Bool) == true
        context["pane_active"] = isFocused ? "1" : "0"

        guard let columns = pane["columns"] as? Int,
              let rows = pane["rows"] as? Int else { return }

        context["pane_width"] = String(columns)
        context["pane_height"] = String(rows)

        let cellW = pane["cell_width_px"] as? Int ?? 0
        let cellH = pane["cell_height_px"] as? Int ?? 0
        guard cellW > 0, cellH > 0 else { return }

        if let frame = pane["pixel_frame"] as? [String: Any] {
            let px = frame["x"] as? Double ?? 0
            let py = frame["y"] as? Double ?? 0
            context["pane_left"] = String(Int(px) / cellW)
            context["pane_top"] = String(Int(py) / cellH)
        }

        if let cf = containerFrame {
            let cw = cf["width"] as? Double ?? 0
            let ch = cf["height"] as? Double ?? 0
            context["window_width"] = String(max(Int(cw) / cellW, 1))
            context["window_height"] = String(max(Int(ch) / cellH, 1))
        }
    }

    private func tmuxShellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private func tmuxShellCommandText(commandTokens: [String], cwd: String?) -> String? {
        let trimmedCwd = cwd?.trimmingCharacters(in: .whitespacesAndNewlines)
        let commandText = commandTokens.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard (trimmedCwd?.isEmpty == false) || !commandText.isEmpty else {
            return nil
        }

        var pieces: [String] = []
        if let trimmedCwd, !trimmedCwd.isEmpty {
            pieces.append("cd -- \(tmuxShellQuote(resolvePath(trimmedCwd)))")
        }
        if !commandText.isEmpty {
            pieces.append(commandText)
        }
        return pieces.joined(separator: " && ") + "\r"
    }

    private func tmuxSpecialKeyText(_ token: String) -> String? {
        switch token.lowercased() {
        case "enter", "c-m", "kpenter":
            return "\r"
        case "tab", "c-i":
            return "\t"
        case "space":
            return " "
        case "bspace", "backspace":
            return "\u{7f}"
        case "escape", "esc", "c-[":
            return "\u{1b}"
        case "c-c":
            return "\u{03}"
        case "c-d":
            return "\u{04}"
        case "c-z":
            return "\u{1a}"
        case "c-l":
            return "\u{0c}"
        default:
            return nil
        }
    }

    private func tmuxSendKeysText(from tokens: [String], literal: Bool) -> String {
        if literal {
            return tokens.joined(separator: " ")
        }

        var result = ""
        var pendingSpace = false
        for token in tokens {
            if let special = tmuxSpecialKeyText(token) {
                result += special
                pendingSpace = false
                continue
            }
            if pendingSpace {
                result += " "
            }
            result += token
            pendingSpace = true
        }
        return result
    }

    private func prependPathEntries(_ newEntries: [String], to currentPath: String?) -> String {
        var ordered: [String] = []
        var seen: Set<String> = []
        for entry in newEntries + (currentPath?.split(separator: ":").map(String.init) ?? []) where !entry.isEmpty {
            if seen.insert(entry).inserted {
                ordered.append(entry)
            }
        }
        return ordered.joined(separator: ":")
    }

    struct TmuxCompatFocusedContext {
        let socketPath: String
        let workspaceId: String
        let windowId: String?
        let paneHandle: String
        let paneId: String?
        let surfaceId: String?
    }

    private func tmuxCompatResolvedSocketPath(processEnvironment: [String: String]) -> String {
        let envSocketPath: String? = {
            for key in ["PROGRAMA_SOCKET_PATH", "PROGRAMA_SOCKET"] {
                guard let raw = processEnvironment[key] else { continue }
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
            return nil
        }()

        let requestedSocketPath = envSocketPath ?? CLISocketPathResolver.defaultSocketPath
        let source: CLISocketPathSource
        if let envSocketPath {
            source = CLISocketPathResolver.isImplicitDefaultPath(envSocketPath) ? .implicitDefault : .environment
        } else {
            source = .implicitDefault
        }

        return CLISocketPathResolver.resolve(
            requestedPath: requestedSocketPath,
            source: source,
            environment: processEnvironment
        )
    }

    func tmuxCompatFocusedContext(
        processEnvironment: [String: String],
        explicitPassword: String?
    ) -> TmuxCompatFocusedContext? {
        let socketPath = tmuxCompatResolvedSocketPath(processEnvironment: processEnvironment)
        let client = SocketClient(path: socketPath)

        do {
            try client.connect()
            try authenticateClientIfNeeded(
                client,
                explicitPassword: explicitPassword,
                socketPath: socketPath
            )
            defer { client.close() }

            let payload = try client.sendV2(method: V2MethodNames.systemIdentify)
            let focused = payload["focused"] as? [String: Any] ?? [:]

            let workspaceId = (focused["workspace_id"] as? String)
                ?? (focused["workspace_ref"] as? String)
            let paneId = (focused["pane_id"] as? String)
                ?? (focused["pane_ref"] as? String)

            guard let workspaceId, let paneId else {
                return nil
            }

            let paneHandle = paneId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !paneHandle.isEmpty else {
                return nil
            }

            let windowId = (focused["window_id"] as? String)
                ?? (focused["window_ref"] as? String)
            let surfaceId = (focused["surface_id"] as? String)
                ?? (focused["surface_ref"] as? String)

            return TmuxCompatFocusedContext(
                socketPath: socketPath,
                workspaceId: workspaceId,
                windowId: windowId,
                paneHandle: paneHandle,
                paneId: focused["pane_id"] as? String,
                surfaceId: surfaceId
            )
        } catch {
            client.close()
            return nil
        }
    }

    func configureTmuxCompatEnvironment(
        processEnvironment: [String: String],
        shimDirectory: URL,
        executablePath: String,
        socketPath: String,
        explicitPassword: String?,
        focusedContext: TmuxCompatFocusedContext?,
        tmuxPathPrefix: String,
        programaBinEnvVar: String,
        termOverrideEnvVar: String,
        extraEnvVars: [(key: String, value: String)] = []
    ) {
        let updatedPath = prependPathEntries(
            [shimDirectory.path],
            to: processEnvironment["PATH"]
        )
        let fakeTmuxValue: String = {
            if let focusedContext {
                let windowToken = focusedContext.windowId ?? focusedContext.workspaceId
                return "/tmp/\(tmuxPathPrefix)/\(focusedContext.workspaceId),\(windowToken),\(focusedContext.paneHandle)"
            }
            return processEnvironment["TMUX"] ?? "/tmp/\(tmuxPathPrefix)/default,0,0"
        }()
        let fakeTmuxPane = focusedContext.map { "%\($0.paneHandle)" }
            ?? processEnvironment["TMUX_PANE"]
            ?? "%1"
        let fakeTerm = processEnvironment[termOverrideEnvVar] ?? "screen-256color"

        setenv(programaBinEnvVar, executablePath, 1)
        setenv("PATH", updatedPath, 1)
        setenv("TMUX", fakeTmuxValue, 1)
        setenv("TMUX_PANE", fakeTmuxPane, 1)
        setenv("TERM", fakeTerm, 1)
        setenv("PROGRAMA_SOCKET_PATH", socketPath, 1)
        setenv("PROGRAMA_SOCKET", socketPath, 1)
        if let explicitPassword,
           !explicitPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            setenv("PROGRAMA_SOCKET_PASSWORD", explicitPassword, 1)
        }
        unsetenv("TERM_PROGRAM")
        for envVar in extraEnvVars {
            setenv(envVar.key, envVar.value, 1)
        }
        if let focusedContext {
            setenv("PROGRAMA_WORKSPACE_ID", focusedContext.workspaceId, 1)
            if let surfaceId = focusedContext.surfaceId, !surfaceId.isEmpty {
                setenv("PROGRAMA_SURFACE_ID", surfaceId, 1)
            }
        }
    }

    func createTmuxCompatShimDirectory(
        directoryName: String,
        tmuxShimScript: String
    ) throws -> URL {
        let homePath = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        let root = URL(fileURLWithPath: homePath, isDirectory: true)
            .appendingPathComponent(".programa", isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: nil)
        let tmuxURL = root.appendingPathComponent("tmux", isDirectory: false)
        try writeShimIfChanged(tmuxShimScript, to: tmuxURL)
        return root
    }

    func runClaudeTeamsTmuxCompat(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        let (command, rawArgs) = try splitTmuxCommand(commandArgs)

        switch command {
        case "new-session", "new":
            let parsed = try parseTmuxArguments(
                rawArgs,
                valueFlags: ["-c", "-F", "-n", "-s"],
                boolFlags: ["-A", "-d", "-P"]
            )
            if parsed.hasFlag("-A") {
                throw CLIError(message: "new-session -A is not supported in programa claude-teams mode")
            }
            var params: [String: Any] = ["focus": false]
            if let cwd = parsed.value("-c") {
                params["cwd"] = resolvePath(cwd)
            }
            let created = try client.sendV2(method: V2MethodNames.workspaceCreate, params: params)
            guard let workspaceId = created["workspace_id"] as? String else {
                throw CLIError(message: "workspace.create did not return workspace_id")
            }
            if let title = parsed.value("-n") ?? parsed.value("-s"),
               !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                _ = try client.sendV2(method: V2MethodNames.workspaceRename, params: [
                    "workspace_id": workspaceId,
                    "title": title
                ])
            }
            if let text = tmuxShellCommandText(commandTokens: parsed.positional, cwd: parsed.value("-c")) {
                let surfaceId = try resolveSurfaceId(nil, workspaceId: workspaceId, client: client)
                _ = try client.sendV2(method: V2MethodNames.surfaceSendText, params: [
                    "workspace_id": workspaceId,
                    "surface_id": surfaceId,
                    "text": text
                ])
            }
            if parsed.hasFlag("-P") {
                let context = try tmuxFormatContext(workspaceId: workspaceId, client: client)
                print(tmuxRenderFormat(parsed.value("-F"), context: context, fallback: "@\(workspaceId)"))
            }

        case "new-window", "neww":
            let parsed = try parseTmuxArguments(
                rawArgs,
                valueFlags: ["-c", "-F", "-n", "-t"],
                boolFlags: ["-d", "-P"]
            )
            if parsed.value("-t") != nil {
                throw CLIError(message: "new-window -t is not supported in programa claude-teams mode")
            }
            let parentWorkspaceId: String
            if let callerWorkspaceId = tmuxResolvedCallerWorkspaceId(client: client) {
                parentWorkspaceId = callerWorkspaceId
            } else {
                parentWorkspaceId = try tmuxResolveWorkspaceTarget(nil, client: client)
            }
            let requestedTitle = parsed.value("-n")?.trimmingCharacters(in: .whitespacesAndNewlines)
            let task = requestedTitle.flatMap { $0.isEmpty ? nil : $0 }
                ?? String(localized: "agentOverview.helper", defaultValue: "Helper")
            var params: [String: Any] = [
                "parent_workspace_id": parentWorkspaceId,
                "host": "claude-teams",
                "task": task,
            ]
            if let initialCommand = tmuxShellCommandText(
                commandTokens: parsed.positional,
                cwd: parsed.value("-c")
            ) {
                params["initial_command"] = initialCommand
            }
            let created = try client.sendV2(method: V2MethodNames.agentSpawn, params: params)
            guard let workspaceId = created["workspace_id"] as? String else {
                throw CLIError(message: "agent.spawn did not return workspace_id")
            }
            if parsed.hasFlag("-P") {
                guard let surfaceId = created["surface_id"] as? String else {
                    throw CLIError(message: "agent.spawn did not return surface_id")
                }
                let context = try tmuxFormatContext(
                    workspaceId: workspaceId,
                    surfaceId: surfaceId,
                    client: client
                )
                print(tmuxRenderFormat(parsed.value("-F"), context: context, fallback: "@\(workspaceId)"))
            }

        case "split-window", "splitw":
            let parsed = try parseTmuxArguments(
                rawArgs,
                valueFlags: ["-c", "-F", "-l", "-t"],
                boolFlags: ["-P", "-b", "-d", "-h", "-v"]
            )
            let requestedTarget = try tmuxResolveSurfaceTarget(parsed.value("-t"), client: client)
            let parentWorkspaceId = tmuxResolvedCallerWorkspaceId(client: client)
                ?? requestedTarget.workspaceId
            var createParams: [String: Any] = [
                "parent_workspace_id": parentWorkspaceId,
                "host": "claude-teams",
                "task": String(localized: "agentOverview.helper", defaultValue: "Helper"),
            ]
            if let initialCommand = tmuxShellCommandText(
                commandTokens: parsed.positional,
                cwd: parsed.value("-c")
            ) {
                createParams["initial_command"] = initialCommand
            }
            let created = try client.sendV2(method: V2MethodNames.agentSpawn, params: createParams)
            guard let workspaceId = created["workspace_id"] as? String else {
                throw CLIError(message: "agent.spawn did not return workspace_id")
            }
            guard let surfaceId = created["surface_id"] as? String else {
                throw CLIError(message: "agent.spawn did not return surface_id")
            }
            if parsed.hasFlag("-P") {
                let context = try tmuxFormatContext(
                    workspaceId: workspaceId,
                    surfaceId: surfaceId,
                    client: client
                )
                let fallback = context["pane_id"] ?? surfaceId
                print(tmuxRenderFormat(parsed.value("-F"), context: context, fallback: fallback))
            }

        case "select-window", "selectw":
            let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-t"], boolFlags: [])
            let workspaceId = try tmuxResolveWorkspaceTarget(parsed.value("-t"), client: client)
            _ = try client.sendV2(method: V2MethodNames.workspaceSelect, params: ["workspace_id": workspaceId])

        case "select-pane", "selectp":
            let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-P", "-T", "-t"], boolFlags: [])
            if parsed.value("-P") != nil || parsed.value("-T") != nil {
                return
            }
            let target = try tmuxResolvePaneTarget(parsed.value("-t"), client: client)
            _ = try client.sendV2(method: V2MethodNames.paneFocus, params: [
                "workspace_id": target.workspaceId,
                "pane_id": target.paneId
            ])

        case "kill-window", "killw":
            let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-t"], boolFlags: [])
            let workspaceId = try tmuxResolveWorkspaceTarget(parsed.value("-t"), client: client)
            let workspaceItems = try tmuxWorkspaceItems(client: client)
            for descendantId in tmuxDescendantWorkspaceIds(
                of: workspaceId,
                workspaceItems: workspaceItems
            ) {
                try tmuxCloseHelperWorkspace(workspaceId: descendantId, client: client)
            }
            let workspaceItem = workspaceItems.first { ($0["id"] as? String) == workspaceId }
            if (workspaceItem?["agent_parent_workspace_id"] as? String) != nil {
                try tmuxCloseHelperWorkspace(workspaceId: workspaceId, client: client)
            } else {
                _ = try client.sendV2(method: V2MethodNames.workspaceClose, params: ["workspace_id": workspaceId])
            }

        case "kill-pane", "killp":
            let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-t"], boolFlags: [])
            let target = try tmuxResolveSurfaceTarget(parsed.value("-t"), client: client)
            let panePayload = try client.sendV2(method: V2MethodNames.paneList, params: [
                "workspace_id": target.workspaceId,
            ])
            let panes = panePayload["panes"] as? [[String: Any]] ?? []
            let workspaceItems = try tmuxWorkspaceItems(client: client)
            let targetItem = workspaceItems.first { ($0["id"] as? String) == target.workspaceId }
            let closedTeamWorkspace = panes.count <= 1
                && targetItem.map { tmuxIsClaudeTeamWorkspace($0) } == true
            if closedTeamWorkspace {
                for descendantId in tmuxDescendantWorkspaceIds(
                    of: target.workspaceId,
                    workspaceItems: workspaceItems
                ) {
                    try tmuxCloseHelperWorkspace(workspaceId: descendantId, client: client)
                }
                try tmuxCloseHelperWorkspace(workspaceId: target.workspaceId, client: client)
            }
            if !closedTeamWorkspace {
                _ = try client.sendV2(method: V2MethodNames.surfaceClose, params: [
                    "workspace_id": target.workspaceId,
                    "surface_id": target.surfaceId
                ])
                // Re-equalize ordinary multi-pane workspaces after removing a pane.
                _ = try? client.sendV2(method: V2MethodNames.workspaceEqualizeSplits, params: [
                    "workspace_id": target.workspaceId,
                    "orientation": "vertical"
                ])
            }

        case "send-keys", "send":
            let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-t"], boolFlags: ["-l"])
            let target = try tmuxResolveSurfaceTarget(parsed.value("-t"), client: client)
            let text = tmuxSendKeysText(from: parsed.positional, literal: parsed.hasFlag("-l"))
            if !text.isEmpty {
                _ = try client.sendV2(method: V2MethodNames.surfaceSendText, params: [
                    "workspace_id": target.workspaceId,
                    "surface_id": target.surfaceId,
                    "text": text
                ])
            }

        case "capture-pane", "capturep":
            let parsed = try parseTmuxArguments(
                rawArgs,
                valueFlags: ["-E", "-S", "-t"],
                boolFlags: ["-J", "-N", "-p"]
            )
            let target = try tmuxResolveSurfaceTarget(parsed.value("-t"), client: client)
            var params: [String: Any] = [
                "workspace_id": target.workspaceId,
                "surface_id": target.surfaceId,
                "scrollback": true
            ]
            if let start = parsed.value("-S"), let lines = Int(start), lines < 0 {
                params["lines"] = abs(lines)
            }
            let payload = try client.sendV2(method: V2MethodNames.surfaceReadText, params: params)
            let text = (payload["text"] as? String) ?? ""
            if parsed.hasFlag("-p") {
                print(text)
            } else {
                _ = try updateTmuxCompatStore { store in
                    store.buffers["default"] = text
                }
            }

        case "display-message", "display", "displayp":
            let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-F", "-t"], boolFlags: ["-p"])
            let target = try tmuxResolveSurfaceTarget(parsed.value("-t"), client: client)
            var context = try tmuxFormatContext(
                workspaceId: target.workspaceId,
                paneId: target.paneId,
                surfaceId: target.surfaceId,
                client: client
            )
            // Enrich with geometry for format strings like #{pane_width},#{window_width}
            let panePayload = try client.sendV2(method: V2MethodNames.paneList, params: ["workspace_id": target.workspaceId])
            let panesList = panePayload["panes"] as? [[String: Any]] ?? []
            let containerFrame = panePayload["container_frame"] as? [String: Any]
            if let targetPaneId = target.paneId,
               let matchingPane = panesList.first(where: { ($0["id"] as? String) == targetPaneId }) {
                tmuxEnrichContextWithGeometry(&context, pane: matchingPane, containerFrame: containerFrame)
            } else if let firstPane = panesList.first(where: { ($0["focused"] as? Bool) == true }) ?? panesList.first {
                tmuxEnrichContextWithGeometry(&context, pane: firstPane, containerFrame: containerFrame)
            }
            let format = parsed.positional.isEmpty ? parsed.value("-F") : parsed.positional.joined(separator: " ")
            let rendered = tmuxRenderFormat(format, context: context, fallback: "")
            if parsed.hasFlag("-p") || !rendered.isEmpty {
                print(rendered)
            }

        case "list-windows", "lsw":
            let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-F", "-t"], boolFlags: [])
            let items = try tmuxWorkspaceItems(client: client)
            for item in items {
                guard let workspaceId = item["id"] as? String else { continue }
                let context = try tmuxFormatContext(workspaceId: workspaceId, client: client)
                let fallback = [
                    context["window_index"] ?? "?",
                    context["window_name"] ?? workspaceId
                ].joined(separator: " ")
                print(tmuxRenderFormat(parsed.value("-F"), context: context, fallback: fallback))
            }

        case "list-panes", "lsp":
            let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-F", "-t"], boolFlags: [])
            // Resolve target: can be a pane (%uuid) or workspace. In tmux,
            // list-panes -t %<pane> lists all panes in the window containing that pane.
            let workspaceId: String
            if let target = parsed.value("-t"), tmuxPaneSelector(from: target) != nil {
                let paneTarget = try tmuxResolvePaneTarget(target, client: client)
                workspaceId = paneTarget.workspaceId
            } else {
                workspaceId = try tmuxResolveWorkspaceTarget(parsed.value("-t"), client: client)
            }
            let workspaceItems = try tmuxWorkspaceItems(client: client)
            let workspaceIds = tmuxTeamWorkspaceIds(
                containing: workspaceId,
                workspaceItems: workspaceItems
            )
            for listedWorkspaceId in workspaceIds {
                let payload = try client.sendV2(method: V2MethodNames.paneList, params: ["workspace_id": listedWorkspaceId])
                let panes = payload["panes"] as? [[String: Any]] ?? []
                let containerFrame = payload["container_frame"] as? [String: Any]
                for pane in panes {
                    guard let paneId = pane["id"] as? String else { continue }
                    var context = try tmuxFormatContext(
                        workspaceId: listedWorkspaceId,
                        paneId: paneId,
                        client: client
                    )
                    tmuxEnrichContextWithGeometry(&context, pane: pane, containerFrame: containerFrame)
                    let fallback = context["pane_id"] ?? paneId
                    print(tmuxRenderFormat(parsed.value("-F"), context: context, fallback: fallback))
                }
            }

        case "rename-window", "renamew":
            let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-t"], boolFlags: [])
            let title = parsed.positional.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else {
                throw CLIError(message: "rename-window requires a title")
            }
            let workspaceId = try tmuxResolveWorkspaceTarget(parsed.value("-t"), client: client)
            _ = try client.sendV2(method: V2MethodNames.workspaceRename, params: [
                "workspace_id": workspaceId,
                "title": title
            ])

        case "resize-pane", "resizep":
            let parsed = try parseTmuxArguments(
                rawArgs,
                valueFlags: ["-t", "-x", "-y"],
                boolFlags: ["-D", "-L", "-R", "-U"]
            )
            let hasDirectionalFlags = parsed.hasFlag("-L")
                || parsed.hasFlag("-R")
                || parsed.hasFlag("-U")
                || parsed.hasFlag("-D")
            let target = try tmuxResolvePaneTarget(parsed.value("-t"), client: client)

            if !hasDirectionalFlags, let absWidth = parsed.value("-x").flatMap({ Int($0.replacingOccurrences(of: "%", with: "")) }) {
                // Absolute width: resize-pane -t <pane> -x <columns>
                // Compute pixel delta from current width to desired width.
                let panePayload = try client.sendV2(method: V2MethodNames.paneList, params: ["workspace_id": target.workspaceId])
                let panes = panePayload["panes"] as? [[String: Any]] ?? []
                if let matchingPane = panes.first(where: { ($0["id"] as? String) == target.paneId }),
                   let cellW = matchingPane["cell_width_px"] as? Int, cellW > 0,
                   let currentCols = matchingPane["columns"] as? Int {
                    let delta = absWidth - currentCols
                    if delta != 0 {
                        _ = try? client.sendV2(method: V2MethodNames.paneResize, params: [
                            "workspace_id": target.workspaceId,
                            "pane_id": target.paneId,
                            "direction": delta > 0 ? "right" : "left",
                            "amount": abs(delta) * cellW
                        ])
                    }
                }
            } else if hasDirectionalFlags {
                let direction: String
                if parsed.hasFlag("-L") {
                    direction = "left"
                } else if parsed.hasFlag("-U") {
                    direction = "up"
                } else if parsed.hasFlag("-D") {
                    direction = "down"
                } else {
                    direction = "right"
                }
                let rawAmount = (parsed.value("-x") ?? parsed.value("-y") ?? "5")
                    .replacingOccurrences(of: "%", with: "")
                let amount = Int(rawAmount) ?? 5
                _ = try client.sendV2(method: V2MethodNames.paneResize, params: [
                    "workspace_id": target.workspaceId,
                    "pane_id": target.paneId,
                    "direction": direction,
                    "amount": max(1, amount)
                ])
            }

        case "wait-for":
            try runTmuxCompatCommand(
                command: "wait-for",
                commandArgs: rawArgs,
                client: client,
                jsonOutput: jsonOutput,
                idFormat: idFormat,
                windowOverride: windowOverride
            )

        case "last-pane":
            let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-t"], boolFlags: [])
            let workspaceId = try tmuxResolveWorkspaceTarget(parsed.value("-t"), client: client)
            _ = try client.sendV2(method: V2MethodNames.paneLast, params: ["workspace_id": workspaceId])

        case "show-buffer", "showb":
            let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-b"], boolFlags: [])
            let name = parsed.value("-b") ?? "default"
            let store = loadTmuxCompatStore()
            if let buffer = store.buffers[name] {
                print(buffer)
            }

        case "save-buffer", "saveb":
            let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-b"], boolFlags: [])
            let name = parsed.value("-b") ?? "default"
            let store = loadTmuxCompatStore()
            guard let buffer = store.buffers[name] else {
                throw CLIError(message: "Buffer not found: \(name)")
            }
            if let outputPath = parsed.positional.last, !outputPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try buffer.write(toFile: resolvePath(outputPath), atomically: true, encoding: .utf8)
            } else {
                print(buffer)
            }

        case "last-window", "next-window", "previous-window", "set-hook", "set-buffer", "list-buffers":
            try runTmuxCompatCommand(
                command: command,
                commandArgs: rawArgs,
                client: client,
                jsonOutput: jsonOutput,
                idFormat: idFormat,
                windowOverride: windowOverride
            )

        case "has-session", "has":
            let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-t"], boolFlags: [])
            _ = try tmuxResolveWorkspaceTarget(parsed.value("-t"), client: client)

        case "select-layout":
            let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-t"], boolFlags: [])
            let layoutName = parsed.positional.first ?? ""
            // select-layout -t accepts pane targets (e.g. %1) in real tmux.
            // Try pane target first, then workspace target. Only fall back to
            // the caller's current workspace when no -t was provided; an
            // explicit -t that fails to resolve should error, not silently
            // apply to the wrong workspace.
            let workspaceId: String = {
                if let target = parsed.value("-t") {
                    if let resolved = try? tmuxResolvePaneTarget(target, client: client) {
                        return resolved.workspaceId
                    }
                    return (try? tmuxResolveWorkspaceTarget(target, client: client)) ?? ""
                }
                return (try? tmuxResolveWorkspaceTarget(nil, client: client)) ?? ""
            }()
            guard !workspaceId.isEmpty else {
                throw CLIError(message: "Could not resolve workspace for select-layout")
            }
            if layoutName == "main-vertical" || layoutName == "main-horizontal" {
                // Preserve tmux's requested main-axis layout when equalizing the workspace.
                let orientation = layoutName == "main-vertical" ? "vertical" : "horizontal"
                _ = try? client.sendV2(method: V2MethodNames.workspaceEqualizeSplits, params: [
                    "workspace_id": workspaceId,
                    "orientation": orientation
                ])
            } else {
                // Tiled and even layouts equalize every split.
                _ = try? client.sendV2(method: V2MethodNames.workspaceEqualizeSplits, params: ["workspace_id": workspaceId])
            }

        case "set-option", "set", "set-window-option", "setw", "source-file", "refresh-client", "attach-session", "detach-client":
            return

        case "-V", "-v":
            print("tmux 3.4")
            return

        default:
            throw CLIError(message: "Unsupported tmux compatibility command: \(command)")
        }
    }

    private struct TmuxCompatStore: Codable {
        var buffers: [String: String] = [:]
        var hooks: [String: String] = [:]
    }

    private func tmuxCompatStoreURL() -> URL {
        let homePath = ProcessInfo.processInfo.environment["HOME"]
            ?? NSString(string: "~").expandingTildeInPath
        return URL(fileURLWithPath: homePath)
            .appendingPathComponent(".programa")
            .appendingPathComponent("tmux-compat-store.json")
    }

    private func loadTmuxCompatStore() -> TmuxCompatStore {
        let url = tmuxCompatStoreURL()
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(TmuxCompatStore.self, from: data) else {
            return TmuxCompatStore()
        }
        return decoded
    }

    private func saveTmuxCompatStore(_ store: TmuxCompatStore) throws {
        let url = tmuxCompatStoreURL()
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: nil)
        let data = try JSONEncoder().encode(store)
        try data.write(to: url, options: .atomic)
    }

    private func updateTmuxCompatStore<T>(
        _ body: (inout TmuxCompatStore) throws -> T
    ) throws -> T {
        let storeURL = tmuxCompatStoreURL()
        let parent = storeURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: nil)
        let lockPath = storeURL.path + ".lock"
        let descriptor = lockPath.withCString {
            Darwin.open($0, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        }
        guard descriptor >= 0 else {
            throw CLIError(message: "Failed to open tmux compatibility state lock: \(lockPath)")
        }
        defer { Darwin.close(descriptor) }

        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw CLIError(message: "Tmux compatibility state lock is not a regular file: \(lockPath)")
        }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw CLIError(message: "Failed to lock tmux compatibility state: \(lockPath)")
        }
        defer { _ = flock(descriptor, LOCK_UN) }

        var store = loadTmuxCompatStore()
        let result = try body(&store)
        try saveTmuxCompatStore(store)
        return result
    }

    private func runShellCommand(_ command: String, stdinText: String) throws -> (status: Int32, stdout: String, stderr: String) {
        let result = CLIProcessRunner.runProcess(
            executablePath: "/bin/zsh",
            arguments: ["-lc", command],
            stdinText: stdinText
        )
        return (result.status, result.stdout, result.stderr)
    }

    private func tmuxWaitForSignalURL(name: String, socketIdentity: String) throws -> URL {
        let runtimeDirectory = try tmuxWaitForRuntimeDirectory()
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let sanitized = name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let sessionHash = SHA256.hash(data: Data(socketIdentity.utf8)).prefix(8)
            .map { String(format: "%02x", $0) }.joined()
        let nameHash = SHA256.hash(data: Data(name.utf8)).prefix(8)
            .map { String(format: "%02x", $0) }.joined()
        return runtimeDirectory.appendingPathComponent(
            "\(sessionHash)-\(String(sanitized))-\(nameHash).sig",
            isDirectory: false
        )
    }

    private func tmuxWaitForRuntimeDirectory() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        if let rawXDG = environment["XDG_RUNTIME_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawXDG.isEmpty,
           tmuxIsOwnedPrivateDirectory(rawXDG) {
            let programa = URL(fileURLWithPath: rawXDG, isDirectory: true)
                .appendingPathComponent("programa", isDirectory: true)
            let waitFor = programa.appendingPathComponent("wait-for", isDirectory: true)
            try tmuxEnsureOwnedPrivateDirectory(programa)
            try tmuxEnsureOwnedPrivateDirectory(waitFor)
            return waitFor
        }

        let rawHomePath = environment["HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let homePath = rawHomePath.isEmpty ? NSHomeDirectory() : rawHomePath
        let programa = URL(fileURLWithPath: homePath, isDirectory: true)
            .appendingPathComponent(".programa", isDirectory: true)
        let run = programa.appendingPathComponent("run", isDirectory: true)
        let waitFor = run.appendingPathComponent("wait-for", isDirectory: true)
        for directory in [programa, run, waitFor] {
            try tmuxEnsureOwnedPrivateDirectory(directory)
        }
        return waitFor
    }

    private func tmuxIsOwnedPrivateDirectory(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              info.st_uid == getuid(),
              (info.st_mode & 0o777) == 0o700 else {
            return false
        }
        return true
    }

    private func tmuxEnsureOwnedPrivateDirectory(_ url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            guard errno == ENOENT else {
                throw CLIError(message: "Failed to inspect wait-for runtime directory")
            }
            guard mkdir(url.path, 0o700) == 0 || errno == EEXIST else {
                throw CLIError(message: "Failed to create wait-for runtime directory")
            }
        }

        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_DIRECTORY)
        guard fd >= 0 else {
            throw CLIError(message: "Wait-for runtime path is not a real directory")
        }
        defer { Darwin.close(fd) }
        guard fstat(fd, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              info.st_uid == getuid() else {
            throw CLIError(message: "Wait-for runtime directory is not owned by the current user")
        }
        guard fchmod(fd, 0o700) == 0,
              fstat(fd, &info) == 0,
              (info.st_mode & 0o777) == 0o700 else {
            throw CLIError(message: "Failed to secure wait-for runtime directory")
        }
    }

    private func tmuxValidateWaitForSignal(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              info.st_uid == getuid(),
              (info.st_mode & 0o777) == 0o600 else {
            throw CLIError(message: "Wait-for signal is not a private file owned by the current user")
        }
    }

    private func tmuxWriteWaitForSignal(_ url: URL) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        if fd < 0, errno == EEXIST {
            try tmuxValidateWaitForSignal(url)
            return
        }
        guard fd >= 0 else {
            throw CLIError(message: "Failed to create wait-for signal")
        }
        let payload = Data("signal\n".utf8)
        do {
            try payload.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(fd, base.advanced(by: offset), bytes.count - offset)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else {
                        throw CLIError(message: "Failed to write wait-for signal")
                    }
                    offset += count
                }
            }
            guard fsync(fd) == 0 else {
                throw CLIError(message: "Failed to sync wait-for signal")
            }
        } catch {
            Darwin.close(fd)
            throw error
        }
        guard Darwin.close(fd) == 0 else {
            throw CLIError(message: "Failed to close wait-for signal")
        }
        try tmuxValidateWaitForSignal(url)
    }

    func runTmuxCompatCommand(
        command: String,
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        switch command {
        case "capture-pane":
            let (wsArg, rem0) = parseOption(commandArgs, name: "--workspace")
            let (sfArg, rem1) = parseOption(rem0, name: "--surface")
            let (linesArg, rem2) = parseOption(rem1, name: "--lines")
            let workspaceArg = wsArg ?? (windowOverride == nil ? ProcessInfo.processInfo.environment["PROGRAMA_WORKSPACE_ID"] : nil)
            let surfaceArg = sfArg ?? (wsArg == nil && windowOverride == nil ? ProcessInfo.processInfo.environment["PROGRAMA_SURFACE_ID"] : nil)

            var params: [String: Any] = [:]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let sfId = try normalizeSurfaceHandle(surfaceArg, client: client, workspaceHandle: wsId)
            if let sfId { params["surface_id"] = sfId }

            let includeScrollback = rem2.contains("--scrollback")
            if includeScrollback {
                params["scrollback"] = true
            }
            if let linesArg {
                guard let lineCount = Int(linesArg), lineCount > 0 else {
                    throw CLIError(message: "--lines must be greater than 0")
                }
                params["lines"] = lineCount
                params["scrollback"] = true
            }

            let payload = try client.sendV2(method: V2MethodNames.surfaceReadText, params: params)
            if jsonOutput {
                print(jsonString(payload))
            } else {
                print((payload["text"] as? String) ?? "")
            }

        case "resize-pane":
            let workspaceArg = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowOverride)
            let paneArg = optionValue(commandArgs, name: "--pane")
            let amountArg = optionValue(commandArgs, name: "--amount")
            let amount = Int(amountArg ?? "1") ?? 1
            if amount <= 0 {
                throw CLIError(message: "--amount must be greater than 0")
            }

            let direction: String = {
                if commandArgs.contains("-L") { return "left" }
                if commandArgs.contains("-R") { return "right" }
                if commandArgs.contains("-U") { return "up" }
                if commandArgs.contains("-D") { return "down" }
                return "right"
            }()

            var params: [String: Any] = ["direction": direction, "amount": amount]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let paneId = try normalizePaneHandle(paneArg, client: client, workspaceHandle: wsId, allowFocused: true)
            if let paneId { params["pane_id"] = paneId }
            let payload = try client.sendV2(method: V2MethodNames.paneResize, params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat, kinds: ["pane"]))

        case "pipe-pane":
            let workspaceArg = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowOverride)
            let surfaceArg = optionValue(commandArgs, name: "--surface")
            let (cmdOpt, rem0) = parseOption(commandArgs, name: "--command")
            let commandText: String = {
                if let cmdOpt { return cmdOpt }
                let trimmed = rem0.dropFirst(rem0.first == "--" ? 1 : 0).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed
            }()
            guard !commandText.isEmpty else {
                throw CLIError(message: "pipe-pane requires --command <shell-command>")
            }

            var params: [String: Any] = ["scrollback": true]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client, allowCurrent: true)
            if let wsId { params["workspace_id"] = wsId }
            let sfId = try normalizeSurfaceHandle(surfaceArg, client: client, workspaceHandle: wsId, allowFocused: true)
            if let sfId { params["surface_id"] = sfId }
            let payload = try client.sendV2(method: V2MethodNames.surfaceReadText, params: params)
            let text = (payload["text"] as? String) ?? ""
            let shell = try runShellCommand(commandText, stdinText: text)
            if shell.status != 0 {
                throw CLIError(message: "pipe-pane command failed (\(shell.status)): \(shell.stderr)")
            }
            if jsonOutput {
                print(jsonString([
                    "ok": true,
                    "status": shell.status,
                    "stdout": shell.stdout,
                    "stderr": shell.stderr
                ]))
            } else {
                if !shell.stdout.isEmpty {
                    print(shell.stdout, terminator: "")
                }
                print("OK")
            }

        case "wait-for":
            let signal = commandArgs.contains("-S") || commandArgs.contains("--signal")
            let timeoutRaw = optionValue(commandArgs, name: "--timeout")
            let timeout = timeoutRaw.flatMap { Double($0) } ?? 30.0
            let name = commandArgs.first(where: { !$0.hasPrefix("-") }) ?? ""
            guard !name.isEmpty else {
                throw CLIError(message: "wait-for requires a name")
            }
            let signalURL = try tmuxWaitForSignalURL(name: name, socketIdentity: client.socketPath)
            if signal {
                try tmuxWriteWaitForSignal(signalURL)
                print("OK")
                return
            }
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                var info = stat()
                if lstat(signalURL.path, &info) == 0 {
                    try tmuxValidateWaitForSignal(signalURL)
                    guard unlink(signalURL.path) == 0 else {
                        throw CLIError(message: "Failed to consume wait-for signal")
                    }
                    print("OK")
                    return
                }
                guard errno == ENOENT else {
                    throw CLIError(message: "Failed to inspect wait-for signal")
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
            throw CLIError(message: "wait-for timed out waiting for '\(name)'")

        case "swap-pane":
            let workspaceArg = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowOverride)
            guard let sourcePaneRaw = optionValue(commandArgs, name: "--pane") else {
                throw CLIError(message: "swap-pane requires --pane")
            }
            guard let targetPaneRaw = optionValue(commandArgs, name: "--target-pane") else {
                throw CLIError(message: "swap-pane requires --target-pane")
            }
            var params: [String: Any] = [:]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let sourcePane = try normalizePaneHandle(sourcePaneRaw, client: client, workspaceHandle: wsId)
            let targetPane = try normalizePaneHandle(targetPaneRaw, client: client, workspaceHandle: wsId)
            if let sourcePane { params["pane_id"] = sourcePane }
            if let targetPane { params["target_pane_id"] = targetPane }
            let payload = try client.sendV2(method: V2MethodNames.paneSwap, params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: "OK")

        case "break-pane":
            let workspaceArg = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowOverride)
            let paneArg = optionValue(commandArgs, name: "--pane")
            let surfaceArg = optionValue(commandArgs, name: "--surface")
            var params: [String: Any] = ["focus": !commandArgs.contains("--no-focus")]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let paneId = try normalizePaneHandle(paneArg, client: client, workspaceHandle: wsId)
            if let paneId { params["pane_id"] = paneId }
            let surfaceId = try normalizeSurfaceHandle(surfaceArg, client: client, workspaceHandle: wsId)
            if let surfaceId { params["surface_id"] = surfaceId }
            let payload = try client.sendV2(method: V2MethodNames.paneBreak, params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: "OK")

        case "join-pane":
            let workspaceArg = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowOverride)
            let sourcePaneArg = optionValue(commandArgs, name: "--pane")
            let surfaceArg = optionValue(commandArgs, name: "--surface")
            guard let targetPaneArg = optionValue(commandArgs, name: "--target-pane") else {
                throw CLIError(message: "join-pane requires --target-pane")
            }
            var params: [String: Any] = ["focus": !commandArgs.contains("--no-focus")]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let sourcePaneId = try normalizePaneHandle(sourcePaneArg, client: client, workspaceHandle: wsId)
            if let sourcePaneId { params["pane_id"] = sourcePaneId }
            let targetPaneId = try normalizePaneHandle(targetPaneArg, client: client, workspaceHandle: wsId)
            if let targetPaneId { params["target_pane_id"] = targetPaneId }
            let surfaceId = try normalizeSurfaceHandle(surfaceArg, client: client, workspaceHandle: wsId)
            if let surfaceId { params["surface_id"] = surfaceId }
            let payload = try client.sendV2(method: V2MethodNames.paneJoin, params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: "OK")

        case "last-window":
            let payload = try client.sendV2(method: V2MethodNames.workspaceLast)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat, kinds: ["workspace"]))

        case "next-window":
            let payload = try client.sendV2(method: V2MethodNames.workspaceNext)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat, kinds: ["workspace"]))

        case "previous-window":
            let payload = try client.sendV2(method: V2MethodNames.workspacePrevious)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat, kinds: ["workspace"]))

        case "last-pane":
            let workspaceArg = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowOverride)
            var params: [String: Any] = [:]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let payload = try client.sendV2(method: V2MethodNames.paneLast, params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat, kinds: ["pane"]))

        case "find-window":
            let includeContent = commandArgs.contains("--content")
            let shouldSelect = commandArgs.contains("--select")
            let query = commandArgs
                .filter { !$0.hasPrefix("-") }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let listPayload = try client.sendV2(method: V2MethodNames.workspaceList)
            let workspaces = listPayload["workspaces"] as? [[String: Any]] ?? []

            var matches: [[String: Any]] = []
            for ws in workspaces {
                let title = (ws["title"] as? String) ?? ""
                let titleMatch = query.isEmpty || title.localizedCaseInsensitiveContains(query)
                var contentMatch = false
                if includeContent && !query.isEmpty, let wsId = ws["id"] as? String {
                    let textPayload = try? client.sendV2(method: V2MethodNames.surfaceReadText, params: ["workspace_id": wsId])
                    let text = (textPayload?["text"] as? String) ?? ""
                    contentMatch = text.localizedCaseInsensitiveContains(query)
                }
                if titleMatch || contentMatch {
                    matches.append(ws)
                }
            }

            if shouldSelect, let first = matches.first, let wsId = first["id"] as? String {
                _ = try client.sendV2(method: V2MethodNames.workspaceSelect, params: ["workspace_id": wsId])
            }

            if jsonOutput {
                let formatted = formatIDs(["matches": matches], mode: idFormat) as? [String: Any]
                print(jsonString(["matches": formatted?["matches"] ?? []]))
            } else if matches.isEmpty {
                print("No matches")
            } else {
                for item in matches {
                    let handle = textHandle(item, idFormat: idFormat)
                    let title = (item["title"] as? String) ?? ""
                    print("\(handle)  \"\(title)\"")
                }
            }

        case "clear-history":
            let workspaceArg = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowOverride)
            let surfaceArg = optionValue(commandArgs, name: "--surface")
            var params: [String: Any] = [:]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let sfId = try normalizeSurfaceHandle(surfaceArg, client: client, workspaceHandle: wsId, allowFocused: true)
            if let sfId { params["surface_id"] = sfId }
            let payload = try client.sendV2(method: V2MethodNames.surfaceClearHistory, params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat))

        case "set-hook":
            let store = loadTmuxCompatStore()
            if commandArgs.contains("--list") {
                if jsonOutput {
                    print(jsonString(["hooks": store.hooks]))
                } else if store.hooks.isEmpty {
                    print("No hooks configured")
                } else {
                    for (event, hookCmd) in store.hooks.sorted(by: { $0.key < $1.key }) {
                        print("\(event) -> \(hookCmd)")
                    }
                }
                return
            }
            if commandArgs.contains("--unset") {
                guard let event = commandArgs.last else {
                    throw CLIError(message: "set-hook --unset requires an event name")
                }
                _ = try updateTmuxCompatStore { store in
                    store.hooks.removeValue(forKey: event)
                }
                print("OK")
                return
            }
            guard let event = commandArgs.first(where: { !$0.hasPrefix("-") }) else {
                throw CLIError(message: "set-hook requires <event> <command>")
            }
            let commandText = commandArgs.drop(while: { $0 != event }).dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !commandText.isEmpty else {
                throw CLIError(message: "set-hook requires <event> <command>")
            }
            try updateTmuxCompatStore { store in
                store.hooks[event] = commandText
            }
            print("OK")

        case "popup":
            throw CLIError(message: "popup is not supported yet in programa CLI parity mode")

        case "bind-key", "unbind-key", "copy-mode":
            throw CLIError(message: "\(command) is not supported yet in programa CLI parity mode")

        case "set-buffer":
            let (nameArg, rem0) = parseOption(commandArgs, name: "--name")
            let name = (nameArg?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ? nameArg! : "default"
            let content = rem0.dropFirst(rem0.first == "--" ? 1 : 0).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else {
                throw CLIError(message: "set-buffer requires text")
            }
            try updateTmuxCompatStore { store in
                store.buffers[name] = content
            }
            print("OK")

        case "list-buffers":
            let store = loadTmuxCompatStore()
            if jsonOutput {
                let payload = store.buffers.map { key, value in ["name": key, "size": value.count] }
                print(jsonString(["buffers": payload.sorted { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }]))
            } else if store.buffers.isEmpty {
                print("No buffers")
            } else {
                for key in store.buffers.keys.sorted() {
                    let size = store.buffers[key]?.count ?? 0
                    print("\(key)\t\(size)")
                }
            }

        case "paste-buffer":
            let workspaceArg = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowOverride)
            let surfaceArg = optionValue(commandArgs, name: "--surface")
            let name = optionValue(commandArgs, name: "--name") ?? "default"
            let store = loadTmuxCompatStore()
            guard let buffer = store.buffers[name] else {
                throw CLIError(message: "Buffer not found: \(name)")
            }
            var params: [String: Any] = ["text": buffer]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client, allowCurrent: true)
            if let wsId { params["workspace_id"] = wsId }
            let sfId = try normalizeSurfaceHandle(surfaceArg, client: client, workspaceHandle: wsId, allowFocused: true)
            if let sfId { params["surface_id"] = sfId }
            let payload = try client.sendV2(method: V2MethodNames.surfaceSendText, params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: "OK")

        case "respawn-pane":
            let workspaceArg = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowOverride)
            let surfaceArg = optionValue(commandArgs, name: "--surface")
            let (commandOpt, rem0) = parseOption(commandArgs, name: "--command")
            let commandText = (commandOpt ?? rem0.dropFirst(rem0.first == "--" ? 1 : 0).joined(separator: " ")).trimmingCharacters(in: .whitespacesAndNewlines)
            let finalCommand = commandText.isEmpty ? "exec ${SHELL:-/bin/zsh} -l" : commandText
            var params: [String: Any] = ["text": finalCommand + "\n"]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client, allowCurrent: true)
            if let wsId { params["workspace_id"] = wsId }
            let sfId = try normalizeSurfaceHandle(surfaceArg, client: client, workspaceHandle: wsId, allowFocused: true)
            if let sfId { params["surface_id"] = sfId }
            let payload = try client.sendV2(method: V2MethodNames.surfaceSendText, params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: "OK")

        case "display-message":
            let printOnly = commandArgs.contains("-p") || commandArgs.contains("--print")
            let message = commandArgs
                .filter { !$0.hasPrefix("-") }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !message.isEmpty else {
                throw CLIError(message: "display-message requires text")
            }
            if printOnly {
                print(message)
                return
            }
            let payload = try client.sendV2(method: V2MethodNames.notificationCreate, params: ["title": "Programa", "body": message])
            if jsonOutput {
                print(jsonString(payload))
            } else {
                print(message)
            }

        default:
            throw CLIError(message: "Unsupported tmux compatibility command: \(command)")
        }
    }

    /// Subcommand help text for TmuxCompat commands, split out of the
    /// central `subcommandUsage` switch (programa.swift) so each domain's
    /// help text lives next to its command descriptors. Refs #101.
    func tmuxCompatSubcommandUsage(_ command: String) -> String? {
        switch command {
        case "capture-pane":
            return """
            Usage: programa capture-pane [--workspace <id|ref>] [--surface <id|ref>] [--scrollback] [--lines <n>]

            tmux-compatible alias for reading terminal text from a pane.

            Flags:
              --workspace <id|ref>   Workspace context (default: $PROGRAMA_WORKSPACE_ID)
              --surface <id|ref>     Surface context (default: $PROGRAMA_SURFACE_ID)
              --scrollback           Include scrollback
              --lines <n>            Return only the last N lines (implies --scrollback)

            Example:
              programa capture-pane --workspace workspace:2 --surface surface:1 --scrollback --lines 200
            """
        case "resize-pane":
            return """
            Usage: programa resize-pane [--pane <id|ref>] [--workspace <id|ref>] [-L|-R|-U|-D] [--amount <n>]

            tmux-compatible pane resize command.

            Flags:
              --pane <id|ref>        Pane to resize (default: focused pane)
              --workspace <id|ref>   Workspace context (default: $PROGRAMA_WORKSPACE_ID)
              -L|-R|-U|-D            Direction (default: -R)
              --amount <n>           Resize amount (default: 1)
            """
        case "pipe-pane":
            return """
            Usage: programa pipe-pane [--workspace <id|ref>] [--surface <id|ref>] [--command <shell-command> | <shell-command>]

            Capture pane text and pipe it to a shell command via stdin.

            Flags:
              --workspace <id|ref>   Workspace context (default: $PROGRAMA_WORKSPACE_ID)
              --surface <id|ref>     Surface context (default: focused surface)
              --command <command>    Shell command to run (or pass as trailing text)
            """
        case "wait-for":
            return """
            Usage: programa wait-for [-S|--signal] <name> [--timeout <seconds>]

            Wait for or signal a named synchronization token.

            Flags:
              -S, --signal           Signal the token instead of waiting
              --timeout <seconds>    Wait timeout (default: 30)
            """
        case "swap-pane":
            return """
            Usage: programa swap-pane --pane <id|ref> --target-pane <id|ref> [--workspace <id|ref>]

            Swap two panes.

            Flags:
              --pane <id|ref>         Source pane (required)
              --target-pane <id|ref>  Target pane (required)
              --workspace <id|ref>    Workspace context (default: $PROGRAMA_WORKSPACE_ID)
            """
        case "break-pane":
            return """
            Usage: programa break-pane [--workspace <id|ref>] [--pane <id|ref>] [--surface <id|ref>] [--no-focus]

            Move a pane/surface out into its own pane context.

            Flags:
              --workspace <id|ref>   Workspace context (default: $PROGRAMA_WORKSPACE_ID)
              --pane <id|ref>        Source pane
              --surface <id|ref>     Source surface
              --no-focus             Do not focus the result
            """
        case "join-pane":
            return """
            Usage: programa join-pane --target-pane <id|ref> [--workspace <id|ref>] [--pane <id|ref>] [--surface <id|ref>] [--no-focus]

            Join a pane/surface into another pane.

            Flags:
              --target-pane <id|ref>  Target pane (required)
              --workspace <id|ref>    Workspace context (default: $PROGRAMA_WORKSPACE_ID)
              --pane <id|ref>         Source pane
              --surface <id|ref>      Source surface
              --no-focus              Do not focus the result
            """
        case "next-window", "previous-window", "last-window":
            return """
            Usage: programa \(command)

            Switch workspace selection (next/previous/last) in the current window.
            """
        case "last-pane":
            return """
            Usage: programa last-pane [--workspace <id|ref>]

            Focus the previously focused pane in a workspace.

            Flags:
              --workspace <id|ref>   Workspace context (default: $PROGRAMA_WORKSPACE_ID)
            """
        case "find-window":
            return """
            Usage: programa find-window [--content] [--select] [query]

            Find workspaces by title (and optionally terminal content).

            Flags:
              --content   Search terminal content in addition to workspace titles
              --select    Select the first match
            """
        case "clear-history":
            return """
            Usage: programa clear-history [--workspace <id|ref>] [--surface <id|ref>]

            Clear terminal scrollback history.

            Flags:
              --workspace <id|ref>   Workspace context (default: $PROGRAMA_WORKSPACE_ID)
              --surface <id|ref>     Surface context (default: focused surface)
            """
        case "set-hook":
            return """
            Usage: programa set-hook [--list] [--unset <event>] | <event> <command>

            Manage tmux-compat hook definitions.

            Flags:
              --list            List configured hooks
              --unset <event>   Remove a hook by event name
            """
        case "popup":
            return """
            Usage: programa popup

            tmux compatibility placeholder. This command is currently not supported.
            """
        case "bind-key", "unbind-key", "copy-mode":
            return """
            Usage: programa \(command)

            tmux compatibility placeholder. This command is currently not supported.
            """
        case "set-buffer":
            return """
            Usage: programa set-buffer [--name <name>] [--] <text>

            Save text into a named tmux-compat buffer.

            Flags:
              --name <name>   Buffer name (default: default)
            """
        case "paste-buffer":
            return """
            Usage: programa paste-buffer [--name <name>] [--workspace <id|ref>] [--surface <id|ref>]

            Paste a named tmux-compat buffer into a surface.

            Flags:
              --name <name>         Buffer name (default: default)
              --workspace <id|ref>  Workspace context (default: $PROGRAMA_WORKSPACE_ID)
              --surface <id|ref>    Surface context (default: focused surface)
            """
        case "list-buffers":
            return """
            Usage: programa list-buffers

            List tmux-compat buffers.
            """
        case "respawn-pane":
            return """
            Usage: programa respawn-pane [--workspace <id|ref>] [--surface <id|ref>] [--command <cmd> | <cmd>]

            Send a command (or default shell restart command) to a surface.

            Flags:
              --workspace <id|ref>   Workspace context (default: $PROGRAMA_WORKSPACE_ID)
              --surface <id|ref>     Surface context (default: focused surface)
              --command <cmd>        Command text (or pass trailing command text)
            """
        case "display-message":
            return """
            Usage: programa display-message [-p|--print] <text>

            Print text (or show it via notification bridge in parity mode).

            Flags:
              -p, --print   Print to stdout only
            """
        default:
            return nil
        }
    }
}
