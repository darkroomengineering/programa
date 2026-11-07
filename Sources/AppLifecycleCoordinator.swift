import AppKit
import Foundation
import UserNotifications

@MainActor
final class AppLifecycleCoordinator {
    struct TerminationDecision: Equatable {
        let shouldWarn: Bool
        let logReason: String
    }

    private enum TerminationState {
        case running
        case quitAuthorized
        case quitRequested(UUID)
        case confirmedQuit
        case awaitingPowerOff(UUID?, QuitAuthorization)
        case updateRelaunch
        case terminating(QuitAuthorization)
    }

    private enum QuitAuthorization {
        case required
        case confirmed
    }

    private var terminationState: TerminationState = .running {
        didSet { transitionToken = UUID() }
    }
    private(set) var transitionToken = UUID()
    var isTerminating: Bool {
        switch terminationState {
        case .running, .quitAuthorized: return false
        default: return true
        }
    }
    var isAwaitingPowerOff: Bool {
        if case .awaitingPowerOff = terminationState { return true }
        return false
    }
    var isQuitWarningConfirmed: Bool {
        switch terminationState {
        case .quitAuthorized, .confirmedQuit, .updateRelaunch: return true
        case .awaitingPowerOff(_, .confirmed), .terminating(.confirmed): return true
        default: return false
        }
    }
    var quitRequestToken: UUID? {
        switch terminationState {
        case .quitRequested(let token), .awaitingPowerOff(.some(let token), _): return token
        default: return nil
        }
    }
    private var didInstallSnapshotObservers = false
    private var didDisableSuddenTermination = false

    func beginTermination(
        isTaggedDevBuild: Bool,
        isQuitWarningEnabled: Bool
    ) -> TerminationDecision {
        let shouldWarn = AppDelegate.shouldWarnBeforeTermination(
            isTaggedDevBuild: isTaggedDevBuild,
            isQuitWarningConfirmed: isQuitWarningConfirmed,
            isQuitWarningEnabled: isQuitWarningEnabled
        )
        if isAwaitingPowerOff {
            terminationState = .awaitingPowerOff(UUID(), isQuitWarningConfirmed ? .confirmed : .required)
        } else {
            terminationState = isQuitWarningConfirmed ? .confirmedQuit : .quitRequested(UUID())
        }
        return TerminationDecision(shouldWarn: shouldWarn, logReason: "warning_bypassed")
    }

    func confirmQuit() {
        if case .awaitingPowerOff(let token, _) = terminationState {
            terminationState = .awaitingPowerOff(token, .confirmed)
        } else {
            terminationState = isTerminating ? .confirmedQuit : .quitAuthorized
        }
    }

    func cancelTermination() {
        terminationState = isQuitWarningConfirmed ? .quitAuthorized : .running
    }

    func beginPowerOff() {
        terminationState = .awaitingPowerOff(nil, isQuitWarningConfirmed ? .confirmed : .required)
    }

    @discardableResult
    func resumeAfterCancelledPowerOff() -> Bool {
        guard isAwaitingPowerOff else { return false }
        terminationState = isQuitWarningConfirmed ? .quitAuthorized : .running
        return true
    }

    func willTerminate() {
        terminationState = .terminating(isQuitWarningConfirmed ? .confirmed : .required)
    }

    func beginUpdateRelaunch() {
        terminationState = .updateRelaunch
    }

    func claimSnapshotObserverInstallation() -> Bool {
        guard !didInstallSnapshotObservers else { return false }
        didInstallSnapshotObservers = true
        return true
    }

    func claimSuddenTerminationDisable() -> Bool {
        guard !didDisableSuddenTermination else { return false }
        didDisableSuddenTermination = true
        return true
    }

    func claimSuddenTerminationEnable() -> Bool {
        guard didDisableSuddenTermination else { return false }
        didDisableSuddenTermination = false
        return true
    }
}

struct AppNotificationRouter {
    enum Route: Equatable {
        case activateApplication
        case open(tabId: UUID, surfaceId: UUID?, notificationId: UUID?)
        case markRead(notificationId: UUID)
        case ignore
    }

    static func route(
        actionIdentifier: String,
        requestIdentifier: String,
        userInfo: [AnyHashable: Any]
    ) -> Route {
        guard let tabIdString = userInfo["tabId"] as? String,
              let tabId = UUID(uuidString: tabIdString) else {
            return .activateApplication
        }
        let surfaceId = (userInfo["surfaceId"] as? String).flatMap(UUID.init(uuidString:))
        let notificationId = UUID(uuidString: requestIdentifier)
            ?? (userInfo["notificationId"] as? String).flatMap(UUID.init(uuidString:))
        switch actionIdentifier {
        case UNNotificationDefaultActionIdentifier, TerminalNotificationStore.actionShowIdentifier:
            return .open(tabId: tabId, surfaceId: surfaceId, notificationId: notificationId)
        case UNNotificationDismissActionIdentifier:
            return notificationId.map(Route.markRead) ?? .ignore
        default:
            return .ignore
        }
    }

    static func presentationOptions(hasSound: Bool) -> UNNotificationPresentationOptions {
        hasSound ? [.banner, .list, .sound] : [.banner, .list]
    }
}
