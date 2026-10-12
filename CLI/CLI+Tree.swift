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
    private struct TreeCommandOptions {
        let includeAllWindows: Bool
        let workspaceHandle: String?
        let jsonOutput: Bool
    }

    private struct TreePath {
        let windowHandle: String?
        let workspaceHandle: String?
        let paneHandle: String?
        let surfaceHandle: String?
    }

    func runTreeCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let options = try parseTreeCommandOptions(commandArgs)
        let payload = try buildTreePayload(options: options, client: client)
        if jsonOutput || options.jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
        } else {
            let windows = payload["windows"] as? [[String: Any]] ?? []
            print(renderTreeText(windows: windows, idFormat: idFormat))
        }
    }

    private func parseTreeCommandOptions(_ args: [String]) throws -> TreeCommandOptions {
        let (workspaceOpt, rem0) = parseOption(args, name: "--workspace")
        if rem0.contains("--workspace") {
            throw CLIError(message: "tree requires --workspace <id|ref>")
        }

        var includeAll = false
        var jsonOutput = false
        var remaining: [String] = []
        for arg in rem0 {
            if arg == "--all" {
                includeAll = true
                continue
            }
            if arg == "--json" {
                jsonOutput = true
                continue
            }
            remaining.append(arg)
        }

        if let unknown = remaining.first(where: { $0.hasPrefix("--") }) {
            throw CLIError(message: "tree: unknown flag '\(unknown)'. Known flags: --all --workspace <id|ref> --json")
        }
        if let extra = remaining.first {
            throw CLIError(message: "tree: unexpected argument '\(extra)'")
        }

        return TreeCommandOptions(includeAllWindows: includeAll, workspaceHandle: workspaceOpt, jsonOutput: jsonOutput)
    }

    private func buildTreePayload(
        options: TreeCommandOptions,
        client: SocketClient
    ) throws -> [String: Any] {
        var params: [String: Any] = ["all_windows": options.includeAllWindows]
        if let workspaceRaw = options.workspaceHandle {
            guard let workspaceHandle = try normalizeWorkspaceHandle(workspaceRaw, client: client) else {
                throw CLIError(message: "Invalid workspace handle")
            }
            params["workspace_id"] = workspaceHandle
        }
        if let caller = treeCallerContextFromEnvironment() {
            params["caller"] = caller
        }

        let payload = try client.sendV2(method: V2MethodNames.systemTree, params: params)
        return treePayloadWithMarkers(payload)
    }

    private func treeRelatedHandle(_ item: [String: Any], refKey: String, idKey: String) -> String? {
        if let ref = item[refKey] as? String, !ref.isEmpty {
            return ref
        }
        if let id = item[idKey] as? String, !id.isEmpty {
            return id
        }
        return nil
    }

    private func parseTreePath(payload: [String: Any]) -> TreePath {
        return TreePath(
            windowHandle: treeRelatedHandle(payload, refKey: "window_ref", idKey: "window_id"),
            workspaceHandle: treeRelatedHandle(payload, refKey: "workspace_ref", idKey: "workspace_id"),
            paneHandle: treeRelatedHandle(payload, refKey: "pane_ref", idKey: "pane_id"),
            surfaceHandle: treeRelatedHandle(payload, refKey: "surface_ref", idKey: "surface_id")
        )
    }

    private func treeCallerContextFromEnvironment() -> [String: Any]? {
        let env = ProcessInfo.processInfo.environment
        let workspaceRaw = env["PROGRAMA_WORKSPACE_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let surfaceRaw = env["PROGRAMA_SURFACE_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        var caller: [String: Any] = [:]
        if let workspaceRaw, !workspaceRaw.isEmpty {
            caller["workspace_id"] = workspaceRaw
        }
        if let surfaceRaw, !surfaceRaw.isEmpty {
            caller["surface_id"] = surfaceRaw
        }
        return caller.isEmpty ? nil : caller
    }

    private func treePayloadWithMarkers(_ payload: [String: Any]) -> [String: Any] {
        let active = payload["active"] as? [String: Any] ?? [:]
        let caller = payload["caller"] as? [String: Any] ?? [:]
        let activePath = parseTreePath(payload: active)
        let callerPath = parseTreePath(payload: caller)
        var result = payload
        let windows = payload["windows"] as? [[String: Any]] ?? []
        result["windows"] = treeApplyMarkers(windows: windows, activePath: activePath, callerPath: callerPath)
        if result["active"] == nil {
            result["active"] = active.isEmpty ? NSNull() : active
        }
        if result["caller"] == nil {
            result["caller"] = caller.isEmpty ? NSNull() : caller
        }
        return result
    }

    private func treeApplyMarkers(
        windows: [[String: Any]],
        activePath: TreePath,
        callerPath: TreePath
    ) -> [[String: Any]] {
        return windows.map { window in
            var windowNode = window
            let isActiveWindow = treeItemMatchesHandle(windowNode, handle: activePath.windowHandle)
            windowNode["current"] = isActiveWindow
            windowNode["active"] = isActiveWindow

            let workspaces = window["workspaces"] as? [[String: Any]] ?? []
            let workspaceNodes = workspaces.map { workspace in
                var workspaceNode = workspace
                workspaceNode["active"] = treeItemMatchesHandle(workspaceNode, handle: activePath.workspaceHandle)

                let panes = workspace["panes"] as? [[String: Any]] ?? []
                let paneNodes = panes.map { pane in
                    var paneNode = pane
                    paneNode["active"] = treeItemMatchesHandle(paneNode, handle: activePath.paneHandle)

                    let surfaces = pane["surfaces"] as? [[String: Any]] ?? []
                    paneNode["surfaces"] = surfaces.map { surface in
                        var surfaceNode = surface
                        surfaceNode["active"] = treeItemMatchesHandle(surfaceNode, handle: activePath.surfaceHandle)
                        surfaceNode["here"] = treeItemMatchesHandle(surfaceNode, handle: callerPath.surfaceHandle)
                        return surfaceNode
                    }
                    return paneNode
                }

                workspaceNode["panes"] = paneNodes
                return workspaceNode
            }

            windowNode["workspaces"] = workspaceNodes
            return windowNode
        }
    }

    private func treeItemMatchesHandle(_ item: [String: Any], handle: String?) -> Bool {
        guard let handle = handle?.trimmingCharacters(in: .whitespacesAndNewlines), !handle.isEmpty else {
            return false
        }
        return (item["id"] as? String) == handle || (item["ref"] as? String) == handle
    }

    private func renderTreeText(windows: [[String: Any]], idFormat: CLIIDFormat) -> String {
        guard !windows.isEmpty else { return "No windows" }

        var lines: [String] = []
        for window in windows {
            lines.append(treeWindowLabel(window, idFormat: idFormat))

            let workspaces = window["workspaces"] as? [[String: Any]] ?? []
            for (workspaceIndex, workspace) in workspaces.enumerated() {
                let workspaceIsLast = workspaceIndex == workspaces.count - 1
                let workspaceBranch = workspaceIsLast ? "└── " : "├── "
                let workspaceIndent = workspaceIsLast ? "    " : "│   "
                lines.append("\(workspaceBranch)\(treeWorkspaceLabel(workspace, idFormat: idFormat))")

                let panes = workspace["panes"] as? [[String: Any]] ?? []
                for (paneIndex, pane) in panes.enumerated() {
                    let paneIsLast = paneIndex == panes.count - 1
                    let paneBranch = paneIsLast ? "└── " : "├── "
                    let paneIndent = paneIsLast ? "    " : "│   "
                    lines.append("\(workspaceIndent)\(paneBranch)\(treePaneLabel(pane, idFormat: idFormat))")

                    let surfaces = pane["surfaces"] as? [[String: Any]] ?? []
                    for (surfaceIndex, surface) in surfaces.enumerated() {
                        let surfaceIsLast = surfaceIndex == surfaces.count - 1
                        let surfaceBranch = surfaceIsLast ? "└── " : "├── "
                        lines.append("\(workspaceIndent)\(paneIndent)\(surfaceBranch)\(treeSurfaceLabel(surface, idFormat: idFormat))")
                    }
                }
            }
        }

        return lines.joined(separator: "\n")
    }

    private func treeWindowLabel(_ window: [String: Any], idFormat: CLIIDFormat) -> String {
        var parts = ["window \(textHandle(window, idFormat: idFormat))"]
        if (window["current"] as? Bool) == true {
            parts.append("[current]")
        }
        if (window["active"] as? Bool) == true {
            parts.append("◀ active")
        }
        return parts.joined(separator: " ")
    }

    private func treeWorkspaceLabel(_ workspace: [String: Any], idFormat: CLIIDFormat) -> String {
        var parts = ["workspace \(textHandle(workspace, idFormat: idFormat))"]
        let title = (workspace["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !title.isEmpty {
            parts.append("\"\(title)\"")
        }
        if (workspace["selected"] as? Bool) == true {
            parts.append("[selected]")
        }
        if (workspace["active"] as? Bool) == true {
            parts.append("◀ active")
        }
        return parts.joined(separator: " ")
    }

    private func treePaneLabel(_ pane: [String: Any], idFormat: CLIIDFormat) -> String {
        var parts = ["pane \(textHandle(pane, idFormat: idFormat))"]
        if (pane["focused"] as? Bool) == true {
            parts.append("[focused]")
        }
        if (pane["active"] as? Bool) == true {
            parts.append("◀ active")
        }
        return parts.joined(separator: " ")
    }

    private func treeSurfaceLabel(_ surface: [String: Any], idFormat: CLIIDFormat) -> String {
        let rawType = ((surface["type"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let surfaceType = rawType.isEmpty ? "unknown" : rawType
        var parts = ["surface \(textHandle(surface, idFormat: idFormat))", "[\(surfaceType)]"]
        let title = (surface["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !title.isEmpty {
            parts.append("\"\(title)\"")
        }
        if (surface["selected"] as? Bool) == true {
            parts.append("[selected]")
        }
        if (surface["active"] as? Bool) == true {
            parts.append("◀ active")
        }
        if (surface["here"] as? Bool) == true {
            parts.append("◀ here")
        }
        if let tty = surface["tty"] as? String, !tty.isEmpty {
            parts.append("tty=\(tty)")
        }
        return parts.joined(separator: " ")
    }

    /// Subcommand help text for Tree commands, split out of the
    /// central `subcommandUsage` switch (programa.swift) so each domain's
    /// help text lives next to its command descriptors. Refs #101.
    func treeSubcommandUsage(_ command: String) -> String? {
        switch command {
        case "tree":
            return """
            Usage: programa tree [flags]

            Print the hierarchy of windows, workspaces, panes, and surfaces.

            Flags:
              --all                         Include all windows (default: current window only)
              --workspace <id|ref>         Show only one workspace
              --json                        Structured JSON output

            Output:
              Text mode prints a box-drawing tree with markers:
              - ◀ active (true focused window/workspace/pane/surface path)
              - ◀ here (caller surface where `programa tree` was invoked)
              - workspace [selected]
              - pane [focused]
              - surface [selected]

            Example:
              programa tree
              programa tree --all
              programa tree --workspace workspace:2
              programa --json tree --all
            """
        default:
            return nil
        }
    }

    /// Tree command descriptors, split out of the central
    /// `commandDescriptors()` array (programa.swift) so they live next to
    /// their implementation. Refs #101.
    func treeDescriptors() -> [CommandDescriptor] {
        [
            CommandDescriptor(
                names: ["tree"],
                helpLines: ["tree [--all] [--workspace <id|ref>]"],
                execute: { ctx in
                    try self.runTreeCommand(commandArgs: ctx.commandArgs, client: ctx.client, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat)
                }
            ),
        ]
    }
}
