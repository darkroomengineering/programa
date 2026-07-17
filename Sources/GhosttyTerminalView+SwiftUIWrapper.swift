import Foundation
import SwiftUI
import AppKit
import Metal
import QuartzCore
import Combine
import CoreText
import Darwin
import Carbon.HIToolbox
import Bonsplit
import IOSurface
import UniformTypeIdentifiers

// MARK: - GhosttyTerminalView (SwiftUI Wrapper)
//
// The NSViewRepresentable bridge between SwiftUI panel layout and the
// AppKit-hosted terminal portal (GhosttySurfaceScrollView/GhosttyNSView),
// plus its Coordinator and the private HostContainerView it manages.
//
// Split out of GhosttyTerminalView.swift (Nuclear Review #97). Extracted
// verbatim, so call-site behavior is unchanged.

// MARK: - SwiftUI Wrapper

struct GhosttyTerminalView: NSViewRepresentable {
    @Environment(\.paneDropZone) var paneDropZone

    let terminalSurface: TerminalSurface
    let paneId: PaneID
    var isActive: Bool = true
    var isVisibleInUI: Bool = true
    var portalZPriority: Int = 0
    var showsInactiveOverlay: Bool = false
    var showsUnreadNotificationRing: Bool = false
    var inactiveOverlayColor: NSColor = .clear
    var inactiveOverlayOpacity: Double = 0
    var searchState: TerminalSurface.SearchState? = nil
    var reattachToken: UInt64 = 0
    var onFocus: ((UUID) -> Void)? = nil
    var onTriggerFlash: (() -> Void)? = nil

    private final class HostContainerView: NSView {
        private static var nextInstanceSerial: UInt64 = 0

        var onDidMoveToWindow: (() -> Void)?
        var onGeometryChanged: (() -> Void)?
        let instanceSerial: UInt64
        private(set) var geometryRevision: UInt64 = 0
        private var lastReportedGeometryState: GeometryState?

        override init(frame frameRect: NSRect) {
            Self.nextInstanceSerial &+= 1
            instanceSerial = Self.nextInstanceSerial
            super.init(frame: frameRect)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) not implemented")
        }

        private struct GeometryState: Equatable {
            let frame: CGRect
            let bounds: CGRect
            let windowNumber: Int?
            let superviewID: ObjectIdentifier?
        }

        private func currentGeometryState() -> GeometryState {
            GeometryState(
                frame: frame,
                bounds: bounds,
                windowNumber: window?.windowNumber,
                superviewID: superview.map(ObjectIdentifier.init)
            )
        }

        private func notifyGeometryChangedIfNeeded() {
            let state = currentGeometryState()
            guard state != lastReportedGeometryState else { return }
            lastReportedGeometryState = state
            geometryRevision &+= 1
            onGeometryChanged?()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onDidMoveToWindow?()
            notifyGeometryChangedIfNeeded()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            notifyGeometryChangedIfNeeded()
        }

        override func layout() {
            super.layout()
            notifyGeometryChangedIfNeeded()
        }

        override func setFrameOrigin(_ newOrigin: NSPoint) {
            super.setFrameOrigin(newOrigin)
            notifyGeometryChangedIfNeeded()
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            notifyGeometryChangedIfNeeded()
        }
    }

    final class Coordinator {
        var attachGeneration: Int = 0
        // Track the latest desired state so attach retries can re-apply focus after re-parenting.
        var desiredIsActive: Bool = true
        var desiredIsVisibleInUI: Bool = true
        var desiredShowsUnreadNotificationRing: Bool = false
        var desiredPortalZPriority: Int = 0
        var lastBoundHostId: ObjectIdentifier?
        var lastPaneDropZone: DropZone?
        var lastSynchronizedHostGeometryRevision: UInt64 = 0
        weak var hostedView: GhosttySurfaceScrollView?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    static func shouldApplyImmediateHostedStateUpdate(
        hostedViewHasSuperview: Bool,
        isBoundToCurrentHost: Bool
    ) -> Bool {
        // If this update originates from a stale/replaced host while the hosted view is
        // already attached elsewhere, do not mutate visibility/active state here.
        if isBoundToCurrentHost { return true }
        return !hostedViewHasSuperview
    }

    static func shouldSynchronizePortalGeometryImmediately(
        hostInLiveResize: Bool,
        windowInLiveResize: Bool,
        interactiveGeometryResizeActive: Bool
    ) -> Bool {
        hostInLiveResize || windowInLiveResize || interactiveGeometryResizeActive
    }

    private static func synchronizePortalGeometry(
        for host: HostContainerView,
        coordinator: Coordinator
    ) {
        let geometryRevision = host.geometryRevision
        guard coordinator.lastSynchronizedHostGeometryRevision != geometryRevision else { return }
        coordinator.lastSynchronizedHostGeometryRevision = geometryRevision
        let window = host.window
        if shouldSynchronizePortalGeometryImmediately(
            hostInLiveResize: host.inLiveResize,
            windowInLiveResize: window?.inLiveResize == true,
            interactiveGeometryResizeActive: TerminalWindowPortalRegistry.isInteractiveGeometryResizeActive
        ) {
            TerminalWindowPortalRegistry.synchronizeForAnchor(host)
            return
        }
        // Avoid synchronizing the terminal portal while AppKit is still inside
        // the current layout turn. Re-entrant syncs here can wedge window resize
        // handling and leave the app spinning on the wait cursor.
        guard let window else { return }
        TerminalWindowPortalRegistry.scheduleExternalGeometrySynchronize(for: window)
    }

    func makeNSView(context: Context) -> NSView {
        let container = HostContainerView(frame: .zero)
        container.wantsLayer = false
        // The actual terminal surface lives in the AppKit portal layer above SwiftUI.
        // This empty placeholder should not be walked by the accessibility subsystem.
        container.setAccessibilityRole(.none)
        container.setAccessibilityElement(false)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let hostedView = terminalSurface.hostedView
        let coordinator = context.coordinator
        let previousDesiredIsActive = coordinator.desiredIsActive
        let previousDesiredIsVisibleInUI = coordinator.desiredIsVisibleInUI
        let previousDesiredPortalZPriority = coordinator.desiredPortalZPriority
        let desiredStateChanged =
            previousDesiredIsActive != isActive ||
            previousDesiredIsVisibleInUI != isVisibleInUI ||
            previousDesiredPortalZPriority != portalZPriority
        coordinator.desiredIsActive = isActive
        coordinator.desiredIsVisibleInUI = isVisibleInUI
        coordinator.desiredShowsUnreadNotificationRing = showsUnreadNotificationRing
        coordinator.desiredPortalZPriority = portalZPriority
        coordinator.hostedView = hostedView
#if DEBUG
        if desiredStateChanged {
            if let snapshot = AppDelegate.shared?.tabManager?.debugCurrentWorkspaceSwitchSnapshot() {
                let dtMs = (CACurrentMediaTime() - snapshot.startedAt) * 1000
                dlog(
                    "ws.swiftui.update id=\(snapshot.id) dt=\(String(format: "%.2fms", dtMs)) " +
                    "surface=\(terminalSurface.id.uuidString.prefix(5)) visible=\(isVisibleInUI ? 1 : 0) " +
                    "active=\(isActive ? 1 : 0) z=\(portalZPriority) " +
                    "hostWindow=\(nsView.window != nil ? 1 : 0) hostedWindow=\(hostedView.window != nil ? 1 : 0) " +
                    "hostedSuperview=\(hostedView.superview != nil ? 1 : 0)"
                )
            } else {
                dlog(
                    "ws.swiftui.update id=none surface=\(terminalSurface.id.uuidString.prefix(5)) " +
                    "visible=\(isVisibleInUI ? 1 : 0) active=\(isActive ? 1 : 0) z=\(portalZPriority) " +
                    "hostWindow=\(nsView.window != nil ? 1 : 0) hostedWindow=\(hostedView.window != nil ? 1 : 0) " +
                    "hostedSuperview=\(hostedView.superview != nil ? 1 : 0)"
                )
            }
        }
#endif

        let hostContainer = nsView as? HostContainerView
        let hostOwnsPortalNow = hostContainer.map { host in
            terminalSurface.claimPortalHost(
                hostId: ObjectIdentifier(host),
                paneId: paneId,
                instanceSerial: host.instanceSerial,
                inWindow: host.window != nil,
                bounds: host.bounds,
                reason: "update"
            )
        } ?? true

        // Keep the surface lifecycle and handlers updated even if we defer re-parenting.
        hostedView.attachSurface(terminalSurface)
        hostedView.setFocusHandler { onFocus?(terminalSurface.id) }
        hostedView.setTriggerFlashHandler(onTriggerFlash)
        if hostOwnsPortalNow {
            hostedView.setInactiveOverlay(
                color: inactiveOverlayColor,
                opacity: CGFloat(inactiveOverlayOpacity),
                visible: showsInactiveOverlay
            )
            hostedView.setNotificationRing(visible: showsUnreadNotificationRing)
            hostedView.setSearchOverlay(searchState: searchState)
            hostedView.syncKeyStateIndicator(text: terminalSurface.currentKeyStateIndicatorText)
        }
        let portalExpectedSurfaceId = terminalSurface.id
        let portalExpectedGeneration = terminalSurface.portalBindingGeneration()
        func portalBindingStillLive() -> Bool {
            terminalSurface.canAcceptPortalBinding(
                expectedSurfaceId: portalExpectedSurfaceId,
                expectedGeneration: portalExpectedGeneration
            )
        }
        let forwardedDropZone = isVisibleInUI ? paneDropZone : nil
#if DEBUG
        if coordinator.lastPaneDropZone != paneDropZone {
            let oldZone = coordinator.lastPaneDropZone.map { String(describing: $0) } ?? "none"
            let newZone = paneDropZone.map { String(describing: $0) } ?? "none"
            dlog(
                "terminal.paneDropZone surface=\(terminalSurface.id.uuidString.prefix(5)) " +
                "old=\(oldZone) new=\(newZone) " +
                "active=\(isActive ? 1 : 0) visible=\(isVisibleInUI ? 1 : 0) " +
                "inWindow=\(hostedView.window != nil ? 1 : 0)"
            )
            coordinator.lastPaneDropZone = paneDropZone
        }
        if paneDropZone != nil, !isVisibleInUI {
            dlog(
                "terminal.paneDropZone.suppress surface=\(terminalSurface.id.uuidString.prefix(5)) " +
                "requested=\(String(describing: paneDropZone!)) visible=0 active=\(isActive ? 1 : 0)"
            )
        }
#endif
        if hostOwnsPortalNow {
            hostedView.setDropZoneOverlay(zone: forwardedDropZone)
        }

        coordinator.attachGeneration += 1
        let generation = coordinator.attachGeneration

        if let host = hostContainer {
            host.onDidMoveToWindow = { [weak host, weak hostedView, weak coordinator] in
                guard let host, let hostedView, let coordinator else { return }
                guard coordinator.attachGeneration == generation else { return }
                guard terminalSurface.claimPortalHost(
                    hostId: ObjectIdentifier(host),
                    paneId: paneId,
                    instanceSerial: host.instanceSerial,
                    inWindow: host.window != nil,
                    bounds: host.bounds,
                    reason: "didMoveToWindow"
                ) else { return }
                guard host.window != nil else { return }
                guard portalBindingStillLive() else { return }
                TerminalWindowPortalRegistry.bind(
                    hostedView: hostedView,
                    to: host,
                    visibleInUI: coordinator.desiredIsVisibleInUI,
                    zPriority: coordinator.desiredPortalZPriority,
                    expectedSurfaceId: portalExpectedSurfaceId,
                    expectedGeneration: portalExpectedGeneration
                )
                coordinator.lastBoundHostId = ObjectIdentifier(host)
                coordinator.lastSynchronizedHostGeometryRevision = host.geometryRevision
                hostedView.setVisibleInUI(coordinator.desiredIsVisibleInUI)
                hostedView.setActive(coordinator.desiredIsActive)
                hostedView.setNotificationRing(visible: coordinator.desiredShowsUnreadNotificationRing)
            }
            host.onGeometryChanged = { [weak host, weak hostedView, weak coordinator] in
                guard let host, let hostedView, let coordinator else { return }
                guard coordinator.attachGeneration == generation else { return }
                guard terminalSurface.claimPortalHost(
                    hostId: ObjectIdentifier(host),
                    paneId: paneId,
                    instanceSerial: host.instanceSerial,
                    inWindow: host.window != nil,
                    bounds: host.bounds,
                    reason: "geometryChanged"
                ) else { return }
                guard portalBindingStillLive() else { return }
                let hostId = ObjectIdentifier(host)
                if host.window != nil,
                   (coordinator.lastBoundHostId != hostId ||
                    !TerminalWindowPortalRegistry.isHostedView(hostedView, boundTo: host)) {
#if DEBUG
                    dlog(
                        "ws.hostState.rebindOnGeometry surface=\(terminalSurface.id.uuidString.prefix(5)) " +
                        "reason=portalEntryMissing visible=\(coordinator.desiredIsVisibleInUI ? 1 : 0) " +
                        "active=\(coordinator.desiredIsActive ? 1 : 0) z=\(coordinator.desiredPortalZPriority)"
                    )
#endif
                    TerminalWindowPortalRegistry.bind(
                        hostedView: hostedView,
                        to: host,
                        visibleInUI: coordinator.desiredIsVisibleInUI,
                        zPriority: coordinator.desiredPortalZPriority,
                        expectedSurfaceId: portalExpectedSurfaceId,
                        expectedGeneration: portalExpectedGeneration
                    )
                    coordinator.lastBoundHostId = hostId
                    hostedView.setVisibleInUI(coordinator.desiredIsVisibleInUI)
                    hostedView.setActive(coordinator.desiredIsActive)
                    hostedView.setNotificationRing(visible: coordinator.desiredShowsUnreadNotificationRing)
                }
                Self.synchronizePortalGeometry(
                    for: host,
                    coordinator: coordinator
                )
            }

            if host.window != nil, hostOwnsPortalNow {
                let portalBindingLive = portalBindingStillLive()
                let hostId = ObjectIdentifier(host)
                let geometryRevision = host.geometryRevision
                let portalEntryMissing = !TerminalWindowPortalRegistry.isHostedView(hostedView, boundTo: host)
                // Notification rings are hosted inside GhosttySurfaceScrollView and update in place.
                // A ring-only state change must not resynchronize the window portal while SwiftUI is
                // invalidating notification UI, or the terminal can be hidden until the next tab switch.
                let shouldBindNow =
                    coordinator.lastBoundHostId != hostId ||
                    hostedView.superview == nil ||
                    portalEntryMissing ||
                    previousDesiredIsVisibleInUI != isVisibleInUI ||
                    previousDesiredPortalZPriority != portalZPriority
                if portalBindingLive && shouldBindNow {
#if DEBUG
                    if portalEntryMissing {
                        dlog(
                            "ws.hostState.rebindOnUpdate surface=\(terminalSurface.id.uuidString.prefix(5)) " +
                            "reason=portalEntryMissing visible=\(coordinator.desiredIsVisibleInUI ? 1 : 0) " +
                            "active=\(coordinator.desiredIsActive ? 1 : 0) z=\(coordinator.desiredPortalZPriority)"
                        )
                    }
#endif
                    TerminalWindowPortalRegistry.bind(
                        hostedView: hostedView,
                        to: host,
                        visibleInUI: coordinator.desiredIsVisibleInUI,
                        zPriority: coordinator.desiredPortalZPriority,
                        expectedSurfaceId: portalExpectedSurfaceId,
                        expectedGeneration: portalExpectedGeneration
                    )
                    coordinator.lastBoundHostId = hostId
                    coordinator.lastSynchronizedHostGeometryRevision = geometryRevision
                } else if portalBindingLive && coordinator.lastSynchronizedHostGeometryRevision != geometryRevision {
                    Self.synchronizePortalGeometry(
                        for: host,
                        coordinator: coordinator
                    )
                }
            } else if hostOwnsPortalNow, portalBindingStillLive() {
                // Bind is deferred until host moves into a window. Update the
                // existing portal entry's visibleInUI now so that any portal sync
                // that runs before the deferred bind completes won't hide the view.
#if DEBUG
                if desiredStateChanged {
                    dlog(
                        "ws.hostState.deferBind surface=\(terminalSurface.id.uuidString.prefix(5)) " +
                        "reason=hostNoWindow visible=\(coordinator.desiredIsVisibleInUI ? 1 : 0) " +
                        "active=\(coordinator.desiredIsActive ? 1 : 0) z=\(coordinator.desiredPortalZPriority) " +
                        "hostedWindow=\(hostedView.window != nil ? 1 : 0) hostedSuperview=\(hostedView.superview != nil ? 1 : 0)"
                    )
                }
#endif
                TerminalWindowPortalRegistry.updateEntryVisibility(
                    for: hostedView,
                    visibleInUI: coordinator.desiredIsVisibleInUI
                )
            }
        }

        let hostWindowAttached = hostContainer?.window != nil
        let isBoundToCurrentHost = hostContainer.map { host in
            TerminalWindowPortalRegistry.isHostedView(hostedView, boundTo: host)
        } ?? true
        let shouldApplyImmediateHostedState = hostOwnsPortalNow && Self.shouldApplyImmediateHostedStateUpdate(
            hostedViewHasSuperview: hostedView.superview != nil,
            isBoundToCurrentHost: isBoundToCurrentHost
        )

        if portalBindingStillLive() && shouldApplyImmediateHostedState {
            hostedView.setVisibleInUI(isVisibleInUI)
            hostedView.setActive(isActive)
        } else {
            // Preserve portal entry visibility while a stale host is still receiving SwiftUI updates.
            // The currently bound host remains authoritative for immediate visible/active state.
#if DEBUG
            if desiredStateChanged {
                dlog(
                    "ws.hostState.deferApply surface=\(terminalSurface.id.uuidString.prefix(5)) " +
                    "reason=\(hostOwnsPortalNow ? "staleHostBinding" : "hostOwnershipRejected") " +
                    "hostWindow=\(hostWindowAttached ? 1 : 0) " +
                    "boundToCurrent=\(isBoundToCurrentHost ? 1 : 0) hostedSuperview=\(hostedView.superview != nil ? 1 : 0) " +
                    "visible=\(isVisibleInUI ? 1 : 0) active=\(isActive ? 1 : 0)"
                )
            }
#endif
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.attachGeneration += 1
        coordinator.desiredIsActive = false
        coordinator.desiredIsVisibleInUI = false
        coordinator.desiredShowsUnreadNotificationRing = false
        coordinator.desiredPortalZPriority = 0
        coordinator.lastBoundHostId = nil
        let hostedView = coordinator.hostedView
#if DEBUG
        if let hostedView {
            if let snapshot = AppDelegate.shared?.tabManager?.debugCurrentWorkspaceSwitchSnapshot() {
                let dtMs = (CACurrentMediaTime() - snapshot.startedAt) * 1000
                dlog(
                    "ws.swiftui.dismantle id=\(snapshot.id) dt=\(String(format: "%.2fms", dtMs)) " +
                    "surface=\(hostedView.debugSurfaceId?.uuidString.prefix(5) ?? "nil") " +
                    "inWindow=\(hostedView.window != nil ? 1 : 0)"
                )
            } else {
                dlog(
                    "ws.swiftui.dismantle id=none surface=\(hostedView.debugSurfaceId?.uuidString.prefix(5) ?? "nil") " +
                    "inWindow=\(hostedView.window != nil ? 1 : 0)"
                )
            }
        }
#endif

        if let host = nsView as? HostContainerView {
            host.onDidMoveToWindow = nil
            host.onGeometryChanged = nil
            hostedView?.prepareOwnedPortalHostForTransientReattach(
                hostId: ObjectIdentifier(host),
                reason: "dismantle"
            )
        }

        // SwiftUI can transiently dismantle/rebuild NSViewRepresentable instances during split
        // tree updates. Do not drop the portal lease or force visible/active false here; that
        // causes avoidable blackouts when the same hosted view is rebound moments later.
        hostedView?.setFocusHandler(nil)
        hostedView?.setTriggerFlashHandler(nil)
        hostedView?.setDropZoneOverlay(zone: nil)
        coordinator.hostedView = nil

        nsView.subviews.forEach { $0.removeFromSuperview() }
    }
}
