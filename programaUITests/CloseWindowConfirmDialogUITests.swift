import XCTest

final class CloseWindowConfirmDialogUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testCloseShortcutPreservesRunningShellOnReopen() throws {
        try assertRunningShellSurvivesClose(useNativeButton: false)
    }

    func testNativeCloseButtonPreservesRunningShellOnReopen() throws {
        try assertRunningShellSurvivesClose(useNativeButton: true)
    }

    private func assertRunningShellSurvivesClose(useNativeButton: Bool) throws {
        let token = UUID().uuidString
        let before = URL(fileURLWithPath: "/tmp/programa-close-before-\(token)")
        let after = URL(fileURLWithPath: "/tmp/programa-close-after-\(token)")
        defer {
            try? FileManager.default.removeItem(at: before)
            try? FileManager.default.removeItem(at: after)
        }
        let app = XCUIApplication()
        app.launchEnvironment["PROGRAMA_TAG"] = "ui-tests-close-\(token.lowercased())"
        app.launch()
        if !app.wait(for: .runningForeground, timeout: 12) { app.activate() }
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 6))
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))

        // A fresh shell displaying old output cannot preserve both its process
        // identity and this shell-local variable.
        app.typeText("PROGRAMA_REOPEN_TOKEN=\(token); printf '%s\\n%s\\n' \"$$\" \"$PROGRAMA_REOPEN_TOKEN\" > '\(before.path)'")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitUntil { self.shellRecord(at: before)?.contains(token) == true })
        let expected = try XCTUnwrap(shellRecord(at: before))

        if useNativeButton {
            app.windows.firstMatch.buttons[XCUIIdentifierCloseWindow].click()
        } else {
            app.typeKey("w", modifierFlags: [.command, .control])
        }
        XCTAssertTrue(waitUntil { app.windows.count == 0 }, "Closing should hide the window without a confirmation dialog")
        XCTAssertFalse(app.staticTexts["Close window?"].exists)
        XCTAssertNotEqual(app.state, .notRunning, "Closing a window must keep its sessions running")

        app.typeKey("n", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(app.windows.count, 1, "New Window should reopen the preserved window")
        app.typeText("printf '%s\\n%s\\n' \"$$\" \"$PROGRAMA_REOPEN_TOKEN\" > '\(after.path)'")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitUntil { self.shellRecord(at: after) != nil })
        XCTAssertEqual(try XCTUnwrap(shellRecord(at: after)), expected, "Reopen must preserve the running shell, not just its text")

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Reopened preserved terminal"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func shellRecord(at url: URL) -> String? {
        guard let value = try? String(contentsOf: url, encoding: .utf8),
              value.split(separator: "\n", omittingEmptySubsequences: false).count >= 3 else { return nil }
        return value
    }

    private func waitUntil(_ condition: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in condition() }, object: NSObject()
        )
        return XCTWaiter().wait(for: [expectation], timeout: 10) == .completed
    }
}
