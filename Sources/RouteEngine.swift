import Foundation

// The event-route engine (docs/plans/event-routes.md): the broadcaster's tap hands it each
// `agent_state`, `needs_input` and `workspace_lifecycle` frame, it resolves the fields the frame
// lacks, matches the installed routes and drives one `RouteGate` per (route name, key).

/// Where the installed routes came from. `debug.routes.load` installs a `debugOverride`, which
/// masks the file until it is cleared.
enum RouteSource: Sendable, Equatable {
    case file(digest: String?)
    case debugOverride
}

struct RouteCounters: Sendable, Equatable {
    var matched = 0
    var fired = 0
    var throttled = 0
    var busy = 0
    var expired = 0

    mutating func record(_ counter: RouteCounter) {
        switch counter {
        case .fired: fired += 1
        case .throttled: throttled += 1
        case .busy: busy += 1
        case .expired: expired += 1
        }
    }
}

struct RouteEngineSnapshot: Sendable, Equatable {
    struct Route: Sendable, Equatable {
        var name: String
        var on: String
        var action: String
        var counters: RouteCounters
        var lastError: String?
    }

    var source: RouteSource
    var routes: [Route]
    var issues: [ProgramaRouteIssue]
}

/// One action the gate let through. `generation` ties it to the route set that fired it.
struct RouteFire: Sendable, Equatable {
    let route: CompiledRoute
    let key: String
    let event: RouteEvent
    let generation: UInt64
}

/// Runs route actions, on the main actor.
@MainActor
protocol RouteActionExecutor: AnyObject {
    /// Runs `fire`'s action. When the route holds for a delivery (`fire.route.deliveryTimeout` is
    /// set), call `RouteEngine.endDelivery(_:error:)` once it ends, however it ends.
    func execute(_ fire: RouteFire)
    /// The delivery for this route and key expired, or the route set changed under it: stop it.
    func cancel(routeName: String, key: String)
}

@MainActor
final class RouteEngine {
    static let shared = RouteEngine(tap: SocketEventBroadcaster.shared.routeTap)

    /// Nil until the action executor exists. Without one a fire is only counted, and a delivery
    /// ends at once so the route does not read as busy until it expires.
    weak var executor: RouteActionExecutor?

    private struct GateKey: Hashable {
        let route: String
        let key: String
    }

    private struct InstalledRoute {
        let compiled: CompiledRoute
        var counters = RouteCounters()
        var lastError: String?
    }

    private struct RouteSet {
        var routes: [ProgramaRouteDefinition]
        var issues: [ProgramaRouteIssue]
        var source: RouteSource
    }

    private let tap: RouteTap?
    private let now: @MainActor () -> Date
    private let scheduleWake: @MainActor (Date, @escaping @MainActor () -> Void) -> Void
    private let modelFields: @MainActor (RouteEvent) -> [String: String]

    /// The global file's latest routes, kept while a debug override masks them.
    private var fileSet = RouteSet(routes: [], issues: [], source: .file(digest: nil))
    private var source: RouteSource = .file(digest: nil)
    private var routes: [InstalledRoute] = []
    private var issues: [ProgramaRouteIssue] = []
    private var gates: [GateKey: RouteGateState] = [:]
    /// Bumped on every install, so wakes and delivery ends from an older route set are ignored.
    private var generation: UInt64 = 0

    init(
        tap: RouteTap? = nil,
        now: @escaping @MainActor () -> Date = Date.init,
        scheduleWake: @escaping @MainActor (Date, @escaping @MainActor () -> Void) -> Void = RouteEngine.scheduleOnMain(at:_:),
        modelFields: @escaping @MainActor (RouteEvent) -> [String: String] = RouteEngine.resolveModelFields(for:)
    ) {
        self.tap = tap
        self.now = now
        self.scheduleWake = scheduleWake
        self.modelFields = modelFields
    }

    // MARK: - Routes

    /// Installs a route set. A file install with the digest the engine already holds is a no-op
    /// (every window's config store reports the same global file), and a file install while a
    /// debug override holds is kept for when the override is cleared.
    func install(routes: [ProgramaRouteDefinition], issues: [ProgramaRouteIssue], source: RouteSource) {
        let set = RouteSet(routes: routes, issues: issues, source: source)
        if case .file = source {
            guard source != fileSet.source else { return }
            fileSet = set
            guard self.source != .debugOverride else { return }
        }
        activate(set)
    }

    /// Returns to the global file's routes.
    func clearDebugOverride() {
        guard source == .debugOverride else { return }
        activate(fileSet)
    }

    func snapshot() -> RouteEngineSnapshot {
        RouteEngineSnapshot(
            source: source,
            routes: routes.map { route in
                RouteEngineSnapshot.Route(
                    name: route.compiled.name,
                    on: route.compiled.definition.on.text,
                    action: route.compiled.definition.action.name,
                    counters: route.counters,
                    lastError: route.lastError
                )
            },
            issues: issues
        )
    }

    /// A route change cancels every delivery in flight and forgets every gate.
    private func activate(_ set: RouteSet) {
        for (gateKey, state) in gates {
            if case .delivering = state {
                executor?.cancel(routeName: gateKey.route, key: gateKey.key)
            }
        }
        gates = [:]
        generation &+= 1
        source = set.source
        routes = set.routes.map { InstalledRoute(compiled: CompiledRoute($0)) }
        issues = set.issues
        tap?.setWantedClasses(Self.eventClasses(for: set.routes.map(\.on)))
    }

    // MARK: - Events

    func ingest(_ tapped: RouteEvent) {
        let candidates = routes.indices.filter { routes[$0].compiled.definition.on.matches(topic: tapped.topic) }
        guard !candidates.isEmpty else { return }
        let event = RouteEvent(
            topic: tapped.topic,
            fields: tapped.fields.merging(modelFields(tapped)) { frame, _ in frame }
        )
        let values = event.values
        let at = now()
        for index in candidates where routes[index].compiled.definition.matches(event) {
            routes[index].counters.matched += 1
            let definition = routes[index].compiled.definition
            let key = ProgramaConfigExecutor.substituteParameters(in: definition.key, values: values)
            apply(.matched(event, now: at), to: GateKey(route: definition.name, key: key))
        }
    }

    /// Reports that `fire`'s delivery ended. `error` becomes the route's last error.
    func endDelivery(_ fire: RouteFire, error: String? = nil) {
        guard fire.generation == generation else { return }
        if let error, let index = routes.firstIndex(where: { $0.compiled.name == fire.route.name }) {
            routes[index].lastError = error
        }
        apply(.deliveryEnded(now: now()), to: GateKey(route: fire.route.name, key: fire.key))
    }

    private func apply(_ input: RouteGateInput, to gateKey: GateKey) {
        guard let index = routes.firstIndex(where: { $0.compiled.name == gateKey.route }) else { return }
        let route = routes[index].compiled
        let (next, effects) = RouteGate.reduce(gates[gateKey], input, route: route)
        gates[gateKey] = next

        var fires: [RouteFire] = []
        for effect in effects {
            switch effect {
            case .fire(let event):
                fires.append(RouteFire(route: route, key: gateKey.key, event: event, generation: generation))
            case .wake(let date):
                let scheduledGeneration = generation
                scheduleWake(date) { [weak self] in
                    self?.wake(gateKey, at: date, generation: scheduledGeneration)
                }
            case .cancelDelivery:
                executor?.cancel(routeName: gateKey.route, key: gateKey.key)
            case .count(let counter):
                routes[index].counters.record(counter)
            }
        }
        // After the gate state and counters are stored, so a delivery that ends inside `execute`
        // reaches the state the fire left.
        for fire in fires {
            if let executor {
                executor.execute(fire)
            } else if route.deliveryTimeout != nil {
                endDelivery(fire)
            }
        }
    }

    private func wake(_ gateKey: GateKey, at scheduled: Date, generation scheduledGeneration: UInt64) {
        guard scheduledGeneration == generation else { return }
        // The timer runs on uptime and the gate compares wall-clock dates: a wake a moment early
        // would be a no-op and leave a debounced event pending.
        apply(.wake(now: max(now(), scheduled)), to: gateKey)
    }

    // MARK: - Production seams

    static func scheduleOnMain(at date: Date, _ body: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, date.timeIntervalSinceNow)) {
            MainActor.assumeIsolated { body() }
        }
    }

    /// Fields an `agent/#` event takes from the model: the surface's directory and branch, and
    /// whether its workspace came from `worktree.create` or `worktree.open`.
    static func resolveModelFields(for event: RouteEvent) -> [String: String] {
        guard event.topic.hasPrefix("agent/"),
              let workspaceId = event.fields["workspace_id"].flatMap(UUID.init(uuidString:)),
              let surfaceId = event.fields["surface_id"].flatMap(UUID.init(uuidString:)),
              let workspace = AppDelegate.shared?.workspaceFor(tabId: workspaceId) else { return [:] }
        var fields = ["worktree": (workspace.worktreeBranch ?? "").isEmpty ? "false" : "true"]
        fields["cwd"] = workspace.sidebarResolvedDirectory(for: surfaceId)
        fields["git_branch"] = workspace.panelGitBranches[surfaceId]?.branch
        return fields
    }

    /// The event classes a set of patterns can match. Over-inclusive on purpose: a class missing
    /// here drops its events silently.
    nonisolated static func eventClasses(for patterns: [ProgramaRouteTopicPattern]) -> Set<SocketEventClass> {
        // A nil level is an ID or a value; the literals are each topic's hand-written levels.
        let shapes: [(SocketEventClass, [String?])] = [
            (.agentState, ["agent", nil, "state", nil]),
            (.needsInput, ["agent", nil, "needs_input", nil]),
            (.workspaceLifecycle, ["workspace", nil, nil]),
        ]
        var classes = Set<SocketEventClass>()
        for (eventClass, shape) in shapes where patterns.contains(where: { $0.couldMatch(shape) }) {
            classes.insert(eventClass)
        }
        return classes
    }
}

private extension ProgramaRouteTopicPattern {
    func couldMatch(_ shape: [String?]) -> Bool {
        for (position, level) in levels.enumerated() {
            switch level {
            case .anyRest:
                return true
            case .anyOne:
                guard position < shape.count else { return false }
            case .literal(let text):
                guard position < shape.count else { return false }
                if let fixed = shape[position], fixed != text { return false }
            }
        }
        return levels.count == shape.count
    }
}

extension ProgramaRouteAction {
    var name: String {
        switch self {
        case .notify: return "notify"
        case .send: return "send"
        case .prompt: return "prompt"
        case .run: return "run"
        case .review: return "review"
        }
    }
}

// MARK: - Tap

/// The broadcaster's in-process consumer. `wants` is read on every publish, so a class no route
/// names costs one locked set lookup.
final class RouteTap: @unchecked Sendable {
    private let lock = NSLock()
    private var wantedClasses = Set<SocketEventClass>()

    func setWantedClasses(_ classes: Set<SocketEventClass>) {
        lock.lock()
        wantedClasses = classes
        lock.unlock()
    }

    func wants(_ eventClass: SocketEventClass) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return wantedClasses.contains(eventClass)
    }

    func ingest(_ frame: [String: Any], previousState: AgentActivityState? = nil) {
        guard let event = RouteEvent(frame: frame, previousState: previousState) else { return }
        // Never inline: the publishers run on main in the middle of a model mutation, and an
        // action must not run inside it. The main queue is FIFO, so events keep their order.
        DispatchQueue.main.async {
            MainActor.assumeIsolated { RouteEngine.shared.ingest(event) }
        }
    }
}

extension RouteEvent {
    /// The event a route sees for a broadcaster frame, or nil for a frame routes do not take.
    /// Null values are absent, numbers are their decimal string, and `program_status` is
    /// flattened to `program_status.<key>`.
    init?(frame: [String: Any], previousState: AgentActivityState? = nil) {
        var fields: [String: String] = [:]
        for (key, value) in frame where key != "event" {
            if key == "program_status", let status = value as? [String: Any] {
                for (statusKey, statusValue) in status {
                    fields[ProgramaRouteField.programStatusPrefix + statusKey] = Self.text(statusValue)
                }
            } else {
                fields[key] = Self.text(value)
            }
        }
        if let previousState {
            fields["previous_state"] = previousState.rawValue
        }

        let topic: String
        switch frame["event"] as? String {
        case "agent_state":
            guard let surfaceId = fields["surface_id"] else { return nil }
            topic = "agent/\(surfaceId)/state/\(fields["state"] ?? "none")"
        case "needs_input":
            guard let surfaceId = fields["surface_id"] else { return nil }
            topic = "agent/\(surfaceId)/needs_input/\(fields["kind"] ?? "unknown")"
        case "workspace_lifecycle":
            guard let workspaceId = fields["workspace_id"], let kind = fields["kind"] else { return nil }
            topic = "workspace/\(workspaceId)/\(kind)"
        default:
            return nil
        }
        self.init(topic: topic, fields: fields)
    }

    private static func text(_ value: Any) -> String? {
        switch value {
        case let string as String: return string
        case let bool as Bool: return bool ? "true" : "false"
        case let integer as Int: return String(integer)
        case let double as Double: return String(double)
        case let number as NSNumber: return number.stringValue
        default: return nil
        }
    }
}
