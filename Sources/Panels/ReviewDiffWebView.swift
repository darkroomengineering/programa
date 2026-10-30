// Adapted from cmux (manaflow-ai/cmux), GPL-3.0
import AppKit
import Bonsplit
import SwiftUI
import WebKit

/// A new-side line range the user picked in the Pierre diff viewer's gutter.
struct ReviewDiffLineSelection: Equatable {
    let filePath: String
    let startLine: Int
    let endLine: Int
}

enum ReviewDiffViewerStyle: String {
    case split
    case unified
}

/// Debug spike (INC-392): renders the review diff with `@pierre/diffs` in a WKWebView. The
/// bundle in `Resources/review-diff-viewer` (built by `scripts/build-review-diff-viewer.sh`)
/// is served from the `programa-review` scheme because ES module workers and dynamic imports
/// need a real origin. The page pulls the patch from `/patch` and posts `selectLines` back.
struct ReviewDiffWebView: NSViewRepresentable {
    static let debugToggleKey = "debugReviewPierreDiffs"
    static let scheme = "programa-review"
    fileprivate static let messageHandlerName = "programaReview"

    static var bundleDirectory: URL? {
        guard let directory = Bundle.main.resourceURL?.appendingPathComponent("review-diff-viewer", isDirectory: true),
              FileManager.default.fileExists(atPath: directory.appendingPathComponent("index.html").path) else {
            return nil
        }
        return directory
    }

    let rawDiff: String
    let revision: UInt64
    let style: ReviewDiffViewerStyle
    let bundleDirectory: URL
    let onSelectLines: (ReviewDiffLineSelection) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(schemeHandler: ReviewDiffSchemeHandler(rootDirectory: bundleDirectory))
    }

    func makeNSView(context: Context) -> WKWebView {
        let coordinator = context.coordinator
        coordinator.onSelectLines = onSelectLines
        coordinator.schemeHandler.patchText = rawDiff
        coordinator.lastRevision = revision
        coordinator.lastStyle = style

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(coordinator.schemeHandler, forURLScheme: Self.scheme)
        configuration.userContentController.add(
            WeakScriptMessageHandler(target: coordinator),
            name: Self.messageHandlerName
        )
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        webView.navigationDelegate = coordinator
        coordinator.webView = webView

        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = "app"
        components.path = "/index.html"
        components.queryItems = [URLQueryItem(name: "style", value: style.rawValue)]
        if let url = components.url {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onSelectLines = onSelectLines
        if coordinator.lastRevision != revision {
            coordinator.lastRevision = revision
            coordinator.schemeHandler.patchText = rawDiff
            webView.evaluateJavaScript("window.programaReview?.reload()", completionHandler: nil)
        }
        if coordinator.lastStyle != style {
            coordinator.lastStyle = style
            webView.evaluateJavaScript("window.programaReview?.setDiffStyle('\(style.rawValue)')", completionHandler: nil)
        }
    }

    /// Drops every reference into the page so the WKWebView, and with it the WebContent
    /// process and the page's highlight workers, can go away with the panel.
    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: messageHandlerName)
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.loadHTMLString("", baseURL: nil)
        coordinator.webView = nil
        coordinator.onSelectLines = nil
        coordinator.schemeHandler.patchText = ""
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let schemeHandler: ReviewDiffSchemeHandler
        weak var webView: WKWebView?
        var onSelectLines: ((ReviewDiffLineSelection) -> Void)?
        var lastRevision: UInt64 = 0
        var lastStyle: ReviewDiffViewerStyle = .split
        private var webContentTerminations = 0

        init(schemeHandler: ReviewDiffSchemeHandler) {
            self.schemeHandler = schemeHandler
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            switch type {
            case "selectLines":
                // Only new-side ranges reach Swift; comments address new-file line numbers.
                guard body["side"] as? String == "additions",
                      let filePath = body["filePath"] as? String, !filePath.isEmpty,
                      let start = (body["startLine"] as? NSNumber)?.intValue,
                      let end = (body["endLine"] as? NSNumber)?.intValue,
                      start > 0, end >= start else { return }
                onSelectLines?(ReviewDiffLineSelection(filePath: filePath, startLine: start, endLine: end))
            case "error":
#if DEBUG
                dlog("review.pierre.error \(String(describing: body["message"]).prefix(500))")
#endif
            default:
                break
            }
        }

        /// The viewer only ever loads its own document from the `programa-review` scheme.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            let url = navigationAction.request.url
            let allowed = url?.scheme == ReviewDiffWebView.scheme && url?.host == "app"
            decisionHandler(allowed ? .allow : .cancel)
        }

        /// Reloads once; a second termination (likely a memory kill on a huge diff) leaves the
        /// page dead so it does not cycle.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            webContentTerminations += 1
#if DEBUG
            dlog("review.pierre.webContentTerminated count=\(webContentTerminations)")
#endif
            if webContentTerminations == 1 {
                webView.reload()
            }
        }
    }
}

/// Holds the coordinator weakly: `WKUserContentController` retains its handlers, and the
/// configuration outlives nothing but the web view, so a strong handler would pin the
/// coordinator (and through it the scheme handler's patch text) to the page.
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

/// Serves the bundled viewer files and the current patch. Holds no reference to the web view.
/// WebKit calls it on the main thread and every response is written synchronously, so there
/// is never a task to cancel in `stop`.
final class ReviewDiffSchemeHandler: NSObject, WKURLSchemeHandler {
    let rootDirectory: URL
    var patchText = ""

    init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory.standardizedFileURL
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, url.host == "app" else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        if url.path == "/patch" {
            respond(urlSchemeTask, url: url, data: Data(patchText.utf8), contentType: "text/plain; charset=utf-8")
            return
        }
        let fileURL = rootDirectory.appendingPathComponent(String(url.path.dropFirst())).standardizedFileURL
        guard fileURL.path.hasPrefix(rootDirectory.path + "/"),
              let data = try? Data(contentsOf: fileURL) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        respond(urlSchemeTask, url: url, data: data, contentType: Self.contentType(forExtension: fileURL.pathExtension))
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

    private func respond(_ task: WKURLSchemeTask, url: URL, data: Data, contentType: String) {
        let headers = [
            "Content-Type": contentType,
            "Content-Length": String(data.count),
            "Cache-Control": "no-store",
            "X-Content-Type-Options": "nosniff",
        ]
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers) else {
            task.didFailWithError(URLError(.cannotParseResponse))
            return
        }
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    private static func contentType(forExtension pathExtension: String) -> String {
        switch pathExtension {
        case "html": return "text/html; charset=utf-8"
        case "mjs", "js": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json": return "application/json"
        case "wasm": return "application/wasm"
        default: return "application/octet-stream"
        }
    }
}
