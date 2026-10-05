import Foundation

enum ProgramaGlassSurface: String, CaseIterable, Sendable {
    case window
    case sidebar
    case tabBar
    case overlays

    var environmentKey: String {
        switch self {
        case .window:
            return "PROGRAMA_TEST_FORCE_WINDOW_GLASS"
        case .sidebar:
            return "PROGRAMA_TEST_FORCE_SIDEBAR_GLASS"
        case .tabBar:
            return "PROGRAMA_TEST_FORCE_TAB_BAR_GLASS"
        case .overlays:
            return "PROGRAMA_TEST_FORCE_OVERLAY_GLASS"
        }
    }

    init?(commandValue: String) {
        switch commandValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "window": self = .window
        case "sidebar": self = .sidebar
        case "tabbar", "tab-bar", "tab_bar": self = .tabBar
        case "overlay", "overlays": self = .overlays
        default: return nil
        }
    }
}

enum ProgramaGlassSettings {
    static let windowEnabledKey = "bgGlassEnabled"
    static let tabBarEnabledKey = "tabBarLiquidGlassEnabled"
    static let overlaysEnabledKey = "overlayLiquidGlassEnabled"

    /// Environment is snapshotted once. The perf harness launches a fresh process for each
    /// ON/OFF sample, so glass selection never adds environment reads to a rendering hot path.
    private static let startupEnvironment = ProcessInfo.processInfo.environment

    static func parseOverride(
        for surface: ProgramaGlassSurface,
        environment: [String: String]
    ) -> Bool? {
        guard let rawValue = environment[surface.environmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        else {
            return nil
        }

        switch rawValue {
        case "1", "true", "yes", "on": return true
        case "0", "false", "no", "off": return false
        default: return nil
        }
    }

    static func startupOverride(for surface: ProgramaGlassSurface) -> Bool? {
        #if DEBUG
        parseOverride(for: surface, environment: startupEnvironment)
        #else
        nil
        #endif
    }

    static func resolvedEnabled(
        for surface: ProgramaGlassSurface,
        persistedValue: Bool
    ) -> Bool {
        startupOverride(for: surface) ?? persistedValue
    }

    /// A clean install uses the native inset panel only where AppKit can provide real Liquid
    /// Glass. Existing persisted sidebar choices continue to win over this startup default.
    static func defaultSidebarPreset(nativeGlassAvailable: Bool) -> SidebarPresetOption {
        nativeGlassAvailable ? .liquidGlass : .nativeSidebar
    }

    /// Returns the terminal fill opacity applied above the window glass. Opaque terminal
    /// backgrounds retain enough tint for readable text while allowing the glass to show through.
    static func effectiveTerminalBackgroundOpacity(
        configuredOpacity: Double,
        windowGlassEnabled _: Bool
    ) -> Double {
        // Inverted backdrop layout: the terminal pane is an opaque elevated card;
        // the glass material lives behind it in the sidebar backdrop. The old
        // 0.82 glass clamp forced a translucent terminal, which in turn forced a
        // transparent window and killed the backdrop's window-server blur.
        min(1.0, max(0.0, configuredOpacity))
    }

    static let sidebarMigrationVersionKey = "sidebarAppearanceDefaultsVersion"

    /// One-time sidebar appearance migration, version-gated via
    /// `sidebarAppearanceDefaultsVersion`. Values that the app itself stamped are
    /// migratable; values the user changed by hand are an explicit choice and win.
    static func migrateSidebarAppearanceDefaultsIfNeeded(
        defaults: UserDefaults,
        nativeGlassAvailable: Bool
    ) {
        let targetVersion = 3
        guard defaults.integer(forKey: sidebarMigrationVersionKey) < targetVersion else { return }

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

        // Migration v1 stamped every stock install with the nativeSidebar preset,
        // so on any machine that ran a post-v1 build the legacy fingerprint above
        // can no longer match — the Liquid Glass default would only ever reach
        // clean installs. The exact stamp is programmatic, not a user choice, so
        // v3 treats it as migratable too. Any hand-tuned value breaks the match
        // and keeps the user's setup.
        //
        // The stamp values are frozen literals, not the live nativeSidebar preset
        // accessors: if the preset's values ever change in a later release, the
        // historical stamp on users' disks does not, and reading the preset live
        // would make this fingerprint silently stop matching for anyone skipping
        // versions.
        //
        // The per-scheme tints and the match-terminal toggle are written only by
        // explicit user configuration (settings UI / config file), never by v1's
        // stamp — any of them present means this sidebar is not the untouched
        // default.
        let usesV1NativeSidebarStamp =
            material == SidebarMaterialOption.sidebar.rawValue &&
            blendMode == SidebarBlendModeOption.withinWindow.rawValue &&
            state == SidebarStateOption.followWindow.rawValue &&
            normalizeHex(tintHex) == "000000" &&
            approximatelyEqual(tintOpacity, 0.18) &&
            approximatelyEqual(blurOpacity, 1.0) &&
            approximatelyEqual(cornerRadius, 0.0) &&
            defaults.string(forKey: "sidebarTintHexLight") == nil &&
            defaults.string(forKey: "sidebarTintHexDark") == nil &&
            !defaults.bool(forKey: "sidebarMatchTerminalBackground")

        if usesLegacyDefaults || usesV1NativeSidebarStamp {
            applySidebarPreset(
                defaultSidebarPreset(nativeGlassAvailable: nativeGlassAvailable),
                defaults: defaults
            )
            // Where native glass is unavailable (older macOS) the stamp upgrade is a
            // no-op re-stamp, so leave the version below 3: a later launch after a
            // macOS upgrade re-evaluates instead of burning the migration on a
            // machine that could not show glass. v2 semantics are complete either way.
            defaults.set(
                nativeGlassAvailable ? targetVersion : 2,
                forKey: sidebarMigrationVersionKey
            )
            return
        }

        if material == SidebarMaterialOption.liquidGlass.rawValue,
           approximatelyEqual(cornerRadius, 0.0) {
            // Version 1 shipped the local glass sidebar flush on all four corners. Version 2
            // rounds only its terminal-facing edge; the NSWindow still masks the outer edge.
            defaults.set(SidebarPresetOption.liquidGlass.cornerRadius, forKey: "sidebarCornerRadius")
        }

        defaults.set(targetVersion, forKey: sidebarMigrationVersionKey)
    }

    private static func applySidebarPreset(
        _ preset: SidebarPresetOption,
        defaults: UserDefaults
    ) {
        defaults.set(preset.rawValue, forKey: "sidebarPreset")
        defaults.set(preset.material.rawValue, forKey: "sidebarMaterial")
        defaults.set(preset.blendMode.rawValue, forKey: "sidebarBlendMode")
        defaults.set(preset.state.rawValue, forKey: "sidebarState")
        defaults.set(preset.tintHex, forKey: "sidebarTintHex")
        defaults.set(preset.tintOpacity, forKey: "sidebarTintOpacity")
        defaults.set(preset.blurOpacity, forKey: "sidebarBlurOpacity")
        defaults.set(preset.cornerRadius, forKey: "sidebarCornerRadius")
    }

    private static func normalizeHex(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
            .uppercased()
    }

    private static func approximatelyEqual(_ lhs: Double, _ rhs: Double, tolerance: Double = 0.0001) -> Bool {
        abs(lhs - rhs) <= tolerance
    }

    /// Registers platform defaults without overwriting an explicit user choice. Only surfaces
    /// that have passed their independent gate are enabled here; later phases extend this map.
    static func platformDefaults(nativeGlassAvailable: Bool) -> [String: Any] {
        [
            windowEnabledKey: nativeGlassAvailable,
            tabBarEnabledKey: nativeGlassAvailable,
            overlaysEnabledKey: nativeGlassAvailable,
        ]
    }

    static func registerPlatformDefaults(
        defaults: UserDefaults = .standard,
        nativeGlassAvailable: Bool
    ) {
        defaults.register(defaults: platformDefaults(nativeGlassAvailable: nativeGlassAvailable))
    }

    #if DEBUG
    /// Mutates only debug-build preferences. This is used by the footprint script against a
    /// tagged app and intentionally performs no app activation or focus-changing work.
    static func setDebugEnabled(
        _ enabled: Bool,
        for surface: ProgramaGlassSurface,
        defaults: UserDefaults = .standard
    ) {
        switch surface {
        case .window:
            if enabled {
                defaults.set(SidebarBlendModeOption.behindWindow.rawValue, forKey: "sidebarBlendMode")
            }
            defaults.set(enabled, forKey: windowEnabledKey)
        case .sidebar:
            defaults.set(false, forKey: windowEnabledKey)
            defaults.set(SidebarBlendModeOption.withinWindow.rawValue, forKey: "sidebarBlendMode")
            defaults.set(
                enabled ? SidebarMaterialOption.liquidGlass.rawValue : SidebarMaterialOption.sidebar.rawValue,
                forKey: "sidebarMaterial"
            )
            defaults.set(
                enabled ? SidebarPresetOption.liquidGlass.cornerRadius : SidebarPresetOption.nativeSidebar.cornerRadius,
                forKey: "sidebarCornerRadius"
            )
        case .tabBar:
            defaults.set(enabled, forKey: tabBarEnabledKey)
        case .overlays:
            defaults.set(enabled, forKey: overlaysEnabledKey)
        }
    }
    #endif
}
