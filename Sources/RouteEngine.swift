import Foundation

// The event-route engine (docs/plans/event-routes.md): the broadcaster's tap hands it each
// `agent_state`, `needs_input` and `workspace_lifecycle` frame, it resolves the fields the frame
// lacks, matches the installed routes and drives one `RouteGate` per (route name, key).

/// A reported directory with symlinks and `..` resolved, tied to the report it came from.
struct ResolvedPanelDirectory: Equatable, Sendable {
    let reported: String
    let resolved: String?
}

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
    /// the end of that work (an idle after `working` from the same writer). Deliver it now, then
    /// call `endDelivery`, or `turnStarted` for a submitted prompt.
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

    /// What text deliveries need from one surface's recent agent reports. Built from the frames
    /// the tap delivers; at each install it starts from the surfaces blocked at that moment.
    private struct AgentTrack {
        enum Resume: Equatable {
            case free
            /// After the agent stops for the person (a `blocked` report or an `agent.needs_input`
            /// call), deliveries wait for a `working` report from the writer of that stop (or of
            /// the last `working` before it, when the stop named none), or from the program itself:
            /// Programa's hooks report a prompt over the socket while the program's own OSC 7501
            /// status owns the presence and reports the `working` after it. With no writer known,
            /// only the program resumes it.
            ///
            /// `since` is the stop's `ts`. A `working` report stamped earlier was published before
            /// the stop and reached the engine late (the tap delivers asynchronously, while
            /// `agent.needs_input` records its stop in its own hop), so it is ignored.
            case awaitingWorking(from: String?, since: Double?)
        }

        /// Writer of the latest `working` report; nil when it named no session.
        var lastWorkingWriter: String?
        var resume = Resume.free
    }

    private let tap: RouteTap?
    private let now: @MainActor () -> Date
    private let scheduleWake: @MainActor (Date, @escaping @MainActor () -> Void) -> Void
    private let modelFields: @MainActor (RouteEvent) -> [String: String]
    /// Runs actions fired while an `agent.needs_input` call is ingested, after that call's hop.
    private let deferWork: @MainActor (@escaping @MainActor () -> Void) -> Void
    /// Surfaces whose agent is `blocked` right now, each with the writer of its route view (nil
    /// when the view names none).
    private let blockedSurfaces: @MainActor () -> [(id: String, writer: String?)]
    /// Collects fires instead of running them, while `ingestNeedsInput` holds the hop.
    private var deferredFires: [RouteFire]?

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
    /// Keyed by surface id.
    private var agentTracks: [String: AgentTrack] = [:]
    /// Bumped on every install, so wakes and delivery ends from an older route set are ignored.
    private var generation: UInt64 = 0

    init(
        tap: RouteTap? = nil,
        now: @escaping @MainActor () -> Date = Date.init,
        scheduleWake: @escaping @MainActor (Date, @escaping @MainActor () -> Void) -> Void = RouteEngine.scheduleOnMain(at:_:),
        modelFields: @escaping @MainActor (RouteEvent) -> [String: String] = RouteEngine.resolveModelFields(for:),
        deferWork: @escaping @MainActor (@escaping @MainActor () -> Void) -> Void = RouteEngine.runOnMainLater(_:),
        blockedSurfaces: @escaping @MainActor () -> [(id: String, writer: String?)] = RouteEngine.blockedSurfaceWriters
    ) {
        self.tap = tap
        self.now = now
        self.scheduleWake = scheduleWake
        self.modelFields = modelFields
        self.deferWork = deferWork
        self.blockedSurfaces = blockedSurfaces
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
        // Stops from before this install were never seen: a surface blocked now waits for a
        // `working` from its route view's writer, or from the program when the view names none.
        agentTracks = Dictionary(
            blockedSurfaces().map { ($0.id, AgentTrack(resume: .awaitingWorking(from: $0.writer, since: nil))) },
            uniquingKeysWith: { first, _ in first }
        )
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

    /// Matches the routes, then settles the text deliveries that were already held on the
    /// event's surface, then records the report. In that order, the idle that ends a prompt's own
    /// turn is still inside that turn when the routes see it, and a delivery this very event fired
    /// is not handed back as "went idle".
    func ingest(_ tapped: RouteEvent) {
        let heldBefore = Set(deliveries.values.map(\.id))
        match(tapped)
        settleTextDeliveries(after: tapped, heldBefore: heldBefore)
        track(tapped)
    }

    /// Feeds every matching route's gate. Returns the names of the `notify` routes that matched.
    @discardableResult
    private func match(_ tapped: RouteEvent) -> [String] {
        let candidates = routes.indices.filter { routes[$0].compiled.definition.on.matches(topic: tapped.topic) }
        guard !candidates.isEmpty else { return [] }
        let event = resolved(tapped)
        let values = event.values
        let at = now()
        let surfaceId = event.fields["surface_id"]
        var notifyMatches: [String] = []
        let regexDeadline = RouteRegexDeadline.startingNow()
        for index in candidates {
            let result = routes[index].compiled.definition.evaluate(event, until: regexDeadline)
            if let field = result.timedOutField {
                routes[index].lastError = "when.\(field): the regex ran longer than \(Int(ProgramaRouteRegex.eventBudget * 1000)) ms and was stopped; the event did not match"
            }
            guard result.matches else { continue }
            routes[index].counters.matched += 1
            if case .notify = routes[index].compiled.definition.action {
                notifyMatches.append(routes[index].compiled.name)
            }
            // While a route's prompt holds the surface for its turn, including the idle that ends
            // it, no prompt route takes an event from it, so two prompt routes cannot feed each
            // other. Checked per route: an earlier route in this pass may have just submitted.
            if case .prompt = routes[index].compiled.definition.action,
               let surfaceId, routeTurnIsOpen(onSurface: surfaceId) {
                routes[index].counters.record(.busy)
                continue
            }
            apply(.matched(event, now: at), to: gateKey(routes[index].compiled.definition, values: values))
        }
        return notifyMatches
    }

    /// Whether a route's prompt holds `surfaceId` for its turn. A prompt is checked again right
    /// before it is delivered, since a debounced or queued one fires after its match.
    func routeTurnIsOpen(onSurface surfaceId: String) -> Bool {
        deliveries.contains { gateKey, fire in
            guard fire.event.fields["surface_id"] == surfaceId,
                  case .delivering(.ownTurn, _, _) = gates[gateKey] else { return false }
            return true
        }
    }

    /// On the event's surface: an idle that follows a `working` report from the same identified
    /// writer delivers the queued `send`s and `prompt`s and ends the prompt turns that saw
    /// `working`; a `working` report marks the open turns; a clear ends everything, since the agent
    /// is gone. Any other report leaves the deliveries waiting until they expire.
    private func settleTextDeliveries(after event: RouteEvent, heldBefore: Set<UInt64>) {
        guard event.topic.hasPrefix("agent/"), let surfaceId = event.fields["surface_id"] else { return }
        let state = event.topic.split(separator: "/").last.map(String.init)
        let isStateReport = event.topic.hasPrefix("agent/\(surfaceId)/state/")
        guard isStateReport, let state, ["idle", "none", "working"].contains(state) else { return }
        let releases = state == "idle" && releasesTextDeliveries(event, onSurface: surfaceId)
        for (gateKey, fire) in deliveries
        where heldBefore.contains(fire.id) && fire.event.fields["surface_id"] == surfaceId {
            // An earlier settle in this loop can have moved this gate on.
            guard deliveries[gateKey]?.id == fire.id,
                  case .delivering(let delivery, _, _) = gates[gateKey] else { continue }
            switch (delivery, state) {
            case (.running, _):
                continue
            case (.ownTurn, "none"):
                endDelivery(fire)
            case (.ownTurn(sawWorking: false), "working"):
                if event.writer != nil { apply(.turnWorking, to: gateKey) }
            case (.ownTurn(sawWorking: true), "idle") where releases:
                endDelivery(fire)
            case (.waitingForIdle, "none"):
                endDelivery(fire, error: "the agent stopped before the text was delivered")
            case (.waitingForIdle, "idle") where releases:
                if let executor {
                    executor.targetWentIdle(fire, engine: self)
                } else {
                    endDelivery(fire)
                }
            default:
                continue
            }
        }
    }

    /// Whether `idle` is the end of real work: it follows a `working` report, and both came from
    /// the same identified writer, with no permission prompt still waiting on that agent.
    private func releasesTextDeliveries(_ idle: RouteEvent, onSurface surfaceId: String) -> Bool {
        guard let writer = idle.writer, idle.fields["previous_state"] == "working",
              let track = agentTracks[surfaceId] else { return false }
        return track.lastWorkingWriter == writer && track.resume == .free
    }

    /// Records the report for later text deliveries on its surface.
    private func track(_ event: RouteEvent) {
        let levels = event.topic.split(separator: "/").map(String.init)
        guard levels.count == 4, levels[0] == "agent" else { return }
        let surfaceId = levels[1]
        var track = agentTracks[surfaceId] ?? AgentTrack()
        switch (levels[2], levels[3]) {
        case ("state", "none"):
            agentTracks.removeValue(forKey: surfaceId)
            return
        case ("state", "working"):
            if case .awaitingWorking(let from, let since) = track.resume {
                if let since, let ts = event.fields["ts"].flatMap(Double.init), ts < since { return }
                if let writer = event.writer, writer == from || writer == "program" {
                    track.resume = .free
                }
            }
            track.lastWorkingWriter = event.writer
        case ("state", "blocked"), ("needs_input", _):
            // Any stop for the person, whatever its kind: failing closed costs one `working`.
            track.resume = .awaitingWorking(
                from: event.writer ?? track.lastWorkingWriter,
                since: event.fields["ts"].flatMap(Double.init)
            )
        default:
            break
        }
        agentTracks[surfaceId] = track
    }

    /// Why a `send` or `prompt` must not go into `surfaceId` now, from the reports the engine saw.
    func textDeliveryRefusal(surfaceId: String) -> String? {
        if case .awaitingWorking = agentTracks[surfaceId]?.resume {
            return "refused: waiting for the agent to resume after it stopped for input"
        }
        return nil
    }

    /// Whether `fire` belongs to the routes installed now.
    func isCurrent(_ fire: RouteFire) -> Bool {
        fire.generation == generation
    }

    /// Ingests an `agent.needs_input` call inside the call's own main-thread hop and returns
    /// whether its built-in banner gives way to a `notify` route. Deciding and moving the gates in
    /// one step means a burst of calls sharing a throttle window cannot all hide their banners
    /// behind one route notification. The actions it fires run after the hop, so a route's
    /// notification lands after the built-in entry.
    ///
    /// A question gives way whenever a `notify` route matches it on topic and `when`, throttled or
    /// not, so "once per 5 minutes" is what the person sees. Any other call, a permission prompt or
    /// one with no kind, gives way only when a `notify` route fires for this very call.
    func ingestNeedsInput(_ tapped: RouteEvent) -> Bool {
        deferredFires = []
        let heldBefore = Set(deliveries.values.map(\.id))
        let notifyMatches = match(tapped)
        settleTextDeliveries(after: tapped, heldBefore: heldBefore)
        track(tapped)
        let fires = deferredFires ?? []
        deferredFires = nil
        if !fires.isEmpty {
            // A fire that holds a delivery runs only if the delivery is still the one this call
            // started: a releasing report handled before this block may have delivered it already.
            let firedStates = fires.map { ($0, gates[GateKey(route: $0.route.name, key: $0.key)]) }
            deferWork { [weak self] in
                guard let self else { return }
                for (fire, firedState) in firedStates where self.isCurrent(fire) {
                    if fire.route.deliveryTimeout != nil {
                        let gateKey = GateKey(route: fire.route.name, key: fire.key)
                        guard self.deliveries[gateKey]?.id == fire.id, self.gates[gateKey] == firedState else { continue }
                    }
                    self.execute(fire)
                }
            }
        }
        let fired = Set(fires.map(\.route.name))
        let question = tapped.fields["kind"] == "question"
        return notifyMatches.contains { question || fired.contains($0) }
    }

    /// Counts a fire whose action did not run because a route's prompt holds its surface.
    func recordBusy(_ fire: RouteFire) {
        guard isCurrent(fire), let index = routes.firstIndex(where: { $0.compiled.name == fire.route.name }) else { return }
        routes[index].counters.record(.busy)
    }

    private func gateKey(_ definition: ProgramaRouteDefinition, values: [String: String]) -> GateKey {
        GateKey(route: definition.name, key: ProgramaConfigExecutor.substituteParameters(in: definition.key, values: values))
    }

    /// The tapped event plus the fields the model adds. Frame fields win.
    private func resolved(_ tapped: RouteEvent) -> RouteEvent {
        RouteEvent(
            topic: tapped.topic,
            fields: tapped.fields.merging(modelFields(tapped)) { frame, _ in frame },
            writer: tapped.writer
        )
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
    /// ends (an idle after a `working` report in that turn, or a clear), so a route on the idle
    /// edge cannot trigger itself.
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
            if deferredFires != nil {
                deferredFires?.append(fire)
            } else {
                execute(fire)
            }
        }
    }

    private func execute(_ fire: RouteFire) {
        if let executor {
            executor.execute(fire, engine: self)
        } else if fire.route.deliveryTimeout != nil {
            endDelivery(fire)
        }
    }

    private func wake(_ gateKey: GateKey, at scheduled: Date, generation scheduledGeneration: UInt64) {
        guard scheduledGeneration == generation else { return }
        // The timer runs on uptime and the gate compares wall-clock dates: a wake a moment early
        // would be a no-op and leave a debounced event pending.
        apply(.wake(now: max(now(), scheduled)), to: gateKey)
    }

    // MARK: - Production seams

    static func blockedSurfaceWriters() -> [(id: String, writer: String?)] {
        guard let contexts = AppDelegate.shared?.mainWindowContexts.values else { return [] }
        return contexts.flatMap { $0.tabManager.tabs }.flatMap { workspace in
            // The route view when there is one: an unsigned OSC 7501 report can own the badge, so
            // the writer never comes from the presence itself.
            workspace.panelAgentPresence.compactMap { entry -> (id: String, writer: String?)? in
                let route = entry.value.route
                guard (route?.state ?? entry.value.state) == .blocked else { return nil }
                let writer = route.flatMap {
                    RouteEvent.writer(source: $0.source, sessionKey: $0.sessionKey, programVerified: $0.source == .program)
                }
                return (id: entry.key.uuidString, writer: writer)
            }
        }
    }

    static func runOnMainLater(_ body: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated { body() } }
    }

    static func scheduleOnMain(at date: Date, _ body: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, date.timeIntervalSinceNow)) {
            MainActor.assumeIsolated { body() }
        }
    }

    /// Fields an `agent/#` event takes from the model: the surface's directory and branch, and
    /// whether its workspace came from `worktree.create` or `worktree.open`. The directory is the
    /// one resolved off main when it was reported, so nothing here touches the file system.
    static func resolveModelFields(for event: RouteEvent) -> [String: String] {
        guard event.topic.hasPrefix("agent/"),
              let workspaceId = event.fields["workspace_id"].flatMap(UUID.init(uuidString:)),
              let surfaceId = event.fields["surface_id"].flatMap(UUID.init(uuidString:)),
              let workspace = AppDelegate.shared?.workspaceFor(tabId: workspaceId) else { return [:] }
        var fields = ["worktree": (workspace.worktreeBranch ?? "").isEmpty ? "false" : "true"]
        fields["cwd"] = workspace.resolvedRouteDirectory(for: surfaceId)
        fields["git_branch"] = workspace.panelGitBranches[surfaceId]?.branch
        return fields
    }

    /// `path` with symlinks and `..` resolved, or nil when it is not absolute or not an existing
    /// directory. A reported directory is shell-written and can be `/allowed/../../elsewhere`, so
    /// `when` and `run` see only this form. Touches the file system, which can stall on a network
    /// mount: call it off main.
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

    func ingest(_ frame: [String: Any], previousState: AgentActivityState? = nil, writer: String? = nil) {
        guard let event = RouteEvent(frame: frame, previousState: previousState, writer: writer) else { return }
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
    init?(frame: [String: Any], previousState: AgentActivityState? = nil, writer: String? = nil) {
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
        self.init(topic: topic, fields: fields, writer: writer)
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
