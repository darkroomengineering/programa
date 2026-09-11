import XCTest
import AppKit

#if canImport(Programa_DEV)
@testable import Programa_DEV
#elseif canImport(Programa)
@testable import Programa
#endif

@MainActor
final class MarkdownFindRegressionTests: XCTestCase {
    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !predicate(), Date() < deadline {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertTrue(predicate(), "Find must update after debounce or a watched file replacement")
    }

    func testFindUsesDisplayedTextAndUTF16RangesAndWrapsIndividualHits() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        try "😀 **joined** phrase and joined *phrase*. [Visible](https://hidden.invalid/private)".write(to: url, atomically: true, encoding: .utf8)
        let panel = MarkdownPanel(workspaceId: UUID(), filePath: url.path)
        defer { panel.close(); try? FileManager.default.removeItem(at: url) }
        panel.startFind()
        let state = try XCTUnwrap(panel.searchState)
        state.needle = "joined phrase"
        try await waitUntil { state.matches.count == 2 }
        let first = try XCTUnwrap(state.selectedRange)
        XCTAssertEqual((state.searchText as NSString).substring(with: first), "joined phrase")
        XCTAssertEqual(first, (state.searchText as NSString).range(of: "joined phrase"))
        panel.findNext()
        let second = try XCTUnwrap(state.selectedRange)
        XCTAssertGreaterThan(second.location, first.location)
        XCTAssertEqual((state.searchText as NSString).substring(with: second), "joined phrase")
        panel.findNext()
        XCTAssertEqual(state.selectedRange, first)
        panel.findPrevious()
        XCTAssertEqual(state.selectedRange, second)
        state.needle = "hidden.invalid"
        try await waitUntil { state.matches.isEmpty }
        XCTAssertNil(state.selectedRange, "Link destinations are not displayed search text")
    }

    func testAtomicFileReplacementRefreshesFindAndCloseDiscardsSearch() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        try "original needle".write(to: url, atomically: true, encoding: .utf8)
        let panel = MarkdownPanel(workspaceId: UUID(), filePath: url.path)
        defer { panel.close(); try? FileManager.default.removeItem(at: url) }
        panel.startFind()
        let state = try XCTUnwrap(panel.searchState)
        state.needle = "needle"
        try await waitUntil { state.matches.count == 1 }
        try "replacement needle and needle".write(to: url, atomically: true, encoding: .utf8)
        try await waitUntil { state.searchText.contains("replacement") && state.matches.count == 2 }
        panel.close()
        XCTAssertNil(panel.searchState)
        XCTAssertTrue(state.matches.isEmpty)
        XCTAssertTrue(state.searchText.isEmpty)
        XCTAssertNil(state.selectedRange)
        panel.startFind()
        XCTAssertNil(panel.searchState, "A closed panel must not recreate search subscriptions")
    }

    func testNativeFindRevealsOffscreenMatchAndSelectsSeparateHitsInOneParagraph() throws {
        let view = MarkdownSearchTextView(frame: .zero)
        let text = String(repeating: "Filler paragraph.\n", count: 150) + "😀 needle and needle"
        let source = text as NSString
        let first = source.range(of: "needle")
        let second = source.range(of: "needle", options: .backwards)
        view.update(text: text, selectedRange: first)
        view.frame = NSRect(x: 0, y: 0, width: 360, height: 180)
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.textView.selectedRange(), first)
        let manager = try XCTUnwrap(view.textView.layoutManager)
        let container = try XCTUnwrap(view.textView.textContainer)
        let glyphs = manager.glyphRange(forCharacterRange: first, actualCharacterRange: nil)
        let bounds = manager.boundingRect(forGlyphRange: glyphs, in: container)
            .offsetBy(dx: view.textView.textContainerOrigin.x, dy: view.textView.textContainerOrigin.y)
        XCTAssertGreaterThan(bounds.minY, view.contentSize.height, "The fixture must place the hit below the initial viewport")
        XCTAssertTrue(view.documentVisibleRect.intersects(bounds), "Find must scroll its selected hit into view")
        view.update(text: text, selectedRange: second)
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.textView.selectedRange(), second)
        XCTAssertNotEqual(first, second)
        view.update(text: text, selectedRange: nil)
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.textView.selectedRange().length, 0)
    }
}

final class SidebarMarkdownRendererTests: XCTestCase {
    func testRenderWorkspaceDescriptionPreservesLineBreaks() throws {
        let rendered = try XCTUnwrap(
            SidebarMarkdownRenderer.renderWorkspaceDescription("First line\nSecond line")
        )

        XCTAssertEqual(String(rendered.characters), "First line\nSecond line")
    }

    func testRenderWorkspaceDescriptionPreservesInlineMarkdownAttributes() throws {
        let rendered = try XCTUnwrap(
            SidebarMarkdownRenderer.renderWorkspaceDescription("**Bold**\n[Link](https://example.com)")
        )

        XCTAssertEqual(String(rendered.characters), "Bold\nLink")
        XCTAssertTrue(rendered.runs.contains { $0.inlinePresentationIntent != nil })
        XCTAssertTrue(
            rendered.runs.contains { $0.link == URL(string: "https://example.com") }
        )
    }
}

final class MarkdownAlertFenceTests: XCTestCase {
    private func assertLiteralMarkdown(_ source: String, file: StaticString = #filePath, line: UInt = #line) {
        let segments = MarkdownAlertParser.segments(from: source)
        XCTAssertEqual(segments.count, 1, file: file, line: line)
        guard let first = segments.first, case .markdown(let text) = first else {
            return XCTFail("Code examples must not become alerts or compare widgets", file: file, line: line)
        }
        XCTAssertEqual(text, source, file: file, line: line)
    }

    func testAlertAndCompareMarkersInsideBacktickAndTildeFencesRemainLiteral() {
        for fence in ["```", "~~~"] {
            assertLiteralMarkdown("\(fence)markdown\n> [!NOTE]\n> literal example\n:::compare\n::: \n\(fence)")
        }
    }

    func testShorterFenceCannotEndLongerCodeExample() {
        for (outer, inner) in [("````", "```"), ("~~~~", "~~~")] {
            assertLiteralMarkdown("\(outer)markdown\n\(inner)\n> [!WARNING]\n> still code\n:::compare\n:::\n\(outer)")
        }
    }

    func testUnclosedFenceProtectsMarkersThroughEndOfDocument() {
        for fence in ["```", "~~~", "````"] {
            assertLiteralMarkdown("\(fence)markdown\n> [!TIP]\n> unfinished example\n:::compare\n:::")
        }
    }

    func testOutsideAlertAndTripleBacktickCompareKeepTypedBodies() {
        let source = "> [!NOTE]\n> Real notice\n:::compare\n```swift before\nlet old = 1\n```\n```swift after\nlet new = 2\n```\n:::"
        let segments = MarkdownAlertParser.segments(from: source)
        XCTAssertEqual(segments.count, 2)
        guard segments.count == 2,
              case .alert(let kind, let body) = segments[0],
              case .compare(let language, let before, let after) = segments[1] else {
            return XCTFail("Outside markers must retain alert and compare rendering")
        }
        XCTAssertEqual(kind.rawValue, "NOTE")
        XCTAssertEqual(body, "Real notice")
        XCTAssertEqual(language, "swift")
        XCTAssertEqual(before, "let old = 1")
        XCTAssertEqual(after, "let new = 2")
    }

    func testLiteralCompareTerminatorInsideCodeDoesNotCloseCompareWidget() {
        let source = ":::compare\n```text before\nold\n:::\n> [!CAUTION]\n```\n```text after\nnew\n:::\n```\n:::"
        let segments = MarkdownAlertParser.segments(from: source)
        XCTAssertEqual(segments.count, 1)
        guard let first = segments.first, case .compare(let language, let before, let after) = first else {
            return XCTFail("Only the terminator outside both code fences may end the compare block")
        }
        XCTAssertEqual(language, "text")
        XCTAssertEqual(before, "old\n:::\n> [!CAUTION]")
        XCTAssertEqual(after, "new\n:::")
    }
}
