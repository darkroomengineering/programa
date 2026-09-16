import Foundation

extension ProgramaCLI {
    /// Subcommand help text for Hooks commands, split out of the
    /// central `subcommandUsage` switch (programa.swift) so each domain's
    /// help text lives next to its command descriptors. Refs #101.
    func hooksSubcommandUsage(_ command: String) -> String? {
        switch command {
        case "claude-hook":
            return """
            Usage: programa claude-hook <session-start|stop|session-end|notification|prompt-submit|pre-tool-use|subagent-start|subagent-stop> [flags]

            Hook for Claude Code integration. Reads JSON from stdin.

            Subcommands:
              session-start   Signal that a Claude session has started
              active          Alias for session-start
              stop            Signal that a Claude session has stopped
              idle            Alias for stop
              notification    Forward a Claude notification
              notify          Alias for notification
              prompt-submit   Clear notification and set Running on user prompt
              session-end     Clean up a Claude session when it exits
              pre-tool-use    Update the current task before a tool runs
              subagent-start  Track a helper when it starts
              subagent-stop   Mark a helper as finished

            Flags:
              --workspace <id|ref>   Target workspace (default: $PROGRAMA_WORKSPACE_ID)
              --surface <id|ref>     Target surface (default: $PROGRAMA_SURFACE_ID)

            Example:
              echo '{"session_id":"abc"}' | programa claude-hook session-start
              echo '{}' | programa claude-hook stop
            """
        case "codex":
            return """
            Usage: programa codex <install-hooks|uninstall-hooks>

            Manage Codex CLI hooks integration.

            Subcommands:
              install-hooks     Install programa hooks into ~/.codex/hooks.json,
                                 plus the agent skill into ~/.agents/skills/programa/
              uninstall-hooks   Remove programa hooks from ~/.codex/hooks.json,
                                 plus the agent skill if programa-managed
            """
        case "codex-hook":
            return """
            Usage: programa codex-hook <session-start|prompt-submit|stop|notification|session-end> [flags]

            Hook for Codex CLI integration. Reads JSON from stdin.
            Gracefully no-ops when not running inside programa.

            Subcommands:
              session-start   Register a Codex session
              prompt-submit   Set Running status on user prompt
              stop            Send completion notification, set Idle
              notification    Send an attention-classified notification, set Needs input
              session-end     Final cleanup when the Codex process exits (Ctrl+C/kill)

            Flags:
              --workspace <id|ref>   Target workspace (default: $PROGRAMA_WORKSPACE_ID)
              --surface <id|ref>     Target surface (default: $PROGRAMA_SURFACE_ID)
            """
        case "opencode":
            return """
            Usage: programa opencode <install-integration|uninstall-integration>

            Manage Programa's OpenCode plugin integration.

            Subcommands:
              install-integration     Install programa's plugin into ~/.config/opencode/plugins/programa.js,
                                       plus the agent skill into ~/.config/opencode/skills/programa/
              uninstall-integration   Remove programa's plugin (refuses if you've customized the file),
                                       plus the agent skill if programa-managed
            """
        case "opencode-hook":
            return """
            Usage: programa opencode-hook <session-start|prompt-submit|stop|notification|session-end> [flags]

            Hook for the OpenCode plugin integration. Reads --cwd/--session flags passed
            by the plugin (stdin JSON is tolerated but not required). Gracefully no-ops
            when not running inside programa.

            Subcommands:
              session-start   Register an OpenCode session (plugin boot)
              prompt-submit   Set Running status on user prompt (chat.message)
              stop            Send completion notification, set Idle (session.idle)
              notification    Send an attention notification, set Needs input (permission.asked)
              session-end     Final cleanup when the OpenCode plugin disposes

            Flags:
              --cwd <path>           Working directory reported by the plugin
              --session <id>         OpenCode session id, when available
              --workspace <id|ref>   Target workspace (default: $PROGRAMA_WORKSPACE_ID)
              --surface <id|ref>     Target surface (default: $PROGRAMA_SURFACE_ID)
            """
        default:
            return nil
        }
    }

    /// Hook command descriptors live beside their help text while hook-provider
    /// state and installation remain in CLI+Hooks.
    func hooksDescriptors() -> [CommandDescriptor] {
        [
            CommandDescriptor(
                names: ["claude-hook"],
                helpLines: ["claude-hook <session-start|stop|session-end|notification|prompt-submit|pre-tool-use|subagent-start|subagent-stop> [--workspace <id|ref>] [--surface <id|ref>]"],
                execute: { ctx in
                    try self.runClaudeHook(commandArgs: ctx.commandArgs, client: ctx.client)
                }
            ),
            CommandDescriptor(
                names: ["codex-hook"],
                helpLines: [],
                execute: { ctx in
                    try self.runCodexHook(commandArgs: ctx.commandArgs, client: ctx.client)
                }
            ),
            CommandDescriptor(
                names: ["opencode-hook"],
                helpLines: [],
                execute: { ctx in
                    try self.runOpenCodeHook(commandArgs: ctx.commandArgs, client: ctx.client)
                }
            ),
            CommandDescriptor(
                names: ["agent-event"],
                helpLines: ["agent-event --event <event_type> [--provider <p>] [--session-id <id>] [--turn-id <id>] [--item-id <id>] [--label <text>] [--resolution <r>] [--workspace <id|ref>] [--surface <id|ref>]"],
                detailedUsage: """
                Usage: programa agent-event --event <event_type> [flags]

                Report a normalized agent lifecycle event (docs/plans/agent-events.md). One
                fixed CLI invocation, meant for provider adapters whose installed hook command
                needs a single command rather than a stdin-parsing subcommand (Codex hooks.json,
                the OpenCode plugin), and as a documented, testable entry point for tests_v2.

                --event must be one of:
                  session.started, session.exited, turn.started, turn.completed, turn.aborted,
                  request.opened, request.resolved, user-input.requested, user-input.resolved,
                  item.started, item.completed

                Flags:
                  --event <event_type>   Required. One of the values above.
                  --provider <p>         Provider name (e.g. claude-code, codex, opencode)
                  --session-id <id>      Provider's own session/thread id
                  --turn-id <id>         Turn id, when the provider gives one
                  --item-id <id>         Tool-call/item id, for item.* events
                  --label <text>         Human-readable summary (tool name, question text)
                  --resolution <r>       approved, denied, or answered (request/user-input.resolved)
                  --workspace <id|ref>   Target workspace (default: $PROGRAMA_WORKSPACE_ID)
                  --surface <id|ref>     Target surface (default: $PROGRAMA_SURFACE_ID)

                Example:
                  programa agent-event --provider codex --event turn.started
                  programa agent-event --provider codex --event session.exited
                """,
                grammar: CLIArgumentGrammar(
                    valueOptions: [
                        "event", "provider", "session-id", "turn-id", "item-id",
                        "label", "resolution", "workspace", "surface",
                    ],
                    requiredOptions: ["event"],
                    maxPositionals: 0
                ),
                execute: { ctx in
                    let (providerArg, rem0) = self.parseOption(ctx.commandArgs, name: "--provider")
                    let (eventArg, rem1) = self.parseOption(rem0, name: "--event")
                    let (sessionIdArg, rem2) = self.parseOption(rem1, name: "--session-id")
                    let (turnIdArg, rem3) = self.parseOption(rem2, name: "--turn-id")
                    let (itemIdArg, rem4) = self.parseOption(rem3, name: "--item-id")
                    let (labelArg, rem5) = self.parseOption(rem4, name: "--label")
                    let (resolutionArg, rem6) = self.parseOption(rem5, name: "--resolution")
                    let (wsArg, rem7) = self.parseOption(rem6, name: "--workspace")
                    let (sfArg, rem8) = self.parseOption(rem7, name: "--surface")
                    if !rem8.isEmpty {
                        throw CLIError(message: "agent-event: unexpected arguments: \(rem8.joined(separator: " "))")
                    }

                    let validEventTypes: Set<String> = [
                        "session.started", "session.exited",
                        "turn.started", "turn.completed", "turn.aborted",
                        "request.opened", "request.resolved",
                        "user-input.requested", "user-input.resolved",
                        "item.started", "item.completed",
                    ]
                    guard let eventArg else {
                        throw CLIError(message: "agent-event: --event is required")
                    }
                    guard validEventTypes.contains(eventArg) else {
                        throw CLIError(message: "agent-event: invalid --event '\(eventArg)' — use one of: \(validEventTypes.sorted().joined(separator: ", "))")
                    }

                    let workspaceArg = wsArg ?? (ctx.windowId == nil ? ProcessInfo.processInfo.environment["PROGRAMA_WORKSPACE_ID"] : nil)
                    let surfaceArg = sfArg ?? (workspaceArg == nil && ctx.windowId == nil ? ProcessInfo.processInfo.environment["PROGRAMA_SURFACE_ID"] : nil)

                    var params: [String: Any] = ["event_type": eventArg]
                    let wsId = try self.normalizeWorkspaceHandle(workspaceArg, client: ctx.client)
                    if let wsId { params["workspace_id"] = wsId }
                    let sfId = try self.normalizeSurfaceHandle(surfaceArg, client: ctx.client, workspaceHandle: wsId)
                    if let sfId { params["surface_id"] = sfId }
                    if let providerArg { params["provider"] = providerArg }
                    if let sessionIdArg { params["session_id"] = sessionIdArg }
                    if let turnIdArg { params["turn_id"] = turnIdArg }
                    if let itemIdArg { params["item_id"] = itemIdArg }
                    if let labelArg { params["label"] = labelArg }
                    if let resolutionArg { params["resolution"] = resolutionArg }

                    let payload = try ctx.client.sendV2(method: "agent.event", params: params)
                    if ctx.jsonOutput {
                        print(self.jsonString(payload))
                    } else if let state = payload["state"] as? String {
                        print(state)
                    } else {
                        print("cleared")
                    }
                }
            ),
        ]
    }
}
