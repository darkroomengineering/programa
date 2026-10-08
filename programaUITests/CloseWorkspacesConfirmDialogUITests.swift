import XCTest
import Foundation

final class CloseWorkspacesConfirmDialogUITests: XCTestCase {
    private var countPath = ""

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        countPath = "/tmp/programa-ui-test-close-workspaces-\(UUID().uuidString).json"
        try? FileManager.default.removeItem(atPath: countPath)
    }

    func testCommandPaletteCloseOtherWorkspacesShowsSingleSummaryDialog() {
        let app = XCUIApplication()
        configureLaunch(app)
        app.launchEnvironment["PROGRAMA_UI_TEST_FORCE_CONFIRM_CLOSE_WORKSPACE"] = "1"
        app.launch()
        XCTAssertTrue(
            ensureForegroundAfterLaunch(app, timeout: 12.0),
            "Expected app to launch for close-workspaces confirmation test. state=\(app.state.rawValue)"
        )
        XCTAssertTrue(waitForWorkspaceCount(1, timeout: 12.0), "Expected initial workspace. count=\(workspaceCount())")

        app.typeKey("n", modifierFlags: [.command])
        XCTAssertTrue(waitForWorkspaceCount(2, timeout: 5.0), "Expected 2 workspaces. count=\(workspaceCount())")
        app.typeKey("n", modifierFlags: [.command])
        XCTAssertTrue(
            waitForWorkspaceCount(3, timeout: 5.0),
            "Expected 3 workspaces before running the close-other-workspaces command. count=\(workspaceCount())"
        )
        app.typeKey("2", modifierFlags: [.command])

        app.typeKey("p", modifierFlags: [.command, .shift])

        let searchField = app.textFields["CommandPaletteSearchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5.0), "Expected command palette search field")
        searchField.click()
        searchField.typeText("Close Other Workspaces")

        let resultButton = app.buttons["Close Other Workspaces"].firstMatch
        if resultButton.waitForExistence(timeout: 5.0) {
            resultButton.click()
        } else {
            app.typeKey(.return, modifierFlags: [])
        }

        XCTAssertTrue(
            waitForCloseWorkspacesAlert(app: app, timeout: 5.0),
            "Expected a single aggregated close-workspaces alert"
        )

        clickCancelOnCloseWorkspacesAlert(app: app)

        XCTAssertFalse(
            isCloseWorkspacesAlertPresent(app: app),
            "Expected aggregated close-workspaces alert to dismiss after clicking Cancel"
        )
        XCTAssertTrue(
            waitForWorkspaceCount(3, timeout: 5.0),
            "Expected all workspaces to remain after cancelling multi-close. count=\(workspaceCount())"
        )
    }

    func testCmdShiftWUsesSidebarMultiSelectionSummaryDialog() {
        let app = XCUIApplication()
        configureLaunch(app)
        app.launchEnvironment["PROGRAMA_UI_TEST_FORCE_CONFIRM_CLOSE_WORKSPACE"] = "1"
        // Applied by the app once the third workspace exists, so later Cmd+N presses cannot reset it.
        app.launchEnvironment["PROGRAMA_UI_TEST_SIDEBAR_SELECTED_WORKSPACE_INDICES"] = "1,2"
        app.launch()
        XCTAssertTrue(
            ensureForegroundAfterLaunch(app, timeout: 12.0),
            "Expected app to launch for close-workspaces shortcut test. state=\(app.state.rawValue)"
        )
        XCTAssertTrue(waitForWorkspaceCount(1, timeout: 12.0), "Expected initial workspace. count=\(workspaceCount())")

        // Three workspaces so the two selected ones are not all of them; closing every
        // workspace shows the "Close window?" alert instead.
        app.typeKey("n", modifierFlags: [.command])
        XCTAssertTrue(waitForWorkspaceCount(2, timeout: 5.0), "Expected 2 workspaces. count=\(workspaceCount())")
        app.typeKey("n", modifierFlags: [.command])
        XCTAssertTrue(
            waitForWorkspaceCount(3, timeout: 5.0),
            "Expected 3 workspaces before running Cmd+Shift+W. count=\(workspaceCount())"
        )

        app.typeKey("w", modifierFlags: [.command, .shift])

        XCTAssertTrue(
            waitForCloseWorkspacesAlert(app: app, timeout: 5.0),
            "Expected Cmd+Shift+W to use the aggregated close-workspaces alert for sidebar multi-selection"
        )

        clickCancelOnCloseWorkspacesAlert(app: app)

        XCTAssertFalse(
            isCloseWorkspacesAlertPresent(app: app),
            "Expected aggregated close-workspaces alert to dismiss after clicking Cancel"
        )
        XCTAssertTrue(
            waitForWorkspaceCount(3, timeout: 5.0),
            "Expected all workspaces to remain after cancelling Cmd+Shift+W multi-close. count=\(workspaceCount())"
        )
    }

    private func configureLaunch(_ app: XCUIApplication) {
        app.launchEnvironment["PROGRAMA_UI_TEST_MODE"] = "1"
        app.launchEnvironment["PROGRAMA_UI_TEST_KEYEQUIV_PATH"] = countPath
    }

    private func ensureForegroundAfterLaunch(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
        if app.wait(for: .runningForeground, timeout: timeout) {
            return true
        }
        if app.state == .runningBackground {
            app.activate()
            return app.wait(for: .runningForeground, timeout: 6.0)
        }
        return false
    }

    private func waitForWorkspaceCount(_ expectedCount: Int, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                self.workspaceCount() == expectedCount
            },
            object: NSObject()
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Reads the workspace count the app records to `PROGRAMA_UI_TEST_KEYEQUIV_PATH`; -1 if unavailable.
    private func workspaceCount() -> Int {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: countPath)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let raw = object["workspaceCount"], let count = Int(raw) else { return -1 }
        return count
    }

    private func isCloseWorkspacesAlertPresent(app: XCUIApplication) -> Bool {
        if closeWorkspacesDialog(app: app).exists { return true }
        if closeWorkspacesAlert(app: app).exists { return true }
        return app.staticTexts["Close workspaces?"].exists
    }

    private func waitForCloseWorkspacesAlert(app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                self.isCloseWorkspacesAlertPresent(app: app)
            },
            object: NSObject()
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func clickCancelOnCloseWorkspacesAlert(app: XCUIApplication) {
        let dialog = closeWorkspacesDialog(app: app)
        if dialog.exists {
            dialog.buttons["Cancel"].firstMatch.click()
            return
        }
        let alert = closeWorkspacesAlert(app: app)
        if alert.exists {
            alert.buttons["Cancel"].firstMatch.click()
            return
        }
        let anyDialog = app.dialogs.firstMatch
        if anyDialog.exists, anyDialog.buttons["Cancel"].exists {
            anyDialog.buttons["Cancel"].firstMatch.click()
        }
    }

    private func closeWorkspacesDialog(app: XCUIApplication) -> XCUIElement {
        app.dialogs.containing(.staticText, identifier: "Close workspaces?").firstMatch
    }

    private func closeWorkspacesAlert(app: XCUIApplication) -> XCUIElement {
        app.alerts.containing(.staticText, identifier: "Close workspaces?").firstMatch
    }
}
