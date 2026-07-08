import Foundation
import CryptoKit
import Darwin
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
#if canImport(Security)
import Security
#endif

extension CMUXCLI {
    // MARK: - Markdown Commands

    func runMarkdownCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        var args = commandArgs

        // Parse routing flags
        let (workspaceOpt, argsAfterWorkspace) = parseOption(args, name: "--workspace")
        let (windowOpt, argsAfterWindow) = parseOption(argsAfterWorkspace, name: "--window")
        let (surfaceOpt, argsAfterSurface) = parseOption(argsAfterWindow, name: "--surface")
        let (directionOpt, argsAfterDirection) = parseOption(argsAfterSurface, name: "--direction")
        args = argsAfterDirection

        // Determine subcommand. Explicit "open" is supported, otherwise treat
        // a single positional argument as shorthand path.
        let subArgs: [String]
        if let first = args.first, first.lowercased() == "open" {
            subArgs = Array(args.dropFirst())
        } else if args.count == 1, let first = args.first, !first.hasPrefix("-") {
            subArgs = [first]
        } else {
            // Allow path-like first tokens (e.g. plan.md) with trailing args
            // so we can surface specific trailing-arg/flag errors below.
            if let first = args.first, first.hasPrefix("-") {
                throw CLIError(
                    message:
                        "markdown open: unknown flag '\(first)'. Usage: programa markdown open <path> [--workspace <id|ref|index>] [--surface <id|ref|index>] [--window <id|ref|index>] [--direction right|down|left|up]"
                )
            } else if let first = args.first, looksLikePath(first) || first.contains(".") {
                subArgs = args
            } else if let first = args.first {
                throw CLIError(message: "Unknown markdown subcommand: \(first). Usage: programa markdown open <path>")
            } else {
                subArgs = []
            }
        }

        guard let rawPath = subArgs.first, !rawPath.isEmpty else {
            throw CLIError(message: "markdown open requires a file path. Usage: programa markdown open <path>")
        }
        let trailingArgs = Array(subArgs.dropFirst())
        if let unknownFlag = trailingArgs.first(where: { $0.hasPrefix("-") }) {
            throw CLIError(
                message:
                    "markdown open: unknown flag '\(unknownFlag)'. Usage: programa markdown open <path> [--workspace <id|ref|index>] [--surface <id|ref|index>] [--window <id|ref|index>] [--direction right|down|left|up]"
            )
        }
        if let extraArg = trailingArgs.first {
            throw CLIError(
                message:
                    "markdown open: unexpected argument '\(extraArg)'. Usage: programa markdown open <path> [--workspace <id|ref|index>] [--surface <id|ref|index>] [--window <id|ref|index>] [--direction right|down|left|up]"
            )
        }

        let absolutePath = resolvePath(rawPath)

        // Build params
        let direction = directionOpt ?? "right"
        var params: [String: Any] = ["path": absolutePath, "direction": direction]
        if let surfaceRaw = surfaceOpt {
            if let surface = try normalizeSurfaceHandle(surfaceRaw, client: client) {
                params["surface_id"] = surface
            }
        }
        let workspaceRaw = workspaceOpt ?? (windowOpt == nil ? ProcessInfo.processInfo.environment["PROGRAMA_WORKSPACE_ID"] : nil)
        if let workspaceRaw {
            if let workspace = try normalizeWorkspaceHandle(workspaceRaw, client: client) {
                params["workspace_id"] = workspace
            }
        }
        if let windowRaw = windowOpt {
            if let window = try normalizeWindowHandle(windowRaw, client: client) {
                params["window_id"] = window
            }
        }

        let payload = try client.sendV2(method: "markdown.open", params: params)

        if jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
        } else {
            let surfaceText = formatHandle(payload, kind: "surface", idFormat: idFormat) ?? "unknown"
            let paneText = formatHandle(payload, kind: "pane", idFormat: idFormat) ?? "unknown"
            let filePath = (payload["path"] as? String) ?? absolutePath
            print("OK surface=\(surfaceText) pane=\(paneText) path=\(filePath)")
        }
    }
}
