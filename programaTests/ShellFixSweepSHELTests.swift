import XCTest
import AppKit

#if canImport(Programa_DEV)
@testable import Programa_DEV
#elseif canImport(Programa)
@testable import Programa
#endif

// MARK: - SHEL-03: window close gate

@MainActor
final class WindowCloseGateTests: XCTestCase {
    func testCancelledConfirmationKeepsTheWindowAndAsksExactlyOnce() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        let terminal = try XCTUnwrap(workspace.terminalPanel(for: panelId))
        terminal.surface.setNeedsConfirmCloseOverrideForTesting(false)
        workspace.updatePanelShellActivityState(panelId: panelId, state: .commandRunning)

        var titles: [String] = []
        manager.confirmCloseHandler = { title, _, _ in
            titles.append(title)
            return false
        }

        XCTAssertFalse(manager.confirmCloseWindowIfNeeded(), "Cancel must veto the window close")
        XCTAssertEqual(titles, [String(localized: "dialog.closeWindow.title", defaultValue: "Close window?")])
    }

    func testAcceptedConfirmationAllowsTheClose() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        workspace.updatePanelShellActivityState(panelId: panelId, state: .commandRunning)

        var promptCount = 0
        manager.confirmCloseHandler = { _, _, _ in
            promptCount += 1
            return true
        }

        XCTAssertTrue(manager.confirmCloseWindowIfNeeded())
        XCTAssertEqual(promptCount, 1)
    }

    func testIdleWindowClosesWithoutPrompt() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        workspace.updatePanelShellActivityState(panelId: panelId, state: .promptIdle)

        var promptCount = 0
        manager.confirmCloseHandler = { _, _, _ in
            promptCount += 1
            return false
        }

        XCTAssertTrue(manager.confirmCloseWindowIfNeeded())
        XCTAssertEqual(promptCount, 0, "Nothing is running, so there is nothing to confirm")
    }
}

// MARK: - SHEL-06 / SHEL-07: external open policy

final class ExternalOpenPolicySHELTests: XCTestCase {
    func testNativeGestureWindowAcceptsOnlyRecentPastTimestamps() {
        XCTAssertTrue(ExternalOpenPolicy.isRecentNativeGesture([99.5], now: 100))
        XCTAssertTrue(ExternalOpenPolicy.isRecentNativeGesture([nil, 99.5], now: 100))
        XCTAssertFalse(ExternalOpenPolicy.isRecentNativeGesture([nil], now: 100))
        XCTAssertFalse(ExternalOpenPolicy.isRecentNativeGesture([], now: 100))
        XCTAssertFalse(ExternalOpenPolicy.isRecentNativeGesture([98], now: 100), "Stale gesture must not unlock a remembered approval")
        XCTAssertFalse(ExternalOpenPolicy.isRecentNativeGesture([101], now: 100), "A timestamp in the future is not a past gesture")
    }

    func testRememberedApprovalIsIgnoredWithoutANativeGesture() throws {
        let url = try XCTUnwrap(URL(string: "ssh://x"))
        let allow = [ExternalOpenPolicy.allowlistKey(bundleIdentifier: "com.apple.Terminal", scheme: "ssh")]
        XCTAssertEqual(
            ExternalOpenPolicy.requirement(for: url, handlerBundleIdentifier: "com.apple.Terminal", allowlist: allow, targetIsExecutable: false, allowRememberedApproval: false),
            .prompt(offerAlwaysAllow: true)
        )
        XCTAssertEqual(
            ExternalOpenPolicy.requirement(for: url, handlerBundleIdentifier: "com.apple.Terminal", allowlist: allow, targetIsExecutable: false, allowRememberedApproval: true),
            .openWithoutPrompt
        )
    }

    func testApprovalIsScopedToTheSchemeItWasGivenFor() throws {
        let allow = ["com.apple.Terminal|ssh"]
        XCTAssertEqual(
            ExternalOpenPolicy.requirement(for: try XCTUnwrap(URL(string: "ssh://x")), handlerBundleIdentifier: "com.apple.Terminal", allowlist: allow, targetIsExecutable: false),
            .openWithoutPrompt
        )
        XCTAssertEqual(
            ExternalOpenPolicy.requirement(for: try XCTUnwrap(URL(string: "telnet://x")), handlerBundleIdentifier: "com.apple.Terminal", allowlist: allow, targetIsExecutable: false),
            .prompt(offerAlwaysAllow: true),
            "Approving Terminal for ssh must not approve Terminal for another scheme"
        )
    }

    func testTerminalDocumentAlwaysPromptsWithoutRememberOffer() {
        let allow = ["com.apple.Terminal|file"]
        XCTAssertEqual(
            ExternalOpenPolicy.requirement(
                for: URL(fileURLWithPath: "/x/setup.terminal"),
                handlerBundleIdentifier: "com.apple.Terminal",
                allowlist: allow,
                targetIsExecutable: ExternalOpenPolicy.targetIsExecutable(URL(fileURLWithPath: "/x/setup.terminal"))
            ),
            .prompt(offerAlwaysAllow: false)
        )
    }

    func testAllowlistDropsLegacyBundleOnlyEntries() throws {
        let suite = "ExternalOpenPolicySHELTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("com.apple.Terminal\ncom.apple.Terminal|ssh", forKey: ExternalOpenPolicy.allowlistKey)
        XCTAssertEqual(ExternalOpenPolicy.allowlist(defaults: defaults), ["com.apple.Terminal|ssh"])
    }
}

// MARK: - SHEL-11: omnibar input resolution

final class BrowserNavigableURLResolutionSHELTests: XCTestCase {
    func testHostPortAndSchemeLessInputsResolveToTheRightScheme() {
        XCTAssertEqual(resolveBrowserNavigableURL("example.com:8080")?.absoluteString, "http://example.com:8080")
        XCTAssertEqual(resolveBrowserNavigableURL("foo.local:3000")?.absoluteString, "http://foo.local:3000")
        XCTAssertEqual(resolveBrowserNavigableURL("my-nas:8080")?.absoluteString, "http://my-nas:8080")
        XCTAssertEqual(resolveBrowserNavigableURL("localhostile.com")?.absoluteString, "https://localhostile.com", "Only exact loopback hosts get http")
    }

    func testFilePathAndAboutBlankPassThrough() {
        let file = resolveBrowserNavigableURL("/tmp/a.html")
        XCTAssertEqual(file?.isFileURL, true)
        XCTAssertEqual(file?.path, "/tmp/a.html")
        XCTAssertEqual(resolveBrowserNavigableURL("about:blank")?.absoluteString, "about:blank")
    }

    func testNonWebSchemesAreRejected() {
        XCTAssertNil(resolveBrowserNavigableURL("mailto:x@y.z"))
    }
}

// MARK: - SHEL-12: design mode payload bounds

final class DesignModePayloadBoundsTests: XCTestCase {
    func testHTMLHasNoLineBreaks() {
        let payload = DesignModePickPayload(
            html: "a\nb\r",
            css: [:],
            selector: "div",
            rect: DesignModePickRect(x: 0, y: 0, width: 1, height: 1),
            url: "https://example.com"
        )
        XCTAssertFalse(payload.html.contains("\n"))
        XCTAssertFalse(payload.html.contains("\r"))
    }

    func testCSSKeysAreCapped() {
        var css: [String: String] = [:]
        for index in 0..<100 { css["prop-\(index)"] = "v" }
        let payload = DesignModePickPayload(
            html: "x",
            css: css,
            selector: "div",
            rect: DesignModePickRect(x: 0, y: 0, width: 1, height: 1),
            url: "u"
        )
        XCTAssertEqual(payload.css.count, DesignModePickPayload.cssKeyLimit)
        XCTAssertEqual(DesignModePickPayload.cssKeyLimit, 64)
    }

    func testComposedTextIsByteBoundedOnACharacterBoundary() {
        let capped = DesignModeTextComposer.capped(String(repeating: "é", count: 20_000))
        XCTAssertLessThanOrEqual(capped.utf8.count, 16_384)
        XCTAssertTrue(capped.hasSuffix(DesignModePickPayload.truncationMarker))
        XCTAssertNotNil(String(data: Data(capped.utf8), encoding: .utf8))
    }
}

// MARK: - SHEL-15: notification reorder keeps children under their parent

@MainActor
final class NotificationReorderHierarchyTests: XCTestCase {
    private func makeManager() -> (TabManager, Workspace, Workspace, Workspace) {
        let manager = TabManager()
        let a = manager.tabs[0]
        let b = manager.addWorkspace()
        let c = manager.addWorkspace()
        manager.tabs = [a, b, c]
        return (manager, a, b, c)
    }

    func testChildStaysDirectlyAfterItsParentWhenItNotifies() {
        let (manager, a, b, c) = makeManager()
        c.agentParentWorkspaceId = a.id
        manager.canonicalizeHierarchyOrderIfNeeded()
        XCTAssertEqual(manager.tabs.map(\.id), [a.id, c.id, b.id])

        manager.moveTabToTopForNotification(c.id)
        XCTAssertEqual(manager.tabs.map(\.id), [a.id, c.id, b.id], "A child must not leave its parent")
    }

    func testNotifyingChildMovesItsWholeGroupToTop() {
        let (manager, a, b, c) = makeManager()
        c.agentParentWorkspaceId = b.id
        manager.canonicalizeHierarchyOrderIfNeeded()

        manager.moveTabToTopForNotification(c.id)
        XCTAssertEqual(manager.tabs.map(\.id), [b.id, c.id, a.id])
    }
}
