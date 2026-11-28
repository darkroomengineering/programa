import Darwin
import Foundation

nonisolated struct MobileChatRepositoryConfiguration: Sendable {
    let id: UUID
    let name: String
    let checkout: URL
}

actor MobileChatJobs {
    private struct Record: Codable, Sendable {
        var job: MobileChatJob
        var messages: [MobileChatMessage]
        let peerID: String
        let checkout: URL
        let sessionID: UUID
        var worktree: URL?
        var attemptedClaude = false
    }

    private enum JobError: Error {
        case invalidConfiguration, worktreeUnavailable, workerFailed
    }

    private let directory: URL
    private let repositories: [MobileChatRepositoryConfiguration]
    private var claudeExecutable: URL
    private let worktreesDirectory: String
    private var records: [UUID: Record] = [:]
    private var active: Set<UUID> = []

    private static let simultaneousJobs = 4
    private static let jobLimit = 64
    private static let messageLimit = 512
    private static let pageLimit = 24
    private static let outputLimit = 8 * 1024 * 1024
    private static let workerTimeout: TimeInterval = 10 * 60

    init(directory: URL, repositories: [MobileChatRepositoryConfiguration], claudeExecutable: URL) throws {
        guard directory.isFileURL,
              !repositories.isEmpty, repositories.count <= Self.jobLimit,
              Set(repositories.map(\.id)).count == repositories.count,
              repositories.allSatisfy({ $0.checkout.isFileURL && !$0.name.isEmpty && $0.name.utf8.count <= 160 }) else {
            throw JobError.invalidConfiguration
        }
        self.directory = directory
        self.repositories = repositories.map {
            MobileChatRepositoryConfiguration(
                id: $0.id, name: $0.name, checkout: $0.checkout.standardizedFileURL.resolvingSymlinksInPath()
            )
        }
        self.claudeExecutable = try Self.validatedClaudeExecutable(claudeExecutable)
        worktreesDirectory = StorageSettings.read().directory
        try Self.prepareStorage(directory)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for file in files where file.pathExtension == "json" {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent) else { continue }
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 32 * 1024 * 1024 else {
                throw JobError.invalidConfiguration
            }
            var record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: file))
            guard id == record.job.id, records.updateValue(record, forKey: id) == nil else {
                throw JobError.invalidConfiguration
            }
            if record.job.state == .running {
                record.job = Self.update(record.job, state: .interrupted)
                try Self.write(record, to: file)
                records[id] = record
            }
        }
        Task { await self.schedule() }
    }

    func updateClaudeExecutable(_ executable: URL) throws {
        claudeExecutable = try Self.validatedClaudeExecutable(executable)
    }

    func handle(_ request: MobileChatRequest, peerID: String) async -> MobileChatResponse {
        guard !peerID.isEmpty, peerID.utf8.count <= 256 else { return .failure(.unauthorized) }
        switch request {
        case .pair:
            return .failure(.invalidRequest)
        case .list:
            return .snapshot(MobileChatSnapshot(
                repositories: repositories.map { MobileChatRepository(id: $0.id, name: $0.name) },
                jobs: records.values.filter { $0.peerID == peerID }.map(\.job).sorted {
                    if $0.updatedAt == $1.updatedAt { return $0.id.uuidString < $1.id.uuidString }
                    return $0.updatedAt > $1.updatedAt
                }
            ))
        case let .start(jobID, messageID, repositoryID, prompt):
            return start(jobID: jobID, messageID: messageID, repositoryID: repositoryID, prompt: prompt, peerID: peerID)
        case let .reply(jobID, messageID, prompt):
            return reply(jobID: jobID, messageID: messageID, prompt: prompt, peerID: peerID)
        case let .history(jobID, before):
            return history(jobID: jobID, before: before, peerID: peerID)
        }
    }

    private func start(jobID: UUID, messageID: UUID, repositoryID: UUID, prompt: String, peerID: String) -> MobileChatResponse {
        guard let text = Self.promptText(prompt) else { return .failure(.invalidRequest) }
        if let record = records[jobID] {
            guard record.peerID == peerID else { return .failure(.notFound) }
            guard record.job.repositoryID == repositoryID,
                  let first = record.messages.first, first.id == messageID, first.text == text else {
                return .failure(.invalidRequest)
            }
            return .job(record.job)
        }
        guard let repository = repositories.first(where: { $0.id == repositoryID }) else {
            return .failure(.notFound)
        }
        guard records.count < Self.jobLimit else { return .failure(.storage) }
        let firstLine = text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? text
        let now = Date()
        let record = Record(
            job: MobileChatJob(
                id: jobID, repositoryID: repositoryID, title: Self.bounded(firstLine, bytes: 160),
                state: .queued, updatedAt: now, workspaceReference: nil
            ),
            messages: [MobileChatMessage(id: messageID, role: .user, text: text, createdAt: now)],
            peerID: peerID,
            checkout: repository.checkout,
            sessionID: UUID()
        )
        return accept(record)
    }

    private func reply(jobID: UUID, messageID: UUID, prompt: String, peerID: String) -> MobileChatResponse {
        guard let text = Self.promptText(prompt) else { return .failure(.invalidRequest) }
        guard var record = records[jobID], record.peerID == peerID else { return .failure(.notFound) }
        if let existing = record.messages.first(where: { $0.id == messageID }) {
            return existing.role == .user && existing.text == text ? .job(record.job) : .failure(.invalidRequest)
        }
        // An interrupted worker can still be running after an unclean app exit.
        guard record.job.state != .interrupted else { return .failure(.unavailable) }
        guard record.job.state != .queued, !active.contains(jobID) else { return .failure(.busy) }
        guard record.messages.count + 2 <= Self.messageLimit else { return .failure(.storage) }
        guard repositories.contains(where: { $0.id == record.job.repositoryID && $0.checkout == record.checkout }) else {
            return .failure(.unavailable)
        }
        record.job = Self.update(record.job, state: .queued)
        record.messages.append(MobileChatMessage(id: messageID, role: .user, text: text, createdAt: Date()))
        return accept(record)
    }

    private func accept(_ record: Record) -> MobileChatResponse {
        do {
            try persist(record)
            schedule()
            return .job(records[record.job.id]?.job ?? record.job)
        } catch {
            return .failure(.storage)
        }
    }

    private func history(jobID: UUID, before: UUID?, peerID: String) -> MobileChatResponse {
        guard let record = records[jobID], record.peerID == peerID else { return .failure(.notFound) }
        let end: Int
        if let before {
            guard let index = record.messages.firstIndex(where: { $0.id == before }) else { return .failure(.notFound) }
            end = index
        } else {
            end = record.messages.count
        }
        let encoder = JSONEncoder()
        var bytes = 4_096
        var start = end
        while start > 0, end - start < Self.pageLimit {
            guard let length = try? encoder.encode(record.messages[start - 1]).count else {
                return .failure(.storage)
            }
            if bytes + length + 1 > MobileChatWire.maximumResponseBytes { break }
            bytes += length + 1
            start -= 1
        }
        return .conversation(MobileChatConversation(
            job: record.job, messages: Array(record.messages[start..<end]), hasEarlier: start > 0
        ))
    }

    private func schedule() {
        guard active.count < Self.simultaneousJobs else { return }
        let awaiting = records.values.filter { $0.job.state == .queued }.sorted { $0.job.updatedAt < $1.job.updatedAt }
        for var record in awaiting.prefix(Self.simultaneousJobs - active.count) {
            let id = record.job.id
            record.job = Self.update(record.job, state: .running)
            do {
                try persist(record)
            } catch {
                records[id]?.job = Self.update(record.job, state: .failed)
                continue
            }
            active.insert(id)
            Task { await self.run(jobID: id) }
        }
    }

    private func run(jobID: UUID) async {
        defer {
            active.remove(jobID)
            schedule()
        }
        guard var record = records[jobID], let prompt = record.messages.last?.text else { return }
        do {
            guard repositories.contains(where: { $0.id == record.job.repositoryID && $0.checkout == record.checkout }) else {
                throw JobError.invalidConfiguration
            }
            let checkout = record.checkout
            let expected = record.worktree
            let sessionID = record.sessionID
            let branch = "programa-mobile/\(sessionID.uuidString.lowercased())"
            let worktrees = worktreesDirectory
            let tree = try await Self.blocking {
                try Self.prepareWorktree(checkout: checkout, branch: branch, baseDirectory: worktrees, expected: expected)
            }
            let reference = await Self.openWorkspace(tree, branch: branch, reference: record.job.workspaceReference)
            record.worktree = tree.url
            record.job = Self.update(record.job, state: .running, workspaceReference: reference)
            let resume = record.attemptedClaude
            record.attemptedClaude = true
            try persist(record)
            let executable = claudeExecutable
            let directory = directory
            let result = try await Self.blocking {
                try Self.runClaude(
                    executable: executable, worktree: tree.url, inputDirectory: directory,
                    sessionID: sessionID, resume: resume, prompt: prompt
                )
            }
            record.job = Self.update(record.job, state: .ready)
            record.messages.append(MobileChatMessage(id: UUID(), role: .assistant, text: result, createdAt: Date()))
            try persist(record)
        } catch {
            record.job = Self.update(record.job, state: .failed)
            do {
                try persist(record)
            } catch {
                records[jobID]?.job = Self.update(record.job, state: .interrupted)
            }
        }
    }

    private func persist(_ record: Record) throws {
        let file = directory.appendingPathComponent(record.job.id.uuidString).appendingPathExtension("json")
        try Self.write(record, to: file)
        records[record.job.id] = record
    }

    private static func write(_ record: Record, to file: URL) throws {
        try JSONEncoder().encode(record).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private static func prepareStorage(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              let mode = attributes[.posixPermissions] as? NSNumber, mode.intValue & 0o077 == 0 else {
            throw JobError.invalidConfiguration
        }
    }

    private static func validatedClaudeExecutable(_ executable: URL) throws -> URL {
        guard executable.isFileURL, FileManager.default.isExecutableFile(atPath: executable.path),
              (try executable.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else {
            throw JobError.invalidConfiguration
        }
        return executable
    }

    private static func update(
        _ job: MobileChatJob, state: MobileChatJobState, workspaceReference: UUID? = nil
    ) -> MobileChatJob {
        MobileChatJob(
            id: job.id, repositoryID: job.repositoryID, title: job.title, state: state, updatedAt: Date(),
            workspaceReference: workspaceReference ?? job.workspaceReference
        )
    }

    private static func promptText(_ prompt: String) -> String? {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= MobileChatWire.maximumPromptBytes,
              text.unicodeScalars.allSatisfy({ $0.value == 9 || $0.value == 10 || $0.value == 13 || $0.value >= 32 }) else {
            return nil
        }
        return text
    }

    private static func bounded(_ text: String, bytes: Int) -> String {
        String(decoding: text.utf8.prefix(bytes), as: UTF8.self)
    }

    private struct Worktree: Sendable {
        let url: URL
        let root: String
    }

    private static func prepareWorktree(checkout: URL, branch: String, baseDirectory: String, expected: URL?) throws -> Worktree {
        guard let root = GitWorktreeManager.resolveRepoRoot(from: checkout.path) else {
            throw JobError.worktreeUnavailable
        }
        let candidate = URL(fileURLWithPath: baseDirectory)
            .appendingPathComponent(GitWorktreeManager.repoName(forRepoRoot: root))
            .appendingPathComponent(GitWorktreeManager.branchSlug(branch))
            .standardizedFileURL.resolvingSymlinksInPath()
        if let existing = GitWorktreeManager.worktreeEntry(forBranch: branch, repoRoot: root) {
            let url = URL(fileURLWithPath: existing.path).standardizedFileURL.resolvingSymlinksInPath()
            guard url == (expected ?? candidate), FileManager.default.fileExists(atPath: url.path) else {
                throw JobError.worktreeUnavailable
            }
            return Worktree(url: url, root: root)
        }
        guard expected == nil else { throw JobError.worktreeUnavailable }
        switch GitWorktreeManager.add(repoRoot: root, branch: branch, base: nil, path: candidate.path, runCheckoutHooks: false) {
        case .success(let entry):
            return Worktree(url: URL(fileURLWithPath: entry.path).standardizedFileURL.resolvingSymlinksInPath(), root: root)
        case .worktreePathExists, .gitCommandFailed:
            throw JobError.worktreeUnavailable
        }
    }

    @MainActor
    private static func openWorkspace(_ tree: Worktree, branch: String, reference: UUID?) -> UUID? {
        guard let delegate = AppDelegate.shared else { return nil }
        let managers = delegate.listMainWindowSummaries().sorted { first, second in
            if first.isKeyWindow != second.isKeyWindow { return first.isKeyWindow }
            if first.isVisible != second.isVisible { return first.isVisible }
            return first.windowId.uuidString < second.windowId.uuidString
        }.compactMap { delegate.tabManagerFor(windowId: $0.windowId) }
        for manager in managers {
            if let workspace = manager.tabs.first(where: {
                $0.referenceID == reference ||
                    URL(fileURLWithPath: $0.currentDirectory).standardizedFileURL == tree.url.standardizedFileURL
            }) {
                return workspace.referenceID
            }
        }
        return managers.first?.addWorktreeWorkspace(
            path: tree.url.path, branch: branch, repoRoot: tree.root, select: false, eagerLoadTerminal: false
        ).referenceID
    }

    private static func blocking<Value: Sendable>(_ action: @escaping @Sendable () throws -> Value) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result(catching: action))
            }
        }
    }

    private struct ClaudeResult: Decodable {
        let type: String
        let is_error: Bool
        let session_id: UUID
        let result: String
    }

    private static func runClaude(
        executable: URL, worktree: URL, inputDirectory: URL, sessionID: UUID, resume: Bool, prompt: String
    ) throws -> String {
        let inputURL = inputDirectory.appendingPathComponent(".prompt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: inputURL) }
        try Data(prompt.utf8).write(to: inputURL, options: .withoutOverwriting)
        let input = try FileHandle(forReadingFrom: inputURL)
        defer { try? input.close() }
        // The child inherits this open descriptor. Unlink the temporary pathname before launching.
        try FileManager.default.removeItem(at: inputURL)

        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.currentDirectoryURL = worktree
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.arguments = [
            "--print", "--output-format", "json", "--safe-mode", "--restricted",
            "--permission-mode", "acceptEdits", "--permission-prompts", "none",
            "--tools", "Read,Glob,Grep,Edit,Write", "--disallowedTools", "mcp__*",
            "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}",
            "--append-system-prompt",
            "Reply with a brief result or ask one specific follow-up question. This reply goes to the owner's phone. Keep it under 2,000 characters. Never include secrets, raw tool output or large diffs. Report any checks you could not run.",
            resume ? "--resume" : "--session-id", sessionID.uuidString.lowercased(),
        ]
        let allowed = Set(["HOME", "USER", "LOGNAME", "TMPDIR", "PATH", "LANG", "LC_ALL"])
        process.environment = ProcessInfo.processInfo.environment.filter { allowed.contains($0.key) }
        try process.run()
        try? output.fileHandleForWriting.close()
        let timeout = DispatchWorkItem {
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + workerTimeout, execute: timeout)
        defer {
            timeout.cancel()
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }

        var data = Data()
        while let chunk = try output.fileHandleForReading.read(upToCount: 64 * 1024), !chunk.isEmpty {
            guard data.count + chunk.count <= outputLimit else { throw JobError.workerFailed }
            data.append(chunk)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let reply = try? JSONDecoder().decode(ClaudeResult.self, from: data),
              reply.type == "result", !reply.is_error, reply.session_id == sessionID else {
            throw JobError.workerFailed
        }
        let result = reply.result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { throw JobError.workerFailed }
        return bounded(result, bytes: 8_192)
    }
}
