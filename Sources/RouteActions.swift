import Darwin
import Foundation

// Route actions (docs/plans/event-routes.md, "Actions"): `notify`, `review` and `run`. `send` and
// `prompt` end their delivery at once until they are delivered to the agent.

struct RouteNotification: Sendable, Equatable {
    var workspaceId: UUID?
    var surfaceId: UUID?
    var title: String
    var subtitle: String
    var body: String
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
        case .timedOut(let timeout): return "timed out after \(Int(timeout)) s"
        case .launch(let message): return "could not start: \(message)"
        }
    }
}

/// What the actions touch, injectable so tests run without AppKit, git or a shell.
struct RouteActionEnvironment {
    var notify: @MainActor (RouteNotification) -> Void
    var postAppNotification: @MainActor (_ title: String, _ body: String) -> Void
    var hasReviewPanel: @MainActor (UUID) -> Bool
    /// Off main. Returns an error message, or nil once the panel is open.
    var openReview: @Sendable (RouteReviewRequest) -> String?
    /// Off main; blocks until the command exits or times out.
    var run: @Sendable (RouteRunRequest) -> CanonicalSubprocessResult
    var offMain: (@escaping @Sendable () -> Void) -> Void
    var onMain: @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void
    var loginShell: () -> String
    var homeDirectory: String
}

@MainActor
final class RouteActions: RouteActionExecutor {
    /// Owns the production executor for the app's lifetime; `RouteEngine.shared` holds it weakly.
    static let shared = RouteActions(environment: .live())

    private let environment: RouteActionEnvironment

    init(environment: RouteActionEnvironment) {
        self.environment = environment
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
                body: Self.render(body ?? "", values)
            ))
        case .review(let mode, let baseBranch):
            review(fire, mode: mode, baseBranch: baseBranch, engine: engine)
        case .run(let command, _):
            run(fire, command: command, engine: engine)
        case .send, .prompt:
            engine.endDelivery(fire)
        }
    }

    func cancel(_ fire: RouteFire) {
        // SHORTCUT: a cancelled `run` keeps going until it exits or reaches its own timeout,
        // which equals the route's delivery timeout, so only a route reload cancels one early.
        // ceiling: one stray process per route and key per reload of the global file.
        // upgrade: when CanonicalSubprocessRunner exposes a cancel handle or the child's pid.
    }

    func reportLoadIssues(_ issues: [ProgramaRouteIssue]) {
        guard let first = issues.first else { return }
        let label = first.name ?? first.index.map { "#\($0 + 1)" } ?? "routes"
        let title = String(localized: "routes.loadIssues.title", defaultValue: "Some event routes did not load")
        let body = issues.count == 1
            ? String.localizedStringWithFormat(
                String(localized: "routes.loadIssues.bodyOne", defaultValue: "“%@” in programa.json has a problem and was skipped."),
                label
            )
            : String.localizedStringWithFormat(
                String(
                    localized: "routes.loadIssues.bodyMany",
                    defaultValue: "“%1$@” and %2$lld more routes in programa.json have problems and were skipped."
                ),
                label,
                Int64(issues.count - 1)
            )
        environment.postAppNotification(title, body)
    }

    // MARK: - review

    /// A workspace that already shows a review panel keeps it: the panel refreshes itself on turn
    /// edges, and a second one would only add a split.
    private func review(_ fire: RouteFire, mode: ReviewDiffMode?, baseBranch: String?, engine: RouteEngine) {
        guard let workspaceId = fire.event.fields["workspace_id"].flatMap(UUID.init(uuidString:)) else {
            engine.recordError("review: the event names no workspace", for: fire)
            return
        }
        guard !environment.hasReviewPanel(workspaceId) else { return }
        let request = RouteReviewRequest(
            workspaceId: workspaceId,
            surfaceId: fire.event.fields["surface_id"].flatMap(UUID.init(uuidString:)),
            mode: mode,
            baseBranch: baseBranch
        )
        let openReview = environment.openReview
        let onMain = environment.onMain
        environment.offMain {
            guard let error = openReview(request) else { return }
            onMain { engine.recordError("review: \(error)", for: fire) }
        }
    }

    // MARK: - run

    private func run(_ fire: RouteFire, command: String, engine: RouteEngine) {
        let timeout = fire.route.deliveryTimeout ?? CompiledRoute.defaultDeliveryTimeout
        let request = RouteRunRequest(
            shell: environment.loginShell(),
            command: command,
            directory: fire.event.fields["cwd"] ?? environment.homeDirectory,
            timeout: timeout,
            environment: Self.environmentVariables(for: fire.event)
        )
        let runCommand = environment.run
        let onMain = environment.onMain
        environment.offMain {
            let failure = RouteRunFailure(runCommand(request), timeout: timeout)
            onMain { self.finishRun(fire, failure: failure, engine: engine) }
        }
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

extension RouteActionEnvironment {
    @MainActor
    static func live() -> RouteActionEnvironment {
        let controller = TerminalController.shared
        // Concurrent: a long `run` must not hold up a `review` or another route's `run`. The gate
        // allows one delivery per route and key.
        let queue = DispatchQueue(label: "com.darkroom.programa.route-actions", qos: .utility, attributes: .concurrent)
        return RouteActionEnvironment(
            notify: postNotification,
            postAppNotification: { title, body in
                TerminalNotificationStore.shared.postAppNotification(title: title, body: body)
            },
            hasReviewPanel: { workspaceId in
                AppDelegate.shared?.workspaceFor(tabId: workspaceId)?.panels.values.contains { $0 is ReviewPanel } ?? false
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
            loginShell: userLoginShell,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path
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
            body: notification.body
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
