import AppKit

@MainActor
class HostedViewPortalRegistry: NSObject {
    weak var window: NSWindow?
    var installedContainerView: NSView?
    var installedReferenceView: NSView?
    var geometryObservers: [NSObjectProtocol] = []

    init(window: NSWindow) {
        self.window = window
        super.init()
    }

    var hostViewForGeometry: NSView {
        preconditionFailure("HostedViewPortalRegistry subclasses must override hostViewForGeometry")
    }

    func removeGeometryObservers() {
        for observer in geometryObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        geometryObservers.removeAll()
    }

    /// Convert an anchor view's bounds to window coordinates while honoring ancestor
    /// clipping. SwiftUI/AppKit hosting layers can report an anchor bounds rect wider
    /// than its split pane when intrinsic-size content overflows; intersecting through
    /// ancestor bounds gives the effective visible rect that should drive portal geometry.
    func effectiveAnchorFrameInWindow(for anchorView: NSView) -> NSRect {
        var frameInWindow = anchorView.convert(anchorView.bounds, to: nil)
        var current = anchorView.superview
        while let ancestor = current {
            let ancestorBoundsInWindow = ancestor.convert(ancestor.bounds, to: nil)
            let finiteAncestorBounds =
                ancestorBoundsInWindow.origin.x.isFinite &&
                ancestorBoundsInWindow.origin.y.isFinite &&
                ancestorBoundsInWindow.size.width.isFinite &&
                ancestorBoundsInWindow.size.height.isFinite
            if finiteAncestorBounds {
                frameInWindow = frameInWindow.intersection(ancestorBoundsInWindow)
                if frameInWindow.isNull { return .zero }
            }
            if ancestor === installedReferenceView { break }
            current = ancestor.superview
        }
        return frameInWindow
    }

    @discardableResult
    func synchronizeHostFrameToReference() -> Bool {
        guard let container = installedContainerView,
              let reference = installedReferenceView else {
            return false
        }
        let frameInContainer = container.convert(reference.bounds, from: reference)
        let hasFiniteFrame =
            frameInContainer.origin.x.isFinite &&
            frameInContainer.origin.y.isFinite &&
            frameInContainer.size.width.isFinite &&
            frameInContainer.size.height.isFinite
        guard hasFiniteFrame else { return false }

        if !Self.rectApproximatelyEqual(hostViewForGeometry.frame, frameInContainer) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hostViewForGeometry.frame = frameInContainer
            CATransaction.commit()
#if DEBUG
            logHostFrameUpdate(frameInContainer)
#endif
        }
        return frameInContainer.width > 1 && frameInContainer.height > 1
    }

#if DEBUG
    /// No-op by default; each subclass overrides to emit its own dlog line verbatim so
    /// the existing greppable per-class diagnostic tokens/prefixes are unchanged.
    func logHostFrameUpdate(_ frame: NSRect) {}

    func debugHostedSubviewCount() -> Int {
        hostViewForGeometry.subviews.count
    }
#endif

    static func isHiddenOrAncestorHidden(_ view: NSView) -> Bool {
        if view.isHidden { return true }
        var current = view.superview
        while let v = current {
            if v.isHidden { return true }
            current = v.superview
        }
        return false
    }

    static func rectApproximatelyEqual(_ lhs: NSRect, _ rhs: NSRect, epsilon: CGFloat = 0.01) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) <= epsilon &&
            abs(lhs.origin.y - rhs.origin.y) <= epsilon &&
            abs(lhs.size.width - rhs.size.width) <= epsilon &&
            abs(lhs.size.height - rhs.size.height) <= epsilon
    }

    static func pixelSnappedRect(_ rect: NSRect, in view: NSView) -> NSRect {
        guard rect.origin.x.isFinite,
              rect.origin.y.isFinite,
              rect.size.width.isFinite,
              rect.size.height.isFinite else {
            return rect
        }
        let scale = max(1.0, view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1.0)
        func snap(_ value: CGFloat) -> CGFloat {
            (value * scale).rounded(.toNearestOrAwayFromZero) / scale
        }
        return NSRect(
            x: snap(rect.origin.x),
            y: snap(rect.origin.y),
            width: max(0, snap(rect.size.width)),
            height: max(0, snap(rect.size.height))
        )
    }

    static func isView(_ view: NSView, above reference: NSView, in container: NSView) -> Bool {
        guard let viewIndex = container.subviews.firstIndex(of: view),
              let referenceIndex = container.subviews.firstIndex(of: reference) else {
            return false
        }
        return viewIndex > referenceIndex
    }

    func tearDownEntries<ID: Hashable>(ids: [ID], detach: (ID) -> Void) {
        removeGeometryObservers()
        for id in ids {
            detach(id)
        }
    }

    struct GeometryNotificationSpec {
        let name: Notification.Name
        let object: NSObject?
        let handler: (Notification) -> Void
    }

    func observeGeometryAffectingNotifications(_ specs: [GeometryNotificationSpec]) {
        guard geometryObservers.isEmpty else { return }
        let center = NotificationCenter.default
        for spec in specs {
            geometryObservers.append(center.addObserver(
                forName: spec.name,
                object: spec.object,
                queue: .main
            ) { notification in
                MainActor.assumeIsolated {
                    spec.handler(notification)
                }
            })
        }
    }

    func hitScanReversedSubviews<Match, Result>(
        at windowPoint: NSPoint,
        map: (NSView) -> Match?,
        resolve: (Match, NSPoint) -> Result?
    ) -> Result? {
        let point = hostViewForGeometry.convert(windowPoint, from: nil)
        for subview in hostViewForGeometry.subviews.reversed() {
            guard let matched = map(subview) else { continue }
            if let result = resolve(matched, point) {
                return result
            }
        }
        return nil
    }

    static func pruneEntries<ID: Hashable>(
        ids: [ID],
        isDead: (ID) -> Bool,
        detach: (ID) -> Void
    ) {
        for id in ids where isDead(id) {
            detach(id)
        }
    }
}

struct TransientRecoveryRetryState {
    var remaining: Int
    var reason: String?
}

enum TransientRecoveryResetPolicy {
    /// Terminal: reset only when `remaining == 0`.
    case whenExhausted
}

/// Returns `true` if a retry was scheduled (and decrements `state.remaining`), `false`
/// if the budget is exhausted for the current reason. Mutates `state` in place; has no
/// view/window/notification access, so it is directly unit-testable.
@discardableResult
func scheduleRetryIfNeeded(
    state: inout TransientRecoveryRetryState,
    newReason: String,
    budget: Int,
    resetPolicy: TransientRecoveryResetPolicy
) -> Bool {
    let shouldReset: Bool
    switch resetPolicy {
    case .whenExhausted:
        shouldReset = state.remaining == 0
    }
    if shouldReset {
        state.remaining = budget
    }
    state.reason = newReason
    guard state.remaining > 0 else { return false }
    state.remaining -= 1
    return true
}
