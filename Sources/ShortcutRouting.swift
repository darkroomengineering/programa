import AppKit
import Foundation

/// Pure, injectable keyboard shortcut matching logic.
///
/// This was extracted from `AppDelegate`'s `matchShortcutStroke(event:stroke:)` and
/// `matchShortcut(event:shortcut:)` so the layout/chord/precedence matching matrix can be
/// table-tested without spinning up any AppKit windows or touching `AppDelegate` state.
///
/// The only behavioral change from the original `AppDelegate` methods: the original methods
/// read the instance property `AppDelegate.shortcutLayoutCharacterProvider`. Here that is an
/// explicit `layoutCharacterProvider` parameter so the functions are pure. `AppDelegate` keeps
/// thin forwarders with the original private signatures that pass its
/// `shortcutLayoutCharacterProvider` through unchanged, so all existing call sites keep working.
enum ShortcutRouting {
    /// Match a shortcut stroke against an event, handling normal keys.
    static func matchStroke(
        event: NSEvent,
        stroke: ShortcutStroke,
        layoutCharacterProvider: (UInt16, NSEvent.ModifierFlags) -> String?
    ) -> Bool {
        // Some keys can include extra flags (e.g. .function) depending on the responder chain.
        // Strip those for consistent matching across first responders.
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        guard flags == stroke.modifierFlags else { return false }

        let shortcutKey = stroke.key.lowercased()
        if shortcutKey == "\r" {
            return event.keyCode == 36 || event.keyCode == 76
        }

        let eventCharsIgnoringModifiers = event.charactersIgnoringModifiers
        if shortcutCharacterMatches(
            eventCharacter: eventCharsIgnoringModifiers,
            shortcutKey: shortcutKey,
            applyShiftSymbolNormalization: flags.contains(.shift),
            eventKeyCode: event.keyCode
        ) {
            return true
        }

        // For command-based shortcuts, trust AppKit's layout-aware characters when present.
        // Keep this strict for letter shortcuts to avoid physical-key collisions across layouts,
        // while still allowing keyCode fallback for digit/punctuation shortcuts on non-US layouts.
        // When a non-Latin input source is active (Russian, Korean, Chinese, Japanese, etc.),
        // charactersIgnoringModifiers returns non-ASCII characters that can never match
        // a Latin shortcut key — skip this guard and fall through to layout-based matching.
        let hasEventChars = !(eventCharsIgnoringModifiers?.isEmpty ?? true)
        let eventCharsAreASCII = eventCharsIgnoringModifiers?.allSatisfy(\.isASCII) ?? true
        let shortcutKeyIsDigit = shortcutKey.count == 1 && shortcutKey.first?.isNumber == true
        if shortcutKeyIsDigit,
           hasEventChars,
           eventCharsAreASCII,
           AppDelegate.digitForNumberKeyCode(event.keyCode) == nil {
            return false
        }
        if hasEventChars,
           eventCharsAreASCII,
           flags.contains(.command),
           !flags.contains(.control),
           shouldRequireCharacterMatchForCommandShortcut(shortcutKey: shortcutKey) {
            return false
        }

        // Match using the current keyboard layout so Command shortcuts stay character-based
        // across layouts (QWERTY, Dvorak, etc.) instead of being tied to ANSI physical keys.
        let layoutCharacter = layoutCharacterProvider(event.keyCode, event.modifierFlags)
        if shortcutCharacterMatches(
            eventCharacter: layoutCharacter,
            shortcutKey: shortcutKey,
            applyShiftSymbolNormalization: false,
            eventKeyCode: event.keyCode
        ) {
            return true
        }

        // Control-key combos can surface as ASCII control characters (e.g. Ctrl+H => backspace),
        // so keep ANSI keyCode fallback for control-modified shortcuts. Also allow fallback for
        // command punctuation shortcuts, since some non-US layouts report different characters
        // for the same physical key even when menu-equivalent semantics should still apply.
        // When a non-Latin input source is active (Russian, Korean, Chinese, Japanese, etc.),
        // event chars carry no usable Latin key identity. Always allow keyCode fallback as a
        // safety net — even when the layout-based translation resolved a character, the
        // physical key code is the definitive identifier for the intended shortcut.
        // For empty-character events (synthetic key equivalents), preserve the original
        // behavior: only fall back when the layout translation also failed.
        let allowANSIKeyCodeFallback = flags.contains(.control)
            || (flags.contains(.command)
                && !flags.contains(.control)
                && (
                    !shouldRequireCharacterMatchForCommandShortcut(shortcutKey: shortcutKey)
                        || (hasEventChars && !eventCharsAreASCII)
                        || (!hasEventChars && (layoutCharacter?.isEmpty ?? true))
                ))
        if allowANSIKeyCodeFallback, let expectedKeyCode = keyCodeForShortcutKey(shortcutKey) {
            return event.keyCode == expectedKeyCode
        }
        return false
    }

    static func match(
        event: NSEvent,
        shortcut: StoredShortcut,
        layoutCharacterProvider: (UInt16, NSEvent.ModifierFlags) -> String?
    ) -> Bool {
        guard !shortcut.hasChord else { return false }
        return matchStroke(event: event, stroke: shortcut.firstStroke, layoutCharacterProvider: layoutCharacterProvider)
    }

    // MARK: - Private helpers

    // These are only ever called from `matchStroke` above, so they moved here in full rather
    // than staying behind a forwarder on `AppDelegate`.

    private static func shouldRequireCharacterMatchForCommandShortcut(shortcutKey: String) -> Bool {
        guard shortcutKey.count == 1, let scalar = shortcutKey.unicodeScalars.first else {
            return false
        }
        return CharacterSet.letters.contains(scalar)
    }

    private static func shortcutCharacterMatches(
        eventCharacter: String?,
        shortcutKey: String,
        applyShiftSymbolNormalization: Bool,
        eventKeyCode: UInt16
    ) -> Bool {
        guard let eventCharacter, !eventCharacter.isEmpty else { return false }
        if AppDelegate.normalizedShortcutEventCharacter(
            eventCharacter,
            applyShiftSymbolNormalization: applyShiftSymbolNormalization,
            eventKeyCode: eventKeyCode
        ) == shortcutKey {
            return true
        }
        return false
    }

    private static func keyCodeForShortcutKey(_ key: String) -> UInt16? {
        // Matches macOS ANSI key codes. This is intentionally limited to keys we
        // support in StoredShortcut/ghostty trigger translation.
        switch key {
        case "a": return 0   // kVK_ANSI_A
        case "s": return 1   // kVK_ANSI_S
        case "d": return 2   // kVK_ANSI_D
        case "f": return 3   // kVK_ANSI_F
        case "h": return 4   // kVK_ANSI_H
        case "g": return 5   // kVK_ANSI_G
        case "z": return 6   // kVK_ANSI_Z
        case "x": return 7   // kVK_ANSI_X
        case "c": return 8   // kVK_ANSI_C
        case "v": return 9   // kVK_ANSI_V
        case "b": return 11  // kVK_ANSI_B
        case "q": return 12  // kVK_ANSI_Q
        case "w": return 13  // kVK_ANSI_W
        case "e": return 14  // kVK_ANSI_E
        case "r": return 15  // kVK_ANSI_R
        case "y": return 16  // kVK_ANSI_Y
        case "t": return 17  // kVK_ANSI_T
        case "1": return 18  // kVK_ANSI_1
        case "2": return 19  // kVK_ANSI_2
        case "3": return 20  // kVK_ANSI_3
        case "4": return 21  // kVK_ANSI_4
        case "6": return 22  // kVK_ANSI_6
        case "5": return 23  // kVK_ANSI_5
        case "=": return 24  // kVK_ANSI_Equal
        case "9": return 25  // kVK_ANSI_9
        case "7": return 26  // kVK_ANSI_7
        case "-": return 27  // kVK_ANSI_Minus
        case "8": return 28  // kVK_ANSI_8
        case "0": return 29  // kVK_ANSI_0
        case "]": return 30  // kVK_ANSI_RightBracket
        case "o": return 31  // kVK_ANSI_O
        case "u": return 32  // kVK_ANSI_U
        case "[": return 33  // kVK_ANSI_LeftBracket
        case "i": return 34  // kVK_ANSI_I
        case "p": return 35  // kVK_ANSI_P
        case "l": return 37  // kVK_ANSI_L
        case "j": return 38  // kVK_ANSI_J
        case "'": return 39  // kVK_ANSI_Quote
        case "k": return 40  // kVK_ANSI_K
        case ";": return 41  // kVK_ANSI_Semicolon
        case "\\": return 42 // kVK_ANSI_Backslash
        case ",": return 43  // kVK_ANSI_Comma
        case "/": return 44  // kVK_ANSI_Slash
        case "n": return 45  // kVK_ANSI_N
        case "m": return 46  // kVK_ANSI_M
        case ".": return 47  // kVK_ANSI_Period
        case "`": return 50  // kVK_ANSI_Grave
        case "\r": return 36 // kVK_Return
        case "←": return 123 // kVK_LeftArrow
        case "→": return 124 // kVK_RightArrow
        case "↓": return 125 // kVK_DownArrow
        case "↑": return 126 // kVK_UpArrow
        default:
            return nil
        }
    }
}
