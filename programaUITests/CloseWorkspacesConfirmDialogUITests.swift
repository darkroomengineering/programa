import XCTest
import Foundation

final class CloseWorkspacesConfirmDialogUITests: XCTestCase {
    private var socketPath = ""

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        socketPath = "/tmp/programa-ui-test-close-workspaces-\(UUID().uuidString).sock"
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    func testCommandPaletteCloseOtherWorkspacesShowsSingleSummaryDialog() {
        let app = XCUIApplication()
        configureSocketControlledLaunch(app)
        app.launchEnvironment["PROGRAMA_UI_TEST_FORCE_CONFIRM_CLOSE_WORKSPACE"] = "1"
        app.launch()
        XCTAssertTrue(
            ensureForegroundAfterLaunch(app, timeout: 12.0),
            "Expected app to launch for close-workspaces confirmation test. state=\(app.state.rawValue)"
        )
        XCTAssertTrue(waitForSocketPong(timeout: 12.0), "Expected control socket to respond at \(socketPath)")

        XCTAssertNotNil(socketRequest("workspace.create"))
        XCTAssertNotNil(socketRequest("workspace.create"))
        XCTAssertTrue(
            waitForWorkspaceCount(3, timeout: 5.0),
            "Expected 3 workspaces before running the close-other-workspaces command. list=\(socketRequest("workspace.list").map { "\($0)" } ?? "<nil>")"
        )
        let secondWorkspaceId = (socketRequest("workspace.list")?["workspaces"] as? [[String: Any]])?
            .dropFirst().first?["id"] as? String
        XCTAssertNotNil(secondWorkspaceId, "Expected a second workspace to select")
        XCTAssertNotNil(socketRequest("workspace.select", params: ["workspace_id": secondWorkspaceId ?? ""]))

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
            "Expected all workspaces to remain after cancelling multi-close. list=\(socketRequest("workspace.list").map { "\($0)" } ?? "<nil>")"
        )
    }

    func testCmdShiftWUsesSidebarMultiSelectionSummaryDialog() {
        let app = XCUIApplication()
        configureSocketControlledLaunch(app)
        app.launchEnvironment["PROGRAMA_UI_TEST_FORCE_CONFIRM_CLOSE_WORKSPACE"] = "1"
        app.launchEnvironment["PROGRAMA_UI_TEST_SIDEBAR_SELECTED_WORKSPACE_INDICES"] = "0,1"
        app.launch()
        XCTAssertTrue(
            ensureForegroundAfterLaunch(app, timeout: 12.0),
            "Expected app to launch for close-workspaces shortcut test. state=\(app.state.rawValue)"
        )
        XCTAssertTrue(waitForSocketPong(timeout: 12.0), "Expected control socket to respond at \(socketPath)")

        XCTAssertNotNil(socketRequest("workspace.create"))
        XCTAssertTrue(
            waitForWorkspaceCount(2, timeout: 5.0),
            "Expected 2 workspaces before running Cmd+Shift+W. list=\(socketRequest("workspace.list").map { "\($0)" } ?? "<nil>")"
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
            waitForWorkspaceCount(2, timeout: 5.0),
            "Expected both workspaces to remain after cancelling Cmd+Shift+W multi-close. list=\(socketRequest("workspace.list").map { "\($0)" } ?? "<nil>")"
        )
    }

    private func configureSocketControlledLaunch(_ app: XCUIApplication) {
        app.launchArguments += ["-socketControlMode", "allowAll"]
        app.launchEnvironment["PROGRAMA_UI_TEST_MODE"] = "1"
        app.launchEnvironment["PROGRAMA_SOCKET_PATH"] = socketPath
        app.launchEnvironment["PROGRAMA_SOCKET_ENABLE"] = "1"
        app.launchEnvironment["PROGRAMA_SOCKET_MODE"] = "allowAll"
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

    private func waitForSocketPong(timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                self.socketRequest("system.ping") != nil
            },
            object: NSObject()
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
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

    private func workspaceCount() -> Int {
        guard let result = socketRequest("workspace.list"),
              let workspaces = result["workspaces"] as? [[String: Any]] else { return -1 }
        return workspaces.count
    }

    /// Sends one v2 JSON-RPC request line and returns `result` when the response has `ok: true`.
    private func socketRequest(_ method: String, params: [String: Any] = [:]) -> [String: Any]? {
        let nc = "/usr/bin/nc"
        guard FileManager.default.isExecutableFile(atPath: nc) else { return nil }
        let request: [String: Any] = ["id": 1, "method": method, "params": params]
        guard let body = try? JSONSerialization.data(withJSONObject: request) else { return nil }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: nc)
        proc.arguments = ["-U", socketPath, "-w", "2"]

        let inPipe = Pipe()
        let outPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = Pipe()

        do {
            try proc.run()
        } catch {
            return nil
        }

        inPipe.fileHandleForWriting.write(body + Data("\n".utf8))
        inPipe.fileHandleForWriting.closeFile()

        proc.waitUntilExit()

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        guard let response = (try? JSONSerialization.jsonObject(with: outData)) as? [String: Any],
              response["ok"] as? Bool == true else { return nil }
        return (response["result"] as? [String: Any]) ?? [:]
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
