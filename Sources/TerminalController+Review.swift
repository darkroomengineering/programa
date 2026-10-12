import Bonsplit
import Foundation

// Agent diff review panel socket API (docs/plans/diff-review-panel.md §2).
//
// Threading: every handler orchestrates from the calling socket thread. Main-actor hops resolve
// or mutate UI-owned TabManager/Workspace/ReviewPanel state and return checked Sendable values;
// no UI-owned object crosses a hop. `review.open`/`review.refresh` run git subprocess I/O between
// those hops, so the main thread is never blocked on probing. Comment operations use one bounded,
// git-free mutation hop after pinning the exact window/workspace/panel IDs.

private struct ReviewOpenContext: Sendable {
    let windowId: UUID?
    let workspaceId: UUID
    let sourceSurfaceId: UUID
    let sourcePaneId: UUID?
    let directory: String
    let mode: ReviewDiffMode
    let baseBranch: String
    let focusRequested: Bool
    let horizontal: Bool
    let insertFirst: Bool
}

private enum ReviewOpenResolution: Sendable {
    case tabManagerUnavailable
    case invalidMode(String)
    case workspaceNotFound
    case noFocusedSurface
    case sourceSurfaceNotFound(UUID)
    case invalidDirection(String)
    case ready(ReviewOpenContext)
}

private struct ReviewOpenResult: Sendable {
    let windowId: UUID?
    let workspaceId: UUID
    let paneId: UUID?
    let surfaceId: UUID
    let baseBranch: String
}

private enum ReviewOpenCreation: Sendable {
    case workspaceNotFound
    case sourceSurfaceNotFound
    case splitFailed
    case created(ReviewOpenResult)
}

private struct ReviewWorkspaceContext: Sendable {
    let windowId: UUID?
    let workspaceId: UUID
}

private struct ReviewPanelContext: Sendable {
    let workspace: ReviewWorkspaceContext
    let panelId: UUID
}

private struct ReviewRefreshContext: Sendable {
    let target: ReviewPanelContext
    let directory: String
    let mode: ReviewDiffMode
    let baseBranch: String
}

private enum ReviewPanelResolution<Context: Sendable>: Sendable {
    case tabManagerUnavailable
    case workspaceNotFound
    case panelNotFound
    case ready(Context)
}

private enum ReviewPanelOperation<Value: Sendable>: Sendable {
    case workspaceNotFound
    case panelNotFound
    case value(Value)
}

private enum ReviewCommentRemoveResult: Sendable {
    case removed
    case commentNotFound
}

private enum ReviewCommentAddInput: Sendable {
    case invalid(String)
    case valid(filePath: String, startLine: Int, endLine: Int, text: String)
}

private enum ReviewCommentRemoveInput: Sendable {
    case invalid(String)
    case valid(id: UUID, rawId: String)
}

private enum ReviewCommentOperation<Value: Sendable>: Sendable {
    case tabManagerUnavailable
    case workspaceNotFound
    case panelNotFound
    case value(Value)
}

private enum ReviewValidatedCommentOperation<Value: Sendable>: Sendable {
    case tabManagerUnavailable
    case invalidParams(String)
    case workspaceNotFound
    case panelNotFound
    case value(Value)

    func v2Result(onValue: (Value) -> TerminalController.V2CallResult) -> TerminalController.V2CallResult {
        switch self {
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        case .invalidParams(let message):
            return .err(code: "invalid_params", message: message, data: nil)
        case .workspaceNotFound:
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        case .panelNotFound:
            return .err(code: "not_found", message: "Review panel not found", data: nil)
        case .value(let value):
            return onValue(value)
        }
    }
}

private struct ReviewCommentWireValue: Sendable {
    let id: UUID
    let filePath: String
    let startLine: Int
    let endLine: Int
    let text: String
    let createdAt: Int
    let isStale: Bool
}

private struct ReviewSendResult: Sendable {
    let sentCount: Int?
    let sourceSurfaceId: UUID
    let windowId: UUID?
}

extension TerminalController {
    @MainActor
    private func v2ResolveReviewPanel(params: [String: Any], workspace ws: Workspace) -> ReviewPanel? {
        if let surfaceId = v2UUID(params, "surface_id") {
            return ws.reviewPanel(for: surfaceId)
        }
        if let focusedPanelId = ws.focusedPanelId, let reviewPanel = ws.reviewPanel(for: focusedPanelId) {
            return reviewPanel
        }
        return ws.panels.values.compactMap { $0 as? ReviewPanel }.first
    }

    @MainActor
    private func v2ReviewWorkspace(context: ReviewWorkspaceContext) -> (TabManager, Workspace)? {
        let tabManager: TabManager?
        if let windowId = context.windowId {
            tabManager = AppDelegate.shared?.tabManagerFor(windowId: windowId)
        } else {
            tabManager = AppDelegate.shared?.tabManagerFor(tabId: context.workspaceId)
                ?? self.tabManager
        }
        guard let tabManager,
              let workspace = tabManager.tabs.first(where: { $0.id == context.workspaceId }) else {
            return nil
        }
        return (tabManager, workspace)
    }

    nonisolated func v2ReviewOpen(params: [String: Any]) -> V2CallResult {
        let modeRaw = v2String(params, "mode") ?? "uncommitted"
        let baseBranch = v2String(params, "base_branch") ?? "origin/main"
        let focusRequested = v2Bool(params, "focus") ?? false

        let resolution: ReviewOpenResolution = v2MainSync {
            guard let tabManager = self.v2ResolveTabManager(params: params) else {
                return .tabManagerUnavailable
            }
            guard let mode = ReviewDiffMode(rawValue: modeRaw) else {
                return .invalidMode(modeRaw)
            }
            guard let workspace = self.v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                return .workspaceNotFound
            }
            let sourceSurfaceId = self.v2UUID(params, "surface_id") ?? workspace.focusedPanelId
            guard let sourceSurfaceId else {
                return .noFocusedSurface
            }
            guard workspace.panels[sourceSurfaceId] != nil else {
                return .sourceSurfaceNotFound(sourceSurfaceId)
            }

            let directionRaw = self.v2String(params, "direction") ?? "right"
            guard let direction = self.parseSplitDirection(directionRaw) else {
                return .invalidDirection(directionRaw)
            }

            return .ready(ReviewOpenContext(
                windowId: AppDelegate.shared?.windowId(for: tabManager),
                workspaceId: workspace.id,
                sourceSurfaceId: sourceSurfaceId,
                sourcePaneId: workspace.paneId(forPanelId: sourceSurfaceId)?.id,
                directory: workspace.panelDirectories[sourceSurfaceId] ?? workspace.currentDirectory,
                mode: mode,
                baseBranch: baseBranch,
                focusRequested: focusRequested,
                horizontal: direction.isHorizontal,
                insertFirst: direction == .left || direction == .up
            ))
        }

        let context: ReviewOpenContext
        switch resolution {
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        case .invalidMode(let raw):
            return .err(code: "invalid_params", message: "Invalid mode '\(raw)' (uncommitted|branch)", data: nil)
        case .workspaceNotFound:
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        case .noFocusedSurface:
            return .err(code: "not_found", message: "No focused surface to review", data: nil)
        case .sourceSurfaceNotFound(let surfaceId):
            return .err(
                code: "not_found",
                message: "Source surface not found",
                data: ["surface_id": surfaceId.uuidString]
            )
        case .invalidDirection(let raw):
            return .err(code: "invalid_params", message: "Invalid direction '\(raw)' (left|right|up|down)", data: nil)
        case .ready(let resolved):
            context = resolved
        }

        // Off-main: the snapshot's repository lookup is also the pre-split git-repository gate,
        // avoiding the previous duplicate `git rev-parse --show-toplevel` subprocess.
        let snapshot = ReviewDiffProber.diffSnapshot(
            directory: context.directory,
            mode: context.mode,
            baseBranch: context.baseBranch
        )
        if snapshot.error == .notGitRepository {
            return .err(
                code: "unavailable",
                message: "Not a git repository: \(context.directory)",
                data: ["directory": context.directory]
            )
        }

        let creation: ReviewOpenCreation = v2MainSync {
            let target = ReviewWorkspaceContext(
                windowId: context.windowId,
                workspaceId: context.workspaceId
            )
            guard let (tabManager, workspace) = self.v2ReviewWorkspace(context: target) else {
                return .workspaceNotFound
            }
            guard workspace.panels[context.sourceSurfaceId] != nil else {
                return .sourceSurfaceNotFound
            }

            // Per the socket focus policy, the default focus:false path does not activate the
            // app or change workspace selection. The explicit focus path keeps its original
            // focus-window, select-workspace, then create-and-focus ordering.
            if context.focusRequested {
                self.v2MaybeFocusWindow(for: tabManager)
                self.v2MaybeSelectWorkspace(tabManager, workspace: workspace)
            }

            let orientation: SplitOrientation = context.horizontal ? .horizontal : .vertical
            guard let created = workspace.newReviewSplit(
                from: context.sourceSurfaceId,
                orientation: orientation,
                insertFirst: context.insertFirst,
                mode: context.mode,
                baseBranch: context.baseBranch,
                focus: self.v2FocusAllowed(requested: context.focusRequested)
            ) else {
                return .splitFailed
            }
            created.apply(snapshot: snapshot)

            return .created(ReviewOpenResult(
                windowId: AppDelegate.shared?.windowId(for: tabManager),
                workspaceId: workspace.id,
                paneId: workspace.paneId(forPanelId: created.id)?.id,
                surfaceId: created.id,
                baseBranch: created.baseBranch
            ))
        }

        switch creation {
        case .workspaceNotFound:
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        case .sourceSurfaceNotFound:
            return .err(
                code: "not_found",
                message: "Source surface not found",
                data: ["surface_id": context.sourceSurfaceId.uuidString]
            )
        case .splitFailed:
            return .err(code: "internal_error", message: "Failed to create review panel", data: nil)
        case .created(let created):
            return .ok([
                "window_id": v2OrNull(created.windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: created.windowId),
                "workspace_id": created.workspaceId.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: created.workspaceId),
                "pane_id": v2OrNull(created.paneId?.uuidString),
                "pane_ref": v2Ref(kind: .pane, uuid: created.paneId),
                "surface_id": created.surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: created.surfaceId),
                "source_surface_id": context.sourceSurfaceId.uuidString,
                "source_surface_ref": v2Ref(kind: .surface, uuid: context.sourceSurfaceId),
                "source_pane_id": v2OrNull(context.sourcePaneId?.uuidString),
                "source_pane_ref": v2Ref(kind: .pane, uuid: context.sourcePaneId),
                "mode": context.mode.rawValue,
                "base_branch": created.baseBranch,
                "diffable_file_count": snapshot.diffableFileCount,
                "file_count": snapshot.files.count
            ])
        }
    }

    nonisolated func v2ReviewRefresh(params: [String: Any]) -> V2CallResult {
        let resolution: ReviewPanelResolution<ReviewRefreshContext> = v2MainSync {
            guard let tabManager = self.v2ResolveTabManager(params: params) else {
                return .tabManagerUnavailable
            }
            guard let workspace = self.v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                return .workspaceNotFound
            }
            guard let panel = self.v2ResolveReviewPanel(params: params, workspace: workspace) else {
                return .panelNotFound
            }
            return .ready(ReviewRefreshContext(
                target: ReviewPanelContext(
                    workspace: ReviewWorkspaceContext(
                        windowId: AppDelegate.shared?.windowId(for: tabManager),
                        workspaceId: workspace.id
                    ),
                    panelId: panel.id
                ),
                directory: panel.directory,
                mode: panel.mode,
                baseBranch: panel.baseBranch
            ))
        }

        let context: ReviewRefreshContext
        switch resolution {
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        case .workspaceNotFound:
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        case .panelNotFound:
            return .err(code: "not_found", message: "Review panel not found", data: nil)
        case .ready(let resolved):
            context = resolved
        }

        let snapshot = ReviewDiffProber.diffSnapshot(
            directory: context.directory,
            mode: context.mode,
            baseBranch: context.baseBranch
        )

        let applied: ReviewPanelOperation<Void> = v2MainSync {
            guard let (_, workspace) = self.v2ReviewWorkspace(context: context.target.workspace) else {
                return .workspaceNotFound
            }
            guard let panel = workspace.reviewPanel(for: context.target.panelId) else {
                return .panelNotFound
            }
            panel.apply(snapshot: snapshot)
            return .value(())
        }

        switch applied {
        case .workspaceNotFound:
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        case .panelNotFound:
            return .err(code: "not_found", message: "Review panel not found", data: nil)
        case .value:
            return .ok([
                "file_count": snapshot.files.count,
                "diffable_file_count": snapshot.diffableFileCount,
                "generated_at": Int(snapshot.generatedAt.timeIntervalSince1970)
            ])
        }
    }

    nonisolated func v2ReviewCommentAdd(params: [String: Any]) -> V2CallResult {
        let input: ReviewCommentAddInput
        if let filePath = v2String(params, "file_path"), !filePath.isEmpty {
            if let startLine = v2Int(params, "start_line"), startLine > 0 {
                let endLine = v2Int(params, "end_line") ?? startLine
                if endLine >= startLine {
                    if let text = v2String(params, "text"),
                       !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        input = .valid(
                            filePath: filePath,
                            startLine: startLine,
                            endLine: endLine,
                            text: text
                        )
                    } else {
                        input = .invalid("Missing text")
                    }
                } else {
                    input = .invalid("end_line must be >= start_line")
                }
            } else {
                input = .invalid("Missing or invalid start_line")
            }
        } else {
            input = .invalid("Missing file_path")
        }

        let outcome: ReviewValidatedCommentOperation<UUID> = v2MainSync {
            guard let tabManager = self.v2ResolveTabManager(params: params) else {
                return .tabManagerUnavailable
            }
            guard case .valid(let filePath, let startLine, let endLine, let text) = input else {
                guard case .invalid(let message) = input else { preconditionFailure() }
                return .invalidParams(message)
            }
            guard let workspace = self.v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                return .workspaceNotFound
            }
            guard let panel = self.v2ResolveReviewPanel(params: params, workspace: workspace) else {
                return .panelNotFound
            }
            do {
                return .value(try panel.addComment(
                    filePath: filePath,
                    startLine: startLine,
                    endLine: endLine,
                    text: text
                ).id)
            } catch {
                return .invalidParams(error.localizedDescription)
            }
        }

        return outcome.v2Result { commentId in
            .ok(["comment_id": commentId.uuidString])
        }
    }

    nonisolated func v2ReviewCommentRemove(params: [String: Any]) -> V2CallResult {
        let input: ReviewCommentRemoveInput
        if let rawId = v2String(params, "comment_id"), let id = UUID(uuidString: rawId) {
            input = .valid(id: id, rawId: rawId)
        } else {
            input = .invalid("Missing or invalid comment_id")
        }

        let outcome: ReviewValidatedCommentOperation<(ReviewCommentRemoveResult, String)> = v2MainSync {
            guard let tabManager = self.v2ResolveTabManager(params: params) else {
                return .tabManagerUnavailable
            }
            guard case .valid(let commentId, let rawId) = input else {
                guard case .invalid(let message) = input else { preconditionFailure() }
                return .invalidParams(message)
            }
            guard let workspace = self.v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                return .workspaceNotFound
            }
            guard let panel = self.v2ResolveReviewPanel(params: params, workspace: workspace) else {
                return .panelNotFound
            }
            let result: ReviewCommentRemoveResult = panel.removeComment(id: commentId) ? .removed : .commentNotFound
            return .value((result, rawId))
        }

        return outcome.v2Result { value in
            switch value {
            case (.commentNotFound, let rawId):
                return .err(code: "not_found", message: "Comment not found", data: ["comment_id": rawId])
            case (.removed, _):
                return .ok(["ok": true])
            }
        }
    }

    nonisolated func v2ReviewCommentList(params: [String: Any]) -> V2CallResult {
        let outcome: ReviewCommentOperation<[ReviewCommentWireValue]> = v2MainSync {
            guard let tabManager = self.v2ResolveTabManager(params: params) else {
                return .tabManagerUnavailable
            }
            guard let workspace = self.v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                return .workspaceNotFound
            }
            guard let panel = self.v2ResolveReviewPanel(params: params, workspace: workspace) else {
                return .panelNotFound
            }
            return .value(panel.comments.map { comment in
                ReviewCommentWireValue(
                    id: comment.id,
                    filePath: comment.filePath,
                    startLine: comment.startLine,
                    endLine: comment.endLine,
                    text: comment.text,
                    createdAt: Int(comment.createdAt.timeIntervalSince1970),
                    isStale: comment.isStale
                )
            })
        }

        switch outcome {
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        case .workspaceNotFound:
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        case .panelNotFound:
            return .err(code: "not_found", message: "Review panel not found", data: nil)
        case .value(let comments):
            return .ok(["comments": comments.map { comment in
                [
                    "id": comment.id.uuidString,
                    "file_path": comment.filePath,
                    "start_line": comment.startLine,
                    "end_line": comment.endLine,
                    "text": comment.text,
                    "created_at": comment.createdAt,
                    "is_stale": comment.isStale
                ] as [String: Any]
            }])
        }
    }

    nonisolated func v2ReviewSendComments(params: [String: Any]) -> V2CallResult {
        let preamble = v2String(params, "preamble")

        let outcome: ReviewCommentOperation<ReviewSendResult> = v2MainSync {
            guard let tabManager = self.v2ResolveTabManager(params: params) else {
                return .tabManagerUnavailable
            }
            guard let workspace = self.v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                return .workspaceNotFound
            }
            guard let panel = self.v2ResolveReviewPanel(params: params, workspace: workspace) else {
                return .panelNotFound
            }
            let sourceSurfaceId = panel.sourceSurfaceId
            // Sending zero comments is a no-op, not a failure.
            let sentCount = panel.sendPendingComments(preamble: preamble)
            return .value(ReviewSendResult(
                sentCount: sentCount,
                sourceSurfaceId: sourceSurfaceId,
                windowId: AppDelegate.shared?.windowId(for: tabManager)
            ))
        }

        switch outcome {
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        case .workspaceNotFound:
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        case .panelNotFound:
            return .err(code: "not_found", message: "Review panel not found", data: nil)
        case .value(let sent):
            guard let sentCount = sent.sentCount else {
                return .err(code: "unavailable", message: "Review source terminal is unavailable. Pending comments were retained.", data: nil)
            }
            return .ok([
                "sent_count": sentCount,
                "target_surface_id": sent.sourceSurfaceId.uuidString,
                "target_surface_ref": v2Ref(kind: .surface, uuid: sent.sourceSurfaceId),
                "window_id": v2OrNull(sent.windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: sent.windowId)
            ])
        }
    }
}
