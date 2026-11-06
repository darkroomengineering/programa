import AppKit
import Bonsplit
import Combine
import SwiftUI

final class NonDraggableHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { false }

    required init(rootView: Content) {
        super.init(rootView: rootView)
        // Titlebar accessory content must not observe safe-area changes: SwiftUI's
        // observation recurses through invalidateSafeAreaInsets on ambient display
        // events until AppKit's layout-loop guard kills the app (issue #307; same
        // fix as MainWindowHostingView, #308 — it does not cascade to sibling hosts).
        safeAreaRegions = []
    }

    @MainActor required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// macOS traffic lights are 12pt circles laid out on a 20pt pitch — an 8pt visual gap
/// between adjacent lights. The bare-glyph presets (macOS 14/15) derive their inter-icon
/// spacing from that same 8pt gap, so the row reads as one rhythm with the lights. Do not
/// "tidy" this into a rounder-looking magic number — 8 is the traffic-light gap.
private enum TitlebarControlsRhythm {
    static let trafficLightGap: CGFloat = 8

    /// Per-preset spacing as multiples of the traffic-light gap, so every preset derives
    /// from the same rule instead of its own magic number.
    enum ScaleFactor {
        static let classic: CGFloat = 1.0
        static let compact: CGFloat = 0.625
        static let roomy: CGFloat = 1.375
        static let pillGroup: CGFloat = 0.75
        static let softButtons: CGFloat = 0.75
    }

    static func spacing(_ scale: CGFloat) -> CGFloat {
        trafficLightGap * scale
    }
}

enum TitlebarControlsStyle: Int, CaseIterable, Identifiable {
    case classic
    case compact
    case roomy
    case pillGroup
    case softButtons

    var id: Int { rawValue }

    var menuTitle: String {
        switch self {
        case .classic:
            return "Classic"
        case .compact:
            return "Compact"
        case .roomy:
            return "Roomy"
        case .pillGroup:
            return "Pill Group"
        case .softButtons:
            return "Soft Buttons"
        }
    }

    var config: TitlebarControlsStyleConfig {
        switch self {
        case .classic:
            return TitlebarControlsStyleConfig(
                spacing: TitlebarControlsRhythm.spacing(TitlebarControlsRhythm.ScaleFactor.classic),
                iconSize: 15,
                buttonSize: 24,
                groupBackground: false,
                groupPadding: EdgeInsets(),
                buttonBackground: false,
                buttonCornerRadius: 8,
                hoverBackground: true
            )
        case .compact:
            return TitlebarControlsStyleConfig(
                spacing: TitlebarControlsRhythm.spacing(TitlebarControlsRhythm.ScaleFactor.compact),
                iconSize: 13,
                buttonSize: 20,
                groupBackground: false,
                groupPadding: EdgeInsets(),
                buttonBackground: false,
                buttonCornerRadius: 6,
                hoverBackground: true
            )
        case .roomy:
            return TitlebarControlsStyleConfig(
                spacing: TitlebarControlsRhythm.spacing(TitlebarControlsRhythm.ScaleFactor.roomy),
                iconSize: 16,
                buttonSize: 28,
                groupBackground: false,
                groupPadding: EdgeInsets(),
                buttonBackground: false,
                buttonCornerRadius: 10,
                hoverBackground: true
            )
        case .pillGroup:
            return TitlebarControlsStyleConfig(
                spacing: TitlebarControlsRhythm.spacing(TitlebarControlsRhythm.ScaleFactor.pillGroup),
                iconSize: 14,
                buttonSize: 24,
                groupBackground: false,
                groupPadding: EdgeInsets(top: 1, leading: 4, bottom: 1, trailing: 4),
                buttonBackground: false,
                buttonCornerRadius: 8,
                hoverBackground: true
            )
        case .softButtons:
            return TitlebarControlsStyleConfig(
                spacing: TitlebarControlsRhythm.spacing(TitlebarControlsRhythm.ScaleFactor.softButtons),
                iconSize: 15,
                buttonSize: 26,
                groupBackground: false,
                groupPadding: EdgeInsets(),
                buttonBackground: true,
                buttonCornerRadius: 8,
                hoverBackground: true
            )
        }
    }
}

/// Titlebar cluster geometry. On macOS 26+ it matches a stock NavigationSplitView
/// toolbar (measured on macOS 27.2): bell and "+" share one glass capsule, the
/// sidebar toggle is its own glass circle, both 37pt tall with a 7pt gap.
enum TitlebarControlsMetrics {
    static let glassHeight: CGFloat = 37
    static let glassGap: CGFloat = 7
    /// Gap between the toggle's glass edge and the sidebar's trailing edge.
    static let sidebarTrailingInset: CGFloat = 8

    static let glassConfig = TitlebarControlsStyleConfig(
        spacing: 0,
        iconSize: ChromeScale.toolbarIconSize,
        buttonSize: glassHeight,
        groupBackground: false,
        groupPadding: EdgeInsets(),
        buttonBackground: false,
        buttonCornerRadius: glassHeight / 2,
        hoverBackground: false,
        primaryGlyphAtRest: true
    )

    /// Gap between the collapsed-sidebar toolbar controls and the content after them.
    static let gapAfterToolbarControls: CGFloat = 12
}

/// Where a titlebar controls cluster sits; decides its outer insets.
enum TitlebarControlsPlacement: Equatable {
    /// Trailing edge of the sidebar header row.
    case sidebarHeader
    /// Leading edge of its host: past the traffic lights, or the window edge in fullscreen.
    case leading(inset: CGFloat)
}

struct TitlebarControlsStyleConfig {
    let spacing: CGFloat
    let iconSize: CGFloat
    let buttonSize: CGFloat
    let groupBackground: Bool
    let groupPadding: EdgeInsets
    let buttonBackground: Bool
    let buttonCornerRadius: CGFloat
    let hoverBackground: Bool
    /// Glass toolbar buttons draw full-strength glyphs at rest, like Finder and Mail.
    var primaryGlyphAtRest = false
}

final class TitlebarControlsViewModel: ObservableObject {
    weak var notificationsAnchorView: NSView?
}

extension Notification.Name {
    static let programaNotificationsPopoverVisibilityDidChange = Notification.Name("programa.notificationsPopoverVisibilityDidChange")
}

private enum NotificationsPopoverVisibilityUserInfoKey {
    static let isShown = "isShown"
}

private func postNotificationsPopoverVisibilityDidChange(isShown: Bool) {
    NotificationCenter.default.post(
        name: .programaNotificationsPopoverVisibilityDidChange,
        object: nil,
        userInfo: [NotificationsPopoverVisibilityUserInfoKey.isShown: isShown]
    )
}

struct NotificationsAnchorView: NSViewRepresentable {
    let onResolve: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = AnchorNSView()
        view.onLayout = { [weak view] in
            guard let view else { return }
            onResolve(view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

final class AnchorNSView: NSView {
    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }
}

struct ShortcutHintLanePlanner {
    static func assignLanes(for intervals: [ClosedRange<CGFloat>], minSpacing: CGFloat = 4) -> [Int] {
        guard !intervals.isEmpty else { return [] }

        var laneMaxX: [CGFloat] = []
        var lanes: [Int] = []
        lanes.reserveCapacity(intervals.count)

        for interval in intervals {
            var lane = 0
            while lane < laneMaxX.count {
                let requiredMinX = laneMaxX[lane] + minSpacing
                if interval.lowerBound >= requiredMinX {
                    break
                }
                lane += 1
            }

            if lane == laneMaxX.count {
                laneMaxX.append(interval.upperBound)
            } else {
                laneMaxX[lane] = max(laneMaxX[lane], interval.upperBound)
            }
            lanes.append(lane)
        }

        return lanes
    }
}

struct ShortcutHintHorizontalPlanner {
    static func assignRightEdges(for intervals: [ClosedRange<CGFloat>], minSpacing: CGFloat = 6) -> [CGFloat] {
        guard !intervals.isEmpty else { return [] }

        var assignedRightEdges = Array(repeating: CGFloat.zero, count: intervals.count)
        var nextMaxRight = CGFloat.greatestFiniteMagnitude

        for index in stride(from: intervals.count - 1, through: 0, by: -1) {
            let interval = intervals[index]
            let width = interval.upperBound - interval.lowerBound
            let preferredRightEdge = interval.upperBound
            let adjustedRightEdge = min(preferredRightEdge, nextMaxRight)
            assignedRightEdges[index] = adjustedRightEdge
            nextMaxRight = adjustedRightEdge - width - minSpacing
        }

        return assignedRightEdges
    }
}

/// SF Symbols at an identical point size are NOT optically equal — perceived size depends on
/// the glyph's bounding box and ink coverage, not just the numeric point size. These per-symbol
/// correction factors are judged by eye (not arbitrary tuning): `sidebar.left` is a wide,
/// filled-ish shape that reads larger than its point size, `plus` is a thin cross with little
/// ink that reads smaller, and `bell` / `bell.fill` sit in between as the reference. Unknown
/// symbols default to 1.0, i.e. unscaled.
private let titlebarIconOpticalScale: [String: CGFloat] = [
    "sidebar.left": 0.94,
    "bell": 1.0,
    "bell.fill": 1.0,
    "plus": 1.10,
]

/// Rendered glyph point size after applying the optical correction for `systemName`. Only the
/// glyph scales — the tappable hit target (`config.buttonSize`) is unaffected.
func titlebarIconRenderSize(for systemName: String, config: TitlebarControlsStyleConfig) -> CGFloat {
    config.iconSize * (titlebarIconOpticalScale[systemName] ?? 1.0)
}

func titlebarShortcutHintHeight(for config: TitlebarControlsStyleConfig) -> CGFloat {
    max(14, config.iconSize + 1)
}

func titlebarShortcutHintVerticalOffset(for config: TitlebarControlsStyleConfig) -> CGFloat {
    max(0, floor(config.buttonSize - titlebarShortcutHintHeight(for: config)))
}

struct TitlebarControlButton<Content: View>: View {
    let config: TitlebarControlsStyleConfig
    let action: () -> Void
    @ViewBuilder let content: (Bool) -> Content
    @State private var isHovering = false

    var body: some View {
        let baseButton = Button(action: action) {
            content(isHovering)
                .frame(width: config.buttonSize, height: config.buttonSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(TitlebarControlButtonStyle(config: config, isHovering: isHovering))
        .frame(width: config.buttonSize, height: config.buttonSize)
        .contentShape(Rectangle())

        if titlebarControlsShouldTrackButtonHover(config: config) {
            baseButton.onHover { isHovering = $0 }
        } else {
            baseButton
        }
    }
}

private struct TitlebarControlButtonStyle: ButtonStyle {
    let config: TitlebarControlsStyleConfig
    let isHovering: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                // Hover and press fills switch instantly, with no fade, like native toolbar buttons.
                RoundedRectangle(cornerRadius: WindowGlassEffect.controlCornerRadius, style: .continuous)
                    .fill(Color.primary.opacity(backgroundOpacity(isPressed: configuration.isPressed)))
            )
    }

    private func backgroundOpacity(isPressed: Bool) -> Double {
        guard config.hoverBackground else { return 0 }
        if isPressed { return 0.16 }
        if isHovering { return 0.08 }
        return 0
    }
}

struct TitlebarControlsView: View {
    @ObservedObject var notificationStore: TerminalNotificationStore
    @ObservedObject var viewModel: TitlebarControlsViewModel
    let onToggleSidebar: () -> Void
    let onToggleNotifications: () -> Void
    let onNewTab: () -> Void
    let visibilityMode: TitlebarControlsVisibilityMode
    var placement: TitlebarControlsPlacement = .leading(inset: 0)
    @AppStorage("titlebarControlsStyle") private var styleRawValue = TitlebarControlsStyle.classic.rawValue
    @AppStorage(ShortcutHintDebugSettings.titlebarHintXKey) private var titlebarShortcutHintXOffset = ShortcutHintDebugSettings.defaultTitlebarHintX
    @AppStorage(ShortcutHintDebugSettings.titlebarHintYKey) private var titlebarShortcutHintYOffset = ShortcutHintDebugSettings.defaultTitlebarHintY
    @AppStorage(ShortcutHintDebugSettings.alwaysShowHintsKey) private var alwaysShowShortcutHints = ShortcutHintDebugSettings.defaultAlwaysShowHints
    @State private var shortcutRefreshTick = 0
    @State private var isHoveringControls = false
    @State private var isNotificationsPopoverShown = false
    @StateObject private var modifierKeyMonitor = TitlebarShortcutHintModifierMonitor()
    private let titlebarHintRightSafetyShift: CGFloat = 10
    private let titlebarHintBaseXShift: CGFloat = -10

    /// Declared in display order: bell, "+", then the sidebar toggle last, as in a
    /// stock NavigationSplitView toolbar.
    private enum HintSlot: Int, CaseIterable {
        case showNotifications
        case newTab
        case toggleSidebar

        var action: KeyboardShortcutSettings.Action {
            switch self {
            case .toggleSidebar:
                return .toggleSidebar
            case .showNotifications:
                return .showNotifications
            case .newTab:
                return .newTab
            }
        }
    }

    private struct TitlebarHintLayoutItem: Identifiable {
        let action: KeyboardShortcutSettings.Action
        let shortcut: StoredShortcut
        let width: CGFloat
        let leftEdge: CGFloat

        var id: String { action.rawValue }
    }

    private var shouldShowTitlebarShortcutHints: Bool {
        alwaysShowShortcutHints || modifierKeyMonitor.isModifierPressed
    }

    private var shouldShowControls: Bool {
        if visibilityMode == .alwaysVisible {
            return true
        }
        return isHoveringControls || isNotificationsPopoverShown || shouldShowTitlebarShortcutHints
    }

    var body: some View {
        // Force the `.safeHelp(...)` tooltips to re-evaluate when shortcuts are changed in settings.
        // (The titlebar controls don't otherwise re-render on UserDefaults changes.)
        let _ = shortcutRefreshTick
        let style = TitlebarControlsStyle(rawValue: styleRawValue) ?? .classic
        let config = style.config
        laidOutControls(config: config)
            .opacity(shouldShowControls ? 1 : 0)
            .allowsHitTesting(shouldShowControls)
            .animation(.easeOut(duration: 0.14), value: shouldShowControls)
            .background(
                WindowAccessor { window in
                    modifierKeyMonitor.setHostWindow(window)
                }
                .frame(width: 0, height: 0)
            )
            .onHover { hovering in
                isHoveringControls = hovering
            }
            .onReceive(NotificationCenter.default.publisher(for: KeyboardShortcutSettings.didChangeNotification)) { _ in
                shortcutRefreshTick &+= 1
            }
            .onAppear {
                isNotificationsPopoverShown = AppDelegate.shared?.isNotificationsPopoverShown() ?? false
            }
            .onReceive(NotificationCenter.default.publisher(for: .programaNotificationsPopoverVisibilityDidChange)) { notification in
                isNotificationsPopoverShown = (notification.userInfo?[NotificationsPopoverVisibilityUserInfoKey.isShown] as? Bool) ?? false
            }
            .onAppear {
                modifierKeyMonitor.start()
            }
            .onDisappear {
                modifierKeyMonitor.stop()
            }
    }

    /// Glass: the toggle's glass edge sits `sidebarTrailingInset` from the sidebar edge.
    /// Bare glyphs: the last icon's center sits on the row icon column mirrored from the left.
    private func titlebarHintTrailingInset(for config: TitlebarControlsStyleConfig) -> CGFloat {
        if WindowGlassEffect.isAvailable {
            return TitlebarControlsMetrics.sidebarTrailingInset
        }
        return max(0, SidebarRowMetrics.trailingIconColumnCenter - config.buttonSize / 2)
    }

    /// Glass buttons are tall enough that a bottom-aligned hint would cover the glyph,
    /// so their hint straddles the glass's bottom edge instead.
    private func titlebarHintVerticalBaseOffset(for config: TitlebarControlsStyleConfig) -> CGFloat {
        if WindowGlassEffect.isAvailable {
            return config.buttonSize - titlebarShortcutHintHeight(for: config) / 2
        }
        return titlebarShortcutHintVerticalOffset(for: config)
    }

    @ViewBuilder
    private func laidOutControls(config: TitlebarControlsStyleConfig) -> some View {
        switch placement {
        case .sidebarHeader:
            controlGroups(config: config)
                .padding(.trailing, titlebarHintTrailingInset(for: config))
        case .leading(let inset):
            controlGroups(config: config)
                .padding(.leading, inset)
        }
    }

    @ViewBuilder
    private func controlGroups(config: TitlebarControlsStyleConfig) -> some View {
        if WindowGlassEffect.isAvailable {
            let glass = TitlebarControlsMetrics.glassConfig
            HStack(spacing: TitlebarControlsMetrics.glassGap) {
                controlsGroup(slots: [.showNotifications, .newTab], config: glass, glass: .capsule)
                controlsGroup(slots: [.toggleSidebar], config: glass, glass: .circle)
            }
        } else {
            controlsGroup(slots: HintSlot.allCases, config: config)
                .contentShape(Rectangle())
        }
    }

    @ViewBuilder
    private func controlsGroup(
        slots: [HintSlot],
        config: TitlebarControlsStyleConfig,
        glass: TitlebarGlassSurface.GlassShape? = nil
    ) -> some View {
        let hintLayoutItems = titlebarHintLayoutItems(slots: slots, config: config)
        let content = HStack(spacing: config.spacing) {
            ForEach(slots, id: \.self) { slot in
                controlButton(for: slot, config: config)
            }
        }

        let paddedContent = content.padding(config.groupPadding)

        if config.groupBackground {
            paddedContent
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1)
                )
                .overlay(alignment: .topLeading) {
                    titlebarShortcutHintOverlay(items: hintLayoutItems, config: config)
                }
        } else {
            paddedContent
                .modifier(TitlebarGlassSurface(shape: glass))
                .overlay(alignment: .topLeading) {
                    titlebarShortcutHintOverlay(items: hintLayoutItems, config: config)
                }
        }
    }

    @ViewBuilder
    private func controlButton(for slot: HintSlot, config: TitlebarControlsStyleConfig) -> some View {
        switch slot {
        case .toggleSidebar:
            TitlebarControlButton(config: config, action: {
                #if DEBUG
                dlog("titlebar.toggleSidebar")
                #endif
                onToggleSidebar()
            }) { isHovering in
                iconLabel(systemName: "sidebar.left", config: config, isHovering: isHovering)
            }
            .accessibilityIdentifier("titlebarControl.toggleSidebar")
            .accessibilityLabel(String(localized: "titlebar.sidebar.accessibilityLabel", defaultValue: "Toggle Sidebar"))
            .safeHelp(KeyboardShortcutSettings.Action.toggleSidebar.tooltip(String(localized: "titlebar.sidebar.tooltip", defaultValue: "Show or hide the sidebar")))
        case .showNotifications:
            TitlebarControlButton(config: config, action: {
                #if DEBUG
                dlog("titlebar.notifications")
                #endif
                onToggleNotifications()
            }) { isHovering in
                Group {
                    if notificationStore.unreadCount > 0 {
                        Image(systemName: "bell.fill")
                            .font(.system(size: titlebarIconRenderSize(for: "bell.fill", config: config), weight: .regular))
                            .foregroundColor(programaAccentColor())
                    } else {
                        iconLabel(systemName: "bell", config: config, isHovering: isHovering)
                    }
                }
                .frame(width: config.buttonSize, height: config.buttonSize)
            }
            .accessibilityIdentifier("titlebarControl.showNotifications")
            .background(NotificationsAnchorView { viewModel.notificationsAnchorView = $0 })
            .accessibilityLabel(String(localized: "titlebar.notifications.accessibilityLabel", defaultValue: "Notifications"))
            .safeHelp(KeyboardShortcutSettings.Action.showNotifications.tooltip(String(localized: "titlebar.notifications.tooltip", defaultValue: "Show notifications")))
        case .newTab:
            TitlebarControlButton(config: config, action: {
                #if DEBUG
                dlog("titlebar.newTab")
                #endif
                onNewTab()
            }) { isHovering in
                iconLabel(systemName: "plus", config: config, isHovering: isHovering)
            }
            .accessibilityIdentifier("titlebarControl.newTab")
            .accessibilityLabel(String(localized: "titlebar.newWorkspace.accessibilityLabel", defaultValue: "New Workspace"))
            .safeHelp(KeyboardShortcutSettings.Action.newTab.tooltip(String(localized: "titlebar.newWorkspace.tooltip", defaultValue: "New workspace")))
        }
    }

    private func titlebarHintLayoutItems(slots: [HintSlot], config: TitlebarControlsStyleConfig) -> [TitlebarHintLayoutItem] {
        let xOffset = CGFloat(ShortcutHintDebugSettings.clamped(titlebarShortcutHintXOffset))
        let intervals = titlebarHintIntervals(slots: slots, config: config, xOffset: xOffset)
        guard !intervals.isEmpty else { return [] }

        // Keep all titlebar hints on the same Y lane and resolve overlaps by shifting left.
        let minimumSpacing: CGFloat = 6
        let assignedRightEdges = ShortcutHintHorizontalPlanner.assignRightEdges(
            for: intervals.map { $0.interval },
            minSpacing: minimumSpacing
        )

        var items: [TitlebarHintLayoutItem] = []
        items.reserveCapacity(intervals.count)
        for (index, item) in intervals.enumerated() {
            let rightEdge = assignedRightEdges[index]
            items.append(
                TitlebarHintLayoutItem(
                    action: item.action,
                    shortcut: item.shortcut,
                    width: item.width,
                    leftEdge: rightEdge - item.width
                )
            )
        }
        return items
    }

    /// Hint x positions are relative to the group that hosts `slots`; each group carries
    /// its own overlay, so a button's position is its index within that group.
    private func titlebarHintIntervals(
        slots: [HintSlot],
        config: TitlebarControlsStyleConfig,
        xOffset: CGFloat
    ) -> [(action: KeyboardShortcutSettings.Action, shortcut: StoredShortcut, width: CGFloat, interval: ClosedRange<CGFloat>)] {
        guard shouldShowTitlebarShortcutHints else { return [] }

        return slots.enumerated().compactMap { position, slot in
            let shortcut = KeyboardShortcutSettings.shortcut(for: slot.action)
            guard shortcut.command else { return nil }

            let width = titlebarHintWidth(for: shortcut, config: config)
            // Glass: centered under the glyph. Bare glyphs: hugging the button's right edge.
            let anchor = WindowGlassEffect.isAvailable
                ? titlebarButtonRightEdge(at: position, config: config) - (config.buttonSize - width) / 2
                : titlebarButtonRightEdge(at: position, config: config)
                    + titlebarHintRightSafetyShift
                    + titlebarHintBaseXShift
            let rightEdge = config.groupPadding.leading + anchor + xOffset
            return (slot.action, shortcut, width, (rightEdge - width)...rightEdge)
        }
    }

    private func titlebarHintWidth(for shortcut: StoredShortcut, config: TitlebarControlsStyleConfig) -> CGFloat {
        let font = NSFont.systemFont(ofSize: max(8, config.iconSize - 4), weight: .semibold)
        let textWidth = (shortcut.displayString as NSString).size(withAttributes: [.font: font]).width
        return ceil(textWidth) + 12
    }

    private func titlebarButtonRightEdge(at position: Int, config: TitlebarControlsStyleConfig) -> CGFloat {
        let index = CGFloat(position)
        return (index + 1) * config.buttonSize + index * config.spacing
    }

    @ViewBuilder
    private func titlebarShortcutHintOverlay(
        items: [TitlebarHintLayoutItem],
        config: TitlebarControlsStyleConfig
    ) -> some View {
        let yOffset = config.groupPadding.top
            + titlebarHintVerticalBaseOffset(for: config)
            + ShortcutHintDebugSettings.clamped(titlebarShortcutHintYOffset)

        ZStack(alignment: .topLeading) {
            ForEach(items) { item in
                titlebarShortcutHintPill(action: item.action, shortcut: item.shortcut, config: config)
                    .frame(width: item.width, alignment: .leading)
                    .offset(x: item.leftEdge, y: yOffset)
            }
        }
        .animation(.easeOut(duration: 0.14), value: shouldShowTitlebarShortcutHints)
        .transition(.opacity)
        .allowsHitTesting(false)
    }

    private func titlebarShortcutHintPill(
        action: KeyboardShortcutSettings.Action,
        shortcut: StoredShortcut,
        config: TitlebarControlsStyleConfig
    ) -> some View {
        ShortcutHintPill {
            // The identifier lives on the text itself: on macOS 26 the pill content is hosted
            // in a separate glass view, so an identifier on the pill never reaches the label.
            Text(shortcut.displayString)
                .accessibilityIdentifier("titlebarShortcutHint.\(action.rawValue)")
                .font(.system(size: max(8, config.iconSize - 5), weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundColor(.primary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .frame(minHeight: titlebarShortcutHintHeight(for: config))
        }
    }

    @ViewBuilder
    private func iconLabel(systemName: String, config: TitlebarControlsStyleConfig, isHovering: Bool) -> some View {
        let icon = Image(systemName: systemName)
            .font(.system(size: titlebarIconRenderSize(for: systemName, config: config), weight: .regular))
            .foregroundColor(isHovering || config.primaryGlyphAtRest ? Color(nsColor: .labelColor) : Color(nsColor: .secondaryLabelColor))
            .frame(width: config.buttonSize, height: config.buttonSize)

        if config.buttonBackground {
            icon
                .background(
                    RoundedRectangle(cornerRadius: config.buttonCornerRadius)
                        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.7))
                )
        } else {
            icon
        }
    }
}

/// System glass behind one titlebar button group (macOS 26+); a no-op elsewhere.
struct TitlebarGlassSurface: ViewModifier {
    enum GlassShape {
        case capsule
        case circle
    }

    let shape: GlassShape?

    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *), let shape {
            switch shape {
            case .capsule:
                content.glassEffect(.regular.interactive(), in: Capsule())
            case .circle:
                content.glassEffect(.regular.interactive(), in: Circle())
            }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

struct HiddenTitlebarSidebarControlsView: View {
    @ObservedObject var notificationStore: TerminalNotificationStore
    @ObservedObject var sidebarState: SidebarState
    @StateObject private var viewModel = TitlebarControlsViewModel()

    private var hostHeight: CGFloat {
        WindowGlassEffect.isAvailable ? TitlebarControlsMetrics.glassHeight : 28
    }

    var body: some View {
        TitlebarControlsView(
            notificationStore: notificationStore,
            viewModel: viewModel,
            onToggleSidebar: { sidebarState.toggle() },
            onToggleNotifications: { [viewModel] in
                AppDelegate.shared?.toggleNotificationsPopover(
                    animated: true,
                    anchorView: viewModel.notificationsAnchorView
                )
            },
            onNewTab: { _ = AppDelegate.shared?.tabManager?.addTab() },
            visibilityMode: .alwaysVisible,
            placement: .sidebarHeader
        )
        .frame(maxWidth: .infinity, alignment: .trailing)
        .frame(height: hostHeight)
    }
}

enum TitlebarControlsVisibilityMode {
    case alwaysVisible
    case onHover
}

@MainActor
private final class TitlebarShortcutHintModifierMonitor: ObservableObject {
    @Published private(set) var isModifierPressed = false

    private weak var hostWindow: NSWindow?
    private var hostWindowDidBecomeKeyObserver: NSObjectProtocol?
    private var hostWindowDidResignKeyObserver: NSObjectProtocol?
    private var flagsMonitor: Any?
    private var keyDownMonitor: Any?
    private var appResignObserver: NSObjectProtocol?
    private var pendingShowWorkItem: DispatchWorkItem?

    func setHostWindow(_ window: NSWindow?) {
        guard hostWindow !== window else { return }
        removeHostWindowObservers()
        hostWindow = window
        guard let window else {
            cancelPendingHintShow(resetVisible: true)
            return
        }

        hostWindowDidBecomeKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.update(from: NSEvent.modifierFlags, eventWindow: nil)
            }
        }

        hostWindowDidResignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.cancelPendingHintShow(resetVisible: true)
            }
        }

        update(from: NSEvent.modifierFlags, eventWindow: nil)
    }

    func start() {
        guard flagsMonitor == nil else {
            update(from: NSEvent.modifierFlags, eventWindow: nil)
            return
        }

        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.update(from: event.modifierFlags, eventWindow: event.window)
            return event
        }

        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyDown(event)
            return event
        }

        appResignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.cancelPendingHintShow(resetVisible: true)
            }
        }

        update(from: NSEvent.modifierFlags, eventWindow: nil)
    }

    func stop() {
        if let flagsMonitor {
            NSEvent.removeMonitor(flagsMonitor)
            self.flagsMonitor = nil
        }
        if let keyDownMonitor {
            NSEvent.removeMonitor(keyDownMonitor)
            self.keyDownMonitor = nil
        }
        if let appResignObserver {
            NotificationCenter.default.removeObserver(appResignObserver)
            self.appResignObserver = nil
        }
        removeHostWindowObservers()
        cancelPendingHintShow(resetVisible: true)
    }

    private func handleKeyDown(_ event: NSEvent) {
        guard isCurrentWindow(eventWindow: event.window) else { return }
        cancelPendingHintShow(resetVisible: true)
    }

    private func isCurrentWindow(eventWindow: NSWindow?) -> Bool {
        ShortcutHintModifierPolicy.isCurrentWindow(
            hostWindowNumber: hostWindow?.windowNumber,
            hostWindowIsKey: hostWindow?.isKeyWindow ?? false,
            eventWindowNumber: eventWindow?.windowNumber,
            keyWindowNumber: NSApp.keyWindow?.windowNumber
        )
    }

    private func update(from modifierFlags: NSEvent.ModifierFlags, eventWindow: NSWindow?) {
        guard ShortcutHintModifierPolicy.shouldShowHints(
            for: modifierFlags,
            hostWindowNumber: hostWindow?.windowNumber,
            hostWindowIsKey: hostWindow?.isKeyWindow ?? false,
            eventWindowNumber: eventWindow?.windowNumber,
            keyWindowNumber: NSApp.keyWindow?.windowNumber
        ) else {
            cancelPendingHintShow(resetVisible: true)
            return
        }

        queueHintShow()
    }

    private func queueHintShow() {
        guard !isModifierPressed else { return }
        guard pendingShowWorkItem == nil else { return }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingShowWorkItem = nil
            guard ShortcutHintModifierPolicy.shouldShowHints(
                for: NSEvent.modifierFlags,
                hostWindowNumber: self.hostWindow?.windowNumber,
                hostWindowIsKey: self.hostWindow?.isKeyWindow ?? false,
                eventWindowNumber: nil,
                keyWindowNumber: NSApp.keyWindow?.windowNumber
            ) else { return }
            self.isModifierPressed = true
        }

        pendingShowWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + ShortcutHintModifierPolicy.intentionalHoldDelay, execute: workItem)
    }

    private func cancelPendingHintShow(resetVisible: Bool) {
        pendingShowWorkItem?.cancel()
        pendingShowWorkItem = nil
        if resetVisible {
            isModifierPressed = false
        }
    }

    private func removeHostWindowObservers() {
        if let hostWindowDidBecomeKeyObserver {
            NotificationCenter.default.removeObserver(hostWindowDidBecomeKeyObserver)
            self.hostWindowDidBecomeKeyObserver = nil
        }
        if let hostWindowDidResignKeyObserver {
            NotificationCenter.default.removeObserver(hostWindowDidResignKeyObserver)
            self.hostWindowDidResignKeyObserver = nil
        }
    }
}

struct TitlebarControlsLayoutSnapshot: Equatable {
    let contentSize: NSSize
    let containerHeight: CGFloat
    let yOffset: CGFloat
}

func titlebarControlsShouldTrackButtonHover(config: TitlebarControlsStyleConfig) -> Bool {
    config.hoverBackground
}

func titlebarControlsShouldScheduleForViewSizeChange(
    previous: NSSize,
    current: NSSize,
    tolerance: CGFloat = 0.5
) -> Bool {
    guard current.width > 0, current.height > 0 else { return false }
    guard previous.width > 0, previous.height > 0 else { return true }
    return abs(previous.width - current.width) > tolerance
        || abs(previous.height - current.height) > tolerance
}

func titlebarControlsShouldApplyLayout(
    previous: TitlebarControlsLayoutSnapshot?,
    next: TitlebarControlsLayoutSnapshot,
    tolerance: CGFloat = 0.5
) -> Bool {
    guard let previous else { return true }
    return abs(previous.contentSize.width - next.contentSize.width) > tolerance
        || abs(previous.contentSize.height - next.contentSize.height) > tolerance
        || abs(previous.containerHeight - next.containerHeight) > tolerance
        || abs(previous.yOffset - next.yOffset) > tolerance
}

/// Owns the app's notifications popover. It anchors to the main window toolbar's bell, or
/// to an explicit anchor view (the full-screen controls), and falls back to the window's
/// top-left corner when the toolbar is hidden.
@MainActor
final class NotificationsPopoverController: NSObject, NSPopoverDelegate {
    private lazy var popover: NSPopover = {
        let popover = NSPopover()
        popover.behavior = .semitransient
        popover.animates = true
        popover.delegate = self
        return popover
    }()

    var isShown: Bool { popover.isShown }

    func toggle(animated: Bool, anchorView: NSView? = nil, window: NSWindow? = nil) {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        show(animated: animated, anchorView: anchorView, window: window)
    }

    func show(animated: Bool, anchorView: NSView? = nil, window: NSWindow? = nil) {
        guard !popover.isShown,
              let window = anchorView?.window ?? window ?? Self.preferredMainWindow(),
              let contentView = window.contentView else { return }
        // Recreate the content each time so no SwiftUI observers outlive a closed popover.
        let hostingController = NSHostingController(
            rootView: NotificationsPopoverView(
                notificationStore: TerminalNotificationStore.shared,
                onDismiss: { [weak self] in self?.popover.performClose(nil) }
            )
        )
        // Popover content must not observe safe-area changes: SwiftUI's observation
        // recurses through invalidateSafeAreaInsets on ambient display events until
        // AppKit's layout-loop guard kills the app (issue #307/#308 — the opt-out does
        // not cascade to sibling hosts, so every new hosting controller needs its own).
        hostingController.safeAreaRegions = []
        hostingController.view.wantsLayer = true
        hostingController.view.layer?.backgroundColor = .clear
        popover.contentViewController = hostingController
        popover.animates = animated

        if let anchorView, anchorView.window === window {
            anchorView.superview?.layoutSubtreeIfNeeded()
            let anchorRect = anchorView.convert(anchorView.bounds, to: contentView)
            if !anchorRect.isEmpty {
                popover.show(relativeTo: anchorRect, of: contentView, preferredEdge: .maxY)
                postNotificationsPopoverVisibilityDidChange(isShown: true)
                return
            }
        }
        if let bell = MainWindowToolbar.notificationsItem(in: window) {
            popover.show(relativeTo: bell)
            postNotificationsPopoverVisibilityDidChange(isShown: true)
            return
        }
        contentView.layoutSubtreeIfNeeded()
        let bounds = contentView.bounds
        let anchorRect = NSRect(x: 12, y: bounds.maxY - 8, width: 1, height: 1)
        popover.show(relativeTo: anchorRect, of: contentView, preferredEdge: .maxY)
        postNotificationsPopoverVisibilityDidChange(isShown: true)
    }

    @discardableResult
    func dismissIfShown() -> Bool {
        guard popover.isShown else { return false }
        popover.performClose(nil)
        return true
    }

    private static func preferredMainWindow() -> NSWindow? {
        if let key = NSApp.keyWindow, key.hasProgramaMainIdentifier { return key }
        if let main = NSApp.mainWindow, main.hasProgramaMainIdentifier { return main }
        return NSApp.orderedWindows.first { $0.hasProgramaMainIdentifier && $0.isVisible }
    }

    // MARK: - NSPopoverDelegate

    func popoverDidClose(_ notification: Notification) {
        // Clear the content view controller to stop SwiftUI observers when popover is hidden
        popover.contentViewController = nil
        postNotificationsPopoverVisibilityDidChange(isShown: false)
#if DEBUG
        // UI-test seam: lets XCUITests check that typing stayed out of the terminal while the
        // popover was open, without the control socket. No-op unless PROGRAMA_UI_TEST_KEYEQUIV_PATH is set.
        if UITestRecorder.isEnabled,
           let panel = AppDelegate.shared?.tabManager?.selectedWorkspace?.focusedTerminalPanel {
            UITestRecorder.record([
                "terminalTextAtNotificationsPopoverClose":
                    TerminalController.shared.readTerminalTextForSnapshot(terminalPanel: panel, lineLimit: 200) ?? ""
            ])
        }
#endif
    }
}

private struct NotificationsPopoverView: View {
    @ObservedObject var notificationStore: TerminalNotificationStore
    @ObservedObject private var keyboardShortcutSettingsObserver = KeyboardShortcutSettingsObserver.shared
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(String(localized: "notifications.title", defaultValue: "Notifications"))
                    .font(.headline)
                Spacer()
                Button(action: jumpToLatestUnread) {
                    HStack(spacing: 6) {
                        Text(String(localized: "notifications.jumpToLatest", defaultValue: "Jump to Latest"))
                        Text(jumpToUnreadShortcut.displayString)
                    }
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("notificationsPopover.jumpToLatest")
                .accessibilityValue(jumpToUnreadShortcut.displayString)
                .safeHelp(
                    KeyboardShortcutSettings.Action.jumpToUnread.tooltip(
                        String(localized: "notifications.jumpToLatest", defaultValue: "Jump to Latest")
                    )
                )
                .disabled(!hasUnreadNotifications)

                Button(String(localized: "notifications.clearAll", defaultValue: "Clear All")) {
                    notificationStore.clearAll()
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("notificationsPopover.clearAll")
                .disabled(notificationStore.notifications.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            if notificationStore.notifications.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "bell.slash")
                        .symbolRasterSize(28)
                        .foregroundColor(.secondary)
                    Text(String(localized: "notifications.empty.title", defaultValue: "No notifications yet"))
                        .font(.headline)
                    Text(String(localized: "notifications.empty.subtitle", defaultValue: "Desktop notifications will appear here."))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(minWidth: 420, idealWidth: 520, maxWidth: 640, minHeight: 180)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(notificationStore.notifications) { notification in
                            NotificationPopoverRow(
                                notification: notification,
                                tabTitle: tabTitle(for: notification.tabId),
                                onOpen: { open(notification) },
                                onClear: { notificationStore.remove(id: notification.id) },
                                onMarkRead: { notificationStore.markRead(id: notification.id) },
                                onMarkUnread: { notificationStore.markUnread(id: notification.id) }
                            )
                        }
                    }
                    .padding(12)
                }
                .frame(minWidth: 420, idealWidth: 520, maxWidth: 640, minHeight: 320, maxHeight: 480)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func tabTitle(for tabId: UUID) -> String? {
        AppDelegate.shared?.tabTitle(for: tabId)
    }

    private var jumpToUnreadShortcut: StoredShortcut {
        let _ = keyboardShortcutSettingsObserver.revision
        return KeyboardShortcutSettings.shortcut(for: .jumpToUnread)
    }

    private var hasUnreadNotifications: Bool {
        notificationStore.notifications.contains(where: { !$0.isRead })
    }

    private func jumpToLatestUnread() {
        DispatchQueue.main.async {
            AppDelegate.shared?.jumpToLatestUnread()
            onDismiss()
        }
    }

    private func open(_ notification: TerminalNotification) {
        // SwiftUI action closures are not guaranteed to run on the main actor.
        // Ensure window focus + tab selection happens on the main thread.
        DispatchQueue.main.async {
            _ = AppDelegate.shared?.openNotification(
                tabId: notification.tabId,
                surfaceId: notification.surfaceId,
                notificationId: notification.id
            )
            onDismiss()
        }
    }
}

private struct NotificationPopoverRow: View {
    let notification: TerminalNotification
    let tabTitle: String?
    let onOpen: () -> Void
    let onClear: () -> Void
    let onMarkRead: () -> Void
    let onMarkUnread: () -> Void

    @State private var isRowHovering = false
    @FocusState private var isRowFocused: Bool
    @State private var isClearHovering = false
    @FocusState private var isClearFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: onOpen) {
                HStack(alignment: .top, spacing: 10) {
                    Circle()
                        .fill(notification.isRead ? Color.clear : programaAccentColor())
                        .frame(width: 8, height: 8)
                        .overlay(
                            Circle()
                                .stroke(programaAccentColor().opacity(notification.isRead ? 0.2 : 1), lineWidth: 1)
                        )
                        .padding(.top, 6)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(notification.title)
                                .font(.headline)
                                .foregroundColor(.primary)
                            Spacer()
                            Text(notification.createdAt.formatted(date: .omitted, time: .shortened))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        if !notification.body.isEmpty {
                            Text(notification.body)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .lineLimit(3)
                        }

                        if let tabTitle {
                            Text(tabTitle)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    Spacer(minLength: 0)
                }
                .padding(.trailing, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable()
            .focused($isRowFocused)
            .onHover { hovering in isRowHovering = hovering }
            .accessibilityIdentifier("NotificationPopoverRow.\(notification.id.uuidString)")
            // XCUITest's `.click()` is not always reliable for SwiftUI `Button`s hosted in an `NSPopover`.
            // Provide an explicit accessibility action so AXPress always routes to `onOpen`.
            .accessibilityAction { onOpen() }
            // A SwiftUI `.contextMenu` here hangs off `isRowHovering`/`isRowFocused`
            // state: `onHover(false)` fires as the pointer moves from the row onto the
            // open menu, re-evaluating this view's body and rebuilding the menu, which
            // macOS then closes out from under the click. A native NSMenu shown from a
            // right-mouse-down/ctrl-click catcher is immune to that re-evaluation. It sits
            // in an overlay so it hit-tests above the SwiftUI button.
            .overlay(
                NotificationRowContextMenuCatcher(
                    isRead: notification.isRead,
                    onMarkRead: onMarkRead,
                    onMarkUnread: onMarkUnread
                )
            )

            Button(action: onClear) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
                    .padding(4)
                    .background(
                        Circle()
                            .strokeBorder(programaAccentColor(), lineWidth: (isClearHovering || isClearFocused) ? 1.5 : 0)
                    )
            }
            .buttonStyle(.plain)
            .focusable()
            .focused($isClearFocused)
            .onHover { hovering in isClearHovering = hovering }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(programaAccentColor(), lineWidth: (isRowHovering || isRowFocused) ? 1.5 : 0)
                )
        )
    }
}

/// Right-click catcher backing `NotificationPopoverRow`'s context menu. Sized to match
/// the row via `.background(...)`; only intercepts right-click / ctrl-click — every
/// other event falls through to the SwiftUI button/hover handling underneath.
private struct NotificationRowContextMenuCatcher: NSViewRepresentable {
    let isRead: Bool
    let onMarkRead: () -> Void
    let onMarkUnread: () -> Void

    func makeNSView(context: Context) -> NotificationRowContextMenuNSView {
        NotificationRowContextMenuNSView()
    }

    func updateNSView(_ nsView: NotificationRowContextMenuNSView, context: Context) {
        nsView.isRead = isRead
        nsView.onMarkRead = onMarkRead
        nsView.onMarkUnread = onMarkUnread
    }
}

private final class NotificationRowContextMenuNSView: NSView {
    var isRead = false
    var onMarkRead: (() -> Void)?
    var onMarkUnread: (() -> Void)?

    override var mouseDownCanMoveWindow: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Only intercept right-click and ctrl-click (left-click with the control key
        // held, which AppKit does not always redirect to rightMouseDown on its own) so
        // plain left-click, hover, and keyboard focus continue to hit-test through to
        // the SwiftUI button underneath.
        guard let event = NSApp.currentEvent else { return nil }
        let isCtrlClick = event.type == .leftMouseDown && event.modifierFlags.contains(.control)
        guard event.type == .rightMouseDown || isCtrlClick else { return nil }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        guard event.modifierFlags.contains(.control) else {
            super.mouseDown(with: event)
            return
        }
        showContextMenu(for: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        showContextMenu(for: event)
    }

    private func showContextMenu(for event: NSEvent) {
        let menu = NSMenu()
        if isRead {
            let item = NSMenuItem(
                title: String(localized: "notificationsPopover.markUnread", defaultValue: "Mark as Unread"),
                action: #selector(markUnreadAction),
                keyEquivalent: ""
            )
            item.target = self
            menu.addItem(item)
        } else {
            let item = NSMenuItem(
                title: String(localized: "notificationsPopover.markRead", defaultValue: "Mark as Read"),
                action: #selector(markReadAction),
                keyEquivalent: ""
            )
            item.target = self
            menu.addItem(item)
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func markReadAction() { onMarkRead?() }
    @objc private func markUnreadAction() { onMarkUnread?() }
}
