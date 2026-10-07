// OSC 7501 Program Status Protocol: the per-terminal record store and the report parser.
//
// Ghostty's parser has already validated every report before the action reaches Swift. The
// checks here are defense in depth, so the store never holds a record the sidebar or the socket
// could not safely show. See docs/plans/osc7501-program-status.md (D6, D7).
import Foundation

enum ProgramStatusState: String, Sendable, CaseIterable {
    case idle, working, done, blocked, error

    /// A program that is working or blocked is mid-task. `done`, `error` and `idle` are resting
    /// values that survive a shell prompt.
    var isActive: Bool { self == .working || self == .blocked }

    /// The `agent_state` value the root record projects to. `agent_state` keeps its three wire
    /// values; `AgentPresence.programState` carries the finer distinction.
    var legacyAgentState: AgentActivityState {
        switch self {
        case .working: return .working
        case .blocked: return .blocked
        case .idle, .done, .error: return .idle
        }
    }
}

enum ProgramStatusKind: String, Sendable {
    case permission, question, auth
}

struct ProgramStatusRecord: Equatable, Sendable {
    /// Empty string is the root record (the program itself).
    var id: String
    var state: ProgramStatusState
    var kind: ProgramStatusKind?
    var progress: Int?
    /// As the program sent it. `ProgramStatusStore.record(id:)` returns the value resolved
    /// through ancestors.
    var app: String?
    var title: String?
    var msg: String?
    var updatedAt: Date
}

/// One validated report. `state == nil` is the `clear` operation: it removes `id` and every
/// descendant, or every record when `id` is empty.
struct ProgramStatusReport: Equatable, Sendable {
    static let maxMsgBytes = 2048
    static let maxTitleBytes = 192
    static let maxIdBytes = 128
    static let maxIdSegments = 8
    static let maxSegmentLength = 32

    var state: ProgramStatusState?
    var id: String
    var kind: ProgramStatusKind?
    var progress: Int?
    var app: String?
    var title: String?
    var msg: String?

    /// Parses the bytes after `7501;`. Returns nil when the report must be discarded whole.
    /// Pairs split on `:`, keys on the first `=`; malformed pairs are skipped, unknown keys
    /// ignored, and the last value of a repeated key wins.
    static func parse(state: ProgramStatusState?, body: Data) -> ProgramStatusReport? {
        guard let text = String(data: body, encoding: .utf8) else { return nil }
        var values: [Substring: Substring] = [:]
        for pair in text.split(separator: ":", omittingEmptySubsequences: true) {
            guard let eq = pair.firstIndex(of: "=") else { continue }
            // Ghostty's parser trims ASCII whitespace from keys and values; match it so both
            // sides agree on which record a report addresses.
            values[trimASCIIWhitespace(pair[pair.startIndex..<eq])] =
                trimASCIIWhitespace(pair[pair.index(after: eq)...])
        }

        let id = values["id"].map(String.init) ?? ""
        guard isValidId(id) else { return nil }

        var kind: ProgramStatusKind?
        if state == .blocked, let raw = values["kind"] {
            kind = ProgramStatusKind(rawValue: String(raw))
        }
        var progress: Int?
        if let state, state.isActive, let raw = values["progress"] {
            progress = parseProgress(raw)
        }
        var app: String?
        if let raw = values["app"], isName(raw, maxLength: maxSegmentLength) {
            app = String(raw)
        }

        var title: String?
        var msg: String?
        if state != nil {
            guard let decodedTitle = decodeText(values["title"], maxBytes: maxTitleBytes),
                  let decodedMsg = decodeText(values["msg"], maxBytes: maxMsgBytes) else { return nil }
            title = decodedTitle.value
            msg = decodedMsg.value
        }

        return ProgramStatusReport(
            state: state, id: id, kind: kind, progress: progress, app: app, title: title, msg: msg
        )
    }

    static func isValidId(_ id: String) -> Bool {
        if id.isEmpty { return true }
        guard id.utf8.count <= maxIdBytes else { return false }
        let segments = id.split(separator: "/", omittingEmptySubsequences: false)
        guard segments.count <= maxIdSegments else { return false }
        return segments.allSatisfy { isName($0, maxLength: maxSegmentLength) }
    }

    private static func isName(_ value: Substring, maxLength: Int) -> Bool {
        guard !value.isEmpty, value.utf8.count <= maxLength else { return false }
        return value.utf8.allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "_"), UInt8(ascii: "."), UInt8(ascii: "+"), UInt8(ascii: "-"):
                return true
            default:
                return false
            }
        }
    }

    private static func trimASCIIWhitespace(_ value: Substring) -> Substring {
        let isSpace: (Character) -> Bool = { " \t\n\r\u{0B}\u{0C}".contains($0) }
        guard let start = value.firstIndex(where: { !isSpace($0) }),
              let end = value.lastIndex(where: { !isSpace($0) }) else { return "" }
        return value[start...end]
    }

    private static func parseProgress(_ value: Substring) -> Int? {
        guard !value.isEmpty, value.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
        guard let number = Int(value), number <= 100 else { return nil }
        return number
    }

    /// Returns a nil `value` for an absent or empty field, and nil itself when the field is
    /// invalid and the report must be discarded.
    private static func decodeText(_ encoded: Substring?, maxBytes: Int) -> DecodedText? {
        guard let encoded, !encoded.isEmpty else { return DecodedText(value: nil) }
        var padded = String(encoded)
        if padded.utf8.count % 4 != 0 {
            padded += String(repeating: "=", count: 4 - padded.utf8.count % 4)
        }
        guard let data = Data(base64Encoded: padded),
              !data.isEmpty,
              data.count <= maxBytes,
              let string = String(data: data, encoding: .utf8) else { return nil }
        for scalar in string.unicodeScalars {
            let v = scalar.value
            if v <= 0x1F || v == 0x7F || (0x80...0x9F).contains(v) { return nil }
        }
        return DecodedText(value: string)
    }

    private struct DecodedText {
        let value: String?
    }
}

/// Result of applying a report to the store.
enum ProgramStatusChange: Equatable {
    /// The report would create a record past `ProgramStatusStore.capacity` and was discarded.
    case rejected
    /// The report was applied. `rootTouched` is true when it wrote or removed the root record.
    case applied(rootTouched: Bool)
}

/// Records for one terminal, keyed by id (`""` is the root). Lives on `TerminalPanel`, so it
/// travels with the panel across detach/reattach and is never persisted.
@MainActor
final class ProgramStatusStore {
    static let capacity = 256

    private var records: [String: ProgramStatusRecord] = [:]

    var count: Int { records.count }
    var isEmpty: Bool { records.isEmpty }

    /// The root record: the program's own status.
    var root: ProgramStatusRecord? { record(id: "") }

    /// The record for `id`, with `app` resolved to the nearest ancestor that has one.
    func record(id: String) -> ProgramStatusRecord? {
        guard var record = records[id] else { return nil }
        if record.app == nil {
            record.app = inheritedApp(for: id)
        }
        return record
    }

    @discardableResult
    func apply(_ report: ProgramStatusReport, at now: Date = Date()) -> ProgramStatusChange {
        guard let state = report.state else {
            return .applied(rootTouched: clear(id: report.id))
        }
        if records[report.id] == nil, records.count >= Self.capacity {
            return .rejected
        }
        records[report.id] = ProgramStatusRecord(
            id: report.id,
            state: state,
            kind: report.kind,
            progress: report.progress,
            app: report.app,
            title: report.title,
            msg: report.msg,
            updatedAt: now
        )
        return .applied(rootTouched: report.id.isEmpty)
    }

    /// A shell prompt means the foreground program ended: drop working and blocked records at
    /// every depth. Returns true when the root record was removed.
    @discardableResult
    func dropTransient() -> Bool {
        let hadRoot = records[""] != nil
        records = records.filter { !$0.value.state.isActive }
        return hadRoot && records[""] == nil
    }

    /// Full terminal reset (RIS). Returns true when the root record was removed.
    @discardableResult
    func resetAll() -> Bool {
        let hadRoot = records[""] != nil
        records.removeAll()
        return hadRoot
    }

    /// Removes `id` and every descendant (`a` removes `a/b`, not `ab`); an empty `id` removes
    /// everything. Returns true when the root record was removed.
    private func clear(id: String) -> Bool {
        if id.isEmpty { return resetAll() }
        let prefix = id + "/"
        records = records.filter { $0.key != id && !$0.key.hasPrefix(prefix) }
        return false
    }

    private func inheritedApp(for id: String) -> String? {
        var parts = id.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        while !parts.isEmpty {
            parts.removeLast()
            if let app = records[parts.joined(separator: "/")]?.app { return app }
        }
        return nil
    }
}

extension ProgramStatusRecord {
    /// The socket representation of a record. It never carries `msg`, `title` or child ids:
    /// any process in a Programa terminal can reach the socket, and the protocol forbids
    /// revealing record text back to programs.
    var wirePayload: [String: Any] {
        [
            "state": state.rawValue,
            "kind": kind?.rawValue ?? NSNull(),
            "progress": progress ?? NSNull(),
            "app": app ?? NSNull(),
            "has_message": msg != nil,
            "updated_at": updatedAt.timeIntervalSince1970,
        ]
    }
}

extension Workspace {
    /// `program_status` for `surface.list` and `system.tree`: the root record, or null.
    func programStatusWire(panelId: UUID) -> Any {
        (panels[panelId] as? TerminalPanel)?.programStatus.root?.wirePayload ?? NSNull()
    }
}
