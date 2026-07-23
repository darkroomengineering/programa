import Foundation

extension ProgramaCLI {
    // MARK: - Recap Commands
    //
    // Recaps are markdown files an agent writes to summarize a change, saved at
    // `<repo-root>/.programa/recaps/<slug>.md` (repo root resolved via `git
    // rev-parse --show-toplevel` from the caller's cwd). `recap open` reuses the
    // existing `markdown.open` socket call, no new socket method.

    func runRecapCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        var args = commandArgs

        let (workspaceOpt, argsAfterWorkspace) = parseOption(args, name: "--workspace")
        let (windowOpt, argsAfterWindow) = parseOption(argsAfterWorkspace, name: "--window")
        args = argsAfterWindow

        guard let subcommand = args.first?.lowercased() else {
            throw CLIError(message: recapSubcommandUsage("recap") ?? "Usage: programa recap open <slug>|list")
        }
        let rest = Array(args.dropFirst())

        switch subcommand {
        case "open":
            guard let slug = rest.first, !slug.isEmpty else {
                throw CLIError(message: "recap open requires <slug>. Usage: programa recap open <slug> [--workspace <id|ref|index>] [--window <id|ref|index>]")
            }
            if rest.count > 1 {
                throw CLIError(message: "recap open: unexpected argument '\(rest[1])'. Usage: programa recap open <slug>")
            }

            let recapsDir = try recapsDirectory()
            let recapPath = recapsDir.appendingPathComponent("\(slug).md")
            guard FileManager.default.fileExists(atPath: recapPath.path) else {
                throw CLIError(message: "recap open: no recap found for '\(slug)' (looked at \(recapPath.path)). Run 'programa recap list' to see available recaps.")
            }

            var params: [String: Any] = ["path": recapPath.path, "direction": "right"]
            let workspaceRaw = workspaceOpt ?? (windowOpt == nil ? ProcessInfo.processInfo.environment["PROGRAMA_WORKSPACE_ID"] : nil)
            if let workspaceRaw, let workspace = try normalizeWorkspaceHandle(workspaceRaw, client: client) {
                params["workspace_id"] = workspace
            }
            if let windowRaw = windowOpt, let window = try normalizeWindowHandle(windowRaw, client: client) {
                params["window_id"] = window
            }

            let payload = try client.sendV2(method: "markdown.open", params: params)
            if jsonOutput {
                print(jsonString(formatIDs(payload, mode: idFormat)))
            } else {
                let surfaceText = formatHandle(payload, kind: "surface", idFormat: idFormat) ?? "unknown"
                let paneText = formatHandle(payload, kind: "pane", idFormat: idFormat) ?? "unknown"
                print("OK surface=\(surfaceText) pane=\(paneText) path=\(recapPath.path)")
            }

        case "list":
            guard rest.isEmpty else {
                throw CLIError(message: "recap list: unexpected argument '\(rest[0])'. Usage: programa recap list")
            }
            let recapsDir = try recapsDirectory()
            let slugs = recapSlugs(in: recapsDir)
            if jsonOutput {
                print(jsonString(["recaps": slugs]))
            } else if slugs.isEmpty {
                print("No recaps found in \(recapsDir.path)")
            } else {
                for slug in slugs {
                    print(slug)
                }
            }

        default:
            throw CLIError(message: "Unknown recap subcommand: \(subcommand). Usage: programa recap open <slug>|list")
        }
    }

    /// Resolves `<repo-root>/.programa/recaps`, where repo root is `git rev-parse
    /// --show-toplevel` from the CLI process's own current directory (the
    /// caller's cwd, not any workspace's cwd -- this is a shell-invoked CLI).
    private func recapsDirectory() throws -> URL {
        let cwd = FileManager.default.currentDirectoryPath
        guard let root = recapGitTopLevelDirectory(at: cwd) else {
            throw CLIError(message: "recap: '\(cwd)' is not inside a git repository")
        }
        return URL(fileURLWithPath: root).appendingPathComponent(".programa/recaps")
    }

    private func recapGitTopLevelDirectory(at directory: String) -> String? {
        let process = Process()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", directory, "rev-parse", "--show-toplevel"]
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func recapSlugs(in directory: URL) -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        return entries
            .filter { $0.pathExtension == "md" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    /// Subcommand help text for Recap commands, split out of the central `subcommandUsage`
    /// switch (programa.swift), mirroring `markdownSubcommandUsage`.
    func recapSubcommandUsage(_ command: String) -> String? {
        switch command {
        case "recap":
            return """
            Usage: programa recap open <slug> [options]
                   programa recap list

            Open or list saved recaps: markdown summaries an agent writes to
            <repo-root>/.programa/recaps/<slug>.md and reopens later via 'recap open'.
            Repo root is resolved from the caller's working directory with
            'git rev-parse --show-toplevel'. 'recap open' reuses the markdown viewer
            panel (formatting, live reload).

            Options (recap open):
              --workspace <id|ref|index>   Target workspace (default: $PROGRAMA_WORKSPACE_ID)
              --window <id|ref|index>      Target window

            Examples:
              programa recap open demo
              programa recap list
            """
        default:
            return nil
        }
    }
}
