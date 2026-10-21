import Foundation

extension ProgramaCLI {
    /// `handoff`, registered from `commandDescriptors()` (programa.swift).
    func handoffDescriptors() -> [CommandDescriptor] {
        [
            CommandDescriptor(
                names: ["handoff"],
                helpLines: ["handoff --from <id|ref> [--lines <n>] [--note <text>] [--to <id|ref>]"],
                detailedUsage: """
                Usage: programa handoff --from <id|ref> [flags]

                Paste another pane's recent output into a pane's prompt as context. The text
                arrives as one paste and Return is never pressed, so you can keep typing before
                you submit.

                Flags:
                  --from <id|ref>   Pane to copy output from (required)
                  --lines <n>       How many of its last lines to include (default: \(PaneHandoffFormatter.defaultLineCount), max: \(PaneHandoffFormatter.maxLineCount))
                  --note <text>     Add a "Note:" line after the context
                  --to <id|ref>     Pane to paste into (default: $PROGRAMA_SURFACE_ID)

                Example:
                  programa handoff --from surface:3
                  programa handoff --from surface:3 --lines 50 --note "Why does this test fail?"
                """,
                grammar: CLIArgumentGrammar(valueOptions: ["from", "lines", "note", "to"], requiredOptions: ["from"]),
                execute: { ctx in
                    try self.runHandoff(ctx: ctx)
                }
            ),
        ]
    }

    private func runHandoff(ctx: CommandContext) throws {
        let (fromArg, rem0) = parseOption(ctx.commandArgs, name: "--from")
        let (linesArg, rem1) = parseOption(rem0, name: "--lines")
        let (noteArg, rem2) = parseOption(rem1, name: "--note")
        let (toArg, _) = parseOption(rem2, name: "--to")

        var lineCount = PaneHandoffFormatter.defaultLineCount
        if let linesArg {
            guard let parsed = Int(linesArg), parsed > 0, parsed <= PaneHandoffFormatter.maxLineCount else {
                throw CLIError(message: "handoff: --lines must be between 1 and \(PaneHandoffFormatter.maxLineCount)")
            }
            lineCount = parsed
        }
        guard let source = try normalizeSurfaceHandle(fromArg, client: ctx.client) else {
            throw CLIError(message: "handoff: --from is required")
        }
        guard let target = try resolveCommandSurface(
            explicitSurface: toArg, explicitWorkspace: nil,
            windowId: ctx.windowId, workspaceHandle: nil, client: ctx.client
        ) else {
            throw CLIError(message: "handoff: no target pane; pass --to <id|ref> or run inside a Programa pane")
        }

        // A one-line read resolves the target to its UUID (handles may be refs or UUIDs) and
        // fails early when it is missing or not a terminal, before the source is read.
        let targetPayload = try ctx.client.sendV2(
            method: V2MethodNames.surfaceReadText, params: ["surface_id": target, "lines": 1]
        )
        let sourcePayload = try ctx.client.sendV2(
            method: V2MethodNames.surfaceReadText, params: ["surface_id": source, "lines": lineCount]
        )
        let targetId = targetPayload["surface_id"] as? String
        let sourceId = sourcePayload["surface_id"] as? String
        if let targetId, let sourceId, UUID(uuidString: targetId) == UUID(uuidString: sourceId) {
            throw CLIError(message: "handoff: --from and the target are the same pane; pick another pane with --from")
        }

        let sourceRef = (sourcePayload["surface_ref"] as? String) ?? source
        let label = handoffSourceTitle(sourcePayload: sourcePayload, client: ctx.client).map { "\($0) (\(sourceRef))" } ?? sourceRef
        let text = PaneHandoffFormatter.format(
            sourceLabel: label,
            text: (sourcePayload["text"] as? String) ?? "",
            note: noteArg
        )
        let payload = try ctx.client.sendV2(
            method: V2MethodNames.surfaceSendPaste, params: ["surface_id": targetId ?? target, "text": text]
        )
        if ctx.jsonOutput {
            print(jsonString(formatIDs(payload, mode: ctx.idFormat)))
        } else {
            print("OK")
        }
    }

    /// The source pane's title from `surface.list`, or nil when it is unavailable or empty.
    private func handoffSourceTitle(sourcePayload: [String: Any], client: SocketClient) -> String? {
        guard let workspaceId = sourcePayload["workspace_id"] as? String,
              let sourceId = sourcePayload["surface_id"] as? String,
              let listed = try? client.sendV2(method: V2MethodNames.surfaceList, params: ["workspace_id": workspaceId]),
              let surfaces = listed["surfaces"] as? [[String: Any]],
              let match = surfaces.first(where: { ($0["id"] as? String) == sourceId }),
              let title = (match["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { return nil }
        return title
    }
}
