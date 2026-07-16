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

// MARK: - Ghostty Surface View (split out, Nuclear Review #97; verbatim move)
// Keyboard/mouse/drag/accessibility/IME/render-stats live in GhosttyTerminalView+*.swift.

class GhosttyNSView: NSView, NSUserInterfaceValidations {
    private static let focusDebugEnabled: Bool = {
        if ProcessInfo.processInfo.environment["PROGRAMA_FOCUS_DEBUG"] == "1" {
            return true
        }
        return UserDefaults.standard.bool(forKey: "programaFocusDebug")
    }()
    internal enum DropPlan: Equatable {
        case insertText(String)
        case uploadFiles([URL])
        case reject
    }

    static let dropTypes: Set<NSPasteboard.PasteboardType> = [
        .string,
        .fileURL,
        .URL,
        .png,
        .tiff,
        NSPasteboard.PasteboardType(UTType.jpeg.identifier),
        NSPasteboard.PasteboardType(UTType.gif.identifier),
        NSPasteboard.PasteboardType(UTType.heic.identifier),
        NSPasteboard.PasteboardType(UTType.heif.identifier)
    ]
    private static let tabTransferPasteboardType = NSPasteboard.PasteboardType("com.splittabbar.tabtransfer")
    private static let sidebarTabReorderPasteboardType = NSPasteboard.PasteboardType("com.darkroom.programa.sidebar-tab-reorder")

    enum WordPathResolutionSource: String {
        case quicklook
        case snapshot
    }

    struct WordPathResolution {
        let path: String
        let source: WordPathResolutionSource
        let rawToken: String
    }

    func makeWordPathResolution(
        path: String,
        source: WordPathResolutionSource,
        rawToken: String
    ) -> WordPathResolution {
        WordPathResolution(
            path: path,
            source: source,
            rawToken: rawToken
        )
    }

    static func focusLog(_ message: String) {
        guard focusDebugEnabled else { return }
        FocusLogStore.shared.append(message)
        NSLog("[FOCUSDBG] %@", message)
    }

    weak var terminalSurface: TerminalSurface?
    var scrollbar: GhosttyScrollbar?
    /// Pending scrollbar value written from the action callback thread;
    /// read and cleared on the main thread by `flushPendingScrollbar()`.
    /// Access is guarded by `_scrollbarLock` because the action callback
    /// fires on Ghostty's I/O thread while the flush runs on main.
    private var _pendingScrollbar: GhosttyScrollbar?
    private var _scrollbarFlushScheduled = false
    private let _scrollbarLock = NSLock()
    var cellSize: CGSize = .zero
    var lastKnownMousePointInView: NSPoint?

    /// Coalesce high-frequency scrollbar updates into a single main-thread
    /// dispatch.  The action callback (which may fire thousands of times per
    /// second during bulk output like `seq 1 100000`) stores the latest value
    /// and schedules exactly one async flush.
    func enqueueScrollbarUpdate(_ newValue: GhosttyScrollbar) {
        _scrollbarLock.lock()
        defer { _scrollbarLock.unlock() }
        // Store the latest value (always overwrites — only the newest matters).
        _pendingScrollbar = newValue
        let needsSchedule = !_scrollbarFlushScheduled
        if needsSchedule { _scrollbarFlushScheduled = true }

        // If a flush is already scheduled, skip the dispatch — the scheduled
        // block will pick up the latest value.
        guard needsSchedule else { return }
        DispatchQueue.main.async { [weak self] in
            self?.flushPendingScrollbar()
        }
    }

    private func flushPendingScrollbar() {
        _scrollbarLock.lock()
        _scrollbarFlushScheduled = false
        let pending = _pendingScrollbar
        _pendingScrollbar = nil
        _scrollbarLock.unlock()

        guard let pending else { return }
        scrollbar = pending
        NotificationCenter.default.post(
            name: .ghosttyDidUpdateScrollbar,
            object: self,
            userInfo: [GhosttyNotificationKey.scrollbar: pending]
        )
    }

    var desiredFocus: Bool = false
    var suppressingReparentFocus: Bool = false
    var tabId: UUID?
    var onFocus: (() -> Void)?
    var onTriggerFlash: (() -> Void)?
    var backgroundColor: NSColor?
    private var appliedColorScheme: ghostty_color_scheme_e?
    private var lastLoggedSurfaceBackgroundSignature: String?
    private var lastLoggedWindowBackgroundSignature: String?
    var keySequence: [ghostty_input_trigger_s] = []
    var keyTables: [String] = []
    var keyboardCopyModeActive = false
    var wordPathHoverActive = false
    var keyboardCopyModeConsumedKeyUps: Set<UInt16> = []
    var keyboardCopyModeInputState = TerminalKeyboardCopyModeInputState()
    var keyboardCopyModeViewportRow: Int?
    /// Tracks whether the user has explicitly entered visual selection mode (v).
    /// Separate from Ghostty's `has_selection` because copy mode always maintains
    /// a 1-cell selection as a visible cursor. This flag determines whether
    /// movements should extend the selection (visual) or scroll the viewport.
    var keyboardCopyModeVisualActive = false
    var isKeyboardCopyModeActive: Bool { keyboardCopyModeActive }
    var currentKeyStateIndicatorText: String? {
        if let name = keyTables.last {
            return terminalKeyTableIndicatorText(name)
        }

        if keyboardCopyModeActive {
            return terminalKeyboardCopyModeIndicatorText
        }

        return nil
    }
#if DEBUG
    static let keyLatencyProbeEnabled: Bool = {
        if ProcessInfo.processInfo.environment["PROGRAMA_KEY_LATENCY_PROBE"] == "1" {
            return true
        }
        return UserDefaults.standard.bool(forKey: "programaKeyLatencyProbe")
    }()
    static var debugGhosttySurfaceKeyEventObserver: ((ghostty_input_key_s) -> Void)?
#endif
    private var eventMonitor: Any?
    var trackingArea: NSTrackingArea?
    private var windowObserver: NSObjectProtocol?
    var lastScrollEventTime: CFTimeInterval = 0
    private var visibleInUI: Bool = true
    private var pendingSurfaceSize: CGSize?
    private var deferredSurfaceSizeRetryQueued = false
    private var lastDrawableSize: CGSize = .zero
    var isFindEscapeSuppressionArmed = false
#if DEBUG
    private var lastSizeSkipSignature: String?
#endif

    var hasUsableFocusGeometry: Bool {
        bounds.width > 1 && bounds.height > 1
    }

    static func shouldRequestFirstResponderForMouseFocus(
        focusFollowsMouseEnabled: Bool,
        pressedMouseButtons: Int,
        appIsActive: Bool,
        windowIsKey: Bool,
        alreadyFirstResponder: Bool,
        visibleInUI: Bool,
        hasUsableGeometry: Bool,
        hiddenInHierarchy: Bool
    ) -> Bool {
        guard focusFollowsMouseEnabled else { return false }
        guard pressedMouseButtons == 0 else { return false }
        guard appIsActive, windowIsKey else { return false }
        guard !alreadyFirstResponder else { return false }
        guard visibleInUI, hasUsableGeometry, !hiddenInHierarchy else { return false }
        return true
    }

        // Visibility is used for focus gating. Explicit portal visibility transitions
        // also drive Ghostty occlusion so hidden workspace/split surfaces pause and
        // queue a redraw when they become visible again.
        var isVisibleInUI: Bool { visibleInUI }
        func setVisibleInUI(_ visible: Bool) {
            visibleInUI = visible
        }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    override func makeBackingLayer() -> CALayer {
        let metalLayer = CAMetalLayer()
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.isOpaque = false
        // framebufferOnly=false lets the macOS compositor read the drawable
        // when blending translucent or blurred window layers.  This matches
        // standalone Ghostty's SurfaceView and is required for background-opacity
        // and background-blur to render correctly.
        metalLayer.framebufferOnly = false
        return metalLayer
    }

    private func setup() {
        // Only enable our instrumented CAMetalLayer in targeted debug/test scenarios.
        // The lock in GhosttyMetalLayer.nextDrawable() adds overhead we don't want in normal runs.
        wantsLayer = true
        layer?.masksToBounds = true
        installEventMonitor()
        updateTrackingAreas()
        registerForDraggedTypes(Array(Self.dropTypes))
    }

    private func effectiveBackgroundColor() -> NSColor {
        let base = backgroundColor ?? GhosttyApp.shared.defaultBackgroundColor
        let opacity = GhosttyApp.shared.defaultBackgroundOpacity
        return base.withAlphaComponent(opacity)
    }

    func applySurfaceBackground() {
        let useHostLayerBackground = GhosttyApp.shared.usesHostLayerBackground
        let color = useHostLayerBackground ? effectiveBackgroundColor() : .clear
        if let layer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            // GhosttySurfaceScrollView owns the panel background fill. Keeping this layer clear
            // avoids stacking multiple identical translucent backgrounds (which looks opaque).
            layer.backgroundColor = NSColor.clear.cgColor
            layer.isOpaque = false
            CATransaction.commit()
        }
        terminalSurface?.hostedView.setBackgroundColor(color)
        if GhosttyApp.shared.backgroundLogEnabled {
            let signature = "\(useHostLayerBackground ? color.hexString() : "ghostty-native"):\(String(format: "%.3f", color.alphaComponent))"
            if signature != lastLoggedSurfaceBackgroundSignature {
                lastLoggedSurfaceBackgroundSignature = signature
                let hasOverride = backgroundColor != nil
                let overrideHex = backgroundColor?.hexString() ?? "nil"
                let defaultHex = GhosttyApp.shared.defaultBackgroundColor.hexString()
                let source = useHostLayerBackground ? (hasOverride ? "surfaceOverride" : "defaultBackground") : "ghosttyNativeBackground"
                GhosttyApp.shared.logBackground(
                    "surface background applied tab=\(tabId?.uuidString ?? "unknown") surface=\(terminalSurface?.id.uuidString ?? "unknown") source=\(source) override=\(overrideHex) default=\(defaultHex) color=\(color.hexString()) opacity=\(String(format: "%.3f", color.alphaComponent))"
                )
            }
        }
    }

    // Theme/background application is window-local. During cross-window workspace
    // switches (e.g. jump-to-unread), the global active tab manager can lag behind.
    // Prefer the owning window's selected workspace when available.
    static func shouldApplyWindowBackground(
        surfaceTabId: UUID?,
        owningManagerExists: Bool,
        owningSelectedTabId: UUID?,
        activeSelectedTabId: UUID?
    ) -> Bool {
        guard let surfaceTabId else { return true }
        if owningManagerExists {
            guard let owningSelectedTabId else { return true }
            return owningSelectedTabId == surfaceTabId
        }
        if let activeSelectedTabId {
            return activeSelectedTabId == surfaceTabId
        }
        return true
    }

    func applyWindowBackgroundIfActive() {
        guard let window else { return }
        let appDelegate = AppDelegate.shared
        let owningManager = tabId.flatMap { appDelegate?.tabManagerFor(tabId: $0) }
        let owningSelectedTabId = owningManager?.selectedTabId
        let activeSelectedTabId = owningManager == nil ? appDelegate?.tabManager?.selectedTabId : nil
        guard Self.shouldApplyWindowBackground(
            surfaceTabId: tabId,
            owningManagerExists: owningManager != nil,
            owningSelectedTabId: owningSelectedTabId,
            activeSelectedTabId: activeSelectedTabId
        ) else {
            return
        }
        applySurfaceBackground()
        let color = effectiveBackgroundColor()
        if cmuxShouldUseClearWindowBackground(for: color.alphaComponent) {
            window.backgroundColor = programaTransparentWindowBaseColor()
            window.isOpaque = false
            GhosttyApp.shared.applyWindowBlurIfNeeded(window)
        } else {
            window.backgroundColor = color
            window.isOpaque = color.alphaComponent >= 1.0
        }
        if GhosttyApp.shared.backgroundLogEnabled {
            let signature = "\(cmuxShouldUseClearWindowBackground(for: color.alphaComponent) ? "transparent" : color.hexString()):\(String(format: "%.3f", color.alphaComponent))"
            if signature != lastLoggedWindowBackgroundSignature {
                lastLoggedWindowBackgroundSignature = signature
                let hasOverride = backgroundColor != nil
                let overrideHex = backgroundColor?.hexString() ?? "nil"
                let defaultHex = GhosttyApp.shared.defaultBackgroundColor.hexString()
                let source = hasOverride ? "surfaceOverride" : "defaultBackground"
                GhosttyApp.shared.logBackground(
                    "window background applied tab=\(tabId?.uuidString ?? "unknown") surface=\(terminalSurface?.id.uuidString ?? "unknown") source=\(source) override=\(overrideHex) default=\(defaultHex) transparent=\(cmuxShouldUseClearWindowBackground(for: color.alphaComponent)) color=\(color.hexString()) opacity=\(String(format: "%.3f", color.alphaComponent))"
                )
            }
        }
    }

    private func installEventMonitor() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
            return self?.localEventHandler(event) ?? event
        }
    }

    private func localEventHandler(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .scrollWheel:
            return localEventScrollWheel(event)
        default:
            return event
        }
    }

    private func localEventScrollWheel(_ event: NSEvent) -> NSEvent? {
        guard let window,
              let eventWindow = event.window,
              window == eventWindow else { return event }

        let location = convert(event.locationInWindow, from: nil)
        guard hitTest(location) == self else { return event }

        Self.focusLog("localEventScrollWheel: window=\(ObjectIdentifier(window)) firstResponder=\(String(describing: window.firstResponder))")
        return event
    }

    func attachSurface(_ surface: TerminalSurface) {
        let isSameSurface = terminalSurface === surface
        let isAlreadyAttached = surface.isAttached(to: self)
        if !isSameSurface {
            appliedColorScheme = nil
        }
        terminalSurface = surface
        tabId = surface.tabId
        if !isAlreadyAttached {
            surface.attachToView(self)
        }
        surface.setKeyboardCopyModeActive(keyboardCopyModeActive)
        if !isAlreadyAttached {
            updateSurfaceSize()
        }
        applySurfaceBackground()
        applySurfaceColorScheme(force: !isSameSurface || !isAlreadyAttached)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let windowObserver {
            NotificationCenter.default.removeObserver(windowObserver)
            self.windowObserver = nil
        }
        // Balance the cursor stack if the view is removed while hover is active
        if wordPathHoverActive {
            wordPathHoverActive = false
            NSCursor.pop()
        }
#if DEBUG
        dlog(
            "surface.view.windowMove surface=\(terminalSurface?.id.uuidString.prefix(5) ?? "nil") " +
            "inWindow=\(window != nil ? 1 : 0) bounds=\(String(format: "%.1fx%.1f", bounds.width, bounds.height)) " +
            "pending=\(String(format: "%.1fx%.1f", pendingSurfaceSize?.width ?? 0, pendingSurfaceSize?.height ?? 0))"
        )
#endif
        guard let window else { return }

        // If the surface creation was deferred while detached, create/attach it now.
        terminalSurface?.attachToView(self)
        if let terminalSurface {
            NotificationCenter.default.post(
                name: .terminalSurfaceHostedViewDidMoveToWindow,
                object: terminalSurface,
                userInfo: [
                    "surfaceId": terminalSurface.id,
                    "workspaceId": terminalSurface.tabId
                ]
            )
        }

        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeScreenNotification,
            object: window,
            queue: .main
        ) { [weak self] notification in
            self?.windowDidChangeScreen(notification)
        }

        if let surface = terminalSurface?.surface,
           let displayID = window.screen?.displayID,
           displayID != 0 {
            ghostty_surface_set_display_id(surface, displayID)
        }

        // Recompute from current bounds after layout. Pending size is only a fallback
        // when we don't have usable bounds (e.g. detached/off-window transitions).
        superview?.layoutSubtreeIfNeeded()
        layoutSubtreeIfNeeded()
        updateSurfaceSize()
        applySurfaceBackground()
        applySurfaceColorScheme(force: true)
        GhosttyApp.shared.synchronizeThemeWithAppearance(
            effectiveAppearance,
            source: "surface.viewDidMoveToWindow"
        )
        applyWindowBackgroundIfActive()
        invalidateTextInputCoordinates()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if GhosttyApp.shared.backgroundLogEnabled {
            let bestMatch = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
            GhosttyApp.shared.logBackground(
                "surface appearance changed tab=\(tabId?.uuidString ?? "nil") surface=\(terminalSurface?.id.uuidString ?? "nil") bestMatch=\(bestMatch?.rawValue ?? "nil")"
            )
        }
        applySurfaceColorScheme()
        GhosttyApp.shared.synchronizeThemeWithAppearance(
            effectiveAppearance,
            source: "surface.viewDidChangeEffectiveAppearance"
        )
    }

    fileprivate func updateOcclusionState() {
        // Intentionally no-op: we don't drive libghostty occlusion from AppKit occlusion state.
        // This avoids transient clears during reparenting and keeps rendering logic minimal.
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let window {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contentsScale = window.backingScaleFactor
            CATransaction.commit()
        }
        updateSurfaceSize()
        invalidateTextInputCoordinates()
    }

    override func layout() {
        super.layout()
        updateSurfaceSize()
        invalidateTextInputCoordinates()
    }

    override var isOpaque: Bool { false }

    private func resolvedSurfaceSize(preferred size: CGSize?) -> CGSize {
        if let size,
           size.width > 0,
           size.height > 0 {
            return size
        }

        let currentBounds = bounds.size
        if currentBounds.width > 0, currentBounds.height > 0 {
            return currentBounds
        }

        if let pending = pendingSurfaceSize,
           pending.width > 0,
           pending.height > 0 {
            return pending
        }

        return currentBounds
    }

    private static func hasTabDragPasteboardTypes() -> Bool {
        let types = NSPasteboard(name: .drag).types ?? []
        return types.contains(tabTransferPasteboardType) || types.contains(sidebarTabReorderPasteboardType)
    }

    private static func isDragResizeEvent(_ eventType: NSEvent.EventType?) -> Bool {
        switch eventType {
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            return true
        default:
            return false
        }
    }

    private static func shouldDeferSurfaceResizeForActiveDrag() -> Bool {
        // The drag pasteboard can retain tab-transfer UTIs briefly after a split command
        // or other layout churn. Only defer terminal resizes while an actual drag event
        // is in flight; otherwise pre-existing panes can stay stuck at their old size.
        // Interactive geometry resize already has an explicit fast path for sidebar and
        // split-divider drags. Do not let stale drag-pasteboard state suppress those updates.
        if TerminalWindowPortalRegistry.isInteractiveGeometryResizeActive {
            return false
        }
        guard hasTabDragPasteboardTypes() else { return false }
        return isDragResizeEvent(NSApp.currentEvent?.type)
    }

    private func activeSurfaceResizeDeferralReason() -> String? {
        if inLiveResize || window?.inLiveResize == true {
            return nil
        }
        return Self.shouldDeferSurfaceResizeForActiveDrag() ? "tabDrag" : nil
    }

    private func scheduleDeferredSurfaceSizeRetryIfNeeded() {
        guard window != nil else { return }
        guard !deferredSurfaceSizeRetryQueued else { return }
        deferredSurfaceSizeRetryQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.deferredSurfaceSizeRetryQueued = false
            _ = self.updateSurfaceSize()
        }
    }

    @discardableResult
    func updateSurfaceSize(size: CGSize? = nil) -> Bool {
        guard let terminalSurface = terminalSurface else { return false }
        let size = resolvedSurfaceSize(preferred: size)
        guard size.width > 0 && size.height > 0 else {
#if DEBUG
            let signature = "nonPositive-\(Int(size.width))x\(Int(size.height))"
            if lastSizeSkipSignature != signature {
                dlog(
                    "surface.size.defer surface=\(terminalSurface.id.uuidString.prefix(5)) " +
                    "reason=nonPositive size=\(String(format: "%.1fx%.1f", size.width, size.height)) " +
                    "inWindow=\(window != nil ? 1 : 0)"
                )
                lastSizeSkipSignature = signature
            }
#endif
            return false
        }
        pendingSurfaceSize = size
        if let deferralReason = activeSurfaceResizeDeferralReason() {
            scheduleDeferredSurfaceSizeRetryIfNeeded()
#if DEBUG
            let signature = "\(deferralReason)-\(Int(size.width.rounded()))x\(Int(size.height.rounded()))"
            if lastSizeSkipSignature != signature {
                dlog(
                    "surface.size.defer surface=\(terminalSurface.id.uuidString.prefix(5)) reason=\(deferralReason) " +
                    "size=\(String(format: "%.1fx%.1f", size.width, size.height)) " +
                    "inWindow=\(window != nil ? 1 : 0)"
                )
                lastSizeSkipSignature = signature
            }
#endif
            return false
        }

        guard let window else {
#if DEBUG
            let signature = "noWindow-\(Int(size.width))x\(Int(size.height))"
            if lastSizeSkipSignature != signature {
                dlog(
                    "surface.size.defer surface=\(terminalSurface.id.uuidString.prefix(5)) reason=noWindow " +
                    "size=\(String(format: "%.1fx%.1f", size.width, size.height))"
                )
                lastSizeSkipSignature = signature
            }
#endif
            return false
        }

        // First principles: derive pixel size from AppKit's backing conversion for the current
        // window/screen. Avoid updating Ghostty while detached from a window.
        let backingSize = convertToBacking(NSRect(origin: .zero, size: size)).size
        guard backingSize.width > 0, backingSize.height > 0 else {
#if DEBUG
            let signature = "zeroBacking-\(Int(backingSize.width))x\(Int(backingSize.height))"
            if lastSizeSkipSignature != signature {
                dlog(
                    "surface.size.defer surface=\(terminalSurface.id.uuidString.prefix(5)) reason=zeroBacking " +
                    "size=\(String(format: "%.1fx%.1f", size.width, size.height)) " +
                    "backing=\(String(format: "%.1fx%.1f", backingSize.width, backingSize.height))"
                )
                lastSizeSkipSignature = signature
            }
#endif
            return false
        }
#if DEBUG
        if lastSizeSkipSignature != nil {
            dlog(
                "surface.size.resume surface=\(terminalSurface.id.uuidString.prefix(5)) " +
                "size=\(String(format: "%.1fx%.1f", size.width, size.height)) " +
                "backing=\(String(format: "%.1fx%.1f", backingSize.width, backingSize.height))"
            )
            lastSizeSkipSignature = nil
        }
#endif
        let xScale = backingSize.width / size.width
        let yScale = backingSize.height / size.height
        let layerScale = max(1.0, window.backingScaleFactor)
        let drawablePixelSize = CGSize(
            width: floor(max(0, backingSize.width)),
            height: floor(max(0, backingSize.height))
        )
        var didChange = false

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let layer, !nearlyEqual(layer.contentsScale, layerScale) {
            didChange = true
        }
        layer?.contentsScale = layerScale
        layer?.masksToBounds = true
        if let metalLayer = layer as? CAMetalLayer {
            if drawablePixelSize != lastDrawableSize || metalLayer.drawableSize != drawablePixelSize {
                if metalLayer.drawableSize != drawablePixelSize {
                    didChange = true
                }
                if metalLayer.drawableSize != drawablePixelSize {
                    metalLayer.drawableSize = drawablePixelSize
                }
                lastDrawableSize = drawablePixelSize
            }
        }
        CATransaction.commit()

        let surfaceSizeChanged = terminalSurface.updateSize(
            width: size.width,
            height: size.height,
            xScale: xScale,
            yScale: yScale,
            layerScale: layerScale,
            backingSize: backingSize
        )
        return didChange || surfaceSizeChanged
    }

    @discardableResult
    func pushTargetSurfaceSize(_ size: CGSize) -> Bool {
        updateSurfaceSize(size: size)
    }

#if DEBUG
    func debugPendingSurfaceSize() -> CGSize? {
        pendingSurfaceSize
    }
#endif

    /// Force a full size reconciliation for the current bounds.
    /// Keep the drawable-size cache intact so redundant refresh paths do not
    /// reallocate Metal drawables when the pixel size is unchanged.
    @discardableResult
    func forceRefreshSurface() -> Bool {
        updateSurfaceSize()
    }

    private func nearlyEqual(_ lhs: CGFloat, _ rhs: CGFloat, epsilon: CGFloat = 0.0001) -> Bool {
        abs(lhs - rhs) <= epsilon
    }

    func expectedPixelSize(for pointsSize: CGSize) -> CGSize {
        let backing = convertToBacking(NSRect(origin: .zero, size: pointsSize)).size
        if backing.width > 0, backing.height > 0 {
            return backing
        }
        let scale = max(1.0, window?.backingScaleFactor ?? layer?.contentsScale ?? 1.0)
        return CGSize(width: pointsSize.width * scale, height: pointsSize.height * scale)
    }

    // Convenience accessor for the ghostty surface
    var surface: ghostty_surface_t? {
        terminalSurface?.surface
    }

    func applySurfaceColorScheme(force: Bool = false) {
        guard let surface else { return }
        let bestMatch = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        let scheme: ghostty_color_scheme_e = bestMatch == .darkAqua
            ? GHOSTTY_COLOR_SCHEME_DARK
            : GHOSTTY_COLOR_SCHEME_LIGHT
        if !force, appliedColorScheme == scheme {
            if GhosttyApp.shared.backgroundLogEnabled {
                let schemeLabel = scheme == GHOSTTY_COLOR_SCHEME_DARK ? "dark" : "light"
                GhosttyApp.shared.logBackground(
                    "surface color scheme tab=\(tabId?.uuidString ?? "nil") surface=\(terminalSurface?.id.uuidString ?? "nil") bestMatch=\(bestMatch?.rawValue ?? "nil") scheme=\(schemeLabel) force=\(force) applied=false"
                )
            }
            return
        }
        ghostty_surface_set_color_scheme(surface, scheme)
        appliedColorScheme = scheme
        if GhosttyApp.shared.backgroundLogEnabled {
            let schemeLabel = scheme == GHOSTTY_COLOR_SCHEME_DARK ? "dark" : "light"
            GhosttyApp.shared.logBackground(
                "surface color scheme tab=\(tabId?.uuidString ?? "nil") surface=\(terminalSurface?.id.uuidString ?? "nil") bestMatch=\(bestMatch?.rawValue ?? "nil") scheme=\(schemeLabel) force=\(force) applied=true"
            )
        }
    }



    func withExternalCommittedText<T>(_ body: () -> T) -> T {
        externalCommittedTextDepth += 1
        defer { externalCommittedTextDepth -= 1 }
        return body()
    }

    // For NSTextInputClient - accumulates text during key events
    var keyTextAccumulator: [String]? = nil
    var markedText = NSMutableAttributedString()
    var lastPerformKeyEvent: TimeInterval?
    var externalCommittedTextDepth = 0
    struct SelectionSnapshot {
        let range: NSRange
        let string: String
        let topLeft: CGPoint
    }

#if DEBUG
    // Test-only accessors for keyTextAccumulator to verify CJK IME composition behavior.
    func setKeyTextAccumulatorForTesting(_ value: [String]?) {
        keyTextAccumulator = value
    }
    var keyTextAccumulatorForTesting: [String]? {
        keyTextAccumulator
    }
    func shouldSuppressShiftSpaceFallbackTextForTesting(event: NSEvent, markedTextBefore: Bool) -> Bool {
        shouldSuppressShiftSpaceFallbackText(event: event, markedTextBefore: markedTextBefore)
    }

    // Test-only IME point override so firstRect behavior can be regression tested.
    // private(set): read from the NSTextInputClient conformance in
    // GhosttyTerminalView+IME.swift (Nuclear Review #97 split), written only here.
    private(set) var imePointOverrideForTesting: (x: Double, y: Double, width: Double, height: Double)?

    func setIMEPointForTesting(x: Double, y: Double, width: Double, height: Double) {
        imePointOverrideForTesting = (x, y, width, height)
    }

    func clearIMEPointForTesting() {
        imePointOverrideForTesting = nil
    }
#endif



    func shouldSuppressCommandPathHover(for flags: NSEvent.ModifierFlags) -> Bool {
        guard flags.contains(.command), let surface else { return false }
        return ghostty_surface_has_selection(surface)
    }

    func hoverModsFromFlags(
        _ flags: NSEvent.ModifierFlags,
        suppressCommandPathHover: Bool
    ) -> ghostty_input_mods_e {
        let effectiveFlags = suppressCommandPathHover ? flags.subtracting(.command) : flags
#if DEBUG
        if suppressCommandPathHover, flags.contains(.command) {
            _ = ProgramaUITestCapture.mutateJSONObjectIfConfigured(
                envKey: "PROGRAMA_UI_TEST_CMD_HOVER_DIAGNOSTICS_PATH"
            ) { payload in
                payload["suppressed_command_hover_count"] = (payload["suppressed_command_hover_count"] as? Int ?? 0) + 1
            }
        }
#endif
        return modsFromFlags(effectiveFlags)
    }

    func modsFromEvent(_ event: NSEvent) -> ghostty_input_mods_e {
        modsFromFlags(event.modifierFlags)
    }

    func modsFromFlags(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        return ghostty_input_mods_e(rawValue: mods)
    }

    /// Consumed mods are modifiers that were used for text translation.
    /// Control and Command never contribute to text translation, so they
    /// should be excluded from consumed_mods.
    func consumedModsFromFlags(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods = GHOSTTY_MODS_NONE.rawValue
        // Only include Shift and Option as potentially consumed
        // Control and Command are never consumed for text translation
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        return ghostty_input_mods_e(rawValue: mods)
    }



    deinit {
        // Surface lifecycle is managed by TerminalSurface, not the view
#if DEBUG
        dlog(
            "surface.view.deinit view=\(Unmanaged.passUnretained(self).toOpaque()) " +
            "surface=\(terminalSurface?.id.uuidString.prefix(5) ?? "nil") " +
            "inWindow=\(window != nil ? 1 : 0) hasSuperview=\(superview != nil ? 1 : 0)"
        )
#endif
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        if let windowObserver {
            NotificationCenter.default.removeObserver(windowObserver)
        }
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        terminalSurface = nil
    }


    private func windowDidChangeScreen(_ notification: Notification) {
        guard let window else { return }
        guard let object = notification.object as? NSWindow, window == object else { return }
        guard let screen = window.screen else { return }
        guard let surface = terminalSurface?.surface else { return }

        if let displayID = screen.displayID,
           displayID != 0 {
            ghostty_surface_set_display_id(surface, displayID)
        }

        DispatchQueue.main.async { [weak self] in
            self?.viewDidChangeBackingProperties()
        }
    }

}

extension NSScreen {
    var displayID: UInt32? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        if let v = deviceDescription[key] as? UInt32 { return v }
        if let v = deviceDescription[key] as? Int { return UInt32(v) }
        if let v = deviceDescription[key] as? NSNumber { return v.uint32Value }
        return nil
    }
}
