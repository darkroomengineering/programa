import Foundation

/// Owns argv parsing, descriptor lookup, validation, help routing, and local/socket dispatch.
struct CLICommandDispatcher {
    let cli: ProgramaCLI
    private var args: [String] { cli.args }

    func run() throws {
    let processEnv = ProcessInfo.processInfo.environment
    let envSocketPath: String? = {
        for key in ["PROGRAMA_SOCKET_PATH", "PROGRAMA_SOCKET"] {
            guard let raw = processEnv[key] else { continue }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }()
    var socketPath = envSocketPath ?? CLISocketPathResolver.defaultSocketPath
    var socketPathSource: CLISocketPathSource
    if let envSocketPath {
        socketPathSource = CLISocketPathResolver.isImplicitDefaultPath(envSocketPath) ? .implicitDefault : .environment
    } else {
        socketPathSource = .implicitDefault
    }
    var jsonOutput = false
    var idFormatArg: String? = nil
    var windowId: String? = nil
    var socketPasswordArg: String? = nil

    var index = 1
    while index < args.count {
        let arg = args[index]
        if arg == "--socket" {
            guard index + 1 < args.count else {
                throw CLIError(message: "--socket requires a path")
            }
            socketPath = args[index + 1]
            socketPathSource = .explicitFlag
            index += 2
            continue
        }
        if arg == "--json" {
            jsonOutput = true
            index += 1
            continue
        }
        if arg == "--id-format" {
            guard index + 1 < args.count else {
                throw CLIError(message: "--id-format requires a value (refs|uuids|both)")
            }
            idFormatArg = args[index + 1]
            index += 2
            continue
        }
        if arg == "--window" {
            guard index + 1 < args.count else {
                throw CLIError(message: "--window requires a window id")
            }
            windowId = args[index + 1]
            index += 2
            continue
        }
        if arg == "--password" {
            guard index + 1 < args.count else {
                throw CLIError(message: "--password requires a value")
            }
            socketPasswordArg = args[index + 1]
            index += 2
            continue
        }
        if arg == "-v" || arg == "--version" {
            print(cli.versionSummary())
            return
        }
        if arg == "-h" || arg == "--help" {
            print(cli.usage())
            return
        }
        if arg.hasPrefix("-") {
            throw CLIError(message: "Unknown global option: \(arg)")
        }
        break
    }

    guard index < args.count else {
        print(cli.usage())
        throw CLIError(message: "Missing command")
    }

    let command = args[index]
    let commandArgs = Array(args[(index + 1)...])

    guard let descriptor = cli.commandDescriptor(named: command) else {
        // Filesystem opening is a fallback only after command lookup, so a
        // registered command can never be mistaken for a path.
        if cli.looksLikePath(command) {
            let resolvedSocketPath = CLISocketPathResolver.resolve(
                requestedPath: socketPath,
                source: socketPathSource,
                environment: processEnv
            )
            try cli.openPath(command, socketPath: resolvedSocketPath, explicitPassword: socketPasswordArg)
            return
        }
        throw CLIError(message: "Unknown command: \(command). Run 'programa help' to see available commands.")
    }

    if descriptor.helpPolicy == .programa,
       commandArgs.contains(where: { $0 == "--help" || $0 == "-h" }) {
        guard cli.dispatchSubcommandHelp(command: command, commandArgs: commandArgs) else {
            throw CLIError(message: "No help is available for command: \(command)")
        }
        return
    }

    try cli.validateArguments(commandArgs, for: command, contract: descriptor.argumentContract)
    let idFormat = try cli.resolvedIDFormat(jsonOutput: jsonOutput, raw: idFormatArg)

    var resolvedSocketPathCache: String?
    func resolveSocketPath() -> String {
        if let resolvedSocketPathCache { return resolvedSocketPathCache }
        let resolved = CLISocketPathResolver.resolve(
            requestedPath: socketPath,
            source: socketPathSource,
            environment: processEnv
        )
        resolvedSocketPathCache = resolved
        return resolved
    }

    switch command {
    case "version":
        print(cli.versionSummary())
        return
    case "help":
        print(cli.usage())
        return
    case "welcome":
        cli.printWelcome()
        return
    case "shortcuts":
        try cli.runShortcuts(
            commandArgs: commandArgs,
            socketPath: resolveSocketPath(),
            explicitPassword: socketPasswordArg,
            jsonOutput: jsonOutput
        )
        return
    case "feedback":
        try cli.runFeedback(
            commandArgs: commandArgs,
            socketPath: resolveSocketPath(),
            explicitPassword: socketPasswordArg,
            jsonOutput: jsonOutput
        )
        return
    case "themes":
        try cli.runThemes(commandArgs: commandArgs, jsonOutput: jsonOutput)
        return
    case "claude-teams":
        try cli.runClaudeTeams(
            commandArgs: commandArgs,
            socketPath: resolveSocketPath(),
            explicitPassword: socketPasswordArg
        )
        return
    case "omo":
        try cli.runOMO(
            commandArgs: commandArgs,
            socketPath: resolveSocketPath(),
            explicitPassword: socketPasswordArg
        )
        return
    case "omx":
        try cli.runOMX(
            commandArgs: commandArgs,
            socketPath: resolveSocketPath(),
            explicitPassword: socketPasswordArg
        )
        return
    case "omc":
        try cli.runOMC(
            commandArgs: commandArgs,
            socketPath: resolveSocketPath(),
            explicitPassword: socketPasswordArg
        )
        return
    case "aside":
        try cli.runAside(arguments: commandArgs)
        return
    default:
        break
    }

    if try HookInstallationCoordinator(cli: cli).dispatch(command: command, arguments: commandArgs) {
        return
    }

    // Codex hook handler: gracefully no-op when not inside programa
    // (before socket connection, so it doesn't fail when no socket exists)
    if command == "codex-hook" {
        guard ProcessInfo.processInfo.environment["PROGRAMA_SURFACE_ID"] != nil else {
            print("{}")
            return
        }
    }

    // OpenCode hook handler: gracefully no-op when not inside programa
    // (before socket connection, so it doesn't fail when no socket exists)
    if command == "opencode-hook" {
        guard ProcessInfo.processInfo.environment["PROGRAMA_SURFACE_ID"] != nil else {
            print("{}")
            return
        }
    }

    guard descriptor.connectionPolicy == .socket else {
        throw CLIError(message: "Unsupported \(command) subcommand")
    }
    guard let execute = descriptor.execute else {
        throw CLIError(message: "Command is unavailable: \(command)")
    }

    let resolvedSocketPath = resolveSocketPath()

    let client = SocketClient(path: resolvedSocketPath)
    try client.connectWithTransientRetry()
    defer { client.close() }

    try cli.authenticateClientIfNeeded(
        client,
        explicitPassword: socketPasswordArg,
        socketPath: resolvedSocketPath
    )

    // If the user explicitly targets a window, focus it first so commands route correctly.
    if let windowId {
        let normalizedWindow = try cli.normalizeWindowHandle(windowId, client: client) ?? windowId
        _ = try client.sendV2(method: "window.focus", params: ["window_id": normalizedWindow])
    }

    let ctx = CommandContext(
        command: command,
        commandArgs: commandArgs,
        client: client,
        jsonOutput: jsonOutput,
        idFormat: idFormat,
        idFormatArgProvided: idFormatArg != nil,
        windowId: windowId,
        socketPasswordArg: socketPasswordArg
    )
    try execute(ctx)
}

}
