import AppKit
import Bonsplit
import WebKit

private func browserPortalDebugToken(_ view: NSView?) -> String {
    guard let view else { return "nil" }
    let ptr = Unmanaged.passUnretained(view).toOpaque()
    return String(describing: ptr)
}

private func browserPortalDebugFrame(_ rect: NSRect) -> String {
    String(format: "%.1f,%.1f %.1fx%.1f", rect.origin.x, rect.origin.y, rect.size.width, rect.size.height)
}

enum HostedInspectorDockSide {
    case leading
    case trailing

    static func resolve(
        pageFrame: NSRect,
        inspectorFrame: NSRect,
        epsilon: CGFloat = 1
    ) -> Self? {
        if pageFrame.maxX <= inspectorFrame.minX + epsilon {
            return .trailing
        }
        if inspectorFrame.maxX <= pageFrame.minX + epsilon {
            return .leading
        }
        return nil
    }

    func dividerX(pageFrame: NSRect, inspectorFrame: NSRect) -> CGFloat {
        switch self {
        case .leading:
            return inspectorFrame.maxX
        case .trailing:
            return inspectorFrame.minX
        }
    }

    func dividerHitRect(
        in bounds: NSRect,
        pageFrame: NSRect,
        inspectorFrame: NSRect,
        expansion: CGFloat
    ) -> NSRect {
        return NSRect(
            x: dividerX(pageFrame: pageFrame, inspectorFrame: inspectorFrame) - expansion,
            y: bounds.minY,
            width: expansion * 2,
            height: max(0, bounds.height)
        )
    }

    func clampedDividerX(
        _ proposedDividerX: CGFloat,
        containerBounds: NSRect,
        pageFrame: NSRect,
        minimumInspectorWidth: CGFloat
    ) -> CGFloat {
        switch self {
        case .leading:
            let minDividerX = min(containerBounds.maxX, containerBounds.minX + minimumInspectorWidth)
            let maxDividerX = max(minDividerX, min(containerBounds.maxX, pageFrame.maxX))
            return max(minDividerX, min(maxDividerX, proposedDividerX))
        case .trailing:
            let minDividerX = max(containerBounds.minX, pageFrame.minX)
            let maxDividerX = max(minDividerX, containerBounds.maxX - minimumInspectorWidth)
            return max(minDividerX, min(maxDividerX, proposedDividerX))
        }
    }

    func inspectorWidth(forDividerX dividerX: CGFloat, in containerBounds: NSRect) -> CGFloat {
        switch self {
        case .leading:
            return max(0, dividerX - containerBounds.minX)
        case .trailing:
            return max(0, containerBounds.maxX - dividerX)
        }
    }

    func resizedFrames(
        preferredWidth: CGFloat,
        in containerBounds: NSRect,
        pageFrame: NSRect,
        inspectorFrame: NSRect,
        minimumInspectorWidth: CGFloat
    ) -> (pageFrame: NSRect, inspectorFrame: NSRect) {
        let normalizedMinY = containerBounds.minY
        let normalizedHeight = max(0, containerBounds.height)

        switch self {
        case .leading:
            let maximumInspectorWidth = max(0, containerBounds.width)
            let clampedMinimumInspectorWidth = min(maximumInspectorWidth, max(0, minimumInspectorWidth))
            let clampedInspectorWidth = min(
                maximumInspectorWidth,
                max(clampedMinimumInspectorWidth, preferredWidth)
            )
            let dividerX = min(containerBounds.maxX, containerBounds.minX + clampedInspectorWidth)

            var nextPageFrame = pageFrame
            nextPageFrame.origin.x = dividerX
            nextPageFrame.origin.y = normalizedMinY
            nextPageFrame.size.width = max(0, containerBounds.maxX - dividerX)
            nextPageFrame.size.height = normalizedHeight

            var nextInspectorFrame = inspectorFrame
            nextInspectorFrame.origin.x = containerBounds.minX
            nextInspectorFrame.origin.y = normalizedMinY
            nextInspectorFrame.size.width = max(0, dividerX - containerBounds.minX)
            nextInspectorFrame.size.height = normalizedHeight
            return (pageFrame: nextPageFrame, inspectorFrame: nextInspectorFrame)

        case .trailing:
            let maximumInspectorWidth = max(0, containerBounds.width)
            let clampedMinimumInspectorWidth = min(maximumInspectorWidth, max(0, minimumInspectorWidth))
            let clampedInspectorWidth = min(
                maximumInspectorWidth,
                max(clampedMinimumInspectorWidth, preferredWidth)
            )
            let dividerX = max(containerBounds.minX, containerBounds.maxX - clampedInspectorWidth)

            var nextPageFrame = pageFrame
            nextPageFrame.origin.x = containerBounds.minX
            nextPageFrame.origin.y = normalizedMinY
            nextPageFrame.size.width = max(0, dividerX - containerBounds.minX)
            nextPageFrame.size.height = normalizedHeight

            var nextInspectorFrame = inspectorFrame
            nextInspectorFrame.origin.x = dividerX
            nextInspectorFrame.origin.y = normalizedMinY
            nextInspectorFrame.size.width = max(0, containerBounds.maxX - dividerX)
            nextInspectorFrame.size.height = normalizedHeight
            return (pageFrame: nextPageFrame, inspectorFrame: nextInspectorFrame)
        }
    }
}

final class WindowBrowserHostView: NSView {
    private struct DividerRegion {
        let rectInWindow: NSRect
        let isVertical: Bool
        /// True when the split view that owns this divider is a descendant of the
        /// portal host view (i.e. an inspector/internal split, not an app-layout split).
        let isInHostedContent: Bool
    }

    private struct DividerHit {
        let kind: DividerCursorKind
        let isInHostedContent: Bool
    }

    private struct HostedInspectorDividerHit {
        let slotView: WindowBrowserSlotView
        let containerView: NSView
        let pageView: NSView
        let inspectorView: NSView
        let dockSide: HostedInspectorDockSide
    }

    private struct HostedInspectorDividerDragState {
        let slotView: WindowBrowserSlotView
        let containerView: NSView
        let pageView: NSView
        let inspectorView: NSView
        let dockSide: HostedInspectorDockSide
        let initialWindowX: CGFloat
        let initialPageFrame: NSRect
        let initialInspectorFrame: NSRect
    }

    private enum DividerCursorKind: Equatable {
        case vertical
        case horizontal

        var cursor: NSCursor {
            switch self {
            case .vertical: return .resizeLeftRight
            case .horizontal: return .resizeUpDown
            }
        }
    }

    override var isOpaque: Bool { false }
    private static let sidebarLeadingEdgeEpsilon: CGFloat = 1
    private static let minimumVisibleLeadingContentWidth: CGFloat = 24
    private static let hostedInspectorDividerHitExpansion: CGFloat = 6
    private static let minimumHostedInspectorWidth: CGFloat = 120
    private var cachedSidebarDividerX: CGFloat?
    private var sidebarDividerMissCount = 0
    private var trackingArea: NSTrackingArea?
    private var activeDividerCursorKind: DividerCursorKind?
    private var hostedInspectorDividerDrag: HostedInspectorDividerDragState?
    private var lastHostedInspectorLayoutBoundsSize: NSSize?
    // PERF: Cache split-divider regions to avoid recursive view-tree walk on every
    // pointer event. Invalidated on any geometry change.
    private var cachedDividerRegions: [DividerRegion]?

    deinit {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        clearActiveDividerCursor(restoreArrow: false)
    }

#if DEBUG
    private static func shouldLogPointerEvent(_ event: NSEvent?) -> Bool {
        switch event?.type {
        case .leftMouseDown, .leftMouseDragged, .leftMouseUp:
            return true
        default:
            return false
        }
    }

    private func debugLogPointerRouting(
        stage: String,
        point: NSPoint,
        titlebarPassThrough: Bool,
        sidebarPassThrough: Bool,
        dividerHit: DividerHit?,
        hitView: NSView?
    ) {
        let event = NSApp.currentEvent
        guard Self.shouldLogPointerEvent(event) else { return }

        let hitDesc: String = {
            guard let hitView else { return "nil" }
            return "\(type(of: hitView))@\(browserPortalDebugToken(hitView))"
        }()
        let dividerDesc: String = {
            guard let dividerHit else { return "nil" }
            let kind = dividerHit.kind == .vertical ? "vertical" : "horizontal"
            return "kind=\(kind),hosted=\(dividerHit.isInHostedContent ? 1 : 0)"
        }()
        let windowPoint = convert(point, to: nil)
        dlog(
            "browser.portal.pointer stage=\(stage) event=\(String(describing: event?.type)) " +
            "host=\(browserPortalDebugToken(self)) point=\(browserPortalDebugFrame(NSRect(origin: point, size: .zero))) " +
            "windowPoint=\(browserPortalDebugFrame(NSRect(origin: windowPoint, size: .zero))) " +
            "titlebar=\(titlebarPassThrough ? 1 : 0) sidebar=\(sidebarPassThrough ? 1 : 0) " +
            "divider=\(dividerDesc) hit=\(hitDesc)"
        )
    }
#endif

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        cachedDividerRegions = nil
        if window == nil {
            clearActiveDividerCursor(restoreArrow: false)
        }
        window?.invalidateCursorRects(for: self)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        cachedDividerRegions = nil
        window?.invalidateCursorRects(for: self)
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        cachedDividerRegions = nil
        window?.invalidateCursorRects(for: self)
    }

    override func layout() {
        super.layout()
        if let previousSize = lastHostedInspectorLayoutBoundsSize,
           Self.sizeApproximatelyEqual(previousSize, bounds.size, epsilon: 0.5) {
            return
        }
        lastHostedInspectorLayoutBoundsSize = bounds.size
        reapplyHostedInspectorDividersIfNeeded(reason: "host.layout")
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        guard let slot = subview as? WindowBrowserSlotView else { return }
        slot.onHostedInspectorLayout = { [weak self] slotView in
            self?.reapplyHostedInspectorDividerIfNeeded(in: slotView, reason: "slot.layout")
        }
    }

    override func willRemoveSubview(_ subview: NSView) {
        if let slot = subview as? WindowBrowserSlotView {
            slot.onHostedInspectorLayout = nil
        }
        super.willRemoveSubview(subview)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        // A split add/remove can change divider geometry without changing the host
        // frame, so frame-hook invalidation alone is insufficient (#6587 review).
        // Drop the cache here so the warm below reflects current structure;
        // resetCursorRects is driven by invalidateCursorRects, not per pointer event.
        cachedDividerRegions = nil
        guard window != nil else { return }
        // Warms the cache. Subsequent pointer events avoid the recursive walk.
        let regions = dividerRegions()
        let expansion: CGFloat = 4
        for region in regions {
            var rectInHost = convert(region.rectInWindow, from: nil)
            rectInHost = rectInHost.insetBy(
                dx: region.isVertical ? -expansion : 0,
                dy: region.isVertical ? 0 : -expansion
            )
            let clipped = rectInHost.intersection(bounds)
            guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { continue }
            addCursorRect(clipped, cursor: region.isVertical ? .resizeLeftRight : .resizeUpDown)
        }
    }

    override func updateTrackingAreas() {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let options: NSTrackingArea.Options = [
            .inVisibleRect,
            .activeAlways,
            .cursorUpdate,
            .mouseMoved,
            .mouseEnteredAndExited,
            .enabledDuringMouseDrag,
        ]
        let next = NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil)
        addTrackingArea(next)
        trackingArea = next
        super.updateTrackingAreas()
    }

    override func cursorUpdate(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        updateDividerCursor(at: point)
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        updateDividerCursor(at: point)
    }

    override func mouseExited(with event: NSEvent) {
        clearActiveDividerCursor(restoreArrow: true)
    }

    // PERF: hitTest is called on EVERY event including keyboard. Fast-path only the
    // keyboard-typing events known to trigger hitTest as a side effect
    // (keyDown/keyUp/flagsChanged). Everything else — including all pointer events
    // AND an ambiguous/nil currentEvent (e.g. hitTest invoked directly, outside
    // AppKit's real event dispatch: unit tests, programmatic hit-testing) — must
    // still run the full routing below, or dividers/pass-through silently break.
    // Mirrors the guard in WindowTerminalHostView. Do not add work to the keyboard
    // fast path below.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let currentEvent = NSApp.currentEvent
        switch currentEvent?.type {
        case .keyDown, .keyUp, .flagsChanged:
            let hitView = super.hitTest(point)
            return hitView === self ? nil : hitView
        default:
            break
        }

        let dividerHit = splitDividerHit(at: point)
        let hostedInspectorHit = dividerHit == nil ? hostedInspectorDividerHit(at: point) : nil
        updateDividerCursor(at: point, dividerHit: dividerHit, hostedInspectorHit: hostedInspectorHit)

        let titlebarPassThrough = shouldPassThroughToTitlebar(at: point)
        let sidebarPassThrough = shouldPassThroughToSidebarResizer(
            at: point,
            dividerHit: dividerHit,
            hostedInspectorHit: hostedInspectorHit
        )
        let splitPassThrough = dividerHit.map { !$0.isInHostedContent } ?? false

        if titlebarPassThrough {
#if DEBUG
            debugLogPointerRouting(
                stage: "hitTest.titlebarPass",
                point: point,
                titlebarPassThrough: true,
                sidebarPassThrough: sidebarPassThrough,
                dividerHit: dividerHit,
                hitView: nil
            )
#endif
            return nil
        }
        if sidebarPassThrough {
#if DEBUG
            debugLogPointerRouting(
                stage: "hitTest.sidebarPass",
                point: point,
                titlebarPassThrough: false,
                sidebarPassThrough: true,
                dividerHit: dividerHit,
                hitView: nil
            )
#endif
            return nil
        }
        if splitPassThrough {
#if DEBUG
            debugLogPointerRouting(
                stage: "hitTest.splitPass",
                point: point,
                titlebarPassThrough: false,
                sidebarPassThrough: false,
                dividerHit: dividerHit,
                hitView: nil
            )
#endif
            return nil
        }
        // Mirror terminal portal routing: while tab-reorder drags are active,
        // pass through to SwiftUI drop targets behind the portal host.
        // Browser hover routing also arrives as cursor/enter events and may not
        // report a pressed-button state, so include that path here.
        if Self.shouldPassThroughToDragTargets(
            pasteboardTypes: NSPasteboard(name: .drag).types,
            eventType: NSApp.currentEvent?.type
        ) {
            return nil
        }

        if let hostedInspectorHit {
            if let nativeHit = nativeHostedInspectorHit(at: point, hostedInspectorHit: hostedInspectorHit) {
#if DEBUG
                debugLogPointerRouting(
                    stage: "hitTest.hostedInspectorNative",
                    point: point,
                    titlebarPassThrough: false,
                    sidebarPassThrough: false,
                    dividerHit: DividerHit(kind: .vertical, isInHostedContent: true),
                    hitView: nativeHit
                )
#endif
                return nativeHit
            }
#if DEBUG
            debugLogPointerRouting(
                stage: "hitTest.hostedInspectorManual",
                point: point,
                titlebarPassThrough: false,
                sidebarPassThrough: false,
                dividerHit: DividerHit(kind: .vertical, isInHostedContent: true),
                hitView: hostedInspectorHit.inspectorView
            )
#endif
            return self
        }
        let hitView = super.hitTest(point)
#if DEBUG
        debugLogPointerRouting(
            stage: "hitTest.result",
            point: point,
            titlebarPassThrough: false,
            sidebarPassThrough: false,
            dividerHit: dividerHit,
            hitView: hitView === self ? nil : hitView
        )
#endif
        return hitView === self ? nil : hitView
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let hostedInspectorHit = hostedInspectorDividerHit(at: point) else {
            super.mouseDown(with: event)
            return
        }

        hostedInspectorHit.slotView.isHostedInspectorDividerDragActive = true
        hostedInspectorDividerDrag = HostedInspectorDividerDragState(
            slotView: hostedInspectorHit.slotView,
            containerView: hostedInspectorHit.containerView,
            pageView: hostedInspectorHit.pageView,
            inspectorView: hostedInspectorHit.inspectorView,
            dockSide: hostedInspectorHit.dockSide,
            initialWindowX: event.locationInWindow.x,
            initialPageFrame: hostedInspectorHit.pageView.frame,
            initialInspectorFrame: hostedInspectorHit.inspectorView.frame
        )
#if DEBUG
        dlog(
            "browser.portal.manualInspectorDrag stage=start slot=\(browserPortalDebugToken(hostedInspectorHit.slotView)) " +
            "page=\(browserPortalDebugToken(hostedInspectorHit.pageView)) " +
            "inspector=\(browserPortalDebugToken(hostedInspectorHit.inspectorView)) " +
            "pageFrame=\(browserPortalDebugFrame(hostedInspectorHit.pageView.frame)) " +
            "inspectorFrame=\(browserPortalDebugFrame(hostedInspectorHit.inspectorView.frame))"
        )
#endif
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragState = hostedInspectorDividerDrag else {
            super.mouseDragged(with: event)
            return
        }
        guard dragState.slotView.window === window else {
            dragState.slotView.isHostedInspectorDividerDragActive = false
            hostedInspectorDividerDrag = nil
            super.mouseDragged(with: event)
            return
        }

        let containerBounds = dragState.containerView.bounds
        let minimumInspectorWidth = min(
            Self.minimumHostedInspectorWidth,
            max(60, dragState.initialInspectorFrame.width)
        )
        let initialDividerX = dragState.dockSide.dividerX(
            pageFrame: dragState.initialPageFrame,
            inspectorFrame: dragState.initialInspectorFrame
        )
        let proposedDividerX = initialDividerX + (event.locationInWindow.x - dragState.initialWindowX)
        let clampedDividerX = dragState.dockSide.clampedDividerX(
            proposedDividerX,
            containerBounds: containerBounds,
            pageFrame: dragState.initialPageFrame,
            minimumInspectorWidth: minimumInspectorWidth
        )
        let inspectorWidth = dragState.dockSide.inspectorWidth(
            forDividerX: clampedDividerX,
            in: containerBounds
        )

        dragState.slotView.recordPreferredHostedInspectorWidth(inspectorWidth, containerBounds: containerBounds)
        let appliedFrames = applyHostedInspectorDividerWidth(
            inspectorWidth,
            to: HostedInspectorDividerHit(
                slotView: dragState.slotView,
                containerView: dragState.containerView,
                pageView: dragState.pageView,
                inspectorView: dragState.inspectorView,
                dockSide: dragState.dockSide
            ),
            minimumInspectorWidth: Self.minimumHostedInspectorWidth,
            reason: "drag"
        )
        updateDividerCursor(
            at: convert(event.locationInWindow, from: nil),
            dividerHit: nil,
            hostedInspectorHit: HostedInspectorDividerHit(
                slotView: dragState.slotView,
                containerView: dragState.containerView,
                pageView: dragState.pageView,
                inspectorView: dragState.inspectorView,
                dockSide: dragState.dockSide
            )
        )
#if DEBUG
        dlog(
            "browser.portal.manualInspectorDrag stage=update slot=\(browserPortalDebugToken(dragState.slotView)) " +
            "dividerX=\(String(format: "%.1f", clampedDividerX)) " +
            "pageFrame=\(browserPortalDebugFrame(appliedFrames.pageFrame)) " +
            "inspectorFrame=\(browserPortalDebugFrame(appliedFrames.inspectorFrame))"
        )
#endif
    }

    override func mouseUp(with event: NSEvent) {
        if let dragState = hostedInspectorDividerDrag {
            dragState.slotView.isHostedInspectorDividerDragActive = false
#if DEBUG
            dlog(
                "browser.portal.manualInspectorDrag stage=end slot=\(browserPortalDebugToken(dragState.slotView)) " +
                "pageFrame=\(browserPortalDebugFrame(dragState.pageView.frame)) " +
                "inspectorFrame=\(browserPortalDebugFrame(dragState.inspectorView.frame))"
            )
#endif
            scheduleHostedInspectorDividerReapply(in: dragState.slotView, reason: "dragEndAsync")
        }
        hostedInspectorDividerDrag = nil
        updateDividerCursor(at: convert(event.locationInWindow, from: nil))
        super.mouseUp(with: event)
    }

    private func shouldPassThroughToTitlebar(at point: NSPoint) -> Bool {
        guard let window else { return false }
        // Window-level portal hosts sit above SwiftUI content. Never intercept
        // hits that land in native titlebar space or the custom titlebar strip
        // we reserve directly under it for window drag/double-click behaviors.
        let windowPoint = convert(point, to: nil)
        let nativeTitlebarHeight = window.frame.height - window.contentLayoutRect.height
        let customTitlebarBandHeight = max(28, min(72, nativeTitlebarHeight))
        let interactionBandMinY = window.contentLayoutRect.maxY - customTitlebarBandHeight - 0.5
        return windowPoint.y >= interactionBandMinY
    }

    private func shouldPassThroughToSidebarResizer(at point: NSPoint) -> Bool {
        let dividerHit = splitDividerHit(at: point)
        let hostedInspectorHit = dividerHit == nil ? hostedInspectorDividerHit(at: point) : nil
        return shouldPassThroughToSidebarResizer(
            at: point,
            dividerHit: dividerHit,
            hostedInspectorHit: hostedInspectorHit
        )
    }

    private func shouldPassThroughToSidebarResizer(
        at point: NSPoint,
        dividerHit: DividerHit?,
        hostedInspectorHit: HostedInspectorDividerHit? = nil
    ) -> Bool {
        // If WebKit has a hosted vertical inspector split collapsed to the pane edge,
        // prefer that divider over the app/sidebar resize hit zone.
        if let dividerHit,
           dividerHit.isInHostedContent,
           dividerHit.kind == .vertical {
            return false
        }
        if hostedInspectorHit != nil {
            return false
        }

        // Browser portal host sits above SwiftUI content. Allow pointer/mouse events
        // to reach the SwiftUI sidebar divider resizer zone.
        let visibleSlots = subviews.compactMap { $0 as? WindowBrowserSlotView }
            .filter { !$0.isHidden && $0.window != nil && $0.frame.width > 1 && $0.frame.height > 1 }

        // If content is flush to the leading edge, sidebar is effectively hidden.
        // In that state, treating any internal split edge as a sidebar divider
        // steals split-divider cursor/drag behavior.
        let hasLeadingContent = visibleSlots.contains {
            $0.frame.minX <= Self.sidebarLeadingEdgeEpsilon
                && $0.frame.maxX > Self.minimumVisibleLeadingContentWidth
        }
        if hasLeadingContent {
            if cachedSidebarDividerX != nil {
                sidebarDividerMissCount += 1
                if sidebarDividerMissCount >= 2 {
                    cachedSidebarDividerX = nil
                    sidebarDividerMissCount = 0
                }
            }
            return false
        }

        // Ignore transient 0-origin slots during layout churn and preserve the last
        // known-good divider edge.
        let dividerCandidates = visibleSlots
            .map(\.frame.minX)
            .filter { $0 > Self.sidebarLeadingEdgeEpsilon }
        if let leftMostEdge = dividerCandidates.min() {
            cachedSidebarDividerX = leftMostEdge
            sidebarDividerMissCount = 0
        } else if cachedSidebarDividerX != nil {
            // Keep cache briefly for layout churn, but clear if we miss repeatedly
            // so stale divider positions don't steal pointer routing.
            sidebarDividerMissCount += 1
            if sidebarDividerMissCount >= 4 {
                cachedSidebarDividerX = nil
                sidebarDividerMissCount = 0
            }
        }

        guard let dividerX = cachedSidebarDividerX else {
            return false
        }

        let regionMinX = dividerX - SidebarResizeInteraction.sidebarSideHitWidth
        let regionMaxX = dividerX + SidebarResizeInteraction.contentSideHitWidth
        return point.x >= regionMinX && point.x <= regionMaxX
    }

    private func updateDividerCursor(
        at point: NSPoint,
        dividerHit: DividerHit? = nil,
        hostedInspectorHit: HostedInspectorDividerHit? = nil
    ) {
        let resolvedDividerHit = dividerHit ?? splitDividerHit(at: point)
        let resolvedHostedInspectorHit = resolvedDividerHit == nil ? (hostedInspectorHit ?? hostedInspectorDividerHit(at: point)) : nil
        if shouldPassThroughToSidebarResizer(
            at: point,
            dividerHit: resolvedDividerHit,
            hostedInspectorHit: resolvedHostedInspectorHit
        ) {
            clearActiveDividerCursor(restoreArrow: false)
            return
        }

        let nextKind = resolvedDividerHit?.kind ?? (resolvedHostedInspectorHit == nil ? nil : .vertical)
        guard let nextKind else {
            clearActiveDividerCursor(restoreArrow: true)
            return
        }
        activeDividerCursorKind = nextKind
        nextKind.cursor.set()
    }

    private func nativeHostedInspectorHit(
        at point: NSPoint,
        hostedInspectorHit: HostedInspectorDividerHit
    ) -> NSView? {
        guard let nativeHit = super.hitTest(point), nativeHit !== self else { return nil }
        if nativeHit === hostedInspectorHit.pageView ||
            nativeHit.isDescendant(of: hostedInspectorHit.pageView) {
            return nil
        }
        if nativeHit === hostedInspectorHit.inspectorView ||
            nativeHit.isDescendant(of: hostedInspectorHit.inspectorView) {
            return nativeHit
        }
        if hostedInspectorHit.inspectorView.isDescendant(of: nativeHit),
           !(hostedInspectorHit.pageView === nativeHit || hostedInspectorHit.pageView.isDescendant(of: nativeHit)) {
            return nativeHit
        }
        return nil
    }

    private func clearActiveDividerCursor(restoreArrow: Bool) {
        guard activeDividerCursorKind != nil else { return }
        window?.invalidateCursorRects(for: self)
        activeDividerCursorKind = nil
        if restoreArrow {
            NSCursor.arrow.set()
        }
    }

    // PERF: Returns the cached divider regions (including isInHostedContent), computing
    // and caching on first call. The cache is invalidated by setFrameSize / setFrameOrigin /
    // viewDidMoveToWindow. Do NOT call from non-pointer-event paths.
    private func dividerRegions() -> [DividerRegion] {
        if let cached = cachedDividerRegions { return cached }
        guard let rootView = dividerSearchRootView() else {
            cachedDividerRegions = []
            return []
        }
        var regions: [DividerRegion] = []
        Self.collectSplitDividerRegions(in: rootView, hostView: self, into: &regions)
        cachedDividerRegions = regions
        return regions
    }

    private func splitDividerHit(at point: NSPoint) -> DividerHit? {
        guard window != nil else { return nil }
        let windowPoint = convert(point, to: nil)
        let expansion: CGFloat = 5
        var fallback: DividerHit?
        for region in dividerRegions() {
            // Mirror the original dividerHit expansion: expand in all directions.
            let expanded = region.rectInWindow.insetBy(dx: -expansion, dy: -expansion)
            guard expanded.contains(windowPoint) else { continue }
            let hit = DividerHit(
                kind: region.isVertical ? .vertical : .horizontal,
                isInHostedContent: region.isInHostedContent
            )
            // Hosted (portal-internal, e.g. WebKit inspector) dividers are drawn on
            // top of the underlying app layout, so they must win hit-testing over an
            // app-level divider that only coincidentally overlaps this point — e.g. an
            // app split's full-height vertical divider sharing an x-coordinate with a
            // hosted horizontal inspector divider elsewhere on the same column. Keep
            // scanning for a hosted match before settling for a non-hosted one.
            if region.isInHostedContent {
                return hit
            }
            if fallback == nil {
                fallback = hit
            }
        }
        return fallback
    }

    private func dividerSearchRootView() -> NSView? {
        if let container = superview {
            return container
        }
        return window?.contentView
    }

    private func shouldPassThroughToSplitDivider(at point: NSPoint) -> Bool {
        guard let dividerHit = splitDividerHit(at: point) else { return false }
        // Portal host should pass split-divider events through to app layout splits,
        // but keep WebKit inspector/internal split dividers interactive.
        return !dividerHit.isInHostedContent
    }

    static func shouldPassThroughToDragTargets(
        pasteboardTypes: [NSPasteboard.PasteboardType]?,
        eventType: NSEvent.EventType?
    ) -> Bool {
        if DragOverlayRoutingPolicy.shouldPassThroughPortalHitTesting(
            pasteboardTypes: pasteboardTypes,
            eventType: eventType
        ) {
            return true
        }

        guard let eventType else { return false }
        switch eventType {
        case .cursorUpdate, .mouseEntered, .mouseExited, .mouseMoved:
            // Browser-side tab drags can surface as hover events with a mixed
            // pasteboard payload (tabtransfer plus promised-file UTIs). Prefer
            // the explicit Bonsplit drag types so WKWebView cannot steal the
            // session as a file upload.
            return DragOverlayRoutingPolicy.hasBonsplitTabTransfer(pasteboardTypes)
                || DragOverlayRoutingPolicy.hasSidebarTabReorder(pasteboardTypes)
        default:
            return false
        }
    }

    private func hostedInspectorDividerHit(at point: NSPoint) -> HostedInspectorDividerHit? {
        let visibleSlots = subviews.compactMap { $0 as? WindowBrowserSlotView }
            .filter { !$0.isHidden && $0.window != nil && $0.frame.height > 1 }

        for slot in visibleSlots {
            let pointInSlot = slot.convert(point, from: self)
            guard slot.bounds.contains(pointInSlot),
                  let hit = hostedInspectorDividerCandidate(in: slot) else {
                continue
            }

            if hostedInspectorDividerHitRect(for: hit).contains(pointInSlot) {
                return hit
            }
        }

        return nil
    }

    private func hostedInspectorDividerCandidate(in slot: WindowBrowserSlotView) -> HostedInspectorDividerHit? {
        let inspectorCandidates = InspectorDock.visibleDescendants(in: slot)
            .filter { InspectorDock.isVisibleCandidate($0) && InspectorDock.isInspectorView($0) }
            .sorted { lhs, rhs in
                let lhsFrame = slot.convert(lhs.bounds, from: lhs)
                let rhsFrame = slot.convert(rhs.bounds, from: rhs)
                return lhsFrame.minX < rhsFrame.minX
            }

        var bestHit: HostedInspectorDividerHit?
        var bestScore = -CGFloat.greatestFiniteMagnitude

        for inspectorCandidate in inspectorCandidates {
            guard let candidate = hostedInspectorDividerCandidate(in: slot, startingAt: inspectorCandidate) else {
                continue
            }
            let score = hostedInspectorDividerCandidateScore(candidate)
            if score > bestScore {
                bestScore = score
                bestHit = candidate
            }
        }

        return bestHit
    }

    private func hostedInspectorDividerCandidate(
        in slot: WindowBrowserSlotView,
        startingAt inspectorLeaf: NSView
    ) -> HostedInspectorDividerHit? {
        var current: NSView? = inspectorLeaf
        var bestHit: HostedInspectorDividerHit?

        while let inspectorView = current, inspectorView !== slot {
            guard let containerView = inspectorView.superview else { break }

            let pageCandidates = containerView.subviews.compactMap { candidate -> (view: NSView, dockSide: HostedInspectorDockSide)? in
                guard InspectorDock.isVisibleSiblingCandidate(candidate, requireMinWidth: false) else { return nil }
                guard candidate !== inspectorView else { return nil }
                guard InspectorDock.verticalOverlap(between: candidate.frame, and: inspectorView.frame) > 8 else {
                    return nil
                }
                guard let dockSide = HostedInspectorDockSide.resolve(
                    pageFrame: candidate.frame,
                    inspectorFrame: inspectorView.frame
                ) else {
                    return nil
                }
                return (view: candidate, dockSide: dockSide)
            }

            if let pageCandidate = pageCandidates.max(by: {
                hostedInspectorPageCandidateScore($0.view, inspectorView: inspectorView)
                    < hostedInspectorPageCandidateScore($1.view, inspectorView: inspectorView)
            }) {
                bestHit = HostedInspectorDividerHit(
                    slotView: slot,
                    containerView: containerView,
                    pageView: pageCandidate.view,
                    inspectorView: inspectorView,
                    dockSide: pageCandidate.dockSide
                )
            }

            current = containerView
        }

        return bestHit
    }

    private func hostedInspectorDividerHitRect(for hit: HostedInspectorDividerHit) -> NSRect {
        let slotBounds = hit.slotView.bounds
        let pageFrame = hit.slotView.convert(hit.pageView.bounds, from: hit.pageView)
        let inspectorFrame = hit.slotView.convert(hit.inspectorView.bounds, from: hit.inspectorView)
        return hit.dockSide.dividerHitRect(
            in: slotBounds,
            pageFrame: pageFrame,
            inspectorFrame: inspectorFrame,
            expansion: Self.hostedInspectorDividerHitExpansion
        )
    }

    private func hostedInspectorDividerCandidateScore(_ hit: HostedInspectorDividerHit) -> CGFloat {
        let pageFrame = hit.slotView.convert(hit.pageView.bounds, from: hit.pageView)
        let inspectorFrame = hit.slotView.convert(hit.inspectorView.bounds, from: hit.inspectorView)
        let overlap = InspectorDock.verticalOverlap(between: pageFrame, and: inspectorFrame)
        let coverageWidth = max(pageFrame.maxX, inspectorFrame.maxX) - min(pageFrame.minX, inspectorFrame.minX)
        return (overlap * 1_000) + coverageWidth + pageFrame.width
    }

    private func hostedInspectorPageCandidateScore(_ pageView: NSView, inspectorView: NSView) -> CGFloat {
        let overlap = InspectorDock.verticalOverlap(between: pageView.frame, and: inspectorView.frame)
        let coverageWidth = max(pageView.frame.maxX, inspectorView.frame.maxX) - min(pageView.frame.minX, inspectorView.frame.minX)
        return (overlap * 1_000) + coverageWidth + pageView.frame.width
    }

    private func reapplyHostedInspectorDividersIfNeeded(reason: String) {
        let visibleSlots = subviews.compactMap { $0 as? WindowBrowserSlotView }
            .filter { !$0.isHidden && $0.window != nil && $0.frame.height > 1 }
        for slot in visibleSlots {
            reapplyHostedInspectorDividerIfNeeded(in: slot, reason: reason)
        }
    }

    private func scheduleHostedInspectorDividerReapply(in slot: WindowBrowserSlotView, reason: String) {
        guard slot.preferredHostedInspectorWidth != nil else { return }
        DispatchQueue.main.async { [weak self, weak slot] in
            guard let self, let slot, slot.isDescendant(of: self) else { return }
            self.reapplyHostedInspectorDividerIfNeeded(in: slot, reason: reason)
        }
    }

    @discardableResult
    func reapplyHostedInspectorDividerIfNeeded(in slot: WindowBrowserSlotView, reason: String) -> Bool {
        guard !slot.isHostedInspectorDividerDragActive else {
#if DEBUG
            dlog(
                "browser.portal.manualInspectorDrag stage=skipReapply slot=\(browserPortalDebugToken(slot)) " +
                "reason=\(reason)"
            )
#endif
            return false
        }
        guard let preferredWidth = slot.resolvedPreferredHostedInspectorWidth(in: slot.bounds) else { return false }
        guard let hit = hostedInspectorDividerCandidate(in: slot) else { return false }
        let oldPageFrame = hit.pageView.frame
        let oldInspectorFrame = hit.inspectorView.frame
        _ = applyHostedInspectorDividerWidth(
            preferredWidth,
            to: hit,
            minimumInspectorWidth: Self.minimumHostedInspectorWidth,
            reason: reason
        )
        return !InspectorDock.rectApproximatelyEqual(oldPageFrame, hit.pageView.frame, epsilon: 0.5) ||
            !InspectorDock.rectApproximatelyEqual(oldInspectorFrame, hit.inspectorView.frame, epsilon: 0.5)
    }

    @discardableResult
    private func applyHostedInspectorDividerWidth(
        _ preferredWidth: CGFloat,
        to hit: HostedInspectorDividerHit,
        minimumInspectorWidth: CGFloat,
        reason: String
    ) -> (pageFrame: NSRect, inspectorFrame: NSRect) {
        let containerBounds = hit.containerView.bounds
        let nextFrames = hit.dockSide.resizedFrames(
            preferredWidth: preferredWidth,
            in: containerBounds,
            pageFrame: hit.pageView.frame,
            inspectorFrame: hit.inspectorView.frame,
            minimumInspectorWidth: minimumInspectorWidth
        )
        let pageFrame = nextFrames.pageFrame
        let inspectorFrame = nextFrames.inspectorFrame

        let oldPageFrame = hit.pageView.frame
        let oldInspectorFrame = hit.inspectorView.frame
        let pageChanged = !InspectorDock.rectApproximatelyEqual(pageFrame, oldPageFrame, epsilon: 0.5)
        let inspectorChanged = !InspectorDock.rectApproximatelyEqual(inspectorFrame, oldInspectorFrame, epsilon: 0.5)
        guard pageChanged || inspectorChanged else {
            return (pageFrame, inspectorFrame)
        }

        hit.slotView.isApplyingHostedInspectorLayout = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hit.pageView.frame = pageFrame
        hit.inspectorView.frame = inspectorFrame
        CATransaction.commit()
        hit.slotView.isApplyingHostedInspectorLayout = false

        let isLiveDrag = reason == "drag"
        hit.pageView.needsDisplay = true
        hit.pageView.setNeedsDisplay(hit.pageView.bounds)
        hit.inspectorView.needsDisplay = true
        hit.inspectorView.setNeedsDisplay(hit.inspectorView.bounds)
        hit.containerView.needsDisplay = true
        hit.containerView.setNeedsDisplay(hit.containerView.bounds)
        hit.slotView.needsDisplay = true
        hit.slotView.setNeedsDisplay(hit.slotView.bounds)
#if DEBUG
        dlog(
            "browser.portal.manualInspectorDrag stage=reapply slot=\(browserPortalDebugToken(hit.slotView)) " +
            "container=\(browserPortalDebugToken(hit.containerView)) reason=\(reason) " +
            "preferredWidth=\(String(format: "%.1f", preferredWidth)) " +
            "liveDrag=\(isLiveDrag ? 1 : 0) " +
            "pageChanged=\(pageChanged ? 1 : 0) inspectorChanged=\(inspectorChanged ? 1 : 0) " +
            "oldPageFrame=\(browserPortalDebugFrame(oldPageFrame)) oldInspectorFrame=\(browserPortalDebugFrame(oldInspectorFrame)) " +
            "pageFrame=\(browserPortalDebugFrame(pageFrame)) " +
            "inspectorFrame=\(browserPortalDebugFrame(inspectorFrame))"
        )
#endif
        return (pageFrame, inspectorFrame)
    }

    private static func sizeApproximatelyEqual(_ lhs: NSSize, _ rhs: NSSize, epsilon: CGFloat = 0.01) -> Bool {
        abs(lhs.width - rhs.width) <= epsilon &&
            abs(lhs.height - rhs.height) <= epsilon
    }

    private static func collectSplitDividerRegions(
        in view: NSView,
        hostView: WindowBrowserHostView,
        into result: inout [DividerRegion]
    ) {
        guard !view.isHidden else { return }

        if let splitView = view as? NSSplitView {
            let dividerCount = max(0, splitView.arrangedSubviews.count - 1)
            for dividerIndex in 0..<dividerCount {
                let first = splitView.arrangedSubviews[dividerIndex].frame
                let second = splitView.arrangedSubviews[dividerIndex + 1].frame
                let thickness = splitView.dividerThickness
                let dividerRect: NSRect
                if splitView.isVertical {
                    guard first.width > 1 || second.width > 1 else { continue }
                    let x = max(0, first.maxX)
                    dividerRect = NSRect(x: x, y: 0, width: thickness, height: splitView.bounds.height)
                } else {
                    guard first.height > 1 || second.height > 1 else { continue }
                    let y = max(0, first.maxY)
                    dividerRect = NSRect(x: 0, y: y, width: splitView.bounds.width, height: thickness)
                }
                let dividerRectInWindow = splitView.convert(dividerRect, to: nil)
                guard dividerRectInWindow.width > 0, dividerRectInWindow.height > 0 else { continue }
                result.append(
                    DividerRegion(
                        rectInWindow: dividerRectInWindow,
                        isVertical: splitView.isVertical,
                        isInHostedContent: splitView.isDescendant(of: hostView)
                    )
                )
            }
        }

        for subview in view.subviews {
            collectSplitDividerRegions(in: subview, hostView: hostView, into: &result)
        }
    }

}
