import AppKit
import Foundation

enum RendererRealizationSettings {
    struct Values: Equatable, Sendable {
        let enabled: Bool
        let idleSeconds: TimeInterval
        let maxWarmRenderers: Int
    }

    // Reclamation is non-destructive: only Ghostty's Metal swap chain is released.
    // The PTY, terminal state, scrollback, and surface wrapper remain alive.
    static let current = Values(enabled: true, idleSeconds: 30, maxWarmRenderers: 1)
}

struct RendererRealizationPlannerInput: Sendable {
    let surfaceId: UUID
    let isVisible: Bool
    let isRealized: Bool
    let lastVisibleAt: TimeInterval
}

enum RendererRealizationPlanner {
    static func selectedSurfaceIds(
        inputs: [RendererRealizationPlannerInput],
        settings: RendererRealizationSettings.Values,
        now: TimeInterval
    ) -> Set<UUID> {
        guard settings.enabled else { return [] }

        let ranked = inputs
            .filter(\.isRealized)
            .sorted { lhs, rhs in
                if lhs.lastVisibleAt == rhs.lastVisibleAt {
                    return lhs.surfaceId.uuidString < rhs.surfaceId.uuidString
                }
                return lhs.lastVisibleAt > rhs.lastVisibleAt
            }

        // Closed/hidden windows keep PTYs alive but need no permanently warm swap chain.
        let warmCap = inputs.contains(where: \.isVisible) ? max(1, settings.maxWarmRenderers) : 0
        var selected: Set<UUID> = []
        for (index, input) in ranked.enumerated() {
            if index < warmCap || input.isVisible { continue }
            guard now - input.lastVisibleAt >= settings.idleSeconds else { continue }
            selected.insert(input.surfaceId)
        }
        return selected
    }
}

/// Releases hidden terminal Metal swap chains after a short idle window while
/// leaving each terminal's PTY and state alive. A revealed surface rebuilds its
/// renderer before it is marked visible again.
@MainActor
final class RendererRealizationController {
    static let shared = RendererRealizationController()

    private let timerQueue = DispatchQueue(label: "com.darkroom.programa.renderer-realization", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var hasScheduledImmediatePass = false

    private init() {}

    func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        timer.schedule(deadline: .now() + 10, repeating: 20)
        timer.setEventHandler {
            let now = Date()
            Task { @MainActor in
                RendererRealizationController.shared.evaluate(now: now)
            }
        }
        timer.resume()
        self.timer = timer
    }

    func scheduleImmediatePass() {
        guard !hasScheduledImmediatePass else { return }
        hasScheduledImmediatePass = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            RendererRealizationController.shared.evaluate(now: Date())
            RendererRealizationController.shared.hasScheduledImmediatePass = false
        }
    }

    func evaluate(now: Date) {
        let settings = RendererRealizationSettings.current
        guard settings.enabled else { return }

        let surfaces = TerminalSurfaceRegistry.shared.allSurfaces()
        for surface in surfaces where surface.isRendererPortalVisible {
            surface.noteBecameVisibleForRendererReclamation()
            if surface.hasLiveSurface, !surface.isRendererRealized {
                surface.realizeRenderer()
            }
        }

        let inputs = surfaces.compactMap { surface -> RendererRealizationPlannerInput? in
            guard surface.hasLiveSurface else { return nil }
            return RendererRealizationPlannerInput(
                surfaceId: surface.id,
                isVisible: surface.isRendererPortalVisible,
                isRealized: surface.isRendererRealized,
                lastVisibleAt: surface.rendererLastVisibleAt
            )
        }

        let selected = RendererRealizationPlanner.selectedSurfaceIds(
            inputs: inputs,
            settings: settings,
            now: now.timeIntervalSince1970
        )
        for surface in surfaces where selected.contains(surface.id) {
            surface.releaseRenderer()
        }
    }
}
