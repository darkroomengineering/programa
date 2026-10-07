import XCTest
import Darwin

#if canImport(Programa_DEV)
@testable import Programa_DEV
#elseif canImport(Programa)
@testable import Programa
#endif

/// Pure decision functions behind the socket fix sweep. Each assertion encodes the rule a
/// socket caller depends on, so breaking the rule fails the case.
final class SocketFixSweepPureRuleTests: XCTestCase {
    // SOCK-09: a JS timeout in the isolated world already burned the caller's budget, and the
    // script may have side effects, so it must never be replayed in the page world.

    // SOCK-12: the cookie domain filter is a host-suffix match, not a substring match.

    // SOCK-14: CRLF is a single Return key press; a lone LF is still its own key.
    func testSocketKeyChunksTreatCRLFAsOneReturn() {
        XCTAssertEqual(
            TerminalController.socketKeyChunks("ls\r\n"),
            [.text("ls"), .control("\r")]
        )
        XCTAssertEqual(
            TerminalController.socketKeyChunks("a\nb"),
            [.text("a"), .control("\n"), .text("b")]
        )
    }
}

@MainActor
final class SocketFixSweepAgentStateTests: XCTestCase {
    // SOCK-24: a finished helper reports as an outcome, not as the workspace's live state.
    func testFailedHelperDoesNotPinWorkspaceActivityState() throws {
        let workspace = Workspace()
        let panel = try XCTUnwrap(workspace.focusedPanelId)
        workspace.updatePanelAgentState(panelId: panel, state: .idle)
        let registry = AgentSupervisionRegistry(capacity: 4)
        _ = try registry.start(
            host: "codex",
            state: .failed,
            placement: .runsWithParent,
            workspaceId: workspace.id
        )
        let records = registry.records()

        XCTAssertEqual(
            AgentSupervisionMetadata.currentActivityState(for: workspace, records: records),
            "idle"
        )
        XCTAssertEqual(AgentSupervisionMetadata.helperOutcomes(records: records)["failed"], 1)
    }
}

#if DEBUG
/// SOCK-02: a pending `surface.wait` blocks only its own connection. The in-command marker that
/// suppresses app activation must not leak onto the main thread while that wait is registered.
@MainActor
final class SocketFixSweepPendingWaitTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TerminalController.shared.stop()
    }

    override func tearDown() {
        TerminalController.shared.stop()
        super.tearDown()
    }

    func testPendingSurfaceWaitDoesNotMarkMainThreadAsInSocketCommand() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("programa-sock02-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let tabManager = TabManager(initialWorkingDirectory: directoryURL.path)
        let workspace = try XCTUnwrap(tabManager.selectedWorkspace)
        let surfaceId = try XCTUnwrap(workspace.focusedPanelId)
        XCTAssertTrue(tabManager.updateSurfaceAgentState(
            tabId: workspace.id, surfaceId: surfaceId, state: .idle, source: .hooks))

        let shortID = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        let socketPath = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sk02-\(shortID).sock").path
        TerminalController.shared.start(tabManager: tabManager, socketPath: socketPath, accessMode: .allowAll)
        defer {
            // Release the waiter so the connection thread finishes before the controller stops.
            _ = tabManager.updateSurfaceAgentState(
                tabId: workspace.id, surfaceId: surfaceId, state: .working, source: .hooks)
            TerminalController.shared.stop()
        }

        let socketDeadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: socketPath), Date() < socketDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath), "socket never appeared")

        // Client A: its own connection, blocked inside surface.wait.
        let waitDone = expectation(description: "surface.wait returned")
        let fd = try Self.connect(to: socketPath)
        defer { Darwin.close(fd) }
        let request: [String: Any] = [
            "jsonrpc": "2.0", "id": 1, "method": "surface.wait",
            "params": [
                "workspace_id": workspace.id.uuidString,
                "surface_id": surfaceId.uuidString,
                "agent_state": "working",
                "timeout_ms": 5_000,
            ],
        ]
        let line = try JSONSerialization.data(withJSONObject: request) + Data("\n".utf8)
        let written = line.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, line.count) }
        XCTAssertEqual(written, line.count)
        DispatchQueue.global().async {
            var byte: UInt8 = 0
            while Darwin.read(fd, &byte, 1) == 1, byte != 0x0A {}
            waitDone.fulfill()
        }

        let deadline = Date().addingTimeInterval(2)
        while !AgentStateWaitRegistry.shared.hasPendingWaiterForTesting(surfaceId: surfaceId, condition: .working),
              Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(
            AgentStateWaitRegistry.shared.hasPendingWaiterForTesting(surfaceId: surfaceId, condition: .working),
            "surface.wait did not register its waiter within 2s"
        )

        XCTAssertTrue(Thread.isMainThread)
        XCTAssertFalse(
            TerminalController.shouldSuppressSocketCommandActivation(),
            "A pending socket command must not mark the main thread as inside a socket command"
        )

        _ = tabManager.updateSurfaceAgentState(
            tabId: workspace.id, surfaceId: surfaceId, state: .working, source: .hooks)
        await fulfillment(of: [waitDone], timeout: 6)
    }

    private static func connect(to path: String) throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else {
            Darwin.close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENAMETOOLONG))
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            let cPath = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self)
            cPath.initialize(repeating: 0, count: capacity)
            for (i, b) in bytes.enumerated() { cPath[i] = CChar(bitPattern: b) }
        }
        let len = socklen_t(MemoryLayout<sa_family_t>.size + bytes.count + 1)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, len) }
        }
        guard rc == 0 else {
            let code = errno
            Darwin.close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        return fd
    }
}
#endif
