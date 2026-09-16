// Native git worktree workflow (docs/plans/worktree-and-layouts.md): v2 socket handlers for
// `worktree.create/open/remove/list`. Mirrors TerminalController+Workspace.swift's V2CallResult
// / v2MainSync shape. All git/filesystem I/O runs through GitWorktreeManager, which is
// synchronous by construction (matches GitMetadataProber) -- v2MainSync here is used only
// around the final tabManager mutation, per the socket threading policy in CLAUDE.md.
import Foundation

extension TerminalController {
    // MARK: - V2 Worktree Methods

    nonisolated func v2WorktreeCreate(params: [String: Any]) -> V2CallResult {
        guard let repoRoot = v2ResolveWorktreeRepoRoot(params: params) else {
            return .err(code: "not_a_git_repo", message: "Could not resolve a git repository from 'repo'", data: nil)
        }
        guard let branch = v2String(params, "branch") else {
            return v2InvalidParam("branch")
        }
        let base = v2String(params, "base")
        let layoutName = v2String(params, "layout")
        let requiredParentWorkspaceId = v2UUID(params, "required_parent_workspace_id")
        let requiredParentDirectory = v2String(params, "required_parent_directory")
        let focusRequested = v2Bool(params, "focus") ?? false
        guard let windowId = v2ResolveWorktreeWindowId(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        if let layoutName, v2MainSync({ ProgramaLayoutStore.shared.load(name: layoutName) }) == nil {
            return .err(code: "layout_not_found", message: "No saved layout named '\(layoutName)'", data: nil)
        }

        if let existing = GitWorktreeManager.worktreeCheckedOut(branch: branch, repoRoot: repoRoot) {
            return .err(code: "branch_checked_out", message: "Branch '\(branch)' is already checked out at \(existing.path)", data: [
                "existing_path": existing.path
            ])
        }

        let worktreeBaseDirectory = v2MainSync { ProgramaWorktreeSettings.resolvedDirectory() }
        let path = v2ResolveWorktreePath(
            params: params,
            repoRoot: repoRoot,
            branch: branch,
            baseDirectory: worktreeBaseDirectory
        )

        switch GitWorktreeManager.add(repoRoot: repoRoot, branch: branch, base: base, path: path) {
        case .success(let entry):
            let completion = v2MainSync {
                v2CompleteWorktreeCreation(
                    windowId: windowId,
                    entry: entry,
                    repoRoot: repoRoot,
                    layoutName: layoutName,
                    focusRequested: focusRequested,
                    requiredParentWorkspaceId: requiredParentWorkspaceId,
                    requiredParentDirectory: requiredParentDirectory
                )
            }
            if case .err(let originalCode, let originalMessage, _) = completion {
                switch GitWorktreeManager.remove(repoRoot: repoRoot, path: entry.path, force: false) {
                case .success:
                    break
                case .worktreeNotFound, .worktreeDirty, .gitCommandFailed:
                    return .err(
                        code: "cleanup_failed",
                        message: "\(originalMessage). The unused worktree could not be removed.",
                        data: [
                            "original_code": originalCode,
                            "worktree_path": entry.path,
                        ]
                    )
                }
            }
            return completion
        case .worktreePathExists:
            return .err(code: "worktree_path_exists", message: "Path already exists: \(path)", data: nil)
        case .gitCommandFailed(let message):
            return .err(code: "git_command_failed", message: message, data: nil)
        }
    }

    @MainActor
    private func v2CompleteWorktreeCreation(
        windowId: UUID,
        entry: GitWorktreeManager.WorktreeEntry,
        repoRoot: String,
        layoutName: String?,
        focusRequested: Bool,
        requiredParentWorkspaceId: UUID?,
        requiredParentDirectory: String?
    ) -> V2CallResult {
        guard let tabManager = AppDelegate.shared?.tabManagerFor(windowId: windowId) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        if let requiredParentWorkspaceId {
            guard let parent = tabManager.tabs.first(where: { $0.id == requiredParentWorkspaceId }),
                  requiredParentDirectory == nil || parent.currentDirectory == requiredParentDirectory else {
                return .err(
                    code: "parent_changed",
                    message: "The parent workspace changed while the worktree was being prepared",
                    data: ["parent_workspace_id": requiredParentWorkspaceId.uuidString]
                )
            }
        }
        let shouldFocus = v2FocusAllowed(requested: focusRequested)
        let ws = tabManager.addWorktreeWorkspace(
            path: entry.path,
            branch: entry.branch,
            repoRoot: repoRoot,
            layoutName: layoutName,
            parentWorkspaceId: requiredParentWorkspaceId,
            select: shouldFocus
        )
        return .ok([
            "worktree": ["path": entry.path, "branch": v2OrNull(entry.branch), "repo": repoRoot],
            "workspace_id": ws.id.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
            "window_id": windowId.uuidString,
            "window_ref": v2Ref(kind: .window, uuid: windowId)
        ])
    }

    nonisolated func v2WorktreeOpen(params: [String: Any]) -> V2CallResult {
        guard let windowId = v2ResolveWorktreeWindowId(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let repoRoot = v2ResolveWorktreeRepoRoot(params: params) else {
            return .err(code: "not_a_git_repo", message: "Could not resolve a git repository from 'repo'", data: nil)
        }
        let pathParam = v2String(params, "path")
        let branchParam = v2String(params, "branch")
        guard pathParam != nil || branchParam != nil else {
            return v2InvalidParam("path or branch")
        }

        let entry: GitWorktreeManager.WorktreeEntry?
        if let pathParam {
            entry = GitWorktreeManager.worktreeEntry(atPath: v2ExpandedPath(pathParam), repoRoot: repoRoot)
        } else {
            entry = GitWorktreeManager.worktreeEntry(forBranch: branchParam!, repoRoot: repoRoot)
        }
        guard let entry else {
            return .err(code: "worktree_not_found", message: "No matching worktree found", data: nil)
        }

        let focusRequested = v2Bool(params, "focus") ?? false
        let requiredParentWorkspaceId = v2UUID(params, "required_parent_workspace_id")
        let requiredParentDirectory = v2String(params, "required_parent_directory")
        return v2MainSync {
            guard let tabManager = AppDelegate.shared?.tabManagerFor(windowId: windowId) else {
                return .err(code: "unavailable", message: "TabManager not available", data: nil)
            }

            if let existingWorkspace = self.v2WorktreeOpenWorkspace(tabManager: tabManager, path: entry.path) {
                // "already open" is idempotent -- only touch focus/selection when the caller
                // explicitly opted in via `focus: true` (socket focus policy default is false).
                if self.v2FocusAllowed(requested: focusRequested) {
                    _ = AppDelegate.shared?.focusMainWindow(windowId: windowId)
                    self.setActiveTabManager(tabManager)
                    tabManager.selectWorkspace(existingWorkspace)
                }
                return .ok([
                    "worktree": ["path": entry.path, "branch": self.v2OrNull(entry.branch), "repo": repoRoot],
                    "workspace_id": existingWorkspace.id.uuidString,
                    "workspace_ref": self.v2Ref(kind: .workspace, uuid: existingWorkspace.id),
                    "window_id": self.v2OrNull(windowId.uuidString),
                    "window_ref": self.v2Ref(kind: .window, uuid: windowId)
                ])
            }

            return self.v2CompleteWorktreeCreation(
                windowId: windowId,
                entry: entry,
                repoRoot: repoRoot,
                layoutName: nil,
                focusRequested: focusRequested,
                requiredParentWorkspaceId: requiredParentWorkspaceId,
                requiredParentDirectory: requiredParentDirectory
            )
        }
    }

    nonisolated func v2WorktreeRemove(params: [String: Any]) -> V2CallResult {
        guard let windowId = v2ResolveWorktreeWindowId(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let repoRoot = v2ResolveWorktreeRepoRoot(params: params) else {
            return .err(code: "not_a_git_repo", message: "Could not resolve a git repository from 'repo'", data: nil)
        }
        let pathParam = v2String(params, "path")
        let branchParam = v2String(params, "branch")
        guard pathParam != nil || branchParam != nil else {
            return v2InvalidParam("path or branch")
        }

        let entry: GitWorktreeManager.WorktreeEntry?
        if let pathParam {
            entry = GitWorktreeManager.worktreeEntry(atPath: v2ExpandedPath(pathParam), repoRoot: repoRoot)
        } else {
            entry = GitWorktreeManager.worktreeEntry(forBranch: branchParam!, repoRoot: repoRoot)
        }
        guard let entry else {
            return .err(code: "worktree_not_found", message: "No matching worktree found", data: nil)
        }

        switch GitWorktreeManager.remove(repoRoot: repoRoot, path: entry.path, force: v2Bool(params, "force") ?? false) {
        case .success:
            let closedWorkspaceId = v2MainSync { () -> UUID? in
                guard let tabManager = AppDelegate.shared?.tabManagerFor(windowId: windowId) else {
                    return nil
                }
                if let ws = self.v2WorktreeOpenWorkspace(tabManager: tabManager, path: entry.path) {
                    tabManager.closeWorkspace(ws)
                    return ws.id
                }
                return nil
            }
            var result: [String: Any] = ["removed": true]
            if let closedWorkspaceId {
                result["closed_workspace_id"] = closedWorkspaceId.uuidString
            }
            return .ok(result)
        case .worktreeNotFound:
            return .err(code: "worktree_not_found", message: "No matching worktree found", data: nil)
        case .worktreeDirty(let message):
            return .err(code: "worktree_dirty", message: message.isEmpty ? "Worktree has uncommitted changes" : message, data: nil)
        case .gitCommandFailed(let message):
            return .err(code: "git_command_failed", message: message, data: nil)
        }
    }

    nonisolated func v2WorktreeList(params: [String: Any]) -> V2CallResult {
        let windowId = v2ResolveWorktreeWindowId(params: params)
        guard let repoRoot = v2ResolveWorktreeRepoRoot(params: params) else {
            return .err(code: "not_a_git_repo", message: "Could not resolve a git repository from 'repo'", data: nil)
        }
        guard let entries = GitWorktreeManager.listWorktrees(repoRoot: repoRoot) else {
            return .err(code: "not_a_git_repo", message: "'\(repoRoot)' is not a git repository", data: nil)
        }

        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser.path
        let openWorkspaceIdsByPath = v2MainSync { () -> [String: UUID] in
            guard let windowId,
                  let tabManager = AppDelegate.shared?.tabManagerFor(windowId: windowId) else {
                return [:]
            }
            var workspaceIdsByPath: [String: UUID] = [:]
            for workspace in tabManager.tabs {
                guard let key = SidebarBranchOrdering.canonicalDirectoryKey(
                    workspace.currentDirectory,
                    homeDirectoryForTildeExpansion: homeDirectory
                ), workspaceIdsByPath[key] == nil else { continue }
                workspaceIdsByPath[key] = workspace.id
            }
            return workspaceIdsByPath
        }

        var payloads: [[String: Any]] = []
        for entry in entries where !entry.isBare {
            var payload: [String: Any] = [
                "path": entry.path,
                "branch": v2OrNull(entry.branch),
                "head": v2OrNull(entry.headSHA),
                "is_open": false
            ]
            if let key = SidebarBranchOrdering.canonicalDirectoryKey(
                entry.path,
                homeDirectoryForTildeExpansion: homeDirectory
            ), let workspaceId = openWorkspaceIdsByPath[key] {
                payload["is_open"] = true
                payload["workspace_id"] = workspaceId.uuidString
                payload["workspace_ref"] = v2Ref(kind: .workspace, uuid: workspaceId)
            }
            payloads.append(payload)
        }

        return .ok(["repo": repoRoot, "worktrees": payloads])
    }

    // MARK: - Shared helpers

    private nonisolated func v2ResolveWorktreeWindowId(params: [String: Any]) -> UUID? {
        v2MainSync {
            guard let tabManager = self.v2ResolveTabManager(params: params) else { return nil }
            return AppDelegate.shared?.windowId(for: tabManager)
        }
    }

    private nonisolated func v2ExpandedPath(_ raw: String) -> String {
        (raw as NSString).expandingTildeInPath
    }

    /// Resolves the repo root from the `repo` param via `git rev-parse --show-toplevel`, so
    /// callers can pass any directory inside the repo, not only its exact toplevel. Missing or
    /// unresolvable `repo` fails clearly rather than falling back to the app process's own
    /// (meaningless, from the caller's perspective) working directory -- see plan risk #2.
    private nonisolated func v2ResolveWorktreeRepoRoot(params: [String: Any]) -> String? {
        guard let raw = v2String(params, "repo") else { return nil }
        return GitWorktreeManager.resolveRepoRoot(from: v2ExpandedPath(raw))
    }

    private nonisolated func v2ResolveWorktreePath(
        params: [String: Any],
        repoRoot: String,
        branch: String,
        baseDirectory: String
    ) -> String {
        if let raw = v2String(params, "path") {
            return v2ExpandedPath(raw)
        }
        let repoName = GitWorktreeManager.repoName(forRepoRoot: repoRoot)
        let branchSlug = GitWorktreeManager.branchSlug(branch)
        return (baseDirectory as NSString)
            .appendingPathComponent(repoName)
            .appending("/" + branchSlug)
    }

    /// Finds the workspace whose `currentDirectory` canonically matches `path`, if one is
    /// currently open. Must run on the main actor (reads `tabManager.tabs`/`Workspace.currentDirectory`).
    @MainActor
    private func v2WorktreeOpenWorkspace(tabManager: TabManager, path: String) -> Workspace? {
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser.path
        let targetKey = SidebarBranchOrdering.canonicalDirectoryKey(path, homeDirectoryForTildeExpansion: homeDirectory)
        guard let targetKey else { return nil }
        return tabManager.tabs.first {
            SidebarBranchOrdering.canonicalDirectoryKey($0.currentDirectory, homeDirectoryForTildeExpansion: homeDirectory) == targetKey
        }
    }

}
