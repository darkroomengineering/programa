import Foundation
import Darwin

// Shared by the `programa` CLI and the `programa-mcp` sidecar (CLI-MCP/MCPSocketBridge.swift).

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

final class SocketClient {
    private let path: String
    private var socketFD: Int32 = -1
    private static let defaultResponseTimeoutSeconds: TimeInterval = 15.0
    private static let multilineResponseIdleTimeoutSeconds: TimeInterval = 0.12
    private static let maxSocketTimeoutSeconds: TimeInterval = 9_007_199_254_740_991
    private static let responseTimeoutSeconds: TimeInterval = {
        let env = ProcessInfo.processInfo.environment
        // Legacy cmux name (CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC), still read so existing scripts keep working.
        if let raw = env["PROGRAMA_CLI_RESPONSE_TIMEOUT_SEC"] ?? env["CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC"],
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
    ///   `PROGRAMA_CLI_RESPONSE_TIMEOUT_SEC`'s default (e.g. `surface.wait` with a caller-chosen
    ///   `--timeout`). Ignored (falls back to the default) when `nil` or smaller.
    func send(
        command: String,
        minimumReceiveTimeout: TimeInterval? = nil,
        singleLine: Bool = false
    ) throws -> String {
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
        let responseDeadline = ProcessInfo.processInfo.systemUptime + (
            initialReceiveTimeout.isFinite ? initialReceiveTimeout : Self.defaultResponseTimeoutSeconds
        )

        while true {
            let receiveTimeout: TimeInterval
            if singleLine {
                receiveTimeout = responseDeadline - ProcessInfo.processInfo.systemUptime
                guard receiveTimeout > 0 else { throw CLIError(message: "Command timed out") }
            } else {
                receiveTimeout = sawNewline ? Self.multilineResponseIdleTimeoutSeconds : initialReceiveTimeout
            }
            try configureReceiveTimeout(receiveTimeout)

            var buffer = [UInt8](repeating: 0, count: 8192)
            let count = Darwin.read(socketFD, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR {
                    continue
                }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    if singleLine { continue }
                    if sawNewline {
                        break
                    }
                    throw CLIError(message: "Command timed out")
                }
                throw CLIError(message: "Socket read error")
            }
            if count == 0 {
                if singleLine { throw CLIError(message: "Socket closed before terminating response newline") }
                break
            }
            data.append(buffer, count: count)
            if singleLine, ProcessInfo.processInfo.systemUptime >= responseDeadline {
                throw CLIError(message: "Command timed out")
            }
            if let newline = data.firstIndex(of: UInt8(0x0A)) {
                if singleLine {
                    guard data.index(after: newline) == data.endIndex else {
                        throw CLIError(message: "Unexpected trailing bytes after v2 response")
                    }
                    break
                }
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
        // Verify the path is a socket (never a symlink) owned by the current user to prevent
        // fake-socket attacks; the peer uid is checked again after connecting.
        switch CLISocketSafety.checkPath(path) {
        case .ok:
            break
        case .missing(let statErrno):
            throw SocketConnectError(errnoValue: statErrno, message: "Socket not found at \(path)")
        case .symlink:
            throw CLIError(message: "Path at \(path) is a symlink — refusing to connect")
        case .notSocket:
            throw CLIError(message: "Path exists at \(path) but is not a Unix socket")
        case .foreignOwner:
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
            guard CLISocketSafety.peerUIDMatchesCurrentUser(fd: socketFD) else {
                Darwin.close(socketFD)
                socketFD = -1
                throw CLIError(message: "Socket at \(path) is served by a different user — refusing to connect")
            }
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

        let raw = try send(command: requestLine, minimumReceiveTimeout: minimumReceiveTimeout, singleLine: true)

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
    /// frame one at a time via `readEventLine`, which retains additional buffered
    /// frames for a connection that keeps receiving events indefinitely.
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
