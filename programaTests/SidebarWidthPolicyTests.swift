import XCTest

#if canImport(Programa_DEV)
@testable import Programa_DEV
#elseif canImport(Programa)
@testable import Programa
#endif

final class SidebarWidthPolicyTests: XCTestCase {
    func testClampEnforcesToolbarSafeMinimum() {
        // Below the floor, widths clamp up so the traffic lights and the
        // toolbar controls over the sidebar never collide.
        XCTAssertEqual(
            SidebarWidthPolicy.clamped(184, maximumWidth: 600),
            CGFloat(SessionPersistencePolicy.minimumSidebarWidth),
            accuracy: 0.001
        )
        XCTAssertEqual(
            SidebarWidthPolicy.clamped(240, maximumWidth: 600),
            240,
            accuracy: 0.001
        )
    }

    func testMaximumIsAThirdOfTheWindowWithinTheFloorAndCeiling() {
        XCTAssertEqual(SidebarWidthPolicy.maximum(forAvailableWidth: 1200), 400, accuracy: 0.001)
        // Narrow windows keep the floor; wide windows stop at the persisted ceiling.
        XCTAssertEqual(
            SidebarWidthPolicy.maximum(forAvailableWidth: 500),
            CGFloat(SessionPersistencePolicy.minimumSidebarWidth),
            accuracy: 0.001
        )
        XCTAssertEqual(
            SidebarWidthPolicy.maximum(forAvailableWidth: 3000),
            CGFloat(SessionPersistencePolicy.maximumSidebarWidth),
            accuracy: 0.001
        )
    }
}
