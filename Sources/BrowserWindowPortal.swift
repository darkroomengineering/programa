import AppKit
import Bonsplit
import ObjectiveC
import SwiftUI
import WebKit

private var programaWindowBrowserPortalKey: UInt8 = 0
private var programaWindowBrowserPortalCloseObserverKey: UInt8 = 0
private var programaBrowserPortalNeedsRenderingStateReattachKey: UInt8 = 0
private var programaWindowInteractiveSplitDividerDragKey: UInt8 = 0

#if DEBUG
private func browserPortalDebugToken(_ view: NSView?) -> String {
    guard let view else { return "nil" }
    let ptr = Unmanaged.passUnretained(view).toOpaque()
    return String(describing: ptr)
}

private func browserPortalDebugFrame(_ rect: NSRect) -> String {
    String(format: "%.1f,%.1f %.1fx%.1f", rect.origin.x, rect.origin.y, rect.size.width, rect.size.height)
}
#endif

private extension NSObject {
    @discardableResult
    func browserPortalCallVoidIfAvailable(_ rawSelector: String) -> Bool {
        let selector = NSSelectorFromString(rawSelector)
        guard responds(to: selector) else { return false }
        typealias Fn = @convention(c) (AnyObject, Selector) -> Void
        let fn = unsafeBitCast(method(for: selector), to: Fn.self)
        fn(self, selector)
        return true
    }
}

private extension NSWindow {
    var browserPortalHasInteractiveSplitDividerDrag: Bool {
        get {
            let isActive =
                (objc_getAssociatedObject(self, &programaWindowInteractiveSplitDividerDragKey) as? NSNumber)?
                    .boolValue ?? false
            guard isActive else { return false }
            guard (NSEvent.pressedMouseButtons & 1) != 0 else {
                objc_setAssociatedObject(
                    self,
                    &programaWindowInteractiveSplitDividerDragKey,
                    NSNumber(value: false),
                    .OBJC_ASSOCIATION_RETAIN_NONATOMIC
                )
                return false
            }
            return true
        }
        set {
            objc_setAssociatedObject(
                self,
                &programaWindowInteractiveSplitDividerDragKey,
                NSNumber(value: newValue),
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
    }
}

private extension WKWebView {
    private var browserPortalNeedsRenderingStateReattach: Bool {
        get {
            (objc_getAssociatedObject(self, &programaBrowserPortalNeedsRenderingStateReattachKey) as? NSNumber)?
                .boolValue ?? false
        }
        set {
            objc_setAssociatedObject(
                self,
                &programaBrowserPortalNeedsRenderingStateReattachKey,
                NSNumber(value: newValue),
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
    }

    var browserPortalRequiresRenderingStateReattach: Bool {
        browserPortalNeedsRenderingStateReattach
    }

    /// Flags that a future reveal should nudge WebKit's rendering state back in,
    /// without firing the heavier `viewDidHide`/`_exitInWindow` lifecycle pair.
    /// Use this for simple tab/workspace visibility toggles where the surface isn't
    /// actually leaving the window/render tree — merely un-hiding the container
    /// (`isHidden = false`) isn't enough to resume WebKit compositing, but the full
    /// exit/enter pair would fire `visibilitychange` and can trigger page reloads.
    func browserPortalMarkNeedsRenderingStateReattach() {
        browserPortalNeedsRenderingStateReattach = true
    }

    func browserPortalNotifyHidden(reason: String) {
        browserPortalNeedsRenderingStateReattach = true
        let firedSelectors = ["viewDidHide", "_exitInWindow"].filter {
            browserPortalCallVoidIfAvailable($0)
        }
#if DEBUG
        if !firedSelectors.isEmpty {
            dlog(
                "browser.portal.webview.hidden web=\(browserPortalDebugToken(self)) " +
                "reason=\(reason) selectors=\(firedSelectors.joined(separator: ","))"
            )
        }
#endif
    }

    func browserPortalReattachRenderingState(reason: String) {
        guard browserPortalNeedsRenderingStateReattach else { return }
        guard window != nil else { return }
        browserPortalNeedsRenderingStateReattach = false

        let firedSelectors = [
            "viewDidUnhide",
            "_enterInWindow",
            "_endDeferringViewInWindowChangesSync",
        ].filter {
            browserPortalCallVoidIfAvailable($0)
        }

        if let scrollView = enclosingScrollView {
            scrollView.needsLayout = true
            scrollView.needsDisplay = true
            scrollView.setNeedsDisplay(scrollView.bounds)
            scrollView.contentView.needsLayout = true
            scrollView.contentView.needsDisplay = true
        }

        needsLayout = true
        needsDisplay = true
        setNeedsDisplay(bounds)

#if DEBUG
        if !firedSelectors.isEmpty {
            dlog(
                "browser.portal.webview.reattach web=\(browserPortalDebugToken(self)) " +
                "reason=\(reason) selectors=\(firedSelectors.joined(separator: ",")) " +
                "frame=\(browserPortalDebugFrame(frame))"
            )
        }
#endif
    }
}

@MainActor
final class WindowBrowserPortal: HostedViewPortalRegistry {
    private static let transientRecoveryRetryBudget: Int = 12

    private static func dividerHitRectContains(_ point: NSPoint, rect: NSRect) -> Bool {
        point.x >= rect.minX &&
            point.x <= rect.maxX &&
            point.y >= rect.minY &&
            point.y <= rect.maxY
    }

    private let hostView = WindowBrowserHostView(frame: .zero)
    private var hasDeferredFullSyncScheduled = false
    private var hasExternalGeometrySyncScheduled = false
    // Keep generations monotonic even if a pending entry is cleared during hide/detach churn.
    private var nextHostedWebViewRefreshGeneration: UInt64 = 0
    private var pendingHostedWebViewRefreshes: [ObjectIdentifier: PendingHostedWebViewRefresh] = [:]

    override var hostViewForGeometry: NSView { hostView }

    private struct Entry {
        weak var webView: WKWebView?
        weak var containerView: WindowBrowserSlotView?
        weak var anchorView: NSView?
        var visibleInUI: Bool
        var zPriority: Int
        var dropZone: DropZone?
        var paneDropContext: BrowserPaneDropContext?
        var searchOverlay: BrowserPortalSearchOverlayConfiguration?
        var paneTopChromeHeight: CGFloat
        var transientRecoveryReason: String?
        var transientRecoveryRetriesRemaining: Int
    }

    private struct PendingHostedWebViewRefresh {
        var generation: UInt64 = 0
        var asyncWorkItem: DispatchWorkItem?
        var delayedWorkItem: DispatchWorkItem?
    }

    private var entriesByWebViewId: [ObjectIdentifier: Entry] = [:]
    private var webViewByAnchorId: [ObjectIdentifier: ObjectIdentifier] = [:]

    override init(window: NSWindow) {
        super.init(window: window)
        hostView.wantsLayer = true
        hostView.layer?.masksToBounds = true
        hostView.translatesAutoresizingMaskIntoConstraints = true
        hostView.autoresizingMask = []
        installGeometryObservers(for: window)
        _ = ensureInstalled()
    }

    static func shouldTreatSplitResizeAsExternalGeometry(
        _ splitView: NSSplitView,
        window: NSWindow,
        hostView: WindowBrowserHostView
    ) -> Bool {
        guard splitView.window === window else { return false }
        // WebKit's attached DevTools uses internal NSSplitView instances for the
        // side/bottom inspector layout. Those resizes are local to hosted content
        // and should not trigger a full portal re-sync/refresh pass.
        guard !splitView.isDescendant(of: hostView) else { return false }
        // Browser host anchors already emit coalesced geometry callbacks while the
        // user drags a split divider. Running the portal-wide external-geometry
        // sync on the same drag frame doubles up WebKit refresh work and shows up
        // as visible flicker in browser panes.
        return !isInteractiveSplitDividerDrag(in: window)
    }

    private static func noteInteractiveSplitDividerDragIfNeeded(
        _ splitView: NSSplitView,
        window: NSWindow,
        hostView: WindowBrowserHostView
    ) {
        guard splitView.window === window else { return }
        guard !splitView.isDescendant(of: hostView) else { return }
        guard (NSEvent.pressedMouseButtons & 1) != 0 else { return }
        guard let event = NSApp.currentEvent else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard (now - event.timestamp) < 0.1 else { return }
        guard event.window === window else { return }
        switch event.type {
        case .leftMouseDown, .leftMouseDragged:
            break
        default:
            return
        }
        guard splitView.arrangedSubviews.count >= 2 else { return }

        let location = splitView.convert(event.locationInWindow, from: nil)
        let first = splitView.arrangedSubviews[0].frame
        let second = splitView.arrangedSubviews[1].frame
        let thickness = splitView.dividerThickness
        let dividerRect: NSRect

        if splitView.isVertical {
            guard first.width > 1, second.width > 1 else { return }
            dividerRect = NSRect(
                x: max(0, first.maxX),
                y: 0,
                width: thickness,
                height: splitView.bounds.height
            )
        } else {
            guard first.height > 1, second.height > 1 else { return }
            dividerRect = NSRect(
                x: 0,
                y: max(0, first.maxY),
                width: splitView.bounds.width,
                height: thickness
            )
        }

        let hitRect = dividerRect.insetBy(dx: -5, dy: -5)
        if dividerHitRectContains(location, rect: hitRect) {
            window.browserPortalHasInteractiveSplitDividerDrag = true
        }
    }

    private static func isInteractiveSplitDividerDrag(in window: NSWindow) -> Bool {
        if window.browserPortalHasInteractiveSplitDividerDrag {
            return true
        }
        guard (NSEvent.pressedMouseButtons & 1) != 0 else { return false }
        guard let event = NSApp.currentEvent else { return false }
        let now = ProcessInfo.processInfo.systemUptime
        guard (now - event.timestamp) < 0.1 else { return false }
        guard event.window === window else { return false }
        switch event.type {
        case .leftMouseDown, .leftMouseDragged:
            return true
        default:
            return false
        }
    }

    private func installGeometryObservers(for window: NSWindow) {
        guard geometryObservers.isEmpty else { return }

        let center = NotificationCenter.default
        geometryObservers.append(center.addObserver(
            forName: NSWindow.didResizeNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleExternalGeometrySynchronize()
            }
        })
        geometryObservers.append(center.addObserver(
            forName: NSWindow.didEndLiveResizeNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleExternalGeometrySynchronize()
            }
        })
        geometryObservers.append(center.addObserver(
            forName: NSSplitView.willResizeSubviewsNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self,
                      let splitView = notification.object as? NSSplitView,
                      let window = self.window else { return }
                Self.noteInteractiveSplitDividerDragIfNeeded(
                    splitView,
                    window: window,
                    hostView: self.hostView
                )
            }
        })
        geometryObservers.append(center.addObserver(
            forName: NSSplitView.didResizeSubviewsNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self,
                      let splitView = notification.object as? NSSplitView,
                      let window = self.window,
                      Self.shouldTreatSplitResizeAsExternalGeometry(
                          splitView,
                          window: window,
                          hostView: self.hostView
                      ) else { return }
                self.scheduleExternalGeometrySynchronize()
            }
        })
    }

    private func scheduleExternalGeometrySynchronize() {
        guard !hasExternalGeometrySyncScheduled else { return }
        hasExternalGeometrySyncScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hasExternalGeometrySyncScheduled = false
            self.synchronizeAllEntriesFromExternalGeometryChange()
        }
    }

    private func synchronizeAllEntriesFromExternalGeometryChange() {
        guard ensureInstalled() else { return }
        installedContainerView?.layoutSubtreeIfNeeded()
        installedReferenceView?.layoutSubtreeIfNeeded()
        hostView.superview?.layoutSubtreeIfNeeded()
        hostView.layoutSubtreeIfNeeded()
        synchronizeAllWebViews(excluding: nil, source: "externalGeometry")

        for entry in entriesByWebViewId.values {
            guard let webView = entry.webView,
                  let containerView = entry.containerView,
                  !containerView.isHidden else { continue }
            guard webView.superview === containerView else { continue }
            invalidateHostedWebViewGeometry(
                webView,
                in: containerView,
                reason: "externalGeometry"
            )
        }
        // Split add/remove fires this (via NSSplitView.didResizeSubviewsNotification)
        // without changing the host frame, so force a cursor-rect rebuild → the host
        // drops its stale divider-region cache (see resetCursorRects) and the new
        // divider is grabbable (#6587 review).
        hostView.window?.invalidateCursorRects(for: hostView)
    }

    @discardableResult
    private func ensureInstalled() -> Bool {
        guard let window else { return false }
        guard let (container, reference) = installationTarget(for: window) else { return false }
        let placementReference = preferredHostPlacementReference(in: container, fallback: reference)

        if hostView.superview !== container ||
            installedContainerView !== container ||
            installedReferenceView !== reference {
            hostView.removeFromSuperview()
            container.addSubview(hostView, positioned: .above, relativeTo: placementReference)
            installedContainerView = container
            installedReferenceView = reference
        } else {
            let aboveReference = Self.isView(hostView, above: reference, in: container)
            let abovePlacementReference = placementReference === reference
                || Self.isView(hostView, above: placementReference, in: container)
            if !aboveReference || !abovePlacementReference {
                container.addSubview(hostView, positioned: .above, relativeTo: placementReference)
            }
        }

        synchronizeHostFrameToReference()
        return true
    }

#if DEBUG
    override func logHostFrameUpdate(_ frame: NSRect) {
        dlog(
            "browser.portal.hostFrame.update host=\(browserPortalDebugToken(hostView)) " +
            "frame=\(browserPortalDebugFrame(frame))"
        )
    }
#endif

    private func installationTarget(for window: NSWindow) -> (container: NSView, reference: NSView)? {
        guard let contentView = window.contentView else { return nil }

        if WindowGlassEffect.isGlassEffectView(contentView),
           let foreground = contentView.subviews.first(where: { $0 !== hostView }) {
            return (contentView, foreground)
        }

        guard let themeFrame = contentView.superview else { return nil }
        return (themeFrame, contentView)
    }

    private static func searchOverlayConfigurationsEquivalent(
        _ lhs: BrowserPortalSearchOverlayConfiguration?,
        _ rhs: BrowserPortalSearchOverlayConfiguration?
    ) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            return lhs.panelId == rhs.panelId &&
                lhs.searchState === rhs.searchState &&
                lhs.focusRequestGeneration == rhs.focusRequestGeneration
        default:
            return false
        }
    }

    private static func frameExtendsOutsideBounds(_ frame: NSRect, bounds: NSRect, epsilon: CGFloat = 0.5) -> Bool {
        frame.minX < bounds.minX - epsilon ||
            frame.minY < bounds.minY - epsilon ||
            frame.maxX > bounds.maxX + epsilon ||
            frame.maxY > bounds.maxY + epsilon
    }

    private static func hasVisibleInspectorDescendant(in root: NSView) -> Bool {
        var stack: [NSView] = [root]
        while let current = stack.popLast() {
            if current !== root,
               InspectorDock.isInspectorView(current),
               InspectorDock.isVisibleCandidate(current) {
                return true
            }
            stack.append(contentsOf: current.subviews)
        }
        return false
    }

    private static func inferredBottomDockedInspectorFrame(
        in containerView: NSView,
        primaryWebView: WKWebView,
        epsilon: CGFloat = 1
    ) -> NSRect? {
        let pageFrame = primaryWebView.frame
        let containerBounds = containerView.bounds

        let candidates = containerView.subviews.compactMap { candidate -> NSRect? in
            guard candidate !== primaryWebView else { return nil }
            guard hasVisibleInspectorDescendant(in: candidate) else { return nil }

            let frame = candidate.frame
            guard frame.width > 1, frame.height > 1 else { return nil }
            let overlapWidth = min(pageFrame.maxX, frame.maxX) - max(pageFrame.minX, frame.minX)
            guard overlapWidth > min(pageFrame.width, frame.width) * 0.7 else { return nil }
            guard frame.minY <= containerBounds.minY + epsilon else { return nil }
            guard frame.maxY <= pageFrame.minY + epsilon else { return nil }
            return frame
        }

        return candidates.max(by: { $0.height < $1.height })
    }

    private static func repairedBottomDockedPageFrame(
        in containerView: NSView,
        primaryWebView: WKWebView,
        epsilon: CGFloat = 0.5
    ) -> NSRect? {
        let pageFrame = primaryWebView.frame
        let containerBounds = containerView.bounds
        guard frameExtendsOutsideBounds(pageFrame, bounds: containerBounds, epsilon: epsilon),
              let inspectorFrame = inferredBottomDockedInspectorFrame(
                  in: containerView,
                  primaryWebView: primaryWebView
              ) else {
            return nil
        }

        return NSRect(
            x: containerBounds.minX,
            y: inspectorFrame.maxY,
            width: containerBounds.width,
            height: max(0, containerBounds.maxY - inspectorFrame.maxY)
        )
    }

#if DEBUG
    private static func inspectorSubviewCount(in root: NSView) -> Int {
        var stack: [NSView] = [root]
        var count = 0
        while let current = stack.popLast() {
            for subview in current.subviews {
                if InspectorDock.isInspectorView(subview) {
                    count += 1
                }
                stack.append(subview)
            }
        }
        return count
    }
#endif

    private func preferredHostPlacementReference(in container: NSView, fallback reference: NSView) -> NSView {
        container.subviews.last(where: {
            $0 !== hostView && ($0 === reference || $0 is WindowTerminalHostView)
        }) ?? reference
    }

    private func directTransferChild(of container: NSView, containing descendant: NSView) -> NSView? {
        var current: NSView? = descendant
        var directChild: NSView?
        while let view = current, view !== container {
            directChild = view
            current = view.superview
        }
        guard current === container else { return nil }
        return directChild
    }

    private func relatedWebKitTransferSubviews(
        from sourceSuperview: NSView,
        primaryWebView: WKWebView
    ) -> [NSView] {
        var relatedSubviews: [NSView] = []
        var seen = Set<ObjectIdentifier>()

        func append(_ candidate: NSView?) {
            guard let candidate, candidate !== sourceSuperview else { return }
            let id = ObjectIdentifier(candidate)
            guard seen.insert(id).inserted else { return }
            relatedSubviews.append(candidate)
        }

        append(directTransferChild(of: sourceSuperview, containing: primaryWebView) ?? primaryWebView)

        if let inspectorFrontend = primaryWebView.programaInspectorFrontendWebView() {
            append(directTransferChild(of: sourceSuperview, containing: inspectorFrontend) ?? inspectorFrontend)
        }

        for view in sourceSuperview.subviews {
            if view === primaryWebView { continue }
            let className = String(describing: type(of: view))
            guard className.contains("WK") else { continue }
            if InspectorDock.isInspectorView(view) && !InspectorDock.isVisibleCandidate(view) {
                continue
            }
            append(view)
        }

        return relatedSubviews
    }

    private func appendHostedWebKitSubviews(
        in root: NSView,
        to result: inout [WKWebView],
        seen: inout Set<ObjectIdentifier>
    ) {
        if let webView = root as? WKWebView {
            let id = ObjectIdentifier(webView)
            if seen.insert(id).inserted {
                result.append(webView)
            }
        }
        for subview in root.subviews {
            appendHostedWebKitSubviews(in: subview, to: &result, seen: &seen)
        }
    }

    private func hostedWebKitSubviews(
        in containerView: NSView,
        primaryWebView: WKWebView
    ) -> [WKWebView] {
        var result: [WKWebView] = []
        var seen = Set<ObjectIdentifier>()

        func append(_ webView: WKWebView?) {
            guard let webView else { return }
            let id = ObjectIdentifier(webView)
            guard seen.insert(id).inserted else { return }
            result.append(webView)
        }

        if primaryWebView === containerView ||
            primaryWebView.superview === containerView ||
            primaryWebView.isDescendant(of: containerView) {
            append(primaryWebView)
        }
        appendHostedWebKitSubviews(in: containerView, to: &result, seen: &seen)
        return result
    }

    private func notifyHostedWebKitHidden(
        in containerView: NSView,
        primaryWebView: WKWebView,
        reason: String
    ) {
        for webKitSubview in hostedWebKitSubviews(
            in: containerView,
            primaryWebView: primaryWebView
        ) {
            webKitSubview.browserPortalNotifyHidden(reason: reason)
        }
    }

    private func ensureContainerView(for entry: Entry, webView: WKWebView) -> WindowBrowserSlotView {
        if let existing = entry.containerView {
            existing.setPaneDropContext(entry.paneDropContext)
            existing.setSearchOverlay(entry.searchOverlay)
            existing.setPaneTopChromeHeight(entry.paneTopChromeHeight)
            return existing
        }
        let created = WindowBrowserSlotView(frame: .zero)
        created.setPaneDropContext(entry.paneDropContext)
        created.setSearchOverlay(entry.searchOverlay)
        created.setPaneTopChromeHeight(entry.paneTopChromeHeight)
#if DEBUG
        dlog(
            "browser.portal.container.create web=\(browserPortalDebugToken(webView)) " +
            "container=\(browserPortalDebugToken(created))"
        )
#endif
        return created
    }

    private func runHostedWebViewRefreshPass(
        _ webView: WKWebView,
        in containerView: WindowBrowserSlotView,
        reason: String,
        phase: String,
        reattachRenderingState: Bool
    ) {
        guard !containerView.isHidden else { return }
        guard !containerView.isHostedInspectorDividerDragActive else {
#if DEBUG
            dlog(
                "browser.portal.refresh.skip web=\(browserPortalDebugToken(webView)) " +
                "container=\(browserPortalDebugToken(containerView)) reason=\(reason) phase=\(phase) " +
                "drag=1 reattach=\(reattachRenderingState ? 1 : 0)"
            )
#endif
            return
        }

        let hostedWebKitSubviews = hostedWebKitSubviews(
            in: containerView,
            primaryWebView: webView
        )
        guard !hostedWebKitSubviews.isEmpty else { return }

        containerView.needsLayout = true
        containerView.needsDisplay = true
        containerView.setNeedsDisplay(containerView.bounds)

        for webKitSubview in hostedWebKitSubviews {
            if let scrollView = webKitSubview.enclosingScrollView {
                scrollView.needsLayout = true
                scrollView.needsDisplay = true
                scrollView.setNeedsDisplay(scrollView.bounds)
                scrollView.contentView.needsLayout = true
                scrollView.contentView.needsDisplay = true
            }

            webKitSubview.needsLayout = true
            webKitSubview.needsDisplay = true
            webKitSubview.setNeedsDisplay(webKitSubview.bounds)
        }

        containerView.layoutSubtreeIfNeeded()
        for webKitSubview in hostedWebKitSubviews {
            if let scrollView = webKitSubview.enclosingScrollView {
                scrollView.layoutSubtreeIfNeeded()
                scrollView.contentView.layoutSubtreeIfNeeded()
                scrollView.displayIfNeeded()
            }
            webKitSubview.layoutSubtreeIfNeeded()
            if reattachRenderingState {
                webKitSubview.browserPortalReattachRenderingState(reason: "\(reason):\(phase)")
            }
            webKitSubview.displayIfNeeded()
        }
        containerView.displayIfNeeded()
        (containerView.window ?? webView.window ?? hostView.window)?.displayIfNeeded()
#if DEBUG
        dlog(
            "\(reattachRenderingState ? "browser.portal.refresh" : "browser.portal.invalidate") " +
            "web=\(browserPortalDebugToken(webView)) " +
            "container=\(browserPortalDebugToken(containerView)) reason=\(reason) " +
            "phase=\(phase) frame=\(browserPortalDebugFrame(containerView.frame))"
        )
#endif
    }

    private func cancelPendingHostedWebViewRefreshes(
        for webViewId: ObjectIdentifier,
        keepGeneration: Bool = false
    ) {
        guard var pending = pendingHostedWebViewRefreshes[webViewId] else { return }
        pending.asyncWorkItem?.cancel()
        pending.delayedWorkItem?.cancel()
        if keepGeneration {
            pending.asyncWorkItem = nil
            pending.delayedWorkItem = nil
            pendingHostedWebViewRefreshes[webViewId] = pending
        } else {
            pendingHostedWebViewRefreshes.removeValue(forKey: webViewId)
        }
    }

    private func invalidateHostedWebViewGeometry(
        _ webView: WKWebView,
        in containerView: WindowBrowserSlotView,
        reason: String
    ) {
        runHostedWebViewRefreshPass(
            webView,
            in: containerView,
            reason: reason,
            phase: "geometry",
            reattachRenderingState: false
        )
    }

    private func refreshHostedWebViewPresentation(
        _ webView: WKWebView,
        in containerView: WindowBrowserSlotView,
        reason: String
    ) {
        guard !containerView.isHidden else { return }
        let webViewId = ObjectIdentifier(webView)

        // Bind/reveal/fullscreen refreshes can stack up during a single layout churn.
        // Keep only the latest follow-up passes so reattach work does not pile up on
        // the main thread while browser panes are moving between hosts.
        cancelPendingHostedWebViewRefreshes(for: webViewId, keepGeneration: true)
        var pending = pendingHostedWebViewRefreshes[webViewId] ?? PendingHostedWebViewRefresh()
        nextHostedWebViewRefreshGeneration &+= 1
        let generation = nextHostedWebViewRefreshGeneration
        pending.generation = generation

        runHostedWebViewRefreshPass(
            webView,
            in: containerView,
            reason: reason,
            phase: "immediate",
            reattachRenderingState: true
        )

        let asyncWorkItem = DispatchWorkItem { [weak self, weak webView, weak containerView] in
            guard let self, let webView, let containerView else { return }
            guard self.pendingHostedWebViewRefreshes[webViewId]?.generation == generation else { return }
            self.runHostedWebViewRefreshPass(
                webView,
                in: containerView,
                reason: reason,
                phase: "async",
                reattachRenderingState: true
            )
        }
        pending.asyncWorkItem = asyncWorkItem

        let delayedWorkItem = DispatchWorkItem { [weak self, weak webView, weak containerView] in
            guard let self else { return }
            defer {
                if var current = self.pendingHostedWebViewRefreshes[webViewId],
                   current.generation == generation {
                    current.asyncWorkItem = nil
                    current.delayedWorkItem = nil
                    self.pendingHostedWebViewRefreshes[webViewId] = current
                }
            }
            guard let webView, let containerView else { return }
            guard self.pendingHostedWebViewRefreshes[webViewId]?.generation == generation else { return }
            self.runHostedWebViewRefreshPass(
                webView,
                in: containerView,
                reason: reason,
                phase: "delayed",
                reattachRenderingState: true
            )
        }
        pending.delayedWorkItem = delayedWorkItem
        pendingHostedWebViewRefreshes[webViewId] = pending

        DispatchQueue.main.async(execute: asyncWorkItem)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: delayedWorkItem)
    }

    private enum HostedWebViewPresentationUpdateKind {
        case none
        case geometryOnly
        case refresh

        private static let geometryOnlyReasons: Set<String> = [
            "frame",
            "bounds",
            "webFrame",
            "webFrameBottomDock",
        ]

        private static let refreshReasons: Set<String> = [
            "syncAttachContainer",
            "syncAttachWebView",
            "reveal",
            "transientRecovery",
            "anchor",
        ]

        static func resolve(reasons: [String]) -> Self {
            guard !reasons.isEmpty else { return .none }
            let reasonSet = Set(reasons)
            if !reasonSet.isDisjoint(with: Self.refreshReasons) {
                return .refresh
            }
            if reasonSet.isSubset(of: Self.geometryOnlyReasons) {
                return .geometryOnly
            }
            return .refresh
        }
    }

    private func moveWebKitRelatedSubviewsIfNeeded(
        from sourceSuperview: NSView,
        to containerView: WindowBrowserSlotView,
        primaryWebView: WKWebView,
        reason: String
    ) {
        guard sourceSuperview !== containerView else { return }
        // When Web Inspector is docked, WebKit can inject companion WK* subviews
        // next to the primary WKWebView. Move those with the web view so inspector
        // UI state does not get orphaned in the old host during split churn.
        let relatedSubviews = relatedWebKitTransferSubviews(
            from: sourceSuperview,
            primaryWebView: primaryWebView
        )
        guard !relatedSubviews.isEmpty else { return }
#if DEBUG
        dlog(
            "browser.portal.reparent.batch reason=\(reason) source=\(browserPortalDebugToken(sourceSuperview)) " +
            "container=\(browserPortalDebugToken(containerView)) count=\(relatedSubviews.count) " +
            "sourceType=\(String(describing: type(of: sourceSuperview))) targetType=\(String(describing: type(of: containerView))) " +
            "sourceFlipped=\(sourceSuperview.isFlipped ? 1 : 0) targetFlipped=\(containerView.isFlipped ? 1 : 0) " +
            "sourceBounds=\(browserPortalDebugFrame(sourceSuperview.bounds)) targetBounds=\(browserPortalDebugFrame(containerView.bounds))"
        )
#endif
        for view in relatedSubviews {
            let frameInWindow = sourceSuperview.convert(view.frame, to: nil)
            let className = String(describing: type(of: view))
            view.removeFromSuperview()
            containerView.addSubview(view, positioned: .above, relativeTo: nil)
            let convertedFrame = containerView.convert(frameInWindow, from: nil)
            view.frame = convertedFrame
#if DEBUG
            dlog(
                "browser.portal.reparent.batch.item reason=\(reason) class=\(className) " +
                "view=\(browserPortalDebugToken(view)) frameInWindow=\(browserPortalDebugFrame(frameInWindow)) " +
                "converted=\(browserPortalDebugFrame(convertedFrame))"
            )
#endif
        }
    }

    func detachWebView(withId webViewId: ObjectIdentifier) {
        cancelPendingHostedWebViewRefreshes(for: webViewId)
        guard let entry = entriesByWebViewId.removeValue(forKey: webViewId) else { return }
        if let anchor = entry.anchorView {
            webViewByAnchorId.removeValue(forKey: ObjectIdentifier(anchor))
        }
#if DEBUG
        let hadContainerSuperview = (entry.containerView?.superview === hostView) ? 1 : 0
        let hadWebSuperview = entry.webView?.superview == nil ? 0 : 1
        dlog(
            "browser.portal.detach web=\(browserPortalDebugToken(entry.webView)) " +
            "container=\(browserPortalDebugToken(entry.containerView)) " +
            "anchor=\(browserPortalDebugToken(entry.anchorView)) " +
            "hadContainerSuperview=\(hadContainerSuperview) hadWebSuperview=\(hadWebSuperview)"
        )
#endif
        if let webView = entry.webView, let containerView = entry.containerView {
            notifyHostedWebKitHidden(
                in: containerView,
                primaryWebView: webView,
                reason: "detach"
            )
        } else {
            entry.webView?.browserPortalNotifyHidden(reason: "detach")
        }
        entry.webView?.removeFromSuperview()
        entry.containerView?.removeFromSuperview()
    }

    func discardWebViewEntry(
        withId webViewId: ObjectIdentifier,
        source: String,
        preserveCurrentSuperview: Bool
    ) {
        cancelPendingHostedWebViewRefreshes(for: webViewId)
        guard let entry = entriesByWebViewId.removeValue(forKey: webViewId) else { return }
        if let anchor = entry.anchorView {
            webViewByAnchorId.removeValue(forKey: ObjectIdentifier(anchor))
        }

        let portalOwnsWebView = entry.webView?.superview === entry.containerView
#if DEBUG
        dlog(
            "browser.portal.discard web=\(browserPortalDebugToken(entry.webView)) " +
            "container=\(browserPortalDebugToken(entry.containerView)) " +
            "anchor=\(browserPortalDebugToken(entry.anchorView)) " +
            "source=\(source) preserve=\(preserveCurrentSuperview ? 1 : 0) " +
            "portalOwnsWeb=\(portalOwnsWebView ? 1 : 0) " +
            "currentSuper=\(browserPortalDebugToken(entry.webView?.superview))"
        )
#endif

        if !(preserveCurrentSuperview && !portalOwnsWebView) {
            if let webView = entry.webView, let containerView = entry.containerView {
                notifyHostedWebKitHidden(
                    in: containerView,
                    primaryWebView: webView,
                    reason: "discard:\(source)"
                )
            } else {
                entry.webView?.browserPortalNotifyHidden(reason: "discard:\(source)")
            }
            entry.webView?.removeFromSuperview()
        }
        entry.containerView?.removeFromSuperview()
    }

    /// Update the visibleInUI/zPriority state on an existing entry without rebinding.
    /// Used when a bind is deferred (host not yet in window) so stale portal syncs
    /// do not keep an old anchor visible.
    func updateEntryVisibility(forWebViewId webViewId: ObjectIdentifier, visibleInUI: Bool, zPriority: Int) {
        guard var entry = entriesByWebViewId[webViewId] else { return }
        guard entry.visibleInUI != visibleInUI || entry.zPriority != zPriority else { return }
        entry.visibleInUI = visibleInUI
        entry.zPriority = zPriority
        entriesByWebViewId[webViewId] = entry
    }

    func isWebViewBoundToAnchor(withId webViewId: ObjectIdentifier, anchorView: NSView) -> Bool {
        guard let entry = entriesByWebViewId[webViewId],
              let boundAnchor = entry.anchorView else { return false }
        return boundAnchor === anchorView
    }

    func hideWebView(withId webViewId: ObjectIdentifier, source: String = "externalHide") {
        guard var entry = entriesByWebViewId[webViewId] else { return }
        entry.visibleInUI = false
        entry.zPriority = 0
        entriesByWebViewId[webViewId] = entry
        synchronizeWebView(withId: webViewId, source: source)
    }

    func updateDropZoneOverlay(forWebViewId webViewId: ObjectIdentifier, zone: DropZone?) {
        guard var entry = entriesByWebViewId[webViewId] else { return }
        guard entry.dropZone != zone else { return }
        entry.dropZone = zone
        entriesByWebViewId[webViewId] = entry
        entry.containerView?.setDropZoneOverlay(zone: zone)
    }

    func updatePaneDropContext(forWebViewId webViewId: ObjectIdentifier, context: BrowserPaneDropContext?) {
        guard var entry = entriesByWebViewId[webViewId] else { return }
        guard entry.paneDropContext != context else { return }
        entry.paneDropContext = context
        entriesByWebViewId[webViewId] = entry
        entry.containerView?.setPaneDropContext(context)
    }

    func updateSearchOverlay(
        forWebViewId webViewId: ObjectIdentifier,
        configuration: BrowserPortalSearchOverlayConfiguration?
    ) {
        guard var entry = entriesByWebViewId[webViewId] else { return }
        guard !Self.searchOverlayConfigurationsEquivalent(entry.searchOverlay, configuration) else { return }
        entry.searchOverlay = configuration
        entriesByWebViewId[webViewId] = entry
        entry.containerView?.setSearchOverlay(configuration)
    }

    func searchOverlayPanelId(for responder: NSResponder) -> UUID? {
        for entry in entriesByWebViewId.values {
            if let panelId = entry.containerView?.searchOverlayPanelId(for: responder) {
                return panelId
            }
        }
        return nil
    }

    @discardableResult
    func yieldSearchOverlayFocusIfOwned(by panelId: UUID) -> Bool {
        guard let window else { return false }
        for entry in entriesByWebViewId.values {
            if entry.containerView?.yieldSearchOverlayFocusIfOwned(by: panelId, in: window) == true {
                return true
            }
        }
        return false
    }

    func updatePaneTopChromeHeight(forWebViewId webViewId: ObjectIdentifier, height: CGFloat) {
        guard var entry = entriesByWebViewId[webViewId] else { return }
        let resolvedHeight = max(0, height)
        guard abs(entry.paneTopChromeHeight - resolvedHeight) > 0.5 else { return }
        entry.paneTopChromeHeight = resolvedHeight
        entriesByWebViewId[webViewId] = entry
        entry.containerView?.setPaneTopChromeHeight(resolvedHeight)
    }

    func forceRefreshWebView(withId webViewId: ObjectIdentifier, reason: String) {
        guard ensureInstalled() else { return }
        let refreshSource = "forceRefresh:\(reason)"
        synchronizeWebView(
            withId: webViewId,
            source: refreshSource,
            forcePresentationRefresh: true
        )
        guard let entry = entriesByWebViewId[webViewId],
              let webView = entry.webView,
              let containerView = entry.containerView,
              !containerView.isHidden else {
            return
        }
        // Portal-host replacement/fullscreen churn relies on forceRefresh to kick
        // WebKit even when synchronizeWebView short-circuits or skips its refresh path.
        refreshHostedWebViewPresentation(
            webView,
            in: containerView,
            reason: refreshSource
        )
    }

    func bind(webView: WKWebView, to anchorView: NSView, visibleInUI: Bool, zPriority: Int = 0) {
        guard ensureInstalled() else { return }

        let webViewId = ObjectIdentifier(webView)
        let anchorId = ObjectIdentifier(anchorView)
        let previousEntry = entriesByWebViewId[webViewId]
        let shouldPreserveExternalFullscreenHost =
            webView.programaIsManagedByExternalFullscreenWindow(relativeTo: window)
        let containerView = ensureContainerView(
            for: previousEntry ?? Entry(
                webView: nil,
                containerView: nil,
                anchorView: nil,
                visibleInUI: false,
                zPriority: 0,
                dropZone: nil,
                paneDropContext: nil,
                searchOverlay: nil,
                paneTopChromeHeight: 0,
                transientRecoveryReason: nil,
                transientRecoveryRetriesRemaining: 0
            ),
            webView: webView
        )

        if let previousWebViewId = webViewByAnchorId[anchorId], previousWebViewId != webViewId {
#if DEBUG
            let previousToken = entriesByWebViewId[previousWebViewId]
                .map { browserPortalDebugToken($0.webView) }
                ?? String(describing: previousWebViewId)
            dlog(
                "browser.portal.bind.replace anchor=\(browserPortalDebugToken(anchorView)) " +
                "oldWeb=\(previousToken) newWeb=\(browserPortalDebugToken(webView))"
            )
#endif
            detachWebView(withId: previousWebViewId)
        }

        if let oldEntry = entriesByWebViewId[webViewId],
           let oldAnchor = oldEntry.anchorView,
           oldAnchor !== anchorView {
            webViewByAnchorId.removeValue(forKey: ObjectIdentifier(oldAnchor))
        }

        webViewByAnchorId[anchorId] = webViewId
        entriesByWebViewId[webViewId] = Entry(
            webView: webView,
            containerView: containerView,
            anchorView: anchorView,
            visibleInUI: visibleInUI,
            zPriority: zPriority,
            dropZone: previousEntry?.dropZone,
            paneDropContext: previousEntry?.paneDropContext,
            searchOverlay: previousEntry?.searchOverlay,
            paneTopChromeHeight: previousEntry?.paneTopChromeHeight ?? 0,
            transientRecoveryReason: previousEntry?.transientRecoveryReason,
            transientRecoveryRetriesRemaining: previousEntry?.transientRecoveryRetriesRemaining ?? 0
        )

        let didChangeAnchor: Bool = {
            guard let previousAnchor = previousEntry?.anchorView else { return true }
            return previousAnchor !== anchorView
        }()
        let becameVisible = (previousEntry?.visibleInUI ?? false) == false && visibleInUI
        let priorityIncreased = zPriority > (previousEntry?.zPriority ?? Int.min)
#if DEBUG
        if previousEntry == nil ||
            didChangeAnchor ||
            becameVisible ||
            priorityIncreased ||
            webView.superview !== containerView ||
            containerView.superview !== hostView {
            dlog(
                "browser.portal.bind web=\(browserPortalDebugToken(webView)) " +
                "container=\(browserPortalDebugToken(containerView)) " +
                "anchor=\(browserPortalDebugToken(anchorView)) prevAnchor=\(browserPortalDebugToken(previousEntry?.anchorView)) " +
                "visible=\(visibleInUI ? 1 : 0) prevVisible=\((previousEntry?.visibleInUI ?? false) ? 1 : 0) " +
                "z=\(zPriority) prevZ=\(previousEntry?.zPriority ?? Int.min)"
            )
        }
#endif

        if shouldPreserveExternalFullscreenHost {
#if DEBUG
            dlog(
                "browser.portal.reparent.skip web=\(browserPortalDebugToken(webView)) " +
                "reason=fullscreenExternalHost super=\(browserPortalDebugToken(webView.superview)) " +
                "container=\(browserPortalDebugToken(containerView)) " +
                "state=\(String(describing: webView.fullscreenState))"
            )
#endif
        } else if webView.superview !== containerView {
#if DEBUG
            dlog(
                "browser.portal.reparent web=\(browserPortalDebugToken(webView)) " +
                "reason=attachContainer super=\(browserPortalDebugToken(webView.superview)) " +
                "container=\(browserPortalDebugToken(containerView))"
            )
#endif
            if let sourceSuperview = webView.superview {
                moveWebKitRelatedSubviewsIfNeeded(
                    from: sourceSuperview,
                    to: containerView,
                    primaryWebView: webView,
                    reason: "bind.attachContainer"
                )
            } else {
                containerView.addSubview(webView, positioned: .above, relativeTo: nil)
            }
            containerView.pinHostedWebView(webView)
            webView.needsLayout = true
            webView.layoutSubtreeIfNeeded()
        } else {
            containerView.pinHostedWebView(webView)
        }

        if containerView.superview !== hostView {
#if DEBUG
            dlog(
                "browser.portal.reparent container=\(browserPortalDebugToken(containerView)) " +
                "reason=attach super=\(browserPortalDebugToken(containerView.superview))"
            )
#endif
            hostView.addSubview(containerView, positioned: .above, relativeTo: nil)
        } else if (becameVisible || priorityIncreased), hostView.subviews.last !== containerView {
#if DEBUG
            dlog(
                "browser.portal.reparent container=\(browserPortalDebugToken(containerView)) reason=raise " +
                "didChangeAnchor=\(didChangeAnchor ? 1 : 0) becameVisible=\(becameVisible ? 1 : 0) " +
                "priorityIncreased=\(priorityIncreased ? 1 : 0)"
            )
#endif
            hostView.addSubview(containerView, positioned: .above, relativeTo: nil)
        }

        synchronizeWebView(
            withId: webViewId,
            source: "bind",
            forcePresentationRefresh: didChangeAnchor
        )
        pruneDeadEntries()
    }

    func synchronizeWebViewForAnchor(_ anchorView: NSView) {
        pruneDeadEntries()
        let anchorId = ObjectIdentifier(anchorView)
        let primaryWebViewId = webViewByAnchorId[anchorId]
        if let primaryWebViewId {
            synchronizeWebView(withId: primaryWebViewId, source: "anchorPrimary")
        }

        // During rapid geometry changes (e.g. divider drag), syncing every web view
        // on every frame is expensive and causes stuttering.  Each panel's
        // HostContainerView fires its own geometry callback, so secondary web views
        // will sync themselves.  Defer the all-sync to coalesce with the next
        // run-loop turn instead.
        scheduleDeferredFullSynchronizeAll()
    }

    private func scheduleDeferredFullSynchronizeAll() {
        guard !hasDeferredFullSyncScheduled else { return }
        hasDeferredFullSyncScheduled = true
#if DEBUG
        dlog("browser.portal.sync.defer.schedule entries=\(entriesByWebViewId.count)")
#endif
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hasDeferredFullSyncScheduled = false
#if DEBUG
            dlog("browser.portal.sync.defer.tick entries=\(self.entriesByWebViewId.count)")
#endif
            self.synchronizeAllWebViews(excluding: nil, source: "deferredTick")
        }
    }

    private func synchronizeAllWebViews(excluding webViewIdToSkip: ObjectIdentifier?, source: String) {
        guard ensureInstalled() else { return }
        pruneDeadEntries()
        let webViewIds = Array(entriesByWebViewId.keys)
        for webViewId in webViewIds {
            if webViewId == webViewIdToSkip { continue }
            synchronizeWebView(withId: webViewId, source: source)
        }
    }

    private func resetTransientRecoveryRetryIfNeeded(forWebViewId webViewId: ObjectIdentifier, entry: inout Entry) {
        guard entry.transientRecoveryRetriesRemaining != 0 || entry.transientRecoveryReason != nil else { return }
        entry.transientRecoveryReason = nil
        entry.transientRecoveryRetriesRemaining = 0
        entriesByWebViewId[webViewId] = entry
    }

    private func scheduleTransientRecoveryRetryIfNeeded(
        forWebViewId webViewId: ObjectIdentifier,
        entry: inout Entry,
        webView: WKWebView,
        reason: String
    ) -> Bool {
        if entry.transientRecoveryReason != reason {
            entry.transientRecoveryReason = reason
            entry.transientRecoveryRetriesRemaining = Self.transientRecoveryRetryBudget
        }
#if DEBUG
        if entry.transientRecoveryRetriesRemaining <= 0 {
            dlog(
                "browser.portal.sync.deferRecover.skip web=\(browserPortalDebugToken(webView)) " +
                "reason=\(reason) exhausted=1"
            )
        }
#endif
        guard entry.transientRecoveryRetriesRemaining > 0 else { return false }

        entry.transientRecoveryRetriesRemaining -= 1
        entriesByWebViewId[webViewId] = entry
#if DEBUG
        dlog(
            "browser.portal.sync.deferRecover web=\(browserPortalDebugToken(webView)) " +
            "reason=\(reason) remaining=\(entry.transientRecoveryRetriesRemaining)"
        )
#endif
        if entry.transientRecoveryRetriesRemaining > 0 {
            scheduleDeferredFullSynchronizeAll()
        }
        return true
    }

    private func synchronizeWebView(
        withId webViewId: ObjectIdentifier,
        source: String,
        forcePresentationRefresh: Bool = false
    ) {
        guard ensureInstalled() else { return }
        guard var entry = entriesByWebViewId[webViewId] else { return }
        guard let webView = entry.webView else {
            entriesByWebViewId.removeValue(forKey: webViewId)
            return
        }
        guard let containerView = entry.containerView else {
            entriesByWebViewId.removeValue(forKey: webViewId)
            if let anchor = entry.anchorView {
                webViewByAnchorId.removeValue(forKey: ObjectIdentifier(anchor))
            }
            return
        }
        let previousTransientRecoveryReason = entry.transientRecoveryReason
        func hideContainerView(reason: String) {
            cancelPendingHostedWebViewRefreshes(for: webViewId)
            containerView.setPaneTopChromeHeight(0)
            containerView.setSearchOverlay(nil)
            containerView.setPaneDropContext(nil)
            containerView.setPortalDragDropZone(nil)
            containerView.setDropZoneOverlay(zone: nil)
            // Tab/workspace visibility changes should hide the portal slot without forcing
            // WebKit through `_exitInWindow`/`_enterInWindow`, which fires visibilitychange
            // and can trigger page reloads. Reserve the full lifecycle notify for cases
            // where the visible surface is actually leaving the window/render tree; for a
            // simple visibility toggle, still flag that the next reveal should nudge
            // WebKit's rendering state back in (just un-hiding the container isn't enough
            // to resume compositing).
            if !containerView.isHidden, webView.superview === containerView {
                if entry.visibleInUI {
                    notifyHostedWebKitHidden(
                        in: containerView,
                        primaryWebView: webView,
                        reason: reason
                    )
                } else {
                    for webKitSubview in hostedWebKitSubviews(in: containerView, primaryWebView: webView) {
                        webKitSubview.browserPortalMarkNeedsRenderingStateReattach()
                    }
                }
            }
            containerView.isHidden = true
        }
        func scheduleTransientDetachRecovery(reason: String) -> Bool {
            guard entry.visibleInUI else { return false }
            return scheduleTransientRecoveryRetryIfNeeded(
                forWebViewId: webViewId,
                entry: &entry,
                webView: webView,
                reason: reason
            )
        }
        func preserveVisibleDuringTransientDetach(reason: String) -> Bool {
            guard entry.visibleInUI, !containerView.isHidden else { return false }
            let didScheduleTransientRecovery = scheduleTransientRecoveryRetryIfNeeded(
                forWebViewId: webViewId,
                entry: &entry,
                webView: webView,
                reason: reason
            )
            guard didScheduleTransientRecovery else { return false }
#if DEBUG
            dlog(
                "browser.portal.hidden.deferKeep web=\(browserPortalDebugToken(webView)) " +
                "reason=\(reason) frame=\(browserPortalDebugFrame(containerView.frame))"
            )
#endif
            containerView.setPaneDropContext(nil)
            containerView.setPortalDragDropZone(nil)
            containerView.setDropZoneOverlay(zone: nil)
            return true
        }
        guard let anchorView = entry.anchorView, let window else {
            if preserveVisibleDuringTransientDetach(reason: "missingAnchorOrWindow") {
                return
            }
            if scheduleTransientDetachRecovery(reason: "missingAnchorOrWindow") {
                hideContainerView(reason: "missingAnchorOrWindow")
                return
            }
            if !entry.visibleInUI {
                resetTransientRecoveryRetryIfNeeded(forWebViewId: webViewId, entry: &entry)
            }
#if DEBUG
            if !containerView.isHidden {
                dlog(
                    "browser.portal.hidden container=\(browserPortalDebugToken(containerView)) " +
                    "web=\(browserPortalDebugToken(webView)) value=1 reason=missingAnchorOrWindow"
                )
            }
#endif
            hideContainerView(reason: "missingAnchorOrWindow")
            return
        }
        guard anchorView.window === window else {
            let isOffWindowReparent =
                entry.visibleInUI &&
                anchorView.window == nil &&
                anchorView.superview != nil
            if isOffWindowReparent {
                if preserveVisibleDuringTransientDetach(reason: "anchorWindowMismatch.offWindow") {
                    return
                }
                if scheduleTransientDetachRecovery(reason: "anchorWindowMismatch") {
                    hideContainerView(reason: "anchorWindowMismatch")
                    return
                }
            } else if anchorView.superview != nil {
                // Anchor is parented somewhere (just not under this window) but not via
                // the off-window-reparent pattern above (e.g. visibleInUI already false).
                // Still parented is a meaningfully weaker "gone" signal than no superview
                // at all, so keep the same lenient grace period.
                if preserveVisibleDuringTransientDetach(reason: "anchorWindowMismatch") {
                    return
                }
                if scheduleTransientDetachRecovery(reason: "anchorWindowMismatch") {
                    hideContainerView(reason: "anchorWindowMismatch")
                    return
                }
            }
            // Reached when either: the anchor has no superview at all (a much
            // stronger "genuinely gone" signal than an off-window-but-still-parented
            // reparent mid-drag, so no grace period was granted above), or the grace
            // period above was granted but is now exhausted/not applicable. Hide now.
#if DEBUG
            if !containerView.isHidden {
                dlog(
                    "browser.portal.hidden container=\(browserPortalDebugToken(containerView)) " +
                    "web=\(browserPortalDebugToken(webView)) value=1 " +
                    "reason=anchorWindowMismatch anchorWindow=\(browserPortalDebugToken(anchorView.window?.contentView))"
                )
            }
#endif
            if !entry.visibleInUI {
                resetTransientRecoveryRetryIfNeeded(forWebViewId: webViewId, entry: &entry)
            }
            hideContainerView(reason: "anchorWindowMismatch")
            return
        }

        var refreshReasons: [String] = []
        if containerView.superview !== hostView {
#if DEBUG
            dlog(
                "browser.portal.reparent container=\(browserPortalDebugToken(containerView)) " +
                "reason=syncAttach super=\(browserPortalDebugToken(containerView.superview))"
            )
#endif
            hostView.addSubview(containerView, positioned: .above, relativeTo: nil)
            refreshReasons.append("syncAttachContainer")
        }
        let shouldPreserveExternalFullscreenHost =
            webView.programaIsManagedByExternalFullscreenWindow(relativeTo: window)
        let shouldPreserveExternalHostForHiddenEntry =
            !shouldPreserveExternalFullscreenHost &&
            !entry.visibleInUI &&
            webView.superview !== containerView
        if shouldPreserveExternalFullscreenHost {
#if DEBUG
            dlog(
                "browser.portal.reparent.skip web=\(browserPortalDebugToken(webView)) " +
                "reason=fullscreenExternalHost super=\(browserPortalDebugToken(webView.superview)) " +
                "container=\(browserPortalDebugToken(containerView)) " +
                "state=\(String(describing: webView.fullscreenState))"
            )
#endif
        } else if shouldPreserveExternalHostForHiddenEntry {
#if DEBUG
            dlog(
                "browser.portal.reparent.skip web=\(browserPortalDebugToken(webView)) " +
                "reason=hiddenEntryExternalHost super=\(browserPortalDebugToken(webView.superview)) " +
                "container=\(browserPortalDebugToken(containerView))"
            )
#endif
        } else if webView.superview !== containerView {
#if DEBUG
            dlog(
                "browser.portal.reparent web=\(browserPortalDebugToken(webView)) " +
                "reason=syncAttachContainer super=\(browserPortalDebugToken(webView.superview)) " +
                "container=\(browserPortalDebugToken(containerView))"
            )
#endif
            if let sourceSuperview = webView.superview {
                moveWebKitRelatedSubviewsIfNeeded(
                    from: sourceSuperview,
                    to: containerView,
                    primaryWebView: webView,
                    reason: "sync.attachContainer"
                )
            } else {
                containerView.addSubview(webView, positioned: .above, relativeTo: nil)
            }
            containerView.pinHostedWebView(webView)
            refreshReasons.append("syncAttachWebView")
        } else {
            containerView.pinHostedWebView(webView)
        }

        _ = synchronizeHostFrameToReference()
        let frameInWindow = effectiveAnchorFrameInWindow(for: anchorView)
        let frameInHostRaw = hostView.convert(frameInWindow, from: nil)
        let frameInHost = Self.pixelSnappedRect(frameInHostRaw, in: hostView)
        let hostBounds = hostView.bounds
        let hasFiniteHostBounds =
            hostBounds.origin.x.isFinite &&
            hostBounds.origin.y.isFinite &&
            hostBounds.size.width.isFinite &&
            hostBounds.size.height.isFinite
        let hostBoundsReady = hasFiniteHostBounds && hostBounds.width > 1 && hostBounds.height > 1
        if !hostBoundsReady {
#if DEBUG
            dlog(
                "browser.portal.sync.defer container=\(browserPortalDebugToken(containerView)) " +
                "web=\(browserPortalDebugToken(webView)) " +
                "reason=hostBoundsNotReady host=\(browserPortalDebugFrame(hostBounds)) " +
                "anchor=\(browserPortalDebugFrame(frameInHost)) visibleInUI=\(entry.visibleInUI ? 1 : 0)"
            )
#endif
            if entry.visibleInUI {
                let shouldPreserveVisibleOnTransient = !containerView.isHidden &&
                    scheduleTransientRecoveryRetryIfNeeded(
                        forWebViewId: webViewId,
                        entry: &entry,
                        webView: webView,
                        reason: "hostBoundsNotReady"
                    )
                if shouldPreserveVisibleOnTransient {
#if DEBUG
                    dlog(
                        "browser.portal.hidden.deferKeep web=\(browserPortalDebugToken(webView)) " +
                        "reason=hostBoundsNotReady frame=\(browserPortalDebugFrame(containerView.frame))"
                    )
#endif
                    containerView.setPaneDropContext(nil)
                    containerView.setPortalDragDropZone(nil)
                    containerView.setDropZoneOverlay(zone: nil)
                    return
                }
            } else {
                resetTransientRecoveryRetryIfNeeded(forWebViewId: webViewId, entry: &entry)
            }
            hideContainerView(reason: "hostBoundsNotReady")
            if entry.visibleInUI {
                _ = scheduleTransientRecoveryRetryIfNeeded(
                    forWebViewId: webViewId,
                    entry: &entry,
                    webView: webView,
                    reason: "hostBoundsNotReady"
                )
            } else {
                scheduleDeferredFullSynchronizeAll()
            }
            containerView.setPaneTopChromeHeight(0)
            return
        }
        let oldFrame = containerView.frame
        let hasFiniteFrame =
            frameInHost.origin.x.isFinite &&
            frameInHost.origin.y.isFinite &&
            frameInHost.size.width.isFinite &&
            frameInHost.size.height.isFinite
        let clampedFrame = frameInHost.intersection(hostBounds)
        let hasVisibleIntersection =
            !clampedFrame.isNull &&
            clampedFrame.width > 1 &&
            clampedFrame.height > 1
        let targetFrame = hasVisibleIntersection ? clampedFrame : frameInHost
        let anchorHidden = Self.isHiddenOrAncestorHidden(anchorView)
        let tinyFrame = targetFrame.width <= 1 || targetFrame.height <= 1
        let outsideHostBounds = !hasVisibleIntersection
        let shouldHide =
            !entry.visibleInUI ||
            anchorHidden ||
            tinyFrame ||
            !hasFiniteFrame ||
            outsideHostBounds
        let transientRecoveryReason: String? = {
            guard entry.visibleInUI else { return nil }
            if anchorHidden { return "anchorHidden" }
            if !hasFiniteFrame { return "nonFiniteFrame" }
            if outsideHostBounds { return "outsideHostBounds" }
            if tinyFrame { return "tinyFrame" }
            return nil
        }()
        let didScheduleTransientRecovery: Bool = {
            guard let transientRecoveryReason else { return false }
            return scheduleTransientRecoveryRetryIfNeeded(
                forWebViewId: webViewId,
                entry: &entry,
                webView: webView,
                reason: transientRecoveryReason
            )
        }()
        let shouldPreserveVisibleOnTransientGeometry =
            didScheduleTransientRecovery &&
            shouldHide &&
            entry.visibleInUI &&
            !containerView.isHidden
        let recoveredFromTransientGeometry =
            previousTransientRecoveryReason != nil &&
            transientRecoveryReason == nil &&
            !shouldHide
#if DEBUG
        let frameWasClamped = hasFiniteFrame && !Self.rectApproximatelyEqual(frameInHost, targetFrame)
        if frameWasClamped {
            dlog(
                "browser.portal.frame.clamp container=\(browserPortalDebugToken(containerView)) " +
                "web=\(browserPortalDebugToken(webView)) anchor=\(browserPortalDebugToken(anchorView)) " +
                "raw=\(browserPortalDebugFrame(frameInHost)) clamped=\(browserPortalDebugFrame(targetFrame)) " +
                "host=\(browserPortalDebugFrame(hostBounds))"
            )
        }
        let collapsedToTiny = oldFrame.width > 1 && oldFrame.height > 1 && tinyFrame
        let restoredFromTiny = (oldFrame.width <= 1 || oldFrame.height <= 1) && !tinyFrame
        if collapsedToTiny {
            dlog(
                "browser.portal.frame.collapse container=\(browserPortalDebugToken(containerView)) " +
                "web=\(browserPortalDebugToken(webView)) anchor=\(browserPortalDebugToken(anchorView)) " +
                "old=\(browserPortalDebugFrame(oldFrame)) new=\(browserPortalDebugFrame(targetFrame))"
            )
        } else if restoredFromTiny {
            dlog(
                "browser.portal.frame.restore container=\(browserPortalDebugToken(containerView)) " +
                "web=\(browserPortalDebugToken(webView)) anchor=\(browserPortalDebugToken(anchorView)) " +
                "old=\(browserPortalDebugFrame(oldFrame)) new=\(browserPortalDebugFrame(targetFrame))"
            )
        }
#endif
        if shouldPreserveVisibleOnTransientGeometry {
            let hasExistingVisibleFrame =
                oldFrame.width > 1 &&
                oldFrame.height > 1 &&
                containerView.bounds.width > 1 &&
                containerView.bounds.height > 1
#if DEBUG
            dlog(
                "browser.portal.hidden.deferKeep web=\(browserPortalDebugToken(webView)) " +
                "reason=\(transientRecoveryReason ?? "unknown") frame=\(browserPortalDebugFrame(containerView.frame)) " +
                "keepFrame=\(hasExistingVisibleFrame ? 1 : 0)"
            )
#endif
            if hasExistingVisibleFrame {
                containerView.setDropZoneOverlay(zone: nil)
                containerView.setPaneDropContext(nil)
                containerView.setPortalDragDropZone(nil)
                return
            }
        }
        if !Self.rectApproximatelyEqual(oldFrame, targetFrame) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            containerView.frame = targetFrame
            CATransaction.commit()
            refreshReasons.append("frame")
        }

        let expectedContainerBounds = NSRect(origin: .zero, size: targetFrame.size)
        if !Self.rectApproximatelyEqual(containerView.bounds, expectedContainerBounds) {
            let oldContainerBounds = containerView.bounds
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            containerView.bounds = expectedContainerBounds
            CATransaction.commit()
#if DEBUG
            dlog(
                "browser.portal.bounds.normalize container=\(browserPortalDebugToken(containerView)) " +
                "web=\(browserPortalDebugToken(webView)) old=\(browserPortalDebugFrame(oldContainerBounds)) " +
                "target=\(browserPortalDebugFrame(expectedContainerBounds))"
            )
#endif
            refreshReasons.append("bounds")
        }

        let containerOwnsWebView = webView.superview === containerView
        let containerBounds = containerView.bounds
        let preNormalizeWebFrame = containerOwnsWebView ? webView.frame : .zero
        let inspectorHeightFromInsets = max(0, containerBounds.height - preNormalizeWebFrame.height)
        let inspectorHeightFromOverflow = max(0, preNormalizeWebFrame.maxY - containerBounds.maxY)
        let inspectorHeightApprox = max(inspectorHeightFromInsets, inspectorHeightFromOverflow)
#if DEBUG
        let inspectorSubviews = Self.inspectorSubviewCount(in: containerView)
#endif
        if containerOwnsWebView,
           let repairedBottomDockFrame = Self.repairedBottomDockedPageFrame(
               in: containerView,
               primaryWebView: webView
           ) {
            let oldWebFrame = preNormalizeWebFrame
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            webView.frame = repairedBottomDockFrame
            CATransaction.commit()
#if DEBUG
            dlog(
                "browser.portal.webframe.bottomDockRepair web=\(browserPortalDebugToken(webView)) " +
                "container=\(browserPortalDebugToken(containerView)) old=\(browserPortalDebugFrame(oldWebFrame)) " +
                "new=\(browserPortalDebugFrame(repairedBottomDockFrame)) bounds=\(browserPortalDebugFrame(containerBounds)) " +
                "inspectorHApprox=\(String(format: "%.1f", inspectorHeightApprox)) " +
                "inspectorInsets=\(String(format: "%.1f", inspectorHeightFromInsets)) " +
                "inspectorOverflow=\(String(format: "%.1f", inspectorHeightFromOverflow)) " +
                "inspectorSubviews=\(inspectorSubviews) " +
                "source=\(source)"
            )
#endif
            refreshReasons.append("webFrameBottomDock")
        } else if containerOwnsWebView && Self.frameExtendsOutsideBounds(preNormalizeWebFrame, bounds: containerBounds) {
            let oldWebFrame = preNormalizeWebFrame
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            webView.frame = containerBounds
            CATransaction.commit()
#if DEBUG
            dlog(
                "browser.portal.webframe.normalize web=\(browserPortalDebugToken(webView)) " +
                "container=\(browserPortalDebugToken(containerView)) old=\(browserPortalDebugFrame(oldWebFrame)) " +
                "new=\(browserPortalDebugFrame(webView.frame)) bounds=\(browserPortalDebugFrame(containerBounds)) " +
                "inspectorHApprox=\(String(format: "%.1f", inspectorHeightApprox)) " +
                "inspectorInsets=\(String(format: "%.1f", inspectorHeightFromInsets)) " +
                "inspectorOverflow=\(String(format: "%.1f", inspectorHeightFromOverflow)) " +
                "inspectorSubviews=\(inspectorSubviews) " +
                "source=\(source)"
            )
#endif
            refreshReasons.append("webFrame")
        }

        let revealedForDisplay = !shouldHide && containerView.isHidden
        if shouldHide, !containerView.isHidden, !shouldPreserveVisibleOnTransientGeometry {
#if DEBUG
            dlog(
                "browser.portal.hidden container=\(browserPortalDebugToken(containerView)) " +
                "web=\(browserPortalDebugToken(webView)) value=\(shouldHide ? 1 : 0) " +
                "visibleInUI=\(entry.visibleInUI ? 1 : 0) anchorHidden=\(anchorHidden ? 1 : 0) " +
                "tiny=\(tinyFrame ? 1 : 0) finite=\(hasFiniteFrame ? 1 : 0) " +
                    "outside=\(outsideHostBounds ? 1 : 0) frame=\(browserPortalDebugFrame(targetFrame)) " +
                    "host=\(browserPortalDebugFrame(hostBounds))"
            )
#endif
            hideContainerView(reason: transientRecoveryReason ?? "geometryHidden")
        } else if !shouldHide, containerView.isHidden {
#if DEBUG
            dlog(
                "browser.portal.hidden container=\(browserPortalDebugToken(containerView)) " +
                "web=\(browserPortalDebugToken(webView)) value=0 " +
                "visibleInUI=\(entry.visibleInUI ? 1 : 0) anchorHidden=\(anchorHidden ? 1 : 0) " +
                "tiny=\(tinyFrame ? 1 : 0) finite=\(hasFiniteFrame ? 1 : 0) " +
                "outside=\(outsideHostBounds ? 1 : 0) frame=\(browserPortalDebugFrame(targetFrame)) " +
                "host=\(browserPortalDebugFrame(hostBounds))"
            )
#endif
            containerView.isHidden = false
        }
        containerView.setPaneTopChromeHeight(shouldHide ? 0 : entry.paneTopChromeHeight)
        containerView.setSearchOverlay(shouldHide ? nil : entry.searchOverlay)
        containerView.setPaneDropContext(containerView.isHidden ? nil : entry.paneDropContext)
        containerView.setDropZoneOverlay(zone: containerView.isHidden ? nil : entry.dropZone)
        if revealedForDisplay {
            refreshReasons.append("reveal")
        }
        if recoveredFromTransientGeometry {
            // Drag/reparent churn can recover to the same visible frame we preserved.
            // Force a redraw so WebKit doesn't keep stale tiles until a later resize/focus.
            refreshReasons.append("transientRecovery")
        }
        if forcePresentationRefresh {
            refreshReasons.append("anchor")
        }
        if transientRecoveryReason == nil {
            resetTransientRecoveryRetryIfNeeded(forWebViewId: webViewId, entry: &entry)
        }
        let hostedInspectorAdjustedDuringSync =
            containerOwnsWebView &&
            hostView.reapplyHostedInspectorDividerIfNeeded(in: containerView, reason: "portal.sync")
        let requiresRenderingStateReattach = webView.browserPortalRequiresRenderingStateReattach
        let presentationUpdateKind = HostedWebViewPresentationUpdateKind.resolve(
            reasons: refreshReasons
        )
        let shouldReapplyHostedInspectorPostRefresh =
            presentationUpdateKind == .refresh && requiresRenderingStateReattach
        if !shouldHide, containerOwnsWebView, presentationUpdateKind != .none {
            if presentationUpdateKind == .refresh &&
                hostedInspectorAdjustedDuringSync &&
                !recoveredFromTransientGeometry &&
                !requiresRenderingStateReattach {
#if DEBUG
                dlog(
                    "browser.portal.refresh.skip web=\(browserPortalDebugToken(webView)) " +
                    "container=\(browserPortalDebugToken(containerView)) reason=\(source):" +
                    "\(refreshReasons.joined(separator: ",")) adjustedDuringSync=1"
                )
#endif
            } else {
                let refreshReason = "\(source):" + refreshReasons.joined(separator: ",")
                switch presentationUpdateKind {
                case .none:
                    break
                case .geometryOnly:
                    invalidateHostedWebViewGeometry(
                        webView,
                        in: containerView,
                        reason: refreshReason
                    )
                case .refresh:
                    refreshHostedWebViewPresentation(
                        webView,
                        in: containerView,
                        reason: refreshReason
                    )
                }
            }
        }
        if containerOwnsWebView,
           (!hostedInspectorAdjustedDuringSync || shouldReapplyHostedInspectorPostRefresh) {
            // Keep the existing post-sync pass for cases where the inspector candidate
            // appears only after WebKit settles. Re-run it after rendering-state reattach
            // refreshes as well, because WebKit's enter/unhide relayout can overwrite the
            // preferred divider position we already clamped during portal.sync.
            _ = hostView.reapplyHostedInspectorDividerIfNeeded(in: containerView, reason: "portal.sync.postRefresh")
        }
#if DEBUG
        dlog(
            "browser.portal.sync.result web=\(browserPortalDebugToken(webView)) source=\(source) " +
            "container=\(browserPortalDebugToken(containerView)) " +
            "anchor=\(browserPortalDebugToken(anchorView)) host=\(browserPortalDebugToken(hostView)) " +
            "hostWin=\(hostView.window?.windowNumber ?? -1) " +
            "old=\(browserPortalDebugFrame(oldFrame)) raw=\(browserPortalDebugFrame(frameInHost)) " +
            "target=\(browserPortalDebugFrame(targetFrame)) hide=\(shouldHide ? 1 : 0) " +
            "entryVisible=\(entry.visibleInUI ? 1 : 0) " +
            "containerOwnsWeb=\(containerOwnsWebView ? 1 : 0) " +
            "inspectorAdjusted=\(hostedInspectorAdjustedDuringSync ? 1 : 0) " +
            "containerHidden=\(containerView.isHidden ? 1 : 0) webHidden=\(webView.isHidden ? 1 : 0) " +
            "containerBounds=\(browserPortalDebugFrame(containerView.bounds)) " +
            "preWebFrame=\(browserPortalDebugFrame(preNormalizeWebFrame)) " +
            "webFrame=\(browserPortalDebugFrame(webView.frame)) webBounds=\(browserPortalDebugFrame(webView.bounds)) " +
            "inspectorHApprox=\(String(format: "%.1f", inspectorHeightApprox)) " +
            "inspectorInsets=\(String(format: "%.1f", inspectorHeightFromInsets)) " +
            "inspectorOverflow=\(String(format: "%.1f", inspectorHeightFromOverflow)) " +
            "inspectorSubviews=\(inspectorSubviews)"
        )
#endif
    }

    private func pruneDeadEntries() {
        let currentWindow = window
        let deadWebViewIds = entriesByWebViewId.compactMap { webViewId, entry -> ObjectIdentifier? in
            guard entry.webView != nil else { return webViewId }
            guard let container = entry.containerView else { return webViewId }
            guard let anchor = entry.anchorView else {
                // Workspace switching hides retiring browser portals before SwiftUI unmounts
                // their anchor views. Keep the hidden WKWebView/slot alive so switching back
                // can rebind the existing view instead of forcing a full WebKit reload.
                return nil
            }
            if container.superview == nil || !container.isDescendant(of: hostView) {
                return webViewId
            }
            let anchorInvalidForCurrentHost =
                anchor.window !== currentWindow ||
                anchor.superview == nil ||
                (installedReferenceView.map { !anchor.isDescendant(of: $0) } ?? false)
            if anchorInvalidForCurrentHost {
                // Hidden browser portals can legitimately be off-tree between workspace
                // deactivation and the next rebind. Preserve them until an explicit detach
                // (panel close, window teardown, or web view replacement) says otherwise.
                return nil
            }
            return nil
        }

        for webViewId in deadWebViewIds {
            detachWebView(withId: webViewId)
        }

        let validAnchorIds = Set(entriesByWebViewId.compactMap { _, entry in
            entry.anchorView.map { ObjectIdentifier($0) }
        })
        webViewByAnchorId = webViewByAnchorId.filter { validAnchorIds.contains($0.key) }
    }

    func webViewIds() -> Set<ObjectIdentifier> {
        Set(entriesByWebViewId.keys)
    }

    func tearDown() {
        removeGeometryObservers()
        for webViewId in Array(entriesByWebViewId.keys) {
            detachWebView(withId: webViewId)
        }
        hostView.removeFromSuperview()
        installedContainerView = nil
        installedReferenceView = nil
    }

#if DEBUG
    func debugEntryCount() -> Int {
        entriesByWebViewId.count
    }
#endif

    func debugSnapshot(forWebViewId webViewId: ObjectIdentifier) -> BrowserWindowPortalRegistry.DebugSnapshot? {
        guard let entry = entriesByWebViewId[webViewId] else { return nil }
        let frameInWindow: CGRect = {
            guard let container = entry.containerView, container.window != nil else { return .zero }
            return container.convert(container.bounds, to: nil)
        }()
        return BrowserWindowPortalRegistry.DebugSnapshot(
            visibleInUI: entry.visibleInUI,
            containerHidden: entry.containerView?.isHidden ?? true,
            frameInWindow: frameInWindow
        )
    }

    func webViewAtWindowPoint(_ windowPoint: NSPoint) -> WKWebView? {
        guard ensureInstalled() else { return nil }
        let point = hostView.convert(windowPoint, from: nil)
        for subview in hostView.subviews.reversed() {
            guard let container = subview as? WindowBrowserSlotView else { continue }
            guard !container.isHidden else { continue }
            guard container.frame.contains(point) else { continue }
            guard let webView = entriesByWebViewId
                .first(where: { _, entry in entry.containerView === container })?
                .value
                .webView else { continue }
            return webView
        }
        return nil
    }
}

@MainActor
enum BrowserWindowPortalRegistry {
    struct DebugSnapshot {
        let visibleInUI: Bool
        let containerHidden: Bool
        let frameInWindow: CGRect
    }

    private static var portalsByWindowId: [ObjectIdentifier: WindowBrowserPortal] = [:]
    private static var webViewToWindowId: [ObjectIdentifier: ObjectIdentifier] = [:]

    private static func postRegistryDidChange(for webView: WKWebView) {
        NotificationCenter.default.post(name: .browserPortalRegistryDidChange, object: webView)
    }

    private static func installWindowCloseObserverIfNeeded(for window: NSWindow) {
        guard objc_getAssociatedObject(window, &programaWindowBrowserPortalCloseObserverKey) == nil else { return }
        let windowId = ObjectIdentifier(window)
        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak window] _ in
            MainActor.assumeIsolated {
                if let window {
                    removePortal(for: window)
                } else {
                    removePortal(windowId: windowId, window: nil)
                }
            }
        }
        objc_setAssociatedObject(
            window,
            &programaWindowBrowserPortalCloseObserverKey,
            observer,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }

    private static func removePortal(for window: NSWindow) {
        removePortal(windowId: ObjectIdentifier(window), window: window)
    }

    private static func removePortal(windowId: ObjectIdentifier, window: NSWindow?) {
        if let portal = portalsByWindowId.removeValue(forKey: windowId) {
            portal.tearDown()
        }
        webViewToWindowId = webViewToWindowId.filter { $0.value != windowId }

        guard let window else { return }
        if let observer = objc_getAssociatedObject(window, &programaWindowBrowserPortalCloseObserverKey) {
            NotificationCenter.default.removeObserver(observer)
        }
        objc_setAssociatedObject(window, &programaWindowBrowserPortalCloseObserverKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        objc_setAssociatedObject(window, &programaWindowBrowserPortalKey, nil, .OBJC_ASSOCIATION_RETAIN)
    }

    private static func pruneWebViewMappings(for windowId: ObjectIdentifier, validWebViewIds: Set<ObjectIdentifier>) {
        webViewToWindowId = webViewToWindowId.filter { webViewId, mappedWindowId in
            mappedWindowId != windowId || validWebViewIds.contains(webViewId)
        }
    }

    private static func portal(for window: NSWindow) -> WindowBrowserPortal {
        if let existing = objc_getAssociatedObject(window, &programaWindowBrowserPortalKey) as? WindowBrowserPortal {
            portalsByWindowId[ObjectIdentifier(window)] = existing
            installWindowCloseObserverIfNeeded(for: window)
            return existing
        }

        let portal = WindowBrowserPortal(window: window)
        objc_setAssociatedObject(window, &programaWindowBrowserPortalKey, portal, .OBJC_ASSOCIATION_RETAIN)
        portalsByWindowId[ObjectIdentifier(window)] = portal
        installWindowCloseObserverIfNeeded(for: window)
        return portal
    }

    static func bind(webView: WKWebView, to anchorView: NSView, visibleInUI: Bool, zPriority: Int = 0) {
        guard let window = anchorView.window else { return }

        let windowId = ObjectIdentifier(window)
        let webViewId = ObjectIdentifier(webView)
        let nextPortal = portal(for: window)

        if let oldWindowId = webViewToWindowId[webViewId],
           oldWindowId != windowId {
            portalsByWindowId[oldWindowId]?.detachWebView(withId: webViewId)
        }

        nextPortal.bind(webView: webView, to: anchorView, visibleInUI: visibleInUI, zPriority: zPriority)
        webViewToWindowId[webViewId] = windowId
        pruneWebViewMappings(for: windowId, validWebViewIds: nextPortal.webViewIds())
        postRegistryDidChange(for: webView)
    }

    static func synchronizeForAnchor(_ anchorView: NSView) {
        guard let window = anchorView.window else { return }
        let portal = portal(for: window)
        portal.synchronizeWebViewForAnchor(anchorView)
    }

    /// Update visibleInUI/zPriority on an existing portal entry without rebinding.
    /// Called when a bind is deferred because the new host is temporarily off-window.
    static func updateEntryVisibility(for webView: WKWebView, visibleInUI: Bool, zPriority: Int) {
        let webViewId = ObjectIdentifier(webView)
        guard let windowId = webViewToWindowId[webViewId],
              let portal = portalsByWindowId[windowId] else { return }
        portal.updateEntryVisibility(forWebViewId: webViewId, visibleInUI: visibleInUI, zPriority: zPriority)
        postRegistryDidChange(for: webView)
    }

    static func isWebView(_ webView: WKWebView, boundTo anchorView: NSView) -> Bool {
        let webViewId = ObjectIdentifier(webView)
        guard let window = anchorView.window else { return false }
        let windowId = ObjectIdentifier(window)
        guard webViewToWindowId[webViewId] == windowId,
              let portal = portalsByWindowId[windowId] else { return false }
        return portal.isWebViewBoundToAnchor(withId: webViewId, anchorView: anchorView)
    }

    static func hide(webView: WKWebView, source: String = "externalHide") {
        let webViewId = ObjectIdentifier(webView)
        guard let windowId = webViewToWindowId[webViewId],
              let portal = portalsByWindowId[windowId] else { return }
        portal.hideWebView(withId: webViewId, source: source)
        postRegistryDidChange(for: webView)
    }

    static func discard(
        webView: WKWebView,
        source: String = "externalDiscard",
        preserveCurrentSuperview: Bool = false
    ) {
        let webViewId = ObjectIdentifier(webView)
        guard let windowId = webViewToWindowId.removeValue(forKey: webViewId),
              let portal = portalsByWindowId[windowId] else { return }
        portal.discardWebViewEntry(
            withId: webViewId,
            source: source,
            preserveCurrentSuperview: preserveCurrentSuperview
        )
        postRegistryDidChange(for: webView)
    }

    static func updateDropZoneOverlay(for webView: WKWebView, zone: DropZone?) {
        let webViewId = ObjectIdentifier(webView)
        guard let windowId = webViewToWindowId[webViewId],
              let portal = portalsByWindowId[windowId] else { return }
        portal.updateDropZoneOverlay(forWebViewId: webViewId, zone: zone)
    }

    static func updatePaneDropContext(for webView: WKWebView, context: BrowserPaneDropContext?) {
        let webViewId = ObjectIdentifier(webView)
        guard let windowId = webViewToWindowId[webViewId],
              let portal = portalsByWindowId[windowId] else { return }
        portal.updatePaneDropContext(forWebViewId: webViewId, context: context)
    }

    static func updateSearchOverlay(
        for webView: WKWebView,
        configuration: BrowserPortalSearchOverlayConfiguration?
    ) {
        let webViewId = ObjectIdentifier(webView)
        guard let windowId = webViewToWindowId[webViewId],
              let portal = portalsByWindowId[windowId] else { return }
        portal.updateSearchOverlay(forWebViewId: webViewId, configuration: configuration)
    }

    static func searchOverlayPanelId(for responder: NSResponder, in window: NSWindow) -> UUID? {
        let windowId = ObjectIdentifier(window)
        guard let portal = portalsByWindowId[windowId] else { return nil }
        return portal.searchOverlayPanelId(for: responder)
    }

    @discardableResult
    static func yieldSearchOverlayFocusIfOwned(by panelId: UUID, in window: NSWindow) -> Bool {
        let windowId = ObjectIdentifier(window)
        guard let portal = portalsByWindowId[windowId] else { return false }
        return portal.yieldSearchOverlayFocusIfOwned(by: panelId)
    }

    static func updatePaneTopChromeHeight(for webView: WKWebView, height: CGFloat) {
        let webViewId = ObjectIdentifier(webView)
        guard let windowId = webViewToWindowId[webViewId],
              let portal = portalsByWindowId[windowId] else { return }
        portal.updatePaneTopChromeHeight(forWebViewId: webViewId, height: height)
    }

    static func detach(webView: WKWebView) {
        let webViewId = ObjectIdentifier(webView)
        guard let windowId = webViewToWindowId.removeValue(forKey: webViewId) else { return }
        portalsByWindowId[windowId]?.detachWebView(withId: webViewId)
        postRegistryDidChange(for: webView)
    }

    static func webViewAtWindowPoint(_ windowPoint: NSPoint, in window: NSWindow) -> WKWebView? {
        let windowId = ObjectIdentifier(window)
        guard let portal = portalsByWindowId[windowId] else { return nil }
        return portal.webViewAtWindowPoint(windowPoint)
    }

    static func refresh(webView: WKWebView, reason: String) {
        let webViewId = ObjectIdentifier(webView)
        guard let windowId = webViewToWindowId[webViewId],
              let portal = portalsByWindowId[windowId] else { return }
        portal.forceRefreshWebView(withId: webViewId, reason: reason)
        postRegistryDidChange(for: webView)
    }

    static func debugSnapshot(for webView: WKWebView) -> DebugSnapshot? {
        let webViewId = ObjectIdentifier(webView)
        guard let windowId = webViewToWindowId[webViewId],
              let portal = portalsByWindowId[windowId] else { return nil }
        return portal.debugSnapshot(forWebViewId: webViewId)
    }

#if DEBUG
    static func debugPortalCount() -> Int {
        portalsByWindowId.count
    }
#endif
}
