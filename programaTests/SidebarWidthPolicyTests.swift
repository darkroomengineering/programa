import XCTest

#if canImport(Programa_DEV)
@testable import Programa_DEV
#elseif canImport(Programa)
@testable import Programa
#endif

final class SidebarWidthPolicyTests: XCTestCase {
    func testContentViewClampEnforcesHeaderSafeMinimum() {
        // Below the floor, widths clamp up so the traffic lights and the
        // header's titlebar controls never collide.
        XCTAssertEqual(
            ContentView.clampedSidebarWidth(184, maximumWidth: 600),
            CGFloat(SessionPersistencePolicy.minimumSidebarWidth),
            accuracy: 0.001
        )
        XCTAssertEqual(
            ContentView.clampedSidebarWidth(240, maximumWidth: 600),
            240,
            accuracy: 0.001
        )
    }
}
