import AppKit
import ObjectiveC
#if DEBUG
import Bonsplit
#endif

// MARK: - Window Terminal Host View (split out, Nuclear Review #97; hitTest() moved byte-for-byte)

final class WindowTerminalHostView: NSView {
    private struct DividerRegion {
        let rectInWindow: NSRect
        let isVertical: Bool
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
    private var cachedSidebarDividerX: CGFloat?
    private var sidebarDividerMissCount = 0
    private var trackingArea: NSTrackingArea?
    private var activeDividerCursorKind: DividerCursorKind?
    // PERF: Cache split-divider regions to avoid recursive view-tree walk on every
    // pointer event. Invalidated on any geometry change.
    private var cachedDividerRegions: [DividerRegion]?
#if DEBUG
    private var lastDragRouteSignature: String?
#endif

    deinit {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        clearActiveDividerCursor(restoreArrow: false)
    }

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

    override func resetCursorRects() {
        super.resetCursorRects()
        // A split add/remove can change divider geometry without changing the host
        // frame, so the frame-hook invalidation alone is insufficient (#6587 review).
        // Drop the cache here so the warm below always reflects current structure;
        // resetCursorRects is driven by invalidateCursorRects, not per pointer event,
        // so this keeps the cache fresh per cursor-rect cycle without re-walking the
        // tree on every hover.
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
    // Do not add work to the keyboard fast path below.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let currentEvent = NSApp.currentEvent
        switch currentEvent?.type {
        case .keyDown, .keyUp, .flagsChanged:
            let hitView = super.hitTest(point)
            return hitView === self ? nil : hitView
        default:
            break
        }

        if shouldPassThroughToSidebarResizer(at: point) {
            clearActiveDividerCursor(restoreArrow: false)
            return nil
        }

        // Compute divider hit once and reuse for both cursor update and pass-through.
        if let kind = splitDividerCursorKind(at: point) {
            activeDividerCursorKind = kind
            kind.cursor.set()
            TerminalWindowPortalRegistry.noteSplitDividerInteraction(
                in: window,
                event: currentEvent
            )
            return nil
        }

        clearActiveDividerCursor(restoreArrow: true)

        let dragPasteboardTypes = NSPasteboard(name: .drag).types
        let eventType = currentEvent?.type
        let shouldPassThrough = DragOverlayRoutingPolicy.shouldPassThroughPortalHitTesting(
            pasteboardTypes: dragPasteboardTypes,
            eventType: eventType
        )
        if shouldPassThrough {
#if DEBUG
            logDragRouteDecision(
                passThrough: true,
                eventType: eventType,
                pasteboardTypes: dragPasteboardTypes,
                hitView: nil
            )
#endif
            return nil
        }

        let hitView = super.hitTest(point)
#if DEBUG
        logDragRouteDecision(
            passThrough: false,
            eventType: currentEvent?.type,
            pasteboardTypes: dragPasteboardTypes,
            hitView: hitView
        )
#endif
        return hitView === self ? nil : hitView
    }

    private func shouldPassThroughToSidebarResizer(at point: NSPoint) -> Bool {
        // The sidebar resizer handle is implemented in SwiftUI. When terminals
        // are portal-hosted, this AppKit host can otherwise sit above the handle
        // and steal hover/mouse events.
        let visibleHostedViews = subviews.compactMap { $0 as? GhosttySurfaceScrollView }
            .filter { !$0.isHidden && $0.window != nil && $0.frame.width > 1 && $0.frame.height > 1 }

        // If content is flush to the leading edge, sidebar is effectively hidden.
        // In that state, treating any internal split edge as a sidebar divider
        // steals split-divider cursor/drag behavior.
        let hasLeadingContent = visibleHostedViews.contains {
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

        // Ignore transient 0-origin hosts while layouts churn (e.g. workspace
        // creation/switching). They can temporarily report minX=0 and would
        // otherwise clear divider pass-through, causing hover flicker.
        let dividerCandidates = visibleHostedViews
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

    private func updateDividerCursor(at point: NSPoint) {
        if shouldPassThroughToSidebarResizer(at: point) {
            clearActiveDividerCursor(restoreArrow: false)
            return
        }

        guard let nextKind = splitDividerCursorKind(at: point) else {
            clearActiveDividerCursor(restoreArrow: true)
            return
        }
        activeDividerCursorKind = nextKind
        nextKind.cursor.set()
    }

    private func clearActiveDividerCursor(restoreArrow: Bool) {
        guard activeDividerCursorKind != nil else { return }
        window?.invalidateCursorRects(for: self)
        activeDividerCursorKind = nil
        if restoreArrow {
            NSCursor.arrow.set()
        }
    }

    // PERF: Returns the cached divider regions, computing and caching on first call.
    // The cache is invalidated by setFrameSize / setFrameOrigin / viewDidMoveToWindow.
    // Do NOT call from non-pointer-event paths.
    private func dividerRegions() -> [DividerRegion] {
        if let cached = cachedDividerRegions { return cached }
        guard let rootView = window?.contentView else {
            cachedDividerRegions = []
            return []
        }
        var regions: [DividerRegion] = []
        Self.collectSplitDividerRegions(in: rootView, into: &regions)
        cachedDividerRegions = regions
        return regions
    }

    private func splitDividerCursorKind(at point: NSPoint) -> DividerCursorKind? {
        guard window != nil else { return nil }
        let windowPoint = convert(point, to: nil)
        // Only vertical dividers need the asymmetric-overlap treatment below,
        // so only pay for the hosted-view scan when a vertical region is present.
        var visibleHostedRectsInWindow: [NSRect]?
        for region in dividerRegions() {
            let expanded: NSRect
            if region.isVertical {
                let hostedRects = visibleHostedRectsInWindow ?? computeVisibleHostedRectsInWindow()
                visibleHostedRectsInWindow = hostedRects
                expanded = Self.expandedVerticalDividerRect(region.rectInWindow, hostedRectsInWindow: hostedRects)
            } else {
                // Mirror the original dividerCursorKind expansion: expand in all directions.
                expanded = region.rectInWindow.insetBy(dx: -Self.defaultDividerExpansion, dy: -Self.defaultDividerExpansion)
            }
            if expanded.contains(windowPoint) {
                return region.isVertical ? .vertical : .horizontal
            }
        }
        return nil
    }

    private static let defaultDividerExpansion: CGFloat = 5
    // Matches SidebarResizeInteraction.contentSideHitWidth's rationale: keep a
    // minimal overlap on whichever side of a divider is actually covered by
    // portal-hosted terminal content, so column-0 text selection isn't stolen by
    // the divider's drag handle. The non-hosted side keeps the full generous
    // defaultDividerExpansion grab area.
    private static let hostedTerminalDividerOverlapWidth: CGFloat = 2

    private func computeVisibleHostedRectsInWindow() -> [NSRect] {
        subviews
            .compactMap { $0 as? GhosttySurfaceScrollView }
            .filter { !$0.isHidden && $0.window != nil && $0.frame.width > 1 && $0.frame.height > 1 }
            .map { convert($0.frame, to: nil) }
    }

    // A vertical divider's default expansion is generous (defaultDividerExpansion)
    // on both sides. When a visible hosted terminal view's frame actually spans
    // across one side of the divider, shrink that side's overlap so hit-testing
    // near column 0 of the terminal favors terminal content over the divider's
    // drag handle, while the other (non-hosted) side keeps the full grab area.
    private static func expandedVerticalDividerRect(_ rect: NSRect, hostedRectsInWindow: [NSRect]) -> NSRect {
        let hostedSpansLeft = hostedRectsInWindow.contains { $0.minX < rect.minX && $0.maxX >= rect.minX }
        let hostedSpansRight = hostedRectsInWindow.contains { $0.minX <= rect.maxX && $0.maxX > rect.maxX }
        let leftExpansion = hostedSpansLeft ? hostedTerminalDividerOverlapWidth : defaultDividerExpansion
        let rightExpansion = hostedSpansRight ? hostedTerminalDividerOverlapWidth : defaultDividerExpansion
        return NSRect(
            x: rect.minX - leftExpansion,
            y: rect.minY - defaultDividerExpansion,
            width: rect.width + leftExpansion + rightExpansion,
            height: rect.height + defaultDividerExpansion * 2
        )
    }

    static func hasSplitDivider(atScreenPoint screenPoint: NSPoint, in window: NSWindow) -> Bool {
        guard let rootView = window.contentView else { return false }
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        return dividerCursorKind(at: windowPoint, in: rootView) != nil
    }

    private func shouldPassThroughToSplitDivider(at point: NSPoint) -> Bool {
        splitDividerCursorKind(at: point) != nil
    }

    private static func dividerCursorKind(at windowPoint: NSPoint, in view: NSView) -> DividerCursorKind? {
        guard !view.isHidden else { return nil }

        if let splitView = view as? NSSplitView {
            let pointInSplit = splitView.convert(windowPoint, from: nil)
            if splitView.bounds.contains(pointInSplit) {
                // Keep divider interactions reliable even when portal-hosted terminal frames
                // temporarily overlap divider edges during rapid layout churn.
                let expansion: CGFloat = 5
                let dividerCount = max(0, splitView.arrangedSubviews.count - 1)
                for dividerIndex in 0..<dividerCount {
                    let first = splitView.arrangedSubviews[dividerIndex].frame
                    let second = splitView.arrangedSubviews[dividerIndex + 1].frame
                    let thickness = splitView.dividerThickness
                    let dividerRect: NSRect
                    if splitView.isVertical {
                        // Keep divider hit-testing active even when one side is nearly collapsed,
                        // so users can drag the divider back out from the border.
                        // But ignore transient states where both panes are effectively 0-width.
                        guard first.width > 1 || second.width > 1 else { continue }
                        let x = max(0, first.maxX)
                        dividerRect = NSRect(
                            x: x,
                            y: 0,
                            width: thickness,
                            height: splitView.bounds.height
                        )
                    } else {
                        // Same behavior for horizontal splits with a near-zero-height pane.
                        guard first.height > 1 || second.height > 1 else { continue }
                        let y = max(0, first.maxY)
                        dividerRect = NSRect(
                            x: 0,
                            y: y,
                            width: splitView.bounds.width,
                            height: thickness
                        )
                    }
                    let expandedDividerRect = dividerRect.insetBy(dx: -expansion, dy: -expansion)
                    if expandedDividerRect.contains(pointInSplit) {
                        return splitView.isVertical ? .vertical : .horizontal
                    }
                }
            }
        }

        for subview in view.subviews.reversed() {
            if let kind = dividerCursorKind(at: windowPoint, in: subview) {
                return kind
            }
        }

        return nil
    }

    private static func collectSplitDividerRegions(in view: NSView, into result: inout [DividerRegion]) {
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
                        isVertical: splitView.isVertical
                    )
                )
            }
        }

        for subview in view.subviews {
            collectSplitDividerRegions(in: subview, into: &result)
        }
    }

#if DEBUG
    private func logDragRouteDecision(
        passThrough: Bool,
        eventType: NSEvent.EventType?,
        pasteboardTypes: [NSPasteboard.PasteboardType]?,
        hitView: NSView?
    ) {
        let hasRelevantTypes = DragOverlayRoutingPolicy.hasBonsplitTabTransfer(pasteboardTypes)
            || DragOverlayRoutingPolicy.hasSidebarTabReorder(pasteboardTypes)
        guard passThrough || hasRelevantTypes else { return }

        let targetClass = hitView.map { NSStringFromClass(type(of: $0)) } ?? "nil"
        let signature = [
            passThrough ? "1" : "0",
            debugEventName(eventType),
            debugPasteboardTypes(pasteboardTypes),
            targetClass,
        ].joined(separator: "|")
        guard lastDragRouteSignature != signature else { return }
        lastDragRouteSignature = signature

        dlog(
            "portal.dragRoute passThrough=\(passThrough ? 1 : 0) " +
            "event=\(debugEventName(eventType)) target=\(targetClass) " +
            "types=\(debugPasteboardTypes(pasteboardTypes))"
        )
    }

    private func debugPasteboardTypes(_ types: [NSPasteboard.PasteboardType]?) -> String {
        guard let types, !types.isEmpty else { return "-" }
        return types.map(\.rawValue).joined(separator: ",")
    }

    private func debugEventName(_ eventType: NSEvent.EventType?) -> String {
        guard let eventType else { return "none" }
        switch eventType {
        case .cursorUpdate: return "cursorUpdate"
        case .appKitDefined: return "appKitDefined"
        case .systemDefined: return "systemDefined"
        case .applicationDefined: return "applicationDefined"
        case .periodic: return "periodic"
        case .mouseMoved: return "mouseMoved"
        case .mouseEntered: return "mouseEntered"
        case .mouseExited: return "mouseExited"
        case .flagsChanged: return "flagsChanged"
        case .leftMouseDragged: return "leftMouseDragged"
        case .rightMouseDragged: return "rightMouseDragged"
        case .otherMouseDragged: return "otherMouseDragged"
        case .leftMouseDown: return "leftMouseDown"
        case .leftMouseUp: return "leftMouseUp"
        case .rightMouseDown: return "rightMouseDown"
        case .rightMouseUp: return "rightMouseUp"
        case .otherMouseDown: return "otherMouseDown"
        case .otherMouseUp: return "otherMouseUp"
        default: return "other(\(eventType.rawValue))"
        }
    }
#endif
}

final class SplitDividerOverlayView: NSView {
    private struct DividerSegment {
        let rect: NSRect
        let color: NSColor
        let isVertical: Bool
    }

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let window, let rootView = window.contentView else { return }

        var dividerSegments: [DividerSegment] = []
        collectDividerSegments(in: rootView, into: &dividerSegments)
        guard !dividerSegments.isEmpty else { return }
        let hostedFrames = hostedFramesLikelyToOccludeDividers()
        let visibleSegments = dividerSegments.filter { shouldRenderOverlay(for: $0, hostedFrames: hostedFrames) }
        guard !visibleSegments.isEmpty else { return }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }

        // Keep separators visible above portal-hosted surfaces while matching each split view's
        // native divider color (avoids visible color shifts at tiny pane sizes).
        for segment in visibleSegments where segment.rect.intersects(dirtyRect) {
            segment.color.setFill()
            let rect = segment.rect
            let pixelAligned = NSRect(
                x: floor(rect.origin.x),
                y: floor(rect.origin.y),
                width: max(1, round(rect.size.width)),
                height: max(1, round(rect.size.height))
            )
            NSBezierPath(rect: pixelAligned).fill()
        }
    }

    private func collectDividerSegments(in view: NSView, into result: inout [DividerSegment]) {
        guard !view.isHidden else { return }

        if let splitView = view as? NSSplitView {
            let dividerCount = max(0, splitView.arrangedSubviews.count - 1)
            let dividerColor = overlayDividerColor(for: splitView)
            for dividerIndex in 0..<dividerCount {
                let first = splitView.arrangedSubviews[dividerIndex].frame
                let thickness = max(splitView.dividerThickness, 1)
                let dividerRectInSplit: NSRect
                if splitView.isVertical {
                    dividerRectInSplit = NSRect(
                        x: first.maxX,
                        y: 0,
                        width: thickness,
                        height: splitView.bounds.height
                    )
                } else {
                    dividerRectInSplit = NSRect(
                        x: 0,
                        y: first.maxY,
                        width: splitView.bounds.width,
                        height: thickness
                    )
                }

                let dividerRectInWindow = splitView.convert(dividerRectInSplit, to: nil)
                let dividerRectInOverlay = convert(dividerRectInWindow, from: nil)
                if dividerRectInOverlay.intersects(bounds) {
                    result.append(
                        DividerSegment(
                            rect: dividerRectInOverlay,
                            color: dividerColor,
                            isVertical: splitView.isVertical
                        )
                    )
                }
            }
        }

        for subview in view.subviews {
            collectDividerSegments(in: subview, into: &result)
        }
    }

    private func hostedFramesLikelyToOccludeDividers() -> [NSRect] {
        guard let hostView = superview else { return [] }
        return hostView.subviews.compactMap { subview -> NSRect? in
            guard let hosted = subview as? GhosttySurfaceScrollView else { return nil }
            guard !hosted.isHidden, hosted.window != nil else { return nil }
            return hosted.frame
        }
    }

    private func shouldRenderOverlay(for segment: DividerSegment, hostedFrames: [NSRect]) -> Bool {
        // Draw only when a hosted surface actually intrudes across the divider centerline.
        // This preserves tiny-pane visibility fixes without darkening regular dividers.
        let axisEpsilon: CGFloat = 0.01
        let axis = segment.isVertical ? segment.rect.midX : segment.rect.midY
        let extentRect = segment.rect.insetBy(
            dx: segment.isVertical ? 0 : -1,
            dy: segment.isVertical ? -1 : 0
        )

        for frame in hostedFrames where frame.intersects(extentRect) {
            if segment.isVertical {
                if frame.minX < axis - axisEpsilon && frame.maxX > axis + axisEpsilon {
                    return true
                }
            } else if frame.minY < axis - axisEpsilon && frame.maxY > axis + axisEpsilon {
                return true
            }
        }
        return false
    }

    private func overlayDividerColor(for splitView: NSSplitView) -> NSColor {
        let divider = splitView.dividerColor.usingColorSpace(.deviceRGB) ?? splitView.dividerColor
        let alpha = divider.alphaComponent
        guard alpha < 0.999 else { return divider }

        guard let bgColor = splitView.layer?.backgroundColor.flatMap(NSColor.init(cgColor:)),
              let bgRGB = bgColor.usingColorSpace(.deviceRGB) else {
            return divider
        }

        let opaqueBG = bgRGB.withAlphaComponent(1)
        let opaqueDivider = divider.withAlphaComponent(1)
        return opaqueBG.blended(withFraction: alpha, of: opaqueDivider) ?? divider
    }
}
