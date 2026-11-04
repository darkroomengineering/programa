import Foundation

extension ProgramaCLI {
    func systemCommandDescriptors() -> [CommandDescriptor] {
        [
            CommandDescriptor(
                names: ["ping"],
                helpLines: ["ping"],
                argumentContract: .noArguments,
                detailedUsage: """
                Usage: programa ping

                Check connectivity to the programa socket server.
                """,
                execute: { ctx in
                    let payload = try ctx.client.sendV2(method: V2MethodNames.systemPing)
                    self.printV2Payload(payload, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat, fallbackText: "PONG")
                }
            ),

            CommandDescriptor(names: ["version"], helpLines: ["version"], connectionPolicy: .local, grammar: CLIArgumentGrammar(), execute: nil),

            CommandDescriptor(
                names: ["capabilities"],
                helpLines: ["capabilities"],
                detailedUsage: """
                Usage: programa capabilities

                Print server capabilities as JSON.
                """,
                grammar: CLIArgumentGrammar(),
                execute: { ctx in
                    let response = try ctx.client.sendV2(method: V2MethodNames.systemCapabilities)
                    print(self.jsonString(self.formatIDs(response, mode: ctx.idFormat)))
                }
            ),

            CommandDescriptor(
                names: ["rpc"],
                helpLines: ["rpc <method> [json-params]"],
                detailedUsage: """
                Usage: programa rpc <method> [json-params]

                Call a raw v2 method with an optional JSON object for params.
                Example: programa rpc surface.report_tty '{"workspace_id":"...","surface_id":"...","tty_name":"ttys001"}'
                """,
                grammar: CLIArgumentGrammar(minPositionals: 1, maxPositionals: 2, validate: { _, parsed in
                    _ = try self.parseRPCParams(Array(parsed.positional.dropFirst()))
                }),
                execute: { ctx in
                    guard let method = ctx.commandArgs.first?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !method.isEmpty else {
                        throw CLIError(message: "Usage: programa rpc <method> [json-params]")
                    }
                    let params = try self.parseRPCParams(Array(ctx.commandArgs.dropFirst()))
                    let response = try ctx.client.sendV2(method: method, params: params)
                    let output: Any = ctx.idFormatArgProvided ? self.formatIDs(response, mode: ctx.idFormat) : response
                    print(self.jsonString(output))
                }
            ),

            CommandDescriptor(
                names: ["identify"],
                helpLines: ["identify [--workspace <id|ref>] [--surface <id|ref>] [--no-caller]"],
                detailedUsage: """
                Usage: programa identify [--workspace <id|ref>] [--surface <id|ref>] [--no-caller]

                Print server identity and caller context details.

                Flags:
                  --workspace <id|ref>   Caller workspace context (default: $PROGRAMA_WORKSPACE_ID)
                  --surface <id|ref>     Caller surface context (default: $PROGRAMA_SURFACE_ID)
                  --no-caller                  Omit caller context from the request
                """,
                grammar: CLIArgumentGrammar(valueOptions: ["workspace", "surface"], booleanOptions: ["no-caller"]),
                execute: { ctx in
                    var params: [String: Any] = [:]
                    let includeCaller = !self.hasFlag(ctx.commandArgs, name: "--no-caller")
                    if includeCaller {
                        let idWsFlag = self.optionValue(ctx.commandArgs, name: "--workspace")
                        let workspaceArg = idWsFlag ?? (ctx.windowId == nil ? ProcessInfo.processInfo.environment["PROGRAMA_WORKSPACE_ID"] : nil)
                        let surfaceArg = self.optionValue(ctx.commandArgs, name: "--surface") ?? (idWsFlag == nil && ctx.windowId == nil ? ProcessInfo.processInfo.environment["PROGRAMA_SURFACE_ID"] : nil)
                        if workspaceArg != nil || surfaceArg != nil {
                            let workspaceId = try self.normalizeWorkspaceHandle(
                                workspaceArg,
                                client: ctx.client,
                                allowCurrent: surfaceArg != nil
                            )
                            var caller: [String: Any] = [:]
                            if let workspaceId {
                                caller["workspace_id"] = workspaceId
                            }
                            if surfaceArg != nil {
                                guard let surfaceId = try self.normalizeSurfaceHandle(
                                    surfaceArg,
                                    client: ctx.client,
                                    workspaceHandle: workspaceId
                                ) else {
                                    throw CLIError(message: "Invalid surface handle")
                                }
                                caller["surface_id"] = surfaceId
                            }
                            if !caller.isEmpty {
                                params["caller"] = caller
                            }
                        }
                    }
                    let response = try ctx.client.sendV2(method: V2MethodNames.systemIdentify, params: params)
                    print(self.jsonString(self.formatIDs(response, mode: ctx.idFormat)))
                }
            ),
        ]
    }

    /// Test-only focus overrides and the `claude-teams` tmux shim entrypoint.
    func internalCommandDescriptors() -> [CommandDescriptor] {
        [
            CommandDescriptor(
                names: ["set-app-focus"],
                helpLines: ["set-app-focus <active|inactive|clear>"],
                detailedUsage: """
                Usage: programa set-app-focus <active|inactive|clear>

                Override app focus state for notification routing tests.

                Example:
                  programa set-app-focus inactive
                  programa set-app-focus clear
                """,
                grammar: CLIArgumentGrammar(minPositionals: 1, maxPositionals: 1, validate: { _, parsed in
                    guard ["active", "inactive", "clear", "1", "0", "true", "false", "none"].contains(parsed.positional[0].lowercased()) else {
                        throw CLIError(message: "set-app-focus: invalid state")
                    }
                }),
                execute: { ctx in
                    guard let value = ctx.commandArgs.first else { throw CLIError(message: "set-app-focus requires a value") }
                    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    let state: String
                    switch normalized {
                    case "active", "1", "true": state = "active"
                    case "inactive", "0", "false": state = "inactive"
                    case "clear", "none", "": state = "clear"
                    default:
                        throw CLIError(message: "ERROR: Expected active, inactive, or clear")
                    }
                    _ = try ctx.client.sendV2(method: V2MethodNames.appFocusOverrideSet, params: ["state": state])
                    print("OK")
                }
            ),

            CommandDescriptor(
                names: ["simulate-app-active"],
                helpLines: ["simulate-app-active"],
                detailedUsage: """
                Usage: programa simulate-app-active

                Trigger the app-active handler used by notification focus tests.
                """,
                grammar: CLIArgumentGrammar(),
                execute: { ctx in
                    _ = try ctx.client.sendV2(method: V2MethodNames.appSimulateActive)
                    print("OK")
                }
            ),

            CommandDescriptor(
                names: ["__tmux-compat"],
                helpLines: [],
                helpPolicy: .passthrough,
                argumentContract: .handlerParsed,
                execute: { ctx in
                    try self.runClaudeTeamsTmuxCompat(
                        commandArgs: ctx.commandArgs,
                        client: ctx.client,
                        jsonOutput: ctx.jsonOutput,
                        idFormat: ctx.idFormat,
                        windowOverride: ctx.windowId
                    )
                }
            ),
        ]
    }

    func helpCommandDescriptors() -> [CommandDescriptor] {
        [
            CommandDescriptor(
                names: ["help"],
                helpLines: ["help"],
                connectionPolicy: .local,
                detailedUsage: """
                Usage: programa help

                Show top-level CLI usage and command list.
                """,
                grammar: CLIArgumentGrammar(),
                execute: { ctx in
                    print(self.usage())
                }
            ),
        ]
    }
}
