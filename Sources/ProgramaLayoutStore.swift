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
struct ProgramaSavedLayoutSummary: Identifiable, Equatable, Sendable {
    var name: String
    var savedAt: Date
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

    @Published private(set) var savedLayouts: [ProgramaSavedLayoutSummary] = []

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

    func list() -> [ProgramaSavedLayoutSummary] {
        savedLayouts
    }

    func exists(name: String) -> Bool {
        guard Self.isValidName(name) else { return false }
        return FileManager.default.fileExists(atPath: filePath(for: name))
    }

    func load(name: String) -> ProgramaSavedLayout? {
        guard Self.isValidName(name) else { return nil }
        guard let data = FileManager.default.contents(atPath: filePath(for: name)), !data.isEmpty else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard var saved = try? decoder.decode(ProgramaSavedLayout.self, from: data) else { return nil }
        // The filename remains authoritative when a layout file is copied or renamed.
        saved.name = name
        return saved
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
        guard let entries = try? fileManager.contentsOfDirectory(atPath: directoryURL.path) else {
            savedLayouts = []
            return
        }

        var summaries: [ProgramaSavedLayoutSummary] = []
        for entry in entries where entry.hasSuffix(".json") {
            let name = String(entry.dropLast(".json".count))
            guard Self.isValidName(name), let saved = load(name: name) else { continue }
            summaries.append(ProgramaSavedLayoutSummary(name: saved.name, savedAt: saved.savedAt))
        }
        savedLayouts = summaries.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
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
