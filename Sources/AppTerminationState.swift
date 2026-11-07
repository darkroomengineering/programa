import Foundation

enum AppTerminationState {
    enum QuitAuthorization {
        case required
        case confirmed
    }

    case running
    case quitAuthorized
    case quitRequested(UUID)
    case confirmedQuit
    case awaitingPowerOff(UUID?, QuitAuthorization)
    case updateRelaunch
    case terminating(QuitAuthorization)

    var isTerminating: Bool {
        switch self {
        case .running, .quitAuthorized: return false
        default: return true
        }
    }

    var isAwaitingPowerOff: Bool {
        if case .awaitingPowerOff = self { return true }
        return false
    }

    var isQuitWarningConfirmed: Bool {
        switch self {
        case .quitAuthorized, .confirmedQuit, .updateRelaunch: return true
        case .awaitingPowerOff(_, .confirmed), .terminating(.confirmed): return true
        default: return false
        }
    }

    var quitRequestToken: UUID? {
        switch self {
        case .quitRequested(let token), .awaitingPowerOff(.some(let token), _): return token
        default: return nil
        }
    }

    var authorization: QuitAuthorization { isQuitWarningConfirmed ? .confirmed : .required }

    mutating func beginTermination() {
        if isAwaitingPowerOff {
            self = .awaitingPowerOff(UUID(), authorization)
        } else {
            self = isQuitWarningConfirmed ? .confirmedQuit : .quitRequested(UUID())
        }
    }

    mutating func confirmQuit() {
        if case .awaitingPowerOff(let token, _) = self {
            self = .awaitingPowerOff(token, .confirmed)
        } else {
            self = isTerminating ? .confirmedQuit : .quitAuthorized
        }
    }

    mutating func settle() {
        self = isQuitWarningConfirmed ? .quitAuthorized : .running
    }
}
