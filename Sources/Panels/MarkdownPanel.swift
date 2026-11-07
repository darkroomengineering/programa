import Foundation
import Bonsplit
import Combine

// MARK: - MarkdownSearchState

/// Observable state for find-in-markdown. Owned by MarkdownPanel while find is open.
final class MarkdownSearchState: ObservableObject {
    /// The current search needle typed by the user.
    @Published var needle: String = ""
    /// The exact plain text displayed by the native Find document.
    @Published var searchText: String = ""
    /// UTF-16 ranges in searchText, suitable for NSTextView selection.
    @Published var matches: [NSRange] = []
    /// Index of the currently selected match, or nil when no matches.
    @Published var currentIndex: Int? = nil

    var selectedRange: NSRange? {
        guard let currentIndex, matches.indices.contains(currentIndex) else { return nil }
        return matches[currentIndex]
    }
}

// MARK: - MarkdownPanel

/// A panel that renders a markdown file with live file-watching.
/// When the file changes on disk, the content is automatically reloaded.
@MainActor
final class MarkdownPanel: Panel, ObservableObject {
    let id: UUID
    let panelType: PanelType = .markdown

    /// Absolute path to the markdown file being displayed.
    let filePath: String

    private(set) var workspaceId: UUID

    /// Current markdown content read from the file.
    @Published private(set) var content: String = ""

    /// Title shown in the tab bar (filename).
    @Published private(set) var displayTitle: String = ""

    /// SF Symbol icon for the tab bar.
    var displayIcon: String? { "doc.richtext" }

    /// Whether the file has been deleted or is unreadable.
    @Published private(set) var isFileUnavailable: Bool = false

    /// True when the file is larger than `maxDisplayBytes` and only its first part is shown.
    @Published private(set) var isTruncated: Bool = false

    /// Largest prefix of the file that is read and rendered. A multi-megabyte file would
    /// otherwise stall the main thread in the markdown renderer.
    nonisolated static let maxDisplayBytes = 2 * 1024 * 1024

    /// Token incremented to trigger focus flash animation.
    @Published private(set) var focusFlashToken: Int = 0

    /// Non-nil while the find bar is visible.
    @Published var searchState: MarkdownSearchState? = nil

    // MARK: - File watching

    private final class WatchResource {
        let source: DispatchSourceFileSystemObject

        init(source: DispatchSourceFileSystemObject) {
            self.source = source
        }

        deinit {
            source.cancel()
        }
    }

    private enum WatchState {
        case stopped
        case closed
        case watching(UUID, WatchResource)
        case debouncing(UUID, WatchResource, UUID, DispatchWorkItem)
        case reattaching(UUID, Int)

        var resource: WatchResource? {
            switch self {
            case .watching(_, let resource), .debouncing(_, let resource, _, _): return resource
            default: return nil
            }
        }

        var generation: UUID? {
            switch self {
            case .watching(let token, _), .debouncing(let token, _, _, _), .reattaching(let token, _): return token
            default: return nil
            }
        }
    }

    private var watchState: WatchState = .stopped
    private var isClosed: Bool {
        if case .closed = watchState { return true }
        return false
    }
    private let watchQueue = DispatchQueue(label: "com.darkroom.programa.markdown-file-watch", qos: .utility)

    /// Maximum number of reattach attempts after a file delete/rename event.
    private static let maxReattachAttempts = 6
    /// Delay between reattach attempts (total window: attempts * delay = 3s).
    private static let reattachDelay: TimeInterval = 0.5
    /// Content-change events inside this window collapse into one reload (editors and
    /// generators often write a file in many small chunks).
    private nonisolated static let reloadCoalesceDelay: TimeInterval = 0.15

    /// Bumped by every load request; a read that finishes after a newer request is dropped.
    private var loadGeneration: Int = 0

    // MARK: - Find state plumbing

    /// Cancellable for the needle-change subscription that recomputes matches.
    private var searchSubscription: AnyCancellable? = nil

    // MARK: - Init

    init(workspaceId: UUID, filePath: String) {
        self.id = UUID()
        self.workspaceId = workspaceId
        self.filePath = filePath
        self.displayTitle = (filePath as NSString).lastPathComponent

        loadFileContent()
        startFileWatcher()
        if watchState.resource == nil {
            // Session restore can create a panel before the file is recreated.
            // Retry briefly so atomic-rename recreations can reconnect.
            scheduleReattach(attempt: 1)
        }
    }

    /// Called when the panel is re-attached to a different workspace (detach/move transfer).
    /// Mirrors `TerminalPanel.updateWorkspaceId` /
    /// `ReviewPanel.updateWorkspaceId`.
    func updateWorkspaceId(_ newWorkspaceId: UUID) {
        workspaceId = newWorkspaceId
    }

    // MARK: - Panel protocol

    func focus() {
        // Markdown panel is read-only; no first responder to manage.
    }

    func unfocus() {
        // No-op for read-only panel.
    }

    func close() {
        stopFileWatcher()
        watchState = .closed
        hideFind()
    }

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
        focusFlashToken += 1
    }

    // MARK: - Find in Markdown

    /// Open the find bar (or re-focus it if already open).
    func startFind() {
        guard !isClosed else { return }
        if searchState == nil {
            let state = MarkdownSearchState()
            state.searchText = isFileUnavailable ? "" : MarkdownDocumentSearch.text(from: content)
            searchState = state
            // Re-run match computation whenever the needle changes.
            searchSubscription = state.$needle
                .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
                .sink { [weak self] _ in
                    self?.recomputeMatches()
                }
        }
        recomputeMatches()
#if DEBUG
        dlog("markdown.find.start panel=\(id.uuidString.prefix(5))")
#endif
    }

    /// Advance to the next match (wraps around).
    func findNext() {
        guard let state = searchState, !state.matches.isEmpty else { return }
        let count = state.matches.count
        state.currentIndex = (state.currentIndex.map { $0 + 1 } ?? 0) % count
#if DEBUG
        dlog("markdown.find.next panel=\(id.uuidString.prefix(5)) idx=\(state.currentIndex ?? -1)/\(count)")
#endif
    }

    /// Advance to the previous match (wraps around).
    func findPrevious() {
        guard let state = searchState, !state.matches.isEmpty else { return }
        let count = state.matches.count
        state.currentIndex = state.currentIndex.map { ($0 - 1 + count) % count } ?? (count - 1)
#if DEBUG
        dlog("markdown.find.previous panel=\(id.uuidString.prefix(5)) idx=\(state.currentIndex ?? -1)/\(count)")
#endif
    }

    /// Close the find bar and discard search state.
    func hideFind() {
        searchSubscription = nil
        searchState?.searchText = ""
        searchState?.matches = []
        searchState?.currentIndex = nil
        searchState = nil
#if DEBUG
        dlog("markdown.find.hide panel=\(id.uuidString.prefix(5))")
#endif
    }

    /// Collect case-insensitive matches in the exact displayed Find text.
    private func recomputeMatches() {
        guard let state = searchState else { return }
        guard !state.needle.isEmpty else {
            state.matches = []
            state.currentIndex = nil
            return
        }
        let text = state.searchText
        var result: [NSRange] = []
        var searchRange = text.startIndex..<text.endIndex
        while let range = text.range(of: state.needle, options: .caseInsensitive, range: searchRange) {
            guard !range.isEmpty else { break }
            result.append(NSRange(range, in: text))
            guard range.upperBound < text.endIndex else { break }
            searchRange = range.upperBound..<text.endIndex
        }
        state.matches = result
        if result.isEmpty {
            state.currentIndex = nil
        } else if state.currentIndex == nil {
            state.currentIndex = 0
        } else if let current = state.currentIndex, current >= result.count {
            state.currentIndex = result.count - 1
        }
    }

    // MARK: - File I/O

    /// Reads the file off the main thread and publishes the result when it lands. Only the
    /// newest request applies, so an older slow read never overwrites newer content.
    private func loadFileContent() {
        guard !isClosed else { return }
        loadGeneration &+= 1
        let generation = loadGeneration
        let path = filePath
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Self.readDisplayableContent(atPath: path, maxBytes: Self.maxDisplayBytes)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.applyLoadedContent(result, generation: generation)
                }
            }
        }
    }

    private func applyLoadedContent(_ result: LoadedContent?, generation: Int) {
        guard !isClosed, generation == loadGeneration else { return }
        if let result {
            content = result.text
            isTruncated = result.isTruncated
            isFileUnavailable = false
        } else {
            content = ""
            isTruncated = false
            isFileUnavailable = true
        }
        if let state = searchState {
            state.searchText = isFileUnavailable ? "" : MarkdownDocumentSearch.text(from: content)
            recomputeMatches()
        }
    }

    struct LoadedContent: Equatable, Sendable {
        let text: String
        let isTruncated: Bool
    }

    /// Returns the first `maxBytes` of a regular file (symlinks followed) decoded as UTF-8,
    /// falling back to ISO Latin-1, which accepts all 256 byte values and covers legacy
    /// encodings like Windows-1252. Returns nil for a missing, unreadable or non-regular file
    /// (a FIFO or device would block or never end).
    nonisolated static func readDisplayableContent(atPath path: String, maxBytes: Int) -> LoadedContent? {
        var info = stat()
        guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes + 1) ?? Data() else { return nil }
        let isTruncated = data.count > maxBytes
        let bytes = isTruncated ? data.prefix(maxBytes) : data
        if let text = String(data: bytes, encoding: .utf8) {
            return LoadedContent(text: text, isTruncated: isTruncated)
        }
        if isTruncated {
            // The cut can land inside a multi-byte scalar; drop at most 3 trailing bytes.
            for trim in 1...3 where bytes.count > trim {
                if let text = String(data: bytes.dropLast(trim), encoding: .utf8) {
                    return LoadedContent(text: text, isTruncated: true)
                }
            }
        }
        guard let text = String(data: bytes, encoding: .isoLatin1) else { return nil }
        return LoadedContent(text: text, isTruncated: isTruncated)
    }

    // MARK: - File watcher via DispatchSource

    private func startFileWatcher() {
        guard !isClosed else { return }
        stopFileWatcher()
        let fd = open(filePath, O_EVTONLY)
        guard fd >= 0 else { return }
        let generation = UUID()

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend],
            queue: watchQueue
        )

        source.setEventHandler { [weak self] in
            let flags = source.data
            DispatchQueue.main.async {
                guard let self, self.watchState.generation == generation else { return }
                if flags.contains(.delete) || flags.contains(.rename) {
                    self.stopFileWatcher()
                    self.loadFileContent()
                    if FileManager.default.fileExists(atPath: self.filePath) {
                        self.startFileWatcher()
                    }
                    if self.watchState.resource == nil {
                        self.scheduleReattach(attempt: 1)
                    }
                } else {
                    if case .debouncing(_, _, _, let pending) = self.watchState {
                        pending.cancel()
                    }
                    let reloadToken = UUID()
                    let reload = DispatchWorkItem { [weak self] in
                        guard let self,
                              case .debouncing(let currentGeneration, let currentSource, let currentReload, _) = self.watchState,
                              currentGeneration == generation, currentReload == reloadToken else { return }
                        self.watchState = .watching(generation, currentSource)
                        self.loadFileContent()
                    }
                    guard let resource = self.watchState.resource else { return }
                    self.watchState = .debouncing(generation, resource, reloadToken, reload)
                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.reloadCoalesceDelay, execute: reload)
                }
            }
        }

        source.setCancelHandler {
            Darwin.close(fd)
        }

        watchState = .watching(generation, WatchResource(source: source))
        source.resume()
    }

    /// Retry reattaching the file watcher up to `maxReattachAttempts` times.
    /// Each attempt checks if the file has reappeared. Bails out early if
    /// the panel has been closed.
    private func scheduleReattach(attempt: Int) {
        guard !isClosed, attempt <= Self.maxReattachAttempts else { return }
        let generation = UUID()
        watchState = .reattaching(generation, attempt)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.reattachDelay) { [weak self] in
            guard let self,
                  case .reattaching(let currentGeneration, let currentAttempt) = self.watchState,
                  currentGeneration == generation, currentAttempt == attempt else { return }
            self.watchState = .stopped
            if FileManager.default.fileExists(atPath: self.filePath) {
                self.loadFileContent()
                self.startFileWatcher()
            } else {
                self.scheduleReattach(attempt: attempt + 1)
            }
        }
    }

    private func stopFileWatcher() {
        if case .debouncing(_, _, _, let pending) = watchState {
            pending.cancel()
        }
        watchState.resource?.source.cancel()
        if !isClosed { watchState = .stopped }
    }

}
