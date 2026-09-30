import XCTest
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ObjectiveC.runtime
import Bonsplit
import UserNotifications

#if canImport(Programa_DEV)
@testable import Programa_DEV
#elseif canImport(Programa)
@testable import Programa
#endif

private func drainBrowserPanelMainQueue() {
    let expectation = XCTestExpectation(description: "drain main queue")
    DispatchQueue.main.async {
        expectation.fulfill()
    }
    XCTWaiter().wait(for: [expectation], timeout: 1.0)
}

@MainActor
final class BrowserRPCLifecycleOwnerTests: XCTestCase {
    func testDispatcherRecognizesBrowserMethodsWithoutClaimingOtherRPCs() {
        XCTAssertTrue(BrowserRPCDispatcher.recognizes("browser.navigate"))
        XCTAssertTrue(BrowserRPCDispatcher.recognizes("browser.download.wait"))
        XCTAssertFalse(BrowserRPCDispatcher.recognizes("workspace.list"))
        XCTAssertFalse(BrowserRPCDispatcher.recognizes("browser.unknown"))
    }

    func testNavigationGenerationRetainsOneStaleGenerationThenDiscardsIt() {
        let state = BrowserRPCState()
        let surfaceId = UUID()

        guard case .allocated(let refs) = state.allocateElementRefs(
            surfaceId: surfaceId,
            selectors: ["#submit"]
        ) else {
            XCTFail("Expected element reference allocation")
            return
        }
        XCTAssertEqual(refs.count, 1)
        XCTAssertNotNil(state.elementRefs[refs[0]])

        state.advanceNavigationGeneration(for: surfaceId)

        XCTAssertEqual(state.navigationGeneration(for: surfaceId), 1)
        XCTAssertEqual(state.elementRefs[refs[0]]?.navigationGeneration, 0)
        XCTAssertNil(state.elementRefBySelectorBySurface[surfaceId])

        state.advanceNavigationGeneration(for: surfaceId)

        XCTAssertEqual(state.navigationGeneration(for: surfaceId), 2)
        XCTAssertNil(state.elementRefs[refs[0]])
    }

    func testDownloadQueueIsBoundedAndReportsDroppedEvents() {
        let state = BrowserRPCState()
        let surfaceId = UUID()
        for index in 0...TerminalController.v2BrowserDownloadEventQueueLimit {
            state.enqueueDownloadEvent(surfaceId: surfaceId, event: ["index": index])
        }

        let consumed = state.consumeDownloadEvent(surfaceId: surfaceId)

        XCTAssertEqual(consumed?.event["index"] as? Int, 1)
        XCTAssertEqual(consumed?.droppedEvents, 1)
    }
}

@MainActor
private func makeTemporaryBrowserPanelProfile(named prefix: String) throws -> BrowserProfileDefinition {
    try XCTUnwrap(
        BrowserProfileStore.shared.createProfile(
            named: "\(prefix)-\(UUID().uuidString)"
        )
    )
}

final class BrowserPanelOmnibarPillBackgroundColorTests: XCTestCase {
    // Theme background (0.94, 0.93, 0.91) darkened toward black by the per-scheme mix
    // (light 0.04, dark 0.05). NSColor.blended(withFraction:of:) does not interpolate the
    // sRGB components linearly, so these are the literal values it produces, not
    // theme * (1 - mix).
    func testLightModeSlightlyDarkensThemeBackground() {
        assertResolvedColor(for: .light, red: 0.9100, green: 0.9003, blue: 0.8809)
    }

    func testDarkModeSlightlyDarkensThemeBackground() {
        assertResolvedColor(for: .dark, red: 0.9024, green: 0.8928, blue: 0.8736)
    }

    private func assertResolvedColor(
        for colorScheme: ColorScheme,
        red: CGFloat,
        green: CGFloat,
        blue: CGFloat,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let themeBackground = NSColor(srgbRed: 0.94, green: 0.93, blue: 0.91, alpha: 1.0)

        guard
            let actual = resolvedBrowserOmnibarPillBackgroundColor(
                for: colorScheme,
                themeBackgroundColor: themeBackground
            ).usingColorSpace(.sRGB)
        else {
            XCTFail("Expected an sRGB-convertible color", file: file, line: line)
            return
        }

        XCTAssertEqual(actual.redComponent, red, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.greenComponent, green, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.blueComponent, blue, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.alphaComponent, 1.0, accuracy: 0.001, file: file, line: line)
    }
}


@MainActor
final class BrowserPanelProfileIsolationTests: XCTestCase {
    func testStaleDidFinishDoesNotRecordVisitIntoSwitchedProfileHistory() throws {
        let alternateProfile = try makeTemporaryBrowserPanelProfile(named: "Switched")
        let defaultStore = BrowserHistoryStore.shared
        let alternateStore = BrowserProfileStore.shared.historyStore(for: alternateProfile.id)
        defaultStore.clearHistory()
        alternateStore.clearHistory()
        defer {
            defaultStore.clearHistory()
            alternateStore.clearHistory()
        }

        let panel = BrowserPanel(
            workspaceId: UUID(),
            profileID: BrowserProfileStore.shared.builtInDefaultProfileID
        )
        let staleWebView = panel.webView
        let staleDelegate = try XCTUnwrap(staleWebView.navigationDelegate)
        let staleURL = try XCTUnwrap(URL(string: "https://example.com/stale-finish"))
        staleWebView.loadHTMLString(
            "<html><head><title>Stale</title></head><body>stale</body></html>",
            baseURL: staleURL
        )

        XCTAssertTrue(
            panel.switchToProfile(alternateProfile.id),
            "Expected profile switch to succeed, current=\(panel.profileID) requested=\(alternateProfile.id) exists=\(BrowserProfileStore.shared.profileDefinition(id: alternateProfile.id) != nil)"
        )
        defaultStore.clearHistory()
        alternateStore.clearHistory()

        staleDelegate.webView?(staleWebView, didFinish: nil)
        drainBrowserPanelMainQueue()

        XCTAssertTrue(
            defaultStore.entries.isEmpty,
            "Expected stale completion callbacks to avoid writing into the old profile history store, found \(defaultStore.entries.map { $0.url })"
        )
        XCTAssertTrue(
            alternateStore.entries.isEmpty,
            "Expected stale completion callbacks to avoid writing into the newly selected profile history store, found \(alternateStore.entries.map { $0.url })"
        )
    }
}


@MainActor
final class BrowserPanelAddressBarFocusRequestTests: XCTestCase {
    func testRequestPersistsUntilAcknowledged() {
        let panel = BrowserPanel(workspaceId: UUID())
        XCTAssertNil(panel.pendingAddressBarFocusRequestId)

        let requestId = panel.requestAddressBarFocus()
        XCTAssertEqual(panel.pendingAddressBarFocusRequestId, requestId)
        XCTAssertTrue(panel.shouldSuppressWebViewFocus())

        panel.acknowledgeAddressBarFocusRequest(requestId)
        XCTAssertNil(panel.pendingAddressBarFocusRequestId)

        // Acknowledgement only clears the durable request; focus suppression follows
        // explicit blur state transitions.
        XCTAssertTrue(panel.shouldSuppressWebViewFocus())
        panel.endSuppressWebViewFocusForAddressBar()
        XCTAssertFalse(panel.shouldSuppressWebViewFocus())
    }

    func testRequestCoalescesWhilePending() {
        let panel = BrowserPanel(workspaceId: UUID())
        let firstRequest = panel.requestAddressBarFocus()
        let secondRequest = panel.requestAddressBarFocus()

        XCTAssertEqual(firstRequest, secondRequest)
        XCTAssertEqual(panel.pendingAddressBarFocusRequestId, firstRequest)
    }

    func testStaleAcknowledgementDoesNotClearNewestRequest() {
        let panel = BrowserPanel(workspaceId: UUID())
        let firstRequest = panel.requestAddressBarFocus()
        panel.acknowledgeAddressBarFocusRequest(firstRequest)
        let secondRequest = panel.requestAddressBarFocus()

        XCTAssertNotEqual(firstRequest, secondRequest)
        XCTAssertEqual(panel.pendingAddressBarFocusRequestId, secondRequest)

        panel.acknowledgeAddressBarFocusRequest(firstRequest)
        XCTAssertEqual(panel.pendingAddressBarFocusRequestId, secondRequest)

        panel.acknowledgeAddressBarFocusRequest(secondRequest)
        XCTAssertNil(panel.pendingAddressBarFocusRequestId)
    }
}




@MainActor
final class BrowserSnapshotJavaScriptPolicyTests: XCTestCase {
    private func snapshot(
        _ panel: BrowserPanel,
        interactiveOnly: Bool = false,
        includeCursor: Bool = false,
        compact: Bool = false,
        maxDepth: Int = 64,
        scopeSelector: String? = nil
    ) async throws -> [String: Any] {
        let script = TerminalController.shared.v2BrowserSnapshotJavaScript(
            interactiveOnly: interactiveOnly,
            includeCursor: includeCursor,
            compact: compact,
            maxDepth: maxDepth,
            scopeSelector: scopeSelector
        )
        let value = try await panel.evaluateJavaScript(script)
        return try XCTUnwrap(value as? [String: Any])
    }

    /// Runs the same isolated-world collector seam used by `browser.snapshot` after the page
    /// has had a chance to replace page-world globals.
    private func productionSnapshot(
        _ panel: BrowserPanel,
        interactiveOnly: Bool = false,
        includeCursor: Bool = false,
        compact: Bool = false,
        maxDepth: Int = 64,
        scopeSelector: String? = nil
    ) throws -> [String: Any] {
        let script = TerminalController.shared.v2BrowserSnapshotJavaScript(
            interactiveOnly: interactiveOnly,
            includeCursor: includeCursor,
            compact: compact,
            maxDepth: maxDepth,
            scopeSelector: scopeSelector
        )
        return try XCTUnwrap(
            TerminalController.shared.v2BrowserCollectSnapshotJavaScriptResult(
                webView: panel.webView,
                surfaceId: panel.id,
                script: script
            )
        )
    }

    private func assertGeneratedHTMLIsBounded(
        _ panel: BrowserPanel,
        setupScript: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        _ = try await panel.evaluateJavaScript(setupScript)
        let fullHTMLValue = try await panel.evaluateJavaScript("String(document.documentElement.outerHTML)") as? String
        let fullHTML = try XCTUnwrap(fullHTMLValue, file: file, line: line)
        XCTAssertGreaterThan(fullHTML.count, TerminalController.v2BrowserSnapshotHTMLCharacterLimit, file: file, line: line)

        let result = try await snapshot(panel)
        let html = try XCTUnwrap(result["html"] as? String, file: file, line: line)
        XCTAssertEqual(html.count, TerminalController.v2BrowserSnapshotHTMLCharacterLimit, file: file, line: line)
        XCTAssertEqual(
            html,
            String(fullHTML.prefix(TerminalController.v2BrowserSnapshotHTMLCharacterLimit)),
            "The bounded serializer must preserve the exact deterministic document prefix",
            file: file,
            line: line
        )
        XCTAssertEqual(result["html_truncated"] as? Bool, true, file: file, line: line)
    }

    private func entries(in result: [String: Any]) throws -> [[String: Any]] {
        try XCTUnwrap(result["entries"] as? [[String: Any]])
    }

    private func reasons(in result: [String: Any]) -> [String] {
        result["truncation_reasons"] as? [String] ?? []
    }

    private func javaScriptStringLiteral(_ value: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [value])
        return String(try XCTUnwrap(String(data: data, encoding: .utf8)).dropFirst().dropLast())
    }

    func testSnapshotStopsAfterTheBoundedNodePrefixBeforeAButton() async throws {
        let panel = BrowserPanel(workspaceId: UUID())
        defer { panel.close() }
        _ = try await panel.evaluateJavaScript(
            """
            document.body.replaceChildren();
            const fragment = document.createDocumentFragment();
            for (let i = 0; i < 4095; i += 1) fragment.appendChild(document.createElement('span'));
            const button = document.createElement('button');
            button.id = 'after-node-budget';
            button.textContent = 'Too late';
            fragment.appendChild(button);
            document.body.appendChild(fragment);
            true;
            """
        )

        let result = try await snapshot(panel)

        XCTAssertEqual(TerminalController.v2BrowserSnapshotNodeVisitLimit, 4_096)
        XCTAssertEqual(result["visited_nodes"] as? Int, 4_096)
        XCTAssertEqual(result["node_limit"] as? Int, 4_096)
        XCTAssertEqual(result["truncated"] as? Bool, true)
        XCTAssertEqual(reasons(in: result), ["node_limit"])
        XCTAssertFalse(try entries(in: result).contains { $0["selector"] as? String == "#after-node-budget" })
    }

    func testCursorModeCannotRestartTraversalBeyondTheNodeBudget() async throws {
        let panel = BrowserPanel(workspaceId: UUID())
        defer { panel.close() }
        _ = try await panel.evaluateJavaScript(
            """
            document.body.replaceChildren();
            const fragment = document.createDocumentFragment();
            for (let i = 0; i < 4095; i += 1) fragment.appendChild(document.createElement('span'));
            const cursorOnly = document.createElement('div');
            cursorOnly.id = 'cursor-after-budget';
            cursorOnly.style.cursor = 'pointer';
            cursorOnly.textContent = 'cursor';
            fragment.appendChild(cursorOnly);
            document.body.appendChild(fragment);
            true;
            """
        )

        let withoutCursor = try await snapshot(panel, includeCursor: false)
        let withCursor = try await snapshot(panel, includeCursor: true)

        XCTAssertEqual(withoutCursor["visited_nodes"] as? Int, 4_096)
        XCTAssertEqual(withCursor["visited_nodes"] as? Int, 4_096)
        XCTAssertEqual(reasons(in: withoutCursor), ["node_limit"])
        XCTAssertEqual(reasons(in: withCursor), ["node_limit"])
        XCTAssertFalse(try entries(in: withCursor).contains { $0["selector"] as? String == "#cursor-after-budget" })
    }

    func testSnapshotClampsRequestedDepthToTheNamedMaximum() async throws {
        let panel = BrowserPanel(workspaceId: UUID())
        defer { panel.close() }
        _ = try await panel.evaluateJavaScript(
            """
            document.body.innerHTML = '';
            let parent = document.body;
            for (let i = 0; i < 64; i += 1) {
              const child = document.createElement('div');
              parent.appendChild(child);
              parent = child;
            }
            const tooDeep = document.createElement('button');
            tooDeep.id = 'past-max-depth';
            tooDeep.textContent = 'too deep';
            parent.appendChild(tooDeep);
            true;
            """
        )

        let result = try await snapshot(panel, maxDepth: .max)

        XCTAssertEqual(TerminalController.v2BrowserSnapshotMaxDepth, 64)
        XCTAssertFalse(try entries(in: result).contains { $0["selector"] as? String == "#past-max-depth" })
        XCTAssertEqual(
            result["text_truncated"] as? Bool,
            true,
            "Skipping text below the requested depth must be reported as text truncation"
        )
    }

    func testScopedSnapshotNeverTraversesOrSerializesLaterSiblings() async throws {
        let panel = BrowserPanel(workspaceId: UUID())
        defer { panel.close() }
        let expectedNodeCountValue = try await panel.evaluateJavaScript(
            """
            document.body.innerHTML = `
              <section id="snapshot-scope">
                <button id="scoped-button">Scoped button</button>
                <p>Scoped text marker</p>
              </section>
              <section id="later-sibling">
                <button id="later-button">Later sibling marker</button>
              </section>
            `;
            window.__programaLaterSiblingTouches = 0;
            const laterSibling = document.getElementById('later-sibling');
            laterSibling.getBoundingClientRect = function() {
              window.__programaLaterSiblingTouches += 1;
              return { x: 0, y: 0, width: 10, height: 10, top: 0, right: 10, bottom: 10, left: 0 };
            };
            const scopeRoot = document.getElementById('snapshot-scope');
            const walker = document.createTreeWalker(scopeRoot, NodeFilter.SHOW_ALL);
            let scopedNodeCount = 1;
            while (walker.nextNode()) scopedNodeCount += 1;
            scopedNodeCount;
            """
        )
        let expectedNodeCount = try XCTUnwrap(expectedNodeCountValue as? Int)
        let expectedScopedHTMLValue = try await panel.evaluateJavaScript("document.getElementById('snapshot-scope').outerHTML") as? String
        let expectedScopedHTML = try XCTUnwrap(expectedScopedHTMLValue)

        let result = try await snapshot(panel, scopeSelector: "#snapshot-scope")
        let sentinelValue = try await panel.evaluateJavaScript("window.__programaLaterSiblingTouches")
        let returnedEntries = try entries(in: result)
        let text = try XCTUnwrap(result["text"] as? String)
        let html = try XCTUnwrap(result["html"] as? String)

        XCTAssertEqual(sentinelValue as? Int, 0, "A scoped traversal must not touch a later sibling")
        XCTAssertEqual(result["visited_nodes"] as? Int, expectedNodeCount)
        XCTAssertTrue(returnedEntries.contains { $0["selector"] as? String == "#scoped-button" })
        XCTAssertFalse(returnedEntries.contains { $0["selector"] as? String == "#later-button" })
        XCTAssertTrue(text.contains("Scoped button"))
        XCTAssertTrue(text.contains("Scoped text marker"))
        XCTAssertFalse(text.contains("Later sibling marker"))
        XCTAssertEqual(html, expectedScopedHTML, "A scoped snapshot must serialize only the selected subtree")
        XCTAssertTrue(html.hasPrefix("<section id=\"snapshot-scope\">"))
        XCTAssertFalse(html.contains("<html"))
        XCTAssertFalse(html.contains("<body"))
        XCTAssertFalse(html.contains("later-sibling"))
        XCTAssertFalse(html.contains("later-button"))
    }

    func testScopedSelectorListProducesChildSelectorsBoundToTheSelectedRoot() async throws {
        let panel = BrowserPanel(workspaceId: UUID())
        defer { panel.close() }
        _ = try await panel.evaluateJavaScript(
            """
            document.body.innerHTML = `
              <section id="a" data-identity="selected-root">
                <button data-identity="selected-child">A child</button>
              </section>
              <section id="b" data-identity="other-root">
                <button data-identity="other-child">B child</button>
              </section>
            `;
            true;
            """
        )
        let expectedHTMLValue = try await panel.evaluateJavaScript("document.getElementById('a').outerHTML") as? String
        let expectedHTML = try XCTUnwrap(expectedHTMLValue)

        let result = try await snapshot(panel, scopeSelector: "#a, #b")
        let returnedEntries = try entries(in: result)
        let childEntry = try XCTUnwrap(returnedEntries.first { $0["name"] as? String == "A child" })
        let childSelector = try XCTUnwrap(childEntry["selector"] as? String)
        let selectorLiteral = try javaScriptStringLiteral(childSelector)
        let resolvedIdentity = try await panel.evaluateJavaScript(
            "document.querySelector(\(selectorLiteral))?.dataset.identity || null"
        )

        XCTAssertEqual(result["html"] as? String, expectedHTML)
        XCTAssertEqual(resolvedIdentity as? String, "selected-child")
        XCTAssertNotEqual(resolvedIdentity as? String, "selected-root")
        XCTAssertNotEqual(resolvedIdentity as? String, "other-root")
        XCTAssertNotEqual(resolvedIdentity as? String, "other-child")
    }

    func testSnapshotCollectorIgnoresCompromisedPageWorldCSSEscape() async throws {
        let panel = BrowserPanel(workspaceId: UUID())
        defer { panel.close() }
        _ = try await panel.evaluateJavaScript(
            """
            document.body.innerHTML = '<button id="safe-selector">Safe</button><button id="attacker-selector">Attacker</button>';
            CSS.escape = function() { return 'attacker-selector'; };
            true;
            """
        )
        let compromisedEscape = try await panel.evaluateJavaScript("CSS.escape('harmless-known-input')")
        XCTAssertEqual(
            compromisedEscape as? String,
            "attacker-selector",
            "The page-world mutation must be active before testing the isolated collector"
        )

        let result = try productionSnapshot(panel)
        let returnedEntries = try entries(in: result)
        let safeEntry = try XCTUnwrap(returnedEntries.first { $0["name"] as? String == "Safe" })

        XCTAssertEqual(
            safeEntry["selector"] as? String,
            "#safe-selector",
            "Page JavaScript must not be able to redirect a snapshot ref by replacing CSS.escape"
        )
    }

    func testDuplicateIDSelectorStillResolvesToTheVisibleElementThatProducedTheEntry() async throws {
        let panel = BrowserPanel(workspaceId: UUID())
        defer { panel.close() }
        _ = try await panel.evaluateJavaScript(
            """
            document.body.innerHTML = '';
            const hidden = document.createElement('button');
            hidden.id = 'duplicate';
            hidden.dataset.identity = 'hidden-first';
            hidden.style.display = 'none';
            hidden.textContent = 'Hidden duplicate';
            document.body.appendChild(hidden);
            const visible = document.createElement('button');
            visible.id = 'duplicate';
            visible.dataset.identity = 'visible-second';
            visible.textContent = 'Visible duplicate';
            document.body.appendChild(visible);
            true;
            """
        )

        let result = try await snapshot(panel)
        let visibleEntry = try XCTUnwrap(try entries(in: result).first { $0["name"] as? String == "Visible duplicate" })
        let selector = try XCTUnwrap(visibleEntry["selector"] as? String)
        let selectorLiteral = try javaScriptStringLiteral(selector)
        let resolvedIdentity = try await panel.evaluateJavaScript(
            "document.querySelector(\(selectorLiteral))?.dataset.identity || null"
        )

        XCTAssertNotEqual(selector, "#duplicate", "A duplicate ID is not an identity-safe selector")
        XCTAssertEqual(resolvedIdentity as? String, "visible-second")
    }

    func testSnapshotAccessibleNamesIncludeNestedTextAndNestedLabelledContent() async throws {
        let panel = BrowserPanel(workspaceId: UUID())
        defer { panel.close() }
        _ = try await panel.evaluateJavaScript(
            """
            document.body.innerHTML = `
              <button id="nested-name"><span>Save</span></button>
              <div id="nested-label"><span>Account</span> <strong>settings</strong></div>
              <button id="labelled-button" aria-labelledby="nested-label"></button>
            `;
            true;
            """
        )

        let result = try await snapshot(panel)
        let returnedEntries = try entries(in: result)
        let nestedName = returnedEntries.first { $0["selector"] as? String == "#nested-name" }?["name"] as? String
        let labelledName = returnedEntries.first { $0["selector"] as? String == "#labelled-button" }?["name"] as? String

        XCTAssertEqual(nestedName, "Save")
        XCTAssertEqual(labelledName, "Account settings")
    }

    func testSnapshotPageTextExcludesNonVisibleAndNonContentTextWithElementBoundaries() async throws {
        let panel = BrowserPanel(workspaceId: UUID())
        defer { panel.close() }
        _ = try await panel.evaluateJavaScript(
            """
            document.body.innerHTML = `
              <p>Hello</p><p>World</p>
              <script type="application/json">script-marker</script>
              <style>.unused { content: 'style-marker'; }</style>
              <div style="display: none"><span>hidden-marker</span></div>
              <div>Visible marker</div>
            `;
            true;
            """
        )

        let result = try await snapshot(panel)
        let text = try XCTUnwrap(result["text"] as? String)
        let normalized = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")

        XCTAssertEqual(normalized, "Hello World Visible marker")
        XCTAssertNotEqual(normalized, "HelloWorld Visible marker")
        XCTAssertFalse(normalized.contains("script-marker"))
        XCTAssertFalse(normalized.contains("style-marker"))
        XCTAssertFalse(normalized.contains("hidden-marker"))
    }

    func testSelectedSameOriginFrameSnapshotUsesTheChildDocumentURLStylesAndNames() async throws {
        let panel = BrowserPanel(workspaceId: UUID())
        defer {
            TerminalController.shared.v2BrowserFrameSelectorBySurface.removeValue(forKey: panel.id)
            panel.close()
        }
        let frameStateValue = try await panel.evaluateJavaScript(
            """
            document.body.innerHTML = '';
            const frame = document.createElement('iframe');
            frame.id = 'selected-frame';
            document.body.appendChild(frame);
            frame.contentWindow.location.hash = 'selected-child-document';
            const childDocument = frame.contentDocument;
            childDocument.open();
            childDocument.write('<!doctype html><html><head><title>Child title</title></head><body><button id="child-frame-button" data-identity="child-button"><span>Child action</span></button></body></html>');
            childDocument.close();
            ({ url: String(childDocument.location.href), title: childDocument.title });
            """
        ) as? [String: Any]
        let frameState = try XCTUnwrap(frameStateValue)
        let expectedURL = try XCTUnwrap(frameState["url"] as? String)
        TerminalController.shared.v2BrowserFrameSelectorBySurface[panel.id] = "#selected-frame"

        let result = try productionSnapshot(panel)
        let returnedEntries = try entries(in: result)
        let childEntry = try XCTUnwrap(returnedEntries.first { $0["name"] as? String == "Child action" })
        let selector = try XCTUnwrap(childEntry["selector"] as? String)
        let selectorLiteral = try javaScriptStringLiteral(selector)
        let resolvedIdentity = try await panel.evaluateJavaScript(
            "document.getElementById('selected-frame').contentDocument.querySelector(\(selectorLiteral))?.dataset.identity || null"
        )

        XCTAssertEqual(result["url"] as? String, expectedURL)
        XCTAssertEqual(result["title"] as? String, "Child title")
        XCTAssertEqual(childEntry["role"] as? String, "button")
        XCTAssertEqual(resolvedIdentity as? String, "child-button")
    }

    func testOversizedSelectorIsSkippedWithoutRetargetingALaterButton() async throws {
        let panel = BrowserPanel(workspaceId: UUID())
        defer { panel.close() }
        _ = try await panel.evaluateJavaScript(
            """
            document.body.innerHTML = '';
            const oversized = document.createElement('button');
            oversized.id = 'x'.repeat(16385);
            oversized.textContent = 'oversized';
            document.body.appendChild(oversized);
            const normal = document.createElement('button');
            normal.id = 'normal-after-oversized';
            normal.textContent = 'normal';
            document.body.appendChild(normal);
            true;
            """
        )

        let result = try await snapshot(panel)
        let returnedEntries = try entries(in: result)
        let selectors = returnedEntries.compactMap { $0["selector"] as? String }

        XCTAssertEqual(result["selector_byte_limit"] as? Int, 16_384)
        XCTAssertEqual(result["selector_skipped_count"] as? Int, 1)
        XCTAssertTrue(reasons(in: result).contains("selector_byte_limit"))
        XCTAssertEqual(selectors, ["#normal-after-oversized"])
        XCTAssertEqual(selectors[0].utf8.count, "#normal-after-oversized".utf8.count)
    }

    func testMultibyteAccessibleNameTruncatesAtAValidUTF8Boundary() async throws {
        let panel = BrowserPanel(workspaceId: UUID())
        defer { panel.close() }
        _ = try await panel.evaluateJavaScript(
            """
            document.body.innerHTML = '';
            const button = document.createElement('button');
            button.id = 'multibyte-name';
            button.setAttribute('aria-label', 'é'.repeat(600));
            document.body.appendChild(button);
            true;
            """
        )

        let result = try await snapshot(panel)
        let name = try XCTUnwrap(try entries(in: result).first?["name"] as? String)

        XCTAssertEqual(result["name_byte_limit"] as? Int, 1_024)
        XCTAssertEqual(result["name_truncated_count"] as? Int, 1)
        XCTAssertTrue(reasons(in: result).contains("name_byte_limit"))
        XCTAssertEqual(name, String(repeating: "é", count: 512))
        XCTAssertEqual(name.utf8.count, 1_024)
    }

    func testOversizedRolesFallBackToImplicitRoleOrSkipInsteadOfTruncating() async throws {
        let panel = BrowserPanel(workspaceId: UUID())
        defer { panel.close() }
        // The snapshot's visibility check requires a positive layout rect. A zero-size
        // WKWebView (the default for a panel that has never been placed in a window) gives
        // block-level elements a 0px width, so give it a real viewport before laying out
        // the block-level `invalidDiv` below.
        panel.webView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        _ = try await panel.evaluateJavaScript(
            """
            document.body.innerHTML = '';
            const implicitButton = document.createElement('button');
            implicitButton.id = 'implicit-role-fallback';
            implicitButton.setAttribute('role', 'button'.repeat(20));
            implicitButton.textContent = 'button';
            document.body.appendChild(implicitButton);
            const invalidDiv = document.createElement('div');
            invalidDiv.id = 'invalid-role-skip';
            invalidDiv.setAttribute('role', 'link'.repeat(20));
            invalidDiv.textContent = 'div';
            document.body.appendChild(invalidDiv);
            true;
            """
        )

        let result = try await snapshot(panel)
        let returnedEntries = try entries(in: result)

        XCTAssertEqual(result["role_byte_limit"] as? Int, 64)
        XCTAssertEqual(result["role_skipped_count"] as? Int, 1)
        XCTAssertTrue(reasons(in: result).contains("role_byte_limit"))
        XCTAssertEqual(returnedEntries.count, 1)
        XCTAssertEqual(returnedEntries[0]["selector"] as? String, "#implicit-role-fallback")
        XCTAssertEqual(returnedEntries[0]["role"] as? String, "button")
    }

    func testAggregateEntryBytesKeepOnlyTheDeterministicPreorderPrefix() async throws {
        let panel = BrowserPanel(workspaceId: UUID())
        defer { panel.close() }
        _ = try await panel.evaluateJavaScript(
            """
            document.body.innerHTML = '';
            const fragment = document.createDocumentFragment();
            for (let i = 0; i < 300; i += 1) {
              const button = document.createElement('button');
              button.id = 'entry-' + i;
              button.setAttribute('aria-label', 'n'.repeat(1024));
              fragment.appendChild(button);
            }
            document.body.appendChild(fragment);
            true;
            """
        )

        let result = try await snapshot(panel)
        let returnedEntries = try entries(in: result)
        let accountedBytes = returnedEntries.reduce(into: 0) { total, entry in
            total += ((entry["selector"] as? String) ?? "").utf8.count
            total += ((entry["name"] as? String) ?? "").utf8.count
            total += ((entry["role"] as? String) ?? "").utf8.count
        }

        XCTAssertEqual(result["entry_byte_limit"] as? Int, 262_144)
        XCTAssertEqual(result["entry_bytes"] as? Int, accountedBytes)
        XCTAssertLessThanOrEqual(accountedBytes, 262_144)
        XCTAssertLessThanOrEqual(returnedEntries.count, 256)
        XCTAssertTrue(reasons(in: result).contains("entry_byte_limit"))
        XCTAssertEqual(
            returnedEntries.compactMap { $0["selector"] as? String },
            (0 ..< returnedEntries.count).map { "#entry-\($0)" }
        )
    }

    func testGeneratedSnapshotBoundsPageStringsAndPreservesExactPrefixes() async throws {
        let panel = BrowserPanel(workspaceId: UUID())
        defer { panel.close() }

        // WebKit refuses to grow the URL of the WKWebView's initial "about:blank" document via
        // `location.hash`/`history.replaceState` (SecurityError: session history URL cannot
        // change from an opaque initial document). Commit a real navigation with a long-path
        // base URL instead so `document.location.href` is genuinely long, then poll for that
        // navigation to land before mutating title/body content.
        let longPath = String(repeating: "u", count: 17000)
        let longBaseURL = try XCTUnwrap(URL(string: "https://example.com/\(longPath)"))
        panel.webView.loadHTMLString("<html><head></head><body></body></html>", baseURL: longBaseURL)
        for _ in 0 ..< 200 {
            let currentHref = try await panel.evaluateJavaScript("String(location.href)") as? String
            if currentHref?.hasPrefix("https://example.com/") == true { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        _ = try await panel.evaluateJavaScript(
            """
            document.title = 't'.repeat(1100);
            document.body.textContent = 'b'.repeat(1100000);
            true;
            """
        )

        let evaluatedURL = try await panel.evaluateJavaScript("String(location.href)")
        let evaluatedHTML = try await panel.evaluateJavaScript("String(document.documentElement.outerHTML)")
        let fullURL = try XCTUnwrap(evaluatedURL as? String)
        let fullHTML = try XCTUnwrap(evaluatedHTML as? String)
        let result = try await snapshot(panel)
        let title = try XCTUnwrap(result["title"] as? String)
        let url = try XCTUnwrap(result["url"] as? String)
        let text = try XCTUnwrap(result["text"] as? String)
        let html = try XCTUnwrap(result["html"] as? String)

        XCTAssertEqual(title, String(String(repeating: "t", count: 1100).prefix(1_024)))
        XCTAssertEqual(url, String(fullURL.prefix(16_384)))
        XCTAssertEqual(text, String(String(repeating: "b", count: 1_100_000).prefix(262_144)))
        XCTAssertEqual(html, String(fullHTML.prefix(1_048_576)))
        XCTAssertEqual(title.utf8.count, 1_024)
        XCTAssertEqual(url.utf8.count, 16_384)
        XCTAssertEqual(text.count, 262_144)
        XCTAssertLessThanOrEqual(html.count, 1_048_576)
        XCTAssertTrue(reasons(in: result).contains("title_byte_limit"))
        XCTAssertTrue(reasons(in: result).contains("url_byte_limit"))
        XCTAssertEqual(result["text_truncated"] as? Bool, true)
        XCTAssertEqual(result["html_truncated"] as? Bool, true)
    }

    func testGeneratedSnapshotBoundsHugeCommentAttributeAndTagOutput() async throws {
        let panel = BrowserPanel(workspaceId: UUID())
        defer { panel.close() }
        let limit = TerminalController.v2BrowserSnapshotHTMLCharacterLimit

        try await assertGeneratedHTMLIsBounded(
            panel,
            setupScript: """
            document.body.replaceChildren(document.createComment('c'.repeat(\(limit + 256))));
            true;
            """
        )
        try await assertGeneratedHTMLIsBounded(
            panel,
            setupScript: """
            document.body.innerHTML = '';
            const attributed = document.createElement('div');
            attributed.setAttribute('data-huge', 'a'.repeat(\(limit + 256)));
            document.body.appendChild(attributed);
            true;
            """
        )
        try await assertGeneratedHTMLIsBounded(
            panel,
            setupScript: """
            document.body.innerHTML = '';
            const fragment = document.createDocumentFragment();
            const tag = 'snapshot-' + 'x'.repeat(240);
            for (let index = 0; index < 2_200; index += 1) fragment.appendChild(document.createElement(tag));
            document.body.appendChild(fragment);
            true;
            """
        )
    }

    func testNestedScopedSelectorListKeepsEachEntryBoundToItsOriginatingElement() async throws {
        let panel = BrowserPanel(workspaceId: UUID())
        defer { panel.close() }
        _ = try await panel.evaluateJavaScript(
            """
            document.body.innerHTML = `
              <section id="a">
                <section id="b"><button data-identity="nested-wrong">Wrong nested button</button></section>
                <button data-identity="direct-target">Direct target</button>
              </section>
            `;
            true;
            """
        )

        let result = try await snapshot(panel, scopeSelector: "#a, #b")
        let targetEntry = try XCTUnwrap(
            try entries(in: result).first { $0["name"] as? String == "Direct target" }
        )
        let selector = try XCTUnwrap(targetEntry["selector"] as? String)
        let selectorLiteral = try javaScriptStringLiteral(selector)
        let resolvedIdentity = try await panel.evaluateJavaScript(
            "document.querySelector(\(selectorLiteral))?.dataset.identity || null"
        )

        XCTAssertEqual(resolvedIdentity as? String, "direct-target")
        XCTAssertNotEqual(resolvedIdentity as? String, "nested-wrong")
    }

    func testSnapshotStopsInspectingAggregateWhitespaceBeforeUnboundedLateText() async throws {
        let panel = BrowserPanel(workspaceId: UUID())
        defer { panel.close() }
        _ = try await panel.evaluateJavaScript(
            """
            document.body.replaceChildren();
            const fragment = document.createDocumentFragment();
            for (let index = 0; index < 1024; index += 1) {
              fragment.appendChild(document.createTextNode(' '.repeat(1025)));
            }
            const marker = document.createElement('span');
            marker.textContent = 'late-visible-marker';
            fragment.appendChild(marker);
            document.body.appendChild(fragment);
            true;
            """
        )

        let result = try await snapshot(panel)
        let text = try XCTUnwrap(result["text"] as? String)

        XCTAssertLessThan(result["visited_nodes"] as? Int ?? .max, 4_096)
        XCTAssertEqual(result["text_truncated"] as? Bool, true)
        XCTAssertFalse(text.contains("late-visible-marker"))
        XCTAssertEqual(result["text_inspection_limit"] as? Int, 1_048_832)
        let inspectedUnits = try XCTUnwrap(result["text_inspected_units"] as? Int)
        XCTAssertGreaterThan(inspectedUnits, 0)
        XCTAssertLessThanOrEqual(inspectedUnits, 1_048_832)
        XCTAssertTrue(reasons(in: result).contains("text_inspection_limit"))
    }

    func testEscapedNullIDSelectorCannotResolveAnEarlierReplacementCharacterElement() async throws {
        let panel = BrowserPanel(workspaceId: UUID())
        defer { panel.close() }
        _ = try await panel.evaluateJavaScript(
            """
            document.body.replaceChildren();
            const replacement = document.createElement('button');
            replacement.id = '\u{FFFD}';
            replacement.dataset.identity = 'replacement-character';
            replacement.textContent = 'Replacement character';
            document.body.appendChild(replacement);
            const nul = document.createElement('button');
            nul.id = String.fromCharCode(0);
            nul.dataset.identity = 'nul-target';
            nul.textContent = 'NUL target';
            document.body.appendChild(nul);
            true;
            """
        )

        let result = try await snapshot(panel)
        let targetEntry = try XCTUnwrap(try entries(in: result).first { $0["name"] as? String == "NUL target" })
        let selector = try XCTUnwrap(targetEntry["selector"] as? String)
        let selectorLiteral = try javaScriptStringLiteral(selector)
        let resolvedIdentity = try await panel.evaluateJavaScript(
            "document.querySelector(\(selectorLiteral))?.dataset.identity || null"
        )

        XCTAssertEqual(resolvedIdentity as? String, "nul-target")
        XCTAssertNotEqual(resolvedIdentity as? String, "replacement-character")
    }

    func testSnapshotTextPreservesInlineRunsAuthoredWhitespaceAndBlockBoundaries() async throws {
        let panel = BrowserPanel(workspaceId: UUID())
        defer { panel.close() }
        _ = try await panel.evaluateJavaScript(
            """
            document.body.innerHTML = '<span>pro</span><span>grama </span><span>rocks</span><p>First block</p><p>Second block</p>';
            true;
            """
        )

        let result = try await snapshot(panel)

        XCTAssertEqual(result["text"] as? String, "programa rocks First block Second block")
    }

    func testContentNamesSuppressHiddenDescendantsWhileExplicitHiddenLabelsTakePrecedence() async throws {
        let panel = BrowserPanel(workspaceId: UUID())
        defer { panel.close() }
        _ = try await panel.evaluateJavaScript(
            """
            document.body.innerHTML = `
              <button id="content-name">Visible <span hidden>hidden-attribute</span><span style="display:none">hidden-style</span><span aria-hidden="true">hidden-aria</span><span>nested text</span></button>
              <div id="explicit-hidden-label" hidden><span>Explicit hidden</span> <strong>label</strong></div>
              <button id="label-precedence" aria-label="Fallback label" aria-labelledby="explicit-hidden-label"></button>
            `;
            true;
            """
        )

        let result = try await snapshot(panel)
        let returnedEntries = try entries(in: result)
        let contentName = returnedEntries.first { $0["selector"] as? String == "#content-name" }?["name"] as? String
        let labelledName = returnedEntries.first { $0["selector"] as? String == "#label-precedence" }?["name"] as? String

        XCTAssertEqual(contentName, "Visible nested text")
        XCTAssertEqual(labelledName, "Explicit hidden label")
    }

    func testSnapshotPreservesInertTemplateMarkupWithoutExposingItsText() async throws {
        let panel = BrowserPanel(workspaceId: UUID())
        defer { panel.close() }
        _ = try await panel.evaluateJavaScript(
            """
            document.body.innerHTML = '<template><div data-marker="deferred">Deferred</div></template>';
            true;
            """
        )
        let nativeHTMLValue = try await panel.evaluateJavaScript("String(document.documentElement.outerHTML)") as? String
        let nativeHTML = try XCTUnwrap(nativeHTMLValue)

        let result = try await snapshot(panel)
        let html = try XCTUnwrap(result["html"] as? String)
        let text = try XCTUnwrap(result["text"] as? String)

        XCTAssertEqual(html, nativeHTML)
        XCTAssertTrue(html.contains("<div data-marker=\"deferred\">Deferred</div>"))
        XCTAssertFalse(text.contains("Deferred"), "Inert template content must not become visible page text")
    }

    func testExplicitVisibilityHiddenLabelIncludesDescendantsWhileOrdinaryNamesSuppressThem() async throws {
        let panel = BrowserPanel(workspaceId: UUID())
        defer { panel.close() }
        _ = try await panel.evaluateJavaScript(
            """
            document.body.innerHTML = `
              <div id="hidden-label" style="visibility:hidden"><span>Secret</span></div>
              <button id="labelled" aria-labelledby="hidden-label"></button>
              <button id="ordinary">Public<span style="visibility:hidden">Private</span></button>
            `;
            true;
            """
        )

        let result = try await snapshot(panel)
        let returnedEntries = try entries(in: result)
        let labelledName = returnedEntries.first { $0["selector"] as? String == "#labelled" }?["name"] as? String
        let ordinaryName = returnedEntries.first { $0["selector"] as? String == "#ordinary" }?["name"] as? String

        XCTAssertEqual(labelledName, "Secret")
        XCTAssertEqual(ordinaryName, "Public")
    }

    func testMixedNamespaceSnapshotPreservesNativeHTMLAndForeignElementIdentity() async throws {
        let panel = BrowserPanel(workspaceId: UUID())
        defer { panel.close() }
        _ = try await panel.evaluateJavaScript(
            """
            document.body.innerHTML = `
              <svg id="mixed-svg" width="240" height="80" xmlns="http://www.w3.org/2000/svg">
                <defs><linearGradient id="mixedGradient"><stop offset="0%" stop-color="red"></stop></linearGradient></defs>
                <rect width="240" height="80" fill="url(#mixedGradient)"></rect>
                <foreignObject x="10" y="10" width="180" height="50">
                  <button xmlns="http://www.w3.org/1999/xhtml" id="foreign-button" data-identity="foreign-origin"><span>Foreign action</span></button>
                </foreignObject>
              </svg>
            `;
            true;
            """
        )
        let nativeHTMLValue = try await panel.evaluateJavaScript("String(document.documentElement.outerHTML)") as? String
        let nativeHTML = try XCTUnwrap(nativeHTMLValue)

        let result = try await snapshot(panel)
        let foreignEntry = try XCTUnwrap(try entries(in: result).first { $0["name"] as? String == "Foreign action" })
        let selector = try XCTUnwrap(foreignEntry["selector"] as? String)
        let selectorLiteral = try javaScriptStringLiteral(selector)
        let resolvedIdentity = try await panel.evaluateJavaScript(
            "document.querySelector(\(selectorLiteral))?.dataset.identity || null"
        )

        XCTAssertEqual(result["html"] as? String, nativeHTML)
        XCTAssertTrue(nativeHTML.contains("linearGradient"))
        XCTAssertEqual(resolvedIdentity as? String, "foreign-origin")
    }

    func testSelectedFrameRemovalReturnsFrameUnavailableInsteadOfTopDocumentContent() async throws {
        let panel = BrowserPanel(workspaceId: UUID())
        defer {
            TerminalController.shared.v2BrowserFrameSelectorBySurface.removeValue(forKey: panel.id)
            panel.close()
        }
        _ = try await panel.evaluateJavaScript(
            """
            document.body.innerHTML = '<div id="top-document-marker">Top document must not leak</div><iframe id="removed-frame"></iframe>';
            document.getElementById('removed-frame').remove();
            true;
            """
        )
        TerminalController.shared.v2BrowserFrameSelectorBySurface[panel.id] = "#removed-frame"
        let script = TerminalController.shared.v2BrowserSnapshotJavaScript(
            interactiveOnly: false,
            includeCursor: false,
            compact: false,
            maxDepth: 64,
            scopeSelector: nil
        )

        let outcome = TerminalController.shared.v2BrowserCollectSnapshotJavaScriptOutcome(
            webView: panel.webView,
            surfaceId: panel.id,
            script: script
        )
        switch outcome {
        case .frameUnavailable(let selector):
            XCTAssertEqual(selector, "#removed-frame")
        case .collected(let result):
            XCTFail("A missing selected frame must not fall back to top-document content: \(result)")
        case .failed(let message):
            XCTFail("A missing selected frame must have a structured unavailable outcome, not a generic failure: \(message)")
        }
    }

    func testGeneratedSelectorActionFailsWhenSelectedFrameDisappearsInsteadOfClickingTopDocument() async throws {
        let panel = BrowserPanel(workspaceId: UUID())
        defer {
            TerminalController.shared.v2BrowserFrameSelectorBySurface.removeValue(forKey: panel.id)
            panel.close()
        }
        _ = try await panel.evaluateJavaScript(
            """
            document.body.innerHTML = '<button id="shared-action" data-clicked="0">Top target</button><iframe id="selected-action-frame"></iframe>';
            document.getElementById('shared-action').addEventListener('click', (event) => {
              event.currentTarget.dataset.clicked = '1';
            });
            document.getElementById('selected-action-frame').remove();
            true;
            """
        )
        TerminalController.shared.v2BrowserFrameSelectorBySurface[panel.id] = "#selected-action-frame"

        let outcome = TerminalController.shared.v2BrowserRunGeneratedSelectorAction(
            webView: panel.webView,
            surfaceId: panel.id,
            selector: "#shared-action",
            action: .click
        )
        switch outcome {
        case .frameUnavailable(let selector):
            XCTAssertEqual(selector, "#selected-action-frame")
        case .succeeded:
            XCTFail("A removed selected frame must not let a generated action fall back to the top document")
        case .elementNotFound:
            XCTFail("The selected-frame failure must remain distinguishable from a missing element")
        case .failed(let message):
            XCTFail("The selected-frame failure must be structured, not generic: \(message)")
        }
        let topClickCount = try await panel.evaluateJavaScript(
            "document.getElementById('shared-action').dataset.clicked"
        )
        XCTAssertEqual(topClickCount as? String, "0")
    }

    func testGeneratedElementRefActionIgnoresHostilePageWorldQuerySelectorOverride() async throws {
        let panel = BrowserPanel(workspaceId: UUID())
        defer {
            TerminalController.shared.v2BrowserPermanentlyRemoveSurfaceState(surfaceId: panel.id)
            panel.close()
        }
        _ = try await panel.evaluateJavaScript(
            """
            document.body.innerHTML = '<button id="trusted-action" data-clicked="0">Trusted</button><button id="attacker-action" data-clicked="0">Attacker</button>';
            for (const button of document.querySelectorAll('button')) {
              button.addEventListener('click', (event) => { event.currentTarget.dataset.clicked = '1'; });
            }
            const attacker = document.getElementById('attacker-action');
            document.querySelector = function() { return attacker; };
            true;
            """
        )
        let elementRef: String
        switch TerminalController.shared.browserRPCState.allocateElementRefs(
            surfaceId: panel.id,
            selectors: ["#trusted-action"]
        ) {
        case .allocated(let refs):
            elementRef = try XCTUnwrap(refs.first)
        case .resourceExhausted:
            return XCTFail("A fresh surface must have capacity for one trusted selector")
        }

        let outcome = TerminalController.shared.v2BrowserRunGeneratedSelectorAction(
            webView: panel.webView,
            surfaceId: panel.id,
            selector: elementRef,
            action: .click
        )
        guard case .succeeded = outcome else {
            return XCTFail("The trusted generated action must succeed despite the page-world override: \(outcome)")
        }
        let clickStateValue = try await panel.evaluateJavaScript(
            "({ trusted: document.getElementById('trusted-action').dataset.clicked, attacker: document.getElementById('attacker-action').dataset.clicked })"
        ) as? [String: Any]
        let clickState = try XCTUnwrap(clickStateValue)

        XCTAssertEqual(clickState["trusted"] as? String, "1")
        XCTAssertEqual(clickState["attacker"] as? String, "0")
    }

    func testOversizedFrameSelectorsAreRejectedForLiteralSelectionAndStateRestore() {
        let selector = "#" + String(repeating: "f", count: 16_384)
        XCTAssertGreaterThan(selector.utf8.count, TerminalController.v2BrowserElementRefSelectorByteLimit)
        let selectedSurface = UUID()
        let restoredSurface = UUID()
        defer {
            TerminalController.shared.v2BrowserFrameSelectorBySurface.removeValue(forKey: selectedSurface)
            TerminalController.shared.v2BrowserFrameSelectorBySurface.removeValue(forKey: restoredSurface)
        }

        for (surfaceId, source) in [
            (selectedSurface, TerminalController.V2BrowserFrameSelectorSource.frameSelect),
            (restoredSurface, TerminalController.V2BrowserFrameSelectorSource.stateLoad),
        ] {
            let result = TerminalController.shared.v2BrowserApplyFrameSelector(
                selector,
                surfaceId: surfaceId,
                source: source
            )
            guard case .rejected(let limit) = result else {
                return XCTFail("An oversized \(source) selector must be rejected")
            }
            XCTAssertEqual(limit, 16_384)
            XCTAssertNil(TerminalController.shared.v2BrowserFrameSelectorBySurface[surfaceId])
        }
    }
}


@MainActor
final class WindowBrowserHostViewTests: XCTestCase {
    private final class CapturingView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            bounds.contains(point) ? self : nil
        }
    }

    private final class PrimaryPageProbeView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            bounds.contains(point) ? self : nil
        }
    }

    private final class WKInspectorProbeView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            bounds.contains(point) ? self : nil
        }
    }

    private final class EdgeTransparentWKInspectorProbeView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            let localPoint = convert(point, from: superview)
            guard bounds.contains(localPoint) else { return nil }
            return localPoint.x <= 12 ? nil : self
        }
    }

    private final class TrailingEdgeTransparentWKInspectorProbeView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            let localPoint = convert(point, from: superview)
            guard bounds.contains(localPoint) else { return nil }
            return localPoint.x >= bounds.maxX - 12 ? nil : self
        }
    }

    private final class BonsplitMockSplitDelegate: NSObject, NSSplitViewDelegate {}

    private func makeMouseEvent(type: NSEvent.EventType, location: NSPoint, window: NSWindow) -> NSEvent {
        guard let event = NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        ) else {
            fatalError("Failed to create \(type) mouse event")
        }
        return event
    }

    private func isInspectorOwnedHit(_ hit: NSView?, inspectorView: NSView, pageView: NSView) -> Bool {
        guard let hit else { return false }
        if hit === pageView || hit.isDescendant(of: pageView) {
            return false
        }
        if hit === inspectorView || hit.isDescendant(of: inspectorView) {
            return true
        }
        return inspectorView.isDescendant(of: hit) && !(pageView === hit || pageView.isDescendant(of: hit))
    }

    func testHostViewPassesThroughDividerWhenAdjacentPaneIsCollapsed() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 180),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let splitView = NSSplitView(frame: contentView.bounds)
        splitView.autoresizingMask = [.width, .height]
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        let splitDelegate = BonsplitMockSplitDelegate()
        splitView.delegate = splitDelegate
        let first = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: contentView.bounds.height))
        let second = NSView(frame: NSRect(x: 121, y: 0, width: 179, height: contentView.bounds.height))
        splitView.addSubview(first)
        splitView.addSubview(second)
        contentView.addSubview(splitView)
        splitView.setPosition(1, ofDividerAt: 0)
        splitView.adjustSubviews()
        contentView.layoutSubtreeIfNeeded()

        guard let container = contentView.superview else {
            XCTFail("Expected content container")
            return
        }

        let hostFrame = container.convert(contentView.bounds, from: contentView)
        let host = WindowBrowserHostView(frame: hostFrame)
        host.autoresizingMask = [.width, .height]
        let child = CapturingView(frame: host.bounds)
        child.autoresizingMask = [.width, .height]
        host.addSubview(child)
        container.addSubview(host, positioned: .above, relativeTo: contentView)

        let dividerPointInSplit = NSPoint(
            x: splitView.arrangedSubviews[0].frame.maxX + (splitView.dividerThickness * 0.5),
            y: splitView.bounds.midY
        )
        let dividerPointInWindow = splitView.convert(dividerPointInSplit, to: nil)
        let dividerPointInHost = host.convert(dividerPointInWindow, from: nil)
        XCTAssertLessThanOrEqual(splitView.arrangedSubviews[0].frame.width, 1.5)
        XCTAssertNil(
            host.hitTest(dividerPointInHost),
            "Browser host must pass through divider hits even when one pane is nearly collapsed"
        )

        let contentPointInSplit = NSPoint(x: dividerPointInSplit.x + 40, y: splitView.bounds.midY)
        let contentPointInWindow = splitView.convert(contentPointInSplit, to: nil)
        let contentPointInHost = host.convert(contentPointInWindow, from: nil)
        XCTAssertTrue(host.hitTest(contentPointInHost) === child)
    }

    func testWindowBrowserPortalIgnoresHostedInspectorSplitResizeNotifications() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }
        guard let container = contentView.superview else {
            XCTFail("Expected content container")
            return
        }

        let hostFrame = container.convert(contentView.bounds, from: contentView)
        let host = WindowBrowserHostView(frame: hostFrame)
        host.autoresizingMask = [.width, .height]
        container.addSubview(host, positioned: .above, relativeTo: contentView)

        let appSplit = NSSplitView(frame: contentView.bounds)
        appSplit.autoresizingMask = [.width, .height]
        appSplit.isVertical = true
        appSplit.addSubview(NSView(frame: NSRect(x: 0, y: 0, width: 120, height: contentView.bounds.height)))
        appSplit.addSubview(NSView(frame: NSRect(x: 121, y: 0, width: 299, height: contentView.bounds.height)))
        contentView.addSubview(appSplit)

        let inspectorSplit = NSSplitView(frame: host.bounds)
        inspectorSplit.autoresizingMask = [.width, .height]
        inspectorSplit.isVertical = true
        inspectorSplit.addSubview(NSView(frame: NSRect(x: 0, y: 0, width: 120, height: host.bounds.height)))
        inspectorSplit.addSubview(NSView(frame: NSRect(x: 121, y: 0, width: 299, height: host.bounds.height)))
        host.addSubview(inspectorSplit)

        XCTAssertTrue(
            WindowBrowserPortal.shouldTreatSplitResizeAsExternalGeometry(
                appSplit,
                window: window,
                hostView: host
            ),
            "App layout splits should still trigger browser portal geometry sync"
        )
        XCTAssertFalse(
            WindowBrowserPortal.shouldTreatSplitResizeAsExternalGeometry(
                inspectorSplit,
                window: window,
                hostView: host
            ),
            "Hosted DevTools/internal splits should not trigger browser portal geometry sync"
        )
    }

    func testDragHoverEventsPassThroughForTabTransferOnBrowserHoverEvents() {
        XCTAssertTrue(
            WindowBrowserHostView.shouldPassThroughToDragTargets(
                pasteboardTypes: [DragOverlayRoutingPolicy.bonsplitTabTransferType],
                eventType: .cursorUpdate
            )
        )
        XCTAssertTrue(
            WindowBrowserHostView.shouldPassThroughToDragTargets(
                pasteboardTypes: [DragOverlayRoutingPolicy.bonsplitTabTransferType],
                eventType: .mouseEntered
            )
        )
    }

    func testDragHoverEventsPassThroughForSidebarReorderWithoutMouseButtonState() {
        XCTAssertTrue(
            WindowBrowserHostView.shouldPassThroughToDragTargets(
                pasteboardTypes: [DragOverlayRoutingPolicy.sidebarTabReorderType],
                eventType: .cursorUpdate
            )
        )
    }

    func testDragHoverEventsDoNotPassThroughForUnrelatedPasteboardTypes() {
        XCTAssertFalse(
            WindowBrowserHostView.shouldPassThroughToDragTargets(
                pasteboardTypes: [.fileURL],
                eventType: .cursorUpdate
            )
        )
    }

    func testHostViewKeepsHostedInspectorDividerInteractive() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }
        guard let container = contentView.superview else {
            XCTFail("Expected content container")
            return
        }

        // Underlying app layout split that should still be pass-through.
        let appSplit = NSSplitView(frame: contentView.bounds)
        appSplit.autoresizingMask = [.width, .height]
        appSplit.isVertical = true
        appSplit.dividerStyle = .thin
        let appSplitDelegate = BonsplitMockSplitDelegate()
        appSplit.delegate = appSplitDelegate
        let leading = NSView(frame: NSRect(x: 0, y: 0, width: 210, height: contentView.bounds.height))
        let trailing = NSView(frame: NSRect(x: 211, y: 0, width: 209, height: contentView.bounds.height))
        appSplit.addSubview(leading)
        appSplit.addSubview(trailing)
        contentView.addSubview(appSplit)
        appSplit.adjustSubviews()

        let hostFrame = container.convert(contentView.bounds, from: contentView)
        let host = WindowBrowserHostView(frame: hostFrame)
        host.autoresizingMask = [.width, .height]
        container.addSubview(host, positioned: .above, relativeTo: contentView)

        // WebKit inspector uses an internal split (page + console). Divider drags
        // here must stay in hosted content, not pass through to appSplit behind it.
        let inspectorSplit = NSSplitView(frame: host.bounds)
        inspectorSplit.autoresizingMask = [.width, .height]
        inspectorSplit.isVertical = false
        inspectorSplit.dividerStyle = .thin
        let inspectorDelegate = BonsplitMockSplitDelegate()
        inspectorSplit.delegate = inspectorDelegate
        let pageView = CapturingView(frame: NSRect(x: 0, y: 0, width: host.bounds.width, height: 160))
        let consoleView = CapturingView(frame: NSRect(x: 0, y: 161, width: host.bounds.width, height: 99))
        inspectorSplit.addSubview(pageView)
        inspectorSplit.addSubview(consoleView)
        host.addSubview(inspectorSplit)
        inspectorSplit.setPosition(160, ofDividerAt: 0)
        inspectorSplit.adjustSubviews()
        contentView.layoutSubtreeIfNeeded()

        let appDividerPointInSplit = NSPoint(
            x: appSplit.arrangedSubviews[0].frame.maxX + (appSplit.dividerThickness * 0.5),
            y: appSplit.bounds.midY
        )
        let appDividerPointInWindow = appSplit.convert(appDividerPointInSplit, to: nil)
        let appDividerPointInHost = host.convert(appDividerPointInWindow, from: nil)
        XCTAssertNil(
            host.hitTest(appDividerPointInHost),
            "Underlying app split divider should still pass through with a hosted inspector split present"
        )

        let dividerPointInInspector = NSPoint(
            x: inspectorSplit.bounds.midX,
            y: inspectorSplit.arrangedSubviews[0].frame.maxY + (inspectorSplit.dividerThickness * 0.5)
        )
        let dividerPointInWindow = inspectorSplit.convert(dividerPointInInspector, to: nil)
        let dividerPointInHost = host.convert(dividerPointInWindow, from: nil)
        let hit = host.hitTest(dividerPointInHost)

        XCTAssertNotNil(
            hit,
            "Inspector divider should receive hit-testing in hosted content, not pass through"
        )
        XCTAssertFalse(hit === host)
        if let hit {
            XCTAssertTrue(
                hit === inspectorSplit || hit.isDescendant(of: inspectorSplit),
                "Expected hit to remain inside inspector split subtree"
            )
        }
    }

    func testHostViewKeepsHostedVerticalInspectorDividerInteractiveAtSlotLeadingEdge() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }
        guard let container = contentView.superview else {
            XCTFail("Expected content container")
            return
        }

        let hostFrame = container.convert(contentView.bounds, from: contentView)
        let host = WindowBrowserHostView(frame: hostFrame)
        host.autoresizingMask = [.width, .height]
        container.addSubview(host, positioned: .above, relativeTo: contentView)

        let slot = WindowBrowserSlotView(frame: NSRect(x: 180, y: 0, width: 240, height: host.bounds.height))
        slot.autoresizingMask = [.minXMargin, .height]
        host.addSubview(slot)

        let inspectorSplit = NSSplitView(frame: slot.bounds)
        inspectorSplit.autoresizingMask = [.width, .height]
        inspectorSplit.isVertical = true
        inspectorSplit.dividerStyle = .thin
        let inspectorDelegate = BonsplitMockSplitDelegate()
        inspectorSplit.delegate = inspectorDelegate
        let pageView = CapturingView(frame: NSRect(x: 0, y: 0, width: 1, height: slot.bounds.height))
        let inspectorView = CapturingView(
            frame: NSRect(x: 2, y: 0, width: slot.bounds.width - 2, height: slot.bounds.height)
        )
        inspectorSplit.addSubview(pageView)
        inspectorSplit.addSubview(inspectorView)
        slot.addSubview(inspectorSplit)
        inspectorSplit.setPosition(1, ofDividerAt: 0)
        inspectorSplit.adjustSubviews()
        contentView.layoutSubtreeIfNeeded()

        let dividerPointInSplit = NSPoint(
            x: inspectorSplit.arrangedSubviews[0].frame.maxX + (inspectorSplit.dividerThickness * 0.5),
            y: inspectorSplit.bounds.midY
        )
        let dividerPointInWindow = inspectorSplit.convert(dividerPointInSplit, to: nil)
        let dividerPointInHost = host.convert(dividerPointInWindow, from: nil)

        XCTAssertLessThanOrEqual(inspectorSplit.arrangedSubviews[0].frame.width, 1.5)
        XCTAssertTrue(
            abs(dividerPointInHost.x - slot.frame.minX) <= 2,
            "Expected collapsed hosted divider to overlap the browser slot leading-edge resizer zone"
        )

        let hit = host.hitTest(dividerPointInHost)
        XCTAssertNotNil(
            hit,
            "Hosted vertical inspector divider should stay interactive even when collapsed onto the slot edge"
        )
        XCTAssertFalse(hit === host)
        if let hit {
            XCTAssertTrue(
                hit === inspectorSplit || hit.isDescendant(of: inspectorSplit),
                "Expected hit to remain inside hosted inspector split subtree at the slot edge"
            )
        }
    }

    func testHostViewPrefersNativeHostedInspectorSiblingDividerHit() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }
        guard let container = contentView.superview else {
            XCTFail("Expected content container")
            return
        }

        let hostFrame = container.convert(contentView.bounds, from: contentView)
        let host = WindowBrowserHostView(frame: hostFrame)
        host.autoresizingMask = [.width, .height]
        container.addSubview(host, positioned: .above, relativeTo: contentView)

        let slot = WindowBrowserSlotView(frame: NSRect(x: 180, y: 0, width: 240, height: host.bounds.height))
        slot.autoresizingMask = [.minXMargin, .height]
        host.addSubview(slot)

        let pageView = PrimaryPageProbeView(frame: NSRect(x: 0, y: 0, width: 92, height: slot.bounds.height))
        let inspectorView = WKInspectorProbeView(
            frame: NSRect(x: 92, y: 0, width: slot.bounds.width - 92, height: slot.bounds.height)
        )
        slot.addSubview(pageView)
        slot.addSubview(inspectorView)
        contentView.layoutSubtreeIfNeeded()

        let dividerPointInSlot = NSPoint(x: inspectorView.frame.minX + 2, y: slot.bounds.midY)
        let dividerPointInWindow = slot.convert(dividerPointInSlot, to: nil)
        let dividerPointInHost = host.convert(dividerPointInWindow, from: nil)
        let bodyPointInSlot = NSPoint(x: inspectorView.frame.minX + 18, y: slot.bounds.midY)
        let bodyPointInWindow = slot.convert(bodyPointInSlot, to: nil)
        let bodyPointInHost = host.convert(bodyPointInWindow, from: nil)

        let dividerHit = host.hitTest(dividerPointInHost)
        XCTAssertTrue(
            isInspectorOwnedHit(dividerHit, inspectorView: inspectorView, pageView: pageView),
            "Hosted right-docked inspector divider should stay on the native WebKit hit path when WebKit exposes a hittable inspector-side view. actual=\(String(describing: dividerHit))"
        )
        let interiorHit = host.hitTest(bodyPointInHost)
        XCTAssertTrue(
            isInspectorOwnedHit(interiorHit, inspectorView: inspectorView, pageView: pageView),
            "Only the divider edge should be claimed; interior inspector hits should still reach WebKit content. actual=\(String(describing: interiorHit))"
        )
    }

    func testHostViewPrefersNativeNestedHostedInspectorSiblingDividerHit() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }
        guard let container = contentView.superview else {
            XCTFail("Expected content container")
            return
        }

        let hostFrame = container.convert(contentView.bounds, from: contentView)
        let host = WindowBrowserHostView(frame: hostFrame)
        host.autoresizingMask = [.width, .height]
        container.addSubview(host, positioned: .above, relativeTo: contentView)

        let slot = WindowBrowserSlotView(frame: NSRect(x: 180, y: 0, width: 240, height: host.bounds.height))
        slot.autoresizingMask = [.minXMargin, .height]
        host.addSubview(slot)

        let wrapper = NSView(frame: slot.bounds)
        wrapper.autoresizingMask = [.width, .height]
        slot.addSubview(wrapper)

        let pageView = PrimaryPageProbeView(frame: NSRect(x: 0, y: 0, width: 92, height: wrapper.bounds.height))
        let inspectorContainer = NSView(
            frame: NSRect(x: 92, y: 0, width: wrapper.bounds.width - 92, height: wrapper.bounds.height)
        )
        let inspectorView = WKInspectorProbeView(frame: inspectorContainer.bounds)
        inspectorView.autoresizingMask = [.width, .height]
        inspectorContainer.addSubview(inspectorView)
        wrapper.addSubview(pageView)
        wrapper.addSubview(inspectorContainer)
        contentView.layoutSubtreeIfNeeded()

        let dividerPointInSlot = NSPoint(x: inspectorContainer.frame.minX + 2, y: slot.bounds.midY)
        let dividerPointInWindow = slot.convert(dividerPointInSlot, to: nil)
        let dividerPointInHost = host.convert(dividerPointInWindow, from: nil)
        let bodyPointInSlot = NSPoint(x: inspectorContainer.frame.minX + 18, y: slot.bounds.midY)
        let bodyPointInWindow = slot.convert(bodyPointInSlot, to: nil)
        let bodyPointInHost = host.convert(bodyPointInWindow, from: nil)

        let dividerHit = host.hitTest(dividerPointInHost)
        XCTAssertTrue(
            isInspectorOwnedHit(dividerHit, inspectorView: inspectorView, pageView: pageView),
            "Portal host should prefer the native nested WebKit hit target on the right-docked divider when available. actual=\(String(describing: dividerHit))"
        )
        let interiorHit = host.hitTest(bodyPointInHost)
        XCTAssertTrue(
            isInspectorOwnedHit(interiorHit, inspectorView: inspectorView, pageView: pageView),
            "Only the divider edge should be claimed; interior nested inspector hits should still reach WebKit content. actual=\(String(describing: interiorHit))"
        )
    }

    func testHostViewReappliesStoredHostedInspectorWidthAfterSlotLayoutReset() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }
        guard let container = contentView.superview else {
            XCTFail("Expected content container")
            return
        }

        let hostFrame = container.convert(contentView.bounds, from: contentView)
        let host = WindowBrowserHostView(frame: hostFrame)
        host.autoresizingMask = [.width, .height]
        container.addSubview(host, positioned: .above, relativeTo: contentView)

        let slot = WindowBrowserSlotView(frame: NSRect(x: 180, y: 0, width: 240, height: host.bounds.height))
        slot.autoresizingMask = [.minXMargin, .height]
        host.addSubview(slot)

        let wrapper = NSView(frame: slot.bounds)
        wrapper.autoresizingMask = [.width, .height]
        slot.addSubview(wrapper)

        let originalPageFrame = NSRect(x: 0, y: 0, width: 92, height: wrapper.bounds.height)
        let originalInspectorFrame = NSRect(
            x: 92,
            y: 0,
            width: wrapper.bounds.width - 92,
            height: wrapper.bounds.height
        )
        let pageView = PrimaryPageProbeView(frame: originalPageFrame)
        let inspectorContainer = NSView(frame: originalInspectorFrame)
        let inspectorView = WKInspectorProbeView(frame: inspectorContainer.bounds)
        inspectorView.autoresizingMask = [.width, .height]
        inspectorContainer.addSubview(inspectorView)
        wrapper.addSubview(pageView)
        wrapper.addSubview(inspectorContainer)
        contentView.layoutSubtreeIfNeeded()

        let dividerPointInSlot = NSPoint(x: inspectorContainer.frame.minX, y: slot.bounds.midY)
        let dividerPointInWindow = slot.convert(dividerPointInSlot, to: nil)

        let down = makeMouseEvent(type: .leftMouseDown, location: dividerPointInWindow, window: window)
        host.mouseDown(with: down)
        let drag = makeMouseEvent(
            type: .leftMouseDragged,
            location: NSPoint(x: dividerPointInWindow.x + 48, y: dividerPointInWindow.y),
            window: window
        )
        host.mouseDragged(with: drag)
        host.mouseUp(with: makeMouseEvent(type: .leftMouseUp, location: drag.locationInWindow, window: window))

        let draggedPageWidth = pageView.frame.width
        let draggedInspectorMinX = inspectorContainer.frame.minX
        XCTAssertGreaterThan(draggedPageWidth, originalPageFrame.width)
        XCTAssertGreaterThan(draggedInspectorMinX, originalInspectorFrame.minX)

        pageView.frame = originalPageFrame
        inspectorContainer.frame = originalInspectorFrame
        slot.needsLayout = true
        slot.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()

        XCTAssertEqual(pageView.frame.width, draggedPageWidth, accuracy: 0.5)
        XCTAssertEqual(inspectorContainer.frame.minX, draggedInspectorMinX, accuracy: 0.5)
    }

    func testHostViewFallsBackToManualHostedInspectorDragWhenNativeDividerHitIsUnavailable() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }
        guard let container = contentView.superview else {
            XCTFail("Expected content container")
            return
        }

        let hostFrame = container.convert(contentView.bounds, from: contentView)
        let host = WindowBrowserHostView(frame: hostFrame)
        host.autoresizingMask = [.width, .height]
        container.addSubview(host, positioned: .above, relativeTo: contentView)

        let slot = WindowBrowserSlotView(frame: NSRect(x: 180, y: 0, width: 240, height: host.bounds.height))
        slot.autoresizingMask = [.minXMargin, .height]
        host.addSubview(slot)

        let pageView = PrimaryPageProbeView(frame: NSRect(x: 0, y: 0, width: 92, height: slot.bounds.height))
        let inspectorView = EdgeTransparentWKInspectorProbeView(
            frame: NSRect(x: 92, y: 0, width: slot.bounds.width - 92, height: slot.bounds.height)
        )
        slot.addSubview(pageView)
        slot.addSubview(inspectorView)
        contentView.layoutSubtreeIfNeeded()

        let dividerPointInSlot = NSPoint(x: inspectorView.frame.minX + 2, y: slot.bounds.midY)
        let dividerPointInWindow = slot.convert(dividerPointInSlot, to: nil)
        let dividerPointInHost = host.convert(dividerPointInWindow, from: nil)

        let dividerHit = host.hitTest(dividerPointInHost)
        XCTAssertTrue(
            dividerHit === host,
            "Host should only take the manual fallback path when the right-docked divider edge is not natively hittable. actual=\(String(describing: dividerHit))"
        )

        let down = makeMouseEvent(type: .leftMouseDown, location: dividerPointInWindow, window: window)
        host.mouseDown(with: down)
        let drag = makeMouseEvent(
            type: .leftMouseDragged,
            location: NSPoint(x: dividerPointInWindow.x + 40, y: dividerPointInWindow.y),
            window: window
        )
        host.mouseDragged(with: drag)
        host.mouseUp(with: makeMouseEvent(type: .leftMouseUp, location: drag.locationInWindow, window: window))

        XCTAssertGreaterThan(pageView.frame.width, 92)
        XCTAssertGreaterThan(inspectorView.frame.minX, 92)
    }

    func testHostViewFallsBackToManualHostedInspectorDragForLeftDockedInspector() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }
        guard let container = contentView.superview else {
            XCTFail("Expected content container")
            return
        }

        let hostFrame = container.convert(contentView.bounds, from: contentView)
        let host = WindowBrowserHostView(frame: hostFrame)
        host.autoresizingMask = [.width, .height]
        container.addSubview(host, positioned: .above, relativeTo: contentView)

        let slot = WindowBrowserSlotView(frame: NSRect(x: 180, y: 0, width: 240, height: host.bounds.height))
        slot.autoresizingMask = [.minXMargin, .height]
        host.addSubview(slot)

        let inspectorView = TrailingEdgeTransparentWKInspectorProbeView(
            frame: NSRect(x: 0, y: 0, width: 92, height: slot.bounds.height)
        )
        let pageView = PrimaryPageProbeView(
            frame: NSRect(x: 92, y: 0, width: slot.bounds.width - 92, height: slot.bounds.height)
        )
        slot.addSubview(inspectorView)
        slot.addSubview(pageView)
        contentView.layoutSubtreeIfNeeded()

        let dividerPointInSlot = NSPoint(x: inspectorView.frame.maxX - 2, y: slot.bounds.midY)
        let dividerPointInWindow = slot.convert(dividerPointInSlot, to: nil)
        let dividerPointInHost = host.convert(dividerPointInWindow, from: nil)

        XCTAssertTrue(
            host.hitTest(dividerPointInHost) === host,
            "Host should take the manual fallback path for a left-docked divider when the native edge is not hittable"
        )

        let down = makeMouseEvent(type: .leftMouseDown, location: dividerPointInWindow, window: window)
        host.mouseDown(with: down)
        let drag = makeMouseEvent(
            type: .leftMouseDragged,
            location: NSPoint(x: dividerPointInWindow.x + 40, y: dividerPointInWindow.y),
            window: window
        )
        host.mouseDragged(with: drag)
        host.mouseUp(with: makeMouseEvent(type: .leftMouseUp, location: drag.locationInWindow, window: window))

        XCTAssertGreaterThan(inspectorView.frame.width, 92)
        XCTAssertGreaterThan(pageView.frame.minX, 92)
    }

    func testHostViewClaimsCollapsedHostedInspectorSiblingDividerAtSlotLeadingEdge() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }
        guard let container = contentView.superview else {
            XCTFail("Expected content container")
            return
        }

        let hostFrame = container.convert(contentView.bounds, from: contentView)
        let host = WindowBrowserHostView(frame: hostFrame)
        host.autoresizingMask = [.width, .height]
        container.addSubview(host, positioned: .above, relativeTo: contentView)

        let slot = WindowBrowserSlotView(frame: NSRect(x: 180, y: 0, width: 240, height: host.bounds.height))
        slot.autoresizingMask = [.minXMargin, .height]
        host.addSubview(slot)

        let pageView = PrimaryPageProbeView(frame: NSRect(x: 0, y: 0, width: 0, height: slot.bounds.height))
        let inspectorView = WKInspectorProbeView(frame: slot.bounds)
        slot.addSubview(pageView)
        slot.addSubview(inspectorView)
        contentView.layoutSubtreeIfNeeded()

        let dividerPointInSlot = NSPoint(x: inspectorView.frame.minX + 2, y: slot.bounds.midY)
        let dividerPointInWindow = slot.convert(dividerPointInSlot, to: nil)
        let dividerPointInHost = host.convert(dividerPointInWindow, from: nil)

        XCTAssertLessThanOrEqual(dividerPointInHost.x - slot.frame.minX, 2)
        let dividerHit = host.hitTest(dividerPointInHost)
        XCTAssertTrue(
            isInspectorOwnedHit(dividerHit, inspectorView: inspectorView, pageView: pageView),
            "Collapsed right-docked hosted inspector divider should stay on the native WebKit hit path while still beating the sidebar-resizer overlap zone. actual=\(String(describing: dividerHit))"
        )
    }
}


@MainActor
final class BrowserPanelHostContainerViewTests: XCTestCase {
    private final class PrimaryPageProbeView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            bounds.contains(point) ? self : nil
        }
    }

    private final class TrackingInspectorFrontendWebView: WKWebView {
        private(set) var evaluatedJavaScript: [String] = []

        @MainActor override func evaluateJavaScript(
            _ javaScriptString: String,
            completionHandler: (@MainActor @Sendable (Any?, (any Error)?) -> Void)? = nil
        ) {
            evaluatedJavaScript.append(javaScriptString)
            completionHandler?(nil, nil)
        }
    }

    private final class WKInspectorProbeView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            bounds.contains(point) ? self : nil
        }
    }

    private final class EdgeTransparentWKInspectorProbeView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            let localPoint = convert(point, from: superview)
            guard bounds.contains(localPoint) else { return nil }
            return localPoint.x <= 12 ? nil : self
        }
    }

    private final class TrailingEdgeTransparentWKInspectorProbeView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            let localPoint = convert(point, from: superview)
            guard bounds.contains(localPoint) else { return nil }
            return localPoint.x >= bounds.maxX - 12 ? nil : self
        }
    }

    private func makeMouseEvent(type: NSEvent.EventType, location: NSPoint, window: NSWindow) -> NSEvent {
        guard let event = NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        ) else {
            fatalError("Failed to create \(type) mouse event")
        }
        return event
    }

    func testBrowserPanelHostPrefersNativeHostedInspectorSiblingDividerHit() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let host = WebViewRepresentable.HostContainerView(frame: NSRect(x: 180, y: 0, width: 240, height: contentView.bounds.height))
        host.autoresizingMask = [.minXMargin, .height]
        contentView.addSubview(host)

        let webViewRoot = NSView(frame: host.bounds)
        webViewRoot.autoresizingMask = [.width, .height]
        host.addSubview(webViewRoot)

        let pageView = PrimaryPageProbeView(frame: NSRect(x: 0, y: 0, width: 92, height: webViewRoot.bounds.height))
        let inspectorContainer = NSView(
            frame: NSRect(x: 92, y: 0, width: webViewRoot.bounds.width - 92, height: webViewRoot.bounds.height)
        )
        let inspectorView = WKInspectorProbeView(frame: inspectorContainer.bounds)
        inspectorView.autoresizingMask = [.width, .height]
        inspectorContainer.addSubview(inspectorView)
        webViewRoot.addSubview(pageView)
        webViewRoot.addSubview(inspectorContainer)
        contentView.layoutSubtreeIfNeeded()

        let dividerPointInHost = NSPoint(x: inspectorContainer.frame.minX + 2, y: host.bounds.midY)
        let bodyPointInHost = NSPoint(x: inspectorContainer.frame.minX + 18, y: host.bounds.midY)
        let interiorHit = host.hitTest(bodyPointInHost)

        XCTAssertTrue(
            host.hitTest(dividerPointInHost) === host,
            "Browser panel host should claim the right-docked divider edge for the manual resize path"
        )
        XCTAssertTrue(
            interiorHit == nil || interiorHit !== host,
            "Only the divider edge should be claimed; interior inspector hits should not be stolen by the host. actual=\(String(describing: interiorHit))"
        )
    }

    func testBrowserPanelHostClaimsCollapsedHostedInspectorSiblingDividerAtLeadingEdge() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let host = WebViewRepresentable.HostContainerView(frame: NSRect(x: 180, y: 0, width: 240, height: contentView.bounds.height))
        host.autoresizingMask = [.minXMargin, .height]
        contentView.addSubview(host)

        let webViewRoot = NSView(frame: host.bounds)
        webViewRoot.autoresizingMask = [.width, .height]
        host.addSubview(webViewRoot)

        let pageView = PrimaryPageProbeView(frame: NSRect(x: 0, y: 0, width: 0, height: webViewRoot.bounds.height))
        let inspectorContainer = NSView(frame: webViewRoot.bounds)
        let inspectorView = WKInspectorProbeView(frame: inspectorContainer.bounds)
        inspectorView.autoresizingMask = [.width, .height]
        inspectorContainer.addSubview(inspectorView)
        webViewRoot.addSubview(pageView)
        webViewRoot.addSubview(inspectorContainer)
        contentView.layoutSubtreeIfNeeded()

        let dividerPointInHost = NSPoint(x: inspectorContainer.frame.minX + 2, y: host.bounds.midY)
        let dividerPointInWindow = host.convert(dividerPointInHost, to: nil)

        XCTAssertTrue(
            host.hitTest(dividerPointInHost) === host,
            "Collapsed right-docked divider should stay on the manual browser-panel resize path while beating the sidebar-resizer overlap"
        )

        let down = makeMouseEvent(type: .leftMouseDown, location: dividerPointInWindow, window: window)
        host.mouseDown(with: down)
        let drag = makeMouseEvent(
            type: .leftMouseDragged,
            location: NSPoint(x: dividerPointInWindow.x + 36, y: dividerPointInWindow.y),
            window: window
        )
        host.mouseDragged(with: drag)
        host.mouseUp(with: makeMouseEvent(type: .leftMouseUp, location: drag.locationInWindow, window: window))

        XCTAssertGreaterThan(pageView.frame.width, 0)
        XCTAssertGreaterThan(inspectorContainer.frame.minX, 0)
    }

    func testBrowserPanelHostClaimsHostedInspectorDividerAcrossFullHeight() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let host = WebViewRepresentable.HostContainerView(frame: NSRect(x: 180, y: 0, width: 240, height: contentView.bounds.height))
        host.autoresizingMask = [.minXMargin, .height]
        contentView.addSubview(host)

        let webViewRoot = NSView(frame: host.bounds)
        webViewRoot.autoresizingMask = [.width, .height]
        host.addSubview(webViewRoot)

        let pageView = PrimaryPageProbeView(frame: NSRect(x: 0, y: 20, width: 92, height: webViewRoot.bounds.height - 40))
        let inspectorContainer = EdgeTransparentWKInspectorProbeView(
            frame: NSRect(x: 92, y: 20, width: webViewRoot.bounds.width - 92, height: webViewRoot.bounds.height - 40)
        )
        webViewRoot.addSubview(pageView)
        webViewRoot.addSubview(inspectorContainer)
        contentView.layoutSubtreeIfNeeded()

        XCTAssertTrue(
            host.hitTest(NSPoint(x: inspectorContainer.frame.minX + 2, y: 4)) === host,
            "The custom DevTools divider should remain draggable at the top edge of the browser pane"
        )
        XCTAssertTrue(
            host.hitTest(NSPoint(x: inspectorContainer.frame.minX + 2, y: host.bounds.maxY - 4)) === host,
            "The custom DevTools divider should remain draggable at the bottom edge of the browser pane"
        )
    }

    func testBrowserPanelHostFallsBackToManualHostedInspectorDragWhenNativeDividerHitIsUnavailable() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let host = WebViewRepresentable.HostContainerView(frame: NSRect(x: 180, y: 0, width: 240, height: contentView.bounds.height))
        host.autoresizingMask = [.minXMargin, .height]
        contentView.addSubview(host)

        let webViewRoot = NSView(frame: host.bounds)
        webViewRoot.autoresizingMask = [.width, .height]
        host.addSubview(webViewRoot)

        let pageView = PrimaryPageProbeView(frame: NSRect(x: 0, y: 0, width: 92, height: webViewRoot.bounds.height))
        let inspectorContainer = EdgeTransparentWKInspectorProbeView(
            frame: NSRect(x: 92, y: 0, width: webViewRoot.bounds.width - 92, height: webViewRoot.bounds.height)
        )
        webViewRoot.addSubview(pageView)
        webViewRoot.addSubview(inspectorContainer)
        contentView.layoutSubtreeIfNeeded()

        let dividerPointInHost = NSPoint(x: inspectorContainer.frame.minX + 2, y: host.bounds.midY)
        let dividerPointInWindow = host.convert(dividerPointInHost, to: nil)

        XCTAssertTrue(
            host.hitTest(dividerPointInHost) === host,
            "Browser panel host should only take the manual fallback path when the divider edge is not natively hittable"
        )

        let down = makeMouseEvent(type: .leftMouseDown, location: dividerPointInWindow, window: window)
        host.mouseDown(with: down)
        let drag = makeMouseEvent(
            type: .leftMouseDragged,
            location: NSPoint(x: dividerPointInWindow.x + 40, y: dividerPointInWindow.y),
            window: window
        )
        host.mouseDragged(with: drag)
        host.mouseUp(with: makeMouseEvent(type: .leftMouseUp, location: drag.locationInWindow, window: window))

        XCTAssertGreaterThan(pageView.frame.width, 92)
        XCTAssertGreaterThan(inspectorContainer.frame.minX, 92)
    }

    func testBrowserPanelHostKeepsInspectorResizableAfterShrinkingToMinimumWidth() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let host = WebViewRepresentable.HostContainerView(frame: NSRect(x: 180, y: 0, width: 240, height: contentView.bounds.height))
        host.autoresizingMask = [.minXMargin, .height]
        contentView.addSubview(host)

        let webViewRoot = NSView(frame: host.bounds)
        webViewRoot.autoresizingMask = [.width, .height]
        host.addSubview(webViewRoot)

        let pageView = PrimaryPageProbeView(frame: NSRect(x: 0, y: 0, width: 92, height: webViewRoot.bounds.height))
        let inspectorContainer = EdgeTransparentWKInspectorProbeView(
            frame: NSRect(x: 92, y: 0, width: webViewRoot.bounds.width - 92, height: webViewRoot.bounds.height)
        )
        webViewRoot.addSubview(pageView)
        webViewRoot.addSubview(inspectorContainer)
        contentView.layoutSubtreeIfNeeded()

        let dividerPointInHost = NSPoint(x: inspectorContainer.frame.minX + 2, y: host.bounds.midY)
        let dividerPointInWindow = host.convert(dividerPointInHost, to: nil)

        host.mouseDown(with: makeMouseEvent(type: .leftMouseDown, location: dividerPointInWindow, window: window))
        let drag = makeMouseEvent(
            type: .leftMouseDragged,
            location: NSPoint(x: dividerPointInWindow.x + 220, y: dividerPointInWindow.y),
            window: window
        )
        host.mouseDragged(with: drag)
        host.mouseUp(with: makeMouseEvent(type: .leftMouseUp, location: drag.locationInWindow, window: window))

        XCTAssertGreaterThanOrEqual(
            inspectorContainer.frame.width,
            120,
            "Shrinking the DevTools pane should clamp to a recoverable minimum width"
        )
        XCTAssertTrue(
            host.hitTest(NSPoint(x: inspectorContainer.frame.minX + 2, y: 4)) === host,
            "After clamping, the DevTools divider should still be draggable near the top edge"
        )
        XCTAssertTrue(
            host.hitTest(NSPoint(x: inspectorContainer.frame.minX + 2, y: host.bounds.maxY - 4)) === host,
            "After clamping, the DevTools divider should still be draggable near the bottom edge"
        )
    }

    func testBrowserPanelHostPromotesVisibleRightDockedInspectorIntoManagedSideDock() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let host = WebViewRepresentable.HostContainerView(frame: NSRect(x: 180, y: 0, width: 240, height: contentView.bounds.height))
        host.autoresizingMask = [.minXMargin, .height]
        contentView.addSubview(host)

        let slotView = host.ensureLocalInlineSlotView()
        let pageView = WKWebView(frame: NSRect(x: 0, y: 0, width: 92, height: host.bounds.height + 180))
        let inspectorView = WKWebView(
            frame: NSRect(x: 92, y: 0, width: slotView.bounds.width - 92, height: host.bounds.height)
        )
        slotView.addSubview(pageView)
        slotView.addSubview(inspectorView)
        host.pinHostedWebView(pageView, in: slotView)
        host.setHostedInspectorFrontendWebView(inspectorView)
        contentView.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()

        XCTAssertTrue(
            host.promoteHostedInspectorSideDockFromCurrentLayoutIfNeeded(),
            "A visible right-docked inspector should not wait on async dock-configuration JS before entering the managed side-dock path"
        )
        XCTAssertTrue(
            pageView.superview === inspectorView.superview && pageView.superview !== slotView,
            "Promotion should move both hosted inspector siblings into the managed side-dock container"
        )
        XCTAssertEqual(
            pageView.frame.height,
            host.bounds.height,
            accuracy: 0.5,
            "Promotion should normalize stale page heights to the host height so the page layer stops covering the divider"
        )
        XCTAssertEqual(
            inspectorView.frame.height,
            host.bounds.height,
            accuracy: 0.5,
            "Promotion should normalize the inspector height to the host height"
        )
    }

    func testBrowserPanelHostAllowsRightDockedInspectorToExpandLeftAfterPromotion() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let host = WebViewRepresentable.HostContainerView(frame: NSRect(x: 180, y: 0, width: 240, height: contentView.bounds.height))
        host.autoresizingMask = [.minXMargin, .height]
        contentView.addSubview(host)

        let slotView = host.ensureLocalInlineSlotView()
        let pageView = WKWebView(frame: NSRect(x: 0, y: 0, width: 92, height: host.bounds.height))
        let inspectorView = WKWebView(
            frame: NSRect(x: 92, y: 0, width: slotView.bounds.width - 92, height: host.bounds.height)
        )
        slotView.addSubview(pageView)
        slotView.addSubview(inspectorView)
        host.pinHostedWebView(pageView, in: slotView)
        host.setHostedInspectorFrontendWebView(inspectorView)
        contentView.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()

        XCTAssertTrue(
            host.promoteHostedInspectorSideDockFromCurrentLayoutIfNeeded(),
            "The managed side-dock path should be active before drag assertions run"
        )

        let initialPageWidth = pageView.frame.width
        let initialInspectorWidth = inspectorView.frame.width
        let dividerPointInHost = NSPoint(x: inspectorView.frame.minX + 2, y: host.bounds.midY)
        let dividerPointInWindow = host.convert(dividerPointInHost, to: nil)

        host.mouseDown(with: makeMouseEvent(type: .leftMouseDown, location: dividerPointInWindow, window: window))
        let drag = makeMouseEvent(
            type: .leftMouseDragged,
            location: NSPoint(x: dividerPointInWindow.x - 40, y: dividerPointInWindow.y),
            window: window
        )
        host.mouseDragged(with: drag)
        host.mouseUp(with: makeMouseEvent(type: .leftMouseUp, location: drag.locationInWindow, window: window))

        XCTAssertGreaterThan(
            inspectorView.frame.width,
            initialInspectorWidth,
            "Right-docked DevTools should expand when the divider is dragged left"
        )
        XCTAssertLessThan(
            pageView.frame.width,
            initialPageWidth,
            "Expanding right-docked DevTools should shrink the page width"
        )
    }

    func testBrowserPanelHostKeepsAutomaticRightDockedWidthAboveMinimumWhileShrinking() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let host = WebViewRepresentable.HostContainerView(frame: NSRect(x: 140, y: 0, width: 280, height: contentView.bounds.height))
        host.autoresizingMask = [.minXMargin, .height]
        contentView.addSubview(host)

        let slotView = host.ensureLocalInlineSlotView()
        let pageView = WKWebView(frame: NSRect(x: 0, y: 0, width: 132, height: host.bounds.height))
        let inspectorView = WKWebView(
            frame: NSRect(x: 132, y: 0, width: slotView.bounds.width - 132, height: host.bounds.height)
        )
        slotView.addSubview(pageView)
        slotView.addSubview(inspectorView)
        host.pinHostedWebView(pageView, in: slotView)
        host.setHostedInspectorFrontendWebView(inspectorView)
        contentView.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()

        XCTAssertTrue(host.promoteHostedInspectorSideDockFromCurrentLayoutIfNeeded())

        host.setPreferredHostedInspectorWidth(width: 80, widthFraction: nil)
        host.setFrameSize(NSSize(width: 210, height: host.frame.height))
        contentView.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()

        XCTAssertGreaterThanOrEqual(
            inspectorView.frame.width,
            120,
            "Automatic pane resize should honor the same minimum hosted inspector width as manual dragging"
        )
        XCTAssertEqual(
            inspectorView.frame.height,
            host.bounds.height,
            accuracy: 0.5,
            "Automatic shrink should keep the inspector vertically normalized to the host height"
        )
    }

    func testBrowserPanelHostRequestsBottomDockWhenSideDockLeavesTooLittlePageWidth() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let host = WebViewRepresentable.HostContainerView(frame: NSRect(x: 180, y: 0, width: 280, height: contentView.bounds.height))
        host.autoresizingMask = [.minXMargin, .height]
        contentView.addSubview(host)

        let slotView = host.ensureLocalInlineSlotView()
        let pageView = WKWebView(frame: NSRect(x: 0, y: 0, width: 120, height: host.bounds.height))
        let inspectorView = TrackingInspectorFrontendWebView(
            frame: NSRect(x: 120, y: 0, width: slotView.bounds.width - 120, height: host.bounds.height)
        )
        slotView.addSubview(pageView)
        slotView.addSubview(inspectorView)
        host.pinHostedWebView(pageView, in: slotView)
        host.setHostedInspectorFrontendWebView(inspectorView)
        contentView.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()

        XCTAssertTrue(host.promoteHostedInspectorSideDockFromCurrentLayoutIfNeeded())

        host.setFrameSize(NSSize(width: 210, height: host.frame.height))
        contentView.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()

        XCTAssertTrue(
            inspectorView.evaluatedJavaScript.contains(where: { $0.contains("WI._dockBottom()") }),
            "Narrow pane widths should request bottom-docked DevTools instead of leaving the side-docked inspector in an unstable layout"
        )
        XCTAssertTrue(
            inspectorView.evaluatedJavaScript.contains(where: { $0.contains("const allowSideDock = false;") }),
            "Once a narrow pane proves it cannot safely side-dock DevTools, the inspector frontend should hide and disable left/right dock controls"
        )
    }

    func testBrowserPanelManagedSideDockDoesNotAutoresizeDraggedFrames() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let host = WebViewRepresentable.HostContainerView(frame: NSRect(x: 180, y: 0, width: 240, height: contentView.bounds.height))
        host.autoresizingMask = [.minXMargin, .height]
        contentView.addSubview(host)

        let slotView = host.ensureLocalInlineSlotView()
        let pageView = WKWebView(frame: NSRect(x: 0, y: 0, width: 92, height: host.bounds.height))
        let inspectorView = WKWebView(
            frame: NSRect(x: 92, y: 0, width: slotView.bounds.width - 92, height: host.bounds.height)
        )
        slotView.addSubview(pageView)
        slotView.addSubview(inspectorView)
        host.pinHostedWebView(pageView, in: slotView)
        host.setHostedInspectorFrontendWebView(inspectorView)
        contentView.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()

        XCTAssertTrue(host.promoteHostedInspectorSideDockFromCurrentLayoutIfNeeded())

        let dividerPointInHost = NSPoint(x: inspectorView.frame.minX + 2, y: host.bounds.midY)
        let dividerPointInWindow = host.convert(dividerPointInHost, to: nil)
        host.mouseDown(with: makeMouseEvent(type: .leftMouseDown, location: dividerPointInWindow, window: window))
        let drag = makeMouseEvent(
            type: .leftMouseDragged,
            location: NSPoint(x: dividerPointInWindow.x - 30, y: dividerPointInWindow.y),
            window: window
        )
        host.mouseDragged(with: drag)
        host.mouseUp(with: makeMouseEvent(type: .leftMouseUp, location: drag.locationInWindow, window: window))

        guard let managedContainer = pageView.superview else {
            XCTFail("Expected managed side-dock container")
            return
        }
        let draggedPageFrame = pageView.frame
        let draggedInspectorFrame = inspectorView.frame

        managedContainer.setFrameSize(
            NSSize(width: managedContainer.frame.width, height: managedContainer.frame.height + 24)
        )

        XCTAssertEqual(
            pageView.frame.origin.x,
            draggedPageFrame.origin.x,
            accuracy: 0.5,
            "Managed side-dock container should not autoresize the page back to a stale divider position"
        )
        XCTAssertEqual(
            pageView.frame.width,
            draggedPageFrame.width,
            accuracy: 0.5,
            "Managed side-dock container should preserve the dragged page width until the host explicitly reapplies layout"
        )
        XCTAssertEqual(
            inspectorView.frame.origin.x,
            draggedInspectorFrame.origin.x,
            accuracy: 0.5,
            "Managed side-dock container should preserve the dragged inspector origin"
        )
        XCTAssertEqual(
            inspectorView.frame.width,
            draggedInspectorFrame.width,
            accuracy: 0.5,
            "Managed side-dock container should preserve the dragged inspector width"
        )
    }

    func testBrowserPanelHostFallsBackToManualHostedInspectorDragForLeftDockedInspector() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let host = WebViewRepresentable.HostContainerView(frame: NSRect(x: 180, y: 0, width: 240, height: contentView.bounds.height))
        host.autoresizingMask = [.minXMargin, .height]
        contentView.addSubview(host)

        let webViewRoot = NSView(frame: host.bounds)
        webViewRoot.autoresizingMask = [.width, .height]
        host.addSubview(webViewRoot)

        let inspectorContainer = TrailingEdgeTransparentWKInspectorProbeView(
            frame: NSRect(x: 0, y: 0, width: 92, height: webViewRoot.bounds.height)
        )
        let pageView = PrimaryPageProbeView(
            frame: NSRect(x: 92, y: 0, width: webViewRoot.bounds.width - 92, height: webViewRoot.bounds.height)
        )
        webViewRoot.addSubview(inspectorContainer)
        webViewRoot.addSubview(pageView)
        contentView.layoutSubtreeIfNeeded()

        let dividerPointInHost = NSPoint(x: inspectorContainer.frame.maxX - 2, y: host.bounds.midY)
        let dividerPointInWindow = host.convert(dividerPointInHost, to: nil)

        XCTAssertTrue(
            host.hitTest(dividerPointInHost) === host,
            "Browser panel host should take the manual fallback path for a left-docked divider when the native edge is not hittable"
        )

        let down = makeMouseEvent(type: .leftMouseDown, location: dividerPointInWindow, window: window)
        host.mouseDown(with: down)
        let drag = makeMouseEvent(
            type: .leftMouseDragged,
            location: NSPoint(x: dividerPointInWindow.x + 40, y: dividerPointInWindow.y),
            window: window
        )
        host.mouseDragged(with: drag)
        host.mouseUp(with: makeMouseEvent(type: .leftMouseUp, location: drag.locationInWindow, window: window))

        XCTAssertGreaterThan(inspectorContainer.frame.width, 92)
        XCTAssertGreaterThan(pageView.frame.minX, 92)
    }

    func testBrowserPanelHostReappliesStoredHostedInspectorWidthAfterLayoutReset() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let host = WebViewRepresentable.HostContainerView(
            frame: NSRect(x: 180, y: 0, width: 240, height: contentView.bounds.height)
        )
        host.autoresizingMask = [.minXMargin, .height]
        contentView.addSubview(host)

        let webViewRoot = NSView(frame: host.bounds)
        webViewRoot.autoresizingMask = [.width, .height]
        host.addSubview(webViewRoot)

        let originalPageFrame = NSRect(x: 0, y: 0, width: 92, height: webViewRoot.bounds.height)
        let originalInspectorFrame = NSRect(
            x: 92,
            y: 0,
            width: webViewRoot.bounds.width - 92,
            height: webViewRoot.bounds.height
        )
        let pageView = PrimaryPageProbeView(frame: originalPageFrame)
        let inspectorContainer = NSView(frame: originalInspectorFrame)
        let inspectorView = WKInspectorProbeView(frame: inspectorContainer.bounds)
        inspectorView.autoresizingMask = [.width, .height]
        inspectorContainer.addSubview(inspectorView)
        webViewRoot.addSubview(pageView)
        webViewRoot.addSubview(inspectorContainer)
        contentView.layoutSubtreeIfNeeded()

        let dividerPointInHost = NSPoint(x: inspectorContainer.frame.minX + 2, y: host.bounds.midY)
        let dividerPointInWindow = host.convert(dividerPointInHost, to: nil)

        let down = makeMouseEvent(type: .leftMouseDown, location: dividerPointInWindow, window: window)
        host.mouseDown(with: down)
        let drag = makeMouseEvent(
            type: .leftMouseDragged,
            location: NSPoint(x: dividerPointInWindow.x + 48, y: dividerPointInWindow.y),
            window: window
        )
        host.mouseDragged(with: drag)
        host.mouseUp(with: makeMouseEvent(type: .leftMouseUp, location: drag.locationInWindow, window: window))

        let draggedPageWidth = pageView.frame.width
        let draggedInspectorMinX = inspectorContainer.frame.minX
        XCTAssertGreaterThan(draggedPageWidth, originalPageFrame.width)
        XCTAssertGreaterThan(draggedInspectorMinX, originalInspectorFrame.minX)

        pageView.frame = originalPageFrame
        inspectorContainer.frame = originalInspectorFrame
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()

        XCTAssertEqual(pageView.frame.width, draggedPageWidth, accuracy: 0.5)
        XCTAssertEqual(inspectorContainer.frame.minX, draggedInspectorMinX, accuracy: 0.5)
    }

    func testWindowBrowserSlotPinsHostedWebViewWithAutoresizingForAttachedInspector() {
        let slot = WindowBrowserSlotView(frame: NSRect(x: 0, y: 0, width: 240, height: 180))
        let webView = WKWebView(frame: .zero)
        slot.addSubview(webView)

        slot.pinHostedWebView(webView)
        slot.frame = NSRect(x: 0, y: 0, width: 300, height: 220)
        slot.layoutSubtreeIfNeeded()

        XCTAssertTrue(webView.translatesAutoresizingMaskIntoConstraints)
        XCTAssertEqual(webView.autoresizingMask, [.width, .height])
        XCTAssertEqual(webView.frame, slot.bounds)
    }

    func testWindowBrowserSlotReattachesPlainWebViewAtFullBoundsAfterHiddenHostResize() {
        let slot = WindowBrowserSlotView(frame: NSRect(x: 0, y: 0, width: 400, height: 180))
        let webView = WKWebView(frame: .zero)
        slot.addSubview(webView)
        slot.pinHostedWebView(webView)
        XCTAssertEqual(webView.frame, slot.bounds)

        let externalHost = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 180))
        webView.removeFromSuperview()
        externalHost.addSubview(webView)
        webView.frame = externalHost.bounds
        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.autoresizingMask = [.width, .height]

        slot.addSubview(webView)
        slot.pinHostedWebView(webView)

        slot.frame = NSRect(x: 0, y: 0, width: 300, height: 180)
        slot.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            webView.frame,
            slot.bounds,
            "Reattaching a plain web view should restore full-bounds hosting instead of preserving a stale inset frame from a hidden host"
        )
    }
}


@MainActor
final class BrowserPaneDropRoutingTests: XCTestCase {
    func testVerticalZonesFollowAppKitCoordinates() {
        let size = CGSize(width: 240, height: 180)

        XCTAssertEqual(
            BrowserPaneDropRouting.zone(for: CGPoint(x: size.width * 0.5, y: size.height - 8), in: size),
            .top
        )
        XCTAssertEqual(
            BrowserPaneDropRouting.zone(for: CGPoint(x: size.width * 0.5, y: 8), in: size),
            .bottom
        )
    }

    func testTopChromeHeightPushesTopSplitThresholdIntoWebView() {
        let size = CGSize(width: 240, height: 180)

        XCTAssertEqual(
            BrowserPaneDropRouting.zone(
                for: CGPoint(x: size.width * 0.5, y: 110),
                in: size,
                topChromeHeight: 36
            ),
            .center
        )
        XCTAssertEqual(
            BrowserPaneDropRouting.zone(
                for: CGPoint(x: size.width * 0.5, y: 150),
                in: size,
                topChromeHeight: 36
            ),
            .top
        )
    }

    func testHitTestingCapturesOnlyForRelevantDragEvents() {
        XCTAssertTrue(
            BrowserPaneDropTargetView.shouldCaptureHitTesting(
                pasteboardTypes: [DragOverlayRoutingPolicy.bonsplitTabTransferType],
                eventType: .cursorUpdate
            )
        )
        XCTAssertFalse(
            BrowserPaneDropTargetView.shouldCaptureHitTesting(
                pasteboardTypes: [DragOverlayRoutingPolicy.bonsplitTabTransferType],
                eventType: .leftMouseDown
            )
        )
        XCTAssertFalse(
            BrowserPaneDropTargetView.shouldCaptureHitTesting(
                pasteboardTypes: [.fileURL],
                eventType: .cursorUpdate
            )
        )
    }

    func testCenterDropOnSamePaneIsNoOp() {
        let paneId = PaneID(id: UUID())
        let target = BrowserPaneDropContext(
            workspaceId: UUID(),
            panelId: UUID(),
            paneId: paneId
        )
        let transfer = BrowserPaneDragTransfer(
            tabId: UUID(),
            sourcePaneId: paneId.id,
            sourceProcessId: Int32(ProcessInfo.processInfo.processIdentifier)
        )

        XCTAssertEqual(
            BrowserPaneDropRouting.action(for: transfer, target: target, zone: .center),
            .noOp
        )
    }

    func testRightEdgeDropBuildsSplitMoveAction() {
        let paneId = PaneID(id: UUID())
        let target = BrowserPaneDropContext(
            workspaceId: UUID(),
            panelId: UUID(),
            paneId: paneId
        )
        let tabId = UUID()
        let transfer = BrowserPaneDragTransfer(
            tabId: tabId,
            sourcePaneId: UUID(),
            sourceProcessId: Int32(ProcessInfo.processInfo.processIdentifier)
        )

        XCTAssertEqual(
            BrowserPaneDropRouting.action(for: transfer, target: target, zone: .right),
            .move(
                tabId: tabId,
                targetWorkspaceId: target.workspaceId,
                targetPane: paneId,
                splitTarget: BrowserPaneSplitTarget(orientation: .horizontal, insertFirst: false)
            )
        )
    }

    func testDecodeTransferPayloadReadsTabAndSourcePane() {
        let tabId = UUID()
        let sourcePaneId = UUID()
        let payload = try! JSONSerialization.data(
            withJSONObject: [
                "tab": ["id": tabId.uuidString],
                "sourcePaneId": sourcePaneId.uuidString,
                "sourceProcessId": ProcessInfo.processInfo.processIdentifier,
            ]
        )

        let transfer = BrowserPaneDragTransfer.decode(from: payload)

        XCTAssertEqual(transfer?.tabId, tabId)
        XCTAssertEqual(transfer?.sourcePaneId, sourcePaneId)
        XCTAssertTrue(transfer?.isFromCurrentProcess == true)
    }
}


@MainActor
final class WindowBrowserSlotViewTests: XCTestCase {
    private final class CapturingView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            bounds.contains(point) ? self : nil
        }
    }

    private func advanceAnimations() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    }

    func testDropZoneOverlayStaysAboveContentWithoutBlockingHits() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let slot = WindowBrowserSlotView(frame: container.bounds)
        container.addSubview(slot)
        let child = CapturingView(frame: slot.bounds)
        child.autoresizingMask = [.width, .height]
        slot.addSubview(child)

        slot.setDropZoneOverlay(zone: .right)
        container.layoutSubtreeIfNeeded()

        guard let overlay = container.subviews.first(where: {
            $0 !== slot && String(describing: type(of: $0)).contains("BrowserDropZoneOverlayView")
        }) else {
            XCTFail("Expected browser slot drop-zone overlay")
            return
        }

        XCTAssertTrue(container.subviews.last === overlay, "Overlay should stay above the hosted web view")
        XCTAssertFalse(overlay.isHidden)
        XCTAssertEqual(overlay.frame.origin.x, 100, accuracy: 0.5)
        XCTAssertEqual(overlay.frame.origin.y, 4, accuracy: 0.5)
        XCTAssertEqual(overlay.frame.size.width, 96, accuracy: 0.5)
        XCTAssertEqual(overlay.frame.size.height, 92, accuracy: 0.5)
        XCTAssertNil(overlay.hitTest(NSPoint(x: 120, y: 50)), "Overlay should never intercept pointer hits")
        XCTAssertTrue(slot.hitTest(NSPoint(x: 120, y: 50)) === child)

        slot.setDropZoneOverlay(zone: nil)
        advanceAnimations()
        XCTAssertTrue(overlay.isHidden, "Clearing the drop zone should hide the overlay")
    }

    func testTopDropZoneOverlayUsesFullBrowserContentHeight() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let slot = WindowBrowserSlotView(frame: container.bounds)
        container.addSubview(slot)

        slot.setPaneTopChromeHeight(20)
        slot.setDropZoneOverlay(zone: .top)
        container.layoutSubtreeIfNeeded()

        guard let overlay = container.subviews.first(where: {
            String(describing: type(of: $0)).contains("BrowserDropZoneOverlayView")
        }) else {
            XCTFail("Expected browser slot drop-zone overlay")
            return
        }

        XCTAssertFalse(overlay.isHidden)
        XCTAssertEqual(overlay.frame.origin.x, 4, accuracy: 0.5)
        XCTAssertEqual(overlay.frame.origin.y, 60, accuracy: 0.5)
        XCTAssertEqual(overlay.frame.size.width, 192, accuracy: 0.5)
        XCTAssertEqual(overlay.frame.size.height, 56, accuracy: 0.5)
        XCTAssertGreaterThan(overlay.frame.maxY, slot.frame.maxY)
        XCTAssertEqual(slot.layer?.masksToBounds, true)

        slot.setDropZoneOverlay(zone: nil)
        advanceAnimations()
        XCTAssertEqual(slot.layer?.masksToBounds, true)
    }
}


@MainActor
final class BrowserWindowPortalLifecycleTests: XCTestCase {
    // Un-quarantined (#169): the class-level CI skip added when the 2026-07-21 runner
    // image changed layout behavior for never-shown windows is no longer needed now
    // that testExternalSplitResizeDoesNotForceHostedWebViewPresentationRefresh — the
    // only test in this suite that was root-caused — drives its resync through an
    // explicit, synchronous call instead of relying on the deferred notification
    // observer (see that test). If other tests in this suite start failing on CI with
    // the same deferred-drain signature, they need the same explicit-drive treatment
    // rather than re-adding this blanket skip.

    private final class TrackingPortalWebView: WKWebView {
        private(set) var displayIfNeededCount = 0
        private(set) var reattachRenderingStateCount = 0

        override func displayIfNeeded() {
            displayIfNeededCount += 1
            super.displayIfNeeded()
        }

        @objc(_enterInWindow)
        func cmuxUnitTestEnterInWindow() {
            reattachRenderingStateCount += 1
        }

        @objc(_endDeferringViewInWindowChangesSync)
        func cmuxUnitTestEndDeferringViewInWindowChangesSync() {
            reattachRenderingStateCount += 1
        }
    }

    private final class WKInspectorProbeView: NSView {}

    private func realizeWindowLayout(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        // Give real headroom under a full serial suite run, where the main queue can
        // carry a genuine backlog from other tests' pending async work.
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    private func advanceAnimations() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
    }

    private func dropZoneOverlay(in slot: WindowBrowserSlotView, excluding webView: WKWebView) -> NSView? {
        let candidates = slot.subviews + (slot.superview?.subviews ?? [])
        return candidates.first(where: {
            $0 !== slot &&
            $0 !== webView &&
            String(describing: type(of: $0)).contains("BrowserDropZoneOverlayView")
        })
    }

    func testPortalHostInstallsAboveContentViewForVisibility() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        let portal = WindowBrowserPortal(window: window)
        _ = portal.webViewAtWindowPoint(NSPoint(x: 1, y: 1))

        guard let contentView = window.contentView,
              let container = contentView.superview else {
            XCTFail("Expected content container")
            return
        }

        guard let hostIndex = container.subviews.firstIndex(where: { $0 is WindowBrowserHostView }),
              let contentIndex = container.subviews.firstIndex(where: { $0 === contentView }) else {
            XCTFail("Expected host/content views in same container")
            return
        }

        XCTAssertGreaterThan(
            hostIndex,
            contentIndex,
            "Browser portal host must remain above content view so portal-hosted web views stay visible"
        )
    }

    func testBrowserPortalHostStaysAboveTerminalPortalHostDuringPortalChurn() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)

        let browserPortal = WindowBrowserPortal(window: window)
        let terminalPortal = WindowTerminalPortal(window: window)
        _ = browserPortal.webViewAtWindowPoint(NSPoint(x: 1, y: 1))
        _ = terminalPortal.viewAtWindowPoint(NSPoint(x: 1, y: 1))

        guard let contentView = window.contentView,
              let container = contentView.superview else {
            XCTFail("Expected content container")
            return
        }

        func assertHostOrder(_ message: String) {
            guard let browserHostIndex = container.subviews.firstIndex(where: { $0 is WindowBrowserHostView }),
                  let terminalHostIndex = container.subviews.firstIndex(where: { $0 is WindowTerminalHostView }) else {
                XCTFail("Expected both portal hosts in same container")
                return
            }

            XCTAssertGreaterThan(
                browserHostIndex,
                terminalHostIndex,
                message
            )
        }

        assertHostOrder("Browser portal host should start above terminal portal host")

        let terminalAnchor = NSView(frame: NSRect(x: 20, y: 20, width: 200, height: 140))
        contentView.addSubview(terminalAnchor)
        let terminalHostedView = GhosttySurfaceScrollView(
            surfaceView: GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        )
        terminalPortal.bind(hostedView: terminalHostedView, to: terminalAnchor, visibleInUI: true)
        terminalPortal.synchronizeHostedViewForAnchor(terminalAnchor)
        assertHostOrder("Terminal portal sync should not rise above the browser portal host")

        let browserAnchor = NSView(frame: NSRect(x: 240, y: 20, width: 220, height: 140))
        contentView.addSubview(browserAnchor)
        let webView = ProgramaWebView(frame: .zero, configuration: WKWebViewConfiguration())
        browserPortal.bind(webView: webView, to: browserAnchor, visibleInUI: true)
        browserPortal.synchronizeWebViewForAnchor(browserAnchor)
        assertHostOrder("Browser portal sync should keep browser panes above portal-hosted terminals")
    }

    func testAnchorRebindKeepsWebViewInStablePortalSuperview() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)
        let portal = WindowBrowserPortal(window: window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let anchor1 = NSView(frame: NSRect(x: 20, y: 20, width: 180, height: 120))
        let anchor2 = NSView(frame: NSRect(x: 240, y: 40, width: 180, height: 120))
        contentView.addSubview(anchor1)
        contentView.addSubview(anchor2)

        let webView = ProgramaWebView(frame: .zero, configuration: WKWebViewConfiguration())
        portal.bind(webView: webView, to: anchor1, visibleInUI: true)
        let firstSuperview = webView.superview

        XCTAssertNotNil(firstSuperview)
        XCTAssertTrue(firstSuperview is WindowBrowserSlotView)

        portal.bind(webView: webView, to: anchor2, visibleInUI: true)
        XCTAssertTrue(webView.superview === firstSuperview, "Anchor moves should not reparent the web view")

        contentView.layoutSubtreeIfNeeded()
        portal.synchronizeWebViewForAnchor(anchor2)
        guard let slot = webView.superview as? WindowBrowserSlotView,
              let host = slot.superview as? WindowBrowserHostView else {
            XCTFail("Expected browser slot + host views")
            return
        }
        let expectedFrame = host.convert(anchor2.bounds, from: anchor2)
        XCTAssertEqual(slot.frame.origin.x, expectedFrame.origin.x, accuracy: 0.5)
        XCTAssertEqual(slot.frame.origin.y, expectedFrame.origin.y, accuracy: 0.5)
        XCTAssertEqual(slot.frame.size.width, expectedFrame.size.width, accuracy: 0.5)
        XCTAssertEqual(slot.frame.size.height, expectedFrame.size.height, accuracy: 0.5)
    }

    func testPortalClampsWebViewFrameToHostBoundsWhenAnchorOverflowsSidebar() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)
        let portal = WindowBrowserPortal(window: window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        // Simulate a transient oversized anchor rect during split churn.
        let anchor = NSView(frame: NSRect(x: 120, y: 20, width: 260, height: 150))
        contentView.addSubview(anchor)

        let webView = ProgramaWebView(frame: .zero, configuration: WKWebViewConfiguration())
        portal.bind(webView: webView, to: anchor, visibleInUI: true)
        contentView.layoutSubtreeIfNeeded()
        portal.synchronizeWebViewForAnchor(anchor)

        guard let slot = webView.superview as? WindowBrowserSlotView else {
            XCTFail("Expected web view slot")
            return
        }

        XCTAssertFalse(slot.isHidden, "Partially visible browser anchor should stay visible")
        XCTAssertEqual(slot.frame.origin.x, 120, accuracy: 0.5)
        XCTAssertEqual(slot.frame.origin.y, 20, accuracy: 0.5)
        XCTAssertEqual(slot.frame.size.width, 200, accuracy: 0.5)
        XCTAssertEqual(slot.frame.size.height, 150, accuracy: 0.5)
    }

    func testPortalClipsAnchorFrameThroughAncestorBounds() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)
        let portal = WindowBrowserPortal(window: window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let clipView = NSView(frame: NSRect(x: 60, y: 40, width: 150, height: 120))
        contentView.addSubview(clipView)

        // Simulate SwiftUI/AppKit reporting an anchor wider than the actual visible pane.
        let anchor = NSView(frame: NSRect(x: -30, y: 0, width: 220, height: 120))
        clipView.addSubview(anchor)

        let webView = ProgramaWebView(frame: .zero, configuration: WKWebViewConfiguration())
        portal.bind(webView: webView, to: anchor, visibleInUI: true)
        contentView.layoutSubtreeIfNeeded()
        clipView.layoutSubtreeIfNeeded()
        portal.synchronizeWebViewForAnchor(anchor)

        guard let slot = webView.superview as? WindowBrowserSlotView else {
            XCTFail("Expected browser slot")
            return
        }

        XCTAssertFalse(slot.isHidden, "Ancestor clipping should keep the browser visible in the real pane")
        XCTAssertEqual(slot.frame.origin.x, 60, accuracy: 0.5)
        XCTAssertEqual(slot.frame.origin.y, 40, accuracy: 0.5)
        XCTAssertEqual(slot.frame.size.width, 150, accuracy: 0.5)
        XCTAssertEqual(slot.frame.size.height, 120, accuracy: 0.5)
    }

    func testPortalSyncNormalizesOutOfBoundsWebFrame() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)
        let portal = WindowBrowserPortal(window: window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let anchor = NSView(frame: NSRect(x: 40, y: 20, width: 220, height: 160))
        contentView.addSubview(anchor)

        let webView = ProgramaWebView(frame: .zero, configuration: WKWebViewConfiguration())
        portal.bind(webView: webView, to: anchor, visibleInUI: true)
        contentView.layoutSubtreeIfNeeded()
        portal.synchronizeWebViewForAnchor(anchor)

        guard let slot = webView.superview as? WindowBrowserSlotView else {
            XCTFail("Expected browser slot")
            return
        }

        // Reproduce observed drift from logs where WebKit shifts/expands frame beyond slot bounds.
        webView.frame = NSRect(x: 0, y: 250, width: slot.bounds.width, height: slot.bounds.height)
        XCTAssertGreaterThan(webView.frame.maxY, slot.bounds.maxY)

        portal.synchronizeWebViewForAnchor(anchor)
        XCTAssertEqual(webView.frame.origin.x, slot.bounds.origin.x, accuracy: 0.5)
        XCTAssertEqual(webView.frame.origin.y, slot.bounds.origin.y, accuracy: 0.5)
        XCTAssertEqual(webView.frame.size.width, slot.bounds.size.width, accuracy: 0.5)
        XCTAssertEqual(webView.frame.size.height, slot.bounds.size.height, accuracy: 0.5)
    }

    func testPortalSlotPinPreservesSideDockedInspectorManagedWebViewFrameOnRehost() {
        let slot = WindowBrowserSlotView(frame: NSRect(x: 0, y: 0, width: 240, height: 160))
        let webView = ProgramaWebView(frame: NSRect(x: 0, y: 0, width: 132, height: 160), configuration: WKWebViewConfiguration())
        let inspectorContainer = NSView(frame: NSRect(x: 132, y: 0, width: 108, height: 160))
        let inspectorView = WKInspectorProbeView(frame: inspectorContainer.bounds)
        inspectorView.autoresizingMask = [.width, .height]
        inspectorContainer.addSubview(inspectorView)
        slot.addSubview(webView)
        slot.addSubview(inspectorContainer)

        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.autoresizingMask = []
        slot.pinHostedWebView(webView)

        XCTAssertEqual(
            webView.frame.maxX,
            inspectorContainer.frame.minX,
            accuracy: 0.5,
            "Rehosting a portal-managed browser should preserve the WebKit-owned side inspector split"
        )
        XCTAssertLessThan(
            webView.frame.width,
            slot.bounds.width,
            "The page frame should stay narrower than the full slot while a side-docked inspector is present"
        )
    }

    func testPortalResizePreservesSideDockedInspectorManagedWebViewFrame() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)
        let portal = WindowBrowserPortal(window: window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let anchor = NSView(frame: NSRect(x: 40, y: 24, width: 260, height: 180))
        contentView.addSubview(anchor)

        let webView = ProgramaWebView(frame: .zero, configuration: WKWebViewConfiguration())
        portal.bind(webView: webView, to: anchor, visibleInUI: true)
        contentView.layoutSubtreeIfNeeded()
        portal.synchronizeWebViewForAnchor(anchor)

        guard let slot = webView.superview as? WindowBrowserSlotView else {
            XCTFail("Expected browser slot")
            return
        }

        let initialInspectorWidth: CGFloat = 110
        let inspectorContainer = NSView(
            frame: NSRect(
                x: slot.bounds.width - initialInspectorWidth,
                y: 0,
                width: initialInspectorWidth,
                height: slot.bounds.height
            )
        )
        inspectorContainer.autoresizingMask = [.minXMargin, .height]
        let inspectorView = WKInspectorProbeView(frame: inspectorContainer.bounds)
        inspectorView.autoresizingMask = [.width, .height]
        inspectorContainer.addSubview(inspectorView)
        slot.addSubview(inspectorContainer)

        webView.frame = NSRect(
            x: 0,
            y: 0,
            width: slot.bounds.width - initialInspectorWidth,
            height: slot.bounds.height
        )
        webView.autoresizingMask = [.width, .height]
        slot.layoutSubtreeIfNeeded()

        anchor.frame = NSRect(x: 40, y: 24, width: 220, height: 180)
        contentView.layoutSubtreeIfNeeded()
        portal.synchronizeWebViewForAnchor(anchor)

        XCTAssertFalse(slot.isHidden, "Resizing the browser pane should keep the hosted browser visible")
        XCTAssertEqual(
            webView.frame.maxX,
            inspectorContainer.frame.minX,
            accuracy: 0.5,
            "Portal sync should preserve the side-docked inspector split instead of stretching the page back over the inspector"
        )
        XCTAssertLessThan(
            webView.frame.width,
            slot.bounds.width,
            "Side-docked inspector should still own part of the slot after pane resize"
        )
    }

    func testPortalAnchorResizeDoesNotForceHostedWebViewPresentationRefresh() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)
        let portal = WindowBrowserPortal(window: window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let anchor = NSView(frame: NSRect(x: 40, y: 24, width: 220, height: 160))
        contentView.addSubview(anchor)

        let webView = TrackingPortalWebView(frame: .zero, configuration: WKWebViewConfiguration())
        portal.bind(webView: webView, to: anchor, visibleInUI: true)
        contentView.layoutSubtreeIfNeeded()
        portal.synchronizeWebViewForAnchor(anchor)
        advanceAnimations()

        guard let slot = webView.superview as? WindowBrowserSlotView else {
            XCTFail("Expected browser slot")
            return
        }

        let initialDisplayCount = webView.displayIfNeededCount
        let initialReattachCount = webView.reattachRenderingStateCount
        anchor.frame = NSRect(x: 52, y: 30, width: 248, height: 178)
        contentView.layoutSubtreeIfNeeded()
        portal.synchronizeWebViewForAnchor(anchor)
        advanceAnimations()

        XCTAssertFalse(slot.isHidden, "Anchor resize should keep the portal-hosted browser visible")
        XCTAssertEqual(slot.frame.origin.x, 52, accuracy: 0.5)
        XCTAssertEqual(slot.frame.origin.y, 30, accuracy: 0.5)
        XCTAssertEqual(slot.frame.size.width, 248, accuracy: 0.5)
        XCTAssertEqual(slot.frame.size.height, 178, accuracy: 0.5)
        XCTAssertGreaterThan(
            webView.displayIfNeededCount,
            initialDisplayCount,
            "Pure anchor geometry updates should still repaint the hosted browser"
        )
        XCTAssertEqual(
            webView.reattachRenderingStateCount,
            initialReattachCount,
            "Pure anchor geometry updates should not trigger the WebKit reattach path"
        )
    }

    func testExternalSplitResizeDoesNotForceHostedWebViewPresentationRefresh() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)
        let portal = WindowBrowserPortal(window: window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let splitView = NSSplitView(frame: contentView.bounds)
        splitView.autoresizingMask = [.width, .height]
        splitView.isVertical = true

        let leadingPane = NSView(
            frame: NSRect(x: 0, y: 0, width: 220, height: contentView.bounds.height)
        )
        leadingPane.autoresizingMask = [.height]
        let trailingPane = NSView(
            frame: NSRect(
                x: 221,
                y: 0,
                width: contentView.bounds.width - 221,
                height: contentView.bounds.height
            )
        )
        trailingPane.autoresizingMask = [.width, .height]
        splitView.addSubview(leadingPane)
        splitView.addSubview(trailingPane)
        contentView.addSubview(splitView)
        splitView.adjustSubviews()

        let anchor = NSView(frame: trailingPane.bounds.insetBy(dx: 12, dy: 12))
        anchor.autoresizingMask = [.width, .height]
        trailingPane.addSubview(anchor)

        let webView = TrackingPortalWebView(frame: .zero, configuration: WKWebViewConfiguration())
        portal.bind(webView: webView, to: anchor, visibleInUI: true)
        contentView.layoutSubtreeIfNeeded()
        portal.synchronizeWebViewForAnchor(anchor)
        advanceAnimations()

        guard let slot = webView.superview as? WindowBrowserSlotView else {
            XCTFail("Expected browser slot")
            return
        }

        let initialDisplayCount = webView.displayIfNeededCount
        let initialReattachCount = webView.reattachRenderingStateCount
        let initialWidth = slot.frame.width

        splitView.setPosition(280, ofDividerAt: 0)
        contentView.layoutSubtreeIfNeeded()
        // Drive the resync through an explicit, synchronous call instead of relying on
        // NSSplitView.didResizeSubviewsNotification's observer, which defers the actual
        // resync via DispatchQueue.main.async (see WindowBrowserPortal.scheduleExternal-
        // GeometrySynchronize). On the CI runner image that deferred block does not drain
        // within advanceAnimations()'s RunLoop window, so the portal never resyncs and
        // this test no-ops deterministically (#169) even though contentView's layout
        // pass above did resize the anchor. Calling synchronizeWebViewForAnchor directly
        // exercises the exact same production sync path the notification would eventually
        // reach (WindowBrowserPortal.synchronizeWebView(withId:source:)); it does not
        // manufacture the geometryOnly refresh below — that still only fires because the
        // anchor's frame genuinely changed. We still post the notification afterward so
        // any other observers of it keep seeing real split-resize behavior.
        portal.synchronizeWebViewForAnchor(anchor)
        NotificationCenter.default.post(name: NSSplitView.didResizeSubviewsNotification, object: splitView)
        advanceAnimations()

        XCTAssertFalse(slot.isHidden, "App split resize should keep the browser slot visible")
        XCTAssertLessThan(
            slot.frame.width,
            initialWidth,
            "Moving the app split divider should shrink the hosted browser slot"
        )
        XCTAssertGreaterThan(
            webView.displayIfNeededCount,
            initialDisplayCount,
            "External split resize should still repaint the hosted browser"
        )
        XCTAssertEqual(
            webView.reattachRenderingStateCount,
            initialReattachCount,
            "External split resize should not trigger the WebKit reattach path"
        )
    }

    func testPortalSyncRepairsBottomDockedInspectorOverflowedPageFrame() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)
        let portal = WindowBrowserPortal(window: window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let anchor = NSView(frame: NSRect(x: 40, y: 24, width: 260, height: 180))
        contentView.addSubview(anchor)

        let webView = ProgramaWebView(frame: .zero, configuration: WKWebViewConfiguration())
        portal.bind(webView: webView, to: anchor, visibleInUI: true)
        contentView.layoutSubtreeIfNeeded()
        portal.synchronizeWebViewForAnchor(anchor)

        guard let slot = webView.superview as? WindowBrowserSlotView else {
            XCTFail("Expected browser slot")
            return
        }

        let inspectorHeight: CGFloat = 84
        let inspectorContainer = NSView(
            frame: NSRect(x: 0, y: 0, width: slot.bounds.width, height: inspectorHeight)
        )
        inspectorContainer.autoresizingMask = [.width]
        let inspectorView = WKInspectorProbeView(frame: inspectorContainer.bounds)
        inspectorView.autoresizingMask = [.width, .height]
        inspectorContainer.addSubview(inspectorView)
        slot.addSubview(inspectorContainer)

        webView.frame = NSRect(
            x: 0,
            y: inspectorHeight,
            width: slot.bounds.width,
            height: slot.bounds.height
        )
        webView.autoresizingMask = [.width, .height]
        slot.layoutSubtreeIfNeeded()

        portal.synchronizeWebViewForAnchor(anchor)

        XCTAssertFalse(slot.isHidden, "Portal sync should keep the hosted browser visible")
        XCTAssertEqual(
            webView.frame.minY,
            inspectorHeight,
            accuracy: 0.5,
            "Portal sync should keep the page viewport below a bottom-docked inspector instead of shifting the page upward"
        )
        XCTAssertEqual(
            webView.frame.height,
            slot.bounds.height - inspectorHeight,
            accuracy: 0.5,
            "Portal sync should shrink the page viewport to the space above a bottom-docked inspector"
        )
        XCTAssertEqual(
            webView.frame.maxY,
            slot.bounds.maxY,
            accuracy: 0.5,
            "The repaired page viewport should stay flush with the top edge of the slot"
        )
    }

    func testHidingBrowserSlotYieldsOwnedInspectorFirstResponder() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let slot = WindowBrowserSlotView(frame: NSRect(x: 40, y: 24, width: 260, height: 180))
        contentView.addSubview(slot)

        let inspectorContainer = NSView(frame: slot.bounds)
        inspectorContainer.autoresizingMask = [.width, .height]
        let inspectorView = WKInspectorProbeView(frame: inspectorContainer.bounds)
        inspectorView.autoresizingMask = [.width, .height]
        inspectorContainer.addSubview(inspectorView)
        slot.addSubview(inspectorContainer)
        contentView.layoutSubtreeIfNeeded()

        XCTAssertTrue(
            window.makeFirstResponder(inspectorView),
            "Precondition failed: inspector probe should become first responder"
        )
        XCTAssertTrue(window.firstResponder === inspectorView)

        slot.isHidden = true

        XCTAssertFalse(
            window.firstResponder === inspectorView,
            "Hiding a browser slot should yield any owned inspector responder before it goes off-screen"
        )
        if let firstResponderView = window.firstResponder as? NSView {
            XCTAssertFalse(
                firstResponderView === slot || firstResponderView.isDescendant(of: slot),
                "Hiding a browser slot should not leave first responder inside the hidden slot"
            )
        }
    }

    func testHiddenPortalSyncDoesNotStealLocallyHostedDevToolsWebViewDuringResize() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)
        let portal = WindowBrowserPortal(window: window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let anchor = NSView(frame: NSRect(x: 40, y: 24, width: 260, height: 180))
        contentView.addSubview(anchor)

        let webView = ProgramaWebView(frame: .zero, configuration: WKWebViewConfiguration())
        portal.bind(webView: webView, to: anchor, visibleInUI: true)
        contentView.layoutSubtreeIfNeeded()
        portal.synchronizeWebViewForAnchor(anchor)
        advanceAnimations()

        guard let hiddenPortalSlot = webView.superview as? WindowBrowserSlotView else {
            XCTFail("Expected browser slot")
            return
        }

        portal.updateEntryVisibility(forWebViewId: ObjectIdentifier(webView), visibleInUI: false, zPriority: 0)
        portal.synchronizeWebViewForAnchor(anchor)
        advanceAnimations()
        XCTAssertTrue(hiddenPortalSlot.isHidden, "Hidden portal entry should keep its slot hidden")

        let localInlineSlot = WindowBrowserSlotView(frame: anchor.frame)
        contentView.addSubview(localInlineSlot)

        let inspectorView = WKInspectorProbeView(
            frame: NSRect(x: 0, y: 0, width: localInlineSlot.bounds.width, height: 72)
        )
        inspectorView.autoresizingMask = [.width]
        localInlineSlot.addSubview(inspectorView)

        localInlineSlot.addSubview(webView)
        webView.frame = NSRect(
            x: 0,
            y: inspectorView.frame.maxY,
            width: localInlineSlot.bounds.width,
            height: localInlineSlot.bounds.height - inspectorView.frame.height
        )
        localInlineSlot.layoutSubtreeIfNeeded()

        anchor.frame = NSRect(x: 40, y: 24, width: 220, height: 180)
        localInlineSlot.frame = anchor.frame
        contentView.layoutSubtreeIfNeeded()
        localInlineSlot.layoutSubtreeIfNeeded()
        portal.synchronizeWebViewForAnchor(anchor)

        XCTAssertTrue(
            webView.superview === localInlineSlot,
            "Hidden portal sync should not steal a DevTools-hosted web view back out of local inline hosting during pane resize"
        )
        XCTAssertTrue(
            inspectorView.superview === localInlineSlot,
            "Hidden portal sync should leave local DevTools companion views in the local inline host"
        )
        XCTAssertTrue(hiddenPortalSlot.isHidden, "The retiring hidden portal slot should stay hidden during local inline hosting")
    }

    func testPortalHostBoundsBecomeReadyAfterBindingInFrameDrivenHierarchy() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)
        let portal = WindowBrowserPortal(window: window)

        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }
        let anchor = NSView(frame: NSRect(x: 40, y: 24, width: 220, height: 160))
        contentView.addSubview(anchor)

        let webView = ProgramaWebView(frame: .zero, configuration: WKWebViewConfiguration())
        portal.bind(webView: webView, to: anchor, visibleInUI: true)
        portal.synchronizeWebViewForAnchor(anchor)

        guard let slot = webView.superview as? WindowBrowserSlotView,
              let host = slot.superview as? WindowBrowserHostView else {
            XCTFail("Expected portal slot + host views")
            return
        }
        XCTAssertGreaterThan(host.bounds.width, 1, "Portal host width should be ready for clipping/sync")
        XCTAssertGreaterThan(host.bounds.height, 1, "Portal host height should be ready for clipping/sync")
    }

    func testPortalDropZoneOverlayPersistsAcrossVisibilityChanges() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)
        let portal = WindowBrowserPortal(window: window)

        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }
        let anchor = NSView(frame: NSRect(x: 40, y: 24, width: 220, height: 160))
        contentView.addSubview(anchor)

        let webView = ProgramaWebView(frame: .zero, configuration: WKWebViewConfiguration())
        portal.bind(webView: webView, to: anchor, visibleInUI: true)
        portal.synchronizeWebViewForAnchor(anchor)

        guard let slot = webView.superview as? WindowBrowserSlotView,
              let overlay = dropZoneOverlay(in: slot, excluding: webView) else {
            XCTFail("Expected browser slot overlay")
            return
        }

        XCTAssertTrue(overlay.isHidden, "Overlay should start hidden without an active drop zone")

        portal.updateDropZoneOverlay(forWebViewId: ObjectIdentifier(webView), zone: .right)
        slot.layoutSubtreeIfNeeded()
        XCTAssertFalse(overlay.isHidden)
        XCTAssertTrue(slot.superview?.subviews.last === overlay, "Overlay should remain above the hosted web view")
        XCTAssertEqual(overlay.frame.origin.x, slot.frame.origin.x + 110, accuracy: 0.5)
        XCTAssertEqual(overlay.frame.origin.y, slot.frame.origin.y + 4, accuracy: 0.5)
        XCTAssertEqual(overlay.frame.size.width, 106, accuracy: 0.5)
        XCTAssertEqual(overlay.frame.size.height, 152, accuracy: 0.5)

        portal.updateEntryVisibility(forWebViewId: ObjectIdentifier(webView), visibleInUI: false, zPriority: 0)
        portal.synchronizeWebViewForAnchor(anchor)
        advanceAnimations()
        XCTAssertTrue(overlay.isHidden, "Invisible browser entries should hide the overlay")

        portal.updateEntryVisibility(forWebViewId: ObjectIdentifier(webView), visibleInUI: true, zPriority: 0)
        portal.synchronizeWebViewForAnchor(anchor)
        XCTAssertFalse(overlay.isHidden, "Restoring visibility should restore the active drop-zone overlay")
    }

    func testPortalRevealRefreshesHostedWebViewWithoutFrameDelta() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)
        let portal = WindowBrowserPortal(window: window)

        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }
        let anchor = NSView(frame: NSRect(x: 40, y: 24, width: 220, height: 160))
        contentView.addSubview(anchor)

        let webView = TrackingPortalWebView(frame: .zero, configuration: WKWebViewConfiguration())
        portal.bind(webView: webView, to: anchor, visibleInUI: true)
        portal.synchronizeWebViewForAnchor(anchor)
        advanceAnimations()
        let initialDisplayCount = webView.displayIfNeededCount
        let initialReattachCount = webView.reattachRenderingStateCount

        portal.updateEntryVisibility(forWebViewId: ObjectIdentifier(webView), visibleInUI: false, zPriority: 0)
        portal.synchronizeWebViewForAnchor(anchor)
        advanceAnimations()
        let hiddenDisplayCount = webView.displayIfNeededCount
        let hiddenReattachCount = webView.reattachRenderingStateCount

        portal.updateEntryVisibility(forWebViewId: ObjectIdentifier(webView), visibleInUI: true, zPriority: 0)
        portal.synchronizeWebViewForAnchor(anchor)
        advanceAnimations()

        XCTAssertGreaterThanOrEqual(hiddenDisplayCount, initialDisplayCount)
        XCTAssertEqual(
            hiddenReattachCount,
            initialReattachCount,
            "Hiding a portal-hosted browser should not itself trigger the WebKit reattach path"
        )
        XCTAssertGreaterThan(
            webView.displayIfNeededCount,
            hiddenDisplayCount,
            "Revealing an existing portal-hosted browser should refresh WebKit presentation immediately"
        )
        XCTAssertGreaterThan(
            webView.reattachRenderingStateCount,
            hiddenReattachCount,
            "Revealing an existing portal-hosted browser should trigger the WebKit reattach path"
        )
    }

    func testVisiblePortalEntryHidesWithoutDetachingDuringTransientAnchorRemovalUntilRebind() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)
        let portal = WindowBrowserPortal(window: window)

        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let anchorFrame = NSRect(x: 40, y: 24, width: 220, height: 160)
        let anchor1 = NSView(frame: anchorFrame)
        contentView.addSubview(anchor1)

        let webView = TrackingPortalWebView(frame: .zero, configuration: WKWebViewConfiguration())
        portal.bind(webView: webView, to: anchor1, visibleInUI: true)
        portal.synchronizeWebViewForAnchor(anchor1)
        advanceAnimations()

        guard let slot = webView.superview as? WindowBrowserSlotView else {
            XCTFail("Expected browser slot")
            return
        }

        anchor1.removeFromSuperview()
        portal.synchronizeWebViewForAnchor(anchor1)
        advanceAnimations()

        XCTAssertTrue(webView.superview === slot, "Visible browser entries should not detach during transient anchor removal")
        XCTAssertTrue(
            slot.isHidden,
            "Transient anchor churn should hide the stale browser slot instead of rendering in the wrong pane"
        )
        XCTAssertEqual(portal.debugEntryCount(), 1)

        let displayCountBeforeRebind = webView.displayIfNeededCount
        let anchor2 = NSView(frame: anchorFrame)
        contentView.addSubview(anchor2)
        portal.bind(webView: webView, to: anchor2, visibleInUI: true)
        portal.synchronizeWebViewForAnchor(anchor2)
        advanceAnimations()

        XCTAssertTrue(webView.superview === slot, "Rebinding after transient anchor removal should reuse the existing portal slot")
        XCTAssertFalse(slot.isHidden)
        XCTAssertEqual(portal.debugEntryCount(), 1)
        XCTAssertGreaterThan(
            webView.displayIfNeededCount,
            displayCountBeforeRebind,
            "Anchor rebinds should refresh hosted browser presentation even when geometry is unchanged"
        )
    }

    func testVisiblePortalEntryStaysVisibleDuringOffWindowAnchorReparentUntilRebind() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)
        let portal = WindowBrowserPortal(window: window)

        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let anchorFrame = NSRect(x: 40, y: 24, width: 220, height: 160)
        let anchor = NSView(frame: anchorFrame)
        contentView.addSubview(anchor)

        let webView = TrackingPortalWebView(frame: .zero, configuration: WKWebViewConfiguration())
        portal.bind(webView: webView, to: anchor, visibleInUI: true)
        portal.synchronizeWebViewForAnchor(anchor)
        advanceAnimations()

        guard let slot = webView.superview as? WindowBrowserSlotView else {
            XCTFail("Expected browser slot")
            return
        }

        let offWindowContainer = NSView(frame: anchorFrame)
        anchor.removeFromSuperview()
        offWindowContainer.addSubview(anchor)
        portal.synchronizeWebViewForAnchor(anchor)
        advanceAnimations()

        XCTAssertTrue(
            webView.superview === slot,
            "Off-window anchor reparent should preserve the hosted browser slot during drag churn"
        )
        XCTAssertFalse(
            slot.isHidden,
            "Off-window anchor reparent should keep the visible browser portal alive until the anchor returns"
        )
        XCTAssertEqual(portal.debugEntryCount(), 1)

        contentView.addSubview(anchor)
        portal.synchronizeWebViewForAnchor(anchor)
        advanceAnimations()

        XCTAssertTrue(webView.superview === slot, "Rebinding after off-window reparent should reuse the existing portal slot")
        XCTAssertFalse(slot.isHidden)
        XCTAssertEqual(portal.debugEntryCount(), 1)
    }

    func testRegistryDetachRemovesPortalHostedWebView() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let anchor = NSView(frame: NSRect(x: 20, y: 20, width: 180, height: 120))
        contentView.addSubview(anchor)
        let webView = ProgramaWebView(frame: .zero, configuration: WKWebViewConfiguration())

        BrowserWindowPortalRegistry.bind(webView: webView, to: anchor, visibleInUI: true)
        XCTAssertNotNil(webView.superview)

        BrowserWindowPortalRegistry.detach(webView: webView)
        XCTAssertNil(webView.superview)
    }

    func testRegistryHideKeepsPortalHostedWebViewAttachedButHidden() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let anchor = NSView(frame: NSRect(x: 20, y: 20, width: 180, height: 120))
        contentView.addSubview(anchor)
        let webView = ProgramaWebView(frame: .zero, configuration: WKWebViewConfiguration())

        BrowserWindowPortalRegistry.bind(webView: webView, to: anchor, visibleInUI: true)
        BrowserWindowPortalRegistry.synchronizeForAnchor(anchor)
        advanceAnimations()

        guard let slot = webView.superview as? WindowBrowserSlotView else {
            XCTFail("Expected browser slot")
            return
        }
        XCTAssertFalse(slot.isHidden)

        BrowserWindowPortalRegistry.hide(webView: webView, source: "unitTest")
        advanceAnimations()

        XCTAssertTrue(webView.superview === slot, "Hiding should preserve the hosted WKWebView attachment")
        XCTAssertTrue(slot.isHidden, "Hiding should immediately hide the existing portal slot")
    }

    func testHiddenPortalEntrySurvivesAnchorRemovalUntilWorkspaceRebind() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)
        let portal = WindowBrowserPortal(window: window)

        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let anchorFrame = NSRect(x: 40, y: 24, width: 220, height: 160)
        let oldAnchor = NSView(frame: anchorFrame)
        contentView.addSubview(oldAnchor)

        let webView = TrackingPortalWebView(frame: .zero, configuration: WKWebViewConfiguration())
        portal.bind(webView: webView, to: oldAnchor, visibleInUI: true)
        portal.synchronizeWebViewForAnchor(oldAnchor)
        advanceAnimations()

        guard let slot = webView.superview as? WindowBrowserSlotView else {
            XCTFail("Expected browser slot")
            return
        }

        portal.updateEntryVisibility(forWebViewId: ObjectIdentifier(webView), visibleInUI: false, zPriority: 0)
        portal.synchronizeWebViewForAnchor(oldAnchor)
        advanceAnimations()
        XCTAssertTrue(slot.isHidden, "Workspace handoff should hide the retiring browser before unmount")

        oldAnchor.removeFromSuperview()
        portal.synchronizeWebViewForAnchor(oldAnchor)
        advanceAnimations()

        XCTAssertTrue(
            webView.superview === slot,
            "Hidden workspace browsers should stay attached while their SwiftUI anchor is temporarily unmounted"
        )
        XCTAssertTrue(slot.isHidden, "Unmounted hidden workspace browser should remain hidden until rebound")
        XCTAssertEqual(portal.debugEntryCount(), 1, "Workspace handoff should keep the hidden browser portal entry alive")

        let displayCountBeforeRebind = webView.displayIfNeededCount
        let newAnchor = NSView(frame: anchorFrame)
        contentView.addSubview(newAnchor)
        portal.bind(webView: webView, to: newAnchor, visibleInUI: true)
        portal.synchronizeWebViewForAnchor(newAnchor)
        advanceAnimations()

        XCTAssertTrue(
            webView.superview === slot,
            "Selecting the workspace again should reuse the existing hidden browser portal slot"
        )
        XCTAssertFalse(slot.isHidden, "Rebinding the workspace browser should reveal the existing portal slot")
        XCTAssertEqual(portal.debugEntryCount(), 1)
        XCTAssertGreaterThan(
            webView.displayIfNeededCount,
            displayCountBeforeRebind,
            "Workspace rebind should refresh the preserved browser without recreating its portal slot"
        )
    }

    /// Pins the H4 isDead-policy divergence (nuclear-review N4) directly at the
    /// `pruneDeadEntries` boundary: unlike `WindowTerminalPortal`, which treats a fully
    /// deallocated anchor as dead (see
    /// `TerminalWindowPortalLifecycleTests.testPruneDeadEntriesDetachesAnchorlessHostedView`),
    /// `WindowBrowserPortal` deliberately keeps the entry alive so a hidden WKWebView
    /// survives a workspace switch instead of forcing a WebKit reload storm. This test
    /// exercises the *fully deallocated* anchor case (weak ref auto-nil'd), which is a
    /// stronger signal than the merely-off-tree case already covered by
    /// `testHiddenPortalEntrySurvivesAnchorRemovalUntilWorkspaceRebind` above.
    func testPruneDeadEntriesPreservesWebViewWhenAnchorIsFullyDeallocated() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        let portal = WindowBrowserPortal(window: window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let webView1 = ProgramaWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let webView2 = ProgramaWebView(frame: .zero, configuration: WKWebViewConfiguration())
        // Allocate anchor2 before anchor1 is dropped so ARC can't reuse anchor1's freed
        // memory address for anchor2 — an address reuse would make
        // ObjectIdentifier(anchor2) alias the stale webViewByAnchorId[anchor1] entry and
        // trip bind()'s unrelated "anchor replaced" detach path instead of exercising
        // pruneDeadEntries' nil-anchor policy.
        let anchor2 = NSView(frame: NSRect(x: 180, y: 20, width: 120, height: 80))

        // Drop the anchor inside an autoreleasepool so the portal's weak reference
        // actually nils out before pruneDeadEntries runs — AppKit teardown is not
        // synchronous with the last strong-reference drop.
        autoreleasepool {
            var anchor1: NSView? = NSView(frame: NSRect(x: 20, y: 20, width: 120, height: 80))
            contentView.addSubview(anchor1!)
            portal.bind(webView: webView1, to: anchor1!, visibleInUI: true)

            anchor1?.removeFromSuperview()
            anchor1 = nil
        }

        contentView.addSubview(anchor2)
        portal.bind(webView: webView2, to: anchor2, visibleInUI: true)

        XCTAssertEqual(
            portal.debugEntryCount(), 2,
            "Browser must keep the anchorless entry alive (unlike Terminal) so a hidden " +
            "WKWebView survives workspace switching without a reload"
        )
        XCTAssertTrue(
            portal.webViewIds().contains(ObjectIdentifier(webView1)),
            "The webView with a fully deallocated anchor must remain tracked, not pruned"
        )
    }
}
