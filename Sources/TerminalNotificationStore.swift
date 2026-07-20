import AppKit
import Foundation
import UserNotifications
import Bonsplit

// UNUserNotificationCenter.removeDeliveredNotifications(withIdentifiers:) and
// removePendingNotificationRequests(withIdentifiers:) perform synchronous XPC to
// usernoted under the hood. When usernoted is slow, this blocks the calling thread
// indefinitely. These helpers dispatch the calls off the main thread so they never
// freeze the UI.
extension UNUserNotificationCenter {
    private static let removalQueue = DispatchQueue(
        label: "com.cmuxterm.notification-removal",
        qos: .utility
    )

    func removeDeliveredNotificationsOffMain(withIdentifiers ids: [String]) {
        guard !ids.isEmpty else { return }
        Self.removalQueue.async {
            self.removeDeliveredNotifications(withIdentifiers: ids)
        }
    }

    func removePendingNotificationRequestsOffMain(withIdentifiers ids: [String]) {
        guard !ids.isEmpty else { return }
        Self.removalQueue.async {
            self.removePendingNotificationRequests(withIdentifiers: ids)
        }
    }
}

enum TaggedRunBadgeSettings {
    static let environmentKey = "PROGRAMA_TAG"
    private static let maxTagLength = 10

    static func normalizedTag(from env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        normalizedTag(env[environmentKey])
    }

    static func normalizedTag(_ rawTag: String?) -> String? {
        guard var tag = rawTag?.trimmingCharacters(in: .whitespacesAndNewlines), !tag.isEmpty else {
            return nil
        }
        if tag.count > maxTagLength {
            tag = String(tag.prefix(maxTagLength))
        }
        return tag
    }
}

enum AppFocusState {
    static var overrideIsFocused: Bool?

    static func isAppActive() -> Bool {
        if let overrideIsFocused {
            return overrideIsFocused
        }
        return NSApp.isActive
    }

    static func isAppFocused() -> Bool {
        if let overrideIsFocused {
            return overrideIsFocused
        }
        guard NSApp.isActive else { return false }
        guard let keyWindow = NSApp.keyWindow, keyWindow.isKeyWindow else { return false }
        // Only treat the app as "focused" for notification suppression when a main terminal window
        // is key. If Settings/About/debug panels are key, we still want notifications to show.
        if let raw = keyWindow.identifier?.rawValue {
            return raw == "cmux.main" || raw.hasPrefix("cmux.main.")
        }
        return false
    }
}

enum NotificationAuthorizationState: Equatable {
    case unknown
    case notDetermined
    case authorized
    case denied
    case provisional
    case ephemeral

    var statusLabel: String {
        switch self {
        case .unknown, .notDetermined:
            return "Not Requested"
        case .authorized:
            return "Allowed"
        case .denied:
            return "Denied"
        case .provisional:
            return "Deliver Quietly"
        case .ephemeral:
            return "Temporary"
        }
    }

    var allowsDelivery: Bool {
        switch self {
        case .authorized, .provisional, .ephemeral:
            return true
        case .unknown, .notDetermined, .denied:
            return false
        }
    }
}

struct TerminalNotification: Identifiable, Hashable {
    let id: UUID
    let tabId: UUID
    let surfaceId: UUID?
    let title: String
    let subtitle: String
    let body: String
    let createdAt: Date
    var isRead: Bool
}

@MainActor
final class TerminalNotificationStore: ObservableObject {
    private struct TabSurfaceKey: Hashable {
        let tabId: UUID
        let surfaceId: UUID?
    }

    private struct NotificationIndexes {
        var unreadCount = 0
        var unreadCountByTabId: [UUID: Int] = [:]
        var unreadByTabSurface = Set<TabSurfaceKey>()
        var latestUnreadByTabId: [UUID: TerminalNotification] = [:]
        var latestByTabId: [UUID: TerminalNotification] = [:]
    }

    static let shared = TerminalNotificationStore()

    static let categoryIdentifier = "com.darkroom.programa.userNotification"
    static let actionShowIdentifier = "com.darkroom.programa.userNotification.show"
    private enum AuthorizationRequestOrigin: String {
        case notificationDelivery = "notification_delivery"
        case settingsButton = "settings_button"
    }

    @Published private(set) var notifications: [TerminalNotification] = [] {
        didSet {
            indexes = Self.buildIndexes(for: notifications)
            refreshDockBadge()
        }
    }
    @Published private(set) var focusedReadIndicatorByTabId: [UUID: UUID] = [:]
    @Published private(set) var authorizationState: NotificationAuthorizationState = .unknown

    private let center = UNUserNotificationCenter.current()
    private var hasRequestedAutomaticAuthorization = false
    private var hasDeferredAuthorizationRequest = false
    private var hasPromptedForSettings = false
    private var userDefaultsObserver: NSObjectProtocol?
    private let settingsPromptWindowRetryDelay: TimeInterval = 0.5
    private let settingsPromptWindowRetryLimit = 20
    private var notificationSettingsWindowProvider: () -> NSWindow? = {
        NSApp.keyWindow ?? NSApp.mainWindow
    }
    private var notificationSettingsAlertFactory: () -> NSAlert = {
        NSAlert()
    }
    private var notificationSettingsScheduler: (_ delay: TimeInterval, _ block: @escaping () -> Void) -> Void = {
        delay,
        block in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            block()
        }
    }
    private var notificationSettingsURLOpener: (URL) -> Void = { url in
        NSWorkspace.shared.open(url)
    }
    private var notificationDeliveryHandler: (TerminalNotificationStore, TerminalNotification) -> Void = {
        store,
        notification in
        store.scheduleUserNotification(notification)
    }
    private var suppressedNotificationFeedbackHandler: (TerminalNotificationStore, TerminalNotification) -> Void = {
        store,
        notification in
        store.playSuppressedNotificationFeedback(for: notification)
    }
    private var lastNotificationDateByCooldownKey: [String: Date] = [:]
    private var indexes = NotificationIndexes()

    private init() {
        indexes = Self.buildIndexes(for: notifications)
        userDefaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshDockBadge()
            }
        }
        refreshDockBadge()
        refreshAuthorizationStatus()
    }

    deinit {
        if let userDefaultsObserver {
            NotificationCenter.default.removeObserver(userDefaultsObserver)
        }
    }

    static func dockBadgeLabel(unreadCount: Int, isEnabled: Bool, runTag: String? = nil) -> String? {
        let unreadLabel: String? = {
            guard isEnabled, unreadCount > 0 else { return nil }
            if unreadCount > 99 {
                return "99+"
            }
            return String(unreadCount)
        }()

        if let tag = TaggedRunBadgeSettings.normalizedTag(runTag) {
            if let unreadLabel {
                return "\(tag):\(unreadLabel)"
            }
            return tag
        }

        return unreadLabel
    }

    var unreadCount: Int {
        indexes.unreadCount
    }

    private func logAuthorization(_ message: String) {
#if DEBUG
        dlog("notification.auth \(message)")
#endif
        NSLog("notification.auth %@", message)
    }

    private static func authorizationStatusLabel(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined:
            return "notDetermined"
        case .denied:
            return "denied"
        case .authorized:
            return "authorized"
        case .provisional:
            return "provisional"
        case .ephemeral:
            return "ephemeral"
        @unknown default:
            return "unknown(\(status.rawValue))"
        }
    }

    func refreshAuthorizationStatus() {
        center.getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                guard let self else { return }
                self.authorizationState = Self.authorizationState(from: settings.authorizationStatus)
                self.logAuthorization(
                    "refresh status=\(Self.authorizationStatusLabel(settings.authorizationStatus)) mapped=\(self.authorizationState.statusLabel)"
                )
            }
        }
    }

    func requestAuthorizationFromSettings() {
        logAuthorization("settings request tapped state=\(authorizationState.statusLabel)")
        ensureAuthorization(origin: .settingsButton) { _ in }
    }

    func openNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") else {
            return
        }
        logAuthorization("open settings url=\(url.absoluteString)")
        notificationSettingsURLOpener(url)
    }

    func handleApplicationDidBecomeActive() {
        logAuthorization("app became active deferred=\(hasDeferredAuthorizationRequest)")
        if hasDeferredAuthorizationRequest {
            hasDeferredAuthorizationRequest = false
            ensureAuthorization(origin: .settingsButton) { _ in }
            return
        }
        refreshAuthorizationStatus()
    }

    func unreadCount(forTabId tabId: UUID) -> Int {
        indexes.unreadCountByTabId[tabId] ?? 0
    }

    func hasUnreadNotification(forTabId tabId: UUID, surfaceId: UUID?) -> Bool {
        indexes.unreadByTabSurface.contains(TabSurfaceKey(tabId: tabId, surfaceId: surfaceId))
    }

    func hasVisibleNotificationIndicator(forTabId tabId: UUID, surfaceId: UUID?) -> Bool {
        hasUnreadNotification(forTabId: tabId, surfaceId: surfaceId) ||
            focusedReadIndicatorByTabId[tabId] == surfaceId
    }

    func latestNotification(forTabId tabId: UUID) -> TerminalNotification? {
        indexes.latestByTabId[tabId]
    }

    func clearLatestNotification(forTabId tabId: UUID) {
        guard let latestNotification = indexes.latestByTabId[tabId] else { return }
        remove(id: latestNotification.id)
    }

    func focusedReadIndicatorSurfaceId(forTabId tabId: UUID) -> UUID? {
        focusedReadIndicatorByTabId[tabId]
    }

    func addNotification(
        tabId: UUID,
        surfaceId: UUID?,
        title: String,
        subtitle: String,
        body: String,
        cooldownKey: String? = nil,
        cooldownInterval: TimeInterval? = nil
    ) {
        let now = Date()
        let resolvedCooldownInterval: TimeInterval?
        if let cooldownInterval, cooldownInterval.isFinite, cooldownInterval > 0 {
            resolvedCooldownInterval = cooldownInterval
        } else {
            resolvedCooldownInterval = nil
        }
        if let cooldownKey,
           let resolvedCooldownInterval,
           let lastNotificationDate = lastNotificationDateByCooldownKey[cooldownKey],
           now.timeIntervalSince(lastNotificationDate) < resolvedCooldownInterval {
            return
        }

        var updated = notifications
        var idsToClear: [String] = []
        updated.removeAll { existing in
            guard existing.tabId == tabId, existing.surfaceId == surfaceId else { return false }
            idsToClear.append(existing.id.uuidString)
            return true
        }

        if let existingIndicatorSurfaceId = focusedReadIndicatorByTabId[tabId],
           existingIndicatorSurfaceId != surfaceId {
            focusedReadIndicatorByTabId.removeValue(forKey: tabId)
        }

        // Judge focus state by the tab manager that owns this tab — the primary
        // window's manager gives wrong answers for tabs in secondary windows.
        //
        // NOTE (nuclear-review #90): TerminalNotificationStore reaching back into
        // AppDelegate.shared for tab-manager lookups is a layering smell — this store should
        // arguably be handed the owning TabManager(s) rather than reaching for a global.
        // Flagged, not fixed here: untangling it needs a real design pass on how
        // TerminalNotificationStore is scoped/injected across windows, not a mechanical move.
        let owningTabManager = AppDelegate.shared?.tabManagerFor(tabId: tabId) ?? AppDelegate.shared?.tabManager
        let isActiveTab = owningTabManager?.selectedTabId == tabId
        let focusedSurfaceId = owningTabManager?.focusedSurfaceId(for: tabId)
        let isFocusedSurface = surfaceId == nil || focusedSurfaceId == surfaceId
        let isFocusedPanel = isActiveTab && isFocusedSurface
        let isAppFocused = AppFocusState.isAppFocused()
        let shouldSuppressExternalDelivery = isAppFocused && isFocusedPanel
        if shouldSuppressExternalDelivery {
            setFocusedReadIndicator(forTabId: tabId, surfaceId: surfaceId)
        }

        if WorkspaceAutoReorderSettings.isEnabled() {
            owningTabManager?.moveTabToTopForNotification(tabId)
        }

        let notification = TerminalNotification(
            id: UUID(),
            tabId: tabId,
            surfaceId: surfaceId,
            title: title,
            subtitle: subtitle,
            body: body,
            createdAt: now,
            isRead: false
        )
        updated.insert(notification, at: 0)
        notifications = updated
        if let cooldownKey, resolvedCooldownInterval != nil {
            lastNotificationDateByCooldownKey[cooldownKey] = now
        }
        if !idsToClear.isEmpty {
            center.removeDeliveredNotificationsOffMain(withIdentifiers: idsToClear)
            center.removePendingNotificationRequestsOffMain(withIdentifiers: idsToClear)
        }
        if shouldSuppressExternalDelivery {
            suppressedNotificationFeedbackHandler(self, notification)
        } else {
            notificationDeliveryHandler(self, notification)
        }
    }

    func markRead(id: UUID) {
        var updated = notifications
        guard let index = updated.firstIndex(where: { $0.id == id }) else { return }
        guard !updated[index].isRead else { return }
        updated[index].isRead = true
        notifications = updated
        center.removeDeliveredNotificationsOffMain(withIdentifiers: [id.uuidString])
    }

    /// Marks a single notification unread and bumps it to the top of the list (mirrors the
    /// bump `addNotification` performs on arrival), so a manually-unread notification is easy
    /// to find again instead of staying buried at its original position.
    func markUnread(id: UUID) {
        var updated = notifications
        guard let index = updated.firstIndex(where: { $0.id == id }) else { return }
        guard updated[index].isRead else { return }
        updated[index].isRead = false
        notifications = Self.bumpingChangedToFront(updated, changedIds: [id])
    }

    func markRead(forTabId tabId: UUID) {
        var updated = notifications
        var idsToClear: [String] = []
        for index in updated.indices {
            if updated[index].tabId == tabId && !updated[index].isRead {
                updated[index].isRead = true
                idsToClear.append(updated[index].id.uuidString)
            }
        }
        if !idsToClear.isEmpty {
            notifications = updated
            center.removeDeliveredNotificationsOffMain(withIdentifiers: idsToClear)
        }
    }

    func markRead(forTabId tabId: UUID, surfaceId: UUID?) {
        var updated = notifications
        var idsToClear: [String] = []
        for index in updated.indices {
            if updated[index].tabId == tabId,
               updated[index].surfaceId == surfaceId,
               !updated[index].isRead {
                updated[index].isRead = true
                idsToClear.append(updated[index].id.uuidString)
            }
        }
        if !idsToClear.isEmpty {
            notifications = updated
            center.removeDeliveredNotificationsOffMain(withIdentifiers: idsToClear)
            center.removePendingNotificationRequestsOffMain(withIdentifiers: idsToClear)
        }
    }

    func markUnread(forTabId tabId: UUID) {
        var updated = notifications
        var changedIds: Set<UUID> = []
        for index in updated.indices {
            if updated[index].tabId == tabId, updated[index].isRead {
                updated[index].isRead = false
                changedIds.insert(updated[index].id)
            }
        }
        if !changedIds.isEmpty {
            notifications = Self.bumpingChangedToFront(updated, changedIds: changedIds)
        }
    }

    /// Partitions `notifications` so entries whose id is in `changedIds` move to the front
    /// (preserving their relative order), followed by the rest (also preserving relative
    /// order). Used by both `markUnread(forTabId:)` and `markUnread(id:)` so a
    /// just-marked-unread notification is bumped to the top the same way a freshly arriving
    /// notification is via `addNotification`'s `insert(at: 0)`.
    private static func bumpingChangedToFront(
        _ notifications: [TerminalNotification],
        changedIds: Set<UUID>
    ) -> [TerminalNotification] {
        var bumped: [TerminalNotification] = []
        var rest: [TerminalNotification] = []
        bumped.reserveCapacity(changedIds.count)
        rest.reserveCapacity(notifications.count)
        for notification in notifications {
            if changedIds.contains(notification.id) {
                bumped.append(notification)
            } else {
                rest.append(notification)
            }
        }
        return bumped + rest
    }

    func setFocusedReadIndicator(forTabId tabId: UUID, surfaceId: UUID?) {
        guard let surfaceId else { return }
        guard focusedReadIndicatorByTabId[tabId] != surfaceId else { return }
        focusedReadIndicatorByTabId[tabId] = surfaceId
    }

    func clearFocusedReadIndicator(forTabId tabId: UUID, surfaceId: UUID? = nil) {
        guard let existingSurfaceId = focusedReadIndicatorByTabId[tabId] else { return }
        guard surfaceId == nil || existingSurfaceId == surfaceId else { return }
        focusedReadIndicatorByTabId.removeValue(forKey: tabId)
    }

    func clearFocusedReadIndicatorIfSurfaceChanged(forTabId tabId: UUID, surfaceId: UUID?) {
        guard let existingSurfaceId = focusedReadIndicatorByTabId[tabId] else { return }
        guard existingSurfaceId != surfaceId else { return }
        focusedReadIndicatorByTabId.removeValue(forKey: tabId)
    }

    func markAllRead() {
        var updated = notifications
        var idsToClear: [String] = []
        for index in updated.indices {
            if !updated[index].isRead {
                updated[index].isRead = true
                idsToClear.append(updated[index].id.uuidString)
            }
        }
        if !idsToClear.isEmpty {
            notifications = updated
            center.removeDeliveredNotificationsOffMain(withIdentifiers: idsToClear)
            center.removePendingNotificationRequestsOffMain(withIdentifiers: idsToClear)
        }
    }

    func remove(id: UUID) {
        var updated = notifications
        let removed = updated.first(where: { $0.id == id })
        let originalCount = updated.count
        updated.removeAll { $0.id == id }
        guard updated.count != originalCount else { return }
        notifications = updated
        if let removed {
            clearFocusedReadIndicator(forTabId: removed.tabId, surfaceId: removed.surfaceId)
        }
        center.removeDeliveredNotificationsOffMain(withIdentifiers: [id.uuidString])
    }

    func clearAll() {
        guard !notifications.isEmpty || !focusedReadIndicatorByTabId.isEmpty else { return }
        let ids = notifications.map { $0.id.uuidString }
        notifications.removeAll()
        focusedReadIndicatorByTabId.removeAll()
        center.removeDeliveredNotificationsOffMain(withIdentifiers: ids)
        center.removePendingNotificationRequestsOffMain(withIdentifiers: ids)
    }

    func clearNotifications(forTabId tabId: UUID, surfaceId: UUID?) {
        var updated: [TerminalNotification] = []
        updated.reserveCapacity(notifications.count)
        var idsToClear: [String] = []
        for notification in notifications {
            if notification.tabId == tabId, notification.surfaceId == surfaceId {
                idsToClear.append(notification.id.uuidString)
            } else {
                updated.append(notification)
            }
        }
        guard !idsToClear.isEmpty else { return }
        notifications = updated
        clearFocusedReadIndicator(forTabId: tabId, surfaceId: surfaceId)
        center.removeDeliveredNotificationsOffMain(withIdentifiers: idsToClear)
        center.removePendingNotificationRequestsOffMain(withIdentifiers: idsToClear)
    }

    func clearNotifications(forTabId tabId: UUID) {
        var updated: [TerminalNotification] = []
        updated.reserveCapacity(notifications.count)
        var idsToClear: [String] = []
        for notification in notifications {
            if notification.tabId == tabId {
                idsToClear.append(notification.id.uuidString)
            } else {
                updated.append(notification)
            }
        }
        guard !idsToClear.isEmpty else { return }
        notifications = updated
        clearFocusedReadIndicator(forTabId: tabId)
        center.removeDeliveredNotificationsOffMain(withIdentifiers: idsToClear)
        center.removePendingNotificationRequestsOffMain(withIdentifiers: idsToClear)
    }

    private func resolvedNotificationTitle(for notification: TerminalNotification) -> String {
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Programa"
        return notification.title.isEmpty ? appName : notification.title
    }

    private func scheduleUserNotification(_ notification: TerminalNotification) {
        ensureAuthorization(origin: .notificationDelivery) { [weak self] authorized in
            guard let self, authorized else { return }

            let content = UNMutableNotificationContent()
            content.title = self.resolvedNotificationTitle(for: notification)
            content.subtitle = notification.subtitle
            content.body = notification.body
            content.sound = NotificationSoundSettings.sound()
            content.categoryIdentifier = Self.categoryIdentifier
            content.userInfo = [
                "tabId": notification.tabId.uuidString,
                "notificationId": notification.id.uuidString,
            ]
            if let surfaceId = notification.surfaceId {
                content.userInfo["surfaceId"] = surfaceId.uuidString
            }

            let request = UNNotificationRequest(
                identifier: notification.id.uuidString,
                content: content,
                trigger: nil
            )
            let commandTitle = content.title
            let commandSubtitle = content.subtitle
            let commandBody = content.body

            self.center.add(request) { error in
                if let error {
                    NSLog("Failed to schedule notification: \(error)")
                } else {
                    NotificationSoundSettings.runCustomCommand(
                        title: commandTitle,
                        subtitle: commandSubtitle,
                        body: commandBody
                    )
                }
            }
        }
    }

    private func playSuppressedNotificationFeedback(for notification: TerminalNotification) {
        NotificationSoundSettings.playSelectedSound()
        NotificationSoundSettings.runCustomCommand(
            title: resolvedNotificationTitle(for: notification),
            subtitle: notification.subtitle,
            body: notification.body
        )
    }

    private func ensureAuthorization(
        origin: AuthorizationRequestOrigin,
        _ completion: @escaping (Bool) -> Void
    ) {
        logAuthorization("ensure start origin=\(origin.rawValue)")
        center.getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                guard let self else {
                    completion(false)
                    return
                }

                self.authorizationState = Self.authorizationState(from: settings.authorizationStatus)
                self.logAuthorization(
                    "ensure status origin=\(origin.rawValue) status=\(Self.authorizationStatusLabel(settings.authorizationStatus)) mapped=\(self.authorizationState.statusLabel) appActive=\(AppFocusState.isAppActive())"
                )
                switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral:
                    completion(true)
                case .denied:
                    self.logAuthorization("ensure denied origin=\(origin.rawValue) prompting_settings")
                    self.promptToEnableNotifications()
                    completion(false)
                case .notDetermined:
                    if Self.shouldDeferAutomaticAuthorizationRequest(
                        origin: origin,
                        status: settings.authorizationStatus,
                        isAppActive: AppFocusState.isAppActive()
                    ) {
                        self.logAuthorization("ensure deferred origin=\(origin.rawValue)")
                        self.hasDeferredAuthorizationRequest = true
                        completion(false)
                    } else {
                        self.requestAuthorizationIfNeeded(origin: origin, completion)
                    }
                @unknown default:
                    self.logAuthorization("ensure unknown status origin=\(origin.rawValue)")
                    completion(false)
                }
            }
        }
    }

    private func requestAuthorizationIfNeeded(
        origin: AuthorizationRequestOrigin,
        _ completion: @escaping (Bool) -> Void
    ) {
        let isAutomaticRequest = origin == .notificationDelivery
        guard Self.shouldRequestAuthorization(
            isAutomaticRequest: isAutomaticRequest,
            hasRequestedAutomaticAuthorization: hasRequestedAutomaticAuthorization
        ) else {
            logAuthorization(
                "request blocked origin=\(origin.rawValue) automatic=\(isAutomaticRequest) hasRequestedAutomatic=\(hasRequestedAutomaticAuthorization)"
            )
            completion(false)
            return
        }
        if isAutomaticRequest {
            hasRequestedAutomaticAuthorization = true
        }
        hasDeferredAuthorizationRequest = false
        logAuthorization(
            "request starting origin=\(origin.rawValue) automatic=\(isAutomaticRequest) hasRequestedAutomatic=\(hasRequestedAutomaticAuthorization)"
        )
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            DispatchQueue.main.async {
                if granted {
                    self.authorizationState = .authorized
                } else {
                    self.refreshAuthorizationStatus()
                }
                self.logAuthorization(
                    "request callback origin=\(origin.rawValue) granted=\(granted) error=\(error?.localizedDescription ?? "nil") mapped=\(self.authorizationState.statusLabel)"
                )
                completion(granted)
            }
        }
    }

    private func promptToEnableNotifications() {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.hasPromptedForSettings else { return }
            self.logAuthorization("prompt settings shown")
            self.hasPromptedForSettings = true
            self.presentNotificationSettingsPrompt(attempt: 0)
        }
    }

    private func presentNotificationSettingsPrompt(attempt: Int) {
        guard let window = notificationSettingsWindowProvider() else {
            guard attempt < settingsPromptWindowRetryLimit else {
                // If no window is available after retries, allow a future denied callback
                // to prompt again when the app has a key/main window.
                hasPromptedForSettings = false
                return
            }
            notificationSettingsScheduler(settingsPromptWindowRetryDelay) { [weak self] in
                self?.presentNotificationSettingsPrompt(attempt: attempt + 1)
            }
            return
        }

        let alert = notificationSettingsAlertFactory()
        alert.messageText = String(localized: "dialog.enableNotifications.title", defaultValue: "Enable Notifications for Programa")
        alert.informativeText = String(localized: "dialog.enableNotifications.message", defaultValue: "Notifications are disabled for Programa. Enable them in System Settings to see alerts.")
        alert.addButton(withTitle: String(localized: "dialog.enableNotifications.openSettings", defaultValue: "Open Settings"))
        alert.addButton(withTitle: String(localized: "dialog.enableNotifications.notNow", defaultValue: "Not Now"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else {
                return
            }
            self?.openNotificationSettings()
        }
    }

    static func authorizationState(from status: UNAuthorizationStatus) -> NotificationAuthorizationState {
        switch status {
        case .authorized:
            return .authorized
        case .denied:
            return .denied
        case .notDetermined:
            return .notDetermined
        case .provisional:
            return .provisional
        case .ephemeral:
            return .ephemeral
        @unknown default:
            return .unknown
        }
    }

    static func shouldDeferAutomaticAuthorizationRequest(
        status: UNAuthorizationStatus,
        isAppActive: Bool
    ) -> Bool {
        status == .notDetermined && !isAppActive
    }

    static func shouldRequestAuthorization(
        isAutomaticRequest: Bool,
        hasRequestedAutomaticAuthorization: Bool
    ) -> Bool {
        guard isAutomaticRequest else { return true }
        return !hasRequestedAutomaticAuthorization
    }

    private static func shouldDeferAutomaticAuthorizationRequest(
        origin: AuthorizationRequestOrigin,
        status: UNAuthorizationStatus,
        isAppActive: Bool
    ) -> Bool {
        guard origin == .notificationDelivery else { return false }
        return shouldDeferAutomaticAuthorizationRequest(status: status, isAppActive: isAppActive)
    }

    private static func buildIndexes(for notifications: [TerminalNotification]) -> NotificationIndexes {
        var indexes = NotificationIndexes()
        for notification in notifications {
            if indexes.latestByTabId[notification.tabId] == nil {
                indexes.latestByTabId[notification.tabId] = notification
            }
            guard !notification.isRead else { continue }
            indexes.unreadCount += 1
            indexes.unreadCountByTabId[notification.tabId, default: 0] += 1
            indexes.unreadByTabSurface.insert(
                TabSurfaceKey(tabId: notification.tabId, surfaceId: notification.surfaceId)
            )
            if indexes.latestUnreadByTabId[notification.tabId] == nil {
                indexes.latestUnreadByTabId[notification.tabId] = notification
            }
        }
        return indexes
    }

#if DEBUG
    func configureNotificationSettingsPromptHooksForTesting(
        windowProvider: @escaping () -> NSWindow?,
        alertFactory: @escaping () -> NSAlert,
        scheduler: @escaping (_ delay: TimeInterval, _ block: @escaping () -> Void) -> Void,
        urlOpener: @escaping (URL) -> Void
    ) {
        notificationSettingsWindowProvider = windowProvider
        notificationSettingsAlertFactory = alertFactory
        notificationSettingsScheduler = scheduler
        notificationSettingsURLOpener = urlOpener
        hasPromptedForSettings = false
    }

    func resetNotificationSettingsPromptHooksForTesting() {
        notificationSettingsWindowProvider = { NSApp.keyWindow ?? NSApp.mainWindow }
        notificationSettingsAlertFactory = { NSAlert() }
        notificationSettingsScheduler = { delay, block in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                block()
            }
        }
        notificationSettingsURLOpener = { url in
            NSWorkspace.shared.open(url)
        }
        hasPromptedForSettings = false
    }

    func configureNotificationDeliveryHandlerForTesting(
        _ handler: @escaping (TerminalNotificationStore, TerminalNotification) -> Void
    ) {
        notificationDeliveryHandler = handler
    }

    func resetNotificationDeliveryHandlerForTesting() {
        notificationDeliveryHandler = { store, notification in
            store.scheduleUserNotification(notification)
        }
    }

    func configureSuppressedNotificationFeedbackHandlerForTesting(
        _ handler: @escaping (TerminalNotificationStore, TerminalNotification) -> Void
    ) {
        suppressedNotificationFeedbackHandler = handler
    }

    func resetSuppressedNotificationFeedbackHandlerForTesting() {
        suppressedNotificationFeedbackHandler = { store, notification in
            store.playSuppressedNotificationFeedback(for: notification)
        }
    }

    func promptToEnableNotificationsForTesting() {
        promptToEnableNotifications()
    }

    func replaceNotificationsForTesting(_ notifications: [TerminalNotification]) {
        self.notifications = notifications
        focusedReadIndicatorByTabId.removeAll()
    }
#endif

    private func refreshDockBadge() {
        let label = Self.dockBadgeLabel(
            unreadCount: unreadCount,
            isEnabled: true,
            runTag: TaggedRunBadgeSettings.normalizedTag()
        )
        NSApp?.dockTile.badgeLabel = label
    }
}
