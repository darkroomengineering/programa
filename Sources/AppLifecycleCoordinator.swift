import AppKit
import Foundation
import UserNotifications

@MainActor
final class AppLifecycleCoordinator {
    struct TerminationDecision: Equatable {
        let shouldWarn: Bool
        let logReason: String
    }

    private(set) var isTerminating = false
    private(set) var isAwaitingPowerOff = false
    private(set) var isQuitWarningConfirmed = false
    private var didInstallSnapshotObservers = false
    private var didDisableSuddenTermination = false

    func beginTermination(
        isTaggedDevBuild: Bool,
        isQuitWarningEnabled: Bool
    ) -> TerminationDecision {
        isTerminating = true
        let shouldWarn = AppDelegate.shouldWarnBeforeTermination(
            isTaggedDevBuild: isTaggedDevBuild,
            isQuitWarningConfirmed: isQuitWarningConfirmed,
            isQuitWarningEnabled: isQuitWarningEnabled
        )
        return TerminationDecision(shouldWarn: shouldWarn, logReason: "warning_bypassed")
    }

    func confirmQuit() {
        isQuitWarningConfirmed = true
    }

    func cancelTermination() {
        isTerminating = false
    }

    func beginPowerOff() {
        isAwaitingPowerOff = true
        isTerminating = true
    }

    @discardableResult
    func resumeAfterCancelledPowerOff() -> Bool {
        guard isAwaitingPowerOff else { return false }
        isAwaitingPowerOff = false
        isTerminating = false
        return true
    }

    func willTerminate() {
        isAwaitingPowerOff = false
        isTerminating = true
    }

    func beginUpdateRelaunch() {
        isTerminating = true
        isQuitWarningConfirmed = true
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
