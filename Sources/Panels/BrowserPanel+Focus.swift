import Foundation
import WebKit
import AppKit
import Bonsplit

extension BrowserPanel {
    func suppressOmnibarAutofocus(for seconds: TimeInterval) {
        suppressOmnibarAutofocusUntil = Date().addingTimeInterval(seconds)
#if DEBUG
        dlog(
            "browser.focus.omnibarAutofocus.suppress panel=\(id.uuidString.prefix(5)) " +
            "seconds=\(String(format: "%.2f", seconds))"
        )
#endif
    }

    func suppressWebViewFocus(for seconds: TimeInterval) {
        suppressWebViewFocusUntil = Date().addingTimeInterval(seconds)
#if DEBUG
        dlog(
            "browser.focus.webView.suppress panel=\(id.uuidString.prefix(5)) " +
            "seconds=\(String(format: "%.2f", seconds))"
        )
#endif
    }

    func clearWebViewFocusSuppression() {
        suppressWebViewFocusUntil = nil
#if DEBUG
        dlog("browser.focus.webView.suppress.clear panel=\(id.uuidString.prefix(5))")
#endif
    }

    func shouldSuppressOmnibarAutofocus() -> Bool {
        if let until = suppressOmnibarAutofocusUntil {
            return Date() < until
        }
        return false
    }

    func shouldSuppressWebViewFocus() -> Bool {
        if suppressWebViewFocusForAddressBar {
            return true
        }
        if searchState != nil {
            return true
        }
        if let until = suppressWebViewFocusUntil {
            return Date() < until
        }
        return false
    }

    func beginSuppressWebViewFocusForAddressBar() {
        let enteringAddressBar = !suppressWebViewFocusForAddressBar
        if enteringAddressBar {
#if DEBUG
            dlog("browser.focus.addressBarSuppress.begin panel=\(id.uuidString.prefix(5))")
#endif
            invalidateAddressBarPageFocusRestoreAttempts()
        }
        suppressWebViewFocusForAddressBar = true
        if enteringAddressBar {
            captureAddressBarPageFocusIfNeeded()
        }
    }

    func endSuppressWebViewFocusForAddressBar() {
        if suppressWebViewFocusForAddressBar {
#if DEBUG
            dlog("browser.focus.addressBarSuppress.end panel=\(id.uuidString.prefix(5))")
#endif
        }
        suppressWebViewFocusForAddressBar = false
    }

    @discardableResult
    func requestAddressBarFocus() -> UUID {
        preferredFocusIntent = .addressBar
        invalidateSearchFocusRequests(reason: "requestAddressBarFocus")
        beginSuppressWebViewFocusForAddressBar()
        if let pendingAddressBarFocusRequestId {
#if DEBUG
            dlog(
                "browser.focus.addressBar.request panel=\(id.uuidString.prefix(5)) " +
                "request=\(pendingAddressBarFocusRequestId.uuidString.prefix(8)) result=reuse_pending"
            )
#endif
            return pendingAddressBarFocusRequestId
        }
        let requestId = UUID()
        pendingAddressBarFocusRequestId = requestId
#if DEBUG
        dlog(
            "browser.focus.addressBar.request panel=\(id.uuidString.prefix(5)) " +
            "request=\(requestId.uuidString.prefix(8)) result=new"
        )
#endif
        return requestId
    }

    func noteWebViewFocused() {
        guard searchState == nil else { return }
        guard preferredFocusIntent != .webView else { return }
        preferredFocusIntent = .webView
        invalidateSearchFocusRequests(reason: "webViewFocused")
    }

    func noteAddressBarFocused() {
        guard preferredFocusIntent != .addressBar else { return }
        preferredFocusIntent = .addressBar
        invalidateSearchFocusRequests(reason: "addressBarFocused")
    }

    func noteFindFieldFocused() {
        guard preferredFocusIntent != .findField else { return }
        preferredFocusIntent = .findField
    }

    func canApplySearchFocusRequest(_ generation: UInt64) -> Bool {
        generation != 0 &&
            generation == searchFocusRequestGeneration &&
            searchState != nil &&
            preferredFocusIntent == .findField
    }

    func captureFocusIntent(in window: NSWindow?) -> PanelFocusIntent {
        if pendingAddressBarFocusRequestId != nil || AppDelegate.shared?.focusedBrowserAddressBarPanelId() == id {
            return .browser(.addressBar)
        }

        if searchState != nil && preferredFocusIntent == .findField {
            return .browser(.findField)
        }

        if let window,
           InspectorDock.responderChainContains(window.firstResponder, target: webView) {
            return .browser(.webView)
        }

        return .browser(preferredFocusIntent)
    }

    func preferredFocusIntentForActivation() -> PanelFocusIntent {
        if pendingAddressBarFocusRequestId != nil {
            return .browser(.addressBar)
        }
        if searchState != nil && preferredFocusIntent == .findField {
            return .browser(.findField)
        }
        return .browser(preferredFocusIntent)
    }

    func prepareFocusIntentForActivation(_ intent: PanelFocusIntent) {
        guard case .browser(let target) = intent else { return }

        switch target {
        case .webView:
            preferredFocusIntent = .webView
            invalidateSearchFocusRequests(reason: "prepareWebView")
            endSuppressWebViewFocusForAddressBar()
        case .addressBar:
            preferredFocusIntent = .addressBar
            invalidateSearchFocusRequests(reason: "prepareAddressBar")
            beginSuppressWebViewFocusForAddressBar()
        case .findField:
            preferredFocusIntent = .findField
        }
#if DEBUG
        dlog(
            "browser.focus.prepare panel=\(id.uuidString.prefix(5)) " +
            "target=\(String(describing: target)) suppressWeb=\(shouldSuppressWebViewFocus() ? 1 : 0)"
        )
#endif
    }

    @discardableResult
    func restoreFocusIntent(_ intent: PanelFocusIntent) -> Bool {
        guard case .browser(let target) = intent else { return false }

        switch target {
        case .webView:
            noteWebViewFocused()
            focus()
            return true
        case .addressBar:
            let requestId = requestAddressBarFocus()
            NotificationCenter.default.post(name: .browserFocusAddressBar, object: id)
#if DEBUG
            dlog(
                "browser.focus.restore panel=\(id.uuidString.prefix(5)) " +
                "target=addressBar request=\(requestId.uuidString.prefix(8))"
            )
#endif
            return true
        case .findField:
            startFind()
            return true
        }
    }

    func ownedFocusIntent(for responder: NSResponder, in window: NSWindow) -> PanelFocusIntent? {
        if AppDelegate.shared?.focusedBrowserAddressBarPanelId() == id {
            return .browser(.addressBar)
        }

        if BrowserWindowPortalRegistry.searchOverlayPanelId(for: responder, in: window) == id {
            return .browser(.findField)
        }

        if InspectorDock.responderChainContains(responder, target: webView) {
            return .browser(.webView)
        }

        return nil
    }

    @discardableResult
    func yieldFocusIntent(_ intent: PanelFocusIntent, in window: NSWindow) -> Bool {
        guard case .browser(let target) = intent else { return false }

        switch target {
        case .findField:
            invalidateSearchFocusRequests(reason: "yieldFindField")
            let yielded = BrowserWindowPortalRegistry.yieldSearchOverlayFocusIfOwned(by: id, in: window)
#if DEBUG
            if yielded {
                dlog("focus.handoff.yield panel=\(id.uuidString.prefix(5)) target=browserFind")
            }
#endif
            return yielded
        case .addressBar:
            guard AppDelegate.shared?.focusedBrowserAddressBarPanelId() == id else { return false }
            let yielded = window.makeFirstResponder(nil)
#if DEBUG
            if yielded {
                dlog("focus.handoff.yield panel=\(id.uuidString.prefix(5)) target=addressBar")
            }
#endif
            return yielded
        case .webView:
            guard InspectorDock.responderChainContains(window.firstResponder, target: webView) else { return false }
            return window.makeFirstResponder(nil)
        }
    }

    @discardableResult
    func beginSearchFocusRequest(reason: String) -> UInt64 {
        searchFocusRequestGeneration &+= 1
#if DEBUG
        dlog(
            "browser.find.focusLease.begin panel=\(id.uuidString.prefix(5)) " +
            "generation=\(searchFocusRequestGeneration) reason=\(reason)"
        )
#endif
        return searchFocusRequestGeneration
    }

    func invalidateSearchFocusRequests(reason: String) {
        searchFocusRequestGeneration &+= 1
#if DEBUG
        dlog(
            "browser.find.focusLease.invalidate panel=\(id.uuidString.prefix(5)) " +
            "generation=\(searchFocusRequestGeneration) reason=\(reason)"
        )
#endif
    }

    func acknowledgeAddressBarFocusRequest(_ requestId: UUID) {
        guard pendingAddressBarFocusRequestId == requestId else {
#if DEBUG
            dlog(
                "browser.focus.addressBar.requestAck panel=\(id.uuidString.prefix(5)) " +
                "request=\(requestId.uuidString.prefix(8)) result=ignored " +
                "pending=\(pendingAddressBarFocusRequestId?.uuidString.prefix(8) ?? "nil")"
            )
#endif
            return
        }
        pendingAddressBarFocusRequestId = nil
#if DEBUG
        dlog(
            "browser.focus.addressBar.requestAck panel=\(id.uuidString.prefix(5)) " +
            "request=\(requestId.uuidString.prefix(8)) result=cleared"
        )
#endif
    }

    private func captureAddressBarPageFocusIfNeeded() {
        webView.evaluateJavaScript(Self.addressBarFocusCaptureScript) { [weak self] result, error in
#if DEBUG
            guard let self else { return }
            if let error {
                dlog(
                    "browser.focus.addressBar.capture panel=\(self.id.uuidString.prefix(5)) " +
                    "result=error message=\(error.localizedDescription)"
                )
                return
            }
            let resultValue = (result as? String) ?? "unknown"
            dlog(
                "browser.focus.addressBar.capture panel=\(self.id.uuidString.prefix(5)) " +
                "result=\(resultValue)"
            )
#else
            _ = self
            _ = result
            _ = error
#endif
        }
    }

    private enum AddressBarPageFocusRestoreStatus: String {
        case restored
        case noState = "no_state"
        case missingTarget = "missing_target"
        case notFocused = "not_focused"
        case error
    }

    private static func addressBarPageFocusRestoreStatus(
        from result: Any?,
        error: Error?
    ) -> AddressBarPageFocusRestoreStatus {
        if error != nil { return .error }
        guard let raw = result as? String else { return .error }
        return AddressBarPageFocusRestoreStatus(rawValue: raw) ?? .error
    }

    func invalidateAddressBarPageFocusRestoreAttempts() {
        addressBarFocusRestoreGeneration &+= 1
#if DEBUG
        dlog(
            "browser.focus.addressBar.restore.invalidate panel=\(id.uuidString.prefix(5)) " +
            "generation=\(addressBarFocusRestoreGeneration)"
        )
#endif
    }

    func restoreAddressBarPageFocusIfNeeded(completion: @escaping (Bool) -> Void) {
        addressBarFocusRestoreGeneration &+= 1
        let generation = addressBarFocusRestoreGeneration
        let delays: [TimeInterval] = [0.0, 0.03, 0.09, 0.2]
        restoreAddressBarPageFocusAttemptIfNeeded(
            attempt: 0,
            delays: delays,
            generation: generation,
            completion: completion
        )
    }

    private func restoreAddressBarPageFocusAttemptIfNeeded(
        attempt: Int,
        delays: [TimeInterval],
        generation: UInt64,
        completion: @escaping (Bool) -> Void
    ) {
        guard generation == addressBarFocusRestoreGeneration else {
            completion(false)
            return
        }
        webView.evaluateJavaScript(Self.addressBarFocusRestoreScript) { [weak self] result, error in
            guard let self else {
                completion(false)
                return
            }
            guard generation == self.addressBarFocusRestoreGeneration else {
                completion(false)
                return
            }

            let status = Self.addressBarPageFocusRestoreStatus(from: result, error: error)
            let canRetry = (status == .notFocused || status == .error)
            let hasNextAttempt = attempt + 1 < delays.count

#if DEBUG
            if let error {
                dlog(
                    "browser.focus.addressBar.restore panel=\(self.id.uuidString.prefix(5)) " +
                    "attempt=\(attempt) status=\(status.rawValue) " +
                    "message=\(error.localizedDescription)"
                )
            } else {
                dlog(
                    "browser.focus.addressBar.restore panel=\(self.id.uuidString.prefix(5)) " +
                    "attempt=\(attempt) status=\(status.rawValue)"
                )
            }
#endif

            if status == .restored {
                completion(true)
                return
            }

            if canRetry && hasNextAttempt {
                let delay = delays[attempt + 1]
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self else {
                        completion(false)
                        return
                    }
                    guard generation == self.addressBarFocusRestoreGeneration else {
                        completion(false)
                        return
                    }
                    self.restoreAddressBarPageFocusAttemptIfNeeded(
                        attempt: attempt + 1,
                        delays: delays,
                        generation: generation,
                        completion: completion
                    )
                }
                return
            }

            completion(false)
        }
    }
}
