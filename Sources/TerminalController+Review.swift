import Bonsplit
import Foundation

// Agent diff review panel socket API (docs/plans/diff-review-panel.md §2). Mirrors
// `v2MarkdownOpen`'s (TerminalController+BrowserAutomation.swift) and `v2SurfaceSendText`'s
// (TerminalController+Surface.swift) exact patterns.
//
// Threading: `review.open`/`review.refresh` compute the actual `git diff` snapshot
// (`ReviewDiffProber.diffSnapshot`) OUTSIDE any `v2MainSync` hop, on the calling (already
// off-main) socket-handling thread -- so the main thread is never blocked on git subprocess
// I/O, while the socket response can still report an accurate `diffable_file_count` because the
// snapshot is computed synchronously before the response is built. `review.comment.*` and
// `review.send_comments` are pure in-memory mutations on the review panel's own `@MainActor`
// state, so they still require a (fast, git-free) `v2MainSync` hop -- `ReviewPanel` is
// `@MainActor`-isolated like every other `Panel`.
extension TerminalController {
    private func v2ResolveReviewPanel(params: [String: Any], workspace ws: Workspace) -> ReviewPanel? {
        if let surfaceId = v2UUID(params, "surface_id") {
            return ws.reviewPanel(for: surfaceId)
        }
        if let focusedPanelId = ws.focusedPanelId, let reviewPanel = ws.reviewPanel(for: focusedPanelId) {
            return reviewPanel
        }
        return ws.panels.values.compactMap { $0 as? ReviewPanel }.first
    }

    func v2ReviewOpen(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        let modeRaw = v2String(params, "mode") ?? "uncommitted"
        guard let mode = ReviewDiffMode(rawValue: modeRaw) else {
            return .err(code: "invalid_params", message: "Invalid mode '\(modeRaw)' (uncommitted|branch)", data: nil)
        }
        let baseBranch = v2String(params, "base_branch") ?? "origin/main"
        let focusRequested = v2Bool(params, "focus") ?? false

        // Hop 1 (main actor): resolve workspace/source surface/directory/pane ids only -- no
        // panel creation yet, so we can fail fast with `unavailable` before creating a split.
        var resolveError: V2CallResult?
        var sourceSurfaceId: UUID?
        var sourcePaneUUID: UUID?
        var directory: String?
        var orientation: SplitOrientation?
        var insertFirst = false

        v2MainSync {
            guard let ws = self.v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                resolveError = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            let resolvedSourceSurfaceId = self.v2UUID(params, "surface_id") ?? ws.focusedPanelId
            guard let resolvedSourceSurfaceId else {
                resolveError = .err(code: "not_found", message: "No focused surface to review", data: nil)
                return
            }
            guard ws.panels[resolvedSourceSurfaceId] != nil else {
                resolveError = .err(
                    code: "not_found",
                    message: "Source surface not found",
                    data: ["surface_id": resolvedSourceSurfaceId.uuidString]
                )
                return
            }

            let directionStr = self.v2String(params, "direction") ?? "right"
            guard let direction = self.parseSplitDirection(directionStr) else {
                resolveError = .err(code: "invalid_params", message: "Invalid direction '\(directionStr)' (left|right|up|down)", data: nil)
                return
            }

            sourceSurfaceId = resolvedSourceSurfaceId
            sourcePaneUUID = ws.paneId(forPanelId: resolvedSourceSurfaceId)?.id
            directory = ws.panelDirectories[resolvedSourceSurfaceId] ?? ws.currentDirectory
            orientation = direction.isHorizontal ? .horizontal : .vertical
            insertFirst = (direction == .left || direction == .up)
        }
        if let resolveError { return resolveError }
        guard let sourceSurfaceId, let directory, let orientation else {
            return .err(code: "internal_error", message: "Failed to resolve review target", data: nil)
        }

        // Fail fast if the resolved directory isn't inside a git worktree at all, before
        // creating any split.
        guard ReviewDiffProber.repositoryRoot(directory: directory) != nil else {
            return .err(code: "unavailable", message: "Not a git repository: \(directory)", data: ["directory": directory])
        }

        // Off-main: compute the first diff snapshot synchronously (see file header).
        let snapshot = ReviewDiffProber.diffSnapshot(directory: directory, mode: mode, baseBranch: baseBranch)

        // Hop 2 (main actor): create the split + panel, apply the snapshot, build the response.
        var result: V2CallResult = .err(code: "internal_error", message: "Failed to create review panel", data: nil)
        v2MainSync {
            guard let ws = self.v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }

            // Per the "Socket focus policy" (root CLAUDE.md) and docs/plans/diff-review-panel.md
            // §2: `focus:false` (the default) must not activate the app or move focus at all.
            if focusRequested {
                self.v2MaybeFocusWindow(for: tabManager)
                self.v2MaybeSelectWorkspace(tabManager, workspace: ws)
            }

            let created = ws.newReviewSplit(
                from: sourceSurfaceId,
                orientation: orientation,
                insertFirst: insertFirst,
                mode: mode,
                baseBranch: baseBranch,
                focus: self.v2FocusAllowed(requested: focusRequested)
            )
            guard let created else {
                result = .err(code: "internal_error", message: "Failed to create review panel", data: nil)
                return
            }
            created.apply(snapshot: snapshot)

            let targetPaneUUID = ws.paneId(forPanelId: created.id)?.id
            let windowId = self.v2ResolveWindowId(tabManager: tabManager)
            result = .ok([
                "window_id": self.v2OrNull(windowId?.uuidString),
                "window_ref": self.v2Ref(kind: .window, uuid: windowId),
                "workspace_id": ws.id.uuidString,
                "workspace_ref": self.v2Ref(kind: .workspace, uuid: ws.id),
                "pane_id": self.v2OrNull(targetPaneUUID?.uuidString),
                "pane_ref": self.v2Ref(kind: .pane, uuid: targetPaneUUID),
                "surface_id": created.id.uuidString,
                "surface_ref": self.v2Ref(kind: .surface, uuid: created.id),
                "source_surface_id": sourceSurfaceId.uuidString,
                "source_surface_ref": self.v2Ref(kind: .surface, uuid: sourceSurfaceId),
                "source_pane_id": self.v2OrNull(sourcePaneUUID?.uuidString),
                "source_pane_ref": self.v2Ref(kind: .pane, uuid: sourcePaneUUID),
                "mode": mode.rawValue,
                "base_branch": created.baseBranch,
                "diffable_file_count": snapshot.diffableFileCount,
                "file_count": snapshot.files.count
            ])
        }
        return result
    }

    func v2ReviewRefresh(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        var resolveError: V2CallResult?
        var reviewPanel: ReviewPanel?
        v2MainSync {
            guard let ws = self.v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                resolveError = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            guard let panel = self.v2ResolveReviewPanel(params: params, workspace: ws) else {
                resolveError = .err(code: "not_found", message: "Review panel not found", data: nil)
                return
            }
            reviewPanel = panel
        }
        if let resolveError { return resolveError }
        guard let reviewPanel else {
            return .err(code: "internal_error", message: "Failed to resolve review panel", data: nil)
        }

        // Off-main, mirroring `review.open` (see file header).
        let snapshot = ReviewDiffProber.diffSnapshot(directory: reviewPanel.directory, mode: reviewPanel.mode, baseBranch: reviewPanel.baseBranch)

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to refresh review panel", data: nil)
        v2MainSync {
            reviewPanel.apply(snapshot: snapshot)
            result = .ok([
                "file_count": snapshot.files.count,
                "diffable_file_count": snapshot.diffableFileCount,
                "generated_at": Int(snapshot.generatedAt.timeIntervalSince1970)
            ])
        }
        return result
    }

    func v2ReviewCommentAdd(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let filePath = v2String(params, "file_path"), !filePath.isEmpty else {
            return .err(code: "invalid_params", message: "Missing file_path", data: nil)
        }
        guard let startLine = v2Int(params, "start_line"), startLine > 0 else {
            return .err(code: "invalid_params", message: "Missing or invalid start_line", data: nil)
        }
        let endLine = v2Int(params, "end_line") ?? startLine
        guard endLine >= startLine else {
            return .err(code: "invalid_params", message: "end_line must be >= start_line", data: nil)
        }
        guard let text = v2String(params, "text"), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .err(code: "invalid_params", message: "Missing text", data: nil)
        }

        var result: V2CallResult = .err(code: "not_found", message: "Review panel not found", data: nil)
        v2MainSync {
            guard let ws = self.v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            guard let reviewPanel = self.v2ResolveReviewPanel(params: params, workspace: ws) else {
                result = .err(code: "not_found", message: "Review panel not found", data: nil)
                return
            }
            let comment = reviewPanel.addComment(filePath: filePath, startLine: startLine, endLine: endLine, text: text)
            result = .ok(["comment_id": comment.id.uuidString])
        }
        return result
    }

    func v2ReviewCommentRemove(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let commentIdString = v2String(params, "comment_id"), let commentId = UUID(uuidString: commentIdString) else {
            return .err(code: "invalid_params", message: "Missing or invalid comment_id", data: nil)
        }

        var result: V2CallResult = .err(code: "not_found", message: "Review panel not found", data: nil)
        v2MainSync {
            guard let ws = self.v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            guard let reviewPanel = self.v2ResolveReviewPanel(params: params, workspace: ws) else {
                result = .err(code: "not_found", message: "Review panel not found", data: nil)
                return
            }
            guard reviewPanel.removeComment(id: commentId) else {
                result = .err(code: "not_found", message: "Comment not found", data: ["comment_id": commentIdString])
                return
            }
            result = .ok(["ok": true])
        }
        return result
    }

    func v2ReviewCommentList(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        var result: V2CallResult = .err(code: "not_found", message: "Review panel not found", data: nil)
        v2MainSync {
            guard let ws = self.v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            guard let reviewPanel = self.v2ResolveReviewPanel(params: params, workspace: ws) else {
                result = .err(code: "not_found", message: "Review panel not found", data: nil)
                return
            }
            let comments: [[String: Any]] = reviewPanel.comments.map { comment in
                [
                    "id": comment.id.uuidString,
                    "file_path": comment.filePath,
                    "start_line": comment.startLine,
                    "end_line": comment.endLine,
                    "text": comment.text,
                    "created_at": Int(comment.createdAt.timeIntervalSince1970),
                    "is_stale": comment.isStale
                ]
            }
            result = .ok(["comments": comments])
        }
        return result
    }

    func v2ReviewSendComments(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        let preamble = v2String(params, "preamble")

        var result: V2CallResult = .err(code: "not_found", message: "Review panel not found", data: nil)
        v2MainSync {
            guard let ws = self.v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            guard let reviewPanel = self.v2ResolveReviewPanel(params: params, workspace: ws) else {
                result = .err(code: "not_found", message: "Review panel not found", data: nil)
                return
            }
            let sourceSurfaceId = reviewPanel.sourceSurfaceId
            // Sending zero comments is a no-op, not a failure -- see docs/plans/diff-review-panel.md §2.
            let sentCount = reviewPanel.sendPendingComments(preamble: preamble)
            let windowId = self.v2ResolveWindowId(tabManager: tabManager)
            result = .ok([
                "sent_count": sentCount,
                "target_surface_id": sourceSurfaceId.uuidString,
                "target_surface_ref": self.v2Ref(kind: .surface, uuid: sourceSurfaceId),
                "window_id": self.v2OrNull(windowId?.uuidString),
                "window_ref": self.v2Ref(kind: .window, uuid: windowId)
            ])
        }
        return result
    }
}
