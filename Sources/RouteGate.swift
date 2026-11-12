import Foundation

/// A route with its timings resolved for the gate.
struct CompiledRoute: Sendable, Equatable {
    static let defaultDeliveryTimeout: TimeInterval = 600

    let definition: ProgramaRouteDefinition
    /// nil when unset or zero.
    let debounce: TimeInterval?
    /// nil when unset or zero.
    let throttle: TimeInterval?
    /// How long a delivery may hold the route before it is cancelled; nil for `notify` and
    /// `review`, which finish when they fire.
    let deliveryTimeout: TimeInterval?

    init(_ definition: ProgramaRouteDefinition) {
        self.definition = definition
        debounce = Self.seconds(definition.debounceMs)
        throttle = Self.seconds(definition.throttleMs)
        switch definition.action {
        case .notify, .review:
            deliveryTimeout = nil
        case .run(_, let timeoutMs):
            deliveryTimeout = Self.seconds(timeoutMs) ?? Self.defaultDeliveryTimeout
        case .send, .prompt:
            deliveryTimeout = Self.defaultDeliveryTimeout
        }
    }

    var name: String { definition.name }

    fileprivate func delivery(for event: RouteEvent) -> RouteDelivery {
        if case .run = definition.action { return .running }
        return .waitingForIdle(event)
    }

    private static func seconds(_ milliseconds: Int?) -> TimeInterval? {
        guard let milliseconds, milliseconds > 0 else { return nil }
        return TimeInterval(milliseconds) / 1000
    }
}

/// The gate for one (route name, key). An absent entry is the idle state.
enum RouteGateState: Sendable, Equatable {
    case debouncing(pending: RouteEvent, deadline: Date, cooldownUntil: Date?)
    case delivering(RouteDelivery, expiresAt: Date, cooldownUntil: Date?)
    case coolingDown(until: Date)
}

enum RouteDelivery: Sendable, Equatable {
    /// `run`: the process is alive.
    case running
    /// `send`/`prompt`: the text has not reached the agent yet.
    case waitingForIdle(RouteEvent)
    /// `prompt` delivered: the turn it started is open.
    case ownTurn
}

enum RouteGateInput: Sendable, Equatable {
    case matched(RouteEvent, now: Date)
    case wake(now: Date)
    case deliveryEnded(now: Date)
}

enum RouteCounter: String, Sendable, Equatable {
    case fired
    case throttled
    case busy
    case expired
}

enum RouteGateEffect: Sendable, Equatable {
    case fire(RouteEvent)
    case wake(at: Date)
    case cancelDelivery
    case count(RouteCounter)
}

/// The rate limit and in-flight rule for routes, as one pure reducer. It never reads the clock:
/// `now` arrives with each input. A wake that comes early or for a state that moved on is a
/// no-op, so scheduled wakes need no cancellation.
enum RouteGate {
    static func reduce(
        _ state: RouteGateState?,
        _ input: RouteGateInput,
        route: CompiledRoute
    ) -> (RouteGateState?, [RouteGateEffect]) {
        switch (state, input) {
        case (nil, .matched(let event, let now)):
            return admit(event, now: now, cooldownUntil: nil, route: route)
        case (nil, .wake), (nil, .deliveryEnded):
            return (nil, [])

        case (.debouncing(_, _, let cooldownUntil), .matched(let event, let now)):
            let deadline = now.addingTimeInterval(route.debounce ?? 0)
            return (
                .debouncing(pending: event, deadline: deadline, cooldownUntil: cooldownUntil),
                [.wake(at: deadline)]
            )
        case (.debouncing(let pending, let deadline, let cooldownUntil), .wake(let now)):
            guard now >= deadline else { return (state, []) }
            if let cooldownUntil, cooldownUntil > now {
                return (.coolingDown(until: cooldownUntil), [.count(.throttled), .wake(at: cooldownUntil)])
            }
            return fire(pending, now: now, route: route)
        case (.debouncing, .deliveryEnded):
            return (state, [])

        case (.coolingDown(let until), .matched(let event, let now)):
            if now >= until {
                return admit(event, now: now, cooldownUntil: nil, route: route)
            }
            if route.debounce != nil {
                return admit(event, now: now, cooldownUntil: until, route: route)
            }
            return (state, [.count(.throttled)])
        case (.coolingDown(let until), .wake(let now)):
            return now >= until ? (nil, []) : (state, [])
        case (.coolingDown, .deliveryEnded):
            return (state, [])

        case (.delivering, .matched):
            return (state, [.count(.busy)])
        case (.delivering(_, _, let cooldownUntil), .deliveryEnded(let now)):
            return settle(cooldownUntil: cooldownUntil, now: now)
        case (.delivering(_, let expiresAt, let cooldownUntil), .wake(let now)):
            guard now >= expiresAt else { return (state, []) }
            let (next, effects) = settle(cooldownUntil: cooldownUntil, now: now)
            return (next, [.cancelDelivery, .count(.expired)] + effects)
        }
    }

    /// A match the gate may take: debounce it, or fire it now.
    private static func admit(
        _ event: RouteEvent,
        now: Date,
        cooldownUntil: Date?,
        route: CompiledRoute
    ) -> (RouteGateState?, [RouteGateEffect]) {
        guard let debounce = route.debounce else {
            return fire(event, now: now, route: route)
        }
        let deadline = now.addingTimeInterval(debounce)
        return (
            .debouncing(pending: event, deadline: deadline, cooldownUntil: cooldownUntil),
            [.wake(at: deadline)]
        )
    }

    /// Fires and starts the throttle window. Actions that take time hold the route until they
    /// end or expire; the others go straight to the cooldown, or to idle without a throttle.
    private static func fire(
        _ event: RouteEvent,
        now: Date,
        route: CompiledRoute
    ) -> (RouteGateState?, [RouteGateEffect]) {
        let cooldownUntil = route.throttle.map { now.addingTimeInterval($0) }
        var effects: [RouteGateEffect] = [.fire(event), .count(.fired)]
        if let timeout = route.deliveryTimeout {
            let expiresAt = now.addingTimeInterval(timeout)
            effects.append(.wake(at: expiresAt))
            return (
                .delivering(route.delivery(for: event), expiresAt: expiresAt, cooldownUntil: cooldownUntil),
                effects
            )
        }
        guard let cooldownUntil else { return (nil, effects) }
        effects.append(.wake(at: cooldownUntil))
        return (.coolingDown(until: cooldownUntil), effects)
    }

    /// Where a finished delivery leaves the route: cooling down while the window lasts, else idle.
    private static func settle(cooldownUntil: Date?, now: Date) -> (RouteGateState?, [RouteGateEffect]) {
        guard let cooldownUntil, cooldownUntil > now else { return (nil, []) }
        return (.coolingDown(until: cooldownUntil), [.wake(at: cooldownUntil)])
    }
}
