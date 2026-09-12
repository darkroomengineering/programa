import XCTest
import AppKit
import WebKit
import Darwin

#if canImport(Programa_DEV)
@testable import Programa_DEV
#elseif canImport(Programa)
@testable import Programa
#endif

/// Runs the actual shell integration against a bundled CLI stand-in. The first
/// report is denied, the next acknowledged; shell bookkeeping must follow that
/// acknowledgment, including when no password environment variable is present.
private final class LocalTTYReportFixture {
    let root: URL
    let socketFD: Int32
    var socketPath: String { root.appendingPathComponent("control.sock").path }
    var countPath: String { root.appendingPathComponent("count").path }
    var cliPath: String { root.appendingPathComponent("programa").path }

    init() throws {
        root = URL(fileURLWithPath: "/tmp/tty-" + String(UUID().uuidString.prefix(8)))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        socketFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = root.appendingPathComponent("control.sock").path
        path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: 104) { _ = strcpy($0, source) }
            }
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let script = """
        #!/bin/sh
        case "$*" in *"rpc surface.report_tty "*) ;; *) exit 0 ;; esac
        count=0
        test ! -f '\(countPath)' || count=$(cat '\(countPath)')
        count=$((count + 1))
        printf '%s' "$count" > '\(countPath)'
        test "$count" -gt 1
        """
        try script.write(toFile: cliPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cliPath)
    }

    deinit {
        Darwin.close(socketFD)
        try? FileManager.default.removeItem(at: root)
    }

    var environment: [String: String] { [
        "PATH": root.path + ":/usr/bin:/bin:/usr/sbin:/sbin",
        "PROGRAMA_BUNDLED_CLI_PATH": cliPath,
        "PROGRAMA_SOCKET_PATH": socketPath,
        "PROGRAMA_WORKSPACE_ID": "11111111-1111-1111-1111-111111111111",
        "PROGRAMA_TAB_ID": "11111111-1111-1111-1111-111111111111",
        "PROGRAMA_PANEL_ID": "22222222-2222-2222-2222-222222222222",
        "PROGRAMA_SURFACE_ID": "22222222-2222-2222-2222-222222222222",
    ] }

    var posixCommand: String { """
        rm -f '\(countPath)'
        _PROGRAMA_TTY_NAME=ttys999
        _PROGRAMA_TTY_REPORTED=0
        _cmux_report_tty_once
        first=$_PROGRAMA_TTY_REPORTED
        _cmux_report_tty_once
        second=$_PROGRAMA_TTY_REPORTED
        _cmux_report_tty_once
        printf 'TTY_STATES=%s,%s,%s\\n' "$first" "$second" "$_PROGRAMA_TTY_REPORTED"
        printf 'TTY_ATTEMPTS=%s\\n' "$(cat '\(countPath)' 2>/dev/null)"
        """ }

    var fishCommand: String { """
        rm -f '\(countPath)'
        set -g _PROGRAMA_TTY_NAME ttys999
        set -g _PROGRAMA_TTY_REPORTED 0
        _cmux_report_tty_once
        set first $_PROGRAMA_TTY_REPORTED
        _cmux_report_tty_once
        set second $_PROGRAMA_TTY_REPORTED
        _cmux_report_tty_once
        printf 'TTY_STATES=%s,%s,%s\\n' $first $second $_PROGRAMA_TTY_REPORTED
        printf 'TTY_ATTEMPTS=%s\\n' (cat '\(countPath)' 2>/dev/null)
        """ }
}

final class SidebarPathFormatterTests: XCTestCase {
    func testShortenedPathReplacesExactHomeDirectory() {
        XCTAssertEqual(
            SidebarPathFormatter.shortenedPath(
                "/Users/example",
                homeDirectoryPath: "/Users/example"
            ),
            "~"
        )
    }

    func testShortenedPathReplacesHomeDirectoryPrefix() {
        XCTAssertEqual(
            SidebarPathFormatter.shortenedPath(
                "/Users/example/projects/cmux",
                homeDirectoryPath: "/Users/example"
            ),
            "~/projects/cmux"
        )
    }

    func testShortenedPathLeavesExternalPathUnchanged() {
        XCTAssertEqual(
            SidebarPathFormatter.shortenedPath(
                "/tmp/programa",
                homeDirectoryPath: "/Users/example"
            ),
            "/tmp/programa"
        )
    }
}

final class GhosttyConfigTests: XCTestCase {
    private struct RGB: Equatable {
        let red: Int
        let green: Int
        let blue: Int
    }

    func testResolveThemeNamePrefersLightEntryForPairedTheme() {
        let resolved = GhosttyConfig.resolveThemeName(
            from: "light:Builtin Solarized Light,dark:Builtin Solarized Dark",
            preferredColorScheme: .light
        )

        XCTAssertEqual(resolved, "Builtin Solarized Light")
    }

    func testResolveThemeNamePrefersDarkEntryForPairedTheme() {
        let resolved = GhosttyConfig.resolveThemeName(
            from: "light:Builtin Solarized Light,dark:Builtin Solarized Dark",
            preferredColorScheme: .dark
        )

        XCTAssertEqual(resolved, "Builtin Solarized Dark")
    }

    func testThemeNameCandidatesIncludeBuiltinAliasForms() {
        let candidates = GhosttyConfig.themeNameCandidates(from: "Builtin Solarized Light")
        XCTAssertEqual(candidates.first, "Builtin Solarized Light")
        XCTAssertTrue(candidates.contains("Solarized Light"))
        XCTAssertTrue(candidates.contains("iTerm2 Solarized Light"))
    }

    func testThemeNameCandidatesMapSolarizedDarkToITerm2Alias() {
        let candidates = GhosttyConfig.themeNameCandidates(from: "Builtin Solarized Dark")
        XCTAssertTrue(candidates.contains("Solarized Dark"))
        XCTAssertTrue(candidates.contains("iTerm2 Solarized Dark"))
    }

    // #26: on near-black backgrounds the divider must be lightened to stay visible,
    // not darkened toward black.
    func testSplitDividerLightensOnNearBlackBackground() {
        var config = GhosttyConfig()
        config.splitDividerColor = nil
        config.backgroundColor = NSColor(hex: "#0a0a0a")!

        let divider = config.resolvedSplitDividerColor
        XCTAssertGreaterThan(
            divider.luminance,
            config.backgroundColor.luminance + 0.05,
            "Divider on a near-black background should be clearly lighter than the background"
        )
    }

    func testSplitDividerDarkensOnLightBackground() {
        var config = GhosttyConfig()
        config.splitDividerColor = nil
        config.backgroundColor = NSColor(hex: "#fafafa")!

        let divider = config.resolvedSplitDividerColor
        XCTAssertLessThan(
            divider.luminance,
            config.backgroundColor.luminance,
            "Divider on a light background should be darker than the background"
        )
    }

    func testSplitDividerHonorsExplicitOverride() {
        var config = GhosttyConfig()
        let override = NSColor(hex: "#ff0000")!
        config.splitDividerColor = override
        config.backgroundColor = NSColor(hex: "#0a0a0a")!

        XCTAssertEqual(config.resolvedSplitDividerColor, override)
    }

    func testThemeSearchPathsIncludeXDGDataDirsThemes() {
        let pathA = "/tmp/programa-theme-a"
        let pathB = "/tmp/programa-theme-b"
        let paths = GhosttyConfig.themeSearchPaths(
            forThemeName: "Solarized Light",
            environment: ["XDG_DATA_DIRS": "\(pathA):\(pathB)"],
            bundleResourceURL: nil
        )

        XCTAssertTrue(paths.contains("\(pathA)/ghostty/themes/Solarized Light"))
        XCTAssertTrue(paths.contains("\(pathB)/ghostty/themes/Solarized Light"))
    }

    func testAvailableThemeNamesEnumeratesDirectoriesResolvedByThemeSearchPaths() throws {
        let resourcesRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("programa-theme-catalog-\(UUID().uuidString)", isDirectory: true)
        let themesDirectory = resourcesRoot.appendingPathComponent("themes", isDirectory: true)
        try FileManager.default.createDirectory(at: themesDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: resourcesRoot) }

        try "background = #ffffff\n".write(
            to: themesDirectory.appendingPathComponent("Cloud Light", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
        try "background = #111111\n".write(
            to: themesDirectory.appendingPathComponent("Midnight Dark", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createDirectory(
            at: themesDirectory.appendingPathComponent("Not A Theme", isDirectory: true),
            withIntermediateDirectories: true
        )

        let names = GhosttyConfig.availableThemeNames(
            environment: ["GHOSTTY_RESOURCES_DIR": resourcesRoot.path],
            bundleResourceURL: nil,
            fileManager: .default
        )

        XCTAssertEqual(names, ["Cloud Light", "Midnight Dark"])
    }

    func testLoadThemeResolvesPairedThemeValueByColorScheme() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ghostty-theme-pair-\(UUID().uuidString)")
        let themesDir = root.appendingPathComponent("themes")
        try FileManager.default.createDirectory(at: themesDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try """
        background = #fdf6e3
        foreground = #657b83
        """.write(
            to: themesDir.appendingPathComponent("Light Theme"),
            atomically: true,
            encoding: .utf8
        )

        try """
        background = #002b36
        foreground = #93a1a1
        """.write(
            to: themesDir.appendingPathComponent("Dark Theme"),
            atomically: true,
            encoding: .utf8
        )

        var lightConfig = GhosttyConfig()
        lightConfig.loadTheme(
            "light:Light Theme,dark:Dark Theme",
            environment: ["GHOSTTY_RESOURCES_DIR": root.path],
            bundleResourceURL: nil,
            preferredColorScheme: .light
        )
        XCTAssertEqual(rgb255(lightConfig.backgroundColor), RGB(red: 253, green: 246, blue: 227))

        var darkConfig = GhosttyConfig()
        darkConfig.loadTheme(
            "light:Light Theme,dark:Dark Theme",
            environment: ["GHOSTTY_RESOURCES_DIR": root.path],
            bundleResourceURL: nil,
            preferredColorScheme: .dark
        )
        XCTAssertEqual(rgb255(darkConfig.backgroundColor), RGB(red: 0, green: 43, blue: 54))
    }

    func testParseBackgroundOpacityReadsConfigValue() {
        var config = GhosttyConfig()
        config.parse("background-opacity = 0.42")
        XCTAssertEqual(config.backgroundOpacity, 0.42, accuracy: 0.0001)
    }

    func testLoadThemeResolvesBuiltinAliasFromGhosttyResourcesDir() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ghostty-themes-\(UUID().uuidString)")
        let themesDir = root.appendingPathComponent("themes")
        try FileManager.default.createDirectory(at: themesDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let themePath = themesDir.appendingPathComponent("Solarized Light")
        let themeContents = """
        background = #fdf6e3
        foreground = #657b83
        """
        try themeContents.write(to: themePath, atomically: true, encoding: .utf8)

        var config = GhosttyConfig()
        config.loadTheme(
            "Builtin Solarized Light",
            environment: ["GHOSTTY_RESOURCES_DIR": root.path],
            bundleResourceURL: nil
        )

        XCTAssertEqual(rgb255(config.backgroundColor), RGB(red: 253, green: 246, blue: 227))
    }

    func testLoadThemeResolvesITerm2SolarizedLightAliasToLegacyThemeName() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ghostty-solarized-light-\(UUID().uuidString)")
        let themesDir = root.appendingPathComponent("themes")
        try FileManager.default.createDirectory(at: themesDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try """
        background = #fdf6e3
        foreground = #657b83
        """.write(
            to: themesDir.appendingPathComponent("Solarized Light"),
            atomically: true,
            encoding: .utf8
        )

        var config = GhosttyConfig()
        config.loadTheme(
            "iTerm2 Solarized Light",
            environment: ["GHOSTTY_RESOURCES_DIR": root.path],
            bundleResourceURL: nil
        )

        XCTAssertEqual(rgb255(config.backgroundColor), RGB(red: 253, green: 246, blue: 227))
    }

    func testLoadThemeResolvesITerm2SolarizedDarkAliasToLegacyThemeName() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ghostty-solarized-dark-\(UUID().uuidString)")
        let themesDir = root.appendingPathComponent("themes")
        try FileManager.default.createDirectory(at: themesDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try """
        background = #002b36
        foreground = #93a1a1
        """.write(
            to: themesDir.appendingPathComponent("Solarized Dark"),
            atomically: true,
            encoding: .utf8
        )

        var config = GhosttyConfig()
        config.loadTheme(
            "iTerm2 Solarized Dark",
            environment: ["GHOSTTY_RESOURCES_DIR": root.path],
            bundleResourceURL: nil
        )

        XCTAssertEqual(rgb255(config.backgroundColor), RGB(red: 0, green: 43, blue: 54))
    }

    func testLoadCachesPerColorScheme() {
        GhosttyConfig.invalidateLoadCache()
        defer { GhosttyConfig.invalidateLoadCache() }

        var loadCount = 0
        let loadFromDisk: (GhosttyConfig.ColorSchemePreference) -> GhosttyConfig = { scheme in
            loadCount += 1
            var config = GhosttyConfig()
            config.fontFamily = "\(scheme)-\(loadCount)"
            return config
        }

        let lightFirst = GhosttyConfig.load(
            preferredColorScheme: .light,
            loadFromDisk: loadFromDisk
        )
        let lightSecond = GhosttyConfig.load(
            preferredColorScheme: .light,
            loadFromDisk: loadFromDisk
        )
        let darkFirst = GhosttyConfig.load(
            preferredColorScheme: .dark,
            loadFromDisk: loadFromDisk
        )

        XCTAssertEqual(loadCount, 2)
        XCTAssertEqual(lightFirst.fontFamily, "light-1")
        XCTAssertEqual(lightSecond.fontFamily, "light-1")
        XCTAssertEqual(darkFirst.fontFamily, "dark-2")
    }

    func testLoadCacheInvalidationForcesReload() {
        GhosttyConfig.invalidateLoadCache()
        defer { GhosttyConfig.invalidateLoadCache() }

        var loadCount = 0
        let loadFromDisk: (GhosttyConfig.ColorSchemePreference) -> GhosttyConfig = { _ in
            loadCount += 1
            var config = GhosttyConfig()
            config.fontFamily = "reload-\(loadCount)"
            return config
        }

        let first = GhosttyConfig.load(
            preferredColorScheme: .dark,
            loadFromDisk: loadFromDisk
        )
        GhosttyConfig.invalidateLoadCache()
        let second = GhosttyConfig.load(
            preferredColorScheme: .dark,
            loadFromDisk: loadFromDisk
        )

        XCTAssertEqual(loadCount, 2)
        XCTAssertEqual(first.fontFamily, "reload-1")
        XCTAssertEqual(second.fontFamily, "reload-2")
    }

    func testLegacyConfigFallbackUsesLegacyFileWhenConfigGhosttyIsEmpty() {
        XCTAssertTrue(
            GhosttyApp.shouldLoadLegacyGhosttyConfig(
                newConfigFileSize: 0,
                legacyConfigFileSize: 42
            )
        )
    }

    func testLegacyConfigFallbackSkipsWhenNewFileMissingOrLegacyEmpty() {
        XCTAssertFalse(
            GhosttyApp.shouldLoadLegacyGhosttyConfig(
                newConfigFileSize: nil,
                legacyConfigFileSize: 42
            )
        )
        XCTAssertFalse(
            GhosttyApp.shouldLoadLegacyGhosttyConfig(
                newConfigFileSize: 10,
                legacyConfigFileSize: 42
            )
        )
        XCTAssertFalse(
            GhosttyApp.shouldLoadLegacyGhosttyConfig(
                newConfigFileSize: 0,
                legacyConfigFileSize: 0
            )
        )
        XCTAssertFalse(
            GhosttyApp.shouldLoadLegacyGhosttyConfig(
                newConfigFileSize: 0,
                legacyConfigFileSize: nil
            )
        )
    }

    func testProgramaAppSupportConfigURLsUseReleaseConfigForDebugBundleWithoutCurrentConfig() throws {
        try withTemporaryAppSupportDirectory { appSupportDirectory in
            let releaseConfigURL = try writeAppSupportConfig(
                appSupportDirectory: appSupportDirectory,
                bundleIdentifier: "com.darkroom.programa",
                filename: "config",
                contents: "font-size = 13\n"
            )

            XCTAssertEqual(
                GhosttyApp.cmuxAppSupportConfigURLs(
                    currentBundleIdentifier: "com.darkroom.programa.debug",
                    appSupportDirectory: appSupportDirectory
                ),
                [releaseConfigURL]
            )
        }
    }

    func testProgramaAppSupportConfigURLsPreferCurrentBundleConfigWhenPresent() throws {
        try withTemporaryAppSupportDirectory { appSupportDirectory in
            _ = try writeAppSupportConfig(
                appSupportDirectory: appSupportDirectory,
                bundleIdentifier: "com.darkroom.programa",
                filename: "config",
                contents: "font-size = 13\n"
            )
            let currentConfigURL = try writeAppSupportConfig(
                appSupportDirectory: appSupportDirectory,
                bundleIdentifier: "com.darkroom.programa.debug.issue-829",
                filename: "config.ghostty",
                contents: "font-size = 14\n"
            )

            XCTAssertEqual(
                GhosttyApp.cmuxAppSupportConfigURLs(
                    currentBundleIdentifier: "com.darkroom.programa.debug.issue-829",
                    appSupportDirectory: appSupportDirectory
                ),
                [currentConfigURL]
            )
        }
    }

    func testProgramaAppSupportConfigURLsSkipReleaseFallbackForNonDebugBundle() throws {
        try withTemporaryAppSupportDirectory { appSupportDirectory in
            _ = try writeAppSupportConfig(
                appSupportDirectory: appSupportDirectory,
                bundleIdentifier: "com.darkroom.programa",
                filename: "config",
                contents: "font-size = 13\n"
            )

            XCTAssertTrue(
                GhosttyApp.cmuxAppSupportConfigURLs(
                    currentBundleIdentifier: "com.example.other-app",
                    appSupportDirectory: appSupportDirectory
                ).isEmpty
            )
        }
    }

    func testProgramaAppSupportConfigURLsIgnoreMissingOrEmptyFiles() throws {
        try withTemporaryAppSupportDirectory { appSupportDirectory in
            _ = try writeAppSupportConfig(
                appSupportDirectory: appSupportDirectory,
                bundleIdentifier: "com.darkroom.programa",
                filename: "config.ghostty",
                contents: ""
            )

            XCTAssertTrue(
                GhosttyApp.cmuxAppSupportConfigURLs(
                    currentBundleIdentifier: "com.darkroom.programa.debug",
                    appSupportDirectory: appSupportDirectory
                ).isEmpty
            )
        }
    }

    func testDefaultBackgroundUpdateScopePrioritizesSurfaceOverAppAndUnscoped() {
        XCTAssertTrue(
            GhosttyApp.shouldApplyDefaultBackgroundUpdate(
                currentScope: .unscoped,
                incomingScope: .app
            )
        )
        XCTAssertTrue(
            GhosttyApp.shouldApplyDefaultBackgroundUpdate(
                currentScope: .app,
                incomingScope: .surface
            )
        )
        XCTAssertTrue(
            GhosttyApp.shouldApplyDefaultBackgroundUpdate(
                currentScope: .surface,
                incomingScope: .surface
            )
        )
        XCTAssertFalse(
            GhosttyApp.shouldApplyDefaultBackgroundUpdate(
                currentScope: .surface,
                incomingScope: .app
            )
        )
        XCTAssertFalse(
            GhosttyApp.shouldApplyDefaultBackgroundUpdate(
                currentScope: .surface,
                incomingScope: .unscoped
            )
        )
    }

    func testAppearanceChangeReloadsWhenColorSchemeChanges() {
        XCTAssertTrue(
            GhosttyApp.shouldReloadConfigurationForAppearanceChange(
                previousColorScheme: .dark,
                currentColorScheme: .light
            )
        )
        XCTAssertTrue(
            GhosttyApp.shouldReloadConfigurationForAppearanceChange(
                previousColorScheme: nil,
                currentColorScheme: .dark
            )
        )
    }

    func testAppearanceChangeSkipsReloadWhenColorSchemeUnchanged() {
        XCTAssertFalse(
            GhosttyApp.shouldReloadConfigurationForAppearanceChange(
                previousColorScheme: .light,
                currentColorScheme: .light
            )
        )
        XCTAssertFalse(
            GhosttyApp.shouldReloadConfigurationForAppearanceChange(
                previousColorScheme: .dark,
                currentColorScheme: .dark
            )
        )
    }

    func testClaudeCodeIntegrationDefaultsToEnabledWhenUnset() {
        let suiteName = "cmux.tests.claude-hooks.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated user defaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        defaults.removeObject(forKey: ClaudeCodeIntegrationSettings.hooksEnabledKey)
        XCTAssertTrue(ClaudeCodeIntegrationSettings.hooksEnabled(defaults: defaults))
    }

    func testClaudeCodeIntegrationRespectsStoredPreference() {
        let suiteName = "cmux.tests.claude-hooks.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated user defaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        defaults.set(true, forKey: ClaudeCodeIntegrationSettings.hooksEnabledKey)
        XCTAssertTrue(ClaudeCodeIntegrationSettings.hooksEnabled(defaults: defaults))

        defaults.set(false, forKey: ClaudeCodeIntegrationSettings.hooksEnabledKey)
        XCTAssertFalse(ClaudeCodeIntegrationSettings.hooksEnabled(defaults: defaults))
    }

    private func rgb255(_ color: NSColor) -> RGB {
        let srgb = color.usingColorSpace(.sRGB)!
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        srgb.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return RGB(
            red: Int(round(red * 255)),
            green: Int(round(green * 255)),
            blue: Int(round(blue * 255))
        )
    }

    private func withTemporaryAppSupportDirectory(
        _ body: (URL) throws -> Void
    ) throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-app-support-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }
        try body(directory)
    }

    private func writeAppSupportConfig(
        appSupportDirectory: URL,
        bundleIdentifier: String,
        filename: String,
        contents: String
    ) throws -> URL {
        let fileManager = FileManager.default
        let bundleDirectory = appSupportDirectory
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
        try fileManager.createDirectory(at: bundleDirectory, withIntermediateDirectories: true)

        let configURL = bundleDirectory.appendingPathComponent(filename, isDirectory: false)
        try contents.write(to: configURL, atomically: true, encoding: .utf8)
        return configURL
    }
}

final class WorkspaceChromeThemeTests: XCTestCase {
    func testResolvedChromeColorsUsesLightGhosttyBackground() {
        guard let backgroundColor = NSColor(hex: "#FDF6E3") else {
            XCTFail("Expected valid test color")
            return
        }

        let colors = Workspace.resolvedChromeColors(from: backgroundColor)
        XCTAssertEqual(colors.backgroundHex, "#FDF6E3")
        XCTAssertNil(colors.borderHex)
    }

    func testResolvedChromeColorsUsesDarkGhosttyBackground() {
        guard let backgroundColor = NSColor(hex: "#272822") else {
            XCTFail("Expected valid test color")
            return
        }

        let colors = Workspace.resolvedChromeColors(from: backgroundColor)
        XCTAssertEqual(colors.backgroundHex, "#272822")
        XCTAssertNil(colors.borderHex)
    }
}

final class WorkspaceAppearanceConfigResolutionTests: XCTestCase {
    func testResolvedAppearanceConfigPrefersGhosttyRuntimeBackgroundOverLoadedConfig() {
        guard let loadedBackground = NSColor(hex: "#112233"),
              let runtimeBackground = NSColor(hex: "#FDF6E3"),
              let loadedForeground = NSColor(hex: "#ABCDEF") else {
            XCTFail("Expected valid test colors")
            return
        }

        var loaded = GhosttyConfig()
        loaded.backgroundColor = loadedBackground
        loaded.foregroundColor = loadedForeground
        loaded.unfocusedSplitOpacity = 0.42

        let resolved = WorkspaceContentView.resolveGhosttyAppearanceConfig(
            loadConfig: { loaded },
            defaultBackground: { runtimeBackground }
        )

        XCTAssertEqual(resolved.backgroundColor.hexString(), "#FDF6E3")
        XCTAssertEqual(resolved.foregroundColor.hexString(), "#ABCDEF")
        XCTAssertEqual(resolved.unfocusedSplitOpacity, 0.42, accuracy: 0.0001)
    }

    func testResolvedAppearanceConfigPrefersExplicitBackgroundOverride() {
        guard let loadedBackground = NSColor(hex: "#112233"),
              let runtimeBackground = NSColor(hex: "#FDF6E3"),
              let explicitOverride = NSColor(hex: "#272822") else {
            XCTFail("Expected valid test colors")
            return
        }

        var loaded = GhosttyConfig()
        loaded.backgroundColor = loadedBackground

        let resolved = WorkspaceContentView.resolveGhosttyAppearanceConfig(
            backgroundOverride: explicitOverride,
            loadConfig: { loaded },
            defaultBackground: { runtimeBackground }
        )

        XCTAssertEqual(resolved.backgroundColor.hexString(), "#272822")
    }
}

@MainActor
final class WorkspaceChromeColorTests: XCTestCase {
    func testBonsplitChromeHexIncludesAlphaWhenTranslucent() {
        let color = NSColor(
            srgbRed: 17.0 / 255.0,
            green: 34.0 / 255.0,
            blue: 51.0 / 255.0,
            alpha: 1.0
        )

        let hex = Workspace.bonsplitChromeHex(backgroundColor: color, backgroundOpacity: 0.5)
        XCTAssertEqual(hex, "#11223380")
    }

    func testBonsplitChromeHexOmitsAlphaWhenOpaque() {
        let color = NSColor(
            srgbRed: 17.0 / 255.0,
            green: 34.0 / 255.0,
            blue: 51.0 / 255.0,
            alpha: 1.0
        )

        let hex = Workspace.bonsplitChromeHex(backgroundColor: color, backgroundOpacity: 1.0)
        XCTAssertEqual(hex, "#112233")
    }
}

final class WindowTransparencyDecisionTests: XCTestCase {
    private let sidebarBlendModeKey = "sidebarBlendMode"
    private let bgGlassEnabledKey = "bgGlassEnabled"

    func testWindowTransparencyFollowsGlassAvailabilityAndTerminalOpacity() {
        withTemporaryWindowBackgroundDefaults {
            let defaults = UserDefaults.standard
            defaults.set("withinWindow", forKey: sidebarBlendModeKey)
            defaults.set(false, forKey: bgGlassEnabledKey)

            if WindowGlassEffect.isAvailable {
                // Inverted layout: the glass backdrop is stock, and it samples
                // behind the window — transparency is on regardless of opacity.
                XCTAssertTrue(cmuxShouldUseTransparentBackgroundWindow())
                XCTAssertTrue(cmuxShouldUseClearWindowBackground(for: 1.0))
            } else {
                // Pre-26: opt-in off means only a translucent terminal clears it.
                XCTAssertFalse(cmuxShouldUseTransparentBackgroundWindow())
                XCTAssertFalse(cmuxShouldUseClearWindowBackground(for: 1.0))
            }
            XCTAssertTrue(cmuxShouldUseClearWindowBackground(for: 0.80))
        }
    }

    func testGlassIsStockWhenAvailableAndOptInOtherwise() {
        // Legacy opt-in still decides when the native glass is unavailable.
        XCTAssertTrue(
            cmuxShouldApplyWindowGlass(bgGlassEnabled: true, glassEffectAvailable: false)
        )
        XCTAssertFalse(
            cmuxShouldApplyWindowGlass(bgGlassEnabled: false, glassEffectAvailable: false)
        )
        // Inverted layout: glass is the stock treatment whenever available.
        XCTAssertTrue(
            cmuxShouldApplyWindowGlass(bgGlassEnabled: false, glassEffectAvailable: true)
        )
        XCTAssertTrue(
            cmuxShouldApplyWindowGlass(bgGlassEnabled: true, glassEffectAvailable: true)
        )
        // The startup performance override wins in both directions.
        XCTAssertTrue(
            cmuxShouldApplyWindowGlass(
                bgGlassEnabled: false,
                glassEffectAvailable: false,
                performanceOverride: true
            )
        )
        XCTAssertFalse(
            cmuxShouldApplyWindowGlass(
                bgGlassEnabled: true,
                glassEffectAvailable: true,
                performanceOverride: false
            )
        )
    }

    func testGlassPerformanceOverrideParserAcceptsExplicitBooleanValuesOnly() {
        for surface in ProgramaGlassSurface.allCases {
            XCTAssertEqual(
                ProgramaGlassSettings.parseOverride(
                    for: surface,
                    environment: [surface.environmentKey: "1"]
                ),
                true
            )
            XCTAssertEqual(
                ProgramaGlassSettings.parseOverride(
                    for: surface,
                    environment: [surface.environmentKey: "off"]
                ),
                false
            )
            XCTAssertNil(
                ProgramaGlassSettings.parseOverride(
                    for: surface,
                    environment: [surface.environmentKey: "maybe"]
                )
            )
            XCTAssertNil(
                ProgramaGlassSettings.parseOverride(for: surface, environment: [:])
            )
        }
    }

    func testCleanInstallSidebarPresetUsesLiquidGlassOnlyWhenNativeGlassIsAvailable() {
        XCTAssertEqual(
            ProgramaGlassSettings.defaultSidebarPreset(nativeGlassAvailable: true),
            .liquidGlass
        )
        XCTAssertEqual(
            ProgramaGlassSettings.defaultSidebarPreset(nativeGlassAvailable: false),
            .nativeSidebar
        )
    }

    func testTerminalBackgroundOpacityStaysOpaqueWithWindowGlass() {
        // Inverted layout: panes are opaque elevated cards — window glass no
        // longer clamps an opaque terminal fill.
        XCTAssertEqual(
            ProgramaGlassSettings.effectiveTerminalBackgroundOpacity(
                configuredOpacity: 1.0,
                windowGlassEnabled: true
            ),
            1.0,
            accuracy: 0.0001
        )
    }

    func testTerminalBackgroundOpacityPreservesLowerTranslucentFillWithWindowGlass() {
        XCTAssertEqual(
            ProgramaGlassSettings.effectiveTerminalBackgroundOpacity(
                configuredOpacity: 0.55,
                windowGlassEnabled: true
            ),
            0.55,
            accuracy: 0.0001
        )
    }

    func testTerminalBackgroundOpacityPreservesConfiguredFillWithoutWindowGlass() {
        XCTAssertEqual(
            ProgramaGlassSettings.effectiveTerminalBackgroundOpacity(
                configuredOpacity: 0.96,
                windowGlassEnabled: false
            ),
            0.96,
            accuracy: 0.0001
        )
    }

    func testTerminalBackgroundOpacityClampsConfiguredValue() {
        XCTAssertEqual(
            ProgramaGlassSettings.effectiveTerminalBackgroundOpacity(
                configuredOpacity: -0.25,
                windowGlassEnabled: false
            ),
            0.0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            ProgramaGlassSettings.effectiveTerminalBackgroundOpacity(
                configuredOpacity: 1.25,
                windowGlassEnabled: false
            ),
            1.0,
            accuracy: 0.0001
        )
    }

    func testPlatformGlassDefaultsEnableGatedSurfacesOnlyWhenNativeGlassIsAvailable() {
        let nativeDefaults = ProgramaGlassSettings.platformDefaults(nativeGlassAvailable: true)
        let fallbackDefaults = ProgramaGlassSettings.platformDefaults(nativeGlassAvailable: false)

        XCTAssertEqual(nativeDefaults[ProgramaGlassSettings.windowEnabledKey] as? Bool, true)
        XCTAssertEqual(fallbackDefaults[ProgramaGlassSettings.windowEnabledKey] as? Bool, false)
        XCTAssertEqual(nativeDefaults[ProgramaGlassSettings.tabBarEnabledKey] as? Bool, true)
        XCTAssertEqual(fallbackDefaults[ProgramaGlassSettings.tabBarEnabledKey] as? Bool, false)
        XCTAssertEqual(nativeDefaults[ProgramaGlassSettings.browserToolbarEnabledKey] as? Bool, false)
        XCTAssertEqual(nativeDefaults[ProgramaGlassSettings.overlaysEnabledKey] as? Bool, true)
        XCTAssertEqual(fallbackDefaults[ProgramaGlassSettings.overlaysEnabledKey] as? Bool, false)
    }

    func testExplicitWindowGlassChoiceOverridesRegisteredPlatformDefault() {
        let suite = "programa-tests-glass-explicit-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: ProgramaGlassSettings.windowEnabledKey)

        ProgramaGlassSettings.registerPlatformDefaults(
            defaults: defaults,
            nativeGlassAvailable: true
        )

        XCTAssertFalse(defaults.bool(forKey: ProgramaGlassSettings.windowEnabledKey))
    }

    func testExplicitTabGlassChoiceOverridesRegisteredPlatformDefault() {
        let suite = "programa-tests-tab-glass-explicit-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: ProgramaGlassSettings.tabBarEnabledKey)

        ProgramaGlassSettings.registerPlatformDefaults(
            defaults: defaults,
            nativeGlassAvailable: true
        )

        XCTAssertFalse(defaults.bool(forKey: ProgramaGlassSettings.tabBarEnabledKey))
    }

    func testWithinWindowSidebarBlendKeepsIndependentWindowGlassEnabled() {
        withTemporaryWindowBackgroundDefaults {
            let defaults = UserDefaults.standard
            defaults.set("withinWindow", forKey: sidebarBlendModeKey)
            defaults.set(true, forKey: bgGlassEnabledKey)

            XCTAssertTrue(cmuxShouldUseTransparentBackgroundWindow())
            XCTAssertTrue(cmuxShouldUseClearWindowBackground(for: 1.0))
        }
    }

    private func withTemporaryWindowBackgroundDefaults(_ body: () -> Void) {
        let defaults = UserDefaults.standard
        let originalBlendMode = defaults.object(forKey: sidebarBlendModeKey)
        let originalGlassEnabled = defaults.object(forKey: bgGlassEnabledKey)
        defer {
            restoreDefaultsValue(originalBlendMode, key: sidebarBlendModeKey, defaults: defaults)
            restoreDefaultsValue(originalGlassEnabled, key: bgGlassEnabledKey, defaults: defaults)
        }
        body()
    }

    private func restoreDefaultsValue(_ value: Any?, key: String, defaults: UserDefaults) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}

final class GhosttyTerminalStartupEnvironmentTests: XCTestCase {
    func testPortRangeAssignmentFallsBackWithoutOverflowForMalformedSettings() {
        let assignment = ProgramaPortRangePolicy.assignment(
            base: Int.max,
            range: Int.max,
            ordinal: 0
        )

        XCTAssertEqual(
            assignment,
            ProgramaPortRangeAssignment(start: 9_100, end: 9_109, size: 10)
        )
    }

    func testPortRangeAssignmentWrapsOrdinalWithinValidTCPPorts() {
        let first = ProgramaPortRangePolicy.assignment(base: 65_526, range: 10, ordinal: 0)
        let wrapped = ProgramaPortRangePolicy.assignment(base: 65_526, range: 10, ordinal: Int.max)

        XCTAssertEqual(first, ProgramaPortRangeAssignment(start: 65_526, end: 65_535, size: 10))
        XCTAssertEqual(wrapped, first)
    }

    func testPortRangeAssignmentReadsDefaultsForEveryNewAssignment() throws {
        let suiteName = "GhosttyTerminalStartupEnvironmentTests.ports.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(9_100, forKey: ProgramaPortRangePolicy.baseDefaultsKey)
        defaults.set(10, forKey: ProgramaPortRangePolicy.rangeDefaultsKey)
        XCTAssertEqual(
            ProgramaPortRangePolicy.assignment(defaults: defaults, ordinal: 0),
            ProgramaPortRangeAssignment(start: 9_100, end: 9_109, size: 10)
        )

        defaults.set(12_000, forKey: ProgramaPortRangePolicy.baseDefaultsKey)
        defaults.set(25, forKey: ProgramaPortRangePolicy.rangeDefaultsKey)
        XCTAssertEqual(
            ProgramaPortRangePolicy.assignment(defaults: defaults, ordinal: 1),
            ProgramaPortRangeAssignment(start: 12_025, end: 12_049, size: 25)
        )
    }

    func testPortRangeClampingKeepsCompleteRangeInsideTCPPortSpace() {
        let clamped = ProgramaPortRangePolicy.clamped(base: 70_000, range: 10)
        XCTAssertEqual(clamped.base, 65_535)
        XCTAssertEqual(clamped.range, 1)
        XCTAssertTrue(ProgramaPortRangePolicy.isValid(base: 65_535, range: 1))
        XCTAssertFalse(ProgramaPortRangePolicy.isValid(base: 65_535, range: 2))
    }

    func testApplyManagedTerminalIdentityEnvironmentOverridesInheritedValues() {
        var environment = [
            "TERM": "xterm-ghostty",
            "COLORTERM": "24bit",
            "TERM_PROGRAM": "Apple_Terminal",
            "CUSTOM_FLAG": "1"
        ]
        var protectedKeys: Set<String> = []

        TerminalSurface.applyManagedTerminalIdentityEnvironment(
            to: &environment,
            protectedKeys: &protectedKeys
        )

        XCTAssertEqual(environment["TERM"], TerminalSurface.managedTerminalType)
        XCTAssertEqual(environment["COLORTERM"], TerminalSurface.managedColorTerm)
        XCTAssertEqual(environment["TERM_PROGRAM"], TerminalSurface.managedTerminalProgram)
        XCTAssertEqual(environment["CUSTOM_FLAG"], "1")
        XCTAssertTrue(protectedKeys.contains("TERM"))
        XCTAssertTrue(protectedKeys.contains("COLORTERM"))
        XCTAssertTrue(protectedKeys.contains("TERM_PROGRAM"))
    }

    func testMergedStartupEnvironmentAllowsArbitraryAdditionalAndInitialEnvCMUXKeys() {
        let arbitraryValue = "arbitrary-\(UUID().uuidString)"
        let merged = TerminalSurface.mergedStartupEnvironment(
            base: [
                "PATH": "/usr/bin",
                "PROGRAMA_SURFACE_ID": "managed-surface"
            ],
            protectedKeys: ["PATH", "PROGRAMA_SURFACE_ID"],
            additionalEnvironment: [
                "PROGRAMA_TEST_ADDITIONAL_ENV_KEY": arbitraryValue
            ],
            initialEnvironmentOverrides: [
                "PROGRAMA_INITIAL_ENV_TOKEN": "token-123"
            ]
        )

        XCTAssertEqual(merged["PROGRAMA_TEST_ADDITIONAL_ENV_KEY"], arbitraryValue)
        XCTAssertEqual(merged["PROGRAMA_INITIAL_ENV_TOKEN"], "token-123")
    }

    func testMergedStartupEnvironmentProtectsManagedKeysOnly() {
        let merged = TerminalSurface.mergedStartupEnvironment(
            base: [
                "PATH": "/usr/bin",
                "PROGRAMA_SURFACE_ID": "managed-surface"
            ],
            protectedKeys: ["PATH", "PROGRAMA_SURFACE_ID"],
            additionalEnvironment: [
                "PROGRAMA_SURFACE_ID": "user-surface",
                "CUSTOM_FLAG": "1"
            ],
            initialEnvironmentOverrides: [
                "PATH": "/tmp/bin",
                "PROGRAMA_SURFACE_ID": "override-surface"
            ]
        )

        XCTAssertEqual(merged["PATH"], "/usr/bin")
        XCTAssertEqual(merged["PROGRAMA_SURFACE_ID"], "managed-surface")
        XCTAssertEqual(merged["CUSTOM_FLAG"], "1")
    }

    func testMergedStartupEnvironmentProtectsManagedTerminalIdentity() {
        var baseEnvironment = [
            "PATH": "/usr/bin"
        ]
        var protectedKeys: Set<String> = ["PATH"]
        TerminalSurface.applyManagedTerminalIdentityEnvironment(
            to: &baseEnvironment,
            protectedKeys: &protectedKeys
        )

        let merged = TerminalSurface.mergedStartupEnvironment(
            base: baseEnvironment,
            protectedKeys: protectedKeys,
            additionalEnvironment: [
                "TERM": "xterm-ghostty",
                "COLORTERM": "24bit",
                "TERM_PROGRAM": "Apple_Terminal"
            ],
            initialEnvironmentOverrides: [
                "TERM": "screen-256color",
                "COLORTERM": "false",
                "TERM_PROGRAM": "WarpTerminal"
            ]
        )

        XCTAssertEqual(merged["TERM"], TerminalSurface.managedTerminalType)
        XCTAssertEqual(merged["COLORTERM"], TerminalSurface.managedColorTerm)
        XCTAssertEqual(merged["TERM_PROGRAM"], TerminalSurface.managedTerminalProgram)
    }
}

@MainActor
final class BrowserPanelPopupContextTests: XCTestCase {
    func testFloatingPopupInheritsOpenerBrowserContext() throws {
        let panel = BrowserPanel(workspaceId: UUID())
        let popupWebView = try XCTUnwrap(
            panel.createFloatingPopup(
                configuration: WKWebViewConfiguration(),
                windowFeatures: WKWindowFeatures()
            )
        )
        defer { popupWebView.window?.close() }

        XCTAssertTrue(
            popupWebView.configuration.websiteDataStore === panel.webView.configuration.websiteDataStore
        )
    }

}

final class TitlebarDoubleClickPreferenceTests: XCTestCase {
    func testResolvesZoomForFillPreference() {
        XCTAssertEqual(
            resolvedStandardTitlebarDoubleClickAction(globalDefaults: [
                "AppleActionOnDoubleClick": "Fill",
            ]),
            .zoom
        )
    }

    func testResolvesMiniaturizeForExplicitMinimizePreference() {
        XCTAssertEqual(
            resolvedStandardTitlebarDoubleClickAction(globalDefaults: [
                "AppleActionOnDoubleClick": "Minimize",
            ]),
            .miniaturize
        )
    }

    func testResolvesNoneForNoActionPreference() {
        XCTAssertEqual(
            resolvedStandardTitlebarDoubleClickAction(globalDefaults: [
                "AppleActionOnDoubleClick": "No Action",
            ]),
            .none
        )
    }

    func testFallsBackToLegacyMiniaturizePreference() {
        XCTAssertEqual(
            resolvedStandardTitlebarDoubleClickAction(globalDefaults: [
                "AppleMiniaturizeOnDoubleClick": true,
            ]),
            .miniaturize
        )
    }

    func testDefaultsToZoomWhenPreferenceIsMissing() {
        XCTAssertEqual(
            resolvedStandardTitlebarDoubleClickAction(globalDefaults: [:]),
            .zoom
        )
    }
}

final class WindowBackgroundSelectionGateTests: XCTestCase {
    func testShouldApplyWindowBackgroundUsesOwningWindowSelectionWhenAvailable() {
        let tabId = UUID()
        let activeSelectedTabId = UUID()

        XCTAssertTrue(
            GhosttyNSView.shouldApplyWindowBackground(
                surfaceTabId: tabId,
                owningManagerExists: true,
                owningSelectedTabId: tabId,
                activeSelectedTabId: activeSelectedTabId
            )
        )
    }

    func testShouldApplyWindowBackgroundRejectsWhenOwningSelectionDiffers() {
        let tabId = UUID()

        XCTAssertFalse(
            GhosttyNSView.shouldApplyWindowBackground(
                surfaceTabId: tabId,
                owningManagerExists: true,
                owningSelectedTabId: UUID(),
                activeSelectedTabId: tabId
            )
        )
    }

    func testShouldApplyWindowBackgroundAllowsWhenOwningManagerSelectionIsTemporarilyNil() {
        let tabId = UUID()

        XCTAssertTrue(
            GhosttyNSView.shouldApplyWindowBackground(
                surfaceTabId: tabId,
                owningManagerExists: true,
                owningSelectedTabId: nil,
                activeSelectedTabId: UUID()
            )
        )
    }

    func testShouldApplyWindowBackgroundFallsBackToActiveSelection() {
        let tabId = UUID()

        XCTAssertTrue(
            GhosttyNSView.shouldApplyWindowBackground(
                surfaceTabId: tabId,
                owningManagerExists: false,
                owningSelectedTabId: nil,
                activeSelectedTabId: tabId
            )
        )
        XCTAssertFalse(
            GhosttyNSView.shouldApplyWindowBackground(
                surfaceTabId: tabId,
                owningManagerExists: false,
                owningSelectedTabId: nil,
                activeSelectedTabId: UUID()
            )
        )
    }

    func testShouldApplyWindowBackgroundAllowsWhenNoSelectionContext() {
        XCTAssertTrue(
            GhosttyNSView.shouldApplyWindowBackground(
                surfaceTabId: UUID(),
                owningManagerExists: false,
                owningSelectedTabId: nil,
                activeSelectedTabId: nil
            )
        )
        XCTAssertTrue(
            GhosttyNSView.shouldApplyWindowBackground(
                surfaceTabId: nil,
                owningManagerExists: false,
                owningSelectedTabId: nil,
                activeSelectedTabId: nil
            )
        )
        XCTAssertTrue(
            GhosttyNSView.shouldApplyWindowBackground(
                surfaceTabId: nil,
                owningManagerExists: true,
                owningSelectedTabId: UUID(),
                activeSelectedTabId: UUID()
            )
        )
    }
}

final class NotificationBurstCoalescerTests: XCTestCase {
    func testSignalsInSameBurstFlushOnce() {
        let coalescer = NotificationBurstCoalescer(delay: 0.01)
        let expectation = expectation(description: "flush once")
        expectation.expectedFulfillmentCount = 1
        var flushCount = 0

        DispatchQueue.main.async {
            for _ in 0..<8 {
                coalescer.signal {
                    flushCount += 1
                    expectation.fulfill()
                }
            }
        }

        // A fixed 1s timeout isn't reliable headroom for this 0.01s-delay coalescer
        // under a full serial suite run, where GCD timer firing can be pushed back by
        // system load/backlog from hundreds of prior tests.
        wait(for: [expectation], timeout: 5.0)
        XCTAssertEqual(flushCount, 1)
    }

    func testLatestActionWinsWithinBurst() {
        let coalescer = NotificationBurstCoalescer(delay: 0.01)
        let expectation = expectation(description: "latest action flushed")
        var value = 0

        DispatchQueue.main.async {
            coalescer.signal {
                value = 1
            }
            coalescer.signal {
                value = 2
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 5.0)
        XCTAssertEqual(value, 2)
    }

    func testSignalsAcrossBurstsFlushMultipleTimes() {
        let coalescer = NotificationBurstCoalescer(delay: 0.01)
        let expectation = expectation(description: "flush twice")
        expectation.expectedFulfillmentCount = 2
        var flushCount = 0

        DispatchQueue.main.async {
            coalescer.signal {
                flushCount += 1
                expectation.fulfill()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                coalescer.signal {
                    flushCount += 1
                    expectation.fulfill()
                }
            }
        }

        wait(for: [expectation], timeout: 5.0)
        XCTAssertEqual(flushCount, 2)
    }
}

final class GhosttyDefaultBackgroundNotificationDispatcherTests: XCTestCase {
    func testSignalCoalescesBurstToLatestBackground() {
        guard let dark = NSColor(hex: "#272822"),
              let light = NSColor(hex: "#FDF6E3") else {
            XCTFail("Expected valid test colors")
            return
        }

        let expectation = expectation(description: "coalesced notification")
        expectation.expectedFulfillmentCount = 1
        var postedUserInfos: [[AnyHashable: Any]] = []

        let dispatcher = GhosttyDefaultBackgroundNotificationDispatcher(
            delay: 0.01,
            postNotification: { userInfo in
                postedUserInfos.append(userInfo)
                expectation.fulfill()
            }
        )

        DispatchQueue.main.async {
            dispatcher.signal(backgroundColor: dark, opacity: 0.95, eventId: 1, source: "test.dark")
            dispatcher.signal(backgroundColor: light, opacity: 0.75, eventId: 2, source: "test.light")
        }

        wait(for: [expectation], timeout: 5.0)
        XCTAssertEqual(postedUserInfos.count, 1)
        XCTAssertEqual(
            (postedUserInfos[0][GhosttyNotificationKey.backgroundColor] as? NSColor)?.hexString(),
            "#FDF6E3"
        )
        XCTAssertEqual(
            postedOpacity(from: postedUserInfos[0][GhosttyNotificationKey.backgroundOpacity]),
            0.75,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            (postedUserInfos[0][GhosttyNotificationKey.backgroundEventId] as? NSNumber)?.uint64Value,
            2
        )
        XCTAssertEqual(
            postedUserInfos[0][GhosttyNotificationKey.backgroundSource] as? String,
            "test.light"
        )
    }

    func testSignalAcrossSeparateBurstsPostsMultipleNotifications() {
        guard let dark = NSColor(hex: "#272822"),
              let light = NSColor(hex: "#FDF6E3") else {
            XCTFail("Expected valid test colors")
            return
        }

        let expectation = expectation(description: "two notifications")
        expectation.expectedFulfillmentCount = 2
        var postedHexes: [String] = []

        let dispatcher = GhosttyDefaultBackgroundNotificationDispatcher(
            delay: 0.01,
            postNotification: { userInfo in
                let hex = (userInfo[GhosttyNotificationKey.backgroundColor] as? NSColor)?.hexString() ?? "nil"
                postedHexes.append(hex)
                expectation.fulfill()
            }
        )

        DispatchQueue.main.async {
            dispatcher.signal(backgroundColor: dark, opacity: 1.0, eventId: 1, source: "test.dark")
            // Half a second between signals keeps the two bursts unambiguous even
            // when a loaded CI runner delays the 10ms coalescing flush.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                dispatcher.signal(backgroundColor: light, opacity: 1.0, eventId: 2, source: "test.light")
            }
        }

        wait(for: [expectation], timeout: 15.0)
        XCTAssertEqual(postedHexes, ["#272822", "#FDF6E3"])
    }

    private func postedOpacity(from value: Any?) -> Double {
        if let value = value as? Double {
            return value
        }
        if let value = value as? NSNumber {
            return value.doubleValue
        }
        XCTFail("Expected background opacity payload")
        return -1
    }
}

final class RecentlyClosedBrowserStackTests: XCTestCase {
    func testPopReturnsEntriesInLIFOOrder() {
        var stack = RecentlyClosedBrowserStack(capacity: 20)
        stack.push(makeSnapshot(index: 1))
        stack.push(makeSnapshot(index: 2))
        stack.push(makeSnapshot(index: 3))

        XCTAssertEqual(stack.pop()?.originalTabIndex, 3)
        XCTAssertEqual(stack.pop()?.originalTabIndex, 2)
        XCTAssertEqual(stack.pop()?.originalTabIndex, 1)
        XCTAssertNil(stack.pop())
    }

    func testPushDropsOldestEntriesWhenCapacityExceeded() {
        var stack = RecentlyClosedBrowserStack(capacity: 3)
        for index in 1...5 {
            stack.push(makeSnapshot(index: index))
        }

        XCTAssertEqual(stack.pop()?.originalTabIndex, 5)
        XCTAssertEqual(stack.pop()?.originalTabIndex, 4)
        XCTAssertEqual(stack.pop()?.originalTabIndex, 3)
        XCTAssertNil(stack.pop())
    }

    private func makeSnapshot(index: Int) -> ClosedBrowserPanelRestoreSnapshot {
        ClosedBrowserPanelRestoreSnapshot(
            workspaceId: UUID(),
            url: URL(string: "https://example.com/\(index)"),
            profileID: nil,
            originalPaneId: UUID(),
            originalTabIndex: index,
            fallbackSplitOrientation: .horizontal,
            fallbackSplitInsertFirst: false,
            fallbackAnchorPaneId: UUID()
        )
    }
}

final class SocketControlSettingsTests: XCTestCase {
    func testMigrateModeSupportsExpandedSocketModes() {
        XCTAssertEqual(SocketControlSettings.migrateMode("off"), .off)
        XCTAssertEqual(SocketControlSettings.migrateMode("cmuxOnly"), .cmuxOnly)
        XCTAssertEqual(SocketControlSettings.migrateMode("automation"), .automation)
        XCTAssertEqual(SocketControlSettings.migrateMode("password"), .password)
        XCTAssertEqual(SocketControlSettings.migrateMode("allow-all"), .allowAll)

        // Legacy aliases
        XCTAssertEqual(SocketControlSettings.migrateMode("notifications"), .automation)
        XCTAssertEqual(SocketControlSettings.migrateMode("full"), .allowAll)
    }

    func testSocketModePermissions() {
        XCTAssertEqual(SocketControlMode.off.socketFilePermissions, 0o600)
        XCTAssertEqual(SocketControlMode.cmuxOnly.socketFilePermissions, 0o600)
        XCTAssertEqual(SocketControlMode.automation.socketFilePermissions, 0o600)
        XCTAssertEqual(SocketControlMode.password.socketFilePermissions, 0o600)
        XCTAssertEqual(SocketControlMode.allowAll.socketFilePermissions, 0o666)
    }

    func testInvalidEnvSocketModeDoesNotOverrideUserMode() {
        XCTAssertNil(
            SocketControlSettings.envOverrideMode(
                environment: ["PROGRAMA_SOCKET_MODE": "definitely-not-a-mode"]
            )
        )
        XCTAssertEqual(
            SocketControlSettings.effectiveMode(
                userMode: .password,
                environment: ["PROGRAMA_SOCKET_MODE": "definitely-not-a-mode"]
            ),
            .password
        )
    }

    func testStableReleaseIgnoresAmbientSocketOverrideByDefault() {
        let path = SocketControlSettings.socketPath(
            environment: [
                "PROGRAMA_SOCKET_PATH": "/tmp/programa-debug-issue-153-tmux-compat.sock",
            ],
            bundleIdentifier: "com.darkroom.programa",
            isDebugBuild: false,
            probeStableDefaultPathEntry: { _ in .missing }
        )

        XCTAssertEqual(path, SocketControlSettings.stableDefaultSocketPath)
    }

    func testNightlyReleaseFallsBackToStableDefaultAndIgnoresAmbientSocketOverride() {
        let path = SocketControlSettings.socketPath(
            environment: [
                "PROGRAMA_SOCKET_PATH": "/tmp/programa-debug-issue-153-tmux-compat.sock",
            ],
            bundleIdentifier: "com.darkroom.programa.nightly",
            isDebugBuild: false,
            probeStableDefaultPathEntry: { _ in .missing }
        )

        XCTAssertEqual(path, SocketControlSettings.stableDefaultSocketPath)
    }

    func testDebugBundleHonorsSocketOverrideWithoutOptInFlag() {
        let path = SocketControlSettings.socketPath(
            environment: [
                "PROGRAMA_SOCKET_PATH": "/tmp/programa-debug-my-tag.sock",
            ],
            bundleIdentifier: "com.darkroom.programa.debug.my-tag",
            isDebugBuild: false
        )

        XCTAssertEqual(path, "/tmp/programa-debug-my-tag.sock")
    }

    func testStagingBundleHonorsSocketOverrideWithoutOptInFlag() {
        let path = SocketControlSettings.socketPath(
            environment: [
                "PROGRAMA_SOCKET_PATH": "/tmp/programa-staging-my-tag.sock",
            ],
            bundleIdentifier: "com.darkroom.programa.staging.my-tag",
            isDebugBuild: false
        )

        XCTAssertEqual(path, "/tmp/programa-staging-my-tag.sock")
    }

    func testStableReleaseCanOptInToSocketOverride() {
        let path = SocketControlSettings.socketPath(
            environment: [
                "PROGRAMA_SOCKET_PATH": "/tmp/programa-debug-forced.sock",
                "PROGRAMA_ALLOW_SOCKET_OVERRIDE": "1",
            ],
            bundleIdentifier: "com.darkroom.programa",
            isDebugBuild: false,
            probeStableDefaultPathEntry: { _ in .missing }
        )

        XCTAssertEqual(path, "/tmp/programa-debug-forced.sock")
    }

    func testDefaultSocketPathByChannel() {
        XCTAssertEqual(
            SocketControlSettings.defaultSocketPath(
                bundleIdentifier: "com.darkroom.programa",
                isDebugBuild: false,
                probeStableDefaultPathEntry: { _ in .missing }
            ),
            SocketControlSettings.stableDefaultSocketPath
        )
        XCTAssertEqual(
            SocketControlSettings.defaultSocketPath(
                bundleIdentifier: "com.darkroom.programa.nightly",
                isDebugBuild: false,
                probeStableDefaultPathEntry: { _ in .missing }
            ),
            SocketControlSettings.stableDefaultSocketPath
        )
        XCTAssertEqual(
            SocketControlSettings.defaultSocketPath(
                bundleIdentifier: "com.darkroom.programa.debug.tag",
                isDebugBuild: false,
                probeStableDefaultPathEntry: { _ in .missing }
            ),
            "/tmp/programa-debug-tag.sock"
        )
        XCTAssertEqual(
            SocketControlSettings.defaultSocketPath(
                bundleIdentifier: "com.darkroom.programa.staging.tag",
                isDebugBuild: false,
                probeStableDefaultPathEntry: { _ in .missing }
            ),
            "/tmp/programa-staging.sock"
        )
    }

    func testStableReleaseFallsBackToUserScopedSocketWhenStablePathOwnedByDifferentUser() {
        let path = SocketControlSettings.defaultSocketPath(
            bundleIdentifier: "com.darkroom.programa",
            isDebugBuild: false,
            currentUserID: 501,
            probeStableDefaultPathEntry: { _ in .socket(ownerUserID: 0) }
        )

        XCTAssertEqual(path, SocketControlSettings.userScopedStableSocketPath(currentUserID: 501))
    }

    func testStableReleaseFallsBackToUserScopedSocketWhenStablePathIsBlockedByNonSocketEntry() {
        let path = SocketControlSettings.defaultSocketPath(
            bundleIdentifier: "com.darkroom.programa",
            isDebugBuild: false,
            currentUserID: 501,
            probeStableDefaultPathEntry: { _ in .other(ownerUserID: 501) }
        )

        XCTAssertEqual(path, SocketControlSettings.userScopedStableSocketPath(currentUserID: 501))
    }

    func testUntaggedDebugBundleBlockedWithoutLaunchTag() {
        XCTAssertTrue(
            SocketControlSettings.shouldBlockUntaggedDebugLaunch(
                environment: [:],
                bundleIdentifier: "com.darkroom.programa.debug",
                isDebugBuild: true
            )
        )
    }

    func testUntaggedDebugBundleAllowedWithLaunchTag() {
        XCTAssertFalse(
            SocketControlSettings.shouldBlockUntaggedDebugLaunch(
                environment: ["PROGRAMA_TAG": "tests-v1"],
                bundleIdentifier: "com.darkroom.programa.debug",
                isDebugBuild: true
            )
        )
    }

    func testTaggedDebugBundleAllowedWithoutLaunchTag() {
        XCTAssertFalse(
            SocketControlSettings.shouldBlockUntaggedDebugLaunch(
                environment: [:],
                bundleIdentifier: "com.darkroom.programa.debug.tests-v1",
                isDebugBuild: true
            )
        )
    }

    func testReleaseBuildIgnoresLaunchTagGate() {
        XCTAssertFalse(
            SocketControlSettings.shouldBlockUntaggedDebugLaunch(
                environment: [:],
                bundleIdentifier: "com.darkroom.programa.debug",
                isDebugBuild: false
            )
        )
    }

    func testXCTestLaunchIgnoresLaunchTagGate() {
        XCTAssertFalse(
            SocketControlSettings.shouldBlockUntaggedDebugLaunch(
                environment: ["XCTestConfigurationFilePath": "/tmp/fake.xctestconfiguration"],
                bundleIdentifier: "com.darkroom.programa.debug",
                isDebugBuild: true
            )
        )
    }

    func testXCTestInjectBundleLaunchIgnoresLaunchTagGate() {
        XCTAssertFalse(
            SocketControlSettings.shouldBlockUntaggedDebugLaunch(
                environment: ["XCInjectBundle": "/tmp/fake.xctest"],
                bundleIdentifier: "com.darkroom.programa.debug",
                isDebugBuild: true
            )
        )
    }

    func testXCTestDyldLaunchIgnoresLaunchTagGate() {
        XCTAssertFalse(
            SocketControlSettings.shouldBlockUntaggedDebugLaunch(
                environment: ["DYLD_INSERT_LIBRARIES": "/usr/lib/libXCTestBundleInject.dylib"],
                bundleIdentifier: "com.darkroom.programa.debug",
                isDebugBuild: true
            )
        )
    }

    func testXCUITestLaunchEnvironmentIgnoresLaunchTagGate() {
        // XCUITest launches the app as a separate process without XCTest env vars.
        // The app receives PROGRAMA_UI_TEST_* vars via XCUIApplication.launchEnvironment.
        XCTAssertFalse(
            SocketControlSettings.shouldBlockUntaggedDebugLaunch(
                environment: ["PROGRAMA_UI_TEST_MODE": "1"],
                bundleIdentifier: "com.darkroom.programa.debug",
                isDebugBuild: true
            )
        )
    }
}

final class UITestLaunchManifestTests: XCTestCase {
    func testManifestPathReadsArgumentValue() {
        XCTAssertEqual(
            UITestLaunchManifest.manifestPath(
                from: ["programa", "-cmuxUITestLaunchManifest", "/tmp/programa-ui-test-launch.json"]
            ),
            "/tmp/programa-ui-test-launch.json"
        )
    }

    func testManifestPathReturnsNilWithoutValue() {
        XCTAssertNil(
            UITestLaunchManifest.manifestPath(
                from: ["programa", "-cmuxUITestLaunchManifest"]
            )
        )
    }

    func testApplyIfPresentDecodesEnvironmentPayload() {
        let payload = """
        {"environment":{"PROGRAMA_TAG":"ui-tests-display","PROGRAMA_SOCKET_PATH":"/tmp/programa-ui-tests.sock"}}
        """.data(using: .utf8)!
        var applied: [String: String] = [:]

        UITestLaunchManifest.applyIfPresent(
            arguments: ["programa", UITestLaunchManifest.argumentName, "/tmp/programa-ui-test-launch.json"],
            loadData: { _ in payload },
            applyEnvironment: { key, value in
                applied[key] = value
            }
        )

        XCTAssertEqual(applied["PROGRAMA_TAG"], "ui-tests-display")
        XCTAssertEqual(applied["PROGRAMA_SOCKET_PATH"], "/tmp/programa-ui-tests.sock")
    }
}

final class GhosttyMouseFocusTests: XCTestCase {
    func testShouldRequestFirstResponderForMouseFocusWhenEnabledAndWindowIsActive() {
        XCTAssertTrue(
            GhosttyNSView.shouldRequestFirstResponderForMouseFocus(
                focusFollowsMouseEnabled: true,
                pressedMouseButtons: 0,
                appIsActive: true,
                windowIsKey: true,
                alreadyFirstResponder: false,
                visibleInUI: true,
                hasUsableGeometry: true,
                hiddenInHierarchy: false
            )
        )
    }

    func testShouldNotRequestFirstResponderWhenFocusFollowsMouseDisabled() {
        XCTAssertFalse(
            GhosttyNSView.shouldRequestFirstResponderForMouseFocus(
                focusFollowsMouseEnabled: false,
                pressedMouseButtons: 0,
                appIsActive: true,
                windowIsKey: true,
                alreadyFirstResponder: false,
                visibleInUI: true,
                hasUsableGeometry: true,
                hiddenInHierarchy: false
            )
        )
    }

    func testShouldNotRequestFirstResponderDuringMouseDrag() {
        XCTAssertFalse(
            GhosttyNSView.shouldRequestFirstResponderForMouseFocus(
                focusFollowsMouseEnabled: true,
                pressedMouseButtons: 1,
                appIsActive: true,
                windowIsKey: true,
                alreadyFirstResponder: false,
                visibleInUI: true,
                hasUsableGeometry: true,
                hiddenInHierarchy: false
            )
        )
    }

    func testShouldNotRequestFirstResponderWhenViewCannotSafelyReceiveFocus() {
        XCTAssertFalse(
            GhosttyNSView.shouldRequestFirstResponderForMouseFocus(
                focusFollowsMouseEnabled: true,
                pressedMouseButtons: 0,
                appIsActive: true,
                windowIsKey: true,
                alreadyFirstResponder: false,
                visibleInUI: true,
                hasUsableGeometry: false,
                hiddenInHierarchy: false
            )
        )
        XCTAssertFalse(
            GhosttyNSView.shouldRequestFirstResponderForMouseFocus(
                focusFollowsMouseEnabled: true,
                pressedMouseButtons: 0,
                appIsActive: true,
                windowIsKey: true,
                alreadyFirstResponder: false,
                visibleInUI: true,
                hasUsableGeometry: true,
                hiddenInHierarchy: true
            )
        )
    }

    // MARK: - CJK Font Fallback

    private func withTempConfig(
        _ contents: String,
        body: (String) -> Void
    ) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-test-cjk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("config")
        try contents.write(to: file, atomically: true, encoding: .utf8)
        body(file.path)
    }

    // MARK: cjkFontMappings

    func testCJKFontMappingsReturnsHiraginoWithKanaForJapanese() {
        let mappings = GhosttyApp.cjkFontMappings(preferredLanguages: ["ja-JP", "en-US"])!
        let fonts = Set(mappings.map(\.1))
        let ranges = mappings.map(\.0)

        XCTAssertTrue(fonts.contains("Hiragino Sans"))
        XCTAssertTrue(ranges.contains("U+3040-U+309F"), "Should include Hiragana")
        XCTAssertTrue(ranges.contains("U+30A0-U+30FF"), "Should include Katakana")
        XCTAssertTrue(ranges.contains("U+4E00-U+9FFF"), "Should include CJK Ideographs")
        XCTAssertFalse(ranges.contains("U+AC00-U+D7AF"), "Should NOT include Hangul")
    }

    func testCJKFontMappingsReturnsNilForKoreanOnly() {
        // Korean is not auto-mapped — Ghostty's native CTFontCreateForString
        // fallback selects a better-matching font for Hangul.
        XCTAssertNil(GhosttyApp.cjkFontMappings(preferredLanguages: ["ko-KR"]))
    }

    func testCJKFontMappingsReturnsPingFangForChinese() {
        let mappingsTW = GhosttyApp.cjkFontMappings(preferredLanguages: ["zh-Hant-TW"])!
        XCTAssertTrue(mappingsTW.contains { $0.1 == "PingFang TC" })

        let mappingsCN = GhosttyApp.cjkFontMappings(preferredLanguages: ["zh-Hans-CN"])!
        XCTAssertTrue(mappingsCN.contains { $0.1 == "PingFang SC" })

        let mappingsHK = GhosttyApp.cjkFontMappings(preferredLanguages: ["zh-HK"])!
        XCTAssertTrue(mappingsHK.contains { $0.1 == "PingFang TC" })
    }

    func testCJKFontMappingsReturnsNilForNonCJKLanguages() {
        XCTAssertNil(GhosttyApp.cjkFontMappings(preferredLanguages: ["en-US", "fr-FR"]))
        XCTAssertNil(GhosttyApp.cjkFontMappings(preferredLanguages: []))
    }

    func testCJKFontMappingsMultiLanguageSkipsKorean() {
        // When both ja and ko are preferred, only Japanese mappings are generated.
        // Korean is left to Ghostty's native CTFontCreateForString fallback.
        let mappings = GhosttyApp.cjkFontMappings(preferredLanguages: ["ja-JP", "ko-KR"])!

        let hiraginoRanges = mappings.filter { $0.1 == "Hiragino Sans" }.map(\.0)

        XCTAssertTrue(hiraginoRanges.contains("U+3040-U+309F"), "Hiragana → Hiragino")
        XCTAssertTrue(hiraginoRanges.contains("U+4E00-U+9FFF"), "Shared CJK → first lang font")
        XCTAssertFalse(mappings.contains { $0.1 == "Apple SD Gothic Neo" }, "No Korean font mapping")
        XCTAssertFalse(hiraginoRanges.contains("U+AC00-U+D7AF"), "Hangul NOT in Hiragino")
    }

    // MARK: autoInjectedCJKFontMappings

    func testAutoInjectedCJKFontMappingsSkipsRangesCoveredByConfiguredPrimaryFont() throws {
        let coveredRanges: Set<String> = [
            "U+3000-U+303F",
            "U+4E00-U+9FFF",
            "U+F900-U+FAFF",
            "U+FF00-U+FFEF",
            "U+3400-U+4DBF",
        ]

        try withTempConfig("font-family = Sarasa Mono K\n") { path in
            XCTAssertNil(
                GhosttyApp.autoInjectedCJKFontMappings(
                    preferredLanguages: ["zh-Hans-CN"],
                    configPaths: [path],
                    rangeCoverageProbe: { fontFamily, range in
                        XCTAssertEqual(fontFamily, "Sarasa Mono K")
                        return coveredRanges.contains(range)
                    }
                )
            )
        }
    }

    func testAutoInjectedCJKFontMappingsKeepsOnlyUncoveredRanges() throws {
        let coveredRanges: Set<String> = [
            "U+3000-U+303F",
            "U+4E00-U+9FFF",
            "U+F900-U+FAFF",
            "U+FF00-U+FFEF",
            "U+3400-U+4DBF",
        ]

        try withTempConfig("font-family = Example CJK Mono\n") { path in
            let mappings = GhosttyApp.autoInjectedCJKFontMappings(
                preferredLanguages: ["ja-JP"],
                configPaths: [path],
                rangeCoverageProbe: { _, range in
                    coveredRanges.contains(range)
                }
            )!

            XCTAssertEqual(Set(mappings.map(\.0)), Set(["U+3040-U+309F", "U+30A0-U+30FF"]))
            XCTAssertEqual(Set(mappings.map(\.1)), Set(["Hiragino Sans"]))
        }
    }

    // MARK: userConfigContainsCJKCodepointMap

    func testUserConfigContainsCJKCodepointMapDetectsPresence() throws {
        try withTempConfig("font-family = Menlo\nfont-codepoint-map = U+3000-U+9FFF=Hiragino Sans\n") { path in
            XCTAssertTrue(GhosttyApp.userConfigContainsCJKCodepointMap(configPaths: [path]))
        }
    }

    func testUserConfigContainsCJKCodepointMapReturnsFalseWhenAbsent() throws {
        try withTempConfig("font-family = Menlo\nfont-size = 14\n") { path in
            XCTAssertFalse(GhosttyApp.userConfigContainsCJKCodepointMap(configPaths: [path]))
        }
    }

    func testUserConfigContainsCJKCodepointMapIgnoresComments() throws {
        try withTempConfig("# font-codepoint-map = U+3000-U+9FFF=Hiragino Sans\n") { path in
            XCTAssertFalse(GhosttyApp.userConfigContainsCJKCodepointMap(configPaths: [path]))
        }
    }

    func testUserConfigContainsCJKCodepointMapReturnsFalseForMissingFiles() {
        let path = NSTemporaryDirectory() + "cmux-nonexistent-\(UUID().uuidString)/config"
        XCTAssertFalse(
            GhosttyApp.userConfigContainsCJKCodepointMap(configPaths: [path])
        )
    }

    func testUserConfigContainsCJKCodepointMapFollowsConfigFileIncludes() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-test-cjk-include-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let included = dir.appendingPathComponent("fonts.conf")
        try "font-codepoint-map = U+3000-U+9FFF=Hiragino Sans\n"
            .write(to: included, atomically: true, encoding: .utf8)

        let main = dir.appendingPathComponent("config")
        try "font-family = Menlo\nconfig-file = \(included.path)\n"
            .write(to: main, atomically: true, encoding: .utf8)

        XCTAssertTrue(GhosttyApp.userConfigContainsCJKCodepointMap(configPaths: [main.path]))
    }

    func testUserConfigContainsCJKCodepointMapFollowsRelativeIncludes() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-test-cjk-rel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let included = dir.appendingPathComponent("fonts.conf")
        try "font-codepoint-map = U+4E00-U+9FFF=Hiragino Sans\n"
            .write(to: included, atomically: true, encoding: .utf8)

        let main = dir.appendingPathComponent("config")
        try "config-file = fonts.conf\n"
            .write(to: main, atomically: true, encoding: .utf8)

        XCTAssertTrue(GhosttyApp.userConfigContainsCJKCodepointMap(configPaths: [main.path]))
    }

    func testUserConfigContainsCJKCodepointMapHandlesOptionalInclude() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-test-cjk-opt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let included = dir.appendingPathComponent("fonts.conf")
        try "font-codepoint-map = U+4E00-U+9FFF=Hiragino Sans\n"
            .write(to: included, atomically: true, encoding: .utf8)

        let main = dir.appendingPathComponent("config")
        try "config-file = ?\(included.path)\n"
            .write(to: main, atomically: true, encoding: .utf8)

        XCTAssertTrue(GhosttyApp.userConfigContainsCJKCodepointMap(configPaths: [main.path]))
    }

    func testUserConfigContainsCJKCodepointMapHandlesCyclicIncludes() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-test-cjk-cycle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileA = dir.appendingPathComponent("a.conf")
        let fileB = dir.appendingPathComponent("b.conf")
        try "config-file = \(fileB.path)\n"
            .write(to: fileA, atomically: true, encoding: .utf8)
        try "config-file = \(fileA.path)\n"
            .write(to: fileB, atomically: true, encoding: .utf8)

        // Should not hang; should return false since neither file has font-codepoint-map
        XCTAssertFalse(GhosttyApp.userConfigContainsCJKCodepointMap(configPaths: [fileA.path]))
    }

    func testUserConfigContainsCJKCodepointMapRespectsReset() throws {
        try withTempConfig("""
        font-codepoint-map = U+4E00-U+9FFF=Hiragino Sans
        font-codepoint-map =
        """) { path in
            XCTAssertFalse(
                GhosttyApp.userConfigContainsCJKCodepointMap(configPaths: [path])
            )
        }
    }

    // MARK: userConfigHasExplicitFontFamilyFallbackChain

    func testUserConfigHasExplicitFontFamilyFallbackChainDetectsMultipleEntries() throws {
        try withTempConfig("""
        font-family = JetBrains Mono
        font-family = LXGW WenKai Mono TC
        """) { path in
            XCTAssertTrue(
                GhosttyApp.userConfigHasExplicitFontFamilyFallbackChain(configPaths: [path])
            )
        }
    }

    func testUserConfigHasExplicitFontFamilyFallbackChainFollowsConfigFileIncludes() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-test-cjk-font-family-include-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let included = dir.appendingPathComponent("fonts.conf")
        try "font-family = LXGW WenKai Mono TC\n"
            .write(to: included, atomically: true, encoding: .utf8)

        let main = dir.appendingPathComponent("config")
        try "font-family = JetBrains Mono\nconfig-file = \(included.path)\n"
            .write(to: main, atomically: true, encoding: .utf8)

        XCTAssertTrue(
            GhosttyApp.userConfigHasExplicitFontFamilyFallbackChain(configPaths: [main.path])
        )
    }

    func testUserConfigHasExplicitFontFamilyFallbackChainRespectsFontFamilyReset() throws {
        try withTempConfig("""
        font-family = JetBrains Mono
        font-family =
        font-family = LXGW WenKai Mono TC
        """) { path in
            XCTAssertFalse(
                GhosttyApp.userConfigHasExplicitFontFamilyFallbackChain(configPaths: [path])
            )
        }
    }

    func testUserConfigHasExplicitFontFamilyFallbackChainIgnoresDuplicateFamilies() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-test-cjk-font-family-duplicate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let legacy = dir.appendingPathComponent("config")
        try "font-family = JetBrains Mono\n"
            .write(to: legacy, atomically: true, encoding: .utf8)

        let preferred = dir.appendingPathComponent("config.ghostty")
        try "font-family = JetBrains Mono\n"
            .write(to: preferred, atomically: true, encoding: .utf8)

        XCTAssertFalse(
            GhosttyApp.userConfigHasExplicitFontFamilyFallbackChain(
                configPaths: [legacy.path, preferred.path]
            )
        )
    }

    func testUserConfigHasExplicitFontFamilyFallbackChainMatchesGhosttyIncludeLoadOrder() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-test-cjk-font-family-order-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let included = dir.appendingPathComponent("fonts.conf")
        try "font-family = LXGW WenKai Mono TC\n"
            .write(to: included, atomically: true, encoding: .utf8)

        let main = dir.appendingPathComponent("config")
        try "font-family = JetBrains Mono\nconfig-file = \(included.path)\n"
            .write(to: main, atomically: true, encoding: .utf8)

        let reset = dir.appendingPathComponent("config.ghostty")
        try "font-family =\n"
            .write(to: reset, atomically: true, encoding: .utf8)

        XCTAssertFalse(
            GhosttyApp.userConfigHasExplicitFontFamilyFallbackChain(
                configPaths: [main.path, reset.path]
            )
        )
    }

    func testUserConfigHasExplicitFontFamilyFallbackChainRespectsConfigFileReset() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-test-cjk-font-family-config-file-reset-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let included = dir.appendingPathComponent("fonts.conf")
        try "font-family = LXGW WenKai Mono TC\n"
            .write(to: included, atomically: true, encoding: .utf8)

        let main = dir.appendingPathComponent("config")
        try "font-family = JetBrains Mono\nconfig-file = \(included.path)\n"
            .write(to: main, atomically: true, encoding: .utf8)

        let reset = dir.appendingPathComponent("config.ghostty")
        try "config-file =\n"
            .write(to: reset, atomically: true, encoding: .utf8)

        XCTAssertFalse(
            GhosttyApp.userConfigHasExplicitFontFamilyFallbackChain(
                configPaths: [main.path, reset.path]
            )
        )
    }

    // MARK: shouldInjectCJKFontFallback

    func testShouldInjectCJKFontFallbackSkipsExplicitMultiFontFallbackChain() throws {
        try withTempConfig("""
        font-family = JetBrains Mono
        font-family = LXGW WenKai Mono TC
        """) { path in
            XCTAssertFalse(
                GhosttyApp.shouldInjectCJKFontFallback(
                    preferredLanguages: ["zh-Hans-CN"],
                    configPaths: [path]
                )
            )
        }
    }

    func testShouldInjectCJKFontFallbackAllowsSingleFontWithoutExplicitOverrides() throws {
        try withTempConfig("font-family = JetBrains Mono\n") { path in
            XCTAssertTrue(
                GhosttyApp.shouldInjectCJKFontFallback(
                    preferredLanguages: ["zh-Hans-CN"],
                    configPaths: [path]
                )
            )
        }
    }

    func testShouldInjectCJKFontFallbackSkipsConfiguredFontThatAlreadyCoversMappedRanges() throws {
        let coveredRanges: Set<String> = [
            "U+3000-U+303F",
            "U+4E00-U+9FFF",
            "U+F900-U+FAFF",
            "U+FF00-U+FFEF",
            "U+3400-U+4DBF",
        ]

        try withTempConfig("font-family = Sarasa Mono K\n") { path in
            XCTAssertFalse(
                GhosttyApp.shouldInjectCJKFontFallback(
                    preferredLanguages: ["zh-Hans-CN"],
                    configPaths: [path],
                    rangeCoverageProbe: { fontFamily, range in
                        XCTAssertEqual(fontFamily, "Sarasa Mono K")
                        return coveredRanges.contains(range)
                    }
                )
            )
        }
    }

    func testLoadedCJKScanPathsSkipsReleaseAppSupportWhenTaggedConfigExists() throws {
        let appSupport = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-test-cjk-app-support-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: appSupport) }

        let taggedDir = appSupport.appendingPathComponent("com.example.cmux-dev", isDirectory: true)
        try FileManager.default.createDirectory(at: taggedDir, withIntermediateDirectories: true)
        let taggedConfig = taggedDir.appendingPathComponent("config", isDirectory: false)
        try "font-family = JetBrains Mono\n"
            .write(to: taggedConfig, atomically: true, encoding: .utf8)

        let releaseDir = appSupport.appendingPathComponent("com.mitchellh.ghostty", isDirectory: true)
        try FileManager.default.createDirectory(at: releaseDir, withIntermediateDirectories: true)
        let releaseConfig = releaseDir.appendingPathComponent("config", isDirectory: false)
        try "font-family = LXGW WenKai Mono TC\n"
            .write(to: releaseConfig, atomically: true, encoding: .utf8)

        let paths = GhosttyApp.loadedCJKScanPaths(
            currentBundleIdentifier: "com.example.cmux-dev",
            appSupportDirectory: appSupport
        )

        XCTAssertTrue(paths.contains(taggedConfig.path))
        XCTAssertFalse(paths.contains(releaseConfig.path))
        XCTAssertTrue(
            GhosttyApp.shouldInjectCJKFontFallback(
                preferredLanguages: ["zh-Hans-CN"],
                configPaths: paths
            )
        )
    }
}

final class SidebarBackgroundConfigTests: XCTestCase {

    func testParseSidebarBackgroundSingleHex() {
        var config = GhosttyConfig()
        config.parse("sidebar-background = #336699")
        XCTAssertEqual(config.rawSidebarBackground, "#336699")
    }

    func testParseSidebarBackgroundDualMode() {
        var config = GhosttyConfig()
        config.parse("sidebar-background = light:#fbf3db,dark:#103c48")
        XCTAssertEqual(config.rawSidebarBackground, "light:#fbf3db,dark:#103c48")
    }

    func testParseSidebarTintOpacity() {
        var config = GhosttyConfig()
        config.parse("sidebar-tint-opacity = 0.4")
        XCTAssertEqual(config.sidebarTintOpacity ?? -1, 0.4, accuracy: 0.0001)
    }

    func testParseSidebarTintOpacityClampedAboveOne() {
        var config = GhosttyConfig()
        config.parse("sidebar-tint-opacity = 1.5")
        XCTAssertEqual(config.sidebarTintOpacity ?? -1, 1.0, accuracy: 0.0001)
    }

    func testParseSidebarTintOpacityClampedBelowZero() {
        var config = GhosttyConfig()
        config.parse("sidebar-tint-opacity = -0.3")
        XCTAssertEqual(config.sidebarTintOpacity ?? -1, 0.0, accuracy: 0.0001)
    }

    func testResolveSidebarBackgroundSingleHex() {
        var config = GhosttyConfig()
        config.rawSidebarBackground = "#336699"
        config.resolveSidebarBackground(preferredColorScheme: .light)

        XCTAssertNotNil(config.sidebarBackground)
        XCTAssertNil(config.sidebarBackgroundLight)
        XCTAssertNil(config.sidebarBackgroundDark)
    }

    func testResolveSidebarBackgroundDualModeSetsLightAndDark() {
        var config = GhosttyConfig()
        config.rawSidebarBackground = "light:#fbf3db,dark:#103c48"
        config.resolveSidebarBackground(preferredColorScheme: .light)

        XCTAssertNotNil(config.sidebarBackgroundLight)
        XCTAssertNotNil(config.sidebarBackgroundDark)
        XCTAssertNotNil(config.sidebarBackground)
    }

    func testResolveSidebarBackgroundNilWhenNoRaw() {
        var config = GhosttyConfig()
        config.resolveSidebarBackground(preferredColorScheme: .dark)

        XCTAssertNil(config.sidebarBackground)
        XCTAssertNil(config.sidebarBackgroundLight)
        XCTAssertNil(config.sidebarBackgroundDark)
    }

    func testApplyToUserDefaultsSkipsWritesWhenNoConfig() {
        let defaults = UserDefaults.standard
        let testKey = "sidebarTintHex"
        let original = defaults.string(forKey: testKey)
        defer { restoreDefaultsValue(original, key: testKey, defaults: defaults) }

        defaults.set("#AAAAAA", forKey: testKey)

        var config = GhosttyConfig()
        config.applySidebarAppearanceToUserDefaults()

        XCTAssertEqual(defaults.string(forKey: testKey), "#AAAAAA",
                       "Should not overwrite UserDefaults when rawSidebarBackground is nil")
    }

    func testApplyToUserDefaultsWritesHexWhenConfigSet() {
        let defaults = UserDefaults.standard
        let keys = ["sidebarTintHex", "sidebarTintHexLight", "sidebarTintHexDark"]
        let originals = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, original) in zip(keys, originals) {
                restoreDefaultsValue(original, key: key, defaults: defaults)
            }
        }

        var config = GhosttyConfig()
        config.rawSidebarBackground = "#336699"
        config.resolveSidebarBackground(preferredColorScheme: .light)
        config.applySidebarAppearanceToUserDefaults()

        XCTAssertEqual(defaults.string(forKey: "sidebarTintHex"), "#336699")
        XCTAssertNil(defaults.string(forKey: "sidebarTintHexLight"))
        XCTAssertNil(defaults.string(forKey: "sidebarTintHexDark"))
    }

    func testApplyToUserDefaultsClearsStaleKeysOnSwitchFromDualToSingle() {
        let defaults = UserDefaults.standard
        let keys = ["sidebarTintHex", "sidebarTintHexLight", "sidebarTintHexDark"]
        let originals = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, original) in zip(keys, originals) {
                restoreDefaultsValue(original, key: key, defaults: defaults)
            }
        }

        defaults.set("#AAAAAA", forKey: "sidebarTintHexLight")
        defaults.set("#BBBBBB", forKey: "sidebarTintHexDark")

        var config = GhosttyConfig()
        config.rawSidebarBackground = "#222222"
        config.resolveSidebarBackground(preferredColorScheme: .light)
        config.applySidebarAppearanceToUserDefaults()

        XCTAssertEqual(defaults.string(forKey: "sidebarTintHex"), "#222222")
        XCTAssertNil(defaults.string(forKey: "sidebarTintHexLight"),
                     "Stale light key should be cleared")
        XCTAssertNil(defaults.string(forKey: "sidebarTintHexDark"),
                     "Stale dark key should be cleared")
    }

    func testApplyToUserDefaultsOnlyWritesOpacityWhenExplicit() {
        let defaults = UserDefaults.standard
        let keys = ["sidebarTintHex", "sidebarTintHexLight", "sidebarTintHexDark", "sidebarTintOpacity"]
        let originals = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, original) in zip(keys, originals) {
                restoreDefaultsValue(original, key: key, defaults: defaults)
            }
        }

        defaults.set(0.18, forKey: "sidebarTintOpacity")

        var config = GhosttyConfig()
        config.rawSidebarBackground = "#336699"
        config.resolveSidebarBackground(preferredColorScheme: .light)
        config.applySidebarAppearanceToUserDefaults()

        XCTAssertEqual(defaults.double(forKey: "sidebarTintOpacity"), 0.18, accuracy: 0.0001,
                       "Should not overwrite opacity when config doesn't set sidebar-tint-opacity")
    }

    private func restoreDefaultsValue(_ value: Any?, key: String, defaults: UserDefaults) {
        if let value = value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}

final class ZshShellIntegrationHandoffTests: XCTestCase {
    func testLocalTTYReportRetriesDeniedCLIThenDeduplicatesAcknowledgmentInZsh() throws {
        let fixture = try LocalTTYReportFixture()
        let output = try runInteractiveZsh(
            cmuxLoadGhosttyIntegration: false, cmuxLoadShellIntegration: true,
            command: fixture.posixCommand, extraEnvironment: fixture.environment
        )
        XCTAssertTrue(output.contains("TTY_ATTEMPTS=2"), output)
        XCTAssertTrue(output.contains("TTY_STATES=0,1,1"), output)
    }

    func testLocalTTYReportRetriesDeniedCLIThenDeduplicatesAcknowledgmentInBash() throws {
        let fixture = try LocalTTYReportFixture()
        let output = try runInteractiveBash(
            cmuxLoadShellIntegration: true, command: fixture.posixCommand,
            extraEnvironment: fixture.environment
        )
        XCTAssertTrue(output.stdout.contains("TTY_ATTEMPTS=2"), output.stdout + output.stderr)
        XCTAssertTrue(output.stdout.contains("TTY_STATES=0,1,1"), output.stdout + output.stderr)
    }
    func testGhosttyPromptHooksLoadWhenProgramaRequestsZshIntegration() throws {
        let output = try runInteractiveZsh(cmuxLoadGhosttyIntegration: true)

        XCTAssertTrue(output.contains("PRECMD=1"), output)
        XCTAssertTrue(output.contains("PREEXEC=1"), output)
        XCTAssertTrue(output.contains("PRECMDS=_ghostty_precmd"), output)
    }

    func testGhosttyPromptHooksDoNotLoadWithoutProgramaHandoffFlag() throws {
        let output = try runInteractiveZsh(cmuxLoadGhosttyIntegration: false)

        XCTAssertTrue(output.contains("PRECMD=0"), output)
        XCTAssertTrue(output.contains("PREEXEC=0"), output)
    }

    func testGhosttySemanticPatchRetriesAfterDeferredInitCreatesLiveHooks() throws {
        let output = try runInteractiveZsh(
            cmuxLoadGhosttyIntegration: true,
            cmuxLoadShellIntegration: true,
            command: """
            _cmux_patch_ghostty_semantic_redraw
            (( $+functions[_ghostty_deferred_init] )) && _ghostty_deferred_init >/dev/null 2>&1
            _cmux_patch_ghostty_semantic_redraw
            print -r -- "PRECMD_BODY=${functions[_ghostty_precmd]}"
            print -r -- "PREEXEC_BODY=${functions[_ghostty_preexec]}"
            """
        )

        XCTAssertTrue(output.contains("PRECMD_BODY="), output)
        XCTAssertTrue(output.contains("PREEXEC_BODY="), output)
        XCTAssertTrue(output.contains("133;A;redraw=last;cl=line"), output)
    }

    func testShellIntegrationWinchGuardDoesNotPrintSpacerLineOnResize() throws {
        let output = try runInteractiveZsh(
            cmuxLoadGhosttyIntegration: false,
            cmuxLoadShellIntegration: true,
            command: """
            print -r -- BEFORE
            TRAPWINCH
            print -r -- AFTER
            """
        )

        XCTAssertEqual(output, "BEFORE\nAFTER", output)
    }

    func testShellIntegrationPreservesStartupTermForThemeSelectionBeforeRestoringManagedTerm() throws {
        let output = try runPromptInteractiveZsh(
            cmuxLoadGhosttyIntegration: false,
            cmuxLoadShellIntegration: true,
            command: """
            print -r -- "CMD=$TERM|${PROGRAMA_ZSH_RESTORE_TERM-unset}" >> "$PROGRAMA_TEST_OUTPUT"
            """,
            userZshRCContents: """
            export PROGRAMA_STARTUP_THEME_TERM="$TERM"
            if [[ $TERM = (*256color|*rxvt*) ]]; then
              export PROGRAMA_STARTUP_THEME_BRANCH=extended
            else
              export PROGRAMA_STARTUP_THEME_BRANCH=basic
            fi

            cmux_test_ready() {
              # Run once: precmd fires again before the next prompt (e.g. right
              # before "exit" is read), which would otherwise clobber this
              # snapshot with post-restoration TERM values before the test
              # harness's own "CMD=..." append runs.
              precmd_functions=(${precmd_functions:#cmux_test_ready})
              print -r -- "PRE=$PROGRAMA_STARTUP_THEME_TERM|$PROGRAMA_STARTUP_THEME_BRANCH|$TERM|${PROGRAMA_ZSH_RESTORE_TERM-unset}" > "$PROGRAMA_TEST_OUTPUT"
              : > "$PROGRAMA_TEST_READY"
            }
            precmd_functions+=(cmux_test_ready)
            """
        )

        XCTAssertEqual(
            output,
            "PRE=xterm-ghostty|basic|xterm-ghostty|xterm-256color\nCMD=xterm-256color|unset",
            output
        )
    }

    func testShellIntegrationDoesNotSpoofManagedTermForInteractiveCommandMode() throws {
        let output = try runInteractiveZsh(
            cmuxLoadGhosttyIntegration: false,
            cmuxLoadShellIntegration: true,
            command: """
            print -r -- "$PROGRAMA_STARTUP_TERM|$TERM|${PROGRAMA_ZSH_RESTORE_TERM-unset}"
            """,
            userZshRCContents: """
            export PROGRAMA_STARTUP_TERM="$TERM"
            """
        )

        XCTAssertEqual(output, "xterm-256color|xterm-256color|unset", output)
    }

    func testShellIntegrationDoesNotSpoofManagedTermWhenIntegrationDisabled() throws {
        let output = try runInteractiveZsh(
            cmuxLoadGhosttyIntegration: false,
            cmuxLoadShellIntegration: false,
            command: """
            print -r -- "$PROGRAMA_STARTUP_TERM|$TERM|${PROGRAMA_ZSH_RESTORE_TERM-unset}"
            """,
            userZshRCContents: """
            export PROGRAMA_STARTUP_TERM="$TERM"
            """
        )

        XCTAssertEqual(output, "xterm-256color|xterm-256color|unset", output)
    }

    func testShellIntegrationDoesNotSpoofManagedTermWhenUserZshEnvDisablesIntegration() throws {
        let output = try runInteractiveZsh(
            cmuxLoadGhosttyIntegration: false,
            cmuxLoadShellIntegration: true,
            command: """
            print -r -- "$PROGRAMA_STARTUP_TERM|$TERM|${PROGRAMA_ZSH_RESTORE_TERM-unset}|${PROGRAMA_SHELL_INTEGRATION:-unset}"
            """,
            userZshEnvContents: """
            export PROGRAMA_SHELL_INTEGRATION=0
            """,
            userZshRCContents: """
            export PROGRAMA_STARTUP_TERM="$TERM"
            """
        )

        XCTAssertEqual(output, "xterm-256color|xterm-256color|unset|0", output)
    }

    func testShellIntegrationDoesNotRegisterPromptTimeTermRestoreHooks() throws {
        let output = try runInteractiveZsh(
            cmuxLoadGhosttyIntegration: false,
            cmuxLoadShellIntegration: true,
            command: """
            print -r -- "${(j:,:)precmd_functions}"
            """
        )

        XCTAssertEqual(
            output,
            "_cmux_precmd,_cmux_fix_path",
            output
        )
    }

    func testShellIntegrationRestoresManagedTermDuringPreexec() throws {
        let output = try runInteractiveZsh(
            cmuxLoadGhosttyIntegration: false,
            cmuxLoadShellIntegration: true,
            command: """
            _cmux_preexec 'echo $TERM'
            print -r -- "$TERM|${PROGRAMA_ZSH_RESTORE_TERM-unset}"
            """,
            extraEnvironment: [
                "TERM": "xterm-ghostty",
                "PROGRAMA_ZSH_RESTORE_TERM": "xterm-256color",
            ]
        )

        XCTAssertEqual(
            output,
            "xterm-256color|unset",
            output
        )
    }

    func testShellIntegrationPublishesOnlyWorkspaceScopedProgramaEnvironmentToTmuxServerAutomatically() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-zsh-tmux-publish-\(UUID().uuidString)")
        let binDir = root.appendingPathComponent("bin", isDirectory: true)
        let logPath = root.appendingPathComponent("tmux.log", isDirectory: false)

        try fileManager.createDirectory(at: binDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try writeExecutableScript(
            at: binDir.appendingPathComponent("tmux", isDirectory: false),
            contents: """
            #!/bin/sh
            if [ "$1" = "show-environment" ] && [ "$2" = "-g" ]; then
              exit 0
            fi
            printf '%s\\n' "$*" >> "\(logPath.path)"
            exit 0
            """
        )

        _ = try runInteractiveZsh(
            cmuxLoadGhosttyIntegration: false,
            cmuxLoadShellIntegration: true,
            command: "_cmux_preexec tmux; print -r -- READY",
            extraEnvironment: [
                "PATH": "\(binDir.path):/usr/bin:/bin:/usr/sbin:/sbin",
                "PROGRAMA_SOCKET_PATH": "/tmp/programa-current.sock",
                "PROGRAMA_TAG": "feat-tmux-notification-attention-state",
                "PROGRAMA_WORKSPACE_ID": "11111111-1111-1111-1111-111111111111",
                "PROGRAMA_SURFACE_ID": "22222222-2222-2222-2222-222222222222",
                "PROGRAMA_TAB_ID": "11111111-1111-1111-1111-111111111111",
                "PROGRAMA_PANEL_ID": "22222222-2222-2222-2222-222222222222",
            ]
        )

        let log = (try? String(contentsOf: logPath, encoding: .utf8)) ?? ""
        XCTAssertTrue(log.contains("set-environment -g PROGRAMA_TAG feat-tmux-notification-attention-state"), log)
        XCTAssertTrue(log.contains("set-environment -g PROGRAMA_SOCKET_PATH /tmp/programa-current.sock"), log)
        XCTAssertTrue(log.contains("set-environment -g PROGRAMA_WORKSPACE_ID 11111111-1111-1111-1111-111111111111"), log)
        XCTAssertFalse(log.contains("set-environment -g PROGRAMA_SURFACE_ID"), log)
        XCTAssertFalse(log.contains("set-environment -g PROGRAMA_PANEL_ID"), log)
    }

    func testShellIntegrationClearsStaleSurfaceScopedTmuxEnvironmentAutomatically() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-zsh-tmux-clear-\(UUID().uuidString)")
        let binDir = root.appendingPathComponent("bin", isDirectory: true)
        let logPath = root.appendingPathComponent("tmux.log", isDirectory: false)

        try fileManager.createDirectory(at: binDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try writeExecutableScript(
            at: binDir.appendingPathComponent("tmux", isDirectory: false),
            contents: """
            #!/bin/sh
            if [ "$1" = "show-environment" ] && [ "$2" = "-g" ]; then
              printf '%s\\n' 'PROGRAMA_SURFACE_ID=99999999-9999-9999-9999-999999999999'
              printf '%s\\n' 'PROGRAMA_PANEL_ID=99999999-9999-9999-9999-999999999999'
              exit 0
            fi
            printf '%s\\n' "$*" >> "\(logPath.path)"
            exit 0
            """
        )

        _ = try runInteractiveZsh(
            cmuxLoadGhosttyIntegration: false,
            cmuxLoadShellIntegration: true,
            command: "_cmux_preexec tmux; print -r -- READY",
            extraEnvironment: [
                "PATH": "\(binDir.path):/usr/bin:/bin:/usr/sbin:/sbin",
                "PROGRAMA_SOCKET_PATH": "/tmp/programa-current.sock",
                "PROGRAMA_TAG": "feat-tmux-notification-attention-state",
                "PROGRAMA_WORKSPACE_ID": "11111111-1111-1111-1111-111111111111",
                "PROGRAMA_SURFACE_ID": "22222222-2222-2222-2222-222222222222",
                "PROGRAMA_TAB_ID": "11111111-1111-1111-1111-111111111111",
                "PROGRAMA_PANEL_ID": "22222222-2222-2222-2222-222222222222",
            ]
        )

        let log = (try? String(contentsOf: logPath, encoding: .utf8)) ?? ""
        XCTAssertTrue(log.contains("set-environment -gu PROGRAMA_SURFACE_ID"), log)
        XCTAssertTrue(log.contains("set-environment -gu PROGRAMA_PANEL_ID"), log)
    }

    func testShellIntegrationRefreshesWorkspaceScopedProgramaEnvironmentFromTmuxWithoutOverwritingSurfaceScope() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-zsh-tmux-refresh-\(UUID().uuidString)")
        let binDir = root.appendingPathComponent("bin", isDirectory: true)

        try fileManager.createDirectory(at: binDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try writeExecutableScript(
            at: binDir.appendingPathComponent("tmux", isDirectory: false),
            contents: """
            #!/bin/sh
            if [ "$1" = "show-environment" ] && [ "$2" = "-g" ]; then
              printf '%s\\n' 'PROGRAMA_SOCKET_PATH=/tmp/programa-current.sock'
              printf '%s\\n' 'PROGRAMA_TAG=feat-tmux-notification-attention-state'
              printf '%s\\n' 'PROGRAMA_WORKSPACE_ID=11111111-1111-1111-1111-111111111111'
              printf '%s\\n' 'PROGRAMA_SURFACE_ID=99999999-9999-9999-9999-999999999999'
              printf '%s\\n' 'PROGRAMA_TAB_ID=11111111-1111-1111-1111-111111111111'
              printf '%s\\n' 'PROGRAMA_PANEL_ID=99999999-9999-9999-9999-999999999999'
              exit 0
            fi
            exit 0
            """
        )

        let output = try runInteractiveZsh(
            cmuxLoadGhosttyIntegration: false,
            cmuxLoadShellIntegration: true,
            command: "_cmux_precmd; print -r -- \"$PROGRAMA_TAG|$PROGRAMA_SOCKET_PATH|$PROGRAMA_WORKSPACE_ID|$PROGRAMA_SURFACE_ID|$PROGRAMA_PANEL_ID\"",
            extraEnvironment: [
                "PATH": "\(binDir.path):/usr/bin:/bin:/usr/sbin:/sbin",
                "TMUX": "/tmp/tmux-stale,123,0",
                "PROGRAMA_SOCKET_PATH": "/tmp/programa-stale.sock",
                "PROGRAMA_TAG": "feat-tmux-integration-experiments",
                "PROGRAMA_WORKSPACE_ID": "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
                "PROGRAMA_SURFACE_ID": "22222222-2222-2222-2222-222222222222",
                "PROGRAMA_TAB_ID": "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
                "PROGRAMA_PANEL_ID": "22222222-2222-2222-2222-222222222222",
            ]
        )

        XCTAssertEqual(
            output,
            "feat-tmux-notification-attention-state|/tmp/programa-current.sock|11111111-1111-1111-1111-111111111111|22222222-2222-2222-2222-222222222222|22222222-2222-2222-2222-222222222222"
        )
    }

    func testShellIntegrationReportsTTYFromTmuxWithoutUsingPanelScope() throws {
        let output = try runInteractiveZsh(
            cmuxLoadGhosttyIntegration: false,
            cmuxLoadShellIntegration: true,
            command: """
            _PROGRAMA_TTY_NAME=ttys999
            print -r -- "$(_cmux_report_tty_payload)"
            """,
            extraEnvironment: [
                "TMUX": "/tmp/tmux-current,123,0",
                "PROGRAMA_TAB_ID": "11111111-1111-1111-1111-111111111111",
                "PROGRAMA_PANEL_ID": "99999999-9999-9999-9999-999999999999",
            ]
        )

        XCTAssertEqual(
            output,
            #"{"id":1,"method":"surface.report_tty","params":{"workspace_id":"11111111-1111-1111-1111-111111111111","tty_name":"ttys999"}}"#
        )
    }

    func testShellIntegrationRelayReportTTYUsesWorkspaceIDInZsh() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-zsh-relay-report-tty-\(UUID().uuidString)")
        let binDir = root.appendingPathComponent("bin", isDirectory: true)
        let logPath = root.appendingPathComponent("relay.log", isDirectory: false)

        try fileManager.createDirectory(at: binDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try writeExecutableScript(
            at: binDir.appendingPathComponent("programa", isDirectory: false),
            contents: """
            #!/bin/sh
            printf '%s\\n' "$*" >> "\(logPath.path)"
            exit 0
            """
        )

        let output = try runInteractiveZsh(
            cmuxLoadGhosttyIntegration: false,
            cmuxLoadShellIntegration: true,
            command: """
            : > "\(logPath.path)"
            _PROGRAMA_TTY_NAME=ttys777
            _cmux_report_tty_via_relay
            cat "\(logPath.path)"
            """,
            extraEnvironment: [
                "PATH": "\(binDir.path):/usr/bin:/bin:/usr/sbin:/sbin",
                "PROGRAMA_SOCKET_PATH": "127.0.0.1:64011",
                "PROGRAMA_WORKSPACE_ID": "11111111-1111-1111-1111-111111111111",
                "PROGRAMA_TAB_ID": "22222222-2222-2222-2222-222222222222",
                "PROGRAMA_PANEL_ID": "22222222-2222-2222-2222-222222222222",
            ]
        )

        XCTAssertTrue(
            output.contains(#"rpc surface.report_tty {"workspace_id":"11111111-1111-1111-1111-111111111111","tty_name":"ttys777","surface_id":"22222222-2222-2222-2222-222222222222"}"#),
            output
        )
    }

    func testShellIntegrationRelayPortsKickOmitsSurfaceIDUntilAvailableInZsh() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-zsh-relay-kick-\(UUID().uuidString)")
        let binDir = root.appendingPathComponent("bin", isDirectory: true)
        let logPath = root.appendingPathComponent("relay.log", isDirectory: false)

        try fileManager.createDirectory(at: binDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try writeExecutableScript(
            at: binDir.appendingPathComponent("programa", isDirectory: false),
            contents: """
            #!/bin/sh
            printf '%s\\n' "$*" >> "\(logPath.path)"
            exit 0
            """
        )

        let output = try runInteractiveZsh(
            cmuxLoadGhosttyIntegration: false,
            cmuxLoadShellIntegration: true,
            command: """
            : > "\(logPath.path)"
            _cmux_ports_kick_via_relay refresh
            repeat 20; do
              [[ -s "\(logPath.path)" ]] && break
              sleep 0.05
            done
            cat "\(logPath.path)"
            """,
            extraEnvironment: [
                "PATH": "\(binDir.path):/usr/bin:/bin:/usr/sbin:/sbin",
                "PROGRAMA_SOCKET_PATH": "127.0.0.1:64011",
                "PROGRAMA_WORKSPACE_ID": "11111111-1111-1111-1111-111111111111",
                "PROGRAMA_TAB_ID": "22222222-2222-2222-2222-222222222222",
                "PROGRAMA_PANEL_ID": "",
            ]
        )

        XCTAssertTrue(
            output.contains(#"rpc surface.ports_kick {"workspace_id":"11111111-1111-1111-1111-111111111111","reason":"refresh"}"#),
            output
        )
        XCTAssertFalse(output.contains("surface_id"), output)
    }

    func testShellIntegrationRelayPromptRefreshUsesRefreshReasonInZsh() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-zsh-relay-precmd-\(UUID().uuidString)")
        let binDir = root.appendingPathComponent("bin", isDirectory: true)
        let logPath = root.appendingPathComponent("relay.log", isDirectory: false)

        try fileManager.createDirectory(at: binDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try writeExecutableScript(
            at: binDir.appendingPathComponent("programa", isDirectory: false),
            contents: """
            #!/bin/sh
            printf '%s\\n' "$*" >> "\(logPath.path)"
            exit 0
            """
        )

        let output = try runInteractiveZsh(
            cmuxLoadGhosttyIntegration: false,
            cmuxLoadShellIntegration: true,
            command: """
            : > "\(logPath.path)"
            _PROGRAMA_TTY_REPORTED=1
            _PROGRAMA_PORTS_LAST_RUN=-999
            _cmux_precmd
            repeat 20; do
              [[ -s "\(logPath.path)" ]] && break
              sleep 0.05
            done
            cat "\(logPath.path)"
            """,
            extraEnvironment: [
                "PATH": "\(binDir.path):/usr/bin:/bin:/usr/sbin:/sbin",
                "PROGRAMA_SOCKET_PATH": "127.0.0.1:64011",
                "PROGRAMA_WORKSPACE_ID": "11111111-1111-1111-1111-111111111111",
                "PROGRAMA_TAB_ID": "22222222-2222-2222-2222-222222222222",
                "PROGRAMA_PANEL_ID": "22222222-2222-2222-2222-222222222222",
            ]
        )

        XCTAssertTrue(
            output.contains(#"rpc surface.ports_kick {"workspace_id":"11111111-1111-1111-1111-111111111111","reason":"refresh","surface_id":"22222222-2222-2222-2222-222222222222"}"#),
            output
        )
    }

    func testShellIntegrationRelayReportTTYUsesWorkspaceIDInBash() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-bash-relay-report-tty-\(UUID().uuidString)")
        let binDir = root.appendingPathComponent("bin", isDirectory: true)
        let logPath = root.appendingPathComponent("relay.log", isDirectory: false)

        try fileManager.createDirectory(at: binDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try writeExecutableScript(
            at: binDir.appendingPathComponent("programa", isDirectory: false),
            contents: """
            #!/bin/sh
            printf '%s\\n' "$*" >> "\(logPath.path)"
            exit 0
            """
        )

        let result = try runInteractiveBash(
            cmuxLoadShellIntegration: true,
            command: """
            : > "\(logPath.path)"
            _PROGRAMA_TTY_NAME=ttys888
            _cmux_report_tty_via_relay
            cat "\(logPath.path)"
            """,
            extraEnvironment: [
                "PATH": "\(binDir.path):/usr/bin:/bin:/usr/sbin:/sbin",
                "PROGRAMA_SOCKET_PATH": "127.0.0.1:64011",
                "PROGRAMA_WORKSPACE_ID": "11111111-1111-1111-1111-111111111111",
                "PROGRAMA_TAB_ID": "22222222-2222-2222-2222-222222222222",
                "PROGRAMA_PANEL_ID": "22222222-2222-2222-2222-222222222222",
            ]
        )

        XCTAssertTrue(
            result.stdout.contains(#"rpc surface.report_tty {"workspace_id":"11111111-1111-1111-1111-111111111111","tty_name":"ttys888","surface_id":"22222222-2222-2222-2222-222222222222"}"#),
            result.stdout
        )
    }

    func testShellIntegrationRelayPreexecWorksBeforeSurfaceIDExistsInBash() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-bash-relay-preexec-no-surface-\(UUID().uuidString)")
        let binDir = root.appendingPathComponent("bin", isDirectory: true)
        let logPath = root.appendingPathComponent("relay.log", isDirectory: false)

        try fileManager.createDirectory(at: binDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try writeExecutableScript(
            at: binDir.appendingPathComponent("programa", isDirectory: false),
            contents: """
            #!/bin/sh
            printf '%s\\n' "$*" >> "\(logPath.path)"
            exit 0
            """
        )

        let result = try runInteractiveBash(
            cmuxLoadShellIntegration: true,
            command: """
            : > "\(logPath.path)"
            _PROGRAMA_TTY_NAME=ttys889
            _PROGRAMA_TTY_REPORTED=0
            _cmux_preexec_command "python3 -m http.server 8899"
            for _cmux_i in $(seq 1 20); do
              grep -q ports_kick "\(logPath.path)" 2>/dev/null && break
              sleep 0.05
            done
            cat "\(logPath.path)"
            """,
            extraEnvironment: [
                "PATH": "\(binDir.path):/usr/bin:/bin:/usr/sbin:/sbin",
                "PROGRAMA_SOCKET_PATH": "127.0.0.1:64011",
                "PROGRAMA_WORKSPACE_ID": "11111111-1111-1111-1111-111111111111",
                "PROGRAMA_TAB_ID": "22222222-2222-2222-2222-222222222222",
                "PROGRAMA_PANEL_ID": "",
            ]
        )

        XCTAssertTrue(
            result.stdout.contains(#"rpc surface.report_tty {"workspace_id":"11111111-1111-1111-1111-111111111111","tty_name":"ttys889"}"#),
            result.stdout
        )
        XCTAssertTrue(
            result.stdout.contains(#"rpc surface.ports_kick {"workspace_id":"11111111-1111-1111-1111-111111111111","reason":"command"}"#),
            result.stdout
        )
        XCTAssertFalse(result.stdout.contains(#""surface_id""#), result.stdout)
    }

    func testShellIntegrationRelayPromptRefreshUsesRefreshReasonInBashWithoutPromptNoise() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-bash-relay-prompt-\(UUID().uuidString)")
        let binDir = root.appendingPathComponent("bin", isDirectory: true)
        let logPath = root.appendingPathComponent("relay.log", isDirectory: false)

        try fileManager.createDirectory(at: binDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try writeExecutableScript(
            at: binDir.appendingPathComponent("programa", isDirectory: false),
            contents: """
            #!/bin/sh
            printf '%s\\n' "$*" >> "\(logPath.path)"
            exit 0
            """
        )

        let result = try runInteractiveBash(
            cmuxLoadShellIntegration: true,
            command: """
            : > "\(logPath.path)"
            _PROGRAMA_TTY_REPORTED=1
            _PROGRAMA_PORTS_LAST_RUN=-999
            _cmux_prompt_command
            for _cmux_i in $(seq 1 20); do
              [ -s "\(logPath.path)" ] && break
              sleep 0.05
            done
            cat "\(logPath.path)"
            """,
            extraEnvironment: [
                "PATH": "\(binDir.path):/usr/bin:/bin:/usr/sbin:/sbin",
                "PROGRAMA_SOCKET_PATH": "127.0.0.1:64011",
                "PROGRAMA_WORKSPACE_ID": "11111111-1111-1111-1111-111111111111",
                "PROGRAMA_TAB_ID": "22222222-2222-2222-2222-222222222222",
                "PROGRAMA_PANEL_ID": "22222222-2222-2222-2222-222222222222",
            ]
        )

        XCTAssertFalse(result.stderr.contains("_cmux_report_tmux_state"), result.stderr)
        XCTAssertTrue(
            result.stdout.contains(#"rpc surface.ports_kick {"workspace_id":"11111111-1111-1111-1111-111111111111","reason":"refresh","surface_id":"22222222-2222-2222-2222-222222222222"}"#),
            result.stdout
        )
    }

    func testBashBootstrapPreservesStarshipPromptCommandAcrossPrompts() throws {
        // Regression test: Programa's local macOS bash bootstrap is injected
        // as PROMPT_COMMAND and used to begin by unconditionally clobbering
        // PROMPT_COMMAND. A user's startup files run
        // `eval "$(starship init bash)"` before the first prompt, which
        // appends starship_precmd to PROMPT_COMMAND; the bootstrap then
        // discarded it after running once, freezing the prompt. This drives
        // the real bootstrap file (Resources/shell-integration/
        // programa-bash-bootstrap.bash) plus a faithful starship stub
        // through bash and asserts starship_precmd survives across prompts,
        // rather than relying on a PTY.
        let fields = try runBashBootstrapDriver(withUserPromptHook: true)
        let debug = "\n\nstdout:\n\(fields["__stdout__"] ?? "")\nstderr:\n\(fields["__stderr__"] ?? "")"

        XCTAssertTrue(
            (fields["PC_AFTER_RC"] ?? "").contains("starship_precmd"),
            "test setup did not append starship_precmd to PROMPT_COMMAND" + debug
        )

        for i in 1...3 {
            let pc = fields["PC_\(i)"] ?? ""
            XCTAssertTrue(
                pc.contains("starship_precmd"),
                "starship_precmd was dropped from PROMPT_COMMAND at prompt \(i); the bootstrap took exclusive ownership instead of composing with the user's hook. PROMPT_COMMAND=<\(pc)>" + debug
            )
            XCTAssertTrue(
                pc.contains("_cmux_prompt_command"),
                "Programa's own prompt hook is missing from PROMPT_COMMAND at prompt \(i): <\(pc)>" + debug
            )
            XCTAssertFalse(
                pc.contains("__programa_bash_bootstrap_marker__"),
                "bootstrap marker leaked into PROMPT_COMMAND at prompt \(i): <\(pc)>" + debug
            )
        }

        let ps1Values = (1...3).map { fields["PS1_\($0)"] ?? "" }
        XCTAssertNotEqual(
            ps1Values[0], ps1Values[1],
            "starship prompt went static across prompts (it stopped re-rendering): \(ps1Values)" + debug
        )
        XCTAssertNotEqual(
            ps1Values[1], ps1Values[2],
            "starship prompt went static across prompts (it stopped re-rendering): \(ps1Values)" + debug
        )
        XCTAssertTrue(
            ps1Values[2].contains("n=3"),
            "starship_precmd did not run on every prompt; final PS1=<\(ps1Values[2])>" + debug
        )
        XCTAssertTrue(
            ps1Values[2].contains("cwd=cd-target"),
            "prompt did not pick up the new cwd after cd; final PS1=<\(ps1Values[2])>" + debug
        )
    }

    func testBashBootstrapInstallsPromptCommandWithoutUserHook() throws {
        // No-regression guard: with no user PROMPT_COMMAND hook (plain bash,
        // no Starship or similar prompt framework), the bootstrap must still
        // install Programa's own prompt hook -- and must not leak its
        // internal marker into PROMPT_COMMAND.
        let fields = try runBashBootstrapDriver(withUserPromptHook: false)
        let debug = "\n\nstdout:\n\(fields["__stdout__"] ?? "")\nstderr:\n\(fields["__stderr__"] ?? "")"

        for i in 1...3 {
            let pc = fields["PC_\(i)"] ?? ""
            // Assert the observable contract (hook installed, bootstrap
            // marker removed, no phantom hook) rather than the exact
            // integration-internal string, so this stays green if
            // programa-bash-integration.bash ever tweaks its PROMPT_COMMAND
            // merge.
            XCTAssertTrue(
                pc.contains("_cmux_prompt_command"),
                "plain-bash bootstrap did not install Programa's prompt hook at prompt \(i): <\(pc)>" + debug
            )
            XCTAssertFalse(
                pc.contains("__programa_bash_bootstrap_marker__"),
                "bootstrap marker leaked into PROMPT_COMMAND at prompt \(i): <\(pc)>" + debug
            )
            XCTAssertFalse(
                pc.contains("starship_precmd"),
                "unexpected starship hook in plain-bash PROMPT_COMMAND at prompt \(i): <\(pc)>" + debug
            )
        }
    }

    /// Drives `Resources/shell-integration/programa-bash-bootstrap.bash`
    /// through real bash, modeling bash's "evaluate PROMPT_COMMAND before
    /// each prompt" loop directly (deterministic, no PTY needed). When
    /// `withUserPromptHook` is true, simulates a user's startup files running
    /// `eval "$(starship init bash)"` and appending `starship_precmd` to
    /// PROMPT_COMMAND before the first prompt, exactly as the real Starship
    /// binary's bash init does for non-bash-preexec shells.
    private func runBashBootstrapDriver(withUserPromptHook: Bool) throws -> [String: String] {
        let fileManager = FileManager.default
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let bootstrapSourcePath = repoRoot
            .appendingPathComponent("Resources/shell-integration/programa-bash-bootstrap.bash")
        let rawBootstrap = try String(contentsOf: bootstrapSourcePath, encoding: .utf8)
        // Mirrors Sources/GhosttyTerminalView.swift's comment/blank-line
        // stripping so the test exercises exactly what ships as
        // $PROMPT_COMMAND.
        let leanBootstrap = rawBootstrap
            .components(separatedBy: "\n")
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                return !trimmed.isEmpty && !trimmed.hasPrefix("#")
            }
            .joined(separator: "\n")

        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-bash-bootstrap-starship-\(UUID().uuidString)")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let bootstrapFile = root.appendingPathComponent("bootstrap.bash")
        try leanBootstrap.write(to: bootstrapFile, atomically: true, encoding: .utf8)

        let cdTarget = root.appendingPathComponent("cd-target")
        try fileManager.createDirectory(at: cdTarget, withIntermediateDirectories: true)

        let shellIntegrationDir = repoRoot.appendingPathComponent("Resources/shell-integration")

        let driver = #"""
        set +e
        PROMPT_COMMAND="$(cat "$BOOTSTRAP_FILE")"

        if [[ "${WITH_USER_HOOK:-1}" == "1" ]]; then
            starship_precmd() {
                STARSHIP_COUNTER=$((STARSHIP_COUNTER + 1))
                PS1="cwd=${PWD##*/} n=${STARSHIP_COUNTER} "
            }
            if [[ "$(declare -p PROMPT_COMMAND 2>/dev/null)" == "declare -a"* ]]; then
                PROMPT_COMMAND+=(starship_precmd)
            else
                PROMPT_COMMAND=${PROMPT_COMMAND:+$PROMPT_COMMAND$'\n'}"starship_precmd"
            fi
        fi

        _emit() { printf '%s<%s>\n' "$1" "${2//$'\n'/<NL>}"; }
        _emit PC_AFTER_RC "$PROMPT_COMMAND"

        _render() {
            if [[ "$(declare -p PROMPT_COMMAND 2>/dev/null)" == "declare -a"* ]]; then
                local pc
                for pc in "${PROMPT_COMMAND[@]}"; do eval "$pc"; done
            else
                eval "$PROMPT_COMMAND"
            fi
        }

        STARSHIP_COUNTER=0
        i=0
        while (( i < 3 )); do
            i=$((i + 1))
            (( i == 3 )) && cd "$CD_TARGET"
            _render
            _emit "PS1_$i" "$PS1"
            _emit "PC_$i" "$PROMPT_COMMAND"
        done
        """#

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["--noprofile", "--norc", "-c", driver]
        process.environment = [
            "HOME": root.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "BOOTSTRAP_FILE": bootstrapFile.path,
            "CD_TARGET": cdTarget.path,
            "WITH_USER_HOOK": withUserPromptHook ? "1" : "0",
            "PROGRAMA_LOAD_GHOSTTY_BASH_INTEGRATION": "0",
            "GHOSTTY_RESOURCES_DIR": "",
            "PROGRAMA_SHELL_INTEGRATION": "1",
            "PROGRAMA_SHELL_INTEGRATION_DIR": shellIntegrationDir.path,
        ]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            XCTFail("Timed out waiting for bash bootstrap driver to exit")
        }

        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let error = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, "stdout:\n\(output)\nstderr:\n\(error)")

        var fields: [String: String] = ["__stdout__": output, "__stderr__": error]
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let openIdx = line.firstIndex(of: "<"), line.hasSuffix(">") else { continue }
            let key = String(line[line.startIndex..<openIdx])
            let value = String(line[line.index(after: openIdx)..<line.index(before: line.endIndex)])
            fields[key] = value
        }
        return fields
    }

    private func runInteractiveZsh(cmuxLoadGhosttyIntegration: Bool) throws -> String {
        try runInteractiveZsh(
            cmuxLoadGhosttyIntegration: cmuxLoadGhosttyIntegration,
            cmuxLoadShellIntegration: false,
            command: "(( $+functions[_ghostty_deferred_init] )) && _ghostty_deferred_init >/dev/null 2>&1; " +
                "print -r -- \"PRECMD=${+functions[_ghostty_precmd]} " +
                "PREEXEC=${+functions[_ghostty_preexec]} PRECMDS=${(j:,:)precmd_functions}\""
        )
    }

    private func runInteractiveZsh(
        cmuxLoadGhosttyIntegration: Bool,
        cmuxLoadShellIntegration: Bool,
        command: String,
        extraEnvironment: [String: String] = [:],
        userZshEnvContents: String? = nil,
        userZshRCContents: String? = nil
    ) throws -> String {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-zsh-shell-integration-\(UUID().uuidString)")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let userZdotdir = root.appendingPathComponent("zdotdir")
        try fileManager.createDirectory(at: userZdotdir, withIntermediateDirectories: true)
        var userZshEnvFileContents = "\n"
        if let path = extraEnvironment["PATH"] {
            let escaped = path.replacingOccurrences(of: "\"", with: "\\\"")
            userZshEnvFileContents = "export PATH=\"\(escaped)\"\n"
        }
        if let userZshEnvContents {
            if !userZshEnvFileContents.hasSuffix("\n") {
                userZshEnvFileContents.append("\n")
            }
            userZshEnvFileContents.append(userZshEnvContents)
            if !userZshEnvFileContents.hasSuffix("\n") {
                userZshEnvFileContents.append("\n")
            }
        }
        try userZshEnvFileContents.write(
            to: userZdotdir.appendingPathComponent(".zshenv"),
            atomically: true,
            encoding: .utf8
        )
        if let userZshRCContents {
            try userZshRCContents.write(
                to: userZdotdir.appendingPathComponent(".zshrc"),
                atomically: true,
                encoding: .utf8
            )
        }

        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let cmuxZdotdir = repoRoot.appendingPathComponent("Resources/shell-integration")
        let ghosttyResources = repoRoot.appendingPathComponent("ghostty/src")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [
            "-i",
            "-c", command
        ]
        process.environment = [
            "HOME": root.path,
            "TERM": "xterm-256color",
            "SHELL": "/bin/zsh",
            "USER": NSUserName(),
            "ZDOTDIR": cmuxZdotdir.path,
            "PROGRAMA_ZSH_ZDOTDIR": userZdotdir.path,
            "PROGRAMA_SHELL_INTEGRATION": "0",
            "GHOSTTY_RESOURCES_DIR": ghosttyResources.path,
        ]
        if cmuxLoadGhosttyIntegration {
            process.environment?["PROGRAMA_LOAD_GHOSTTY_ZSH_INTEGRATION"] = "1"
        }
        if cmuxLoadShellIntegration {
            process.environment?["PROGRAMA_SHELL_INTEGRATION"] = "1"
            process.environment?["PROGRAMA_SHELL_INTEGRATION_DIR"] = cmuxZdotdir.path
            process.environment?["PROGRAMA_SOCKET_PATH"] = root.appendingPathComponent("cmux-test.sock").path
            process.environment?["PROGRAMA_TAB_ID"] = "tab-test"
            process.environment?["PROGRAMA_PANEL_ID"] = "panel-test"
        }
        for (key, value) in extraEnvironment {
            process.environment?[key] = value
        }

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            XCTFail("Timed out waiting for zsh to exit")
        }

        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let error = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        XCTAssertEqual(process.terminationStatus, 0, error)
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func runPromptInteractiveZsh(
        cmuxLoadGhosttyIntegration: Bool,
        cmuxLoadShellIntegration: Bool,
        command: String,
        extraEnvironment: [String: String] = [:],
        userZshEnvContents: String? = nil,
        userZshRCContents: String? = nil
    ) throws -> String {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-zsh-prompt-integration-\(UUID().uuidString)")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let userZdotdir = root.appendingPathComponent("zdotdir")
        try fileManager.createDirectory(at: userZdotdir, withIntermediateDirectories: true)
        var userZshEnvFileContents = "\n"
        if let path = extraEnvironment["PATH"] {
            let escaped = path.replacingOccurrences(of: "\"", with: "\\\"")
            userZshEnvFileContents = "export PATH=\"\(escaped)\"\n"
        }
        if let userZshEnvContents {
            if !userZshEnvFileContents.hasSuffix("\n") {
                userZshEnvFileContents.append("\n")
            }
            userZshEnvFileContents.append(userZshEnvContents)
            if !userZshEnvFileContents.hasSuffix("\n") {
                userZshEnvFileContents.append("\n")
            }
        }
        try userZshEnvFileContents.write(
            to: userZdotdir.appendingPathComponent(".zshenv"),
            atomically: true,
            encoding: .utf8
        )
        if let userZshRCContents {
            try userZshRCContents.write(
                to: userZdotdir.appendingPathComponent(".zshrc"),
                atomically: true,
                encoding: .utf8
            )
        }

        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let cmuxZdotdir = repoRoot.appendingPathComponent("Resources/shell-integration")
        let ghosttyResources = repoRoot.appendingPathComponent("ghostty/src")
        let readyPath = root.appendingPathComponent("ready", isDirectory: false)
        let outputPath = root.appendingPathComponent("output.log", isDirectory: false)

        var masterFD: Int32 = -1
        var slaveFD: Int32 = -1
        guard openpty(&masterFD, &slaveFD, nil, nil, nil) == 0 else {
            let message = "openpty failed: \(String(cString: strerror(errno)))"
            XCTFail(message)
            throw NSError(
                domain: "ZshShellIntegrationHandoffTests",
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-i"]
        process.environment = [
            "HOME": root.path,
            "TERM": "xterm-256color",
            "SHELL": "/bin/zsh",
            "USER": NSUserName(),
            "ZDOTDIR": cmuxZdotdir.path,
            "PROGRAMA_ZSH_ZDOTDIR": userZdotdir.path,
            "PROGRAMA_SHELL_INTEGRATION": "0",
            "GHOSTTY_RESOURCES_DIR": ghosttyResources.path,
            "PROGRAMA_TEST_READY": readyPath.path,
            "PROGRAMA_TEST_OUTPUT": outputPath.path,
        ]
        if cmuxLoadGhosttyIntegration {
            process.environment?["PROGRAMA_LOAD_GHOSTTY_ZSH_INTEGRATION"] = "1"
        }
        if cmuxLoadShellIntegration {
            process.environment?["PROGRAMA_SHELL_INTEGRATION"] = "1"
            process.environment?["PROGRAMA_SHELL_INTEGRATION_DIR"] = cmuxZdotdir.path
            process.environment?["PROGRAMA_SOCKET_PATH"] = root.appendingPathComponent("cmux-test.sock").path
            process.environment?["PROGRAMA_TAB_ID"] = "tab-test"
            process.environment?["PROGRAMA_PANEL_ID"] = "panel-test"
        }
        for (key, value) in extraEnvironment {
            process.environment?[key] = value
        }

        let slaveHandle = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: true)
        process.standardInput = slaveHandle
        process.standardOutput = slaveHandle
        process.standardError = slaveHandle

        let masterHandle = FileHandle(fileDescriptor: masterFD, closeOnDealloc: true)
        let terminalOutputLock = NSLock()
        var terminalOutputData = Data()
        masterHandle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            terminalOutputLock.lock()
            terminalOutputData.append(data)
            terminalOutputLock.unlock()
        }
        defer { masterHandle.readabilityHandler = nil }

        func terminalOutputSnapshot() -> String {
            terminalOutputLock.lock()
            defer { terminalOutputLock.unlock() }
            return String(data: terminalOutputData, encoding: .utf8) ?? ""
        }

        try process.run()
        slaveHandle.closeFile()

        let readyDeadline = Date().addingTimeInterval(5)
        while !fileManager.fileExists(atPath: readyPath.path) && Date() < readyDeadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        if !fileManager.fileExists(atPath: readyPath.path) {
            process.terminate()
            process.waitUntilExit()
            let terminalOutput = terminalOutputSnapshot()
            let message = "Timed out waiting for interactive zsh prompt: \(terminalOutput)"
            XCTFail(message)
            throw NSError(
                domain: "ZshShellIntegrationHandoffTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }

        masterHandle.write(Data((command + "\nexit\n").utf8))

        let exitDeadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < exitDeadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            let terminalOutput = terminalOutputSnapshot()
            let message = "Timed out waiting for interactive zsh to exit: \(terminalOutput)"
            XCTFail(message)
            throw NSError(
                domain: "ZshShellIntegrationHandoffTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }

        let terminalOutput = terminalOutputSnapshot()
        XCTAssertEqual(process.terminationStatus, 0, terminalOutput)
        return (try? String(contentsOf: outputPath, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func runInteractiveBash(
        cmuxLoadShellIntegration: Bool,
        command: String,
        extraEnvironment: [String: String] = [:]
    ) throws -> (stdout: String, stderr: String) {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-bash-shell-integration-\(UUID().uuidString)")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let integrationPath = repoRoot.appendingPathComponent("Resources/shell-integration/programa-bash-integration.bash")
        let rcfilePath = root.appendingPathComponent(".bashrc")
        let rcfileContents: String = {
            guard cmuxLoadShellIntegration else { return ":\n" }
            return """
            . "\(integrationPath.path)"
            """
        }()
        try rcfileContents.write(to: rcfilePath, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            "--noprofile",
            "--rcfile", rcfilePath.path,
            "-i",
            "-c", command
        ]
        process.environment = [
            "HOME": root.path,
            "TERM": "xterm-256color",
            "SHELL": "/bin/bash",
            "USER": NSUserName(),
        ]
        if cmuxLoadShellIntegration {
            process.environment?["PROGRAMA_SOCKET_PATH"] = root.appendingPathComponent("cmux-test.sock").path
            process.environment?["PROGRAMA_TAB_ID"] = "tab-test"
            process.environment?["PROGRAMA_PANEL_ID"] = "panel-test"
        }
        for (key, value) in extraEnvironment {
            process.environment?[key] = value
        }

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            XCTFail("Timed out waiting for bash to exit")
        }

        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let error = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        XCTAssertEqual(process.terminationStatus, 0, error)
        return (
            stdout: output.trimmingCharacters(in: .whitespacesAndNewlines),
            stderr: error.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func writeExecutableScript(at url: URL, contents: String) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func bindUnixSocket(at path: String) throws -> Int32 {
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "Failed to create Unix socket"]
            )
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxPathLength = MemoryLayout.size(ofValue: addr.sun_path)
        path.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                let pathBuf = UnsafeMutableRawPointer(pathPtr).assumingMemoryBound(to: CChar.self)
                strncpy(pathBuf, ptr, maxPathLength - 1)
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let code = Int(errno)
            Darwin.close(fd)
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: code,
                userInfo: [NSLocalizedDescriptionKey: "Failed to bind Unix socket"]
            )
        }

        guard Darwin.listen(fd, 1) == 0 else {
            let code = Int(errno)
            Darwin.close(fd)
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: code,
                userInfo: [NSLocalizedDescriptionKey: "Failed to listen on Unix socket"]
            )
        }

        return fd
    }
}

final class FishShellIntegrationHandoffTests: XCTestCase {
    func testLocalTTYReportRetriesDeniedCLIThenDeduplicatesAcknowledgmentInFish() throws {
        let fixture = try LocalTTYReportFixture()
        let output = try runInteractiveFish(command: fixture.fishCommand, extraEnvironment: fixture.environment)
        XCTAssertTrue(output.contains("TTY_ATTEMPTS=2"), output)
        XCTAssertTrue(output.contains("TTY_STATES=0,1,1"), output)
    }
    func testFishReportTtyPayloadIncludesSurfaceIdWithoutTmux() throws {
        let output = try runInteractiveFish(
            command: """
            set -g _PROGRAMA_TTY_NAME ttys999
            _cmux_report_tty_payload
            """,
            extraEnvironment: [
                "PROGRAMA_TAB_ID": "11111111-1111-1111-1111-111111111111",
                "PROGRAMA_PANEL_ID": "99999999-9999-9999-9999-999999999999",
            ]
        )

        XCTAssertEqual(
            output,
            #"{"id":1,"method":"surface.report_tty","params":{"workspace_id":"11111111-1111-1111-1111-111111111111","tty_name":"ttys999","surface_id":"99999999-9999-9999-9999-999999999999"}}"#
        )
    }

    func testFishReportTtyPayloadOmitsSurfaceIdWithTmux() throws {
        let output = try runInteractiveFish(
            command: """
            set -g _PROGRAMA_TTY_NAME ttys555
            _cmux_report_tty_payload
            """,
            extraEnvironment: [
                "TMUX": "/tmp/tmux-current,123,0",
                "PROGRAMA_WORKSPACE_ID": "11111111-1111-1111-1111-111111111111",
                "PROGRAMA_TAB_ID": "11111111-1111-1111-1111-111111111111",
                "PROGRAMA_PANEL_ID": "99999999-9999-9999-9999-999999999999",
            ]
        )

        XCTAssertEqual(
            output,
            #"{"id":1,"method":"surface.report_tty","params":{"workspace_id":"11111111-1111-1111-1111-111111111111","tty_name":"ttys555"}}"#
        )
    }

    func testFishRelayReportTtyUsesWorkspaceId() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-fish-relay-report-tty-\(UUID().uuidString)")
        let binDir = root.appendingPathComponent("bin", isDirectory: true)
        let logPath = root.appendingPathComponent("relay.log", isDirectory: false)

        try fileManager.createDirectory(at: binDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try writeExecutableScript(
            at: binDir.appendingPathComponent("programa", isDirectory: false),
            contents: """
            #!/bin/sh
            printf '%s\\n' "$*" >> "\(logPath.path)"
            exit 0
            """
        )

        let output = try runInteractiveFish(
            command: """
            : > "\(logPath.path)"
            set -g _PROGRAMA_TTY_NAME ttys777
            _cmux_report_tty_via_relay
            cat "\(logPath.path)"
            """,
            extraEnvironment: [
                "PATH": "\(binDir.path):/usr/bin:/bin:/usr/sbin:/sbin",
                "PROGRAMA_SOCKET_PATH": "127.0.0.1:64011",
                "PROGRAMA_WORKSPACE_ID": "11111111-1111-1111-1111-111111111111",
                "PROGRAMA_TAB_ID": "22222222-2222-2222-2222-222222222222",
                "PROGRAMA_PANEL_ID": "22222222-2222-2222-2222-222222222222",
            ]
        )

        XCTAssertTrue(
            output.contains(#"rpc surface.report_tty {"workspace_id":"11111111-1111-1111-1111-111111111111","tty_name":"ttys777","surface_id":"22222222-2222-2222-2222-222222222222"}"#),
            output
        )
    }

    func testFishRelayPortsKickOmitsSurfaceIdUntilAvailable() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-fish-relay-kick-\(UUID().uuidString)")
        let binDir = root.appendingPathComponent("bin", isDirectory: true)
        let logPath = root.appendingPathComponent("relay.log", isDirectory: false)

        try fileManager.createDirectory(at: binDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try writeExecutableScript(
            at: binDir.appendingPathComponent("programa", isDirectory: false),
            contents: """
            #!/bin/sh
            printf '%s\\n' "$*" >> "\(logPath.path)"
            exit 0
            """
        )

        let output = try runInteractiveFish(
            command: """
            : > "\(logPath.path)"
            _cmux_ports_kick_via_relay refresh
            for _cmux_i in (seq 1 20)
                test -s "\(logPath.path)"; and break
                sleep 0.05
            end
            cat "\(logPath.path)"
            """,
            extraEnvironment: [
                "PATH": "\(binDir.path):/usr/bin:/bin:/usr/sbin:/sbin",
                "PROGRAMA_SOCKET_PATH": "127.0.0.1:64011",
                "PROGRAMA_WORKSPACE_ID": "11111111-1111-1111-1111-111111111111",
                "PROGRAMA_TAB_ID": "22222222-2222-2222-2222-222222222222",
            ]
        )

        XCTAssertTrue(
            output.contains(#"rpc surface.ports_kick {"workspace_id":"11111111-1111-1111-1111-111111111111","reason":"refresh"}"#),
            output
        )
        XCTAssertFalse(output.contains("surface_id"), output)
    }

    func testFishTmuxSyncPublishesOnlyWorkspaceScopedProgramaEnvironment() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-fish-tmux-publish-\(UUID().uuidString)")
        let binDir = root.appendingPathComponent("bin", isDirectory: true)
        let logPath = root.appendingPathComponent("tmux.log", isDirectory: false)

        try fileManager.createDirectory(at: binDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try writeExecutableScript(
            at: binDir.appendingPathComponent("tmux", isDirectory: false),
            contents: """
            #!/bin/sh
            if [ "$1" = "show-environment" ] && [ "$2" = "-g" ]; then
              exit 0
            fi
            printf '%s\\n' "$*" >> "\(logPath.path)"
            exit 0
            """
        )

        let output = try runInteractiveFish(
            command: """
            _cmux_tmux_sync_cmux_environment
            cat "\(logPath.path)"
            """,
            extraEnvironment: [
                "PATH": "\(binDir.path):/usr/bin:/bin:/usr/sbin:/sbin",
                "PROGRAMA_SOCKET_PATH": "/tmp/programa-current.sock",
                "PROGRAMA_TAG": "feat-fish-shell-integration",
                "PROGRAMA_WORKSPACE_ID": "11111111-1111-1111-1111-111111111111",
                "PROGRAMA_SURFACE_ID": "22222222-2222-2222-2222-222222222222",
                "PROGRAMA_TAB_ID": "11111111-1111-1111-1111-111111111111",
                "PROGRAMA_PANEL_ID": "22222222-2222-2222-2222-222222222222",
            ]
        )

        XCTAssertTrue(output.contains("set-environment -g PROGRAMA_TAG feat-fish-shell-integration"), output)
        XCTAssertTrue(output.contains("set-environment -g PROGRAMA_SOCKET_PATH /tmp/programa-current.sock"), output)
        XCTAssertTrue(output.contains("set-environment -g PROGRAMA_WORKSPACE_ID 11111111-1111-1111-1111-111111111111"), output)
        XCTAssertTrue(output.contains("set-environment -gu PROGRAMA_SURFACE_ID"), output)
        XCTAssertTrue(output.contains("set-environment -gu PROGRAMA_PANEL_ID"), output)
        XCTAssertFalse(output.contains("set-environment -g PROGRAMA_SURFACE_ID"), output)
        XCTAssertFalse(output.contains("set-environment -g PROGRAMA_PANEL_ID"), output)
    }

    func testFishResetTerminalKeyboardProtocolsPrintsSequenceWhenForced() throws {
        let output = try runInteractiveFish(
            command: "_cmux_reset_terminal_keyboard_protocols",
            extraEnvironment: [
                "PROGRAMA_TEST_FORCE_KEYBOARD_RESET": "1",
            ]
        )

        XCTAssertEqual(output, "\u{1B}[>m\u{1B}[<8u")
    }

    private func resolveFishExecutablePath() -> String? {
        let candidates = [
            "/opt/homebrew/bin/fish",
            "/usr/local/bin/fish",
            "/usr/bin/fish",
            "/bin/fish",
        ]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return nil
    }

    private func requireFishExecutablePath() throws -> String {
        guard let path = resolveFishExecutablePath() else {
            throw XCTSkip("fish is not installed on this host")
        }
        return path
    }

    private func runInteractiveFish(
        command: String,
        extraEnvironment: [String: String] = [:]
    ) throws -> String {
        let fishPath = try requireFishExecutablePath()

        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-fish-shell-integration-\(UUID().uuidString)")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let integrationPath = repoRoot.appendingPathComponent("Resources/shell-integration/fish/config.fish")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: fishPath)
        process.arguments = [
            "--no-config",
            "--init-command", "source \"\(integrationPath.path)\"",
            "-c", command,
        ]
        process.environment = [
            "HOME": root.path,
            "TERM": "xterm-256color",
            "SHELL": fishPath,
            "USER": NSUserName(),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "PROGRAMA_FISH_USER_CONFIG_ALREADY_LOADED": "1",
            "PROGRAMA_SHELL_INTEGRATION": "1",
        ]
        for (key, value) in extraEnvironment {
            process.environment?[key] = value
        }

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            XCTFail("Timed out waiting for fish to exit")
        }

        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let error = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        XCTAssertEqual(process.terminationStatus, 0, error)
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func writeExecutableScript(at url: URL, contents: String) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}

final class SidebarGlassMigrationTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "programa-tests-sidebar-migration-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    /// Writes the exact values migration v1 stamped on every stock install.
    /// Frozen literals on purpose — these are the historical on-disk values, and
    /// must not drift if SidebarPresetOption.nativeSidebar ever changes.
    private func stampNativeSidebarPreset() {
        defaults.set("nativeSidebar", forKey: "sidebarPreset")
        defaults.set("sidebar", forKey: "sidebarMaterial")
        defaults.set("withinWindow", forKey: "sidebarBlendMode")
        defaults.set("followWindow", forKey: "sidebarState")
        defaults.set("#000000", forKey: "sidebarTintHex")
        defaults.set(0.18, forKey: "sidebarTintOpacity")
        defaults.set(1.0, forKey: "sidebarBlurOpacity")
        defaults.set(0.0, forKey: "sidebarCornerRadius")
    }

    func testV1NativeSidebarStampUpgradesToLiquidGlassWhenNativeGlassAvailable() {
        stampNativeSidebarPreset()
        defaults.set(2, forKey: ProgramaGlassSettings.sidebarMigrationVersionKey)

        ProgramaGlassSettings.migrateSidebarAppearanceDefaultsIfNeeded(
            defaults: defaults,
            nativeGlassAvailable: true
        )

        XCTAssertEqual(defaults.string(forKey: "sidebarPreset"), SidebarPresetOption.liquidGlass.rawValue)
        XCTAssertEqual(defaults.string(forKey: "sidebarMaterial"), SidebarMaterialOption.liquidGlass.rawValue)
        XCTAssertEqual(
            defaults.object(forKey: "sidebarCornerRadius") as? Double,
            SidebarPresetOption.liquidGlass.cornerRadius
        )
    }

    func testV1NativeSidebarStampStaysNativeWithoutNativeGlass() {
        stampNativeSidebarPreset()
        defaults.set(2, forKey: ProgramaGlassSettings.sidebarMigrationVersionKey)

        ProgramaGlassSettings.migrateSidebarAppearanceDefaultsIfNeeded(
            defaults: defaults,
            nativeGlassAvailable: false
        )

        XCTAssertEqual(defaults.string(forKey: "sidebarPreset"), SidebarPresetOption.nativeSidebar.rawValue)
        XCTAssertEqual(defaults.string(forKey: "sidebarMaterial"), SidebarMaterialOption.sidebar.rawValue)
    }

    func testGlassUnavailableRunStaysReRunnableAfterOSUpgrade() {
        stampNativeSidebarPreset()
        defaults.set(2, forKey: ProgramaGlassSettings.sidebarMigrationVersionKey)

        // Launch on an older macOS: no glass, migration must not burn its version.
        ProgramaGlassSettings.migrateSidebarAppearanceDefaultsIfNeeded(
            defaults: defaults,
            nativeGlassAvailable: false
        )
        XCTAssertEqual(defaults.string(forKey: "sidebarPreset"), SidebarPresetOption.nativeSidebar.rawValue)

        // First launch after upgrading to a glass-capable macOS.
        ProgramaGlassSettings.migrateSidebarAppearanceDefaultsIfNeeded(
            defaults: defaults,
            nativeGlassAvailable: true
        )
        XCTAssertEqual(defaults.string(forKey: "sidebarPreset"), SidebarPresetOption.liquidGlass.rawValue)
    }

    func testPerSchemeTintMarksSidebarAsUserConfigured() {
        stampNativeSidebarPreset()
        defaults.set("#0A0A0A", forKey: "sidebarTintHexLight")
        defaults.set(2, forKey: ProgramaGlassSettings.sidebarMigrationVersionKey)

        ProgramaGlassSettings.migrateSidebarAppearanceDefaultsIfNeeded(
            defaults: defaults,
            nativeGlassAvailable: true
        )

        XCTAssertEqual(defaults.string(forKey: "sidebarPreset"), SidebarPresetOption.nativeSidebar.rawValue)
        XCTAssertEqual(defaults.string(forKey: "sidebarTintHexLight"), "#0A0A0A")
    }

    func testMatchTerminalBackgroundMarksSidebarAsUserConfigured() {
        stampNativeSidebarPreset()
        defaults.set(true, forKey: "sidebarMatchTerminalBackground")
        defaults.set(2, forKey: ProgramaGlassSettings.sidebarMigrationVersionKey)

        ProgramaGlassSettings.migrateSidebarAppearanceDefaultsIfNeeded(
            defaults: defaults,
            nativeGlassAvailable: true
        )

        XCTAssertEqual(defaults.string(forKey: "sidebarPreset"), SidebarPresetOption.nativeSidebar.rawValue)
    }

    func testCustomizedSidebarSettingsSurviveMigration() {
        stampNativeSidebarPreset()
        // A hand-picked tint makes these values a user choice, not the v1 stamp.
        defaults.set("#123456", forKey: "sidebarTintHex")
        defaults.set(2, forKey: ProgramaGlassSettings.sidebarMigrationVersionKey)

        ProgramaGlassSettings.migrateSidebarAppearanceDefaultsIfNeeded(
            defaults: defaults,
            nativeGlassAvailable: true
        )

        XCTAssertEqual(defaults.string(forKey: "sidebarMaterial"), SidebarMaterialOption.sidebar.rawValue)
        XCTAssertEqual(defaults.string(forKey: "sidebarTintHex"), "#123456")
    }

    func testLegacyDefaultsStillUpgradeToLiquidGlass() {
        defaults.set(SidebarMaterialOption.sidebar.rawValue, forKey: "sidebarMaterial")
        defaults.set(SidebarBlendModeOption.behindWindow.rawValue, forKey: "sidebarBlendMode")
        defaults.set(SidebarStateOption.followWindow.rawValue, forKey: "sidebarState")
        defaults.set("#101010", forKey: "sidebarTintHex")
        defaults.set(0.54, forKey: "sidebarTintOpacity")
        defaults.set(0.79, forKey: "sidebarBlurOpacity")
        defaults.set(0.0, forKey: "sidebarCornerRadius")

        ProgramaGlassSettings.migrateSidebarAppearanceDefaultsIfNeeded(
            defaults: defaults,
            nativeGlassAvailable: true
        )

        XCTAssertEqual(defaults.string(forKey: "sidebarPreset"), SidebarPresetOption.liquidGlass.rawValue)
        XCTAssertEqual(defaults.string(forKey: "sidebarMaterial"), SidebarMaterialOption.liquidGlass.rawValue)
    }

    func testMigrationDoesNotRerunAfterCompletion() {
        stampNativeSidebarPreset()
        defaults.set(2, forKey: ProgramaGlassSettings.sidebarMigrationVersionKey)
        ProgramaGlassSettings.migrateSidebarAppearanceDefaultsIfNeeded(
            defaults: defaults,
            nativeGlassAvailable: true
        )

        // A user who re-picks Native Sidebar after the migration must keep it.
        stampNativeSidebarPreset()
        ProgramaGlassSettings.migrateSidebarAppearanceDefaultsIfNeeded(
            defaults: defaults,
            nativeGlassAvailable: true
        )

        XCTAssertEqual(defaults.string(forKey: "sidebarPreset"), SidebarPresetOption.nativeSidebar.rawValue)
    }
}
