import XCTest

final class SidebarResizeUITests: XCTestCase {
    private let minimumSidebarWidth: CGFloat = 238

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testSidebarDividerTracksCursor() {
        let app = launchedApp()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5.0))

        let divider = sidebarDivider(in: app)
        XCTAssertTrue(divider.waitForExistence(timeout: 5.0))
        XCTAssertTrue(waitForDividerGeometry(divider, timeout: 5.0), "Expected the sidebar divider to have usable geometry")

        let initialX = divider.frame.midX

        let start = dividerCoordinate(divider, in: window)
        let end = start.withOffset(CGVector(dx: 80, dy: 0))
        start.press(forDuration: 0.1, thenDragTo: end)

        let afterX = divider.frame.midX
        let rightDelta = afterX - initialX
        XCTAssertGreaterThanOrEqual(rightDelta, 40, "Expected drag-right to move the divider meaningfully")
        XCTAssertLessThanOrEqual(rightDelta, 82, "Divider moved farther than the requested drag-right offset")

        let startBack = dividerCoordinate(divider, in: window)
        let endBack = startBack.withOffset(CGVector(dx: -60, dy: 0))
        startBack.press(forDuration: 0.1, thenDragTo: endBack)

        let afterBackX = divider.frame.midX
        let leftDelta = afterBackX - afterX
        XCTAssertLessThanOrEqual(leftDelta, -30, "Expected drag-left to move the divider left")
        XCTAssertGreaterThanOrEqual(leftDelta, -62, "Divider moved farther than the requested drag-left offset")
    }

    func testSidebarDividerClampsToMinimumWidth() {
        let app = launchedApp()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5.0))

        let divider = sidebarDivider(in: app)
        XCTAssertTrue(divider.waitForExistence(timeout: 5.0))
        XCTAssertTrue(waitForDividerGeometry(divider, timeout: 5.0), "Expected the sidebar divider to have usable geometry")

        let sidebarMinX = sidebarLeadingEdge(in: app)
        // Stop above half the minimum: a drag past that collapses the sidebar instead.
        let start = dividerCoordinate(divider, in: window)
        let targetWidth = minimumSidebarWidth - 40
        let offset = targetWidth - (divider.frame.midX - sidebarMinX)
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: offset, dy: 0)))

        let sidebarWidth = max(0, divider.frame.midX - sidebarMinX)
        XCTAssertEqual(
            sidebarWidth,
            minimumSidebarWidth,
            accuracy: 6,
            "Expected a drag below the minimum to stop at \(minimumSidebarWidth) pt. width=\(sidebarWidth)"
        )
    }

    func testSidebarDividerHasMaximumWidthCap() {
        let app = launchedApp()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5.0))

        let divider = sidebarDivider(in: app)
        XCTAssertTrue(divider.waitForExistence(timeout: 5.0))
        XCTAssertTrue(waitForDividerGeometry(divider, timeout: 5.0), "Expected the sidebar divider to have usable geometry")

        let sidebarMinX = sidebarLeadingEdge(in: app)
        let start = dividerCoordinate(divider, in: window)
        let farRight = start.withOffset(CGVector(dx: max(1200, window.frame.width * 2.0), dy: 0))
        start.press(forDuration: 0.1, thenDragTo: farRight)

        let windowFrame = window.frame
        let sidebarWidth = max(0, divider.frame.midX - sidebarMinX)
        // The cap is a third of the window, but never below the minimum.
        let expectedMaximum = max(minimumSidebarWidth, min(600, windowFrame.width / 3))
        XCTAssertLessThanOrEqual(
            sidebarWidth,
            expectedMaximum + 6,
            "Expected the sidebar to stop at a third of the window. width=\(sidebarWidth), window=\(windowFrame.width)"
        )
    }

    private func sidebarDivider(in app: XCUIApplication) -> XCUIElement {
        app.splitGroups["MainSidebarSplit"].splitters.firstMatch
    }

    /// The system sidebar floats inside the window (inset from its leading edge on macOS 26),
    /// so the width runs from the sidebar's own leading edge. Read it before a drag: the
    /// sidebar's accessibility frame lags the divider while it settles.
    private func sidebarLeadingEdge(in app: XCUIApplication) -> CGFloat {
        let sidebar = app.descendants(matching: .any).matching(identifier: "Sidebar").firstMatch
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5.0), "Expected the sidebar to exist")
        return sidebar.frame.minX
    }

    private func launchedApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["PROGRAMA_UI_TEST_MODE"] = "1"
        app.launchEnvironment["PROGRAMA_TAG"] = "ui-tests-sidebar-resize-\(UUID().uuidString.lowercased())"
        app.launch()
        return app
    }

    private func dividerCoordinate(_ divider: XCUIElement, in window: XCUIElement) -> XCUICoordinate {
        let frame = divider.frame
        let windowFrame = window.frame
        return window.coordinate(withNormalizedOffset: .zero).withOffset(
            CGVector(dx: frame.midX - windowFrame.minX, dy: frame.midY - windowFrame.minY)
        )
    }

    private func waitForDividerGeometry(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                element.exists && element.frame.height > 1
            },
            object: NSObject()
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
