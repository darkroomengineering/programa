import Foundation

/// An event as a route sees it: its topic and a flat map of string fields. An empty value is an
/// absent field, so `when` treats "" and a missing key alike.
struct RouteEvent: Sendable, Equatable {
    let topic: String
    let fields: [String: String]
    /// Who made an agent report (`RouteEvent.writer(source:sessionKey:)`), or nil when the report
    /// named no session. Not a field: it never reaches `when`, templates or `run`'s environment.
    let writer: String?

    init(topic: String, fields: [String: String], writer: String? = nil) {
        self.topic = topic
        self.fields = fields.filter { !$0.value.isEmpty }
        self.writer = writer
    }

    /// The writer of one agent report, from that report's own source and session key, never
    /// from the presence it updates (a report without a key keeps the key an earlier report set).
    /// OSC 7501 is the program in the terminal; a hooks report is identified only by its session
    /// id. Screen inference and keyless hooks reports have no writer.
    static func writer(source: AgentStateSource?, sessionKey: AgentSessionKey?) -> String? {
        switch source {
        case .program:
            return "program"
        case .hooks:
            guard let sessionKey, let sessionId = sessionKey.sessionId, !sessionId.isEmpty else { return nil }
            return "hooks:\(sessionKey.provider):\(sessionId)"
        case .inferred, nil:
            return nil
        }
    }

    /// What `when` and templates can name: the fields plus `topic`.
    var values: [String: String] {
        var values = fields
        values["topic"] = topic
        return values
    }
}

extension ProgramaRouteTopicPattern {
    func matches(topic: String) -> Bool {
        let parts = topic.split(separator: "/", omittingEmptySubsequences: false)
        for (position, level) in levels.enumerated() {
            switch level {
            case .anyRest:
                // MQTT: `a/#` also matches its parent `a`.
                return true
            case .anyOne:
                guard position < parts.count else { return false }
            case .literal(let text):
                guard position < parts.count, parts[position] == text else { return false }
            }
        }
        return parts.count == levels.count
    }
}

enum RouteRegexResult: Sendable, Equatable {
    case matched
    case notMatched
    /// The event's regex budget (`ProgramaRouteRegex.eventBudget`) ran out before or during the
    /// match, so it was stopped or never started.
    case timedOut
}

/// When the regexes for one event must stop. One deadline is shared by every `when` regex of
/// every route matched against that event, so the main thread waits at most one budget per event
/// however many routes there are.
struct RouteRegexDeadline: Sendable {
    /// `ProcessInfo.systemUptime` past which no regex runs.
    let uptime: TimeInterval

    static func startingNow(budget: TimeInterval = ProgramaRouteRegex.eventBudget) -> RouteRegexDeadline {
        RouteRegexDeadline(uptime: ProcessInfo.processInfo.systemUptime + budget)
    }

    var hasPassed: Bool {
        ProcessInfo.processInfo.systemUptime > uptime
    }
}

/// The outcome of a route's topic and `when` against one event.
struct RouteMatchResult: Sendable, Equatable {
    var matches: Bool
    /// The `when` field whose regex was stopped, or skipped, because the event's regex budget ran
    /// out; that clause counts as unmet.
    var timedOutField: String?
}

extension ProgramaRouteCondition {
    /// An absent field fails every condition except `ne` and `exists: false`.
    func evaluate(for value: String?, until deadline: RouteRegexDeadline) -> RouteRegexResult {
        switch self {
        case .equals(let expected):
            return value == expected ? .matched : .notMatched
        case .notEquals(let unexpected):
            return value != unexpected ? .matched : .notMatched
        case .oneOf(let options):
            guard let value else { return .notMatched }
            return options.contains(value) ? .matched : .notMatched
        case .exists(let expected):
            return (value != nil) == expected ? .matched : .notMatched
        case .matches(let regex):
            guard let value else { return .notMatched }
            return regex.evaluate(value, until: deadline)
        }
    }

    func holds(for value: String?) -> Bool {
        evaluate(for: value, until: .startingNow()) == .matched
    }
}

extension ProgramaRouteRegex {
    /// How much of a value a pattern sees, in UTF-16 units. Event fields carry agent-written text.
    static let inputLimit = 4096
    /// How long all the `when` regexes of all routes may run, together, for one event. Matching
    /// runs on the main thread, and no lint catches every pattern that backtracks exponentially
    /// (`^(a|aa)+$`, `(a|a)+b`, `(.*,){10}x`), so matching itself is bounded: ICU calls the
    /// progress block periodically while it works, and the block stops it past the event's
    /// `RouteRegexDeadline`. A regex reached after the deadline does not start.
    static let eventBudget: TimeInterval = 0.05

    /// A search, not a full match: the pattern may match anywhere in the first `inputLimit` units.
    func evaluate(_ value: String, until deadline: RouteRegexDeadline = .startingNow()) -> RouteRegexResult {
        guard !deadline.hasPassed else { return .timedOut }
        let length = min((value as NSString).length, Self.inputLimit)
        var result = RouteRegexResult.notMatched
        expression.enumerateMatches(
            in: value,
            options: [.reportProgress],
            range: NSRange(location: 0, length: length)
        ) { match, _, stop in
            if match != nil {
                result = .matched
                stop.pointee = true
            } else if deadline.hasPassed {
                result = .timedOut
                stop.pointee = true
            }
        }
        return result
    }

    func matches(_ value: String) -> Bool {
        evaluate(value) == .matched
    }
}

extension ProgramaRouteDefinition {
    /// Topic first, then `when`. The key and the gate come after a match. `deadline` is the
    /// event's, shared with every other route evaluated for it.
    func evaluate(_ event: RouteEvent, until deadline: RouteRegexDeadline) -> RouteMatchResult {
        guard on.matches(topic: event.topic) else { return RouteMatchResult(matches: false) }
        let values = event.values
        for clause in when {
            for condition in clause.conditions {
                switch condition.evaluate(for: values[clause.field], until: deadline) {
                case .matched:
                    continue
                case .notMatched:
                    return RouteMatchResult(matches: false)
                case .timedOut:
                    return RouteMatchResult(matches: false, timedOutField: clause.field)
                }
            }
        }
        return RouteMatchResult(matches: true)
    }

    func matches(_ event: RouteEvent) -> Bool {
        evaluate(event, until: .startingNow()).matches
    }
}
