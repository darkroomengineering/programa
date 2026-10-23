import SwiftUI

enum NotificationPageSelection {
    static func reconcile(_ selectedId: UUID?, visibleIds: [UUID]) -> UUID? {
        if let selectedId, visibleIds.contains(selectedId) { return selectedId }
        return visibleIds.first
    }
}

struct NotificationsPage: View {
    @EnvironmentObject var notificationStore: TerminalNotificationStore
    @EnvironmentObject var tabManager: TabManager
    @Binding var selection: SidebarSelection
    @FocusState private var focusedNotificationId: UUID?
    @State private var unreadOnly = false
    @ObservedObject private var keyboardShortcutSettingsObserver = KeyboardShortcutSettingsObserver.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if visibleNotifications.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(visibleNotifications) { notification in
                            NotificationRow(
                                notification: notification,
                                tabTitle: tabTitle(for: notification.tabId),
                                onOpen: {
                                    // SwiftUI action closures are not guaranteed to run on the main actor.
                                    // Ensure window focus + tab selection happens on the main thread.
                                    DispatchQueue.main.async {
                                        _ = AppDelegate.shared?.openNotification(
                                            tabId: notification.tabId,
                                            surfaceId: notification.surfaceId,
                                            notificationId: notification.id
                                        )
                                        selection = .tabs
                                    }
                                },
                                onClear: {
                                    notificationStore.remove(id: notification.id)
                                },
                                onToggleRead: {
                                    if notification.isRead {
                                        notificationStore.markUnread(id: notification.id)
                                    } else {
                                        notificationStore.markRead(id: notification.id)
                                    }
                                },
                                focusedNotificationId: $focusedNotificationId
                            )
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { reconcileFocus(initialize: true) }
        .onChange(of: visibleNotifications.map(\.id)) {
            reconcileFocus()
        }
        .onChange(of: selection) { reconcileFocus(initialize: true) }
    }

    private var visibleNotifications: [TerminalNotification] {
        notificationStore.notifications.filter { !unreadOnly || !$0.isRead }
    }

    private func reconcileFocus(initialize: Bool = false) {
        guard selection == .notifications else { return }
        // A nil row focus can mean the user is operating a filter or row action.
        // Incoming notifications must not pull focus away from that control.
        guard initialize || focusedNotificationId != nil else { return }
        focusedNotificationId = NotificationPageSelection.reconcile(
            focusedNotificationId, visibleIds: visibleNotifications.map(\.id)
        )
    }

    private var header: some View {
        HStack {
            Text(String(localized: "notifications.title", defaultValue: "Notifications"))
                .font(.title2)
                .fontWeight(.semibold)

            Spacer()

            Toggle(String(localized: "notifications.unreadOnly", defaultValue: "Unread only"), isOn: $unreadOnly)
                .toggleStyle(.button)
                .frame(minHeight: 44)

            if !notificationStore.notifications.isEmpty {
                jumpToUnreadButton

                Button(String(localized: "notifications.clearAll", defaultValue: "Clear All")) {
                    notificationStore.clearAll()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bell.slash")
                .symbolRasterSize(32)
                .foregroundColor(.secondary)
            Text(unreadOnly
                 ? String(localized: "notifications.empty.unread", defaultValue: "No unread notifications")
                 : String(localized: "notifications.empty.title", defaultValue: "No notifications yet"))
                .font(.headline)
            Text(String(localized: "notifications.empty.description", defaultValue: "Desktop notifications will appear here for quick review."))
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var jumpToUnreadButton: some View {
        if let key = jumpToUnreadShortcut.keyEquivalent {
            Button(action: {
                AppDelegate.shared?.jumpToLatestUnread()
            }) {
                HStack(spacing: 6) {
                    Text(String(localized: "notifications.jumpToLatestUnread", defaultValue: "Jump to Latest Unread"))
                    ShortcutAnnotation(text: jumpToUnreadShortcut.displayString)
                }
            }
            .buttonStyle(.bordered)
            .keyboardShortcut(key, modifiers: jumpToUnreadShortcut.eventModifiers)
            .safeHelp(KeyboardShortcutSettings.Action.jumpToUnread.tooltip(String(localized: "notifications.jumpToLatestUnread", defaultValue: "Jump to Latest Unread")))
            .disabled(!hasUnreadNotifications)
        } else {
            Button(action: {
                AppDelegate.shared?.jumpToLatestUnread()
            }) {
                HStack(spacing: 6) {
                    Text(String(localized: "notifications.jumpToLatestUnread", defaultValue: "Jump to Latest Unread"))
                    ShortcutAnnotation(text: jumpToUnreadShortcut.displayString)
                }
            }
            .buttonStyle(.bordered)
            .safeHelp(KeyboardShortcutSettings.Action.jumpToUnread.tooltip(String(localized: "notifications.jumpToLatestUnread", defaultValue: "Jump to Latest Unread")))
            .disabled(!hasUnreadNotifications)
        }
    }

    private var jumpToUnreadShortcut: StoredShortcut {
        let _ = keyboardShortcutSettingsObserver.revision
        return KeyboardShortcutSettings.shortcut(for: .jumpToUnread)
    }

    private func tabTitle(for tabId: UUID) -> String? {
        AppDelegate.shared?.tabTitle(for: tabId) ?? tabManager.tabs.first(where: { $0.id == tabId })?.title
    }

    private var hasUnreadNotifications: Bool {
        notificationStore.notifications.contains(where: { !$0.isRead })
    }
}

struct ShortcutAnnotation: View {
    let text: String
    var accessibilityIdentifier: String? = nil

    @ViewBuilder
    var body: some View {
        if let accessibilityIdentifier {
            badge.accessibilityIdentifier(accessibilityIdentifier)
        } else {
            badge
        }
    }

    private var badge: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(.primary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
    }
}

private struct NotificationRow: View {
    let notification: TerminalNotification
    let tabTitle: String?
    let onOpen: () -> Void
    let onClear: () -> Void
    let onToggleRead: () -> Void
    let focusedNotificationId: FocusState<UUID?>.Binding
    @State private var isExpanded = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onOpen) {
                HStack(alignment: .top, spacing: 12) {
                    Circle()
                        .fill(notification.isRead ? Color.clear : programaAccentColor())
                        .frame(width: 8, height: 8)
                        .overlay(
                            Circle()
                                .stroke(programaAccentColor().opacity(notification.isRead ? 0.2 : 1), lineWidth: 1)
                        )
                        .padding(.top, 6)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(notification.title)
                                .font(.headline)
                                .foregroundColor(.primary)
                            Spacer()
                            Text(notification.createdAt.formatted(date: .omitted, time: .shortened))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        if !notification.subtitle.isEmpty {
                            Text(notification.subtitle)
                                .font(.subheadline.weight(.medium))
                                .foregroundColor(.secondary)
                        }

                        if !notification.body.isEmpty {
                            Text(notification.body)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .lineLimit(isExpanded ? nil : 3)
                        }

                        if let tabTitle {
                            Text(tabTitle)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    Spacer(minLength: 0)
                }
                .padding(.trailing, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("NotificationRow.\(notification.id.uuidString)")
            .focusable()
            .focused(focusedNotificationId, equals: notification.id)
            .modifier(DefaultActionModifier(isActive: focusedNotificationId.wrappedValue == notification.id))

            VStack(alignment: .trailing, spacing: 4) {
                Button(action: onClear) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "notifications.clear", defaultValue: "Clear notification"))

                Button(action: onToggleRead) {
                    Text(notification.isRead
                         ? String(localized: "notifications.markUnread", defaultValue: "Mark unread")
                         : String(localized: "notifications.markRead", defaultValue: "Mark read"))
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)

                if !notification.body.isEmpty {
                    Button {
                        isExpanded.toggle()
                    } label: {
                        Text(isExpanded
                             ? String(localized: "notifications.showLess", defaultValue: "Show less")
                             : String(localized: "notifications.showMore", defaultValue: "Show full message"))
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}

private struct DefaultActionModifier: ViewModifier {
    let isActive: Bool

    func body(content: Content) -> some View {
        if isActive {
            content.keyboardShortcut(.defaultAction)
        } else {
            content
        }
    }
}
