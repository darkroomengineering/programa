import Darwin
import Foundation

// Route actions (docs/plans/event-routes.md, "Actions"): `notify`, `review`, `run`, and `send` and
// `prompt`, which paste into the event's agent surface.

struct RouteNotification: Sendable, Equatable {
    var workspaceId: UUID?
    var surfaceId: UUID?
    var title: String
    var subtitle: String
    var body: String
    /// The banner kind a socket client can take over with `notification.claim_banners`; a route
    /// notification for a `needs_input` call honours the claim as the built-in one does.
    var claimKind: NotificationBannerClaimKind?
}

struct RouteReviewRequest: Sendable, Equatable {
    var workspaceId: UUID
    var surfaceId: UUID?
    var mode: ReviewDiffMode?
    var baseBranch: String?
}

struct RouteRunRequest: Sendable, Equatable {
    var shell: String
    var command: String
    var directory: String
    var timeout: TimeInterval
    var environment: [String: String]
}

/// Why a `run` failed. A zero exit is success, even when the output overflowed its limit.
enum RouteRunFailure: Sendable, Equatable {
    case exitStatus(Int32, tail: String)
    case timedOut(TimeInterval)
    case launch(String)
    /// The command waited for a run slot for its whole timeout and never started.
    case neverStarted(TimeInterval)

    static let outputTailLimit = 600

    init?(_ result: CanonicalSubprocessResult, timeout: TimeInterval) {
        switch result.outcome {
        case .timedOut:
            self = .timedOut(timeout)
        case .launchError(let message):
            self = .launch(message)
        default:
            guard let status = result.exitStatus else {
                self = .launch(result.executionError ?? "the command reported no exit status")
                return
            }
            guard status != 0 else { return nil }
            let output = [result.stdout, result.stderr].compactMap { $0 }.joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            self = .exitStatus(status, tail: String(output.suffix(Self.outputTailLimit)))
        }
    }

    /// For `routes.list`, which is read by scripts and the CLI, so it stays English.
    var lastError: String {
        switch self {
        case .exitStatus(let status, _): return "exited with status \(status)"
        case .timedOut(let timeout):
            return timeout >= 1 ? "timed out after \(Int(timeout)) s" : "timed out after \(Int(timeout * 1000)) ms"
        case .launch(let message): return "could not start: \(message)"
        case .neverStarted(let timeout):
            return "never started: no run slot was free within \(Int(timeout)) s"
        }
    }
}

/// The surface a `send` or `prompt` writes into. Every read and the write happen in one main hop,
/// so no keystroke or agent report lands between the checks and the paste.
@MainActor
protocol RouteAgentTarget {
    var agentState: AgentActivityState? { get }
    /// `Workspace.canAutoSubmitToAgent`: a known, non-blocked, non-stale agent.
    var canAutoSubmit: Bool { get }
    /// The permission or sign-in prompt kind showing, if any.
    var promptHoldKind: String? { get }
    /// A person has unsent typed input.
    var hasDraftHold: Bool { get }
    /// The agent's state comes from a reporter that names itself: OSC 7501 from the program, or
    /// hooks reports that carry a session id. Screen inference and keyless hooks reports do not.
    var writerIdentified: Bool { get }
    /// One paste, plus Return when `submit` is true.
    func deliver(_ text: String, submit: Bool)
}

/// What the actions touch, injectable so tests run without AppKit, git or a shell.
struct RouteActionEnvironment {
    var notify: @MainActor (RouteNotification) -> Void
    var postAppNotification: @MainActor (_ title: String, _ body: String) -> Void
    var hasReviewPanel: @MainActor (UUID) -> Bool
    var agentTarget: @MainActor (_ workspaceId: UUID, _ surfaceId: UUID) -> (any RouteAgentTarget)?
    /// Off main. Returns an error message, or nil once the panel is open.
    var openReview: @Sendable (RouteReviewRequest) -> String?
    /// Off main; blocks until the command exits or times out.
    var run: @Sendable (RouteRunRequest) -> CanonicalSubprocessResult
    var offMain: (@escaping @Sendable () -> Void) -> Void
    var onMain: @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void
    var loginShell: () -> String
    var now: @MainActor () -> Date = Date.init
}

/// The one builder of text a route sends to an agent. It substitutes identifier fields only (load
/// validation already rejects a free-text placeholder in `send` and `prompt`); an absent
/// identifier renders empty, and any other placeholder stays literal. When external route sources
/// arrive, this is where free text gets wrapped in the untrusted-text marker.
enum RouteAgentText {
    @MainActor
    static func render(_ template: String, event: RouteEvent) -> String {
        var values = event.values.filter { ProgramaRouteField.trust(of: $0.key) == .identifier }
        for name in ProgramaRouteField.placeholders(in: template)
        where values[name] == nil && ProgramaRouteField.trust(of: name) == .identifier {
            values[name] = ""
        }
        return ProgramaConfigExecutor.substituteParameters(in: template, values: values)
    }
}

@MainActor
final class RouteActions: RouteActionExecutor {
    /// Owns the production executor for the app's lifetime; `RouteEngine.shared` holds it weakly.
    static let shared = RouteActions(environment: .live())
    nonisolated static let maxConcurrentRuns = 4

    private struct QueuedRun {
        let fire: RouteFire
        let command: String
        let engine: RouteEngine
        let queuedAt: Date
    }

    private let environment: RouteActionEnvironment
    /// Bounds `run` processes app-wide; `review` does not count.
    private let maxConcurrentRuns: Int
    private var runningRuns = 0
    /// Runs waiting for a slot, oldest first. Waiting holds no thread.
    private var queuedRuns: [QueuedRun] = []
    /// Workspaces with a route review being opened off main, so two surfaces going idle together
    /// open one panel.
    private var pendingReviews = Set<UUID>()

    init(environment: RouteActionEnvironment, maxConcurrentRuns: Int = RouteActions.maxConcurrentRuns) {
        self.environment = environment
        self.maxConcurrentRuns = maxConcurrentRuns
    }

    func execute(_ fire: RouteFire, engine: RouteEngine) {
        switch fire.route.definition.action {
        case .notify(let title, let subtitle, let body):
            let values = fire.event.values
            environment.notify(RouteNotification(
                workspaceId: values["workspace_id"].flatMap(UUID.init(uuidString:)),
                surfaceId: values["surface_id"].flatMap(UUID.init(uuidString:)),
                title: Self.render(title, values),
                subtitle: Self.render(subtitle ?? "", values),
                body: Self.render(body ?? "", values),
                claimKind: fire.event.topic.contains("/needs_input/") ? .needsInput : nil
            ))
        case .review(let mode, let baseBranch):
            review(fire, mode: mode, baseBranch: baseBranch, engine: engine)
        case .run(let command, _):
            run(fire, command: command, engine: engine)
        case .send(_, let whenBusy), .prompt(_, let whenBusy):
            guard let target = agentTarget(for: fire) else {
                engine.endDelivery(fire, error: "the event's surface is gone")
                return
            }
            // `queue` waits for the end of the agent's work: `targetWentIdle`.
            if whenBusy == .queue, target.agentState == .working { return }
            deliverText(fire, to: target, engine: engine, firedNow: true)
        }
    }

    func targetWentIdle(_ fire: RouteFire, engine: RouteEngine) {
        guard let target = agentTarget(for: fire) else {
            engine.endDelivery(fire, error: "the event's surface is gone")
            return
        }
        deliverText(fire, to: target, engine: engine, firedNow: false)
    }

    func cancel(_ fire: RouteFire) {
        // A run still waiting for a slot is dropped here: its route expired or was reinstalled.
        if let index = queuedRuns.firstIndex(where: { $0.fire.id == fire.id }) {
            let queued = queuedRuns.remove(at: index)
            if queued.engine.isCurrent(fire) {
                finishRun(fire, failure: .neverStarted(fire.route.deliveryTimeout ?? CompiledRoute.defaultDeliveryTimeout), engine: queued.engine)
            } else {
                reportStaleRun(fire)
            }
            return
        }
        // SHORTCUT: a cancelled `run` keeps going until it exits or reaches its own timeout,
        // which equals the route's delivery timeout, so only a route reload cancels one early.
        // `send` and `prompt` hold nothing outside the gate, so there is nothing else to stop.
        // ceiling: one stray process per route and key per reload of the global file.
        // upgrade: when CanonicalSubprocessRunner exposes a cancel handle or the child's pid.
    }

    func reportLoadIssues(_ issues: [ProgramaRouteIssue]) {
        guard let first = issues.first else { return }
        let label = first.name ?? first.index.map { "#\($0 + 1)" } ?? "routes"
        let title = String(localized: "routes.loadIssues.title", defaultValue: "Some event routes did not load")
        let more = issues.count - 1
        let body = more == 0
            ? String.localizedStringWithFormat(
                String(localized: "routes.loadIssues.bodyOne", defaultValue: "“%@” in programa.json has a problem and was skipped."),
                label
            )
            : String(
                localized: "routes.loadIssues.bodyMany",
                defaultValue: "“\(label)” and \(more) more routes in programa.json have problems and were skipped."
            )
        environment.postAppNotification(title, body)
    }

    // MARK: - send and prompt

    private func agentTarget(for fire: RouteFire) -> (any RouteAgentTarget)? {
        guard let workspaceId = fire.event.fields["workspace_id"].flatMap(UUID.init(uuidString:)),
              let surfaceId = fire.event.fields["surface_id"].flatMap(UUID.init(uuidString:)) else { return nil }
        return environment.agentTarget(workspaceId, surfaceId)
    }

    /// Checks and paste in one main hop. Text goes only to an agent whose state reports name their
    /// writer; a route never answers a prompt or overrides a person's draft. `firedNow` is true
    /// when the report that fired the route is the one releasing the text. A `prompt` submits only
    /// to an agent that can take it and then holds its route until the turn ends; anything else
    /// ends the delivery at once.
    private func deliverText(_ fire: RouteFire, to target: any RouteAgentTarget, engine: RouteEngine, firedNow: Bool) {
        let template: String
        let wantsSubmit: Bool
        switch fire.route.definition.action {
        case .send(let text, _): (template, wantsSubmit) = (text, false)
        case .prompt(let text, _): (template, wantsSubmit) = (text, true)
        default: return
        }
        // A debounced or queued prompt fires after its match, and two can come due together, so
        // the one-turn-per-surface rule is checked again here, just before anything is pasted.
        if wantsSubmit, let surfaceId = fire.event.fields["surface_id"], engine.routeTurnIsOpen(onSurface: surfaceId) {
            engine.recordBusy(fire)
            engine.endDelivery(fire)
            return
        }
        if let refusal = Self.textRefusal(fire, target: target, engine: engine, firedNow: firedNow) {
            engine.endDelivery(fire, error: refusal)
            return
        }
        let submit = wantsSubmit && target.canAutoSubmit
        target.deliver(RouteAgentText.render(template, event: fire.event), submit: submit)
        if submit {
            engine.turnStarted(fire)
        } else if wantsSubmit {
            engine.endDelivery(fire, error: "pasted without submitting: no agent ready for a prompt")
        } else {
            engine.endDelivery(fire)
        }
    }

    /// Why text must not go to `target` now, in the order the checks run.
    private static func textRefusal(
        _ fire: RouteFire,
        target: any RouteAgentTarget,
        engine: RouteEngine,
        firedNow: Bool
    ) -> String? {
        guard target.agentState != nil else {
            return "refused: the surface has no agent; nothing was sent"
        }
        if let kind = target.promptHoldKind {
            return "refused: a \(kind) prompt is showing; nothing was sent"
        }
        if target.hasDraftHold {
            return "refused: the surface has unsent typed input; nothing was sent"
        }
        guard target.writerIdentified else {
            return "refused: the agent's state reports name no session; nothing was sent"
        }
        if let surfaceId = fire.event.fields["surface_id"], let refusal = engine.textDeliveryRefusal(surfaceId: surfaceId) {
            return refusal
        }
        guard firedNow, let surfaceId = fire.event.fields["surface_id"],
              fire.event.topic.hasPrefix("agent/\(surfaceId)/") else { return nil }
        // The report releasing the text must name its own writer: a keyless report inherits the
        // session key of the presence it updates, so the presence alone cannot tell.
        if fire.event.writer == nil {
            return "refused: the report that fired this route names no session; nothing was sent"
        }
        // A report that both creates the agent's state and fires the route proves nothing about an
        // agent being there.
        if fire.event.topic.hasPrefix("agent/\(surfaceId)/state/"), fire.event.fields["previous_state"] == nil {
            return "refused: the report that fired this route is the first from this agent; nothing was sent"
        }
        return nil
    }

    // MARK: - review

    /// A workspace that already shows a review panel, or is opening one for a route, keeps it: the
    /// panel refreshes itself on turn edges, and a second one would only add a split.
    private func review(_ fire: RouteFire, mode: ReviewDiffMode?, baseBranch: String?, engine: RouteEngine) {
        guard let workspaceId = fire.event.fields["workspace_id"].flatMap(UUID.init(uuidString:)) else {
            engine.recordError("review: the event names no workspace", for: fire)
            return
        }
        guard !environment.hasReviewPanel(workspaceId), pendingReviews.insert(workspaceId).inserted else { return }
        let request = RouteReviewRequest(
            workspaceId: workspaceId,
            surfaceId: fire.event.fields["surface_id"].flatMap(UUID.init(uuidString:)),
            mode: mode,
            baseBranch: baseBranch
        )
        let openReview = environment.openReview
        let onMain = environment.onMain
        environment.offMain {
            let error = openReview(request)
            onMain {
                self.pendingReviews.remove(workspaceId)
                if let error {
                    engine.recordError("review: \(error)", for: fire)
                }
            }
        }
    }

    // MARK: - run

    private func run(_ fire: RouteFire, command: String, engine: RouteEngine) {
        queuedRuns.append(QueuedRun(fire: fire, command: command, engine: engine, queuedAt: environment.now()))
        startQueuedRuns()
    }

    /// Starts queued runs while slots are free. Time spent queued counts against each run's
    /// timeout, so a run that waits too long times out instead of starting late.
    private func startQueuedRuns() {
        while runningRuns < maxConcurrentRuns, !queuedRuns.isEmpty {
            let queued = queuedRuns.removeFirst()
            guard queued.engine.isCurrent(queued.fire) else {
                reportStaleRun(queued.fire)
                continue
            }
            let timeout = queued.fire.route.deliveryTimeout ?? CompiledRoute.defaultDeliveryTimeout
            let remaining = timeout - environment.now().timeIntervalSince(queued.queuedAt)
            guard remaining > 0 else {
                finishRun(queued.fire, failure: .neverStarted(timeout), engine: queued.engine)
                continue
            }
            launch(queued, timeout: timeout, remaining: remaining)
        }
    }

    private func launch(_ queued: QueuedRun, timeout: TimeInterval, remaining: TimeInterval) {
        runningRuns += 1
        let fire = queued.fire
        let engine = queued.engine
        let request = RouteRunRequest(
            shell: environment.loginShell(),
            command: queued.command,
            directory: fire.event.fields["cwd"] ?? "",
            timeout: remaining,
            environment: Self.environmentVariables(for: fire.event)
        )
        let runCommand = environment.run
        let onMain = environment.onMain
        environment.offMain {
            let failure = Self.runResolved(request, timeout: timeout, runCommand: runCommand)
            onMain {
                self.runningRuns -= 1
                self.finishRun(fire, failure: failure, engine: engine)
                self.startQueuedRuns()
            }
        }
    }

    /// Resolves the directory again just before the spawn: it must still be an existing directory
    /// when the process starts.
    nonisolated private static func runResolved(
        _ request: RouteRunRequest,
        timeout: TimeInterval,
        runCommand: (RouteRunRequest) -> CanonicalSubprocessResult
    ) -> RouteRunFailure? {
        guard let directory = RouteEngine.canonicalDirectory(request.directory) else {
            return .launch("the surface's working directory is unknown or does not exist")
        }
        var resolved = request
        resolved.directory = directory
        return RouteRunFailure(runCommand(resolved), timeout: timeout)
    }

    /// A queued run whose routes were replaced before it started. Its route's counters went with
    /// the old routes, so the notification is the only report.
    private func reportStaleRun(_ fire: RouteFire) {
        environment.notify(RouteNotification(
            workspaceId: fire.event.fields["workspace_id"].flatMap(UUID.init(uuidString:)),
            surfaceId: fire.event.fields["surface_id"].flatMap(UUID.init(uuidString:)),
            title: String.localizedStringWithFormat(
                String(localized: "routes.run.failed.title", defaultValue: "Route “%@” failed"),
                fire.route.name
            ),
            subtitle: String(localized: "routes.run.failed.launch", defaultValue: "The command could not start"),
            body: String(
                localized: "routes.run.failed.stale",
                defaultValue: "The routes in programa.json changed before this command could start."
            )
        ))
    }

    private func finishRun(_ fire: RouteFire, failure: RouteRunFailure?, engine: RouteEngine) {
        engine.endDelivery(fire, error: failure?.lastError)
        guard let failure else { return }
        let subtitle: String
        let body: String
        switch failure {
        case .exitStatus(let status, let tail):
            subtitle = String.localizedStringWithFormat(
                String(localized: "routes.run.failed.exitStatus", defaultValue: "Exited with status %lld"),
                Int64(status)
            )
            body = tail
        case .timedOut(let timeout):
            subtitle = String.localizedStringWithFormat(
                String(localized: "routes.run.failed.timedOut", defaultValue: "Timed out after %lld seconds"),
                Int64(timeout)
            )
            body = ""
        case .launch(let message):
            subtitle = String(localized: "routes.run.failed.launch", defaultValue: "The command could not start")
            body = message
        case .neverStarted(let timeout):
            subtitle = String(localized: "routes.run.failed.launch", defaultValue: "The command could not start")
            body = String.localizedStringWithFormat(
                String(
                    localized: "routes.run.failed.noSlot",
                    defaultValue: "No run slot became free within %lld seconds, so the command never started."
                ),
                Int64(timeout)
            )
        }
        environment.notify(RouteNotification(
            workspaceId: fire.event.fields["workspace_id"].flatMap(UUID.init(uuidString:)),
            surfaceId: fire.event.fields["surface_id"].flatMap(UUID.init(uuidString:)),
            title: String.localizedStringWithFormat(
                String(localized: "routes.run.failed.title", defaultValue: "Route “%@” failed"),
                fire.route.name
            ),
            subtitle: subtitle,
            body: body
        ))
    }

    /// Every field as `PROGRAMA_ROUTE_<FIELD>`, upper-cased with other characters as `_`
    /// (`program_status.state` is `PROGRAMA_ROUTE_PROGRAM_STATUS_STATE`). The command string is
    /// never templated, so event text reaches the shell only as data.
    nonisolated static func environmentVariables(for event: RouteEvent) -> [String: String] {
        var variables: [String: String] = [:]
        for (field, value) in event.values {
            let name = field.uppercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? String($0) : "_" }.joined()
            variables["PROGRAMA_ROUTE_" + name] = value
        }
        return variables
    }

    /// Display text: every placeholder names a known field (checked at load), so one that is still
    /// unresolved is an absent field and renders empty.
    static func render(_ template: String, _ values: [String: String]) -> String {
        var values = values
        for name in ProgramaRouteField.placeholders(in: template) where values[name] == nil {
            values[name] = ""
        }
        return ProgramaConfigExecutor.substituteParameters(in: template, values: values)
    }
}

// MARK: - Production environment

@MainActor
private struct LiveRouteAgentTarget: RouteAgentTarget {
    let workspace: Workspace
    let panel: TerminalPanel

    var agentState: AgentActivityState? { workspace.panelAgentPresence[panel.id]?.state }
    var canAutoSubmit: Bool { workspace.canAutoSubmitToAgent(panelId: panel.id) }
    var promptHoldKind: String? { panel.surface.activePromptHold()?.kind.rawValue }
    var hasDraftHold: Bool { panel.surface.activeDraftHold() != nil }
    var writerIdentified: Bool {
        guard let presence = workspace.panelAgentPresence[panel.id] else { return false }
        switch presence.source {
        case .program: return true
        case .hooks: return !(presence.sessionKey?.sessionId ?? "").isEmpty
        case .inferred: return false
        }
    }

    func deliver(_ text: String, submit: Bool) {
        if submit {
            workspace.deliverTextToAgent(text, terminalPanel: panel)
        } else {
            panel.surface.sendPaste(text)
            panel.surface.forceRefresh(reason: "route.send")
        }
        panel.surface.noteDraftEvent(.socketWriteDelivered)
    }
}

extension RouteActionEnvironment {
    @MainActor
    static func live() -> RouteActionEnvironment {
        let controller = TerminalController.shared
        // Concurrent: a long `run` must not hold up a `review` or another route's `run`. The gate
        // allows one delivery per route and key, and `RouteActions` caps runs app-wide.
        let queue = DispatchQueue(label: "com.darkroom.programa.route-actions", qos: .utility, attributes: .concurrent)
        return RouteActionEnvironment(
            notify: postNotification,
            postAppNotification: { title, body in
                TerminalNotificationStore.shared.postAppNotification(title: title, body: body)
            },
            hasReviewPanel: { workspaceId in
                AppDelegate.shared?.workspaceFor(tabId: workspaceId)?.panels.values.contains { $0 is ReviewPanel } ?? false
            },
            agentTarget: { workspaceId, surfaceId in
                guard let workspace = AppDelegate.shared?.workspaceFor(tabId: workspaceId),
                      let panel = workspace.terminalPanel(for: surfaceId) else { return nil }
                return LiveRouteAgentTarget(workspace: workspace, panel: panel)
            },
            openReview: { request in
                var params: [String: Any] = ["workspace_id": request.workspaceId.uuidString, "focus": false]
                params["surface_id"] = request.surfaceId?.uuidString
                params["mode"] = request.mode?.rawValue
                params["base_branch"] = request.baseBranch
                switch controller.v2ReviewOpen(params: params) {
                case .ok:
                    return nil
                case .err(let code, let message, _):
                    return "\(code): \(message)"
                }
            },
            run: { request in
                CanonicalSubprocessRunner.run(
                    executable: request.shell,
                    arguments: ["-lc", request.command],
                    currentDirectory: request.directory,
                    timeout: request.timeout,
                    stdoutLimit: 1024 * 1024,
                    stderrLimit: 1024 * 1024,
                    executableURL: URL(fileURLWithPath: request.shell),
                    environmentOverrides: request.environment
                )
            },
            offMain: { work in queue.async(execute: work) },
            onMain: { body in
                DispatchQueue.main.async { MainActor.assumeIsolated { body() } }
            },
            loginShell: userLoginShell
        )
    }

    /// The event's workspace and surface when the workspace is still open; otherwise an app-level
    /// notification, since a closed workspace has no list entry to jump to.
    @MainActor
    private static func postNotification(_ notification: RouteNotification) {
        guard let workspaceId = notification.workspaceId,
              let workspace = AppDelegate.shared?.workspaceFor(tabId: workspaceId) else {
            let body = [notification.subtitle, notification.body].filter { !$0.isEmpty }.joined(separator: "\n")
            TerminalNotificationStore.shared.postAppNotification(title: notification.title, body: body)
            return
        }
        let surfaceId = notification.surfaceId.flatMap { workspace.panels[$0] != nil ? $0 : nil }
        TerminalNotificationStore.shared.addNotification(
            tabId: workspaceId,
            surfaceId: surfaceId,
            title: TerminalController.v2ResolveNotificationTitle(
                title: notification.title, workspace: workspace, surfaceId: surfaceId
            ),
            subtitle: notification.subtitle,
            body: notification.body,
            deliversBanner: !(notification.claimKind.map(NotificationBannerClaims.shared.isClaimed) ?? false)
        )
    }

    private static func userLoginShell() -> String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let path = String(cString: shell)
            if !path.isEmpty { return path }
        }
        return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }
}
