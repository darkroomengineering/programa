import Foundation

// MARK: - GhosttyTitleUpdateDispatcher (ported from upstream cmux c30733e5e6)
//
// Every GHOSTTY_ACTION_SET_TITLE callback used to post `.ghosttyDidSetTitle` via an
// unconditional `DispatchQueue.main.async`. Shells and agent CLIs that rewrite the
// title on every render (e.g. progress spinners) flood the main actor with
// NotificationCenter posts during typing, adding up to real input latency.
//
// This dispatcher coalesces title updates per surface: at most one
// `.ghosttyDidSetTitle` notification is posted per surface per `interval`. Updates
// that arrive while a flush is already scheduled overwrite the pending title rather
// than queuing a second post, but the *last* title set within the window is always
// the one delivered -- no title is ever silently dropped.
//
// Only the coalescing machinery is ported here. Upstream's notification-hook /
// desktop-notification ingress is cmux agent-chat machinery programa doesn't have.
final class GhosttyTitleUpdateDispatcher {
    /// Identifies the surface a title update belongs to. Coalescing is scoped per key
    /// so a burst of title churn on one surface never delays or drops updates for
    /// another.
    struct SurfaceKey: Hashable {
        let tabId: UUID
        let surfaceId: UUID
    }

    private struct PendingUpdate {
        // Held strongly for the (short, <=50ms) coalescing window, matching the
        // pre-fix behavior where `surfaceView` was captured strongly inside the
        // `DispatchQueue.main.async` closure that posted the notification.
        let surfaceView: AnyObject?
        let tabId: UUID
        let surfaceId: UUID
        let title: String
    }

    private let interval: TimeInterval
    private let postNotification: (AnyObject?, [AnyHashable: Any]) -> Void
    private var pending: [SurfaceKey: PendingUpdate] = [:]
    private var scheduledKeys: Set<SurfaceKey> = []

    init(
        interval: TimeInterval = 0.05,
        postNotification: @escaping (AnyObject?, [AnyHashable: Any]) -> Void = { object, userInfo in
            NotificationCenter.default.post(name: .ghosttyDidSetTitle, object: object, userInfo: userInfo)
        }
    ) {
        self.interval = interval
        self.postNotification = postNotification
    }

    /// Records a title update for `surfaceId` and schedules a coalesced flush if one
    /// isn't already pending for this surface. Safe to call from any thread; the
    /// pending/scheduling state is only ever touched on the main thread.
    func setTitle(surfaceView: AnyObject?, tabId: UUID, surfaceId: UUID, title: String) {
        let apply: () -> Void = { [weak self] in
            self?.setTitleOnMain(surfaceView: surfaceView, tabId: tabId, surfaceId: surfaceId, title: title)
        }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }

    private func setTitleOnMain(surfaceView: AnyObject?, tabId: UUID, surfaceId: UUID, title: String) {
        let key = SurfaceKey(tabId: tabId, surfaceId: surfaceId)
        pending[key] = PendingUpdate(surfaceView: surfaceView, tabId: tabId, surfaceId: surfaceId, title: title)
        guard !scheduledKeys.contains(key) else { return }
        scheduledKeys.insert(key)
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) { [weak self] in
            self?.flush(key: key)
        }
    }

    private func flush(key: SurfaceKey) {
        scheduledKeys.remove(key)
        guard let update = pending.removeValue(forKey: key) else { return }
        postNotification(update.surfaceView, [
            GhosttyNotificationKey.tabId: update.tabId,
            GhosttyNotificationKey.surfaceId: update.surfaceId,
            GhosttyNotificationKey.title: update.title,
        ])
    }
}
