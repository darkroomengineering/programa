import AppKit
import SwiftUI
import Darwin
import Bonsplit
import UniformTypeIdentifiers

enum UITestLaunchManifest {
    static let argumentName = "-cmuxUITestLaunchManifest"

    struct Payload: Decodable {
        let environment: [String: String]
    }

    static func applyIfPresent(
        arguments: [String] = CommandLine.arguments,
        loadData: (String) -> Data? = { path in
            try? Data(contentsOf: URL(fileURLWithPath: path))
        },
        applyEnvironment: (String, String) -> Void = { key, value in
            setenv(key, value, 1)
        }
    ) {
        guard let path = manifestPath(from: arguments),
              let data = loadData(path),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return
        }

        for (key, value) in payload.environment {
            applyEnvironment(key, value)
        }
    }

    static func manifestPath(from arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: argumentName) else { return nil }
        let valueIndex = arguments.index(after: index)
        guard valueIndex < arguments.endIndex else { return nil }

        let rawPath = arguments[valueIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        return rawPath.isEmpty ? nil : rawPath
    }
}

@main
struct programaApp: App {
    @StateObject private var tabManager: TabManager
    @StateObject private var notificationStore = TerminalNotificationStore.shared
    @StateObject private var sidebarState = SidebarState()
    @StateObject private var sidebarSelectionState = SidebarSelectionState()
    @StateObject private var programaConfigStore = ProgramaConfigStore()
    @StateObject private var keyboardShortcutSettingsObserver = KeyboardShortcutSettingsObserver.shared
    private let primaryWindowId = UUID()
    @AppStorage(AppearanceSettings.appearanceModeKey) private var appearanceMode = AppearanceSettings.defaultMode.rawValue
    @AppStorage("titlebarControlsStyle") private var titlebarControlsStyle = TitlebarControlsStyle.classic.rawValue
    @AppStorage(ShortcutHintDebugSettings.alwaysShowHintsKey) private var alwaysShowShortcutHints = ShortcutHintDebugSettings.defaultAlwaysShowHints
    @AppStorage(DevBuildBannerDebugSettings.sidebarBannerVisibleKey)
    private var showSidebarDevBuildBanner = DevBuildBannerDebugSettings.defaultShowSidebarBanner
    @AppStorage(SocketControlSettings.appStorageKey) private var socketControlMode = SocketControlSettings.defaultMode.rawValue
    @AppStorage(BrowserToolbarAccessorySpacingDebugSettings.key) private var browserToolbarAccessorySpacingRaw = BrowserToolbarAccessorySpacingDebugSettings.defaultSpacing
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private var browserToolbarAccessorySpacing: Int {
        BrowserToolbarAccessorySpacingDebugSettings.resolved(browserToolbarAccessorySpacingRaw)
    }

    init() {
        UITestLaunchManifest.applyIfPresent()

        if SocketControlSettings.shouldBlockUntaggedDebugLaunch() {
            Self.terminateForMissingLaunchTag()
        }

        Self.configureGhosttyEnvironment()
        _ = KeyboardShortcutSettings.settingsFileStore

        // The in-app language picker was removed; the app always follows the
        // system language. Clear any previously chosen per-app override once,
        // since no UI can undo it anymore.
        Self.migrateLanguageOverrideRemovalIfNeeded(defaults: .standard)

        let startupAppearance = AppearanceSettings.resolvedMode()
        Self.applyAppearance(startupAppearance)
        _tabManager = StateObject(wrappedValue: TabManager())
        let defaults = UserDefaults.standard
        // Rebrand: forward every legacy cmux-prefixed default to its programa key
        // before anything reads the new keys, so existing users keep their prefs.
        Self.migrateCmuxDefaultsToProgramaIfNeeded(defaults: defaults)
        // Migrate legacy and old-format socket mode values to the new enum.
        if let stored = defaults.string(forKey: SocketControlSettings.appStorageKey) {
            let migrated = SocketControlSettings.migrateMode(stored)
            if migrated.rawValue != stored {
                defaults.set(migrated.rawValue, forKey: SocketControlSettings.appStorageKey)
            }
        } else if let legacy = defaults.object(forKey: SocketControlSettings.legacyEnabledKey) as? Bool {
            defaults.set(legacy ? SocketControlMode.cmuxOnly.rawValue : SocketControlMode.off.rawValue,
                         forKey: SocketControlSettings.appStorageKey)
        }
        // Skip keychain migration for DEV/staging builds. Each tagged build gets a
        // unique bundle ID with its own UserDefaults domain, so migration would run
        // on every launch and trigger a macOS keychain access prompt (the legacy
        // keychain item was created by a differently-signed app).
        let bundleID = Bundle.main.bundleIdentifier
        if !SocketControlSettings.isDebugLikeBundleIdentifier(bundleID)
            && !SocketControlSettings.isStagingBundleIdentifier(bundleID) {
            SocketControlPasswordStore.migrateLegacyKeychainPasswordIfNeeded(defaults: defaults)
        }
        migrateSidebarAppearanceDefaultsIfNeeded(defaults: defaults)

        // UI tests depend on AppDelegate wiring happening even if SwiftUI view appearance
        // callbacks (e.g. `.onAppear`) are delayed or skipped.
        appDelegate.configure(tabManager: tabManager, notificationStore: notificationStore, sidebarState: sidebarState)
    }

    private static func terminateForMissingLaunchTag() -> Never {
        let message = "error: refusing to launch untagged programa DEV; start with ./scripts/reload.sh --tag <name> (or set PROGRAMA_TAG for test harnesses)"
        fputs("\(message)\n", stderr)
        fflush(stderr)
        NSLog("%@", message)
        Darwin.exit(64)
    }

    private static func configureGhosttyEnvironment() {
        let fileManager = FileManager.default
        let ghosttyAppResources = "/Applications/Ghostty.app/Contents/Resources/ghostty"
        let bundledGhosttyURL = Bundle.main.resourceURL?.appendingPathComponent("ghostty")
        var resolvedResourcesDir: String?

        if getenv("GHOSTTY_RESOURCES_DIR") == nil {
            if let bundledGhosttyURL,
               fileManager.fileExists(atPath: bundledGhosttyURL.path),
               fileManager.fileExists(atPath: bundledGhosttyURL.appendingPathComponent("themes").path) {
                resolvedResourcesDir = bundledGhosttyURL.path
            } else if fileManager.fileExists(atPath: ghosttyAppResources) {
                resolvedResourcesDir = ghosttyAppResources
            } else if let bundledGhosttyURL, fileManager.fileExists(atPath: bundledGhosttyURL.path) {
                resolvedResourcesDir = bundledGhosttyURL.path
            }

            if let resolvedResourcesDir {
                setenv("GHOSTTY_RESOURCES_DIR", resolvedResourcesDir, 1)
            }
        }

        if getenv("TERM") == nil {
            setenv("TERM", TerminalSurface.managedTerminalType, 1)
        }

        if getenv("COLORTERM") == nil {
            setenv("COLORTERM", TerminalSurface.managedColorTerm, 1)
        }

        if getenv("TERM_PROGRAM") == nil {
            setenv("TERM_PROGRAM", TerminalSurface.managedTerminalProgram, 1)
        }

        if let resourcesDir = getenv("GHOSTTY_RESOURCES_DIR").flatMap({ String(cString: $0) }) {
            let resourcesURL = URL(fileURLWithPath: resourcesDir)
            let resourcesParent = resourcesURL.deletingLastPathComponent()
            let dataDir = resourcesParent.path
            let manDir = resourcesParent.appendingPathComponent("man").path

            appendEnvPathIfMissing(
                "XDG_DATA_DIRS",
                path: dataDir,
                defaultValue: "/usr/local/share:/usr/share"
            )
            appendEnvPathIfMissing("MANPATH", path: manDir)
        }
    }

    private static func appendEnvPathIfMissing(_ key: String, path: String, defaultValue: String? = nil) {
        if path.isEmpty { return }
        var current = getenv(key).flatMap { String(cString: $0) } ?? ""
        if current.isEmpty, let defaultValue {
            current = defaultValue
        }
        if current.split(separator: ":").contains(Substring(path)) {
            return
        }
        let updated = current.isEmpty ? path : "\(current):\(path)"
        setenv(key, updated, 1)
    }

    /// One-time rebrand migration: copy every `cmux`-prefixed UserDefaults value to
    /// the corresponding `programa`-prefixed key. Version-gated so it runs once, and
    /// never deletes the legacy keys (a downgrade still finds its old values).
    private static func migrateCmuxDefaultsToProgramaIfNeeded(defaults: UserDefaults) {
        let migrationKey = "programaDefaultsRebrandMigrationVersion"
        let targetVersion = 1
        guard defaults.integer(forKey: migrationKey) < targetVersion else { return }
        for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix("cmux") {
            let newKey = "programa" + key.dropFirst("cmux".count)
            if defaults.object(forKey: newKey) == nil {
                defaults.set(value, forKey: newKey)
            }
        }
        defaults.set(targetVersion, forKey: migrationKey)
    }

    private static func migrateLanguageOverrideRemovalIfNeeded(defaults: UserDefaults) {
        let migrationKey = "programaLanguageOverrideRemovalVersion"
        let targetVersion = 1
        guard defaults.integer(forKey: migrationKey) < targetVersion else { return }
        defaults.removeObject(forKey: "AppleLanguages")
        defaults.removeObject(forKey: "appLanguage")
        defaults.set(targetVersion, forKey: migrationKey)
    }

    private func migrateSidebarAppearanceDefaultsIfNeeded(defaults: UserDefaults) {
        let migrationKey = "sidebarAppearanceDefaultsVersion"
        let targetVersion = 1
        guard defaults.integer(forKey: migrationKey) < targetVersion else { return }

        func normalizeHex(_ value: String) -> String {
            value
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "#", with: "")
                .uppercased()
        }

        func approximatelyEqual(_ lhs: Double, _ rhs: Double, tolerance: Double = 0.0001) -> Bool {
            abs(lhs - rhs) <= tolerance
        }

        let material = defaults.string(forKey: "sidebarMaterial") ?? SidebarMaterialOption.sidebar.rawValue
        let blendMode = defaults.string(forKey: "sidebarBlendMode") ?? SidebarBlendModeOption.behindWindow.rawValue
        let state = defaults.string(forKey: "sidebarState") ?? SidebarStateOption.followWindow.rawValue
        let tintHex = defaults.string(forKey: "sidebarTintHex") ?? "#101010"
        let tintOpacity = defaults.object(forKey: "sidebarTintOpacity") as? Double ?? 0.54
        let blurOpacity = defaults.object(forKey: "sidebarBlurOpacity") as? Double ?? 0.79
        let cornerRadius = defaults.object(forKey: "sidebarCornerRadius") as? Double ?? 0.0

        let usesLegacyDefaults =
            material == SidebarMaterialOption.sidebar.rawValue &&
            blendMode == SidebarBlendModeOption.behindWindow.rawValue &&
            state == SidebarStateOption.followWindow.rawValue &&
            normalizeHex(tintHex) == "101010" &&
            approximatelyEqual(tintOpacity, 0.54) &&
            approximatelyEqual(blurOpacity, 0.79) &&
            approximatelyEqual(cornerRadius, 0.0)

        if usesLegacyDefaults {
            let preset = SidebarPresetOption.nativeSidebar
            defaults.set(preset.rawValue, forKey: "sidebarPreset")
            defaults.set(preset.material.rawValue, forKey: "sidebarMaterial")
            defaults.set(preset.blendMode.rawValue, forKey: "sidebarBlendMode")
            defaults.set(preset.state.rawValue, forKey: "sidebarState")
            defaults.set(preset.tintHex, forKey: "sidebarTintHex")
            defaults.set(preset.tintOpacity, forKey: "sidebarTintOpacity")
            defaults.set(preset.blurOpacity, forKey: "sidebarBlurOpacity")
            defaults.set(preset.cornerRadius, forKey: "sidebarCornerRadius")
        }

        defaults.set(targetVersion, forKey: migrationKey)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(updateViewModel: appDelegate.updateViewModel, windowId: primaryWindowId)
                .environmentObject(tabManager)
                .environmentObject(notificationStore)
                .environmentObject(sidebarState)
                .environmentObject(sidebarSelectionState)
                .environmentObject(programaConfigStore)
                .onAppear {
#if DEBUG
                    if ProcessInfo.processInfo.environment["PROGRAMA_UI_TEST_MODE"] == "1" {
                        UpdateLogStore.shared.append("ui test: programaApp onAppear")
                    }
#endif
                    // Start the Unix socket controller for programmatic access
                    updateSocketController()
                    appDelegate.configure(tabManager: tabManager, notificationStore: notificationStore, sidebarState: sidebarState)
                    programaConfigStore.wireDirectoryTracking(tabManager: tabManager)
                    programaConfigStore.loadAll()
                    applyAppearance()
                    if ProcessInfo.processInfo.environment["PROGRAMA_UI_TEST_SHOW_SETTINGS"] == "1" {
                        DispatchQueue.main.async {
                            appDelegate.openPreferencesWindow(debugSource: "uiTestShowSettings")
                        }
                    }
                }
                .onChange(of: appearanceMode) {
                    applyAppearance()
                }
                .onChange(of: socketControlMode) {
                    updateSocketController()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .appSettings) {
                splitCommandButton(title: String(localized: "menu.app.settings", defaultValue: "Settings…"), shortcut: menuShortcut(for: .openSettings)) {
                    appDelegate.openPreferencesWindow(debugSource: "menu.cmdComma")
                }
                Button(String(localized: "menu.app.openProgramaSettingsFile", defaultValue: "Open settings.json")) {
                    openProgramaSettingsFileInEditor()
                }
                Button(String(localized: "menu.app.ghosttySettings", defaultValue: "Ghostty Settings…")) {
                    GhosttyApp.shared.openConfigurationInTextEdit()
                }
                splitCommandButton(title: String(localized: "menu.app.reloadConfiguration", defaultValue: "Reload Configuration"), shortcut: menuShortcut(for: .reloadConfiguration)) {
                    GhosttyApp.shared.reloadConfiguration(source: "menu.reload_configuration")
                }
            }

            CommandGroup(replacing: .appInfo) {
                Button(String(localized: "menu.app.about", defaultValue: "About Programa")) {
                    showAboutPanel()
                }

                Button(String(localized: "menu.app.checkForUpdates", defaultValue: "Check for Updates…")) {
                    appDelegate.checkForUpdates(nil)
                }
                InstallUpdateMenuItem(model: appDelegate.updateViewModel)
            }

            CommandGroup(replacing: .appTermination) {
                splitCommandButton(title: String(localized: "menu.quitPrograma", defaultValue: "Quit Programa"), shortcut: menuShortcut(for: .quit)) {
                    NSApp.terminate(nil)
                }
            }

#if DEBUG
            CommandMenu(String(localized: "debug.updatePill.menu", defaultValue: "Update Pill")) {
                Button(String(localized: "debug.updatePill.show", defaultValue: "Show Update Pill")) {
                    appDelegate.showUpdatePill(nil)
                }
                Button(String(localized: "debug.updatePill.showLongNightly", defaultValue: "Show Long Nightly Pill")) {
                    appDelegate.showUpdatePillLongNightly(nil)
                }
                Button(String(localized: "debug.updatePill.showLoading", defaultValue: "Show Loading State")) {
                    appDelegate.showUpdatePillLoading(nil)
                }
                Button(String(localized: "debug.updatePill.hide", defaultValue: "Hide Update Pill")) {
                    appDelegate.hideUpdatePill(nil)
                }
                Button(String(localized: "debug.updatePill.automatic", defaultValue: "Automatic Update Pill")) {
                    appDelegate.clearUpdatePillOverride(nil)
                }
            }
#endif

            CommandMenu(String(localized: "menu.notifications.title", defaultValue: "Notifications")) {
                let snapshot = notificationMenuSnapshot

                Button(snapshot.stateHintTitle) {}
                    .disabled(true)

                if !snapshot.recentNotifications.isEmpty {
                    Divider()

                    ForEach(snapshot.recentNotifications) { notification in
                        Button(notificationMenuItemTitle(for: notification)) {
                            openNotificationFromMainMenu(notification)
                        }
                    }

                    Divider()
                }

                splitCommandButton(title: String(localized: "menu.notifications.show", defaultValue: "Show Notifications"), shortcut: menuShortcut(for: .showNotifications)) {
                    showNotificationsPopover()
                }

                splitCommandButton(title: String(localized: "menu.notifications.jumpToUnread", defaultValue: "Jump to Latest Unread"), shortcut: menuShortcut(for: .jumpToUnread)) {
                    appDelegate.jumpToLatestUnread()
                }
                .disabled(!snapshot.hasUnreadNotifications)

                Button(String(localized: "menu.notifications.markAllRead", defaultValue: "Mark All Read")) {
                    notificationStore.markAllRead()
                }
                .disabled(!snapshot.hasUnreadNotifications)

                Button(String(localized: "menu.notifications.clearAll", defaultValue: "Clear All")) {
                    notificationStore.clearAll()
                }
                .disabled(!snapshot.hasNotifications)
            }

#if DEBUG
            CommandMenu(String(localized: "debug.menu.title", defaultValue: "Debug")) {
                Button(String(localized: "debug.menu.newLoremTab", defaultValue: "New Tab With Lorem Search Text")) {
                    appDelegate.openDebugLoremTab(nil)
                }

                Button(String(localized: "debug.menu.newLargeScrollbackTab", defaultValue: "New Tab With Large Scrollback")) {
                    appDelegate.openDebugScrollbackTab(nil)
                }

                Button(String(localized: "debug.menu.openWorkspaceColors", defaultValue: "Open Workspaces for All Workspace Colors")) {
                    appDelegate.openDebugColorComparisonWorkspaces(nil)
                }

                Button(
                    String(
                        localized: "debug.menu.openStressWorkspacesWithLoadedSurfaces",
                        defaultValue: "Open Stress Workspaces and Load All Terminals"
                    )
                ) {
                    appDelegate.openDebugStressWorkspacesWithLoadedSurfaces(nil)
                }

                Divider()
                Menu(String(localized: "debug.menu.windows", defaultValue: "Debug Windows")) {
                    Button(String(localized: "debug.menu.background", defaultValue: "Background Debug…")) {
                        BackgroundDebugWindowController.shared.show()
                    }
                    Button(
                        String(
                            localized: "debug.menu.browserProfilePopoverDebug",
                            defaultValue: "Browser Profile Popover Debug…"
                        )
                    ) {
                        BrowserProfilePopoverDebugWindowController.shared.show()
                    }
                    Button(String(localized: "debug.menu.windowControls", defaultValue: "Debug Window Controls…")) {
                        DebugWindowControlsWindowController.shared.show()
                    }
                    Button(String(localized: "debug.menu.menuBarExtra", defaultValue: "Menu Bar Extra Debug…")) {
                        MenuBarExtraDebugWindowController.shared.show()
                    }
                    Button(String(localized: "debug.menu.settingsAboutTitlebar", defaultValue: "Settings/About Titlebar Debug…")) {
                        SettingsAboutTitlebarDebugWindowController.shared.show()
                    }
                    Button(String(localized: "debug.menu.sidebar", defaultValue: "Sidebar Debug…")) {
                        SidebarDebugWindowController.shared.show()
                    }
                    Button(String(localized: "debug.menu.splitButtonLayout", defaultValue: "Split Button Layout Debug…")) {
                        SplitButtonLayoutDebugWindowController.shared.show()
                    }
                    Button(String(localized: "debug.menu.openAllWindows", defaultValue: "Open All Debug Windows")) {
                        openAllDebugWindows()
                    }
                }

                Menu(
                    String(
                        localized: "debug.menu.browserToolbarButtonSpacing",
                        defaultValue: "Browser Toolbar Button Spacing"
                    )
                ) {
                    ForEach(BrowserToolbarAccessorySpacingDebugSettings.supportedValues, id: \.self) { spacing in
                        Button {
                            browserToolbarAccessorySpacingRaw = spacing
                        } label: {
                            if browserToolbarAccessorySpacing == spacing {
                                Label {
                                    Text(verbatim: "\(spacing)")
                                } icon: {
                                    Image(systemName: "checkmark")
                                }
                            } else {
                                Text(verbatim: "\(spacing)")
                            }
                        }
                    }
                }

                Toggle(String(localized: "debug.shortcutHints.alwaysShow", defaultValue: "Always Show Shortcut Hints"), isOn: $alwaysShowShortcutHints)
                Toggle(
                    String(localized: "debug.devBuildBanner.show", defaultValue: "Show Dev Build Banner"),
                    isOn: $showSidebarDevBuildBanner
                )

                Divider()

                Picker(String(localized: "debug.titlebarControls.style", defaultValue: "Titlebar Controls Style"), selection: $titlebarControlsStyle) {
                    ForEach(TitlebarControlsStyle.allCases) { style in
                        Text(style.menuTitle).tag(style.rawValue)
                    }
                }

                Divider()

                Button(String(localized: "menu.updateLogs.copyUpdateLogs", defaultValue: "Copy Update Logs")) {
                    appDelegate.copyUpdateLogs(nil)
                }
                Button(String(localized: "menu.updateLogs.copyFocusLogs", defaultValue: "Copy Focus Logs")) {
                    appDelegate.copyFocusLogs(nil)
                }
            }
#endif

            // New tab commands
            CommandGroup(replacing: .newItem) {
                splitCommandButton(title: String(localized: "menu.file.newWindow", defaultValue: "New Window"), shortcut: menuShortcut(for: .newWindow)) {
                    appDelegate.openNewMainWindow(nil)
                }

                splitCommandButton(title: String(localized: "menu.file.newWorkspace", defaultValue: "New Workspace"), shortcut: menuShortcut(for: .newTab)) {
                    if let appDelegate = AppDelegate.shared {
                        if appDelegate.addWorkspaceInPreferredMainWindow(debugSource: "menu.newWorkspace") == nil {
#if DEBUG
                            FocusLogStore.shared.append(
                                "cmdn.route phase=fallback_new_window src=menu.newWorkspace reason=workspace_creation_returned_nil"
                            )
#endif
                            appDelegate.openNewMainWindow(nil)
                        }
                    } else {
                        activeTabManager.addTab()
                    }
                }

                splitCommandButton(title: String(localized: "menu.file.openFolder", defaultValue: "Open Folder…"), shortcut: menuShortcut(for: .openFolder)) {
                    AppDelegate.shared?.showOpenFolderPanel()
                }

                Button(
                    String(
                        localized: "menu.file.openFolderInVSCodeInline",
                        defaultValue: "Open Folder in VS Code (Inline)…"
                    )
                ) {
                    AppDelegate.shared?.showOpenFolderInInlineVSCodePanel()
                }
                .disabled(!TerminalDirectoryOpenTarget.vscodeInline.isAvailable())

                Button(
                    String(
                        localized: "menu.file.installClaudeIntegration",
                        defaultValue: "Install Claude Code Integration…"
                    )
                ) {
                    AppDelegate.shared?.openClaudeIntegrationInstaller(debugSource: "menu.installClaudeIntegration")
                }
            }

            // Close tab/workspace
            CommandGroup(after: .newItem) {
                splitCommandButton(title: String(localized: "menu.file.goToWorkspace", defaultValue: "Go to Workspace…"), shortcut: menuShortcut(for: .goToWorkspace)) {
                    let targetWindow = NSApp.keyWindow ?? NSApp.mainWindow
                    NotificationCenter.default.post(name: .commandPaletteSwitcherRequested, object: targetWindow)
                }

                splitCommandButton(title: String(localized: "menu.file.commandPalette", defaultValue: "Command Palette…"), shortcut: menuShortcut(for: .commandPalette)) {
                    let targetWindow = NSApp.keyWindow ?? NSApp.mainWindow
                    NotificationCenter.default.post(name: .commandPaletteRequested, object: targetWindow)
                }

                Divider()

                // Terminal semantics:
                // Cmd+W closes the focused tab/surface (with confirmation if needed). By
                // default, closing the last surface also closes the workspace and the window
                // if it was also the last workspace. Users can opt into keeping the workspace
                // open instead.
                splitCommandButton(title: String(localized: "menu.file.closeTab", defaultValue: "Close Tab"), shortcut: menuShortcut(for: .closeTab)) {
                    closePanelOrWindow()
                }

                splitCommandButton(title: String(localized: "menu.file.closeOtherTabs", defaultValue: "Close Other Tabs in Pane"), shortcut: menuShortcut(for: .closeOtherTabsInPane)) {
                    closeOtherTabsInFocusedPane()
                }
                .disabled(!activeTabManager.canCloseOtherTabsInFocusedPane())

                // Cmd+Shift+W closes the current workspace (with confirmation if needed). If this
                // is the last workspace, it closes the window.
                splitCommandButton(title: String(localized: "menu.file.closeWorkspace", defaultValue: "Close Workspace"), shortcut: menuShortcut(for: .closeWorkspace)) {
                    closeTabOrWindow()
                }

                Menu(String(localized: "commandPalette.switcher.workspaceLabel", defaultValue: "Workspace")) {
                    workspaceCommandMenuContent(manager: activeTabManager)
                }

                splitCommandButton(title: String(localized: "menu.file.reopenClosedBrowserPanel", defaultValue: "Reopen Closed Panel"), shortcut: menuShortcut(for: .reopenClosedBrowserPanel)) {
                    _ = activeTabManager.reopenMostRecentlyClosedBrowserPanel()
                }
            }

            // Find
            CommandGroup(after: .textEditing) {
                Menu(String(localized: "menu.find.title", defaultValue: "Find")) {
                    splitCommandButton(title: String(localized: "menu.find.find", defaultValue: "Find…"), shortcut: menuShortcut(for: .find)) {
#if DEBUG
                        dlog("find.menu Cmd+F fired")
#endif
                        activeTabManager.startSearch()
                    }

                    splitCommandButton(title: String(localized: "menu.find.findNext", defaultValue: "Find Next"), shortcut: menuShortcut(for: .findNext)) {
                        activeTabManager.findNext()
                    }

                    splitCommandButton(title: String(localized: "menu.find.findPrevious", defaultValue: "Find Previous"), shortcut: menuShortcut(for: .findPrevious)) {
                        activeTabManager.findPrevious()
                    }

                    Divider()

                    splitCommandButton(title: String(localized: "menu.find.hideFindBar", defaultValue: "Hide Find Bar"), shortcut: menuShortcut(for: .hideFind)) {
                        activeTabManager.hideFind()
                    }
                    .disabled(!(activeTabManager.isFindVisible))

                    Divider()

                    splitCommandButton(title: String(localized: "menu.find.useSelectionForFind", defaultValue: "Use Selection for Find"), shortcut: menuShortcut(for: .useSelectionForFind)) {
                        activeTabManager.searchSelection()
                    }
                    .disabled(!(activeTabManager.canUseSelectionForFind))
                }
            }

            // Tab navigation
            CommandGroup(after: .toolbar) {
                splitCommandButton(title: String(localized: "menu.view.toggleSidebar", defaultValue: "Toggle Sidebar"), shortcut: menuShortcut(for: .toggleSidebar)) {
                    if AppDelegate.shared?.toggleSidebarInActiveMainWindow() != true {
                        sidebarState.toggle()
                    }
                }

                Divider()

                splitCommandButton(title: String(localized: "menu.view.nextSurface", defaultValue: "Next Surface"), shortcut: menuShortcut(for: .nextSurface)) {
                    activeTabManager.selectNextSurface()
                }

                splitCommandButton(title: String(localized: "menu.view.previousSurface", defaultValue: "Previous Surface"), shortcut: menuShortcut(for: .prevSurface)) {
                    activeTabManager.selectPreviousSurface()
                }

                splitCommandButton(title: String(localized: "menu.view.back", defaultValue: "Back"), shortcut: menuShortcut(for: .browserBack)) {
                    activeTabManager.focusedBrowserPanel?.goBack()
                }

                splitCommandButton(title: String(localized: "menu.view.forward", defaultValue: "Forward"), shortcut: menuShortcut(for: .browserForward)) {
                    activeTabManager.focusedBrowserPanel?.goForward()
                }

                splitCommandButton(title: String(localized: "menu.view.reloadPage", defaultValue: "Reload Page"), shortcut: menuShortcut(for: .browserReload)) {
                    activeTabManager.focusedBrowserPanel?.reload()
                }

                splitCommandButton(title: String(localized: "menu.view.toggleDevTools", defaultValue: "Toggle Developer Tools"), shortcut: menuShortcut(for: .toggleBrowserDeveloperTools)) {
                    let manager = activeTabManager
                    if !manager.toggleDeveloperToolsFocusedBrowser() {
                        NSSound.beep()
                    }
                }

                splitCommandButton(title: String(localized: "menu.view.showJSConsole", defaultValue: "Show JavaScript Console"), shortcut: menuShortcut(for: .showBrowserJavaScriptConsole)) {
                    let manager = activeTabManager
                    if !manager.showJavaScriptConsoleFocusedBrowser() {
                        NSSound.beep()
                    }
                }

                splitCommandButton(title: String(localized: "menu.view.toggleReactGrab", defaultValue: "Toggle React Grab"), shortcut: menuShortcut(for: .toggleReactGrab)) {
                    if !activeTabManager.toggleReactGrabFromCurrentFocus() {
                        NSSound.beep()
                    }
                }

                splitCommandButton(title: String(localized: "menu.view.zoomIn", defaultValue: "Zoom In"), shortcut: menuShortcut(for: .browserZoomIn)) {
                    _ = activeTabManager.zoomInFocusedBrowser()
                }

                splitCommandButton(title: String(localized: "menu.view.zoomOut", defaultValue: "Zoom Out"), shortcut: menuShortcut(for: .browserZoomOut)) {
                    _ = activeTabManager.zoomOutFocusedBrowser()
                }

                splitCommandButton(title: String(localized: "menu.view.actualSize", defaultValue: "Actual Size"), shortcut: menuShortcut(for: .browserZoomReset)) {
                    _ = activeTabManager.resetZoomFocusedBrowser()
                }

                Button(String(localized: "menu.view.clearBrowserHistory", defaultValue: "Clear Browser History")) {
                    BrowserHistoryStore.shared.clearHistory()
                }

                Button(String(localized: "menu.view.importFromBrowser", defaultValue: "Import Browser Data…")) {
                    // Defer modal presentation until after AppKit finishes menu tracking.
                    DispatchQueue.main.async {
                        BrowserDataImportCoordinator.shared.presentImportDialog()
                    }
                }

                splitCommandButton(title: String(localized: "menu.view.nextWorkspace", defaultValue: "Next Workspace"), shortcut: menuShortcut(for: .nextSidebarTab)) {
                    activeTabManager.selectNextTab()
                }

                splitCommandButton(title: String(localized: "menu.view.previousWorkspace", defaultValue: "Previous Workspace"), shortcut: menuShortcut(for: .prevSidebarTab)) {
                    activeTabManager.selectPreviousTab()
                }

                splitCommandButton(title: String(localized: "menu.view.renameWorkspace", defaultValue: "Rename Workspace…"), shortcut: menuShortcut(for: .renameWorkspace)) {
                    _ = AppDelegate.shared?.requestRenameWorkspaceViaCommandPalette()
                }

                splitCommandButton(title: String(localized: "menu.view.editWorkspaceDescription", defaultValue: "Edit Workspace Description…"), shortcut: menuShortcut(for: .editWorkspaceDescription)) {
                    _ = AppDelegate.shared?.requestEditWorkspaceDescriptionViaCommandPalette()
                }

                splitCommandButton(title: String(localized: "command.toggleFullScreen.title", defaultValue: "Toggle Full Screen"), shortcut: menuShortcut(for: .toggleFullScreen)) {
                    guard let targetWindow = NSApp.keyWindow ?? NSApp.mainWindow else { return }
                    targetWindow.toggleFullScreen(nil)
                }

                Divider()

                splitCommandButton(title: String(localized: "menu.view.splitRight", defaultValue: "Split Right"), shortcut: menuShortcut(for: .splitRight)) {
                    performSplitFromMenu(direction: .right)
                }

                splitCommandButton(title: String(localized: "menu.view.splitDown", defaultValue: "Split Down"), shortcut: menuShortcut(for: .splitDown)) {
                    performSplitFromMenu(direction: .down)
                }

                splitCommandButton(title: String(localized: "menu.view.splitBrowserRight", defaultValue: "Split Browser Right"), shortcut: menuShortcut(for: .splitBrowserRight)) {
                    performBrowserSplitFromMenu(direction: .right)
                }

                splitCommandButton(title: String(localized: "menu.view.splitBrowserDown", defaultValue: "Split Browser Down"), shortcut: menuShortcut(for: .splitBrowserDown)) {
                    performBrowserSplitFromMenu(direction: .down)
                }

                Divider()

                // Numbered workspace selection (9 = last workspace)
                ForEach(1...9, id: \.self) { number in
                    let selectWorkspaceByNumberShortcut = menuShortcut(for: .selectWorkspaceByNumber)
                    if selectWorkspaceByNumberShortcut.hasChord {
                        Button(String(localized: "menu.view.workspace", defaultValue: "Workspace \(number)")) {
                            let manager = activeTabManager
                            if let targetIndex = WorkspaceShortcutMapper.workspaceIndex(forDigit: number, workspaceCount: manager.tabs.count) {
                                manager.selectTab(at: targetIndex)
                            }
                        }
                    } else {
                        Button(String(localized: "menu.view.workspace", defaultValue: "Workspace \(number)")) {
                            let manager = activeTabManager
                            if let targetIndex = WorkspaceShortcutMapper.workspaceIndex(forDigit: number, workspaceCount: manager.tabs.count) {
                                manager.selectTab(at: targetIndex)
                            }
                        }
                        .keyboardShortcut(
                            KeyEquivalent(Character("\(number)")),
                            modifiers: selectWorkspaceByNumberShortcut.eventModifiers
                        )
                    }
                }

                Divider()

                splitCommandButton(title: String(localized: "menu.view.jumpToUnread", defaultValue: "Jump to Latest Unread"), shortcut: menuShortcut(for: .jumpToUnread)) {
                    AppDelegate.shared?.jumpToLatestUnread()
                }

                splitCommandButton(title: String(localized: "menu.view.showNotifications", defaultValue: "Show Notifications"), shortcut: menuShortcut(for: .showNotifications)) {
                    showNotificationsPopover()
                }
            }
        }
    }

    private func showAboutPanel() {
        AboutWindowController.shared.show()
    }

    private func applyAppearance() {
        let mode = AppearanceSettings.mode(for: appearanceMode)
        if appearanceMode != mode.rawValue {
            appearanceMode = mode.rawValue
        }
        Self.applyAppearance(mode)
    }

    private static func applyAppearance(_ mode: AppearanceMode) {
        switch mode {
        case .system:
            NSApplication.shared.appearance = nil
        case .light:
            NSApplication.shared.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        case .auto:
            NSApplication.shared.appearance = nil
        }
    }

    private func updateSocketController() {
        let mode = SocketControlSettings.effectiveMode(userMode: currentSocketMode)
        if mode != .off {
            TerminalController.shared.start(
                tabManager: tabManager,
                socketPath: SocketControlSettings.socketPath(),
                accessMode: mode
            )
        } else {
            TerminalController.shared.stop()
        }
    }

    private var currentSocketMode: SocketControlMode {
        SocketControlSettings.migrateMode(socketControlMode)
    }

    private func menuShortcut(for action: KeyboardShortcutSettings.Action) -> StoredShortcut {
        let _ = keyboardShortcutSettingsObserver.revision
        return KeyboardShortcutSettings.shortcut(for: action)
    }

    private var notificationMenuSnapshot: NotificationMenuSnapshot {
        NotificationMenuSnapshotBuilder.make(notifications: notificationStore.notifications)
    }

    private var activeTabManager: TabManager {
        AppDelegate.shared?.synchronizeActiveMainWindowContext(
            preferredWindow: NSApp.keyWindow ?? NSApp.mainWindow
        ) ?? tabManager
    }

    private func notificationMenuItemTitle(for notification: TerminalNotification) -> String {
        let tabTitle = appDelegate.tabTitle(for: notification.tabId)
        return MenuBarNotificationLineFormatter.menuTitle(notification: notification, tabTitle: tabTitle)
    }

    private func openNotificationFromMainMenu(_ notification: TerminalNotification) {
        _ = appDelegate.openNotification(
            tabId: notification.tabId,
            surfaceId: notification.surfaceId,
            notificationId: notification.id
        )
    }

    private func performSplitFromMenu(direction: SplitDirection) {
        if AppDelegate.shared?.performSplitShortcut(direction: direction) == true {
            return
        }
        tabManager.createSplit(direction: direction)
    }

    private func performBrowserSplitFromMenu(direction: SplitDirection) {
        if AppDelegate.shared?.performBrowserSplitShortcut(direction: direction) == true {
            return
        }
        _ = tabManager.createBrowserSplit(direction: direction)
    }

    private func selectedWorkspaceIndex(in manager: TabManager, workspaceId: UUID) -> Int? {
        manager.tabs.firstIndex { $0.id == workspaceId }
    }

    private func selectedWorkspaceWindowMoveTargets(in manager: TabManager) -> [AppDelegate.WindowMoveTarget] {
        let referenceWindowId = AppDelegate.shared?.windowId(for: manager)
        return AppDelegate.shared?.windowMoveTargets(referenceWindowId: referenceWindowId) ?? []
    }

    private func toggleSelectedWorkspacePinned(in manager: TabManager) {
        guard let workspace = manager.selectedWorkspace else { return }
        manager.setPinned(workspace, pinned: !workspace.isPinned)
    }

    private func clearSelectedWorkspaceCustomName(in manager: TabManager) {
        guard let workspace = manager.selectedWorkspace else { return }
        manager.clearCustomTitle(tabId: workspace.id)
    }

    private func moveSelectedWorkspace(in manager: TabManager, by delta: Int) {
        guard let workspace = manager.selectedWorkspace,
              let currentIndex = selectedWorkspaceIndex(in: manager, workspaceId: workspace.id) else { return }
        let targetIndex = currentIndex + delta
        guard targetIndex >= 0, targetIndex < manager.tabs.count else { return }
        _ = manager.reorderWorkspace(tabId: workspace.id, toIndex: targetIndex)
        manager.selectWorkspace(workspace)
    }

    private func moveSelectedWorkspaceToTop(in manager: TabManager) {
        guard let workspace = manager.selectedWorkspace else { return }
        manager.moveTabsToTop([workspace.id])
        manager.selectWorkspace(workspace)
    }

    private func moveSelectedWorkspace(in manager: TabManager, toWindow windowId: UUID) {
        guard let workspace = manager.selectedWorkspace else { return }
        _ = AppDelegate.shared?.moveWorkspaceToWindow(workspaceId: workspace.id, windowId: windowId, focus: true)
    }

    private func moveSelectedWorkspaceToNewWindow(in manager: TabManager) {
        guard let workspace = manager.selectedWorkspace else { return }
        _ = AppDelegate.shared?.moveWorkspaceToNewWindow(workspaceId: workspace.id, focus: true)
    }

    private func closeWorkspaceIds(
        _ workspaceIds: [UUID],
        in manager: TabManager,
        allowPinned: Bool
    ) {
        manager.closeWorkspacesWithConfirmation(workspaceIds, allowPinned: allowPinned)
    }

    private func closeOtherSelectedWorkspacePeers(in manager: TabManager) {
        guard let workspace = manager.selectedWorkspace else { return }
        let workspaceIds = manager.tabs.compactMap { $0.id == workspace.id ? nil : $0.id }
        closeWorkspaceIds(workspaceIds, in: manager, allowPinned: true)
    }

    private func closeSelectedWorkspacesBelow(in manager: TabManager) {
        guard let workspace = manager.selectedWorkspace,
              let anchorIndex = selectedWorkspaceIndex(in: manager, workspaceId: workspace.id) else { return }
        let workspaceIds = manager.tabs.suffix(from: anchorIndex + 1).map(\.id)
        closeWorkspaceIds(workspaceIds, in: manager, allowPinned: true)
    }

    private func closeSelectedWorkspacesAbove(in manager: TabManager) {
        guard let workspace = manager.selectedWorkspace,
              let anchorIndex = selectedWorkspaceIndex(in: manager, workspaceId: workspace.id) else { return }
        let workspaceIds = manager.tabs.prefix(upTo: anchorIndex).map(\.id)
        closeWorkspaceIds(workspaceIds, in: manager, allowPinned: true)
    }

    private func selectedWorkspaceHasUnreadNotifications(in manager: TabManager) -> Bool {
        guard let workspaceId = manager.selectedWorkspace?.id else { return false }
        return notificationStore.notifications.contains { $0.tabId == workspaceId && !$0.isRead }
    }

    private func selectedWorkspaceHasReadNotifications(in manager: TabManager) -> Bool {
        guard let workspaceId = manager.selectedWorkspace?.id else { return false }
        return notificationStore.notifications.contains { $0.tabId == workspaceId && $0.isRead }
    }

    private func markSelectedWorkspaceRead(in manager: TabManager) {
        guard let workspaceId = manager.selectedWorkspace?.id else { return }
        notificationStore.markRead(forTabId: workspaceId)
    }

    private func markSelectedWorkspaceUnread(in manager: TabManager) {
        guard let workspaceId = manager.selectedWorkspace?.id else { return }
        notificationStore.markUnread(forTabId: workspaceId)
    }

    @ViewBuilder
    private func workspaceCommandMenuContent(manager: TabManager) -> some View {
        let workspace = manager.selectedWorkspace
        let workspaceIndex = workspace.flatMap { selectedWorkspaceIndex(in: manager, workspaceId: $0.id) }
        let windowMoveTargets = selectedWorkspaceWindowMoveTargets(in: manager)

        Button(
            workspace?.isPinned == true
                ? String(localized: "contextMenu.unpinWorkspace", defaultValue: "Unpin Workspace")
                : String(localized: "contextMenu.pinWorkspace", defaultValue: "Pin Workspace")
        ) {
            toggleSelectedWorkspacePinned(in: manager)
        }
        .disabled(workspace == nil)

        Button(String(localized: "menu.view.renameWorkspace", defaultValue: "Rename Workspace…")) {
            _ = AppDelegate.shared?.requestRenameWorkspaceViaCommandPalette()
        }
        .disabled(workspace == nil)

        Button(String(localized: "menu.view.editWorkspaceDescription", defaultValue: "Edit Workspace Description…")) {
            _ = AppDelegate.shared?.requestEditWorkspaceDescriptionViaCommandPalette()
        }
        .disabled(workspace == nil)

        if workspace?.hasCustomTitle == true {
            Button(String(localized: "contextMenu.removeCustomWorkspaceName", defaultValue: "Remove Custom Workspace Name")) {
                clearSelectedWorkspaceCustomName(in: manager)
            }
        }

        Divider()

        Button(String(localized: "contextMenu.moveUp", defaultValue: "Move Up")) {
            moveSelectedWorkspace(in: manager, by: -1)
        }
        .disabled(workspaceIndex == nil || workspaceIndex == 0)

        Button(String(localized: "contextMenu.moveDown", defaultValue: "Move Down")) {
            moveSelectedWorkspace(in: manager, by: 1)
        }
        .disabled(workspaceIndex == nil || workspaceIndex == manager.tabs.count - 1)

        Button(String(localized: "contextMenu.moveToTop", defaultValue: "Move to Top")) {
            moveSelectedWorkspaceToTop(in: manager)
        }
        .disabled(workspace == nil || workspaceIndex == 0)

        Menu(String(localized: "contextMenu.moveWorkspaceToWindow", defaultValue: "Move Workspace to Window")) {
            Button(String(localized: "contextMenu.newWindow", defaultValue: "New Window")) {
                moveSelectedWorkspaceToNewWindow(in: manager)
            }
            .disabled(workspace == nil)

            if !windowMoveTargets.isEmpty {
                Divider()
            }

            ForEach(windowMoveTargets) { target in
                Button(target.label) {
                    moveSelectedWorkspace(in: manager, toWindow: target.windowId)
                }
                .disabled(target.isCurrentWindow || workspace == nil)
            }
        }
        .disabled(workspace == nil)

        Divider()

        Button(String(localized: "menu.file.closeWorkspace", defaultValue: "Close Workspace")) {
            manager.closeCurrentWorkspaceWithConfirmation()
        }
        .disabled(workspace == nil)

        Button(String(localized: "contextMenu.closeOtherWorkspaces", defaultValue: "Close Other Workspaces")) {
            closeOtherSelectedWorkspacePeers(in: manager)
        }
        .disabled(workspace == nil || manager.tabs.count <= 1)

        Button(String(localized: "contextMenu.closeWorkspacesBelow", defaultValue: "Close Workspaces Below")) {
            closeSelectedWorkspacesBelow(in: manager)
        }
        .disabled(workspaceIndex == nil || workspaceIndex == manager.tabs.count - 1)

        Button(String(localized: "contextMenu.closeWorkspacesAbove", defaultValue: "Close Workspaces Above")) {
            closeSelectedWorkspacesAbove(in: manager)
        }
        .disabled(workspaceIndex == nil || workspaceIndex == 0)

        Divider()

        Button(String(localized: "contextMenu.markWorkspaceRead", defaultValue: "Mark Workspace as Read")) {
            markSelectedWorkspaceRead(in: manager)
        }
        .disabled(!selectedWorkspaceHasUnreadNotifications(in: manager))

        Button(String(localized: "contextMenu.markWorkspaceUnread", defaultValue: "Mark Workspace as Unread")) {
            markSelectedWorkspaceUnread(in: manager)
        }
        .disabled(!selectedWorkspaceHasReadNotifications(in: manager))
    }

    @ViewBuilder
    private func splitCommandButton(title: String, shortcut: StoredShortcut, action: @escaping () -> Void) -> some View {
        if let key = shortcut.keyEquivalent {
            Button(title, action: action)
                .keyboardShortcut(key, modifiers: shortcut.eventModifiers)
        } else {
            Button(title, action: action)
        }
    }

    private func closePanelOrWindow() {
        if let window = NSApp.keyWindow ?? NSApp.mainWindow,
           programaWindowShouldOwnCloseShortcut(window) {
            window.performClose(nil)
            return
        }
        activeTabManager.closeCurrentPanelWithConfirmation()
    }

    private func closeOtherTabsInFocusedPane() {
        activeTabManager.closeOtherTabsInFocusedPaneWithConfirmation()
    }

    private func closeTabOrWindow() {
        activeTabManager.closeCurrentTabWithConfirmation()
    }

    private func showNotificationsPopover() {
        AppDelegate.shared?.toggleNotificationsPopover(animated: false)
    }

    private func openAllDebugWindows() {
        BrowserProfilePopoverDebugWindowController.shared.show()
        SettingsAboutTitlebarDebugWindowController.shared.show()
        SidebarDebugWindowController.shared.show()
        BackgroundDebugWindowController.shared.show()
        MenuBarExtraDebugWindowController.shared.show()
    }
}

private let programaAuxiliaryWindowIdentifiers: Set<String> = [
    "cmux.settings",
    "cmux.about",
    "programa.licenses",
    "programa.browser-popup",
    "programa.settingsAboutTitlebarDebug",
    "programa.debugWindowControls",
    "programa.browserImportHintDebug",
    "programa.sidebarDebug",
    "programa.menubarDebug",
    "programa.backgroundDebug",
]

/// Returns whether the given window should handle the standard close shortcut
/// as a standalone auxiliary window instead of routing it through workspace or
/// panel-close behavior.
func programaWindowShouldOwnCloseShortcut(_ window: NSWindow?) -> Bool {
    guard let identifier = window?.identifier?.rawValue else { return false }
    return programaAuxiliaryWindowIdentifiers.contains(identifier)
}

private final class AboutWindowController: NSWindowController, NSWindowDelegate {
    static let shared = AboutWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 520),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("cmux.about")
        window.center()
        window.contentView = NSHostingView(rootView: AboutPanelView())
        SettingsAboutTitlebarDebugStore.shared.applyCurrentOptions(to: window, for: .about)
        AppDelegate.shared?.applyWindowDecorations(to: window)
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        guard let window else { return }
        SettingsAboutTitlebarDebugStore.shared.applyCurrentOptions(to: window, for: .about)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }
}

private final class AcknowledgmentsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = AcknowledgmentsWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = String(localized: "about.licenses.windowTitle", defaultValue: "Third-Party Licenses")
        window.identifier = NSUserInterfaceItemIdentifier("programa.licenses")
        window.center()
        window.contentView = NSHostingView(rootView: AcknowledgmentsView())
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
    }
}

private struct AcknowledgmentsView: View {
    private let content: String = {
        if let url = Bundle.main.url(forResource: "THIRD_PARTY_LICENSES", withExtension: "md"),
           let text = try? String(contentsOf: url) {
            return text
        }
        return String(localized: "about.licenses.notFound", defaultValue: "Licenses file not found.")
    }()

    var body: some View {
        ScrollView {
            Text(content)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
    }
}

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController()
    private var pendingFocusRestoreWorkItems: [DispatchWorkItem] = []
    private var focusRestoreGeneration = 0

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("cmux.settings")
        window.center()
        window.contentView = NSHostingView(rootView: SettingsRootView())
        SettingsAboutTitlebarDebugStore.shared.applyCurrentOptions(to: window, for: .settings)
        AppDelegate.shared?.applyWindowDecorations(to: window)
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(navigationTarget: SettingsNavigationTarget? = nil) {
        guard let window else { return }
#if DEBUG
        dlog("settings.window.show requested isVisible=\(window.isVisible ? 1 : 0) isKey=\(window.isKeyWindow ? 1 : 0)")
#endif
        SettingsAboutTitlebarDebugStore.shared.applyCurrentOptions(to: window, for: .settings)
        if !window.isVisible {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        if let navigationTarget {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                SettingsNavigationRequest.post(navigationTarget)
            }
        }
#if DEBUG
        dlog("settings.window.show completed isVisible=\(window.isVisible ? 1 : 0) isKey=\(window.isKeyWindow ? 1 : 0)")
#endif
    }

    func preserveFocusAfterPreferenceMutation() {
        guard let window, window.isVisible else { return }
        cancelPendingFocusRestore()
        focusRestoreGeneration += 1
        let generation = focusRestoreGeneration
        writeFocusDiagnosticsIfNeeded(stage: "requested")
        scheduleFocusRestore(
            for: window,
            generation: generation,
            delays: [0, 0.04, 0.12, 0.24, 0.4, 0.7]
        )
    }

    func windowWillClose(_ notification: Notification) {
        cancelPendingFocusRestore()
        writeFocusDiagnosticsIfNeeded(stage: "windowWillClose")
    }

    func windowDidBecomeKey(_ notification: Notification) {
        writeFocusDiagnosticsIfNeeded(stage: "didBecomeKey")
    }

    func windowDidResignKey(_ notification: Notification) {
        guard let window else { return }
        writeFocusDiagnosticsIfNeeded(stage: "didResignKey")
        guard focusRestoreGeneration > 0 else { return }
        scheduleFocusRestore(
            for: window,
            generation: focusRestoreGeneration,
            delays: [0, 0.03, 0.1]
        )
    }

    private func scheduleFocusRestore(
        for window: NSWindow,
        generation: Int,
        delays: [TimeInterval]
    ) {
        for (index, delay) in delays.enumerated() {
            let isLastAttempt = index == delays.count - 1
            let workItem = DispatchWorkItem { [weak self, weak window] in
                guard let self, let window, window.isVisible else { return }
                guard self.focusRestoreGeneration == generation else { return }
                self.writeFocusDiagnosticsIfNeeded(stage: "restoreAttempt.\(index)")
                if !window.isKeyWindow {
                    NSApp.activate(ignoringOtherApps: true)
                    window.orderFrontRegardless()
                    window.makeKeyAndOrderFront(nil)
                    self.writeFocusDiagnosticsIfNeeded(stage: "restoreApplied.\(index)")
                }
                if isLastAttempt, self.focusRestoreGeneration == generation {
                    self.focusRestoreGeneration = 0
                }
            }
            pendingFocusRestoreWorkItems.append(workItem)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
    }

    private func cancelPendingFocusRestore() {
        pendingFocusRestoreWorkItems.forEach { $0.cancel() }
        pendingFocusRestoreWorkItems.removeAll()
        focusRestoreGeneration = 0
    }

    private func writeFocusDiagnosticsIfNeeded(stage: String) {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["PROGRAMA_UI_TEST_DIAGNOSTICS_PATH"], !path.isEmpty else { return }

        var payload = loadFocusDiagnostics(at: path)
        payload["focusStage"] = stage
        payload["keyWindowIdentifier"] = NSApp.keyWindow?.identifier?.rawValue ?? ""
        payload["mainWindowIdentifier"] = NSApp.mainWindow?.identifier?.rawValue ?? ""
        payload["settingsWindowIsKey"] = (window?.isKeyWindow ?? false) ? "1" : "0"

        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private func loadFocusDiagnostics(at path: String) -> [String: String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return object
    }
}

enum SettingsNavigationTarget: String {
    case browser
    case browserImport
    case keyboardShortcuts
}

enum SettingsNavigationRequest {
    static let notificationName = Notification.Name("programa.settings.navigate")
    private static let targetKey = "target"

    static func post(_ target: SettingsNavigationTarget) {
        NotificationCenter.default.post(
            name: notificationName,
            object: nil,
            userInfo: [targetKey: target.rawValue]
        )
    }

    static func target(from notification: Notification) -> SettingsNavigationTarget? {
        guard let rawValue = notification.userInfo?[targetKey] as? String else { return nil }
        return SettingsNavigationTarget(rawValue: rawValue)
    }
}

private struct AboutPanelView: View {
    @Environment(\.openURL) private var openURL

    private let githubURL = URL(string: "https://github.com/darkroomengineering/programa")
    private let docsURL = URL(string: "https://github.com/darkroomengineering/programa/tree/main/docs")

    private var version: String? { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String }
    private var build: String? { Bundle.main.infoDictionary?["CFBundleVersion"] as? String }
    private var commit: String? {
        if let value = Bundle.main.infoDictionary?["ProgramaCommit"] as? String, !value.isEmpty {
            return value
        }
        let env = ProcessInfo.processInfo.environment["PROGRAMA_COMMIT"] ?? ""
        return env.isEmpty ? nil : env
    }
    private var copyright: String? { Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String }

    var body: some View {
        VStack(alignment: .center) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .renderingMode(.original)
                .frame(width: 96, height: 96)
                .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 3)

            VStack(alignment: .center, spacing: 32) {
                VStack(alignment: .center, spacing: 8) {
                    Text(String(localized: "about.appName", defaultValue: "Programa"))
                        .bold()
                        .font(.title)
                    Text(String(localized: "about.description", defaultValue: "A Ghostty-based terminal with vertical tabs\nand a notification panel for macOS."))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .font(.caption)
                        .tint(.secondary)
                        .opacity(0.8)
                }
                .textSelection(.enabled)

                VStack(spacing: 2) {
                    if let version {
                        AboutPropertyRow(label: String(localized: "about.version", defaultValue: "Version"), text: version)
                    }
                    if let build {
                        AboutPropertyRow(label: String(localized: "about.build", defaultValue: "Build"), text: build)
                    }
                    let commitText = commit ?? "—"
                    let commitURL = commit.flatMap { hash in
                        URL(string: "https://github.com/darkroomengineering/programa/commit/\(hash)")
                    }
                    AboutPropertyRow(label: String(localized: "about.commit", defaultValue: "Commit"), text: commitText, url: commitURL)
                }
                .frame(maxWidth: .infinity)

                HStack(spacing: 8) {
                    if let url = docsURL {
                        Button(String(localized: "about.docs", defaultValue: "Docs")) {
                            openURL(url)
                        }
                    }
                    if let url = githubURL {
                        Button(String(localized: "about.github", defaultValue: "GitHub")) {
                            openURL(url)
                        }
                    }
                    Button(String(localized: "about.licenses", defaultValue: "Licenses")) {
                        AcknowledgmentsWindowController.shared.show()
                    }
                }

                if let copy = copyright, !copy.isEmpty {
                    Text(copy)
                        .font(.caption)
                        .textSelection(.enabled)
                        .tint(.secondary)
                        .opacity(0.8)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.top, 8)
        .padding(32)
        .frame(minWidth: 280)
        .background(AboutVisualEffectBackground(material: .underWindowBackground).ignoresSafeArea())
    }
}

private struct AboutPropertyRow: View {
    private let label: String
    private let text: String
    private let url: URL?

    init(label: String, text: String, url: URL? = nil) {
        self.label = label
        self.text = text
        self.url = url
    }

    @ViewBuilder private var textView: some View {
        Text(text)
            .frame(width: 140, alignment: .leading)
            .padding(.leading, 2)
            .tint(.secondary)
            .opacity(0.8)
            .monospaced()
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .frame(width: 126, alignment: .trailing)
                .padding(.trailing, 2)
            if let url {
                Link(destination: url) {
                    textView
                }
            } else {
                textView
            }
        }
        .font(.callout)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity)
    }
}

struct AboutVisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    let isEmphasized: Bool

    init(
        material: NSVisualEffectView.Material,
        blendingMode: NSVisualEffectView.BlendingMode = .behindWindow,
        isEmphasized: Bool = false
    ) {
        self.material = material
        self.blendingMode = blendingMode
        self.isEmphasized = isEmphasized
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.isEmphasized = isEmphasized
    }

    func makeNSView(context: Context) -> NSVisualEffectView {
        let visualEffect = NSVisualEffectView()
        visualEffect.autoresizingMask = [.width, .height]
        return visualEffect
    }
}

final class AppIconAppearanceObserver: NSObject {
    static let shared = AppIconAppearanceObserver()
    private var observation: NSKeyValueObservation?

    private override init() { super.init() }

    func startObserving() {
        applyIconForCurrentAppearance()
        guard observation == nil else { return }
        observation = NSApp.observe(\.effectiveAppearance, options: []) { [weak self] _, _ in
            DispatchQueue.main.async {
                guard let self, self.observation != nil else { return }
                self.applyIconForCurrentAppearance()
            }
        }
    }

    func stopObserving() {
        observation?.invalidate()
        observation = nil
    }

    private func applyIconForCurrentAppearance() {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let imageName = isDark ? "AppIconDark" : "AppIconLight"
        if let icon = NSImage(named: imageName) {
            NSApplication.shared.applicationIconImage = icon
        }
    }
}

enum ProgramaUITestCapture {
    static func appendLineIfConfigured(envKey: String, line: String) -> Bool {
        guard let url = configuredURL(for: envKey) else { return false }
        appendLine(line, to: url)
        return true
    }

    static func mutateJSONObjectIfConfigured(
        envKey: String,
        _ update: (inout [String: Any]) -> Void
    ) -> Bool {
        guard let url = configuredURL(for: envKey) else { return false }
        mutateJSONObject(at: url, update)
        return true
    }

    private static func configuredURL(for envKey: String) -> URL? {
        let env = ProcessInfo.processInfo.environment
        guard let rawPath = env[envKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawPath.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: rawPath)
    }

    private static func appendLine(_ line: String, to url: URL) {
        ensureParentDirectory(for: url)
        let payload = (line + "\n").data(using: .utf8) ?? Data()

        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: payload)
            } catch {
                if let existing = try? Data(contentsOf: url) {
                    var combined = existing
                    combined.append(payload)
                    try? combined.write(to: url, options: .atomic)
                } else {
                    try? payload.write(to: url, options: .atomic)
                }
            }
            return
        }

        try? payload.write(to: url, options: .atomic)
    }

    private static func mutateJSONObject(
        at url: URL,
        _ update: (inout [String: Any]) -> Void
    ) {
        ensureParentDirectory(for: url)
        var payload: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            payload = object
        }
        update(&payload)
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return
        }
        try? data.write(to: url, options: .atomic)
    }

    private static func ensureParentDirectory(for url: URL) {
        let directory = url.deletingLastPathComponent()
        guard !directory.path.isEmpty else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}

enum ProgramaRuntimeDebugCapture {
    private struct Configuration {
        let baseURL: URL
        let token: String
        let sessionID: String
    }

    private static let configuration: Configuration? = {
        let env = ProcessInfo.processInfo.environment
        guard let baseURLString = env["PROGRAMA_RUNTIME_DEBUG_BASE_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              let baseURL = URL(string: baseURLString),
              let token = env["PROGRAMA_RUNTIME_DEBUG_TOKEN"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty,
              let sessionID = env["PROGRAMA_RUNTIME_DEBUG_SESSION_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionID.isEmpty else {
            return nil
        }
        return Configuration(baseURL: baseURL, token: token, sessionID: sessionID)
    }()

    private static let lock = NSLock()
    private static var sequence: Int = 0

    static func logIfConfigured(
        hypothesisID: String,
        source: String,
        name: String,
        expected: String? = nil,
        actual: String? = nil,
        data: [String: Any] = [:]
    ) {
        guard let configuration else { return }

        var payload: [String: Any] = [
            "session_id": configuration.sessionID,
            "hypothesis_id": hypothesisID,
            "service": "programa-macos",
            "source": source,
            "name": name,
            "ts": ISO8601DateFormatter().string(from: Date()),
            "mono_ms": ProcessInfo.processInfo.systemUptime * 1000,
            "seq": nextSequence(),
            "data": data
        ]
        if let expected {
            payload["expected"] = expected
        }
        if let actual {
            payload["actual"] = actual
        }

        guard JSONSerialization.isValidJSONObject(payload),
              let requestBody = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            return
        }

        var request = URLRequest(url: configuration.baseURL.appendingPathComponent("api/logs"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.token, forHTTPHeaderField: "X-Debug-Token")
        request.httpBody = requestBody

        URLSession.shared.dataTask(with: request).resume()
    }

    private static func nextSequence() -> Int {
        lock.lock()
        defer { lock.unlock() }
        sequence += 1
        return sequence
    }
}

private func openProgramaSettingsFileInEditor() {
    let url = KeyboardShortcutSettings.settingsFileStore.settingsFileURLForEditing()
    PreferredEditorSettings.open(url)
}

func openProgramaSettingsFileInTextEdit() {
    #if os(macOS)
    let fileURL = KeyboardShortcutSettings.settingsFileStore.settingsFileURLForEditing()
    let editorURL = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
    let configuration = NSWorkspace.OpenConfiguration()
    NSWorkspace.shared.open([fileURL], withApplicationAt: editorURL, configuration: configuration)
    #endif
}
