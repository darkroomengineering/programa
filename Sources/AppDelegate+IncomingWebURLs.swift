import AppKit
import Bonsplit

/// Web links macOS hands to Programa when it is the default browser (or the user
/// picks it from "Open With"). Each link opens as a browser tab in the focused pane
/// of the active window. Links that arrive before any main window exists (a cold
/// launch from a link click) wait until the first window registers, so session
/// restore still runs and the link lands on top of the restored workspaces.
extension AppDelegate {
    static func isIncomingWebURL(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        return (scheme == "http" || scheme == "https") && url.host?.isEmpty == false
    }

    func openIncomingWebURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard tabManager?.window != nil else {
            pendingIncomingWebURLs.append(contentsOf: urls)
            return
        }
        urls.forEach(openIncomingWebURL)
    }

    func flushPendingIncomingWebURLs() {
        guard !pendingIncomingWebURLs.isEmpty else { return }
        // Additional restored windows are created in a later main-queue turn; open the
        // links after them so a restore cannot replace the workspace they landed in.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let urls = self.pendingIncomingWebURLs
            self.pendingIncomingWebURLs = []
            urls.forEach(self.openIncomingWebURL)
        }
    }

    private func openIncomingWebURL(_ url: URL) {
        guard let tabManager else {
            pendingIncomingWebURLs.append(url)
            return
        }
        let profileID = tabManager.selectedWorkspace?.preferredBrowserProfileID
        var panelId = tabManager.openBrowser(url: url, preferredProfileID: profileID)
        if panelId == nil, addWorkspaceInPreferredMainWindow(debugSource: "application.openWebURL") != nil {
            panelId = self.tabManager?.openBrowser(url: url, preferredProfileID: profileID)
        }
#if DEBUG
        dlog("browser.openIncomingURL opened=\(panelId != nil ? 1 : 0) host=\(url.host ?? "-")")
#endif
        // A link click in another app is an explicit request to see the page, so the
        // window comes forward (unlike socket commands, which must not steal focus).
        guard let window = self.tabManager?.window else { return }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
    }
}
