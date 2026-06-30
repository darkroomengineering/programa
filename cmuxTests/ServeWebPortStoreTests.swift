import XCTest
import Foundation
import Darwin

#if canImport(Programa_DEV)
@testable import Programa_DEV
#elseif canImport(Programa)
@testable import Programa
#endif

/// Tests for #21: persisting and reusing the VS Code serve-web port so the embedded
/// browser keeps the same URL across restarts, while falling back to an OS-assigned
/// port when the persisted one is no longer free.
final class ServeWebPortStoreTests: XCTestCase {
    private func makeTempDir() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("serve-web-port-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testPortArgumentIsZeroWhenNoFile() {
        let dir = makeTempDir()
        XCTAssertEqual(
            ServeWebPortStore.portArgument(persistedIn: dir, isPortAvailable: { _ in true }),
            "0"
        )
    }

    func testPersistThenReuseRoundTrips() {
        let dir = makeTempDir()
        ServeWebPortStore.persist(port: 50_321, in: dir)
        XCTAssertEqual(
            ServeWebPortStore.portArgument(persistedIn: dir, isPortAvailable: { _ in true }),
            "50321"
        )
    }

    func testPersistedPortIgnoredWhenUnavailable() {
        let dir = makeTempDir()
        ServeWebPortStore.persist(port: 50_321, in: dir)
        XCTAssertEqual(
            ServeWebPortStore.portArgument(persistedIn: dir, isPortAvailable: { _ in false }),
            "0",
            "An occupied persisted port must fall back to OS-assigned"
        )
    }

    func testNilDirectoryIsZero() {
        XCTAssertEqual(
            ServeWebPortStore.portArgument(persistedIn: nil, isPortAvailable: { _ in true }),
            "0"
        )
    }

    func testPersistRejectsOutOfRangePorts() {
        let dir = makeTempDir()
        ServeWebPortStore.persist(port: 0, in: dir)
        ServeWebPortStore.persist(port: 70_000, in: dir)
        // Nothing valid was written, so the OS-assigned fallback still applies.
        XCTAssertEqual(
            ServeWebPortStore.portArgument(persistedIn: dir, isPortAvailable: { _ in true }),
            "0"
        )
    }

    func testParsePort() {
        XCTAssertEqual(ServeWebPortStore.parsePort(" 8080 \n"), 8080)
        XCTAssertEqual(ServeWebPortStore.parsePort("1"), 1)
        XCTAssertEqual(ServeWebPortStore.parsePort("65535"), 65535)
        XCTAssertNil(ServeWebPortStore.parsePort(""))
        XCTAssertNil(ServeWebPortStore.parsePort("notaport"))
        XCTAssertNil(ServeWebPortStore.parsePort("0"))
        XCTAssertNil(ServeWebPortStore.parsePort("65536"))
        XCTAssertNil(ServeWebPortStore.parsePort("-1"))
    }

    func testIsPortAvailableDetectsOccupiedPort() throws {
        // Bind+listen on an OS-assigned loopback port, then assert the store reports it busy.
        let listenFd = socket(AF_INET, SOCK_STREAM, 0)
        try XCTSkipIf(listenFd < 0, "could not create probe socket")
        defer { close(listenFd) }

        var reuse: Int32 = 1
        _ = setsockopt(listenFd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0 // OS-assigned
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(listenFd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        try XCTSkipIf(bound != 0, "could not bind probe socket")
        try XCTSkipIf(listen(listenFd, 1) != 0, "could not listen on probe socket")

        var boundAddr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let got = withUnsafeMutablePointer(to: &boundAddr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                getsockname(listenFd, sockaddrPointer, &len)
            }
        }
        try XCTSkipIf(got != 0, "could not read probe port")
        let port = Int(UInt16(bigEndian: boundAddr.sin_port))

        XCTAssertFalse(
            ServeWebPortStore.isPortAvailable(port),
            "A port held by a live listener must report as unavailable"
        )
    }
}
