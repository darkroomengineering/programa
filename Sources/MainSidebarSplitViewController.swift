import AppKit
import Bonsplit
import Combine
import SwiftUI

enum SidebarWidthPolicy {
    static let minimum = CGFloat(SessionPersistencePolicy.minimumSidebarWidth)
    static let maximumRatio: CGFloat = 1.0 / 3.0

    /// The sidebar never takes more than a third of the window, and never more than the
    /// persisted ceiling; the floor wins in windows too narrow for both.
    static func maximum(forAvailableWidth availableWidth: CGFloat) -> CGFloat {
        let ceiling = CGFloat(SessionPersistencePolicy.maximumSidebarWidth)
        guard availableWidth.isFinite, availableWidth > 0 else { return ceiling }
        return max(minimum, min(ceiling, availableWidth * maximumRatio))
    }

    static func clamped(_ candidate: CGFloat, maximumWidth: CGFloat) -> CGFloat {
        let sanitizedMaximum = max(minimum, maximumWidth.isFinite ? maximumWidth : minimum)
        guard candidate.isFinite else { return CGFloat(SessionPersistencePolicy.defaultSidebarWidth) }
        return max(minimum, min(sanitizedMaximum, candidate))
    }
}

/// Marks the main window's sidebar split so Programa's own divider walkers
/// (`WindowTerminalHostView`, `SplitDividerOverlayView`) leave its divider to AppKit.
protocol MainSidebarSplitViewMarker: AnyObject {}

final class MainSidebarSplitView: NSSplitView, MainSidebarSplitViewMarker {
    var onMoveToWindow: ((NSWindow?) -> Void)?
    var onFrameSizeWillChange: ((NSSize) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onMoveToWindow?(window)
    }

    // The 1/3 cap has to change before the frame does, so the layout pass that follows a
    // window resize already solves against the new maximum.
    override func setFrameSize(_ newSize: NSSize) {
        onFrameSizeWillChange?(newSize)
        super.setFrameSize(newSize)
    }
}

/// Hosts the main window's sidebar and content columns as system split view items.
/// `SidebarState` stays the model: visibility and width flow into the split items, and
/// only user-driven changes (divider drags, the divider collapse) flow back.
final class MainSidebarSplitViewController: NSSplitViewController {
    let sidebarHost: MainWindowHostingView<AnyView>
    let contentHost: MainWindowHostingView<AnyView>
    let sidebarItem: NSSplitViewItem
    private weak var sidebarState: SidebarState?
    private var cancellables: Set<AnyCancellable> = []
    private var collapseObservation: NSKeyValueObservation?
    /// The collapse state this controller last asked for; a KVO change that differs from
    /// it came from the user.
    private var requestedCollapsed = false
    private var didApplyInitialWidth = false
    private var isWritingPersistedWidth = false
    private var isSeedingWidth = false
    private var isApplyingWidth = false
    private var isReapplyScheduled = false
    private var lastSplitWidth: CGFloat = 0
    /// Collapse animations whose completion has not run; released in deinit so a window
    /// closed mid-animation cannot leave the global portal resize counter raised.
    private var pendingAnimations = 0

    init(sidebar: AnyView, content: AnyView) {
        sidebarHost = MainWindowHostingView(rootView: sidebar)
        contentHost = MainWindowHostingView(rootView: content)
        // The split items own the column sizes; SwiftUI's ideal sizes must not fight the divider.
        sidebarHost.sizingOptions = []
        contentHost.sizingOptions = []
        let sidebarController = NSViewController()
        sidebarController.view = sidebarHost
        let contentController = NSViewController()
        contentController.view = contentHost
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarController)
        sidebarItem.canCollapse = true
        // Only the user hides the sidebar; a narrow window keeps it at the minimum width.
        sidebarItem.canCollapseFromWindowResize = false
        sidebarItem.minimumThickness = SidebarWidthPolicy.minimum
        sidebarItem.maximumThickness = CGFloat(SessionPersistencePolicy.maximumSidebarWidth)
        sidebarItem.allowsFullHeightLayout = true
        let contentItem = NSSplitViewItem(viewController: contentController)
        super.init(nibName: nil, bundle: nil)

        let split = MainSidebarSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        // The session snapshot is the only width store (per window).
        split.autosaveName = nil
        split.setAccessibilityIdentifier("MainSidebarSplit")
        split.onMoveToWindow = { [weak self] window in
            guard let window else { return }
            DispatchQueue.main.async {
                guard let self, self.view.window === window else { return }
                MainWindowToolbar.installIfNeeded(on: window)
            }
        }
        split.onFrameSizeWillChange = { [weak self] size in
            self?.updateMaximumThickness(availableWidth: size.width)
        }
        splitView = split
        addSplitViewItem(sidebarItem)
        addSplitViewItem(contentItem)
        collapseObservation = sidebarItem.observe(\.isCollapsed, options: [.new]) { [weak self] item, _ in
            MainActor.assumeIsolated { self?.sidebarItemCollapseDidChange(item.isCollapsed) }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        let pending = pendingAnimations
        guard pending > 0 else { return }
        Task { @MainActor in
            for _ in 0..<pending { TerminalWindowPortalRegistry.endInteractiveGeometryResize() }
        }
    }

    func bind(to state: SidebarState) {
        sidebarState = state
        requestedCollapsed = !state.isVisible
        sidebarItem.isCollapsed = requestedCollapsed
        // @Published emits from willSet: use the emitted value, never read the state back here.
        state.$isVisible
            .dropFirst()
            .sink { [weak self, weak state] visible in
                guard let self, let state else { return }
                let animated = state.nextVisibilityChangeAnimates
                state.nextVisibilityChangeAnimates = false
                self.applyVisibility(visible, animated: animated)
            }
            .store(in: &cancellables)
        state.$persistedWidth
            .dropFirst()
            .sink { [weak self] width in
                guard let self, !self.isWritingPersistedWidth, self.didApplyInitialWidth else { return }
                self.applyWidth(width)
            }
            .store(in: &cancellables)
    }

    var isSidebarCollapsed: Bool { sidebarItem.isCollapsed }
    var sidebarWidth: CGFloat { sidebarHost.frame.width }
    var currentMaximumWidth: CGFloat { sidebarItem.maximumThickness }

    /// `persistedWidth` is the width the user chose; the 1/3 cap only limits what is shown.
    /// A window that shrinks below it narrows the sidebar without forgetting the choice, and
    /// one that grows back restores it here.
    override func viewDidLayout() {
        super.viewDidLayout()
        guard let state = sidebarState, view.window != nil, view.bounds.width > 0 else { return }
        if !didApplyInitialWidth {
            didApplyInitialWidth = true
            updateMaximumThickness(availableWidth: view.bounds.width)
            applyWidth(state.persistedWidth)
            return
        }
        guard !isReapplyScheduled, needsWidthReapply(state) else { return }
        // Not from inside the layout pass.
        isReapplyScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isReapplyScheduled = false
            self.reapplyWidthIfNeeded()
        }
    }

    private func needsWidthReapply(_ state: SidebarState) -> Bool {
        // Never fight a divider drag in progress; the drag records its own width on the way.
        guard pendingAnimations == 0, !sidebarItem.isCollapsed, NSEvent.pressedMouseButtons & 1 == 0 else { return false }
        let target = SidebarWidthPolicy.clamped(state.persistedWidth, maximumWidth: sidebarItem.maximumThickness)
        return abs(sidebarHost.frame.width - target) > 0.5
    }

    private func reapplyWidthIfNeeded() {
        guard let state = sidebarState, needsWidthReapply(state) else { return }
        applyWidth(state.persistedWidth)
    }

    private func updateMaximumThickness(availableWidth: CGFloat) {
        let maximum = SidebarWidthPolicy.maximum(forAvailableWidth: availableWidth)
        if abs(sidebarItem.maximumThickness - maximum) > 0.5 {
            sidebarItem.maximumThickness = maximum
        }
    }

    /// Moves the divider to `width` (clamped). A collapsed sidebar picks the width up when it
    /// expands (`seedExpandedWidth`).
    private func applyWidth(_ width: CGFloat) {
        guard !sidebarItem.isCollapsed else { return }
        let target = SidebarWidthPolicy.clamped(width, maximumWidth: sidebarItem.maximumThickness)
        guard abs(sidebarHost.frame.width - target) > 0.5 else { return }
#if DEBUG
        dlog("sidebar.split.applyWidth requested=\(String(format: "%.0f", width)) target=\(Int(target)) from=\(Int(sidebarHost.frame.width)) split=\(Int(splitView.bounds.width))")
#endif
        isApplyingWidth = true
        splitView.setPosition(target, ofDividerAt: 0)
        isApplyingWidth = false
    }

    /// An expanding item returns to the thickness it had when it collapsed. Size it to the
    /// persisted width first: expand, move the divider and collapse again, all before the
    /// window draws.
    private func seedExpandedWidth() {
        guard let state = sidebarState, sidebarItem.isCollapsed, didApplyInitialWidth else { return }
        isSeedingWidth = true
        isApplyingWidth = true
        sidebarItem.isCollapsed = false
        splitView.layoutSubtreeIfNeeded()
        let target = SidebarWidthPolicy.clamped(state.persistedWidth, maximumWidth: sidebarItem.maximumThickness)
        splitView.setPosition(target, ofDividerAt: 0)
        splitView.layoutSubtreeIfNeeded()
        sidebarItem.isCollapsed = true
        splitView.layoutSubtreeIfNeeded()
        isApplyingWidth = false
        isSeedingWidth = false
    }

    private func applyVisibility(_ visible: Bool, animated: Bool) {
        let collapsed = !visible
        requestedCollapsed = collapsed
        guard sidebarItem.isCollapsed != collapsed else { return }
        guard let window = view.window else {
            sidebarItem.isCollapsed = collapsed
            return
        }
        MainWindowToolbar.setSidebarCollapsed(collapsed, in: window)
        if !collapsed { seedExpandedWidth() }
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            sidebarItem.isCollapsed = collapsed
            reapplyWidthIfNeeded()
            postToggleDidSettle()
            return
        }
        // The terminal is an AppKit portal above the split view; marking the collapse as an
        // interactive resize makes it follow the animated column frame every tick.
        TerminalWindowPortalRegistry.beginInteractiveGeometryResize()
        pendingAnimations += 1
        NSAnimationContext.runAnimationGroup({ context in
            context.allowsImplicitAnimation = true
            sidebarItem.animator().isCollapsed = collapsed
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pendingAnimations -= 1
                TerminalWindowPortalRegistry.endInteractiveGeometryResize()
                self.reapplyWidthIfNeeded()
                self.postToggleDidSettle()
            }
        })
    }

    private func postToggleDidSettle() {
        guard let sidebarState else { return }
        NotificationCenter.default.post(name: .programaSidebarToggleDidSettle, object: sidebarState)
    }

    private func sidebarItemCollapseDidChange(_ collapsed: Bool) {
        guard !isSeedingWidth, collapsed != requestedCollapsed else { return }
        // The user collapsed or expanded the sidebar through the split view itself.
        requestedCollapsed = collapsed
        if let window = view.window {
            MainWindowToolbar.setSidebarCollapsed(collapsed, in: window)
        }
        guard let state = sidebarState, state.isVisible == collapsed else { return }
        state.isVisible = !collapsed
    }

    /// Only a divider drag records a new width: a left-mouse event is in flight and the split
    /// view kept its own width. Window resizes (including a double-click zoom), session restore
    /// and the 1/3 cap change what is shown, never the width the user chose.
    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        let splitWidth = splitView.bounds.width
        let splitWidthChanged = abs(splitWidth - lastSplitWidth) > 0.5
        lastSplitWidth = splitWidth
        guard didApplyInitialWidth, !splitWidthChanged, !isApplyingWidth, pendingAnimations == 0, !splitView.inLiveResize,
              !sidebarItem.isCollapsed, let state = sidebarState,
              let eventType = NSApp.currentEvent?.type,
              [.leftMouseDown, .leftMouseDragged, .leftMouseUp].contains(eventType) else { return }
        let width = sidebarHost.frame.width
        guard width >= SidebarWidthPolicy.minimum - 0.5, abs(state.persistedWidth - width) > 0.5 else { return }
#if DEBUG
        dlog("sidebar.split.widthFromDrag \(Int(state.persistedWidth))->\(Int(width)) split=\(Int(splitView.bounds.width))")
#endif
        isWritingPersistedWidth = true
        state.persistedWidth = width
        isWritingPersistedWidth = false
    }
}

/// Each column is its own SwiftUI root, so `ContentView` state reaches it only when the
/// host's `rootView` is reassigned. `sidebarInputs` / `contentInputs` hold every value the
/// column reads from `ContentView` outside its own observed objects; a host is re-rooted
/// only when its inputs change, never on every `ContentView` body evaluation.
struct MainSidebarSplitRepresentable: NSViewControllerRepresentable {
    let sidebar: AnyView
    let sidebarInputs: AnyHashable
    let content: AnyView
    let contentInputs: AnyHashable
    let sidebarState: SidebarState

    final class Coordinator {
        var sidebarInputs: AnyHashable?
        var contentInputs: AnyHashable?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSViewController(context: Context) -> MainSidebarSplitViewController {
        let controller = MainSidebarSplitViewController(sidebar: sidebar, content: content)
        controller.bind(to: sidebarState)
        context.coordinator.sidebarInputs = sidebarInputs
        context.coordinator.contentInputs = contentInputs
        return controller
    }

    func updateNSViewController(_ controller: MainSidebarSplitViewController, context: Context) {
        if context.coordinator.sidebarInputs != sidebarInputs {
            context.coordinator.sidebarInputs = sidebarInputs
            controller.sidebarHost.rootView = sidebar
#if DEBUG
            MainSidebarSplitDebugCounters.sidebarRootUpdates += 1
#endif
        }
        if context.coordinator.contentInputs != contentInputs {
            context.coordinator.contentInputs = contentInputs
            controller.contentHost.rootView = content
#if DEBUG
            MainSidebarSplitDebugCounters.contentRootUpdates += 1
#endif
        }
#if DEBUG
        MainSidebarSplitDebugCounters.updateCalls += 1
#endif
    }
}

#if DEBUG
/// Read by `debug.sidebar.set` to measure how often the column hosts are re-rooted.
enum MainSidebarSplitDebugCounters {
    static var updateCalls = 0
    static var sidebarRootUpdates = 0
    static var contentRootUpdates = 0
}
#endif

#if DEBUG
extension AppDelegate {
    /// Backs the `debug.sidebar.set` socket method: applies the requested state through
    /// `SidebarState` and reports the split view geometry and toolbar it produced.
    func debugSetSidebar(windowId: UUID, visible: Bool?, width: CGFloat?, animated: Bool) -> [String: Any]? {
        guard let context = mainWindowContexts.values.first(where: { $0.windowId == windowId }) else { return nil }
        let state = context.sidebarState
        if let width {
            state.persistedWidth = width
        }
        if let visible, visible != state.isVisible {
            state.toggle(animated: animated)
        }
        var snapshot: [String: Any] = [
            "window_id": windowId.uuidString,
            "visible": state.isVisible,
            "persisted_width": Double(state.persistedWidth),
            "update_calls": MainSidebarSplitDebugCounters.updateCalls,
            "sidebar_root_updates": MainSidebarSplitDebugCounters.sidebarRootUpdates,
            "content_root_updates": MainSidebarSplitDebugCounters.contentRootUpdates,
        ]
        guard let window = context.window ?? windowForMainWindowId(windowId) else { return snapshot }
        snapshot["window_number"] = window.windowNumber
        snapshot["window_width"] = Double(window.frame.width)
        snapshot["titlebar_height"] = Double(window.frame.height - window.contentLayoutRect.height)
        if let controller = Self.debugSidebarSplitController(in: window.contentView) {
            controller.view.layoutSubtreeIfNeeded()
            snapshot["collapsed"] = controller.isSidebarCollapsed
            snapshot["sidebar_width"] = Double(controller.sidebarWidth)
            snapshot["max_width"] = Double(controller.currentMaximumWidth)
        }
        if let toolbar = window.toolbar {
            snapshot["toolbar_id"] = toolbar.identifier
            snapshot["toolbar_visible"] = toolbar.isVisible
            snapshot["toolbar_items"] = toolbar.items.map(\.itemIdentifier.rawValue)
        }
        if let edge = MainWindowToolbar.expectedCollapsedControlsTrailingEdge() {
            snapshot["expected_collapsed_controls_max_x"] = Double(edge)
        }
        if let edge = MainWindowToolbar.collapsedControlsTrailingEdge(in: window) {
            snapshot["collapsed_controls_max_x"] = Double(edge)
        }
        if let workspace = context.tabManager.selectedWorkspace {
            snapshot["tab_bar_leading_inset"] = Double(workspace.bonsplitController.configuration.appearance.tabBarLeadingInset)
        }
        if let titlebarView = window.standardWindowButton(.closeButton)?.superview {
            var viewers: [String] = []
            func collect(_ view: NSView) {
                if String(describing: type(of: view)).contains("ItemViewer"), !view.isHiddenOrHasHiddenAncestor {
                    let frame = view.convert(view.bounds, to: nil)
                    viewers.append(String(format: "%.0f,%.0f,%.0f,%.0f", frame.minX, frame.minY, frame.width, frame.height))
                }
                view.subviews.forEach(collect)
            }
            collect(titlebarView.superview ?? titlebarView)
            snapshot["toolbar_viewers"] = viewers
            if let zoom = window.standardWindowButton(.zoomButton) {
                snapshot["zoom_max_x"] = Double(zoom.convert(zoom.bounds, to: nil).maxX)
            }
        }
        return snapshot
    }

    private static func debugSidebarSplitController(in view: NSView?) -> MainSidebarSplitViewController? {
        guard let view else { return nil }
        if view is MainSidebarSplitViewMarker, let controller = (view as? NSSplitView)?.delegate as? MainSidebarSplitViewController {
            return controller
        }
        for subview in view.subviews {
            if let found = debugSidebarSplitController(in: subview) { return found }
        }
        return nil
    }
}
#endif
