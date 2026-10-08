import Bonsplit
import Combine
import Foundation

@MainActor
final class KeyboardShortcutSettingsObserver: ObservableObject {
    static let shared = KeyboardShortcutSettingsObserver()

    @Published private(set) var revision: UInt64 = 0

    private var cancellable: AnyCancellable?

    private init(notificationCenter: NotificationCenter = .default) {
        cancellable = notificationCenter.publisher(for: KeyboardShortcutSettings.didChangeNotification)
            .sink { [weak self] _ in
                self?.revision &+= 1
            }
    }
}

final class ProgramaSettingsFileStore {
    static let shared = ProgramaSettingsFileStore()

    static let currentSchemaVersion = 1
    /// Posted (on any thread) after every reload attempt, including one that kept the previous
    /// settings because the file failed to parse. Settings observes it to refresh which rows
    /// are managed by the file and whether to show the parse-error banner.
    static let didReloadNotification = Notification.Name("programa.settingsFile.didReload")
    static let schemaURLString = "https://raw.githubusercontent.com/darkroomengineering/programa/main/Resources/settings.schema.json"

    private static let releaseBundleIdentifier = "com.darkroom.programa"
    private static let backupsDefaultsKey = "programa.settingsFile.backups.v1"
    fileprivate static let trustedDirectoriesBackupIdentifier = "customCommands.trustedDirectories"
    fileprivate static let socketPasswordBackupIdentifier = "automation.socketPassword"
    fileprivate static let terminalThemeBackupIdentifier = "app.terminalTheme"
    // Restore-only: settings.json does not manage opacity or blur, but a backup saved by an older
    // build must still restore the user's own Ghostty value once, then be discarded.
    fileprivate static let terminalOpacityBackupIdentifier = "app.terminalOpacity"
    fileprivate static let terminalBlurBackupIdentifier = "app.terminalBlur"
    fileprivate static let terminalFontBackupIdentifier = "app.terminalFont"

    static var defaultPrimaryPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(".config/programa/settings.json")
    }

    static var defaultFallbackPath: String? {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        return appSupport
            .appendingPathComponent(releaseBundleIdentifier, isDirectory: true)
            .appendingPathComponent("settings.json", isDirectory: false)
            .path
    }

    private let primaryPath: String
    private let fallbackPath: String?
    private let fileManager: FileManager
    private let notificationCenter: NotificationCenter
    private let terminalThemeStore: TerminalThemeStore
    private let terminalThemeReloadHandler: () -> Void
    private let stateLock = NSLock()
    private let managedSettingsQueue = DispatchQueue(
        label: "com.darkroom.programa.settings-file.managed-apply",
        qos: .userInitiated
    )
    private let managedSettingsQueueKey = DispatchSpecificKey<UInt8>()

    private var primaryWatcher: ShortcutSettingsFileWatcher?
    private var fallbackWatcher: ShortcutSettingsFileWatcher?
    private var defaultsCancellable: AnyCancellable?
    private var trustObserver: NSObjectProtocol?
    private var socketPasswordObserver: NSObjectProtocol?

    private var shortcutsByAction: [KeyboardShortcutSettings.Action: StoredShortcut] = [:]
    private var activeManagedUserDefaults: [String: ManagedSettingsValue] = [:]
    private var activeManagedCustomSettings = ManagedCustomSettings()
    private var isApplyingManagedSettings = false
    private var lastParseError: String?
    private(set) var activeSourcePath: String?

    init(
        primaryPath: String = ProgramaSettingsFileStore.defaultPrimaryPath,
        fallbackPath: String? = ProgramaSettingsFileStore.defaultFallbackPath,
        fileManager: FileManager = .default,
        notificationCenter: NotificationCenter = .default,
        terminalThemeStore: TerminalThemeStore = .live(),
        terminalThemeReloadHandler: @escaping () -> Void = {
            TerminalThemeStore.requestReload(
                targetBundleIdentifier: Bundle.main.bundleIdentifier
                    ?? TerminalThemeStore.overrideBundleIdentifier
            )
        },
        startWatching: Bool = true
    ) {
        self.primaryPath = primaryPath
        self.fallbackPath = fallbackPath
        self.fileManager = fileManager
        self.notificationCenter = notificationCenter
        self.terminalThemeStore = terminalThemeStore
        self.terminalThemeReloadHandler = terminalThemeReloadHandler
        managedSettingsQueue.setSpecific(key: managedSettingsQueueKey, value: 1)

        bootstrapPrimaryTemplateIfNeeded()
        reload()
        guard startWatching else { return }

        primaryWatcher = ShortcutSettingsFileWatcher(path: primaryPath, fileManager: fileManager) { [weak self] in
            DispatchQueue.main.async {
                self?.reload()
            }
        }
        if let fallbackPath {
            fallbackWatcher = ShortcutSettingsFileWatcher(path: fallbackPath, fileManager: fileManager) { [weak self] in
                DispatchQueue.main.async {
                    self?.reload()
                }
            }
        }

        defaultsCancellable = notificationCenter.publisher(for: UserDefaults.didChangeNotification)
            .sink { [weak self] _ in
                self?.reapplyManagedSettingsIfNeeded()
            }
        trustObserver = notificationCenter.addObserver(
            forName: ProgramaDirectoryTrust.didChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.reapplyManagedSettingsIfNeeded()
        }
        socketPasswordObserver = notificationCenter.addObserver(
            forName: SocketControlPasswordStore.didChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.reapplyManagedSettingsIfNeeded()
        }
    }

    deinit {
        primaryWatcher?.stop()
        fallbackWatcher?.stop()
        defaultsCancellable?.cancel()
        if let trustObserver {
            notificationCenter.removeObserver(trustObserver)
        }
        if let socketPasswordObserver {
            notificationCenter.removeObserver(socketPasswordObserver)
        }
    }

    func reload() {
        onManagedSettingsQueue {
            reloadOnManagedSettingsQueue()
        }
    }

    private func reloadOnManagedSettingsQueue() {
        defer { notificationCenter.post(name: Self.didReloadNotification, object: self) }
        let previousShortcuts = synchronized { shortcutsByAction }
        let previousActiveSourcePath = synchronized { activeSourcePath }
        let resolved: ResolvedSettingsSnapshot
        switch resolveSettings() {
        case .resolved(let snapshot):
            resolved = snapshot
        case .invalid(let path, let message):
            // A file that fails to parse is usually a save in the middle of an edit. Keep every
            // value applied from the last good parse instead of restoring the pre-file backups
            // (which would flip socket mode, clear the password and drop trusted directories
            // until the next good save), and tell the user what is wrong.
            dilog("settings.file", "parse error at \(path), keeping previous settings: \(message)")
            synchronized {
                lastParseError = message
                if activeSourcePath == nil { activeSourcePath = path }
            }
            return
        }
        applyManagedSettings(snapshot: resolved)
        synchronized {
            shortcutsByAction = resolved.shortcuts
            activeManagedUserDefaults = resolved.managedUserDefaults
            activeManagedCustomSettings = resolved.managedCustomSettings
            activeSourcePath = resolved.path
            lastParseError = nil
        }

        if previousShortcuts != resolved.shortcuts || previousActiveSourcePath != resolved.path {
            KeyboardShortcutSettings.notifySettingsFileDidChange()
        }
    }

    /// The parse error of the active settings file when its last reload failed (the previous
    /// good settings stay applied meanwhile), or nil when it parsed.
    func currentParseError() -> String? {
        synchronized { lastParseError }
    }

    /// Whether settings.json currently sets the UserDefaults key `defaultsKey`. A control bound
    /// to such a key is reverted on the next reapply, so Settings disables it.
    func isManagedByFile(defaultsKey: String) -> Bool {
        synchronized { activeManagedUserDefaults[defaultsKey] != nil }
    }

    func isTrustedDirectoriesManagedByFile() -> Bool {
        synchronized { activeManagedCustomSettings.trustedDirectories != nil }
    }

    func isSocketPasswordManagedByFile() -> Bool {
        synchronized { activeManagedCustomSettings.socketPassword != nil }
    }

    func override(for action: KeyboardShortcutSettings.Action) -> StoredShortcut? {
        synchronized { shortcutsByAction[action] }
    }

    func isManagedByFile(_ action: KeyboardShortcutSettings.Action) -> Bool {
        synchronized { shortcutsByAction[action] != nil }
    }

    func isTerminalThemeManagedByFile() -> Bool {
        synchronized { activeManagedCustomSettings.terminalTheme != nil }
    }

    func isTerminalFontManagedByFile() -> Bool {
        synchronized { activeManagedCustomSettings.terminalFont != nil }
    }

    func settingsFileURLForEditing() -> URL {
        if let activeSourcePath = synchronized({ activeSourcePath }) {
            return URL(fileURLWithPath: activeSourcePath)
        }

        bootstrapPrimaryTemplateIfNeeded()
        reload()

        if let activeSourcePath = synchronized({ activeSourcePath }) {
            return URL(fileURLWithPath: activeSourcePath)
        }

        return URL(fileURLWithPath: primaryPath)
    }

    func settingsFileDisplayPath() -> String {
        let path = synchronized { activeSourcePath } ?? primaryPath
        return (path as NSString).abbreviatingWithTildeInPath
    }

    private func bootstrapPrimaryTemplateIfNeeded() {
        guard !fileManager.fileExists(atPath: primaryPath) else { return }
        if let fallbackPath, fileManager.fileExists(atPath: fallbackPath) {
            return
        }

        let fileURL = URL(fileURLWithPath: primaryPath)
        let directoryURL = fileURL.deletingLastPathComponent()

        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755]
            )
            let template = Self.defaultTemplate()
            try template.write(to: fileURL, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            NSLog("[ProgramaSettingsFileStore] failed to bootstrap %@: %@", primaryPath, String(describing: error))
        }
    }

    private func reapplyManagedSettingsIfNeeded() {
        onManagedSettingsQueue {
            reapplyManagedSettingsOnManagedSettingsQueueIfNeeded()
        }
    }

    private func reapplyManagedSettingsOnManagedSettingsQueueIfNeeded() {
        let snapshot: ResolvedSettingsSnapshot? = synchronized {
            guard !isApplyingManagedSettings else { return nil }
            if activeManagedUserDefaults.isEmpty && activeManagedCustomSettings.isEmpty {
                return nil
            }
            return ResolvedSettingsSnapshot(
                path: activeSourcePath,
                shortcuts: shortcutsByAction,
                managedUserDefaults: activeManagedUserDefaults,
                managedCustomSettings: activeManagedCustomSettings
            )
        }
        guard let snapshot else { return }
        applyManagedSettings(snapshot: snapshot, updateBackups: false)
    }

    private func onManagedSettingsQueue<T>(_ body: () -> T) -> T {
        if DispatchQueue.getSpecific(key: managedSettingsQueueKey) != nil {
            return body()
        }
        return managedSettingsQueue.sync(execute: body)
    }

    private func synchronized<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    private enum ResolveResult {
        case resolved(ResolvedSettingsSnapshot)
        /// The active file exists but could not be parsed. An invalid primary never falls
        /// through to the fallback file.
        case invalid(path: String, message: String)
    }

    private func resolveSettings() -> ResolveResult {
        switch loadSettings(at: primaryPath) {
        case .parsed(let snapshot):
            return .resolved(snapshot)
        case .invalid(let message):
            return .invalid(path: primaryPath, message: message)
        case .missing:
            break
        }

        guard let fallbackPath else {
            return .resolved(ResolvedSettingsSnapshot(path: nil))
        }

        switch loadSettings(at: fallbackPath) {
        case .parsed(let snapshot):
            return .resolved(snapshot)
        case .invalid(let message):
            return .invalid(path: fallbackPath, message: message)
        case .missing:
            return .resolved(ResolvedSettingsSnapshot(path: nil))
        }
    }

    private enum LoadResult {
        case missing
        case invalid(String)
        case parsed(ResolvedSettingsSnapshot)
    }

    private func loadSettings(at path: String) -> LoadResult {
        guard fileManager.fileExists(atPath: path) else {
            return .missing
        }
        guard let data = fileManager.contents(atPath: path), !data.isEmpty else {
            return .invalid("the file is empty")
        }

        do {
            let sanitized = try JSONCParser.preprocess(data: data)
            let object = try JSONSerialization.jsonObject(with: sanitized, options: [])
            guard let root = object as? [String: Any] else {
                return .invalid("the top level is not a JSON object")
            }
            return .parsed(parseSettingsFile(root: root, sourcePath: path))
        } catch {
            NSLog("[ProgramaSettingsFileStore] parse error at %@: %@", path, String(describing: error))
            return .invalid((error as NSError).localizedDescription)
        }
    }

    private func parseSettingsFile(root: [String: Any], sourcePath: String) -> ResolvedSettingsSnapshot {
        let schemaVersion = jsonInt(root["schemaVersion"]) ?? 1
        if schemaVersion > Self.currentSchemaVersion {
            NSLog(
                "[ProgramaSettingsFileStore] %@ uses future schemaVersion %d; parsing known fields only",
                sourcePath,
                schemaVersion
            )
        }

        var snapshot = ResolvedSettingsSnapshot(path: sourcePath)

        if let appSection = root["app"] as? [String: Any] {
            parseAppSection(appSection, sourcePath: sourcePath, snapshot: &snapshot)
        }
        if let notificationsSection = root["notifications"] as? [String: Any] {
            parseNotificationsSection(notificationsSection, sourcePath: sourcePath, snapshot: &snapshot)
        }
        if let sidebarAppearanceSection = root["sidebarAppearance"] as? [String: Any] {
            parseSidebarAppearanceSection(sidebarAppearanceSection, sourcePath: sourcePath, snapshot: &snapshot)
        }
        if let automationSection = root["automation"] as? [String: Any] {
            parseAutomationSection(automationSection, sourcePath: sourcePath, snapshot: &snapshot)
        }
        if let customCommandsSection = root["customCommands"] as? [String: Any] {
            parseCustomCommandsSection(customCommandsSection, sourcePath: sourcePath, snapshot: &snapshot)
        }
        if let browserSection = root["browser"] as? [String: Any] {
            if let values = jsonStringArray(browserSection["externalAppOpenAllowlist"]) {
                let normalized = values
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                snapshot.managedUserDefaults[ExternalOpenPolicy.allowlistKey] = .string(
                    normalized.joined(separator: "\n")
                )
            } else if browserSection.keys.contains("externalAppOpenAllowlist") {
                logInvalid("browser.externalAppOpenAllowlist", sourcePath: sourcePath)
            }
        }
        if let shortcutsSection = root["shortcuts"] {
            parseShortcutsSection(shortcutsSection, sourcePath: sourcePath, snapshot: &snapshot)
        }

        return snapshot
    }

    private func parseAppSection(
        _ section: [String: Any],
        sourcePath: String,
        snapshot: inout ResolvedSettingsSnapshot
    ) {
        if let raw = jsonString(section["appearance"]) {
            let normalized = AppearanceSettings.mode(for: raw).rawValue
            let accepted = Set(AppearanceMode.allCases.map(\.rawValue))
            if accepted.contains(raw) {
                snapshot.managedUserDefaults[AppearanceSettings.appearanceModeKey] = .string(normalized)
            } else {
                logInvalid("app.appearance", sourcePath: sourcePath)
            }
        }
        if let raw = jsonString(section["newWorkspacePlacement"]) {
            if let placement = NewWorkspacePlacement(rawValue: raw) {
                snapshot.managedUserDefaults[WorkspacePlacementSettings.placementKey] = .string(placement.rawValue)
            } else {
                logInvalid("app.newWorkspacePlacement", sourcePath: sourcePath)
            }
        }
        if let value = jsonBool(section["minimalMode"]) {
            let mode = value ? WorkspacePresentationModeSettings.Mode.minimal : .standard
            snapshot.managedUserDefaults[WorkspacePresentationModeSettings.modeKey] = .string(mode.rawValue)
        }
        if let value = jsonBool(section["warnBeforeQuit"]) {
            snapshot.managedUserDefaults[QuitWarningSettings.warnBeforeQuitKey] = .bool(value)
        }
        if let value = jsonBool(section["commandPaletteSearchesAllSurfaces"]) {
            snapshot.managedUserDefaults[CommandPaletteSwitcherSearchSettings.searchAllSurfacesKey] = .bool(value)
        }
        if let rawTerminalTheme = section["terminalTheme"] {
            if rawTerminalTheme is NSNull {
                snapshot.managedCustomSettings.terminalTheme = ManagedTerminalTheme(light: nil, dark: nil)
            } else if let terminalTheme = rawTerminalTheme as? [String: Any] {
                let light = parseTerminalThemeName(
                    terminalTheme["light"],
                    path: "app.terminalTheme.light",
                    sourcePath: sourcePath
                )
                let dark = parseTerminalThemeName(
                    terminalTheme["dark"],
                    path: "app.terminalTheme.dark",
                    sourcePath: sourcePath
                )
                if light.isValid && dark.isValid {
                    snapshot.managedCustomSettings.terminalTheme = ManagedTerminalTheme(
                        light: light.value,
                        dark: dark.value
                    )
                }
            } else {
                logInvalid("app.terminalTheme", sourcePath: sourcePath)
            }
        }
        if let rawTerminalFont = section["terminalFont"] {
            if rawTerminalFont is NSNull {
                snapshot.managedCustomSettings.terminalFont = ManagedTerminalFont(family: nil, size: nil)
            } else if let terminalFont = rawTerminalFont as? [String: Any] {
                let family = jsonString(terminalFont["family"])?.trimmingCharacters(in: .whitespacesAndNewlines)
                let size = jsonDouble(terminalFont["size"])
                if let family, !family.isEmpty, let size, size > 0 {
                    snapshot.managedCustomSettings.terminalFont = ManagedTerminalFont(family: family, size: size)
                } else {
                    logInvalid("app.terminalFont", sourcePath: sourcePath)
                }
            } else {
                logInvalid("app.terminalFont", sourcePath: sourcePath)
            }
        }
    }

    private func parseTerminalThemeName(
        _ rawValue: Any?,
        path: String,
        sourcePath: String
    ) -> (isValid: Bool, value: String?) {
        guard let rawValue else { return (true, nil) }
        if rawValue is NSNull { return (true, nil) }
        guard let string = rawValue as? String else {
            logInvalid(path, sourcePath: sourcePath)
            return (false, nil)
        }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            logInvalid(path, sourcePath: sourcePath)
            return (false, nil)
        }
        return (true, trimmed)
    }

    private func parseNotificationsSection(
        _ section: [String: Any],
        sourcePath: String,
        snapshot: inout ResolvedSettingsSnapshot
    ) {
        if let value = jsonBool(section["showInMenuBar"]) {
            snapshot.managedUserDefaults[MenuBarExtraSettings.showInMenuBarKey] = .bool(value)
        }
        if let raw = jsonString(section["sound"]) {
            let allowed = Set(NotificationSoundSettings.systemSounds.map(\.value))
            if allowed.contains(raw) {
                snapshot.managedUserDefaults[NotificationSoundSettings.key] = .string(raw)
            } else {
                logInvalid("notifications.sound", sourcePath: sourcePath)
            }
        }
    }


    private func parseSidebarAppearanceSection(
        _ section: [String: Any],
        sourcePath: String,
        snapshot: inout ResolvedSettingsSnapshot
    ) {
        if let value = jsonBool(section["matchTerminalBackground"]) {
            snapshot.managedUserDefaults["sidebarMatchTerminalBackground"] = .bool(value)
        }
        if let value = jsonBool(section["showClaudeQuota"]) {
            snapshot.managedUserDefaults["sidebarShowClaudeQuota"] = .bool(value)
        }
    }

    private func parseAutomationSection(
        _ section: [String: Any],
        sourcePath: String,
        snapshot: inout ResolvedSettingsSnapshot
    ) {
        if let raw = jsonString(section["socketControlMode"]) {
            let knownModes = Set([
                "off", "programaonly", "automation", "password", "allowall", "openaccess", "fullopenaccess",
                "notifications", "full",
            ])
            let normalizedRaw = raw.replacingOccurrences(of: "-", with: "").lowercased()
            if knownModes.contains(normalizedRaw) {
                snapshot.managedUserDefaults[SocketControlSettings.appStorageKey] = .string(
                    SocketControlSettings.migrateMode(raw).rawValue
                )
            } else {
                logInvalid("automation.socketControlMode", sourcePath: sourcePath)
            }
        }
        if section.keys.contains("socketPassword") {
            if section["socketPassword"] is NSNull {
                snapshot.managedCustomSettings.socketPassword = .clear
            } else if let raw = jsonString(section["socketPassword"]) {
                snapshot.managedCustomSettings.socketPassword = raw.isEmpty ? .clear : .set(raw)
            } else {
                logInvalid("automation.socketPassword", sourcePath: sourcePath)
            }
        }
        if let value = jsonBool(section["claudeCodeIntegration"]) {
            snapshot.managedUserDefaults[ClaudeCodeIntegrationSettings.hooksEnabledKey] = .bool(value)
        }
    }

    private func parseCustomCommandsSection(
        _ section: [String: Any],
        sourcePath: String,
        snapshot: inout ResolvedSettingsSnapshot
    ) {
        if let values = jsonStringArray(section["trustedDirectories"]) {
            let normalized = values
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            snapshot.managedCustomSettings.trustedDirectories = normalized
        } else if section.keys.contains("trustedDirectories") {
            logInvalid("customCommands.trustedDirectories", sourcePath: sourcePath)
        }
    }

    private func parseShortcutsSection(
        _ value: Any,
        sourcePath: String,
        snapshot: inout ResolvedSettingsSnapshot
    ) {
        guard let section = value as? [String: Any] else {
            logInvalid("shortcuts", sourcePath: sourcePath)
            return
        }

        var bindings = section["bindings"] as? [String: Any] ?? [:]
        for (key, rawValue) in section where key != "bindings" {
            bindings[key] = rawValue
        }

        for (rawAction, rawBinding) in bindings {
            guard let action = KeyboardShortcutSettings.Action(rawValue: rawAction) else {
                NSLog("[ProgramaSettingsFileStore] ignoring unknown shortcut action '%@' in %@", rawAction, sourcePath)
                continue
            }
            guard let shortcut = parseShortcutBindingValue(rawBinding, action: action) else {
                NSLog(
                    "[ProgramaSettingsFileStore] ignoring invalid shortcut binding for '%@' in %@",
                    rawAction,
                    sourcePath
                )
                continue
            }
            snapshot.shortcuts[action] = shortcut
        }
    }

    private func parseShortcutBindingValue(
        _ rawValue: Any,
        action: KeyboardShortcutSettings.Action
    ) -> StoredShortcut? {
        let shortcut: StoredShortcut?
        if let stroke = jsonString(rawValue) {
            shortcut = parseStoredShortcut(strokes: [stroke])
        } else if let strokes = jsonStringArray(rawValue) {
            shortcut = parseStoredShortcut(strokes: strokes)
        } else {
            shortcut = nil
        }

        guard let shortcut else { return nil }
        if let normalized = action.normalizedRecordedShortcut(shortcut) {
            return normalized
        }
        return action.usesNumberedDigitMatching ? nil : shortcut
    }

    private func parseStoredShortcut(strokes: [String]) -> StoredShortcut? {
        guard !strokes.isEmpty, strokes.count <= 2 else { return nil }
        let parsedStrokes = strokes.compactMap(parseStroke(_:))
        guard parsedStrokes.count == strokes.count, let firstStroke = parsedStrokes.first else {
            return nil
        }
        guard !firstStroke.modifierFlags.isEmpty else { return nil }
        let secondStroke = parsedStrokes.count == 2 ? parsedStrokes[1] : nil
        return StoredShortcut(first: firstStroke, second: secondStroke)
    }

    private func parseStroke(_ rawValue: String) -> ShortcutStroke? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let parts = trimmed.split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !parts.isEmpty, let lastPart = parts.last, !lastPart.isEmpty else {
            return nil
        }

        var command = false
        var shift = false
        var option = false
        var control = false

        for modifier in parts.dropLast() {
            switch modifier.lowercased() {
            case "cmd", "command", "⌘":
                command = true
            case "shift", "⇧":
                shift = true
            case "opt", "option", "alt", "⌥":
                option = true
            case "ctrl", "control", "ctl", "⌃":
                control = true
            default:
                return nil
            }
        }

        guard let key = parseKeyToken(lastPart) else { return nil }
        return ShortcutStroke(
            key: key,
            command: command,
            shift: shift,
            option: option,
            control: control
        )
    }

    private func parseKeyToken(_ rawValue: String) -> String? {
        let lowered = rawValue.lowercased()
        switch lowered {
        case "left", "arrowleft", "leftarrow", "←":
            return "←"
        case "right", "arrowright", "rightarrow", "→":
            return "→"
        case "up", "arrowup", "uparrow", "↑":
            return "↑"
        case "down", "arrowdown", "downarrow", "↓":
            return "↓"
        case "tab":
            return "\t"
        case "return", "enter", "↩":
            return "\r"
        case "space":
            return " "
        case "comma":
            return ","
        case "period", "dot":
            return "."
        case "slash":
            return "/"
        case "backslash":
            return "\\"
        case "semicolon":
            return ";"
        case "quote", "apostrophe":
            return "'"
        case "backtick", "grave":
            return "`"
        case "minus", "hyphen":
            return "-"
        case "plus", "equals":
            return "="
        case "leftbracket", "openbracket":
            return "["
        case "rightbracket", "closebracket":
            return "]"
        default:
            guard lowered.count == 1 else { return nil }
            return lowered
        }
    }

    private func applyManagedSettings(
        snapshot: ResolvedSettingsSnapshot,
        updateBackups: Bool = true
    ) {
        var backups = loadBackups()
        let currentManagedIdentifiers = Set(backups.keys)
        let nextManagedIdentifiers = Set(snapshot.managedUserDefaults.keys)
            .union(snapshot.managedCustomSettings.managedIdentifiers)

        synchronized {
            isApplyingManagedSettings = true
        }
        defer {
            synchronized {
                isApplyingManagedSettings = false
            }
        }

        if updateBackups {
            for (defaultsKey, value) in snapshot.managedUserDefaults where backups[defaultsKey] == nil {
                backups[defaultsKey] = backupValueForUserDefaultsKey(defaultsKey, managedValue: value)
            }
            if snapshot.managedCustomSettings.trustedDirectories != nil,
               backups[Self.trustedDirectoriesBackupIdentifier] == nil {
                backups[Self.trustedDirectoriesBackupIdentifier] = .stringArray(ProgramaDirectoryTrust.shared.allTrustedPaths)
            }
            if snapshot.managedCustomSettings.socketPassword != nil,
               backups[Self.socketPasswordBackupIdentifier] == nil {
                backups[Self.socketPasswordBackupIdentifier] = currentSocketPasswordBackupValue()
            }
            if snapshot.managedCustomSettings.terminalTheme != nil,
               backups[Self.terminalThemeBackupIdentifier] == nil {
                backups[Self.terminalThemeBackupIdentifier] = currentTerminalThemeBackupValue()
            }
            if snapshot.managedCustomSettings.terminalFont != nil,
               backups[Self.terminalFontBackupIdentifier] == nil {
                backups[Self.terminalFontBackupIdentifier] = currentTerminalFontBackupValue()
            }
        }

        for identifier in currentManagedIdentifiers.subtracting(nextManagedIdentifiers) {
            guard let backup = backups[identifier] else { continue }
            restoreBackup(backup, for: identifier)
            backups.removeValue(forKey: identifier)
        }

        for (defaultsKey, value) in snapshot.managedUserDefaults {
            applyManagedUserDefaultsValue(value, for: defaultsKey)
        }
        applyManagedCustomSettings(snapshot.managedCustomSettings)

        if updateBackups {
            saveBackups(backups)
        }
    }

    private func applyManagedCustomSettings(_ settings: ManagedCustomSettings) {
        // `replaceAll` keeps the digests of roots that stay and is a no-op when the set is
        // unchanged, so a reapply never wipes per-config trust digests.
        if let trustedDirectories = settings.trustedDirectories {
            ProgramaDirectoryTrust.shared.replaceAll(with: trustedDirectories)
        }

        if let socketPassword = settings.socketPassword {
            switch socketPassword {
            case .set(let value):
                let current = (try? SocketControlPasswordStore.loadPassword()) ?? nil
                if current != value {
                    try? SocketControlPasswordStore.savePassword(value)
                }
            case .clear:
                let current = (try? SocketControlPasswordStore.loadPassword()) ?? nil
                if current != nil {
                    try? SocketControlPasswordStore.clearPassword()
                }
            }
        }

        if let terminalTheme = settings.terminalTheme {
            applyTerminalTheme(light: terminalTheme.light, dark: terminalTheme.dark)
        }
        if let terminalFont = settings.terminalFont {
            applyTerminalFont(family: terminalFont.family, size: terminalFont.size)
        }
    }

    private func restoreBackup(_ backup: BackupValue, for identifier: String) {
        switch identifier {
        case Self.trustedDirectoriesBackupIdentifier:
            if case .stringArray(let values) = backup {
                ProgramaDirectoryTrust.shared.replaceAll(with: values)
            } else {
                ProgramaDirectoryTrust.shared.replaceAll(with: [])
            }
        case Self.socketPasswordBackupIdentifier:
            switch backup {
            case .string(let value):
                try? SocketControlPasswordStore.savePassword(value)
            case .absent:
                try? SocketControlPasswordStore.clearPassword()
            default:
                break
            }
        case Self.terminalThemeBackupIdentifier:
            do {
                let mutation: TerminalThemeMutation
                switch backup {
                case .string(let rawValue):
                    mutation = try terminalThemeStore.set(rawThemeValue: rawValue)
                case .absent:
                    mutation = try terminalThemeStore.clear()
                default:
                    return
                }
                if mutation.didChange {
                    terminalThemeReloadHandler()
                }
            } catch {
                NSLog(
                    "[ProgramaSettingsFileStore] failed to restore terminal theme: %@",
                    String(describing: error)
                )
            }
        case Self.terminalOpacityBackupIdentifier:
            do {
                let mutation: TerminalThemeMutation
                switch backup {
                case .double(let value):
                    mutation = try terminalThemeStore.set(rawAppearanceValue: String(value), forKey: "background-opacity")
                case .absent:
                    mutation = try terminalThemeStore.set(rawAppearanceValue: "", forKey: "background-opacity")
                default:
                    return
                }
                if mutation.didChange {
                    terminalThemeReloadHandler()
                }
            } catch {
                NSLog(
                    "[ProgramaSettingsFileStore] failed to restore terminal opacity: %@",
                    String(describing: error)
                )
            }
        case Self.terminalBlurBackupIdentifier:
            do {
                let mutation: TerminalThemeMutation
                switch backup {
                case .bool(let value):
                    mutation = try terminalThemeStore.set(rawAppearanceValue: value ? "true" : "false", forKey: "background-blur")
                case .absent:
                    mutation = try terminalThemeStore.set(rawAppearanceValue: "", forKey: "background-blur")
                default:
                    return
                }
                if mutation.didChange {
                    terminalThemeReloadHandler()
                }
            } catch {
                NSLog(
                    "[ProgramaSettingsFileStore] failed to restore terminal blur: %@",
                    String(describing: error)
                )
            }
        case Self.terminalFontBackupIdentifier:
            do {
                let mutation: TerminalThemeMutation
                switch backup {
                case .stringDictionary(let values):
                    mutation = try terminalThemeStore.set(rawAppearanceValues: [
                        "font-family": values["family"],
                        "font-size": values["size"],
                    ])
                case .absent:
                    mutation = try terminalThemeStore.set(rawAppearanceValues: [
                        "font-family": nil,
                        "font-size": nil,
                    ])
                default:
                    return
                }
                if mutation.didChange {
                    terminalThemeReloadHandler()
                }
            } catch {
                NSLog(
                    "[ProgramaSettingsFileStore] failed to restore terminal font: %@",
                    String(describing: error)
                )
            }
        default:
            restoreUserDefaultsBackup(backup, for: identifier)
        }
    }

    private func backupValueForUserDefaultsKey(_ defaultsKey: String, managedValue: ManagedSettingsValue) -> BackupValue {
        let defaults = UserDefaults.standard
        switch managedValue {
        case .bool:
            guard defaults.object(forKey: defaultsKey) != nil else { return .absent }
            return .bool(defaults.bool(forKey: defaultsKey))
        case .string:
            guard let value = defaults.string(forKey: defaultsKey) else { return .absent }
            return .string(value)
        case .stringArray:
            guard let value = defaults.array(forKey: defaultsKey) as? [String] else { return .absent }
            return .stringArray(value)
        }
    }

    private func currentSocketPasswordBackupValue() -> BackupValue {
        guard let current = try? SocketControlPasswordStore.loadPassword() else {
            return .absent
        }
        return .string(current)
    }

    private func currentTerminalThemeBackupValue() -> BackupValue {
        guard let rawValue = terminalThemeStore.managedRawThemeValue() else {
            return .absent
        }
        return .string(rawValue)
    }

    private func currentTerminalFontBackupValue() -> BackupValue {
        let appearance = terminalThemeStore.managedRawAppearance()
        guard let family = appearance.fontFamily, let size = appearance.fontSize else {
            return .absent
        }
        return .stringDictionary(["family": family, "size": String(size)])
    }

    private func applyTerminalTheme(light: String?, dark: String?) {
        do {
            // Surgical single-key write: preserves any independently-managed opacity/blur/font
            // directives already present in the block.
            let rawValue = TerminalThemeStore.encodedThemeValue(light: light, dark: dark) ?? ""
            let mutation = try terminalThemeStore.set(rawAppearanceValue: rawValue, forKey: "theme")
            if mutation.didChange {
                terminalThemeReloadHandler()
            }
        } catch {
            NSLog(
                "[ProgramaSettingsFileStore] failed to apply terminal theme: %@",
                String(describing: error)
            )
        }
    }

    private func applyTerminalFont(family: String?, size: Double?) {
        do {
            let mutation = try terminalThemeStore.set(rawAppearanceValues: [
                "font-family": family,
                "font-size": size.map { String($0) },
            ])
            if mutation.didChange {
                terminalThemeReloadHandler()
            }
        } catch {
            NSLog(
                "[ProgramaSettingsFileStore] failed to apply terminal font: %@",
                String(describing: error)
            )
        }
    }

    private func applyManagedUserDefaultsValue(_ value: ManagedSettingsValue, for defaultsKey: String) {
        let defaults = UserDefaults.standard
        switch value {
        case .bool(let next):
            let current = defaults.object(forKey: defaultsKey) as? Bool
            if current != next {
                defaults.set(next, forKey: defaultsKey)
            }
        case .string(let next):
            let current = defaults.string(forKey: defaultsKey)
            if current != next {
                defaults.set(next, forKey: defaultsKey)
            }
        case .stringArray(let next):
            let current = defaults.array(forKey: defaultsKey) as? [String]
            if current != next {
                defaults.set(next, forKey: defaultsKey)
            }
        }
    }

    private func restoreUserDefaultsBackup(_ backup: BackupValue, for defaultsKey: String) {
        let defaults = UserDefaults.standard
        switch backup {
        case .absent:
            defaults.removeObject(forKey: defaultsKey)
        case .bool(let value):
            defaults.set(value, forKey: defaultsKey)
        case .int(let value):
            defaults.set(value, forKey: defaultsKey)
        case .double(let value):
            defaults.set(value, forKey: defaultsKey)
        case .string(let value):
            defaults.set(value, forKey: defaultsKey)
        case .stringArray(let value):
            defaults.set(value, forKey: defaultsKey)
        case .stringDictionary(let value):
            defaults.set(value, forKey: defaultsKey)
        }
    }

    private func loadBackups() -> [String: BackupValue] {
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: Self.backupsDefaultsKey),
              let backups = try? JSONDecoder().decode([String: BackupValue].self, from: data) else {
            return [:]
        }
        return backups
    }

    private func saveBackups(_ backups: [String: BackupValue]) {
        let defaults = UserDefaults.standard
        if backups.isEmpty {
            defaults.removeObject(forKey: Self.backupsDefaultsKey)
            return
        }
        guard let data = try? JSONEncoder().encode(backups) else { return }
        defaults.set(data, forKey: Self.backupsDefaultsKey)
    }

    private func logInvalid(_ path: String, sourcePath: String) {
        NSLog("[ProgramaSettingsFileStore] ignoring invalid setting '%@' in %@", path, sourcePath)
    }

    private func jsonString(_ rawValue: Any?) -> String? {
        rawValue as? String
    }

    private func jsonBool(_ rawValue: Any?) -> Bool? {
        guard let number = rawValue as? NSNumber else { return nil }
        guard CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private func jsonInt(_ rawValue: Any?) -> Int? {
        guard let number = rawValue as? NSNumber else { return nil }
        guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let doubleValue = number.doubleValue
        guard doubleValue.rounded() == doubleValue else { return nil }
        return number.intValue
    }

    private func jsonDouble(_ rawValue: Any?) -> Double? {
        guard let number = rawValue as? NSNumber else { return nil }
        guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue
    }

    private func jsonStringArray(_ rawValue: Any?) -> [String]? {
        guard let values = rawValue as? [Any] else { return nil }
        var strings: [String] = []
        strings.reserveCapacity(values.count)
        for value in values {
            guard let string = value as? String else { return nil }
            strings.append(string)
        }
        return strings
    }

    static func defaultTemplate() -> String {
        var lines: [String] = [
            "{",
            "  \"$schema\": \"\(schemaURLString)\",",
            "  \"schemaVersion\": \(currentSchemaVersion),",
            "",
            "  // This file uses JSON with comments (JSONC).",
            "  // Uncomment and edit any setting to make it file-managed.",
            "  // Remove a setting to fall back to the value saved in Settings.",
            "  // Programa creates this template on launch when both settings file locations are missing.",
            "  // ~/.config/programa/settings.json takes precedence over the Application Support fallback.",
            "",
        ]

        let sections = defaultTemplateSections()
        for (index, section) in sections.enumerated() {
            lines.append(contentsOf: commentedTemplateLines(for: section))
            if index < sections.count - 1 {
                lines.append("")
            }
        }

        lines.append("}")
        return lines.joined(separator: "\n") + "\n"
    }

    private static func commentedTemplateLines(for section: [String: Any]) -> [String] {
        let json = prettyJSONString(section)
        let sectionLines = json
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard sectionLines.count >= 2 else { return [] }

        return sectionLines
            .dropFirst()
            .dropLast()
            .enumerated()
            .map { index, line in
                if index == sectionLines.count - 3 {
                    return "  // \(line),"
                }
                return "  // \(line)"
            }
    }

    private static func defaultTemplateSections() -> [[String: Any]] {
        let shortcutsBindings = Dictionary(
            uniqueKeysWithValues: KeyboardShortcutSettings.Action.allCases.map { action in
                (action.rawValue, shortcutTemplateValue(action.defaultShortcut, usesNumberedDigits: action.usesNumberedDigitMatching))
            }
        )

        return [
            [
                "app": [
                    "appearance": AppearanceSettings.defaultMode.rawValue,
                    "terminalTheme": [
                        "light": NSNull(),
                        "dark": NSNull(),
                    ],
                    "terminalFont": NSNull(),
                    "newWorkspacePlacement": WorkspacePlacementSettings.defaultPlacement.rawValue,
                    "minimalMode": WorkspacePresentationModeSettings.defaultMode == .minimal,
                    "warnBeforeQuit": QuitWarningSettings.defaultWarnBeforeQuit,
                    "commandPaletteSearchesAllSurfaces": CommandPaletteSwitcherSearchSettings.defaultSearchAllSurfaces,
                ],
            ],
            [
                "notifications": [
                    "showInMenuBar": MenuBarExtraSettings.defaultShowInMenuBar,
                    "sound": NotificationSoundSettings.defaultValue,
                ],
            ],
            [
                "sidebarAppearance": [
                    "matchTerminalBackground": false,
                ],
            ],
            [
                "automation": [
                    "socketControlMode": SocketControlSettings.defaultMode.rawValue,
                    "socketPassword": "",
                    "claudeCodeIntegration": ClaudeCodeIntegrationSettings.defaultHooksEnabled,
                ],
            ],
            [
                "customCommands": [
                    "trustedDirectories": [String](),
                ],
            ],
            [
                "browser": [
                    "externalAppOpenAllowlist": [String](),
                ],
            ],
            [
                "shortcuts": [
                    "bindings": shortcutsBindings,
                ],
            ],
        ]
    }

    private static func shortcutTemplateValue(
        _ shortcut: StoredShortcut,
        usesNumberedDigits: Bool
    ) -> Any {
        let defaultShortcut = usesNumberedDigits ? (shortcut.secondStroke ?? shortcut.firstStroke) : nil
        let rendered = renderShortcutStroke(shortcut.firstStroke, preserveDigit: !usesNumberedDigits)
        if let secondStroke = shortcut.secondStroke {
            return [rendered, renderShortcutStroke(secondStroke, preserveDigit: true)]
        }
        if let defaultShortcut {
            return renderShortcutStroke(defaultShortcut, preserveDigit: true)
        }
        return rendered
    }

    private static func renderShortcutStroke(_ stroke: ShortcutStroke, preserveDigit: Bool) -> String {
        var parts: [String] = []
        if stroke.command { parts.append("cmd") }
        if stroke.shift { parts.append("shift") }
        if stroke.option { parts.append("opt") }
        if stroke.control { parts.append("ctrl") }
        parts.append(renderShortcutKey(stroke.key, preserveDigit: preserveDigit))
        return parts.joined(separator: "+")
    }

    private static func renderShortcutKey(_ key: String, preserveDigit: Bool) -> String {
        switch key {
        case "\r": return "return"
        case "\t": return "tab"
        case " ": return "space"
        default: break
        }
        if preserveDigit {
            return key
        }
        return key
    }

    private static func prettyJSONString(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }
}

typealias KeyboardShortcutSettingsFileStore = ProgramaSettingsFileStore

private struct ResolvedSettingsSnapshot {
    var path: String?
    var shortcuts: [KeyboardShortcutSettings.Action: StoredShortcut] = [:]
    var managedUserDefaults: [String: ManagedSettingsValue] = [:]
    var managedCustomSettings = ManagedCustomSettings()
}

private enum ManagedStringOverride: Equatable {
    case set(String)
    case clear
}

private struct ManagedTerminalTheme: Equatable {
    let light: String?
    let dark: String?
}

private struct ManagedTerminalFont: Equatable {
    let family: String?
    let size: Double?
}

private struct ManagedCustomSettings: Equatable {
    var trustedDirectories: [String]?
    var socketPassword: ManagedStringOverride?
    var terminalTheme: ManagedTerminalTheme?
    var terminalFont: ManagedTerminalFont?

    var isEmpty: Bool {
        trustedDirectories == nil && socketPassword == nil && terminalTheme == nil && terminalFont == nil
    }

    var managedIdentifiers: Set<String> {
        var identifiers: Set<String> = []
        if trustedDirectories != nil {
            identifiers.insert(ProgramaSettingsFileStore.trustedDirectoriesBackupIdentifier)
        }
        if socketPassword != nil {
            identifiers.insert(ProgramaSettingsFileStore.socketPasswordBackupIdentifier)
        }
        if terminalTheme != nil {
            identifiers.insert(ProgramaSettingsFileStore.terminalThemeBackupIdentifier)
        }
        if terminalFont != nil {
            identifiers.insert(ProgramaSettingsFileStore.terminalFontBackupIdentifier)
        }
        return identifiers
    }
}

private enum ManagedSettingsValue: Equatable {
    case bool(Bool)
    case string(String)
    case stringArray([String])
}

private enum BackupValue: Codable, Equatable {
    case absent
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case stringArray([String])
    case stringDictionary([String: String])

    private enum Kind: String, Codable {
        case absent
        case bool
        case int
        case double
        case string
        case stringArray
        case stringDictionary
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case boolValue
        case intValue
        case doubleValue
        case stringValue
        case stringArrayValue
        case stringDictionaryValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .absent:
            self = .absent
        case .bool:
            self = .bool(try container.decode(Bool.self, forKey: .boolValue))
        case .int:
            self = .int(try container.decode(Int.self, forKey: .intValue))
        case .double:
            self = .double(try container.decode(Double.self, forKey: .doubleValue))
        case .string:
            self = .string(try container.decode(String.self, forKey: .stringValue))
        case .stringArray:
            self = .stringArray(try container.decode([String].self, forKey: .stringArrayValue))
        case .stringDictionary:
            self = .stringDictionary(try container.decode([String: String].self, forKey: .stringDictionaryValue))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .absent:
            try container.encode(Kind.absent, forKey: .kind)
        case .bool(let value):
            try container.encode(Kind.bool, forKey: .kind)
            try container.encode(value, forKey: .boolValue)
        case .int(let value):
            try container.encode(Kind.int, forKey: .kind)
            try container.encode(value, forKey: .intValue)
        case .double(let value):
            try container.encode(Kind.double, forKey: .kind)
            try container.encode(value, forKey: .doubleValue)
        case .string(let value):
            try container.encode(Kind.string, forKey: .kind)
            try container.encode(value, forKey: .stringValue)
        case .stringArray(let value):
            try container.encode(Kind.stringArray, forKey: .kind)
            try container.encode(value, forKey: .stringArrayValue)
        case .stringDictionary(let value):
            try container.encode(Kind.stringDictionary, forKey: .kind)
            try container.encode(value, forKey: .stringDictionaryValue)
        }
    }
}

// JSONCParser (comments + trailing-comma stripping) now lives in Sources/JSONCParser.swift,
// shared with ProgramaConfigStore's programa.json parsing.

// NOTE (drift, refs #100): unlike ProgramaConfigStore's local/global config watchers, this
// watcher has no delayed retry/backoff at all — on delete/rename it re-evaluates and
// reattaches (or falls back to directory watching) immediately, synchronously, on the watch
// queue. That immediate-reattach behavior is preserved as-is; only the raw DispatchSource
// open/create/resume/cancel plumbing is shared via `FileWatcher`.
private final class ShortcutSettingsFileWatcher {
    private static let reloadCoalescingDelay: TimeInterval = 0.15

    private let path: String
    private let fileManager: FileManager
    private let onChange: () -> Void
    private let watcher: FileWatcher
    private let pendingReloadLock = NSLock()
    private var pendingReloadWorkItem: DispatchWorkItem?

    init(path: String, fileManager: FileManager = .default, onChange: @escaping () -> Void) {
        self.path = path
        self.fileManager = fileManager
        self.onChange = onChange
        self.watcher = FileWatcher(queue: DispatchQueue(label: "com.darkroom.programa.shortcut-settings-file-watch"))
        start()
    }

    deinit {
        cancelPendingReload()
    }

    func stop() {
        watcher.stop()
        cancelPendingReload()
    }

    private func cancelPendingReload() {
        pendingReloadLock.lock()
        pendingReloadWorkItem?.cancel()
        pendingReloadWorkItem = nil
        pendingReloadLock.unlock()
    }

    private func start() {
        if fileManager.fileExists(atPath: path) {
            startFileWatcher()
        } else {
            startDirectoryWatcher()
        }
    }

    private func startFileWatcher() {
        let started = watcher.start(
            path: path,
            eventMask: [.write, .delete, .rename, .extend]
        ) { [weak self] flags in
            guard let self else { return }
            if flags.contains(.delete) || flags.contains(.rename) {
                self.start()
            }
            self.scheduleReload()
        }
        if !started {
            startDirectoryWatcher()
        }
    }

    private func startDirectoryWatcher() {
        let directoryPath = (path as NSString).deletingLastPathComponent
        watcher.start(
            path: directoryPath,
            eventMask: [.write, .rename, .delete]
        ) { [weak self] _ in
            guard let self else { return }
            if self.fileManager.fileExists(atPath: self.path) {
                self.start()
            }
            self.scheduleReload()
        }
    }

    private func scheduleReload() {
        let workItem = DispatchWorkItem { [weak self] in
            self?.onChange()
        }
        pendingReloadLock.lock()
        pendingReloadWorkItem?.cancel()
        pendingReloadWorkItem = workItem
        pendingReloadLock.unlock()
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.reloadCoalescingDelay,
            execute: workItem
        )
    }
}
