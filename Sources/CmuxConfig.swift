import Bonsplit
import Combine
import Foundation

struct ProgramaConfigFile: Codable, Sendable {
    var commands: [ProgramaCommandDefinition]
}

struct ProgramaCommandDefinition: Codable, Sendable, Identifiable {
    var name: String
    var description: String?
    var keywords: [String]?
    var restart: ProgramaRestartBehavior?
    var workspace: ProgramaWorkspaceDefinition?
    var command: String?
    var confirm: Bool?

    var id: String {
        "cmux.config.command." + (name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? name)
    }

    init(
        name: String,
        description: String? = nil,
        keywords: [String]? = nil,
        restart: ProgramaRestartBehavior? = nil,
        workspace: ProgramaWorkspaceDefinition? = nil,
        command: String? = nil,
        confirm: Bool? = nil
    ) {
        self.name = name
        self.description = description
        self.keywords = keywords
        self.restart = restart
        self.workspace = workspace
        self.command = command
        self.confirm = confirm
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

enum ProgramaRestartBehavior: String, Codable, Sendable {
    case recreate
    case ignore
    case confirm
}

struct ProgramaWorkspaceDefinition: Codable, Sendable {
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

indirect enum ProgramaLayoutNode: Codable, Sendable {
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

struct ProgramaSplitDefinition: Codable, Sendable {
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

enum ProgramaSplitDirection: String, Codable, Sendable {
    case horizontal
    case vertical
}

struct ProgramaPaneDefinition: Codable, Sendable {
    var surfaces: [ProgramaSurfaceDefinition]

    init(surfaces: [ProgramaSurfaceDefinition]) {
        self.surfaces = surfaces
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        surfaces = try container.decode([ProgramaSurfaceDefinition].self, forKey: .surfaces)
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

struct ProgramaSurfaceDefinition: Codable, Sendable {
    var type: ProgramaSurfaceType
    var name: String?
    var command: String?
    var cwd: String?
    var env: [String: String]?
    var url: String?
    var focus: Bool?
}

enum ProgramaSurfaceType: String, Codable, Sendable {
    case terminal
    case browser
}

@MainActor
final class ProgramaConfigStore: ObservableObject {
    @Published private(set) var loadedCommands: [ProgramaCommandDefinition] = []
    @Published private(set) var configRevision: UInt64 = 0

    /// Which config file each command came from, keyed by command id.
    private(set) var commandSourcePaths: [String: String] = [:]

    private(set) var localConfigPath: String?
    let globalConfigPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(".config/cmux/cmux.json")
    }()

    private var cancellables = Set<AnyCancellable>()
    private var localFileWatchSource: DispatchSourceFileSystemObject?
    private var localFileDescriptor: Int32 = -1
    private var globalFileWatchSource: DispatchSourceFileSystemObject?
    private var globalFileDescriptor: Int32 = -1
    private let watchQueue = DispatchQueue(label: "com.cmux.config-file-watch")

    private static let maxReattachAttempts = 5
    private static let reattachDelay: TimeInterval = 0.5

    init() {
        startGlobalFileWatcher()
    }

    deinit {
        localFileWatchSource?.cancel()
        globalFileWatchSource?.cancel()
    }

    // MARK: - Public API

    func wireDirectoryTracking(tabManager: TabManager) {
        cancellables.removeAll()

        tabManager.$selectedTabId
            .compactMap { [weak tabManager] tabId -> Workspace? in
                guard let tabId, let tabManager else { return nil }
                return tabManager.tabs.first(where: { $0.id == tabId })
            }
            .removeDuplicates(by: { $0.id == $1.id })
            .map { workspace -> AnyPublisher<String, Never> in
                workspace.$currentDirectory.eraseToAnyPublisher()
            }
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
                ?? (directory as NSString).appendingPathComponent("cmux.json")
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
            let candidate = (current as NSString).appendingPathComponent("cmux.json")
            if fs.fileExists(atPath: candidate) {
                return candidate
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
        }

        loadedCommands = commands
        commandSourcePaths = sourcePaths
        configRevision &+= 1
    }

    // MARK: - Parsing

    private func parseConfig(at path: String) -> ProgramaConfigFile? {
        guard FileManager.default.fileExists(atPath: path),
              let data = FileManager.default.contents(atPath: path),
              !data.isEmpty else {
            return nil
        }
        do {
            return try JSONDecoder().decode(ProgramaConfigFile.self, from: data)
        } catch {
            NSLog("[ProgramaConfig] parse error at %@: %@", path, String(describing: error))
            return nil
        }
    }

    // MARK: - File watching (local)

    private func startLocalFileWatcher() {
        guard let path = localConfigPath else { return }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            // File doesn't exist yet — watch the directory instead
            startLocalDirectoryWatcher()
            return
        }
        localFileDescriptor = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend],
            queue: watchQueue
        )

        source.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = source.data
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

        source.setCancelHandler {
            Darwin.close(fd)
        }

        source.resume()
        localFileWatchSource = source
    }

    private func startLocalDirectoryWatcher() {
        guard let path = localConfigPath else { return }
        let dirPath = (path as NSString).deletingLastPathComponent
        let fd = open(dirPath, O_EVTONLY)
        guard fd >= 0 else { return }
        localFileDescriptor = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .link, .rename],
            queue: watchQueue
        )

        source.setEventHandler { [weak self] in
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

        source.setCancelHandler {
            Darwin.close(fd)
        }

        source.resume()
        localFileWatchSource = source
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
        if let source = localFileWatchSource {
            source.cancel()
            localFileWatchSource = nil
        }
        localFileDescriptor = -1
    }

    // MARK: - File watching (global)

    private func startGlobalFileWatcher() {
        let fd = open(globalConfigPath, O_EVTONLY)
        guard fd >= 0 else {
            startGlobalDirectoryWatcher()
            return
        }
        globalFileDescriptor = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend],
            queue: watchQueue
        )

        source.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = source.data
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

        source.setCancelHandler {
            Darwin.close(fd)
        }

        source.resume()
        globalFileWatchSource = source
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
        let fd = open(dirPath, O_EVTONLY)
        guard fd >= 0 else { return }
        globalFileDescriptor = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .link, .rename],
            queue: watchQueue
        )

        source.setEventHandler { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async {
                guard FileManager.default.fileExists(atPath: self.globalConfigPath) else { return }
                self.stopGlobalFileWatcher()
                self.loadAll()
                self.startGlobalFileWatcher()
            }
        }

        source.setCancelHandler {
            Darwin.close(fd)
        }

        source.resume()
        globalFileWatchSource = source
    }

    private func stopGlobalFileWatcher() {
        if let source = globalFileWatchSource {
            source.cancel()
            globalFileWatchSource = nil
        }
        globalFileDescriptor = -1
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
