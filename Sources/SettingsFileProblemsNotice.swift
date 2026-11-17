import AppKit
import SwiftUI

/// Tells the user, in the bottom-right corner of a main window, that settings.json has problems.
/// It shows once per distinct set of problems, persisted across launches, so an unchanged file
/// does not nag on every launch. It adds a view without activating the app or changing the key
/// window or first responder, so it never steals focus.
@MainActor
final class SettingsFileProblemsNotice {
    static let shared = SettingsFileProblemsNotice()

    private static let shownSignatureKey = "programa.settingsFile.shownProblemsSignature"

    private struct Report: Equatable {
        let count: Int
        let signature: String
    }

    private enum State {
        /// No problems, or the current ones were already shown.
        case idle
        /// Problems not shown yet, waiting for a visible main window.
        case pending(Report)
        case showing(Report, NSHostingView<SettingsFileProblemsNoticeView>)
    }

    private var state: State = .idle
    private var observers: [NSObjectProtocol] = []
    private let defaults: UserDefaults

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func install() {
        guard observers.isEmpty else { return }
        // Create the store before observing it: its first reload posts the notification from
        // inside its lazy initializer, and evaluate() would re-enter that initializer.
        _ = KeyboardShortcutSettings.settingsFileStore
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: ProgramaSettingsFileStore.didReloadNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.evaluate() }
            },
            center.addObserver(forName: NSWindow.didBecomeMainNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.presentIfPending() }
            },
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.presentIfPending() }
            },
        ]
        evaluate()
    }

    private func evaluate() {
        let store = KeyboardShortcutSettings.settingsFileStore
        let problems = store.currentProblems()
        guard !problems.isEmpty else {
            // Forget what was shown, so the same problems coming back later are shown again.
            defaults.removeObject(forKey: Self.shownSignatureKey)
            transition(to: .idle)
            return
        }
        // Lines are left out, so an edit elsewhere in the file does not bring the notice back.
        let signature = ([store.settingsFileDisplayPath()] + problems.map { "\($0.keyPath ?? ""): \($0.message)" })
            .joined(separator: "\n")
        let report = Report(count: problems.count, signature: signature)
        switch state {
        case .showing(let shown, _) where shown == report:
            return
        case .showing:
            // A different result while the notice is up: show the new count in place.
            transition(to: .pending(report))
            presentIfPending()
        case .idle, .pending:
            guard defaults.string(forKey: Self.shownSignatureKey) != signature else {
                transition(to: .idle)
                return
            }
            transition(to: .pending(report))
            presentIfPending()
        }
    }

    private func presentIfPending() {
        guard case .pending(let report) = state,
              let window = Self.targetWindow(),
              let contentView = window.contentView,
              let frameView = contentView.superview else { return }

        let hostingView = NSHostingView(rootView: SettingsFileProblemsNoticeView(
            count: report.count,
            onOpen: { [weak self] in
                self?.transition(to: .idle)
                PreferredEditorSettings.open(KeyboardShortcutSettings.settingsFileStore.settingsFileURLForEditing())
            },
            onDismiss: { [weak self] in self?.transition(to: .idle) }
        ))
        // Window-level chrome: safe-area observation feeds the layout-loop guard (issue #307).
        hostingView.safeAreaRegions = []
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        // Above the content view, so the AppKit-hosted terminals cannot cover it.
        frameView.addSubview(hostingView, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            hostingView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            hostingView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
        ])
        defaults.set(report.signature, forKey: Self.shownSignatureKey)
        transition(to: .showing(report, hostingView))
    }

    private func transition(to newState: State) {
        if case .showing(_, let hostingView) = state {
            hostingView.removeFromSuperview()
        }
        state = newState
    }

    private static func targetWindow() -> NSWindow? {
        if let main = NSApp.mainWindow, main.hasProgramaMainIdentifier, main.isVisible { return main }
        return NSApp.orderedWindows.first { $0.hasProgramaMainIdentifier && $0.isVisible }
    }
}

struct SettingsFileProblemsNoticeView: View {
    let count: Int
    let onOpen: () -> Void
    let onDismiss: () -> Void

    private var title: String {
        count == 1
            ? String(localized: "settingsFile.problems.notice.one", defaultValue: "settings.json has 1 problem")
            : String(
                format: String(localized: "settingsFile.problems.notice.other", defaultValue: "settings.json has %lld problems"),
                count
            )
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.semibold))
                Text(String(
                    localized: "settingsFile.problems.notice.detail",
                    defaultValue: "Run programa config check in a terminal to list them."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Button(String(localized: "settingsFile.problems.notice.open", defaultValue: "Open settings.json"), action: onOpen)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(String(localized: "settingsFile.problems.notice.dismiss", defaultValue: "Dismiss"))
            .help(String(localized: "settingsFile.problems.notice.dismiss", defaultValue: "Dismiss"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor))
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("SettingsFileProblemsNotice")
    }
}
