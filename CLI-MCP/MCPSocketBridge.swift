import Foundation
import CoreFoundation
import Darwin

/// Failure modes talking to Programa's v2 control socket.
///
/// The wire protocol (docs/socket-api.md) is newline-delimited
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
/// Socket connect/write/read is the CLI's `SocketClient` (`CLI/SocketClient.swift`,
/// compiled into both targets), so the two stay consistent on the path/peer-uid
/// checks, transient-connect retry, and timeouts. This type adds only the v2
/// envelope handling and the mapping into `MCPSocketBridgeError`. A v2 response is
/// one line, so each call returns as soon as its newline arrives.
///
/// Connects fresh per call and closes afterward -- matches the CLI's
/// per-invocation connection lifecycle (no pooling / keep-alive), which is
/// the right fit for how MCP tool calls arrive (one at a time, no shared
/// session state needed at the socket layer).
struct MCPSocketBridge {
    private static let defaultResponseTimeoutSeconds: TimeInterval = 15.0
    /// Blocking socket I/O must not run on the Swift cooperative pool; a long
    /// `surface.wait` would otherwise pin one of its few threads.
    private static let ioQueue = DispatchQueue(label: "com.programa.mcp.socket-io", qos: .userInitiated, attributes: .concurrent)

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
    /// (`CLICommandDispatcher.run()`): `PROGRAMA_SOCKET_PATH` takes priority over
    /// `PROGRAMA_SOCKET`, then `CLISocketPathResolver` (`CLI/SocketPathResolution.swift`)
    /// tries the `PROGRAMA_TAG` sockets and the stable defaults only.
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
        let client = SocketClient(path: socketPath)
        defer { client.close() }
        do {
            try client.connectWithTransientRetry()
        } catch {
            throw Self.bridgeError(from: error)
        }

        if let socketPassword {
            _ = try Self.sendRequest(
                method: V2MethodNames.authLogin,
                params: ["password": socketPassword],
                client: client
            )
        }
        return try Self.sendRequest(method: method, params: params, client: client)
    }

    /// `send` on a background queue, for async MCP handlers.
    func sendAsync(method: String, params: [String: Any] = [:]) async throws -> [String: Any] {
        struct Box: @unchecked Sendable { let value: [String: Any] }
        let params = Box(value: params)
        let box: Box = try await withCheckedThrowingContinuation { continuation in
            Self.ioQueue.async {
                do {
                    continuation.resume(returning: Box(value: try self.send(method: method, params: params.value)))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        return box.value
    }

    /// Socket-level failures from `SocketClient` (connect, write, read, timeout) are all
    /// transport errors here; the v2 envelope is interpreted separately in `sendRequest`.
    private static func bridgeError(from error: Error) -> MCPSocketBridgeError {
        if let bridgeError = error as? MCPSocketBridgeError { return bridgeError }
        return .transport(String(describing: error))
    }

    private static func sendRequest(
        method: String,
        params: [String: Any],
        client: SocketClient
    ) throws -> [String: Any] {
        let requestLine = try encodeRequest(method: method, params: params)
        let raw: String
        do {
            raw = try client.send(
                command: requestLine,
                minimumReceiveTimeout: responseTimeout(method: method, params: params),
                singleLine: true
            )
        } catch {
            throw bridgeError(from: error)
        }

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
        case V2MethodNames.surfaceWait:
            timeoutMs = timeoutInteger(params["timeout_ms"]) ?? timeoutInteger(params["timeout"]) ?? 30_000
        case V2MethodNames.browserWait:
            timeoutMs = timeoutInteger(params["timeout_ms"]) ?? 5_000
        case V2MethodNames.browserDownloadWait:
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
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
