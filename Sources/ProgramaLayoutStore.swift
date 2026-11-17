import Foundation
import Combine

// MARK: - ProgramaLayoutStore
//
// Named-layout file store (docs/plans/worktree-and-layouts.md, "named layout configs"):
// `~/.config/programa/layouts/<name>.json`, one file per saved layout. Reuses the existing
// Codable layout DSL from ProgramaConfig.swift (`ProgramaLayoutNode` and friends) verbatim --
// this store only owns the small wrapper envelope (schemaVersion/name/savedAt/layout) and the
// list/load/save/remove file operations, mirroring the relevant parts of
// `ProgramaConfigStore` (FileWatcher-backed `ObservableObject` so the command palette live-
// updates when layouts are saved/removed via CLI or another window -- see plan risk #7).

/// On-disk envelope for a saved layout file.
struct ProgramaSavedLayout: Codable, Sendable {
    var schemaVersion: Int
    var name: String
    var savedAt: Date
    var layout: ProgramaLayoutNode
}

/// Lightweight summary used for listing (command palette, `layout.list`) without decoding the
/// full layout tree.
struct ProgramaSavedLayoutSummary: Identifiable, Hashable, Sendable {
    var name: String
    var savedAt: Date
    var id: String { name }
}

/// A layout file that exists but cannot be used. It is listed with its reason instead of being
/// hidden, so the user can see which file is broken and why.
struct ProgramaLayoutFileFailure: Error, Hashable, Sendable {
    var name: String
    var reason: String

    var fileName: String { "\(name).json" }

    /// For example "my-layout.json: missing key 'panes'".
    var displayMessage: String {
        String(localized: "layout.failed.detail", defaultValue: "\(fileName): \(reason)")
    }
}

/// One file in the layouts directory, whether or not it decodes.
enum ProgramaLayoutEntry: Identifiable, Hashable, Sendable {
    case saved(ProgramaSavedLayoutSummary)
    case failed(ProgramaLayoutFileFailure)

    var name: String {
        switch self {
        case .saved(let summary): return summary.name
        case .failed(let failure): return failure.name
        }
    }

    var id: String { name }
}

enum ProgramaLayoutStoreError: Error, CustomStringConvertible {
    case invalidName
    case alreadyExists
    case notFound
    case noActiveWorkspace

    var description: String {
        switch self {
        case .invalidName: return "Layout name must be non-empty and must not contain '/'"
        case .alreadyExists: return "A layout with this name already exists"
        case .notFound: return "No saved layout with this name"
        case .noActiveWorkspace: return "No active workspace to capture"
        }
    }
}

@MainActor
final class ProgramaLayoutStore: ObservableObject {
    static let shared = ProgramaLayoutStore()

    @Published private(set) var entries: [ProgramaLayoutEntry] = []

    static let directoryPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(".config/programa/layouts")
    }()

    private let watchQueue = DispatchQueue(label: "com.programa.layout-store-watch")
    private let fileWatcher: FileWatcher
    private let directoryURL: URL

    init(directoryURL: URL? = nil, startWatching: Bool = true) {
        self.directoryURL = directoryURL ?? URL(fileURLWithPath: Self.directoryPath, isDirectory: true)
        fileWatcher = FileWatcher(queue: watchQueue)
        reload()
        if startWatching { self.startWatching() }
    }

    deinit {
        fileWatcher.stop()
    }

    // MARK: - Public API

    /// The layouts that decode. Broken files are only in `entries`.
    func list() -> [ProgramaSavedLayoutSummary] {
        entries.compactMap { entry in
            guard case .saved(let summary) = entry else { return nil }
            return summary
        }
    }

    func exists(name: String) -> Bool {
        guard Self.isValidName(name) else { return false }
        return FileManager.default.fileExists(atPath: filePath(for: name))
    }

    func load(name: String) -> ProgramaSavedLayout? {
        try? decode(name: name).get()
    }

    /// Like `load`, but says why a file cannot be used.
    func decode(name: String) -> Result<ProgramaSavedLayout, ProgramaLayoutFileFailure> {
        func failure(_ reason: String) -> Result<ProgramaSavedLayout, ProgramaLayoutFileFailure> {
            .failure(ProgramaLayoutFileFailure(name: name, reason: reason))
        }
        guard Self.isValidName(name) else {
            return failure(String(localized: "layout.decodeError.invalidName", defaultValue: "not a valid layout name"))
        }
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: filePath(for: name)))
        } catch CocoaError.fileReadNoSuchFile {
            return failure(String(localized: "layout.decodeError.fileMissing", defaultValue: "the file no longer exists"))
        } catch {
            return failure(error.localizedDescription)
        }
        guard !data.isEmpty else {
            return failure(String(localized: "layout.decodeError.emptyFile", defaultValue: "the file is empty"))
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            var saved = try decoder.decode(ProgramaSavedLayout.self, from: data)
            // The filename remains authoritative when a layout file is copied or renamed.
            saved.name = name
            return .success(saved)
        } catch let error as DecodingError {
            return failure(Self.reason(for: error))
        } catch {
            return failure(error.localizedDescription)
        }
    }

    @discardableResult
    func save(name: String, layout: ProgramaLayoutNode, force: Bool) throws -> String {
        guard Self.isValidName(name) else { throw ProgramaLayoutStoreError.invalidName }
        let path = filePath(for: name)
        if !force, FileManager.default.fileExists(atPath: path) {
            throw ProgramaLayoutStoreError.alreadyExists
        }

        let saved = ProgramaSavedLayout(schemaVersion: 1, name: name, savedAt: Date(), layout: layout)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(saved)

        try ensureDirectoryExists()
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        reload()
        return path
    }

    func remove(name: String) throws {
        guard Self.isValidName(name) else { throw ProgramaLayoutStoreError.invalidName }
        let path = filePath(for: name)
        guard FileManager.default.fileExists(atPath: path) else {
            throw ProgramaLayoutStoreError.notFound
        }
        try FileManager.default.removeItem(atPath: path)
        reload()
    }

    static func isValidName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != ".." else { return false }
        return !trimmed.contains("/") && !name.contains("\0")
    }

    // MARK: - Internals

    private func filePath(for name: String) -> String {
        (directoryURL.path as NSString).appendingPathComponent("\(name).json")
    }

    private func ensureDirectoryExists() throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    private func reload() {
        let fileManager = FileManager.default
        guard let fileNames = try? fileManager.contentsOfDirectory(atPath: directoryURL.path) else {
            entries = []
            return
        }

        var loaded: [ProgramaLayoutEntry] = []
        for fileName in fileNames where fileName.hasSuffix(".json") {
            let name = String(fileName.dropLast(".json".count))
            guard Self.isValidName(name) else { continue }
            switch decode(name: name) {
            case .success(let saved):
                loaded.append(.saved(ProgramaSavedLayoutSummary(name: saved.name, savedAt: saved.savedAt)))
            case .failure(let failure):
                loaded.append(.failed(failure))
            }
        }
        entries = loaded.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// A short, user-facing reason such as "missing key 'panes'".
    private static func reason(for error: DecodingError) -> String {
        func path(_ codingPath: [CodingKey]) -> String {
            codingPath.reduce(into: "") { path, key in
                if let index = key.intValue {
                    path += "[\(index)]"
                } else {
                    path += path.isEmpty ? key.stringValue : ".\(key.stringValue)"
                }
            }
        }
        switch error {
        case .keyNotFound(let key, let context):
            let location = path(context.codingPath)
            return location.isEmpty
                ? String(localized: "layout.decodeError.missingKey", defaultValue: "missing key '\(key.stringValue)'")
                : String(localized: "layout.decodeError.missingKeyAt", defaultValue: "missing key '\(key.stringValue)' in '\(location)'")
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            let location = path(context.codingPath)
            return location.isEmpty
                ? String(localized: "layout.decodeError.wrongValueRoot", defaultValue: "wrong value type")
                : String(localized: "layout.decodeError.wrongValue", defaultValue: "wrong or missing value at '\(location)'")
        case .dataCorrupted(let context):
            if context.codingPath.isEmpty, let underlying = context.underlyingError as NSError? {
                // JSONSerialization puts the line and column of a syntax error here.
                if let detail = underlying.userInfo[NSDebugDescriptionErrorKey] as? String, !detail.isEmpty {
                    return String(localized: "layout.decodeError.invalidJSONDetail", defaultValue: "not valid JSON (\(detail))")
                }
                return String(localized: "layout.decodeError.invalidJSON", defaultValue: "not valid JSON")
            }
            let location = path(context.codingPath)
            return location.isEmpty
                ? context.debugDescription
                : String(localized: "layout.decodeError.invalidValueAt", defaultValue: "\(context.debugDescription) at '\(location)'")
        @unknown default:
            return error.localizedDescription
        }
    }

    private func startWatching() {
        try? ensureDirectoryExists()
        _ = fileWatcher.start(
            path: directoryURL.path,
            eventMask: [.write, .delete, .rename, .extend]
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.reload()
            }
        }
    }
}
