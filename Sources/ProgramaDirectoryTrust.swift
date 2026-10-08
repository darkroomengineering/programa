import CryptoKit
import Foundation

/// Manages trusted directories for programa.json command execution.
///
/// Trust is the only thing that lets a `programa.json` entry run without asking first. In an
/// untrusted directory every entry is confirmed, whatever the config file itself says; in a
/// trusted one entries run straight away unless the author marked them `confirm: true`. See
/// `ProgramaConfigExecutor.requiresConfirmation` for the full table.
///
/// Global config (~/.config/programa/programa.json) is always trusted.
///
/// Trust is pinned to each config's *executable content* at the moment it was approved, not
/// just to the directory. The trusted root (the git repo root, or the config's directory outside
/// a repo) maps to one SHA-256 digest per config file under it, keyed by the config's resolved
/// path, so two `programa.json` files in one monorepo never overwrite each other's digest. The
/// digest covers the config with JSONC comments/trailing commas stripped and keys canonically
/// sorted, so editing a comment or reformatting the file does not re-prompt, but changing an
/// actual command does. A config under a trusted root with no recorded digest (a root added in
/// Settings or settings.json, a migrated legacy entry, a nested config nobody approved yet)
/// reads as `.changed` and prompts once instead of being adopted silently. See
/// `trustState(configPath:globalConfigPath:)`.
final class ProgramaDirectoryTrust: @unchecked Sendable {
    static let shared = ProgramaDirectoryTrust()
    static let didChangeNotification = Notification.Name("programa.directoryTrustDidChange")

    /// Outcome of comparing a config's current content against what was trusted.
    enum TrustState {
        /// Trusted, and the config's content still matches the digest recorded for it.
        case trusted
        /// The config sits under a trusted root, but its content differs from what was approved
        /// or no approval was ever recorded for this exact file.
        case changed
        /// Never trusted (or the config can no longer be read/digested).
        case untrusted
    }

    /// Trusted root -> (resolved config path -> SHA-256 hex digest of its executable content).
    typealias ConfigDigests = [String: String]

    /// On-disk shape, version 3.
    private struct TrustStoreV3: Codable {
        var version: Int
        var directories: [String: ConfigDigests]
    }

    /// Version 2: one optional digest per root. Read only for migration.
    private struct TrustStoreV2: Codable {
        var version: Int
        var directories: [String: String?]
    }

    private static let currentStoreVersion = 3

    private let storePath: String
    private let stateLock = NSLock()
    private var trustedDirectories: [String: ConfigDigests]

    private convenience init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("programa")

        let fm = FileManager.default
        if !fm.fileExists(atPath: appSupport.path) {
            try? fm.createDirectory(atPath: appSupport.path, withIntermediateDirectories: true)
        }

        self.init(storePath: appSupport.appendingPathComponent("trusted-directories.json").path)
    }

    /// Testing seam: lets tests point the store at a temp file instead of the real per-user
    /// Application Support store. Production code must always go through `.shared`.
    init(storePath: String) {
        self.storePath = storePath
        self.trustedDirectories = Self.load(fromStorePath: storePath)
    }

    /// Check if a programa.json path is trusted and its content has not changed since approval.
    /// Global config is always trusted. For local configs, check the git repo root
    /// (or the programa.json parent directory if not in a git repo).
    func isTrusted(configPath: String, globalConfigPath: String) -> Bool {
        trustState(configPath: configPath, globalConfigPath: globalConfigPath) == .trusted
    }

    /// True when a digest is recorded for this exact config file. A `.changed` config without
    /// one sits under a root trusted before per-file digests existed (or was never approved
    /// itself), so the user has not reviewed this file's content, as opposed to edited it.
    func hasRecordedDigest(configPath: String) -> Bool {
        let trustKey = Self.trustKey(for: configPath)
        let configKey = Self.configKey(for: configPath)
        stateLock.lock()
        defer { stateLock.unlock() }
        return trustedDirectories[trustKey]?[configKey] != nil
    }

    /// Three-state trust query. Fails closed: a root that is absent is `.untrusted`; a root that
    /// is present but holds no digest for this exact config, or a digest that differs, is
    /// `.changed`; an unreadable config is `.untrusted`. Nothing is ever adopted silently.
    func trustState(configPath: String, globalConfigPath: String) -> TrustState {
        if configPath == globalConfigPath { return .trusted }

        let trustKey = Self.trustKey(for: configPath)
        guard let currentDigest = Self.executableDigest(forConfigAt: configPath) else {
            return .untrusted
        }
        let configKey = Self.configKey(for: configPath)

        stateLock.lock()
        defer { stateLock.unlock() }
        guard let digests = trustedDirectories[trustKey] else {
            return .untrusted
        }
        return digests[configKey] == currentDigest ? .trusted : .changed
    }

    /// Trust the directory containing a programa.json. If the programa.json is inside a git
    /// repo, trusts the repo root. Records this config's current executable-content digest so a
    /// later edit to the file is detected; digests recorded for other configs under the same
    /// root are kept.
    func trust(configPath: String) {
        // An unreadable config has no digest and must not create or widen a trusted entry.
        guard let digest = Self.executableDigest(forConfigAt: configPath) else { return }
        let trustKey = Self.trustKey(for: configPath)
        let configKey = Self.configKey(for: configPath)
        stateLock.lock()
        defer {
            stateLock.unlock()
            postDidChangeNotification()
        }
        trustedDirectories[trustKey, default: [:]][configKey] = digest
        saveLocked()
    }

    /// Remove trust for a directory.
    func revokeTrust(configPath: String) {
        let trustKey = Self.trustKey(for: configPath)
        stateLock.lock()
        defer {
            stateLock.unlock()
            postDidChangeNotification()
        }
        trustedDirectories.removeValue(forKey: trustKey)
        saveLocked()
    }

    /// All currently trusted paths.
    var allTrustedPaths: [String] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return Array(trustedDirectories.keys).sorted()
    }

    /// Replace the set of trusted roots (used by the Settings textarea, settings.json, and
    /// settings-backup restore). Roots that stay keep every digest recorded for them; roots that
    /// arrive new carry no digests, so each config under them prompts once (`.changed`) before
    /// it can run unprompted. Does nothing, and posts nothing, when the set is unchanged.
    func replaceAll(with paths: [String]) {
        stateLock.lock()
        let requested = Set(paths)
        guard requested != Set(trustedDirectories.keys) else {
            stateLock.unlock()
            return
        }
        var replacement: [String: ConfigDigests] = [:]
        for path in requested {
            replacement[path] = trustedDirectories[path] ?? [:]
        }
        trustedDirectories = replacement
        saveLocked()
        stateLock.unlock()
        postDidChangeNotification()
    }

    /// Clear all trusted directories.
    func clearAll() {
        stateLock.lock()
        trustedDirectories.removeAll()
        saveLocked()
        stateLock.unlock()
        postDidChangeNotification()
    }

    // MARK: - Digesting

    /// SHA-256 of the config's executable content: JSONC comments and trailing commas
    /// stripped, then re-serialized canonically with sorted keys, so comment edits and
    /// reformatting do not invalidate trust but a changed command does.
    static func executableDigest(forConfigAt path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path), !data.isEmpty else { return nil }
        guard let sanitized = try? JSONCParser.preprocess(data: data) else { return nil }
        // A config with a repeated key never gets a digest, so it can never be trusted: the
        // digest and the command decoder could disagree about which value is real.
        guard !JSONCParser.containsDuplicateObjectKeys(sanitized) else { return nil }
        let canonical: Data
        if let object = try? JSONSerialization.jsonObject(with: sanitized),
           let encoded = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
            canonical = encoded
        } else {
            canonical = sanitized
        }
        return Data(SHA256.hash(data: canonical)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Private

    /// Resolve the trust key for a programa.json path: git repo root if inside a repo,
    /// otherwise the programa.json's parent directory.
    static func trustKey(for configPath: String) -> String {
        let configDir = (configPath as NSString).deletingLastPathComponent
        if let gitRoot = findGitRoot(from: configDir) {
            return gitRoot
        }
        return configDir
    }

    /// Resolved path of a config file, used as the per-config digest key. Symlinks and `/var`
    /// vs `/private/var` style aliases collapse to one key, so trusting and querying the same
    /// file through different spellings never disagree. Falls back to the standardized path when
    /// the file does not exist.
    static func configKey(for configPath: String) -> String {
        if let resolved = realpath(configPath, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        return (configPath as NSString).standardizingPath
    }

    /// Walk up from `directory` looking for a `.git` directory or file.
    private static func findGitRoot(from directory: String) -> String? {
        let fm = FileManager.default
        var current = directory
        while true {
            let gitPath = (current as NSString).appendingPathComponent(".git")
            if fm.fileExists(atPath: gitPath) {
                return current
            }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current { break }
            current = parent
        }
        return nil
    }

    /// Decode the on-disk store. Reads the current version-3 shape first, then migrates the
    /// version-2 shape (one digest per root) and the flat `[String]` array of the pre-digest
    /// store. Never crashes and never wipes the file on a decode error -- an empty result just
    /// means "nothing trusted yet".
    ///
    /// A version-2 digest was recorded for whichever config was trusted under that root, which
    /// in practice is the root's own `programa.json` (or legacy `cmux.json`), so it migrates to
    /// that file's key. If the guess is wrong the affected config prompts once as `.changed`.
    /// Entries with no digest migrate to an empty map and prompt once too.
    private static func load(fromStorePath path: String) -> [String: ConfigDigests] {
        guard let data = FileManager.default.contents(atPath: path), !data.isEmpty else { return [:] }

        if let current = try? JSONDecoder().decode(TrustStoreV3.self, from: data),
           current.version == currentStoreVersion {
            return current.directories
        }

        if let versioned = try? JSONDecoder().decode(TrustStoreV2.self, from: data) {
            var map: [String: ConfigDigests] = [:]
            for (root, digest) in versioned.directories {
                if let digest {
                    map[root] = [configKey(for: migratedConfigPath(forRoot: root)): digest]
                } else {
                    map[root] = [:]
                }
            }
            return map
        }

        if let paths = try? JSONDecoder().decode([String].self, from: data) {
            var map: [String: ConfigDigests] = [:]
            for path in paths {
                map[path] = [:]
            }
            return map
        }

        return [:]
    }

    private static func migratedConfigPath(forRoot root: String) -> String {
        let programaPath = (root as NSString).appendingPathComponent("programa.json")
        let legacyPath = (root as NSString).appendingPathComponent("cmux.json")
        let fm = FileManager.default
        if !fm.fileExists(atPath: programaPath), fm.fileExists(atPath: legacyPath) {
            return legacyPath
        }
        return programaPath
    }

    /// Caller holds `stateLock`; notification is deliberately posted after unlocking so a
    /// synchronous observer can safely query or replace trust without deadlocking this store.
    private func saveLocked() {
        let store = TrustStoreV3(version: Self.currentStoreVersion, directories: trustedDirectories)
        guard let data = try? JSONEncoder().encode(store) else { return }
        FileManager.default.createFile(atPath: storePath, contents: data)
    }

    private func postDidChangeNotification() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }
}
