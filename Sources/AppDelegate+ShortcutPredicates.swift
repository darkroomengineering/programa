import AppKit

func isCommandPaletteFocusStealingTerminalResponder(_ responder: NSResponder) -> Bool {
    if responder is GhosttyNSView {
        return true
    }

    if let textView = responder as? NSTextView, !textView.isFieldEditor {
        if let delegateView = textView.delegate as? NSView,
           isCommandPaletteFocusStealingTerminalView(delegateView) {
            return true
        }
        return isCommandPaletteFocusStealingTerminalView(textView)
    }

    if let view = responder as? NSView {
        return isCommandPaletteFocusStealingTerminalView(view)
    }

    return false
}

func isCommandPaletteFocusStealingTerminalView(_ view: NSView) -> Bool {
    if view is GhosttyNSView || view is GhosttySurfaceScrollView {
        return true
    }
    var current: NSView? = view.superview
    while let candidate = current {
        if candidate is GhosttyNSView || candidate is GhosttySurfaceScrollView {
            return true
        }
        current = candidate.superview
    }
    return false
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

    // Escape dismisses the palette and must not leak through to the terminal.
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

enum TerminalZoomShortcutAction: Equatable {
    case zoomIn
    case zoomOut
    case reset
}

func terminalZoomShortcutAction(
    flags: NSEvent.ModifierFlags,
    chars: String,
    keyCode: UInt16,
    literalChars: String? = nil
) -> TerminalZoomShortcutAction? {
    let normalizedFlags = flags
        .intersection(.deviceIndependentFlagsMask)
        .subtracting([.numericPad, .function])
    let hasCommand = normalizedFlags.contains(.command)
    let hasOnlyCommandAndOptionalShift = hasCommand && normalizedFlags.isDisjoint(with: [.control, .option])

    guard hasOnlyCommandAndOptionalShift else { return nil }
    let keys = terminalZoomShortcutKeyCandidates(
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

func terminalZoomShortcutKeyCandidates(
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
    return terminalZoomShortcutAction(
        flags: flags,
        chars: chars,
        keyCode: keyCode,
        literalChars: literalChars
    ) != nil
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

func programaOwningGhosttyView(for responder: NSResponder?) -> GhosttyNSView? {
    guard let responder else { return nil }
    if let ghosttyView = responder as? GhosttyNSView {
        return ghosttyView
    }

    if let view = responder as? NSView,
       let ghosttyView = programaOwningGhosttyView(for: view) {
        return ghosttyView
    }

    if let textView = responder as? NSTextView {
        if textView.isFieldEditor,
           let ownerView = programaFieldEditorOwnerView(textView),
           let ghosttyView = programaOwningGhosttyView(for: ownerView) {
            return ghosttyView
        }

        if !textView.isFieldEditor,
           let delegateView = textView.delegate as? NSView,
           let ghosttyView = programaOwningGhosttyView(for: delegateView) {
            return ghosttyView
        }
    }

    var current = responder.nextResponder
    while let next = current {
        if let ghosttyView = next as? GhosttyNSView {
            return ghosttyView
        }
        if let view = next as? NSView,
           let ghosttyView = programaOwningGhosttyView(for: view) {
            return ghosttyView
        }
        current = next.nextResponder
    }

    return nil
}

func programaFieldEditorOwnerView(_ editor: NSTextView) -> NSView? {
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

func programaOwningGhosttyView(for view: NSView) -> GhosttyNSView? {
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
