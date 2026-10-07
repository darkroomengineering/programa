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



// MARK: - SHEL-12: design mode payload bounds


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

    func testMoveDownCarriesChildrenPastTheNextSibling() {
        let (manager, a, b, c) = makeManager()
        c.agentParentWorkspaceId = a.id
        manager.canonicalizeHierarchyOrderIfNeeded()

        XCTAssertTrue(manager.moveWorkspaceAmongSiblings(tabId: a.id, by: 1))
        XCTAssertEqual(manager.tabs.map(\.id), [b.id, a.id, c.id], "Move Down must not be undone by the hierarchy order")

        XCTAssertTrue(manager.moveWorkspaceAmongSiblings(tabId: a.id, by: -1))
        XCTAssertEqual(manager.tabs.map(\.id), [a.id, c.id, b.id])
    }

    func testOnlyChildCannotMoveOutOfItsParent() {
        let (manager, a, b, c) = makeManager()
        c.agentParentWorkspaceId = a.id
        manager.canonicalizeHierarchyOrderIfNeeded()

        XCTAssertFalse(manager.moveWorkspaceAmongSiblings(tabId: c.id, by: -1))
        XCTAssertFalse(manager.moveWorkspaceAmongSiblings(tabId: c.id, by: 1))
        XCTAssertEqual(manager.tabs.map(\.id), [a.id, c.id, b.id])
    }
}
