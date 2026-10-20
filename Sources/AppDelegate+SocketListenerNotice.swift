import AppKit

/// Tells the user, once per launch, that the control socket listener could not start (the CLI and
/// agent hooks cannot reach the app without it). The notice is a sheet on the key main window and
/// only appears while the app is already active, so it never activates the app or steals focus; a
/// failure that happens in the background waits for the next activation or key-window change.
@MainActor
final class SocketListenerFailureNotice {
    private var failure: (path: String, error: String)?
    private var didPresent = false
    private var observers: [NSObjectProtocol] = []
    private var sheetWindow: () -> NSWindow? = { nil }

    func install(sheetWindow: @escaping () -> NSWindow?) {
        guard observers.isEmpty else { return }
        self.sheetWindow = sheetWindow
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .socketListenerDidFail, object: nil, queue: .main) { [weak self] note in
                let path = note.userInfo?["path"] as? String ?? ""
                let error = note.userInfo?["error"] as? String ?? ""
                MainActor.assumeIsolated {
                    guard let self, !self.didPresent else { return }
                    self.failure = (path, error)
                    // Never present from inside the listener start (it runs in SwiftUI onAppear).
                    DispatchQueue.main.async { [weak self] in
                        MainActor.assumeIsolated { self?.presentIfPossible() }
                    }
                }
            },
            center.addObserver(forName: .socketListenerDidStart, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.failure = nil }
            },
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.presentIfPossible() }
            },
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.presentIfPossible() }
            },
        ]
    }

    private func presentIfPossible() {
        guard let failure, !didPresent, NSApp.isActive, NSApp.modalWindow == nil,
              let window = sheetWindow(), window.attachedSheet == nil else { return }
        didPresent = true
        self.failure = nil
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "socketListener.failed.title",
            defaultValue: "Programa could not start its control socket"
        )
        alert.informativeText = String(
            localized: "socketListener.failed.message",
            defaultValue: "The programa CLI and agent hooks cannot reach this app until the socket starts. Run Restart CLI Listener from the command palette, or relaunch Programa.\n\nSocket: \(failure.path)\nError: \(failure.error)"
        )
        alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
        alert.beginSheetModal(for: window)
    }
}

extension AppDelegate {
    func installSocketListenerFailureNotice() {
        socketListenerFailureNotice.install { [weak self] in
            guard let self, let window = NSApp.keyWindow, self.isMainTerminalWindow(window) else { return nil }
            return window
        }
    }
}
