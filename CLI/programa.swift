import Foundation
import Darwin

enum CLIIDFormat: String {
    case refs
    case uuids
    case both

    static func parse(_ raw: String?) throws -> CLIIDFormat? {
        guard let raw else { return nil }
        guard let parsed = CLIIDFormat(rawValue: raw.lowercased()) else {
            throw CLIError(message: "--id-format must be one of: refs, uuids, both")
        }
        return parsed
    }
}

struct CLIProcessResult {
    let status: Int32
    let stdout: String
    let stderr: String
    let timedOut: Bool
}

enum CLIProcessRunner {
    private static let maximumCapturedBytesPerStream = 8 * 1024 * 1024

    private final class OutputCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var stdoutData = Data()
        private var stderrData = Data()

        func storeStdout(_ data: Data) {
            lock.lock()
            stdoutData = data
            lock.unlock()
        }

        func storeStderr(_ data: Data) {
            lock.lock()
            stderrData = data
            lock.unlock()
        }

        func snapshot() -> (stdout: Data, stderr: Data) {
            lock.lock()
            defer { lock.unlock() }
            return (stdoutData, stderrData)
        }
    }

    private static func readBounded(_ handle: FileHandle) -> Data {
        let chunkSize = 64 * 1024
        var captured = Data()
        while true {
            let chunk = handle.readData(ofLength: chunkSize)
            if chunk.isEmpty { break }
            if captured.count < maximumCapturedBytesPerStream {
                captured.append(contentsOf: chunk.prefix(maximumCapturedBytesPerStream - captured.count))
            }
        }
        return captured
    }

    static func runProcess(
        executablePath: String,
        arguments: [String],
        stdinText: String? = nil,
        timeout: TimeInterval? = nil,
        currentDirectoryPath: String? = nil
    ) -> CLIProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        if let currentDirectoryPath {
            process.currentDirectoryURL = URL(fileURLWithPath: currentDirectoryPath, isDirectory: true)
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdinPipe: Pipe?
        if stdinText != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            stdinPipe = pipe
        } else {
            stdinPipe = nil
        }

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            finished.signal()
        }

        do {
            try process.run()
        } catch {
            return CLIProcessResult(status: 1, stdout: "", stderr: String(describing: error), timedOut: false)
        }

        let outputCollector = OutputCollector()
        let outputReaders = DispatchGroup()
        outputReaders.enter()
        DispatchQueue.global(qos: .utility).async {
            outputCollector.storeStdout(readBounded(stdoutPipe.fileHandleForReading))
            outputReaders.leave()
        }
        outputReaders.enter()
        DispatchQueue.global(qos: .utility).async {
            outputCollector.storeStderr(readBounded(stderrPipe.fileHandleForReading))
            outputReaders.leave()
        }

        let inputWriter = DispatchGroup()
        if let stdinText, let stdinPipe {
            inputWriter.enter()
            DispatchQueue.global(qos: .utility).async {
                if let data = stdinText.data(using: .utf8) {
                    try? stdinPipe.fileHandleForWriting.write(contentsOf: data)
                }
                try? stdinPipe.fileHandleForWriting.close()
                inputWriter.leave()
            }
        }

        let timedOut: Bool
        if let timeout {
            switch finished.wait(timeout: .now() + timeout) {
            case .success:
                timedOut = false
            case .timedOut:
                timedOut = true
                terminate(process: process, finished: finished)
            }
        } else {
            finished.wait()
            timedOut = false
        }

        inputWriter.wait()
        outputReaders.wait()
        let output = outputCollector.snapshot()
        let stdout = String(decoding: output.stdout, as: UTF8.self)
        var stderr = String(decoding: output.stderr, as: UTF8.self)
        if timedOut {
            let timeoutMessage = "process timed out"
            if stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                stderr = timeoutMessage
            } else if !stderr.contains(timeoutMessage) {
                stderr += "\n\(timeoutMessage)"
            }
        }

        return CLIProcessResult(
            status: timedOut ? 124 : process.terminationStatus,
            stdout: stdout,
            stderr: stderr,
            timedOut: timedOut
        )
    }

    private static func terminate(process: Process, finished: DispatchSemaphore) {
        guard process.isRunning else { return }
        process.terminate()
        if finished.wait(timeout: .now() + 0.5) == .success {
            return
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        _ = finished.wait(timeout: .now() + 0.5)
    }
}

/// Execution context passed to a `CommandDescriptor`'s `execute` closure.
///
/// Bundles everything a command body reads from `run()`'s locals
/// (commandArgs, client, jsonOutput, idFormat, windowId, and the literal
/// command name, needed by handlers shared across several names such as
/// the tmux-compat group).
struct CommandContext {
    let command: String
    let commandArgs: [String]
    let client: SocketClient
    let jsonOutput: Bool
    let idFormat: CLIIDFormat
    /// True when the user passed `--id-format` explicitly (distinct from
    /// `idFormat`, which always has a concrete value). Only `rpc` cares
    /// about this distinction today.
    let idFormatArgProvided: Bool
    let windowId: String?
    /// Explicit `--password` value, if any. Only `watch-events`' reconnect loop needs this
    /// today, to re-run `authenticateClientIfNeeded` after re-establishing a dropped
    /// connection (auth is per-connection, not per-process).
    let socketPasswordArg: String?
}

enum CLICommandConnectionPolicy {
    /// The command is parsed and validated first, then receives one connected client.
    case socket
    /// The command owns any process/socket work it needs and must not be preconnected.
    case local
}

enum CLICommandHelpPolicy {
    /// `--help` is handled by Programa without acquiring a socket.
    case programa
    /// Help flags are forwarded verbatim to the wrapped/internal command.
    case passthrough
}

/// Typed preflight contracts that must succeed before a socket client exists.
/// `.registered` routes through the exhaustive command grammar table; bespoke
/// cases retain additional semantic validation where the schema is richer.
enum CLICommandArgumentContract {
    case registered
    /// The handler parses its own (often foreign or passthrough) arguments, so
    /// preflight leaves them untouched.
    case handlerParsed
    case noArguments
    case focusPanel
    case readScreen
    case waitSurface
    case setProgress
    case listLog
    case watchEvents
}

/// The argument grammar a `.registered` command accepts, declared once on its
/// descriptor so validation is generated from the same source that documents
/// it (`detailedUsage`), instead of being restated by hand as a switch arm in
/// `validateRegisteredArguments`. Field vocabulary matches that function's
/// nested `parse`/`require` helpers.
///
/// A command with a `nil` grammar (the default) falls through to the switch
/// in `validateRegisteredArguments`, which covers only descriptors declared
/// outside `CLI/Commands/`.
struct CLIArgumentGrammar {
    /// Flags that take a value, e.g. `--name <value>`.
    var valueOptions: Set<String> = []
    var repeatableValueOptions: Set<String> = []
    /// Flags with no value, e.g. `--force`.
    var booleanOptions: Set<String> = []
    /// Subset of `valueOptions` that must be present. Checked in this order,
    /// matching `require(_:in:)`'s first-missing-wins error semantics.
    var requiredOptions: [String] = []
    var minPositionals: Int = 0
    /// `nil` means unbounded.
    var maxPositionals: Int? = 0
    /// Single-dash tokens accepted as positionals, e.g. `-y`.
    var shortFlags: Set<String> = []
    /// Semantic checks the flag schema cannot state (allowed values, numeric
    /// ranges, mutually exclusive flags). Runs after parsing and
    /// `requiredOptions`; receives the command name for error messages.
    var validate: ((_ command: String, _ parsed: (positional: [String], options: [String: String])) throws -> Void)?
}

/// Single source of truth for a CLI command's name(s), its one-line entry in
/// the grouped `Commands:` help block, and how it executes.
///
/// This one table covers what would otherwise be three separate places:
/// the kebab-case dispatch switch, the free-text `usage()` help string, and
/// (implicitly) the "is this a known command" check used for unknown-command
/// handling. A command added to the table automatically gets dispatch,
/// help-list membership, and unknown-command exclusion in one place —
/// nothing else to keep in sync.
///
/// Commands whose implementation is intercepted in `run()` still have a
/// descriptor so their connection, help, and argument policies are decided
/// before any socket work begins.
///
/// A descriptor with `names: []` is a pure help-text spacer/section-comment
/// (e.g. the blank line + "# tmux compatibility commands" header) — it
/// contributes lines to the help block but never participates in dispatch.
///
/// Explicit non-goal: this table only unifies CLI-side name → behavior
/// knowledge. It does not attempt to unify with the app-side v2 method
/// switch (`Sources/TerminalController.swift`'s `processV2Command`) — that's
/// server code with different concerns (method routing, not CLI UX).
struct CommandDescriptor {
    /// Kebab-case name(s) that route to this descriptor. More than one name
    /// means the names are aliases sharing one handler (e.g. tmux-compat
    /// commands, or `rename-workspace`/`rename-window`).
    let names: [String]
    /// Lines contributed verbatim, in order, to the `Commands:` section of
    /// `usage()`. Empty means the command exists but is intentionally
    /// undocumented.
    let helpLines: [String]
    let connectionPolicy: CLICommandConnectionPolicy
    let helpPolicy: CLICommandHelpPolicy
    let argumentContract: CLICommandArgumentContract
    /// Full, verbatim `programa <command> --help` text (the `Usage: ...`
    /// block), or `nil` if this command has no detailed usage text (falls
    /// back to `helpLines` only, or to one of the per-family
    /// `*SubcommandUsage` helpers checked before the table lookup).
    let detailedUsage: String?
    /// When set (and `argumentContract == .registered`), drives argument
    /// validation directly instead of the command needing a switch arm in
    /// `validateRegisteredArguments`. `nil` means "still on the switch".
    let grammar: CLIArgumentGrammar?
    /// Executes the command. `nil` for commands implemented directly by
    /// `run()` before generic socket dispatch.
    let execute: ((CommandContext) throws -> Void)?

    init(
        names: [String],
        helpLines: [String],
        connectionPolicy: CLICommandConnectionPolicy = .socket,
        helpPolicy: CLICommandHelpPolicy = .programa,
        argumentContract: CLICommandArgumentContract = .registered,
        detailedUsage: String? = nil,
        grammar: CLIArgumentGrammar? = nil,
        execute: ((CommandContext) throws -> Void)?
    ) {
        self.names = names
        self.helpLines = helpLines
        self.connectionPolicy = connectionPolicy
        self.helpPolicy = helpPolicy
        self.argumentContract = argumentContract
        self.detailedUsage = detailedUsage
        self.grammar = grammar
        self.execute = execute
    }
}

/// Memoizes `ProgramaCLI.commandDescriptors()`. The table's closures capture
/// the CLI value that built it, so it lives for the rest of the process.
final class CommandDescriptorCache {
    private let lock = NSLock()
    private var cached: [CommandDescriptor]?

    func descriptors(_ build: () -> [CommandDescriptor]) -> [CommandDescriptor] {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let built = build()
        cached = built
        return built
    }
}

struct ProgramaCLI {
    let args: [String]
    let descriptorCache = CommandDescriptorCache()

    func run() throws {
        try CLICommandDispatcher(cli: self).run()
    }
    /// Single source of truth for command existence, help text, and dispatch.
    /// See `CommandDescriptor` for the collapsed-knowledge rationale.
    ///
    /// Order matches the `Commands:` help block, since that order
    /// is externally visible; dispatch itself is by name lookup and does not
    /// depend on array order. Built once per process: dispatch, argument
    /// validation and help all look commands up here.
    func commandDescriptors() -> [CommandDescriptor] {
        descriptorCache.descriptors { buildCommandDescriptors() }
    }

    private func buildCommandDescriptors() -> [CommandDescriptor] {
        // Each group is its own array literal in CLI/Commands/: one expression
        // spanning every descriptor times out the Swift type-checker.
        var descriptors = localCommandDescriptors()
        descriptors += systemCommandDescriptors()
        descriptors += windowCommandDescriptors()
        descriptors += workspaceOrderingDescriptors()
        descriptors += worktreeAndLayoutDescriptors()
        descriptors += workspaceListDescriptors()
        descriptors += paneListDescriptors()
        descriptors += self.treeDescriptors()
        descriptors += self.portsDescriptors() + self.resumeDescriptors() + self.usageDescriptors() + self.storageDescriptors()
        descriptors += self.handoffDescriptors()
        descriptors += paneSurfaceDescriptors()
        descriptors += surfaceDiagnosticsDescriptors()
        descriptors += panelDescriptors()
        descriptors += workspaceSelectionDescriptors()
        descriptors += terminalIODescriptors()
        descriptors += notificationDescriptors()
        descriptors += sidebarMetadataDescriptors()
        descriptors += self.hooksDescriptors()
        descriptors += internalCommandDescriptors()
        // tmux compatibility commands all share one bespoke handler; help text
        // preserves the original grouped layout, including the two
        // pipe-separated combo lines.
        descriptors.append(CommandDescriptor(names: [], helpLines: ["", "# tmux compatibility commands"], execute: nil))
        descriptors += Self.tmuxCompatDescriptors(runTmuxCompatCommand: { ctx in
            try self.runTmuxCompatCommand(
                command: ctx.command,
                commandArgs: ctx.commandArgs,
                client: ctx.client,
                jsonOutput: ctx.jsonOutput,
                idFormat: ctx.idFormat,
                windowOverride: ctx.windowId
            )
        })
        descriptors.append(CommandDescriptor(names: [], helpLines: [""], execute: nil))
        descriptors += viewerPanelDescriptors()
        descriptors.append(CommandDescriptor(names: [], helpLines: [""], execute: nil))
        descriptors += helpCommandDescriptors()
        return descriptors
    }

    /// Looks up the descriptor whose `names` contains `command`, if any.
    func commandDescriptor(named command: String) -> CommandDescriptor? {
        commandDescriptors().first { $0.names.contains(command) }
    }

    func resolvePath(_ path: String) -> String {
        let expanded = NSString(string: path).expandingTildeInPath
        if expanded.hasPrefix("/") { return expanded }
        let cwd = FileManager.default.currentDirectoryPath
        return (cwd as NSString).appendingPathComponent(expanded)
    }

    /// Returns true if the argument looks like a filesystem path rather than a CLI command.
    func looksLikePath(_ arg: String) -> Bool {
        if arg == "." || arg == ".." { return true }
        if arg.hasPrefix("/") || arg.hasPrefix("./") || arg.hasPrefix("../") || arg.hasPrefix("~") { return true }
        if arg.contains("/") { return true }
        return false
    }

    /// Open a path in programa by creating a new workspace with the given directory.
    /// Launches the app if it isn't already running.
    func openPath(_ path: String, socketPath: String, explicitPassword: String?) throws {
        let resolved = resolvePath(path)
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir)

        let directory: String
        if exists && isDir.boolValue {
            directory = resolved
        } else if exists {
            directory = (resolved as NSString).deletingLastPathComponent
        } else {
            throw CLIError(message: "Path does not exist: \(resolved)")
        }

        let client = try connectClient(
            socketPath: socketPath,
            explicitPassword: explicitPassword,
            launchIfNeeded: true
        )
        defer { client.close() }

        let params: [String: Any] = ["cwd": directory]
        let response = try client.sendV2(method: V2MethodNames.workspaceCreate, params: params)
        let wsRef = (response["workspace_ref"] as? String) ?? (response["workspace_id"] as? String) ?? ""
        if !wsRef.isEmpty {
            print("OK \(wsRef)")
        }

        try activateApp()
    }

    func runFeedback(
        commandArgs: [String],
        socketPath: String,
        explicitPassword: String?,
        jsonOutput: Bool
    ) throws {
        let (emailOpt, rem0) = parseOption(commandArgs, name: "--email")
        let (bodyOpt, rem1) = parseOption(rem0, name: "--body")
        let (imagePaths, rem2) = parseRepeatedOption(rem1, name: "--image")
        let remaining = rem2.filter { $0 != "--" }

        if let unknown = remaining.first {
            throw CLIError(message: "feedback: unknown flag '\(unknown)'. Known flags: --email <email>, --body <text>, --image <path>")
        }

        let client = try connectClient(
            socketPath: socketPath,
            explicitPassword: explicitPassword,
            launchIfNeeded: true
        )
        defer { client.close() }

        if emailOpt == nil && bodyOpt == nil && imagePaths.isEmpty {
            var params: [String: Any] = [:]
            let env = ProcessInfo.processInfo.environment
            if let workspaceId = env["PROGRAMA_WORKSPACE_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !workspaceId.isEmpty {
                params["workspace_id"] = workspaceId
                params["activate"] = false
            } else {
                params["activate"] = true
            }
            let response = try client.sendV2(method: V2MethodNames.feedbackOpen, params: params)
            if jsonOutput {
                print(jsonString(response))
            } else {
                print("OK")
            }
            return
        }

        guard let email = emailOpt?.trimmingCharacters(in: .whitespacesAndNewlines),
              email.isEmpty == false else {
            throw CLIError(message: "feedback requires --email <email> when sending feedback")
        }
        guard let body = bodyOpt, body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw CLIError(message: "feedback requires --body <text> when sending feedback")
        }

        let resolvedImages = imagePaths.map(resolvePath)
        let response = try client.sendV2(method: V2MethodNames.feedbackSubmit, params: [
            "email": email,
            "body": body,
            "image_paths": resolvedImages,
        ])
        if jsonOutput {
            print(jsonString(response))
        } else {
            print("OK")
        }
    }

    func runShortcuts(
        commandArgs: [String],
        socketPath: String,
        explicitPassword: String?,
        jsonOutput: Bool
    ) throws {
        let remaining = commandArgs.filter { $0 != "--" }
        if let unknown = remaining.first {
            throw CLIError(message: "shortcuts: unknown flag '\(unknown)'")
        }

        let client = try connectClient(
            socketPath: socketPath,
            explicitPassword: explicitPassword,
            launchIfNeeded: true
        )
        defer { client.close() }

        let response = try client.sendV2(method: V2MethodNames.settingsOpen, params: [
            "target": "keyboardShortcuts",
            "activate": true,
        ])
        if jsonOutput {
            print(jsonString(response))
        } else {
            print("OK")
        }
    }

    private func connectClient(
        socketPath: String,
        explicitPassword: String?,
        launchIfNeeded: Bool
    ) throws -> SocketClient {
        let client = SocketClient(path: socketPath)
        if launchIfNeeded && (try? client.connect()) == nil {
            client.close()
            try launchApp()
            let launchedClient = try SocketClient.waitForConnectableSocket(path: socketPath, timeout: 10)
            try authenticateClientIfNeeded(
                launchedClient,
                explicitPassword: explicitPassword,
                socketPath: socketPath
            )
            return launchedClient
        }

        try client.connect()
        try authenticateClientIfNeeded(
            client,
            explicitPassword: explicitPassword,
            socketPath: socketPath
        )
        return client
    }

    func authenticateClientIfNeeded(
        _ client: SocketClient,
        explicitPassword: String?,
        socketPath: String
    ) throws {
        if let socketPassword = SocketPasswordResolver.resolve(
            explicit: explicitPassword,
            socketPath: socketPath
        ) {
            // v2 JSON-RPC auth.login. The server treats this the same whether or not
            // password auth is actually required: when required, the pre-protocol auth
            // gate verifies the password before any command is processed; when not
            // required, the server's own auth.login handler answers with
            // authenticated: true, required: false rather than an error.
            _ = try client.sendV2(method: V2MethodNames.authLogin, params: ["password": socketPassword])
        }
    }

    private func launchApp() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Programa"]
        try process.run()
        process.waitUntilExit()
    }

    private func activateApp() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Programa"]
        try process.run()
        process.waitUntilExit()
    }

    func resolvedIDFormat(jsonOutput: Bool, raw: String?) throws -> CLIIDFormat {
        _ = jsonOutput
        if let parsed = try CLIIDFormat.parse(raw) {
            return parsed
        }
        return .refs
    }

    func formatIDs(_ object: Any, mode: CLIIDFormat) -> Any {
        switch object {
        case let dict as [String: Any]:
            var out: [String: Any] = [:]
            for (k, v) in dict {
                out[k] = formatIDs(v, mode: mode)
            }

            switch mode {
            case .both:
                break
            case .refs:
                if out["ref"] != nil && out["id"] != nil {
                    out.removeValue(forKey: "id")
                }
                let keys = Array(out.keys)
                for key in keys where key.hasSuffix("_id") {
                    let prefix = String(key.dropLast(3))
                    if out["\(prefix)_ref"] != nil {
                        out.removeValue(forKey: key)
                    }
                }
                for key in keys where key.hasSuffix("_ids") {
                    let prefix = String(key.dropLast(4))
                    if out["\(prefix)_refs"] != nil {
                        out.removeValue(forKey: key)
                    }
                }
            case .uuids:
                if out["id"] != nil && out["ref"] != nil {
                    out.removeValue(forKey: "ref")
                }
                let keys = Array(out.keys)
                for key in keys where key.hasSuffix("_ref") {
                    let prefix = String(key.dropLast(4))
                    if out["\(prefix)_id"] != nil {
                        out.removeValue(forKey: key)
                    }
                }
                for key in keys where key.hasSuffix("_refs") {
                    let prefix = String(key.dropLast(5))
                    if out["\(prefix)_ids"] != nil {
                        out.removeValue(forKey: key)
                    }
                }
            }
            return out

        case let array as [Any]:
            return array.map { formatIDs($0, mode: mode) }

        default:
            return object
        }
    }

    func intFromAny(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String { return Int(s) }
        return nil
    }

    func doubleFromAny(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let f = value as? Float { return Double(f) }
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    func parseBoolString(_ raw: String) -> Bool? {
        switch raw.lowercased() {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return nil
        }
    }

    func isHandleRef(_ value: String) -> Bool {
        let pieces = value.split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count == 2 else { return false }
        let kind = String(pieces[0]).lowercased()
        guard ["window", "workspace", "pane", "surface"].contains(kind) else { return false }
        return Int(String(pieces[1])) != nil
    }

    /// Generic handle normalizer shared by window/workspace/pane/surface lookups.
    /// Resolves a raw CLI argument (UUID or handle ref) to a canonical
    /// handle ref/id, optionally scoped to a parent handle and falling back to a
    /// caller-supplied "current"/"focused" resolver when `raw` is nil. Bare indexes
    /// are rejected with a clear error.
    private func normalizeHandle(
        _ raw: String?,
        client: SocketClient,
        kind: String,
        filterParam: (key: String, value: String)? = nil,
        fallback: () throws -> String?
    ) throws -> String? {
        guard let raw else {
            return try fallback()
        }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if isUUID(trimmed) || isHandleRef(trimmed) {
            return trimmed
        }
        if Int(trimmed) != nil {
            let listCommand = kind == "surface" ? "list-pane-surfaces" : "list-\(kind)s"
            throw CLIError(message: "\(kind): bare indexes are no longer accepted; use a UUID or short ref like \(kind):2 (see \(listCommand))")
        }
        throw CLIError(message: "Invalid \(kind) handle: \(trimmed) (expected UUID or ref like \(kind):1)")
    }

    func normalizeWindowHandle(_ raw: String?, client: SocketClient, allowCurrent: Bool = false) throws -> String? {
        try normalizeHandle(raw, client: client, kind: "window") {
            guard allowCurrent else { return nil }
            let current = try client.sendV2(method: V2MethodNames.windowCurrent)
            return (current["window_ref"] as? String) ?? (current["window_id"] as? String)
        }
    }

    func normalizeWorkspaceHandle(
        _ raw: String?,
        client: SocketClient,
        windowHandle: String? = nil,
        allowCurrent: Bool = false
    ) throws -> String? {
        try normalizeHandle(
            raw,
            client: client,
            kind: "workspace",
            filterParam: windowHandle.map { ("window_id", $0) }
        ) {
            guard allowCurrent else { return nil }
            let current = try client.sendV2(method: V2MethodNames.workspaceCurrent)
            return (current["workspace_ref"] as? String) ?? (current["workspace_id"] as? String)
        }
    }

    func normalizePaneHandle(
        _ raw: String?,
        client: SocketClient,
        workspaceHandle: String? = nil,
        allowFocused: Bool = false
    ) throws -> String? {
        try normalizeHandle(
            raw,
            client: client,
            kind: "pane",
            filterParam: workspaceHandle.map { ("workspace_id", $0) }
        ) {
            guard allowFocused else { return nil }
            let ident = try client.sendV2(method: V2MethodNames.systemIdentify)
            let focused = ident["focused"] as? [String: Any] ?? [:]
            return (focused["pane_ref"] as? String) ?? (focused["pane_id"] as? String)
        }
    }

    func normalizeSurfaceHandle(
        _ raw: String?,
        client: SocketClient,
        workspaceHandle: String? = nil,
        allowFocused: Bool = false
    ) throws -> String? {
        try normalizeHandle(
            raw,
            client: client,
            kind: "surface",
            filterParam: workspaceHandle.map { ("workspace_id", $0) }
        ) {
            guard allowFocused else { return nil }
            let ident = try client.sendV2(method: V2MethodNames.systemIdentify)
            let focused = ident["focused"] as? [String: Any] ?? [:]
            return (focused["surface_ref"] as? String) ?? (focused["surface_id"] as? String)
        }
    }

    func resolveCommandSurface(
        explicitSurface: String?,
        explicitWorkspace: String?,
        windowId: String?,
        workspaceHandle: String?,
        client: SocketClient
    ) throws -> String? {
        if let explicitSurface {
            return try normalizeSurfaceHandle(explicitSurface, client: client, workspaceHandle: workspaceHandle)
        }
        guard explicitWorkspace == nil, windowId == nil,
              let rawOrigin = ProcessInfo.processInfo.environment["PROGRAMA_SURFACE_ID"] else { return nil }
        if workspaceHandle == nil {
            return try normalizeSurfaceHandle(rawOrigin, client: client, workspaceHandle: nil)
        }
        let origin = rawOrigin.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isUUID(origin) || isHandleRef(origin) else { return nil }

        let params: [String: Any] = workspaceHandle.map { ["workspace_id": $0] } ?? [:]
        let listed = try client.sendV2(method: V2MethodNames.surfaceList, params: params)
        guard let surfaces = listed["surfaces"] as? [[String: Any]] else {
            throw CLIError(message: "Invalid surface.list response: missing surfaces")
        }
        if let expectedWorkspace = workspaceHandle.flatMap(UUID.init(uuidString:)),
           let returnedWorkspace = listed["workspace_id"] as? String,
           UUID(uuidString: returnedWorkspace) != expectedWorkspace {
            throw CLIError(message: "Invalid surface.list response: workspace mismatch")
        }
        let originUUID = UUID(uuidString: origin)
        var resolvedOrigin: String?
        for surface in surfaces {
            guard let id = surface["id"] as? String, let uuid = UUID(uuidString: id) else {
                throw CLIError(message: "Invalid surface.list response: missing surface UUID")
            }
            let reference = (surface["ref"] as? String)?.lowercased()
            if originUUID == nil {
                guard let reference, reference.hasPrefix("surface:"), isHandleRef(reference) else {
                    throw CLIError(message: "Invalid surface.list response: missing surface reference")
                }
            }
            if uuid == originUUID || reference == origin.lowercased() {
                resolvedOrigin = id
            }
        }
        // Only a missing/foreign origin falls back to the workspace's focused
        // surface. A validated origin is pinned to its UUID for this command;
        // a later server error must never retry against a different panel.
        return resolvedOrigin
    }

    private func canonicalSurfaceHandleFromTabInput(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let pieces = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count == 2,
              String(pieces[0]).lowercased() == "tab",
              let ordinal = Int(String(pieces[1])) else {
            return trimmed
        }
        return "surface:\(ordinal)"
    }

    private func normalizeTabHandle(
        _ raw: String?,
        client: SocketClient,
        workspaceHandle: String? = nil,
        allowFocused: Bool = false
    ) throws -> String? {
        guard let raw else {
            return try normalizeSurfaceHandle(
                nil,
                client: client,
                workspaceHandle: workspaceHandle,
                allowFocused: allowFocused
            )
        }

        let canonical = canonicalSurfaceHandleFromTabInput(raw)
        return try normalizeSurfaceHandle(
            canonical,
            client: client,
            workspaceHandle: workspaceHandle,
            allowFocused: false
        )
    }

    private func displayTabHandle(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let pieces = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count == 2,
              String(pieces[0]).lowercased() == "surface",
              let ordinal = Int(String(pieces[1])) else {
            return trimmed
        }
        return "tab:\(ordinal)"
    }

    func formatHandle(_ payload: [String: Any], kind: String, idFormat: CLIIDFormat) -> String? {
        formatHandle(id: payload["\(kind)_id"] as? String, ref: payload["\(kind)_ref"] as? String, idFormat: idFormat)
    }

    func formatHandle(id: String?, ref: String?, idFormat: CLIIDFormat) -> String? {
        switch idFormat {
        case .refs:
            return ref ?? id
        case .uuids:
            return id ?? ref
        case .both:
            if let ref, let id {
                return "\(ref) (\(id))"
            }
            return ref ?? id
        }
    }

    private func formatTabHandle(_ payload: [String: Any], idFormat: CLIIDFormat) -> String? {
        let id = (payload["tab_id"] as? String) ?? (payload["surface_id"] as? String)
        let refRaw = (payload["tab_ref"] as? String) ?? (payload["surface_ref"] as? String)
        return formatHandle(id: id, ref: displayTabHandle(refRaw), idFormat: idFormat)
    }

    private func formatCreatedTabHandle(_ payload: [String: Any], idFormat: CLIIDFormat) -> String? {
        let id = (payload["created_tab_id"] as? String) ?? (payload["created_surface_id"] as? String)
        let refRaw = (payload["created_tab_ref"] as? String) ?? (payload["created_surface_ref"] as? String)
        return formatHandle(id: id, ref: displayTabHandle(refRaw), idFormat: idFormat)
    }

    func printV2Payload(
        _ payload: [String: Any],
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        fallbackText: String
    ) {
        if jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
        } else {
            print(fallbackText)
        }
    }

    private func debugString(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        if let string = value as? String {
            return string
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return String(describing: value)
    }

    private func debugBool(_ value: Any?) -> Bool? {
        if let bool = value as? Bool {
            return bool
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        if let string = value as? String {
            return parseBoolString(string)
        }
        return nil
    }

    private func debugFlag(_ value: Any?) -> String {
        guard let bool = debugBool(value) else { return "nil" }
        return bool ? "1" : "0"
    }

    private func formatDebugRect(_ value: Any?) -> String? {
        guard let rect = value as? [String: Any],
              let x = doubleFromAny(rect["x"]),
              let y = doubleFromAny(rect["y"]),
              let width = doubleFromAny(rect["width"]),
              let height = doubleFromAny(rect["height"]) else {
            return nil
        }
        return String(format: "{%.1f,%.1f %.1fx%.1f}", x, y, width, height)
    }

    private func formatDebugPorts(_ value: Any?) -> String {
        guard let array = value as? [Any], !array.isEmpty else { return "[]" }
        let ports = array
            .compactMap { intFromAny($0) }
            .map(String.init)
        return ports.isEmpty ? "[]" : ports.joined(separator: ",")
    }

    private func formatDebugList(_ value: Any?) -> String? {
        guard let array = value as? [Any], !array.isEmpty else { return nil }
        let items = array.compactMap { item -> String? in
            if let string = item as? String {
                return string
            }
            return debugString(item)
        }
        guard !items.isEmpty else { return nil }
        return items.joined(separator: ">")
    }

    private func formatDebugAge(_ value: Any?) -> String? {
        guard let seconds = doubleFromAny(value) else { return nil }
        return String(format: "%.3fs", seconds)
    }

    func formatDebugTerminalsPayload(_ payload: [String: Any], idFormat: CLIIDFormat) -> String {
        let terminals = payload["terminals"] as? [[String: Any]] ?? []
        guard !terminals.isEmpty else { return "No terminal surfaces" }

        return terminals.map { item in
            let index = intFromAny(item["index"]) ?? 0
            let surface = formatHandle(item, kind: "surface", idFormat: idFormat) ?? "?"
            let window = formatHandle(item, kind: "window", idFormat: idFormat) ?? "nil"
            let workspace = formatHandle(item, kind: "workspace", idFormat: idFormat) ?? "nil"
            let pane = formatHandle(item, kind: "pane", idFormat: idFormat) ?? "nil"
            let bonsplitTab = debugString(item["bonsplit_tab_id"]) ?? "nil"
            let lastKnownWorkspace = debugString(item["last_known_workspace_ref"]) ?? debugString(item["last_known_workspace_id"]) ?? "nil"
            let titleSuffix: String = {
                guard let title = debugString(item["surface_title"]), !title.isEmpty else { return "" }
                let escaped = title.replacingOccurrences(of: "\"", with: "\\\"")
                return " \"\(escaped)\""
            }()
            let branchLabel: String = {
                guard let branch = debugString(item["git_branch"]), !branch.isEmpty else { return "nil" }
                return debugBool(item["git_dirty"]) == true ? "\(branch)*" : branch
            }()
            let teardownLabel: String = {
                guard debugBool(item["teardown_requested"]) == true else { return "nil" }
                let reason = debugString(item["teardown_requested_reason"]) ?? "requested"
                let age = formatDebugAge(item["teardown_requested_age_seconds"]) ?? "unknown"
                return "\(reason)@\(age)"
            }()
            let portalHostLabel: String = {
                let hostId = debugString(item["portal_host_id"]) ?? "nil"
                let area = doubleFromAny(item["portal_host_area"]).map { String(format: "%.1f", $0) } ?? "nil"
                let inWindow = debugFlag(item["portal_host_in_window"])
                return "\(hostId)/win=\(inWindow)/area=\(area)"
            }()
            let windowMetaLabel: String = {
                let title = debugString(item["window_title"]) ?? "nil"
                let windowClass = debugString(item["window_class"]) ?? "nil"
                let controllerClass = debugString(item["window_controller_class"]) ?? "nil"
                let delegateClass = debugString(item["window_delegate_class"]) ?? "nil"
                return "title=\(title) class=\(windowClass) controller=\(controllerClass) delegate=\(delegateClass)"
            }()

            let line1 =
                "[\(index)] \(surface)\(titleSuffix) " +
                "mapped=\(debugFlag(item["mapped"])) tree=\(debugFlag(item["tree_visible"])) " +
                "window=\(window) workspace=\(workspace) pane=\(pane) bonsplitTab=\(bonsplitTab) " +
                "ctx=\(debugString(item["surface_context"]) ?? "nil")"

            let line2 =
                "    runtime=\(debugFlag(item["runtime_surface_ready"])) " +
                "focused=\(debugFlag(item["surface_focused"])) " +
                "selected=\(debugFlag(item["surface_selected_in_pane"])) " +
                "pinned=\(debugFlag(item["surface_pinned"])) " +
                "terminal=\(debugString(item["terminal_object_ptr"]) ?? "nil") " +
                "hosted=\(debugString(item["hosted_view_ptr"]) ?? "nil") " +
                "ghostty=\(debugString(item["ghostty_surface_ptr"]) ?? "nil") " +
                "portal=\(debugString(item["portal_binding_state"]) ?? "nil")#\(debugString(item["portal_binding_generation"]) ?? "nil") " +
                "teardown=\(teardownLabel)"

            let line3 =
                "    tty=\(debugString(item["tty"]) ?? "nil") " +
                "cwd=\(debugString(item["current_directory"]) ?? debugString(item["requested_working_directory"]) ?? "nil") " +
                "branch=\(branchLabel) " +
                "ports=\(formatDebugPorts(item["listening_ports"])) " +
                "visible=\(debugFlag(item["hosted_view_visible_in_ui"])) " +
                "inWindow=\(debugFlag(item["hosted_view_in_window"])) " +
                "superview=\(debugFlag(item["hosted_view_has_superview"])) " +
                "hidden=\(debugFlag(item["hosted_view_hidden"])) " +
                "ancestorHidden=\(debugFlag(item["hosted_view_hidden_or_ancestor_hidden"])) " +
                "firstResponder=\(debugFlag(item["surface_view_first_responder"])) " +
                "windowNum=\(debugString(item["window_number"]) ?? "nil") " +
                "windowKey=\(debugFlag(item["window_key"])) " +
                "frame=\(formatDebugRect(item["hosted_view_frame_in_window"]) ?? "nil")"

            let line4 =
                "    created=\(formatDebugAge(item["surface_age_seconds"]) ?? "nil") " +
                "runtimeCreated=\(formatDebugAge(item["runtime_surface_age_seconds"]) ?? "nil") " +
                "lastWorkspace=\(lastKnownWorkspace) " +
                "initialCommand=\(debugString(item["initial_command"]) ?? "nil") " +
                "portalHost=\(portalHostLabel)"

            let line5 =
                "    window=\(windowMetaLabel) " +
                "chain=\(formatDebugList(item["hosted_view_superview_chain"]) ?? "nil")"

            return [line1, line2, line3, line4, line5].joined(separator: "\n")
        }
        .joined(separator: "\n")
    }

    func runMoveSurface(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let surfaceRaw = optionOrFirstPositional(commandArgs, name: "--surface")
        guard let surfaceRaw else {
            throw CLIError(message: "move-surface requires --surface <id|ref>")
        }

        let workspaceRaw = optionValue(commandArgs, name: "--workspace")
        let windowRaw = optionValue(commandArgs, name: "--window")
        let paneRaw = optionValue(commandArgs, name: "--pane")
        let beforeRaw = optionValue(commandArgs, name: "--before") ?? optionValue(commandArgs, name: "--before-surface")
        let afterRaw = optionValue(commandArgs, name: "--after") ?? optionValue(commandArgs, name: "--after-surface")

        let windowHandle = try normalizeWindowHandle(windowRaw, client: client)
        let workspaceHandle = try normalizeWorkspaceHandle(workspaceRaw, client: client, windowHandle: windowHandle)
        let surfaceHandle = try normalizeSurfaceHandle(surfaceRaw, client: client, workspaceHandle: workspaceHandle, allowFocused: false)
        let paneHandle = try normalizePaneHandle(paneRaw, client: client, workspaceHandle: workspaceHandle)
        let beforeHandle = try normalizeSurfaceHandle(beforeRaw, client: client, workspaceHandle: workspaceHandle)
        let afterHandle = try normalizeSurfaceHandle(afterRaw, client: client, workspaceHandle: workspaceHandle)

        var params: [String: Any] = [:]
        if let surfaceHandle { params["surface_id"] = surfaceHandle }
        if let paneHandle { params["pane_id"] = paneHandle }
        if let workspaceHandle { params["workspace_id"] = workspaceHandle }
        if let windowHandle { params["window_id"] = windowHandle }
        if let beforeHandle { params["before_surface_id"] = beforeHandle }
        if let afterHandle { params["after_surface_id"] = afterHandle }

        if let indexRaw = optionValue(commandArgs, name: "--index") {
            guard let index = Int(indexRaw) else {
                throw CLIError(message: "--index must be an integer")
            }
            params["index"] = index
        }
        if let focusRaw = optionValue(commandArgs, name: "--focus") {
            guard let focus = parseBoolString(focusRaw) else {
                throw CLIError(message: "--focus must be true|false")
            }
            params["focus"] = focus
        }

        let payload = try client.sendV2(method: V2MethodNames.surfaceMove, params: params)
        let summary = "OK surface=\(formatHandle(payload, kind: "surface", idFormat: idFormat) ?? "unknown") pane=\(formatHandle(payload, kind: "pane", idFormat: idFormat) ?? "unknown") workspace=\(formatHandle(payload, kind: "workspace", idFormat: idFormat) ?? "unknown") window=\(formatHandle(payload, kind: "window", idFormat: idFormat) ?? "unknown")"
        printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: summary)
    }

    func runReorderSurface(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let surfaceRaw = optionOrFirstPositional(commandArgs, name: "--surface")
        guard let surfaceRaw else {
            throw CLIError(message: "reorder-surface requires --surface <id|ref>")
        }

        let workspaceRaw = optionValue(commandArgs, name: "--workspace")
        let workspaceHandle = try normalizeWorkspaceHandle(workspaceRaw, client: client)
        let surfaceHandle = try normalizeSurfaceHandle(surfaceRaw, client: client, workspaceHandle: workspaceHandle)

        let beforeRaw = optionValue(commandArgs, name: "--before") ?? optionValue(commandArgs, name: "--before-surface")
        let afterRaw = optionValue(commandArgs, name: "--after") ?? optionValue(commandArgs, name: "--after-surface")
        let beforeHandle = try normalizeSurfaceHandle(beforeRaw, client: client, workspaceHandle: workspaceHandle)
        let afterHandle = try normalizeSurfaceHandle(afterRaw, client: client, workspaceHandle: workspaceHandle)

        var params: [String: Any] = [:]
        if let surfaceHandle { params["surface_id"] = surfaceHandle }
        if let beforeHandle { params["before_surface_id"] = beforeHandle }
        if let afterHandle { params["after_surface_id"] = afterHandle }
        if let indexRaw = optionValue(commandArgs, name: "--index") {
            guard let index = Int(indexRaw) else {
                throw CLIError(message: "--index must be an integer")
            }
            params["index"] = index
        }

        let payload = try client.sendV2(method: V2MethodNames.surfaceReorder, params: params)
        let summary = "OK surface=\(formatHandle(payload, kind: "surface", idFormat: idFormat) ?? "unknown") pane=\(formatHandle(payload, kind: "pane", idFormat: idFormat) ?? "unknown") workspace=\(formatHandle(payload, kind: "workspace", idFormat: idFormat) ?? "unknown")"
        printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: summary)
    }

    func runReorderWorkspace(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let workspaceRaw = optionOrFirstPositional(commandArgs, name: "--workspace")
        guard let workspaceRaw else {
            throw CLIError(message: "reorder-workspace requires --workspace <id|ref>")
        }

        let windowRaw = optionValue(commandArgs, name: "--window")
        let windowHandle = try normalizeWindowHandle(windowRaw, client: client)
        let workspaceHandle = try normalizeWorkspaceHandle(workspaceRaw, client: client, windowHandle: windowHandle)

        let beforeRaw = optionValue(commandArgs, name: "--before") ?? optionValue(commandArgs, name: "--before-workspace")
        let afterRaw = optionValue(commandArgs, name: "--after") ?? optionValue(commandArgs, name: "--after-workspace")
        let beforeHandle = try normalizeWorkspaceHandle(beforeRaw, client: client, windowHandle: windowHandle)
        let afterHandle = try normalizeWorkspaceHandle(afterRaw, client: client, windowHandle: windowHandle)

        var params: [String: Any] = [:]
        if let workspaceHandle { params["workspace_id"] = workspaceHandle }
        if let beforeHandle { params["before_workspace_id"] = beforeHandle }
        if let afterHandle { params["after_workspace_id"] = afterHandle }
        if let indexRaw = optionValue(commandArgs, name: "--index") {
            guard let index = Int(indexRaw) else {
                throw CLIError(message: "--index must be an integer")
            }
            params["index"] = index
        }
        if let windowHandle {
            params["window_id"] = windowHandle
        }

        let payload = try client.sendV2(method: V2MethodNames.workspaceReorder, params: params)
        let summary = "OK workspace=\(formatHandle(payload, kind: "workspace", idFormat: idFormat) ?? "unknown") window=\(formatHandle(payload, kind: "window", idFormat: idFormat) ?? "unknown") index=\(payload["index"] ?? "?")"
        printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: summary)
    }

    func runWorkspaceAction(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        let (workspaceOpt, rem0) = parseOption(commandArgs, name: "--workspace")
        let (actionOpt, rem1) = parseOption(rem0, name: "--action")
        let (titleOpt, rem2) = parseOption(rem1, name: "--title")
        let (colorOpt, rem3) = parseOption(rem2, name: "--color")
        let (descriptionOpt, rem4) = parseOption(rem3, name: "--description")

        var positional = rem4
        let actionRaw: String
        if let actionOpt {
            actionRaw = actionOpt
        } else if let first = positional.first {
            actionRaw = first
            positional.removeFirst()
        } else {
            throw CLIError(message: "workspace-action requires --action <name>")
        }

        if let unknown = positional.first(where: { $0.hasPrefix("--") }) {
            throw CLIError(message: "workspace-action: unknown flag '\(unknown)'")
        }

        let action = actionRaw.lowercased().replacingOccurrences(of: "-", with: "_")
        let workspaceArg = workspaceOpt ?? (windowOverride == nil ? ProcessInfo.processInfo.environment["PROGRAMA_WORKSPACE_ID"] : nil)
        let workspaceId = try normalizeWorkspaceHandle(workspaceArg, client: client, allowCurrent: true)

        let inferredPositionalRaw = positional.joined(separator: " ")
        let inferredPositional = inferredPositionalRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (titleOpt ?? (action == "rename" && !inferredPositional.isEmpty ? inferredPositional : nil))?.trimmingCharacters(in: .whitespacesAndNewlines)

        if action == "rename", (title?.isEmpty ?? true) {
            throw CLIError(message: "workspace-action rename requires --title <text> (or a trailing title)")
        }

        let color = (
            colorOpt ?? (action == "set_color" ? (inferredPositional.isEmpty ? nil : inferredPositional) : nil)
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
        if action == "set_color", (color?.isEmpty ?? true) {
            throw CLIError(message: "workspace-action set-color requires --color <name|#hex> (or a trailing color)")
        }

        let description = (
            descriptionOpt ?? (action == "set_description" && !inferredPositional.isEmpty ? inferredPositionalRaw : nil)
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
        if action == "set_description", (description?.isEmpty ?? true) {
            throw CLIError(message: "workspace-action set-description requires --description <text> (or trailing text)")
        }

        var params: [String: Any] = ["action": action]
        if let workspaceId {
            params["workspace_id"] = workspaceId
        }
        if let title, !title.isEmpty {
            params["title"] = title
        }
        if let color, !color.isEmpty {
            params["color"] = color
        }
        if let description, !description.isEmpty {
            params["description"] = description
        }

        let payload = try client.sendV2(method: V2MethodNames.workspaceAction, params: params)
        var summaryParts = ["OK", "action=\(action)"]
        if let workspaceHandle = formatHandle(payload, kind: "workspace", idFormat: idFormat) {
            summaryParts.append("workspace=\(workspaceHandle)")
        }
        if let windowHandle = formatHandle(payload, kind: "window", idFormat: idFormat) {
            summaryParts.append("window=\(windowHandle)")
        }
        if let closed = payload["closed"] {
            summaryParts.append("closed=\(closed)")
        }
        if let index = payload["index"] {
            summaryParts.append("index=\(index)")
        }
        if let color = payload["color"] as? String {
            summaryParts.append("color=\(color)")
        }
        printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: summaryParts.joined(separator: " "))
    }

    // MARK: - Worktree commands (docs/plans/worktree-and-layouts.md)

    func runWorktreeCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        var positional = commandArgs
        guard let subcommandRaw = positional.first else {
            throw CLIError(message: "worktree requires a subcommand: create, open, remove, list")
        }
        positional.removeFirst()

        switch subcommandRaw.lowercased() {
        case "create":
            try runWorktreeCreate(args: positional, client: client, jsonOutput: jsonOutput, idFormat: idFormat)
        case "open":
            try runWorktreeOpen(args: positional, client: client, jsonOutput: jsonOutput, idFormat: idFormat)
        case "remove":
            try runWorktreeRemove(args: positional, client: client, jsonOutput: jsonOutput, idFormat: idFormat)
        case "list":
            try runWorktreeList(args: positional, client: client, jsonOutput: jsonOutput, idFormat: idFormat)
        default:
            throw CLIError(message: "worktree: unknown subcommand '\(subcommandRaw)' (expected create, open, remove, list)")
        }
    }

    private func runWorktreeCreate(
        args: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let (repoOpt, rem0) = parseOption(args, name: "--repo")
        let (baseOpt, rem1) = parseOption(rem0, name: "--base")
        let (pathOpt, rem2) = parseOption(rem1, name: "--path")
        let (layoutOpt, rem3) = parseOption(rem2, name: "--layout")
        let (issueOpt, rem4) = parseOption(rem3, name: "--from-issue")
        let (agentOpt, rem5) = parseOption(rem4, name: "--agent")
        let focus = hasFlag(rem5, name: "--focus")
        var positional = rem5.filter { $0 != "--focus" }

        let explicitBranch = positional.first.flatMap { $0.hasPrefix("--") ? nil : $0 }
        if explicitBranch != nil { positional.removeFirst() }
        if let unknown = positional.first(where: { $0.hasPrefix("--") }) {
            throw CLIError(message: "worktree create: unknown flag '\(unknown)'")
        }
        let issueNumber = try issueOpt.map(parseWorktreeIssueNumber)
        let agent = try agentOpt.map { try validateWorktreeIssueAgent($0, issueNumber: issueNumber) }
        guard explicitBranch != nil || issueNumber != nil else {
            throw CLIError(message: "worktree create requires <branch> (or --from-issue <number>)")
        }

        let repo = try resolveWorktreeRepoRoot(explicit: repoOpt)
        let issue = try issueNumber.map { try fetchGitHubIssue(number: $0, repo: repo) }
        let promptFile = try agent != nil ? issue.map(writeWorktreeIssuePromptFile) : nil
        guard let branch = explicitBranch ?? issue.map(worktreeIssueBranchName) else {
            throw CLIError(message: "worktree create requires <branch>")
        }

        var params: [String: Any] = ["repo": repo, "branch": branch]
        if let baseOpt { params["base"] = baseOpt }
        if let pathOpt { params["path"] = pathOpt }
        if let layoutOpt { params["layout"] = layoutOpt }
        if focus { params["focus"] = true }

        var payload = try client.sendV2(method: V2MethodNames.worktreeCreate, params: params)
        var summary = worktreeSummary(payload, idFormat: idFormat)
        if let issue {
            payload["issue"] = ["number": issue.number, "title": issue.title, "url": issue.url]
            summary += " issue=#\(issue.number)"
        }
        var agentError: String?
        if let agent, let issue, let promptFile {
            payload["agent"] = agent
            payload["prompt_file"] = promptFile
            summary += " prompt_file=\(promptFile)"
            do {
                guard let workspaceId = payload["workspace_id"] as? String else {
                    throw CLIError(message: "worktree.create did not return a workspace_id")
                }
                _ = try client.sendV2(method: V2MethodNames.surfaceSendText, params: [
                    "workspace_id": workspaceId,
                    "text": worktreeIssueAgentLaunchCommand(agent: agent, issueNumber: issue.number, promptFile: promptFile) + "\n"
                ])
                summary += " agent=\(agent)"
            } catch {
                let message = (error as? CLIError)?.message ?? "\(error)"
                agentError = message
                payload["agent_error"] = message
            }
        }
        printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: summary)
        if let agentError, let agent {
            // Not a throw: in --json mode the top-level handler would print a second JSON object to stdout.
            FileHandle.standardError.write(Data("Error: worktree create: the workspace was created, but starting \(agent) failed: \(agentError)\n".utf8))
            exit(1)
        }
    }

    private func runWorktreeOpen(
        args: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let (repoOpt, rem0) = parseOption(args, name: "--repo")
        let focus = hasFlag(rem0, name: "--focus")
        let all = hasFlag(rem0, name: "--all")
        var positional = rem0.filter { $0 != "--focus" && $0 != "--all" }

        if all {
            if focus {
                throw CLIError(message: "worktree open: --focus cannot be combined with --all")
            }
            if !positional.isEmpty {
                throw CLIError(message: "worktree open --all does not take a <path-or-branch> argument")
            }
            let repo = try resolveWorktreeRepoRoot(explicit: repoOpt)
            try runWorktreeOpenAll(repo: repo, client: client, jsonOutput: jsonOutput, idFormat: idFormat)
            return
        }

        guard let target = positional.first, !target.hasPrefix("--") else {
            throw CLIError(message: "worktree open requires <path-or-branch> (or --all)")
        }
        positional.removeFirst()
        if let unknown = positional.first(where: { $0.hasPrefix("--") }) {
            throw CLIError(message: "worktree open: unknown flag '\(unknown)'")
        }

        let repo = try resolveWorktreeRepoRoot(explicit: repoOpt)

        var params: [String: Any] = ["repo": repo]
        if target.hasPrefix("/") || target.hasPrefix("~") || target.hasPrefix(".") {
            params["path"] = target
        } else {
            params["branch"] = target
        }
        if focus { params["focus"] = true }

        let payload = try client.sendV2(method: V2MethodNames.worktreeOpen, params: params)
        printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: worktreeSummary(payload, idFormat: idFormat))
    }

    /// Opens every worktree of `repo` as a workspace, in one call. `worktree.open` is idempotent
    /// (a no-op for a worktree already open as a workspace), so this never duplicates workspaces
    /// on repeated runs, and it never focuses/selects -- same "no focus by default" policy as a
    /// single `worktree open`.
    private func runWorktreeOpenAll(
        repo: String,
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let listPayload = try client.sendV2(method: V2MethodNames.worktreeList, params: ["repo": repo])
        let worktrees = listPayload["worktrees"] as? [[String: Any]] ?? []

        var openedPayloads: [[String: Any]] = []
        for entry in worktrees {
            guard let path = entry["path"] as? String else { continue }
            let opened = try client.sendV2(method: V2MethodNames.worktreeOpen, params: ["repo": repo, "path": path])
            openedPayloads.append(opened)
        }

        if jsonOutput {
            print(jsonString(formatIDs(openedPayloads, mode: idFormat)))
            return
        }

        guard !openedPayloads.isEmpty else {
            print("No worktrees to open for \(repo)")
            return
        }
        for payload in openedPayloads {
            print(worktreeSummary(payload, idFormat: idFormat))
        }
    }

    private func runWorktreeRemove(
        args: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let (repoOpt, rem0) = parseOption(args, name: "--repo")
        let force = hasFlag(rem0, name: "--force")
        var positional = rem0.filter { $0 != "--force" }

        guard let target = positional.first, !target.hasPrefix("--") else {
            throw CLIError(message: "worktree remove requires <path-or-branch>")
        }
        positional.removeFirst()
        if let unknown = positional.first(where: { $0.hasPrefix("--") }) {
            throw CLIError(message: "worktree remove: unknown flag '\(unknown)'")
        }

        let repo = try resolveWorktreeRepoRoot(explicit: repoOpt)

        var params: [String: Any] = ["repo": repo]
        if target.hasPrefix("/") || target.hasPrefix("~") || target.hasPrefix(".") {
            params["path"] = target
        } else {
            params["branch"] = target
        }
        if force { params["force"] = true }

        let payload = try client.sendV2(method: V2MethodNames.worktreeRemove, params: params)
        var summaryParts = ["OK", "removed=\(payload["removed"] ?? false)"]
        if let closed = payload["closed_workspace_id"] {
            summaryParts.append("closed_workspace=\(closed)")
        }
        printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: summaryParts.joined(separator: " "))
    }

    private func runWorktreeList(
        args: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let (repoOpt, rem0) = parseOption(args, name: "--repo")
        if let unknown = rem0.first(where: { $0.hasPrefix("--") && $0 != "--json" }) {
            throw CLIError(message: "worktree list: unknown flag '\(unknown)'")
        }

        let repo = try resolveWorktreeRepoRoot(explicit: repoOpt)
        let payload = try client.sendV2(method: V2MethodNames.worktreeList, params: ["repo": repo])

        if jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
            return
        }

        let worktrees = payload["worktrees"] as? [[String: Any]] ?? []
        guard !worktrees.isEmpty else {
            print("No worktrees for \(repo)")
            return
        }
        for entry in worktrees {
            let path = entry["path"] as? String ?? "?"
            let branch = entry["branch"] as? String ?? "(detached)"
            let isOpen = (entry["is_open"] as? Bool) ?? false
            let openTag = isOpen ? " [open]" : ""
            print("\(path)  (branch \(branch))\(openTag)")
        }
    }

    private func worktreeSummary(_ payload: [String: Any], idFormat: CLIIDFormat) -> String {
        let worktree = payload["worktree"] as? [String: Any] ?? [:]
        let path = worktree["path"] as? String ?? "?"
        let branch = worktree["branch"] as? String ?? "?"
        let workspaceHandle = formatHandle(payload, kind: "workspace", idFormat: idFormat) ?? "unknown"
        return "OK worktree workspace=\(workspaceHandle) path=\(path) branch=\(branch)"
    }

    /// Resolves the repo to operate on: `explicit` (an arbitrary directory inside the repo,
    /// not necessarily its toplevel) if given, else the CLI process's own current directory --
    /// this is a shell-invoked CLI, so its cwd is the natural "caller's directory" default,
    /// distinct from any currently-selected workspace's cwd.
    private func resolveWorktreeRepoRoot(explicit: String?) throws -> String {
        let directory = ((explicit ?? FileManager.default.currentDirectoryPath) as NSString).expandingTildeInPath
        guard let root = gitTopLevelDirectory(at: directory) else {
            throw CLIError(message: "not_a_git_repo: '\(directory)' is not inside a git repository")
        }
        return root
    }

    /// Every branch name already present in `repo` that looks like `<prefix>/<number>`, as the
    /// set of those trailing numbers. Used by `race` to pick a starting index that does not
    /// collide, so racing twice in a row works instead of failing on every index.
    ///
    /// Returns an empty set when git fails for any reason -- a listing failure should degrade
    /// to "start at 1 and let worktree.create report the real collision", not abort the run.
    private func existingRaceIndexes(repo: String, prefix: String) -> Set<Int> {
        let result = CLIProcessRunner.runProcess(
            executablePath: "/usr/bin/env",
            arguments: [
                "git", "-C", repo, "for-each-ref", "--format=%(refname:short)", "refs/heads/\(prefix)/"
            ]
        )
        guard result.status == 0 else { return [] }

        var indexes: Set<Int> = []
        for line in result.stdout.split(separator: "\n") {
            let name = line.trimmingCharacters(in: .whitespaces)
            // Only `<prefix>/<number>` counts. `race/my-thing` or `race/1/nested` are somebody
            // else's branches and must not shift our numbering.
            guard name.hasPrefix("\(prefix)/") else { continue }
            let tail = String(name.dropFirst(prefix.count + 1))
            guard let value = Int(tail), value > 0 else { continue }
            indexes.insert(value)
        }
        return indexes
    }

    private func gitTopLevelDirectory(at directory: String) -> String? {
        let result = CLIProcessRunner.runProcess(
            executablePath: "/usr/bin/env",
            arguments: ["git", "-C", directory, "rev-parse", "--show-toplevel"]
        )
        guard result.status == 0 else { return nil }
        let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Race command (fan one prompt across N agents in isolated worktrees, spawn only)

    /// The only agents `race` supports: the three that report state via lifecycle hooks
    /// (Claude Code, OpenCode, Codex). Racing needs a trustworthy idle signal, which
    /// screen-pattern detection (used for Gemini CLI/Copilot/Cursor Agent/Aider) cannot
    /// provide, so those are deliberately excluded here even though they're supported
    /// elsewhere in the app for status badges.
    static let raceSupportedAgents: [String] = ["claude", "opencode", "codex"]

    /// Builds the shell command line that starts an agent on `prompt`. OpenCode reads a bare argument as a project path.
    func raceAgentLaunchCommand(agent: String, prompt: String) -> String {
        "\(agent) \(agent == "opencode" ? "--prompt " : "")\(shellSingleQuote(prompt))"
    }

    /// Shell-quotes arbitrary text for safe inclusion in a POSIX shell command line typed into
    /// a terminal via `surface.send_text`. Wraps in single quotes and escapes embedded single
    /// quotes as '\'' (close quote, literal escaped quote, reopen quote) -- the standard
    /// technique, safe against every other shell metacharacter (double quotes, backticks, $,
    /// *, newlines, etc.) since nothing but a literal `'` is special inside single quotes.
    func shellSingleQuote(_ raw: String) -> String {
        "'" + raw.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    func runRaceCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let (nOpt, rem0) = parseOption(commandArgs, name: "--n")
        let (agentOpt, rem1) = parseOption(rem0, name: "--agent")
        let (baseOpt, rem2) = parseOption(rem1, name: "--base")
        let (prefixOpt, rem3) = parseOption(rem2, name: "--prefix")
        let (layoutOpt, rem4) = parseOption(rem3, name: "--layout")

        var positional = rem4
        if positional.first == "--" {
            positional.removeFirst()
        }
        if let unknown = positional.first(where: { $0.hasPrefix("--") }) {
            throw CLIError(message: "race: unknown flag '\(unknown)'")
        }

        let prompt = positional.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            throw CLIError(message: "race requires a <prompt>")
        }

        let n: Int
        if let nOpt {
            guard let parsed = Int(nOpt), parsed >= 1, parsed <= 8 else {
                throw CLIError(message: "race: --n must be between 1 and 8")
            }
            n = parsed
        } else {
            n = 3
        }

        let agent = (agentOpt ?? "claude").lowercased()
        guard Self.raceSupportedAgents.contains(agent) else {
            throw CLIError(message: "race: --agent must be one of claude, opencode, codex")
        }

        let prefix = prefixOpt ?? "race"

        // Fail immediately, before creating anything, if the cwd isn't inside a git repo.
        let repo = try resolveWorktreeRepoRoot(explicit: nil)

        // Start after whatever `<prefix>/<number>` branches already exist so repeated runs
        // continue the numbering instead of colliding.
        let taken = existingRaceIndexes(repo: repo, prefix: prefix)
        let firstIndex = (taken.max() ?? 0) + 1
        let indexes = Array(firstIndex..<(firstIndex + n))

        var succeededCount = 0
        var failedIndexes: [Int] = []

        for index in indexes {
            let branch = "\(prefix)/\(index)"
            do {
                var params: [String: Any] = ["repo": repo, "branch": branch]
                if let baseOpt { params["base"] = baseOpt }
                if let layoutOpt { params["layout"] = layoutOpt }
                // Deliberately no "focus" key: worktree.create defaults focus to false, and
                // `race` is not a focus-intent command per the socket focus policy in
                // CLAUDE.md, so every worktree after the first (and the first) stays
                // unfocused -- the user's current focus is never stolen.

                let payload = try client.sendV2(method: V2MethodNames.worktreeCreate, params: params)
                guard let workspaceId = payload["workspace_id"] as? String else {
                    throw CLIError(message: "worktree.create did not return a workspace_id")
                }
                let workspaceRef = formatHandle(payload, kind: "workspace", idFormat: idFormat) ?? workspaceId

                let launchCommand = raceAgentLaunchCommand(agent: agent, prompt: prompt)
                _ = try client.sendV2(method: V2MethodNames.surfaceSendText, params: [
                    "workspace_id": workspaceId,
                    "text": launchCommand + "\n"
                ])

                succeededCount += 1
                print("[\(index)] branch=\(branch) workspace=\(workspaceRef)")
            } catch {
                failedIndexes.append(index)
                let message = (error as? CLIError)?.message ?? "\(error)"
                print("[\(index)] branch=\(branch) FAILED: \(message)")
            }
        }

        print("")
        if failedIndexes.isEmpty {
            let range = n == 1
                ? "\(prefix)/\(firstIndex)"
                : "\(prefix)/\(firstIndex)..\(prefix)/\(firstIndex + n - 1)"
            print("race: started \(succeededCount)/\(n) agents on branches \(range). Watch with: programa list-workspaces (or check each workspace's status badge in the sidebar).")
        } else {
            let failedList = failedIndexes.map(String.init).joined(separator: ", ")
            print("race: started \(succeededCount)/\(n) agents; failed indexes: \(failedList). Watch the succeeded ones with: programa list-workspaces")
            throw CLIError(message: "race: \(failedIndexes.count) of \(n) agent(s) failed to start")
        }
    }

    // MARK: - Layout commands (docs/plans/worktree-and-layouts.md)

    func runLayoutCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        var positional = commandArgs
        guard let subcommandRaw = positional.first else {
            throw CLIError(message: "layout requires a subcommand: save, apply, list")
        }
        positional.removeFirst()

        switch subcommandRaw.lowercased() {
        case "save":
            try runLayoutSave(args: positional, client: client, jsonOutput: jsonOutput, idFormat: idFormat)
        case "apply":
            try runLayoutApply(args: positional, client: client, jsonOutput: jsonOutput, idFormat: idFormat)
        case "list":
            try runLayoutList(args: positional, client: client, jsonOutput: jsonOutput, idFormat: idFormat)
        default:
            throw CLIError(message: "layout: unknown subcommand '\(subcommandRaw)' (expected save, apply, list)")
        }
    }

    private func runLayoutSave(
        args: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let force = hasFlag(args, name: "--force")
        var positional = args.filter { $0 != "--force" }

        guard let name = positional.first, !name.hasPrefix("--") else {
            throw CLIError(message: "layout save requires <name>")
        }
        positional.removeFirst()
        if let unknown = positional.first(where: { $0.hasPrefix("--") }) {
            throw CLIError(message: "layout save: unknown flag '\(unknown)'")
        }

        var params: [String: Any] = ["name": name]
        if force { params["force"] = true }

        let payload = try client.sendV2(method: V2MethodNames.layoutSave, params: params)
        let path = payload["path"] as? String ?? "?"
        printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: "OK layout=\(name) path=\(path)")
    }

    private func runLayoutApply(
        args: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let (workspaceOpt, rem0) = parseOption(args, name: "--workspace")
        let (cwdOpt, rem1) = parseOption(rem0, name: "--cwd")
        var positional = rem1

        guard let name = positional.first, !name.hasPrefix("--") else {
            throw CLIError(message: "layout apply requires <name>")
        }
        positional.removeFirst()
        if let unknown = positional.first(where: { $0.hasPrefix("--") }) {
            throw CLIError(message: "layout apply: unknown flag '\(unknown)'")
        }

        var params: [String: Any] = ["name": name]
        if let workspaceOpt {
            guard let workspaceId = try normalizeWorkspaceHandle(workspaceOpt, client: client) else {
                throw CLIError(message: "layout apply: could not resolve --workspace '\(workspaceOpt)'")
            }
            params["workspace_id"] = workspaceId
        }
        // Help text promises cwd = --cwd or the current directory, so fall back explicitly;
        // otherwise the app applies its own new-tab heuristic.
        params["cwd"] = cwdOpt ?? FileManager.default.currentDirectoryPath

        let payload = try client.sendV2(method: V2MethodNames.layoutApply, params: params)
        let workspaceHandle = formatHandle(payload, kind: "workspace", idFormat: idFormat) ?? "unknown"
        printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: "OK layout=\(name) workspace=\(workspaceHandle)")
    }

    private func runLayoutList(
        args: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        if let unknown = args.first(where: { $0.hasPrefix("--") && $0 != "--json" }) {
            throw CLIError(message: "layout list: unknown flag '\(unknown)'")
        }

        let payload = try client.sendV2(method: V2MethodNames.layoutList, params: [:])
        if jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
            return
        }

        let layouts = payload["layouts"] as? [[String: Any]] ?? []
        guard !layouts.isEmpty else {
            print("No saved layouts")
            return
        }
        for entry in layouts {
            let name = entry["name"] as? String ?? "?"
            let savedAt = entry["saved_at"] as? String ?? ""
            print(savedAt.isEmpty ? name : "\(name)  (saved \(savedAt))")
        }
    }

    // MARK: - Snapshot history commands (docs/plans/snapshot-restore.md)

    func runSnapshotCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        var positional = commandArgs
        guard let subcommandRaw = positional.first else {
            throw CLIError(message: "snapshot requires a subcommand: list, restore")
        }
        positional.removeFirst()

        switch subcommandRaw.lowercased() {
        case "list":
            try runSnapshotList(args: positional, client: client, jsonOutput: jsonOutput, idFormat: idFormat)
        case "restore":
            try runSnapshotRestore(args: positional, client: client, jsonOutput: jsonOutput, idFormat: idFormat)
        default:
            throw CLIError(message: "snapshot: unknown subcommand '\(subcommandRaw)' (expected list, restore)")
        }
    }

    private func runSnapshotList(
        args: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        if let unknown = args.first(where: { $0.hasPrefix("--") && $0 != "--json" }) {
            throw CLIError(message: "snapshot list: unknown flag '\(unknown)'")
        }

        let payload = try client.sendV2(method: V2MethodNames.snapshotList, params: [:])
        if jsonOutput || args.contains("--json") {
            print(jsonString(formatIDs(payload, mode: idFormat)))
            return
        }

        let snapshots = payload["snapshots"] as? [[String: Any]] ?? []
        guard !snapshots.isEmpty else {
            print("No archived snapshots")
            return
        }
        for entry in snapshots {
            let id = entry["id"] as? String ?? "?"
            let savedAt = entry["saved_at"] as? String ?? ""
            let cleanShutdown = entry["clean_shutdown"] as? Bool
            let cleanTag = cleanShutdown == true ? "clean" : (cleanShutdown == false ? "unclean" : "unknown")
            let windowCount = intFromAny(entry["window_count"]) ?? 0
            let workspaceCount = intFromAny(entry["workspace_count"]) ?? 0
            let panelCount = intFromAny(entry["panel_count"]) ?? 0
            print("\(id)  \(savedAt)  \(cleanTag)  windows=\(windowCount) workspaces=\(workspaceCount) panels=\(panelCount)")
        }
    }

    private func runSnapshotRestore(
        args: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        var positional = args
        if let unknown = positional.first(where: { $0.hasPrefix("--") }) {
            throw CLIError(message: "snapshot restore: unknown flag '\(unknown)'")
        }

        var params: [String: Any] = [:]
        if let target = positional.first {
            positional.removeFirst()
            if !positional.isEmpty {
                throw CLIError(message: "snapshot restore takes at most one argument: <id>|latest")
            }
            if target.lowercased() != "latest" {
                params["id"] = target
            }
        }

        let payload = try client.sendV2(method: V2MethodNames.snapshotRestore, params: params)
        let restored = payload["restored"] as? [String: Any] ?? [:]
        let windows = intFromAny(restored["windows"]) ?? 0
        let workspaces = intFromAny(restored["workspaces"]) ?? 0
        let panels = intFromAny(restored["panels"]) ?? 0
        printV2Payload(
            payload,
            jsonOutput: jsonOutput,
            idFormat: idFormat,
            fallbackText: "OK restored windows=\(windows) workspaces=\(workspaces) panels=\(panels)"
        )
    }

    func runTabAction(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        let (workspaceOpt, rem0) = parseOption(commandArgs, name: "--workspace")
        let (tabOpt, rem1) = parseOption(rem0, name: "--tab")
        let (surfaceOpt, rem2) = parseOption(rem1, name: "--surface")
        let (actionOpt, rem3) = parseOption(rem2, name: "--action")
        let (titleOpt, rem4) = parseOption(rem3, name: "--title")
        var positional = rem4
        let actionRaw: String
        if let actionOpt {
            actionRaw = actionOpt
        } else if let first = positional.first {
            actionRaw = first
            positional.removeFirst()
        } else {
            throw CLIError(message: "tab-action requires --action <name>")
        }

        if let unknown = positional.first(where: { $0.hasPrefix("--") }) {
            throw CLIError(message: "tab-action: unknown flag '\(unknown)'")
        }

        let action = actionRaw.lowercased().replacingOccurrences(of: "-", with: "_")
        let workspaceArg = workspaceOpt ?? (windowOverride == nil ? ProcessInfo.processInfo.environment["PROGRAMA_WORKSPACE_ID"] : nil)
        let tabArg = tabOpt
            ?? surfaceOpt
            ?? (workspaceOpt == nil && windowOverride == nil
                ? (ProcessInfo.processInfo.environment["PROGRAMA_TAB_ID"] ?? ProcessInfo.processInfo.environment["PROGRAMA_SURFACE_ID"])
                : nil)

        let workspaceId = try normalizeWorkspaceHandle(workspaceArg, client: client, allowCurrent: true)
        // If a workspace is explicitly targeted and no tab/surface is provided, let server-side
        // tab.action resolve that workspace's focused tab instead of using global focus.
        let allowFocusedFallback = (workspaceId == nil)
        let surfaceId = try normalizeTabHandle(
            tabArg,
            client: client,
            workspaceHandle: workspaceId,
            allowFocused: allowFocusedFallback
        )

        let inferredTitle = positional.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (titleOpt ?? (inferredTitle.isEmpty ? nil : inferredTitle))?.trimmingCharacters(in: .whitespacesAndNewlines)

        if action == "rename", (title?.isEmpty ?? true) {
            throw CLIError(message: "tab-action rename requires --title <text> (or a trailing title)")
        }

        var params: [String: Any] = ["action": action]
        if let workspaceId {
            params["workspace_id"] = workspaceId
        }
        if let surfaceId {
            params["surface_id"] = surfaceId
        }
        if let title, !title.isEmpty {
            params["title"] = title
        }

        let payload = try client.sendV2(method: V2MethodNames.tabAction, params: params)
        var summaryParts = ["OK", "action=\(action)"]
        if let tabHandle = formatTabHandle(payload, idFormat: idFormat) {
            summaryParts.append("tab=\(tabHandle)")
        }
        if let workspaceHandle = formatHandle(payload, kind: "workspace", idFormat: idFormat) {
            summaryParts.append("workspace=\(workspaceHandle)")
        }
        if let closed = payload["closed"] {
            summaryParts.append("closed=\(closed)")
        }
        if let created = formatCreatedTabHandle(payload, idFormat: idFormat) {
            summaryParts.append("created=\(created)")
        }
        printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: summaryParts.joined(separator: " "))
    }

    func runRenameTab(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        let (workspaceOpt, rem0) = parseOption(commandArgs, name: "--workspace")
        let (tabOpt, rem1) = parseOption(rem0, name: "--tab")
        let (surfaceOpt, rem2) = parseOption(rem1, name: "--surface")
        let (titleOpt, rem3) = parseOption(rem2, name: "--title")

        if rem3.contains("--action") {
            throw CLIError(message: "rename-tab does not accept --action (it always performs rename)")
        }
        if let unknown = rem3.first(where: { $0.hasPrefix("--") && $0 != "--" }) {
            throw CLIError(message: "rename-tab: unknown flag '\(unknown)'")
        }

        let inferredTitle = rem3
            .dropFirst(rem3.first == "--" ? 1 : 0)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (titleOpt ?? (inferredTitle.isEmpty ? nil : inferredTitle))?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let title, !title.isEmpty else {
            throw CLIError(message: "rename-tab requires a title")
        }

        var forwarded: [String] = ["--action", "rename", "--title", title]
        if let workspaceOpt {
            forwarded += ["--workspace", workspaceOpt]
        }
        if let tabOpt {
            forwarded += ["--tab", tabOpt]
        } else if let surfaceOpt {
            forwarded += ["--surface", surfaceOpt]
        }

        try runTabAction(
            commandArgs: forwarded,
            client: client,
            jsonOutput: jsonOutput,
            idFormat: idFormat,
            windowOverride: windowOverride
        )
    }
    func resolveWorkspaceId(_ raw: String?, client: SocketClient) throws -> String {
        if let raw, isUUID(raw) {
            return raw
        }
        if let raw, isHandleRef(raw) {
            // Resolve ref to UUID — search across all windows
            let windows = try client.sendV2(method: V2MethodNames.windowList)
            let windowList = windows["windows"] as? [[String: Any]] ?? []
            for window in windowList {
                guard let windowId = window["id"] as? String else { continue }
                let listed = try client.sendV2(method: V2MethodNames.workspaceList, params: ["window_id": windowId])
                let items = listed["workspaces"] as? [[String: Any]] ?? []
                for item in items where (item["ref"] as? String) == raw {
                    if let id = item["id"] as? String { return id }
                }
            }
            throw CLIError(message: "not_found: Workspace ref not found: \(raw)")
        }

        if let raw, Int(raw) != nil {
            throw CLIError(message: "workspace: bare indexes are no longer accepted; use a UUID or short ref like workspace:2 (see list-workspaces)")
        }

        let current = try client.sendV2(method: V2MethodNames.workspaceCurrent)
        if let wsId = current["workspace_id"] as? String { return wsId }
        throw CLIError(message: "No workspace selected")
    }

    func resolveSurfaceId(_ raw: String?, workspaceId: String, client: SocketClient) throws -> String {
        if let raw, isUUID(raw) {
            return raw
        }
        if let raw, isHandleRef(raw) {
            let listed = try client.sendV2(method: V2MethodNames.surfaceList, params: ["workspace_id": workspaceId])
            let items = listed["surfaces"] as? [[String: Any]] ?? []
            for item in items where (item["ref"] as? String) == raw {
                if let id = item["id"] as? String { return id }
            }
            throw CLIError(message: "not_found: Surface ref not found: \(raw)")
        }

        if let raw, Int(raw) != nil {
            throw CLIError(message: "surface: bare indexes are no longer accepted; use a UUID or short ref like surface:2 (see list-pane-surfaces)")
        }

        let listed = try client.sendV2(method: V2MethodNames.surfaceList, params: ["workspace_id": workspaceId])
        let items = listed["surfaces"] as? [[String: Any]] ?? []

        if let focused = items.first(where: { ($0["focused"] as? Bool) == true }) {
            if let id = focused["id"] as? String { return id }
        }

        throw CLIError(message: "Unable to resolve surface ID")
    }

    /// Return the help/usage text for a subcommand, or nil if the command is unknown.
    private func subcommandUsage(_ command: String) -> String? {
        if let text = tmuxCompatSubcommandUsage(command) { return text }
        if let text = treeSubcommandUsage(command) { return text }
        if let text = hooksSubcommandUsage(command) { return text }
        if let text = markdownSubcommandUsage(command) { return text }
        if let text = reviewSubcommandUsage(command) { return text }
        if let text = recapSubcommandUsage(command) { return text }
        if let text = themesSubcommandUsage(command) { return text }
        if let text = agentWrapperSubcommandUsage(command) { return text }
        return commandDescriptor(named: command)?.detailedUsage
    }

    /// Dispatch help for a subcommand. Returns true if help was printed.
    func dispatchSubcommandHelp(command: String, commandArgs: [String]) -> Bool {
        guard commandArgs.contains("--help") || commandArgs.contains("-h") else { return false }
        guard let text = subcommandUsage(command) else { return false }
        print("programa \(command)")
        print("")
        print(text)
        return true
    }

    /// Unescape CLI escape sequences for send behavior.
    /// \n and \r → carriage return (Enter), \t → tab.
    func unescapeSendText(_ text: String) -> String {
        return text
            .replacingOccurrences(of: "\\n", with: "\r")
            .replacingOccurrences(of: "\\r", with: "\r")
            .replacingOccurrences(of: "\\t", with: "\t")
    }

    func workspaceFromArgsOrEnv(_ args: [String], windowOverride: String? = nil) -> String? {
        if let explicit = optionValue(args, name: "--workspace") { return explicit }
        // When --window is explicitly targeted, don't fall back to env workspace from a different window
        if windowOverride != nil { return nil }
        return ProcessInfo.processInfo.environment["PROGRAMA_WORKSPACE_ID"]
    }

    /// Validates a `.registered` command from its descriptor grammar. A command
    /// with neither a grammar nor a switch arm fails closed before socket
    /// acquisition until its grammar is declared.
    private func validateRegisteredArguments(_ args: [String], for command: String) throws {
        func parse(
            values: Set<String> = [],
            booleans: Set<String> = [],
            shortFlags: Set<String> = [],
            minPositionals: Int = 0,
            maxPositionals: Int? = 0, repeatableValues: Set<String> = []
        ) throws -> (positional: [String], options: [String: String]) {
            // Unbounded positionals are free text (`send`, `log`), where `-x` is a word.
            let parsed = try preflightFlagArguments(
                args,
                command: command,
                valueFlags: values,
                booleanFlags: booleans,
                repeatableValueFlags: repeatableValues,
                shortFlags: shortFlags,
                rejectOptionLikePositionals: maxPositionals != nil
            )
            guard parsed.positional.count >= minPositionals else {
                throw CLIError(message: "\(command): missing required argument")
            }
            if let maxPositionals, parsed.positional.count > maxPositionals {
                throw CLIError(message: "\(command): unexpected arguments: \(parsed.positional.dropFirst(maxPositionals).joined(separator: " "))")
            }
            return parsed
        }

        func require(_ names: [String], in options: [String: String]) throws {
            for name in names where options[name] == nil {
                throw CLIError(message: "\(command): --\(name) is required")
            }
        }

        // Descriptor grammars and the switch share validation and error messages.
        if let grammar = commandDescriptor(named: command)?.grammar {
            let parsed = try parse(
                values: grammar.valueOptions,
                booleans: grammar.booleanOptions,
                shortFlags: grammar.shortFlags,
                minPositionals: grammar.minPositionals,
                maxPositionals: grammar.maxPositionals, repeatableValues: grammar.repeatableValueOptions
            )
            try require(grammar.requiredOptions, in: parsed.options)
            try grammar.validate?(command, parsed)
            return
        }

        // Descriptors declared outside CLI/Commands/ (tree, agent hooks, tmux
        // compatibility) still carry their semantic checks here.
        switch command {
        case "tree":
            _ = try parse(values: ["workspace"], booleans: ["all"])
        case "claude-hook":
            let parsed = try parse(values: ["workspace", "surface"], maxPositionals: 1)
            if let subcommand = parsed.positional.first?.lowercased(),
               !["session-start", "active", "stop", "idle", "prompt-submit", "notification", "notify", "session-end", "pre-tool-use", "subagent-start", "subagent-stop", "help", "--help", "-h"].contains(subcommand) {
                throw CLIError(message: "claude-hook: unknown event \(subcommand)")
            }
        case "codex-hook":
            guard ProcessInfo.processInfo.environment["PROGRAMA_SURFACE_ID"] != nil else { return }
            let parsed = try parse(values: ["workspace", "surface"], maxPositionals: 1)
            if let subcommand = parsed.positional.first?.lowercased(),
               !["session-start", "prompt-submit", "stop", "notification", "notify", "session-end", "help", "--help", "-h"].contains(subcommand) {
                throw CLIError(message: "codex-hook: unknown event \(subcommand)")
            }
        case "opencode-hook":
            guard ProcessInfo.processInfo.environment["PROGRAMA_SURFACE_ID"] != nil else { return }
            let parsed = try parse(values: ["workspace", "surface", "cwd", "session"], maxPositionals: 1)
            if let subcommand = parsed.positional.first?.lowercased(),
               !["session-start", "prompt-submit", "stop", "notification", "notify", "session-end", "help", "--help", "-h"].contains(subcommand) {
                throw CLIError(message: "opencode-hook: unknown event \(subcommand)")
            }
        case "capture-pane":
            let parsed = try parse(values: ["workspace", "surface", "lines"], booleans: ["scrollback"])
            if let lines = parsed.options["lines"], (Int(lines) ?? 0) <= 0 {
                throw CLIError(message: "capture-pane: --lines must be greater than 0")
            }
        case "resize-pane":
            let parsed = try parse(values: ["pane", "workspace", "amount"], shortFlags: ["-L", "-R", "-U", "-D"], minPositionals: 1, maxPositionals: 1)
            try require(["pane"], in: parsed.options)
            guard ["-L", "-R", "-U", "-D"].contains(parsed.positional[0]) else {
                throw CLIError(message: "resize-pane requires -L, -R, -U, or -D")
            }
            if let amount = parsed.options["amount"], (Int(amount) ?? 0) <= 0 {
                throw CLIError(message: "resize-pane: --amount must be greater than 0")
            }
        case "pipe-pane":
            let parsed = try parse(values: ["command", "workspace", "surface"], maxPositionals: nil)
            guard parsed.options["command"] != nil || !parsed.positional.isEmpty else {
                throw CLIError(message: "pipe-pane requires --command <shell-command>")
            }
        case "wait-for":
            let parsed = try parse(values: ["timeout"], booleans: ["signal"], shortFlags: ["-S"], minPositionals: 1, maxPositionals: 2)
            let positionals = parsed.positional.filter { $0 != "-S" }
            guard positionals.count == 1 else { throw CLIError(message: "wait-for requires one name") }
            if let timeout = parsed.options["timeout"] {
                guard let seconds = Double(timeout), seconds.isFinite, seconds >= 0 else {
                    throw CLIError(message: "wait-for: --timeout must be finite and nonnegative")
                }
            }
        case "set-hook":
            let parsed = try parse(values: ["unset"], booleans: ["list"], maxPositionals: nil)
            if parsed.options["list"] == nil, parsed.options["unset"] == nil, parsed.positional.count < 2 {
                throw CLIError(message: "set-hook requires <event> <command>")
            }
        case "display-message":
            let parsed = try parse(booleans: ["print"], minPositionals: 1, maxPositionals: nil)
            guard parsed.positional.filter({ $0 != "-p" }).isEmpty == false else {
                throw CLIError(message: "display-message requires text")
            }
        default:
            throw CLIError(message: "Internal CLI registry error: no argument contract for \(command)")
        }
    }

    func validateArguments(
        _ args: [String],
        for command: String,
        contract: CLICommandArgumentContract
    ) throws {
        switch contract {
        case .registered:
            try validateRegisteredArguments(args, for: command)

        case .handlerParsed:
            return

        case .noArguments:
            guard args.isEmpty else {
                throw CLIError(message: "\(command): unexpected arguments: \(args.joined(separator: " "))")
            }

        case .focusPanel:
            let parsed = try preflightFlagArguments(
                args,
                command: command,
                valueFlags: ["panel", "workspace"]
            )
            guard parsed.positional.isEmpty else {
                throw CLIError(message: "focus-panel: unexpected arguments: \(parsed.positional.joined(separator: " "))")
            }
            guard parsed.options["panel"] != nil else {
                throw CLIError(message: "focus-panel requires --panel <id|ref>")
            }

        case .readScreen:
            let parsed = try preflightFlagArguments(
                args,
                command: command,
                valueFlags: ["workspace", "surface", "lines"],
                booleanFlags: ["scrollback"]
            )
            guard parsed.positional.isEmpty else {
                throw CLIError(message: "read-screen: unexpected arguments: \(parsed.positional.joined(separator: " "))")
            }
            if let lines = parsed.options["lines"] {
                guard let count = Int(lines), count > 0 else {
                    throw CLIError(message: "read-screen: --lines must be greater than 0")
                }
            }

        case .waitSurface:
            let parsed = try preflightFlagArguments(
                args,
                command: command,
                valueFlags: ["workspace", "surface", "pattern", "timeout", "lines", "agent-state"],
                booleanFlags: ["exit"]
            )
            guard parsed.positional.isEmpty else {
                throw CLIError(message: "wait-surface: unexpected arguments: \(parsed.positional.joined(separator: " "))")
            }
            guard ["pattern", "exit", "agent-state"].filter({ parsed.options[$0] != nil }).count == 1 else {
                throw CLIError(message: "wait-surface requires exactly one of --pattern <regex>, --exit, or --agent-state <idle|working|blocked|any_change>")
            }
            if let state = parsed.options["agent-state"], !["idle", "working", "blocked", "any_change"].contains(state) {
                throw CLIError(message: "wait-surface: --agent-state must be one of idle, working, blocked, any_change")
            }
            if let timeout = parsed.options["timeout"] {
                guard let seconds = Double(timeout), seconds.isFinite, seconds > 0 else {
                    throw CLIError(message: "wait-surface: --timeout must be a positive number of seconds")
                }
            }
            if let lines = parsed.options["lines"] {
                guard let count = Int(lines), count > 0 else {
                    throw CLIError(message: "wait-surface: --lines must be greater than 0")
                }
            }

        case .watchEvents:
            let parsed = try preflightFlagArguments(
                args,
                command: command,
                valueFlags: ["output"],
                booleanFlags: ["agent-state", "workspace-lifecycle", "needs-input", "no-reconnect"]
            )
            guard parsed.positional.isEmpty else {
                throw CLIError(message: "watch-events: unexpected arguments: \(parsed.positional.joined(separator: " "))")
            }
            guard parsed.options["agent-state"] != nil
                || parsed.options["workspace-lifecycle"] != nil
                || parsed.options["needs-input"] != nil
                || parsed.options["output"] != nil else {
                throw CLIError(
                    message: "watch-events requires at least one of --agent-state, --workspace-lifecycle, --needs-input, --output <surface_id[,surface_id...]>"
                )
            }

        case .setProgress:
            let parsed = try preflightFlagArguments(
                args,
                command: command,
                valueFlags: ["label", "workspace"]
            )
            guard parsed.positional.count == 1, let rawValue = parsed.positional.first else {
                throw CLIError(message: "set-progress requires a progress value")
            }
            guard let value = Double(rawValue), value.isFinite, (0.0...1.0).contains(value) else {
                throw CLIError(message: "set-progress: invalid progress value '\(rawValue)'; must be between 0.0 and 1.0")
            }

        case .listLog:
            let parsed = try preflightFlagArguments(
                args,
                command: command,
                valueFlags: ["limit", "workspace"]
            )
            guard parsed.positional.isEmpty else {
                throw CLIError(message: "list-log: unexpected arguments: \(parsed.positional.joined(separator: " "))")
            }
            if let rawLimit = parsed.options["limit"] {
                guard let limit = Int(rawLimit), limit >= 0 else {
                    throw CLIError(message: "list-log: invalid limit '\(rawLimit)'; must be >= 0")
                }
            }
        }
    }

    func normalizedFlagValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Resolves the target workspace for a sidebar-metadata command: explicit `--workspace`
    /// flag, else `$PROGRAMA_WORKSPACE_ID` (unless a `--window` override is active), else the
    /// server's currently-selected workspace (mirrors v1's `resolveTabForReport`/
    /// `parseSidebarMutationTabTarget` fallback to `tabManager.selectedTabId`).
    func resolveSidebarWorkspaceId(
        options: [String: String],
        windowOverride: String?,
        client: SocketClient
    ) throws -> String {
        let raw = options["workspace"] ?? (windowOverride == nil ? ProcessInfo.processInfo.environment["PROGRAMA_WORKSPACE_ID"] : nil)
        return try resolveWorkspaceId(raw, client: client)
    }

    /// Rebuilds v1's `key=value icon=X color=Y url=Z priority=N format=X` status-entry line
    /// from a `workspace.set_status`/`list_status`/`sidebar_state` v2 entry dict.
    func sidebarMetadataLineText(_ entry: [String: Any]) -> String {
        let key = (entry["key"] as? String) ?? ""
        let value = (entry["value"] as? String) ?? ""
        var line = "\(key)=\(value)"
        if let icon = entry["icon"] as? String { line += " icon=\(icon)" }
        if let color = entry["color"] as? String { line += " color=\(color)" }
        if let url = entry["url"] as? String { line += " url=\(url)" }
        if let priority = intFromAny(entry["priority"]), priority != 0 { line += " priority=\(priority)" }
        if let format = entry["format"] as? String, format != "plain" { line += " format=\(format)" }
        return line
    }

    /// Rebuilds v1's `key=markdown priority=N` metadata-block line from a `sidebar_state`
    /// v2 `metadata_blocks` entry dict.
    private func sidebarMetadataBlockLineText(_ block: [String: Any]) -> String {
        let key = (block["key"] as? String) ?? ""
        let markdown = ((block["markdown"] as? String) ?? "").replacingOccurrences(of: "\n", with: "\\n")
        var line = "\(key)=\(markdown)"
        if let priority = intFromAny(block["priority"]), priority != 0 { line += " priority=\(priority)" }
        return line
    }

    /// Rebuilds v1's `[level] message` (optionally `[source] [level] message`) log line from
    /// a `workspace.list_log` v2 entry dict.
    func sidebarLogLineText(_ entry: [String: Any]) -> String {
        let level = (entry["level"] as? String) ?? "info"
        let message = (entry["message"] as? String) ?? ""
        var line = "[\(level)] \(message)"
        if let source = entry["source"] as? String, !source.isEmpty {
            line = "[\(source)] \(line)"
        }
        return line
    }

    /// Rebuilds v1's `sidebar_state` multi-line text dump from a `workspace.sidebar_state`
    /// v2 payload. Field-for-field mirror of `TerminalController.sidebarState(_:)`.
    func sidebarStateText(_ payload: [String: Any]) -> String {
        var lines: [String] = []
        lines.append("tab=\((payload["workspace_id"] as? String) ?? "")")
        lines.append("color=\((payload["color"] as? String) ?? "none")")
        lines.append("cwd=\((payload["cwd"] as? String) ?? "")")

        if let focusedCwd = payload["focused_cwd"] as? String {
            lines.append("focused_cwd=\(focusedCwd)")
            lines.append("focused_panel=\((payload["focused_surface_id"] as? String) ?? "unknown")")
        } else {
            lines.append("focused_cwd=unknown")
            lines.append("focused_panel=unknown")
        }

        if let git = payload["git_branch"] as? [String: Any], let branch = git["branch"] as? String {
            let dirty = (git["dirty"] as? Bool) ?? false
            lines.append("git_branch=\(branch)\(dirty ? " dirty" : " clean")")
        } else {
            lines.append("git_branch=none")
        }

        if let pr = payload["pull_request"] as? [String: Any],
           let number = intFromAny(pr["number"]),
           let status = pr["state"] as? String,
           let url = pr["url"] as? String {
            lines.append("pr=#\(number) \(status) \(url)")
            lines.append("pr_label=\((pr["label"] as? String) ?? "")")
            lines.append("pr_checks=\((pr["checks"] as? String) ?? "none")")
        } else {
            lines.append("pr=none")
            lines.append("pr_label=none")
            lines.append("pr_checks=none")
        }

        let ports = (payload["ports"] as? [Any])?.compactMap { intFromAny($0) } ?? []
        if ports.isEmpty {
            lines.append("ports=none")
        } else {
            lines.append("ports=\(ports.map(String.init).joined(separator: ","))")
        }

        if let progress = payload["progress"] as? [String: Any], let value = doubleFromAny(progress["value"]) {
            let label = (progress["label"] as? String) ?? ""
            lines.append("progress=\(String(format: "%.2f", value)) \(label)".trimmingCharacters(in: .whitespaces))
        } else {
            lines.append("progress=none")
        }

        let statusEntries = payload["status_entries"] as? [[String: Any]] ?? []
        lines.append("status_count=\(statusEntries.count)")
        for entry in statusEntries {
            lines.append("  \(sidebarMetadataLineText(entry))")
        }

        let metadataBlocks = payload["metadata_blocks"] as? [[String: Any]] ?? []
        lines.append("meta_block_count=\(metadataBlocks.count)")
        for block in metadataBlocks {
            lines.append("  \(sidebarMetadataBlockLineText(block))")
        }

        lines.append("log_count=\(intFromAny(payload["log_count"]) ?? 0)")
        let recentLogEntries = payload["recent_log_entries"] as? [[String: Any]] ?? []
        for entry in recentLogEntries {
            let level = (entry["level"] as? String) ?? "info"
            let message = (entry["message"] as? String) ?? ""
            lines.append("  [\(level)] \(message)")
        }

        return lines.joined(separator: "\n")
    }

    /// Pick the display handle for an item dict based on --id-format.
    func textHandle(_ item: [String: Any], idFormat: CLIIDFormat) -> String {
        let ref = item["ref"] as? String
        let id = item["id"] as? String
        switch idFormat {
        case .refs:  return ref ?? id ?? "?"
        case .uuids: return id ?? ref ?? "?"
        case .both:  return [ref, id].compactMap({ $0 }).joined(separator: " ")
        }
    }

    func v2OKSummary(_ payload: [String: Any], idFormat: CLIIDFormat, kinds: [String] = ["surface", "workspace"]) -> String {
        var parts = ["OK"]
        for kind in kinds {
            if let handle = formatHandle(payload, kind: kind, idFormat: idFormat) {
                parts.append(handle)
            }
        }
        return parts.joined(separator: " ")
    }

    func isUUID(_ value: String) -> Bool {
        return UUID(uuidString: value) != nil
    }

    func jsonString(_ object: Any) -> String {
        var options: JSONSerialization.WritingOptions = [.prettyPrinted]
        options.insert(.withoutEscapingSlashes)
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: options),
              let output = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return output
    }

    func parseRPCParams(_ args: [String]) throws -> [String: Any] {
        guard !args.isEmpty else { return [:] }
        let raw = args.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return [:] }
        guard let data = raw.data(using: .utf8) else {
            throw CLIError(message: "rpc params must be valid UTF-8 JSON")
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw CLIError(message: "rpc params must be valid JSON: \(error.localizedDescription)")
        }
        guard let params = object as? [String: Any] else {
            throw CLIError(message: "rpc params must be a JSON object")
        }
        return params
    }

    func printVersion(jsonOutput: Bool) {
        guard jsonOutput else { return print(versionSummary()) }
        let info = resolvedVersionInfo()
        var payload: [String: Any] = ["summary": versionSummary()]
        payload["version"] = info["CFBundleShortVersionString"]
        payload["build"] = info["CFBundleVersion"]
        payload["commit"] = info["ProgramaCommit"].flatMap { normalizedCommitHash($0) }
        print(jsonString(payload))
    }

    func versionSummary() -> String {
        let info = resolvedVersionInfo()
        let commit = info["ProgramaCommit"].flatMap { normalizedCommitHash($0) }
        let baseSummary: String
        if let version = info["CFBundleShortVersionString"], let build = info["CFBundleVersion"] {
            baseSummary = "programa \(version) (\(build))"
        } else if let version = info["CFBundleShortVersionString"] {
            baseSummary = "programa \(version)"
        } else if let build = info["CFBundleVersion"] {
            baseSummary = "programa build \(build)"
        } else {
            baseSummary = "programa version unknown"
        }
        guard let commit else { return baseSummary }
        return "\(baseSummary) [\(commit)]"
    }

    func printWelcome() {
        let reset = "\u{001B}[0m"
        let bold = "\u{001B}[1m"
        func trueColor(_ red: Int, _ green: Int, _ blue: Int) -> String {
            "\u{001B}[38;2;\(red);\(green);\(blue)m"
        }

        let isDark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"

        // Row colors, light → dark red (develop gradient), plus the accent cursor cell.
        let r1: String, r2: String, r3: String, r4: String, cursor: String
        // Wordmark letter ramp (8 letters).
        let w: [String]
        let tagline: String
        let subdued: String

        if isDark {
            r1 = trueColor(255, 107, 82)   // #FF6B52
            r2 = trueColor(240, 64, 42)    // #F0402A
            r3 = trueColor(220, 46, 30)    // #DC2E1E
            r4 = trueColor(194, 31, 22)    // #C21F16
            cursor = trueColor(255, 138, 102) // #FF8A66
            w = [trueColor(255, 107, 82), trueColor(248, 90, 62), trueColor(240, 74, 46),
                 trueColor(230, 60, 36), trueColor(220, 46, 30), trueColor(210, 38, 26),
                 trueColor(194, 31, 22), trueColor(194, 31, 22)]
            tagline = trueColor(140, 130, 136)
            subdued = "\u{001B}[2m"
        } else {
            r1 = trueColor(232, 68, 46)    // #E8442E
            r2 = trueColor(212, 47, 31)    // #D42F1F
            r3 = trueColor(194, 31, 22)    // #C21F16
            r4 = trueColor(162, 24, 17)    // #A21811
            cursor = trueColor(232, 68, 46) // #E8442E
            w = [trueColor(232, 68, 46), trueColor(222, 56, 38), trueColor(212, 47, 31),
                 trueColor(202, 39, 26), trueColor(194, 31, 22), trueColor(178, 27, 19),
                 trueColor(162, 24, 17), trueColor(162, 24, 17)]
            tagline = trueColor(90, 90, 98)
            subdued = trueColor(100, 100, 108)
        }

        let wordmark = "\(w[0])p\(w[1])r\(w[2])o\(w[3])g\(w[4])r\(w[5])a\(w[6])m\(w[7])a\(reset)"

        // Shade-ramp cells are doubled so they stay square in 1:2 terminal cells.
        let logo = """
        \(r1)\u{2596}\u{2596} \u{2591}\u{2591} \u{2592}\u{2592} \u{2593}\u{2593}\(reset)        \(wordmark)
        \(r2)\u{2591}\u{2591} \u{2592}\u{2592} \u{2593}\u{2593} \u{2588}\u{2588}\(reset)
        \(r3)\u{2592}\u{2592} \u{2593}\u{2593} \u{2588}\u{2588} \u{2588}\u{2588}\(reset)        \(tagline)the open source terminal\(reset)
        \(r4)\u{2593}\u{2593} \u{2588}\u{2588} \u{2588}\u{2588} \(cursor)\u{2588}\u{2588}\(reset)        \(tagline)built for coding agents\(reset)
        """

        let shortcuts = """
          \(bold)Shortcuts\(reset)

          \(bold)\u{2318}N\(reset)\(subdued)                  New workspace\(reset)
          \(bold)\u{2318}T\(reset)\(subdued)                  New tab\(reset)
          \(bold)\u{2318}P\(reset)\(subdued)                  Go to workspace\(reset)
          \(bold)\u{2318}D\(reset)\(subdued)                  Split right\(reset)
          \(bold)\u{2318}\u{21E7}D\(reset)\(subdued)                 Split down\(reset)
          \(bold)\u{2318}\u{21E7}P\(reset)\(subdued)                 Command palette\(reset)
          \(bold)\u{2318}\u{21E7}R\(reset)\(subdued)                 Rename workspace\(reset)
          \(bold)\u{2318}\u{21E7}U\(reset)\(subdued)                 Jump to latest unread\(reset)
        """

        print()
        print(logo)
        print()
        print(shortcuts)
        print()
        print("  \(bold)Docs\(reset)\(subdued)                https://github.com/darkroomengineering/programa/tree/main/docs\(reset)")
        print("  \(bold)X\(reset)\(subdued)                   https://x.com/darkroomdevs\(reset)")
        print("  \(bold)GitHub\(reset)\(subdued)              https://github.com/darkroomengineering/programa (please leave a star ⭐)\(reset)")
        print("  \(bold)Issues\(reset)\(subdued)              https://github.com/darkroomengineering/programa/issues\(reset)")
        print()
        print("  \(subdued)Run \(reset)\(bold)programa --help\(reset)\(subdued) for all commands.\(reset)")
        print("  \(subdued)Run \(reset)\(bold)programa shortcuts\(reset)\(subdued) to edit shortcuts.\(reset)")
        print("  \(subdued)Run \(reset)\(bold)programa feedback\(reset)\(subdued) to report a bug.\(reset)")
        print()
    }

    func resolvedVersionInfo() -> [String: String] {
        var info: [String: String] = [:]
        if let main = versionInfo(from: Bundle.main.infoDictionary) {
            info.merge(main, uniquingKeysWith: { current, _ in current })
        }

        let needsPlistFallback =
            info["CFBundleShortVersionString"] == nil ||
            info["CFBundleVersion"] == nil ||
            info["ProgramaCommit"] == nil
        if needsPlistFallback {
            for plistURL in candidateInfoPlistURLs() {
                guard let data = try? Data(contentsOf: plistURL),
                      let raw = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
                      let dictionary = raw as? [String: Any],
                      let parsed = versionInfo(from: dictionary)
                else {
                    continue
                }
                info.merge(parsed, uniquingKeysWith: { current, _ in current })
                if info["CFBundleShortVersionString"] != nil,
                   info["CFBundleVersion"] != nil,
                   info["ProgramaCommit"] != nil {
                    break
                }
            }
        }

        let needsProjectFallback =
            info["CFBundleShortVersionString"] == nil ||
            info["CFBundleVersion"] == nil ||
            info["ProgramaCommit"] == nil
        if needsProjectFallback, let fromProject = versionInfoFromProjectFile() {
            info.merge(fromProject, uniquingKeysWith: { current, _ in current })
        }

        if info["ProgramaCommit"] == nil,
           let commit = normalizedCommitHash(ProcessInfo.processInfo.environment["PROGRAMA_COMMIT"]) {
            info["ProgramaCommit"] = commit
        }

        return info
    }

    private func versionInfo(from dictionary: [String: Any]?) -> [String: String]? {
        guard let dictionary else { return nil }

        var info: [String: String] = [:]
        if let version = dictionary["CFBundleShortVersionString"] as? String {
            let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && !trimmed.contains("$(") {
                info["CFBundleShortVersionString"] = trimmed
            }
        }
        if let build = dictionary["CFBundleVersion"] as? String {
            let trimmed = build.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && !trimmed.contains("$(") {
                info["CFBundleVersion"] = trimmed
            }
        }
        if let commit = dictionary["ProgramaCommit"] as? String,
           let normalizedCommit = normalizedCommitHash(commit) {
            info["ProgramaCommit"] = normalizedCommit
        }
        return info.isEmpty ? nil : info
    }

    private func versionInfoFromProjectFile() -> [String: String]? {
        guard let executableURL = resolvedExecutableURL() else {
            return nil
        }

        let fileManager = FileManager.default
        var current = executableURL.deletingLastPathComponent().standardizedFileURL

        while true {
            let projectFile = current.appendingPathComponent("GhosttyTabs.xcodeproj/project.pbxproj")
            if fileManager.fileExists(atPath: projectFile.path),
               let contents = try? String(contentsOf: projectFile, encoding: .utf8) {
                var info: [String: String] = [:]
                if let version = firstProjectSetting("MARKETING_VERSION", in: contents) {
                    info["CFBundleShortVersionString"] = version
                }
                if let build = firstProjectSetting("CURRENT_PROJECT_VERSION", in: contents) {
                    info["CFBundleVersion"] = build
                }
                if let commit = gitCommitHash(at: current) {
                    info["ProgramaCommit"] = commit
                }
                if !info.isEmpty {
                    return info
                }
            }

            guard let parent = parentSearchURL(for: current) else {
                break
            }
            current = parent
        }

        return nil
    }

    private func firstProjectSetting(_ key: String, in source: String) -> String? {
        let pattern = NSRegularExpression.escapedPattern(for: key) + "\\s*=\\s*([^;]+);"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let searchRange = NSRange(source.startIndex..<source.endIndex, in: source)
        guard let match = regex.firstMatch(in: source, options: [], range: searchRange),
              match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: source)
        else {
            return nil
        }
        let value = source[valueRange]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        guard !value.isEmpty, !value.contains("$(") else {
            return nil
        }
        return value
    }

    private func gitCommitHash(at directory: URL) -> String? {
        let process = Process()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", directory.path, "rev-parse", "--short=9", "HEAD"]
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return nil
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else {
            return nil
        }
        return normalizedCommitHash(output)
    }

    private func normalizedCommitHash(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("$(") else {
            return nil
        }
        let normalized = trimmed.lowercased()
        let allowed = CharacterSet(charactersIn: "0123456789abcdef")
        guard normalized.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return nil
        }
        return String(normalized.prefix(12))
    }

    // Foundation can walk past "/" into "/.." when repeatedly deleting path
    // components, so stop once the canonical root is reached.
    func parentSearchURL(for url: URL) -> URL? {
        let standardized = url.standardizedFileURL
        let path = standardized.path
        guard !path.isEmpty, path != "/" else {
            return nil
        }

        let parent = standardized.deletingLastPathComponent().standardizedFileURL
        guard parent.path != path else {
            return nil
        }
        return parent
    }

    func candidateInfoPlistURLs() -> [URL] {
        guard let executableURL = resolvedExecutableURL() else {
            return []
        }

        let fileManager = FileManager.default

        var candidates: [URL] = []
        var seen: Set<String> = []
        func appendIfExisting(_ url: URL) {
            let path = url.path
            guard !path.isEmpty else { return }
            guard seen.insert(path).inserted else { return }
            guard fileManager.fileExists(atPath: path) else { return }
            candidates.append(url)
        }

        var current = executableURL.deletingLastPathComponent().standardizedFileURL
        while true {
            if current.pathExtension == "app" {
                appendIfExisting(current.appendingPathComponent("Contents/Info.plist"))
            }
            if current.lastPathComponent == "Contents" {
                appendIfExisting(current.appendingPathComponent("Info.plist"))
            }

            let projectMarker = current.appendingPathComponent("GhosttyTabs.xcodeproj/project.pbxproj")
            let repoInfo = current.appendingPathComponent("Resources/Info.plist")
            if fileManager.fileExists(atPath: projectMarker.path),
               fileManager.fileExists(atPath: repoInfo.path) {
                appendIfExisting(repoInfo)
                break
            }

            guard let parent = parentSearchURL(for: current) else {
                break
            }
            current = parent
        }

        // If we already found an ancestor bundle or repo Info.plist, avoid scanning
        // sibling app bundles. Large Resources directories can otherwise balloon RSS.
        guard candidates.isEmpty else {
            return candidates
        }

        let searchRoots = [
            executableURL.deletingLastPathComponent().standardizedFileURL,
            executableURL.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL
        ]
        for root in searchRoots {
            guard let entries = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants],
                errorHandler: { _, _ in true }
            ) else {
                continue
            }
            for case let entry as URL in entries where entry.pathExtension == "app" {
                appendIfExisting(entry.appendingPathComponent("Contents/Info.plist"))
            }
        }

        return candidates
    }

    private func currentExecutablePath() -> String? {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        if size > 0 {
            var buffer = Array<CChar>(repeating: 0, count: Int(size))
            if _NSGetExecutablePath(&buffer, &size) == 0 {
                let path = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
                if !path.isEmpty {
                    return path
                }
            }
        }
        return Bundle.main.executableURL?.path ?? args.first
    }

    func resolvedExecutableURL() -> URL? {
        guard let executable = currentExecutablePath(), !executable.isEmpty else {
            return nil
        }

        let expanded = (executable as NSString).expandingTildeInPath
        if let resolvedPath = realpath(expanded, nil) {
            defer { free(resolvedPath) }
            return URL(fileURLWithPath: String(cString: resolvedPath)).standardizedFileURL
        }

        return URL(fileURLWithPath: expanded).standardizedFileURL
    }

    /// The `Commands:` section body, generated from `commandDescriptors()` so
    /// it can never drift from what the dispatcher actually knows about.
    /// See `CommandDescriptor` for why this is the single source of truth.
    private func commandsHelpBlock() -> String {
        commandDescriptors()
            .flatMap { $0.helpLines }
            .map { $0.isEmpty ? "" : "  " + $0 }
            .joined(separator: "\n")
    }

    func usage() -> String {
        return """
        programa - control programa via Unix socket

        Usage:
          programa <path>                Open a directory in a new workspace (launches programa if needed)
          programa [global-options] <command> [options]

        Global Options (before the command):
          --socket <path>                  Socket to connect to (default: see PROGRAMA_SOCKET_PATH below)
          --json                           JSON output; errors print {"ok":false,"error":{...}} on stdout
          --id-format <refs|uuids|both>    Handle format in output (default: refs)
          --window <id|ref>                Run the command in this window without focusing it
          --password <value>               Socket password (visible in ps; prefer --password-stdin or PROGRAMA_SOCKET_PASSWORD)
          --password-stdin                 Read the socket password from the first line of stdin
          -v, --version                    Print the version and exit
          -h, --help                       Print this help and exit

        Handle Inputs:
          Use UUIDs or short refs (window:1/workspace:2/pane:3/surface:4) where commands accept window, workspace, pane, or surface inputs.
          `tab-action` also accepts `tab:<n>` in addition to `surface:<n>`.
          Output defaults to refs; pass --id-format uuids or --id-format both to include UUIDs.

        Socket Auth:
          --password or --password-stdin takes precedence, then PROGRAMA_SOCKET_PASSWORD env var, then password saved in Settings.

        Commands:
        \(commandsHelpBlock())

        Environment:
          PROGRAMA_WORKSPACE_ID   Auto-set in programa terminals. Used as default --workspace for
                              ALL commands (send, list-panels, new-split, notify, etc.).
          PROGRAMA_TAB_ID         Optional alias used by `tab-action`/`rename-tab` as default --tab.
          PROGRAMA_SURFACE_ID     Auto-set in programa terminals. Used as default --surface.
          PROGRAMA_SOCKET_PATH    Override the Unix socket path. Without this, the CLI defaults
                              to ~/Library/Application Support/programa/programa.sock and never connects to tagged/debug sockets on its own.
        """
    }
}

@main
struct ProgramaMain {
    static func main() {
        PaneJob.runIfRequested(CommandLine.arguments)
        // CLI tools should ignore SIGPIPE so closed stdout pipes do not terminate the process.
        _ = signal(SIGPIPE, SIG_IGN)
        let cli = ProgramaCLI(args: CommandLine.arguments)
        do {
            try cli.run()
        } catch {
            if jsonOutputRequested(CommandLine.arguments) {
                print(cli.jsonString(["ok": false, "error": jsonErrorObject(error)] as [String: Any]))
            } else {
                FileHandle.standardError.write(Data("Error: \(error)\n".utf8))
            }
            exit(1)
        }
    }

    /// Mirrors the global-option loop in `CLICommandDispatcher.run()`: `--json` counts only
    /// before the command name.
    static func jsonOutputRequested(_ args: [String]) -> Bool {
        var index = 1
        while index < args.count {
            let arg = args[index]
            if arg == "--json" { return true }
            if ["--socket", "--id-format", "--window", "--password"].contains(arg) { index += 2; continue }
            guard arg.hasPrefix("-") else { return false }
            index += 1
        }
        return false
    }

    /// Socket errors arrive as "<code>: <message>" (`SocketClient.sendV2`); everything else is a
    /// CLI-side error with code "error".
    static func jsonErrorObject(_ error: Error) -> [String: Any] {
        let text = String(describing: error)
        if let separator = text.range(of: ": "),
           case let code = String(text[..<separator.lowerBound]),
           code.contains("_") || ["unavailable", "timeout", "error"].contains(code),
           code.allSatisfy({ $0.isLowercase || $0 == "_" }) {
            return ["code": code, "message": String(text[separator.upperBound...])]
        }
        return ["code": "error", "message": text]
    }
}
