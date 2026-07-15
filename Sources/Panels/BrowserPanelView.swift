import Bonsplit
import SwiftUI
import WebKit
import AppKit
import ObjectiveC

private var programaBrowserPanelNeedsRenderingStateReattachKey: UInt8 = 0

private func browserPanelViewObjectID(_ object: AnyObject?) -> String {
    guard let object else { return "nil" }
    return String(describing: Unmanaged.passUnretained(object).toOpaque())
}

private func browserPanelViewRectDescription(_ rect: NSRect) -> String {
    String(format: "%.1f,%.1f %.1fx%.1f", rect.origin.x, rect.origin.y, rect.width, rect.height)
}

private extension NSObject {
    @discardableResult
    func browserPanelCallVoidIfAvailable(_ rawSelector: String) -> Bool {
        let selector = NSSelectorFromString(rawSelector)
        guard responds(to: selector) else { return false }
        typealias Fn = @convention(c) (AnyObject, Selector) -> Void
        let fn = unsafeBitCast(method(for: selector), to: Fn.self)
        fn(self, selector)
        return true
    }
}

// Not `private`: programaBrowserPanelNotifyHidden/Reattach/ForceRenderingStateRefresh below are
// called from WebViewRepresentable.swift (file-reorg for #99). The genuinely private members
// (programaBrowserPanelNeedsRenderingStateReattach, programaBrowserPanelApplyRenderingStateRefresh)
// keep their explicit `private` modifiers below and stay file-scoped to BrowserPanelView.swift.
extension WKWebView {
    private var programaBrowserPanelNeedsRenderingStateReattach: Bool {
        get {
            (objc_getAssociatedObject(self, &programaBrowserPanelNeedsRenderingStateReattachKey) as? NSNumber)?
                .boolValue ?? false
        }
        set {
            objc_setAssociatedObject(
                self,
                &programaBrowserPanelNeedsRenderingStateReattachKey,
                NSNumber(value: newValue),
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
    }

    var programaBrowserPanelRequiresRenderingStateReattach: Bool {
        programaBrowserPanelNeedsRenderingStateReattach
    }

    private func programaBrowserPanelApplyRenderingStateRefresh(
        reason: String,
        force: Bool
    ) {
        guard force || programaBrowserPanelNeedsRenderingStateReattach else { return }
        guard window != nil else { return }
        programaBrowserPanelNeedsRenderingStateReattach = false

        let firedSelectors = [
            "viewDidUnhide",
            "_enterInWindow",
            "_endDeferringViewInWindowChangesSync",
        ].filter {
            browserPanelCallVoidIfAvailable($0)
        }

        if let scrollView = enclosingScrollView {
            scrollView.needsLayout = true
            scrollView.needsDisplay = true
            scrollView.setNeedsDisplay(scrollView.bounds)
            scrollView.contentView.needsLayout = true
            scrollView.contentView.needsDisplay = true
        }

        needsLayout = true
        needsDisplay = true
        setNeedsDisplay(bounds)

#if DEBUG
        if !firedSelectors.isEmpty {
            dlog(
                "\(force ? "browser.localHost.webview.forceRefresh" : "browser.localHost.webview.reattach") " +
                "web=\(browserPanelViewObjectID(self)) " +
                "reason=\(reason) selectors=\(firedSelectors.joined(separator: ",")) " +
                "frame=\(browserPanelViewRectDescription(frame))"
            )
        }
#endif
    }

    func programaBrowserPanelNotifyHidden(reason: String) {
        programaBrowserPanelNeedsRenderingStateReattach = true
        let firedSelectors = ["viewDidHide", "_exitInWindow"].filter {
            browserPanelCallVoidIfAvailable($0)
        }
#if DEBUG
        if !firedSelectors.isEmpty {
            dlog(
                "browser.localHost.webview.hidden web=\(browserPanelViewObjectID(self)) " +
                "reason=\(reason) selectors=\(firedSelectors.joined(separator: ","))"
            )
        }
#endif
    }

    func programaBrowserPanelReattachRenderingState(reason: String) {
        programaBrowserPanelApplyRenderingStateRefresh(reason: reason, force: false)
    }

    func programaBrowserPanelForceRenderingStateRefresh(reason: String) {
        programaBrowserPanelApplyRenderingStateRefresh(reason: reason, force: true)
    }
}

/// View for rendering a browser panel with address bar
struct BrowserPanelView: View {
    @ObservedObject var panel: BrowserPanel
    @ObservedObject private var browserProfileStore = BrowserProfileStore.shared
    let paneId: PaneID
    let isFocused: Bool
    let isVisibleInUI: Bool
    let portalPriority: Int
    let onRequestPanelFocus: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.paneDropZone) private var paneDropZone
    @State private var omnibarState = OmnibarState()
    @State private var addressBarFocused: Bool = false
    @AppStorage(BrowserSearchSettings.searchEngineKey) private var searchEngineRaw = BrowserSearchSettings.defaultSearchEngine.rawValue
    @AppStorage(BrowserSearchSettings.searchSuggestionsEnabledKey) private var searchSuggestionsEnabledStorage = BrowserSearchSettings.defaultSearchSuggestionsEnabled
    @AppStorage(BrowserDevToolsButtonDebugSettings.iconNameKey) private var devToolsIconNameRaw = BrowserDevToolsButtonDebugSettings.defaultIcon.rawValue
    @AppStorage(BrowserDevToolsButtonDebugSettings.iconColorKey) private var devToolsIconColorRaw = BrowserDevToolsButtonDebugSettings.defaultColor.rawValue
    @AppStorage(BrowserToolbarAccessorySpacingDebugSettings.key) private var browserToolbarAccessorySpacingRaw = BrowserToolbarAccessorySpacingDebugSettings.defaultSpacing
    @AppStorage(BrowserProfilePopoverDebugSettings.horizontalPaddingKey)
    private var browserProfilePopoverHorizontalPaddingRaw = BrowserProfilePopoverDebugSettings.defaultHorizontalPadding
    @AppStorage(BrowserProfilePopoverDebugSettings.verticalPaddingKey)
    private var browserProfilePopoverVerticalPaddingRaw = BrowserProfilePopoverDebugSettings.defaultVerticalPadding
    @AppStorage(BrowserThemeSettings.modeKey) private var browserThemeModeRaw = BrowserThemeSettings.defaultMode.rawValue
    @AppStorage(BrowserImportHintSettings.showOnBlankTabsKey) private var showBrowserImportHintOnBlankTabs = BrowserImportHintSettings.defaultShowOnBlankTabs
    @AppStorage(BrowserImportHintSettings.dismissedKey) private var isBrowserImportHintDismissed = BrowserImportHintSettings.defaultDismissed
    @ObservedObject private var keyboardShortcutSettingsObserver = KeyboardShortcutSettingsObserver.shared
    @State private var suggestionTask: Task<Void, Never>?
    @State private var isLoadingRemoteSuggestions: Bool = false
    @State private var latestRemoteSuggestionQuery: String = ""
    @State private var latestRemoteSuggestions: [String] = []
    @State private var emptyStateImportBrowsers: [InstalledBrowserCandidate] = []
    @State private var emptyStateImportBrowserRefreshTask: Task<Void, Never>?
    @State private var emptyStateImportBrowserRefreshGeneration: UInt64 = 0
    @State private var inlineCompletion: OmnibarInlineCompletion?
    @State private var omnibarSelectionRange: NSRange = NSRange(location: NSNotFound, length: 0)
    @State private var omnibarHasMarkedText: Bool = false
    @State private var suppressNextFocusLostRevert: Bool = false
    @State private var focusFlashOpacity: Double = 0.0
    @State private var focusFlashAnimationGeneration: Int = 0
    @State private var omnibarPillFrame: CGRect = .zero
    @State private var addressBarHeight: CGFloat = 0
    @State private var isBrowserImportHintPopoverPresented = false
    @State private var lastHandledAddressBarFocusRequestId: UUID?
    @State private var pendingAddressBarFocusRetryRequestId: UUID?
    @State private var pendingAddressBarFocusRetryGeneration: UInt64 = 0
    @State private var isBrowserProfileMenuPresented = false
    @State private var isBrowserThemeMenuPresented = false
    @State private var browserChromeStyle = BrowserChromeStyle.resolve(
        for: .light,
        themeBackgroundColor: GhosttyBackgroundTheme.currentColor()
    )
    // Keep this below half of the compact omnibar height so it reads as a squircle,
    // not a capsule.
    private let omnibarPillCornerRadius: CGFloat = 10
    private let addressBarButtonSize: CGFloat = 22
    private let addressBarVerticalPadding: CGFloat = 4
    private let devToolsButtonIconSize: CGFloat = 11

    private var searchEngine: BrowserSearchEngine {
        BrowserSearchEngine(rawValue: searchEngineRaw) ?? BrowserSearchSettings.defaultSearchEngine
    }

    private var searchSuggestionsEnabled: Bool {
        // Touch @AppStorage so SwiftUI invalidates this view when settings change.
        _ = searchSuggestionsEnabledStorage
        return BrowserSearchSettings.currentSearchSuggestionsEnabled(defaults: .standard)
    }

    private var remoteSuggestionsEnabled: Bool {
        // Deterministic UI-test hook: force remote path on even if a persisted
        // setting disabled suggestions in previous sessions.
        if ProcessInfo.processInfo.environment["PROGRAMA_UI_TEST_REMOTE_SUGGESTIONS_JSON"] != nil ||
            UserDefaults.standard.string(forKey: "PROGRAMA_UI_TEST_REMOTE_SUGGESTIONS_JSON") != nil {
            return true
        }
        // Keep UI tests deterministic by disabling network suggestions when requested.
        if ProcessInfo.processInfo.environment["PROGRAMA_UI_TEST_DISABLE_REMOTE_SUGGESTIONS"] == "1" {
            return false
        }
        return searchSuggestionsEnabled
    }

    private var devToolsIconOption: BrowserDevToolsIconOption {
        BrowserDevToolsIconOption(rawValue: devToolsIconNameRaw) ?? BrowserDevToolsButtonDebugSettings.defaultIcon
    }

    private var devToolsColorOption: BrowserDevToolsIconColorOption {
        BrowserDevToolsIconColorOption(rawValue: devToolsIconColorRaw) ?? BrowserDevToolsButtonDebugSettings.defaultColor
    }

    private var browserThemeMode: BrowserThemeMode {
        BrowserThemeSettings.mode(for: browserThemeModeRaw)
    }

    private var browserImportHintPresentation: BrowserImportHintPresentation {
        BrowserImportHintPresentation(
            showOnBlankTabs: showBrowserImportHintOnBlankTabs,
            isDismissed: isBrowserImportHintDismissed
        )
    }

    private var browserToolbarAccessorySpacing: CGFloat {
        CGFloat(BrowserToolbarAccessorySpacingDebugSettings.resolved(browserToolbarAccessorySpacingRaw))
    }

    private var browserProfilePopoverHorizontalPadding: CGFloat {
        CGFloat(BrowserProfilePopoverDebugSettings.resolvedHorizontalPadding(browserProfilePopoverHorizontalPaddingRaw))
    }

    private var browserProfilePopoverVerticalPadding: CGFloat {
        CGFloat(BrowserProfilePopoverDebugSettings.resolvedVerticalPadding(browserProfilePopoverVerticalPaddingRaw))
    }

    private var browserChromeBackground: Color {
        Color(nsColor: browserChromeStyle.backgroundColor)
    }

    private var browserChromeBackgroundColor: NSColor {
        browserChromeStyle.backgroundColor
    }

    private var browserChromeColorScheme: ColorScheme {
        browserChromeStyle.colorScheme
    }

    private var browserContentAccessibilityIdentifier: String {
        "BrowserPanelContent.\(panel.id.uuidString)"
    }

    private var omnibarPillBackgroundColor: NSColor {
        browserChromeStyle.omnibarPillBackgroundColor
    }

    private var developerToolsButtonHelp: String {
        let base = String(localized: "browser.toggleDevTools", defaultValue: "Toggle Developer Tools")
        let _ = keyboardShortcutSettingsObserver.revision
        return "\(base) (\(KeyboardShortcutSettings.shortcut(for: .toggleBrowserDeveloperTools).displayString))"
    }

    private var browserImportHintSummary: String {
        InstalledBrowserDetector.summaryText(for: emptyStateImportBrowsers)
    }

    private var shouldShowToolbarImportHintChip: Bool {
        shouldShowEmptyStateImportOverlay && browserImportHintPresentation.blankTabPlacement == .toolbarChip
    }

    private var owningWorkspace: Workspace? {
        guard let app = AppDelegate.shared,
              let manager = app.tabManagerFor(tabId: panel.workspaceId) else {
            return nil
        }
        return manager.tabs.first(where: { $0.id == panel.workspaceId })
    }

    private var isCurrentPaneOwner: Bool {
        guard let currentPaneId = owningWorkspace?.paneId(forPanelId: panel.id) else {
            return false
        }
        return currentPaneId.id == paneId.id
    }

    private var layeredBrowserContent: some View {
        // Layering contract: browser Cmd+F UI is mounted in the portal-hosted AppKit
        // container. Rendering it here can hide it behind the portal-hosted WKWebView.
        VStack(spacing: 0) {
            addressBar
                .fixedSize(horizontal: false, vertical: true)
            webView
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay {
            // Keep Cmd+F usable when the browser is still in the empty new-tab
            // state (no WKWebView mounted yet). WebView-backed cases are hosted
            // in AppKit by WindowBrowserPortal to avoid layering/clipping issues.
            if !panel.shouldRenderWebView, let searchState = panel.searchState {
                BrowserSearchOverlay(
                    panelId: panel.id,
                    searchState: searchState,
                    focusRequestGeneration: panel.searchFocusRequestGeneration,
                    canApplyFocusRequest: { generation in
                        canApplyBrowserFindFieldFocusRequest(generation)
                    },
                    onNext: { panel.findNext() },
                    onPrevious: { panel.findPrevious() },
                    onClose: { panel.hideFind() },
                    onFieldDidFocus: { panel.noteFindFieldFocused() }
                )
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: FocusFlashPattern.ringCornerRadius)
                .stroke(programaAccentColor().opacity(focusFlashOpacity), lineWidth: 3)
                .shadow(color: programaAccentColor().opacity(focusFlashOpacity * 0.35), radius: 10)
                .padding(FocusFlashPattern.ringInset)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .topLeading) {
            if addressBarFocused, !omnibarState.suggestions.isEmpty, omnibarPillFrame.width > 0 {
                OmnibarSuggestionsView(
                    engineName: searchEngine.displayName,
                    items: omnibarState.suggestions,
                    selectedIndex: omnibarState.selectedSuggestionIndex,
                    isLoadingRemoteSuggestions: isLoadingRemoteSuggestions,
                    searchSuggestionsEnabled: remoteSuggestionsEnabled,
                    onCommit: { item in
                        commitSuggestion(item)
                    },
                    onHighlight: { idx in
                        let effects = omnibarReduce(state: &omnibarState, event: .highlightIndex(idx))
                        applyOmnibarEffects(effects)
                    }
                )
                .frame(width: omnibarPillFrame.width)
                .offset(x: omnibarPillFrame.minX, y: omnibarPillFrame.maxY + 3)
                .zIndex(1000)
                .environment(\.colorScheme, browserChromeColorScheme)
            }
        }
    }

    var body: some View {
        browserNotificationContent
    }

    private var browserClickContent: some View {
        layeredBrowserContent
        .coordinateSpace(name: "BrowserPanelViewSpace")
        .onPreferenceChange(OmnibarPillFramePreferenceKey.self) { frame in
            omnibarPillFrame = frame
        }
        .onPreferenceChange(BrowserAddressBarHeightPreferenceKey.self) { height in
            addressBarHeight = height
        }
        .onReceive(NotificationCenter.default.publisher(for: .webViewDidReceiveClick).filter { [weak panel] note in
            // Only handle clicks from our own webview.
            guard let webView = note.object as? ProgramaWebView else { return false }
            return webView === panel?.webView
        }) { _ in
#if DEBUG
            dlog(
                "browser.focus.clickIntent panel=\(panel.id.uuidString.prefix(5)) " +
                "isFocused=\(isFocused ? 1 : 0) " +
                "addressFocused=\(addressBarFocused ? 1 : 0)"
            )
#endif
            if addressBarFocused {
#if DEBUG
                logBrowserFocusState(event: "addressBarFocus.webViewClickBlur")
#endif
                setAddressBarFocused(false, reason: "webView.clickIntent")
            }
            if !isFocused {
                onRequestPanelFocus()
            }
        }
    }

    private var browserLifecycleContent: some View {
        browserClickContent
        .onAppear {
            UserDefaults.standard.register(defaults: [
                BrowserSearchSettings.searchEngineKey: BrowserSearchSettings.defaultSearchEngine.rawValue,
                BrowserSearchSettings.searchSuggestionsEnabledKey: BrowserSearchSettings.defaultSearchSuggestionsEnabled,
                BrowserToolbarAccessorySpacingDebugSettings.key: BrowserToolbarAccessorySpacingDebugSettings.defaultSpacing,
                BrowserProfilePopoverDebugSettings.horizontalPaddingKey: BrowserProfilePopoverDebugSettings.defaultHorizontalPadding,
                BrowserProfilePopoverDebugSettings.verticalPaddingKey: BrowserProfilePopoverDebugSettings.defaultVerticalPadding,
                BrowserThemeSettings.modeKey: BrowserThemeSettings.defaultMode.rawValue,
            ])
            refreshBrowserChromeStyle()
            let resolvedThemeMode = BrowserThemeSettings.mode(defaults: .standard)
            if browserThemeModeRaw != resolvedThemeMode.rawValue {
                browserThemeModeRaw = resolvedThemeMode.rawValue
            }
            let resolvedToolbarAccessorySpacing = BrowserToolbarAccessorySpacingDebugSettings.resolved(browserToolbarAccessorySpacingRaw)
            if browserToolbarAccessorySpacingRaw != resolvedToolbarAccessorySpacing {
                browserToolbarAccessorySpacingRaw = resolvedToolbarAccessorySpacing
            }
            let resolvedProfilePopoverHorizontalPadding = BrowserProfilePopoverDebugSettings.resolvedHorizontalPadding(browserProfilePopoverHorizontalPaddingRaw)
            if browserProfilePopoverHorizontalPaddingRaw != resolvedProfilePopoverHorizontalPadding {
                browserProfilePopoverHorizontalPaddingRaw = resolvedProfilePopoverHorizontalPadding
            }
            let resolvedProfilePopoverVerticalPadding = BrowserProfilePopoverDebugSettings.resolvedVerticalPadding(browserProfilePopoverVerticalPaddingRaw)
            if browserProfilePopoverVerticalPaddingRaw != resolvedProfilePopoverVerticalPadding {
                browserProfilePopoverVerticalPaddingRaw = resolvedProfilePopoverVerticalPadding
            }
            panel.refreshAppearanceDrivenColors()
            panel.setBrowserThemeMode(browserThemeMode)
            applyPendingAddressBarFocusRequestIfNeeded()
            syncURLFromPanel()
            // If the browser surface is focused but has no URL loaded yet, auto-focus the omnibar.
            autoFocusOmnibarIfBlank()
            syncWebViewResponderPolicyWithViewState(reason: "onAppear")
            refreshEmptyStateImportBrowsers()
            panel.historyStore.loadIfNeeded()
#if DEBUG
            logBrowserFocusState(event: "view.onAppear")
#endif
        }
        .onChange(of: panel.focusFlashToken) {
            triggerFocusFlashAnimation()
        }
        .onChange(of: panel.currentURL) {
            let addressWasEmpty = omnibarState.buffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            syncURLFromPanel()
            // If we auto-focused a blank omnibar but then a URL loads programmatically, move focus
            // into WebKit unless the user had already started typing.
            if addressBarFocused,
               !panel.shouldSuppressWebViewFocus(),
               addressWasEmpty,
               !isWebViewBlank() {
                setAddressBarFocused(false, reason: "panel.currentURL.loaded")
            }
            if isWebViewBlank() {
                refreshEmptyStateImportBrowsers()
            }
            panel.resetReactGrabState(
                preserveRoundTrip: true,
                reason: "panel.currentURL.changed"
            )
        }
        .onChange(of: browserThemeModeRaw) {
            let normalizedMode = BrowserThemeSettings.mode(for: browserThemeModeRaw)
            if browserThemeModeRaw != normalizedMode.rawValue {
                browserThemeModeRaw = normalizedMode.rawValue
            }
            panel.setBrowserThemeMode(normalizedMode)
        }
        .onChange(of: colorScheme) {
            refreshBrowserChromeStyle()
            panel.refreshAppearanceDrivenColors()
        }
        .onChange(of: panel.pendingAddressBarFocusRequestId) {
            applyPendingAddressBarFocusRequestIfNeeded()
        }
        .onChange(of: panel.profileID) {
            panel.historyStore.loadIfNeeded()
            if addressBarFocused {
                refreshSuggestions()
            }
        }
    }

    private var browserFocusContent: some View {
        browserLifecycleContent
        .onChange(of: isVisibleInUI) { _, visibleInUI in
            if visibleInUI {
                panel.cancelPendingDeveloperToolsVisibilityLossCheck()
                return
            }
            if panel.shouldUseLocalInlineDeveloperToolsHosting() {
                // Workspace switches keep the attached inspector alive off-screen.
                // Treating that hide as a manual X-close can clear the restore intent
                // before the original local-inline host becomes visible again.
                panel.cancelPendingDeveloperToolsVisibilityLossCheck()
                return
            }
            // Pane/workspace churn can briefly mark the browser hidden before the
            // final host settles. Only treat a stable hide as a signal to consume
            // an attached-inspector X-close.
            panel.scheduleDeveloperToolsVisibilityLossCheck()
        }
        .onChange(of: isFocused) { _, focused in
#if DEBUG
            logBrowserFocusState(
                event: "panelFocus.onChange",
                detail: "next=\(focused ? 1 : 0)"
            )
#endif
            // Ensure this view doesn't retain focus while hidden (bonsplit keepAllAlive).
            if focused {
                applyPendingAddressBarFocusRequestIfNeeded()
                autoFocusOmnibarIfBlank()
            } else {
                panel.invalidateAddressBarPageFocusRestoreAttempts()
                hideSuggestions()
                setAddressBarFocused(false, reason: "panelFocus.onChange.unfocused")
                // Surface switches in split layouts can keep the browser visible, so
                // `isVisibleInUI` never flips to false. Check for an attached-inspector
                // X-close when focus leaves as well so the persisted intent stays in sync.
                DispatchQueue.main.async {
                    guard isVisibleInUI else { return }
                    panel.scheduleDeveloperToolsVisibilityLossCheck()
                }
            }
            syncWebViewResponderPolicyWithViewState(
                reason: "panelFocusChanged",
                isPanelFocusedOverride: focused
            )
        }
        .onChange(of: addressBarFocused) { _, focused in
#if DEBUG
            logBrowserFocusState(
                event: "addressBarFocus.onChange",
                detail: "next=\(focused ? 1 : 0)"
            )
#endif
            let urlString = panel.preferredURLStringForOmnibar() ?? ""
            if focused {
                panel.beginSuppressWebViewFocusForAddressBar()
                NotificationCenter.default.post(name: .browserDidFocusAddressBar, object: panel.id)
                // Only request panel focus if this pane isn't currently focused. When already
                // focused (e.g. Cmd+L), forcing focus can steal first responder back to WebKit.
                if !isFocused {
#if DEBUG
                    logBrowserFocusState(event: "addressBarFocus.requestPanelFocus")
#endif
                    onRequestPanelFocus()
                }
                let effects = omnibarReduce(state: &omnibarState, event: .focusGained(currentURLString: urlString))
                applyOmnibarEffects(effects)
                refreshInlineCompletion()
            } else {
                panel.endSuppressWebViewFocusForAddressBar()
                NotificationCenter.default.post(name: .browserDidBlurAddressBar, object: panel.id)
                if suppressNextFocusLostRevert {
                    suppressNextFocusLostRevert = false
                    let effects = omnibarReduce(state: &omnibarState, event: .focusLostPreserveBuffer(currentURLString: urlString))
                    applyOmnibarEffects(effects)
                } else {
                    let effects = omnibarReduce(state: &omnibarState, event: .focusLostRevertBuffer(currentURLString: urlString))
                    applyOmnibarEffects(effects)
                }
                inlineCompletion = nil
            }
            syncWebViewResponderPolicyWithViewState(reason: "addressBarFocusChanged")
#if DEBUG
            logBrowserFocusState(event: "addressBarFocus.onChange.applied")
#endif
        }
    }

    private var browserNotificationContent: some View {
        browserFocusContent
        .onReceive(NotificationCenter.default.publisher(for: .browserMoveOmnibarSelection)) { notification in
            guard let panelId = notification.object as? UUID, panelId == panel.id else { return }
            guard addressBarFocused, !omnibarState.suggestions.isEmpty else { return }
            guard let delta = notification.userInfo?["delta"] as? Int, delta != 0 else { return }
#if DEBUG
            logBrowserFocusState(event: "addressBarFocus.moveSelection", detail: "delta=\(delta)")
#endif
            let effects = omnibarReduce(state: &omnibarState, event: .moveSelection(delta: delta))
            applyOmnibarEffects(effects)
            refreshInlineCompletion()
        }
        .onReceive(panel.historyStore.$entries) { _ in
            guard addressBarFocused else { return }
            refreshSuggestions()
        }
        .onReceive(NotificationCenter.default.publisher(for: .browserDidBlurAddressBar).filter { note in
            guard let panelId = note.object as? UUID else { return false }
            return panelId == panel.id
        }) { _ in
            if addressBarFocused {
#if DEBUG
                logBrowserFocusState(event: "addressBarFocus.externalBlur")
#endif
                setAddressBarFocused(false, reason: "notification.externalBlur")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ghosttyDefaultBackgroundDidChange)) { _ in
            refreshBrowserChromeStyle()
        }
    }

    private var addressBar: some View {
        HStack(spacing: 8) {
            BrowserNavigationButtonsView(panel: panel)

            omnibarField
                .accessibilityIdentifier("BrowserOmnibarPill")
                .accessibilityLabel(String(localized: "browser.omnibar.accessibilityLabel", defaultValue: "Browser omnibar"))

            HStack(spacing: browserToolbarAccessorySpacing) {
                if shouldShowToolbarImportHintChip {
                    browserImportHintToolbarChip
                }
                reactGrabButton
                BrowserProfileMenuView(
                    panel: panel,
                    iconColor: devToolsColorOption.color,
                    isPresented: $isBrowserProfileMenuPresented,
                    popoverPadding: (browserProfilePopoverHorizontalPadding, browserProfilePopoverVerticalPadding),
                    onSelectProfile: applyBrowserProfileSelection,
                    onAction: { action in
                        switch action {
                        case .newProfile:
                            presentCreateBrowserProfilePrompt()
                        case .importBrowserData:
                            presentImportDialogFromProfileMenu()
                        case .renameProfile:
                            presentRenameBrowserProfilePrompt()
                        }
                    }
                )
                BrowserThemeModeMenuView(
                    currentMode: browserThemeMode,
                    iconColor: browserThemeModeIconColor,
                    isPresented: $isBrowserThemeMenuPresented,
                    onSelectMode: applyBrowserThemeModeSelection
                )
                developerToolsButton
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, addressBarVerticalPadding)
        .background(browserChromeBackground)
        .background {
            GeometryReader { geo in
                Color.clear
                    .preference(
                        key: BrowserAddressBarHeightPreferenceKey.self,
                        value: geo.size.height
                    )
            }
        }
        // Keep the omnibar stack above WKWebView so the suggestions popup is visible.
        .zIndex(1)
        .environment(\.colorScheme, browserChromeColorScheme)
    }

    private var reactGrabButton: some View {
        Button(action: {
            panel.clearReactGrabRoundTrip(reason: "toolbarButton.manualStart")
            Task { await panel.toggleOrInjectReactGrab() }
        }) {
            Image(systemName: "cursorarrow.click.2")
                .symbolRenderingMode(.monochrome)
                .programaFlatSymbolColorRendering()
                .font(.system(size: devToolsButtonIconSize, weight: .medium))
                .foregroundStyle(panel.isReactGrabActive ? Color.accentColor : Color.secondary)
                .frame(width: addressBarButtonSize, height: addressBarButtonSize, alignment: .center)
        }
        .buttonStyle(OmnibarAddressButtonStyle())
        .frame(width: addressBarButtonSize, height: addressBarButtonSize, alignment: .center)
        .safeHelp(String(localized: "browser.reactGrab", defaultValue: "Inject React Grab"))
        .accessibilityIdentifier("BrowserReactGrabButton")
    }

    private var developerToolsButton: some View {
        Button(action: {
            openDevTools()
        }) {
            Image(systemName: devToolsIconOption.rawValue)
                .symbolRenderingMode(.monochrome)
                .programaFlatSymbolColorRendering()
                .font(.system(size: devToolsButtonIconSize, weight: .medium))
                .foregroundStyle(devToolsColorOption.color)
                .frame(width: addressBarButtonSize, height: addressBarButtonSize, alignment: .center)
        }
        .buttonStyle(OmnibarAddressButtonStyle())
        .frame(width: addressBarButtonSize, height: addressBarButtonSize, alignment: .center)
        .safeHelp(developerToolsButtonHelp)
        .accessibilityIdentifier("BrowserToggleDevToolsButton")
    }

    private var browserImportHintToolbarChip: some View {
        Button(action: {
            isBrowserImportHintPopoverPresented.toggle()
        }) {
            HStack(spacing: 4) {
                Image(systemName: "square.and.arrow.down.on.square")
                    .font(.system(size: 10, weight: .medium))
                Text(String(localized: "browser.import.hint.toolbar", defaultValue: "Import"))
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(devToolsColorOption.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .buttonStyle(OmnibarAddressButtonStyle())
        .popover(isPresented: $isBrowserImportHintPopoverPresented, arrowEdge: .bottom) {
            browserImportHintContent.popover
        }
        .safeHelp(String(localized: "browser.import.hint.toolbar.help", defaultValue: "Import browser data"))
        .accessibilityIdentifier("BrowserImportHintToolbarChip")
    }

    private var browserThemeModeIconColor: Color {
        devToolsColorOption.color
    }

    private var browserImportHintContent: BrowserImportHintContentView {
        BrowserImportHintContentView(
            summary: browserImportHintSummary,
            onImport: presentImportDialogFromHint,
            onOpenSettings: openBrowserImportSettings,
            onDismiss: dismissBrowserImportHint
        )
    }

    private var omnibarField: some View {
        let showSecureBadge = panel.currentURL?.scheme == "https"

        return HStack(spacing: 4) {
            if showSecureBadge {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            OmnibarTextFieldRepresentable(
                text: Binding(
                    get: { omnibarState.buffer },
                    set: { newValue in
                        let effects = omnibarReduce(state: &omnibarState, event: .bufferChanged(newValue))
                        applyOmnibarEffects(effects)
                        refreshInlineCompletion()
                    }
                ),
                isFocused: $addressBarFocused,
                inlineCompletion: inlineCompletion,
                placeholder: String(localized: "browser.addressBar.placeholder", defaultValue: "Search or enter URL"),
                onTap: {
                    handleOmnibarTap()
                },
                onSubmit: {
                    if addressBarFocused, !omnibarState.suggestions.isEmpty {
                        commitSelectedSuggestion()
                    } else {
                        panel.navigateSmart(omnibarState.buffer)
                        hideSuggestions()
                        suppressNextFocusLostRevert = true
                        setAddressBarFocused(false, reason: "omnibar.submit.navigate")
                    }
                },
                onEscape: {
                    handleOmnibarEscape()
                },
                onFieldLostFocus: {
                    setAddressBarFocused(false, reason: "omnibar.fieldLostFocus")
                },
                onMoveSelection: { delta in
                    guard addressBarFocused, !omnibarState.suggestions.isEmpty else { return }
                    let effects = omnibarReduce(state: &omnibarState, event: .moveSelection(delta: delta))
                    applyOmnibarEffects(effects)
                    refreshInlineCompletion()
                },
                onDeleteSelectedSuggestion: {
                    deleteSelectedSuggestionIfPossible()
                },
                onAcceptInlineCompletion: {
                    acceptInlineCompletion()
                },
                onDeleteBackwardWithInlineSelection: {
                    handleInlineBackspace()
                },
                onSelectionChanged: { selectionRange, hasMarkedText in
                    handleOmnibarSelectionChange(range: selectionRange, hasMarkedText: hasMarkedText)
                },
                shouldSuppressWebViewFocus: {
                    panel.shouldSuppressWebViewFocus()
                }
            )
                .frame(height: 18)
                .accessibilityIdentifier("BrowserOmnibarTextField")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: omnibarPillCornerRadius, style: .continuous)
                .fill(Color(nsColor: omnibarPillBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: omnibarPillCornerRadius, style: .continuous)
                .stroke(addressBarFocused ? programaAccentColor() : Color.clear, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .background {
            GeometryReader { geo in
                Color.clear
                    .preference(
                        key: OmnibarPillFramePreferenceKey.self,
                        value: geo.frame(in: .named("BrowserPanelViewSpace"))
                    )
            }
        }
    }

    private var webView: some View {
        let useLocalInlineDeveloperToolsHosting =
            panel.shouldUseLocalInlineDeveloperToolsHosting() &&
            isCurrentPaneOwner

        return Group {
            if panel.shouldRenderWebView {
                WebViewRepresentable(
                    panel: panel,
                    paneId: paneId,
                    shouldAttachWebView: isVisibleInUI && isCurrentPaneOwner && !useLocalInlineDeveloperToolsHosting,
                    useLocalInlineHosting: useLocalInlineDeveloperToolsHosting,
                    shouldFocusWebView: isFocused && !addressBarFocused,
                    isPanelFocused: isFocused,
                    portalZPriority: portalPriority,
                    paneDropZone: paneDropZone,
                    searchOverlay: panel.searchState.map { searchState in
                        BrowserPortalSearchOverlayConfiguration(
                            panelId: panel.id,
                            searchState: searchState,
                            focusRequestGeneration: panel.searchFocusRequestGeneration,
                            canApplyFocusRequest: { generation in
                                canApplyBrowserFindFieldFocusRequest(generation)
                            },
                            onNext: { panel.findNext() },
                            onPrevious: { panel.findPrevious() },
                            onClose: { panel.hideFind() },
                            onFieldDidFocus: { panel.noteFindFieldFocused() }
                        )
                    },
                    paneTopChromeHeight: addressBarHeight
                )
                .accessibilityIdentifier("BrowserWebViewSurface")
                // Keep the host stable for normal pane churn, but force a remount when
                // BrowserPanel replaces its underlying WKWebView after process termination
                // or when the browser moves to a different Bonsplit pane host.
                .id("\(panel.webViewInstanceID.uuidString)-\(paneId.id.uuidString)")
                .contentShape(Rectangle())
                .accessibilityIdentifier(browserContentAccessibilityIdentifier)
                .simultaneousGesture(TapGesture().onEnded {
                    // Chrome-like behavior: clicking web content while editing the
                    // omnibar should commit blur and revert transient edits.
                    if addressBarFocused {
#if DEBUG
                        logBrowserFocusState(event: "webContent.tapBlur")
#endif
                        setAddressBarFocused(false, reason: "webContent.tapBlur")
                    }
                })
            } else {
                Color(nsColor: browserChromeBackgroundColor)
                    .contentShape(Rectangle())
                    .accessibilityIdentifier(browserContentAccessibilityIdentifier)
                    .onTapGesture {
                        onRequestPanelFocus()
                        if addressBarFocused {
                            setAddressBarFocused(false, reason: "placeholderContent.tapBlur")
                        }
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .layoutPriority(1)
        .zIndex(0)
    }

    private func triggerFocusFlashAnimation() {
        focusFlashAnimationGeneration &+= 1
        let generation = focusFlashAnimationGeneration
        focusFlashOpacity = FocusFlashPattern.values.first ?? 0

        for segment in FocusFlashPattern.segments {
            DispatchQueue.main.asyncAfter(deadline: .now() + segment.delay) {
                guard focusFlashAnimationGeneration == generation else { return }
                withAnimation(focusFlashAnimation(for: segment.curve, duration: segment.duration)) {
                    focusFlashOpacity = segment.targetOpacity
                }
            }
        }
    }

    private func focusFlashAnimation(for curve: FocusFlashCurve, duration: TimeInterval) -> Animation {
        switch curve {
        case .easeIn:
            return .easeIn(duration: duration)
        case .easeOut:
            return .easeOut(duration: duration)
        }
    }

    private func refreshBrowserChromeStyle() {
        browserChromeStyle = BrowserChromeStyle.resolve(
            for: colorScheme,
            themeBackgroundColor: GhosttyBackgroundTheme.currentColor()
        )
    }

    private func syncWebViewResponderPolicyWithViewState(
        reason: String,
        isPanelFocusedOverride: Bool? = nil
    ) {
        guard let programaWebView = panel.webView as? ProgramaWebView else { return }
        let isPanelFocused = isPanelFocusedOverride ?? isFocused
        let next = isPanelFocused && !panel.shouldSuppressWebViewFocus()
        if programaWebView.allowsFirstResponderAcquisition != next {
#if DEBUG
            dlog(
                "browser.focus.policy.resync panel=\(panel.id.uuidString.prefix(5)) " +
                "web=\(ObjectIdentifier(programaWebView)) old=\(programaWebView.allowsFirstResponderAcquisition ? 1 : 0) " +
                "new=\(next ? 1 : 0) reason=\(reason) " +
                "panelFocusedUsed=\(isPanelFocused ? 1 : 0)"
            )
#endif
        }
        programaWebView.allowsFirstResponderAcquisition = next
    }

    private func setAddressBarFocused(_ focused: Bool, reason: String) {
#if DEBUG
        if addressBarFocused == focused {
            logBrowserFocusState(
                event: "addressBarFocus.write.noop",
                detail: "reason=\(reason) value=\(focused ? 1 : 0)"
            )
        } else {
            logBrowserFocusState(
                event: "addressBarFocus.write",
                detail: "reason=\(reason) old=\(addressBarFocused ? 1 : 0) new=\(focused ? 1 : 0)"
            )
        }
#endif
        addressBarFocused = focused
        if focused {
            panel.noteAddressBarFocused()
        }
    }

    private func browserFocusResponderChainContains(
        _ start: NSResponder?,
        target: NSResponder
    ) -> Bool {
        var current = start
        var hops = 0
        while let responder = current, hops < 64 {
            if responder === target { return true }
            current = responder.nextResponder
            hops += 1
        }
        return false
    }

    private func isPanelFocusedInModel() -> Bool {
        guard let app = AppDelegate.shared,
              let manager = app.tabManagerFor(tabId: panel.workspaceId),
              manager.selectedTabId == panel.workspaceId,
              let workspace = manager.tabs.first(where: { $0.id == panel.workspaceId }) else {
            return false
        }
        return workspace.focusedPanelId == panel.id
    }

    private func canApplyBrowserFindFieldFocusRequest(_ generation: UInt64) -> Bool {
        isPanelFocusedInModel() && panel.canApplySearchFocusRequest(generation)
    }

    private func shouldApplyAddressBarExitFallback(in window: NSWindow) -> Bool {
        // Navigation-triggered omnibar blur can still be unwinding when Cmd+F opens
        // the browser find bar. Once find is visible, any delayed omnibar-exit
        // handoff must not reclaim first responder for WebKit.
        panel.webView.window === window &&
            isPanelFocusedInModel() &&
            panel.searchState == nil
    }

#if DEBUG
    private func browserFocusWindow() -> NSWindow? {
        panel.webView.window ?? NSApp.keyWindow ?? NSApp.mainWindow
    }

    private func browserFocusResponderDescription(_ responder: NSResponder?) -> String {
        guard let responder else { return "nil" }
        return String(describing: type(of: responder))
    }

    private func logBrowserFocusState(event: String, detail: String = "") {
        let window = browserFocusWindow()
        let firstResponder = window?.firstResponder
        let firstResponderType = browserFocusResponderDescription(firstResponder)
        let webResponder = browserFocusResponderChainContains(firstResponder, target: panel.webView) ? 1 : 0
        var line =
            "browser.focus.trace event=\(event) panel=\(panel.id.uuidString.prefix(5)) " +
            "panelFocused=\(isFocused ? 1 : 0) addrFocused=\(addressBarFocused ? 1 : 0) " +
            "suppressWeb=\(panel.shouldSuppressWebViewFocus() ? 1 : 0) " +
            "suppressAuto=\(panel.shouldSuppressOmnibarAutofocus() ? 1 : 0) " +
            "webResponder=\(webResponder) win=\(window?.windowNumber ?? -1) fr=\(firstResponderType)"
        if let pending = panel.pendingAddressBarFocusRequestId {
            line += " pending=\(pending.uuidString.prefix(8))"
        }
        if !detail.isEmpty {
            line += " \(detail)"
        }
        dlog(line)
    }
#endif

    private func syncURLFromPanel() {
        let urlString = panel.preferredURLStringForOmnibar() ?? ""
        let effects = omnibarReduce(state: &omnibarState, event: .panelURLChanged(currentURLString: urlString))
        applyOmnibarEffects(effects)
    }

    private func isCommandPaletteVisibleForPanelWindow() -> Bool {
        guard let app = AppDelegate.shared else { return false }

        if let window = panel.webView.window, app.isCommandPaletteVisible(for: window) {
            return true
        }

        if let manager = app.tabManagerFor(tabId: panel.workspaceId),
           let windowId = app.windowId(for: manager),
           let window = app.mainWindow(for: windowId),
           app.isCommandPaletteVisible(for: window) {
            return true
        }

        if let keyWindow = NSApp.keyWindow, app.isCommandPaletteVisible(for: keyWindow) {
            return true
        }
        if let mainWindow = NSApp.mainWindow, app.isCommandPaletteVisible(for: mainWindow) {
            return true
        }
        return false
    }

    private func clearPendingAddressBarFocusRetry() {
        pendingAddressBarFocusRetryRequestId = nil
        pendingAddressBarFocusRetryGeneration &+= 1
    }

    private func schedulePendingAddressBarFocusRetryIfNeeded(requestId: UUID) {
        guard pendingAddressBarFocusRetryRequestId != requestId else { return }
        pendingAddressBarFocusRetryRequestId = requestId
        pendingAddressBarFocusRetryGeneration &+= 1
        let generation = pendingAddressBarFocusRetryGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
            guard pendingAddressBarFocusRetryGeneration == generation else { return }
            pendingAddressBarFocusRetryRequestId = nil
            guard panel.pendingAddressBarFocusRequestId == requestId else { return }
            applyPendingAddressBarFocusRequestIfNeeded()
        }
    }

    private func applyPendingAddressBarFocusRequestIfNeeded() {
        guard let requestId = panel.pendingAddressBarFocusRequestId else {
            clearPendingAddressBarFocusRetry()
            return
        }
        guard !isCommandPaletteVisibleForPanelWindow() else {
#if DEBUG
            logBrowserFocusState(
                event: "addressBarFocus.request.apply.skip",
                detail: "reason=command_palette_visible request=\(requestId.uuidString.prefix(8))"
            )
#endif
            schedulePendingAddressBarFocusRetryIfNeeded(requestId: requestId)
            return
        }
        clearPendingAddressBarFocusRetry()
        guard lastHandledAddressBarFocusRequestId != requestId else {
#if DEBUG
            logBrowserFocusState(
                event: "addressBarFocus.request.apply.skip",
                detail: "reason=already_handled request=\(requestId.uuidString.prefix(8))"
            )
#endif
            return
        }
        lastHandledAddressBarFocusRequestId = requestId
        panel.beginSuppressWebViewFocusForAddressBar()
#if DEBUG
        logBrowserFocusState(
            event: "addressBarFocus.request.apply",
            detail: "request=\(requestId.uuidString.prefix(8))"
        )
#endif

        if addressBarFocused {
            // Re-run focus behavior (select-all/refresh suggestions) when focus is
            // explicitly requested again while already focused.
            let urlString = panel.preferredURLStringForOmnibar() ?? ""
            let effects = omnibarReduce(state: &omnibarState, event: .focusGained(currentURLString: urlString))
            applyOmnibarEffects(effects)
            refreshInlineCompletion()
#if DEBUG
            logBrowserFocusState(
                event: "addressBarFocus.request.apply",
                detail: "request=\(requestId.uuidString.prefix(8)) mode=refresh"
            )
#endif
        } else {
            setAddressBarFocused(true, reason: "request.apply")
#if DEBUG
            logBrowserFocusState(
                event: "addressBarFocus.request.apply",
                detail: "request=\(requestId.uuidString.prefix(8)) mode=set_focused"
            )
#endif
        }

        panel.acknowledgeAddressBarFocusRequest(requestId)
#if DEBUG
        logBrowserFocusState(
            event: "addressBarFocus.request.ack",
            detail: "request=\(requestId.uuidString.prefix(8))"
        )
#endif
    }

    private var shouldShowEmptyStateImportOverlay: Bool {
        !panel.shouldRenderWebView && isWebViewBlank()
    }

    private func presentImportDialogFromHint() {
        isBrowserImportHintPopoverPresented = false
        // Let the popover fully dismiss before entering the modal import flow.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            BrowserDataImportCoordinator.shared.presentImportDialog(
                defaultDestinationProfileID: panel.profileID
            )
        }
    }

    private func presentImportDialogFromProfileMenu() {
        isBrowserProfileMenuPresented = false
        DispatchQueue.main.async {
            BrowserDataImportCoordinator.shared.presentImportDialog(
                defaultDestinationProfileID: panel.profileID
            )
        }
    }

    private func openBrowserImportSettings() {
        isBrowserImportHintPopoverPresented = false
        AppDelegate.presentPreferencesWindow(navigationTarget: .browserImport)
    }

    private func dismissBrowserImportHint() {
        showBrowserImportHintOnBlankTabs = false
        isBrowserImportHintDismissed = true
        isBrowserImportHintPopoverPresented = false
    }

    /// Treat a WebView with no URL (or about:blank) as "blank" for UX purposes.
    private func isWebViewBlank() -> Bool {
        guard let url = panel.webView.url else { return true }
        return url.absoluteString == "about:blank"
    }

    private func autoFocusOmnibarIfBlank() {
        guard isFocused else {
#if DEBUG
            logBrowserFocusState(event: "addressBarFocus.autoFocus.skip", detail: "reason=panel_not_focused")
#endif
            return
        }
        guard !addressBarFocused else {
#if DEBUG
            logBrowserFocusState(event: "addressBarFocus.autoFocus.skip", detail: "reason=already_focused")
#endif
            return
        }
        guard !isCommandPaletteVisibleForPanelWindow() else {
#if DEBUG
            logBrowserFocusState(event: "addressBarFocus.autoFocus.skip", detail: "reason=command_palette_visible")
#endif
            return
        }
        // If a test/automation explicitly focused WebKit, don't steal focus back.
        guard !panel.shouldSuppressOmnibarAutofocus() else {
#if DEBUG
            logBrowserFocusState(event: "addressBarFocus.autoFocus.skip", detail: "reason=autofocus_suppressed")
#endif
            return
        }
        // If a real navigation is underway (e.g. open_browser https://...), don't steal focus.
        guard !panel.webView.isLoading else {
#if DEBUG
            logBrowserFocusState(event: "addressBarFocus.autoFocus.skip", detail: "reason=webview_loading")
#endif
            return
        }
        guard isWebViewBlank() else {
#if DEBUG
            logBrowserFocusState(event: "addressBarFocus.autoFocus.skip", detail: "reason=webview_not_blank")
#endif
            return
        }
        setAddressBarFocused(true, reason: "autoFocus.blank")
#if DEBUG
        logBrowserFocusState(event: "addressBarFocus.autoFocus.apply")
#endif
    }

    private func refreshEmptyStateImportBrowsers() {
        emptyStateImportBrowserRefreshTask?.cancel()
        emptyStateImportBrowserRefreshGeneration &+= 1
        let generation = emptyStateImportBrowserRefreshGeneration

        guard shouldShowEmptyStateImportOverlay else {
            emptyStateImportBrowsers = []
            emptyStateImportBrowserRefreshTask = nil
            return
        }

        emptyStateImportBrowserRefreshTask = Task {
            let browsers = await Task.detached(priority: .utility) {
                InstalledBrowserDetector.detectInstalledBrowsers()
            }.value
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard emptyStateImportBrowserRefreshGeneration == generation,
                      shouldShowEmptyStateImportOverlay else { return }
                emptyStateImportBrowsers = browsers
                emptyStateImportBrowserRefreshTask = nil
            }
        }
    }

    private func openDevTools() {
        #if DEBUG
        dlog("browser.toggleDevTools panel=\(panel.id.uuidString.prefix(5))")
        #endif
        if !panel.toggleDeveloperTools() {
            NSSound.beep()
        }
    }

    private func applyBrowserThemeModeSelection(_ mode: BrowserThemeMode) {
        if browserThemeModeRaw != mode.rawValue {
            browserThemeModeRaw = mode.rawValue
        }
        panel.setBrowserThemeMode(mode)
    }

    private func handleOmnibarTap() {
#if DEBUG
        logBrowserFocusState(event: "addressBar.tap")
#endif
        if !addressBarFocused {
            // Mark focused before pane selection converges so WebKit focus is not
            // briefly re-acquired during `focusPane`.
            setAddressBarFocused(true, reason: "omnibar.tap")
        }
        onRequestPanelFocus()
    }

    private func hideSuggestions() {
        suggestionTask?.cancel()
        suggestionTask = nil
        let effects = omnibarReduce(state: &omnibarState, event: .suggestionsUpdated([]))
        applyOmnibarEffects(effects)
        isLoadingRemoteSuggestions = false
        inlineCompletion = nil
    }

    private func commitSelectedSuggestion() {
        let idx = omnibarState.selectedSuggestionIndex
        guard idx >= 0, idx < omnibarState.suggestions.count else { return }
        commitSuggestion(omnibarState.suggestions[idx])
    }

    private func commitSuggestion(_ suggestion: OmnibarSuggestion) {
        // Treat this as a commit, not a user edit: don't refetch suggestions while we're navigating away.
        omnibarState.buffer = suggestion.completion
        omnibarState.isUserEditing = false
        switch suggestion.kind {
        case .switchToTab(let tabId, let panelId, _, _):
            AppDelegate.shared?.tabManager?.focusTab(tabId, surfaceId: panelId)
        default:
            panel.navigateSmart(suggestion.completion)
        }
        hideSuggestions()
        inlineCompletion = nil
        suppressNextFocusLostRevert = true
        setAddressBarFocused(false, reason: "suggestion.commit")
    }

    private func handleOmnibarEscape() {
        guard addressBarFocused else { return }

        // Chrome-like flow: clear inline completion first, then apply normal escape behavior.
        if inlineCompletion != nil {
            inlineCompletion = nil
            return
        }

        let effects = omnibarReduce(state: &omnibarState, event: .escape)
        applyOmnibarEffects(effects)
        refreshInlineCompletion()
    }

    private func handleOmnibarSelectionChange(range: NSRange, hasMarkedText: Bool) {
        omnibarSelectionRange = range
        omnibarHasMarkedText = hasMarkedText
        refreshInlineCompletion()
    }

    private func acceptInlineCompletion() {
        guard let completion = inlineCompletion else { return }
        let effects = omnibarReduce(state: &omnibarState, event: .bufferChanged(completion.displayText))
        applyOmnibarEffects(effects)
        inlineCompletion = nil
    }

    private func handleInlineBackspace() {
        guard let completion = inlineCompletion else { return }
        let prefix = completion.typedText
        guard !prefix.isEmpty else { return }
        let updated = String(prefix.dropLast())
        let effects = omnibarReduce(state: &omnibarState, event: .bufferChanged(updated))
        applyOmnibarEffects(effects)
        omnibarSelectionRange = NSRange(location: updated.utf16.count, length: 0)
        refreshInlineCompletion()
    }

    private func deleteSelectedSuggestionIfPossible() {
        let idx = omnibarState.selectedSuggestionIndex
        guard idx >= 0, idx < omnibarState.suggestions.count else { return }

        let target = omnibarState.suggestions[idx]
        guard case .history(let url, _) = target.kind else { return }
        guard panel.historyStore.removeHistoryEntry(urlString: url) else { return }
        refreshSuggestions()
    }

    private func applyBrowserProfileSelection(_ profileID: UUID) {
        isBrowserProfileMenuPresented = false
        let didApply = panel.profileID == profileID || panel.switchToProfile(profileID)
        guard didApply else { return }
        owningWorkspace?.setPreferredBrowserProfileID(profileID)
    }

    private func presentCreateBrowserProfilePrompt() {
        let alert = NSAlert()
        alert.messageText = String(localized: "browser.profile.new.title", defaultValue: "New Browser Profile")
        alert.informativeText = String(localized: "browser.profile.new.message", defaultValue: "Create a separate browser profile for cookies, history, and local storage.")

        let input = NSTextField(string: "")
        input.placeholderString = String(localized: "browser.profile.new.placeholder", defaultValue: "Profile name")
        input.frame = NSRect(x: 0, y: 0, width: 260, height: 22)
        alert.accessoryView = input

        alert.addButton(withTitle: String(localized: "common.create", defaultValue: "Create"))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))

        let alertWindow = alert.window
        alertWindow.initialFirstResponder = input
        DispatchQueue.main.async {
            alertWindow.makeFirstResponder(input)
            input.selectText(nil)
        }

        guard alert.runModal() == .alertFirstButtonReturn,
              let profile = browserProfileStore.createProfile(named: input.stringValue) else {
            return
        }

        applyBrowserProfileSelection(profile.id)
    }

    private func presentRenameBrowserProfilePrompt() {
        guard let profile = browserProfileStore.profileDefinition(id: panel.profileID),
              browserProfileStore.canRenameProfile(id: profile.id) else {
            return
        }

        let alert = NSAlert()
        alert.messageText = String(localized: "browser.profile.rename.title", defaultValue: "Rename Browser Profile")
        alert.informativeText = String(localized: "browser.profile.rename.message", defaultValue: "Choose a new name for this browser profile.")

        let input = NSTextField(string: profile.displayName)
        input.placeholderString = String(localized: "browser.profile.new.placeholder", defaultValue: "Profile name")
        input.frame = NSRect(x: 0, y: 0, width: 260, height: 22)
        alert.accessoryView = input

        alert.addButton(withTitle: String(localized: "common.rename", defaultValue: "Rename"))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))

        let alertWindow = alert.window
        alertWindow.initialFirstResponder = input
        DispatchQueue.main.async {
            alertWindow.makeFirstResponder(input)
            input.selectText(nil)
        }

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        _ = browserProfileStore.renameProfile(id: profile.id, to: input.stringValue)
    }

    private func refreshInlineCompletion() {
        inlineCompletion = omnibarInlineCompletionForDisplay(
            typedText: omnibarState.buffer,
            suggestions: omnibarState.suggestions,
            isFocused: addressBarFocused,
            selectionRange: omnibarSelectionRange,
            hasMarkedText: omnibarHasMarkedText
        )
    }

    private func refreshSuggestions() {
#if DEBUG
        let typingTimingStart = ProgramaTypingTiming.start()
        defer {
            let trimmedQuery = omnibarState.buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            ProgramaTypingTiming.logDuration(
                path: "browser.omnibar.refreshSuggestions",
                startedAt: typingTimingStart,
                extra: "focused=\(addressBarFocused ? 1 : 0) queryLen=\(trimmedQuery.utf8.count) suggestionCount=\(omnibarState.suggestions.count)"
            )
        }
#endif
        suggestionTask?.cancel()
        suggestionTask = nil
        isLoadingRemoteSuggestions = false

        guard addressBarFocused else {
            let effects = omnibarReduce(state: &omnibarState, event: .suggestionsUpdated([]))
            applyOmnibarEffects(effects)
            return
        }

        let query = omnibarState.buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        let historyEntries: [BrowserHistoryStore.Entry] = {
            if query.isEmpty {
                return panel.historyStore.recentSuggestions(limit: 12)
            }
            return panel.historyStore.suggestions(for: query, limit: 12)
        }()
        let openTabMatches = query.isEmpty ? [] : matchingOpenTabSuggestions(for: query, limit: 12)
        let isSingleCharacterQuery = omnibarSingleCharacterQuery(for: query) != nil
        let staleRemote: [String]
        if query.isEmpty || isSingleCharacterQuery {
            staleRemote = []
        } else {
            staleRemote = staleRemoteSuggestionsForDisplay(query: query)
        }
        let resolvedURL = query.isEmpty ? nil : panel.resolveNavigableURL(from: query)
        let items = buildOmnibarSuggestions(
            query: query,
            engineName: searchEngine.displayName,
            historyEntries: historyEntries,
            openTabMatches: openTabMatches,
            remoteQueries: staleRemote,
            resolvedURL: resolvedURL,
            limit: 8
        )
        let effects = omnibarReduce(state: &omnibarState, event: .suggestionsUpdated(items))
        applyOmnibarEffects(effects)
        refreshInlineCompletion()

        guard !query.isEmpty else { return }

        if !isSingleCharacterQuery, let forcedRemote = forcedRemoteSuggestionsForUITest() {
            latestRemoteSuggestionQuery = query
            latestRemoteSuggestions = forcedRemote
            let merged = buildOmnibarSuggestions(
                query: query,
                engineName: searchEngine.displayName,
                historyEntries: historyEntries,
                openTabMatches: openTabMatches,
                remoteQueries: forcedRemote,
                resolvedURL: resolvedURL,
                limit: 8
            )
            let forcedEffects = omnibarReduce(state: &omnibarState, event: .suggestionsUpdated(merged))
            applyOmnibarEffects(forcedEffects)
            refreshInlineCompletion()
            return
        }

        guard remoteSuggestionsEnabled else { return }
        guard !isSingleCharacterQuery else { return }
        guard omnibarInputIntent(for: query) != .urlLike else { return }

        // Keep current remote rows visible while fetching fresh predictions.
        let engine = searchEngine
        isLoadingRemoteSuggestions = true
        suggestionTask = Task {
            let remote = await BrowserSearchSuggestionService.shared.suggestions(engine: engine, query: query)
            if Task.isCancelled { return }

            await MainActor.run {
                guard addressBarFocused else { return }
                let current = omnibarState.buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                guard current == query else { return }
                latestRemoteSuggestionQuery = query
                latestRemoteSuggestions = remote
                let merged = buildOmnibarSuggestions(
                    query: query,
                    engineName: searchEngine.displayName,
                    historyEntries: panel.historyStore.suggestions(for: query, limit: 12),
                    openTabMatches: matchingOpenTabSuggestions(for: query, limit: 12),
                    remoteQueries: remote,
                    resolvedURL: panel.resolveNavigableURL(from: query),
                    limit: 8
                )
                let effects = omnibarReduce(state: &omnibarState, event: .suggestionsUpdated(merged))
                applyOmnibarEffects(effects)
                refreshInlineCompletion()
                isLoadingRemoteSuggestions = false
            }
        }
    }

    private func staleRemoteSuggestionsForDisplay(query: String) -> [String] {
        staleOmnibarRemoteSuggestionsForDisplay(
            query: query,
            previousRemoteQuery: latestRemoteSuggestionQuery,
            previousRemoteSuggestions: latestRemoteSuggestions
        )
    }

    private func matchingOpenTabSuggestions(for query: String, limit: Int) -> [OmnibarOpenTabMatch] {
        guard !query.isEmpty, limit > 0 else { return [] }

        let loweredQuery = query.lowercased()
        let singleCharacterQuery = omnibarSingleCharacterQuery(for: query)
        let includeCurrentPanelForSingleCharacterQuery = singleCharacterQuery != nil
        let tabManager = AppDelegate.shared?.tabManager
        let currentPanelWorkspaceId = tabManager?.tabs.first(where: { tab in
            tab.panels[panel.id] is BrowserPanel
        })?.id
        var matches: [OmnibarOpenTabMatch] = []
        var seenKeys = Set<String>()

        func preferredPanelURL(_ browserPanel: BrowserPanel) -> String? {
            browserPanel.preferredURLStringForOmnibar()
        }

        func addMatch(
            tabId: UUID,
            panelId: UUID,
            url: String,
            title: String?,
            isKnownOpenTab: Bool,
            matches: inout [OmnibarOpenTabMatch],
            seenKeys: inout Set<String>
        ) {
            let key = "\(tabId.uuidString.lowercased())|\(panelId.uuidString.lowercased())|\(url.lowercased())"
            guard !seenKeys.contains(key) else { return }
            seenKeys.insert(key)
            matches.append(
                OmnibarOpenTabMatch(
                    tabId: tabId,
                    panelId: panelId,
                    url: url,
                    title: title,
                    isKnownOpenTab: isKnownOpenTab
                )
            )
        }

        if includeCurrentPanelForSingleCharacterQuery,
           let query = singleCharacterQuery,
           let currentURL = preferredPanelURL(panel),
           !currentURL.isEmpty {
            let rawTitle = panel.pageTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = rawTitle.isEmpty ? nil : rawTitle
            if omnibarHasSingleCharacterPrefixMatch(query: query, url: currentURL, title: title) {
                addMatch(
                    tabId: currentPanelWorkspaceId ?? panel.workspaceId,
                    panelId: panel.id,
                    url: currentURL,
                    title: title,
                    isKnownOpenTab: currentPanelWorkspaceId != nil,
                    matches: &matches,
                    seenKeys: &seenKeys
                )
            }
        }

        guard let tabManager else { return matches }

        for tab in tabManager.tabs {
            for (panelId, anyPanel) in tab.panels {
                guard let browserPanel = anyPanel as? BrowserPanel else { continue }
                guard let currentURL = preferredPanelURL(browserPanel),
                      !currentURL.isEmpty else { continue }
                let isCurrentPanel = tab.id == panel.workspaceId && panelId == panel.id
                if isCurrentPanel && !includeCurrentPanelForSingleCharacterQuery {
                    continue
                }

                let rawTitle = browserPanel.pageTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                let title = rawTitle.isEmpty ? nil : rawTitle
                let isMatch: Bool = {
                    if let singleCharacterQuery {
                        return omnibarHasSingleCharacterPrefixMatch(
                            query: singleCharacterQuery,
                            url: currentURL,
                            title: title
                        )
                    }
                    let haystacks = [
                        currentURL.lowercased(),
                        (title ?? "").lowercased(),
                    ]
                    return haystacks.contains { $0.contains(loweredQuery) }
                }()
                guard isMatch else { continue }

                addMatch(
                    tabId: tab.id,
                    panelId: panelId,
                    url: currentURL,
                    title: title,
                    isKnownOpenTab: true,
                    matches: &matches,
                    seenKeys: &seenKeys
                )
            }
        }

        if matches.count <= limit { return matches }
        return Array(matches.prefix(limit))
    }

    private func forcedRemoteSuggestionsForUITest() -> [String]? {
        let raw = ProcessInfo.processInfo.environment["PROGRAMA_UI_TEST_REMOTE_SUGGESTIONS_JSON"]
            ?? UserDefaults.standard.string(forKey: "PROGRAMA_UI_TEST_REMOTE_SUGGESTIONS_JSON")
        guard let raw,
              let data = raw.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            return nil
        }

        let values = parsed.compactMap { item -> String? in
            guard let s = item as? String else { return nil }
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return values.isEmpty ? nil : values
    }

    private func applyOmnibarEffects(_ effects: OmnibarEffects) {
        if effects.shouldRefreshSuggestions {
            refreshSuggestions()
        }
        if effects.shouldSelectAll {
            // Apply immediately for fast Cmd+L typing, then retry once in case
            // first responder wasn't fully settled on the same runloop.
            DispatchQueue.main.async {
                NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
            }
        }
        if effects.shouldBlurToWebView {
            hideSuggestions()
            // This transition is stateful: drop omnibar focus suppression before
            // attempting responder handoff so WKWebView can actually become first responder.
            panel.endSuppressWebViewFocusForAddressBar()
            syncWebViewResponderPolicyWithViewState(reason: "effects.blurToWebView.preHandoff")
            setAddressBarFocused(false, reason: "effects.blurToWebView")
            DispatchQueue.main.async {
                guard let window = panel.webView.window,
                      !panel.webView.isHiddenOrHasHiddenAncestor else { return }
                guard shouldApplyAddressBarExitFallback(in: window) else {
#if DEBUG
                    dlog(
                        "browser.focus.addressBar.exit.handoff panel=\(panel.id.uuidString.prefix(5)) " +
                        "result=skip_not_focused"
                    )
#endif
                    NotificationCenter.default.post(name: .browserDidExitAddressBar, object: panel.id)
                    return
                }
                syncWebViewResponderPolicyWithViewState(reason: "effects.blurToWebView.handoff")
                panel.clearWebViewFocusSuppression()
                let focusedWebView = window.makeFirstResponder(panel.webView)
                if focusedWebView {
                    panel.noteWebViewFocused()
                }
#if DEBUG
                dlog(
                    "browser.focus.addressBar.exit.handoff panel=\(panel.id.uuidString.prefix(5)) " +
                    "focusedWebView=\(focusedWebView ? 1 : 0)"
                )
#endif
                panel.restoreAddressBarPageFocusIfNeeded { restored in
                    guard shouldApplyAddressBarExitFallback(in: window) else {
#if DEBUG
                        dlog(
                            "browser.focus.addressBar.exit.handoff panel=\(panel.id.uuidString.prefix(5)) " +
                            "result=skip_stale_restore restored=\(restored ? 1 : 0)"
                        )
#endif
                        NotificationCenter.default.post(name: .browserDidExitAddressBar, object: panel.id)
                        return
                    }
                    var hasWebViewResponder =
                        browserFocusResponderChainContains(window.firstResponder, target: panel.webView)
                    if !hasWebViewResponder {
                        let fallbackFocusedWebView = window.makeFirstResponder(panel.webView)
                        hasWebViewResponder = fallbackFocusedWebView
#if DEBUG
                        dlog(
                            "browser.focus.addressBar.exit.handoff panel=\(panel.id.uuidString.prefix(5)) " +
                            "fallbackFocusedWebView=\(fallbackFocusedWebView ? 1 : 0) " +
                            "restored=\(restored ? 1 : 0)"
                        )
#endif
                    }
                    if hasWebViewResponder {
                        panel.noteWebViewFocused()
                    }
                    NotificationCenter.default.post(name: .browserDidExitAddressBar, object: panel.id)
                }
            }
        }
    }
}

