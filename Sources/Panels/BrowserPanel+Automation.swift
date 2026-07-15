import Foundation
import WebKit
import AppKit
import Bonsplit

extension BrowserPanel {
    @discardableResult
    func zoomIn() -> Bool {
        applyPageZoom(webView.pageZoom + pageZoomStep)
    }

    @discardableResult
    func zoomOut() -> Bool {
        applyPageZoom(webView.pageZoom - pageZoomStep)
    }

    @discardableResult
    func resetZoom() -> Bool {
        applyPageZoom(1.0)
    }

    func currentPageZoomFactor() -> CGFloat {
        webView.pageZoom
    }

    @discardableResult
    func setPageZoomFactor(_ pageZoom: CGFloat) -> Bool {
        let clamped = max(minPageZoom, min(maxPageZoom, pageZoom))
        return applyPageZoom(clamped)
    }

    /// Take a snapshot of the web view
    func takeSnapshot(completion: @escaping (NSImage?) -> Void) {
        let config = WKSnapshotConfiguration()
        webView.takeSnapshot(with: config) { image, error in
            if let error = error {
                NSLog("BrowserPanel snapshot error: %@", error.localizedDescription)
                completion(nil)
                return
            }
            completion(image)
        }
    }

    /// Execute JavaScript
    func evaluateJavaScript(_ script: String) async throws -> Any? {
        try await webView.evaluateJavaScript(script)
    }

    // MARK: - Find in Page

    func startFind() {
        preferredFocusIntent = .findField
        let created = searchState == nil
        if created {
            searchState = BrowserSearchState()
        }
        pendingAddressBarFocusRequestId = nil
        NotificationCenter.default.post(name: .browserDidBlurAddressBar, object: id)
        let generation = beginSearchFocusRequest(reason: "startFind")
#if DEBUG
        let window = webView.window
        dlog(
            "browser.find.start panel=\(id.uuidString.prefix(5)) " +
            "created=\(created ? 1 : 0) render=\(shouldRenderWebView ? 1 : 0) " +
            "generation=\(generation) " +
            "window=\(window?.windowNumber ?? -1) key=\(NSApp.keyWindow === window ? 1 : 0) " +
            "firstResponder=\(String(describing: window?.firstResponder))"
        )
#endif
        postBrowserSearchFocusNotification(reason: "immediate", generation: generation)
        // Focus notification can race with portal overlay mount. Re-post on the
        // next runloop and shortly after so the find field can claim first responder.
        DispatchQueue.main.async { [weak self] in
            self?.postBrowserSearchFocusNotification(reason: "async0", generation: generation)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.postBrowserSearchFocusNotification(reason: "async50ms", generation: generation)
        }
    }

    private func postBrowserSearchFocusNotification(reason: String, generation: UInt64) {
        guard canApplySearchFocusRequest(generation) else {
#if DEBUG
            dlog(
                "browser.find.focusNotification.skip panel=\(id.uuidString.prefix(5)) " +
                "reason=\(reason) generation=\(generation)"
            )
#endif
            return
        }
#if DEBUG
        let window = webView.window
        dlog(
            "browser.find.focusNotification panel=\(id.uuidString.prefix(5)) " +
            "generation=\(generation) " +
            "reason=\(reason) window=\(window?.windowNumber ?? -1) " +
            "firstResponder=\(String(describing: window?.firstResponder))"
        )
#endif
        NotificationCenter.default.post(name: .browserSearchFocus, object: id)
    }

    func findNext() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = try? await self.webView.evaluateJavaScript(BrowserFindJavaScript.nextScript())
            self.parseFindResult(result)
        }
    }

    func findPrevious() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = try? await self.webView.evaluateJavaScript(BrowserFindJavaScript.previousScript())
            self.parseFindResult(result)
        }
    }

    func hideFind() {
        invalidateSearchFocusRequests(reason: "hideFind")
        searchState = nil
    }

    func restoreFindStateAfterNavigation(replaySearch: Bool) {
        guard let state = searchState else { return }
        state.total = nil
        state.selected = nil
        if replaySearch, !state.needle.isEmpty {
            executeFindSearch(state.needle)
        }
        postBrowserSearchFocusNotification(
            reason: "restoreAfterNavigation",
            generation: searchFocusRequestGeneration
        )
    }

    func executeFindSearch(_ needle: String) {
        guard !needle.isEmpty else {
            executeFindClear()
            searchState?.selected = nil
            searchState?.total = nil
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let js = BrowserFindJavaScript.searchScript(query: needle)
            do {
                let result = try await self.webView.evaluateJavaScript(js)
                self.parseFindResult(result)
            } catch {
                NSLog("Find: browser JS search error: %@", error.localizedDescription)
            }
        }
    }

    func executeFindClear() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await self.webView.evaluateJavaScript(BrowserFindJavaScript.clearScript())
            } catch {
                NSLog("Find: browser JS clear error: %@", error.localizedDescription)
            }
        }
    }

    private func parseFindResult(_ result: Any?) {
        guard let jsonString = result as? String,
              let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let total = json["total"] as? Int,
              let current = json["current"] as? Int,
              total >= 0, current >= 0 else {
            return
        }
        searchState?.total = UInt(total)
        searchState?.selected = total > 0 ? UInt(current) : nil
    }
}

private extension BrowserPanel {
    @discardableResult
    func applyPageZoom(_ candidate: CGFloat) -> Bool {
        let clamped = max(minPageZoom, min(maxPageZoom, candidate))
        if abs(webView.pageZoom - clamped) < 0.0001 {
            return false
        }
        webView.pageZoom = clamped
        return true
    }
}
