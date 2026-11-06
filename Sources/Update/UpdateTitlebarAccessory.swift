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

/// Owns the app's notifications popover. It anchors to the main window toolbar's bell, in
/// full screen too, and falls back to the window's top-left corner when the toolbar is hidden.
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

    func toggle(animated: Bool, window: NSWindow? = nil) {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        show(animated: animated, window: window)
    }

    func show(animated: Bool, window: NSWindow? = nil) {
        guard !popover.isShown,
              let window = window ?? Self.preferredMainWindow(),
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
