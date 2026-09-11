import AppKit
import SwiftUI
import Darwin
import Bonsplit
import UniformTypeIdentifiers
import CoreImage
import CoreImage.CIFilterBuiltins


/// Height tracks the selected tab's content; width is free above a floor derived from
/// the tab labels, so the six segments never truncate.
enum SettingsWindowMetrics {
    static let contentWidth: CGFloat = 640
    static let maxContentWidth: CGFloat = 1_100
    /// Low enough that a one-row tab fits snugly instead of padding out dead space.
    static let minContentHeight: CGFloat = 180
    /// Long tabs scroll rather than growing the window off the desk.
    static let maxContentHeight: CGFloat = 760
    /// Opening straight onto an over-long tab (a deep link to Shortcuts) never
    /// triggers a fit, so the window has to start at a height that already reads well.
    static let defaultContentHeight: CGFloat = 520
}

struct SettingsView: View {
    // The header is a traffic-light band plus the tab strip. It is a safe-area inset,
    // so the scroll view positions content below it without a hand-tuned top inset.
    private let headerHeight: CGFloat = 80
    private let contentVerticalPadding: CGFloat = 20
    /// Clears the traffic lights so the header action sits level with them.
    private let titlebarBandHeight: CGFloat = 28
    /// Shared by the tab strip and the scrolling rows so they line up on both edges.
    private let contentHorizontalInset: CGFloat = 20

    @State private var selectedTab: SettingsTab = .general
    @State private var measuredContentHeight: CGFloat = 0
    @State private var minimumWindowWidth: CGFloat = SettingsWindowMetrics.contentWidth
    private let pickerColumnWidth: CGFloat = 196
    private let notificationSoundControlWidth: CGFloat = 280
    private let shortcutChordsDocsURL = URL(string: "https://github.com/darkroomengineering/programa/tree/main/docs")!

    @AppStorage(AppearanceSettings.appearanceModeKey) private var appearanceMode = AppearanceSettings.defaultMode.rawValue
    @AppStorage(WorkspacePresentationModeSettings.modeKey)
    private var workspacePresentationMode = WorkspacePresentationModeSettings.defaultMode.rawValue
    @AppStorage(SocketControlSettings.appStorageKey) private var socketControlMode = SocketControlSettings.defaultMode.rawValue
    @AppStorage(ClaudeCodeIntegrationSettings.hooksEnabledKey)
    private var claudeCodeHooksEnabled = ClaudeCodeIntegrationSettings.defaultHooksEnabled
    @AppStorage(ClaudeCodeIntegrationSettings.customClaudePathKey)
    private var customClaudePath = ""
    @AppStorage(AgentScreenDetectionSettings.enabledKey)
    private var agentScreenDetectionEnabled = AgentScreenDetectionSettings.defaultEnabled
    @AppStorage(PreferredEditorSettings.key) private var preferredEditorCommand = ""
    @AppStorage(ProgramaPortRangePolicy.baseDefaultsKey)
    private var programaPortBase = ProgramaPortRangePolicy.defaultBase
    @AppStorage(ProgramaPortRangePolicy.rangeDefaultsKey)
    private var programaPortRange = ProgramaPortRangePolicy.defaultRange
    @AppStorage(BrowserSearchSettings.searchEngineKey) private var browserSearchEngine = BrowserSearchSettings.defaultSearchEngine.rawValue
    @AppStorage(BrowserSearchSettings.searchSuggestionsEnabledKey) private var browserSearchSuggestionsEnabled = BrowserSearchSettings.defaultSearchSuggestionsEnabled
    @AppStorage(BrowserThemeSettings.modeKey) private var browserThemeMode = BrowserThemeSettings.defaultMode.rawValue
    @AppStorage(BrowserLinkOpenSettings.openTerminalLinksInProgramaBrowserKey) private var openTerminalLinksInProgramaBrowser = BrowserLinkOpenSettings.defaultOpenTerminalLinksInProgramaBrowser
    @AppStorage(BrowserLinkOpenSettings.interceptTerminalOpenCommandInProgramaBrowserKey)
    private var interceptTerminalOpenCommandInProgramaBrowser = BrowserLinkOpenSettings.initialInterceptTerminalOpenCommandInProgramaBrowserValue()
    @AppStorage(BrowserLinkOpenSettings.browserHostWhitelistKey) private var browserHostWhitelist = BrowserLinkOpenSettings.defaultBrowserHostWhitelist
    @AppStorage(BrowserLinkOpenSettings.browserExternalOpenPatternsKey)
    private var browserExternalOpenPatterns = BrowserLinkOpenSettings.defaultBrowserExternalOpenPatterns
    @AppStorage(BrowserLinkOpenSettings.externalBrowserBundleIdentifierKey)
    private var externalBrowserBundleIdentifier = BrowserLinkOpenSettings.defaultExternalBrowserBundleIdentifier
    @AppStorage(BrowserInsecureHTTPSettings.allowlistKey) private var browserInsecureHTTPAllowlist = BrowserInsecureHTTPSettings.defaultAllowlistText
    @AppStorage(NotificationSoundSettings.key) private var notificationSound = NotificationSoundSettings.defaultValue
    @AppStorage(NotificationSoundSettings.customCommandKey) private var notificationCustomCommand = NotificationSoundSettings.defaultCustomCommand
    @AppStorage(MenuBarExtraSettings.showInMenuBarKey) private var showMenuBarExtra = MenuBarExtraSettings.defaultShowInMenuBar
    @AppStorage(LongCommandNotificationSettings.thresholdSecondsKey)
    private var longCommandThresholdSeconds = LongCommandNotificationSettings.defaultThresholdSeconds
    @AppStorage(QuitWarningSettings.warnBeforeQuitKey) private var warnBeforeQuitShortcut = QuitWarningSettings.defaultWarnBeforeQuit
    @AppStorage(AgentBrowserSplitSettings.key) private var openBrowserWithAgentSplits = AgentBrowserSplitSettings.defaultValue
    @AppStorage(ScrollbackPersistenceSettings.persistScrollbackKey) private var sessionPersistScrollback = ScrollbackPersistenceSettings.defaultPersistScrollback
    @AppStorage(ScrollbackPersistenceSettings.failureKey) private var scrollbackPersistenceFailure: String?
    @AppStorage(CommandPaletteSwitcherSearchSettings.searchAllSurfacesKey)
    private var commandPaletteSearchAllSurfaces = CommandPaletteSwitcherSearchSettings.defaultSearchAllSurfaces
    @AppStorage(ShortcutHintDebugSettings.alwaysShowHintsKey)
    private var alwaysShowShortcutHints = ShortcutHintDebugSettings.defaultAlwaysShowHints
    @AppStorage(WorkspacePlacementSettings.placementKey) private var newWorkspacePlacement = WorkspacePlacementSettings.defaultPlacement.rawValue
    @AppStorage(WorkspaceAutoReorderSettings.key) private var workspaceAutoReorder = WorkspaceAutoReorderSettings.defaultValue
    @AppStorage(SidebarActiveTabIndicatorSettings.styleKey)
    private var sidebarActiveTabIndicatorStyle = SidebarActiveTabIndicatorSettings.defaultStyle.rawValue
    @AppStorage("sidebarSelectionColorHex") private var sidebarSelectionColorHex: String?
    @AppStorage("sidebarNotificationBadgeColorHex") private var sidebarNotificationBadgeColorHex: String?
    @AppStorage(ShortcutHintDebugSettings.showHintsOnCommandHoldKey)
    private var showShortcutHintsOnCommandHold = ShortcutHintDebugSettings.defaultShowHintsOnCommandHold
    @AppStorage("sidebarTintHex") private var sidebarTintHex = SidebarTintDefaults.hex
    @AppStorage("sidebarTintHexLight") private var sidebarTintHexLight: String?
    @AppStorage("sidebarTintHexDark") private var sidebarTintHexDark: String?
    @AppStorage("sidebarTintOpacity") private var sidebarTintOpacity = SidebarTintDefaults.opacity
    @AppStorage("sidebarMatchTerminalBackground") private var sidebarMatchTerminalBackground = false
    @AppStorage("sidebarShowClaudeQuota") private var showClaudeQuota = true

    @ObservedObject private var notificationStore = TerminalNotificationStore.shared
    @StateObject private var keyboardShortcutSettingsObserver = KeyboardShortcutSettingsObserver.shared
    @StateObject private var terminalThemeSettings = TerminalThemeSettingsModel()
    @State private var shortcutResetToken = UUID()
    @State private var topBlurOpacity: Double = 0
    @State private var topBlurBaselineOffset: CGFloat?
    @State private var showClearBrowserHistoryConfirmation = false
    @State private var showOpenAccessConfirmation = false
    @State private var pendingOpenAccessMode: SocketControlMode?
    @State private var browserHistoryEntryCount: Int = 0
    @State private var browserInsecureHTTPAllowlistDraft = BrowserInsecureHTTPSettings.defaultAllowlistText
    @State private var socketPasswordDraft = ""
    @State private var socketPasswordStatusMessage: String?
    @State private var socketPasswordStatusIsError = false
    @State private var trustedDirectoriesDraft: String = ProgramaDirectoryTrust.shared.allTrustedPaths.joined(separator: "\n")
    @State private var installedExternalBrowsers: [(bundleIdentifier: String, name: String)] = []

    private var selectedWorkspacePlacement: NewWorkspacePlacement {
        NewWorkspacePlacement(rawValue: newWorkspacePlacement) ?? WorkspacePlacementSettings.defaultPlacement
    }

    private var minimalModeEnabled: Bool {
        WorkspacePresentationModeSettings.mode(for: workspacePresentationMode) == .minimal
    }

    private var minimalModeSubtitle: String {
        if minimalModeEnabled {
            return String(
                localized: "settings.app.minimalMode.subtitleOn",
                defaultValue: "Hide the workspace title bar and move workspace controls into the sidebar."
            )
        }
        return String(
            localized: "settings.app.minimalMode.subtitleOff",
            defaultValue: "Use the standard workspace title bar and controls."
        )
    }

    private var selectedSidebarActiveTabIndicatorStyle: SidebarActiveTabIndicatorStyle {
        SidebarActiveTabIndicatorSettings.resolvedStyle(rawValue: sidebarActiveTabIndicatorStyle)
    }

    private var sidebarIndicatorStyleSelection: Binding<String> {
        Binding(
            get: { selectedSidebarActiveTabIndicatorStyle.rawValue },
            set: { sidebarActiveTabIndicatorStyle = $0 }
        )
    }

    private var terminalLightThemeSelection: Binding<String> {
        Binding(
            get: { terminalThemeSettings.lightTheme },
            set: { terminalThemeSettings.selectLightTheme($0) }
        )
    }

    private var terminalDarkThemeSelection: Binding<String> {
        Binding(
            get: { terminalThemeSettings.darkTheme },
            set: { terminalThemeSettings.selectDarkTheme($0) }
        )
    }

    private var selectedSocketControlMode: SocketControlMode {
        SocketControlSettings.migrateMode(socketControlMode)
    }

    private var selectedBrowserThemeMode: BrowserThemeMode {
        BrowserThemeSettings.mode(for: browserThemeMode)
    }

    private var browserThemeModeSelection: Binding<String> {
        Binding(
            get: { browserThemeMode },
            set: { newValue in
                browserThemeMode = BrowserThemeSettings.mode(for: newValue).rawValue
            }
        )
    }

    private var socketModeSelection: Binding<String> {
        Binding(
            get: { socketControlMode },
            set: { newValue in
                let normalized = SocketControlSettings.migrateMode(newValue)
                if normalized == .allowAll && selectedSocketControlMode != .allowAll {
                    pendingOpenAccessMode = normalized
                    showOpenAccessConfirmation = true
                    return
                }
                socketControlMode = normalized.rawValue
                if normalized != .password {
                    socketPasswordStatusMessage = nil
                    socketPasswordStatusIsError = false
                }
            }
        )
    }

    private var minimalModeBinding: Binding<Bool> {
        Binding(
            get: { minimalModeEnabled },
            set: { newValue in
                workspacePresentationMode = newValue
                    ? WorkspacePresentationModeSettings.Mode.minimal.rawValue
                    : WorkspacePresentationModeSettings.Mode.standard.rawValue
                SettingsWindowController.shared.preserveFocusAfterPreferenceMutation()
            }
        )
    }

    private var hasSocketPasswordConfigured: Bool {
        SocketControlPasswordStore.hasConfiguredPassword()
    }

    private var browserHistorySubtitle: String {
        switch browserHistoryEntryCount {
        case 0:
            return String(localized: "settings.browser.history.subtitleEmpty", defaultValue: "No saved pages yet.")
        case 1:
            return String(localized: "settings.browser.history.subtitleOne", defaultValue: "1 saved page appears in omnibar suggestions.")
        default:
            return String(localized: "settings.browser.history.subtitleMany", defaultValue: "\(browserHistoryEntryCount) saved pages appear in omnibar suggestions.")
        }
    }

    private var browserInsecureHTTPAllowlistHasUnsavedChanges: Bool {
        browserInsecureHTTPAllowlistDraft != browserInsecureHTTPAllowlist
    }

    private func saveTrustedDirectories() {
        let paths = trustedDirectoriesDraft
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        ProgramaDirectoryTrust.shared.replaceAll(with: paths)
    }

    private var canPreviewNotificationSound: Bool {
        notificationSound != "none"
    }

    private var notificationPermissionStatusText: String {
        notificationStore.authorizationState.statusLabel
    }

    private var notificationPermissionStatusColor: Color {
        switch notificationStore.authorizationState {
        case .authorized, .provisional, .ephemeral:
            return .green
        case .denied:
            return .red
        case .unknown, .notDetermined:
            return .secondary
        }
    }

    private var notificationPermissionSubtitle: String {
        switch notificationStore.authorizationState {
        case .unknown, .notDetermined:
            return String(localized: "settings.notifications.permission.subtitle.notDetermined", defaultValue: "Desktop notifications are not enabled yet.")
        case .authorized:
            return String(localized: "settings.notifications.permission.subtitle.authorized", defaultValue: "Desktop notifications are enabled.")
        case .denied:
            return String(localized: "settings.notifications.permission.subtitle.denied", defaultValue: "Desktop notifications are disabled in System Settings.")
        case .provisional:
            return String(localized: "settings.notifications.permission.subtitle.provisional", defaultValue: "Desktop notifications are enabled with quiet delivery.")
        case .ephemeral:
            return String(localized: "settings.notifications.permission.subtitle.ephemeral", defaultValue: "Desktop notifications are temporarily enabled.")
        }
    }

    private var notificationPermissionActionTitle: String {
        switch notificationStore.authorizationState {
        case .unknown, .notDetermined:
            return String(localized: "settings.notifications.permission.action.enable", defaultValue: "Enable")
        case .authorized, .denied, .provisional, .ephemeral:
            return String(localized: "settings.notifications.permission.action.openSettings", defaultValue: "Open Settings")
        }
    }

    private func blurOpacity(forContentOffset offset: CGFloat) -> Double {
        guard let baseline = topBlurBaselineOffset else { return 0 }
        let reveal = (baseline - offset) / 24
        return Double(min(max(reveal, 0), 1))
    }

    private func previewNotificationSound() {
        NotificationSoundSettings.previewSound(value: notificationSound)
    }

    private func handleNotificationPermissionAction() {
        let state = notificationStore.authorizationState.statusLabel
#if DEBUG
        dlog("notification.ui enableTapped state=\(state)")
#endif
        NSLog("notification.ui enableTapped state=%@", state)
        switch notificationStore.authorizationState {
        case .unknown, .notDetermined:
            notificationStore.requestAuthorizationFromSettings()
        case .authorized, .denied, .provisional, .ephemeral:
            notificationStore.openNotificationSettings()
        }
    }

    private func saveSocketPassword() {
        let trimmed = socketPasswordDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            socketPasswordStatusMessage = String(localized: "settings.automation.socketPassword.enterFirst", defaultValue: "Enter a password first.")
            socketPasswordStatusIsError = true
            return
        }

        do {
            try SocketControlPasswordStore.savePassword(trimmed)
            socketPasswordDraft = ""
            socketPasswordStatusMessage = String(localized: "settings.automation.socketPassword.saved", defaultValue: "Password saved.")
            socketPasswordStatusIsError = false
        } catch {
            socketPasswordStatusMessage = String(localized: "settings.automation.socketPassword.saveFailed", defaultValue: "Failed to save password (\(error.localizedDescription)).")
            socketPasswordStatusIsError = true
        }
    }

    private func clearSocketPassword() {
        do {
            try SocketControlPasswordStore.clearPassword()
            socketPasswordDraft = ""
            socketPasswordStatusMessage = String(localized: "settings.automation.socketPassword.cleared", defaultValue: "Password cleared.")
            socketPasswordStatusIsError = false
        } catch {
            socketPasswordStatusMessage = String(localized: "settings.automation.socketPassword.clearFailed", defaultValue: "Failed to clear password (\(error.localizedDescription)).")
            socketPasswordStatusIsError = true
        }
    }

    var body: some View {
        let _ = keyboardShortcutSettingsObserver.revision
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch selectedTab {
                    case .general:
                        appSection
                        notificationsSection
                        resetSection
                    case .appearance:
                        appearanceSection
                        terminalAppearanceSection
                        sidebarSection
                    case .automation:
                        socketControlSection
                        agentsSection
                        portsSection
                        customCommandsSection
                    case .browser:
                        browsingSection
                        browserLinksSection
                        browserDataSection
                    case .shortcuts:
                        keyboardShortcutsSection
                    }
                }
                .padding(.horizontal, contentHorizontalInset)
                .padding(.vertical, contentVerticalPadding)
                .background(
                    GeometryReader { proxy in
                        Color.clear
                            .preference(
                                key: SettingsTopOffsetPreferenceKey.self,
                                value: proxy.frame(in: .named("SettingsScrollArea")).minY
                            )
                            .preference(
                                key: SettingsContentHeightPreferenceKey.self,
                                value: proxy.size.height
                            )
                    }
                )
            }
            .coordinateSpace(name: "SettingsScrollArea")
            .onPreferenceChange(SettingsTopOffsetPreferenceKey.self) { value in
                if topBlurBaselineOffset == nil {
                    topBlurBaselineOffset = value
                }
                topBlurOpacity = blurOpacity(forContentOffset: value)
            }
            .onPreferenceChange(SettingsContentHeightPreferenceKey.self) { value in
                measuredContentHeight = value
            }
            .onChange(of: selectedTab) { _, _ in
                // Each tab starts at the top, so the old baseline would leave the
                // hairline showing over content that is no longer scrolled.
                topBlurBaselineOffset = nil
                topBlurOpacity = 0
            }
            // A safe-area inset rather than an overlay: the scroll view then knows the
            // header is there, so its scroller starts below the header instead of
            // running the full height and disappearing behind it.
            .safeAreaInset(edge: .top, spacing: 0) {
            ZStack(alignment: .top) {
                // A gradient that fades to clear never fully hides what scrolls behind
                // it, so rows used to read straight through the tab strip. A solid
                // header material plus a hairline on scroll is what AppKit does.
                AboutVisualEffectBackground(material: .headerView, blendingMode: .withinWindow)

                VStack(alignment: .leading, spacing: 10) {
                    // No in-window title: the window is already the Settings window, so
                    // this row is just the traffic lights on the left and the one action
                    // on the right, the way System Settings uses its titlebar band.
                    HStack {
                        Spacer(minLength: 0)
                        SettingsHeaderActionButton(
                            title: String(localized: "settings.app.settingsFile.openButton", defaultValue: "Open settings.json"),
                            helpText: KeyboardShortcutSettings.settingsFileStore.settingsFileDisplayPath(),
                            accessibilityIdentifier: "SettingsFileOpenButton",
                            action: openProgramaSettingsFileInTextEdit
                        )
                    }
                    .frame(height: titlebarBandHeight)

                    // Lives in the header rather than the scroll content so it stays
                    // put while a tab's rows scroll underneath it.
                    SettingsTabStrip(selection: $selectedTab) { natural in
                        let floor = natural + (contentHorizontalInset * 2)
                        if abs(floor - minimumWindowWidth) > 0.5 {
                            minimumWindowWidth = floor
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, contentHorizontalInset)
                .padding(.top, 6)
                .padding(.bottom, 12)
            }
                .frame(height: headerHeight)
                .overlay(
                    Rectangle()
                        .fill(Color(nsColor: .separatorColor))
                        .frame(height: 1)
                        // Only once something is actually tucked under the header.
                        .opacity(topBlurOpacity),
                    alignment: .bottom
                )
            }
            // The window draws under the titlebar, so the header has to start at the
            // very top of the frame for its action to sit level with the traffic lights.
            .ignoresSafeArea(.container, edges: .top)
        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
        .background(
            SettingsWindowHeightFitter(
                contentHeight: measuredContentHeight,
                headerHeight: headerHeight,
                minimumWidth: minimumWindowWidth
            )
            .frame(width: 0, height: 0)
        )
        .toggleStyle(.switch)
        .onAppear {
            BrowserHistoryStore.shared.loadIfNeeded()
            notificationStore.refreshAuthorizationStatus()
            browserThemeMode = BrowserThemeSettings.mode(defaults: .standard).rawValue
            browserHistoryEntryCount = BrowserHistoryStore.shared.entries.count
            browserInsecureHTTPAllowlistDraft = browserInsecureHTTPAllowlist
        }
        .onChange(of: browserInsecureHTTPAllowlist) { oldValue, newValue in
            // Keep draft in sync with external changes unless the user has local unsaved edits.
            if browserInsecureHTTPAllowlistDraft == oldValue {
                browserInsecureHTTPAllowlistDraft = newValue
            }
        }
        .onReceive(BrowserHistoryStore.shared.$entries) { entries in
            browserHistoryEntryCount = entries.count
        }
        .onReceive(NotificationCenter.default.publisher(for: SettingsNavigationRequest.notificationName)) { notification in
            guard let target = SettingsNavigationRequest.target(from: notification) else { return }
            // Select the owning tab first. The anchor only exists while its tab is
            // the selected one, so scrolling in the same pass would find nothing.
            selectedTab = SettingsTab.owning(target)
            DispatchQueue.main.async {
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(target, anchor: .top)
                }
            }
        }
        .confirmationDialog(
            String(localized: "settings.browser.history.clearDialog.title", defaultValue: "Clear browser history?"),
            isPresented: $showClearBrowserHistoryConfirmation,
            titleVisibility: .visible
        ) {
            Button(String(localized: "settings.browser.history.clearDialog.confirm", defaultValue: "Clear History"), role: .destructive) {
                BrowserHistoryStore.shared.clearHistory()
            }
            Button(String(localized: "settings.browser.history.clearDialog.cancel", defaultValue: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "settings.browser.history.clearDialog.message", defaultValue: "This removes visited-page suggestions from the browser omnibar."))
        }
        .confirmationDialog(
            String(localized: "settings.automation.openAccess.dialog.title", defaultValue: "Enable full open access?"),
            isPresented: $showOpenAccessConfirmation,
            titleVisibility: .visible
        ) {
            Button(String(localized: "settings.automation.openAccess.dialog.confirm", defaultValue: "Enable Full Open Access"), role: .destructive) {
                socketControlMode = (pendingOpenAccessMode ?? .allowAll).rawValue
                pendingOpenAccessMode = nil
            }
            Button(String(localized: "settings.automation.openAccess.dialog.cancel", defaultValue: "Cancel"), role: .cancel) {
                pendingOpenAccessMode = nil
            }
        } message: {
            Text(String(localized: "settings.automation.openAccess.dialog.message", defaultValue: "This disables ancestry and password checks and opens the socket to all local users. Only enable when you understand the risk."))
        }
        }
    }

    @ViewBuilder
    private var appSection: some View {
        SettingsSectionHeader(title: String(localized: "settings.section.app", defaultValue: "App"))
        SettingsCard {
            SettingsPickerRow(
                String(localized: "settings.app.newWorkspacePlacement", defaultValue: "New Workspace Placement"),
                subtitle: selectedWorkspacePlacement.description,
                controlWidth: pickerColumnWidth,
                selection: $newWorkspacePlacement
            ) {
                ForEach(NewWorkspacePlacement.allCases) { placement in
                    Text(placement.displayName).tag(placement.rawValue)
                }
            }

            SettingsCardDivider()

            // Next to New Workspace Placement: both decide where a workspace sits
            // in the sidebar list, so they read as one question.
            SettingsCardRow(
                String(localized: "settings.app.reorderOnNotification", defaultValue: "Reorder on Notification"),
                subtitle: String(localized: "settings.app.reorderOnNotification.subtitle", defaultValue: "Move workspaces to the top when they receive a notification. Disable for stable shortcut positions.")
            ) {
                Toggle("", isOn: $workspaceAutoReorder)
                    .labelsHidden()
                    .controlSize(.small)
            }

            SettingsCardDivider()

            SettingsCardRow(
                String(localized: "settings.app.preferredEditor", defaultValue: "Open Files With"),
                subtitle: String(localized: "settings.app.preferredEditor.subtitle", defaultValue: "Command to open files on Cmd-click. Leave empty for system default.")
            ) {
                TextField(
                    String(localized: "settings.app.preferredEditor.placeholder", defaultValue: "e.g. code, zed, subl"),
                    text: $preferredEditorCommand
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
            }

            SettingsCardDivider()

            SettingsCardRow(
                String(localized: "settings.app.showInMenuBar", defaultValue: "Show in Menu Bar"),
                subtitle: String(localized: "settings.app.showInMenuBar.subtitle", defaultValue: "Keep Programa in the menu bar for unread notifications and quick actions.")
            ) {
                Toggle("", isOn: $showMenuBarExtra)
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityLabel(
                        String(localized: "settings.app.showInMenuBar", defaultValue: "Show in Menu Bar")
                    )
            }


            SettingsCardDivider()

            SettingsCardRow(
                String(localized: "settings.app.warnBeforeQuit", defaultValue: "Warn Before Quit"),
                subtitle: warnBeforeQuitShortcut
                    ? String(localized: "settings.app.warnBeforeQuit.subtitleOn", defaultValue: "Show a confirmation before quitting with Cmd+Q.")
                    : String(localized: "settings.app.warnBeforeQuit.subtitleOff", defaultValue: "Cmd+Q quits immediately without confirmation.")
            ) {
                Toggle("", isOn: $warnBeforeQuitShortcut)
                    .labelsHidden()
                    .controlSize(.small)
            }

            SettingsCardDivider()

            SettingsCardRow(
                String(localized: "settings.app.persistScrollback", defaultValue: "Save Scrollback on Quit"),
                subtitle: scrollbackPersistenceFailure != nil
                    ? String(localized: "settings.app.persistScrollback.incomplete", defaultValue: "Scrollback privacy could not be fully applied. Retry to finish protecting existing sessions.")
                    : sessionPersistScrollback
                    ? String(localized: "settings.app.persistScrollback.subtitleOn", defaultValue: "Terminal scrollback is saved and restored on next launch.")
                    : String(localized: "settings.app.persistScrollback.subtitleOff", defaultValue: "Terminal scrollback is not written to disk.")
            ) {
                Toggle("", isOn: Binding(
                    get: { sessionPersistScrollback },
                    set: { ScrollbackPersistenceSettings.setEnabled($0) }
                ))
                    .labelsHidden()
                    .controlSize(.small)
            }

            if scrollbackPersistenceFailure != nil {
                SettingsCardRow(
                    String(localized: "settings.app.persistScrollback.warning", defaultValue: "Some older sessions may still write terminal output to disk.")
                ) {
                    Button(String(localized: "settings.app.persistScrollback.retry", defaultValue: "Retry")) {
                        ScrollbackPersistenceSettings.retry()
                    }
                }
            }

            SettingsCardDivider()

            SettingsCardRow(
                String(localized: "settings.app.commandPaletteSearchAllSurfaces", defaultValue: "Command Palette Searches All Surfaces"),
                subtitle: commandPaletteSearchAllSurfaces
                    ? String(localized: "settings.app.commandPaletteSearchAllSurfaces.subtitleOn", defaultValue: "Cmd+P also matches terminal, browser, and markdown surfaces across workspaces.")
                    : String(localized: "settings.app.commandPaletteSearchAllSurfaces.subtitleOff", defaultValue: "Cmd+P matches workspace rows only.")
            ) {
                Toggle("", isOn: $commandPaletteSearchAllSurfaces)
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("CommandPaletteSearchAllSurfacesToggle")
                    .accessibilityLabel(
                        String(localized: "settings.app.commandPaletteSearchAllSurfaces", defaultValue: "Command Palette Searches All Surfaces")
                    )
            }

        }

    }

    @ViewBuilder
    private var notificationsSection: some View {
        SettingsSectionHeader(title: String(localized: "settings.section.notifications", defaultValue: "Notifications"))
        SettingsCard {
            SettingsCardRow(
                String(localized: "settings.notifications.desktop.title", defaultValue: "Desktop Notifications"),
                subtitle: notificationPermissionSubtitle
            ) {
                HStack(spacing: 6) {
                    Text(notificationPermissionStatusText)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(notificationPermissionStatusColor)
                        .frame(width: 98, alignment: .trailing)

                    Button(notificationPermissionActionTitle) {
                        handleNotificationPermissionAction()
                    }
                    .controlSize(.small)
                }
            }

            SettingsCardDivider()

            SettingsCardRow(
                String(localized: "settings.notifications.sound.title", defaultValue: "Notification Sound"),
                subtitle: String(localized: "settings.notifications.sound.subtitle", defaultValue: "Sound played when a notification arrives."),
                controlWidth: notificationSoundControlWidth
            ) {
                HStack(spacing: 6) {
                    Picker("", selection: $notificationSound) {
                        ForEach(NotificationSoundSettings.systemSounds, id: \.value) { sound in
                            Text(sound.label).tag(sound.value)
                        }
                    }
                    .labelsHidden()
                    Button {
                        previewNotificationSound()
                    } label: {
                        Image(systemName: "play.fill")
                            .symbolRasterSize(9)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!canPreviewNotificationSound)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }

            SettingsCardDivider()

            SettingsCardRow(
                String(localized: "settings.notifications.command.title", defaultValue: "Notification Command"),
                subtitle: String(
                    localized: "settings.notifications.command.subtitle",
                    defaultValue: "Run a shell command when a notification arrives. $PROGRAMA_NOTIFICATION_TITLE, $PROGRAMA_NOTIFICATION_SUBTITLE, $PROGRAMA_NOTIFICATION_BODY are set."
                )
            ) {
                TextField(
                    String(localized: "settings.notifications.command.placeholder", defaultValue: "say \"done\""),
                    text: $notificationCustomCommand
                )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
            }

            SettingsCardDivider()

            SettingsCardRow(
                String(localized: "settings.notifications.longCommandThreshold.title", defaultValue: "Long Command Notification"),
                subtitle: String(
                    localized: "settings.notifications.longCommandThreshold.subtitle",
                    defaultValue: "Notify when a command finishes in a pane you're not looking at, if it ran at least this long. Set to 0 to disable."
                ),
                controlWidth: pickerColumnWidth
            ) {
                HStack(spacing: 4) {
                    TextField("", value: $longCommandThresholdSeconds, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 60)
                        .accessibilityLabel(
                            String(localized: "settings.notifications.longCommandThreshold.title", defaultValue: "Long Command Notification")
                        )
                    Text(String(localized: "settings.notifications.longCommandThreshold.unit", defaultValue: "sec"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var terminalAppearanceSection: some View {
        SettingsSectionHeader(
            title: String(localized: "settings.section.terminal", defaultValue: "Terminal")
        )
        SettingsCard {
            SettingsPickerRow(
                String(localized: "settings.terminalTheme.light", defaultValue: "Light Theme"),
                subtitle: terminalThemeSettings.isManagedBySettingsFile
                    ? String(localized: "settings.terminalTheme.managedByFile", defaultValue: "Managed in settings.json")
                    : String(localized: "settings.terminalTheme.light.subtitle", defaultValue: "Used when Programa has a light appearance."),
                controlWidth: pickerColumnWidth,
                selection: terminalLightThemeSelection,
                accessibilityId: "TerminalLightThemePicker"
            ) {
                Text(
                    String(
                        localized: "settings.terminalTheme.useGhosttyConfiguration",
                        defaultValue: "Use Ghostty Configuration"
                    )
                ).tag("")
                ForEach(terminalThemeSettings.themeNames, id: \.self) { themeName in
                    Text(themeName).tag(themeName)
                }
            }
            .disabled(terminalThemeSettings.isManagedBySettingsFile)

            SettingsCardDivider()

            SettingsPickerRow(
                String(localized: "settings.terminalTheme.dark", defaultValue: "Dark Theme"),
                subtitle: terminalThemeSettings.isManagedBySettingsFile
                    ? String(localized: "settings.terminalTheme.managedByFile", defaultValue: "Managed in settings.json")
                    : String(localized: "settings.terminalTheme.dark.subtitle", defaultValue: "Used when Programa has a dark appearance."),
                controlWidth: pickerColumnWidth,
                selection: terminalDarkThemeSelection,
                accessibilityId: "TerminalDarkThemePicker"
            ) {
                Text(
                    String(
                        localized: "settings.terminalTheme.useGhosttyConfiguration",
                        defaultValue: "Use Ghostty Configuration"
                    )
                ).tag("")
                ForEach(terminalThemeSettings.themeNames, id: \.self) { themeName in
                    Text(themeName).tag(themeName)
                }
            }
            .disabled(terminalThemeSettings.isManagedBySettingsFile)

            SettingsCardDivider()

            SettingsCardRow(
                String(localized: "settings.terminalOpacity.title", defaultValue: "Opacity"),
                subtitle: terminalThemeSettings.isOpacityManagedBySettingsFile
                    ? String(localized: "settings.terminalTheme.managedByFile", defaultValue: "Managed in settings.json")
                    : String(
                        localized: "settings.terminalOpacity.subtitle",
                        defaultValue: "Terminal background transparency."
                    ),
                controlWidth: pickerColumnWidth
            ) {
                Slider(
                    value: Binding(
                        get: { terminalThemeSettings.opacity },
                        set: { terminalThemeSettings.setOpacity($0) }
                    ),
                    in: 0...1
                )
            }
            .disabled(terminalThemeSettings.isOpacityManagedBySettingsFile)

            SettingsCardDivider()

            SettingsCardRow(
                String(localized: "settings.terminalBlur.title", defaultValue: "Background Blur"),
                subtitle: terminalThemeSettings.isBlurManagedBySettingsFile
                    ? String(localized: "settings.terminalTheme.managedByFile", defaultValue: "Managed in settings.json")
                    : String(
                        localized: "settings.terminalBlur.subtitle",
                        defaultValue: "Blur the desktop behind a transparent terminal background."
                    )
            ) {
                Toggle(
                    "",
                    isOn: Binding(
                        get: { terminalThemeSettings.blurEnabled },
                        set: { terminalThemeSettings.setBlurEnabled($0) }
                    )
                )
                .labelsHidden()
                .controlSize(.small)
            }
            .disabled(terminalThemeSettings.isBlurManagedBySettingsFile)

            SettingsCardDivider()

            SettingsCardRow(
                String(localized: "settings.terminalFont.title", defaultValue: "Font"),
                subtitle: terminalThemeSettings.isFontManagedBySettingsFile
                    ? String(localized: "settings.terminalTheme.managedByFile", defaultValue: "Managed in settings.json")
                    : String(
                        localized: "settings.terminalFont.subtitle",
                        defaultValue: "Font family and size used in the terminal."
                    )
            ) {
                HStack(spacing: 6) {
                    TextField(
                        String(localized: "settings.terminalFont.familyPlaceholder", defaultValue: "System Default"),
                        text: Binding(
                            get: { terminalThemeSettings.fontFamily },
                            set: { terminalThemeSettings.setFontFamily($0) }
                        )
                    )
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                    TextField(
                        "",
                        value: Binding(
                            get: { terminalThemeSettings.fontSize },
                            set: { terminalThemeSettings.setFontSize($0) }
                        ),
                        format: .number
                    )
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 44)
                        .accessibilityLabel(
                            String(localized: "settings.terminalFont.title", defaultValue: "Font")
                        )
                }
            }
            .disabled(terminalThemeSettings.isFontManagedBySettingsFile)

            if let errorMessage = terminalThemeSettings.errorMessage {
                SettingsCardDivider()
                SettingsCardNote(errorMessage)
            }
        }

    }

    @ViewBuilder
    private var appearanceSection: some View {
        SettingsSectionHeader(title: String(localized: "settings.section.appearance", defaultValue: "Appearance"))
        SettingsCard {
            ThemePickerRow(selectedMode: appearanceMode, onSelect: { mode in appearanceMode = mode.rawValue })

            SettingsCardDivider()

            SettingsCardRow(
                String(localized: "settings.app.minimalMode", defaultValue: "Minimal Mode"),
                subtitle: minimalModeSubtitle
            ) {
                Toggle("", isOn: minimalModeBinding)
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsMinimalModeToggle")
                    .accessibilityLabel(
                        String(localized: "settings.app.minimalMode", defaultValue: "Minimal Mode")
                    )
            }
        }

    }

    @ViewBuilder
    private var sidebarSection: some View {
        SettingsSectionHeader(title: String(localized: "settings.section.sidebar", defaultValue: "Sidebar"))
        SettingsCard {
            SettingsPickerRow(
                String(localized: "settings.workspaceColors.indicator", defaultValue: "Workspace Color Indicator"),
                controlWidth: pickerColumnWidth,
                selection: sidebarIndicatorStyleSelection
            ) {
                ForEach(SidebarActiveTabIndicatorStyle.allCases) { style in
                    Text(style.displayName).tag(style.rawValue)
                }
            }
            // Selection-highlight and notification-badge hex pickers, the inline
            // palette editor and a section-local Reset Palette used to follow. The
            // editor duplicated settings.json, which its own note already pointed at
            // as the way to manage named colors, and the two hex pickers were the
            // same per-pixel tuning as the sidebar tints. "Reset all settings" still
            // calls WorkspaceTabColorSettings.reset() and nils both hex keys, so
            // anything set while these rows existed is still recoverable.

            // "Match Terminal Background" removed with the inverted glass layout:
            // the sidebar sits on the system-appearance glass backdrop by design,
            // and the toggle's only remaining effect was forcing terminal-derived
            // text contrast that fought the system scheme.

            SettingsCardDivider()

            SettingsCardRow(
                String(localized: "settings.sidebarAppearance.showClaudeQuota", defaultValue: "Show Provider Usage"),
                subtitle: String(localized: "settings.sidebarAppearance.showClaudeQuota.subtitle", defaultValue: "Show on-demand usage for providers with available usage data in the sidebar footer.")
            ) {
                Toggle("", isOn: $showClaudeQuota)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .accessibilityLabel(
                        String(localized: "settings.sidebarAppearance.showClaudeQuota", defaultValue: "Show Provider Usage")
                    )
            }
            // Light/dark tint hex, tint opacity and a section-local reset used to
            // live here. They were per-pixel tuning of one surface, shipped to
            // every user, and the same four keys are already bound by the Debug
            // window (DebugWindows.swift) where that kind of tuning belongs. The
            // bindings stay on this view because "Reset all settings" below still
            // restores them for anyone who set a value while the rows existed.
        }
    }

    @ViewBuilder
    private var socketControlSection: some View {
        SettingsSectionHeader(title: String(localized: "settings.section.socketControl", defaultValue: "Socket Control"))
        SettingsCard {
            SettingsPickerRow(
                String(localized: "settings.automation.socketMode", defaultValue: "Socket Control Mode"),
                subtitle: selectedSocketControlMode.description,
                controlWidth: pickerColumnWidth,
                selection: socketModeSelection,
                accessibilityId: "AutomationSocketModePicker"
            ) {
                ForEach(SocketControlMode.uiCases) { mode in
                    Text(mode.displayName).tag(mode.rawValue)
                }
            }

            SettingsCardDivider()

            SettingsCardNote(String(localized: "settings.automation.socketMode.note", defaultValue: "Controls access to the local Unix socket for programmatic control. Choose a mode that matches your threat model."))
            if selectedSocketControlMode == .password {
                SettingsCardDivider()
                SettingsCardRow(
                    String(localized: "settings.automation.socketPassword", defaultValue: "Socket Password"),
                    subtitle: hasSocketPasswordConfigured
                        ? String(localized: "settings.automation.socketPassword.subtitleSet", defaultValue: "Stored in Application Support.")
                        : String(localized: "settings.automation.socketPassword.subtitleUnset", defaultValue: "No password set. External clients will be blocked until one is configured.")
                ) {
                    HStack(spacing: 8) {
                        SecureField(String(localized: "settings.automation.socketPassword.placeholder", defaultValue: "Password"), text: $socketPasswordDraft)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 170)
                        Button(hasSocketPasswordConfigured ? String(localized: "settings.automation.socketPassword.change", defaultValue: "Change") : String(localized: "settings.automation.socketPassword.set", defaultValue: "Set")) {
                            saveSocketPassword()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(socketPasswordDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if hasSocketPasswordConfigured {
                            Button(String(localized: "settings.automation.socketPassword.clear", defaultValue: "Clear")) {
                                clearSocketPassword()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
                if let message = socketPasswordStatusMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(socketPasswordStatusIsError ? Color.red : Color.secondary)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 8)
                }
            }
            if selectedSocketControlMode == .allowAll {
                SettingsCardDivider()
                Text(String(localized: "settings.automation.openAccessWarning", defaultValue: "Warning: Full open access makes the control socket world-readable/writable on this Mac and disables auth checks. Use only for local debugging."))
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            }
            SettingsCardNote(String(localized: "settings.automation.socketOverrides.note", defaultValue: "Overrides: PROGRAMA_SOCKET_ENABLE, PROGRAMA_SOCKET_MODE, and PROGRAMA_SOCKET_PATH (set PROGRAMA_ALLOW_SOCKET_OVERRIDE=1 for release builds)."))
        }

    }

    @ViewBuilder
    private var agentsSection: some View {
        SettingsSectionHeader(title: String(localized: "settings.section.agents", defaultValue: "Agents"))
        SettingsCard {
            SettingsCardRow(
                String(localized: "settings.automation.claudeCode", defaultValue: "Claude Code Integration"),
                subtitle: claudeCodeHooksEnabled
                    ? String(localized: "settings.automation.claudeCode.subtitleOn", defaultValue: "Sidebar shows Claude session status and notifications.")
                    : String(localized: "settings.automation.claudeCode.subtitleOff", defaultValue: "Claude Code runs without Programa integration.")
            ) {
                Toggle("", isOn: $claudeCodeHooksEnabled)
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsClaudeCodeHooksToggle")
            }

            SettingsCardDivider()

            SettingsCardNote(String(localized: "settings.automation.claudeCode.note", defaultValue: "When enabled, Programa wraps the claude command to inject session tracking and notification hooks. Disable if you prefer to manage Claude Code hooks yourself."))

            SettingsCardDivider()

            SettingsCardRow(
                String(localized: "settings.agents.browserSplit", defaultValue: "Open a browser beside new agents"),
                subtitle: openBrowserWithAgentSplits
                    ? String(localized: "settings.agents.browserSplit.subtitleOn", defaultValue: "New agent workspaces get a browser split next to the terminal.")
                    : String(localized: "settings.agents.browserSplit.subtitleOff", defaultValue: "New agent workspaces open with a terminal only.")
            ) {
                Toggle("", isOn: $openBrowserWithAgentSplits)
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsAgentBrowserSplitToggle")
            }
        }

        SettingsCard {
            SettingsCardRow(
                String(localized: "settings.automation.agentScreenDetection", defaultValue: "Screen-Based Agent Detection"),
                subtitle: agentScreenDetectionEnabled
                    ? String(localized: "settings.automation.agentScreenDetection.subtitleOn", defaultValue: "Infers working/blocked/idle status for agent CLIs without an installed integration by reading the terminal screen.")
                    : String(localized: "settings.automation.agentScreenDetection.subtitleOff", defaultValue: "Agent status is only shown for CLIs with an installed integration.")
            ) {
                Toggle("", isOn: $agentScreenDetectionEnabled)
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsAgentScreenDetectionToggle")
            }

            SettingsCardDivider()

            SettingsCardNote(String(localized: "settings.automation.agentScreenDetection.note", defaultValue: "Applies to agents such as Gemini CLI and GitHub Copilot CLI that have no installed hooks. A hooks-managed session (Claude Code, Codex, OpenCode) always takes priority over this."))
        }

        SettingsCard {
            SettingsCardRow(
                String(localized: "settings.automation.claudeCode.customPath", defaultValue: "Claude Binary Path"),
                subtitle: String(localized: "settings.automation.claudeCode.customPath.subtitle", defaultValue: "Custom path to the claude binary. Leave empty to use PATH.")
            ) {
                TextField(
                    String(localized: "settings.automation.claudeCode.customPath.placeholder", defaultValue: "e.g. /usr/local/bin/claude"),
                    text: $customClaudePath
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
            }
        }

    }

    @ViewBuilder
    private var portsSection: some View {
        SettingsSectionHeader(title: String(localized: "settings.section.ports", defaultValue: "Ports"))
        SettingsCard {
            SettingsCardRow(String(localized: "settings.automation.portBase", defaultValue: "Port Base"), subtitle: String(localized: "settings.automation.portBase.subtitle", defaultValue: "Starting port for PROGRAMA_PORT env var."), controlWidth: pickerColumnWidth) {
                TextField("", value: programaPortBaseBinding, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
            }

            SettingsCardDivider()

            SettingsCardRow(String(localized: "settings.automation.portRange", defaultValue: "Port Range Size"), subtitle: String(localized: "settings.automation.portRange.subtitle", defaultValue: "Number of ports per workspace."), controlWidth: pickerColumnWidth) {
                TextField("", value: programaPortRangeBinding, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
            }

            SettingsCardDivider()

            SettingsCardNote(String(localized: "settings.automation.port.note", defaultValue: "Each workspace gets PROGRAMA_PORT and PROGRAMA_PORT_END env vars with a dedicated port range. New terminals inherit these values."))
        }

    }

    private var programaPortBaseBinding: Binding<Int> {
        Binding(
            get: { programaPortBase },
            set: { requestedBase in
                let value = ProgramaPortRangePolicy.clamped(
                    base: requestedBase,
                    range: programaPortRange
                )
                programaPortBase = value.base
                programaPortRange = value.range
            }
        )
    }

    private var programaPortRangeBinding: Binding<Int> {
        Binding(
            get: { programaPortRange },
            set: { requestedRange in
                let value = ProgramaPortRangePolicy.clamped(
                    base: programaPortBase,
                    range: requestedRange
                )
                programaPortBase = value.base
                programaPortRange = value.range
            }
        )
    }

    @ViewBuilder
    private var customCommandsSection: some View {
        SettingsSectionHeader(title: String(localized: "settings.section.customCommands", defaultValue: "Custom Commands"))
        SettingsCard {
            VStack(alignment: .leading, spacing: 6) {
                SettingsCardRow(
                    String(localized: "settings.customCommands.trustedDirectories", defaultValue: "Trusted Directories"),
                    subtitle: String(localized: "settings.customCommands.trustedDirectories.subtitle", defaultValue: "Commands from programa.json in these directories run without confirmation. One path per line.")
                ) {
                    EmptyView()
                }

                TextEditor(text: $trustedDirectoriesDraft)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 60, maxHeight: 120)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                    )
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                    .onChange(of: trustedDirectoriesDraft) {
                        saveTrustedDirectories()
                    }
            }

            SettingsCardDivider()
            SettingsCardNote(String(localized: "settings.customCommands.trustedDirectories.note", defaultValue: "Place a programa.json in your project root to define custom commands. Trust a directory from the confirmation dialog, or add paths here. For git repos, trusting the root covers all subdirectories."))
        }

    }

    @ViewBuilder
    private var browsingSection: some View {
        SettingsSectionHeader(title: String(localized: "settings.section.browsing", defaultValue: "Browsing"))
            .id(SettingsNavigationTarget.browser)
            .accessibilityIdentifier("SettingsBrowserSection")
        SettingsCard {
            SettingsPickerRow(
                String(localized: "settings.browser.searchEngine", defaultValue: "Default Search Engine"),
                subtitle: String(localized: "settings.browser.searchEngine.subtitle", defaultValue: "Used by the browser address bar when input is not a URL."),
                controlWidth: pickerColumnWidth,
                selection: $browserSearchEngine
            ) {
                ForEach(BrowserSearchEngine.allCases) { engine in
                    Text(engine.displayName).tag(engine.rawValue)
                }
            }

            SettingsCardDivider()

            SettingsCardRow(String(localized: "settings.browser.searchSuggestions", defaultValue: "Show Search Suggestions")) {
                Toggle("", isOn: $browserSearchSuggestionsEnabled)
                    .labelsHidden()
                    .controlSize(.small)
            }

            SettingsCardDivider()

            SettingsPickerRow(
                String(localized: "settings.browser.theme", defaultValue: "Browser Theme"),
                subtitle: selectedBrowserThemeMode == .system
                    ? String(localized: "settings.browser.theme.subtitleSystem", defaultValue: "System follows app and macOS appearance.")
                    : String(localized: "settings.browser.theme.subtitleForced", defaultValue: "\(selectedBrowserThemeMode.displayName) forces that color scheme for compatible pages."),
                controlWidth: pickerColumnWidth,
                selection: browserThemeModeSelection
            ) {
                ForEach(BrowserThemeMode.allCases) { mode in
                    Text(mode.displayName).tag(mode.rawValue)
                }
            }
        }

    }

    @ViewBuilder
    private var browserLinksSection: some View {
        SettingsSectionHeader(title: String(localized: "settings.section.browserLinks", defaultValue: "Link Handling"))
        SettingsCard {
            SettingsCardRow(
                String(localized: "settings.browser.openTerminalLinks", defaultValue: "Open Terminal Links in Programa Browser"),
                subtitle: String(localized: "settings.browser.openTerminalLinks.subtitle", defaultValue: "When off, links clicked in terminal output open in your default browser.")
            ) {
                Toggle("", isOn: $openTerminalLinksInProgramaBrowser)
                    .labelsHidden()
                    .controlSize(.small)
            }

            SettingsCardDivider()

            SettingsCardRow(
                String(localized: "settings.browser.interceptOpen", defaultValue: "Intercept open http(s) in Terminal"),
                subtitle: String(localized: "settings.browser.interceptOpen.subtitle", defaultValue: "When off, `open https://...` and `open http://...` always use your default browser.")
            ) {
                Toggle("", isOn: $interceptTerminalOpenCommandInProgramaBrowser)
                    .labelsHidden()
                    .controlSize(.small)
            }

            SettingsCardDivider()

            SettingsPickerRow(
                String(localized: "settings.browser.externalBrowser", defaultValue: "Open External Links With"),
                subtitle: String(localized: "settings.browser.externalBrowser.subtitle", defaultValue: "Used for terminal links and browser links that open outside Programa."),
                controlWidth: pickerColumnWidth,
                selection: $externalBrowserBundleIdentifier
            ) {
                Text(String(localized: "settings.browser.externalBrowser.systemDefault", defaultValue: "System Default")).tag("")
                ForEach(installedExternalBrowsers, id: \.bundleIdentifier) { browser in
                    Text(browser.name).tag(browser.bundleIdentifier)
                }
            }
            .onAppear {
                installedExternalBrowsers = BrowserLinkOpenSettings.installedBrowsers()
            }

            if openTerminalLinksInProgramaBrowser || interceptTerminalOpenCommandInProgramaBrowser {
                SettingsCardDivider()

                VStack(alignment: .leading, spacing: 6) {
                    SettingsCardRow(
                        String(localized: "settings.browser.hostWhitelist", defaultValue: "Hosts to Open in Embedded Browser"),
                        subtitle: String(localized: "settings.browser.hostWhitelist.subtitle", defaultValue: "Applies to terminal link clicks and intercepted `open https://...` calls. Only these hosts open in Programa. Others open in your default browser. One host or wildcard per line (for example: example.com, *.internal.example). Leave empty to open all hosts in Programa.")
                    ) {
                        EmptyView()
                    }

                    TextEditor(text: $browserHostWhitelist)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 60, maxHeight: 120)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                        )
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                }

                SettingsCardDivider()

                VStack(alignment: .leading, spacing: 6) {
                    SettingsCardRow(
                        String(localized: "settings.browser.externalPatterns", defaultValue: "URLs to Always Open Externally"),
                        subtitle: String(localized: "settings.browser.externalPatterns.subtitle", defaultValue: "Applies to terminal link clicks and intercepted `open https://...` calls. One rule per line. Plain text matches any URL substring, or prefix with `re:` for regex (for example: openai.com/usage, re:^https?://[^/]*\\.example\\.com/(billing|usage)).")
                    ) {
                        EmptyView()
                    }

                    TextEditor(text: $browserExternalOpenPatterns)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 60, maxHeight: 120)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                        )
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                }
            }

            SettingsCardDivider()

            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "settings.browser.httpAllowlist", defaultValue: "HTTP Hosts Allowed in Embedded Browser"))
                    .font(.system(size: 13, weight: .semibold))

                Text(String(localized: "settings.browser.httpAllowlist.description", defaultValue: "Controls which HTTP (non-HTTPS) hosts can open in Programa without a warning prompt. Defaults include localhost, 127.0.0.1, ::1, 0.0.0.0, and *.localtest.me."))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextEditor(text: $browserInsecureHTTPAllowlistDraft)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .frame(minHeight: 86)
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    )
                    .accessibilityIdentifier("SettingsBrowserHTTPAllowlistField")

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 10) {
                        Text(String(localized: "settings.browser.httpAllowlist.hint", defaultValue: "One host or wildcard per line (for example: localhost, 127.0.0.1, ::1, 0.0.0.0, *.localtest.me)."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Spacer(minLength: 0)

                        Button(String(localized: "settings.browser.httpAllowlist.save", defaultValue: "Save")) {
                            saveBrowserInsecureHTTPAllowlist()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!browserInsecureHTTPAllowlistHasUnsavedChanges)
                        .accessibilityIdentifier("SettingsBrowserHTTPAllowlistSaveButton")
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text(String(localized: "settings.browser.httpAllowlist.hint", defaultValue: "One host or wildcard per line (for example: localhost, 127.0.0.1, ::1, 0.0.0.0, *.localtest.me)."))
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack {
                            Spacer(minLength: 0)
                            Button(String(localized: "settings.browser.httpAllowlist.save", defaultValue: "Save")) {
                                saveBrowserInsecureHTTPAllowlist()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(!browserInsecureHTTPAllowlistHasUnsavedChanges)
                            .accessibilityIdentifier("SettingsBrowserHTTPAllowlistSaveButton")
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }

    }

    @ViewBuilder
    private var browserDataSection: some View {
        SettingsSectionHeader(title: String(localized: "settings.section.browserData", defaultValue: "Data"))
        SettingsCard {
            SettingsCardRow(String(localized: "settings.browser.history", defaultValue: "Browsing History"), subtitle: browserHistorySubtitle) {
                Button(String(localized: "settings.browser.history.clearButton", defaultValue: "Clear History…")) {
                    showClearBrowserHistoryConfirmation = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(browserHistoryEntryCount == 0)
            }
        }

    }

    @ViewBuilder
    private var keyboardShortcutsSection: some View {
        SettingsSectionHeader(title: String(localized: "settings.section.keyboardShortcuts", defaultValue: "Keyboard Shortcuts"))
            .id(SettingsNavigationTarget.keyboardShortcuts)
            .accessibilityIdentifier("SettingsKeyboardShortcutsSection")
        SettingsCard {
            SettingsCardRow(
                String(localized: "settings.shortcuts.chords", defaultValue: "Shortcut Chords"),
                subtitle: String(localized: "settings.shortcuts.chords.subtitle", defaultValue: "Add tmux-style multi-step shortcuts in settings.json, for example [\"ctrl+b\", \"c\"].")
            ) {
                HStack(spacing: 8) {
                    Link(String(localized: "settings.shortcuts.chords.docsButton", defaultValue: "Chord docs"), destination: shortcutChordsDocsURL)
                        .font(.caption)
                        .accessibilityIdentifier("SettingsKeyboardShortcutsChordDocsLink")

                    Button(String(localized: "settings.app.settingsFile.openButton", defaultValue: "Open settings.json")) {
                        openProgramaSettingsFileInTextEdit()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsKeyboardShortcutsOpenSettingsFileButton")
                }
            }

            SettingsCardDivider()

            SettingsCardRow(
                String(localized: "settings.shortcuts.showHints", defaultValue: "Show Cmd/Ctrl-Hold Shortcut Hints"),
                subtitle: showShortcutHintsOnCommandHold
                    ? String(localized: "settings.shortcuts.showHints.subtitleOn", defaultValue: "Holding Cmd (sidebar/titlebar) or Ctrl/Cmd (pane tabs) shows shortcut hint pills.")
                    : String(localized: "settings.shortcuts.showHints.subtitleOff", defaultValue: "Holding Cmd or Ctrl keeps shortcut hint pills hidden.")
            ) {
                Toggle("", isOn: $showShortcutHintsOnCommandHold)
                    .labelsHidden()
                    .controlSize(.small)
            }

            SettingsCardDivider()

            let actions = KeyboardShortcutSettings.Action.allCases
            ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                ShortcutSettingRow(action: action)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                if index < actions.count - 1 {
                    SettingsCardDivider()
                }
            }
        }
        .id(shortcutResetToken)

        Text(String(localized: "settings.shortcuts.recordHint", defaultValue: "Click a shortcut value to record a new shortcut."))
            .font(.caption)
            .foregroundColor(.secondary)
            .padding(.leading, 2)
            .accessibilityIdentifier("ShortcutRecordingHint")

    }

    @ViewBuilder
    private var resetSection: some View {
        SettingsSectionHeader(title: String(localized: "settings.section.reset", defaultValue: "Reset"))
        SettingsCard {
            HStack {
                Spacer(minLength: 0)
                Button(String(localized: "settings.reset.resetAll", defaultValue: "Reset All Settings")) {
                    resetAllSettings()
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    private func resetAllSettings() {
        appearanceMode = AppearanceSettings.defaultMode.rawValue
        socketControlMode = SocketControlSettings.defaultMode.rawValue
        claudeCodeHooksEnabled = ClaudeCodeIntegrationSettings.defaultHooksEnabled
        customClaudePath = ""
        agentScreenDetectionEnabled = AgentScreenDetectionSettings.defaultEnabled
        preferredEditorCommand = ""
        browserSearchEngine = BrowserSearchSettings.defaultSearchEngine.rawValue
        browserSearchSuggestionsEnabled = BrowserSearchSettings.defaultSearchSuggestionsEnabled
        browserThemeMode = BrowserThemeSettings.defaultMode.rawValue
        openTerminalLinksInProgramaBrowser = BrowserLinkOpenSettings.defaultOpenTerminalLinksInProgramaBrowser
        interceptTerminalOpenCommandInProgramaBrowser = BrowserLinkOpenSettings.defaultInterceptTerminalOpenCommandInProgramaBrowser
        browserHostWhitelist = BrowserLinkOpenSettings.defaultBrowserHostWhitelist
        browserExternalOpenPatterns = BrowserLinkOpenSettings.defaultBrowserExternalOpenPatterns
        externalBrowserBundleIdentifier = BrowserLinkOpenSettings.defaultExternalBrowserBundleIdentifier
        browserInsecureHTTPAllowlist = BrowserInsecureHTTPSettings.defaultAllowlistText
        browserInsecureHTTPAllowlistDraft = BrowserInsecureHTTPSettings.defaultAllowlistText
        notificationSound = NotificationSoundSettings.defaultValue
        notificationCustomCommand = NotificationSoundSettings.defaultCustomCommand
        showMenuBarExtra = MenuBarExtraSettings.defaultShowInMenuBar
        warnBeforeQuitShortcut = QuitWarningSettings.defaultWarnBeforeQuit
        openBrowserWithAgentSplits = AgentBrowserSplitSettings.defaultValue
        ScrollbackPersistenceSettings.setEnabled(ScrollbackPersistenceSettings.defaultPersistScrollback)
        commandPaletteSearchAllSurfaces = CommandPaletteSwitcherSearchSettings.defaultSearchAllSurfaces
        ShortcutHintDebugSettings.resetVisibilityDefaults()
        alwaysShowShortcutHints = ShortcutHintDebugSettings.defaultAlwaysShowHints
        newWorkspacePlacement = WorkspacePlacementSettings.defaultPlacement.rawValue
        workspacePresentationMode = WorkspacePresentationModeSettings.defaultMode.rawValue
        workspaceAutoReorder = WorkspaceAutoReorderSettings.defaultValue
        sidebarActiveTabIndicatorStyle = SidebarActiveTabIndicatorSettings.defaultStyle.rawValue
        sidebarSelectionColorHex = nil
        sidebarNotificationBadgeColorHex = nil
        showShortcutHintsOnCommandHold = ShortcutHintDebugSettings.defaultShowHintsOnCommandHold
        sidebarTintHex = SidebarTintDefaults.hex
        sidebarTintHexLight = nil
        sidebarTintHexDark = nil
        sidebarTintOpacity = SidebarTintDefaults.opacity
        sidebarMatchTerminalBackground = false
        showClaudeQuota = true
        terminalThemeSettings.clearManagedOverride()
        showOpenAccessConfirmation = false
        pendingOpenAccessMode = nil
        socketPasswordDraft = ""
        socketPasswordStatusMessage = nil
        socketPasswordStatusIsError = false
        KeyboardShortcutSettings.resetAll()
        WorkspaceTabColorSettings.reset()
        WorkspaceTabColorSettings.resetRememberedFolderColors()
        shortcutResetToken = UUID()
    }

    private func saveBrowserInsecureHTTPAllowlist() {
        browserInsecureHTTPAllowlist = browserInsecureHTTPAllowlistDraft
    }

}

@MainActor
private final class TerminalThemeSettingsModel: ObservableObject {
    @Published private(set) var themeNames: [String] = []
    @Published private(set) var lightTheme = ""
    @Published private(set) var darkTheme = ""
    @Published private(set) var opacity: Double = 1.0
    @Published private(set) var blurEnabled = false
    @Published private(set) var fontFamily = ""
    @Published private(set) var fontSize: Double = 0
    @Published private(set) var isManagedBySettingsFile = false
    @Published private(set) var isOpacityManagedBySettingsFile = false
    @Published private(set) var isBlurManagedBySettingsFile = false
    @Published private(set) var isFontManagedBySettingsFile = false
    @Published private(set) var errorMessage: String?

    private let store: TerminalThemeStore
    private let notificationCenter: NotificationCenter
    private var configReloadObserver: NSObjectProtocol?

    init(
        store: TerminalThemeStore = .live(),
        notificationCenter: NotificationCenter = .default
    ) {
        self.store = store
        self.notificationCenter = notificationCenter
        refresh()
        configReloadObserver = notificationCenter.addObserver(
            forName: .ghosttyConfigDidReload,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
    }

    deinit {
        if let configReloadObserver {
            notificationCenter.removeObserver(configReloadObserver)
        }
    }

    func selectLightTheme(_ themeName: String) {
        guard !isManagedBySettingsFile else {
            refresh()
            return
        }
        applyAppearance { overrides in
            overrides.themeLight = themeName.isEmpty ? nil : themeName
        }
    }

    func selectDarkTheme(_ themeName: String) {
        guard !isManagedBySettingsFile else {
            refresh()
            return
        }
        applyAppearance { overrides in
            overrides.themeDark = themeName.isEmpty ? nil : themeName
        }
    }

    func setOpacity(_ value: Double) {
        guard !isOpacityManagedBySettingsFile else {
            refresh()
            return
        }
        applyAppearance { overrides in
            overrides.backgroundOpacity = value
        }
    }

    func setBlurEnabled(_ value: Bool) {
        guard !isBlurManagedBySettingsFile else {
            refresh()
            return
        }
        applyAppearance { overrides in
            overrides.backgroundBlur = value
        }
    }

    func setFontFamily(_ value: String) {
        guard !isFontManagedBySettingsFile else {
            refresh()
            return
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        applyAppearance { overrides in
            overrides.fontFamily = trimmed.isEmpty ? nil : trimmed
        }
    }

    func setFontSize(_ value: Double) {
        guard !isFontManagedBySettingsFile else {
            refresh()
            return
        }
        applyAppearance { overrides in
            overrides.fontSize = value > 0 ? value : nil
        }
    }

    func clearManagedOverride() {
        guard !isManagedBySettingsFile,
              !isOpacityManagedBySettingsFile,
              !isBlurManagedBySettingsFile,
              !isFontManagedBySettingsFile else {
            return
        }
        do {
            let mutation = try store.clear()
            errorMessage = nil
            refresh()
            if mutation.didChange {
                requestReload()
            }
        } catch {
            reportError(error)
        }
    }

    private func applyAppearance(_ mutate: (inout TerminalAppearanceOverrides) -> Void) {
        // Base partial updates on the managed block only, not the full search-chain resolution
        // `currentAppearance()` returns — otherwise a value the user only ever set in their own
        // raw Ghostty config would get silently copied into Programa's managed block the moment
        // any sibling field changes.
        var overrides = store.managedRawAppearance()
        mutate(&overrides)
        do {
            let mutation = try store.set(overrides)
            errorMessage = nil
            refresh()
            if mutation.didChange {
                requestReload()
            }
        } catch {
            reportError(error)
        }
    }

    private func requestReload() {
        TerminalThemeStore.requestReload(
            targetBundleIdentifier: Bundle.main.bundleIdentifier
                ?? TerminalThemeStore.overrideBundleIdentifier
        )
    }

    private func reportError(_ error: Error) {
        let prefix = String(
            localized: "settings.terminalTheme.changeFailed",
            defaultValue: "Couldn’t change the terminal theme."
        )
        errorMessage = "\(prefix) \(error.localizedDescription)"
        refreshSelectionAndOwnership()
    }

    private func refresh() {
        let current = store.currentAppearance()
        var names = GhosttyConfig.availableThemeNames()
        for selectedName in [current.themeLight, current.themeDark].compactMap({ $0 }) {
            if !names.contains(where: { $0.caseInsensitiveCompare(selectedName) == .orderedSame }) {
                names.append(selectedName)
            }
        }
        themeNames = names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        opacity = current.backgroundOpacity ?? 1.0
        blurEnabled = current.backgroundBlur ?? false
        fontFamily = current.fontFamily ?? ""
        fontSize = current.fontSize ?? 0
        refreshSelectionAndOwnership(current: current)
    }

    private func refreshSelectionAndOwnership(
        current: TerminalAppearanceOverrides? = nil
    ) {
        let current = current ?? store.currentAppearance()
        let managedOverride = store.managedRawAppearance()
        let hasManagedThemeOverride = managedOverride.themeLight != nil || managedOverride.themeDark != nil
        lightTheme = hasManagedThemeOverride ? current.themeLight ?? "" : ""
        darkTheme = hasManagedThemeOverride ? current.themeDark ?? "" : ""

        let fileStore = KeyboardShortcutSettings.settingsFileStore
        isManagedBySettingsFile = fileStore.isTerminalThemeManagedByFile()
        isOpacityManagedBySettingsFile = fileStore.isTerminalOpacityManagedByFile()
        isBlurManagedBySettingsFile = fileStore.isTerminalBlurManagedByFile()
        isFontManagedBySettingsFile = fileStore.isTerminalFontManagedByFile()
    }
}

private struct SettingsTopOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct SettingsContentHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    /// `max` rather than last-wins: siblings in the tree report the 0 default and
    /// would otherwise clobber the real measurement. It is recomputed per update, so
    /// it cannot latch onto a previous tab's height.
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Grows and shrinks the window to whatever the selected tab actually needs, the way
/// System Settings does, so short tabs stop showing a half-empty pane and a scroller
/// they never needed. Also owns the width floor the tab labels require.
private struct SettingsWindowHeightFitter: NSViewRepresentable {
    let contentHeight: CGFloat
    let headerHeight: CGFloat
    let minimumWidth: CGFloat

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let measured = contentHeight
        let header = headerHeight
        let floorWidth = minimumWidth
        guard measured > 0 else { return }
        DispatchQueue.main.async {
            guard let window = nsView.window, let container = window.contentView else { return }
            // The floor is whatever the tab labels need, so the strip can never be
            // dragged narrow enough for AppKit to start ellipsising them.
            window.minSize = NSSize(width: floorWidth, height: SettingsWindowMetrics.minContentHeight)
            window.maxSize = NSSize(
                width: SettingsWindowMetrics.maxContentWidth,
                height: SettingsWindowMetrics.maxContentHeight
            )
            if window.frame.width < floorWidth {
                var widened = window.frame
                widened.size.width = floorWidth
                window.setFrame(widened, display: true)
            }
            // The header is a safe-area inset above the scroll view, so the window needs
            // to carry both it and the content the scroll view actually holds.
            let target = measured + header
            let screenCeiling = ((window.screen ?? NSScreen.main)?.visibleFrame.height ?? target) - 40
            let ceiling = min(SettingsWindowMetrics.maxContentHeight, screenCeiling)
            // Tabs taller than the ceiling settle at the ceiling and scroll, rather than
            // growing the window past the bottom of the screen.
            let desired = min(max(target, SettingsWindowMetrics.minContentHeight), ceiling)
            let delta = desired - container.bounds.height
            // Without a deadband the resize retriggers the measurement that caused it.
            guard abs(delta) > 0.5 else { return }
            var frame = window.frame
            frame.origin.y -= delta
            frame.size.height += delta
            window.setFrame(frame, display: true, animate: window.isVisible)
        }
    }
}

/// SwiftUI's segmented `Picker` sizes itself to its labels and centres the result,
/// which leaves the strip floating with wider gaps than the rows below it. Wrapping
/// `NSSegmentedControl` lets us ask for `.fillEqually`, so the segments genuinely
/// share the full width and both edges line up with the content inset.
private struct SettingsTabStrip: NSViewRepresentable {
    @Binding var selection: SettingsTab
    /// The width the six labels need before AppKit starts truncating them. Reported
    /// from the control itself so translated labels raise the floor automatically.
    let onNaturalWidthChange: (CGFloat) -> Void

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(
            labels: SettingsTab.allCases.map(\.title),
            trackingMode: .selectOne,
            target: context.coordinator,
            action: #selector(Coordinator.segmentChanged(_:))
        )
        control.segmentDistribution = .fillEqually
        control.controlSize = .regular
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        control.setAccessibilityIdentifier("SettingsTabPicker")
        control.selectedSegment = Self.index(of: selection)
        return control
    }

    func updateNSView(_ nsView: NSSegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        for (index, tab) in SettingsTab.allCases.enumerated() where nsView.label(forSegment: index) != tab.title {
            nsView.setLabel(tab.title, forSegment: index)
        }
        let index = Self.index(of: selection)
        if nsView.selectedSegment != index {
            nsView.selectedSegment = index
        }
        let natural = nsView.intrinsicContentSize.width
        DispatchQueue.main.async {
            onNaturalWidthChange(natural)
        }
    }

    /// Without this the representable falls back to the control's intrinsic width,
    /// which is the hugging behaviour we are trying to get away from.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl, context: Context) -> CGSize? {
        CGSize(
            width: proposal.width ?? nsView.intrinsicContentSize.width,
            height: nsView.intrinsicContentSize.height
        )
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection)
    }

    private static func index(of tab: SettingsTab) -> Int {
        SettingsTab.allCases.firstIndex(of: tab) ?? 0
    }

    final class Coordinator: NSObject {
        var selection: Binding<SettingsTab>

        init(selection: Binding<SettingsTab>) {
            self.selection = selection
        }

        @objc func segmentChanged(_ sender: NSSegmentedControl) {
            let tabs = SettingsTab.allCases
            guard tabs.indices.contains(sender.selectedSegment) else { return }
            selection.wrappedValue = tabs[sender.selectedSegment]
        }
    }
}

private struct ThemeWindowThumbnail: View {
    let isDark: Bool

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height

            ZStack {
                // Wallpaper background
                if isDark {
                    LinearGradient(
                        colors: [Color(red: 0.1, green: 0.1, blue: 0.3), Color(red: 0.05, green: 0.05, blue: 0.1)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: height * 0.5))
                        path.addQuadCurve(to: CGPoint(x: width, y: height), control: CGPoint(x: width * 0.5, y: height * 0.2))
                        path.addLine(to: CGPoint(x: width, y: 0))
                        path.addLine(to: CGPoint(x: 0, y: 0))
                    }
                    .fill(LinearGradient(colors: [Color(red: 0.2, green: 0.2, blue: 0.6).opacity(0.5), .clear], startPoint: .topLeading, endPoint: .bottomTrailing))
                } else {
                    LinearGradient(
                        colors: [Color(red: 0.6, green: 0.8, blue: 0.95), Color(red: 0.2, green: 0.4, blue: 0.8)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: height * 0.5))
                        path.addQuadCurve(to: CGPoint(x: width, y: height), control: CGPoint(x: width * 0.5, y: height * 0.2))
                        path.addLine(to: CGPoint(x: width, y: 0))
                        path.addLine(to: CGPoint(x: 0, y: 0))
                    }
                    .fill(LinearGradient(colors: [Color(red: 0.8, green: 0.9, blue: 1.0).opacity(0.6), .clear], startPoint: .topLeading, endPoint: .bottomTrailing))
                }

                // Menu bar
                VStack(spacing: 0) {
                    HStack {
                        Image(systemName: "applelogo")
                            .symbolRasterSize(max(height * 0.08, 6))
                            .foregroundColor(isDark ? .white : .black)
                            .opacity(0.8)
                        Spacer()
                    }
                    .padding(.horizontal, max(width * 0.04, 4))
                    .frame(height: max(height * 0.12, 8))
                    .background(.ultraThinMaterial)
                    Spacer()
                }

                // Back window
                VStack(spacing: 0) {
                    Rectangle()
                        .fill(isDark ? Color(white: 0.2) : Color(white: 0.9))
                        .frame(height: max(height * 0.15, 8))
                    ZStack(alignment: .top) {
                        Rectangle()
                            .fill(isDark ? Color(white: 0.15) : Color(white: 0.98))
                        RoundedRectangle(cornerRadius: max(width * 0.02, 2), style: .continuous)
                            .fill(Color.accentColor)
                            .frame(height: max(height * 0.12, 6))
                            .padding(max(width * 0.04, 4))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: max(width * 0.04, 4), style: .continuous))
                .frame(width: width * 0.65, height: height * 0.45)
                .shadow(color: .black.opacity(isDark ? 0.4 : 0.15), radius: 4, x: 0, y: 2)
                .offset(x: -width * 0.08, y: -height * 0.1)

                // Front window with traffic lights
                VStack(spacing: 0) {
                    ZStack {
                        Rectangle()
                            .fill(isDark ? Color(white: 0.18) : Color(white: 0.92))
                        HStack(spacing: max(width * 0.025, 2)) {
                            Circle().fill(Color(red: 1.0, green: 0.37, blue: 0.34)).frame(width: max(width * 0.04, 3))
                            Circle().fill(Color(red: 1.0, green: 0.74, blue: 0.18)).frame(width: max(width * 0.04, 3))
                            Circle().fill(Color(red: 0.15, green: 0.79, blue: 0.25)).frame(width: max(width * 0.04, 3))
                            Spacer()
                        }
                        .padding(.horizontal, max(width * 0.04, 4))
                    }
                    .frame(height: max(height * 0.18, 10))
                    Rectangle()
                        .fill(isDark ? Color(white: 0.1) : .white)
                }
                .clipShape(RoundedRectangle(cornerRadius: max(width * 0.05, 5), style: .continuous))
                .shadow(color: .black.opacity(isDark ? 0.5 : 0.2), radius: 6, x: 0, y: 3)
                .frame(width: width * 0.75, height: height * 0.55)
                .offset(x: width * 0.12, y: height * 0.2)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        )
    }
}

private struct ThemePickerRow: View {
    let selectedMode: String
    let onSelect: (AppearanceMode) -> Void

    private let thumbWidth: CGFloat = 76
    private let thumbHeight: CGFloat = 50

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(String(localized: "settings.app.theme", defaultValue: "Theme"))
                .font(.system(size: 13, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                ForEach(AppearanceMode.visibleCases) { mode in
                    let isSelected = selectedMode == mode.rawValue
                    Button {
                        onSelect(mode)
                    } label: {
                        VStack(spacing: 4) {
                            Group {
                                if mode == .system {
                                    ZStack {
                                        ThemeWindowThumbnail(isDark: false)
                                            .mask(
                                                GeometryReader { geo in
                                                    Rectangle()
                                                        .frame(width: geo.size.width / 2, height: geo.size.height)
                                                        .position(x: geo.size.width / 4, y: geo.size.height / 2)
                                                }
                                            )
                                        ThemeWindowThumbnail(isDark: true)
                                            .mask(
                                                GeometryReader { geo in
                                                    Rectangle()
                                                        .frame(width: geo.size.width / 2, height: geo.size.height)
                                                        .position(x: geo.size.width * 0.75, y: geo.size.height / 2)
                                                }
                                            )
                                        GeometryReader { geo in
                                            Rectangle()
                                                .fill(Color.primary.opacity(0.15))
                                                .frame(width: 1, height: geo.size.height)
                                                .position(x: geo.size.width / 2, y: geo.size.height / 2)
                                        }
                                    }
                                } else {
                                    ThemeWindowThumbnail(isDark: mode == .dark)
                                }
                            }
                            .frame(width: thumbWidth, height: thumbHeight)

                            Text(mode.displayName)
                                .font(.system(size: 10))
                                .fontWeight(isSelected ? .semibold : .regular)
                                .foregroundColor(isSelected ? .primary : .secondary)
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 10)
                        .contentShape(Rectangle())
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(isSelected
                                    ? Color.accentColor.opacity(0.12)
                                    : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
                        )
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .layoutPriority(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}


private struct ShortcutSettingRow: View {
    let action: KeyboardShortcutSettings.Action
    @State private var shortcut: StoredShortcut

    init(action: KeyboardShortcutSettings.Action) {
        self.action = action
        _shortcut = State(initialValue: KeyboardShortcutSettings.shortcut(for: action))
    }

    var body: some View {
        KeyboardShortcutRecorder(
            label: action.label,
            subtitle: KeyboardShortcutSettings.settingsFileManagedSubtitle(for: action),
            shortcut: $shortcut,
            displayString: { action.displayedShortcutString(for: $0) },
            transformRecordedShortcut: { action.normalizedRecordedShortcut($0) },
            isDisabled: KeyboardShortcutSettings.isManagedBySettingsFile(action)
        )
            .onChange(of: shortcut) { _, newValue in
                KeyboardShortcutSettings.setShortcut(newValue, for: action)
            }
            .onReceive(NotificationCenter.default.publisher(for: KeyboardShortcutSettings.didChangeNotification)) { _ in
                let latest = KeyboardShortcutSettings.shortcut(for: action)
                if latest != shortcut {
                    shortcut = latest
                }
            }
    }
}

struct SettingsRootView: View {
    var body: some View {
        SettingsView()
            .background(WindowAccessor { window in
                configureSettingsWindow(window)
            })
    }

    private func configureSettingsWindow(_ window: NSWindow) {
        window.identifier = NSUserInterfaceItemIdentifier("cmux.settings")
        applyCurrentSettingsWindowStyle(to: window)

        let accessories = window.titlebarAccessoryViewControllers
        for index in accessories.indices.reversed() {
            guard let identifier = accessories[index].view.identifier?.rawValue else { continue }
            guard identifier.hasPrefix("cmux.") else { continue }
            window.removeTitlebarAccessoryViewController(at: index)
        }
    }

    private func applyCurrentSettingsWindowStyle(to window: NSWindow) {
        SettingsAboutTitlebarStyleStore.shared.applyCurrentOptions(to: window, for: .settings)
    }
}
