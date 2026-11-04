import Foundation

extension ProgramaCLI {
    /// `close-workspace` and `select-workspace` never fall back to the current workspace.
    private var explicitWorkspaceGrammar: CLIArgumentGrammar {
        CLIArgumentGrammar(valueOptions: ["workspace"], validate: { command, parsed in
            if parsed.options["workspace"] == nil {
                throw CLIError(
                    message: "\(command): --workspace <id|ref> is required (UUID or short ref like workspace:2). Refusing to target the current workspace implicitly."
                )
            }
        })
    }

    func workspaceOrderingDescriptors() -> [CommandDescriptor] {
        [
            CommandDescriptor(
                names: ["reorder-workspace"],
                helpLines: ["reorder-workspace --workspace <id|ref> (--index <n> | --before <id|ref> | --after <id|ref>) [--window <id|ref>]"],
                detailedUsage: """
                Usage: programa reorder-workspace [--workspace <id|ref> | <id|ref>] [flags]

                Reorder a workspace within its window.

                Flags:
                  --workspace <id|ref>   Workspace to reorder (required unless passed positionally)
                  --index <n>                  Place at this index
                  --before <id|ref>      Place before this workspace
                  --before-workspace <id|ref>
                                             Alias for --before
                  --after <id|ref>       Place after this workspace
                  --after-workspace <id|ref>
                                             Alias for --after
                  --window <id|ref>      Window context

                Example:
                  programa reorder-workspace --workspace workspace:2 --index 0
                  programa reorder-workspace --workspace workspace:3 --after workspace:1
                """,
                grammar: CLIArgumentGrammar(valueOptions: ["workspace", "index", "before", "before-workspace", "after", "after-workspace", "window"], maxPositionals: 1, validate: { _, parsed in
                    guard (parsed.options["workspace"] != nil) != (parsed.positional.count == 1) else {
                        throw CLIError(message: "reorder-workspace requires --workspace <id|ref> or one positional <id|ref>")
                    }
                    let anchors = ["index", "before", "before-workspace", "after", "after-workspace"].filter { parsed.options[$0] != nil }
                    guard anchors.count == 1 else {
                        throw CLIError(message: "reorder-workspace requires exactly one of --index, --before, or --after")
                    }
                    if let raw = parsed.options["index"], (Int(raw) ?? -1) < 0 {
                        throw CLIError(message: "reorder-workspace: --index must be a nonnegative integer")
                    }
                }),
                execute: { ctx in
                    try self.runReorderWorkspace(commandArgs: ctx.commandArgs, client: ctx.client, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat)
                }
            ),

            CommandDescriptor(
                names: ["workspace-action"],
                helpLines: ["workspace-action --action <name> [--workspace <id|ref>] [--title <text>] [--color <name|#hex>] [--description <text>]"],
                detailedUsage: """
                Usage: programa workspace-action --action <name> [flags]

                Perform workspace context-menu actions from CLI/socket.

                Actions:
                  pin | unpin
                  rename | clear-name
                  set-description | clear-description
                  move-up | move-down | move-top
                  close-others | close-above | close-below
                  mark-read | mark-unread
                  set-color | clear-color

                Flags:
                  --action <name>              Action name (required if not positional)
                  --workspace <id|ref>   Target workspace (default: current/$PROGRAMA_WORKSPACE_ID)
                  --title <text>               Title for rename
                  --color <name|#hex>          Color for set-color (name or #RRGGBB hex)
                  --description <text>         Description for set-description

                Named colors:
                  Red, Crimson, Orange, Amber, Olive, Green, Teal, Aqua,
                  Blue, Navy, Indigo, Purple, Magenta, Rose, Brown, Charcoal

                Example:
                  programa workspace-action --workspace workspace:2 --action pin
                  programa workspace-action --action rename --title "infra"
                  programa workspace-action close-others
                  programa workspace-action --action set-color --color blue
                  programa workspace-action --action set-color --color "#C0392B"
                  programa workspace-action set-color Amber
                  programa workspace-action --action set-description --description "Ship checklist"
                  programa workspace-action --action set-description $'Ship checklist\n- verify build\n- post notes'
                  programa workspace-action clear-color
                """,
                grammar: CLIArgumentGrammar(valueOptions: ["action", "workspace", "title", "color", "description"], maxPositionals: nil, validate: { _, parsed in
                    guard let rawAction = parsed.options["action"] ?? parsed.positional.first else {
                        throw CLIError(message: "workspace-action requires --action <name>")
                    }
                    let trailing = parsed.options["action"] == nil ? Array(parsed.positional.dropFirst()) : parsed.positional
                    let action = rawAction.lowercased().replacingOccurrences(of: "-", with: "_")
                    if action == "rename", parsed.options["title"] == nil, trailing.isEmpty {
                        throw CLIError(message: "workspace-action rename requires a title")
                    }
                    if action == "set_color", parsed.options["color"] == nil, trailing.isEmpty {
                        throw CLIError(message: "workspace-action set-color requires a color")
                    }
                    if action == "set_description", parsed.options["description"] == nil, trailing.isEmpty {
                        throw CLIError(message: "workspace-action set-description requires a description")
                    }
                }),
                execute: { ctx in
                    try self.runWorkspaceAction(commandArgs: ctx.commandArgs, client: ctx.client, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat, windowOverride: ctx.windowId)
                }
            ),
        ]
    }

    func workspaceListDescriptors() -> [CommandDescriptor] {
        [
            CommandDescriptor(
                names: ["list-workspaces"],
                helpLines: ["list-workspaces"],
                detailedUsage: """
                Usage: programa list-workspaces

                List workspaces in the current window.

                Example:
                  programa list-workspaces
                """,
                grammar: CLIArgumentGrammar(),
                execute: { ctx in
                    let payload = try ctx.client.sendV2(method: V2MethodNames.workspaceList)
                    if ctx.jsonOutput {
                        print(self.jsonString(self.formatIDs(payload, mode: ctx.idFormat)))
                    } else {
                        let workspaces = payload["workspaces"] as? [[String: Any]] ?? []
                        if workspaces.isEmpty {
                            print("No workspaces")
                        } else {
                            for ws in workspaces {
                                let selected = (ws["selected"] as? Bool) == true
                                let handle = self.textHandle(ws, idFormat: ctx.idFormat)
                                let title = (ws["title"] as? String) ?? ""
                                let prefix = selected ? "* " : "  "
                                let selTag = selected ? "  [selected]" : ""
                                let titlePart = title.isEmpty ? "" : "  \(title)"
                                print("\(prefix)\(handle)\(titlePart)\(selTag)")
                            }
                        }
                    }
                }
            ),

            CommandDescriptor(
                names: ["new-workspace"],
                helpLines: ["new-workspace [--name <title>] [--description <text>] [--cwd <path>] [--command <text>]"],
                detailedUsage: """
                Usage: programa new-workspace [--name <title>] [--description <text>] [--cwd <path>] [--command <text>]

                Create a new workspace in the current window.

                Flags:
                  --name <title>     Set a custom name for the new workspace
                  --description <text> Set a custom description for the new workspace
                  --cwd <path>       Set the working directory for the new workspace
                  --command <text>   Send text+Enter to the new workspace after creation

                Example:
                  programa new-workspace
                  programa new-workspace --name "Build Server"
                  programa new-workspace --name "Launch" --description "Ship checklist"
                  programa new-workspace --cwd ~/projects/myapp
                  programa new-workspace --cwd . --command "npm test"
                """,
                grammar: CLIArgumentGrammar(valueOptions: ["name", "description", "cwd", "command"]),
                execute: { ctx in
                    let (commandOpt, rem0) = self.parseOption(ctx.commandArgs, name: "--command")
                    let (cwdOpt, rem1) = self.parseOption(rem0, name: "--cwd")
                    let (nameOpt, rem2) = self.parseOption(rem1, name: "--name")
                    let (descriptionOpt, remaining) = self.parseOption(rem2, name: "--description")
                    if let unknown = remaining.first(where: { $0.hasPrefix("--") }) {
                        throw CLIError(message: "new-workspace: unknown flag '\(unknown)'. Known flags: --name <title>, --description <text>, --command <text>, --cwd <path>")
                    }
                    var params: [String: Any] = [:]
                    if let cwdOpt {
                        let resolved = self.resolvePath(cwdOpt)
                        params["cwd"] = resolved
                    }
                    if let nameOpt {
                        params["title"] = nameOpt
                    }
                    if let descriptionOpt {
                        params["description"] = descriptionOpt
                    }
                    let response = try ctx.client.sendV2(method: V2MethodNames.workspaceCreate, params: params)
                    let wsId = (response["workspace_ref"] as? String) ?? (response["workspace_id"] as? String) ?? ""
                    self.printV2Payload(response, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat, fallbackText: self.v2OKSummary(response, idFormat: ctx.idFormat, kinds: ["workspace"]))
                    if let commandText = commandOpt, !wsId.isEmpty {
                        let text = self.unescapeSendText(commandText + "\\n")
                        let sendParams: [String: Any] = ["text": text, "workspace_id": wsId]
                        _ = try ctx.client.sendV2(method: V2MethodNames.surfaceSendText, params: sendParams)
                    }
                }
            ),
        ]
    }

    func workspaceSelectionDescriptors() -> [CommandDescriptor] {
        [
            CommandDescriptor(
                names: ["close-workspace"],
                helpLines: ["close-workspace --workspace <id|ref>"],
                detailedUsage: """
                Usage: programa close-workspace --workspace <id|ref>

                Close the specified workspace.

                Flags:
                  --workspace <id|ref>   Workspace to close (required)

                Example:
                  programa close-workspace --workspace workspace:2
                """,
                grammar: explicitWorkspaceGrammar,
                execute: { ctx in
                    guard let workspaceRaw = self.optionValue(ctx.commandArgs, name: "--workspace") else {
                        throw CLIError(
                            message: "close-workspace: --workspace <id|ref> is required (UUID or short ref like workspace:2). Refusing to target the current workspace implicitly."
                        )
                    }
                    var params: [String: Any] = [:]
                    let wsId = try self.normalizeWorkspaceHandle(workspaceRaw, client: ctx.client)
                    if let wsId { params["workspace_id"] = wsId }
                    let payload = try ctx.client.sendV2(method: V2MethodNames.workspaceClose, params: params)
                    self.printV2Payload(payload, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat, fallbackText: self.v2OKSummary(payload, idFormat: ctx.idFormat, kinds: ["workspace"]))
                }
            ),

            CommandDescriptor(
                names: ["select-workspace"],
                helpLines: ["select-workspace --workspace <id|ref>"],
                detailedUsage: """
                Usage: programa select-workspace --workspace <id|ref>

                Select (switch to) the specified workspace.

                Flags:
                  --workspace <id|ref>   Workspace to select (required)

                Example:
                  programa select-workspace --workspace workspace:2
                  programa select-workspace --workspace 0
                """,
                grammar: explicitWorkspaceGrammar,
                execute: { ctx in
                    guard let workspaceRaw = self.optionValue(ctx.commandArgs, name: "--workspace") else {
                        throw CLIError(message: "select-workspace requires --workspace")
                    }
                    var params: [String: Any] = [:]
                    let wsId = try self.normalizeWorkspaceHandle(workspaceRaw, client: ctx.client)
                    if let wsId { params["workspace_id"] = wsId }
                    let payload = try ctx.client.sendV2(method: V2MethodNames.workspaceSelect, params: params)
                    self.printV2Payload(payload, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat, fallbackText: self.v2OKSummary(payload, idFormat: ctx.idFormat, kinds: ["workspace"]))
                }
            ),

            CommandDescriptor(
                names: ["rename-workspace", "rename-window"],
                helpLines: [
                    "rename-workspace [--workspace <id|ref>] <title>",
                    "rename-window [--workspace <id|ref>] <title>",
                ],
                detailedUsage: """
                Usage: programa rename-workspace [--workspace <id|ref>] [--] <title>

                Rename a workspace. Defaults to the current workspace.
                tmux-compatible alias: rename-window

                Flags:
                  --workspace <id|ref>   Workspace to rename (default: current/$PROGRAMA_WORKSPACE_ID)

                Example:
                  programa rename-workspace "backend logs"
                  programa rename-window --workspace workspace:2 "agent run"
                """,
                grammar: CLIArgumentGrammar(valueOptions: ["workspace"], minPositionals: 1, maxPositionals: nil),
                execute: { ctx in
                    let (wsArg, rem0) = self.parseOption(ctx.commandArgs, name: "--workspace")
                    let workspaceArg = wsArg ?? (ctx.windowId == nil ? ProcessInfo.processInfo.environment["PROGRAMA_WORKSPACE_ID"] : nil)
                    let titleArgs = rem0.dropFirst(rem0.first == "--" ? 1 : 0)
                    let title = titleArgs.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !title.isEmpty else {
                        throw CLIError(message: "\(ctx.command) requires a title")
                    }
                    let wsId = try self.resolveWorkspaceId(workspaceArg, client: ctx.client)
                    let params: [String: Any] = ["title": title, "workspace_id": wsId]
                    let payload = try ctx.client.sendV2(method: V2MethodNames.workspaceRename, params: params)
                    self.printV2Payload(payload, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat, fallbackText: self.v2OKSummary(payload, idFormat: ctx.idFormat, kinds: ["workspace"]))
                }
            ),

            CommandDescriptor(
                names: ["current-workspace"],
                helpLines: ["current-workspace"],
                detailedUsage: """
                Usage: programa current-workspace

                Print the currently selected workspace ID.
                """,
                grammar: CLIArgumentGrammar(),
                execute: { ctx in
                    let response = try ctx.client.sendV2(method: V2MethodNames.workspaceCurrent)
                    if ctx.jsonOutput {
                        print(self.jsonString(self.formatIDs(response, mode: ctx.idFormat)))
                    } else {
                        let handle = self.formatHandle(response, kind: "workspace", idFormat: ctx.idFormat)
                            ?? (response["workspace_id"] as? String)
                            ?? ""
                        print(handle)
                    }
                }
            ),
        ]
    }
}
