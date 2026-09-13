import AppKit
import Bonsplit
import ObjectiveC

extension Notification.Name {
    /// Posted by the terminal portal (object: NSWindow) after it repositions a
    /// hosted SwiftUI container — the chrome anchors inside move without their
    /// own frames changing.
    static let programaTerminalPortalDidMoveHostedContent =
        Notification.Name("programaTerminalPortalDidMoveHostedContent")
}

#if compiler(>=6.2)
@MainActor
@available(macOS 26.0, *)
final class WindowPaneChromePortalRegistry: NSObject, BonsplitPaneChromePortalBridge {
    private static var associationKey: UInt8 = 0

    static func bridge(for window: NSWindow) -> WindowPaneChromePortalRegistry {
        if let existing = objc_getAssociatedObject(window, &associationKey) as? WindowPaneChromePortalRegistry {
            existing.ensureInstalled()
            return existing
        }
        let bridge = WindowPaneChromePortalRegistry(window: window)
        objc_setAssociatedObject(window, &associationKey, bridge, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return bridge
    }

    let supportsNativePaneChrome = true

    private weak var window: NSWindow?
    private let hostView = PaneChromePortalHostView(frame: .zero)
    private var bars: [PaneID: NativePaneTabBarView] = [:]
    private var descriptors: [PaneID: BonsplitPaneChromeDescriptor] = [:]
    private var observers: [NSObjectProtocol] = []
    private var anchorObservers: [PaneID: (anchor: NSView, tokens: [NSObjectProtocol])] = [:]
    private weak var cachedTerminalHost: WindowTerminalHostView?
    private var isTornDown = false
    /// Workspace-level split controls, pinned to the terminal area's top-right like
    /// Maps' map controls; they act on the focused pane rather than per-pane copies.
    private let splitCluster = GlassIconClusterView(symbols: [
        (name: "square.split.2x1", tooltip: String(localized: "tabBar.splitRight", defaultValue: "Split Right")),
        (name: "square.split.1x2", tooltip: String(localized: "tabBar.splitDown", defaultValue: "Split Down")),
    ])
    private let newTabCluster = GlassIconClusterView(symbols: [
        (name: "terminal", tooltip: String(localized: "tabBar.newTerminalTab", defaultValue: "New Terminal Tab")),
        (name: "globe", tooltip: String(localized: "tabBar.newBrowserTab", defaultValue: "New Browser Tab")),
    ])

    private init(window: NSWindow) {
        self.window = window
        super.init()
        hostView.translatesAutoresizingMaskIntoConstraints = false
        hostView.wantsLayer = true
        hostView.layer?.backgroundColor = NSColor.clear.cgColor
        hostView.addSubview(splitCluster)
        hostView.addSubview(newTabCluster)
        splitCluster.isHidden = true
        newTabCluster.isHidden = true
        applyTerminalAppearance()
        installObservers(window)
        ensureInstalled()
    }

    /// Pills float over terminal content, so their glass and labels must resolve
    /// contrast against the terminal background, not the window appearance —
    /// otherwise a light-mode window draws near-black labels on a dark terminal.
    private func applyTerminalAppearance() {
        let name: NSAppearance.Name =
            SidebarTerminalAppearance.colorScheme() == .dark ? .darkAqua : .aqua
        if hostView.appearance?.name != name {
            hostView.appearance = NSAppearance(named: name)
        }
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        for entry in anchorObservers.values {
            for token in entry.tokens { NotificationCenter.default.removeObserver(token) }
        }
    }

    func updatePaneChrome(_ descriptor: BonsplitPaneChromeDescriptor) {
        descriptors[descriptor.paneID] = descriptor
        if let anchor = descriptor.anchorView {
            observeAnchor(anchor, paneID: descriptor.paneID)
        }
        ensureInstalled()
#if DEBUG
        dlog(
            "paneChrome.update pane=\(descriptor.paneID.id.uuidString.prefix(5)) " +
            "tabs=\(descriptor.tabs.count) visible=\(descriptor.isVisible ? 1 : 0) " +
            "anchorWin=\(descriptor.anchorView?.window != nil ? 1 : 0) " +
            "hostSuper=\(hostView.superview != nil ? 1 : 0)"
        )
#endif
        let bar = bars[descriptor.paneID] ?? {
            let newBar = NativePaneTabBarView(frame: .zero)
            bars[descriptor.paneID] = newBar
            hostView.addSubview(newBar)
            return newBar
        }()
        bar.update(descriptor)
        synchronize(descriptor.paneID)
        updateClusters()
        scheduleSettledSynchronize()
    }

    /// Workspace-level controls follow the focused visible pane, sharing its tab
    /// strip: pills on the left, both capsules side by side on the right, all
    /// centered on the strip's midline. The pane's tab bar reserves trailing
    /// space so pills never run under the controls.
    private func updateClusters() {
        // Anchors can move to another window (workspace drag-out); their stale
        // descriptors must not steer this window's controls.
        let inWindow = descriptors.values.filter { $0.anchorView?.window === window }
        let visible = inWindow.filter(\.isVisible)
        guard let active = visible.first(where: { $0.isFocused }) ?? visible.first,
              let anchor = active.anchorView else {
            newTabCluster.isHidden = true
            splitCluster.isHidden = true
            for bar in bars.values { bar.trailingReservedWidth = 0 }
            return
        }
        let barHeight: CGFloat = 28
        // Chrome spacing grid: 4pt base, edges on 8.
        let gap: CGFloat = 8
        let strip = hostView.convert(anchor.bounds, from: anchor)
        let y = strip.midY - barHeight / 2

        newTabCluster.setActions([active.onNewTab, active.onNewBrowserTab])
        newTabCluster.isHidden = false
        ensureAboveBars(newTabCluster)
        let newTabX = strip.maxX - gap - newTabCluster.preferredWidth
        newTabCluster.frame = NSRect(
            x: newTabX,
            y: y,
            width: newTabCluster.preferredWidth,
            height: barHeight
        )
        var reserved = gap + newTabCluster.preferredWidth

        // Cap workspace splits at a 2x2-equivalent depth; deeper trees degenerate
        // into slivers. Checked here (live pane count) rather than at publish time,
        // where it goes stale when panes collapse without a republish. At the cap
        // the capsule stays visible but disabled so the affordance doesn't vanish.
        // Counts registered panes, not visible ones: zoomed-away panes still
        // exist, and the Workspace delegate vetoes splits on the same predicate.
        if active.showsSplitButtons {
            let canSplit = inWindow.count < SplitPolicy.maxPanesPerWorkspace
            splitCluster.setActions([active.onSplitRight, active.onSplitDown])
            splitCluster.setEnabled(
                canSplit,
                disabledTooltip: String(
                    localized: "tabBar.splitLimitReached",
                    defaultValue: "Split limit reached"
                )
            )
            splitCluster.isHidden = false
            ensureAboveBars(splitCluster)
            splitCluster.frame = NSRect(
                x: newTabX - gap - splitCluster.preferredWidth,
                y: y,
                width: splitCluster.preferredWidth,
                height: barHeight
            )
            reserved += gap + splitCluster.preferredWidth
        } else {
            splitCluster.isHidden = true
        }

        for (paneID, bar) in bars {
            bar.trailingReservedWidth = paneID == active.paneID ? reserved : 0
        }
    }

    /// Re-adding an already-parented subview removes and re-inserts it, which
    /// dirties layout — and updateClusters runs on every coalesced geometry
    /// pass during animation storms. Reorder only when a pane bar (added on
    /// top by updatePaneChrome) actually sits above the cluster.
    private func ensureAboveBars(_ cluster: NSView) {
        guard cluster.superview === hostView else {
            hostView.addSubview(cluster)
            return
        }
        let subviews = hostView.subviews
        guard let clusterIndex = subviews.firstIndex(of: cluster) else { return }
        let topBarIndex = subviews.enumerated()
            .filter { $0.element is NativePaneTabBarView }
            .map(\.offset)
            .max()
        if let topBarIndex, clusterIndex < topBarIndex {
            hostView.addSubview(cluster)
        }
    }

    func removePaneChrome(for paneID: PaneID, anchorView: NSView) {
        let matches = descriptors[paneID]?.anchorView === anchorView
#if DEBUG
        dlog(
            "paneChrome.remove pane=\(paneID.id.uuidString.prefix(5)) " +
            "matches=\(matches ? 1 : 0) remaining=\(descriptors.count)"
        )
#endif
        guard matches else { return }
        descriptors.removeValue(forKey: paneID)
        bars.removeValue(forKey: paneID)?.removeFromSuperview()
        if let entry = anchorObservers.removeValue(forKey: paneID) {
            for token in entry.tokens { NotificationCenter.default.removeObserver(token) }
        }
        updateClusters()
        // Split-tree churn can register two anchor instances for one pane; the
        // dying instance publishes last and its dismantle lands here, deleting the
        // survivor's registration. Ask live anchors to reassert on the next turn —
        // scoped to this window so workspace churn (a storm of pane closes) does
        // not trigger app-wide republish storms.
        // Capture the window itself: posting with a nil object would be an
        // app-wide broadcast (the storm this scoping exists to prevent), and a
        // window that died before the post has no anchors left to reassert.
        DispatchQueue.main.async { [weak window = self.window] in
            guard let window else { return }
            NotificationCenter.default.post(
                name: BonsplitPaneChromeAnchorNotifications.reassertRequest,
                object: window
            )
        }
    }

    private func installObservers(_ window: NSWindow) {
        let center = NotificationCenter.default
        for name in [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                // Live resize fires per frame; coalesce to one pass per runloop turn.
                MainActor.assumeIsolated { self?.scheduleSynchronizeAll() }
            })
        }
        observers.append(center.addObserver(
            forName: NSSplitView.didResizeSubviewsNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, (note.object as? NSSplitView)?.window === self.window else { return }
                // Interactive divider drags fire per tick; coalesce like resize.
                self.scheduleSynchronizeAll()
            }
        })
        // Split collapses and divider animation move the anchor via its
        // ancestors — the anchor's own frame never changes, so resync whenever
        // an ancestor of any anchor resizes (coalesced). Ancestors are arbitrary
        // views, so this pair stays app-global with a cheap window gate; the
        // anchors' own geometry is tracked per-object in observeAnchor(_:paneID:).
        for name in [NSView.frameDidChangeNotification, NSView.boundsDidChangeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, let view = note.object as? NSView, view.window === self.window else { return }
                    let ancestorOfAnchor = self.descriptors.values.contains {
                        guard let anchor = $0.anchorView, anchor !== view else { return false }
                        return anchor.isDescendant(of: view)
                    }
                    if ancestorOfAnchor { self.scheduleSynchronizeAll() }
                }
            })
        }
        observers.append(center.addObserver(
            forName: .programaTerminalPortalDidMoveHostedContent,
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, (note.object as? NSWindow) === self.window else { return }
                self.scheduleSynchronizeAll()
            }
        })
        observers.append(center.addObserver(
            forName: .ghosttyDefaultBackgroundDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyTerminalAppearance() }
        })
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.teardown() }
        })
    }

    /// Tracks a single anchor's own frame/bounds/window-join notifications,
    /// object-scoped so app-wide view churn never reaches these handlers.
    private func observeAnchor(_ anchor: NSView, paneID: PaneID) {
        if let existing = anchorObservers[paneID] {
            if existing.anchor === anchor { return }
            for token in existing.tokens { NotificationCenter.default.removeObserver(token) }
        }
        let center = NotificationCenter.default
        var tokens: [NSObjectProtocol] = []
        for name in [
            NSView.frameDidChangeNotification,
            NSView.boundsDidChangeNotification,
            BonsplitPaneChromeAnchorNotifications.anchorDidMoveToWindow,
        ] {
            tokens.append(center.addObserver(forName: name, object: anchor, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // The anchor can join the window before the terminal host exists
                    // in the hierarchy; re-check installation before syncing.
                    self.ensureInstalled()
                    self.synchronize(paneID)
                }
            })
        }
        anchorObservers[paneID] = (anchor, tokens)
    }

    private func ensureInstalled() {
        guard !isTornDown, supportsNativePaneChrome, let window else { return }
        // Called from every descriptor update and geometry pass; a full-window
        // recursive search each time is the dominant cost, so cache the host and
        // re-find only when it leaves the window.
        // The terminal portal installs its host in the theme frame (the
        // contentView's superview), so the search must start there.
        let searchRoot = window.contentView?.superview ?? window.contentView
        let terminalHost: WindowTerminalHostView
        if let cached = cachedTerminalHost, cached.window === window {
            terminalHost = cached
        } else if let found = findTerminalHost(in: searchRoot) {
            cachedTerminalHost = found
            terminalHost = found
        } else {
#if DEBUG
            dlog("paneChrome.install.noTerminalHost win=\(window.windowNumber)")
#endif
            return
        }
        guard let container = terminalHost.superview else {
#if DEBUG
            dlog("paneChrome.install.noContainer win=\(window.windowNumber)")
#endif
            return
        }
#if DEBUG
        dlog(
            "paneChrome.install win=\(window.windowNumber) " +
            "termHost=\(ObjectIdentifier(terminalHost)) hidden=\(terminalHost.isHiddenOrHasHiddenAncestor ? 1 : 0) " +
            "termFrame=\(Int(terminalHost.frame.width))x\(Int(terminalHost.frame.height)) " +
            "already=\(hostView.superview === container ? 1 : 0)"
        )
#endif
        if hostView.superview !== container {
            hostView.removeFromSuperview()
            container.addSubview(hostView, positioned: .above, relativeTo: terminalHost)
            NSLayoutConstraint.activate([
                hostView.leadingAnchor.constraint(equalTo: terminalHost.leadingAnchor),
                hostView.trailingAnchor.constraint(equalTo: terminalHost.trailingAnchor),
                hostView.topAnchor.constraint(equalTo: terminalHost.topAnchor),
                hostView.bottomAnchor.constraint(equalTo: terminalHost.bottomAnchor),
            ])
            // A fresh install means earlier synchronize calls ran without a host
            // and hid their bars; bring them back now that geometry can resolve.
            container.layoutSubtreeIfNeeded()
            for paneID in descriptors.keys { synchronize(paneID) }
        } else if let portalIndex = container.subviews.firstIndex(of: hostView) {
            // Pane chrome must float above every content portal in this container —
            // the browser portal installs `.above` the terminal host too, so ordering
            // against the terminal host alone can leave pills under browser content.
            let topContentIndex = container.subviews.enumerated()
                .filter { $0.element is WindowTerminalHostView || $0.element is WindowBrowserHostView }
                .map(\.offset)
                .max()
            if let topContentIndex, portalIndex < topContentIndex {
                container.addSubview(hostView, positioned: .above, relativeTo: container.subviews[topContentIndex])
            }
        }
    }

    private func findTerminalHost(in root: NSView?) -> WindowTerminalHostView? {
        guard let root else { return nil }
        if let host = root as? WindowTerminalHostView { return host }
        for child in root.subviews {
            if let host = findTerminalHost(in: child) { return host }
        }
        return nil
    }

    private var syncAllScheduled = false
    private var settledSyncScheduled = false

    /// One extra geometry pass after churn settles: split/collapse animations keep
    /// moving anchors briefly after the last descriptor update or notification.
    private func scheduleSettledSynchronize() {
        guard !settledSyncScheduled else { return }
        settledSyncScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            self.settledSyncScheduled = false
#if DEBUG
            dlog("paneChrome.settledSync descriptors=\(self.descriptors.count)")
#endif
            self.synchronizeAll()
        }
    }

    /// Coalesces ancestor-resize storms (divider drags, collapse animations) into
    /// one geometry pass per runloop turn.
    private func scheduleSynchronizeAll() {
        // Live resize: a one-turn lag reads as chrome smearing behind the
        // window edge — sync immediately (same trade the terminal portal makes).
        if window?.inLiveResize == true {
            synchronizeAll()
            return
        }
        guard !syncAllScheduled else { return }
        syncAllScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.syncAllScheduled = false
            self.synchronizeAll()
        }
    }

    private func synchronizeAll() {
        guard !isTornDown else { return }
        ensureInstalled()
        for paneID in descriptors.keys { synchronize(paneID) }
        updateClusters()
    }

    private func synchronize(_ paneID: PaneID) {
        guard let descriptor = descriptors[paneID],
              let anchor = descriptor.anchorView,
              anchor.window === window,
              let bar = bars[paneID],
              !anchor.isHidden,
              descriptor.isVisible else {
#if DEBUG
            let descriptor = descriptors[paneID]
            let anchor = descriptor?.anchorView
            dlog(
                "paneChrome.sync.hide pane=\(paneID.id.uuidString.prefix(5)) " +
                "hasDesc=\(descriptor != nil ? 1 : 0) hasAnchor=\(anchor != nil ? 1 : 0) " +
                "anchorWinMatch=\(anchor?.window === window ? 1 : 0) " +
                "hasBar=\(bars[paneID] != nil ? 1 : 0) " +
                "anchorHidden=\(anchor?.isHidden == true ? 1 : 0) " +
                "descVisible=\(descriptor?.isVisible == true ? 1 : 0)"
            )
#endif
            bars[paneID]?.isHidden = true
            return
        }
        let windowRect = anchor.convert(anchor.bounds, to: nil)
        guard windowRect.width > 1, windowRect.height > 1 else {
#if DEBUG
            dlog("paneChrome.sync.zeroRect pane=\(paneID.id.uuidString.prefix(5)) rect=\(windowRect)")
#endif
            bar.isHidden = true
            return
        }
        bar.frame = hostView.convert(windowRect, from: nil)
        bar.isHidden = false
#if DEBUG
        dlog(
            "paneChrome.sync.show pane=\(paneID.id.uuidString.prefix(5)) " +
            "barFrame=\(bar.frame) hostFrame=\(hostView.frame) " +
            "hostHidden=\(hostView.isHiddenOrHasHiddenAncestor ? 1 : 0)"
        )
#endif
    }

    private func teardown() {
        isTornDown = true
        descriptors.removeAll()
        for entry in anchorObservers.values {
            for token in entry.tokens { NotificationCenter.default.removeObserver(token) }
        }
        anchorObservers.removeAll()
        cachedTerminalHost = nil
        bars.values.forEach { $0.removeFromSuperview() }
        bars.removeAll()
        splitCluster.isHidden = true
        newTabCluster.isHidden = true
        hostView.removeFromSuperview()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }

    func nativeGlassViewsForTesting() -> [NSGlassEffectView] {
        func descendants(_ root: NSView) -> [NSView] {
            root.subviews.flatMap { [$0] + descendants($0) }
        }
        return descendants(hostView).compactMap { $0 as? NSGlassEffectView }
    }

    var hostViewForTesting: NSView { hostView }
}

private final class PaneChromePortalHostView: NSView {
    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        // `point` arrives in the superview's coordinate space; NSView.hitTest on a
        // child also expects the child's superview (self) space. Convert once here,
        // never per-child, or every hit lands offset by the child's origin.
        let local = convert(point, from: superview)
        for child in subviews.reversed() where !child.isHidden && child.frame.contains(local) {
            if let hit = child.hitTest(local) { return hit }
        }
        return nil
    }
}

@MainActor
@available(macOS 26.0, *)
class PaneChromeDragBackgroundView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        guard let window, !isWindowDragSuppressed(window: window) else { return }
        if event.clickCount >= 2 {
            performStandardTitlebarDoubleClick(window: window)
        } else {
            withTemporaryWindowMovableEnabled(window: window) {
                window.performDrag(with: event)
            }
        }
    }
}

@MainActor
@available(macOS 26.0, *)
private final class NativePaneTabBarView: PaneChromeDragBackgroundView {
    private let scrollView = NSScrollView(frame: .zero)
    // Unflipped on purpose: a flipped document view mirrors the glass pills'
    // built-in shadow upward (layer geometry flip flips shadowOffset), while
    // the control capsules in the unflipped host cast theirs downward. Layout
    // doesn't care — every child spans the full row height at y = 0.
    private let documentView = PaneChromeDragBackgroundView(frame: .zero)
    private var pillViews: [TabID: NativeGlassTabPillView] = [:]
    private var descriptor: BonsplitPaneChromeDescriptor?
    /// Safari-style "+" after the last pill; scrolls with the tabs. Bare glyph,
    /// no capsule — it's an affordance, not a peer of the tab pills.
    private let newTabButton: NSButton = {
        let title = String(localized: "tabBar.newTab", defaultValue: "New Tab")
        let button = NSButton(frame: .zero)
        button.image = NSImage(systemSymbolName: "plus", accessibilityDescription: title)
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = title
        button.setAccessibilityLabel(title)
        return button
    }()
    private var newTabAction: (() -> Void)?

    /// Space kept clear at the trailing edge for the workspace control capsules
    /// that share this strip.
    var trailingReservedWidth: CGFloat = 0 {
        didSet { if oldValue != trailingReservedWidth { needsLayout = true } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        scrollView.drawsBackground = false
        // The portal lives in a full-size-content window; the automatic titlebar
        // content inset would scroll the 28pt row completely out of the clip band.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.horizontalScrollElasticity = .automatic
        scrollView.verticalScrollElasticity = .none
        scrollView.documentView = documentView
        addSubview(scrollView)
        newTabButton.target = self
        newTabButton.action = #selector(newTabPressed)
        documentView.addSubview(newTabButton)
    }

    @objc private func newTabPressed() { newTabAction?() }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        var scrollFrame = bounds.insetBy(dx: 8, dy: 8)
        scrollFrame.size.width = max(0, scrollFrame.width - trailingReservedWidth)
        scrollView.frame = scrollFrame
        layoutPills()
        // Early zero-sized layout passes can leave the clip view scrolled to a
        // negative vertical origin, which parks the whole tab row outside the
        // visible band. The row never scrolls vertically, so pin y to 0.
        let clipOrigin = scrollView.contentView.bounds.origin
        if clipOrigin.y != 0 {
            scrollView.contentView.setBoundsOrigin(NSPoint(x: clipOrigin.x, y: 0))
        }
    }

    func update(_ descriptor: BonsplitPaneChromeDescriptor) {
        self.descriptor = descriptor
        let valid = Set(descriptor.tabs.map(\.id))
        let staleIDs = pillViews.keys.filter { !valid.contains($0) }
        for id in staleIDs {
            pillViews.removeValue(forKey: id)?.removeFromSuperview()
        }
        for tab in descriptor.tabs {
            let pill = pillViews[tab.id] ?? {
                let view = NativeGlassTabPillView(frame: .zero)
                pillViews[tab.id] = view
                documentView.addSubview(view)
                return view
            }()
            pill.update(
                tab,
                select: { [weak descriptor] in descriptor?.onSelect(tab.id) },
                close: { [weak descriptor] in descriptor?.onClose(tab.id) },
                context: { [weak descriptor] action in descriptor?.onContextAction(tab.id, action) },
                dragData: { [weak descriptor] in descriptor?.dragPasteboardData(tab.id) },
                dragState: { [weak descriptor] active in descriptor?.onDragStateChanged(tab.id, active) }
            )
        }
        newTabAction = descriptor.onNewTab
        // Title changes arrive outside AppKit's layout cadence; needsLayout
        // reruns layoutPills() in the next pass (widths track intrinsic size).
        needsLayout = true
    }

    private func layoutPills() {
        guard let descriptor else { return }
        let gap: CGFloat = 8
        let minPillWidth: CGFloat = 78
        let leadingInset = max(0, descriptor.leadingInset)
        let height = max(28, scrollView.contentSize.height)
        let pills = descriptor.tabs.compactMap { pillViews[$0.id] }
        let plusWidth: CGFloat = 28

        // Natural width per pill; only compress (which is what introduces
        // truncation) once the row genuinely runs out of space. The "+" always
        // keeps its seat at the end of the row.
        var widths = pills.map { min(220, max(minPillWidth, $0.preferredWidth)) }
        let available = scrollView.contentSize.width - leadingInset - (gap + plusWidth)
        let naturalTotal = widths.reduce(0, +) + gap * CGFloat(max(0, widths.count - 1))
        if naturalTotal > available, !widths.isEmpty {
            let evenWidth = (available - gap * CGFloat(widths.count - 1)) / CGFloat(widths.count)
            let compressed = max(minPillWidth, evenWidth.rounded(.down))
            widths = widths.map { min($0, max(compressed, minPillWidth)) }
        }

        var x = leadingInset
        for (pill, width) in zip(pills, widths) {
            pill.frame = NSRect(x: x, y: 0, width: width, height: height)
            pill.layoutSubtreeIfNeeded()
            x += width + gap
        }
        newTabButton.frame = NSRect(x: x, y: 0, width: plusWidth, height: height)
        x += plusWidth + gap
        documentView.frame = NSRect(x: 0, y: 0, width: max(x, scrollView.contentSize.width), height: height)
    }
}

/// A Maps-style always-visible control capsule: one glass surface holding a row
/// of icon buttons (Maps groups map-mode + navigation in one pill the same way).
@MainActor
@available(macOS 26.0, *)
private final class GlassIconClusterView: NSView {
    private let glass = NSGlassEffectView(frame: .zero)
    private let container = NSView(frame: .zero)
    private var buttons: [NSButton] = []
    private var actions: [() -> Void] = []
    private var defaultTooltips: [String] = []

    static let buttonWidth: CGFloat = 34

    init(symbols: [(name: String, tooltip: String)]) {
        super.init(frame: .zero)
        #if compiler(>=6.2)
        glass.style = .regular
        glass.cornerRadius = WindowGlassEffect.controlCornerRadius
        glass.contentView = container
        #endif
        addSubview(glass)
        for (index, symbol) in symbols.enumerated() {
            let button = NSButton(frame: .zero)
            button.image = NSImage(systemSymbolName: symbol.name, accessibilityDescription: symbol.tooltip)
            button.isBordered = false
            button.contentTintColor = .secondaryLabelColor
            button.toolTip = symbol.tooltip
            button.target = self
            button.action = #selector(buttonPressed(_:))
            button.tag = index
            button.setAccessibilityLabel(symbol.tooltip)
            container.addSubview(button)
            buttons.append(button)
        }
        actions = Array(repeating: {}, count: symbols.count)
        defaultTooltips = symbols.map(\.tooltip)
        // Full-presence like the selected pill; the shared tint keeps the
        // strip's three capsule surfaces in one material family.
        alphaValue = 1.0
        applySurfaceTint()
    }

    /// Same surface tone as the selected pill (see NativeGlassTabPillView.applySurfaceState).
    private func applySurfaceTint() {
        #if compiler(>=6.2)
        glass.tintColor = WindowGlassEffect.surfaceLiftTint(for: effectiveAppearance)
        #endif
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applySurfaceTint()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var preferredWidth: CGFloat { CGFloat(buttons.count) * Self.buttonWidth }

    func setActions(_ newActions: [() -> Void]) {
        guard newActions.count == buttons.count else { return }
        actions = newActions
    }

    /// Disabled buttons keep the capsule visible (the affordance shouldn't
    /// vanish at a limit) but explain themselves through the swapped tooltip.
    func setEnabled(_ enabled: Bool, disabledTooltip: String? = nil) {
        for (index, button) in buttons.enumerated() {
            button.isEnabled = enabled
            button.contentTintColor = enabled ? .secondaryLabelColor : .tertiaryLabelColor
            button.toolTip = enabled ? defaultTooltips[index] : (disabledTooltip ?? defaultTooltips[index])
        }
    }

    override func layout() {
        super.layout()
        glass.frame = bounds
        container.frame = glass.bounds
        for (index, button) in buttons.enumerated() {
            button.frame = NSRect(
                x: CGFloat(index) * Self.buttonWidth,
                y: 0,
                width: Self.buttonWidth,
                height: bounds.height
            )
        }
    }

    /// Same NSGlassEffectView caveat as the tab pills: its internals do not
    /// hit-test through to the reparented contentView, so route directly.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        for button in buttons where button.frame.contains(local) { return button }
        return self
    }

    @objc private func buttonPressed(_ sender: NSButton) {
        guard actions.indices.contains(sender.tag) else { return }
        actions[sender.tag]()
    }
}

@MainActor
@available(macOS 26.0, *)
private final class NativeGlassTabPillView: NSView, NSDraggingSource {
    private let glass = NSGlassEffectView(frame: .zero)
    private let control = NativeTabPillControl(frame: .zero)

    var preferredWidth: CGFloat { control.preferredWidth }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        #if compiler(>=6.2)
        glass.style = .regular
        glass.cornerRadius = WindowGlassEffect.controlCornerRadius
        glass.contentView = control
        #endif
        addSubview(glass)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        glass.frame = bounds
        control.frame = glass.bounds
    }

    /// NSGlassEffectView's internal hierarchy does not reliably hit-test through
    /// to the reparented contentView; route pointer events to the control directly.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        // The control shares the pill's geometry, so the pill-local point is
        // valid in the control's superview space as well.
        return control.hitTest(local) ?? control
    }

    func update(
        _ tab: BonsplitPaneChromeTabDescriptor,
        select: @escaping () -> Void,
        close: @escaping () -> Void,
        context: @escaping (TabContextAction) -> Void,
        dragData: @escaping () -> Data?,
        dragState: @escaping (Bool) -> Void
    ) {
        control.update(tab, select: select, close: close, context: context, dragData: dragData, dragState: dragState)
        isSelected = tab.isSelected
        control.onHoverChanged = { [weak self] hovering in
            self?.isHovered = hovering
            self?.applySurfaceState()
        }
        applySurfaceState()
    }

    private var isSelected = false
    private var isHovered = false

    /// Maps-style states: the selected pill reads as a solid lit surface,
    /// hover lifts a quiet pill slightly, unselected pills stay quiet glass.
    /// Accent fills fight the native material; tint with the text primary.
    private func applySurfaceState() {
        #if compiler(>=6.2)
        // One shared surface tone across the strip: selected pills and the
        // control capsules share it; quiet pills stay untinted. labelColor@0.12
        // is a white lift in dark mode, but the same alpha in light mode is a
        // black wash that reads muddy/pressed — halve it there.
        if isSelected {
            glass.tintColor = WindowGlassEffect.surfaceLiftTint(for: effectiveAppearance)
        } else if isHovered {
            glass.tintColor = WindowGlassEffect.surfaceLiftTint(for: effectiveAppearance, hover: true)
        } else {
            glass.tintColor = nil
        }
        #endif
        alphaValue = isSelected ? 1.0 : (isHovered ? 0.94 : 0.85)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applySurfaceState()
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .move
    }
}

@MainActor
@available(macOS 26.0, *)
private final class NativeTabPillControl: NSControl, NSMenuDelegate, NSDraggingSource {
    private let iconView = NSImageView(frame: .zero)
    private let titleField = NSTextField(labelWithString: "")
    private let closeButton = NSButton(frame: .zero)
    private var tracking: NSTrackingArea?
    private var tab: BonsplitPaneChromeTabDescriptor?
    private var selectAction: (() -> Void)?
    private var closeAction: (() -> Void)?
    private var contextAction: ((TabContextAction) -> Void)?
    private var dragData: (() -> Data?)?
    private var dragState: ((Bool) -> Void)?
    var onHoverChanged: ((Bool) -> Void)?
    private var mouseDownPoint: NSPoint?

    var preferredWidth: CGFloat {
        // Mirror of layout(): icon leading 12 + icon 16 + gap 6 + trailing close
        // region 34, plus breathing room so the label never truncates.
        ceil(titleField.intrinsicContentSize.width) + 78
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.font = .systemFont(ofSize: 13, weight: .medium)
        iconView.imageScaling = .scaleProportionallyDown
        let closeTitle = String(localized: "tabBar.closeTab", defaultValue: "Close Tab")
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: closeTitle)
        closeButton.setAccessibilityLabel(closeTitle)
        closeButton.toolTip = closeTitle
        closeButton.isBordered = false
        closeButton.target = self
        closeButton.action = #selector(closePressed)
        addSubview(iconView)
        addSubview(titleField)
        addSubview(closeButton)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        iconView.frame = NSRect(x: 12, y: (bounds.height - 16) / 2, width: 16, height: 16)
        closeButton.frame = NSRect(x: bounds.width - 28, y: (bounds.height - 20) / 2, width: 20, height: 20)
        titleField.frame = NSRect(x: 34, y: (bounds.height - 18) / 2, width: max(10, bounds.width - 68), height: 18)
    }

    /// Inner label/icon views don't reliably bubble middle-click and context
    /// events; claim everything except the close button so the whole pill acts
    /// as one control.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        if !closeButton.isHidden, closeButton.frame.contains(local) { return closeButton }
        return self
    }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.activeInKeyWindow, .mouseEnteredAndExited], owner: self)
        addTrackingArea(area)
        tracking = area
        super.updateTrackingAreas()
    }

    func update(
        _ tab: BonsplitPaneChromeTabDescriptor,
        select: @escaping () -> Void,
        close: @escaping () -> Void,
        context: @escaping (TabContextAction) -> Void,
        dragData: @escaping () -> Data?,
        dragState: @escaping (Bool) -> Void
    ) {
        self.tab = tab
        selectAction = select
        closeAction = close
        contextAction = context
        self.dragData = dragData
        self.dragState = dragState
        titleField.stringValue = tab.title
        titleField.font = .systemFont(ofSize: 13, weight: tab.isSelected ? .semibold : .medium)
        titleField.textColor = tab.isSelected ? .labelColor : .secondaryLabelColor
        // Selection reads through the title weight and surface tone; a primary-
        // tinted filled glyph (terminal.fill is a solid box) overpowers the pill.
        iconView.contentTintColor = .secondaryLabelColor
        closeButton.contentTintColor = .secondaryLabelColor
        if let data = tab.iconImageData, let image = NSImage(data: data) {
            iconView.image = image
        } else if let icon = tab.icon {
            // Unconfigured symbols render at the full 16pt slot; boxy filled
            // glyphs like terminal.fill then dominate the pill. Match the
            // SwiftUI tab bar's smaller optical size.
            let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
            // The filled variant is a solid box that dominates the pill; the
            // strip's control capsules already use the outline variant.
            let resolvedName = icon == "terminal.fill" ? "terminal" : icon
            let symbol = NSImage(systemSymbolName: resolvedName, accessibilityDescription: nil)
                ?? NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
            iconView.image = symbol?.withSymbolConfiguration(configuration) ?? symbol
        } else {
            iconView.image = nil
        }
        closeButton.isHidden = tab.isPinned
        toolTip = tab.title
        setAccessibilityLabel(tab.title)
        setAccessibilityValue(tab.accessibilityValue)
        needsLayout = true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Full Keyboard Access: the pill joins the key-view loop, activates on
    // Space/Return, and draws the standard ring clipped to its capsule shape.
    // Gated like NSButton — unconditional acceptance would let a plain click
    // pull first responder off the terminal surface.
    override var acceptsFirstResponder: Bool { NSApp.isFullKeyboardAccessEnabled }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(
            roundedRect: bounds,
            xRadius: WindowGlassEffect.controlCornerRadius,
            yRadius: WindowGlassEffect.controlCornerRadius
        ).fill()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49, 36, 76:  // space, return, keypad enter
            selectAction?()
        default:
            super.keyDown(with: event)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
    }

    override func mouseDown(with event: NSEvent) {
#if DEBUG
        dlog("paneChrome.pill.mouseDown title=\(titleField.stringValue)")
#endif
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        selectAction?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint else { return }
        let current = convert(event.locationInWindow, from: nil)
        guard hypot(current.x - start.x, current.y - start.y) > 4,
              let data = dragData?() else { return }
        let item = NSPasteboardItem()
        item.setData(data, forType: NSPasteboard.PasteboardType("com.splittabbar.tabtransfer"))
        let draggingItem = NSDraggingItem(pasteboardWriter: item)
        draggingItem.setDraggingFrame(bounds, contents: bitmapImageRepForCachingDisplay(in: bounds))
        dragState?(true)
        let session = beginDraggingSession(with: [draggingItem], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        mouseDownPoint = nil
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseDown(with: event)
            return
        }
#if DEBUG
        dlog("paneChrome.pill.middleClick title=\(titleField.stringValue)")
#endif
        closeAction?()
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let tab else { return }
        let menu = NSMenu()
        for item in tab.menuItems {
            switch item {
            case .separator:
                menu.addItem(.separator())
            case .action(let title, let action, let enabled):
                let menuItem = NSMenuItem(title: title, action: #selector(menuAction(_:)), keyEquivalent: "")
                menuItem.target = self
                menuItem.representedObject = ActionBox(action)
                menuItem.isEnabled = enabled
                menu.addItem(menuItem)
            }
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func closePressed() { closeAction?() }

    @objc private func menuAction(_ sender: NSMenuItem) {
        guard let action = (sender.representedObject as? ActionBox)?.action else { return }
        contextAction?(action)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .move
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragState?(false)
    }
}

private final class ActionBox: NSObject {
    let action: TabContextAction
    init(_ action: TabContextAction) { self.action = action }
}
#endif
