import Foundation

/// Owns browser JSON-RPC method classification and dispatch. TerminalController remains
/// responsible for framing JSON-RPC responses and applying the returned effect/result.
@MainActor
final class BrowserRPCDispatcher {
    typealias Params = [String: Any]
    typealias Result = TerminalController.V2CallResult
    typealias Route = (TerminalController, Params) -> Result

    private static let routes: [String: Route] = [
        "browser.open_split": { $0.v2BrowserOpenSplit(params: $1) },
        "browser.navigate": { $0.v2BrowserNavigate(params: $1) },
        "browser.back": { $0.v2BrowserBack(params: $1) },
        "browser.forward": { $0.v2BrowserForward(params: $1) },
        "browser.reload": { $0.v2BrowserReload(params: $1) },
        "browser.url.get": { $0.v2BrowserGetURL(params: $1) },
        "browser.focus_webview": { $0.v2BrowserFocusWebView(params: $1) },
        "browser.is_webview_focused": { $0.v2BrowserIsWebViewFocused(params: $1) },
        "browser.snapshot": { $0.v2BrowserSnapshot(params: $1) },
        "browser.eval": { $0.v2BrowserEval(params: $1) },
        "browser.wait": { $0.v2BrowserWait(params: $1) },
        "browser.click": { $0.v2BrowserClick(params: $1) },
        "browser.dblclick": { $0.v2BrowserDblClick(params: $1) },
        "browser.hover": { $0.v2BrowserHover(params: $1) },
        "browser.focus": { $0.v2BrowserFocusElement(params: $1) },
        "browser.type": { $0.v2BrowserType(params: $1) },
        "browser.fill": { $0.v2BrowserFill(params: $1) },
        "browser.press": { $0.v2BrowserPress(params: $1) },
        "browser.keydown": { $0.v2BrowserKeyDown(params: $1) },
        "browser.keyup": { $0.v2BrowserKeyUp(params: $1) },
        "browser.check": { $0.v2BrowserCheck(params: $1, checked: true) },
        "browser.uncheck": { $0.v2BrowserCheck(params: $1, checked: false) },
        "browser.select": { $0.v2BrowserSelect(params: $1) },
        "browser.scroll": { $0.v2BrowserScroll(params: $1) },
        "browser.scroll_into_view": { $0.v2BrowserScrollIntoView(params: $1) },
        "browser.screenshot": { $0.v2BrowserScreenshot(params: $1) },
        "browser.get.text": { $0.v2BrowserGetText(params: $1) },
        "browser.get.html": { $0.v2BrowserGetHTML(params: $1) },
        "browser.get.value": { $0.v2BrowserGetValue(params: $1) },
        "browser.get.attr": { $0.v2BrowserGetAttr(params: $1) },
        "browser.get.title": { $0.v2BrowserGetTitle(params: $1) },
        "browser.get.count": { $0.v2BrowserGetCount(params: $1) },
        "browser.get.box": { $0.v2BrowserGetBox(params: $1) },
        "browser.get.styles": { $0.v2BrowserGetStyles(params: $1) },
        "browser.is.visible": { $0.v2BrowserIsVisible(params: $1) },
        "browser.is.enabled": { $0.v2BrowserIsEnabled(params: $1) },
        "browser.is.checked": { $0.v2BrowserIsChecked(params: $1) },
        "browser.find.role": { $0.v2BrowserFindRole(params: $1) },
        "browser.find.text": { $0.v2BrowserFindText(params: $1) },
        "browser.find.label": { $0.v2BrowserFindLabel(params: $1) },
        "browser.find.placeholder": { $0.v2BrowserFindPlaceholder(params: $1) },
        "browser.find.alt": { $0.v2BrowserFindAlt(params: $1) },
        "browser.find.title": { $0.v2BrowserFindTitle(params: $1) },
        "browser.find.testid": { $0.v2BrowserFindTestId(params: $1) },
        "browser.find.first": { $0.v2BrowserFindFirst(params: $1) },
        "browser.find.last": { $0.v2BrowserFindLast(params: $1) },
        "browser.find.nth": { $0.v2BrowserFindNth(params: $1) },
        "browser.frame.select": { $0.v2BrowserFrameSelect(params: $1) },
        "browser.frame.main": { $0.v2BrowserFrameMain(params: $1) },
        "browser.dialog.accept": { $0.v2BrowserDialogRespond(params: $1, accept: true) },
        "browser.dialog.dismiss": { $0.v2BrowserDialogRespond(params: $1, accept: false) },
        "browser.download.wait": { $0.v2BrowserDownloadWait(params: $1) },
        "browser.cookies.get": { $0.v2BrowserCookiesGet(params: $1) },
        "browser.cookies.set": { $0.v2BrowserCookiesSet(params: $1) },
        "browser.cookies.clear": { $0.v2BrowserCookiesClear(params: $1) },
        "browser.storage.get": { $0.v2BrowserStorageGet(params: $1) },
        "browser.storage.set": { $0.v2BrowserStorageSet(params: $1) },
        "browser.storage.clear": { $0.v2BrowserStorageClear(params: $1) },
        "browser.tab.new": { $0.v2BrowserTabNew(params: $1) },
        "browser.tab.list": { $0.v2BrowserTabList(params: $1) },
        "browser.tab.switch": { $0.v2BrowserTabSwitch(params: $1) },
        "browser.tab.close": { $0.v2BrowserTabClose(params: $1) },
        "browser.console.list": { $0.v2BrowserConsoleList(params: $1) },
        "browser.console.clear": { $0.v2BrowserConsoleClear(params: $1) },
        "browser.errors.list": { $0.v2BrowserErrorsList(params: $1) },
        "browser.highlight": { $0.v2BrowserHighlight(params: $1) },
        "browser.state.save": { $0.v2BrowserStateSave(params: $1) },
        "browser.state.load": { $0.v2BrowserStateLoad(params: $1) },
        "browser.addinitscript": { $0.v2BrowserAddInitScript(params: $1) },
        "browser.addscript": { $0.v2BrowserAddScript(params: $1) },
        "browser.addstyle": { $0.v2BrowserAddStyle(params: $1) },
        "browser.design_mode.toggle": { $0.v2BrowserDesignModeToggle(params: $1) },
    ]

    func dispatch(method: String, params: Params, controller: TerminalController) -> Result? {
        Self.routes[method]?(controller, params)
    }

    static func recognizes(_ method: String) -> Bool {
        routes[method] != nil
    }
}

/// Mutable browser automation session state has one lifecycle owner. Compatibility accessors
/// on TerminalController keep the automation algorithms focused on behavior during migration.
@MainActor
final class BrowserRPCState {
    var nextElementOrdinal = 1
    var elementRefs: [String: TerminalController.V2BrowserElementRefEntry] = [:]
    var elementRefTokensBySurface: [UUID: Set<String>] = [:]
    var elementRefBySelectorBySurface: [UUID: [String: String]] = [:]
    var elementRefBytesBySurface: [UUID: Int] = [:]
    var frameSelectorBySurface: [UUID: String] = [:]
    var navigationGenerationBySurface: [UUID: UInt64] = [:]
    var initScriptsBySurface: [UUID: [String]] = [:]
    var initStylesBySurface: [UUID: [String]] = [:]
    var downloadEventsBySurface: [UUID: [[String: Any]]] = [:]
    var downloadDroppedEventCountBySurface: [UUID: Int] = [:]
    var pendingDownloadEventWaiter: TerminalController.V2BrowserDownloadEventWaiter?
    let undefinedSentinel = TerminalController.V2BrowserUndefinedSentinel()

    func navigationGeneration(for surfaceId: UUID) -> UInt64 {
        navigationGenerationBySurface[surfaceId] ?? 0
    }

    func advanceNavigationGeneration(for surfaceId: UUID) {
        let previousGeneration = navigationGeneration(for: surfaceId)
        let ownedTokens = elementRefTokensBySurface[surfaceId] ?? []
        var retainedTokens: Set<String> = []
        for token in ownedTokens {
            guard let entry = elementRefs[token], entry.navigationGeneration == previousGeneration else {
                elementRefs.removeValue(forKey: token)
                continue
            }
            retainedTokens.insert(token)
        }
        elementRefTokensBySurface[surfaceId] = retainedTokens.isEmpty ? nil : retainedTokens
        navigationGenerationBySurface[surfaceId] = previousGeneration + 1
        elementRefBySelectorBySurface.removeValue(forKey: surfaceId)
        elementRefBytesBySurface.removeValue(forKey: surfaceId)
    }

    func allocateElementRefs(
        surfaceId: UUID,
        selectors: [String]
    ) -> TerminalController.V2BrowserElementRefAllocation {
        var selectorIndex = elementRefBySelectorBySurface[surfaceId] ?? [:]
        var unseenSelectors: Set<String> = []
        var requestedBytes = 0
        var hasOversizedSelector = false
        for selector in selectors where selectorIndex[selector] == nil {
            guard unseenSelectors.insert(selector).inserted else { continue }
            let byteCount = selector.utf8.count
            hasOversizedSelector = hasOversizedSelector
                || byteCount > TerminalController.v2BrowserElementRefSelectorByteLimit
            let (sum, overflow) = requestedBytes.addingReportingOverflow(byteCount)
            requestedBytes = overflow ? Int.max : sum
        }
        let currentBytes = elementRefBytesBySurface[surfaceId] ?? 0
        let remaining = max(0, TerminalController.v2BrowserElementRefLimit - selectorIndex.count)
        let remainingBytes = max(0, TerminalController.v2BrowserElementRefByteLimit - currentBytes)
        let capacity = TerminalController.V2BrowserElementRefCapacity(
            limit: TerminalController.v2BrowserElementRefLimit,
            requestedUnique: unseenSelectors.count,
            remaining: remaining,
            selectorByteLimit: TerminalController.v2BrowserElementRefSelectorByteLimit,
            byteLimit: TerminalController.v2BrowserElementRefByteLimit,
            requestedBytes: requestedBytes,
            remainingBytes: remainingBytes
        )
        guard !hasOversizedSelector,
              unseenSelectors.count <= remaining,
              requestedBytes <= remainingBytes else { return .resourceExhausted(capacity) }

        let generation = navigationGeneration(for: surfaceId)
        var ownedTokens = elementRefTokensBySurface[surfaceId] ?? []
        var refs: [String] = []
        for selector in selectors {
            if let existingRef = selectorIndex[selector] {
                refs.append(existingRef)
                continue
            }
            let ref = "@e\(nextElementOrdinal)"
            nextElementOrdinal += 1
            elementRefs[ref] = TerminalController.V2BrowserElementRefEntry(
                surfaceId: surfaceId,
                selector: selector,
                navigationGeneration: generation
            )
            selectorIndex[selector] = ref
            ownedTokens.insert(ref)
            refs.append(ref)
        }
        elementRefBySelectorBySurface[surfaceId] = selectorIndex
        elementRefTokensBySurface[surfaceId] = ownedTokens
        elementRefBytesBySurface[surfaceId] = currentBytes + requestedBytes
        return .allocated(refs)
    }

    func enqueueDownloadEvent(surfaceId: UUID, event: [String: Any]) {
        if let waiter = pendingDownloadEventWaiter, waiter.surfaceId == surfaceId {
            pendingDownloadEventWaiter = nil
            let dropped = downloadDroppedEventCountBySurface.removeValue(forKey: surfaceId) ?? 0
            waiter.finish(.event(event, droppedEvents: dropped))
            return
        }
        var queue = downloadEventsBySurface[surfaceId] ?? []
        queue.append(event)
        let overflow = max(0, queue.count - TerminalController.v2BrowserDownloadEventQueueLimit)
        if overflow > 0 {
            queue.removeFirst(overflow)
            downloadDroppedEventCountBySurface[surfaceId, default: 0] += overflow
        }
        downloadEventsBySurface[surfaceId] = queue
    }

    func consumeDownloadEvent(surfaceId: UUID) -> (event: [String: Any], droppedEvents: Int)? {
        guard var queue = downloadEventsBySurface[surfaceId], !queue.isEmpty else { return nil }
        let event = queue.removeFirst()
        downloadEventsBySurface[surfaceId] = queue.isEmpty ? nil : queue
        let dropped = downloadDroppedEventCountBySurface.removeValue(forKey: surfaceId) ?? 0
        return (event, dropped)
    }

    func permanentlyRemoveSurface(_ surfaceId: UUID) {
        let waiter = pendingDownloadEventWaiter?.surfaceId == surfaceId ? pendingDownloadEventWaiter : nil
        if waiter != nil { pendingDownloadEventWaiter = nil }
        for token in elementRefTokensBySurface.removeValue(forKey: surfaceId) ?? [] {
            elementRefs.removeValue(forKey: token)
        }
        elementRefBySelectorBySurface.removeValue(forKey: surfaceId)
        elementRefBytesBySurface.removeValue(forKey: surfaceId)
        navigationGenerationBySurface.removeValue(forKey: surfaceId)
        initScriptsBySurface.removeValue(forKey: surfaceId)
        initStylesBySurface.removeValue(forKey: surfaceId)
        downloadEventsBySurface.removeValue(forKey: surfaceId)
        downloadDroppedEventCountBySurface.removeValue(forKey: surfaceId)
        frameSelectorBySurface.removeValue(forKey: surfaceId)
        waiter?.finish(.cancelled)
    }
}
