import AppKit
import Foundation

/// One policy for every hand-off to another app. http, https and mailto open silently;
/// everything else asks first, naming the app that would receive the target.
enum ExternalOpenPolicy {
    static let allowlistKey = "browserExternalAppOpenAllowlist"
    static let maxRemembered = 200

    private static let freeSchemes: Set<String> = ["http", "https", "mailto"]
    /// Runnable or launch-redirecting file types. `terminal`/`jar`/`workflow` execute; `fileloc`,
    /// `inetloc` and `webloc` re-target LaunchServices to another location.
    private static let executableExtensions: Set<String> = [
        "app", "command", "sh", "tool", "terminal", "jar", "fileloc", "inetloc", "webloc", "workflow",
    ]

    enum Requirement: Equatable {
        case openWithoutPrompt
        case prompt(offerAlwaysAllow: Bool)
    }

    /// Opens a link outside Programa: http, https and mailto go to their macOS default
    /// handler; every other scheme and every file target asks first. The launch is
    /// asynchronous, so `true` means the open (or the prompt) was dispatched.
    @discardableResult
    static func open(_ url: URL, workspace: NSWorkspace = .shared) -> Bool {
        guard opensWithoutPrompt(url) else {
            return confirmAndOpen(url, workspace: workspace)
        }
        return workspace.open(url)
    }

    static func opensWithoutPrompt(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return freeSchemes.contains(scheme)
    }

    /// Allowlist entries are `bundleId|scheme`, so approving Terminal for `ssh` never approves
    /// Terminal for another scheme or a file.
    static func allowlistKey(bundleIdentifier: String, scheme: String) -> String {
        "\(bundleIdentifier)|\(scheme.lowercased())"
    }

    /// App bundles and anything runnable. These always prompt, even for an allow-listed app.
    static func targetIsExecutable(_ url: URL, fileManager: FileManager = .default) -> Bool {
        guard url.isFileURL else { return false }
        if executableExtensions.contains(url.pathExtension.lowercased()) { return true }
        // LaunchServices opens what a symlink points at, so judge the resolved target.
        let resolved = url.resolvingSymlinksInPath()
        if executableExtensions.contains(resolved.pathExtension.lowercased()) { return true }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: resolved.path, isDirectory: &isDirectory) else { return false }
        if isDirectory.boolValue {
            // Bundles and packages (apps, installers) launch rather than open for reading.
            return NSWorkspace.shared.isFilePackage(atPath: resolved.path)
        }
        return fileManager.isExecutableFile(atPath: resolved.path)
    }

    static func requirement(
        for url: URL,
        handlerBundleIdentifier: String?,
        allowlist: [String],
        targetIsExecutable: Bool,
        allowRememberedApproval: Bool = true
    ) -> Requirement {
        if opensWithoutPrompt(url) { return .openWithoutPrompt }
        // Files never get a remembered approval: the handler app is not the risk, the file is.
        if targetIsExecutable || url.isFileURL { return .prompt(offerAlwaysAllow: false) }
        if allowRememberedApproval,
           let handlerBundleIdentifier,
           let scheme = url.scheme,
           allowlist.contains(allowlistKey(bundleIdentifier: handlerBundleIdentifier, scheme: scheme)) {
            return .openWithoutPrompt
        }
        return .prompt(offerAlwaysAllow: handlerBundleIdentifier != nil)
    }

    /// Remembered `bundleId|scheme` entries. Legacy bundle-only entries are dropped, so those
    /// apps prompt once more.
    static func allowlist(defaults: UserDefaults = .standard) -> [String] {
        (defaults.string(forKey: allowlistKey) ?? "")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { entry in
                let parts = entry.split(separator: "|", omittingEmptySubsequences: false)
                return parts.count == 2 && !parts[0].isEmpty && !parts[1].isEmpty
            }
    }

    static func addToAllowlist(_ bundleIdentifier: String, scheme: String, defaults: UserDefaults = .standard) {
        let trimmed = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedScheme = scheme.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmedScheme.isEmpty,
              !trimmed.contains("\n"), !trimmed.contains("|"),
              !trimmedScheme.contains("\n"), !trimmedScheme.contains("|") else { return }
        let key = allowlistKey(bundleIdentifier: trimmed, scheme: trimmedScheme)
        var entries = allowlist(defaults: defaults)
        guard !entries.contains(key), entries.count < maxRemembered else { return }
        entries.append(key)
        defaults.set(entries.joined(separator: "\n"), forKey: allowlistKey)
    }

    static func applicationDisplayName(at appURL: URL) -> String {
        let name = FileManager.default.displayName(atPath: appURL.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    /// Opens `url` if policy allows, otherwise shows a confirmation sheet on the key window.
    /// The sheet never activates the app; with no window at all the alert runs modally.
    @discardableResult
    static func confirmAndOpen(
        _ url: URL,
        defaults: UserDefaults = .standard,
        workspace: NSWorkspace = .shared,
        window: NSWindow? = nil,
        sourceHost: String? = nil,
        allowRememberedApproval: Bool = true
    ) -> Bool {
        let handlerURL = workspace.urlForApplication(toOpen: url)
        let handlerBundleIdentifier = handlerURL.flatMap { Bundle(url: $0)?.bundleIdentifier }
        let requirement = requirement(
            for: url,
            handlerBundleIdentifier: handlerBundleIdentifier,
            allowlist: allowlist(defaults: defaults),
            targetIsExecutable: targetIsExecutable(url),
            allowRememberedApproval: allowRememberedApproval
        )
        switch requirement {
        case .openWithoutPrompt:
            return workspace.open(url)
        case let .prompt(offerAlwaysAllow):
            let appName = handlerURL.map(applicationDisplayName(at:))
                ?? String(localized: "externalOpen.defaultAppName", defaultValue: "the default app")
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(localized: "externalOpen.title", defaultValue: "Open in \(appName)?")
            let target = url.isFileURL ? url.path : url.absoluteString
            if let sourceHost, !sourceHost.isEmpty {
                let format = String(localized: "shell.externalOpen.requestedBy", defaultValue: "Requested by %@")
                alert.informativeText = target + "\n\n" + String(format: format, sourceHost)
            } else {
                alert.informativeText = target
            }
            alert.addButton(withTitle: String(localized: "externalOpen.open", defaultValue: "Open"))
            alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
            if offerAlwaysAllow {
                alert.showsSuppressionButton = true
                alert.suppressionButton?.title = String(
                    localized: "externalOpen.alwaysAllow",
                    defaultValue: "Always allow for this app"
                )
            }
            let handleResponse: (NSApplication.ModalResponse) -> Void = { response in
                guard response == .alertFirstButtonReturn else { return }
                if offerAlwaysAllow,
                   alert.suppressionButton?.state == .on,
                   let handlerBundleIdentifier,
                   let scheme = url.scheme {
                    addToAllowlist(handlerBundleIdentifier, scheme: scheme, defaults: defaults)
                }
                if !workspace.open(url) {
                    NSLog("ExternalOpenPolicy: failed to open %@", url.absoluteString)
                }
            }
            // Prefer a sheet on the key window (no app activation). Without any window the alert
            // runs modally instead of refusing: a refusal would return false, and callers such as
            // the terminal link handler treat false as "let another opener handle it".
            //
            // Both branches are deferred. ghostty's link callback calls in with its renderer lock
            // held, and beginSheetModal is not safe there even though it returns immediately: it
            // makes the sheet key synchronously, the terminal view resigns first responder, and
            // ghostty_surface_set_focus waits forever on that same lock.
            DispatchQueue.main.async {
                if let sheetWindow = window ?? NSApp.keyWindow ?? NSApp.mainWindow {
                    alert.beginSheetModal(for: sheetWindow, completionHandler: handleResponse)
                } else {
                    handleResponse(alert.runModal())
                }
            }
            return true
        }
    }
}
