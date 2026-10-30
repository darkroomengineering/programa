import Foundation

/// The last agent session each terminal panel ran, kept after the agent exits and its
/// presence is cleared, so the panel can resume it ("Resume Agent Session") and the session
/// snapshot can carry it across a restart. Panel ids are unique app-wide, so one map serves
/// every workspace and window, including panels moved between them.
@MainActor
final class AgentResumeStore {
    static let shared = AgentResumeStore()

    private var targets: [UUID: AgentResumeTarget] = [:]

    func target(panelId: UUID) -> AgentResumeTarget? {
        targets[panelId]
    }

    /// Records the session a hook reported for the panel. A repeat report of the same session
    /// keeps the directory first seen: the agent's own working directory never reaches the
    /// panel while it runs, and its provider resolves a session id from where it started. A
    /// transcript path is kept from whichever report first carries one.
    func note(panelId: UUID, provider: String, sessionId: String, cwd: String?, transcriptPath: String? = nil) {
        if let existing = targets[panelId], existing.provider == provider, existing.sessionId == sessionId {
            if existing.transcriptPath == nil, let transcriptPath {
                targets[panelId]?.transcriptPath = transcriptPath
            }
            return
        }
        targets[panelId] = AgentResumeTarget(
            provider: provider, sessionId: sessionId, cwd: cwd, transcriptPath: transcriptPath
        )
    }

    func restore(_ target: AgentResumeTarget, panelId: UUID) {
        targets[panelId] = target
    }

    func forget(panelId: UUID) {
        targets.removeValue(forKey: panelId)
    }
}
