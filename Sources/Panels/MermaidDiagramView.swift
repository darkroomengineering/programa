import AppKit
import SwiftUI
import WebKit

/// Renders a fenced ` ```mermaid ` code block as a diagram using a bundled,
/// offline copy of mermaid.js loaded into a small WKWebView (no network
/// access; `loadHTMLString` with a local `baseURL` pointing at the bundled
/// script). Falls back to the plain code-block presentation if the vendored
/// script is not present in the app bundle, or if rendering fails, so a
/// missing/broken asset degrades gracefully instead of showing a blank view.
struct MermaidBlockView: View {
    let source: String
    let isDark: Bool

    @State private var renderedHeight: CGFloat = 160
    @State private var didFail: Bool = false

    static func isMermaidLanguage(_ language: String?) -> Bool {
        guard let language else { return false }
        return language.caseInsensitiveCompare("mermaid") == .orderedSame
    }

    /// The vendored mermaid.js resource, if present in the app bundle.
    /// See `Resources/mermaid.min.js` (not bundled in this build — see
    /// project notes for the pending vendoring step).
    private static var scriptURL: URL? {
        Bundle.main.url(forResource: "mermaid.min", withExtension: "js")
    }

    var body: some View {
        if let scriptURL = Self.scriptURL, !didFail {
            MermaidWebView(
                source: source,
                isDark: isDark,
                scriptURL: scriptURL,
                height: $renderedHeight,
                didFail: $didFail
            )
            .frame(height: renderedHeight)
            .frame(maxWidth: .infinity)
        } else {
            MermaidFallbackCodeView(source: source, isDark: isDark)
        }
    }
}

/// Plain monospaced rendering of the raw Mermaid source, used when the
/// bundled mermaid.js asset is unavailable or diagram rendering failed.
/// swift-markdown-ui's `CodeBlockConfiguration` cannot be constructed
/// outside the library (its initializer is internal), so this mirrors
/// `MarkdownCodeBlockView`'s styling directly rather than reusing it.
private struct MermaidFallbackCodeView: View {
    let source: String
    let isDark: Bool

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Text(source)
                .font(.system(.body, design: .monospaced))
                .foregroundColor(Color(nsColor: .labelColor))
                .padding(12)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// AppKit bridge that hosts the offline mermaid.js render inside a WKWebView,
/// sized to the rendered diagram's natural height so it sits inline in the
/// document flow. The web view's own background is made transparent (both at
/// the WKWebView layer and in the loaded HTML) so the diagram sits directly
/// on the panel's native surface instead of a white/dark card.
// Not `private`: `html(source:isDark:scriptFileName:)` below is `static`
// (internal) so a test can render it directly, and a private type would cap
// that member's effective access back down to file-private regardless of its
// own declared access level.
struct MermaidWebView: NSViewRepresentable {
    let source: String
    let isDark: Bool
    let scriptURL: URL
    @Binding var height: CGFloat
    @Binding var didFail: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(height: $height, didFail: $didFail)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: "mermaidHeight")
        configuration.userContentController.add(context.coordinator, name: "mermaidError")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        // Keep the web view's own compositing surface transparent so no
        // white/dark flash shows before the HTML (which also sets a
        // transparent body background) finishes loading.
        webView.setValue(false, forKey: "drawsBackground")
        if #available(macOS 12.3, *) {
            webView.underPageBackgroundColor = .clear
        }
        // The coordinator is the navigation delegate for the view's lifetime:
        // it allows only the single `loadHTMLString` document we construct
        // below and cancels every other navigation (link clicks, form
        // submits, script-driven `window.location` changes), so a Mermaid
        // source that escapes into markup cannot navigate the view anywhere.
        webView.navigationDelegate = context.coordinator
        load(into: webView, context: context)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        load(into: webView, context: context)
    }

    private func load(into webView: WKWebView, context: Context) {
        let key = "\(isDark)|\(source)"
        guard context.coordinator.lastLoadedKey != key else { return }
        context.coordinator.lastLoadedKey = key
        let html = Self.html(source: source, isDark: isDark, scriptFileName: scriptURL.lastPathComponent)
        webView.loadHTMLString(html, baseURL: scriptURL.deletingLastPathComponent())
    }

    /// Builds the HTML document loaded into the web view. `internal` (not
    /// `private`) so tests can render it directly.
    ///
    /// The Mermaid source is never interpolated into the page as executable
    /// markup or script text: it is base64-encoded and embedded only as a
    /// quoted string literal built from the base64 alphabet (`A-Za-z0-9+/=`),
    /// which cannot contain `<`, `>`, a backtick, or `${`. The inline script
    /// decodes it back to UTF-8 with `atob`/`TextDecoder` before handing it to
    /// `mermaid.render`, so a source containing `</script><script>...` (or any
    /// other HTML/script delimiter) can never terminate or extend the
    /// surrounding `<script>` tag.
    static func html(source: String, isDark: Bool, scriptFileName: String) -> String {
        let base64Source = Data(source.utf8).base64EncodedString()
        let theme = isDark ? "dark" : "default"
        let fontFamily = "-apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif"
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <script src="\(scriptFileName)"></script>
        <style>
          html, body { background: transparent; margin: 0; padding: 0; }
          #diagram { display: flex; justify-content: center; padding: 4px; }
          #diagram svg { width: 100%; max-width: 100%; height: auto; }
        </style>
        </head>
        <body>
        <div id="diagram" class="mermaid"></div>
        <script>
          function reportHeight() {
            var el = document.getElementById('diagram');
            var h = Math.ceil(el.scrollHeight || document.body.scrollHeight || 0);
            window.webkit.messageHandlers.mermaidHeight.postMessage(h);
          }
          function decodeBase64Utf8(b64) {
            var binary = atob(b64);
            var bytes = new Uint8Array(binary.length);
            for (var i = 0; i < binary.length; i++) {
              bytes[i] = binary.charCodeAt(i);
            }
            return new TextDecoder('utf-8').decode(bytes);
          }
          try {
            mermaid.initialize({
              startOnLoad: false,
              theme: '\(theme)',
              securityLevel: 'strict',
              themeVariables: { fontFamily: "\(fontFamily)" }
            });
            var source = decodeBase64Utf8('\(base64Source)');
            mermaid.render('mermaid-diagram', source).then(function (result) {
              document.getElementById('diagram').innerHTML = result.svg;
              reportHeight();
            }).catch(function (err) {
              window.webkit.messageHandlers.mermaidError.postMessage(String(err));
            });
          } catch (err) {
            window.webkit.messageHandlers.mermaidError.postMessage(String(err));
          }
        </script>
        </body>
        </html>
        """
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        private let height: Binding<CGFloat>
        private let didFail: Binding<Bool>
        var lastLoadedKey: String = ""

        init(height: Binding<CGFloat>, didFail: Binding<Bool>) {
            self.height = height
            self.didFail = didFail
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            switch message.name {
            case "mermaidHeight":
                guard let value = message.body as? NSNumber else { return }
                let clamped = max(40, min(4000, CGFloat(truncating: value)))
                DispatchQueue.main.async { self.height.wrappedValue = clamped }
            case "mermaidError":
                DispatchQueue.main.async { self.didFail.wrappedValue = true }
            default:
                break
            }
        }

        /// The only navigation this view is ever supposed to perform is the
        /// single `loadHTMLString` document built by `MermaidWebView.html`,
        /// whose main-frame navigation carries type `.other` and a `nil` or
        /// `about:blank` URL (or the local `baseURL` we pass alongside it).
        /// Everything else — a link click, a form submit, or a script-driven
        /// `window.location` change reachable if a Mermaid source ever
        /// escapes into executable markup — is cancelled, so the web view can
        /// never navigate away from the diagram it was given.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            let url = navigationAction.request.url
            let isInitialDocumentLoad = navigationAction.navigationType == .other
                && (url == nil || url?.absoluteString == "about:blank" || url?.isFileURL == true)
            decisionHandler(isInitialDocumentLoad ? .allow : .cancel)
        }
    }
}
