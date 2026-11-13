import Foundation

// The `routes` block of programa.json (docs/plans/event-routes.md). Decoding is lossy per route:
// a route that fails to decode or validate becomes a `ProgramaRouteIssue`, and every other route,
// command and recipe in the file still loads.

/// One `routes` entry that did not load. `index` is the entry's position in the array, or nil
/// when `routes` itself is not an array.
struct ProgramaRouteIssue: Sendable, Equatable {
    var index: Int?
    var name: String?
    var message: String
}

struct ProgramaRouteDefinition: Sendable, Equatable {
    static let defaultKey = "{{topic}}"
    static let minimumPromptThrottleMs = 60_000

    var name: String
    var on: ProgramaRouteTopicPattern
    /// Every clause must hold. Sorted by field so a reload of the same file compares equal.
    var when: [ProgramaRouteClause]
    var debounceMs: Int?
    var throttleMs: Int?
    var key: String
    var action: ProgramaRouteAction
}

enum ProgramaRouteAction: Sendable, Equatable {
    case notify(title: String, subtitle: String?, body: String?)
    case send(text: String, whenBusy: ProgramaRouteWhenBusy)
    case prompt(text: String, whenBusy: ProgramaRouteWhenBusy)
    case run(command: String, timeoutMs: Int?)
    case review(mode: ReviewDiffMode?, baseBranch: String?)
}

enum ProgramaRouteWhenBusy: String, Sendable, Equatable, CaseIterable {
    case queue
    case steer
}

/// An MQTT-style topic filter: `+` matches exactly one level, `#` (last level only) the rest.
struct ProgramaRouteTopicPattern: Sendable, Equatable {
    enum Level: Sendable, Equatable {
        case literal(String)
        case anyOne
        case anyRest
    }

    let text: String
    let levels: [Level]

    init(parsing text: String) throws {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        var levels: [Level] = []
        for (position, part) in parts.enumerated() {
            switch part {
            case "":
                throw ProgramaRouteValidationError("'on' has an empty level: '\(text)'")
            case "+":
                levels.append(.anyOne)
            case "#":
                guard position == parts.count - 1 else {
                    throw ProgramaRouteValidationError("'on' may use '#' only as the last level: '\(text)'")
                }
                levels.append(.anyRest)
            default:
                guard !part.contains("+"), !part.contains("#") else {
                    throw ProgramaRouteValidationError("'on' level '\(part)' mixes a wildcard with text: '\(text)'")
                }
                levels.append(.literal(part))
            }
        }
        // `output` frames are polled only for surfaces a socket client subscribes to, so no
        // `surface` topic exists in v1.
        if levels.first == .literal("surface") {
            throw ProgramaRouteValidationError("'on' cannot match 'surface' topics: '\(text)'")
        }
        self.text = text
        self.levels = levels
    }
}

struct ProgramaRouteClause: Sendable, Equatable {
    var field: String
    /// Every condition must hold.
    var conditions: [ProgramaRouteCondition]
}

enum ProgramaRouteCondition: Sendable, Equatable {
    case equals(String)
    case notEquals(String)
    case oneOf([String])
    case exists(Bool)
    case matches(ProgramaRouteRegex)
}

/// A `when` regex, compiled when the file loads so a bad pattern is a load issue.
/// `NSRegularExpression` is immutable and safe to share across threads.
struct ProgramaRouteRegex: @unchecked Sendable, Equatable {
    let pattern: String
    let flags: String
    let expression: NSRegularExpression

    init(pattern: String, flags: String) throws {
        var options: NSRegularExpression.Options = []
        for flag in flags {
            switch flag {
            case "i": options.insert(.caseInsensitive)
            case "m": options.insert(.anchorsMatchLines)
            case "s": options.insert(.dotMatchesLineSeparators)
            case "x": options.insert(.allowCommentsAndWhitespace)
            default:
                throw ProgramaRouteValidationError("unknown regex flag '\(flag)'; use i, m, s or x")
            }
        }
        if Self.nestsQuantifiers(pattern) {
            throw ProgramaRouteValidationError(
                "regex '\(pattern)' repeats a group that already repeats, which can take exponential time; rewrite it without the nested quantifier"
            )
        }
        do {
            expression = try NSRegularExpression(pattern: pattern, options: options)
        } catch {
            throw ProgramaRouteValidationError("invalid regex '\(pattern)'")
        }
        self.pattern = pattern
        self.flags = flags
    }

    static func == (lhs: ProgramaRouteRegex, rhs: ProgramaRouteRegex) -> Bool {
        lhs.pattern == rhs.pattern && lhs.flags == rhs.flags
    }

    /// Whether a group that contains `*`, `+` or an open-ended `{n,}`/`{n,m}` is itself repeated
    /// that way, as in `(a+)+` or `((ab)*c)*`: the shape that backtracks exponentially on a
    /// near-miss. Escaped characters and bracket expressions are skipped.
    static func nestsQuantifiers(_ pattern: String) -> Bool {
        let characters = Array(pattern)
        // One entry per open group: whether its contents repeat.
        var groups: [Bool] = []
        var closedGroupRepeats = false
        var index = 0
        while index < characters.count {
            let character = characters[index]
            switch character {
            case "\\":
                index += 2
                closedGroupRepeats = false
                continue
            case "[":
                index = Self.indexAfterBracketExpression(characters, from: index)
                closedGroupRepeats = false
                continue
            case "(":
                groups.append(false)
                closedGroupRepeats = false
            case ")":
                let repeats = groups.popLast() ?? false
                if repeats, !groups.isEmpty { groups[groups.count - 1] = true }
                closedGroupRepeats = repeats
                index += 1
                continue
            case "*", "+", "{":
                let isQuantifier = character != "{" || Self.isRangeQuantifier(characters, at: index)
                if isQuantifier {
                    if closedGroupRepeats { return true }
                    if !groups.isEmpty { groups[groups.count - 1] = true }
                }
                closedGroupRepeats = false
            default:
                closedGroupRepeats = false
            }
            index += 1
        }
        return false
    }

    /// `{n,}` or `{n,m}`: a repetition with a range. `{n}` repeats a fixed number of times.
    private static func isRangeQuantifier(_ characters: [Character], at index: Int) -> Bool {
        guard let close = characters[index...].firstIndex(of: "}") else { return false }
        let body = characters[(index + 1)..<close]
        return body.contains(",") && body.allSatisfy { $0.isNumber || $0 == "," }
    }

    private static func indexAfterBracketExpression(_ characters: [Character], from start: Int) -> Int {
        var index = start + 1
        if index < characters.count, characters[index] == "^" { index += 1 }
        // A `]` right after `[` or `[^` is a literal.
        if index < characters.count, characters[index] == "]" { index += 1 }
        while index < characters.count {
            if characters[index] == "\\" { index += 2; continue }
            if characters[index] == "]" { return index + 1 }
            index += 1
        }
        return index
    }
}

struct ProgramaRouteValidationError: Error, Equatable {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}

/// The fields a route can name in `when` and in templates, and their trust class. Free text is
/// agent-authored or path-like, so it never goes into text a route sends to an agent.
enum ProgramaRouteField {
    enum Trust: Sendable, Equatable {
        case identifier
        case freeText
    }

    static let identifiers: Set<String> = [
        "topic", "workspace_id", "surface_id", "state", "previous_state", "source", "kind",
        "worktree", "ts",
    ]
    /// `provider` is whatever the agent's hook passed to `agent.needs_input`, so it is free text.
    static let freeText: Set<String> = ["title", "subtitle", "body", "provider", "cwd", "git_branch"]
    static let programStatusPrefix = "program_status."

    static func trust(of field: String) -> Trust? {
        if identifiers.contains(field) { return .identifier }
        if freeText.contains(field) { return .freeText }
        if field.hasPrefix(programStatusPrefix), field.count > programStatusPrefix.count { return .freeText }
        return nil
    }

    /// The `{{name}}` placeholders in `template`, parsed as
    /// `ProgramaConfigExecutor.substituteParameters` parses them.
    static func placeholders(in template: String) -> [String] {
        guard template.contains("{{"),
              let regex = try? NSRegularExpression(pattern: "\\{\\{([^{}]*)\\}\\}") else { return [] }
        let nsTemplate = template as NSString
        return regex.matches(in: template, range: NSRange(location: 0, length: nsTemplate.length)).map {
            nsTemplate.substring(with: $0.range(at: 1)).trimmingCharacters(in: .whitespaces)
        }
    }

    /// Every placeholder must name a known field; text bound for an agent may name identifiers only.
    static func validateTemplate(_ template: String, at path: String, agentBound: Bool = false) throws {
        for name in placeholders(in: template) {
            switch trust(of: name) {
            case nil:
                throw ProgramaRouteValidationError("'\(path)' names unknown field '\(name)'")
            case .freeText where agentBound:
                throw ProgramaRouteValidationError(
                    "'\(path)' names free-text field '\(name)'; text sent to an agent may use identifier fields only"
                )
            default:
                continue
            }
        }
    }
}

/// `debounceMs`, `throttleMs` and `run.timeoutMs` take a number of milliseconds or a duration
/// string: a number with an optional `ms`, `s`, `m` or `h` suffix ("250ms", "4s", "1.5m", "5m").
enum ProgramaRouteDuration {
    static func milliseconds(parsing text: String) -> Int? {
        let units: [(suffix: String, factor: Double)] = [("ms", 1), ("s", 1_000), ("m", 60_000), ("h", 3_600_000)]
        var number = Substring(text)
        var factor = 1.0
        for unit in units where text.hasSuffix(unit.suffix) {
            number = text.dropLast(unit.suffix.count)
            factor = unit.factor
            break
        }
        guard let first = number.first, let last = number.last,
              first.isASCII, first.isNumber, last.isASCII, last.isNumber,
              number.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
              number.filter({ $0 == "." }).count <= 1,
              let value = Double(number) else { return nil }
        return Int(exactly: (value * factor).rounded())
    }
}

// MARK: - Decoding

/// A key for objects whose keys are data (`when` fields and their operators).
private struct ProgramaRouteDynamicKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        nil
    }
}

/// A `when` value compared as text: a string, a number as its decimal string, or a boolean as
/// `true`/`false`.
private struct ProgramaRouteScalar: Decodable {
    let text: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            text = string
        } else if let integer = try? container.decode(Int.self) {
            text = String(integer)
        } else if let double = try? container.decode(Double.self) {
            text = String(double)
        } else if let bool = try? container.decode(Bool.self) {
            text = bool ? "true" : "false"
        } else {
            throw DecodingError.typeMismatch(
                String.self,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Expected a string, number or boolean"
                )
            )
        }
    }
}

extension ProgramaRouteDefinition: Decodable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case name, on, when, debounceMs, throttleMs, key
        case notify, send, prompt, run, review
    }

    private static let actionKeys: [CodingKeys] = [.notify, .send, .prompt, .run, .review]

    private enum NotifyKeys: String, CodingKey { case title, subtitle, body }
    private enum TextKeys: String, CodingKey { case text, whenBusy }
    private enum RunKeys: String, CodingKey { case command, timeoutMs }
    private enum ReviewKeys: String, CodingKey { case mode, baseBranch }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(String.self, forKey: .name)
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProgramaRouteValidationError("'name' must not be blank")
        }
        let on = try ProgramaRouteTopicPattern(parsing: container.decode(String.self, forKey: .on))
        let when: [ProgramaRouteClause]
        if container.contains(.when), try !container.decodeNil(forKey: .when) {
            when = try Self.decodeWhen(from: container.superDecoder(forKey: .when))
        } else {
            when = []
        }
        let debounceMs = try Self.decodeDuration(container, .debounceMs)
        let throttleMs = try Self.decodeDuration(container, .throttleMs)
        let key = try container.decodeIfPresent(String.self, forKey: .key) ?? Self.defaultKey
        try ProgramaRouteField.validateTemplate(key, at: "key")
        let action = try Self.decodeAction(from: container)
        // A prompt submits text with no person present; the throttle bounds how often, and so how
        // fast two prompt routes could feed each other.
        if case .prompt = action, (throttleMs ?? 0) < Self.minimumPromptThrottleMs {
            throw ProgramaRouteValidationError(
                "a 'prompt' route needs a 'throttleMs' of at least \(Self.minimumPromptThrottleMs) (1 minute)"
            )
        }
        self.init(
            name: name,
            on: on,
            when: when,
            debounceMs: debounceMs,
            throttleMs: throttleMs,
            key: key,
            action: action
        )
    }

    /// Decodes `routes` one entry at a time, so one bad entry costs only itself.
    static func decodeList(from decoder: Decoder) -> (routes: [ProgramaRouteDefinition], issues: [ProgramaRouteIssue]) {
        if let single = try? decoder.singleValueContainer(), single.decodeNil() {
            return ([], [])
        }
        guard var list = try? decoder.unkeyedContainer() else {
            return ([], [ProgramaRouteIssue(index: nil, name: nil, message: "'routes' must be an array")])
        }
        var routes: [ProgramaRouteDefinition] = []
        var issues: [ProgramaRouteIssue] = []
        var seenNames = Set<String>()
        while !list.isAtEnd {
            let index = list.currentIndex
            // superDecoder() advances past the entry whether or not it decodes.
            guard let element = try? list.superDecoder() else { break }
            let probedName = try? element.container(keyedBy: CodingKeys.self)
                .decodeIfPresent(String.self, forKey: .name)
            do {
                let route = try ProgramaRouteDefinition(from: element)
                guard seenNames.insert(route.name).inserted else {
                    issues.append(ProgramaRouteIssue(
                        index: index,
                        name: route.name,
                        message: "another route is already named '\(route.name)'"
                    ))
                    continue
                }
                routes.append(route)
            } catch {
                issues.append(ProgramaRouteIssue(
                    index: index,
                    name: probedName,
                    message: describe(error, under: element.codingPath)
                ))
            }
        }
        return (routes, issues)
    }

    private static func decodeWhen(from decoder: Decoder) throws -> [ProgramaRouteClause] {
        let fields = try decoder.container(keyedBy: ProgramaRouteDynamicKey.self)
        var clauses: [ProgramaRouteClause] = []
        for fieldKey in fields.allKeys.sorted(by: { $0.stringValue < $1.stringValue }) {
            let field = fieldKey.stringValue
            let valueDecoder = try fields.superDecoder(forKey: fieldKey)
            if let scalar = try? ProgramaRouteScalar(from: valueDecoder) {
                clauses.append(ProgramaRouteClause(field: field, conditions: [.equals(scalar.text)]))
                continue
            }
            guard let operators = try? valueDecoder.container(keyedBy: ProgramaRouteDynamicKey.self) else {
                throw ProgramaRouteValidationError(
                    "'when.\(field)' must be a string, number, boolean or an object of conditions"
                )
            }
            clauses.append(ProgramaRouteClause(
                field: field,
                conditions: try decodeConditions(operators, field: field)
            ))
        }
        return clauses
    }

    private static func decodeConditions(
        _ operators: KeyedDecodingContainer<ProgramaRouteDynamicKey>,
        field: String
    ) throws -> [ProgramaRouteCondition] {
        var conditions: [ProgramaRouteCondition] = []
        var pattern: String?
        var flags: String?
        for key in operators.allKeys.sorted(by: { $0.stringValue < $1.stringValue }) {
            switch key.stringValue {
            case "ne":
                conditions.append(.notEquals(try operators.decode(ProgramaRouteScalar.self, forKey: key).text))
            case "in":
                conditions.append(.oneOf(try operators.decode([ProgramaRouteScalar].self, forKey: key).map(\.text)))
            case "exists":
                conditions.append(.exists(try operators.decode(Bool.self, forKey: key)))
            case "regex":
                pattern = try operators.decode(String.self, forKey: key)
            case "flags":
                flags = try operators.decode(String.self, forKey: key)
            default:
                throw ProgramaRouteValidationError(
                    "'when.\(field)' uses unknown operator '\(key.stringValue)'; use ne, in, exists or regex"
                )
            }
        }
        if let pattern {
            do {
                conditions.append(.matches(try ProgramaRouteRegex(pattern: pattern, flags: flags ?? "")))
            } catch let error as ProgramaRouteValidationError {
                throw ProgramaRouteValidationError("'when.\(field)': \(error.message)")
            }
        } else if flags != nil {
            throw ProgramaRouteValidationError("'when.\(field)' has 'flags' without 'regex'")
        }
        guard !conditions.isEmpty else {
            throw ProgramaRouteValidationError("'when.\(field)' has no condition")
        }
        return conditions
    }

    private static func decodeDuration<Key: CodingKey>(
        _ container: KeyedDecodingContainer<Key>,
        _ key: Key,
        path: String? = nil
    ) throws -> Int? {
        let path = path ?? key.stringValue
        guard container.contains(key), try !container.decodeNil(forKey: key) else { return nil }
        if let milliseconds = try? container.decode(Int.self, forKey: key) {
            guard milliseconds >= 0 else {
                throw ProgramaRouteValidationError("'\(path)' must not be negative")
            }
            return milliseconds
        }
        if let text = try? container.decode(String.self, forKey: key) {
            guard let milliseconds = ProgramaRouteDuration.milliseconds(parsing: text) else {
                throw ProgramaRouteValidationError(
                    "'\(path)' is not a duration: '\(text)'; use milliseconds or a string such as \"4s\" or \"5m\""
                )
            }
            return milliseconds
        }
        throw ProgramaRouteValidationError(
            "'\(path)' must be a whole number of milliseconds or a duration string such as \"4s\""
        )
    }

    private static func decodeAction(from container: KeyedDecodingContainer<CodingKeys>) throws -> ProgramaRouteAction {
        let present = actionKeys.filter { container.contains($0) }
        guard let actionKey = present.first else {
            throw ProgramaRouteValidationError("a route needs one action: notify, send, prompt, run or review")
        }
        guard present.count == 1 else {
            let names = present.map(\.stringValue).joined(separator: ", ")
            throw ProgramaRouteValidationError("a route takes one action, found \(names)")
        }

        switch actionKey {
        case .notify:
            let notify = try container.nestedContainer(keyedBy: NotifyKeys.self, forKey: .notify)
            let title = try notify.decode(String.self, forKey: .title)
            let subtitle = try notify.decodeIfPresent(String.self, forKey: .subtitle)
            let body = try notify.decodeIfPresent(String.self, forKey: .body)
            try ProgramaRouteField.validateTemplate(title, at: "notify.title")
            try ProgramaRouteField.validateTemplate(subtitle ?? "", at: "notify.subtitle")
            try ProgramaRouteField.validateTemplate(body ?? "", at: "notify.body")
            return .notify(title: title, subtitle: subtitle, body: body)

        case .send, .prompt:
            let action = actionKey.stringValue
            let fields = try container.nestedContainer(keyedBy: TextKeys.self, forKey: actionKey)
            let text = try fields.decode(String.self, forKey: .text)
            try ProgramaRouteField.validateTemplate(text, at: "\(action).text", agentBound: true)
            var whenBusy = ProgramaRouteWhenBusy.queue
            if let raw = try fields.decodeIfPresent(String.self, forKey: .whenBusy) {
                guard let parsed = ProgramaRouteWhenBusy(rawValue: raw) else {
                    throw ProgramaRouteValidationError(
                        "'\(action).whenBusy' is '\(raw)'; use queue or steer"
                    )
                }
                whenBusy = parsed
            }
            return actionKey == .send
                ? .send(text: text, whenBusy: whenBusy)
                : .prompt(text: text, whenBusy: whenBusy)

        case .run:
            let run = try container.nestedContainer(keyedBy: RunKeys.self, forKey: .run)
            let command = try run.decode(String.self, forKey: .command)
            // Event text reaches a command only as PROGRAMA_ROUTE_* environment variables, never
            // through the shell's parser.
            if let field = ProgramaRouteField.placeholders(in: command)
                .first(where: { ProgramaRouteField.trust(of: $0) != nil }) {
                throw ProgramaRouteValidationError(
                    "'run.command' names field '\(field)'; run commands are not templated, read the PROGRAMA_ROUTE_* environment variables instead"
                )
            }
            let timeoutMs = try decodeDuration(run, .timeoutMs, path: "run.timeoutMs")
            if timeoutMs == 0 {
                throw ProgramaRouteValidationError("'run.timeoutMs' must be above zero")
            }
            return .run(command: command, timeoutMs: timeoutMs)

        case .review:
            let review = try container.nestedContainer(keyedBy: ReviewKeys.self, forKey: .review)
            var mode: ReviewDiffMode?
            if let raw = try review.decodeIfPresent(String.self, forKey: .mode) {
                guard let parsed = ReviewDiffMode(rawValue: raw) else {
                    throw ProgramaRouteValidationError("'review.mode' is '\(raw)'; use uncommitted or branch")
                }
                mode = parsed
            }
            return .review(mode: mode, baseBranch: try review.decodeIfPresent(String.self, forKey: .baseBranch))

        default:
            throw ProgramaRouteValidationError("a route needs one action: notify, send, prompt, run or review")
        }
    }

    /// A one-line message for a failed route, with paths relative to the route entry.
    private static func describe(_ error: Error, under base: [CodingKey]) -> String {
        func path(_ codingPath: [CodingKey]) -> String {
            let relative = codingPath.dropFirst(base.count).map { key in
                key.intValue.map { "[\($0)]" } ?? key.stringValue
            }
            return relative.isEmpty ? "route" : relative.joined(separator: ".").replacingOccurrences(of: ".[", with: "[")
        }
        switch error {
        case let error as ProgramaRouteValidationError:
            return error.message
        case DecodingError.keyNotFound(let key, let context):
            return "missing '\(path(context.codingPath + [key]))'"
        case DecodingError.valueNotFound(_, let context):
            return "'\(path(context.codingPath))' must not be null"
        case DecodingError.typeMismatch(_, let context):
            return "'\(path(context.codingPath))' has the wrong type: \(context.debugDescription)"
        case DecodingError.dataCorrupted(let context):
            return "'\(path(context.codingPath))': \(context.debugDescription)"
        default:
            return String(describing: error)
        }
    }
}
