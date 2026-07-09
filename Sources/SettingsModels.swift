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

enum PaneFirstClickFocusSettings {
    static let enabledKey = "paneFirstClickFocus.enabled"
    static let defaultEnabled = false
    private static let flag = UserDefaultsFlag(key: enabledKey, defaultValue: defaultEnabled)

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        flag.isEnabled(defaults: defaults)
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

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        flag.isEnabled(defaults: defaults)
    }
}

enum CommandPaletteRenameSelectionSettings {
    static let selectAllOnFocusKey = "commandPalette.renameSelectAllOnFocus"
    static let defaultSelectAllOnFocus = true
    private static let flag = UserDefaultsFlag(key: selectAllOnFocusKey, defaultValue: defaultSelectAllOnFocus)

    static func selectAllOnFocusEnabled(defaults: UserDefaults = .standard) -> Bool {
        flag.isEnabled(defaults: defaults)
    }
}

enum CommandPaletteSwitcherSearchSettings {
    static let searchAllSurfacesKey = "commandPalette.switcherSearchAllSurfaces"
    static let defaultSearchAllSurfaces = false
    private static let flag = UserDefaultsFlag(key: searchAllSurfacesKey, defaultValue: defaultSearchAllSurfaces)

    static func searchAllSurfacesEnabled(defaults: UserDefaults = .standard) -> Bool {
        flag.isEnabled(defaults: defaults)
    }
}

enum ClaudeCodeIntegrationSettings {
    static let hooksEnabledKey = "claudeCodeHooksEnabled"
    static let defaultHooksEnabled = true
    static let customClaudePathKey = "claudeCodeCustomClaudePath"
    private static let hooksFlag = UserDefaultsFlag(key: hooksEnabledKey, defaultValue: defaultHooksEnabled)

    static func hooksEnabled(defaults: UserDefaults = .standard) -> Bool {
        hooksFlag.isEnabled(defaults: defaults)
    }

    static func customClaudePath(defaults: UserDefaults = .standard) -> String? {
        let value = defaults.string(forKey: customClaudePathKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }
}

enum WelcomeSettings {
    static let shownKey = "programaWelcomeShown"
}

enum PreferredEditorSettings {
    static let key = "preferredEditorCommand"

    /// Returns the configured editor command, or nil to use system default.
    static func resolvedCommand(defaults: UserDefaults = .standard) -> String? {
        guard let stored = defaults.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !stored.isEmpty else {
            return nil
        }
        return stored
    }

    /// Open a file path with the user's preferred editor, falling back to system default.
    static func open(_ url: URL) {
        if ProgramaUITestCapture.appendLineIfConfigured(
            envKey: "PROGRAMA_UI_TEST_CAPTURE_OPEN_PATH",
            line: url.path
        ) {
            return
        }

        guard let command = resolvedCommand() else {
            NSWorkspace.shared.open(url)
            return
        }
        let path = url.path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "\(command) \(shellQuote(path))"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            // Check exit status on a background thread; fall back on failure
            // (e.g. command not found exits 127 but /bin/sh itself succeeds)
            DispatchQueue.global(qos: .userInitiated).async {
                process.waitUntilExit()
                if process.terminationStatus != 0 {
                    DispatchQueue.main.async { NSWorkspace.shared.open(url) }
                }
            }
        } catch {
            NSWorkspace.shared.open(url)
        }
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

