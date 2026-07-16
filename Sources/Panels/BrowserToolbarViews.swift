import SwiftUI
import AppKit
import Bonsplit

enum BrowserDevToolsIconOption: String, CaseIterable, Identifiable {
    case wrenchAndScrewdriver = "wrench.and.screwdriver"
    case wrenchAndScrewdriverFill = "wrench.and.screwdriver.fill"
    case curlyBracesSquare = "curlybraces.square"
    case curlyBraces = "curlybraces"
    case terminalFill = "terminal.fill"
    case terminal = "terminal"
    case hammer = "hammer"
    case hammerCircle = "hammer.circle"
    case ladybug = "ladybug"
    case ladybugFill = "ladybug.fill"
    case scope = "scope"
    case codeChevrons = "chevron.left.slash.chevron.right"
    case gearshape = "gearshape"
    case gearshapeFill = "gearshape.fill"
    case globe = "globe"
    case globeAmericas = "globe.americas.fill"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .wrenchAndScrewdriver: return "Wrench + Screwdriver"
        case .wrenchAndScrewdriverFill: return "Wrench + Screwdriver (Fill)"
        case .curlyBracesSquare: return "Curly Braces"
        case .curlyBraces: return "Curly Braces (Plain)"
        case .terminalFill: return "Terminal (Fill)"
        case .terminal: return "Terminal"
        case .hammer: return "Hammer"
        case .hammerCircle: return "Hammer Circle"
        case .ladybug: return "Bug"
        case .ladybugFill: return "Bug (Fill)"
        case .scope: return "Scope"
        case .codeChevrons: return "Code Chevrons"
        case .gearshape: return "Gear"
        case .gearshapeFill: return "Gear (Fill)"
        case .globe: return "Globe"
        case .globeAmericas: return "Globe Americas (Fill)"
        }
    }
}

enum BrowserDevToolsIconColorOption: String, CaseIterable, Identifiable {
    case bonsplitInactive
    case bonsplitActive
    case accent
    case tertiary

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bonsplitInactive: return "Bonsplit Inactive (Terminal/Globe)"
        case .bonsplitActive: return "Bonsplit Active (Terminal/Globe)"
        case .accent: return "Accent"
        case .tertiary: return "Tertiary"
        }
    }

    var color: Color {
        switch self {
        case .bonsplitInactive:
            // Matches Bonsplit tab icon tint for inactive tabs.
            return Color(nsColor: .secondaryLabelColor)
        case .bonsplitActive:
            // Matches Bonsplit tab icon tint for active tabs.
            return Color(nsColor: .labelColor)
        case .accent:
            return programaAccentColor()
        case .tertiary:
            return Color(nsColor: .tertiaryLabelColor)
        }
    }
}

enum BrowserDevToolsButtonDebugSettings {
    static let iconNameKey = "browserDevToolsIconName"
    static let iconColorKey = "browserDevToolsIconColor"
    static let defaultIcon = BrowserDevToolsIconOption.wrenchAndScrewdriver
    static let defaultColor = BrowserDevToolsIconColorOption.bonsplitInactive

    static func iconOption(defaults: UserDefaults = .standard) -> BrowserDevToolsIconOption {
        guard let raw = defaults.string(forKey: iconNameKey),
              let option = BrowserDevToolsIconOption(rawValue: raw) else {
            return defaultIcon
        }
        return option
    }

    static func colorOption(defaults: UserDefaults = .standard) -> BrowserDevToolsIconColorOption {
        guard let raw = defaults.string(forKey: iconColorKey),
              let option = BrowserDevToolsIconColorOption(rawValue: raw) else {
            return defaultColor
        }
        return option
    }

    static func copyPayload(defaults: UserDefaults = .standard) -> String {
        let icon = iconOption(defaults: defaults)
        let color = colorOption(defaults: defaults)
        return """
        browserDevToolsIconName=\(icon.rawValue)
        browserDevToolsIconColor=\(color.rawValue)
        """
    }
}

enum BrowserToolbarAccessorySpacingDebugSettings {
    static let key = "browserToolbarAccessorySpacing"
    static let defaultSpacing = 2
    static let supportedValues = [0, 2, 4, 6, 8]

    static func resolved(_ rawValue: Int) -> Int {
        supportedValues.contains(rawValue) ? rawValue : defaultSpacing
    }

    static func current(defaults: UserDefaults = .standard) -> Int {
        resolved(defaults.object(forKey: key) as? Int ?? defaultSpacing)
    }
}

enum BrowserProfilePopoverDebugSettings {
    static let horizontalPaddingKey = "browserProfilePopoverHorizontalPadding"
    static let verticalPaddingKey = "browserProfilePopoverVerticalPadding"
    static let defaultHorizontalPadding = 12.0
    static let defaultVerticalPadding = 10.0
    static let horizontalPaddingRange = 8.0...20.0
    static let verticalPaddingRange = 4.0...14.0

    static func resolvedHorizontalPadding(_ rawValue: Double) -> Double {
        horizontalPaddingRange.contains(rawValue) ? rawValue : defaultHorizontalPadding
    }

    static func resolvedVerticalPadding(_ rawValue: Double) -> Double {
        verticalPaddingRange.contains(rawValue) ? rawValue : defaultVerticalPadding
    }

    static func currentHorizontalPadding(defaults: UserDefaults = .standard) -> Double {
        resolvedHorizontalPadding((defaults.object(forKey: horizontalPaddingKey) as? NSNumber)?.doubleValue ?? defaultHorizontalPadding)
    }

    static func currentVerticalPadding(defaults: UserDefaults = .standard) -> Double {
        resolvedVerticalPadding((defaults.object(forKey: verticalPaddingKey) as? NSNumber)?.doubleValue ?? defaultVerticalPadding)
    }
}

func resolvedBrowserChromeBackgroundColor(
    for colorScheme: ColorScheme,
    themeBackgroundColor: NSColor
) -> NSColor {
    switch colorScheme {
    case .dark, .light:
        return themeBackgroundColor
    @unknown default:
        return themeBackgroundColor
    }
}

func resolvedBrowserChromeColorScheme(
    for colorScheme: ColorScheme,
    themeBackgroundColor: NSColor
) -> ColorScheme {
    let backgroundColor = resolvedBrowserChromeBackgroundColor(
        for: colorScheme,
        themeBackgroundColor: themeBackgroundColor
    )
    return backgroundColor.isLightColor ? .light : .dark
}

func resolvedBrowserOmnibarPillBackgroundColor(
    for colorScheme: ColorScheme,
    themeBackgroundColor: NSColor
) -> NSColor {
    let darkenMix: CGFloat
    switch colorScheme {
    case .light:
        darkenMix = 0.04
    case .dark:
        darkenMix = 0.05
    @unknown default:
        darkenMix = 0.04
    }

    return themeBackgroundColor.blended(withFraction: darkenMix, of: .black) ?? themeBackgroundColor
}

struct BrowserChromeStyle {
    let backgroundColor: NSColor
    let colorScheme: ColorScheme
    let omnibarPillBackgroundColor: NSColor

    static func resolve(
        for colorScheme: ColorScheme,
        themeBackgroundColor: NSColor
    ) -> BrowserChromeStyle {
        let backgroundColor = resolvedBrowserChromeBackgroundColor(
            for: colorScheme,
            themeBackgroundColor: themeBackgroundColor
        )
        let chromeColorScheme = resolvedBrowserChromeColorScheme(
            for: colorScheme,
            themeBackgroundColor: backgroundColor
        )
        let omnibarPillBackgroundColor = resolvedBrowserOmnibarPillBackgroundColor(
            for: chromeColorScheme,
            themeBackgroundColor: backgroundColor
        )
        return BrowserChromeStyle(
            backgroundColor: backgroundColor,
            colorScheme: chromeColorScheme,
            omnibarPillBackgroundColor: omnibarPillBackgroundColor
        )
    }
}

/// Back/forward/reload navigation buttons plus the in-progress download
/// indicator shown at the leading edge of the address bar.
struct BrowserNavigationButtonsView: View {
    let panel: BrowserPanel

    private let addressBarButtonHitSize: CGFloat = 26

    var body: some View {
        HStack(spacing: 0) {
            Button(action: {
                #if DEBUG
                dlog("browser.back panel=\(panel.id.uuidString.prefix(5))")
                #endif
                panel.goBack()
            }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: addressBarButtonHitSize, height: addressBarButtonHitSize, alignment: .center)
                    .contentShape(Rectangle())
            }
            .buttonStyle(OmnibarAddressButtonStyle())
            .disabled(!panel.canGoBack)
            .opacity(panel.canGoBack ? 1.0 : 0.4)
            .safeHelp(String(localized: "browser.goBack", defaultValue: "Go Back"))

            Button(action: {
                #if DEBUG
                dlog("browser.forward panel=\(panel.id.uuidString.prefix(5))")
                #endif
                panel.goForward()
            }) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: addressBarButtonHitSize, height: addressBarButtonHitSize, alignment: .center)
                    .contentShape(Rectangle())
            }
            .buttonStyle(OmnibarAddressButtonStyle())
            .disabled(!panel.canGoForward)
            .opacity(panel.canGoForward ? 1.0 : 0.4)
            .safeHelp(String(localized: "browser.goForward", defaultValue: "Go Forward"))

            Button(action: {
                if panel.isLoading {
                    #if DEBUG
                    dlog("browser.stop panel=\(panel.id.uuidString.prefix(5))")
                    #endif
                    panel.stopLoading()
                } else {
                    #if DEBUG
                    dlog("browser.reload panel=\(panel.id.uuidString.prefix(5))")
                    #endif
                    panel.reload()
                }
            }) {
                Image(systemName: panel.isLoading ? "xmark" : "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: addressBarButtonHitSize, height: addressBarButtonHitSize, alignment: .center)
                    .contentShape(Rectangle())
            }
            .buttonStyle(OmnibarAddressButtonStyle())
            .safeHelp(panel.isLoading ? String(localized: "browser.stop", defaultValue: "Stop") : String(localized: "browser.reload", defaultValue: "Reload"))

            if panel.isDownloading {
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.small)
                    Text(String(localized: "browser.downloading", defaultValue: "Downloading..."))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 6)
                .safeHelp(String(localized: "browser.downloadInProgress", defaultValue: "Download in progress"))
            }
        }
    }
}

/// Toolbar button + popover for switching/creating/renaming browser profiles.
struct BrowserProfileMenuView: View {
    enum Action {
        case newProfile
        case importBrowserData
        case renameProfile
    }

    let panel: BrowserPanel
    @ObservedObject private var browserProfileStore = BrowserProfileStore.shared
    let iconColor: Color
    @Binding var isPresented: Bool
    let popoverPadding: (horizontal: CGFloat, vertical: CGFloat)
    let onSelectProfile: (UUID) -> Void
    let onAction: (Action) -> Void

    private let addressBarButtonSize: CGFloat = 22
    private let devToolsButtonIconSize: CGFloat = 11

    var body: some View {
        Button(action: {
            isPresented.toggle()
        }) {
            Image(systemName: "person.crop.circle")
                .symbolRenderingMode(.monochrome)
                .programaFlatSymbolColorRendering()
                .font(.system(size: devToolsButtonIconSize, weight: .medium))
                .foregroundStyle(iconColor)
                .frame(width: addressBarButtonSize, height: addressBarButtonSize, alignment: .center)
        }
        .buttonStyle(OmnibarAddressButtonStyle())
        .frame(width: addressBarButtonSize, height: addressBarButtonSize, alignment: .center)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            popoverContent
        }
        .safeHelp(
            String(
                format: String(
                    localized: "browser.profile.buttonHelp",
                    defaultValue: "Browser Profile: %@"
                ),
                panel.profileDisplayName
            )
        )
        .accessibilityIdentifier("BrowserProfileButton")
    }

    private var popoverContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "browser.profile.menu.title", defaultValue: "Profiles"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                ForEach(browserProfileStore.profiles) { profile in
                    Button {
                        onSelectProfile(profile.id)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: profile.id == panel.profileID ? "checkmark" : "circle")
                                .font(.system(size: 10, weight: .semibold))
                                .opacity(profile.id == panel.profileID ? 1.0 : 0.0)
                                .frame(width: 12, alignment: .center)
                            Text(profile.displayName)
                                .font(.system(size: 12))
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .contentShape(Rectangle())
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(profile.id == panel.profileID ? Color.primary.opacity(0.12) : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider()

            Button {
                isPresented = false
                onAction(.newProfile)
            } label: {
                Text(String(localized: "browser.profile.new", defaultValue: "New Profile..."))
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)

            Button {
                onAction(.importBrowserData)
            } label: {
                Text(String(localized: "menu.view.importFromBrowser", defaultValue: "Import Browser Data…"))
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)

            if browserProfileStore.canRenameProfile(id: panel.profileID) {
                Button {
                    isPresented = false
                    onAction(.renameProfile)
                } label: {
                    Text(String(localized: "browser.profile.rename", defaultValue: "Rename Current Profile..."))
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, popoverPadding.horizontal)
        .padding(.vertical, popoverPadding.vertical)
        .frame(minWidth: 208)
    }
}

/// Toolbar button + popover for switching the browser theme mode.
struct BrowserThemeModeMenuView: View {
    let currentMode: BrowserThemeMode
    let iconColor: Color
    @Binding var isPresented: Bool
    let onSelectMode: (BrowserThemeMode) -> Void

    private let addressBarButtonSize: CGFloat = 22
    private let devToolsButtonIconSize: CGFloat = 11

    var body: some View {
        Button(action: {
            isPresented.toggle()
        }) {
            Image(systemName: currentMode.iconName)
                .symbolRenderingMode(.monochrome)
                .programaFlatSymbolColorRendering()
                .font(.system(size: devToolsButtonIconSize, weight: .medium))
                .foregroundStyle(iconColor)
                .frame(width: addressBarButtonSize, height: addressBarButtonSize, alignment: .center)
        }
        .buttonStyle(OmnibarAddressButtonStyle())
        .frame(width: addressBarButtonSize, height: addressBarButtonSize, alignment: .center)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            popoverContent
        }
        .safeHelp(
            String(
                format: String(
                    localized: "browser.theme.buttonHelp",
                    defaultValue: "Browser Theme: %@"
                ),
                currentMode.displayName
            )
        )
        .accessibilityIdentifier("BrowserThemeModeButton")
    }

    private var popoverContent: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(BrowserThemeMode.allCases) { mode in
                Button {
                    onSelectMode(mode)
                    isPresented = false
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: mode == currentMode ? "checkmark" : "circle")
                            .font(.system(size: 10, weight: .semibold))
                            .opacity(mode == currentMode ? 1.0 : 0.0)
                            .frame(width: 12, alignment: .center)
                        Text(mode.displayName)
                            .font(.system(size: 12))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .contentShape(Rectangle())
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(mode == currentMode ? Color.primary.opacity(0.12) : Color.clear)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("BrowserThemeModeOption\(mode.rawValue.capitalized)")
            }
        }
        .padding(8)
        .frame(minWidth: 128)
    }
}

/// Groups the browser-data import hint content shared by the blank-tab
/// overlays (floating card / inline strip) and the toolbar-chip popover.
/// All three presentations render the same hint body and action buttons.
struct BrowserImportHintContentView {
    let summary: String
    let onImport: () -> Void
    let onOpenSettings: () -> Void
    let onDismiss: () -> Void

    var popover: some View {
        hintBody
            .padding(12)
            .frame(width: 300, alignment: .leading)
    }

    private var hintBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "browser.import.hint.title", defaultValue: "Import browser data"))
                .font(.system(size: 12.5, weight: .semibold))

            Text(summary)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(String(localized: "browser.import.hint.settingsFootnote", defaultValue: "You can always find this in Settings > Browser."))
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    primaryButton
                    settingsButton
                    dismissButton
                }

                VStack(alignment: .leading, spacing: 8) {
                    primaryButton
                    HStack(spacing: 10) {
                        settingsButton
                        dismissButton
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var primaryButton: some View {
        Button(String(localized: "browser.import.hint.import", defaultValue: "Import…")) {
            onImport()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityIdentifier("BrowserImportHintImportButton")
    }

    private var settingsButton: some View {
        Button(String(localized: "browser.import.hint.settings", defaultValue: "Browser Settings")) {
            onOpenSettings()
        }
        .buttonStyle(.plain)
        .controlSize(.small)
        .accessibilityIdentifier("BrowserImportHintSettingsButton")
    }

    private var dismissButton: some View {
        Button(String(localized: "browser.import.hint.dismiss", defaultValue: "Hide Hint")) {
            onDismiss()
        }
        .buttonStyle(.plain)
        .controlSize(.small)
        .accessibilityIdentifier("BrowserImportHintDismissButton")
    }
}
