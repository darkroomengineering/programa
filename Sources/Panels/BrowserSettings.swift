import Foundation
import WebKit
import AppKit

enum GhosttyBackgroundTheme {
    static func clampedOpacity(_ opacity: Double) -> CGFloat {
        CGFloat(max(0.0, min(1.0, opacity)))
    }

    static func color(backgroundColor: NSColor, opacity: Double) -> NSColor {
        backgroundColor.withAlphaComponent(clampedOpacity(opacity))
    }

    static func color(
        from notification: Notification?,
        fallbackColor: NSColor,
        fallbackOpacity: Double
    ) -> NSColor {
        let userInfo = notification?.userInfo
        let backgroundColor =
            (userInfo?[GhosttyNotificationKey.backgroundColor] as? NSColor)
            ?? fallbackColor

        let opacity: Double
        if let value = userInfo?[GhosttyNotificationKey.backgroundOpacity] as? Double {
            opacity = value
        } else if let value = userInfo?[GhosttyNotificationKey.backgroundOpacity] as? NSNumber {
            opacity = value.doubleValue
        } else {
            opacity = fallbackOpacity
        }

        return color(backgroundColor: backgroundColor, opacity: opacity)
    }

    static func color(from notification: Notification?) -> NSColor {
        color(
            from: notification,
            fallbackColor: GhosttyApp.shared.defaultBackgroundColor,
            fallbackOpacity: GhosttyApp.shared.defaultBackgroundOpacity
        )
    }

    static func currentColor() -> NSColor {
        color(
            backgroundColor: GhosttyApp.shared.defaultBackgroundColor,
            opacity: GhosttyApp.shared.defaultBackgroundOpacity
        )
    }
}

enum BrowserSearchEngine: String, CaseIterable, Identifiable {
    case google
    case duckduckgo
    case bing
    case kagi
    case startpage

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .google: return "Google"
        case .duckduckgo: return "DuckDuckGo"
        case .bing: return "Bing"
        case .kagi: return "Kagi"
        case .startpage: return "Startpage"
        }
    }

    func searchURL(query: String) -> URL? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var components: URLComponents?
        switch self {
        case .google:
            components = URLComponents(string: "https://www.google.com/search")
        case .duckduckgo:
            components = URLComponents(string: "https://duckduckgo.com/")
        case .bing:
            components = URLComponents(string: "https://www.bing.com/search")
        case .kagi:
            components = URLComponents(string: "https://kagi.com/search")
        case .startpage:
            components = URLComponents(string: "https://www.startpage.com/do/dsearch")
        }

        components?.queryItems = [
            URLQueryItem(name: "q", value: trimmed),
        ]
        return components?.url
    }
}

enum BrowserSearchSettings {
    static let searchEngineKey = "browserSearchEngine"
    static let searchSuggestionsEnabledKey = "browserSearchSuggestionsEnabled"
    static let defaultSearchEngine: BrowserSearchEngine = .google
    static let defaultSearchSuggestionsEnabled: Bool = true

    static func currentSearchEngine(defaults: UserDefaults = .standard) -> BrowserSearchEngine {
        guard let raw = defaults.string(forKey: searchEngineKey),
              let engine = BrowserSearchEngine(rawValue: raw) else {
            return defaultSearchEngine
        }
        return engine
    }

    static func currentSearchSuggestionsEnabled(defaults: UserDefaults = .standard) -> Bool {
        // Mirror @AppStorage behavior: bool(forKey:) returns false if key doesn't exist.
        // Default to enabled unless user explicitly set a value.
        if defaults.object(forKey: searchSuggestionsEnabledKey) == nil {
            return defaultSearchSuggestionsEnabled
        }
        return defaults.bool(forKey: searchSuggestionsEnabledKey)
    }
}

enum BrowserThemeMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system:
            return String(localized: "theme.system", defaultValue: "System")
        case .light:
            return String(localized: "theme.light", defaultValue: "Light")
        case .dark:
            return String(localized: "theme.dark", defaultValue: "Dark")
        }
    }

    var iconName: String {
        switch self {
        case .system:
            return "circle.lefthalf.filled"
        case .light:
            return "sun.max"
        case .dark:
            return "moon"
        }
    }
}

enum BrowserThemeSettings {
    static let modeKey = "browserThemeMode"
    static let legacyForcedDarkModeEnabledKey = "browserForcedDarkModeEnabled"
    static let defaultMode: BrowserThemeMode = .system

    static func mode(for rawValue: String?) -> BrowserThemeMode {
        guard let rawValue, let mode = BrowserThemeMode(rawValue: rawValue) else {
            return defaultMode
        }
        return mode
    }

    /// - Parameter domainName: The CFPreferences domain backing `defaults` (the app's bundle
    ///   identifier for `.standard`, or the suite name passed to `UserDefaults(suiteName:)`).
    ///   Used to read only the value actually PERSISTED in that domain, ignoring anything
    ///   supplied via `UserDefaults.register(defaults:)`. Foundation applies a registered
    ///   default across every `UserDefaults` instance in the process — not just the one
    ///   `register(defaults:)` was called on (e.g. `BrowserPanelView`'s `.onAppear` registers
    ///   `modeKey: defaultMode.rawValue` on `.standard`, and that default then resolves via
    ///   `string(forKey:)`/`object(forKey:)` on any other suite too). Without filtering it out
    ///   here, that registered default makes `modeKey` look like it was already explicitly
    ///   chosen and permanently skips the legacy-flag migration below — for real users, not
    ///   just isolated test suites.
    static func mode(defaults: UserDefaults = .standard, domainName: String? = nil) -> BrowserThemeMode {
        let resolvedDomainName = domainName ?? Bundle.main.bundleIdentifier
        if let resolvedDomainName,
           let persistedModeRaw = defaults.persistentDomain(forName: resolvedDomainName)?[modeKey] as? String {
            return mode(for: persistedModeRaw)
        }

        // Migrate the legacy bool toggle only when the new mode key hasn't actually been
        // persisted yet (a registered-but-never-set default doesn't count — see above).
        if defaults.object(forKey: legacyForcedDarkModeEnabledKey) != nil {
            let migratedMode: BrowserThemeMode = defaults.bool(forKey: legacyForcedDarkModeEnabledKey) ? .dark : .system
            defaults.set(migratedMode.rawValue, forKey: modeKey)
            return migratedMode
        }

        return defaultMode
    }

    static func apply(_ mode: BrowserThemeMode, to webView: WKWebView) {
        switch mode {
        case .system:
            webView.appearance = nil
        case .light:
            webView.appearance = NSAppearance(named: .aqua)
        case .dark:
            webView.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

enum BrowserLinkOpenSettings {
    static let openTerminalLinksInProgramaBrowserKey = "browserOpenTerminalLinksInProgramaBrowser"
    static let defaultOpenTerminalLinksInProgramaBrowser: Bool = true

    static let interceptTerminalOpenCommandInProgramaBrowserKey = "browserInterceptTerminalOpenCommandInProgramaBrowser"
    static let defaultInterceptTerminalOpenCommandInProgramaBrowser: Bool = true

    static let browserHostWhitelistKey = "browserHostWhitelist"
    static let defaultBrowserHostWhitelist: String = ""
    static let browserExternalOpenPatternsKey = "browserExternalOpenPatterns"
    static let defaultBrowserExternalOpenPatterns: String = ""

    static let externalBrowserBundleIdentifierKey = "browserExternalBrowserBundleIdentifier"
    static let defaultExternalBrowserBundleIdentifier: String = ""

    static func openTerminalLinksInProgramaBrowser(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: openTerminalLinksInProgramaBrowserKey) == nil {
            return defaultOpenTerminalLinksInProgramaBrowser
        }
        return defaults.bool(forKey: openTerminalLinksInProgramaBrowserKey)
    }

    static func interceptTerminalOpenCommandInProgramaBrowser(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: interceptTerminalOpenCommandInProgramaBrowserKey) != nil {
            return defaults.bool(forKey: interceptTerminalOpenCommandInProgramaBrowserKey)
        }

        // Migrate existing behavior for users who only had the link-click toggle.
        if defaults.object(forKey: openTerminalLinksInProgramaBrowserKey) != nil {
            return defaults.bool(forKey: openTerminalLinksInProgramaBrowserKey)
        }

        return defaultInterceptTerminalOpenCommandInProgramaBrowser
    }

    static func initialInterceptTerminalOpenCommandInProgramaBrowserValue(defaults: UserDefaults = .standard) -> Bool {
        interceptTerminalOpenCommandInProgramaBrowser(defaults: defaults)
    }

    static func hostWhitelist(defaults: UserDefaults = .standard) -> [String] {
        let raw = defaults.string(forKey: browserHostWhitelistKey) ?? defaultBrowserHostWhitelist
        return raw
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func externalOpenPatterns(defaults: UserDefaults = .standard) -> [String] {
        let raw = defaults.string(forKey: browserExternalOpenPatternsKey) ?? defaultBrowserExternalOpenPatterns
        return raw
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    static func shouldOpenExternally(_ url: URL, defaults: UserDefaults = .standard) -> Bool {
        shouldOpenExternally(url.absoluteString, defaults: defaults)
    }

    static func shouldOpenExternally(_ rawURL: String, defaults: UserDefaults = .standard) -> Bool {
        let target = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return false }

        for rawPattern in externalOpenPatterns(defaults: defaults) {
            guard let (isRegex, value) = parseExternalPattern(rawPattern) else { continue }
            if isRegex {
                guard let regex = try? NSRegularExpression(pattern: value, options: [.caseInsensitive]) else { continue }
                let range = NSRange(target.startIndex..<target.endIndex, in: target)
                if regex.firstMatch(in: target, options: [], range: range) != nil {
                    return true
                }
            } else if target.range(of: value, options: [.caseInsensitive]) != nil {
                return true
            }
        }

        return false
    }

    static func externalBrowserBundleIdentifier(defaults: UserDefaults = .standard) -> String {
        let raw = defaults.string(forKey: externalBrowserBundleIdentifierKey) ?? defaultExternalBrowserBundleIdentifier
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func externalBrowserApplicationURL(bundleIdentifier: String, workspace: NSWorkspace = .shared) -> URL? {
        let trimmed = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return workspace.urlForApplication(withBundleIdentifier: trimmed)
    }

    /// Opens a web link outside Programa. Only http(s) URLs go to the preferred browser;
    /// mailto: keeps its macOS-registered handler. Every other scheme and every file
    /// target goes through `ExternalOpenPolicy` and opens only after the user confirms.
    /// The launch is asynchronous, so `true` means the launch (or the confirmation
    /// prompt) was dispatched, not that it finished; a launch error is logged, not surfaced.
    @discardableResult
    static func openExternally(
        _ url: URL,
        defaults: UserDefaults = .standard,
        workspace: NSWorkspace = .shared,
        sourceHost: String? = nil,
        allowRememberedApproval: Bool = true
    ) -> Bool {
        if !ExternalOpenPolicy.opensWithoutPrompt(url) {
            return ExternalOpenPolicy.confirmAndOpen(
                url,
                defaults: defaults,
                workspace: workspace,
                sourceHost: sourceHost,
                allowRememberedApproval: allowRememberedApproval
            )
        }
        let scheme = url.scheme?.lowercased()
        let isWebLink = scheme == "http" || scheme == "https"
        let bundleIdentifier = externalBrowserBundleIdentifier(defaults: defaults)
        if isWebLink,
           let appURL = externalBrowserApplicationURL(bundleIdentifier: bundleIdentifier, workspace: workspace)
            ?? browserOtherThanSelfWhenSelfIsDefault(for: url, workspace: workspace) {
            let configuration = NSWorkspace.OpenConfiguration()
            workspace.open([url], withApplicationAt: appURL, configuration: configuration) { _, error in
                if let error {
                    NSLog("BrowserLinkOpenSettings.openExternally: launching %@ for %@ failed: %@", appURL.path, url.absoluteString, error.localizedDescription)
                }
            }
            return true
        }
        if isWebLink, systemDefaultBrowserIsSelf(for: url, workspace: workspace) {
            // No other browser is installed. Handing the link to the system default would
            // send it straight back into Programa, so report that nothing was opened.
            return false
        }
        return workspace.open(url)
    }

    /// When Programa is the system default browser, `NSWorkspace.open` on a web link
    /// routes back into Programa. Links meant to leave Programa then go to the first
    /// other installed browser instead.
    static func browserOtherThanSelfWhenSelfIsDefault(for url: URL, workspace: NSWorkspace = .shared) -> URL? {
        guard systemDefaultBrowserIsSelf(for: url, workspace: workspace),
              let other = installedBrowsers(workspace: workspace).first else { return nil }
        return externalBrowserApplicationURL(bundleIdentifier: other.bundleIdentifier, workspace: workspace)
    }

    private static func systemDefaultBrowserIsSelf(for url: URL, workspace: NSWorkspace) -> Bool {
        guard let defaultAppURL = workspace.urlForApplication(toOpen: url),
              let defaultBundleIdentifier = Bundle(url: defaultAppURL)?.bundleIdentifier else { return false }
        return isProgramaBundleIdentifier(defaultBundleIdentifier)
    }

    /// Release, staging, Debug and every tagged dev build share this prefix. Another
    /// Programa build is never a useful "external" browser: the link would land in a
    /// second embedded browser instead of leaving Programa.
    static func isProgramaBundleIdentifier(_ bundleIdentifier: String) -> Bool {
        let base = "com.darkroom.programa"
        return bundleIdentifier == base
            || bundleIdentifier.hasPrefix(base + ".")
            || bundleIdentifier == Bundle.main.bundleIdentifier
    }

    static func installedBrowsers(workspace: NSWorkspace = .shared) -> [(bundleIdentifier: String, name: String)] {
        guard let exampleURL = URL(string: "https://example.com") else { return [] }
        var seen = Set<String>()
        var results: [(bundleIdentifier: String, name: String)] = []
        for appURL in workspace.urlsForApplications(toOpen: exampleURL) {
            guard let bundleIdentifier = Bundle(url: appURL)?.bundleIdentifier else { continue }
            if isProgramaBundleIdentifier(bundleIdentifier) { continue }
            guard !seen.contains(bundleIdentifier) else { continue }
            seen.insert(bundleIdentifier)
            var name = FileManager.default.displayName(atPath: appURL.path)
            if name.hasSuffix(".app") {
                name = String(name.dropLast(4))
            }
            results.append((bundleIdentifier: bundleIdentifier, name: name))
        }
        return results.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Check whether a hostname matches the configured whitelist.
    /// Empty whitelist means "allow all" (no filtering).
    /// Supports exact match and wildcard prefix (`*.example.com`).
    static func hostMatchesWhitelist(_ host: String, defaults: UserDefaults = .standard) -> Bool {
        let rawPatterns = hostWhitelist(defaults: defaults)
        if rawPatterns.isEmpty { return true }
        guard let normalizedHost = BrowserInsecureHTTPSettings.normalizeHost(host) else { return false }
        for rawPattern in rawPatterns {
            guard let pattern = normalizeWhitelistPattern(rawPattern) else { continue }
            if hostMatchesPattern(normalizedHost, pattern: pattern) {
                return true
            }
        }
        return false
    }

    private static func normalizeWhitelistPattern(_ rawPattern: String) -> String? {
        let trimmed = rawPattern
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("*.") {
            let suffixRaw = String(trimmed.dropFirst(2))
            guard let suffix = BrowserInsecureHTTPSettings.normalizeHost(suffixRaw) else { return nil }
            return "*.\(suffix)"
        }

        return BrowserInsecureHTTPSettings.normalizeHost(trimmed)
    }

    private static func hostMatchesPattern(_ host: String, pattern: String) -> Bool {
        if pattern.hasPrefix("*.") {
            let suffix = String(pattern.dropFirst(2))
            return host == suffix || host.hasSuffix(".\(suffix)")
        }
        return host == pattern
    }

    private static func parseExternalPattern(_ rawPattern: String) -> (isRegex: Bool, value: String)? {
        let trimmed = rawPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.lowercased().hasPrefix("re:") {
            let regexPattern = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !regexPattern.isEmpty else { return nil }
            return (isRegex: true, value: regexPattern)
        }

        return (isRegex: false, value: trimmed)
    }
}

enum BrowserInsecureHTTPSettings {
    static let allowlistKey = "browserInsecureHTTPAllowlist"
    static let defaultAllowlistPatterns = [
        "localhost",
        "127.0.0.1",
        "::1",
        "0.0.0.0",
        "*.localtest.me",
    ]
    static let defaultAllowlistText = defaultAllowlistPatterns.joined(separator: "\n")

    static func normalizedAllowlistPatterns(defaults: UserDefaults = .standard) -> [String] {
        normalizedAllowlistPatterns(rawValue: defaults.string(forKey: allowlistKey))
    }

    static func normalizedAllowlistPatterns(rawValue: String?) -> [String] {
        let source: String
        if let rawValue, !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            source = rawValue
        } else {
            source = defaultAllowlistText
        }
        let parsed = parsePatterns(from: source)
        return parsed.isEmpty ? defaultAllowlistPatterns : parsed
    }

    static func isHostAllowed(_ host: String, defaults: UserDefaults = .standard) -> Bool {
        isHostAllowed(host, rawAllowlist: defaults.string(forKey: allowlistKey))
    }

    static func isHostAllowed(_ host: String, rawAllowlist: String?) -> Bool {
        guard let normalizedHost = normalizeHost(host) else { return false }
        return normalizedAllowlistPatterns(rawValue: rawAllowlist).contains { pattern in
            hostMatchesPattern(normalizedHost, pattern: pattern)
        }
    }

    static func addAllowedHost(_ host: String, defaults: UserDefaults = .standard) {
        guard let normalizedHost = normalizeHost(host) else { return }
        var patterns = normalizedAllowlistPatterns(defaults: defaults)
        guard !patterns.contains(normalizedHost) else { return }
        patterns.append(normalizedHost)
        defaults.set(patterns.joined(separator: "\n"), forKey: allowlistKey)
    }

    static func normalizeHost(_ rawHost: String) -> String? {
        var value = rawHost
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !value.isEmpty else { return nil }

        if let parsed = URL(string: value)?.host {
            return trimHost(parsed)
        }

        if let schemeRange = value.range(of: "://") {
            value = String(value[schemeRange.upperBound...])
        }

        if let slash = value.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            value = String(value[..<slash])
        }

        if value.hasPrefix("[") {
            if let closing = value.firstIndex(of: "]") {
                value = String(value[value.index(after: value.startIndex)..<closing])
            } else {
                value.removeFirst()
            }
        } else if let colon = value.lastIndex(of: ":"),
                  value[value.index(after: colon)...].allSatisfy(\.isNumber),
                  value.filter({ $0 == ":" }).count == 1 {
            value = String(value[..<colon])
        }

        return trimHost(value)
    }

    private static func parsePatterns(from rawValue: String) -> [String] {
        let separators = CharacterSet(charactersIn: ",;\n\r\t")
        var out: [String] = []
        var seen = Set<String>()
        for token in rawValue.components(separatedBy: separators) {
            guard let normalized = normalizePattern(token) else { continue }
            guard seen.insert(normalized).inserted else { continue }
            out.append(normalized)
        }
        return out
    }

    private static func normalizePattern(_ rawPattern: String) -> String? {
        let trimmed = rawPattern
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("*.") {
            let suffixRaw = String(trimmed.dropFirst(2))
            guard let suffix = normalizeHost(suffixRaw) else { return nil }
            return "*.\(suffix)"
        }

        return normalizeHost(trimmed)
    }

    private static func hostMatchesPattern(_ host: String, pattern: String) -> Bool {
        if pattern.hasPrefix("*.") {
            let suffix = String(pattern.dropFirst(2))
            return host == suffix || host.hasSuffix(".\(suffix)")
        }
        return host == pattern
    }

    private static func trimHost(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !trimmed.isEmpty else { return nil }

        // Canonicalize IDN entries (e.g. bücher.example -> xn--bcher-kva.example)
        // so user-entered allowlist patterns compare against URL.host consistently.
        if let canonicalized = URL(string: "https://\(trimmed)")?.host {
            return canonicalized
        }

        return trimmed
    }
}

func browserShouldBlockInsecureHTTPURL(
    _ url: URL,
    defaults: UserDefaults = .standard
) -> Bool {
    browserShouldBlockInsecureHTTPURL(
        url,
        rawAllowlist: defaults.string(forKey: BrowserInsecureHTTPSettings.allowlistKey)
    )
}

func browserShouldBlockInsecureHTTPURL(
    _ url: URL,
    rawAllowlist: String?
) -> Bool {
    guard url.scheme?.lowercased() == "http" else { return false }
    guard let host = BrowserInsecureHTTPSettings.normalizeHost(url.host ?? "") else { return true }
    return !BrowserInsecureHTTPSettings.isHostAllowed(host, rawAllowlist: rawAllowlist)
}

func browserShouldConsumeOneTimeInsecureHTTPBypass(
    _ url: URL,
    bypassHostOnce: inout String?
) -> Bool {
    guard let bypassHost = bypassHostOnce else { return false }
    guard url.scheme?.lowercased() == "http",
          let host = BrowserInsecureHTTPSettings.normalizeHost(url.host ?? "") else {
        return false
    }
    guard host == bypassHost else { return false }
    bypassHostOnce = nil
    return true
}

func browserShouldPersistInsecureHTTPAllowlistSelection(
    response: NSApplication.ModalResponse,
    suppressionEnabled: Bool
) -> Bool {
    guard suppressionEnabled else { return false }
    return response == .alertFirstButtonReturn || response == .alertSecondButtonReturn
}

func browserPreparedNavigationRequest(_ request: URLRequest) -> URLRequest {
    var preparedRequest = request
    // Match browser behavior for ordinary loads while preserving method/body/headers.
    preparedRequest.cachePolicy = .useProtocolCachePolicy
    return preparedRequest
}

func browserReadAccessURL(forLocalFileURL fileURL: URL, fileManager: FileManager = .default) -> URL? {
    guard fileURL.isFileURL, fileURL.path.hasPrefix("/") else { return nil }
    let path = fileURL.path
    var isDirectory: ObjCBool = false
    if fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
        return fileURL
    }

    let parent = fileURL.deletingLastPathComponent()
    guard !parent.path.isEmpty, parent.path.hasPrefix("/") else { return nil }
    return parent
}

@discardableResult
func browserLoadRequest(_ request: URLRequest, in webView: WKWebView) -> WKNavigation? {
    guard let url = request.url else { return nil }
    if url.isFileURL {
        guard let readAccessURL = browserReadAccessURL(forLocalFileURL: url) else { return nil }
        return webView.loadFileURL(url, allowingReadAccessTo: readAccessURL)
    }
    return webView.load(browserPreparedNavigationRequest(request))
}

private let browserEmbeddedNavigationSchemes: Set<String> = [
    "about",
    "applewebdata",
    "blob",
    "data",
    "file",
    "http",
    "https",
    "javascript",
]

func browserShouldOpenURLExternally(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty else { return false }
    return !browserEmbeddedNavigationSchemes.contains(scheme)
}

enum BrowserUserAgentSettings {
    // Force a Safari UA. Some WebKit builds return a minimal UA without Version/Safari tokens,
    // and some installs may have legacy Chrome UA overrides. Both can cause Google to serve
    // fallback/old UIs or trigger bot checks.
    static let safariUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.2 Safari/605.1.15"
}

/// Widened from `private` to `internal` (file-reorg for #99): also referenced by
/// `BrowserNavigationDelegate`/`BrowserUIDelegate` in BrowserPanelWebDelegates.swift.
enum BrowserInsecureHTTPNavigationIntent {
    case currentTab
    case newTab
}

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
    /// How recent a native click or key press on the originating web view must be for a
    /// remembered "Always allow" to skip the prompt. Script-forged navigation types do not count.
    static let nativeGestureWindow: TimeInterval = 1.0

    enum Requirement: Equatable {
        case openWithoutPrompt
        case prompt(offerAlwaysAllow: Bool)
    }

    static func opensWithoutPrompt(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return freeSchemes.contains(scheme)
    }

    /// Web pages may only reach the prompt through a real link click or form submit.
    static func navigationTypeHasUserGesture(_ type: WKNavigationType) -> Bool {
        type == .linkActivated || type == .formSubmitted
    }

    /// True when any of `timestamps` (system uptime, as `NSEvent.timestamp`) is within
    /// `nativeGestureWindow` before `now`.
    static func isRecentNativeGesture(_ timestamps: [TimeInterval?], now: TimeInterval) -> Bool {
        timestamps.contains { timestamp in
            guard let timestamp else { return false }
            let age = now - timestamp
            return age >= 0 && age <= nativeGestureWindow
        }
    }

    /// External open requested by web content. Needs a link-click/form navigation type; a
    /// remembered approval applies only after a native gesture on that web view, else it prompts.
    @discardableResult
    static func openFromWebContent(_ url: URL, navigationType: WKNavigationType, webView: WKWebView) -> Bool {
        guard navigationTypeHasUserGesture(navigationType) else { return false }
        let hadNativeGesture = (webView as? ProgramaWebView)?.hasRecentNativeGesture() ?? false
        return BrowserLinkOpenSettings.openExternally(
            url,
            sourceHost: webView.url?.host,
            allowRememberedApproval: hadNativeGesture
        )
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
