import XCTest
import Darwin

#if canImport(Programa_DEV)
@testable import Programa_DEV
#elseif canImport(Programa)
@testable import Programa
#endif

/// Exercises `MCPSocketBridge` (`CLI-MCP/MCPSocketBridge.swift`) and
/// `MCPSocketBridge.resolveSocketPath` / `CLISocketPathResolver`
/// (`CLI/SocketPathResolution.swift`) through their real, public entry points --
/// no source-text or signature assertions.
///
/// `MCPSocketBridge.swift` and `SocketPathResolution.swift` import only
/// `Foundation`/`Darwin`, not the `MCP` SDK, so they're added directly to this
/// (app-dependency-free) test target rather than pulling the SDK into
/// `programaTests` -- see the Phase 6 test-plan writeup for the full
/// target-structure rationale. `ToolCatalog`/`MCPErrorMapping`, which DO import
/// `MCP`, are instead exercised over the wire by
/// `tests_v2/test_mcp_server_e2e.py`'s `tools/list` assertions -- a genuinely
/// stronger check, since it verifies what MCP clients actually see rather than
/// a compiled-but-untransmitted Swift table.
///
/// `send(method:params:)` connects to a real Unix domain socket per call (no
/// pooling), so these tests stand up a throwaway local listener per case (same
/// `bindUnixSocket`/`startMockServer` pattern as
/// and feed it canned v2 responses --
/// this is real runtime behavior through the bridge's actual `send()` path,
/// not a hand-decoded JSON fixture.
final class MCPSocketBridgeTests: XCTestCase {
    // MARK: - Mock v2 socket server

    private func makeSocketPath(_ name: String) -> String {
        let shortID = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mcpbridge-\(name.prefix(12))-\(shortID).sock")
            .path
    }

    private func bindUnixSocket(at path: String) throws -> Int32 {
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [
                NSLocalizedDescriptionKey: "Failed to create Unix socket",
            ])
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxPathLength = MemoryLayout.size(ofValue: addr.sun_path)
        path.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                let buf = UnsafeMutableRawPointer(pathPtr).assumingMemoryBound(to: CChar.self)
                strncpy(buf, ptr, maxPathLength - 1)
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let code = Int(errno)
            Darwin.close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: code, userInfo: [
                NSLocalizedDescriptionKey: "Failed to bind Unix socket",
            ])
        }

        guard Darwin.listen(fd, 1) == 0 else {
            let code = Int(errno)
            Darwin.close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: code, userInfo: [
                NSLocalizedDescriptionKey: "Failed to listen on Unix socket",
            ])
        }

        return fd
    }

    /// Accepts exactly one connection, reads one newline-delimited request line (discarded --
    /// these tests only care about the canned response path), writes `responseLine` back, and
    /// closes the connection immediately so `MCPSocketBridge.readResponse` doesn't have to wait
    /// out its idle-gap timeout.
    @discardableResult
    private func serveOneCannedResponse(
        listenerFD: Int32,
        responseLine: String,
        capture: ReceivedRequestBox? = nil,
        responseDelay: TimeInterval = 0
    ) -> XCTestExpectation {
        let handled = expectation(description: "mock v2 socket handled one request")
        DispatchQueue.global(qos: .userInitiated).async {
            var clientAddr = sockaddr_un()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    Darwin.accept(listenerFD, sockaddrPtr, &clientAddrLen)
                }
            }
            guard clientFD >= 0 else {
                handled.fulfill()
                return
            }
            defer {
                Darwin.close(clientFD)
                handled.fulfill()
            }

            var pending = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            readLoop: while true {
                let count = Darwin.read(clientFD, &buffer, buffer.count)
                if count < 0 {
                    if errno == EINTR { continue }
                    return
                }
                if count == 0 { return }
                pending.append(buffer, count: count)
                if pending.contains(UInt8(0x0A)) { break readLoop }
            }
            capture?.set(pending)

            var noSigPipe: Int32 = 1
            _ = setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            if responseDelay > 0 { Thread.sleep(forTimeInterval: responseDelay) }

            let line = responseLine + "\n"
            _ = line.withCString { ptr in
                Darwin.write(clientFD, ptr, strlen(ptr))
            }
        }
        return handled
    }

    @discardableResult
    private func serveAuthenticatedSession(
        listenerFD: Int32,
        capture: ReceivedRequestSequenceBox
    ) -> XCTestExpectation {
        let handled = expectation(description: "mock password-authenticated v2 session handled two requests")
        DispatchQueue.global(qos: .userInitiated).async {
            defer { handled.fulfill() }
            let clientFD = Darwin.accept(listenerFD, nil, nil)
            guard clientFD >= 0 else { return }
            defer { Darwin.close(clientFD) }

            func readLine() -> Data? {
                var data = Data()
                while true {
                    var byte: UInt8 = 0
                    let count = Darwin.read(clientFD, &byte, 1)
                    if count < 0 {
                        if errno == EINTR { continue }
                        return nil
                    }
                    if count == 0 { return nil }
                    data.append(byte)
                    if byte == 0x0A { return data }
                }
            }

            guard let authRequest = readLine() else { return }
            capture.append(authRequest)
            _ = "{\"id\":\"auth\",\"ok\":true,\"result\":{\"authenticated\":true}}\n".withCString {
                Darwin.write(clientFD, $0, strlen($0))
            }

            guard let toolRequest = readLine() else { return }
            capture.append(toolRequest)
            _ = "{\"id\":\"tool\",\"ok\":true,\"result\":{\"pong\":true}}\n".withCString {
                Darwin.write(clientFD, $0, strlen($0))
            }
        }
        return handled
    }

    // MARK: - `send(method:params:)` canned-response cases

    func testSurfaceWaitKeepsConnectionUntilAdvertisedOperationDeadline() throws {
        let path = makeSocketPath("wait-deadline")
        let listener = try bindUnixSocket(at: path)
        defer { Darwin.close(listener); unlink(path) }
        let handled = serveOneCannedResponse(
            listenerFD: listener,
            responseLine: #"{"ok":true,"result":{"matched":true}}"#,
            responseDelay: 16
        )
        // A legitimate wait can finish after the transport's old 15-second timeout.
        // Always join the server, including the red baseline's throwing path.
        defer { wait(for: [handled], timeout: 20) }
        let result = try MCPSocketBridge(socketPath: path, socketPassword: nil)
            .send(method: "surface.wait", params: ["pattern": "ready"])
        XCTAssertEqual(result["matched"] as? Bool, true,
                       "A wait that finishes within its default 30-second budget must reach the caller.")
    }

    func testSendDecodesV2SuccessEnvelopeIntoResultDictionary() throws {
        let socketPath = makeSocketPath("success")
        let listenerFD = try bindUnixSocket(at: socketPath)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let handled = serveOneCannedResponse(
            listenerFD: listenerFD,
            responseLine: #"{"id":"1","ok":true,"result":{"pong":true}}"#
        )

        let bridge = MCPSocketBridge(socketPath: socketPath)
        let result = try bridge.send(method: "system.ping")

        wait(for: [handled], timeout: 5)
        XCTAssertEqual(result["pong"] as? Bool, true)
    }

    func testSendAuthenticatesOnSameConnectionBeforeToolRequest() throws {
        let socketPath = makeSocketPath("password")
        let listenerFD = try bindUnixSocket(at: socketPath)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let received = ReceivedRequestSequenceBox()
        let handled = serveAuthenticatedSession(listenerFD: listenerFD, capture: received)
        let bridge = MCPSocketBridge(socketPath: socketPath, socketPassword: "s3cr3t")
        let result = try bridge.send(method: "system.ping")

        wait(for: [handled], timeout: 5)
        XCTAssertEqual(result["pong"] as? Bool, true)
        let requests = try received.values.map { data in
            try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0]["method"] as? String, "auth.login")
        XCTAssertEqual((requests[0]["params"] as? [String: Any])?["password"] as? String, "s3cr3t")
        XCTAssertEqual(requests[1]["method"] as? String, "system.ping")
    }

    func testSendWithoutPasswordReportsActionableAuthenticationError() throws {
        let socketPath = makeSocketPath("authrequired")
        let listenerFD = try bindUnixSocket(at: socketPath)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let handled = serveOneCannedResponse(
            listenerFD: listenerFD,
            responseLine: #"{"id":"1","ok":false,"error":{"code":"auth_required","message":"Authentication required"}}"#
        )
        let bridge = MCPSocketBridge(socketPath: socketPath, socketPassword: nil)

        XCTAssertThrowsError(try bridge.send(method: "system.ping")) { error in
            guard case .authentication(let message) = error as? MCPSocketBridgeError else {
                XCTFail("Expected explicit authentication error, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("PROGRAMA_SOCKET_PASSWORD"))
        }
        wait(for: [handled], timeout: 5)
    }

    func testSendThrowsV2ErrorCarryingSameCodeAndMessageOnV2ErrorEnvelope() throws {
        let socketPath = makeSocketPath("v2error")
        let listenerFD = try bindUnixSocket(at: socketPath)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let handled = serveOneCannedResponse(
            listenerFD: listenerFD,
            responseLine: #"{"id":"1","ok":false,"error":{"code":"not_found","message":"Surface not found"}}"#
        )

        let bridge = MCPSocketBridge(socketPath: socketPath)
        XCTAssertThrowsError(try bridge.send(method: "surface.read_text")) { error in
            guard let bridgeError = error as? MCPSocketBridgeError else {
                XCTFail("Expected MCPSocketBridgeError, got \(error)")
                return
            }
            guard case .v2Error(let code, let message) = bridgeError else {
                XCTFail("Expected .v2Error, got \(bridgeError)")
                return
            }
            // The v2 error's exact code/message must survive the bridge untouched -- a
            // caller (e.g. MCPErrorMapping) that needs to distinguish "not_found" from
            // any other failure depends on this, not on a flattened description string.
            XCTAssertEqual(code, "not_found")
            XCTAssertEqual(message, "Surface not found")
        }
        wait(for: [handled], timeout: 5)
    }

    func testSendThrowsLegacyErrorNotAJSONParseCrashOnBareErrorLine() throws {
        let socketPath = makeSocketPath("legacy")
        let listenerFD = try bindUnixSocket(at: socketPath)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        // Pre-JSON connection-level rejection, exactly as sent by
        // `Sources/TerminalController.swift`'s access-denial path (CLI/programa.swift:833-836
        // mirrors this same "ERROR:" prefix check).
        let handled = serveOneCannedResponse(listenerFD: listenerFD, responseLine: "ERROR: Access denied")

        let bridge = MCPSocketBridge(socketPath: socketPath)
        XCTAssertThrowsError(try bridge.send(method: "system.ping")) { error in
            guard let bridgeError = error as? MCPSocketBridgeError else {
                XCTFail("Expected MCPSocketBridgeError, got \(error)")
                return
            }
            guard case .legacyError(let message) = bridgeError else {
                XCTFail("A bare 'ERROR:' line must surface as .legacyError, not any other case (e.g. a JSON-decode .invalidResponse) -- got \(bridgeError)")
                return
            }
            XCTAssertEqual(message, "ERROR: Access denied")
        }
        wait(for: [handled], timeout: 5)
    }

    func testSendThrowsInvalidResponseOnMalformedNonErrorPrefixedBody() throws {
        let socketPath = makeSocketPath("malformed")
        let listenerFD = try bindUnixSocket(at: socketPath)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        // Not JSON and not "ERROR:"-prefixed -- the third distinct failure path
        // `MCPSocketBridge.send` has to handle without crashing.
        let handled = serveOneCannedResponse(listenerFD: listenerFD, responseLine: "not json at all")

        let bridge = MCPSocketBridge(socketPath: socketPath)
        XCTAssertThrowsError(try bridge.send(method: "system.ping")) { error in
            guard let bridgeError = error as? MCPSocketBridgeError else {
                XCTFail("Expected MCPSocketBridgeError, got \(error)")
                return
            }
            guard case .invalidResponse = bridgeError else {
                XCTFail("Expected .invalidResponse, got \(bridgeError)")
                return
            }
        }
        wait(for: [handled], timeout: 5)
    }

    // MARK: - `MCPSocketBridge.resolveSocketPath(environment:)`

    /// `PROGRAMA_SOCKET_PATH` set to a path that isn't the implicit default is used verbatim --
    /// the sidecar must never silently redirect an explicit override.
    func testResolveSocketPathUsesProgramaSocketPathOverrideVerbatim() {
        let resolved = MCPSocketBridge.resolveSocketPath(environment: [
            "PROGRAMA_SOCKET_PATH": "/tmp/mcp-bridge-test-explicit-a.sock",
        ])
        XCTAssertEqual(resolved, "/tmp/mcp-bridge-test-explicit-a.sock")
    }

    /// `PROGRAMA_SOCKET` is the fallback when `PROGRAMA_SOCKET_PATH` is unset -- the same
    /// precedence `tests_v2/cmux.py` and the CLI rely on.
    func testResolveSocketPathFallsBackToProgramaSocketWhenPathUnset() {
        let resolved = MCPSocketBridge.resolveSocketPath(environment: [
            "PROGRAMA_SOCKET": "/tmp/mcp-bridge-test-explicit-b.sock",
        ])
        XCTAssertEqual(resolved, "/tmp/mcp-bridge-test-explicit-b.sock")
    }

    /// When both are set, `PROGRAMA_SOCKET_PATH` wins -- getting this precedence backwards
    /// would silently point the MCP sidecar at the wrong app instance whenever both env vars
    /// happen to be exported (e.g. from a Programa-launched shell), which is exactly the
    /// "wrong socket" failure mode this resolver exists to prevent.
    func testResolveSocketPathPrefersProgramaSocketPathOverProgramaSocketWhenBothSet() {
        let resolved = MCPSocketBridge.resolveSocketPath(environment: [
            "PROGRAMA_SOCKET_PATH": "/tmp/mcp-bridge-test-precedence-path.sock",
            "PROGRAMA_SOCKET": "/tmp/mcp-bridge-test-precedence-socket.sock",
        ])
        XCTAssertEqual(resolved, "/tmp/mcp-bridge-test-precedence-path.sock")
    }

    /// A whitespace-only override must be treated as unset, not as a literal (and useless)
    /// socket path -- guards the `trimmed.isEmpty` branch in `resolveSocketPath`.
    func testResolveSocketPathIgnoresWhitespaceOnlyPathOverrideAndFallsBackToSocket() {
        let resolved = MCPSocketBridge.resolveSocketPath(environment: [
            "PROGRAMA_SOCKET_PATH": "   ",
            "PROGRAMA_SOCKET": "/tmp/mcp-bridge-test-whitespace-fallback.sock",
        ])
        XCTAssertEqual(resolved, "/tmp/mcp-bridge-test-whitespace-fallback.sock")
    }

    /// With no override env vars, a real, currently-accepting tagged-debug socket
    /// (`PROGRAMA_TAG`) must be preferred over the (absent) stable default -- this is the
    /// exact ordering that lets an agent working in a tagged build talk to ITS app instance
    /// instead of silently falling through to another one. Uses a real bound-and-listening
    /// Unix socket (not just a touched file) because `resolve()`'s preference check is a real
    /// `connect()` syscall, not a `stat()`.
    func testResolveSocketPathPrefersConnectableTaggedSocketOverAbsentDefault() throws {
        let tag = "mcpbridgetest" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(8))
        let taggedSocketPath = "/tmp/programa-debug-\(tag).sock"
        let listenerFD = try bindUnixSocket(at: taggedSocketPath)
        defer {
            Darwin.close(listenerFD)
            unlink(taggedSocketPath)
        }

        let resolved = MCPSocketBridge.resolveSocketPath(environment: ["PROGRAMA_TAG": tag])
        XCTAssertEqual(resolved, taggedSocketPath)
    }

    // MARK: - Wire framing

    /// Tool arguments reach this bridge from a model, so a string argument containing a
    /// newline is attacker-reachable input against a protocol where one line is one command.
    /// If such an argument were ever concatenated into the request instead of encoded, the
    /// tail would arrive as a second, independently dispatched command. Today the whole
    /// envelope goes through `JSONSerialization`, which escapes the newline; this pins that
    /// property so a future hand-rolled encoder cannot quietly give it up.
    func testSendEncodesEmbeddedNewlineRatherThanFramingASecondCommand() throws {
        let socketPath = makeSocketPath("framing")
        let listenerFD = try bindUnixSocket(at: socketPath)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let received = ReceivedRequestBox()
        let handled = serveOneCannedResponse(
            listenerFD: listenerFD,
            responseLine: #"{"id":"1","ok":true,"result":{}}"#,
            capture: received
        )

        let bridge = MCPSocketBridge(socketPath: socketPath)
        let smuggled = "hello\n{\"id\":\"x\",\"method\":\"window.close\",\"params\":{}}"
        _ = try? bridge.send(method: "surface.send_text", params: ["text": smuggled])
        wait(for: [handled], timeout: 5.0)

        let raw = try XCTUnwrap(received.value)
        XCTAssertEqual(
            raw.filter { $0 == UInt8(0x0A) }.count,
            1,
            "The request must be exactly one line; a second newline means the argument framed its own command."
        )

        let line = try XCTUnwrap(String(data: raw, encoding: .utf8))
            .trimmingCharacters(in: .newlines)
        let decoded = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        )
        XCTAssertEqual(decoded["method"] as? String, "surface.send_text")
        let params = try XCTUnwrap(decoded["params"] as? [String: Any])
        XCTAssertEqual(
            params["text"] as? String,
            smuggled,
            "The newline must survive as data inside the argument, not as framing."
        )
    }
}

/// Collects the bytes a mock server received, so a test can assert on wire framing.
private final class ReceivedRequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Data?

    var value: Data? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func set(_ data: Data) {
        lock.lock()
        storage = data
        lock.unlock()
    }
}

private final class ReceivedRequestSequenceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Data] = []

    var values: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ data: Data) {
        lock.lock()
        storage.append(data)
        lock.unlock()
    }
}
