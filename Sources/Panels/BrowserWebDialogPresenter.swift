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
        present(alert, for: webView) { _ in completionHandler() }
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
        present(alert, for: webView) { response in
            completionHandler(response == .alertFirstButtonReturn)
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

        present(alert, for: webView) { response in
            if response == .alertFirstButtonReturn {
                completionHandler(field.stringValue)
            } else {
                completionHandler(nil)
            }
        }
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
