// Sidebar telemetry mutation/query members
// (directory, shell-activity, git-branch, pull-request, status, log, and metadata-block state).

import Foundation
import SwiftUI
import AppKit
import Bonsplit

enum SidebarTelemetryLimits {
    static let maxKeyBytes = 512
    static let maxDirectoryBytes = 4 * 1024
    static let maxGitBranchBytes = 1024
    static let maxPullRequestURLBytes = 4 * 1024
    static let maxPullRequestLabelBytes = 64
    static let maxProgressLabelBytes = 512
    static let maxTTYNameBytes = 1024
    static let maxStatusIconBytes = 256
    static let maxStatusColorBytes = 128
    static let maxStatusURLBytes = 4 * 1024
    static let maxLogSourceBytes = 512
    static let maxLogMessageBytes = 64 * 1024
    static let maxStatusValueBytes = 16 * 1024
    static let maxMetadataMarkdownBytes = 256 * 1024
    static let maxStatusEntries = 128
    static let maxMetadataBlocks = 128
    static let maxAgentPIDs = 128
    // With no protocol dimension, 1...65_535 exhausts the numeric port domain;
    // duplicates count toward this raw ingress limit before canonicalization.
    static let maxReportedPorts = 65_535

    static func utf8ByteCount(_ value: String) -> Int {
        value.utf8.count
    }

    static func isWithinUTF8Limit(_ value: String?, maxBytes: Int) -> Bool {
        value.map { utf8ByteCount($0) <= maxBytes } ?? true
    }

    static func configuredMaxLogEntries() -> Int {
        let configured = UserDefaults.standard.object(forKey: "sidebarMaxLogEntries") as? Int ?? 50
        return max(1, min(500, configured))
    }
}

/// How a program's root record went away, as the prompt gate sees it. Only a signed `state=clear`,
/// or a shell prompt mark after the shell's own socket report, proves the prompt went with it.
enum ProgramRootClear {
    case signed
    case unsigned
    /// The OSC 133;A mark that drops `working` and `blocked` records.
    case shellPrompt
}

extension Workspace {
    func updatePanelDirectory(panelId: UUID, directory: String) {
        guard let normalized = normalizedSidebarDirectory(directory) else { return }
        if panelDirectories[panelId] != normalized {
            panelDirectories[panelId] = normalized
        }
        if panelId == focusedPanelId, currentDirectory != normalized {
            currentDirectory = normalized
        }
    }

    /// Records the resolved form of the directory just reported for `panelId` (resolved off main by
    /// the reporter; nil when it does not resolve). It stays tied to that report: a later
    /// directory from any path makes it stale.
    func noteResolvedPanelDirectory(panelId: UUID, resolved: String?) {
        guard let reported = panelDirectories[panelId] else { return }
        resolvedPanelDirectories[panelId] = ResolvedPanelDirectory(reported: reported, resolved: resolved)
    }

    /// The directory event routes see for `panelId`: the resolved form of its current reported
    /// directory, or nil when none was resolved for it.
    func resolvedRouteDirectory(for panelId: UUID) -> String? {
        guard let entry = resolvedPanelDirectories[panelId], entry.reported == panelDirectories[panelId] else { return nil }
        return entry.resolved
    }

    /// Updates the shell-activity state for a panel.
    ///
    /// - Returns: `true` if the update was applied (panel exists and state changed),
    ///   `false` if it was a no-op (panel absent or state unchanged).
    ///   Callers that deduplicate reports MUST only record the state in their dedup
    ///   dict when this returns `true`; recording on `false` would suppress the next
    ///   identical report even though it was never actually applied.
    @discardableResult
    func updatePanelShellActivityState(panelId: UUID, state: PanelShellActivityState) -> Bool {
        guard panels[panelId] != nil else { return false }
        let previousState = panelShellActivityStates[panelId] ?? .unknown
        guard previousState != state else { return false }
        panelShellActivityStates[panelId] = state
        // The shell's own socket report, unlike a printed prompt mark, proves the foreground
        // program exited. zsh sends it before it prints the prompt mark, so while the route view
        // still shows `blocked` it is remembered, and the mark's clear then ends the prompt
        // (`clearPanelAgentState`). bash and fish send it in the background, so it can also land
        // after the mark, whose clear then left a program presence with no record: end it here.
        if state == .promptIdle {
            panelsShellReturnedSincePromptArmed.insert(panelId)
            if panelAgentPresence[panelId]?.source == .program,
               (panels[panelId] as? TerminalPanel)?.programStatus.root == nil {
                clearPanelAgentState(panelId: panelId, source: .program, programClear: .shellPrompt)
            }
            closePromptGate(panelId: panelId, by: .agent)
        } else {
            panelsShellReturnedSincePromptArmed.remove(panelId)
        }
        // The shell left its prompt, so the banner's Resume could no longer type its line.
        // Only on entering `.commandRunning`: the agent's exit can land while the shell still
        // reports the agent itself as running, before its prompt report.
        if state == .commandRunning, interruptedAgentPanels[panelId] == .shellAlive {
            interruptedAgentPanels.removeValue(forKey: panelId)
        }
#if DEBUG
        dlog(
            "surface.shellState workspace=\(id.uuidString.prefix(5)) " +
            "panel=\(panelId.uuidString.prefix(5)) from=\(previousState.rawValue) to=\(state.rawValue)"
        )
#endif
        return true
    }

    func panelNeedsConfirmClose(panelId: UUID, fallbackNeedsConfirmClose: Bool) -> Bool {
        Self.resolveCloseConfirmation(
            shellActivityState: panelShellActivityStates[panelId],
            hasKnownTTY: surfaceTTYNames[panelId] != nil,
            fallbackNeedsConfirmClose: fallbackNeedsConfirmClose
        )
    }

    func updatePanelGitBranch(panelId: UUID, branch: String, isDirty: Bool) {
        guard let normalizedBranch = normalizedBoundedSidebarBranchName(branch) else { return }
        let state = SidebarGitBranchState(branch: normalizedBranch, isDirty: isDirty)
        let existing = panelGitBranches[panelId]
        let branchChanged = existing?.branch != nil && existing?.branch != normalizedBranch
        var titleMetadataChanged = false
        if existing?.branch != normalizedBranch || existing?.isDirty != isDirty {
            panelGitBranches[panelId] = state
            titleMetadataChanged = true
        }
        if existing?.isDirty == true, !isDirty {
            clearReviewNudge(panelId: panelId)
        }
        if branchChanged {
            if panelPullRequests[panelId] != nil {
                panelPullRequests.removeValue(forKey: panelId)
                titleMetadataChanged = true
            }
            if panelId == focusedPanelId, pullRequest != nil {
                pullRequest = nil
            }
        }
        if panelId == focusedPanelId, gitBranch != state {
            gitBranch = state
        }
        if titleMetadataChanged {
            syncResolvedPanelTitle(panelId: panelId)
        }
    }

    func clearPanelGitBranch(panelId: UUID) {
        var titleMetadataChanged = false
        if panelGitBranches[panelId] != nil {
            panelGitBranches.removeValue(forKey: panelId)
            titleMetadataChanged = true
        }
        if panelPullRequests[panelId] != nil {
            panelPullRequests.removeValue(forKey: panelId)
            titleMetadataChanged = true
        }
        if panelId == focusedPanelId {
            if gitBranch != nil {
                gitBranch = nil
            }
            if pullRequest != nil {
                pullRequest = nil
            }
        }
        if titleMetadataChanged {
            syncResolvedPanelTitle(panelId: panelId)
        }
    }

    func updatePanelPullRequest(
        panelId: UUID,
        number: Int,
        label: String,
        url: URL,
        status: SidebarPullRequestStatus,
        branch: String? = nil,
        checks: SidebarPullRequestChecksStatus? = nil
    ) {
        let normalizedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedLabel.isEmpty,
              SidebarTelemetryLimits.utf8ByteCount(normalizedLabel) <= SidebarTelemetryLimits.maxPullRequestLabelBytes,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false,
              SidebarTelemetryLimits.utf8ByteCount(url.absoluteString) <= SidebarTelemetryLimits.maxPullRequestURLBytes else {
            return
        }
        let existing = panelPullRequests[panelId]
        let normalizedBranch = normalizedSidebarBranchName(branch)
        guard normalizedBranch.map({
            SidebarTelemetryLimits.utf8ByteCount($0) <= SidebarTelemetryLimits.maxGitBranchBytes
        }) ?? true else {
            return
        }
        let currentPanelBranch = normalizedBoundedSidebarBranchName(panelGitBranches[panelId]?.branch)
        let resolvedBranch: String? = {
            if let normalizedBranch {
                return normalizedBranch
            }
            if let currentPanelBranch {
                return currentPanelBranch
            }
            guard let existing,
                  existing.number == number,
                  existing.label == normalizedLabel,
                  existing.url == url,
                  existing.status == status else {
                return nil
            }
            return normalizedBoundedSidebarBranchName(existing.branch)
        }()
        let resolvedChecks: SidebarPullRequestChecksStatus? = {
            if let checks {
                return checks
            }
            guard let existing,
                  existing.number == number,
                  existing.label == normalizedLabel,
                  existing.url == url,
                  existing.status == status else {
                return nil
            }
            return existing.checks
        }()
        let state = SidebarPullRequestState(
            number: number,
            label: normalizedLabel,
            url: url,
            status: status,
            branch: resolvedBranch,
            checks: resolvedChecks
        )
        if existing != state {
            panelPullRequests[panelId] = state
            syncResolvedPanelTitle(panelId: panelId)
        }
        if panelId == focusedPanelId, pullRequest != state {
            pullRequest = state
        }
    }

    func clearPanelPullRequest(panelId: UUID) {
        if panelPullRequests[panelId] != nil {
            panelPullRequests.removeValue(forKey: panelId)
            syncResolvedPanelTitle(panelId: panelId)
        }
        if panelId == focusedPanelId, pullRequest != nil {
            pullRequest = nil
        }
    }

    /// Reports an agent activity state for a surface (hook, screen-manifest `.inferred` and
    /// OSC 7501 `.program` tiers; see docs/plans/screen-manifest-detection.md). This is the single
    /// funnel every report path goes through — `TabManager.updateSurfaceAgentState` (called by
    /// both `TerminalController+Telemetry.swift`'s hook-driven `v2SurfaceReportAgentState` and
    /// `AgentScreenDetectionEngine`'s screen-manifest sampler) is the only caller.
    ///
    /// Hooks-always-win precedence (`source` defaults to `.hooks`):
    /// - `source == .hooks` always writes — state and source both update unconditionally, even
    ///   if the state value itself is unchanged, so a surface's source can flip from `.inferred`
    ///   back to `.hooks` the instant a hook speaks.
    /// - `source == .inferred` only writes if the surface's currently recorded source is `nil`
    ///   (never reported) or already `.inferred`. If it's `.hooks`, the write is silently
    ///   dropped — belt-and-suspenders: the screen-manifest engine's Phase A should already skip
    ///   sampling a hooks-owned surface, but this is the authoritative guard regardless.
    /// - `source == .program` (OSC 7501) always writes, and `programState` carries the root
    ///   record's finer state. While the current presence is `.program`, `.hooks`/`.inferred`
    ///   writes are dropped if its state is active (working/blocked), and, if it is resting
    ///   (idle/done/error), accepted only when they report an active state. Accepting only active
    ///   claims keeps a hook `idle` from overwriting a program `done` badge.
    ///
    /// Event routes read `AgentPresence.route` instead, updated by the same rules from trusted
    /// reports only: hooks, and `.program` with `programVerified` (the report carried the
    /// surface's token). An unsigned program report can own the badge but never the route view,
    /// so routes get their own frames: one per route-view change, carrying that view's previous
    /// state and the report's writer. A panel no trusted reporter has spoken for yet hands routes
    /// its displayed changes, without a writer and untrusted, so `run` and `review` routes skip
    /// them.
    ///
    /// `promptKind` is what a `blocked` report is waiting on (nil when the reporter did not say).
    /// It goes only to the surface's person-input gate, which refuses socket writes while a
    /// permission or sign-in prompt shows (TerminalSurface+DraftGate.swift). Any `blocked` report
    /// arms that gate; an unsigned program report never closes it (`notePromptGate`).
    func updatePanelAgentState(
        panelId: UUID,
        state: AgentActivityState,
        source: AgentStateSource = .hooks,
        sessionKey: AgentSessionKey? = nil,
        transcriptPath: String? = nil,
        inferredAgent: String? = nil,
        programState: ProgramStatusState? = nil,
        promptKind: ProgramStatusKind? = nil,
        programVerified: Bool = false,
        at now: Date = Date()
    ) {
        let current = panelAgentPresence[panelId]

        // Before the precedence guards: which tier owns the badge says nothing about which
        // session runs in the panel, and Programa's own hooks emit OSC 7501 ahead of this report.
        if source == .hooks, let sessionKey, let sessionId = sessionKey.sessionId {
            AgentResumeStore.shared.note(
                panelId: panelId, provider: sessionKey.provider, sessionId: sessionId, cwd: panelDirectories[panelId],
                transcriptPath: transcriptPath
            )
        }
        if source == .hooks, let sessionKey {
            if interruptedAgentPanels[panelId] != nil {
                interruptedAgentPanels.removeValue(forKey: panelId)
            }
            if let pid = sessionKey.pid, sessionKey.provider == "claude-code" || sessionKey.provider == "claude" {
                LeftoverProcessReaper.shared.trackAgent(pid: pid)
            }
        }

        let movedRoute = Self.nextRoute(
            after: current?.route, state: state, source: source, sessionKey: sessionKey, programVerified: programVerified
        )
        let routeChanged = movedRoute != nil && movedRoute != current?.route
        let route = routeChanged ? movedRoute : current?.route
        let publishRoute = {
            guard routeChanged, let route else { return }
            self.publishRouteAgentState(panelId: panelId, route: route, previous: current?.route?.state, sessionKey: sessionKey)
        }

        let reporter = Self.promptReporter(source: source, programVerified: programVerified)

        if Self.programHolds(currentSource: current?.source, currentState: current?.state, against: source, state)
            || (source == .inferred && current?.source == .hooks) {
            // Hooks always win over inference: dropped write must not move lastEventAt either, so
            // a hooks-owned surface's staleness clock keeps ticking from its last real hook
            // event, not from an inferred sample that never took effect.
            if routeChanged { panelAgentPresence[panelId]?.route = route }
            notePromptGate(panelId: panelId, state: state, promptKind: promptKind, reporter: reporter)
            publishRoute()
            return
        }

        // `.inferred` writes never carry a session key -- there is no session to key on.
        // A hook report that omits its session key (agent.event without pid, an older CLI)
        // keeps the key an earlier report established, so the liveness sweep never loses
        // the pid it needs to clear this surface when the process dies.
        let resolvedSessionKey: AgentSessionKey?
        if source != .hooks {
            resolvedSessionKey = nil
        } else {
            resolvedSessionKey = sessionKey ?? current?.sessionKey
        }

        let resolvedInferredAgent = source == .inferred ? inferredAgent : nil

        guard current?.state != state || current?.source != source || current?.sessionKey != resolvedSessionKey
                || current?.inferredAgent != resolvedInferredAgent
                || current?.programState != programState else {
            // Same state from the same writer: only the liveness clock moves. Without this a
            // long-running agent that keeps reporting `working` would read as stale at the
            // threshold. No wait-registry or socket fan-out, since nothing observable changed.
            panelAgentPresence[panelId]?.lastEventAt = now
            panelAgentPresence[panelId]?.staleObserved = false
            if routeChanged { panelAgentPresence[panelId]?.route = route }
            // A repeated `blocked` report (a second permission request in one turn) re-arms a
            // prompt the person already answered with a key.
            notePromptGate(panelId: panelId, state: state, promptKind: promptKind, reporter: reporter)
            publishRoute()
            return
        }
        panelAgentPresence[panelId] = AgentPresence(
            state: state,
            source: source,
            lastEventAt: now,
            sessionKey: resolvedSessionKey,
            inferredAgent: resolvedInferredAgent,
            programState: programState,
            route: route
        )
        notePromptGate(panelId: panelId, state: state, promptKind: promptKind, reporter: reporter)
        noteReviewNudgeTurnEdge(panelId: panelId, previous: current?.state, next: state)
        // Event-driven half of surface.wait's `agent_state` condition (#166 task 2) and
        // agent.prompt's internal working/idle watch (#166 task 3) -- see
        // AgentStateWaitRegistry's doc comment in TerminalController+SurfaceWait.swift for why
        // this is the single safe place to fire from.
        AgentStateWaitRegistry.shared.notify(surfaceId: panelId, newState: state, source: source)
        SocketEventBroadcaster.shared.publishAgentState(
            workspaceId: id,
            surfaceId: panelId,
            state: state,
            previousState: current?.state,
            source: source,
            writer: nil,
            programStatus: source == .program
                ? (panels[panelId] as? TerminalPanel)?.programStatus.root?.wirePayload
                : nil,
            toRoutes: route == nil,
            trusted: reporter == .agent
        )
        publishRoute()
#if DEBUG
        dlog(
            "surface.agentState workspace=\(id.uuidString.prefix(5)) " +
            "panel=\(panelId.uuidString.prefix(5)) state=\(state.rawValue) source=\(source.rawValue)"
        )
#endif
    }

    /// Clears a surface's agent presence. A `.program` clear removes only program-owned presence;
    /// a hooks/inferred clear is ignored while the presence is program-owned. `force` removes the
    /// presence whoever owns it (permanent panel close).
    ///
    /// A `.program` clear ends a showing prompt only for a signed `state=clear`, or for a prompt
    /// mark once the shell reported its prompt over the socket since the prompt armed. An unsigned
    /// clear, a mark alone and a terminal reset leave the prompt gate armed and keep a trusted
    /// route view, which the badge then shows; without one they drop the presence.
    func clearPanelAgentState(
        panelId: UUID, source: AgentStateSource = .hooks, force: Bool = false,
        programClear: ProgramRootClear = .unsigned
    ) {
        let closer: PromptReporter?
        if force || source == .hooks || programClear == .signed
            || (programClear == .shellPrompt && panelsShellReturnedSincePromptArmed.contains(panelId)) {
            closer = .agent
        } else {
            closer = source == .inferred ? .screen : nil
        }
        guard let current = panelAgentPresence[panelId] else {
            closePromptGate(panelId: panelId, by: closer)
            return
        }
        // A clear printed bytes can cause (an unsigned clear, a prompt mark the shell did not
        // report, a reset, screen detection losing its match) drops its own tier's badge but never
        // what a trusted reporter said (INC-1147).
        let printedClear = closer != .agent
        let ownsClear = { (owner: AgentStateSource) in force || (source == .program) == (owner == .program) }
        guard ownsClear(current.source) else {
            // The badge stays, but a clear from the route view's own tier still ends it.
            guard let route = current.route, ownsClear(route.source), !printedClear else {
                closePromptGate(panelId: panelId, by: closer)
                return
            }
            panelAgentPresence[panelId]?.route = nil
            closePromptGate(panelId: panelId, by: closer)
            SocketEventBroadcaster.shared.publishAgentState(
                workspaceId: id, surfaceId: panelId, state: nil, previousState: route.state, source: nil,
                toSubscribers: false, trusted: true
            )
            return
        }
        if printedClear, let route = current.route {
            // The badge falls back to the route view; routes see no change.
            panelAgentPresence[panelId] = AgentPresence(
                state: route.state, source: route.source, lastEventAt: Date(), sessionKey: route.sessionKey, route: route
            )
            AgentStateWaitRegistry.shared.notify(surfaceId: panelId, newState: route.state, source: route.source)
            SocketEventBroadcaster.shared.publishAgentState(
                workspaceId: id, surfaceId: panelId, state: route.state, previousState: current.state,
                source: route.source, writer: nil, programStatus: nil, toRoutes: false, trusted: false
            )
            return
        }
        panelAgentPresence.removeValue(forKey: panelId)
        closePromptGate(panelId: panelId, by: closer)
        AgentStateWaitRegistry.shared.notify(surfaceId: panelId, newState: nil, source: nil)
        // Routes see the clear too: a held delivery ends rather than outliving the agent. It
        // fires `run` and `review` only when both the clear and the agent it ends came from a
        // trusted reporter: a printed `working` that the shell's own prompt report then clears is
        // still printed.
        SocketEventBroadcaster.shared.publishAgentState(
            workspaceId: id, surfaceId: panelId, state: nil, previousState: current.route?.state ?? current.state,
            source: nil, trusted: !printedClear && current.hasTrustedOrigin
        )
#if DEBUG
        dlog("surface.agentState.clear workspace=\(id.uuidString.prefix(5)) panel=\(panelId.uuidString.prefix(5))")
#endif
    }

    /// Moves only the route view (`AgentPresence.route`), for a trusted report that must not drive
    /// the badge: a signed OSC 7501 report the drain applied before a later unsigned one in the
    /// same batch, or Claude Code's PostToolUse hook while Claude reports its own status. Without a
    /// presence it only arms the prompt gate on `blocked`: the route view lives with the presence,
    /// so routes miss the report and fail closed.
    ///
    /// It leaves a blocked route view alone unless `resumesBlocked`: only a report that proves the
    /// person answered the prompt may end a stop for input (a hook that runs after the tool, not
    /// an async one that can land after the next prompt went up).
    func updatePanelRouteAgentState(
        panelId: UUID,
        state: AgentActivityState,
        source: AgentStateSource,
        sessionKey: AgentSessionKey? = nil,
        programVerified: Bool = false,
        resumesBlocked: Bool = false,
        promptKind: ProgramStatusKind? = nil
    ) {
        let reporter = Self.promptReporter(source: source, programVerified: programVerified)
        // Arms even without a presence: a signed `blocked` early in a batch reaches only this call.
        if state == .blocked {
            notePromptGate(panelId: panelId, state: state, promptKind: promptKind, reporter: reporter)
        }
        guard let current = panelAgentPresence[panelId] else { return }
        let moved = resumesBlocked || current.route?.state != .blocked
            ? Self.nextRoute(
                after: current.route, state: state, source: source, sessionKey: sessionKey, programVerified: programVerified
            )
            : nil
        let route = moved.flatMap { $0 == current.route ? nil : $0 }
        if let route { panelAgentPresence[panelId]?.route = route }
        // A resume re-checks the prompt even when the route view already showed `working`.
        if resumesBlocked, state != .blocked {
            closePromptGate(panelId: panelId, by: reporter)
        }
        guard let route else { return }
        publishRouteAgentState(panelId: panelId, route: route, previous: current.route?.state, sessionKey: sessionKey)
    }

    /// The route view after a report, or nil when the report does not move it: it comes from an
    /// untrusted reporter, or a signed program holds the view against it.
    private static func nextRoute(
        after current: RouteAgentPresence?,
        state: AgentActivityState,
        source: AgentStateSource,
        sessionKey: AgentSessionKey?,
        programVerified: Bool
    ) -> RouteAgentPresence? {
        guard source == .hooks || (source == .program && programVerified),
              !programHolds(currentSource: current?.source, currentState: current?.state, against: source, state)
        else { return nil }
        return RouteAgentPresence(
            state: state,
            source: source,
            sessionKey: source == .hooks ? sessionKey ?? (current?.source == .hooks ? current?.sessionKey : nil) : nil
        )
    }

    /// One frame for routes only. The writer comes from the report's own session key, never the
    /// view's resolved one (`RouteEvent.writer`).
    private func publishRouteAgentState(
        panelId: UUID,
        route: RouteAgentPresence,
        previous: AgentActivityState?,
        sessionKey: AgentSessionKey?
    ) {
        SocketEventBroadcaster.shared.publishAgentState(
            workspaceId: id,
            surfaceId: panelId,
            state: route.state,
            previousState: previous,
            source: route.source,
            writer: RouteEvent.writer(source: route.source, sessionKey: sessionKey, programVerified: route.source == .program),
            programStatus: route.source == .program
                ? (panels[panelId] as? TerminalPanel)?.programStatus.root?.wirePayload
                : nil,
            toSubscribers: false,
            trusted: true
        )
    }

    /// Who a report counts as for the prompt gate: nil for an unsigned program report, which
    /// printed bytes can forge.
    private static func promptReporter(source: AgentStateSource, programVerified: Bool) -> PromptReporter? {
        switch source {
        case .inferred: return .screen
        case .hooks: return .agent
        case .program: return programVerified ? .agent : nil
        }
    }

    /// The prompt gate's side of a report, applied after the report moved the presence. Any
    /// `blocked` report arms it, whichever tier sent it and whether or not it reached the badge.
    private func notePromptGate(
        panelId: UUID, state: AgentActivityState, promptKind: ProgramStatusKind?, reporter: PromptReporter?
    ) {
        if state == .blocked {
            panelsShellReturnedSincePromptArmed.remove(panelId)
            (panels[panelId] as? TerminalPanel)?.surface.noteAgentPrompt(promptKind, isBlocked: true, by: reporter ?? .agent)
        } else {
            closePromptGate(panelId: panelId, by: reporter)
        }
    }

    /// Closes a showing prompt for `closer`: never for nil (printed bytes), for `.screen` only a
    /// prompt screen detection alone reported, and only while no trusted view is `blocked`. A
    /// program-owned `blocked` badge never holds it: an unsigned one is forgeable, and a signed
    /// one also shows in the route view.
    private func closePromptGate(panelId: UUID, by closer: PromptReporter?) {
        let presence = panelAgentPresence[panelId]
        guard let closer,
              let surface = (panels[panelId] as? TerminalPanel)?.surface, let reporter = surface.promptReporter,
              closer == .agent || reporter == .screen,
              presence?.route?.state != .blocked,
              !(presence?.state == .blocked && presence?.source != .program) else { return }
        surface.noteAgentPrompt(nil, isBlocked: false)
    }

    /// Whether a program presence in `currentState` keeps a report from another tier: always
    /// while it is active, and while it rests unless the report claims an active state.
    private static func programHolds(
        currentSource: AgentStateSource?,
        currentState: AgentActivityState?,
        against source: AgentStateSource,
        _ state: AgentActivityState
    ) -> Bool {
        guard source != .program, currentSource == .program, let currentState else { return false }
        return currentState != .idle || state == .idle
    }

    // MARK: - Review nudge

    /// An agent turn ending (working/blocked -> idle, from hooks, OSC 7501 or screen inference)
    /// probes the surface's repo once and nudges only if its change fingerprint moved since the
    /// turn started; a new turn (-> working) drops that surface's nudge and records the baseline.
    /// Never opens or focuses anything: the sidebar only offers the review.
    func noteReviewNudgeTurnEdge(panelId: UUID, previous: AgentActivityState?, next: AgentActivityState) {
        if next == .working, previous == .blocked {
            // Same turn resuming after a prompt: keep its baseline (and any baseline probe in flight).
            if panelReviewNudges[panelId] != nil {
                switch reviewTurns[panelId] {
                case .settling(let token, let directory, let baseline, _):
                    reviewTurns[panelId] = .settling(token: token, directory: directory, baseline: baseline, nudge: nil)
                case .settled(let baseline, _):
                    reviewTurns[panelId] = .settled(baseline: baseline, nudge: nil)
                default: break
                }
            }
        } else if next == .working, previous != .working {
            saveTurnCheckpoint(panelId: panelId)
            clearReviewNudge(panelId: panelId)
            runReviewNudgeProbe(panelId: panelId, kind: .baseline)
        } else if next == .idle, previous == .working || previous == .blocked {
            runReviewNudgeProbe(panelId: panelId, kind: .turnEnd(baseline: reviewTurns[panelId]?.baseline))
        }
    }

    /// Snapshots the surface's repo files at turn start so the review panel can revert the turn.
    /// Runs whether or not a review panel is open, unlike the nudge probe.
    private func saveTurnCheckpoint(panelId: UUID) {
        guard let directory = sidebarResolvedDirectory(for: panelId) else { return }
        reviewCheckpointDirectories.insert(directory)
        let workspaceId = id
        ReviewCheckpointStore.queue.async {
            ReviewCheckpointStore.save(directory: directory, workspaceId: workspaceId, surfaceId: panelId)
        }
    }

    func clearReviewNudge(panelId: UUID) {
        reviewTurns.removeValue(forKey: panelId)
    }

    /// Opening any review panel covers the workspace's diff, so every nudge in it goes.
    func clearAllReviewNudges() {
        reviewTurns.removeAll()
    }

    private enum ReviewNudgeProbeKind: Sendable {
        case baseline
        /// `baseline == nil` (its probe failed, was superseded, or the turn began before the app
        /// saw it) nudges on any non-empty diff.
        case turnEnd(baseline: ReviewChangeFingerprint?)
    }

    private func runReviewNudgeProbe(panelId: UUID, kind: ReviewNudgeProbeKind) {
        // An open review panel already refreshes itself on these same edges.
        guard !panels.values.contains(where: { $0 is ReviewPanel }),
              let directory = sidebarResolvedDirectory(for: panelId) else {
            return
        }
        let token = UUID()
        switch kind {
        case .baseline:
            reviewTurns[panelId] = .capturingBaseline(token: token, directory: directory)
        case .turnEnd(let baseline):
            reviewTurns[panelId] = .settling(
                token: token, directory: directory, baseline: baseline, nudge: reviewTurns[panelId]?.nudge
            )
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let fingerprint = ReviewDiffProber.uncommittedChangeFingerprint(directory: directory)
            DispatchQueue.main.async {
                guard let self,
                      self.reviewTurns[panelId]?.probeToken == token,
                      self.panels[panelId] != nil,
                      self.sidebarResolvedDirectory(for: panelId) == directory else { return }
                guard let fingerprint else {
                    switch kind {
                    case .baseline: self.reviewTurns[panelId] = .working(baseline: nil)
                    case .turnEnd(let baseline):
                        self.reviewTurns[panelId] = .settled(baseline: baseline, nudge: self.reviewTurns[panelId]?.nudge)
                    }
                    return
                }
                switch kind {
                case .baseline:
                    self.reviewTurns[panelId] = .working(baseline: fingerprint)
                case .turnEnd(let baseline):
                    self.reviewNudgeTurnEndsSettled &+= 1
                    let changed = baseline.map { fingerprint.differs(from: $0) } ?? true
                    let count = changed ? fingerprint.paths.count : 0
                    self.reviewTurns[panelId] = .settled(baseline: baseline, nudge: count > 0 ? count : nil)
#if DEBUG
                    dlog(
                        "review.nudge workspace=\(self.id.uuidString.prefix(5)) " +
                        "panel=\(panelId.uuidString.prefix(5)) files=\(fingerprint.paths.count) " +
                        "baseline=\(baseline.map { String($0.paths.count) } ?? "none") nudge=\(count)"
                    )
#endif
                }
            }
        }
    }

    /// The surface the sidebar's review affordance targets: the largest diff, ties broken by id
    /// so the row does not flip between equal surfaces.
    var reviewNudgeTarget: (panelId: UUID, fileCount: Int)? {
        panelReviewNudges
            .max { lhs, rhs in
                lhs.value != rhs.value ? lhs.value < rhs.value : lhs.key.uuidString > rhs.key.uuidString
            }
            .map { (panelId: $0.key, fileCount: $0.value) }
    }

    /// User-initiated (sidebar click): opens and focuses a review split beside the agent surface.
    @discardableResult
    func openReviewFromNudge(panelId: UUID) -> ReviewPanel? {
        let sourcePanelId = panels[panelId] != nil ? panelId : focusedPanelId
        guard let sourcePanelId else {
            clearAllReviewNudges()
            return nil
        }
        return newReviewSplit(from: sourcePanelId, orientation: .horizontal, focus: true)
    }

    func resetSidebarContext(
        reason: String = "unspecified",
        portScanner: PortScanner = .shared
    ) {
        statusEntries.removeAll()
        agentPIDs.removeAll()
        portScanner.refreshAgentPorts(workspaceId: id, agentPIDs: [])
        agentListeningPorts.removeAll()
        logEntries.removeAll()
        progress = nil
        gitBranch = nil
        let panelIdsWithAutomaticTitles = Set(panelGitBranches.keys).union(panelPullRequests.keys)
        panelGitBranches.removeAll()
        pullRequest = nil
        panelPullRequests.removeAll()
        for panelId in panelIdsWithAutomaticTitles {
            syncResolvedPanelTitle(panelId: panelId)
        }
        // Clears bypass updatePanelAgentState/clearPanelAgentState's per-surface notify, so fan
        // it out here too -- otherwise a surface.wait `agent_state` (or a subscribed client)
        // watching a surface whose state got wiped by a sidebar reset would hang until timeout
        // instead of observing the transition to "no state".
        for (panelId, panel) in panels {
            if (panel as? TerminalPanel)?.programStatus.resetAll() == true {
                ProgramStateWaitRegistry.shared.notify(surfaceId: panelId, newState: nil)
            }
        }
        let clearedPresences = panelAgentPresence
        // A showing permission or sign-in prompt stays armed: any client can reset the sidebar,
        // and the box is still on screen. The person's key, an `answer_prompt` write or the
        // agent's next trusted report ends it.
        for (panelId, presence) in panelAgentPresence where presence.state == .blocked {
            guard let surface = (panels[panelId] as? TerminalPanel)?.surface,
                  surface.activePromptHold() == nil else { continue }
            surface.noteAgentPrompt(nil, isBlocked: false)
        }
        panelAgentPresence.removeAll()
        for (surfaceId, presence) in clearedPresences {
            AgentStateWaitRegistry.shared.notify(surfaceId: surfaceId, newState: nil, source: nil)
            SocketEventBroadcaster.shared.publishAgentState(
                workspaceId: id, surfaceId: surfaceId, state: nil, previousState: presence.route?.state ?? presence.state,
                source: nil, trusted: presence.hasTrustedOrigin
            )
        }
        surfaceListeningPorts.removeAll()
        listeningPorts.removeAll()
        metadataBlocks.removeAll()
        clearAllReviewNudges()
    }

    @discardableResult
    func updatePanelTitle(panelId: UUID, title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if panelsHoldingRestoredTitle.contains(panelId) {
            if Self.isTerminalStartupTitle(trimmed) { return false }
            panelsHoldingRestoredTitle.remove(panelId)
        }
        var didMutate = false

        if panelTitles[panelId] != trimmed {
            panelTitles[panelId] = trimmed
            didMutate = true
        }
        panelsWithLiveTitle.insert(panelId)

        // Update bonsplit tab title only when this panel's title changed.
        if didMutate {
            syncResolvedPanelTitle(panelId: panelId)
        }

        // The focused pane titles the workspace (tmux-style). Single-panel
        // workspaces have no focus ambiguity; in splits, only the focused
        // pane's title propagates so two panes never fight over the sidebar.
        if panels.count == 1 || panelId == focusedPanelId {
            let previousTitle = self.title
            processTitle = trimmed
            refreshResolvedWorkspaceTitle()
            if self.title != previousTitle { didMutate = true }
        }

        return didMutate
    }

    /// Titles a terminal shows before it has anything of its own to say: a shell's cwd
    /// (`/path`, `~/path`, `user@host: ~/path`), the `AgentResumeCommand` line being run, and
    /// an agent's banner before its session has a topic.
    static func isTerminalStartupTitle(_ title: String) -> Bool {
        var text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = text.range(of: #"^[^\s@:]+@[^\s:]+:\s*"#, options: .regularExpression) {
            text.removeSubrange(range)
        }
        if text.hasPrefix("/") || text.hasPrefix("~") { return true }
        if text.range(of: #"(^|&& )(claude --resume|codex resume|opencode --session) "#, options: .regularExpression) != nil {
            return true
        }
        let banner = text.drop { !$0.isLetter && !$0.isNumber }
        return banner.caseInsensitiveCompare("Claude Code") == .orderedSame
    }

    /// Re-derive the workspace title from the focused panel's last known
    /// title. Called on pane-focus changes so the sidebar follows the active
    /// pane without waiting for it to emit a new OSC title. Only titles that
    /// arrived through a real update qualify; creation-time displayTitle
    /// seeds must not overwrite the workspace's default title.
    func refreshWorkspaceTitleFromFocusedPanel() {
        guard let panelId = focusedPanelId,
              panelsWithLiveTitle.contains(panelId),
              let stored = panelTitles[panelId] else { return }
        if processTitle != stored { processTitle = stored }
        refreshResolvedWorkspaceTitle()
    }

    func pruneSurfaceMetadata(validSurfaceIds: Set<UUID>) {
        if panelDirectories.keys.contains(where: { !validSurfaceIds.contains($0) }) {
            panelDirectories = panelDirectories.filter { validSurfaceIds.contains($0.key) }
        }
        if resolvedPanelDirectories.keys.contains(where: { !validSurfaceIds.contains($0) }) {
            resolvedPanelDirectories = resolvedPanelDirectories.filter { validSurfaceIds.contains($0.key) }
        }
        if panelTitles.keys.contains(where: { !validSurfaceIds.contains($0) }) {
            panelTitles = panelTitles.filter { validSurfaceIds.contains($0.key) }
        }
        if panelsWithLiveTitle.contains(where: { !validSurfaceIds.contains($0) }) {
            panelsWithLiveTitle = panelsWithLiveTitle.filter { validSurfaceIds.contains($0) }
            panelsHoldingRestoredTitle = panelsHoldingRestoredTitle.filter { validSurfaceIds.contains($0) }
        }
        if panelCustomTitles.keys.contains(where: { !validSurfaceIds.contains($0) }) {
            panelCustomTitles = panelCustomTitles.filter { validSurfaceIds.contains($0.key) }
        }
        if pinnedPanelIds.contains(where: { !validSurfaceIds.contains($0) }) {
            pinnedPanelIds = pinnedPanelIds.filter { validSurfaceIds.contains($0) }
        }
        if panelColorHexes.keys.contains(where: { !validSurfaceIds.contains($0) }) {
            panelColorHexes = panelColorHexes.filter { validSurfaceIds.contains($0.key) }
        }
        if manualUnreadPanelIds.contains(where: { !validSurfaceIds.contains($0) }) {
            manualUnreadPanelIds = manualUnreadPanelIds.filter { validSurfaceIds.contains($0) }
        }
        if panelGitBranches.keys.contains(where: { !validSurfaceIds.contains($0) }) {
            panelGitBranches = panelGitBranches.filter { validSurfaceIds.contains($0.key) }
        }
        if manualUnreadMarkedAt.keys.contains(where: { !validSurfaceIds.contains($0) }) {
            manualUnreadMarkedAt = manualUnreadMarkedAt.filter { validSurfaceIds.contains($0.key) }
        }
        if reviewTurns.keys.contains(where: { !validSurfaceIds.contains($0) }) {
            reviewTurns = reviewTurns.filter { validSurfaceIds.contains($0.key) }
        }
        let didPruneListeningPorts = surfaceListeningPorts.keys.contains(where: {
            !validSurfaceIds.contains($0)
        })
        if didPruneListeningPorts {
            surfaceListeningPorts = surfaceListeningPorts.filter { validSurfaceIds.contains($0.key) }
        }
        let didPruneTTYNames = surfaceTTYNames.keys.contains(where: {
            !validSurfaceIds.contains($0)
        })
        if didPruneTTYNames {
            surfaceTTYNames = surfaceTTYNames.filter { validSurfaceIds.contains($0.key) }
        }
        if panelShellActivityStates.keys.contains(where: { !validSurfaceIds.contains($0) }) {
            panelShellActivityStates = panelShellActivityStates.filter { validSurfaceIds.contains($0.key) }
        }
        panelsShellReturnedSincePromptArmed.formIntersection(validSurfaceIds)
        if panelPullRequests.keys.contains(where: { !validSurfaceIds.contains($0) }) {
            panelPullRequests = panelPullRequests.filter { validSurfaceIds.contains($0.key) }
        }
        // Through clearPanelAgentState so surface.wait waiters and subscribers see the removal.
        for panelId in panelAgentPresence.keys where !validSurfaceIds.contains(panelId) {
            clearPanelAgentState(panelId: panelId)
        }
        if didPruneListeningPorts {
            recomputeListeningPorts()
        }
    }

    func recomputeListeningPorts() {
        let unique = Set(surfaceListeningPorts.values.flatMap { $0 })
            .union(agentListeningPorts)
        let next = unique.sorted()
        if listeningPorts != next {
            listeningPorts = next
        }
    }

    func sidebarOrderedPanelIds() -> [UUID] {
        let paneTabs: [String: [UUID]] = Dictionary(
            uniqueKeysWithValues: bonsplitController.allPaneIds.map { paneId in
                let panelIds = bonsplitController
                    .tabs(inPane: paneId)
                    .compactMap { panelIdFromSurfaceId($0.id) }
                return (paneId.id.uuidString, panelIds)
            }
        )

        let fallbackPanelIds = panels.keys.sorted { $0.uuidString < $1.uuidString }
        let tree = bonsplitController.treeSnapshot()
        return SidebarBranchOrdering.orderedPanelIds(
            tree: tree,
            paneTabs: paneTabs,
            fallbackPanelIds: fallbackPanelIds
        )
    }

    func normalizedSidebarDirectory(_ directory: String?) -> String? {
        guard let directory else { return nil }
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              SidebarTelemetryLimits.utf8ByteCount(trimmed) <= SidebarTelemetryLimits.maxDirectoryBytes else {
            return nil
        }
        return trimmed
    }

    func normalizedBoundedSidebarBranchName(_ branch: String?) -> String? {
        guard let normalized = normalizedSidebarBranchName(branch),
              SidebarTelemetryLimits.utf8ByteCount(normalized) <= SidebarTelemetryLimits.maxGitBranchBytes else {
            return nil
        }
        return normalized
    }

    func normalizedSidebarTTYName(_ ttyName: String?) -> String? {
        guard let ttyName else { return nil }
        let trimmed = ttyName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              SidebarTelemetryLimits.utf8ByteCount(trimmed) <= SidebarTelemetryLimits.maxTTYNameBytes else {
            return nil
        }
        return trimmed
    }

    func sidebarHomeDirectoryForCanonicalization(
        resolvedPanelDirectories: [UUID: String]
    ) -> String? {
        FileManager.default.homeDirectoryForCurrentUser.path
    }

    func sidebarResolvedDirectory(for panelId: UUID) -> String? {
        if let directory = normalizedSidebarDirectory(panelDirectories[panelId]) {
            return directory
        }
        if let requestedDirectory = normalizedSidebarDirectory(
            terminalPanel(for: panelId)?.requestedWorkingDirectory
        ) {
            return requestedDirectory
        }
        guard panelId == focusedPanelId else { return nil }
        return normalizedSidebarDirectory(currentDirectory)
    }

    func sidebarResolvedPanelDirectories(orderedPanelIds: [UUID]) -> [UUID: String] {
        var resolved: [UUID: String] = [:]
        for panelId in orderedPanelIds {
            if let directory = sidebarResolvedDirectory(for: panelId) {
                resolved[panelId] = directory
            }
        }
        return resolved
    }

    func sidebarGitBranchesInDisplayOrder(orderedPanelIds: [UUID]) -> [SidebarGitBranchState] {
        SidebarBranchOrdering
            .orderedUniqueBranches(
                orderedPanelIds: orderedPanelIds,
                panelBranches: panelGitBranches,
                fallbackBranch: gitBranch
            )
            .map { SidebarGitBranchState(branch: $0.name, isDirty: $0.isDirty) }
    }

    func sidebarGitBranchesInDisplayOrder() -> [SidebarGitBranchState] {
        sidebarGitBranchesInDisplayOrder(orderedPanelIds: sidebarOrderedPanelIds())
    }

    func sidebarBranchDirectoryEntriesInDisplayOrder(
        orderedPanelIds: [UUID]
    ) -> [SidebarBranchOrdering.BranchDirectoryEntry] {
        let resolvedDirectories = sidebarResolvedPanelDirectories(orderedPanelIds: orderedPanelIds)
        return SidebarBranchOrdering.orderedUniqueBranchDirectoryEntries(
            orderedPanelIds: orderedPanelIds,
            panelBranches: panelGitBranches,
            panelDirectories: resolvedDirectories,
            defaultDirectory: normalizedSidebarDirectory(currentDirectory),
            homeDirectoryForTildeExpansion: sidebarHomeDirectoryForCanonicalization(
                resolvedPanelDirectories: resolvedDirectories
            ),
            fallbackBranch: gitBranch
        )
    }

    func sidebarBranchDirectoryEntriesInDisplayOrder() -> [SidebarBranchOrdering.BranchDirectoryEntry] {
        sidebarBranchDirectoryEntriesInDisplayOrder(orderedPanelIds: sidebarOrderedPanelIds())
    }

    func sidebarPullRequestsInDisplayOrder(orderedPanelIds: [UUID]) -> [SidebarPullRequestState] {
        let validPanelPullRequests = panelPullRequests.filter { panelId, state in
            guard let pullRequestBranch = normalizedSidebarBranchName(state.branch) else {
                return true
            }
            return normalizedSidebarBranchName(panelGitBranches[panelId]?.branch) == pullRequestBranch
        }
        return SidebarBranchOrdering.orderedUniquePullRequests(
            orderedPanelIds: orderedPanelIds,
            panelPullRequests: validPanelPullRequests,
            fallbackPullRequest: nil
        )
    }

    func sidebarPullRequestsInDisplayOrder() -> [SidebarPullRequestState] {
        sidebarPullRequestsInDisplayOrder(orderedPanelIds: sidebarOrderedPanelIds())
    }

    func sidebarStatusEntriesInDisplayOrder() -> [SidebarStatusEntry] {
        statusEntries.values.sorted { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp > rhs.timestamp }
            return lhs.key < rhs.key
        }
    }

    func sidebarMetadataBlocksInDisplayOrder() -> [SidebarMetadataBlock] {
        metadataBlocks.values.sorted { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp > rhs.timestamp }
            return lhs.key < rhs.key
        }
    }

    @discardableResult
    func setSidebarStatusEntry(_ entry: SidebarStatusEntry) -> (inserted: Bool, evictedAgentPID: Bool) {
        guard SidebarTelemetryLimits.utf8ByteCount(entry.key) <= SidebarTelemetryLimits.maxKeyBytes,
              SidebarTelemetryLimits.utf8ByteCount(entry.value) <= SidebarTelemetryLimits.maxStatusValueBytes,
              SidebarTelemetryLimits.isWithinUTF8Limit(entry.icon, maxBytes: SidebarTelemetryLimits.maxStatusIconBytes),
              SidebarTelemetryLimits.isWithinUTF8Limit(entry.color, maxBytes: SidebarTelemetryLimits.maxStatusColorBytes),
              SidebarTelemetryLimits.isWithinUTF8Limit(
                  entry.url?.absoluteString,
                  maxBytes: SidebarTelemetryLimits.maxStatusURLBytes
              ) else {
            return (false, false)
        }
        var evictedAgentPID = false
        while statusEntries[entry.key] == nil,
              statusEntries.count >= SidebarTelemetryLimits.maxStatusEntries,
              let oldestKey = statusEntries.min(by: { lhs, rhs in
                  if lhs.value.timestamp != rhs.value.timestamp {
                      return lhs.value.timestamp < rhs.value.timestamp
                  }
                  return lhs.key < rhs.key
              })?.key {
            statusEntries.removeValue(forKey: oldestKey)
            if agentPIDs.removeValue(forKey: oldestKey) != nil {
                evictedAgentPID = true
            }
        }
        statusEntries[entry.key] = entry
        return (true, evictedAgentPID)
    }

    @discardableResult
    func setSidebarProgress(value: Double, label: String?) -> Bool {
        guard value.isFinite,
              (0.0...1.0).contains(value),
              SidebarTelemetryLimits.isWithinUTF8Limit(
                  label,
                  maxBytes: SidebarTelemetryLimits.maxProgressLabelBytes
              ) else {
            return false
        }
        progress = SidebarProgressState(value: value, label: label)
        return true
    }

    @discardableResult
    func setSidebarAgentPID(key: String, pid: pid_t) -> Bool {
        guard SidebarTelemetryLimits.utf8ByteCount(key) <= SidebarTelemetryLimits.maxKeyBytes,
              pid > 0,
              agentPIDs[key] != nil || agentPIDs.count < SidebarTelemetryLimits.maxAgentPIDs else {
            return false
        }
        agentPIDs[key] = pid
        // SessionStart reports Claude's pid here; per-surface presence only gets it on a tool call.
        if key == "claude_code" {
            LeftoverProcessReaper.shared.trackAgent(pid: pid)
        }
        return true
    }

    @discardableResult
    func setSidebarTTYName(panelId: UUID, ttyName: String) -> Bool {
        guard let normalized = normalizedSidebarTTYName(ttyName) else { return false }
        surfaceTTYNames[panelId] = normalized
        return true
    }

    @discardableResult
    func setSidebarMetadataBlock(_ block: SidebarMetadataBlock) -> Bool {
        guard SidebarTelemetryLimits.utf8ByteCount(block.key) <= SidebarTelemetryLimits.maxKeyBytes,
              SidebarTelemetryLimits.utf8ByteCount(block.markdown) <= SidebarTelemetryLimits.maxMetadataMarkdownBytes else {
            return false
        }
        while metadataBlocks[block.key] == nil,
              metadataBlocks.count >= SidebarTelemetryLimits.maxMetadataBlocks,
              let oldestKey = metadataBlocks.min(by: { lhs, rhs in
                  if lhs.value.timestamp != rhs.value.timestamp {
                      return lhs.value.timestamp < rhs.value.timestamp
                  }
                  return lhs.key < rhs.key
              })?.key {
            metadataBlocks.removeValue(forKey: oldestKey)
        }
        metadataBlocks[block.key] = block
        return true
    }

    @discardableResult
    func appendSidebarLogEntry(_ entry: SidebarLogEntry) -> Bool {
        guard !entry.message.isEmpty,
              SidebarTelemetryLimits.utf8ByteCount(entry.message) <= SidebarTelemetryLimits.maxLogMessageBytes,
              SidebarTelemetryLimits.isWithinUTF8Limit(
                  entry.source,
                  maxBytes: SidebarTelemetryLimits.maxLogSourceBytes
              ) else {
            return false
        }
        logEntries.append(entry)
        let limit = SidebarTelemetryLimits.configuredMaxLogEntries()
        if logEntries.count > limit {
            logEntries.removeFirst(logEntries.count - limit)
        }
        return true
    }

    func restoreSidebarLogEntries(_ entries: [SidebarLogEntry]) {
        logEntries.removeAll(keepingCapacity: true)
        for entry in entries {
            _ = appendSidebarLogEntry(entry)
        }
    }
}
