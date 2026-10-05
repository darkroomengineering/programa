import Bonsplit
import Combine
import Foundation

struct ProgramaConfigFile: Codable, Sendable, Equatable {
    var commands: [ProgramaCommandDefinition]
    var recipes: [ProgramaRecipeDefinition]?
}

/// A named, reusable input to a `command` template or a recipe `prompt`, referenced as
/// `{{name}}`. `prompt` is the label shown when asking the user for a value (defaults to
/// `name` when absent); `default` pre-fills the text field.
struct ProgramaParameterDefinition: Codable, Sendable, Equatable {
    var name: String
    var prompt: String?
    var `default`: String?

    init(name: String, prompt: String? = nil, default: String? = nil) {
        self.name = name
        self.prompt = prompt
        self.default = `default`
    }
}

struct ProgramaCommandDefinition: Codable, Sendable, Identifiable, Equatable {
    var name: String
    var description: String?
    var keywords: [String]?
    var restart: ProgramaRestartBehavior?
    var workspace: ProgramaWorkspaceDefinition?
    var command: String?
    var confirm: Bool?
    var parameters: [ProgramaParameterDefinition]?

    var id: String {
        "programa.config.command." + (name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? name)
    }

    init(
        name: String,
        description: String? = nil,
        keywords: [String]? = nil,
        restart: ProgramaRestartBehavior? = nil,
        workspace: ProgramaWorkspaceDefinition? = nil,
        command: String? = nil,
        confirm: Bool? = nil,
        parameters: [ProgramaParameterDefinition]? = nil
    ) {
        self.name = name
        self.description = description
        self.keywords = keywords
        self.restart = restart
        self.workspace = workspace
        self.command = command
        self.confirm = confirm
        self.parameters = parameters
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        keywords = try container.decodeIfPresent([String].self, forKey: .keywords)
        restart = try container.decodeIfPresent(ProgramaRestartBehavior.self, forKey: .restart)
        workspace = try container.decodeIfPresent(ProgramaWorkspaceDefinition.self, forKey: .workspace)
        command = try container.decodeIfPresent(String.self, forKey: .command)
        confirm = try container.decodeIfPresent(Bool.self, forKey: .confirm)
        parameters = try container.decodeIfPresent([ProgramaParameterDefinition].self, forKey: .parameters)

        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Command name must not be blank"
                )
            )
        }
        if let cmd = command,
           cmd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Command '\(name)' must not define a blank 'command'"
                )
            )
        }

        if workspace != nil && command != nil {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Command '\(name)' must not define both 'workspace' and 'command'"
                )
            )
        }
        if workspace == nil && command == nil {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Command '\(name)' must define either 'workspace' or 'command'"
                )
            )
        }
    }
}

/// A named prompt template for the command palette. Unlike `ProgramaCommandDefinition`,
/// selecting a recipe never runs anything by itself -- after parameter substitution and the
/// same trust gate every config entry goes through, the substituted `prompt` is typed into the
/// focused terminal WITHOUT a trailing newline, so the user reviews it and presses Return
/// themselves. See `ProgramaConfigExecutor.executeRecipe`.
struct ProgramaRecipeDefinition: Codable, Sendable, Identifiable, Equatable {
    var name: String
    var description: String?
    var keywords: [String]?
    var prompt: String
    var parameters: [ProgramaParameterDefinition]?

    var id: String {
        "programa.config.recipe." + (name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? name)
    }

    init(
        name: String,
        description: String? = nil,
        keywords: [String]? = nil,
        prompt: String,
        parameters: [ProgramaParameterDefinition]? = nil
    ) {
        self.name = name
        self.description = description
        self.keywords = keywords
        self.prompt = prompt
        self.parameters = parameters
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        keywords = try container.decodeIfPresent([String].self, forKey: .keywords)
        prompt = try container.decode(String.self, forKey: .prompt)
        parameters = try container.decodeIfPresent([ProgramaParameterDefinition].self, forKey: .parameters)

        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Recipe name must not be blank"
                )
            )
        }
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Recipe '\(name)' must not define a blank 'prompt'"
                )
            )
        }
    }
}

enum ProgramaRestartBehavior: String, Codable, Sendable, Equatable {
    case recreate
    case ignore
    case confirm
}

struct ProgramaWorkspaceDefinition: Codable, Sendable, Equatable {
    var name: String?
    var cwd: String?
    var color: String?
    var layout: ProgramaLayoutNode?

    init(name: String? = nil, cwd: String? = nil, color: String? = nil, layout: ProgramaLayoutNode? = nil) {
        self.name = name
        self.cwd = cwd
        self.color = color
        self.layout = layout
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        layout = try container.decodeIfPresent(ProgramaLayoutNode.self, forKey: .layout)

        if let rawColor = try container.decodeIfPresent(String.self, forKey: .color) {
            guard let normalized = WorkspaceTabColorSettings.normalizedHex(rawColor) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .color,
                    in: container,
                    debugDescription: "Invalid color \"\(rawColor)\". Expected 6-digit hex format: #RRGGBB"
                )
            }
            color = normalized
        } else {
            color = nil
        }
    }
}

indirect enum ProgramaLayoutNode: Codable, Sendable, Equatable {
    case pane(ProgramaPaneDefinition)
    case split(ProgramaSplitDefinition)

    private enum CodingKeys: String, CodingKey {
        case pane
        case direction
        case split
        case children
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let hasPane = container.contains(.pane)
        let hasDirection = container.contains(.direction)

        if hasPane && hasDirection {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "ProgramaLayoutNode must not contain both 'pane' and 'direction' keys"
                )
            )
        }

        if hasPane {
            let pane = try container.decode(ProgramaPaneDefinition.self, forKey: .pane)
            self = .pane(pane)
        } else if hasDirection {
            let splitDef = try ProgramaSplitDefinition(from: decoder)
            self = .split(splitDef)
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "ProgramaLayoutNode must contain either a 'pane' key or a 'direction' key"
                )
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .pane(let pane):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(pane, forKey: .pane)
        case .split(let split):
            try split.encode(to: encoder)
        }
    }
}

struct ProgramaSplitDefinition: Codable, Sendable, Equatable {
    var direction: ProgramaSplitDirection
    var split: Double?
    var children: [ProgramaLayoutNode]

    init(direction: ProgramaSplitDirection, split: Double? = nil, children: [ProgramaLayoutNode]) {
        self.direction = direction
        self.split = split
        self.children = children
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        direction = try container.decode(ProgramaSplitDirection.self, forKey: .direction)
        split = try container.decodeIfPresent(Double.self, forKey: .split)
        children = try container.decode([ProgramaLayoutNode].self, forKey: .children)
        if children.count != 2 {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Split node requires exactly 2 children, got \(children.count)"
                )
            )
        }
    }

    var clampedSplitPosition: Double {
        let value = split ?? 0.5
        return min(0.9, max(0.1, value))
    }

    var splitOrientation: SplitOrientation {
        switch direction {
        case .horizontal: return .horizontal
        case .vertical: return .vertical
        }
    }
}

enum ProgramaSplitDirection: String, Codable, Sendable, Equatable {
    case horizontal
    case vertical
}

struct ProgramaPaneDefinition: Codable, Sendable, Equatable {
    var surfaces: [ProgramaSurfaceDefinition]

    private enum SurfaceTypeKey: String, CodingKey {
        case type
    }

    init(surfaces: [ProgramaSurfaceDefinition]) {
        self.surfaces = surfaces
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var list = try container.nestedUnkeyedContainer(forKey: .surfaces)
        let declaredCount = list.count ?? 0
        var decoded: [ProgramaSurfaceDefinition] = []
        while !list.isAtEnd {
            // Skip retired surface types so the rest of the file keeps loading;
            // any other bad type still fails.
            let probe = try list.superDecoder()
            if let type = try? probe.container(keyedBy: SurfaceTypeKey.self)
                .decode(String.self, forKey: .type),
               ProgramaSurfaceType.retiredRawValues.contains(type) {
                continue
            }
            decoded.append(try ProgramaSurfaceDefinition(from: probe))
        }
        // A pane that held only retired surfaces keeps its place in the split as a terminal.
        surfaces = decoded.isEmpty && declaredCount > 0
            ? [ProgramaSurfaceDefinition(type: .terminal)]
            : decoded
        if surfaces.isEmpty {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Pane node must contain at least one surface"
                )
            )
        }
    }
}

struct ProgramaSurfaceDefinition: Codable, Sendable, Equatable {
    var type: ProgramaSurfaceType
    var name: String?
    var command: String?
    var cwd: String?
    var env: [String: String]?
    var url: String?
    var focus: Bool?
}

enum ProgramaSurfaceType: String, Codable, Sendable, Equatable {
    case terminal

    /// Surface types that older config files may still name and that layouts skip.
    static let retiredRawValues: Set<String> = ["browser"]
}

@MainActor
final class ProgramaConfigStore: ObservableObject {
    @Published private(set) var loadedCommands: [ProgramaCommandDefinition] = []
    @Published private(set) var loadedRecipes: [ProgramaRecipeDefinition] = []
    @Published private(set) var configRevision: UInt64 = 0

    /// Which config file each command came from, keyed by command id.
    private(set) var commandSourcePaths: [String: String] = [:]
    /// Which config file each recipe came from, keyed by recipe id -- same invariant as
    /// `commandSourcePaths`: every loaded recipe must be traceable so `confirmIfUntrusted` never
    /// mistakes an untrusted recipe for the trusted global config. See
    /// `ProgramaConfigSourceTrackingTests`.
    private(set) var recipeSourcePaths: [String: String] = [:]

    // `internal` (not `private(set)`) rather than fully public: production code only ever
    // mutates these through `updateLocalConfigPath`/the computed default below, but tests in
    // this module need to point `loadAll()` at real temp files without a home-directory
    // dependent global config, and there is no other injectable seam on this store.
    var localConfigPath: String?
    var globalConfigPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let newPath = (home as NSString).appendingPathComponent(".config/programa/programa.json")
        // Legacy cmux name, still read so existing ~/.config/cmux/cmux.json files keep working.
        let legacyPath = (home as NSString).appendingPathComponent(".config/cmux/cmux.json")
        let fm = FileManager.default
        if fm.fileExists(atPath: newPath) { return newPath }
        if fm.fileExists(atPath: legacyPath) { return legacyPath }
        return newPath
    }()

    private var cancellables = Set<AnyCancellable>()
    private let watchQueue = DispatchQueue(label: "com.darkroom.programa.config-file-watch")
    private let localFileWatcher: FileWatcher
    private let globalFileWatcher: FileWatcher

    private static let maxReattachAttempts = 5
    private static let reattachDelay: TimeInterval = 0.5

    init() {
        localFileWatcher = FileWatcher(queue: watchQueue)
        globalFileWatcher = FileWatcher(queue: watchQueue)
        startGlobalFileWatcher()
    }

    deinit {
        localFileWatcher.stop()
        globalFileWatcher.stop()
    }

    // MARK: - Public API

    func wireDirectoryTracking(tabManager: TabManager) {
        cancellables.removeAll()

        // The pipeline keeps only the workspace id and its directory publisher. Operators such as
        // removeDuplicates retain their last value, and holding the Workspace itself would pin a
        // closed window's workspace until the next wiring.
        tabManager.$selectedTabId
            .compactMap { [weak tabManager] tabId -> (id: UUID, directory: AnyPublisher<String, Never>)? in
                guard let tabId,
                      let workspace = tabManager?.tabs.first(where: { $0.id == tabId }) else { return nil }
                return (workspace.id, workspace.$currentDirectory.eraseToAnyPublisher())
            }
            .removeDuplicates(by: { $0.id == $1.id })
            .map(\.directory)
            .switchToLatest()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] directory in
                self?.updateLocalConfigPath(directory)
            }
            .store(in: &cancellables)

        if let directory = tabManager.selectedWorkspace?.currentDirectory {
            updateLocalConfigPath(directory)
        }
    }

    private func updateLocalConfigPath(_ directory: String?) {
        let newPath: String?
        if let directory, !directory.isEmpty {
            newPath = findProgramaConfig(startingFrom: directory)
                ?? (directory as NSString).appendingPathComponent("programa.json")
        } else {
            newPath = nil
        }

        guard newPath != localConfigPath else { return }
        stopLocalFileWatcher()
        localConfigPath = newPath
        if newPath != nil {
            startLocalFileWatcher()
        }
        loadAll()
    }

    private func findProgramaConfig(startingFrom directory: String) -> String? {
        var current = directory
        let fs = FileManager.default
        while true {
            // Legacy cmux name, still read so existing project roots keep working.
            for name in ["programa.json", "cmux.json"] {
                let candidate = (current as NSString).appendingPathComponent(name)
                if fs.fileExists(atPath: candidate) {
                    return candidate
                }
            }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current { break }
            current = parent
        }
        return nil
    }

    func loadAll() {
        var commands: [ProgramaCommandDefinition] = []
        var seenNames = Set<String>()
        var sourcePaths: [String: String] = [:]

        var recipes: [ProgramaRecipeDefinition] = []
        var seenRecipeNames = Set<String>()
        var recipeSources: [String: String] = [:]

        // Local config takes precedence
        if let localPath = localConfigPath {
            if let localConfig = parseConfig(at: localPath) {
                for command in localConfig.commands {
                    if !seenNames.contains(command.name) {
                        commands.append(command)
                        seenNames.insert(command.name)
                        sourcePaths[command.id] = localPath
                    }
                }
                for recipe in localConfig.recipes ?? [] {
                    if !seenRecipeNames.contains(recipe.name) {
                        recipes.append(recipe)
                        seenRecipeNames.insert(recipe.name)
                        recipeSources[recipe.id] = localPath
                    }
                }
            }
        }

        // Global config fills in the rest
        if let globalConfig = parseConfig(at: globalConfigPath) {
            for command in globalConfig.commands {
                if !seenNames.contains(command.name) {
                    commands.append(command)
                    seenNames.insert(command.name)
                    sourcePaths[command.id] = globalConfigPath
                }
            }
            for recipe in globalConfig.recipes ?? [] {
                if !seenRecipeNames.contains(recipe.name) {
                    recipes.append(recipe)
                    seenRecipeNames.insert(recipe.name)
                    recipeSources[recipe.id] = globalConfigPath
                }
            }
        }

        guard commands != loadedCommands ||
                sourcePaths != commandSourcePaths ||
                recipes != loadedRecipes ||
                recipeSources != recipeSourcePaths else {
            return
        }

        loadedCommands = commands
        commandSourcePaths = sourcePaths
        loadedRecipes = recipes
        recipeSourcePaths = recipeSources
        configRevision &+= 1
    }

    // MARK: - Parsing

    private func parseConfig(at path: String) -> ProgramaConfigFile? {
        guard FileManager.default.fileExists(atPath: path),
              let data = FileManager.default.contents(atPath: path),
              !data.isEmpty else {
            return nil
        }

        let sanitized: Data
        do {
            sanitized = try JSONCParser.preprocess(data: data)
        } catch {
            NSLog("[ProgramaConfig] JSONC preprocessing error at %@: %@", path, String(describing: error))
            return nil
        }
        // The trust digest and this decoder are different parsers; a repeated key could be
        // approved under one value and executed under the other. See
        // `JSONCParser.containsDuplicateObjectKeys`.
        guard !JSONCParser.containsDuplicateObjectKeys(sanitized) else {
            NSLog("[ProgramaConfig] rejecting %@: an object repeats a key", path)
            return nil
        }

        do {
            return try JSONDecoder().decode(ProgramaConfigFile.self, from: sanitized)
        } catch {
            NSLog("[ProgramaConfig] parse error at %@: %@", path, String(describing: error))
            return nil
        }
    }

    // MARK: - File watching (local)
    //
    // NOTE (drift, refs #100): the local and global watchers below look symmetric but their
    // reattach policy on delete/rename genuinely differs, and that difference is preserved
    // here rather than "fixed" as part of the FileWatcher dedup:
    // - Local: `scheduleLocalReattach` makes exactly ONE delayed existence check (0.5s) after
    //   a delete/rename, then permanently falls back to directory watching if the file is
    //   still missing — it does not recurse to retry further despite `maxReattachAttempts`
    //   being defined (a leftover from copy/pasting the global watcher).
    // - Global: `scheduleGlobalReattach` actually recurses up to `maxReattachAttempts` times
    //   (2.5s total) before falling back to directory watching.

    private func startLocalFileWatcher() {
        guard let path = localConfigPath else { return }
        let started = localFileWatcher.start(
            path: path,
            eventMask: [.write, .delete, .rename, .extend]
        ) { [weak self] flags in
            guard let self else { return }
            if flags.contains(.delete) || flags.contains(.rename) {
                DispatchQueue.main.async {
                    self.stopLocalFileWatcher()
                    self.loadAll()
                    self.scheduleLocalReattach(attempt: 1)
                }
            } else {
                DispatchQueue.main.async {
                    self.loadAll()
                }
            }
        }
        if !started {
            // File doesn't exist yet — watch the directory instead
            startLocalDirectoryWatcher()
        }
    }

    private func startLocalDirectoryWatcher() {
        guard let path = localConfigPath else { return }
        let dirPath = (path as NSString).deletingLastPathComponent
        localFileWatcher.start(
            path: dirPath,
            eventMask: [.write, .link, .rename]
        ) { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.async {
                guard let configPath = self.localConfigPath,
                      FileManager.default.fileExists(atPath: configPath) else { return }
                // File appeared — switch to file-level watching
                self.stopLocalFileWatcher()
                self.loadAll()
                self.startLocalFileWatcher()
            }
        }
    }

    private func scheduleLocalReattach(attempt: Int) {
        guard attempt <= Self.maxReattachAttempts else { return }
        watchQueue.asyncAfter(deadline: .now() + Self.reattachDelay) { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async {
                guard let path = self.localConfigPath else { return }
                if FileManager.default.fileExists(atPath: path) {
                    self.loadAll()
                    self.startLocalFileWatcher()
                } else {
                    self.startLocalDirectoryWatcher()
                }
            }
        }
    }

    private func stopLocalFileWatcher() {
        localFileWatcher.stop()
    }

    // MARK: - File watching (global)

    private func startGlobalFileWatcher() {
        let started = globalFileWatcher.start(
            path: globalConfigPath,
            eventMask: [.write, .delete, .rename, .extend]
        ) { [weak self] flags in
            guard let self else { return }
            if flags.contains(.delete) || flags.contains(.rename) {
                DispatchQueue.main.async {
                    self.stopGlobalFileWatcher()
                    self.loadAll()
                    self.scheduleGlobalReattach(attempt: 1)
                }
            } else {
                DispatchQueue.main.async {
                    self.loadAll()
                }
            }
        }
        if !started {
            startGlobalDirectoryWatcher()
        }
    }

    private func scheduleGlobalReattach(attempt: Int) {
        guard attempt <= Self.maxReattachAttempts else {
            startGlobalDirectoryWatcher()
            return
        }
        watchQueue.asyncAfter(deadline: .now() + Self.reattachDelay) { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async {
                if FileManager.default.fileExists(atPath: self.globalConfigPath) {
                    self.loadAll()
                    self.startGlobalFileWatcher()
                } else {
                    self.scheduleGlobalReattach(attempt: attempt + 1)
                }
            }
        }
    }

    private func startGlobalDirectoryWatcher() {
        let dirPath = (globalConfigPath as NSString).deletingLastPathComponent
        let fm = FileManager.default
        if !fm.fileExists(atPath: dirPath) {
            try? fm.createDirectory(atPath: dirPath, withIntermediateDirectories: true)
        }
        globalFileWatcher.start(
            path: dirPath,
            eventMask: [.write, .link, .rename]
        ) { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.async {
                guard FileManager.default.fileExists(atPath: self.globalConfigPath) else { return }
                self.stopGlobalFileWatcher()
                self.loadAll()
                self.startGlobalFileWatcher()
            }
        }
    }

    private func stopGlobalFileWatcher() {
        globalFileWatcher.stop()
    }
}

extension ProgramaConfigStore {
    static func resolveCwd(_ cwd: String?, relativeTo baseCwd: String) -> String {
        guard let cwd, !cwd.isEmpty, cwd != "." else {
            return baseCwd
        }
        if cwd.hasPrefix("~/") || cwd == "~" {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            if cwd == "~" { return home }
            return (home as NSString).appendingPathComponent(String(cwd.dropFirst(2)))
        }
        if cwd.hasPrefix("/") {
            return cwd
        }
        return (baseCwd as NSString).appendingPathComponent(cwd)
    }
}
