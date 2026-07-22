// Native git worktree workflow (docs/plans/worktree-and-layouts.md): v2 socket handlers for
// `worktree.create/open/remove/list`. Mirrors TerminalController+Workspace.swift's V2CallResult
// / v2MainSync shape. All git/filesystem I/O runs through GitWorktreeManager, which is
// synchronous by construction (matches GitMetadataProber) -- v2MainSync here is used only
// around the final tabManager mutation, per the socket threading policy in CLAUDE.md.
import Foundation

extension TerminalController {
    // MARK: - V2 Worktree Methods

    func v2WorktreeCreate(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let repoRoot = v2ResolveWorktreeRepoRoot(params: params) else {
            return .err(code: "not_a_git_repo", message: "Could not resolve a git repository from 'repo'", data: nil)
        }
        guard let branch = v2String(params, "branch") else {
            return v2InvalidParam("branch")
        }
        let base = v2String(params, "base")
        let layoutName = v2String(params, "layout")

        if let layoutName, v2MainSync({ ProgramaLayoutStore.shared.load(name: layoutName) }) == nil {
            return .err(code: "layout_not_found", message: "No saved layout named '\(layoutName)'", data: nil)
        }

        if let existing = GitWorktreeManager.worktreeCheckedOut(branch: branch, repoRoot: repoRoot) {
            return .err(code: "branch_checked_out", message: "Branch '\(branch)' is already checked out at \(existing.path)", data: [
                "existing_path": existing.path
            ])
        }

        let path = v2ResolveWorktreePath(params: params, repoRoot: repoRoot, branch: branch)

        switch GitWorktreeManager.add(repoRoot: repoRoot, branch: branch, base: base, path: path) {
        case .success(let entry):
            return v2CompleteWorktreeCreation(
                tabManager: tabManager,
                entry: entry,
                repoRoot: repoRoot,
                layoutName: layoutName,
                focusRequested: v2Bool(params, "focus") ?? false
            )
        case .notAGitRepo:
            return .err(code: "not_a_git_repo", message: "'\(repoRoot)' is not a git repository", data: nil)
        case .branchCheckedOut(let existing):
            return .err(code: "branch_checked_out", message: "Branch '\(branch)' is already checked out at \(existing.path)", data: [
                "existing_path": existing.path
            ])
        case .worktreePathExists:
            return .err(code: "worktree_path_exists", message: "Path already exists: \(path)", data: nil)
        case .gitCommandFailed(let message):
            return .err(code: "git_command_failed", message: message, data: nil)
        }
    }

    private func v2CompleteWorktreeCreation(
        tabManager: TabManager,
        entry: GitWorktreeManager.WorktreeEntry,
        repoRoot: String,
        layoutName: String?,
        focusRequested: Bool
    ) -> V2CallResult {
        let shouldFocus = v2FocusAllowed(requested: focusRequested)
        var newId: UUID?
        v2MainSync {
            let ws = tabManager.addWorkspace(
                workingDirectory: entry.path,
                select: shouldFocus,
                eagerLoadTerminal: !shouldFocus
            )
            ws.worktreeBranch = entry.branch
            if let parent = self.v2WorktreeParentWorkspace(tabManager: tabManager, repoRoot: repoRoot) {
                ws.worktreeParentWorkspaceId = parent.id
                _ = tabManager.reorderWorkspace(tabId: ws.id, after: parent.id)
            }
            if let layoutName {
                _ = ws.applyNamedLayout(name: layoutName, baseCwd: entry.path, store: ProgramaLayoutStore.shared)
            }
            newId = ws.id
        }

        guard let newId else {
            return .err(code: "internal_error", message: "Failed to create worktree workspace", data: nil)
        }
        let windowId = v2ResolveWindowId(tabManager: tabManager)
        return .ok([
            "worktree": ["path": entry.path, "branch": v2OrNull(entry.branch), "repo": repoRoot],
            "workspace_id": newId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: newId),
            "window_id": v2OrNull(windowId?.uuidString),
            "window_ref": v2Ref(kind: .window, uuid: windowId)
        ])
    }

    func v2WorktreeOpen(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
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

        if let existingWorkspace = v2MainSync({ self.v2WorktreeOpenWorkspace(tabManager: tabManager, path: entry.path) }) {
            // "already open" is idempotent -- only touch focus/selection when the caller
            // explicitly opted in via `focus: true` (socket focus policy default is false).
            if v2FocusAllowed(requested: v2Bool(params, "focus") ?? false) {
                v2MainSync {
                    if let windowId = self.v2ResolveWindowId(tabManager: tabManager) {
                        _ = AppDelegate.shared?.focusMainWindow(windowId: windowId)
                        self.setActiveTabManager(tabManager)
                    }
                    tabManager.selectWorkspace(existingWorkspace)
                }
            }
            let windowId = v2ResolveWindowId(tabManager: tabManager)
            return .ok([
                "worktree": ["path": entry.path, "branch": v2OrNull(entry.branch), "repo": repoRoot],
                "workspace_id": existingWorkspace.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: existingWorkspace.id),
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId)
            ])
        }

        return v2CompleteWorktreeCreation(
            tabManager: tabManager,
            entry: entry,
            repoRoot: repoRoot,
            layoutName: nil,
            focusRequested: v2Bool(params, "focus") ?? false
        )
    }

    func v2WorktreeRemove(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
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
            var closedWorkspaceId: UUID?
            v2MainSync {
                if let ws = self.v2WorktreeOpenWorkspace(tabManager: tabManager, path: entry.path) {
                    tabManager.closeWorkspace(ws)
                    closedWorkspaceId = ws.id
                }
            }
            var result: [String: Any] = ["removed": true]
            if let closedWorkspaceId {
                result["closed_workspace_id"] = closedWorkspaceId.uuidString
            }
            return .ok(result)
        case .notAGitRepo:
            return .err(code: "not_a_git_repo", message: "'\(repoRoot)' is not a git repository", data: nil)
        case .worktreeNotFound:
            return .err(code: "worktree_not_found", message: "No matching worktree found", data: nil)
        case .worktreeDirty(let message):
            return .err(code: "worktree_dirty", message: message.isEmpty ? "Worktree has uncommitted changes" : message, data: nil)
        case .gitCommandFailed(let message):
            return .err(code: "git_command_failed", message: message, data: nil)
        }
    }

    func v2WorktreeList(params: [String: Any]) -> V2CallResult {
        let tabManager = v2ResolveTabManager(params: params)
        guard let repoRoot = v2ResolveWorktreeRepoRoot(params: params) else {
            return .err(code: "not_a_git_repo", message: "Could not resolve a git repository from 'repo'", data: nil)
        }
        guard let entries = GitWorktreeManager.listWorktrees(repoRoot: repoRoot) else {
            return .err(code: "not_a_git_repo", message: "'\(repoRoot)' is not a git repository", data: nil)
        }

        var payloads: [[String: Any]] = []
        for entry in entries where !entry.isBare {
            var payload: [String: Any] = [
                "path": entry.path,
                "branch": v2OrNull(entry.branch),
                "head": v2OrNull(entry.headSHA),
                "is_open": false
            ]
            if let tabManager,
               let ws = v2MainSync({ self.v2WorktreeOpenWorkspace(tabManager: tabManager, path: entry.path) }) {
                payload["is_open"] = true
                payload["workspace_id"] = ws.id.uuidString
                payload["workspace_ref"] = v2Ref(kind: .workspace, uuid: ws.id)
            }
            payloads.append(payload)
        }

        return .ok(["repo": repoRoot, "worktrees": payloads])
    }

    // MARK: - Shared helpers

    private func v2ExpandedPath(_ raw: String) -> String {
        (raw as NSString).expandingTildeInPath
    }

    /// Resolves the repo root from the `repo` param via `git rev-parse --show-toplevel`, so
    /// callers can pass any directory inside the repo, not only its exact toplevel. Missing or
    /// unresolvable `repo` fails clearly rather than falling back to the app process's own
    /// (meaningless, from the caller's perspective) working directory -- see plan risk #2.
    private func v2ResolveWorktreeRepoRoot(params: [String: Any]) -> String? {
        guard let raw = v2String(params, "repo") else { return nil }
        return GitWorktreeManager.resolveRepoRoot(from: v2ExpandedPath(raw))
    }

    private func v2ResolveWorktreePath(params: [String: Any], repoRoot: String, branch: String) -> String {
        if let raw = v2String(params, "path") {
            return v2ExpandedPath(raw)
        }
        let baseDirectory = ProgramaWorktreeSettings.resolvedDirectory()
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

    /// Finds an already-open workspace whose directory matches `repoRoot` exactly, used to
    /// group a newly created worktree workspace next to its parent repo workspace in the
    /// sidebar (adjacency = grouping, see plan decision #4). Returns nil (ungrouped) if the
    /// parent repo isn't open as a workspace -- the worktree workspace still opens correctly.
    @MainActor
    private func v2WorktreeParentWorkspace(tabManager: TabManager, repoRoot: String) -> Workspace? {
        v2WorktreeOpenWorkspace(tabManager: tabManager, path: repoRoot)
    }
}
