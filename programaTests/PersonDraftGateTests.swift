import XCTest
import AppKit

#if canImport(Programa_DEV)
@testable import Programa_DEV
#elseif canImport(Programa)
@testable import Programa
#endif

/// The person-draft gate keeps agent text out of a pane while a person has unsent typed input
/// (INC-687). A wrong transition either mixes agent text into the person's line (false open) or
/// blocks a pane nothing can release (false hold), so every cell of the table is pinned.
final class PersonDraftGateTransitionTests: XCTestCase {
    private let t0: TimeInterval = 1_000
    private var drafting: PersonDraftGate { .drafting(since: t0, lastKeyAt: t0) }

    private func next(_ state: PersonDraftGate, _ event: PersonDraftEvent) -> PersonDraftGate {
        PersonDraftGate.next(state, event)
    }

    // MARK: open

    func testOpenTypedStartsDraftAtKeystrokeTime() {
        XCTAssertEqual(next(.open, .typed(at: 42)), .drafting(since: 42, lastKeyAt: 42))
    }

    func testOpenAgentBlockedMovesToAnsweringPrompt() {
        XCTAssertEqual(next(.open, .agentBlocked), .answeringPrompt)
    }

    func testOpenStaysOpenForEveryNonTypingEvent() {
        for event: PersonDraftEvent in [.submitted, .cleared, .agentUnblocked, .forcedSubmitDelivered, .expired] {
            XCTAssertEqual(next(.open, event), .open, "open + \(event)")
        }
    }

    // MARK: answeringPrompt

    func testAnsweringPromptIgnoresTypingSoAnApprovalAnswerNeverStartsADraft() {
        XCTAssertEqual(next(.answeringPrompt, .typed(at: 5)), .answeringPrompt)
    }

    func testAnsweringPromptOnlyLeavesOnAgentUnblocked() {
        for event: PersonDraftEvent in [.submitted, .cleared, .agentBlocked, .forcedSubmitDelivered, .expired] {
            XCTAssertEqual(next(.answeringPrompt, event), .answeringPrompt, "answeringPrompt + \(event)")
        }
        XCTAssertEqual(next(.answeringPrompt, .agentUnblocked), .open)
    }

    func testTypingAfterApprovalPromptClosesStartsADraft() {
        let afterAnswer = next(next(next(.open, .agentBlocked), .typed(at: 1)), .agentUnblocked)
        XCTAssertEqual(afterAnswer, .open)
        XCTAssertEqual(next(afterAnswer, .typed(at: 2)), .drafting(since: 2, lastKeyAt: 2))
    }

    // MARK: drafting

    func testDraftingTypedKeepsSinceAndMovesLastKey() {
        XCTAssertEqual(next(drafting, .typed(at: t0 + 10)), .drafting(since: t0, lastKeyAt: t0 + 10))
    }

    func testDraftingEndsOnSubmitClearForcedSubmitAndExpiry() {
        for event: PersonDraftEvent in [.submitted, .cleared, .forcedSubmitDelivered, .expired] {
            XCTAssertEqual(next(drafting, event), .open, "drafting + \(event)")
        }
    }

    func testDraftTypedBeforeApprovalPromptSurvivesAgentStateChanges() {
        XCTAssertEqual(next(drafting, .agentBlocked), drafting)
        XCTAssertEqual(next(drafting, .agentUnblocked), drafting)
    }

    // MARK: expiry

    func testHoldsUntilExactlySixtySecondsAfterLastKeystroke() {
        let state = PersonDraftGate.drafting(since: t0 - 30, lastKeyAt: t0)
        XCTAssertEqual(PersonDraftGate.idleExpiry, 60)
        XCTAssertTrue(state.isHolding(now: t0))
        XCTAssertTrue(state.isHolding(now: t0 + 59.999))
        XCTAssertFalse(state.isHolding(now: t0 + 60), "a draft left alone for 60 s must stop holding")
        XCTAssertFalse(state.isHolding(now: t0 + 600))
    }

    func testOnlyDraftingHolds() {
        XCTAssertFalse(PersonDraftGate.open.isHolding(now: t0))
        XCTAssertFalse(PersonDraftGate.answeringPrompt.isHolding(now: t0))
    }

    func testKeystrokeAfterExpiredDraftRestartsSince() {
        let stale = PersonDraftGate.drafting(since: t0 - 100, lastKeyAt: t0)
        XCTAssertEqual(next(stale, .typed(at: t0 + 60)), .drafting(since: t0 + 60, lastKeyAt: t0 + 60))
        XCTAssertEqual(next(stale, .typed(at: t0 + 59.999)), .drafting(since: t0 - 100, lastKeyAt: t0 + 59.999))
    }
}

final class DraftGuardSettingsTests: XCTestCase {
    func testHoldIsOnUnlessTurnedOff() throws {
        let suite = "PersonDraftGateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertTrue(DraftGuardSettings.isEnabled(defaults: defaults), "unset must mean protected")
        defaults.set(false, forKey: DraftGuardSettings.enabledKey)
        XCTAssertFalse(DraftGuardSettings.isEnabled(defaults: defaults))
        defaults.set(true, forKey: DraftGuardSettings.enabledKey)
        XCTAssertTrue(DraftGuardSettings.isEnabled(defaults: defaults))
    }
}

/// The surface-level hold and the socket guard that reads it.
@MainActor
final class PersonDraftHoldGuardTests: XCTestCase {
    private func makeSurface() -> TerminalSurface {
        TerminalSurface(tabId: UUID(), context: GHOSTTY_SURFACE_CONTEXT_SPLIT, configTemplate: nil, workingDirectory: nil)
    }

    func testActiveHoldReportsAgeAndTimeLeft() throws {
        let surface = makeSurface()
        surface.noteDraftEvent(.typed(at: 100))
        surface.noteDraftEvent(.typed(at: 110))

        let hold = try XCTUnwrap(surface.activeDraftHold(now: 115))
        XCTAssertEqual(hold.ageMs, 15_000)
        XCTAssertEqual(hold.expiresInMs, 55_000)
    }

    func testIdleDraftIsReleasedAtCheckTime() {
        let surface = makeSurface()
        surface.noteDraftEvent(.typed(at: 100))

        XCTAssertNil(surface.activeDraftHold(now: 160))
        XCTAssertEqual(surface.draftGate, .open, "an expired draft must not linger and hold later writes")
    }

    func testAgentBlockedChangeExpiresAStaleDraftFirst() {
        let surface = makeSurface()
        surface.noteDraftEvent(.typed(at: 100))
        surface.noteAgentBlockedChange(isBlocked: true, now: 105)
        XCTAssertTrue(surface.draftGate.isDrafting, "a live draft survives an approval prompt")

        surface.noteAgentBlockedChange(isBlocked: false, now: 200)
        surface.noteAgentBlockedChange(isBlocked: true, now: 200)
        XCTAssertEqual(surface.draftGate, .answeringPrompt, "a stale draft must not shadow the approval state")
    }

    func testGuardRejectsWithDraftData() throws {
        let surface = makeSurface()
        let panel = TerminalPanel(workspaceId: UUID(), surface: surface)
        let surfaceId = UUID()
        surface.noteDraftEvent(.typed(at: ProcessInfo.processInfo.systemUptime))

        let rejection = TerminalController.shared.v2DraftGuardRejection(params: [:], surfaceId: surfaceId, terminalPanel: panel)
        guard case .err(let code, _, let data)? = rejection else {
            return XCTFail("Expected draft_in_progress, got \(String(describing: rejection))")
        }
        XCTAssertEqual(code, "draft_in_progress")
        let fields = try XCTUnwrap(data as? [String: Any])
        XCTAssertEqual(fields["surface_id"] as? String, surfaceId.uuidString)
        XCTAssertTrue((fields["surface_ref"] as? String)?.hasPrefix("surface:") == true, "\(fields)")
        XCTAssertNotNil(fields["draft_age_ms"] as? Int)
        let expiresIn = try XCTUnwrap(fields["expires_in_ms"] as? Int)
        XCTAssertTrue((1...60_000).contains(expiresIn), "expires_in_ms=\(expiresIn)")
    }

    func testForceAndKillSwitchBypassTheGuardButKeepTracking() {
        let surface = makeSurface()
        let panel = TerminalPanel(workspaceId: UUID(), surface: surface)
        surface.noteDraftEvent(.typed(at: ProcessInfo.processInfo.systemUptime))

        XCTAssertNil(TerminalController.shared.v2DraftGuardRejection(params: ["force": true], surfaceId: UUID(), terminalPanel: panel))

        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: DraftGuardSettings.enabledKey)
        defer {
            if let previous { defaults.set(previous, forKey: DraftGuardSettings.enabledKey) }
            else { defaults.removeObject(forKey: DraftGuardSettings.enabledKey) }
        }
        defaults.set(false, forKey: DraftGuardSettings.enabledKey)
        XCTAssertNil(TerminalController.shared.v2DraftGuardRejection(params: [:], surfaceId: UUID(), terminalPanel: panel))
        XCTAssertTrue(surface.draftGate.isDrafting, "tracking keeps running while the hold is off")

        defaults.set(true, forKey: DraftGuardSettings.enabledKey)
        XCTAssertNotNil(TerminalController.shared.v2DraftGuardRejection(params: [:], surfaceId: UUID(), terminalPanel: panel),
                        "turning the hold back on mid-draft protects that draft")
    }

    func testSubmittingForcedWriteEndsTheDraft() {
        let surface = makeSurface()
        let panel = TerminalPanel(workspaceId: UUID(), surface: surface)
        let now = ProcessInfo.processInfo.systemUptime

        surface.noteDraftEvent(.typed(at: now))
        TerminalController.shared.v2NoteSocketSubmit(text: "partial", terminalPanel: panel)
        TerminalController.shared.v2NoteSocketSubmit(text: "", keys: ["tab", "escape"], terminalPanel: panel)
        XCTAssertTrue(surface.draftGate.isDrafting, "text without CR/LF does not submit the person's line")

        TerminalController.shared.v2NoteSocketSubmit(text: "run\r", terminalPanel: panel)
        XCTAssertEqual(surface.draftGate, .open)

        surface.noteDraftEvent(.typed(at: now))
        TerminalController.shared.v2NoteSocketSubmit(text: "run\n", terminalPanel: panel)
        XCTAssertEqual(surface.draftGate, .open)

        for key in ["enter", "Return"] {
            surface.noteDraftEvent(.typed(at: now))
            TerminalController.shared.v2NoteSocketSubmit(text: "", keys: [key], terminalPanel: panel)
            XCTAssertEqual(surface.draftGate, .open, "key \(key)")
        }
    }

    func testForcedControlTextClearsTheDraft() {
        let surface = makeSurface()
        let panel = TerminalPanel(workspaceId: UUID(), surface: surface)
        let now = ProcessInfo.processInfo.systemUptime

        for text in ["partial\u{03}", "partial\u{15}"] {
            surface.noteDraftEvent(.typed(at: now))
            TerminalController.shared.v2NoteSocketSubmit(text: text, terminalPanel: panel)
            XCTAssertEqual(surface.draftGate, .open, "a delivered line-clear control releases the draft")
        }
    }

    func testForcedControlKeyClearsTheDraft() {
        let surface = makeSurface()
        let panel = TerminalPanel(workspaceId: UUID(), surface: surface)
        let now = ProcessInfo.processInfo.systemUptime

        for key in ["ctrl+c", "ctrl-c", "control+c", "control-c", "sigint",
                    "ctrl+u", "ctrl-u", "control+u", "control-u", "Ctrl+C", "CTRL+U", "SIGINT"] {
            surface.noteDraftEvent(.typed(at: now))
            TerminalController.shared.v2NoteSocketSubmit(text: "", keys: [key], terminalPanel: panel)
            XCTAssertEqual(surface.draftGate, .open, "key \(key) clears the person's line")
        }
    }

    func testForcedPlainTextCLeavesTheDraftHeld() {
        let surface = makeSurface()
        let panel = TerminalPanel(workspaceId: UUID(), surface: surface)
        let now = ProcessInfo.processInfo.systemUptime

        surface.noteDraftEvent(.typed(at: now))
        TerminalController.shared.v2NoteSocketSubmit(text: "c", terminalPanel: panel)
        XCTAssertTrue(surface.draftGate.isDrafting, "plain c does not clear the person's line")
    }
}

/// Which real keystrokes move the gate, driven through `GhosttyNSView.keyDown` with events shaped
/// like the hardware ones. The socket's `debug.shortcut.simulate` cannot build these faithfully
/// (no Escape/Backspace/Tab, arrows without `.function`), so this is where they are covered.
@MainActor
final class PersonDraftGateKeyDownTests: XCTestCase {
    private var window: NSWindow!
    private var surface: TerminalSurface!
    private var view: GhosttyNSView!

    override func setUpWithError() throws {
        try super.setUpWithError()
        _ = NSApplication.shared
        surface = TerminalSurface(tabId: UUID(), context: GHOSTTY_SURFACE_CONTEXT_SPLIT, configTemplate: nil, workingDirectory: nil)
        let hostedView = surface.hostedView
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let contentView = try XCTUnwrap(window.contentView)
        hostedView.frame = contentView.bounds
        hostedView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostedView)
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        hostedView.setVisibleInUI(true)
        hostedView.setActive(true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        view = try XCTUnwrap(Self.findGhosttyNSView(in: hostedView))
        window.makeFirstResponder(view)
    }

    override func tearDown() {
        window?.orderOut(nil)
        window = nil
        view = nil
        surface = nil
        super.tearDown()
    }

    private static func findGhosttyNSView(in view: NSView) -> GhosttyNSView? {
        if let match = view as? GhosttyNSView { return match }
        for subview in view.subviews {
            if let match = findGhosttyNSView(in: subview) { return match }
        }
        return nil
    }

    private func press(
        _ characters: String,
        ignoringModifiers: String? = nil,
        keyCode: UInt16,
        flags: NSEvent.ModifierFlags = []
    ) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: ignoringModifiers ?? characters,
            isARepeat: false,
            keyCode: keyCode
        ))
        view.keyDown(with: event)
    }

    private func typeDraft() throws {
        try press("a", keyCode: 0)
        XCTAssertTrue(surface.draftGate.isDrafting, "a typed letter must start a draft")
    }

    func testTypedLetterStartsDraftAndBareReturnSubmits() throws {
        try typeDraft()
        try press("\r", keyCode: 36)
        XCTAssertEqual(surface.draftGate, .open)
    }

    // Ghostty marks its default cmd+v binding performable, so AppKit routes it through
    // performKeyEquivalent into keyDown and never calls paste(_:).
    func testCmdVThroughKeyEquivalentStartsDraft() throws {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        defer {
            pasteboard.clearContents()
            if let saved { pasteboard.setString(saved, forType: .string) }
        }
        pasteboard.clearContents()
        pasteboard.setString("pasted", forType: .string)

        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "v",
            charactersIgnoringModifiers: "v",
            isARepeat: false,
            keyCode: 9
        ))
        XCTAssertTrue(view.performKeyEquivalent(with: event), "cmd+v must be handled as a Ghostty binding")
        XCTAssertTrue(surface.draftGate.isDrafting, "a person's cmd+v paste must start a draft")
    }

    func testKeypadEnterSubmits() throws {
        try typeDraft()
        try press("\u{3}", keyCode: 76, flags: [.numericPad])
        XCTAssertEqual(surface.draftGate, .open)
    }

    func testShiftReturnInsertsANewlineAndKeepsTheDraft() throws {
        try typeDraft()
        try press("\r", keyCode: 36, flags: [.shift])
        XCTAssertTrue(surface.draftGate.isDrafting, "Shift+Return is a newline in agent TUIs, not a submit")
    }

    func testCtrlCClearsTheDraft() throws {
        try typeDraft()
        try press("\u{3}", ignoringModifiers: "c", keyCode: 8, flags: [.control])
        XCTAssertEqual(surface.draftGate, .open)
    }

    func testCtrlUClearsTheDraft() throws {
        try typeDraft()
        try press("\u{15}", ignoringModifiers: "u", keyCode: 32, flags: [.control])
        XCTAssertEqual(surface.draftGate, .open)
    }

    /// AppKit can report the control character in `charactersIgnoringModifiers` for Ctrl+letter
    /// (the case `debug.shortcut.simulate` reproduces). Ctrl+C must still release the pane.
    func testCtrlCClearsTheDraftWhenReportedAsControlCharacter() throws {
        try typeDraft()
        try press("\u{3}", ignoringModifiers: "\u{3}", keyCode: 8, flags: [.control])
        XCTAssertEqual(surface.draftGate, .open)
    }

    func testCtrlUClearsTheDraftWhenReportedAsControlCharacter() throws {
        try typeDraft()
        try press("\u{15}", ignoringModifiers: "\u{15}", keyCode: 32, flags: [.control])
        XCTAssertEqual(surface.draftGate, .open)
    }

    func testEditingAndNavigationKeysNeverStartADraft() throws {
        let keys: [(String, UInt16, NSEvent.ModifierFlags, String)] = [
            ("\u{1B}", 53, [], "Escape"),
            ("\u{7F}", 51, [], "Backspace"),
            ("\t", 48, [], "Tab"),
            ("\u{F702}", 123, [.function, .numericPad], "Left"),
            ("\u{F703}", 124, [.function, .numericPad], "Right"),
            ("\u{F700}", 126, [.function, .numericPad], "Up"),
            ("\u{F701}", 125, [.function, .numericPad], "Down"),
            ("\u{4}", 2, [.control], "Ctrl+D"),
        ]
        for (chars, code, flags, name) in keys {
            try press(chars, ignoringModifiers: chars, keyCode: code, flags: flags)
            XCTAssertEqual(surface.draftGate, .open, "\(name) must not start a draft")
        }
    }

    func testEscapeBackspaceAndArrowsLeaveAnExistingDraftInPlace() throws {
        try typeDraft()
        let keys: [(String, UInt16, NSEvent.ModifierFlags, String)] = [
            ("\u{1B}", 53, [], "Escape"),
            ("\u{7F}", 51, [], "Backspace"),
            ("\u{F702}", 123, [.function, .numericPad], "Left"),
        ]
        for (chars, code, flags, name) in keys {
            try press(chars, keyCode: code, flags: flags)
            XCTAssertTrue(surface.draftGate.isDrafting, "\(name) must not end the draft")
        }
    }

    func testTypingWhileAgentWaitsOnApprovalDoesNotStartADraft() throws {
        surface.noteAgentBlockedChange(isBlocked: true)
        try press("y", keyCode: 16)
        XCTAssertEqual(surface.draftGate, .answeringPrompt)
        surface.noteAgentBlockedChange(isBlocked: false)
        XCTAssertEqual(surface.draftGate, .open, "an approval answer leaves no draft behind")
    }

    func testCommittedTextOutsideKeyDownCountsAsTyping() {
        view.insertText("dictated", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(surface.draftGate.isDrafting, "IME, dictation and voice commits are the person's input")
        view.insertText("\r", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(surface.draftGate, .open)
    }
}
