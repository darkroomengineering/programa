// Sidebar visual chrome, extracted from ContentView.swift (nuclear-review #94.5).
// Pure move: sidebar footer/help-menu/scrim/blur/material/tint/preset enums,
// visual-effect/backdrop views, and the NSColor extension, consolidated from two
// non-contiguous locations in ContentView.swift.
//
// Access-level widening: SidebarFooter, SidebarTopScrim, SidebarScrollViewResolver,
// SidebarEmptyArea, ClearScrollBackground, DraggableFolderIcon,
// TitlebarLeadingInsetReader, and SidebarBackdrop were
// file-private to the old ContentView.swift; widened to internal (dropped the
// `private` modifier) because VerticalTabsSidebar and ContentView, which stay in
// ContentView.swift, still construct/reference them. No other behavior change.

import AppKit
import Bonsplit
import SwiftUI

struct SidebarFooter: View {
    @ObservedObject var updateViewModel: UpdateViewModel
    let onSendFeedback: () -> Void

    var body: some View {
#if DEBUG
        SidebarDevFooter(updateViewModel: updateViewModel, onSendFeedback: onSendFeedback)
#else
        // Sidebar spacing grid: 4pt base, edges on 8.
        SidebarFooterButtons(updateViewModel: updateViewModel, onSendFeedback: onSendFeedback)
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
#endif
    }
}

enum SidebarFooterControlLayout {
    static let buttonSize: CGFloat = 44
    /// Traffic lights sit on a 20pt pitch; the thinner outline glyphs need one
    /// extra grid step to read as evenly spaced next to them.
    static let visualPitch: CGFloat = 24

    static func helpIconOffset(clustersWithUsage: Bool) -> CGFloat {
        clustersWithUsage ? (buttonSize - visualPitch) / 2 : 0
    }

    static let usageIconOffset = -(buttonSize - visualPitch) / 2
}

private struct SidebarFooterButtons: View {
    @ObservedObject var updateViewModel: UpdateViewModel
    @AppStorage("sidebarShowClaudeQuota") private var showProviderUsage = true
    let onSendFeedback: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            HStack(spacing: 0) {
                SidebarHelpMenuButton(
                    clustersWithUsage: showProviderUsage,
                    onSendFeedback: onSendFeedback
                )
                if showProviderUsage {
                    SidebarUsageButton()
                }
            }
            UpdatePill(model: updateViewModel)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SidebarUsageButton: View {
    private let title = String(localized: "sidebar.usage.button", defaultValue: "Provider Usage")
    private let buttonSize = SidebarFooterControlLayout.buttonSize
    private let iconSize: CGFloat = 11

    @StateObject private var store = ProviderUsageStore()
    @State private var isPopoverPresented = false

    var body: some View {
        Button {
            let isOpening = !isPopoverPresented
            isPopoverPresented.toggle()
            if isOpening {
                Task { await store.refresh() }
            } else {
                store.cancelRefresh()
            }
        } label: {
            Image(systemName: "gauge.with.dots.needle.33percent")
                .symbolRenderingMode(.monochrome)
                .symbolRasterSize(iconSize, weight: .medium)
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                .frame(width: buttonSize, height: buttonSize, alignment: .center)
                .offset(x: SidebarFooterControlLayout.usageIconOffset)
        }
        .buttonStyle(SidebarFooterIconButtonStyle())
        .frame(width: buttonSize, height: buttonSize, alignment: .center)
        .background(ArrowlessPopoverAnchor(
            isPresented: $isPopoverPresented,
            preferredEdge: .maxX,
            detachedGap: 4
        ) {
            SidebarQuotaFooter(store: store)
        })
        .safeHelp(title)
        .accessibilityLabel(title)
        .accessibilityIdentifier("SidebarUsageButton")
        .onChange(of: isPopoverPresented) { _, isPresented in
            if !isPresented {
                store.cancelRefresh()
            }
        }
        .onDisappear {
            store.cancelRefresh()
        }
    }
}

private enum SidebarHelpMenuAction {
    case keyboardShortcuts
    case docs
    case changelog
    case github
    case githubIssues
    case twitter
    case website
    case checkForUpdates
    case sendFeedback
    case welcome
}

private struct SidebarHelpMenuButton: View {
    private let docsURL = URL(string: "https://github.com/darkroomengineering/programa/tree/main/docs")
    private let changelogURL = URL(string: "https://github.com/darkroomengineering/programa/blob/main/CHANGELOG.md")
    private let githubURL = URL(string: "https://github.com/darkroomengineering/programa")
    private let githubIssuesURL = URL(string: "https://github.com/darkroomengineering/programa/issues")
    private let twitterURL = URL(string: "https://x.com/darkroomdevs")
    private let websiteURL = URL(string: "https://darkroom.engineering")
    private let helpTitle = String(localized: "sidebar.help.button", defaultValue: "Help")
    private let buttonSize = SidebarFooterControlLayout.buttonSize
    private let iconSize: CGFloat = 11
    @ObservedObject private var keyboardShortcutSettingsObserver = KeyboardShortcutSettingsObserver.shared

    let clustersWithUsage: Bool
    let onSendFeedback: () -> Void

    @State private var isPopoverPresented = false

    private var sendFeedbackShortcutHint: String {
        let _ = keyboardShortcutSettingsObserver.revision
        return KeyboardShortcutSettings.shortcut(for: .sendFeedback).displayString
    }

    var body: some View {
        Button {
            isPopoverPresented.toggle()
        } label: {
            Image(systemName: "questionmark.circle")
                .symbolRenderingMode(.monochrome)
                .symbolRasterSize(iconSize, weight: .medium)
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                .frame(width: buttonSize, height: buttonSize, alignment: .center)
                .offset(x: SidebarFooterControlLayout.helpIconOffset(clustersWithUsage: clustersWithUsage))
        }
        .buttonStyle(SidebarFooterIconButtonStyle())
        .frame(width: buttonSize, height: buttonSize, alignment: .center)
        .background(ArrowlessPopoverAnchor(
            isPresented: $isPopoverPresented,
            preferredEdge: .maxY,
            detachedGap: 4
        ) {
            helpPopover
        })
        .safeHelp(helpTitle)
        .accessibilityLabel(helpTitle)
        .accessibilityIdentifier("SidebarHelpMenuButton")
    }

    private var helpPopover: some View {
        VStack(alignment: .leading, spacing: 2) {
            helpOptionButton(
                title: String(localized: "sidebar.help.welcome", defaultValue: "Welcome to Programa!"),
                action: .welcome,
                accessibilityIdentifier: "SidebarHelpMenuOptionWelcome",
                isExternalLink: false
            )
            helpOptionButton(
                title: String(localized: "sidebar.help.sendFeedback", defaultValue: "Send Feedback"),
                action: .sendFeedback,
                accessibilityIdentifier: "SidebarHelpMenuOptionSendFeedback",
                isExternalLink: false,
                shortcutHint: sendFeedbackShortcutHint,
                trailingSystemImage: "bubble.left.and.text.bubble.right"
            )
            helpOptionButton(
                title: String(localized: "settings.section.keyboardShortcuts", defaultValue: "Keyboard Shortcuts"),
                action: .keyboardShortcuts,
                accessibilityIdentifier: "SidebarHelpMenuOptionKeyboardShortcuts",
                isExternalLink: false
            )
            if docsURL != nil {
                helpOptionButton(
                    title: String(localized: "about.docs", defaultValue: "Docs"),
                    action: .docs,
                    accessibilityIdentifier: "SidebarHelpMenuOptionDocs",
                    isExternalLink: true
                )
            }
            if changelogURL != nil {
                helpOptionButton(
                    title: String(localized: "sidebar.help.changelog", defaultValue: "Changelog"),
                    action: .changelog,
                    accessibilityIdentifier: "SidebarHelpMenuOptionChangelog",
                    isExternalLink: true
                )
            }
            if githubURL != nil {
                helpOptionButton(
                    title: String(localized: "about.github", defaultValue: "GitHub"),
                    action: .github,
                    accessibilityIdentifier: "SidebarHelpMenuOptionGitHub",
                    isExternalLink: true
                )
            }
            if githubIssuesURL != nil {
                helpOptionButton(
                    title: String(localized: "sidebar.help.githubIssues", defaultValue: "GitHub Issues"),
                    action: .githubIssues,
                    accessibilityIdentifier: "SidebarHelpMenuOptionGitHubIssues",
                    isExternalLink: true
                )
            }
            if twitterURL != nil {
                helpOptionButton(
                    title: String(localized: "sidebar.help.twitter", defaultValue: "X (Twitter)"),
                    action: .twitter,
                    accessibilityIdentifier: "SidebarHelpMenuOptionTwitter",
                    isExternalLink: true
                )
            }
            if websiteURL != nil {
                helpOptionButton(
                    title: String(localized: "sidebar.help.website", defaultValue: "Darkroom"),
                    action: .website,
                    accessibilityIdentifier: "SidebarHelpMenuOptionWebsite",
                    isExternalLink: true
                )
            }
            helpOptionButton(
                title: String(localized: "command.checkForUpdates.title", defaultValue: "Check for Updates"),
                action: .checkForUpdates,
                accessibilityIdentifier: "SidebarHelpMenuOptionCheckForUpdates",
                isExternalLink: false
            )
        }
        .padding(8)
        .frame(minWidth: 200)
    }

    #if DEBUG
    @MainActor
    static func popoverFittingSizeForTesting() -> NSSize {
        let button = Self(clustersWithUsage: false, onSendFeedback: {})
        let coordinator = ArrowlessPopoverAnchor<AnyView>.Coordinator(
            isPresented: .constant(true)
        )
        coordinator.updateRootView(AnyView(button.helpPopover))
        return coordinator.installPopoverForSizingTest()
    }
    #endif

    private func helpOptionButton(
        title: String,
        action: SidebarHelpMenuAction,
        accessibilityIdentifier: String,
        isExternalLink: Bool,
        shortcutHint: String? = nil,
        trailingSystemImage: String? = nil
    ) -> some View {
        Button {
            isPopoverPresented = false
            perform(action)
        } label: {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 12))
                Spacer(minLength: 0)
                if let shortcutHint {
                    helpOptionShortcutHint(text: shortcutHint)
                }
                if let trailingSystemImage {
                    helpOptionTrailingIcon(systemName: trailingSystemImage)
                }
                if isExternalLink {
                    helpOptionTrailingIcon(systemName: "arrow.up.right", size: 8)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private func helpOptionShortcutHint(text: String) -> some View {
        Text(text)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .font(.system(size: 10, weight: .regular, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
    }

    private func helpOptionTrailingIcon(systemName: String, size: CGFloat = 13) -> some View {
        Image(systemName: systemName)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
    }

    private func perform(_ action: SidebarHelpMenuAction) {
        switch action {
        case .keyboardShortcuts:
            isPopoverPresented = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                Task { @MainActor in
                    if let appDelegate = AppDelegate.shared {
                        appDelegate.openPreferencesWindow(
                            debugSource: "sidebarHelpMenu.keyboardShortcuts",
                            navigationTarget: .keyboardShortcuts
                        )
                    } else {
                        AppDelegate.presentPreferencesWindow(navigationTarget: .keyboardShortcuts)
                    }
                }
            }
        case .docs:
            guard let docsURL else { return }
            NSWorkspace.shared.open(docsURL)
        case .changelog:
            guard let changelogURL else { return }
            NSWorkspace.shared.open(changelogURL)
        case .github:
            guard let githubURL else { return }
            NSWorkspace.shared.open(githubURL)
        case .githubIssues:
            guard let githubIssuesURL else { return }
            NSWorkspace.shared.open(githubIssuesURL)
        case .twitter:
            guard let twitterURL else { return }
            NSWorkspace.shared.open(twitterURL)
        case .website:
            guard let websiteURL else { return }
            NSWorkspace.shared.open(websiteURL)
        case .checkForUpdates:
            Task { @MainActor in
                AppDelegate.shared?.checkForUpdates(nil)
            }
        case .sendFeedback:
            isPopoverPresented = false
            onSendFeedback()
        case .welcome:
            isPopoverPresented = false
            Task { @MainActor in
                if let appDelegate = AppDelegate.shared {
                    appDelegate.openWelcomeWorkspace()
                }
            }
        }
    }

}

private struct ArrowlessPopoverAnchor<PopoverContent: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    let preferredEdge: NSRectEdge
    let detachedGap: CGFloat
    @ViewBuilder let content: () -> PopoverContent

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.anchorView = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.anchorView = nsView
        context.coordinator.updateRootView(AnyView(content()))

        if isPresented {
            context.coordinator.present(
                preferredEdge: preferredEdge,
                detachedGap: detachedGap
            )
        } else {
            context.coordinator.dismiss()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(isPresented: $isPresented)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.dismiss()
    }

    final class Coordinator: NSObject, NSPopoverDelegate {
        @Binding var isPresented: Bool

        weak var anchorView: NSView?
        private let hostingController = NSHostingController(rootView: AnyView(EmptyView()))
        private var popover: NSPopover?

        init(isPresented: Binding<Bool>) {
            _isPresented = isPresented
        }

        func updateRootView(_ rootView: AnyView) {
            hostingController.rootView = AnyView(rootView.fixedSize())
            hostingController.view.invalidateIntrinsicContentSize()
            hostingController.view.layoutSubtreeIfNeeded()
            if let popover {
                sizePopoverToCurrentContent(popover)
            }
        }

        func present(preferredEdge: NSRectEdge, detachedGap: CGFloat) {
            guard let anchorView else {
                isPresented = false
                dismiss()
                return
            }

            let popover = popover ?? makePopover()
            if popover.isShown {
                return
            }

            hostingController.view.invalidateIntrinsicContentSize()
            hostingController.view.layoutSubtreeIfNeeded()
            sizePopoverToCurrentContent(popover)

            popover.show(
                relativeTo: positioningRect(
                    for: anchorView.bounds,
                    preferredEdge: preferredEdge,
                    detachedGap: detachedGap
                ),
                of: anchorView,
                preferredEdge: preferredEdge
            )
        }

        func dismiss() {
            popover?.performClose(nil)
            popover = nil
        }

        func popoverDidClose(_ notification: Notification) {
            popover = nil
            if isPresented {
                isPresented = false
            }
        }

        private func makePopover() -> NSPopover {
            let popover = NSPopover()
            popover.behavior = .semitransient
            popover.animates = true
            popover.setValue(true, forKeyPath: "shouldHideAnchor")
            popover.contentViewController = hostingController
            popover.delegate = self
            self.popover = popover
            return popover
        }

        private func sizePopoverToCurrentContent(_ popover: NSPopover) {
            let fittingSize = hostingController.view.fittingSize
            if fittingSize.width > 0, fittingSize.height > 0 {
                popover.contentSize = NSSize(
                    width: ceil(fittingSize.width),
                    height: ceil(fittingSize.height)
                )
            }
        }

        #if DEBUG
        func installPopoverForSizingTest() -> NSSize {
            let popover = makePopover()
            hostingController.view.invalidateIntrinsicContentSize()
            hostingController.view.layoutSubtreeIfNeeded()
            sizePopoverToCurrentContent(popover)
            return popover.contentSize
        }

        var contentSizeForTesting: NSSize? {
            popover?.contentSize
        }
        #endif

        private func positioningRect(
            for bounds: CGRect,
            preferredEdge: NSRectEdge,
            detachedGap: CGFloat
        ) -> CGRect {
            let hiddenArrowInset: CGFloat = 13
            let compensation = max(hiddenArrowInset - detachedGap, 0)

            switch preferredEdge {
            case .maxY:
                return NSRect(
                    x: bounds.minX,
                    y: bounds.maxY - compensation,
                    width: bounds.width,
                    height: compensation
                )
            case .minY:
                return NSRect(
                    x: bounds.minX,
                    y: bounds.minY,
                    width: bounds.width,
                    height: compensation
                )
            case .maxX:
                return NSRect(
                    x: bounds.maxX - compensation,
                    y: bounds.minY,
                    width: compensation,
                    height: bounds.height
                )
            case .minX:
                return NSRect(
                    x: bounds.minX,
                    y: bounds.minY,
                    width: compensation,
                    height: bounds.height
                )
            @unknown default:
                return bounds
            }
        }
    }
}

#if DEBUG
@MainActor
final class SidebarPopoverSizingTestDriver {
    private let coordinator = ArrowlessPopoverAnchor<AnyView>.Coordinator(
        isPresented: .constant(true)
    )

    init(rootView: AnyView) {
        coordinator.updateRootView(rootView)
    }

    func installPopover() -> NSSize {
        coordinator.installPopoverForSizingTest()
    }

    func updateRootView(_ rootView: AnyView) {
        coordinator.updateRootView(rootView)
    }

    var contentSize: NSSize? {
        coordinator.contentSizeForTesting
    }
}

@MainActor
enum SidebarHelpPopoverSizingTestDriver {
    static func fittingSize() -> NSSize {
        SidebarHelpMenuButton.popoverFittingSizeForTesting()
    }
}
#endif

private struct SidebarFooterIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SidebarFooterIconButtonStyleBody(configuration: configuration)
    }
}

private struct SidebarFooterIconButtonStyleBody: View {
    let configuration: SidebarFooterIconButtonStyle.Configuration

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .opacity(isEnabled ? (configuration.isPressed ? 0.55 : 1) : 0.35)
    }
}

#if DEBUG
private struct SidebarDevFooter: View {
    @ObservedObject var updateViewModel: UpdateViewModel
    let onSendFeedback: () -> Void
    @AppStorage(DevBuildBannerDebugSettings.sidebarBannerVisibleKey)
    private var showSidebarDevBuildBanner = DevBuildBannerDebugSettings.defaultShowSidebarBanner

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SidebarFooterButtons(updateViewModel: updateViewModel, onSendFeedback: onSendFeedback)
            if showSidebarDevBuildBanner {
                Text(String(localized: "debug.devBuildBanner.title", defaultValue: "THIS IS A DEV BUILD"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.red)
            }
        }
        // Sidebar spacing grid: 4pt base, edges on 8.
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }
}
#endif

/// When the sidebar borrows the terminal's background, the app's own light/dark
/// appearance stops describing what the sidebar actually looks like. Anything drawn on
/// it has to resolve against the terminal's luminance instead, or `.primary` and
/// `.secondary` land dark-on-dark.
enum SidebarTerminalAppearance {
    static func colorScheme() -> ColorScheme {
        let color = GhosttyBackgroundTheme.currentColor()
        let srgb = color.usingColorSpace(.sRGB) ?? color
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        srgb.getRed(&r, green: &g, blue: &b, alpha: &a)
        let luminance = 0.299 * r + 0.587 * g + 0.114 * b
        return luminance > 0.5 ? .light : .dark
    }
}

struct SidebarTopScrim: View {
    let height: CGFloat
    @AppStorage("sidebarMatchTerminalBackground") private var matchTerminalBackground = false
    @Environment(\.accessibilityReduceTransparency) private var accessibilityReduceTransparency
    @State private var terminalColor = Color(nsColor: GhosttyBackgroundTheme.currentColor())

    private var usesNativeGlassSidebar: Bool {
        WindowGlassEffect.isAvailable && !accessibilityReduceTransparency
    }

    var body: some View {
        Group {
            if usesNativeGlassSidebar {
                // The glass surface provides its own top treatment; a material
                // scrim reads as an opaque gray band on it (Maps has none).
                Color.clear
            } else if matchTerminalBackground {
                // The system material stays light over a terminal-coloured sidebar, which
                // reads as a grey wash across the top. Fade the terminal colour instead.
                LinearGradient(
                    colors: [
                        terminalColor,
                        terminalColor.opacity(0.85),
                        terminalColor.opacity(0.4),
                        Color.clear
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            } else {
                SidebarTopBlurEffect()
                    .mask(
                        LinearGradient(
                            colors: [
                                Color.black.opacity(0.95),
                                Color.black.opacity(0.75),
                                Color.black.opacity(0.35),
                                Color.clear
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }
        }
        .frame(height: height)
        .onReceive(NotificationCenter.default.publisher(for: .ghosttyDefaultBackgroundDidChange)) { _ in
            terminalColor = Color(nsColor: GhosttyBackgroundTheme.currentColor())
        }
    }
}

private struct SidebarTopBlurEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .withinWindow
        view.material = .underWindowBackground
        view.state = .active
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

struct SidebarScrollViewResolver: NSViewRepresentable {
    let onResolve: (NSScrollView?) -> Void

    func makeNSView(context: Context) -> SidebarScrollViewResolverView {
        let view = SidebarScrollViewResolverView()
        view.onResolve = onResolve
        return view
    }

    func updateNSView(_ nsView: SidebarScrollViewResolverView, context: Context) {
        nsView.onResolve = onResolve
        nsView.resolveScrollView()
    }
}

final class SidebarScrollViewResolverView: NSView {
    var onResolve: ((NSScrollView?) -> Void)?

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        resolveScrollView()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        resolveScrollView()
    }

    func resolveScrollView() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            onResolve?(self.enclosingScrollView)
        }
    }
}

struct SidebarEmptyArea: View {
    let tabManager: TabManager
    let rowSpacing: CGFloat
    @Binding var selection: SidebarSelection
    @Binding var selectedTabIds: Set<UUID>
    @Binding var lastSidebarSelectionIndex: Int?
    let dragAutoScrollController: SidebarDragAutoScrollController
    @Binding var draggedTabId: UUID?
    @Binding var dropIndicator: SidebarDropIndicator?

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Drag view must be an .overlay (frontmost), not .background: as a background,
            // the Color.clear + .contentShape content above it is the real hit-test target,
            // so AppKit never even asks the background NSView's hitTest — that's why the
            // titlebar.dragHandle.* logs never fired here. Once frontmost, this view's own
            // hitTest bails out for non-mouseDown event types, so SwiftUI's onDrop target
            // underneath is unaffected.
            //
            // Double-click is handled by `onDoubleClick` below rather than a sibling
            // `.onTapGesture(count: 2)`: once this view is frontmost, it claims the hit-test
            // for the *first* click of any double-click, so a sibling gesture recognizer on
            // the content beneath never observes that first click and can't reliably count
            // to two. Owning the whole click sequence here (mirroring Bonsplit's
            // TabBarDragZoneView.onDoubleClick pattern) avoids that race entirely.
            .overlay {
                WindowDragHandleView(
                    handlesDoubleClick: false,
                    onDoubleClick: {
                        #if DEBUG
                        dlog("sidebar.dragHandle.doubleClick action=addWorkspace")
                        #endif
                        tabManager.addWorkspace(placementOverride: .end)
                        if let selectedId = tabManager.selectedTabId {
                            selectedTabIds = [selectedId]
                            lastSidebarSelectionIndex = tabManager.tabs.firstIndex { $0.id == selectedId }
                        }
                        selection = .tabs
                    }
                )
            }
            .onDrop(of: SidebarTabDragPayload.dropContentTypes, delegate: SidebarTabDropDelegate(
                targetTabId: nil,
                tabManager: tabManager,
                draggedTabId: $draggedTabId,
                selectedTabIds: $selectedTabIds,
                lastSidebarSelectionIndex: $lastSidebarSelectionIndex,
                targetRowHeight: nil,
                dragAutoScrollController: dragAutoScrollController,
                dropIndicator: $dropIndicator
            ))
            .overlay(alignment: .top) {
                if shouldShowTopDropIndicator {
                    Rectangle()
                        .fill(programaAccentColor())
                        .frame(height: 2)
                        .padding(.horizontal, 8)
                        .offset(y: -(rowSpacing / 2))
                }
            }
    }

    private var shouldShowTopDropIndicator: Bool {
        guard draggedTabId != nil, let indicator = dropIndicator else { return false }
        if indicator.tabId == nil {
            return true
        }
        guard indicator.edge == .bottom, let lastTabId = tabManager.tabs.last?.id else { return false }
        return indicator.tabId == lastTabId
    }
}

enum SidebarPathFormatter {
    static let homeDirectoryPath: String = FileManager.default.homeDirectoryForCurrentUser.path

    static func shortenedPath(
        _ path: String,
        homeDirectoryPath: String = Self.homeDirectoryPath
    ) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return path }
        if trimmed == homeDirectoryPath {
            return "~"
        }
        if trimmed.hasPrefix(homeDirectoryPath + "/") {
            return "~" + trimmed.dropFirst(homeDirectoryPath.count)
        }
        return trimmed
    }
}

enum SidebarWorkspaceShortcutHintMetrics {
    private static let measurementFont = NSFont.systemFont(ofSize: 10, weight: .semibold)
    private static let minimumSlotWidth: CGFloat = 28
    private static let horizontalPadding: CGFloat = 12
    private static let lock = NSLock()
    private static var cachedHintWidths: [String: CGFloat] = [:]
    #if DEBUG
    private static var measurementCount = 0
    #endif

    static func slotWidth(label: String?, debugXOffset: Double) -> CGFloat {
        guard let label else { return minimumSlotWidth }
        let positiveDebugInset = max(0, CGFloat(ShortcutHintDebugSettings.clamped(debugXOffset))) + 2
        return max(minimumSlotWidth, hintWidth(for: label) + positiveDebugInset)
    }

    static func hintWidth(for label: String) -> CGFloat {
        lock.lock()
        if let cached = cachedHintWidths[label] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let textWidth = (label as NSString).size(withAttributes: [.font: measurementFont]).width
        let measuredWidth = ceil(textWidth) + horizontalPadding

        lock.lock()
        cachedHintWidths[label] = measuredWidth
        #if DEBUG
        measurementCount += 1
        #endif
        lock.unlock()
        return measuredWidth
    }

    #if DEBUG
    static func resetCacheForTesting() {
        lock.lock()
        cachedHintWidths.removeAll()
        measurementCount = 0
        lock.unlock()
    }

    static func measurementCountForTesting() -> Int {
        lock.lock()
        let count = measurementCount
        lock.unlock()
        return count
    }
    #endif
}

enum SidebarTrailingAccessoryWidthPolicy {
    static let closeButtonWidth: CGFloat = 16

    static func width(
        canCloseWorkspace: Bool,
        showsWorkspaceShortcutHint: Bool,
        workspaceShortcutLabel: String?,
        debugXOffset: Double
    ) -> CGFloat {
        if showsWorkspaceShortcutHint, let workspaceShortcutLabel {
            return SidebarWorkspaceShortcutHintMetrics.slotWidth(
                label: workspaceShortcutLabel,
                debugXOffset: debugXOffset
            )
        }

        return canCloseWorkspace ? closeButtonWidth : 0
    }
}


struct MiddleClickCapture: NSViewRepresentable {
    let onMiddleClick: () -> Void

    func makeNSView(context: Context) -> MiddleClickCaptureView {
        let view = MiddleClickCaptureView()
        view.onMiddleClick = onMiddleClick
        return view
    }

    func updateNSView(_ nsView: MiddleClickCaptureView, context: Context) {
        nsView.onMiddleClick = onMiddleClick
    }
}

final class MiddleClickCaptureView: NSView {
    var onMiddleClick: (() -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Only intercept middle-click so left-click selection and right-click context menus
        // continue to hit-test through to SwiftUI/AppKit normally.
        guard let event = NSApp.currentEvent,
              event.type == .otherMouseDown,
              event.buttonNumber == 2 else {
            return nil
        }
        return self
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseDown(with: event)
            return
        }
        onMiddleClick?()
    }
}

enum SidebarSelection {
    case tabs
    case notifications
}

struct ClearScrollBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(ScrollBackgroundClearer())
    }
}

private struct ScrollBackgroundClearer: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let scrollView = findScrollView(startingAt: nsView) else { return }
            // Clear all backgrounds and mark as non-opaque for transparency
            scrollView.drawsBackground = false
            scrollView.backgroundColor = .clear
            scrollView.wantsLayer = true
            scrollView.layer?.backgroundColor = NSColor.clear.cgColor
            scrollView.layer?.isOpaque = false

            scrollView.contentView.drawsBackground = false
            scrollView.contentView.backgroundColor = .clear
            scrollView.contentView.wantsLayer = true
            scrollView.contentView.layer?.backgroundColor = NSColor.clear.cgColor
            scrollView.contentView.layer?.isOpaque = false

            if let docView = scrollView.documentView {
                docView.wantsLayer = true
                docView.layer?.backgroundColor = NSColor.clear.cgColor
                docView.layer?.isOpaque = false
            }
        }
    }

    private func findScrollView(startingAt view: NSView) -> NSScrollView? {
        var current: NSView? = view
        while let candidate = current {
            if let scrollView = candidate as? NSScrollView {
                return scrollView
            }
            current = candidate.superview
        }
        return nil
    }
}

struct DraggableFolderIcon: View {
    let directory: String

    var body: some View {
        DraggableFolderIconRepresentable(directory: directory)
            .frame(width: 16, height: 16)
            .safeHelp(String(localized: "sidebar.folderIcon.dragHint", defaultValue: "Drag to open in Finder or another app"))
            .onTapGesture(count: 2) {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: directory)
            }
    }
}

private struct DraggableFolderIconRepresentable: NSViewRepresentable {
    let directory: String

    func makeNSView(context: Context) -> DraggableFolderNSView {
        DraggableFolderNSView(directory: directory)
    }

    func updateNSView(_ nsView: DraggableFolderNSView, context: Context) {
        nsView.directory = directory
        nsView.updateIcon()
    }
}

final class DraggableFolderNSView: NSView, NSDraggingSource {
    private final class FolderIconImageView: NSImageView {
        override var mouseDownCanMoveWindow: Bool { false }
    }

    var directory: String
    private var imageView: FolderIconImageView!
    private var previousWindowMovableState: Bool?
    private weak var suppressedWindow: NSWindow?
    private var hasActiveDragSession = false
    private var didArmWindowDragSuppression = false

    private func formatPoint(_ point: NSPoint) -> String {
        String(format: "(%.1f,%.1f)", point.x, point.y)
    }

    init(directory: String) {
        self.directory = directory
        super.init(frame: .zero)
        setupImageView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 16, height: 16)
    }

    override var mouseDownCanMoveWindow: Bool { false }

    private func setupImageView() {
        imageView = FolderIconImageView()
        imageView.imageScaling = .scaleProportionallyDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 16),
            imageView.heightAnchor.constraint(equalToConstant: 16),
        ])
        updateIcon()
    }

    func updateIcon() {
        let icon = NSWorkspace.shared.icon(forFile: directory)
        icon.size = NSSize(width: 16, height: 16)
        imageView.image = icon
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return context == .outsideApplication ? [.copy, .link] : .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        hasActiveDragSession = false
        restoreWindowMovableStateIfNeeded()
        #if DEBUG
        let nowMovable = window.map { String($0.isMovable) } ?? "nil"
        let windowOrigin = window.map { formatPoint($0.frame.origin) } ?? "nil"
        dlog("folder.dragEnd dir=\(directory) operation=\(operation.rawValue) screen=\(formatPoint(screenPoint)) nowMovable=\(nowMovable) windowOrigin=\(windowOrigin)")
        #endif
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        let hit = super.hitTest(point)
        #if DEBUG
        let hitDesc = hit.map { String(describing: type(of: $0)) } ?? "nil"
        let imageHit = (hit === imageView)
        let wasMovable = previousWindowMovableState.map(String.init) ?? "nil"
        let nowMovable = window.map { String($0.isMovable) } ?? "nil"
        dlog("folder.hitTest point=\(formatPoint(point)) hit=\(hitDesc) imageViewHit=\(imageHit) returning=DraggableFolderNSView wasMovable=\(wasMovable) nowMovable=\(nowMovable)")
        #endif
        return self
    }

    override func mouseDown(with event: NSEvent) {
        maybeDisableWindowDraggingEarly(trigger: "mouseDown")
        hasActiveDragSession = false
        #if DEBUG
        let localPoint = convert(event.locationInWindow, from: nil)
        let responderDesc = window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        let wasMovable = previousWindowMovableState.map(String.init) ?? "nil"
        let nowMovable = window.map { String($0.isMovable) } ?? "nil"
        let windowOrigin = window.map { formatPoint($0.frame.origin) } ?? "nil"
        dlog("folder.mouseDown dir=\(directory) point=\(formatPoint(localPoint)) firstResponder=\(responderDesc) wasMovable=\(wasMovable) nowMovable=\(nowMovable) windowOrigin=\(windowOrigin)")
        #endif
        let fileURL = URL(fileURLWithPath: directory)
        let draggingItem = NSDraggingItem(pasteboardWriter: fileURL as NSURL)

        let iconImage = NSWorkspace.shared.icon(forFile: directory)
        iconImage.size = NSSize(width: 32, height: 32)
        draggingItem.setDraggingFrame(bounds, contents: iconImage)

        let session = beginDraggingSession(with: [draggingItem], event: event, source: self)
        hasActiveDragSession = true
        #if DEBUG
        let itemCount = session.draggingPasteboard.pasteboardItems?.count ?? 0
        dlog("folder.dragStart dir=\(directory) pasteboardItems=\(itemCount)")
        #endif
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        // Always restore suppression on mouse-up; drag-session callbacks can be
        // skipped for non-started drags, which would otherwise leave suppression stuck.
        restoreWindowMovableStateIfNeeded()
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = buildPathMenu()
        // Pop up menu at bottom-left of icon (like native proxy icon)
        let menuLocation = NSPoint(x: 0, y: bounds.height)
        menu.popUp(positioning: nil, at: menuLocation, in: self)
    }

    private func buildPathMenu() -> NSMenu {
        let menu = NSMenu()
        let url = URL(fileURLWithPath: directory).standardized
        var pathComponents: [URL] = []

        // Build path from current directory up to root
        var current = url
        while current.path != "/" {
            pathComponents.append(current)
            current = current.deletingLastPathComponent()
        }
        pathComponents.append(URL(fileURLWithPath: "/"))

        // Add path components (current dir at top, root at bottom - matches native macOS)
        for pathURL in pathComponents {
            let icon = NSWorkspace.shared.icon(forFile: pathURL.path)
            icon.size = NSSize(width: 16, height: 16)

            let displayName: String
            if pathURL.path == "/" {
                // Use the volume name for root
                if let volumeName = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeNameKey]).volumeName {
                    displayName = volumeName
                } else {
                    displayName = String(localized: "sidebar.pathMenu.macintoshHD", defaultValue: "Macintosh HD")
                }
            } else {
                displayName = FileManager.default.displayName(atPath: pathURL.path)
            }

            let item = NSMenuItem(title: displayName, action: #selector(openPathComponent(_:)), keyEquivalent: "")
            item.target = self
            item.image = icon
            item.representedObject = pathURL
            menu.addItem(item)
        }

        // Add computer name at the bottom (like native proxy icon)
        let computerName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        let computerIcon = NSImage(named: NSImage.computerName) ?? NSImage()
        computerIcon.size = NSSize(width: 16, height: 16)

        let computerItem = NSMenuItem(title: computerName, action: #selector(openComputer(_:)), keyEquivalent: "")
        computerItem.target = self
        computerItem.image = computerIcon
        menu.addItem(computerItem)

        return menu
    }

    @objc private func openPathComponent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
    }

    @objc private func openComputer(_ sender: NSMenuItem) {
        // Open "Computer" view in Finder (shows all volumes)
        NSWorkspace.shared.open(URL(fileURLWithPath: "/", isDirectory: true))
    }

    private func restoreWindowMovableStateIfNeeded() {
        guard didArmWindowDragSuppression || previousWindowMovableState != nil else { return }
        let targetWindow = suppressedWindow ?? window
        let depthAfter = endWindowDragSuppression(window: targetWindow)
        restoreWindowDragging(window: targetWindow, previousMovableState: previousWindowMovableState)
        self.previousWindowMovableState = nil
        self.suppressedWindow = nil
        self.didArmWindowDragSuppression = false
        #if DEBUG
        let nowMovable = targetWindow.map { String($0.isMovable) } ?? "nil"
        dlog("folder.dragSuppression restore depth=\(depthAfter) nowMovable=\(nowMovable)")
        #endif
    }

    private func maybeDisableWindowDraggingEarly(trigger: String) {
        guard !didArmWindowDragSuppression else { return }
        guard let eventType = NSApp.currentEvent?.type,
              eventType == .leftMouseDown || eventType == .leftMouseDragged else {
            return
        }
        guard let currentWindow = window else { return }

        didArmWindowDragSuppression = true
        suppressedWindow = currentWindow
        let suppressionDepth = beginWindowDragSuppression(window: currentWindow) ?? 0
        if currentWindow.isMovable {
            previousWindowMovableState = temporarilyDisableWindowDragging(window: currentWindow)
        } else {
            previousWindowMovableState = nil
        }
        #if DEBUG
        let wasMovable = previousWindowMovableState.map(String.init) ?? "nil"
        let nowMovable = String(currentWindow.isMovable)
        dlog(
            "folder.dragSuppression trigger=\(trigger) event=\(eventType) depth=\(suppressionDepth) wasMovable=\(wasMovable) nowMovable=\(nowMovable)"
        )
        #endif
    }
}

func temporarilyDisableWindowDragging(window: NSWindow?) -> Bool? {
    guard let window else { return nil }
    let wasMovable = window.isMovable
    if wasMovable {
        window.isMovable = false
    }
    return wasMovable
}

func restoreWindowDragging(window: NSWindow?, previousMovableState: Bool?) {
    guard let window, let previousMovableState else { return }
    window.isMovable = previousMovableState
}

/// Wrapper view that tries NSGlassEffectView (macOS 26+) when available or requested
private struct SidebarVisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    let state: NSVisualEffectView.State
    let opacity: Double
    let tintColor: NSColor?
    let cornerRadius: CGFloat
    let preferLiquidGlass: Bool

    init(
        material: NSVisualEffectView.Material = .hudWindow,
        blendingMode: NSVisualEffectView.BlendingMode = .behindWindow,
        state: NSVisualEffectView.State = .active,
        opacity: Double = 1.0,
        tintColor: NSColor? = nil,
        cornerRadius: CGFloat = 0,
        preferLiquidGlass: Bool = false
    ) {
        self.material = material
        self.blendingMode = blendingMode
        self.state = state
        self.opacity = opacity
        self.tintColor = tintColor
        self.cornerRadius = cornerRadius
        self.preferLiquidGlass = preferLiquidGlass
    }

    static var liquidGlassAvailable: Bool {
        WindowGlassEffect.isAvailable
    }

    func makeNSView(context: Context) -> NSView {
        #if compiler(>=6.2)
        if preferLiquidGlass, #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: .zero)
            glass.autoresizingMask = [.width, .height]
            glass.wantsLayer = true
            return glass
        }
        #endif

        // Use NSVisualEffectView
        let view = NSVisualEffectView()
        view.autoresizingMask = [.width, .height]
        view.wantsLayer = true
        view.layerContentsRedrawPolicy = .onSetNeedsDisplay
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *), let glass = nsView as? NSGlassEffectView {
            glass.alphaValue = max(0.0, min(1.0, opacity))
            glass.cornerRadius = cornerRadius
            glass.tintColor = tintColor
            return
        }
        #endif

        if let visualEffect = nsView as? NSVisualEffectView {
            visualEffect.material = material
            visualEffect.blendingMode = blendingMode
            visualEffect.state = state
            visualEffect.alphaValue = max(0.0, min(1.0, opacity))
            visualEffect.layer?.cornerRadius = cornerRadius
            visualEffect.layer?.masksToBounds = cornerRadius > 0
            visualEffect.needsDisplay = true
        }
    }
}

/// Hosts the complete interactive sidebar directly on the window's glass backdrop
/// (inverted, Aside-style layout). No inner glass surface: the window contentView
/// glass provides the material, so this host is a transparent AppKit container
/// whose only job is zeroing the window safe area — the sidebar owns its own
/// titlebar-like header row.
private struct SidebarBackdropContentHost<Content: View>: NSViewRepresentable {
    let content: Content

    final class Coordinator {
        let hostingView: NSHostingView<Content>

        init(content: Content) {
            hostingView = NSHostingView(rootView: content)
            hostingView.autoresizingMask = [.width, .height]
            hostingView.wantsLayer = true
            hostingView.layer?.backgroundColor = NSColor.clear.cgColor
            // The sidebar owns its own titlebar-like header row; the window safe
            // area must not add a second inset on top of it.
            hostingView.safeAreaRegions = []
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(content: content)
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.hostingView
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.hostingView.rootView = content
    }
}

/// Owns the sidebar as a distinct native glass surface above the terminal-colored base plane.
struct SidebarSurface<Content: View>: View {
    let content: Content

    @AppStorage("sidebarMatchTerminalBackground") private var matchTerminalBackground = true
    @AppStorage("sidebarTintOpacity") private var sidebarTintOpacity = SidebarTintDefaults.opacity
    @AppStorage("sidebarTintHex") private var sidebarTintHex = SidebarTintDefaults.hex
    @AppStorage("sidebarTintHexLight") private var sidebarTintHexLight: String?
    @AppStorage("sidebarTintHexDark") private var sidebarTintHexDark: String?
    @AppStorage("sidebarMaterial") private var sidebarMaterial = SidebarMaterialOption.sidebar.rawValue
    @Environment(\.accessibilityReduceTransparency) private var accessibilityReduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @State private var terminalScheme: ColorScheme = SidebarTerminalAppearance.colorScheme()
    #if DEBUG
    // Makes the sidebar panel's corner radius re-render live when the Density
    // Debug window's sliders change (see WindowChrome.swift ChromeDensity).
    @ObservedObject private var densityStore = ChromeDensityStore.shared
    #endif

    private var standaloneCornerRadius: CGFloat { WindowGlassEffect.sidebarPanelCornerRadius }

    var body: some View {
        Group {
            if usesLocalNativeGlass {
                // Inverted layout: the sidebar sits directly on the window's glass
                // backdrop, which follows the SYSTEM appearance (light sidebar in
                // light mode) — only the content card and its pills stay
                // terminal-toned. No inner glass, no clip: window-level material.
                SidebarBackdropContentHost(content: content)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Fallback path (pre-26 / Reduce Transparency): the backdrop can
                // render terminal-colored when Match Terminal Background is on,
                // so labels must resolve contrast against the terminal, not the
                // system scheme.
                ZStack {
                    SidebarBackdrop()
                    if matchTerminalBackground {
                        content.environment(\.colorScheme, terminalScheme)
                    } else {
                        content
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: standaloneCornerRadius, style: .continuous))
            }
        }
        // Subscribed outside the glass branch so the scheme stays current while
        // Reduce Transparency toggles the branch off and back on.
        .onReceive(
            NotificationCenter.default.publisher(for: .ghosttyDefaultBackgroundDidChange)
        ) { _ in
            terminalScheme = SidebarTerminalAppearance.colorScheme()
        }
    }

    private var usesLocalNativeGlass: Bool {
        guard !accessibilityReduceTransparency,
              WindowGlassEffect.isAvailable
        else {
            return false
        }
        return true
    }

    private var resolvedTintColor: NSColor? {
        // Per-scheme hexes are only ever written by explicit user configuration
        // (the preset stamp never sets them) — honor those. Otherwise tint the
        // glass with the terminal background so the panel reads as the same
        // material family as the terminal, not a desktop-colored slab.
        let explicitHex: String? = terminalScheme == .dark ? sidebarTintHexDark : sidebarTintHexLight
        if let explicitHex, sidebarTintOpacity > 0, let color = NSColor(hex: explicitHex) {
            return color.withAlphaComponent(sidebarTintOpacity)
        }
        return GhosttyBackgroundTheme.currentColor().withAlphaComponent(0.5)
    }
}

/// Reads the leading inset required to clear traffic lights + left titlebar accessories.
final class TitlebarLeadingInsetPassthroughView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct TitlebarLeadingInsetReader: NSViewRepresentable {
    @Binding var inset: CGFloat

    func makeNSView(context: Context) -> NSView {
        let view = TitlebarLeadingInsetPassthroughView()
        view.setFrameSize(.zero)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            // Start past the traffic lights. Prefer the real zoom-button frame --
            // the unified-toolbar titlebar indents the buttons (zoom right edge
            // measured 78.75pt), so a fixed 78 would graze it. The 9pt gap after
            // the button matches the Tahoe traffic-light pitch rhythm.
            var leading: CGFloat = 88
            if let zoom = window.standardWindowButton(.zoomButton), zoom.superview != nil {
                let frameInWindow = zoom.convert(zoom.bounds, to: nil)
                leading = max(leading, frameInWindow.maxX + 9)
            }
            // Add width of all left-aligned titlebar accessories
            for accessory in window.titlebarAccessoryViewControllers
                where accessory.layoutAttribute == .leading || accessory.layoutAttribute == .left {
                leading += accessory.view.frame.width
            }
            leading += 0
            if leading != inset {
                inset = leading
            }
        }
    }
}

/// Sidebar background that uses the same technique as TitlebarLayerBackground:
/// fully opaque layer color + layer-level opacity. This matches how the terminal's
/// Metal surface composites its background.
private struct SidebarTerminalBackgroundView: NSViewRepresentable {
    let backgroundColor: NSColor
    let opacity: CGFloat

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = backgroundColor.withAlphaComponent(1.0).cgColor
        view.layer?.opacity = Float(opacity)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.layer?.backgroundColor = backgroundColor.withAlphaComponent(1.0).cgColor
        nsView.layer?.opacity = Float(opacity)
    }
}

/// The non-glass plane shared visually with terminal content beneath the floating sidebar.
struct SidebarTerminalBasePlane: View {
    @State private var backgroundColor = GhosttyApp.shared.defaultBackgroundColor
    @State private var backgroundOpacity = CGFloat(GhosttyApp.shared.effectiveTerminalBackgroundOpacity)

    var body: some View {
        SidebarTerminalBackgroundView(
            backgroundColor: backgroundColor,
            opacity: backgroundOpacity
        )
        .onReceive(NotificationCenter.default.publisher(for: .ghosttyDefaultBackgroundDidChange)) { _ in
            backgroundColor = GhosttyApp.shared.defaultBackgroundColor
            backgroundOpacity = CGFloat(GhosttyApp.shared.effectiveTerminalBackgroundOpacity)
        }
    }
}

struct SidebarBackdrop: View {
    @AppStorage("sidebarMatchTerminalBackground") private var matchTerminalBackground = true
    @AppStorage("sidebarTintOpacity") private var sidebarTintOpacity = SidebarTintDefaults.opacity
    @AppStorage("sidebarTintHex") private var sidebarTintHex = SidebarTintDefaults.hex
    @AppStorage("sidebarTintHexLight") private var sidebarTintHexLight: String?
    @AppStorage("sidebarTintHexDark") private var sidebarTintHexDark: String?
    @AppStorage("sidebarMaterial") private var sidebarMaterial = SidebarMaterialOption.sidebar.rawValue
    @AppStorage("sidebarBlendMode") private var sidebarBlendMode = SidebarBlendModeOption.withinWindow.rawValue
    @AppStorage("sidebarState") private var sidebarState = SidebarStateOption.followWindow.rawValue
    @AppStorage("sidebarBlurOpacity") private var sidebarBlurOpacity = 1.0
    @Environment(\.accessibilityReduceTransparency) private var accessibilityReduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @State private var terminalBackgroundColor: NSColor = GhosttyApp.shared.defaultBackgroundColor

    private let standaloneCornerRadius: CGFloat = 18

    var body: some View {
        if matchTerminalBackground {
            // The terminal background is provided by a single CALayer, so
            // the sidebar matches the opacity applied to that layer.
            let alpha = CGFloat(GhosttyApp.shared.effectiveTerminalBackgroundOpacity)
            return AnyView(
                SidebarTerminalBackgroundView(
                    backgroundColor: terminalBackgroundColor,
                    opacity: alpha
                )
                .onReceive(NotificationCenter.default.publisher(for: .ghosttyDefaultBackgroundDidChange)) { _ in
                    terminalBackgroundColor = GhosttyApp.shared.defaultBackgroundColor
                }
            )
        }

        let usesWholeWindowGlass = cmuxShouldUseTransparentBackgroundWindow()

        if accessibilityReduceTransparency {
            return AnyView(adaptiveSurface(opaque: true))
        }

        if usesWholeWindowGlass {
            return AnyView(adaptiveSurface(opaque: false))
        }

        let materialOption = SidebarMaterialOption(rawValue: sidebarMaterial)
        let blendingMode = SidebarBlendModeOption(rawValue: sidebarBlendMode)?.mode ?? .behindWindow
        let state = SidebarStateOption(rawValue: sidebarState)?.state ?? .active
        let resolvedHex: String = {
            if colorScheme == .dark, let dark = sidebarTintHexDark {
                return dark
            } else if colorScheme == .light, let light = sidebarTintHexLight {
                return light
            }
            return sidebarTintHex
        }()
        let tintColor = (NSColor(hex: resolvedHex) ?? NSColor(hex: sidebarTintHex) ?? .controlAccentColor)
            .withAlphaComponent(sidebarTintOpacity)
        let sidebarGlassOverride = ProgramaGlassSettings.startupOverride(for: .sidebar)
        let useLiquidGlass = sidebarGlassOverride ?? materialOption?.usesLiquidGlass ?? false
        let resolvedMaterial: NSVisualEffectView.Material? = sidebarGlassOverride == true
            ? .underWindowBackground
            : materialOption?.material

        return AnyView(
            ZStack {
                if let material = resolvedMaterial {
                    SidebarVisualEffectBackground(
                        material: material,
                        blendingMode: blendingMode,
                        state: state,
                        opacity: sidebarBlurOpacity,
                        tintColor: tintColor,
                        cornerRadius: standaloneCornerRadius,
                        preferLiquidGlass: useLiquidGlass
                    )
                    // Tint overlay for NSVisualEffectView fallback
                    if !useLiquidGlass {
                        Color(nsColor: tintColor)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: standaloneCornerRadius, style: .continuous))
        )
    }

    private func adaptiveSurface(opaque: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: standaloneCornerRadius, style: .continuous)
        let baseColor = Color(nsColor: .windowBackgroundColor)
        let baseOpacity = colorScheme == .dark ? 0.48 : 0.62
        let tintOpacity = min(sidebarTintOpacity, opaque ? 0.16 : 0.12)
        let resolvedHex: String = {
            if colorScheme == .dark, let dark = sidebarTintHexDark {
                return dark
            } else if colorScheme == .light, let light = sidebarTintHexLight {
                return light
            }
            return sidebarTintHex
        }()
        let tintColor = (NSColor(hex: resolvedHex) ?? NSColor(hex: sidebarTintHex) ?? .controlAccentColor)
            .withAlphaComponent(tintOpacity)
        let outlineWidth = 1 / max(displayScale, 1)

        return ZStack {
            shape.fill(opaque ? baseColor : baseColor.opacity(baseOpacity))
            if tintOpacity > 0 {
                shape.fill(Color(nsColor: tintColor))
            }
        }
        .overlay {
            shape.strokeBorder(
                Color(nsColor: .separatorColor).opacity(opaque ? 0.72 : 0.58),
                lineWidth: outlineWidth
            )
        }
        .shadow(
            color: Color(nsColor: .shadowColor).opacity(colorScheme == .dark ? 0.2 : 0.12),
            radius: 8,
            y: 2
        )
    }
}

enum SidebarMaterialOption: String, CaseIterable, Identifiable {
    case none
    case liquidGlass  // macOS 26+ NSGlassEffectView
    case sidebar
    case hudWindow
    case menu
    case popover
    case underWindowBackground
    case windowBackground
    case contentBackground
    case fullScreenUI
    case sheet
    case headerView
    case toolTip

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return String(localized: "settings.material.none", defaultValue: "None")
        case .liquidGlass: return String(localized: "settings.material.liquidGlass", defaultValue: "Liquid Glass (macOS 26+)")
        case .sidebar: return String(localized: "settings.material.sidebar", defaultValue: "Sidebar")
        case .hudWindow: return String(localized: "settings.material.hudWindow", defaultValue: "HUD Window")
        case .menu: return String(localized: "settings.material.menu", defaultValue: "Menu")
        case .popover: return String(localized: "settings.material.popover", defaultValue: "Popover")
        case .underWindowBackground: return String(localized: "settings.material.underWindow", defaultValue: "Under Window")
        case .windowBackground: return String(localized: "settings.material.windowBackground", defaultValue: "Window Background")
        case .contentBackground: return String(localized: "settings.material.contentBackground", defaultValue: "Content Background")
        case .fullScreenUI: return String(localized: "settings.material.fullScreenUI", defaultValue: "Full Screen UI")
        case .sheet: return String(localized: "settings.material.sheet", defaultValue: "Sheet")
        case .headerView: return String(localized: "settings.material.headerView", defaultValue: "Header View")
        case .toolTip: return String(localized: "settings.material.toolTip", defaultValue: "Tool Tip")
        }
    }

    /// Returns true if this option should use NSGlassEffectView (macOS 26+)
    var usesLiquidGlass: Bool {
        self == .liquidGlass
    }

    var material: NSVisualEffectView.Material? {
        switch self {
        case .none: return nil
        case .liquidGlass: return .underWindowBackground  // Fallback material
        case .sidebar: return .sidebar
        case .hudWindow: return .hudWindow
        case .menu: return .menu
        case .popover: return .popover
        case .underWindowBackground: return .underWindowBackground
        case .windowBackground: return .windowBackground
        case .contentBackground: return .contentBackground
        case .fullScreenUI: return .fullScreenUI
        case .sheet: return .sheet
        case .headerView: return .headerView
        case .toolTip: return .toolTip
        }
    }
}

enum SidebarBlendModeOption: String, CaseIterable, Identifiable {
    case behindWindow
    case withinWindow

    var id: String { rawValue }

    var title: String {
        switch self {
        case .behindWindow: return String(localized: "settings.blendMode.behindWindow", defaultValue: "Behind Window")
        case .withinWindow: return String(localized: "settings.blendMode.withinWindow", defaultValue: "Within Window")
        }
    }

    var mode: NSVisualEffectView.BlendingMode {
        switch self {
        case .behindWindow: return .behindWindow
        case .withinWindow: return .withinWindow
        }
    }
}

enum SidebarStateOption: String, CaseIterable, Identifiable {
    case active
    case inactive
    case followWindow

    var id: String { rawValue }

    var title: String {
        switch self {
        case .active: return String(localized: "settings.state.active", defaultValue: "Active")
        case .inactive: return String(localized: "settings.state.inactive", defaultValue: "Inactive")
        case .followWindow: return String(localized: "settings.state.followWindow", defaultValue: "Follow Window")
        }
    }

    var state: NSVisualEffectView.State {
        switch self {
        case .active: return .active
        case .inactive: return .inactive
        case .followWindow: return .followsWindowActiveState
        }
    }
}

enum SidebarTintDefaults {
    static let hex = "#000000"
    static let opacity = 0.18
}

enum SidebarPresetOption: String, CaseIterable, Identifiable {
    case liquidGlass
    case nativeSidebar
    case glassBehind
    case softBlur
    case popoverGlass
    case hudGlass
    case underWindow

    var id: String { rawValue }

    var title: String {
        switch self {
        case .liquidGlass: return String(localized: "settings.preset.liquidGlass", defaultValue: "Liquid Glass")
        case .nativeSidebar: return String(localized: "settings.preset.nativeSidebar", defaultValue: "Native Sidebar")
        case .glassBehind: return String(localized: "settings.preset.raycastGray", defaultValue: "Raycast Gray")
        case .softBlur: return String(localized: "settings.preset.softBlur", defaultValue: "Soft Blur")
        case .popoverGlass: return String(localized: "settings.preset.popoverGlass", defaultValue: "Popover Glass")
        case .hudGlass: return String(localized: "settings.preset.hudGlass", defaultValue: "HUD Glass")
        case .underWindow: return String(localized: "settings.preset.underWindow", defaultValue: "Under Window")
        }
    }

    var material: SidebarMaterialOption {
        switch self {
        case .liquidGlass: return .liquidGlass
        case .nativeSidebar: return .sidebar
        case .glassBehind: return .sidebar
        case .softBlur: return .sidebar
        case .popoverGlass: return .popover
        case .hudGlass: return .hudWindow
        case .underWindow: return .underWindowBackground
        }
    }

    var blendMode: SidebarBlendModeOption {
        switch self {
        case .liquidGlass: return .withinWindow
        case .nativeSidebar: return .withinWindow
        case .glassBehind: return .behindWindow
        case .softBlur: return .behindWindow
        case .popoverGlass: return .behindWindow
        case .hudGlass: return .withinWindow
        case .underWindow: return .withinWindow
        }
    }

    var state: SidebarStateOption {
        switch self {
        case .liquidGlass: return .followWindow
        case .nativeSidebar: return .followWindow
        case .glassBehind: return .active
        case .softBlur: return .active
        case .popoverGlass: return .active
        case .hudGlass: return .active
        case .underWindow: return .followWindow
        }
    }

    var tintHex: String {
        switch self {
        case .liquidGlass: return "#000000"
        case .nativeSidebar: return "#000000"
        case .glassBehind: return "#000000"
        case .softBlur: return "#000000"
        case .popoverGlass: return "#000000"
        case .hudGlass: return "#000000"
        case .underWindow: return "#000000"
        }
    }

    var tintOpacity: Double {
        switch self {
        case .liquidGlass: return 0.0
        case .nativeSidebar: return 0.18
        case .glassBehind: return 0.36
        case .softBlur: return 0.28
        case .popoverGlass: return 0.10
        case .hudGlass: return 0.62
        case .underWindow: return 0.14
        }
    }

    var cornerRadius: Double {
        switch self {
        // Native glass applies this only to the terminal-facing edge. The NSWindow mask
        // continues to own the flush outer corners, avoiding a duplicate perimeter.
        case .liquidGlass: return 18.0
        case .nativeSidebar: return 0.0
        case .glassBehind: return 0.0
        case .softBlur: return 0.0
        case .popoverGlass: return 10.0
        case .hudGlass: return 10.0
        case .underWindow: return 6.0
        }
    }

    var blurOpacity: Double {
        switch self {
        case .liquidGlass: return 1.0
        case .nativeSidebar: return 1.0
        case .glassBehind: return 0.6
        case .softBlur: return 0.45
        case .popoverGlass: return 0.9
        case .hudGlass: return 0.98
        case .underWindow: return 0.9
        }
    }
}

extension NSColor {
    func hexString(includeAlpha: Bool = false) -> String {
        let color = usingColorSpace(.sRGB) ?? self
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let redByte = min(255, max(0, Int((red * 255).rounded())))
        let greenByte = min(255, max(0, Int((green * 255).rounded())))
        let blueByte = min(255, max(0, Int((blue * 255).rounded())))
        if includeAlpha {
            let alphaByte = min(255, max(0, Int((alpha * 255).rounded())))
            return String(format: "#%02X%02X%02X%02X", redByte, greenByte, blueByte, alphaByte)
        }
        return String(format: "#%02X%02X%02X", redByte, greenByte, blueByte)
    }
}
