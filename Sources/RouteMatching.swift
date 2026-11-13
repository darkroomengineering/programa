import Foundation

/// An event as a route sees it: its topic and a flat map of string fields. An empty value is an
/// absent field, so `when` treats "" and a missing key alike.
struct RouteEvent: Sendable, Equatable {
    let topic: String
    let fields: [String: String]

    init(topic: String, fields: [String: String]) {
        self.topic = topic
        self.fields = fields.filter { !$0.value.isEmpty }
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

extension ProgramaRouteCondition {
    /// An absent field fails every condition except `ne` and `exists: false`.
    func holds(for value: String?) -> Bool {
        switch self {
        case .equals(let expected):
            return value == expected
        case .notEquals(let unexpected):
            return value != unexpected
        case .oneOf(let options):
            guard let value else { return false }
            return options.contains(value)
        case .exists(let expected):
            return (value != nil) == expected
        case .matches(let regex):
            guard let value else { return false }
            return regex.matches(value)
        }
    }
}

extension ProgramaRouteRegex {
    /// How much of a value a pattern sees, in UTF-16 units. Event fields carry agent-written text,
    /// and a slow pattern on a long body would run on the main thread.
    static let inputLimit = 4096

    /// A search, not a full match: the pattern may match anywhere in the first `inputLimit` units.
    func matches(_ value: String) -> Bool {
        let length = min((value as NSString).length, Self.inputLimit)
        return expression.firstMatch(in: value, range: NSRange(location: 0, length: length)) != nil
    }
}

extension ProgramaRouteDefinition {
    /// Topic first, then `when`. The key and the gate come after a match.
    func matches(_ event: RouteEvent) -> Bool {
        guard on.matches(topic: event.topic) else { return false }
        let values = event.values
        return when.allSatisfy { clause in
            clause.conditions.allSatisfy { $0.holds(for: values[clause.field]) }
        }
    }
}
