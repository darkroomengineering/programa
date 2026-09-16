// Screen-manifest agent detection (docs/plans/screen-manifest-detection.md): loads and caches
// AgentManifest instances from bundled Resources/AgentDetection/*.json, overlaid by user
// overrides at ~/.config/programa/agent-detection/<agent>.json.
//
// Precedence: a user override *fully replaces* the bundled manifest for that agent id (no
// field-level merge — simpler mental model, matches "user override" semantics used elsewhere in
// the config system, e.g. Claude/Codex hook settings writes in CLI+Hooks.swift).
import Bonsplit
import Foundation

/// Loads (once, lazily) and caches every bundled + user-override agent manifest. Thread-safe —
/// `AgentScreenDetectionEngine` calls `manifest(forAgent:)`/`allManifests()` from its background
/// sampling thread.
final class AgentManifestLoader: @unchecked Sendable {
    static let shared = AgentManifestLoader()

    /// Bundled manifest ids shipped with the app (Resources/AgentDetection/<id>.json). Kept as an
    /// explicit list rather than directory-listing the bundle at runtime, so a missing/renamed
    /// manifest fails loudly in `AgentManifestTests` (programaTests) instead of silently
    /// vanishing from the candidate set.
    static let bundledAgentIds = [
        "claude-code",
        "codex",
        "gemini-cli",
        "opencode",
        "copilot-cli",
        "cursor-agent",
        "aider",
    ]

    /// Where a loaded manifest came from -- exposed so callers (e.g. the `agent-detection list`
    /// CLI command via `agent.detection.list`) can report bundled-vs-override without
    /// reimplementing this loader's file discovery.
    enum ManifestSource: String, Sendable {
        case bundled
        case override
    }

    /// A loaded manifest paired with where it came from. See `ManifestSource`.
    struct ManifestEntry: Sendable {
        let manifest: AgentManifest
        let source: ManifestSource
    }

    private let lock = NSLock()
    private var manifestsByAgent: [String: AgentManifest] = [:]
    private var sourceByAgent: [String: ManifestSource] = [:]
    private var isLoaded = false

    private init() {}

    private static var userOverrideDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/programa/agent-detection", isDirectory: true)
    }

    private func loadIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard !isLoaded else { return }
        isLoaded = true

        var byAgent: [String: AgentManifest] = [:]
        var bySource: [String: ManifestSource] = [:]
        let decoder = JSONDecoder()

        for agentId in Self.bundledAgentIds {
            guard let url = Bundle.main.url(forResource: agentId, withExtension: "json", subdirectory: "AgentDetection"),
                  let data = try? Data(contentsOf: url),
                  let manifest = try? decoder.decode(AgentManifest.self, from: data) else {
#if DEBUG
                dlog("agentManifest.bundled.missing agent=\(agentId)")
#endif
                continue
            }
            byAgent[manifest.agent] = manifest
            bySource[manifest.agent] = .bundled
        }

        let overrideDirectory = Self.userOverrideDirectory
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: overrideDirectory,
            includingPropertiesForKeys: nil
        ) {
            for url in entries where url.pathExtension.lowercased() == "json" {
                guard let data = try? Data(contentsOf: url),
                      let manifest = try? decoder.decode(AgentManifest.self, from: data) else {
#if DEBUG
                    dlog("agentManifest.override.invalid path=\(url.path)")
#endif
                    continue
                }
                byAgent[manifest.agent] = manifest
                bySource[manifest.agent] = .override
#if DEBUG
                dlog("agentManifest.override.loaded agent=\(manifest.agent) path=\(url.path)")
#endif
            }
        }

        manifestsByAgent = byAgent
        sourceByAgent = bySource
    }

    /// Looks up a manifest by its stable agent id (e.g. "claude-code").
    func manifest(forAgent agent: String) -> AgentManifest? {
        loadIfNeeded()
        lock.lock()
        defer { lock.unlock() }
        return manifestsByAgent[agent]
    }

    /// All loaded manifests (bundled + user overrides), used by `AgentScreenDetectionEngine`'s
    /// Phase A screen-pattern recognition scan, which checks every manifest's
    /// `recognize.screen_patterns` against not-yet-candidate surfaces.
    func allManifests() -> [AgentManifest] {
        loadIfNeeded()
        lock.lock()
        defer { lock.unlock() }
        return Array(manifestsByAgent.values)
    }

    /// All loaded manifests paired with their source (bundled vs. user override), for
    /// `agent.detection.list` -- lets that socket method report provenance without duplicating
    /// this loader's file discovery.
    func allManifestEntries() -> [ManifestEntry] {
        loadIfNeeded()
        lock.lock()
        defer { lock.unlock() }
        return manifestsByAgent.map { agentId, manifest in
            ManifestEntry(manifest: manifest, source: sourceByAgent[agentId] ?? .bundled)
        }
    }

    /// Drops the cache so the next access re-reads bundled manifests and the user override
    /// directory from disk.
    ///
    /// Manifests are otherwise loaded exactly once per app launch, which is right for the
    /// detection engine's hot sampling path but wrong for authoring: `programa agent-detection
    /// scaffold` writes a new override file, and without this the running app would not see it
    /// until relaunch -- so `agent-detection test`, whose whole job is to check the patterns you
    /// just edited, would report "no manifest loaded" for a file sitting right there on disk.
    ///
    /// Called only from the user-initiated `agent.detection.*` socket handlers, never from the
    /// sampling loop.
    func reloadFromDisk() {
        lock.lock()
        isLoaded = false
        manifestsByAgent = [:]
        sourceByAgent = [:]
        lock.unlock()
        loadIfNeeded()
    }

#if DEBUG
    /// Test-only: forces a reload on next access. `programaTests/AgentManifestTests.swift` uses
    /// this to exercise loader behavior without cross-test caching.
    func resetForTesting() {
        lock.lock()
        isLoaded = false
        manifestsByAgent = [:]
        sourceByAgent = [:]
        lock.unlock()
    }
#endif
}
