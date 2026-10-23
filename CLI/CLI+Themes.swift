import Foundation
import Darwin

extension ProgramaCLI {
    private struct ThemeReloadStatus {
        let requested: Bool
        let targetBundleIdentifier: String
    }

    func runThemes(commandArgs: [String], jsonOutput: Bool) throws {
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
        let themeStore = TerminalThemeStore.live()
        let current = themeStore.currentSelection()
        let appearance = themeStore.currentAppearance()
        let configPath = themeStore.managedConfigURL.path

        if jsonOutput {
            let currentPayload: [String: Any] = [
                "raw_value": current.rawValue ?? NSNull(),
                "light": current.light ?? NSNull(),
                "dark": current.dark ?? NSNull(),
                "source_path": current.sourcePath ?? NSNull(),
                "opacity": appearance.backgroundOpacity ?? NSNull(),
                "blur": appearance.backgroundBlur ?? NSNull(),
                "font_family": appearance.fontFamily ?? NSNull(),
                "font_size": appearance.fontSize ?? NSNull()
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
        print("Opacity: \(appearance.backgroundOpacity.map { String($0) } ?? "inherit")")
        print("Blur: \(appearance.backgroundBlur.map { $0 ? "on" : "off" } ?? "inherit")")
        print("Font: \(appearance.fontFamily ?? "inherit") \(appearance.fontSize.map { String($0) } ?? "")")
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
        let (opacityOpt, rem2) = parseOption(rem1, name: "--opacity")
        let (fontOpt, rem3) = parseOption(rem2, name: "--font")
        let (fontSizeOpt, rem4) = parseOption(rem3, name: "--font-size")
        let (blurFlag, rem5) = extractFlag(rem4, name: "--blur")
        let (noBlurFlag, remaining) = extractFlag(rem5, name: "--no-blur")

        if let unknown = remaining.first(where: { $0.hasPrefix("--") }) {
            throw CLIError(message: "themes set: unknown flag '\(unknown)'. Known flags: --light <theme>, --dark <theme>, --opacity <0-1>, --blur, --no-blur, --font <name>, --font-size <n>")
        }
        if blurFlag && noBlurFlag {
            throw CLIError(message: "themes set: cannot pass both --blur and --no-blur")
        }

        let availableThemes = availableThemeNames()
        // Base partial updates on the managed block only (not currentAppearance()'s full
        // search-chain resolution) so setting one field never copies a value the user only
        // ever set in their own raw Ghostty config into Programa's managed block.
        let current = TerminalThemeStore.live().managedRawAppearance()

        let lightTheme: String?
        let darkTheme: String?
        var didSpecifyField = false

        if lightOpt == nil && darkOpt == nil && !remaining.isEmpty {
            let joinedTheme = remaining.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            let resolved = try validatedThemeName(joinedTheme, availableThemes: availableThemes)
            lightTheme = resolved
            darkTheme = resolved
            didSpecifyField = true
        } else {
            if !remaining.isEmpty {
                throw CLIError(message: "themes set: unexpected argument '\(remaining.joined(separator: " "))'")
            }
            lightTheme = try lightOpt.map { try validatedThemeName($0, availableThemes: availableThemes) } ?? current.themeLight
            darkTheme = try darkOpt.map { try validatedThemeName($0, availableThemes: availableThemes) } ?? current.themeDark
            didSpecifyField = lightOpt != nil || darkOpt != nil
        }

        var overrides = TerminalAppearanceOverrides(
            themeLight: lightTheme,
            themeDark: darkTheme,
            backgroundOpacity: current.backgroundOpacity,
            backgroundBlur: current.backgroundBlur,
            fontFamily: current.fontFamily,
            fontSize: current.fontSize
        )

        if let opacityOpt {
            guard let opacityValue = Double(opacityOpt), opacityValue >= 0, opacityValue <= 1 else {
                throw CLIError(message: "themes set: --opacity must be a number between 0 and 1")
            }
            overrides.backgroundOpacity = opacityValue
            didSpecifyField = true
        }
        if blurFlag {
            overrides.backgroundBlur = true
            didSpecifyField = true
        }
        if noBlurFlag {
            overrides.backgroundBlur = false
            didSpecifyField = true
        }
        if let fontOpt {
            let trimmed = fontOpt.trimmingCharacters(in: .whitespacesAndNewlines)
            overrides.fontFamily = trimmed.isEmpty ? nil : trimmed
            didSpecifyField = true
        }
        if let fontSizeOpt {
            guard let sizeValue = Double(fontSizeOpt), sizeValue > 0 else {
                throw CLIError(message: "themes set: --font-size must be a positive number")
            }
            overrides.fontSize = sizeValue
            didSpecifyField = true
        }

        guard didSpecifyField else {
            throw CLIError(message: "themes set requires a theme name or at least one flag: --light, --dark, --opacity, --blur/--no-blur, --font, --font-size")
        }

        let configURL = try TerminalThemeStore.live().set(overrides).configURL
        let reloadStatus = reloadThemesIfPossible()

        if jsonOutput {
            let payload: [String: Any] = [
                "ok": true,
                "light": lightTheme ?? NSNull(),
                "dark": darkTheme ?? NSNull(),
                "opacity": overrides.backgroundOpacity ?? NSNull(),
                "blur": overrides.backgroundBlur ?? NSNull(),
                "font_family": overrides.fontFamily ?? NSNull(),
                "font_size": overrides.fontSize ?? NSNull(),
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
        let configURL = try TerminalThemeStore.live().clear().configURL
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
        let needle = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let nearMatches = availableThemes.filter {
            $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).contains(needle)
        }.prefix(5)
        let suggestion = nearMatches.isEmpty
            ? ""
            : " Did you mean: \(nearMatches.map { "'\($0)'" }.joined(separator: ", "))?"
        throw CLIError(message: "Unknown theme '\(trimmed)'.\(suggestion) Run 'programa themes' to list available themes.")
    }

    private func reloadThemesIfPossible() -> ThemeReloadStatus {
        let bundleIdentifier = currentProgramaAppBundleIdentifier()
            ?? TerminalThemeStore.overrideBundleIdentifier
        TerminalThemeStore.requestReload(targetBundleIdentifier: bundleIdentifier)
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

    func themesSubcommandUsage(_ command: String) -> String? {
        switch command {
        case "themes":
            return """
            Usage: programa themes
                   programa themes list
                   programa themes set <theme>
                   programa themes set --light <theme> [--dark <theme>]
                   programa themes set --dark <theme> [--light <theme>]
                   programa themes set --opacity <0-1> [--blur|--no-blur] [--font <name>] [--font-size <n>]
                   programa themes clear

            Commands:
              list                      List available themes and mark the current light/dark defaults and appearance
                                        (running `programa themes` with no subcommand does the same)
              set <theme>               Set the same theme for both light and dark appearance
              set --light <theme>       Set the light appearance theme
              set --dark <theme>        Set the dark appearance theme
              set --opacity <0-1>       Set the terminal background opacity
              set --blur                Enable background blur
              set --no-blur             Disable background blur
              set --font <name>         Set the terminal font family
              set --font-size <n>       Set the terminal font size
              clear                     Remove the programa managed overrides and fall back to other config

            Examples:
              programa themes
              programa themes list
              programa themes set "Catppuccin Mocha"
              programa themes set --light "Catppuccin Latte" --dark "Catppuccin Mocha"
              programa themes set --opacity 0.85 --blur --font "JetBrains Mono" --font-size 13
              programa themes clear
            """
        default:
            return nil
        }
    }
}
