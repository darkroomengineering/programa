import Foundation

extension ProgramaCLI {
    /// `focus-window` and `close-window`: a required `--window` that must be a UUID or ref.
    private var windowTargetGrammar: CLIArgumentGrammar {
        CLIArgumentGrammar(valueOptions: ["window"], requiredOptions: ["window"], validate: { command, parsed in
            guard let rawWindow = parsed.options["window"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  self.isUUID(rawWindow) || self.isHandleRef(rawWindow) else {
                throw CLIError(message: "\(command): invalid window id")
            }
        })
    }

    func windowCommandDescriptors() -> [CommandDescriptor] {
        [
            CommandDescriptor(
                names: ["list-windows"],
                helpLines: ["list-windows"],
                detailedUsage: """
                Usage: programa list-windows

                List open windows.
                """,
                grammar: CLIArgumentGrammar(),
                execute: { ctx in
                    let listed = try ctx.client.sendV2(method: V2MethodNames.windowList)
                    let windows = listed["windows"] as? [[String: Any]] ?? []
                    if ctx.jsonOutput {
                        let payload = windows.map { item -> [String: Any] in
                            var dict: [String: Any] = [
                                "index": self.intFromAny(item["index"]) ?? 0,
                                "id": (item["id"] as? String) ?? "",
                                "key": (item["key"] as? Bool) ?? false,
                                "workspace_count": self.intFromAny(item["workspace_count"]) ?? 0,
                            ]
                            dict["selected_workspace_id"] = item["selected_workspace_id"] as? String ?? NSNull()
                            return dict
                        }
                        print(self.jsonString(payload))
                    } else if windows.isEmpty {
                        print("No windows")
                    } else {
                        let lines = windows.map { item -> String in
                            let selected = ((item["key"] as? Bool) ?? false) ? "*" : " "
                            let idx = self.intFromAny(item["index"]) ?? 0
                            let id = (item["id"] as? String) ?? ""
                            let selectedWs = (item["selected_workspace_id"] as? String) ?? "none"
                            let workspaceCount = self.intFromAny(item["workspace_count"]) ?? 0
                            return "\(selected) \(idx): \(id) selected_workspace=\(selectedWs) workspaces=\(workspaceCount)"
                        }
                        print(lines.joined(separator: "\n"))
                    }
                }
            ),

            CommandDescriptor(
                names: ["current-window"],
                helpLines: ["current-window"],
                detailedUsage: """
                Usage: programa current-window

                Print the currently selected window ID.
                """,
                grammar: CLIArgumentGrammar(),
                execute: { ctx in
                    let response = try ctx.client.sendV2(method: V2MethodNames.windowCurrent)
                    let windowId = (response["window_id"] as? String) ?? ""
                    if ctx.jsonOutput {
                        print(self.jsonString(["window_id": windowId]))
                    } else {
                        print(windowId)
                    }
                }
            ),

            CommandDescriptor(
                names: ["new-window"],
                helpLines: ["new-window"],
                detailedUsage: """
                Usage: programa new-window

                Create a new window.

                Example:
                  programa new-window
                """,
                grammar: CLIArgumentGrammar(),
                execute: { ctx in
                    let response = try ctx.client.sendV2(method: V2MethodNames.windowCreate)
                    self.printV2Payload(response, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat, fallbackText: self.v2OKSummary(response, idFormat: ctx.idFormat, kinds: ["window"]))
                }
            ),

            CommandDescriptor(
                names: ["focus-window"],
                helpLines: ["focus-window --window <id>"],
                detailedUsage: """
                Usage: programa focus-window --window <id|ref>

                Focus (bring to front) the specified window.

                Flags:
                  --window <id|ref>   Window to focus (required)

                Example:
                  programa focus-window --window <window-uuid>
                  programa focus-window --window window:1
                """,
                grammar: windowTargetGrammar,
                execute: { ctx in
                    guard let target = self.optionValue(ctx.commandArgs, name: "--window") else {
                        throw CLIError(message: "focus-window requires --window")
                    }
                    // A UUID or a short ref (new-window prints a ref); bare indexes are rejected.
                    guard self.isUUID(target.trimmingCharacters(in: .whitespacesAndNewlines))
                        || self.isHandleRef(target.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                        throw CLIError(message: "ERROR: Invalid window id")
                    }
                    do {
                        _ = try ctx.client.sendV2(method: V2MethodNames.windowFocus, params: ["window_id": target])
                        print("OK")
                    } catch let error as CLIError where error.message.hasPrefix("not_found:") {
                        throw CLIError(message: "not_found: Window not found")
                    }
                }
            ),

            CommandDescriptor(
                names: ["close-window"],
                helpLines: ["close-window --window <id>"],
                detailedUsage: """
                Usage: programa close-window --window <id|ref>

                Close the specified window.

                Flags:
                  --window <id|ref>   Window to close (required)

                Example:
                  programa close-window --window <window-uuid>
                  programa close-window --window window:1
                """,
                grammar: windowTargetGrammar,
                execute: { ctx in
                    guard let target = self.optionValue(ctx.commandArgs, name: "--window") else {
                        throw CLIError(message: "close-window requires --window")
                    }
                    guard self.isUUID(target.trimmingCharacters(in: .whitespacesAndNewlines))
                        || self.isHandleRef(target.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                        throw CLIError(message: "ERROR: Invalid window id")
                    }
                    do {
                        _ = try ctx.client.sendV2(method: V2MethodNames.windowClose, params: ["window_id": target])
                        print("OK")
                    } catch let error as CLIError where error.message.hasPrefix("not_found:") {
                        throw CLIError(message: "not_found: Window not found")
                    }
                }
            ),

            CommandDescriptor(
                names: ["move-workspace-to-window"],
                helpLines: ["move-workspace-to-window --workspace <id|ref> --window <id|ref>"],
                detailedUsage: """
                Usage: programa move-workspace-to-window --workspace <id|ref> --window <id|ref>

                Move a workspace to a different window.

                Flags:
                  --workspace <id|ref>   Workspace to move (required)
                  --window <id|ref>      Target window (required)

                Example:
                  programa move-workspace-to-window --workspace workspace:2 --window window:1
                """,
                grammar: CLIArgumentGrammar(valueOptions: ["workspace", "window"], requiredOptions: ["workspace", "window"]),
                execute: { ctx in
                    guard let workspaceRaw = self.optionValue(ctx.commandArgs, name: "--workspace") else {
                        throw CLIError(message: "move-workspace-to-window requires --workspace")
                    }
                    guard let windowRaw = self.optionValue(ctx.commandArgs, name: "--window") else {
                        throw CLIError(message: "move-workspace-to-window requires --window")
                    }
                    var params: [String: Any] = [:]
                    let wsId = try self.normalizeWorkspaceHandle(workspaceRaw, client: ctx.client)
                    if let wsId { params["workspace_id"] = wsId }
                    let winId = try self.normalizeWindowHandle(windowRaw, client: ctx.client)
                    if let winId { params["window_id"] = winId }
                    let payload = try ctx.client.sendV2(method: V2MethodNames.workspaceMoveToWindow, params: params)
                    self.printV2Payload(payload, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat, fallbackText: self.v2OKSummary(payload, idFormat: ctx.idFormat, kinds: ["workspace", "window"]))
                }
            ),
        ]
    }
}
