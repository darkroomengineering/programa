import AppKit
import SwiftUI
import Darwin
import Bonsplit
import UniformTypeIdentifiers


enum WorkspacePresentationModeSettings {
    static let modeKey = "workspacePresentationMode"

    enum Mode: String {
        case standard
        case minimal
    }

    static let defaultMode: Mode = .minimal

    static func mode(for rawValue: String?) -> Mode {
        Mode(rawValue: rawValue ?? "") ?? defaultMode
    }

    static func mode(defaults: UserDefaults = .standard) -> Mode {
        mode(for: defaults.string(forKey: modeKey))
    }

    static func isMinimal(defaults: UserDefaults = .standard) -> Bool {
        mode(defaults: defaults) == .minimal
    }
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark
    case auto

    var id: String { rawValue }

    static var visibleCases: [AppearanceMode] {
        [.system, .light, .dark]
    }

    var displayName: String {
        switch self {
        case .system:
            return String(localized: "appearance.system", defaultValue: "System")
        case .light:
            return String(localized: "appearance.light", defaultValue: "Light")
        case .dark:
            return String(localized: "appearance.dark", defaultValue: "Dark")
        case .auto:
            return String(localized: "appearance.auto", defaultValue: "Auto")
        }
    }
}

enum AppearanceSettings {
    static let appearanceModeKey = "appearanceMode"
    static let defaultMode: AppearanceMode = .system

    static func mode(for rawValue: String?) -> AppearanceMode {
        guard let rawValue, let mode = AppearanceMode(rawValue: rawValue) else {
            return defaultMode
        }
        if mode == .auto {
            return .system
        }
        return mode
    }

    @discardableResult
    static func resolvedMode(defaults: UserDefaults = .standard) -> AppearanceMode {
        let stored = defaults.string(forKey: appearanceModeKey)
        let resolved = mode(for: stored)
        if stored != resolved.rawValue {
            defaults.set(resolved.rawValue, forKey: appearanceModeKey)
        }
        return resolved
    }
}



enum QuitWarningSettings {
    static let warnBeforeQuitKey = "warnBeforeQuitShortcut"
    static let defaultWarnBeforeQuit = true
    private static let flag = UserDefaultsFlag(key: warnBeforeQuitKey, defaultValue: defaultWarnBeforeQuit)

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        flag.isEnabled(defaults: defaults)
    }

    static func setEnabled(_ isEnabled: Bool, defaults: UserDefaults = .standard) {
        flag.setEnabled(isEnabled, defaults: defaults)
    }
}

enum ScrollbackPersistenceSettings {
    static let persistScrollbackKey = "sessionPersistScrollback"
    static let defaultPersistScrollback = true
    private static let flag = UserDefaultsFlag(key: persistScrollbackKey, defaultValue: defaultPersistScrollback)
    static let failureKey = "sessionPersistScrollbackFailure"
    @MainActor private static var defaultsObserver: NSObjectProtocol?
    @MainActor private static var appliedPreference: Bool?
    @MainActor private static var migrationInProgress = false

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        flag.isEnabled(defaults: defaults) && defaults.string(forKey: failureKey) == nil
    }

    @MainActor static func configureAtStartup() {
        setEnabled(flag.isEnabled(defaults: .standard), migrate: false)
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                let requested = flag.isEnabled(defaults: .standard)
                if requested != appliedPreference { setEnabled(requested) }
            }
        }
    }

    @MainActor static func setEnabled(_ enabled: Bool, migrate: Bool = true) {
        appliedPreference = enabled
        // Publish the requested opt-out even if storage fails. The persistent
        // failure state prevents the UI from presenting that as a guarantee.
        UserDefaults.standard.set(enabled, forKey: persistScrollbackKey)
        do {
            try SessionWALStore.shared.transitionPersistence(enabled: enabled)
            UserDefaults.standard.removeObject(forKey: failureKey)
        } catch {
            UserDefaults.standard.set("storage", forKey: failureKey)
            return
        }
        if !enabled {
            if SessionEscrowClient.hasLegacySessions() {
                UserDefaults.standard.set("legacy", forKey: failureKey)
            }
            if migrate { retryLegacyMigration() }
        }
    }

    @MainActor static func retry() {
        setEnabled(flag.isEnabled(defaults: .standard))
    }

    @MainActor static func retryLegacyMigration() {
        guard (!flag.isEnabled(defaults: .standard) || !SessionEscrowRetainedDescriptor.pending().isEmpty), !migrationInProgress,
              UserDefaults.standard.string(forKey: failureKey) != "storage" else { return }
        migrationInProgress = true
        SessionEscrowClient.migrateLegacySessions { success in
            DispatchQueue.main.async {
                migrationInProgress = false
                guard !flag.isEnabled(defaults: .standard) else { return }
                if success || !SessionEscrowClient.hasLegacySessions() {
                    UserDefaults.standard.removeObject(forKey: failureKey)
                } else {
                    UserDefaults.standard.set("legacy", forKey: failureKey)
                }
            }
        }
    }
}

enum CommandPaletteSwitcherSearchSettings {
    static let searchAllSurfacesKey = "commandPalette.switcherSearchAllSurfaces"
    static let defaultSearchAllSurfaces = false
    private static let flag = UserDefaultsFlag(key: searchAllSurfacesKey, defaultValue: defaultSearchAllSurfaces)

}

enum ClaudeCodeIntegrationSettings {
    static let hooksEnabledKey = "claudeCodeHooksEnabled"
    static let defaultHooksEnabled = true
    private static let hooksFlag = UserDefaultsFlag(key: hooksEnabledKey, defaultValue: defaultHooksEnabled)

    static func hooksEnabled(defaults: UserDefaults = .standard) -> Bool {
        hooksFlag.isEnabled(defaults: defaults)
    }
}

/// Screen-manifest agent detection (docs/plans/screen-manifest-detection.md): pattern-matches
/// the terminal buffer against per-agent manifests to infer `working`/`blocked`/`idle` for
/// agents with no installed lifecycle hooks (Gemini CLI, Copilot CLI, etc.). Defaults on;
/// hooks-managed surfaces (Claude Code, Codex, OpenCode with hooks installed) are never affected
/// -- hooks always win (see `Workspace.updatePanelAgentState`).
enum AgentScreenDetectionSettings {
    static let enabledKey = "agentScreenDetectionEnabled"
    static let defaultEnabled = true
    private static let flag = UserDefaultsFlag(key: enabledKey, defaultValue: defaultEnabled)

    static func enabled(defaults: UserDefaults = .standard) -> Bool {
        flag.isEnabled(defaults: defaults)
    }
}

enum WelcomeSettings {
    static let shownKey = "programaWelcomeShown"
}

enum PreferredEditorSettings {
    /// Open a file path from terminal content with the system default application.
    static func open(_ url: URL) {
#if DEBUG
        if ProgramaUITestCapture.appendLineIfConfigured(
            envKey: "PROGRAMA_UI_TEST_CAPTURE_OPEN_PATH",
            line: url.path
        ) {
            return
        }
#endif

        openWithSystem(url)
    }

    /// System open for a path from terminal content. An executable or app bundle would
    /// launch rather than open for editing, so it goes through the external-open prompt.
    private static func openWithSystem(_ url: URL) {
        if ExternalOpenPolicy.targetIsExecutable(url) {
            _ = ExternalOpenPolicy.confirmAndOpen(url)
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}


/// The tabs the settings window is split across.
///
/// Tabs group settings by the
/// question a user is answering, and each tab is further split into its own
/// named sections so a tab is never just one undivided pile of rows: General
/// covers how the app behaves day to day (App), what it notifies you about
/// (Notifications), and how to start over (Reset); Appearance covers how the
/// app looks (theme, window chrome) and how the sidebar looks and behaves
/// (Sidebar); Automation covers the socket used for scripting it (Socket
/// Control), the coding agents it integrates with (Agents), and per-project
/// custom commands (Custom Commands).
///
/// Keyboard Shortcuts stays on its own because it renders one row per
/// `KeyboardShortcutSettings.Action` -- 57 of them -- and would swamp whatever
/// it shared a tab with.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case appearance
    case automation
    case shortcuts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: String(localized: "settings.tab.general", defaultValue: "General")
        case .appearance: String(localized: "settings.tab.appearance", defaultValue: "Appearance")
        case .automation: String(localized: "settings.tab.automation", defaultValue: "Automation")
        case .shortcuts: String(localized: "settings.tab.shortcuts", defaultValue: "Shortcuts")
        }
    }

    /// The tab that owns a deep-link target, so `SettingsNavigationRequest`
    /// still lands on the right content now that it is not all one scroll.
    static func owning(_ target: SettingsNavigationTarget) -> SettingsTab {
        switch target {
        case .keyboardShortcuts: .shortcuts
        }
    }
}
