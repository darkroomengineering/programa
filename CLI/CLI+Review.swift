import Foundation

extension ProgramaCLI {
    // MARK: - Review Commands (agent diff review panel)

    func runReviewCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        var args = commandArgs

        let (workspaceOpt, argsAfterWorkspace) = parseOption(args, name: "--workspace")
        let (windowOpt, argsAfterWindow) = parseOption(argsAfterWorkspace, name: "--window")
        let (surfaceOpt, argsAfterSurface) = parseOption(argsAfterWindow, name: "--surface")
        let (directionOpt, argsAfterDirection) = parseOption(argsAfterSurface, name: "--direction")
        let (modeOpt, argsAfterMode) = parseOption(argsAfterDirection, name: "--mode")
        let (baseBranchOpt, argsAfterBaseBranch) = parseOption(argsAfterMode, name: "--base-branch")
        let (preambleOpt, argsAfterPreamble) = parseOption(argsAfterBaseBranch, name: "--preamble")
        args = argsAfterPreamble

        guard let subcommand = args.first?.lowercased() else {
            throw CLIError(message: reviewSubcommandUsage("review") ?? "Usage: programa review open|refresh|comment|send")
        }
        let rest = Array(args.dropFirst())

        func workspaceRoutingParams() throws -> [String: Any] {
            var params: [String: Any] = [:]
            if let surfaceRaw = surfaceOpt, let surface = try normalizeSurfaceHandle(surfaceRaw, client: client) {
                params["surface_id"] = surface
            }
            let workspaceRaw = workspaceOpt ?? (windowOpt == nil ? ProcessInfo.processInfo.environment["PROGRAMA_WORKSPACE_ID"] : nil)
            if let workspaceRaw, let workspace = try normalizeWorkspaceHandle(workspaceRaw, client: client) {
                params["workspace_id"] = workspace
            }
            if let windowRaw = windowOpt, let window = try normalizeWindowHandle(windowRaw, client: client) {
                params["window_id"] = window
            }
            return params
        }

        switch subcommand {
        case "open":
            guard rest.isEmpty else {
                throw CLIError(
                    message:
                        "review open: unexpected argument '\(rest[0])'. Usage: programa review open [--surface <id|ref|index>] [--workspace <id|ref|index>] [--window <id|ref|index>] [--direction left|right|up|down] [--mode uncommitted|branch] [--base-branch <ref>]"
                )
            }
            var params = try workspaceRoutingParams()
            params["direction"] = directionOpt ?? "right"
            if let modeOpt {
                let normalizedMode = modeOpt.lowercased()
                guard ["uncommitted", "branch"].contains(normalizedMode) else {
                    throw CLIError(message: "review open: invalid --mode '\(modeOpt)' (uncommitted|branch)")
                }
                params["mode"] = normalizedMode
            }
            if let baseBranchOpt {
                params["base_branch"] = baseBranchOpt
            }

            let payload = try client.sendV2(method: "review.open", params: params)
            if jsonOutput {
                print(jsonString(formatIDs(payload, mode: idFormat)))
            } else {
                let surfaceText = formatHandle(payload, kind: "surface", idFormat: idFormat) ?? "unknown"
                let paneText = formatHandle(payload, kind: "pane", idFormat: idFormat) ?? "unknown"
                let diffableCount = intFromAny(payload["diffable_file_count"]) ?? 0
                print("OK surface=\(surfaceText) pane=\(paneText) diffable_files=\(diffableCount)")
            }

        case "refresh":
            guard rest.isEmpty else {
                throw CLIError(message: "review refresh: unexpected argument '\(rest[0])'. Usage: programa review refresh [--surface <id|ref|index>]")
            }
            let params = try workspaceRoutingParams()
            let payload = try client.sendV2(method: "review.refresh", params: params)
            if jsonOutput {
                print(jsonString(formatIDs(payload, mode: idFormat)))
            } else {
                let fileCount = intFromAny(payload["file_count"]) ?? 0
                let diffableCount = intFromAny(payload["diffable_file_count"]) ?? 0
                print("OK files=\(fileCount) diffable=\(diffableCount)")
            }

        case "comment":
            try runReviewCommentCommand(
                rest: rest,
                workspaceRoutingParams: workspaceRoutingParams,
                client: client,
                jsonOutput: jsonOutput,
                idFormat: idFormat
            )

        case "send":
            guard rest.isEmpty else {
                throw CLIError(message: "review send: unexpected argument '\(rest[0])'. Usage: programa review send [--surface <id|ref|index>] [--preamble <text>]")
            }
            var params = try workspaceRoutingParams()
            if let preambleOpt {
                params["preamble"] = preambleOpt
            }
            let payload = try client.sendV2(method: "review.send_comments", params: params)
            if jsonOutput {
                print(jsonString(formatIDs(payload, mode: idFormat)))
            } else {
                let sentCount = intFromAny(payload["sent_count"]) ?? 0
                print("OK sent_count=\(sentCount)")
            }

        default:
            throw CLIError(message: "Unknown review subcommand: \(subcommand). Usage: programa review open|refresh|comment|send")
        }
    }

    private func runReviewCommentCommand(
        rest: [String],
        workspaceRoutingParams: () throws -> [String: Any],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        guard let commentSubcommand = rest.first?.lowercased() else {
            throw CLIError(message: "Usage: programa review comment add|remove|list ...")
        }
        let commentRest = Array(rest.dropFirst())

        switch commentSubcommand {
        case "add":
            guard commentRest.count >= 3 else {
                throw CLIError(
                    message:
                        "review comment add requires <file> <line|start-end> <text>. Usage: programa review comment add <file> <line|start-end> <text> [--surface <id|ref|index>]"
                )
            }
            let filePath = commentRest[0]
            let (startLine, endLine) = try reviewParseLineRangeToken(commentRest[1])
            let text = commentRest.dropFirst(2).joined(separator: " ")

            var params = try workspaceRoutingParams()
            params["file_path"] = filePath
            params["start_line"] = startLine
            params["end_line"] = endLine
            params["text"] = text

            let payload = try client.sendV2(method: "review.comment.add", params: params)
            if jsonOutput {
                print(jsonString(formatIDs(payload, mode: idFormat)))
            } else {
                print("OK comment_id=\((payload["comment_id"] as? String) ?? "unknown")")
            }

        case "remove":
            guard let commentId = commentRest.first, !commentId.isEmpty else {
                throw CLIError(message: "review comment remove requires <comment-id>. Usage: programa review comment remove <comment-id> [--surface <id|ref|index>]")
            }
            var params = try workspaceRoutingParams()
            params["comment_id"] = commentId

            let payload = try client.sendV2(method: "review.comment.remove", params: params)
            if jsonOutput {
                print(jsonString(formatIDs(payload, mode: idFormat)))
            } else {
                print("OK")
            }

        case "list":
            guard commentRest.isEmpty else {
                throw CLIError(message: "review comment list: unexpected argument '\(commentRest[0])'. Usage: programa review comment list [--surface <id|ref|index>]")
            }
            let params = try workspaceRoutingParams()
            let payload = try client.sendV2(method: "review.comment.list", params: params)
            if jsonOutput {
                print(jsonString(formatIDs(payload, mode: idFormat)))
            } else {
                let comments = (payload["comments"] as? [[String: Any]]) ?? []
                if comments.isEmpty {
                    print("No pending comments.")
                } else {
                    for comment in comments {
                        let filePath = (comment["file_path"] as? String) ?? "?"
                        let startLine = intFromAny(comment["start_line"]) ?? 0
                        let endLine = intFromAny(comment["end_line"]) ?? startLine
                        let text = (comment["text"] as? String) ?? ""
                        let commentId = (comment["id"] as? String) ?? "?"
                        let lineToken = startLine == endLine ? "\(startLine)" : "\(startLine)-\(endLine)"
                        let staleSuffix = (comment["is_stale"] as? Bool) == true ? " [stale]" : ""
                        print("\(commentId)  \(filePath):\(lineToken) — \(text)\(staleSuffix)")
                    }
                }
            }

        default:
            throw CLIError(message: "Unknown review comment subcommand: \(commentSubcommand). Usage: programa review comment add|remove|list")
        }
    }

    private func reviewParseLineRangeToken(_ token: String) throws -> (Int, Int) {
        let parts = token.split(separator: "-", maxSplits: 1)
        guard let firstPart = parts.first, let start = Int(firstPart) else {
            throw CLIError(message: "review comment add: invalid line '\(token)' (expected <line> or <start>-<end>)")
        }
        if parts.count == 2, let end = Int(parts[1]) {
            return (start, end)
        }
        return (start, start)
    }

    /// Subcommand help text for Review commands, split out of the central `subcommandUsage`
    /// switch (programa.swift), mirroring `markdownSubcommandUsage`.
    func reviewSubcommandUsage(_ command: String) -> String? {
        switch command {
        case "review":
            return """
            Usage: programa review open [options]
                   programa review refresh [--surface <id|ref|index>]
                   programa review comment add <file> <line|start-end> <text> [--surface <id|ref|index>]
                   programa review comment remove <comment-id> [--surface <id|ref|index>]
                   programa review comment list [--surface <id|ref|index>]
                   programa review send [--surface <id|ref|index>] [--preamble <text>]

            Open a diff review panel beside a terminal surface showing its worktree diff
            (uncommitted changes, or the whole branch vs a merge-base), attach line comments,
            and send them back into the agent's input as `path:line — comment`.

            Options (review open):
              --workspace <id|ref|index>   Target workspace (default: $PROGRAMA_WORKSPACE_ID)
              --surface <id|ref|index>     Source surface to review + split from (default: focused surface)
              --window <id|ref|index>      Target window
              --direction <left|right|up|down>  Split direction (default: right)
              --mode <uncommitted|branch>  Diff mode (default: uncommitted)
              --base-branch <ref>          Base branch for --mode branch (default: origin/main)

            Examples:
              programa review open
              programa review open --mode branch --base-branch main
              programa review comment add src/foo.swift 12-14 "please add a guard here"
              programa review send
            """
        default:
            return nil
        }
    }
}
