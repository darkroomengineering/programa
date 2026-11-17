import Foundation

/// Every Settings window row that holds a preference, with the settings.json key that sets it
/// as the raw value. A row with no settings.json key has no raw value.
///
/// `scripts/check-settings-docs.py` reads this enum and fails CI when a schema key has no case
/// here, or a case has no key, unless the script lists it with a reason. Add the case together
/// with the row, and look the row's managed state up through `SettingsFileStatusModel.isManaged`.
enum SettingsRow: String, CaseIterable {
    // General > App
    case newWorkspacePlacement = "app.newWorkspacePlacement"
    case showInMenuBar = "notifications.showInMenuBar"
    case warnBeforeQuit = "app.warnBeforeQuit"
    case confirmCloseLastPane = "app.confirmCloseLastPane"
    case saveScrollbackOnQuit = "app.saveScrollbackOnQuit"
    case autoResumeAgents = "app.autoResumeAgents"
    case reapLeftoverAgentProcesses = "app.reapLeftoverAgentProcesses"
    case commandPaletteSearchesAllSurfaces = "app.commandPaletteSearchesAllSurfaces"
    case reviewDiffRenderer = "app.reviewDiffRenderer"

    // General > Notifications
    case desktopNotifications
    case notificationSound = "notifications.sound"

    // General > Links
    case externalAppOpenAllowlist = "browser.externalAppOpenAllowlist"

    // General > Storage
    case worktreeDirectory = "worktrees.directory"
    case autoRemoveMergedWorktrees = "worktrees.autoRemoveMerged"
    case autoRemoveWorktreesAfterHours = "worktrees.autoRemoveAfterHours"
    case autoCleanCaches = "storage.autoCleanCaches"
    case lowDiskWarning = "storage.lowDiskWarningGB"

    // Appearance > Appearance
    case appearance = "app.appearance"
    case minimalMode = "app.minimalMode"

    // Appearance > Terminal
    case terminalTheme = "app.terminalTheme"
    case terminalFont = "app.terminalFont"

    // Appearance > Sidebar
    case showClaudeQuota = "sidebarAppearance.showClaudeQuota"

    // Automation > Socket Control
    case socketControlMode = "automation.socketControlMode"
    case socketPassword = "automation.socketPassword"

    // Automation > Agents
    case claudeCodeIntegration = "automation.claudeCodeIntegration"
    case claudeTeamsByDefault = "automation.claudeTeamsByDefault"
    case holdAgentTextWhileTyping = "automation.holdAgentTextWhileTyping"
    case protectApprovalPrompts = "automation.protectApprovalPrompts"
    case agentScreenDetection = "automation.agentScreenDetection"

    // Automation > Custom Commands
    case trustedDirectories = "customCommands.trustedDirectories"

    // Shortcuts > Keyboard Shortcuts
    case shortcutBindings = "shortcuts.bindings"

    /// The settings.json key path, such as `app.warnBeforeQuit`, or nil for a Settings-only row.
    var settingsFileKey: String? {
        rawValue.contains(".") ? rawValue : nil
    }

    /// The UserDefaults key settings.json writes for this row. Nil for rows whose value lives
    /// elsewhere (Keychain, Ghostty config, trust store, shortcut store) or nowhere.
    var defaultsKey: String? {
        switch self {
        case .newWorkspacePlacement: WorkspacePlacementSettings.placementKey
        case .showInMenuBar: MenuBarExtraSettings.showInMenuBarKey
        case .warnBeforeQuit: QuitWarningSettings.warnBeforeQuitKey
        case .confirmCloseLastPane: LastPaneCloseWarningSettings.confirmCloseLastPaneKey
        case .saveScrollbackOnQuit: ScrollbackPersistenceSettings.persistScrollbackKey
        case .autoResumeAgents: AgentAutoResumeSettings.autoResumeAgentsKey
        case .reapLeftoverAgentProcesses: LeftoverProcessReaperSettings.reapLeftoverAgentProcessesKey
        case .commandPaletteSearchesAllSurfaces: CommandPaletteSwitcherSearchSettings.searchAllSurfacesKey
        case .reviewDiffRenderer: ReviewDiffRendererSettings.rendererKey
        case .notificationSound: NotificationSoundSettings.key
        case .externalAppOpenAllowlist: ExternalOpenPolicy.allowlistKey
        case .worktreeDirectory: StorageSettings.directoryKey
        case .autoRemoveMergedWorktrees: StorageSettings.autoRemoveMergedKey
        case .autoRemoveWorktreesAfterHours: StorageSettings.autoRemoveAfterHoursKey
        case .autoCleanCaches: StorageSettings.autoCleanCachesKey
        case .lowDiskWarning: StorageSettings.lowDiskWarningGBKey
        case .appearance: AppearanceSettings.appearanceModeKey
        case .minimalMode: WorkspacePresentationModeSettings.modeKey
        case .showClaudeQuota: "sidebarShowClaudeQuota"
        case .socketControlMode: SocketControlSettings.appStorageKey
        case .claudeCodeIntegration: ClaudeCodeIntegrationSettings.hooksEnabledKey
        case .claudeTeamsByDefault: ClaudeCodeIntegrationSettings.teamsByDefaultKey
        case .holdAgentTextWhileTyping: DraftGuardSettings.enabledKey
        case .protectApprovalPrompts: ApprovalGuardSettings.enabledKey
        case .agentScreenDetection: AgentScreenDetectionSettings.enabledKey
        case .desktopNotifications, .terminalTheme, .terminalFont, .socketPassword,
             .trustedDirectories, .shortcutBindings:
            nil
        }
    }
}
