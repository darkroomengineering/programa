import Foundation

extension ProgramaCLI {
    func paneListDescriptors() -> [CommandDescriptor] {
        [
            CommandDescriptor(
                names: ["new-split"],
                helpLines: ["new-split <left|right|up|down> [--workspace <id|ref>] [--surface <id|ref>] [--panel <id|ref>]"],
                detailedUsage: """
                Usage: programa new-split <left|right|up|down> [flags]

                Split the current pane in the given direction.

                Flags:
                  --workspace <id|ref>   Target workspace (default: $PROGRAMA_WORKSPACE_ID)
                  --surface <id|ref>     Surface to split from (default: $PROGRAMA_SURFACE_ID)
                  --panel <id|ref>       Alias for --surface

                Example:
                  programa new-split right
                  programa new-split down --workspace workspace:1
                """,
                grammar: CLIArgumentGrammar(valueOptions: ["workspace", "surface", "panel"], minPositionals: 1, maxPositionals: 1, validate: { _, parsed in
                    guard ["left", "right", "up", "down"].contains(parsed.positional[0].lowercased()) else {
                        throw CLIError(message: "new-split: direction must be left, right, up, or down")
                    }
                }),
                execute: { ctx in
                    let (wsArg, rem0) = self.parseOption(ctx.commandArgs, name: "--workspace")
                    let (panelArg, rem1) = self.parseOption(rem0, name: "--panel")
                    let (sfArg, rem2) = self.parseOption(rem1, name: "--surface")
                    let workspaceArg = wsArg ?? (ctx.windowId == nil ? ProcessInfo.processInfo.environment["PROGRAMA_WORKSPACE_ID"] : nil)
                    guard let direction = rem2.first else {
                        throw CLIError(message: "new-split requires a direction")
                    }
                    var params: [String: Any] = ["direction": direction]
                    let wsId = try self.normalizeWorkspaceHandle(workspaceArg, client: ctx.client)
                    if let wsId { params["workspace_id"] = wsId }
                    let sfId = try self.resolveCommandSurface(
                        explicitSurface: sfArg ?? panelArg, explicitWorkspace: wsArg,
                        windowId: ctx.windowId, workspaceHandle: wsId, client: ctx.client
                    )
                    if let sfId { params["surface_id"] = sfId }
                    let payload = try ctx.client.sendV2(method: V2MethodNames.surfaceSplit, params: params)
                    self.printV2Payload(payload, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat, fallbackText: self.v2OKSummary(payload, idFormat: ctx.idFormat))
                }
            ),

            CommandDescriptor(
                names: ["list-panes"],
                helpLines: ["list-panes [--workspace <id|ref>]"],
                detailedUsage: """
                Usage: programa list-panes [--workspace <id|ref>]

                List panes in a workspace.

                Flags:
                  --workspace <id|ref>   Workspace context (default: $PROGRAMA_WORKSPACE_ID)

                Example:
                  programa list-panes
                  programa list-panes --workspace workspace:2
                """,
                grammar: CLIArgumentGrammar(valueOptions: ["workspace"]),
                execute: { ctx in
                    let workspaceArg = self.workspaceFromArgsOrEnv(ctx.commandArgs, windowOverride: ctx.windowId)
                    var params: [String: Any] = [:]
                    let wsId = try self.normalizeWorkspaceHandle(workspaceArg, client: ctx.client)
                    if let wsId { params["workspace_id"] = wsId }
                    let payload = try ctx.client.sendV2(method: V2MethodNames.paneList, params: params)
                    if ctx.jsonOutput {
                        print(self.jsonString(self.formatIDs(payload, mode: ctx.idFormat)))
                    } else {
                        let panes = payload["panes"] as? [[String: Any]] ?? []
                        if panes.isEmpty {
                            print("No panes")
                        } else {
                            for pane in panes {
                                let focused = (pane["focused"] as? Bool) == true
                                let handle = self.textHandle(pane, idFormat: ctx.idFormat)
                                let count = pane["surface_count"] as? Int ?? 0
                                let prefix = focused ? "* " : "  "
                                let focusTag = focused ? "  [focused]" : ""
                                print("\(prefix)\(handle)  [\(count) surface\(count == 1 ? "" : "s")]\(focusTag)")
                            }
                        }
                    }
                }
            ),

            CommandDescriptor(
                names: ["list-pane-surfaces"],
                helpLines: ["list-pane-surfaces [--workspace <id|ref>] [--pane <id|ref>]"],
                detailedUsage: """
                Usage: programa list-pane-surfaces [--workspace <id|ref>] [--pane <id|ref>]

                List surfaces in a pane.

                Flags:
                  --workspace <id|ref>   Workspace context (default: $PROGRAMA_WORKSPACE_ID)
                  --pane <id|ref>        Restrict to a specific pane (default: focused pane)

                Example:
                  programa list-pane-surfaces
                  programa list-pane-surfaces --workspace workspace:2 --pane pane:1
                """,
                grammar: CLIArgumentGrammar(valueOptions: ["workspace", "pane"]),
                execute: { ctx in
                    let workspaceArg = self.workspaceFromArgsOrEnv(ctx.commandArgs, windowOverride: ctx.windowId)
                    let paneRaw = self.optionValue(ctx.commandArgs, name: "--pane")
                    var params: [String: Any] = [:]
                    let wsId = try self.normalizeWorkspaceHandle(workspaceArg, client: ctx.client)
                    if let wsId { params["workspace_id"] = wsId }
                    let paneId = try self.normalizePaneHandle(paneRaw, client: ctx.client, workspaceHandle: wsId)
                    if let paneId { params["pane_id"] = paneId }
                    let payload = try ctx.client.sendV2(method: V2MethodNames.paneSurfaces, params: params)
                    if ctx.jsonOutput {
                        print(self.jsonString(self.formatIDs(payload, mode: ctx.idFormat)))
                    } else {
                        let surfaces = payload["surfaces"] as? [[String: Any]] ?? []
                        if surfaces.isEmpty {
                            print("No surfaces in pane")
                        } else {
                            for surface in surfaces {
                                let selected = (surface["selected"] as? Bool) == true
                                let handle = self.textHandle(surface, idFormat: ctx.idFormat)
                                let title = (surface["title"] as? String) ?? ""
                                let prefix = selected ? "* " : "  "
                                let selTag = selected ? "  [selected]" : ""
                                print("\(prefix)\(handle)  \(title)\(selTag)")
                            }
                        }
                    }
                }
            ),
        ]
    }

    func paneSurfaceDescriptors() -> [CommandDescriptor] {
        [
            CommandDescriptor(
                names: ["focus-pane"],
                helpLines: ["focus-pane --pane <id|ref> [--workspace <id|ref>]"],
                detailedUsage: """
                Usage: programa focus-pane [--pane <id|ref> | <id|ref>] [flags]

                Focus the specified pane.

                Flags:
                  --pane <id|ref>          Pane to focus (required unless passed positionally)
                  --workspace <id|ref>     Workspace context (default: $PROGRAMA_WORKSPACE_ID)

                Example:
                  programa focus-pane --pane pane:2
                  programa focus-pane pane:1
                  programa focus-pane --pane pane:1 --workspace workspace:2
                """,
                grammar: CLIArgumentGrammar(valueOptions: ["workspace", "pane"], maxPositionals: 1, validate: { _, parsed in
                    guard parsed.options["pane"] != nil || parsed.positional.count == 1 else {
                        throw CLIError(message: "focus-pane requires --pane <id|ref>")
                    }
                    guard !(parsed.options["pane"] != nil && !parsed.positional.isEmpty) else {
                        throw CLIError(message: "focus-pane: provide the pane once")
                    }
                }),
                execute: { ctx in
                    let workspaceArg = self.workspaceFromArgsOrEnv(ctx.commandArgs, windowOverride: ctx.windowId)
                    guard let paneRaw = self.optionOrFirstPositional(ctx.commandArgs, name: "--pane") else {
                        throw CLIError(message: "focus-pane requires --pane <id|ref>")
                    }
                    var params: [String: Any] = [:]
                    let wsId = try self.normalizeWorkspaceHandle(workspaceArg, client: ctx.client)
                    if let wsId { params["workspace_id"] = wsId }
                    let paneId = try self.normalizePaneHandle(paneRaw, client: ctx.client, workspaceHandle: wsId)
                    if let paneId { params["pane_id"] = paneId }
                    let payload = try ctx.client.sendV2(method: V2MethodNames.paneFocus, params: params)
                    self.printV2Payload(payload, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat, fallbackText: self.v2OKSummary(payload, idFormat: ctx.idFormat, kinds: ["pane", "workspace"]))
                }
            ),

            CommandDescriptor(
                names: ["new-pane"],
                helpLines: ["new-pane [--type <terminal>] [--direction <left|right|up|down>] [--workspace <id|ref>]"],
                detailedUsage: """
                Usage: programa new-pane [flags]

                Create a new pane in the workspace.

                Flags:
                  --type <terminal>           Pane type (default: terminal)
                  --direction <left|right|up|down>    Split direction (default: right)
                  --workspace <id|ref>                Target workspace (default: $PROGRAMA_WORKSPACE_ID)

                Example:
                  programa new-pane
                  programa new-pane --direction down
                """,
                grammar: CLIArgumentGrammar(valueOptions: ["type", "direction", "workspace"], validate: { _, parsed in
                    if let type = parsed.options["type"], type.lowercased() != "terminal" {
                        throw CLIError(message: "new-pane: --type must be terminal")
                    }
                    if let direction = parsed.options["direction"], !["left", "right", "up", "down"].contains(direction.lowercased()) {
                        throw CLIError(message: "new-pane: invalid direction")
                    }
                }),
                execute: { ctx in
                    let workspaceArg = self.workspaceFromArgsOrEnv(ctx.commandArgs, windowOverride: ctx.windowId)
                    let type = self.optionValue(ctx.commandArgs, name: "--type")
                    let direction = self.optionValue(ctx.commandArgs, name: "--direction") ?? "right"
                    var params: [String: Any] = ["direction": direction]
                    let wsId = try self.normalizeWorkspaceHandle(workspaceArg, client: ctx.client)
                    if let wsId { params["workspace_id"] = wsId }
                    if let type { params["type"] = type }
                    let payload = try ctx.client.sendV2(method: V2MethodNames.paneCreate, params: params)
                    self.printV2Payload(payload, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat, fallbackText: self.v2OKSummary(payload, idFormat: ctx.idFormat, kinds: ["surface", "pane", "workspace"]))
                }
            ),

            CommandDescriptor(
                names: ["new-surface"],
                helpLines: ["new-surface [--type <terminal>] [--pane <id|ref>] [--workspace <id|ref>]"],
                detailedUsage: """
                Usage: programa new-surface [flags]

                Create a new surface (tab) in a pane.

                Flags:
                  --type <terminal>   Surface type (default: terminal)
                  --pane <id|ref>             Target pane
                  --workspace <id|ref>        Target workspace (default: $PROGRAMA_WORKSPACE_ID)

                Example:
                  programa new-surface
                  programa new-surface --pane pane:1
                """,
                grammar: CLIArgumentGrammar(valueOptions: ["type", "pane", "workspace"], validate: { _, parsed in
                    if let type = parsed.options["type"], type.lowercased() != "terminal" {
                        throw CLIError(message: "new-surface: --type must be terminal")
                    }
                }),
                execute: { ctx in
                    let workspaceArg = self.workspaceFromArgsOrEnv(ctx.commandArgs, windowOverride: ctx.windowId)
                    let type = self.optionValue(ctx.commandArgs, name: "--type")
                    let paneRaw = self.optionValue(ctx.commandArgs, name: "--pane")
                    var params: [String: Any] = [:]
                    let wsId = try self.normalizeWorkspaceHandle(workspaceArg, client: ctx.client)
                    if let wsId { params["workspace_id"] = wsId }
                    let paneId = try self.normalizePaneHandle(paneRaw, client: ctx.client, workspaceHandle: wsId)
                    if let paneId { params["pane_id"] = paneId }
                    if let type { params["type"] = type }
                    let payload = try ctx.client.sendV2(method: V2MethodNames.surfaceCreate, params: params)
                    self.printV2Payload(payload, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat, fallbackText: self.v2OKSummary(payload, idFormat: ctx.idFormat, kinds: ["surface", "pane", "workspace"]))
                }
            ),

            CommandDescriptor(
                names: ["close-surface"],
                helpLines: ["close-surface [--surface <id|ref>] [--workspace <id|ref>]"],
                detailedUsage: """
                Usage: programa close-surface [flags]

                Close a surface. Defaults to the focused surface if none specified.

                Flags:
                  --surface <id|ref>     Surface to close (default: $PROGRAMA_SURFACE_ID)
                  --panel <id|ref>       Alias for --surface
                  --workspace <id|ref>   Workspace context (default: $PROGRAMA_WORKSPACE_ID)

                Example:
                  programa close-surface
                  programa close-surface --surface surface:3
                """,
                grammar: CLIArgumentGrammar(valueOptions: ["surface", "panel", "workspace"]),
                execute: { ctx in
                    let csWsFlag = self.optionValue(ctx.commandArgs, name: "--workspace")
                    let workspaceArg = csWsFlag ?? (ctx.windowId == nil ? ProcessInfo.processInfo.environment["PROGRAMA_WORKSPACE_ID"] : nil)
                    let surfaceRaw = self.optionValue(ctx.commandArgs, name: "--surface") ?? self.optionValue(ctx.commandArgs, name: "--panel")
                    var params: [String: Any] = [:]
                    let wsId = try self.normalizeWorkspaceHandle(workspaceArg, client: ctx.client)
                    if let wsId { params["workspace_id"] = wsId }
                    let sfId = try self.resolveCommandSurface(
                        explicitSurface: surfaceRaw, explicitWorkspace: csWsFlag,
                        windowId: ctx.windowId, workspaceHandle: wsId, client: ctx.client
                    )
                    if let sfId { params["surface_id"] = sfId }
                    let payload = try ctx.client.sendV2(method: V2MethodNames.surfaceClose, params: params)
                    self.printV2Payload(payload, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat, fallbackText: self.v2OKSummary(payload, idFormat: ctx.idFormat))
                }
            ),

            CommandDescriptor(
                names: ["move-surface"],
                helpLines: ["move-surface --surface <id|ref> [--pane <id|ref>] [--workspace <id|ref>] [--window <id|ref>] [--before <id|ref>] [--after <id|ref>] [--index <n>] [--focus <true|false>]"],
                detailedUsage: """
                Usage: programa move-surface [--surface <id|ref> | <id|ref>] [flags]

                Move a surface to a different pane, workspace, or window.

                Flags:
                  --surface <id|ref>   Surface to move (required unless passed positionally)
                  --pane <id|ref>      Target pane
                  --workspace <id|ref> Target workspace
                  --window <id|ref>    Target window
                  --before <id|ref>    Place before this surface
                  --before-surface <id|ref>
                                           Alias for --before
                  --after <id|ref>     Place after this surface
                  --after-surface <id|ref>
                                           Alias for --after
                  --index <n>                Place at this index
                  --focus <true|false>       Focus the surface after moving

                Example:
                  programa move-surface --surface surface:1 --workspace workspace:2
                  programa move-surface surface:1 --pane pane:2 --index 0
                """,
                grammar: CLIArgumentGrammar(valueOptions: ["surface", "pane", "workspace", "window", "before", "before-surface", "after", "after-surface", "index", "focus"], maxPositionals: 1, validate: { _, parsed in
                    guard parsed.options["surface"] != nil || parsed.positional.count == 1 else {
                        throw CLIError(message: "move-surface requires --surface <id|ref>")
                    }
                    guard !(parsed.options["surface"] != nil && !parsed.positional.isEmpty) else {
                        throw CLIError(message: "move-surface: provide the surface once")
                    }
                    if let raw = parsed.options["index"], (Int(raw) ?? -1) < 0 {
                        throw CLIError(message: "move-surface: --index must be a nonnegative integer")
                    }
                    if let raw = parsed.options["focus"], !["true", "false", "1", "0", "yes", "no", "on", "off"].contains(raw.lowercased()) {
                        throw CLIError(message: "move-surface: --focus must be true or false")
                    }
                    let anchors = ["index", "before", "before-surface", "after", "after-surface"].filter { parsed.options[$0] != nil }
                    guard anchors.count <= 1 else {
                        throw CLIError(message: "move-surface accepts only one of --index, --before, or --after")
                    }
                }),
                execute: { ctx in
                    try self.runMoveSurface(commandArgs: ctx.commandArgs, client: ctx.client, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat)
                }
            ),

            CommandDescriptor(
                names: ["reorder-surface"],
                helpLines: ["reorder-surface --surface <id|ref> (--index <n> | --before <id|ref> | --after <id|ref>)"],
                detailedUsage: """
                Usage: programa reorder-surface [--surface <id|ref> | <id|ref>] [flags]

                Reorder a surface within its pane.

                Flags:
                  --surface <id|ref>   Surface to reorder (required unless passed positionally)
                  --workspace <id|ref> Workspace context
                  --before <id|ref>    Place before this surface
                  --before-surface <id|ref>
                                           Alias for --before
                  --after <id|ref>     Place after this surface
                  --after-surface <id|ref>
                                           Alias for --after
                  --index <n>                Place at this index

                Example:
                  programa reorder-surface --surface surface:1 --index 0
                  programa reorder-surface --surface surface:3 --after surface:1
                """,
                grammar: CLIArgumentGrammar(valueOptions: ["surface", "workspace", "index", "before", "before-surface", "after", "after-surface"], maxPositionals: 1, validate: { _, parsed in
                    guard parsed.options["surface"] != nil || parsed.positional.count == 1 else {
                        throw CLIError(message: "reorder-surface requires --surface <id|ref>")
                    }
                    guard !(parsed.options["surface"] != nil && !parsed.positional.isEmpty) else {
                        throw CLIError(message: "reorder-surface: provide the surface once")
                    }
                    let anchors = ["index", "before", "before-surface", "after", "after-surface"].filter { parsed.options[$0] != nil }
                    guard anchors.count == 1 else {
                        throw CLIError(message: "reorder-surface requires exactly one of --index, --before, or --after")
                    }
                    if let raw = parsed.options["index"], (Int(raw) ?? -1) < 0 {
                        throw CLIError(message: "reorder-surface: --index must be a nonnegative integer")
                    }
                }),
                execute: { ctx in
                    try self.runReorderSurface(commandArgs: ctx.commandArgs, client: ctx.client, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat)
                }
            ),

            CommandDescriptor(
                names: ["tab-action"],
                helpLines: ["tab-action --action <name> [--tab <id|ref>] [--surface <id|ref>] [--workspace <id|ref>] [--title <text>]"],
                detailedUsage: """
                Usage: programa tab-action --action <name> [flags]

                Perform horizontal tab context-menu actions from CLI/socket.

                Actions:
                  rename | clear-name
                  close-left | close-right | close-others
                  new-terminal-right
                  reload | duplicate
                  pin | unpin
                  mark-unread

                Flags:
                  --action <name>              Action name (required if not positional)
                  --tab <id|ref>         Target tab (accepts tab:<n> or surface:<n>; default: $PROGRAMA_TAB_ID, then $PROGRAMA_SURFACE_ID, then focused tab)
                  --surface <id|ref>     Alias for --tab (backward compatibility)
                  --workspace <id|ref>   Workspace context (default: current/$PROGRAMA_WORKSPACE_ID)
                  --title <text>               Title for rename (or pass trailing title text)

                Example:
                  programa tab-action --tab tab:3 --action pin
                  programa tab-action --action close-right
                  programa tab-action --tab tab:2 --action rename --title "build logs"
                """,
                grammar: CLIArgumentGrammar(valueOptions: ["action", "tab", "surface", "workspace", "title"], maxPositionals: nil, validate: { _, parsed in
                    guard parsed.options["action"] != nil || !parsed.positional.isEmpty else {
                        throw CLIError(message: "tab-action requires --action <name>")
                    }
                }),
                execute: { ctx in
                    try self.runTabAction(commandArgs: ctx.commandArgs, client: ctx.client, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat, windowOverride: ctx.windowId)
                }
            ),

            CommandDescriptor(
                names: ["rename-tab"],
                helpLines: ["rename-tab [--workspace <id|ref>] [--tab <id|ref>] [--surface <id|ref>] <title>"],
                detailedUsage: """
                Usage: programa rename-tab [--workspace <id|ref>] [--tab <id|ref>] [--surface <id|ref>] [--] <title>

                Compatibility alias for tab-action rename.

                Resolution order for target tab:
                1) --tab
                2) --surface
                3) $PROGRAMA_TAB_ID / $PROGRAMA_SURFACE_ID
                4) currently focused tab (optionally within --workspace)

                Flags:
                  --workspace <id|ref>   Workspace context (default: current/$PROGRAMA_WORKSPACE_ID)
                  --tab <id|ref>         Tab target (supports tab:<n> or surface:<n>)
                  --surface <id|ref>     Alias for --tab
                  --title <text>         Explicit title (or use trailing positional title)

                Examples:
                  programa rename-tab "build logs"
                  programa rename-tab --tab tab:3 "staging server"
                  programa rename-tab --workspace workspace:2 --surface surface:5 --title "agent run"
                """,
                grammar: CLIArgumentGrammar(valueOptions: ["workspace", "tab", "surface", "title"], maxPositionals: nil, validate: { _, parsed in
                    guard parsed.options["title"] != nil || !parsed.positional.isEmpty else {
                        throw CLIError(message: "rename-tab requires a title")
                    }
                }),
                execute: { ctx in
                    try self.runRenameTab(commandArgs: ctx.commandArgs, client: ctx.client, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat, windowOverride: ctx.windowId)
                }
            ),

            CommandDescriptor(
                names: ["drag-surface-to-split"],
                helpLines: ["drag-surface-to-split --surface <id|ref> <left|right|up|down>"],
                detailedUsage: """
                Usage: programa drag-surface-to-split --surface <id|ref> <left|right|up|down>

                Drag a surface into a new split in the given direction.

                Flags:
                  --surface <id|ref>   Surface to drag (required)
                  --panel <id|ref>     Alias for --surface

                Example:
                  programa drag-surface-to-split --surface surface:1 right
                  programa drag-surface-to-split --panel surface:2 down
                """,
                grammar: CLIArgumentGrammar(valueOptions: ["surface", "panel"], minPositionals: 1, maxPositionals: 1, validate: { _, parsed in
                    guard (parsed.options["surface"] != nil) != (parsed.options["panel"] != nil) else {
                        throw CLIError(message: "drag-surface-to-split requires exactly one of --surface or --panel")
                    }
                    guard ["left", "right", "up", "down"].contains(parsed.positional[0].lowercased()) else {
                        throw CLIError(message: "drag-surface-to-split: invalid direction")
                    }
                }),
                execute: { ctx in
                    let (surfaceArg, rem0) = self.parseOption(ctx.commandArgs, name: "--surface")
                    let (panelArg, rem1) = self.parseOption(rem0, name: "--panel")
                    let surface = surfaceArg ?? panelArg
                    guard let surface else {
                        throw CLIError(message: "drag-surface-to-split requires --surface <id|ref>")
                    }
                    guard let direction = rem1.first else {
                        throw CLIError(message: "drag-surface-to-split requires a direction")
                    }
                    // No --workspace support: leave workspace_id unset so v2 targets the current selection.
                    let surfaceIdForDrag = try self.normalizeSurfaceHandle(surface, client: ctx.client, workspaceHandle: nil)
                    var dragParams: [String: Any] = ["direction": direction]
                    if let surfaceIdForDrag { dragParams["surface_id"] = surfaceIdForDrag }
                    let dragPayload = try ctx.client.sendV2(method: V2MethodNames.surfaceDragToSplit, params: dragParams)
                    print("OK \((dragPayload["pane_id"] as? String) ?? "")")
                }
            ),
        ]
    }

    func surfaceDiagnosticsDescriptors() -> [CommandDescriptor] {
        [
            CommandDescriptor(
                names: ["refresh-surfaces"],
                helpLines: ["refresh-surfaces"],
                detailedUsage: """
                Usage: programa refresh-surfaces

                Refresh surface snapshots for the focused workspace.
                """,
                grammar: CLIArgumentGrammar(),
                execute: { ctx in
                    // No --workspace support: leave workspace_id unset so v2 targets the current selection.
                    let refreshPayload = try ctx.client.sendV2(method: V2MethodNames.surfaceRefresh, params: [:])
                    print("OK Refreshed \(self.intFromAny(refreshPayload["refreshed"]) ?? 0) surfaces")
                }
            ),

            CommandDescriptor(
                names: ["reload-config"],
                helpLines: ["reload-config"],
                detailedUsage: """
                Usage: programa reload-config

                Run the same configuration reload as the Reload Configuration shortcut.
                This reloads Ghostty config, re-reads ~/.config/programa/settings.json, and refreshes terminals.

                Example:
                  programa reload-config
                """,
                grammar: CLIArgumentGrammar(),
                execute: { ctx in
                    if let unexpected = ctx.commandArgs.first {
                        throw CLIError(message: "reload-config does not accept arguments. Unexpected argument '\(unexpected)'")
                    }
                    _ = try ctx.client.sendV2(method: V2MethodNames.appReloadConfig)
                    print("OK Reloaded config")
                }
            ),

            CommandDescriptor(
                names: ["surface-health"],
                helpLines: ["surface-health [--workspace <id|ref>]"],
                detailedUsage: """
                Usage: programa surface-health [--workspace <id|ref>]

                List health details for surfaces in a workspace.

                Flags:
                  --workspace <id|ref>   Workspace context (default: $PROGRAMA_WORKSPACE_ID)

                Example:
                  programa surface-health
                  programa surface-health --workspace workspace:2
                """,
                grammar: CLIArgumentGrammar(valueOptions: ["workspace"]),
                execute: { ctx in
                    let workspaceArg = self.workspaceFromArgsOrEnv(ctx.commandArgs, windowOverride: ctx.windowId)
                    var params: [String: Any] = [:]
                    let wsId = try self.normalizeWorkspaceHandle(workspaceArg, client: ctx.client)
                    if let wsId { params["workspace_id"] = wsId }
                    let payload = try ctx.client.sendV2(method: V2MethodNames.surfaceHealth, params: params)
                    if ctx.jsonOutput {
                        print(self.jsonString(self.formatIDs(payload, mode: ctx.idFormat)))
                    } else {
                        let surfaces = payload["surfaces"] as? [[String: Any]] ?? []
                        if surfaces.isEmpty {
                            print("No surfaces")
                        } else {
                            for surface in surfaces {
                                let handle = self.textHandle(surface, idFormat: ctx.idFormat)
                                let sType = (surface["type"] as? String) ?? ""
                                let inWindow = surface["in_window"]
                                let inWindowStr: String
                                if let b = inWindow as? Bool {
                                    inWindowStr = " in_window=\(b)"
                                } else {
                                    inWindowStr = ""
                                }
                                print("\(handle)  type=\(sType)\(inWindowStr)")
                            }
                        }
                    }
                }
            ),

            CommandDescriptor(
                names: ["debug-terminals"],
                helpLines: [],
                detailedUsage: """
                Usage: programa debug-terminals

                Print live Ghostty terminal runtime metadata across all windows and workspaces.
                Intended for debugging stray or detached terminal views.
                """,
                grammar: CLIArgumentGrammar(),
                execute: { ctx in
                    let unexpected = ctx.commandArgs.filter { $0 != "--" }
                    if let extra = unexpected.first {
                        throw CLIError(message: "debug-terminals: unexpected argument '\(extra)'")
                    }
                    let payload = try ctx.client.sendV2(method: V2MethodNames.debugTerminals)
                    if ctx.jsonOutput {
                        print(self.jsonString(self.formatIDs(payload, mode: ctx.idFormat)))
                    } else {
                        print(self.formatDebugTerminalsPayload(payload, idFormat: ctx.idFormat))
                    }
                }
            ),

            CommandDescriptor(
                names: ["trigger-flash"],
                helpLines: ["trigger-flash [--workspace <id|ref>] [--surface <id|ref>]"],
                detailedUsage: """
                Usage: programa trigger-flash [--workspace <id|ref>] [--surface <id|ref>] [--panel <id|ref>]

                Trigger the unread flash indicator for a surface.

                Flags:
                  --workspace <id|ref>   Workspace context (default: $PROGRAMA_WORKSPACE_ID)
                  --surface <id|ref>     Target surface (default: $PROGRAMA_SURFACE_ID)
                  --panel <id|ref>       Alias for --surface

                Example:
                  programa trigger-flash
                  programa trigger-flash --workspace workspace:2 --surface surface:3
                """,
                grammar: CLIArgumentGrammar(valueOptions: ["workspace", "surface", "panel"]),
                execute: { ctx in
                    let tfWsFlag = self.optionValue(ctx.commandArgs, name: "--workspace")
                    let explicitWorkspaceArg = tfWsFlag
                    let preferTTYFallback = ctx.windowId == nil && ProcessInfo.processInfo.environment["TMUX"] != nil
                    let callerWorkspaceArg = preferTTYFallback
                        ? nil
                        : (ctx.windowId == nil ? ProcessInfo.processInfo.environment["PROGRAMA_WORKSPACE_ID"] : nil)
                    let workspaceArg = explicitWorkspaceArg ?? callerWorkspaceArg
                    let explicitSurfaceArg = self.optionValue(ctx.commandArgs, name: "--surface") ?? self.optionValue(ctx.commandArgs, name: "--panel")
                    let callerSurfaceArg = explicitSurfaceArg == nil && preferTTYFallback == false && ctx.windowId == nil
                        ? ProcessInfo.processInfo.environment["PROGRAMA_SURFACE_ID"]
                        : nil
                    let surfaceArg = explicitSurfaceArg ?? callerSurfaceArg
                    var params: [String: Any] = [:]
                    let wsId = try {
                        if explicitWorkspaceArg != nil {
                            return try self.normalizeWorkspaceHandle(workspaceArg, client: ctx.client)
                        }
                        return try self.resolveWorkspaceIdAllowingFallback(workspaceArg, client: ctx.client)
                    }()
                    if let wsId { params["workspace_id"] = wsId }
                    let sfId = try {
                        if explicitSurfaceArg != nil {
                            return try self.normalizeSurfaceHandle(surfaceArg, client: ctx.client, workspaceHandle: wsId)
                        }
                        guard let wsId else { return nil }
                        return try self.resolveSurfaceIdAllowingFallback(
                            surfaceArg,
                            workspaceId: wsId,
                            client: ctx.client
                        )
                    }()
                    if let sfId { params["surface_id"] = sfId }
                    let payload = try ctx.client.sendV2(method: V2MethodNames.surfaceTriggerFlash, params: params)
                    self.printV2Payload(payload, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat, fallbackText: self.v2OKSummary(payload, idFormat: ctx.idFormat))
                }
            ),
        ]
    }

    func panelDescriptors() -> [CommandDescriptor] {
        [
            CommandDescriptor(
                names: ["list-panels"],
                helpLines: ["list-panels [--workspace <id|ref>]"],
                detailedUsage: """
                Usage: programa list-panels [--workspace <id|ref>]

                List surfaces (panels) in a workspace.

                Flags:
                  --workspace <id|ref>   Workspace context (default: $PROGRAMA_WORKSPACE_ID)

                Example:
                  programa list-panels
                  programa list-panels --workspace workspace:2
                """,
                grammar: CLIArgumentGrammar(valueOptions: ["workspace"]),
                execute: { ctx in
                    let workspaceArg = self.workspaceFromArgsOrEnv(ctx.commandArgs, windowOverride: ctx.windowId)
                    var params: [String: Any] = [:]
                    let wsId = try self.normalizeWorkspaceHandle(workspaceArg, client: ctx.client)
                    if let wsId { params["workspace_id"] = wsId }
                    let payload = try ctx.client.sendV2(method: V2MethodNames.surfaceList, params: params)
                    if ctx.jsonOutput {
                        print(self.jsonString(self.formatIDs(payload, mode: ctx.idFormat)))
                    } else {
                        let surfaces = payload["surfaces"] as? [[String: Any]] ?? []
                        if surfaces.isEmpty {
                            print("No surfaces")
                        } else {
                            for surface in surfaces {
                                let focused = (surface["focused"] as? Bool) == true
                                let handle = self.textHandle(surface, idFormat: ctx.idFormat)
                                let sType = (surface["type"] as? String) ?? ""
                                let title = (surface["title"] as? String) ?? ""
                                let prefix = focused ? "* " : "  "
                                let focusTag = focused ? "  [focused]" : ""
                                let titlePart = title.isEmpty ? "" : "  \"\(title)\""
                                print("\(prefix)\(handle)  \(sType)\(focusTag)\(titlePart)")
                            }
                        }
                    }
                }
            ),

            CommandDescriptor(
                names: ["focus-panel"],
                helpLines: ["focus-panel --panel <id|ref> [--workspace <id|ref>]"],
                argumentContract: .focusPanel,
                detailedUsage: """
                Usage: programa focus-panel --panel <id|ref> [--workspace <id|ref>]

                Focus a specific panel (surface).

                Flags:
                  --panel <id|ref>       Panel/surface to focus (required)
                  --workspace <id|ref>   Workspace context (default: $PROGRAMA_WORKSPACE_ID)

                Example:
                  programa focus-panel --panel surface:2
                  programa focus-panel --panel surface:5 --workspace workspace:2
                """,
                execute: { ctx in
                    let workspaceArg = self.workspaceFromArgsOrEnv(ctx.commandArgs, windowOverride: ctx.windowId)
                    guard let panelRaw = self.optionValue(ctx.commandArgs, name: "--panel") else {
                        throw CLIError(message: "focus-panel requires --panel")
                    }
                    var params: [String: Any] = [:]
                    let wsId = try self.normalizeWorkspaceHandle(workspaceArg, client: ctx.client)
                    if let wsId { params["workspace_id"] = wsId }
                    let sfId = try self.normalizeSurfaceHandle(panelRaw, client: ctx.client, workspaceHandle: wsId)
                    if let sfId { params["surface_id"] = sfId }
                    let payload = try ctx.client.sendV2(method: V2MethodNames.surfaceFocus, params: params)
                    self.printV2Payload(payload, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat, fallbackText: self.v2OKSummary(payload, idFormat: ctx.idFormat))
                }
            ),
        ]
    }

    func viewerPanelDescriptors() -> [CommandDescriptor] {
        [
            CommandDescriptor(
                names: ["markdown"],
                helpLines: ["markdown [open] <path>             (open markdown file in formatted viewer panel with live reload)"],
                grammar: CLIArgumentGrammar(valueOptions: ["workspace", "window", "surface", "direction"], minPositionals: 1, maxPositionals: 2, validate: { _, parsed in
                    if parsed.positional.count == 2, parsed.positional[0].lowercased() != "open" {
                        throw CLIError(message: "markdown: unexpected subcommand \(parsed.positional[0])")
                    }
                }),
                execute: { ctx in
                    try self.runMarkdownCommand(commandArgs: ctx.commandArgs, client: ctx.client, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat)
                }
            ),

            CommandDescriptor(
                names: ["review"],
                helpLines: ["review open|refresh|comment|send  (agent diff review panel: worktree/branch diff, line comments)"],
                grammar: CLIArgumentGrammar(valueOptions: ["workspace", "window", "surface", "direction", "mode", "base-branch", "preamble"], minPositionals: 1, maxPositionals: nil, validate: { _, parsed in
                    let subcommand = parsed.positional[0].lowercased()
                    guard ["open", "refresh", "comment", "send"].contains(subcommand) else {
                        throw CLIError(message: "review: unknown subcommand \(parsed.positional[0])")
                    }
                    if subcommand == "comment" {
                        guard parsed.positional.count >= 2 else {
                            throw CLIError(message: "review comment: missing subcommand (add|remove|list)")
                        }
                        guard ["add", "remove", "list"].contains(parsed.positional[1].lowercased()) else {
                            throw CLIError(message: "review comment: unknown subcommand \(parsed.positional[1])")
                        }
                    }
                }),
                execute: { ctx in
                    try self.runReviewCommand(commandArgs: ctx.commandArgs, client: ctx.client, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat)
                }
            ),

            CommandDescriptor(
                names: ["recap"],
                helpLines: ["recap open <slug>|list             (open/list saved recaps in .programa/recaps/)"],
                grammar: CLIArgumentGrammar(valueOptions: ["workspace", "window"], minPositionals: 1, maxPositionals: 2, validate: { _, parsed in
                    let subcommand = parsed.positional[0].lowercased()
                    guard ["open", "list"].contains(subcommand) else {
                        throw CLIError(message: "recap: unknown subcommand \(parsed.positional[0])")
                    }
                    if subcommand == "open" {
                        guard parsed.positional.count == 2 else {
                            throw CLIError(message: "recap open requires <slug>")
                        }
                    } else if subcommand == "list", parsed.positional.count != 1 {
                        throw CLIError(message: "recap list: unexpected argument \(parsed.positional[1])")
                    }
                }),
                execute: { ctx in
                    try self.runRecapCommand(commandArgs: ctx.commandArgs, client: ctx.client, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat)
                }
            ),
        ]
    }
}
