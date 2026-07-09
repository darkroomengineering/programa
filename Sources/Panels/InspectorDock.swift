import AppKit

/// Canonical helpers for detecting and reasoning about WebKit's hosted Web Inspector
/// (the attached "WKInspector*" view hierarchy) inside the browser view stack.
///
/// Prior to this type, the same WKInspector string-sniffing and side-dock geometry math was
/// independently reimplemented in `BrowserPanel.swift`, `BrowserPanelView.swift`
/// (`WebViewRepresentable.Coordinator.HostContainerView`), and `BrowserWindowPortal.swift`
/// (`WindowBrowserHostView`). This consolidates the parts that were byte-for-byte identical
/// across those call sites. `AppDelegate.swift` has its own copy of the responder-sniffing half
/// (`programaIsLikelyWebInspectorResponder`) that is intentionally left alone here since
/// AppDelegate belongs to a different maintenance cluster.
enum InspectorDock {
    /// WebKit's hosted inspector views are private API with type names like
    /// `WKInspectorWKWebView` / `WKInspectorViewController` — detected by substring since there is
    /// no public type to check against.
    static func isInspectorView(_ view: NSView) -> Bool {
        String(describing: type(of: view)).contains("WKInspector")
    }

    /// Depth-first flattening of every descendant of `root` (not including `root` itself).
    static func visibleDescendants(in root: NSView) -> [NSView] {
        var descendants: [NSView] = []
        var stack = Array(root.subviews.reversed())
        while let view = stack.popLast() {
            descendants.append(view)
            stack.append(contentsOf: view.subviews.reversed())
        }
        return descendants
    }

    static func verticalOverlap(between lhs: NSRect, and rhs: NSRect) -> CGFloat {
        max(0, min(lhs.maxY, rhs.maxY) - max(lhs.minY, rhs.minY))
    }

    /// A view large enough on both axes to plausibly be a docked inspector panel (as opposed to a
    /// collapsed/zero-size view mid-layout-pass).
    static func isVisibleCandidate(_ view: NSView) -> Bool {
        !view.isHidden &&
            view.alphaValue > 0 &&
            view.frame.width > 1 &&
            view.frame.height > 1
    }

    /// A sibling of a candidate inspector view, large enough vertically to plausibly sit beside it.
    ///
    /// `requireMinWidth` preserves a real behavioral divergence between call sites: the
    /// `BrowserPanel` side-dock *detection* path requires `width > 1` (it only cares about fully
    /// laid-out siblings), while the `BrowserPanelView` / `BrowserWindowPortal` divider *hit-testing*
    /// paths intentionally omit the width check (a page sibling can be transiently zero-width while
    /// the user is mid-drag on the divider). Pass `true` for detection, `false` for divider hit-testing.
    static func isVisibleSiblingCandidate(_ view: NSView, requireMinWidth: Bool) -> Bool {
        guard !view.isHidden, view.alphaValue > 0, view.frame.height > 1 else { return false }
        return requireMinWidth ? view.frame.width > 1 : true
    }

    static func rectApproximatelyEqual(_ lhs: NSRect, _ rhs: NSRect, epsilon: CGFloat = 0.01) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) <= epsilon &&
            abs(lhs.origin.y - rhs.origin.y) <= epsilon &&
            abs(lhs.size.width - rhs.size.width) <= epsilon &&
            abs(lhs.size.height - rhs.size.height) <= epsilon
    }

    /// Walks the responder chain from `start` looking for `target`, bounded to guard against an
    /// accidental cycle.
    static func responderChainContains(_ start: NSResponder?, target: NSResponder, maxHops: Int = 64) -> Bool {
        var responder = start
        var hops = 0
        while let current = responder, hops < maxHops {
            if current === target { return true }
            responder = current.nextResponder
            hops += 1
        }
        return false
    }

    /// True if `responder` is itself a hosted-inspector view, or is nested inside one by walking up
    /// the `superview` chain.
    static func isLikelyInspectorResponder(_ responder: NSResponder?) -> Bool {
        guard let responder else { return false }
        if String(describing: type(of: responder)).contains("WKInspector") {
            return true
        }
        guard let view = responder as? NSView else { return false }
        var node: NSView? = view
        var hops = 0
        while let current = node, hops < 64 {
            if isInspectorView(current) {
                return true
            }
            node = current.superview
            hops += 1
        }
        return false
    }

    /// True if `root` (or any descendant) is a hosted inspector view — used to identify a detached
    /// Web Inspector window by inspecting its content view tree.
    static func windowContainsInspectorViews(_ root: NSView) -> Bool {
        if isInspectorView(root) {
            return true
        }
        for subview in root.subviews where windowContainsInspectorViews(subview) {
            return true
        }
        return false
    }

    /// True if `window` is a detached (undocked) Web Inspector window: titled "Web Inspector…" and
    /// hosting an inspector view somewhere in its content view tree.
    static func isDetachedInspectorWindow(_ window: NSWindow) -> Bool {
        guard window.title.hasPrefix("Web Inspector") else { return false }
        guard let contentView = window.contentView else { return false }
        return windowContainsInspectorViews(contentView)
    }
}
