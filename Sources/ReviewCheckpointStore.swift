import Foundation
import Bonsplit

/// One saved working-tree snapshot under `refs/programa/checkpoints/<workspace>/<surface>/<seq>`.
struct ReviewCheckpoint: Equatable, Sendable {
    enum Kind: String, Sendable {
        /// Saved when an agent turn started in the surface.
        case turnStart = "turn start"
        /// Saved by `restore` just before it rewrote the files, so the revert can be undone.
        case beforeRevert = "before revert"
    }

    let ref: String
    let commit: String
    let tree: String
    let kind: Kind
}

enum ReviewCheckpointError: Error, Equatable, Sendable {
    case notGitRepository
    case checkpointNotFound
    /// The current files could not be saved first (too many changes or a file too large).
    case tooLargeToSave
    case commandFailed(String)
}

/// Stateless per-turn file checkpoints. A checkpoint is a commit whose tree is the working tree
/// (tracked plus untracked, `.gitignore` respected), built in a temporary index file so the
/// repository's real index, `HEAD` and branches are never touched. Submodule contents are not
/// captured and never restored. Every call runs git synchronously: callers dispatch onto `queue`.
enum ReviewCheckpointStore {
    /// Serializes checkpoint git work so two saves never race for the same sequence number.
    static let queue = DispatchQueue(label: "com.darkroom.programa.review-checkpoints", qos: .utility)

    static let refRoot = "refs/programa/checkpoints"
    static let keepCount = 20
    /// More changed paths than this (tracked changes plus untracked files) skips the checkpoint.
    static let maxChangedPaths = ReviewDiffProber.fingerprintHashPathLimit
    /// Any untracked file larger than this skips the checkpoint.
    static let maxUntrackedFileBytes: Int64 = 10 * 1024 * 1024
    /// Checkpoints of other workspaces older than this are deleted on save: workspace ids do not
    /// survive an app restart, so nothing else would ever delete them.
    static let staleAge: TimeInterval = 7 * 24 * 60 * 60

    private static let quickTimeout: TimeInterval = 10
    private static let treeTimeout: TimeInterval = 60
    private static let stdoutLimit = 32 * 1024 * 1024
    private static let stderrLimit = 1024 * 1024
    private static let gitOptions = ["-c", "core.hooksPath=/dev/null", "-c", "core.quotePath=false"]
    /// A repository with no git identity configured can still record checkpoints.
    private static let identityEnvironment = [
        "GIT_AUTHOR_NAME": "Programa",
        "GIT_AUTHOR_EMAIL": "checkpoints@programa.invalid",
        "GIT_COMMITTER_NAME": "Programa",
        "GIT_COMMITTER_EMAIL": "checkpoints@programa.invalid",
    ]
    private static let subjectPrefix = "programa checkpoint: "
    private static let gitlinkMode = "160000"

    static func refPrefix(workspaceId: UUID, surfaceId: UUID) -> String {
        "\(refRoot)/\(workspaceId.uuidString)/\(surfaceId.uuidString)/"
    }

    // MARK: - Public API

    /// Saves the working tree as a checkpoint and prunes the surface down to `keepCount`. Returns
    /// the ref holding the current state (the newest existing one when the tree is unchanged), or
    /// `nil` when the directory is not a git repo, the change set is over the limits, or git failed.
    @discardableResult
    static func save(
        directory: String,
        workspaceId: UUID,
        surfaceId: UUID,
        kind: ReviewCheckpoint.Kind = .turnStart
    ) -> String? {
        guard let repoRoot = ReviewDiffProber.repositoryRoot(directory: directory) else { return nil }
        switch save(repoRoot: repoRoot, workspaceId: workspaceId, surfaceId: surfaceId, kind: kind) {
        case .success(let checkpoint):
            return checkpoint.ref
        case .failure(let error):
#if DEBUG
            dlog("review.checkpoint.save skipped surface=\(surfaceId.uuidString.prefix(5)) reason=\(error)")
#endif
            return nil
        }
    }

    /// The surface's checkpoints in `directory`'s repo, newest first.
    static func list(directory: String, workspaceId: UUID, surfaceId: UUID) -> [ReviewCheckpoint] {
        guard let repoRoot = ReviewDiffProber.repositoryRoot(directory: directory) else { return [] }
        return list(repoRoot: repoRoot, prefix: refPrefix(workspaceId: workspaceId, surfaceId: surfaceId)) ?? []
    }

    static func prune(directory: String, workspaceId: UUID, surfaceId: UUID, keep: Int = keepCount) {
        guard let repoRoot = ReviewDiffProber.repositoryRoot(directory: directory) else { return }
        prune(repoRoot: repoRoot, workspaceId: workspaceId, surfaceId: surfaceId, keep: keep)
    }

    /// Makes the files in the repo match checkpoint `ref`. The current files are saved first as a
    /// `.beforeRevert` checkpoint; if that save fails nothing is changed. Writes only working-tree
    /// files: the real index, `HEAD`, ignored files and submodules stay as they are.
    static func restore(
        ref: String,
        directory: String,
        workspaceId: UUID,
        surfaceId: UUID
    ) -> Result<Void, ReviewCheckpointError> {
        guard let repoRoot = ReviewDiffProber.repositoryRoot(directory: directory) else {
            return .failure(.notGitRepository)
        }
        guard let targetTree = output(repoRoot: repoRoot, ["rev-parse", "--verify", "--quiet", "\(ref)^{tree}"])?
            .trimmingCharacters(in: .whitespacesAndNewlines), !targetTree.isEmpty else {
            return .failure(.checkpointNotFound)
        }
        // Restoring a pre-revert save is an undo; the state it replaces is the turn's start again,
        // so the panel offers a revert next rather than another undo.
        let targetKind = list(repoRoot: repoRoot, prefix: refPrefix(workspaceId: workspaceId, surfaceId: surfaceId))?
            .first(where: { $0.ref == ref })?.kind
        let saveKind: ReviewCheckpoint.Kind = targetKind == .beforeRevert ? .turnStart : .beforeRevert
        let current: ReviewCheckpoint
        switch save(repoRoot: repoRoot, workspaceId: workspaceId, surfaceId: surfaceId, kind: saveKind) {
        case .success(let checkpoint):
            current = checkpoint
        case .failure(let error):
            return .failure(error)
        }
        guard current.tree != targetTree else { return .success(()) }

        let changes: [TreeChange]
        switch treeChanges(repoRoot: repoRoot, from: current.tree, to: targetTree) {
        case .success(let parsed):
            changes = parsed
        case .failure(let error):
            return .failure(error)
        }

        // Deletes first, so a path that turns from a directory back into a file is free. A failed
        // delete still lets the writes land, then fails the restore: the pre-revert checkpoint
        // above can undo the partial result.
        let undeleted = changes.filter(\.deletesPath).map(\.path).filter { !removeFile(repoRoot: repoRoot, path: $0) }
        let writes = changes.filter { !$0.deletesPath }.map(\.path)
        if !writes.isEmpty, case .failure(let error) = checkout(repoRoot: repoRoot, tree: targetTree, paths: writes) {
            return .failure(error)
        }
        if !undeleted.isEmpty {
            return .failure(.commandFailed("could not remove \(undeleted.joined(separator: ", "))"))
        }
#if DEBUG
        dlog("review.checkpoint.restore surface=\(surfaceId.uuidString.prefix(5)) ref=\(ref) changes=\(changes.count)")
#endif
        return .success(())
    }

    /// Deletes every checkpoint the workspace recorded in `directory`'s repo.
    static func deleteAll(workspaceId: UUID, directory: String) {
        guard let repoRoot = ReviewDiffProber.repositoryRoot(directory: directory) else { return }
        let prefix = "\(refRoot)/\(workspaceId.uuidString)/"
        guard let refs = output(repoRoot: repoRoot, ["for-each-ref", "--format=%(refname)", prefix]) else { return }
        for ref in refs.split(separator: "\n") where !ref.isEmpty {
            _ = run(repoRoot: repoRoot, ["update-ref", "-d", String(ref)])
        }
    }

    // MARK: - Save

    private static func save(
        repoRoot: String,
        workspaceId: UUID,
        surfaceId: UUID,
        kind: ReviewCheckpoint.Kind
    ) -> Result<ReviewCheckpoint, ReviewCheckpointError> {
        let prefix = refPrefix(workspaceId: workspaceId, surfaceId: surfaceId)
        guard let existing = list(repoRoot: repoRoot, prefix: prefix) else {
            return .failure(.commandFailed("for-each-ref \(prefix)"))
        }
        let head = output(repoRoot: repoRoot, ["rev-parse", "--verify", "--quiet", "HEAD^{commit}"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let headCommit = (head?.isEmpty ?? true) ? nil : head

        let tree: String
        switch snapshotTree(repoRoot: repoRoot, hasHead: headCommit != nil) {
        case .success(let snapshot):
            tree = snapshot
        case .failure(let error):
            return .failure(error)
        }
        if let newest = existing.first, newest.tree == tree {
            return .success(newest)
        }

        var commitArguments = ["commit-tree", tree, "-m", subjectPrefix + kind.rawValue]
        if let headCommit {
            commitArguments += ["-p", headCommit]
        }
        let commitResult = run(repoRoot: repoRoot, commitArguments, environment: identityEnvironment)
        guard let commit = succeededOutput(commitResult)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !commit.isEmpty else {
            return .failure(.commandFailed(failureDetail("commit-tree", commitResult)))
        }

        let nextSequence = (existing.first.flatMap { sequence(of: $0.ref) } ?? 0) + 1
        let ref = prefix + String(format: "%06d", nextSequence)
        // The empty old value makes update-ref refuse to overwrite an existing ref.
        let updateResult = run(repoRoot: repoRoot, ["update-ref", ref, commit, ""])
        guard succeededOutput(updateResult) != nil else {
            return .failure(.commandFailed(failureDetail("update-ref", updateResult)))
        }
        prune(repoRoot: repoRoot, workspaceId: workspaceId, surfaceId: surfaceId, keep: keepCount)
        pruneStale(repoRoot: repoRoot, keepingWorkspace: workspaceId)
#if DEBUG
        dlog("review.checkpoint.save surface=\(surfaceId.uuidString.prefix(5)) ref=\(ref) kind=\(kind.rawValue)")
#endif
        return .success(ReviewCheckpoint(ref: ref, commit: commit, tree: tree, kind: kind))
    }

    /// Writes the working tree to a tree object through a temporary index. The temporary index
    /// starts as a copy of the real one (whose stat cache saves rehashing every tracked file),
    /// or `HEAD`'s tree if the copy fails; the real index file is only ever read.
    private static func snapshotTree(repoRoot: String, hasHead: Bool) -> Result<String, ReviewCheckpointError> {
        if let error = limitViolation(repoRoot: repoRoot) {
            return .failure(error)
        }
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("programa-checkpoint-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        } catch {
            return .failure(.commandFailed("temporary index directory: \(error.localizedDescription)"))
        }
        defer { try? FileManager.default.removeItem(at: scratch) }
        let indexPath = scratch.appendingPathComponent("index").path
        let environment = ["GIT_INDEX_FILE": indexPath]

        var seeded = false
        if let realIndex = realIndexPath(repoRoot: repoRoot), FileManager.default.fileExists(atPath: realIndex) {
            seeded = (try? FileManager.default.copyItem(atPath: realIndex, toPath: indexPath)) != nil
        }
        if !seeded, hasHead {
            let readTree = run(repoRoot: repoRoot, ["read-tree", "HEAD"], environment: environment)
            guard succeededOutput(readTree) != nil else {
                return .failure(.commandFailed(failureDetail("read-tree", readTree)))
            }
        }
        let add = run(repoRoot: repoRoot, ["add", "-A"], environment: environment, timeout: treeTimeout)
        guard succeededOutput(add) != nil else {
            return .failure(.commandFailed(failureDetail("add -A", add)))
        }
        let writeTree = run(repoRoot: repoRoot, ["write-tree"], environment: environment)
        guard let tree = succeededOutput(writeTree)?.trimmingCharacters(in: .whitespacesAndNewlines), !tree.isEmpty else {
            return .failure(.commandFailed(failureDetail("write-tree", writeTree)))
        }
        return .success(tree)
    }

    private static func limitViolation(repoRoot: String) -> ReviewCheckpointError? {
        guard let changed = ReviewDiffProber.uncommittedChangedPaths(directory: repoRoot),
              let untracked = output(repoRoot: repoRoot, ["ls-files", "-z", "--others", "--exclude-standard"]) else {
            return .commandFailed("listing changed files")
        }
        guard changed.count <= maxChangedPaths else { return .tooLargeToSave }
        for path in untracked.split(separator: "\0") where !path.isEmpty {
            let fullPath = (repoRoot as NSString).appendingPathComponent(String(path))
            let size = (try? FileManager.default.attributesOfItem(atPath: fullPath)[.size] as? NSNumber)?.int64Value ?? 0
            if size > maxUntrackedFileBytes { return .tooLargeToSave }
        }
        return nil
    }

    /// The real index path; `.git` is a file in a linked worktree, so ask git.
    private static func realIndexPath(repoRoot: String) -> String? {
        guard let path = output(repoRoot: repoRoot, ["rev-parse", "--git-path", "index"])?
            .trimmingCharacters(in: .newlines), !path.isEmpty else { return nil }
        return path.hasPrefix("/") ? path : (repoRoot as NSString).appendingPathComponent(path)
    }

    // MARK: - Listing and pruning

    private static func list(repoRoot: String, prefix: String) -> [ReviewCheckpoint]? {
        guard let records = output(repoRoot: repoRoot, [
            "for-each-ref", "--sort=-refname",
            "--format=%(refname)%00%(objectname)%00%(tree)%00%(contents:subject)",
            prefix,
        ]) else { return nil }
        return records.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 4, sequence(of: fields[0]) != nil else { return nil }
            let kind = fields[3].hasPrefix(subjectPrefix)
                ? ReviewCheckpoint.Kind(rawValue: String(fields[3].dropFirst(subjectPrefix.count))) ?? .turnStart
                : .turnStart
            return ReviewCheckpoint(ref: fields[0], commit: fields[1], tree: fields[2], kind: kind)
        }
    }

    private static func prune(repoRoot: String, workspaceId: UUID, surfaceId: UUID, keep: Int) {
        guard let checkpoints = list(repoRoot: repoRoot, prefix: refPrefix(workspaceId: workspaceId, surfaceId: surfaceId)),
              checkpoints.count > keep else { return }
        for checkpoint in checkpoints.dropFirst(max(keep, 0)) {
            _ = run(repoRoot: repoRoot, ["update-ref", "-d", checkpoint.ref])
        }
    }

    private static func pruneStale(repoRoot: String, keepingWorkspace workspaceId: UUID) {
        guard let records = output(repoRoot: repoRoot, [
            "for-each-ref", "--format=%(refname)%00%(committerdate:unix)", "\(refRoot)/",
        ]) else { return }
        let cutoff = Date().addingTimeInterval(-staleAge).timeIntervalSince1970
        let ownPrefix = "\(refRoot)/\(workspaceId.uuidString)/"
        for line in records.split(separator: "\n") {
            let fields = line.split(separator: "\0").map(String.init)
            guard fields.count == 2, !fields[0].hasPrefix(ownPrefix),
                  let timestamp = TimeInterval(fields[1]), timestamp < cutoff else { continue }
            _ = run(repoRoot: repoRoot, ["update-ref", "-d", fields[0]])
        }
    }

    private static func sequence(of ref: String) -> Int? {
        guard let last = ref.split(separator: "/").last, last.count == 6 else { return nil }
        return Int(last)
    }

    // MARK: - Restore

    private struct TreeChange {
        let path: String
        let deletesPath: Bool
    }

    /// `diff-tree` between two checkpoint trees; gitlinks (submodules, embedded repos) dropped.
    private static func treeChanges(repoRoot: String, from: String, to: String) -> Result<[TreeChange], ReviewCheckpointError> {
        let result = run(repoRoot: repoRoot, ["diff-tree", "-r", "-z", "--raw", "--no-renames", "--no-ext-diff", from, to])
        guard let raw = succeededOutput(result) else {
            return .failure(.commandFailed(failureDetail("diff-tree", result)))
        }
        // Records are `:<old mode> <new mode> <old id> <new id> <status>` NUL `<path>` NUL.
        let fields = raw.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var changes: [TreeChange] = []
        var index = 0
        while index + 1 < fields.count {
            let header = fields[index].split(separator: " ")
            let path = fields[index + 1]
            index += 2
            guard header.count == 5, header[0].hasPrefix(":") else { continue }
            let oldMode = String(header[0].dropFirst())
            let newMode = String(header[1])
            if oldMode == gitlinkMode || newMode == gitlinkMode { continue }
            changes.append(TreeChange(path: path, deletesPath: header[4] == "D"))
        }
        return .success(changes)
    }

    /// `git checkout <tree> -- <paths>` against a throwaway index: the files are written with the
    /// repo's checkout rules (modes, symlinks, smudge filters) while the real index stays as is.
    private static func checkout(repoRoot: String, tree: String, paths: [String]) -> Result<Void, ReviewCheckpointError> {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("programa-checkpoint-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            try Data(paths.joined(separator: "\0").utf8).write(to: scratch.appendingPathComponent("paths"))
        } catch {
            return .failure(.commandFailed("checkout pathspec file: \(error.localizedDescription)"))
        }
        defer { try? FileManager.default.removeItem(at: scratch) }
        let result = run(
            repoRoot: repoRoot,
            [
                "--literal-pathspecs", "checkout", tree,
                "--pathspec-from-file=\(scratch.appendingPathComponent("paths").path)", "--pathspec-file-nul",
            ],
            environment: ["GIT_INDEX_FILE": scratch.appendingPathComponent("index").path],
            timeout: treeTimeout
        )
        guard succeededOutput(result) != nil else {
            return .failure(.commandFailed(failureDetail("checkout", result)))
        }
        return .success(())
    }

    /// Removes a file or symlink the checkpoint does not have, then any parent directories it
    /// leaves empty, stopping at the repo root. Directories are never removed recursively.
    /// Returns false when the path is still there afterwards; an already-missing path is success.
    private static func removeFile(repoRoot: String, path: String) -> Bool {
        let fileManager = FileManager.default
        let fullPath = (repoRoot as NSString).appendingPathComponent(path)
        guard let type = (try? fileManager.attributesOfItem(atPath: fullPath))?[.type] as? FileAttributeType else {
            return true
        }
        guard type != .typeDirectory, (try? fileManager.removeItem(atPath: fullPath)) != nil else { return false }
        var parent = (fullPath as NSString).deletingLastPathComponent
        while parent.count > repoRoot.count, parent.hasPrefix(repoRoot + "/"),
              (try? fileManager.contentsOfDirectory(atPath: parent))?.isEmpty == true {
            try? fileManager.removeItem(atPath: parent)
            parent = (parent as NSString).deletingLastPathComponent
        }
        return true
    }

    // MARK: - Process plumbing

    private static func run(
        repoRoot: String,
        _ arguments: [String],
        environment: [String: String] = [:],
        timeout: TimeInterval = quickTimeout
    ) -> CanonicalSubprocessResult {
        CanonicalSubprocessRunner.runAutomaticGit(
            arguments: gitOptions + arguments,
            currentDirectory: repoRoot,
            timeout: timeout,
            stdoutLimit: stdoutLimit,
            stderrLimit: stderrLimit,
            environmentOverrides: environment
        )
    }

    private static func output(repoRoot: String, _ arguments: [String]) -> String? {
        succeededOutput(run(repoRoot: repoRoot, arguments))
    }

    private static func succeededOutput(_ result: CanonicalSubprocessResult) -> String? {
        guard result.exitStatus == 0, result.outcome == .exited else { return nil }
        return result.stdout ?? ""
    }

    private static func failureDetail(_ command: String, _ result: CanonicalSubprocessResult) -> String {
        let stderr = (result.stderr ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return "git \(command): " + (stderr.isEmpty ? "exit status \(String(describing: result.exitStatus)), \(result.outcome)" : stderr)
    }
}
