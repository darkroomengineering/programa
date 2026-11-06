import XCTest

final class SidebarResizeUITests: XCTestCase {
    private let minimumSidebarWidth: CGFloat = 238

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testSidebarDividerTracksCursor() {
        let app = launchedApp()

        let divider = sidebarDivider(in: app)
        XCTAssertTrue(divider.waitForExistence(timeout: 5.0))
        XCTAssertTrue(waitForElementHittable(divider, timeout: 5.0), "Expected the sidebar divider to become hittable")

        let initialX = divider.frame.midX

        let start = divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = start.withOffset(CGVector(dx: 80, dy: 0))
        start.press(forDuration: 0.1, thenDragTo: end)

        let afterX = divider.frame.midX
        let rightDelta = afterX - initialX
        XCTAssertGreaterThanOrEqual(rightDelta, 40, "Expected drag-right to move the divider meaningfully")
        XCTAssertLessThanOrEqual(rightDelta, 82, "Divider moved farther than the requested drag-right offset")

        let startBack = divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
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
        XCTAssertTrue(waitForElementHittable(divider, timeout: 5.0), "Expected the sidebar divider to become hittable")

        // Stop above half the minimum: a drag past that collapses the sidebar instead.
        let start = divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let targetWidth = minimumSidebarWidth - 40
        let offset = targetWidth - (divider.frame.midX - window.frame.minX)
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: offset, dy: 0)))

        let sidebarWidth = max(0, divider.frame.midX - window.frame.minX)
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
        XCTAssertTrue(waitForElementHittable(divider, timeout: 5.0), "Expected the sidebar divider to become hittable")

        let start = divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let farRight = start.withOffset(CGVector(dx: max(1200, window.frame.width * 2.0), dy: 0))
        start.press(forDuration: 0.1, thenDragTo: farRight)

        let windowFrame = window.frame
        let sidebarWidth = max(0, divider.frame.midX - windowFrame.minX)
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

    private func launchedApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["PROGRAMA_UI_TEST_MODE"] = "1"
        app.launchEnvironment["PROGRAMA_TAG"] = "ui-tests-sidebar-resize-\(UUID().uuidString.lowercased())"
        app.launch()
        return app
    }

    private func waitForElementHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                guard element.exists, element.isHittable else { return false }
                let frame = element.frame
                return frame.width > 0 && frame.height > 1
            },
            object: NSObject()
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
