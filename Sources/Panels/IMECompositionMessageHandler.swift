import AppKit
import WebKit

/// Receives `compositionstart`/`compositionend` bridge messages from the web view's
/// JS IME tracking script and forwards them to the native `ProgramaWebView`.
final class IMECompositionMessageHandler: NSObject, WKScriptMessageHandler {
    private let onCompositionStateChanged: (Bool) -> Void

    init(onCompositionStateChanged: @escaping (Bool) -> Void) {
        self.onCompositionStateChanged = onCompositionStateChanged
        super.init()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let composing = body["composing"] as? Bool else { return }
        onCompositionStateChanged(composing)
    }
}
