import Foundation
import SwiftUI
import AppKit
import Metal
import QuartzCore
import Combine
import CoreText
import Darwin
import Carbon.HIToolbox
import Bonsplit
import IOSurface
import UniformTypeIdentifiers

// MARK: - GhosttyNSView + Keyboard
//
// Keyboard input handling for GhosttyNSView: keyboard copy-mode, clipboard
// actions, and the typing-latency-critical key path (performKeyEquivalent,
// keyDown, keyUp, flagsChanged, and their key-encoding helpers).
//
// Split out of GhosttyTerminalView.swift (Nuclear Review TC5). Moving these
// methods into a same-type extension adds zero call-site indirection, so the
// typing-latency-sensitive behavior here is unchanged from the original
// single-file version. Method bodies are moved verbatim.

extension GhosttyNSView {
    @discardableResult
    func ensureSurfaceReadyForInput() -> ghostty_surface_t? {
        if let surface = surface {
            return surface
        }
        guard window != nil else { return nil }
        terminalSurface?.attachToView(self)
        updateSurfaceSize(size: bounds.size)
        applySurfaceColorScheme(force: true)
        return surface
    }

    private func requestInputRecoveryAfterSurfaceMiss(reason: String) {
        // A view with no window can never be the legitimate first responder for its
        // terminal surface — AppKit only dispatches real keyDown events to views inside
        // an active window's responder chain, so reaching this path with `window == nil`
        // means the view was detached without going through the normal
        // resignFirstResponder()/becomeFirstResponder() protocol (e.g. removeFromSuperview
        // while still the window's stale first responder). Clear any stale "desired
        // focus" now, synchronously, so the background surface recreation requested below
        // does not resurrect focus for a pane that isn't the real focus owner anymore.
        // Only `window == nil` triggers this — a live but surface-less view (e.g. during
        // layout restoration) must keep its desired focus so createSurface can apply it.
        if window == nil {
            desiredFocus = false
            terminalSurface?.recordExternalFocusState(false)
        }
        terminalSurface?.requestBackgroundSurfaceStartIfNeeded()
#if DEBUG
        dlog(
            "focus.input_recovery surface=\(terminalSurface?.id.uuidString.prefix(5) ?? "nil") " +
            "reason=\(reason) inWindow=\(window != nil ? 1 : 0)"
        )
#endif
    }

    func performBindingAction(_ action: String) -> Bool {
        guard let surface = surface else { return false }
        return action.withCString { cString in
            ghostty_surface_binding_action(surface, cString, UInt(strlen(cString)))
        }
    }

    @discardableResult
    func toggleKeyboardCopyMode() -> Bool {
        guard surface != nil else { return false }
        setKeyboardCopyModeActive(!keyboardCopyModeActive)
        if !keyboardCopyModeActive, let surface {
            _ = ghostty_surface_clear_selection_compat(surface)
        }
        return true
    }

    private func setKeyboardCopyModeActive(_ active: Bool) {
        keyboardCopyModeInputState.reset()
        keyboardCopyModeVisualActive = false
        keyboardCopyModeActive = active
        if active, let surface {
            keyboardCopyModeViewportRow = keyboardCopyModeSelectionAnchor(surface: surface)?.row
            _ = ghostty_surface_clear_selection_compat(surface)
            if keyboardCopyModeViewportRow == nil {
                keyboardCopyModeViewportRow = keyboardCopyModeImeViewportRow(surface: surface)
            }
            // Create a 1-cell selection at the terminal cursor to serve as a
            // visible cursor indicator in copy mode.
            _ = ghostty_surface_select_cursor_cell_compat(surface)
        } else {
            keyboardCopyModeViewportRow = nil
        }
        terminalSurface?.setKeyboardCopyModeActive(active)
    }

    private func performBindingAction(_ action: String, repeatCount: Int) {
        let count = terminalKeyboardCopyModeClampCount(repeatCount)
        for _ in 0 ..< count {
            _ = performBindingAction(action)
        }
    }

    private func currentKeyboardCopyModeViewportRow(surface: ghostty_surface_t) -> Int {
        let rows = max(Int(ghostty_surface_size(surface).rows), 1)
        let fallback = rows - 1
        return max(0, min(rows - 1, keyboardCopyModeViewportRow ?? fallback))
    }

    private func keyboardCopyModeImeViewportRow(surface: ghostty_surface_t) -> Int {
        let rows = max(Int(ghostty_surface_size(surface).rows), 1)
        var x: Double = 0
        var y: Double = 0
        var width: Double = 0
        var height: Double = 0
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)
        return terminalKeyboardCopyModeInitialViewportRow(
            rows: rows,
            imePointY: y,
            imeCellHeight: height
        )
    }

    private func keyboardCopyModeSelectionAnchor(surface: ghostty_surface_t) -> (row: Int, y: Double)? {
        let size = ghostty_surface_size(surface)
        guard size.rows > 0, size.columns > 0 else { return nil }
        guard ghostty_surface_select_cursor_cell_compat(surface) else { return nil }

        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }

        let rows = max(Int(size.rows), 1)
        let cols = max(Int(size.columns), 1)
        let rawRow = Int(text.offset_start) / cols
        let clampedRow = max(0, min(rows - 1, rawRow))
        return (row: clampedRow, y: text.tl_px_y)
    }

    private func refreshKeyboardCopyModeViewportRowFromVisibleAnchor(surface: ghostty_surface_t) {
        // In visual mode the user owns the selection range; don't disturb it.
        // Outside visual mode we keep a 1-cell cursor selection for visibility,
        // so we still need to refresh the viewport row after scrolling.
        guard !keyboardCopyModeVisualActive else { return }
        guard let anchor = keyboardCopyModeSelectionAnchor(surface: surface) else { return }
        keyboardCopyModeViewportRow = anchor.row
        // Preserve the visible cursor indicator.
        _ = ghostty_surface_select_cursor_cell_compat(surface)
    }

    private func copyCurrentViewportLinesToClipboard(
        surface: ghostty_surface_t,
        startRow: Int,
        lineCount: Int
    ) -> Bool {
        let clampedCount = terminalKeyboardCopyModeClampCount(lineCount)
        let rows = max(Int(ghostty_surface_size(surface).rows), 1)
        let targetRow = max(0, min(rows - 1, startRow))
        let endRow = min(rows - 1, targetRow + clampedCount - 1)
        guard let anchor = keyboardCopyModeSelectionAnchor(surface: surface) else {
            return false
        }
        _ = ghostty_surface_clear_selection_compat(surface)

        var imeX: Double = 0
        var imeY: Double = 0
        var imeWidth: Double = 0
        var imeHeight: Double = 0
        ghostty_surface_ime_point(surface, &imeX, &imeY, &imeWidth, &imeHeight)
        let cellHeight = imeHeight > 0 ? imeHeight : max(bounds.height / Double(rows), 1)
        let yMax = max(bounds.height - 1, 0)

        let startRawY = anchor.y + (Double(targetRow - anchor.row) * cellHeight)
        let endRawY = anchor.y + (Double(endRow - anchor.row) * cellHeight)
        let startY = max(0, min(startRawY, yMax))
        let endY = max(0, min(endRawY, yMax))
        let xMax = max(bounds.width - 1, 0)
        let startX = min(1, xMax)
        let endX = xMax

        let mods = ghostty_input_mods_e(rawValue: GHOSTTY_MODS_NONE.rawValue)
        ghostty_surface_mouse_pos(surface, startX, startY, mods)
        guard ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, mods) else {
            return false
        }
        defer {
            _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, mods)
        }
        ghostty_surface_mouse_pos(surface, endX, endY, mods)
        guard ghostty_surface_has_selection(surface) else { return false }

        return performBindingAction("copy_to_clipboard")
    }

    private func handleKeyboardCopyModeIfNeeded(_ event: NSEvent, surface: ghostty_surface_t) -> Bool {
        guard keyboardCopyModeActive else { return false }

        if terminalKeyboardCopyModeShouldBypassForShortcut(modifierFlags: event.modifierFlags) {
            keyboardCopyModeInputState.reset()
            return false
        }

        // Use the visual-mode flag instead of raw has_selection so that the
        // 1-cell cursor selection doesn't make every motion behave as visual.
        let hasSelection = keyboardCopyModeVisualActive
        let resolution = terminalKeyboardCopyModeResolve(
            keyCode: event.keyCode,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            modifierFlags: event.modifierFlags,
            hasSelection: hasSelection,
            state: &keyboardCopyModeInputState
        )
        guard case let .perform(action, count) = resolution else {
            return true
        }

        switch action {
        case .exit:
            _ = ghostty_surface_clear_selection_compat(surface)
            setKeyboardCopyModeActive(false)
        case .startSelection:
            keyboardCopyModeVisualActive = true
        case .clearSelection:
            keyboardCopyModeVisualActive = false
            _ = ghostty_surface_clear_selection_compat(surface)
            // Re-create 1-cell cursor at terminal cursor position.
            _ = ghostty_surface_select_cursor_cell_compat(surface)
        case .copyAndExit:
            _ = performBindingAction("copy_to_clipboard")
            _ = ghostty_surface_clear_selection_compat(surface)
            setKeyboardCopyModeActive(false)
        case .copyLineAndExit:
            let startRow = currentKeyboardCopyModeViewportRow(surface: surface)
            _ = copyCurrentViewportLinesToClipboard(
                surface: surface,
                startRow: startRow,
                lineCount: count
            )
            _ = ghostty_surface_clear_selection_compat(surface)
            setKeyboardCopyModeActive(false)
        case let .scrollLines(delta):
            _ = performBindingAction("scroll_page_lines:\(delta * count)")
            refreshKeyboardCopyModeViewportRowFromVisibleAnchor(surface: surface)
        case let .scrollPage(delta):
            performBindingAction(delta > 0 ? "scroll_page_down" : "scroll_page_up", repeatCount: count)
            refreshKeyboardCopyModeViewportRowFromVisibleAnchor(surface: surface)
        case let .scrollHalfPage(delta):
            let fraction = delta > 0 ? 0.5 : -0.5
            performBindingAction("scroll_page_fractional:\(fraction)", repeatCount: count)
            refreshKeyboardCopyModeViewportRowFromVisibleAnchor(surface: surface)
        case .scrollToTop:
            keyboardCopyModeViewportRow = 0
            _ = performBindingAction("scroll_to_top")
        case .scrollToBottom:
            keyboardCopyModeViewportRow = max(Int(ghostty_surface_size(surface).rows) - 1, 0)
            _ = performBindingAction("scroll_to_bottom")
        case let .jumpToPrompt(delta):
            _ = performBindingAction("jump_to_prompt:\(delta * count)")
            refreshKeyboardCopyModeViewportRowFromVisibleAnchor(surface: surface)
        case .startSearch:
            _ = performBindingAction("start_search")
        case .searchNext:
            performBindingAction("navigate_search:next", repeatCount: count)
            refreshKeyboardCopyModeViewportRowFromVisibleAnchor(surface: surface)
        case .searchPrevious:
            performBindingAction("navigate_search:previous", repeatCount: count)
            refreshKeyboardCopyModeViewportRowFromVisibleAnchor(surface: surface)
        case let .adjustSelection(direction):
            performBindingAction("adjust_selection:\(direction.rawValue)", repeatCount: count)
        }
        return true
    }

    // MARK: - Input Handling

    @IBAction func copy(_ sender: Any?) {
        _ = performBindingAction("copy_to_clipboard")
    }

    // MARK: - Clipboard paste

    @IBAction func paste(_ sender: Any?) {
        _ = performBindingAction("paste_from_clipboard")
    }

    /// Pastes clipboard text as plain text, stripping any rich formatting.
    @IBAction func pasteAsPlainText(_ sender: Any?) {
        _ = performBindingAction("paste_from_clipboard")
    }

    /// Validates whether edit menu items (copy, paste, split) should be enabled.
    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)):
            guard let surface = surface else { return false }
            return ghostty_surface_has_selection(surface)
        case #selector(paste(_:)):
            return GhosttyPasteboardHelper.hasString(for: GHOSTTY_CLIPBOARD_STANDARD)
        case #selector(pasteAsPlainText(_:)):
            return GhosttyPasteboardHelper.hasString(for: GHOSTTY_CLIPBOARD_STANDARD)
        case #selector(splitHorizontally(_:)), #selector(splitVertically(_:)):
            return canSplitCurrentSurface()
        default:
            return true
        }
    }

#if DEBUG
    private func recordKeyLatency(path: String, event: NSEvent) {
        guard Self.keyLatencyProbeEnabled else { return }
        ProgramaTypingTiming.logEventDelay(path: path, event: event)
    }
#endif

    // Prevents NSBeep for unimplemented actions from interpretKeyEvents
    override func doCommand(by selector: Selector) {
        // Intentionally empty - prevents system beep on unhandled key commands
    }

    /// Some third-party voice input apps inject committed text by sending the
    /// responder-chain `insertText:` action (single-argument form).
    /// Route that into our NSTextInputClient path so text lands in the terminal.
    override func insertText(_ insertString: Any) {
        withExternalCommittedText {
            insertText(insertString, replacementRange: NSRange(location: NSNotFound, length: 0))
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
#if DEBUG
        let typingTimingStart = ProgramaTypingTiming.start()
        defer {
            ProgramaTypingTiming.logDuration(
                path: "terminal.performKeyEquivalent",
                startedAt: typingTimingStart,
                event: event
            )
        }
#endif
        guard event.type == .keyDown else { return false }
        guard let fr = window?.firstResponder as? NSView,
              fr === self || fr.isDescendant(of: self) else { return false }
        guard let surface = ensureSurfaceReadyForInput() else { return false }

        // If the IME is composing (marked text present) and the key has no Cmd
        // modifier, don't intercept — let it flow through to keyDown so the input
        // method can process it normally. Cmd-based shortcuts should still work
        // during composition since Cmd is never part of IME input sequences.
        if hasMarkedText(), !event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command) {
            return false
        }

        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])

        // Printable text without Command/Control should stay on the normal keyDown
        // path. AppKit can still route layout-dependent punctuation through
        // performKeyEquivalent first, and probing bindings here can misclassify
        // keys such as ABC-QWERTZ Shift+7 ("/") or Shift+- ("?") as shortcuts.
        if !flags.contains(.command),
           !flags.contains(.control),
           let text = textForKeyEvent(event),
           shouldSendText(text) {
            lastPerformKeyEvent = nil
            return false
        }

#if DEBUG
        recordKeyLatency(path: "performKeyEquivalent", event: event)
#endif

#if DEBUG
        programaWriteChildExitProbe(
            [
                "probePerformCharsHex": programaScalarHex(event.characters),
                "probePerformCharsIgnoringHex": programaScalarHex(event.charactersIgnoringModifiers),
                "probePerformKeyCode": String(event.keyCode),
                "probePerformModsRaw": String(event.modifierFlags.rawValue),
                "probePerformSurfaceId": terminalSurface?.id.uuidString ?? "",
            ],
            increments: ["probePerformKeyEquivalentCount": 1]
        )
#endif

        // Check if this event matches a Ghostty keybinding.
        let bindingFlags: ghostty_binding_flags_e? = {
            var keyEvent = ghosttyKeyEvent(for: event, surface: surface)
            let text = textForKeyEvent(event).flatMap { shouldSendText($0) ? $0 : nil } ?? ""
            var flags = ghostty_binding_flags_e(0)
            let isBinding = text.withCString { ptr in
                keyEvent.text = ptr
                return ghostty_surface_key_is_binding(surface, keyEvent, &flags)
            }
            return isBinding ? flags : nil
        }()

        if let bindingFlags {
            let isConsumed = (bindingFlags.rawValue & GHOSTTY_BINDING_FLAGS_CONSUMED.rawValue) != 0
            let isAll = (bindingFlags.rawValue & GHOSTTY_BINDING_FLAGS_ALL.rawValue) != 0
            let isPerformable = (bindingFlags.rawValue & GHOSTTY_BINDING_FLAGS_PERFORMABLE.rawValue) != 0

            // If the binding is consumed and not meant for the menu, allow menu first.
            if isConsumed && !isAll && !isPerformable && keySequence.isEmpty && keyTables.isEmpty {
                if let menu = NSApp.mainMenu, menu.performKeyEquivalent(with: event) {
                    return true
                }
            }

            keyDown(with: event)
            return true
        }

        let equivalent: String
        switch event.charactersIgnoringModifiers {
        case "\r":
            // Pass Ctrl+Return through verbatim (prevent context menu equivalent).
            guard event.modifierFlags.contains(.control) else { return false }
            equivalent = "\r"

        case "/":
            // Treat Ctrl+/ as Ctrl+_ to avoid the system beep.
            guard event.modifierFlags.contains(.control),
                  event.modifierFlags.isDisjoint(with: [.shift, .command, .option]) else {
                return false
            }
            equivalent = "_"

        default:
            // Ignore synthetic events.
            if event.timestamp == 0 {
                return false
            }

            // Match AppKit key-equivalent routing for menu-style shortcuts (Command-modified).
            // Control-only terminal input (e.g. Ctrl+D) should not participate in redispatch;
            // it must flow through the normal keyDown path exactly once.
            if !event.modifierFlags.contains(.command) {
                lastPerformKeyEvent = nil
                return false
            }

            if let lastPerformKeyEvent {
                self.lastPerformKeyEvent = nil
                if lastPerformKeyEvent == event.timestamp {
                    equivalent = event.charactersIgnoringModifiers ?? ""
                    break
                }
            }

            lastPerformKeyEvent = event.timestamp
            return false
        }

        let finalEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: event.locationInWindow,
            modifierFlags: event.modifierFlags,
            timestamp: event.timestamp,
            windowNumber: event.windowNumber,
            context: nil,
            characters: equivalent,
            charactersIgnoringModifiers: equivalent,
            isARepeat: event.isARepeat,
            keyCode: event.keyCode
        )

        if let finalEvent {
            keyDown(with: finalEvent)
            return true
        }

        return false
    }

    override func keyDown(with event: NSEvent) {
#if DEBUG
        let typingTimingStart = ProgramaTypingTiming.start()
        let phaseTotalStart = ProcessInfo.processInfo.systemUptime
        var ensureSurfaceMs: Double = 0
        var dismissNotificationMs: Double = 0
        var keyboardCopyModeMs: Double = 0
        var interpretMs: Double = 0
        var syncPreeditMs: Double = 0
        var ghosttySendMs: Double = 0
        var refreshMs: Double = 0
        defer {
            let totalMs = (ProcessInfo.processInfo.systemUptime - phaseTotalStart) * 1000.0
            ProgramaTypingTiming.logBreakdown(
                path: "terminal.keyDown.phase",
                totalMs: totalMs,
                event: event,
                thresholdMs: 1.0,
                parts: [
                    ("ensureSurfaceMs", ensureSurfaceMs),
                    ("dismissNotificationMs", dismissNotificationMs),
                    ("keyboardCopyModeMs", keyboardCopyModeMs),
                    ("interpretMs", interpretMs),
                    ("syncPreeditMs", syncPreeditMs),
                    ("ghosttySendMs", ghosttySendMs),
                    ("refreshMs", refreshMs),
                ],
                extra: "marked=\(hasMarkedText() ? 1 : 0)"
            )
            ProgramaTypingTiming.logDuration(path: "terminal.keyDown", startedAt: typingTimingStart, event: event)
        }
        let ensureSurfaceStart = ProcessInfo.processInfo.systemUptime
#endif
        guard let surface = ensureSurfaceReadyForInput() else {
            requestInputRecoveryAfterSurfaceMiss(reason: "keyDown.missingSurface")
#if DEBUG
            ensureSurfaceMs = (ProcessInfo.processInfo.systemUptime - ensureSurfaceStart) * 1000.0
#endif
            super.keyDown(with: event)
            return
        }
#if DEBUG
        ensureSurfaceMs = (ProcessInfo.processInfo.systemUptime - ensureSurfaceStart) * 1000.0
#endif
        if let terminalSurface {
#if DEBUG
            let dismissNotificationStart = ProcessInfo.processInfo.systemUptime
#endif
            AppDelegate.shared?.tabManager?.dismissNotificationOnDirectInteraction(
                tabId: terminalSurface.tabId,
                surfaceId: terminalSurface.id
            )
#if DEBUG
            dismissNotificationMs = (ProcessInfo.processInfo.systemUptime - dismissNotificationStart) * 1000.0
#endif
        }
        if event.keyCode != 53 {
            endFindEscapeSuppression()
        }
        if shouldConsumeSuppressedFindEscape(event) {
            return
        }
#if DEBUG
        let keyboardCopyModeStart = ProcessInfo.processInfo.systemUptime
#endif
        if handleKeyboardCopyModeIfNeeded(event, surface: surface) {
#if DEBUG
            keyboardCopyModeMs = (ProcessInfo.processInfo.systemUptime - keyboardCopyModeStart) * 1000.0
#endif
            keyboardCopyModeConsumedKeyUps.insert(event.keyCode)
            return
        }
#if DEBUG
        keyboardCopyModeMs = (ProcessInfo.processInfo.systemUptime - keyboardCopyModeStart) * 1000.0
#endif
#if DEBUG
        recordKeyLatency(path: "keyDown", event: event)
#endif

#if DEBUG
        programaWriteChildExitProbe(
            [
                "probeKeyDownCharsHex": programaScalarHex(event.characters),
                "probeKeyDownCharsIgnoringHex": programaScalarHex(event.charactersIgnoringModifiers),
                "probeKeyDownKeyCode": String(event.keyCode),
                "probeKeyDownModsRaw": String(event.modifierFlags.rawValue),
                "probeKeyDownSurfaceId": terminalSurface?.id.uuidString ?? "",
            ],
            increments: ["probeKeyDownCount": 1]
        )
#endif

        // Fast path for control-modified terminal input (for example Ctrl+D).
        //
        // These keys are terminal control input, not text composition, so we bypass
        // AppKit text interpretation and send a single deterministic Ghostty key event.
        // This avoids intermittent drops after rapid split close/reparent transitions.
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.control) && !flags.contains(.command) && !flags.contains(.option) && !hasMarkedText() {
            terminalSurface?.recordExternalFocusState(true)
            ghostty_surface_set_focus(surface, true)
            var keyEvent = ghostty_input_key_s()
            keyEvent.action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
            keyEvent.keycode = UInt32(event.keyCode)
            keyEvent.mods = modsFromEvent(event)
            keyEvent.consumed_mods = GHOSTTY_MODS_NONE
            keyEvent.composing = false
            keyEvent.unshifted_codepoint = unshiftedCodepointFromEvent(event)

            let text = (event.charactersIgnoringModifiers ?? event.characters ?? "")
            let handled: Bool
            if text.isEmpty {
                keyEvent.text = nil
                #if DEBUG
                let ghosttySendStart = ProcessInfo.processInfo.systemUptime
                handled = sendTimedGhosttyKey(
                    surface,
                    keyEvent,
                    path: "terminal.keyDown.ctrlGhosttySend",
                    event: event
                )
                ghosttySendMs = (ProcessInfo.processInfo.systemUptime - ghosttySendStart) * 1000.0
                #else
                handled = ghostty_surface_key(surface, keyEvent)
                #endif
            } else {
                #if DEBUG
                let sendTimingStart = ProgramaTypingTiming.start()
                let ghosttySendStart = ProcessInfo.processInfo.systemUptime
                #endif
                handled = text.withCString { ptr in
                    keyEvent.text = ptr
                    return ghostty_surface_key(surface, keyEvent)
                }
                #if DEBUG
                ghosttySendMs = (ProcessInfo.processInfo.systemUptime - ghosttySendStart) * 1000.0
                ProgramaTypingTiming.logDuration(
                    path: "terminal.keyDown.ctrlGhosttySend",
                    startedAt: sendTimingStart,
                    event: event,
                    extra: "handled=\(handled ? 1 : 0)"
                )
                #endif
            }
#if DEBUG
            dlog(
                "key.ctrl path=ghostty surface=\(terminalSurface?.id.uuidString.prefix(5) ?? "nil") " +
                "handled=\(handled ? 1 : 0) keyCode=\(event.keyCode) chars=\(programaScalarHex(event.characters)) " +
                "ign=\(programaScalarHex(event.charactersIgnoringModifiers)) mods=\(event.modifierFlags.rawValue)"
            )
#endif
            // If Ghostty handled the key (action/encoding), we're done.
            // If not (e.g. `ignore` keybind), fall through to interpretKeyEvents
            // so the IME gets a chance to process this event.
            if handled { return }
        }

        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS

        // Translate mods to respect Ghostty config (e.g., macos-option-as-alt)
        let translationModsGhostty = ghostty_surface_key_translation_mods(surface, modsFromEvent(event))
        var translationMods = event.modifierFlags
        for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            let hasFlag: Bool
            switch flag {
            case .shift:
                hasFlag = (translationModsGhostty.rawValue & GHOSTTY_MODS_SHIFT.rawValue) != 0
            case .control:
                hasFlag = (translationModsGhostty.rawValue & GHOSTTY_MODS_CTRL.rawValue) != 0
            case .option:
                hasFlag = (translationModsGhostty.rawValue & GHOSTTY_MODS_ALT.rawValue) != 0
            case .command:
                hasFlag = (translationModsGhostty.rawValue & GHOSTTY_MODS_SUPER.rawValue) != 0
            default:
                hasFlag = translationMods.contains(flag)
            }
            if hasFlag {
                translationMods.insert(flag)
            } else {
                translationMods.remove(flag)
            }
        }

        let translationEvent: NSEvent
        if translationMods == event.modifierFlags {
            translationEvent = event
        } else {
            translationEvent = NSEvent.keyEvent(
                with: event.type,
                location: event.locationInWindow,
                modifierFlags: translationMods,
                timestamp: event.timestamp,
                windowNumber: event.windowNumber,
                context: nil,
                characters: event.characters(byApplyingModifiers: translationMods) ?? "",
                charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                isARepeat: event.isARepeat,
                keyCode: event.keyCode
            ) ?? event
        }

        // Set up text accumulator for interpretKeyEvents
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }

        // Track whether we had marked text (IME preedit) before this event,
        // so we can detect when composition ends.
        let markedTextBefore = markedText.length > 0

        // Capture the keyboard layout ID before interpretation so we can
        // detect if an IME changed it (e.g. toggling input methods).
        // We only check when not already in a preedit state.
        let keyboardIdBefore: String? = if (!markedTextBefore) {
            KeyboardLayout.id
        } else {
            nil
        }

        // Let the input system handle the event (for IME, dead keys, etc.)
#if DEBUG
        let interpretTimingStart = ProgramaTypingTiming.start()
        let interpretPhaseStart = ProcessInfo.processInfo.systemUptime
#endif
        interpretKeyEvents([translationEvent])
#if DEBUG
        interpretMs = (ProcessInfo.processInfo.systemUptime - interpretPhaseStart) * 1000.0
        ProgramaTypingTiming.logDuration(
            path: "terminal.keyDown.interpretKeyEvents",
            startedAt: interpretTimingStart,
            event: event
        )
#endif

        // If the keyboard layout changed, an input method grabbed the event.
        // Sync preedit and return without sending the key to Ghostty.
        if !markedTextBefore, let kbBefore = keyboardIdBefore, kbBefore != KeyboardLayout.id {
#if DEBUG
            let syncPreeditStart = ProcessInfo.processInfo.systemUptime
#endif
            syncPreedit(clearIfNeeded: markedTextBefore)
#if DEBUG
            syncPreeditMs = (ProcessInfo.processInfo.systemUptime - syncPreeditStart) * 1000.0
#endif
            return
        }

        // Sync the preedit state with Ghostty so it can render the IME
        // composition overlay (e.g. for Korean, Japanese, Chinese input).
#if DEBUG
        let syncPreeditStart = ProcessInfo.processInfo.systemUptime
#endif
        syncPreedit(clearIfNeeded: markedTextBefore)
#if DEBUG
        syncPreeditMs = (ProcessInfo.processInfo.systemUptime - syncPreeditStart) * 1000.0
#endif

        // Build the key event
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = action
        keyEvent.keycode = UInt32(event.keyCode)
        keyEvent.mods = modsFromEvent(event)
        // Control and Command never contribute to text translation
        keyEvent.consumed_mods = consumedModsFromFlags(translationMods)
        keyEvent.unshifted_codepoint = unshiftedCodepointFromEvent(event)

        // We're composing if we have preedit (the obvious case). But we're also
        // composing if we don't have preedit and we had marked text before,
        // because this input probably just reset the preedit state. It shouldn't
        // be encoded. Example: Japanese begin composing, then press backspace.
        // This should only cancel the composing state but not actually delete
        // the prior input characters (prior to the composing).
        keyEvent.composing = markedText.length > 0 || markedTextBefore

        // Use accumulated text from insertText (for IME), or compute text for key.
        //
        // Some AppKit key paths route Shift+` through interpretKeyEvents' insertText
        // as a literal ESC control character (0x1B) instead of dispatching it as a
        // command, even though the physical key should produce "~". When that exact
        // quirk is detected against the original event, substitute the accumulated
        // ESC text with the correct "~" before it's evaluated below — otherwise
        // shouldSendText correctly (but wrongly, for this quirk) rejects the ESC
        // control character and no text is ever sent.
        let accumulatedText: [String] = {
            let raw = keyTextAccumulator ?? []
            guard raw == ["\u{1B}"], let escTildeOverride = shiftBackquoteEscFallbackText(for: event) else {
                return raw
            }
            return [escTildeOverride]
        }()
        var shouldRefreshAfterTextInput = false
        if !accumulatedText.isEmpty {
            // Accumulated text comes from insertText (IME composition result).
            // These never have "composing" set to true because these are the
            // result of a composition.
            keyEvent.composing = false
            for text in accumulatedText {
                if shouldSendText(text) {
                    shouldRefreshAfterTextInput = true
#if DEBUG
                    let sendTimingStart = ProgramaTypingTiming.start()
                    let ghosttySendStart = ProcessInfo.processInfo.systemUptime
#endif
                    text.withCString { ptr in
                        keyEvent.text = ptr
                        #if DEBUG
                        _ = sendTimedGhosttyKey(
                            surface,
                            keyEvent,
                            path: "terminal.keyDown.accumulatedGhosttySend",
                            event: event,
                            extra: "textBytes=\(text.utf8.count)"
                        )
                        #else
                        _ = sendGhosttyKey(surface, keyEvent)
                        #endif
                    }
#if DEBUG
                    ghosttySendMs += (ProcessInfo.processInfo.systemUptime - ghosttySendStart) * 1000.0
                    ProgramaTypingTiming.logDuration(
                        path: "terminal.keyDown.accumulatedGhosttySend.total",
                        startedAt: sendTimingStart,
                        event: event,
                        extra: "textBytes=\(text.utf8.count)"
                    )
#endif
                } else {
                    keyEvent.consumed_mods = GHOSTTY_MODS_NONE
                    keyEvent.text = nil
                    #if DEBUG
                    let ghosttySendStart = ProcessInfo.processInfo.systemUptime
                    _ = sendTimedGhosttyKey(
                        surface,
                        keyEvent,
                        path: "terminal.keyDown.accumulatedGhosttySend",
                        event: event
                    )
                    ghosttySendMs += (ProcessInfo.processInfo.systemUptime - ghosttySendStart) * 1000.0
                    #else
                    _ = ghostty_surface_key(surface, keyEvent)
                    #endif
                }
            }

            if shouldSendCommittedIMEConfirmKey(
                event: translationEvent,
                markedTextBefore: markedTextBefore
            ) {
                keyEvent.consumed_mods = GHOSTTY_MODS_NONE
                keyEvent.text = nil
#if DEBUG
                let ghosttySendStart = ProcessInfo.processInfo.systemUptime
                _ = sendTimedGhosttyKey(
                    surface,
                    keyEvent,
                    path: "terminal.keyDown.accumulatedConfirmGhosttySend",
                    event: event
                )
                ghosttySendMs += (ProcessInfo.processInfo.systemUptime - ghosttySendStart) * 1000.0
#else
                _ = ghostty_surface_key(surface, keyEvent)
#endif
            }
        } else {
            // Get the appropriate text for this key event
            // For control characters, this returns the unmodified character
            // so Ghostty's KeyEncoder can handle ctrl encoding
            let suppressShiftSpaceFallbackText =
                shouldSuppressShiftSpaceFallbackText(
                    event: translationEvent,
                    markedTextBefore: markedTextBefore
                )
            let suppressComposingFallbackText = keyEvent.composing
            // Check the Shift+`-reported-as-ESC quirk against the original event
            // before falling back to the (possibly mods-translated) textForKeyEvent
            // result — see shiftBackquoteEscFallbackText's doc comment.
            if let text = shiftBackquoteEscFallbackText(for: event) ?? textForKeyEvent(translationEvent) {
                if shouldSendText(text),
                   !suppressShiftSpaceFallbackText,
                   !suppressComposingFallbackText {
                    shouldRefreshAfterTextInput = true
#if DEBUG
                    let sendTimingStart = ProgramaTypingTiming.start()
                    let ghosttySendStart = ProcessInfo.processInfo.systemUptime
#endif
                    text.withCString { ptr in
                        keyEvent.text = ptr
                        #if DEBUG
                        _ = sendTimedGhosttyKey(
                            surface,
                            keyEvent,
                            path: "terminal.keyDown.ghosttySend",
                            event: event,
                            extra: "textBytes=\(text.utf8.count)"
                        )
                        #else
                        _ = sendGhosttyKey(surface, keyEvent)
                        #endif
                    }
#if DEBUG
                    ghosttySendMs += (ProcessInfo.processInfo.systemUptime - ghosttySendStart) * 1000.0
                    ProgramaTypingTiming.logDuration(
                        path: "terminal.keyDown.ghosttySend.total",
                        startedAt: sendTimingStart,
                        event: event,
                        extra: "textBytes=\(text.utf8.count)"
                    )
#endif
                } else {
                    keyEvent.consumed_mods = GHOSTTY_MODS_NONE
                    keyEvent.text = nil
                    #if DEBUG
                    let ghosttySendStart = ProcessInfo.processInfo.systemUptime
                    _ = sendTimedGhosttyKey(
                        surface,
                        keyEvent,
                        path: "terminal.keyDown.ghosttySend",
                        event: event
                    )
                    ghosttySendMs += (ProcessInfo.processInfo.systemUptime - ghosttySendStart) * 1000.0
                    #else
                    _ = ghostty_surface_key(surface, keyEvent)
                    #endif
                }
            } else {
                keyEvent.consumed_mods = GHOSTTY_MODS_NONE
                keyEvent.text = nil
                #if DEBUG
                let ghosttySendStart = ProcessInfo.processInfo.systemUptime
                _ = sendTimedGhosttyKey(
                    surface,
                    keyEvent,
                    path: "terminal.keyDown.ghosttySend",
                    event: event
                )
                ghosttySendMs += (ProcessInfo.processInfo.systemUptime - ghosttySendStart) * 1000.0
                #else
                _ = ghostty_surface_key(surface, keyEvent)
                #endif
            }
        }

        if shouldRefreshAfterTextInput {
#if DEBUG
            let refreshStart = ProcessInfo.processInfo.systemUptime
#endif
            terminalSurface?.forceRefresh(reason: "keyDown.textInput")
#if DEBUG
            refreshMs = (ProcessInfo.processInfo.systemUptime - refreshStart) * 1000.0
#endif
        }

        // Rendering is driven by Ghostty's wakeups/renderer.
    }

    @discardableResult
    func sendGhosttyKey(_ surface: ghostty_surface_t, _ keyEvent: ghostty_input_key_s) -> Bool {
#if DEBUG
        Self.debugGhosttySurfaceKeyEventObserver?(keyEvent)
#endif
        return ghostty_surface_key(surface, keyEvent)
    }

#if DEBUG
    @discardableResult
    private func sendTimedGhosttyKey(
        _ surface: ghostty_surface_t,
        _ keyEvent: ghostty_input_key_s,
        path: String,
        event: NSEvent? = nil,
        extra: String? = nil
    ) -> Bool {
        let timingStart = ProgramaTypingTiming.start()
        let handled = sendGhosttyKey(surface, keyEvent)
        let baseExtra = "handled=\(handled ? 1 : 0)"
        let mergedExtra: String
        if let extra, !extra.isEmpty {
            mergedExtra = "\(baseExtra) \(extra)"
        } else {
            mergedExtra = baseExtra
        }
        ProgramaTypingTiming.logDuration(path: path, startedAt: timingStart, event: event, extra: mergedExtra)
        return handled
    }
#endif

    override func keyUp(with event: NSEvent) {
        guard let surface = ensureSurfaceReadyForInput() else {
            super.keyUp(with: event)
            return
        }
        if event.keyCode != 53 {
            endFindEscapeSuppression()
        }
        if shouldConsumeSuppressedFindEscape(event) {
            endFindEscapeSuppression()
            return
        }
        if event.keyCode == 53 {
            endFindEscapeSuppression()
        }

        if keyboardCopyModeConsumedKeyUps.remove(event.keyCode) != nil {
            return
        }

        // Build release events from the same translation path as keyDown so
        // consumers that depend on precise key identity (for example Space
        // hold/release flows) receive consistent metadata.
        var keyEvent = ghosttyKeyEvent(for: event, surface: surface)
        keyEvent.action = GHOSTTY_ACTION_RELEASE
        keyEvent.text = nil
        keyEvent.composing = false
        _ = sendGhosttyKey(surface, keyEvent)
    }

    override func flagsChanged(with event: NSEvent) {
        guard let surface = surface else {
            super.flagsChanged(with: event)
            return
        }

        var keyEvent = ghostty_input_key_s()
        keyEvent.action = GHOSTTY_ACTION_PRESS
        keyEvent.keycode = UInt32(event.keyCode)
        keyEvent.mods = modsFromEvent(event)
        keyEvent.consumed_mods = GHOSTTY_MODS_NONE
        keyEvent.text = nil
        keyEvent.composing = false
        _ = ghostty_surface_key(surface, keyEvent)

        let selectionActive = ghostty_surface_has_selection(surface)
        let suppressCommandPathHover = event.modifierFlags.contains(.command) && selectionActive
        // Refresh ghostty's mouse position so quicklook_word uses current coordinates
        // when Cmd is pressed while the pointer is stationary.
        let eventPoint = convert(event.locationInWindow, from: nil)
        trackMousePointIfUsable(eventPoint)
        let point = preferredPointerPoint(from: eventPoint) ?? eventPoint
#if DEBUG
        if event.modifierFlags.contains(.command) || selectionActive {
            runtimeDebugLog(
                hypothesisID: "h1",
                name: "flags_changed",
                expected: "selection active should suppress cmd-hover",
                actual: suppressCommandPathHover ? "suppressed" : "forwarded",
                data: [
                    "flags": debugModifierString(event.modifierFlags),
                    "selection_active": selectionActive,
                    "point_x": eventPoint.x,
                    "point_y": eventPoint.y,
                    "resolved_point_x": point.x,
                    "resolved_point_y": point.y
                ]
            )
        }
#endif
        ghostty_surface_mouse_pos(
            surface,
            point.x,
            bounds.height - point.y,
            hoverModsFromFlags(
                event.modifierFlags,
                suppressCommandPathHover: suppressCommandPathHover
            )
        )
        updateWordPathHover(
            at: point,
            cmdHeld: event.modifierFlags.contains(.command),
            suppressPathHover: suppressCommandPathHover
        )
    }

    func beginFindEscapeSuppression() {
        isFindEscapeSuppressionArmed = true
    }

    private func endFindEscapeSuppression() {
        isFindEscapeSuppressionArmed = false
    }

    private func shouldConsumeSuppressedFindEscape(_ event: NSEvent) -> Bool {
        guard event.keyCode == 53 else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.isEmpty else { return false }
        return isFindEscapeSuppressionArmed
    }

    /// Detect AppKit key paths that report Shift+` as a bare ESC control character
    /// even though the physical key should produce "~". This must be checked against
    /// the original, untranslated keyDown event: Ghostty's mods-translation step
    /// (`translationEvent` in keyDown) can consume the shift bit for printable keys
    /// and recompute `.characters` from `characters(byApplyingModifiers:)`, which
    /// erases this signal entirely (and returns nil for synthetic/test events with
    /// no backing hardware report), silently dropping the "~" fallback below.
    private func shiftBackquoteEscFallbackText(for event: NSEvent) -> String? {
        guard let chars = event.characters, chars.count == 1,
              let scalar = chars.unicodeScalars.first,
              scalar.value == 0x1B else { return nil }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == [.shift], event.charactersIgnoringModifiers == "`" else { return nil }
        return "~"
    }

    /// Get the characters for a key event with control character handling.
    /// When control is pressed, we get the character without the control modifier
    /// so Ghostty's KeyEncoder can apply its own control character encoding.
    private func textForKeyEvent(_ event: NSEvent) -> String? {
        guard let chars = event.characters, !chars.isEmpty else { return nil }

        if chars.count == 1, let scalar = chars.unicodeScalars.first {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            // If we have a single control character, return the character without
            // the control modifier so Ghostty's KeyEncoder can handle it.
            if isControlCharacterScalar(scalar) {
                if flags.contains(.control) {
                    return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control))
                }

                // Some AppKit key paths can report Shift+` as a bare ESC control
                // character even though the physical key should produce "~".
                if scalar.value == 0x1B,
                   flags == [.shift],
                   event.charactersIgnoringModifiers == "`" {
                    return "~"
                }
            }
            // Private Use Area characters (function keys) should not be sent
            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF {
                return nil
            }
        }

        return chars
    }

    /// Get the unshifted codepoint for the key event
    private func unshiftedCodepointFromEvent(_ event: NSEvent) -> UInt32 {
        if let layoutChars = KeyboardLayout.character(forKeyCode: event.keyCode),
           layoutChars.count == 1,
           let layoutScalar = layoutChars.unicodeScalars.first,
           layoutScalar.value >= 0x20,
           !(layoutScalar.value >= 0xF700 && layoutScalar.value <= 0xF8FF) {
            return layoutScalar.value
        }

        guard let chars = (event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers ?? event.characters),
              let scalar = chars.unicodeScalars.first else { return 0 }
        return scalar.value
    }

    private func isControlCharacterScalar(_ scalar: UnicodeScalar) -> Bool {
        scalar.value < 0x20 || scalar.value == 0x7F
    }

    private func shouldSendText(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        if text.count == 1, let scalar = text.unicodeScalars.first {
            return !isControlCharacterScalar(scalar)
        }
        return true
    }

    /// If AppKit consumed Shift+Space for IME/input-source switching, interpretKeyEvents
    /// can return without insertText and without a detectable layout ID change.
    /// In that case we must not synthesize a literal space fallback.
    func shouldSuppressShiftSpaceFallbackText(event: NSEvent, markedTextBefore: Bool) -> Bool {
        guard event.keyCode == 49 else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == [.shift] else { return false }
        guard !markedTextBefore, markedText.length == 0 else { return false }
        return true
    }

    private func shouldSendCommittedIMEConfirmKey(event: NSEvent, markedTextBefore: Bool) -> Bool {
        guard markedTextBefore, markedText.length == 0 else { return false }
        guard event.keyCode == 36 || event.keyCode == 76 else { return false }
        // Korean IME: Enter commits the syllable AND executes the command (single step).
        // Japanese/Chinese IME: Enter only confirms the conversion; a second Enter executes.
        // Only send the extra Return key for Korean input sources.
        guard let sourceId = KeyboardLayout.id else { return false }
        return sourceId.range(of: "korean", options: .caseInsensitive) != nil
    }

    private func ghosttyKeyEvent(for event: NSEvent, surface: ghostty_surface_t) -> ghostty_input_key_s {
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = GHOSTTY_ACTION_PRESS
        keyEvent.keycode = UInt32(event.keyCode)
        keyEvent.mods = modsFromEvent(event)

        // Translate mods to respect Ghostty config (e.g., macos-option-as-alt).
        let translationModsGhostty = ghostty_surface_key_translation_mods(surface, modsFromEvent(event))
        var translationMods = event.modifierFlags
        for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            let hasFlag: Bool
            switch flag {
            case .shift:
                hasFlag = (translationModsGhostty.rawValue & GHOSTTY_MODS_SHIFT.rawValue) != 0
            case .control:
                hasFlag = (translationModsGhostty.rawValue & GHOSTTY_MODS_CTRL.rawValue) != 0
            case .option:
                hasFlag = (translationModsGhostty.rawValue & GHOSTTY_MODS_ALT.rawValue) != 0
            case .command:
                hasFlag = (translationModsGhostty.rawValue & GHOSTTY_MODS_SUPER.rawValue) != 0
            default:
                hasFlag = translationMods.contains(flag)
            }
            if hasFlag {
                translationMods.insert(flag)
            } else {
                translationMods.remove(flag)
            }
        }

        keyEvent.consumed_mods = consumedModsFromFlags(translationMods)
        keyEvent.text = nil
        keyEvent.composing = false
        keyEvent.unshifted_codepoint = unshiftedCodepointFromEvent(event)
        return keyEvent
    }

    func updateKeySequence(_ action: ghostty_action_key_sequence_s) {
        if action.active {
            keySequence.append(action.trigger)
        } else {
            keySequence.removeAll()
        }
    }

    func updateKeyTable(_ action: ghostty_action_key_table_s) {
        switch action.tag {
        case GHOSTTY_KEY_TABLE_ACTIVATE:
            let namePtr = action.value.activate.name
            let nameLen = Int(action.value.activate.len)
            let name: String
            if let namePtr, nameLen > 0 {
                let data = Data(bytes: namePtr, count: nameLen)
                name = String(data: data, encoding: .utf8) ?? ""
            } else {
                name = ""
            }
            keyTables.append(name)
        case GHOSTTY_KEY_TABLE_DEACTIVATE:
            _ = keyTables.popLast()
        case GHOSTTY_KEY_TABLE_DEACTIVATE_ALL:
            keyTables.removeAll()
        default:
            break
        }

        terminalSurface?.hostedView.syncKeyStateIndicator(text: currentKeyStateIndicatorText)
    }
}
