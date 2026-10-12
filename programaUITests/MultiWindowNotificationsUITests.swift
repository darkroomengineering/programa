import XCTest
import AppKit
import Foundation
import CoreGraphics

final class MultiWindowNotificationsUITests: XCTestCase {
    private var dataPath = ""
    private var socketPath = ""
    private var launchTag = ""
    private let programaBundleIdentifier = "com.darkroom.programa.debug"
    private var launchedApplication: XCUIApplication?

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        dataPath = "/tmp/programa-ui-test-multi-window-notifs-\(UUID().uuidString).json"
        socketPath = "/tmp/programa-ui-test-socket-\(UUID().uuidString).sock"
        launchTag = "ui-tests-multi-window-notifs-\(UUID().uuidString.prefix(8))"
        try? FileManager.default.removeItem(atPath: dataPath)
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    override func tearDown() {
        launchedApplication?.terminate()
        launchedApplication = nil
        try? FileManager.default.removeItem(atPath: dataPath)
        try? FileManager.default.removeItem(atPath: socketPath)
        super.tearDown()
    }

    private func makeTrackedApplication() -> XCUIApplication {
        let application = XCUIApplication()
        launchedApplication = application
        return application
    }

    func testNotificationsRouteToCorrectWindow() {
        let app = makeTrackedApplication()
        app.launchEnvironment["PROGRAMA_UI_TEST_MULTI_WINDOW_NOTIF_SETUP"] = "1"
        app.launchEnvironment["PROGRAMA_UI_TEST_MULTI_WINDOW_NOTIF_PATH"] = dataPath
        app.launchEnvironment["PROGRAMA_TAG"] = launchTag
        app.launch()
        XCTAssertTrue(
            ensureForegroundAfterLaunch(app, timeout: 12.0),
            "Expected app to launch for multi-window routing test. state=\(app.state.rawValue)"
        )

        XCTAssertTrue(
            waitForData(keys: [
                "window1Id",
                "window2Id",
                "window2InitialSidebarSelection",
                "tabId1",
                "tabId2",
                "notifId1",
                "notifId2",
                "expectedLatestWindowId",
                "expectedLatestTabId",
            ], timeout: 15.0),
            "Expected multi-window notification setup data"
        )

        guard let setup = loadData() else {
            XCTFail("Missing setup data")
            return
        }

        let expectedLatestWindowId = setup["expectedLatestWindowId"] ?? ""
        let expectedLatestTabId = setup["expectedLatestTabId"] ?? ""
        let window2Id = setup["window2Id"] ?? ""
        let window2InitialSidebarSelection = setup["window2InitialSidebarSelection"] ?? ""
        let tabId2 = setup["tabId2"] ?? ""
        let notifId2 = setup["notifId2"] ?? ""

        XCTAssertFalse(expectedLatestWindowId.isEmpty)
        XCTAssertFalse(expectedLatestTabId.isEmpty)
        XCTAssertFalse(window2Id.isEmpty)
        XCTAssertEqual(window2InitialSidebarSelection, "notifications")
        XCTAssertFalse(tabId2.isEmpty)
        XCTAssertFalse(notifId2.isEmpty)

        // Sanity: ensure the second window was actually created.
        XCTAssertTrue(waitForWindowCount(atLeast: 2, app: app, timeout: 6.0))

        // Jump to latest unread (Cmd+Shift+U). This should bring the owning window forward.
        let beforeToken = loadData()?["focusToken"]
        app.typeKey("u", modifierFlags: [.command, .shift])

        XCTAssertTrue(
            waitForFocusChange(from: beforeToken, timeout: 6.0),
            "Expected focus record after jump-to-unread"
        )
        guard let afterJump = loadData() else {
            XCTFail("Missing focus data after jump")
            return
        }
        XCTAssertEqual(afterJump["focusedWindowId"], expectedLatestWindowId)
        XCTAssertEqual(afterJump["focusedTabId"], expectedLatestTabId)

        // Open the notifications popover (Cmd+I) and click the notification belonging to window 2.
        let beforeClickToken = afterJump["focusToken"]
        app.typeKey("i", modifierFlags: [.command])

        let targetButton = app.buttons["NotificationPopoverRow.\(notifId2)"]
        XCTAssertTrue(targetButton.waitForExistence(timeout: 6.0), "Expected notification row button to exist")
        XCTAssertTrue(
            clickNotificationPopoverRowAndWaitForFocusChange(
                button: targetButton,
                app: app,
                from: beforeClickToken,
                timeout: 6.0
            ),
            "Expected focus record after clicking notification"
        )
        guard let afterClick = loadData() else {
            XCTFail("Missing focus data after click")
            return
        }
        XCTAssertEqual(afterClick["focusedWindowId"], window2Id)
        XCTAssertEqual(afterClick["focusedTabId"], tabId2)
        XCTAssertEqual(afterClick["focusedSidebarSelection"], "tabs")
    }

    func testNotificationsPopoverCanCloseViaShortcutAndEscape() {
        let app = makeTrackedApplication()
        app.launchEnvironment["PROGRAMA_UI_TEST_MULTI_WINDOW_NOTIF_SETUP"] = "1"
        app.launchEnvironment["PROGRAMA_UI_TEST_MULTI_WINDOW_NOTIF_PATH"] = dataPath
        app.launchEnvironment["PROGRAMA_TAG"] = launchTag
        app.launch()
        XCTAssertTrue(
            ensureForegroundAfterLaunch(app, timeout: 12.0),
            "Expected app to launch for notifications popover shortcut test. state=\(app.state.rawValue)"
        )

        XCTAssertTrue(
            waitForData(keys: ["notifId1"], timeout: 15.0),
            "Expected multi-window notification setup data"
        )

        guard let notifId1 = loadData()?["notifId1"], !notifId1.isEmpty else {
            XCTFail("Missing setup notification id")
            return
        }

        XCTAssertTrue(waitForWindowCount(atLeast: 1, app: app, timeout: 6.0))

        app.typeKey("i", modifierFlags: [.command])
        let targetButton = app.buttons["NotificationPopoverRow.\(notifId1)"]
        XCTAssertTrue(targetButton.waitForExistence(timeout: 6.0), "Expected popover to open on Show Notifications shortcut")

        app.typeKey("i", modifierFlags: [.command])
        XCTAssertTrue(waitForElementToDisappear(targetButton, timeout: 3.0), "Expected popover to close on repeated Show Notifications shortcut")

        app.typeKey("i", modifierFlags: [.command])
        XCTAssertTrue(targetButton.waitForExistence(timeout: 6.0), "Expected popover to reopen on Show Notifications shortcut")

        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(waitForElementToDisappear(targetButton, timeout: 3.0), "Expected popover to close on Escape")
    }

    func testNotificationsPopoverJumpToLatestButtonShowsShortcut() {
        let app = makeTrackedApplication()
        app.launchEnvironment["PROGRAMA_UI_TEST_MULTI_WINDOW_NOTIF_SETUP"] = "1"
        app.launchEnvironment["PROGRAMA_UI_TEST_MULTI_WINDOW_NOTIF_PATH"] = dataPath
        app.launchEnvironment["PROGRAMA_TAG"] = launchTag
        app.launch()
        XCTAssertTrue(
            ensureForegroundAfterLaunch(app, timeout: 12.0),
            "Expected app to launch for jump-to-latest popover test. state=\(app.state.rawValue)"
        )

        XCTAssertTrue(waitForData(keys: ["notifId1"], timeout: 15.0), "Expected multi-window notification setup data")
        XCTAssertTrue(waitForWindowCount(atLeast: 1, app: app, timeout: 6.0))

        app.typeKey("i", modifierFlags: [.command])

        let jumpButton = app.buttons["notificationsPopover.jumpToLatest"]
        XCTAssertTrue(jumpButton.waitForExistence(timeout: 6.0), "Expected Jump to Latest button in notifications popover")
        let shortcutValue = jumpButton.value as? String
        XCTAssertNotNil(shortcutValue, "Expected Jump to Latest shortcut badge")
        XCTAssertTrue(shortcutValue?.contains("⌘") == true, "Expected Jump to Latest shortcut to include Command")
        XCTAssertTrue(shortcutValue?.contains("⇧") == true, "Expected Jump to Latest shortcut to include Shift")
        XCTAssertTrue(shortcutValue?.uppercased().contains("U") == true, "Expected Jump to Latest shortcut to include U")
    }

    func testEmptyNotificationsPopoverBlocksTerminalTyping() throws {
        let app = makeTrackedApplication()
        // The app records the focused terminal's text here when the popover closes.
        app.launchEnvironment["PROGRAMA_UI_TEST_KEYEQUIV_PATH"] = dataPath
        app.launchEnvironment["PROGRAMA_TAG"] = launchTag
        app.launch()
        XCTAssertTrue(
            ensureForegroundAfterLaunch(app, timeout: 12.0),
            "Expected app to launch for empty popover blocking test. state=\(app.state.rawValue)"
        )

        XCTAssertTrue(waitForWindowCount(atLeast: 1, app: app, timeout: 8.0))

        app.typeKey("i", modifierFlags: [.command])
        XCTAssertTrue(app.staticTexts["No notifications yet"].waitForExistence(timeout: 6.0), "Expected empty notifications popover state")
        let jumpButton = app.buttons["notificationsPopover.jumpToLatest"]
        XCTAssertTrue(jumpButton.waitForExistence(timeout: 2.0), "Expected Jump to Latest button in empty notifications popover")
        XCTAssertFalse(jumpButton.isEnabled, "Expected Jump to Latest button to be disabled with no notifications")
        let clearAllButton = app.buttons["notificationsPopover.clearAll"]
        XCTAssertTrue(clearAllButton.waitForExistence(timeout: 2.0), "Expected Clear All button in empty notifications popover")
        XCTAssertFalse(clearAllButton.isEnabled, "Expected Clear All button to be disabled with no notifications")

        let marker = "programa_notif_block_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8))"
        app.typeText(marker)
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))

        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(
            waitForData(keys: ["terminalTextAtNotificationsPopoverClose"], timeout: 3.0),
            "Expected the terminal text recorded when the popover closed"
        )
        let after = loadData()?["terminalTextAtNotificationsPopoverClose"] ?? ""
        XCTAssertFalse(after.isEmpty, "Expected a terminal text snapshot, got an empty one")
        XCTAssertFalse(after.contains(marker), "Expected typing to be blocked while empty notifications popover is open")
    }

    func testNotifyCLIDoesNotStealFocusAcrossWindows() throws {
        let app = makeTrackedApplication()
        app.launchArguments += ["-socketControlMode", "allowAll"]
        app.launchEnvironment["PROGRAMA_UI_TEST_MULTI_WINDOW_NOTIF_SETUP"] = "1"
        app.launchEnvironment["PROGRAMA_UI_TEST_MULTI_WINDOW_NOTIF_PATH"] = dataPath
        app.launchEnvironment["PROGRAMA_SOCKET_PATH"] = socketPath
        app.launchEnvironment["PROGRAMA_SOCKET_MODE"] = "allowAll"
        app.launchEnvironment["PROGRAMA_SOCKET_ENABLE"] = "1"
        app.launchEnvironment["PROGRAMA_UI_TEST_SOCKET_SANITY"] = "1"
        app.launchEnvironment["PROGRAMA_UI_TEST_NOTIFY_SOURCE_TERMINAL_READY"] = "1"
        app.launchEnvironment["PROGRAMA_TAG"] = launchTag
        app.launch()
        XCTAssertTrue(
            ensureForegroundAfterLaunch(app, timeout: 12.0),
            "Expected app to launch for notify focus regression test. state=\(app.state.rawValue)"
        )
        XCTAssertTrue(
            waitForDataMatch(timeout: 20.0) { data in
                let tabId2 = data["tabId2"] ?? ""
                let surfaceId2 = data["surfaceId2"] ?? ""
                let socketReady = data["socketReady"] ?? ""
                let sourceTerminalReady = data["sourceTerminalReady"] ?? ""
                return !tabId2.isEmpty &&
                    !surfaceId2.isEmpty &&
                    !socketReady.isEmpty &&
                    socketReady != "pending" &&
                    !sourceTerminalReady.isEmpty &&
                    sourceTerminalReady != "pending"
            },
            "Expected multi-window notification setup data, socket readiness, and source terminal focus. " +
            "data=\(loadData().map { $0.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ") } ?? "<missing>")"
        )

        guard let setup = loadData() else {
            XCTFail("Missing setup data")
            return
        }
        guard let tabId2 = setup["tabId2"], !tabId2.isEmpty else {
            XCTFail("Missing setup workspace id")
            return
        }
        if let expectedSocketPath = setup["socketExpectedPath"], !expectedSocketPath.isEmpty {
            socketPath = expectedSocketPath
        }
        if setup["socketReady"] != "1" {
            XCTFail(
                "Control socket unavailable in this test environment. expected=\(socketPath) " +
                socketDiagnostics(from: setup)
            )
            return
        }
        guard setup["socketPingResponse"] == "PONG" else {
            XCTFail(
                "Control socket ping sanity check failed. path=\(socketPath) " +
                socketDiagnostics(from: setup)
            )
            return
        }
        guard let surfaceId = setup["surfaceId2"], !surfaceId.isEmpty else {
            XCTFail("Missing target surface id for workspace \(tabId2)")
            return
        }
        guard setup["sourceTerminalReady"] == "1" else {
            XCTFail(
                "Expected source terminal to be focused before typing. " +
                "failure=\(setup["sourceTerminalFocusFailure"] ?? "<unknown>")"
            )
            return
        }

        XCTAssertTrue(waitForWindowCount(atLeast: 2, app: app, timeout: 6.0))

        let title = "focus-regression-\(UUID().uuidString.prefix(8))"
        let commandResultStem = UUID().uuidString
        let commandStatusPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("programa-ui-test-notify-\(commandResultStem).status")
            .path
        let commandStdoutPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("programa-ui-test-notify-\(commandResultStem).stdout")
            .path
        let commandStderrPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("programa-ui-test-notify-\(commandResultStem).stderr")
            .path
        let commandScriptPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("programa-ui-test-notify-\(commandResultStem).sh")
            .path
        defer {
            try? FileManager.default.removeItem(atPath: commandStatusPath)
            try? FileManager.default.removeItem(atPath: commandStdoutPath)
            try? FileManager.default.removeItem(atPath: commandStderrPath)
            try? FileManager.default.removeItem(atPath: commandScriptPath)
        }

        guard let bundledCLIPath = resolveProgramaCLIPaths().first else {
            XCTFail("Failed to locate bundled programa CLI for notify regression test")
            return
        }

        let notifyScript = [
            "#!/bin/sh",
            "sleep 1",
            "rm -f \(shellSingleQuote(commandStatusPath)) \(shellSingleQuote(commandStdoutPath)) \(shellSingleQuote(commandStderrPath))",
            "\(shellSingleQuote(bundledCLIPath)) --socket \(shellSingleQuote(socketPath)) notify --workspace \(shellSingleQuote(tabId2)) --surface \(shellSingleQuote(surfaceId)) --title \(shellSingleQuote(title)) --subtitle \(shellSingleQuote("ui-test")) --body \(shellSingleQuote("focus-regression")) >\(shellSingleQuote(commandStdoutPath)) 2>\(shellSingleQuote(commandStderrPath))",
            "printf '%s' $? >\(shellSingleQuote(commandStatusPath))"
        ].joined(separator: "\n")
        do {
            try notifyScript.write(toFile: commandScriptPath, atomically: true, encoding: .utf8)
        } catch {
            XCTFail(
                "Failed to write delayed bundled `programa notify` script. " +
                "path=\(commandScriptPath) error=\(error)"
            )
            return
        }

        app.typeText("sh \(commandScriptPath)")
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])

        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        finder.activate()
        XCTAssertTrue(
            waitForAppToLeaveForeground(app, timeout: 8.0),
            "Expected programa to move to background before delayed notify command runs. state=\(app.state.rawValue)"
        )

        XCTAssertTrue(
            waitForCommandCompletionWhileBackgrounded(
                statusPath: commandStatusPath,
                app: app,
                timeout: 15.0
            ),
            "Expected delayed bundled `programa notify` command to finish without foregrounding programa. state=\(app.state.rawValue) frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil")"
        )

        let notifyExitStatus = readTrimmedFile(atPath: commandStatusPath) ?? "<missing>"
        let notifyStdout = readTrimmedFile(atPath: commandStdoutPath) ?? ""
        let notifyStderr = readTrimmedFile(atPath: commandStderrPath) ?? ""

        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertFalse(
            isAppFrontmost(app),
            "Expected programa to remain in background after bundled `programa notify`. state=\(app.state.rawValue) frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil") stderr=\(notifyStderr)"
        )
        guard notifyExitStatus == "0" else {
            XCTFail(
                "Expected bundled `programa notify` launched from the in-app shell to succeed. " +
                "status=\(notifyExitStatus) stdout=\(notifyStdout) stderr=\(notifyStderr)"
            )
            return
        }
        XCTAssertTrue(notifyStdout.contains("OK"), "Expected notify command to return OK. stdout=\(notifyStdout) stderr=\(notifyStderr)")
    }

    private func clickNotificationPopoverRowAndWaitForFocusChange(
        button: XCUIElement,
        app: XCUIApplication,
        from token: String?,
        timeout: TimeInterval
    ) -> Bool {
        // `.click()` on a button inside an NSPopover can be flaky on the VM; prefer a coordinate click
        // within the left side of the row (away from the clear button).
        if button.exists {
            let coord = button.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5))
            coord.click()
        } else {
            button.click()
        }

        // If the coordinate click was swallowed (popover auto-dismiss, etc), retry with a normal click.
        let firstDeadline = min(1.0, timeout)
        if waitForFocusChange(from: token, timeout: firstDeadline) {
            return true
        }
        // A click that landed closes the popover before the focus record is written, so only
        // retry while the row is still there.
        if button.exists {
            button.click()
        }
        return waitForFocusChange(from: token, timeout: max(0.0, timeout - firstDeadline))
    }

    private func waitForWindowCount(atLeast count: Int, app: XCUIApplication, timeout: TimeInterval) -> Bool {
        waitForCondition(timeout: timeout) {
            app.windows.count >= count
        }
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

    private func waitForElementToDisappear(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForFocusChange(from token: String?, timeout: TimeInterval) -> Bool {
        waitForCondition(timeout: timeout) {
            guard let data = self.loadData(),
                  let current = data["focusToken"],
                  !current.isEmpty else {
                return false
            }
            return current != token
        }
    }

    private func waitForData(keys: [String], timeout: TimeInterval) -> Bool {
        waitForCondition(timeout: timeout) {
            guard let data = self.loadData() else { return false }
            return keys.allSatisfy { (data[$0] ?? "").isEmpty == false }
        }
    }

    private func waitForDataMatch(timeout: TimeInterval, predicate: @escaping ([String: String]) -> Bool) -> Bool {
        waitForCondition(timeout: timeout) {
            guard let data = self.loadData() else { return false }
            return predicate(data)
        }
    }

    /// Whether the app under test is the frontmost (active) application according to the
    /// workspace. `XCUIApplication.state` can report `.runningForeground` for an instant on the
    /// CI virtual display while the app itself never receives `applicationDidBecomeActive`;
    /// the workspace's frontmost application is the same signal the app observes.
    private func isAppFrontmost(_ app: XCUIApplication) -> Bool {
        guard let frontmost = NSWorkspace.shared.frontmostApplication else {
            return app.state == .runningForeground
        }
        return frontmost.bundleIdentifier == programaBundleIdentifier
    }

    private func waitForCommandCompletionWhileBackgrounded(
        statusPath: String,
        app: XCUIApplication,
        timeout: TimeInterval
    ) -> Bool {
        var sawCompletion = false
        var sawForeground = false
        let completed = waitForCondition(timeout: timeout) {
            if self.isAppFrontmost(app) {
                sawForeground = true
                return false
            }
            if FileManager.default.fileExists(atPath: statusPath) {
                sawCompletion = true
                return true
            }
            return false
        }
        guard !sawForeground else { return false }
        guard completed || sawCompletion || FileManager.default.fileExists(atPath: statusPath) else {
            return false
        }

        // Sample for a short window after completion instead of a single poll.
        let deadline = Date().addingTimeInterval(0.75)
        while Date() < deadline {
            if isAppFrontmost(app) { return false }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return true
    }

    private func waitForAppToLeaveForeground(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
        waitForCondition(timeout: timeout) {
            !self.isAppFrontmost(app)
        }
    }

    private func waitForCondition(timeout: TimeInterval, predicate: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in predicate() },
            object: nil
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func socketDiagnostics(from data: [String: String]) -> String {
        let pingResponse = data["socketPingResponse"].flatMap { $0.isEmpty ? nil : $0 } ?? "<nil>"
        return "mode=\(data["socketMode"] ?? "") running=\(data["socketIsRunning"] ?? "") " +
            "acceptLoopAlive=\(data["socketAcceptLoopAlive"] ?? "") pathMatches=\(data["socketPathMatches"] ?? "") " +
            "pathExists=\(data["socketPathExists"] ?? "") ping=\(pingResponse) " +
            "signals=\(data["socketFailureSignals"] ?? "")"
    }

    private func resolveProgramaCLIPaths() -> [String] {
        let fileManager = FileManager.default
        let env = ProcessInfo.processInfo.environment
        var candidates: [String] = []
        var productDirectories: [String] = []

        if let builtProductsDir = env["BUILT_PRODUCTS_DIR"], !builtProductsDir.isEmpty {
            productDirectories.append(builtProductsDir)
        }

        if let hostPath = env["TEST_HOST"], !hostPath.isEmpty {
            let hostURL = URL(fileURLWithPath: hostPath)
            let productsDir = hostURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .path
            productDirectories.append(productsDir)
        }

        productDirectories.append(contentsOf: inferredBuildProductsDirectories())
        for productsDir in uniquePaths(productDirectories) {
            appendCLIPathCandidates(fromProductsDirectory: productsDir, to: &candidates)
        }

        candidates.append("/tmp/programa-\(launchTag)/Build/Products/Debug/Programa DEV.app/Contents/Resources/bin/programa")
        candidates.append("/tmp/programa-\(launchTag)/Build/Products/Debug/Programa.app/Contents/Resources/bin/programa")

        var resolvedPaths: [String] = []
        for path in uniquePaths(candidates) {
            guard fileManager.isExecutableFile(atPath: path) else { continue }
            resolvedPaths.append(URL(fileURLWithPath: path).resolvingSymlinksInPath().path)
        }
        return uniquePaths(resolvedPaths)
    }

    private func inferredBuildProductsDirectories() -> [String] {
        let bundleURLs = [
            Bundle.main.bundleURL,
            Bundle(for: Self.self).bundleURL,
        ]

        return bundleURLs.compactMap { bundleURL in
            let standardizedPath = bundleURL.standardizedFileURL.path
            let components = standardizedPath.split(separator: "/")
            guard let productsIndex = components.firstIndex(of: "Products"),
                  productsIndex + 1 < components.count else {
                return nil
            }
            let prefixComponents = components.prefix(productsIndex + 2)
            return "/" + prefixComponents.joined(separator: "/")
        }
    }

    private func appendCLIPathCandidates(
        fromProductsDirectory productsDir: String,
        to candidates: inout [String]
    ) {
        candidates.append("\(productsDir)/Programa DEV.app/Contents/Resources/bin/programa")
        candidates.append("\(productsDir)/Programa.app/Contents/Resources/bin/programa")

        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: productsDir) else {
            return
        }

        for entry in entries.sorted() where entry.hasSuffix(".app") {
            let cliPath = URL(fileURLWithPath: productsDir)
                .appendingPathComponent(entry)
                .appendingPathComponent("Contents/Resources/bin/programa")
                .path
            candidates.append(cliPath)
        }
    }

    private func uniquePaths(_ paths: [String]) -> [String] {
        var unique: [String] = []
        var seen = Set<String>()
        for path in paths {
            if seen.insert(path).inserted {
                unique.append(path)
            }
        }
        return unique
    }

    private func shellSingleQuote(_ value: String) -> String {
        if value.isEmpty { return "''" }
        return "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private func readTrimmedFile(atPath path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func loadData() -> [String: String]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: dataPath)) else {
            return nil
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: String]
    }
}
