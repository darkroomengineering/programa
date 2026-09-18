import AppKit
import SwiftUI
import Darwin
import Bonsplit
import UniformTypeIdentifiers

private func localizedDebugLabel(_ value: String) -> String {
    String(localized: String.LocalizationValue(value))
}

#if DEBUG

final class SettingsAboutTitlebarDebugWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsAboutTitlebarDebugWindowController()

    private init() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 470, height: 690),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = localizedDebugLabel("Settings/About Titlebar Debug")
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("programa.settingsAboutTitlebarDebug")
        window.center()
        window.contentView = NSHostingView(rootView: SettingsAboutTitlebarDebugView())
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        SettingsAboutTitlebarStyleStore.shared.applyToOpenWindows()
    }
}

private struct SettingsAboutTitlebarDebugView: View {
    @ObservedObject private var store = SettingsAboutTitlebarStyleStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(localizedDebugLabel("Settings/About Titlebar Debug"))
                    .font(.headline)

                editor(for: .settings)
                editor(for: .about)

                GroupBox(localizedDebugLabel("Actions")) {
                    HStack(spacing: 10) {
                        Button(localizedDebugLabel("Reset All")) {
                            store.reset(.settings)
                            store.reset(.about)
                        }
                        Button(localizedDebugLabel("Reapply to Open Windows")) {
                            store.applyToOpenWindows()
                        }
                        Button(localizedDebugLabel("Copy Config")) {
                            store.copyConfigToPasteboard()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 2)
                }

                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func editor(for kind: SettingsAboutWindowKind) -> some View {
        let overridesEnabled = binding(for: kind, keyPath: \.overridesEnabled)

        return GroupBox(kind.displayTitle) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(localizedDebugLabel("Enable Debug Overrides"), isOn: overridesEnabled)

                Text(localizedDebugLabel("When disabled, Programa uses normal default titlebar behavior for this window."))
                    .font(.caption)
                    .foregroundColor(.secondary)

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Text(localizedDebugLabel("Window Title"))
                        TextField("", text: binding(for: kind, keyPath: \.windowTitle))
                    }

                    HStack(spacing: 10) {
                        Picker(localizedDebugLabel("Title Visibility"), selection: binding(for: kind, keyPath: \.titleVisibility)) {
                            ForEach(TitlebarVisibilityOption.allCases) { option in
                                Text(option.displayTitle).tag(option)
                            }
                        }
                        Picker(localizedDebugLabel("Toolbar Style"), selection: binding(for: kind, keyPath: \.toolbarStyle)) {
                            ForEach(TitlebarToolbarStyleOption.allCases) { option in
                                Text(option.displayTitle).tag(option)
                            }
                        }
                    }

                    Toggle(localizedDebugLabel("Show Toolbar"), isOn: binding(for: kind, keyPath: \.showToolbar))
                    Toggle(localizedDebugLabel("Transparent Titlebar"), isOn: binding(for: kind, keyPath: \.titlebarAppearsTransparent))
                    Toggle(localizedDebugLabel("Movable by Window Background"), isOn: binding(for: kind, keyPath: \.movableByWindowBackground))

                    Divider()

                    Text(localizedDebugLabel("Style Mask"))
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Toggle(localizedDebugLabel("Titled"), isOn: binding(for: kind, keyPath: \.titled))
                    Toggle(localizedDebugLabel("Closable"), isOn: binding(for: kind, keyPath: \.closable))
                    Toggle(localizedDebugLabel("Miniaturizable"), isOn: binding(for: kind, keyPath: \.miniaturizable))
                    Toggle(localizedDebugLabel("Resizable"), isOn: binding(for: kind, keyPath: \.resizable))
                    Toggle(localizedDebugLabel("Full Size Content View"), isOn: binding(for: kind, keyPath: \.fullSizeContentView))

                    HStack(spacing: 10) {
                        Button(
                            kind == .settings
                                ? localizedDebugLabel("Reset Settings")
                                : localizedDebugLabel("Reset About")
                        ) {
                            store.reset(kind)
                        }
                        Button(localizedDebugLabel("Apply Now")) {
                            store.applyToOpenWindows(for: kind)
                        }
                    }
                }
                .disabled(!overridesEnabled.wrappedValue)
                .opacity(overridesEnabled.wrappedValue ? 1 : 0.75)
            }
            .padding(.top, 2)
        }
    }

    private func binding<Value>(
        for kind: SettingsAboutWindowKind,
        keyPath: WritableKeyPath<SettingsAboutTitlebarDebugOptions, Value>
    ) -> Binding<Value> {
        Binding(
            get: { store.options(for: kind)[keyPath: keyPath] },
            set: { newValue in
                var updated = store.options(for: kind)
                updated[keyPath: keyPath] = newValue
                store.update(updated, for: kind)
            }
        )
    }
}

private enum DebugWindowConfigSnapshot {
    static func copyCombinedToPasteboard(defaults: UserDefaults = .standard) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(combinedPayload(defaults: defaults), forType: .string)
    }

    static func combinedPayload(defaults: UserDefaults = .standard) -> String {
        let sidebarPayload = """
        sidebarPreset=\(stringValue(defaults, key: "sidebarPreset", fallback: SidebarPresetOption.nativeSidebar.rawValue))
        sidebarMaterial=\(stringValue(defaults, key: "sidebarMaterial", fallback: SidebarMaterialOption.sidebar.rawValue))
        sidebarBlendMode=\(stringValue(defaults, key: "sidebarBlendMode", fallback: SidebarBlendModeOption.withinWindow.rawValue))
        sidebarState=\(stringValue(defaults, key: "sidebarState", fallback: SidebarStateOption.followWindow.rawValue))
        sidebarBlurOpacity=\(String(format: "%.2f", doubleValue(defaults, key: "sidebarBlurOpacity", fallback: 1.0)))
        sidebarTintHex=\(stringValue(defaults, key: "sidebarTintHex", fallback: "#000000"))
        sidebarTintHexLight=\(stringValue(defaults, key: "sidebarTintHexLight", fallback: "(nil)"))
        sidebarTintHexDark=\(stringValue(defaults, key: "sidebarTintHexDark", fallback: "(nil)"))
        sidebarTintOpacity=\(String(format: "%.2f", doubleValue(defaults, key: "sidebarTintOpacity", fallback: 0.18)))
        sidebarCornerRadius=\(String(format: "%.1f", doubleValue(defaults, key: "sidebarCornerRadius", fallback: 0.0)))
        sidebarActiveTabIndicatorStyle=\(stringValue(defaults, key: SidebarActiveTabIndicatorSettings.styleKey, fallback: SidebarActiveTabIndicatorSettings.defaultStyle.rawValue))
        sidebarDevBuildBannerVisible=\(boolValue(defaults, key: DevBuildBannerDebugSettings.sidebarBannerVisibleKey, fallback: DevBuildBannerDebugSettings.defaultShowSidebarBanner))
        shortcutHintSidebarXOffset=\(String(format: "%.1f", doubleValue(defaults, key: ShortcutHintDebugSettings.sidebarHintXKey, fallback: ShortcutHintDebugSettings.defaultSidebarHintX)))
        shortcutHintSidebarYOffset=\(String(format: "%.1f", doubleValue(defaults, key: ShortcutHintDebugSettings.sidebarHintYKey, fallback: ShortcutHintDebugSettings.defaultSidebarHintY)))
        shortcutHintTitlebarXOffset=\(String(format: "%.1f", doubleValue(defaults, key: ShortcutHintDebugSettings.titlebarHintXKey, fallback: ShortcutHintDebugSettings.defaultTitlebarHintX)))
        shortcutHintTitlebarYOffset=\(String(format: "%.1f", doubleValue(defaults, key: ShortcutHintDebugSettings.titlebarHintYKey, fallback: ShortcutHintDebugSettings.defaultTitlebarHintY)))
        shortcutHintPaneTabXOffset=\(String(format: "%.1f", doubleValue(defaults, key: ShortcutHintDebugSettings.paneHintXKey, fallback: ShortcutHintDebugSettings.defaultPaneHintX)))
        shortcutHintPaneTabYOffset=\(String(format: "%.1f", doubleValue(defaults, key: ShortcutHintDebugSettings.paneHintYKey, fallback: ShortcutHintDebugSettings.defaultPaneHintY)))
        shortcutHintAlwaysShow=\(boolValue(defaults, key: ShortcutHintDebugSettings.alwaysShowHintsKey, fallback: ShortcutHintDebugSettings.defaultAlwaysShowHints))
        shortcutHintShowOnCommandHold=\(boolValue(defaults, key: ShortcutHintDebugSettings.showHintsOnCommandHoldKey, fallback: ShortcutHintDebugSettings.defaultShowHintsOnCommandHold))
        """

        let backgroundPayload = """
        bgGlassEnabled=\(boolValue(defaults, key: "bgGlassEnabled", fallback: false))
        bgGlassMaterial=\(stringValue(defaults, key: "bgGlassMaterial", fallback: "hudWindow"))
        bgGlassTintHex=\(stringValue(defaults, key: "bgGlassTintHex", fallback: "#000000"))
        bgGlassTintOpacity=\(String(format: "%.2f", doubleValue(defaults, key: "bgGlassTintOpacity", fallback: 0.03)))
        """

        let menuBarPayload = MenuBarIconDebugSettings.copyPayload(defaults: defaults)
        let browserDevToolsPayload = BrowserDevToolsButtonDebugSettings.copyPayload(defaults: defaults)

        return """
        # Sidebar Debug
        \(sidebarPayload)

        # Background Debug
        \(backgroundPayload)

        # Menu Bar Extra Debug
        \(menuBarPayload)

        # Browser DevTools Button
        \(browserDevToolsPayload)
        """
    }

    private static func stringValue(_ defaults: UserDefaults, key: String, fallback: String) -> String {
        defaults.string(forKey: key) ?? fallback
    }

    private static func doubleValue(_ defaults: UserDefaults, key: String, fallback: Double) -> Double {
        if let value = defaults.object(forKey: key) as? NSNumber {
            return value.doubleValue
        }
        if let text = defaults.string(forKey: key), let parsed = Double(text) {
            return parsed
        }
        return fallback
    }

    private static func boolValue(_ defaults: UserDefaults, key: String, fallback: Bool) -> Bool {
        guard defaults.object(forKey: key) != nil else { return fallback }
        return defaults.bool(forKey: key)
    }
}

final class DebugWindowControlsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = DebugWindowControlsWindowController()

    private init() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 560),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = localizedDebugLabel("Debug Window Controls")
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("programa.debugWindowControls")
        window.center()
        window.contentView = NSHostingView(rootView: DebugWindowControlsView())
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct DebugWindowControlsView: View {
    @AppStorage(ShortcutHintDebugSettings.sidebarHintXKey) private var sidebarShortcutHintXOffset = ShortcutHintDebugSettings.defaultSidebarHintX
    @AppStorage(ShortcutHintDebugSettings.sidebarHintYKey) private var sidebarShortcutHintYOffset = ShortcutHintDebugSettings.defaultSidebarHintY
    @AppStorage(ShortcutHintDebugSettings.titlebarHintXKey) private var titlebarShortcutHintXOffset = ShortcutHintDebugSettings.defaultTitlebarHintX
    @AppStorage(ShortcutHintDebugSettings.titlebarHintYKey) private var titlebarShortcutHintYOffset = ShortcutHintDebugSettings.defaultTitlebarHintY
    @AppStorage(ShortcutHintDebugSettings.paneHintXKey) private var paneShortcutHintXOffset = ShortcutHintDebugSettings.defaultPaneHintX
    @AppStorage(ShortcutHintDebugSettings.paneHintYKey) private var paneShortcutHintYOffset = ShortcutHintDebugSettings.defaultPaneHintY
    @AppStorage(ShortcutHintDebugSettings.alwaysShowHintsKey) private var alwaysShowShortcutHints = ShortcutHintDebugSettings.defaultAlwaysShowHints
    @AppStorage(SidebarActiveTabIndicatorSettings.styleKey)
    private var sidebarActiveTabIndicatorStyle = SidebarActiveTabIndicatorSettings.defaultStyle.rawValue
    @AppStorage("debugTitlebarLeadingExtra") private var titlebarLeadingExtra: Double = 0
    @AppStorage(BrowserDevToolsButtonDebugSettings.iconNameKey) private var browserDevToolsIconNameRaw = BrowserDevToolsButtonDebugSettings.defaultIcon.rawValue
    @AppStorage(BrowserDevToolsButtonDebugSettings.iconColorKey) private var browserDevToolsIconColorRaw = BrowserDevToolsButtonDebugSettings.defaultColor.rawValue

    private var selectedDevToolsIconOption: BrowserDevToolsIconOption {
        BrowserDevToolsIconOption(rawValue: browserDevToolsIconNameRaw) ?? BrowserDevToolsButtonDebugSettings.defaultIcon
    }

    private var selectedDevToolsColorOption: BrowserDevToolsIconColorOption {
        BrowserDevToolsIconColorOption(rawValue: browserDevToolsIconColorRaw) ?? BrowserDevToolsButtonDebugSettings.defaultColor
    }

    private var selectedSidebarActiveTabIndicatorStyle: SidebarActiveTabIndicatorStyle {
        SidebarActiveTabIndicatorSettings.resolvedStyle(rawValue: sidebarActiveTabIndicatorStyle)
    }

    private var sidebarIndicatorStyleSelection: Binding<String> {
        Binding(
            get: { selectedSidebarActiveTabIndicatorStyle.rawValue },
            set: { sidebarActiveTabIndicatorStyle = $0 }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(localizedDebugLabel("Debug Window Controls"))
                    .font(.headline)

                GroupBox(localizedDebugLabel("Open")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Button(
                            String(
                                localized: "debug.menu.browserProfilePopoverDebug",
                                defaultValue: "Browser Profile Popover Debug…"
                            )
                        ) {
                            BrowserProfilePopoverDebugWindowController.shared.show()
                        }
                        Button(
                            String(
                                localized: "debug.menu.browserToolbarGlass",
                                defaultValue: "Browser Toolbar Glass Debug…"
                            )
                        ) {
                            BrowserToolbarGlassDebugWindowController.shared.show()
                        }
                        Button(localizedDebugLabel("Settings/About Titlebar Debug…")) {
                            SettingsAboutTitlebarDebugWindowController.shared.show()
                        }
                        Button(localizedDebugLabel("Sidebar Debug…")) {
                            SidebarDebugWindowController.shared.show()
                        }
                        Button(localizedDebugLabel("Background Debug…")) {
                            BackgroundDebugWindowController.shared.show()
                        }
                        Button(localizedDebugLabel("Menu Bar Extra Debug…")) {
                            MenuBarExtraDebugWindowController.shared.show()
                        }
                        Button(String(localized: "debug.menu.overlayGlass", defaultValue: "Overlay Glass Debug…")) {
                            OverlayGlassDebugWindowController.shared.show()
                        }
                        Button(localizedDebugLabel("Open All Debug Windows")) {
                            BrowserProfilePopoverDebugWindowController.shared.show()
                            BrowserToolbarGlassDebugWindowController.shared.show()
                            SettingsAboutTitlebarDebugWindowController.shared.show()
                            SidebarDebugWindowController.shared.show()
                            BackgroundDebugWindowController.shared.show()
                            MenuBarExtraDebugWindowController.shared.show()
                            OverlayGlassDebugWindowController.shared.show()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 2)
                }

                GroupBox(localizedDebugLabel("Shortcut Hints")) {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle(localizedDebugLabel("Always show shortcut hints"), isOn: $alwaysShowShortcutHints)

                        hintOffsetSection(
                            localizedDebugLabel("Sidebar Cmd+1…9"),
                            x: $sidebarShortcutHintXOffset,
                            y: $sidebarShortcutHintYOffset
                        )

                        hintOffsetSection(
                            localizedDebugLabel("Titlebar Buttons"),
                            x: $titlebarShortcutHintXOffset,
                            y: $titlebarShortcutHintYOffset
                        )

                        hintOffsetSection(
                            localizedDebugLabel("Pane Ctrl/Cmd+1…9"),
                            x: $paneShortcutHintXOffset,
                            y: $paneShortcutHintYOffset
                        )

                        HStack(spacing: 12) {
                            Button(localizedDebugLabel("Reset Hints")) {
                                resetShortcutHintOffsets()
                            }
                            Button(localizedDebugLabel("Copy Hint Config")) {
                                copyShortcutHintConfig()
                            }
                        }
                    }
                    .padding(.top, 2)
                }

                GroupBox(localizedDebugLabel("Active Workspace Indicator")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker(localizedDebugLabel("Style"), selection: sidebarIndicatorStyleSelection) {
                            ForEach(SidebarActiveTabIndicatorStyle.allCases) { style in
                                Text(style.displayName).tag(style.rawValue)
                            }
                        }
                        .pickerStyle(.menu)

                        Button(localizedDebugLabel("Reset Indicator Style")) {
                            sidebarActiveTabIndicatorStyle = SidebarActiveTabIndicatorSettings.defaultStyle.rawValue
                        }
                    }
                    .padding(.top, 2)
                }

                GroupBox(localizedDebugLabel("Titlebar Spacing")) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text(localizedDebugLabel("Leading extra"))
                            Slider(value: $titlebarLeadingExtra, in: 0...40)
                            Text(String(format: "%.0f", titlebarLeadingExtra))
                                .font(.caption)
                                .monospacedDigit()
                                .frame(width: 30, alignment: .trailing)
                        }
                        Button(localizedDebugLabel("Reset (0)")) {
                            titlebarLeadingExtra = 0
                        }
                    }
                    .padding(.top, 2)
                }

                GroupBox(localizedDebugLabel("Browser DevTools Button")) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Text(localizedDebugLabel("Icon"))
                            Picker(localizedDebugLabel("Icon"), selection: $browserDevToolsIconNameRaw) {
                                ForEach(BrowserDevToolsIconOption.allCases) { option in
                                    Text(option.title).tag(option.rawValue)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            Spacer()
                        }

                        HStack(spacing: 8) {
                            Text(localizedDebugLabel("Color"))
                            Picker(localizedDebugLabel("Color"), selection: $browserDevToolsIconColorRaw) {
                                ForEach(BrowserDevToolsIconColorOption.allCases) { option in
                                    Text(option.title).tag(option.rawValue)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            Spacer()
                        }

                        HStack(spacing: 8) {
                            Text(localizedDebugLabel("Preview"))
                            Spacer()
                            Image(systemName: selectedDevToolsIconOption.rawValue)
                                .symbolRasterSize(12, weight: .medium)
                                .foregroundStyle(selectedDevToolsColorOption.color)
                        }

                        HStack(spacing: 12) {
                            Button(localizedDebugLabel("Reset Button")) {
                                resetBrowserDevToolsButton()
                            }
                            Button(localizedDebugLabel("Copy Button Config")) {
                                copyBrowserDevToolsButtonConfig()
                            }
                        }
                    }
                    .padding(.top, 2)
                }

                GroupBox(localizedDebugLabel("Copy")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Button(localizedDebugLabel("Copy All Debug Config")) {
                            DebugWindowConfigSnapshot.copyCombinedToPasteboard()
                        }
                        Text(localizedDebugLabel("Copies sidebar, background, menu bar, and browser devtools settings as one payload."))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 2)
                }

                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func hintOffsetSection(_ title: String, x: Binding<Double>, y: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            sliderRow("X", value: x)
            sliderRow("Y", value: y)
        }
    }

    private func sliderRow(_ label: String, value: Binding<Double>) -> some View {
        HStack(spacing: 8) {
            Text(localizedDebugLabel(label))
            Slider(value: value, in: ShortcutHintDebugSettings.offsetRange)
            Text(String(format: "%.1f", ShortcutHintDebugSettings.clamped(value.wrappedValue)))
                .font(.caption)
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)
        }
    }

    private func resetShortcutHintOffsets() {
        sidebarShortcutHintXOffset = ShortcutHintDebugSettings.defaultSidebarHintX
        sidebarShortcutHintYOffset = ShortcutHintDebugSettings.defaultSidebarHintY
        titlebarShortcutHintXOffset = ShortcutHintDebugSettings.defaultTitlebarHintX
        titlebarShortcutHintYOffset = ShortcutHintDebugSettings.defaultTitlebarHintY
        paneShortcutHintXOffset = ShortcutHintDebugSettings.defaultPaneHintX
        paneShortcutHintYOffset = ShortcutHintDebugSettings.defaultPaneHintY
        alwaysShowShortcutHints = ShortcutHintDebugSettings.defaultAlwaysShowHints
    }

    private func copyShortcutHintConfig() {
        let payload = """
        shortcutHintSidebarXOffset=\(String(format: "%.1f", ShortcutHintDebugSettings.clamped(sidebarShortcutHintXOffset)))
        shortcutHintSidebarYOffset=\(String(format: "%.1f", ShortcutHintDebugSettings.clamped(sidebarShortcutHintYOffset)))
        shortcutHintTitlebarXOffset=\(String(format: "%.1f", ShortcutHintDebugSettings.clamped(titlebarShortcutHintXOffset)))
        shortcutHintTitlebarYOffset=\(String(format: "%.1f", ShortcutHintDebugSettings.clamped(titlebarShortcutHintYOffset)))
        shortcutHintPaneTabXOffset=\(String(format: "%.1f", ShortcutHintDebugSettings.clamped(paneShortcutHintXOffset)))
        shortcutHintPaneTabYOffset=\(String(format: "%.1f", ShortcutHintDebugSettings.clamped(paneShortcutHintYOffset)))
        shortcutHintAlwaysShow=\(alwaysShowShortcutHints)
        """
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(payload, forType: .string)
    }

    private func resetBrowserDevToolsButton() {
        browserDevToolsIconNameRaw = BrowserDevToolsButtonDebugSettings.defaultIcon.rawValue
        browserDevToolsIconColorRaw = BrowserDevToolsButtonDebugSettings.defaultColor.rawValue
    }

    private func copyBrowserDevToolsButtonConfig() {
        let payload = BrowserDevToolsButtonDebugSettings.copyPayload(defaults: .standard)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(payload, forType: .string)
    }
}

final class BrowserProfilePopoverDebugWindowController: NSWindowController, NSWindowDelegate {
    static let shared = BrowserProfilePopoverDebugWindowController()

    private init() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 340),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = String(
            localized: "debug.windows.browserProfilePopover.title",
            defaultValue: "Browser Profile Popover Debug"
        )
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("programa.browserProfilePopoverDebug")
        window.center()
        window.contentView = NSHostingView(rootView: BrowserProfilePopoverDebugView())
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct BrowserProfilePopoverDebugView: View {
    @AppStorage(BrowserProfilePopoverDebugSettings.horizontalPaddingKey)
    private var horizontalPaddingRaw = BrowserProfilePopoverDebugSettings.defaultHorizontalPadding
    @AppStorage(BrowserProfilePopoverDebugSettings.verticalPaddingKey)
    private var verticalPaddingRaw = BrowserProfilePopoverDebugSettings.defaultVerticalPadding

    private var horizontalPaddingBinding: Binding<Double> {
        Binding(
            get: { BrowserProfilePopoverDebugSettings.resolvedHorizontalPadding(horizontalPaddingRaw) },
            set: { horizontalPaddingRaw = BrowserProfilePopoverDebugSettings.resolvedHorizontalPadding($0) }
        )
    }

    private var verticalPaddingBinding: Binding<Double> {
        Binding(
            get: { BrowserProfilePopoverDebugSettings.resolvedVerticalPadding(verticalPaddingRaw) },
            set: { verticalPaddingRaw = BrowserProfilePopoverDebugSettings.resolvedVerticalPadding($0) }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(
                    String(
                        localized: "debug.browserProfilePopover.heading",
                        defaultValue: "Browser Profile Popover"
                    )
                )
                .font(.headline)

                Text(
                    String(
                        localized: "debug.browserProfilePopover.note",
                        defaultValue: "Tune the profile popover padding live while comparing it against the browser toolbar menu."
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                GroupBox(
                    String(
                        localized: "debug.browserProfilePopover.group.padding",
                        defaultValue: "Padding"
                    )
                ) {
                    VStack(alignment: .leading, spacing: 8) {
                        sliderRow(
                            String(
                                localized: "debug.browserProfilePopover.label.horizontal",
                                defaultValue: "Horizontal"
                            ),
                            value: horizontalPaddingBinding,
                            range: BrowserProfilePopoverDebugSettings.horizontalPaddingRange
                        )
                        sliderRow(
                            String(
                                localized: "debug.browserProfilePopover.label.vertical",
                                defaultValue: "Vertical"
                            ),
                            value: verticalPaddingBinding,
                            range: BrowserProfilePopoverDebugSettings.verticalPaddingRange
                        )
                    }
                    .padding(.top, 2)
                }

                GroupBox(
                    String(
                        localized: "debug.browserProfilePopover.group.preview",
                        defaultValue: "Preview"
                    )
                ) {
                    profilePopoverPreview
                        .padding(.top, 2)
                }

                HStack(spacing: 12) {
                    Button(
                        String(
                            localized: "debug.browserProfilePopover.reset",
                            defaultValue: "Reset"
                        )
                    ) {
                        horizontalPaddingRaw = BrowserProfilePopoverDebugSettings.defaultHorizontalPadding
                        verticalPaddingRaw = BrowserProfilePopoverDebugSettings.defaultVerticalPadding
                    }
                }

                Text(
                    String(
                        localized: "debug.browserProfilePopover.liveNote",
                        defaultValue: "Changes apply live to the browser profile popover."
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var profilePopoverPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "browser.profile.menu.title", defaultValue: "Profiles"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 12, alignment: .center)
                    Text(String(localized: "browser.profile.default", defaultValue: "Default"))
                        .font(.system(size: 12))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.12))
                )
            }

            Divider()

            Text(String(localized: "browser.profile.new", defaultValue: "New Profile..."))
                .font(.system(size: 12))
        }
        .padding(.horizontal, BrowserProfilePopoverDebugSettings.resolvedHorizontalPadding(horizontalPaddingRaw))
        .padding(.vertical, BrowserProfilePopoverDebugSettings.resolvedVerticalPadding(verticalPaddingRaw))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.primary.opacity(0.08))
                )
        )
    }

    private func sliderRow(_ label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack(spacing: 8) {
            Text(localizedDebugLabel(label))
            Slider(value: value, in: range, step: 1)
            Text(String(format: "%.0f", value.wrappedValue))
                .font(.caption)
                .monospacedDigit()
                .frame(width: 32, alignment: .trailing)
        }
    }
}

final class SidebarDebugWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SidebarDebugWindowController()

    private init() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 520),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = localizedDebugLabel("Sidebar Debug")
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("programa.sidebarDebug")
        window.center()
        window.contentView = NSHostingView(rootView: SidebarDebugView())
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct SidebarDebugView: View {
    @AppStorage("sidebarMatchTerminalBackground") private var matchTerminalBackground = false
    @AppStorage("sidebarPreset") private var sidebarPreset = SidebarPresetOption.nativeSidebar.rawValue
    @AppStorage("sidebarTintOpacity") private var sidebarTintOpacity = SidebarTintDefaults.opacity
    @AppStorage("sidebarTintHex") private var sidebarTintHex = SidebarTintDefaults.hex
    @AppStorage("sidebarTintHexLight") private var sidebarTintHexLight: String?
    @AppStorage("sidebarTintHexDark") private var sidebarTintHexDark: String?
    @AppStorage("sidebarMaterial") private var sidebarMaterial = SidebarMaterialOption.sidebar.rawValue
    @AppStorage("sidebarBlendMode") private var sidebarBlendMode = SidebarBlendModeOption.withinWindow.rawValue
    @AppStorage("sidebarState") private var sidebarState = SidebarStateOption.followWindow.rawValue
    @AppStorage("sidebarCornerRadius") private var sidebarCornerRadius = 0.0
    @AppStorage("sidebarBlurOpacity") private var sidebarBlurOpacity = 1.0
    @AppStorage(ShortcutHintDebugSettings.sidebarHintXKey) private var sidebarShortcutHintXOffset = ShortcutHintDebugSettings.defaultSidebarHintX
    @AppStorage(ShortcutHintDebugSettings.sidebarHintYKey) private var sidebarShortcutHintYOffset = ShortcutHintDebugSettings.defaultSidebarHintY
    @AppStorage(ShortcutHintDebugSettings.titlebarHintXKey) private var titlebarShortcutHintXOffset = ShortcutHintDebugSettings.defaultTitlebarHintX
    @AppStorage(ShortcutHintDebugSettings.titlebarHintYKey) private var titlebarShortcutHintYOffset = ShortcutHintDebugSettings.defaultTitlebarHintY
    @AppStorage(ShortcutHintDebugSettings.paneHintXKey) private var paneShortcutHintXOffset = ShortcutHintDebugSettings.defaultPaneHintX
    @AppStorage(ShortcutHintDebugSettings.paneHintYKey) private var paneShortcutHintYOffset = ShortcutHintDebugSettings.defaultPaneHintY
    @AppStorage(ShortcutHintDebugSettings.alwaysShowHintsKey) private var alwaysShowShortcutHints = ShortcutHintDebugSettings.defaultAlwaysShowHints
    @AppStorage(DevBuildBannerDebugSettings.sidebarBannerVisibleKey)
    private var showSidebarDevBuildBanner = DevBuildBannerDebugSettings.defaultShowSidebarBanner
    @AppStorage(SidebarActiveTabIndicatorSettings.styleKey)
    private var sidebarActiveTabIndicatorStyle = SidebarActiveTabIndicatorSettings.defaultStyle.rawValue
    @AppStorage("sidebarSelectionColorHex") private var sidebarSelectionColorHex: String?

    private var selectedSidebarIndicatorStyle: SidebarActiveTabIndicatorStyle {
        SidebarActiveTabIndicatorSettings.resolvedStyle(rawValue: sidebarActiveTabIndicatorStyle)
    }

    private var sidebarIndicatorStyleSelection: Binding<String> {
        Binding(
            get: { selectedSidebarIndicatorStyle.rawValue },
            set: { sidebarActiveTabIndicatorStyle = $0 }
        )
    }

    private var selectionColorBinding: Binding<Color> {
        Binding(
            get: {
                if let hex = sidebarSelectionColorHex, let nsColor = NSColor(hex: hex) {
                    return Color(nsColor: nsColor)
                }
                return programaAccentColor()
            },
            set: { newColor in
                let nsColor = NSColor(newColor)
                sidebarSelectionColorHex = nsColor.hexString()
            }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(localizedDebugLabel("Sidebar Appearance"))
                    .font(.headline)

                Toggle(String(localized: "settings.sidebarAppearance.matchTerminalBackground", defaultValue: "Match Terminal Background"), isOn: $matchTerminalBackground)

                GroupBox(localizedDebugLabel("Presets")) {
                    Picker(localizedDebugLabel("Preset"), selection: $sidebarPreset) {
                        ForEach(SidebarPresetOption.allCases) { option in
                            Text(option.title).tag(option.rawValue)
                        }
                    }
                    .onChange(of: sidebarPreset) {
                        applyPreset()
                    }
                    .padding(.top, 2)
                }

                GroupBox(localizedDebugLabel("Blur")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker(localizedDebugLabel("Material"), selection: $sidebarMaterial) {
                            ForEach(SidebarMaterialOption.allCases) { option in
                                Text(option.title).tag(option.rawValue)
                            }
                        }

                        Picker(localizedDebugLabel("Blending"), selection: $sidebarBlendMode) {
                            ForEach(SidebarBlendModeOption.allCases) { option in
                                Text(option.title).tag(option.rawValue)
                            }
                        }

                        Picker(localizedDebugLabel("State"), selection: $sidebarState) {
                            ForEach(SidebarStateOption.allCases) { option in
                                Text(option.title).tag(option.rawValue)
                            }
                        }

                        HStack(spacing: 8) {
                            Text(localizedDebugLabel("Strength"))
                            Slider(value: $sidebarBlurOpacity, in: 0...1)
                            Text(String(format: "%.0f%%", sidebarBlurOpacity * 100))
                                .font(.caption)
                                .frame(width: 44, alignment: .trailing)
                        }
                    }
                    .padding(.top, 2)
                }

                GroupBox(localizedDebugLabel("Tint")) {
                    VStack(alignment: .leading, spacing: 8) {
                        ColorPicker(localizedDebugLabel("Tint Color"), selection: tintColorBinding, supportsOpacity: false)

                        HStack(spacing: 8) {
                            Text(localizedDebugLabel("Opacity"))
                            Slider(value: $sidebarTintOpacity, in: 0...0.7)
                            Text(String(format: "%.0f%%", sidebarTintOpacity * 100))
                                .font(.caption)
                                .frame(width: 44, alignment: .trailing)
                        }
                    }
                    .padding(.top, 2)
                }

                GroupBox(localizedDebugLabel("Shape")) {
                    HStack(spacing: 8) {
                        Text(localizedDebugLabel("Corner Radius"))
                        Slider(value: $sidebarCornerRadius, in: 0...20)
                        Text(String(format: "%.0f", sidebarCornerRadius))
                            .font(.caption)
                            .frame(width: 32, alignment: .trailing)
                    }
                    .padding(.top, 2)
                }

                GroupBox(localizedDebugLabel("Shortcut Hints")) {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle(localizedDebugLabel("Always show shortcut hints"), isOn: $alwaysShowShortcutHints)

                        hintOffsetSection(
                            localizedDebugLabel("Sidebar Cmd+1…9"),
                            x: $sidebarShortcutHintXOffset,
                            y: $sidebarShortcutHintYOffset
                        )

                        hintOffsetSection(
                            localizedDebugLabel("Titlebar Buttons"),
                            x: $titlebarShortcutHintXOffset,
                            y: $titlebarShortcutHintYOffset
                        )

                        hintOffsetSection(
                            localizedDebugLabel("Pane Ctrl/Cmd+1…9"),
                            x: $paneShortcutHintXOffset,
                            y: $paneShortcutHintYOffset
                        )
                    }
                    .padding(.top, 2)
                }

                GroupBox(localizedDebugLabel("Active Workspace Indicator")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker(localizedDebugLabel("Style"), selection: sidebarIndicatorStyleSelection) {
                            ForEach(SidebarActiveTabIndicatorStyle.allCases) { style in
                                Text(style.displayName).tag(style.rawValue)
                            }
                        }

                        ColorPicker(String(localized: "sidebar.debug.selectionColor", defaultValue: "Selection Color"), selection: selectionColorBinding, supportsOpacity: false)

                        if sidebarSelectionColorHex != nil {
                            Button(String(localized: "sidebar.debug.resetSelectionColor", defaultValue: "Reset to Default")) {
                                sidebarSelectionColorHex = nil
                            }
                            .font(.caption)
                        }
                    }
                    .padding(.top, 2)
                }

                HStack(spacing: 12) {
                    Button(localizedDebugLabel("Reset Tint")) {
                        sidebarTintOpacity = 0.62
                        sidebarTintHex = SidebarTintDefaults.hex
                        sidebarTintHexLight = nil
                        sidebarTintHexDark = nil
                    }
                    Button(localizedDebugLabel("Reset Blur")) {
                        sidebarMaterial = SidebarMaterialOption.hudWindow.rawValue
                        sidebarBlendMode = SidebarBlendModeOption.withinWindow.rawValue
                        sidebarState = SidebarStateOption.active.rawValue
                        sidebarBlurOpacity = 0.98
                    }
                    Button(localizedDebugLabel("Reset Shape")) {
                        sidebarCornerRadius = 0.0
                    }
                    Button(localizedDebugLabel("Reset Hints")) {
                        resetShortcutHintOffsets()
                    }
                    Button(localizedDebugLabel("Reset Active Indicator")) {
                        sidebarActiveTabIndicatorStyle = SidebarActiveTabIndicatorSettings.defaultStyle.rawValue
                        sidebarSelectionColorHex = nil
                    }
                }

                Button(localizedDebugLabel("Copy Config")) {
                    copySidebarConfig()
                }

                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var tintColorBinding: Binding<Color> {
        Binding(
            get: {
                Color(nsColor: NSColor(hex: sidebarTintHex) ?? .black)
            },
            set: { newColor in
                let nsColor = NSColor(newColor)
                sidebarTintHex = nsColor.hexString()
            }
        )
    }

    private func hintOffsetSection(_ title: String, x: Binding<Double>, y: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            sliderRow("X", value: x)
            sliderRow("Y", value: y)
        }
    }

    private func sliderRow(_ label: String, value: Binding<Double>) -> some View {
        HStack(spacing: 8) {
            Text(localizedDebugLabel(label))
            Slider(value: value, in: ShortcutHintDebugSettings.offsetRange)
            Text(String(format: "%.1f", ShortcutHintDebugSettings.clamped(value.wrappedValue)))
                .font(.caption)
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)
        }
    }

    private func resetShortcutHintOffsets() {
        sidebarShortcutHintXOffset = ShortcutHintDebugSettings.defaultSidebarHintX
        sidebarShortcutHintYOffset = ShortcutHintDebugSettings.defaultSidebarHintY
        titlebarShortcutHintXOffset = ShortcutHintDebugSettings.defaultTitlebarHintX
        titlebarShortcutHintYOffset = ShortcutHintDebugSettings.defaultTitlebarHintY
        paneShortcutHintXOffset = ShortcutHintDebugSettings.defaultPaneHintX
        paneShortcutHintYOffset = ShortcutHintDebugSettings.defaultPaneHintY
        alwaysShowShortcutHints = ShortcutHintDebugSettings.defaultAlwaysShowHints
    }

    private func copySidebarConfig() {
        let payload = """
        sidebarPreset=\(sidebarPreset)
        sidebarMaterial=\(sidebarMaterial)
        sidebarBlendMode=\(sidebarBlendMode)
        sidebarState=\(sidebarState)
        sidebarBlurOpacity=\(String(format: "%.2f", sidebarBlurOpacity))
        sidebarTintHex=\(sidebarTintHex)
        sidebarTintHexLight=\(sidebarTintHexLight ?? "(nil)")
        sidebarTintHexDark=\(sidebarTintHexDark ?? "(nil)")
        sidebarTintOpacity=\(String(format: "%.2f", sidebarTintOpacity))
        sidebarCornerRadius=\(String(format: "%.1f", sidebarCornerRadius))
        sidebarActiveTabIndicatorStyle=\(sidebarActiveTabIndicatorStyle)
        sidebarDevBuildBannerVisible=\(showSidebarDevBuildBanner)
        shortcutHintSidebarXOffset=\(String(format: "%.1f", ShortcutHintDebugSettings.clamped(sidebarShortcutHintXOffset)))
        shortcutHintSidebarYOffset=\(String(format: "%.1f", ShortcutHintDebugSettings.clamped(sidebarShortcutHintYOffset)))
        shortcutHintTitlebarXOffset=\(String(format: "%.1f", ShortcutHintDebugSettings.clamped(titlebarShortcutHintXOffset)))
        shortcutHintTitlebarYOffset=\(String(format: "%.1f", ShortcutHintDebugSettings.clamped(titlebarShortcutHintYOffset)))
        shortcutHintPaneTabXOffset=\(String(format: "%.1f", ShortcutHintDebugSettings.clamped(paneShortcutHintXOffset)))
        shortcutHintPaneTabYOffset=\(String(format: "%.1f", ShortcutHintDebugSettings.clamped(paneShortcutHintYOffset)))
        shortcutHintAlwaysShow=\(alwaysShowShortcutHints)
        """
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(payload, forType: .string)
    }

    private func applyPreset() {
        guard let preset = SidebarPresetOption(rawValue: sidebarPreset) else { return }
        sidebarMaterial = preset.material.rawValue
        sidebarBlendMode = preset.blendMode.rawValue
        sidebarState = preset.state.rawValue
        sidebarTintHex = preset.tintHex
        sidebarTintOpacity = preset.tintOpacity
        sidebarCornerRadius = preset.cornerRadius
        sidebarBlurOpacity = preset.blurOpacity
        sidebarTintHexLight = nil
        sidebarTintHexDark = nil
    }
}

// MARK: - Menu Bar Extra Debug Window

final class MenuBarExtraDebugWindowController: NSWindowController, NSWindowDelegate {
    static let shared = MenuBarExtraDebugWindowController()

    private init() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 430),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = localizedDebugLabel("Menu Bar Extra Debug")
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("programa.menubarDebug")
        window.center()
        window.contentView = NSHostingView(rootView: MenuBarExtraDebugView())
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct MenuBarExtraDebugView: View {
    @AppStorage(MenuBarIconDebugSettings.previewEnabledKey) private var previewEnabled = false
    @AppStorage(MenuBarIconDebugSettings.previewCountKey) private var previewCount = 1
    @AppStorage(MenuBarIconDebugSettings.badgeRectXKey) private var badgeRectX = Double(MenuBarIconDebugSettings.defaultBadgeRect.origin.x)
    @AppStorage(MenuBarIconDebugSettings.badgeRectYKey) private var badgeRectY = Double(MenuBarIconDebugSettings.defaultBadgeRect.origin.y)
    @AppStorage(MenuBarIconDebugSettings.badgeRectWidthKey) private var badgeRectWidth = Double(MenuBarIconDebugSettings.defaultBadgeRect.width)
    @AppStorage(MenuBarIconDebugSettings.badgeRectHeightKey) private var badgeRectHeight = Double(MenuBarIconDebugSettings.defaultBadgeRect.height)
    @AppStorage(MenuBarIconDebugSettings.singleDigitFontSizeKey) private var singleDigitFontSize = Double(MenuBarIconDebugSettings.defaultSingleDigitFontSize)
    @AppStorage(MenuBarIconDebugSettings.multiDigitFontSizeKey) private var multiDigitFontSize = Double(MenuBarIconDebugSettings.defaultMultiDigitFontSize)
    @AppStorage(MenuBarIconDebugSettings.singleDigitYOffsetKey) private var singleDigitYOffset = Double(MenuBarIconDebugSettings.defaultSingleDigitYOffset)
    @AppStorage(MenuBarIconDebugSettings.multiDigitYOffsetKey) private var multiDigitYOffset = Double(MenuBarIconDebugSettings.defaultMultiDigitYOffset)
    @AppStorage(MenuBarIconDebugSettings.singleDigitXAdjustKey) private var singleDigitXAdjust = Double(MenuBarIconDebugSettings.defaultSingleDigitXAdjust)
    @AppStorage(MenuBarIconDebugSettings.multiDigitXAdjustKey) private var multiDigitXAdjust = Double(MenuBarIconDebugSettings.defaultMultiDigitXAdjust)
    @AppStorage(MenuBarIconDebugSettings.textRectWidthAdjustKey) private var textRectWidthAdjust = Double(MenuBarIconDebugSettings.defaultTextRectWidthAdjust)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(localizedDebugLabel("Menu Bar Extra Icon"))
                    .font(.headline)

                GroupBox(localizedDebugLabel("Preview Count")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(localizedDebugLabel("Override unread count"), isOn: $previewEnabled)

                        Stepper(value: $previewCount, in: 0...99) {
                            HStack {
                                Text(localizedDebugLabel("Unread Count"))
                                Spacer()
                                Text("\(previewCount)")
                                    .font(.caption)
                                    .monospacedDigit()
                            }
                        }
                        .disabled(!previewEnabled)
                    }
                    .padding(.top, 2)
                }

                GroupBox(localizedDebugLabel("Badge Rect")) {
                    VStack(alignment: .leading, spacing: 8) {
                        sliderRow("X", value: $badgeRectX, range: 0...20, format: "%.2f")
                        sliderRow("Y", value: $badgeRectY, range: 0...20, format: "%.2f")
                        sliderRow("Width", value: $badgeRectWidth, range: 4...14, format: "%.2f")
                        sliderRow("Height", value: $badgeRectHeight, range: 4...14, format: "%.2f")
                    }
                    .padding(.top, 2)
                }

                GroupBox(localizedDebugLabel("Badge Text")) {
                    VStack(alignment: .leading, spacing: 8) {
                        sliderRow("1-digit size", value: $singleDigitFontSize, range: 6...14, format: "%.2f")
                        sliderRow("2-digit size", value: $multiDigitFontSize, range: 6...14, format: "%.2f")
                        sliderRow("1-digit X", value: $singleDigitXAdjust, range: -4...4, format: "%.2f")
                        sliderRow("2-digit X", value: $multiDigitXAdjust, range: -4...4, format: "%.2f")
                        sliderRow("1-digit Y", value: $singleDigitYOffset, range: -3...4, format: "%.2f")
                        sliderRow("2-digit Y", value: $multiDigitYOffset, range: -3...4, format: "%.2f")
                        sliderRow("Text width adjust", value: $textRectWidthAdjust, range: -3...5, format: "%.2f")
                    }
                    .padding(.top, 2)
                }

                HStack(spacing: 12) {
                    Button(localizedDebugLabel("Reset")) {
                        previewEnabled = false
                        previewCount = 1
                        badgeRectX = Double(MenuBarIconDebugSettings.defaultBadgeRect.origin.x)
                        badgeRectY = Double(MenuBarIconDebugSettings.defaultBadgeRect.origin.y)
                        badgeRectWidth = Double(MenuBarIconDebugSettings.defaultBadgeRect.width)
                        badgeRectHeight = Double(MenuBarIconDebugSettings.defaultBadgeRect.height)
                        singleDigitFontSize = Double(MenuBarIconDebugSettings.defaultSingleDigitFontSize)
                        multiDigitFontSize = Double(MenuBarIconDebugSettings.defaultMultiDigitFontSize)
                        singleDigitYOffset = Double(MenuBarIconDebugSettings.defaultSingleDigitYOffset)
                        multiDigitYOffset = Double(MenuBarIconDebugSettings.defaultMultiDigitYOffset)
                        singleDigitXAdjust = Double(MenuBarIconDebugSettings.defaultSingleDigitXAdjust)
                        multiDigitXAdjust = Double(MenuBarIconDebugSettings.defaultMultiDigitXAdjust)
                        textRectWidthAdjust = Double(MenuBarIconDebugSettings.defaultTextRectWidthAdjust)
                        applyLiveUpdate()
                    }

                    Button(localizedDebugLabel("Copy Config")) {
                        let payload = MenuBarIconDebugSettings.copyPayload()
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(payload, forType: .string)
                    }
                }

                Text(localizedDebugLabel("Tip: enable override count, then tune until the menu bar icon looks right."))
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onAppear { applyLiveUpdate() }
        .onChange(of: previewEnabled) { applyLiveUpdate() }
        .onChange(of: previewCount) { applyLiveUpdate() }
        .onChange(of: badgeRectX) { applyLiveUpdate() }
        .onChange(of: badgeRectY) { applyLiveUpdate() }
        .onChange(of: badgeRectWidth) { applyLiveUpdate() }
        .onChange(of: badgeRectHeight) { applyLiveUpdate() }
        .onChange(of: singleDigitFontSize) { applyLiveUpdate() }
        .onChange(of: multiDigitFontSize) { applyLiveUpdate() }
        .onChange(of: singleDigitXAdjust) { applyLiveUpdate() }
        .onChange(of: multiDigitXAdjust) { applyLiveUpdate() }
        .onChange(of: singleDigitYOffset) { applyLiveUpdate() }
        .onChange(of: multiDigitYOffset) { applyLiveUpdate() }
        .onChange(of: textRectWidthAdjust) { applyLiveUpdate() }
    }

    private func sliderRow(
        _ label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        format: String
    ) -> some View {
        HStack(spacing: 8) {
            Text(localizedDebugLabel(label))
            Slider(value: value, in: range)
            Text(String(format: format, value.wrappedValue))
                .font(.caption)
                .monospacedDigit()
                .frame(width: 58, alignment: .trailing)
        }
    }

    private func applyLiveUpdate() {
        AppDelegate.shared?.refreshMenuBarExtraForDebug()
    }
}

// MARK: - Browser Toolbar Glass Debug Window

final class BrowserToolbarGlassDebugWindowController: NSWindowController, NSWindowDelegate {
    static let shared = BrowserToolbarGlassDebugWindowController()

    private init() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 170),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = String(
            localized: "debug.browserToolbarGlass.title",
            defaultValue: "Browser Toolbar Glass"
        )
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("programa.browserToolbarGlassDebug")
        window.center()
        window.contentView = NSHostingView(rootView: BrowserToolbarGlassDebugView())
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct BrowserToolbarGlassDebugView: View {
    @AppStorage(ProgramaGlassSettings.browserToolbarEnabledKey)
    private var browserToolbarLiquidGlassEnabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(
                String(
                    localized: "debug.browserToolbarGlass.title",
                    defaultValue: "Browser Toolbar Glass"
                )
            )
            .font(.headline)

            Toggle(
                String(
                    localized: "debug.browserToolbarGlass.enable",
                    defaultValue: "Enable Native Glass Browser Toolbar"
                ),
                isOn: $browserToolbarLiquidGlassEnabled
            )
            .disabled(!WindowGlassEffect.isAvailable)

            Text(
                WindowGlassEffect.isAvailable
                    ? String(localized: "debug.glass.changesApplyLive", defaultValue: "Changes apply live.")
                    : String(localized: "debug.glass.requiresMacOS26", defaultValue: "Native Liquid Glass requires macOS 26.")
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Overlay Glass Debug Window

final class OverlayGlassDebugWindowController: NSWindowController, NSWindowDelegate {
    static let shared = OverlayGlassDebugWindowController()

    private init() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 170),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = String(
            localized: "debug.overlayGlass.title",
            defaultValue: "Overlay Glass"
        )
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("programa.overlayGlassDebug")
        window.center()
        window.contentView = NSHostingView(rootView: OverlayGlassDebugView())
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct OverlayGlassDebugView: View {
    @AppStorage(ProgramaGlassSettings.overlaysEnabledKey)
    private var overlayLiquidGlassEnabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(
                String(
                    localized: "debug.overlayGlass.title",
                    defaultValue: "Overlay Glass"
                )
            )
            .font(.headline)

            Toggle(
                String(
                    localized: "debug.overlayGlass.enable",
                    defaultValue: "Enable Native Glass Overlays"
                ),
                isOn: $overlayLiquidGlassEnabled
            )
            .disabled(!WindowGlassEffect.isAvailable)

            Text(
                WindowGlassEffect.isAvailable
                    ? String(localized: "debug.glass.changesApplyLive", defaultValue: "Changes apply live.")
                    : String(localized: "debug.glass.requiresMacOS26", defaultValue: "Native Liquid Glass requires macOS 26.")
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Tab Bar Glass Debug Window

final class TabBarGlassDebugWindowController: NSWindowController, NSWindowDelegate {
    static let shared = TabBarGlassDebugWindowController()

    private init() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 170),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = String(
            localized: "debug.tabBarGlass.title",
            defaultValue: "Tab Bar Glass"
        )
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("programa.tabBarGlassDebug")
        window.center()
        window.contentView = NSHostingView(rootView: TabBarGlassDebugView())
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct TabBarGlassDebugView: View {
    @AppStorage(ProgramaGlassSettings.tabBarEnabledKey)
    private var tabBarLiquidGlassEnabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(
                String(
                    localized: "debug.tabBarGlass.title",
                    defaultValue: "Tab Bar Glass"
                )
            )
            .font(.headline)

            Toggle(
                String(
                    localized: "debug.tabBarGlass.enable",
                    defaultValue: "Enable Native Glass Tab Pills"
                ),
                isOn: $tabBarLiquidGlassEnabled
            )
            .disabled(!WindowGlassEffect.isAvailable)

            Text(
                WindowGlassEffect.isAvailable
                    ? String(
                        localized: "debug.glass.changesApplyLive",
                        defaultValue: "Changes apply live."
                    )
                    : String(
                        localized: "debug.glass.requiresMacOS26",
                        defaultValue: "Native Liquid Glass requires macOS 26."
                    )
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Split Button Layout Debug Window

final class SplitButtonLayoutDebugWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SplitButtonLayoutDebugWindowController()

    private init() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = localizedDebugLabel("Split Button Layout")
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("programa.splitButtonLayoutDebug")
        window.center()
        window.contentView = NSHostingView(rootView: SplitButtonLayoutDebugView())
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct SplitButtonLayoutDebugView: View {
    @AppStorage("debugFadeColorStyle") private var backdropStyle = 0

    private let options: [(Int, String)] = [
        (0, "Pre-composited paneBackground"),
        (1, "Raw paneBackground (opaque)"),
        (2, "barBackground (tab chrome)"),
        (3, "windowBackgroundColor"),
        (4, "controlBackgroundColor"),
        (5, "Pre-composited barBackground"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(localizedDebugLabel("Button Backdrop Color"))
                .font(.headline)

            ForEach(options, id: \.0) { id, label in
                HStack {
                    Image(systemName: backdropStyle == id ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(backdropStyle == id ? .accentColor : .secondary)
                    Text(localizedDebugLabel(label))
                }
                .contentShape(Rectangle())
                .onTapGesture { backdropStyle = id }
            }

            Text(localizedDebugLabel("Changes apply live."))
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

// MARK: - Background Debug Window

final class BackgroundDebugWindowController: NSWindowController, NSWindowDelegate {
    static let shared = BackgroundDebugWindowController()

    private init() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 300),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = localizedDebugLabel("Background Debug")
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("programa.backgroundDebug")
        window.center()
        window.contentView = NSHostingView(rootView: BackgroundDebugView())
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct BackgroundDebugView: View {
    @AppStorage("bgGlassTintHex") private var bgGlassTintHex = "#000000"
    @AppStorage("bgGlassTintOpacity") private var bgGlassTintOpacity = 0.03
    @AppStorage("bgGlassMaterial") private var bgGlassMaterial = "hudWindow"
    @AppStorage("bgGlassEnabled") private var bgGlassEnabled = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(localizedDebugLabel("Window Background Glass"))
                    .font(.headline)

                GroupBox(localizedDebugLabel("Glass Effect")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(localizedDebugLabel("Enable Glass Effect"), isOn: $bgGlassEnabled)

                        Picker(localizedDebugLabel("Material"), selection: $bgGlassMaterial) {
                            Text(localizedDebugLabel("HUD Window")).tag("hudWindow")
                            Text(localizedDebugLabel("Under Window")).tag("underWindowBackground")
                            Text(localizedDebugLabel("Sidebar")).tag("sidebar")
                            Text(localizedDebugLabel("Menu")).tag("menu")
                            Text(localizedDebugLabel("Popover")).tag("popover")
                        }
                        .disabled(!bgGlassEnabled)
                    }
                    .padding(.top, 2)
                }

                GroupBox(localizedDebugLabel("Tint")) {
                    VStack(alignment: .leading, spacing: 8) {
                        ColorPicker(localizedDebugLabel("Tint Color"), selection: tintColorBinding, supportsOpacity: false)
                            .disabled(!bgGlassEnabled)

                        HStack(spacing: 8) {
                            Text(localizedDebugLabel("Opacity"))
                            Slider(value: $bgGlassTintOpacity, in: 0...0.8)
                                .disabled(!bgGlassEnabled)
                            Text(String(format: "%.0f%%", bgGlassTintOpacity * 100))
                                .font(.caption)
                                .frame(width: 44, alignment: .trailing)
                        }
                    }
                    .padding(.top, 2)
                }

                HStack(spacing: 12) {
                    Button(localizedDebugLabel("Reset")) {
                        bgGlassTintHex = "#000000"
                        bgGlassTintOpacity = 0.03
                        bgGlassMaterial = "hudWindow"
                        bgGlassEnabled = false
                        updateWindowGlassTint()
                    }

                    Button(localizedDebugLabel("Copy Config")) {
                        copyBgConfig()
                    }
                }

                Text(localizedDebugLabel("Tint changes apply live. Enable/disable requires reload."))
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onChange(of: bgGlassTintHex) { updateWindowGlassTint() }
        .onChange(of: bgGlassTintOpacity) { updateWindowGlassTint() }
    }

    private func updateWindowGlassTint() {
        let window: NSWindow? = {
            if let key = NSApp.keyWindow,
               let raw = key.identifier?.rawValue,
               raw == "cmux.main" || raw.hasPrefix("cmux.main.") {
                return key
            }
            return NSApp.windows.first(where: {
                guard let raw = $0.identifier?.rawValue else { return false }
                return raw == "cmux.main" || raw.hasPrefix("cmux.main.")
            })
        }()
        guard let window else { return }
        let tintColor = (NSColor(hex: bgGlassTintHex) ?? .black).withAlphaComponent(bgGlassTintOpacity)
        WindowGlassEffect.updateTint(to: window, color: tintColor)
    }

    private var tintColorBinding: Binding<Color> {
        Binding(
            get: {
                Color(nsColor: NSColor(hex: bgGlassTintHex) ?? .black)
            },
            set: { newColor in
                let nsColor = NSColor(newColor)
                bgGlassTintHex = nsColor.hexString()
            }
        )
    }

    private func copyBgConfig() {
        let payload = """
        bgGlassEnabled=\(bgGlassEnabled)
        bgGlassMaterial=\(bgGlassMaterial)
        bgGlassTintHex=\(bgGlassTintHex)
        bgGlassTintOpacity=\(String(format: "%.2f", bgGlassTintOpacity))
        """
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(payload, forType: .string)
    }
}

final class DensityDebugWindowController: NSWindowController, NSWindowDelegate {
    static let shared = DensityDebugWindowController()

    private init() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 640),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = localizedDebugLabel("Density Debug")
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("programa.densityDebug")
        window.center()
        window.contentView = NSHostingView(rootView: DensityDebugView())
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}

/// One slider per `ChromeDensity` token (see `WindowChrome.swift`). Each
/// slider is bound to the same `"chromeDensity.<name>"` UserDefaults key
/// `ChromeDensity.resolved` and Bonsplit's `TabBarMetrics.resolved` read, so
/// changes apply live with no rebuild. Bumping `ChromeDensityStore.shared.revision`
/// after every change re-renders the SwiftUI views that observe that store
/// (sidebar, content card, window panel); the Bonsplit tab strip re-renders on
/// its own via its `@AppStorage` subscriptions to the same keys.
private struct DensityDebugView: View {
    private struct Token: Identifiable {
        let id: String
        let label: String
        let defaultValue: Double
        let range: ClosedRange<Double>

        var key: String { "chromeDensity.\(id)" }
    }

    private static let sidebarRowTokens: [Token] = [
        Token(id: "sidebarRowVerticalPadding", label: "Row Vertical Padding", defaultValue: Double(ChromeDensity.sidebarRowVerticalPaddingDefault), range: 0...16),
        Token(id: "sidebarRowHorizontalPadding", label: "Row Horizontal Padding", defaultValue: Double(ChromeDensity.sidebarRowHorizontalPaddingDefault), range: 0...16),
        Token(id: "sidebarRowCornerRadius", label: "Row Corner Radius", defaultValue: Double(ChromeDensity.sidebarRowCornerRadiusDefault), range: 0...30),
        Token(id: "sidebarRowSpacing", label: "Row Spacing", defaultValue: Double(ChromeDensity.sidebarRowSpacingDefault), range: 0...16),
        Token(id: "sidebarTitleFontSize", label: "Row Title Font Size", defaultValue: Double(ChromeDensity.sidebarTitleFontSizeDefault), range: 9...16),
    ]

    private static let windowTokens: [Token] = [
        Token(id: "windowCornerRadius", label: "Window Corner Radius", defaultValue: Double(ChromeDensity.windowCornerRadiusDefault), range: 0...30),
        Token(id: "sidebarPanelInset", label: "Sidebar Panel Inset", defaultValue: Double(ChromeDensity.sidebarPanelInsetDefault), range: 0...16),
        Token(id: "contentCardInset", label: "Content Card Inset", defaultValue: Double(ChromeDensity.contentCardInsetDefault), range: 0...16),
        Token(id: "controlCornerRadius", label: "Control Corner Radius", defaultValue: Double(ChromeDensity.controlCornerRadiusDefault), range: 0...30),
    ]

    private static let tabBarTokens: [Token] = [
        Token(id: "tabBarHeight", label: "Tab Bar Height", defaultValue: Double(ChromeDensity.tabBarHeightDefault), range: 20...36),
        Token(id: "tabHorizontalPadding", label: "Tab Horizontal Padding", defaultValue: Double(ChromeDensity.tabHorizontalPaddingDefault), range: 0...16),
        Token(id: "tabIconSize", label: "Tab Icon Size", defaultValue: Double(ChromeDensity.tabIconSizeDefault), range: 9...16),
        Token(id: "tabTitleFontSize", label: "Tab Title Font Size", defaultValue: Double(ChromeDensity.tabTitleFontSizeDefault), range: 9...16),
        Token(id: "tabCloseButtonSize", label: "Tab Close Button Size", defaultValue: Double(ChromeDensity.tabCloseButtonSizeDefault), range: 0...30),
        Token(id: "tabCloseIconSize", label: "Tab Close Icon Size", defaultValue: Double(ChromeDensity.tabCloseIconSizeDefault), range: 0...16),
        Token(id: "tabContentSpacing", label: "Tab Content Spacing", defaultValue: Double(ChromeDensity.tabContentSpacingDefault), range: 0...16),
    ]

    private static let allTokens = sidebarRowTokens + windowTokens + tabBarTokens

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(localizedDebugLabel("Chrome Density"))
                    .font(.headline)

                GroupBox(localizedDebugLabel("Sidebar Rows")) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Self.sidebarRowTokens) { token in
                            DensitySliderRow(token: token)
                        }
                    }
                    .padding(.top, 2)
                }

                GroupBox(localizedDebugLabel("Window Card / Insets / Radii")) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Self.windowTokens) { token in
                            DensitySliderRow(token: token)
                        }
                    }
                    .padding(.top, 2)
                }

                GroupBox(localizedDebugLabel("Tab Strip")) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Self.tabBarTokens) { token in
                            DensitySliderRow(token: token)
                        }
                    }
                    .padding(.top, 2)
                }

                Button(localizedDebugLabel("Reset to Defaults")) {
                    let defaults = UserDefaults.standard
                    for token in Self.allTokens {
                        defaults.removeObject(forKey: token.key)
                    }
                    ChromeDensityStore.shared.revision &+= 1
                }

                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private struct DensitySliderRow: View {
        let token: Token

        @AppStorage private var value: Double

        init(token: Token) {
            self.token = token
            _value = AppStorage(wrappedValue: token.defaultValue, token.key)
        }

        var body: some View {
            HStack(spacing: 8) {
                Text(localizedDebugLabel(token.label))
                    .frame(width: 150, alignment: .leading)
                Slider(value: $value, in: token.range)
                    .onChange(of: value) {
                        ChromeDensityStore.shared.revision &+= 1
                    }
                Text(String(format: "%.1f", value))
                    .font(.caption)
                    .monospacedDigit()
                    .frame(width: 36, alignment: .trailing)
            }
        }
    }
}

#endif
