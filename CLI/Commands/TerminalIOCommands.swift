import Foundation

extension ProgramaCLI {
    func terminalIODescriptors() -> [CommandDescriptor] {
        [
            CommandDescriptor(
                names: ["read-screen"],
                helpLines: ["read-screen [--workspace <id|ref>] [--surface <id|ref>] [--scrollback] [--lines <n>]"],
                argumentContract: .readScreen,
                detailedUsage: """
                Usage: programa read-screen [flags]

                Read terminal text from a surface as plain text.

                Flags:
                  --workspace <id|ref>   Target workspace (default: $PROGRAMA_WORKSPACE_ID)
                  --surface <id|ref>     Target surface (default: $PROGRAMA_SURFACE_ID)
                  --scrollback           Include scrollback (not just visible viewport)
                  --lines <n>            Limit to the last n lines (implies --scrollback)

                Example:
                  programa read-screen
                  programa read-screen --surface surface:2 --scrollback --lines 200
                """,
                execute: { ctx in
                    let (wsArg, rem0) = self.parseOption(ctx.commandArgs, name: "--workspace")
                    let (sfArg, rem1) = self.parseOption(rem0, name: "--surface")
                    let (linesArg, rem2) = self.parseOption(rem1, name: "--lines")
                    let trailing = rem2.filter { $0 != "--scrollback" }
                    if !trailing.isEmpty {
                        throw CLIError(message: "read-screen: unexpected arguments: \(trailing.joined(separator: " "))")
                    }

                    let workspaceArg = wsArg ?? (ctx.windowId == nil ? ProcessInfo.processInfo.environment["PROGRAMA_WORKSPACE_ID"] : nil)

                    var params: [String: Any] = [:]
                    let wsId = try self.normalizeWorkspaceHandle(workspaceArg, client: ctx.client)
                    if let wsId { params["workspace_id"] = wsId }
                    let sfId = try self.resolveCommandSurface(
                        explicitSurface: sfArg, explicitWorkspace: wsArg,
                        windowId: ctx.windowId, workspaceHandle: wsId, client: ctx.client
                    )
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

                    let payload = try ctx.client.sendV2(method: V2MethodNames.surfaceReadText, params: params)
                    if ctx.jsonOutput {
                        print(self.jsonString(payload))
                    } else {
                        print((payload["text"] as? String) ?? "")
                    }
                }
            ),

            CommandDescriptor(
                names: ["wait-surface"],
                helpLines: ["wait-surface [--workspace <id|ref>] [--surface <id|ref>] (--pattern <regex> | --exit | --agent-state <state>) [--timeout <seconds>] [--lines <n>]"],
                argumentContract: .waitSurface,
                detailedUsage: """
                Usage: programa wait-surface [flags]

                Block until a surface hits a condition, in one server-owned request -- no
                polling loop needed. Answers as soon as the condition is met (or is already
                true when the call arrives) or the timeout elapses.

                Flags:
                  --workspace <id|ref>   Target workspace (default: $PROGRAMA_WORKSPACE_ID)
                  --surface <id|ref>     Target surface (default: $PROGRAMA_SURFACE_ID)
                  --pattern <regex>      Wait until output (screen + scrollback) matches this regex
                  --exit                 Wait until the surface's child process exits
                  --agent-state <state>  Wait until the agent's reported state is idle, working,
                                         blocked, or any_change (lifecycle-hook agents)
                  --timeout <seconds>    Give up after this long (default: 30)
                  --lines <n>            Cap how much scrollback --pattern rereads per check (default: 2000)

                Exactly one of --pattern / --exit / --agent-state is required. A marker already
                present when the call arrives (or a process that has already exited, or an agent
                already in the state; a surface with no reported state counts as idle) resolves
                immediately --
                `waited: false` in JSON output distinguishes that from an actual wait.

                Example:
                  programa wait-surface --pattern 'BUILD (SUCCEEDED|FAILED)' --timeout 120
                  programa wait-surface --surface surface:2 --exit --timeout 10
                  programa wait-surface --surface surface:2 --agent-state idle --timeout 300
                """,
                execute: { ctx in
                    let (wsArg, rem0) = self.parseOption(ctx.commandArgs, name: "--workspace")
                    let (sfArg, rem1) = self.parseOption(rem0, name: "--surface")
                    let (patternArg, rem2) = self.parseOption(rem1, name: "--pattern")
                    let (timeoutArg, rem3) = self.parseOption(rem2, name: "--timeout")
                    let (linesArg, rem4) = self.parseOption(rem3, name: "--lines")
                    let (agentStateArg, rem5) = self.parseOption(rem4, name: "--agent-state")
                    let exitFlag = rem5.contains("--exit")
                    let trailing = rem5.filter { $0 != "--exit" }
                    if !trailing.isEmpty {
                        throw CLIError(message: "wait-surface: unexpected arguments: \(trailing.joined(separator: " "))")
                    }
                    guard [patternArg != nil, exitFlag, agentStateArg != nil].filter({ $0 }).count == 1 else {
                        throw CLIError(message: "wait-surface requires exactly one of --pattern <regex>, --exit, or --agent-state <idle|working|blocked|any_change>")
                    }

                    let workspaceArg = wsArg ?? (ctx.windowId == nil ? ProcessInfo.processInfo.environment["PROGRAMA_WORKSPACE_ID"] : nil)

                    var params: [String: Any] = [:]
                    let wsId = try self.normalizeWorkspaceHandle(workspaceArg, client: ctx.client)
                    if let wsId { params["workspace_id"] = wsId }
                    let sfId = try self.resolveCommandSurface(
                        explicitSurface: sfArg, explicitWorkspace: wsArg,
                        windowId: ctx.windowId, workspaceHandle: wsId, client: ctx.client
                    )
                    if let sfId { params["surface_id"] = sfId }

                    if let patternArg {
                        params["pattern"] = patternArg
                    } else if let agentStateArg {
                        params["agent_state"] = agentStateArg
                    } else {
                        params["exit"] = true
                    }

                    var timeoutSeconds = 30.0
                    if let timeoutArg {
                        guard let parsed = Double(timeoutArg), parsed.isFinite, parsed > 0 else {
                            throw CLIError(message: "wait-surface: --timeout must be a positive number of seconds")
                        }
                        timeoutSeconds = parsed
                        params["timeout_ms"] = Int((parsed * 1000).rounded())
                    }
                    if let linesArg {
                        guard let lineCount = Int(linesArg), lineCount > 0 else {
                            throw CLIError(message: "wait-surface: --lines must be greater than 0")
                        }
                        params["lines"] = lineCount
                    }

                    // The server may legitimately hold this connection open for the full
                    // --timeout; give the client-side socket read at least that long (plus a
                    // buffer for the response round trip) rather than the default 15s.
                    let payload = try ctx.client.sendV2(
                        method: V2MethodNames.surfaceWait,
                        params: params,
                        minimumReceiveTimeout: timeoutSeconds + 5.0
                    )
                    if ctx.jsonOutput {
                        print(self.jsonString(payload))
                    } else if let match = payload["match"] as? String {
                        print(match)
                    } else if exitFlag {
                        print("exited")
                    } else if agentStateArg != nil {
                        print((payload["state"] as? String) ?? "ok")
                    } else {
                        print("ok")
                    }
                }
            ),

            CommandDescriptor(
                names: ["prompt-agent"],
                helpLines: ["prompt-agent [--workspace <id|ref>] [--surface <id|ref>] [--timeout <seconds>] [--working-grace <seconds>] [--force] [--answer-prompt] <text>"],
                detailedUsage: """
                Usage: programa prompt-agent [flags] [--] <text>

                Submit a prompt to an agent surface and wait for it to finish, in one
                request -- built on surface.wait's agent_state condition (#166). Sends
                <text> (+ Enter) the same way `send` does, waits up to --working-grace for
                the agent to report it started working (capped by the remaining --timeout),
                then waits up to the remaining --timeout for it to report idle again.

                If the agent never reports "working" before that capped grace expires --
                including when the overall deadline arrives first -- the call resolves
                immediately (working_observed: false in JSON output), rather than returning
                a timeout error. If the surface never reported any agent_state at all, JSON
                output carries a `warning` noting hooks may not be installed.

                If a person has typed into the surface and not submitted it, the command waits
                for them to submit or clear it, then sends. If --timeout runs out first, nothing
                is sent and the command fails (draft_in_progress). --force sends without waiting.

                If the agent waits on a permission or sign-in prompt, nothing is sent and the
                command fails at once (agent_awaiting_approval). Ask the person to answer it;
                --answer-prompt sends anyway, only when they asked you to answer for them.

                Flags:
                  --workspace <id|ref>      Target workspace (default: $PROGRAMA_WORKSPACE_ID)
                  --surface <id|ref>        Target surface (default: $PROGRAMA_SURFACE_ID)
                  --timeout <seconds>       Overall budget for the agent to finish (default: 120)
                  --working-grace <seconds> How long to wait for a "working" report before
                                            giving up on observing it, capped by the remaining
                                            --timeout budget (default: 3)
                  --force                   Send even if a person has unsent typed input in the
                                            surface
                  --answer-prompt           Send even if the agent waits on an approval prompt

                Example:
                  programa prompt-agent "review this diff for bugs"
                  programa prompt-agent --surface surface:2 --timeout 300 "run the test suite"
                """,
                grammar: CLIArgumentGrammar(valueOptions: ["workspace", "surface", "timeout", "working-grace"], booleanOptions: ["force", "answer-prompt"], minPositionals: 1, maxPositionals: nil),
                execute: { ctx in
                    let (wsArg, rem0) = self.parseOption(ctx.commandArgs, name: "--workspace")
                    let (sfArg, rem1) = self.parseOption(rem0, name: "--surface")
                    let (timeoutArg, rem2) = self.parseOption(rem1, name: "--timeout")
                    let (graceArg, rem3) = self.parseOption(rem2, name: "--working-grace")
                    let (force, rem4) = self.takeFlag("--force", rem3)
                    let (answerPrompt, rem5) = self.takeFlag("--answer-prompt", rem4)
                    let workspaceArg = wsArg ?? (ctx.windowId == nil ? ProcessInfo.processInfo.environment["PROGRAMA_WORKSPACE_ID"] : nil)
                    let rawText = rem5.dropFirst(rem5.first == "--" ? 1 : 0).joined(separator: " ")
                    guard !rawText.isEmpty else { throw CLIError(message: "prompt-agent requires text") }

                    var params: [String: Any] = ["text": rawText]
                    if force { params["force"] = true }
                    if answerPrompt { params["answer_prompt"] = true }
                    let wsId = try self.normalizeWorkspaceHandle(workspaceArg, client: ctx.client)
                    if let wsId { params["workspace_id"] = wsId }
                    let sfId = try self.resolveCommandSurface(
                        explicitSurface: sfArg, explicitWorkspace: wsArg,
                        windowId: ctx.windowId, workspaceHandle: wsId, client: ctx.client
                    )
                    if let sfId { params["surface_id"] = sfId }

                    var timeoutSeconds = 120.0
                    if let timeoutArg {
                        guard let parsed = Double(timeoutArg), parsed.isFinite, parsed > 0 else {
                            throw CLIError(message: "prompt-agent: --timeout must be a positive number of seconds")
                        }
                        timeoutSeconds = parsed
                        params["timeout_ms"] = Int((parsed * 1000).rounded())
                    }
                    if let graceArg {
                        guard let parsedGrace = Double(graceArg), parsedGrace.isFinite, parsedGrace > 0 else {
                            throw CLIError(message: "prompt-agent: --working-grace must be a positive number of seconds")
                        }
                        params["working_grace_ms"] = Int((parsedGrace * 1000).rounded())
                    }

                    // Mirrors wait-surface: the server may legitimately hold this connection
                    // open for close to the full --timeout.
                    let payload = try self.sendDraftGuardedV2(
                        ctx.client,
                        method: V2MethodNames.agentPrompt,
                        params: params,
                        minimumReceiveTimeout: timeoutSeconds + 5.0
                    )
                    if ctx.jsonOutput {
                        print(self.jsonString(payload))
                    } else if let warning = payload["warning"] as? String {
                        print(warning)
                    } else {
                        print((payload["final_state"] as? String) ?? "ok")
                    }
                }
            ),

            CommandDescriptor(
                names: ["watch-events"],
                helpLines: ["watch-events [--agent-state] [--workspace-lifecycle] [--needs-input] [--output <surface_id[,surface_id...]>] [--no-reconnect]"],
                argumentContract: .watchEvents,
                detailedUsage: """
                Usage: programa watch-events [flags]

                Subscribe to a long-lived stream of pushed events (#167) -- for consumers
                that need many events over time (dashboards, orchestrators, a menu bar on
                another machine). Casual "wait for one thing" callers should use
                `wait-surface`/`prompt-agent` instead; this command holds the connection
                open indefinitely and prints one JSON event per line until interrupted
                (Ctrl-C) or the process gives up reconnecting.

                Flags (at least one of --agent-state/--workspace-lifecycle/--needs-input/--output required):
                  --agent-state                    Agent working/blocked/idle transitions
                  --workspace-lifecycle             Workspace created/closed/renamed
                  --needs-input                     Agent prompts waiting for the user, with the
                                                    prompt text (needs_input events)
                  --output <surface_id[,surface_id...]>
                                                    Coalesced output for specific surfaces
                                                    (not available for "all surfaces" -- see docs)
                  --no-reconnect                    Exit on disconnect instead of the default
                                                    auto-reconnect (for scripts that want to
                                                    observe and handle drops themselves)

                By default, if the connection drops (app restart, network hiccup, or the
                1-hour idle read timeout) the command prints a notice to stderr and
                automatically reconnects and resubscribes with capped exponential backoff,
                rather than exiting. Pass --no-reconnect to restore the old exit-on-drop
                behavior. Stdout only ever contains event lines (or JSON, in --json mode);
                reconnect notices always go to stderr.

                If the per-connection event queue overflows (a slow/disconnected reader),
                a synthetic {"event":"dropped","count":N} line is printed -- re-sync with
                `list-workspaces`/`surface list` after seeing one.

                Example:
                  programa watch-events --agent-state
                  programa watch-events --output surface:2,surface:3
                  programa watch-events --agent-state --no-reconnect
                  programa watch-events --needs-input
                """,
                execute: { ctx in
                    let agentState = self.hasFlag(ctx.commandArgs, name: "--agent-state")
                    let workspaceLifecycle = self.hasFlag(ctx.commandArgs, name: "--workspace-lifecycle")
                    let needsInput = self.hasFlag(ctx.commandArgs, name: "--needs-input")
                    let noReconnect = self.hasFlag(ctx.commandArgs, name: "--no-reconnect")
                    let (outputArg, _) = self.parseOption(ctx.commandArgs, name: "--output")

                    var classes: [String] = []
                    if agentState { classes.append("agent_state") }
                    if workspaceLifecycle { classes.append("workspace_lifecycle") }
                    if needsInput { classes.append("needs_input") }

                    var params: [String: Any] = [:]
                    if let outputArg {
                        classes.append("output")
                        let rawIds = outputArg.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
                        var resolvedIds: [String] = []
                        for rawId in rawIds where !rawId.isEmpty {
                            guard let resolved = try self.normalizeSurfaceHandle(rawId, client: ctx.client) else {
                                throw CLIError(message: "watch-events: could not resolve surface id: \(rawId)")
                            }
                            resolvedIds.append(resolved)
                        }
                        guard !resolvedIds.isEmpty else {
                            throw CLIError(message: "watch-events: --output requires at least one surface id")
                        }
                        params["surface_ids"] = resolvedIds
                    }
                    params["classes"] = classes

                    // Sends the subscribe request and reads its ack. Shared by the initial
                    // subscribe and every reconnect below, so a resubscribe after a dropped
                    // connection goes through the exact same path as first connect: the ack is
                    // parsed and checked for `ok: true` before we consider the (re)subscribe
                    // successful, and the raw ack line is never written to stdout -- stdout is
                    // events-only, both to preserve that contract on first connect and to avoid
                    // a stray non-event JSON object landing mid-stream on a later resubscribe.
                    func subscribeAndAck() throws {
                        try ctx.client.sendV2RequestOnly(method: V2MethodNames.subscribe, params: params)
                        let ackLine = try ctx.client.readEventLine(timeout: 10)
                        if ackLine.hasPrefix("ERROR:") {
                            throw CLIError(message: ackLine)
                        }
                        guard let ackData = ackLine.data(using: .utf8),
                              let ack = try? JSONSerialization.jsonObject(with: ackData) as? [String: Any] else {
                            throw CLIError(message: "Invalid subscribe ack: \(ackLine)")
                        }
                        guard (ack["ok"] as? Bool) == true else {
                            if let error = ack["error"] as? [String: Any] {
                                let code = (error["code"] as? String) ?? "error"
                                let message = (error["message"] as? String) ?? "Subscribe rejected"
                                throw CLIError(message: "\(code): \(message)")
                            }
                            throw CLIError(message: "Subscribe rejected: \(ackLine)")
                        }
                        FileHandle.standardError.write("Subscribed: \(classes.joined(separator: ", "))\n".data(using: .utf8)!)
                    }

                    // Reconnect failures that won't resolve themselves on retry: wrong
                    // password / unconfigured password (auth.login's auth_failed/
                    // auth_required/auth_unconfigured), the programa-ancestry "unsafe socket"
                    // rejection (raw "ERROR: Access denied ..." preamble), and an explicit
                    // subscribe-ack rejection (invalid_params -- retrying with the same
                    // params will never succeed). Everything else (ECONNREFUSED/ENOENT while
                    // the app restarts, EOF, read timeouts) is transient and keeps retrying
                    // indefinitely as designed.
                    func isPermanentReconnectFailure(_ error: Error) -> Bool {
                        let description = String(describing: error)
                        if description.hasPrefix("ERROR: Access denied") { return true }
                        let permanentCodes = ["auth_failed:", "auth_required:", "auth_unconfigured:", "invalid_params:"]
                        return permanentCodes.contains { description.hasPrefix($0) }
                    }

                    func printEvent(_ line: String) {
                        if ctx.jsonOutput {
                            print(line)
                            return
                        }
                        guard let data = line.data(using: .utf8),
                              let frame = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                            print(line)
                            return
                        }
                        let event = (frame["event"] as? String) ?? "event"
                        let rest = frame.filter { $0.key != "event" }
                            .sorted { $0.key < $1.key }
                            .map { "\($0.key)=\($0.value)" }
                            .joined(separator: " ")
                        print("[\(event)] \(rest)")
                    }

                    var connectedAt = Date()
                    try subscribeAndAck()

                    // Long-lived: reads and prints one pushed event frame per line until the
                    // connection closes or the process is interrupted (Ctrl-C). Each frame is
                    // already a complete JSON object (see SocketEventBroadcaster.encodeFrame),
                    // so JSON mode just echoes the raw line.
                    //
                    // Any disconnect (EOF, a transport error, or the 3600s idle read timeout
                    // firing after an hour of silence) lands here. By default we don't let any
                    // of those kill the process: print one stderr notice, reconnect+resubscribe
                    // with capped exponential backoff, and keep streaming. --no-reconnect
                    // exits on the first drop instead, for scripts that handle drops themselves.
                    while true {
                        do {
                            let line = try ctx.client.readEventLine(timeout: 3600)
                            guard !line.isEmpty else { continue }
                            printEvent(line)
                        } catch {
                            if noReconnect { throw error }

                            let elapsedSeconds = Int(Date().timeIntervalSince(connectedAt))
                            let reason = String(describing: error)
                            FileHandle.standardError.write(
                                "programa: event stream disconnected (\(reason)) after \(elapsedSeconds)s; reconnecting…\n".data(using: .utf8)!
                            )

                            ctx.client.close()
                            var backoffSeconds = 0.5
                            var consecutivePermanentFailures = 0
                            while true {
                                do {
                                    try ctx.client.connectWithTransientRetry()
                                    try self.authenticateClientIfNeeded(
                                        ctx.client,
                                        explicitPassword: ctx.socketPasswordArg,
                                        socketPath: ctx.client.socketPath
                                    )
                                    connectedAt = Date()
                                    try subscribeAndAck()
                                    break
                                } catch {
                                    ctx.client.close()
                                    let permanent = isPermanentReconnectFailure(error)
                                    consecutivePermanentFailures = permanent ? consecutivePermanentFailures + 1 : 0
                                    FileHandle.standardError.write(
                                        "programa: reconnect attempt failed (\(error))\(permanent ? " [not retryable]" : "")\n".data(using: .utf8)!
                                    )
                                    if permanent && consecutivePermanentFailures >= 3 {
                                        throw error
                                    }
                                    Thread.sleep(forTimeInterval: backoffSeconds + Double.random(in: 0...0.1))
                                    backoffSeconds = min(backoffSeconds * 2, 5.0)
                                }
                            }
                            FileHandle.standardError.write("programa: event stream reconnected\n".data(using: .utf8)!)
                        }
                    }
                }
            ),

            CommandDescriptor(
                names: ["send"],
                helpLines: ["send [--workspace <id|ref>] [--surface <id|ref>] [--force] [--answer-prompt] <text>"],
                detailedUsage: """
                Usage: programa send [flags] [--] <text>

                Send text to a terminal surface. Escape sequences: \\n and \\r send Enter, \\t sends Tab.

                Flags:
                  --workspace <id|ref>   Target workspace (default: $PROGRAMA_WORKSPACE_ID)
                  --surface <id|ref>     Target surface (default: $PROGRAMA_SURFACE_ID)
                  --force                Send even if a person has unsent typed input in the
                                         surface (by default that returns draft_in_progress)
                  --answer-prompt        Send even if the agent there waits on a permission or
                                         sign-in prompt (agent_awaiting_approval). Pass it only
                                         when the person asked you to answer for them

                Example:
                  programa send "echo hello"
                  programa send --surface surface:2 "ls -la\\n"
                """,
                grammar: CLIArgumentGrammar(valueOptions: ["workspace", "surface"], booleanOptions: ["force", "answer-prompt"], minPositionals: 1, maxPositionals: nil),
                execute: { ctx in
                    let (wsArg, rem0) = self.parseOption(ctx.commandArgs, name: "--workspace")
                    let (sfArg, rem1) = self.parseOption(rem0, name: "--surface")
                    let (force, rem2) = self.takeFlag("--force", rem1)
                    let (answerPrompt, rem3) = self.takeFlag("--answer-prompt", rem2)
                    let workspaceArg = wsArg ?? (ctx.windowId == nil ? ProcessInfo.processInfo.environment["PROGRAMA_WORKSPACE_ID"] : nil)
                    let rawText = rem3.dropFirst(rem3.first == "--" ? 1 : 0).joined(separator: " ")
                    guard !rawText.isEmpty else { throw CLIError(message: "send requires text") }
                    let text = self.unescapeSendText(rawText)
                    var params: [String: Any] = ["text": text]
                    if force { params["force"] = true }
                    if answerPrompt { params["answer_prompt"] = true }
                    let wsId = try self.normalizeWorkspaceHandle(workspaceArg, client: ctx.client)
                    if let wsId { params["workspace_id"] = wsId }
                    let sfId = try self.resolveCommandSurface(
                        explicitSurface: sfArg, explicitWorkspace: wsArg,
                        windowId: ctx.windowId, workspaceHandle: wsId, client: ctx.client
                    )
                    if let sfId { params["surface_id"] = sfId }
                    let payload = try self.sendDraftGuardedV2(ctx.client, method: V2MethodNames.surfaceSendText, params: params)
                    self.printV2Payload(payload, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat, fallbackText: self.v2OKSummary(payload, idFormat: ctx.idFormat))
                }
            ),

            CommandDescriptor(
                names: ["send-key"],
                helpLines: ["send-key [--workspace <id|ref>] [--surface <id|ref>] [--force] [--answer-prompt] <key>"],
                detailedUsage: """
                Usage: programa send-key [flags] [--] <key>

                Send a key event to a terminal surface.

                Flags:
                  --workspace <id|ref>   Target workspace (default: $PROGRAMA_WORKSPACE_ID)
                  --surface <id|ref>     Target surface (default: $PROGRAMA_SURFACE_ID)
                  --force                Send even if a person has unsent typed input in the
                                         surface (by default that returns draft_in_progress)
                  --answer-prompt        Send even if the agent there waits on a permission or
                                         sign-in prompt (agent_awaiting_approval). Pass it only
                                         when the person asked you to answer for them

                Example:
                  programa send-key enter
                  programa send-key --surface surface:2 ctrl+c
                """,
                grammar: CLIArgumentGrammar(valueOptions: ["workspace", "surface"], booleanOptions: ["force", "answer-prompt"], minPositionals: 1, maxPositionals: 1),
                execute: { ctx in
                    let (wsArg, rem0) = self.parseOption(ctx.commandArgs, name: "--workspace")
                    let (sfArg, rem1) = self.parseOption(rem0, name: "--surface")
                    let (force, rem2) = self.takeFlag("--force", rem1)
                    let (answerPrompt, rem3) = self.takeFlag("--answer-prompt", rem2)
                    let workspaceArg = wsArg ?? (ctx.windowId == nil ? ProcessInfo.processInfo.environment["PROGRAMA_WORKSPACE_ID"] : nil)
                    let keyArgs = rem3.first == "--" ? Array(rem3.dropFirst()) : rem3
                    guard let key = keyArgs.first else { throw CLIError(message: "send-key requires a key") }
                    var params: [String: Any] = ["key": key]
                    if force { params["force"] = true }
                    if answerPrompt { params["answer_prompt"] = true }
                    let wsId = try self.normalizeWorkspaceHandle(workspaceArg, client: ctx.client)
                    if let wsId { params["workspace_id"] = wsId }
                    let sfId = try self.resolveCommandSurface(
                        explicitSurface: sfArg, explicitWorkspace: wsArg,
                        windowId: ctx.windowId, workspaceHandle: wsId, client: ctx.client
                    )
                    if let sfId { params["surface_id"] = sfId }
                    let payload = try self.sendDraftGuardedV2(ctx.client, method: V2MethodNames.surfaceSendKey, params: params)
                    self.printV2Payload(payload, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat, fallbackText: self.v2OKSummary(payload, idFormat: ctx.idFormat))
                }
            ),

            CommandDescriptor(
                names: ["send-panel"],
                helpLines: ["send-panel --panel <id|ref> [--workspace <id|ref>] [--force] [--answer-prompt] <text>"],
                detailedUsage: """
                Usage: programa send-panel --panel <id|ref> [flags] [--] <text>

                Send text to a specific panel (surface). Escape sequences: \\n and \\r send Enter, \\t sends Tab.

                Flags:
                  --panel <id|ref>       Target panel (required)
                  --workspace <id|ref>   Target workspace (default: $PROGRAMA_WORKSPACE_ID)
                  --force                Send even if a person has unsent typed input in the
                                         surface (by default that returns draft_in_progress)
                  --answer-prompt        Send even if the agent there waits on a permission or
                                         sign-in prompt (agent_awaiting_approval). Pass it only
                                         when the person asked you to answer for them

                Example:
                  programa send-panel --panel surface:2 "echo hello\\n"
                """,
                grammar: CLIArgumentGrammar(valueOptions: ["panel", "workspace"], booleanOptions: ["force", "answer-prompt"], requiredOptions: ["panel"], minPositionals: 1, maxPositionals: nil),
                execute: { ctx in
                    let (wsArg, rem0) = self.parseOption(ctx.commandArgs, name: "--workspace")
                    let (panelArg, rem1) = self.parseOption(rem0, name: "--panel")
                    let workspaceArg = wsArg ?? (ctx.windowId == nil ? ProcessInfo.processInfo.environment["PROGRAMA_WORKSPACE_ID"] : nil)
                    guard let panelArg else {
                        throw CLIError(message: "send-panel requires --panel")
                    }
                    let (force, rem2) = self.takeFlag("--force", rem1)
                    let (answerPrompt, rem3) = self.takeFlag("--answer-prompt", rem2)
                    let rawText = rem3.dropFirst(rem3.first == "--" ? 1 : 0).joined(separator: " ")
                    guard !rawText.isEmpty else { throw CLIError(message: "send-panel requires text") }
                    let text = self.unescapeSendText(rawText)
                    var params: [String: Any] = ["text": text]
                    if force { params["force"] = true }
                    if answerPrompt { params["answer_prompt"] = true }
                    let wsId = try self.normalizeWorkspaceHandle(workspaceArg, client: ctx.client)
                    if let wsId { params["workspace_id"] = wsId }
                    let sfId = try self.normalizeSurfaceHandle(panelArg, client: ctx.client, workspaceHandle: wsId)
                    if let sfId { params["surface_id"] = sfId }
                    let payload = try self.sendDraftGuardedV2(ctx.client, method: V2MethodNames.surfaceSendText, params: params)
                    self.printV2Payload(payload, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat, fallbackText: self.v2OKSummary(payload, idFormat: ctx.idFormat))
                }
            ),

            CommandDescriptor(
                names: ["send-key-panel"],
                helpLines: ["send-key-panel --panel <id|ref> [--workspace <id|ref>] [--force] [--answer-prompt] <key>"],
                detailedUsage: """
                Usage: programa send-key-panel --panel <id|ref> [flags] [--] <key>

                Send a key event to a specific panel (surface).

                Flags:
                  --panel <id|ref>       Target panel (required)
                  --workspace <id|ref>   Target workspace (default: $PROGRAMA_WORKSPACE_ID)
                  --force                Send even if a person has unsent typed input in the
                                         surface (by default that returns draft_in_progress)
                  --answer-prompt        Send even if the agent there waits on a permission or
                                         sign-in prompt (agent_awaiting_approval). Pass it only
                                         when the person asked you to answer for them

                Example:
                  programa send-key-panel --panel surface:2 enter
                  programa send-key-panel --panel surface:2 ctrl+c
                """,
                grammar: CLIArgumentGrammar(valueOptions: ["panel", "workspace"], booleanOptions: ["force", "answer-prompt"], requiredOptions: ["panel"], minPositionals: 1, maxPositionals: 1),
                execute: { ctx in
                    let (wsArg, rem0) = self.parseOption(ctx.commandArgs, name: "--workspace")
                    let (panelArg, rem1) = self.parseOption(rem0, name: "--panel")
                    let workspaceArg = wsArg ?? (ctx.windowId == nil ? ProcessInfo.processInfo.environment["PROGRAMA_WORKSPACE_ID"] : nil)
                    guard let panelArg else {
                        throw CLIError(message: "send-key-panel requires --panel")
                    }
                    let (force, rem2) = self.takeFlag("--force", rem1)
                    let (answerPrompt, rem3) = self.takeFlag("--answer-prompt", rem2)
                    let skpArgs = rem3.first == "--" ? Array(rem3.dropFirst()) : rem3
                    let key = skpArgs.first ?? ""
                    guard !key.isEmpty else { throw CLIError(message: "send-key-panel requires a key") }
                    var params: [String: Any] = ["key": key]
                    if force { params["force"] = true }
                    if answerPrompt { params["answer_prompt"] = true }
                    let wsId = try self.normalizeWorkspaceHandle(workspaceArg, client: ctx.client)
                    if let wsId { params["workspace_id"] = wsId }
                    let sfId = try self.normalizeSurfaceHandle(panelArg, client: ctx.client, workspaceHandle: wsId)
                    if let sfId { params["surface_id"] = sfId }
                    let payload = try self.sendDraftGuardedV2(ctx.client, method: V2MethodNames.surfaceSendKey, params: params)
                    self.printV2Payload(payload, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat, fallbackText: self.v2OKSummary(payload, idFormat: ctx.idFormat))
                }
            ),
        ]
    }

    /// Splits a boolean flag such as `--force` out of a command's arguments. Only tokens ahead
    /// of a `--` separator count, so `send -- --force` still sends the literal text.
    func takeFlag(_ flag: String, _ args: [String]) -> (isSet: Bool, rest: [String]) {
        let separator = args.firstIndex(of: "--") ?? args.endIndex
        guard args[..<separator].contains(flag) else { return (false, args) }
        return (true, args[..<separator].filter { $0 != flag } + args[separator...])
    }

    /// `sendV2` for a write the server refuses while a person has unsent typed input in the
    /// target (`draft_in_progress`) or while its agent waits on an approval prompt
    /// (`agent_awaiting_approval`), with the refusal turned into one line for the person.
    /// `approvalHint` and `draftHint` replace the `--answer-prompt` and `--force` advice for a
    /// command without those flags.
    func sendDraftGuardedV2(
        _ client: SocketClient,
        method: String,
        params: [String: Any],
        minimumReceiveTimeout: TimeInterval? = nil,
        approvalHint: String = "Answer it in the pane, or pass --answer-prompt only if the person asked you to.",
        draftHint: String? = nil
    ) throws -> [String: Any] {
        let draftPrefix = "draft_in_progress: "
        let approvalPrefix = "agent_awaiting_approval: "
        do {
            return try client.sendV2(method: method, params: params, minimumReceiveTimeout: minimumReceiveTimeout)
        } catch let error as CLIError where error.message.hasPrefix(draftPrefix) {
            // agent.prompt already waited out its --timeout, so "retry later" is the wrong advice.
            let hint = draftHint ?? (method == V2MethodNames.agentPrompt
                ? "Pass a longer --timeout, or --force to send now."
                : "Retry after it is submitted or cleared, or pass --force.")
            throw CLIError(message: "\(error.message.dropFirst(draftPrefix.count)). \(hint)")
        } catch let error as CLIError where error.message.hasPrefix(approvalPrefix) {
            throw CLIError(message: "\(error.message.dropFirst(approvalPrefix.count)). \(approvalHint)")
        }
    }
}
