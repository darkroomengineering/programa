#if DEBUG
import XCTest
@testable import Bonsplit

final class DebugEventLogTests: XCTestCase {
    func testProgramaDebugLogWinsOverEverything() {
        let env: [String: String] = [
            "PROGRAMA_DEBUG_LOG": "/tmp/explicit-programa.log",
            "CMUX_DEBUG_LOG": "/tmp/explicit-cmux.log",
            "PROGRAMA_TAG": "my-tag",
            "CMUX_TAG": "old-tag"
        ]
        XCTAssertEqual(DebugEventLog.resolveLogPath(env: env), "/tmp/explicit-programa.log")
    }

    func testCmuxDebugLogWinsWhenNoProgramaDebugLog() {
        let env: [String: String] = [
            "CMUX_DEBUG_LOG": "/tmp/explicit-cmux.log",
            "PROGRAMA_TAG": "my-tag"
        ]
        XCTAssertEqual(DebugEventLog.resolveLogPath(env: env), "/tmp/explicit-cmux.log")
    }

    func testProgramaTagProducesProgramaDebugPath() {
        let env: [String: String] = [
            "PROGRAMA_TAG": "my-tag"
        ]
        XCTAssertEqual(DebugEventLog.resolveLogPath(env: env), "/tmp/programa-debug-my-tag.log")
    }

    func testEmptyEnvFallsBackToBundleIdOrDefaultPath() {
        let resolved = DebugEventLog.resolveLogPath(env: [:])
        XCTAssertTrue(
            resolved == "/tmp/programa-debug.log" || resolved.hasPrefix("/tmp/programa-debug-"),
            "Expected default or bundle-id-derived programa-debug path, got \(resolved)"
        )
    }
}
#endif
