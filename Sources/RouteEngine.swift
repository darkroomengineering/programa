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

/// One action the gate let through. `id` is unique for the app's lifetime; `generation` ties the
/// fire to the route set that fired it.
struct RouteFire: Sendable, Equatable {
    let id: UInt64
    let route: CompiledRoute
    let key: String
    let event: RouteEvent
    let generation: UInt64
}

/// Runs route actions, on the main actor.
@MainActor
protocol RouteActionExecutor: AnyObject {
    /// Runs `fire`'s action. When the route holds for a delivery (`fire.route.deliveryTimeout` is
    /// set), call `engine.endDelivery(_:error:)` once it ends, however it ends.
    func execute(_ fire: RouteFire, engine: RouteEngine)
    /// `fire`'s delivery expired, or the route set changed under it: stop it. The engine has
    /// already released the route, so no `endDelivery` follows; a late one is ignored, and only
    /// its error is kept.
    func cancel(_ fire: RouteFire)
    /// `fire` is a `send` or `prompt` queued behind a working agent, and its surface just reported
    /// idle. Deliver it now, then call `endDelivery`, or `turnStarted` for a submitted prompt.
    func targetWentIdle(_ fire: RouteFire, engine: RouteEngine)
    /// A changed global file installed with route issues. Called once per file digest.
    func reportLoadIssues(_ issues: [ProgramaRouteIssue])
}

@MainActor
final class RouteEngine {
    static let shared: RouteEngine = {
        let engine = RouteEngine(tap: SocketEventBroadcaster.shared.routeTap)
        engine.executor = RouteActions.shared
        return engine
    }()

    /// Weak: `RouteActions.shared` owns the production executor. Without one a fire is only
    /// counted, and a delivery ends at once so the route does not read as busy until it expires.
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
    /// The fire behind each gate in `.delivering`, and only those: `apply` keeps the two in step.
    /// A late `endDelivery` from an expired fire must not end the newer delivery on its key.
    private var deliveries: [GateKey: RouteFire] = [:]
    private var lastFireId: UInt64 = 0
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
            if !issues.isEmpty {
                executor?.reportLoadIssues(issues)
            }
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
        let cancelled = Array(deliveries.values)
        deliveries = [:]
        gates = [:]
        generation &+= 1
        source = set.source
        routes = set.routes.map { InstalledRoute(compiled: CompiledRoute($0)) }
        issues = set.issues
        var classes = Self.eventClasses(for: set.routes.map(\.on))
        // A `send` or `prompt` waits on its surface's idle report whatever topic fired it.
        if set.routes.contains(where: { $0.action.deliversText }) {
            classes.insert(.agentState)
        }
        tap?.setWantedClasses(classes)
        for fire in cancelled {
            executor?.cancel(fire)
        }
    }

    // MARK: - Events

    /// Matches the routes first, then settles the text deliveries that were already held on the
    /// event's surface. In that order, the idle that ends a prompt's own turn counts as `busy` for
    /// its route instead of firing it again, and a delivery this very event fired is not handed
    /// back as "went idle".
    func ingest(_ tapped: RouteEvent) {
        let heldBefore = Set(deliveries.values.map(\.id))
        match(tapped)
        settleTextDeliveries(after: tapped, heldBefore: heldBefore)
    }

    private func match(_ tapped: RouteEvent) {
        let candidates = routes.indices.filter { routes[$0].compiled.definition.on.matches(topic: tapped.topic) }
        guard !candidates.isEmpty else { return }
        let event = resolved(tapped)
        let values = event.values
        let at = now()
        for index in candidates where routes[index].compiled.definition.matches(event) {
            routes[index].counters.matched += 1
            apply(.matched(event, now: at), to: gateKey(routes[index].compiled.definition, values: values))
        }
    }

    /// An idle report delivers the `send`s and `prompt`s queued on that surface and ends the
    /// prompt turns open on it; a clear ends both, since the agent is gone.
    private func settleTextDeliveries(after event: RouteEvent, heldBefore: Set<UInt64>) {
        guard event.topic.hasPrefix("agent/"), let surfaceId = event.fields["surface_id"] else { return }
        let cleared = event.topic.hasSuffix("/state/none")
        guard cleared || event.topic.hasSuffix("/state/idle") else { return }
        for (gateKey, fire) in deliveries
        where heldBefore.contains(fire.id) && fire.event.fields["surface_id"] == surfaceId {
            // An earlier settle in this loop can have moved this gate on.
            guard deliveries[gateKey]?.id == fire.id,
                  case .delivering(let delivery, _, _) = gates[gateKey] else { continue }
            switch delivery {
            case .running:
                continue
            case .ownTurn:
                endDelivery(fire)
            case .waitingForIdle where cleared:
                endDelivery(fire, error: "the agent stopped before the text was delivered")
            case .waitingForIdle:
                if let executor {
                    executor.targetWentIdle(fire, engine: self)
                } else {
                    endDelivery(fire)
                }
            }
        }
    }

    /// Whether `tapped`'s built-in `needs_input` banner gives way to a `notify` route. A question
    /// gives way whenever a route matches on topic and `when`, throttled or not, so "once per
    /// 5 minutes" is what the person sees. A permission prompt gives way only when a route fires
    /// for this very call: a throttled or debounced route must never hide one. Synchronous, so
    /// the caller can ask before it posts; the tap's ingest of the same call runs next.
    func hasNotifyRoute(matching tapped: RouteEvent) -> Bool {
        let candidates = routes.map(\.compiled).filter { route in
            guard case .notify = route.definition.action else { return false }
            return route.definition.on.matches(topic: tapped.topic)
        }
        guard !candidates.isEmpty else { return false }
        let event = resolved(tapped)
        let values = event.values
        let firesOnly = tapped.fields["kind"] == "permission"
        let at = now()
        return candidates.contains { route in
            guard route.definition.matches(event) else { return false }
            guard firesOnly else { return true }
            let key = gateKey(route.definition, values: values)
            return RouteGate.reduce(gates[key], .matched(event, now: at), route: route).1.contains {
                if case .fire = $0 { return true }
                return false
            }
        }
    }

    private func gateKey(_ definition: ProgramaRouteDefinition, values: [String: String]) -> GateKey {
        GateKey(route: definition.name, key: ProgramaConfigExecutor.substituteParameters(in: definition.key, values: values))
    }

    /// The tapped event plus the fields the model adds. Frame fields win.
    private func resolved(_ tapped: RouteEvent) -> RouteEvent {
        RouteEvent(topic: tapped.topic, fields: tapped.fields.merging(modelFields(tapped)) { frame, _ in frame })
    }

    /// Reports that `fire`'s delivery ended. `error` becomes the route's last error even when the
    /// delivery already expired; the gate moves only for the delivery the route still holds.
    func endDelivery(_ fire: RouteFire, error: String? = nil) {
        if let error {
            recordError(error, for: fire)
        }
        let gateKey = GateKey(route: fire.route.name, key: fire.key)
        guard deliveries[gateKey]?.id == fire.id else { return }
        apply(.deliveryEnded(now: now()), to: gateKey)
    }

    /// Reports that `fire`'s prompt was submitted: the route stays held until the turn it started
    /// ends, so a route on the idle edge cannot trigger itself.
    func turnStarted(_ fire: RouteFire) {
        let gateKey = GateKey(route: fire.route.name, key: fire.key)
        guard deliveries[gateKey]?.id == fire.id else { return }
        apply(.turnStarted, to: gateKey)
    }

    /// Sets the route's last error, unless the route set that fired has been replaced.
    func recordError(_ message: String, for fire: RouteFire) {
        guard fire.generation == generation,
              let index = routes.firstIndex(where: { $0.compiled.name == fire.route.name }) else { return }
        routes[index].lastError = message
    }

    private func apply(_ input: RouteGateInput, to gateKey: GateKey) {
        guard let index = routes.firstIndex(where: { $0.compiled.name == gateKey.route }) else { return }
        let route = routes[index].compiled
        let (next, effects) = RouteGate.reduce(gates[gateKey], input, route: route)
        gates[gateKey] = next
        let heldDelivery = deliveries.removeValue(forKey: gateKey)

        var fires: [RouteFire] = []
        for effect in effects {
            switch effect {
            case .fire(let event):
                lastFireId &+= 1
                fires.append(RouteFire(
                    id: lastFireId, route: route, key: gateKey.key, event: event, generation: generation
                ))
            case .wake(let date):
                let scheduledGeneration = generation
                scheduleWake(date) { [weak self] in
                    self?.wake(gateKey, at: date, generation: scheduledGeneration)
                }
            case .cancelDelivery:
                if let heldDelivery {
                    executor?.cancel(heldDelivery)
                }
            case .count(let counter):
                routes[index].counters.record(counter)
            }
        }
        if case .delivering = next {
            // The fire that started the delivery, or the one already holding it.
            deliveries[gateKey] = fires.last ?? heldDelivery
        }
        // After the gate state, deliveries and counters are stored, so a delivery that ends
        // inside `execute` reaches the state the fire left.
        for fire in fires {
            if let executor {
                executor.execute(fire, engine: self)
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
        fields["cwd"] = workspace.sidebarResolvedDirectory(for: surfaceId).flatMap(canonicalDirectory)
        fields["git_branch"] = workspace.panelGitBranches[surfaceId]?.branch
        return fields
    }

    /// `path` with symlinks and `..` resolved, or nil when it is not absolute or not an existing
    /// directory. A reported directory is shell-written and can be `/allowed/../../elsewhere`, so
    /// `when` and `run` see only this form.
    nonisolated static func canonicalDirectory(_ path: String) -> String? {
        guard path.hasPrefix("/"), let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        let canonical = String(cString: resolved)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canonical, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return canonical
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
    var deliversText: Bool {
        switch self {
        case .send, .prompt: return true
        case .notify, .run, .review: return false
        }
    }

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
