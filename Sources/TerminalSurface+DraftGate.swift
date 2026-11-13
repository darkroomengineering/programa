import Foundation
import Bonsplit

// Keeps socket writes (`surface.send_*`, `agent.prompt`, `programa handoff`) out of a terminal
// while a person has typed input there that they have not submitted (INC-687), and while the
// agent in it waits on a permission or sign-in prompt the person has not answered (INC-695).
//
// Only person input moves the draft side of the gate: keyDown, paste, IME/dictation commits and
// drag-drop in `GhosttyNSView`. Terminal replies (DA1, DSR, OSC 11, focus reports) and socket
// writes reach the PTY without passing through those sites, so they can never look like typing.
// The prompt side moves on agent-state reports (`Workspace.updatePanelAgentState`): any report
// can arm it, and only a report printed bytes could not have forged can close it.

/// Unsent person input. Times are `systemUptime` seconds, the clock `NSEvent.timestamp` uses.
struct PersonDraft: Equatable {
    var since: TimeInterval
    var lastKeyAt: TimeInterval

    /// True while this draft holds socket writes at `now`.
    func isHolding(now: TimeInterval) -> Bool {
        now - lastKeyAt < PersonDraftGate.idleExpiry
    }
}

/// Who reported a prompt. Screen detection reads printed text, so it may end only a prompt that
/// nothing but screen detection reported (`Workspace.closePromptGate`).
enum PromptReporter: Equatable {
    case screen
    /// Hooks over the socket, or an OSC 7501 report, signed or not.
    case agent
}

/// Whether a person has unsent typed input in one terminal surface, and whether the agent in it
/// is showing a prompt the person has not answered yet.
enum PersonDraftGate: Equatable {
    /// No unsent person input and no open prompt.
    case open
    case drafting(PersonDraft)
    /// The agent reported a prompt (nil kind: the reporter did not say which). `since` is
    /// `systemUptime` seconds. `draft` is input the person typed before the prompt appeared;
    /// it is still theirs once the prompt closes. `reportedBy` is `.screen` only while screen
    /// detection is the one reporter that has reported it.
    case promptShowing(ProgramStatusKind?, since: TimeInterval, draft: PersonDraft?, reportedBy: PromptReporter = .agent)

    /// A draft left alone this long stops holding writes. Without it, text typed and then
    /// erased with Backspace (DEL is not counted as typing) would hold the pane forever.
    static let idleExpiry: TimeInterval = 60

    /// Kinds whose prompt refuses socket writes. A question, or a prompt of unknown kind, does
    /// not: Claude's idle prompt reads as a question, and refusing it would break `prompt-agent`.
    static func refusesWrites(_ kind: ProgramStatusKind?) -> Bool {
        kind == .permission || kind == .auth
    }

    static func next(_ state: PersonDraftGate, _ event: PersonDraftEvent) -> PersonDraftGate {
        switch state {
        case .open:
            switch event {
            case .typed(let at): return .drafting(PersonDraft(since: at, lastKeyAt: at))
            case .agentPrompt(let kind, let at, let by): return .promptShowing(kind, since: at, draft: nil, reportedBy: by)
            case .submitted, .cleared, .dismissed, .socketWriteDelivered, .agentPromptClosed, .expired: return .open
            }
        case .drafting(let draft):
            switch event {
            case .typed(let at):
                // A keystroke after an expired draft starts a new one.
                let since = at - draft.lastKeyAt >= idleExpiry ? at : draft.since
                return .drafting(PersonDraft(since: since, lastKeyAt: at))
            case .submitted, .cleared, .expired:
                return .open
            case .agentPrompt(let kind, let at, let by):
                return .promptShowing(kind, since: at, draft: draft, reportedBy: by)
            case .dismissed, .socketWriteDelivered, .agentPromptClosed:
                return state
            }
        case .promptShowing(let kind, let since, let draft, let reporter):
            switch event {
            case .submitted where !refusesWrites(kind), .cleared where !refusesWrites(kind):
                // At a question or kindless prompt the input box is the prompt, so Return sends
                // the draft and Ctrl+C/Ctrl+U clears it.
                return .open
            case .typed, .submitted, .cleared, .dismissed, .socketWriteDelivered, .agentPromptClosed:
                // The person's first key (or a delivered write) answers an approval box drawn over
                // the input box; a draft typed before it is still theirs.
                return draft.map { .drafting($0) } ?? .open
            case .expired:
                return .promptShowing(kind, since: since, draft: nil, reportedBy: reporter)
            case .agentPrompt(let newKind, let at, let by):
                // Reporters repeat the same prompt; keep its age unless the kind changed. Any
                // client can report `blocked` or `question`, so a kind that refuses writes is
                // never replaced by one that doesn't; only an answer or a close ends it.
                let resolved = PersonDraftGate.refusesWrites(kind) ? (newKind.flatMap { PersonDraftGate.refusesWrites($0) ? $0 : nil } ?? kind) : (newKind ?? kind)
                // Once an agent reported the prompt, screen detection re-reporting it never
                // lets screen detection end it.
                return .promptShowing(
                    resolved, since: resolved == kind ? since : at, draft: draft,
                    reportedBy: reporter == .screen ? by : .agent
                )
            }
        }
    }

    /// The person's unsent draft, whether or not a prompt shows over it.
    var draft: PersonDraft? {
        switch self {
        case .open: return nil
        case .drafting(let draft): return draft
        case .promptShowing(_, _, let draft, _): return draft
        }
    }

    /// True while a draft holds socket writes at `now`.
    func isHolding(now: TimeInterval) -> Bool {
        draft?.isHolding(now: now) ?? false
    }

    var isDrafting: Bool { draft != nil }

    fileprivate func isSameCase(as other: PersonDraftGate) -> Bool {
        switch (self, other) {
        case (.open, .open), (.drafting, .drafting): return true
        case (.promptShowing(let kind, _, let draft, _), .promptShowing(let otherKind, _, let otherDraft, _)):
            return kind == otherKind && (draft == nil) == (otherDraft == nil)
        default: return false
        }
    }

    fileprivate var caseName: String {
        switch self {
        case .open: return "open"
        case .drafting: return "drafting"
        case .promptShowing(let kind, _, let draft, _):
            return "promptShowing(\(kind?.rawValue ?? "unknown")\(draft == nil ? "" : ",draft"))"
        }
    }
}

enum PersonDraftEvent: Equatable {
    case typed(at: TimeInterval)
    /// The person pressed Return, or a delivered socket write contained a submit (CR/LF, or
    /// the Enter key).
    case submitted
    case cleared
    /// The person pressed Escape.
    case dismissed
    /// Any socket write went through. Posted after `submitted`/`cleared` for the same write.
    case socketWriteDelivered
    /// The agent reported a prompt (`blocked`). `at` is `systemUptime` seconds.
    case agentPrompt(ProgramStatusKind?, at: TimeInterval, by: PromptReporter = .agent)
    /// A trusted report shows the agent no longer `blocked`, a trusted clear removed its state, or
    /// the shell reported its prompt with nothing `blocked`.
    case agentPromptClosed
    /// The draft went `PersonDraftGate.idleExpiry` seconds without a keystroke.
    case expired
}

/// Kill switch for the hold (`automation.holdAgentTextWhileTyping`). Tracking keeps running
/// while it is off, so turning it back on mid-draft protects that draft.
enum DraftGuardSettings {
    static let enabledKey = "holdAgentTextWhileTyping"
    static let defaultEnabled = true
    private static let flag = UserDefaultsFlag(key: enabledKey, defaultValue: defaultEnabled)

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        flag.isEnabled(defaults: defaults)
    }
}

/// Kill switch for the approval refusal (`automation.protectApprovalPrompts`). Prompt tracking
/// keeps running while it is off, so turning it back on protects a prompt already showing.
enum ApprovalGuardSettings {
    static let enabledKey = "protectApprovalPrompts"
    static let defaultEnabled = true
    private static let flag = UserDefaultsFlag(key: enabledKey, defaultValue: defaultEnabled)

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        flag.isEnabled(defaults: defaults)
    }
}

/// A draft that is holding writes, as reported in the `draft_in_progress` error.
struct PersonDraftHold: Equatable {
    let ageMs: Int
    let expiresInMs: Int
}

/// A prompt that is refusing writes, as reported in the `agent_awaiting_approval` error.
struct PersonPromptHold: Equatable {
    let kind: ProgramStatusKind
    let ageMs: Int
}

extension TerminalSurface {
    /// The draft holding socket writes at `now`, or nil. Drops an idle draft first, in the
    /// caller's main hop, so the check and the write that follows see one state.
    func activeDraftHold(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> PersonDraftHold? {
        expireIdleDraft(now: now)
        guard let draft = draftGate.draft else { return nil }
        return PersonDraftHold(
            ageMs: max(0, Int(((now - draft.since) * 1000).rounded())),
            expiresInMs: max(0, Int(((draft.lastKeyAt + PersonDraftGate.idleExpiry - now) * 1000).rounded()))
        )
    }

    /// The permission or sign-in prompt refusing socket writes at `now`, or nil.
    func activePromptHold(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> PersonPromptHold? {
        guard case .promptShowing(let kind?, let since, _, _) = draftGate,
              PersonDraftGate.refusesWrites(kind) else { return nil }
        return PersonPromptHold(kind: kind, ageMs: max(0, Int(((now - since) * 1000).rounded())))
    }

    /// True while the agent's prompt of any kind shows and the person has not answered it. It can
    /// outlast a badge that left `blocked`: printed bytes move the badge but never close the gate.
    var isPromptShowing: Bool { promptReporter != nil }

    /// Who reported the showing prompt, nil while none shows.
    var promptReporter: PromptReporter? {
        guard case .promptShowing(_, _, _, let reporter) = draftGate else { return nil }
        return reporter
    }

    /// Agent-state hook: the agent reported a prompt of `kind` (every `blocked` report, so a
    /// repeated report re-arms a prompt the person already answered), or stopped waiting on one.
    func noteAgentPrompt(
        _ kind: ProgramStatusKind?,
        isBlocked: Bool,
        by reporter: PromptReporter = .agent,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        expireIdleDraft(now: now)
        noteDraftEvent(isBlocked ? .agentPrompt(kind, at: now, by: reporter) : .agentPromptClosed)
    }

    private func expireIdleDraft(now: TimeInterval) {
        if draftGate.isDrafting, !draftGate.isHolding(now: now) {
            noteDraftEvent(.expired)
        }
    }

#if DEBUG
    func logDraftGateTransition(from old: PersonDraftGate, to new: PersonDraftGate, event: PersonDraftEvent) {
        guard !old.isSameCase(as: new) else { return }
        dlog("draft.gate surface=\(id.uuidString.prefix(5)) from=\(old.caseName) to=\(new.caseName) event=\(event)")
    }
#endif
}
