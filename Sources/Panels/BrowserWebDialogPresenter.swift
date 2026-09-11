import AppKit
import WebKit

/// Canonical implementations of the `WKUIDelegate` JS-dialog / file-picker / media-permission
/// behaviors that were byte-for-byte duplicated between the main browser's `BrowserUIDelegate`
/// (`BrowserPanel.swift`) and the popup window's `PopupUIDelegate`
/// (`BrowserPopupWindowController.swift`, marked "parity with main browser" in its doc comment).
///
/// `WKUIDelegate` methods are `@objc optional`, so the Objective-C runtime resolves them via
/// `respondsToSelector:` on the conforming class itself — a protocol-extension default
/// implementation would silently never be called. Each conforming class therefore keeps its own
/// thin `@objc`-visible method, forwarding the body to these shared statics so there is exactly
/// one implementation of the actual behavior.
enum BrowserJSDialogPresenter {
    /// Kind of native JS dialog currently pending for a `WKWebView`, used to describe a pending
    /// dialog back to RPC callers without exposing the underlying `NSAlert`.
    enum Kind: String {
        case alert
        case confirm
        case prompt
    }

    /// Read-only snapshot of a pending native dialog, safe to hand to non-UI callers (RPC layer).
    struct PendingDialogInfo {
        let kind: Kind
        let message: String
        let defaultText: String?
    }

    /// One still-open native `NSAlert` standing in for a JS `alert`/`confirm`/`prompt` call, keyed
    /// by the `WKWebView` that requested it. `resolve` is the single path back to WebKit's
    /// completion handler; it is one-shot (removes itself from `pendingDialogs` before firing).
    private final class PendingDialogEntry {
        let kind: Kind
        let message: String
        let defaultText: String?
        let alert: NSAlert
        let textField: NSTextField?
        let resolve: (_ accept: Bool, _ text: String?) -> Void

        init(
            kind: Kind,
            message: String,
            defaultText: String?,
            alert: NSAlert,
            textField: NSTextField?,
            resolve: @escaping (_ accept: Bool, _ text: String?) -> Void
        ) {
            self.kind = kind
            self.message = message
            self.defaultText = defaultText
            self.alert = alert
            self.textField = textField
            self.resolve = resolve
        }
    }

    /// At most one pending dialog per `WKWebView` — JS dialogs are modal, so a page can never have
    /// two dialogs open at once. Every access happens on the main thread: WebKit always invokes
    /// `WKUIDelegate` dialog callbacks there, and the RPC path resolves via `v2BrowserWithPanel`,
    /// which itself hops to the main actor. `BrowserUIDelegate`/`PopupUIDelegate` are not
    /// `@MainActor`-isolated types, so this stays `nonisolated(unsafe)` rather than `@MainActor`
    /// to keep calling from those delegate callbacks straightforward.
    private nonisolated(unsafe) static var pendingDialogs: [ObjectIdentifier: PendingDialogEntry] = [:]

    private static func key(for webView: WKWebView) -> ObjectIdentifier {
        ObjectIdentifier(webView)
    }

    static func title(for webView: WKWebView) -> String {
        if let absolute = webView.url?.absoluteString, !absolute.isEmpty {
            return String(localized: "browser.dialog.pageSaysAt", defaultValue: "The page at \(absolute) says:")
        }
        return String(localized: "browser.dialog.pageSays", defaultValue: "This page says:")
    }

    static func present(
        _ alert: NSAlert,
        for webView: WKWebView,
        completion: @escaping (NSApplication.ModalResponse) -> Void
    ) {
        if let window = webView.window {
            alert.beginSheetModal(for: window, completionHandler: completion)
            return
        }
        completion(alert.runModal())
    }

    static func presentAlert(
        message: String,
        webView: WKWebView,
        completionHandler: @escaping () -> Void
    ) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title(for: webView)
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))

        var resolved = false
        let webViewKey = key(for: webView)
        let resolve: (Bool, String?) -> Void = { _, _ in
            guard !resolved else { return }
            resolved = true
            pendingDialogs.removeValue(forKey: webViewKey)
            completionHandler()
        }
        pendingDialogs[webViewKey] = PendingDialogEntry(
            kind: .alert, message: message, defaultText: nil, alert: alert, textField: nil, resolve: resolve
        )
        present(alert, for: webView) { _ in resolve(true, nil) }
    }

    static func presentConfirm(
        message: String,
        webView: WKWebView,
        completionHandler: @escaping (Bool) -> Void
    ) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title(for: webView)
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))

        var resolved = false
        let webViewKey = key(for: webView)
        let resolve: (Bool, String?) -> Void = { accept, _ in
            guard !resolved else { return }
            resolved = true
            pendingDialogs.removeValue(forKey: webViewKey)
            completionHandler(accept)
        }
        pendingDialogs[webViewKey] = PendingDialogEntry(
            kind: .confirm, message: message, defaultText: nil, alert: alert, textField: nil, resolve: resolve
        )
        present(alert, for: webView) { response in
            resolve(response == .alertFirstButtonReturn, nil)
        }
    }

    static func presentTextInput(
        prompt: String,
        defaultText: String?,
        webView: WKWebView,
        completionHandler: @escaping (String?) -> Void
    ) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title(for: webView)
        alert.informativeText = prompt
        alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field

        var resolved = false
        let webViewKey = key(for: webView)
        let resolve: (Bool, String?) -> Void = { accept, text in
            guard !resolved else { return }
            resolved = true
            pendingDialogs.removeValue(forKey: webViewKey)
            if accept {
                completionHandler(text ?? field.stringValue)
            } else {
                completionHandler(nil)
            }
        }
        pendingDialogs[webViewKey] = PendingDialogEntry(
            kind: .prompt, message: prompt, defaultText: defaultText, alert: alert, textField: field, resolve: resolve
        )
        present(alert, for: webView) { response in
            resolve(response == .alertFirstButtonReturn, nil)
        }
    }

    /// Resolves whatever native JS dialog is currently pending on `webView`, answering the actual
    /// WebKit completion handler installed by `presentAlert`/`presentConfirm`/`presentTextInput`
    /// (rather than a synthetic queue). Returns `nil` when nothing is pending.
    ///
    /// `text`, when non-nil, is written verbatim (no trimming) into the prompt's text field before
    /// resolving, so an explicit accepted answer — including `""` or whitespace-only text — reaches
    /// the page. It is ignored for alert/confirm, which have no text field.
    @discardableResult
    @MainActor
    static func resolvePendingDialog(for webView: WKWebView, accept: Bool, text: String?) -> PendingDialogInfo? {
        let webViewKey = key(for: webView)
        guard let entry = pendingDialogs[webViewKey] else { return nil }
        let info = PendingDialogInfo(kind: entry.kind, message: entry.message, defaultText: entry.defaultText)
        if let text, let textField = entry.textField {
            textField.stringValue = text
        }
        if let window = webView.window {
            // Hosted as a sheet: ending it drives the same completion handler that a user clicking
            // a button would, keeping exactly one path back to WebKit's real completion.
            window.endSheet(
                entry.alert.window,
                returnCode: accept ? .alertFirstButtonReturn : .alertSecondButtonReturn
            )
        } else {
            // Unhosted `runModal` path: there is no sheet to end, so resolve directly.
            entry.resolve(accept, text)
        }
        return info
    }

    /// Cancels (dismisses) whatever native JS dialog is pending on `webView`, e.g. when the
    /// `WKWebView` is being torn down and would otherwise leak WebKit's completion handler.
    @MainActor
    static func cancelPendingDialog(for webView: WKWebView) {
        _ = resolvePendingDialog(for: webView, accept: false, text: nil)
    }

    /// Read-only lookup for whatever native JS dialog is pending on `webView`, without resolving it.
    @MainActor
    static func pendingDialogInfo(for webView: WKWebView) -> PendingDialogInfo? {
        guard let entry = pendingDialogs[key(for: webView)] else { return nil }
        return PendingDialogInfo(kind: entry.kind, message: entry.message, defaultText: entry.defaultText)
    }

    /// Handle `<input type="file">` elements by presenting the native file picker.
    static func presentOpenPanel(
        parameters: WKOpenPanelParameters,
        completionHandler: @escaping ([URL]?) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        panel.begin { result in
            completionHandler(result == .OK ? panel.urls : nil)
        }
    }

    /// Always prompts rather than silently granting/denying — the system permission prompt
    /// itself is the actual gate.
    static func decideMediaCapturePermission(decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.prompt)
    }
}

/// Canonical construction of the insecure-HTTP (plain-`http://`) warning alert shown by both the
/// main browser (`BrowserPanel.presentInsecureHTTPAlert`) and popup windows
/// (`BrowserPopupWindowController.presentInsecureHTTPAlert`, "parity with main browser").
///
/// Only the alert's *construction* is shared here — the two call sites diverge in what happens
/// after a button is chosen (the main browser persists typed-navigation/bypass-host state across
/// tabs; the popup only opens externally or proceeds inline), so that response handling stays
/// local to each call site.
enum BrowserInsecureHTTPAlertBuilder {
    /// Configures `alert` in place (rather than constructing and returning a new `NSAlert`) so the
    /// main browser can keep routing alert creation through its `#if DEBUG`-overridable
    /// `insecureHTTPAlertFactory` test hook while still sharing this construction logic.
    static func configure(_ alert: NSAlert, host: String) {
        alert.alertStyle = .warning
        alert.messageText = String(localized: "browser.error.insecure.title", defaultValue: "Connection isn\u{2019}t secure")
        alert.informativeText = String(localized: "browser.error.insecure.message", defaultValue: "\(host) uses plain HTTP, so traffic can be read or modified on the network.\n\nOpen this URL in your default browser, or proceed in Programa.")
        alert.addButton(withTitle: String(localized: "browser.openInDefaultBrowser", defaultValue: "Open in Default Browser"))
        alert.addButton(withTitle: String(localized: "browser.proceedInPrograma", defaultValue: "Proceed in Programa"))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = String(localized: "browser.alwaysAllowHost", defaultValue: "Always allow this host in Programa")
    }

    static func makeAlert(host: String) -> NSAlert {
        let alert = NSAlert()
        configure(alert, host: host)
        return alert
    }
}

/// Alert offering to hand a page off to the default browser when it attempts a real passkey
/// ceremony that the built-in browser cannot complete (no WebAuthn entitlement yet).
enum BrowserPasskeyHandoffAlertBuilder {
    static func configure(_ alert: NSAlert) {
        alert.alertStyle = .informational
        alert.messageText = String(
            localized: "browser.passkeyHandoff.title",
            defaultValue: "Passkeys aren\u{2019}t available in the built-in browser yet"
        )
        alert.informativeText = String(
            localized: "browser.passkeyHandoff.message",
            defaultValue: "This page is asking for a passkey, which the built-in browser can\u{2019}t provide. You can finish signing in with your default browser."
        )
        alert.addButton(withTitle: String(localized: "browser.openInDefaultBrowser", defaultValue: "Open in Default Browser"))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
    }

    static func makeAlert() -> NSAlert {
        let alert = NSAlert()
        configure(alert)
        return alert
    }
}
