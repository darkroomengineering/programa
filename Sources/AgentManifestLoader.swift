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

    private let lock = NSLock()
    private var manifestsByAgent: [String: AgentManifest] = [:]
    private var manifestsByProcessName: [String: AgentManifest] = [:]
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
#if DEBUG
                dlog("agentManifest.override.loaded agent=\(manifest.agent) path=\(url.path)")
#endif
            }
        }

        manifestsByAgent = byAgent
        var byProcessName: [String: AgentManifest] = [:]
        for manifest in byAgent.values {
            for processName in manifest.recognize.processNames {
                byProcessName[processName] = manifest
            }
        }
        manifestsByProcessName = byProcessName
    }

    /// Looks up a manifest by its stable agent id (e.g. "claude-code").
    func manifest(forAgent agent: String) -> AgentManifest? {
        loadIfNeeded()
        lock.lock()
        defer { lock.unlock() }
        return manifestsByAgent[agent]
    }

    /// Looks up a manifest by a recognized foreground-command process name (e.g. "claude"). Used
    /// by the Phase A recognition path if/when a foreground-command signal becomes available on
    /// the wire (see AgentScreenDetectionEngine.swift's header for why v1 uses a screen-pattern
    /// fallback instead).
    func manifest(forProcessName processName: String) -> AgentManifest? {
        loadIfNeeded()
        lock.lock()
        defer { lock.unlock() }
        return manifestsByProcessName[processName]
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

#if DEBUG
    /// Test-only: forces a reload on next access. `programaTests/AgentManifestTests.swift` uses
    /// this to exercise loader behavior without cross-test caching.
    func resetForTesting() {
        lock.lock()
        isLoaded = false
        manifestsByAgent = [:]
        manifestsByProcessName = [:]
        lock.unlock()
    }
#endif
}
