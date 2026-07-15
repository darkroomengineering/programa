import AppKit
import ObjectiveC
#if DEBUG
import Bonsplit
#endif

#if DEBUG
// Widened from private to internal: also called from
// TerminalWindowPortalRegistry.swift (Nuclear Review #97 split).
func portalDebugToken(_ view: NSView?) -> String {
    guard let view else { return "nil" }
    let ptr = Unmanaged.passUnretained(view).toOpaque()
    return String(describing: ptr)
}

func portalDebugFrame(_ rect: NSRect) -> String {
    String(format: "%.1f,%.1f %.1fx%.1f", rect.origin.x, rect.origin.y, rect.size.width, rect.size.height)
}

func portalDebugFrameInWindow(_ view: NSView?) -> String {
    guard let view else { return "nil" }
    guard view.window != nil else { return "no-window" }
    return portalDebugFrame(view.convert(view.bounds, to: nil))
}
#endif

@MainActor
final class WindowTerminalPortal: HostedViewPortalRegistry {
#if DEBUG
    static var isPointerDragActiveForTesting = false
#endif
    private static let tinyHideThreshold: CGFloat = 1
    private static let minimumRevealWidth: CGFloat = 24
    private static let minimumRevealHeight: CGFloat = 18
    private static let transientRecoveryRetryBudget: Int = 12
#if PROGRAMA_ISSUE_483_PORTAL_RECOVERY
    private static let transientRecoveryEnabled = true
#else
    private static let transientRecoveryEnabled = false
#endif

    private let hostView = WindowTerminalHostView(frame: .zero)
    private let dividerOverlayView = SplitDividerOverlayView(frame: .zero)
    private var installConstraints: [NSLayoutConstraint] = []
    private var hasDeferredFullSyncScheduled = false
    private var hasExternalGeometrySyncScheduled = false
    private var pendingExternalGeometrySyncRequiresImmediate = false
    private var externalGeometrySyncGeneration: UInt64 = 0
#if DEBUG
    private var lastLoggedBonsplitContainerSignature: String?
#endif

    override var hostViewForGeometry: NSView { hostView }

    private struct Entry {
        weak var hostedView: GhosttySurfaceScrollView?
        weak var anchorView: NSView?
        var visibleInUI: Bool
        var zPriority: Int
        var transientRecoveryRetriesRemaining: Int
    }

    private var entriesByHostedId: [ObjectIdentifier: Entry] = [:]
    private var hostedByAnchorId: [ObjectIdentifier: ObjectIdentifier] = [:]

    override init(window: NSWindow) {
        super.init(window: window)
        hostView.wantsLayer = true
        hostView.layer?.masksToBounds = true
        hostView.postsFrameChangedNotifications = true
        hostView.postsBoundsChangedNotifications = true
        hostView.translatesAutoresizingMaskIntoConstraints = false
        dividerOverlayView.translatesAutoresizingMaskIntoConstraints = true
        dividerOverlayView.autoresizingMask = [.width, .height]
        installGeometryObservers(for: window)
        _ = ensureInstalled()
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
            forName: NSSplitView.didResizeSubviewsNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self,
                      let splitView = notification.object as? NSSplitView,
                      let window = self.window,
                      splitView.window === window else { return }
                self.scheduleExternalGeometrySynchronize()
            }
        })
        geometryObservers.append(center.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: hostView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleExternalGeometrySynchronize()
            }
        })
        geometryObservers.append(center.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: hostView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleExternalGeometrySynchronize()
            }
        })
    }

    func scheduleExternalGeometrySynchronize() {
        scheduleExternalGeometrySynchronize(
            forceImmediate: TerminalWindowPortalRegistry.isInteractiveGeometryResizeActive
        )
    }

    func scheduleExternalGeometrySynchronize(forceImmediate: Bool) {
        // Coalesce to the latest request so ancestor/frame churn (for example
        // sidebar toggles) doesn't resize the PTY at stale intermediate widths.
        externalGeometrySyncGeneration &+= 1
        let generation = externalGeometrySyncGeneration
        guard !hasExternalGeometrySyncScheduled else {
            pendingExternalGeometrySyncRequiresImmediate =
                pendingExternalGeometrySyncRequiresImmediate || forceImmediate
            return
        }
        hasExternalGeometrySyncScheduled = true
        let requiresSettledLayout = !(hostView.inLiveResize || window?.inLiveResize == true || forceImmediate)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let performSync = {
                if self.externalGeometrySyncGeneration != generation {
                    self.hasExternalGeometrySyncScheduled = false
                    let followUpRequiresImmediate = self.pendingExternalGeometrySyncRequiresImmediate
                    self.pendingExternalGeometrySyncRequiresImmediate = false
                    self.scheduleExternalGeometrySynchronize(forceImmediate: followUpRequiresImmediate)
                    return
                }
                self.hasExternalGeometrySyncScheduled = false
                self.pendingExternalGeometrySyncRequiresImmediate = false
                self.synchronizeAllEntriesFromExternalGeometryChange()
            }
            if requiresSettledLayout {
                DispatchQueue.main.async(execute: performSync)
            } else {
                performSync()
            }
        }
    }

    private func synchronizeLayoutHierarchy() {
        installedContainerView?.layoutSubtreeIfNeeded()
        installedReferenceView?.layoutSubtreeIfNeeded()
        hostView.superview?.layoutSubtreeIfNeeded()
        hostView.layoutSubtreeIfNeeded()
        _ = synchronizeHostFrameToReference()
    }

#if DEBUG
    override func logHostFrameUpdate(_ frame: NSRect) {
        dlog(
            "portal.hostFrame.update host=\(portalDebugToken(hostView)) " +
            "frame=\(portalDebugFrame(frame))"
        )
    }
#endif

    func synchronizeAllEntriesFromExternalGeometryChange() {
        guard ensureInstalled() else { return }
        synchronizeLayoutHierarchy()
        synchronizeAllHostedViews(excluding: nil)
        reconcileVisibleHostedViewsAfterGeometrySync(reason: "portal.externalGeometrySync")
        // This fires on NSSplitView.didResizeSubviewsNotification (split add/remove),
        // which can change divider geometry without changing the host frame — so the
        // host's frame hooks never run. Force a cursor-rect rebuild so the host drops
        // its stale divider-region cache (see resetCursorRects) and the new divider is
        // grabbable (#6587 review).
        hostView.window?.invalidateCursorRects(for: hostView)
    }

    private func ensureDividerOverlayOnTop() {
        if dividerOverlayView.superview !== hostView {
            dividerOverlayView.frame = hostView.bounds
            hostView.addSubview(dividerOverlayView, positioned: .above, relativeTo: nil)
        } else if hostView.subviews.last !== dividerOverlayView {
            hostView.addSubview(dividerOverlayView, positioned: .above, relativeTo: nil)
        }

        if !Self.rectApproximatelyEqual(dividerOverlayView.frame, hostView.bounds) {
            dividerOverlayView.frame = hostView.bounds
        }
        dividerOverlayView.needsDisplay = true
    }

    @discardableResult
    private func ensureInstalled() -> Bool {
        guard let window else { return false }
        guard let (container, reference) = installedTargetIfStillValid(for: window) ?? installationTarget(for: window)
        else { return false }
        let browserHost = preferredBrowserHost(in: container)

        if hostView.superview !== container ||
            installedContainerView !== container ||
            installedReferenceView !== reference {
            NSLayoutConstraint.deactivate(installConstraints)
            installConstraints.removeAll()

            hostView.removeFromSuperview()
            if let browserHost {
                container.addSubview(hostView, positioned: .below, relativeTo: browserHost)
            } else {
                container.addSubview(hostView, positioned: .above, relativeTo: reference)
            }

            installConstraints = [
                hostView.leadingAnchor.constraint(equalTo: reference.leadingAnchor),
                hostView.trailingAnchor.constraint(equalTo: reference.trailingAnchor),
                hostView.topAnchor.constraint(equalTo: reference.topAnchor),
                hostView.bottomAnchor.constraint(equalTo: reference.bottomAnchor),
            ]
            NSLayoutConstraint.activate(installConstraints)
            installedContainerView = container
            installedReferenceView = reference
        } else if let browserHost {
            if !Self.isView(browserHost, above: hostView, in: container) {
                container.addSubview(hostView, positioned: .below, relativeTo: browserHost)
            }
        } else if !Self.isView(hostView, above: reference, in: container) {
            container.addSubview(hostView, positioned: .above, relativeTo: reference)
        }

        // Keep the drag/mouse forwarding overlay above portal-hosted terminal views.
        if let overlay = objc_getAssociatedObject(window, &fileDropOverlayKey) as? NSView,
           overlay.superview === container,
           !Self.isView(overlay, above: hostView, in: container) {
            container.addSubview(overlay, positioned: .above, relativeTo: hostView)
        }

        synchronizeLayoutHierarchy()
        _ = synchronizeHostFrameToReference()
        ensureDividerOverlayOnTop()

        return true
    }

    private func installedTargetIfStillValid(for window: NSWindow) -> (container: NSView, reference: NSView)? {
        guard let container = installedContainerView,
              let reference = installedReferenceView else {
            return nil
        }

        guard hostView.superview === container,
              container.window === window,
              reference.window === window,
              reference.superview === container else {
            return nil
        }

        return (container, reference)
    }

    private func installationTarget(for window: NSWindow) -> (container: NSView, reference: NSView)? {
        guard let contentView = window.contentView else { return nil }

        // If NSGlassEffectView wraps the original content view, install inside the glass view
        // so terminals are above the glass background but below SwiftUI content.
        if WindowGlassEffect.isGlassEffectView(contentView),
           let foreground = contentView.subviews.first(where: { $0 !== hostView }) {
            return (contentView, foreground)
        }

        guard let themeFrame = contentView.superview else { return nil }
        return (themeFrame, contentView)
    }

    private func preferredBrowserHost(in container: NSView) -> WindowBrowserHostView? {
        container.subviews.last(where: { $0 is WindowBrowserHostView }) as? WindowBrowserHostView
    }

#if DEBUG
    private func nearestBonsplitContainer(from anchorView: NSView) -> NSView? {
        var current: NSView? = anchorView
        while let view = current {
            let className = NSStringFromClass(type(of: view))
            if className.contains("PaneDragContainerView") || className.contains("Bonsplit") {
                return view
            }
            current = view.superview
        }
        return installedReferenceView
    }

    private func logBonsplitContainerFrameIfNeeded(anchorView: NSView, hostedView: GhosttySurfaceScrollView) {
        guard let container = nearestBonsplitContainer(from: anchorView) else { return }
        let containerFrame = container.convert(container.bounds, to: nil)
        let signature = "\(ObjectIdentifier(container)):\(portalDebugFrame(containerFrame))"
        guard signature != lastLoggedBonsplitContainerSignature else { return }
        lastLoggedBonsplitContainerSignature = signature

        let containerClass = NSStringFromClass(type(of: container))
        dlog(
            "portal.bonsplit.container hosted=\(portalDebugToken(hostedView)) " +
            "class=\(containerClass) frame=\(portalDebugFrame(containerFrame)) " +
            "host=\(portalDebugFrameInWindow(hostView)) anchor=\(portalDebugFrameInWindow(anchorView))"
        )
    }
#endif

    private func seededFrameInHost(for anchorView: NSView) -> NSRect? {
        _ = synchronizeHostFrameToReference()
        let frameInWindow = effectiveAnchorFrameInWindow(for: anchorView)
        let frameInHostRaw = hostView.convert(frameInWindow, from: nil)
        let frameInHost = Self.pixelSnappedRect(frameInHostRaw, in: hostView)
        let hasFiniteFrame =
            frameInHost.origin.x.isFinite &&
            frameInHost.origin.y.isFinite &&
            frameInHost.size.width.isFinite &&
            frameInHost.size.height.isFinite
        guard hasFiniteFrame else { return nil }

        let hostBounds = hostView.bounds
        let hasFiniteHostBounds =
            hostBounds.origin.x.isFinite &&
            hostBounds.origin.y.isFinite &&
            hostBounds.size.width.isFinite &&
            hostBounds.size.height.isFinite
        if hasFiniteHostBounds {
            let clampedFrame = frameInHost.intersection(hostBounds)
            if !clampedFrame.isNull, clampedFrame.width > 1, clampedFrame.height > 1 {
                return clampedFrame
            }
        }

        return frameInHost
    }

    func detachHostedView(withId hostedId: ObjectIdentifier) {
        guard let entry = entriesByHostedId.removeValue(forKey: hostedId) else { return }
        if let anchor = entry.anchorView {
            hostedByAnchorId.removeValue(forKey: ObjectIdentifier(anchor))
        }
#if DEBUG
        let hadSuperview = (entry.hostedView?.superview === hostView) ? 1 : 0
        dlog(
            "portal.detach hosted=\(portalDebugToken(entry.hostedView)) " +
            "anchor=\(portalDebugToken(entry.anchorView)) hadSuperview=\(hadSuperview)"
        )
#endif
        if let hostedView = entry.hostedView {
            // A detached (no longer tracked) hosted view must never remain visible in
            // the host; callers that rebind elsewhere reveal explicitly via bind().
            hostedView.isHidden = true
            if hostedView.superview === hostView {
                hostedView.removeFromSuperview()
            }
        }
    }

    /// Hide a portal entry without detaching it. Updates visibleInUI to false and
    /// sets isHidden = true so subsequent synchronizeHostedView calls keep it hidden.
    /// Used when a workspace is permanently unmounted (vs. transient bonsplit dismantles).
    func hideEntry(forHostedId hostedId: ObjectIdentifier) {
        guard var entry = entriesByHostedId[hostedId] else { return }
        guard entry.visibleInUI else { return }
        entry.visibleInUI = false
        entry.transientRecoveryRetriesRemaining = 0
        entriesByHostedId[hostedId] = entry
        entry.hostedView?.isHidden = true
#if DEBUG
        dlog("portal.hideEntry hosted=\(portalDebugToken(entry.hostedView)) reason=workspaceUnmount")
#endif
    }

    /// Update the visibleInUI flag on an existing entry without rebinding.
    /// Used when a deferred bind is pending — this ensures synchronizeHostedView
    /// won't hide a view that updateNSView has already marked as visible.
    func updateEntryVisibility(forHostedId hostedId: ObjectIdentifier, visibleInUI: Bool) {
        guard var entry = entriesByHostedId[hostedId] else { return }
        entry.visibleInUI = visibleInUI
        if !visibleInUI {
            entry.transientRecoveryRetriesRemaining = 0
        }
        entriesByHostedId[hostedId] = entry
    }

    func isHostedViewBoundToAnchor(withId hostedId: ObjectIdentifier, anchorView: NSView) -> Bool {
        guard let entry = entriesByHostedId[hostedId],
              let boundAnchor = entry.anchorView else { return false }
        return boundAnchor === anchorView
    }

    func bind(hostedView: GhosttySurfaceScrollView, to anchorView: NSView, visibleInUI: Bool, zPriority: Int = 0) {
        guard ensureInstalled() else { return }

        let hostedId = ObjectIdentifier(hostedView)
        let anchorId = ObjectIdentifier(anchorView)
        let previousEntry = entriesByHostedId[hostedId]

        if let previousHostedId = hostedByAnchorId[anchorId], previousHostedId != hostedId {
#if DEBUG
            let previousToken = entriesByHostedId[previousHostedId]
                .map { portalDebugToken($0.hostedView) }
                ?? String(describing: previousHostedId)
            dlog(
                "portal.bind.replace anchor=\(portalDebugToken(anchorView)) " +
                "oldHosted=\(previousToken) newHosted=\(portalDebugToken(hostedView))"
            )
#endif
            detachHostedView(withId: previousHostedId)
        }

        if let oldEntry = entriesByHostedId[hostedId],
           let oldAnchor = oldEntry.anchorView,
           oldAnchor !== anchorView {
            hostedByAnchorId.removeValue(forKey: ObjectIdentifier(oldAnchor))
        }

        hostedByAnchorId[anchorId] = hostedId
        entriesByHostedId[hostedId] = Entry(
            hostedView: hostedView,
            anchorView: anchorView,
            visibleInUI: visibleInUI,
            zPriority: zPriority,
            transientRecoveryRetriesRemaining: 0
        )

        let didChangeAnchor: Bool = {
            guard let previousAnchor = previousEntry?.anchorView else { return true }
            return previousAnchor !== anchorView
        }()
        let becameVisible = (previousEntry?.visibleInUI ?? false) == false && visibleInUI
        let priorityIncreased = zPriority > (previousEntry?.zPriority ?? Int.min)
#if DEBUG
        if previousEntry == nil || didChangeAnchor || becameVisible || priorityIncreased || hostedView.superview !== hostView {
            dlog(
                "portal.bind hosted=\(portalDebugToken(hostedView)) " +
                "anchor=\(portalDebugToken(anchorView)) prevAnchor=\(portalDebugToken(previousEntry?.anchorView)) " +
                "visible=\(visibleInUI ? 1 : 0) prevVisible=\((previousEntry?.visibleInUI ?? false) ? 1 : 0) " +
                "z=\(zPriority) prevZ=\(previousEntry?.zPriority ?? Int.min)"
            )
        }
#endif

        _ = synchronizeHostFrameToReference()

        // Seed frame/bounds before entering the window so a freshly reparented
        // surface doesn't do a transient 800x600 size update on viewDidMoveToWindow.
        if let seededFrame = seededFrameInHost(for: anchorView),
           seededFrame.width > 0,
           seededFrame.height > 0 {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hostedView.frame = seededFrame
            hostedView.bounds = NSRect(origin: .zero, size: seededFrame.size)
            CATransaction.commit()
        } else {
            // If anchor geometry is still unsettled, keep this hidden/zero-sized until
            // synchronizeHostedView resolves a valid target frame on the next layout tick.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hostedView.frame = .zero
            hostedView.bounds = .zero
            CATransaction.commit()
            hostedView.isHidden = true
        }
        // Keep inner scroll/surface geometry in sync with the seeded outer frame
        // before the hosted view enters a window.
        hostedView.reconcileGeometryNow()

        if hostedView.superview !== hostView {
#if DEBUG
            dlog(
                "portal.reparent hosted=\(portalDebugToken(hostedView)) " +
                "reason=attach super=\(portalDebugToken(hostedView.superview))"
            )
#endif
            hostView.addSubview(hostedView, positioned: .above, relativeTo: nil)
        } else if (becameVisible || priorityIncreased), hostView.subviews.last !== hostedView {
            // Refresh z-order only when a view becomes visible or gets a higher priority.
            // Anchor-only churn is common during split tree updates; forcing remove/add there
            // causes transient inWindow=0 -> 1 bounces that can flash black.
#if DEBUG
            dlog(
                "portal.reparent hosted=\(portalDebugToken(hostedView)) reason=raise " +
                "didChangeAnchor=\(didChangeAnchor ? 1 : 0) becameVisible=\(becameVisible ? 1 : 0) " +
                "priorityIncreased=\(priorityIncreased ? 1 : 0)"
            )
#endif
            hostView.addSubview(hostedView, positioned: .above, relativeTo: nil)
        }

        ensureDividerOverlayOnTop()

        synchronizeHostedView(withId: hostedId)
        scheduleDeferredFullSynchronizeAll()
        pruneDeadEntries()
    }

    func synchronizeHostedViewForAnchor(_ anchorView: NSView) {
        guard ensureInstalled() else { return }
        synchronizeLayoutHierarchy()
        pruneDeadEntries()
        let anchorId = ObjectIdentifier(anchorView)
        let primaryHostedId = hostedByAnchorId[anchorId]
        if let primaryHostedId {
            synchronizeHostedView(withId: primaryHostedId)
        }

        // Failsafe: during aggressive divider drags/structural churn, one anchor can miss a
        // geometry callback while another fires. Reconcile all mapped hosted views so no stale
        // frame remains "stuck" onscreen until the next interaction.
        synchronizeAllHostedViews(excluding: primaryHostedId)
        reconcileVisibleHostedViewsAfterGeometrySync(reason: "portal.anchorGeometrySync")
        scheduleDeferredFullSynchronizeAll()
    }

    private func reconcileVisibleHostedViewsAfterGeometrySync(reason: String) {
        // During live resize, AppKit can deliver frame churn where outer portal geometry
        // settles a tick before the terminal's own scroll/surface hierarchy. Only force an
        // in-place surface refresh when reconciliation actually changed terminal geometry.
        for entry in entriesByHostedId.values {
            guard let hostedView = entry.hostedView, !hostedView.isHidden else { continue }
            if hostedView.reconcileGeometryNow() {
                hostedView.refreshSurfaceNow(reason: reason)
            }
        }
    }

    private func scheduleDeferredFullSynchronizeAll() {
        guard !hasDeferredFullSyncScheduled else { return }
        hasDeferredFullSyncScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hasDeferredFullSyncScheduled = false
            self.synchronizeAllHostedViews(excluding: nil)
        }
    }

    private func synchronizeAllHostedViews(excluding hostedIdToSkip: ObjectIdentifier?) {
        guard ensureInstalled() else { return }
        synchronizeLayoutHierarchy()
        pruneDeadEntries()
        let hostedIds = Array(entriesByHostedId.keys)
        for hostedId in hostedIds {
            if hostedId == hostedIdToSkip { continue }
            synchronizeHostedView(withId: hostedId)
        }
    }

    private func resetTransientRecoveryRetryIfNeeded(forHostedId hostedId: ObjectIdentifier, entry: inout Entry) {
        guard entry.transientRecoveryRetriesRemaining != 0 else { return }
        entry.transientRecoveryRetriesRemaining = 0
        entriesByHostedId[hostedId] = entry
    }

    private func scheduleTransientRecoveryRetryIfNeeded(
        forHostedId hostedId: ObjectIdentifier,
        entry: inout Entry,
        hostedView: GhosttySurfaceScrollView,
        reason: String
    ) -> Bool {
        guard Self.transientRecoveryEnabled else { return false }
        if entry.transientRecoveryRetriesRemaining == 0 {
            entry.transientRecoveryRetriesRemaining = Self.transientRecoveryRetryBudget
        }
        guard entry.transientRecoveryRetriesRemaining > 0 else { return false }

        entry.transientRecoveryRetriesRemaining -= 1
        entriesByHostedId[hostedId] = entry
#if DEBUG
        dlog(
            "portal.sync.deferRecover hosted=\(portalDebugToken(hostedView)) " +
            "reason=\(reason) remaining=\(entry.transientRecoveryRetriesRemaining)"
        )
#endif
        if entry.transientRecoveryRetriesRemaining > 0 {
            scheduleDeferredFullSynchronizeAll()
        }
        return true
    }

    /// Hide `hostedView` for a `synchronizeHostedView` entry that can't be positioned this
    /// pass (missing anchor/window, anchor moved to a different window, or host bounds not
    /// yet laid out), scheduling a transient-recovery retry so a genuinely-transient geometry
    /// hiccup doesn't get stuck hidden. Falls back to a full `synchronizeAllHostedViews` when
    /// transient recovery is disabled (production builds), so that path isn't left with no
    /// recovery at all.
    ///
    /// Returns `true` if the caller should return immediately because the current visible
    /// frame was preserved pending a transient-recovery retry (i.e. `hostedView.isHidden`
    /// was deliberately left unchanged this pass).
    @discardableResult
    private func hideHostedViewSchedulingRecovery(
        hostedId: ObjectIdentifier,
        entry: inout Entry,
        hostedView: GhosttySurfaceScrollView,
        reason: String
    ) -> Bool {
        if entry.visibleInUI {
            let shouldPreserveVisibleOnTransient = !hostedView.isHidden &&
                scheduleTransientRecoveryRetryIfNeeded(
                    forHostedId: hostedId,
                    entry: &entry,
                    hostedView: hostedView,
                    reason: reason
                )
            if shouldPreserveVisibleOnTransient {
#if DEBUG
                dlog(
                    "portal.hidden.deferKeep hosted=\(portalDebugToken(hostedView)) " +
                    "reason=\(reason) frame=\(portalDebugFrame(hostedView.frame))"
                )
#endif
                return true
            }
        } else {
            resetTransientRecoveryRetryIfNeeded(forHostedId: hostedId, entry: &entry)
        }
#if DEBUG
        if !hostedView.isHidden {
            dlog("portal.hidden hosted=\(portalDebugToken(hostedView)) value=1 reason=\(reason)")
        }
#endif
        hostedView.isHidden = true
        if entry.visibleInUI {
            if Self.transientRecoveryEnabled {
                _ = scheduleTransientRecoveryRetryIfNeeded(
                    forHostedId: hostedId,
                    entry: &entry,
                    hostedView: hostedView,
                    reason: reason
                )
            } else {
                scheduleDeferredFullSynchronizeAll()
            }
        }
        return false
    }

    private func synchronizeHostedView(withId hostedId: ObjectIdentifier) {
        guard ensureInstalled() else { return }
        guard var entry = entriesByHostedId[hostedId] else { return }
        guard let hostedView = entry.hostedView else {
            entriesByHostedId.removeValue(forKey: hostedId)
            return
        }
        guard let anchorView = entry.anchorView, let window else {
            _ = hideHostedViewSchedulingRecovery(
                hostedId: hostedId,
                entry: &entry,
                hostedView: hostedView,
                reason: "missingAnchorOrWindow"
            )
            return
        }
        guard anchorView.window === window else {
#if DEBUG
            if !hostedView.isHidden {
                dlog(
                    "portal.hidden hosted=\(portalDebugToken(hostedView)) value=1 " +
                    "reason=anchorWindowMismatch anchorWindow=\(portalDebugToken(anchorView.window?.contentView))"
                )
            }
#endif
            _ = hideHostedViewSchedulingRecovery(
                hostedId: hostedId,
                entry: &entry,
                hostedView: hostedView,
                reason: "anchorWindowMismatch"
            )
            return
        }

        _ = synchronizeHostFrameToReference()
        let frameInWindow = effectiveAnchorFrameInWindow(for: anchorView)
        let frameInHostRaw = hostView.convert(frameInWindow, from: nil)
        let frameInHost = Self.pixelSnappedRect(frameInHostRaw, in: hostView)
#if DEBUG
        logBonsplitContainerFrameIfNeeded(anchorView: anchorView, hostedView: hostedView)
#endif
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
                "portal.sync.defer hosted=\(portalDebugToken(hostedView)) " +
                "reason=hostBoundsNotReady host=\(portalDebugFrame(hostBounds)) " +
                "anchor=\(portalDebugFrame(frameInHost)) visibleInUI=\(entry.visibleInUI ? 1 : 0)"
            )
#endif
            _ = hideHostedViewSchedulingRecovery(
                hostedId: hostedId,
                entry: &entry,
                hostedView: hostedView,
                reason: "hostBoundsNotReady"
            )
            return
        }
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
        let targetFrame = (hasFiniteFrame && hasVisibleIntersection) ? clampedFrame : frameInHost
        let anchorHidden = Self.isHiddenOrAncestorHidden(anchorView)
        let tinyFrame =
            targetFrame.width <= Self.tinyHideThreshold ||
            targetFrame.height <= Self.tinyHideThreshold
        let revealReadyForDisplay =
            targetFrame.width >= Self.minimumRevealWidth &&
            targetFrame.height >= Self.minimumRevealHeight
        let outsideHostBounds = !hasVisibleIntersection
        let shouldHide =
            !entry.visibleInUI ||
            anchorHidden ||
            tinyFrame ||
            !hasFiniteFrame ||
            outsideHostBounds
        let shouldDeferReveal = !shouldHide && hostedView.isHidden && !revealReadyForDisplay
        let transientRecoveryReason: String? = {
            guard Self.transientRecoveryEnabled else { return nil }
            guard entry.visibleInUI else { return nil }
            if anchorHidden { return "anchorHidden" }
            if !hasFiniteFrame { return "nonFiniteFrame" }
            if outsideHostBounds { return "outsideHostBounds" }
            if tinyFrame { return "tinyFrame" }
            if shouldDeferReveal { return "deferReveal" }
            return nil
        }()
        let didScheduleTransientRecovery: Bool = {
            guard let transientRecoveryReason else { return false }
            return scheduleTransientRecoveryRetryIfNeeded(
                forHostedId: hostedId,
                entry: &entry,
                hostedView: hostedView,
                reason: transientRecoveryReason
            )
        }()
        let shouldPreserveVisibleOnTransientGeometry =
            didScheduleTransientRecovery &&
            shouldHide &&
            entry.visibleInUI &&
            !hostedView.isHidden

        let oldFrame = hostedView.frame
#if DEBUG
        let frameWasClamped = hasFiniteFrame && !Self.rectApproximatelyEqual(frameInHost, targetFrame)
        if frameWasClamped {
            dlog(
                "portal.frame.clamp hosted=\(portalDebugToken(hostedView)) " +
                "anchor=\(portalDebugToken(anchorView)) " +
                "raw=\(portalDebugFrame(frameInHost)) clamped=\(portalDebugFrame(targetFrame)) " +
                "host=\(portalDebugFrame(hostBounds))"
            )
        }
        let collapsedToTiny = oldFrame.width > 1 && oldFrame.height > 1 && tinyFrame
        let restoredFromTiny = (oldFrame.width <= 1 || oldFrame.height <= 1) && !tinyFrame
        if collapsedToTiny {
            dlog(
                "portal.frame.collapse hosted=\(portalDebugToken(hostedView)) anchor=\(portalDebugToken(anchorView)) " +
                "old=\(portalDebugFrame(oldFrame)) new=\(portalDebugFrame(targetFrame))"
            )
        } else if restoredFromTiny {
            dlog(
                "portal.frame.restore hosted=\(portalDebugToken(hostedView)) anchor=\(portalDebugToken(anchorView)) " +
                "old=\(portalDebugFrame(oldFrame)) new=\(portalDebugFrame(targetFrame))"
            )
        }
#endif

        // Hide before updating the frame when this entry should not be visible.
        // This avoids a one-frame flash of unrendered terminal background when a portal
        // briefly transitions through offscreen/tiny geometry during rapid split churn.
        if shouldHide, !hostedView.isHidden, !shouldPreserveVisibleOnTransientGeometry {
#if DEBUG
            dlog(
                "portal.hidden hosted=\(portalDebugToken(hostedView)) value=1 " +
                "visibleInUI=\(entry.visibleInUI ? 1 : 0) anchorHidden=\(anchorHidden ? 1 : 0) " +
                "tiny=\(tinyFrame ? 1 : 0) revealReady=\(revealReadyForDisplay ? 1 : 0) finite=\(hasFiniteFrame ? 1 : 0) " +
                "outside=\(outsideHostBounds ? 1 : 0) frame=\(portalDebugFrame(targetFrame)) " +
                "host=\(portalDebugFrame(hostBounds))"
            )
#endif
            hostedView.isHidden = true
        }
        if shouldPreserveVisibleOnTransientGeometry {
#if DEBUG
            dlog(
                "portal.hidden.deferKeep hosted=\(portalDebugToken(hostedView)) " +
                "reason=\(transientRecoveryReason ?? "unknown") frame=\(portalDebugFrame(hostedView.frame))"
            )
#endif
        }

        if hasFiniteFrame {
            let expectedBounds = NSRect(origin: .zero, size: targetFrame.size)
            var geometryChanged = false
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if !Self.rectApproximatelyEqual(oldFrame, targetFrame) {
                hostedView.frame = targetFrame
                geometryChanged = true
            }
            if !Self.rectApproximatelyEqual(hostedView.bounds, expectedBounds) {
                hostedView.bounds = expectedBounds
                geometryChanged = true
            }
            CATransaction.commit()
            if geometryChanged {
                hostedView.reconcileGeometryNow()
                hostedView.refreshSurfaceNow(reason: "portal.frameChange")
            }
        }

        if shouldDeferReveal {
#if DEBUG
            if !Self.rectApproximatelyEqual(oldFrame, frameInHost) {
                dlog(
                    "portal.hidden.deferReveal hosted=\(portalDebugToken(hostedView)) " +
                    "frame=\(portalDebugFrame(frameInHost)) min=\(Int(Self.minimumRevealWidth))x\(Int(Self.minimumRevealHeight))"
                )
            }
#endif
        }

        if !shouldHide, hostedView.isHidden, revealReadyForDisplay {
#if DEBUG
            dlog(
                "portal.hidden hosted=\(portalDebugToken(hostedView)) value=0 " +
                "visibleInUI=\(entry.visibleInUI ? 1 : 0) anchorHidden=\(anchorHidden ? 1 : 0) " +
                "tiny=\(tinyFrame ? 1 : 0) revealReady=\(revealReadyForDisplay ? 1 : 0) finite=\(hasFiniteFrame ? 1 : 0) " +
                "outside=\(outsideHostBounds ? 1 : 0) frame=\(portalDebugFrame(targetFrame)) " +
                "host=\(portalDebugFrame(hostBounds))"
            )
#endif
            hostedView.isHidden = false
            // A reveal can happen without any frame delta (same targetFrame), which means the
            // normal frame-change refresh path won't run. Nudge geometry + redraw so newly
            // revealed terminals don't sit on a stale/blank IOSurface until later focus churn.
            hostedView.reconcileGeometryNow()
            hostedView.refreshSurfaceNow(reason: "portal.reveal")
            // Schedule a deferred refresh so terminals with active output (e.g. progress
            // bars) get an explicit ghostty_surface_refresh after the portal reveal settles.
            // The immediate refreshSurfaceNow can exit early if the view isn't fully in the
            // window hierarchy yet, leaving the IOSurface frozen on a stale frame (#2628).
            DispatchQueue.main.async { [weak hostedView] in
                hostedView?.refreshSurfaceNow(reason: "portal.reveal.deferred")
            }
        }

        if transientRecoveryReason == nil {
            resetTransientRecoveryRetryIfNeeded(forHostedId: hostedId, entry: &entry)
        }

#if DEBUG
        dlog(
            "portal.sync.result hosted=\(portalDebugToken(hostedView)) " +
            "anchor=\(portalDebugToken(anchorView)) host=\(portalDebugToken(hostView)) " +
            "hostWin=\(hostView.window?.windowNumber ?? -1) " +
            "old=\(portalDebugFrame(oldFrame)) raw=\(portalDebugFrame(frameInHost)) " +
            "target=\(portalDebugFrame(targetFrame)) hide=\(shouldHide ? 1 : 0) " +
            "entryVisible=\(entry.visibleInUI ? 1 : 0) hostedHidden=\(hostedView.isHidden ? 1 : 0) " +
            "hostBounds=\(portalDebugFrame(hostBounds))"
        )
#endif

        ensureDividerOverlayOnTop()
    }

    private func pruneDeadEntries() {
        let currentWindow = window
        let deadHostedIds = entriesByHostedId.compactMap { hostedId, entry -> ObjectIdentifier? in
            guard entry.hostedView != nil else { return hostedId }
            guard let anchor = entry.anchorView else {
                // The anchor has been fully deallocated (weak ref auto-nil'd), unlike a
                // transient anchor that's merely off-tree (still alive, superview nil) and
                // can be recovered on the next bind/sync. There is nothing left to
                // reconcile against here, so always prune regardless of visibleInUI.
                return hostedId
            }

            let anchorInvalidForCurrentHost =
                anchor.window !== currentWindow ||
                anchor.superview == nil ||
                (installedReferenceView.map { !anchor.isDescendant(of: $0) } ?? false)
            if anchorInvalidForCurrentHost {
                // During aggressive tab drag/reorder churn, SwiftUI/AppKit can briefly
                // detach/rehome anchor hosts while the terminal should stay visible.
                // Avoid pruning those visible entries so sync/bind recovery can reattach.
                return entry.visibleInUI ? nil : hostedId
            }
            return nil
        }

        for hostedId in deadHostedIds {
            detachHostedView(withId: hostedId)
        }

        let validAnchorIds = Set(entriesByHostedId.compactMap { _, entry in
            entry.anchorView.map { ObjectIdentifier($0) }
        })
        hostedByAnchorId = hostedByAnchorId.filter { validAnchorIds.contains($0.key) }
    }

    func hostedIds() -> Set<ObjectIdentifier> {
        Set(entriesByHostedId.keys)
    }

    func tearDown() {
        removeGeometryObservers()
        for hostedId in Array(entriesByHostedId.keys) {
            detachHostedView(withId: hostedId)
        }
        NSLayoutConstraint.deactivate(installConstraints)
        installConstraints.removeAll()
        hostView.removeFromSuperview()
        installedContainerView = nil
        installedReferenceView = nil
    }

#if DEBUG
    struct DebugStats {
        let windowNumber: Int
        let entryCount: Int
        let hostSubviewCount: Int
        let terminalSubviewCount: Int
        let mappedTerminalSubviewCount: Int
        let orphanTerminalSubviewCount: Int
        let visibleOrphanTerminalSubviewCount: Int
        let staleEntryCount: Int
    }

    func debugStats() -> DebugStats {
        let terminalSubviews = hostView.subviews.compactMap { $0 as? GhosttySurfaceScrollView }
        var mappedTerminalSubviewCount = 0
        var orphanTerminalSubviewCount = 0
        var visibleOrphanTerminalSubviewCount = 0

        for hostedView in terminalSubviews {
            let hostedId = ObjectIdentifier(hostedView)
            if entriesByHostedId[hostedId] != nil {
                mappedTerminalSubviewCount += 1
            } else {
                orphanTerminalSubviewCount += 1
                if hostedView.window != nil,
                   !hostedView.isHidden,
                   hostedView.frame.width > Self.tinyHideThreshold,
                   hostedView.frame.height > Self.tinyHideThreshold {
                    visibleOrphanTerminalSubviewCount += 1
                }
            }
        }

        let staleEntryCount = entriesByHostedId.values.reduce(0) { partialResult, entry in
            guard let hostedView = entry.hostedView else { return partialResult + 1 }
            return hostedView.superview === hostView ? partialResult : partialResult + 1
        }

        return DebugStats(
            windowNumber: window?.windowNumber ?? -1,
            entryCount: entriesByHostedId.count,
            hostSubviewCount: hostView.subviews.count,
            terminalSubviewCount: terminalSubviews.count,
            mappedTerminalSubviewCount: mappedTerminalSubviewCount,
            orphanTerminalSubviewCount: orphanTerminalSubviewCount,
            visibleOrphanTerminalSubviewCount: visibleOrphanTerminalSubviewCount,
            staleEntryCount: staleEntryCount
        )
    }

    func debugEntryCount() -> Int {
        entriesByHostedId.count
    }

    // Base-class debugHostedSubviewCount() counts raw hostView.subviews, which for
    // Terminal also includes the permanently-attached dividerOverlayView (not a
    // hosted terminal view). Override so debug tooling reports only actual hosted
    // terminal subviews, matching the Browser portal (which has no such overlay).
    override func debugHostedSubviewCount() -> Int {
        hostView.subviews.filter { $0 is GhosttySurfaceScrollView }.count
    }
#endif

    func viewAtWindowPoint(_ windowPoint: NSPoint) -> NSView? {
        guard ensureInstalled() else { return nil }
        let point = hostView.convert(windowPoint, from: nil)

        // Restrict hit-testing to currently mapped entries so stale detached views
        // can't steal file-drop/mouse routing.
        for subview in hostView.subviews.reversed() {
            guard let hostedView = subview as? GhosttySurfaceScrollView else { continue }
            let hostedId = ObjectIdentifier(hostedView)
            guard entriesByHostedId[hostedId] != nil else { continue }
            guard !hostedView.isHidden else { continue }
            guard hostedView.frame.contains(point) else { continue }
            let localPoint = hostedView.convert(point, from: hostView)
            return hostedView.hitTest(localPoint) ?? hostedView
        }

        return nil
    }

    func terminalViewAtWindowPoint(_ windowPoint: NSPoint) -> GhosttyNSView? {
        guard ensureInstalled() else { return nil }
        let point = hostView.convert(windowPoint, from: nil)

        for subview in hostView.subviews.reversed() {
            guard let hostedView = subview as? GhosttySurfaceScrollView else { continue }
            let hostedId = ObjectIdentifier(hostedView)
            guard entriesByHostedId[hostedId] != nil else { continue }
            guard !hostedView.isHidden else { continue }
            guard hostedView.frame.contains(point) else { continue }
            let localPoint = hostedView.convert(point, from: hostView)
            if let terminal = hostedView.terminalViewForDrop(at: localPoint) {
                return terminal
            }
        }

        return nil
    }
}
