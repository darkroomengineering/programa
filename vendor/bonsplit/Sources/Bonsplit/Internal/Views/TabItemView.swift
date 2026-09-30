import SwiftUI
import AppKit

private enum TabControlShortcutHintDebugSettings {
    static let xKey = "shortcutHintPaneTabXOffset"
    static let yKey = "shortcutHintPaneTabYOffset"
    static let alwaysShowKey = "shortcutHintAlwaysShow"
    static let defaultX = 0.0
    static let defaultY = 0.0
    static let defaultAlwaysShow = false
    static let range: ClosedRange<Double> = -20...20

    static func clamped(_ value: Double) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

enum TabItemStyling {
    static func iconSaturation(hasRasterIcon: Bool, tabSaturation: Double) -> Double {
        hasRasterIcon ? 1.0 : tabSaturation
    }

    static func shouldShowHoverBackground(isHovered: Bool, isSelected: Bool) -> Bool {
        isHovered && !isSelected
    }

    static func resolvedFaviconImage(existing: NSImage?, incomingData: Data?) -> NSImage? {
        guard let incomingData else { return nil }
        if let decoded = NSImage(data: incomingData) {
            // Favicon bitmaps must never be treated as template/tintable symbols.
            decoded.isTemplate = false
            return decoded
        }
        return existing
    }

    /// Parses a "#RRGGBB" hex string into a Color. Bonsplit is host-app-agnostic, so it
    /// cannot reuse the app's own NSColor(hex:) extension.
    static func color(fromHex hex: String) -> Color? {
        var body = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("#") { body.removeFirst() }
        guard body.count == 6, let value = UInt64(body, radix: 16) else { return nil }
        let r = Double((value >> 16) & 0xFF) / 255.0
        let g = Double((value >> 8) & 0xFF) / 255.0
        let b = Double(value & 0xFF) / 255.0
        return Color(red: r, green: g, blue: b)
    }
}

/// Individual tab view with icon, title, close button, and dirty indicator
struct TabItemView: View {
    let tab: TabItem
    let isSelected: Bool
    let showsZoomIndicator: Bool
    let appearance: BonsplitConfiguration.Appearance
    let saturation: Double
    let controlShortcutDigit: Int?
    let showsControlShortcutHint: Bool
    let shortcutModifierSymbol: String
    let contextMenuState: TabContextMenuState
    let onSelect: () -> Void
    let onClose: () -> Void
    let onZoomToggle: () -> Void
    let onContextAction: (TabContextAction) -> Void
    let onApplyTabColor: (String) -> Void

    @State private var isHovered = false
    @State private var isCloseHovered = false
    @State private var isZoomHovered = false
    @State private var showGlobeFallback = true
    @State private var globeFallbackWorkItem: DispatchWorkItem?
    @State private var lastIsLoadingObserved = false
    @State private var lastLoadingStoppedAt: Date?
    @State private var renderedFaviconData: Data?
    @State private var renderedFaviconImage: NSImage?
    @AppStorage(TabControlShortcutHintDebugSettings.xKey) private var controlShortcutHintXOffset = TabControlShortcutHintDebugSettings.defaultX
    @AppStorage(TabControlShortcutHintDebugSettings.yKey) private var controlShortcutHintYOffset = TabControlShortcutHintDebugSettings.defaultY
    @AppStorage(TabControlShortcutHintDebugSettings.alwaysShowKey) private var alwaysShowShortcutHints = TabControlShortcutHintDebugSettings.defaultAlwaysShow

    private var usesNativeOverlayGlass: Bool {
        appearance.overlayLiquidGlassEnabled && TabBarGlassStyling.isAvailable
    }

    @ViewBuilder
    var body: some View {
        tabContent
    }

    private var tabContent: some View {
        HStack(spacing: 0) {
            // Icon + title block uses the standard spacing, but keep the close affordance tight.
            HStack(spacing: TabBarMetrics.contentSpacing) {
                let iconSlotSize = TabBarMetrics.iconSize
                let iconTint = isSelected
                    ? TabBarColors.activeText(for: appearance)
                    : TabBarColors.inactiveText(for: appearance)
                let faviconImage = renderedFaviconImage ?? tab.iconImageData.flatMap { NSImage(data: $0) }

                Group {
                    if tab.isLoading {
                        // Slightly smaller than the icon slot so it reads cleaner at tab scale.
                        TabLoadingSpinner(size: iconSlotSize * 0.86, color: iconTint)
                    } else if let image = faviconImage {
                        FaviconIconView(image: image)
                            .frame(width: iconSlotSize, height: iconSlotSize, alignment: .center)
                            .clipped()
                    } else if let iconName = tab.icon {
                        if iconName == "globe", !showGlobeFallback {
                            // Avoid a distracting "globe -> favicon" flash: show a neutral placeholder
                            // briefly while the favicon fetch finishes. If no favicon arrives, we
                            // reveal the globe after a short delay.
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(iconTint.opacity(0.25), lineWidth: 1)
                        } else {
                            Image(systemName: iconName)
                                .font(.system(size: glyphSize(for: iconName)))
                                .foregroundStyle(iconTint)
                        }
                    }
                }
                // Keep downloaded favicon bitmaps in full color even for inactive tab bars.
                .saturation(TabItemStyling.iconSaturation(hasRasterIcon: faviconImage != nil, tabSaturation: saturation))
                .transaction { tx in
                    // Prevent incidental parent animations from briefly fading icon content.
                    tx.animation = nil
                }
                .frame(width: iconSlotSize, height: iconSlotSize, alignment: .center)
                .onAppear {
                    updateRenderedFaviconImage()
                    updateGlobeFallback()
                }
                .onDisappear {
                    globeFallbackWorkItem?.cancel()
                    globeFallbackWorkItem = nil
                }
                .onChange(of: tab.isLoading) { _ in updateGlobeFallback() }
                .onChange(of: tab.iconImageData) { _ in
                    updateRenderedFaviconImage()
                    updateGlobeFallback()
                }
                .onChange(of: tab.icon) { _ in updateGlobeFallback() }

                Text(tab.title)
                    .font(.system(size: TabBarMetrics.titleFontSize))
                    .lineLimit(1)
                    .foregroundStyle(
                        isSelected
                            ? TabBarColors.activeText(for: appearance)
                            : TabBarColors.inactiveText(for: appearance)
                    )
                    .saturation(saturation)

                if showsZoomIndicator {
                    Button {
                        onZoomToggle()
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: max(8, TabBarMetrics.titleFontSize - 2), weight: .semibold))
                            .foregroundStyle(
                                isZoomHovered
                                    ? TabBarColors.activeText(for: appearance)
                                    : TabBarColors.inactiveText(for: appearance)
                            )
                            .frame(width: TabBarMetrics.closeButtonSize, height: TabBarMetrics.closeButtonSize)
                            .background(
                                Circle()
                                    .fill(
                                        isZoomHovered
                                            ? TabBarColors.hoveredTabBackground(for: appearance)
                                            : .clear
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        isZoomHovered = hovering
                    }
                    .saturation(saturation)
                    .accessibilityLabel("Exit zoom")
                }
            }

            Spacer(minLength: 0)

            // Close button / dirty indicator / shortcut hint share the same trailing slot.
            trailingAccessory
        }
        .padding(.horizontal, TabBarMetrics.tabHorizontalPadding)
        .offset(y: isSelected ? 0.5 : 0)
        .frame(
            minWidth: TabBarMetrics.tabMinWidth,
            maxWidth: TabBarMetrics.tabMaxWidth,
            minHeight: TabBarMetrics.tabHeight,
            maxHeight: TabBarMetrics.tabHeight
        )
        .padding(.bottom, isSelected ? 1 : 0)
        .background(tabBackground.saturation(saturation))
        .animation(.easeInOut(duration: 0.14), value: showsShortcutHint)
        .contentShape(Rectangle())
        // Middle click to close (macOS convention).
        // Uses an AppKit event monitor so it doesn't interfere with left click selection or drag/reorder.
        .background(MiddleClickMonitorView(onMiddleClick: {
            guard !tab.isPinned else { return }
            onClose()
        }))
        .onTapGesture {
            onSelect()
        }
        .onHover { hovering in
            // Keep icon rendering stable while hovering; only accessory/background elements animate.
            isHovered = hovering
        }
        // Right-click / ctrl-click context menu, built natively with NSMenu at click time.
        // A SwiftUI `.contextMenu` here gets closed by macOS the instant this view re-renders
        // while the menu is open (constant re-eval from closure props, hover state changes when
        // the pointer crosses onto the open menu, etc.) -- AppKit's own tracking loop is immune
        // to that since it owns the run loop for the popup, not SwiftUI's diffing. It sits in an
        // overlay so normal hit-testing reaches it; that skips clipped and non-interactive tabs.
        .overlay(TabContextMenuHostView(
            tab: tab,
            contextMenuState: contextMenuState,
            onContextAction: onContextAction,
            onApplyTabColor: onApplyTabColor
        ))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tab.title)
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func glyphSize(for iconName: String) -> CGFloat {
        // `terminal.fill` reads visually heavier than most symbols at the same point size.
        // Hardcode sizes to avoid cross-glyph layout shifts.
        if iconName == "terminal.fill" || iconName == "terminal" || iconName == "globe" {
            return max(10, TabBarMetrics.iconSize - 2.5)
        }
        return TabBarMetrics.iconSize
    }

    private var shortcutHintLabel: String? {
        guard let controlShortcutDigit else { return nil }
        return "\(shortcutModifierSymbol)\(controlShortcutDigit)"
    }

    private var showsShortcutHint: Bool {
        (showsControlShortcutHint || alwaysShowShortcutHints) && shortcutHintLabel != nil
    }

    private var shortcutHintSlotWidth: CGFloat {
        guard let label = shortcutHintLabel else {
            return TabBarMetrics.closeButtonSize
        }
        let positiveDebugInset = max(0, CGFloat(TabControlShortcutHintDebugSettings.clamped(controlShortcutHintXOffset))) + 2
        return max(TabBarMetrics.closeButtonSize, shortcutHintWidth(for: label) + positiveDebugInset)
    }

    private func shortcutHintWidth(for label: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: max(8, TabBarMetrics.titleFontSize - 2), weight: .semibold)
        let textWidth = (label as NSString).size(withAttributes: [.font: font]).width
        return ceil(textWidth) + 8
    }

    @ViewBuilder
    private func shortcutHintPill(label: String) -> some View {
        let content = Text(label)
            .font(.system(size: max(8, TabBarMetrics.titleFontSize - 2), weight: .semibold, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(
                isSelected
                    ? TabBarColors.activeText(for: appearance)
                    : TabBarColors.inactiveText(for: appearance)
            )
            .padding(.horizontal, 4)
            .padding(.vertical, 1)

        if usesNativeOverlayGlass {
            TabPillGlassHost(
                content: content,
                tintColor: nil,
                cornerRadius: 100
            )
        } else {
            content
                .background(
                    Capsule(style: .continuous)
                        .fill(.regularMaterial)
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(Color.white.opacity(0.30), lineWidth: 0.8)
                        )
                        .shadow(color: Color.black.opacity(0.22), radius: 2, x: 0, y: 1)
                )
        }
    }

    @ViewBuilder
    private var trailingAccessory: some View {
        ZStack(alignment: .center) {
            if let shortcutHintLabel {
                shortcutHintPill(label: shortcutHintLabel)
                    .offset(
                        x: TabControlShortcutHintDebugSettings.clamped(controlShortcutHintXOffset),
                        y: TabControlShortcutHintDebugSettings.clamped(controlShortcutHintYOffset)
                    )
                    .opacity(showsShortcutHint ? 1 : 0)
                    .allowsHitTesting(false)
            }

            closeOrDirtyIndicator
                .opacity(showsShortcutHint ? 0 : 1)
                .allowsHitTesting(!showsShortcutHint)
        }
        .frame(
            minWidth: shortcutHintSlotWidth,
            minHeight: TabBarMetrics.closeButtonSize,
            alignment: .center
        )
        .animation(.easeInOut(duration: 0.14), value: showsShortcutHint)
    }

    private func updateGlobeFallback() {
        // Track load transitions so we can avoid an "empty placeholder -> globe" flash on brand-new tabs.
        if lastIsLoadingObserved && !tab.isLoading {
            lastLoadingStoppedAt = Date()
        }
        lastIsLoadingObserved = tab.isLoading

        globeFallbackWorkItem?.cancel()
        globeFallbackWorkItem = nil

        // Only delay the globe fallback right after a navigation completes, when a favicon is likely to
        // arrive soon. Otherwise (e.g. a brand-new tab), show the globe immediately.
        let recentlyStoppedLoading: Bool = {
            guard let t = lastLoadingStoppedAt else { return false }
            return Date().timeIntervalSince(t) < 1.5
        }()
        let shouldDelayGlobe = (tab.icon == "globe") && (tab.iconImageData == nil) && !tab.isLoading && recentlyStoppedLoading
        if !shouldDelayGlobe {
            showGlobeFallback = true
            return
        }

        showGlobeFallback = false
        let work = DispatchWorkItem {
            showGlobeFallback = true
        }
        globeFallbackWorkItem = work
        // Give favicon fetches a little longer before showing the globe fallback to reduce brief flashes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.90, execute: work)
    }

    private func updateRenderedFaviconImage() {
        guard renderedFaviconData != tab.iconImageData ||
                (renderedFaviconImage == nil && tab.iconImageData != nil) else { return }
        renderedFaviconData = tab.iconImageData
        renderedFaviconImage = TabItemStyling.resolvedFaviconImage(
            existing: renderedFaviconImage,
            incomingData: tab.iconImageData
        )
    }

    private var accessibilityValue: String {
        var parts: [String] = []
        if tab.isLoading { parts.append("Loading") }
        if tab.isPinned { parts.append("Pinned") }
        if tab.showsNotificationBadge { parts.append("Unread") }
        if tab.isDirty { parts.append("Modified") }
        if showsZoomIndicator { parts.append("Zoomed") }
        return parts.joined(separator: ", ")
    }

    // MARK: - Tab Background

    @ViewBuilder
    private var tabBackground: some View {
        ZStack(alignment: .top) {
            // Custom tab color tint (bottom-most layer, low-opacity wash across the whole tab).
            if let hex = tab.customColorHex, let tintColor = TabItemStyling.color(fromHex: hex) {
                Rectangle()
                    .fill(tintColor.opacity(0.2))
            }

            // Background fill (hover)
            if TabItemStyling.shouldShowHoverBackground(isHovered: isHovered, isSelected: isSelected) {
                Rectangle()
                    .fill(TabBarColors.hoveredTabBackground(for: appearance))
            } else {
                Color.clear
            }

            // Top accent indicator for selected tab
            if isSelected {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(height: TabBarMetrics.activeIndicatorHeight)
            }

            HStack {
                Spacer()
                Rectangle()
                    .fill(TabBarColors.separator(for: appearance))
                    .frame(width: 1)
            }
        }
    }

    // MARK: - Close Button / Dirty Indicator

    @ViewBuilder
    private var closeOrDirtyIndicator: some View {
        ZStack {
            // Dirty indicator (shown when dirty and not hovering, hidden for selected tab)
            if (!isSelected && !isHovered && !isCloseHovered) && (tab.isDirty || tab.showsNotificationBadge) {
                HStack(spacing: 2) {
                    if tab.showsNotificationBadge {
                        Circle()
                            .fill(TabBarColors.notificationBadge(for: appearance))
                            .frame(width: TabBarMetrics.notificationBadgeSize, height: TabBarMetrics.notificationBadgeSize)
                    }
                    if tab.isDirty {
                        Circle()
                            .fill(TabBarColors.dirtyIndicator(for: appearance))
                            .frame(width: TabBarMetrics.dirtyIndicatorSize, height: TabBarMetrics.dirtyIndicatorSize)
                            .saturation(saturation)
                    }
                }
            }

            if tab.isPinned {
                if isSelected || isHovered || isCloseHovered || (!tab.isDirty && !tab.showsNotificationBadge) {
                    Image(systemName: "pin.fill")
                        .font(.system(size: TabBarMetrics.closeIconSize, weight: .semibold))
                        .foregroundStyle(TabBarColors.inactiveText(for: appearance))
                        .frame(width: TabBarMetrics.closeButtonSize, height: TabBarMetrics.closeButtonSize)
                        .saturation(saturation)
                }
            } else if isSelected || isHovered || isCloseHovered {
                // Close button (always visible on active tab, shown on hover for others)
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: TabBarMetrics.closeIconSize, weight: .semibold))
                        .foregroundStyle(
                            isCloseHovered
                                ? TabBarColors.activeText(for: appearance)
                                : TabBarColors.inactiveText(for: appearance)
                        )
                        .frame(width: TabBarMetrics.closeButtonSize, height: TabBarMetrics.closeButtonSize)
                        .background(
                            Circle()
                                .fill(
                                    isCloseHovered
                                        ? TabBarColors.hoveredTabBackground(for: appearance)
                                        : .clear
                                )
                        )
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    isCloseHovered = hovering
                }
                .saturation(saturation)
            }
        }
        .frame(width: TabBarMetrics.closeButtonSize, height: TabBarMetrics.closeButtonSize)
        .animation(.easeInOut(duration: TabBarMetrics.hoverDuration), value: isHovered)
        .animation(.easeInOut(duration: TabBarMetrics.hoverDuration), value: isCloseHovered)
    }
}

private struct TabLoadingSpinner: View {
    let size: CGFloat
    let color: Color
    @State private var angle: Double = 0

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.20), lineWidth: ringWidth)
            Circle()
                .trim(from: 0.0, to: 0.28)
                .stroke(color, style: StrokeStyle(lineWidth: ringWidth, lineCap: .round))
                .rotationEffect(.degrees(angle))
        }
        .frame(width: size, height: size)
        .onAppear {
            // 0.9s per revolution; one repeating animation instead of a per-frame body.
            angle = 360
        }
        .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: angle)
    }

    private var ringWidth: CGFloat {
        max(1.6, size * 0.14)
    }
}

private struct FaviconIconView: NSViewRepresentable {
    let image: NSImage

    final class ContainerView: NSView {
        let imageView = NSImageView(frame: .zero)

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.masksToBounds = true
            imageView.imageScaling = .scaleProportionallyDown
            imageView.imageAlignment = .alignCenter
            imageView.animates = false
            imageView.contentTintColor = nil
            imageView.autoresizingMask = [.width, .height]
            addSubview(imageView)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override var intrinsicContentSize: NSSize {
            .zero
        }

        override func layout() {
            super.layout()
            imageView.frame = bounds.integral
        }
    }

    func makeNSView(context: Context) -> ContainerView {
        ContainerView(frame: .zero)
    }

    func updateNSView(_ nsView: ContainerView, context: Context) {
        image.isTemplate = false
        if nsView.imageView.image !== image {
            nsView.imageView.image = image
        }
        nsView.imageView.contentTintColor = nil
    }
}

private struct MiddleClickMonitorView: NSViewRepresentable {
    let onMiddleClick: () -> Void

    final class Coordinator {
        var onMiddleClick: (() -> Void)?
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
        context.coordinator.onMiddleClick = onMiddleClick

        // Monitor only middle clicks so we don't break drag/reorder or normal selection.
        let coordinator = context.coordinator
        coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseUp]) { [weak coordinator] event in
            guard event.buttonNumber == 2 else { return event }
            guard let coordinator, let v = coordinator.view, let w = v.window else { return event }
            guard event.window === w else { return event }

            let p = v.convert(event.locationInWindow, from: nil)
            guard v.bounds.contains(p) else { return event }

            coordinator.onMiddleClick?()
            return nil // swallow so it doesn't also select the tab
        }

        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.view = nsView
        context.coordinator.onMiddleClick = onMiddleClick
    }
}

/// Retains a single closure as an NSMenuItem target. `NSMenuItem.target` is weak, so each
/// item's target must be kept alive independently until the menu is dismissed.
private final class ClosureMenuItemTarget: NSObject {
    let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func invoke() {
        handler()
    }
}

/// Right-click / ctrl-click hook that builds and pops a native NSMenu at click time from the
/// tab's current context-menu state. AppKit owns the menu's tracking run loop, so SwiftUI
/// re-renders of the tab row (which happen constantly -- see the comment at the `.contextMenu`
/// replacement call site) can never close it out from under the user, unlike SwiftUI's own
/// `.contextMenu` modifier.
private struct TabContextMenuHostView: NSViewRepresentable {
    let tab: TabItem
    let contextMenuState: TabContextMenuState
    let onContextAction: (TabContextAction) -> Void
    let onApplyTabColor: (String) -> Void

    final class Coordinator {
        var tab: TabItem?
        var contextMenuState: TabContextMenuState?
        var onContextAction: ((TabContextAction) -> Void)?
        var onApplyTabColor: ((String) -> Void)?
        // Keeps this popup's NSMenuItem targets alive for the duration of the menu; replaced
        // (and the previous batch released) on every new popup.
        var retainedTargets: [ClosureMenuItemTarget] = []

        func popUpMenu(for event: NSEvent, in view: NSView) {
            guard let tab, let contextMenuState else { return }
            var targets: [ClosureMenuItemTarget] = []
            let menu = Self.buildMenu(
                tab: tab,
                state: contextMenuState,
                onContextAction: { [weak self] action in self?.onContextAction?(action) },
                onApplyTabColor: { [weak self] hex in self?.onApplyTabColor?(hex) },
                retaining: &targets
            )
            retainedTargets = targets
            NSMenu.popUpContextMenu(menu, with: event, for: view)
        }

        private static func addItem(
            to menu: NSMenu,
            title: String,
            action: TabContextAction,
            enabled: Bool,
            shortcut: KeyboardShortcut?,
            onContextAction: @escaping (TabContextAction) -> Void,
            retaining targets: inout [ClosureMenuItemTarget]
        ) {
            let target = ClosureMenuItemTarget { onContextAction(action) }
            targets.append(target)
            let item = NSMenuItem(title: title, action: #selector(ClosureMenuItemTarget.invoke), keyEquivalent: "")
            item.target = target
            item.isEnabled = enabled
            if let shortcut {
                item.keyEquivalent = String(shortcut.key.character)
                item.keyEquivalentModifierMask = nsModifierFlags(from: shortcut.modifiers)
            }
            menu.addItem(item)
        }

        private static func nsModifierFlags(from modifiers: EventModifiers) -> NSEvent.ModifierFlags {
            var flags: NSEvent.ModifierFlags = []
            if modifiers.contains(.command) { flags.insert(.command) }
            if modifiers.contains(.shift) { flags.insert(.shift) }
            if modifiers.contains(.option) { flags.insert(.option) }
            if modifiers.contains(.control) { flags.insert(.control) }
            if modifiers.contains(.capsLock) { flags.insert(.capsLock) }
            if modifiers.contains(.numericPad) { flags.insert(.numericPad) }
            // .function is reserved for system applications (macOS 12+ deprecation); menu
            // shortcuts never use it in practice, so it's intentionally left unmapped.
            return flags
        }

        private static func localized(_ key: String, defaultValue: String) -> String {
            Bundle.module.localizedString(forKey: key, value: defaultValue, table: nil)
        }

        private static func buildMenu(
            tab: TabItem,
            state: TabContextMenuState,
            onContextAction: @escaping (TabContextAction) -> Void,
            onApplyTabColor: @escaping (String) -> Void,
            retaining targets: inout [ClosureMenuItemTarget]
        ) -> NSMenu {
            let menu = NSMenu()
            menu.autoenablesItems = false

            func add(_ title: String, _ action: TabContextAction, enabled: Bool = true) {
                addItem(
                    to: menu,
                    title: title,
                    action: action,
                    enabled: enabled,
                    shortcut: state.shortcuts[action],
                    onContextAction: onContextAction,
                    retaining: &targets
                )
            }

            add("Rename Tab…", .rename)

            if state.hasCustomTitle {
                add("Remove Custom Tab Name", .clearName)
            }

            menu.addItem(.separator())

            add("Close Tabs to Left", .closeToLeft, enabled: state.canCloseToLeft)
            add("Close Tabs to Right", .closeToRight, enabled: state.canCloseToRight)
            add("Close Other Tabs", .closeOthers, enabled: state.canCloseOthers)
            add("Move Tab…", .move)

            if state.isTerminal {
                add(
                    localized("command.moveTabToLeftPane.title", defaultValue: "Move to Left Pane"),
                    .moveToLeftPane,
                    enabled: state.canMoveToLeftPane
                )
                add(
                    localized("command.moveTabToRightPane.title", defaultValue: "Move to Right Pane"),
                    .moveToRightPane,
                    enabled: state.canMoveToRightPane
                )
            }

            menu.addItem(.separator())

            add("New Terminal Tab to Right", .newTerminalToRight)
            add("New Browser Tab to Right", .newBrowserToRight)

            if state.isBrowser {
                menu.addItem(.separator())
                add("Reload Tab", .reload)
                add("Duplicate Tab", .duplicate)
            }

            menu.addItem(.separator())

            if state.hasSplits {
                add(state.isZoomed ? "Exit Zoom" : "Zoom Pane", .toggleZoom)
            }

            add(state.isPinned ? "Unpin Tab" : "Pin Tab", .togglePin)

            if state.isUnread {
                add("Mark Tab as Read", .markAsRead, enabled: state.canMarkAsRead)
            } else {
                add("Mark Tab as Unread", .markAsUnread, enabled: state.canMarkAsUnread)
            }

            menu.addItem(.separator())
            menu.addItem(buildTabColorSubmenu(
                state: state,
                onContextAction: onContextAction,
                onApplyTabColor: onApplyTabColor,
                retaining: &targets
            ))

            return menu
        }

        private static func buildTabColorSubmenu(
            state: TabContextMenuState,
            onContextAction: @escaping (TabContextAction) -> Void,
            onApplyTabColor: @escaping (String) -> Void,
            retaining targets: inout [ClosureMenuItemTarget]
        ) -> NSMenuItem {
            let submenuItem = NSMenuItem(
                title: localized("contextMenu.tabColor", defaultValue: "Tab Color"),
                action: nil,
                keyEquivalent: ""
            )
            let submenu = NSMenu()
            submenu.autoenablesItems = false

            if state.hasCustomColor {
                addItem(
                    to: submenu,
                    title: localized("contextMenu.clearColor", defaultValue: "Clear Color"),
                    action: .clearTabColor,
                    enabled: true,
                    shortcut: nil,
                    onContextAction: onContextAction,
                    retaining: &targets
                )
            }

            addItem(
                to: submenu,
                title: localized("contextMenu.chooseCustomColor", defaultValue: "Choose Custom Color…"),
                action: .chooseCustomTabColor,
                enabled: true,
                shortcut: nil,
                onContextAction: onContextAction,
                retaining: &targets
            )

            if !state.colorPalette.isEmpty {
                submenu.addItem(.separator())
            }

            for swatch in state.colorPalette {
                let target = ClosureMenuItemTarget { onApplyTabColor(swatch.hex) }
                targets.append(target)
                let item = NSMenuItem(title: swatch.name, action: #selector(ClosureMenuItemTarget.invoke), keyEquivalent: "")
                item.target = target
                item.isEnabled = true
                item.image = swatchImage(color: swatch.swatchColor)
                submenu.addItem(item)
            }

            submenuItem.submenu = submenu
            return submenuItem
        }

        private static func swatchImage(color: NSColor, diameter: CGFloat = 12) -> NSImage {
            NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) { rect in
                color.setFill()
                NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
                return true
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> TabContextMenuCaptureView {
        let view = TabContextMenuCaptureView()
        view.coordinator = context.coordinator
        context.coordinator.tab = tab
        context.coordinator.contextMenuState = contextMenuState
        context.coordinator.onContextAction = onContextAction
        context.coordinator.onApplyTabColor = onApplyTabColor
        return view
    }

    func updateNSView(_ nsView: TabContextMenuCaptureView, context: Context) {
        // Refresh on every render so a stale enabled/disabled state or pinned/unread flag
        // from a previous render can never be shown in a freshly popped menu.
        nsView.coordinator = context.coordinator
        context.coordinator.tab = tab
        context.coordinator.contextMenuState = contextMenuState
        context.coordinator.onContextAction = onContextAction
        context.coordinator.onApplyTabColor = onApplyTabColor
    }
}

/// Claims only right-mouse-down and ctrl-left-mouse-down in `hitTest`, so left-click
/// selection, middle-click close, hover, and drag/reorder hit-test through to the tab
/// underneath. Control-click arrives as a genuine `.leftMouseDown` with `.control` set,
/// so `hitTest` must recognize it too or the click falls through to plain selection.
private final class TabContextMenuCaptureView: NSView {
    weak var coordinator: TabContextMenuHostView.Coordinator?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent,
              let superview,
              bounds.contains(convert(point, from: superview)) else { return nil }
        if event.type == .rightMouseDown {
            return self
        }
        if event.type == .leftMouseDown, event.modifierFlags.contains(.control) {
            return self
        }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        guard event.modifierFlags.contains(.control) else {
            super.mouseDown(with: event)
            return
        }
        rightMouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let coordinator else {
            super.rightMouseDown(with: event)
            return
        }
        coordinator.popUpMenu(for: event, in: self)
    }
}
