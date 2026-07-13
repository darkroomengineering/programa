import AppKit
import Bonsplit
import SwiftUI

private func windowDragHandleFormatPoint(_ point: NSPoint) -> String {
    String(format: "(%.1f,%.1f)", point.x, point.y)
}

private func windowDragHandleShouldResolveActiveHitCapture(
    for eventType: NSEvent.EventType?,
    eventWindow: NSWindow?,
    dragHandleWindow: NSWindow?
) -> Bool {
    // We only need active hit resolution for titlebar mouse-down handling.
    // During launch, NSApp.currentEvent can transiently point at a stale
    // leftMouseDown from outside this window (for example Finder/Dock
    // activation). Treat those as passive events so we never walk SwiftUI/
    // AppKit hierarchy while initial layout is mutating it.
    guard eventType == .leftMouseDown else {
        return false
    }
    guard let dragHandleWindow else {
        // Test-only views may not be attached to a window.
        return true
    }
    guard let eventWindow else {
        return false
    }
    return eventWindow === dragHandleWindow
}

/// Runs the same action macOS titlebars use for double-click:
/// zoom by default, or minimize when the user preference is set.
enum StandardTitlebarDoubleClickAction: Equatable {
    case miniaturize
    case zoom
    case none
}

func resolvedStandardTitlebarDoubleClickAction(globalDefaults: [String: Any]) -> StandardTitlebarDoubleClickAction {
    if let action = (globalDefaults["AppleActionOnDoubleClick"] as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased() {
        switch action {
        case "minimize", "miniaturize":
            return .miniaturize
        case "maximize", "zoom", "fill":
            return .zoom
        case "none", "no action":
            return .none
        default:
            break
        }
    }

    if let miniaturizeOnDoubleClick = globalDefaults["AppleMiniaturizeOnDoubleClick"] as? Bool,
       miniaturizeOnDoubleClick {
        return .miniaturize
    }

    return .zoom
}

/// Runs the same action macOS titlebars use for double-click:
/// zoom by default, or minimize when the user preference is set.
@discardableResult
func performStandardTitlebarDoubleClick(window: NSWindow?) -> StandardTitlebarDoubleClickAction? {
    guard let window else { return nil }

    let globalDefaults = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain) ?? [:]
    let action = resolvedStandardTitlebarDoubleClickAction(globalDefaults: globalDefaults)
    switch action {
    case .miniaturize:
        window.miniaturize(nil)
    case .zoom:
        window.zoom(nil)
    case .none:
        break
    }
    return action
}

private enum WindowDragHandleAssociatedObjectKeys {
    private static let suppressionDepthToken = NSObject()

    static let suppressionDepth = UnsafeRawPointer(Unmanaged.passUnretained(suppressionDepthToken).toOpaque())
}

func beginWindowDragSuppression(window: NSWindow?) -> Int? {
    guard let window else { return nil }
    let current = windowDragSuppressionDepth(window: window)
    let next = current + 1
    objc_setAssociatedObject(
        window,
        WindowDragHandleAssociatedObjectKeys.suppressionDepth,
        NSNumber(value: next),
        .OBJC_ASSOCIATION_RETAIN_NONATOMIC
    )
    return next
}

@discardableResult
func endWindowDragSuppression(window: NSWindow?) -> Int {
    guard let window else { return 0 }
    let current = windowDragSuppressionDepth(window: window)
    let next = max(0, current - 1)
    if next == 0 {
        objc_setAssociatedObject(
            window,
            WindowDragHandleAssociatedObjectKeys.suppressionDepth,
            nil,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    } else {
        objc_setAssociatedObject(
            window,
            WindowDragHandleAssociatedObjectKeys.suppressionDepth,
            NSNumber(value: next),
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }
    return next
}

func windowDragSuppressionDepth(window: NSWindow?) -> Int {
    guard let window,
          let value = objc_getAssociatedObject(window, WindowDragHandleAssociatedObjectKeys.suppressionDepth) as? NSNumber else {
        return 0
    }
    return value.intValue
}

func isWindowDragSuppressed(window: NSWindow?) -> Bool {
    windowDragSuppressionDepth(window: window) > 0
}

@discardableResult
func clearWindowDragSuppression(window: NSWindow?) -> Int {
    guard let window else { return 0 }
    var depth = windowDragSuppressionDepth(window: window)
    while depth > 0 {
        depth = endWindowDragSuppression(window: window)
    }
    return depth
}

/// Temporarily enables window movability for explicit drag-handle drags, then
/// restores the previous movability state after `body` finishes.
@discardableResult
func withTemporaryWindowMovableEnabled(window: NSWindow?, _ body: () -> Void) -> Bool? {
    guard let window else {
        body()
        return nil
    }

    let previousMovableState = window.isMovable
    if !previousMovableState {
        window.isMovable = true
    }
    defer {
        if window.isMovable != previousMovableState {
            window.isMovable = previousMovableState
        }
    }

    body()
    return previousMovableState
}

/// SwiftUI/AppKit hosting wrappers can appear as the top hit even for empty
/// titlebar space. Treat those as pass-through so explicit sibling checks decide.
func windowDragHandleShouldTreatTopHitAsPassiveHost(_ view: NSView) -> Bool {
    let className = String(describing: type(of: view))
    if className.contains("HostContainerView")
        || className.contains("AppKitWindowHostingView")
        || className.contains("NSHostingView") {
        return true
    }
    if let window = view.window, view === window.contentView {
        return true
    }
    return false
}

/// Re-entrancy guard for the sibling hit-test walk and the window-level
/// top-hit resolution below. When `sibling.hitTest()` (or the top-hit
/// `superview.hitTest()` call) triggers SwiftUI view-body evaluation, AppKit
/// can call back into this function before the outer invocation finishes,
/// causing a Swift exclusive-access violation (SIGABRT). Scoped per window so
/// a nested window's capture check can still resolve while another window's
/// walk is in progress. Main-thread only, no lock needed.
private var _windowDragHandleResolvingSiblingHitScopes = Set<ObjectIdentifier>()

/// Tracks scopes where the window-level top-hit resolution below re-entered
/// this function (for example the drag handle is its own only subview, so
/// asking the superview to hit-test the point calls straight back into the
/// drag handle's own `hitTest`). When that happens the resulting top-hit is
/// unreliable — it reflects the guard's bail-out, not a real competing view —
/// so we must not use it to block capture. Scoped identically to
/// `_windowDragHandleResolvingSiblingHitScopes`.
private var _windowDragHandleTopHitReentrantScopes = Set<ObjectIdentifier>()

/// Returns whether the titlebar drag handle should capture a hit at `point`.
/// We only claim the hit when no sibling view already handles it, so interactive
/// controls layered in the titlebar (e.g. proxy folder icon) keep their gestures.
func windowDragHandleShouldCaptureHit(
    _ point: NSPoint,
    in dragHandleView: NSView,
    eventType: NSEvent.EventType? = NSApp.currentEvent?.type,
    eventWindow: NSWindow? = NSApp.currentEvent?.window
) -> Bool {
    let dragHandleWindow = dragHandleView.window

    // Suppression recovery runs first so stale depth is cleared even for
    // passive events — the associated-object reads/writes here are pure ObjC
    // runtime calls and cannot trigger Swift exclusive-access violations.
    if isWindowDragSuppressed(window: dragHandleWindow) {
        // Recover from stale suppression if a prior interaction missed cleanup.
        // We only keep suppression active while the left mouse button is down.
        if (NSEvent.pressedMouseButtons & 0x1) == 0 {
            let clearedDepth = clearWindowDragSuppression(window: dragHandleWindow)
            #if DEBUG
            dlog(
                "titlebar.dragHandle.hitTest suppressionRecovered clearedDepth=\(clearedDepth) point=\(windowDragHandleFormatPoint(point))"
            )
            #endif
        } else {
        #if DEBUG
            let depth = windowDragSuppressionDepth(window: dragHandleWindow)
            dlog(
                "titlebar.dragHandle.hitTest capture=false reason=suppressed depth=\(depth) point=\(windowDragHandleFormatPoint(point))"
            )
        #endif
            return false
        }
    }

    // Bail out before the view-hierarchy walk so we never re-enter SwiftUI
    // views during a layout pass — which causes exclusive-access crashes (#490).
    if !windowDragHandleShouldResolveActiveHitCapture(
        for: eventType,
        eventWindow: eventWindow,
        dragHandleWindow: dragHandleWindow
    ) {
        #if DEBUG
        let eventTypeDescription = eventType.map { String(describing: $0) } ?? "nil"
        let eventWindowNumber = eventWindow?.windowNumber ?? -1
        let dragWindowNumber = dragHandleWindow?.windowNumber ?? -1
        dlog(
            "titlebar.dragHandle.hitTest capture=false reason=passiveEvent eventType=\(eventTypeDescription) eventWindow=\(eventWindowNumber) dragWindow=\(dragWindowNumber) point=\(windowDragHandleFormatPoint(point))"
        )
        #endif
        return false
    }

    guard dragHandleView.bounds.contains(point) else {
        #if DEBUG
        dlog("titlebar.dragHandle.hitTest capture=false reason=outside point=\(windowDragHandleFormatPoint(point))")
        #endif
        return false
    }

    guard let superview = dragHandleView.superview else {
        #if DEBUG
        dlog("titlebar.dragHandle.hitTest capture=true reason=noSuperview point=\(windowDragHandleFormatPoint(point))")
        #endif
        return true
    }

    // Bail out if we're already inside a sibling hit-test walk. This happens
    // when sibling.hitTest() re-enters SwiftUI layout, which calls hitTest on
    // this drag handle again. Proceeding would trigger an exclusive-access
    // violation in the Swift runtime.
    let resolutionScope = ObjectIdentifier((dragHandleWindow ?? superview) as AnyObject)
    guard !_windowDragHandleResolvingSiblingHitScopes.contains(resolutionScope) else {
        _windowDragHandleTopHitReentrantScopes.insert(resolutionScope)
        #if DEBUG
        dlog("titlebar.dragHandle.hitTest capture=false reason=reentrant point=\(windowDragHandleFormatPoint(point))")
        #endif
        return false
    }

    _windowDragHandleResolvingSiblingHitScopes.insert(resolutionScope)
    defer { _windowDragHandleResolvingSiblingHitScopes.remove(resolutionScope) }

    let siblingSnapshot = Array(superview.subviews.reversed())

    #if DEBUG
    let siblingCount = siblingSnapshot.count
    #endif

    for sibling in siblingSnapshot {
        guard sibling !== dragHandleView else { continue }
        guard !sibling.isHidden, sibling.alphaValue > 0 else { continue }

        let pointInSibling = dragHandleView.convert(point, to: sibling)
        if let hitView = sibling.hitTest(pointInSibling) {
            let passiveHostHit = windowDragHandleShouldTreatTopHitAsPassiveHost(hitView)
            if passiveHostHit {
                #if DEBUG
                dlog(
                    "titlebar.dragHandle.hitTest capture=defer point=\(windowDragHandleFormatPoint(point)) sibling=\(type(of: sibling)) hit=\(type(of: hitView)) passiveHost=true"
                )
                #endif
                continue
            }
            #if DEBUG
            dlog(
                "titlebar.dragHandle.hitTest capture=false point=\(windowDragHandleFormatPoint(point)) siblingCount=\(siblingCount) sibling=\(type(of: sibling)) hit=\(type(of: hitView)) passiveHost=false"
            )
            #endif
            return false
        }
    }

    // Sibling-only checks above can't see a superview that overrides hitTest
    // to claim the point for itself without even delegating to its subviews
    // (for example a frontmost overlay container mounted above the drag
    // handle). Ask the superview directly what it would resolve to for this
    // point; if it's neither us nor a passive host wrapper, something else
    // owns this point and we must not steal it.
    //
    // This can call back into this function (e.g. when the drag handle is
    // the superview's only subview, `superview.hitTest` recurses straight
    // into the drag handle's own hitTest). Discard any stale re-entrancy
    // marker from the sibling walk above, then check freshly: if this
    // specific call re-enters, the resulting top-hit reflects the guard's
    // bail-out rather than a real competing view, so we must not use it to
    // block capture.
    _windowDragHandleTopHitReentrantScopes.remove(resolutionScope)
    let pointInSuperview = dragHandleView.convert(point, to: superview)
    let topHit = superview.hitTest(pointInSuperview)
    let topHitResolutionReentered = _windowDragHandleTopHitReentrantScopes.remove(resolutionScope) != nil

    if !topHitResolutionReentered,
       let topHit,
       topHit !== dragHandleView,
       !topHit.isHidden,
       topHit.alphaValue > 0,
       !windowDragHandleShouldTreatTopHitAsPassiveHost(topHit) {
        #if DEBUG
        dlog(
            "titlebar.dragHandle.hitTest capture=false reason=topHitBlocked point=\(windowDragHandleFormatPoint(point)) topHit=\(type(of: topHit))"
        )
        #endif
        return false
    }

    #if DEBUG
    dlog("titlebar.dragHandle.hitTest capture=true point=\(windowDragHandleFormatPoint(point)) siblingCount=\(siblingCount)")
    #endif
    return true
}

/// A transparent view that enables dragging the window when clicking in empty titlebar space.
/// This lets us keep `window.isMovableByWindowBackground = false` so drags in the app content
/// (e.g. sidebar tab reordering) don't move the whole window.
struct WindowDragHandleView: NSViewRepresentable {
    /// When `false` (and `onDoubleClick` is `nil`), double-clicks are left untouched
    /// (no titlebar zoom/minimize, no drag capture) so an underlying SwiftUI gesture
    /// can still fire. Defaults to `true` to preserve existing callers.
    var handlesDoubleClick: Bool = true

    /// When set, this view owns double-click handling itself and invokes this closure
    /// instead of the standard titlebar zoom/minimize action or the passthrough behavior.
    /// Use this (rather than relying on a sibling SwiftUI `.onTapGesture(count: 2)`) when
    /// this drag view is mounted in front of the gesture's content: a sibling gesture
    /// recognizer never sees the first click of a double-click once this view has
    /// claimed the hit-test for it, so passthrough-based double-click detection is
    /// unreliable when this view is frontmost (see sidebar empty-area drag fix).
    var onDoubleClick: (() -> Void)?

    func makeNSView(context: Context) -> NSView {
        let view = DraggableView()
        view.handlesDoubleClick = handlesDoubleClick
        view.onDoubleClick = onDoubleClick
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? DraggableView)?.handlesDoubleClick = handlesDoubleClick
        (nsView as? DraggableView)?.onDoubleClick = onDoubleClick
    }

    private final class DraggableView: NSView {
        var handlesDoubleClick = true
        var onDoubleClick: (() -> Void)?

        override var mouseDownCanMoveWindow: Bool { false }

        override func hitTest(_ point: NSPoint) -> NSView? {
            let currentEvent = NSApp.currentEvent
            // Fast bail-out: only claim hits for left-mouse-down events.
            // For mouseMoved / mouseEntered / etc., return nil immediately
            // to avoid re-entering SwiftUI view state during layout passes,
            // which causes exclusive-access crashes.
            guard currentEvent?.type == .leftMouseDown else {
                return nil
            }
            // Let double-clicks pass through to whatever is underneath when this
            // instance doesn't own double-click handling in any form (no zoom, no
            // custom action). When `onDoubleClick` is set, this view owns the double
            // click itself (see mouseDown) and must keep capturing the hit here too.
            if !handlesDoubleClick, onDoubleClick == nil, (currentEvent?.clickCount ?? 1) >= 2 {
                return nil
            }
            let shouldCapture = windowDragHandleShouldCaptureHit(
                point,
                in: self,
                eventType: currentEvent?.type,
                eventWindow: currentEvent?.window
            )
            #if DEBUG
            dlog(
                "titlebar.dragHandle.hitTestResult capture=\(shouldCapture) point=\(windowDragHandleFormatPoint(point)) window=\(window != nil)"
            )
            #endif
            return shouldCapture ? self : nil
        }

        override func mouseDown(with event: NSEvent) {
            #if DEBUG
            let point = convert(event.locationInWindow, from: nil)
            let depth = windowDragSuppressionDepth(window: window)
            dlog(
                "titlebar.dragHandle.mouseDown point=\(windowDragHandleFormatPoint(point)) clickCount=\(event.clickCount) depth=\(depth)"
            )
            #endif

            if event.clickCount >= 2 {
                if let onDoubleClick {
                    #if DEBUG
                    dlog("titlebar.dragHandle.mouseDownDoubleClick action=custom")
                    #endif
                    onDoubleClick()
                    return
                }
                guard handlesDoubleClick else {
                    #if DEBUG
                    dlog("titlebar.dragHandle.mouseDownDoubleClick skipped=handlesDoubleClickFalse")
                    #endif
                    super.mouseDown(with: event)
                    return
                }
                let action = performStandardTitlebarDoubleClick(window: window)
                #if DEBUG
                dlog("titlebar.dragHandle.mouseDownDoubleClick action=\(String(describing: action))")
                #endif
                if action != nil {
                    return
                }
            }

            guard !isWindowDragSuppressed(window: window) else {
                #if DEBUG
                dlog("titlebar.dragHandle.mouseDownIgnored reason=suppressed")
                #endif
                return
            }

            if let window {
                let previousMovableState = withTemporaryWindowMovableEnabled(window: window) {
                    window.performDrag(with: event)
                }
                #if DEBUG
                let restored = previousMovableState.map { String($0) } ?? "nil"
                dlog("titlebar.dragHandle.mouseDownComplete restoredMovable=\(restored) nowMovable=\(window.isMovable)")
                #endif
            } else {
                super.mouseDown(with: event)
            }
        }
    }
}

/// Local monitor that guarantees double-clicks in custom titlebar surfaces trigger
/// the standard macOS titlebar action even when the visible strip is hosted by
/// higher-level SwiftUI/AppKit container views.
struct TitlebarDoubleClickMonitorView: NSViewRepresentable {
    final class Coordinator {
        weak var view: NSView?
        var monitor: Any?

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor

        context.coordinator.view = view

        let coordinator = context.coordinator
        coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak coordinator] event in
            guard event.clickCount >= 2 else { return event }
            guard let coordinator, let view = coordinator.view, let window = view.window else { return event }
            guard event.window === window else { return event }

            let point = view.convert(event.locationInWindow, from: nil)
            guard view.bounds.contains(point) else { return event }

            let action = performStandardTitlebarDoubleClick(window: window)
            return action == nil ? event : nil
        }

        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.view = nsView
    }
}
