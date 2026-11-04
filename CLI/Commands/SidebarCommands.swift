import Foundation

extension ProgramaCLI {
    func sidebarMetadataDescriptors() -> [CommandDescriptor] {
        [
            CommandDescriptor(
                names: ["set-status"],
                helpLines: ["set-status <key> <value> [--icon <name>] [--color <#hex>] [--url <url>] [--priority <n>] [--format <plain|markdown>] [--workspace <id|ref>]"],
                detailedUsage: """
                Usage: programa set-status <key> <value> [flags]

                Set a sidebar status entry for a workspace. Status entries appear as
                pills in the sidebar tab row. Use a unique key so different tools
                (e.g. "claude_code", "build") can manage their own entries.

                Flags:
                  --icon <name>          Icon name (e.g. "sparkle", "hammer")
                  --color <#hex>         Pill color (e.g. "#ff9500")
                  --url <url>            Link attached to the pill (alias: --link)
                  --priority <n>         Sort order, higher first (-9999 to 9999)
                  --format <plain|markdown>  How the value is rendered (default: plain)
                  --pid <pid>            Process behind this key (its listening ports are tracked)
                  --workspace <id|ref>   Target workspace (default: $PROGRAMA_WORKSPACE_ID)

                Example:
                  programa set-status build "compiling" --icon hammer --color "#ff9500"
                  programa set-status deploy "v1.2.3" --workspace workspace:2
                """,
                grammar: CLIArgumentGrammar(valueOptions: ["icon", "color", "url", "link", "priority", "format", "pid", "workspace"], minPositionals: 2, maxPositionals: nil, validate: { _, parsed in
                    if let priority = parsed.options["priority"], Int(priority) == nil {
                        throw CLIError(message: "set-status: --priority must be an integer")
                    }
                    if let format = parsed.options["format"], !["plain", "markdown", "md"].contains(format.lowercased()) {
                        throw CLIError(message: "set-status: --format must be plain or markdown")
                    }
                    if let pid = parsed.options["pid"], (Int(pid) ?? 0) <= 0 {
                        throw CLIError(message: "set-status: --pid must be a positive integer")
                    }
                }),
                execute: { ctx in
                    let parsed = self.parseFlagArgs(ctx.commandArgs, stopAtDashDash: false)
                    guard parsed.positional.count >= 2 else {
                        throw CLIError(message: "ERROR: Missing status key or value — usage: programa set-status <key> <value> [--icon <name>] [--color <#hex>] [--url <url>] [--priority <n>] [--format plain|markdown] [--pid <pid>] [--workspace <id|ref>]")
                    }
                    var params: [String: Any] = [
                        "key": parsed.positional[0],
                        "value": parsed.positional[1...].joined(separator: " "),
                    ]
                    if let icon = self.normalizedFlagValue(parsed.options["icon"]) { params["icon"] = icon }
                    if let color = self.normalizedFlagValue(parsed.options["color"]) { params["color"] = color }
                    if let url = self.normalizedFlagValue(parsed.options["url"] ?? parsed.options["link"]) { params["url"] = url }
                    if let priorityRaw = self.normalizedFlagValue(parsed.options["priority"]) {
                        guard let priority = Int(priorityRaw) else {
                            throw CLIError(message: "ERROR: Invalid metadata priority '\(priorityRaw)' — must be an integer")
                        }
                        params["priority"] = max(-9999, min(9999, priority))
                    }
                    if let formatRaw = self.normalizedFlagValue(parsed.options["format"]) {
                        guard ["plain", "markdown", "md"].contains(formatRaw.lowercased()) else {
                            throw CLIError(message: "ERROR: Invalid metadata format '\(formatRaw)' — use: plain, markdown")
                        }
                        params["format"] = formatRaw.lowercased() == "md" ? "markdown" : formatRaw.lowercased()
                    }
                    if let pidRaw = self.normalizedFlagValue(parsed.options["pid"]), let pid = Int(pidRaw), pid > 0 {
                        params["pid"] = pid
                    }
                    params["workspace_id"] = try self.resolveSidebarWorkspaceId(options: parsed.options, windowOverride: ctx.windowId, client: ctx.client)
                    _ = try ctx.client.sendV2(method: V2MethodNames.workspaceSetStatus, params: params)
                    print("OK")
                }
            ),

            CommandDescriptor(
                names: ["clear-status"],
                helpLines: ["clear-status <key> [--workspace <id|ref>]"],
                detailedUsage: """
                Usage: programa clear-status <key> [flags]

                Remove a sidebar status entry by key.

                Flags:
                  --workspace <id|ref>   Target workspace (default: $PROGRAMA_WORKSPACE_ID)

                Example:
                  programa clear-status build
                """,
                grammar: CLIArgumentGrammar(valueOptions: ["workspace"], minPositionals: 1, maxPositionals: 1),
                execute: { ctx in
                    let parsed = self.parseFlagArgs(ctx.commandArgs)
                    guard let key = parsed.positional.first, parsed.positional.count == 1 else {
                        throw CLIError(message: "ERROR: Missing metadata key — usage: programa clear-status <key> [--workspace <id|ref>]")
                    }
                    let workspaceId = try self.resolveSidebarWorkspaceId(options: parsed.options, windowOverride: ctx.windowId, client: ctx.client)
                    _ = try ctx.client.sendV2(method: V2MethodNames.workspaceClearStatus, params: ["workspace_id": workspaceId, "key": key])
                    print("OK")
                }
            ),

            CommandDescriptor(
                names: ["list-status"],
                helpLines: ["list-status [--workspace <id|ref>]"],
                detailedUsage: """
                Usage: programa list-status [flags]

                List all sidebar status entries for a workspace.

                Flags:
                  --workspace <id|ref>   Target workspace (default: $PROGRAMA_WORKSPACE_ID)

                Example:
                  programa list-status
                  programa list-status --workspace workspace:2
                """,
                grammar: CLIArgumentGrammar(valueOptions: ["workspace"]),
                execute: { ctx in
                    let parsed = self.parseFlagArgs(ctx.commandArgs)
                    let workspaceId = try self.resolveSidebarWorkspaceId(options: parsed.options, windowOverride: ctx.windowId, client: ctx.client)
                    let payload = try ctx.client.sendV2(method: V2MethodNames.workspaceListStatus, params: ["workspace_id": workspaceId])
                    let entries = payload["entries"] as? [[String: Any]] ?? []
                    if entries.isEmpty {
                        print("No status entries")
                    } else {
                        print(entries.map(self.sidebarMetadataLineText).joined(separator: "\n"))
                    }
                }
            ),

            CommandDescriptor(
                names: ["set-progress"],
                helpLines: ["set-progress <0.0-1.0> [--label <text>] [--workspace <id|ref>]"],
                argumentContract: .setProgress,
                detailedUsage: """
                Usage: programa set-progress <0.0-1.0> [flags]

                Set a progress bar in the sidebar for a workspace.

                Flags:
                  --label <text>         Label shown next to the progress bar
                  --workspace <id|ref>   Target workspace (default: $PROGRAMA_WORKSPACE_ID)

                Example:
                  programa set-progress 0.5 --label "Building..."
                  programa set-progress 1.0 --label "Done"
                """,
                execute: { ctx in
                    let parsed = self.parseFlagArgs(ctx.commandArgs)
                    guard let first = parsed.positional.first else {
                        throw CLIError(message: "ERROR: Missing progress value — usage: programa set-progress <0.0-1.0> [--label <text>] [--workspace <id|ref>]")
                    }
                    guard let value = Double(first), value.isFinite else {
                        throw CLIError(message: "ERROR: Invalid progress value '\(first)' — must be 0.0 to 1.0")
                    }
                    var params: [String: Any] = ["value": min(1.0, max(0.0, value))]
                    if let label = self.normalizedFlagValue(parsed.options["label"]) { params["label"] = label }
                    params["workspace_id"] = try self.resolveSidebarWorkspaceId(options: parsed.options, windowOverride: ctx.windowId, client: ctx.client)
                    _ = try ctx.client.sendV2(method: V2MethodNames.workspaceSetProgress, params: params)
                    print("OK")
                }
            ),

            CommandDescriptor(
                names: ["clear-progress"],
                helpLines: ["clear-progress [--workspace <id|ref>]"],
                detailedUsage: """
                Usage: programa clear-progress [flags]

                Clear the sidebar progress bar for a workspace.

                Flags:
                  --workspace <id|ref>   Target workspace (default: $PROGRAMA_WORKSPACE_ID)

                Example:
                  programa clear-progress
                """,
                grammar: CLIArgumentGrammar(valueOptions: ["workspace"]),
                execute: { ctx in
                    let parsed = self.parseFlagArgs(ctx.commandArgs)
                    let workspaceId = try self.resolveSidebarWorkspaceId(options: parsed.options, windowOverride: ctx.windowId, client: ctx.client)
                    _ = try ctx.client.sendV2(method: V2MethodNames.workspaceClearProgress, params: ["workspace_id": workspaceId])
                    print("OK")
                }
            ),

            CommandDescriptor(
                names: ["log"],
                helpLines: ["log [--level <level>] [--source <name>] [--workspace <id|ref>] [--] <message>"],
                detailedUsage: """
                Usage: programa log [flags] [--] <message>

                Append a log entry to the sidebar for a workspace.

                Flags:
                  --level <level>        Log level: info, progress, success, warning, error (default: info)
                  --source <name>        Source label (e.g. "build", "test")
                  --workspace <id|ref>   Target workspace (default: $PROGRAMA_WORKSPACE_ID)

                Example:
                  programa log "Build started"
                  programa log --level error --source build "Compilation failed"
                  programa log --level success -- "All 42 tests passed"
                """,
                grammar: CLIArgumentGrammar(valueOptions: ["level", "source", "workspace"], minPositionals: 1, maxPositionals: nil, validate: { _, parsed in
                    if let level = parsed.options["level"], !["info", "progress", "success", "warning", "error"].contains(level) {
                        throw CLIError(message: "log: invalid --level value")
                    }
                }),
                execute: { ctx in
                    let parsed = self.parseFlagArgs(ctx.commandArgs)
                    guard !parsed.positional.isEmpty else {
                        throw CLIError(message: "ERROR: Missing message — usage: programa log [--level <level>] [--source <name>] [--workspace <id|ref>] [--] <message>")
                    }
                    let levelStr = parsed.options["level"] ?? "info"
                    guard ["info", "progress", "success", "warning", "error"].contains(levelStr) else {
                        throw CLIError(message: "ERROR: Unknown log level '\(levelStr)' — use: info, progress, success, warning, error")
                    }
                    var params: [String: Any] = [
                        "message": parsed.positional.joined(separator: " "),
                        "level": levelStr,
                    ]
                    if let source = self.normalizedFlagValue(parsed.options["source"]) { params["source"] = source }
                    params["workspace_id"] = try self.resolveSidebarWorkspaceId(options: parsed.options, windowOverride: ctx.windowId, client: ctx.client)
                    _ = try ctx.client.sendV2(method: V2MethodNames.workspaceLog, params: params)
                    print("OK")
                }
            ),

            CommandDescriptor(
                names: ["clear-log"],
                helpLines: ["clear-log [--workspace <id|ref>]"],
                detailedUsage: """
                Usage: programa clear-log [flags]

                Clear all sidebar log entries for a workspace.

                Flags:
                  --workspace <id|ref>   Target workspace (default: $PROGRAMA_WORKSPACE_ID)

                Example:
                  programa clear-log
                """,
                grammar: CLIArgumentGrammar(valueOptions: ["workspace"]),
                execute: { ctx in
                    let parsed = self.parseFlagArgs(ctx.commandArgs)
                    let workspaceId = try self.resolveSidebarWorkspaceId(options: parsed.options, windowOverride: ctx.windowId, client: ctx.client)
                    _ = try ctx.client.sendV2(method: V2MethodNames.workspaceClearLog, params: ["workspace_id": workspaceId])
                    print("OK")
                }
            ),

            CommandDescriptor(
                names: ["list-log"],
                helpLines: ["list-log [--limit <n>] [--workspace <id|ref>]"],
                argumentContract: .listLog,
                detailedUsage: """
                Usage: programa list-log [flags]

                List sidebar log entries for a workspace.

                Flags:
                  --limit <n>            Show only the last N entries
                  --workspace <id|ref>   Target workspace (default: $PROGRAMA_WORKSPACE_ID)

                Example:
                  programa list-log
                  programa list-log --limit 5
                """,
                execute: { ctx in
                    let parsed = self.parseFlagArgs(ctx.commandArgs)
                    var params: [String: Any] = [:]
                    if let limitStr = parsed.options["limit"] {
                        guard !limitStr.isEmpty else {
                            throw CLIError(message: "ERROR: Missing limit value — usage: programa list-log [--limit <n>] [--workspace <id|ref>]")
                        }
                        guard let limit = Int(limitStr), limit >= 0 else {
                            throw CLIError(message: "ERROR: Invalid limit '\(limitStr)' — must be >= 0")
                        }
                        params["limit"] = limit
                    }
                    params["workspace_id"] = try self.resolveSidebarWorkspaceId(options: parsed.options, windowOverride: ctx.windowId, client: ctx.client)
                    let payload = try ctx.client.sendV2(method: V2MethodNames.workspaceListLog, params: params)
                    let entries = payload["entries"] as? [[String: Any]] ?? []
                    if entries.isEmpty {
                        print("No log entries")
                    } else {
                        print(entries.map(self.sidebarLogLineText).joined(separator: "\n"))
                    }
                }
            ),

            CommandDescriptor(
                names: ["sidebar-state"],
                helpLines: ["sidebar-state [--workspace <id|ref>]"],
                detailedUsage: """
                Usage: programa sidebar-state [flags]

                Dump all sidebar metadata for a workspace (cwd, git branch, ports,
                status entries, progress, log entries).

                Flags:
                  --workspace <id|ref>   Target workspace (default: $PROGRAMA_WORKSPACE_ID)

                Example:
                  programa sidebar-state
                  programa sidebar-state --workspace workspace:2
                """,
                grammar: CLIArgumentGrammar(valueOptions: ["workspace"]),
                execute: { ctx in
                    let parsed = self.parseFlagArgs(ctx.commandArgs)
                    let workspaceId = try self.resolveSidebarWorkspaceId(options: parsed.options, windowOverride: ctx.windowId, client: ctx.client)
                    let payload = try ctx.client.sendV2(method: V2MethodNames.workspaceSidebarState, params: ["workspace_id": workspaceId])
                    print(self.sidebarStateText(payload))
                }
            ),
        ]
    }
}
