import SwiftUI
import AppKit
import Bonsplit

func browserOmnibarShouldReacquireFocusAfterEndEditing(
    desiredOmnibarFocus: Bool,
    nextResponderIsOtherTextField: Bool
) -> Bool {
    desiredOmnibarFocus && !nextResponderIsOtherTextField
}

final class OmnibarNativeTextField: NSTextField {
    var onPointerDown: (() -> Void)?
    var onHandleKeyEvent: ((NSEvent, NSTextView?) -> Bool)?
    /// Anchor index for Shift+click selection extension, reset on non-shift clicks.
    private var shiftClickAnchor: Int?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        isBezeled = false
        drawsBackground = false
        focusRingType = .none
        lineBreakMode = .byTruncatingTail
        usesSingleLineMode = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        #if DEBUG
        let frType = window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        dlog(
            "browser.omnibarClick win=\(window?.windowNumber ?? -1) " +
            "fr=\(frType) hasEditor=\(currentEditor() == nil ? 0 : 1)"
        )
        #endif
        onPointerDown?()

        if currentEditor() == nil {
            // First click — activate editing and select all (standard URL bar behavior).
            // Avoids NSTextView's tracking loop which can spin forever if text layout
            // enters an infinite invalidation cycle (e.g. under memory pressure).
            let result = window?.makeFirstResponder(self) ?? false
#if DEBUG
            let frAfter = window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
            dlog(
                "browser.omnibarClick.makeFirstResponder result=\(result ? 1 : 0) " +
                "win=\(window?.windowNumber ?? -1) fr=\(frAfter)"
            )
#endif
            currentEditor()?.selectAll(nil)
            shiftClickAnchor = nil
        } else {
            // Already editing — place the cursor at the click position without calling
            // super.mouseDown, which enters NSTextView's mouse-tracking loop. That loop
            // can spin forever when NSTextLayoutManager.enumerateTextLayoutFragments hits
            // an infinite invalidation cycle (see #917). The previous mitigation posted a
            // synthetic mouseUp via NSApp.postEvent after a timeout, but the tracking loop
            // does not always dequeue events from the application event queue, so the hang
            // persisted. By positioning the cursor ourselves we avoid the tracking loop
            // entirely. Drag-to-select is not supported in this path, but for a single-line
            // omnibar this is an acceptable trade-off (double-click to select word and
            // Shift+click to extend selection still work via the field editor).
            guard let editor = currentEditor() as? NSTextView else {
                super.mouseDown(with: event)
                return
            }

            // Double/triple-click: forward directly to the field editor (NSTextView)
            // which handles word and line selection internally. This bypasses
            // NSTextField's super.mouseDown (and its problematic tracking loop)
            // while preserving multi-click semantics.
            if event.clickCount > 1 {
                editor.mouseDown(with: event)
                shiftClickAnchor = nil
                return
            }

            let localPoint = editor.convert(event.locationInWindow, from: nil)
            let index = editor.characterIndexForInsertion(at: localPoint)
            let textLength = (editor.string as NSString).length
            let safeIndex = min(index, textLength)

            if event.modifierFlags.contains(.shift) {
                // Shift+click: extend the existing selection to the clicked position.
                // Use stored anchor to handle bidirectional extension correctly;
                // NSRange.location is always the lower index so it cannot serve as
                // a directional anchor on its own.
                let sel = editor.selectedRange()
                let anchor = shiftClickAnchor ?? sel.location
                shiftClickAnchor = anchor
                let newRange: NSRange
                if safeIndex >= anchor {
                    newRange = NSRange(location: anchor, length: safeIndex - anchor)
                } else {
                    newRange = NSRange(location: safeIndex, length: anchor - safeIndex)
                }
                editor.setSelectedRange(newRange)
            } else {
                shiftClickAnchor = nil
                editor.setSelectedRange(NSRange(location: safeIndex, length: 0))
            }
        }
    }

    override func keyDown(with event: NSEvent) {
#if DEBUG
        let typingTimingStart = ProgramaTypingTiming.start()
        var route = "super"
        defer {
            ProgramaTypingTiming.logDuration(
                path: "browser.omnibar.keyDown",
                startedAt: typingTimingStart,
                event: event,
                extra: "route=\(route)"
            )
        }
#endif
        // Reset shift-click anchor on any keyboard input so that a subsequent
        // Shift+click uses the post-keyboard selection as its anchor, not a
        // stale value from a prior mouse interaction.
        shiftClickAnchor = nil
        if (currentEditor() as? NSTextView)?.hasMarkedText() == true {
            super.keyDown(with: event)
            return
        }
        if onHandleKeyEvent?(event, currentEditor() as? NSTextView) == true {
#if DEBUG
            route = "custom"
#endif
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
#if DEBUG
        let typingTimingStart = ProgramaTypingTiming.start()
        var handled = false
        defer {
            ProgramaTypingTiming.logDuration(
                path: "browser.omnibar.performKeyEquivalent",
                startedAt: typingTimingStart,
                event: event,
                extra: "handled=\(handled ? 1 : 0)"
            )
        }
#endif
        shiftClickAnchor = nil
        if (currentEditor() as? NSTextView)?.hasMarkedText() == true {
            let result = super.performKeyEquivalent(with: event)
#if DEBUG
            handled = result
#endif
            return result
        }
        if onHandleKeyEvent?(event, currentEditor() as? NSTextView) == true {
#if DEBUG
            handled = true
#endif
            return true
        }
        let result = super.performKeyEquivalent(with: event)
#if DEBUG
        handled = result
#endif
        return result
    }
}

struct OmnibarTextFieldRepresentable: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let inlineCompletion: OmnibarInlineCompletion?
    let placeholder: String
    let onTap: () -> Void
    let onSubmit: () -> Void
    let onEscape: () -> Void
    let onFieldLostFocus: () -> Void
    let onMoveSelection: (Int) -> Void
    let onDeleteSelectedSuggestion: () -> Void
    let onAcceptInlineCompletion: () -> Void
    let onDeleteBackwardWithInlineSelection: () -> Void
    let onSelectionChanged: (NSRange, Bool) -> Void
    let shouldSuppressWebViewFocus: () -> Bool

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: OmnibarTextFieldRepresentable
        var isProgrammaticMutation: Bool = false
        var selectionObserver: NSObjectProtocol?
        weak var observedEditor: NSTextView?
        var appliedInlineCompletion: OmnibarInlineCompletion?
        var lastPublishedSelection: NSRange = NSRange(location: NSNotFound, length: 0)
        var lastPublishedHasMarkedText: Bool = false
        /// Guards against infinite focus loops: `true` = focus requested, `false` = blur requested, `nil` = idle.
        var pendingFocusRequest: Bool?

        init(parent: OmnibarTextFieldRepresentable) {
            self.parent = parent
        }

#if DEBUG
        func logFocusEvent(_ event: String, detail: String = "") {
            let window = parentField?.window
            let responder = window?.firstResponder
            let responderType = responder.map { String(describing: type(of: $0)) } ?? "nil"
            let responderIsField: Int = {
                guard let field = parentField else { return 0 }
                if responder === field { return 1 }
                if let editor = responder as? NSTextView,
                   (editor.delegate as? NSTextField) === field {
                    return 1
                }
                return 0
            }()
            let pendingValue: String = {
                guard let pendingFocusRequest else { return "nil" }
                return pendingFocusRequest ? "focus" : "blur"
            }()
            var line =
                "browser.focus.field event=\(event) focused=\(parent.isFocused ? 1 : 0) " +
                "pending=\(pendingValue) suppressWeb=\(parent.shouldSuppressWebViewFocus() ? 1 : 0) " +
                "win=\(window?.windowNumber ?? -1) fr=\(responderType) frIsField=\(responderIsField)"
            if !detail.isEmpty {
                line += " \(detail)"
            }
            dlog(line)
        }
#endif

        deinit {
            if let selectionObserver {
                NotificationCenter.default.removeObserver(selectionObserver)
            }
        }

        private func nextResponderIsOtherTextField(window: NSWindow?) -> Bool {
            guard let window, let field = parentField else { return false }
            let responder = window.firstResponder

            if let editor = responder as? NSTextView,
               let delegateField = editor.delegate as? NSTextField {
                return delegateField !== field
            }

            if let textField = responder as? NSTextField {
                return textField !== field
            }

            return false
        }

        private func isPointerDownEvent(_ event: NSEvent) -> Bool {
            switch event.type {
            case .leftMouseDown, .rightMouseDown, .otherMouseDown:
                return true
            default:
                return false
            }
        }

        private func topHitViewForCurrentPointerEvent(window: NSWindow) -> NSView? {
            guard let event = NSApp.currentEvent, isPointerDownEvent(event) else {
                return nil
            }
            if event.windowNumber != 0, event.windowNumber != window.windowNumber {
                return nil
            }
            if let eventWindow = event.window, eventWindow !== window {
                return nil
            }

            if let contentView = window.contentView,
               let themeFrame = contentView.superview {
                let pointInTheme = themeFrame.convert(event.locationInWindow, from: nil)
                if let hitInTheme = themeFrame.hitTest(pointInTheme) {
                    return hitInTheme
                }
            }

            guard let contentView = window.contentView else {
                return nil
            }
            let pointInContent = contentView.convert(event.locationInWindow, from: nil)
            return contentView.hitTest(pointInContent)
        }

        private func pointerDownBlurIntent(window: NSWindow?) -> Bool {
            guard let window, let field = parentField else { return false }
            guard let hitView = topHitViewForCurrentPointerEvent(window: window) else {
                return false
            }

            if hitView === field || hitView.isDescendant(of: field) {
                return false
            }
            if let textView = hitView as? NSTextView,
               let delegateField = textView.delegate as? NSTextField,
               delegateField === field {
                return false
            }
            return true
        }

        private func shouldReacquireFocusAfterEndEditing(window: NSWindow?) -> Bool {
            if pointerDownBlurIntent(window: window) {
                return false
            }
            return browserOmnibarShouldReacquireFocusAfterEndEditing(
                desiredOmnibarFocus: parent.isFocused,
                nextResponderIsOtherTextField: nextResponderIsOtherTextField(window: window)
            )
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
#if DEBUG
            logFocusEvent("controlTextDidBeginEditing")
#endif
            if !parent.isFocused {
                DispatchQueue.main.async {
#if DEBUG
                    self.logFocusEvent("controlTextDidBeginEditing.asyncSetFocused", detail: "old=0 new=1")
#endif
                    self.parent.isFocused = true
                }
            }
            attachSelectionObserverIfNeeded()
            publishSelectionState()
        }

        func controlTextDidEndEditing(_ obj: Notification) {
#if DEBUG
            let nextOther = nextResponderIsOtherTextField(window: parentField?.window)
            let pointerBlur = pointerDownBlurIntent(window: parentField?.window)
            logFocusEvent(
                "controlTextDidEndEditing",
                detail: "nextOther=\(nextOther ? 1 : 0) pointerBlur=\(pointerBlur ? 1 : 0) shouldReacquire=\(shouldReacquireFocusAfterEndEditing(window: parentField?.window) ? 1 : 0)"
            )
#endif
            if parent.isFocused {
                if shouldReacquireFocusAfterEndEditing(window: parentField?.window) {
#if DEBUG
                    logFocusEvent("controlTextDidEndEditing.reacquire.begin")
#endif
                    guard pendingFocusRequest != true else { return }
                    pendingFocusRequest = true
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.pendingFocusRequest = nil
#if DEBUG
                        self.logFocusEvent("controlTextDidEndEditing.reacquire.tick")
#endif
                        guard self.parent.isFocused else { return }
                        guard let field = self.parentField, let window = field.window else { return }
                        guard self.shouldReacquireFocusAfterEndEditing(window: window) else {
#if DEBUG
                            self.logFocusEvent("controlTextDidEndEditing.reacquire.cancel")
#endif
                            self.parent.onFieldLostFocus()
                            return
                        }
                        // Check both the field itself AND its field editor (which becomes
                        // the actual first responder when the text field is being edited).
                        let fr = window.firstResponder
                        let isAlreadyFocused = fr === field ||
                            field.currentEditor() != nil ||
                            ((fr as? NSTextView)?.delegate as? NSTextField) === field
                        if !isAlreadyFocused {
#if DEBUG
                            self.logFocusEvent("controlTextDidEndEditing.reacquire.apply")
#endif
                            window.makeFirstResponder(field)
                        } else {
#if DEBUG
                            self.logFocusEvent("controlTextDidEndEditing.reacquire.skip", detail: "reason=already_focused")
#endif
                        }
                    }
                    return
                }
#if DEBUG
                logFocusEvent("controlTextDidEndEditing.blur")
#endif
                parent.onFieldLostFocus()
            }
            detachSelectionObserver()
        }

        func controlTextDidChange(_ obj: Notification) {
#if DEBUG
            let typingTimingStart = ProgramaTypingTiming.start()
            defer {
                ProgramaTypingTiming.logDuration(
                    path: "browser.omnibar.controlTextDidChange",
                    startedAt: typingTimingStart,
                    event: NSApp.currentEvent,
                    extra: "programmatic=\(isProgrammaticMutation ? 1 : 0)"
                )
            }
#endif
            guard !isProgrammaticMutation else { return }
            guard let field = obj.object as? NSTextField else { return }
            let editor = field.currentEditor() as? NSTextView
            parent.text = omnibarPublishedBufferTextForFieldChange(
                fieldValue: field.stringValue,
                inlineCompletion: parent.inlineCompletion,
                selectionRange: editor?.selectedRange(),
                hasMarkedText: editor?.hasMarkedText() ?? false
            )
            publishSelectionState()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
#if DEBUG
            let typingTimingStart = ProgramaTypingTiming.start()
            var handled = false
            defer {
                ProgramaTypingTiming.logDuration(
                    path: "browser.omnibar.doCommandBy",
                    startedAt: typingTimingStart,
                    event: NSApp.currentEvent,
                    extra: "handled=\(handled ? 1 : 0) selector=\(NSStringFromSelector(commandSelector))"
                )
            }
#endif
            switch commandSelector {
            case #selector(NSResponder.moveDown(_:)):
                parent.onMoveSelection(+1)
#if DEBUG
                handled = true
#endif
                return true
            case #selector(NSResponder.moveUp(_:)):
                parent.onMoveSelection(-1)
#if DEBUG
                handled = true
#endif
                return true
            case #selector(NSResponder.insertNewline(_:)):
                let currentFlags = NSApp.currentEvent?.modifierFlags ?? []
                guard browserOmnibarShouldSubmitOnReturn(flags: currentFlags) else { return false }
                parent.onSubmit()
#if DEBUG
                handled = true
#endif
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onEscape()
#if DEBUG
                handled = true
#endif
                return true
            case #selector(NSResponder.moveRight(_:)), #selector(NSResponder.moveToEndOfLine(_:)):
                if parent.inlineCompletion != nil {
                    parent.onAcceptInlineCompletion()
#if DEBUG
                    handled = true
#endif
                    return true
                }
                return false
            case #selector(NSResponder.insertTab(_:)):
                if parent.inlineCompletion != nil {
                    parent.onAcceptInlineCompletion()
#if DEBUG
                    handled = true
#endif
                    return true
                }
                return false
            case #selector(NSResponder.deleteBackward(_:)):
                if suffixSelectionMatchesInline(textView, inline: parent.inlineCompletion) {
                    parent.onDeleteBackwardWithInlineSelection()
#if DEBUG
                    handled = true
#endif
                    return true
                }
                return false
            default:
                return false
            }
        }

        func attachSelectionObserverIfNeeded() {
            guard selectionObserver == nil else { return }
            guard let field = parentField else { return }
            guard let editor = field.currentEditor() as? NSTextView else { return }
            observedEditor = editor
            selectionObserver = NotificationCenter.default.addObserver(
                forName: NSTextView.didChangeSelectionNotification,
                object: editor,
                queue: .main
            ) { [weak self] _ in
                self?.publishSelectionState()
            }
        }

        func detachSelectionObserver() {
            if let selectionObserver {
                NotificationCenter.default.removeObserver(selectionObserver)
                self.selectionObserver = nil
            }
            observedEditor = nil
        }

        weak var parentField: OmnibarNativeTextField?

        func publishSelectionState() {
            guard let field = parentField else { return }
            if let editor = field.currentEditor() as? NSTextView {
                let range = editor.selectedRange()
                let hasMarkedText = editor.hasMarkedText()
                guard !NSEqualRanges(range, lastPublishedSelection) || hasMarkedText != lastPublishedHasMarkedText else {
                    return
                }
                lastPublishedSelection = range
                lastPublishedHasMarkedText = hasMarkedText
                parent.onSelectionChanged(range, hasMarkedText)
            } else {
                let location = field.stringValue.utf16.count
                let range = NSRange(location: location, length: 0)
                guard !NSEqualRanges(range, lastPublishedSelection) || lastPublishedHasMarkedText else { return }
                lastPublishedSelection = range
                lastPublishedHasMarkedText = false
                parent.onSelectionChanged(range, false)
            }
        }

    private func suffixSelectionMatchesInline(_ editor: NSTextView?, inline: OmnibarInlineCompletion?) -> Bool {
        guard let editor, let inline else { return false }
        let selected = editor.selectedRange()
        return NSEqualRanges(selected, inline.suffixRange)
    }

    private func selectionIsTypedPrefixBoundary(_ editor: NSTextView?, inline: OmnibarInlineCompletion?) -> Bool {
        guard let editor, let inline else { return false }
        let selected = editor.selectedRange()
        let typedCount = inline.typedText.utf16.count
        return selected.location == typedCount && selected.length == 0
    }

        func handleKeyEvent(_ event: NSEvent, editor: NSTextView?) -> Bool {
#if DEBUG
            let typingTimingStart = ProgramaTypingTiming.start()
            var handled = false
            defer {
                ProgramaTypingTiming.logDuration(
                    path: "browser.omnibar.handleKeyEvent",
                    startedAt: typingTimingStart,
                    event: event,
                    extra: "handled=\(handled ? 1 : 0)"
                )
            }
#endif
            let keyCode = event.keyCode
            let modifiers = event.modifierFlags.intersection([.command, .control, .shift, .option, .function])
            // When a non-Latin input source is active (Korean, Chinese, Japanese),
            // charactersIgnoringModifiers returns non-ASCII characters. Normalize
            // via KeyboardLayout so Cmd/Ctrl+N/P navigation works across input sources.
            let lowered = KeyboardLayout.normalizedCharacters(for: event)
            let hasCommandOrControl = modifiers.contains(.command) || modifiers.contains(.control)

            // Cmd/Ctrl+N and Cmd/Ctrl+P should repeat while held.
            if hasCommandOrControl, lowered == "n" {
                parent.onMoveSelection(+1)
#if DEBUG
                handled = true
#endif
                return true
            }
            if hasCommandOrControl, lowered == "p" {
                parent.onMoveSelection(-1)
#if DEBUG
                handled = true
#endif
                return true
            }

            // Shift+Delete removes the selected history suggestion when possible.
            if modifiers.contains(.shift), (keyCode == 51 || keyCode == 117) {
                parent.onDeleteSelectedSuggestion()
#if DEBUG
                handled = true
#endif
                return true
            }

            switch keyCode {
            case 36, 76: // Return / keypad Enter
                guard browserOmnibarShouldSubmitOnReturn(flags: event.modifierFlags) else { return false }
                parent.onSubmit()
#if DEBUG
                handled = true
#endif
                return true
            case 53: // Escape
                parent.onEscape()
#if DEBUG
                handled = true
#endif
                return true
            case 125: // Down
                parent.onMoveSelection(+1)
#if DEBUG
                handled = true
#endif
                return true
            case 126: // Up
                parent.onMoveSelection(-1)
#if DEBUG
                handled = true
#endif
                return true
            case 124, 119: // Right arrow / End
                if parent.inlineCompletion != nil {
                    parent.onAcceptInlineCompletion()
#if DEBUG
                    handled = true
#endif
                    return true
                }
            case 48: // Tab
                if parent.inlineCompletion != nil {
                    parent.onAcceptInlineCompletion()
#if DEBUG
                    handled = true
#endif
                    return true
                }
            case 51: // Backspace
                if let inline = parent.inlineCompletion,
                   (suffixSelectionMatchesInline(editor, inline: inline) || selectionIsTypedPrefixBoundary(editor, inline: inline)) {
                    parent.onDeleteBackwardWithInlineSelection()
#if DEBUG
                    handled = true
#endif
                    return true
                }
            default:
                break
            }

            return false
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> OmnibarNativeTextField {
        let field = OmnibarNativeTextField(frame: .zero)
        field.font = .systemFont(ofSize: 12)
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.target = nil
        field.action = nil
        field.isEditable = true
        field.isSelectable = true
        field.isEnabled = true
        field.stringValue = text
        field.onPointerDown = {
            onTap()
        }
        field.onHandleKeyEvent = { [weak coordinator = context.coordinator] event, editor in
            coordinator?.handleKeyEvent(event, editor: editor) ?? false
        }
        context.coordinator.parentField = field
        return field
    }

    func updateNSView(_ nsView: OmnibarNativeTextField, context: Context) {
        context.coordinator.parent = self
        context.coordinator.parentField = nsView
        nsView.placeholderString = placeholder

        let activeInlineCompletion = omnibarInlineCompletionIfBufferMatchesTypedPrefix(
            bufferText: text,
            inlineCompletion: inlineCompletion
        )
        let desiredDisplayText = activeInlineCompletion?.displayText ?? text
        if let editor = nsView.currentEditor() as? NSTextView {
            if !editor.hasMarkedText(), editor.string != desiredDisplayText {
                context.coordinator.isProgrammaticMutation = true
                editor.string = desiredDisplayText
                nsView.stringValue = desiredDisplayText
                context.coordinator.isProgrammaticMutation = false
            }
        } else if nsView.stringValue != desiredDisplayText {
            nsView.stringValue = desiredDisplayText
        }

        if let window = nsView.window {
            let firstResponder = window.firstResponder
            let isFirstResponder =
                firstResponder === nsView ||
                nsView.currentEditor() != nil ||
                ((firstResponder as? NSTextView)?.delegate as? NSTextField) === nsView
            if isFocused, !isFirstResponder, context.coordinator.pendingFocusRequest != true {
#if DEBUG
                context.coordinator.logFocusEvent(
                    "updateNSView.requestFocus.begin",
                    detail: "isFocused=1 isFirstResponder=0"
                )
#endif
                // Defer to avoid triggering input method XPC during layout pass,
                // which can crash via re-entrant view hierarchy modification.
                context.coordinator.pendingFocusRequest = true
                DispatchQueue.main.async { [weak nsView, weak coordinator = context.coordinator] in
                    coordinator?.pendingFocusRequest = nil
                    guard let nsView, let window = nsView.window else { return }
#if DEBUG
                    if coordinator?.parent.isFocused != true {
                        coordinator?.logFocusEvent("updateNSView.requestFocus.cancel", detail: "reason=stale_state")
                        return
                    }
#endif
                    guard coordinator?.parent.isFocused == true else { return }
#if DEBUG
                    coordinator?.logFocusEvent("updateNSView.requestFocus.tick")
#endif
                    let fr = window.firstResponder
                    let alreadyFocused = fr === nsView ||
                        nsView.currentEditor() != nil ||
                        ((fr as? NSTextView)?.delegate as? NSTextField) === nsView
                    guard !alreadyFocused else { return }
#if DEBUG
                    coordinator?.logFocusEvent("updateNSView.requestFocus.apply")
#endif
                    window.makeFirstResponder(nsView)
                }
            } else if !isFocused, isFirstResponder, context.coordinator.pendingFocusRequest != false {
#if DEBUG
                context.coordinator.logFocusEvent(
                    "updateNSView.requestBlur.begin",
                    detail: "isFocused=0 isFirstResponder=1"
                )
#endif
                context.coordinator.pendingFocusRequest = false
                DispatchQueue.main.async { [weak nsView, weak coordinator = context.coordinator] in
                    coordinator?.pendingFocusRequest = nil
                    guard let nsView, let window = nsView.window else { return }
#if DEBUG
                    if coordinator?.parent.isFocused == true {
                        coordinator?.logFocusEvent("updateNSView.requestBlur.cancel", detail: "reason=stale_state")
                        return
                    }
#endif
                    guard coordinator?.parent.isFocused == false else { return }
#if DEBUG
                    coordinator?.logFocusEvent("updateNSView.requestBlur.tick")
#endif
                    let fr = window.firstResponder
                    let stillFirst = fr === nsView ||
                        ((fr as? NSTextView)?.delegate as? NSTextField) === nsView
                    guard stillFirst else { return }
#if DEBUG
                    coordinator?.logFocusEvent("updateNSView.requestBlur.apply")
#endif
                    window.makeFirstResponder(nil)
                }
            }
        }

        if let editor = nsView.currentEditor() as? NSTextView, !editor.hasMarkedText() {
            if let activeInlineCompletion {
                let currentSelection = editor.selectedRange()
                let desiredSelection = omnibarDesiredSelectionRangeForInlineCompletion(
                    currentSelection: currentSelection,
                    inlineCompletion: activeInlineCompletion
                )
                if context.coordinator.appliedInlineCompletion != activeInlineCompletion ||
                    !NSEqualRanges(currentSelection, desiredSelection) {
                    context.coordinator.isProgrammaticMutation = true
                    editor.setSelectedRange(desiredSelection)
                    context.coordinator.isProgrammaticMutation = false
                }
            } else if context.coordinator.appliedInlineCompletion != nil {
                let end = text.utf16.count
                let current = editor.selectedRange()
                if current.length != 0 || current.location != end {
                    context.coordinator.isProgrammaticMutation = true
                    editor.setSelectedRange(NSRange(location: end, length: 0))
                    context.coordinator.isProgrammaticMutation = false
                }
            }
        }
        context.coordinator.appliedInlineCompletion = activeInlineCompletion
        context.coordinator.attachSelectionObserverIfNeeded()
        context.coordinator.publishSelectionState()
    }

    static func dismantleNSView(_ nsView: OmnibarNativeTextField, coordinator: Coordinator) {
        nsView.onPointerDown = nil
        nsView.onHandleKeyEvent = nil
        nsView.delegate = nil
        coordinator.detachSelectionObserver()
        coordinator.parentField = nil
    }
}
