import Foundation
import CryptoKit
import Darwin
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
#if canImport(Security)
import Security
#endif

extension CMUXCLI {
    private static let programaThemeOverrideBundleIdentifier = "com.darkroom.programa"
    private static let programaThemesBlockStart = "# programa themes start"
    private static let programaThemesBlockEnd = "# programa themes end"
    private static let programaThemesReloadNotificationName = "com.darkroom.programa.themes.reload-config"

    private struct ThemeSelection {
        let rawValue: String?
        let light: String?
        let dark: String?
        let sourcePath: String?
    }

    private struct ThemeReloadStatus {
        let requested: Bool
        let targetBundleIdentifier: String
    }

    private enum ThemePickerTargetMode: String {
        case both
        case light
        case dark
    }

    private func shouldUseInteractiveThemePicker(jsonOutput: Bool) -> Bool {
        guard !jsonOutput else { return false }
        return isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1
    }

    private func runInteractiveThemes() throws {
        guard let helperURL = bundledHelperURL(named: "ghostty") else {
            throw CLIError(message: "Bundled Ghostty theme picker helper not found")
        }

        let selection = currentThemeSelection()
        var environment = ProcessInfo.processInfo.environment
        environment["PROGRAMA_THEME_PICKER_CONFIG"] = try programaThemeOverrideConfigURL().path
        environment["PROGRAMA_THEME_PICKER_BUNDLE_ID"] = currentProgramaAppBundleIdentifier() ?? Self.programaThemeOverrideBundleIdentifier
        environment["PROGRAMA_THEME_PICKER_TARGET"] = defaultThemePickerTargetMode(current: selection).rawValue
        environment["PROGRAMA_THEME_PICKER_COLOR_SCHEME"] = defaultAppearancePrefersDarkThemes() ? "dark" : "light"
        if let light = selection.light {
            environment["PROGRAMA_THEME_PICKER_INITIAL_LIGHT"] = light
        }
        if let dark = selection.dark {
            environment["PROGRAMA_THEME_PICKER_INITIAL_DARK"] = dark
        }
        if let resourcesURL = bundledGhosttyResourcesURL() {
            environment["GHOSTTY_RESOURCES_DIR"] = resourcesURL.path
        }

        try execInteractiveHelper(
            executablePath: helperURL.path,
            arguments: ["+list-themes"],
            environment: environment
        )
    }

    private func defaultThemePickerTargetMode(current: ThemeSelection) -> ThemePickerTargetMode {
        if let light = current.light,
           let dark = current.dark,
           light.caseInsensitiveCompare(dark) == .orderedSame {
            return .both
        }
        return defaultAppearancePrefersDarkThemes() ? .dark : .light
    }

    private func defaultAppearancePrefersDarkThemes() -> Bool {
        let globalDefaults = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)
        let interfaceStyle = (globalDefaults?["AppleInterfaceStyle"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return interfaceStyle?.caseInsensitiveCompare("Dark") == .orderedSame
    }

    private func bundledHelperURL(named helperName: String) -> URL? {
        let fileManager = FileManager.default
        guard let executableURL = resolvedExecutableURL() else { return nil }

        var candidates: [URL] = [
            executableURL.deletingLastPathComponent().appendingPathComponent(helperName, isDirectory: false)
        ]

        var current = executableURL.deletingLastPathComponent().standardizedFileURL
        while true {
            if current.lastPathComponent == "Contents" {
                candidates.append(
                    current
                        .appendingPathComponent("Resources", isDirectory: true)
                        .appendingPathComponent("bin", isDirectory: true)
                        .appendingPathComponent(helperName, isDirectory: false)
                )
            }

            let projectMarker = current.appendingPathComponent("GhosttyTabs.xcodeproj/project.pbxproj", isDirectory: false)
            let repoHelper = current
                .appendingPathComponent("ghostty", isDirectory: true)
                .appendingPathComponent("zig-out", isDirectory: true)
                .appendingPathComponent("bin", isDirectory: true)
                .appendingPathComponent(helperName, isDirectory: false)
            if fileManager.fileExists(atPath: projectMarker.path),
               fileManager.isExecutableFile(atPath: repoHelper.path) {
                candidates.append(repoHelper)
                break
            }

            guard let parent = parentSearchURL(for: current) else { break }
            current = parent
        }

        return candidates.first(where: { fileManager.isExecutableFile(atPath: $0.path) })
    }

    private func execInteractiveHelper(
        executablePath: String,
        arguments: [String],
        environment: [String: String]
    ) throws -> Never {
        var argv = ([executablePath] + arguments).map { strdup($0) }
        defer {
            for item in argv {
                free(item)
            }
        }
        argv.append(nil)

        var envp = environment
            .map { key, value in strdup("\(key)=\(value)") }
        defer {
            for item in envp {
                free(item)
            }
        }
        envp.append(nil)

        execve(executablePath, &argv, &envp)
        let code = errno
        throw CLIError(message: "Failed to launch interactive theme picker: \(String(cString: strerror(code)))")
    }

    private func bundledGhosttyResourcesURL() -> URL? {
        let fileManager = FileManager.default
        guard let executableURL = resolvedExecutableURL() else { return nil }

        var current = executableURL.deletingLastPathComponent().standardizedFileURL
        while true {
            if current.lastPathComponent == "Contents" {
                let candidate = current
                    .appendingPathComponent("Resources", isDirectory: true)
                    .appendingPathComponent("ghostty", isDirectory: true)
                if fileManager.fileExists(atPath: candidate.path) {
                    return candidate
                }
            }

            let projectMarker = current.appendingPathComponent("GhosttyTabs.xcodeproj/project.pbxproj", isDirectory: false)
            let repoResources = current
                .appendingPathComponent("Resources", isDirectory: true)
                .appendingPathComponent("ghostty", isDirectory: true)
            if fileManager.fileExists(atPath: projectMarker.path),
               fileManager.fileExists(atPath: repoResources.path) {
                return repoResources
            }

            guard let parent = parentSearchURL(for: current) else { break }
            current = parent
        }

        return Bundle.main.resourceURL?.appendingPathComponent("ghostty", isDirectory: true)
    }

    func runThemes(commandArgs: [String], jsonOutput: Bool) throws {
        if commandArgs.isEmpty {
            if shouldUseInteractiveThemePicker(jsonOutput: jsonOutput) {
                try runInteractiveThemes()
                return
            }
            try printThemesList(jsonOutput: jsonOutput)
            return
        }

        guard let subcommand = commandArgs.first else {
            try printThemesList(jsonOutput: jsonOutput)
            return
        }

        switch subcommand {
        case "list":
            if commandArgs.count > 1 {
                throw CLIError(message: "themes list does not take any positional arguments")
            }
            try printThemesList(jsonOutput: jsonOutput)
        case "set":
            try runThemesSet(
                args: Array(commandArgs.dropFirst()),
                jsonOutput: jsonOutput
            )
        case "clear":
            if commandArgs.count > 1 {
                throw CLIError(message: "themes clear does not take any positional arguments")
            }
            try runThemesClear(jsonOutput: jsonOutput)
        default:
            if subcommand.hasPrefix("-") {
                throw CLIError(message: "Unknown themes subcommand '\(subcommand)'. Run 'programa themes --help'.")
            }

            try runThemesSet(
                args: commandArgs,
                jsonOutput: jsonOutput
            )
        }
    }

    private func printThemesList(jsonOutput: Bool) throws {
        let themes = availableThemeNames()
        let current = currentThemeSelection()
        let configPath = try programaThemeOverrideConfigURL().path

        if jsonOutput {
            let currentPayload: [String: Any] = [
                "raw_value": current.rawValue ?? NSNull(),
                "light": current.light ?? NSNull(),
                "dark": current.dark ?? NSNull(),
                "source_path": current.sourcePath ?? NSNull()
            ]
            let payload: [String: Any] = [
                "themes": themes.map { theme in
                    [
                        "name": theme,
                        "current_light": current.light?.caseInsensitiveCompare(theme) == .orderedSame,
                        "current_dark": current.dark?.caseInsensitiveCompare(theme) == .orderedSame
                    ]
                },
                "current": currentPayload,
                "config_path": configPath
            ]
            print(jsonString(payload))
            return
        }

        print("Current light: \(current.light ?? "inherit")")
        print("Current dark: \(current.dark ?? "inherit")")
        print("Config: \(configPath)")
        if let sourcePath = current.sourcePath {
            print("Source: \(sourcePath)")
        }
        print("")

        guard !themes.isEmpty else {
            print("No themes found.")
            return
        }

        for theme in themes {
            var badges: [String] = []
            if current.light?.caseInsensitiveCompare(theme) == .orderedSame {
                badges.append("light")
            }
            if current.dark?.caseInsensitiveCompare(theme) == .orderedSame {
                badges.append("dark")
            }
            let badgeText = badges.isEmpty ? "" : "  [\(badges.joined(separator: ", "))]"
            print("\(theme)\(badgeText)")
        }
    }

    private func runThemesSet(args: [String], jsonOutput: Bool) throws {
        let (lightOpt, rem0) = parseOption(args, name: "--light")
        let (darkOpt, rem1) = parseOption(rem0, name: "--dark")

        if let unknown = rem1.first(where: { $0.hasPrefix("--") }) {
            throw CLIError(message: "themes set: unknown flag '\(unknown)'. Known flags: --light <theme>, --dark <theme>")
        }

        let availableThemes = availableThemeNames()
        let current = currentThemeSelection()

        let lightTheme: String?
        let darkTheme: String?

        if lightOpt == nil && darkOpt == nil {
            let joinedTheme = rem1.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !joinedTheme.isEmpty else {
                throw CLIError(message: "themes set requires a theme name or --light/--dark flags")
            }
            let resolved = try validatedThemeName(joinedTheme, availableThemes: availableThemes)
            lightTheme = resolved
            darkTheme = resolved
        } else {
            if !rem1.isEmpty {
                throw CLIError(message: "themes set: unexpected argument '\(rem1.joined(separator: " "))'")
            }
            lightTheme = try lightOpt.map { try validatedThemeName($0, availableThemes: availableThemes) } ?? current.light
            darkTheme = try darkOpt.map { try validatedThemeName($0, availableThemes: availableThemes) } ?? current.dark
        }

        guard let rawThemeValue = encodedThemeValue(light: lightTheme, dark: darkTheme) else {
            throw CLIError(message: "themes set requires at least one theme")
        }

        let configURL = try writeManagedThemeOverride(rawThemeValue: rawThemeValue)
        let reloadStatus = reloadThemesIfPossible()

        if jsonOutput {
            let payload: [String: Any] = [
                "ok": true,
                "light": lightTheme ?? NSNull(),
                "dark": darkTheme ?? NSNull(),
                "raw_value": rawThemeValue,
                "config_path": configURL.path,
                "reload_requested": reloadStatus.requested,
                "reload_target_bundle_id": reloadStatus.targetBundleIdentifier
            ]
            print(jsonString(payload))
            return
        }

        print(
            "OK light=\(lightTheme ?? "-") dark=\(darkTheme ?? "-") config=\(configURL.path) reload=requested"
        )
    }

    private func runThemesClear(jsonOutput: Bool) throws {
        let configURL = try clearManagedThemeOverride()
        let reloadStatus = reloadThemesIfPossible()

        if jsonOutput {
            let payload: [String: Any] = [
                "ok": true,
                "cleared": true,
                "config_path": configURL.path,
                "reload_requested": reloadStatus.requested,
                "reload_target_bundle_id": reloadStatus.targetBundleIdentifier
            ]
            print(jsonString(payload))
            return
        }

        print("OK cleared config=\(configURL.path) reload=requested")
    }

    private func currentThemeSelection() -> ThemeSelection {
        var rawValue: String?
        var sourcePath: String?

        for url in themeConfigSearchURLs() {
            guard let contents = try? String(contentsOf: url, encoding: .utf8),
                  let nextValue = lastThemeDirective(in: contents) else {
                continue
            }
            rawValue = nextValue
            sourcePath = url.path
        }

        return parseThemeSelection(rawValue: rawValue, sourcePath: sourcePath)
    }

    private func parseThemeSelection(rawValue: String?, sourcePath: String?) -> ThemeSelection {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines), !rawValue.isEmpty else {
            return ThemeSelection(rawValue: nil, light: nil, dark: nil, sourcePath: sourcePath)
        }

        var fallbackTheme: String?
        var lightTheme: String?
        var darkTheme: String?

        for token in rawValue.split(separator: ",").map(String.init) {
            let entry = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !entry.isEmpty else { continue }

            let parts = entry.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count != 2 {
                if fallbackTheme == nil {
                    fallbackTheme = entry
                }
                continue
            }

            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }

            switch key {
            case "light":
                if lightTheme == nil {
                    lightTheme = value
                }
            case "dark":
                if darkTheme == nil {
                    darkTheme = value
                }
            default:
                if fallbackTheme == nil {
                    fallbackTheme = value
                }
            }
        }

        let resolvedLight = lightTheme ?? fallbackTheme ?? darkTheme
        let resolvedDark = darkTheme ?? fallbackTheme ?? lightTheme
        return ThemeSelection(rawValue: rawValue, light: resolvedLight, dark: resolvedDark, sourcePath: sourcePath)
    }

    private func encodedThemeValue(light: String?, dark: String?) -> String? {
        let normalizedLight = light?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedDark = dark?.trimmingCharacters(in: .whitespacesAndNewlines)

        switch (normalizedLight?.isEmpty == false ? normalizedLight : nil, normalizedDark?.isEmpty == false ? normalizedDark : nil) {
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

    private func availableThemeNames() -> [String] {
        let fileManager = FileManager.default
        var seen: Set<String> = []
        var themes: [String] = []

        for directoryURL in themeDirectoryURLs() {
            guard let entries = try? fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for entry in entries {
                let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
                guard values?.isDirectory != true else { continue }
                guard values?.isRegularFile == true || values?.isRegularFile == nil else { continue }
                let name = entry.lastPathComponent
                let folded = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                if seen.insert(folded).inserted {
                    themes.append(name)
                }
            }
        }

        return themes.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private func themeDirectoryURLs() -> [URL] {
        let fileManager = FileManager.default
        let processEnv = ProcessInfo.processInfo.environment
        var urls: [URL] = []
        var seen: Set<String> = []

        func appendIfExisting(_ url: URL?) {
            guard let url else { return }
            let standardized = url.standardizedFileURL
            guard fileManager.fileExists(atPath: standardized.path) else { return }
            if seen.insert(standardized.path).inserted {
                urls.append(standardized)
            }
        }

        if let resourcesDir = processEnv["GHOSTTY_RESOURCES_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !resourcesDir.isEmpty {
            appendIfExisting(URL(fileURLWithPath: resourcesDir, isDirectory: true).appendingPathComponent("themes", isDirectory: true))
        }

        appendIfExisting(
            Bundle.main.resourceURL?
                .appendingPathComponent("ghostty", isDirectory: true)
                .appendingPathComponent("themes", isDirectory: true)
        )

        if let executableURL = resolvedExecutableURL() {
            var current = executableURL.deletingLastPathComponent().standardizedFileURL
            while true {
                if current.lastPathComponent == "Resources" {
                    appendIfExisting(
                        current
                            .appendingPathComponent("ghostty", isDirectory: true)
                            .appendingPathComponent("themes", isDirectory: true)
                    )
                }
                if current.lastPathComponent == "Contents" {
                    appendIfExisting(
                        current
                            .appendingPathComponent("Resources", isDirectory: true)
                            .appendingPathComponent("ghostty", isDirectory: true)
                            .appendingPathComponent("themes", isDirectory: true)
                    )
                }

                let projectMarker = current.appendingPathComponent("GhosttyTabs.xcodeproj/project.pbxproj", isDirectory: false)
                let repoThemes = current.appendingPathComponent("Resources/ghostty/themes", isDirectory: true)
                if fileManager.fileExists(atPath: projectMarker.path),
                   fileManager.fileExists(atPath: repoThemes.path) {
                    appendIfExisting(repoThemes)
                    break
                }

                guard let parent = parentSearchURL(for: current) else { break }
                current = parent
            }
        }

        if let xdgDataDirs = processEnv["XDG_DATA_DIRS"] {
            for dataDir in xdgDataDirs.split(separator: ":").map(String.init).filter({ !$0.isEmpty }) {
                appendIfExisting(
                    URL(fileURLWithPath: NSString(string: dataDir).expandingTildeInPath, isDirectory: true)
                        .appendingPathComponent("ghostty/themes", isDirectory: true)
                )
            }
        }

        appendIfExisting(URL(fileURLWithPath: "/Applications/Ghostty.app/Contents/Resources/ghostty/themes", isDirectory: true))
        appendIfExisting(URL(fileURLWithPath: NSString(string: "~/.config/ghostty/themes").expandingTildeInPath, isDirectory: true))
        appendIfExisting(
            URL(
                fileURLWithPath: NSString(
                    string: "~/Library/Application Support/com.mitchellh.ghostty/themes"
                ).expandingTildeInPath,
                isDirectory: true
            )
        )

        return urls
    }

    private func validatedThemeName(_ rawValue: String, availableThemes: [String]) throws -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CLIError(message: "Theme name cannot be empty")
        }
        if let matched = availableThemes.first(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return matched
        }
        if availableThemes.isEmpty {
            return trimmed
        }
        throw CLIError(message: "Unknown theme '\(trimmed)'. Run 'programa themes' to list available themes.")
    }

    private func themeConfigSearchURLs() -> [URL] {
        let rawPaths = [
            "~/.config/ghostty/config",
            "~/.config/ghostty/config.ghostty",
            "~/Library/Application Support/com.mitchellh.ghostty/config",
            "~/Library/Application Support/com.mitchellh.ghostty/config.ghostty",
            "~/Library/Application Support/\(Self.programaThemeOverrideBundleIdentifier)/config",
            "~/Library/Application Support/\(Self.programaThemeOverrideBundleIdentifier)/config.ghostty",
        ]

        return rawPaths.map {
            URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath, isDirectory: false)
        }
    }

    private func lastThemeDirective(in contents: String) -> String? {
        var lastValue: String?

        for line in contents.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }

            let parts = trimmed.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            guard parts[0].trimmingCharacters(in: .whitespacesAndNewlines) == "theme" else { continue }

            let value = parts[1]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if !value.isEmpty {
                lastValue = value
            }
        }

        return lastValue
    }

    private func programaThemeOverrideConfigURL() throws -> URL {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw CLIError(message: "Unable to resolve Application Support directory")
        }
        return appSupport
            .appendingPathComponent(Self.programaThemeOverrideBundleIdentifier, isDirectory: true)
            .appendingPathComponent("config.ghostty", isDirectory: false)
    }

    private func writeManagedThemeOverride(rawThemeValue: String) throws -> URL {
        let fileManager = FileManager.default
        let configURL = try programaThemeOverrideConfigURL()
        let directoryURL = configURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)

        let existingContents = try readOptionalThemeOverrideContents(at: configURL) ?? ""
        let strippedContents = removingManagedThemeOverride(from: existingContents)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let block = """
        \(Self.programaThemesBlockStart)
        theme = \(rawThemeValue)
        \(Self.programaThemesBlockEnd)
        """

        let nextContents = strippedContents.isEmpty ? "\(block)\n" : "\(strippedContents)\n\n\(block)\n"
        try nextContents.write(to: configURL, atomically: true, encoding: .utf8)
        return configURL
    }

    private func clearManagedThemeOverride() throws -> URL {
        let fileManager = FileManager.default
        let configURL = try programaThemeOverrideConfigURL()
        guard let existingContents = try readOptionalThemeOverrideContents(at: configURL) else {
            return configURL
        }

        let strippedContents = removingManagedThemeOverride(from: existingContents)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if strippedContents.isEmpty {
            do {
                try fileManager.removeItem(at: configURL)
            } catch {
                guard !isThemeOverrideFileNotFoundError(error) else {
                    return configURL
                }
                throw error
            }
        } else {
            try strippedContents.appending("\n").write(to: configURL, atomically: true, encoding: .utf8)
        }

        return configURL
    }

    private func readOptionalThemeOverrideContents(at url: URL) throws -> String? {
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            guard isThemeOverrideFileNotFoundError(error) else {
                throw error
            }
            return nil
        }
    }

    private func isThemeOverrideFileNotFoundError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            return nsError.code == NSFileNoSuchFileError || nsError.code == NSFileReadNoSuchFileError
        }
        if nsError.domain == NSPOSIXErrorDomain {
            return nsError.code == ENOENT
        }
        return false
    }

    private func removingManagedThemeOverride(from contents: String) -> String {
        let pattern = #"(?ms)\n?# programa themes start\n.*?\n# programa themes end\n?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return contents
        }
        let fullRange = NSRange(contents.startIndex..<contents.endIndex, in: contents)
        return regex.stringByReplacingMatches(in: contents, options: [], range: fullRange, withTemplate: "")
    }

    private func reloadThemesIfPossible() -> ThemeReloadStatus {
        let bundleIdentifier = currentProgramaAppBundleIdentifier() ?? Self.programaThemeOverrideBundleIdentifier
        DistributedNotificationCenter.default().post(
            name: Notification.Name(Self.programaThemesReloadNotificationName),
            object: nil,
            userInfo: ["bundleIdentifier": bundleIdentifier]
        )
        return ThemeReloadStatus(requested: true, targetBundleIdentifier: bundleIdentifier)
    }

    private func currentProgramaAppBundleIdentifier() -> String? {
        if let bundleIdentifier = ProcessInfo.processInfo.environment["PROGRAMA_BUNDLE_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !bundleIdentifier.isEmpty {
            return bundleIdentifier
        }

        if let bundleIdentifier = Bundle.main.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
           !bundleIdentifier.isEmpty {
            return bundleIdentifier
        }

        guard let executableURL = resolvedExecutableURL() else {
            return nil
        }

        var current = executableURL.deletingLastPathComponent().standardizedFileURL
        while true {
            if current.pathExtension == "app",
               let bundleIdentifier = Bundle(url: current)?.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
               !bundleIdentifier.isEmpty {
                return bundleIdentifier
            }

            if current.lastPathComponent == "Contents" {
                let appURL = current.deletingLastPathComponent().standardizedFileURL
                if appURL.pathExtension == "app",
                   let bundleIdentifier = Bundle(url: appURL)?.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !bundleIdentifier.isEmpty {
                    return bundleIdentifier
                }
            }

            guard let parent = parentSearchURL(for: current) else {
                break
            }
            current = parent
        }

        return nil
    }

    /// Subcommand help text for Themes commands, split out of the
    /// central `subcommandUsage` switch (programa.swift) so each domain's
    /// help text lives next to its command descriptors. Refs #101.
    func themesSubcommandUsage(_ command: String) -> String? {
        switch command {
        case "themes":
            return """
            Usage: programa themes
                   programa themes list
                   programa themes set <theme>
                   programa themes set --light <theme> [--dark <theme>]
                   programa themes set --dark <theme> [--light <theme>]
                   programa themes clear

            When run in a TTY, `programa themes` opens an interactive theme picker with
            live app preview. Use `programa themes list` for a plain listing.

            The picker previews the selected theme across the running programa app and
            lets you apply it to the light theme, dark theme, or both defaults.

            Commands:
              list                      List available themes and mark the current light/dark defaults
              set <theme>               Set the same theme for both light and dark appearance
              set --light <theme>       Set the light appearance theme
              set --dark <theme>        Set the dark appearance theme
              clear                     Remove the programa theme override and fall back to other config

            Examples:
              programa themes
              programa themes list
              programa themes set "Catppuccin Mocha"
              programa themes set --light "Catppuccin Latte" --dark "Catppuccin Mocha"
              programa themes clear
            """
        default:
            return nil
        }
    }
}
