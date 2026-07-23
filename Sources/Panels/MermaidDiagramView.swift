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
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(isDark ? Color(red: 0.9, green: 0.9, blue: 0.9) : Color(red: 0.2, green: 0.2, blue: 0.2))
                .padding(12)
        }
        .background(isDark
            ? Color(nsColor: NSColor(white: 0.08, alpha: 1.0))
            : Color(nsColor: NSColor(white: 0.93, alpha: 1.0)))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// AppKit bridge that hosts the offline mermaid.js render inside a WKWebView,
/// sized to the rendered diagram's natural height so it sits inline in the
/// document flow.
private struct MermaidWebView: NSViewRepresentable {
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

    private static func html(source: String, isDark: Bool, scriptFileName: String) -> String {
        let escapedSource = source
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "${", with: "\\${")
        let theme = isDark ? "dark" : "default"
        let backgroundHex = isDark ? "#1e1e1e" : "#ffffff"
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <script src="\(scriptFileName)"></script>
        <style>
          html, body { margin: 0; padding: 0; background: \(backgroundHex); }
          #diagram { display: flex; justify-content: center; padding: 4px; }
          #diagram svg { max-width: 100%; height: auto; }
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
          try {
            mermaid.initialize({ startOnLoad: false, theme: '\(theme)', securityLevel: 'strict' });
            var source = `\(escapedSource)`;
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

    final class Coordinator: NSObject, WKScriptMessageHandler {
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
    }
}
