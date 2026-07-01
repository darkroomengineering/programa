import AppKit
import Bonsplit
import Foundation

/// Maintains a small pool of pre-warmed terminal surfaces so new tabs open instantly.
///
/// Each pooled surface lives in a hidden offscreen `NSWindow` with a running shell process.
/// When `TabManager.addWorkspace()` needs a new terminal, it claims a pooled surface instead
/// of cold-starting one, eliminating the visible blank-screen delay.
@MainActor
final class SurfacePool {
    static let shared = SurfacePool()

    // MARK: - Configuration

    private let maxPoolSize = 1

    // MARK: - State

    enum EntryState {
        case warming
        case ready
    }

    struct PoolEntry {
        let surface: TerminalSurface
        let offscreenWindow: NSWindow
        var state: EntryState
        let createdAt: Date
    }

    /// Keyed by surface.id
    private var entries: [UUID: PoolEntry] = [:]

    /// Whether the pool is enabled. Reads user default, defaulting to true.
    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "cmuxSurfacePoolEnabled") as? Bool ?? true
    }

    #if DEBUG
    private(set) var claimCount = 0
    private(set) var missCount = 0
    #endif

    private init() {}

    // MARK: - Public API

    /// Pre-warm a surface if the pool isn't full.
    func warmIfNeeded() {
        guard isEnabled else { return }
        guard GhosttyApp.shared.app != nil else { return }
        guard entries.count < maxPoolSize else { return }

#if DEBUG
        dlog("pool.warm.start count=\(entries.count) max=\(maxPoolSize)")
#endif

        let entry = createPoolEntry()
        entries[entry.surface.id] = entry

#if DEBUG
        dlog("pool.warm.done surface=\(entry.surface.id.uuidString.prefix(8)) count=\(entries.count)")
#endif
    }

    /// Claim a pre-warmed surface for use in a real workspace.
    ///
    /// Returns `nil` if the pool is empty, not ready, or incompatible with the request.
    /// The caller should fall back to the normal cold-start path.
    func claim(
        workspaceId: UUID,
        portOrdinal: Int,
        workingDirectory: String?,
        configTemplate: ProgramaSurfaceConfigTemplate?
    ) -> ClaimedSurface? {
        guard isEnabled else { return nil }

        // Skip pool for non-default font sizes — the surface would need a resize
        if let template = configTemplate, template.fontSize > 0 {
            // fontSize 0 means "use default", which is what the pool uses.
            // Skip pool if a non-default size was explicitly requested.
#if DEBUG
                dlog("pool.claim.skip reason=fontSizeMismatch requested=\(template.fontSize)")
                missCount += 1
#endif
                return nil
        }

        guard let entry = entries.first(where: { $0.value.state == .ready }) else {
#if DEBUG
            dlog("pool.claim.miss count=\(entries.count) warming=\(entries.values.filter { $0.state == .warming }.count)")
            missCount += 1
#endif
            return nil
        }

        let poolEntry = entry.value
        entries.removeValue(forKey: entry.key)

#if DEBUG
        let warmMs = Date().timeIntervalSince(poolEntry.createdAt) * 1000
        dlog("pool.claim surface=\(poolEntry.surface.id.uuidString.prefix(8)) warmMs=\(String(format: "%.0f", warmMs))")
        claimCount += 1
#endif

        // Detach from offscreen window
        poolEntry.surface.hostedView.removeFromSuperview()
        poolEntry.offscreenWindow.contentView = nil
        poolEntry.offscreenWindow.orderOut(nil)

        // Update workspace identity
        poolEntry.surface.updateWorkspaceId(workspaceId)

        // Patch environment variables and working directory via pty
        patchClaimedSurface(
            poolEntry.surface,
            workspaceId: workspaceId,
            portOrdinal: portOrdinal,
            workingDirectory: workingDirectory
        )

        // Replenish the pool on the next tick
        DispatchQueue.main.async { [weak self] in
            self?.warmIfNeeded()
        }

        return ClaimedSurface(
            surface: poolEntry.surface,
            panel: TerminalPanel(workspaceId: workspaceId, surface: poolEntry.surface)
        )
    }

    /// Tear down all pooled surfaces (app termination, memory pressure, etc.)
    func teardownAll() {
#if DEBUG
        dlog("pool.teardown count=\(entries.count)")
#endif
        for (_, entry) in entries {
            entry.surface.hostedView.removeFromSuperview()
            entry.offscreenWindow.contentView = nil
            entry.offscreenWindow.orderOut(nil)
            entry.offscreenWindow.close()
        }
        entries.removeAll()
    }

    // MARK: - Types

    struct ClaimedSurface {
        let surface: TerminalSurface
        let panel: TerminalPanel
    }

    // MARK: - Private

    private func createPoolEntry() -> PoolEntry {
        // Create surface with placeholder workspace ID — patched on claim
        let placeholderWorkspaceId = UUID()
        let surface = TerminalSurface(
            tabId: placeholderWorkspaceId,
            context: GHOSTTY_SURFACE_CONTEXT_TAB,
            configTemplate: nil
        )

        // Create a hidden offscreen window to host the surface.
        // ghostty_surface_new requires view.window != nil to trigger.
        let offscreenWindow = NSWindow(
            contentRect: NSRect(x: -10000, y: -10000, width: 800, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        offscreenWindow.isReleasedWhenClosed = false
        offscreenWindow.contentView = surface.hostedView

        // Moving the hosted view into the window triggers viewDidMoveToWindow
        // on the GhosttyNSView, which calls attachToView → createSurface.
        // However, the portal system's viewDidMoveToWindow also fires. We need
        // the surface to be created but NOT registered with any portal.
        // The hostedView is a GhosttySurfaceScrollView containing the GhosttyNSView.
        // Setting it as contentView puts it in the window hierarchy, satisfying
        // the view.window != nil guard in attachToView → createSurface.

        // Mark as ready once the surface exists (created synchronously in attachToView).
        // If the surface wasn't created (e.g. Ghostty app not ready), stay in warming.
        let state: EntryState = surface.surface != nil ? .ready : .warming

        if state == .warming {
            // Surface creation was deferred. Try triggering it explicitly.
            surface.requestBackgroundSurfaceStartIfNeeded()

            // Check again after a tick
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard var entry = self.entries[surface.id] else { return }
                if surface.surface != nil && entry.state == .warming {
                    entry.state = .ready
                    self.entries[surface.id] = entry
#if DEBUG
                    let warmMs = Date().timeIntervalSince(entry.createdAt) * 1000
                    dlog("pool.entry.ready surface=\(surface.id.uuidString.prefix(8)) warmMs=\(String(format: "%.0f", warmMs))")
#endif
                }
            }
        }

#if DEBUG
        dlog("pool.entry.create surface=\(surface.id.uuidString.prefix(8)) state=\(state) hasSurface=\(surface.surface != nil)")
#endif

        return PoolEntry(
            surface: surface,
            offscreenWindow: offscreenWindow,
            state: state,
            createdAt: Date()
        )
    }

    /// Inject updated environment variables and cd to the target directory via pty input.
    private func patchClaimedSurface(
        _ surface: TerminalSurface,
        workspaceId: UUID,
        portOrdinal: Int,
        workingDirectory: String?
    ) {
        var commands: [String] = []

        // Update per-surface/workspace env vars
        commands.append("export PROGRAMA_SURFACE_ID=\(surface.id.uuidString)")
        commands.append("export PROGRAMA_PANEL_ID=\(surface.id.uuidString)")
        commands.append("export PROGRAMA_WORKSPACE_ID=\(workspaceId.uuidString)")
        commands.append("export PROGRAMA_TAB_ID=\(workspaceId.uuidString)")

        // Update port range
        let portBase = TerminalSurface.sessionPortBase
        let portRange = TerminalSurface.sessionPortRangeSize
        let startPort = portBase + portOrdinal * portRange
        commands.append("export PROGRAMA_PORT=\(startPort)")
        commands.append("export PROGRAMA_PORT_END=\(startPort + portRange - 1)")

        // cd to target directory if different from home
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        if let dir = workingDirectory, !dir.isEmpty, dir != homeDir {
            commands.append("cd \(shellQuote(dir))")
        }

        // Clear screen + scrollback to hide the pre-warm prompt/zshrc output
        commands.append("clear && printf '\\e[3J'")

        let combined = commands.joined(separator: "; ")
        surface.sendInput(combined + "\n")
    }

    /// Shell-quote a string for safe interpolation into a shell command.
    private func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

