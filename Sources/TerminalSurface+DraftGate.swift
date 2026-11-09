import Foundation
import Bonsplit

// Keeps socket writes (`surface.send_*`, `agent.prompt`, `programa handoff`) out of a terminal
// while a person has typed input there that they have not submitted (INC-687).
//
// Only person input moves the gate: keyDown, paste, IME/dictation commits and drag-drop in
// `GhosttyNSView`. Terminal replies (DA1, DSR, OSC 11, focus reports) and socket writes reach
// the PTY without passing through those sites, so they can never look like typing.

/// Whether a person has unsent typed input in one terminal surface.
enum PersonDraftGate: Equatable {
    /// No unsent person input.
    case open
    /// The agent is blocked on an approval prompt: keys typed now answer it, not start a draft.
    case answeringPrompt
    /// Times are `systemUptime` seconds, the clock `NSEvent.timestamp` uses.
    case drafting(since: TimeInterval, lastKeyAt: TimeInterval)

    /// A draft left alone this long stops holding writes. Without it, text typed and then
    /// erased with Backspace (DEL is not counted as typing) would hold the pane forever.
    static let idleExpiry: TimeInterval = 60

    static func next(_ state: PersonDraftGate, _ event: PersonDraftEvent) -> PersonDraftGate {
        switch state {
        case .open:
            switch event {
            case .typed(let at): return .drafting(since: at, lastKeyAt: at)
            case .agentBlocked: return .answeringPrompt
            case .submitted, .cleared, .agentUnblocked, .forcedSubmitDelivered, .expired: return .open
            }
        case .answeringPrompt:
            if case .agentUnblocked = event { return .open }
            return .answeringPrompt
        case .drafting(let since, let lastKeyAt):
            switch event {
            case .typed(let at):
                // A keystroke after an expired draft starts a new one.
                return .drafting(since: at - lastKeyAt >= idleExpiry ? at : since, lastKeyAt: at)
            case .submitted, .cleared, .forcedSubmitDelivered, .expired:
                return .open
            case .agentBlocked, .agentUnblocked:
                // A draft typed before an approval prompt is still the person's text.
                return state
            }
        }
    }

    /// True while a draft holds socket writes at `now`.
    func isHolding(now: TimeInterval) -> Bool {
        guard case .drafting(_, let lastKeyAt) = self else { return false }
        return now - lastKeyAt < Self.idleExpiry
    }

    var isDrafting: Bool {
        if case .drafting = self { return true }
        return false
    }

    fileprivate func isSameCase(as other: PersonDraftGate) -> Bool {
        switch (self, other) {
        case (.open, .open), (.answeringPrompt, .answeringPrompt), (.drafting, .drafting): return true
        default: return false
        }
    }

    fileprivate var caseName: String {
        switch self {
        case .open: return "open"
        case .answeringPrompt: return "answeringPrompt"
        case .drafting: return "drafting"
        }
    }
}

enum PersonDraftEvent: Equatable {
    case typed(at: TimeInterval)
    case submitted
    case cleared
    case agentBlocked
    case agentUnblocked
    /// A forced socket write that contained a submit (CR/LF, or the Enter key) went through,
    /// so the person's draft was submitted with it.
    case forcedSubmitDelivered
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

/// A draft that is holding writes, as reported in the `draft_in_progress` error.
struct PersonDraftHold: Equatable {
    let ageMs: Int
    let expiresInMs: Int
}

extension TerminalSurface {
    /// The draft holding socket writes at `now`, or nil. Moves an idle draft to `.open` first,
    /// in the caller's main hop, so the check and the write that follows see one state.
    func activeDraftHold(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> PersonDraftHold? {
        expireIdleDraft(now: now)
        guard case .drafting(let since, let lastKeyAt) = draftGate else { return nil }
        return PersonDraftHold(
            ageMs: max(0, Int(((now - since) * 1000).rounded())),
            expiresInMs: max(0, Int(((lastKeyAt + PersonDraftGate.idleExpiry - now) * 1000).rounded()))
        )
    }

    /// Agent-state hook: the agent started or stopped waiting on an approval prompt.
    func noteAgentBlockedChange(isBlocked: Bool, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        expireIdleDraft(now: now)
        noteDraftEvent(isBlocked ? .agentBlocked : .agentUnblocked)
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
