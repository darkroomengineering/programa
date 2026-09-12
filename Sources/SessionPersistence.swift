import CoreGraphics
import CryptoKit
import Foundation
import Bonsplit

enum SessionSnapshotSchema {
    static let currentVersion = 1
}

enum SessionPersistencePolicy {
    static let defaultSidebarWidth: Double = 240
    // Floor: traffic lights end ~79pt from the window edge (first center 24pt,
    // 24pt pitch, 14pt buttons); the right-aligned header controls occupy the
    // trailing ~120pt (panel inset 6 + hint clearance 18 + three buttons). 220
    // keeps a ~20pt gap between them; narrower collides in the header row.
    static let minimumSidebarWidth: Double = 220
    static let maximumSidebarWidth: Double = 600
    static let minimumWindowWidth: Double = 300
    static let minimumWindowHeight: Double = 200
    static let autosaveInterval: TimeInterval = 8.0
    static let maxWindowsPerSnapshot: Int = 12
    static let maxWorkspacesPerWindow: Int = 128
    static let maxPanelsPerWorkspace: Int = 512
    static let maxScrollbackLinesPerTerminal: Int = 4000
    static let maxScrollbackCharactersPerTerminal: Int = 400_000
    static let maxSnapshotHistoryEntries: Int = 10
    static let maxSnapshotBytes: Int = 128 * 1024 * 1024
    static let maxJSONNestingDepth: Int = 96
    static let maxLayoutDepth: Int = 64
    static let maxLayoutNodesPerWorkspace: Int = (maxPanelsPerWorkspace * 2) - 1
    static let maxTotalPanelsPerSnapshot: Int = 8_192
    static let maxMetadataStringBytes: Int = 64 * 1024
    static let maxPathStringBytes: Int = 16 * 1024
    static let maxURLStringBytes: Int = 64 * 1024
    static let maxBrowserHistoryEntriesPerDirection: Int = 2_048
    static let maxLogEntriesPerWorkspace: Int = 500
    static let maxReviewCommentsPerPanel: Int = 2_048

    static func sanitizedSidebarWidth(_ candidate: Double?) -> Double {
        let fallback = defaultSidebarWidth
        guard let candidate, candidate.isFinite else { return fallback }
        return min(max(candidate, minimumSidebarWidth), maximumSidebarWidth)
    }

    static func truncatedScrollback(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        if text.count <= maxScrollbackCharactersPerTerminal {
            return text
        }
        let initialStart = text.index(text.endIndex, offsetBy: -maxScrollbackCharactersPerTerminal)
        let safeStart = ansiSafeTruncationStart(in: text, initialStart: initialStart)
        return String(text[safeStart...])
    }

    /// If truncation starts in the middle of an ANSI CSI escape sequence, advance
    /// to the first printable character after that sequence to avoid replaying
    /// malformed control bytes.
    private static func ansiSafeTruncationStart(in text: String, initialStart: String.Index) -> String.Index {
        guard initialStart > text.startIndex else { return initialStart }
        let escape = "\u{001B}"

        guard let lastEscape = text[..<initialStart].lastIndex(of: Character(escape)) else {
            return initialStart
        }
        let csiMarker = text.index(after: lastEscape)
        guard csiMarker < text.endIndex, text[csiMarker] == "[" else {
            return initialStart
        }

        // If a final CSI byte exists before the truncation boundary, we are not
        // inside a partial sequence.
        if csiFinalByteIndex(in: text, from: csiMarker, upperBound: initialStart) != nil {
            return initialStart
        }

        // We are inside a CSI sequence. Skip to the first character after the
        // sequence terminator if it exists.
        guard let final = csiFinalByteIndex(in: text, from: csiMarker, upperBound: text.endIndex) else {
            return initialStart
        }
        let next = text.index(after: final)
        return next < text.endIndex ? next : text.endIndex
    }

    private static func csiFinalByteIndex(
        in text: String,
        from csiMarker: String.Index,
        upperBound: String.Index
    ) -> String.Index? {
        var index = text.index(after: csiMarker)
        while index < upperBound {
            guard let scalar = text[index].unicodeScalars.first?.value else {
                index = text.index(after: index)
                continue
            }
            if scalar >= 0x40, scalar <= 0x7E {
                return index
            }
            index = text.index(after: index)
        }
        return nil
    }
}

enum SessionRestorePolicy {
    static func isRunningUnderAutomatedTests(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        if environment["PROGRAMA_UI_TEST_MODE"] == "1" {
            return true
        }
        if environment.keys.contains(where: { $0.hasPrefix("PROGRAMA_UI_TEST_") }) {
            return true
        }
        if environment["XCTestConfigurationFilePath"] != nil {
            return true
        }
        if environment["XCTestBundlePath"] != nil {
            return true
        }
        if environment["XCTestSessionIdentifier"] != nil {
            return true
        }
        if environment["XCInjectBundle"] != nil {
            return true
        }
        if environment["XCInjectBundleInto"] != nil {
            return true
        }
        if environment["DYLD_INSERT_LIBRARIES"]?.contains("libXCTest") == true {
            return true
        }
        return false
    }

    static func shouldAttemptRestore(
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        if environment["PROGRAMA_DISABLE_SESSION_RESTORE"] == "1" {
            return false
        }
        if isRunningUnderAutomatedTests(environment: environment) {
            return false
        }

        // Any explicit launch argument is treated as an explicit open intent, except
        // launch-services process serial numbers and NSUserDefaults argument-domain
        // pairs (single-dash `-key value`), which configure preferences rather than
        // open anything. Double-dash options remain explicit intents.
        var extraArgs: [String] = []
        var skipValue = false
        for argument in arguments.dropFirst() {
            if skipValue {
                skipValue = false
                continue
            }
            if argument.hasPrefix("-psn_") { continue }
            if argument.hasPrefix("-"), !argument.hasPrefix("--"), argument.count > 1 {
                skipValue = true
                continue
            }
            extraArgs.append(argument)
        }
        return extraArgs.isEmpty
    }
}

struct SessionRectSnapshot: Codable, Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    init(_ rect: CGRect) {
        self.x = Double(rect.origin.x)
        self.y = Double(rect.origin.y)
        self.width = Double(rect.size.width)
        self.height = Double(rect.size.height)
    }

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

struct SessionDisplaySnapshot: Codable, Sendable {
    var displayID: UInt32?
    var stableID: String?
    var frame: SessionRectSnapshot?
    var visibleFrame: SessionRectSnapshot?
}

enum SessionSidebarSelection: String, Codable, Sendable, Equatable {
    case tabs
    case notifications

    init(selection: SidebarSelection) {
        switch selection {
        case .tabs:
            self = .tabs
        case .notifications:
            self = .notifications
        }
    }

    var sidebarSelection: SidebarSelection {
        switch self {
        case .tabs:
            return .tabs
        case .notifications:
            return .notifications
        }
    }
}

struct SessionSidebarSnapshot: Codable, Sendable {
    var isVisible: Bool
    var selection: SessionSidebarSelection
    var width: Double?
}

struct SessionStatusEntrySnapshot: Codable, Sendable {
    var key: String
    var value: String
    var icon: String?
    var color: String?
    var timestamp: TimeInterval
}

struct SessionLogEntrySnapshot: Codable, Sendable {
    var message: String
    var level: String
    var source: String?
    var timestamp: TimeInterval
}

struct SessionProgressSnapshot: Codable, Sendable {
    var value: Double
    var label: String?
}

struct SessionGitBranchSnapshot: Codable, Sendable {
    var branch: String
    var isDirty: Bool
}

struct SessionTerminalPanelSnapshot: Codable, Sendable {
    var workingDirectory: String?
    var scrollback: String?
}

struct SessionBrowserPanelSnapshot: Codable, Sendable {
    var urlString: String?
    var profileID: UUID?
    var shouldRenderWebView: Bool
    var pageZoom: Double
    var developerToolsVisible: Bool
    var backHistoryURLStrings: [String]?
    var forwardHistoryURLStrings: [String]?
}

struct SessionMarkdownPanelSnapshot: Codable, Sendable {
    var filePath: String
}

/// Session restore preserves pending comments, but re-runs `git diff` to validate their anchors
/// against fresh content. Missing comments in older snapshots decode as an empty draft list.
/// `sourceSurfaceId` is the OLD (pre-restore) panel id of the reviewed terminal; it is remapped
/// to the newly-restored panel id in a post-restore fixup pass (`Workspace+Persistence.swift`,
/// since the source terminal may live in a pane restored after this one).
struct SessionReviewPanelSnapshot: Codable, Sendable {
    var sourceSurfaceId: UUID
    var mode: String
    var baseBranch: String
    var comments: [ReviewComment]? = nil
}

struct SessionPanelSnapshot: Codable, Sendable {
    var id: UUID
    var type: PanelType
    var title: String?
    var customTitle: String?
    var directory: String?
    var isPinned: Bool
    var isManuallyUnread: Bool
    var gitBranch: SessionGitBranchSnapshot?
    var listeningPorts: [Int]
    var ttyName: String?
    var terminal: SessionTerminalPanelSnapshot?
    var browser: SessionBrowserPanelSnapshot?
    var markdown: SessionMarkdownPanelSnapshot?
    var review: SessionReviewPanelSnapshot?
}

enum SessionSplitOrientation: String, Codable, Sendable {
    case horizontal
    case vertical

    init(_ orientation: SplitOrientation) {
        switch orientation {
        case .horizontal:
            self = .horizontal
        case .vertical:
            self = .vertical
        }
    }

    var splitOrientation: SplitOrientation {
        switch self {
        case .horizontal:
            return .horizontal
        case .vertical:
            return .vertical
        }
    }
}

struct SessionPaneLayoutSnapshot: Codable, Sendable {
    var panelIds: [UUID]
    var selectedPanelId: UUID?
}

struct SessionSplitLayoutSnapshot: Codable, Sendable {
    var orientation: SessionSplitOrientation
    var dividerPosition: Double
    var first: SessionWorkspaceLayoutSnapshot
    var second: SessionWorkspaceLayoutSnapshot
}

indirect enum SessionWorkspaceLayoutSnapshot: Codable, Sendable {
    case pane(SessionPaneLayoutSnapshot)
    case split(SessionSplitLayoutSnapshot)

    private enum CodingKeys: String, CodingKey {
        case type
        case pane
        case split
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "pane":
            self = .pane(try container.decode(SessionPaneLayoutSnapshot.self, forKey: .pane))
        case "split":
            self = .split(try container.decode(SessionSplitLayoutSnapshot.self, forKey: .split))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unsupported layout node type: \(type)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pane(let pane):
            try container.encode("pane", forKey: .type)
            try container.encode(pane, forKey: .pane)
        case .split(let split):
            try container.encode("split", forKey: .type)
            try container.encode(split, forKey: .split)
        }
    }
}

struct SessionWorkspaceSnapshot: Codable, Sendable {
    var processTitle: String
    var customTitle: String?
    var customDescription: String?
    var customColor: String?
    var isPinned: Bool
    var currentDirectory: String
    var focusedPanelId: UUID?
    var layout: SessionWorkspaceLayoutSnapshot
    var panels: [SessionPanelSnapshot]
    var statusEntries: [SessionStatusEntrySnapshot]
    var logEntries: [SessionLogEntrySnapshot]
    var progress: SessionProgressSnapshot?
    var gitBranch: SessionGitBranchSnapshot?
    var worktreeFolderId: UUID? = nil
    var worktreeFolderRepoRoot: String? = nil
    var isWorktreeFolder: Bool? = nil
    var isWorktreeFolderCollapsed: Bool? = nil
    var worktreeBranch: String? = nil
}

struct SessionTabManagerSnapshot: Codable, Sendable {
    var selectedWorkspaceIndex: Int?
    var workspaces: [SessionWorkspaceSnapshot]
}

struct SessionWindowSnapshot: Codable, Sendable {
    var frame: SessionRectSnapshot?
    var display: SessionDisplaySnapshot?
    var tabManager: SessionTabManagerSnapshot
    var sidebar: SessionSidebarSnapshot
}

struct AppSessionSnapshot: Codable, Sendable {
    var version: Int
    var createdAt: TimeInterval
    var windows: [SessionWindowSnapshot]
    /// `nil` for snapshots written before this field existed -- treat as "unknown", not "unclean".
    var cleanShutdown: Bool?
}

enum SessionPersistenceStore {
    static func withoutScrollback(_ snapshot: AppSessionSnapshot) -> AppSessionSnapshot {
        var result = snapshot
        for window in result.windows.indices {
            for workspace in result.windows[window].tabManager.workspaces.indices {
                for panel in result.windows[window].tabManager.workspaces[workspace].panels.indices {
                    result.windows[window].tabManager.workspaces[workspace].panels[panel].terminal?.scrollback = nil
                }
            }
        }
        return result
    }
    static let historyDirectoryScanLimit = 256

    struct HistoryScanResult {
        let entries: [URL]
        let inspectedEntryCount: Int
    }

    static func load(fileURL: URL? = nil) -> AppSessionSnapshot? {
        guard let fileURL = fileURL ?? defaultSnapshotFileURL() else { return nil }
        guard let data = boundedSnapshotData(at: fileURL),
              let snapshot = decodeSnapshot(from: data) else { return nil }
        guard snapshot.version == SessionSnapshotSchema.currentVersion else { return nil }
        guard !snapshot.windows.isEmpty else { return nil }
        return snapshot
    }

    /// Like `load(fileURL:)`, but when the primary snapshot exists and fails to decode or is on
    /// an unrecognized schema version, falls back to the newest usable archive in
    /// `session-history/` (see `rotateIntoHistory`, which -- run just before this at startup --
    /// already guarantees the previous launch's intact snapshot lives there) instead of dropping
    /// the whole session. Deliberately does NOT migrate an old-version history entry forward: a
    /// history entry that also fails the version check is treated the same as no history at all,
    /// and this returns nil exactly like `load(fileURL:)` would. Every outcome -- a used fallback
    /// or an exhausted one -- is reported to the release diagnostics log so a version-bump-after-
    /// update drop is distinguishable from real data loss (a silent primary-file-missing case,
    /// e.g. first launch, is neither -- no diagnostics line, matching `load(fileURL:)`).
    static func loadWithHistoryFallback(fileURL: URL? = nil, historyLookupLimit: Int = 5) -> AppSessionSnapshot? {
        guard let fileURL = fileURL ?? defaultSnapshotFileURL() else { return nil }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        guard let data = boundedSnapshotData(at: fileURL) else {
            return fallbackAfterPrimarySnapshotFailure(
                reason: "read_bounds",
                fileURL: fileURL,
                limit: historyLookupLimit
            )
        }

        guard let snapshot = decodeSnapshot(from: data) else {
            return fallbackAfterPrimarySnapshotFailure(
                reason: "decode_or_limits",
                fileURL: fileURL,
                limit: historyLookupLimit
            )
        }
        guard snapshot.version == SessionSnapshotSchema.currentVersion else {
            return fallbackAfterPrimarySnapshotFailure(reason: "version", fileURL: fileURL, limit: historyLookupLimit)
        }
        guard !snapshot.windows.isEmpty else {
            return fallbackAfterPrimarySnapshotFailure(reason: "empty", fileURL: fileURL, limit: historyLookupLimit)
        }
        return snapshot
    }

    private static func fallbackAfterPrimarySnapshotFailure(
        reason: String,
        fileURL: URL,
        limit: Int
    ) -> AppSessionSnapshot? {
        let quarantinedURL = quarantineInvalidSnapshot(fileURL: fileURL)
        guard let fallback = newestRestorableHistorySnapshot(fileURL: fileURL, limit: limit) else {
            dilog(
                "session.restore",
                "primary snapshot unusable reason=\(reason) quarantine=\(quarantinedURL?.lastPathComponent ?? "failed") fallback=none"
            )
            return nil
        }
        dilog(
            "session.restore",
            "primary snapshot unusable reason=\(reason) quarantine=\(quarantinedURL?.lastPathComponent ?? "failed") fallback=\(fallback.filename)"
        )
        return fallback.snapshot
    }

    /// Scans the newest `limit` archives belonging to this bundle (newest-first, per `historyFileURLs`) for the first one
    /// that decodes at the current schema version with at least one window. Capped rather than
    /// unbounded: a long-neglected `session-history/` directory should not turn a startup restore
    /// into an unbounded disk scan.
    private static func newestRestorableHistorySnapshot(
        fileURL: URL,
        limit: Int
    ) -> (snapshot: AppSessionSnapshot, filename: String)? {
        let archiveSuffix = "\(sanitizedBundleIdentifier(Bundle.main.bundleIdentifier)).json"
        let candidates = historyFileURLs(fileURL: fileURL)
            .filter { $0.lastPathComponent.split(separator: "-", maxSplits: 2).last == Substring(archiveSuffix) }
            .prefix(max(0, limit))
        for entry in candidates {
            guard let data = boundedSnapshotData(at: entry),
                  let snapshot = decodeSnapshot(from: data),
                  snapshot.version == SessionSnapshotSchema.currentVersion,
                  !snapshot.windows.isEmpty
            else { continue }
            return (snapshot, entry.lastPathComponent)
        }
        return nil
    }

    @discardableResult
    static func save(_ snapshot: AppSessionSnapshot, fileURL: URL? = nil) -> Bool {
        guard let fileURL = fileURL ?? defaultSnapshotFileURL(),
              isStructurallyValid(snapshot) else {
            return false
        }
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
            let data = try encodedSnapshotData(snapshot)
            guard data.count <= SessionPersistencePolicy.maxSnapshotBytes else { return false }
            if let existingData = boundedSnapshotData(at: fileURL), existingData == data {
                return true
            }
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    static func contentIdentity(for snapshot: AppSessionSnapshot) -> Data? {
        var normalized = snapshot
        normalized.createdAt = 0
        return canonicalContentIdentity(for: normalized)
    }

    static func canonicalContentIdentity<Value: Encodable>(for value: Value) -> Data? {
        guard let data = try? encodedData(value) else { return nil }
        return Data(SHA256.hash(data: data))
    }

    private static func encodedSnapshotData(_ snapshot: AppSessionSnapshot) throws -> Data {
        try encodedData(snapshot)
    }

    private static func encodedData<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    static func removeSnapshot(fileURL: URL? = nil) {
        guard let fileURL = fileURL ?? defaultSnapshotFileURL() else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }

    static func defaultSnapshotFileURL(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        appSupportDirectory: URL? = nil
    ) -> URL? {
        let resolvedAppSupport: URL
        if let appSupportDirectory {
            resolvedAppSupport = appSupportDirectory
        } else if let discovered = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            resolvedAppSupport = discovered
        } else {
            return nil
        }
        return resolvedAppSupport
            .appendingPathComponent("programa", isDirectory: true)
            .appendingPathComponent("session-\(sanitizedBundleIdentifier(bundleIdentifier)).json", isDirectory: false)
    }

    static func historyDirectoryURL(fileURL: URL? = nil) -> URL? {
        guard let fileURL = fileURL ?? defaultSnapshotFileURL() else { return nil }
        return fileURL
            .deletingLastPathComponent()
            .appendingPathComponent("session-history", isDirectory: true)
    }

    /// Newest-first list of archived snapshot files, or `[]` if none exist yet.
    static func historyFileURLs(
        fileURL: URL? = nil,
        scanLimit: Int = historyDirectoryScanLimit
    ) -> [URL] {
        guard let historyDirectory = historyDirectoryURL(fileURL: fileURL) else { return [] }
        return historyEntries(in: historyDirectory, scanLimit: scanLimit).entries
    }

    /// Decodes an archived (or live) snapshot file's bytes without enforcing the current
    /// schema version, so a caller can inspect `version`/`cleanShutdown` on an older file
    /// before deciding whether it is restorable.
    static func decodeSnapshot(from data: Data) -> AppSessionSnapshot? {
        guard data.count <= SessionPersistencePolicy.maxSnapshotBytes,
              isJSONNestingWithinLimit(data),
              let snapshot = try? JSONDecoder().decode(AppSessionSnapshot.self, from: data),
              isStructurallyValid(snapshot) else {
            return nil
        }
        return snapshot
    }

    /// The windows a restore should actually reconstruct. Startup restore already clamps to
    /// `maxWindowsPerSnapshot`; manual `snapshot restore` reads the same archives and must
    /// clamp identically, or a corrupt or hand-edited history file with thousands of windows
    /// freezes the app on the one command you reach for when recovering.
    static func windowsToRestore(
        from snapshot: AppSessionSnapshot,
        limit: Int = SessionPersistencePolicy.maxWindowsPerSnapshot
    ) -> [SessionWindowSnapshot] {
        Array(snapshot.windows.prefix(max(0, limit)))
    }

    /// Archives the current snapshot file into `session-history/` before anything else can
    /// overwrite it, so a launch that clobbers `session-<bundleId>.json` (a cold boot with no
    /// clean shutdown, or an explicit-open-intent launch that skips restore entirely) never
    /// destroys the previous layout for good. Copies rather than moves: the normal same-launch
    /// restore path still reads the live file afterward, unchanged. Best-effort throughout --
    /// every failure mode here must leave launch unaffected.
    @discardableResult
    static func rotateIntoHistory(
        fileURL: URL? = nil,
        now: Date = Date(),
        maxHistoryEntries: Int = SessionPersistencePolicy.maxSnapshotHistoryEntries,
        historyScanObserver: ((HistoryScanResult) -> Void)? = nil,
        includeScrollback: Bool = true
    ) -> Bool {
        guard let fileURL = fileURL ?? defaultSnapshotFileURL(),
              let historyDirectory = historyDirectoryURL(fileURL: fileURL),
              var data = boundedSnapshotData(at: fileURL) else {
            return false
        }
        if !includeScrollback {
            guard let snapshot = decodeSnapshot(from: data),
                  let metadata = try? encodedSnapshotData(withoutScrollback(snapshot)) else { return false }
            data = metadata
        }

        do {
            try FileManager.default.createDirectory(at: historyDirectory, withIntermediateDirectories: true)
        } catch {
            return false
        }

        let duplicateScan = historyEntries(in: historyDirectory, scanLimit: historyDirectoryScanLimit)
        historyScanObserver?(duplicateScan)
        if let newestEntry = duplicateScan.entries.first,
           let newestData = boundedSnapshotData(at: newestEntry),
           newestData == data {
            return false
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let modifiedAt = (attributes?[.modificationDate] as? Date) ?? now
        let filename = "\(historyTimestampFormatter.string(from: modifiedAt))-\(sanitizedBundleIdentifier(Bundle.main.bundleIdentifier)).json"
        let destination = historyDirectory.appendingPathComponent(filename, isDirectory: false)

        // Stage the copy beside the destination and swap it in, rather than deleting the
        // existing archive first. Second-resolution filenames mean two launches can land on
        // the same name, and a delete-then-copy that fails midway (full disk) would leave
        // neither the old archive nor the new one -- the exact loss this file exists to
        // prevent. The staging name is hidden and not `.json`, so it never reads back as a
        // history entry if we die before the swap.
        let staging = historyDirectory.appendingPathComponent(
            ".\(filename).staging-\(UUID().uuidString)",
            isDirectory: false
        )
        do {
            try data.write(to: staging)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            return false
        }

        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
            } else {
                try FileManager.default.moveItem(at: staging, to: destination)
            }
        } catch {
            try? FileManager.default.removeItem(at: staging)
            return false
        }

        let pruneScan = pruneHistory(in: historyDirectory, keeping: maxHistoryEntries)
        historyScanObserver?(pruneScan)
        return true
    }

    static func historyScan(
        fileURL: URL,
        scanLimit: Int = historyDirectoryScanLimit
    ) -> HistoryScanResult {
        guard let historyDirectory = historyDirectoryURL(fileURL: fileURL) else {
            return HistoryScanResult(entries: [], inspectedEntryCount: 0)
        }
        return historyEntries(in: historyDirectory, scanLimit: scanLimit)
    }

    private static func historyEntries(in directory: URL, scanLimit: Int) -> HistoryScanResult {
        let boundedLimit = min(max(0, scanLimit), historyDirectoryScanLimit)
        guard boundedLimit > 0,
              let enumerator = FileManager.default.enumerator(
                  at: directory,
                  includingPropertiesForKeys: nil,
                  options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
              ) else {
            return HistoryScanResult(entries: [], inspectedEntryCount: 0)
        }
        var inspectedEntryCount = 0
        var candidates: [URL] = []
        candidates.reserveCapacity(boundedLimit)
        while inspectedEntryCount < boundedLimit, let candidate = enumerator.nextObject() as? URL {
            inspectedEntryCount += 1
            if candidate.pathExtension == "json" {
                candidates.append(candidate)
            }
        }
        // Filenames are `<yyyyMMdd-HHmmss>-<bundleId>.json`; the fixed-width timestamp prefix
        // sorts newest-first lexicographically without needing to parse it back into a Date.
        candidates.sort { $0.lastPathComponent > $1.lastPathComponent }
        return HistoryScanResult(entries: candidates, inspectedEntryCount: inspectedEntryCount)
    }

    @discardableResult
    private static func pruneHistory(in directory: URL, keeping maxEntries: Int) -> HistoryScanResult {
        let scan = historyEntries(in: directory, scanLimit: historyDirectoryScanLimit)
        for staleEntry in scan.entries.dropFirst(max(0, maxEntries)) {
            try? FileManager.default.removeItem(at: staleEntry)
        }
        return scan
    }

    /// Reads at most one byte beyond the policy cap so a file that changes after its metadata
    /// is inspected still cannot force an unbounded allocation.
    static func boundedSnapshotData(
        at fileURL: URL,
        maximumBytes: Int = SessionPersistencePolicy.maxSnapshotBytes
    ) -> Data? {
        guard maximumBytes >= 0, maximumBytes < Int.max,
              let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return nil
        }
        defer { try? handle.close() }
        let data: Data
        do {
            data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        } catch {
            return nil
        }
        return data.count <= maximumBytes ? data : nil
    }

    /// Rejects adversarial recursive JSON before `JSONDecoder` constructs the indirect layout
    /// tree. Braces inside strings are ignored, including escaped quotes and backslashes.
    private static func isJSONNestingWithinLimit(_ data: Data) -> Bool {
        var depth = 0
        var inString = false
        var isEscaped = false

        for byte in data {
            if inString {
                if isEscaped {
                    isEscaped = false
                } else if byte == 0x5C {
                    isEscaped = true
                } else if byte == 0x22 {
                    inString = false
                }
                continue
            }

            switch byte {
            case 0x22:
                inString = true
            case 0x7B, 0x5B:
                depth += 1
                if depth > SessionPersistencePolicy.maxJSONNestingDepth { return false }
            case 0x7D, 0x5D:
                depth -= 1
                if depth < 0 { return false }
            default:
                break
            }
        }

        return depth == 0 && !inString && !isEscaped
    }

    private static func isStructurallyValid(_ snapshot: AppSessionSnapshot) -> Bool {
        guard snapshot.windows.count <= SessionPersistencePolicy.maxWindowsPerSnapshot else {
            return false
        }

        var totalPanels = 0
        for window in snapshot.windows {
            if let display = window.display,
               !isValidString(display.stableID) {
                return false
            }
            let workspaces = window.tabManager.workspaces
            guard workspaces.count <= SessionPersistencePolicy.maxWorkspacesPerWindow else {
                return false
            }
            for workspace in workspaces {
                guard workspace.panels.count <= SessionPersistencePolicy.maxPanelsPerWorkspace else {
                    return false
                }
                guard isValidString(workspace.processTitle),
                      isValidString(workspace.customTitle),
                      isValidString(workspace.customDescription),
                      isValidString(workspace.customColor),
                      isValidString(
                          workspace.currentDirectory,
                          maxBytes: SessionPersistencePolicy.maxPathStringBytes
                      ),
                      workspace.statusEntries.count <= SidebarTelemetryLimits.maxStatusEntries,
                      workspace.logEntries.count <= SessionPersistencePolicy.maxLogEntriesPerWorkspace,
                      isValidString(workspace.progress?.label),
                      isValidString(workspace.gitBranch?.branch),
                      isValidString(
                          workspace.worktreeFolderRepoRoot,
                          maxBytes: SessionPersistencePolicy.maxPathStringBytes
                      ),
                      isValidString(workspace.worktreeBranch),
                      workspace.statusEntries.allSatisfy(isValidStatusEntry),
                      workspace.logEntries.allSatisfy(isValidLogEntry),
                      workspace.panels.allSatisfy(isValidPanel) else {
                    return false
                }
                totalPanels += workspace.panels.count
                guard totalPanels <= SessionPersistencePolicy.maxTotalPanelsPerSnapshot else {
                    return false
                }

                var layoutNodeCount = 0
                var panelReferenceCount = 0
                guard isValidLayout(
                    workspace.layout,
                    depth: 1,
                    nodeCount: &layoutNodeCount,
                    panelReferenceCount: &panelReferenceCount
                ) else {
                    return false
                }
            }
        }
        return true
    }

    private static func isValidPanel(_ panel: SessionPanelSnapshot) -> Bool {
        guard isValidString(panel.title),
              isValidString(panel.customTitle),
              isValidString(panel.directory, maxBytes: SessionPersistencePolicy.maxPathStringBytes),
              isValidString(panel.ttyName),
              isValidString(panel.gitBranch?.branch),
              panel.listeningPorts.count <= SidebarTelemetryLimits.maxReportedPorts else {
            return false
        }

        if let terminal = panel.terminal {
            guard isValidString(
                terminal.workingDirectory,
                maxBytes: SessionPersistencePolicy.maxPathStringBytes
            ) else {
                return false
            }
            if let scrollback = terminal.scrollback {
                guard scrollback.count <= SessionPersistencePolicy.maxScrollbackCharactersPerTerminal,
                      scrollback.utf8.count <= SessionPersistencePolicy.maxScrollbackCharactersPerTerminal * 4 else {
                    return false
                }
            }
        }

        if let browser = panel.browser {
            guard isValidString(
                browser.urlString,
                maxBytes: SessionPersistencePolicy.maxURLStringBytes
            ),
            isValidURLHistory(browser.backHistoryURLStrings),
            isValidURLHistory(browser.forwardHistoryURLStrings) else {
                return false
            }
        }

        if let markdown = panel.markdown,
           !isValidString(
               markdown.filePath,
               maxBytes: SessionPersistencePolicy.maxPathStringBytes
           ) {
            return false
        }
        if let review = panel.review {
            let comments = review.comments ?? []
            guard isValidString(review.mode), isValidString(review.baseBranch),
                  comments.count <= SessionPersistencePolicy.maxReviewCommentsPerPanel,
                  Set(comments.map(\.id)).count == comments.count,
                  comments.allSatisfy(\.isValidForPersistence) else { return false }
        }
        return true
    }

    private static func isValidStatusEntry(_ entry: SessionStatusEntrySnapshot) -> Bool {
        entry.key.utf8.count <= SidebarTelemetryLimits.maxKeyBytes
            && entry.value.utf8.count <= SidebarTelemetryLimits.maxStatusValueBytes
            && SidebarTelemetryLimits.isWithinUTF8Limit(
                entry.icon,
                maxBytes: SidebarTelemetryLimits.maxStatusIconBytes
            )
            && SidebarTelemetryLimits.isWithinUTF8Limit(
                entry.color,
                maxBytes: SidebarTelemetryLimits.maxStatusColorBytes
            )
    }

    private static func isValidLogEntry(_ entry: SessionLogEntrySnapshot) -> Bool {
        entry.message.utf8.count <= SidebarTelemetryLimits.maxLogMessageBytes
            && entry.level.utf8.count <= SessionPersistencePolicy.maxMetadataStringBytes
            && SidebarTelemetryLimits.isWithinUTF8Limit(
                entry.source,
                maxBytes: SidebarTelemetryLimits.maxLogSourceBytes
            )
    }

    private static func isValidURLHistory(_ values: [String]?) -> Bool {
        guard let values else { return true }
        return values.count <= SessionPersistencePolicy.maxBrowserHistoryEntriesPerDirection
            && values.allSatisfy {
                $0.utf8.count <= SessionPersistencePolicy.maxURLStringBytes
            }
    }

    private static func isValidString(
        _ value: String?,
        maxBytes: Int = SessionPersistencePolicy.maxMetadataStringBytes
    ) -> Bool {
        value.map { $0.utf8.count <= maxBytes } ?? true
    }

    private static func isValidLayout(
        _ layout: SessionWorkspaceLayoutSnapshot,
        depth: Int,
        nodeCount: inout Int,
        panelReferenceCount: inout Int
    ) -> Bool {
        guard depth <= SessionPersistencePolicy.maxLayoutDepth else { return false }
        nodeCount += 1
        guard nodeCount <= SessionPersistencePolicy.maxLayoutNodesPerWorkspace else { return false }

        switch layout {
        case .pane(let pane):
            panelReferenceCount += pane.panelIds.count
            return panelReferenceCount <= SessionPersistencePolicy.maxPanelsPerWorkspace
        case .split(let split):
            return isValidLayout(
                split.first,
                depth: depth + 1,
                nodeCount: &nodeCount,
                panelReferenceCount: &panelReferenceCount
            ) && isValidLayout(
                split.second,
                depth: depth + 1,
                nodeCount: &nodeCount,
                panelReferenceCount: &panelReferenceCount
            )
        }
    }

    @discardableResult
    private static func quarantineInvalidSnapshot(fileURL: URL) -> URL? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let quarantineURL = fileURL.deletingPathExtension().appendingPathExtension(
            "invalid-\(UUID().uuidString).json-quarantine"
        )
        do {
            try FileManager.default.moveItem(at: fileURL, to: quarantineURL)
            return quarantineURL
        } catch {
            return nil
        }
    }

    private static let historyTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    private static func sanitizedBundleIdentifier(_ bundleIdentifier: String?) -> String {
        let bundleId = (bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? bundleIdentifier!
            : "com.darkroom.programa"
        return bundleId.replacingOccurrences(
            of: "[^A-Za-z0-9._-]",
            with: "_",
            options: .regularExpression
        )
    }
}

/// Disarms terminal modes that replayed scrollback can leave stuck "on".
///
/// Restored scrollback is a historical transcript, not a live stream. Every
/// `DECSET` in it was meant to be balanced by a `DECRST` from the program that
/// set it — but that program was killed by the relaunch and never got to send
/// one. Replaying those bytes into a fresh terminal therefore re-arms the mode
/// permanently.
///
/// Mouse tracking is the mode where this is visible: with 1003 (any-event
/// motion) and 1006 (SGR encoding) armed and no TUI left to consume the
/// reports, every mouse move is encoded and written to the pty as input. At a
/// bare zsh prompt ZLE swallows the `ESC[<` prefix, so the prompt fills with
/// literal `35;16;54M35;33;53M…` — the symptom seen after an update relaunch.
///
/// These sequences are fed into the terminal parser (never the pty), so the
/// revived shell is undisturbed.
enum TerminalReplayModeReset {
    /// `DECRST` for every mouse tracking mode — X10 (9), VT200/normal (1000),
    /// highlight (1001), button/cell-motion (1002), any-event/all-motion
    /// (1003) — and every mouse report encoding — UTF-8 (1005), SGR (1006),
    /// urxvt (1015), SGR-pixel (1016).
    static let mouseReportingReset =
        "\u{001B}[?9l"
        + "\u{001B}[?1000l"
        + "\u{001B}[?1001l"
        + "\u{001B}[?1002l"
        + "\u{001B}[?1003l"
        + "\u{001B}[?1005l"
        + "\u{001B}[?1006l"
        + "\u{001B}[?1015l"
        + "\u{001B}[?1016l"
        // Focus reporting (1004) is the same failure shape as mouse tracking:
        // left armed by a dead TUI, every focus change injects CSI I / CSI O
        // into the revived shell as input.
        + "\u{001B}[?1004l"

    /// State that makes the grid itself render wrong when a transcript leaves
    /// it armed. Ordered deliberately: leave the alternate screen first, so
    /// everything after it applies to the primary screen the shell is on.
    ///
    /// A window resize clears only one of these. `Terminal.resize()` in ghostty
    /// unconditionally resets the scrolling region, which is why a stuck
    /// `DECSTBM` (tmux's constant companion) heals when you drag the window.
    /// It never touches the active screen key, the wraparound bit, or the
    /// charset — so a shell stranded on the alternate screen, or with autowrap
    /// off, or with G0 left on line-drawing, stays broken through any number of
    /// resizes. That asymmetry is the whole reason this bug looks unfixable to
    /// some people and self-healing to others.
    /// Two sequences here move the cursor, and both are handled deliberately.
    ///
    /// `ESC[?1047l` rather than `ESC[?1049l`: ghostty's 1049-disable branch
    /// calls `restoreCursor()` unconditionally (`Terminal.zig:3022`), and
    /// `restoreCursor` with nothing previously saved homes the cursor to (0,0)
    /// (`Terminal.zig:1100`). Since most restarts involve no alternate screen
    /// at all, emitting 1049l would drop the revived prompt on top of the
    /// restored scrollback every time. 1047's switch is gated on the screen
    /// actually changing (`switchScreen` returns null otherwise,
    /// `Terminal.zig:2891`), so it is a true no-op when we are already on the
    /// primary screen and still rescues a shell stranded on the alternate one.
    ///
    /// `ESC[r` ends with `setCursorPos(1, 1)` (`Terminal.zig:1619`), so the
    /// margin reset is bracketed in DECSC/DECRC. The charset and origin resets
    /// must come BEFORE the DECSC, because DECRC restores both from the save
    /// (`Terminal.zig:1123-1124`) and would otherwise reinstate the bad ones.
    static let layoutStateReset =
        "\u{001B}[?1047l"   // leave the alternate screen if stranded on it
        + "\u{001B}(B"      // G0 back to ASCII (undo line-drawing)
        + "\u{001B})B"      // G1 back to ASCII
        + "\u{001B}[?6l"    // DECOM: origin mode off
        + "\u{001B}7"       // DECSC: save cursor, now with clean charset/origin
        + "\u{001B}[?69l"   // DECLRMM: left/right margin mode off
        + "\u{001B}[r"      // DECSTBM: full screen again (this homes the cursor)
        + "\u{001B}8"       // DECRC: put the cursor back where the replay left it
        + "\u{001B}[?7h"    // DECAWM: autowrap back on
        + "\u{001B}[?25h"   // cursor visible

    /// Everything a replayed transcript can leave armed, in one sequence.
    static let disableSequence = layoutStateReset + mouseReportingReset
}

/// Prepares fallback-restore scrollback text (pre-crash / clean-quit
/// transcript for a session whose child did not survive to be reattached)
/// for injection into a freshly spawned surface's revive-seed path
/// (`TerminalSurface.pendingReviveSeed` / `seedRevivedScrollbackIfPending`),
/// instead of the old temp-file + `PROGRAMA_RESTORE_SCROLLBACK_FILE` +
/// shell-rc-`cat` mechanism this replaces (formerly
/// `SessionScrollbackReplayStore`). A pure text transform now -- no temp
/// files, no environment variables, no shell integration involved -- because
/// the seed path bypasses the pty entirely (`ghostty_surface_process_output`)
/// exactly like the escrow-revive path already does. See
/// `TerminalSurface.createSurface`'s fresh-seed arm for how the result is
/// consumed and why `resetModes: false` is passed there (the mode reset is
/// already baked into this text, below).
enum SessionFreshSpawnScrollbackSeed {
    private static let ansiEscape = "\u{001B}"
    private static let ansiReset = "\u{001B}[0m"

    /// Returns nil when there is nothing usable to seed (missing, blank, or
    /// only whitespace) -- callers should treat nil as "spawn a plain fresh
    /// terminal, no seed".
    static func preparedText(for scrollback: String?) -> String? {
        guard let scrollback else { return nil }
        guard scrollback.contains(where: { !$0.isWhitespace }) else { return nil }
        // The WAL byte stream can begin mid-escape-sequence: log rotation and
        // ring overruns cut at byte boundaries, not sequence boundaries. When
        // the surviving tail lost its ESC[ prefix, the parameter remainder
        // ("38;5;114m") is plain text to every sanitizer below and renders
        // literally at the head of the replay (2026-08-20 update-reset report).
        // `truncatedScrollback`'s ANSI-safe start only guards its OWN cut, and
        // only runs at all when the text exceeds the length cap — so the head
        // must be repaired before anything else.
        let headRepaired = strippedOrphanedSequenceHead(scrollback)
        guard let truncated = SessionPersistencePolicy.truncatedScrollback(headRepaired) else { return nil }
        let sanitized = positioningSanitizedText(truncated)
        // Captured on the PRE-sanitization text, not the sanitized result:
        // `positioningSanitizedText` strips every DEC private mode sequence
        // (`ESC[?1003h` and friends are CSI) as width-dependent, which can
        // leave a line with zero escape bytes even though the raw WAL text
        // armed a mode that still needs undoing. See `ansiSafeReplayText`'s
        // doc comment for why the mode reset must fire independently of
        // what survives sanitization.
        return ansiSafeReplayText(sanitized, forceModeReset: truncated.contains(ansiEscape))
    }

    /// Drops an orphaned CSI parameter tail from the very start of replay
    /// text: CSI parameter/intermediate bytes (0x30-0x3F) followed by a final
    /// byte (0x40-0x7E), with no preceding ESC. To keep false positives out of
    /// legitimate prose ("1m 30s", "42x42 grid"), the fragment must contain at
    /// least one `;` or `?` — real-world orphans are multi-parameter SGR/mode
    /// sequences. A surviving single-parameter orphan renders as a couple of
    /// literal characters, which is tolerable; a stripped legitimate line is
    /// not. Bounded scan: parameter fragments are short.
    static func strippedOrphanedSequenceHead(_ text: String) -> String {
        var index = text.startIndex
        var sawSeparator = false
        var sawParameterByte = false
        var steps = 0
        while index < text.endIndex, steps < 64 {
            guard let scalar = text[index].unicodeScalars.first?.value else { break }
            if (0x30...0x3F).contains(scalar) {
                sawParameterByte = true
                if scalar == 0x3B || scalar == 0x3F { sawSeparator = true }
                index = text.index(after: index)
                steps += 1
                continue
            }
            if (0x40...0x7E).contains(scalar), sawParameterByte, sawSeparator {
                return String(text[text.index(after: index)...])
            }
            break
        }
        return text
    }

    /// Neutralizes width-dependent cursor-positioning escapes before replay.
    ///
    /// `SessionWALStore.readFallbackScrollbackText` (used whenever a session's
    /// child did not survive to be reattached -- e.g. after a reboot, which is
    /// the case this exists for) returns the *raw* PTY byte stream: the exact
    /// bytes the child wrote, unmodified. That stream carries absolute cursor
    /// moves (`ESC[r;cH`), relative moves, erase-line/-screen sequences, and
    /// `\r` overwrite runs (spinners, progress bars) -- all of which are only
    /// meaningful when replayed into a grid of the *exact* width/height they
    /// were captured at. The freshly spawned surface this text is seeded into
    /// is very likely a different width: the window frame has not yet settled
    /// when the seed is applied (see `TerminalSurface
    /// .isSessionRestoreSettling`'s doc comment for that race). Replaying
    /// position-dependent bytes into the wrong width scatters words to the
    /// wrong columns and superimposes distinct rows on top of each other --
    /// and no later resize can repair it, because the position data itself
    /// was wrong relative to the new grid the moment it landed.
    ///
    /// This walks each line as a virtual single-row cell buffer -- `\r`
    /// resets the write column to 0 (a real overwrite, not a clear: shorter
    /// replacement text leaves the tail of a longer previous write in place,
    /// exactly like a real terminal), `\b` moves it back one column, and
    /// erase-line escapes clear cells outright -- rather than trying to
    /// preserve any position-dependent escape verbatim. SGR (`ESC[...m`)
    /// color/attribute state is the one exception: it is width-independent,
    /// so it is tracked as per-cell state DURING the walk (`ReplayCell.sgr`)
    /// rather than stripped -- a later redraw's color correctly overwrites
    /// the color of the frame it overwrites, and a line's color sequences
    /// stay adjacent to the text they actually color instead of all being
    /// hoisted to the front (which would cancel out any balanced
    /// enable/reset pair before a single character was ever colored).
    /// Everything else -- OSC (hyperlink/title) sequences and all other CSI,
    /// including DEC private mode set/reset like `ESC[?1049h` -- is dropped
    /// outright: OSC carries no width dependence but also no value in a
    /// historical transcript, and a partial-match regex risks swallowing the
    /// rest of the line if its terminator was cut off by
    /// `SessionPersistencePolicy.truncatedScrollback`. DEC private modes are
    /// CSI too and are removed the same way, which means the replayed enable
    /// (`ESC[?1003h`) no longer survives to arm anything -- but that does
    /// NOT make `TerminalReplayModeReset.disableSequence` (appended by
    /// `ansiSafeReplayText` below) redundant: the disable list also
    /// neutralizes state that never went through this sanitizer's CSI/OSC
    /// removal in the first place (charset designation like `ESC(0` is a
    /// two-character escape, not CSI, and survives untouched -- exactly what
    /// `layoutStateReset`'s `ESC(B`/`ESC)B` exists to undo), so the reset
    /// must fire independent of whatever the sanitizer left behind. See
    /// `forceModeReset` in `preparedText(for:)`. The clean-quit snapshot path
    /// (`TerminalController.readTerminalTextForSnapshot`) only ever produces
    /// already-rendered rows carrying SGR, so this is a no-op there -- it is
    /// applied unconditionally rather than gated behind a "which path did
    /// this come from" flag.
    private static func positioningSanitizedText(_ text: String) -> String {
        // `split(omittingEmptySubsequences: false)` + `joined` round-trips a
        // trailing newline (and any blank lines) exactly, so no separate
        // trailing-newline bookkeeping is needed here.
        var rendition = ReplayRendition()
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { sanitizedLine(String($0), rendition: &rendition) }
            .joined(separator: "\n")
    }

    private static func sanitizedLine(_ line: String, rendition: inout ReplayRendition) -> String {
        // Cheap bypass: the overwhelming majority of lines in a scrollback
        // transcript are plain text with none of the three signals below.
        guard line.contains(where: { $0 == "\u{001B}" || $0 == "\r" || $0 == "\u{8}" }) else {
            return line
        }

        // A trailing `\r` immediately before the line boundary is the CR
        // half of a `\r\n` line ending written by the pty's ONLCR
        // translation, not an overwrite -- there is nothing after it to
        // overwrite with, so treating it as a real cursor move (which would
        // just reset the column to 0 right before the line ends) is
        // harmless either way, but stripping it here keeps the intent
        // explicit and matches the CRLF handling this function has always
        // had.
        var line = line
        while line.hasSuffix("\r") {
            line.removeLast()
        }

        let working = sanitizedWorkingText(line)
        return replayedLine(from: replayTokens(in: working), rendition: &rendition)
    }

    /// Produces a working string safe to tokenize for the cell walk:
    /// erase-line escapes become one of two sentinel control characters
    /// (`U{0}` = erase-to-end-of-line, `U{1}` = erase-entire-line), OSC and
    /// every other CSI are removed outright, and SGR (`ESC[...m`) is left
    /// entirely alone -- `replayTokens(in:)` recognizes it inline instead.
    /// `csiRegex`'s final-byte class deliberately excludes `m` so it never
    /// competes with SGR for the same bytes. The erase-line translation MUST
    /// run before the generic CSI strip, since `ESC[K`/`ESC[2K`/etc. are
    /// themselves valid CSI sequences and would otherwise be deleted before
    /// they could be turned into sentinels.
    private static func sanitizedWorkingText(_ line: String) -> String {
        var text = line
        text = replacingMatches(of: eraseToEndOfLineRegex, in: text, with: "\u{0}")
        text = replacingMatches(of: eraseEntireLineRegex, in: text, with: "\u{1}")
        text = replacingMatches(of: oscRegex, in: text, with: "")
        text = replacingMatches(of: csiRegex, in: text, with: "")
        text = replacingMatches(of: saveRestoreCursorRegex, in: text, with: "")
        return text
    }

    private static func replacingMatches(of regex: NSRegularExpression, in text: String, with replacement: String) -> String {
        let nsText = text as NSString
        return regex.stringByReplacingMatches(
            in: text,
            range: NSRange(location: 0, length: nsText.length),
            withTemplate: replacement
        )
    }

    /// One unit of replay input: either a single plain/control character, or
    /// one whole SGR escape sequence recognized as a unit (never split
    /// character-by-character, so a `\b` immediately after an SGR sequence
    /// -- see `replayedLine` -- can only ever delete a previously-written
    /// plain character, never a byte belonging to the escape itself).
    private enum ReplayToken {
        case char(Character)
        case sgr(String)
    }

    /// Splits `text` into `ReplayToken`s by locating every SGR match and
    /// treating everything between/around them as plain characters. SGR was
    /// deliberately left in place by `sanitizedWorkingText`, so this is the
    /// one point that recognizes it.
    private static func replayTokens(in text: String) -> [ReplayToken] {
        let nsText = text as NSString
        let matches = sgrRegex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return text.map(ReplayToken.char) }

        var tokens: [ReplayToken] = []
        var searchIndex = text.startIndex
        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }
            if searchIndex < range.lowerBound {
                tokens.append(contentsOf: text[searchIndex..<range.lowerBound].map(ReplayToken.char))
            }
            tokens.append(.sgr(String(text[range])))
            searchIndex = range.upperBound
        }
        if searchIndex < text.endIndex {
            tokens.append(contentsOf: text[searchIndex...].map(ReplayToken.char))
        }
        return tokens
    }

    /// A single replayed grid cell: the character last written there, and
    /// the SGR state active at the moment it was written. Overwriting a cell
    /// replaces both fields together, so a later redraw's color correctly
    /// wins over the frame it overwrites.
    private struct ReplayCell {
        var sgr: ReplayRendition
        var char: Character
    }

    /// Stores only active attributes, never the sequence history that produced them.
    /// Parsing follows the pinned Ghostty CSI/SGR parser, including its 24-parameter
    /// limit, saturating UInt16 parameters, and color-component truncation.
    private struct ReplayRendition: Equatable {
        private enum Color: Equatable {
            case palette(UInt8)
            case rgb(UInt8, UInt8, UInt8)

            func parameters(for target: Int) -> String {
                switch self {
                case .palette(let index):
                    if target != 58, index < 16 {
                        return String(target - 8 + Int(index) + (index >= 8 ? 52 : 0))
                    }
                    return "\(target);5;\(index)"
                case .rgb(let red, let green, let blue):
                    return "\(target);2;\(red);\(green);\(blue)"
                }
            }
        }

        private struct Parameter {
            var value: UInt16
            var colon: Bool
        }

        private var foreground: Color?
        private var background: Color?
        private var underlineColor: Color?
        private var underline: UInt16 = 0
        private var bold = false
        private var faint = false
        private var italic = false
        private var blink = false
        private var inverse = false
        private var invisible = false
        private var strikethrough = false
        private var overline = false

        var sequence: String {
            var attributes: [String] = []
            if bold { attributes.append("1") }
            if faint { attributes.append("2") }
            if italic { attributes.append("3") }
            if underline != 0 { attributes.append(underline == 1 ? "4" : "4:\(underline)") }
            if blink { attributes.append("5") }
            if inverse { attributes.append("7") }
            if invisible { attributes.append("8") }
            if strikethrough { attributes.append("9") }
            if overline { attributes.append("53") }
            if let foreground { attributes.append(foreground.parameters(for: 38)) }
            if let background { attributes.append(background.parameters(for: 48)) }
            if let underlineColor { attributes.append(underlineColor.parameters(for: 58)) }
            return ansiReset + attributes.map { "\u{001B}[\($0)m" }.joined()
        }

        mutating func apply(_ sequence: String) {
            var parameters: [Parameter] = []
            var accumulator = 0
            var hasDigits = false
            for byte in sequence.utf8.dropFirst(2).dropLast() {
                if byte == 0x3B || byte == 0x3A {
                    guard parameters.count < 24 else { return }
                    parameters.append(Parameter(value: UInt16(accumulator), colon: byte == 0x3A))
                    accumulator = 0
                    hasDigits = false
                } else {
                    guard (0x30...0x39).contains(byte) else { return }
                    accumulator = min(Int(UInt16.max), accumulator * 10 + Int(byte - 0x30))
                    hasDigits = true
                }
            }
            guard parameters.count < 24 else { return }
            if hasDigits {
                parameters.append(Parameter(value: UInt16(accumulator), colon: false))
            }
            if parameters.isEmpty {
                self = ReplayRendition()
                return
            }

            var index = 0
            func consumeColonGroup() {
                while index < parameters.count, parameters[index].colon { index += 1 }
                if index < parameters.count { index += 1 }
            }
            while index < parameters.count {
                let parameter = parameters[index]
                index += 1
                if parameter.colon, ![4, 38, 48, 58].contains(parameter.value) {
                    consumeColonGroup()
                    continue
                }
                switch parameter.value {
                case 0: self = ReplayRendition()
                case 1: bold = true
                case 2: faint = true
                case 3: italic = true
                case 4:
                    if parameter.colon {
                        guard index < parameters.count else { continue }
                        if parameters[index].colon {
                            consumeColonGroup()
                            continue
                        }
                        let style = parameters[index].value
                        underline = style <= 5 ? style : 1
                        index += 1
                    } else {
                        underline = 1
                    }
                case 5, 6: blink = true
                case 7: inverse = true
                case 8: invisible = true
                case 9: strikethrough = true
                case 21: underline = 2
                case 22:
                    bold = false
                    faint = false
                case 23: italic = false
                case 24: underline = 0
                case 25: blink = false
                case 27: inverse = false
                case 28: invisible = false
                case 29: strikethrough = false
                case 30...37: foreground = .palette(UInt8(parameter.value - 30))
                case 39: foreground = nil
                case 40...47: background = .palette(UInt8(parameter.value - 40))
                case 49: background = nil
                case 53: overline = true
                case 55: overline = false
                case 59: underlineColor = nil
                case 90...97: foreground = .palette(UInt8(parameter.value - 82))
                case 100...107: background = .palette(UInt8(parameter.value - 92))
                case 38, 48, 58:
                    guard index < parameters.count else { continue }
                    let color: Color
                    if parameters[index].value == 5, index + 1 < parameters.count {
                        color = .palette(UInt8(truncatingIfNeeded: parameters[index + 1].value))
                        index += 2
                    } else if parameters[index].value == 2, index + 3 < parameters.count {
                        var componentIndex = index + 1
                        if parameter.colon {
                            var end = index
                            while end < parameters.count - 1, parameters[end].colon { end += 1 }
                            switch end - index {
                            case 3: break
                            case 4: componentIndex += 1
                            default:
                                consumeColonGroup()
                                continue
                            }
                        }
                        color = .rgb(
                            UInt8(truncatingIfNeeded: parameters[componentIndex].value),
                            UInt8(truncatingIfNeeded: parameters[componentIndex + 1].value),
                            UInt8(truncatingIfNeeded: parameters[componentIndex + 2].value)
                        )
                        index = componentIndex + 3
                    } else {
                        continue
                    }
                    switch parameter.value {
                    case 38: foreground = color
                    case 48: background = color
                    default: underlineColor = color
                    }
                default: break
                }
            }
        }
    }

    /// Replays a line's tokens (see `replayTokens`) against a virtual
    /// single-row cell buffer, then re-emits it as text with SGR reinserted
    /// only where it actually changes cell-to-cell -- never re-stated on
    /// every cell, and never dropped when it changes back to "no color"
    /// (that transition emits a real `ESC[0m`, not silence, since a later
    /// terminal has no notion of an "empty" SGR state to fall back to). `\r`
    /// and `\b` move the write column without touching cell content -- a
    /// real terminal overwrite, not a clear -- so a shorter redraw correctly
    /// leaves the tail of a longer previous one in place.
    private static func replayedLine(from tokens: [ReplayToken], rendition: inout ReplayRendition) -> String {
        var cells: [ReplayCell] = []
        var cursor = 0
        var currentSGR = rendition

        for token in tokens {
            switch token {
            case .sgr(let sequence):
                currentSGR.apply(sequence)
            case .char(let char):
                switch char {
                case "\r":
                    cursor = 0
                case "\u{8}":
                    cursor = max(0, cursor - 1)
                case "\u{0}":
                    if cursor < cells.count {
                        cells.removeSubrange(cursor..<cells.count)
                    }
                case "\u{1}":
                    cells.removeAll()
                    cursor = 0
                default:
                    let cell = ReplayCell(sgr: currentSGR, char: char)
                    if cursor < cells.count {
                        cells[cursor] = cell
                    } else {
                        if cursor > cells.count {
                            cells.append(contentsOf: repeatElement(ReplayCell(sgr: ReplayRendition(), char: " "), count: cursor - cells.count))
                        }
                        cells.append(cell)
                    }
                    cursor += 1
                }
            }
        }

        var output = ""
        var lastEmittedSGR = rendition
        for cell in cells {
            if cell.sgr != lastEmittedSGR {
                output += cell.sgr.sequence
                lastEmittedSGR = cell.sgr
            }
            output.append(cell.char)
        }
        if currentSGR != lastEmittedSGR {
            output += currentSGR.sequence
        }
        rendition = currentSGR
        return output
    }

    /// `ESC[K` / `ESC[0K`: erase from the cursor to the end of the line.
    private static let eraseToEndOfLineRegex: NSRegularExpression = {
        let esc = "\u{001B}"
        // swiftlint:disable:next force_try
        return try! NSRegularExpression(pattern: esc + #"\[0?K"#)
    }()

    /// `ESC[1K` / `ESC[2K`: erase the whole line, cursor to column 0. (EL1
    /// technically erases only up to the cursor, not the whole line, but a
    /// scrollback replay has no reason to preserve that distinction -- both
    /// forms exist here only so a dead TUI's status-line redraw doesn't leave
    /// stale characters behind.)
    private static let eraseEntireLineRegex: NSRegularExpression = {
        let esc = "\u{001B}"
        // swiftlint:disable:next force_try
        return try! NSRegularExpression(pattern: esc + #"\[[12]K"#)
    }()

    /// Matches SGR (`ESC[...m`, including the bare `ESC[m` shorthand for
    /// reset). Used by `replayTokens(in:)` to recognize SGR as a unit within
    /// otherwise-plain text -- `sanitizedWorkingText` deliberately does not
    /// strip these, and `csiRegex` deliberately excludes them.
    private static let sgrRegex: NSRegularExpression = {
        let esc = "\u{001B}"
        // swiftlint:disable:next force_try
        return try! NSRegularExpression(pattern: esc + #"\[[0-9;:]*m"#)
    }()

    /// OSC (`ESC]...`) terminated by BEL or ST (`ESC\`). Requiring the
    /// terminator (rather than matching greedily to end-of-line) means a
    /// truncated/unterminated OSC left behind by
    /// `SessionPersistencePolicy.truncatedScrollback`'s cut simply fails to
    /// match and is left in place for the generic CSI/escape cleanup to
    /// ignore, instead of swallowing the rest of the line.
    private static let oscRegex: NSRegularExpression = {
        let esc = "\u{001B}"
        // swiftlint:disable:next force_try
        return try! NSRegularExpression(pattern: esc + #"\][^\x07\x1B]*(?:\x07|\x1B\\)"#)
    }()

    /// Generic CSI: `ESC[`, parameter bytes (`0x30`-`0x3F`: digits, `;`,
    /// `:`, `<=>?`), intermediate bytes (`0x20`-`0x2F`), one final byte
    /// (`0x40`-`0x7E`, i.e. `@`-`~`) -- EXCLUDING `m` (`0x6D`), which is SGR
    /// and is deliberately left for `replayTokens(in:)` to recognize inline
    /// rather than being stripped here. Matches every other CSI form --
    /// cursor moves, erase, scroll region, and DEC private mode set/reset
    /// alike -- which is why this must run after the erase-line translation
    /// above has already pulled those out.
    private static let csiRegex: NSRegularExpression = {
        let esc = "\u{001B}"
        // swiftlint:disable:next force_try
        return try! NSRegularExpression(pattern: esc + #"\[[\x30-\x3F]*[\x20-\x2F]*[\x40-\x6C\x6E-\x7E]"#)
    }()

    /// DECSC/DECRC (`ESC7`/`ESC8`), the two-character escapes not shaped
    /// like CSI or OSC and so not covered by either regex above.
    private static let saveRestoreCursorRegex: NSRegularExpression = {
        let esc = "\u{001B}"
        // swiftlint:disable:next force_try
        return try! NSRegularExpression(pattern: esc + #"[78]"#)
    }()

    /// Preserve ANSI color state safely across replay boundaries, disarm any
    /// terminal mode the replayed transcript leaves set (see
    /// `TerminalReplayModeReset`), and guarantee a trailing newline so the
    /// fresh shell's own first prompt lands on its own line below the
    /// replayed text rather than concatenated onto its last line.
    ///
    /// `forceModeReset` exists because `text.contains(ansiEscape)` is no
    /// longer sufficient on its own to decide whether a mode reset is
    /// needed: `positioningSanitizedText` can legitimately reduce a line to
    /// zero escape bytes (every CSI it contained, including DEC private mode
    /// sequences like `ESC[?1003h`, was width-dependent and got stripped),
    /// while the ORIGINAL pre-sanitization text still proves the transcript
    /// could have armed a mode that needs disarming. The reset is cheap and
    /// idempotent, so callers should pass `true` whenever the untouched
    /// source text contained any escape at all, regardless of what survived
    /// sanitization -- see `preparedText(for:)`.
    private static func ansiSafeReplayText(_ text: String, forceModeReset: Bool) -> String {
        guard text.contains(ansiEscape) || forceModeReset else { return ensuringTrailingNewline(text) }
        var output = text
        if !output.hasPrefix(ansiReset) {
            output = ansiReset + output
        }
        output += TerminalReplayModeReset.disableSequence
        if !output.hasSuffix(ansiReset) {
            output += ansiReset
        }
        return ensuringTrailingNewline(output)
    }

    private static func ensuringTrailingNewline(_ text: String) -> String {
        text.hasSuffix("\n") ? text : text + "\n"
    }
}
