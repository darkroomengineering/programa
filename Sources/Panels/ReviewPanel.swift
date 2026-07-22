import Foundation
import Bonsplit

/// A panel that shows the git diff for another terminal surface ("the agent's pane"), with
/// line comments that can be sent back into that surface's input. Modeled directly on
/// `MarkdownPanel.swift`: read-only w.r.t. git (never mutates worktree/index/branches),
/// refresh-driven rather than continuously live. See docs/plans/diff-review-panel.md.
@MainActor
final class ReviewPanel: Panel, ObservableObject {
    let id: UUID
    let panelType: PanelType = .review

    /// The workspace this panel belongs to.
    private(set) var workspaceId: UUID

    /// The terminal surface being reviewed. `var` (not `let`) because session restore may need
    /// to remap this once the source terminal's own panel id has been re-created -- see
    /// `Workspace+Persistence.swift`'s post-restore fixup pass.
    var sourceSurfaceId: UUID

    /// Working directory anchor for git invocations (from `Workspace.panelDirectories` at
    /// creation time). `ReviewDiffProber` resolves the actual repo root from this via
    /// `git rev-parse --show-toplevel`.
    let directory: String

    @Published private(set) var mode: ReviewDiffMode
    @Published private(set) var baseBranch: String
    @Published private(set) var files: [ReviewFileDiff] = []
    @Published private(set) var comments: [ReviewComment] = []
    @Published private(set) var isRefreshing: Bool = false
    @Published private(set) var lastError: ReviewDiffError?
    @Published private(set) var lastRefreshedAt: Date?
    @Published private(set) var displayTitle: String = ""

    /// Token incremented to trigger the focus flash animation (mirrors `MarkdownPanel`).
    @Published private(set) var focusFlashToken: Int = 0

    var displayIcon: String? { "checklist" }

    /// Set by `Workspace.newReviewSplit` at creation time. Delivers serialized comment text
    /// into the reviewed terminal surface via the same path `surface.send_text` uses, then
    /// submits Enter (mirrors `agent.prompt`'s "type the prompt, press Enter" semantics). `nil`
    /// only in contexts where the panel was constructed without a live workspace.
    var sendToSourceSurface: ((String) -> Void)?

    init(workspaceId: UUID, sourceSurfaceId: UUID, directory: String, mode: ReviewDiffMode, baseBranch: String) {
        self.id = UUID()
        self.workspaceId = workspaceId
        self.sourceSurfaceId = sourceSurfaceId
        self.directory = directory
        self.mode = mode
        self.baseBranch = baseBranch
        self.displayTitle = Self.title(mode: mode, baseBranch: baseBranch)
    }

    private static func title(mode: ReviewDiffMode, baseBranch: String) -> String {
        switch mode {
        case .uncommitted:
            return String(localized: "review.title.uncommitted", defaultValue: "Review: Uncommitted")
        case .branch:
            return String(localized: "review.title.branch", defaultValue: "Review: vs \(baseBranch)")
        }
    }

    // MARK: - Panel protocol

    func focus() {
        // Read-only panel; no first responder of its own beyond the inline comment
        // composer, which SwiftUI manages via `@FocusState` in ReviewPanelView.
    }

    func unfocus() {
        // No-op.
    }

    func close() {
        // Nothing to tear down: no file watcher, no running subprocess is retained past
        // its own async callback.
    }

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
        focusFlashToken += 1
    }

    // MARK: - Mode

    func setMode(_ newMode: ReviewDiffMode, baseBranch newBaseBranch: String? = nil) {
        mode = newMode
        if let newBaseBranch {
            baseBranch = newBaseBranch
        }
        displayTitle = Self.title(mode: newMode, baseBranch: baseBranch)
        refresh()
    }

    // MARK: - Refresh

    /// Kicks off `ReviewDiffProber.diffSnapshot` on a background queue and publishes the
    /// result back on the main actor. Never blocks the caller -- see the socket threading
    /// policy in docs/plans/diff-review-panel.md §2.
    func refresh() {
        isRefreshing = true
        let capturedDirectory = directory
        let capturedMode = mode
        let capturedBaseBranch = baseBranch
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let snapshot = ReviewDiffProber.diffSnapshot(directory: capturedDirectory, mode: capturedMode, baseBranch: capturedBaseBranch)
            DispatchQueue.main.async {
                self?.apply(snapshot: snapshot)
            }
        }
    }

    /// Publishes an already-computed snapshot (used both by the async `refresh()` path above
    /// and by `review.open`, which computes the *first* snapshot synchronously off-main so the
    /// socket response can report an accurate `diffable_file_count` -- see
    /// `TerminalController+Review.swift`).
    func apply(snapshot: ReviewDiffSnapshot) {
        files = snapshot.files
        lastError = snapshot.error
        lastRefreshedAt = snapshot.generatedAt
        isRefreshing = false
        if case .branch = mode, let resolvedBaseBranch = snapshot.resolvedBaseBranch {
            baseBranch = resolvedBaseBranch
            displayTitle = Self.title(mode: mode, baseBranch: resolvedBaseBranch)
        }
        recomputeStaleComments()
#if DEBUG
        dlog("review.refresh panel=\(id.uuidString.prefix(5)) files=\(files.count) diffable=\(snapshot.diffableFileCount) error=\(String(describing: lastError))")
#endif
    }

    /// Comments are never dropped on refresh -- only flagged when their file/line range no
    /// longer exists. See docs/plans/diff-review-panel.md §3 point 3 / §5 risk 2.
    private func recomputeStaleComments() {
        guard !comments.isEmpty else { return }
        comments = comments.map { comment in
            var updated = comment
            updated.isStale = !lineRangeStillExists(filePath: comment.filePath, startLine: comment.startLine, endLine: comment.endLine)
            return updated
        }
    }

    private func lineRangeStillExists(filePath: String, startLine: Int, endLine: Int) -> Bool {
        guard let file = files.first(where: { $0.displayPath == filePath }), file.notDiffableReason == nil else {
            return false
        }
        let newLineNumbers = file.hunks.flatMap { $0.lines.compactMap(\.newLineNumber) }
        guard let maxLine = newLineNumbers.max() else { return false }
        return endLine <= maxLine
    }

    // MARK: - Comments

    @discardableResult
    func addComment(filePath: String, startLine: Int, endLine: Int? = nil, text: String) -> ReviewComment {
        let comment = ReviewComment(filePath: filePath, startLine: startLine, endLine: endLine, text: text)
        comments.append(comment)
        return comment
    }

    @discardableResult
    func removeComment(id commentId: UUID) -> Bool {
        guard let index = comments.firstIndex(where: { $0.id == commentId }) else { return false }
        comments.remove(at: index)
        return true
    }

    /// Serializes every pending comment via `ReviewCommentSerializer`. Empty string when there
    /// are no pending comments.
    func serializedPendingComments(preamble: String? = nil) -> String {
        ReviewCommentSerializer.serialize(comments: comments, preamble: preamble)
    }

    /// Clears every currently-pending comment. Called after `review.send_comments` (or the
    /// in-app "Send to agent" button) successfully delivers the serialized text.
    func clearSentComments() {
        comments.removeAll()
    }

    /// Serializes and delivers all pending comments into the source surface via
    /// `sendToSourceSurface`, then clears them. Returns `false` (no-op) when there is nothing
    /// pending -- sending zero comments is treated as a no-op, not a failure, mirroring
    /// `review.send_comments`'s socket response.
    @discardableResult
    func sendPendingComments(preamble: String? = nil) -> Int {
        let pendingCount = comments.count
        let serialized = serializedPendingComments(preamble: preamble)
        guard !serialized.isEmpty else { return 0 }
        sendToSourceSurface?(serialized)
        clearSentComments()
        return pendingCount
    }
}
