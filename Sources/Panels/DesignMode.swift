import Foundation
import WebKit
import AppKit
import Bonsplit

// MARK: - Design Mode
//
// Design Mode is a click-to-select picker for the in-app browser panel. It does not fetch any
// script over the network -- the picker is a fully self-contained JS string embedded below.
//
// Flow: TabManager.toggleDesignModeFromCurrentFocus() / the "browser.design_mode.toggle" socket
// method both call `activateDesignModeRoute(in:)`, which resolves a route via
// `resolveDesignModeShortcutRoute` below (the focused-panel routing rule is panel-agnostic;
// it originated in the removed React Grab feature, see docs/removed/browser-react-grab.md),
// arms a round trip on the target BrowserPanel, and
// injects/toggles the picker script. When the user clicks an element, the picker posts a `pick`
// message across the bridge; BrowserPanel crops a screenshot and posts `.designModeDidCapture`,
// which AppDelegate observes to write the screenshot to disk, compose the text block, and deliver
// it to the return terminal panel via the shared `sendTextWhenReady` pasteback path.

// MARK: - Shared panel routing

struct DesignModeShortcutPanelSnapshot: Equatable {
    let id: UUID
    let panelType: PanelType
    let isFocused: Bool
}

struct DesignModeShortcutRoute: Equatable {
    let browserPanelId: UUID
    let returnTerminalPanelId: UUID?
}

func resolveDesignModeShortcutRoute(
    panels: [DesignModeShortcutPanelSnapshot]
) -> DesignModeShortcutRoute? {
    guard let focusedPanel = panels.first(where: \.isFocused) else { return nil }

    if focusedPanel.panelType == .browser {
        return DesignModeShortcutRoute(
            browserPanelId: focusedPanel.id,
            returnTerminalPanelId: nil
        )
    }

    guard focusedPanel.panelType == .terminal else { return nil }

    let browserPanels = panels.filter { $0.panelType == .browser }
    guard browserPanels.count == 1, let browserPanel = browserPanels.first else {
        return nil
    }

    return DesignModeShortcutRoute(
        browserPanelId: browserPanel.id,
        returnTerminalPanelId: focusedPanel.id
    )
}

// MARK: - Payload

struct DesignModePickRect: Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct DesignModePickPayload: Equatable {
    static let htmlTruncationLimit = 4000
    static let truncationMarker = "\n... [truncated]"
    static let fieldLengthLimit = 2000

    let html: String
    let css: [String: String]
    let selector: String
    let rect: DesignModePickRect
    let url: String

    init(html: String, css: [String: String], selector: String, rect: DesignModePickRect, url: String) {
        self.html = Self.truncatedHTML(html)
        // The page script is untrusted and these fields land in a terminal: no line breaks, bounded length.
        var cleanCSS: [String: String] = [:]
        for (key, value) in css {
            cleanCSS[Self.singleLine(key)] = Self.singleLine(value)
        }
        self.css = cleanCSS
        self.selector = Self.singleLine(selector)
        self.rect = rect
        self.url = Self.singleLine(url)
    }

    static func singleLine(_ value: String) -> String {
        let stripped = value.unicodeScalars.filter { $0 != "\n" && $0 != "\r" }
        return String(String.UnicodeScalarView(stripped).prefix(fieldLengthLimit))
    }

    /// Parses the `pick` message body posted from the injected picker script.
    init?(body: [String: Any]) {
        guard let html = body["html"] as? String,
              let selector = body["selector"] as? String,
              let url = body["url"] as? String,
              let rectDict = body["rect"] as? [String: Any],
              let x = Self.doubleValue(rectDict["x"]),
              let y = Self.doubleValue(rectDict["y"]),
              let width = Self.doubleValue(rectDict["width"]),
              let height = Self.doubleValue(rectDict["height"]) else {
            return nil
        }
        var cssOut: [String: String] = [:]
        if let cssDict = body["css"] as? [String: Any] {
            for (key, value) in cssDict {
                if let stringValue = value as? String {
                    cssOut[key] = stringValue
                } else {
                    cssOut[key] = String(describing: value)
                }
            }
        }
        self.init(
            html: html,
            css: cssOut,
            selector: selector,
            rect: DesignModePickRect(x: x, y: y, width: width, height: height),
            url: url
        )
    }

    private static func doubleValue(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let n = any as? NSNumber { return n.doubleValue }
        if let i = any as? Int { return Double(i) }
        return nil
    }

    static func truncatedHTML(_ html: String) -> String {
        guard html.count > htmlTruncationLimit else { return html }
        return String(html.prefix(htmlTruncationLimit)) + truncationMarker
    }
}

// MARK: - Text composition (pure, unit-testable)

enum DesignModeTextComposer {
    static func compose(payload: DesignModePickPayload, screenshotPath: String?) -> String {
        var lines: [String] = []
        lines.append("Element: \(payload.selector)")
        lines.append("URL: \(payload.url)")
        if let screenshotPath {
            lines.append("Screenshot: \(screenshotPath)")
        }
        lines.append("")
        lines.append("HTML:")
        lines.append(payload.html)
        lines.append("")
        lines.append("CSS:")
        let cssKeys = payload.css.keys.sorted()
        if cssKeys.isEmpty {
            lines.append("  (no notable computed styles)")
        } else {
            for key in cssKeys {
                lines.append("  \(key): \(payload.css[key] ?? "")")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Filesystem-safe slug used in the screenshot filename, derived from the element selector.
    static func filenameSafeSelector(_ selector: String) -> String {
        var result = String(selector.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "-"
        })
        while result.contains("--") {
            result = result.replacingOccurrences(of: "--", with: "-")
        }
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if result.isEmpty { result = "element" }
        return String(result.prefix(60))
    }
}

// MARK: - Screenshot file writer

enum DesignModeFileWriter {
    /// `<repo-root>/.programa/design` when a repo root is resolvable from `workingDirectory`
    /// (via `GitWorktreeManager.resolveRepoRoot`, the same helper used for worktree resolution),
    /// else a temp-directory fallback so a capture never fails just because the terminal isn't
    /// inside a git repo.
    static func screenshotDirectory(workingDirectory: String?) -> URL {
        if let workingDirectory, let repoRoot = GitWorktreeManager.resolveRepoRoot(from: workingDirectory) {
            return URL(fileURLWithPath: repoRoot).appendingPathComponent(".programa/design")
        }
        return FileManager.default.temporaryDirectory.appendingPathComponent("programa-design")
    }

    @discardableResult
    static func write(_ data: Data, selector: String, workingDirectory: String?) -> String? {
        let directory = screenshotDirectory(workingDirectory: workingDirectory)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            NSLog("DesignMode: failed to create screenshot directory: %@", error.localizedDescription)
            return nil
        }
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let slug = DesignModeTextComposer.filenameSafeSelector(selector)
        let fileURL = directory.appendingPathComponent("\(timestamp)-\(slug).png")
        do {
            try data.write(to: fileURL)
            return fileURL.path
        } catch {
            NSLog("DesignMode: failed to write screenshot: %@", error.localizedDescription)
            return nil
        }
    }
}

// MARK: - Notification

enum DesignModeNotificationKey {
    static let workspaceId = "workspaceId"
    static let browserPanelId = "browserPanelId"
    static let returnPanelId = "returnPanelId"
    static let payload = "payload"
    static let screenshotData = "screenshotData"
}

// MARK: - Panel routing (shared by command palette + socket entry points)

/// Resolves a Design Mode route from the focused panel (focused
/// browser panel is the target with no return; focused terminal panel requires exactly one
/// browser panel in the workspace) and drives the picker's arm/focus/inject sequence.
/// Returns `false` when no route could be resolved (e.g. no browser panel in the workspace).
@discardableResult
@MainActor
func activateDesignModeRoute(in workspace: Workspace) -> Bool {
    let snapshots = workspace.panels.values.map { panel in
        DesignModeShortcutPanelSnapshot(
            id: panel.id,
            panelType: panel.panelType,
            isFocused: panel.id == workspace.focusedPanelId
        )
    }
    guard let route = resolveDesignModeShortcutRoute(panels: snapshots),
          let browserPanel = workspace.browserPanel(for: route.browserPanelId) else {
        return false
    }

    if let returnTerminalPanelId = route.returnTerminalPanelId {
        browserPanel.armDesignModeRoundTrip(returnTo: returnTerminalPanelId)
    } else {
        browserPanel.clearDesignModeRoundTrip(reason: "shortcut.noReturnTarget")
    }

    if workspace.focusedPanelId != browserPanel.id {
        workspace.clearSplitZoom()
        workspace.focusPanel(browserPanel.id)
    }

    let didRequestExplicitWebViewFocus = browserPanel.requestExplicitWebViewFocus()
    Task { @MainActor [weak browserPanel] in
        guard let browserPanel else { return }
        if route.returnTerminalPanelId != nil {
            await browserPanel.ensureDesignModeActive()
        } else {
            await browserPanel.toggleOrInjectDesignMode()
        }
        if !didRequestExplicitWebViewFocus {
            _ = browserPanel.requestExplicitWebViewFocus()
        }
    }
    return true
}

// MARK: - WKScriptMessageHandler

private let designModeMessageHandlerName = "programaDesignMode"

/// A `pick` posted by the page script counts only when it follows a real click in the web view;
/// the script itself cannot be trusted to prove a user acted.
enum DesignModePickGate {
    static let window: TimeInterval = 1.5

    static func accepts(lastNativeMouseDown: TimeInterval?, now: TimeInterval) -> Bool {
        guard let lastNativeMouseDown else { return false }
        let elapsed = now - lastNativeMouseDown
        return elapsed >= 0 && elapsed <= window
    }
}

enum DesignModeBridgeMessage {
    case stateChange(isActive: Bool)
    case pick(payload: DesignModePickPayload)

    init?(body: [String: Any]) {
        let type = body["type"] as? String ?? "stateChange"
        switch type {
        case "stateChange":
            guard let isActive = body["isActive"] as? Bool else { return nil }
            self = .stateChange(isActive: isActive)
        case "pick":
            guard let payload = DesignModePickPayload(body: body) else { return nil }
            self = .pick(payload: payload)
        default:
            return nil
        }
    }
}

class DesignModeMessageHandler: NSObject, WKScriptMessageHandler {
    private let onMessage: @MainActor (DesignModeBridgeMessage) -> Void

    init(onMessage: @escaping @MainActor (DesignModeBridgeMessage) -> Void) {
        self.onMessage = onMessage
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.frameInfo.isMainFrame else {
#if DEBUG
            dlog("designMode.message dropped: not main frame")
#endif
            return
        }
        guard let body = message.body as? [String: Any],
              let bridgeMessage = DesignModeBridgeMessage(body: body) else { return }
        Task { @MainActor in
            onMessage(bridgeMessage)
        }
    }
}

// MARK: - Picker script (self-contained, no network fetch)

enum DesignModePickerScript {
    static func source(handlerName: String) -> String {
        """
        (function() {
            var API_NAME = '__PROGRAMA_DESIGN_MODE__';
            if (window[API_NAME] && window[API_NAME].__installed) {
                return;
            }

            var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(handlerName);
            var active = false;
            var overlay = null;
            var lastTarget = null;

            var CSS_PROPS = [
                'display', 'position', 'width', 'height', 'margin', 'padding', 'border',
                'border-radius', 'color', 'background-color', 'font-family', 'font-size',
                'font-weight', 'line-height', 'letter-spacing', 'text-align', 'flex-direction',
                'justify-content', 'align-items', 'gap', 'grid-template-columns', 'opacity',
                'box-shadow', 'z-index', 'overflow'
            ];

            var INITIAL_VALUES = {
                'display': 'inline', 'position': 'static', 'margin': '0px', 'padding': '0px',
                'border-radius': '0px', 'color': 'rgb(0, 0, 0)', 'background-color': 'rgba(0, 0, 0, 0)',
                'font-weight': '400', 'line-height': 'normal', 'letter-spacing': 'normal',
                'text-align': 'start', 'flex-direction': 'row', 'justify-content': 'normal',
                'align-items': 'normal', 'gap': 'normal', 'grid-template-columns': 'none',
                'opacity': '1', 'box-shadow': 'none', 'z-index': 'auto', 'overflow': 'visible'
            };

            function ensureOverlay() {
                if (overlay) return overlay;
                overlay = document.createElement('div');
                overlay.setAttribute('data-programa-design-mode-overlay', 'true');
                overlay.style.cssText = [
                    'position:fixed', 'pointer-events:none', 'z-index:2147483647',
                    'border:2px solid #4f8cff', 'background:rgba(79,140,255,0.12)',
                    'box-sizing:border-box', 'border-radius:2px', 'display:none'
                ].join(';');
                (document.body || document.documentElement).appendChild(overlay);
                return overlay;
            }

            function updateOverlay(el) {
                var ov = ensureOverlay();
                if (!el) { ov.style.display = 'none'; return; }
                var r = el.getBoundingClientRect();
                ov.style.display = 'block';
                ov.style.left = r.left + 'px';
                ov.style.top = r.top + 'px';
                ov.style.width = r.width + 'px';
                ov.style.height = r.height + 'px';
            }

            function shortSelector(el) {
                var parts = [];
                var node = el;
                var depth = 0;
                while (node && node.nodeType === 1 && depth <= 3) {
                    var part = node.tagName ? node.tagName.toLowerCase() : '';
                    if (node.id) {
                        part += '#' + node.id;
                    } else if (node.classList && node.classList.length) {
                        var cls = Array.prototype.slice.call(node.classList).slice(0, 2);
                        if (cls.length) part += '.' + cls.join('.');
                    }
                    parts.unshift(part);
                    node = node.parentElement;
                    depth++;
                }
                return parts.join(' > ');
            }

            function truncateHTML(html) {
                var LIMIT = 4000;
                if (html.length <= LIMIT) return html;
                return html.slice(0, LIMIT) + '\\n... [truncated]';
            }

            function collectCSS(el) {
                var style;
                try { style = getComputedStyle(el); } catch (_) { return {}; }
                var out = {};
                for (var i = 0; i < CSS_PROPS.length; i++) {
                    var prop = CSS_PROPS[i];
                    var value;
                    try { value = style.getPropertyValue(prop); } catch (_) { continue; }
                    if (!value) continue;
                    var initial = INITIAL_VALUES[prop];
                    if (initial !== undefined && value === initial) continue;
                    out[prop] = value;
                }
                return out;
            }

            function pick(el) {
                var rect = el.getBoundingClientRect();
                var payload = {
                    type: 'pick',
                    html: truncateHTML(el.outerHTML || ''),
                    css: collectCSS(el),
                    selector: shortSelector(el),
                    rect: { x: rect.x, y: rect.y, width: rect.width, height: rect.height },
                    url: String(location.href)
                };
                if (handler) handler.postMessage(payload);
            }

            function onMouseMove(e) {
                if (!active) return;
                var el = document.elementFromPoint(e.clientX, e.clientY);
                if (el === overlay) return;
                if (el !== lastTarget) {
                    lastTarget = el;
                    updateOverlay(el);
                }
            }

            function onClick(e) {
                if (!active) return;
                e.preventDefault();
                e.stopPropagation();
                var el = lastTarget || document.elementFromPoint(e.clientX, e.clientY);
                deactivate();
                if (el) pick(el);
            }

            function onKeyDown(e) {
                if (!active) return;
                if (e.key === 'Escape') {
                    e.preventDefault();
                    deactivate();
                }
            }

            function setActive(next) {
                if (active === next) return;
                active = next;
                if (handler) handler.postMessage({ type: 'stateChange', isActive: active });
                if (!active) {
                    lastTarget = null;
                    updateOverlay(null);
                }
            }

            function activate() {
                if (active) return;
                setActive(true);
                document.addEventListener('mousemove', onMouseMove, true);
                document.addEventListener('click', onClick, true);
                document.addEventListener('keydown', onKeyDown, true);
            }

            function deactivate() {
                if (!active) return;
                setActive(false);
                document.removeEventListener('mousemove', onMouseMove, true);
                document.removeEventListener('click', onClick, true);
                document.removeEventListener('keydown', onKeyDown, true);
            }

            function toggle() {
                if (active) { deactivate(); } else { activate(); }
            }

            window[API_NAME] = { toggle: toggle, activate: activate, deactivate: deactivate, __installed: true };
        })();
        window.__PROGRAMA_DESIGN_MODE__ && window.__PROGRAMA_DESIGN_MODE__.activate();
        """
    }
}

// MARK: - BrowserPanel extension

extension BrowserPanel {
    func setupDesignModeMessageHandler(for webView: WKWebView) {
        let handler = DesignModeMessageHandler { [weak self] message in
            self?.handleDesignModeBridgeMessage(message)
        }
        designModeMessageHandler = handler
        webView.configuration.userContentController.add(handler, name: designModeMessageHandlerName)
    }

    func armDesignModeRoundTrip(returnTo panelId: UUID) {
        pendingDesignModeReturnTargetPanelId = panelId
    }

    func clearDesignModeRoundTrip(reason: String = "unspecified") {
        pendingDesignModeReturnTargetPanelId = nil
    }

    func handleDesignModeBridgeMessage(_ message: DesignModeBridgeMessage) {
        switch message {
        case .stateChange(let isActive):
            isDesignModeActive = isActive
        case .pick(let payload):
            let lastMouseDown = (webView as? ProgramaWebView)?.lastPrimaryMouseDownTimestamp
            guard DesignModePickGate.accepts(
                lastNativeMouseDown: lastMouseDown,
                now: ProcessInfo.processInfo.systemUptime
            ) else {
#if DEBUG
                dlog("designMode.pick dropped: no recent native click")
#endif
                return
            }
            guard let returnPanelId = pendingDesignModeReturnTargetPanelId else {
                // No return terminal armed (e.g. focused directly inside the browser panel with
                // no terminal to return to): drop the capture.
                return
            }
            clearDesignModeRoundTrip(reason: "pick")
            let capturedWorkspaceId = workspaceId
            let capturedBrowserPanelId = id
            Task { @MainActor [weak self] in
                guard let self else { return }
                let image = await self.captureDesignModeScreenshot(rect: payload.rect)
                let pngData = BrowserPanel.designModePNGData(from: image)
                NotificationCenter.default.post(
                    name: .designModeDidCapture,
                    object: nil,
                    userInfo: [
                        DesignModeNotificationKey.workspaceId: capturedWorkspaceId,
                        DesignModeNotificationKey.browserPanelId: capturedBrowserPanelId,
                        DesignModeNotificationKey.returnPanelId: returnPanelId,
                        DesignModeNotificationKey.payload: payload,
                        DesignModeNotificationKey.screenshotData: pngData as Any
                    ]
                )
            }
        }
    }

    func injectDesignMode() async {
        let script = DesignModePickerScript.source(handlerName: designModeMessageHandlerName)
        do {
            _ = try await webView.evaluateJavaScript(script)
        } catch {
            NSLog("DesignMode: injection failed: %@", error.localizedDescription)
            isDesignModeActive = false
        }
    }

    func toggleDesignMode() {
        webView.evaluateJavaScript(
            "window.__PROGRAMA_DESIGN_MODE__ && window.__PROGRAMA_DESIGN_MODE__.toggle();",
            completionHandler: nil
        )
    }

    func toggleOrInjectDesignMode() async {
        if isDesignModeActive {
            toggleDesignMode()
        } else {
            await injectDesignMode()
        }
    }

    func ensureDesignModeActive() async {
        if isDesignModeActive { return }
        await injectDesignMode()
    }

    /// Crops a screenshot of the picked element, converting the CSS-pixel rect (from
    /// `getBoundingClientRect()`) into the web view's own point coordinate system. WKWebView's
    /// `pageZoom` scales layout the same way Safari's page zoom does (1 CSS px renders as
    /// `pageZoom` view points), so the conversion multiplies by `webView.pageZoom` before
    /// padding and clamping to the view's bounds.
    func captureDesignModeScreenshot(rect: DesignModePickRect) async -> NSImage? {
        await withCheckedContinuation { continuation in
            let zoom = webView.pageZoom
            let padding: CGFloat = 8
            let viewRect = CGRect(
                x: rect.x * zoom - padding,
                y: rect.y * zoom - padding,
                width: rect.width * zoom + padding * 2,
                height: rect.height * zoom + padding * 2
            )
            let clamped = viewRect.intersection(webView.bounds)
            guard !clamped.isNull, clamped.width >= 1, clamped.height >= 1 else {
                continuation.resume(returning: nil)
                return
            }
            let config = WKSnapshotConfiguration()
            config.rect = clamped
            webView.takeSnapshot(with: config) { image, error in
                if let error {
                    NSLog("DesignMode: snapshot error: %@", error.localizedDescription)
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: image)
            }
        }
    }

    static func designModePNGData(from image: NSImage?) -> Data? {
        guard let image,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}
