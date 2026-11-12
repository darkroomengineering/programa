import Foundation
import Bonsplit

/// Why review comments were not delivered. They stay pending in every case.
enum ReviewCommentDeliveryFailure: Error, Equatable {
    case sourceUnavailable
    /// The source agent waits on a permission or sign-in prompt, so a paste could answer it.
    case awaitingApproval(PersonPromptHold)
}

enum ReviewCommentDelivery: Equatable {
    case sent
    case failed(ReviewCommentDeliveryFailure)
}

/// A panel that shows the git diff for another terminal surface ("the agent's pane"), with
/// line comments that can be sent back into that surface's input. Modeled directly on
/// `MarkdownPanel.swift`: never mutates the index or branches, and touches worktree files only
/// when the user confirms a checkpoint revert (`revertToLatestCheckpoint`). Refresh-driven
/// rather than continuously live. See docs/plans/diff-review-panel.md.
@MainActor
final class ReviewPanel: Panel, ObservableObject {
    private enum Operation<Value> {
        case settled(generation: UInt64, value: Value)
        case running(generation: UInt64, previous: Value)

        var generation: UInt64 {
            switch self {
            case .settled(let generation, _), .running(let generation, _): return generation
            }
        }

        var value: Value {
            switch self {
            case .settled(_, let value), .running(_, let value): return value
            }
        }

        var isRunning: Bool {
            if case .running = self { return true }
            return false
        }
    }

    let id: UUID
    let panelType: PanelType = .review

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
    var files: [ReviewFileDiff] { diffOperation.value?.files ?? [] }
    private(set) var filesRevision: UInt64 = 0
    /// The patch the Pierre diff viewer renders; entry `i` is `files[i]`.
    var viewerPatch: String { diffOperation.value?.viewerPatch ?? "" }
    @Published private(set) var comments: [ReviewComment] = []
    @Published private(set) var commentDeliveryFailure: ReviewCommentDeliveryFailure?
    @Published private var diffOperation: Operation<ReviewDiffSnapshot?> = .settled(generation: 0, value: nil)
    var isRefreshing: Bool { diffOperation.isRunning }
    var lastError: ReviewDiffError? { diffOperation.value?.error }
    var lastRefreshedAt: Date? { diffOperation.value?.generatedAt }
    @Published private(set) var displayTitle: String = ""
    /// Newest file checkpoint of the reviewed surface in this repo (`ReviewCheckpointStore`).
    @Published private var checkpointOperation: Operation<ReviewCheckpoint?> = .settled(generation: 0, value: nil)
    var latestCheckpoint: ReviewCheckpoint? { checkpointOperation.value }
    @Published private var restoreOperation: Operation<String?> = .settled(generation: 0, value: nil)
    var isRestoringCheckpoint: Bool { restoreOperation.isRunning }
    var checkpointRestoreError: String? {
        get { restoreOperation.value }
        set {
            switch restoreOperation {
            case .settled(let generation, _):
                restoreOperation = .settled(generation: generation, value: newValue)
            case .running(let generation, _):
                restoreOperation = .running(generation: generation, previous: newValue)
            }
        }
    }
    /// nil when the workspace has no GitHub pull request.
    @Published private var readinessOperation: Operation<ReviewMergeReadinessState?> = .settled(generation: 0, value: nil)
    var mergeReadiness: ReviewMergeReadinessState? { readinessOperation.value }
    var isRefreshingMergeReadiness: Bool { readinessOperation.isRunning }

    /// Token incremented to trigger the focus flash animation (mirrors `MarkdownPanel`).
    @Published private(set) var focusFlashToken: Int = 0

    /// Bumped by every `refresh()` call and by the public `apply(snapshot:)` fast path used by
    /// `review.open`. A completion only applies its snapshot when the generation it was issued
    /// under still matches -- this stops a slow probe from a stale request (e.g. a prior branch
    /// selection) from overwriting a newer result. See M12 in
    /// docs/audits/codebase-audit-2026-09-11.md.
    var refreshGeneration: UInt64 { diffOperation.generation }

    var displayIcon: String? { "checklist" }

    /// Set by `Workspace.newReviewSplit` at creation time. Delivers serialized comment text
    /// into the reviewed terminal surface via the same path `surface.send_text` uses, then
    /// submits Enter (mirrors `agent.prompt`'s "type the prompt, press Enter" semantics). `nil`
    /// only in contexts where the panel was constructed without a live workspace.
    var sendToSourceSurface: ((String) -> ReviewCommentDelivery)?

    init(workspaceId: UUID, sourceSurfaceId: UUID, directory: String, mode: ReviewDiffMode, baseBranch: String) {
        self.id = UUID()
        self.workspaceId = workspaceId
        self.sourceSurfaceId = sourceSurfaceId
        self.directory = directory
        self.mode = mode
        self.baseBranch = baseBranch
        self.displayTitle = Self.title(mode: mode, baseBranch: baseBranch)
    }

    /// Called when the panel is re-attached to a different workspace (detach/move transfer).
    /// Mirrors `TerminalPanel.updateWorkspaceId`.
    func updateWorkspaceId(_ newWorkspaceId: UUID) {
        workspaceId = newWorkspaceId
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

    // MARK: - Refresh

    /// Kicks off `ReviewDiffProber.diffSnapshot` on a background queue and publishes the
    /// result back on the main actor. Never blocks the caller -- see the socket threading
    /// policy in docs/plans/diff-review-panel.md §2.
    func refresh() {
        let generation = refreshGeneration &+ 1
        diffOperation = .running(generation: generation, previous: diffOperation.value)
        let capturedDirectory = directory
        let capturedMode = mode
        let capturedBaseBranch = baseBranch
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let snapshot = ReviewDiffProber.diffSnapshot(directory: capturedDirectory, mode: capturedMode, baseBranch: capturedBaseBranch)
            DispatchQueue.main.async {
                self?.apply(snapshot: snapshot, generation: generation)
            }
        }
    }

    /// Publishes an already-computed snapshot (used by `review.open`, which computes the
    /// *first* snapshot synchronously off-main so the socket response can report an accurate
    /// `diffable_file_count` -- see `TerminalController+Review.swift`). Bumps the refresh
    /// generation itself so that any `refresh()` still in flight from before this panel existed
    /// (or from a superseded request) is discarded when it later completes.
    func apply(snapshot: ReviewDiffSnapshot) {
        diffOperation = .running(generation: refreshGeneration &+ 1, previous: diffOperation.value)
        apply(snapshot: snapshot, generation: refreshGeneration)
    }

    /// Generation-checked apply used by both `refresh()`'s completion and the public
    /// `apply(snapshot:)` above. Discards `snapshot` without touching any published state when
    /// `generation` no longer matches `refreshGeneration`, i.e. a newer request has since been
    /// issued. `internal` (not `private`) so tests can exercise out-of-order completions
    /// directly -- see M12 in docs/audits/codebase-audit-2026-09-11.md.
    func apply(snapshot: ReviewDiffSnapshot, generation: UInt64) {
        guard generation == refreshGeneration else { return }
        filesRevision &+= 1
        diffOperation = .settled(generation: generation, value: snapshot)
        if case .branch = mode, let resolvedBaseBranch = snapshot.resolvedBaseBranch {
            baseBranch = resolvedBaseBranch
            displayTitle = Self.title(mode: mode, baseBranch: resolvedBaseBranch)
        }
        recomputeStaleComments()
        reloadLatestCheckpoint()
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

    // MARK: - Merge readiness

    /// Prefers the reviewed surface's own pull request, else the first one the sidebar shows.
    private var workspacePullRequest: SidebarPullRequestState? {
        guard let workspace = Workspace.workspaceOwning(surfaceId: sourceSurfaceId) else { return nil }
        let pullRequests = workspace.sidebarPullRequestsInDisplayOrder()
        if let own = workspace.panelPullRequests[sourceSurfaceId],
           let match = pullRequests.first(where: { $0.url == own.url }) {
            return match
        }
        return pullRequests.first
    }

    /// Fetches PR state, checks and unresolved review threads with `gh` off-main. Runs only on
    /// explicit requests (panel shown, refresh button), never on a timer or an agent turn edge.
    func refreshMergeReadiness() {
        let generation = readinessOperation.generation &+ 1
        guard let pullRequest = workspacePullRequest,
              ReviewMergeReadinessProber.coordinates(from: pullRequest.url) != nil else {
            readinessOperation = .settled(generation: generation, value: nil)
            return
        }
        let number = pullRequest.number
        let url = pullRequest.url
        let previous = mergeReadiness?.url == url
            ? mergeReadiness
            : ReviewMergeReadinessState(number: number, url: url, result: nil)
        readinessOperation = .running(generation: generation, previous: previous)
        let directory = directory
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = ReviewMergeReadinessProber.fetch(pullRequestURL: url, directory: directory)
            DispatchQueue.main.async {
                guard let self, self.readinessOperation.isRunning,
                      self.readinessOperation.generation == generation else { return }
                self.readinessOperation = .settled(
                    generation: generation,
                    value: ReviewMergeReadinessState(number: number, url: url, result: result)
                )
            }
        }
    }

    // MARK: - Checkpoints

    /// Checkpoints are keyed by the workspace that owned the surface when its turn started; a
    /// moved review panel's own `workspaceId` can differ, so resolve the surface's current owner.
    private var checkpointWorkspaceId: UUID {
        Workspace.workspaceOwning(surfaceId: sourceSurfaceId)?.id ?? workspaceId
    }

    private func reloadLatestCheckpoint() {
        let generation = checkpointOperation.generation &+ 1
        checkpointOperation = .running(generation: generation, previous: checkpointOperation.value)
        let directory = directory
        let workspaceId = checkpointWorkspaceId
        let surfaceId = sourceSurfaceId
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let newest = ReviewCheckpointStore.list(directory: directory, workspaceId: workspaceId, surfaceId: surfaceId).first
            DispatchQueue.main.async {
                guard let self, self.checkpointOperation.isRunning,
                      self.checkpointOperation.generation == generation else { return }
                self.checkpointOperation = .settled(generation: generation, value: newest)
            }
        }
    }

    /// Restores the files to `latestCheckpoint` off-main (the store saves the current files first),
    /// then refreshes the diff. Failures land in `checkpointRestoreError`.
    func revertToLatestCheckpoint() {
        guard let checkpoint = latestCheckpoint, !isRestoringCheckpoint else { return }
        let generation = restoreOperation.generation &+ 1
        restoreOperation = .running(generation: generation, previous: checkpointRestoreError)
        let directory = directory
        let workspaceId = checkpointWorkspaceId
        let surfaceId = sourceSurfaceId
        ReviewCheckpointStore.queue.async { [weak self] in
            let result = ReviewCheckpointStore.restore(
                ref: checkpoint.ref,
                directory: directory,
                workspaceId: workspaceId,
                surfaceId: surfaceId
            )
            DispatchQueue.main.async {
                guard let self, self.restoreOperation.isRunning,
                      self.restoreOperation.generation == generation else { return }
                let errorMessage: String?
                if case .failure(let error) = result {
                    errorMessage = Self.message(for: error)
                } else {
                    errorMessage = self.checkpointRestoreError
                }
                self.restoreOperation = .settled(generation: generation, value: errorMessage)
                self.refresh()
            }
        }
    }

    private static func message(for error: ReviewCheckpointError) -> String {
        switch error {
        case .notGitRepository:
            return String(localized: "review.checkpoint.error.notGitRepository", defaultValue: "This folder is no longer a git repository.")
        case .checkpointNotFound:
            return String(localized: "review.checkpoint.error.notFound", defaultValue: "The checkpoint no longer exists.")
        case .tooLargeToSave:
            return String(
                localized: "review.checkpoint.error.tooLarge",
                defaultValue: "The current files could not be saved first: more than 500 changed files, or an untracked file over 10 MB. Nothing was changed."
            )
        case .commandFailed(let detail):
            return detail
        }
    }

    // MARK: - Comments

    func restoreComments(_ drafts: [ReviewComment]) {
        // The fresh diff will verify these anchors; do not present restored anchors as current.
        comments = drafts.map { draft in
            var draft = draft
            draft.isStale = true
            return draft
        }
    }

    @discardableResult
    func addComment(filePath: String, startLine: Int, endLine: Int? = nil, text: String) throws -> ReviewComment {
        let comment = ReviewComment(filePath: filePath, startLine: startLine, endLine: endLine, text: text)
        guard comment.isValidForPersistence else { throw ReviewComment.AdmissionError.invalidComment }
        guard comments.count < SessionPersistencePolicy.maxReviewCommentsPerPanel else {
            throw ReviewComment.AdmissionError.tooManyComments
        }
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
    /// `sendToSourceSurface`, clearing only after dispatch, and returns how many were sent. A
    /// failure keeps every comment; zero is a no-op. Dispatch does not acknowledge that the agent
    /// processed the input.
    @discardableResult
    func sendPendingComments(preamble: String? = nil) -> Result<Int, ReviewCommentDeliveryFailure> {
        let pendingCount = comments.count
        let serialized = serializedPendingComments(preamble: preamble)
        commentDeliveryFailure = nil
        guard !serialized.isEmpty else { return .success(0) }
        switch sendToSourceSurface?(serialized) ?? .failed(.sourceUnavailable) {
        case .sent:
            clearSentComments()
            return .success(pendingCount)
        case .failed(let failure):
            commentDeliveryFailure = failure
            return .failure(failure)
        }
    }
}
