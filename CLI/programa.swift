import Foundation
import CryptoKit
import Darwin
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
#if canImport(Security)
import Security
#endif

struct CLIError: Error, CustomStringConvertible {
    let message: String

    var description: String { message }
}

/// A `connect()`/`stat()` syscall failure, carrying the raw `errno` so callers can decide
/// whether the failure is worth retrying (ECONNREFUSED/ENOENT during an app-restart window)
/// without parsing the human-readable message string.
struct SocketConnectError: Error, CustomStringConvertible {
    let errnoValue: Int32
    let message: String

    var description: String { message }

    /// True for failures typical of the brief window while the app process is restarting
    /// (auto-update relaunch or crash recovery): the socket file hasn't been recreated yet
    /// (ENOENT) or nothing is listening on it yet (ECONNREFUSED). Any other failure (wrong
    /// file type, ownership mismatch, permission) is not transient and should fail immediately.
    var isTransient: Bool {
        errnoValue == ECONNREFUSED || errnoValue == ENOENT
    }
}

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

enum SocketPasswordResolver {
    private static let service = "com.darkroom.programa.socket-control"
    private static let account = "local-socket-password"
    private static let directoryName = "programa"
    private static let fileName = "socket-control-password"

    static func resolve(explicit: String?, socketPath: String) -> String? {
        if let explicit = normalized(explicit) {
            return explicit
        }
        if let env = normalized(ProcessInfo.processInfo.environment["PROGRAMA_SOCKET_PASSWORD"]) {
            return env
        }
        if let filePassword = loadFromFile() {
            return filePassword
        }
        return loadFromKeychain(socketPath: socketPath)
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .newlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func loadFromFile() -> String? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let passwordURL = appSupport
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)

        var pathStat = stat()
        guard lstat(passwordURL.path, &pathStat) == 0,
              (pathStat.st_mode & S_IFMT) == S_IFREG,
              pathStat.st_uid == geteuid(),
              (pathStat.st_mode & 0o077) == 0,
              pathStat.st_size >= 0,
              pathStat.st_size <= 64 * 1024 else {
            return nil
        }

        let descriptor = open(passwordURL.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }

        var openedStat = stat()
        guard fstat(descriptor, &openedStat) == 0,
              (openedStat.st_mode & S_IFMT) == S_IFREG,
              openedStat.st_uid == geteuid(),
              (openedStat.st_mode & 0o077) == 0,
              openedStat.st_dev == pathStat.st_dev,
              openedStat.st_ino == pathStat.st_ino,
              openedStat.st_size >= 0,
              openedStat.st_size <= 64 * 1024 else {
            return nil
        }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data = handle.readDataToEndOfFile()
        guard let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return normalized(value)
    }

    static func keychainServices(
        socketPath: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        guard let scope = keychainScope(socketPath: socketPath, environment: environment) else {
            return [service]
        }
        return ["\(service).\(scope)", service]
    }

    private static func keychainScope(
        socketPath: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        if let tag = normalized(environment["PROGRAMA_TAG"]) {
            let scoped = sanitizeScope(tag)
            if !scoped.isEmpty {
                return scoped
            }
        }

        let candidate = URL(fileURLWithPath: socketPath).lastPathComponent
        let prefixes = ["cmux-debug-", "cmux-"]
        for prefix in prefixes {
            guard candidate.hasPrefix(prefix), candidate.hasSuffix(".sock") else { continue }
            let start = candidate.index(candidate.startIndex, offsetBy: prefix.count)
            let end = candidate.index(candidate.endIndex, offsetBy: -".sock".count)
            guard start < end else { continue }
            let rawScope = String(candidate[start..<end])
            let scoped = sanitizeScope(rawScope)
            if !scoped.isEmpty {
                return scoped
            }
        }
        return nil
    }

    private static func sanitizeScope(_ raw: String) -> String {
        let lowered = raw.lowercased()
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-"))
        let mappedScalars = lowered.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "."
        }
        var normalizedScope = String(mappedScalars)
        normalizedScope = normalizedScope.replacingOccurrences(
            of: "\\.+",
            with: ".",
            options: .regularExpression
        )
        normalizedScope = normalizedScope.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return normalizedScope
    }

    private static func loadFromKeychain(socketPath: String) -> String? {
        for service in keychainServices(socketPath: socketPath) {
            let authContext = LAContext()
            authContext.interactionNotAllowed = true
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
                // Never trigger keychain UI from CLI commands; fail fast instead.
                kSecUseAuthenticationContext as String: authContext,
            ]
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound || status == errSecInteractionNotAllowed || status == errSecAuthFailed {
                continue
            }
            guard status == errSecSuccess else {
                continue
            }
            guard let data = result as? Data,
                  let password = String(data: data, encoding: .utf8) else {
                continue
            }
            return password
        }
        return nil
    }
}

// CLISocketPathSource / CLISocketPathResolver live in
// `CLI/SocketPathResolution.swift`, shared with the MCP sidecar
// (`CLI-MCP/MCPSocketBridge.swift`) -- see that file's header comment and
// docs/plans/mcp-server.md §1.4/§6.

final class SocketClient {
    private let path: String
    private var socketFD: Int32 = -1
    private static let defaultResponseTimeoutSeconds: TimeInterval = 15.0
    private static let multilineResponseIdleTimeoutSeconds: TimeInterval = 0.12
    private static let maxSocketTimeoutSeconds: TimeInterval = 9_007_199_254_740_991
    private static let responseTimeoutSeconds: TimeInterval = {
        let env = ProcessInfo.processInfo.environment
        if let raw = env["CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC"],
           let seconds = Double(raw),
           seconds.isFinite,
           seconds > 0 {
            return seconds
        }
        return defaultResponseTimeoutSeconds
    }()

    init(path: String) {
        self.path = path
    }

    var socketPath: String {
        path
    }

    private static func socketTimeval(for timeout: TimeInterval) -> timeval {
        let sanitizedTimeout = timeout.isFinite ? timeout : defaultResponseTimeoutSeconds
        let clampedTimeout = min(max(sanitizedTimeout, 0.01), maxSocketTimeoutSeconds)
        let seconds = floor(clampedTimeout)
        let microseconds = min(
            max(Int((clampedTimeout - seconds) * 1_000_000), 0),
            999_999
        )
        return timeval(
            tv_sec: Int(seconds),
            tv_usec: __darwin_suseconds_t(microseconds)
        )
    }

    func connect() throws {
        if socketFD >= 0 { return }
        try connectOnce()
    }

    /// Like `connect()`, but retries a transient failure (ECONNREFUSED/ENOENT -- see
    /// `SocketConnectError.isTransient`) up to 3 total attempts spread over ~1.5s
    /// (250ms/500ms/750ms delays before each retry), bounding added worst-case latency to
    /// ~1.5s. Covers the brief window while the app process is restarting (auto-update
    /// relaunch or crash recovery) so a one-shot command doesn't fail outright just because
    /// it raced the relaunch. Never retries once a connection has been established, and
    /// never retries a non-transient failure (permission, wrong file type) -- those fail
    /// immediately exactly as `connect()` does today.
    func connectWithTransientRetry() throws {
        if socketFD >= 0 { return }
        let retryDelays: [TimeInterval] = [0.25, 0.5, 0.75]
        var attempt = 0
        while true {
            do {
                try connectOnce()
                return
            } catch let error as SocketConnectError where error.isTransient && attempt < retryDelays.count {
                Thread.sleep(forTimeInterval: retryDelays[attempt])
                attempt += 1
            }
        }
    }

    func close() {
        if socketFD >= 0 {
            Darwin.close(socketFD)
            socketFD = -1
        }
    }

    /// - Parameter minimumReceiveTimeout: overrides the default response-wait timeout when
    ///   larger than it, for commands that legitimately hold the connection open longer than
    ///   `CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC`'s default (e.g. `surface.wait` with a caller-chosen
    ///   `--timeout`). Ignored (falls back to the default) when `nil` or smaller.
    func send(command: String, minimumReceiveTimeout: TimeInterval? = nil) throws -> String {
        guard socketFD >= 0 else { throw CLIError(message: "Not connected") }

        let payload = command + "\n"
        try writeAll(
            Data(payload.utf8),
            timeoutMessage: "Command timed out",
            failureMessage: "Failed to write to socket"
        )

        var data = Data()
        var sawNewline = false
        let initialReceiveTimeout: TimeInterval = {
            guard let minimumReceiveTimeout, minimumReceiveTimeout > Self.responseTimeoutSeconds else {
                return Self.responseTimeoutSeconds
            }
            return minimumReceiveTimeout
        }()

        while true {
            try configureReceiveTimeout(
                sawNewline ? Self.multilineResponseIdleTimeoutSeconds : initialReceiveTimeout
            )

            var buffer = [UInt8](repeating: 0, count: 8192)
            let count = Darwin.read(socketFD, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR {
                    continue
                }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    if sawNewline {
                        break
                    }
                    throw CLIError(message: "Command timed out")
                }
                throw CLIError(message: "Socket read error")
            }
            if count == 0 {
                break
            }
            data.append(buffer, count: count)
            if data.contains(UInt8(0x0A)) {
                sawNewline = true
            }
        }

        guard var response = String(data: data, encoding: .utf8) else {
            throw CLIError(message: "Invalid UTF-8 response")
        }
        if response.hasSuffix("\n") {
            response.removeLast()
        }
        return response
    }

    private func connectOnce() throws {
        // Verify socket is owned by the current user to prevent fake-socket attacks.
        var st = stat()
        guard stat(path, &st) == 0 else {
            let statErrno = errno
            throw SocketConnectError(errnoValue: statErrno, message: "Socket not found at \(path)")
        }
        guard (st.st_mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK) else {
            throw CLIError(message: "Path exists at \(path) but is not a Unix socket")
        }
        guard st.st_uid == getuid() else {
            throw CLIError(message: "Socket at \(path) is not owned by the current user — refusing to connect")
        }

        socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        if socketFD < 0 {
            throw CLIError(message: "Failed to create socket")
        }
        do {
            try configureSocketWriteSafety(Self.responseTimeoutSeconds)
        } catch {
            close()
            throw error
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLength = MemoryLayout.size(ofValue: addr.sun_path)
        path.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                let buf = UnsafeMutableRawPointer(pathPtr).assumingMemoryBound(to: CChar.self)
                strncpy(buf, ptr, maxLength - 1)
            }
        }

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(socketFD, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result == 0 {
            return
        }

        let connectErrno = errno
        Darwin.close(socketFD)
        socketFD = -1
        throw SocketConnectError(
            errnoValue: connectErrno,
            message: "Failed to connect to socket at \(path) (\(String(cString: strerror(connectErrno))), errno \(connectErrno))"
        )
    }

    private func writeAll(
        _ data: Data,
        timeoutMessage: String,
        failureMessage: String
    ) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return
            }
            var offset = 0
            while offset < data.count {
                let written = Darwin.write(socketFD, baseAddress.advanced(by: offset), data.count - offset)
                if written < 0 {
                    let errorCode = errno
                    if errorCode == EINTR {
                        continue
                    }
                    close()
                    if errorCode == EAGAIN || errorCode == EWOULDBLOCK || errorCode == ETIMEDOUT {
                        throw CLIError(message: timeoutMessage)
                    }
                    let reason = String(cString: strerror(errorCode))
                    throw CLIError(
                        message: "\(failureMessage) (\(reason), errno \(errorCode))"
                    )
                }
                if written == 0 {
                    close()
                    throw CLIError(message: failureMessage)
                }
                offset += written
            }
        }
    }

    private func configureSocketWriteSafety(_ timeout: TimeInterval) throws {
        var interval = Self.socketTimeval(for: timeout)
        let sendTimeoutResult = withUnsafePointer(to: &interval) { ptr in
            setsockopt(
                socketFD,
                SOL_SOCKET,
                SO_SNDTIMEO,
                ptr,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }
        guard sendTimeoutResult == 0 else {
            throw CLIError(message: "Failed to configure socket write timeout")
        }

#if os(macOS)
        var noSigPipe: Int32 = 1
        let noSigPipeResult = withUnsafePointer(to: &noSigPipe) { ptr in
            setsockopt(
                socketFD,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                ptr,
                socklen_t(MemoryLayout<Int32>.size)
            )
        }
        guard noSigPipeResult == 0 else {
            throw CLIError(message: "Failed to disable SIGPIPE on socket")
        }
#endif
    }

    private func configureReceiveTimeout(_ timeout: TimeInterval) throws {
        var interval = Self.socketTimeval(for: timeout)
        let result = withUnsafePointer(to: &interval) { ptr in
            setsockopt(
                socketFD,
                SOL_SOCKET,
                SO_RCVTIMEO,
                ptr,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }
        guard result == 0 else {
            throw CLIError(message: "Failed to configure socket receive timeout")
        }
    }

    static func waitForConnectableSocket(path: String, timeout: TimeInterval) throws -> SocketClient {
        let client = SocketClient(path: path)
        if (try? client.connect()) != nil {
            return client
        }

        guard let watchDirectory = existingWatchDirectory(forPath: path) else {
            throw CLIError(message: "programa app did not start in time (socket not found at \(path))")
        }
        let watchFD = open(watchDirectory, O_EVTONLY)
        guard watchFD >= 0 else {
            throw CLIError(message: "programa app did not start in time (socket not found at \(path))")
        }

        let queue = DispatchQueue(label: "com.programa.cli.socket-watch.\(UUID().uuidString)")
        let semaphore = DispatchSemaphore(value: 0)
        var connected = false
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: watchFD,
            eventMask: [.write, .rename, .delete, .attrib, .extend, .link],
            queue: queue
        )

        func attemptConnect() {
            guard !connected else { return }
            if (try? client.connect()) != nil {
                connected = true
                semaphore.signal()
            }
        }

        source.setEventHandler {
            attemptConnect()
        }
        source.setCancelHandler {
            Darwin.close(watchFD)
        }
        source.resume()
        queue.async {
            attemptConnect()
        }

        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            source.cancel()
            client.close()
            throw CLIError(message: "programa app did not start in time (socket not found at \(path))")
        }

        source.cancel()
        return client
    }

    static func waitForFilesystemPath(_ path: String, timeout: TimeInterval) throws {
        if FileManager.default.fileExists(atPath: path) {
            return
        }

        guard let watchDirectory = existingWatchDirectory(forPath: path) else {
            throw CLIError(message: "Timed out waiting for \(path)")
        }
        let watchFD = open(watchDirectory, O_EVTONLY)
        guard watchFD >= 0 else {
            throw CLIError(message: "Timed out waiting for \(path)")
        }

        let queue = DispatchQueue(label: "com.programa.cli.path-watch.\(UUID().uuidString)")
        let semaphore = DispatchSemaphore(value: 0)
        var found = false
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: watchFD,
            eventMask: [.write, .rename, .delete, .attrib, .extend, .link],
            queue: queue
        )

        func checkPath() {
            guard !found else { return }
            if FileManager.default.fileExists(atPath: path) {
                found = true
                semaphore.signal()
            }
        }

        source.setEventHandler {
            checkPath()
        }
        source.setCancelHandler {
            Darwin.close(watchFD)
        }
        source.resume()
        queue.async {
            checkPath()
        }

        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            source.cancel()
            throw CLIError(message: "Timed out waiting for \(path)")
        }

        source.cancel()
    }

    private static func existingWatchDirectory(forPath path: String) -> String? {
        let fileManager = FileManager.default
        var candidate = URL(fileURLWithPath: (path as NSString).deletingLastPathComponent, isDirectory: true)

        while !candidate.path.isEmpty {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return candidate.path
            }
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path {
                break
            }
            candidate = parent
        }
        return nil
    }

    func sendV2(method: String, params: [String: Any] = [:], minimumReceiveTimeout: TimeInterval? = nil) throws -> [String: Any] {
        let request: [String: Any] = [
            "id": UUID().uuidString,
            "method": method,
            "params": params
        ]
        guard JSONSerialization.isValidJSONObject(request) else {
            throw CLIError(message: "Failed to encode v2 request")
        }

        let requestData = try JSONSerialization.data(withJSONObject: request, options: [])
        guard let requestLine = String(data: requestData, encoding: .utf8) else {
            throw CLIError(message: "Failed to encode v2 request")
        }

        let raw = try send(command: requestLine, minimumReceiveTimeout: minimumReceiveTimeout)

        // The server may return plain-text errors (e.g., "ERROR: Access denied ...")
        // before the JSON protocol starts. Surface these directly instead of letting
        // JSONSerialization throw a confusing parse error.
        if raw.hasPrefix("ERROR:") {
            throw CLIError(message: raw)
        }

        guard let responseData = raw.data(using: .utf8) else {
            throw CLIError(message: "Invalid UTF-8 v2 response")
        }
        guard let response = try JSONSerialization.jsonObject(with: responseData, options: []) as? [String: Any] else {
            throw CLIError(message: "Invalid v2 response: \(raw)")
        }

        if let ok = response["ok"] as? Bool, ok {
            return (response["result"] as? [String: Any]) ?? [:]
        }

        if let error = response["error"] as? [String: Any] {
            let code = (error["code"] as? String) ?? "error"
            let message = (error["message"] as? String) ?? "Unknown v2 error"
            throw CLIError(message: "\(code): \(message)")
        }

        throw CLIError(message: "v2 request failed")
    }

    /// Writes a v2 JSON-RPC request line without reading a response. Used by `watch-events`
    /// (#167 `subscribe`), which reads the subscribe ack and every subsequently pushed event
    /// frame one at a time via `readEventLine` -- `send`/`sendV2`'s "read until an idle gap"
    /// model isn't a good fit for a connection that keeps receiving lines indefinitely.
    func sendV2RequestOnly(method: String, params: [String: Any] = [:]) throws {
        guard socketFD >= 0 else { throw CLIError(message: "Not connected") }
        let request: [String: Any] = [
            "id": UUID().uuidString,
            "method": method,
            "params": params
        ]
        guard JSONSerialization.isValidJSONObject(request) else {
            throw CLIError(message: "Failed to encode v2 request")
        }
        let requestData = try JSONSerialization.data(withJSONObject: request, options: [])
        guard let requestLine = String(data: requestData, encoding: .utf8) else {
            throw CLIError(message: "Failed to encode v2 request")
        }
        try writeAll(
            Data((requestLine + "\n").utf8),
            timeoutMessage: "Command timed out",
            failureMessage: "Failed to write to socket"
        )
    }

    /// Reads exactly one newline-terminated line, blocking up to `timeout`. Pairs with
    /// `sendV2RequestOnly` for `watch-events`: unlike `send`, this never opportunistically
    /// slurps multiple already-buffered lines into one read, so each pushed event frame (and
    /// the initial subscribe ack) is read and handled one at a time.
    func readEventLine(timeout: TimeInterval) throws -> String {
        guard socketFD >= 0 else { throw CLIError(message: "Not connected") }
        var data = Data()
        while true {
            try configureReceiveTimeout(timeout)
            var byte: UInt8 = 0
            let count = Darwin.read(socketFD, &byte, 1)
            if count < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    throw CLIError(message: "Timed out waiting for the next event")
                }
                throw CLIError(message: "Socket read error")
            }
            if count == 0 {
                throw CLIError(message: "Connection closed")
            }
            if byte == 0x0A { break }
            data.append(byte)
        }
        guard let line = String(data: data, encoding: .utf8) else {
            throw CLIError(message: "Invalid UTF-8 in event line")
        }
        return line.trimmingCharacters(in: .whitespacesAndNewlines)
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
        timeout: TimeInterval? = nil
    ) -> CLIProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

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
/// Bundles everything a command body previously read from `run()`'s locals
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
/// `validateRegisteredArguments`. Field vocabulary matches that switch's
/// nested `parse`/`require` helpers so a grammar and a switch arm are
/// interchangeable line-for-line.
///
/// A command with a `nil` grammar (the default) falls through to the switch
/// unchanged -- this is additive, not a migration deadline.
struct CLIArgumentGrammar {
    /// Flags that take a value, e.g. `--name <value>`.
    var valueOptions: Set<String> = []
    /// Flags with no value, e.g. `--force`.
    var booleanOptions: Set<String> = []
    /// Subset of `valueOptions` that must be present. Checked in this order,
    /// matching `require(_:in:)`'s first-missing-wins error semantics.
    var requiredOptions: [String] = []
    var minPositionals: Int = 0
    /// `nil` means unbounded.
    var maxPositionals: Int? = 0
    /// Whether `--name=value` syntax is accepted in addition to `--name value`.
    var allowEquals: Bool = false
}

/// Single source of truth for a CLI command's name(s), its one-line entry in
/// the grouped `Commands:` help block, and how it executes.
///
/// This collapses what used to be independently maintained in three places:
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
    /// undocumented (matches several legacy/internal commands that were
    /// already missing from the old free-text help).
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

struct ProgramaCLI {
    let args: [String]

    private static let debugLastSocketHintPath = "/tmp/programa-last-socket-path"

    static func normalizedEnvValue(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func pathIsSocket(_ path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFSOCK
    }

    private static func debugSocketPathFromHintFile() -> String? {
#if DEBUG
        guard let raw = try? String(contentsOfFile: debugLastSocketHintPath, encoding: .utf8) else {
            return nil
        }
        guard let hinted = normalizedEnvValue(raw),
              hinted.hasPrefix("/tmp/programa-debug"),
              hinted.hasSuffix(".sock"),
              pathIsSocket(hinted) else {
            return nil
        }
        return hinted
#else
        return nil
#endif
    }

    private static func defaultSocketPath(environment: [String: String]) -> String {
        if let explicit = normalizedEnvValue(environment["PROGRAMA_SOCKET_PATH"]) {
            return explicit
        }
#if DEBUG
        if let hinted = debugSocketPathFromHintFile() {
            return hinted
        }
        return "/tmp/programa-debug.sock"
#else
        return "/tmp/programa.sock"
#endif
    }

    func run() throws {
        try CLICommandDispatcher(cli: self).run()
    }
    /// Single source of truth for command existence, help text, and dispatch.
    /// See `CommandDescriptor` for the collapsed-knowledge rationale (CT1).
    ///
    /// Order matches the historical `Commands:` help block, since that order
    /// is externally visible; dispatch itself is by name lookup and does not
    /// depend on array order.
    func commandDescriptors() -> [CommandDescriptor] {
        // Built imperatively (rather than as one large `[...] + f() + [...]`
        // expression) because the Swift type-checker times out trying to
        // infer a single expression spanning this many array-literal +
        // function-call concatenations.
        var descriptors: [CommandDescriptor] = [
            // MARK: - Pre-connection specials (dispatched earlier in run();
            // documented here only so usage() has one source for help text).
            CommandDescriptor(
                names: ["welcome"],
                helpLines: ["welcome"],
                connectionPolicy: .local,
                detailedUsage: """
                Usage: programa welcome

                Show a welcome screen with the programa logo and useful shortcuts.
                Auto-runs once on first launch.
                """,
                grammar: CLIArgumentGrammar(),
                execute: nil
            ),
            CommandDescriptor(
                names: ["shortcuts"],
                helpLines: ["shortcuts"],
                connectionPolicy: .local,
                detailedUsage: """
                Usage: programa shortcuts

                Open the Settings window to Keyboard Shortcuts.
                """,
                execute: nil
            ),
            CommandDescriptor(
                names: ["feedback"],
                helpLines: ["feedback [--email <email> --body <text> [--image <path> ...]]  (opens GitHub issues; direct submission disabled)"],
                connectionPolicy: .local,
                detailedUsage: """
                Usage: programa feedback
                       programa feedback --email <email> --body <text> [--image <path> ...]

                Without args, opens the GitHub issues page (https://github.com/darkroomengineering/programa/issues) in your browser.

                Direct feedback submission is disabled; --email/--body/--image are accepted but the app will
                return an error telling you to report the issue on GitHub instead.

                Flags:
                  --email <email>   Contact email for follow-up (submission disabled)
                  --body <text>     Feedback body (submission disabled)
                  --image <path>    Attach an image file, repeat for multiple images (submission disabled)
                """,
                execute: nil
            ),
            CommandDescriptor(names: ["themes"], helpLines: ["themes [list|set|clear]"], connectionPolicy: .local, execute: nil),
            CommandDescriptor(names: ["claude-teams"], helpLines: ["claude-teams [claude-args...]"], connectionPolicy: .local, helpPolicy: .passthrough, execute: nil),
            CommandDescriptor(names: ["omo"], helpLines: ["omo [opencode-args...]"], connectionPolicy: .local, helpPolicy: .passthrough, execute: nil),
            CommandDescriptor(names: ["omx"], helpLines: ["omx [omx-args...]"], connectionPolicy: .local, helpPolicy: .passthrough, execute: nil),
            CommandDescriptor(names: ["omc"], helpLines: ["omc [omc-args...]"], connectionPolicy: .local, helpPolicy: .passthrough, execute: nil),
            CommandDescriptor(
                names: ["codex"],
                helpLines: ["codex <install-integration|uninstall-integration>"],
                connectionPolicy: .local,
                detailedUsage: """
                Usage: programa codex <install-integration|uninstall-integration>
                       programa codex <install-hooks|uninstall-hooks>  (legacy aliases, still supported)

                Install or remove Programa's Codex notification hooks in
                ~/.codex/hooks.json (or $CODEX_HOME/hooks.json), and the
                `programa` agent skill (SKILL.md) into ~/.agents/skills/programa/.
                """,
                execute: nil
            ),
            CommandDescriptor(
                names: ["claude"],
                helpLines: ["claude <install-integration|uninstall-integration>"],
                connectionPolicy: .local,
                detailedUsage: """
                Usage: programa claude <install-integration|uninstall-integration>

                Install or remove Programa's persistent Claude Code hooks in
                ~/.claude/settings.json (or $CLAUDE_CONFIG_DIR/settings.json),
                and the `programa` agent skill (SKILL.md) into
                ~/.claude/skills/programa/.
                Unlike the runtime wrapper, this makes the integration work from
                any terminal, not just programa's.
                """,
                execute: nil
            ),
            CommandDescriptor(
                names: ["opencode"],
                helpLines: ["opencode <install-integration|uninstall-integration>"],
                connectionPolicy: .local,
                detailedUsage: """
                Usage: programa opencode <install-integration|uninstall-integration>

                Install or remove Programa's OpenCode plugin in
                ~/.config/opencode/plugins/programa.js (or $OPENCODE_CONFIG_DIR/plugins/programa.js),
                and the `programa` agent skill (SKILL.md) into
                ~/.config/opencode/skills/programa/ (or $OPENCODE_CONFIG_DIR/skills/programa/).
                OpenCode auto-loads local plugin files, so no opencode.json edit or
                npm install is needed.
                """,
                execute: nil
            ),
            CommandDescriptor(
                names: ["aside"],
                helpLines: ["aside <status|install-mcp|uninstall-mcp> [--with-devtools] [--yes]"],
                connectionPolicy: .local,
                detailedUsage: """
                Usage: programa aside <status|install-mcp|uninstall-mcp> [--with-devtools] [--yes]

                Detect the Aside agent browser CLI and register its MCP server with
                Claude Code and Codex. `status` reports the detected aside binary,
                the DevTools endpoint if Aside is running, and each client's
                registration state. `install-mcp` runs `claude mcp add` / `codex mcp add`
                for each detected client; `--with-devtools` also registers a
                chrome-devtools-mcp server pointed at Aside's DevTools port.
                `uninstall-mcp` removes both. `--yes`/`-y` skips the confirmation prompt.
                """,
                execute: nil
            ),

            CommandDescriptor(
                names: ["ping"],
                helpLines: ["ping"],
                argumentContract: .noArguments,
                detailedUsage: """
                Usage: programa ping

                Check connectivity to the programa socket server.
                """,
                execute: { ctx in
                    _ = try ctx.client.sendV2(method: "system.ping")
                    print("PONG")
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
                    let response = try ctx.client.sendV2(method: "system.capabilities")
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
                    let response = try ctx.client.sendV2(method: "system.identify", params: params)
                    print(self.jsonString(self.formatIDs(response, mode: ctx.idFormat)))
                }
            ),

            CommandDescriptor(
                names: ["list-windows"],
                helpLines: ["list-windows"],
                detailedUsage: """
                Usage: programa list-windows

                List open windows.
                """,
                grammar: CLIArgumentGrammar(),
                execute: { ctx in
                    let listed = try ctx.client.sendV2(method: "window.list")
                    let windows = listed["windows"] as? [[String: Any]] ?? []
                    if ctx.jsonOutput {
                        let payload = windows.map { item -> [String: Any] in
                            var dict: [String: Any] = [
                                "index": self.intFromAny(item["index"]) ?? 0,
                                "id": (item["id"] as? String) ?? "",
                                "key": (item["key"] as? Bool) ?? false,
                                "workspace_count": self.intFromAny(item["workspace_count"]) ?? 0,
                            ]
                            dict["selected_workspace_id"] = item["selected_workspace_id"] as? String ?? NSNull()
                            return dict
                        }
                        print(self.jsonString(payload))
                    } else if windows.isEmpty {
                        print("No windows")
                    } else {
                        let lines = windows.map { item -> String in
                            let selected = ((item["key"] as? Bool) ?? false) ? "*" : " "
                            let idx = self.intFromAny(item["index"]) ?? 0
                            let id = (item["id"] as? String) ?? ""
                            let selectedWs = (item["selected_workspace_id"] as? String) ?? "none"
                            let workspaceCount = self.intFromAny(item["workspace_count"]) ?? 0
                            return "\(selected) \(idx): \(id) selected_workspace=\(selectedWs) workspaces=\(workspaceCount)"
                        }
                        print(lines.joined(separator: "\n"))
                    }
                }
            ),

            CommandDescriptor(
                names: ["current-window"],
                helpLines: ["current-window"],
                detailedUsage: """
                Usage: programa current-window

                Print the currently selected window ID.
                """,
                grammar: CLIArgumentGrammar(),
                execute: { ctx in
                    let response = try ctx.client.sendV2(method: "window.current")
                    let windowId = (response["window_id"] as? String) ?? ""
                    if ctx.jsonOutput {
                        print(self.jsonString(["window_id": windowId]))
                    } else {
                        print(windowId)
                    }
                }
            ),

            CommandDescriptor(
                names: ["new-window"],
                helpLines: ["new-window"],
                detailedUsage: """
                Usage: programa new-window

                Create a new window.

                Example:
                  programa new-window
                """,
                grammar: CLIArgumentGrammar(),
                execute: { ctx in
                    let response = try ctx.client.sendV2(method: "window.create")
                    print("OK \((response["window_id"] as? String) ?? "")")
                }
            ),

            CommandDescriptor(
                names: ["focus-window"],
                helpLines: ["focus-window --window <id>"],
                detailedUsage: """
                Usage: programa focus-window --window <id|ref>

                Focus (bring to front) the specified window.

                Flags:
                  --window <id|ref>   Window to focus (required)

                Example:
                  programa focus-window --window <window-uuid>
                  programa focus-window --window window:1
                """,
                execute: { ctx in
                    guard let target = self.optionValue(ctx.commandArgs, name: "--window") else {
                        throw CLIError(message: "focus-window requires --window")
                    }
                    // v1 only ever accepted a literal window UUID (no index/ref resolution) — preserve
                    // that exactly rather than widening acceptance via normalizeWindowHandle.
                    guard self.isUUID(target.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                        throw CLIError(message: "ERROR: Invalid window id")
                    }
                    do {
                        _ = try ctx.client.sendV2(method: "window.focus", params: ["window_id": target])
                        print("OK")
                    } catch let error as CLIError where error.message.hasPrefix("not_found:") {
                        throw CLIError(message: "ERROR: Window not found")
                    }
                }
            ),

            CommandDescriptor(
                names: ["close-window"],
                helpLines: ["close-window --window <id>"],
                detailedUsage: """
                Usage: programa close-window --window <id|ref>

                Close the specified window.

                Flags:
                  --window <id|ref>   Window to close (required)

                Example:
                  programa close-window --window 0
                  programa close-window --window window:1
                """,
                execute: { ctx in
                    guard let target = self.optionValue(ctx.commandArgs, name: "--window") else {
                        throw CLIError(message: "close-window requires --window")
                    }
                    guard self.isUUID(target.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                        throw CLIError(message: "ERROR: Invalid window id")
                    }
                    do {
                        _ = try ctx.client.sendV2(method: "window.close", params: ["window_id": target])
                        print("OK")
                    } catch let error as CLIError where error.message.hasPrefix("not_found:") {
                        throw CLIError(message: "ERROR: Window not found")
                    }
                }
            ),

            CommandDescriptor(
                names: ["move-workspace-to-window"],
                helpLines: ["move-workspace-to-window --workspace <id|ref> --window <id|ref>"],
                detailedUsage: """
                Usage: programa move-workspace-to-window --workspace <id|ref> --window <id|ref>

                Move a workspace to a different window.

                Flags:
                  --workspace <id|ref>   Workspace to move (required)
                  --window <id|ref>      Target window (required)

                Example:
                  programa move-workspace-to-window --workspace workspace:2 --window window:1
                """,
                grammar: CLIArgumentGrammar(valueOptions: ["workspace", "window"], requiredOptions: ["workspace", "window"]),
                execute: { ctx in
                    guard let workspaceRaw = self.optionValue(ctx.commandArgs, name: "--workspace") else {
                        throw CLIError(message: "move-workspace-to-window requires --workspace")
                    }
                    guard let windowRaw = self.optionValue(ctx.commandArgs, name: "--window") else {
                        throw CLIError(message: "move-workspace-to-window requires --window")
                    }
                    var params: [String: Any] = [:]
                    let wsId = try self.normalizeWorkspaceHandle(workspaceRaw, client: ctx.client)
                    if let wsId { params["workspace_id"] = wsId }
                    let winId = try self.normalizeWindowHandle(windowRaw, client: ctx.client)
                    if let winId { params["window_id"] = winId }
                    let payload = try ctx.client.sendV2(method: "workspace.move_to_window", params: params)
                    self.printV2Payload(payload, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat, fallbackText: self.v2OKSummary(payload, idFormat: ctx.idFormat, kinds: ["workspace", "window"]))
                }
            ),

            CommandDescriptor(
                names: ["reorder-workspace"],
                helpLines: ["reorder-workspace --workspace <id|ref> (--index <n> | --before <id|ref> | --after <id|ref>) [--window <id|ref>]"],
                detailedUsage: """
                Usage: programa reorder-workspace [--workspace <id|ref> | <id|ref>] [flags]

                Reorder a workspace within its window.

                Flags:
                  --workspace <id|ref>   Workspace to reorder (required unless passed positionally)
                  --index <n>                  Place at this index
                  --before <id|ref>      Place before this workspace
                  --before-workspace <id|ref>
                                             Alias for --before
                  --after <id|ref>       Place after this workspace
                  --after-workspace <id|ref>
                                             Alias for --after
                  --window <id|ref>      Window context

                Example:
                  programa reorder-workspace --workspace workspace:2 --index 0
                  programa reorder-workspace --workspace workspace:3 --after workspace:1
                """,
                execute: { ctx in
                    try self.runReorderWorkspace(commandArgs: ctx.commandArgs, client: ctx.client, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat)
                }
            ),

            CommandDescriptor(
                names: ["workspace-action"],
                helpLines: ["workspace-action --action <name> [--workspace <id|ref>] [--title <text>] [--color <name|#hex>] [--description <text>]"],
                detailedUsage: """
                Usage: programa workspace-action --action <name> [flags]

                Perform workspace context-menu actions from CLI/socket.

                Actions:
                  pin | unpin
                  rename | clear-name
                  set-description | clear-description
                  move-up | move-down | move-top
                  close-others | close-above | close-below
                  mark-read | mark-unread
                  set-color | clear-color

                Flags:
                  --action <name>              Action name (required if not positional)
                  --workspace <id|ref>   Target workspace (default: current/$PROGRAMA_WORKSPACE_ID)
                  --title <text>               Title for rename
                  --color <name|#hex>          Color for set-color (name or #RRGGBB hex)
                  --description <text>         Description for set-description

                Named colors:
                  Red, Crimson, Orange, Amber, Olive, Green, Teal, Aqua,
                  Blue, Navy, Indigo, Purple, Magenta, Rose, Brown, Charcoal

                Example:
                  programa workspace-action --workspace workspace:2 --action pin
                  programa workspace-action --action rename --title "infra"
                  programa workspace-action close-others
                  programa workspace-action --action set-color --color blue
                  programa workspace-action --action set-color --color "#C0392B"
                  programa workspace-action set-color Amber
                  programa workspace-action --action set-description --description "Ship checklist"
                  programa workspace-action --action set-description $'Ship checklist\n- verify build\n- post notes'
                  programa workspace-action clear-color
                """,
                execute: { ctx in
                    try self.runWorkspaceAction(commandArgs: ctx.commandArgs, client: ctx.client, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat, windowOverride: ctx.windowId)
                }
            ),

            CommandDescriptor(
                names: ["worktree"],
                helpLines: ["worktree <create|open|remove|list> ..."],
                detailedUsage: """
                Usage: programa worktree <subcommand> [flags]

                Native git worktree workflow: create/open a worktree as its own workspace,
                grouped next to its parent repo's workspace in the sidebar.

                Subcommands:
                  create <branch> [--base <ref>] [--path <dir>] [--repo <dir>] [--layout <name>] [--focus]
                      Create (or check out) a worktree for <branch> and open it as a workspace.
                      If <branch> already exists locally, it is checked out; otherwise it is
                      created from --base (default HEAD). Default --path is
                      <worktrees.directory>/<repo-name>/<branch-slug>. --layout applies a saved
                      layout (see 'programa layout') into the new workspace. --focus opts in to
                      focusing the new workspace (default: does not steal focus).

                  open <path-or-branch> [--repo <dir>] [--focus]
                  open --all [--repo <dir>]
                      Open an existing worktree (by path or branch name) as a workspace.
                      Idempotent: returns the existing workspace if already open. --all opens
                      every worktree of the repo at once instead of one <path-or-branch>;
                      mutually exclusive with a positional target and with --focus.

                  remove <path-or-branch> [--repo <dir>] [--force]
                      Remove a worktree (never deletes the branch). Closes its workspace if
                      open. Requires --force if the worktree has uncommitted changes.

                  list [--repo <dir>] [--json]
                      List worktrees for the resolved repo, noting which are open as workspaces.

                Flags:
                  --repo <dir>       Repo to operate on. Default: resolved from the current
                                     directory via 'git rev-parse --show-toplevel'.
                  --base <ref>       Base ref for a new branch (create only). Default: HEAD.
                  --path <dir>       Worktree directory (create only). Default: computed from
                                     the worktrees.directory setting.
                  --layout <name>    Apply a saved layout (see 'programa layout') after creating
                                     the workspace (create only).
                  --focus            Focus the workspace after create/open (default: off).
                  --all              Open every worktree of the repo (open only).
                  --force            Allow removing a worktree with uncommitted changes.

                Example:
                  programa worktree create feature-x
                  programa worktree create feature-x --base main --layout fullstack-dev
                  programa worktree list --repo ~/code/programa
                  programa worktree open --all
                  programa worktree remove feature-x
                """,
                execute: { ctx in
                    try self.runWorktreeCommand(commandArgs: ctx.commandArgs, client: ctx.client, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat)
                }
            ),

            CommandDescriptor(
                names: ["agent-detection"],
                helpLines: ["agent-detection <list|scaffold|test> ..."],
                detailedUsage: """
                Usage: programa agent-detection <subcommand> [flags]

                Screen-manifest agent detection is a best-effort tier: regex patterns matched
                against visible terminal text to guess whether a coding agent is
                working/blocked/idle, used only when an agent doesn't report its own lifecycle
                via hooks. Programa ships manifests for a handful of agents; this command lets
                you author your own for anything else, at
                ~/.config/programa/agent-detection/<agent-id>.json -- a user override there
                fully replaces any bundled manifest with the same agent id.

                Subcommands:
                  list [--json]
                      List every loaded manifest (bundled + user overrides): agent id, display
                      name, source, and recognized process names.

                  scaffold <agent-id> [--surface <id|ref>] [--workspace <id|ref>] [--force]
                      Capture the target surface's current screen and write a starter manifest
                      to ~/.config/programa/agent-detection/<agent-id>.json, with the captured
                      screen embedded as reference text in each state's notes. Refuses to
                      overwrite an existing file unless --force. Also refuses <agent-id>s that
                      match one of the seven bundled agents (claude-code, codex, gemini-cli,
                      opencode, copilot-cli, cursor-agent, aider) unless --force, since an
                      override fully replaces the bundled manifest and a fresh scaffold starts
                      with empty patterns -- without --force this would silently disable working
                      detection for that agent. --force seeds the new file from the bundled
                      manifest's own patterns instead of starting blank.

                  test [<agent-id>] [--surface <id|ref>] [--workspace <id|ref>]
                      Classify the target surface's current screen through the real
                      recognition + classification path. With <agent-id>, tests that manifest's
                      state patterns directly (bypasses recognition -- useful right after
                      scaffolding, before recognize.screen_patterns is filled in). Without it,
                      reports whichever loaded manifest's recognize.screen_patterns first
                      matches the screen, the same way live detection would.

                Flags:
                  --surface <id|ref>     Target surface (default: $PROGRAMA_SURFACE_ID)
                  --workspace <id|ref>   Target workspace (default: $PROGRAMA_WORKSPACE_ID)
                  --force                Overwrite an existing scaffolded manifest, and/or
                                         confirm scaffolding one of the bundled agent ids
                                         (scaffold only)

                Example:
                  programa agent-detection list
                  programa agent-detection scaffold my-agent
                  programa agent-detection test my-agent
                  programa agent-detection test
                """,
                execute: { ctx in
                    try self.runAgentDetectionCommand(commandArgs: ctx.commandArgs, client: ctx.client, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat, windowId: ctx.windowId)
                }
            ),

            CommandDescriptor(
                names: ["race"],
                helpLines: ["race <prompt> [--n <count>] [--agent <name>] [--base <ref>] [--prefix <slug>] [--layout <name>]"],
                detailedUsage: """
                Usage: programa race <prompt> [flags]

                Fan one prompt across N agents, each in its own isolated git worktree, so you
                can compare their approaches and pick a winner. v1: spawns the fleet only --
                comparison/merge is manual (open each workspace, review its diff, merge the one
                you like via 'programa worktree remove' for the rest).

                For each index 1...N: creates a worktree + workspace on branch <prefix>/<index>
                (via 'programa worktree create', never stealing focus), then types the agent's
                launch command with your prompt into that workspace's focused terminal.

                Flags:
                  --n <count>        Number of parallel agents. Default 3. Must be 1-8.
                  --agent <name>     Agent to launch: claude, opencode, or codex. Default claude.
                                     Only these three report state via lifecycle hooks, which
                                     racing needs for a trustworthy idle signal.
                  --base <ref>       Git ref to branch from. Default: HEAD (see 'worktree create').
                  --prefix <slug>    Branch-name prefix. Default 'race'. Branches are
                                     <prefix>/<n>, continuing after any that already
                                     exist, so racing twice gives you race/1, race/2
                                     then race/3, race/4 rather than a collision.
                  --layout <name>    Saved layout to apply into each new workspace (see
                                     'programa layout').

                If a branch or worktree path already exists for one index, that index is
                reported as failed and the rest of the fleet still spawns; the command exits
                non-zero if any index failed.

                Example:
                  programa race "fix the failing test"
                  programa race "add dark mode" --n 5 --agent codex
                  programa race "refactor the parser" --n 2 --base main --prefix spike
                """,
                execute: { ctx in
                    try self.runRaceCommand(commandArgs: ctx.commandArgs, client: ctx.client, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat)
                }
            ),

            CommandDescriptor(
                names: ["layout"],
                helpLines: ["layout <save|apply|list> ..."],
                detailedUsage: """
                Usage: programa layout <subcommand> [flags]

                Named layout configs: save the current workspace's pane/split layout under a
                name, and re-apply it later (from the CLI or the command palette).

                Subcommands:
                  save <name> [--force]
                      Capture the current workspace's pane/split layout, cwds, and browser URLs
                      into ~/.config/programa/layouts/<name>.json. Does NOT capture what
                      command is currently running in each pane -- only geometry, cwd, and
                      browser URL are saved.

                  apply <name> [--workspace <id|ref>] [--cwd <dir>]
                      Apply a saved layout. If --workspace is omitted, creates a new (unfocused)
                      workspace first, with cwd = --cwd (or the current directory), then applies
                      the layout into it -- relative cwds in the saved layout resolve against
                      that new workspace's root.

                  list [--json]
                      List saved layout names.

                Flags:
                  --force            Overwrite an existing layout with the same name (save only).
                  --workspace <id|ref>
                                     Target an existing workspace (apply only).
                  --cwd <dir>        Base directory for a newly created workspace (apply only).

                Example:
                  programa layout save fullstack-dev
                  programa layout apply fullstack-dev
                  programa layout list
                """,
                execute: { ctx in
                    try self.runLayoutCommand(commandArgs: ctx.commandArgs, client: ctx.client, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat)
                }
            ),

            CommandDescriptor(
                names: ["snapshot"],
                helpLines: ["snapshot <list|restore> ..."],
                detailedUsage: """
                Usage: programa snapshot <subcommand> [flags]

                Session-restore history: every launch archives the previous session snapshot
                into ~/Library/Application Support/programa/session-history/ before it can be
                overwritten, so a crash, a forced shutdown, or a launch that skips restore
                never loses your last window layout for good.

                Subcommands:
                  list [--json]
                      List archived snapshots, newest first: id, saved-at, clean/unclean
                      shutdown, and window/workspace/panel counts.

                  restore [<id>|latest]
                      Restore an archived snapshot by opening a new window for every window
                      it contains. Never closes or changes a window that is already open.
                      Defaults to the newest archived snapshot when <id> is omitted or
                      "latest".

                Example:
                  programa snapshot list
                  programa snapshot restore
                  programa snapshot restore 20260731-153000-com.darkroom.programa
                """,
                execute: { ctx in
                    try self.runSnapshotCommand(commandArgs: ctx.commandArgs, client: ctx.client, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat)
                }
            ),

            CommandDescriptor(
                names: ["list-workspaces"],
                helpLines: ["list-workspaces"],
                detailedUsage: """
                Usage: programa list-workspaces

                List workspaces in the current window.

                Example:
                  programa list-workspaces
                """,
                grammar: CLIArgumentGrammar(),
                execute: { ctx in
                    let payload = try ctx.client.sendV2(method: "workspace.list")
                    if ctx.jsonOutput {
                        print(self.jsonString(self.formatIDs(payload, mode: ctx.idFormat)))
                    } else {
                        let workspaces = payload["workspaces"] as? [[String: Any]] ?? []
                        if workspaces.isEmpty {
                            print("No workspaces")
                        } else {
                            for ws in workspaces {
                                let selected = (ws["selected"] as? Bool) == true
                                let handle = self.textHandle(ws, idFormat: ctx.idFormat)
                                let title = (ws["title"] as? String) ?? ""
                                let prefix = selected ? "* " : "  "
                                let selTag = selected ? "  [selected]" : ""
                                let titlePart = title.isEmpty ? "" : "  \(title)"
                                print("\(prefix)\(handle)\(titlePart)\(selTag)")
                            }
                        }
                    }
                }
            ),

            CommandDescriptor(
                names: ["new-workspace"],
                helpLines: ["new-workspace [--name <title>] [--description <text>] [--cwd <path>] [--command <text>]"],
                detailedUsage: """
                Usage: programa new-workspace [--name <title>] [--description <text>] [--cwd <path>] [--command <text>]

                Create a new workspace in the current window.

                Flags:
                  --name <title>     Set a custom name for the new workspace
                  --description <text> Set a custom description for the new workspace
                  --cwd <path>       Set the working directory for the new workspace
                  --command <text>   Send text+Enter to the new workspace after creation

                Example:
                  programa new-workspace
                  programa new-workspace --name "Build Server"
                  programa new-workspace --name "Launch" --description "Ship checklist"
                  programa new-workspace --cwd ~/projects/myapp
                  programa new-workspace --cwd . --command "npm test"
                """,
                grammar: CLIArgumentGrammar(valueOptions: ["name", "description", "cwd", "command"]),
                execute: { ctx in
                    let (commandOpt, rem0) = self.parseOption(ctx.commandArgs, name: "--command")
                    let (cwdOpt, rem1) = self.parseOption(rem0, name: "--cwd")
                    let (nameOpt, rem2) = self.parseOption(rem1, name: "--name")
                    let (descriptionOpt, remaining) = self.parseOption(rem2, name: "--description")
                    if let unknown = remaining.first(where: { $0.hasPrefix("--") }) {
                        throw CLIError(message: "new-workspace: unknown flag '\(unknown)'. Known flags: --name <title>, --description <text>, --command <text>, --cwd <path>")
                    }
                    var params: [String: Any] = [:]
                    if let cwdOpt {
                        let resolved = self.resolvePath(cwdOpt)
                        params["cwd"] = resolved
                    }
                    if let nameOpt {
                        params["title"] = nameOpt
                    }
                    if let descriptionOpt {
                        params["description"] = descriptionOpt
                    }
                    let response = try ctx.client.sendV2(method: "workspace.create", params: params)
                    let wsId = (response["workspace_ref"] as? String) ?? (response["workspace_id"] as? String) ?? ""
                    print("OK \(wsId)")
                    if let commandText = commandOpt, !wsId.isEmpty {
                        let text = self.unescapeSendText(commandText + "\\n")
                        let sendParams: [String: Any] = ["text": text, "workspace_id": wsId]
                        _ = try ctx.client.sendV2(method: "surface.send_text", params: sendParams)
                    }
                }
            ),

            ]
        descriptors += [

            CommandDescriptor(
                names: ["new-split"],
                helpLines: ["new-split <left|right|up|down> [--workspace <id|ref>] [--surface <id|ref>] [--panel <id|ref>]"],
                detailedUsage: """
                Usage: programa new-split <left|right|up|down> [flags]

                Split the current pane in the given direction.

                Flags:
                  --workspace <id|ref>   Target workspace (default: $PROGRAMA_WORKSPACE_ID)
                  --surface <id|ref>     Surface to split from (default: $PROGRAMA_SURFACE_ID)
                  --panel <id|ref>       Alias for --surface

                Example:
                  programa new-split right
                  programa new-split down --workspace workspace:1
                """,
                execute: { ctx in
                    let (wsArg, rem0) = self.parseOption(ctx.commandArgs, name: "--workspace")
                    let (panelArg, rem1) = self.parseOption(rem0, name: "--panel")
                    let (sfArg, rem2) = self.parseOption(rem1, name: "--surface")
                    let workspaceArg = wsArg ?? (ctx.windowId == nil ? ProcessInfo.processInfo.environment["PROGRAMA_WORKSPACE_ID"] : nil)
                    guard let direction = rem2.first else {
                        throw CLIError(message: "new-split requires a direction")
                    }
                    var params: [String: Any] = ["direction": direction]
                    let wsId = try self.normalizeWorkspaceHandle(workspaceArg, client: ctx.client)
                    if let wsId { params["workspace_id"] = wsId }
                    let sfId = try self.resolveCommandSurface(
                        explicitSurface: sfArg ?? panelArg, explicitWorkspace: wsArg,
                        windowId: ctx.windowId, workspaceHandle: wsId, client: ctx.client
                    )
                    if let sfId { params["surface_id"] = sfId }
                    let payload = try ctx.client.sendV2(method: "surface.split", params: params)
                    self.printV2Payload(payload, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat, fallbackText: self.v2OKSummary(payload, idFormat: ctx.idFormat))
                }
            ),

            CommandDescriptor(
                names: ["list-panes"],
                helpLines: ["list-panes [--workspace <id|ref>]"],
                detailedUsage: """
                Usage: programa list-panes [--workspace <id|ref>]

                List panes in a workspace.

                Flags:
                  --workspace <id|ref>   Workspace context (default: $PROGRAMA_WORKSPACE_ID)

                Example:
                  programa list-panes
                  programa list-panes --workspace workspace:2
                """,
                grammar: CLIArgumentGrammar(valueOptions: ["workspace"]),
                execute: { ctx in
                    let workspaceArg = self.workspaceFromArgsOrEnv(ctx.commandArgs, windowOverride: ctx.windowId)
                    var params: [String: Any] = [:]
                    let wsId = try self.normalizeWorkspaceHandle(workspaceArg, client: ctx.client)
                    if let wsId { params["workspace_id"] = wsId }
                    let payload = try ctx.client.sendV2(method: "pane.list", params: params)
                    if ctx.jsonOutput {
                        print(self.jsonString(self.formatIDs(payload, mode: ctx.idFormat)))
                    } else {
                        let panes = payload["panes"] as? [[String: Any]] ?? []
                        if panes.isEmpty {
                            print("No panes")
                        } else {
                            for pane in panes {
                                let focused = (pane["focused"] as? Bool) == true
                                let handle = self.textHandle(pane, idFormat: ctx.idFormat)
                                let count = pane["surface_count"] as? Int ?? 0
                                let prefix = focused ? "* " : "  "
                                let focusTag = focused ? "  [focused]" : ""
                                print("\(prefix)\(handle)  [\(count) surface\(count == 1 ? "" : "s")]\(focusTag)")
                            }
                        }
                    }
                }
            ),

            CommandDescriptor(
                names: ["list-pane-surfaces"],
                helpLines: ["list-pane-surfaces [--workspace <id|ref>] [--pane <id|ref>]"],
                detailedUsage: """
                Usage: programa list-pane-surfaces [--workspace <id|ref>] [--pane <id|ref>]

                List surfaces in a pane.

                Flags:
                  --workspace <id|ref>   Workspace context (default: $PROGRAMA_WORKSPACE_ID)
                  --pane <id|ref>        Restrict to a specific pane (default: focused pane)

                Example:
                  programa list-pane-surfaces
                  programa list-pane-surfaces --workspace workspace:2 --pane pane:1
                """,
                grammar: CLIArgumentGrammar(valueOptions: ["workspace", "pane"]),
                execute: { ctx in
                    let workspaceArg = self.workspaceFromArgsOrEnv(ctx.commandArgs, windowOverride: ctx.windowId)
                    let paneRaw = self.optionValue(ctx.commandArgs, name: "--pane")
                    var params: [String: Any] = [:]
                    let wsId = try self.normalizeWorkspaceHandle(workspaceArg, client: ctx.client)
                    if let wsId { params["workspace_id"] = wsId }
                    let paneId = try self.normalizePaneHandle(paneRaw, client: ctx.client, workspaceHandle: wsId)
                    if let paneId { params["pane_id"] = paneId }
                    let payload = try ctx.client.sendV2(method: "pane.surfaces", params: params)
                    if ctx.jsonOutput {
                        print(self.jsonString(self.formatIDs(payload, mode: ctx.idFormat)))
                    } else {
                        let surfaces = payload["surfaces"] as? [[String: Any]] ?? []
                        if surfaces.isEmpty {
                            print("No surfaces in pane")
                        } else {
                            for surface in surfaces {
                                let selected = (surface["selected"] as? Bool) == true
                                let handle = self.textHandle(surface, idFormat: ctx.idFormat)
                                let title = (surface["title"] as? String) ?? ""
                                let prefix = selected ? "* " : "  "
                                let selTag = selected ? "  [selected]" : ""
                                print("\(prefix)\(handle)  \(title)\(selTag)")
                            }
                        }
                    }
                }
            ),

            ]
        descriptors += self.treeDescriptors()
        descriptors += [

            CommandDescriptor(
                names: ["focus-pane"],
                helpLines: ["focus-pane --pane <id|ref> [--workspace <id|ref>]"],
                detailedUsage: """
                Usage: programa focus-pane [--pane <id|ref> | <id|ref>] [flags]

                Focus the specified pane.

                Flags:
                  --pane <id|ref>          Pane to focus (required unless passed positionally)
                  --workspace <id|ref>     Workspace context (default: $PROGRAMA_WORKSPACE_ID)

                Example:
                  programa focus-pane --pane pane:2
                  programa focus-pane pane:1
                  programa focus-pane --pane pane:1 --workspace workspace:2
                """,
                execute: { ctx in
                    let workspaceArg = self.workspaceFromArgsOrEnv(ctx.commandArgs, windowOverride: ctx.windowId)
                    guard let paneRaw = self.optionValue(ctx.commandArgs, name: "--pane") ?? ctx.commandArgs.first else {
                        throw CLIError(message: "focus-pane requires --pane <id|ref>")
                    }
                    var params: [String: Any] = [:]
                    let wsId = try self.normalizeWorkspaceHandle(workspaceArg, client: ctx.client)
                    if let wsId { params["workspace_id"] = wsId }
                    let paneId = try self.normalizePaneHandle(paneRaw, client: ctx.client, workspaceHandle: wsId)
                    if let paneId { params["pane_id"] = paneId }
                    let payload = try ctx.client.sendV2(method: "pane.focus", params: params)
                    self.printV2Payload(payload, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat, fallbackText: self.v2OKSummary(payload, idFormat: ctx.idFormat, kinds: ["pane", "workspace"]))
                }
            ),

            CommandDescriptor(
                names: ["new-pane"],
                helpLines: ["new-pane [--type <terminal|browser>] [--direction <left|right|up|down>] [--workspace <id|ref>] [--url <url>]"],
                detailedUsage: """
                Usage: programa new-pane [flags]

                Create a new pane in the workspace.

                Flags:
                  --type <terminal|browser>           Pane type (default: terminal)
                  --direction <left|right|up|down>    Split direction (default: right)
                  --workspace <id|ref>                Target workspace (default: $PROGRAMA_WORKSPACE_ID)
                  --url <url>                         URL for browser panes

                Example:
                  programa new-pane
                  programa new-pane --type browser --direction down --url https://example.com
                """,
                execute: { ctx in
                    let workspaceArg = self.workspaceFromArgsOrEnv(ctx.commandArgs, windowOverride: ctx.windowId)
                    let type = self.optionValue(ctx.commandArgs, name: "--type")
                    let direction = self.optionValue(ctx.commandArgs, name: "--direction") ?? "right"
                    let url = self.optionValue(ctx.commandArgs, name: "--url")
                    var params: [String: Any] = ["direction": direction]
                    let wsId = try self.normalizeWorkspaceHandle(workspaceArg, client: ctx.client)
                    if let wsId { params["workspace_id"] = wsId }
                    if let type { params["type"] = type }
                    if let url { params["url"] = url }
                    let payload = try ctx.client.sendV2(method: "pane.create", params: params)
                    self.printV2Payload(payload, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat, fallbackText: self.v2OKSummary(payload, idFormat: ctx.idFormat, kinds: ["surface", "pane", "workspace"]))
                }
            ),

            CommandDescriptor(
                names: ["new-surface"],
                helpLines: ["new-surface [--type <terminal|browser>] [--pane <id|ref>] [--workspace <id|ref>] [--url <url>]"],
                detailedUsage: """
                Usage: programa new-surface [flags]

                Create a new surface (tab) in a pane.

                Flags:
                  --type <terminal|browser>   Surface type (default: terminal)
                  --pane <id|ref>             Target pane
                  --workspace <id|ref>        Target workspace (default: $PROGRAMA_WORKSPACE_ID)
                  --url <url>                 URL for browser surfaces

                Example:
                  programa new-surface
                  programa new-surface --type browser --pane pane:1 --url https://example.com
                """,
                execute: { ctx in
                    let workspaceArg = self.workspaceFromArgsOrEnv(ctx.commandArgs, windowOverride: ctx.windowId)
                    let type = self.optionValue(ctx.commandArgs, name: "--type")
                    let paneRaw = self.optionValue(ctx.commandArgs, name: "--pane")
                    let url = self.optionValue(ctx.commandArgs, name: "--url")
                    var params: [String: Any] = [:]
                    let wsId = try self.normalizeWorkspaceHandle(workspaceArg, client: ctx.client)
                    if let wsId { params["workspace_id"] = wsId }
                    let paneId = try self.normalizePaneHandle(paneRaw, client: ctx.client, workspaceHandle: wsId)
                    if let paneId { params["pane_id"] = paneId }
                    if let type { params["type"] = type }
                    if let url { params["url"] = url }
                    let payload = try ctx.client.sendV2(method: "surface.create", params: params)
                    self.printV2Payload(payload, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat, fallbackText: self.v2OKSummary(payload, idFormat: ctx.idFormat, kinds: ["surface", "pane", "workspace"]))
                }
            ),

            CommandDescriptor(
                names: ["close-surface"],
                helpLines: ["close-surface [--surface <id|ref>] [--workspace <id|ref>]"],
                detailedUsage: """
                Usage: programa close-surface [flags]

                Close a surface. Defaults to the focused surface if none specified.

                Flags:
                  --surface <id|ref>     Surface to close (default: $PROGRAMA_SURFACE_ID)
                  --panel <id|ref>       Alias for --surface
                  --workspace <id|ref>   Workspace context (default: $PROGRAMA_WORKSPACE_ID)

                Example:
                  programa close-surface
                  programa close-surface --surface surface:3
                """,
                grammar: CLIArgumentGrammar(valueOptions: ["surface", "panel", "workspace"]),
                execute: { ctx in
                    let csWsFlag = self.optionValue(ctx.commandArgs, name: "--workspace")
                    let workspaceArg = csWsFlag ?? (ctx.windowId == nil ? ProcessInfo.processInfo.environment["PROGRAMA_WORKSPACE_ID"] : nil)
                    let surfaceRaw = self.optionValue(ctx.commandArgs, name: "--surface") ?? self.optionValue(ctx.commandArgs, name: "--panel")
                    var params: [String: Any] = [:]
                    let wsId = try self.normalizeWorkspaceHandle(workspaceArg, client: ctx.client)
                    if let wsId { params["workspace_id"] = wsId }
                    let sfId = try self.resolveCommandSurface(
                        explicitSurface: surfaceRaw, explicitWorkspace: csWsFlag,
                        windowId: ctx.windowId, workspaceHandle: wsId, client: ctx.client
                    )
                    if let sfId { params["surface_id"] = sfId }
                    let payload = try ctx.client.sendV2(method: "surface.close", params: params)
                    self.printV2Payload(payload, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat, fallbackText: self.v2OKSummary(payload, idFormat: ctx.idFormat))
                }
            ),

            CommandDescriptor(
                names: ["move-surface"],
                helpLines: ["move-surface --surface <id|ref> [--pane <id|ref>] [--workspace <id|ref>] [--window <id|ref>] [--before <id|ref>] [--after <id|ref>] [--index <n>] [--focus <true|false>]"],
                detailedUsage: """
                Usage: programa move-surface [--surface <id|ref> | <id|ref>] [flags]

                Move a surface to a different pane, workspace, or window.

                Flags:
                  --surface <id|ref>   Surface to move (required unless passed positionally)
                  --pane <id|ref>      Target pane
                  --workspace <id|ref> Target workspace
                  --window <id|ref>    Target window
                  --before <id|ref>    Place before this surface
                  --before-surface <id|ref>
                                           Alias for --before
                  --after <id|ref>     Place after this surface
                  --after-surface <id|ref>
                                           Alias for --after
                  --index <n>                Place at this index
                  --focus <true|false>       Focus the surface after moving

                Example:
                  programa move-surface --surface surface:1 --workspace workspace:2
                  programa move-surface surface:1 --pane pane:2 --index 0
                """,
                execute: { ctx in
                    try self.runMoveSurface(commandArgs: ctx.commandArgs, client: ctx.client, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat)
                }
            ),

            CommandDescriptor(
                names: ["reorder-surface"],
                helpLines: ["reorder-surface --surface <id|ref> (--index <n> | --before <id|ref> | --after <id|ref>)"],
                detailedUsage: """
                Usage: programa reorder-surface [--surface <id|ref> | <id|ref>] [flags]

                Reorder a surface within its pane.

                Flags:
                  --surface <id|ref>   Surface to reorder (required unless passed positionally)
                  --workspace <id|ref> Workspace context
                  --before <id|ref>    Place before this surface
                  --before-surface <id|ref>
                                           Alias for --before
                  --after <id|ref>     Place after this surface
                  --after-surface <id|ref>
                                           Alias for --after
                  --index <n>                Place at this index

                Example:
                  programa reorder-surface --surface surface:1 --index 0
                  programa reorder-surface --surface surface:3 --after surface:1
                """,
                execute: { ctx in
                    try self.runReorderSurface(commandArgs: ctx.commandArgs, client: ctx.client, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat)
                }
            ),

            CommandDescriptor(
                names: ["tab-action"],
                helpLines: ["tab-action --action <name> [--tab <id|ref>] [--surface <id|ref>] [--workspace <id|ref>] [--title <text>] [--url <url>]"],
                detailedUsage: """
                Usage: programa tab-action --action <name> [flags]

                Perform horizontal tab context-menu actions from CLI/socket.

                Actions:
                  rename | clear-name
                  close-left | close-right | close-others
                  new-terminal-right | new-browser-right
                  reload | duplicate
                  pin | unpin
                  mark-unread

                Flags:
                  --action <name>              Action name (required if not positional)
                  --tab <id|ref>         Target tab (accepts tab:<n> or surface:<n>; default: $PROGRAMA_TAB_ID, then $PROGRAMA_SURFACE_ID, then focused tab)
                  --surface <id|ref>     Alias for --tab (backward compatibility)
                  --workspace <id|ref>   Workspace context (default: current/$PROGRAMA_WORKSPACE_ID)
                  --title <text>               Title for rename (or pass trailing title text)
                  --url <url>                  Optional URL for new-browser-right

                Example:
                  programa tab-action --tab tab:3 --action pin
                  programa tab-action --action close-right
                  programa tab-action --tab tab:2 --action rename --title "build logs"
                """,
                execute: { ctx in
                    try self.runTabAction(commandArgs: ctx.commandArgs, client: ctx.client, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat, windowOverride: ctx.windowId)
                }
            ),

            CommandDescriptor(
                names: ["rename-tab"],
                helpLines: ["rename-tab [--workspace <id|ref>] [--tab <id|ref>] [--surface <id|ref>] <title>"],
                detailedUsage: """
                Usage: programa rename-tab [--workspace <id|ref>] [--tab <id|ref>] [--surface <id|ref>] [--] <title>

                Compatibility alias for tab-action rename.

                Resolution order for target tab:
                1) --tab
                2) --surface
                3) $PROGRAMA_TAB_ID / $PROGRAMA_SURFACE_ID
                4) currently focused tab (optionally within --workspace)

                Flags:
                  --workspace <id|ref>   Workspace context (default: current/$PROGRAMA_WORKSPACE_ID)
                  --tab <id|ref>         Tab target (supports tab:<n> or surface:<n>)
                  --surface <id|ref>     Alias for --tab
                  --title <text>         Explicit title (or use trailing positional title)

                Examples:
                  programa rename-tab "build logs"
                  programa rename-tab --tab tab:3 "staging server"
                  programa rename-tab --workspace workspace:2 --surface surface:5 --title "agent run"
                """,
                execute: { ctx in
                    try self.runRenameTab(commandArgs: ctx.commandArgs, client: ctx.client, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat, windowOverride: ctx.windowId)
                }
            ),

            CommandDescriptor(
                names: ["drag-surface-to-split"],
                helpLines: ["drag-surface-to-split --surface <id|ref> <left|right|up|down>"],
                detailedUsage: """
                Usage: programa drag-surface-to-split --surface <id|ref> <left|right|up|down>

                Drag a surface into a new split in the given direction.

                Flags:
                  --surface <id|ref>   Surface to drag (required)
                  --panel <id|ref>     Alias for --surface

                Example:
                  programa drag-surface-to-split --surface surface:1 right
                  programa drag-surface-to-split --panel surface:2 down
                """,
                execute: { ctx in
                    let (surfaceArg, rem0) = self.parseOption(ctx.commandArgs, name: "--surface")
                    let (panelArg, rem1) = self.parseOption(rem0, name: "--panel")
                    let surface = surfaceArg ?? panelArg
                    guard let surface else {
                        throw CLIError(message: "drag-surface-to-split requires --surface <id|ref>")
                    }
                    guard let direction = rem1.first else {
                        throw CLIError(message: "drag-surface-to-split requires a direction")
                    }
                    // v1 always targeted the currently-selected workspace (no --workspace support);
                    // leave workspace_id unset so v2 falls back to the current selection identically.
                    let surfaceIdForDrag = try self.normalizeSurfaceHandle(surface, client: ctx.client, workspaceHandle: nil)
                    var dragParams: [String: Any] = ["direction": direction]
                    if let surfaceIdForDrag { dragParams["surface_id"] = surfaceIdForDrag }
                    let dragPayload = try ctx.client.sendV2(method: "surface.drag_to_split", params: dragParams)
                    print("OK \((dragPayload["pane_id"] as? String) ?? "")")
                }
            ),

            CommandDescriptor(
                names: ["refresh-surfaces"],
                helpLines: ["refresh-surfaces"],
                detailedUsage: """
                Usage: programa refresh-surfaces

                Refresh surface snapshots for the focused workspace.
                """,
                grammar: CLIArgumentGrammar(),
                execute: { ctx in
                    // v1 always targeted the currently-selected workspace; no workspace_id here either.
                    let refreshPayload = try ctx.client.sendV2(method: "surface.refresh", params: [:])
                    print("OK Refreshed \(self.intFromAny(refreshPayload["refreshed"]) ?? 0) surfaces")
                }
            ),

            CommandDescriptor(
                names: ["reload-config"],
                helpLines: ["reload-config"],
                detailedUsage: """
                Usage: programa reload-config

                Run the same configuration reload as the Reload Configuration shortcut.
                This reloads Ghostty config, re-reads ~/.config/programa/settings.json, and refreshes terminals.

                Example:
                  programa reload-config
                """,
                grammar: CLIArgumentGrammar(),
                execute: { ctx in
                    if let unexpected = ctx.commandArgs.first {
                        throw CLIError(message: "reload-config does not accept arguments. Unexpected argument '\(unexpected)'")
                    }
                    _ = try ctx.client.sendV2(method: "app.reload_config")
                    print("OK Reloaded config")
                }
            ),

            CommandDescriptor(
                names: ["surface-health"],
                helpLines: ["surface-health [--workspace <id|ref>]"],
                detailedUsage: """
                Usage: programa surface-health [--workspace <id|ref>]

                List health details for surfaces in a workspace.

                Flags:
                  --workspace <id|ref>   Workspace context (default: $PROGRAMA_WORKSPACE_ID)

                Example:
                  programa surface-health
                  programa surface-health --workspace workspace:2
                """,
                grammar: CLIArgumentGrammar(valueOptions: ["workspace"]),
                execute: { ctx in
                    let workspaceArg = self.workspaceFromArgsOrEnv(ctx.commandArgs, windowOverride: ctx.windowId)
                    var params: [String: Any] = [:]
                    let wsId = try self.normalizeWorkspaceHandle(workspaceArg, client: ctx.client)
                    if let wsId { params["workspace_id"] = wsId }
                    let payload = try ctx.client.sendV2(method: "surface.health", params: params)
                    if ctx.jsonOutput {
                        print(self.jsonString(self.formatIDs(payload, mode: ctx.idFormat)))
                    } else {
                        let surfaces = payload["surfaces"] as? [[String: Any]] ?? []
                        if surfaces.isEmpty {
                            print("No surfaces")
                        } else {
                            for surface in surfaces {
                                let handle = self.textHandle(surface, idFormat: ctx.idFormat)
                                let sType = (surface["type"] as? String) ?? ""
                                let inWindow = surface["in_window"]
                                let inWindowStr: String
                                if let b = inWindow as? Bool {
                                    inWindowStr = " in_window=\(b)"
                                } else {
                                    inWindowStr = ""
                                }
                                print("\(handle)  type=\(sType)\(inWindowStr)")
                            }
                        }
                    }
                }
            ),

            CommandDescriptor(
                names: ["debug-terminals"],
                helpLines: [],
                detailedUsage: """
                Usage: programa debug-terminals

                Print live Ghostty terminal runtime metadata across all windows and workspaces.
                Intended for debugging stray or detached terminal views.
                """,
                grammar: CLIArgumentGrammar(),
                execute: { ctx in
                    let unexpected = ctx.commandArgs.filter { $0 != "--" }
                    if let extra = unexpected.first {
                        throw CLIError(message: "debug-terminals: unexpected argument '\(extra)'")
                    }
                    let payload = try ctx.client.sendV2(method: "debug.terminals")
                    if ctx.jsonOutput {
                        print(self.jsonString(self.formatIDs(payload, mode: ctx.idFormat)))
                    } else {
                        print(self.formatDebugTerminalsPayload(payload, idFormat: ctx.idFormat))
                    }
                }
            ),

            CommandDescriptor(
                names: ["trigger-flash"],
                helpLines: ["trigger-flash [--workspace <id|ref>] [--surface <id|ref>]"],
                detailedUsage: """
                Usage: programa trigger-flash [--workspace <id|ref>] [--surface <id|ref>] [--panel <id|ref>]

                Trigger the unread flash indicator for a surface.

                Flags:
                  --workspace <id|ref>   Workspace context (default: $PROGRAMA_WORKSPACE_ID)
                  --surface <id|ref>     Target surface (default: $PROGRAMA_SURFACE_ID)
                  --panel <id|ref>       Alias for --surface

                Example:
                  programa trigger-flash
                  programa trigger-flash --workspace workspace:2 --surface surface:3
                """,
                grammar: CLIArgumentGrammar(valueOptions: ["workspace", "surface", "panel"]),
                execute: { ctx in
                    let tfWsFlag = self.optionValue(ctx.commandArgs, name: "--workspace")
                    let explicitWorkspaceArg = tfWsFlag
                    let preferTTYFallback = ctx.windowId == nil && ProcessInfo.processInfo.environment["TMUX"] != nil
                    let callerWorkspaceArg = preferTTYFallback
                        ? nil
                        : (ctx.windowId == nil ? ProcessInfo.processInfo.environment["PROGRAMA_WORKSPACE_ID"] : nil)
                    let workspaceArg = explicitWorkspaceArg ?? callerWorkspaceArg
                    let explicitSurfaceArg = self.optionValue(ctx.commandArgs, name: "--surface") ?? self.optionValue(ctx.commandArgs, name: "--panel")
                    let callerSurfaceArg = explicitSurfaceArg == nil && preferTTYFallback == false && ctx.windowId == nil
                        ? ProcessInfo.processInfo.environment["PROGRAMA_SURFACE_ID"]
                        : nil
                    let surfaceArg = explicitSurfaceArg ?? callerSurfaceArg
                    var params: [String: Any] = [:]
                    let wsId = try {
                        if explicitWorkspaceArg != nil {
                            return try self.normalizeWorkspaceHandle(workspaceArg, client: ctx.client)
                        }
                        return try self.resolveWorkspaceIdAllowingFallback(workspaceArg, client: ctx.client)
                    }()
                    if let wsId { params["workspace_id"] = wsId }
                    let sfId = try {
                        if explicitSurfaceArg != nil {
                            return try self.normalizeSurfaceHandle(surfaceArg, client: ctx.client, workspaceHandle: wsId)
                        }
                        guard let wsId else { return nil }
                        return try self.resolveSurfaceIdAllowingFallback(
                            surfaceArg,
                            workspaceId: wsId,
                            client: ctx.client
                        )
                    }()
                    if let sfId { params["surface_id"] = sfId }
                    let payload = try ctx.client.sendV2(method: "surface.trigger_flash", params: params)
                    self.printV2Payload(payload, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat, fallbackText: self.v2OKSummary(payload, idFormat: ctx.idFormat))
                }
            ),

            CommandDescriptor(
                names: ["list-panels"],
                helpLines: ["list-panels [--workspace <id|ref>]"],
                detailedUsage: """
                Usage: programa list-panels [--workspace <id|ref>]

                List surfaces (panels) in a workspace.

                Flags:
                  --workspace <id|ref>   Workspace context (default: $PROGRAMA_WORKSPACE_ID)

                Example:
                  programa list-panels
                  programa list-panels --workspace workspace:2
                """,
                grammar: CLIArgumentGrammar(valueOptions: ["workspace"]),
                execute: { ctx in
                    let workspaceArg = self.workspaceFromArgsOrEnv(ctx.commandArgs, windowOverride: ctx.windowId)
                    var params: [String: Any] = [:]
                    let wsId = try self.normalizeWorkspaceHandle(workspaceArg, client: ctx.client)
                    if let wsId { params["workspace_id"] = wsId }
                    let payload = try ctx.client.sendV2(method: "surface.list", params: params)
                    if ctx.jsonOutput {
                        print(self.jsonString(self.formatIDs(payload, mode: ctx.idFormat)))
                    } else {
                        let surfaces = payload["surfaces"] as? [[String: Any]] ?? []
                        if surfaces.isEmpty {
                            print("No surfaces")
                        } else {
                            for surface in surfaces {
                                let focused = (surface["focused"] as? Bool) == true
                                let handle = self.textHandle(surface, idFormat: ctx.idFormat)
                                let sType = (surface["type"] as? String) ?? ""
                                let title = (surface["title"] as? String) ?? ""
                                let prefix = focused ? "* " : "  "
                                let focusTag = focused ? "  [focused]" : ""
                                let titlePart = title.isEmpty ? "" : "  \"\(title)\""
                                print("\(prefix)\(handle)  \(sType)\(focusTag)\(titlePart)")
                            }
                        }
                    }
                }
            ),

            CommandDescriptor(
                names: ["focus-panel"],
                helpLines: ["focus-panel --panel <id|ref> [--workspace <id|ref>]"],
                argumentContract: .focusPanel,
                detailedUsage: """
                Usage: programa focus-panel --panel <id|ref> [--workspace <id|ref>]

                Focus a specific panel (surface).

                Flags:
                  --panel <id|ref>       Panel/surface to focus (required)
                  --workspace <id|ref>   Workspace context (default: $PROGRAMA_WORKSPACE_ID)

                Example:
                  programa focus-panel --panel surface:2
                  programa focus-panel --panel surface:5 --workspace workspace:2
                """,
                execute: { ctx in
                    let workspaceArg = self.workspaceFromArgsOrEnv(ctx.commandArgs, windowOverride: ctx.windowId)
                    guard let panelRaw = self.optionValue(ctx.commandArgs, name: "--panel") else {
                        throw CLIError(message: "focus-panel requires --panel")
                    }
                    var params: [String: Any] = [:]
                    let wsId = try self.normalizeWorkspaceHandle(workspaceArg, client: ctx.client)
                    if let wsId { params["workspace_id"] = wsId }
                    let sfId = try self.normalizeSurfaceHandle(panelRaw, client: ctx.client, workspaceHandle: wsId)
                    if let sfId { params["surface_id"] = sfId }
                    let payload = try ctx.client.sendV2(method: "surface.focus", params: params)
                    self.printV2Payload(payload, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat, fallbackText: self.v2OKSummary(payload, idFormat: ctx.idFormat))
                }
            ),

            CommandDescriptor(
                names: ["close-workspace"],
                helpLines: ["close-workspace --workspace <id|ref>"],
                detailedUsage: """
                Usage: programa close-workspace --workspace <id|ref>

                Close the specified workspace.

                Flags:
                  --workspace <id|ref>   Workspace to close (required)

                Example:
                  programa close-workspace --workspace workspace:2
                """,
                execute: { ctx in
                    guard let workspaceRaw = self.optionValue(ctx.commandArgs, name: "--workspace") else {
                        throw CLIError(
                            message: "close-workspace: --workspace <id|ref> is required (UUID or short ref like workspace:2). Refusing to target the current workspace implicitly."
                        )
                    }
                    var params: [String: Any] = [:]
                    let wsId = try self.normalizeWorkspaceHandle(workspaceRaw, client: ctx.client)
                    if let wsId { params["workspace_id"] = wsId }
                    let payload = try ctx.client.sendV2(method: "workspace.close", params: params)
                    self.printV2Payload(payload, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat, fallbackText: self.v2OKSummary(payload, idFormat: ctx.idFormat, kinds: ["workspace"]))
                }
            ),

            CommandDescriptor(
                names: ["select-workspace"],
                helpLines: ["select-workspace --workspace <id|ref>"],
                detailedUsage: """
                Usage: programa select-workspace --workspace <id|ref>

                Select (switch to) the specified workspace.

                Flags:
                  --workspace <id|ref>   Workspace to select (required)

                Example:
                  programa select-workspace --workspace workspace:2
                  programa select-workspace --workspace 0
                """,
                execute: { ctx in
                    guard let workspaceRaw = self.optionValue(ctx.commandArgs, name: "--workspace") else {
                        throw CLIError(message: "select-workspace requires --workspace")
                    }
                    var params: [String: Any] = [:]
                    let wsId = try self.normalizeWorkspaceHandle(workspaceRaw, client: ctx.client)
                    if let wsId { params["workspace_id"] = wsId }
                    let payload = try ctx.client.sendV2(method: "workspace.select", params: params)
                    self.printV2Payload(payload, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat, fallbackText: self.v2OKSummary(payload, idFormat: ctx.idFormat, kinds: ["workspace"]))
                }
            ),

            CommandDescriptor(
                names: ["rename-workspace", "rename-window"],
                helpLines: [
                    "rename-workspace [--workspace <id|ref>] <title>",
                    "rename-window [--workspace <id|ref>] <title>",
                ],
                detailedUsage: """
                Usage: programa rename-workspace [--workspace <id|ref>] [--] <title>

                Rename a workspace. Defaults to the current workspace.
                tmux-compatible alias: rename-window

                Flags:
                  --workspace <id|ref>   Workspace to rename (default: current/$PROGRAMA_WORKSPACE_ID)

                Example:
                  programa rename-workspace "backend logs"
                  programa rename-window --workspace workspace:2 "agent run"
                """,
                grammar: CLIArgumentGrammar(valueOptions: ["workspace"], minPositionals: 1, maxPositionals: nil),
                execute: { ctx in
                    let (wsArg, rem0) = self.parseOption(ctx.commandArgs, name: "--workspace")
                    let workspaceArg = wsArg ?? (ctx.windowId == nil ? ProcessInfo.processInfo.environment["PROGRAMA_WORKSPACE_ID"] : nil)
                    let titleArgs = rem0.dropFirst(rem0.first == "--" ? 1 : 0)
                    let title = titleArgs.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !title.isEmpty else {
                        throw CLIError(message: "\(ctx.command) requires a title")
                    }
                    let wsId = try self.resolveWorkspaceId(workspaceArg, client: ctx.client)
                    let params: [String: Any] = ["title": title, "workspace_id": wsId]
                    let payload = try ctx.client.sendV2(method: "workspace.rename", params: params)
                    self.printV2Payload(payload, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat, fallbackText: self.v2OKSummary(payload, idFormat: ctx.idFormat, kinds: ["workspace"]))
                }
            ),

            CommandDescriptor(
                names: ["current-workspace"],
                helpLines: ["current-workspace"],
                detailedUsage: """
                Usage: programa current-workspace

                Print the currently selected workspace ID.
                """,
                grammar: CLIArgumentGrammar(),
                execute: { ctx in
                    let response = try ctx.client.sendV2(method: "workspace.current")
                    if ctx.jsonOutput {
                        print(self.jsonString(self.formatIDs(response, mode: ctx.idFormat)))
                    } else {
                        let handle = self.formatHandle(response, kind: "workspace", idFormat: ctx.idFormat)
                            ?? (response["workspace_id"] as? String)
                            ?? ""
                        print(handle)
                    }
                }
            ),

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

                    let payload = try ctx.client.sendV2(method: "surface.read_text", params: params)
                    if ctx.jsonOutput {
                        print(self.jsonString(payload))
                    } else {
                        print((payload["text"] as? String) ?? "")
                    }
                }
            ),

            CommandDescriptor(
                names: ["wait-surface"],
                helpLines: ["wait-surface [--workspace <id|ref>] [--surface <id|ref>] (--pattern <regex> | --exit) [--timeout <seconds>] [--lines <n>]"],
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
                  --timeout <seconds>    Give up after this long (default: 30)
                  --lines <n>            Cap how much scrollback --pattern rereads per check (default: 2000)

                Exactly one of --pattern / --exit is required. A marker already present when the
                call arrives (or a process that has already exited) resolves immediately --
                `waited: false` in JSON output distinguishes that from an actual wait.

                Example:
                  programa wait-surface --pattern 'BUILD (SUCCEEDED|FAILED)' --timeout 120
                  programa wait-surface --surface surface:2 --exit --timeout 10
                """,
                execute: { ctx in
                    let (wsArg, rem0) = self.parseOption(ctx.commandArgs, name: "--workspace")
                    let (sfArg, rem1) = self.parseOption(rem0, name: "--surface")
                    let (patternArg, rem2) = self.parseOption(rem1, name: "--pattern")
                    let (timeoutArg, rem3) = self.parseOption(rem2, name: "--timeout")
                    let (linesArg, rem4) = self.parseOption(rem3, name: "--lines")
                    let exitFlag = rem4.contains("--exit")
                    let trailing = rem4.filter { $0 != "--exit" }
                    if !trailing.isEmpty {
                        throw CLIError(message: "wait-surface: unexpected arguments: \(trailing.joined(separator: " "))")
                    }
                    guard (patternArg != nil) != exitFlag else {
                        throw CLIError(message: "wait-surface requires exactly one of --pattern <regex> or --exit")
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
                        method: "surface.wait",
                        params: params,
                        minimumReceiveTimeout: timeoutSeconds + 5.0
                    )
                    if ctx.jsonOutput {
                        print(self.jsonString(payload))
                    } else if let match = payload["match"] as? String {
                        print(match)
                    } else if exitFlag {
                        print("exited")
                    } else {
                        print("ok")
                    }
                }
            ),

            CommandDescriptor(
                names: ["prompt-agent"],
                helpLines: ["prompt-agent [--workspace <id|ref>] [--surface <id|ref>] [--timeout <seconds>] [--working-grace <seconds>] <text>"],
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

                Flags:
                  --workspace <id|ref>      Target workspace (default: $PROGRAMA_WORKSPACE_ID)
                  --surface <id|ref>        Target surface (default: $PROGRAMA_SURFACE_ID)
                  --timeout <seconds>       Overall budget for the agent to finish (default: 120)
                  --working-grace <seconds> How long to wait for a "working" report before
                                            giving up on observing it, capped by the remaining
                                            --timeout budget (default: 3)

                Example:
                  programa prompt-agent "review this diff for bugs"
                  programa prompt-agent --surface surface:2 --timeout 300 "run the test suite"
                """,
                grammar: CLIArgumentGrammar(valueOptions: ["workspace", "surface", "timeout", "working-grace"], minPositionals: 1, maxPositionals: nil),
                execute: { ctx in
                    let (wsArg, rem0) = self.parseOption(ctx.commandArgs, name: "--workspace")
                    let (sfArg, rem1) = self.parseOption(rem0, name: "--surface")
                    let (timeoutArg, rem2) = self.parseOption(rem1, name: "--timeout")
                    let (graceArg, rem3) = self.parseOption(rem2, name: "--working-grace")
                    let workspaceArg = wsArg ?? (ctx.windowId == nil ? ProcessInfo.processInfo.environment["PROGRAMA_WORKSPACE_ID"] : nil)
                    let rawText = rem3.dropFirst(rem3.first == "--" ? 1 : 0).joined(separator: " ")
                    guard !rawText.isEmpty else { throw CLIError(message: "prompt-agent requires text") }

                    var params: [String: Any] = ["text": rawText]
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
                    let payload = try ctx.client.sendV2(
                        method: "agent.prompt",
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
                helpLines: ["watch-events [--agent-state] [--workspace-lifecycle] [--output <surface_id[,surface_id...]>] [--no-reconnect]"],
                argumentContract: .watchEvents,
                detailedUsage: """
                Usage: programa watch-events [flags]

                Subscribe to a long-lived stream of pushed events (#167) -- for consumers
                that need many events over time (dashboards, orchestrators, a menu bar on
                another machine). Casual "wait for one thing" callers should use
                `wait-surface`/`prompt-agent` instead; this command holds the connection
                open indefinitely and prints one JSON event per line until interrupted
                (Ctrl-C) or the process gives up reconnecting.

                Flags (at least one of --agent-state/--workspace-lifecycle/--output required):
                  --agent-state                    Agent working/blocked/idle transitions
                  --workspace-lifecycle             Workspace created/closed/renamed
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
                """,
                execute: { ctx in
                    let agentState = self.hasFlag(ctx.commandArgs, name: "--agent-state")
                    let workspaceLifecycle = self.hasFlag(ctx.commandArgs, name: "--workspace-lifecycle")
                    let noReconnect = self.hasFlag(ctx.commandArgs, name: "--no-reconnect")
                    let (outputArg, _) = self.parseOption(ctx.commandArgs, name: "--output")

                    var classes: [String] = []
                    if agentState { classes.append("agent_state") }
                    if workspaceLifecycle { classes.append("workspace_lifecycle") }

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
                        try ctx.client.sendV2RequestOnly(method: "subscribe", params: params)
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
                    // auth_required/auth_unconfigured), the cmux-ancestry "unsafe socket"
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
                    // restores the historical exit-on-drop behavior for scripts that want to
                    // observe and handle drops themselves.
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
                helpLines: ["send [--workspace <id|ref>] [--surface <id|ref>] <text>"],
                detailedUsage: """
                Usage: programa send [flags] [--] <text>

                Send text to a terminal surface. Escape sequences: \\n and \\r send Enter, \\t sends Tab.

                Flags:
                  --workspace <id|ref>   Target workspace (default: $PROGRAMA_WORKSPACE_ID)
                  --surface <id|ref>     Target surface (default: $PROGRAMA_SURFACE_ID)

                Example:
                  programa send "echo hello"
                  programa send --surface surface:2 "ls -la\\n"
                """,
                grammar: CLIArgumentGrammar(valueOptions: ["workspace", "surface"], minPositionals: 1, maxPositionals: nil),
                execute: { ctx in
                    let (wsArg, rem0) = self.parseOption(ctx.commandArgs, name: "--workspace")
                    let (sfArg, rem1) = self.parseOption(rem0, name: "--surface")
                    let workspaceArg = wsArg ?? (ctx.windowId == nil ? ProcessInfo.processInfo.environment["PROGRAMA_WORKSPACE_ID"] : nil)
                    let rawText = rem1.dropFirst(rem1.first == "--" ? 1 : 0).joined(separator: " ")
                    guard !rawText.isEmpty else { throw CLIError(message: "send requires text") }
                    let text = self.unescapeSendText(rawText)
                    var params: [String: Any] = ["text": text]
                    let wsId = try self.normalizeWorkspaceHandle(workspaceArg, client: ctx.client)
                    if let wsId { params["workspace_id"] = wsId }
                    let sfId = try self.resolveCommandSurface(
                        explicitSurface: sfArg, explicitWorkspace: wsArg,
                        windowId: ctx.windowId, workspaceHandle: wsId, client: ctx.client
                    )
                    if let sfId { params["surface_id"] = sfId }
                    let payload = try ctx.client.sendV2(method: "surface.send_text", params: params)
                    self.printV2Payload(payload, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat, fallbackText: self.v2OKSummary(payload, idFormat: ctx.idFormat))
                }
            ),

            CommandDescriptor(
                names: ["send-key"],
                helpLines: ["send-key [--workspace <id|ref>] [--surface <id|ref>] <key>"],
                detailedUsage: """
                Usage: programa send-key [flags] [--] <key>

                Send a key event to a terminal surface.

                Flags:
                  --workspace <id|ref>   Target workspace (default: $PROGRAMA_WORKSPACE_ID)
                  --surface <id|ref>     Target surface (default: $PROGRAMA_SURFACE_ID)

                Example:
                  programa send-key enter
                  programa send-key --surface surface:2 ctrl+c
                """,
                grammar: CLIArgumentGrammar(valueOptions: ["workspace", "surface"], minPositionals: 1, maxPositionals: 1),
                execute: { ctx in
                    let (wsArg, rem0) = self.parseOption(ctx.commandArgs, name: "--workspace")
                    let (sfArg, rem1) = self.parseOption(rem0, name: "--surface")
                    let workspaceArg = wsArg ?? (ctx.windowId == nil ? ProcessInfo.processInfo.environment["PROGRAMA_WORKSPACE_ID"] : nil)
                    let keyArgs = rem1.first == "--" ? Array(rem1.dropFirst()) : rem1
                    guard let key = keyArgs.first else { throw CLIError(message: "send-key requires a key") }
                    var params: [String: Any] = ["key": key]
                    let wsId = try self.normalizeWorkspaceHandle(workspaceArg, client: ctx.client)
                    if let wsId { params["workspace_id"] = wsId }
                    let sfId = try self.resolveCommandSurface(
                        explicitSurface: sfArg, explicitWorkspace: wsArg,
                        windowId: ctx.windowId, workspaceHandle: wsId, client: ctx.client
                    )
                    if let sfId { params["surface_id"] = sfId }
                    let payload = try ctx.client.sendV2(method: "surface.send_key", params: params)
                    self.printV2Payload(payload, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat, fallbackText: self.v2OKSummary(payload, idFormat: ctx.idFormat))
                }
            ),

            CommandDescriptor(
                names: ["send-panel"],
                helpLines: ["send-panel --panel <id|ref> [--workspace <id|ref>] <text>"],
                detailedUsage: """
                Usage: programa send-panel --panel <id|ref> [flags] [--] <text>

                Send text to a specific panel (surface). Escape sequences: \\n and \\r send Enter, \\t sends Tab.

                Flags:
                  --panel <id|ref>       Target panel (required)
                  --workspace <id|ref>   Target workspace (default: $PROGRAMA_WORKSPACE_ID)

                Example:
                  programa send-panel --panel surface:2 "echo hello\\n"
                """,
                grammar: CLIArgumentGrammar(valueOptions: ["panel", "workspace"], requiredOptions: ["panel"], minPositionals: 1, maxPositionals: nil),
                execute: { ctx in
                    let (wsArg, rem0) = self.parseOption(ctx.commandArgs, name: "--workspace")
                    let (panelArg, rem1) = self.parseOption(rem0, name: "--panel")
                    let workspaceArg = wsArg ?? (ctx.windowId == nil ? ProcessInfo.processInfo.environment["PROGRAMA_WORKSPACE_ID"] : nil)
                    guard let panelArg else {
                        throw CLIError(message: "send-panel requires --panel")
                    }
                    let rawText = rem1.dropFirst(rem1.first == "--" ? 1 : 0).joined(separator: " ")
                    guard !rawText.isEmpty else { throw CLIError(message: "send-panel requires text") }
                    let text = self.unescapeSendText(rawText)
                    var params: [String: Any] = ["text": text]
                    let wsId = try self.normalizeWorkspaceHandle(workspaceArg, client: ctx.client)
                    if let wsId { params["workspace_id"] = wsId }
                    let sfId = try self.normalizeSurfaceHandle(panelArg, client: ctx.client, workspaceHandle: wsId)
                    if let sfId { params["surface_id"] = sfId }
                    let payload = try ctx.client.sendV2(method: "surface.send_text", params: params)
                    self.printV2Payload(payload, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat, fallbackText: self.v2OKSummary(payload, idFormat: ctx.idFormat))
                }
            ),

            CommandDescriptor(
                names: ["send-key-panel"],
                helpLines: ["send-key-panel --panel <id|ref> [--workspace <id|ref>] <key>"],
                detailedUsage: """
                Usage: programa send-key-panel --panel <id|ref> [flags] [--] <key>

                Send a key event to a specific panel (surface).

                Flags:
                  --panel <id|ref>       Target panel (required)
                  --workspace <id|ref>   Target workspace (default: $PROGRAMA_WORKSPACE_ID)

                Example:
                  programa send-key-panel --panel surface:2 enter
                  programa send-key-panel --panel surface:2 ctrl+c
                """,
                grammar: CLIArgumentGrammar(valueOptions: ["panel", "workspace"], requiredOptions: ["panel"], minPositionals: 1, maxPositionals: 1),
                execute: { ctx in
                    let (wsArg, rem0) = self.parseOption(ctx.commandArgs, name: "--workspace")
                    let (panelArg, rem1) = self.parseOption(rem0, name: "--panel")
                    let workspaceArg = wsArg ?? (ctx.windowId == nil ? ProcessInfo.processInfo.environment["PROGRAMA_WORKSPACE_ID"] : nil)
                    guard let panelArg else {
                        throw CLIError(message: "send-key-panel requires --panel")
                    }
                    let skpArgs = rem1.first == "--" ? Array(rem1.dropFirst()) : rem1
                    let key = skpArgs.first ?? ""
                    guard !key.isEmpty else { throw CLIError(message: "send-key-panel requires a key") }
                    var params: [String: Any] = ["key": key]
                    let wsId = try self.normalizeWorkspaceHandle(workspaceArg, client: ctx.client)
                    if let wsId { params["workspace_id"] = wsId }
                    let sfId = try self.normalizeSurfaceHandle(panelArg, client: ctx.client, workspaceHandle: wsId)
                    if let sfId { params["surface_id"] = sfId }
                    let payload = try ctx.client.sendV2(method: "surface.send_key", params: params)
                    self.printV2Payload(payload, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat, fallbackText: self.v2OKSummary(payload, idFormat: ctx.idFormat))
                }
            ),

            CommandDescriptor(
                names: ["notify"],
                helpLines: ["notify --title <text> [--subtitle <text>] [--body <text>] [--workspace <id|ref>] [--surface <id|ref>]"],
                detailedUsage: """
                Usage: programa notify [flags]

                Send a notification to a workspace/surface.

                Flags:
                  --title <text>         Notification title (default: "Notification")
                  --subtitle <text>      Notification subtitle
                  --body <text>          Notification body
                  --workspace <id|ref>   Target workspace (default: $PROGRAMA_WORKSPACE_ID)
                  --surface <id|ref>     Target surface (default: $PROGRAMA_SURFACE_ID)

                Example:
                  programa notify --title "Build done" --body "All tests passed"
                  programa notify --title "Error" --subtitle "test.swift" --body "Line 42: syntax error"
                """,
                grammar: CLIArgumentGrammar(valueOptions: ["title", "subtitle", "body", "workspace", "surface"]),
                execute: { ctx in
                    let title = self.optionValue(ctx.commandArgs, name: "--title") ?? "Notification"
                    let subtitle = self.optionValue(ctx.commandArgs, name: "--subtitle") ?? ""
                    let body = self.optionValue(ctx.commandArgs, name: "--body") ?? ""

                    let explicitWorkspaceArg = self.optionValue(ctx.commandArgs, name: "--workspace")
                    let preferTTYFallback = ctx.windowId == nil && ProcessInfo.processInfo.environment["TMUX"] != nil
                    let callerWorkspaceArg = preferTTYFallback
                        ? nil
                        : (ctx.windowId == nil ? ProcessInfo.processInfo.environment["PROGRAMA_WORKSPACE_ID"] : nil)
                    let workspaceArg = explicitWorkspaceArg ?? callerWorkspaceArg
                    let explicitSurfaceArg = self.optionValue(ctx.commandArgs, name: "--surface")
                    let callerSurfaceArg = explicitSurfaceArg == nil && workspaceArg == nil && preferTTYFallback == false && ctx.windowId == nil
                        ? ProcessInfo.processInfo.environment["PROGRAMA_SURFACE_ID"]
                        : nil
                    let surfaceArg = explicitSurfaceArg ?? callerSurfaceArg

                    let targetWorkspace = try {
                        if explicitWorkspaceArg != nil {
                            return try self.resolveWorkspaceId(workspaceArg, client: ctx.client)
                        }
                        return try self.resolveWorkspaceIdAllowingFallback(workspaceArg, client: ctx.client)
                    }()
                    let targetSurface = try {
                        if explicitSurfaceArg != nil {
                            return try self.resolveSurfaceId(surfaceArg, workspaceId: targetWorkspace, client: ctx.client)
                        }
                        return try self.resolveSurfaceIdAllowingFallback(
                            surfaceArg,
                            workspaceId: targetWorkspace,
                            client: ctx.client
                        )
                    }()

                    _ = try ctx.client.sendV2(method: "notification.create_for_target", params: [
                        "workspace_id": targetWorkspace,
                        "surface_id": targetSurface,
                        "title": title,
                        "subtitle": subtitle,
                        "body": body,
                    ])
                    print("OK")
                }
            ),

            CommandDescriptor(
                names: ["list-notifications"],
                helpLines: ["list-notifications"],
                detailedUsage: """
                Usage: programa list-notifications

                List queued notifications.
                """,
                grammar: CLIArgumentGrammar(),
                execute: { ctx in
                    let listed = try ctx.client.sendV2(method: "notification.list")
                    let notifications = listed["notifications"] as? [[String: Any]] ?? []
                    if ctx.jsonOutput {
                        let payload = notifications.enumerated().map { _, item -> [String: Any] in
                            var dict: [String: Any] = [
                                "id": (item["id"] as? String) ?? "",
                                "workspace_id": (item["workspace_id"] as? String) ?? "",
                                "is_read": (item["is_read"] as? Bool) ?? false,
                                "title": (item["title"] as? String) ?? "",
                                "subtitle": (item["subtitle"] as? String) ?? "",
                                "body": (item["body"] as? String) ?? "",
                            ]
                            dict["surface_id"] = item["surface_id"] as? String ?? NSNull()
                            return dict
                        }
                        print(self.jsonString(payload))
                    } else if notifications.isEmpty {
                        print("No notifications")
                    } else {
                        let lines = notifications.enumerated().map { index, item -> String in
                            let surfaceText = (item["surface_id"] as? String) ?? "none"
                            let readText = ((item["is_read"] as? Bool) ?? false) ? "read" : "unread"
                            let id = (item["id"] as? String) ?? ""
                            let workspaceId = (item["workspace_id"] as? String) ?? ""
                            let title = (item["title"] as? String) ?? ""
                            let subtitle = (item["subtitle"] as? String) ?? ""
                            let body = (item["body"] as? String) ?? ""
                            return "\(index):\(id)|\(workspaceId)|\(surfaceText)|\(readText)|\(title)|\(subtitle)|\(body)"
                        }
                        print(lines.joined(separator: "\n"))
                    }
                }
            ),

            CommandDescriptor(
                names: ["clear-notifications"],
                helpLines: ["clear-notifications"],
                detailedUsage: """
                Usage: programa clear-notifications

                Clear all queued notifications.
                """,
                grammar: CLIArgumentGrammar(valueOptions: ["workspace"]),
                execute: { ctx in
                    if let wsFlag = self.optionValue(ctx.commandArgs, name: "--workspace") {
                        let wsId = try self.resolveWorkspaceId(wsFlag, client: ctx.client)
                        _ = try ctx.client.sendV2(method: "notification.clear", params: ["workspace_id": wsId])
                    } else if ctx.windowId == nil,
                              let envWs = ProcessInfo.processInfo.environment["PROGRAMA_WORKSPACE_ID"],
                              let wsId = try? self.resolveWorkspaceId(envWs, client: ctx.client) {
                        _ = try ctx.client.sendV2(method: "notification.clear", params: ["workspace_id": wsId])
                    } else {
                        _ = try ctx.client.sendV2(method: "notification.clear")
                    }
                    print("OK")
                }
            ),

            CommandDescriptor(
                names: ["set-status"],
                helpLines: [],
                detailedUsage: """
                Usage: programa set-status <key> <value> [flags]

                Set a sidebar status entry for a workspace. Status entries appear as
                pills in the sidebar tab row. Use a unique key so different tools
                (e.g. "claude_code", "build") can manage their own entries.

                Flags:
                  --icon <name>          Icon name (e.g. "sparkle", "hammer")
                  --color <#hex>         Pill color (e.g. "#ff9500")
                  --workspace <id|ref>   Target workspace (default: $PROGRAMA_WORKSPACE_ID)

                Example:
                  programa set-status build "compiling" --icon hammer --color "#ff9500"
                  programa set-status deploy "v1.2.3" --workspace workspace:2
                """,
                execute: { ctx in
                    let parsed = self.parseFlagArgs(ctx.commandArgs, stopAtDashDash: false)
                    guard parsed.positional.count >= 2 else {
                        throw CLIError(message: "ERROR: Missing status key or value — usage: set_status <key> <value> [--icon=X] [--color=#hex] [--url=X] [--priority=N] [--format=plain|markdown] [--tab=X]")
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
                    _ = try ctx.client.sendV2(method: "workspace.set_status", params: params)
                    print("OK")
                }
            ),

            CommandDescriptor(
                names: ["clear-status"],
                helpLines: [],
                detailedUsage: """
                Usage: programa clear-status <key> [flags]

                Remove a sidebar status entry by key.

                Flags:
                  --workspace <id|ref>   Target workspace (default: $PROGRAMA_WORKSPACE_ID)

                Example:
                  programa clear-status build
                """,
                grammar: CLIArgumentGrammar(valueOptions: ["workspace"], minPositionals: 1, maxPositionals: 1, allowEquals: true),
                execute: { ctx in
                    let parsed = self.parseFlagArgs(ctx.commandArgs)
                    guard let key = parsed.positional.first, parsed.positional.count == 1 else {
                        throw CLIError(message: "ERROR: Missing metadata key — usage: clear_status <key> [--tab=X]")
                    }
                    let workspaceId = try self.resolveSidebarWorkspaceId(options: parsed.options, windowOverride: ctx.windowId, client: ctx.client)
                    _ = try ctx.client.sendV2(method: "workspace.clear_status", params: ["workspace_id": workspaceId, "key": key])
                    print("OK")
                }
            ),

            CommandDescriptor(
                names: ["list-status"],
                helpLines: [],
                detailedUsage: """
                Usage: programa list-status [flags]

                List all sidebar status entries for a workspace.

                Flags:
                  --workspace <id|ref>   Target workspace (default: $PROGRAMA_WORKSPACE_ID)

                Example:
                  programa list-status
                  programa list-status --workspace workspace:2
                """,
                grammar: CLIArgumentGrammar(valueOptions: ["workspace"], allowEquals: true),
                execute: { ctx in
                    let parsed = self.parseFlagArgs(ctx.commandArgs)
                    let workspaceId = try self.resolveSidebarWorkspaceId(options: parsed.options, windowOverride: ctx.windowId, client: ctx.client)
                    let payload = try ctx.client.sendV2(method: "workspace.list_status", params: ["workspace_id": workspaceId])
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
                helpLines: [],
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
                        throw CLIError(message: "ERROR: Missing progress value — usage: set_progress <0.0-1.0> [--label=X] [--tab=X]")
                    }
                    guard let value = Double(first), value.isFinite else {
                        throw CLIError(message: "ERROR: Invalid progress value '\(first)' — must be 0.0 to 1.0")
                    }
                    var params: [String: Any] = ["value": min(1.0, max(0.0, value))]
                    if let label = self.normalizedFlagValue(parsed.options["label"]) { params["label"] = label }
                    params["workspace_id"] = try self.resolveSidebarWorkspaceId(options: parsed.options, windowOverride: ctx.windowId, client: ctx.client)
                    _ = try ctx.client.sendV2(method: "workspace.set_progress", params: params)
                    print("OK")
                }
            ),

            CommandDescriptor(
                names: ["clear-progress"],
                helpLines: [],
                detailedUsage: """
                Usage: programa clear-progress [flags]

                Clear the sidebar progress bar for a workspace.

                Flags:
                  --workspace <id|ref>   Target workspace (default: $PROGRAMA_WORKSPACE_ID)

                Example:
                  programa clear-progress
                """,
                grammar: CLIArgumentGrammar(valueOptions: ["workspace"], allowEquals: true),
                execute: { ctx in
                    let parsed = self.parseFlagArgs(ctx.commandArgs)
                    let workspaceId = try self.resolveSidebarWorkspaceId(options: parsed.options, windowOverride: ctx.windowId, client: ctx.client)
                    _ = try ctx.client.sendV2(method: "workspace.clear_progress", params: ["workspace_id": workspaceId])
                    print("OK")
                }
            ),

            CommandDescriptor(
                names: ["log"],
                helpLines: [],
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
                execute: { ctx in
                    let parsed = self.parseFlagArgs(ctx.commandArgs)
                    guard !parsed.positional.isEmpty else {
                        throw CLIError(message: "ERROR: Missing message — usage: log [--level=X] [--source=X] [--tab=X] -- <message>")
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
                    _ = try ctx.client.sendV2(method: "workspace.log", params: params)
                    print("OK")
                }
            ),

            CommandDescriptor(
                names: ["clear-log"],
                helpLines: [],
                detailedUsage: """
                Usage: programa clear-log [flags]

                Clear all sidebar log entries for a workspace.

                Flags:
                  --workspace <id|ref>   Target workspace (default: $PROGRAMA_WORKSPACE_ID)

                Example:
                  programa clear-log
                """,
                grammar: CLIArgumentGrammar(valueOptions: ["workspace"], allowEquals: true),
                execute: { ctx in
                    let parsed = self.parseFlagArgs(ctx.commandArgs)
                    let workspaceId = try self.resolveSidebarWorkspaceId(options: parsed.options, windowOverride: ctx.windowId, client: ctx.client)
                    _ = try ctx.client.sendV2(method: "workspace.clear_log", params: ["workspace_id": workspaceId])
                    print("OK")
                }
            ),

            CommandDescriptor(
                names: ["list-log"],
                helpLines: [],
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
                            throw CLIError(message: "ERROR: Missing limit value — usage: list_log [--limit=N] [--tab=X]")
                        }
                        guard let limit = Int(limitStr), limit >= 0 else {
                            throw CLIError(message: "ERROR: Invalid limit '\(limitStr)' — must be >= 0")
                        }
                        params["limit"] = limit
                    }
                    params["workspace_id"] = try self.resolveSidebarWorkspaceId(options: parsed.options, windowOverride: ctx.windowId, client: ctx.client)
                    let payload = try ctx.client.sendV2(method: "workspace.list_log", params: params)
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
                helpLines: [],
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
                grammar: CLIArgumentGrammar(valueOptions: ["workspace"], allowEquals: true),
                execute: { ctx in
                    let parsed = self.parseFlagArgs(ctx.commandArgs)
                    let workspaceId = try self.resolveSidebarWorkspaceId(options: parsed.options, windowOverride: ctx.windowId, client: ctx.client)
                    let payload = try ctx.client.sendV2(method: "workspace.sidebar_state", params: ["workspace_id": workspaceId])
                    print(self.sidebarStateText(payload))
                }
            ),

            ]
        descriptors += self.hooksDescriptors()
        descriptors += [

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
                    _ = try ctx.client.sendV2(method: "app.focus_override.set", params: ["state": state])
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
                    _ = try ctx.client.sendV2(method: "app.simulate_active")
                    print("OK")
                }
            ),

            CommandDescriptor(
                names: ["__tmux-compat"],
                helpLines: [],
                helpPolicy: .passthrough,
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

            // MARK: - tmux compatibility commands (all share one bespoke
            // handler; help text preserves the original grouped layout,
            // including the two pipe-separated combo lines).
            CommandDescriptor(names: [], helpLines: ["", "# tmux compatibility commands"], execute: nil),
        ]
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
        descriptors += [
            CommandDescriptor(names: [], helpLines: [""], execute: nil),

            CommandDescriptor(
                names: ["markdown"],
                helpLines: ["markdown [open] <path>             (open markdown file in formatted viewer panel with live reload)"],
                execute: { ctx in
                    try self.runMarkdownCommand(commandArgs: ctx.commandArgs, client: ctx.client, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat)
                }
            ),

            CommandDescriptor(
                names: ["review"],
                helpLines: ["review open|refresh|comment|send  (agent diff review panel: worktree/branch diff, line comments)"],
                execute: { ctx in
                    try self.runReviewCommand(commandArgs: ctx.commandArgs, client: ctx.client, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat)
                }
            ),

            CommandDescriptor(
                names: ["recap"],
                helpLines: ["recap open <slug>|list             (open/list saved recaps in .programa/recaps/)"],
                execute: { ctx in
                    try self.runRecapCommand(commandArgs: ctx.commandArgs, client: ctx.client, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat)
                }
            ),

            CommandDescriptor(names: [], helpLines: [""], execute: nil),

            CommandDescriptor(
                names: ["browser"],
                helpLines: [
                    "browser [--surface <id|ref> | <surface>] <subcommand> ...",
                    "browser open [url]                   (create browser split in caller's workspace; if surface supplied, behaves like navigate)",
                    "browser open-split [url]",
                    "browser goto|navigate <url> [--snapshot-after]",
                    "browser back|forward|reload [--snapshot-after]",
                    "browser url|get-url",
                    "browser snapshot [--interactive|-i] [--cursor] [--compact] [--max-depth <n>] [--selector <css>]",
                    "browser eval <script>",
                    "browser wait [--selector <css>] [--text <text>] [--url-contains <text>] [--load-state <interactive|complete>] [--function <js>] [--timeout-ms <ms>]",
                    "browser click|dblclick|hover|focus|check|uncheck|scroll-into-view <selector> [--snapshot-after]",
                    "browser type <selector> <text> [--snapshot-after]",
                    "browser fill <selector> [text] [--snapshot-after]   (empty text clears input)",
                    "browser press|keydown|keyup <key> [--snapshot-after]",
                    "browser select <selector> <value> [--snapshot-after]",
                    "browser scroll [--selector <css>] [--dx <n>] [--dy <n>] [--snapshot-after]",
                    "browser screenshot [--out <path>] [--json]",
                    "browser get <url|title|text|html|value|attr|count|box|styles> [...]",
                    "browser is <visible|enabled|checked> <selector>",
                    "browser find <role|text|label|placeholder|alt|title|testid|first|last|nth> ...",
                    "browser frame <selector|main>",
                    "browser dialog <accept|dismiss> [text]",
                    "browser download [wait] [--path <path>] [--timeout-ms <ms>]",
                    "browser cookies <get|set|clear> [...]",
                    "browser storage <local|session> <get|set|clear> [...]",
                    "browser tab <new|list|switch|close|<index>> [...]",
                    "browser console <list|clear>",
                    "browser errors <list|clear>",
                    "browser highlight <selector>",
                    "browser state <save|load> <path>",
                    "browser addinitscript <script>",
                    "browser addscript <script>",
                    "browser addstyle <css>",
                    "browser identify [--surface <id|ref>]",
                ],
                execute: { ctx in
                    try self.runBrowserCommand(commandArgs: ctx.commandArgs, client: ctx.client, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat)
                }
            ),

            // Legacy aliases shimmed onto the v2 browser command surface.
            // Undocumented in the old help text; kept that way here too.
            CommandDescriptor(
                names: ["open-browser"],
                helpLines: [],
                execute: { ctx in
                    try self.runBrowserCommand(commandArgs: ["open"] + ctx.commandArgs, client: ctx.client, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat)
                }
            ),
            CommandDescriptor(
                names: ["navigate"],
                helpLines: [],
                execute: { ctx in
                    let bridged = self.replaceToken(ctx.commandArgs, from: "--panel", to: "--surface")
                    try self.runBrowserCommand(commandArgs: ["navigate"] + bridged, client: ctx.client, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat)
                }
            ),
            CommandDescriptor(
                names: ["browser-back"],
                helpLines: [],
                execute: { ctx in
                    let bridged = self.replaceToken(ctx.commandArgs, from: "--panel", to: "--surface")
                    try self.runBrowserCommand(commandArgs: ["back"] + bridged, client: ctx.client, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat)
                }
            ),
            CommandDescriptor(
                names: ["browser-forward"],
                helpLines: [],
                execute: { ctx in
                    let bridged = self.replaceToken(ctx.commandArgs, from: "--panel", to: "--surface")
                    try self.runBrowserCommand(commandArgs: ["forward"] + bridged, client: ctx.client, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat)
                }
            ),
            CommandDescriptor(
                names: ["browser-reload"],
                helpLines: [],
                execute: { ctx in
                    let bridged = self.replaceToken(ctx.commandArgs, from: "--panel", to: "--surface")
                    try self.runBrowserCommand(commandArgs: ["reload"] + bridged, client: ctx.client, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat)
                }
            ),
            CommandDescriptor(
                names: ["get-url"],
                helpLines: [],
                execute: { ctx in
                    let bridged = self.replaceToken(ctx.commandArgs, from: "--panel", to: "--surface")
                    try self.runBrowserCommand(commandArgs: ["get-url"] + bridged, client: ctx.client, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat)
                }
            ),
            CommandDescriptor(
                names: ["focus-webview"],
                helpLines: [],
                execute: { ctx in
                    let bridged = self.replaceToken(ctx.commandArgs, from: "--panel", to: "--surface")
                    try self.runBrowserCommand(commandArgs: ["focus-webview"] + bridged, client: ctx.client, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat)
                }
            ),
            CommandDescriptor(
                names: ["is-webview-focused"],
                helpLines: [],
                execute: { ctx in
                    let bridged = self.replaceToken(ctx.commandArgs, from: "--panel", to: "--surface")
                    try self.runBrowserCommand(commandArgs: ["is-webview-focused"] + bridged, client: ctx.client, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat)
                }
            ),

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

    func sanitizedFilenameComponent(_ raw: String) -> String {
        let sanitized = raw.replacingOccurrences(
            of: #"[^\p{L}\p{N}._-]+"#,
            with: "-",
            options: .regularExpression
        )
        let trimmed = sanitized.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return trimmed.isEmpty ? "item" : trimmed
    }

    func bestEffortPruneTemporaryFiles(
        in directoryURL: URL,
        keepingMostRecent maxCount: Int = 50,
        maxAge: TimeInterval = 24 * 60 * 60
    ) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let now = Date()
        let datedEntries = entries.compactMap { url -> (url: URL, date: Date)? in
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .creationDateKey]),
                  values.isRegularFile == true else {
                return nil
            }
            return (url, values.contentModificationDate ?? values.creationDate ?? .distantPast)
        }.sorted { $0.date > $1.date }

        for (index, entry) in datedEntries.enumerated() {
            if index >= maxCount || now.timeIntervalSince(entry.date) > maxAge {
                try? FileManager.default.removeItem(at: entry.url)
            }
        }
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
    func openPath(_ path: String, socketPath: String) throws {
        let resolved = resolvePath(path)
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir)

        let directory: String
        if exists && isDir.boolValue {
            directory = resolved
        } else if exists {
            // It's a file; use its parent directory
            directory = (resolved as NSString).deletingLastPathComponent
        } else {
            throw CLIError(message: "Path does not exist: \(resolved)")
        }

        // Try connecting to the socket. If it fails, launch the app and retry.
        let client = SocketClient(path: socketPath)
        if (try? client.connect()) == nil {
            client.close()
            try launchApp()
            let launchedClient = try SocketClient.waitForConnectableSocket(path: socketPath, timeout: 10)
            defer { launchedClient.close() }
            let params: [String: Any] = ["cwd": directory]
            let response = try launchedClient.sendV2(method: "workspace.create", params: params)
            let wsRef = (response["workspace_ref"] as? String) ?? (response["workspace_id"] as? String) ?? ""
            if !wsRef.isEmpty {
                print("OK \(wsRef)")
            }
            try activateApp()
            return
        }
        defer { client.close() }

        let params: [String: Any] = ["cwd": directory]
        let response = try client.sendV2(method: "workspace.create", params: params)
        let wsRef = (response["workspace_ref"] as? String) ?? (response["workspace_id"] as? String) ?? ""
        if !wsRef.isEmpty {
            print("OK \(wsRef)")
        }

        // Bring the app to front
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
            let response = try client.sendV2(method: "feedback.open", params: params)
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
        let response = try client.sendV2(method: "feedback.submit", params: [
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

        let response = try client.sendV2(method: "settings.open", params: [
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
            _ = try client.sendV2(method: "auth.login", params: ["password": socketPassword])
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

    private func parsePositiveInt(_ raw: String?, label: String) throws -> Int? {
        guard let raw else { return nil }
        guard let value = Int(raw) else {
            throw CLIError(message: "\(label) must be an integer")
        }
        return value
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
            let current = try client.sendV2(method: "window.current")
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
            let current = try client.sendV2(method: "workspace.current")
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
            let ident = try client.sendV2(method: "system.identify")
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
            let ident = try client.sendV2(method: "system.identify")
            let focused = ident["focused"] as? [String: Any] ?? [:]
            return (focused["surface_ref"] as? String) ?? (focused["surface_id"] as? String)
        }
    }

    private func resolveCommandSurface(
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
        let listed = try client.sendV2(method: "surface.list", params: params)
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
        let id = payload["\(kind)_id"] as? String
        let ref = payload["\(kind)_ref"] as? String
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
        let ref = displayTabHandle(refRaw)
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

    private func formatCreatedTabHandle(_ payload: [String: Any], idFormat: CLIIDFormat) -> String? {
        let id = (payload["created_tab_id"] as? String) ?? (payload["created_surface_id"] as? String)
        let refRaw = (payload["created_tab_ref"] as? String) ?? (payload["created_surface_ref"] as? String)
        let ref = displayTabHandle(refRaw)
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

    private func formatDebugTerminalsPayload(_ payload: [String: Any], idFormat: CLIIDFormat) -> String {
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

    private func runMoveSurface(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let surfaceRaw = optionValue(commandArgs, name: "--surface") ?? commandArgs.first
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

        let payload = try client.sendV2(method: "surface.move", params: params)
        let summary = "OK surface=\(formatHandle(payload, kind: "surface", idFormat: idFormat) ?? "unknown") pane=\(formatHandle(payload, kind: "pane", idFormat: idFormat) ?? "unknown") workspace=\(formatHandle(payload, kind: "workspace", idFormat: idFormat) ?? "unknown") window=\(formatHandle(payload, kind: "window", idFormat: idFormat) ?? "unknown")"
        printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: summary)
    }

    private func runReorderSurface(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let surfaceRaw = optionValue(commandArgs, name: "--surface") ?? commandArgs.first
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

        let payload = try client.sendV2(method: "surface.reorder", params: params)
        let summary = "OK surface=\(formatHandle(payload, kind: "surface", idFormat: idFormat) ?? "unknown") pane=\(formatHandle(payload, kind: "pane", idFormat: idFormat) ?? "unknown") workspace=\(formatHandle(payload, kind: "workspace", idFormat: idFormat) ?? "unknown")"
        printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: summary)
    }

    private func runReorderWorkspace(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let workspaceRaw = optionValue(commandArgs, name: "--workspace") ?? commandArgs.first
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

        let payload = try client.sendV2(method: "workspace.reorder", params: params)
        let summary = "OK workspace=\(formatHandle(payload, kind: "workspace", idFormat: idFormat) ?? "unknown") window=\(formatHandle(payload, kind: "window", idFormat: idFormat) ?? "unknown") index=\(payload["index"] ?? "?")"
        printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: summary)
    }

    private func runWorkspaceAction(
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

        let payload = try client.sendV2(method: "workspace.action", params: params)
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

    private func runWorktreeCommand(
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
        let focus = hasFlag(rem3, name: "--focus")
        var positional = rem3.filter { $0 != "--focus" }

        guard let branch = positional.first, !branch.hasPrefix("--") else {
            throw CLIError(message: "worktree create requires <branch>")
        }
        positional.removeFirst()
        if let unknown = positional.first(where: { $0.hasPrefix("--") }) {
            throw CLIError(message: "worktree create: unknown flag '\(unknown)'")
        }

        let repo = try resolveWorktreeRepoRoot(explicit: repoOpt)

        var params: [String: Any] = ["repo": repo, "branch": branch]
        if let baseOpt { params["base"] = baseOpt }
        if let pathOpt { params["path"] = pathOpt }
        if let layoutOpt { params["layout"] = layoutOpt }
        if focus { params["focus"] = true }

        let payload = try client.sendV2(method: "worktree.create", params: params)
        printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: worktreeSummary(payload, idFormat: idFormat))
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

        let payload = try client.sendV2(method: "worktree.open", params: params)
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
        let listPayload = try client.sendV2(method: "worktree.list", params: ["repo": repo])
        let worktrees = listPayload["worktrees"] as? [[String: Any]] ?? []

        var openedPayloads: [[String: Any]] = []
        for entry in worktrees {
            guard let path = entry["path"] as? String else { continue }
            let opened = try client.sendV2(method: "worktree.open", params: ["repo": repo, "path": path])
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

        let payload = try client.sendV2(method: "worktree.remove", params: params)
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
        let payload = try client.sendV2(method: "worktree.list", params: ["repo": repo])

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
    /// distinct from any currently-selected workspace's cwd (plan risk #2).
    private func resolveWorktreeRepoRoot(explicit: String?) throws -> String {
        let directory = ((explicit ?? FileManager.default.currentDirectoryPath) as NSString).expandingTildeInPath
        guard let root = gitTopLevelDirectory(at: directory) else {
            throw CLIError(message: "not_a_git_repo: '\(directory)' is not inside a git repository")
        }
        return root
    }

    // MARK: - Agent detection commands (docs/agent-detection-manifests.md)

    private func runAgentDetectionCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowId: String?
    ) throws {
        var positional = commandArgs
        guard let subcommandRaw = positional.first else {
            throw CLIError(message: "agent-detection requires a subcommand: list, scaffold, test")
        }
        positional.removeFirst()

        switch subcommandRaw.lowercased() {
        case "list":
            try runAgentDetectionList(args: positional, client: client, jsonOutput: jsonOutput, idFormat: idFormat)
        case "scaffold":
            try runAgentDetectionScaffold(args: positional, client: client, jsonOutput: jsonOutput, windowId: windowId)
        case "test":
            try runAgentDetectionTest(args: positional, client: client, jsonOutput: jsonOutput, idFormat: idFormat, windowId: windowId)
        default:
            throw CLIError(message: "agent-detection: unknown subcommand '\(subcommandRaw)' (expected list, scaffold, test)")
        }
    }

    private func runAgentDetectionList(
        args: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        if let unknown = args.first(where: { $0.hasPrefix("--") && $0 != "--json" }) {
            throw CLIError(message: "agent-detection list: unknown flag '\(unknown)'")
        }

        let payload = try client.sendV2(method: "agent.detection.list")
        if jsonOutput {
            print(jsonString(payload))
            return
        }

        let manifests = payload["manifests"] as? [[String: Any]] ?? []
        guard !manifests.isEmpty else {
            print("No agent-detection manifests loaded")
            return
        }
        for entry in manifests {
            let agent = entry["agent"] as? String ?? "?"
            let displayName = entry["display_name"] as? String ?? agent
            let source = entry["source"] as? String ?? "?"
            let processNames = (entry["process_names"] as? [String] ?? []).joined(separator: ", ")
            let shadowsBundled = (entry["shadows_bundled"] as? Bool) ?? false
            var line = "\(agent)  (\(displayName), source=\(source), process_names=[\(processNames)])"
            if shadowsBundled {
                line += "  [shadows bundled manifest]"
            }
            print(line)
        }
    }

    /// Mirrors `AgentManifestLoader.bundledAgentIds`
    /// (Sources/AgentManifestLoader.swift:21-29) -- this CLI target can't import that type, so
    /// this is a manually-kept-in-sync copy, used only to gate `agent-detection scaffold`'s
    /// bundled-shadowing guard below.
    private static let agentDetectionBundledIds: Set<String> = [
        "claude-code", "codex", "gemini-cli", "opencode", "copilot-cli", "cursor-agent", "aider"
    ]

    private func runAgentDetectionScaffold(
        args: [String],
        client: SocketClient,
        jsonOutput: Bool,
        windowId: String?
    ) throws {
        let (wsArg, rem0) = parseOption(args, name: "--workspace")
        let (sfArg, rem1) = parseOption(rem0, name: "--surface")
        let force = hasFlag(rem1, name: "--force")
        var positional = rem1.filter { $0 != "--force" }

        guard let agentId = positional.first, !agentId.hasPrefix("--") else {
            throw CLIError(message: "agent-detection scaffold requires <agent-id>")
        }
        positional.removeFirst()
        if let unknown = positional.first(where: { $0.hasPrefix("--") }) {
            throw CLIError(message: "agent-detection scaffold: unknown flag '\(unknown)'")
        }
        guard isValidAgentDetectionId(agentId) else {
            throw CLIError(message: "agent-detection scaffold: <agent-id> must be lowercase letters, digits, and hyphens only")
        }

        let destinationDirectory = ("~/.config/programa/agent-detection" as NSString).expandingTildeInPath
        let destinationPath = (destinationDirectory as NSString).appendingPathComponent("\(agentId).json")

        // A user override at `destinationPath` fully replaces the bundled manifest for this
        // agent id (no field merge -- AgentManifestLoader.swift's header), and a freshly
        // scaffolded manifest starts with empty `patterns` (safe -- see
        // `agentDetectionScaffoldJSON`'s doc comment -- but inert). Scaffolding one of the seven
        // bundled ids without --force would therefore silently replace working screen-based
        // detection with a manifest that detects nothing at all. Refuse by default; --force
        // seeds the new file from the bundled manifest's own patterns instead of starting blank,
        // so forcing degrades to "edit a copy of what already worked."
        var seedStates: [[String: Any]]?
        if Self.agentDetectionBundledIds.contains(agentId) {
            guard force else {
                throw CLIError(message: """
                agent-detection scaffold: '\(agentId)' is one of programa's bundled agents. A user override at \(destinationPath) fully replaces its bundled manifest (no merge) -- and a freshly scaffolded manifest starts with empty patterns, so screen-based detection for '\(agentId)' would silently stop working until you fill them back in. Pass --force to proceed anyway; the bundled manifest's existing patterns will be seeded into the new file so you start from a working copy, not a blank one.
                """)
            }
            let listPayload = try client.sendV2(method: "agent.detection.list")
            let manifests = listPayload["manifests"] as? [[String: Any]] ?? []
            if let match = manifests.first(where: { ($0["agent"] as? String) == agentId }) {
                seedStates = match["states"] as? [[String: Any]]
            }
        }

        let workspaceArg = wsArg ?? (windowId == nil ? ProcessInfo.processInfo.environment["PROGRAMA_WORKSPACE_ID"] : nil)

        var readParams: [String: Any] = [:]
        let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
        if let wsId { readParams["workspace_id"] = wsId }
        let sfId = try resolveCommandSurface(
            explicitSurface: sfArg, explicitWorkspace: wsArg,
            windowId: windowId, workspaceHandle: wsId, client: client
        )
        if let sfId { readParams["surface_id"] = sfId }

        // Capture the currently visible screen only (no --scrollback/--lines), same socket
        // method 'read-screen' calls, via the same client -- see CommandDescriptor(names:
        // ["read-screen"]) above.
        let readPayload = try client.sendV2(method: "surface.read_text", params: readParams)
        let capturedText = (readPayload["text"] as? String) ?? ""

        if !force, FileManager.default.fileExists(atPath: destinationPath) {
            throw CLIError(message: "agent-detection scaffold: \(destinationPath) already exists (use --force to overwrite)")
        }

        do {
            try FileManager.default.createDirectory(atPath: destinationDirectory, withIntermediateDirectories: true)
        } catch {
            throw CLIError(message: "agent-detection scaffold: failed to create \(destinationDirectory): \(error.localizedDescription)")
        }

        let manifestJSON = agentDetectionScaffoldJSON(agentId: agentId, capturedText: capturedText, seedStates: seedStates)
        do {
            try manifestJSON.write(toFile: destinationPath, atomically: true, encoding: .utf8)
        } catch {
            throw CLIError(message: "agent-detection scaffold: failed to write \(destinationPath): \(error.localizedDescription)")
        }

        if jsonOutput {
            print(jsonString(["path": destinationPath, "agent": agentId, "seeded_from_bundled": seedStates != nil]))
        } else {
            print("Wrote starter manifest: \(destinationPath)")
            if seedStates != nil {
                print("Seeded from the bundled '\(agentId)' manifest's existing patterns -- review them, they were verified against the bundled agent's UI, not necessarily yours.")
            }
            print("Next: review/fill in its \"patterns\" arrays, then run 'programa agent-detection test \(agentId)' to check them against the live screen.")
        }
    }

    private func runAgentDetectionTest(
        args: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowId: String?
    ) throws {
        let (wsArg, rem0) = parseOption(args, name: "--workspace")
        let (sfArg, rem1) = parseOption(rem0, name: "--surface")
        var positional = rem1

        var agentId: String?
        if let first = positional.first, !first.hasPrefix("--") {
            agentId = first
            positional.removeFirst()
        }
        if let unknown = positional.first {
            throw CLIError(message: "agent-detection test: unexpected arguments: \(unknown)")
        }

        let workspaceArg = wsArg ?? (windowId == nil ? ProcessInfo.processInfo.environment["PROGRAMA_WORKSPACE_ID"] : nil)

        var params: [String: Any] = [:]
        let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
        if let wsId { params["workspace_id"] = wsId }
        let sfId = try resolveCommandSurface(
            explicitSurface: sfArg, explicitWorkspace: wsArg,
            windowId: windowId, workspaceHandle: wsId, client: client
        )
        if let sfId { params["surface_id"] = sfId }
        if let agentId { params["agent"] = agentId }

        let payload = try client.sendV2(method: "agent.detection.classify", params: params)
        if jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
            return
        }

        guard let recognizedAgent = payload["agent"] as? String else {
            if let agentId {
                print("No manifest loaded for '\(agentId)'")
            } else {
                print("No loaded manifest recognized this screen")
            }
            return
        }
        let displayName = payload["display_name"] as? String ?? recognizedAgent
        guard let bucket = payload["bucket"] as? String else {
            print("\(recognizedAgent) (\(displayName)) recognized, but no state pattern matched the current screen")
            return
        }
        let confidence = payload["confidence"] as? String ?? "?"
        let matchedPattern = payload["matched_pattern"] as? String ?? "?"
        print("\(recognizedAgent) (\(displayName)): \(bucket)  [confidence=\(confidence), pattern=\(matchedPattern)]")
    }

    private func isValidAgentDetectionId(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "-" }
    }

    private func agentDetectionDisplayName(forAgentId agentId: String) -> String {
        agentId
            .split(separator: "-")
            .map { $0.isEmpty ? "" : $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    /// Wraps `value` as a single JSON string literal (quotes + escaping) via JSONSerialization,
    /// so arbitrary captured terminal text (quotes, backslashes, control characters, unicode) can
    /// be embedded into hand-assembled JSON safely, without a bespoke escaper.
    private func jsonEscapedString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value], options: [.withoutEscapingSlashes]),
              let arrayJSON = String(data: data, encoding: .utf8),
              arrayJSON.hasPrefix("["), arrayJSON.hasSuffix("]") else {
            return "\"\""
        }
        return String(arrayJSON.dropFirst().dropLast())
    }

    private func lastLines(_ text: String, maxLines: Int) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > maxLines else { return text }
        return lines.suffix(maxLines).joined(separator: "\n")
    }

    /// Encodes `values` as a compact JSON string array literal (e.g. `["a","b"]`) via
    /// `JSONSerialization`, so a bundled manifest's existing `patterns` (fetched over the wire
    /// from `agent.detection.list`) can be re-embedded into scaffolded JSON verbatim and safely,
    /// without a bespoke escaper.
    private func jsonEncodedStringArray(_ values: [String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: values, options: [.withoutEscapingSlashes]),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }

    private func agentDetectionStateBlockLiteral(
        bucket: String,
        priority: Int,
        anchorLines: Int,
        patternsJSON: String,
        confidence: String,
        notes: String
    ) -> String {
        "    {\n"
            + "      \"bucket\": \(jsonEscapedString(bucket)),\n"
            + "      \"priority\": \(priority),\n"
            + "      \"anchor_last_n_lines\": \(anchorLines),\n"
            + "      \"patterns\": \(patternsJSON),\n"
            + "      \"confidence\": \(jsonEscapedString(confidence)),\n"
            + "      \"source_notes\": \(jsonEscapedString(notes))\n"
            + "    }"
    }

    /// Builds a starter manifest matching `AgentManifest`'s schema (Sources/AgentManifest.swift)
    /// -- this CLI target cannot import that type directly, so the shape is mirrored by hand.
    ///
    /// When `seedStates` is nil (the common case: scaffolding an agent with no bundled
    /// manifest), all three `states[].patterns` are left empty -- confirmed safe:
    /// `AgentManifest.classify(text:)` iterates a state's patterns with a `for` loop, so an
    /// empty array matches nothing, never everything -- with a TODO in `source_notes` plus the
    /// captured screen as reference text, since JSON has no comments.
    ///
    /// When `seedStates` is non-nil (forced scaffold of a bundled agent id -- see
    /// `runAgentDetectionScaffold`'s bundled-shadowing guard), those states' own patterns are
    /// reused verbatim instead, so the result is an editable copy of a working manifest rather
    /// than a blank one.
    private func agentDetectionScaffoldJSON(
        agentId: String,
        capturedText: String,
        seedStates: [[String: Any]]?
    ) -> String {
        let displayName = agentDetectionDisplayName(forAgentId: agentId)
        let truncated = lastLines(capturedText, maxLines: 30)
        let screenReference: String
        if truncated.isEmpty {
            screenReference = "No screen text was captured (surface appeared empty at scaffold time)."
        } else {
            let lineCount = truncated.split(separator: "\n", omittingEmptySubsequences: false).count
            screenReference = "Captured screen (last \(lineCount) lines) for reference, delete once patterns are reviewed:\n\(truncated)"
        }

        let stateBlocks: [String]
        if let seedStates, !seedStates.isEmpty {
            stateBlocks = seedStates.map { state in
                let bucket = state["bucket"] as? String ?? "idle"
                let priority = (state["priority"] as? Int) ?? ((state["priority"] as? NSNumber)?.intValue ?? 0)
                let anchorLines = (state["anchor_last_n_lines"] as? Int) ?? ((state["anchor_last_n_lines"] as? NSNumber)?.intValue ?? 6)
                let patterns = (state["patterns"] as? [String]) ?? []
                let confidence = state["confidence"] as? String ?? "low"
                let notes = "SEEDED from the bundled '\(agentId)' manifest (forced override) -- "
                    + "review these, they were verified against the bundled agent's UI, not "
                    + "necessarily yours. \(screenReference)"
                return agentDetectionStateBlockLiteral(
                    bucket: bucket,
                    priority: priority,
                    anchorLines: anchorLines,
                    patternsJSON: jsonEncodedStringArray(patterns),
                    confidence: confidence,
                    notes: notes
                )
            }
        } else {
            let templates: [(bucket: String, priority: Int, anchorLines: Int, hint: String)] = [
                (
                    "blocked", 100, 12,
                    "Add regex patterns that appear when \(displayName) is waiting on you -- a y/n confirmation, a permission prompt, etc."
                ),
                (
                    "working", 50, 6,
                    "Add regex patterns that appear while \(displayName) is actively working -- a spinner, \"Thinking\", token counters, etc."
                ),
                (
                    "idle", 0, 4,
                    "Add regex patterns that match \(displayName)'s prompt when it's idle and ready for the next instruction."
                )
            ]
            stateBlocks = templates.map { template in
                let notes = "TODO: \(template.hint) Patterns are intentionally empty -- an empty "
                    + "list matches nothing (never everything; see AgentManifest.classify). \(screenReference)"
                return agentDetectionStateBlockLiteral(
                    bucket: template.bucket,
                    priority: template.priority,
                    anchorLines: template.anchorLines,
                    patternsJSON: "[]",
                    confidence: "low",
                    notes: notes
                )
            }
        }

        let states = stateBlocks.joined(separator: ",\n")

        return """
        {
          "version": 1,
          "agent": \(jsonEscapedString(agentId)),
          "display_name": \(jsonEscapedString(displayName)),
          "recognize": {
            "process_names": [\(jsonEscapedString(agentId))],
            "screen_patterns": []
          },
          "states": [
        \(states)
          ]
        }
        """
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

    // MARK: - Race command (fan one prompt across N agents in isolated worktrees, v1: spawn only)

    /// The only agents `race` supports: the three that report state via lifecycle hooks
    /// (Claude Code, OpenCode, Codex). Racing needs a trustworthy idle signal, which
    /// screen-pattern detection (used for Gemini CLI/Copilot/Cursor Agent/Aider) cannot
    /// provide, so those are deliberately excluded here even though they're supported
    /// elsewhere in the app for status badges.
    private static let raceSupportedAgents: [String] = ["claude", "opencode", "codex"]

    /// Builds the shell command line that starts an agent with `prompt` as its initial task.
    /// Reuses the same bare binary names Programa already invokes elsewhere for these agents
    /// (`initialTerminalInput: "claude\n"` for the "New Claude Code Workspace" shortcut in
    /// AppDelegate.swift, and the `process_names` in Resources/AgentDetection/*.json), just
    /// with the prompt appended as a shell-quoted positional argument so the agent starts
    /// working immediately instead of sitting at its own empty prompt. No prior art exists in
    /// this codebase for "agent + initial prompt argument" specifically, so this is a new,
    /// minimal one-place mapping rather than an existing construction being reused verbatim.
    private func raceAgentLaunchCommand(agent: String, prompt: String) -> String {
        "\(agent) \(shellSingleQuote(prompt))"
    }

    /// Shell-quotes arbitrary text for safe inclusion in a POSIX shell command line typed into
    /// a terminal via `surface.send_text`. Wraps in single quotes and escapes embedded single
    /// quotes as '\'' (close quote, literal escaped quote, reopen quote) -- the standard
    /// technique, safe against every other shell metacharacter (double quotes, backticks, $,
    /// *, newlines, etc.) since nothing but a literal `'` is special inside single quotes.
    private func shellSingleQuote(_ raw: String) -> String {
        "'" + raw.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func runRaceCommand(
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

        // Racing twice in a row used to collide on every index, because the branches were
        // always `<prefix>/1...<prefix>/N`. Start after whatever `<prefix>/<number>` branches
        // already exist so a second run just continues the numbering.
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

                let payload = try client.sendV2(method: "worktree.create", params: params)
                guard let workspaceId = payload["workspace_id"] as? String else {
                    throw CLIError(message: "worktree.create did not return a workspace_id")
                }
                let workspaceRef = formatHandle(payload, kind: "workspace", idFormat: idFormat) ?? workspaceId

                let launchCommand = raceAgentLaunchCommand(agent: agent, prompt: prompt)
                _ = try client.sendV2(method: "surface.send_text", params: [
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

    private func runLayoutCommand(
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

        let payload = try client.sendV2(method: "layout.save", params: params)
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
        // Help text promises "cwd = --cwd (or the current directory)"; without an
        // explicit fallback here, an omitted --cwd sent nothing and the app fell
        // back to its own new-tab heuristic instead.
        params["cwd"] = cwdOpt ?? FileManager.default.currentDirectoryPath

        let payload = try client.sendV2(method: "layout.apply", params: params)
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

        let payload = try client.sendV2(method: "layout.list", params: [:])
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

    private func runSnapshotCommand(
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

        let payload = try client.sendV2(method: "snapshot.list", params: [:])
        if jsonOutput {
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

        let payload = try client.sendV2(method: "snapshot.restore", params: params)
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

    private func runTabAction(
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
        let (urlOpt, rem5) = parseOption(rem4, name: "--url")

        var positional = rem5
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
        if let urlOpt, !urlOpt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            params["url"] = urlOpt.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let payload = try client.sendV2(method: "tab.action", params: params)
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

    private func runRenameTab(
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
            let windows = try client.sendV2(method: "window.list")
            let windowList = windows["windows"] as? [[String: Any]] ?? []
            for window in windowList {
                guard let windowId = window["id"] as? String else { continue }
                let listed = try client.sendV2(method: "workspace.list", params: ["window_id": windowId])
                let items = listed["workspaces"] as? [[String: Any]] ?? []
                for item in items where (item["ref"] as? String) == raw {
                    if let id = item["id"] as? String { return id }
                }
            }
            throw CLIError(message: "Workspace ref not found: \(raw)")
        }

        if let raw, Int(raw) != nil {
            throw CLIError(message: "workspace: bare indexes are no longer accepted; use a UUID or short ref like workspace:2 (see list-workspaces)")
        }

        let current = try client.sendV2(method: "workspace.current")
        if let wsId = current["workspace_id"] as? String { return wsId }
        throw CLIError(message: "No workspace selected")
    }

    func resolveSurfaceId(_ raw: String?, workspaceId: String, client: SocketClient) throws -> String {
        if let raw, isUUID(raw) {
            return raw
        }
        if let raw, isHandleRef(raw) {
            let listed = try client.sendV2(method: "surface.list", params: ["workspace_id": workspaceId])
            let items = listed["surfaces"] as? [[String: Any]] ?? []
            for item in items where (item["ref"] as? String) == raw {
                if let id = item["id"] as? String { return id }
            }
            throw CLIError(message: "Surface ref not found: \(raw)")
        }

        if let raw, Int(raw) != nil {
            throw CLIError(message: "surface: bare indexes are no longer accepted; use a UUID or short ref like surface:2 (see list-pane-surfaces)")
        }

        let listed = try client.sendV2(method: "surface.list", params: ["workspace_id": workspaceId])
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
        if let text = browserSubcommandUsage(command) { return text }
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

    /// Shared scan loop for `parseOption`/`parseRepeatedOption`: walks `args`,
    /// collecting every value that follows `name` (honoring a `--` terminator)
    /// and returning the leftover args with those option/value pairs removed.
    private func scanOption(_ args: [String], name: String) -> ([String], [String]) {
        var remaining: [String] = []
        var values: [String] = []
        var skipNext = false
        var pastTerminator = false
        for (idx, arg) in args.enumerated() {
            if skipNext {
                skipNext = false
                continue
            }
            if arg == "--" {
                pastTerminator = true
                remaining.append(arg)
                continue
            }
            if !pastTerminator, arg == name, idx + 1 < args.count {
                values.append(args[idx + 1])
                skipNext = true
                continue
            }
            remaining.append(arg)
        }
        return (values, remaining)
    }

    func parseOption(_ args: [String], name: String) -> (String?, [String]) {
        let (values, remaining) = scanOption(args, name: name)
        return (values.last, remaining)
    }

    private func parseRepeatedOption(_ args: [String], name: String) -> ([String], [String]) {
        scanOption(args, name: name)
    }

    func optionValue(_ args: [String], name: String) -> String? {
        guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    func hasFlag(_ args: [String], name: String) -> Bool {
        args.contains(name)
    }

    private func replaceToken(_ args: [String], from: String, to: String) -> [String] {
        args.map { $0 == from ? to : $0 }
    }

    /// Unescape CLI escape sequences for send behavior.
    /// \n and \r → carriage return (Enter), \t → tab.
    private func unescapeSendText(_ text: String) -> String {
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

    /// Validates contracts whose failures can be determined without opening
    /// the socket. Handlers retain their checks as a defensive boundary, but
    /// malformed invocations now fail before they can affect a running app.
    private func preflightFlagArguments(
        _ args: [String],
        command: String,
        valueFlags: Set<String>,
        booleanFlags: Set<String> = [],
        allowEquals: Bool
    ) throws -> (positional: [String], options: [String: String]) {
        var positional: [String] = []
        var options: [String: String] = [:]
        var pastTerminator = false
        var index = 0

        while index < args.count {
            let token = args[index]
            if pastTerminator {
                positional.append(token)
                index += 1
                continue
            }
            if token == "--" {
                pastTerminator = true
                index += 1
                continue
            }
            guard token.hasPrefix("--") else {
                positional.append(token)
                index += 1
                continue
            }

            let body = String(token.dropFirst(2))
            let parts = body.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = String(parts[0])
            let hasEqualsValue = parts.count == 2

            guard valueFlags.contains(name) || booleanFlags.contains(name) else {
                throw CLIError(message: "\(command): unknown option --\(name)")
            }
            guard options[name] == nil else {
                throw CLIError(message: "\(command): duplicate option --\(name)")
            }

            if booleanFlags.contains(name) {
                guard !hasEqualsValue else {
                    throw CLIError(message: "\(command): --\(name) does not take a value")
                }
                options[name] = "true"
                index += 1
                continue
            }

            if hasEqualsValue {
                guard allowEquals else {
                    throw CLIError(message: "\(command): unexpected option syntax --\(name)=; use --\(name) <value>")
                }
                let value = String(parts[1])
                guard !value.isEmpty else {
                    throw CLIError(message: "\(command): --\(name) requires a value")
                }
                options[name] = value
                index += 1
                continue
            }

            guard index + 1 < args.count, !args[index + 1].hasPrefix("--") else {
                throw CLIError(message: "\(command): --\(name) requires a value")
            }
            options[name] = args[index + 1]
            index += 2
        }
        return (positional, options)
    }

    /// Exhaustive grammar table for commands that use the shared registry
    /// contract. Keeping this switch total makes a newly registered command
    /// fail closed before socket acquisition until its grammar is declared.
    private func validateRegisteredArguments(_ args: [String], for command: String) throws {
        func parse(
            values: Set<String> = [],
            booleans: Set<String> = [],
            minPositionals: Int = 0,
            maxPositionals: Int? = 0,
            allowEquals: Bool = false
        ) throws -> (positional: [String], options: [String: String]) {
            let parsed = try preflightFlagArguments(
                args,
                command: command,
                valueFlags: values,
                booleanFlags: booleans,
                allowEquals: allowEquals
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

        // Commands that declare a typed grammar on their descriptor validate
        // from it directly, through the exact same `parse`/`require` helpers
        // the switch below uses -- so migrating a command off the switch
        // cannot change its error messages. Commands without a grammar fall
        // through to the switch unchanged.
        if let grammar = commandDescriptor(named: command)?.grammar {
            let parsed = try parse(
                values: grammar.valueOptions,
                booleans: grammar.booleanOptions,
                minPositionals: grammar.minPositionals,
                maxPositionals: grammar.maxPositionals,
                allowEquals: grammar.allowEquals
            )
            try require(grammar.requiredOptions, in: parsed.options)
            return
        }

        switch command {
        case "rpc":
            let parsed = try parse(minPositionals: 1, maxPositionals: 2)
            _ = try parseRPCParams(Array(parsed.positional.dropFirst()))

        case "focus-window", "close-window":
            let parsed = try parse(values: ["window"])
            try require(["window"], in: parsed.options)
            guard let rawWindow = parsed.options["window"], isUUID(rawWindow.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw CLIError(message: "\(command): invalid window id")
            }

        case "reorder-workspace":
            let parsed = try parse(values: ["workspace", "index", "before", "after", "window"])
            try require(["workspace"], in: parsed.options)
            let anchors = ["index", "before", "after"].filter { parsed.options[$0] != nil }
            guard anchors.count == 1 else {
                throw CLIError(message: "reorder-workspace requires exactly one of --index, --before, or --after")
            }
            if let raw = parsed.options["index"], (Int(raw) ?? -1) < 0 {
                throw CLIError(message: "reorder-workspace: --index must be a nonnegative integer")
            }

        case "workspace-action":
            let parsed = try parse(values: ["action", "workspace", "title", "color", "description"], maxPositionals: nil)
            guard let rawAction = parsed.options["action"] ?? parsed.positional.first else {
                throw CLIError(message: "workspace-action requires --action <name>")
            }
            let trailing = parsed.options["action"] == nil ? Array(parsed.positional.dropFirst()) : parsed.positional
            let action = rawAction.lowercased().replacingOccurrences(of: "-", with: "_")
            if action == "rename", parsed.options["title"] == nil, trailing.isEmpty {
                throw CLIError(message: "workspace-action rename requires a title")
            }
            if action == "set_color", parsed.options["color"] == nil, trailing.isEmpty {
                throw CLIError(message: "workspace-action set-color requires a color")
            }
            if action == "set_description", parsed.options["description"] == nil, trailing.isEmpty {
                throw CLIError(message: "workspace-action set-description requires a description")
            }

        case "new-split":
            let parsed = try parse(values: ["workspace", "surface", "panel"], minPositionals: 1, maxPositionals: 1)
            guard ["left", "right", "up", "down"].contains(parsed.positional[0].lowercased()) else {
                throw CLIError(message: "new-split: direction must be left, right, up, or down")
            }

        case "focus-pane":
            let parsed = try parse(values: ["workspace", "pane"], maxPositionals: 1)
            guard parsed.options["pane"] != nil || parsed.positional.count == 1 else {
                throw CLIError(message: "focus-pane requires --pane <id|ref>")
            }
            guard !(parsed.options["pane"] != nil && !parsed.positional.isEmpty) else {
                throw CLIError(message: "focus-pane: provide the pane once")
            }

        case "new-pane":
            let parsed = try parse(values: ["type", "direction", "workspace", "url"])
            if let type = parsed.options["type"], !["terminal", "browser"].contains(type.lowercased()) {
                throw CLIError(message: "new-pane: --type must be terminal or browser")
            }
            if let direction = parsed.options["direction"], !["left", "right", "up", "down"].contains(direction.lowercased()) {
                throw CLIError(message: "new-pane: invalid direction")
            }

        case "new-surface":
            let parsed = try parse(values: ["type", "pane", "workspace", "url"])
            if let type = parsed.options["type"], !["terminal", "browser"].contains(type.lowercased()) {
                throw CLIError(message: "new-surface: --type must be terminal or browser")
            }

        case "move-surface":
            let parsed = try parse(values: ["surface", "pane", "workspace", "window", "before", "before-surface", "after", "after-surface", "index", "focus"], maxPositionals: 1)
            guard parsed.options["surface"] != nil || parsed.positional.count == 1 else {
                throw CLIError(message: "move-surface requires --surface <id|ref>")
            }
            guard !(parsed.options["surface"] != nil && !parsed.positional.isEmpty) else {
                throw CLIError(message: "move-surface: provide the surface once")
            }
            if let raw = parsed.options["index"], (Int(raw) ?? -1) < 0 {
                throw CLIError(message: "move-surface: --index must be a nonnegative integer")
            }
            if let raw = parsed.options["focus"], !["true", "false", "1", "0", "yes", "no", "on", "off"].contains(raw.lowercased()) {
                throw CLIError(message: "move-surface: --focus must be true or false")
            }
            let anchors = ["index", "before", "before-surface", "after", "after-surface"].filter { parsed.options[$0] != nil }
            guard anchors.count <= 1 else {
                throw CLIError(message: "move-surface accepts only one of --index, --before, or --after")
            }

        case "reorder-surface":
            let parsed = try parse(values: ["surface", "workspace", "index", "before", "before-surface", "after", "after-surface"], maxPositionals: 1)
            guard parsed.options["surface"] != nil || parsed.positional.count == 1 else {
                throw CLIError(message: "reorder-surface requires --surface <id|ref>")
            }
            guard !(parsed.options["surface"] != nil && !parsed.positional.isEmpty) else {
                throw CLIError(message: "reorder-surface: provide the surface once")
            }
            let anchors = ["index", "before", "before-surface", "after", "after-surface"].filter { parsed.options[$0] != nil }
            guard anchors.count == 1 else {
                throw CLIError(message: "reorder-surface requires exactly one of --index, --before, or --after")
            }
            if let raw = parsed.options["index"], (Int(raw) ?? -1) < 0 {
                throw CLIError(message: "reorder-surface: --index must be a nonnegative integer")
            }

        case "tab-action":
            let parsed = try parse(values: ["action", "tab", "surface", "workspace", "title", "url"], maxPositionals: nil)
            guard parsed.options["action"] != nil || !parsed.positional.isEmpty else {
                throw CLIError(message: "tab-action requires --action <name>")
            }

        case "rename-tab":
            let parsed = try parse(values: ["workspace", "tab", "surface", "title"], maxPositionals: nil)
            guard parsed.options["title"] != nil || !parsed.positional.isEmpty else {
                throw CLIError(message: "rename-tab requires a title")
            }

        case "drag-surface-to-split":
            let parsed = try parse(values: ["surface", "panel"], minPositionals: 1, maxPositionals: 1)
            guard (parsed.options["surface"] != nil) != (parsed.options["panel"] != nil) else {
                throw CLIError(message: "drag-surface-to-split requires exactly one of --surface or --panel")
            }
            guard ["left", "right", "up", "down"].contains(parsed.positional[0].lowercased()) else {
                throw CLIError(message: "drag-surface-to-split: invalid direction")
            }

        case "close-workspace", "select-workspace":
            let parsed = try parse(values: ["workspace"])
            if parsed.options["workspace"] == nil {
                throw CLIError(
                    message: "\(command): --workspace <id|ref> is required (UUID or short ref like workspace:2). Refusing to target the current workspace implicitly."
                )
            }

        case "set-status":
            let parsed = try parse(
                values: ["icon", "color", "url", "link", "priority", "format", "pid", "workspace"],
                minPositionals: 2,
                maxPositionals: nil,
                allowEquals: true
            )
            if let priority = parsed.options["priority"], Int(priority) == nil {
                throw CLIError(message: "set-status: --priority must be an integer")
            }
            if let format = parsed.options["format"], !["plain", "markdown", "md"].contains(format.lowercased()) {
                throw CLIError(message: "set-status: --format must be plain or markdown")
            }
            if let pid = parsed.options["pid"], (Int(pid) ?? 0) <= 0 {
                throw CLIError(message: "set-status: --pid must be a positive integer")
            }

        case "log":
            let parsed = try parse(values: ["level", "source", "workspace"], minPositionals: 1, maxPositionals: nil, allowEquals: true)
            if let level = parsed.options["level"], !["info", "progress", "success", "warning", "error"].contains(level) {
                throw CLIError(message: "log: invalid --level value")
            }

        case "set-app-focus":
            let parsed = try parse(minPositionals: 1, maxPositionals: 1)
            guard ["active", "inactive", "clear", "1", "0", "true", "false", "none"].contains(parsed.positional[0].lowercased()) else {
                throw CLIError(message: "set-app-focus: invalid state")
            }

        case "tree":
            _ = try parse(values: ["workspace"], booleans: ["all"])

        case "markdown":
            let parsed = try parse(
                values: ["workspace", "window", "surface", "direction"],
                minPositionals: 1,
                maxPositionals: 2,
                allowEquals: true
            )
            if parsed.positional.count == 2, parsed.positional[0].lowercased() != "open" {
                throw CLIError(message: "markdown: unexpected subcommand \(parsed.positional[0])")
            }

        case "review":
            let parsed = try parse(
                values: ["workspace", "window", "surface", "direction", "mode", "base-branch", "preamble"],
                minPositionals: 1,
                maxPositionals: nil,
                allowEquals: true
            )
            let subcommand = parsed.positional[0].lowercased()
            guard ["open", "refresh", "comment", "send"].contains(subcommand) else {
                throw CLIError(message: "review: unknown subcommand \(parsed.positional[0])")
            }
            if subcommand == "comment" {
                guard parsed.positional.count >= 2 else {
                    throw CLIError(message: "review comment: missing subcommand (add|remove|list)")
                }
                guard ["add", "remove", "list"].contains(parsed.positional[1].lowercased()) else {
                    throw CLIError(message: "review comment: unknown subcommand \(parsed.positional[1])")
                }
            }

        case "recap":
            let parsed = try parse(
                values: ["workspace", "window"],
                minPositionals: 1,
                maxPositionals: 2,
                allowEquals: true
            )
            let subcommand = parsed.positional[0].lowercased()
            guard ["open", "list"].contains(subcommand) else {
                throw CLIError(message: "recap: unknown subcommand \(parsed.positional[0])")
            }
            if subcommand == "open" {
                guard parsed.positional.count == 2 else {
                    throw CLIError(message: "recap open requires <slug>")
                }
            } else if subcommand == "list", parsed.positional.count != 1 {
                throw CLIError(message: "recap list: unexpected argument \(parsed.positional[1])")
            }

        case "worktree":
            let parsed = try parse(
                values: ["repo", "base", "path", "layout"],
                booleans: ["focus", "force", "json"],
                minPositionals: 1,
                maxPositionals: nil,
                allowEquals: true
            )
            guard ["create", "open", "remove", "list"].contains(parsed.positional[0].lowercased()) else {
                throw CLIError(message: "worktree: unknown subcommand \(parsed.positional[0])")
            }

        case "agent-detection":
            let parsed = try parse(
                values: ["surface", "workspace"],
                booleans: ["force", "json"],
                minPositionals: 1,
                maxPositionals: 2,
                allowEquals: true
            )
            let subcommand = parsed.positional[0].lowercased()
            guard ["list", "scaffold", "test"].contains(subcommand) else {
                throw CLIError(message: "agent-detection: unknown subcommand \(parsed.positional[0])")
            }
            if subcommand == "scaffold", parsed.positional.count != 2 {
                throw CLIError(message: "agent-detection scaffold requires <agent-id>")
            }

        case "race":
            let parsed = try parse(
                values: ["n", "agent", "base", "prefix", "layout"],
                minPositionals: 1,
                maxPositionals: nil,
                allowEquals: true
            )
            if let rawN = parsed.options["n"] {
                guard let n = Int(rawN), n >= 1, n <= 8 else {
                    throw CLIError(message: "race: --n must be between 1 and 8")
                }
            }
            if let rawAgent = parsed.options["agent"] {
                guard ["claude", "opencode", "codex"].contains(rawAgent.lowercased()) else {
                    throw CLIError(message: "race: --agent must be one of claude, opencode, codex")
                }
            }

        case "layout":
            let parsed = try parse(
                values: ["workspace", "cwd"],
                booleans: ["force", "json"],
                minPositionals: 1,
                maxPositionals: nil,
                allowEquals: true
            )
            guard ["save", "apply", "list"].contains(parsed.positional[0].lowercased()) else {
                throw CLIError(message: "layout: unknown subcommand \(parsed.positional[0])")
            }

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
            let parsed = try parse(values: ["pane", "workspace", "amount"], minPositionals: 1, maxPositionals: 1)
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
            let parsed = try parse(values: ["timeout"], booleans: ["signal"], minPositionals: 1, maxPositionals: 2)
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
        case "popup", "bind-key", "unbind-key", "copy-mode":
            throw CLIError(message: "\(command) is not supported yet in programa CLI parity mode")
        case "display-message":
            let parsed = try parse(booleans: ["print"], minPositionals: 1, maxPositionals: nil)
            guard parsed.positional.filter({ $0 != "-p" }).isEmpty == false else {
                throw CLIError(message: "display-message requires text")
            }

        // These commands own nested or foreign grammars. Their handlers do
        // full parsing; flags must remain byte-for-byte passthrough here.
        case "__tmux-compat",
             "browser", "open-browser",
             "navigate", "browser-back", "browser-forward", "browser-reload", "get-url",
             "focus-webview", "is-webview-focused":
            return

        // Local commands are registered for unified lookup/help, but do not
        // acquire the app socket through the generic dispatcher.
        case "shortcuts", "feedback", "themes", "claude-teams", "omo", "omx", "omc":
            return
        case "codex", "claude", "opencode":
            _ = try parse(booleans: ["yes", "y"], minPositionals: 1, maxPositionals: 1)
        case "aside":
            _ = try parse(booleans: ["yes", "y", "with-devtools"], minPositionals: 1, maxPositionals: 1)
        // Commands with richer bespoke contracts are validated by their
        // dedicated cases in `validateArguments`.
        case "ping", "focus-panel", "read-screen", "wait-surface", "set-progress", "list-log", "watch-events":
            return

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

        case .noArguments:
            guard args.isEmpty else {
                throw CLIError(message: "\(command): unexpected arguments: \(args.joined(separator: " "))")
            }

        case .focusPanel:
            let parsed = try preflightFlagArguments(
                args,
                command: command,
                valueFlags: ["panel", "workspace"],
                allowEquals: false
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
                booleanFlags: ["scrollback"],
                allowEquals: false
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
                valueFlags: ["workspace", "surface", "pattern", "timeout", "lines"],
                booleanFlags: ["exit"],
                allowEquals: false
            )
            guard parsed.positional.isEmpty else {
                throw CLIError(message: "wait-surface: unexpected arguments: \(parsed.positional.joined(separator: " "))")
            }
            guard (parsed.options["pattern"] != nil) != (parsed.options["exit"] != nil) else {
                throw CLIError(message: "wait-surface requires exactly one of --pattern <regex> or --exit")
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
                booleanFlags: ["agent-state", "workspace-lifecycle", "no-reconnect"],
                allowEquals: false
            )
            guard parsed.positional.isEmpty else {
                throw CLIError(message: "watch-events: unexpected arguments: \(parsed.positional.joined(separator: " "))")
            }
            guard parsed.options["agent-state"] != nil
                || parsed.options["workspace-lifecycle"] != nil
                || parsed.options["output"] != nil else {
                throw CLIError(
                    message: "watch-events requires at least one of --agent-state, --workspace-lifecycle, --output <surface_id[,surface_id...]>"
                )
            }

        case .setProgress:
            let parsed = try preflightFlagArguments(
                args,
                command: command,
                valueFlags: ["label", "workspace"],
                allowEquals: true
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
                valueFlags: ["limit", "workspace"],
                allowEquals: true
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

    /// Parses CLI-style flags (`--name value` or `--name=value`) into positional args + an
    /// options dict, mirroring the v1 server-side `parseOptions`/`parseOptionsNoStop` grammar
    /// so v2-backed sidebar commands can rebuild the same structured params client-side.
    /// `stopAtDashDash: true` matches `parseOptions` (a bare `--` ends flag parsing, remaining
    /// tokens are positional); `false` matches `parseOptionsNoStop` (a bare `--` is skipped,
    /// used by `report_meta_block`-style commands where `--` separates key/options from markdown
    /// body but the caller already split that out).
    private func parseFlagArgs(_ args: [String], stopAtDashDash: Bool = true) -> (positional: [String], options: [String: String]) {
        var positional: [String] = []
        var options: [String: String] = [:]
        var stopParsingOptions = false
        var i = 0
        while i < args.count {
            let token = args[i]
            if stopParsingOptions {
                positional.append(token)
            } else if token == "--" {
                if stopAtDashDash {
                    stopParsingOptions = true
                }
            } else if token.hasPrefix("--") {
                if let eqIndex = token.firstIndex(of: "=") {
                    let key = String(token[token.index(token.startIndex, offsetBy: 2)..<eqIndex])
                    let value = String(token[token.index(after: eqIndex)...])
                    options[key] = value
                } else {
                    let key = String(token.dropFirst(2))
                    if i + 1 < args.count, !args[i + 1].hasPrefix("--") {
                        options[key] = args[i + 1]
                        i += 1
                    } else {
                        options[key] = ""
                    }
                }
            } else {
                positional.append(token)
            }
            i += 1
        }
        return (positional, options)
    }

    private func normalizedFlagValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Resolves the target workspace for a sidebar-metadata command: explicit `--workspace`
    /// flag, else `$PROGRAMA_WORKSPACE_ID` (unless a `--window` override is active), else the
    /// server's currently-selected workspace (mirrors v1's `resolveTabForReport`/
    /// `parseSidebarMutationTabTarget` fallback to `tabManager.selectedTabId`).
    private func resolveSidebarWorkspaceId(
        options: [String: String],
        windowOverride: String?,
        client: SocketClient
    ) throws -> String {
        let raw = options["workspace"] ?? (windowOverride == nil ? ProcessInfo.processInfo.environment["PROGRAMA_WORKSPACE_ID"] : nil)
        return try resolveWorkspaceId(raw, client: client)
    }

    /// Rebuilds v1's `key=value icon=X color=Y url=Z priority=N format=X` status-entry line
    /// from a `workspace.set_status`/`list_status`/`sidebar_state` v2 entry dict.
    private func sidebarMetadataLineText(_ entry: [String: Any]) -> String {
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
    private func sidebarLogLineText(_ entry: [String: Any]) -> String {
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
    private func sidebarStateText(_ payload: [String: Any]) -> String {
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

    private func parseRPCParams(_ args: [String]) throws -> [String: Any] {
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
          \(bold)\u{2318}\u{21E7}L\(reset)\(subdued)                 New browser\(reset)
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

        Handle Inputs:
          Use UUIDs or short refs (window:1/workspace:2/pane:3/surface:4) where commands accept window, workspace, pane, or surface inputs.
          `tab-action` also accepts `tab:<n>` in addition to `surface:<n>`.
          Output defaults to refs; pass --id-format uuids or --id-format both to include UUIDs.

        Socket Auth:
          --password takes precedence, then PROGRAMA_SOCKET_PASSWORD env var, then password saved in Settings.

        Commands:
        \(commandsHelpBlock())

        Environment:
          PROGRAMA_WORKSPACE_ID   Auto-set in programa terminals. Used as default --workspace for
                              ALL commands (send, list-panels, new-split, notify, etc.).
          PROGRAMA_TAB_ID         Optional alias used by `tab-action`/`rename-tab` as default --tab.
          PROGRAMA_SURFACE_ID     Auto-set in programa terminals. Used as default --surface.
          PROGRAMA_SOCKET_PATH    Override the Unix socket path. Without this, the CLI defaults
                              to ~/Library/Application Support/programa/programa.sock and auto-discovers tagged/debug sockets.
        """
    }

#if DEBUG
    func debugUsageTextForTesting() -> String {
        usage()
    }

    func debugFormatDebugTerminalsPayloadForTesting(
        _ payload: [String: Any],
        idFormat: CLIIDFormat = .refs
    ) -> String {
        formatDebugTerminalsPayload(payload, idFormat: idFormat)
    }
#endif
}

@main
struct CMUXTermMain {
    static func main() {
        // CLI tools should ignore SIGPIPE so closed stdout pipes do not terminate the process.
        _ = signal(SIGPIPE, SIG_IGN)
        let cli = ProgramaCLI(args: CommandLine.arguments)
        do {
            try cli.run()
        } catch {
            FileHandle.standardError.write(Data("Error: \(error)\n".utf8))
            exit(1)
        }
    }
}
