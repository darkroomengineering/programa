import Foundation

private enum AgentSupervisionInputError: Error {
    case message(String)
}

extension TerminalController {
    nonisolated func v2AgentTaskStart(params: [String: Any]) -> V2CallResult {
        do {
            let workspaceId = try agentUUID(params, key: "workspace_id", required: true)!
            let agentId = try agentIdentifier(params, key: "agent_id", required: false) ?? UUID()
            let parentId = try agentIdentifier(params, key: "parent_id", required: false)
            let surfaceId = try agentUUID(params, key: "surface_id", required: false)
            let host = try agentText(params, key: "host", required: true, maximumLength: 128)!
            let session = try agentText(params, key: "session", required: false, maximumLength: 512)
            let task = try agentText(params, key: "task", required: false, maximumLength: 2_048)
            let role = try agentText(params, key: "role", required: false, maximumLength: 256)
            let state = try agentState(params, default: .working)
            let placement = try agentPlacement(params, default: .runsWithParent)

            return v2MainSync {
                guard let (_, workspace) = agentWorkspace(id: workspaceId) else {
                    return .err(code: "not_found", message: "Workspace not found", data: [
                        "workspace_id": workspaceId.uuidString,
                    ])
                }
                if let surfaceId, workspace.panels[surfaceId] == nil {
                    return .err(code: "not_found", message: "Surface not found in workspace", data: [
                        "workspace_id": workspaceId.uuidString,
                        "surface_id": surfaceId.uuidString,
                    ])
                }
                if let parentId {
                    guard let parent = AgentSupervisionRegistry.shared.record(id: parentId),
                          parent.workspaceId == workspaceId else {
                        return .err(code: "not_found", message: "Parent helper not found in workspace", data: [
                            "parent_id": parentId.uuidString,
                        ])
                    }
                }
                do {
                    let record = try AgentSupervisionRegistry.shared.start(
                        id: agentId,
                        parentId: parentId,
                        host: host,
                        session: session,
                        task: task,
                        role: role,
                        state: state,
                        placement: placement,
                        workspaceId: workspaceId,
                        surfaceId: surfaceId
                    )
                    return .ok(["agent": record.payload()])
                } catch {
                    return agentRegistryError(error)
                }
            }
        } catch AgentSupervisionInputError.message(let message) {
            return .err(code: "invalid_params", message: message, data: nil)
        } catch {
            return .err(code: "invalid_params", message: "Invalid agent task", data: nil)
        }
    }

    nonisolated func v2AgentTaskUpdate(params: [String: Any]) -> V2CallResult {
        do {
            let agentId = try agentIdentifier(params, key: "agent_id", required: true)!
            let workspaceId = try agentUUID(params, key: "workspace_id", required: false)
            let surfaceId = try agentUUID(params, key: "surface_id", required: false)
            let session = try agentText(params, key: "session", required: false, maximumLength: 512)
            let task = try agentText(params, key: "task", required: false, maximumLength: 2_048)
            let role = try agentText(params, key: "role", required: false, maximumLength: 256)
            let state = try agentOptionalState(params)

            return v2MainSync {
                if let workspaceId {
                    guard let (_, workspace) = agentWorkspace(id: workspaceId) else {
                        return .err(code: "not_found", message: "Workspace not found", data: [
                            "workspace_id": workspaceId.uuidString,
                        ])
                    }
                    if let surfaceId, workspace.panels[surfaceId] == nil {
                        return .err(code: "not_found", message: "Surface not found in workspace", data: [
                            "workspace_id": workspaceId.uuidString,
                            "surface_id": surfaceId.uuidString,
                        ])
                    }
                } else if let surfaceId,
                          let current = AgentSupervisionRegistry.shared.record(id: agentId),
                          agentWorkspace(id: current.workspaceId)?.workspace.panels[surfaceId] == nil {
                    return .err(code: "not_found", message: "Surface not found in workspace", data: [
                        "surface_id": surfaceId.uuidString,
                    ])
                }
                do {
                    let record = try AgentSupervisionRegistry.shared.update(
                        id: agentId,
                        state: state,
                        session: session,
                        task: task,
                        role: role,
                        workspaceId: workspaceId,
                        surfaceId: surfaceId
                    )
                    return .ok(["agent": record.payload()])
                } catch {
                    return agentRegistryError(error)
                }
            }
        } catch AgentSupervisionInputError.message(let message) {
            return .err(code: "invalid_params", message: message, data: nil)
        } catch {
            return .err(code: "invalid_params", message: "Invalid agent task update", data: nil)
        }
    }

    nonisolated func v2AgentTaskFinish(params: [String: Any]) -> V2CallResult {
        do {
            let agentId = try agentIdentifier(params, key: "agent_id", required: true)!
            let state = try agentState(params, default: .completed)
            guard state.isFinished else {
                return .err(
                    code: "invalid_params",
                    message: "state must be completed, failed, or cancelled",
                    data: nil
                )
            }
            return v2MainSync {
                do {
                    let record = try AgentSupervisionRegistry.shared.finish(id: agentId, state: state)
                    return .ok(["agent": record.payload()])
                } catch {
                    return agentRegistryError(error)
                }
            }
        } catch AgentSupervisionInputError.message(let message) {
            return .err(code: "invalid_params", message: message, data: nil)
        } catch {
            return .err(code: "invalid_params", message: "Invalid agent task finish", data: nil)
        }
    }

    nonisolated func v2AgentTaskFinishSession(params: [String: Any]) -> V2CallResult {
        do {
            let host = try agentText(params, key: "host", required: true, maximumLength: 128)!
            let session = try agentText(params, key: "session", required: true, maximumLength: 512)!
            let state = try agentState(params, default: .cancelled)
            guard state.isFinished else {
                return .err(
                    code: "invalid_params",
                    message: "state must be completed, failed, or cancelled",
                    data: nil
                )
            }
            return v2MainSync {
                do {
                    let records = try AgentSupervisionRegistry.shared.finishSession(
                        host: host,
                        session: session,
                        state: state
                    )
                    return .ok([
                        "agents": records.map { $0.payload() },
                        "count": records.count,
                    ])
                } catch {
                    return agentRegistryError(error)
                }
            }
        } catch AgentSupervisionInputError.message(let message) {
            return .err(code: "invalid_params", message: message, data: nil)
        } catch {
            return .err(code: "invalid_params", message: "Invalid helper session finish", data: nil)
        }
    }

    nonisolated func v2AgentTaskList(params: [String: Any]) -> V2CallResult {
        do {
            let workspaceId = try agentUUID(params, key: "workspace_id", required: false)
            let parentId = try agentIdentifier(params, key: "parent_id", required: false)
            let includeFinished = try agentBool(params, key: "include_finished", default: true)
            return v2MainSync {
                if let workspaceId, agentWorkspace(id: workspaceId) == nil {
                    return .err(code: "not_found", message: "Workspace not found", data: [
                        "workspace_id": workspaceId.uuidString,
                    ])
                }
                var liveWorkspaceIds = Set(AppDelegate.shared?.scriptableMainWindows().flatMap {
                    $0.tabManager.tabs.map(\.id)
                } ?? [])
                if let tabManager = self.tabManager {
                    liveWorkspaceIds.formUnion(tabManager.tabs.map(\.id))
                }
                AgentSupervisionRegistry.shared.retainWorkspaces(liveWorkspaceIds)
                let workspaceIds = workspaceId.map { Set([$0]) }
                let records = AgentSupervisionRegistry.shared.records(
                    workspaceIds: workspaceIds,
                    parentId: parentId,
                    includeFinished: includeFinished
                )
                return .ok([
                    "agents": records.map { $0.payload() },
                    "count": records.count,
                ])
            }
        } catch AgentSupervisionInputError.message(let message) {
            return .err(code: "invalid_params", message: message, data: nil)
        } catch {
            return .err(code: "invalid_params", message: "Invalid agent task list", data: nil)
        }
    }

    nonisolated func v2AgentSpawn(params: [String: Any]) -> V2CallResult {
        do {
            let parentWorkspaceId = try agentUUID(params, key: "parent_workspace_id", required: true)!
            let parentAgentId = try agentIdentifier(params, key: "parent_agent_id", required: false)
            let host = try agentText(params, key: "host", required: false, maximumLength: 128) ?? "programa"
            let session = try agentText(params, key: "session", required: false, maximumLength: 512)
            let task = try agentText(params, key: "task", required: false, maximumLength: 2_048)
            let role = try agentText(params, key: "role", required: false, maximumLength: 256)
            let initialCommand = try agentText(
                params,
                key: "initial_command",
                required: false,
                maximumLength: 16_384
            )
            let initialEnv: [String: String]
            if let rawInitialEnv = params["initial_env"] {
                guard let values = rawInitialEnv as? [String: Any],
                      values.values.allSatisfy({ $0 is String }),
                      let parsed = v2StringMap(params, "initial_env") else {
                    return .err(code: "invalid_params", message: "initial_env must contain string values", data: nil)
                }
                initialEnv = parsed
            } else {
                initialEnv = [:]
            }
            let needsIsolation = try agentBool(params, key: "needs_isolation", default: false)
            if needsIsolation {
                let repository = try agentText(
                    params,
                    key: "repository_path",
                    required: false,
                    maximumLength: 4_096
                )
                let branch = try agentText(params, key: "branch", required: false, maximumLength: 512)
                let base = try agentText(params, key: "base", required: false, maximumLength: 4_096)
                let layout = try agentText(params, key: "layout", required: false, maximumLength: 4_096)
                guard let repository, let branch else {
                    return .err(
                        code: "invalid_params",
                        message: "repository_path and branch are required when needs_isolation is true",
                        data: ["use_method": "worktree.create"]
                    )
                }
                guard initialEnv.isEmpty else {
                    return .err(
                        code: "invalid_params",
                        message: "initial_env is not supported for a separate worktree helper",
                        data: nil
                    )
                }

                let agentId = UUID()
                let parentValidation: (directory: String?, error: V2CallResult?) = v2MainSync {
                    guard let (_, parentWorkspace) = agentWorkspace(id: parentWorkspaceId) else {
                        return (nil, .err(code: "not_found", message: "Parent workspace not found", data: [
                            "parent_workspace_id": parentWorkspaceId.uuidString,
                        ]))
                    }
                    if let parentAgentId {
                        guard let parentRecord = AgentSupervisionRegistry.shared.record(id: parentAgentId),
                              parentRecord.workspaceId == parentWorkspaceId else {
                            return (nil, .err(code: "not_found", message: "Parent helper not found in the parent workspace", data: [
                                "parent_agent_id": parentAgentId.uuidString,
                            ]))
                        }
                    }
                    do {
                        _ = try AgentSupervisionRegistry.shared.start(
                            id: agentId,
                            parentId: parentAgentId,
                            host: host,
                            session: session,
                            task: task,
                            role: role,
                            placement: .separateWorktree,
                            workspaceId: parentWorkspaceId
                        )
                    } catch {
                        return (nil, agentRegistryError(error))
                    }
                    return (parentWorkspace.currentDirectory, nil)
                }
                if let error = parentValidation.error { return error }
                guard let parentDirectory = parentValidation.directory else {
                    return .err(code: "internal_error", message: "Could not prepare the helper", data: nil)
                }
                guard let parentRepoRoot = GitWorktreeManager.resolveRepoRoot(
                    from: parentDirectory
                ), let requestedRepoRoot = GitWorktreeManager.resolveRepoRoot(from: repository) else {
                    v2MainSync { AgentSupervisionRegistry.shared.discard(id: agentId) }
                    return .err(code: "not_a_git_repo", message: "The parent workspace is not in that git repository", data: nil)
                }
                let normalizedParentRepo = URL(fileURLWithPath: parentRepoRoot)
                    .resolvingSymlinksInPath().standardizedFileURL.path
                let normalizedRequestedRepo = URL(fileURLWithPath: requestedRepoRoot)
                    .resolvingSymlinksInPath().standardizedFileURL.path
                guard normalizedParentRepo == normalizedRequestedRepo else {
                    v2MainSync { AgentSupervisionRegistry.shared.discard(id: agentId) }
                    return .err(
                        code: "repository_mismatch",
                        message: "A helper worktree must use the parent workspace's repository",
                        data: ["parent_repository": normalizedParentRepo]
                    )
                }
                let parentWindowId: UUID? = v2MainSync {
                    guard let (tabManager, _) = agentWorkspace(id: parentWorkspaceId) else { return nil }
                    return AppDelegate.shared?.windowId(for: tabManager)
                }
                guard let parentWindowId else {
                    v2MainSync { AgentSupervisionRegistry.shared.discard(id: agentId) }
                    return .err(code: "not_found", message: "Parent workspace not found", data: [
                        "parent_workspace_id": parentWorkspaceId.uuidString,
                    ])
                }
                guard params["path"] == nil else {
                    v2MainSync { AgentSupervisionRegistry.shared.discard(id: agentId) }
                    return .err(
                        code: "invalid_params",
                        message: "agent.spawn uses Programa's configured worktree folder; omit path",
                        data: nil
                    )
                }

                let latestParentDirectory: String? = v2MainSync {
                    guard let tabManager = AppDelegate.shared?.tabManagerFor(windowId: parentWindowId),
                          let parent = tabManager.tabs.first(where: { $0.id == parentWorkspaceId }) else {
                        return nil
                    }
                    return parent.currentDirectory
                }
                guard let latestParentDirectory,
                      let latestParentRepo = GitWorktreeManager.resolveRepoRoot(from: latestParentDirectory),
                      URL(fileURLWithPath: latestParentRepo)
                        .resolvingSymlinksInPath().standardizedFileURL.path == normalizedParentRepo else {
                    v2MainSync { AgentSupervisionRegistry.shared.discard(id: agentId) }
                    return .err(
                        code: "parent_changed",
                        message: "The parent workspace changed while the helper was being prepared",
                        data: ["parent_workspace_id": parentWorkspaceId.uuidString]
                    )
                }

                var worktreeParams: [String: Any] = [
                    "repo": normalizedParentRepo,
                    "branch": branch,
                    "window_id": parentWindowId.uuidString,
                    "focus": false,
                    "required_parent_workspace_id": parentWorkspaceId.uuidString,
                    "required_parent_directory": latestParentDirectory,
                ]
                if let base { worktreeParams["base"] = base }
                if let layout { worktreeParams["layout"] = layout }

                let worktreeResult = v2WorktreeCreate(params: worktreeParams)
                guard case .ok(let rawPayload) = worktreeResult,
                      let payload = rawPayload as? [String: Any],
                      let workspaceIdRaw = payload["workspace_id"] as? String,
                      let workspaceId = UUID(uuidString: workspaceIdRaw) else {
                    v2MainSync { AgentSupervisionRegistry.shared.discard(id: agentId) }
                    return worktreeResult
                }

                let setupResult: V2CallResult = v2MainSync {
                    guard let (tabManager, workspace) = agentWorkspace(id: workspaceId) else {
                        AgentSupervisionRegistry.shared.discard(id: agentId)
                        return .err(
                            code: "internal_error",
                            message: "The worktree was created, but its workspace is unavailable",
                            data: ["workspace_id": workspaceId.uuidString]
                        )
                    }
                    let automaticTitle = agentAutomaticTitle(task: task, role: role, siblingNumber: 1)
                    workspace.automaticAgentTitle = automaticTitle
                    workspace.agentParentWorkspaceId = parentWorkspaceId
                    tabManager.canonicalizeHierarchyOrderIfNeeded()
                    let surfaceId = workspace.focusedTerminalPanel?.id

                    do {
                        let record = try AgentSupervisionRegistry.shared.update(
                            id: agentId,
                            task: task ?? automaticTitle,
                            workspaceId: workspace.id,
                            surfaceId: surfaceId
                        )
                        if let initialCommand, let terminal = workspace.focusedTerminalPanel {
                            terminal.sendInput(initialCommand + "\n")
                        }
                        tabManager.openCompanionBrowserSplitIfEnabled(for: workspace)
                        var result = payload
                        result["agent_id"] = agentId.uuidString
                        result["surface_id"] = v2OrNull(surfaceId?.uuidString)
                        result["surface_ref"] = v2Ref(kind: .surface, uuid: surfaceId)
                        result["focused"] = false
                        result["agent"] = record.payload()
                        return .ok(result)
                    } catch {
                        return agentRegistryError(error)
                    }
                }
                if case .err = setupResult,
                   let worktree = payload["worktree"] as? [String: Any],
                   let path = worktree["path"] as? String {
                    _ = v2WorktreeRemove(params: [
                        "repo": normalizedParentRepo,
                        "path": path,
                        "workspace_id": workspaceId.uuidString,
                    ])
                }
                return setupResult
            }

            return v2MainSync {
                guard let (tabManager, parentWorkspace) = agentWorkspace(id: parentWorkspaceId) else {
                    return .err(code: "not_found", message: "Parent workspace not found", data: [
                        "parent_workspace_id": parentWorkspaceId.uuidString,
                    ])
                }
                if let parentAgentId {
                    guard let parentRecord = AgentSupervisionRegistry.shared.record(id: parentAgentId),
                          parentRecord.workspaceId == parentWorkspaceId else {
                        return .err(code: "not_found", message: "Parent helper not found in the parent workspace", data: [
                            "parent_agent_id": parentAgentId.uuidString,
                        ])
                    }
                }

                let agentId = UUID()
                let siblingNumber = tabManager.tabs.lazy
                    .filter { $0.agentParentWorkspaceId == parentWorkspaceId }
                    .count + 1
                let automaticTitle = agentAutomaticTitle(
                    task: task,
                    role: role,
                    siblingNumber: siblingNumber
                )
                do {
                    _ = try AgentSupervisionRegistry.shared.start(
                        id: agentId,
                        parentId: parentAgentId,
                        host: host,
                        session: session,
                        task: task ?? automaticTitle,
                        role: role,
                        placement: .nestedWorkspace,
                        workspaceId: parentWorkspaceId
                    )
                } catch {
                    return agentRegistryError(error)
                }
                let workspace = tabManager.addWorkspace(
                    workingDirectory: parentWorkspace.currentDirectory,
                    initialTerminalCommand: initialCommand,
                    initialTerminalEnvironment: initialEnv,
                    select: false,
                    eagerLoadTerminal: true,
                    autoWelcomeIfNeeded: false
                )
                workspace.automaticAgentTitle = automaticTitle
                workspace.agentParentWorkspaceId = parentWorkspaceId
                tabManager.canonicalizeHierarchyOrderIfNeeded()
                let surfaceId = workspace.focusedTerminalPanel?.id
                tabManager.openCompanionBrowserSplitIfEnabled(for: workspace)

                do {
                    let record = try AgentSupervisionRegistry.shared.update(
                        id: agentId,
                        workspaceId: workspace.id,
                        surfaceId: surfaceId
                    )
                    // Pane hosting the spawned terminal, so callers can target it without a lookup.
                    let paneUUID = surfaceId.flatMap { workspace.paneId(forPanelId: $0)?.id }
                    return .ok([
                        "agent_id": agentId.uuidString,
                        "workspace_id": workspace.id.uuidString,
                        "workspace_ref": v2Ref(kind: .workspace, uuid: workspace.id),
                        "pane_id": v2OrNull(paneUUID?.uuidString),
                        "pane_ref": v2Ref(kind: .pane, uuid: paneUUID),
                        "surface_id": v2OrNull(surfaceId?.uuidString),
                        "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                        "focused": false,
                        "agent": record.payload(),
                    ])
                } catch {
                    return agentRegistryError(error)
                }
            }
        } catch AgentSupervisionInputError.message(let message) {
            return .err(code: "invalid_params", message: message, data: nil)
        } catch {
            return .err(code: "invalid_params", message: "Invalid helper request", data: nil)
        }
    }

    @MainActor
    private func agentWorkspace(id: UUID) -> (tabManager: TabManager, workspace: Workspace)? {
        let manager = AppDelegate.shared?.tabManagerFor(tabId: id) ?? tabManager
        guard let manager,
              let workspace = manager.tabs.first(where: { $0.id == id }) else { return nil }
        return (manager, workspace)
    }

    @MainActor
    private func agentRegistryError(_ error: Error) -> V2CallResult {
        switch error {
        case AgentSupervisionRegistryError.duplicate(let id):
            return .err(code: "conflict", message: "Helper already exists", data: ["agent_id": id.uuidString])
        case AgentSupervisionRegistryError.missing(let id):
            return .err(code: "not_found", message: "Helper not found", data: ["agent_id": id.uuidString])
        case AgentSupervisionRegistryError.parentMissing(let id):
            return .err(code: "not_found", message: "Parent helper not found", data: ["parent_id": id.uuidString])
        case AgentSupervisionRegistryError.alreadyFinished(let id):
            return .err(code: "conflict", message: "Helper already finished", data: ["agent_id": id.uuidString])
        case AgentSupervisionRegistryError.finishStateRequired:
            return .err(code: "invalid_params", message: "A finished state is required", data: nil)
        case AgentSupervisionRegistryError.capacityReached:
            return .err(
                code: "capacity_reached",
                message: "Too many helpers are active; finish one before starting another",
                data: nil
            )
        default:
            return .err(code: "internal_error", message: "Could not update helper", data: nil)
        }
    }

    private nonisolated func agentText(
        _ params: [String: Any],
        key: String,
        required: Bool,
        maximumLength: Int
    ) throws -> String? {
        guard let raw = params[key] else {
            if required { throw AgentSupervisionInputError.message("Missing \(key)") }
            return nil
        }
        guard let string = raw as? String else {
            throw AgentSupervisionInputError.message("\(key) must be a string")
        }
        let value = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            if required { throw AgentSupervisionInputError.message("\(key) cannot be empty") }
            return nil
        }
        guard value.utf8.count <= maximumLength else {
            throw AgentSupervisionInputError.message("\(key) is too long")
        }
        return value
    }

    private nonisolated func agentUUID(
        _ params: [String: Any],
        key: String,
        required: Bool
    ) throws -> UUID? {
        guard params[key] != nil else {
            if required { throw AgentSupervisionInputError.message("Missing \(key)") }
            return nil
        }
        guard let value = v2UUID(params, key) else {
            throw AgentSupervisionInputError.message("\(key) must be a valid UUID or reference")
        }
        return value
    }

    private nonisolated func agentIdentifier(
        _ params: [String: Any],
        key: String,
        required: Bool
    ) throws -> UUID? {
        guard let raw = params[key] else {
            if required { throw AgentSupervisionInputError.message("Missing \(key)") }
            return nil
        }
        guard let string = raw as? String,
              let value = UUID(uuidString: string.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw AgentSupervisionInputError.message("\(key) must be a valid UUID")
        }
        return value
    }

    private nonisolated func agentBool(
        _ params: [String: Any],
        key: String,
        default defaultValue: Bool
    ) throws -> Bool {
        guard params[key] != nil else { return defaultValue }
        guard let value = v2Bool(params, key) else {
            throw AgentSupervisionInputError.message("\(key) must be true or false")
        }
        return value
    }

    private nonisolated func agentState(
        _ params: [String: Any],
        default defaultState: AgentTaskState
    ) throws -> AgentTaskState {
        guard params["state"] != nil else { return defaultState }
        guard let raw = v2String(params, "state"), let state = AgentTaskState(rawValue: raw) else {
            throw AgentSupervisionInputError.message(
                "state must be idle, working, blocked, completed, failed, or cancelled"
            )
        }
        return state
    }

    private nonisolated func agentOptionalState(_ params: [String: Any]) throws -> AgentTaskState? {
        guard params["state"] != nil else { return nil }
        return try agentState(params, default: .working)
    }

    private nonisolated func agentPlacement(
        _ params: [String: Any],
        default defaultPlacement: AgentTaskPlacement
    ) throws -> AgentTaskPlacement {
        guard params["placement"] != nil else { return defaultPlacement }
        guard let raw = v2String(params, "placement"),
              let placement = AgentTaskPlacement(rawValue: raw) else {
            throw AgentSupervisionInputError.message(
                "placement must be nested_workspace, separate_worktree, or runs_with_parent"
            )
        }
        return placement
    }

    private nonisolated func agentAutomaticTitle(
        task: String?,
        role: String?,
        siblingNumber: Int
    ) -> String {
        let fallback = String(
            format: String(localized: "agentOverview.helperNumbered", defaultValue: "Helper %lld"),
            Int64(siblingNumber)
        )
        let source = task?.split(separator: "\n", maxSplits: 1).first.map(String.init)
            ?? role
            ?? fallback
        return String(source.prefix(80))
    }
}
