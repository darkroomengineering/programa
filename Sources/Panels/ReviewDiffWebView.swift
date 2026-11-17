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

/// Renders the review diff with `@pierre/diffs` in a WKWebView (the default Review panel
/// renderer, see `ReviewDiffRendererSettings`). The bundle in `Resources/review-diff-viewer`
/// (built by `scripts/build-review-diff-viewer.sh`) is served from the `programa-review` scheme
/// because ES module workers and dynamic imports need a real origin. The page pulls the patch
/// from `/patch`, the not-diffable labels from `/notices` and the editable files from `/editable`,
/// and posts `selectLines` back. Inline editing asks for `loadFile` and `saveFile` and gets the
/// result as the message reply.
struct ReviewDiffWebView: NSViewRepresentable {
    typealias LoadFile = (_ path: String, _ completion: @escaping (Result<ReviewEditableFile, ReviewFileEditError>) -> Void) -> Void
    typealias SaveFile = (
        _ path: String,
        _ contents: String,
        _ token: String,
        _ completion: @escaping (Result<Void, ReviewFileEditError>) -> Void
    ) -> Void

    static let scheme = "programa-review"
    static let host = "app"
    fileprivate static let messageHandlerName = "programaReview"

    static var bundleDirectory: URL? {
        guard let directory = Bundle.main.resourceURL?.appendingPathComponent("review-diff-viewer", isDirectory: true),
              FileManager.default.fileExists(atPath: directory.appendingPathComponent("index.html").path) else {
            return nil
        }
        return directory
    }

    let patch: String
    /// Entry `i` of `patch`; files with a `notDiffableReason` get their label in the viewer.
    let files: [ReviewFileDiff]
    /// Entry index -> repo-relative path of each file the viewer may offer to edit.
    let editablePaths: [Int: String]
    let revision: UInt64
    let style: ReviewDiffViewerStyle
    /// The view stays mounted while its tab is hidden; hiding it keeps it from taking file
    /// drops and clicks meant for the visible tab.
    let isVisibleInUI: Bool
    let bundleDirectory: URL
    let onLoadFile: LoadFile
    let onSaveFile: SaveFile
    let onSelectLines: (ReviewDiffLineSelection) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(schemeHandler: ReviewDiffSchemeHandler(rootDirectory: bundleDirectory))
    }

    func makeNSView(context: Context) -> WKWebView {
        let coordinator = context.coordinator
        coordinator.onSelectLines = onSelectLines
        coordinator.onLoadFile = onLoadFile
        coordinator.onSaveFile = onSaveFile
        coordinator.schemeHandler.setContent(patch: patch, files: files, editablePaths: editablePaths)
        coordinator.lastRevision = revision
        coordinator.lastStyle = style

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(coordinator.schemeHandler, forURLScheme: Self.scheme)
        configuration.userContentController.addScriptMessageHandler(
            WeakScriptMessageHandler(target: coordinator),
            contentWorld: .page,
            name: Self.messageHandlerName
        )
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        webView.navigationDelegate = coordinator
        coordinator.webView = webView
        webView.isHidden = !isVisibleInUI

        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.host
        components.path = "/index.html"
        // The page has no strings of its own; its labels arrive localized here.
        components.queryItems = [
            URLQueryItem(name: "style", value: style.rawValue),
            URLQueryItem(name: "editLabel", value: String(localized: "review.file.edit", defaultValue: "Edit")),
            URLQueryItem(
                name: "editHelp",
                value: String(localized: "review.file.edit.help", defaultValue: "Edit this file here")
            ),
            URLQueryItem(name: "saveLabel", value: String(localized: "review.file.save", defaultValue: "Save")),
            URLQueryItem(
                name: "saveHelp",
                value: String(localized: "review.file.save.help", defaultValue: "Save your changes to the file (⌘S)")
            ),
            URLQueryItem(name: "cancelLabel", value: String(localized: "review.file.cancel", defaultValue: "Cancel")),
            URLQueryItem(
                name: "cancelHelp",
                value: String(localized: "review.file.cancel.help", defaultValue: "Discard your changes")
            ),
            URLQueryItem(
                name: "editFailed",
                value: String(localized: "review.file.edit.error.generic", defaultValue: "Could not edit this file.")
            ),
        ]
        if let url = components.url {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        webView.isHidden = !isVisibleInUI
        coordinator.onSelectLines = onSelectLines
        coordinator.onLoadFile = onLoadFile
        coordinator.onSaveFile = onSaveFile
        if coordinator.lastRevision != revision {
            coordinator.lastRevision = revision
            coordinator.schemeHandler.setContent(patch: patch, files: files, editablePaths: editablePaths)
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
        webView.configuration.userContentController.removeScriptMessageHandler(forName: messageHandlerName, contentWorld: .page)
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.loadHTMLString("", baseURL: nil)
        coordinator.webView = nil
        coordinator.onSelectLines = nil
        coordinator.onLoadFile = nil
        coordinator.onSaveFile = nil
        coordinator.schemeHandler.setContent(patch: "", files: [], editablePaths: [:])
    }

    final class Coordinator: NSObject, WKScriptMessageHandlerWithReply, WKNavigationDelegate {
        let schemeHandler: ReviewDiffSchemeHandler
        weak var webView: WKWebView?
        var onSelectLines: ((ReviewDiffLineSelection) -> Void)?
        var onLoadFile: LoadFile?
        var onSaveFile: SaveFile?
        var lastRevision: UInt64 = 0
        var lastStyle: ReviewDiffViewerStyle = .split
        private var webContentTerminations = 0

        init(schemeHandler: ReviewDiffSchemeHandler) {
            self.schemeHandler = schemeHandler
        }

        /// Every message gets exactly one reply: `loadFile` and `saveFile` with their result,
        /// everything else with `nil`. `saveFile` writes to disk, so only the viewer's own top
        /// document may send anything.
        func userContentController(
            _ controller: WKUserContentController,
            didReceive message: WKScriptMessage,
            replyHandler: @escaping (Any?, String?) -> Void
        ) {
            let origin = message.frameInfo.securityOrigin
            guard message.frameInfo.isMainFrame,
                  origin.protocol == ReviewDiffWebView.scheme,
                  origin.host == ReviewDiffWebView.host,
                  let body = message.body as? [String: Any], let type = body["type"] as? String else {
                replyHandler(nil, nil)
                return
            }
            switch type {
            case "loadFile":
                guard let filePath = body["filePath"] as? String, let onLoadFile else {
                    replyHandler(Self.failureReply(.notEditable), nil)
                    return
                }
                onLoadFile(filePath) { result in
                    switch result {
                    case .success(let file):
                        replyHandler([
                            "ok": true,
                            "oldContents": file.oldContents.map { $0 as Any } ?? NSNull(),
                            "newContents": file.newContents,
                            "token": file.token,
                        ], nil)
                    case .failure(let error):
                        replyHandler(Self.failureReply(error), nil)
                    }
                }
            case "saveFile":
                guard let filePath = body["filePath"] as? String,
                      let contents = body["contents"] as? String,
                      let token = body["token"] as? String,
                      let onSaveFile else {
                    replyHandler(Self.failureReply(.notEditable), nil)
                    return
                }
                onSaveFile(filePath, contents, token) { result in
                    switch result {
                    case .success:
                        replyHandler(["ok": true], nil)
                    case .failure(let error):
                        replyHandler(Self.failureReply(error), nil)
                    }
                }
            default:
                replyHandler(nil, nil)
                handleNotification(type: type, body: body)
            }
        }

        private static func failureReply(_ error: ReviewFileEditError) -> [String: Any] {
            ["ok": false, "message": error.message]
        }

        private func handleNotification(type: String, body: [String: Any]) {
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
            let allowed = url?.scheme == ReviewDiffWebView.scheme && url?.host == ReviewDiffWebView.host
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
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandlerWithReply {
    weak var target: WKScriptMessageHandlerWithReply?

    init(target: WKScriptMessageHandlerWithReply) {
        self.target = target
    }

    func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        guard let target else {
            replyHandler(nil, nil)
            return
        }
        target.userContentController(controller, didReceive: message, replyHandler: replyHandler)
    }
}

/// Serves the bundled viewer files, the current patch (`/patch`), the placeholder labels for its
/// not-diffable entries (`/notices`) and the paths of its editable entries (`/editable`), both
/// JSON objects keyed by entry index. Holds no reference
/// to the web view. WebKit calls it on the main thread and every response is written
/// synchronously, so there is never a task to cancel in `stop`.
final class ReviewDiffSchemeHandler: NSObject, WKURLSchemeHandler {
    let rootDirectory: URL
    private var patchText = ""
    private var noticesJSON = Data("{}".utf8)
    private var editableJSON = Data("{}".utf8)

    init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory.standardizedFileURL
    }

    func setContent(patch: String, files: [ReviewFileDiff], editablePaths: [Int: String]) {
        patchText = patch
        var notices: [String: String] = [:]
        for (index, file) in files.enumerated() {
            if let reason = file.notDiffableReason {
                notices[String(index)] = reason.label
            }
        }
        noticesJSON = (try? JSONSerialization.data(withJSONObject: notices)) ?? Data("{}".utf8)
        let editable = Dictionary(uniqueKeysWithValues: editablePaths.map { (String($0.key), $0.value) })
        editableJSON = (try? JSONSerialization.data(withJSONObject: editable)) ?? Data("{}".utf8)
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, url.host == ReviewDiffWebView.host else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        if url.path == "/patch" {
            respond(urlSchemeTask, url: url, data: Data(patchText.utf8), contentType: "text/plain; charset=utf-8")
            return
        }
        if url.path == "/notices" {
            respond(urlSchemeTask, url: url, data: noticesJSON, contentType: "application/json")
            return
        }
        if url.path == "/editable" {
            respond(urlSchemeTask, url: url, data: editableJSON, contentType: "application/json")
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

    /// Same-origin only. `'wasm-unsafe-eval'` is for the inlined Shiki/Pierre WebAssembly, `data:`
    /// images for Pierre's SVG `mask-image` markers, and inline styles for Pierre's shadow-DOM
    /// styles and the HTML it renders with `style` attributes. Workers fetch their script
    /// without this header and run without a policy.
    private static let contentSecurityPolicy = [
        "default-src 'none'",
        "script-src 'self' \(origin) 'wasm-unsafe-eval'",
        "worker-src 'self' \(origin)",
        "connect-src 'self' \(origin)",
        "style-src 'self' \(origin) 'unsafe-inline'",
        "img-src 'self' \(origin) data:",
        "font-src 'self' \(origin)",
        "base-uri 'none'",
        "form-action 'none'",
        "frame-src 'none'",
    ].joined(separator: "; ")

    /// Spelled out beside `'self'` so the policy does not depend on how WebKit matches `'self'`
    /// for a custom scheme.
    private static let origin = "\(ReviewDiffWebView.scheme)://\(ReviewDiffWebView.host)"

    private func respond(_ task: WKURLSchemeTask, url: URL, data: Data, contentType: String) {
        var headers = [
            "Content-Type": contentType,
            "Content-Length": String(data.count),
            "Cache-Control": "no-store",
            "X-Content-Type-Options": "nosniff",
        ]
        if contentType.hasPrefix("text/html") {
            headers["Content-Security-Policy"] = Self.contentSecurityPolicy
        }
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
