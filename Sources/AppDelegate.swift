import AppKit
import SwiftUI
import Bonsplit
import CoreGraphics
import CoreServices
import UserNotifications
import WebKit
import Combine
import ObjectiveC.runtime
import Darwin
import Security



private enum ProgramaThemeNotifications {
    static let reloadConfig = Notification.Name("com.darkroom.programa.themes.reload-config")
}

/// Association key for retaining `MainWindowToolbarDelegate` on its window --
/// `NSToolbar.delegate` is weak, so without this the delegate is deallocated
/// immediately and the toolbar silently loses its item provider.
private var mainWindowToolbarDelegateAssociationKey: UInt8 = 0

/// Supplies a single invisible spacer item so the main window's otherwise-empty
/// unified toolbar reports a non-zero height, growing the titlebar so AppKit
/// re-centers the traffic lights on `WindowGlassEffect.sidebarHeaderCenterFromWindowTop`.
/// See the call site in `configureMainWindow` for why this is a toolbar item and
/// not an empty toolbar or a `.top` titlebar accessory (both measured as no-ops).
private final class MainWindowToolbarDelegate: NSObject, NSToolbarDelegate {
    static let spacerItemIdentifier = NSToolbarItem.Identifier("programa.titlebarSpacer")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.spacerItemIdentifier]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.spacerItemIdentifier]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard itemIdentifier == Self.spacerItemIdentifier else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.widthAnchor.constraint(equalToConstant: 1).isActive = true
        spacer.heightAnchor.constraint(
            equalToConstant: WindowGlassEffect.mainWindowTitlebarSpacerHeight
        ).isActive = true
        item.view = spacer
        item.isEnabled = false
        item.isBordered = false
        item.visibilityPriority = .user
        return item
    }
}

func isCommandPaletteFocusStealingTerminalOrBrowserResponder(_ responder: NSResponder) -> Bool {
    if responder is GhosttyNSView || responder is WKWebView {
        return true
    }

    if let textView = responder as? NSTextView, !textView.isFieldEditor {
        if let delegateView = textView.delegate as? NSView,
           isCommandPaletteFocusStealingTerminalOrBrowserView(delegateView) {
            return true
        }
        return isCommandPaletteFocusStealingTerminalOrBrowserView(textView)
    }

    if let view = responder as? NSView {
        return isCommandPaletteFocusStealingTerminalOrBrowserView(view)
    }

    return false
}

func isCommandPaletteFocusStealingTerminalOrBrowserView(_ view: NSView) -> Bool {
    if view is GhosttyNSView || view is GhosttySurfaceScrollView || view is WKWebView {
        return true
    }
    var current: NSView? = view.superview
    while let candidate = current {
        if candidate is GhosttyNSView || candidate is GhosttySurfaceScrollView || candidate is WKWebView {
            return true
        }
        current = candidate.superview
    }
    return false
}







private extension NSScreen {
    var programaDisplayID: UInt32? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let value = deviceDescription[key] as? NSNumber else { return nil }
        return value.uint32Value
    }

    /// Stable per-monitor identity that survives displayID reassignment across
    /// unplug/replug and sleep/wake (CGDirectDisplayID is not guaranteed stable).
    var programaStableDisplayID: String? {
        guard let displayID = programaDisplayID,
              let cfuuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else {
            return nil
        }
        return CFUUIDCreateString(nil, cfuuid) as String?
    }
}

func browserOmnibarSelectionDeltaForCommandNavigation(
    hasFocusedAddressBar: Bool,
    flags: NSEvent.ModifierFlags,
    chars: String
) -> Int? {
    guard hasFocusedAddressBar else { return nil }
    let normalizedFlags = browserOmnibarNormalizedModifierFlags(flags)
    let isCommandOrControlOnly = normalizedFlags == [.command] || normalizedFlags == [.control]
    guard isCommandOrControlOnly else { return nil }
    if chars == "n" { return 1 }
    if chars == "p" { return -1 }
    return nil
}

func browserOmnibarSelectionDeltaForArrowNavigation(
    hasFocusedAddressBar: Bool,
    flags: NSEvent.ModifierFlags,
    keyCode: UInt16
) -> Int? {
    guard hasFocusedAddressBar else { return nil }
    let normalizedFlags = browserOmnibarNormalizedModifierFlags(flags)
    guard normalizedFlags == [] else { return nil }
    switch keyCode {
    case 125: return 1
    case 126: return -1
    default: return nil
    }
}

func browserOmnibarNormalizedModifierFlags(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
    flags
        .intersection(.deviceIndependentFlagsMask)
        .subtracting([.numericPad, .function, .capsLock])
}

func browserOmnibarShouldSubmitOnReturn(flags: NSEvent.ModifierFlags) -> Bool {
    let normalizedFlags = browserOmnibarNormalizedModifierFlags(flags)
    return normalizedFlags == [] || normalizedFlags == [.shift]
}

func browserResponderHasMarkedText(_ responder: NSResponder?) -> Bool {
    guard let responder else { return false }

    // During IME composition, Return/Enter belongs to the text system so the
    // candidate list can commit or confirm the marked text.
    if let textInputClient = responder as? NSTextInputClient {
        if textInputClient.hasMarkedText() { return true }
    }

    if let textField = responder as? NSTextField,
       let editor = textField.currentEditor() as? NSTextView {
        if editor.hasMarkedText() { return true }
    }

    // WKWebView clears marked text before performKeyEquivalent fires, so the
    // synchronous hasMarkedText() check above can return false even though an IME
    // composition just ended on the same Enter keystroke. Check the JS bridge's
    // composition timestamp to detect this race condition (#2626).
    if let webView = responder.programaEnclosingProgramaWebView {
        if webView.webViewIsComposing { return true }
        let age = ProcessInfo.processInfo.systemUptime - webView.recentCompositionEndTimestamp
        if age >= 0 && age < 0.15 { return true }
    }

    return false
}

private extension NSResponder {
    /// Walk the responder chain to find the enclosing ProgramaWebView.
    var programaEnclosingProgramaWebView: ProgramaWebView? {
        var current: NSResponder? = self
        while let responder = current {
            if let webView = responder as? ProgramaWebView { return webView }
            current = responder.nextResponder
        }
        return nil
    }
}

func shouldDispatchBrowserReturnViaFirstResponderKeyDown(
    keyCode: UInt16,
    firstResponderIsBrowser: Bool,
    firstResponderHasMarkedText: Bool = false,
    flags: NSEvent.ModifierFlags
) -> Bool {
    guard firstResponderIsBrowser else { return false }
    guard !firstResponderHasMarkedText else { return false }
    guard keyCode == 36 || keyCode == 76 else { return false }
    // Keep browser Return forwarding narrow: only plain/Shift Return should be
    // treated as submit-intent. Command-modified Return is reserved for app shortcuts
    // like Toggle Pane Zoom (Cmd+Shift+Enter).
    return browserOmnibarShouldSubmitOnReturn(flags: flags)
}

func shouldToggleMainWindowFullScreenForCommandControlFShortcut(
    flags: NSEvent.ModifierFlags,
    chars: String,
    keyCode: UInt16,
    layoutCharacterProvider: (UInt16, NSEvent.ModifierFlags) -> String? = KeyboardLayout.character(forKeyCode:modifierFlags:)
) -> Bool {
    let normalizedFlags = flags
        .intersection(.deviceIndependentFlagsMask)
        .subtracting([.numericPad, .function, .capsLock])
    guard normalizedFlags == [.command, .control] else { return false }
    let normalizedChars = chars.lowercased()
    if normalizedChars == "f" {
        return true
    }
    let charsAreControlSequence = !normalizedChars.isEmpty
        && normalizedChars.unicodeScalars.allSatisfy { CharacterSet.controlCharacters.contains($0) }
    if !normalizedChars.isEmpty && !charsAreControlSequence {
        return false
    }

    // Fallback to layout translation only when characters are unavailable (for
    // synthetic/key-equivalent paths that can report an empty string).
    if let translatedCharacter = layoutCharacterProvider(keyCode, flags), !translatedCharacter.isEmpty {
        return translatedCharacter == "f"
    }

    // Keep ANSI fallback as a final safety net when layout translation is unavailable.
    return keyCode == 3
}

func commandPaletteSelectionDeltaForKeyboardNavigation(
    flags: NSEvent.ModifierFlags,
    chars: String,
    keyCode: UInt16
) -> Int? {
    let normalizedFlags = flags
        .intersection(.deviceIndependentFlagsMask)
        .subtracting([.numericPad, .function])
    let normalizedChars = chars.lowercased()

    if normalizedFlags == [] {
        switch keyCode {
        case 125: return 1    // Down arrow
        case 126: return -1   // Up arrow
        default: break
        }
    }

    if normalizedFlags == [.control] {
        // Control modifiers can surface as either printable chars or ASCII control chars.
        // Keep Emacs-style next/previous navigation, but leave other control bindings
        // (for example Ctrl+K text editing in the palette search field) to AppKit.
        if keyCode == 45 || normalizedChars == "n" || normalizedChars == "\u{0e}" { return 1 }    // Ctrl+N
        if keyCode == 35 || normalizedChars == "p" || normalizedChars == "\u{10}" { return -1 }   // Ctrl+P
    }

    return nil
}

func shouldRouteCommandPaletteSelectionNavigation(
    delta: Int?,
    isInteractive: Bool,
    usesInlineTextHandling: Bool
) -> Bool {
    guard delta != nil, isInteractive else { return false }
    return !usesInlineTextHandling
}

func shouldConsumeShortcutWhileCommandPaletteVisible(
    isCommandPaletteVisible: Bool,
    normalizedFlags: NSEvent.ModifierFlags,
    chars: String,
    keyCode: UInt16
) -> Bool {
    guard isCommandPaletteVisible else { return false }

    // Escape dismisses the palette, and must not leak through to the
    // underlying terminal or browser content.
    if normalizedFlags.isEmpty, keyCode == 53 {
        return true
    }

    guard normalizedFlags.contains(.command) else { return false }

    let normalizedChars = chars.lowercased()

    if normalizedFlags == [.command] {
        if normalizedChars == "a"
            || normalizedChars == "c"
            || normalizedChars == "v"
            || normalizedChars == "x"
            || normalizedChars == "z"
            || normalizedChars == "y" {
            return false
        }

        switch keyCode {
        case 51, 117, 123, 124:
            return false
        default:
            break
        }
    }

    if normalizedFlags == [.command, .shift], normalizedChars == "z" {
        return false
    }

    return true
}

func shouldSubmitCommandPaletteWithReturn(
    keyCode: UInt16,
    flags: NSEvent.ModifierFlags,
    mode: String
) -> Bool {
    guard keyCode == 36 || keyCode == 76 else { return false }
    let normalizedFlags = flags
        .intersection(.deviceIndependentFlagsMask)
        .subtracting([.numericPad, .function, .capsLock])
    if normalizedFlags.isEmpty {
        return true
    }
    if normalizedFlags == [.shift] {
        return mode != "workspace_description_input"
    }
    return false
}

func commandPaletteFieldEditorHasMarkedText(in window: NSWindow) -> Bool {
    if let editor = window.firstResponder as? NSTextView {
        return editor.hasMarkedText()
    }
    if let textField = window.firstResponder as? NSTextField,
       let editor = textField.currentEditor() as? NSTextView {
        return editor.hasMarkedText()
    }
    return false
}

func shouldHandleCommandPaletteShortcutEvent(
    _ event: NSEvent,
    paletteWindow: NSWindow?
) -> Bool {
    guard let paletteWindow else { return false }
    if let eventWindow = event.window {
        return eventWindow === paletteWindow
    }
    let eventWindowNumber = event.windowNumber
    if eventWindowNumber > 0 {
        return eventWindowNumber == paletteWindow.windowNumber
    }
    if let keyWindow = NSApp.keyWindow {
        return keyWindow === paletteWindow
    }
    return false
}

enum BrowserZoomShortcutAction: Equatable {
    case zoomIn
    case zoomOut
    case reset
}

func browserZoomShortcutAction(
    flags: NSEvent.ModifierFlags,
    chars: String,
    keyCode: UInt16,
    literalChars: String? = nil
) -> BrowserZoomShortcutAction? {
    let normalizedFlags = flags
        .intersection(.deviceIndependentFlagsMask)
        .subtracting([.numericPad, .function])
    let hasCommand = normalizedFlags.contains(.command)
    let hasOnlyCommandAndOptionalShift = hasCommand && normalizedFlags.isDisjoint(with: [.control, .option])

    guard hasOnlyCommandAndOptionalShift else { return nil }
    let keys = browserZoomShortcutKeyCandidates(
        chars: chars,
        literalChars: literalChars,
        keyCode: keyCode
    )

    if keys.contains("=") || keys.contains("+") || keyCode == 24 || keyCode == 69 { // kVK_ANSI_Equal / kVK_ANSI_KeypadPlus
        return .zoomIn
    }

    if keys.contains("-") || keys.contains("_") || keyCode == 27 || keyCode == 78 { // kVK_ANSI_Minus / kVK_ANSI_KeypadMinus
        return .zoomOut
    }

    if keys.contains("0") || keyCode == 29 || keyCode == 82 { // kVK_ANSI_0 / kVK_ANSI_Keypad0
        return .reset
    }

    return nil
}

func browserZoomShortcutKeyCandidates(
    chars: String,
    literalChars: String?,
    keyCode: UInt16
) -> Set<String> {
    var keys: Set<String> = [chars.lowercased()]

    if let literalChars, !literalChars.isEmpty {
        keys.insert(literalChars.lowercased())
    }

    if let layoutChar = KeyboardLayout.character(forKeyCode: keyCode), !layoutChar.isEmpty {
        keys.insert(layoutChar)
    }

    return keys
}

func shouldSuppressSplitShortcutForTransientTerminalFocusInputs(
    firstResponderIsWindow: Bool,
    hostedSize: CGSize,
    hostedHiddenInHierarchy: Bool,
    hostedAttachedToWindow: Bool
) -> Bool {
    guard firstResponderIsWindow else { return false }
    let tinyGeometry = hostedSize.width <= 1 || hostedSize.height <= 1
    return tinyGeometry || hostedHiddenInHierarchy || !hostedAttachedToWindow
}

func shouldRouteTerminalFontZoomShortcutToGhostty(
    firstResponderIsGhostty: Bool,
    flags: NSEvent.ModifierFlags,
    chars: String,
    keyCode: UInt16,
    literalChars: String? = nil
) -> Bool {
    guard firstResponderIsGhostty else { return false }
    return browserZoomShortcutAction(
        flags: flags,
        chars: chars,
        keyCode: keyCode,
        literalChars: literalChars
    ) != nil
}

@discardableResult
func startOrFocusTerminalSearch(
    _ terminalSurface: TerminalSurface,
    searchFocusNotifier: @escaping (TerminalSurface) -> Void = {
        NotificationCenter.default.post(name: .ghosttySearchFocus, object: $0)
    }
) -> Bool {
    if terminalSurface.searchState != nil {
        searchFocusNotifier(terminalSurface)
        return true
    }

    if terminalSurface.performBindingAction("start_search") {
        DispatchQueue.main.async { [weak terminalSurface] in
            guard let terminalSurface, terminalSurface.searchState == nil else { return }
            terminalSurface.searchState = TerminalSurface.SearchState()
            searchFocusNotifier(terminalSurface)
        }
        return true
    }

    terminalSurface.searchState = TerminalSurface.SearchState()
    searchFocusNotifier(terminalSurface)
    return true
}

/// Let AppKit own native Cmd+` window cycling so key-window changes do not
/// re-enter our direct-to-menu shortcut path.
func shouldRouteCommandEquivalentDirectlyToMainMenu(_ event: NSEvent) -> Bool {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    guard flags.contains(.command) else { return false }

    let normalizedFlags = flags.subtracting([.numericPad, .function, .capsLock])
    if event.keyCode == 50,
       normalizedFlags == [.command] || normalizedFlags == [.command, .shift] {
        return false
    }

    return true
}

private enum BrowserFindCommandEquivalent {
    case find
    case findNext
    case findPrevious
    case hideFind
    case useSelection

    var keepsProgramaBrowserFindBarOwnershipWhenVisible: Bool {
        switch self {
        case .find, .findNext, .findPrevious, .hideFind:
            return true
        case .useSelection:
            return false
        }
    }
}

private func programaIsLikelyWebInspectorResponder(_ responder: NSResponder?) -> Bool {
    guard let responder else { return false }
    let responderType = String(describing: type(of: responder))
    if responderType.contains("WKInspector") {
        return true
    }
    guard let view = responder as? NSView else { return false }
    var node: NSView? = view
    var hops = 0
    while let current = node, hops < 64 {
        if String(describing: type(of: current)).contains("WKInspector") {
            return true
        }
        node = current.superview
        hops += 1
    }
    return false
}

private func browserFindCommandEquivalent(for event: NSEvent) -> BrowserFindCommandEquivalent? {
    let flags = event.modifierFlags
        .intersection(.deviceIndependentFlagsMask)
        .subtracting([.numericPad, .function, .capsLock])

    let normalizedChars = KeyboardLayout.normalizedCharacters(for: event).lowercased()
    let hasSingleASCIIShortcutChar =
        normalizedChars.count == 1 && normalizedChars.allSatisfy(\.isASCII)
    let producedAnyASCIIShortcutChar = normalizedChars.contains(where: \.isASCII)
    func matches(_ chars: String, keyCode: UInt16) -> Bool {
        if hasSingleASCIIShortcutChar {
            return normalizedChars == chars
        }
        if !producedAnyASCIIShortcutChar {
            return event.keyCode == keyCode
        }
        return false
    }

    switch flags {
    case [.command]:
        if matches("e", keyCode: 14) { // kVK_ANSI_E
            return .useSelection
        }
        if matches("f", keyCode: 3) { // kVK_ANSI_F
            return .find
        }
        if matches("g", keyCode: 5) { // kVK_ANSI_G
            return .findNext
        }
        return nil
    case [.command, .shift]:
        if matches("f", keyCode: 3) { // kVK_ANSI_F
            return .hideFind
        }
        if matches("g", keyCode: 5) { // kVK_ANSI_G
            return .findPrevious
        }
        return nil
    default:
        return nil
    }
}

/// For browser content, let the page try the Find command family before cmux's menu fallback.
/// This preserves native web-app shortcuts like VS Code's Cmd+F while still allowing cmux's
/// browser find overlay to keep owning its visible Find UI shortcuts.
func shouldRouteBrowserFindCommandEquivalentThroughWebContentFirst(
    _ event: NSEvent,
    responder: NSResponder? = nil,
    owningWebView: ProgramaWebView? = nil
) -> Bool {
    guard let shortcut = browserFindCommandEquivalent(for: event) else {
        return false
    }

    if programaIsLikelyWebInspectorResponder(responder) {
        return false
    }

    if shortcut.keepsProgramaBrowserFindBarOwnershipWhenVisible,
       let owningWebView {
        let browserFindBarIsVisible = MainActor.assumeIsolated {
            AppDelegate.shared?.browserFindBarIsVisible(for: owningWebView) == true
        }
        if browserFindBarIsVisible {
            return false
        }
    }

    return true
}

func cmuxOwningGhosttyView(for responder: NSResponder?) -> GhosttyNSView? {
    guard let responder else { return nil }
    if let ghosttyView = responder as? GhosttyNSView {
        return ghosttyView
    }

    if let view = responder as? NSView,
       let ghosttyView = cmuxOwningGhosttyView(for: view) {
        return ghosttyView
    }

    if let textView = responder as? NSTextView {
        if textView.isFieldEditor,
           let ownerView = programaFieldEditorOwnerView(textView),
           let ghosttyView = cmuxOwningGhosttyView(for: ownerView) {
            return ghosttyView
        }

        if !textView.isFieldEditor,
           let delegateView = textView.delegate as? NSView,
           let ghosttyView = cmuxOwningGhosttyView(for: delegateView) {
            return ghosttyView
        }
    }

    var current = responder.nextResponder
    while let next = current {
        if let ghosttyView = next as? GhosttyNSView {
            return ghosttyView
        }
        if let view = next as? NSView,
           let ghosttyView = cmuxOwningGhosttyView(for: view) {
            return ghosttyView
        }
        current = next.nextResponder
    }

    return nil
}

private func programaFieldEditorOwnerView(_ editor: NSTextView) -> NSView? {
    guard editor.isFieldEditor else { return nil }

    var current = editor.nextResponder
    while let next = current {
        if let view = next as? NSView {
            return view
        }
        current = next.nextResponder
    }

    return editor.superview
}

private func cmuxOwningGhosttyView(for view: NSView) -> GhosttyNSView? {
    if let ghosttyView = view as? GhosttyNSView {
        return ghosttyView
    }

    var current: NSView? = view.superview
    while let candidate = current {
        if let ghosttyView = candidate as? GhosttyNSView {
            return ghosttyView
        }
        current = candidate.superview
    }

    return nil
}

#if DEBUG
func browserZoomShortcutTraceCandidate(
    flags: NSEvent.ModifierFlags,
    chars: String,
    keyCode: UInt16,
    literalChars: String? = nil
) -> Bool {
    let normalizedFlags = flags
        .intersection(.deviceIndependentFlagsMask)
        .subtracting([.numericPad, .function])
    guard normalizedFlags.contains(.command) else { return false }

    let keys = browserZoomShortcutKeyCandidates(
        chars: chars,
        literalChars: literalChars,
        keyCode: keyCode
    )
    if keys.contains("=") || keys.contains("+") || keys.contains("-") || keys.contains("_") || keys.contains("0") {
        return true
    }
    switch keyCode {
    case 24, 27, 29, 69, 78, 82: // ANSI and keypad zoom keys
        return true
    default:
        return false
    }
}

func browserZoomShortcutTraceFlagsString(_ flags: NSEvent.ModifierFlags) -> String {
    let normalizedFlags = flags
        .intersection(.deviceIndependentFlagsMask)
        .subtracting([.numericPad, .function])
    var parts: [String] = []
    if normalizedFlags.contains(.command) { parts.append("Cmd") }
    if normalizedFlags.contains(.shift) { parts.append("Shift") }
    if normalizedFlags.contains(.option) { parts.append("Opt") }
    if normalizedFlags.contains(.control) { parts.append("Ctrl") }
    return parts.isEmpty ? "none" : parts.joined(separator: "+")
}

func browserZoomShortcutTraceActionString(_ action: BrowserZoomShortcutAction?) -> String {
    guard let action else { return "none" }
    switch action {
    case .zoomIn: return "zoomIn"
    case .zoomOut: return "zoomOut"
    case .reset: return "reset"
    }
}
#endif

func shouldSuppressWindowMoveForFolderDrag(hitView: NSView?) -> Bool {
    var candidate = hitView
    while let view = candidate {
        if view is DraggableFolderNSView {
            return true
        }
        candidate = view.superview
    }
    return false
}

func shouldSuppressWindowMoveForFolderDrag(window: NSWindow, event: NSEvent) -> Bool {
    guard event.type == .leftMouseDown,
          window.isMovable,
          let contentView = window.contentView else {
        return false
    }

    let contentPoint = contentView.convert(event.locationInWindow, from: nil)
    let hitView = contentView.hitTest(contentPoint)
    return shouldSuppressWindowMoveForFolderDrag(hitView: hitView)
}

struct ProgramaSingleInstanceProcessKey: Equatable, Sendable {
    let startSeconds: Int64
    let startMicroseconds: Int64
    let processIdentifier: pid_t
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, @preconcurrency UNUserNotificationCenterDelegate, NSMenuItemValidation {
    nonisolated(unsafe) static var shared: AppDelegate?

    var core: ProgramaCoreProviding = InProcessCore.shared

    private static let cachedIsRunningUnderXCTest = detectRunningUnderXCTest(ProcessInfo.processInfo.environment)

    private var isRunningUnderXCTestCached: Bool {
        Self.cachedIsRunningUnderXCTest
    }

    private static func detectRunningUnderXCTest(_ env: [String: String]) -> Bool {
        if SessionMachineryGate.isUnitTesting { return true }
        if env.keys.contains(where: { $0.hasPrefix("PROGRAMA_UI_TEST_") }) { return true }
        return false
    }

    /// True only when the XCTest bundle is injected directly into *this* process
    /// (unit tests hosted inside the app, e.g. the `programa-unit` scheme). This is
    /// distinct from a genuine XCUITest run: there the `.xctest` bundle loads into a
    /// separate XCTRunner process, and this app-under-test process is launched fresh
    /// with none of `XCTestBundlePath`/`XCInjectBundle`/`XCInjectBundleInto` set.
    /// `PROGRAMA_UI_TEST_*` keys (set explicitly by UI tests via `launchEnvironment`)
    /// are excluded from this check on purpose so it can't misclassify a real UI test
    /// run as an embedded unit-test host.
    private func isEmbeddedUnitTestHost(_ env: [String: String]) -> Bool {
        env["XCTestBundlePath"] != nil || env["XCInjectBundle"] != nil || env["XCInjectBundleInto"] != nil
    }

    private func isRunningUnderXCTest(_ env: [String: String]) -> Bool {
        // On some macOS/Xcode setups, the app-under-test process doesn't get
        // `XCTestConfigurationFilePath`. Use a broader set of signals so UI tests
        // can reliably skip heavyweight startup work and bring up a window.
        Self.detectRunningUnderXCTest(env)
    }

    final class MainWindowContext {
        let windowId: UUID
        let tabManager: TabManager
        let sidebarState: SidebarState
        let sidebarSelectionState: SidebarSelectionState
        weak var window: NSWindow?
        // SwiftUI owns the primary window; keep it alive while it is ordered out.
        var hiddenWindow: NSWindow?
        var hiddenAt: Date?
        weak var observedWindow: NSWindow?
        var willCloseObserver: NSObjectProtocol?
        var willCloseObserverGeneration: UUID?

        init(
            windowId: UUID,
            tabManager: TabManager,
            sidebarState: SidebarState,
            sidebarSelectionState: SidebarSelectionState,
            window: NSWindow?
        ) {
            self.windowId = windowId
            self.tabManager = tabManager
            self.sidebarState = sidebarState
            self.sidebarSelectionState = sidebarSelectionState
            self.window = window
        }
    }

    private final class MainWindowController: NSWindowController, NSWindowDelegate {
        var onClose: (() -> Void)?

        func windowWillClose(_ notification: Notification) {
            onClose?()
        }
    }

    struct ScriptableMainWindowState {
        let windowId: UUID
        let tabManager: TabManager
        let window: NSWindow?
    }

    struct SessionDisplayGeometry {
        let displayID: UInt32?
        let stableID: String?
        let frame: CGRect
        let visibleFrame: CGRect
    }

    struct PersistedWindowGeometry: Codable, Sendable {
        let version: Int
        let frame: SessionRectSnapshot
        let display: SessionDisplaySnapshot?
    }

    nonisolated static let persistedWindowGeometrySchemaVersion = 2
    nonisolated static let persistedWindowGeometryDefaultsKey = "programa.session.lastWindowGeometry.v2"
    private nonisolated static let legacyPersistedWindowGeometryDefaultsKeys = [
        "programa.session.lastWindowGeometry.v1"
    ]

    weak var tabManager: TabManager?
    weak var notificationStore: TerminalNotificationStore?
    weak var sidebarState: SidebarState?
    weak var fullscreenControlsViewModel: TitlebarControlsViewModel?
    weak var sidebarSelectionState: SidebarSelectionState?
    var shortcutLayoutCharacterProvider: (UInt16, NSEvent.ModifierFlags) -> String? = KeyboardLayout.character(forKeyCode:modifierFlags:)
    private var workspaceObserver: NSObjectProtocol?
    private var lifecycleSnapshotObservers: [NSObjectProtocol] = []
    private var windowKeyObserver: NSObjectProtocol?
    private var shortcutMonitor: Any?
    private var shortcutDefaultsObserver: NSObjectProtocol?
    private var menuBarVisibilityObserver: NSObjectProtocol?
    private var splitButtonTooltipRefreshScheduled = false
    private struct PendingConfiguredShortcutChord {
        let firstStroke: ShortcutStroke
        let windowNumber: Int?
    }
    private var pendingConfiguredShortcutChord: PendingConfiguredShortcutChord?
    private var activeConfiguredShortcutChordPrefixForCurrentEvent: ShortcutStroke?
    private var configuredShortcutChordActions: [KeyboardShortcutSettings.Action] = []
    private var ghosttyConfigObserver: NSObjectProtocol?
    var ghosttyGotoSplitLeftShortcut: StoredShortcut?
    var ghosttyGotoSplitRightShortcut: StoredShortcut?
    var ghosttyGotoSplitUpShortcut: StoredShortcut?
    var ghosttyGotoSplitDownShortcut: StoredShortcut?
    private var browserAddressBarFocusedPanelId: UUID?
    private var browserOmnibarRepeatStartWorkItem: DispatchWorkItem?
    private var browserOmnibarRepeatTickWorkItem: DispatchWorkItem?
    private var browserOmnibarRepeatKeyCode: UInt16?
    private var browserOmnibarRepeatDelta: Int = 0
    private var browserAddressBarFocusObserver: NSObjectProtocol?
    private var browserAddressBarBlurObserver: NSObjectProtocol?
    private let updateController = UpdateController()
    private lazy var titlebarAccessoryController = UpdateTitlebarAccessoryController(viewModel: updateViewModel)
    private var menuBarExtraController: MenuBarExtraController?
    private static let serviceErrorNoPath = NSString(string: String(localized: "error.clipboardFolderPath", defaultValue: "Could not load any folder path from the clipboard."))
    private static let didInstallWindowKeyEquivalentSwizzle: Void = {
        let targetClass: AnyClass = NSWindow.self
        let originalSelector = #selector(NSWindow.performKeyEquivalent(with:))
        let swizzledSelector = #selector(NSWindow.programa_performKeyEquivalent(with:))
        guard let originalMethod = class_getInstanceMethod(targetClass, originalSelector),
              let swizzledMethod = class_getInstanceMethod(targetClass, swizzledSelector) else {
            return
        }
        method_exchangeImplementations(originalMethod, swizzledMethod)
    }()
    private static let didInstallWindowFirstResponderSwizzle: Void = {
        let targetClass: AnyClass = NSWindow.self
        let originalSelector = #selector(NSWindow.makeFirstResponder(_:))
        let swizzledSelector = #selector(NSWindow.programa_makeFirstResponder(_:))
        guard let originalMethod = class_getInstanceMethod(targetClass, originalSelector),
              let swizzledMethod = class_getInstanceMethod(targetClass, swizzledSelector) else {
            return
        }
        method_exchangeImplementations(originalMethod, swizzledMethod)
    }()
    private static let didInstallWindowSendEventSwizzle: Void = {
        let targetClass: AnyClass = NSWindow.self
        let originalSelector = #selector(NSWindow.sendEvent(_:))
        let swizzledSelector = #selector(NSWindow.programa_sendEvent(_:))
        guard let originalMethod = class_getInstanceMethod(targetClass, originalSelector),
              let swizzledMethod = class_getInstanceMethod(targetClass, swizzledSelector) else {
            return
        }
        method_exchangeImplementations(originalMethod, swizzledMethod)
    }()
    private static let didInstallWindowCloseSwizzle: Void = {
        guard let original = class_getInstanceMethod(NSWindow.self, #selector(NSWindow.close)),
              let replacement = class_getInstanceMethod(NSWindow.self, #selector(NSWindow.programa_close)) else { return }
        method_exchangeImplementations(original, replacement)
    }()
    private static let didInstallApplicationSendEventSwizzle: Void = {
        let targetClass: AnyClass = NSApplication.self
        let originalSelector = #selector(NSApplication.sendEvent(_:))
        let swizzledSelector = #selector(NSApplication.programa_applicationSendEvent(_:))
        guard let originalMethod = class_getInstanceMethod(targetClass, originalSelector),
              let swizzledMethod = class_getInstanceMethod(targetClass, swizzledSelector) else {
            return
        }
        method_exchangeImplementations(originalMethod, swizzledMethod)
    }()

#if DEBUG
    var didSetupJumpUnreadUITest = false
    var jumpUnreadFocusExpectation: (tabId: UUID, surfaceId: UUID)?
    var jumpUnreadFocusObserver: NSObjectProtocol?
    var didSetupTerminalCmdClickUITest = false
    var didSetupGotoSplitUITest = false
    var didSetupBonsplitTabDragUITest = false
    var terminalCmdClickUITestPoller: DispatchSourceTimer?
    var bonsplitTabDragUITestRecorder: DispatchSourceTimer?
    var gotoSplitUITestRecorder: DispatchSourceTimer?
    var gotoSplitUITestObservers: [NSObjectProtocol] = []
    var didSetupMultiWindowNotificationsUITest = false
    var didSetupDisplayResolutionUITestDiagnostics = false
    var displayResolutionUITestObservers: [NSObjectProtocol] = []
    private struct UITestRenderDiagnosticsSnapshot {
        let panelId: UUID
        let drawCount: Int
        let presentCount: Int
        let lastPresentTime: Double
        let windowVisible: Bool
        let appIsActive: Bool
        let desiredFocus: Bool
        let isFirstResponder: Bool
    }
    var debugCreateMainWindowSourceIsNativeFullScreenOverride: Bool?
    // Keep debug-only windows alive when tests intentionally inject key mismatches.
    private var debugDetachedContextWindows: [NSWindow] = []

    private func childExitKeyboardProbePath() -> String? {
        let env = ProcessInfo.processInfo.environment
        guard env["PROGRAMA_UI_TEST_CHILD_EXIT_KEYBOARD_SETUP"] == "1",
              let path = env["PROGRAMA_UI_TEST_CHILD_EXIT_KEYBOARD_PATH"],
              !path.isEmpty else {
            return nil
        }
        return path
    }

    private func childExitKeyboardProbeHex(_ value: String?) -> String {
        guard let value else { return "" }
        return value.unicodeScalars
            .map { String(format: "%04X", $0.value) }
            .joined(separator: ",")
    }

    private func writeChildExitKeyboardProbe(_ updates: [String: String], increments: [String: Int] = [:]) {
        guard let path = childExitKeyboardProbePath() else { return }
        var payload: [String: String] = {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
                return [:]
            }
            return object
        }()
        for (key, by) in increments {
            let current = Int(payload[key] ?? "") ?? 0
            payload[key] = String(current + by)
        }
        for (key, value) in updates {
            payload[key] = value
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
#endif

    var mainWindowContexts: [ObjectIdentifier: MainWindowContext] = [:]
    private var disposingMainWindows: Set<ObjectIdentifier> = []
    private var mainWindowControllers: [MainWindowController] = []

    /// Tracks the cascade point for new windows, matching Ghostty's upstream algorithm.
    /// Reset to `.zero` so the first window seeds the point from its own position.
    private var lastCascadePoint = NSPoint.zero
    private var startupSessionSnapshot: AppSessionSnapshot?
    private var didPrepareStartupSessionSnapshot = false
    private var didAttemptStartupSessionRestore = false
    var isApplyingStartupSessionRestore = false
    lazy var startupHandoff = StartupSessionHandoff(
        olderProcess: StartupSessionHandoff.authenticatedOlderProcess,
        isLive: { Self.singleInstanceProcessKey(for: $0.processIdentifier) == $0 },
        onReady: { [weak self] in self?.resumeStartupSessionAfterHandoff() }
    )
    private var startupHandoffPrimaryWindowId: UUID?
    private var acknowledgedDuplicateShutdown: (target: ProgramaSingleInstanceProcessKey, generation: UUID, url: URL)?
    let sessionPersistenceQueue = DispatchQueue(
        label: "com.cmuxterm.app.sessionPersistence",
        qos: .utility
    )
    var sessionSnapshotWriter: @Sendable (AppSessionSnapshot) -> Bool = {
        SessionPersistenceStore.save($0)
    }
    // Constructed eagerly with placeholder dependencies; `configure(...)` in `init()` rebinds
    // them to the real queue/closures immediately after `super.init()` returns. See
    // `SessionAutosaveCoordinator.configure` for why this two-step exists.
    let sessionAutosave = SessionAutosaveCoordinator(
        sessionPersistenceQueue: DispatchQueue(
            label: "com.cmuxterm.app.sessionPersistence.autosave-placeholder",
            qos: .utility
        ),
        snapshotProvider: { _ in nil },
        saveSnapshot: { _, _, completion in completion(false) },
        isTerminating: { false },
        isRunningUnderXCTest: { false }
    )
    private nonisolated static let launchServicesRegistrationQueue = DispatchQueue(
        label: "com.cmuxterm.app.launchServicesRegistration",
        qos: .utility
    )
    private nonisolated static func enqueueLaunchServicesRegistrationWork(_ work: @escaping @Sendable () -> Void) {
        launchServicesRegistrationQueue.async(execute: work)
    }
    private var didHandleExplicitOpenIntentAtStartup = false
    private let appLifecycleCoordinator = AppLifecycleCoordinator()
    var isTerminatingApp: Bool { appLifecycleCoordinator.isTerminating }
#if DEBUG
    var debugSessionSnapshotSaverForTesting: ((AppSessionSnapshot) -> Bool)?
    var debugQuitSaveFailureAlertForTesting: (() -> Void)?

    func debugResetTerminationForTesting() {
        appLifecycleCoordinator.cancelTermination()
        SessionMachineryGate.isApplicationTerminating = false
    }
#endif
    private static let commandPaletteRequestGraceInterval: TimeInterval = 1.25
    private static let commandPalettePendingOpenMaxAge: TimeInterval = 8.0

    var updateViewModel: UpdateViewModel {
        updateController.viewModel
    }

#if DEBUG
    private func pointerString(_ object: AnyObject?) -> String {
        guard let object else { return "nil" }
        return String(describing: Unmanaged.passUnretained(object).toOpaque())
    }

    private func summarizeContextForWorkspaceRouting(_ context: MainWindowContext?) -> String {
        guard let context else { return "nil" }
        let window = context.window ?? windowForMainWindowId(context.windowId)
        let windowNumber = window?.windowNumber ?? -1
        let key = window?.isKeyWindow == true ? 1 : 0
        let main = window?.isMainWindow == true ? 1 : 0
        let visible = window?.isVisible == true ? 1 : 0
        let selected = context.tabManager.selectedTabId.map { String($0.uuidString.prefix(8)) } ?? "nil"
        return "wid=\(context.windowId.uuidString.prefix(8)) win=\(windowNumber) key=\(key) main=\(main) vis=\(visible) tabs=\(context.tabManager.tabs.count) sel=\(selected) tm=\(pointerString(context.tabManager))"
    }

    private func summarizeAllContextsForWorkspaceRouting() -> String {
        guard !mainWindowContexts.isEmpty else { return "<none>" }
        return mainWindowContexts.values
            .map { summarizeContextForWorkspaceRouting($0) }
            .joined(separator: " | ")
    }

    private func logWorkspaceCreationRouting(
        phase: String,
        source: String,
        reason: String,
        event: NSEvent?,
        chosenContext: MainWindowContext?,
        workspaceId: UUID? = nil,
        workingDirectory: String? = nil
    ) {
        let eventWindowNumber = event?.window?.windowNumber ?? -1
        let eventNumber = event?.windowNumber ?? -1
        let eventChars = event?.charactersIgnoringModifiers ?? ""
        let eventKeyCode = event.map { String($0.keyCode) } ?? "nil"
        let keyWindowNumber = NSApp.keyWindow?.windowNumber ?? -1
        let mainWindowNumber = NSApp.mainWindow?.windowNumber ?? -1
        let ws = workspaceId.map { String($0.uuidString.prefix(8)) } ?? "nil"
        let wd = workingDirectory.map { String($0.prefix(120)) } ?? "-"
        FocusLogStore.shared.append(
            "cmdn.route phase=\(phase) src=\(source) reason=\(reason) eventWin=\(eventWindowNumber) eventNum=\(eventNumber) keyCode=\(eventKeyCode) chars=\(eventChars) keyWin=\(keyWindowNumber) mainWin=\(mainWindowNumber) activeTM=\(pointerString(tabManager)) chosen={\(summarizeContextForWorkspaceRouting(chosenContext))} ws=\(ws) wd=\(wd) contexts=[\(summarizeAllContextsForWorkspaceRouting())]"
        )
    }
#endif

    override init() {
        super.init()
        Self.shared = self
        sessionAutosave.configure(
            sessionPersistenceQueue: sessionPersistenceQueue,
            snapshotProvider: { [weak self] includeScrollback in
                self?.buildSessionSnapshot(includeScrollback: includeScrollback)
            },
            saveSnapshot: { [weak self] includeScrollback, prebuiltSnapshot, completion in
                guard let self else {
                    completion(false)
                    return
                }
                self.saveSessionSnapshot(
                    includeScrollback: includeScrollback,
                    prebuiltSnapshot: prebuiltSnapshot,
                    completion: completion
                )
            },
            isTerminating: { [weak self] in self?.isTerminatingApp ?? false },
            isRunningUnderXCTest: { [weak self] in
                guard let self else { return false }
                return self.isRunningUnderXCTest(ProcessInfo.processInfo.environment)
            }
        )
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let directories = externalOpenDirectories(from: urls)
        guard !directories.isEmpty else { return }

        prepareForExplicitOpenIntentAtStartup()
        for directory in directories {
            openWorkspaceForExternalDirectory(
                workingDirectory: directory,
                debugSource: "application.openURLs"
            )
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let env = ProcessInfo.processInfo.environment
        let isRunningUnderXCTest = isRunningUnderXCTest(env)

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleThemesReloadNotification(_:)),
            name: ProgramaThemeNotifications.reloadConfig,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDesignModeDidCapture(_:)),
            name: .designModeDidCapture,
            object: nil
        )

#if DEBUG
        // UI tests run on a shared VM user profile, so persisted shortcuts can drift and make
        // key-equivalent routing flaky. Force defaults for deterministic tests.
        if isRunningUnderXCTest {
            KeyboardShortcutSettings.resetAll()
        }
#endif

#if DEBUG
        writeUITestDiagnosticsIfNeeded(stage: "didFinishLaunching")
        ProgramaMainRunLoopStallMonitor.shared.installIfNeeded()
        ProgramaMainThreadTurnProfiler.shared.installIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.writeUITestDiagnosticsIfNeeded(stage: "after1s")
        }
#endif

        let forceDuplicateLaunchObserver = env["PROGRAMA_UI_TEST_ENABLE_DUPLICATE_LAUNCH_OBSERVER"] == "1"

        // UI tests frequently time out waiting for the main window if we do heavyweight
        // LaunchServices registration / single-instance enforcement synchronously at startup.
        // Skip these during XCTest (the app-under-test) so the window can appear quickly.
        if !isRunningUnderXCTest {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scheduleLaunchServicesBundleRegistration()
                self.enforceSingleInstance()
                self.startupHandoff.initialArbitrationCompleted()
                self.observeDuplicateLaunches()
            }
        } else if forceDuplicateLaunchObserver {
            // Some UI regressions specifically exercise launch-observer behavior while still
            // running under XCTest. Give the initial window and accessibility hierarchy a
            // bounded head start before opting into process inspection for those cases only.
            dilog("single_instance", "pid=\(getpid()) outcome=scheduled reason=ui_test_observer")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                dilog("single_instance", "pid=\(getpid()) outcome=installed reason=ui_test_observer")
                self?.observeDuplicateLaunches()
            }
        }
        NSWindow.allowsAutomaticWindowTabbing = false
        disableNativeTabbingShortcut()
        ensureApplicationIcon()
        if !isRunningUnderXCTest {
            configureUserNotifications()
            installMenuBarVisibilityObserver()
            syncMenuBarExtraVisibility()
            updateController.startUpdaterIfNeeded()
        }
        titlebarAccessoryController.start()
        installMainWindowKeyObserver()
        refreshGhosttyGotoSplitShortcuts()
        installGhosttyConfigObserver()
        installWindowResponderSwizzles()
        installBrowserAddressBarFocusObservers()
        installShortcutMonitor()
        installShortcutDefaultsObserver()
        RendererRealizationController.shared.start()
        NSApp.servicesProvider = self
#if DEBUG
        UpdateTestSupport.applyIfNeeded(to: updateController.viewModel)
        if env["PROGRAMA_UI_TEST_MODE"] == "1" {
            let trigger = env["PROGRAMA_UI_TEST_TRIGGER_UPDATE_CHECK"] ?? "<nil>"
            let feed = env["PROGRAMA_UI_TEST_FEED_URL"] ?? "<nil>"
            UpdateLogStore.shared.append("ui test env: trigger=\(trigger) feed=\(feed)")
        }
        if env["PROGRAMA_UI_TEST_TRIGGER_UPDATE_CHECK"] == "1" {
            UpdateLogStore.shared.append("ui test trigger update check detected")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self else { return }
                let windowIds = NSApp.windows.map { $0.identifier?.rawValue ?? "<nil>" }
                UpdateLogStore.shared.append("ui test windows: count=\(NSApp.windows.count) ids=\(windowIds.joined(separator: ","))")
                if UpdateTestSupport.performMockFeedCheckIfNeeded(on: self.updateController.viewModel) {
                    return
                }
                self.checkForUpdates(nil)
            }
        }

        // In UI tests, `WindowGroup` occasionally fails to materialize a window quickly on the VM.
        // If there are no windows shortly after launch, force-create one so XCUITest can proceed.
        // Unit tests (embedded XCTest bundle hosted in this same process) manage their own
        // windows explicitly per test and never want a phantom default window lingering in
        // `mainWindowContexts` for the lifetime of the test run, so exclude that case here.
        if isRunningUnderXCTest, !isEmbeddedUnitTestHost(env) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self else { return }
                if NSApp.windows.isEmpty {
                    self.openNewMainWindow(nil)
                }
                self.moveUITestWindowToTargetDisplayIfNeeded()
                NSRunningApplication.current.activate(options: [.activateAllWindows])
                // On headless CI runners, activate() silently fails (no GUI session).
                // Force windows visible so the terminal surface starts rendering.
                for window in NSApp.windows {
                    window.orderFrontRegardless()
                }
                self.writeUITestDiagnosticsIfNeeded(stage: "afterForceWindow")
            }
        }
#endif
    }

#if DEBUG
    func writeUITestDiagnosticsIfNeeded(stage: String) {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["PROGRAMA_UI_TEST_DIAGNOSTICS_PATH"], !path.isEmpty else { return }

        var payload = loadUITestDiagnostics(at: path)
        let isRunningUnderXCTest = isRunningUnderXCTest(env)

        let windows = NSApp.windows
        let ids = windows.map { $0.identifier?.rawValue ?? "" }.joined(separator: ",")
        let vis = windows.map { $0.isVisible ? "1" : "0" }.joined(separator: ",")
        let screenIDs = windows.map { $0.screen?.programaDisplayID.map(String.init) ?? "" }.joined(separator: ",")
        let targetDisplayID = env["PROGRAMA_UI_TEST_TARGET_DISPLAY_ID"] ?? ""

        payload["stage"] = stage
        payload["pid"] = String(ProcessInfo.processInfo.processIdentifier)
        payload["bundleId"] = Bundle.main.bundleIdentifier ?? ""
        payload["isRunningUnderXCTest"] = isRunningUnderXCTest ? "1" : "0"
        payload["windowsCount"] = String(windows.count)
        payload["windowIdentifiers"] = ids
        payload["windowVisibleFlags"] = vis
        payload["windowScreenDisplayIDs"] = screenIDs
        payload["uiTestTargetDisplayID"] = targetDisplayID
        if let rawDisplayID = UInt32(targetDisplayID) {
            let screenPresent = NSScreen.screens.contains(where: { $0.programaDisplayID == rawDisplayID })
            let movedWindow = windows.contains(where: { $0.screen?.programaDisplayID == rawDisplayID })
            payload["targetDisplayPresent"] = screenPresent ? "1" : "0"
            payload["targetDisplayMoveSucceeded"] = movedWindow ? "1" : "0"
        }
        appendUITestRenderDiagnosticsIfNeeded(&payload, environment: env)
        appendUITestSocketDiagnosticsIfNeeded(&payload, environment: env)

        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private func loadUITestDiagnostics(at path: String) -> [String: String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return object
    }

    private func appendUITestSocketDiagnosticsIfNeeded(
        _ payload: inout [String: String],
        environment env: [String: String]
    ) {
        guard env["PROGRAMA_UI_TEST_SOCKET_SANITY"] == "1" else { return }

        guard let config = socketListenerConfigurationIfEnabled() else {
            payload["socketExpectedPath"] = env["PROGRAMA_SOCKET_PATH"] ?? ""
            payload["socketMode"] = "off"
            payload["socketReady"] = "0"
            payload["socketPingResponse"] = ""
            payload["socketIsRunning"] = "0"
            payload["socketAcceptLoopAlive"] = "0"
            payload["socketPathMatches"] = "0"
            payload["socketPathExists"] = "0"
            payload["socketFailureSignals"] = "socket_disabled"
            return
        }

        let socketPath = TerminalController.shared.activeSocketPath(preferredPath: config.path)
        let health = TerminalController.shared.socketListenerHealth(expectedSocketPath: socketPath)
        let pingResponse = health.isHealthy
            ? TerminalController.probeSocketPing(at: socketPath, timeout: 1.0)
            : nil
        let isReady = health.isHealthy && pingResponse == "PONG"
        var failureSignals = health.failureSignals
        if health.isHealthy && pingResponse != "PONG" {
            failureSignals.append("ping_timeout")
        }

        payload["socketExpectedPath"] = socketPath
        payload["socketMode"] = config.mode.rawValue
        payload["socketReady"] = isReady ? "1" : "0"
        payload["socketPingResponse"] = pingResponse ?? ""
        payload["socketIsRunning"] = health.isRunning ? "1" : "0"
        payload["socketAcceptLoopAlive"] = health.acceptLoopAlive ? "1" : "0"
        payload["socketPathMatches"] = health.socketPathMatches ? "1" : "0"
        payload["socketPathExists"] = health.socketPathExists ? "1" : "0"
        payload["socketFailureSignals"] = failureSignals.joined(separator: ",")
    }

    private func appendUITestRenderDiagnosticsIfNeeded(
        _ payload: inout [String: String],
        environment env: [String: String]
    ) {
        guard env["PROGRAMA_UI_TEST_DISPLAY_RENDER_STATS"] == "1" else { return }

        guard let renderState = currentUITestRenderDiagnostics() else {
            payload["renderStatsAvailable"] = "0"
            payload["renderPanelId"] = ""
            payload["renderDrawCount"] = ""
            payload["renderPresentCount"] = ""
            payload["renderLastPresentTime"] = ""
            payload["renderWindowVisible"] = ""
            payload["renderAppIsActive"] = ""
            payload["renderDesiredFocus"] = ""
            payload["renderIsFirstResponder"] = ""
            payload["renderDiagnosticsUpdatedAt"] = String(format: "%.6f", ProcessInfo.processInfo.systemUptime)
            return
        }

        payload["renderStatsAvailable"] = "1"
        payload["renderPanelId"] = renderState.panelId.uuidString
        payload["renderDrawCount"] = String(renderState.drawCount)
        payload["renderPresentCount"] = String(renderState.presentCount)
        payload["renderLastPresentTime"] = String(format: "%.6f", renderState.lastPresentTime)
        payload["renderWindowVisible"] = renderState.windowVisible ? "1" : "0"
        payload["renderAppIsActive"] = renderState.appIsActive ? "1" : "0"
        payload["renderDesiredFocus"] = renderState.desiredFocus ? "1" : "0"
        payload["renderIsFirstResponder"] = renderState.isFirstResponder ? "1" : "0"
        payload["renderDiagnosticsUpdatedAt"] = String(format: "%.6f", ProcessInfo.processInfo.systemUptime)
    }

    private func currentUITestRenderDiagnostics() -> UITestRenderDiagnosticsSnapshot? {
        guard let tabManager,
              let tabId = tabManager.selectedTabId,
              let workspace = tabManager.tabs.first(where: { $0.id == tabId }) else {
            return nil
        }

        let terminalPanel: TerminalPanel? = {
            if let focusedPanelId = workspace.focusedPanelId,
               let terminalPanel = workspace.terminalPanel(for: focusedPanelId) {
                return terminalPanel
            }
            if let focusedTerminalPanel = workspace.focusedTerminalPanel {
                return focusedTerminalPanel
            }
            return workspace.panels.values.compactMap { $0 as? TerminalPanel }.first
        }()

        guard let terminalPanel else { return nil }
        let stats = terminalPanel.hostedView.debugRenderStats()
        return UITestRenderDiagnosticsSnapshot(
            panelId: terminalPanel.id,
            drawCount: stats.drawCount,
            presentCount: stats.presentCount,
            lastPresentTime: stats.lastPresentTime,
            windowVisible: stats.windowOcclusionVisible,
            appIsActive: stats.appIsActive,
            desiredFocus: stats.desiredFocus,
            isFirstResponder: stats.isFirstResponder
        )
    }

    // Not private: the display-churn UI test's diagnostics observer
    // (AppDelegate+UITestCmdClick.swift) re-invokes this on every
    // NSApplication.didChangeScreenParametersNotification to pull the window
    // back onto the target display if a mode change bumped it off (#see call site).
    func moveUITestWindowToTargetDisplayIfNeeded(attempt: Int = 0) {
        let env = ProcessInfo.processInfo.environment
        guard let rawDisplayID = env["PROGRAMA_UI_TEST_TARGET_DISPLAY_ID"],
              let targetDisplayID = UInt32(rawDisplayID) else {
            return
        }

        guard let screen = NSScreen.screens.first(where: { $0.programaDisplayID == targetDisplayID }) else {
            if attempt < 20 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    self?.moveUITestWindowToTargetDisplayIfNeeded(attempt: attempt + 1)
                }
            }
            self.writeUITestDiagnosticsIfNeeded(stage: "targetDisplayMissing")
            return
        }

        guard let window = NSApp.windows.first else {
            if attempt < 20 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    self?.moveUITestWindowToTargetDisplayIfNeeded(attempt: attempt + 1)
                }
            }
            self.writeUITestDiagnosticsIfNeeded(stage: "targetDisplayNoWindow")
            return
        }

        let visibleFrame = screen.visibleFrame
        let width = min(window.frame.width, max(visibleFrame.width - 80, 480))
        let height = min(window.frame.height, max(visibleFrame.height - 80, 360))
        let frame = NSRect(
            x: visibleFrame.midX - (width / 2),
            y: visibleFrame.midY - (height / 2),
            width: width,
            height: height
        ).integral

        window.setFrame(frame, display: true, animate: false)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        if window.screen?.programaDisplayID != targetDisplayID, attempt < 20 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.moveUITestWindowToTargetDisplayIfNeeded(attempt: attempt + 1)
            }
            return
        }
        self.writeUITestDiagnosticsIfNeeded(stage: "afterMoveToTargetDisplay")
    }
#endif

    func applicationDidBecomeActive(_ notification: Notification) {
#if DEBUG
        dlog(
            "app.activation active=1 frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil") " +
            "keyWindow=\(NSApp.keyWindow?.identifier?.rawValue ?? "nil") " +
            "currentEvent=\(NSApp.currentEvent.map { String(describing: $0.type) } ?? "nil")"
        )
#endif
        // `willPowerOffNotification` has no matching cancellation notification. If macOS
        // becomes active again before termination, the shutdown was cancelled: resume
        // autosave/session machinery and replace the provisional snapshot with a normal one.
        if appLifecycleCoordinator.resumeAfterCancelledPowerOff() {
            SessionMachineryGate.isApplicationTerminating = false
            saveSessionSnapshot(includeScrollback: false)
        }
        guard let notificationStore else { return }
        notificationStore.handleApplicationDidBecomeActive()
        guard let tabManager else { return }
        guard let tabId = tabManager.selectedTabId else { return }
        let surfaceId = tabManager.focusedSurfaceId(for: tabId)
        guard notificationStore.hasUnreadNotification(forTabId: tabId, surfaceId: surfaceId) else { return }

        if let surfaceId,
           let tab = tabManager.tabs.first(where: { $0.id == tabId }) {
            tab.triggerNotificationFocusFlash(panelId: surfaceId, requiresSplit: false, shouldFocus: false)
        }
        notificationStore.markRead(forTabId: tabId, surfaceId: surfaceId)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if !startupHandoff.hasCompletedInitialArbitration {
            enforceSingleInstance()
            startupHandoff.initialArbitrationCompleted()
        }
        if startupHandoff.isWaiting { appLifecycleCoordinator.confirmSingleInstanceLoser() }
        // Validate the exact-process arbitration request and publish an acknowledgment before
        // synchronous persistence begins. Requesters treat that acknowledgment as proof that
        // this process is responsive and cannot prompt or force-close us during teardown.
        let hasValidatedDuplicateShutdownRequest = acknowledgeValidatedDuplicateShutdownRequest()
        let lifecycleDecision = appLifecycleCoordinator.beginTermination(
            hasValidatedDuplicateShutdownRequest: hasValidatedDuplicateShutdownRequest,
            isTaggedDevBuild: SocketControlSettings.isTaggedDevBuild(),
            isQuitWarningEnabled: QuitWarningSettings.isEnabled()
        )
        SessionMachineryGate.isApplicationTerminating = true
        let terminationPolicy = Self.singleInstanceTerminationPersistencePolicy(
            isDiscardedDuplicate: appLifecycleCoordinator.isSingleInstanceLoser
        )
        // A warning dialog can still cancel this termination request. The final
        // `applicationWillTerminate` callback is the only point that records a clean exit.
        if terminationPolicy.persistPreTerminationSnapshot {
            let saved = saveSessionSnapshot(includeScrollback: true, removeWhenEmpty: false)
            if !saved && !mainWindowContexts.isEmpty {
                revokeAcknowledgedDuplicateShutdown()
                appLifecycleCoordinator.cancelTermination()
                SessionMachineryGate.isApplicationTerminating = false
                dilog("session.save", "outcome=quit_cancelled reason=snapshot_write_failed")
#if DEBUG
                if let debugQuitSaveFailureAlertForTesting {
                    debugQuitSaveFailureAlertForTesting()
                    return .terminateCancel
                }
#endif
                let alert = NSAlert()
                alert.alertStyle = .critical
                alert.messageText = String(localized: "dialog.quitSaveFailed.title", defaultValue: "Couldn’t Save Sessions")
                alert.informativeText = String(
                    localized: "dialog.quitSaveFailed.message",
                    defaultValue: "Programa stayed open because it couldn’t save your sessions. Check available disk space and try quitting again."
                )
                alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
                alert.runModal()
                return .terminateCancel
            }
        }

        guard lifecycleDecision.shouldWarn else {
            dilog("single_instance", "pid=\(getpid()) outcome=terminate_now reason=\(lifecycleDecision.logReason)")
            return .terminateNow
        }
        dilog("single_instance", "pid=\(getpid()) outcome=warning reason=ordinary_quit")

        // Show the same confirmation dialog used by the Cmd+Q shortcut path,
        // then reply asynchronously so we can return .terminateLater now.
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(localized: "dialog.quitPrograma.title", defaultValue: "Quit Programa?")
            alert.informativeText = String(localized: "dialog.quitPrograma.message", defaultValue: "This will close all windows and workspaces.")
            alert.addButton(withTitle: String(localized: "dialog.quitPrograma.quit", defaultValue: "Quit"))
            alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = String(localized: "dialog.dontWarnCmdQ", defaultValue: "Don't warn again for Cmd+Q")

            let response = alert.runModal()
            if alert.suppressionButton?.state == .on {
                QuitWarningSettings.setEnabled(false)
            }

            let shouldQuit = response == .alertFirstButtonReturn
            if shouldQuit {
                self.appLifecycleCoordinator.confirmQuit()
            } else {
                self.revokeAcknowledgedDuplicateShutdown()
                // Reset so that the next quit attempt can show the dialog again.
                self.appLifecycleCoordinator.cancelTermination()
                // Must be reset in lockstep, or a cancelled quit would leave
                // the session machinery treating every later close as
                // termination and never releasing escrowed sessions.
                SessionMachineryGate.isApplicationTerminating = false
            }
            NSApp.reply(toApplicationShouldTerminate: shouldQuit)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        appLifecycleCoordinator.willTerminate()
        SessionMachineryGate.isApplicationTerminating = true
        let terminationPolicy = Self.singleInstanceTerminationPersistencePolicy(
            isDiscardedDuplicate: appLifecycleCoordinator.isSingleInstanceLoser
        )
        if terminationPolicy.persistCleanShutdownSnapshot {
            saveSessionSnapshot(includeScrollback: true, removeWhenEmpty: false, cleanShutdown: true)
        }
        guard terminationPolicy.performProcessLocalTeardown else { return }
        // Finalize any terminal closes still sitting in their undo grace period so a staged close
        // doesn't quietly leak instead of tearing down cleanly on quit.
        for context in mainWindowContexts.values {
            context.tabManager.closedTerminalUndoStore.expireAll()
        }
        sessionAutosave.stopSessionAutosaveTimer()
        TerminalController.shared.stop()
        BrowserProfileStore.shared.flushPendingSaves()
        notificationStore?.clearAll()
        enableSuddenTerminationIfNeeded()
    }

    func applicationWillResignActive(_ notification: Notification) {
#if DEBUG
        dlog("app.activation active=0 frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil")")
#endif
        guard !isTerminatingApp else { return }
        clearConfiguredShortcutChordState()
        saveSessionSnapshot(includeScrollback: false)
    }

    func persistSessionForUpdateRelaunch() {
        appLifecycleCoordinator.beginUpdateRelaunch()
        // The user already consented to this termination by choosing to install
        // the update — without this, applicationShouldTerminate shows the modal
        // "Quit Programa?" warning in the middle of the update relaunch for
        // default-config users, and if Sparkle force-kills past its timeout the
        // stale cleanShutdown=false snapshot fires the crash-recovery notice as
        // a false positive on the next launch (audit 2026-08-20, H4).
        saveSessionSnapshot(includeScrollback: true, removeWhenEmpty: false)
    }

    func configure(tabManager: TabManager, notificationStore: TerminalNotificationStore, sidebarState: SidebarState) {
        self.tabManager = tabManager
        self.notificationStore = notificationStore
        self.sidebarState = sidebarState
        disableSuddenTerminationIfNeeded()
        installLifecycleSnapshotObserversIfNeeded()
        prepareStartupSessionSnapshotIfNeeded()
        sessionAutosave.startSessionAutosaveTimerIfNeeded()
#if DEBUG
        setupJumpUnreadUITestIfNeeded()
        setupTerminalCmdClickUITestIfNeeded()
        setupGotoSplitUITestIfNeeded()
        setupBonsplitTabDragUITestIfNeeded()
        setupMultiWindowNotificationsUITestIfNeeded()
        setupDisplayResolutionUITestDiagnosticsIfNeeded()

        // UI tests sometimes don't run SwiftUI `.onAppear` soon enough (or at all) on the VM.
        // The automation socket is a core testing primitive, so ensure it's started here when
        // we detect XCTest, even if the main view lifecycle is flaky.
        let env = ProcessInfo.processInfo.environment
        if isRunningUnderXCTest(env) {
            let raw = UserDefaults.standard.string(forKey: SocketControlSettings.appStorageKey)
                ?? SocketControlSettings.defaultMode.rawValue
            let userMode = SocketControlSettings.migrateMode(raw)
            let mode = SocketControlSettings.effectiveMode(userMode: userMode)
            if mode != .off {
                TerminalController.shared.start(
                    tabManager: tabManager,
                    socketPath: SocketControlSettings.socketPath(),
                    accessMode: mode
                )
                scheduleUITestSocketSanityCheckIfNeeded()
            }
        }
#endif
    }


    private func prepareStartupSessionSnapshotIfNeeded() {
        guard !didPrepareStartupSessionSnapshot else { return }
        guard !startupHandoff.shouldDefer() else { return }
        didPrepareStartupSessionSnapshot = true
        // Archive whatever the previous launch left behind before any code path below (or
        // later in startup) can overwrite it -- including a launch that skips restore entirely
        // (explicit open intent), which otherwise clobbers the file with no way back.
        let captureEnabled = SessionWALStore.shared.currentCapturePolicy().enabled
        let archivedWithContent = captureEnabled ? try? SessionScrollbackPolicyStore.withContentPermission(
            at: SessionScrollbackPolicyPaths.make(), capturedGeneration: nil,
            { SessionPersistenceStore.rotateIntoHistory() }
        ) : nil
        if archivedWithContent == nil {
            SessionPersistenceStore.rotateIntoHistory(includeScrollback: false)
        }
        guard !didHandleExplicitOpenIntentAtStartup, SessionRestorePolicy.shouldAttemptRestore() else { return }
        Self.removeLegacyPersistedWindowGeometry()
        startupSessionSnapshot = core.sessionSnapshots.loadWithHistoryFallback()
    }

    private func persistedWindowGeometry(
        defaults: UserDefaults = .standard
    ) -> PersistedWindowGeometry? {
        Self.removeLegacyPersistedWindowGeometry(defaults: defaults)
        guard let data = defaults.data(forKey: Self.persistedWindowGeometryDefaultsKey) else {
            return nil
        }
        guard let payload = Self.decodedPersistedWindowGeometryData(data) else {
            defaults.removeObject(forKey: Self.persistedWindowGeometryDefaultsKey)
            return nil
        }
        return payload
    }

    private func persistWindowGeometry(
        frame: SessionRectSnapshot?,
        display: SessionDisplaySnapshot?,
        defaults: UserDefaults = .standard
    ) {
        Self.removeLegacyPersistedWindowGeometry(defaults: defaults)
        guard let data = Self.encodedPersistedWindowGeometryData(frame: frame, display: display) else {
            return
        }
        defaults.set(data, forKey: Self.persistedWindowGeometryDefaultsKey)
    }

    nonisolated static func encodedPersistedWindowGeometryData(
        frame: SessionRectSnapshot?,
        display: SessionDisplaySnapshot?
    ) -> Data? {
        guard let frame else { return nil }
        let payload = PersistedWindowGeometry(
            version: persistedWindowGeometrySchemaVersion,
            frame: frame,
            display: display
        )
        return try? JSONEncoder().encode(payload)
    }

    nonisolated static func decodedPersistedWindowGeometryData(_ data: Data) -> PersistedWindowGeometry? {
        guard let payload = try? JSONDecoder().decode(PersistedWindowGeometry.self, from: data),
              payload.version == persistedWindowGeometrySchemaVersion else {
            return nil
        }
        return payload
    }

    nonisolated static func removeLegacyPersistedWindowGeometry(
        defaults: UserDefaults = .standard
    ) {
        legacyPersistedWindowGeometryDefaultsKeys.forEach { defaults.removeObject(forKey: $0) }
    }

    private func persistWindowGeometry(from window: NSWindow?) {
        guard let window else { return }
        persistWindowGeometry(
            frame: SessionRectSnapshot(window.frame),
            display: displaySnapshot(for: window)
        )
    }

    private func currentDisplayGeometries() -> (
        available: [SessionDisplayGeometry],
        fallback: SessionDisplayGeometry?
    ) {
        let available = NSScreen.screens.map { screen in
            SessionDisplayGeometry(
                displayID: screen.programaDisplayID,
                stableID: screen.programaStableDisplayID,
                frame: screen.frame,
                visibleFrame: screen.visibleFrame
            )
        }
        let fallback = (NSScreen.main ?? NSScreen.screens.first).map { screen in
            SessionDisplayGeometry(
                displayID: screen.programaDisplayID,
                stableID: screen.programaStableDisplayID,
                frame: screen.frame,
                visibleFrame: screen.visibleFrame
            )
        }
        return (available, fallback)
    }

    private func attemptStartupSessionRestoreIfNeeded(primaryWindow: NSWindow) {
        guard !didAttemptStartupSessionRestore else { return }
        guard !startupHandoff.shouldDefer() else { return }
        prepareStartupSessionSnapshotIfNeeded()
        didAttemptStartupSessionRestore = true
        guard !didHandleExplicitOpenIntentAtStartup else { return }
        guard let primaryContext = contextForMainTerminalWindow(primaryWindow) else { return }

        let startupSnapshot = startupSessionSnapshot
        if startupSnapshot?.cleanShutdown == false {
            // The previous run's last snapshot was a periodic autosave, meaning the
            // process died without walking applicationWillTerminate — a crash or a
            // force kill. Until 2026-08-19 this flag was write-only: crashes were
            // invisible unless the user noticed on their own, and escrow revived
            // sessions silently. Say what happened.
            notifyUncleanShutdownRecovery()
        }
        let primaryWindowSnapshot = startupSnapshot?.windows.first
        if let primaryWindowSnapshot {
            isApplyingStartupSessionRestore = true
#if DEBUG
            dlog(
                "session.restore.start windows=\(startupSnapshot?.windows.count ?? 0) " +
                    "primaryFrame={\(debugSessionRectDescription(primaryWindowSnapshot.frame))} " +
                    "primaryDisplay={\(debugSessionDisplayDescription(primaryWindowSnapshot.display))}"
            )
#endif
            applySessionWindowSnapshot(
                primaryWindowSnapshot,
                to: primaryContext,
                window: primaryWindow
            )
        } else {
            let displays = currentDisplayGeometries()
            let fallbackGeometry = persistedWindowGeometry()
            if let restoredFrame = Self.resolvedStartupPrimaryWindowFrame(
                primarySnapshot: nil,
                fallbackFrame: fallbackGeometry?.frame,
                fallbackDisplaySnapshot: fallbackGeometry?.display,
                availableDisplays: displays.available,
                fallbackDisplay: displays.fallback
            ) {
                primaryWindow.setFrame(restoredFrame, display: true)
            }
        }

        if let startupSnapshot {
            let additionalWindows = Array(startupSnapshot
                .windows
                .dropFirst()
                .prefix(max(0, SessionPersistencePolicy.maxWindowsPerSnapshot - 1)))
#if DEBUG
            for (index, windowSnapshot) in additionalWindows.enumerated() {
                dlog(
                    "session.restore.enqueueAdditional idx=\(index + 1) " +
                        "frame={\(debugSessionRectDescription(windowSnapshot.frame))} " +
                        "display={\(debugSessionDisplayDescription(windowSnapshot.display))}"
                )
            }
#endif
            if !additionalWindows.isEmpty {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    for windowSnapshot in additionalWindows {
                        _ = self.createMainWindow(sessionWindowSnapshot: windowSnapshot)
                    }
                    self.completeStartupSessionRestore()
                }
            } else {
                completeStartupSessionRestore()
            }
        } else {
            completeStartupSessionRestore()
        }
    }

    /// Posts the crash-recovery notice (system notification + a Release
    /// diagnostics line). Called once per launch, only when the loaded startup
    /// snapshot's `cleanShutdown` is explicitly false — nil means an
    /// older-schema snapshot where the answer is unknown, so we stay quiet.
    private func notifyUncleanShutdownRecovery() {
        dilog("session.restore", "uncleanShutdown detected=1")
        TerminalNotificationStore.shared.postAppNotification(
            title: String(
                localized: "crash_recovery.notification.title",
                defaultValue: "Restored after an unexpected exit"
            ),
            body: String(
                localized: "crash_recovery.notification.body",
                defaultValue: "Programa quit unexpectedly last time. Saved workspaces are being restored and available processes reconnected. Terminals that cannot reconnect start a new shell."
            )
        )
    }

    private func completeStartupSessionRestore() {
        startupSessionSnapshot = nil
        isApplyingStartupSessionRestore = false
        saveSessionSnapshot(includeScrollback: false)
        reconcileOrphanedEscrowedSessions()
        ScrollbackPersistenceSettings.retryLegacyMigration()
    }

    private func resumeStartupSessionAfterHandoff() {
        guard !isTerminatingApp else { return }
        prepareStartupSessionSnapshotIfNeeded()
        let primary = mainWindowContexts.values.first(where: { $0.windowId == startupHandoffPrimaryWindowId })
            ?? mainWindowContexts.values.first
        if let primary, let window = primary.window ?? windowForMainWindowId(primary.windowId) {
            attemptStartupSessionRestoreIfNeeded(primaryWindow: window)
            _ = saveSessionSnapshot(includeScrollback: false)
        }
    }

    /// Issue #307 orphan-reconciliation fix: the coarse-snapshot restore
    /// that just completed above is keyed entirely by the panel UUIDs
    /// already present in `session-<bundleId>.json` -- if that snapshot was
    /// stale or missing at the moment of an abrupt kill, a session that is
    /// still alive and escrow-claimed on disk (`meta.json`'s
    /// `escrowed: true`) is never looked up, and becomes a permanently
    /// orphaned, invisible shell (see `SessionWALStore
    /// .escrowedSessionIds(excluding:)`'s doc comment). This pass runs
    /// once, synchronously, right after every normal-launch restore: it
    /// diffs the escrowed session directories on disk against every panel
    /// id the restore just produced (a harmless superset that also
    /// includes freshly-spawned, non-revived panels -- we only need to
    /// exclude what's already present, not distinguish revived-vs-fresh),
    /// and reattaches whatever is left into one clearly-labeled recovery
    /// window.
    ///
    /// Reuses `Workspace.revivePanel(sessionId:inPane:workingDirectory:)`
    /// (the same primitive the coarse restore itself uses) directly against
    /// each new tab's freshly-spawned initial pane, rather than pre-building
    /// a `TerminalSurfaceReviveDescriptor` and threading it through
    /// workspace creation: building that descriptor requires the escrow
    /// retrieve, which already lives inside `revivePanel` and shouldn't be
    /// duplicated here. The one fresh panel each new tab starts with is
    /// closed immediately once the revived panel has taken its place in the
    /// same pane, so no tab is ever left showing two panels or an empty one.
    private func reconcileOrphanedEscrowedSessions() {
        var known = Set<String>()
        for context in mainWindowContexts.values {
            for workspace in context.tabManager.tabs {
                for panelId in workspace.panels.keys {
                    known.insert(panelId.uuidString)
                }
            }
        }

        let ownedSockets = Set([SessionEscrowClient.legacySocketPath(), SessionEscrowClient.escrowSocketPath()])
        let orphans = SessionWALStore.shared.escrowedSessionIds(excluding: known).filter {
            $0.meta.escrowSocketPath.map(ownedSockets.contains) == true
        }
        guard !orphans.isEmpty else {
            dilog("escrow.reconcile", "found=0")
            return
        }

        let candidates = orphans.map {
            (sessionId: $0.sessionId, workingDirectory: $0.meta.workingDirectory)
        }
        guard let result = reconcileOrphanedEscrowedSessions(
            candidates: candidates,
            attemptRecovery: { candidate, workspace in
                guard let freshPanelId = workspace.panels.keys.first,
                      let paneId = workspace.paneId(forPanelId: freshPanelId) else {
                    return false
                }

                guard workspace.revivePanel(
                    sessionId: candidate.sessionId,
                    inPane: paneId,
                    workingDirectory: candidate.workingDirectory
                ) != nil else {
                    return false
                }

                // The revived panel now lives in the same pane as the fresh
                // placeholder panel the tab started with -- close the
                // placeholder so the tab ends up with exactly one (revived)
                // panel, never a leftover empty one.
                if !workspace.closePanel(freshPanelId, force: true) {
                    dilog(
                        "escrow.reconcile",
                        "session=\(candidate.sessionId.prefix(8)) outcome=revived reason=placeholder_close_failed panel=\(freshPanelId.uuidString.prefix(8))"
                    )
                }
                if let workingDirectory = candidate.workingDirectory,
                   !workingDirectory.isEmpty {
                    workspace.setCustomTitle(workingDirectory)
                }
                return true
            }
        ) else {
            dilog("escrow.reconcile", "found=\(orphans.count) recovered=0 reason=no_window")
            return
        }

        dilog("escrow.reconcile", "found=\(orphans.count) recovered=\(result.recoveredCount)")
    }

    func reconcileOrphanedEscrowedSessions(
        candidates: [(sessionId: String, workingDirectory: String?)],
        attemptRecovery: (
            _ candidate: (sessionId: String, workingDirectory: String?),
            _ workspace: Workspace
        ) -> Bool
    ) -> (windowId: UUID, recoveredCount: Int)? {
        guard !candidates.isEmpty else { return nil }

        let windowId = createMainWindow()
        guard let context = mainWindowContexts.values.first(where: { $0.windowId == windowId }),
              let bootstrapWorkspace = context.tabManager.tabs.first else {
            return nil
        }
        let tabManager = context.tabManager

        var recoveredCount = 0
        var pendingFailedWorkspace: Workspace?
        var shouldCloseBootstrapWorkspace = true

        for candidate in candidates {
            let workspace = tabManager.addWorkspace(
                workingDirectory: candidate.workingDirectory,
                select: false,
                autoWelcomeIfNeeded: false
            )

            if shouldCloseBootstrapWorkspace {
                tabManager.closeWorkspace(bootstrapWorkspace)
                shouldCloseBootstrapWorkspace = false
            }
            if let failedWorkspace = pendingFailedWorkspace {
                tabManager.closeWorkspace(failedWorkspace)
                pendingFailedWorkspace = nil
            }

            if attemptRecovery(candidate, workspace) {
                recoveredCount += 1
            } else {
                pendingFailedWorkspace = workspace
            }
        }

        guard recoveredCount > 0 else {
            // Every revive attempt failed: nothing to show, and leaving an
            // empty, oddly-titled window open with only blank placeholder
            // shells would just confuse whoever opens it next.
            if let window = resolvedWindow(for: context) { disposeMainWindow(window) }
            return (windowId: windowId, recoveredCount: 0)
        }

        if let pendingFailedWorkspace {
            tabManager.closeWorkspace(pendingFailedWorkspace)
        }

        // Set the window title last, after every workspace mutation above --
        // `TabManager.updateWindowTitle(for:)` reactively overwrites
        // `window.title` on tab selection and title changes (including the
        // `setCustomTitle` calls in the loop above), so setting it any
        // earlier gets clobbered before the user ever sees it.
        resolvedWindow(for: context)?.title = String(
            localized: "session_reconcile.window.title",
            defaultValue: "Recovered Sessions"
        )

        TerminalNotificationStore.shared.postAppNotification(
            title: String(
                localized: "session_reconcile.notification.title",
                defaultValue: "Recovered \(recoveredCount) session(s) from before the last restart"
            ),
            body: String(
                localized: "session_reconcile.notification.body",
                defaultValue: "Programa found terminal sessions still running from before the last restart and reattached them into a new window."
            )
        )

        // `createMainWindow()` persisted the bootstrap workspace before
        // reconciliation replaced it. Persist the finalized recovery window
        // immediately so another abrupt exit cannot restore that stale shell.
        saveSessionSnapshot(includeScrollback: false)

        return (windowId: windowId, recoveredCount: recoveredCount)
    }

    private func applySessionWindowSnapshot(
        _ snapshot: SessionWindowSnapshot,
        to context: MainWindowContext,
        window: NSWindow?
    ) {
#if DEBUG
        dlog(
            "session.restore.apply window=\(context.windowId.uuidString.prefix(8)) " +
                "liveWin=\(window?.windowNumber ?? -1) " +
                "snapshotFrame={\(debugSessionRectDescription(snapshot.frame))} " +
                "snapshotDisplay={\(debugSessionDisplayDescription(snapshot.display))}"
        )
#endif
        context.tabManager.restoreSessionSnapshot(snapshot.tabManager)
        context.sidebarState.isVisible = snapshot.sidebar.isVisible
        context.sidebarState.persistedWidth = CGFloat(
            SessionPersistencePolicy.sanitizedSidebarWidth(snapshot.sidebar.width)
        )
        context.sidebarSelectionState.selection = snapshot.sidebar.selection.sidebarSelection

        if let restoredFrame = resolvedWindowFrame(from: snapshot), let window {
            window.setFrame(restoredFrame, display: true)
#if DEBUG
            dlog(
                "session.restore.frameApplied window=\(context.windowId.uuidString.prefix(8)) " +
                    "applied={\(debugNSRectDescription(window.frame))}"
            )
#endif
        }
    }

    private func resolvedWindowFrame(from snapshot: SessionWindowSnapshot?) -> NSRect? {
        let displays = currentDisplayGeometries()
        return Self.resolvedWindowFrame(
            from: snapshot?.frame,
            display: snapshot?.display,
            availableDisplays: displays.available,
            fallbackDisplay: displays.fallback
        )
    }

    nonisolated static func resolvedStartupPrimaryWindowFrame(
        primarySnapshot: SessionWindowSnapshot?,
        fallbackFrame: SessionRectSnapshot?,
        fallbackDisplaySnapshot: SessionDisplaySnapshot?,
        availableDisplays: [SessionDisplayGeometry],
        fallbackDisplay: SessionDisplayGeometry?
    ) -> CGRect? {
        if let primary = resolvedWindowFrame(
            from: primarySnapshot?.frame,
            display: primarySnapshot?.display,
            availableDisplays: availableDisplays,
            fallbackDisplay: fallbackDisplay
        ) {
            return primary
        }

        return resolvedWindowFrame(
            from: fallbackFrame,
            display: fallbackDisplaySnapshot,
            availableDisplays: availableDisplays,
            fallbackDisplay: fallbackDisplay
        )
    }

    nonisolated static func resolvedWindowFrame(
        from frameSnapshot: SessionRectSnapshot?,
        display displaySnapshot: SessionDisplaySnapshot?,
        availableDisplays: [SessionDisplayGeometry],
        fallbackDisplay: SessionDisplayGeometry?
    ) -> CGRect? {
        guard let frameSnapshot else { return nil }
        let frame = frameSnapshot.cgRect
        guard frame.width.isFinite,
              frame.height.isFinite,
              frame.origin.x.isFinite,
              frame.origin.y.isFinite else {
            return nil
        }

        let minWidth = CGFloat(SessionPersistencePolicy.minimumWindowWidth)
        let minHeight = CGFloat(SessionPersistencePolicy.minimumWindowHeight)
        guard frame.width >= minWidth,
              frame.height >= minHeight else {
            return nil
        }

        guard !availableDisplays.isEmpty else { return frame }

        if let targetDisplay = display(for: displaySnapshot, in: availableDisplays) {
            if shouldPreserveExactFrame(
                frame: frame,
                displaySnapshot: displaySnapshot,
                targetDisplay: targetDisplay
            ) {
                return frame
            }
            return resolvedWindowFrame(
                frame: frame,
                displaySnapshot: displaySnapshot,
                targetDisplay: targetDisplay,
                minWidth: minWidth,
                minHeight: minHeight
            )
        }

        if let intersectingDisplay = availableDisplays.first(where: { $0.visibleFrame.intersects(frame) }) {
            return clampFrame(
                frame,
                within: intersectingDisplay.visibleFrame,
                minWidth: minWidth,
                minHeight: minHeight
            )
        }

        guard let fallbackDisplay else { return frame }
        if let sourceReference = displaySnapshot?.visibleFrame?.cgRect ?? displaySnapshot?.frame?.cgRect {
            return remappedFrame(
                frame,
                from: sourceReference,
                to: fallbackDisplay.visibleFrame,
                minWidth: minWidth,
                minHeight: minHeight
            )
        }

        return centeredFrame(
            frame,
            in: fallbackDisplay.visibleFrame,
            minWidth: minWidth,
            minHeight: minHeight
        )
    }

    private nonisolated static func resolvedWindowFrame(
        frame: CGRect,
        displaySnapshot: SessionDisplaySnapshot?,
        targetDisplay: SessionDisplayGeometry,
        minWidth: CGFloat,
        minHeight: CGFloat
    ) -> CGRect {
        if targetDisplay.visibleFrame.intersects(frame) {
            // Preserve the user's exact frame when enough of the top of the window
            // remains reachable on-screen; only clamp when the saved frame would
            // reopen with an inaccessible titlebar/top strip.
            if shouldPreserveAccessibleFrame(
                frame: frame,
                targetDisplay: targetDisplay
            ) {
                return frame
            }
            return clampFrame(
                frame,
                within: targetDisplay.visibleFrame,
                minWidth: minWidth,
                minHeight: minHeight
            )
        }

        if let sourceReference = displaySnapshot?.visibleFrame?.cgRect ?? displaySnapshot?.frame?.cgRect {
            return remappedFrame(
                frame,
                from: sourceReference,
                to: targetDisplay.visibleFrame,
                minWidth: minWidth,
                minHeight: minHeight
            )
        }

        return centeredFrame(
            frame,
            in: targetDisplay.visibleFrame,
            minWidth: minWidth,
            minHeight: minHeight
        )
    }

    private nonisolated static func shouldPreserveAccessibleFrame(
        frame: CGRect,
        targetDisplay: SessionDisplayGeometry,
        minimumVisibleTopStripWidth: CGFloat = 120,
        topStripHeight: CGFloat = 64,
        minimumVisibleTopStripHeight: CGFloat = 24
    ) -> Bool {
        let standardizedFrame = frame.standardized
        guard standardizedFrame.width.isFinite,
              standardizedFrame.height.isFinite,
              standardizedFrame.width > 0,
              standardizedFrame.height > 0,
              standardizedFrame.intersects(targetDisplay.frame) else {
            return false
        }

        let stripHeight = min(topStripHeight, standardizedFrame.height)
        let topStrip = CGRect(
            x: standardizedFrame.minX,
            y: standardizedFrame.maxY - stripHeight,
            width: standardizedFrame.width,
            height: stripHeight
        )
        let visibleTopStrip = topStrip.intersection(targetDisplay.visibleFrame)
        guard !visibleTopStrip.isNull else { return false }

        let requiredWidth = min(minimumVisibleTopStripWidth, standardizedFrame.width)
        let requiredHeight = min(minimumVisibleTopStripHeight, stripHeight)
        return visibleTopStrip.width >= requiredWidth
            && visibleTopStrip.height >= requiredHeight
    }

    private nonisolated static func display(
        for snapshot: SessionDisplaySnapshot?,
        in displays: [SessionDisplayGeometry]
    ) -> SessionDisplayGeometry? {
        guard let snapshot else { return nil }
        if let stableID = snapshot.stableID, !stableID.isEmpty {
            let matches = displays.filter { $0.stableID == stableID }
            if matches.count == 1 { return matches[0] }
            if matches.count > 1 { return displayMatchingSnapshotGeometry(for: snapshot, in: matches) }
        }
        if let displayID = snapshot.displayID,
           let exact = displays.first(where: { $0.displayID == displayID }) {
            return exact
        }
        return displayMatchingSnapshotGeometry(for: snapshot, in: displays)
    }

    private nonisolated static func displayMatchingSnapshotGeometry(
        for snapshot: SessionDisplaySnapshot,
        in displays: [SessionDisplayGeometry]
    ) -> SessionDisplayGeometry? {
        guard let referenceRect = (snapshot.visibleFrame ?? snapshot.frame)?.cgRect else {
            return nil
        }

        let overlaps = displays.map { display -> (display: SessionDisplayGeometry, area: CGFloat) in
            (display, intersectionArea(referenceRect, display.visibleFrame))
        }
        if let bestOverlap = overlaps.max(by: { $0.area < $1.area }), bestOverlap.area > 0 {
            return bestOverlap.display
        }

        let referenceCenter = CGPoint(x: referenceRect.midX, y: referenceRect.midY)
        return displays.min { lhs, rhs in
            let lhsDistance = distanceSquared(lhs.visibleFrame, referenceCenter)
            let rhsDistance = distanceSquared(rhs.visibleFrame, referenceCenter)
            return lhsDistance < rhsDistance
        }
    }

    private nonisolated static func remappedFrame(
        _ frame: CGRect,
        from sourceRect: CGRect,
        to targetRect: CGRect,
        minWidth: CGFloat,
        minHeight: CGFloat
    ) -> CGRect {
        let source = sourceRect.standardized
        let target = targetRect.standardized
        guard source.width.isFinite,
              source.height.isFinite,
              source.width > 1,
              source.height > 1,
              target.width.isFinite,
              target.height.isFinite,
              target.width > 0,
              target.height > 0 else {
            return centeredFrame(frame, in: targetRect, minWidth: minWidth, minHeight: minHeight)
        }

        let relativeX = (frame.minX - source.minX) / source.width
        let relativeY = (frame.minY - source.minY) / source.height
        let relativeWidth = frame.width / source.width
        let relativeHeight = frame.height / source.height

        let remapped = CGRect(
            x: target.minX + (relativeX * target.width),
            y: target.minY + (relativeY * target.height),
            width: target.width * relativeWidth,
            height: target.height * relativeHeight
        )
        return clampFrame(remapped, within: target, minWidth: minWidth, minHeight: minHeight)
    }

    private nonisolated static func centeredFrame(
        _ frame: CGRect,
        in visibleFrame: CGRect,
        minWidth: CGFloat,
        minHeight: CGFloat
    ) -> CGRect {
        let centered = CGRect(
            x: visibleFrame.midX - (frame.width / 2),
            y: visibleFrame.midY - (frame.height / 2),
            width: frame.width,
            height: frame.height
        )
        return clampFrame(centered, within: visibleFrame, minWidth: minWidth, minHeight: minHeight)
    }

    private nonisolated static func clampFrame(
        _ frame: CGRect,
        within visibleFrame: CGRect,
        minWidth: CGFloat,
        minHeight: CGFloat
    ) -> CGRect {
        guard visibleFrame.width.isFinite,
              visibleFrame.height.isFinite,
              visibleFrame.width > 0,
              visibleFrame.height > 0 else {
            return frame
        }

        let maxWidth = max(visibleFrame.width, 1)
        let maxHeight = max(visibleFrame.height, 1)
        let widthFloor = min(minWidth, maxWidth)
        let heightFloor = min(minHeight, maxHeight)

        let width = min(max(frame.width, widthFloor), maxWidth)
        let height = min(max(frame.height, heightFloor), maxHeight)
        let maxX = visibleFrame.maxX - width
        let maxY = visibleFrame.maxY - height
        let x = min(max(frame.minX, visibleFrame.minX), maxX)
        let y = min(max(frame.minY, visibleFrame.minY), maxY)

        return CGRect(x: x, y: y, width: width, height: height)
    }

    private nonisolated static func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        return max(0, intersection.width) * max(0, intersection.height)
    }

    private nonisolated static func distanceSquared(_ rect: CGRect, _ point: CGPoint) -> CGFloat {
        let dx = rect.midX - point.x
        let dy = rect.midY - point.y
        return (dx * dx) + (dy * dy)
    }

    private nonisolated static func shouldPreserveExactFrame(
        frame: CGRect,
        displaySnapshot: SessionDisplaySnapshot?,
        targetDisplay: SessionDisplayGeometry
    ) -> Bool {
        guard let displaySnapshot else { return false }
        if let stableID = displaySnapshot.stableID, !stableID.isEmpty {
            guard targetDisplay.stableID == stableID else { return false }
        } else {
            guard let snapshotDisplayID = displaySnapshot.displayID,
                  let targetDisplayID = targetDisplay.displayID,
                  snapshotDisplayID == targetDisplayID else {
                return false
            }
        }

        let visibleMatches = displaySnapshot.visibleFrame.map {
            rectApproximatelyEqual($0.cgRect, targetDisplay.visibleFrame)
        } ?? false
        let frameMatches = displaySnapshot.frame.map {
            rectApproximatelyEqual($0.cgRect, targetDisplay.frame)
        } ?? false
        guard visibleMatches || frameMatches else { return false }

        return frame.width.isFinite
            && frame.height.isFinite
            && frame.origin.x.isFinite
            && frame.origin.y.isFinite
    }

    private nonisolated static func rectApproximatelyEqual(
        _ lhs: CGRect,
        _ rhs: CGRect,
        tolerance: CGFloat = 1
    ) -> Bool {
        let lhsStd = lhs.standardized
        let rhsStd = rhs.standardized
        return abs(lhsStd.origin.x - rhsStd.origin.x) <= tolerance
            && abs(lhsStd.origin.y - rhsStd.origin.y) <= tolerance
            && abs(lhsStd.size.width - rhsStd.size.width) <= tolerance
            && abs(lhsStd.size.height - rhsStd.size.height) <= tolerance
    }

    func displaySnapshot(for window: NSWindow?) -> SessionDisplaySnapshot? {
        guard let window else { return nil }
        let screen = window.screen
            ?? NSScreen.screens.first(where: { $0.frame.intersects(window.frame) })
        guard let screen else { return nil }

        return SessionDisplaySnapshot(
            displayID: screen.programaDisplayID,
            stableID: screen.programaStableDisplayID,
            frame: SessionRectSnapshot(screen.frame),
            visibleFrame: SessionRectSnapshot(screen.visibleFrame)
        )
    }

    private func installLifecycleSnapshotObserversIfNeeded() {
        guard appLifecycleCoordinator.claimSnapshotObserverInstallation() else { return }

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let powerOffObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.appLifecycleCoordinator.beginPowerOff()
                SessionMachineryGate.isApplicationTerminating = true
                // `willPowerOff` can still be cancelled. Only applicationWillTerminate may
                // label a snapshot as a clean shutdown.
                self.saveSessionSnapshot(includeScrollback: true, removeWhenEmpty: false)
            }
        }
        lifecycleSnapshotObservers.append(powerOffObserver)

        let sessionResignObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.isTerminatingApp {
                    self.saveSessionSnapshot(includeScrollback: true, removeWhenEmpty: false)
                } else {
                    self.saveSessionSnapshot(includeScrollback: false)
                }
            }
        }
        lifecycleSnapshotObservers.append(sessionResignObserver)

        let willSleepObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { _ in
            dilog("wake.lifecycle", "willSleep")
        }
        lifecycleSnapshotObservers.append(willSleepObserver)

        let didWakeObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleSystemDidWake()
            }
        }
        lifecycleSnapshotObservers.append(didWakeObserver)
    }

    /// Runs everything that must be re-asserted after the Mac wakes from sleep.
    /// See `SessionEscrow.swift`'s `serve` death-detection loop for the
    /// confirmed root cause this responds to: the escrow holder used to
    /// measure heartbeat staleness with wall-clock time, so any sleep longer
    /// than `SessionEscrowPolicy.heartbeatStaleAfter` (6s) made it declare
    /// every escrowed PTY dead the instant the app woke back up and start
    /// reading from them concurrently with the still-alive app, corrupting
    /// terminal output until the app was force-quit. That's fixed at the
    /// source (mach-uptime-based staleness, which pauses across sleep), but
    /// this handler still proactively refreshes the escrow connection and
    /// renderer state on every wake as defense in depth and to leave a
    /// record in the always-on diagnostics log if it ever happens again.
    private func handleSystemDidWake() {
        dilog("wake.lifecycle", "didWake")
        restartSocketListenerIfEnabled(source: "workspace.didWake")
        SessionEscrowClient.shared.notifySystemDidWake()
        RendererRealizationController.shared.scheduleImmediatePass()
    }

    func socketListenerConfigurationIfEnabled() -> (mode: SocketControlMode, path: String)? {
        let raw = UserDefaults.standard.string(forKey: SocketControlSettings.appStorageKey)
            ?? SocketControlSettings.defaultMode.rawValue
        let userMode = SocketControlSettings.migrateMode(raw)
        let mode = SocketControlSettings.effectiveMode(userMode: userMode)
        guard mode != .off else { return nil }
        return (mode: mode, path: SocketControlSettings.socketPath())
    }

    func restartSocketListenerIfEnabled(source: String) {
        guard let tabManager,
              let config = socketListenerConfigurationIfEnabled() else { return }
        let restartPath = TerminalController.shared.activeSocketPath(preferredPath: config.path)
        TerminalController.shared.stop()
        TerminalController.shared.start(tabManager: tabManager, socketPath: restartPath, accessMode: config.mode)
    }

    private func disableSuddenTerminationIfNeeded() {
        guard appLifecycleCoordinator.claimSuddenTerminationDisable() else { return }
        ProcessInfo.processInfo.disableSuddenTermination()
    }

    private func enableSuddenTerminationIfNeeded() {
        guard appLifecycleCoordinator.claimSuddenTerminationEnable() else { return }
        ProcessInfo.processInfo.enableSuddenTermination()
    }

    // Session snapshot build/save/persist machinery lives in
    // `AppDelegate+SessionSnapshotPersistence.swift`.

#if DEBUG
    func debugSessionRectDescription(_ rect: SessionRectSnapshot?) -> String {
        guard let rect else { return "nil" }
        return "x=\(debugSessionNumber(rect.x)) y=\(debugSessionNumber(rect.y)) " +
            "w=\(debugSessionNumber(rect.width)) h=\(debugSessionNumber(rect.height))"
    }

    private func debugNSRectDescription(_ rect: NSRect?) -> String {
        guard let rect else { return "nil" }
        return "x=\(debugSessionNumber(Double(rect.origin.x))) " +
            "y=\(debugSessionNumber(Double(rect.origin.y))) " +
            "w=\(debugSessionNumber(Double(rect.size.width))) " +
            "h=\(debugSessionNumber(Double(rect.size.height)))"
    }

    func debugSessionDisplayDescription(_ display: SessionDisplaySnapshot?) -> String {
        guard let display else { return "nil" }
        let displayIdText = display.displayID.map(String.init) ?? "nil"
        return "id=\(displayIdText) " +
            "frame={\(debugSessionRectDescription(display.frame))} " +
            "visible={\(debugSessionRectDescription(display.visibleFrame))}"
    }

    func debugSessionNumber(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
#endif

    private func notifyMainWindowContextsDidChange() {
        NotificationCenter.default.post(name: .mainWindowContextsDidChange, object: self)
    }

    private func removeMainWindowCloseObserver(from context: MainWindowContext) {
        if let observer = context.willCloseObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        context.willCloseObserver = nil
        context.willCloseObserverGeneration = nil
        context.observedWindow = nil
    }

    private func installMainWindowCloseObserver(
        for context: MainWindowContext,
        window: NSWindow
    ) {
        if context.observedWindow === window, context.willCloseObserver != nil {
            return
        }

        removeMainWindowCloseObserver(from: context)
        let generation = UUID()
        context.observedWindow = window
        context.willCloseObserverGeneration = generation
        context.willCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self, weak window, generation] note in
            MainActor.assumeIsolated {
                guard let self,
                      let window,
                      let closing = note.object as? NSWindow,
                      closing === window,
                      let context = self.mainWindowContexts[ObjectIdentifier(window)],
                      context.willCloseObserverGeneration == generation,
                      context.observedWindow === window,
                      context.window === window else {
                    return
                }
                self.unregisterMainWindow(window)
            }
        }
    }

    /// Register a terminal window with the AppDelegate so menu commands and socket control
    /// can target whichever window is currently active.
    func registerMainWindow(
        _ window: NSWindow,
        windowId: UUID,
        tabManager: TabManager,
        sidebarState: SidebarState,
        sidebarSelectionState: SidebarSelectionState
    ) {
        // A window can be deallocated without ever going through the normal
        // close/NSWindow.willCloseNotification teardown path (e.g. released directly
        // by its owner). That leaves its MainWindowContext behind indefinitely, since
        // nothing else proactively sweeps for dead-window contexts. Registering a new
        // main window is a natural, frequent checkpoint to clean those up so they don't
        // linger and skew context-selection/fallback logic for the lifetime of the app.
        discardOrphanedMainWindowContexts()

        tabManager.window = window

        let key = ObjectIdentifier(window)
        #if DEBUG
        let priorManagerToken = debugManagerToken(self.tabManager)
        #endif
        let context: MainWindowContext
        if let existing = mainWindowContexts[key], existing.windowId == windowId {
            existing.window = window
            context = existing
        } else if let existing = mainWindowContexts.values.first(where: { $0.windowId == windowId }) {
            reindexMainWindowContextIfNeeded(existing, for: window)
            context = existing
        } else {
            if let displaced = mainWindowContexts[key] {
                discardOrphanedMainWindowContext(displaced)
            }
            let newContext = MainWindowContext(
                windowId: windowId,
                tabManager: tabManager,
                sidebarState: sidebarState,
                sidebarSelectionState: sidebarSelectionState,
                window: window
            )
            mainWindowContexts[key] = newContext
            context = newContext
        }
        installMainWindowCloseObserver(for: context, window: window)
        if startupHandoff.shouldDefer() && startupHandoffPrimaryWindowId == nil {
            startupHandoffPrimaryWindowId = windowId
        }
        CommandPaletteController.windowLifecycle.reset(windowId: windowId)

#if DEBUG
        dlog(
            "mainWindow.register windowId=\(String(windowId.uuidString.prefix(8))) window={\(debugWindowToken(window))} manager=\(debugManagerToken(tabManager)) priorActiveMgr=\(priorManagerToken) \(debugShortcutRouteSnapshot())"
        )
#endif
        notifyMainWindowContextsDidChange()
        if window.isKeyWindow {
            setActiveMainWindow(window)
        }

        attemptStartupSessionRestoreIfNeeded(primaryWindow: window)
        if !isTerminatingApp {
            saveSessionSnapshot(includeScrollback: false)
        }
    }

    struct MainWindowSummary {
        let windowId: UUID
        let isKeyWindow: Bool
        let isVisible: Bool
        let workspaceCount: Int
        let selectedWorkspaceId: UUID?
    }

    struct WindowMoveTarget: Identifiable {
        let windowId: UUID
        let label: String
        let tabManager: TabManager
        let isCurrentWindow: Bool

        var id: UUID { windowId }
    }

    struct WorkspaceMoveTarget: Identifiable {
        let windowId: UUID
        let workspaceId: UUID
        let windowLabel: String
        let workspaceTitle: String
        let tabManager: TabManager
        let isCurrentWindow: Bool

        var id: String { "\(windowId.uuidString):\(workspaceId.uuidString)" }
        var label: String {
            isCurrentWindow ? workspaceTitle : "\(workspaceTitle) (\(windowLabel))"
        }
    }

    func listMainWindowSummaries() -> [MainWindowSummary] {
        let contexts = Array(mainWindowContexts.values)
        return contexts.map { ctx in
            let window = ctx.window ?? windowForMainWindowId(ctx.windowId)
            return MainWindowSummary(
                windowId: ctx.windowId,
                isKeyWindow: window?.isKeyWindow ?? false,
                isVisible: window?.isVisible ?? false,
                workspaceCount: ctx.tabManager.tabs.count,
                selectedWorkspaceId: ctx.tabManager.selectedTabId
            )
        }
    }

    func windowMoveTargets(referenceWindowId: UUID?) -> [WindowMoveTarget] {
        let orderedSummaries = orderedMainWindowSummaries(referenceWindowId: referenceWindowId)
        let labels = windowLabelsById(orderedSummaries: orderedSummaries, referenceWindowId: referenceWindowId)
        return orderedSummaries.compactMap { summary in
            guard let manager = tabManagerFor(windowId: summary.windowId) else { return nil }
            let label = labels[summary.windowId] ?? "Window"
            return WindowMoveTarget(
                windowId: summary.windowId,
                label: label,
                tabManager: manager,
                isCurrentWindow: summary.windowId == referenceWindowId
            )
        }
    }

    func workspaceMoveTargets(excludingWorkspaceId: UUID? = nil, referenceWindowId: UUID?) -> [WorkspaceMoveTarget] {
        let orderedSummaries = orderedMainWindowSummaries(referenceWindowId: referenceWindowId)
        let labels = windowLabelsById(orderedSummaries: orderedSummaries, referenceWindowId: referenceWindowId)

        var targets: [WorkspaceMoveTarget] = []
        targets.reserveCapacity(orderedSummaries.reduce(0) { partial, summary in
            partial + summary.workspaceCount
        })

        for summary in orderedSummaries {
            guard let manager = tabManagerFor(windowId: summary.windowId) else { continue }
            let windowLabel = labels[summary.windowId] ?? "Window"
            let isCurrentWindow = summary.windowId == referenceWindowId
            for workspace in manager.tabs {
                if workspace.id == excludingWorkspaceId {
                    continue
                }
                targets.append(
                    WorkspaceMoveTarget(
                        windowId: summary.windowId,
                        workspaceId: workspace.id,
                        windowLabel: windowLabel,
                        workspaceTitle: workspaceDisplayName(workspace),
                        tabManager: manager,
                        isCurrentWindow: isCurrentWindow
                    )
                )
            }
        }

        return targets
    }

    @discardableResult
    func moveWorkspaceToWindow(workspaceId: UUID, windowId: UUID, focus: Bool = true) -> Bool {
        guard let sourceManager = tabManagerFor(tabId: workspaceId),
              let destinationManager = tabManagerFor(windowId: windowId) else {
            return false
        }

        if sourceManager === destinationManager {
            if focus {
                destinationManager.focusTab(workspaceId, suppressFlash: true)
                _ = focusMainWindow(windowId: windowId)
                TerminalController.shared.setActiveTabManager(destinationManager)
            }
            return true
        }

        guard let workspace = sourceManager.detachWorkspace(tabId: workspaceId) else { return false }
        destinationManager.attachWorkspace(workspace, select: focus)

        if focus {
            _ = focusMainWindow(windowId: windowId)
            TerminalController.shared.setActiveTabManager(destinationManager)
        }
        return true
    }

    @discardableResult
    func moveWorkspaceToNewWindow(workspaceId: UUID, focus: Bool = true) -> UUID? {
        let windowId = createMainWindow()
        guard let destinationManager = tabManagerFor(windowId: windowId) else { return nil }
        let bootstrapWorkspaceId = destinationManager.tabs.first?.id

        guard moveWorkspaceToWindow(workspaceId: workspaceId, windowId: windowId, focus: focus) else {
            _ = closeMainWindow(windowId: windowId)
            return nil
        }

        // Remove the bootstrap workspace from the new window once the moved workspace arrives.
        if let bootstrapWorkspaceId,
           bootstrapWorkspaceId != workspaceId,
           let bootstrapWorkspace = destinationManager.tabs.first(where: { $0.id == bootstrapWorkspaceId }),
           destinationManager.tabs.count > 1 {
            destinationManager.closeWorkspace(bootstrapWorkspace)
        }
        return windowId
    }

    func locateBonsplitSurface(tabId: UUID) -> (windowId: UUID, workspaceId: UUID, panelId: UUID, tabManager: TabManager)? {
        let bonsplitTabId = TabID(uuid: tabId)
        for context in mainWindowContexts.values {
            for workspace in context.tabManager.tabs {
                if let panelId = workspace.panelIdFromSurfaceId(bonsplitTabId) {
                    return (context.windowId, workspace.id, panelId, context.tabManager)
                }
            }
        }
        return nil
    }

    @discardableResult
    func moveSurface(
        panelId: UUID,
        toWorkspace targetWorkspaceId: UUID,
        targetPane: PaneID? = nil,
        targetIndex: Int? = nil,
        splitTarget: (orientation: SplitOrientation, insertFirst: Bool)? = nil,
        focus: Bool = true,
        focusWindow: Bool = true
    ) -> Bool {
#if DEBUG
        let moveStart = ProcessInfo.processInfo.systemUptime
        let splitLabel = splitTarget.map { split in
            "\(split.orientation.rawValue):\(split.insertFirst ? 1 : 0)"
        } ?? "none"
        func elapsedMs(since start: TimeInterval) -> String {
            let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
            return String(format: "%.2f", ms)
        }
        dlog(
            "surface.move.begin panel=\(panelId.uuidString.prefix(5)) targetWs=\(targetWorkspaceId.uuidString.prefix(5)) " +
            "targetPane=\(targetPane?.id.uuidString.prefix(5) ?? "auto") targetIndex=\(targetIndex.map(String.init) ?? "nil") " +
            "split=\(splitLabel) focus=\(focus ? 1 : 0) focusWindow=\(focusWindow ? 1 : 0)"
        )
#endif
        guard let source = locateSurface(surfaceId: panelId) else {
#if DEBUG
            dlog("surface.move.fail panel=\(panelId.uuidString.prefix(5)) reason=sourcePanelNotFound elapsedMs=\(elapsedMs(since: moveStart))")
#endif
            return false
        }
        guard let sourceWorkspace = source.tabManager.tabs.first(where: { $0.id == source.workspaceId }) else {
#if DEBUG
            dlog("surface.move.fail panel=\(panelId.uuidString.prefix(5)) reason=sourceWorkspaceMissing elapsedMs=\(elapsedMs(since: moveStart))")
#endif
            return false
        }
        guard let destinationManager = tabManagerFor(tabId: targetWorkspaceId) else {
#if DEBUG
            dlog("surface.move.fail panel=\(panelId.uuidString.prefix(5)) reason=destinationManagerMissing elapsedMs=\(elapsedMs(since: moveStart))")
#endif
            return false
        }
        guard let destinationWorkspace = destinationManager.tabs.first(where: { $0.id == targetWorkspaceId }) else {
#if DEBUG
            dlog("surface.move.fail panel=\(panelId.uuidString.prefix(5)) reason=destinationWorkspaceMissing elapsedMs=\(elapsedMs(since: moveStart))")
#endif
            return false
        }
#if DEBUG
        dlog(
            "surface.move.route panel=\(panelId.uuidString.prefix(5)) sourceWs=\(sourceWorkspace.id.uuidString.prefix(5)) " +
            "sourceWin=\(source.windowId.uuidString.prefix(5)) destinationWs=\(destinationWorkspace.id.uuidString.prefix(5)) " +
            "sameWorkspace=\(destinationWorkspace.id == sourceWorkspace.id ? 1 : 0)"
        )
#endif

        let resolvedTargetPane = targetPane.flatMap { pane in
            destinationWorkspace.bonsplitController.allPaneIds.first(where: { $0 == pane })
        } ?? destinationWorkspace.bonsplitController.focusedPaneId
            ?? destinationWorkspace.bonsplitController.allPaneIds.first

        guard let resolvedTargetPane else {
#if DEBUG
            dlog(
                "surface.move.fail panel=\(panelId.uuidString.prefix(5)) reason=targetPaneMissing " +
                "destinationWs=\(destinationWorkspace.id.uuidString.prefix(5)) elapsedMs=\(elapsedMs(since: moveStart))"
            )
#endif
            return false
        }

        if destinationWorkspace.id == sourceWorkspace.id {
            if let splitTarget {
                guard let sourceTabId = sourceWorkspace.surfaceIdFromPanelId(panelId),
                      sourceWorkspace.bonsplitController.splitPane(
                        resolvedTargetPane,
                        orientation: splitTarget.orientation,
                        movingTab: sourceTabId,
                        insertFirst: splitTarget.insertFirst
                      ) != nil else {
#if DEBUG
                    dlog(
                        "surface.move.fail panel=\(panelId.uuidString.prefix(5)) reason=sameWorkspaceSplitFailed " +
                        "targetPane=\(resolvedTargetPane.id.uuidString.prefix(5)) split=\(splitLabel) " +
                        "elapsedMs=\(elapsedMs(since: moveStart))"
                    )
#endif
                    return false
                }
                if focus {
                    source.tabManager.focusTab(sourceWorkspace.id, surfaceId: panelId, suppressFlash: true)
                }
#if DEBUG
                dlog(
                    "surface.move.end panel=\(panelId.uuidString.prefix(5)) path=sameWorkspaceSplit moved=1 " +
                    "targetPane=\(resolvedTargetPane.id.uuidString.prefix(5)) elapsedMs=\(elapsedMs(since: moveStart))"
                )
#endif
                return true
            }

            let moved = sourceWorkspace.moveSurface(
                panelId: panelId,
                toPane: resolvedTargetPane,
                atIndex: targetIndex,
                focus: focus
            )
#if DEBUG
            dlog(
                "surface.move.end panel=\(panelId.uuidString.prefix(5)) path=sameWorkspaceMove moved=\(moved ? 1 : 0) " +
                "targetPane=\(resolvedTargetPane.id.uuidString.prefix(5)) targetIndex=\(targetIndex.map(String.init) ?? "nil") " +
                "elapsedMs=\(elapsedMs(since: moveStart))"
            )
#endif
            return moved
        }

        let sourcePane = sourceWorkspace.paneId(forPanelId: panelId)
        let sourceIndex = sourceWorkspace.indexInPane(forPanelId: panelId)
#if DEBUG
        let detachStart = ProcessInfo.processInfo.systemUptime
#endif

        guard let detached = sourceWorkspace.detachSurface(panelId: panelId) else {
#if DEBUG
            dlog(
                "surface.move.fail panel=\(panelId.uuidString.prefix(5)) reason=detachFailed " +
                "elapsedMs=\(elapsedMs(since: moveStart))"
            )
#endif
            return false
        }
#if DEBUG
        let detachMs = elapsedMs(since: detachStart)
        let attachStart = ProcessInfo.processInfo.systemUptime
#endif
        let rollbackTarget = detachedSurfaceAttachmentTarget(
            workspace: sourceWorkspace,
            pane: sourcePane,
            index: sourceIndex,
            focus: focus
        )
        let attachmentResult = detached.resolve(
            primary: Workspace.DetachedSurfaceAttachmentTarget(
                workspace: destinationWorkspace,
                paneId: resolvedTargetPane,
                index: targetIndex,
                focus: focus
            ),
            rollback: rollbackTarget
        )
        guard case .attachedPrimary = attachmentResult else {
#if DEBUG
            dlog(
                "surface.move.fail panel=\(panelId.uuidString.prefix(5)) reason=attachFailed " +
                "detachMs=\(detachMs) elapsedMs=\(elapsedMs(since: moveStart))"
            )
#endif
            return false
        }
#if DEBUG
        let attachMs = elapsedMs(since: attachStart)
        var splitMs = "0.00"
#endif

        if let splitTarget {
#if DEBUG
            let splitStart = ProcessInfo.processInfo.systemUptime
#endif
            guard let movedTabId = destinationWorkspace.surfaceIdFromPanelId(panelId),
                  destinationWorkspace.bonsplitController.splitPane(
                    resolvedTargetPane,
                    orientation: splitTarget.orientation,
                    movingTab: movedTabId,
                    insertFirst: splitTarget.insertFirst
                ) != nil else {
                if let detachedFromDestination = destinationWorkspace.detachSurface(panelId: panelId) {
                    if let sourceTarget = detachedSurfaceAttachmentTarget(
                        workspace: sourceWorkspace,
                        pane: sourcePane,
                        index: sourceIndex,
                        focus: focus
                    ) {
                        _ = detachedFromDestination.resolve(primary: sourceTarget, rollback: nil)
                    } else {
                        detachedFromDestination.finalizePermanently()
                    }
                }
#if DEBUG
                dlog(
                    "surface.move.fail panel=\(panelId.uuidString.prefix(5)) reason=postAttachSplitFailed " +
                    "detachMs=\(detachMs) attachMs=\(attachMs) elapsedMs=\(elapsedMs(since: moveStart))"
                )
#endif
                return false
            }
#if DEBUG
            splitMs = elapsedMs(since: splitStart)
#endif
        }

#if DEBUG
        let cleanupStart = ProcessInfo.processInfo.systemUptime
#endif
        cleanupEmptySourceWorkspaceAfterSurfaceMove(
            sourceWorkspace: sourceWorkspace,
            sourceManager: source.tabManager,
            sourceWindowId: source.windowId
        )
#if DEBUG
        let cleanupMs = elapsedMs(since: cleanupStart)
        let focusStart = ProcessInfo.processInfo.systemUptime
#endif

        if focus {
            let destinationWindowId = focusWindow ? windowId(for: destinationManager) : nil
            if let destinationWindowId {
                _ = focusMainWindow(windowId: destinationWindowId)
            }
            destinationManager.focusTab(targetWorkspaceId, surfaceId: panelId, suppressFlash: true)
            if let destinationWindowId {
                reassertCrossWindowSurfaceMoveFocusIfNeeded(
                    destinationWindowId: destinationWindowId,
                    sourceWindowId: source.windowId,
                    destinationWorkspaceId: targetWorkspaceId,
                    destinationPanelId: panelId,
                    destinationManager: destinationManager
                )
            }
        }
#if DEBUG
        let focusMs = elapsedMs(since: focusStart)
        dlog(
            "surface.move.end panel=\(panelId.uuidString.prefix(5)) path=crossWorkspace moved=1 " +
            "sourceWs=\(sourceWorkspace.id.uuidString.prefix(5)) destinationWs=\(destinationWorkspace.id.uuidString.prefix(5)) " +
            "targetPane=\(resolvedTargetPane.id.uuidString.prefix(5)) targetIndex=\(targetIndex.map(String.init) ?? "nil") " +
            "split=\(splitLabel) detachMs=\(detachMs) attachMs=\(attachMs) splitMs=\(splitMs) " +
            "cleanupMs=\(cleanupMs) focusMs=\(focusMs) elapsedMs=\(elapsedMs(since: moveStart))"
        )
#endif

        return true
    }

    @discardableResult
    func moveBonsplitTab(
        tabId: UUID,
        toWorkspace targetWorkspaceId: UUID,
        targetPane: PaneID? = nil,
        targetIndex: Int? = nil,
        splitTarget: (orientation: SplitOrientation, insertFirst: Bool)? = nil,
        focus: Bool = true,
        focusWindow: Bool = true
    ) -> Bool {
#if DEBUG
        let moveStart = ProcessInfo.processInfo.systemUptime
        func elapsedMs(since start: TimeInterval) -> String {
            let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
            return String(format: "%.2f", ms)
        }
        dlog(
            "surface.moveBonsplit.begin tab=\(tabId.uuidString.prefix(5)) targetWs=\(targetWorkspaceId.uuidString.prefix(5)) " +
            "targetPane=\(targetPane?.id.uuidString.prefix(5) ?? "auto") targetIndex=\(targetIndex.map(String.init) ?? "nil")"
        )
#endif
        guard let located = locateBonsplitSurface(tabId: tabId) else {
#if DEBUG
            dlog(
                "surface.moveBonsplit.fail tab=\(tabId.uuidString.prefix(5)) reason=tabNotFound " +
                "targetWs=\(targetWorkspaceId.uuidString.prefix(5)) elapsedMs=\(elapsedMs(since: moveStart))"
            )
#endif
            return false
        }
#if DEBUG
        dlog(
            "surface.moveBonsplit.located tab=\(tabId.uuidString.prefix(5)) panel=\(located.panelId.uuidString.prefix(5)) " +
            "sourceWs=\(located.workspaceId.uuidString.prefix(5)) sourceWin=\(located.windowId.uuidString.prefix(5))"
        )
#endif
        let moved = moveSurface(
            panelId: located.panelId,
            toWorkspace: targetWorkspaceId,
            targetPane: targetPane,
            targetIndex: targetIndex,
            splitTarget: splitTarget,
            focus: focus,
            focusWindow: focusWindow
        )
#if DEBUG
        dlog(
            "surface.moveBonsplit.end tab=\(tabId.uuidString.prefix(5)) panel=\(located.panelId.uuidString.prefix(5)) " +
            "moved=\(moved ? 1 : 0) elapsedMs=\(elapsedMs(since: moveStart))"
        )
#endif
        return moved
    }

    func tabManagerFor(windowId: UUID) -> TabManager? {
        mainWindowContexts.values.first(where: { $0.windowId == windowId })?.tabManager
    }

    func windowId(for tabManager: TabManager) -> UUID? {
        mainWindowContexts.values.first(where: { $0.tabManager === tabManager })?.windowId
    }

    func mainWindow(for windowId: UUID) -> NSWindow? {
        windowForMainWindowId(windowId)
    }

    func mainWindowContainingWorkspace(_ workspaceId: UUID) -> NSWindow? {
        for context in mainWindowContexts.values where context.tabManager.tabs.contains(where: { $0.id == workspaceId }) {
            if let window = context.window ?? windowForMainWindowId(context.windowId) {
                return window
            }
        }
        return nil
    }

    func scriptableMainWindows() -> [ScriptableMainWindowState] {
        var results: [ScriptableMainWindowState] = []
        var seen: Set<UUID> = []

        for window in NSApp.orderedWindows {
            guard let context = contextForMainTerminalWindow(window, reindex: false) else { continue }
            guard seen.insert(context.windowId).inserted else { continue }
            results.append(
                ScriptableMainWindowState(
                    windowId: context.windowId,
                    tabManager: context.tabManager,
                    window: context.window ?? windowForMainWindowId(context.windowId)
                )
            )
        }

        let remaining = mainWindowContexts.values
            .sorted { $0.windowId.uuidString < $1.windowId.uuidString }
            .filter { seen.insert($0.windowId).inserted }

        for context in remaining {
            results.append(
                ScriptableMainWindowState(
                    windowId: context.windowId,
                    tabManager: context.tabManager,
                    window: context.window ?? windowForMainWindowId(context.windowId)
                )
            )
        }

        return results
    }

    func scriptableMainWindow(windowId: UUID) -> ScriptableMainWindowState? {
        guard let context = mainWindowContexts.values.first(where: { $0.windowId == windowId }) else {
            return nil
        }
        return ScriptableMainWindowState(
            windowId: context.windowId,
            tabManager: context.tabManager,
            window: context.window ?? windowForMainWindowId(context.windowId)
        )
    }

    func scriptableMainWindowForTab(_ tabId: UUID) -> ScriptableMainWindowState? {
        guard let context = contextContainingTabId(tabId) else { return nil }
        return ScriptableMainWindowState(
            windowId: context.windowId,
            tabManager: context.tabManager,
            window: context.window ?? windowForMainWindowId(context.windowId)
        )
    }

    @discardableResult
    func focusScriptableMainWindow(windowId: UUID, bringToFront shouldBringToFront: Bool) -> Bool {
        guard let state = scriptableMainWindow(windowId: windowId),
              let window = state.window else {
            return false
        }
        setActiveMainWindow(window)
        if shouldBringToFront {
            bringToFront(window)
        }
        return true
    }

    @discardableResult
    func addWorkspace(windowId: UUID, workingDirectory: String? = nil, bringToFront shouldBringToFront: Bool = false) -> UUID? {
        guard let state = scriptableMainWindow(windowId: windowId) else { return nil }
        if shouldBringToFront, let window = state.window {
            setActiveMainWindow(window)
            bringToFront(window)
        }
        let workspace = state.tabManager.addWorkspace(
            workingDirectory: workingDirectory,
            select: shouldBringToFront
        )
        return workspace.id
    }

    private func teardownCommandPaletteState(for windowId: UUID) {
        CommandPaletteController.windowLifecycle.teardown(windowId: windowId)
    }

    private func markCommandPaletteOpenRequested(for window: NSWindow?) {
        guard let window,
              let windowId = mainWindowId(for: window) else { return }
        CommandPaletteController.windowLifecycle.markOpenRequested(
            windowId: windowId,
            now: ProcessInfo.processInfo.systemUptime
        )
    }

    private func postCommandPaletteRequest(
        name: Notification.Name,
        preferredWindow: NSWindow?,
        source: String,
        markPending: Bool
    ) {
        let targetWindow = preferredWindow ?? NSApp.keyWindow ?? NSApp.mainWindow
        if markPending {
            markCommandPaletteOpenRequested(for: targetWindow)
        }
        NotificationCenter.default.post(name: name, object: targetWindow)
#if DEBUG
        dlog(
            "shortcut.palette.request source=\(source) " +
            "target={\(debugWindowToken(targetWindow))} " +
            "pendingMarked=\(markPending ? 1 : 0)"
        )
#endif
    }

    func requestCommandPaletteCommands(preferredWindow: NSWindow? = nil, source: String = "api.commandPalette") {
        postCommandPaletteRequest(
            name: .commandPaletteRequested,
            preferredWindow: preferredWindow,
            source: source,
            markPending: true
        )
    }

    func requestCommandPaletteSwitcher(preferredWindow: NSWindow? = nil, source: String = "api.commandPaletteSwitcher") {
        postCommandPaletteRequest(
            name: .commandPaletteSwitcherRequested,
            preferredWindow: preferredWindow,
            source: source,
            markPending: true
        )
    }

    func requestCommandPaletteRenameTab(preferredWindow: NSWindow? = nil, source: String = "api.commandPaletteRenameTab") {
        postCommandPaletteRequest(
            name: .commandPaletteRenameTabRequested,
            preferredWindow: preferredWindow,
            source: source,
            markPending: true
        )
    }

    func requestCommandPaletteRenameWorkspace(
        preferredWindow: NSWindow? = nil,
        source: String = "api.commandPaletteRenameWorkspace"
    ) {
        postCommandPaletteRequest(
            name: .commandPaletteRenameWorkspaceRequested,
            preferredWindow: preferredWindow,
            source: source,
            markPending: true
        )
    }

    func requestCommandPaletteEditWorkspaceDescription(
        preferredWindow: NSWindow? = nil,
        source: String = "api.commandPaletteEditWorkspaceDescription"
    ) {
        postCommandPaletteRequest(
            name: .commandPaletteEditWorkspaceDescriptionRequested,
            preferredWindow: preferredWindow,
            source: source,
            markPending: true
        )
    }

    private func clearCommandPalettePendingOpen(for window: NSWindow?) {
        guard let window,
              let windowId = mainWindowId(for: window) else { return }
        CommandPaletteController.windowLifecycle.clearPendingOpen(windowId: windowId)
    }

    private func pruneExpiredCommandPalettePendingOpenStates(
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        CommandPaletteController.windowLifecycle.pruneExpiredPendingOpen(
            now: now,
            maximumAge: Self.commandPalettePendingOpenMaxAge
        )
    }

    private func isCommandPalettePendingOpen(for window: NSWindow) -> Bool {
        guard let windowId = mainWindowId(for: window) else { return false }
        return CommandPaletteController.windowLifecycle.isPendingOpen(
            windowId: windowId,
            now: ProcessInfo.processInfo.systemUptime,
            maximumAge: Self.commandPalettePendingOpenMaxAge
        )
    }

    private func beginCommandPaletteEscapeSuppression(for window: NSWindow?) {
        guard let window,
              let windowId = mainWindowId(for: window) else { return }
        CommandPaletteController.windowLifecycle.beginEscapeSuppression(
            windowId: windowId,
            now: ProcessInfo.processInfo.systemUptime
        )
    }

    private func endCommandPaletteEscapeSuppression(for window: NSWindow?) {
        guard let window,
              let windowId = mainWindowId(for: window) else { return }
        CommandPaletteController.windowLifecycle.endEscapeSuppression(windowId: windowId)
    }

    private func shouldConsumeSuppressedEscape(event: NSEvent, window: NSWindow?) -> Bool {
        guard let window, let windowId = mainWindowId(for: window) else { return false }
        return CommandPaletteController.windowLifecycle.shouldConsumeSuppressedEscape(
            windowId: windowId,
            now: ProcessInfo.processInfo.systemUptime
        )
    }

    private func recentCommandPaletteRequestAge(for window: NSWindow?) -> TimeInterval? {
        guard let window,
              let windowId = mainWindowId(for: window) else {
            return nil
        }
        return CommandPaletteController.windowLifecycle.recentRequestAge(
            windowId: windowId,
            now: ProcessInfo.processInfo.systemUptime,
            maximumAge: Self.commandPalettePendingOpenMaxAge,
            graceInterval: Self.commandPaletteRequestGraceInterval
        )
    }

    private func escapeSuppressionWindow(for event: NSEvent) -> NSWindow? {
        commandPaletteWindowForShortcutEvent(event) ?? event.window ?? NSApp.keyWindow ?? NSApp.mainWindow
    }

    @discardableResult
    private func clearEscapeSuppressionForKeyUp(event: NSEvent, consumeIfSuppressed: Bool = false) -> Bool {
        guard event.type == .keyUp, event.keyCode == 53 else { return false }
        let suppressionWindow = escapeSuppressionWindow(for: event)
        let didConsume = consumeIfSuppressed && shouldConsumeSuppressedEscape(event: event, window: suppressionWindow)
        if let window = suppressionWindow {
            endCommandPaletteEscapeSuppression(for: window)
#if DEBUG
            dlog(
                "shortcut.escape suppressionClear target={\(debugWindowToken(window))} " +
                "keyUpConsumed=\(didConsume ? 1 : 0)"
            )
#endif
            return didConsume
        }
        CommandPaletteController.windowLifecycle.clearAllEscapeSuppression()
#if DEBUG
        dlog("shortcut.escape suppressionClear target={nil} clearedAll=1 keyUpConsumed=\(didConsume ? 1 : 0)")
#endif
        return didConsume
    }

    func setCommandPaletteVisible(_ visible: Bool, for window: NSWindow) {
        guard let windowId = mainWindowId(for: window) else { return }
        let wasVisible = CommandPaletteController.windowLifecycle.setVisible(visible, windowId: windowId)
#if DEBUG
        if !visible,
           !wasVisible,
           CommandPaletteController.windowLifecycle.isPendingOpen(
               windowId: windowId,
               now: ProcessInfo.processInfo.systemUptime,
               maximumAge: Self.commandPalettePendingOpenMaxAge
           ) {
            dlog(
                "palette.visibility.retainPending " +
                "window={\(debugWindowToken(window))} visible=0 wasVisible=0 pending=1"
            )
        }
#endif
    }

    func isCommandPaletteVisible(windowId: UUID) -> Bool {
        CommandPaletteController.windowLifecycle.isVisible(windowId: windowId)
    }

    func setCommandPaletteSelectionIndex(_ index: Int, for window: NSWindow) {
        guard let windowId = mainWindowId(for: window) else { return }
        CommandPaletteController.windowLifecycle.setSelectionIndex(index, windowId: windowId)
    }

    func commandPaletteSelectionIndex(windowId: UUID) -> Int {
        CommandPaletteController.windowLifecycle.selectionIndex(windowId: windowId)
    }

    func setCommandPaletteSnapshot(_ snapshot: CommandPaletteDebugSnapshot, for window: NSWindow) {
        guard let windowId = mainWindowId(for: window) else { return }
        CommandPaletteController.windowLifecycle.setSnapshot(snapshot, windowId: windowId)
    }

    func commandPaletteSnapshot(windowId: UUID) -> CommandPaletteDebugSnapshot {
        CommandPaletteController.windowLifecycle.snapshot(windowId: windowId)
    }

    func isCommandPaletteVisible(for window: NSWindow) -> Bool {
        guard let windowId = mainWindowId(for: window) else { return false }
        return CommandPaletteController.windowLifecycle.isVisible(windowId: windowId)
    }

    func isCommandPaletteEffectivelyVisible(for window: NSWindow) -> Bool {
        isCommandPaletteEffectivelyVisible(in: window)
    }

    func shouldBlockFirstResponderChangeWhileCommandPaletteVisible(
        window: NSWindow,
        responder: NSResponder?
    ) -> Bool {
        guard isCommandPaletteVisible(for: window) else { return false }
        guard let responder else { return false }
        guard !isCommandPaletteResponder(responder) else { return false }
        return isFocusStealingResponderWhileCommandPaletteVisible(responder)
    }

    private func isCommandPaletteResponder(_ responder: NSResponder) -> Bool {
        if let textView = responder as? NSTextView, textView.isFieldEditor {
            if let delegateView = textView.delegate as? NSView {
                return isInsideCommandPaletteOverlay(delegateView)
            }
            // SwiftUI can attach a non-view delegate to TextField editors.
            // When command palette is visible, its search/rename editor is the
            // only expected field editor inside the main window.
            return true
        }
        if let view = responder as? NSView {
            return isInsideCommandPaletteOverlay(view)
        }
        return false
    }

    private func isFocusStealingResponderWhileCommandPaletteVisible(_ responder: NSResponder) -> Bool {
        isCommandPaletteFocusStealingTerminalOrBrowserResponder(responder)
    }

    private func isInsideCommandPaletteOverlay(_ view: NSView) -> Bool {
        var current: NSView? = view
        while let candidate = current {
            if candidate.identifier == commandPaletteOverlayContainerIdentifier {
                return true
            }
            current = candidate.superview
        }
        return false
    }

    private func keyRoutingOwnerView(for responder: NSResponder?) -> NSView? {
        guard let responder else { return nil }
        if let editor = responder as? NSTextView,
           editor.isFieldEditor {
            return programaFieldEditorOwnerView(editor) ?? editor
        }
        return responder as? NSView
    }

    private func responderHasViableKeyRoutingOwner(
        _ responder: NSResponder,
        in window: NSWindow
    ) -> Bool {
        if let ghosttyView = cmuxOwningGhosttyView(for: responder) {
            if ghosttyView.window !== window {
                return false
            }
            if ghosttyView.isHiddenOrHasHiddenAncestor {
                return false
            }
            return ghosttyView === window.contentView || ghosttyView.superview != nil
        }

        guard let ownerView = keyRoutingOwnerView(for: responder) else {
            return false
        }

        if ownerView.window !== window {
            return false
        }

        if ownerView.isHiddenOrHasHiddenAncestor {
            return false
        }

        if ownerView !== window.contentView, ownerView.superview == nil {
            return false
        }

        return true
    }

    private func responderNeedsFocusedTerminalKeyRepair(
        _ responder: NSResponder?,
        in window: NSWindow,
        hostedView: GhosttySurfaceScrollView
    ) -> Bool {
        guard let responder else { return true }
        if responder is NSWindow { return true }
        guard responderHasViableKeyRoutingOwner(responder, in: window) else {
            return true
        }
        if hostedView.responderMatchesPreferredKeyboardFocus(responder) {
            return false
        }
        return true
    }

    func repairFocusedTerminalKeyboardRoutingIfNeeded(
        window: NSWindow,
        event: NSEvent
    ) {
        guard event.type == .keyDown else { return }
        let normalizedFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !normalizedFlags.contains(.command) else { return }
        guard isMainTerminalWindow(window) else { return }
        guard window.attachedSheet == nil else { return }
        guard !isCommandPaletteEffectivelyVisible(in: window) else { return }
        guard let context = contextForMainWindow(window) ?? contextForMainTerminalWindow(window),
              let workspace = context.tabManager.selectedWorkspace,
              let panelId = workspace.focusedPanelId,
              let terminalPanel = workspace.terminalPanel(for: panelId) else {
            return
        }
        guard responderNeedsFocusedTerminalKeyRepair(
            window.firstResponder,
            in: window,
            hostedView: terminalPanel.hostedView
        ) else { return }

#if DEBUG
        let before = window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        let target = terminalPanel.hostedView.preferredPanelFocusIntentForActivation()
        dlog(
            "focus.keyRepair attempt window=\(ObjectIdentifier(window)) " +
            "workspace=\(String(workspace.id.uuidString.prefix(5))) " +
            "panel=\(String(panelId.uuidString.prefix(5))) " +
            "target=\(target == .findField ? "searchField" : "surface") " +
            "fr=\(before) keyCode=\(event.keyCode) mods=\(event.modifierFlags.rawValue)"
        )
#endif

        terminalPanel.hostedView.ensureFocus(for: workspace.id, surfaceId: panelId)

#if DEBUG
        let after = window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        dlog(
            "focus.keyRepair result window=\(ObjectIdentifier(window)) " +
            "panel=\(String(panelId.uuidString.prefix(5))) " +
            "isSurfaceResponder=\(terminalPanel.hostedView.isSurfaceViewFirstResponder() ? 1 : 0) " +
            "fr=\(after)"
        )
#endif
    }

    func locateSurface(surfaceId: UUID) -> (windowId: UUID, workspaceId: UUID, tabManager: TabManager)? {
        for ctx in mainWindowContexts.values {
            for ws in ctx.tabManager.tabs {
                if ws.panels[surfaceId] != nil {
                    return (ctx.windowId, ws.id, ctx.tabManager)
                }
            }
        }
        return nil
    }

    /// Resolve the workspace that currently owns a panel/surface ID.
    /// Prefer the provided workspace when available, then fall back to global lookup.
    func workspaceContainingPanel(
        panelId: UUID,
        preferredWorkspaceId: UUID? = nil
    ) -> (workspace: Workspace, tabManager: TabManager)? {
        if let preferredWorkspaceId,
           let manager = tabManagerFor(tabId: preferredWorkspaceId),
           let workspace = manager.tabs.first(where: { $0.id == preferredWorkspaceId }),
           workspace.panels[panelId] != nil {
            return (workspace, manager)
        }

        if let located = locateSurface(surfaceId: panelId),
           let workspace = located.tabManager.tabs.first(where: { $0.id == located.workspaceId }),
           workspace.panels[panelId] != nil {
            return (workspace, located.tabManager)
        }

        if let preferredWorkspaceId,
           let manager = tabManagerFor(tabId: preferredWorkspaceId) ?? tabManager,
           let workspace = manager.tabs.first(where: { $0.id == preferredWorkspaceId }),
           workspace.panels[panelId] != nil {
            return (workspace, manager)
        }

        if let manager = tabManager,
           let workspace = manager.tabs.first(where: { $0.panels[panelId] != nil }) {
            return (workspace, manager)
        }

        return nil
    }

    func locateGhosttySurface(_ surface: ghostty_surface_t?) -> (windowId: UUID, workspaceId: UUID, panelId: UUID, tabManager: TabManager)? {
        guard let surface else { return nil }
        for ctx in mainWindowContexts.values {
            for ws in ctx.tabManager.tabs {
                for (panelId, panel) in ws.panels {
                    guard let terminal = panel as? TerminalPanel else { continue }
                    if terminal.surface.surface == surface {
                        return (ctx.windowId, ws.id, panelId, ctx.tabManager)
                    }
                }
            }
        }
        return nil
    }

    func refreshTerminalSurfacesAfterGhosttyConfigReload(source: String) {
        var refreshedCount = 0
        forEachTerminalPanel { terminalPanel in
            terminalPanel.hostedView.reconcileGeometryNow()
            terminalPanel.hostedView.refreshHostBackgroundAfterGhosttyConfigReload()
            terminalPanel.surface.forceRefresh(reason: "appDelegate.refreshAfterGhosttyConfigReload")
            refreshedCount += 1
        }
#if DEBUG
        dlog("reload.config.surfaceRefresh source=\(source) count=\(refreshedCount)")
#endif
    }

    private func forEachTerminalPanel(_ body: (TerminalPanel) -> Void) {
        var seenManagers: Set<ObjectIdentifier> = []

        func visitManager(_ manager: TabManager?) {
            guard let manager else { return }
            let managerId = ObjectIdentifier(manager)
            guard seenManagers.insert(managerId).inserted else { return }
            for workspace in manager.tabs {
                for panel in workspace.panels.values {
                    guard let terminalPanel = panel as? TerminalPanel else { continue }
                    body(terminalPanel)
                }
            }
        }

        visitManager(tabManager)
        for context in mainWindowContexts.values {
            visitManager(context.tabManager)
        }
    }

    func focusMainWindow(windowId: UUID) -> Bool {
        guard let window = windowForMainWindowId(windowId) else { return false }
        if TerminalController.shouldSuppressSocketCommandActivation(),
           !TerminalController.socketCommandAllowsInAppFocusMutations() {
            setActiveMainWindow(window)
            return true
        }
        bringToFront(window)
        return true
    }

    func closeMainWindow(windowId: UUID) -> Bool {
        guard let window = windowForMainWindowId(windowId) else { return false }
        disposeMainWindow(window)
        return true
    }

    /// Explicit workspace/panel and socket disposal still ends the owned sessions.
    func disposeMainWindow(_ window: NSWindow) {
        let key = ObjectIdentifier(window)
        guard disposingMainWindows.insert(key).inserted else { return }
        defer { disposingMainWindows.remove(key) }
        contextForMainTerminalWindow(window)?.hiddenWindow = nil
        window.close()
    }

    /// Ordinary window close hides the UI without destroying its workspaces or PTYs.
    func preserveMainWindowOnClose(_ window: NSWindow) -> Bool {
        guard !isTerminatingApp,
              !disposingMainWindows.contains(ObjectIdentifier(window)),
              let context = contextForMainTerminalWindow(window) else { return false }
        context.hiddenWindow = window
        context.hiddenAt = Date()
        NotificationCenter.default.post(
            name: .commandPaletteDismissRequested,
            object: window,
            userInfo: ["restoreFocus": false]
        )
        teardownCommandPaletteState(for: context.windowId)
        dismissNotificationsPopoverIfShown()
        if let panelId = browserAddressBarFocusedPanelId,
           context.tabManager.tabs.contains(where: { $0.panels[panelId] != nil }) {
            browserAddressBarFocusedPanelId = nil
            stopBrowserOmnibarSelectionRepeat()
        }
        persistWindowGeometry(from: window)
        window.orderOut(nil)
        _ = saveSessionSnapshot(includeScrollback: false)
        return true
    }

    @discardableResult
    func reopenMostRecentlyHiddenMainWindow(onlyIfNoVisibleMainWindows: Bool = true) -> Bool {
        if onlyIfNoVisibleMainWindows,
           mainWindowContexts.values.contains(where: {
               guard let window = $0.window else { return false }
               return window.isVisible || window.isMiniaturized
           }) { return false }
        guard let context = mainWindowContexts.values
            .filter({ $0.hiddenWindow != nil })
            .max(by: { ($0.hiddenAt ?? .distantPast) < ($1.hiddenAt ?? .distantPast) }),
              let window = context.hiddenWindow else { return false }
        CommandPaletteController.windowLifecycle.reset(windowId: context.windowId)
        bringToFront(window)
        return window.isVisible
    }

    private func orderedMainWindowSummaries(referenceWindowId: UUID?) -> [MainWindowSummary] {
        let summaries = listMainWindowSummaries()
        return summaries.sorted { lhs, rhs in
            let lhsIsReference = lhs.windowId == referenceWindowId
            let rhsIsReference = rhs.windowId == referenceWindowId
            if lhsIsReference != rhsIsReference { return lhsIsReference }
            if lhs.isKeyWindow != rhs.isKeyWindow { return lhs.isKeyWindow }
            if lhs.isVisible != rhs.isVisible { return lhs.isVisible }
            return lhs.windowId.uuidString < rhs.windowId.uuidString
        }
    }

    private func windowLabelsById(orderedSummaries: [MainWindowSummary], referenceWindowId: UUID?) -> [UUID: String] {
        var labels: [UUID: String] = [:]
        for (index, summary) in orderedSummaries.enumerated() {
            if summary.windowId == referenceWindowId {
                labels[summary.windowId] = String(localized: "menu.currentWindow", defaultValue: "Current Window")
            } else {
                let number = index + 1
                labels[summary.windowId] = String(localized: "menu.windowNumber", defaultValue: "Window \(number)")
            }
        }
        return labels
    }

    private func workspaceDisplayName(_ workspace: Workspace) -> String {
        let trimmed = workspace.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? String(localized: "workspace.displayName.fallback", defaultValue: "Workspace") : trimmed
    }

    private func detachedSurfaceAttachmentTarget(
        workspace: Workspace,
        pane: PaneID?,
        index: Int?,
        focus: Bool
    ) -> Workspace.DetachedSurfaceAttachmentTarget? {
        let resolvedPane = pane.flatMap { pane in
            workspace.bonsplitController.allPaneIds.first(where: { $0 == pane })
        } ?? workspace.bonsplitController.focusedPaneId
            ?? workspace.bonsplitController.allPaneIds.first
        guard let resolvedPane else { return nil }
        return Workspace.DetachedSurfaceAttachmentTarget(
            workspace: workspace,
            paneId: resolvedPane,
            index: index,
            focus: focus
        )
    }

    private func cleanupEmptySourceWorkspaceAfterSurfaceMove(
        sourceWorkspace: Workspace,
        sourceManager: TabManager,
        sourceWindowId: UUID
    ) {
        guard sourceWorkspace.panels.isEmpty else { return }
        guard sourceManager.tabs.contains(where: { $0.id == sourceWorkspace.id }) else { return }

        if sourceManager.tabs.count > 1 {
            sourceManager.closeWorkspace(sourceWorkspace)
        } else {
            _ = closeMainWindow(windowId: sourceWindowId)
        }
    }

    private func reassertCrossWindowSurfaceMoveFocusIfNeeded(
        destinationWindowId: UUID,
        sourceWindowId: UUID,
        destinationWorkspaceId: UUID,
        destinationPanelId: UUID,
        destinationManager: TabManager
    ) {
        let reassert: @MainActor @Sendable () -> Void = { [weak self, weak destinationManager] in
            guard let self, let destinationManager else { return }
            guard let workspace = destinationManager.tabs.first(where: { $0.id == destinationWorkspaceId }),
                  workspace.panels[destinationPanelId] != nil else {
                return
            }
            guard let destinationWindow = self.mainWindow(for: destinationWindowId) else { return }
            guard let keyWindow = NSApp.keyWindow,
                  let keyWindowId = self.mainWindowId(for: keyWindow),
                  keyWindowId == sourceWindowId,
                  keyWindow !== destinationWindow else {
                return
            }

            self.bringToFront(destinationWindow)
            destinationManager.focusTab(
                destinationWorkspaceId,
                surfaceId: destinationPanelId,
                suppressFlash: true
            )
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: reassert)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: reassert)
    }

    func windowForMainWindowId(_ windowId: UUID) -> NSWindow? {
        if let ctx = mainWindowContexts.values.first(where: { $0.windowId == windowId }),
           let window = ctx.window {
            return window
        }
        let expectedIdentifier = "cmux.main.\(windowId.uuidString)"
        return NSApp.windows.first(where: { $0.identifier?.rawValue == expectedIdentifier })
    }

    private func resolvedWindow(for context: MainWindowContext) -> NSWindow? {
        if let window = context.window {
            return window
        }
        guard let window = windowForMainWindowId(context.windowId) else {
            return nil
        }
        reindexMainWindowContextIfNeeded(context, for: window)
        return window
    }

    private func mainWindowId(from window: NSWindow) -> UUID? {
        guard let raw = window.identifier?.rawValue else { return nil }
        let prefix = "cmux.main."
        guard raw.hasPrefix(prefix) else { return nil }
        let suffix = String(raw.dropFirst(prefix.count))
        return UUID(uuidString: suffix)
    }

    private func reindexMainWindowContextIfNeeded(_ context: MainWindowContext, for window: NSWindow) {
        let desiredKey = ObjectIdentifier(window)
        if mainWindowContexts[desiredKey] === context {
            context.window = window
            installMainWindowCloseObserver(for: context, window: window)
            return
        }

        if let displaced = mainWindowContexts[desiredKey], displaced !== context {
            discardOrphanedMainWindowContext(displaced)
        }

        let contextKeys = mainWindowContexts.compactMap { key, value in
            value === context ? key : nil
        }
        for key in contextKeys {
            mainWindowContexts.removeValue(forKey: key)
        }

        mainWindowContexts[desiredKey] = context
        context.window = window
        installMainWindowCloseObserver(for: context, window: window)
        notifyMainWindowContextsDidChange()
    }

    private func contextForMainTerminalWindow(_ window: NSWindow, reindex: Bool = true) -> MainWindowContext? {
        guard isMainTerminalWindow(window) else { return nil }

        if let context = mainWindowContexts[ObjectIdentifier(window)] {
            context.window = window
            return context
        }

        if let windowId = mainWindowId(from: window),
           let context = mainWindowContexts.values.first(where: { $0.windowId == windowId }) {
            if reindex {
                reindexMainWindowContextIfNeeded(context, for: window)
            } else {
                context.window = window
            }
            return context
        }

        let windowNumber = window.windowNumber
        if windowNumber >= 0,
           let context = mainWindowContexts.values.first(where: { candidate in
               let candidateWindow = candidate.window ?? windowForMainWindowId(candidate.windowId)
               return candidateWindow?.windowNumber == windowNumber
           }) {
            if reindex {
                reindexMainWindowContextIfNeeded(context, for: window)
            } else {
                context.window = window
            }
            return context
        }

        return nil
    }

    private func unregisterMainWindowContext(for window: NSWindow) -> MainWindowContext? {
        guard let removed = mainWindowContexts[ObjectIdentifier(window)],
              removed.window === window,
              removed.observedWindow === window else {
            return nil
        }
        let removedKeys = mainWindowContexts.compactMap { key, value in
            value === removed ? key : nil
        }
        for key in removedKeys {
            mainWindowContexts.removeValue(forKey: key)
        }
        notifyMainWindowContextsDidChange()
        return removed
    }

    private func teardownMainWindowContext(_ context: MainWindowContext) {
        removeMainWindowCloseObserver(from: context)
        context.tabManager.teardownForWindowClose(notifyOwner: !isTerminatingApp)
    }

    private func discardOrphanedMainWindowContext(_ context: MainWindowContext) {
        let contextKeys = mainWindowContexts.compactMap { key, value in
            value === context ? key : nil
        }
        for key in contextKeys {
            mainWindowContexts.removeValue(forKey: key)
        }
        notifyMainWindowContextsDidChange()

        teardownCommandPaletteState(for: context.windowId)

        if tabManager === context.tabManager {
            if let nextContext = mainWindowContexts.values.first(where: { resolvedWindow(for: $0) != nil }) {
                tabManager = nextContext.tabManager
                sidebarState = nextContext.sidebarState
                sidebarSelectionState = nextContext.sidebarSelectionState
                TerminalController.shared.setActiveTabManager(nextContext.tabManager)
            } else {
                tabManager = nil
                sidebarState = nil
                sidebarSelectionState = nil
                TerminalController.shared.setActiveTabManager(nil)
            }
        }

        if let store = notificationStore {
            for tab in context.tabManager.tabs {
                store.clearNotifications(forTabId: tab.id)
            }
        }
        teardownMainWindowContext(context)
    }

    /// Prune every registered main window context whose window has already been
    /// deallocated. Snapshot into an array first: `discardOrphanedMainWindowContext`
    /// mutates `mainWindowContexts`, and mutating a dictionary while iterating its
    /// `.values` view directly would trap.
    private func discardOrphanedMainWindowContexts() {
        let orphans = mainWindowContexts.values.filter { resolvedWindow(for: $0) == nil }
        for orphan in orphans {
            discardOrphanedMainWindowContext(orphan)
        }
    }

    private func mainWindowId(for window: NSWindow) -> UUID? {
        if let context = mainWindowContexts[ObjectIdentifier(window)] {
            return context.windowId
        }
        guard let rawIdentifier = window.identifier?.rawValue,
              rawIdentifier.hasPrefix("cmux.main.") else { return nil }
        let idPart = String(rawIdentifier.dropFirst("cmux.main.".count))
        return UUID(uuidString: idPart)
    }

    private func commandPaletteOverlayContainer(in window: NSWindow) -> NSView? {
        guard let searchRoot = window.contentView?.superview ?? window.contentView else { return nil }
        var stack: [NSView] = [searchRoot]
        while let candidate = stack.popLast() {
            if candidate.identifier == commandPaletteOverlayContainerIdentifier {
                return candidate
            }
            stack.append(contentsOf: candidate.subviews)
        }
        return nil
    }

    private func isCommandPaletteOverlayPresented(in window: NSWindow) -> Bool {
        guard let container = commandPaletteOverlayContainer(in: window) else { return false }
        return !container.isHidden && container.alphaValue > 0.001
    }

    private func isCommandPaletteResponderActive(in window: NSWindow) -> Bool {
        guard let responder = window.firstResponder else { return false }
        if let textView = responder as? NSTextView,
           textView.isFieldEditor,
           !(textView.delegate is NSView) {
            // Field-editor delegates can be non-view responders. Confirm the overlay is
            // mounted and visible to avoid treating unrelated editors as palette input.
            return isCommandPaletteOverlayPresented(in: window)
        }
        return isCommandPaletteResponder(responder)
    }

    private func isCommandPaletteMultilineTextResponderActive(in window: NSWindow) -> Bool {
        guard let textView = window.firstResponder as? NSTextView,
              !textView.isFieldEditor else {
            return false
        }
        return isCommandPaletteResponder(textView)
    }

    private func commandPaletteMarkedTextInput(in window: NSWindow) -> NSTextView? {
        if let textView = window.firstResponder as? NSTextView,
           isCommandPaletteResponder(textView),
           textView.hasMarkedText() {
            return textView
        }

        if let textField = window.firstResponder as? NSTextField,
           let editor = textField.currentEditor() as? NSTextView,
           isCommandPaletteResponder(editor),
           editor.hasMarkedText() {
            return editor
        }

        return nil
    }

    private func isCommandPaletteEffectivelyVisible(in window: NSWindow) -> Bool {
        isCommandPaletteVisible(for: window)
            || isCommandPalettePendingOpen(for: window)
            || isCommandPaletteOverlayPresented(in: window)
            || isCommandPaletteResponderActive(in: window)
    }

    private func activeCommandPaletteWindow() -> NSWindow? {
        pruneExpiredCommandPalettePendingOpenStates()
        if let keyWindow = NSApp.keyWindow,
           isMainTerminalWindow(keyWindow),
           isCommandPaletteEffectivelyVisible(in: keyWindow) {
            return keyWindow
        }
        if let mainWindow = NSApp.mainWindow,
           isMainTerminalWindow(mainWindow),
           isCommandPaletteEffectivelyVisible(in: mainWindow) {
            return mainWindow
        }
        if let orderedWindow = NSApp.orderedWindows.first(where: { window in
            isMainTerminalWindow(window) && isCommandPaletteEffectivelyVisible(in: window)
        }) {
            return orderedWindow
        }
        if let visibleWindowId = CommandPaletteController.windowLifecycle.firstVisibleWindowId() {
            return windowForMainWindowId(visibleWindowId)
        }
        if let pendingWindowId = CommandPaletteController.windowLifecycle.firstPendingWindowId() {
            return windowForMainWindowId(pendingWindowId)
        }
        return nil
    }

    private func commandPaletteWindowForShortcutEvent(_ event: NSEvent) -> NSWindow? {
        if let scopedWindow = mainWindowForShortcutEvent(event) {
            return scopedWindow
        }
        return activeCommandPaletteWindow()
    }

    private func contextForMainWindow(_ window: NSWindow?) -> MainWindowContext? {
        guard let window, isMainTerminalWindow(window) else { return nil }
        return mainWindowContexts[ObjectIdentifier(window)]
    }

#if DEBUG
    func debugManagerToken(_ manager: TabManager?) -> String {
        guard let manager else { return "nil" }
        return String(describing: Unmanaged.passUnretained(manager).toOpaque())
    }

    private func debugWindowToken(_ window: NSWindow?) -> String {
        guard let window else { return "nil" }
        let id = mainWindowId(for: window).map { String($0.uuidString.prefix(8)) } ?? "none"
        let ident = window.identifier?.rawValue ?? "nil"
        let shortIdent: String
        if ident.count > 120 {
            shortIdent = String(ident.prefix(120)) + "..."
        } else {
            shortIdent = ident
        }
        return "num=\(window.windowNumber) id=\(id) ident=\(shortIdent) key=\(window.isKeyWindow ? 1 : 0) main=\(window.isMainWindow ? 1 : 0)"
    }

    private func debugContextToken(_ context: MainWindowContext?) -> String {
        guard let context else { return "nil" }
        let selected = context.tabManager.selectedTabId.map { String($0.uuidString.prefix(5)) } ?? "nil"
        let hasWindow = (context.window != nil || windowForMainWindowId(context.windowId) != nil) ? 1 : 0
        return "id=\(String(context.windowId.uuidString.prefix(8))) mgr=\(debugManagerToken(context.tabManager)) tabs=\(context.tabManager.tabs.count) selected=\(selected) hasWindow=\(hasWindow)"
    }

    private func debugShortcutRouteSnapshot(event: NSEvent? = nil) -> String {
        let activeManager = tabManager
        let activeWindowId = activeManager.flatMap { windowId(for: $0) }.map { String($0.uuidString.prefix(8)) } ?? "nil"
        let selectedWorkspace = activeManager?.selectedTabId.map { String($0.uuidString.prefix(5)) } ?? "nil"

        let contexts = mainWindowContexts.values
            .map { context in
                let marker = (activeManager != nil && context.tabManager === activeManager) ? "*" : "-"
                let window = context.window ?? windowForMainWindowId(context.windowId)
                let selected = context.tabManager.selectedTabId.map { String($0.uuidString.prefix(5)) } ?? "nil"
                return "\(marker)\(String(context.windowId.uuidString.prefix(8))){mgr=\(debugManagerToken(context.tabManager)),win=\(window?.windowNumber ?? -1),key=\((window?.isKeyWindow ?? false) ? 1 : 0),main=\((window?.isMainWindow ?? false) ? 1 : 0),tabs=\(context.tabManager.tabs.count),selected=\(selected)}"
            }
            .sorted()
            .joined(separator: ",")

        let eventWindowNumber = event.map { String($0.windowNumber) } ?? "nil"
        let eventWindow = event?.window
        return "eventWinNum=\(eventWindowNumber) eventWin={\(debugWindowToken(eventWindow))} keyWin={\(debugWindowToken(NSApp.keyWindow))} mainWin={\(debugWindowToken(NSApp.mainWindow))} activeMgr=\(debugManagerToken(activeManager)) activeWinId=\(activeWindowId) activeSelected=\(selectedWorkspace) contexts=[\(contexts)]"
    }
#endif

    private func mainWindowForShortcutEvent(_ event: NSEvent) -> NSWindow? {
        if let window = resolvedShortcutEventWindow(event),
           isMainTerminalWindow(window) {
            return window
        }
        if let keyWindow = NSApp.keyWindow, isMainTerminalWindow(keyWindow) {
            return keyWindow
        }
        if let mainWindow = NSApp.mainWindow, isMainTerminalWindow(mainWindow) {
            return mainWindow
        }
        return nil
    }

    private func resolvedShortcutEventWindow(_ event: NSEvent) -> NSWindow? {
        if let window = event.window {
            return window
        }
        let eventWindowNumber = event.windowNumber
        guard eventWindowNumber > 0 else { return nil }
        return NSApp.window(withWindowNumber: eventWindowNumber)
    }

    /// Re-sync app-level active window pointers from the currently focused main terminal window.
    /// This keeps menu/shortcut actions window-scoped even if the cached `tabManager` drifts.
    @discardableResult
    func synchronizeActiveMainWindowContext(preferredWindow: NSWindow? = nil) -> TabManager? {
        let (context, source): (MainWindowContext?, String) = {
            if let preferredWindow,
               let context = contextForMainWindow(preferredWindow) {
                return (context, "preferredWindow")
            }
            if let context = contextForMainWindow(NSApp.keyWindow) {
                return (context, "keyWindow")
            }
            if let context = contextForMainWindow(NSApp.mainWindow) {
                return (context, "mainWindow")
            }
            if let activeManager = tabManager,
               let activeContext = mainWindowContexts.values.first(where: { $0.tabManager === activeManager }) {
                return (activeContext, "activeManager")
            }
            return (mainWindowContexts.values.first, "firstContextFallback")
        }()

#if DEBUG
        let beforeManagerToken = debugManagerToken(tabManager)
        dlog(
            "shortcut.sync.pre source=\(source) preferred={\(debugWindowToken(preferredWindow))} chosen={\(debugContextToken(context))} \(debugShortcutRouteSnapshot())"
        )
#endif
        guard let context else { return tabManager }
        let alreadyActive =
            tabManager === context.tabManager
            && sidebarState === context.sidebarState
            && sidebarSelectionState === context.sidebarSelectionState
        if alreadyActive {
#if DEBUG
            dlog(
                "shortcut.sync.post source=\(source) beforeMgr=\(beforeManagerToken) afterMgr=\(debugManagerToken(tabManager)) chosen={\(debugContextToken(context))} nochange=1 \(debugShortcutRouteSnapshot())"
            )
#endif
            return context.tabManager
        }
        if let window = context.window ?? windowForMainWindowId(context.windowId) {
            setActiveMainWindow(window)
        } else {
            tabManager = context.tabManager
            sidebarState = context.sidebarState
            sidebarSelectionState = context.sidebarSelectionState
            TerminalController.shared.setActiveTabManager(context.tabManager)
        }
#if DEBUG
        dlog(
            "shortcut.sync.post source=\(source) beforeMgr=\(beforeManagerToken) afterMgr=\(debugManagerToken(tabManager)) chosen={\(debugContextToken(context))} \(debugShortcutRouteSnapshot())"
        )
#endif
        return context.tabManager
    }

    private struct FocusedTerminalShortcutContext {
        let tabManager: TabManager
        let workspaceId: UUID
        let panelId: UUID
    }

    private func resolveShortcutTabManager(for tabId: UUID, preferredWindow: NSWindow? = nil) -> TabManager? {
        if let manager = tabManagerFor(tabId: tabId) {
            return manager
        }
        if let preferredWindow,
           let context = contextForMainWindow(preferredWindow),
           context.tabManager.tabs.contains(where: { $0.id == tabId }) {
            return context.tabManager
        }
        if let activeManager = tabManager,
           activeManager.tabs.contains(where: { $0.id == tabId }) {
            return activeManager
        }
        return nil
    }

    private func focusedTerminalShortcutContext(preferredWindow: NSWindow? = nil) -> FocusedTerminalShortcutContext? {
        let targetWindow = preferredWindow ?? NSApp.keyWindow ?? NSApp.mainWindow
        let responder = targetWindow?.firstResponder
            ?? NSApp.keyWindow?.firstResponder
            ?? NSApp.mainWindow?.firstResponder
        guard let ghosttyView = cmuxOwningGhosttyView(for: responder),
              let workspaceId = ghosttyView.tabId,
              let panelId = ghosttyView.terminalSurface?.id,
              let manager = resolveShortcutTabManager(for: workspaceId, preferredWindow: targetWindow) else {
            return nil
        }
        return FocusedTerminalShortcutContext(
            tabManager: manager,
            workspaceId: workspaceId,
            panelId: panelId
        )
    }

    private func preferredMainWindowContextForShortcuts(event: NSEvent) -> MainWindowContext? {
        if let context = contextForMainWindow(event.window) {
            return context
        }
        if let context = contextForMainWindow(NSApp.keyWindow) {
            return context
        }
        if let context = contextForMainWindow(NSApp.mainWindow) {
            return context
        }
        if let activeManager = tabManager,
           let activeContext = mainWindowContexts.values.first(where: { $0.tabManager === activeManager }) {
            return activeContext
        }
        return mainWindowContexts.values.first
    }

    private func activateMainWindowContextForShortcutEvent(_ event: NSEvent) {
        let preferredWindow = mainWindowForShortcutEvent(event)
#if DEBUG
        dlog(
            "shortcut.activate.pre event=\(NSWindow.keyDescription(event)) preferred={\(debugWindowToken(preferredWindow))} \(debugShortcutRouteSnapshot(event: event))"
        )
#endif
        _ = synchronizeActiveMainWindowContext(preferredWindow: preferredWindow)
#if DEBUG
        dlog(
            "shortcut.activate.post event=\(NSWindow.keyDescription(event)) preferred={\(debugWindowToken(preferredWindow))} \(debugShortcutRouteSnapshot(event: event))"
        )
#endif
    }

    @discardableResult
    func toggleSidebarInActiveMainWindow() -> Bool {
        if let activeManager = tabManager,
           let activeContext = mainWindowContexts.values.first(where: { $0.tabManager === activeManager }) {
            if let window = activeContext.window ?? windowForMainWindowId(activeContext.windowId) {
                setActiveMainWindow(window)
            }
            activeContext.sidebarState.toggle()
            return true
        }
        if let keyContext = contextForMainWindow(NSApp.keyWindow) {
            if let window = keyContext.window ?? windowForMainWindowId(keyContext.windowId) {
                setActiveMainWindow(window)
            }
            keyContext.sidebarState.toggle()
            return true
        }
        if let mainContext = contextForMainWindow(NSApp.mainWindow) {
            if let window = mainContext.window ?? windowForMainWindowId(mainContext.windowId) {
                setActiveMainWindow(window)
            }
            mainContext.sidebarState.toggle()
            return true
        }
        if let fallbackContext = mainWindowContexts.values.first {
            if let window = fallbackContext.window ?? windowForMainWindowId(fallbackContext.windowId) {
                setActiveMainWindow(window)
            }
            fallbackContext.sidebarState.toggle()
            return true
        }
        if let sidebarState {
            sidebarState.toggle()
            return true
        }
        return false
    }

    func sidebarVisibility(windowId: UUID) -> Bool? {
        mainWindowContexts.values.first(where: { $0.windowId == windowId })?.sidebarState.isVisible
    }

    /// Toggle the sidebar for the window identified by the given NSWindow.
    /// Used by titlebar accessory buttons so they affect their own window
    /// rather than the currently focused/key window (#1779).
    func toggleSidebarForWindow(_ window: NSWindow?) -> Bool {
        if let window {
            guard let context = contextForMainTerminalWindow(window) else {
                return false
            }
            context.sidebarState.toggle()
            return true
        }
        return toggleSidebarInActiveMainWindow()
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu(title: "")
        let newWindowItem = NSMenuItem(
            title: String(localized: "menu.file.newWindow", defaultValue: "New Window"),
            action: #selector(openNewMainWindow(_:)),
            keyEquivalent: ""
        )
        newWindowItem.target = self
        menu.addItem(newWindowItem)
        return menu
    }

    @objc func openNewMainWindow(_ sender: Any?) {
        if reopenMostRecentlyHiddenMainWindow() { return }
        _ = createMainWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // AppKit's flag includes Settings and other auxiliary windows.
        if reopenMostRecentlyHiddenMainWindow() { return false }
        return true
    }

    /// Shows the "Open Folder" panel and creates a workspace for the selected directory.
    /// Called from both the SwiftUI menu and `handleCustomShortcut`.
    func showOpenFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = String(localized: "menu.file.openFolder.panelTitle", defaultValue: "Open Folder")
        panel.prompt = String(localized: "menu.file.openFolder.panelPrompt", defaultValue: "Open")
        // Seed the panel with the active workspace's directory. Use the shared
        // main-window resolver so this works even when an auxiliary window is key.
        if let context = preferredMainWindowContextForWorkspaceCreation(debugSource: "openFolderPanel.seed"),
           let cwd = context.tabManager.selectedWorkspace?.currentDirectory,
           !cwd.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: cwd)
        }
        if panel.runModal() == .OK, let url = panel.url {
            openWorkspaceForExternalDirectory(
                workingDirectory: url.path,
                debugSource: "shortcut.openFolder"
            )
        }
    }

    @objc func openWindow(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        openFromServicePasteboard(pasteboard, target: .window, error: error)
    }

    @objc func openTab(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        openFromServicePasteboard(pasteboard, target: .workspace, error: error)
    }

    private enum ServiceOpenTarget {
        case window
        case workspace
    }

    private func openFromServicePasteboard(
        _ pasteboard: NSPasteboard,
        target: ServiceOpenTarget,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        let pathURLs = servicePathURLs(from: pasteboard)
        guard !pathURLs.isEmpty else {
            error.pointee = Self.serviceErrorNoPath
            return
        }

        let directories = externalOpenDirectories(from: pathURLs)
        guard !directories.isEmpty else {
            error.pointee = Self.serviceErrorNoPath
            return
        }

        prepareForExplicitOpenIntentAtStartup()
        for directory in directories {
            switch target {
            case .window:
                _ = createMainWindow(initialWorkingDirectory: directory)
            case .workspace:
                openWorkspaceFromService(workingDirectory: directory)
            }
        }
    }

    private func servicePathURLs(from pasteboard: NSPasteboard) -> [URL] {
        if let pathURLs = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !pathURLs.isEmpty {
            return pathURLs
        }

        let filenamesType = NSPasteboard.PasteboardType(rawValue: "NSFilenamesPboardType")
        if let paths = pasteboard.propertyList(forType: filenamesType) as? [String] {
            let urls = paths.map { URL(fileURLWithPath: $0) }
            if !urls.isEmpty {
                return urls
            }
        }

        if let raw = pasteboard.string(forType: .string), !raw.isEmpty {
            return raw
                .split(whereSeparator: \.isNewline)
                .map { line in
                    let text = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
                    if let fileURL = URL(string: text), fileURL.isFileURL {
                        return fileURL
                    }
                    return URL(fileURLWithPath: text)
                }
        }

        return []
    }

    private func openWorkspaceFromService(workingDirectory: String) {
        openWorkspaceForExternalDirectory(
            workingDirectory: workingDirectory,
            debugSource: "service.openTab"
        )
    }

    private func prepareForExplicitOpenIntentAtStartup() {
        didHandleExplicitOpenIntentAtStartup = true
        if !didAttemptStartupSessionRestore {
            startupSessionSnapshot = nil
            didAttemptStartupSessionRestore = true
        }
        ScrollbackPersistenceSettings.retryLegacyMigration()
    }

    private func externalOpenDirectories(from urls: [URL]) -> [String] {
        // LaunchServices can surface the running app bundle on relaunch; ignore self paths so
        // they do not get treated as explicit folder opens and suppress session restore.
        FinderServicePathResolver.orderedUniqueDirectories(
            from: urls.filter { $0.isFileURL },
            excludingDescendantsOf: [Bundle.main.bundleURL]
        )
    }

    private func openWorkspaceForExternalDirectory(
        workingDirectory: String,
        debugSource: String
    ) {
        if addWorkspaceInPreferredMainWindow(
            workingDirectory: workingDirectory,
            shouldBringToFront: true,
            debugSource: debugSource
        ) != nil {
            return
        }
        _ = createMainWindow(initialWorkingDirectory: workingDirectory)
    }

    @discardableResult
    func addWorkspaceInPreferredMainWindow(
        workingDirectory: String? = nil,
        shouldBringToFront: Bool = false,
        event: NSEvent? = nil,
        debugSource: String = "unspecified"
    ) -> UUID? {
        #if DEBUG
        logWorkspaceCreationRouting(
            phase: "request",
            source: debugSource,
            reason: "add_workspace",
            event: event,
            chosenContext: nil,
            workingDirectory: workingDirectory
        )
        #endif
        // Prune unconditionally, before context selection: a deallocated-window context
        // (the owning NSWindow was released without going through the normal
        // close/unregister path) must not keep reporting a non-nil
        // tabManagerFor(windowId:) just because *some other* live window ends up being
        // selected below. Selection succeeding elsewhere is not evidence the orphan was
        // ever a candidate -- only that a different, legitimate window was available.
        discardOrphanedMainWindowContexts()
        guard let context = preferredMainWindowContextForWorkspaceCreation(event: event, debugSource: debugSource) else {
            #if DEBUG
            logWorkspaceCreationRouting(
                phase: "no_context",
                source: debugSource,
                reason: "context_selection_failed",
                event: event,
                chosenContext: nil,
                workingDirectory: workingDirectory
            )
            #endif
            return nil
        }
        guard let window = resolvedWindow(for: context) else {
            #if DEBUG
            logWorkspaceCreationRouting(
                phase: "no_context",
                source: debugSource,
                reason: "context_window_missing",
                event: event,
                chosenContext: context,
                workingDirectory: workingDirectory
            )
            #endif
            discardOrphanedMainWindowContext(context)
            return nil
        }
        setActiveMainWindow(window)
        if shouldBringToFront {
            bringToFront(window)
        }

        let workspace: Workspace
        if let workingDirectory {
            workspace = context.tabManager.addWorkspace(workingDirectory: workingDirectory, select: true)
        } else {
            workspace = context.tabManager.addTab(select: true)
        }
        #if DEBUG
        logWorkspaceCreationRouting(
            phase: "created",
            source: debugSource,
            reason: "workspace_created",
            event: event,
            chosenContext: context,
            workspaceId: workspace.id,
            workingDirectory: workingDirectory
        )
        #endif
        return workspace.id
    }

    /// Instantly creates a new workspace in the focused workspace's working directory
    /// and launches Claude Code in it immediately, selecting the new workspace right
    /// away so the user sees Claude boot in place (no pool, no hidden workspace). Refs #137.
    @discardableResult
    func createClaudeWorkspace(event: NSEvent? = nil, debugSource: String = "unspecified") -> UUID? {
        discardOrphanedMainWindowContexts()
        guard let context = preferredMainWindowContextForWorkspaceCreation(event: event, debugSource: debugSource) else {
            openNewMainWindow(nil)
            return nil
        }
        guard let window = resolvedWindow(for: context) else {
            discardOrphanedMainWindowContext(context)
            openNewMainWindow(nil)
            return nil
        }
        setActiveMainWindow(window)

        let trimmedCwd = context.tabManager.selectedWorkspace?.currentDirectory
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let cwd = (trimmedCwd?.isEmpty ?? true) ? nil : trimmedCwd

        let workspace = context.tabManager.addWorkspace(
            workingDirectory: cwd,
            initialTerminalInput: "claude\n",
            select: true
        )
        context.tabManager.openCompanionBrowserSplitIfEnabled(for: workspace)
        return workspace.id
    }

    /// Opens a new workspace and runs `programa claude install-integration` in it,
    /// mirroring createClaudeWorkspace's window-context resolution but without a
    /// working-directory override — the installer targets the user's global Claude
    /// Code settings, not a project. Menu-only entry point (#138).
    @discardableResult
    func openClaudeIntegrationInstaller(event: NSEvent? = nil, debugSource: String = "unspecified") -> UUID? {
        discardOrphanedMainWindowContexts()
        guard let context = preferredMainWindowContextForWorkspaceCreation(event: event, debugSource: debugSource) else {
            openNewMainWindow(nil)
            return nil
        }
        guard let window = resolvedWindow(for: context) else {
            discardOrphanedMainWindowContext(context)
            openNewMainWindow(nil)
            return nil
        }
        setActiveMainWindow(window)

        let workspace = context.tabManager.addWorkspace(
            initialTerminalInput: "programa claude install-integration\n",
            select: true
        )
        return workspace.id
    }

    /// Opens a new workspace and runs `programa codex install-integration` in it,
    /// mirroring openClaudeIntegrationInstaller: no working-directory override, since
    /// the installer targets the user's global Codex settings, not a project.
    @discardableResult
    func openCodexIntegrationInstaller(event: NSEvent? = nil, debugSource: String = "unspecified") -> UUID? {
        discardOrphanedMainWindowContexts()
        guard let context = preferredMainWindowContextForWorkspaceCreation(event: event, debugSource: debugSource) else {
            openNewMainWindow(nil)
            return nil
        }
        guard let window = resolvedWindow(for: context) else {
            discardOrphanedMainWindowContext(context)
            openNewMainWindow(nil)
            return nil
        }
        setActiveMainWindow(window)

        let workspace = context.tabManager.addWorkspace(
            initialTerminalInput: "programa codex install-integration\n",
            select: true
        )
        return workspace.id
    }

    /// Opens a new workspace and runs `programa opencode install-integration` in it,
    /// mirroring openCodexIntegrationInstaller: no working-directory override, since
    /// the installer targets the user's global OpenCode plugin directory, not a project.
    @discardableResult
    func openOpenCodeIntegrationInstaller(event: NSEvent? = nil, debugSource: String = "unspecified") -> UUID? {
        discardOrphanedMainWindowContexts()
        guard let context = preferredMainWindowContextForWorkspaceCreation(event: event, debugSource: debugSource) else {
            openNewMainWindow(nil)
            return nil
        }
        guard let window = resolvedWindow(for: context) else {
            discardOrphanedMainWindowContext(context)
            openNewMainWindow(nil)
            return nil
        }
        setActiveMainWindow(window)

        let workspace = context.tabManager.addWorkspace(
            initialTerminalInput: "programa opencode install-integration\n",
            select: true
        )
        return workspace.id
    }

    /// Opens a new workspace and runs `programa aside install-mcp --with-devtools` in it,
    /// mirroring openOpenCodeIntegrationInstaller: no working-directory override, since
    /// the installer targets the user's global Claude Code / Codex MCP config, not a project.
    @discardableResult
    func openAsideMCPInstaller(event: NSEvent? = nil, debugSource: String = "unspecified") -> UUID? {
        discardOrphanedMainWindowContexts()
        guard let context = preferredMainWindowContextForWorkspaceCreation(event: event, debugSource: debugSource) else {
            openNewMainWindow(nil)
            return nil
        }
        guard let window = resolvedWindow(for: context) else {
            discardOrphanedMainWindowContext(context)
            openNewMainWindow(nil)
            return nil
        }
        setActiveMainWindow(window)

        let workspace = context.tabManager.addWorkspace(
            initialTerminalInput: "programa aside install-mcp --with-devtools\n",
            select: true
        )
        return workspace.id
    }

    private func preferredMainWindowContextForWorkspaceCreation(
        event: NSEvent? = nil,
        debugSource: String = "unspecified"
    ) -> MainWindowContext? {
        if let context = mainWindowContext(forShortcutEvent: event, debugSource: debugSource) {
            return context
        }

        // If a keyboard event identifies a specific window but that context
        // can't be resolved, do not fall back to another window.
        if shortcutEventHasAddressableWindow(event) {
#if DEBUG
            logWorkspaceCreationRouting(
                phase: "choose",
                source: debugSource,
                reason: "event_context_required_no_fallback",
                event: event,
                chosenContext: nil
            )
#endif
            return nil
        }

        if let keyWindow = NSApp.keyWindow,
           let context = contextForMainTerminalWindow(keyWindow) {
#if DEBUG
            logWorkspaceCreationRouting(
                phase: "choose",
                source: debugSource,
                reason: "key_window",
                event: event,
                chosenContext: context
            )
            #endif
            return context
        }

        if let mainWindow = NSApp.mainWindow,
           let context = contextForMainTerminalWindow(mainWindow) {
            #if DEBUG
            logWorkspaceCreationRouting(
                phase: "choose",
                source: debugSource,
                reason: "main_window",
                event: event,
                chosenContext: context
            )
            #endif
            return context
        }

        for window in NSApp.orderedWindows where isMainTerminalWindow(window) {
            if let context = contextForMainTerminalWindow(window) {
                #if DEBUG
                logWorkspaceCreationRouting(
                    phase: "choose",
                    source: debugSource,
                    reason: "ordered_windows",
                    event: event,
                    chosenContext: context
                )
                #endif
                return context
            }
        }

        let fallback = mainWindowContexts.values.first(where: { resolvedWindow(for: $0) != nil })
        #if DEBUG
        logWorkspaceCreationRouting(
            phase: "choose",
            source: debugSource,
            reason: "fallback_first_context",
            event: event,
            chosenContext: fallback
        )
#endif
        return fallback
    }

    private func shortcutEventHasAddressableWindow(_ event: NSEvent?) -> Bool {
        guard let event else { return false }
        // NSEvent.windowNumber can be 0 for responder-chain events that are not
        // actually bound to an NSWindow (notably some WebKit key paths).
        return event.window != nil || event.windowNumber > 0
    }

    private func mainWindowContext(
        forShortcutEvent event: NSEvent?,
        debugSource: String = "unspecified"
    ) -> MainWindowContext? {
        guard let event else { return nil }

        if let eventWindow = event.window,
           let context = contextForMainTerminalWindow(eventWindow) {
            #if DEBUG
            logWorkspaceCreationRouting(
                phase: "choose",
                source: debugSource,
                reason: "event_window",
                event: event,
                chosenContext: context
            )
            #endif
            return context
        }

        if event.windowNumber > 0,
           let numberedWindow = NSApp.window(withWindowNumber: event.windowNumber),
           let context = contextForMainTerminalWindow(numberedWindow) {
            #if DEBUG
            logWorkspaceCreationRouting(
                phase: "choose",
                source: debugSource,
                reason: "event_window_number",
                event: event,
                chosenContext: context
            )
            #endif
            return context
        }

        if event.windowNumber > 0,
           let context = mainWindowContexts.values.first(where: { candidate in
               let window = candidate.window ?? windowForMainWindowId(candidate.windowId)
               return window?.windowNumber == event.windowNumber
           }) {
            #if DEBUG
            logWorkspaceCreationRouting(
                phase: "choose",
                source: debugSource,
                reason: "event_window_number_scan",
                event: event,
                chosenContext: context
            )
            #endif
            return context
        }

        #if DEBUG
        logWorkspaceCreationRouting(
            phase: "choose",
            source: debugSource,
            reason: "event_context_not_found",
            event: event,
            chosenContext: nil
        )
        #endif
        return nil
    }

    private func preferredMainWindowContextForShortcutRouting(event: NSEvent) -> MainWindowContext? {
        if let context = mainWindowContext(forShortcutEvent: event, debugSource: "shortcut.routing") {
            return context
        }

        if shortcutEventHasAddressableWindow(event) {
            if let eventWindow = resolvedShortcutEventWindow(event),
               programaWindowShouldOwnCloseShortcut(eventWindow) {
                // Auxiliary cmux windows do not own a terminal tab manager. Let them fall back
                // to the active main terminal window so app shortcuts like Cmd+W still route.
            } else {
#if DEBUG
                logWorkspaceCreationRouting(
                    phase: "choose",
                    source: "shortcut.routing",
                    reason: "event_context_required_no_fallback",
                    event: event,
                    chosenContext: nil
                )
#endif
                return nil
            }
        }

        if let keyWindow = NSApp.keyWindow,
           let context = contextForMainTerminalWindow(keyWindow) {
            return context
        }

        if let mainWindow = NSApp.mainWindow,
           let context = contextForMainTerminalWindow(mainWindow) {
            return context
        }

        if let activeManager = tabManager,
           let context = mainWindowContexts.values.first(where: { $0.tabManager === activeManager }) {
            return context
        }

        return mainWindowContexts.values.first
    }

    @discardableResult
    private func synchronizeShortcutRoutingContext(event: NSEvent) -> Bool {
        guard let context = preferredMainWindowContextForShortcutRouting(event: event) else {
#if DEBUG
            FocusLogStore.shared.append(
                "shortcut.route reason=no_context_no_fallback eventWin=\(event.windowNumber) keyCode=\(event.keyCode)"
            )
#endif
            return false
        }

        let alreadyActive =
            tabManager === context.tabManager
            && sidebarState === context.sidebarState
            && sidebarSelectionState === context.sidebarSelectionState
        if alreadyActive { return true }

        if let window = context.window ?? windowForMainWindowId(context.windowId) {
            setActiveMainWindow(window)
        } else {
            tabManager = context.tabManager
            sidebarState = context.sidebarState
            sidebarSelectionState = context.sidebarSelectionState
            TerminalController.shared.setActiveTabManager(context.tabManager)
        }

#if DEBUG
        FocusLogStore.shared.append(
            "shortcut.route reason=sync activeTM=\(pointerString(tabManager)) chosen={\(summarizeContextForWorkspaceRouting(context))}"
        )
#endif
        return true
    }

    @discardableResult
    func createMainWindow(
        initialWorkingDirectory: String? = nil,
        sessionWindowSnapshot: SessionWindowSnapshot? = nil
    ) -> UUID {
        let windowId = UUID()
        let tabManager = TabManager(initialWorkingDirectory: initialWorkingDirectory)
        if let tabManagerSnapshot = sessionWindowSnapshot?.tabManager {
            tabManager.restoreSessionSnapshot(tabManagerSnapshot)
        }

        let sidebarWidth = sessionWindowSnapshot?.sidebar.width
            .map(SessionPersistencePolicy.sanitizedSidebarWidth)
            ?? SessionPersistencePolicy.defaultSidebarWidth
        let sidebarState = SidebarState(
            isVisible: sessionWindowSnapshot?.sidebar.isVisible ?? true,
            persistedWidth: CGFloat(sidebarWidth)
        )
        let sidebarSelectionState = SidebarSelectionState(
            selection: sessionWindowSnapshot?.sidebar.selection.sidebarSelection ?? .tabs
        )
        let notificationStore = TerminalNotificationStore.shared

        let programaConfigStore = ProgramaConfigStore()
        programaConfigStore.wireDirectoryTracking(tabManager: tabManager)
        programaConfigStore.loadAll()

        let root = ContentView(updateViewModel: updateViewModel, windowId: windowId)
            .environmentObject(tabManager)
            .environmentObject(notificationStore)
            .environmentObject(sidebarState)
            .environmentObject(sidebarSelectionState)
            .environmentObject(programaConfigStore)

        // Use the current key window's size for new windows so Cmd+Shift+N
        // creates a window matching the previous one's dimensions.
        let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        let sourceContext = preferredMainWindowContextForWorkspaceCreation(
            debugSource: "createMainWindow.initialGeometry"
        )
        let sourceWindow = sourceContext.flatMap { resolvedWindow(for: $0) }
        let existingFrame = sourceWindow?.frame
        let sourceWindowIsNativeFullScreen: Bool = {
#if DEBUG
            if let debugCreateMainWindowSourceIsNativeFullScreenOverride {
                return debugCreateMainWindowSourceIsNativeFullScreenOverride
            }
#endif
            return sourceWindow?.styleMask.contains(.fullScreen) == true
        }()
        let shouldTemporarilyDisallowFullScreenTiling =
            sessionWindowSnapshot == nil && sourceWindowIsNativeFullScreen
        let initialRect: NSRect
        if sessionWindowSnapshot == nil, let existingFrame {
            // Convert frame rect to content rect so the new window matches the
            // source window's actual size (frame includes titlebar insets).
            initialRect = NSWindow.contentRect(forFrameRect: existingFrame, styleMask: styleMask)
        } else {
            initialRect = NSRect(x: 0, y: 0, width: 460, height: 360)
        }

        let window = NSWindow(
            contentRect: initialRect,
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        // When creating a new window from an existing native fullscreen window,
        // temporarily opt out of fullscreen tiling so AppKit doesn't place the
        // new window into the active fullscreen Space.
        if shouldTemporarilyDisallowFullScreenTiling {
            window.collectionBehavior.insert(.fullScreenDisallowsTiling)
        }
        window.title = ""
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        window.isMovable = false
        let restoredFrame = resolvedWindowFrame(from: sessionWindowSnapshot)
        if let restoredFrame {
            window.setFrame(restoredFrame, display: false)
        } else {
            window.center()
            // Cascade using the same algorithm as upstream Ghostty: seed from
            // the window's own top-left on the first call, then advance the
            // cascade point for each subsequent window.
            if mainWindowContexts.count >= 1 {
                lastCascadePoint = window.cascadeTopLeft(from: lastCascadePoint)
            } else {
                lastCascadePoint = window.cascadeTopLeft(from: NSPoint(x: window.frame.minX, y: window.frame.maxY))
            }
        }
        window.contentView = MainWindowHostingView(rootView: root)

        // Apply shared window styling.
        attachUpdateAccessory(to: window)

        // Keep a strong reference so the window isn't deallocated.
        let controller = MainWindowController(window: window)
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.mainWindowControllers.removeAll(where: { $0 === controller })
        }
        window.delegate = controller
        mainWindowControllers.append(controller)

        registerMainWindow(
            window,
            windowId: windowId,
            tabManager: tabManager,
            sidebarState: sidebarState,
            sidebarSelectionState: sidebarSelectionState
        )
        installFileDropOverlay(on: window, tabManager: tabManager)
        if TerminalController.shouldSuppressSocketCommandActivation() {
            window.orderFront(nil)
            if TerminalController.socketCommandAllowsInAppFocusMutations() {
                setActiveMainWindow(window)
            }
        } else {
            window.makeKeyAndOrderFront(nil)
            setActiveMainWindow(window)
            NSRunningApplication.current.activate(options: [.activateAllWindows])
        }
        if shouldTemporarilyDisallowFullScreenTiling {
            DispatchQueue.main.async { [weak window] in
                window?.collectionBehavior.remove(.fullScreenDisallowsTiling)
            }
        }
        if let restoredFrame {
            window.setFrame(restoredFrame, display: true)
#if DEBUG
            dlog(
                "session.restore.frameApplied window=\(windowId.uuidString.prefix(8)) " +
                    "applied={\(debugNSRectDescription(window.frame))}"
            )
#endif
        }
        return windowId
    }

    @objc func checkForUpdates(_ sender: Any?) {
        updateViewModel.overrideState = nil
        updateController.checkForUpdates()
    }

    func checkForUpdatesInCustomUI() {
        updateViewModel.overrideState = nil
        updateController.checkForUpdatesInCustomUI()
    }

    func openWelcomeWorkspace() {
        guard let context = preferredMainWindowContextForWorkspaceCreation(event: nil, debugSource: "welcome") else {
            return
        }
        if let window = context.window ?? windowForMainWindowId(context.windowId) {
            setActiveMainWindow(window)
            bringToFront(window)
        }
        let workspace = context.tabManager.addWorkspace(select: true, autoWelcomeIfNeeded: false)
        sendWelcomeCommandWhenReady(to: workspace)
    }

    func sendWelcomeCommandWhenReady(to workspace: Workspace, markShownOnSend: Bool = false) {
        sendTextWhenReady("programa welcome\n", to: workspace) {
            if markShownOnSend {
                UserDefaults.standard.set(true, forKey: WelcomeSettings.shownKey)
            }
        }
    }

    @objc func applyUpdateIfAvailable(_ sender: Any?) {
        updateViewModel.overrideState = nil
        updateController.installUpdate()
    }

    @objc func attemptUpdate(_ sender: Any?) {
        updateViewModel.overrideState = nil
        updateController.attemptUpdate()
    }

    func isProgramaCLIInstalledInPATH() -> Bool {
        ProgramaCLIPathInstaller().isInstalled()
    }

    @objc func installProgramaCLIInPath(_ sender: Any?) {
        let installer = ProgramaCLIPathInstaller()
        do {
            let outcome = try installer.install()
            var informativeText = String(localized: "cli.install.symlinkCreated", defaultValue: "Created symlink:\n\n\(outcome.destinationURL.path) -> \(outcome.sourceURL.path)")
            if outcome.usedAdministratorPrivileges {
                informativeText += "\n\n" + String(localized: "cli.install.adminRequired", defaultValue: "Administrator privileges were required to write to /usr/local/bin.")
            }
            presentCLIPathAlert(
                title: String(localized: "cli.installed", defaultValue: "Programa CLI Installed"),
                informativeText: informativeText,
                style: .informational
            )
        } catch {
            presentCLIPathAlert(
                title: String(localized: "cli.installFailed", defaultValue: "Couldn't Install Programa CLI"),
                informativeText: error.localizedDescription,
                style: .warning
            )
        }
    }

    @objc func uninstallProgramaCLIInPath(_ sender: Any?) {
        let installer = ProgramaCLIPathInstaller()
        do {
            let outcome = try installer.uninstall()
            let prefix = outcome.removedExistingEntry
                ? String(localized: "cli.uninstall.removed", defaultValue: "Removed \(outcome.destinationURL.path).")
                : String(localized: "cli.uninstall.notFound", defaultValue: "No Programa CLI symlink was found at \(outcome.destinationURL.path).")
            var informativeText = prefix
            if outcome.usedAdministratorPrivileges {
                informativeText += "\n\n" + String(localized: "cli.uninstall.adminRequired", defaultValue: "Administrator privileges were required to modify /usr/local/bin.")
            }
            presentCLIPathAlert(
                title: String(localized: "cli.uninstalled", defaultValue: "Programa CLI Uninstalled"),
                informativeText: informativeText,
                style: .informational
            )
        } catch {
            presentCLIPathAlert(
                title: String(localized: "cli.uninstallFailed", defaultValue: "Couldn't Uninstall Programa CLI"),
                informativeText: error.localizedDescription,
                style: .warning
            )
        }
    }

    private func presentCLIPathAlert(
        title: String,
        informativeText: String,
        style: NSAlert.Style
    ) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = informativeText
        alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))

        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            _ = alert.runModal()
        }
    }

    @objc func restartSocketListener(_ sender: Any?) {
        guard tabManager != nil else {
            NSSound.beep()
            return
        }

        guard socketListenerConfigurationIfEnabled() != nil else {
            TerminalController.shared.stop()
            NSSound.beep()
            return
        }
        restartSocketListenerIfEnabled(source: "menu.command")
    }

    private func setupMenuBarExtra() {
        guard menuBarExtraController == nil else { return }
        let store = TerminalNotificationStore.shared
        menuBarExtraController = MenuBarExtraController(
            notificationStore: store,
            onShowNotifications: { [weak self] in
                self?.showNotificationsPopoverFromMenuBar()
            },
            onOpenNotification: { [weak self] notification in
                _ = self?.openNotification(
                    tabId: notification.tabId,
                    surfaceId: notification.surfaceId,
                    notificationId: notification.id
                )
            },
            onJumpToLatestUnread: { [weak self] in
                self?.jumpToLatestUnread()
            },
            getBlockedAgentCount: { [weak self] in
                self?.blockedAgentCount() ?? 0
            },
            onJumpToBlockedAgent: { [weak self] in
                _ = self?.jumpToFirstBlockedAgent()
            },
            onCheckForUpdates: { [weak self] in
                self?.checkForUpdates(nil)
            },
            onOpenPreferences: { [weak self] in
                self?.openPreferencesWindow(debugSource: "menuBarExtra")
            },
            onQuitApp: {
                NSApp.terminate(nil)
            }
        )
    }

    private func installMenuBarVisibilityObserver() {
        guard menuBarVisibilityObserver == nil else { return }
        menuBarVisibilityObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.syncMenuBarExtraVisibility()
            }
        }
    }

    private func syncMenuBarExtraVisibility(defaults: UserDefaults = .standard) {
        if MenuBarExtraSettings.showsMenuBarExtra(defaults: defaults) {
            setupMenuBarExtra()
            return
        }

        menuBarExtraController?.removeFromMenuBar()
        menuBarExtraController = nil
    }

    @MainActor
    static func presentPreferencesWindow(
        navigationTarget: SettingsNavigationTarget? = nil,
        showFallbackSettingsWindow: @MainActor (SettingsNavigationTarget?) -> Void = { target in
            SettingsWindowController.shared.show(navigationTarget: target)
        },
        activateApplication: @MainActor () -> Void = {
            NSRunningApplication.current.activate(options: [.activateAllWindows])
        }
    ) {
#if DEBUG
        dlog("settings.open.present path=customWindowDirect")
#endif
        showFallbackSettingsWindow(navigationTarget)
        activateApplication()
        if let window = SettingsWindowController.shared.window {
            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)
            DispatchQueue.main.async {
                window.orderFrontRegardless()
                window.makeKeyAndOrderFront(nil)
            }
        }
#if DEBUG
        dlog("settings.open.present activate=1")
#endif
    }

    @MainActor
    func openPreferencesWindow(debugSource: String, navigationTarget: SettingsNavigationTarget? = nil) {
#if DEBUG
        dlog("settings.open.request source=\(debugSource)")
#endif
        Self.presentPreferencesWindow(navigationTarget: navigationTarget)
    }

    @objc func openPreferencesWindow() {
        openPreferencesWindow(debugSource: "appDelegate")
    }

    func refreshMenuBarExtraForDebug() {
        menuBarExtraController?.refreshForDebugControls()
    }

    func showNotificationsPopoverFromMenuBar() {
        let context: MainWindowContext? = {
            if let keyWindow = NSApp.keyWindow,
               let keyContext = contextForMainTerminalWindow(keyWindow) {
                return keyContext
            }
            if let first = mainWindowContexts.values.first {
                return first
            }
            let windowId = createMainWindow()
            return mainWindowContexts.values.first(where: { $0.windowId == windowId })
        }()

        if let context,
           let window = context.window ?? windowForMainWindowId(context.windowId) {
            setActiveMainWindow(window)
            bringToFront(window)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.titlebarAccessoryController.showNotificationsPopover(animated: false)
        }
    }

    #if DEBUG
    @objc func showUpdatePill(_ sender: Any?) {
        updateViewModel.debugOverrideText = nil
        updateViewModel.overrideState = .installing(.init(isAutoUpdate: true, retryTerminatingApplication: {}, dismiss: {}))
    }

    @objc func showUpdatePillLongNightly(_ sender: Any?) {
        updateViewModel.debugOverrideText = "Update Available: 0.32.0-nightly+20260216.abc1234"
        updateViewModel.overrideState = .notFound(.init(acknowledgement: {}))
    }

    @objc func showUpdatePillLoading(_ sender: Any?) {
        updateViewModel.debugOverrideText = nil
        updateViewModel.overrideState = .checking(.init(cancel: {}))
    }

    @objc func hideUpdatePill(_ sender: Any?) {
        updateViewModel.debugOverrideText = nil
        updateViewModel.overrideState = .idle
    }

    @objc func clearUpdatePillOverride(_ sender: Any?) {
        updateViewModel.debugOverrideText = nil
        updateViewModel.overrideState = nil
    }
#endif

    @objc func copyUpdateLogs(_ sender: Any?) {
        let logText = UpdateLogStore.shared.snapshot()
        let payload: String
        if logText.isEmpty {
            payload = "No update logs captured.\nLog file: \(UpdateLogStore.shared.logPath())"
        } else {
            payload = logText + "\nLog file: \(UpdateLogStore.shared.logPath())"
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(payload, forType: .string)
    }
    @objc func copyFocusLogs(_ sender: Any?) {
        let logText = FocusLogStore.shared.snapshot()
        let payload: String
        if logText.isEmpty {
            payload = "No focus logs captured.\nLog file: \(FocusLogStore.shared.logPath())"
        } else {
            payload = logText + "\nLog file: \(FocusLogStore.shared.logPath())"
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(payload, forType: .string)
    }


    @objc private func handleDesignModeDidCapture(_ notification: Notification) {
        guard let workspaceId = notification.userInfo?[DesignModeNotificationKey.workspaceId] as? UUID,
              let returnPanelId = notification.userInfo?[DesignModeNotificationKey.returnPanelId] as? UUID,
              let payload = notification.userInfo?[DesignModeNotificationKey.payload] as? DesignModePickPayload else {
            return
        }
        let screenshotData = notification.userInfo?[DesignModeNotificationKey.screenshotData] as? Data

        guard let manager = tabManagerFor(tabId: workspaceId),
              let workspace = manager.tabs.first(where: { $0.id == workspaceId }),
              let returnTerminalPanel = workspace.terminalPanel(for: returnPanelId) else {
            return
        }

        var screenshotPath: String?
        if let screenshotData {
            screenshotPath = DesignModeFileWriter.write(
                screenshotData,
                selector: payload.selector,
                workingDirectory: returnTerminalPanel.requestedWorkingDirectory
            )
        }

        let content = DesignModeTextComposer.compose(payload: payload, screenshotPath: screenshotPath)
        manager.focusTab(workspaceId, surfaceId: returnPanelId, suppressFlash: true)
        sendTextWhenReady(content, to: workspace, preferredPanelId: returnPanelId)
    }

    nonisolated private static func debugShortId(_ id: UUID?) -> String {
        id.map { String($0.uuidString.prefix(5)) } ?? "nil"
    }

    static func resolveTerminalPanelForTextSend(in tab: Workspace, preferredPanelId: UUID? = nil) -> TerminalPanel? {
        if let preferredPanelId {
            return tab.terminalPanel(for: preferredPanelId)
        }
        return tab.focusedTerminalPanel
    }

    func sendTextWhenReady(
        _ text: String,
        to tab: Workspace,
        preferredPanelId: UUID? = nil,
        beforeSend: (() -> Void)? = nil
    ) {
        let isDesignModePasteback = preferredPanelId != nil
#if DEBUG
        let initialTargetPanel = Self.resolveTerminalPanelForTextSend(
            in: tab,
            preferredPanelId: preferredPanelId
        )
        if isDesignModePasteback {
            dlog(
                "reactGrab.pasteback h2.send.start " +
                "workspace=\(Self.debugShortId(tab.id)) " +
                "preferred=\(Self.debugShortId(preferredPanelId)) " +
                "focused=\(Self.debugShortId(tab.focusedPanelId)) " +
                "focusedTerminal=\(Self.debugShortId(tab.focusedTerminalPanel?.id)) " +
                "resolved=\(Self.debugShortId(initialTargetPanel?.id)) " +
                "surfaceReady=\(initialTargetPanel?.surface.surface != nil ? 1 : 0) len=\(text.count)"
            )
        }
#endif
        if let terminalPanel = Self.resolveTerminalPanelForTextSend(
            in: tab,
            preferredPanelId: preferredPanelId
        ),
           terminalPanel.surface.surface != nil {
#if DEBUG
            if isDesignModePasteback {
                dlog(
                    "reactGrab.pasteback h2.send.immediate " +
                    "workspace=\(Self.debugShortId(tab.id)) " +
                    "target=\(Self.debugShortId(terminalPanel.id)) len=\(text.count)"
                )
            }
#endif
            beforeSend?()
            terminalPanel.sendText(text)
#if DEBUG
            if isDesignModePasteback {
                dlog(
                    "reactGrab.pasteback h2.send.sent " +
                    "workspace=\(Self.debugShortId(tab.id)) " +
                    "target=\(Self.debugShortId(terminalPanel.id)) mode=immediate len=\(text.count)"
                )
            }
#endif
            return
        }

        var resolved = false
        var readyObserver: NSObjectProtocol?
        var focusObserver: NSObjectProtocol?
        var firstResponderObserver: NSObjectProtocol?
        var panelsCancellable: AnyCancellable?

        func cleanupObservers() {
            if let readyObserver {
                NotificationCenter.default.removeObserver(readyObserver)
            }
            if let focusObserver {
                NotificationCenter.default.removeObserver(focusObserver)
            }
            if let firstResponderObserver {
                NotificationCenter.default.removeObserver(firstResponderObserver)
            }
            panelsCancellable?.cancel()
        }

        func finishIfReady() {
            let terminalPanel = Self.resolveTerminalPanelForTextSend(
                in: tab,
                preferredPanelId: preferredPanelId
            )
#if DEBUG
            if isDesignModePasteback {
                dlog(
                    "reactGrab.pasteback h2.finishIfReady " +
                    "workspace=\(Self.debugShortId(tab.id)) " +
                    "preferred=\(Self.debugShortId(preferredPanelId)) " +
                    "focused=\(Self.debugShortId(tab.focusedPanelId)) " +
                    "resolved=\(Self.debugShortId(terminalPanel?.id)) " +
                    "surfaceReady=\(terminalPanel?.surface.surface != nil ? 1 : 0) alreadyResolved=\(resolved ? 1 : 0)"
                )
            }
#endif
            guard !resolved,
                  let terminalPanel,
                  terminalPanel.surface.surface != nil else { return }
            resolved = true
            cleanupObservers()
            beforeSend?()
            terminalPanel.sendText(text)
#if DEBUG
            if isDesignModePasteback {
                dlog(
                    "reactGrab.pasteback h2.send.sent " +
                    "workspace=\(Self.debugShortId(tab.id)) " +
                    "target=\(Self.debugShortId(terminalPanel.id)) mode=delayed len=\(text.count)"
                )
            }
#endif
        }

        panelsCancellable = tab.$panels
            .map { _ in () }
            .sink { _ in
#if DEBUG
                if isDesignModePasteback {
                    dlog(
                        "reactGrab.pasteback h2.panelsChanged " +
                        "workspace=\(Self.debugShortId(tab.id)) " +
                        "focused=\(Self.debugShortId(tab.focusedPanelId))"
                    )
                }
#endif
                finishIfReady()
            }
        if isDesignModePasteback {
            focusObserver = NotificationCenter.default.addObserver(
                forName: .ghosttyDidFocusSurface,
                object: nil,
                queue: .main
            ) { note in
                guard let candidateTabId = note.userInfo?[GhosttyNotificationKey.tabId] as? UUID,
                      candidateTabId == tab.id,
                      let candidateSurfaceId = note.userInfo?[GhosttyNotificationKey.surfaceId] as? UUID else {
                    return
                }
#if DEBUG
                dlog(
                    "reactGrab.pasteback h1.focusEvent " +
                    "workspace=\(Self.debugShortId(candidateTabId)) " +
                    "surface=\(Self.debugShortId(candidateSurfaceId)) " +
                    "target=\(Self.debugShortId(preferredPanelId)) " +
                    "match=\(candidateSurfaceId == preferredPanelId ? 1 : 0)"
                )
#endif
            }
            firstResponderObserver = NotificationCenter.default.addObserver(
                forName: .ghosttyDidBecomeFirstResponderSurface,
                object: nil,
                queue: .main
            ) { note in
                guard let candidateTabId = note.userInfo?[GhosttyNotificationKey.tabId] as? UUID,
                      candidateTabId == tab.id,
                      let candidateSurfaceId = note.userInfo?[GhosttyNotificationKey.surfaceId] as? UUID else {
                    return
                }
#if DEBUG
                dlog(
                    "reactGrab.pasteback h1.firstResponderEvent " +
                    "workspace=\(Self.debugShortId(candidateTabId)) " +
                    "surface=\(Self.debugShortId(candidateSurfaceId)) " +
                    "target=\(Self.debugShortId(preferredPanelId)) " +
                    "match=\(candidateSurfaceId == preferredPanelId ? 1 : 0)"
                )
#endif
            }
        }
        readyObserver = NotificationCenter.default.addObserver(
            forName: .terminalSurfaceDidBecomeReady,
            object: nil,
            queue: .main
        ) { note in
            MainActor.assumeIsolated {
                guard let workspaceId = note.userInfo?["workspaceId"] as? UUID,
                      workspaceId == tab.id else { return }
                let surfaceId = note.userInfo?["surfaceId"] as? UUID
#if DEBUG
                if isDesignModePasteback {
                    dlog(
                        "reactGrab.pasteback h2.surfaceReadyEvent " +
                        "workspace=\(Self.debugShortId(workspaceId)) " +
                        "surface=\(Self.debugShortId(surfaceId)) " +
                        "target=\(Self.debugShortId(preferredPanelId)) " +
                        "match=\(surfaceId == preferredPanelId ? 1 : 0)"
                    )
                }
#endif
                if let preferredPanelId,
                   let surfaceId,
                   surfaceId != preferredPanelId {
                    return
                }
                finishIfReady()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            if !resolved {
#if DEBUG
                if isDesignModePasteback {
                    dlog(
                        "reactGrab.pasteback h2.send.timeout " +
                        "workspace=\(Self.debugShortId(tab.id)) " +
                        "preferred=\(Self.debugShortId(preferredPanelId)) " +
                        "focused=\(Self.debugShortId(tab.focusedPanelId)) " +
                        "focusedTerminal=\(Self.debugShortId(tab.focusedTerminalPanel?.id))"
                    )
                }
#endif
                cleanupObservers()
                NSLog("Command send: surface not ready after 3.0s")
            }
        }
    }

#if DEBUG
    private let debugColorWorkspaceTitlePrefix = "Debug Color - "
    let debugPerfWorkspaceTitlePrefix = "Debug Perf - "
    var debugStressWorkspaceCreationInProgress = false
    var debugStressLagProbeEnabled = false
    let debugStressWorkspaceCount = 20
    let debugStressPaneCount = 4
    let debugStressTabsPerPane = 4
    let debugStressYieldInterval = 4
    let debugStressSurfaceLoadTimeoutSeconds: TimeInterval = 10.0

    @objc func openDebugScrollbackTab(_ sender: Any?) {
        guard let tabManager else { return }
        let tab = tabManager.addTab()
        let config = GhosttyConfig.load()
        let lineCount = min(max(config.scrollbackLimit * 2, 2000), 60000)
        let command = "for i in {1..\(lineCount)}; do printf \"scrollback %06d\\n\" $i; done\n"
        sendTextWhenReady(command, to: tab)
    }

    @objc func openDebugLoremTab(_ sender: Any?) {
        guard let tabManager else { return }
        let tab = tabManager.addTab()
        let lineCount = 2000
        let base = "Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore."
        var lines: [String] = []
        lines.reserveCapacity(lineCount)
        for index in 1...lineCount {
            lines.append(String(format: "%04d %@", index, base))
        }
        let payload = lines.joined(separator: "\n") + "\n"
        sendTextWhenReady(payload, to: tab)
    }

    @objc func openDebugColorComparisonWorkspaces(_ sender: Any?) {
        guard let tabManager else { return }

        let palette = WorkspaceTabColorSettings.palette()
        guard !palette.isEmpty else { return }

        var existingByTitle: [String: Workspace] = [:]
        for tab in tabManager.tabs {
            guard let title = tab.customTitle,
                  title.hasPrefix(debugColorWorkspaceTitlePrefix) else { continue }
            existingByTitle[title] = tab
        }

        for entry in palette {
            let title = "\(debugColorWorkspaceTitlePrefix)\(entry.name)"
            let targetTab: Workspace
            if let existing = existingByTitle[title] {
                targetTab = existing
            } else {
                targetTab = tabManager.addTab()
            }
            tabManager.setCustomTitle(tabId: targetTab.id, title: title)
            tabManager.setTabColor(tabId: targetTab.id, color: entry.hex)
        }
    }


#endif


    func attachUpdateAccessory(to window: NSWindow) {
        titlebarAccessoryController.start()
        titlebarAccessoryController.attach(to: window)
    }

    func toggleNotificationsPopover(animated: Bool = true, anchorView: NSView? = nil) {
        titlebarAccessoryController.toggleNotificationsPopover(animated: animated, anchorView: anchorView)
    }

    @discardableResult
    func dismissNotificationsPopoverIfShown() -> Bool {
        titlebarAccessoryController.dismissNotificationsPopoverIfShown()
    }

    func isNotificationsPopoverShown() -> Bool {
        titlebarAccessoryController.isNotificationsPopoverShown()
    }

    // MARK: - Agent status badges (issue #164, v1 hook tier)
    //
    // "Blocked" surfaces are surfaced in the menu bar as "N agents blocked" alongside the
    // unread count. State is fed exclusively by installed lifecycle hooks
    // (Workspace.panelAgentStates, set via surface.report_agent_state) — there is no
    // heuristic/screen-rule fallback in this tier.

    /// Every currently-blocked surface across all windows, as (workspaceId, surfaceId)
    /// pairs. Falls back to the active `tabManager`'s tabs when no window context is
    /// registered yet (mirrors `openNotificationFallback`'s early-boot fallback).
    func blockedAgentSurfaces() -> [(tabId: UUID, surfaceId: UUID)] {
        var seenWorkspaceIds: Set<UUID> = []
        var results: [(tabId: UUID, surfaceId: UUID)] = []

        func collect(from workspaces: [Workspace]) {
            for workspace in workspaces {
                guard seenWorkspaceIds.insert(workspace.id).inserted else { continue }
                for (panelId, state) in workspace.panelAgentStates where state == .blocked {
                    results.append((tabId: workspace.id, surfaceId: panelId))
                }
            }
        }

        for context in mainWindowContexts.values {
            collect(from: context.tabManager.tabs)
        }
        if let tabManager {
            collect(from: tabManager.tabs)
        }
        return results
    }

    func blockedAgentCount() -> Int {
        blockedAgentSurfaces().count
    }

    /// Focuses the first blocked surface found, reusing the same cross-window focus path
    /// as notification jump-to (`openNotification`).
    @discardableResult
    func jumpToFirstBlockedAgent() -> Bool {
        guard let target = blockedAgentSurfaces().first else { return false }
        return openNotification(tabId: target.tabId, surfaceId: target.surfaceId, notificationId: nil)
    }

    func jumpToLatestUnread() {
        guard let notificationStore else { return }
#if DEBUG
        if ProcessInfo.processInfo.environment["PROGRAMA_UI_TEST_JUMP_UNREAD_SETUP"] == "1" {
            writeJumpUnreadTestData([
                "jumpUnreadInvoked": "1",
                "jumpUnreadNotificationCount": String(notificationStore.notifications.count),
            ])
        }
#endif
        // Prefer the latest unread that we can actually open. In early startup (especially on the VM),
        // the window-context registry can lag behind model initialization, so fall back to whatever
        // tab manager currently owns the tab.
        for notification in notificationStore.notifications where !notification.isRead {
            if openNotification(tabId: notification.tabId, surfaceId: notification.surfaceId, notificationId: notification.id) {
                return
            }
        }
    }

    static func installWindowResponderSwizzlesForTesting() {
        _ = didInstallWindowCloseSwizzle
        _ = didInstallWindowKeyEquivalentSwizzle
        _ = didInstallWindowFirstResponderSwizzle
        _ = didInstallWindowSendEventSwizzle
    }

#if DEBUG
    static func setWindowFirstResponderGuardTesting(currentEvent: NSEvent?, hitView: NSView?) {
        programaFirstResponderGuardCurrentEventOverride = currentEvent
        programaFirstResponderGuardHitViewOverride = hitView
    }

    static func clearWindowFirstResponderGuardTesting() {
        programaFirstResponderGuardCurrentEventOverride = nil
        programaFirstResponderGuardHitViewOverride = nil
    }
#endif

    private func installWindowResponderSwizzles() {
        _ = Self.didInstallWindowCloseSwizzle
        _ = Self.didInstallApplicationSendEventSwizzle
        _ = Self.didInstallWindowKeyEquivalentSwizzle
        _ = Self.didInstallWindowFirstResponderSwizzle
        _ = Self.didInstallWindowSendEventSwizzle
    }

    private func installShortcutMonitor() {
        // Local monitor only receives events when app is active (not global)
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
#if DEBUG
                let phaseTotalStart = ProcessInfo.processInfo.systemUptime
                let preludeStart = ProcessInfo.processInfo.systemUptime
                var preludeMs: Double = 0
                var shortcutMs: Double = 0
                ProgramaTypingTiming.logEventDelay(path: "appMonitor", event: event)
                let shortcutMonitorTraceEnabled =
                    ProcessInfo.processInfo.environment["PROGRAMA_SHORTCUT_MONITOR_TRACE"] == "1"
                    || UserDefaults.standard.bool(forKey: "programaShortcutMonitorTrace")
                if shortcutMonitorTraceEnabled {
                    let frType = NSApp.keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
                    dlog(
                        "monitor.keyDown: \(NSWindow.keyDescription(event)) fr=\(frType) addrBarId=\(self.browserAddressBarFocusedPanelId?.uuidString.prefix(8) ?? "nil") \(self.debugShortcutRouteSnapshot(event: event))"
                    )
                }
                if let probeKind = self.developerToolsShortcutProbeKind(event: event) {
                    self.logDeveloperToolsShortcutSnapshot(phase: "monitor.pre.\(probeKind)", event: event)
                }
                preludeMs = (ProcessInfo.processInfo.systemUptime - preludeStart) * 1000.0
                let shortcutTimingStart = ProgramaTypingTiming.start()
#endif
                let shortcutStart = ProcessInfo.processInfo.systemUptime
                let handledByShortcut = self.handleCustomShortcut(event: event)
#if DEBUG
                shortcutMs = (ProcessInfo.processInfo.systemUptime - shortcutStart) * 1000.0
                ProgramaTypingTiming.logDuration(
                    path: "appMonitor.handleCustomShortcut",
                    startedAt: shortcutTimingStart,
                    event: event,
                    extra: "handled=\(handledByShortcut ? 1 : 0)"
                )
                let shortcutElapsedMs = (ProcessInfo.processInfo.systemUptime - shortcutStart) * 1000.0
                self.logSlowShortcutMonitorLatencyIfNeeded(
                    event: event,
                    handledByShortcut: handledByShortcut,
                    elapsedMs: shortcutElapsedMs
                )
                let totalMs = (ProcessInfo.processInfo.systemUptime - phaseTotalStart) * 1000.0
                ProgramaTypingTiming.logBreakdown(
                    path: "appMonitor.phase",
                    totalMs: totalMs,
                    event: event,
                    thresholdMs: 0.75,
                    parts: [
                        ("preludeMs", preludeMs),
                        ("shortcutMs", shortcutMs),
                    ],
                    extra: "handled=\(handledByShortcut ? 1 : 0)"
                )
#endif
                if handledByShortcut {
#if DEBUG
                    dlog("  → consumed by handleCustomShortcut")
#endif
                    return nil // Consume the event
                }
                return event // Pass through
            }
            self.handleBrowserOmnibarSelectionRepeatLifecycleEvent(event)
            if self.clearEscapeSuppressionForKeyUp(event: event, consumeIfSuppressed: true) {
                return nil
            }
            return event
        }
    }

    private func installShortcutDefaultsObserver() {
        guard shortcutDefaultsObserver == nil else { return }
        refreshConfiguredShortcutChordActions()
        // queue: nil (not .main) is required so this runs synchronously on the
        // posting thread. All call sites post this notification from the main
        // thread (see Sources/KeyboardShortcutSettings.swift setShortcut/resetShortcut/
        // resetAll, and Sources/ProgramaSettingsFileStore.swift's file watcher, which
        // hops to DispatchQueue.main.async before calling reload()). A .main queue
        // would enqueue delivery asynchronously even when posted from the main thread,
        // leaving configuredShortcutChordActions stale for one run-loop turn if a key
        // event arrives immediately after a shortcut change.
        shortcutDefaultsObserver = NotificationCenter.default.addObserver(
            forName: KeyboardShortcutSettings.didChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshConfiguredShortcutChordActions()
                self?.clearConfiguredShortcutChordState()
                self?.scheduleSplitButtonTooltipRefreshAcrossWorkspaces()
            }
        }
    }

    private func refreshConfiguredShortcutChordActions() {
        configuredShortcutChordActions = KeyboardShortcutSettings.Action.allCases.filter {
            KeyboardShortcutSettings.shortcut(for: $0).hasChord
        }
    }

    private func clearConfiguredShortcutChordState() {
        pendingConfiguredShortcutChord = nil
        activeConfiguredShortcutChordPrefixForCurrentEvent = nil
    }

    /// Coalesce shortcut-default changes and refresh on the next runloop turn to
    /// avoid mutating Bonsplit/SwiftUI-observed state during an active update pass.
    private func scheduleSplitButtonTooltipRefreshAcrossWorkspaces() {
        guard !splitButtonTooltipRefreshScheduled else { return }
        splitButtonTooltipRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.splitButtonTooltipRefreshScheduled = false
            self.refreshSplitButtonTooltipsAcrossWorkspaces()
        }
    }

    private func refreshSplitButtonTooltipsAcrossWorkspaces() {
        var refreshedManagers: Set<ObjectIdentifier> = []
        if let manager = tabManager {
            manager.refreshSplitButtonTooltips()
            refreshedManagers.insert(ObjectIdentifier(manager))
        }
        for context in mainWindowContexts.values {
            let manager = context.tabManager
            let identifier = ObjectIdentifier(manager)
            guard refreshedManagers.insert(identifier).inserted else { continue }
            manager.refreshSplitButtonTooltips()
        }
    }

    private func installGhosttyConfigObserver() {
        guard ghosttyConfigObserver == nil else { return }
        ghosttyConfigObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyConfigDidReload,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshGhosttyGotoSplitShortcuts()
            }
        }
    }

    private func refreshGhosttyGotoSplitShortcuts() {
        guard let config = GhosttyApp.shared.config else {
            ghosttyGotoSplitLeftShortcut = nil
            ghosttyGotoSplitRightShortcut = nil
            ghosttyGotoSplitUpShortcut = nil
            ghosttyGotoSplitDownShortcut = nil
            return
        }

        ghosttyGotoSplitLeftShortcut = storedShortcutFromGhosttyTrigger(
            ghostty_config_trigger(config, "goto_split:left", UInt("goto_split:left".utf8.count))
        )
        ghosttyGotoSplitRightShortcut = storedShortcutFromGhosttyTrigger(
            ghostty_config_trigger(config, "goto_split:right", UInt("goto_split:right".utf8.count))
        )
        ghosttyGotoSplitUpShortcut = storedShortcutFromGhosttyTrigger(
            ghostty_config_trigger(config, "goto_split:up", UInt("goto_split:up".utf8.count))
        )
        ghosttyGotoSplitDownShortcut = storedShortcutFromGhosttyTrigger(
            ghostty_config_trigger(config, "goto_split:down", UInt("goto_split:down".utf8.count))
        )
    }

    private func storedShortcutFromGhosttyTrigger(_ trigger: ghostty_input_trigger_s) -> StoredShortcut? {
        let key: String
        switch trigger.tag {
        case GHOSTTY_TRIGGER_PHYSICAL:
            switch trigger.key.physical {
            case GHOSTTY_KEY_ARROW_LEFT:
                key = "←"
            case GHOSTTY_KEY_ARROW_RIGHT:
                key = "→"
            case GHOSTTY_KEY_ARROW_UP:
                key = "↑"
            case GHOSTTY_KEY_ARROW_DOWN:
                key = "↓"
            case GHOSTTY_KEY_A: key = "a"
            case GHOSTTY_KEY_B: key = "b"
            case GHOSTTY_KEY_C: key = "c"
            case GHOSTTY_KEY_D: key = "d"
            case GHOSTTY_KEY_E: key = "e"
            case GHOSTTY_KEY_F: key = "f"
            case GHOSTTY_KEY_G: key = "g"
            case GHOSTTY_KEY_H: key = "h"
            case GHOSTTY_KEY_I: key = "i"
            case GHOSTTY_KEY_J: key = "j"
            case GHOSTTY_KEY_K: key = "k"
            case GHOSTTY_KEY_L: key = "l"
            case GHOSTTY_KEY_M: key = "m"
            case GHOSTTY_KEY_N: key = "n"
            case GHOSTTY_KEY_O: key = "o"
            case GHOSTTY_KEY_P: key = "p"
            case GHOSTTY_KEY_Q: key = "q"
            case GHOSTTY_KEY_R: key = "r"
            case GHOSTTY_KEY_S: key = "s"
            case GHOSTTY_KEY_T: key = "t"
            case GHOSTTY_KEY_U: key = "u"
            case GHOSTTY_KEY_V: key = "v"
            case GHOSTTY_KEY_W: key = "w"
            case GHOSTTY_KEY_X: key = "x"
            case GHOSTTY_KEY_Y: key = "y"
            case GHOSTTY_KEY_Z: key = "z"
            case GHOSTTY_KEY_DIGIT_0: key = "0"
            case GHOSTTY_KEY_DIGIT_1: key = "1"
            case GHOSTTY_KEY_DIGIT_2: key = "2"
            case GHOSTTY_KEY_DIGIT_3: key = "3"
            case GHOSTTY_KEY_DIGIT_4: key = "4"
            case GHOSTTY_KEY_DIGIT_5: key = "5"
            case GHOSTTY_KEY_DIGIT_6: key = "6"
            case GHOSTTY_KEY_DIGIT_7: key = "7"
            case GHOSTTY_KEY_DIGIT_8: key = "8"
            case GHOSTTY_KEY_DIGIT_9: key = "9"
            case GHOSTTY_KEY_BRACKET_LEFT: key = "["
            case GHOSTTY_KEY_BRACKET_RIGHT: key = "]"
            case GHOSTTY_KEY_MINUS: key = "-"
            case GHOSTTY_KEY_EQUAL: key = "="
            case GHOSTTY_KEY_COMMA: key = ","
            case GHOSTTY_KEY_PERIOD: key = "."
            case GHOSTTY_KEY_SLASH: key = "/"
            case GHOSTTY_KEY_SEMICOLON: key = ";"
            case GHOSTTY_KEY_QUOTE: key = "'"
            case GHOSTTY_KEY_BACKQUOTE: key = "`"
            case GHOSTTY_KEY_BACKSLASH: key = "\\"
            default:
                return nil
            }
        case GHOSTTY_TRIGGER_UNICODE:
            guard let scalar = UnicodeScalar(trigger.key.unicode) else { return nil }
            key = String(Character(scalar)).lowercased()
        case GHOSTTY_TRIGGER_CATCH_ALL:
            return nil
        default:
            return nil
        }

        let mods = trigger.mods.rawValue
        let command = (mods & GHOSTTY_MODS_SUPER.rawValue) != 0
        let shift = (mods & GHOSTTY_MODS_SHIFT.rawValue) != 0
        let option = (mods & GHOSTTY_MODS_ALT.rawValue) != 0
        let control = (mods & GHOSTTY_MODS_CTRL.rawValue) != 0

        // Ignore bogus empty triggers.
        if key.isEmpty || (!command && !shift && !option && !control) {
            return nil
        }

        return StoredShortcut(key: key, command: command, shift: shift, option: option, control: control)
    }

    private func handleQuitShortcutWarning() -> Bool {
        // Tagged DEV builds are ephemeral, skip quit confirmation entirely.
        if SocketControlSettings.isTaggedDevBuild() {
            NSApp.terminate(nil)
            return true
        }

        if !QuitWarningSettings.isEnabled() {
            NSApp.terminate(nil)
            return true
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "dialog.quitPrograma.title", defaultValue: "Quit Programa?")
        alert.informativeText = String(localized: "dialog.quitPrograma.message", defaultValue: "This will close all windows and workspaces.")
        alert.addButton(withTitle: String(localized: "dialog.quitPrograma.quit", defaultValue: "Quit"))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = String(localized: "dialog.dontWarnCmdQ", defaultValue: "Don't warn again for Cmd+Q")

        let response = alert.runModal()
        if alert.suppressionButton?.state == .on {
            QuitWarningSettings.setEnabled(false)
        }

        if response == .alertFirstButtonReturn {
            // Mark as confirmed so applicationShouldTerminate does not show a
            // second alert when NSApp.terminate re-enters the delegate callback.
            appLifecycleCoordinator.confirmQuit()
            NSApp.terminate(nil)
        }
        return true
    }

    func promptRenameSelectedWorkspace() -> Bool {
        guard let tabManager,
              let tabId = tabManager.selectedTabId,
              let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
            NSSound.beep()
            return false
        }

        let alert = NSAlert()
        alert.messageText = String(localized: "dialog.renameWorkspace.title", defaultValue: "Rename Workspace")
        alert.informativeText = String(localized: "dialog.renameWorkspace.message", defaultValue: "Enter a custom name for this workspace.")
        let input = NSTextField(string: tab.customTitle ?? tab.title)
        input.placeholderString = String(localized: "dialog.renameWorkspace.placeholder", defaultValue: "Workspace name")
        input.frame = NSRect(x: 0, y: 0, width: 240, height: 22)
        alert.accessoryView = input
        alert.addButton(withTitle: String(localized: "common.rename", defaultValue: "Rename"))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
        let alertWindow = alert.window
        alertWindow.initialFirstResponder = input
        DispatchQueue.main.async {
            alertWindow.makeFirstResponder(input)
            input.selectText(nil)
        }

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return true }
        tabManager.setCustomTitle(tabId: tab.id, title: input.stringValue)
        return true
    }

    // Precedence encoded by this function's evaluation order (each phase is checked
    // strictly after the previous one; the first phase that returns wins). Refs #95.
    //   1. Setup: chord-prefix bookkeeping, Ctrl+D debug probe, close-confirmation-alert
    //      passthrough, modal/sheet passthrough, command-palette window/state computation.
    //   2. Palette (highest real precedence while interactive): Escape-key routing
    //      (palette dismiss / terminal-IME bypass / suppressed-escape grace window),
    //      palette selection-navigation (arrow keys),
    //      palette interactive Return/dismiss handling, stale browser-address-bar-focus
    //      clear, palette "effective" actions (open palette / go-to-workspace + their
    //      chord arming), shouldConsumeShortcutWhileCommandPaletteVisible catch-all.
    //   3. Browser/terminal pre-checks: terminal IME marked-text passthrough, notifications
    //      popover escape/typing consumption, shortcut-routing-context sync guard, Ctrl+D
    //      terminal-focus reconcile bypass, browser omnibar Cmd/Ctrl+N/P and arrow-key
    //      selection, empty-flags fast-path passthrough, browser-address-bar Emacs-nav
    //      bypass.
    //   4. App-shortcut (lowest precedence, only reached once nothing above claimed the
    //      event): the flat table of ~55 `matchConfiguredShortcut`/digit/directional/tab
    //      checks, extracted verbatim into handleConfiguredAppShortcutActions(event:...).
    // Snapshot of whether/how the command palette is claiming keyboard input for a given
    // shortcut event's routed window. Extracted from the six interdependent booleans that used
    // to be computed inline at the top of handleCustomShortcut(event:) so the precedence
    // decisions below can read `commandPaletteState.isEffectiveInTargetWindow` etc. declaratively
    // instead of re-deriving them. Values and their derivation are unchanged from before.
    private struct CommandPaletteInteractionState {
        let targetWindow: NSWindow?
        let shortcutWindow: NSWindow?
        let isVisibleInTargetWindow: Bool
        let isPendingOpenInTargetWindow: Bool
        let isOverlayVisibleInTargetWindow: Bool
        let isResponderActiveInTargetWindow: Bool
        let isInteractiveInTargetWindow: Bool
        let isEffectiveInTargetWindow: Bool
    }

    private func makeCommandPaletteInteractionState(for event: NSEvent) -> CommandPaletteInteractionState {
        let targetWindow = commandPaletteWindowForShortcutEvent(event)
        let shortcutWindow = shouldHandleCommandPaletteShortcutEvent(
            event,
            paletteWindow: targetWindow
        ) ? targetWindow : nil
        let isVisibleInTargetWindow = shortcutWindow.map {
            isCommandPaletteVisible(for: $0)
        } ?? false
        let isPendingOpenInTargetWindow = targetWindow.map {
            isCommandPalettePendingOpen(for: $0)
        } ?? false
        let isOverlayVisibleInTargetWindow = targetWindow.map {
            isCommandPaletteOverlayPresented(in: $0)
        } ?? false
        let isResponderActiveInTargetWindow = targetWindow.map {
            isCommandPaletteResponderActive(in: $0)
        } ?? false
        let isInteractiveInTargetWindow =
            isVisibleInTargetWindow
            || isOverlayVisibleInTargetWindow
            || isResponderActiveInTargetWindow
        let isEffectiveInTargetWindow =
            isInteractiveInTargetWindow
            || isPendingOpenInTargetWindow
        return CommandPaletteInteractionState(
            targetWindow: targetWindow,
            shortcutWindow: shortcutWindow,
            isVisibleInTargetWindow: isVisibleInTargetWindow,
            isPendingOpenInTargetWindow: isPendingOpenInTargetWindow,
            isOverlayVisibleInTargetWindow: isOverlayVisibleInTargetWindow,
            isResponderActiveInTargetWindow: isResponderActiveInTargetWindow,
            isInteractiveInTargetWindow: isInteractiveInTargetWindow,
            isEffectiveInTargetWindow: isEffectiveInTargetWindow
        )
    }

    private func handleCustomShortcut(event: NSEvent) -> Bool {
        // `charactersIgnoringModifiers` can be nil for some synthetic NSEvents and certain special keys.
        // Treat nil as "" and rely on keyCode/layout-aware fallback logic where needed.
        // When a non-Latin input source is active (Korean, Chinese, Japanese, etc.),
        // charactersIgnoringModifiers returns non-ASCII characters that never match
        // Latin shortcut keys. Normalize via KeyboardLayout so downstream comparisons
        // (Cmd+1-9, Ctrl+1-9, omnibar N/P, command palette, etc.) work correctly.
        let chars = KeyboardLayout.normalizedCharacters(for: event)
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasControl = flags.contains(.control)
        let hasCommand = flags.contains(.command)
        let hasOption = flags.contains(.option)
        let isControlOnly = hasControl && !hasCommand && !hasOption
        let controlDChar = chars == "d" || event.characters == "\u{04}"
        let isControlD = isControlOnly && (controlDChar || event.keyCode == 2)
        let configuredShortcutEventWindowNumber = configuredShortcutChordWindowNumber(for: event)
        if let pendingConfiguredShortcutChord,
           pendingConfiguredShortcutChord.windowNumber == configuredShortcutEventWindowNumber {
            activeConfiguredShortcutChordPrefixForCurrentEvent = pendingConfiguredShortcutChord.firstStroke
        } else {
            activeConfiguredShortcutChordPrefixForCurrentEvent = nil
        }
        pendingConfiguredShortcutChord = nil
        defer { activeConfiguredShortcutChordPrefixForCurrentEvent = nil }
#if DEBUG
        if isControlD {
            writeChildExitKeyboardProbe(
                [
                    "probeAppShortcutCharsHex": childExitKeyboardProbeHex(event.characters),
                    "probeAppShortcutCharsIgnoringHex": childExitKeyboardProbeHex(event.charactersIgnoringModifiers),
                    "probeAppShortcutKeyCode": String(event.keyCode),
                    "probeAppShortcutModsRaw": String(event.modifierFlags.rawValue),
                ],
                increments: ["probeAppShortcutCtrlDSeenCount": 1]
            )
        }
#endif

        // Don't steal shortcuts from close-confirmation alerts. Keep standard alert key
        // equivalents working and avoid surprising actions while the confirmation is up.
        let closeConfirmationTitles = [
            String(localized: "dialog.closeWorkspace.title", defaultValue: "Close workspace?"),
            String(localized: "dialog.closeWorkspaces.title", defaultValue: "Close workspaces?"),
            String(localized: "dialog.closeTab.title", defaultValue: "Close tab?"),
            String(localized: "dialog.closeOtherTabs.title", defaultValue: "Close other tabs?"),
            String(localized: "dialog.closeWindow.title", defaultValue: "Close window?"),
        ]
        let resolvedEventWindow = resolvedShortcutEventWindow(event)
            ?? (event.windowNumber <= 0 ? NSApp.keyWindow : nil)
        let closeConfirmationPanel = matchingCloseConfirmationPanel(
            in: NSApp.modalWindow,
            titles: closeConfirmationTitles
        ) ?? matchingCloseConfirmationPanel(
            in: resolvedEventWindow,
            titles: closeConfirmationTitles
        ) ?? matchingCloseConfirmationPanel(
            in: resolvedEventWindow?.attachedSheet,
            titles: closeConfirmationTitles
        )
        if let closeConfirmationPanel {
            // Special-case: Cmd+D should confirm destructive close on alerts.
            // XCUITest key events often hit the app-level local monitor first, so forward the key
            // equivalent to the alert panel explicitly.
            if matchShortcut(
                event: event,
                shortcut: StoredShortcut(key: "d", command: true, shift: false, option: false, control: false)
            ),
               let root = closeConfirmationPanel.contentView,
               let closeButton = findButton(
                   in: root,
                   titled: String(localized: "common.close", defaultValue: "Close")
               ) {
                closeButton.performClick(nil)
                return true
            }
            return false
        }

        if NSApp.modalWindow != nil
            || resolvedEventWindow?.sheetParent != nil
            || resolvedEventWindow?.attachedSheet != nil {
            return false
        }

        let normalizedFlags = flags.subtracting([.numericPad, .function, .capsLock])
        // The six interdependent booleans below (visible/pendingOpen/overlayVisible/
        // responderActive/interactive/effective) describe whether -- and how -- the command
        // palette is currently claiming keyboard input in the window this event is routed to.
        // Precedence throughout the rest of this function reads off `commandPaletteState`
        // declaratively instead of recomputing these checks inline.
        let commandPaletteState = makeCommandPaletteInteractionState(for: event)
        let commandPaletteTargetWindow = commandPaletteState.targetWindow
        let commandPaletteShortcutWindow = commandPaletteState.shortcutWindow
        let commandPaletteVisibleInTargetWindow = commandPaletteState.isVisibleInTargetWindow
        let commandPalettePendingOpenInTargetWindow = commandPaletteState.isPendingOpenInTargetWindow
        let commandPaletteOverlayVisibleInTargetWindow = commandPaletteState.isOverlayVisibleInTargetWindow
        let commandPaletteResponderActiveInTargetWindow = commandPaletteState.isResponderActiveInTargetWindow
        let commandPaletteInteractiveInTargetWindow = commandPaletteState.isInteractiveInTargetWindow
        let commandPaletteEffectiveInTargetWindow = commandPaletteState.isEffectiveInTargetWindow
        let terminalHasMarkedTextInEventWindow = !normalizedFlags.contains(.command)
            && resolvedEventWindow.flatMap {
                cmuxOwningGhosttyView(for: $0.firstResponder)
            }?.hasMarkedText() == true

#if DEBUG
        if event.keyCode == 36 || event.keyCode == 76 {
            dlog(
                "shortcut.return.raw " +
                "interactive=\(commandPaletteInteractiveInTargetWindow ? 1 : 0) " +
                "effective=\(commandPaletteEffectiveInTargetWindow ? 1 : 0) " +
                "target={\(debugWindowToken(commandPaletteTargetWindow))} " +
                "shortcutWindow={\(debugWindowToken(commandPaletteShortcutWindow))} " +
                "responderTarget=\(commandPaletteResponderActiveInTargetWindow ? 1 : 0) " +
                "overlayTarget=\(commandPaletteOverlayVisibleInTargetWindow ? 1 : 0) " +
                "pendingTarget=\(commandPalettePendingOpenInTargetWindow ? 1 : 0) " +
                "\(debugShortcutRouteSnapshot(event: event))"
            )
        }
#endif

        if normalizedFlags.isEmpty, event.keyCode == 53 {
            let activePaletteWindow = activeCommandPaletteWindow()
            let escapePaletteWindow: NSWindow? = {
                if let targetWindow = commandPaletteTargetWindow {
                    guard commandPaletteEffectiveInTargetWindow else {
                        return nil
                    }
                    return targetWindow
                }
                return activePaletteWindow
            }()
#if DEBUG
            dlog(
                "shortcut.escape route target={\(debugWindowToken(commandPaletteTargetWindow))} " +
                "active={\(debugWindowToken(activePaletteWindow))} " +
                "visibleTarget=\(commandPaletteVisibleInTargetWindow ? 1 : 0) " +
                "pendingTarget=\(commandPalettePendingOpenInTargetWindow ? 1 : 0) " +
                "overlayTarget=\(commandPaletteOverlayVisibleInTargetWindow ? 1 : 0) " +
                "responderTarget=\(commandPaletteResponderActiveInTargetWindow ? 1 : 0) " +
                "effectiveTarget=\(commandPaletteEffectiveInTargetWindow ? 1 : 0) " +
                "\(debugShortcutRouteSnapshot(event: event))"
            )
            if commandPaletteTargetWindow != nil,
               !commandPaletteVisibleInTargetWindow,
               !commandPalettePendingOpenInTargetWindow,
               (commandPaletteOverlayVisibleInTargetWindow || commandPaletteResponderActiveInTargetWindow) {
                dlog(
                    "shortcut.escape stateMismatch target={\(debugWindowToken(commandPaletteTargetWindow))} " +
                    "overlayTarget=\(commandPaletteOverlayVisibleInTargetWindow ? 1 : 0) " +
                    "responderTarget=\(commandPaletteResponderActiveInTargetWindow ? 1 : 0)"
                )
            }
#endif
            if terminalHasMarkedTextInEventWindow,
               !commandPaletteInteractiveInTargetWindow {
#if DEBUG
                dlog(
                    "shortcut.escape terminalImeBypass consumed=0 " +
                    "target={\(debugWindowToken(resolvedEventWindow))}"
                )
#endif
                return false
            }
            if let paletteWindow = escapePaletteWindow,
               isCommandPaletteEffectivelyVisible(in: paletteWindow) {
                if commandPaletteMarkedTextInput(in: paletteWindow) != nil {
#if DEBUG
                    dlog(
                        "shortcut.escape imeMarkedTextBypass consumed=0 target={\(debugWindowToken(paletteWindow))}"
                    )
#endif
                    return false
                }
                clearCommandPalettePendingOpen(for: paletteWindow)
                beginCommandPaletteEscapeSuppression(for: paletteWindow)
                NotificationCenter.default.post(name: .commandPaletteToggleRequested, object: paletteWindow)
#if DEBUG
                dlog("shortcut.escape paletteDismiss consumed=1 target={\(debugWindowToken(paletteWindow))}")
#endif
                return true
            }
            let suppressionWindow = commandPaletteTargetWindow
                ?? event.window
                ?? NSApp.keyWindow
                ?? NSApp.mainWindow
            if shouldConsumeSuppressedEscape(event: event, window: suppressionWindow) {
#if DEBUG
                dlog(
                    "shortcut.escape suppressionConsume consumed=1 target={\(debugWindowToken(suppressionWindow))} " +
                    "repeat=\(event.isARepeat ? 1 : 0)"
                )
#endif
                return true
            }
            if let requestAge = recentCommandPaletteRequestAge(for: suppressionWindow) {
                beginCommandPaletteEscapeSuppression(for: suppressionWindow)
#if DEBUG
                dlog(
                    "shortcut.escape requestGraceConsume consumed=1 target={\(debugWindowToken(suppressionWindow))} " +
                    "ageMs=\(Int(requestAge * 1000)) repeat=\(event.isARepeat ? 1 : 0)"
                )
#endif
                return true
            }
#if DEBUG
            dlog(
                "shortcut.escape paletteDismiss consumed=0 target={\(debugWindowToken(commandPaletteTargetWindow))} " +
                "active={\(debugWindowToken(activePaletteWindow))}"
            )
#endif
        }

        let paletteUsesInlineTextHandling = commandPaletteShortcutWindow.map {
            isCommandPaletteMultilineTextResponderActive(in: $0)
        } ?? false

        let paletteSelectionDelta = commandPaletteSelectionDeltaForKeyboardNavigation(
            flags: event.modifierFlags,
            chars: chars,
            keyCode: event.keyCode
        )

        if shouldRouteCommandPaletteSelectionNavigation(
            delta: paletteSelectionDelta,
            isInteractive: commandPaletteInteractiveInTargetWindow,
            usesInlineTextHandling: paletteUsesInlineTextHandling
        ),
           let delta = paletteSelectionDelta,
           let paletteWindow = commandPaletteShortcutWindow {
            NotificationCenter.default.post(
                name: .commandPaletteMoveSelection,
                object: paletteWindow,
                userInfo: ["delta": delta]
            )
            return true
        }

        if commandPaletteInteractiveInTargetWindow,
           let paletteWindow = commandPaletteShortcutWindow {
            let paletteFieldEditorHasMarkedText = commandPaletteFieldEditorHasMarkedText(in: paletteWindow)
            let paletteSnapshot = mainWindowId(for: paletteWindow).map(commandPaletteSnapshot(windowId:)) ?? .empty
            let paletteUsesInlineReturnHandling = paletteUsesInlineTextHandling
            if normalizedFlags.isEmpty, event.keyCode == 53 {
                if paletteFieldEditorHasMarkedText {
                    return false
                }
                NotificationCenter.default.post(name: .commandPaletteDismissRequested, object: paletteWindow)
                return true
            }

            let shouldSubmitPalette = shouldSubmitCommandPaletteWithReturn(
                keyCode: event.keyCode,
                flags: event.modifierFlags,
                mode: paletteSnapshot.mode
            )
#if DEBUG
            if event.keyCode == 36 || event.keyCode == 76 {
                dlog(
                    "shortcut.palette.return target={\(debugWindowToken(paletteWindow))} " +
                    "mode=\(paletteSnapshot.mode) " +
                    "inline=\(paletteUsesInlineReturnHandling ? 1 : 0) " +
                    "submit=\(shouldSubmitPalette ? 1 : 0) " +
                    "marked=\(paletteFieldEditorHasMarkedText ? 1 : 0) " +
                    "\(debugShortcutRouteSnapshot(event: event))"
                )
            }
#endif
            if paletteUsesInlineReturnHandling,
               event.keyCode == 36 || event.keyCode == 76 {
                return false
            }
            if shouldSubmitPalette {
                if paletteFieldEditorHasMarkedText {
                    return false
                }
                NotificationCenter.default.post(name: .commandPaletteSubmitRequested, object: paletteWindow)
                return true
            }
        }

        // Guard against stale browserAddressBarFocusedPanelId after focus transitions
        // (e.g., split that doesn't properly blur the address bar). If the first responder
        // is a terminal surface, the address bar can't be focused.
        if browserAddressBarFocusedPanelId != nil,
           cmuxOwningGhosttyView(for: NSApp.keyWindow?.firstResponder) != nil {
#if DEBUG
            let stalePanelToken = browserAddressBarFocusedPanelId.map { String($0.uuidString.prefix(5)) } ?? "nil"
            let firstResponderType = NSApp.keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
            dlog(
                "browser.focus.addressBar.staleClear panel=\(stalePanelToken) " +
                "reason=terminal_first_responder fr=\(firstResponderType)"
            )
#endif
            browserAddressBarFocusedPanelId = nil
            stopBrowserOmnibarSelectionRepeat()
        }

        // Keep Cmd+P/Cmd+N inside the focused browser omnibar for Chrome-like
        // suggestion navigation, and avoid opening command palette switcher.
        // Scope the omnibar check to the shortcut's routed window context so a
        // focused omnibar in another window does not suppress Cmd+P here.
        let hasFocusedAddressBarInShortcutContext = focusedBrowserAddressBarPanelIdForShortcutEvent(event) != nil

        if commandPaletteEffectiveInTargetWindow {
            if matchConfiguredShortcut(event: event, action: .commandPalette) {
                let targetWindow = commandPaletteTargetWindow ?? event.window ?? NSApp.keyWindow ?? NSApp.mainWindow
                requestCommandPaletteCommands(preferredWindow: targetWindow, source: "shortcut.commandPalette")
                return true
            }

            if !hasFocusedAddressBarInShortcutContext,
               matchConfiguredShortcut(event: event, action: .goToWorkspace) {
                let targetWindow = commandPaletteTargetWindow ?? event.window ?? NSApp.keyWindow ?? NSApp.mainWindow
                requestCommandPaletteSwitcher(preferredWindow: targetWindow, source: "shortcut.goToWorkspace")
                return true
            }

            if activeConfiguredShortcutChordPrefixForCurrentEvent == nil,
               armConfiguredShortcutChordIfNeeded(event: event, actions: [.commandPalette]) {
                return true
            }

            if activeConfiguredShortcutChordPrefixForCurrentEvent == nil,
               !hasFocusedAddressBarInShortcutContext,
               armConfiguredShortcutChordIfNeeded(event: event, actions: [.goToWorkspace]) {
                return true
            }
        }

        if shouldConsumeShortcutWhileCommandPaletteVisible(
            isCommandPaletteVisible: commandPaletteEffectiveInTargetWindow,
            normalizedFlags: normalizedFlags,
            chars: chars,
            keyCode: event.keyCode
        ) {
            return true
        }

        // When the terminal has active IME composition (e.g. Korean, Japanese, Chinese
        // input), don't intercept non-Cmd key events — let them flow through to the
        // input method. Cmd-based shortcuts (Cmd+T, Cmd+Shift+L, etc.) should still
        // work during composition since Cmd is never part of IME input sequences.
        if terminalHasMarkedTextInEventWindow {
            return false
        }

        // When the notifications popover is open, Escape should dismiss it immediately.
        if flags.isEmpty, event.keyCode == 53, titlebarAccessoryController.dismissNotificationsPopoverIfShown() {
            return true
        }

        // When the notifications popover is showing an empty state, consume plain typing
        // so key presses do not leak through into the focused terminal.
        if flags.isDisjoint(with: [.command, .control, .option]),
           titlebarAccessoryController.isNotificationsPopoverShown(),
           (notificationStore?.notifications.isEmpty ?? false) {
            return true
        }

        let hasEventWindowContext = shortcutEventHasAddressableWindow(event)
        let didSynchronizeShortcutContext = synchronizeShortcutRoutingContext(event: event)
        if hasEventWindowContext && !didSynchronizeShortcutContext {
#if DEBUG
            dlog("handleCustomShortcut: unresolved event window context; bypassing app shortcut handling")
#endif
            return false
        }

        // Keep keyboard routing deterministic after split close/reparent transitions:
        // before processing shortcuts, converge first responder with the focused terminal panel.
        if isControlD {
#if DEBUG
            let selected = tabManager?.selectedTabId?.uuidString.prefix(5) ?? "nil"
            let focused = tabManager?.selectedWorkspace?.focusedPanelId?.uuidString.prefix(5) ?? "nil"
            let frType = NSApp.keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
            dlog("shortcut.ctrlD stage=preReconcile selected=\(selected) focused=\(focused) fr=\(frType)")
#endif
            tabManager?.reconcileFocusedPanelFromFirstResponderForKeyboard()
            #if DEBUG
            let frAfterType = NSApp.keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
            dlog("shortcut.ctrlD stage=postReconcile fr=\(frAfterType)")
            writeChildExitKeyboardProbe([:], increments: ["probeAppShortcutCtrlDPassedCount": 1])
            #endif
            // Ctrl+D belongs to the focused terminal surface; never treat it as an app shortcut.
            return false
        }

        // Chrome-like omnibar navigation while holding Cmd+N / Ctrl+N / Cmd+P / Ctrl+P.
        if let delta = commandOmnibarSelectionDelta(flags: flags, chars: chars) {
            dispatchBrowserOmnibarSelectionMove(delta: delta)
            startBrowserOmnibarSelectionRepeatIfNeeded(keyCode: event.keyCode, delta: delta)
            return true
        }

        if let delta = browserOmnibarSelectionDeltaForArrowNavigation(
            hasFocusedAddressBar: browserAddressBarFocusedPanelId != nil,
            flags: event.modifierFlags,
            keyCode: event.keyCode
        ) {
            dispatchBrowserOmnibarSelectionMove(delta: delta)
            return true
        }

        // Fast path for normal typing and terminal navigation keys (for example Up-arrow
        // history): after command-palette/notification handling and browser omnibar
        // arrow navigation above, plain key events have no app-level shortcut behavior.
        if normalizedFlags.isEmpty && activeConfiguredShortcutChordPrefixForCurrentEvent == nil {
            return false
        }

        // Let omnibar-local Emacs navigation (Cmd/Ctrl+N/P) win while the browser
        // address bar is focused. Without this, app-level Cmd+N can steal focus.
        if shouldBypassAppShortcutForFocusedBrowserAddressBar(flags: flags, chars: chars) {
            return false
        }

        return handleConfiguredAppShortcutActions(
            event: event,
            commandPaletteTargetWindow: commandPaletteTargetWindow,
            hasFocusedAddressBarInShortcutContext: hasFocusedAddressBarInShortcutContext
        )
    }

    // Extracted verbatim from the tail of handleCustomShortcut(event:) -- the flat table of
    // ~55 app-level shortcut checks (lowest precedence phase; only reached once the palette
    // and browser/terminal pre-checks above have declined the event). Evaluation order is
    // preserved exactly: this is pure code motion, not a reordering. Refs #95.
    //
    // Precedence is now expressed as two explicit ordered arrays of
    // KeyboardShortcutSettings.Action (split by the two hardcoded legacy Ctrl+Tab checks, which
    // aren't driven by the Action enum) instead of a flat if-chain. handleConfiguredShortcutAction
    // below is an *exhaustive* switch over Action, so the compiler now forces every future case
    // to be handled (even if only to opt out) instead of silently no-op'ing like the old if-chain
    // would for a forgotten case.
    private static let appShortcutPrecedenceOrderBeforeLegacyTabNavigation: [KeyboardShortcutSettings.Action] = [
        .commandPalette, .goToWorkspace, .quit, .openSettings, .reloadConfiguration, .toggleFullScreen,
        .toggleSidebar, .newTab, .newClaudeWorkspace, .newWindow, .openFolder, .showNotifications, .sendFeedback,
        .jumpToUnread, .triggerFlash, .nextSurface, .prevSurface, .toggleTerminalCopyMode, .nextSidebarTab,
        .prevSidebarTab, .renameWorkspace, .editWorkspaceDescription, .closeOtherTabsInPane, .closeTab,
        .closeWorkspace, .closeWindow, .renameTab, .selectWorkspaceByNumber, .selectSurfaceByNumber,
        .focusLeft, .focusRight, .focusUp, .focusDown, .toggleSplitZoom, .splitRight, .splitDown,
        .splitBrowserRight, .splitBrowserDown,
    ]

    private static let appShortcutPrecedenceOrderAfterLegacyTabNavigation: [KeyboardShortcutSettings.Action] = [
        .newSurface, .openBrowser, .openReview, .openAgentOverview, .focusBrowserAddressBar, .browserBack, .browserForward, .browserReload,
        .toggleBrowserDeveloperTools, .showBrowserJavaScriptConsole, .browserZoomIn,
        .browserZoomOut, .browserZoomReset, .find, .findNext, .findPrevious, .hideFind, .useSelectionForFind,
        .reopenClosedBrowserPanel,
    ]

    private func handleConfiguredAppShortcutActions(
        event: NSEvent,
        commandPaletteTargetWindow: NSWindow?,
        hasFocusedAddressBarInShortcutContext: Bool
    ) -> Bool {
        if activeConfiguredShortcutChordPrefixForCurrentEvent == nil,
           armConfiguredShortcutChordIfNeeded(event: event) {
            return true
        }

        for action in Self.appShortcutPrecedenceOrderBeforeLegacyTabNavigation {
            if let result = handleConfiguredShortcutAction(
                action,
                event: event,
                commandPaletteTargetWindow: commandPaletteTargetWindow,
                hasFocusedAddressBarInShortcutContext: hasFocusedAddressBarInShortcutContext
            ) {
                return result
            }
        }

        // Surface navigation (legacy Ctrl+Tab support). Not driven by KeyboardShortcutSettings.Action,
        // so it can't live in the switch below -- kept as plain checks in their original position.
        if matchTabShortcut(event: event, shortcut: StoredShortcut(key: "\t", command: false, shift: false, option: false, control: true)) {
            tabManager?.selectNextSurface()
            return true
        }
        if matchTabShortcut(event: event, shortcut: StoredShortcut(key: "\t", command: false, shift: true, option: false, control: true)) {
            tabManager?.selectPreviousSurface()
            return true
        }

        for action in Self.appShortcutPrecedenceOrderAfterLegacyTabNavigation {
            if let result = handleConfiguredShortcutAction(
                action,
                event: event,
                commandPaletteTargetWindow: commandPaletteTargetWindow,
                hasFocusedAddressBarInShortcutContext: hasFocusedAddressBarInShortcutContext
            ) {
                return result
            }
        }

        return false
    }

    // Exhaustive dispatch for a single KeyboardShortcutSettings.Action: returns nil when this
    // action's configured shortcut doesn't match the event (or, for .focusBrowserAddressBar,
    // when it matches but none of its sub-branches handled it -- see that case below), in which
    // case the caller continues to the next action in precedence order. Returns non-nil the
    // moment an action's shortcut matches and terminally handles (or declines) the event, exactly
    // mirroring the early-return behavior of the original if-chain.
    private func handleConfiguredShortcutAction(
        _ action: KeyboardShortcutSettings.Action,
        event: NSEvent,
        commandPaletteTargetWindow: NSWindow?,
        hasFocusedAddressBarInShortcutContext: Bool
    ) -> Bool? {
        switch action {
        case .commandPalette:
            return handleCommandPaletteShortcutAction(event: event, commandPaletteTargetWindow: commandPaletteTargetWindow)
        case .goToWorkspace:
            return handleGoToWorkspaceShortcutAction(
                event: event,
                commandPaletteTargetWindow: commandPaletteTargetWindow,
                hasFocusedAddressBarInShortcutContext: hasFocusedAddressBarInShortcutContext
            )
        case .quit:
            return handleQuitShortcutAction(event: event)
        case .openSettings:
            return handleOpenSettingsShortcutAction(event: event)
        case .reloadConfiguration:
            return handleReloadConfigurationShortcutAction(event: event)
        case .toggleFullScreen:
            return handleToggleFullScreenShortcutAction(event: event)
        case .toggleSidebar:
            return handleToggleSidebarShortcutAction(event: event)
        case .newTab:
            return handleNewTabShortcutAction(event: event)
        case .newClaudeWorkspace:
            return handleNewClaudeWorkspaceShortcutAction(event: event)
        case .newWindow:
            return handleNewWindowShortcutAction(event: event)
        case .openFolder:
            return handleOpenFolderShortcutAction(event: event)
        case .showNotifications:
            return handleShowNotificationsShortcutAction(event: event)
        case .sendFeedback:
            return handleSendFeedbackShortcutAction(event: event)
        case .jumpToUnread:
            return handleJumpToUnreadShortcutAction(event: event)
        case .triggerFlash:
            return handleTriggerFlashShortcutAction(event: event)
        case .nextSurface:
            return handleNextSurfaceShortcutAction(event: event)
        case .prevSurface:
            return handlePrevSurfaceShortcutAction(event: event)
        case .toggleTerminalCopyMode:
            return handleToggleTerminalCopyModeShortcutAction(event: event)
        case .nextSidebarTab:
            return handleNextSidebarTabShortcutAction(event: event)
        case .prevSidebarTab:
            return handlePrevSidebarTabShortcutAction(event: event)
        case .renameWorkspace:
            return handleRenameWorkspaceShortcutAction(event: event, commandPaletteTargetWindow: commandPaletteTargetWindow)
        case .editWorkspaceDescription:
            return handleEditWorkspaceDescriptionShortcutAction(event: event, commandPaletteTargetWindow: commandPaletteTargetWindow)
        case .closeOtherTabsInPane:
            return handleCloseOtherTabsInPaneShortcutAction(event: event)
        case .closeTab:
            return handleCloseTabShortcutAction(event: event)
        case .closeWorkspace:
            return handleCloseWorkspaceShortcutAction(event: event)
        case .closeWindow:
            return handleCloseWindowShortcutAction(event: event)
        case .renameTab:
            return handleRenameTabShortcutAction(event: event, commandPaletteTargetWindow: commandPaletteTargetWindow)
        case .selectWorkspaceByNumber:
            return handleSelectWorkspaceByNumberShortcutAction(event: event)
        case .selectSurfaceByNumber:
            return handleSelectSurfaceByNumberShortcutAction(event: event)
        case .focusLeft:
            return handleFocusLeftShortcutAction(event: event)
        case .focusRight:
            return handleFocusRightShortcutAction(event: event)
        case .focusUp:
            return handleFocusUpShortcutAction(event: event)
        case .focusDown:
            return handleFocusDownShortcutAction(event: event)
        case .toggleSplitZoom:
            return handleToggleSplitZoomShortcutAction(event: event)
        case .splitRight:
            return handleSplitRightShortcutAction(event: event)
        case .splitDown:
            return handleSplitDownShortcutAction(event: event)
        case .splitBrowserRight:
            return handleSplitBrowserRightShortcutAction(event: event)
        case .splitBrowserDown:
            return handleSplitBrowserDownShortcutAction(event: event)
        case .newSurface:
            return handleNewSurfaceShortcutAction(event: event)
        case .openBrowser:
            return handleOpenBrowserShortcutAction(event: event)
        case .focusBrowserAddressBar:
            return handleFocusBrowserAddressBarShortcutAction(event: event)
        case .browserBack:
            return handleBrowserBackShortcutAction(event: event)
        case .browserForward:
            return handleBrowserForwardShortcutAction(event: event)
        case .browserReload:
            return handleBrowserReloadShortcutAction(event: event)
        case .toggleBrowserDeveloperTools:
            return handleToggleBrowserDeveloperToolsShortcutAction(event: event)
        case .showBrowserJavaScriptConsole:
            return handleShowBrowserJavaScriptConsoleShortcutAction(event: event)
        case .browserZoomIn:
            return handleBrowserZoomInShortcutAction(event: event)
        case .browserZoomOut:
            return handleBrowserZoomOutShortcutAction(event: event)
        case .browserZoomReset:
            return handleBrowserZoomResetShortcutAction(event: event)
        case .find:
            return handleFindShortcutAction(event: event)
        case .findNext:
            return handleFindNextShortcutAction(event: event)
        case .findPrevious:
            return handleFindPreviousShortcutAction(event: event)
        case .hideFind:
            return handleHideFindShortcutAction(event: event)
        case .useSelectionForFind:
            return handleUseSelectionForFindShortcutAction(event: event)
        case .reopenClosedBrowserPanel:
            return handleReopenClosedBrowserPanelShortcutAction(event: event)
        case .openReview:
            return handleOpenReviewShortcutAction(event: event)
        case .openAgentOverview:
            guard matchConfiguredShortcut(event: event, action: .openAgentOverview) else { return nil }
            guard let context = preferredMainWindowContextForShortcuts(event: event) else { return true }
            AgentOverviewWindowController.shared.show(tabManager: context.tabManager, workspaceId: nil)
            return true
        }
    }

    private func handleCommandPaletteShortcutAction(event: NSEvent, commandPaletteTargetWindow: NSWindow?) -> Bool? {
        guard matchConfiguredShortcut(event: event, action: .commandPalette) else { return nil }
        let targetWindow = commandPaletteTargetWindow ?? event.window ?? NSApp.keyWindow ?? NSApp.mainWindow
        requestCommandPaletteCommands(preferredWindow: targetWindow, source: "shortcut.commandPalette")
        return true
    }

    private func handleOpenReviewShortcutAction(event: NSEvent) -> Bool? {
        guard matchConfiguredShortcut(event: event, action: .openReview) else { return nil }
        guard let workspace = tabManager?.selectedWorkspace,
              let focusedPanelId = workspace.focusedPanelId else { return true }
        _ = workspace.newReviewSplit(from: focusedPanelId, orientation: .horizontal, focus: true)
        return true
    }

    private func handleGoToWorkspaceShortcutAction(
        event: NSEvent,
        commandPaletteTargetWindow: NSWindow?,
        hasFocusedAddressBarInShortcutContext: Bool
    ) -> Bool? {
        guard !hasFocusedAddressBarInShortcutContext,
              matchConfiguredShortcut(event: event, action: .goToWorkspace) else { return nil }
        let targetWindow = commandPaletteTargetWindow ?? event.window ?? NSApp.keyWindow ?? NSApp.mainWindow
        requestCommandPaletteSwitcher(preferredWindow: targetWindow, source: "shortcut.goToWorkspace")
        return true
    }

    private func handleQuitShortcutAction(event: NSEvent) -> Bool? {
        guard matchConfiguredShortcut(event: event, action: .quit) else { return nil }
        return handleQuitShortcutWarning()
    }

    private func handleOpenSettingsShortcutAction(event: NSEvent) -> Bool? {
        guard matchConfiguredShortcut(event: event, action: .openSettings) else { return nil }
        openPreferencesWindow(debugSource: "shortcut.openSettings")
        return true
    }

    private func handleReloadConfigurationShortcutAction(event: NSEvent) -> Bool? {
        guard matchConfiguredShortcut(event: event, action: .reloadConfiguration) else { return nil }
        GhosttyApp.shared.reloadConfiguration(source: "shortcut.reloadConfiguration")
        return true
    }

    private func handleToggleFullScreenShortcutAction(event: NSEvent) -> Bool? {
        guard matchConfiguredShortcut(event: event, action: .toggleFullScreen) else { return nil }
        guard let targetWindow = mainWindowForShortcutEvent(event) else {
            return false
        }
        targetWindow.toggleFullScreen(nil)
        return true
    }

    private func handleToggleSidebarShortcutAction(event: NSEvent) -> Bool? {
        guard matchConfiguredShortcut(event: event, action: .toggleSidebar) else { return nil }
        _ = toggleSidebarInActiveMainWindow()
        return true
    }

    private func handleNewTabShortcutAction(event: NSEvent) -> Bool? {
        guard matchConfiguredShortcut(event: event, action: .newTab) else { return nil }
        if reopenMostRecentlyHiddenMainWindow() { return true }
#if DEBUG
        dlog("shortcut.action name=newWorkspace \(debugShortcutRouteSnapshot(event: event))")
#endif
        // Cmd+N semantics:
        // - If there are no main windows, create a new window.
        // - Otherwise, create a new workspace in the active window.
        if mainWindowContexts.isEmpty {
            #if DEBUG
            logWorkspaceCreationRouting(
                phase: "fallback_new_window",
                source: "shortcut.cmdN",
                reason: "no_main_windows",
                event: event,
                chosenContext: nil
            )
            #endif
            openNewMainWindow(nil)
        } else if addWorkspaceInPreferredMainWindow(event: event, debugSource: "shortcut.cmdN") == nil {
            #if DEBUG
            logWorkspaceCreationRouting(
                phase: "fallback_new_window",
                source: "shortcut.cmdN",
                reason: "workspace_creation_returned_nil",
                event: event,
                chosenContext: nil
            )
            #endif
            openNewMainWindow(nil)
        }
        return true
    }

    // New Claude Code Workspace: Cmd+Shift+C
    // Instantly creates a new workspace in the current workspace's working
    // directory and boots Claude Code into it (no pool, no hidden workspace). Refs #137.
    private func handleNewClaudeWorkspaceShortcutAction(event: NSEvent) -> Bool? {
        guard matchConfiguredShortcut(event: event, action: .newClaudeWorkspace) else { return nil }
#if DEBUG
        dlog("shortcut.action name=newClaudeWorkspace \(debugShortcutRouteSnapshot(event: event))")
#endif
        createClaudeWorkspace(event: event, debugSource: "shortcut.cmdShiftC")
        return true
    }

    // New Window: Cmd+Shift+N
    // Handled here instead of relying on SwiftUI's CommandGroup menu item because
    // after a browser panel has been shown, SwiftUI's menu dispatch can silently
    // consume the key equivalent without firing the action closure.
    private func handleNewWindowShortcutAction(event: NSEvent) -> Bool? {
        guard matchConfiguredShortcut(event: event, action: .newWindow) else { return nil }
        openNewMainWindow(nil)
        return true
    }

    // Open Folder: Cmd+O
    // Handled here to prevent AppKit's default NSDocumentController from opening
    // the Documents folder when SwiftUI menu dispatch fails due to focus bugs.
    private func handleOpenFolderShortcutAction(event: NSEvent) -> Bool? {
        guard matchConfiguredShortcut(event: event, action: .openFolder) else { return nil }
        showOpenFolderPanel()
        return true
    }

    private func handleShowNotificationsShortcutAction(event: NSEvent) -> Bool? {
        guard matchConfiguredShortcut(event: event, action: .showNotifications) else { return nil }
        toggleNotificationsPopover(animated: false, anchorView: fullscreenControlsViewModel?.notificationsAnchorView)
        return true
    }

    private func handleSendFeedbackShortcutAction(event: NSEvent) -> Bool? {
        guard matchConfiguredShortcut(event: event, action: .sendFeedback) else { return nil }
        guard let targetContext = preferredMainWindowContextForShortcuts(event: event),
              let targetWindow = targetContext.window ?? windowForMainWindowId(targetContext.windowId) else {
            return false
        }
        setActiveMainWindow(targetWindow)
        bringToFront(targetWindow)
        NotificationCenter.default.post(name: .feedbackComposerRequested, object: targetWindow)
        return true
    }

    private func handleJumpToUnreadShortcutAction(event: NSEvent) -> Bool? {
        guard matchConfiguredShortcut(event: event, action: .jumpToUnread) else { return nil }
#if DEBUG
        if ProcessInfo.processInfo.environment["PROGRAMA_UI_TEST_JUMP_UNREAD_SETUP"] == "1" {
            writeJumpUnreadTestData(["jumpUnreadShortcutHandled": "1"])
        }
#endif
        jumpToLatestUnread()
        return true
    }

    // Flash the currently focused panel so the user can visually confirm focus.
    private func handleTriggerFlashShortcutAction(event: NSEvent) -> Bool? {
        guard matchConfiguredShortcut(event: event, action: .triggerFlash) else { return nil }
        tabManager?.triggerFocusFlash()
        return true
    }

    // Surface navigation: Cmd+Shift+] / Cmd+Shift+[
    private func handleNextSurfaceShortcutAction(event: NSEvent) -> Bool? {
        guard matchConfiguredShortcut(event: event, action: .nextSurface) else { return nil }
        tabManager?.selectNextSurface()
        return true
    }

    private func handlePrevSurfaceShortcutAction(event: NSEvent) -> Bool? {
        guard matchConfiguredShortcut(event: event, action: .prevSurface) else { return nil }
        tabManager?.selectPreviousSurface()
        return true
    }

    private func handleToggleTerminalCopyModeShortcutAction(event: NSEvent) -> Bool? {
        guard matchConfiguredShortcut(event: event, action: .toggleTerminalCopyMode) else { return nil }
        let handled = tabManager?.toggleFocusedTerminalCopyMode() ?? false
#if DEBUG
        dlog(
            "shortcut.action name=toggleTerminalCopyMode handled=\(handled ? 1 : 0) " +
            "\(debugShortcutRouteSnapshot(event: event))"
        )
#endif
        // Only consume when a focused terminal actually handled the toggle.
        // Otherwise allow the event to continue through the responder chain.
        return handled
    }

    // Workspace navigation: Cmd+Ctrl+] / Cmd+Ctrl+[
    private func handleNextSidebarTabShortcutAction(event: NSEvent) -> Bool? {
        guard matchConfiguredShortcut(event: event, action: .nextSidebarTab) else { return nil }
#if DEBUG
        let selected = tabManager?.selectedTabId.map { String($0.uuidString.prefix(5)) } ?? "nil"
        dlog(
            "ws.shortcut dir=next repeat=\(event.isARepeat ? 1 : 0) keyCode=\(event.keyCode) selected=\(selected)"
        )
#endif
        tabManager?.selectNextTab()
        return true
    }

    private func handlePrevSidebarTabShortcutAction(event: NSEvent) -> Bool? {
        guard matchConfiguredShortcut(event: event, action: .prevSidebarTab) else { return nil }
#if DEBUG
        let selected = tabManager?.selectedTabId.map { String($0.uuidString.prefix(5)) } ?? "nil"
        dlog(
            "ws.shortcut dir=prev repeat=\(event.isARepeat ? 1 : 0) keyCode=\(event.keyCode) selected=\(selected)"
        )
#endif
        tabManager?.selectPreviousTab()
        return true
    }

    private func handleRenameWorkspaceShortcutAction(event: NSEvent, commandPaletteTargetWindow: NSWindow?) -> Bool? {
        guard matchConfiguredShortcut(event: event, action: .renameWorkspace) else { return nil }
        return requestRenameWorkspaceViaCommandPalette(
            preferredWindow: commandPaletteTargetWindow ?? event.window ?? NSApp.keyWindow ?? NSApp.mainWindow
        )
    }

    private func handleEditWorkspaceDescriptionShortcutAction(event: NSEvent, commandPaletteTargetWindow: NSWindow?) -> Bool? {
        guard matchConfiguredShortcut(event: event, action: .editWorkspaceDescription) else { return nil }
#if DEBUG
        dlog(
            "shortcut.editWorkspaceDescription matched target={\(debugWindowToken(commandPaletteTargetWindow ?? event.window ?? NSApp.keyWindow ?? NSApp.mainWindow))} " +
            "\(debugShortcutRouteSnapshot(event: event))"
        )
#endif
        return requestEditWorkspaceDescriptionViaCommandPalette(
            preferredWindow: commandPaletteTargetWindow ?? event.window ?? NSApp.keyWindow ?? NSApp.mainWindow
        )
    }

    private func handleCloseOtherTabsInPaneShortcutAction(event: NSEvent) -> Bool? {
        guard matchConfiguredShortcut(event: event, action: .closeOtherTabsInPane) else { return nil }
        if let targetWindow = event.window ?? NSApp.keyWindow ?? NSApp.mainWindow,
           targetWindow.identifier?.rawValue == "cmux.settings" {
            targetWindow.performClose(nil)
        } else {
            let targetWindow = event.window ?? NSApp.keyWindow ?? NSApp.mainWindow
            if let terminalContext = focusedTerminalShortcutContext(preferredWindow: targetWindow) {
                terminalContext.tabManager.closeOtherTabsInFocusedPaneWithConfirmation()
            } else {
                tabManager?.closeOtherTabsInFocusedPaneWithConfirmation()
            }
        }
        return true
    }

    // Cmd+W must close the focused panel even if first-responder momentarily lags on a
    // browser NSTextView during split focus transitions.
    private func handleCloseTabShortcutAction(event: NSEvent) -> Bool? {
        guard matchConfiguredShortcut(event: event, action: .closeTab) else { return nil }
        let targetWindow = resolvedShortcutEventWindow(event) ?? NSApp.keyWindow ?? NSApp.mainWindow
        let routedManager = preferredMainWindowContextForShortcutRouting(event: event)?.tabManager ?? tabManager
        // Browser popup windows primarily intercept Cmd+W in BrowserPopupPanel.
        // This AppDelegate path is a fallback for cases where AppKit routes the
        // event through the global shortcut handler first.
        if let targetWindow = [targetWindow, NSApp.keyWindow]
            .compactMap({ $0 })
            .first(where: { $0.identifier?.rawValue == "programa.browser-popup" }) {
#if DEBUG
            dlog("shortcut.cmdW route=browserPopup")
#endif
            targetWindow.performClose(nil)
            return true
        } else if let targetWindow,
           programaWindowShouldOwnCloseShortcut(targetWindow) {
            targetWindow.performClose(nil)
        } else {
            if let routedManager {
#if DEBUG
                let selectedWorkspace = routedManager.selectedWorkspace
                dlog(
                    "shortcut.cmdW route=workspaceModel workspace=\(selectedWorkspace?.id.uuidString.prefix(5) ?? "nil") " +
                    "panel=\(selectedWorkspace?.focusedPanelId?.uuidString.prefix(5) ?? "nil") " +
                    "selected=\(routedManager.selectedTabId?.uuidString.prefix(5) ?? "nil")"
                )
#endif
                routedManager.closeCurrentPanelWithConfirmation()
            } else {
#if DEBUG
                dlog("shortcut.cmdW route=noManager")
#endif
                return false
            }
        }
        return true
    }

    private func handleCloseWorkspaceShortcutAction(event: NSEvent) -> Bool? {
        guard matchConfiguredShortcut(event: event, action: .closeWorkspace) else { return nil }
        tabManager?.closeCurrentWorkspaceWithConfirmation()
        return true
    }

    private func handleCloseWindowShortcutAction(event: NSEvent) -> Bool? {
        guard matchConfiguredShortcut(event: event, action: .closeWindow) else { return nil }
        // `event.window` is often nil for synthetic/XCUITest key events that only carry a
        // windowNumber; fall back through the same windowNumber-aware resolver the rest of
        // the shortcut-routing code uses so Cmd+Ctrl+W targets the event's actual window
        // instead of silently no-op'ing when NSApp.keyWindow/mainWindow are stale.
        guard let targetWindow = mainWindowForShortcutEvent(event) ?? event.window ?? NSApp.keyWindow ?? NSApp.mainWindow else {
            NSSound.beep()
            return true
        }
        targetWindow.close()
        return true
    }

    private func handleRenameTabShortcutAction(event: NSEvent, commandPaletteTargetWindow: NSWindow?) -> Bool? {
        guard matchConfiguredShortcut(event: event, action: .renameTab) else { return nil }
        // Keep Cmd+R browser reload behavior when a browser panel is focused.
        if tabManager?.focusedBrowserPanel != nil {
            return false
        }
        let targetWindow = commandPaletteTargetWindow ?? event.window ?? NSApp.keyWindow ?? NSApp.mainWindow
        requestCommandPaletteRenameTab(preferredWindow: targetWindow, source: "shortcut.renameTab")
        return true
    }

    // Numeric shortcuts for specific workspaces (9 = last workspace)
    // Always consume the event when the digit matches to prevent Ghostty's
    // goto_tab fallback from creating a new window when the index is out of bounds.
    private func handleSelectWorkspaceByNumberShortcutAction(event: NSEvent) -> Bool? {
        guard let digit = numberedConfiguredShortcutDigit(event: event, action: .selectWorkspaceByNumber) else { return nil }
        if let manager = tabManager,
           let targetIndex = WorkspaceShortcutMapper.workspaceIndex(forDigit: digit, workspaceCount: manager.tabs.count) {
#if DEBUG
            dlog(
                "shortcut.action name=workspaceDigit digit=\(digit) targetIndex=\(targetIndex) manager=\(debugManagerToken(manager)) \(debugShortcutRouteSnapshot(event: event))"
            )
#endif
            manager.selectTab(at: targetIndex)
        }
        return true
    }

    // Numeric shortcuts for surfaces within the focused pane (9 = last)
    private func handleSelectSurfaceByNumberShortcutAction(event: NSEvent) -> Bool? {
        guard let digit = numberedConfiguredShortcutDigit(event: event, action: .selectSurfaceByNumber) else { return nil }
        if digit == 9 {
            tabManager?.selectLastSurface()
        } else {
            tabManager?.selectSurface(at: digit - 1)
        }
        return true
    }

    // Pane focus navigation (defaults to Cmd+Option+Arrow, but can be customized to letter/number keys).
    // Shared by the four directional focus actions below -- they differ only by arrow glyph/key code,
    // NavigationDirection, the configured ghostty goto_split shortcut to also match against, and which
    // direction to record for goto_split debug telemetry.
    private func handleDirectionalFocusShortcutAction(
        event: NSEvent,
        action: KeyboardShortcutSettings.Action,
        arrowGlyph: String,
        arrowKeyCode: UInt16,
        direction: NavigationDirection,
        ghosttyGotoSplitShortcut: StoredShortcut?
    ) -> Bool? {
        guard matchConfiguredDirectionalShortcut(
            event: event,
            action: action,
            arrowGlyph: arrowGlyph,
            arrowKeyCode: arrowKeyCode
        ) || (ghosttyGotoSplitShortcut.map {
            matchDirectionalShortcut(event: event, shortcut: $0, arrowGlyph: arrowGlyph, arrowKeyCode: arrowKeyCode)
        } ?? false) else { return nil }
        tabManager?.movePaneFocus(direction: direction)
#if DEBUG
        recordGotoSplitMoveIfNeeded(direction: direction)
#endif
        return true
    }

    private func handleFocusLeftShortcutAction(event: NSEvent) -> Bool? {
        handleDirectionalFocusShortcutAction(
            event: event,
            action: .focusLeft,
            arrowGlyph: "←",
            arrowKeyCode: 123,
            direction: .left,
            ghosttyGotoSplitShortcut: ghosttyGotoSplitLeftShortcut
        )
    }

    private func handleFocusRightShortcutAction(event: NSEvent) -> Bool? {
        handleDirectionalFocusShortcutAction(
            event: event,
            action: .focusRight,
            arrowGlyph: "→",
            arrowKeyCode: 124,
            direction: .right,
            ghosttyGotoSplitShortcut: ghosttyGotoSplitRightShortcut
        )
    }

    private func handleFocusUpShortcutAction(event: NSEvent) -> Bool? {
        handleDirectionalFocusShortcutAction(
            event: event,
            action: .focusUp,
            arrowGlyph: "↑",
            arrowKeyCode: 126,
            direction: .up,
            ghosttyGotoSplitShortcut: ghosttyGotoSplitUpShortcut
        )
    }

    private func handleFocusDownShortcutAction(event: NSEvent) -> Bool? {
        handleDirectionalFocusShortcutAction(
            event: event,
            action: .focusDown,
            arrowGlyph: "↓",
            arrowKeyCode: 125,
            direction: .down,
            ghosttyGotoSplitShortcut: ghosttyGotoSplitDownShortcut
        )
    }

    private func handleToggleSplitZoomShortcutAction(event: NSEvent) -> Bool? {
        guard matchConfiguredShortcut(event: event, action: .toggleSplitZoom) else { return nil }
        _ = tabManager?.toggleFocusedSplitZoom()
#if DEBUG
        recordGotoSplitZoomIfNeeded()
#endif
        return true
    }

    // Split actions: Cmd+D / Cmd+Shift+D. Shared by splitRight/splitDown -- they differ only by
    // SplitDirection and the debug-log action name.
    private func handleSplitShortcutAction(
        event: NSEvent,
        action: KeyboardShortcutSettings.Action,
        direction: SplitDirection,
        debugActionName: String
    ) -> Bool? {
        guard matchConfiguredShortcut(event: event, action: action) else { return nil }
#if DEBUG
        dlog("shortcut.action name=\(debugActionName) \(debugShortcutRouteSnapshot(event: event))")
#endif
        if shouldSuppressSplitShortcutForTransientTerminalFocusState(direction: direction) {
            return true
        }
        _ = performSplitShortcut(
            direction: direction,
            preferredWindow: event.window ?? NSApp.keyWindow ?? NSApp.mainWindow
        )
        return true
    }

    private func handleSplitRightShortcutAction(event: NSEvent) -> Bool? {
        handleSplitShortcutAction(event: event, action: .splitRight, direction: .right, debugActionName: "splitRight")
    }

    private func handleSplitDownShortcutAction(event: NSEvent) -> Bool? {
        handleSplitShortcutAction(event: event, action: .splitDown, direction: .down, debugActionName: "splitDown")
    }

    // Browser split actions. Shared by splitBrowserRight/splitBrowserDown -- they differ only by
    // SplitDirection and the debug-log action name.
    private func handleBrowserSplitShortcutAction(
        event: NSEvent,
        action: KeyboardShortcutSettings.Action,
        direction: SplitDirection,
        debugActionName: String
    ) -> Bool? {
        guard matchConfiguredShortcut(event: event, action: action) else { return nil }
#if DEBUG
        dlog("shortcut.action name=\(debugActionName) \(debugShortcutRouteSnapshot(event: event))")
#endif
        _ = performBrowserSplitShortcut(direction: direction)
        return true
    }

    private func handleSplitBrowserRightShortcutAction(event: NSEvent) -> Bool? {
        handleBrowserSplitShortcutAction(event: event, action: .splitBrowserRight, direction: .right, debugActionName: "splitBrowserRight")
    }

    private func handleSplitBrowserDownShortcutAction(event: NSEvent) -> Bool? {
        handleBrowserSplitShortcutAction(event: event, action: .splitBrowserDown, direction: .down, debugActionName: "splitBrowserDown")
    }

    // New surface: Cmd+T
    private func handleNewSurfaceShortcutAction(event: NSEvent) -> Bool? {
        guard matchConfiguredShortcut(event: event, action: .newSurface) else { return nil }
        tabManager?.newSurface()
        return true
    }

    // Open browser: Cmd+Shift+L
    private func handleOpenBrowserShortcutAction(event: NSEvent) -> Bool? {
        guard matchConfiguredShortcut(event: event, action: .openBrowser) else { return nil }
        _ = openBrowserAndFocusAddressBar(insertAtEnd: true)
        return true
    }

    private func handleFocusBrowserAddressBarShortcutAction(event: NSEvent) -> Bool? {
        guard matchConfiguredShortcut(event: event, action: .focusBrowserAddressBar) else { return nil }
        if let focusedPanel = tabManager?.focusedBrowserPanel {
            focusBrowserAddressBar(in: focusedPanel)
            return true
        }

        if let browserAddressBarFocusedPanelId,
           focusBrowserAddressBar(panelId: browserAddressBarFocusedPanelId) {
            return true
        }

        if openBrowserAndFocusAddressBar(insertAtEnd: true) != nil {
            return true
        }

        // Matched but none of the branches above handled it -- fall through to the next action in
        // precedence order, exactly like the original if-chain (which had no trailing `return`
        // statement in this specific case and so fell out of the enclosing `if` block).
        return nil
    }

    private func handleBrowserBackShortcutAction(event: NSEvent) -> Bool? {
        guard matchConfiguredShortcut(event: event, action: .browserBack) else { return nil }
        guard let focusedBrowserPanel = tabManager?.focusedBrowserPanel else {
            return false
        }
        focusedBrowserPanel.goBack()
        return true
    }

    private func handleBrowserForwardShortcutAction(event: NSEvent) -> Bool? {
        guard matchConfiguredShortcut(event: event, action: .browserForward) else { return nil }
        guard let focusedBrowserPanel = tabManager?.focusedBrowserPanel else {
            return false
        }
        focusedBrowserPanel.goForward()
        return true
    }

    private func handleBrowserReloadShortcutAction(event: NSEvent) -> Bool? {
        guard matchConfiguredShortcut(event: event, action: .browserReload) else { return nil }
        guard let focusedBrowserPanel = tabManager?.focusedBrowserPanel else {
            return false
        }
        focusedBrowserPanel.reload()
        return true
    }

    // Safari defaults:
    // - Option+Command+I => Show/Toggle Web Inspector
    // - Option+Command+C => Show JavaScript Console
    private func handleToggleBrowserDeveloperToolsShortcutAction(event: NSEvent) -> Bool? {
        guard matchConfiguredShortcut(event: event, action: .toggleBrowserDeveloperTools) else { return nil }
#if DEBUG
        logDeveloperToolsShortcutSnapshot(phase: "toggle.pre", event: event)
#endif
        let didHandle = tabManager?.toggleDeveloperToolsFocusedBrowser() ?? false
#if DEBUG
        logDeveloperToolsShortcutSnapshot(phase: "toggle.post", event: event, didHandle: didHandle)
        DispatchQueue.main.async { [weak self] in
            self?.logDeveloperToolsShortcutSnapshot(phase: "toggle.tick", didHandle: didHandle)
        }
#endif
        if !didHandle { NSSound.beep() }
        return true
    }

    private func handleShowBrowserJavaScriptConsoleShortcutAction(event: NSEvent) -> Bool? {
        guard matchConfiguredShortcut(event: event, action: .showBrowserJavaScriptConsole) else { return nil }
#if DEBUG
        logDeveloperToolsShortcutSnapshot(phase: "console.pre", event: event)
#endif
        let didHandle = tabManager?.showJavaScriptConsoleFocusedBrowser() ?? false
#if DEBUG
        logDeveloperToolsShortcutSnapshot(phase: "console.post", event: event, didHandle: didHandle)
        DispatchQueue.main.async { [weak self] in
            self?.logDeveloperToolsShortcutSnapshot(phase: "console.tick", didHandle: didHandle)
        }
#endif
        if !didHandle { NSSound.beep() }
        return true
    }

    // Browser zoom actions. Shared by browserZoomIn/Out/Reset -- they differ only by which
    // TabManager zoom method to invoke.
    private func handleBrowserZoomShortcutAction(
        event: NSEvent,
        action: KeyboardShortcutSettings.Action,
        zoom: (TabManager) -> Bool
    ) -> Bool? {
        guard matchConfiguredShortcut(event: event, action: action) else { return nil }
        guard let tabManager else { return false }
        return zoom(tabManager)
    }

    private func handleBrowserZoomInShortcutAction(event: NSEvent) -> Bool? {
        handleBrowserZoomShortcutAction(event: event, action: .browserZoomIn) { $0.zoomInFocusedBrowser() }
    }

    private func handleBrowserZoomOutShortcutAction(event: NSEvent) -> Bool? {
        handleBrowserZoomShortcutAction(event: event, action: .browserZoomOut) { $0.zoomOutFocusedBrowser() }
    }

    private func handleBrowserZoomResetShortcutAction(event: NSEvent) -> Bool? {
        handleBrowserZoomShortcutAction(event: event, action: .browserZoomReset) { $0.resetZoomFocusedBrowser() }
    }

    private func handleFindShortcutAction(event: NSEvent) -> Bool? {
        guard matchConfiguredShortcut(event: event, action: .find) else { return nil }
        guard !shouldLetFocusedBrowserOwnFindShortcut(event) else {
            return false
        }
        tabManager?.startSearch()
        return true
    }

    private func handleFindNextShortcutAction(event: NSEvent) -> Bool? {
        guard matchConfiguredShortcut(event: event, action: .findNext) else { return nil }
        guard !shouldLetFocusedBrowserOwnFindShortcut(event) else {
            return false
        }
        tabManager?.findNext()
        return true
    }

    private func handleFindPreviousShortcutAction(event: NSEvent) -> Bool? {
        guard matchConfiguredShortcut(event: event, action: .findPrevious) else { return nil }
        guard !shouldLetFocusedBrowserOwnFindShortcut(event) else {
            return false
        }
        tabManager?.findPrevious()
        return true
    }

    private func handleHideFindShortcutAction(event: NSEvent) -> Bool? {
        guard matchConfiguredShortcut(event: event, action: .hideFind) else { return nil }
        guard !shouldLetFocusedBrowserOwnFindShortcut(event) else {
            return false
        }
        tabManager?.hideFind()
        return true
    }

    private func handleUseSelectionForFindShortcutAction(event: NSEvent) -> Bool? {
        guard matchConfiguredShortcut(event: event, action: .useSelectionForFind) else { return nil }
        tabManager?.searchSelection()
        return true
    }

    private func handleReopenClosedBrowserPanelShortcutAction(event: NSEvent) -> Bool? {
        guard matchConfiguredShortcut(event: event, action: .reopenClosedBrowserPanel) else { return nil }
        _ = tabManager?.reopenMostRecentlyClosedBrowserPanel()
        return true
    }

    private func shouldSuppressSplitShortcutForTransientTerminalFocusState(direction: SplitDirection) -> Bool {
        guard let tabManager,
              let workspace = tabManager.selectedWorkspace,
              let focusedPanelId = workspace.focusedPanelId,
              let terminalPanel = workspace.terminalPanel(for: focusedPanelId) else {
            return false
        }

        let hostedView = terminalPanel.hostedView
        let hostedSize = hostedView.bounds.size
        let hostedHiddenInHierarchy = hostedView.isHiddenOrHasHiddenAncestor
        let hostedAttachedToWindow = hostedView.window != nil
        let firstResponderIsWindow = NSApp.keyWindow?.firstResponder is NSWindow

        let shouldSuppress = shouldSuppressSplitShortcutForTransientTerminalFocusInputs(
            firstResponderIsWindow: firstResponderIsWindow,
            hostedSize: hostedSize,
            hostedHiddenInHierarchy: hostedHiddenInHierarchy,
            hostedAttachedToWindow: hostedAttachedToWindow
        )
        guard shouldSuppress else { return false }

        tabManager.reconcileFocusedPanelFromFirstResponderForKeyboard()

#if DEBUG
        let directionLabel: String
        switch direction {
        case .left: directionLabel = "left"
        case .right: directionLabel = "right"
        case .up: directionLabel = "up"
        case .down: directionLabel = "down"
        }
        let firstResponderType = NSApp.keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        dlog(
            "split.shortcut suppressed dir=\(directionLabel) reason=transient_focus_state " +
            "fr=\(firstResponderType) hidden=\(hostedHiddenInHierarchy ? 1 : 0) " +
            "attached=\(hostedAttachedToWindow ? 1 : 0) " +
            "frame=\(String(format: "%.1fx%.1f", hostedSize.width, hostedSize.height))"
        )
#endif
        return true
    }

#if DEBUG
    private func logBrowserZoomShortcutTrace(
        stage: String,
        event: NSEvent,
        flags: NSEvent.ModifierFlags,
        chars: String,
        action: BrowserZoomShortcutAction? = nil,
        handled: Bool? = nil
    ) {
        guard browserZoomShortcutTraceCandidate(
            flags: flags,
            chars: chars,
            keyCode: event.keyCode,
            literalChars: event.characters
        ) else {
            return
        }

        let keyWindow = NSApp.keyWindow
        let firstResponderType = keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        let panel = tabManager?.focusedBrowserPanel
        let panelToken = panel.map { String($0.id.uuidString.prefix(8)) } ?? "nil"
        let panelZoom = panel?.webView.pageZoom ?? -1
        var line =
            "zoom.shortcut stage=\(stage) event=\(NSWindow.keyDescription(event)) " +
            "chars='\(chars)' flags=\(browserZoomShortcutTraceFlagsString(flags)) " +
            "action=\(browserZoomShortcutTraceActionString(action)) keyWin=\(keyWindow?.windowNumber ?? -1) " +
            "fr=\(firstResponderType) panel=\(panelToken) zoom=\(String(format: "%.3f", panelZoom)) " +
            "addrBarId=\(browserAddressBarFocusedPanelId?.uuidString.prefix(8) ?? "nil")"
        if let handled {
            line += " handled=\(handled ? 1 : 0)"
        }
        dlog(line)
    }

    private func browserFocusStateSnapshot() -> String {
        let selected = tabManager?.selectedTabId.map { String($0.uuidString.prefix(5)) } ?? "nil"
        let focused = tabManager?.selectedWorkspace?.focusedPanelId.map { String($0.uuidString.prefix(5)) } ?? "nil"
        let addressBar = browserAddressBarFocusedPanelId.map { String($0.uuidString.prefix(5)) } ?? "nil"
        let keyWindow = NSApp.keyWindow?.windowNumber ?? -1
        let firstResponderType = NSApp.keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        return "selected=\(selected) focused=\(focused) addr=\(addressBar) keyWin=\(keyWindow) fr=\(firstResponderType)"
    }

    private func redactedDebugURL(_ url: URL?) -> String {
        guard let url else { return "nil" }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return "<invalid>"
        }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.string ?? "<redacted>"
    }
#endif

    @discardableResult
    private func focusBrowserAddressBar(panelId: UUID) -> Bool {
        guard let tabManager,
              let workspace = tabManager.selectedWorkspace,
              let panel = workspace.browserPanel(for: panelId) else {
#if DEBUG
            dlog(
                "browser.focus.addressBar.route panel=\(panelId.uuidString.prefix(5)) " +
                "result=miss \(browserFocusStateSnapshot())"
            )
#endif
            return false
        }
#if DEBUG
        dlog(
            "browser.focus.addressBar.route panel=\(panel.id.uuidString.prefix(5)) " +
            "workspace=\(workspace.id.uuidString.prefix(5)) result=hit \(browserFocusStateSnapshot())"
        )
#endif
        workspace.focusPanel(panel.id)
#if DEBUG
        let focusedAfter = workspace.focusedPanelId.map { String($0.uuidString.prefix(5)) } ?? "nil"
        dlog(
            "browser.focus.addressBar.route panel=\(panel.id.uuidString.prefix(5)) " +
            "workspace=\(workspace.id.uuidString.prefix(5)) focusedAfter=\(focusedAfter)"
        )
#endif
        focusBrowserAddressBar(in: panel)
        return true
    }

    @discardableResult
    func openBrowserAndFocusAddressBar(url: URL? = nil, insertAtEnd: Bool = false) -> UUID? {
        let preferredProfileID =
            tabManager?.focusedBrowserPanel?.profileID
            ?? tabManager?.selectedWorkspace?.preferredBrowserProfileID
        guard let panelId = tabManager?.openBrowser(
            url: url,
            preferredProfileID: preferredProfileID,
            insertAtEnd: insertAtEnd
        ) else {
#if DEBUG
            dlog(
                "browser.focus.openAndFocus result=open_failed insertAtEnd=\(insertAtEnd ? 1 : 0) " +
                "url=\(redactedDebugURL(url)) \(browserFocusStateSnapshot())"
            )
#endif
            return nil
        }
#if DEBUG
        dlog(
            "browser.focus.openAndFocus result=open_ok panel=\(panelId.uuidString.prefix(5)) " +
            "insertAtEnd=\(insertAtEnd ? 1 : 0) url=\(redactedDebugURL(url))"
        )
#endif
#if DEBUG
        let didFocus = focusBrowserAddressBar(panelId: panelId)
        dlog(
            "browser.focus.openAndFocus result=focus_request panel=\(panelId.uuidString.prefix(5)) " +
            "focused=\(didFocus ? 1 : 0) \(browserFocusStateSnapshot())"
        )
#else
        _ = focusBrowserAddressBar(panelId: panelId)
#endif
        return panelId
    }

    private func focusBrowserAddressBar(in panel: BrowserPanel) {
#if DEBUG
        let requestId = panel.requestAddressBarFocus()
        dlog(
            "browser.focus.addressBar.request panel=\(panel.id.uuidString.prefix(5)) " +
            "request=\(requestId.uuidString.prefix(8)) \(browserFocusStateSnapshot())"
        )
#else
        _ = panel.requestAddressBarFocus()
#endif
        browserAddressBarFocusedPanelId = panel.id
#if DEBUG
        dlog(
            "browser.focus.addressBar.sticky panel=\(panel.id.uuidString.prefix(5)) " +
            "request=\(requestId.uuidString.prefix(8)) \(browserFocusStateSnapshot())"
        )
#endif
        NotificationCenter.default.post(name: .browserFocusAddressBar, object: panel.id)
#if DEBUG
        dlog(
            "browser.focus.addressBar.notify panel=\(panel.id.uuidString.prefix(5)) " +
            "request=\(requestId.uuidString.prefix(8))"
        )
#endif
    }

    func focusedBrowserAddressBarPanelId() -> UUID? {
        browserAddressBarFocusedPanelId
    }

    private func focusedBrowserAddressBarPanelIdForShortcutEvent(_ event: NSEvent) -> UUID? {
        guard let panelId = browserAddressBarFocusedPanelId else { return nil }

        guard let context = preferredMainWindowContextForShortcutRouting(event: event) else {
#if DEBUG
            dlog(
                "browser.focus.addressBar.shortcutContext panel=\(panelId.uuidString.prefix(5)) " +
                "accepted=0 reason=no_context event=\(NSWindow.keyDescription(event))"
            )
#endif
            return nil
        }

        guard let workspace = context.tabManager.selectedWorkspace else {
#if DEBUG
            dlog(
                "browser.focus.addressBar.shortcutContext panel=\(panelId.uuidString.prefix(5)) " +
                "accepted=0 reason=no_workspace event=\(NSWindow.keyDescription(event))"
            )
#endif
            return nil
        }

        guard workspace.browserPanel(for: panelId) != nil else {
#if DEBUG
            dlog(
                "browser.focus.addressBar.shortcutContext panel=\(panelId.uuidString.prefix(5)) " +
                "accepted=0 reason=panel_not_in_workspace workspace=\(workspace.id.uuidString.prefix(5)) " +
                "event=\(NSWindow.keyDescription(event))"
            )
#endif
            return nil
        }

#if DEBUG
        dlog(
            "browser.focus.addressBar.shortcutContext panel=\(panelId.uuidString.prefix(5)) " +
            "accepted=1 workspace=\(workspace.id.uuidString.prefix(5)) event=\(NSWindow.keyDescription(event))"
        )
#endif
        return panelId
    }

    @discardableResult
    func requestBrowserAddressBarFocus(panelId: UUID) -> Bool {
        focusBrowserAddressBar(panelId: panelId)
    }

    private func shouldBypassAppShortcutForFocusedBrowserAddressBar(
        flags: NSEvent.ModifierFlags,
        chars: String
    ) -> Bool {
        guard browserAddressBarFocusedPanelId != nil else { return false }
        let normalizedFlags = browserOmnibarNormalizedModifierFlags(flags)
        let isCommandOrControlOnly = normalizedFlags == [.command] || normalizedFlags == [.control]
        guard isCommandOrControlOnly else { return false }
        let shouldBypass = chars == "n" || chars == "p"
#if DEBUG
        if shouldBypass {
            let panelToken = browserAddressBarFocusedPanelId.map { String($0.uuidString.prefix(5)) } ?? "nil"
            dlog(
                "browser.focus.addressBar.shortcutBypass panel=\(panelToken) " +
                "chars=\(chars) flags=\(normalizedFlags.rawValue)"
            )
        }
#endif
        return shouldBypass
    }

    private func commandOmnibarSelectionDelta(
        flags: NSEvent.ModifierFlags,
        chars: String
    ) -> Int? {
        browserOmnibarSelectionDeltaForCommandNavigation(
            hasFocusedAddressBar: browserAddressBarFocusedPanelId != nil,
            flags: flags,
            chars: chars
        )
    }

    private func dispatchBrowserOmnibarSelectionMove(delta: Int) {
        guard delta != 0 else { return }
        guard let panelId = browserAddressBarFocusedPanelId else { return }
#if DEBUG
        dlog(
            "browser.focus.omnibar.selectionMove panel=\(panelId.uuidString.prefix(5)) " +
            "delta=\(delta) repeatKey=\(browserOmnibarRepeatKeyCode.map(String.init) ?? "nil")"
        )
#endif
        NotificationCenter.default.post(
            name: .browserMoveOmnibarSelection,
            object: panelId,
            userInfo: ["delta": delta]
        )
    }

    private func startBrowserOmnibarSelectionRepeatIfNeeded(keyCode: UInt16, delta: Int) {
        guard delta != 0 else { return }
        guard browserAddressBarFocusedPanelId != nil else {
#if DEBUG
            dlog(
                "browser.focus.omnibar.repeat.start key=\(keyCode) delta=\(delta) " +
                "result=skip_no_focused_address_bar"
            )
#endif
            return
        }

        if browserOmnibarRepeatKeyCode == keyCode, browserOmnibarRepeatDelta == delta {
#if DEBUG
            let panelToken = browserAddressBarFocusedPanelId.map { String($0.uuidString.prefix(5)) } ?? "nil"
            dlog(
                "browser.focus.omnibar.repeat.start panel=\(panelToken) " +
                "key=\(keyCode) delta=\(delta) result=reuse"
            )
#endif
            return
        }

        stopBrowserOmnibarSelectionRepeat()
        browserOmnibarRepeatKeyCode = keyCode
        browserOmnibarRepeatDelta = delta
#if DEBUG
        let panelToken = browserAddressBarFocusedPanelId.map { String($0.uuidString.prefix(5)) } ?? "nil"
        dlog(
            "browser.focus.omnibar.repeat.start panel=\(panelToken) " +
            "key=\(keyCode) delta=\(delta) result=armed"
        )
#endif

        let start = DispatchWorkItem { [weak self] in
            self?.scheduleBrowserOmnibarSelectionRepeatTick()
        }
        browserOmnibarRepeatStartWorkItem = start
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: start)
    }

    private func scheduleBrowserOmnibarSelectionRepeatTick() {
        browserOmnibarRepeatStartWorkItem = nil
        guard browserAddressBarFocusedPanelId != nil else {
#if DEBUG
            dlog("browser.focus.omnibar.repeat.tick result=stop_no_focused_address_bar")
#endif
            stopBrowserOmnibarSelectionRepeat()
            return
        }
        guard browserOmnibarRepeatKeyCode != nil else { return }

#if DEBUG
        let panelToken = browserAddressBarFocusedPanelId.map { String($0.uuidString.prefix(5)) } ?? "nil"
        dlog(
            "browser.focus.omnibar.repeat.tick panel=\(panelToken) " +
            "delta=\(browserOmnibarRepeatDelta)"
        )
#endif
        dispatchBrowserOmnibarSelectionMove(delta: browserOmnibarRepeatDelta)

        let tick = DispatchWorkItem { [weak self] in
            self?.scheduleBrowserOmnibarSelectionRepeatTick()
        }
        browserOmnibarRepeatTickWorkItem = tick
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.055, execute: tick)
    }

    private func stopBrowserOmnibarSelectionRepeat() {
#if DEBUG
        let previousKeyCode = browserOmnibarRepeatKeyCode
        let previousDelta = browserOmnibarRepeatDelta
#endif
        browserOmnibarRepeatStartWorkItem?.cancel()
        browserOmnibarRepeatTickWorkItem?.cancel()
        browserOmnibarRepeatStartWorkItem = nil
        browserOmnibarRepeatTickWorkItem = nil
        browserOmnibarRepeatKeyCode = nil
        browserOmnibarRepeatDelta = 0
#if DEBUG
        if previousKeyCode != nil || previousDelta != 0 {
            dlog(
                "browser.focus.omnibar.repeat.stop key=\(previousKeyCode.map(String.init) ?? "nil") " +
                "delta=\(previousDelta)"
            )
        }
#endif
    }

    private func handleBrowserOmnibarSelectionRepeatLifecycleEvent(_ event: NSEvent) {
        guard browserOmnibarRepeatKeyCode != nil else { return }

        switch event.type {
        case .keyUp:
            if event.keyCode == browserOmnibarRepeatKeyCode {
#if DEBUG
                dlog(
                    "browser.focus.omnibar.repeat.lifecycle event=keyUp key=\(event.keyCode) " +
                    "action=stop"
                )
#endif
                stopBrowserOmnibarSelectionRepeat()
            }
        case .flagsChanged:
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if !flags.contains(.command) {
#if DEBUG
                dlog(
                    "browser.focus.omnibar.repeat.lifecycle event=flagsChanged " +
                    "flags=\(flags.rawValue) action=stop"
                )
#endif
                stopBrowserOmnibarSelectionRepeat()
            }
        default:
            break
        }
    }

    private func isLikelyWebInspectorResponder(_ responder: NSResponder?) -> Bool {
        programaIsLikelyWebInspectorResponder(responder)
    }

#if DEBUG
    private func developerToolsShortcutProbeKind(event: NSEvent) -> String? {
        if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .toggleBrowserDeveloperTools)) {
            return "toggle.configured"
        }
        if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .showBrowserJavaScriptConsole)) {
            return "console.configured"
        }

        let chars = (event.charactersIgnoringModifiers ?? "").lowercased()
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == [.command, .option] {
            if chars == "i" || event.keyCode == 34 {
                return "toggle.literal"
            }
            if chars == "c" || event.keyCode == 8 {
                return "console.literal"
            }
        }
        return nil
    }

    private func logDeveloperToolsShortcutSnapshot(
        phase: String,
        event: NSEvent? = nil,
        didHandle: Bool? = nil
    ) {
        let keyWindow = NSApp.keyWindow
        let firstResponder = keyWindow?.firstResponder
        let firstResponderType = firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        let firstResponderPtr = firstResponder.map { String(describing: Unmanaged.passUnretained($0).toOpaque()) } ?? "nil"
        let eventDescription = event.map(NSWindow.keyDescription) ?? "none"
        if let browser = tabManager?.focusedBrowserPanel {
            var line =
                "browser.devtools shortcut=\(phase) panel=\(browser.id.uuidString.prefix(5)) " +
                "\(browser.debugDeveloperToolsStateSummary()) \(browser.debugDeveloperToolsGeometrySummary()) " +
                "keyWin=\(keyWindow?.windowNumber ?? -1) fr=\(firstResponderType)@\(firstResponderPtr) event=\(eventDescription)"
            if let didHandle {
                line += " handled=\(didHandle ? 1 : 0)"
            }
            dlog(line)
            return
        }
        var line =
            "browser.devtools shortcut=\(phase) panel=nil keyWin=\(keyWindow?.windowNumber ?? -1) " +
            "fr=\(firstResponderType)@\(firstResponderPtr) event=\(eventDescription)"
        if let didHandle {
            line += " handled=\(didHandle ? 1 : 0)"
        }
        dlog(line)
    }
#endif

    private func prepareFocusedBrowserDevToolsForSplit(directionLabel: String) {
        guard let browser = tabManager?.focusedBrowserPanel else { return }
        guard browser.shouldPreserveWebViewAttachmentDuringTransientHide() else { return }
        guard let keyWindow = NSApp.keyWindow else { return }
        guard isLikelyWebInspectorResponder(keyWindow.firstResponder) else { return }

        let beforeResponder = keyWindow.firstResponder
        let movedToWebView = keyWindow.makeFirstResponder(browser.webView)
        let movedToNil = movedToWebView ? false : keyWindow.makeFirstResponder(nil)

        #if DEBUG
        let beforeType = beforeResponder.map { String(describing: type(of: $0)) } ?? "nil"
        let beforePtr = beforeResponder.map { String(describing: Unmanaged.passUnretained($0).toOpaque()) } ?? "nil"
        let afterResponder = keyWindow.firstResponder
        let afterType = afterResponder.map { String(describing: type(of: $0)) } ?? "nil"
        let afterPtr = afterResponder.map { String(describing: Unmanaged.passUnretained($0).toOpaque()) } ?? "nil"
        dlog(
            "split.shortcut inspector.preflight dir=\(directionLabel) panel=\(browser.id.uuidString.prefix(5)) " +
            "before=\(beforeType)@\(beforePtr) after=\(afterType)@\(afterPtr) " +
            "moveWeb=\(movedToWebView ? 1 : 0) moveNil=\(movedToNil ? 1 : 0) \(browser.debugDeveloperToolsStateSummary())"
        )
        #endif
    }

    @discardableResult
    func performSplitShortcut(direction: SplitDirection, preferredWindow: NSWindow? = nil) -> Bool {
        let targetWindow = preferredWindow ?? NSApp.keyWindow ?? NSApp.mainWindow
        let terminalContext = focusedTerminalShortcutContext(preferredWindow: targetWindow)
        _ = synchronizeActiveMainWindowContext(preferredWindow: targetWindow)

        let directionLabel: String
        switch direction {
        case .left: directionLabel = "left"
        case .right: directionLabel = "right"
        case .up: directionLabel = "up"
        case .down: directionLabel = "down"
        }

        #if DEBUG
        let keyWindow = NSApp.keyWindow
        let firstResponder = keyWindow?.firstResponder
        let firstResponderType = firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        let firstResponderPtr = firstResponder.map { String(describing: Unmanaged.passUnretained($0).toOpaque()) } ?? "nil"
        let firstResponderWindow: Int = {
            if let v = firstResponder as? NSView {
                return v.window?.windowNumber ?? -1
            }
            if let w = firstResponder as? NSWindow {
                return w.windowNumber
            }
            return -1
        }()
        let splitContext = "keyWin=\(keyWindow?.windowNumber ?? -1) mainWin=\(NSApp.mainWindow?.windowNumber ?? -1) fr=\(firstResponderType)@\(firstResponderPtr) frWin=\(firstResponderWindow)"
        if let browser = tabManager?.focusedBrowserPanel {
            let webWindow = browser.webView.window?.windowNumber ?? -1
            let webSuperview = browser.webView.superview.map { String(describing: Unmanaged.passUnretained($0).toOpaque()) } ?? "nil"
            dlog("split.shortcut dir=\(directionLabel) pre panel=\(browser.id.uuidString.prefix(5)) \(browser.debugDeveloperToolsStateSummary()) webWin=\(webWindow) webSuper=\(webSuperview) \(splitContext)")
        } else {
            dlog("split.shortcut dir=\(directionLabel) pre panel=nil \(splitContext)")
        }
        #endif

        prepareFocusedBrowserDevToolsForSplit(directionLabel: directionLabel)
        let didCreateSplit: Bool = {
            if let terminalContext {
                return terminalContext.tabManager.createSplit(
                    tabId: terminalContext.workspaceId,
                    surfaceId: terminalContext.panelId,
                    direction: direction
                ) != nil
            }
            return tabManager?.createSplit(direction: direction) != nil
        }()
#if DEBUG
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            let keyWindow = NSApp.keyWindow
            let firstResponder = keyWindow?.firstResponder
            let firstResponderType = firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
            let firstResponderPtr = firstResponder.map { String(describing: Unmanaged.passUnretained($0).toOpaque()) } ?? "nil"
            let firstResponderWindow: Int = {
                if let v = firstResponder as? NSView {
                    return v.window?.windowNumber ?? -1
                }
                if let w = firstResponder as? NSWindow {
                    return w.windowNumber
                }
                return -1
            }()
            let splitContext = "keyWin=\(keyWindow?.windowNumber ?? -1) mainWin=\(NSApp.mainWindow?.windowNumber ?? -1) fr=\(firstResponderType)@\(firstResponderPtr) frWin=\(firstResponderWindow)"
            if let browser = self?.tabManager?.focusedBrowserPanel {
                let webWindow = browser.webView.window?.windowNumber ?? -1
                let webSuperview = browser.webView.superview.map { String(describing: Unmanaged.passUnretained($0).toOpaque()) } ?? "nil"
                dlog("split.shortcut dir=\(directionLabel) post panel=\(browser.id.uuidString.prefix(5)) \(browser.debugDeveloperToolsStateSummary()) webWin=\(webWindow) webSuper=\(webSuperview) \(splitContext)")
            } else {
                dlog("split.shortcut dir=\(directionLabel) post panel=nil \(splitContext)")
            }
        }
        recordGotoSplitSplitIfNeeded(direction: direction)
#endif
        return didCreateSplit
    }

    @discardableResult
    func performBrowserSplitShortcut(direction: SplitDirection) -> Bool {
        _ = synchronizeActiveMainWindowContext(preferredWindow: NSApp.keyWindow ?? NSApp.mainWindow)

        #if DEBUG
        let directionLabel: String
        switch direction {
        case .left: directionLabel = "left"
        case .right: directionLabel = "right"
        case .up: directionLabel = "up"
        case .down: directionLabel = "down"
        }
        let selectedTabBefore = tabManager?.selectedTabId?.uuidString.prefix(5) ?? "nil"
        let focusedPanelBefore = tabManager?.selectedWorkspace?.focusedPanelId?.uuidString.prefix(5) ?? "nil"
        dlog(
            "split.browser.shortcut pre dir=\(directionLabel) " +
            "tab=\(selectedTabBefore) focusedPanel=\(focusedPanelBefore)"
        )
        #endif

        guard let panelId = tabManager?.createBrowserSplit(direction: direction) else {
            #if DEBUG
            dlog("split.browser.shortcut failed dir=\(directionLabel)")
            #endif
            return false
        }

        #if DEBUG
        let selectedTabAfter = tabManager?.selectedTabId?.uuidString.prefix(5) ?? "nil"
        let focusedPanelAfter = tabManager?.selectedWorkspace?.focusedPanelId?.uuidString.prefix(5) ?? "nil"
        dlog(
            "split.browser.shortcut post dir=\(directionLabel) " +
            "created=\(panelId.uuidString.prefix(5)) tab=\(selectedTabAfter) focusedPanel=\(focusedPanelAfter)"
        )
        #endif

        _ = focusBrowserAddressBar(panelId: panelId)
        return true
    }

    /// Allow AppKit-backed browser surfaces (WKWebView) to route non-menu shortcuts
    /// through the same app-level shortcut handler used by the local key monitor.
    @discardableResult
    func handleBrowserSurfaceKeyEquivalent(_ event: NSEvent) -> Bool {
        handleCustomShortcut(event: event)
    }

    @discardableResult
    func requestRenameWorkspaceViaCommandPalette(preferredWindow: NSWindow? = nil) -> Bool {
        let targetWindow = preferredWindow ?? NSApp.keyWindow ?? NSApp.mainWindow
        requestCommandPaletteRenameWorkspace(
            preferredWindow: targetWindow,
            source: "shortcut.renameWorkspace"
        )
        return true
    }

    @discardableResult
    func requestEditWorkspaceDescriptionViaCommandPalette(preferredWindow: NSWindow? = nil) -> Bool {
        let targetWindow = preferredWindow ?? NSApp.keyWindow ?? NSApp.mainWindow
#if DEBUG
        dlog(
            "shortcut.editWorkspaceDescription request target={\(debugWindowToken(targetWindow))} " +
            "fr=\(targetWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil")"
        )
#endif
        requestCommandPaletteEditWorkspaceDescription(
            preferredWindow: targetWindow,
            source: "shortcut.editWorkspaceDescription"
        )
        return true
    }

#if DEBUG
    // Debug/test hook: allow socket-driven shortcut simulation to reuse the same shortcut routing
    // logic as the local NSEvent monitor, without relying on AppKit event monitor behavior for
    // synthetic NSEvents.
    func debugHandleCustomShortcut(event: NSEvent) -> Bool {
        handleCustomShortcut(event: event)
    }

    // Debug/test hook: mirrors local monitor routing (keyDown + keyUp lifecycle).
    func debugHandleShortcutMonitorEvent(event: NSEvent) -> Bool {
        if event.type == .keyDown {
            return handleCustomShortcut(event: event)
        }
        handleBrowserOmnibarSelectionRepeatLifecycleEvent(event)
        return clearEscapeSuppressionForKeyUp(event: event, consumeIfSuppressed: true)
    }

    func debugMarkCommandPaletteOpenPending(window: NSWindow) {
        markCommandPaletteOpenRequested(for: window)
    }

    @discardableResult
    func debugSetCommandPalettePendingOpenAge(window: NSWindow, age: TimeInterval) -> Bool {
        guard let windowId = mainWindowId(for: window) else { return false }
        CommandPaletteController.windowLifecycle.markOpenRequested(
            windowId: windowId,
            now: ProcessInfo.processInfo.systemUptime - max(age, 0)
        )
        return true
    }

    // Test hook: remap a window context under a detached window key so direct
    // ObjectIdentifier(window) lookups fail and fallback logic is exercised.
    @discardableResult
    func debugInjectWindowContextKeyMismatch(windowId: UUID) -> Bool {
        guard let context = mainWindowContexts.values.first(where: { $0.windowId == windowId }),
              let window = context.window ?? windowForMainWindowId(windowId) else {
            return false
        }

        let detachedWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 16, height: 16),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        debugDetachedContextWindows.append(detachedWindow)

        let contextKeys = mainWindowContexts.compactMap { key, value in
            value === context ? key : nil
        }
        for key in contextKeys {
            mainWindowContexts.removeValue(forKey: key)
        }
        mainWindowContexts[ObjectIdentifier(detachedWindow)] = context
        context.window = window
        return true
    }
#endif

    private func findButton(in view: NSView, titled title: String) -> NSButton? {
        if let button = view as? NSButton, button.title == title {
            return button
        }
        for subview in view.subviews {
            if let found = findButton(in: subview, titled: title) {
                return found
            }
        }
        return nil
    }

    private func matchingCloseConfirmationPanel(
        in window: NSWindow?,
        titles: [String]
    ) -> NSPanel? {
        guard let panel = window as? NSPanel,
              panel.isVisible,
              let root = panel.contentView,
              titles.contains(where: { findStaticText(in: root, equals: $0) }) else {
            return nil
        }
        return panel
    }

    private func findStaticText(in view: NSView, equals text: String) -> Bool {
        if let field = view as? NSTextField, field.stringValue == text {
            return true
        }
        for subview in view.subviews {
            if findStaticText(in: subview, equals: text) {
                return true
            }
        }
        return false
    }

    private func matchConfiguredShortcut(event: NSEvent, action: KeyboardShortcutSettings.Action) -> Bool {
        let shortcut = KeyboardShortcutSettings.shortcut(for: action)
        if let prefix = activeConfiguredShortcutChordPrefixForCurrentEvent {
            guard let secondStroke = shortcut.secondStroke,
                  shortcut.firstStroke == prefix else {
                return false
            }
            return matchShortcutStroke(event: event, stroke: secondStroke)
        }
        guard !shortcut.hasChord else { return false }
        return matchShortcutStroke(event: event, stroke: shortcut.firstStroke)
    }

    private func numberedConfiguredShortcutDigit(
        event: NSEvent,
        action: KeyboardShortcutSettings.Action
    ) -> Int? {
        let shortcut = KeyboardShortcutSettings.shortcut(for: action)
        if let prefix = activeConfiguredShortcutChordPrefixForCurrentEvent {
            guard let secondStroke = shortcut.secondStroke,
                  shortcut.firstStroke == prefix else {
                return nil
            }
            return numberedShortcutDigit(event: event, stroke: secondStroke)
        }
        guard !shortcut.hasChord else { return nil }
        return numberedShortcutDigit(event: event, stroke: shortcut.firstStroke)
    }

    private func matchConfiguredDirectionalShortcut(
        event: NSEvent,
        action: KeyboardShortcutSettings.Action,
        arrowGlyph: String,
        arrowKeyCode: UInt16
    ) -> Bool {
        let shortcut = KeyboardShortcutSettings.shortcut(for: action)
        if let prefix = activeConfiguredShortcutChordPrefixForCurrentEvent {
            guard let secondStroke = shortcut.secondStroke,
                  shortcut.firstStroke == prefix else {
                return false
            }
            return matchDirectionalShortcut(
                event: event,
                stroke: secondStroke,
                arrowGlyph: arrowGlyph,
                arrowKeyCode: arrowKeyCode
            )
        }
        guard !shortcut.hasChord else { return false }
        return matchDirectionalShortcut(
            event: event,
            stroke: shortcut.firstStroke,
            arrowGlyph: arrowGlyph,
            arrowKeyCode: arrowKeyCode
        )
    }

    private func configuredShortcutChordWindowNumber(for event: NSEvent) -> Int? {
        if let window = mainWindowForShortcutEvent(event) {
            return window.windowNumber
        }
        if let window = event.window {
            return window.windowNumber
        }
        return event.windowNumber > 0 ? event.windowNumber : nil
    }

    private func armConfiguredShortcutChordIfNeeded(
        event: NSEvent,
        actions: [KeyboardShortcutSettings.Action]? = nil
    ) -> Bool {
        for action in actions ?? configuredShortcutChordActions {
            let shortcut = KeyboardShortcutSettings.shortcut(for: action)
            guard shortcut.hasChord else { continue }
            if matchShortcutStroke(event: event, stroke: shortcut.firstStroke) {
                pendingConfiguredShortcutChord = PendingConfiguredShortcutChord(
                    firstStroke: shortcut.firstStroke,
                    windowNumber: configuredShortcutChordWindowNumber(for: event)
                )
                return true
            }
        }
        return false
    }

    /// Match a shortcut stroke against an event, handling normal keys.
    ///
    /// Thin forwarder: the matching logic lives in `ShortcutRouting.matchStroke`, which is a
    /// pure function over an explicit `layoutCharacterProvider` parameter so it can be
    /// table-tested without AppKit. This method exists so existing call sites keep working
    /// unchanged, passing this instance's `shortcutLayoutCharacterProvider` through.
    private func matchShortcutStroke(event: NSEvent, stroke: ShortcutStroke) -> Bool {
        ShortcutRouting.matchStroke(
            event: event,
            stroke: stroke,
            layoutCharacterProvider: shortcutLayoutCharacterProvider
        )
    }

    private func matchShortcut(event: NSEvent, shortcut: StoredShortcut) -> Bool {
        ShortcutRouting.match(
            event: event,
            shortcut: shortcut,
            layoutCharacterProvider: shortcutLayoutCharacterProvider
        )
    }

    private func numberedShortcutDigit(event: NSEvent, stroke: ShortcutStroke) -> Int? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        guard flags == stroke.modifierFlags else { return nil }
        let numberKeyDigit = Self.digitForNumberKeyCode(event.keyCode)

        if let digit = numberedShortcutDigit(
            eventCharacter: event.charactersIgnoringModifiers,
            applyShiftSymbolNormalization: flags.contains(.shift),
            eventKeyCode: event.keyCode
        ) {
            return digit
        }

        let eventCharsIgnoringModifiers = event.charactersIgnoringModifiers
        let hasUsableASCIIEventChars = !(eventCharsIgnoringModifiers?.isEmpty ?? true)
            && (eventCharsIgnoringModifiers?.allSatisfy(\.isASCII) ?? true)
        if !hasUsableASCIIEventChars || numberKeyDigit != nil {
            let layoutCharacter = shortcutLayoutCharacterProvider(event.keyCode, event.modifierFlags)
            if let digit = numberedShortcutDigit(
                eventCharacter: layoutCharacter,
                applyShiftSymbolNormalization: false,
                eventKeyCode: event.keyCode
            ) {
                return digit
            }
        }

        return numberKeyDigit
    }

    private func numberedShortcutDigit(event: NSEvent, shortcut: StoredShortcut) -> Int? {
        guard !shortcut.hasChord else { return nil }
        return numberedShortcutDigit(event: event, stroke: shortcut.firstStroke)
    }

    private func numberedShortcutDigit(
        eventCharacter: String?,
        applyShiftSymbolNormalization: Bool,
        eventKeyCode: UInt16
    ) -> Int? {
        guard let eventCharacter, !eventCharacter.isEmpty else { return nil }
        let normalized = Self.normalizedShortcutEventCharacter(
            eventCharacter,
            applyShiftSymbolNormalization: applyShiftSymbolNormalization,
            eventKeyCode: eventKeyCode
        )
        guard let digit = Int(normalized), (1...9).contains(digit) else { return nil }
        return digit
    }

    // `shouldRequireCharacterMatchForCommandShortcut` and `shortcutCharacterMatches` moved to
    // `ShortcutRouting` — they were only ever called from `matchShortcutStroke`, which now
    // forwards to `ShortcutRouting.matchStroke`.

    /// Shared with `ShortcutRouting.matchStroke` (via `AppDelegate.normalizedShortcutEventCharacter`)
    /// and with `numberedShortcutDigit` above, so it stays here as `nonisolated static` rather than
    /// moving — it never reads instance state, so isolation is safe to drop explicitly.
    nonisolated static func normalizedShortcutEventCharacter(
        _ eventCharacter: String,
        applyShiftSymbolNormalization: Bool,
        eventKeyCode: UInt16
    ) -> String {
        let lowered = eventCharacter.lowercased()
        guard applyShiftSymbolNormalization else { return lowered }

        switch lowered {
        case "{": return "["
        case "}": return "]"
        case "<": return eventKeyCode == 43 ? "," : lowered // kVK_ANSI_Comma
        case ">": return eventKeyCode == 47 ? "." : lowered // kVK_ANSI_Period
        case "?": return "/"
        case ":": return ";"
        case "\"": return "'"
        case "|": return "\\"
        case "~": return "`"
        case "+": return "="
        case "_": return "-"
        case "!": return eventKeyCode == 18 ? "1" : lowered // kVK_ANSI_1
        case "@": return eventKeyCode == 19 ? "2" : lowered // kVK_ANSI_2
        case "#": return eventKeyCode == 20 ? "3" : lowered // kVK_ANSI_3
        case "$": return eventKeyCode == 21 ? "4" : lowered // kVK_ANSI_4
        case "%": return eventKeyCode == 23 ? "5" : lowered // kVK_ANSI_5
        case "^": return eventKeyCode == 22 ? "6" : lowered // kVK_ANSI_6
        case "&": return eventKeyCode == 26 ? "7" : lowered // kVK_ANSI_7
        case "*": return eventKeyCode == 28 ? "8" : lowered // kVK_ANSI_8
        case "(": return eventKeyCode == 25 ? "9" : lowered // kVK_ANSI_9
        case ")": return eventKeyCode == 29 ? "0" : lowered // kVK_ANSI_0
        default: return lowered
        }
    }

    // `keyCodeForShortcutKey` moved to `ShortcutRouting` — it was only ever called from
    // `matchShortcutStroke`, which now forwards to `ShortcutRouting.matchStroke`.

    /// Shared with `ShortcutRouting.matchStroke` (via `AppDelegate.digitForNumberKeyCode`) and
    /// with `numberedShortcutDigit` above, so it stays here as `nonisolated static` rather than
    /// moving — it never reads instance state, so isolation is safe to drop explicitly.
    nonisolated static func digitForNumberKeyCode(_ keyCode: UInt16) -> Int? {
        switch keyCode {
        case 18: return 1 // kVK_ANSI_1
        case 19: return 2 // kVK_ANSI_2
        case 20: return 3 // kVK_ANSI_3
        case 21: return 4 // kVK_ANSI_4
        case 23: return 5 // kVK_ANSI_5
        case 22: return 6 // kVK_ANSI_6
        case 26: return 7 // kVK_ANSI_7
        case 28: return 8 // kVK_ANSI_8
        case 25: return 9 // kVK_ANSI_9
        default:
            return nil
        }
    }

    /// Match arrow key shortcuts using keyCode
    /// Arrow keys include .numericPad and .function in their modifierFlags, so strip those before comparing.
    private func matchArrowShortcut(event: NSEvent, stroke: ShortcutStroke, keyCode: UInt16) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function])
        return event.keyCode == keyCode && flags == stroke.modifierFlags
    }

    /// Match tab key shortcuts using keyCode 48
    private func matchTabShortcut(event: NSEvent, stroke: ShortcutStroke) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return event.keyCode == 48 && flags == stroke.modifierFlags
    }

    private func matchTabShortcut(event: NSEvent, shortcut: StoredShortcut) -> Bool {
        guard !shortcut.hasChord else { return false }
        return matchTabShortcut(event: event, stroke: shortcut.firstStroke)
    }

    /// Directional shortcuts default to arrow keys, but the shortcut recorder only supports letter/number keys.
    /// Support both so users can customize pane navigation (e.g. Cmd+Ctrl+H/J/K/L).
    private func matchDirectionalShortcut(
        event: NSEvent,
        stroke: ShortcutStroke,
        arrowGlyph: String,
        arrowKeyCode: UInt16
    ) -> Bool {
        if stroke.key == arrowGlyph {
            return matchArrowShortcut(event: event, stroke: stroke, keyCode: arrowKeyCode)
        }
        return matchShortcutStroke(event: event, stroke: stroke)
    }

    private func matchDirectionalShortcut(
        event: NSEvent,
        shortcut: StoredShortcut,
        arrowGlyph: String,
        arrowKeyCode: UInt16
    ) -> Bool {
        guard !shortcut.hasChord else { return false }
        return matchDirectionalShortcut(
            event: event,
            stroke: shortcut.firstStroke,
            arrowGlyph: arrowGlyph,
            arrowKeyCode: arrowKeyCode
        )
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        updateController.validateMenuItem(item)
    }


    private func configureUserNotifications() {
        let actions = [
            UNNotificationAction(
                identifier: TerminalNotificationStore.actionShowIdentifier,
                title: "Show"
            )
        ]

        let category = UNNotificationCategory(
            identifier: TerminalNotificationStore.categoryIdentifier,
            actions: actions,
            intentIdentifiers: [],
            options: [.customDismissAction]
        )

        let center = UNUserNotificationCenter.current()
        center.setNotificationCategories([category])
        center.delegate = self
    }

    private func disableNativeTabbingShortcut() {
        guard let menu = NSApp.mainMenu else { return }
        disableMenuItemShortcut(in: menu, action: #selector(NSWindow.toggleTabBar(_:)))
    }

    private func disableMenuItemShortcut(in menu: NSMenu, action: Selector) {
        for item in menu.items {
            if item.action == action {
                item.keyEquivalent = ""
                item.keyEquivalentModifierMask = []
                item.isEnabled = false
            }
            if let submenu = item.submenu {
                disableMenuItemShortcut(in: submenu, action: action)
            }
        }
    }

    private func ensureApplicationIcon() {
        // Manual light/dark override removed; the icon always tracks system
        // appearance. Clear any stale pre-removal override so the dock-tile
        // plugin (which reads the raw key cross-process) falls back too.
        UserDefaults.standard.removeObject(forKey: "appIconMode")
        AppIconAppearanceObserver.shared.startObserving()
    }

    private func scheduleLaunchServicesBundleRegistration(
        bundleURL: URL = Bundle.main.bundleURL.standardizedFileURL,
        scheduler: @escaping (@escaping @Sendable () -> Void) -> Void = AppDelegate.enqueueLaunchServicesRegistrationWork,
        register: @escaping (CFURL) -> OSStatus = { url in
            LSRegisterURL(url, true)
        },
        breadcrumb: @escaping (_ message: String, _ data: [String: Any]) -> Void = { _, _ in }
    ) {
        let normalizedURL = bundleURL.standardizedFileURL
        breadcrumb("launchservices.register.schedule", [
            "bundlePath": normalizedURL.path
        ])

        scheduler {
            let startedAt = CFAbsoluteTimeGetCurrent()
            let registerStatus = register(normalizedURL as CFURL)
            let durationMs = Int(((CFAbsoluteTimeGetCurrent() - startedAt) * 1000).rounded())

            breadcrumb("launchservices.register.complete", [
                "bundlePath": normalizedURL.path,
                "status": Int(registerStatus),
                "durationMs": durationMs
            ])

            if registerStatus != noErr {
                NSLog("LaunchServices registration failed (status: \(registerStatus)) for \(normalizedURL.path)")
            }
        }
    }

#if DEBUG
    func scheduleLaunchServicesBundleRegistrationForTesting(
        bundleURL: URL,
        scheduler: @escaping (@escaping @Sendable () -> Void) -> Void,
        register: @escaping (CFURL) -> OSStatus,
        breadcrumb: @escaping (_ message: String, _ data: [String: Any]) -> Void = { _, _ in }
    ) {
        scheduleLaunchServicesBundleRegistration(
            bundleURL: bundleURL,
            scheduler: scheduler,
            register: register,
            breadcrumb: breadcrumb
        )
    }
#endif

    struct SingleInstanceShutdownRequest: Codable, Equatable, Sendable {
        static let currentVersion = 1

        let version: Int
        let generation: UUID
        let targetStartSeconds: Int64
        let targetStartMicroseconds: Int64
        let targetProcessIdentifier: pid_t
        let requesterStartSeconds: Int64
        let requesterStartMicroseconds: Int64
        let requesterProcessIdentifier: pid_t
        let createdAtUnixSeconds: TimeInterval

        init(
            version: Int = Self.currentVersion,
            generation: UUID = UUID(),
            target: ProgramaSingleInstanceProcessKey,
            requester: ProgramaSingleInstanceProcessKey,
            createdAtUnixSeconds: TimeInterval
        ) {
            self.version = version
            self.generation = generation
            targetStartSeconds = target.startSeconds
            targetStartMicroseconds = target.startMicroseconds
            targetProcessIdentifier = target.processIdentifier
            requesterStartSeconds = requester.startSeconds
            requesterStartMicroseconds = requester.startMicroseconds
            requesterProcessIdentifier = requester.processIdentifier
            self.createdAtUnixSeconds = createdAtUnixSeconds
        }

        var target: ProgramaSingleInstanceProcessKey {
            ProgramaSingleInstanceProcessKey(
                startSeconds: targetStartSeconds,
                startMicroseconds: targetStartMicroseconds,
                processIdentifier: targetProcessIdentifier
            )
        }

        var requester: ProgramaSingleInstanceProcessKey {
            ProgramaSingleInstanceProcessKey(
                startSeconds: requesterStartSeconds,
                startMicroseconds: requesterStartMicroseconds,
                processIdentifier: requesterProcessIdentifier
            )
        }
    }

    struct SingleInstanceShutdownAcknowledgment: Codable, Equatable, Sendable {
        static let currentVersion = 1

        let version: Int
        let acceptedGeneration: UUID
        let targetStartSeconds: Int64
        let targetStartMicroseconds: Int64
        let targetProcessIdentifier: pid_t
        let createdAtUnixSeconds: TimeInterval

        init(
            version: Int = Self.currentVersion,
            acceptedGeneration: UUID,
            target: ProgramaSingleInstanceProcessKey,
            createdAtUnixSeconds: TimeInterval
        ) {
            self.version = version
            self.acceptedGeneration = acceptedGeneration
            targetStartSeconds = target.startSeconds
            targetStartMicroseconds = target.startMicroseconds
            targetProcessIdentifier = target.processIdentifier
            self.createdAtUnixSeconds = createdAtUnixSeconds
        }

        var target: ProgramaSingleInstanceProcessKey {
            ProgramaSingleInstanceProcessKey(
                startSeconds: targetStartSeconds,
                startMicroseconds: targetStartMicroseconds,
                processIdentifier: targetProcessIdentifier
            )
        }
    }

    enum SingleInstanceForcePromptResponse: Equatable, Sendable {
        case forceClose
        case cancel
    }

    enum SingleInstanceForcePromptButton: Equatable, Sendable {
        case primary
        case secondary
        case escape
    }

    struct SingleInstanceCodeIdentity: Equatable, Sendable {
        let signingIdentifier: String?
        let teamIdentifier: String?
    }

    struct SingleInstanceTerminationPersistencePolicy: Equatable, Sendable {
        let persistPreTerminationSnapshot: Bool
        let persistCleanShutdownSnapshot: Bool
        let performProcessLocalTeardown: Bool
    }

    enum SingleInstanceFallbackAction: Equatable, Sendable {
        case skip
        case waitForAcknowledgedExit
        case prompt
        case force
        case exitNewer
    }

    nonisolated static func singleInstanceProcessKey(
        for processIdentifier: pid_t
    ) -> ProgramaSingleInstanceProcessKey? {
        var processInfo = kinfo_proc()
        var processInfoSize = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, processIdentifier]
        guard sysctl(&mib, UInt32(mib.count), &processInfo, &processInfoSize, nil, 0) == 0,
              processInfoSize == MemoryLayout<kinfo_proc>.size,
              processInfo.kp_proc.p_pid == processIdentifier else {
            return nil
        }

        let startTime = processInfo.kp_proc.p_starttime
        guard startTime.tv_sec > 0 || startTime.tv_usec > 0 else { return nil }
        return ProgramaSingleInstanceProcessKey(
            startSeconds: Int64(startTime.tv_sec),
            startMicroseconds: Int64(startTime.tv_usec),
            processIdentifier: processIdentifier
        )
    }

    nonisolated static func shouldTerminateDuplicateInstance(
        current: ProgramaSingleInstanceProcessKey,
        other: ProgramaSingleInstanceProcessKey
    ) -> Bool {
        if current.startSeconds != other.startSeconds {
            return current.startSeconds > other.startSeconds
        }
        if current.startMicroseconds != other.startMicroseconds {
            return current.startMicroseconds > other.startMicroseconds
        }
        return current.processIdentifier > other.processIdentifier
    }

    private nonisolated static let duplicateShutdownRequestMaxAge: TimeInterval = 10
    private nonisolated static let duplicateShutdownRequestMaxBytes = 4_096
    private nonisolated static let duplicateTerminationGraceInterval: TimeInterval = 8
    private nonisolated static let duplicateStateDirectoryMaxEntries = 128
    private nonisolated static let duplicateStateDirectoryScanLimit = 512
    private nonisolated static let duplicateStateDirectoryMaxPrunePasses = 8
    private nonisolated static let duplicateTargetRequestScanLimit = 32

    nonisolated static func shouldAcceptDuplicateShutdownRequest(
        _ request: SingleInstanceShutdownRequest?,
        currentProcessKey: ProgramaSingleInstanceProcessKey,
        now: TimeInterval,
        resolvedRequesterKey: ProgramaSingleInstanceProcessKey?,
        requesterIsProgramaGUI: Bool
    ) -> Bool {
        guard let request,
              request.version == SingleInstanceShutdownRequest.currentVersion,
              request.target == currentProcessKey,
              request.createdAtUnixSeconds.isFinite else {
            return false
        }

        let age = now - request.createdAtUnixSeconds
        guard age >= 0, age <= duplicateShutdownRequestMaxAge,
              request.requester != currentProcessKey,
              resolvedRequesterKey == request.requester,
              requesterIsProgramaGUI else {
            return false
        }

        return shouldTerminateDuplicateInstance(current: request.requester, other: currentProcessKey)
    }

    nonisolated static func shouldWarnBeforeTermination(
        isTaggedDevBuild: Bool,
        isQuitWarningConfirmed: Bool,
        isInternalSingleInstanceLoserExit: Bool,
        hasValidatedDuplicateShutdownRequest: Bool,
        isQuitWarningEnabled: Bool
    ) -> Bool {
        guard !isTaggedDevBuild,
              !isQuitWarningConfirmed,
              !isInternalSingleInstanceLoserExit,
              !hasValidatedDuplicateShutdownRequest else {
            return false
        }
        return isQuitWarningEnabled
    }

    nonisolated static func shouldAcceptDuplicateShutdownAcknowledgment(
        _ acknowledgment: SingleInstanceShutdownAcknowledgment?,
        expectedTarget: ProgramaSingleInstanceProcessKey,
        requestCreatedAt: TimeInterval,
        now: TimeInterval
    ) -> Bool {
        guard let acknowledgment,
              acknowledgment.version == SingleInstanceShutdownAcknowledgment.currentVersion,
              acknowledgment.target == expectedTarget,
              acknowledgment.createdAtUnixSeconds.isFinite else {
            return false
        }
        let requestDistance = abs(acknowledgment.createdAtUnixSeconds - requestCreatedAt)
        return acknowledgment.createdAtUnixSeconds <= now + 1
            && requestDistance <= duplicateShutdownRequestMaxAge
    }

    nonisolated static func shouldScheduleDuplicateFallback(
        requestWasWritten: Bool,
        gracefulTerminationAccepted: Bool
    ) -> Bool {
        requestWasWritten
    }

    nonisolated static func duplicateForcePromptResponse(
        button: SingleInstanceForcePromptButton
    ) -> SingleInstanceForcePromptResponse {
        switch button {
        case .primary, .escape: return .cancel
        case .secondary: return .forceClose
        }
    }

    nonisolated static func shouldTrustDuplicateCodeIdentity(
        current: SingleInstanceCodeIdentity,
        candidate: SingleInstanceCodeIdentity,
        designatedRequirementMatches: Bool,
        isDebugBuild: Bool
    ) -> Bool {
        guard designatedRequirementMatches,
              let currentSigningIdentifier = current.signingIdentifier,
              !currentSigningIdentifier.isEmpty,
              candidate.signingIdentifier == currentSigningIdentifier else {
            return false
        }
        if isDebugBuild, current.teamIdentifier == nil, candidate.teamIdentifier == nil {
            return true
        }
        guard let currentTeamIdentifier = current.teamIdentifier,
              !currentTeamIdentifier.isEmpty else {
            return false
        }
        return candidate.teamIdentifier == currentTeamIdentifier
    }

    nonisolated static func singleInstanceTerminationPersistencePolicy(
        isDiscardedDuplicate: Bool
    ) -> SingleInstanceTerminationPersistencePolicy {
        SingleInstanceTerminationPersistencePolicy(
            persistPreTerminationSnapshot: !isDiscardedDuplicate,
            persistCleanShutdownSnapshot: !isDiscardedDuplicate,
            performProcessLocalTeardown: true
        )
    }

    nonisolated static func shouldTrustDuplicateRunningCode(
        expectedProcessKey: ProgramaSingleInstanceProcessKey,
        resolvedProcessKeyBeforeValidation: ProgramaSingleInstanceProcessKey?,
        resolvedProcessKeyAfterValidation: ProgramaSingleInstanceProcessKey?,
        currentIdentity: SingleInstanceCodeIdentity,
        candidateIdentity: SingleInstanceCodeIdentity,
        dynamicRequirementMatches: Bool,
        isDebugBuild: Bool
    ) -> Bool {
        guard resolvedProcessKeyBeforeValidation == expectedProcessKey,
              resolvedProcessKeyAfterValidation == expectedProcessKey else {
            return false
        }
        return shouldTrustDuplicateCodeIdentity(
            current: currentIdentity,
            candidate: candidateIdentity,
            designatedRequirementMatches: dynamicRequirementMatches,
            isDebugBuild: isDebugBuild
        )
    }

    nonisolated static func duplicateFallbackAction(
        hasValidTargetAcknowledgment: Bool,
        requestGenerationIsPending: Bool,
        processIdentityMatches: Bool,
        isTerminated: Bool,
        response: SingleInstanceForcePromptResponse?
    ) -> SingleInstanceFallbackAction {
        guard requestGenerationIsPending,
              processIdentityMatches,
              !isTerminated else {
            return .skip
        }
        if hasValidTargetAcknowledgment { return .waitForAcknowledgedExit }
        guard let response else { return .prompt }
        switch response {
        case .forceClose: return .force
        case .cancel: return .exitNewer
        }
    }

    nonisolated static func shouldConsiderDuplicateApplication(
        candidateBundleIdentifier: String?,
        candidateProcessIdentifier: pid_t,
        candidateExecutableURL: URL?,
        expectedBundleIdentifier: String,
        currentProcessIdentifier: pid_t,
        embeddedCLIURL: URL
    ) -> Bool {
        guard candidateBundleIdentifier == expectedBundleIdentifier else {
            dilog("single_instance", "pid=\(candidateProcessIdentifier) outcome=ignored reason=bundle_mismatch")
            return false
        }
        guard candidateProcessIdentifier != currentProcessIdentifier else {
            dilog("single_instance", "pid=\(candidateProcessIdentifier) outcome=ignored reason=current_process")
            return false
        }
        guard let candidateExecutableURL else {
            dilog("single_instance", "pid=\(candidateProcessIdentifier) outcome=ignored reason=missing_executable")
            return false
        }
        guard candidateExecutableURL.standardizedFileURL.resolvingSymlinksInPath()
                != embeddedCLIURL.standardizedFileURL.resolvingSymlinksInPath() else {
            dilog("single_instance", "pid=\(candidateProcessIdentifier) outcome=ignored reason=embedded_cli")
            return false
        }
        dilog("single_instance", "pid=\(candidateProcessIdentifier) outcome=accepted reason=gui_candidate")
        return true
    }

    nonisolated private static func dynamicCodeForCurrentProcess() -> SecCode? {
        var dynamicCode: SecCode?
        guard SecCodeCopySelf(SecCSFlags(rawValue: 0), &dynamicCode) == errSecSuccess,
              let dynamicCode else {
            return nil
        }
        return dynamicCode
    }

    nonisolated private static func dynamicCode(
        for processIdentifier: pid_t
    ) -> SecCode? {
        let attributes = [
            kSecGuestAttributePid as String: NSNumber(value: processIdentifier),
        ] as CFDictionary
        var dynamicCode: SecCode?
        guard SecCodeCopyGuestWithAttributes(
            nil,
            attributes,
            SecCSFlags(rawValue: 0),
            &dynamicCode
        ) == errSecSuccess,
              let dynamicCode else {
            return nil
        }
        return dynamicCode
    }

    nonisolated private static func singleInstanceCodeIdentity(
        for staticCode: SecStaticCode
    ) -> SingleInstanceCodeIdentity? {
        var signingInformation: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &signingInformation
        ) == errSecSuccess,
              let signingInformation else {
            return nil
        }
        let dictionary = signingInformation as NSDictionary
        return SingleInstanceCodeIdentity(
            signingIdentifier: dictionary[kSecCodeInfoIdentifier] as? String,
            teamIdentifier: dictionary[kSecCodeInfoTeamIdentifier] as? String
        )
    }

    nonisolated private static func singleInstanceCodeIdentity(
        for dynamicCode: SecCode
    ) -> SingleInstanceCodeIdentity? {
        // Security.framework documents SecCodeCopySigningInformation as valid for dynamic
        // SecCode objects, but Swift imports its parameter as SecStaticCode. Both are CF
        // code-object references; this bridge preserves the dynamic object rather than
        // resolving a mutable on-disk static-code origin.
        let signingInformationCode = unsafeBitCast(dynamicCode, to: SecStaticCode.self)
        return singleInstanceCodeIdentity(for: signingInformationCode)
    }

    nonisolated static func isAuthenticatedProgramaApplication(
        expectedProcessKey: ProgramaSingleInstanceProcessKey
    ) -> Bool {
        let processIdentifier = expectedProcessKey.processIdentifier
        let processKeyBeforeValidation = singleInstanceProcessKey(for: processIdentifier)
        guard let currentCode = dynamicCodeForCurrentProcess(),
              processKeyBeforeValidation == expectedProcessKey,
              let candidateCode = dynamicCode(for: processIdentifier),
              let currentIdentity = singleInstanceCodeIdentity(for: currentCode),
              let candidateIdentity = singleInstanceCodeIdentity(for: candidateCode) else {
            dilog("single_instance", "pid=\(processIdentifier) outcome=rejected reason=signing_metadata")
            return false
        }
        let currentRequirementCode = unsafeBitCast(currentCode, to: SecStaticCode.self)
        var designatedRequirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(
            currentRequirementCode,
            SecCSFlags(rawValue: 0),
            &designatedRequirement
        ) == errSecSuccess,
              let designatedRequirement else {
            dilog("single_instance", "pid=\(processIdentifier) outcome=rejected reason=signing_requirement")
            return false
        }
        let validationFlags = SecCSFlags(rawValue: 0)
        let designatedRequirementMatches = SecCodeCheckValidity(
            candidateCode,
            validationFlags,
            designatedRequirement
        ) == errSecSuccess
        let processKeyAfterValidation = singleInstanceProcessKey(for: processIdentifier)
#if DEBUG
        let isDebugBuild = true
#else
        let isDebugBuild = false
#endif
        let trusted = shouldTrustDuplicateRunningCode(
            expectedProcessKey: expectedProcessKey,
            resolvedProcessKeyBeforeValidation: processKeyBeforeValidation,
            resolvedProcessKeyAfterValidation: processKeyAfterValidation,
            currentIdentity: currentIdentity,
            candidateIdentity: candidateIdentity,
            dynamicRequirementMatches: designatedRequirementMatches,
            isDebugBuild: isDebugBuild
        )
        dilog(
            "single_instance",
            "pid=\(processIdentifier) outcome=\(trusted ? "accepted" : "rejected") reason=code_identity"
        )
        return trusted
    }

    private static func scheduleDuplicateTermination(
        requestTermination: () -> Bool,
        scheduleGrace: (@escaping @MainActor () -> Void) -> Void,
        performFallbackAfterGrace: @escaping @MainActor () -> Void
    ) {
        guard requestTermination() else { return }
        scheduleGrace {
            performFallbackAfterGrace()
        }
    }

    nonisolated private static func acknowledgmentForAcceptedRequest(
        _ request: SingleInstanceShutdownRequest,
        currentProcessKey: ProgramaSingleInstanceProcessKey,
        now: TimeInterval
    ) -> SingleInstanceShutdownAcknowledgment? {
        guard request.target == currentProcessKey,
              request.version == SingleInstanceShutdownRequest.currentVersion else {
            return nil
        }
        return SingleInstanceShutdownAcknowledgment(
            acceptedGeneration: request.generation,
            target: currentProcessKey,
            createdAtUnixSeconds: now
        )
    }

#if DEBUG
    nonisolated static func duplicateRequestURLForTesting(
        rootDirectory: URL,
        target: ProgramaSingleInstanceProcessKey,
        generation: UUID
    ) -> URL {
        duplicateShutdownRequestURL(
            rootDirectory: rootDirectory,
            target: target,
            generation: generation
        )
    }

    nonisolated static func acknowledgmentForAcceptedRequestForTesting(
        _ request: SingleInstanceShutdownRequest,
        currentProcessKey: ProgramaSingleInstanceProcessKey,
        now: TimeInterval
    ) -> SingleInstanceShutdownAcknowledgment? {
        acknowledgmentForAcceptedRequest(
            request,
            currentProcessKey: currentProcessKey,
            now: now
        )
    }

    nonisolated static func duplicateFallbackActionForTesting(
        hasValidTargetAcknowledgment: Bool,
        requestGenerationIsPending: Bool,
        processIdentityMatches: Bool,
        isTerminated: Bool,
        response: SingleInstanceForcePromptResponse?
    ) -> SingleInstanceFallbackAction {
        duplicateFallbackAction(
            hasValidTargetAcknowledgment: hasValidTargetAcknowledgment,
            requestGenerationIsPending: requestGenerationIsPending,
            processIdentityMatches: processIdentityMatches,
            isTerminated: isTerminated,
            response: response
        )
    }

    nonisolated static func duplicateAcknowledgmentURLForTesting(
        rootDirectory: URL,
        target: ProgramaSingleInstanceProcessKey,
        generation: UUID
    ) -> URL {
        _ = generation
        return duplicateShutdownAcknowledgmentURL(
            rootDirectory: rootDirectory,
            target: target
        )
    }

    nonisolated static func writeDuplicateRequestForTesting(
        rootDirectory: URL,
        request: SingleInstanceShutdownRequest
    ) -> URL? {
        let url = duplicateShutdownRequestURL(
            rootDirectory: rootDirectory,
            target: request.target,
            generation: request.generation
        )
        return writeBoundedSingleInstanceJSON(request, to: url) ? url : nil
    }

    nonisolated static func removeDuplicateStateForTesting(
        rootDirectory: URL,
        request: SingleInstanceShutdownRequest
    ) -> Bool {
        let pending = PendingSingleInstanceShutdown(
            request: request,
            requestURL: duplicateShutdownRequestURL(
                rootDirectory: rootDirectory,
                target: request.target,
                generation: request.generation
            ),
            acknowledgmentURL: duplicateShutdownAcknowledgmentURL(
                rootDirectory: rootDirectory,
                target: request.target
            )
        )
        let existed = isExactRequestPending(pending)
        removeExactShutdownState(pending)
        return existed
    }

    nonisolated static func prepareDuplicateStateForTesting(
        rootDirectory: URL,
        now: TimeInterval,
        isProcessLive: (ProgramaSingleInstanceProcessKey) -> Bool
    ) -> Bool {
        preparedSingleInstanceStateURLs(
            in: rootDirectory,
            now: now,
            isProcessLive: isProcessLive
        ) != nil
    }

    nonisolated static func shouldAcceptDuplicateShutdownAcknowledgmentForTesting(
        _ acknowledgment: SingleInstanceShutdownAcknowledgment?,
        expectedRequest: SingleInstanceShutdownRequest,
        now: TimeInterval
    ) -> Bool {
        shouldAcceptDuplicateShutdownAcknowledgment(
            acknowledgment,
            expectedTarget: expectedRequest.target,
            requestCreatedAt: expectedRequest.createdAtUnixSeconds,
            now: now
        )
    }

    nonisolated static func shouldScheduleDuplicateFallbackForTesting(
        requestWasWritten: Bool,
        gracefulTerminationAccepted: Bool
    ) -> Bool {
        shouldScheduleDuplicateFallback(
            requestWasWritten: requestWasWritten,
            gracefulTerminationAccepted: gracefulTerminationAccepted
        )
    }

    nonisolated static func duplicateForcePromptResponseForTesting(
        button: SingleInstanceForcePromptButton
    ) -> SingleInstanceForcePromptResponse {
        duplicateForcePromptResponse(button: button)
    }

    nonisolated static func shouldTrustDuplicateCodeIdentityForTesting(
        current: SingleInstanceCodeIdentity,
        candidate: SingleInstanceCodeIdentity,
        designatedRequirementMatches: Bool,
        isDebugBuild: Bool
    ) -> Bool {
        shouldTrustDuplicateCodeIdentity(
            current: current,
            candidate: candidate,
            designatedRequirementMatches: designatedRequirementMatches,
            isDebugBuild: isDebugBuild
        )
    }

    nonisolated static func shouldTrustDuplicateRunningCodeForTesting(
        expectedProcessKey: ProgramaSingleInstanceProcessKey,
        resolvedProcessKeyBeforeValidation: ProgramaSingleInstanceProcessKey?,
        resolvedProcessKeyAfterValidation: ProgramaSingleInstanceProcessKey?,
        currentIdentity: SingleInstanceCodeIdentity,
        candidateIdentity: SingleInstanceCodeIdentity,
        dynamicRequirementMatches: Bool,
        isDebugBuild: Bool
    ) -> Bool {
        shouldTrustDuplicateRunningCode(
            expectedProcessKey: expectedProcessKey,
            resolvedProcessKeyBeforeValidation: resolvedProcessKeyBeforeValidation,
            resolvedProcessKeyAfterValidation: resolvedProcessKeyAfterValidation,
            currentIdentity: currentIdentity,
            candidateIdentity: candidateIdentity,
            dynamicRequirementMatches: dynamicRequirementMatches,
            isDebugBuild: isDebugBuild
        )
    }

    nonisolated static func singleInstanceTerminationPersistencePolicyForTesting(
        isDiscardedDuplicate: Bool
    ) -> SingleInstanceTerminationPersistencePolicy {
        singleInstanceTerminationPersistencePolicy(isDiscardedDuplicate: isDiscardedDuplicate)
    }

    nonisolated static var duplicateTerminationGraceIntervalForTesting: TimeInterval {
        duplicateTerminationGraceInterval
    }

    nonisolated static func publishDuplicateAcknowledgmentForTesting(
        rootDirectory: URL,
        request: SingleInstanceShutdownRequest,
        currentProcessKey: ProgramaSingleInstanceProcessKey,
        now: TimeInterval,
        allowWrite: Bool = true
    ) -> Bool {
        publishDuplicateAcknowledgment(
            rootDirectory: rootDirectory,
            request: request,
            currentProcessKey: currentProcessKey,
            now: now,
            write: { acknowledgment, url in
                allowWrite && writeBoundedSingleInstanceJSON(acknowledgment, to: url)
            }
        )
    }

    nonisolated static func hasValidDuplicateAcknowledgmentForTesting(
        rootDirectory: URL,
        request: SingleInstanceShutdownRequest,
        now: TimeInterval
    ) -> Bool {
        let pending = PendingSingleInstanceShutdown(
            request: request,
            requestURL: duplicateShutdownRequestURL(
                rootDirectory: rootDirectory,
                target: request.target,
                generation: request.generation
            ),
            acknowledgmentURL: duplicateShutdownAcknowledgmentURL(
                rootDirectory: rootDirectory,
                target: request.target
            )
        )
        return isExactRequestPending(pending) && hasValidAcknowledgment(for: pending, now: now)
    }

    nonisolated static func shouldAcceptDuplicateShutdownRequestForTesting(
        _ request: SingleInstanceShutdownRequest?,
        currentProcessKey: ProgramaSingleInstanceProcessKey,
        now: TimeInterval,
        resolvedRequesterKey: ProgramaSingleInstanceProcessKey?,
        requesterIsProgramaGUI: Bool
    ) -> Bool {
        shouldAcceptDuplicateShutdownRequest(
            request,
            currentProcessKey: currentProcessKey,
            now: now,
            resolvedRequesterKey: resolvedRequesterKey,
            requesterIsProgramaGUI: requesterIsProgramaGUI
        )
    }

    nonisolated static func shouldWarnBeforeTerminationForTesting(
        isTaggedDevBuild: Bool,
        isQuitWarningConfirmed: Bool,
        isInternalSingleInstanceLoserExit: Bool,
        hasValidatedDuplicateShutdownRequest: Bool,
        isQuitWarningEnabled: Bool
    ) -> Bool {
        shouldWarnBeforeTermination(
            isTaggedDevBuild: isTaggedDevBuild,
            isQuitWarningConfirmed: isQuitWarningConfirmed,
            isInternalSingleInstanceLoserExit: isInternalSingleInstanceLoserExit,
            hasValidatedDuplicateShutdownRequest: hasValidatedDuplicateShutdownRequest,
            isQuitWarningEnabled: isQuitWarningEnabled
        )
    }

    static func scheduleDuplicateTerminationForTesting(
        requestTermination: () -> Bool,
        scheduleGrace: (@escaping @MainActor () -> Void) -> Void,
        performFallbackAfterGrace: @escaping @MainActor () -> Void
    ) {
        scheduleDuplicateTermination(
            requestTermination: requestTermination,
            scheduleGrace: scheduleGrace,
            performFallbackAfterGrace: performFallbackAfterGrace
        )
    }

#endif

    private struct PendingSingleInstanceShutdown: Sendable {
        let request: SingleInstanceShutdownRequest
        let requestURL: URL
        let acknowledgmentURL: URL
    }

    nonisolated private static func singleInstanceStateDirectoryURL(
        rootDirectory: URL = FileManager.default.temporaryDirectory
    ) -> URL {
        rootDirectory.appendingPathComponent(
            "programa-single-instance-\(getuid())",
            isDirectory: true
        )
    }

    nonisolated private static func singleInstanceTargetComponent(
        _ target: ProgramaSingleInstanceProcessKey
    ) -> String {
        "\(target.processIdentifier)-\(target.startSeconds)-\(target.startMicroseconds)"
    }

    nonisolated private static func duplicateShutdownRequestURL(
        rootDirectory: URL,
        target: ProgramaSingleInstanceProcessKey,
        generation: UUID
    ) -> URL {
        rootDirectory.appendingPathComponent(
            "request-\(singleInstanceTargetComponent(target))-\(generation.uuidString.lowercased()).json",
            isDirectory: false
        )
    }

    nonisolated private static func duplicateShutdownAcknowledgmentURL(
        rootDirectory: URL,
        target: ProgramaSingleInstanceProcessKey
    ) -> URL {
        rootDirectory.appendingPathComponent(
            "ack-\(singleInstanceTargetComponent(target)).json",
            isDirectory: false
        )
    }

    nonisolated private static func publishDuplicateAcknowledgment(
        rootDirectory: URL,
        request: SingleInstanceShutdownRequest,
        currentProcessKey: ProgramaSingleInstanceProcessKey,
        now: TimeInterval,
        write: (SingleInstanceShutdownAcknowledgment, URL) -> Bool
    ) -> Bool {
        guard let acknowledgment = acknowledgmentForAcceptedRequest(
            request,
            currentProcessKey: currentProcessKey,
            now: now
        ) else {
            return false
        }
        let url = duplicateShutdownAcknowledgmentURL(
            rootDirectory: rootDirectory,
            target: currentProcessKey
        )
        return write(acknowledgment, url)
    }

    nonisolated private static func validatedSingleInstanceStateDirectory() -> URL? {
        let fileManager = FileManager.default
        let directoryURL = singleInstanceStateDirectoryURL()
        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let values = try directoryURL.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ])
            let attributes = try fileManager.attributesOfItem(atPath: directoryURL.path)
            guard values.isDirectory == true,
                  values.isSymbolicLink != true,
                  let owner = attributes[.ownerAccountID] as? NSNumber,
                  owner.uint32Value == getuid() else {
                return nil
            }
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directoryURL.path
            )
            return directoryURL
        } catch {
            return nil
        }
    }

    nonisolated private static func readBoundedSingleInstanceJSON<Value: Decodable>(
        _ type: Value.Type,
        from url: URL
    ) -> Value? {
        guard let values = try? url.resourceValues(forKeys: [
            .fileSizeKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ]),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              let fileSize = values.fileSize,
              fileSize <= duplicateShutdownRequestMaxBytes,
              let fileHandle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? fileHandle.close() }
        guard let data = try? fileHandle.read(upToCount: duplicateShutdownRequestMaxBytes + 1),
              data.count <= duplicateShutdownRequestMaxBytes else {
            return nil
        }
        return try? JSONDecoder().decode(type, from: data)
    }

    nonisolated private static func writeBoundedSingleInstanceJSON<Value: Encodable>(
        _ value: Value,
        to url: URL
    ) -> Bool {
        do {
            let data = try JSONEncoder().encode(value)
            guard data.count <= duplicateShutdownRequestMaxBytes else { return false }
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    nonisolated private static func isExactRequestPending(
        _ pending: PendingSingleInstanceShutdown
    ) -> Bool {
        readBoundedSingleInstanceJSON(
            SingleInstanceShutdownRequest.self,
            from: pending.requestURL
        ) == pending.request
    }

    @discardableResult
    nonisolated private static func removeExactRequest(
        _ pending: PendingSingleInstanceShutdown
    ) -> Bool {
        guard isExactRequestPending(pending) else {
            return !FileManager.default.fileExists(atPath: pending.requestURL.path)
        }
        do {
            try FileManager.default.removeItem(at: pending.requestURL)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    nonisolated static func removeExactAcknowledgment(
        target: ProgramaSingleInstanceProcessKey,
        acceptedGeneration: UUID? = nil,
        url: URL
    ) -> Bool {
        guard let acknowledgment = readBoundedSingleInstanceJSON(
            SingleInstanceShutdownAcknowledgment.self,
            from: url
        ) else {
            return !FileManager.default.fileExists(atPath: url.path)
        }
        guard acknowledgment.version == SingleInstanceShutdownAcknowledgment.currentVersion,
              acknowledgment.target == target,
              acceptedGeneration == nil || acknowledgment.acceptedGeneration == acceptedGeneration else {
            return false
        }
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            return false
        }
    }

    nonisolated private static func removeExactShutdownState(
        _ pending: PendingSingleInstanceShutdown
    ) {
        _ = removeExactRequest(pending)
    }

    nonisolated private static func preparedSingleInstanceStateURLs(
        in directoryURL: URL,
        now: TimeInterval,
        isProcessLive: (ProgramaSingleInstanceProcessKey) -> Bool
    ) -> [URL]? {
        for _ in 0..<duplicateStateDirectoryMaxPrunePasses {
            guard let enumerator = FileManager.default.enumerator(
                at: directoryURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            ) else {
                return nil
            }

            var requests: [(URL, SingleInstanceShutdownRequest)] = []
            var acknowledgments: [(URL, SingleInstanceShutdownAcknowledgment)] = []
            var scannedCount = 0
            var exceededScanLimit = false
            for case let url as URL in enumerator {
                guard scannedCount < duplicateStateDirectoryScanLimit else {
                    exceededScanLimit = true
                    break
                }
                scannedCount += 1

                if url.lastPathComponent.hasPrefix("request-"),
                   let request = readBoundedSingleInstanceJSON(
                       SingleInstanceShutdownRequest.self,
                       from: url
                   ),
                   duplicateShutdownRequestURL(
                       rootDirectory: directoryURL,
                       target: request.target,
                       generation: request.generation
                   ).standardizedFileURL == url.standardizedFileURL {
                    let age = now - request.createdAtUnixSeconds
                    guard request.version == SingleInstanceShutdownRequest.currentVersion,
                          request.createdAtUnixSeconds.isFinite,
                          age >= 0 else { return nil }
                    requests.append((url, request))
                    continue
                }

                if url.lastPathComponent.hasPrefix("ack-"),
                   let acknowledgment = readBoundedSingleInstanceJSON(
                       SingleInstanceShutdownAcknowledgment.self,
                       from: url
                   ),
                   duplicateShutdownAcknowledgmentURL(
                       rootDirectory: directoryURL,
                       target: acknowledgment.target
                   ).standardizedFileURL == url.standardizedFileURL {
                    let age = now - acknowledgment.createdAtUnixSeconds
                    guard acknowledgment.version == SingleInstanceShutdownAcknowledgment.currentVersion,
                          acknowledgment.createdAtUnixSeconds.isFinite,
                          age >= 0 else { return nil }
                    acknowledgments.append((url, acknowledgment))
                    continue
                }

                return nil
            }

            var retainedURLs: [URL] = []
            var removedCount = 0
            for (url, request) in requests {
                let age = now - request.createdAtUnixSeconds
                let isStale = age > duplicateShutdownRequestMaxAge
                    && (!isProcessLive(request.target) || !isProcessLive(request.requester))
                if isStale {
                    let pending = PendingSingleInstanceShutdown(
                        request: request,
                        requestURL: url,
                        acknowledgmentURL: duplicateShutdownAcknowledgmentURL(
                            rootDirectory: directoryURL,
                            target: request.target
                        )
                    )
                    guard removeExactRequest(pending) else { return nil }
                    removedCount += 1
                } else {
                    retainedURLs.append(url)
                }
            }
            for (url, acknowledgment) in acknowledgments {
                let age = now - acknowledgment.createdAtUnixSeconds
                let isStale = age > duplicateShutdownRequestMaxAge
                    && !isProcessLive(acknowledgment.target)
                if isStale {
                    guard removeExactAcknowledgment(
                        target: acknowledgment.target,
                        url: url
                    ) else { return nil }
                    removedCount += 1
                } else {
                    retainedURLs.append(url)
                }
            }

            if exceededScanLimit {
                guard removedCount > 0 else { return nil }
                continue
            }
            guard retainedURLs.count <= duplicateStateDirectoryMaxEntries else { return nil }
            return retainedURLs
        }
        return nil
    }

    nonisolated private static func hasValidAcknowledgment(
        for pending: PendingSingleInstanceShutdown,
        now: TimeInterval
    ) -> Bool {
        let acknowledgment = readBoundedSingleInstanceJSON(
            SingleInstanceShutdownAcknowledgment.self,
            from: pending.acknowledgmentURL
        )
        return shouldAcceptDuplicateShutdownAcknowledgment(
            acknowledgment,
            expectedTarget: pending.request.target,
            requestCreatedAt: pending.request.createdAtUnixSeconds,
            now: now
        )
    }

    private static func writeDuplicateShutdownRequest(
        target: ProgramaSingleInstanceProcessKey,
        requester: ProgramaSingleInstanceProcessKey
    ) -> PendingSingleInstanceShutdown? {
        guard let directoryURL = validatedSingleInstanceStateDirectory(),
              preparedSingleInstanceStateURLs(
                  in: directoryURL,
                  now: Date().timeIntervalSince1970,
                  isProcessLive: { singleInstanceProcessKey(for: $0.processIdentifier) == $0 }
              ) != nil else {
            dilog("single_instance", "pid=\(target.processIdentifier) outcome=rejected reason=state_directory")
            return nil
        }
        let request = SingleInstanceShutdownRequest(
            target: target,
            requester: requester,
            createdAtUnixSeconds: Date().timeIntervalSince1970
        )
        let pending = PendingSingleInstanceShutdown(
            request: request,
            requestURL: duplicateShutdownRequestURL(
                rootDirectory: directoryURL,
                target: target,
                generation: request.generation
            ),
            acknowledgmentURL: duplicateShutdownAcknowledgmentURL(
                rootDirectory: directoryURL,
                target: target
            )
        )
        guard writeBoundedSingleInstanceJSON(request, to: pending.requestURL) else {
            dilog("single_instance", "pid=\(target.processIdentifier) outcome=failed reason=request_write")
            return nil
        }
        dilog("single_instance", "pid=\(target.processIdentifier) outcome=written reason=shutdown_request")
        return pending
    }

    private func acknowledgeValidatedDuplicateShutdownRequest() -> Bool {
        let currentProcessIdentifier = getpid()
        guard let currentKey = Self.singleInstanceProcessKey(for: currentProcessIdentifier),
              let bundleIdentifier = Bundle.main.bundleIdentifier,
              let directoryURL = Self.validatedSingleInstanceStateDirectory(),
              let stateURLs = Self.preparedSingleInstanceStateURLs(
                  in: directoryURL,
                  now: Date().timeIntervalSince1970,
                  isProcessLive: { Self.singleInstanceProcessKey(for: $0.processIdentifier) == $0 }
              ) else {
            dilog("single_instance", "pid=\(currentProcessIdentifier) outcome=rejected reason=state_directory")
            return false
        }
        let requestPrefix = "request-\(Self.singleInstanceTargetComponent(currentKey))-"
        let embeddedCLIURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/bin/programa", isDirectory: false)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let targetRequestURLs = stateURLs.filter {
            $0.lastPathComponent.hasPrefix(requestPrefix)
        }
        guard targetRequestURLs.count <= Self.duplicateTargetRequestScanLimit else {
            dilog("single_instance", "pid=\(currentProcessIdentifier) outcome=rejected reason=request_limit")
            return false
        }
        for requestURL in targetRequestURLs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let request = Self.readBoundedSingleInstanceJSON(
                SingleInstanceShutdownRequest.self,
                from: requestURL
            ) else {
                continue
            }
            let requesterApplication = NSRunningApplication(
                processIdentifier: request.requesterProcessIdentifier
            )
            let requesterIsProgramaGUI = requesterApplication.map { application in
                Self.shouldConsiderDuplicateApplication(
                    candidateBundleIdentifier: application.bundleIdentifier,
                    candidateProcessIdentifier: application.processIdentifier,
                    candidateExecutableURL: application.executableURL,
                    expectedBundleIdentifier: bundleIdentifier,
                    currentProcessIdentifier: currentProcessIdentifier,
                    embeddedCLIURL: embeddedCLIURL
                )
                && Self.isAuthenticatedProgramaApplication(
                    expectedProcessKey: request.requester
                )
            } ?? false
            guard Self.shouldAcceptDuplicateShutdownRequest(
                request,
                currentProcessKey: currentKey,
                now: Date().timeIntervalSince1970,
                resolvedRequesterKey: Self.singleInstanceProcessKey(
                    for: request.requesterProcessIdentifier
                ),
                requesterIsProgramaGUI: requesterIsProgramaGUI
            ) else {
                continue
            }
            let published = Self.publishDuplicateAcknowledgment(
                rootDirectory: directoryURL,
                request: request,
                currentProcessKey: currentKey,
                now: Date().timeIntervalSince1970,
                write: { acknowledgment, url in
                    Self.writeBoundedSingleInstanceJSON(acknowledgment, to: url)
                }
            )
            if !published {
                dilog("single_instance", "pid=\(currentProcessIdentifier) outcome=rejected reason=ack_write")
                continue
            }
            acknowledgedDuplicateShutdown = (
                currentKey, request.generation,
                Self.duplicateShutdownAcknowledgmentURL(rootDirectory: directoryURL, target: currentKey)
            )
            dilog("single_instance", "pid=\(currentProcessIdentifier) outcome=accepted reason=shutdown_request")
            return true
        }
        dilog("single_instance", "pid=\(currentProcessIdentifier) outcome=missing reason=shutdown_request")
        return false
    }

    private func revokeAcknowledgedDuplicateShutdown() {
        guard let ack = acknowledgedDuplicateShutdown else { return }
        _ = Self.removeExactAcknowledgment(
            target: ack.target, acceptedGeneration: ack.generation, url: ack.url
        )
        acknowledgedDuplicateShutdown = nil
    }

    private static func duplicateFallbackState(
        app: NSRunningApplication,
        pending: PendingSingleInstanceShutdown,
        response: SingleInstanceForcePromptResponse?
    ) -> (SingleInstanceFallbackAction, NSRunningApplication?) {
        let processIdentifier = pending.request.target.processIdentifier
        let resolvedApplication = NSRunningApplication(processIdentifier: processIdentifier)
        let action = duplicateFallbackAction(
            hasValidTargetAcknowledgment: hasValidAcknowledgment(
                for: pending,
                now: Date().timeIntervalSince1970
            ),
            requestGenerationIsPending: isExactRequestPending(pending),
            processIdentityMatches: singleInstanceProcessKey(for: processIdentifier) == pending.request.target,
            isTerminated: resolvedApplication?.isTerminated ?? app.isTerminated,
            response: response
        )
        return (action, resolvedApplication)
    }

    @MainActor
    private static func promptForDuplicateForceClose() -> SingleInstanceForcePromptResponse {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = String(
            localized: "dialog.singleInstanceNotResponding.title",
            defaultValue: "Existing Programa Is Still Open"
        )
        alert.informativeText = String(
            localized: "dialog.singleInstanceNotResponding.message",
            defaultValue: "The existing Programa instance did not quit. Force closing it may lose unsaved terminal or session state."
        )
        let cancelButton = alert.addButton(
            withTitle: String(localized: "common.cancel", defaultValue: "Cancel")
        )
        cancelButton.keyEquivalent = "\u{1b}"
        let forceCloseButton = alert.addButton(withTitle: String(
            localized: "dialog.singleInstanceNotResponding.forceClose",
            defaultValue: "Force Close"
        ))
        forceCloseButton.keyEquivalent = ""
        alert.window.defaultButtonCell = cancelButton.cell as? NSButtonCell

        let button: SingleInstanceForcePromptButton
        switch alert.runModal() {
        case .alertFirstButtonReturn: button = .primary
        case .alertSecondButtonReturn: button = .secondary
        default: button = .escape
        }
        return duplicateForcePromptResponse(button: button)
    }

    @MainActor
    private static func handleDuplicateShutdownFallback(
        app: NSRunningApplication,
        pending: PendingSingleInstanceShutdown
    ) {
        let processIdentifier = pending.request.target.processIdentifier
        let (initialAction, _) = duplicateFallbackState(app: app, pending: pending, response: nil)
        if initialAction == .waitForAcknowledgedExit {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { @MainActor in handleDuplicateShutdownFallback(app: app, pending: pending) }
            return
        }
        guard initialAction == .prompt else {
            removeExactShutdownState(pending)
            dilog("single_instance", "pid=\(processIdentifier) outcome=skipped reason=fallback_revalidated")
            return
        }

        dilog("single_instance", "pid=\(processIdentifier) outcome=prompted reason=grace_expired")
        let response = promptForDuplicateForceClose()
        switch response {
        case .forceClose:
            dilog("single_instance", "pid=\(processIdentifier) outcome=consented reason=force_close")
        case .cancel:
            dilog("single_instance", "pid=\(processIdentifier) outcome=cancelled reason=user_cancel")
        }
        let (action, resolvedApplication) = duplicateFallbackState(
            app: app,
            pending: pending,
            response: response
        )
        switch action {
        case .force:
            guard let resolvedApplication else {
                removeExactShutdownState(pending)
                dilog("single_instance", "pid=\(processIdentifier) outcome=skipped reason=no_longer_running")
                return
            }
            let forced = resolvedApplication.forceTerminate()
            removeExactShutdownState(pending)
            dilog(
                "single_instance",
                "pid=\(processIdentifier) outcome=\(forced ? "forced" : "force_rejected") reason=user_consent"
            )
        case .exitNewer:
            removeExactShutdownState(pending)
            resolvedApplication?.activate(options: [.activateAllWindows])
            AppDelegate.shared?.appLifecycleCoordinator.confirmSingleInstanceLoser()
            dilog("single_instance", "pid=\(processIdentifier) outcome=exiting_newer reason=user_cancel")
            NSApp.terminate(nil)
        case .skip:
            removeExactShutdownState(pending)
            dilog("single_instance", "pid=\(processIdentifier) outcome=skipped reason=post_prompt_revalidation")
        case .waitForAcknowledgedExit:
            handleDuplicateShutdownFallback(app: app, pending: pending)
        case .prompt:
            removeExactShutdownState(pending)
            dilog("single_instance", "pid=\(processIdentifier) outcome=skipped reason=invalid_prompt_state")
        }
    }

    private static func terminateDuplicateApplication(
        _ app: NSRunningApplication,
        expectedProcessKey: ProgramaSingleInstanceProcessKey,
        requesterProcessKey: ProgramaSingleInstanceProcessKey
    ) {
        let processIdentifier = app.processIdentifier
        var pendingShutdown: PendingSingleInstanceShutdown?
        scheduleDuplicateTermination(
            requestTermination: {
                guard let pending = writeDuplicateShutdownRequest(
                    target: expectedProcessKey,
                    requester: requesterProcessKey
                ) else {
                    return false
                }
                pendingShutdown = pending
                let accepted = app.terminate()
                dilog(
                    "single_instance",
                    "pid=\(processIdentifier) outcome=\(accepted ? "requested" : "request_rejected") reason=graceful_terminate"
                )
                return shouldScheduleDuplicateFallback(
                    requestWasWritten: true,
                    gracefulTerminationAccepted: accepted
                )
            },
            scheduleGrace: { action in
                DispatchQueue.main.asyncAfter(deadline: .now() + duplicateTerminationGraceInterval) { @MainActor in
                    action()
                }
            },
            performFallbackAfterGrace: {
                guard let pendingShutdown else {
                    dilog("single_instance", "pid=\(processIdentifier) outcome=skipped reason=missing_generation")
                    return
                }
                handleDuplicateShutdownFallback(app: app, pending: pendingShutdown)
            }
        )
    }

    private func enforceSingleInstance() {
        guard let bundleId = Bundle.main.bundleIdentifier else { return }
        let embeddedCLIURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/bin/programa", isDirectory: false)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let currentPid = NSRunningApplication.current.processIdentifier
        guard let currentKey = Self.singleInstanceProcessKey(for: currentPid) else { return }

        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleId) {
            guard Self.shouldConsiderDuplicateApplication(
                candidateBundleIdentifier: app.bundleIdentifier,
                candidateProcessIdentifier: app.processIdentifier,
                candidateExecutableURL: app.executableURL,
                expectedBundleIdentifier: bundleId,
                currentProcessIdentifier: currentPid,
                embeddedCLIURL: embeddedCLIURL
            ) else {
                continue
            }
            guard let otherKey = Self.singleInstanceProcessKey(for: app.processIdentifier) else {
                continue
            }
            guard Self.isAuthenticatedProgramaApplication(expectedProcessKey: otherKey) else {
                continue
            }
            guard Self.shouldTerminateDuplicateInstance(current: currentKey, other: otherKey) else {
                dilog("single_instance", "pid=\(app.processIdentifier) outcome=ignored reason=election")
                continue
            }
            Self.terminateDuplicateApplication(
                app,
                expectedProcessKey: otherKey,
                requesterProcessKey: currentKey
            )
        }
    }

    private func observeDuplicateLaunches() {
        guard workspaceObserver == nil else { return }
        guard let bundleId = Bundle.main.bundleIdentifier else { return }
        let embeddedCLIURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/bin/programa", isDirectory: false)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let currentPid = NSRunningApplication.current.processIdentifier
        guard let currentKey = Self.singleInstanceProcessKey(for: currentPid) else { return }

        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard self != nil else { return }
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            guard Self.shouldConsiderDuplicateApplication(
                candidateBundleIdentifier: app.bundleIdentifier,
                candidateProcessIdentifier: app.processIdentifier,
                candidateExecutableURL: app.executableURL,
                expectedBundleIdentifier: bundleId,
                currentProcessIdentifier: currentPid,
                embeddedCLIURL: embeddedCLIURL
            ) else {
                return
            }
            guard let otherKey = Self.singleInstanceProcessKey(for: app.processIdentifier) else {
                return
            }
            guard Self.isAuthenticatedProgramaApplication(expectedProcessKey: otherKey) else {
                return
            }
            guard Self.shouldTerminateDuplicateInstance(current: currentKey, other: otherKey) else {
                dilog("single_instance", "pid=\(app.processIdentifier) outcome=ignored reason=election")
                return
            }
            MainActor.assumeIsolated {
                Self.terminateDuplicateApplication(
                    app,
                    expectedProcessKey: otherKey,
                    requesterProcessKey: currentKey
                )
                NSRunningApplication.current.activate(options: [.activateAllWindows])
            }
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        DispatchQueue.main.async { [weak self] in
            self?.handleNotificationResponse(response)
            completionHandler()
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler(AppNotificationRouter.presentationOptions(hasSound: notification.request.content.sound != nil))
    }

    private func handleNotificationResponse(_ response: UNNotificationResponse) {
        let request = response.notification.request
        switch AppNotificationRouter.route(
            actionIdentifier: response.actionIdentifier,
            requestIdentifier: request.identifier,
            userInfo: request.content.userInfo
        ) {
        case .activateApplication:
            NSApp.activate(ignoringOtherApps: true)
        case .open(let tabId, let surfaceId, let notificationId):
            _ = openNotification(tabId: tabId, surfaceId: surfaceId, notificationId: notificationId)
        case .markRead(let notificationId):
            notificationStore?.markRead(id: notificationId)
        case .ignore:
            break
        }
    }

    private func installMainWindowKeyObserver() {
        guard windowKeyObserver == nil else { return }
        windowKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let window = note.object as? NSWindow else { return }
                self.setActiveMainWindow(window)
            }
        }
    }

    private func installBrowserAddressBarFocusObservers() {
        guard browserAddressBarFocusObserver == nil, browserAddressBarBlurObserver == nil else { return }

        browserAddressBarFocusObserver = NotificationCenter.default.addObserver(
            forName: .browserDidFocusAddressBar,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard let panelId = notification.object as? UUID else { return }
                self.browserPanel(for: panelId)?.beginSuppressWebViewFocusForAddressBar()
                self.browserAddressBarFocusedPanelId = panelId
                self.stopBrowserOmnibarSelectionRepeat()
#if DEBUG
                dlog("addressBar FOCUS panelId=\(panelId.uuidString.prefix(8))")
#endif
            }
        }

        browserAddressBarBlurObserver = NotificationCenter.default.addObserver(
            forName: .browserDidBlurAddressBar,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard let panelId = notification.object as? UUID else { return }
                self.browserPanel(for: panelId)?.endSuppressWebViewFocusForAddressBar()
                if self.browserAddressBarFocusedPanelId == panelId {
                    self.browserAddressBarFocusedPanelId = nil
                    self.stopBrowserOmnibarSelectionRepeat()
#if DEBUG
                    dlog("addressBar BLUR panelId=\(panelId.uuidString.prefix(8))")
#endif
                }
            }
        }
    }

    private func browserPanel(for panelId: UUID) -> BrowserPanel? {
        return tabManager?.selectedWorkspace?.browserPanel(for: panelId)
    }

    fileprivate func browserFindBarIsVisible(for webView: ProgramaWebView) -> Bool {
        browserPanelOwning(webView)?.searchState != nil
    }

    private func shouldLetFocusedBrowserOwnFindShortcut(_ event: NSEvent) -> Bool {
        let shortcutWindow = resolvedShortcutEventWindow(event) ?? NSApp.keyWindow ?? NSApp.mainWindow
        let shortcutResponder = shortcutWindow?.firstResponder
        let owningWebView = tabManager?.focusedBrowserPanel?.webView as? ProgramaWebView
        guard let owningWebView else { return false }
        return shouldRouteBrowserFindCommandEquivalentThroughWebContentFirst(
            event,
            responder: shortcutResponder,
            owningWebView: owningWebView
        )
    }

    private func browserPanelOwning(_ webView: ProgramaWebView) -> BrowserPanel? {
        var candidateManagers: [TabManager] = []
        var seenManagers = Set<ObjectIdentifier>()

        func appendCandidate(_ manager: TabManager?) {
            guard let manager else { return }
            let identifier = ObjectIdentifier(manager)
            guard seenManagers.insert(identifier).inserted else { return }
            candidateManagers.append(manager)
        }

        if let window = webView.window,
           let context = contextForMainWindow(window) {
            appendCandidate(context.tabManager)
        }
        appendCandidate(tabManager)
        for context in mainWindowContexts.values {
            appendCandidate(context.tabManager)
        }

        for manager in candidateManagers {
            if let panel = browserPanelOwning(webView, in: manager) {
                return panel
            }
        }
        return nil
    }

    private func browserPanelOwning(_ webView: ProgramaWebView, in manager: TabManager) -> BrowserPanel? {
        for workspace in manager.tabs {
            if let panel = workspace.panels.values
                .compactMap({ $0 as? BrowserPanel })
                .first(where: { $0.webView === webView }) {
                return panel
            }
        }
        return nil
    }

    private func setActiveMainWindow(_ window: NSWindow) {
        guard let context = contextForMainTerminalWindow(window) else { return }
        if window.isVisible {
            context.hiddenWindow = nil
            context.hiddenAt = nil
        }
#if DEBUG
        let beforeManagerToken = debugManagerToken(tabManager)
#endif
        tabManager = context.tabManager
        sidebarState = context.sidebarState
        sidebarSelectionState = context.sidebarSelectionState
        TerminalController.shared.setActiveTabManager(context.tabManager)
#if DEBUG
        dlog(
            "mainWindow.active window={\(debugWindowToken(window))} context={\(debugContextToken(context))} beforeMgr=\(beforeManagerToken) afterMgr=\(debugManagerToken(tabManager)) \(debugShortcutRouteSnapshot())"
        )
#endif
    }

    private func unregisterMainWindow(_ window: NSWindow) {
        // Reset cascade point so the next new window appears near the closing
        // window's position, matching upstream Ghostty behavior.
        let frame = window.frame
        lastCascadePoint = NSPoint(x: frame.minX, y: frame.maxY)

        // Keep geometry available as a fallback even if the full session snapshot
        // is removed when the last window closes.
        persistWindowGeometry(from: window)
        guard let removed = unregisterMainWindowContext(for: window) else { return }
        teardownCommandPaletteState(for: removed.windowId)

        // Avoid stale notifications that can no longer be opened once the owning window is gone.
        if let store = notificationStore {
            for tab in removed.tabManager.tabs {
                store.clearNotifications(forTabId: tab.id)
            }
        }

        // `browserAddressBarFocusedPanelId` is a single app-wide pointer, not scoped to
        // any particular window, and nothing else proactively invalidates it when its
        // owning panel goes away. A stale non-nil value here makes
        // `commandOmnibarSelectionDelta` report `hasFocusedAddressBar = true` for every
        // window afterward, silently hijacking Cmd+N/Cmd+P/Ctrl+N/Ctrl+P in *other*
        // windows as omnibar-suggestion navigation instead of their normal shortcut
        // action. Check across all *remaining* live windows -- rather than just this
        // window's (possibly already-torn-down) tab list -- since teardown order
        // between this window's own workspace/panel cleanup and this notification
        // handler is not guaranteed, and checking only `removed.tabManager` can miss a
        // panel that was already removed from it by the time this runs.
        if let focusedPanelId = browserAddressBarFocusedPanelId,
           !mainWindowContexts.values.contains(where: { context in
               context.tabManager.tabs.contains(where: { $0.panels[focusedPanelId] != nil })
           }) {
            browserAddressBarFocusedPanelId = nil
            stopBrowserOmnibarSelectionRepeat()
        }

        if tabManager === removed.tabManager {
            // Repoint "active" pointers to any remaining main terminal window.
            let nextContext: MainWindowContext? = {
                if let keyWindow = NSApp.keyWindow,
                   let ctx = contextForMainTerminalWindow(keyWindow, reindex: false) {
                    return ctx
                }
                return mainWindowContexts.values.first
            }()

            if let nextContext {
                tabManager = nextContext.tabManager
                sidebarState = nextContext.sidebarState
                sidebarSelectionState = nextContext.sidebarSelectionState
                TerminalController.shared.setActiveTabManager(nextContext.tabManager)
            } else {
                tabManager = nil
                sidebarState = nil
                sidebarSelectionState = nil
                TerminalController.shared.setActiveTabManager(nil)
            }
        }

        teardownMainWindowContext(removed)

        // During app termination we already persisted a full snapshot (with scrollback)
        // in applicationShouldTerminate/applicationWillTerminate. Saving again here would
        // overwrite it as windows tear down one-by-one, dropping closed windows and replay.
        if Self.shouldPersistSnapshotOnWindowUnregister(isTerminatingApp: isTerminatingApp) {
            saveSessionSnapshot(
                includeScrollback: false,
                removeWhenEmpty: Self.shouldRemoveSnapshotWhenNoWindowsRemainOnWindowUnregister(
                    isTerminatingApp: isTerminatingApp
                )
            )
        }
    }

    private func isMainTerminalWindow(_ window: NSWindow) -> Bool {
        if mainWindowContexts[ObjectIdentifier(window)] != nil {
            return true
        }
        guard let raw = window.identifier?.rawValue else { return false }
        return raw == "cmux.main" || raw.hasPrefix("cmux.main.")
    }

    private func contextContainingTabId(_ tabId: UUID) -> MainWindowContext? {
        for context in mainWindowContexts.values {
            if context.tabManager.tabs.contains(where: { $0.id == tabId }) {
                return context
            }
        }
        return nil
    }

    /// Returns the `TabManager` that owns `tabId`, if any.
    func tabManagerFor(tabId: UUID) -> TabManager? {
        contextContainingTabId(tabId)?.tabManager
    }

    private func workspaceForMainActor(tabId: UUID) -> Workspace? {
        contextContainingTabId(tabId)?.tabManager.tabs.first(where: { $0.id == tabId })
    }

    /// Returns the `Workspace` that owns `tabId`, if any.
    @MainActor
    func workspaceFor(tabId: UUID) -> Workspace? {
        workspaceForMainActor(tabId: tabId)
    }

    func closeMainWindowContainingTabId(_ tabId: UUID) {
        guard let context = contextContainingTabId(tabId) else { return }
        let expectedIdentifier = "cmux.main.\(context.windowId.uuidString)"
        let window: NSWindow? = context.window ?? NSApp.windows.first(where: { $0.identifier?.rawValue == expectedIdentifier })
        if let window { disposeMainWindow(window) }
    }

    @discardableResult
    func openNotification(tabId: UUID, surfaceId: UUID?, notificationId: UUID?) -> Bool {
#if DEBUG
        let isJumpUnreadUITest = ProcessInfo.processInfo.environment["PROGRAMA_UI_TEST_JUMP_UNREAD_SETUP"] == "1"
        if isJumpUnreadUITest {
            writeJumpUnreadTestData([
                "jumpUnreadOpenCalled": "1",
                "jumpUnreadOpenTabId": tabId.uuidString,
                "jumpUnreadOpenSurfaceId": surfaceId?.uuidString ?? "",
            ])
        }
#endif
        guard let context = contextContainingTabId(tabId) else {
#if DEBUG
            recordMultiWindowNotificationOpenFailureIfNeeded(
                tabId: tabId,
                surfaceId: surfaceId,
                notificationId: notificationId,
                reason: "missing_context"
            )
#endif
#if DEBUG
            if isJumpUnreadUITest {
                writeJumpUnreadTestData(["jumpUnreadOpenContextFound": "0", "jumpUnreadOpenUsedFallback": "1"])
            }
#endif
            let ok = openNotificationFallback(tabId: tabId, surfaceId: surfaceId, notificationId: notificationId)
#if DEBUG
            if isJumpUnreadUITest {
                writeJumpUnreadTestData(["jumpUnreadOpenResult": ok ? "1" : "0"])
            }
#endif
            return ok
        }
#if DEBUG
        if isJumpUnreadUITest {
            writeJumpUnreadTestData(["jumpUnreadOpenContextFound": "1", "jumpUnreadOpenUsedFallback": "0"])
        }
#endif
        return openNotificationInContext(context, tabId: tabId, surfaceId: surfaceId, notificationId: notificationId)
    }

    private func openNotificationInContext(_ context: MainWindowContext, tabId: UUID, surfaceId: UUID?, notificationId: UUID?) -> Bool {
        let expectedIdentifier = "cmux.main.\(context.windowId.uuidString)"
        let window: NSWindow? = context.window ?? NSApp.windows.first(where: { $0.identifier?.rawValue == expectedIdentifier })
        guard let window else {
#if DEBUG
            recordMultiWindowNotificationOpenFailureIfNeeded(
                tabId: tabId,
                surfaceId: surfaceId,
                notificationId: notificationId,
                reason: "missing_window expectedIdentifier=\(expectedIdentifier)"
            )
#endif
            return false
        }

        context.sidebarSelectionState.selection = .tabs
        bringToFront(window)
        guard context.tabManager.focusTabFromNotification(tabId, surfaceId: surfaceId) else {
#if DEBUG
            recordMultiWindowNotificationOpenFailureIfNeeded(
                tabId: tabId,
                surfaceId: surfaceId,
                notificationId: notificationId,
                reason: "focus_failed"
            )
            if ProcessInfo.processInfo.environment["PROGRAMA_UI_TEST_JUMP_UNREAD_SETUP"] == "1" {
                writeJumpUnreadTestData(["jumpUnreadOpenResult": "0"])
            }
#endif
            return false
        }

#if DEBUG
        // UI test support: Jump-to-unread asserts that the correct workspace/panel is focused.
        // Recording via first-responder can be flaky on the VM, so verify focus via the model.
        recordJumpUnreadFocusFromModelIfNeeded(
            tabManager: context.tabManager,
            tabId: tabId,
            expectedSurfaceId: surfaceId
        )
#endif

        if let notificationId, let store = notificationStore {
            markReadIfFocused(
                notificationId: notificationId,
                tabId: tabId,
                surfaceId: surfaceId,
                tabManager: context.tabManager,
                notificationStore: store
            )
        }

#if DEBUG
        recordMultiWindowNotificationFocusIfNeeded(
            windowId: context.windowId,
            tabId: tabId,
            surfaceId: surfaceId,
            sidebarSelection: context.sidebarSelectionState.selection
        )
        if ProcessInfo.processInfo.environment["PROGRAMA_UI_TEST_JUMP_UNREAD_SETUP"] == "1" {
            writeJumpUnreadTestData(["jumpUnreadOpenInContext": "1", "jumpUnreadOpenResult": "1"])
        }
#endif
        return true
    }

    private func openNotificationFallback(tabId: UUID, surfaceId: UUID?, notificationId: UUID?) -> Bool {
        // If the owning window context hasn't been registered yet, fall back to the "active" window.
        guard let tabManager else {
#if DEBUG
            if ProcessInfo.processInfo.environment["PROGRAMA_UI_TEST_JUMP_UNREAD_SETUP"] == "1" {
                writeJumpUnreadTestData(["jumpUnreadFallbackFail": "missing_tabManager"])
            }
#endif
            return false
        }
        guard tabManager.tabs.contains(where: { $0.id == tabId }) else {
#if DEBUG
            if ProcessInfo.processInfo.environment["PROGRAMA_UI_TEST_JUMP_UNREAD_SETUP"] == "1" {
                writeJumpUnreadTestData(["jumpUnreadFallbackFail": "tab_not_in_active_manager"])
            }
#endif
            return false
        }
        guard let window = (NSApp.keyWindow ?? NSApp.windows.first(where: { isMainTerminalWindow($0) })) else {
#if DEBUG
            if ProcessInfo.processInfo.environment["PROGRAMA_UI_TEST_JUMP_UNREAD_SETUP"] == "1" {
                writeJumpUnreadTestData(["jumpUnreadFallbackFail": "missing_window"])
            }
#endif
            return false
        }

        sidebarSelectionState?.selection = .tabs
        bringToFront(window)
        guard tabManager.focusTabFromNotification(tabId, surfaceId: surfaceId) else {
#if DEBUG
            if ProcessInfo.processInfo.environment["PROGRAMA_UI_TEST_JUMP_UNREAD_SETUP"] == "1" {
                writeJumpUnreadTestData([
                    "jumpUnreadFallbackFail": "focus_failed",
                    "jumpUnreadOpenResult": "0",
                ])
            }
#endif
            return false
        }

#if DEBUG
        recordJumpUnreadFocusFromModelIfNeeded(
            tabManager: tabManager,
            tabId: tabId,
            expectedSurfaceId: surfaceId
        )
#endif

        if let notificationId, let store = notificationStore {
            markReadIfFocused(
                notificationId: notificationId,
                tabId: tabId,
                surfaceId: surfaceId,
                tabManager: tabManager,
                notificationStore: store
            )
        }
#if DEBUG
        if ProcessInfo.processInfo.environment["PROGRAMA_UI_TEST_JUMP_UNREAD_SETUP"] == "1" {
            writeJumpUnreadTestData(["jumpUnreadOpenInFallback": "1", "jumpUnreadOpenResult": "1"])
        }
#endif
        return true
    }

#if DEBUG
    private func recordJumpUnreadFocusFromModelIfNeeded(
        tabManager: TabManager,
        tabId: UUID,
        expectedSurfaceId: UUID?
    ) {
        let env = ProcessInfo.processInfo.environment
        guard env["PROGRAMA_UI_TEST_JUMP_UNREAD_SETUP"] == "1" else { return }
        guard let expectedSurfaceId else { return }

        // Ensure the expectation is armed even if the view doesn't become first responder.
        armJumpUnreadFocusRecord(tabId: tabId, surfaceId: expectedSurfaceId)

        if tabManager.selectedTabId == tabId,
           tabManager.focusedSurfaceId(for: tabId) == expectedSurfaceId {
            recordJumpUnreadFocusIfExpected(tabId: tabId, surfaceId: expectedSurfaceId)
            return
        }

        var resolved = false
        var observers: [NSObjectProtocol] = []
        var cancellables: [AnyCancellable] = []

        func cleanup() {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers.removeAll()
            cancellables.forEach { $0.cancel() }
            cancellables.removeAll()
        }

        @MainActor
        func finishIfFocused() {
            guard !resolved else { return }
            guard tabManager.selectedTabId == tabId,
                  tabManager.focusedSurfaceId(for: tabId) == expectedSurfaceId else {
                return
            }
            resolved = true
            cleanup()
            self.recordJumpUnreadFocusIfExpected(tabId: tabId, surfaceId: expectedSurfaceId)
        }

        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyDidFocusSurface,
            object: nil,
            queue: .main
        ) { note in
            guard let surfaceId = note.userInfo?[GhosttyNotificationKey.surfaceId] as? UUID,
                  surfaceId == expectedSurfaceId else { return }
            Task { @MainActor in finishIfFocused() }
        })
        cancellables.append(tabManager.$selectedTabId.sink { _ in
            Task { @MainActor in finishIfFocused() }
        })
        if let workspace = tabManager.tabs.first(where: { $0.id == tabId }) {
            cancellables.append(workspace.$panels
                .map { _ in () }
                .sink { _ in
                    Task { @MainActor in finishIfFocused() }
                })
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            Task { @MainActor in
                guard !resolved else { return }
                cleanup()
            }
        }
        Task { @MainActor in finishIfFocused() }
    }
#endif

    func tabTitle(for tabId: UUID) -> String? {
        if let context = contextContainingTabId(tabId) {
            return context.tabManager.tabs.first(where: { $0.id == tabId })?.title
        }
        return tabManager?.tabs.first(where: { $0.id == tabId })?.title
    }

    private func bringToFront(_ window: NSWindow) {
        if TerminalController.shouldSuppressSocketCommandActivation(),
           !TerminalController.socketCommandAllowsInAppFocusMutations() {
            return
        }
        setActiveMainWindow(window)
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        if let context = contextForMainTerminalWindow(window) {
            context.hiddenWindow = nil
            context.hiddenAt = nil
        }
        // Improve reliability across Spaces / when other helper panels are key.
        NSRunningApplication.current.activate(options: [.activateAllWindows])
    }

    private func markReadIfFocused(
        notificationId: UUID,
        tabId: UUID,
        surfaceId: UUID?,
        tabManager: TabManager,
        notificationStore: TerminalNotificationStore
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard tabManager.selectedTabId == tabId else { return }
            if let surfaceId {
                guard tabManager.focusedSurfaceId(for: tabId) == surfaceId else { return }
            }
            notificationStore.markRead(id: notificationId)
        }
    }

#if DEBUG
    private func recordMultiWindowNotificationOpenFailureIfNeeded(
        tabId: UUID,
        surfaceId: UUID?,
        notificationId: UUID?,
        reason: String
    ) {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["PROGRAMA_UI_TEST_MULTI_WINDOW_NOTIF_PATH"], !path.isEmpty else { return }

        let contextSummaries: [String] = mainWindowContexts.values.map { ctx in
            let tabIds = ctx.tabManager.tabs.map { $0.id.uuidString }.joined(separator: ",")
            let hasWindow = (ctx.window != nil) ? "1" : "0"
            return "windowId=\(ctx.windowId.uuidString) hasWindow=\(hasWindow) tabs=[\(tabIds)]"
        }

        writeMultiWindowNotificationTestData([
            "focusToken": UUID().uuidString,
            "openFailureTabId": tabId.uuidString,
            "openFailureSurfaceId": surfaceId?.uuidString ?? "",
            "openFailureNotificationId": notificationId?.uuidString ?? "",
            "openFailureReason": reason,
            "openFailureContexts": contextSummaries.joined(separator: "; "),
        ], at: path)
    }
#endif

    /// Configures a Programa main window's AppKit-level presentation (identifier,
    /// titlebar, movability, transparency, glass effect, decorations) and registers
    /// it for window-context tracking, then installs the file-drop overlay.
    ///
    /// Extracted verbatim from `ContentView`'s `WindowAccessor` trailing closure
    /// (nuclear-review CV2b) so this AppKit window mutation lives with the
    /// window-context layer instead of the SwiftUI view layer. `ContentView` still
    /// owns tracking its own `@State` (`observedWindow`, `isFullScreen`,
    /// `titlebarPadding`) — this method returns the computed titlebar padding so
    /// the caller can decide whether to update that `@State`.
    @discardableResult
    func configureMainWindow(
        _ window: NSWindow,
        windowId: UUID,
        windowIdentifier: String,
        tabManager: TabManager,
        sidebarState: SidebarState,
        sidebarSelectionState: SidebarSelectionState,
        sidebarBlendMode: String,
        bgGlassEnabled: Bool,
        bgGlassTintHex: String,
        bgGlassTintOpacity: Double
    ) -> CGFloat {
        // This function runs on every WindowAccessor update, not just once per window
        // (see the toolbar guard below), so every write here is value-diffed against
        // current state first. An unconditional set-to-same-value still fires AppKit's
        // KVO/observer machinery on each call, and repeated firing of that machinery is
        // part of what feeds the safe-area invalidation storm in issue #307 — diffing
        // stops the re-entry without changing what gets configured on first apply.
        let nextIdentifier = NSUserInterfaceItemIdentifier(windowIdentifier)
        if window.identifier != nextIdentifier {
            window.identifier = nextIdentifier
        }
        if !window.titlebarAppearsTransparent {
            window.titlebarAppearsTransparent = true
        }
        // Keep window immovable; the sidebar's WindowDragHandleView handles
        // drag-to-move via performDrag with temporary movable override.
        // isMovableByWindowBackground=true breaks tab reordering, and
        // isMovable=true blocks clicks on sidebar buttons in minimal mode.
        if window.isMovableByWindowBackground {
            window.isMovableByWindowBackground = false
        }
        if window.isMovable {
            window.isMovable = false
        }
        if !window.styleMask.contains(.fullSizeContentView) {
            window.styleMask.insert(.fullSizeContentView)
        }

        if WindowGlassEffect.isAvailable, window.toolbar == nil {
            // A `.top`-attribute NSTitlebarAccessoryViewController and an empty
            // NSToolbar were both measured to have no effect on titlebar height
            // (confirmed against the AppKit header: `.top` only replaces what's
            // drawn within the existing titlebar area, it doesn't grow it; an
            // empty toolbar reports zero height). Give the toolbar a single
            // invisible spacer item -- the same mechanism sidebar apps (Mail,
            // Notes, Finder) use -- so AppKit re-centers the traffic lights on
            // WindowGlassEffect.sidebarHeaderCenterFromWindowTop. Guarded on
            // `window.toolbar == nil` because this function runs on every
            // WindowAccessor update, not just once per window.
            let toolbar = NSToolbar(identifier: "programa.main.titlebar")
            let toolbarDelegate = MainWindowToolbarDelegate()
            objc_setAssociatedObject(
                window,
                &mainWindowToolbarDelegateAssociationKey,
                toolbarDelegate,
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
            toolbar.delegate = toolbarDelegate
            toolbar.allowsUserCustomization = false
            toolbar.autosavesConfiguration = false
            toolbar.displayMode = .iconOnly
            window.toolbar = toolbar
            window.toolbarStyle = .unified
            window.titlebarSeparatorStyle = .none
        }

        // Keep content below the titlebar so drags on Bonsplit's tab bar don't
        // get interpreted as window drags.
        let computedTitlebarHeight = window.frame.height - window.contentLayoutRect.height
        let nextTitlebarPadding = max(28, min(72, computedTitlebarHeight))
#if DEBUG
        if ProcessInfo.processInfo.environment["PROGRAMA_UI_TEST_MODE"] == "1" {
            UpdateLogStore.shared.append("ui test window accessor: id=\(windowIdentifier) visible=\(window.isVisible)")
        }
#endif
        // User settings decide whether window glass is active. The native Tahoe
        // NSGlassEffectView path vs the older NSVisualEffectView fallback is chosen
        // inside WindowGlassEffect.apply.
        let currentThemeBackground = GhosttyBackgroundTheme.currentColor()
        let shouldApplyWindowGlass = cmuxShouldApplyWindowGlass(
            bgGlassEnabled: bgGlassEnabled,
            glassEffectAvailable: WindowGlassEffect.isAvailable
        )
        let shouldForceTransparentHosting =
            shouldApplyWindowGlass || currentThemeBackground.alphaComponent < 0.999

        if shouldForceTransparentHosting {
            if window.isOpaque {
                window.isOpaque = false
            }
            // Keep the window clear whenever translucency is active. Relying only on
            // terminal focus-driven updates can leave stale opaque window fills.
            let clearBackground = NSColor.white.withAlphaComponent(0.001)
            if window.backgroundColor != clearBackground {
                window.backgroundColor = clearBackground
            }
            // Configure contentView hierarchy for transparency. The walk itself
            // skips views whose layer state already matches, so re-running it here
            // is cheap and still picks up any subviews added since the last call.
            if let contentView = window.contentView {
                ContentView.makeViewHierarchyTransparent(contentView)
            }
        } else {
            // Browser-focused workspaces may not have an active terminal panel to refresh
            // the NSWindow background. Keep opaque theme changes applied here as well.
            if window.backgroundColor != currentThemeBackground {
                window.backgroundColor = currentThemeBackground
            }
            let nextIsOpaque = currentThemeBackground.alphaComponent >= 0.999
            if window.isOpaque != nextIsOpaque {
                window.isOpaque = nextIsOpaque
            }
        }

        if shouldApplyWindowGlass {
            // Apply liquid glass effect to the window with tint from settings
            let tintColor = WindowGlassEffect.resolvedWindowTint(hex: bgGlassTintHex, opacity: bgGlassTintOpacity)
            WindowGlassEffect.apply(to: window, tintColor: tintColor)
        } else {
            WindowGlassEffect.remove(from: window)
        }
        AppDelegate.shared?.attachUpdateAccessory(to: window)
        AppDelegate.shared?.registerMainWindow(
            window,
            windowId: windowId,
            tabManager: tabManager,
            sidebarState: sidebarState,
            sidebarSelectionState: sidebarSelectionState
        )
        installFileDropOverlay(on: window, tabManager: tabManager)

        return nextTitlebarPadding
    }

}

private extension AppDelegate {
    @objc func handleThemesReloadNotification(_ notification: Notification) {
        DispatchQueue.main.async {
            GhosttyApp.shared.reloadConfiguration(source: "distributed.cmux.themes")
        }
    }
}
