import XCTest

#if canImport(Programa_DEV)
@testable import Programa_DEV
#elseif canImport(Programa)
@testable import Programa
#endif

final class PaneHandoffFormatterTests: XCTestCase {
    func testTrailingBlankLinesAreTrimmedAndNoteIsOmittedWithoutOne() {
        let text = "$ make test\nFAIL: testParser\n\n   \n\n"
        XCTAssertEqual(
            PaneHandoffFormatter.format(sourceLabel: "build (surface:3)", text: text, note: nil),
            "Context from build (surface:3):\n$ make test\nFAIL: testParser\n"
        )
    }

    func testInnerBlankLinesAndCRLFAreKeptAsPlainNewlines() {
        XCTAssertEqual(
            PaneHandoffFormatter.format(sourceLabel: "logs", text: "one\r\n\r\ntwo\r\n", note: nil),
            "Context from logs:\none\n\ntwo\n"
        )
    }

    func testNoteIsAppendedAfterABlankLine() {
        XCTAssertEqual(
            PaneHandoffFormatter.format(sourceLabel: "server", text: "listening on :3000", note: "  Why is port 3000 busy?\n"),
            "Context from server:\nlistening on :3000\n\nNote: Why is port 3000 busy?\n"
        )
    }

    func testWhitespaceOnlyNoteIsOmitted() {
        XCTAssertEqual(
            PaneHandoffFormatter.format(sourceLabel: "server", text: "ok", note: " \n "),
            "Context from server:\nok\n"
        )
    }

    func testEmptySourceSaysThereIsNoOutput() {
        XCTAssertEqual(
            PaneHandoffFormatter.format(sourceLabel: "idle", text: "", note: nil),
            "Context from idle:\n(no output)\n"
        )
        XCTAssertEqual(
            PaneHandoffFormatter.format(sourceLabel: "idle", text: "\n\n  \n", note: "check this"),
            "Context from idle:\n(no output)\n\nNote: check this\n"
        )
    }
}
