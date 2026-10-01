import AppKit
import Bonsplit
import WebKit

struct BrowserDownloadFinalizationError: Error, CustomNSError {
    let moveError: Error
    let retainedTempURL: URL

    static let errorDomain = "com.darkroom.programa.browser-download-finalization"
    var errorCode: Int { 1 }
    var errorUserInfo: [String: Any] {
        [
            NSLocalizedDescriptionKey: moveError.localizedDescription,
            NSUnderlyingErrorKey: moveError,
            "BrowserDownloadRetainedTemporaryURL": retainedTempURL,
        ]
    }
}

// MARK: - Download Delegate

/// Handles WKDownload lifecycle by saving to a temp file synchronously (no UI
/// during WebKit callbacks), then showing NSSavePanel after the download finishes.
class BrowserDownloadDelegate: NSObject, WKDownloadDelegate {
    private struct DownloadState {
        let tempURL: URL
        let suggestedFilename: String
        let originURL: URL?
    }

    /// Tracks active downloads keyed by WKDownload identity.
    private var activeDownloads: [ObjectIdentifier: DownloadState] = [:]
    /// Downloads the user declined at the no-gesture prompt; their cancellation is not a failure.
    private var declinedDownloads: Set<ObjectIdentifier> = []
    private let activeDownloadsLock = NSLock()
    var onDownloadStarted: ((String) -> Void)?
    var onDownloadReadyToSave: (() -> Void)?
    var onDownloadFailed: ((Error) -> Void)?

    private static let tempDir: URL = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("programa-downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static func sanitizedFilename(_ raw: String, fallbackURL: URL?) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = (trimmed as NSString).lastPathComponent
        let fromURL = fallbackURL?.lastPathComponent ?? ""
        let base = candidate.isEmpty ? fromURL : candidate
        let replaced = base.replacingOccurrences(of: ":", with: "-")
        let safe = replaced.trimmingCharacters(in: .whitespacesAndNewlines)
        return safe.isEmpty ? "download" : safe
    }

    /// Resolves a non-colliding destination in ~/Downloads, appending " 2", " 3", … like Safari.
    static func uniqueDownloadsURL(for filename: String) -> URL {
        let fileManager = FileManager.default
        let downloads = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
        try? fileManager.createDirectory(at: downloads, withIntermediateDirectories: true)

        var candidate = downloads.appendingPathComponent(filename, isDirectory: false)
        guard fileManager.fileExists(atPath: candidate.path) else { return candidate }

        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var counter = 2
        repeat {
            let name = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            candidate = downloads.appendingPathComponent(name, isDirectory: false)
            counter += 1
        } while fileManager.fileExists(atPath: candidate.path)
        return candidate
    }

    static func finalizeDownload(
        from tempURL: URL,
        to destinationURL: URL,
        fileManager: FileManager = .default,
        onReady: () -> Void,
        onFailure: (Error) -> Void
    ) {
        do {
            try fileManager.moveItem(at: tempURL, to: destinationURL)
            onReady()
        } catch let moveError {
            onFailure(
                BrowserDownloadFinalizationError(
                    moveError: moveError,
                    retainedTempURL: tempURL
                )
            )
        }
    }

    private func storeState(_ state: DownloadState, for download: WKDownload) {
        activeDownloadsLock.lock()
        activeDownloads[ObjectIdentifier(download)] = state
        activeDownloadsLock.unlock()
    }

    private func removeState(for download: WKDownload) -> DownloadState? {
        activeDownloadsLock.lock()
        let state = activeDownloads.removeValue(forKey: ObjectIdentifier(download))
        activeDownloadsLock.unlock()
        return state
    }

    private func notifyOnMain(_ action: @escaping () -> Void) {
        if Thread.isMainThread {
            action()
        } else {
            DispatchQueue.main.async(execute: action)
        }
    }

    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        // Save to a temp file — return synchronously so WebKit is never blocked.
        let safeFilename = Self.sanitizedFilename(suggestedFilename, fallbackURL: response.url)
        let tempFilename = "\(UUID().uuidString)-\(safeFilename)"
        let destURL = Self.tempDir.appendingPathComponent(tempFilename, isDirectory: false)
        try? FileManager.default.removeItem(at: destURL)
        let originURL = response.url ?? download.originalRequest?.url
        let proceed = { [weak self] in
            self?.storeState(DownloadState(tempURL: destURL, suggestedFilename: safeFilename, originURL: originURL), for: download)
            self?.notifyOnMain { [weak self] in
                self?.onDownloadStarted?(safeFilename)
            }
            #if DEBUG
            dlog("download.decideDestination file=\(safeFilename)")
            #endif
            NSLog("BrowserPanel download: temp path=%@", destURL.path)
            completionHandler(destURL)
        }
        // A download a real click or key press started proceeds; one a page started on its
        // own (timer, script) asks first.
        notifyOnMain {
            MainActor.assumeIsolated {
                let webView = download.webView
                if (webView as? ProgramaWebView)?.hasRecentNativeGesture() == true {
                    proceed()
                    return
                }
                Self.confirmUnrequestedDownload(
                    filename: safeFilename,
                    sourceHost: webView?.url?.host ?? originURL?.host,
                    window: webView?.window
                ) { allowed in
                    if allowed {
                        proceed()
                    } else {
                        #if DEBUG
                        dlog("download.decideDestination file=\(safeFilename) declined=noGesture")
                        #endif
                        self.activeDownloadsLock.lock()
                        self.declinedDownloads.insert(ObjectIdentifier(download))
                        self.activeDownloadsLock.unlock()
                        completionHandler(nil)
                    }
                }
            }
        }
    }

    @MainActor
    private static func confirmUnrequestedDownload(
        filename: String,
        sourceHost: String?,
        window: NSWindow?,
        completion: @escaping (Bool) -> Void
    ) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            format: String(localized: "shell.download.confirm.title", defaultValue: "Download “%@”?"),
            filename
        )
        alert.informativeText = String(
            format: String(
                localized: "shell.download.confirm.message",
                defaultValue: "%@ started this download without a click. It will be saved to your Downloads folder."
            ),
            sourceHost ?? String(localized: "shell.download.confirm.unknownSource", defaultValue: "A web page")
        )
        alert.addButton(withTitle: String(localized: "shell.download.confirm.download", defaultValue: "Download"))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
        let handle: (NSApplication.ModalResponse) -> Void = { completion($0 == .alertFirstButtonReturn) }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(alert.runModal())
        }
    }

    /// Marks a finished download as coming from the internet so Gatekeeper checks it on open.
    static func applyQuarantine(to fileURL: URL, originURL: URL?) {
        var properties: [String: Any] = [
            kLSQuarantineAgentNameKey as String: Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Programa",
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
        ]
        if let originURL {
            properties[kLSQuarantineDataURLKey as String] = originURL
        }
        var values = URLResourceValues()
        values.quarantineProperties = properties
        var mutableURL = fileURL
        do {
            try mutableURL.setResourceValues(values)
        } catch {
            NSLog("BrowserPanel download quarantine failed: %@", error.localizedDescription)
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let info = removeState(for: download) else {
            #if DEBUG
            dlog("download.finished missing-state")
            #endif
            return
        }
        #if DEBUG
        dlog("download.finished file=\(info.suggestedFilename)")
        #endif
        NSLog("BrowserPanel download finished: %@", info.suggestedFilename)

        // #9: auto-save to ~/Downloads (Safari-style) instead of prompting with a save panel.
        DispatchQueue.main.async {
            let destURL = Self.uniqueDownloadsURL(for: info.suggestedFilename)
            Self.finalizeDownload(
                from: info.tempURL,
                to: destURL,
                onReady: {
                    Self.applyQuarantine(to: destURL, originURL: info.originURL)
                    NSLog("BrowserPanel download saved: %@", destURL.path)
                    self.onDownloadReadyToSave?()
                },
                onFailure: { error in
                    if let finalizationError = error as? BrowserDownloadFinalizationError {
                        NSLog(
                            "BrowserPanel download move failed: %@; completed download retained at: %@",
                            finalizationError.moveError.localizedDescription,
                            finalizationError.retainedTempURL.path
                        )
                    } else {
                        NSLog("BrowserPanel download move failed: %@", error.localizedDescription)
                    }
                    self.onDownloadFailed?(error)
                }
            )
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        if let info = removeState(for: download) {
            try? FileManager.default.removeItem(at: info.tempURL)
        }
        activeDownloadsLock.lock()
        let wasDeclined = declinedDownloads.remove(ObjectIdentifier(download)) != nil
        activeDownloadsLock.unlock()
        guard !wasDeclined else { return }
        notifyOnMain { [weak self] in
            self?.onDownloadFailed?(error)
        }
        #if DEBUG
        dlog("download.failed error=\(error.localizedDescription)")
        #endif
        NSLog("BrowserPanel download failed: %@", error.localizedDescription)
    }
}
