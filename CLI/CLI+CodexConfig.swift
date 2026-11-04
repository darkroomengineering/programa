import Foundation
import CryptoKit
import Darwin
import TOML

extension ProgramaCLI {
    // MARK: - Codex hooks

    static let codexMaximumFileBytes = 16 * 1024 * 1024
    /// Everything Programa writes to config.toml lives between these two lines and is
    /// rewritten whole. Its content is tables only, so it is valid wherever it lands.
    private static let codexBlockBegin = "# BEGIN programa (managed by Programa, do not edit)"
    private static let codexBlockEnd = "# END programa"
    private static let codexTrustBlockStart = "# >>> programa managed codex hook trust v1 >>>"
    private static let codexTrustBlockEnd = "# <<< programa managed codex hook trust v1 <<<"
    private static let codexLegacyTrustBlockStart = "# >>> programa codex hook trust >>>"
    private static let codexLegacyTrustBlockEnd = "# <<< programa codex hook trust <<<"

    private struct CodexHookSpec {
        let event: String
        let label: String
        let commandEvent: String
        let timeout: Int
    }

    private static let codexHookSpecs = [
        CodexHookSpec(event: "SessionStart", label: "session_start", commandEvent: "session-start", timeout: 10),
        CodexHookSpec(event: "UserPromptSubmit", label: "user_prompt_submit", commandEvent: "prompt-submit", timeout: 10),
        CodexHookSpec(event: "Stop", label: "stop", commandEvent: "stop", timeout: 10),
        CodexHookSpec(event: "PermissionRequest", label: "permission_request", commandEvent: "notification", timeout: 10),
        CodexHookSpec(event: "SessionEnd", label: "session_end", commandEvent: "session-end", timeout: 1),
    ]
    private static let codexOwnedCommandEventByHookEvent: [String: String] = {
        var result = Dictionary(uniqueKeysWithValues: codexHookSpecs.map { ($0.event, $0.commandEvent) })
        result["Notification"] = "notification"
        return result
    }()

    struct CodexFileSnapshot: Equatable {
        let data: Data
        let mode: mode_t
    }

    struct CodexPaths {
        let home: String
        let lockHome: String
        let hooks: String
        let configLink: String
        let configTarget: String
    }

    struct CodexTrustEdit {
        let configPath: String
        let configLinkPath: String
        let hooksKeyPrefix: String
        let desired: [String: String]
        /// Trust hashes of the Programa handlers already in hooks.json, by trust key.
        let previousOwned: [String: String]
        let ownedHashes: Set<String>
    }

    struct CodexPreparedConfig {
        let edit: CodexTrustEdit
        let snapshot: CodexFileSnapshot?
        let rendered: Data
    }

    private struct CodexRenderedConfig {
        let text: String
        let warnings: [String]
    }

    private enum CodexTOMLStringMode {
        case none
        case basic
        case literal
        case multilineBasic
        case multilineLiteral
    }

    private struct CodexTOMLLine {
        let range: Range<String.Index>
        let text: String
        let startsInString: Bool
    }

    private indirect enum CodexTOMLValue: Decodable, Equatable {
        case string(String)
        case integer(Int64)
        case float(Double)
        case boolean(Bool)
        case offsetDateTime(Date)
        case localDateTime(LocalDateTime)
        case localDate(LocalDate)
        case localTime(LocalTime)
        case array([CodexTOMLValue])
        case table([String: CodexTOMLValue])
        case null

        private struct Key: CodingKey {
            let stringValue: String
            let intValue: Int? = nil
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { return nil }
        }

        init(from decoder: Decoder) throws {
            if let container = try? decoder.container(keyedBy: Key.self) {
                var result: [String: CodexTOMLValue] = [:]
                for key in container.allKeys {
                    result[key.stringValue] = try container.decode(CodexTOMLValue.self, forKey: key)
                }
                self = .table(result)
                return
            }
            if var container = try? decoder.unkeyedContainer() {
                var result: [CodexTOMLValue] = []
                while !container.isAtEnd {
                    result.append(try container.decode(CodexTOMLValue.self))
                }
                self = .array(result)
                return
            }
            let container = try decoder.singleValueContainer()
            if container.decodeNil() { self = .null; return }
            if let value = try? container.decode(Bool.self) { self = .boolean(value); return }
            if let value = try? container.decode(Int64.self) { self = .integer(value); return }
            if let value = try? container.decode(Double.self) { self = .float(value); return }
            if let value = try? container.decode(String.self) { self = .string(value); return }
            if let value = try? container.decode(Date.self) { self = .offsetDateTime(value); return }
            if let value = try? container.decode(LocalDateTime.self) { self = .localDateTime(value); return }
            if let value = try? container.decode(LocalDate.self) { self = .localDate(value); return }
            if let value = try? container.decode(LocalTime.self) { self = .localTime(value); return }
            throw DecodingError.typeMismatch(
                CodexTOMLValue.self,
                .init(codingPath: decoder.codingPath, debugDescription: "Unsupported TOML value")
            )
        }

        var tableValue: [String: CodexTOMLValue]? {
            guard case .table(let value) = self else { return nil }
            return value
        }

        var stringValue: String? {
            guard case .string(let value) = self else { return nil }
            return value
        }
    }

    struct CodexHooksError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Each installed hook gracefully no-ops outside a programa surface.
    private static func codexHookCommand(_ event: String) -> String {
        "[ -n \"$PROGRAMA_SURFACE_ID\" ] && command -v programa >/dev/null 2>&1 && programa codex-hook \(event) || echo '{}'"
    }

    func codexPaths() throws -> CodexPaths {
        let environment = ProcessInfo.processInfo.environment
        let override = environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let explicit = override?.isEmpty == false
        let rawHome = explicit ? override! : "~/.codex"
        let expanded = Self.integrationExpandTilde(rawHome)
        let absolute = expanded.hasPrefix("/")
            ? URL(fileURLWithPath: expanded).standardizedFileURL.path
            : URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(expanded).standardizedFileURL.path
        try FileManager.default.createDirectory(atPath: absolute, withIntermediateDirectories: true, attributes: nil)
        guard let resolvedHome = absolute.withCString({ realpath($0, nil) }) else {
            throw codexPOSIXError("resolve", path: absolute)
        }
        defer { free(resolvedHome) }
        let canonicalHome = String(cString: resolvedHome)
        let home = explicit ? canonicalHome : absolute
        let hooks = (home as NSString).appendingPathComponent("hooks.json")
        let configLink = (home as NSString).appendingPathComponent("config.toml")
        let configTarget = try codexResolveConfigTarget(configLink)
        return CodexPaths(home: home, lockHome: canonicalHome, hooks: hooks, configLink: configLink, configTarget: configTarget)
    }

    func codexResolveConfigTarget(_ path: String) throws -> String {
        var info = stat()
        let result = path.withCString { Darwin.lstat($0, &info) }
        if result != 0 {
            if errno == ENOENT { return path }
            throw codexPOSIXError("inspect", path: path)
        }
        guard (info.st_mode & S_IFMT) == S_IFLNK else { return path }
        guard let resolved = path.withCString({ realpath($0, nil) }) else {
            throw CodexHooksError(message: "\(path) is a dangling symlink; refusing to replace it")
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    func withCodexHooksLock<T>(at home: String, _ body: () throws -> T) throws -> T {
        let path = (home as NSString).appendingPathComponent(".programa-hooks.lock")
        var existing = stat()
        let createdLock = path.withCString { Darwin.lstat($0, &existing) } != 0
        let descriptor = path.withCString { Darwin.open($0, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600) }
        guard descriptor >= 0 else { throw codexPOSIXError("open lock", path: path) }
        defer { Darwin.close(descriptor) }
        var succeeded = false
        // A declined or failed run leaves no new file behind in the user's Codex home.
        defer { if createdLock && !succeeded { _ = path.withCString { unlink($0) } } }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw CodexHooksError(message: "\(path) is not a regular lock file")
        }
        guard flock(descriptor, LOCK_EX) == 0 else { throw codexPOSIXError("lock", path: path) }
        defer { flock(descriptor, LOCK_UN) }
        let result = try body()
        succeeded = true
        return result
    }

    func codexReadRegularFile(_ path: String, limit: Int, refuseSymlink: Bool) throws -> CodexFileSnapshot? {
        if refuseSymlink {
            var linkInfo = stat()
            let result = path.withCString { Darwin.lstat($0, &linkInfo) }
            if result == 0 {
                if (linkInfo.st_mode & S_IFMT) == S_IFLNK {
                    throw CodexHooksError(message: "refusing to read symlink \(path)")
                }
            } else if errno != ENOENT {
                throw codexPOSIXError("inspect", path: path)
            }
        }
        let descriptor = path.withCString { Darwin.open($0, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW) }
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw codexPOSIXError("open", path: path)
        }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw codexPOSIXError("inspect", path: path) }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw CodexHooksError(message: "\(path) is not a regular file; refusing to read it")
        }
        guard info.st_size >= 0, info.st_size <= Int64(limit) else {
            throw CodexHooksError(message: "\(path) exceeds 16 MiB")
        }
        var data = Data()
        data.reserveCapacity(Int(info.st_size))
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw codexPOSIXError("read", path: path)
            }
            data.append(buffer, count: count)
            guard data.count <= limit else { throw CodexHooksError(message: "\(path) exceeds 16 MiB") }
        }
        return CodexFileSnapshot(data: data, mode: info.st_mode & 0o777)
    }

    func codexHooksRoot(from data: Data?, path: String) throws -> [String: Any] {
        guard let data else { return [:] }
        let value: Any
        do { value = try JSONSerialization.jsonObject(with: data) }
        catch { throw CodexHooksError(message: "\(path) is not valid JSON: \(error.localizedDescription)") }
        guard let root = value as? [String: Any] else {
            throw CodexHooksError(message: "\(path) must contain a JSON object")
        }
        return root
    }

    func codexRewriteHooks(_ source: [String: Any], install: Bool) throws -> [String: Any] {
        var root = source
        let rawHooks = root["hooks"]
        guard rawHooks == nil || rawHooks is [String: Any] else {
            throw CodexHooksError(message: "hooks.json hooks must be an object")
        }
        if rawHooks == nil, !install { return root }
        var hooks = rawHooks as? [String: Any] ?? [:]
        for event in Array(hooks.keys) {
            guard let rawGroups = hooks[event] as? [Any] else {
                throw CodexHooksError(message: "hooks.json event \(event) must be an array")
            }
            // Codex trust keys are positional. On install the first owned handler of
            // a spec event is rewritten where it stands so foreign handlers that
            // follow it keep their (group, handler) positions.
            let spec = install ? Self.codexHookSpecs.first { $0.event == event } : nil
            var updatedInPlace = false
            var rewritten: [[String: Any]] = []
            for (groupIndex, rawGroup) in rawGroups.enumerated() {
                guard var group = rawGroup as? [String: Any] else {
                    throw CodexHooksError(message: "hooks.json \(event) group \(groupIndex) must be an object")
                }
                guard let rawHandlers = group["hooks"] as? [Any] else {
                    throw CodexHooksError(message: "hooks.json \(event) group \(groupIndex).hooks must be an array")
                }
                var handlers: [[String: Any]] = []
                var ownedOnlyGroup = false
                for (handlerIndex, rawHandler) in rawHandlers.enumerated() {
                    guard let handler = rawHandler as? [String: Any] else {
                        throw CodexHooksError(message: "hooks.json \(event) handler \(handlerIndex) must be an object")
                    }
                    if let command = handler["command"], !(command is String) {
                        throw CodexHooksError(message: "hooks.json \(event) handler \(handlerIndex).command must be a string")
                    }
                    if !codexIsOwnedHandler(handler, event: event) {
                        handlers.append(handler)
                    } else if let spec, !updatedInPlace {
                        updatedInPlace = true
                        handlers.append(Self.codexCanonicalHandler(spec))
                        ownedOnlyGroup = rawHandlers.count == 1
                    }
                }
                if ownedOnlyGroup {
                    // A group holding only Programa's handler is replaced whole so a
                    // stale matcher cannot narrow it.
                    rewritten.append(["hooks": handlers])
                } else if !handlers.isEmpty {
                    group["hooks"] = handlers
                    rewritten.append(group)
                }
            }
            if rewritten.isEmpty { hooks.removeValue(forKey: event) }
            else { hooks[event] = rewritten }
        }
        if install {
            for spec in Self.codexHookSpecs {
                var groups = hooks[spec.event] as? [[String: Any]] ?? []
                let hasOwned = groups.contains { group in
                    (group["hooks"] as? [[String: Any]] ?? []).contains { codexIsOwnedHandler($0, event: spec.event) }
                }
                if !hasOwned {
                    groups.append(["hooks": [Self.codexCanonicalHandler(spec)]])
                }
                hooks[spec.event] = groups
            }
        }
        root["hooks"] = hooks
        try codexValidateForeignHandlerPositions(before: source, after: root)
        return root
    }

    private static func codexCanonicalHandler(_ spec: CodexHookSpec) -> [String: Any] {
        [
            "type": "command",
            "command": codexHookCommand(spec.commandEvent),
            "timeout": spec.timeout,
        ]
    }

    private func codexValidateForeignHandlerPositions(
        before: [String: Any],
        after: [String: Any]
    ) throws {
        for spec in Self.codexHookSpecs {
            let oldPositions = codexForeignHandlerPositions(root: before, event: spec.event)
            let newPositions = codexForeignHandlerPositions(root: after, event: spec.event)
            guard oldPositions.count == newPositions.count else {
                throw CodexHooksError(message: "rewriting \(spec.event) would change the foreign handler set; refusing to reuse Codex trust positions")
            }
            for (index, pair) in zip(oldPositions, newPositions).enumerated() where pair.0 != pair.1 {
                throw CodexHooksError(
                    message: "rewriting \(spec.event) would move foreign handler \(index) from \(pair.0.0):\(pair.0.1) to \(pair.1.0):\(pair.1.1); refusing to reuse Codex trust positions"
                )
            }
        }
    }

    private func codexForeignHandlerPositions(root: [String: Any], event: String) -> [(Int, Int)] {
        guard let hooks = root["hooks"] as? [String: Any],
              let groups = hooks[event] as? [[String: Any]] else { return [] }
        var positions: [(Int, Int)] = []
        for (groupIndex, group) in groups.enumerated() {
            guard let handlers = group["hooks"] as? [[String: Any]] else { continue }
            for (handlerIndex, handler) in handlers.enumerated() where !codexIsOwnedHandler(handler, event: event) {
                positions.append((groupIndex, handlerIndex))
            }
        }
        return positions
    }

    private func codexIsOwnedHandler(_ handler: [String: Any], event: String) -> Bool {
        guard let commandEvent = Self.codexOwnedCommandEventByHookEvent[event],
              let command = handler["command"] as? String else { return false }
        return command == Self.codexHookCommand(commandEvent)
            || command == "programa codex-hook \(commandEvent)"
    }

    func codexEncodeHooks(_ root: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(root) else {
            throw CodexHooksError(message: "merged hooks.json is not serializable")
        }
        var data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        data.append(0x0A)
        return data
    }

    func codexExpectedTrustEntries(hooksPath: String, root: [String: Any]) throws -> [String: String] {
        var result: [String: String] = [:]
        for spec in Self.codexHookSpecs {
            let entry = try codexOwnedHookEntry(root: root, spec: spec)
            let key = "\(hooksPath):\(spec.label):\(entry.groupIndex):\(entry.handlerIndex)"
            result[key] = try codexTrustHash(label: spec.label, group: entry.group, handler: entry.handler)
        }
        return result
    }

    private func codexOwnedHookEntry(
        root: [String: Any],
        spec: CodexHookSpec
    ) throws -> (groupIndex: Int, handlerIndex: Int, group: [String: Any], handler: [String: Any]) {
        guard let hooks = root["hooks"] as? [String: Any],
              let groups = hooks[spec.event] as? [[String: Any]] else {
            throw CodexHooksError(message: "installed Codex hook for \(spec.event) is missing")
        }
        for (groupIndex, group) in groups.enumerated() {
            guard let handlers = group["hooks"] as? [[String: Any]] else { continue }
            for (handlerIndex, handler) in handlers.enumerated() where codexIsOwnedHandler(handler, event: spec.event) {
                return (groupIndex, handlerIndex, group, handler)
            }
        }
        throw CodexHooksError(message: "installed Codex hook for \(spec.event) is missing")
    }

    func codexOwnedTrustEntries(hooksPath: String, root: [String: Any]) -> [String: String] {
        guard let hooks = root["hooks"] as? [String: Any] else { return [:] }
        let labels = Dictionary(uniqueKeysWithValues: Self.codexHookSpecs.map { ($0.event, $0.label) })
        var entries: [String: String] = [:]
        for (event, rawGroups) in hooks {
            guard let label = labels[event], let groups = rawGroups as? [[String: Any]] else { continue }
            for (groupIndex, group) in groups.enumerated() {
                guard let handlers = group["hooks"] as? [[String: Any]] else { continue }
                for (handlerIndex, handler) in handlers.enumerated() where codexIsOwnedHandler(handler, event: event) {
                    entries["\(hooksPath):\(label):\(groupIndex):\(handlerIndex)"] =
                        try? codexTrustHash(label: label, group: group, handler: handler)
                }
            }
        }
        return entries
    }

    func codexOwnedTrustHashes() throws -> Set<String> {
        var hashes: Set<String> = []
        for spec in Self.codexHookSpecs {
            let group: [String: Any] = [:]
            let handler: [String: Any] = [
                "type": "command",
                "command": Self.codexHookCommand(spec.commandEvent),
                "timeout": spec.timeout,
            ]
            hashes.insert(try codexTrustHash(label: spec.label, group: group, handler: handler))
        }
        return hashes
    }

    private func codexTrustHash(label: String, group: [String: Any], handler: [String: Any]) throws -> String {
        guard (handler["type"] as? String) == "command",
              let command = handler["command"] as? String else {
            throw CodexHooksError(message: "Codex hook \(label) must be a command handler")
        }
        let asynchronous: Bool
        if let value = handler["async"] {
            guard let value = value as? Bool else { throw CodexHooksError(message: "Codex hook async must be a boolean") }
            asynchronous = value
        } else {
            asynchronous = false
        }
        var normalized: [String: Any] = [
            "async": asynchronous,
            "command": command,
            "timeout": try codexNormalizedTimeout(label: label, value: handler["timeout"]),
            "type": "command",
        ]
        if let status = handler["statusMessage"] {
            guard let status = status as? String else { throw CodexHooksError(message: "Codex hook statusMessage must be a string") }
            normalized["statusMessage"] = status
        }
        if let rawLimit = handler["additionalContextLimit"] {
            let limit = try codexInteger(rawLimit, field: "additionalContextLimit")
            if ["pre_tool_use", "post_tool_use", "session_start", "user_prompt_submit", "subagent_start"].contains(label),
               limit != 2_500 {
                normalized["additionalContextLimit"] = limit
            }
        }
        var identity: [String: Any] = ["event_name": label, "hooks": [normalized]]
        if label != "user_prompt_submit", label != "stop", let matcher = group["matcher"] {
            guard let matcher = matcher as? String else { throw CodexHooksError(message: "Codex hook matcher must be a string") }
            identity["matcher"] = matcher
        }
        let data = try JSONSerialization.data(withJSONObject: identity, options: [.sortedKeys, .withoutEscapingSlashes])
        return "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func codexNormalizedTimeout(label: String, value: Any?) throws -> Int {
        let fallback = label == "session_end" ? 1 : 600
        let timeout = value == nil ? fallback : try codexInteger(value!, field: "timeout")
        return label == "session_end" ? min(max(timeout, 1), 3) : max(timeout, 1)
    }

    private func codexInteger(_ value: Any, field: String) throws -> Int {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            throw CodexHooksError(message: "Codex hook \(field) must be an integer")
        }
        let double = number.doubleValue
        guard double.rounded() == double, double >= Double(Int.min), double <= Double(Int.max) else {
            throw CodexHooksError(message: "Codex hook \(field) must be an integer")
        }
        return number.intValue
    }

    func codexPrepareConfig(_ edit: CodexTrustEdit) throws -> CodexPreparedConfig {
        let snapshot = try codexReadRegularFile(edit.configPath, limit: Self.codexMaximumFileBytes, refuseSymlink: true)
        let original = try codexUTF8(snapshot?.data ?? Data(), path: edit.configPath)
        let rendered = try codexRenderConfig(original, edit: edit)
        try codexProbeWritableDirectory((edit.configPath as NSString).deletingLastPathComponent)
        for warning in rendered.warnings { FileHandle.standardError.write(Data((warning + "\n").utf8)) }
        return CodexPreparedConfig(edit: edit, snapshot: snapshot, rendered: Data(rendered.text.utf8))
    }

    func codexCommitConfig(_ prepared: CodexPreparedConfig) throws {
        let resolvedTarget = try codexResolveConfigTarget(prepared.edit.configLinkPath)
        guard resolvedTarget == prepared.edit.configPath else {
            throw CodexHooksError(message: "\(prepared.edit.configLinkPath) changed targets during installation; retry the command")
        }
        let current = try codexReadRegularFile(prepared.edit.configPath, limit: Self.codexMaximumFileBytes, refuseSymlink: true)
        let rendered: Data
        if current == prepared.snapshot {
            rendered = prepared.rendered
        } else {
            let fresh = try codexUTF8(current?.data ?? Data(), path: prepared.edit.configPath)
            rendered = Data(try codexRenderConfig(fresh, edit: prepared.edit).text.utf8)
        }
        guard (current?.data ?? Data()) != rendered else { return }
        try codexAtomicWrite(rendered, to: prepared.edit.configPath, mode: current?.mode ?? 0o600)
    }

    private func codexRenderConfig(_ source: String, edit: CodexTrustEdit) throws -> CodexRenderedConfig {
        let originalTree = try codexParseTOML(source, path: edit.configPath)
        try codexValidateTrustShape(originalTree, path: edit.configPath)
        let newline = codexNewline(in: source)

        var working = source
        for (begin, end) in [
            (Self.codexTrustBlockStart, Self.codexTrustBlockEnd),
            (Self.codexLegacyTrustBlockStart, Self.codexLegacyTrustBlockEnd),
        ] {
            let removal = try codexRemovingBlock(working, begin: begin, end: end)
            if let interior = removal.interior { try codexValidateLegacyBlock(interior, edit: edit) }
            working = removal.text
        }

        // The current block is rewritten whole, in place, so its contents never need
        // validating. `head` and `tail` are the text before and after it.
        let lines = codexTOMLLines(working)
        let block = try codexBlockRange(lines, begin: Self.codexBlockBegin, end: Self.codexBlockEnd)
        let hadBlock = block != nil
        var head = working
        var tail = ""
        var blockKeys = Set<String>()
        if let block {
            let interior = lines[(block.begin + 1)..<block.end].map { String(working.unicodeScalars[$0.range]) }.joined()
            if let tree = try? codexParseTOML(interior, path: edit.configPath) {
                blockKeys = Set(tree.tableValue?["hooks"]?.tableValue?["state"]?.tableValue?.keys.map { $0 } ?? [])
            }
            head = codexJoinLines(working, lines, removing: Set(block.first..<lines.count))
            tail = codexJoinLines(working, lines, removing: Set(0...block.end))
            working = head + tail
        }

        // Migration runs only until the first block exists, so a user's own
        // `codex_hooks = true` written after that point is never touched.
        var removedFeatureFlag = false
        if !hadBlock {
            let migration = try codexMigratingLegacyLines(working, edit: edit)
            working = migration.text
            removedFeatureFlag = migration.removedFeatureFlag
        }
        let baseTree = try codexParseTOML(working, path: edit.configPath)
        let state = baseTree.tableValue?["hooks"]?.tableValue?["state"]?.tableValue ?? [:]
        let originalState = originalTree.tableValue?["hooks"]?.tableValue?["state"]?.tableValue ?? [:]
        let removedKeys = Set(originalState.keys).subtracting(state.keys)
        guard removedKeys.subtracting(blockKeys).allSatisfy({ $0.hasPrefix(edit.hooksKeyPrefix) }) else {
            throw CodexHooksError(message: "Codex config verification failed: foreign trust state would be removed; refusing to write")
        }
        var entries: [(key: String, hash: String)] = []
        var warnings: [String] = []
        for (key, hash) in edit.desired.sorted(by: { $0.key < $1.key }) {
            if state[key] != nil {
                warnings.append("warning: \(edit.configLinkPath) already defines [hooks.state.\(try codexTOMLQuoted(key))] outside the Programa block; leaving it unchanged and not trusting that hook")
            } else {
                entries.append((key, hash))
            }
        }

        var blockText = ""
        if !entries.isEmpty {
            blockText += Self.codexBlockBegin + newline
            for (index, entry) in entries.enumerated() {
                if index > 0 { blockText += newline }
                blockText += "[hooks.state.\(try codexTOMLQuoted(entry.key))]\(newline)"
                blockText += "trusted_hash = \(try codexTOMLQuoted(entry.hash))\(newline)"
            }
            blockText += Self.codexBlockEnd + newline
        }
        // An existing block is replaced where it stands; a new one goes at the end
        // after one blank line. The block holds full table headers only, so it does
        // not matter which table the file ends in.
        let separator = blockText.isEmpty ? "" : newline
        if hadBlock {
            working = head + (head.isEmpty ? "" : separator) + blockText + tail
        } else if !blockText.isEmpty {
            if !working.isEmpty {
                if working.utf8.last != 0x0A { working += newline }
                working += newline
            }
            working += blockText
        }

        let renderedTree: CodexTOMLValue
        do { renderedTree = try codexParseTOML(working, path: edit.configPath) }
        catch {
            throw CodexHooksError(message: "cannot add Programa trust entries to \(edit.configPath): hooks is defined in a form that cannot be extended (\(error.localizedDescription))")
        }
        let renderedState = renderedTree.tableValue?["hooks"]?.tableValue?["state"]?.tableValue ?? [:]
        for entry in entries {
            guard renderedState[entry.key]?.tableValue?["trusted_hash"]?.stringValue == entry.hash else {
                throw CodexHooksError(message: "Codex trust entry \(entry.key) did not render correctly")
            }
        }
        guard Self.codexStripped(renderedTree, stateKeys: Set(entries.map(\.key)), featureFlag: false)
                == Self.codexStripped(originalTree, stateKeys: removedKeys, featureFlag: removedFeatureFlag) else {
            throw CodexHooksError(message: "Codex config changed outside the Programa block; refusing to write")
        }
        return CodexRenderedConfig(text: working, warnings: warnings)
    }

    private func codexValidateTrustShape(_ root: CodexTOMLValue, path: String) throws {
        guard let table = root.tableValue else { throw CodexHooksError(message: "\(path) must contain a TOML table") }
        if let hooks = table["hooks"] {
            guard let hooksTable = hooks.tableValue else {
                throw CodexHooksError(message: "hooks in \(path) is not a table, so Codex cannot read trust state")
            }
            if let state = hooksTable["state"], state.tableValue == nil {
                throw CodexHooksError(message: "hooks.state in \(path) is not a table")
            }
        }
    }

    /// Drops the named trust entries and feature flag, then every empty table, so two
    /// trees compare equal when they differ only by Programa-owned or now-empty tables.
    private static func codexStripped(_ tree: CodexTOMLValue, stateKeys: Set<String>, featureFlag: Bool) -> CodexTOMLValue? {
        var root = tree.tableValue ?? [:]
        if featureFlag, var features = root["features"]?.tableValue {
            features.removeValue(forKey: "codex_hooks")
            root["features"] = .table(features)
        }
        if var hooks = root["hooks"]?.tableValue, var state = hooks["state"]?.tableValue {
            for key in stateKeys { state.removeValue(forKey: key) }
            hooks["state"] = .table(state)
            root["hooks"] = .table(hooks)
        }
        func pruned(_ value: CodexTOMLValue) -> CodexTOMLValue? {
            guard case .table(let table) = value else { return value }
            let kept = table.compactMapValues(pruned)
            return kept.isEmpty ? nil : .table(kept)
        }
        return pruned(.table(root))
    }

    private func codexParseTOML(_ source: String, path: String) throws -> CodexTOMLValue {
        let decoder = TOMLDecoder()
        decoder.limits = .init(
            maxInputSize: Self.codexMaximumFileBytes,
            maxDepth: 128,
            maxTableKeys: 100_000,
            maxArrayLength: 100_000,
            maxStringLength: Self.codexMaximumFileBytes
        )
        do { return .table(try decoder.decode([String: CodexTOMLValue].self, from: source)) }
        catch { throw CodexHooksError(message: "\(path) is not valid TOML: \(error.localizedDescription)") }
    }

    /// Locates a marker-delimited block. The range starts at the blank line the
    /// installer put before the block, when there is one.
    private func codexBlockRange(
        _ lines: [CodexTOMLLine],
        begin: String,
        end: String
    ) throws -> (first: Int, begin: Int, end: Int)? {
        let starts = lines.indices.filter { !lines[$0].startsInString && lines[$0].text == begin }
        let ends = lines.indices.filter { !lines[$0].startsInString && lines[$0].text == end }
        guard starts.count <= 1, ends.count <= 1, starts.count == ends.count else {
            throw CodexHooksError(message: "Codex config contains duplicate or unmatched Programa markers")
        }
        guard let start = starts.first, let finish = ends.first else { return nil }
        guard start < finish else {
            throw CodexHooksError(message: "Codex config contains mismatched Programa markers")
        }
        // An assignment after the end marker belongs to the block's last table; removing
        // or rewriting the block would silently move it into another table.
        for index in (finish + 1)..<lines.count where !lines[index].startsInString {
            let text = lines[index].text.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("[") { break }
            guard text.isEmpty || text.hasPrefix("#") else {
                throw CodexHooksError(message: "Codex config has settings right after the Programa block that would change meaning if the block moved; put them under their own [table] or above the block")
            }
        }
        let blankBefore = start > 0 && !lines[start - 1].startsInString && lines[start - 1].text.isEmpty
        return (blankBefore ? start - 1 : start, start, finish)
    }

    private func codexRemovingBlock(
        _ source: String,
        begin: String,
        end: String
    ) throws -> (text: String, interior: String?) {
        let lines = codexTOMLLines(source)
        guard let block = try codexBlockRange(lines, begin: begin, end: end) else { return (source, nil) }
        let interior = lines[(block.begin + 1)..<block.end].map { String(source.unicodeScalars[$0.range]) }.joined()
        return (codexJoinLines(source, lines, removing: Set(block.first...block.end)), interior)
    }

    private func codexJoinLines(_ source: String, _ lines: [CodexTOMLLine], removing: Set<Int>) -> String {
        var result = ""
        for (index, line) in lines.enumerated() where !removing.contains(index) {
            result += String(source.unicodeScalars[line.range])
        }
        return result
    }

    /// Older installers wrote trust tables between their own markers. The block must
    /// hold only trust tables for this hooks file; anything else is the user's.
    private func codexValidateLegacyBlock(_ interior: String, edit: CodexTrustEdit) throws {
        let tree = try codexParseTOML(interior, path: edit.configPath)
        let state = tree.tableValue?["hooks"]?.tableValue?["state"]?.tableValue ?? [:]
        let programaHashes = edit.ownedHashes.union(edit.desired.values)
        var expectedLines = Set<String>()
        for (key, value) in state {
            guard key.hasPrefix(edit.hooksKeyPrefix),
                  let hash = value.tableValue?["trusted_hash"]?.stringValue,
                  programaHashes.contains(hash) || edit.previousOwned[key] == hash else {
                throw CodexHooksError(message: "Programa trust block contains an entry Programa does not own: \(key)")
            }
            expectedLines.insert("[hooks.state.\(try codexTOMLQuoted(key))]")
            expectedLines.insert("trusted_hash=\(try codexTOMLQuoted(hash))")
        }
        var contentLines = 0
        for line in codexTOMLLines(interior) {
            let text = line.text.trimmingCharacters(in: .whitespaces)
            if text.isEmpty { continue }
            contentLines += 1
            guard expectedLines.contains(text.hasPrefix("[") ? text : text.filter({ !$0.isWhitespace })) else {
                throw CodexHooksError(message: "Programa trust block contains comments or unrecognized content")
            }
        }
        guard !state.isEmpty, contentLines == state.count * 2 else {
            throw CodexHooksError(message: "Programa trust block contains comments or unrecognized content")
        }
    }

    /// Removes exactly what the older installers wrote outside any block: a
    /// `codex_hooks = true` line under `[features]`, and `[hooks.state."<key>"]` tables
    /// that hold a single `trusted_hash` equal to a hash Programa produces.
    private func codexMigratingLegacyLines(
        _ source: String,
        edit: CodexTrustEdit
    ) throws -> (text: String, removedKeys: Set<String>, removedFeatureFlag: Bool) {
        let lines = codexTOMLLines(source)
        let tree = try codexParseTOML(source, path: edit.configPath)
        let state = tree.tableValue?["hooks"]?.tableValue?["state"]?.tableValue ?? [:]
        let programaHashes = edit.ownedHashes.union(edit.desired.values)
        let headers = lines.indices.compactMap { index -> (index: Int, text: String)? in
            let text = lines[index].text.trimmingCharacters(in: .whitespaces)
            return !lines[index].startsInString && text.hasPrefix("[") ? (index, text) : nil
        }
        func sectionEnd(_ position: Int) -> Int { position + 1 < headers.count ? headers[position + 1].index : lines.count }

        var removal = Set<Int>()
        var removedFeatureFlag = false
        for (position, header) in headers.enumerated() where header.text == "[features]" {
            for index in (header.index + 1)..<sectionEnd(position)
            where !lines[index].startsInString && lines[index].text.filter({ !$0.isWhitespace }) == "codex_hooks=true" {
                removal.insert(index)
                removedFeatureFlag = true
            }
        }

        var removedKeys = Set<String>()
        for (key, value) in state where key.hasPrefix(edit.hooksKeyPrefix) {
            guard let hash = value.tableValue?["trusted_hash"]?.stringValue,
                  programaHashes.contains(hash) || edit.previousOwned[key] == hash else { continue }
            let header = "[hooks.state.\(try codexTOMLQuoted(key))]"
            let matches = headers.indices.filter { headers[$0].text == header }
            guard matches.count == 1 else {
                throw CodexHooksError(message: "Programa trust entry \(key) in \(edit.configPath) is not a plain table and cannot be removed safely")
            }
            let position = matches[0]
            let content = ((headers[position].index + 1)..<sectionEnd(position)).filter {
                !lines[$0].text.trimmingCharacters(in: .whitespaces).isEmpty
            }
            guard content.count == 1,
                  lines[content[0]].text.filter({ !$0.isWhitespace }) == "trusted_hash=\(try codexTOMLQuoted(hash))" else {
                throw CodexHooksError(message: "trust entry \(key) contains fields or comments that Programa cannot remove safely")
            }
            removal.formUnion(headers[position].index..<sectionEnd(position))
            removedKeys.insert(key)
        }
        return (codexJoinLines(source, lines, removing: removal), removedKeys, removedFeatureFlag)
    }

    private func codexTOMLLines(_ source: String) -> [CodexTOMLLine] {
        var result: [CodexTOMLLine] = []
        var mode = CodexTOMLStringMode.none
        let scalars = source.unicodeScalars
        var cursor = scalars.startIndex
        while cursor < scalars.endIndex {
            let newline = scalars[cursor...].firstIndex(of: "\n")
            let lineEnd = newline.map { scalars.index(after: $0) } ?? scalars.endIndex
            var contentEnd = newline ?? scalars.endIndex
            if contentEnd > cursor, scalars[scalars.index(before: contentEnd)] == "\r" {
                contentEnd = scalars.index(before: contentEnd)
            }
            let startsInString = mode != .none
            let text = String(scalars[cursor..<contentEnd])
            result.append(.init(range: cursor..<lineEnd, text: text, startsInString: startsInString))
            mode = codexAdvanceStringMode(in: text, from: mode)
            cursor = lineEnd
        }
        return result
    }

    private func codexAdvanceStringMode(
        in line: String,
        from initial: CodexTOMLStringMode
    ) -> CodexTOMLStringMode {
        var mode = initial
        var cursor = line.startIndex
        while cursor < line.endIndex {
            let suffix = line[cursor...]
            switch mode {
            case .none:
                if line[cursor] == "#" { return .none }
                if suffix.hasPrefix("\"\"\"") {
                    mode = .multilineBasic
                    cursor = line.index(cursor, offsetBy: 3)
                } else if suffix.hasPrefix("'''") {
                    mode = .multilineLiteral
                    cursor = line.index(cursor, offsetBy: 3)
                } else if line[cursor] == "\"" {
                    mode = .basic
                    cursor = line.index(after: cursor)
                } else if line[cursor] == "'" {
                    mode = .literal
                    cursor = line.index(after: cursor)
                } else {
                    cursor = line.index(after: cursor)
                }
            case .basic:
                if line[cursor] == "\\" {
                    cursor = line.index(after: cursor)
                    if cursor < line.endIndex { cursor = line.index(after: cursor) }
                } else {
                    if line[cursor] == "\"" { mode = .none }
                    cursor = line.index(after: cursor)
                }
            case .literal:
                if line[cursor] == "'" { mode = .none }
                cursor = line.index(after: cursor)
            case .multilineBasic:
                if suffix.hasPrefix("\"\"\"") {
                    mode = .none
                    cursor = line.index(cursor, offsetBy: 3)
                } else if line[cursor] == "\\" {
                    cursor = line.index(after: cursor)
                    if cursor < line.endIndex { cursor = line.index(after: cursor) }
                } else {
                    cursor = line.index(after: cursor)
                }
            case .multilineLiteral:
                if suffix.hasPrefix("'''") {
                    mode = .none
                    cursor = line.index(cursor, offsetBy: 3)
                } else {
                    cursor = line.index(after: cursor)
                }
            }
        }
        return mode
    }

    private func codexNewline(in source: String) -> String {
        let scalars = source.unicodeScalars
        guard let newline = scalars.firstIndex(of: "\n") else { return "\n" }
        return newline > scalars.startIndex && scalars[scalars.index(before: newline)] == "\r" ? "\r\n" : "\n"
    }

    private func codexTOMLQuoted(_ value: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [value], options: [.withoutEscapingSlashes])
        let encoded = String(decoding: data, as: UTF8.self)
        return String(encoded.dropFirst().dropLast())
    }

    private func codexUTF8(_ data: Data, path: String) throws -> String {
        guard let value = String(data: data, encoding: .utf8) else {
            throw CodexHooksError(message: "\(path) is not valid UTF-8")
        }
        return value
    }

    private func codexProbeWritableDirectory(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: nil)
        let probe = (path as NSString).appendingPathComponent(".programa-preflight-\(UUID().uuidString)")
        let descriptor = probe.withCString { Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600) }
        guard descriptor >= 0 else { throw codexPOSIXError("preflight write access to", path: path) }
        Darwin.close(descriptor)
        guard unlink(probe) == 0 else { throw codexPOSIXError("remove preflight", path: probe) }
    }

    func codexAtomicWrite(_ data: Data, to path: String, mode: mode_t) throws {
        var targetInfo = stat()
        if path.withCString({ Darwin.lstat($0, &targetInfo) }) == 0 {
            guard (targetInfo.st_mode & S_IFMT) == S_IFREG else {
                throw CodexHooksError(message: "refusing to replace non-regular file \(path)")
            }
        } else if errno != ENOENT {
            throw codexPOSIXError("inspect", path: path)
        }
        let parent = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true, attributes: nil)
        let directoryDescriptor = try codexOpenDirectory(parent)
        defer { Darwin.close(directoryDescriptor) }
        let name = (path as NSString).lastPathComponent
        let temporary = (parent as NSString).appendingPathComponent(".\(name).programa-\(UUID().uuidString)")
        let descriptor = temporary.withCString { Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode) }
        guard descriptor >= 0 else { throw codexPOSIXError("create", path: temporary) }
        var shouldRemove = true
        var descriptorIsOpen = true
        defer {
            if descriptorIsOpen { Darwin.close(descriptor) }
            if shouldRemove { unlink(temporary) }
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw codexPOSIXError("write", path: temporary)
                }
                offset += count
            }
        }
        guard fchmod(descriptor, mode) == 0 else { throw codexPOSIXError("set mode", path: temporary) }
        guard fsync(descriptor) == 0 else { throw codexPOSIXError("sync", path: temporary) }
        guard Darwin.close(descriptor) == 0 else { throw codexPOSIXError("close", path: temporary) }
        descriptorIsOpen = false
        var replacementInfo = stat()
        if path.withCString({ Darwin.lstat($0, &replacementInfo) }) == 0,
           (replacementInfo.st_mode & S_IFMT) != S_IFREG {
            throw CodexHooksError(message: "refusing to replace non-regular file \(path)")
        }
        guard rename(temporary, path) == 0 else { throw codexPOSIXError("replace", path: path) }
        shouldRemove = false
        codexSyncDirectoryAfterCommit(directoryDescriptor, path: parent)
    }

    func codexRestoreFile(_ snapshot: CodexFileSnapshot?, at path: String) throws {
        if let snapshot {
            try codexAtomicWrite(snapshot.data, to: path, mode: snapshot.mode)
            return
        }
        let parent = (path as NSString).deletingLastPathComponent
        let directoryDescriptor = try codexOpenDirectory(parent)
        defer { Darwin.close(directoryDescriptor) }
        if unlink(path) != 0 {
            if errno == ENOENT { return }
            throw codexPOSIXError("remove", path: path)
        }
        codexSyncDirectoryAfterCommit(directoryDescriptor, path: parent)
    }

    private func codexOpenDirectory(_ path: String) throws -> Int32 {
        let descriptor = path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC) }
        guard descriptor >= 0 else { throw codexPOSIXError("open directory", path: path) }
        return descriptor
    }

    private func codexSyncDirectoryAfterCommit(_ descriptor: Int32, path: String) {
        guard fsync(descriptor) != 0 else { return }
        let message = "warning: committed Codex hook change, but syncing directory \(path) failed: \(String(cString: strerror(errno)))\n"
        FileHandle.standardError.write(Data(message.utf8))
    }

    private func codexPOSIXError(_ action: String, path: String) -> Error {
        let code = errno
        return CodexHooksError(message: "\(action) \(path): \(String(cString: strerror(code)))")
    }
}
