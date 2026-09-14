import XCTest

#if canImport(Programa_DEV)
@testable import Programa_DEV
#elseif canImport(Programa)
@testable import Programa
#endif

final class RendererRealizationPlannerTests: XCTestCase {
    private func input(
        _ id: UUID,
        visible: Bool = false,
        realized: Bool = true,
        lastVisibleAt: TimeInterval
    ) -> RendererRealizationPlannerInput {
        RendererRealizationPlannerInput(
            surfaceId: id,
            isVisible: visible,
            isRealized: realized,
            lastVisibleAt: lastVisibleAt
        )
    }

    private func settings(
        enabled: Bool = true,
        idle: TimeInterval = 30,
        warm: Int = 12
    ) -> RendererRealizationSettings.Values {
        .init(enabled: enabled, idleSeconds: idle, maxWarmRenderers: warm)
    }

    func testDisabledSelectsNothing() {
        let selected = RendererRealizationPlanner.selectedSurfaceIds(
            inputs: [input(UUID(), lastVisibleAt: 0)],
            settings: settings(enabled: false),
            now: 1_000
        )
        XCTAssertTrue(selected.isEmpty)
    }

    func testNeverSelectsVisibleSurface() {
        let visible = UUID()
        let selected = RendererRealizationPlanner.selectedSurfaceIds(
            inputs: [input(visible, visible: true, lastVisibleAt: 0)],
            settings: settings(idle: 5, warm: 0),
            now: 1_000
        )
        XCTAssertFalse(selected.contains(visible))
    }

    func testRespectsIdleThresholdAndWarmCap() {
        let now: TimeInterval = 1_000
        let recent = UUID()
        let warm = UUID()
        let old = UUID()
        let selected = RendererRealizationPlanner.selectedSurfaceIds(
            inputs: [
                input(recent, visible: true, lastVisibleAt: now - 2),
                input(warm, lastVisibleAt: now - 100),
                input(old, lastVisibleAt: now - 200),
            ],
            settings: settings(idle: 5, warm: 1),
            now: now
        )
        XCTAssertFalse(selected.contains(recent))
        XCTAssertTrue(selected.contains(warm))
        XCTAssertTrue(selected.contains(old))
    }

    func testIgnoresAlreadyUnrealizedSurface() {
        let unrealized = UUID()
        let selected = RendererRealizationPlanner.selectedSurfaceIds(
            inputs: [input(unrealized, realized: false, lastVisibleAt: 0)],
            settings: settings(idle: 5, warm: 0),
            now: 1_000
        )
        XCTAssertTrue(selected.isEmpty)
    }

    func testTieBreakIsDeterministic() {
        let lower = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let higher = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let selected = RendererRealizationPlanner.selectedSurfaceIds(
            inputs: [
                input(UUID(), visible: true, lastVisibleAt: 1_000),
                input(higher, lastVisibleAt: 0),
                input(lower, lastVisibleAt: 0),
            ],
            settings: settings(idle: 5, warm: 2),
            now: 1_000
        )
        XCTAssertEqual(selected, [higher])
    }

    func testAllHiddenSurfacesReleaseGraphicsAfterIdleThreshold() {
        let old = UUID()
        let recent = UUID()
        let inputs = [input(old, lastVisibleAt: 0), input(recent, lastVisibleAt: 990)]
        XCTAssertEqual(RendererRealizationPlanner.selectedSurfaceIds(
            inputs: inputs, settings: settings(), now: 1_000
        ), [old])
        XCTAssertEqual(RendererRealizationPlanner.selectedSurfaceIds(
            inputs: inputs, settings: settings(), now: 1_021
        ), [old, recent])
    }
}
