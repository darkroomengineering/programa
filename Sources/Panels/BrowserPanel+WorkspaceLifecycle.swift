import Foundation
import WebKit
import Bonsplit

extension BrowserPanel {
    private var needsWorkspaceContextReset: Bool {
        shouldRenderWebView ||
        currentURL != nil ||
        !pageTitle.isEmpty ||
        faviconPNGData != nil ||
        searchState != nil ||
        nativeCanGoBack ||
        nativeCanGoForward ||
        restoredHistoryCurrentURL != nil ||
        !restoredBackHistoryStack.isEmpty ||
        !restoredForwardHistoryStack.isEmpty ||
        estimatedProgress > 0 ||
        isLoading ||
        isDownloading ||
        activeDownloadCount != 0 ||
        preferredDeveloperToolsVisible ||
        webView.superview != nil
    }

    func resetForWorkspaceContextChange(reason: String) {
        guard needsWorkspaceContextReset else {
#if DEBUG
            dlog(
                "browser.contextReset.skip panel=\(id.uuidString.prefix(5)) " +
                "reason=\(reason) render=\(shouldRenderWebView ? 1 : 0)"
            )
#endif
            return
        }

#if DEBUG
        dlog(
            "browser.contextReset.begin panel=\(id.uuidString.prefix(5)) " +
            "reason=\(reason) render=\(shouldRenderWebView ? 1 : 0) " +
            "url=\(preferredURLStringForOmnibar() ?? "nil")"
        )
#endif

        _ = hideDeveloperTools()
        cancelDeveloperToolsRestoreRetry()
        setPreferredDeveloperToolsVisible(false)
        preferredDeveloperToolsPresentation = .unknown
        forceDeveloperToolsRefreshOnNextAttach = false
        developerToolsDetachedOpenGraceDeadline = nil
        developerToolsRestoreRetryAttempt = 0
        preferredAttachedDeveloperToolsWidth = nil
        preferredAttachedDeveloperToolsWidthFraction = nil

        loadingEndWorkItem?.cancel()
        loadingEndWorkItem = nil
        faviconTask?.cancel()
        faviconTask = nil
        faviconRefreshGeneration &+= 1
        loadingGeneration &+= 1
        activeDownloadCount = 0
        isDownloading = false
        isLoading = false
        estimatedProgress = 0
        nativeCanGoBack = false
        nativeCanGoForward = false
        navigationDelegate?.lastAttemptedURL = nil
        abandonRestoredSessionHistoryIfNeeded()

        pendingAddressBarFocusRequestId = nil
        preferredFocusIntent = .addressBar
        suppressOmnibarAutofocusUntil = nil
        suppressWebViewFocusUntil = nil
        endSuppressWebViewFocusForAddressBar()
        invalidateAddressBarPageFocusRestoreAttempts()
        invalidateSearchFocusRequests(reason: "contextReset")
        searchState = nil

        pageTitle = ""
        currentURL = nil
        faviconPNGData = nil
        lastFaviconURLString = nil
        activePortalHostLease = nil
        pendingDistinctPortalHostReplacementPaneId = nil
        lockedPortalHost = nil

        let oldWebView = webView
        webViewObservers.removeAll()
        webViewCancellables.removeAll()
        BrowserWindowPortalRegistry.detach(webView: oldWebView)
        oldWebView.stopLoading()
        BrowserJSDialogPresenter.cancelPendingDialog(for: oldWebView)
        oldWebView.navigationDelegate = nil
        oldWebView.uiDelegate = nil
        if let oldProgramaWebView = oldWebView as? ProgramaWebView {
            oldProgramaWebView.onContextMenuDownloadStateChanged = nil
        }

        let replacement = Self.makeWebView(
            profileID: profileID,
            websiteDataStore: websiteDataStore
        )
        webViewInstanceID = UUID()
        webView = replacement
        shouldRenderWebView = false
        bindWebView(replacement)
        applyBrowserThemeModeIfNeeded()
        refreshNavigationAvailability()

#if DEBUG
        dlog(
            "browser.contextReset.end panel=\(id.uuidString.prefix(5)) " +
            "reason=\(reason) instance=\(webViewInstanceID.uuidString.prefix(6))"
        )
#endif
    }
}

func resolveBrowserNavigableURL(_ input: String) -> URL? {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    guard !trimmed.contains(" ") else { return nil }

    let lower = trimmed.lowercased()
    if lower == "about:blank" {
        return URL(string: "about:blank")
    }
    if trimmed.hasPrefix("/") {
        return URL(fileURLWithPath: trimmed)
    }
    // host:port must be matched before generic URL parsing, which reads the host as a
    // scheme ("my-nas:8080", "example.com:8080", "localhost:3777").
    if trimmed.range(of: #"^[^/?#:\s]+:\d{1,5}([/?#].*)?$"#, options: .regularExpression) != nil {
        return URL(string: "http://\(trimmed)")
    }
    if browserInputIsLoopbackHost(lower) {
        return URL(string: "http://\(trimmed)")
    }

    if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() {
        if scheme == "http" || scheme == "https" {
            return url
        }
        if scheme == "file", url.isFileURL, url.path.hasPrefix("/") {
            return url
        }
        return nil
    }

    if trimmed.contains(":") || trimmed.contains("/") {
        return URL(string: "https://\(trimmed)")
    }

    if trimmed.contains(".") {
        return URL(string: "https://\(trimmed)")
    }

    return nil
}

/// Exact loopback host match on the input's host part ("localhostile.com" is not loopback).
private func browserInputIsLoopbackHost(_ lowercasedInput: String) -> Bool {
    let hostEnd = lowercasedInput.firstIndex(where: { "/?#".contains($0) }) ?? lowercasedInput.endIndex
    let hostAndPort = lowercasedInput[..<hostEnd]
    let host: Substring
    if hostAndPort.hasPrefix("["), let close = hostAndPort.firstIndex(of: "]") {
        host = hostAndPort[...close]
    } else {
        host = hostAndPort.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first ?? hostAndPort
    }
    return host == "localhost" || host == "127.0.0.1" || host == "[::1]"
}

extension BrowserPanel {
    func hideBrowserPortalView(source: String) {
        BrowserWindowPortalRegistry.hide(
            webView: webView,
            source: source
        )
    }
}
