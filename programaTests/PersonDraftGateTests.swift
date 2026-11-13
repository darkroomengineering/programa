import XCTest
import AppKit

#if canImport(Programa_DEV)
@testable import Programa_DEV
#elseif canImport(Programa)
@testable import Programa
#endif

/// The person-input gate keeps socket writes out of a pane while a person has unsent typed input
/// (INC-687) and while the agent in it waits on a permission or sign-in prompt (INC-695). A wrong
/// transition either mixes agent text into the person's line or answers their approval prompt
/// (false open), or blocks a pane nothing can release (false hold), so every cell of the table is
/// pinned.
final class PersonDraftGateTransitionTests: XCTestCase {
    private let t0: TimeInterval = 1_000
    private var draft: PersonDraft { PersonDraft(since: t0, lastKeyAt: t0) }
    private var drafting: PersonDraftGate { .drafting(draft) }
    private let allKinds: [ProgramStatusKind?] = [nil, .permission, .question, .auth]

    private func next(_ state: PersonDraftGate, _ event: PersonDraftEvent) -> PersonDraftGate {
        PersonDraftGate.next(state, event)
    }

    private func prompt(_ kind: ProgramStatusKind?, draft: PersonDraft? = nil) -> PersonDraftGate {
        .promptShowing(kind, since: t0, draft: draft)
    }

    // MARK: open

    func testOpenTypedStartsDraftAtKeystrokeTime() {
        XCTAssertEqual(next(.open, .typed(at: 42)), .drafting(PersonDraft(since: 42, lastKeyAt: 42)))
    }

    func testOpenAgentPromptShowsThePromptFromItsReportTime() {
        for kind in allKinds {
            XCTAssertEqual(next(.open, .agentPrompt(kind, at: 7)), .promptShowing(kind, since: 7, draft: nil), "kind \(String(describing: kind))")
        }
    }

    func testOpenStaysOpenForEveryOtherEvent() {
        for event: PersonDraftEvent in [.submitted, .cleared, .dismissed, .socketWriteDelivered, .agentPromptClosed, .expired] {
            XCTAssertEqual(next(.open, event), .open, "open + \(event)")
        }
    }

    // MARK: drafting

    func testDraftingTypedKeepsSinceAndMovesLastKey() {
        XCTAssertEqual(next(drafting, .typed(at: t0 + 10)), .drafting(PersonDraft(since: t0, lastKeyAt: t0 + 10)))
    }

    func testDraftingEndsOnSubmitClearAndExpiry() {
        for event: PersonDraftEvent in [.submitted, .cleared, .expired] {
            XCTAssertEqual(next(drafting, event), .open, "drafting + \(event)")
        }
    }

    /// Escape, a socket write that neither submits nor clears, and the agent leaving a prompt do
    /// not touch the person's line.
    func testDraftingIgnoresDismissDeliveredWriteAndPromptClosed() {
        for event: PersonDraftEvent in [.dismissed, .socketWriteDelivered, .agentPromptClosed] {
            XCTAssertEqual(next(drafting, event), drafting, "drafting + \(event)")
        }
    }

    func testAgentPromptOverADraftKeepsTheDraftUnderThePrompt() {
        for kind in allKinds {
            XCTAssertEqual(next(drafting, .agentPrompt(kind, at: t0 + 5)), .promptShowing(kind, since: t0 + 5, draft: draft),
                           "kind \(String(describing: kind))")
        }
    }

    // MARK: promptShowing

    /// The person's first key at a prompt answers it, so it lifts the refusal; a draft typed
    /// before the prompt is theirs again. This replaced #567's rule that keys typed at a prompt
    /// never draft (INC-695, intentional contract change).
    func testAnswerEventsLeaveThePromptForTheEarlierDraftOrOpen() {
        let answers: [PersonDraftEvent] = [
            .typed(at: t0 + 1), .submitted, .cleared, .dismissed, .socketWriteDelivered, .agentPromptClosed,
        ]
        for kind in allKinds {
            for event in answers {
                XCTAssertEqual(next(prompt(kind), event), .open, "promptShowing(\(String(describing: kind))) + \(event)")
                let submitsTheDraft = !PersonDraftGate.refusesWrites(kind) && (event == .submitted || event == .cleared)
                XCTAssertEqual(next(prompt(kind, draft: draft), event), submitsTheDraft ? .open : drafting,
                               "promptShowing(\(String(describing: kind)), draft) + \(event)")
            }
        }
    }

    /// At a question or kindless prompt the agent's input box is the prompt, so Return sends the
    /// draft and Ctrl+C/Ctrl+U clears it; nothing stays held. An approval box sits over the input
    /// box instead, so answering it leaves the draft in place.
    func testSubmittingAtAQuestionPromptEndsTheDraft() {
        for kind in [nil, ProgramStatusKind.question] {
            XCTAssertEqual(next(prompt(kind, draft: draft), .submitted), .open)
            XCTAssertEqual(next(prompt(kind, draft: draft), .cleared), .open)
        }
        XCTAssertEqual(next(prompt(.permission, draft: draft), .submitted), drafting)
        XCTAssertEqual(next(prompt(.auth, draft: draft), .cleared), drafting)
    }

    func testKeysAfterTheAnsweringKeyStartADraft() {
        let answered = next(prompt(.permission), .typed(at: t0 + 1))
        XCTAssertEqual(answered, .open)
        XCTAssertEqual(next(answered, .typed(at: t0 + 2)), .drafting(PersonDraft(since: t0 + 2, lastKeyAt: t0 + 2)))
    }

    func testExpiryDropsTheDraftButKeepsThePrompt() {
        for kind in allKinds {
            XCTAssertEqual(next(prompt(kind, draft: draft), .expired), prompt(kind), "kind \(String(describing: kind))")
            XCTAssertEqual(next(prompt(kind), .expired), prompt(kind), "kind \(String(describing: kind))")
        }
    }

    /// Finding 5 of the plan: under #567 an expired draft fell back to `open` and the prompt was
    /// forgotten, so the next socket write answered it.
    func testDraftExpiringWhileAPermissionPromptShowsStillRefuses() {
        let shown = next(drafting, .agentPrompt(.permission, at: t0 + 5))
        let expired = next(shown, .expired)
        XCTAssertEqual(expired, .promptShowing(.permission, since: t0 + 5, draft: nil))
        guard case .promptShowing(let kind, _, _, _) = expired else { return XCTFail("prompt lost on expiry: \(expired)") }
        XCTAssertTrue(PersonDraftGate.refusesWrites(kind))
    }

    /// Reporters repeat the same prompt every sample; restarting `since` would zero
    /// `prompt_age_ms` on every report.
    func testRepeatedSameKindPromptKeepsItsAgeAndDraft() {
        for kind in allKinds {
            XCTAssertEqual(next(prompt(kind), .agentPrompt(kind, at: t0 + 30)), prompt(kind), "kind \(String(describing: kind))")
            XCTAssertEqual(next(prompt(kind, draft: draft), .agentPrompt(kind, at: t0 + 30)), prompt(kind, draft: draft))
        }
    }

    func testPromptOfAnotherKindRestartsItsAgeAndKeepsTheDraft() {
        XCTAssertEqual(next(prompt(.question), .agentPrompt(.permission, at: t0 + 30)),
                       .promptShowing(.permission, since: t0 + 30, draft: nil))
        XCTAssertEqual(next(prompt(nil, draft: draft), .agentPrompt(.auth, at: t0 + 30)),
                       .promptShowing(.auth, since: t0 + 30, draft: draft))
    }

    /// Any client can report `question`; letting that replace a showing permission or sign-in
    /// prompt would let one extra socket call lift the refusal and approve the tool.
    func testNonRefusingKindNeverReplacesARefusingKind() {
        for kind in [ProgramStatusKind.permission, .auth] {
            for weaker in [ProgramStatusKind.question, nil] {
                XCTAssertEqual(next(prompt(kind, draft: draft), .agentPrompt(weaker, at: t0 + 30)),
                               prompt(kind, draft: draft), "\(kind) <- \(String(describing: weaker))")
            }
        }
        XCTAssertEqual(next(prompt(.permission), .agentPrompt(.auth, at: t0 + 30)),
                       .promptShowing(.auth, since: t0 + 30, draft: nil))
    }

    /// `report_agent_state blocked` carries no kind; re-reporting it must not lift a permission
    /// or sign-in refusal that a hook already armed.
    func testKindlessReportKeepsTheKnownKindAndAge() {
        for kind in [ProgramStatusKind.permission, .auth, .question] {
            XCTAssertEqual(next(prompt(kind, draft: draft), .agentPrompt(nil, at: t0 + 30)),
                           prompt(kind, draft: draft), "kind \(kind)")
        }
    }

    /// A second permission request in one turn re-arms after the person answered the first.
    func testPromptReportedAgainAfterAnAnswerRearms() {
        let answered = next(prompt(.permission), .typed(at: t0 + 1))
        XCTAssertEqual(next(answered, .agentPrompt(.permission, at: t0 + 2)), .promptShowing(.permission, since: t0 + 2, draft: nil))
    }

    // MARK: which kinds refuse

    /// Claude's idle prompt reads as a question and a kindless `blocked` is common, so only an
    /// explicit permission or sign-in prompt refuses; refusing more would break `prompt-agent`.
    func testOnlyPermissionAndAuthRefuseWrites() {
        XCTAssertTrue(PersonDraftGate.refusesWrites(.permission))
        XCTAssertTrue(PersonDraftGate.refusesWrites(.auth))
        XCTAssertFalse(PersonDraftGate.refusesWrites(.question))
        XCTAssertFalse(PersonDraftGate.refusesWrites(nil))
    }

    // MARK: draft accessors

    func testDraftUnderAPromptStillHoldsAndCountsAsDrafting() {
        let state = prompt(.permission, draft: draft)
        XCTAssertEqual(state.draft, draft)
        XCTAssertTrue(state.isDrafting)
        XCTAssertTrue(state.isHolding(now: t0 + 1))
        XCTAssertFalse(prompt(.permission).isDrafting)
        XCTAssertFalse(prompt(.permission).isHolding(now: t0))
        XCTAssertNil(PersonDraftGate.open.draft)
    }

    // MARK: expiry

    func testHoldsUntilExactlySixtySecondsAfterLastKeystroke() {
        let state = PersonDraftGate.drafting(PersonDraft(since: t0 - 30, lastKeyAt: t0))
        XCTAssertEqual(PersonDraftGate.idleExpiry, 60)
        XCTAssertTrue(state.isHolding(now: t0))
        XCTAssertTrue(state.isHolding(now: t0 + 59.999))
        XCTAssertFalse(state.isHolding(now: t0 + 60), "a draft left alone for 60 s must stop holding")
        XCTAssertFalse(state.isHolding(now: t0 + 600))
    }

    func testOpenNeverHolds() {
        XCTAssertFalse(PersonDraftGate.open.isHolding(now: t0))
    }

    func testKeystrokeAfterExpiredDraftRestartsSince() {
        let stale = PersonDraftGate.drafting(PersonDraft(since: t0 - 100, lastKeyAt: t0))
        XCTAssertEqual(next(stale, .typed(at: t0 + 60)), .drafting(PersonDraft(since: t0 + 60, lastKeyAt: t0 + 60)))
        XCTAssertEqual(next(stale, .typed(at: t0 + 59.999)), .drafting(PersonDraft(since: t0 - 100, lastKeyAt: t0 + 59.999)))
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

    /// Separate from the typing hold: turning one off must not turn the other off.
    func testApprovalProtectionIsOnUnlessTurnedOffAndIndependentOfTheTypingHold() throws {
        let suite = "PersonDraftGateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(ApprovalGuardSettings.enabledKey, "protectApprovalPrompts")
        XCTAssertTrue(ApprovalGuardSettings.isEnabled(defaults: defaults), "unset must mean protected")
        defaults.set(false, forKey: DraftGuardSettings.enabledKey)
        XCTAssertTrue(ApprovalGuardSettings.isEnabled(defaults: defaults), "the typing hold switch must not lift approvals")
        defaults.set(false, forKey: ApprovalGuardSettings.enabledKey)
        XCTAssertFalse(ApprovalGuardSettings.isEnabled(defaults: defaults))
        defaults.set(true, forKey: DraftGuardSettings.enabledKey)
        XCTAssertFalse(ApprovalGuardSettings.isEnabled(defaults: defaults))
        defaults.set(true, forKey: ApprovalGuardSettings.enabledKey)
        XCTAssertTrue(ApprovalGuardSettings.isEnabled(defaults: defaults))
    }
}

/// Restores one `UserDefaults.standard` key, since the socket guards read the standard domain.
@MainActor
private func withStandardDefault(_ key: String, _ value: Bool, _ body: () throws -> Void) rethrows {
    let defaults = UserDefaults.standard
    let previous = defaults.object(forKey: key)
    defer {
        if let previous { defaults.set(previous, forKey: key) }
        else { defaults.removeObject(forKey: key) }
    }
    defaults.set(value, forKey: key)
    try body()
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

    func testDraftUnderAPromptStillHoldsUntilItExpires() throws {
        let surface = makeSurface()
        surface.noteDraftEvent(.typed(at: 100))
        surface.noteAgentPrompt(.permission, isBlocked: true, now: 105)

        XCTAssertEqual(try XCTUnwrap(surface.activeDraftHold(now: 110)).ageMs, 10_000)
        XCTAssertNil(surface.activeDraftHold(now: 160))
        XCTAssertEqual(surface.draftGate, .promptShowing(.permission, since: 105, draft: nil),
                       "the draft expiring must not forget the prompt over it")
        XCTAssertNotNil(surface.activePromptHold(now: 160), "an approval prompt still refuses after the draft expired")
    }

    func testPromptReportExpiresAStaleDraftFirst() {
        let surface = makeSurface()
        surface.noteDraftEvent(.typed(at: 100))
        surface.noteAgentPrompt(.permission, isBlocked: true, now: 105)
        XCTAssertTrue(surface.draftGate.isDrafting, "a live draft survives an approval prompt")

        surface.noteAgentPrompt(.permission, isBlocked: true, now: 200)
        XCTAssertEqual(surface.draftGate, .promptShowing(.permission, since: 105, draft: nil),
                       "a stale draft must not come back once the prompt closes")
        surface.noteAgentPrompt(nil, isBlocked: false, now: 201)
        XCTAssertEqual(surface.draftGate, .open)
    }

    func testPromptHoldOnlyForPermissionAndAuthWithAgeFromFirstReport() throws {
        let surface = makeSurface()
        for kind: ProgramStatusKind? in [.question, nil] {
            surface.noteAgentPrompt(kind, isBlocked: true, now: 100)
            XCTAssertNil(surface.activePromptHold(now: 101), "kind \(String(describing: kind)) must not refuse writes")
            surface.noteAgentPrompt(nil, isBlocked: false, now: 101)
        }
        for kind: ProgramStatusKind in [.permission, .auth] {
            surface.noteAgentPrompt(kind, isBlocked: true, now: 100)
            surface.noteAgentPrompt(kind, isBlocked: true, now: 104)
            XCTAssertEqual(surface.activePromptHold(now: 107), PersonPromptHold(kind: kind, ageMs: 7_000),
                           "a repeated report must keep the prompt's age")
            surface.noteAgentPrompt(nil, isBlocked: false, now: 108)
            XCTAssertNil(surface.activePromptHold(now: 108))
        }
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

        withStandardDefault(DraftGuardSettings.enabledKey, false) {
            XCTAssertNil(TerminalController.shared.v2DraftGuardRejection(params: [:], surfaceId: UUID(), terminalPanel: panel))
            XCTAssertTrue(surface.draftGate.isDrafting, "tracking keeps running while the hold is off")

            UserDefaults.standard.set(true, forKey: DraftGuardSettings.enabledKey)
            XCTAssertNotNil(TerminalController.shared.v2DraftGuardRejection(params: [:], surfaceId: UUID(), terminalPanel: panel),
                            "turning the hold back on mid-draft protects that draft")
        }
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

    /// A delivered write (only possible with `answer_prompt`) answers the prompt. An Enter that
    /// answers it leaves the draft typed before the prompt in place.
    func testDeliveredWriteAnswersThePromptAndKeepsAnEarlierDraft() {
        let surface = makeSurface()
        let panel = TerminalPanel(workspaceId: UUID(), surface: surface)
        let now = ProcessInfo.processInfo.systemUptime

        surface.noteAgentPrompt(.permission, isBlocked: true, now: now)
        TerminalController.shared.v2NoteSocketSubmit(text: "1", terminalPanel: panel)
        XCTAssertEqual(surface.draftGate, .open, "a plain answer key lifts the refusal")

        surface.noteDraftEvent(.typed(at: now))
        surface.noteAgentPrompt(.permission, isBlocked: true, now: now)
        TerminalController.shared.v2NoteSocketSubmit(text: "", keys: ["enter"], terminalPanel: panel)
        XCTAssertNil(surface.activePromptHold(now: now))
        XCTAssertTrue(surface.draftGate.isDrafting, "the person's earlier draft is still theirs")
    }
}

/// The socket write guard read through a real workspace, so the prompt kind travels the same
/// path an agent-state report takes (`Workspace.updatePanelAgentState`).
@MainActor
final class ApprovalPromptGuardTests: XCTestCase {
    private var workspace: Workspace!
    private var surfaceId: UUID!
    private var panel: TerminalPanel!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workspace = Workspace()
        surfaceId = try XCTUnwrap(workspace.focusedPanelId)
        panel = try XCTUnwrap(workspace.panels[surfaceId] as? TerminalPanel)
    }

    override func tearDown() {
        workspace?.teardownAllPanels()
        workspace = nil
        panel = nil
        surfaceId = nil
        super.tearDown()
    }

    private func block(_ kind: ProgramStatusKind?) {
        workspace.updatePanelAgentState(panelId: surfaceId, state: .blocked, source: .hooks, promptKind: kind)
    }

    private func rejection(_ params: [String: Any] = [:]) -> TerminalController.V2CallResult? {
        TerminalController.shared.v2SocketWriteRejection(params: params, surfaceId: surfaceId, terminalPanel: panel, workspace: workspace)
    }

    private func code(_ result: TerminalController.V2CallResult?) -> String? {
        guard case .err(let code, _, _)? = result else { return nil }
        return code
    }

    func testPermissionPromptRefusesWithApprovalData() throws {
        block(.permission)

        guard case .err(let code, let message, let data)? = rejection() else {
            return XCTFail("Expected agent_awaiting_approval, got \(String(describing: rejection()))")
        }
        XCTAssertEqual(code, "agent_awaiting_approval")
        let fields = try XCTUnwrap(data as? [String: Any])
        let surfaceRef = try XCTUnwrap(fields["surface_ref"] as? String)
        XCTAssertTrue(surfaceRef.hasPrefix("surface:"), "\(fields)")
        XCTAssertEqual(message, "\(surfaceRef) is waiting on an approval prompt; nothing was sent")
        XCTAssertEqual(fields["surface_id"] as? String, surfaceId.uuidString)
        XCTAssertEqual(fields["prompt_kind"] as? String, "permission")
        let age = try XCTUnwrap(fields["prompt_age_ms"] as? Int)
        XCTAssertTrue((0..<60_000).contains(age), "prompt_age_ms=\(age)")
        XCTAssertEqual(fields["agent_state_source"] as? String, "hooks")
        XCTAssertEqual(fields["stale"] as? Bool, false)
    }

    func testStalePresenceIsReportedSoCallersCanJudgeTheRefusal() throws {
        block(.auth)
        workspace.panelAgentPresence[surfaceId]?.lastEventAt = Date().addingTimeInterval(-AgentPresence.staleThreshold - 60)

        guard case .err(_, _, let data)? = rejection() else { return XCTFail("auth prompt must refuse") }
        let fields = try XCTUnwrap(data as? [String: Any])
        XCTAssertEqual(fields["prompt_kind"] as? String, "auth")
        XCTAssertEqual(fields["stale"] as? Bool, true)
    }

    /// `workspace.reset_sidebar` is a cleanup call any client can make; it must not double as a
    /// way to lift a refusal, including for program-owned prompts nothing else can close.
    func testSidebarResetKeepsAPermissionRefusal() {
        block(.permission)
        workspace.resetSidebarContext(reason: "test")
        XCTAssertEqual(code(rejection()), "agent_awaiting_approval")
        XCTAssertNil(rejection(["answer_prompt": true]))
    }

    func testQuestionAndKindlessPromptsDoNotRefuse() {
        block(.question)
        XCTAssertNil(rejection(), "Claude's idle prompt reads as a question; prompt-agent must still reach it")
        workspace.updatePanelAgentState(panelId: surfaceId, state: .working, source: .hooks)
        block(nil)
        XCTAssertNil(rejection(), "a blocked report without a kind must not refuse")
    }

    /// `force` is for a person's draft only; scripts that pass it must not start approving.
    func testForceAloneDoesNotAnswerAPrompt() {
        block(.permission)
        XCTAssertEqual(code(rejection(["force": true])), "agent_awaiting_approval")
        XCTAssertNil(rejection(["answer_prompt": true]))
    }

    /// Approval is checked before the draft, and a write that meets both needs both flags.
    func testPromptOverADraftNeedsBothFlags() {
        panel.surface.noteDraftEvent(.typed(at: ProcessInfo.processInfo.systemUptime))
        block(.permission)

        XCTAssertEqual(code(rejection()), "agent_awaiting_approval")
        XCTAssertEqual(code(rejection(["force": true])), "agent_awaiting_approval")
        XCTAssertEqual(code(rejection(["answer_prompt": true])), "draft_in_progress")
        XCTAssertNil(rejection(["answer_prompt": true, "force": true]))
    }

    func testKillSwitchLiftsTheRefusalButTrackingContinues() {
        block(.permission)
        withStandardDefault(ApprovalGuardSettings.enabledKey, false) {
            XCTAssertNil(rejection())
            XCTAssertNotNil(panel.surface.activePromptHold(), "prompt tracking keeps running while protection is off")

            UserDefaults.standard.set(true, forKey: ApprovalGuardSettings.enabledKey)
            XCTAssertEqual(code(rejection()), "agent_awaiting_approval", "turning protection back on covers a prompt already showing")
        }
    }

    func testApprovalKillSwitchLeavesTheDraftHoldInPlace() {
        panel.surface.noteDraftEvent(.typed(at: ProcessInfo.processInfo.systemUptime))
        block(.permission)
        withStandardDefault(ApprovalGuardSettings.enabledKey, false) {
            XCTAssertEqual(code(rejection()), "draft_in_progress")
        }
    }

    func testLeavingBlockedOrClearingTheStateReopens() {
        block(.permission)
        workspace.updatePanelAgentState(panelId: surfaceId, state: .working, source: .hooks)
        XCTAssertNil(rejection(), "the agent leaving blocked ends the prompt")

        block(.permission)
        workspace.clearPanelAgentState(panelId: surfaceId)
        XCTAssertNil(rejection(), "surface.clear_agent_state and the pid sweep end the prompt")
    }

    /// A person's key answers the prompt; the agent's next permission request (the same
    /// `blocked` state reported again) must refuse again.
    func testRepeatedBlockedReportRearmsAfterAPersonAnswered() {
        block(.permission)
        panel.surface.noteDraftEvent(.typed(at: ProcessInfo.processInfo.systemUptime))
        XCTAssertNil(rejection(), "the person's key answered the prompt")

        block(.permission)
        XCTAssertEqual(code(rejection()), "agent_awaiting_approval")
    }

    func testQuestionTurningIntoAPermissionPromptRefuses() {
        block(.question)
        XCTAssertNil(rejection())
        block(.permission)
        XCTAssertEqual(code(rejection()), "agent_awaiting_approval")
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

    /// The person's first key at an approval prompt answers it, so socket writes are no longer
    /// refused; keys after it are a draft again (INC-695, replacing #567's "keys typed at a
    /// prompt never draft").
    func testFirstKeyAtApprovalPromptLiftsTheRefusalAndLaterKeysDraft() throws {
        surface.noteAgentPrompt(.permission, isBlocked: true)
        XCTAssertNotNil(surface.activePromptHold())
        try press("y", keyCode: 16)
        XCTAssertNil(surface.activePromptHold(), "the person answered the prompt")
        XCTAssertEqual(surface.draftGate, .open, "the answering key is not a draft")
        try press("a", keyCode: 0)
        XCTAssertTrue(surface.draftGate.isDrafting, "keys after the answer are the person's draft")
    }

    /// Escape denies Claude's and Codex's prompts. It reaches the gate as `.dismissed` only from
    /// keyDown, so this is the one place its wiring is covered.
    func testEscapeAtApprovalPromptLiftsTheRefusal() throws {
        surface.noteAgentPrompt(.permission, isBlocked: true)
        try press("\u{1B}", keyCode: 53)
        XCTAssertNil(surface.activePromptHold(), "Escape answered (denied) the prompt")
        XCTAssertEqual(surface.draftGate, .open)
    }

    func testReturnAtApprovalPromptLiftsTheRefusal() throws {
        surface.noteAgentPrompt(.auth, isBlocked: true)
        try press("\r", keyCode: 36)
        XCTAssertNil(surface.activePromptHold())
        XCTAssertEqual(surface.draftGate, .open)
    }

    func testAnsweringKeyKeepsADraftTypedBeforeThePrompt() throws {
        try typeDraft()
        surface.noteAgentPrompt(.permission, isBlocked: true)
        try press("1", keyCode: 18)
        XCTAssertNil(surface.activePromptHold())
        XCTAssertTrue(surface.draftGate.isDrafting, "the draft typed before the prompt is still the person's")
    }

    func testCommittedTextOutsideKeyDownCountsAsTyping() {
        view.insertText("dictated", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(surface.draftGate.isDrafting, "IME, dictation and voice commits are the person's input")
        view.insertText("\r", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(surface.draftGate, .open)
    }
}
