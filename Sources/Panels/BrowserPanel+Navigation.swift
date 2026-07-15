import Foundation
import WebKit
import AppKit
import Bonsplit

extension BrowserPanel {

    /// Go back in history
    func goBack() {
        guard canGoBack else { return }
        if usesRestoredSessionHistory {
            realignRestoredSessionHistoryToLiveCurrentIfPossible()

            if (isLiveSessionHistoryAlignedWithRestoredCurrent || !nativeCanGoBack),
               let targetURL = restoredBackHistoryStack.popLast() {
                if let current = resolvedCurrentSessionHistoryURL() {
                    restoredForwardHistoryStack.append(current)
                }
                restoredHistoryCurrentURL = targetURL
                refreshNavigationAvailability()
                navigateWithoutInsecureHTTPPrompt(
                    to: targetURL,
                    recordTypedNavigation: false,
                    preserveRestoredSessionHistory: true
                )
                return
            }

            if nativeCanGoBack {
                webView.goBack()
                return
            }

            refreshNavigationAvailability()
            return
        }

        webView.goBack()
    }

    /// Go forward in history
    func goForward() {
        guard canGoForward else { return }
        if usesRestoredSessionHistory {
            realignRestoredSessionHistoryToLiveCurrentIfPossible()

            if nativeCanGoForward {
                webView.goForward()
                return
            }

            guard let targetURL = restoredForwardHistoryStack.popLast() else {
                refreshNavigationAvailability()
                return
            }
            if let current = resolvedCurrentSessionHistoryURL() {
                restoredBackHistoryStack.append(current)
            }
            restoredHistoryCurrentURL = targetURL
            refreshNavigationAvailability()
            navigateWithoutInsecureHTTPPrompt(
                to: targetURL,
                recordTypedNavigation: false,
                preserveRestoredSessionHistory: true
            )
            return
        }

        webView.goForward()
    }

    /// Open a link in a new browser surface in the same pane
    func openLinkInNewTab(url: URL, bypassInsecureHTTPHostOnce: String? = nil) {
#if DEBUG
        dlog(
            "browser.newTab.open.begin panel=\(id.uuidString.prefix(5)) " +
            "workspace=\(workspaceId.uuidString.prefix(5)) url=\(url.absoluteString) " +
            "bypass=\(bypassInsecureHTTPHostOnce ?? "nil")"
        )
#endif
        guard let app = AppDelegate.shared else {
#if DEBUG
            dlog("browser.newTab.open.abort panel=\(id.uuidString.prefix(5)) reason=missingAppDelegate")
#endif
            return
        }
        guard let workspace = app.workspaceContainingPanel(
            panelId: id,
            preferredWorkspaceId: workspaceId
        )?.workspace else {
#if DEBUG
            dlog("browser.newTab.open.abort panel=\(id.uuidString.prefix(5)) reason=workspaceMissing")
#endif
            return
        }
        guard let paneId = workspace.paneId(forPanelId: id) else {
#if DEBUG
            dlog("browser.newTab.open.abort panel=\(id.uuidString.prefix(5)) reason=paneMissing")
#endif
            return
        }
        workspace.newBrowserSurface(
            inPane: paneId,
            url: url,
            focus: true,
            preferredProfileID: profileID,
            bypassInsecureHTTPHostOnce: bypassInsecureHTTPHostOnce
        )
#if DEBUG
        dlog(
            "browser.newTab.open.done panel=\(id.uuidString.prefix(5)) " +
            "workspace=\(workspace.id.uuidString.prefix(5)) pane=\(paneId.id.uuidString.prefix(5))"
        )
#endif
    }

    /// Reload the current page
    func reload() {
        webView.customUserAgent = BrowserUserAgentSettings.safariUserAgent
        if Self.serializableSessionHistoryURLString(Self.remoteProxyDisplayURL(for: webView.url)) == nil {
            let fallbackURL = resolvedCurrentSessionHistoryURL()
                ?? Self.remoteProxyDisplayURL(for: navigationDelegate?.lastAttemptedURL)

            if let fallbackURL,
               Self.serializableSessionHistoryURLString(fallbackURL) != nil {
                navigateWithoutInsecureHTTPPrompt(
                    to: fallbackURL,
                    recordTypedNavigation: false,
                    preserveRestoredSessionHistory: usesRestoredSessionHistory
                )
                return
            }
        }
        webView.reload()
    }

    /// Stop loading
    func stopLoading() {
        webView.stopLoading()
    }

    /// Returns the most reliable URL string for omnibar-related matching and UI decisions.
    /// `currentURL` can lag behind navigation changes, so prefer the live WKWebView URL.
    func preferredURLStringForOmnibar() -> String? {
        if let webViewURL = Self.remoteProxyDisplayURL(for: webView.url)?.absoluteString
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !webViewURL.isEmpty,
           webViewURL != blankURLString {
            return webViewURL
        }

        if let current = currentURL?.absoluteString
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !current.isEmpty,
           current != blankURLString {
            return current
        }

        return nil
    }

    private func resolvedCurrentSessionHistoryURL() -> URL? {
        if let webViewURL = Self.remoteProxyDisplayURL(for: webView.url),
           Self.serializableSessionHistoryURLString(webViewURL) != nil {
            return webViewURL
        }
        if let currentURL,
           Self.serializableSessionHistoryURLString(currentURL) != nil {
            return currentURL
        }
        return restoredHistoryCurrentURL
    }

    func refreshNavigationAvailability() {
        let resolvedCanGoBack: Bool
        let resolvedCanGoForward: Bool
        if usesRestoredSessionHistory {
            resolvedCanGoBack = nativeCanGoBack || !restoredBackHistoryStack.isEmpty
            resolvedCanGoForward = nativeCanGoForward || !restoredForwardHistoryStack.isEmpty
        } else {
            resolvedCanGoBack = nativeCanGoBack
            resolvedCanGoForward = nativeCanGoForward
        }

        if canGoBack != resolvedCanGoBack {
            canGoBack = resolvedCanGoBack
        }
        if canGoForward != resolvedCanGoForward {
            canGoForward = resolvedCanGoForward
        }
    }

    func abandonRestoredSessionHistoryIfNeeded() {
        guard usesRestoredSessionHistory else { return }
        usesRestoredSessionHistory = false
        restoredBackHistoryStack.removeAll(keepingCapacity: false)
        restoredForwardHistoryStack.removeAll(keepingCapacity: false)
        restoredHistoryCurrentURL = nil
        refreshNavigationAvailability()
    }
}

#if DEBUG
extension BrowserPanel {
    func configureInsecureHTTPAlertHooksForTesting(
        alertFactory: @escaping () -> NSAlert,
        windowProvider: @escaping () -> NSWindow?
    ) {
        insecureHTTPAlertFactory = alertFactory
        insecureHTTPAlertWindowProvider = windowProvider
    }

    func resetInsecureHTTPAlertHooksForTesting() {
        insecureHTTPAlertFactory = { NSAlert() }
        insecureHTTPAlertWindowProvider = { [weak self] in
            self?.webView.window ?? NSApp.keyWindow ?? NSApp.mainWindow
        }
    }

    func presentInsecureHTTPAlertForTesting(
        url: URL,
        recordTypedNavigation: Bool = false
    ) {
        presentInsecureHTTPAlert(
            for: URLRequest(url: url),
            intent: .currentTab,
            recordTypedNavigation: recordTypedNavigation
        )
    }
}
#endif
