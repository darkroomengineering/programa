import Foundation

/// One seam between the app and the concerns a future out-of-process core
/// would own. See `docs/plans/core-seam.md` for the motivation
/// (`docs/plans/rust-core-spike.md`'s "Reframe"/step 2, and
/// `docs/removed/ssh-remote-workspaces.md`'s postmortem) and the full list
/// of core-owned concerns, including the ones not yet wrapped here.
///
/// Rule: this file never imports `SwiftUI` or `AppKit`, and no protocol
/// below takes a view type or a raw `ghostty_surface_t`. Every signature is
/// a value type or an existing `Codable` model, so a future out-of-process
/// implementation (the same method, backed by a socket RPC instead of a
/// direct call) can conform without changing the shape callers already use.
///
/// `InProcessCore` is the only conformance today: every method forwards
/// straight to the exact same code that ran before this file existed.
/// Nothing moves out of process, no new thread or queue is introduced, and
/// no public socket command changes shape.
///
/// Grown incrementally, one concern per commit, per
/// `docs/plans/core-seam.md`'s "Commits" section.
enum ProgramaCore {
    /// Git branch/PR metadata probing for a workspace's current directory.
    /// Wraps `GitMetadataProber` (`Sources/GitMetadataProber.swift`).
    protocol GitMetadataProbing {
        /// Runs the same bounded `git`/`gh` subprocess probe
        /// `TabManager.scheduleWorkspaceGitMetadataRefresh` already calls off
        /// the main actor. Callers must not call this from a keystroke-hot
        /// path -- it shells out.
        func probeInitialWorkspaceGitMetadata(
            directory: String
        ) -> GitMetadataProber.InitialWorkspaceGitMetadataSnapshot
    }

    /// Batched `ps`/`lsof` port scanning for terminal panels and agent
    /// process trees. Wraps `PortScanner` (`Sources/PortScanner.swift`).
    protocol PortScanning {
        func registerTTY(workspaceId: UUID, panelId: UUID, ttyName: String)
        func unregisterPanel(workspaceId: UUID, panelId: UUID)
        func kick(workspaceId: UUID, panelId: UUID)
        @MainActor func refreshAgentPorts(workspaceId: UUID, agentPIDs: Set<Int>)
    }

    /// Whole-app session snapshot persistence (layout, cwd, scrollback-as-
    /// text). Wraps `SessionPersistenceStore`
    /// (`Sources/SessionPersistence.swift`). Deliberately does NOT wrap
    /// `SessionWALStore`/`SessionEscrow` -- see `docs/plans/core-seam.md`
    /// "Session snapshot / autosave / WAL / escrow" for why those already
    /// look like a core RPC boundary and would only be renamed by wrapping
    /// them here.
    protocol SessionSnapshotting {
        func loadWithHistoryFallback() -> AppSessionSnapshot?
        @discardableResult func save(_ snapshot: AppSessionSnapshot) -> Bool
    }
}

/// Groups every core-owned concern this app currently exposes through the
/// seam. `InProcessCore.shared` is the only production conformance; a test
/// can substitute a fake conforming to the same protocols to record calls
/// without touching real subprocesses/sockets.
protocol ProgramaCoreProviding {
    var git: ProgramaCore.GitMetadataProbing { get }
    var ports: ProgramaCore.PortScanning { get }
    var sessionSnapshots: ProgramaCore.SessionSnapshotting { get }
}

/// Wraps today's in-process implementations with zero behavior change.
/// Every method here is a one-line forward to the pre-existing
/// static/singleton call.
final class InProcessCore: ProgramaCoreProviding {
    static let shared = InProcessCore()

    let git: ProgramaCore.GitMetadataProbing
    let ports: ProgramaCore.PortScanning

    let sessionSnapshots: ProgramaCore.SessionSnapshotting

    init(
        git: ProgramaCore.GitMetadataProbing = InProcessGitMetadataProbe(),
        ports: ProgramaCore.PortScanning = InProcessPortScanner(),
        sessionSnapshots: ProgramaCore.SessionSnapshotting = InProcessSessionSnapshotting()
    ) {
        self.git = git
        self.ports = ports
        self.sessionSnapshots = sessionSnapshots
    }
}

struct InProcessGitMetadataProbe: ProgramaCore.GitMetadataProbing {
    func probeInitialWorkspaceGitMetadata(
        directory: String
    ) -> GitMetadataProber.InitialWorkspaceGitMetadataSnapshot {
        GitMetadataProber.initialWorkspaceGitMetadataSnapshot(for: directory)
    }
}

struct InProcessPortScanner: ProgramaCore.PortScanning {
    func registerTTY(workspaceId: UUID, panelId: UUID, ttyName: String) {
        PortScanner.shared.registerTTY(workspaceId: workspaceId, panelId: panelId, ttyName: ttyName)
    }

    func unregisterPanel(workspaceId: UUID, panelId: UUID) {
        PortScanner.shared.unregisterPanel(workspaceId: workspaceId, panelId: panelId)
    }

    func kick(workspaceId: UUID, panelId: UUID) {
        PortScanner.shared.kick(workspaceId: workspaceId, panelId: panelId)
    }

    @MainActor
    func refreshAgentPorts(workspaceId: UUID, agentPIDs: Set<Int>) {
        PortScanner.shared.refreshAgentPorts(workspaceId: workspaceId, agentPIDs: agentPIDs)
    }
}

struct InProcessSessionSnapshotting: ProgramaCore.SessionSnapshotting {
    func loadWithHistoryFallback() -> AppSessionSnapshot? {
        SessionPersistenceStore.loadWithHistoryFallback()
    }

    @discardableResult
    func save(_ snapshot: AppSessionSnapshot) -> Bool {
        SessionPersistenceStore.save(snapshot)
    }
}
