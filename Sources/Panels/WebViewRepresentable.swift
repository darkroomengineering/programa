import Bonsplit
import SwiftUI
import WebKit
import AppKit
import ObjectiveC

struct WebViewRepresentable: NSViewRepresentable {
    let panel: BrowserPanel
    let paneId: PaneID
    let shouldAttachWebView: Bool
    let useLocalInlineHosting: Bool
    let shouldFocusWebView: Bool
    let isPanelFocused: Bool
    let portalZPriority: Int
    let paneDropZone: DropZone?
    let searchOverlay: BrowserPortalSearchOverlayConfiguration?
    let paneTopChromeHeight: CGFloat

    final class Coordinator {
        weak var panel: BrowserPanel?
        weak var webView: WKWebView?
        var attachGeneration: Int = 0
        var desiredPortalVisibleInUI: Bool = true
        var desiredPortalZPriority: Int = 0
        var lastPortalHostId: ObjectIdentifier?
        var lastSynchronizedHostGeometryRevision: UInt64 = 0
    }

    final class HostContainerView: NSView {
        private final class HostedInspectorSideDockContainerView: NSView {
            override init(frame frameRect: NSRect) {
                super.init(frame: frameRect)
                wantsLayer = true
                layer?.masksToBounds = true
            }

            @available(*, unavailable)
            required init?(coder: NSCoder) {
                nil
            }

            override var isOpaque: Bool { false }

            override func resizeSubviews(withOldSize oldSize: NSSize) {
                // Managed side-docked DevTools use explicit frame updates from the host.
                // Letting AppKit autoresize the WK siblings here makes them snap back to
                // stale widths while the divider drag or pane resize is in flight.
            }
        }

        var onDidMoveToWindow: (() -> Void)?
        var onGeometryChanged: (() -> Void)?
        private(set) var geometryRevision: UInt64 = 0
        private var lastReportedGeometryState: GeometryState?
        private var hasPendingGeometryNotification = false
        private weak var hostedWebView: WKWebView?
        private var hostedWebViewConstraints: [NSLayoutConstraint] = []
        private weak var localInlineSlotView: WindowBrowserSlotView?
        private var localInlineSlotConstraints: [NSLayoutConstraint] = []
        private weak var hostedInspectorSideDockContainerView: HostedInspectorSideDockContainerView?
        private var hostedInspectorSideDockConstraints: [NSLayoutConstraint] = []
        private weak var hostedInspectorFrontendWebView: WKWebView?
        private struct HostedInspectorDividerHit {
            let containerView: NSView
            let pageView: NSView
            let inspectorView: NSView
            let dockSide: HostedInspectorDockSide
        }

        private struct GeometryState: Equatable {
            let frame: CGRect
            let bounds: CGRect
            let windowNumber: Int?
            let superviewID: ObjectIdentifier?
        }

        private struct HostedInspectorDividerDragState {
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

            var cursor: NSCursor { .resizeLeftRight }
        }

        private static let hostedInspectorDividerHitExpansion: CGFloat = 10
        private static let minimumHostedInspectorWidth: CGFloat = 120
        private static let minimumHostedInspectorPageWidthForSideDock: CGFloat = 240
        private static let adaptiveBottomDockRequestCooldown: TimeInterval = 0.25
        private var trackingArea: NSTrackingArea?
        private var activeDividerCursorKind: DividerCursorKind?
        private var hostedInspectorDividerDrag: HostedInspectorDividerDragState?
        private var preferredHostedInspectorWidth: CGFloat?
        private var preferredHostedInspectorWidthFraction: CGFloat?
        var onPreferredHostedInspectorWidthChanged: ((CGFloat, CGFloat?) -> Void)?
        private weak var hostedInspectorSideDockPageView: NSView?
        private weak var hostedInspectorSideDockInspectorView: NSView?
        private var hostedInspectorSideDockDockSide: HostedInspectorDockSide?
        private var isHostedInspectorDividerDragActive = false
        private var isApplyingHostedInspectorLayout = false
        private var hostedInspectorReapplyWorkItem: DispatchWorkItem?
        private var hostedInspectorDockConfigurationSyncWorkItem: DispatchWorkItem?
        private var adaptiveBottomDockRequestCooldownDeadline: Date?
        private var recordedHostedInspectorSideDockWidth: CGFloat?
        private var lastHostedInspectorManualSideDockAllowed: Bool?
        private var lastHostedInspectorLayoutBoundsSize: NSSize?
#if DEBUG
        private var lastLoggedHostedInspectorFrames: (page: NSRect, inspector: NSRect)?
        private var hasLoggedMissingHostedInspectorCandidate = false
#endif

        deinit {
            hostedInspectorReapplyWorkItem?.cancel()
            hostedInspectorDockConfigurationSyncWorkItem?.cancel()
            if let trackingArea {
                removeTrackingArea(trackingArea)
            }
            clearActiveDividerCursor(restoreArrow: false)
        }

        private func recordPreferredHostedInspectorWidth(_ width: CGFloat, containerBounds: NSRect) {
            preferredHostedInspectorWidth = width
            guard containerBounds.width > 0 else {
                preferredHostedInspectorWidthFraction = nil
                onPreferredHostedInspectorWidthChanged?(width, nil)
                return
            }
            preferredHostedInspectorWidthFraction = width / containerBounds.width
            onPreferredHostedInspectorWidthChanged?(width, preferredHostedInspectorWidthFraction)
        }

        private func resolvedPreferredHostedInspectorWidth(in containerBounds: NSRect) -> CGFloat? {
            if let preferredHostedInspectorWidthFraction, containerBounds.width > 0 {
                return max(0, containerBounds.width * preferredHostedInspectorWidthFraction)
            }
            return preferredHostedInspectorWidth
        }

        func setPreferredHostedInspectorWidth(width: CGFloat?, widthFraction: CGFloat?) {
            preferredHostedInspectorWidth = width
            preferredHostedInspectorWidthFraction = widthFraction
        }

        private func recordHostedInspectorSideDockWidth(_ width: CGFloat) {
            guard width > 1 else { return }
            recordedHostedInspectorSideDockWidth = max(Self.minimumHostedInspectorWidth, width)
        }

        private func shouldAllowHostedInspectorManualSideDock() -> Bool {
            let containerWidth = max(0, bounds.width)
            guard containerWidth > 1 else { return true }
            let baselineWidth = max(
                Self.minimumHostedInspectorWidth,
                recordedHostedInspectorSideDockWidth ?? Self.minimumHostedInspectorWidth
            )
            return containerWidth - baselineWidth >= Self.minimumHostedInspectorPageWidthForSideDock
        }

        private func updateHostedInspectorDockControlAvailabilityIfNeeded(reason: String) {
            guard let hostedInspectorFrontendWebView else {
                lastHostedInspectorManualSideDockAllowed = nil
                return
            }

            let sideDockAllowed = shouldAllowHostedInspectorManualSideDock()
            guard lastHostedInspectorManualSideDockAllowed != sideDockAllowed else { return }
            lastHostedInspectorManualSideDockAllowed = sideDockAllowed

            let sideDockAllowedLiteral = sideDockAllowed ? "true" : "false"
#if DEBUG
            let recordedWidthDesc = recordedHostedInspectorSideDockWidth.map {
                String(format: "%.1f", $0)
            } ?? "nil"
            dlog(
                "browser.panel.hostedInspector stage=\(reason).dockControls " +
                "host=\(Self.debugObjectID(self)) allowSideDock=\(sideDockAllowed ? 1 : 0) " +
                "recordedWidth=\(recordedWidthDesc) bounds=\(Self.debugRect(bounds))"
            )
#endif
            hostedInspectorFrontendWebView.evaluateJavaScript(
                """
                (() => {
                    if (typeof WI === "undefined")
                        return null;
                    const allowSideDock = \(sideDockAllowedLiteral);
                    if (!WI.__programaOriginalUpdateDockNavigationItems && typeof WI._updateDockNavigationItems === "function")
                        WI.__programaOriginalUpdateDockNavigationItems = WI._updateDockNavigationItems;
                    if (!WI.__programaOriginalDockLeft && typeof WI._dockLeft === "function")
                        WI.__programaOriginalDockLeft = WI._dockLeft;
                    if (!WI.__programaOriginalDockRight && typeof WI._dockRight === "function")
                        WI.__programaOriginalDockRight = WI._dockRight;
                    if (!WI.__programaOriginalTogglePreviousDockConfiguration && typeof WI._togglePreviousDockConfiguration === "function")
                        WI.__programaOriginalTogglePreviousDockConfiguration = WI._togglePreviousDockConfiguration;
                    function callOriginal(fn, event) {
                        return typeof fn === "function" ? fn.call(WI, event) : null;
                    }
                    function updateButton(button, hidden) {
                        if (!button)
                            return;
                        button.hidden = hidden;
                        if (button.element) {
                            button.element.style.display = hidden ? "none" : "";
                            button.element.style.pointerEvents = hidden ? "none" : "";
                        }
                    }
                    function enforceDockControls() {
                        const disallowSideDock = !WI.__programaAllowSideDock;
                        updateButton(WI._dockLeftTabBarButton, disallowSideDock || WI.dockConfiguration === WI.DockConfiguration.Left);
                        updateButton(WI._dockRightTabBarButton, disallowSideDock || WI.dockConfiguration === WI.DockConfiguration.Right);
                    }
                    WI.__programaAllowSideDock = allowSideDock;
                    WI._dockLeft = function(event) {
                        if (!WI.__programaAllowSideDock)
                            return callOriginal(WI._dockBottom, event);
                        return callOriginal(WI.__programaOriginalDockLeft, event);
                    };
                    WI._dockRight = function(event) {
                        if (!WI.__programaAllowSideDock)
                            return callOriginal(WI._dockBottom, event);
                        return callOriginal(WI.__programaOriginalDockRight, event);
                    };
                    WI._togglePreviousDockConfiguration = function(event) {
                        const previousSideDock = WI._previousDockConfiguration === WI.DockConfiguration.Left || WI._previousDockConfiguration === WI.DockConfiguration.Right;
                        if (!WI.__programaAllowSideDock && previousSideDock)
                            return callOriginal(WI._dockBottom, event);
                        return callOriginal(WI.__programaOriginalTogglePreviousDockConfiguration, event);
                    };
                    WI._updateDockNavigationItems = function(...args) {
                        if (typeof WI.__programaOriginalUpdateDockNavigationItems === "function")
                            WI.__programaOriginalUpdateDockNavigationItems.apply(WI, args);
                        enforceDockControls();
                    };
                    WI._updateDockNavigationItems();
                    return WI.__programaAllowSideDock;
                })();
                """,
                completionHandler: nil
            )
        }

        func containsManagedLocalInlineContent(_ view: NSView) -> Bool {
            if let localInlineSlotView,
               view === localInlineSlotView || view.isDescendant(of: localInlineSlotView) {
                return true
            }
            if let hostedInspectorSideDockContainerView,
               view === hostedInspectorSideDockContainerView || view.isDescendant(of: hostedInspectorSideDockContainerView) {
                return true
            }
            return false
        }

        func currentHostedWebViewContainer(preferredSlotView: WindowBrowserSlotView) -> NSView {
            if let hostedInspectorSideDockContainerView,
               let hostedInspectorSideDockPageView,
               hostedWebView?.isDescendant(of: hostedInspectorSideDockContainerView) == true,
               hostedInspectorSideDockPageView.isDescendant(of: hostedInspectorSideDockContainerView) {
                return hostedInspectorSideDockContainerView
            }
            return preferredSlotView
        }

        func setHostedInspectorFrontendWebView(_ webView: WKWebView?) {
            hostedInspectorFrontendWebView = webView
            lastHostedInspectorManualSideDockAllowed = nil
            updateHostedInspectorDockControlAvailabilityIfNeeded(reason: "setHostedInspectorFrontendWebView")
        }

        private var hasStoredHostedInspectorWidthPreference: Bool {
            preferredHostedInspectorWidth != nil || preferredHostedInspectorWidthFraction != nil
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

        private func debugLogHitTest(stage: String, point: NSPoint, passThrough: Bool, hitView: NSView?) {
            let event = NSApp.currentEvent
            guard Self.shouldLogPointerEvent(event) else { return }

            let hitDesc: String = {
                guard let hitView else { return "nil" }
                let token = Unmanaged.passUnretained(hitView).toOpaque()
                return "\(type(of: hitView))@\(token)"
            }()
            let hostRectInContent: NSRect = {
                guard let window, let contentView = window.contentView else { return .zero }
                return contentView.convert(bounds, from: self)
            }()
            dlog(
                "browser.panel.host stage=\(stage) event=\(String(describing: event?.type)) " +
                "point=\(String(format: "%.1f,%.1f", point.x, point.y)) pass=\(passThrough ? 1 : 0) " +
                "hostFrameInContent=\(String(format: "%.1f,%.1f %.1fx%.1f", hostRectInContent.origin.x, hostRectInContent.origin.y, hostRectInContent.width, hostRectInContent.height)) " +
                "hit=\(hitDesc)"
            )
        }

        private static func debugObjectID(_ object: AnyObject?) -> String {
            guard let object else { return "nil" }
            return String(describing: Unmanaged.passUnretained(object).toOpaque())
        }

        private static func debugRect(_ rect: NSRect) -> String {
            String(format: "%.1f,%.1f %.1fx%.1f", rect.origin.x, rect.origin.y, rect.width, rect.height)
        }

        private func debugLogHostedInspectorFrames(
            stage: String,
            point: NSPoint? = nil,
            hit: HostedInspectorDividerHit
        ) {
            let pointDesc = point.map { String(format: "%.1f,%.1f", $0.x, $0.y) } ?? "nil"
            let preferredWidthDesc = preferredHostedInspectorWidth.map { String(format: "%.1f", $0) } ?? "nil"
            dlog(
                "browser.panel.hostedInspector stage=\(stage) point=\(pointDesc) " +
                "host=\(Self.debugObjectID(self)) container=\(Self.debugObjectID(hit.containerView)) " +
                "page=\(Self.debugObjectID(hit.pageView)) inspector=\(Self.debugObjectID(hit.inspectorView)) " +
                "preferredWidth=\(preferredWidthDesc) " +
                "hostFrame=\(Self.debugRect(frame)) hostBounds=\(Self.debugRect(bounds)) " +
                "containerBounds=\(Self.debugRect(hit.containerView.bounds)) " +
                "pageFrame=\(Self.debugRect(hit.pageView.frame)) " +
                "inspectorFrame=\(Self.debugRect(hit.inspectorView.frame))"
            )
        }

        private func debugLogHostedInspectorLayoutIfNeeded(reason: String) {
            guard let hit = hostedInspectorDividerCandidate() else {
                if !hasLoggedMissingHostedInspectorCandidate,
                   lastLoggedHostedInspectorFrames != nil || preferredHostedInspectorWidth != nil {
                    let preferredWidthDesc = preferredHostedInspectorWidth.map {
                        String(format: "%.1f", $0)
                    } ?? "nil"
                    lastLoggedHostedInspectorFrames = nil
                    hasLoggedMissingHostedInspectorCandidate = true
                    dlog(
                        "browser.panel.hostedInspector stage=\(reason).candidateMissing " +
                        "host=\(Self.debugObjectID(self)) preferredWidth=\(preferredWidthDesc)"
                    )
                }
                return
            }
            hasLoggedMissingHostedInspectorCandidate = false

            let nextFrames = (page: hit.pageView.frame, inspector: hit.inspectorView.frame)
            if let lastLoggedHostedInspectorFrames,
               InspectorDock.rectApproximatelyEqual(lastLoggedHostedInspectorFrames.page, nextFrames.page),
               InspectorDock.rectApproximatelyEqual(lastLoggedHostedInspectorFrames.inspector, nextFrames.inspector) {
                return
            }

            lastLoggedHostedInspectorFrames = nextFrames
            debugLogHostedInspectorFrames(stage: "\(reason).layout", hit: hit)
        }
#endif

        private static func sizeApproximatelyEqual(_ lhs: NSSize, _ rhs: NSSize, epsilon: CGFloat = 0.5) -> Bool {
            abs(lhs.width - rhs.width) <= epsilon &&
                abs(lhs.height - rhs.height) <= epsilon
        }

        private func currentGeometryState() -> GeometryState {
            GeometryState(
                frame: frame,
                bounds: bounds,
                windowNumber: window?.windowNumber,
                superviewID: superview.map(ObjectIdentifier.init)
            )
        }

        /// Record that geometry changed without firing the callback immediately.
        /// `setFrameOrigin`/`setFrameSize` can fire multiple times before `layout()`;
        /// deferring avoids redundant portal-sync cascades during divider drag.
        /// A dispatch fallback ensures the callback fires even if `layout()` is not called.
        /// Note: `lastReportedGeometryState` and `geometryRevision` are only updated
        /// when the callback actually fires, so `updateNSView` sees a revision that
        /// is strictly tied to emitted callbacks (no premature increments).
        private func markGeometryDirtyIfNeeded() {
            let state = currentGeometryState()
            guard state != lastReportedGeometryState else { return }
            guard !hasPendingGeometryNotification else { return }
            hasPendingGeometryNotification = true
            DispatchQueue.main.async { [weak self] in
                self?.notifyGeometryChangedIfNeeded()
            }
        }

        /// Check for geometry changes and fire the callback. Also flushes any pending
        /// dirty state from `markGeometryDirtyIfNeeded` so `layout()` supersedes the
        /// async fallback.  Only updates `lastReportedGeometryState` / `geometryRevision`
        /// when the callback is emitted, keeping the revision in sync with actual
        /// notifications.
        private func notifyGeometryChangedIfNeeded() {
            hasPendingGeometryNotification = false
            let state = currentGeometryState()
            guard state != lastReportedGeometryState else { return }
            lastReportedGeometryState = state
            geometryRevision &+= 1
            onGeometryChanged?()
        }

        func ensureLocalInlineSlotView() -> WindowBrowserSlotView {
            if let localInlineSlotView, localInlineSlotView.superview === self {
                localInlineSlotView.isHidden = false
                return localInlineSlotView
            }

            let slotView = WindowBrowserSlotView(frame: bounds)
            slotView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(slotView, positioned: .above, relativeTo: nil)
            localInlineSlotConstraints = [
                slotView.topAnchor.constraint(equalTo: topAnchor),
                slotView.bottomAnchor.constraint(equalTo: bottomAnchor),
                slotView.leadingAnchor.constraint(equalTo: leadingAnchor),
                slotView.trailingAnchor.constraint(equalTo: trailingAnchor),
            ]
            NSLayoutConstraint.activate(localInlineSlotConstraints)
            localInlineSlotView = slotView
            return slotView
        }

        func setLocalInlineSlotHidden(_ hidden: Bool) {
            localInlineSlotView?.isHidden = hidden
            if hidden {
                notifyHostedWebKitHidden(reason: "slotHidden")
            }
        }

        func clearLocalInlineCallbacks() {
            onPreferredHostedInspectorWidthChanged = nil
            localInlineSlotView?.onHostedInspectorLayout = nil
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

        private var hostedWebKitSubviews: [WKWebView] {
            var result: [WKWebView] = []
            var seen = Set<ObjectIdentifier>()

            func append(_ webView: WKWebView?) {
                guard let webView else { return }
                let id = ObjectIdentifier(webView)
                guard seen.insert(id).inserted else { return }
                result.append(webView)
            }

            append(hostedWebView)
            append(hostedInspectorFrontendWebView)
            appendHostedWebKitSubviews(in: self, to: &result, seen: &seen)
            return result
        }

        private func notifyHostedWebKitHidden(reason: String) {
            for webView in hostedWebKitSubviews {
                webView.programaBrowserPanelNotifyHidden(reason: reason)
            }
        }

        func refreshHostedWebKitPresentation(
            reason: String,
            forceLifecycleRefresh: Bool = false
        ) {
            guard let localInlineSlotView else { return }
            guard !localInlineSlotView.isHidden else { return }
            let hostedWebKitSubviews = hostedWebKitSubviews
            guard !hostedWebKitSubviews.isEmpty else { return }

            localInlineSlotView.needsLayout = true
            localInlineSlotView.needsDisplay = true
            localInlineSlotView.setNeedsDisplay(localInlineSlotView.bounds)

            needsLayout = true
            needsDisplay = true
            setNeedsDisplay(bounds)

            for webView in hostedWebKitSubviews {
                if let scrollView = webView.enclosingScrollView {
                    scrollView.needsLayout = true
                    scrollView.needsDisplay = true
                    scrollView.setNeedsDisplay(scrollView.bounds)
                    scrollView.contentView.needsLayout = true
                    scrollView.contentView.needsDisplay = true
                }
                webView.needsLayout = true
                webView.needsDisplay = true
                webView.setNeedsDisplay(webView.bounds)
            }

            localInlineSlotView.layoutSubtreeIfNeeded()
            layoutSubtreeIfNeeded()

            for webView in hostedWebKitSubviews {
                if let scrollView = webView.enclosingScrollView {
                    scrollView.layoutSubtreeIfNeeded()
                    scrollView.contentView.layoutSubtreeIfNeeded()
                    scrollView.displayIfNeeded()
                }
                webView.layoutSubtreeIfNeeded()
                if forceLifecycleRefresh {
                    webView.programaBrowserPanelForceRenderingStateRefresh(reason: reason)
                } else {
                    webView.programaBrowserPanelReattachRenderingState(reason: reason)
                }
                webView.displayIfNeeded()
            }

            localInlineSlotView.displayIfNeeded()
            displayIfNeeded()
            window?.displayIfNeeded()
        }

        func prepareForWindowPortalHosting() {
            hostedInspectorDockConfigurationSyncWorkItem?.cancel()
            hostedInspectorDockConfigurationSyncWorkItem = nil
            notifyHostedWebKitHidden(reason: "prepareForWindowPortalHosting")
            deactivateHostedInspectorSideDockIfNeeded(reparentTo: localInlineSlotView)
            hostedInspectorFrontendWebView = nil
        }

        func releaseHostedWebViewConstraints() {
            NSLayoutConstraint.deactivate(hostedWebViewConstraints)
            hostedWebViewConstraints = []
            hostedWebView = nil
        }

        func pinHostedWebView(_ webView: WKWebView, in container: NSView) {
            guard webView.superview === container || webView.isDescendant(of: container) else { return }

            let hasCompanionWKSubviews = Self.hasWebKitCompanionSubview(
                in: container,
                primaryWebView: webView
            )
            let needsPlainWebViewFrameReset =
                webView.superview === container &&
                !hasCompanionWKSubviews &&
                Self.frameDiffersFromBounds(webView.frame, bounds: container.bounds)
            let needsFrameHosting =
                hostedWebView !== webView ||
                !hostedWebViewConstraints.isEmpty ||
                needsPlainWebViewFrameReset ||
                !webView.translatesAutoresizingMaskIntoConstraints ||
                webView.autoresizingMask != [.width, .height]
            guard needsFrameHosting else {
                needsLayout = true
                layoutSubtreeIfNeeded()
                return
            }

            NSLayoutConstraint.deactivate(hostedWebViewConstraints)
            hostedWebViewConstraints = []
            hostedWebView = webView

            // WebKit's attached inspector does not reliably dock into a constraint-managed
            // WKWebView hierarchy on macOS. Host the moved webview with autoresizing and
            // preserve WebKit-managed split frames when docked DevTools siblings exist.
            webView.translatesAutoresizingMaskIntoConstraints = true
            webView.autoresizingMask = [.width, .height]
            if webView.superview === container && !hasCompanionWKSubviews {
                webView.frame = container.bounds
            }
            needsLayout = true
            layoutSubtreeIfNeeded()
        }

        private static func frameDiffersFromBounds(_ frame: NSRect, bounds: NSRect, epsilon: CGFloat = 0.5) -> Bool {
            abs(frame.minX - bounds.minX) > epsilon ||
                abs(frame.minY - bounds.minY) > epsilon ||
                abs(frame.width - bounds.width) > epsilon ||
                abs(frame.height - bounds.height) > epsilon
        }

        private static func hasWebKitCompanionSubview(in host: NSView, primaryWebView: WKWebView) -> Bool {
            var stack = host.subviews.filter { $0 !== primaryWebView }
            while let current = stack.popLast() {
                if current.isDescendant(of: primaryWebView) {
                    continue
                }
                if current.isHidden || current.alphaValue <= 0 {
                    continue
                }
                if String(describing: type(of: current)).contains("WK") {
                    let width = max(current.frame.width, current.bounds.width)
                    let height = max(current.frame.height, current.bounds.height)
                    if width > 1, height > 1 {
                        return true
                    }
                    continue
                }
                stack.append(contentsOf: current.subviews)
            }
            return false
        }

        private func ensureHostedInspectorSideDockContainerView() -> HostedInspectorSideDockContainerView {
            if let hostedInspectorSideDockContainerView,
               hostedInspectorSideDockContainerView.superview === self {
                hostedInspectorSideDockContainerView.isHidden = false
                return hostedInspectorSideDockContainerView
            }

            let containerView = HostedInspectorSideDockContainerView(frame: bounds)
            containerView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(containerView, positioned: .above, relativeTo: localInlineSlotView)
            hostedInspectorSideDockConstraints = [
                containerView.topAnchor.constraint(equalTo: topAnchor),
                containerView.bottomAnchor.constraint(equalTo: bottomAnchor),
                containerView.leadingAnchor.constraint(equalTo: leadingAnchor),
                containerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            ]
            NSLayoutConstraint.activate(hostedInspectorSideDockConstraints)
            hostedInspectorSideDockContainerView = containerView
            return containerView
        }

        private func moveHostedInspectorSubviewIfNeeded(_ view: NSView, to container: NSView) {
            guard view.superview !== container else { return }
            let frameInWindow = view.superview?.convert(view.frame, to: nil) ?? convert(view.frame, to: nil)
            view.removeFromSuperview()
            container.addSubview(view, positioned: .above, relativeTo: nil)
            view.frame = container.convert(frameInWindow, from: nil)
        }

        private func isHostedInspectorSideDockActive() -> Bool {
            guard let hostedInspectorSideDockContainerView,
                  let hostedInspectorSideDockPageView,
                  let hostedInspectorSideDockInspectorView else {
                return false
            }
            return hostedInspectorSideDockPageView.superview === hostedInspectorSideDockContainerView &&
                hostedInspectorSideDockInspectorView.superview === hostedInspectorSideDockContainerView
        }

        private func isHostedInspectorSideDockHit(_ hit: HostedInspectorDividerHit) -> Bool {
            guard let hostedInspectorSideDockContainerView else { return false }
            return hit.containerView === hostedInspectorSideDockContainerView
        }

        private func activateHostedInspectorSideDockIfNeeded(using hit: HostedInspectorDividerHit) {
            let containerView = ensureHostedInspectorSideDockContainerView()
            moveHostedInspectorSubviewIfNeeded(hit.pageView, to: containerView)
            moveHostedInspectorSubviewIfNeeded(hit.inspectorView, to: containerView)
            hostedInspectorSideDockPageView = hit.pageView
            hostedInspectorSideDockInspectorView = hit.inspectorView
            hostedInspectorSideDockDockSide = hit.dockSide
            layoutHostedInspectorSideDockIfNeeded(reason: "sideDock.activate")
        }

        @discardableResult
        func promoteHostedInspectorSideDockFromCurrentLayoutIfNeeded() -> Bool {
            guard !isHostedInspectorSideDockActive(),
                  let slotView = localInlineSlotView,
                  let hit = hostedInspectorDividerCandidateUsingKnownWebViews(in: slotView) else {
                return false
            }

            // The inspector frontend sometimes reports its dock configuration a tick
            // late after local-inline reattach. Promote the visible left/right split
            // immediately so drag routing stays symmetric on both dock sides.
            activateHostedInspectorSideDockIfNeeded(using: hit)
            return isHostedInspectorSideDockActive()
        }

        private func deactivateHostedInspectorSideDockIfNeeded(reparentTo slotView: WindowBrowserSlotView?) {
            guard let slotView,
                  let pageView = hostedInspectorSideDockPageView,
                  let inspectorView = hostedInspectorSideDockInspectorView else {
                hostedInspectorSideDockPageView = nil
                hostedInspectorSideDockInspectorView = nil
                hostedInspectorSideDockDockSide = nil
                hostedInspectorSideDockContainerView?.isHidden = true
                return
            }

            moveHostedInspectorSubviewIfNeeded(pageView, to: slotView)
            moveHostedInspectorSubviewIfNeeded(inspectorView, to: slotView)
            hostedInspectorSideDockPageView = nil
            hostedInspectorSideDockInspectorView = nil
            hostedInspectorSideDockDockSide = nil
            hostedInspectorSideDockContainerView?.isHidden = true
        }

        private func layoutHostedInspectorSideDockIfNeeded(reason: String) {
            guard let containerView = hostedInspectorSideDockContainerView,
                  let pageView = hostedInspectorSideDockPageView,
                  let inspectorView = hostedInspectorSideDockInspectorView,
                  let dockSide = hostedInspectorSideDockDockSide else {
                return
            }
            let preferredWidth = resolvedPreferredHostedInspectorWidth(in: containerView.bounds) ?? max(0, inspectorView.frame.width)
            _ = applyHostedInspectorDividerWidth(
                preferredWidth,
                to: HostedInspectorDividerHit(
                    containerView: containerView,
                    pageView: pageView,
                    inspectorView: inspectorView,
                    dockSide: dockSide
                ),
                minimumInspectorWidth: Self.minimumHostedInspectorWidth,
                reason: reason
            )
        }

        func normalizeHostedInspectorLayoutIfNeeded(reason: String) {
            if enforceAdaptiveBottomDockIfNeeded(reason: "\(reason).adaptive") {
                return
            }
            _ = promoteHostedInspectorSideDockFromCurrentLayoutIfNeeded()
            if isHostedInspectorSideDockActive() {
                layoutHostedInspectorSideDockIfNeeded(reason: reason)
            } else if !hasStoredHostedInspectorWidthPreference {
                captureHostedInspectorPreferredWidthFromCurrentLayout(reason: reason)
            }
        }

        private func shouldForceHostedInspectorBottomDock(using hit: HostedInspectorDividerHit) -> Bool {
            let containerWidth = max(0, hit.containerView.bounds.width)
            guard containerWidth > 1 else { return false }

            let currentInspectorWidth = max(0, hit.inspectorView.frame.width)
            let currentPageWidth = max(0, hit.pageView.frame.width)
            let remainingPageWidth = max(0, containerWidth - max(Self.minimumHostedInspectorWidth, currentInspectorWidth))
            let effectivePageWidth = min(currentPageWidth, remainingPageWidth)

            return effectivePageWidth < Self.minimumHostedInspectorPageWidthForSideDock
        }

        @discardableResult
        private func requestAdaptiveHostedInspectorBottomDock(reason: String) -> Bool {
            let now = Date()
            if let adaptiveBottomDockRequestCooldownDeadline, adaptiveBottomDockRequestCooldownDeadline > now {
                return true
            }
            guard let hostedInspectorFrontendWebView else { return false }

            adaptiveBottomDockRequestCooldownDeadline = now.addingTimeInterval(Self.adaptiveBottomDockRequestCooldown)
            updateHostedInspectorDockControlAvailabilityIfNeeded(reason: reason)
#if DEBUG
            dlog(
                "browser.panel.hostedInspector stage=\(reason).adaptiveBottomDock " +
                "host=\(Self.debugObjectID(self)) bounds=\(Self.debugRect(bounds))"
            )
#endif
            hostedInspectorFrontendWebView.evaluateJavaScript(
                "typeof WI !== 'undefined' ? WI._dockBottom() : null"
            ) { [weak self] _, _ in
                self?.scheduleHostedInspectorDockConfigurationSync(
                    reason: "\(reason).adaptiveBottomDock"
                )
            }
            return true
        }

        @discardableResult
        private func enforceAdaptiveBottomDockIfNeeded(reason: String) -> Bool {
            guard let hit = hostedInspectorDividerCandidate(),
                  shouldForceHostedInspectorBottomDock(using: hit) else {
                return false
            }
            recordHostedInspectorSideDockWidth(hit.inspectorView.frame.width)
            return requestAdaptiveHostedInspectorBottomDock(reason: reason)
        }

        fileprivate func scheduleHostedInspectorDockConfigurationSync(reason: String) {
            hostedInspectorDockConfigurationSyncWorkItem?.cancel()
            guard hostedInspectorFrontendWebView != nil else { return }
            let workItem = DispatchWorkItem { [weak self] in
                self?.syncHostedInspectorDockConfiguration(reason: reason)
            }
            hostedInspectorDockConfigurationSyncWorkItem = workItem
            DispatchQueue.main.async(execute: workItem)
        }

        private func syncHostedInspectorDockConfiguration(reason: String) {
            hostedInspectorDockConfigurationSyncWorkItem = nil
            guard let hostedInspectorFrontendWebView else { return }
            hostedInspectorFrontendWebView.evaluateJavaScript(
                "typeof WI === 'undefined' ? null : WI.dockConfiguration"
            ) { [weak self] result, _ in
                self?.applyHostedInspectorDockConfiguration(result as? String, reason: reason)
            }
        }

        private func applyHostedInspectorDockConfiguration(_ dockConfiguration: String?, reason: String) {
            switch dockConfiguration {
            case "left":
                hostedInspectorSideDockDockSide = .leading
                if isHostedInspectorSideDockActive() {
                    if enforceAdaptiveBottomDockIfNeeded(reason: "\(reason).dockLeft") {
                        return
                    }
                    layoutHostedInspectorSideDockIfNeeded(reason: "\(reason).dockLeft")
                } else if let slotView = localInlineSlotView,
                          let hit = hostedInspectorDividerCandidate(in: slotView),
                          hit.dockSide == .leading {
                    if shouldForceHostedInspectorBottomDock(using: hit) {
                        _ = requestAdaptiveHostedInspectorBottomDock(reason: "\(reason).dockLeft")
                        return
                    }
                    activateHostedInspectorSideDockIfNeeded(using: hit)
                }
            case "right":
                hostedInspectorSideDockDockSide = .trailing
                if isHostedInspectorSideDockActive() {
                    if enforceAdaptiveBottomDockIfNeeded(reason: "\(reason).dockRight") {
                        return
                    }
                    layoutHostedInspectorSideDockIfNeeded(reason: "\(reason).dockRight")
                } else if let slotView = localInlineSlotView,
                          let hit = hostedInspectorDividerCandidate(in: slotView),
                          hit.dockSide == .trailing {
                    if shouldForceHostedInspectorBottomDock(using: hit) {
                        _ = requestAdaptiveHostedInspectorBottomDock(reason: "\(reason).dockRight")
                        return
                    }
                    activateHostedInspectorSideDockIfNeeded(using: hit)
                }
            default:
                adaptiveBottomDockRequestCooldownDeadline = nil
                if isHostedInspectorSideDockActive() {
                    deactivateHostedInspectorSideDockIfNeeded(reparentTo: localInlineSlotView)
                    if dockConfiguration == "bottom" {
                        hostedInspectorFrontendWebView?.evaluateJavaScript(
                            "typeof WI !== 'undefined' ? WI._dockBottom() : null",
                            completionHandler: nil
                        )
                    }
                }
            }
            updateHostedInspectorDockControlAvailabilityIfNeeded(reason: "\(reason).dockConfiguration")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                notifyHostedWebKitHidden(reason: "viewDidMoveToWindow")
                clearActiveDividerCursor(restoreArrow: false)
            } else {
                scheduleHostedInspectorDividerReapply(reason: "viewDidMoveToWindow")
                scheduleHostedInspectorDockConfigurationSync(reason: "viewDidMoveToWindow")
                refreshHostedWebKitPresentation(
                    reason: "viewDidMoveToWindow",
                    forceLifecycleRefresh: hostedInspectorFrontendWebView != nil
                )
            }
            window?.invalidateCursorRects(for: self)
            onDidMoveToWindow?()
            notifyGeometryChangedIfNeeded()
#if DEBUG
            debugLogHostedInspectorLayoutIfNeeded(reason: "viewDidMoveToWindow")
#endif
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            scheduleHostedInspectorDividerReapply(reason: "viewDidMoveToSuperview")
            scheduleHostedInspectorDockConfigurationSync(reason: "viewDidMoveToSuperview")
            notifyGeometryChangedIfNeeded()
#if DEBUG
            debugLogHostedInspectorLayoutIfNeeded(reason: "viewDidMoveToSuperview")
#endif
        }

        override func layout() {
            super.layout()
            _ = promoteHostedInspectorSideDockFromCurrentLayoutIfNeeded()
            if enforceAdaptiveBottomDockIfNeeded(reason: "host.layout") {
                updateHostedInspectorDockControlAvailabilityIfNeeded(reason: "host.layout")
                notifyGeometryChangedIfNeeded()
#if DEBUG
                debugLogHostedInspectorLayoutIfNeeded(reason: "layout")
#endif
                return
            }
            if let previousSize = lastHostedInspectorLayoutBoundsSize,
               Self.sizeApproximatelyEqual(previousSize, bounds.size, epsilon: 0.5) {
                // Origin-only frame churn is common while the surrounding split layout
                // settles. Reapplying the side-docked inspector at the same size fights
                // WebKit's own dock layout and shows up as visible flicker.
                if !isHostedInspectorDividerDragActive {
                    if hasStoredHostedInspectorWidthPreference {
                        reapplyHostedInspectorDividerToStoredWidthIfNeeded(reason: "host.layout.sameSize")
                    } else if !isHostedInspectorSideDockActive() {
                        captureHostedInspectorPreferredWidthFromCurrentLayout(reason: "host.layout.sameSize")
                    }
                }
                updateHostedInspectorDockControlAvailabilityIfNeeded(reason: "host.layout.sameSize")
                notifyGeometryChangedIfNeeded()
#if DEBUG
                debugLogHostedInspectorLayoutIfNeeded(reason: "layout")
#endif
                return
            }
            lastHostedInspectorLayoutBoundsSize = bounds.size
            if isHostedInspectorSideDockActive() {
                layoutHostedInspectorSideDockIfNeeded(reason: "host.layout.sideDock")
            } else if hasStoredHostedInspectorWidthPreference {
                reapplyHostedInspectorDividerToStoredWidthIfNeeded(reason: "host.layout")
            } else {
                captureHostedInspectorPreferredWidthFromCurrentLayout(reason: "host.layout")
            }
            updateHostedInspectorDockControlAvailabilityIfNeeded(reason: "host.layout")
            scheduleHostedInspectorDockConfigurationSync(reason: "layout")
            notifyGeometryChangedIfNeeded()
#if DEBUG
            debugLogHostedInspectorLayoutIfNeeded(reason: "layout")
#endif
        }

        override func setFrameOrigin(_ newOrigin: NSPoint) {
            super.setFrameOrigin(newOrigin)
            window?.invalidateCursorRects(for: self)
            // Mark dirty; the callback fires from layout() with the settled geometry.
            markGeometryDirtyIfNeeded()
#if DEBUG
            debugLogHostedInspectorLayoutIfNeeded(reason: "setFrameOrigin")
#endif
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            window?.invalidateCursorRects(for: self)
            // Mark dirty; the callback fires from layout() with the settled geometry.
            markGeometryDirtyIfNeeded()
#if DEBUG
            debugLogHostedInspectorLayoutIfNeeded(reason: "setFrameSize")
#endif
        }

        override func resetCursorRects() {
            super.resetCursorRects()
            guard let hostedInspectorHit = hostedInspectorDividerCandidate() else { return }
            let clipped = hostedInspectorDividerHitRect(for: hostedInspectorHit).intersection(bounds)
            guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return }
            addCursorRect(clipped, cursor: NSCursor.resizeLeftRight)
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
            updateDividerCursor(at: convert(event.locationInWindow, from: nil))
        }

        override func mouseMoved(with event: NSEvent) {
            updateDividerCursor(at: convert(event.locationInWindow, from: nil))
        }

        override func mouseExited(with event: NSEvent) {
            clearActiveDividerCursor(restoreArrow: true)
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            let hostedInspectorHit = hostedInspectorDividerHit(at: point)
            updateDividerCursor(at: point, hostedInspectorHit: hostedInspectorHit)
            let passThrough = shouldPassThroughToSidebarResizer(at: point, hostedInspectorHit: hostedInspectorHit)
            if passThrough {
#if DEBUG
                debugLogHitTest(stage: "hitTest.pass", point: point, passThrough: true, hitView: nil)
#endif
                return nil
            }
            if let hostedInspectorHit {
                if let nativeHit = nativeHostedInspectorHit(at: point, hostedInspectorHit: hostedInspectorHit) {
#if DEBUG
                    debugLogHitTest(stage: "hitTest.hostedInspectorNative", point: point, passThrough: false, hitView: nativeHit)
#endif
                    if nativeHit !== hostedInspectorHit.inspectorView &&
                        !hostedInspectorHit.inspectorView.isDescendant(of: nativeHit) {
                        return nativeHit
                    }
                }
#if DEBUG
                debugLogHitTest(
                    stage: "hitTest.hostedInspectorManual",
                    point: point,
                    passThrough: false,
                    hitView: self
                )
#endif
                return self
            }
            let hit = super.hitTest(point)
#if DEBUG
            debugLogHitTest(stage: "hitTest.result", point: point, passThrough: false, hitView: hit)
#endif
            return hit
        }

        override func mouseDown(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            guard let hostedInspectorHit = hostedInspectorDividerHit(at: point) else {
                super.mouseDown(with: event)
                return
            }

            hostedInspectorReapplyWorkItem?.cancel()
            isHostedInspectorDividerDragActive = true
            hostedInspectorDividerDrag = HostedInspectorDividerDragState(
                containerView: hostedInspectorHit.containerView,
                pageView: hostedInspectorHit.pageView,
                inspectorView: hostedInspectorHit.inspectorView,
                dockSide: hostedInspectorHit.dockSide,
                initialWindowX: event.locationInWindow.x,
                initialPageFrame: hostedInspectorHit.pageView.frame,
                initialInspectorFrame: hostedInspectorHit.inspectorView.frame
            )
#if DEBUG
            debugLogHostedInspectorFrames(stage: "drag.start", point: point, hit: hostedInspectorHit)
#endif
        }

        override func mouseDragged(with event: NSEvent) {
            guard let dragState = hostedInspectorDividerDrag else {
                super.mouseDragged(with: event)
                return
            }

            let containerBounds = dragState.containerView.bounds
            let minimumInspectorWidth = Self.minimumHostedInspectorWidth
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
            recordPreferredHostedInspectorWidth(inspectorWidth, containerBounds: containerBounds)
            _ = applyHostedInspectorDividerWidth(
                inspectorWidth,
                to: HostedInspectorDividerHit(
                    containerView: dragState.containerView,
                    pageView: dragState.pageView,
                    inspectorView: dragState.inspectorView,
                    dockSide: dragState.dockSide
                ),
                minimumInspectorWidth: Self.minimumHostedInspectorWidth,
                reason: "drag"
            )
#if DEBUG
            debugLogHostedInspectorFrames(
                stage: "drag.update",
                point: convert(event.locationInWindow, from: nil),
                hit: HostedInspectorDividerHit(
                    containerView: dragState.containerView,
                    pageView: dragState.pageView,
                    inspectorView: dragState.inspectorView,
                    dockSide: dragState.dockSide
                )
            )
#endif
            updateDividerCursor(
                at: convert(event.locationInWindow, from: nil),
                hostedInspectorHit: HostedInspectorDividerHit(
                    containerView: dragState.containerView,
                    pageView: dragState.pageView,
                    inspectorView: dragState.inspectorView,
                    dockSide: dragState.dockSide
                )
            )
        }

        override func mouseUp(with event: NSEvent) {
            let finalDragState = hostedInspectorDividerDrag
            hostedInspectorDividerDrag = nil
            isHostedInspectorDividerDragActive = false
            updateDividerCursor(at: convert(event.locationInWindow, from: nil))
            if let finalDragState {
#if DEBUG
                debugLogHostedInspectorFrames(
                    stage: "drag.end",
                    point: convert(event.locationInWindow, from: nil),
                    hit: HostedInspectorDividerHit(
                        containerView: finalDragState.containerView,
                        pageView: finalDragState.pageView,
                        inspectorView: finalDragState.inspectorView,
                        dockSide: finalDragState.dockSide
                    )
                )
#endif
                reapplyHostedInspectorDividerToStoredWidthIfNeeded(reason: "drag.end")
            }
            super.mouseUp(with: event)
        }

        private func shouldPassThroughToSidebarResizer(
            at point: NSPoint,
            hostedInspectorHit: HostedInspectorDividerHit? = nil
        ) -> Bool {
            if hostedInspectorHit != nil {
                return false
            }
            // Pass through a narrow leading-edge band so the shared sidebar divider
            // handle can receive hover/click even when WKWebView is attached here.
            // Keeping this deterministic avoids flicker from dynamic left-edge scans.
            guard point.x >= 0, point.x <= SidebarResizeInteraction.contentSideHitWidth else {
                return false
            }
            guard let window, let contentView = window.contentView else {
                return false
            }
            let hostRectInContent = contentView.convert(bounds, from: self)
            return hostRectInContent.minX > 1
        }

        private func updateDividerCursor(
            at point: NSPoint,
            hostedInspectorHit: HostedInspectorDividerHit? = nil
        ) {
            let resolvedHostedInspectorHit = hostedInspectorHit ?? hostedInspectorDividerHit(at: point)
            if shouldPassThroughToSidebarResizer(at: point, hostedInspectorHit: resolvedHostedInspectorHit) {
                clearActiveDividerCursor(restoreArrow: false)
                return
            }
            guard resolvedHostedInspectorHit != nil else {
                clearActiveDividerCursor(restoreArrow: true)
                return
            }
            activeDividerCursorKind = .vertical
            NSCursor.resizeLeftRight.set()
        }

        private func clearActiveDividerCursor(restoreArrow: Bool) {
            guard activeDividerCursorKind != nil else { return }
            window?.invalidateCursorRects(for: self)
            activeDividerCursorKind = nil
            if restoreArrow {
                NSCursor.arrow.set()
            }
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

        private func hostedInspectorDividerHit(at point: NSPoint) -> HostedInspectorDividerHit? {
            guard let hit = hostedInspectorDividerCandidate(),
                  hostedInspectorDividerHitRect(for: hit).contains(point) else {
                return nil
            }
            return hit
        }

        private func hostedInspectorDividerCandidate() -> HostedInspectorDividerHit? {
            hostedInspectorDividerCandidate(in: self)
        }

        private func hostedInspectorDividerCandidate(in root: NSView) -> HostedInspectorDividerHit? {
            if let preferredHit = hostedInspectorDividerCandidateUsingKnownWebViews(in: root) {
                return preferredHit
            }

            let inspectorCandidates = InspectorDock.visibleDescendants(in: root)
                .filter { InspectorDock.isVisibleCandidate($0) && InspectorDock.isInspectorView($0) }
                .sorted { lhs, rhs in
                    let lhsFrame = root.convert(lhs.bounds, from: lhs)
                    let rhsFrame = root.convert(rhs.bounds, from: rhs)
                    return lhsFrame.minX < rhsFrame.minX
                }

            var bestHit: HostedInspectorDividerHit?
            var bestScore = -CGFloat.greatestFiniteMagnitude

            for inspectorCandidate in inspectorCandidates {
                guard let candidate = hostedInspectorDividerCandidate(in: root, startingAt: inspectorCandidate) else {
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

        private func hostedInspectorDividerCandidateUsingKnownWebViews(in root: NSView) -> HostedInspectorDividerHit? {
            guard let pageLeaf = hostedWebView,
                  let inspectorLeaf = hostedInspectorFrontendWebView,
                  pageLeaf.isDescendant(of: root),
                  inspectorLeaf.isDescendant(of: root),
                  InspectorDock.isVisibleCandidate(inspectorLeaf) else {
                return nil
            }
            return hostedInspectorDividerCandidate(
                in: root,
                pageLeaf: pageLeaf,
                inspectorLeaf: inspectorLeaf
            )
        }

        private func hostedInspectorDividerCandidate(
            in root: NSView,
            pageLeaf: NSView,
            inspectorLeaf: NSView
        ) -> HostedInspectorDividerHit? {
            var currentInspector: NSView? = inspectorLeaf

            while let inspectorView = currentInspector, inspectorView !== root {
                guard let containerView = inspectorView.superview else { break }
                guard containerView === root || containerView.isDescendant(of: root) else {
                    currentInspector = containerView
                    continue
                }
                guard let pageView = Self.directChild(of: containerView, containing: pageLeaf) else {
                    currentInspector = containerView
                    continue
                }
                guard pageView !== inspectorView,
                      InspectorDock.isVisibleSiblingCandidate(pageView, requireMinWidth: false),
                      InspectorDock.verticalOverlap(between: pageView.frame, and: inspectorView.frame) > 8,
                      let dockSide = HostedInspectorDockSide.resolve(
                          pageFrame: pageView.frame,
                          inspectorFrame: inspectorView.frame
                      ) else {
                    currentInspector = containerView
                    continue
                }
                return HostedInspectorDividerHit(
                    containerView: containerView,
                    pageView: pageView,
                    inspectorView: inspectorView,
                    dockSide: dockSide
                )
            }

            return nil
        }

        private func hostedInspectorDividerHitRect(for hit: HostedInspectorDividerHit) -> NSRect {
            let pageFrame = convert(hit.pageView.bounds, from: hit.pageView)
            let inspectorFrame = convert(hit.inspectorView.bounds, from: hit.inspectorView)
            return hit.dockSide.dividerHitRect(
                in: bounds,
                pageFrame: pageFrame,
                inspectorFrame: inspectorFrame,
                expansion: Self.hostedInspectorDividerHitExpansion
            )
        }

        private func hostedInspectorDividerCandidate(in root: NSView, startingAt inspectorLeaf: NSView) -> HostedInspectorDividerHit? {
            var current: NSView? = inspectorLeaf
            var bestHit: HostedInspectorDividerHit?

            while let inspectorView = current, inspectorView !== root {
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

        private func hostedInspectorDividerCandidateScore(_ hit: HostedInspectorDividerHit) -> CGFloat {
            let pageFrame = convert(hit.pageView.bounds, from: hit.pageView)
            let inspectorFrame = convert(hit.inspectorView.bounds, from: hit.inspectorView)
            let overlap = InspectorDock.verticalOverlap(between: pageFrame, and: inspectorFrame)
            let coverageWidth = max(pageFrame.maxX, inspectorFrame.maxX) - min(pageFrame.minX, inspectorFrame.minX)
            return (overlap * 1_000) + coverageWidth + pageFrame.width
        }

        private func hostedInspectorPageCandidateScore(_ pageView: NSView, inspectorView: NSView) -> CGFloat {
            let overlap = InspectorDock.verticalOverlap(between: pageView.frame, and: inspectorView.frame)
            let coverageWidth = max(pageView.frame.maxX, inspectorView.frame.maxX) - min(pageView.frame.minX, inspectorView.frame.minX)
            return (overlap * 1_000) + coverageWidth + pageView.frame.width
        }

        fileprivate func scheduleHostedInspectorDividerReapply(reason: String) {
            hostedInspectorReapplyWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.hostedInspectorReapplyWorkItem = nil
                _ = self.promoteHostedInspectorSideDockFromCurrentLayoutIfNeeded()
                if self.hasStoredHostedInspectorWidthPreference {
                    self.reapplyHostedInspectorDividerToStoredWidthIfNeeded(reason: reason)
                } else {
                    self.captureHostedInspectorPreferredWidthFromCurrentLayout(reason: reason)
                }
            }
            hostedInspectorReapplyWorkItem = workItem
            DispatchQueue.main.async(execute: workItem)
        }

        private func captureHostedInspectorPreferredWidthFromCurrentLayout(reason: String) {
            guard !isApplyingHostedInspectorLayout else { return }
            guard !isHostedInspectorDividerDragActive else { return }
            guard let hit = hostedInspectorDividerCandidate() else {
#if DEBUG
                if !hasLoggedMissingHostedInspectorCandidate {
                    hasLoggedMissingHostedInspectorCandidate = true
                    let preferredWidthDesc = preferredHostedInspectorWidth.map {
                        String(format: "%.1f", $0)
                    } ?? "nil"
                    dlog(
                        "browser.panel.hostedInspector stage=\(reason).captureMissingCandidate " +
                        "host=\(Self.debugObjectID(self)) preferredWidth=\(preferredWidthDesc)"
                    )
                }
#endif
                return
            }

            let inspectorWidth = max(0, hit.inspectorView.frame.width)
            guard inspectorWidth > 1 else { return }
            recordHostedInspectorSideDockWidth(inspectorWidth)
            let currentFraction: CGFloat? = {
                guard hit.containerView.bounds.width > 0 else { return nil }
                return inspectorWidth / hit.containerView.bounds.width
            }()
            let widthMatches = preferredHostedInspectorWidth.map {
                abs($0 - inspectorWidth) <= 0.5
            } ?? false
            let fractionMatches: Bool = {
                switch (preferredHostedInspectorWidthFraction, currentFraction) {
                case (nil, nil):
                    return true
                case let (lhs?, rhs?):
                    return abs(lhs - rhs) <= 0.001
                default:
                    return false
                }
            }()
            guard !(widthMatches && fractionMatches) else { return }

#if DEBUG
            hasLoggedMissingHostedInspectorCandidate = false
#endif
            recordPreferredHostedInspectorWidth(
                inspectorWidth,
                containerBounds: hit.containerView.bounds
            )
        }

        private func reapplyHostedInspectorDividerToStoredWidthIfNeeded(reason: String) {
            guard !isApplyingHostedInspectorLayout else { return }
            guard let hit = hostedInspectorDividerCandidate() else { return }
            guard let preferredWidth = resolvedPreferredHostedInspectorWidth(in: hit.containerView.bounds) else {
                return
            }
            let currentInspectorWidth = max(0, hit.inspectorView.frame.width)
            guard abs(currentInspectorWidth - preferredWidth) > 0.5 else { return }
            _ = applyHostedInspectorDividerWidth(
                preferredWidth,
                to: hit,
                minimumInspectorWidth: Self.minimumHostedInspectorWidth,
                reason: reason
            )
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
            recordHostedInspectorSideDockWidth(inspectorFrame.width)

            isApplyingHostedInspectorLayout = true
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hit.pageView.frame = pageFrame
            hit.inspectorView.frame = inspectorFrame
            CATransaction.commit()
            isApplyingHostedInspectorLayout = false

            hit.pageView.needsDisplay = true
            hit.pageView.setNeedsDisplay(hit.pageView.bounds)
            hit.inspectorView.needsDisplay = true
            hit.inspectorView.setNeedsDisplay(hit.inspectorView.bounds)
            hit.containerView.needsDisplay = true
            hit.containerView.setNeedsDisplay(hit.containerView.bounds)
            if let localInlineSlotView {
                localInlineSlotView.needsDisplay = true
                localInlineSlotView.setNeedsDisplay(localInlineSlotView.bounds)
            }
            needsDisplay = true
            setNeedsDisplay(bounds)

            let isLiveDrag = reason == "drag"
#if DEBUG
            dlog(
                "browser.panel.hostedInspector stage=\(reason).reapply " +
                "host=\(Self.debugObjectID(self)) preferredWidth=\(String(format: "%.1f", preferredWidth)) " +
                "liveDrag=\(isLiveDrag ? 1 : 0) " +
                "pageChanged=\(pageChanged ? 1 : 0) inspectorChanged=\(inspectorChanged ? 1 : 0) " +
                "oldPage=\(Self.debugRect(oldPageFrame)) oldInspector=\(Self.debugRect(oldInspectorFrame)) " +
                "container=\(Self.debugObjectID(hit.containerView)) " +
                "pageFrame=\(Self.debugRect(pageFrame)) inspectorFrame=\(Self.debugRect(inspectorFrame))"
            )
#endif
            return (pageFrame, inspectorFrame)
        }

        private static func directChild(of container: NSView, containing descendant: NSView) -> NSView? {
            var current: NSView? = descendant
            var directChild: NSView?
            while let view = current, view !== container {
                directChild = view
                current = view.superview
            }
            guard current === container else { return nil }
            return directChild
        }
    }

    #if DEBUG
    private static func logDevToolsState(
        _ panel: BrowserPanel,
        event: String,
        generation: Int,
        retryCount: Int,
        details: String? = nil
    ) {
        var line = "browser.devtools event=\(event) panel=\(panel.id.uuidString.prefix(5)) generation=\(generation) retry=\(retryCount) \(panel.debugDeveloperToolsStateSummary())"
        if let details, !details.isEmpty {
            line += " \(details)"
        }
        dlog(line)
    }

    private static func objectID(_ object: AnyObject?) -> String {
        guard let object else { return "nil" }
        return String(describing: Unmanaged.passUnretained(object).toOpaque())
    }

    private static func responderDescription(_ responder: NSResponder?) -> String {
        guard let responder else { return "nil" }
        return "\(type(of: responder))@\(objectID(responder))"
    }

    private static func rectDescription(_ rect: NSRect) -> String {
        String(format: "%.1f,%.1f %.1fx%.1f", rect.origin.x, rect.origin.y, rect.size.width, rect.size.height)
    }

    private static func attachContext(webView: WKWebView, host: NSView) -> String {
        let hostWindow = host.window?.windowNumber ?? -1
        let webWindow = webView.window?.windowNumber ?? -1
        let firstResponder = (webView.window ?? host.window)?.firstResponder
        return "host=\(objectID(host)) hostWin=\(hostWindow) hostInWin=\(host.window == nil ? 0 : 1) hostFrame=\(rectDescription(host.frame)) hostBounds=\(rectDescription(host.bounds)) oldSuper=\(objectID(webView.superview)) webWin=\(webWindow) webInWin=\(webView.window == nil ? 0 : 1) webFrame=\(rectDescription(webView.frame)) webHidden=\(webView.isHidden ? 1 : 0) fr=\(responderDescription(firstResponder))"
    }
    #endif

    private static func firstResponderResignState(
        _ responder: NSResponder?,
        webView: WKWebView
    ) -> (needsResign: Bool, flags: String) {
        let inWebViewChain = InspectorDock.responderChainContains(responder, target: webView)
        let inspectorResponder = InspectorDock.isLikelyInspectorResponder(responder)
        let needsResign = inWebViewChain || inspectorResponder
        return (
            needsResign: needsResign,
            flags: "frInWebChain=\(inWebViewChain ? 1 : 0) frIsInspector=\(inspectorResponder ? 1 : 0)"
        )
    }

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator()
        coordinator.panel = panel
        return coordinator
    }

    func makeNSView(context: Context) -> NSView {
        let container = HostContainerView()
        container.wantsLayer = true
        return container
    }

    private static func clearPortalCallbacks(for host: NSView) {
        guard let host = host as? HostContainerView else { return }
        host.onDidMoveToWindow = nil
        host.onGeometryChanged = nil
        host.clearLocalInlineCallbacks()
    }

    private static func shouldPreserveExternalFullscreenHost(
        for webView: WKWebView,
        relativeTo expectedWindow: NSWindow?
    ) -> Bool {
        webView.programaIsManagedByExternalFullscreenWindow(relativeTo: expectedWindow)
    }

    private static func localInlineTransferRoot(for webView: WKWebView) -> NSView? {
        var current = webView.superview
        var last: NSView?
        while let view = current {
            if view is WindowBrowserSlotView {
                return view
            }
            if view is HostContainerView {
                break
            }
            last = view
            current = view.superview
        }
        return last ?? webView.superview
    }

    private static func directTransferChild(of container: NSView, containing descendant: NSView) -> NSView? {
        var current: NSView? = descendant
        var directChild: NSView?
        while let view = current, view !== container {
            directChild = view
            current = view.superview
        }
        guard current === container else { return nil }
        return directChild
    }

    private static func relatedWebKitTransferSubviews(
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

    private static func moveWebKitRelatedSubviewsIntoHostIfNeeded(
        from sourceSuperview: NSView,
        to container: WindowBrowserSlotView,
        primaryWebView: WKWebView,
        reason: String
    ) {
        let relatedSubviews = relatedWebKitTransferSubviews(
            from: sourceSuperview,
            primaryWebView: primaryWebView
        )
        guard !relatedSubviews.isEmpty else { return }
        let preserveSlotLocalFrames = sourceSuperview is WindowBrowserSlotView
        let sourceSlotBoundsSize = sourceSuperview.bounds.size
        var movedSubviewCount = 0
        var reusedSourceLocalFrames = false
#if DEBUG
        dlog(
            "browser.localHost.reparent.batch reason=\(reason) source=\(Self.objectID(sourceSuperview)) " +
            "container=\(Self.objectID(container)) count=\(relatedSubviews.count) " +
            "sourceType=\(String(describing: type(of: sourceSuperview))) targetType=\(String(describing: type(of: container)))"
        )
#endif
        for view in relatedSubviews {
            if view === container || view.isDescendant(of: container) {
                continue
            }
            let className = String(describing: type(of: view))
            let targetFrame: NSRect
            let currentSuperview = view.superview
            if preserveSlotLocalFrames && currentSuperview === sourceSuperview {
                targetFrame = view.frame
                reusedSourceLocalFrames = true
            } else {
                let frameInWindow = currentSuperview?.convert(view.frame, to: nil)
                    ?? sourceSuperview.convert(view.frame, to: nil)
                targetFrame = container.convert(frameInWindow, from: nil)
            }
            view.removeFromSuperview()
            container.addSubview(view, positioned: .above, relativeTo: nil)
            view.frame = targetFrame
            movedSubviewCount += 1
#if DEBUG
            dlog(
                "browser.localHost.reparent.batch.item reason=\(reason) class=\(className) " +
                "view=\(Self.objectID(view))"
            )
#endif
        }
        guard movedSubviewCount > 0 else { return }
        if reusedSourceLocalFrames, sourceSlotBoundsSize != container.bounds.size {
            container.resizeSubviews(withOldSize: sourceSlotBoundsSize)
            container.needsLayout = true
            container.layoutSubtreeIfNeeded()
        }
    }

    private static func installPortalAnchorView(_ anchorView: NSView, in host: NSView) {
        // SwiftUI can keep transient replacement hosts alive off-window during split
        // reparenting. Never let those hosts steal the shared portal anchor, or the
        // portal will bind against an anchor with no real window and WKWebView will
        // fall into a hidden/unrendered state.
        guard host.window != nil else { return }
        if anchorView.superview !== host {
            anchorView.removeFromSuperview()
            anchorView.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(anchorView)
            NSLayoutConstraint.activate([
                anchorView.topAnchor.constraint(equalTo: host.topAnchor),
                anchorView.bottomAnchor.constraint(equalTo: host.bottomAnchor),
                anchorView.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                anchorView.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            ])
        } else if anchorView.translatesAutoresizingMaskIntoConstraints {
            anchorView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                anchorView.topAnchor.constraint(equalTo: host.topAnchor),
                anchorView.bottomAnchor.constraint(equalTo: host.bottomAnchor),
                anchorView.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                anchorView.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            ])
        }
        host.layoutSubtreeIfNeeded()
    }

    private func updateUsingLocalInlineHosting(_ nsView: NSView, context: Context, webView: WKWebView) -> Bool {
        guard let host = nsView as? HostContainerView else { return false }
        let slotView = host.ensureLocalInlineSlotView()
        let isAlreadyInLocalHost = host.containsManagedLocalInlineContent(webView)
        let shouldPreserveExternalFullscreenHost = Self.shouldPreserveExternalFullscreenHost(
            for: webView,
            relativeTo: host.window
        )
        let didAttachWebViewToLocalHost =
            !isAlreadyInLocalHost && !shouldPreserveExternalFullscreenHost

        let coordinator = context.coordinator
        coordinator.desiredPortalVisibleInUI = false
        coordinator.desiredPortalZPriority = 0
        coordinator.attachGeneration += 1

        if panel.releasePortalHostIfOwned(
            hostId: ObjectIdentifier(host),
            reason: "localInlineHosting"
        ) {
            BrowserWindowPortalRegistry.discard(
                webView: webView,
                source: "viewStateChanged.localInlineHosting",
                preserveCurrentSuperview: true
            )
        }

        let shouldPreserveExistingExternalLocalHost =
            host.window == nil &&
            webView.superview != nil &&
            !host.containsManagedLocalInlineContent(webView)
        if shouldPreserveExistingExternalLocalHost {
            // Split zoom can instantiate a replacement local host before it joins a window.
            // Never let that off-window host steal the live page + inspector hierarchy away
            // from the currently visible local host.
            host.setLocalInlineSlotHidden(true)
            coordinator.lastPortalHostId = nil
            coordinator.lastSynchronizedHostGeometryRevision = 0
#if DEBUG
            dlog(
                "browser.localHost.reparent.skip web=\(Self.objectID(webView)) " +
                "reason=offWindowReplacementHost super=\(Self.objectID(webView.superview)) " +
                "host=\(Self.objectID(host)) slot=\(Self.objectID(slotView))"
            )
            Self.logDevToolsState(
                panel,
                event: "localHost.skip",
                generation: coordinator.attachGeneration,
                retryCount: 0,
                details: Self.attachContext(webView: webView, host: host)
            )
#endif
            return false
        }

#if DEBUG
        if shouldPreserveExternalFullscreenHost {
            dlog(
                "browser.localHost.reparent.skip web=\(Self.objectID(webView)) " +
                "reason=fullscreenExternalHost host=\(Self.objectID(host)) " +
                "slot=\(Self.objectID(slotView)) state=\(String(describing: webView.fullscreenState))"
            )
        }
#endif

        let preferredAttachedWidthState = panel.preferredAttachedDeveloperToolsWidthState()
        host.setPreferredHostedInspectorWidth(
            width: preferredAttachedWidthState.width,
            widthFraction: preferredAttachedWidthState.widthFraction
        )
        host.setHostedInspectorFrontendWebView(webView.programaInspectorFrontendWebView())
        host.onPreferredHostedInspectorWidthChanged = { [weak browserPanel = panel] width, _ in
            guard let browserPanel else { return }
            browserPanel.recordPreferredAttachedDeveloperToolsWidth(
                width,
                containerBounds: slotView.bounds
            )
        }
        slotView.onHostedInspectorLayout = { [weak host] _ in
            host?.scheduleHostedInspectorDividerReapply(reason: "slot.layout")
            host?.scheduleHostedInspectorDockConfigurationSync(reason: "slot.layout")
        }

        if didAttachWebViewToLocalHost {
            if let sourceSuperview = Self.localInlineTransferRoot(for: webView) {
                Self.moveWebKitRelatedSubviewsIntoHostIfNeeded(
                    from: sourceSuperview,
                    to: slotView,
                    primaryWebView: webView,
                    reason: "attachLocalHost"
                )
            } else {
                slotView.addSubview(webView, positioned: .above, relativeTo: nil)
            }
        }

        slotView.isHidden = false
        host.pinHostedWebView(
            webView,
            in: host.currentHostedWebViewContainer(preferredSlotView: slotView)
        )
        // Local-inline hosting takes ownership of the live WKWebView hierarchy.
        // Drop any stale portal entry once local-inline hosting owns the live
        // WKWebView hierarchy so deferred portal recovery cannot mutate the
        // browser after workspace switches.
        BrowserWindowPortalRegistry.discard(
            webView: webView,
            source: "viewStateChanged.localInlineHosting",
            preserveCurrentSuperview: true
        )
        coordinator.lastPortalHostId = nil
        coordinator.lastSynchronizedHostGeometryRevision = 0
        if host.window != nil && !shouldPreserveExternalFullscreenHost {
            let wasDeveloperToolsVisible = panel.isDeveloperToolsVisible()
            panel.noteDeveloperToolsHostAttached()
            panel.restoreDeveloperToolsAfterAttachIfNeeded()
            if let sourceSuperview = Self.localInlineTransferRoot(for: webView),
               didAttachWebViewToLocalHost || sourceSuperview === slotView {
                Self.moveWebKitRelatedSubviewsIntoHostIfNeeded(
                    from: sourceSuperview,
                    to: slotView,
                    primaryWebView: webView,
                    reason: didAttachWebViewToLocalHost
                        ? "localInline.reconcile.immediate"
                        : "localInline.reconcile.existingHost"
                )
            }
            host.setHostedInspectorFrontendWebView(webView.programaInspectorFrontendWebView())
            let didRevealDeveloperToolsAfterAttach =
                !wasDeveloperToolsVisible && panel.isDeveloperToolsVisible()
            webView.needsLayout = true
            webView.layoutSubtreeIfNeeded()
            slotView.layoutSubtreeIfNeeded()
            host.layoutSubtreeIfNeeded()
            host.refreshHostedWebKitPresentation(
                reason: didAttachWebViewToLocalHost
                    ? "localInline.update.immediate"
                    : "localInline.update.existingHost",
                forceLifecycleRefresh: didRevealDeveloperToolsAfterAttach
            )
            host.normalizeHostedInspectorLayoutIfNeeded(
                reason: didAttachWebViewToLocalHost
                    ? "localInline.update.immediate"
                    : "localInline.update.existingHost"
            )
            host.scheduleHostedInspectorDividerReapply(
                reason: didAttachWebViewToLocalHost
                    ? "localInline.update.sync"
                    : "localInline.update.existingHost"
            )
            DispatchQueue.main.async { [weak host, weak webView] in
                guard let host, let webView else { return }
                if let sourceSuperview = Self.localInlineTransferRoot(for: webView),
                   sourceSuperview === slotView {
                    Self.moveWebKitRelatedSubviewsIntoHostIfNeeded(
                        from: sourceSuperview,
                        to: slotView,
                        primaryWebView: webView,
                        reason: "localInline.reconcile.async"
                    )
                }
                host.setHostedInspectorFrontendWebView(webView.programaInspectorFrontendWebView())
                host.refreshHostedWebKitPresentation(
                    reason: didAttachWebViewToLocalHost
                        ? "localInline.update.async"
                        : "localInline.update.existingHost.async",
                    forceLifecycleRefresh: didRevealDeveloperToolsAfterAttach
                )
                host.scheduleHostedInspectorDockConfigurationSync(
                    reason: didAttachWebViewToLocalHost
                        ? "localInline.update.async"
                        : "localInline.update.existingHost.async"
                )
            }
        } else if !shouldPreserveExternalFullscreenHost {
            panel.consumeAttachedDeveloperToolsManualCloseIfNeeded()
            host.scheduleHostedInspectorDockConfigurationSync(reason: "localInline.update")
        }

#if DEBUG
        Self.logDevToolsState(
            panel,
            event: "localHost.update",
            generation: coordinator.attachGeneration,
            retryCount: 0,
            details: Self.attachContext(webView: webView, host: host)
        )
#endif
        return !shouldPreserveExternalFullscreenHost
    }

    private func updateUsingWindowPortal(_ nsView: NSView, context: Context, webView: WKWebView) -> Bool {
        guard let host = nsView as? HostContainerView else { return false }
        host.prepareForWindowPortalHosting()
        host.setLocalInlineSlotHidden(true)
        host.releaseHostedWebViewConstraints()
        if panel.shouldUseLocalInlineDeveloperToolsHosting() {
            let hostId = ObjectIdentifier(host)
            if panel.releasePortalHostIfOwned(
                hostId: hostId,
                reason: "windowPortalSuppressedForLocalInlineHosting"
            ) {
                BrowserWindowPortalRegistry.discard(
                    webView: webView,
                    source: "viewStateChanged.windowPortalSuppressedForLocalInlineHosting",
                    preserveCurrentSuperview: true
                )
            }
            return false
        }
        let shouldPreserveExternalFullscreenHost = Self.shouldPreserveExternalFullscreenHost(
            for: webView,
            relativeTo: host.window
        )

        let coordinator = context.coordinator
        let paneDropContext = currentPaneDropContext()
        let isCurrentPaneOwner = paneDropContext?.paneId.id == paneId.id
        let hostId = ObjectIdentifier(host)
        let previousVisible = coordinator.desiredPortalVisibleInUI
        let previousZPriority = coordinator.desiredPortalZPriority
        coordinator.desiredPortalVisibleInUI = shouldAttachWebView && isCurrentPaneOwner
        coordinator.desiredPortalZPriority = portalZPriority
        coordinator.attachGeneration += 1
        let generation = coordinator.attachGeneration
        let activePaneDropContext = coordinator.desiredPortalVisibleInUI ? paneDropContext : nil
        let activeSearchOverlay = coordinator.desiredPortalVisibleInUI ? searchOverlay : nil
        let portalAnchorView = panel.portalAnchorView
        let portalHideReason = !isCurrentPaneOwner ? "lostPaneOwnership" : "hidden"
        let didReleasePortalHost: Bool
        if !shouldAttachWebView || !isCurrentPaneOwner {
            didReleasePortalHost = panel.releasePortalHostIfOwned(
                hostId: hostId,
                reason: portalHideReason
            )
            // Only the host that currently owns the portal is allowed to hide it.
            // Older keep-alive hosts can still receive updates after a new owner binds.
            if didReleasePortalHost {
                BrowserWindowPortalRegistry.hide(
                    webView: webView,
                    source: "viewStateChanged.\(portalHideReason)"
                )
            }
        } else {
            didReleasePortalHost = false
        }
        let portalHostAccepted =
            shouldAttachWebView &&
            isCurrentPaneOwner &&
            panel.claimPortalHost(
                hostId: hostId,
                paneId: paneId,
                inWindow: host.window != nil,
                bounds: host.bounds,
                reason: "update"
            )
#if DEBUG
        if !isCurrentPaneOwner && (shouldAttachWebView || host.window != nil) {
            dlog(
                "browser.portal.owner.skip panel=\(panel.id.uuidString.prefix(5)) " +
                "viewPane=\(paneId.id.uuidString.prefix(5)) " +
                "currentPane=\(paneDropContext?.paneId.id.uuidString.prefix(5) ?? "nil") " +
                "host=\(Self.objectID(host)) hostInWin=\(host.window != nil ? 1 : 0) " +
                "released=\(didReleasePortalHost ? 1 : 0)"
            )
        }
#endif
        if host.window != nil, portalHostAccepted {
            Self.installPortalAnchorView(portalAnchorView, in: host)
        }

        host.onDidMoveToWindow = { [weak host, weak webView, weak coordinator, weak portalAnchorView, weak browserPanel = panel] in
            guard let host, let webView, let coordinator, let portalAnchorView, let browserPanel else { return }
            guard coordinator.attachGeneration == generation else { return }
            guard currentPaneDropContext()?.paneId.id == paneId.id else { return }
            guard browserPanel.claimPortalHost(
                hostId: ObjectIdentifier(host),
                paneId: paneId,
                inWindow: host.window != nil,
                bounds: host.bounds,
                reason: "didMoveToWindow"
            ) else { return }
            guard host.window != nil else { return }
            Self.installPortalAnchorView(portalAnchorView, in: host)
            BrowserWindowPortalRegistry.bind(
                webView: webView,
                to: portalAnchorView,
                visibleInUI: coordinator.desiredPortalVisibleInUI,
                zPriority: coordinator.desiredPortalZPriority
            )
            BrowserWindowPortalRegistry.refresh(
                webView: webView,
                reason: "portalHostBind.didMoveToWindow"
            )
            BrowserWindowPortalRegistry.updatePaneTopChromeHeight(
                for: webView,
                height: coordinator.desiredPortalVisibleInUI ? paneTopChromeHeight : 0
            )
            BrowserWindowPortalRegistry.updatePaneDropContext(for: webView, context: activePaneDropContext)
            BrowserWindowPortalRegistry.updateSearchOverlay(for: webView, configuration: activeSearchOverlay)
            coordinator.lastPortalHostId = ObjectIdentifier(host)
            coordinator.lastSynchronizedHostGeometryRevision = host.geometryRevision
        }
        host.onGeometryChanged = { [weak host, weak webView, weak coordinator, weak portalAnchorView, weak browserPanel = panel] in
            guard let host, let webView, let coordinator, let portalAnchorView, let browserPanel else { return }
            guard coordinator.attachGeneration == generation else { return }
            guard currentPaneDropContext()?.paneId.id == paneId.id else { return }
            guard browserPanel.claimPortalHost(
                hostId: ObjectIdentifier(host),
                paneId: paneId,
                inWindow: host.window != nil,
                bounds: host.bounds,
                reason: "geometryChanged"
            ) else { return }
            guard host.window != nil else { return }
            let hostId = ObjectIdentifier(host)
            Self.installPortalAnchorView(portalAnchorView, in: host)
            if coordinator.lastPortalHostId != hostId ||
               !BrowserWindowPortalRegistry.isWebView(webView, boundTo: portalAnchorView) {
                BrowserWindowPortalRegistry.bind(
                    webView: webView,
                    to: portalAnchorView,
                    visibleInUI: coordinator.desiredPortalVisibleInUI,
                    zPriority: coordinator.desiredPortalZPriority
                )
                BrowserWindowPortalRegistry.refresh(
                    webView: webView,
                    reason: "portalHostBind.geometryChanged"
                )
                BrowserWindowPortalRegistry.updatePaneTopChromeHeight(
                    for: webView,
                    height: coordinator.desiredPortalVisibleInUI ? paneTopChromeHeight : 0
                )
                BrowserWindowPortalRegistry.updatePaneDropContext(for: webView, context: activePaneDropContext)
                BrowserWindowPortalRegistry.updateSearchOverlay(for: webView, configuration: activeSearchOverlay)
                coordinator.lastPortalHostId = hostId
            }
            BrowserWindowPortalRegistry.synchronizeForAnchor(portalAnchorView)
            coordinator.lastSynchronizedHostGeometryRevision = host.geometryRevision
        }

        if !shouldAttachWebView {
            // In portal mode we no longer detach/re-attach to preserve DevTools state.
            // Sync the inspector preference directly so manual closes are respected.
            panel.syncDeveloperToolsPreferenceFromInspector(
                preserveVisibleIntent: panel.shouldPreserveDeveloperToolsIntentWhileDetached()
            )
        }

        if host.window != nil, portalHostAccepted {
            let geometryRevision = host.geometryRevision
            let portalEntryMissing = !BrowserWindowPortalRegistry.isWebView(webView, boundTo: portalAnchorView)
            let shouldBindNow =
                coordinator.lastPortalHostId != hostId ||
                webView.superview == nil ||
                portalEntryMissing ||
                previousVisible != shouldAttachWebView ||
                previousZPriority != portalZPriority
            if shouldBindNow {
                Self.installPortalAnchorView(portalAnchorView, in: host)
                BrowserWindowPortalRegistry.bind(
                    webView: webView,
                    to: portalAnchorView,
                    visibleInUI: coordinator.desiredPortalVisibleInUI,
                    zPriority: coordinator.desiredPortalZPriority
                )
                // Force a rendering-state reattach after portal host replacement
                // (e.g. after a pane split). Without this, WKWebView can freeze
                // because _exitInWindow/_enterInWindow are never cycled when the
                // web view is reparented to a new container during bind.
                BrowserWindowPortalRegistry.refresh(
                    webView: webView,
                    reason: "portalHostBind"
                )
                coordinator.lastPortalHostId = hostId
                coordinator.lastSynchronizedHostGeometryRevision = geometryRevision
            }
            BrowserWindowPortalRegistry.updatePaneTopChromeHeight(
                for: webView,
                height: coordinator.desiredPortalVisibleInUI ? paneTopChromeHeight : 0
            )
            BrowserWindowPortalRegistry.updateSearchOverlay(for: webView, configuration: activeSearchOverlay)
            if !shouldBindNow,
               coordinator.lastSynchronizedHostGeometryRevision != geometryRevision {
                BrowserWindowPortalRegistry.synchronizeForAnchor(portalAnchorView)
                coordinator.lastSynchronizedHostGeometryRevision = geometryRevision
            }
        } else if portalHostAccepted {
            // Bind is deferred until host moves into a window. Keep the current
            // portal entry's desired state in sync so stale callbacks cannot keep
            // the previous anchor visible while this host is temporarily off-window.
            BrowserWindowPortalRegistry.updateEntryVisibility(
                for: webView,
                visibleInUI: coordinator.desiredPortalVisibleInUI,
                zPriority: coordinator.desiredPortalZPriority
            )
        }

        if portalHostAccepted {
            BrowserWindowPortalRegistry.updateDropZoneOverlay(
                for: webView,
                zone: coordinator.desiredPortalVisibleInUI ? paneDropZone : nil
            )
            BrowserWindowPortalRegistry.updatePaneTopChromeHeight(
                for: webView,
                height: coordinator.desiredPortalVisibleInUI ? paneTopChromeHeight : 0
            )
            BrowserWindowPortalRegistry.updatePaneDropContext(
                for: webView,
                context: activePaneDropContext
            )
            BrowserWindowPortalRegistry.updateSearchOverlay(for: webView, configuration: activeSearchOverlay)
        }

        panel.restoreDeveloperToolsAfterAttachIfNeeded()

        #if DEBUG
        Self.logDevToolsState(
            panel,
            event: "portal.update",
            generation: coordinator.attachGeneration,
            retryCount: 0,
            details: Self.attachContext(webView: webView, host: host)
        )
        #endif
        return portalHostAccepted && !shouldPreserveExternalFullscreenHost
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let webView = panel.webView
        let coordinator = context.coordinator
        let isCurrentPaneOwner = currentPaneDropContext()?.paneId.id == paneId.id
        if let previousWebView = coordinator.webView, previousWebView !== webView {
            BrowserWindowPortalRegistry.detach(webView: previousWebView)
            coordinator.lastPortalHostId = nil
            coordinator.lastSynchronizedHostGeometryRevision = 0
        }
        coordinator.panel = panel
        coordinator.webView = webView

        Self.clearPortalCallbacks(for: nsView)
        let hostOwnsPortal = useLocalInlineHosting
            ? updateUsingLocalInlineHosting(nsView, context: context, webView: webView)
            : updateUsingWindowPortal(nsView, context: context, webView: webView)
        Self.applyWebViewFirstResponderPolicy(
            panel: panel,
            webView: webView,
            isPanelFocused: isPanelFocused && isCurrentPaneOwner && hostOwnsPortal
        )

        Self.applyFocus(
            panel: panel,
            webView: webView,
            nsView: nsView,
            shouldFocusWebView: shouldFocusWebView && isCurrentPaneOwner && hostOwnsPortal,
            isPanelFocused: isPanelFocused && isCurrentPaneOwner && hostOwnsPortal
        )
    }

    private static func applyFocus(
        panel: BrowserPanel,
        webView: WKWebView,
        nsView: NSView,
        shouldFocusWebView: Bool,
        isPanelFocused: Bool
    ) {
        // Focus handling. Avoid fighting the address bar when it is focused.
        guard let window = nsView.window else {
#if DEBUG
            dlog(
                "browser.focus.content.apply panel=\(panel.id.uuidString.prefix(5)) " +
                "action=skip reason=no_window shouldFocus=\(shouldFocusWebView ? 1 : 0) " +
                "panelFocused=\(isPanelFocused ? 1 : 0)"
            )
#endif
            return
        }
        if isPanelFocused && InspectorDock.responderChainContains(window.firstResponder, target: webView) {
            panel.noteWebViewFocused()
        }
        if shouldFocusWebView {
            if panel.shouldSuppressWebViewFocus() {
#if DEBUG
                dlog(
                    "browser.focus.content.apply panel=\(panel.id.uuidString.prefix(5)) " +
                    "action=skip reason=suppressed panelFocused=\(isPanelFocused ? 1 : 0)"
                )
#endif
                return
            }
            if InspectorDock.responderChainContains(window.firstResponder, target: webView) {
#if DEBUG
                dlog(
                    "browser.focus.content.apply panel=\(panel.id.uuidString.prefix(5)) " +
                    "action=skip reason=already_first_responder_chain"
                )
#endif
                return
            }
            let result = window.makeFirstResponder(webView)
            if result {
                panel.noteWebViewFocused()
            }
#if DEBUG
            dlog(
                "browser.focus.content.apply panel=\(panel.id.uuidString.prefix(5)) " +
                "action=focus result=\(result ? 1 : 0) fr=\(responderDescription(window.firstResponder))"
            )
#endif
        } else if !isPanelFocused && InspectorDock.responderChainContains(window.firstResponder, target: webView) {
            // Only force-resign WebView focus when this panel itself is not focused.
            // If the panel is focused but the omnibar-focus state is briefly stale, aggressively
            // clearing first responder here can undo programmatic webview focus (socket tests).
            let result = window.makeFirstResponder(nil)
#if DEBUG
            dlog(
                "browser.focus.content.apply panel=\(panel.id.uuidString.prefix(5)) " +
                "action=resign result=\(result ? 1 : 0) fr=\(responderDescription(window.firstResponder))"
            )
#endif
        }
    }

    private static func applyWebViewFirstResponderPolicy(
        panel: BrowserPanel,
        webView: WKWebView,
        isPanelFocused: Bool
    ) {
        guard let programaWebView = webView as? ProgramaWebView else { return }
        let next = isPanelFocused && !panel.shouldSuppressWebViewFocus()
        if programaWebView.allowsFirstResponderAcquisition != next {
#if DEBUG
            dlog(
                "browser.focus.policy panel=\(panel.id.uuidString.prefix(5)) " +
                "web=\(ObjectIdentifier(programaWebView)) old=\(programaWebView.allowsFirstResponderAcquisition ? 1 : 0) " +
                "new=\(next ? 1 : 0) isPanelFocused=\(isPanelFocused ? 1 : 0) " +
                "suppress=\(panel.shouldSuppressWebViewFocus() ? 1 : 0)"
            )
#endif
        }
        programaWebView.allowsFirstResponderAcquisition = next
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.attachGeneration += 1
        clearPortalCallbacks(for: nsView)
        if let panel = coordinator.panel, let host = nsView as? HostContainerView {
            panel.releasePortalHostIfOwned(
                hostId: ObjectIdentifier(host),
                reason: "dismantle"
            )
        }

        guard let webView = coordinator.webView else { return }
        let panel = coordinator.panel

        // If we're being torn down while the WKWebView (or one of its subviews) is first responder,
        // resign it before detaching.
        let window = webView.window ?? nsView.window
        if let window {
            let state = firstResponderResignState(window.firstResponder, webView: webView)
            if state.needsResign {
                #if DEBUG
                if let panel {
                    logDevToolsState(
                        panel,
                        event: "dismantle.resignFirstResponder",
                        generation: coordinator.attachGeneration,
                        retryCount: 0,
                        details: attachContext(webView: webView, host: nsView) + " " + state.flags
                    )
                }
                #endif
                window.makeFirstResponder(nil)
            }
        }

        // SwiftUI can transiently dismantle/rebuild the browser host view during split
        // rearrangement. Do not detach the portal-hosted WKWebView or clear its pane-drop
        // context here; explicit teardown still happens on real web view replacement and
        // panel teardown, and preserving this state lets internal tab drags re-enter the
        // browser pane while SwiftUI churns underneath.
        BrowserWindowPortalRegistry.updateDropZoneOverlay(for: webView, zone: nil)
        coordinator.lastPortalHostId = nil
        coordinator.lastSynchronizedHostGeometryRevision = 0
    }

    private func currentPaneDropContext() -> BrowserPaneDropContext? {
        guard let app = AppDelegate.shared,
              let manager = app.tabManagerFor(tabId: panel.workspaceId),
              let workspace = manager.tabs.first(where: { $0.id == panel.workspaceId }),
              let paneId = workspace.paneId(forPanelId: panel.id) else {
            return nil
        }
        return BrowserPaneDropContext(
            workspaceId: panel.workspaceId,
            panelId: panel.id,
            paneId: paneId
        )
    }
}
