import Foundation
import Darwin

struct TerminalThemeSelection: Equatable {
    let rawValue: String?
    let light: String?
    let dark: String?
    let sourcePath: String?
}

struct TerminalThemeMutation: Equatable {
    let configURL: URL
    let didChange: Bool
}

/// Overrides tracked in Programa's managed config block. Each field maps to one Ghostty
/// config directive (`theme`, `background-opacity`, `background-blur`, `font-family`,
/// `font-size`) and is independently nil-able so callers can read/write a subset of keys
/// without disturbing the others.
struct TerminalAppearanceOverrides: Equatable {
    var themeLight: String?
    var themeDark: String?
    var backgroundOpacity: Double?
    /// `nil` = inherit (no directive written); `.some(true)`/`.some(false)` = explicit on/off,
    /// both written verbatim. `false` is not the same as `nil` — see `set(_:)`.
    var backgroundBlur: Bool?
    var fontFamily: String?
    var fontSize: Double?

    init(
        themeLight: String? = nil,
        themeDark: String? = nil,
        backgroundOpacity: Double? = nil,
        backgroundBlur: Bool? = nil,
        fontFamily: String? = nil,
        fontSize: Double? = nil
    ) {
        self.themeLight = themeLight
        self.themeDark = themeDark
        self.backgroundOpacity = backgroundOpacity
        self.backgroundBlur = backgroundBlur
        self.fontFamily = fontFamily
        self.fontSize = fontSize
    }
}

/// Owns Programa's managed config block so the app and CLI cannot drift.
///
/// User Ghostty configuration remains untouched. Programa only replaces the block delimited by
/// `managedBlockStart`/`managedBlockEnd` in its Application Support config and preserves every
/// unrelated directive in that file. The block can hold up to five directives (theme,
/// background-opacity, background-blur, font-family, font-size), each independently settable.
struct TerminalThemeStore {
    static let overrideBundleIdentifier = "com.darkroom.programa"
    static let managedBlockStart = "# programa themes start"
    static let managedBlockEnd = "# programa themes end"
    static let reloadNotificationName = "com.darkroom.programa.themes.reload-config"

    /// Fixed write order for directives inside the managed block.
    private static let orderedDirectiveKeys = [
        "theme",
        "background-opacity",
        "background-blur",
        "font-family",
        "font-size",
    ]

    private static let managedBlockPattern = #"(?ms)\n?# programa themes start\r?\n(.*?)\r?\n# programa themes end\n?"#

    let fileManager: FileManager
    let managedConfigURL: URL
    let configSearchURLs: [URL]

    init(
        fileManager: FileManager = .default,
        managedConfigURL: URL,
        configSearchURLs: [URL]
    ) {
        self.fileManager = fileManager
        self.managedConfigURL = managedConfigURL
        self.configSearchURLs = configSearchURLs
    }

    static func live(fileManager: FileManager = .default) -> TerminalThemeStore {
        let home = fileManager.homeDirectoryForCurrentUser
        let applicationSupport = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
        let programaDirectory = applicationSupport
            .appendingPathComponent(overrideBundleIdentifier, isDirectory: true)
        let managedConfigURL = programaDirectory
            .appendingPathComponent("config.ghostty", isDirectory: false)
        let ghosttyDirectory = home
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("ghostty", isDirectory: true)
        let ghosttyApplicationSupport = applicationSupport
            .appendingPathComponent("com.mitchellh.ghostty", isDirectory: true)

        return TerminalThemeStore(
            fileManager: fileManager,
            managedConfigURL: managedConfigURL,
            configSearchURLs: [
                ghosttyDirectory.appendingPathComponent("config", isDirectory: false),
                ghosttyDirectory.appendingPathComponent("config.ghostty", isDirectory: false),
                ghosttyApplicationSupport.appendingPathComponent("config", isDirectory: false),
                ghosttyApplicationSupport.appendingPathComponent("config.ghostty", isDirectory: false),
                programaDirectory.appendingPathComponent("config", isDirectory: false),
                managedConfigURL,
            ]
        )
    }

    // MARK: - Reading

    func currentSelection() -> TerminalThemeSelection {
        var rawValue: String?
        var sourcePath: String?

        for url in configSearchURLs {
            guard let contents = try? String(contentsOf: url, encoding: .utf8),
                  let nextValue = Self.directiveValue(for: "theme", in: contents) else {
                continue
            }
            rawValue = nextValue
            sourcePath = url.path
        }

        return Self.parseSelection(rawValue: rawValue, sourcePath: sourcePath)
    }

    /// Resolves all five directives across `configSearchURLs`, independently per key — a later
    /// file in the chain wins for that key only, matching `currentSelection()`'s theme behavior.
    func currentAppearance() -> TerminalAppearanceOverrides {
        var overrides = TerminalAppearanceOverrides()

        for url in configSearchURLs {
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else { continue }

            if let themeValue = Self.directiveValue(for: "theme", in: contents) {
                let selection = Self.parseSelection(rawValue: themeValue, sourcePath: url.path)
                overrides.themeLight = selection.light
                overrides.themeDark = selection.dark
            }
            if let opacityValue = Self.directiveValue(for: "background-opacity", in: contents),
               let opacity = Double(opacityValue) {
                overrides.backgroundOpacity = opacity
            }
            if let blurValue = Self.directiveValue(for: "background-blur", in: contents),
               let blur = Self.parseBoolDirective(blurValue) {
                overrides.backgroundBlur = blur
            }
            if let fontFamilyValue = Self.directiveValue(for: "font-family", in: contents) {
                overrides.fontFamily = fontFamilyValue
            }
            if let fontSizeValue = Self.directiveValue(for: "font-size", in: contents),
               let fontSize = Double(fontSizeValue) {
                overrides.fontSize = fontSize
            }
        }

        return overrides
    }

    func managedRawThemeValue() -> String? {
        guard let body = managedBlockBody() else { return nil }
        return Self.directiveValue(for: "theme", in: body)
    }

    /// Reads only the managed block, for backups of all five directives.
    func managedRawAppearance() -> TerminalAppearanceOverrides {
        guard let body = managedBlockBody() else { return TerminalAppearanceOverrides() }

        var overrides = TerminalAppearanceOverrides()
        if let themeValue = Self.directiveValue(for: "theme", in: body) {
            let selection = Self.parseSelection(rawValue: themeValue, sourcePath: nil)
            overrides.themeLight = selection.light
            overrides.themeDark = selection.dark
        }
        if let opacityValue = Self.directiveValue(for: "background-opacity", in: body),
           let opacity = Double(opacityValue) {
            overrides.backgroundOpacity = opacity
        }
        if let blurValue = Self.directiveValue(for: "background-blur", in: body),
           let blur = Self.parseBoolDirective(blurValue) {
            overrides.backgroundBlur = blur
        }
        if let fontFamilyValue = Self.directiveValue(for: "font-family", in: body) {
            overrides.fontFamily = fontFamilyValue
        }
        if let fontSizeValue = Self.directiveValue(for: "font-size", in: body),
           let fontSize = Double(fontSizeValue) {
            overrides.fontSize = fontSize
        }
        return overrides
    }

    // MARK: - Writing

    func set(light: String?, dark: String?) throws -> TerminalThemeMutation {
        try set(TerminalAppearanceOverrides(themeLight: light, themeDark: dark))
    }

    /// Writes only the non-nil fields as directive lines, in `orderedDirectiveKeys` order.
    /// This is a full desired-state replace of the managed block's directives — callers that
    /// want to change one field while preserving the others must read `managedRawAppearance()`
    /// first and re-supply the sibling fields (mirrors how `set(light:dark:)` already worked
    /// for the single-directive case; reading from the *managed* block, not `currentAppearance()`'s
    /// full search-chain resolution, avoids capturing a value the user only ever set in their own
    /// raw Ghostty config into Programa's managed block). An all-nil `overrides` clears the block.
    ///
    /// `backgroundBlur` is a true tri-state: `nil` omits the directive (inherit), `false` writes
    /// an explicit `background-blur = false` (distinct from inherit — needed because a raw Ghostty
    /// config earlier in the search chain may set `background-blur = true`, and an omitted line
    /// would silently fall through to that instead of turning blur off).
    func set(_ overrides: TerminalAppearanceOverrides) throws -> TerminalThemeMutation {
        var directives: [String: String] = [:]
        if let themeValue = Self.encodedThemeValue(light: overrides.themeLight, dark: overrides.themeDark) {
            directives["theme"] = themeValue
        }
        if let opacity = overrides.backgroundOpacity {
            directives["background-opacity"] = String(opacity)
        }
        if let blur = overrides.backgroundBlur {
            directives["background-blur"] = blur ? "true" : "false"
        }
        if let fontFamily = Self.normalizedThemeName(overrides.fontFamily) {
            directives["font-family"] = fontFamily
        }
        if let fontSize = overrides.fontSize {
            directives["font-size"] = String(fontSize)
        }
        return try writeDirectives(directives)
    }

    func set(rawThemeValue: String) throws -> TerminalThemeMutation {
        try set(rawAppearanceValue: rawThemeValue, forKey: "theme")
    }

    /// Surgically writes (or, if `rawAppearanceValue` is empty, removes) a single directive's
    /// line within the managed block without touching any other directive's line. Used by
    /// settings.json's per-key backup/restore paths, where only one key changes ownership.
    func set(rawAppearanceValue: String, forKey key: String) throws -> TerminalThemeMutation {
        try set(rawAppearanceValues: [key: rawAppearanceValue])
    }

    /// Same surgical semantics as `set(rawAppearanceValue:forKey:)`, generalized to update
    /// several directives atomically in one write (e.g. font-family and font-size together).
    /// A nil or empty value removes that directive's line.
    func set(rawAppearanceValues: [String: String?]) throws -> TerminalThemeMutation {
        var directives = currentManagedDirectives()
        for (key, value) in rawAppearanceValues {
            guard Self.orderedDirectiveKeys.contains(key) else { continue }
            if let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
                directives[key] = trimmed
            } else {
                directives.removeValue(forKey: key)
            }
        }
        return try writeDirectives(directives)
    }

    func clear() throws -> TerminalThemeMutation {
        guard let existingContents = try readOptionalContents(at: managedConfigURL) else {
            return TerminalThemeMutation(configURL: managedConfigURL, didChange: false)
        }

        let contentsWithoutManagedBlock = Self.removingManagedBlock(from: existingContents)
        guard contentsWithoutManagedBlock != existingContents else {
            return TerminalThemeMutation(configURL: managedConfigURL, didChange: false)
        }

        let strippedContents = contentsWithoutManagedBlock.trimmingCharacters(in: .whitespacesAndNewlines)
        if strippedContents.isEmpty {
            do {
                try fileManager.removeItem(at: managedConfigURL)
            } catch {
                guard Self.isFileNotFoundError(error) else { throw error }
            }
        } else {
            try strippedContents.appending("\n").write(
                to: managedConfigURL,
                atomically: true,
                encoding: .utf8
            )
        }

        return TerminalThemeMutation(configURL: managedConfigURL, didChange: true)
    }

    static func parseSelection(rawValue: String?, sourcePath: String?) -> TerminalThemeSelection {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return TerminalThemeSelection(rawValue: nil, light: nil, dark: nil, sourcePath: sourcePath)
        }

        var fallbackTheme: String?
        var lightTheme: String?
        var darkTheme: String?

        for token in rawValue.split(separator: ",").map(String.init) {
            let entry = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !entry.isEmpty else { continue }

            let parts = entry.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count != 2 {
                if fallbackTheme == nil { fallbackTheme = entry }
                continue
            }

            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }

            switch key {
            case "light":
                if lightTheme == nil { lightTheme = value }
            case "dark":
                if darkTheme == nil { darkTheme = value }
            default:
                if fallbackTheme == nil { fallbackTheme = value }
            }
        }

        return TerminalThemeSelection(
            rawValue: rawValue,
            light: lightTheme ?? fallbackTheme ?? darkTheme,
            dark: darkTheme ?? fallbackTheme ?? lightTheme,
            sourcePath: sourcePath
        )
    }

    static func encodedThemeValue(light: String?, dark: String?) -> String? {
        let normalizedLight = normalizedThemeName(light)
        let normalizedDark = normalizedThemeName(dark)

        switch (normalizedLight, normalizedDark) {
        case let (lightTheme?, darkTheme?):
            return "light:\(lightTheme),dark:\(darkTheme)"
        case let (lightTheme?, nil):
            return "light:\(lightTheme)"
        case let (nil, darkTheme?):
            return "dark:\(darkTheme)"
        case (nil, nil):
            return nil
        }
    }

    static func requestReload(targetBundleIdentifier: String) {
        DistributedNotificationCenter.default().post(
            name: Notification.Name(reloadNotificationName),
            object: nil,
            userInfo: ["bundleIdentifier": targetBundleIdentifier]
        )
    }

    private static func normalizedThemeName(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    /// Shared with `GhosttyConfig`'s `background-blur` parsing so both surfaces accept the same
    /// literal spellings for a Ghostty boolean directive.
    static func parseBoolDirective(_ value: String) -> Bool? {
        switch value.lowercased() {
        case "true", "1", "yes": return true
        case "false", "0", "no": return false
        default: return nil
        }
    }

    /// "Last matching line wins" scan for a single `key = value` directive, shared by every
    /// managed directive.
    private static func directiveValue(for key: String, in contents: String) -> String? {
        var lastValue: String?

        for line in contents.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            let parts = trimmed.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespacesAndNewlines) == key else {
                continue
            }

            let value = parts[1]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if !value.isEmpty { lastValue = value }
        }

        return lastValue
    }

    private func managedBlockBody() -> String? {
        guard let contents = try? String(contentsOf: managedConfigURL, encoding: .utf8),
              let regex = try? NSRegularExpression(pattern: Self.managedBlockPattern),
              let match = regex.matches(
                in: contents,
                range: NSRange(contents.startIndex..<contents.endIndex, in: contents)
              ).last,
              match.numberOfRanges > 1,
              let bodyRange = Range(match.range(at: 1), in: contents) else {
            return nil
        }
        return String(contents[bodyRange])
    }

    private func currentManagedDirectives() -> [String: String] {
        guard let body = managedBlockBody() else { return [:] }
        var result: [String: String] = [:]
        for key in Self.orderedDirectiveKeys {
            if let value = Self.directiveValue(for: key, in: body) {
                result[key] = value
            }
        }
        return result
    }

    private func writeDirectives(_ directives: [String: String]) throws -> TerminalThemeMutation {
        let lines = Self.orderedDirectiveKeys.compactMap { key -> String? in
            guard let value = directives[key] else { return nil }
            return "\(key) = \(value)"
        }
        guard !lines.isEmpty else { return try clear() }
        return try writeManagedBlock(lines: lines)
    }

    private func writeManagedBlock(lines: [String]) throws -> TerminalThemeMutation {
        let existingContents = try readOptionalContents(at: managedConfigURL) ?? ""
        let strippedContents = Self.removingManagedBlock(from: existingContents)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let blockBody = lines.joined(separator: "\n")
        let block = """
        \(Self.managedBlockStart)
        \(blockBody)
        \(Self.managedBlockEnd)
        """
        let nextContents = strippedContents.isEmpty ? "\(block)\n" : "\(strippedContents)\n\n\(block)\n"

        guard nextContents != existingContents else {
            return TerminalThemeMutation(configURL: managedConfigURL, didChange: false)
        }

        try fileManager.createDirectory(
            at: managedConfigURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        try nextContents.write(to: managedConfigURL, atomically: true, encoding: .utf8)
        return TerminalThemeMutation(configURL: managedConfigURL, didChange: true)
    }

    private static func removingManagedBlock(from contents: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: managedBlockPattern) else {
            return contents
        }
        return regex.stringByReplacingMatches(
            in: contents,
            range: NSRange(contents.startIndex..<contents.endIndex, in: contents),
            withTemplate: ""
        )
    }

    private func readOptionalContents(at url: URL) throws -> String? {
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            guard Self.isFileNotFoundError(error) else { throw error }
            return nil
        }
    }

    private static func isFileNotFoundError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            return nsError.code == NSFileNoSuchFileError || nsError.code == NSFileReadNoSuchFileError
        }
        if nsError.domain == NSPOSIXErrorDomain {
            return nsError.code == ENOENT
        }
        return false
    }
}
