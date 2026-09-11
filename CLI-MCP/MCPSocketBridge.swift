import Foundation
import CoreFoundation
import Darwin

/// Failure modes talking to Programa's v2 control socket.
///
/// The wire protocol (docs/plans/mcp-server.md §1.2) is newline-delimited
/// JSON, NOT JSON-RPC 2.0 -- responses are `{"ok":true,"result":...}` /
/// `{"ok":false,"error":{"code":...,"message":...}}`, and a legacy
/// pre-JSON `ERROR: ...` line can appear before the JSON protocol engages
/// (connection-level access denial). These cases are kept distinct here so
/// `MCPErrorMapping` can translate each into an honest MCP tool-call error
/// instead of collapsing them into one generic failure string.
enum MCPSocketBridgeError: Error {
    /// A legacy, pre-JSON connection-level failure line, e.g.
    /// `"ERROR: Access denied ..."` (`Sources/TerminalController.swift:1435`).
    case legacyError(String)
    /// A v2 protocol error: `{"ok": false, "error": {"code": ..., "message": ...}}`.
    case v2Error(code: String, message: String)
    /// Could not connect to, write to, or read from the socket (includes
    /// timeouts and a missing/foreign-owned socket file).
    case transport(String)
    /// The socket returned something that isn't valid v2 JSON.
    case invalidResponse(String)
    /// Password-mode configuration or credential failure. Kept distinct from
    /// ordinary v2 method failures so the MCP sidecar can tell operators how
    /// to configure authentication instead of reporting a tool failure.
    case authentication(String)
}

extension MCPSocketBridgeError: CustomStringConvertible {
    var description: String {
        switch self {
        case .legacyError(let message): return message
        case .v2Error(let code, let message): return "\(code): \(message)"
        case .transport(let message): return message
        case .invalidResponse(let message): return message
        case .authentication(let message): return message
        }
    }
}

/// A one-shot client for Programa's v2 JSON control socket, used by
/// `programa-mcp` tool handlers to translate an MCP `tools/call` into a
/// socket request and back.
///
/// Mirrors `SocketClient`/`sendV2` in `CLI/programa.swift:386-1039` closely
/// enough that timeout behavior, the `ERROR:`-prefix pre-JSON case, and the
/// idle-gap multiline read stay consistent between the CLI and the MCP
/// sidecar -- see docs/plans/mcp-server.md §1.2-§1.4. The MCP sidecar only
/// ever talks to a local Unix domain socket.
///
/// Connects fresh per call and closes afterward -- matches the CLI's
/// per-invocation connection lifecycle (no pooling / keep-alive), which is
/// the right fit for how MCP tool calls arrive (one at a time, no shared
/// session state needed at the socket layer).
struct MCPSocketBridge {
    private static let defaultResponseTimeoutSeconds: TimeInterval = 15.0
    private static let multilineResponseIdleTimeoutSeconds: TimeInterval = 0.12
    /// Ceiling for any socket timeout. Exists so a `timeval` handed to `setsockopt`
    /// can never be out of range, which the kernel rejects with EDOM.
    private static let maxSocketTimeoutSeconds: TimeInterval = 300
    private static let connectRetryDelays: [TimeInterval] = [0.25, 0.5, 0.75]

    let socketPath: String
    private let socketPassword: String?

    init(
        socketPath: String = MCPSocketBridge.resolveSocketPath(),
        socketPassword: String? = MCPSocketBridge.resolveSocketPassword()
    ) {
        self.socketPath = socketPath
        self.socketPassword = socketPassword?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    /// Resolves the Programa control socket path the same way the CLI does
    /// (`CLI/programa.swift`'s `run()`, lines ~1387-1405): `PROGRAMA_SOCKET_PATH`
    /// takes priority over `PROGRAMA_SOCKET` (matching `tests_v2/cmux.py:58-60`),
    /// then falls back to `CLISocketPathResolver`'s tagged-debug / discovery /
    /// stable-default logic, shared via `CLI/SocketPathResolution.swift`.
    static func resolveSocketPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        let envSocketPath: String? = {
            for key in ["PROGRAMA_SOCKET_PATH", "PROGRAMA_SOCKET"] {
                guard let raw = environment[key] else { continue }
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
            return nil
        }()
        let requestedPath = envSocketPath ?? CLISocketPathResolver.defaultSocketPath
        let source: CLISocketPathSource
        if let envSocketPath {
            source = CLISocketPathResolver.isImplicitDefaultPath(envSocketPath) ? .implicitDefault : .environment
        } else {
            source = .implicitDefault
        }
        return CLISocketPathResolver.resolve(requestedPath: requestedPath, source: source, environment: environment)
    }

    static func resolveSocketPassword(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        environment["PROGRAMA_SOCKET_PASSWORD"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    /// Sends one v2 request (`{"id","method","params"}`) and returns the
    /// decoded `result` object on success, matching `SocketClient.sendV2`.
    func send(method: String, params: [String: Any] = [:]) throws -> [String: Any] {
        let socketFD = try Self.connectWithTransientRetry(path: socketPath)
        defer { Darwin.close(socketFD) }

        if let socketPassword {
            _ = try Self.sendRequest(
                method: "auth.login",
                params: ["password": socketPassword],
                socketFD: socketFD
            )
        }
        return try Self.sendRequest(method: method, params: params, socketFD: socketFD)
    }

    private static func sendRequest(
        method: String,
        params: [String: Any],
        socketFD: Int32
    ) throws -> [String: Any] {
        let requestLine = try encodeRequest(method: method, params: params)
        try Self.writeAll(Data((requestLine + "\n").utf8), socketFD: socketFD)
        let raw = try Self.readResponse(
            socketFD: socketFD,
            timeout: responseTimeout(method: method, params: params)
        )

        // The server may return a plain-text error (e.g. "ERROR: Access denied
        // ...") before the JSON protocol starts -- surface it distinctly
        // instead of letting JSON parsing throw a confusing error.
        if raw.hasPrefix("ERROR:") {
            throw MCPSocketBridgeError.legacyError(raw)
        }

        guard let responseData = raw.data(using: .utf8) else {
            throw MCPSocketBridgeError.invalidResponse("Invalid UTF-8 v2 response")
        }
        guard let response = try? JSONSerialization.jsonObject(with: responseData, options: []) as? [String: Any] else {
            throw MCPSocketBridgeError.invalidResponse("Invalid v2 response: \(raw)")
        }

        if let ok = response["ok"] as? Bool, ok {
            return (response["result"] as? [String: Any]) ?? [:]
        }

        if let error = response["error"] as? [String: Any] {
            let code = (error["code"] as? String) ?? "error"
            let message = (error["message"] as? String) ?? "Unknown v2 error"
            if ["auth_required", "auth_failed", "auth_unconfigured"].contains(code) {
                let guidance = code == "auth_required"
                    ? "Programa socket authentication is required. Set PROGRAMA_SOCKET_PASSWORD for programa-mcp."
                    : "Programa socket authentication failed. Verify PROGRAMA_SOCKET_PASSWORD."
                throw MCPSocketBridgeError.authentication(guidance)
            }
            throw MCPSocketBridgeError.v2Error(code: code, message: message)
        }

        throw MCPSocketBridgeError.invalidResponse("v2 request failed: \(raw)")
    }

    static func responseTimeout(method: String, params: [String: Any]) -> TimeInterval {
        let timeoutMs: Int
        switch method {
        case "surface.wait":
            timeoutMs = timeoutInteger(params["timeout_ms"]) ?? timeoutInteger(params["timeout"]) ?? 30_000
        case "browser.wait":
            timeoutMs = timeoutInteger(params["timeout_ms"]) ?? 5_000
        case "browser.download.wait":
            timeoutMs = timeoutInteger(params["timeout_ms"]) ?? timeoutInteger(params["timeout"]) ?? 10_000
        default:
            return defaultResponseTimeoutSeconds
        }
        return max(defaultResponseTimeoutSeconds, Double(max(1, timeoutMs)) / 1000.0 + 2)
    }

    /// Match the server's v2Int parsing, including invalid-primary fallback.
    private static func timeoutInteger(_ raw: Any?) -> Int? {
        guard let raw else { return nil }
        if let number = raw as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let value = number.doubleValue
            guard value.isFinite, floor(value) == value else { return nil }
            return Int(exactly: value)
        }
        if let value = raw as? Int { return value }
        if let value = raw as? String {
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    // MARK: - Request encoding

    private static func encodeRequest(method: String, params: [String: Any]) throws -> String {
        let request: [String: Any] = [
            "id": UUID().uuidString,
            "method": method,
            "params": params,
        ]
        guard JSONSerialization.isValidJSONObject(request) else {
            throw MCPSocketBridgeError.invalidResponse("Failed to encode v2 request")
        }
        let requestData = try JSONSerialization.data(withJSONObject: request, options: [])
        guard let requestLine = String(data: requestData, encoding: .utf8) else {
            throw MCPSocketBridgeError.invalidResponse("Failed to encode v2 request")
        }
        return requestLine
    }

    // MARK: - Connection

    /// A `connect()`/`stat()` failure, carrying the raw errno so the retry
    /// loop can decide whether it's worth retrying -- mirrors
    /// `SocketConnectError`/`isTransient` in `CLI/programa.swift:20-33`.
    private struct ConnectFailure: Error {
        let errnoValue: Int32?
        let message: String

        var isTransient: Bool {
            guard let errnoValue else { return false }
            return errnoValue == ECONNREFUSED || errnoValue == ENOENT
        }
    }

    /// Like the CLI's `connectWithTransientRetry()` (`CLI/programa.swift:460-473`):
    /// retries a transient failure (socket file missing / nothing listening
    /// yet) up to 3 total attempts spread over ~1.5s, so a tool call doesn't
    /// fail outright just because it raced an app restart. Non-transient
    /// failures (wrong file type, ownership mismatch) fail immediately.
    private static func connectWithTransientRetry(path: String) throws -> Int32 {
        var attempt = 0
        while true {
            do {
                return try connectOnce(path: path)
            } catch let failure as ConnectFailure where failure.isTransient && attempt < connectRetryDelays.count {
                Thread.sleep(forTimeInterval: connectRetryDelays[attempt])
                attempt += 1
            } catch let failure as ConnectFailure {
                throw MCPSocketBridgeError.transport(failure.message)
            }
        }
    }

    private static func connectOnce(path: String) throws -> Int32 {
        // Verify the socket is owned by the current user to prevent
        // fake-socket attacks -- mirrors `SocketClient.connectOnce()`
        // (`CLI/programa.swift:551-607`).
        var st = stat()
        guard stat(path, &st) == 0 else {
            throw ConnectFailure(errnoValue: errno, message: "Socket not found at \(path)")
        }
        guard (st.st_mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK) else {
            throw ConnectFailure(errnoValue: nil, message: "Path exists at \(path) but is not a Unix socket")
        }
        guard st.st_uid == getuid() else {
            throw ConnectFailure(errnoValue: nil, message: "Socket at \(path) is not owned by the current user -- refusing to connect")
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw ConnectFailure(errnoValue: nil, message: "Failed to create socket")
        }

        do {
            try configureWriteSafety(fd: fd, timeout: defaultResponseTimeoutSeconds)
        } catch {
            Darwin.close(fd)
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
                Darwin.connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result == 0 {
            return fd
        }

        let connectErrno = errno
        Darwin.close(fd)
        throw ConnectFailure(
            errnoValue: connectErrno,
            message: "Failed to connect to socket at \(path) (\(String(cString: strerror(connectErrno))), errno \(connectErrno))"
        )
    }

    private static func configureWriteSafety(fd: Int32, timeout: TimeInterval) throws {
        var interval = socketTimeval(for: timeout)
        let sendTimeoutResult = withUnsafePointer(to: &interval) { ptr in
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, ptr, socklen_t(MemoryLayout<timeval>.size))
        }
        guard sendTimeoutResult == 0 else {
            throw MCPSocketBridgeError.transport("Failed to configure socket write timeout")
        }

        var noSigPipe: Int32 = 1
        let noSigPipeResult = withUnsafePointer(to: &noSigPipe) { ptr in
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, ptr, socklen_t(MemoryLayout<Int32>.size))
        }
        guard noSigPipeResult == 0 else {
            throw MCPSocketBridgeError.transport("Failed to disable SIGPIPE on socket")
        }
    }

    private static func configureReceiveTimeout(fd: Int32, timeout: TimeInterval) throws {
        var interval = socketTimeval(for: timeout)
        let result = withUnsafePointer(to: &interval) { ptr in
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, ptr, socklen_t(MemoryLayout<timeval>.size))
        }
        guard result == 0 else {
            let code = errno
            throw MCPSocketBridgeError.transport(
                "Failed to configure socket receive timeout (\(String(cString: strerror(code))), errno \(code))"
            )
        }
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

    // MARK: - I/O

    private static func writeAll(_ data: Data, socketFD: Int32) throws {
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
                    if errorCode == EAGAIN || errorCode == EWOULDBLOCK || errorCode == ETIMEDOUT {
                        throw MCPSocketBridgeError.transport("Command timed out")
                    }
                    let reason = String(cString: strerror(errorCode))
                    throw MCPSocketBridgeError.transport("Failed to write to socket (\(reason), errno \(errorCode))")
                }
                if written == 0 {
                    throw MCPSocketBridgeError.transport("Failed to write to socket")
                }
                offset += written
            }
        }
    }

    /// Reads until an idle gap after the first newline, mirroring
    /// `SocketClient.send`'s multiline read strategy
    /// (`CLI/programa.swift:505-548`) so a buffered/multi-line response isn't
    /// truncated.
    private static func readResponse(socketFD: Int32, timeout: TimeInterval) throws -> String {
        var data = Data()
        var sawNewline = false
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var lastChunkAt = ProcessInfo.processInfo.systemUptime

        while true {
            let now = ProcessInfo.processInfo.systemUptime
            var remaining = deadline - now
            if sawNewline {
                remaining = min(remaining, multilineResponseIdleTimeoutSeconds - (now - lastChunkAt))
            }
            guard remaining > 0 else {
                if sawNewline { break }
                throw MCPSocketBridgeError.transport("Command timed out")
            }
            do {
                try configureReceiveTimeout(fd: socketFD, timeout: remaining)
            } catch {
                // A peer that closes right after replying leaves the socket torn down,
                // and macOS then rejects setsockopt with EINVAL. If a full line is
                // already buffered that is a complete response, not a failure.
                if sawNewline { break }
                throw error
            }

            var buffer = [UInt8](repeating: 0, count: 8192)
            let count = Darwin.read(socketFD, &buffer, buffer.count)
            if count < 0 {
                let errorCode = errno
                if errorCode == EINTR || errorCode == EAGAIN || errorCode == EWOULDBLOCK {
                    // Receive timeouts are capped at 300 seconds. Retry slices
                    // and interruptions against the same whole-response deadline.
                    continue
                }
                throw MCPSocketBridgeError.transport("Socket read error")
            }
            if count == 0 {
                break
            }
            lastChunkAt = ProcessInfo.processInfo.systemUptime
            data.append(buffer, count: count)
            if data.contains(UInt8(0x0A)) {
                sawNewline = true
            }
        }

        guard var response = String(data: data, encoding: .utf8) else {
            throw MCPSocketBridgeError.invalidResponse("Invalid UTF-8 response")
        }
        if response.hasSuffix("\n") {
            response.removeLast()
        }
        return response
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
