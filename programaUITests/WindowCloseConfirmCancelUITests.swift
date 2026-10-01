import XCTest

/// SHEL-03: closing a window that has a running process asks exactly once, and Cancel keeps the window.
/// Covers the red close button and Ctrl+Cmd+W on the launch window and on a New Window window.
final class WindowCloseConfirmCancelUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testRedButtonCancelKeepsLaunchWindow() {
        let app = launchWithRunningProcess()
        closeAndCancel(app: app, window: app.windows.firstMatch, useNativeButton: true)
    }

    func testCloseShortcutCancelKeepsLaunchWindow() {
        let app = launchWithRunningProcess()
        closeAndCancel(app: app, window: app.windows.firstMatch, useNativeButton: false)
    }

    func testRedButtonCancelKeepsNewWindow() {
        let app = launchWithRunningProcess()
        let newWindow = openNewWindowWithRunningProcess(app: app)
        closeAndCancel(app: app, window: newWindow, useNativeButton: true)
    }

    func testCloseShortcutCancelKeepsNewWindow() {
        let app = launchWithRunningProcess()
        let newWindow = openNewWindowWithRunningProcess(app: app)
        closeAndCancel(app: app, window: newWindow, useNativeButton: false)
    }

    // MARK: - Helpers

    private func launchWithRunningProcess() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["PROGRAMA_TAG"] = "ui-tests-close-cancel-\(UUID().uuidString.prefix(8).lowercased())"
        app.launch()
        if !app.wait(for: .runningForeground, timeout: 12) { app.activate() }
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 6))
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        startSleep(app: app)
        return app
    }

    private func openNewWindowWithRunningProcess(app: XCUIApplication) -> XCUIElement {
        let before = app.windows.count
        app.typeKey("n", modifierFlags: [.command, .shift])
        XCTAssertTrue(waitUntil { app.windows.count == before + 1 }, "New Window should add a window")
        let newWindow = app.windows.firstMatch
        startSleep(app: app)
        return newWindow
    }

    private func startSleep(app: XCUIApplication) {
        app.typeText("sleep 100")
        app.typeKey(.return, modifierFlags: [])
        // Shell integration needs a moment to report the running command.
        Thread.sleep(forTimeInterval: 1.5)
    }

    private func closeAndCancel(app: XCUIApplication, window: XCUIElement, useNativeButton: Bool) {
        let windowCount = app.windows.count
        if useNativeButton {
            window.buttons[XCUIIdentifierCloseWindow].click()
        } else {
            app.typeKey("w", modifierFlags: [.command, .control])
        }

        let cancel = app.dialogs.buttons["Cancel"].exists ? app.dialogs.buttons["Cancel"] : app.sheets.buttons["Cancel"]
        let appeared = waitUntil { app.dialogs.buttons["Cancel"].exists || app.sheets.buttons["Cancel"].exists || app.alerts.buttons["Cancel"].exists }
        XCTAssertTrue(appeared, "Closing a window with a running process must ask for confirmation")
        XCTAssertEqual(app.staticTexts.matching(identifier: "Close window?").count, 1, "Exactly one dialog per close request")

        let target = cancel.exists ? cancel : app.alerts.buttons["Cancel"]
        target.firstMatch.click()

        XCTAssertTrue(waitUntil { !app.dialogs.buttons["Cancel"].exists && !app.sheets.buttons["Cancel"].exists && !app.alerts.buttons["Cancel"].exists })
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertEqual(app.windows.count, windowCount, "Cancel must keep the window")
        XCTAssertFalse(app.dialogs.buttons["Cancel"].exists, "Cancel must not re-prompt")

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Window kept after Cancel"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func waitUntil(_ condition: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in condition() }, object: NSObject()
        )
        return XCTWaiter().wait(for: [expectation], timeout: 10) == .completed
    }
}
