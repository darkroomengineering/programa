// `surface.wait` with `program_state`: blocks until a terminal's OSC 7501 root record reaches a
// state. A sibling of `AgentStateWaitRegistry` so `agent.prompt`'s agent_state watch is untouched.
import Foundation

/// The `program_state` condition of `surface.wait`. `cleared` means the surface has no root
/// record; `any_change` resolves on the next root-state transition, never on the state at
/// registration time.
enum ProgramStateWaitCondition: String {
    case idle, working, done, blocked, error, cleared
    case anyChange = "any_change"

    func isSatisfied(by state: ProgramStatusState?) -> Bool {
        switch self {
        case .idle: return state == .idle
        case .working: return state == .working
        case .done: return state == .done
        case .blocked: return state == .blocked
        case .error: return state == .error
        case .cleared: return state == nil
        case .anyChange: return false
        }
    }

    func firesOn(transitionTo state: ProgramStatusState?) -> Bool {
        self == .anyChange || isSatisfied(by: state)
    }
}

/// Pending `program_state` waiters keyed by surface id. `notify` is called on the main thread
/// from the single mutation points of the root record (`ProgramStatusDispatcher` and
/// `Workspace.resetSidebarContext`), the same ordering argument as `AgentStateWaitRegistry`.
final class ProgramStateWaitRegistry: @unchecked Sendable {
    static let shared = ProgramStateWaitRegistry()

    private struct Entry {
        let token: UUID
        let condition: ProgramStateWaitCondition
        let callback: (ProgramStatusState?) -> Void
    }

    private let lock = NSLock()
    private var waiters: [UUID: [Entry]] = [:]

    @discardableResult
    func addWaiter(
        surfaceId: UUID,
        condition: ProgramStateWaitCondition,
        callback: @escaping (ProgramStatusState?) -> Void
    ) -> UUID {
        let token = UUID()
        lock.lock()
        waiters[surfaceId, default: []].append(Entry(token: token, condition: condition, callback: callback))
        lock.unlock()
        return token
    }

    func removeWaiter(surfaceId: UUID, token: UUID) {
        lock.lock()
        waiters[surfaceId]?.removeAll { $0.token == token }
        if waiters[surfaceId]?.isEmpty == true { waiters.removeValue(forKey: surfaceId) }
        lock.unlock()
    }

    func notify(surfaceId: UUID, newState: ProgramStatusState?) {
        lock.lock()
        let current = waiters[surfaceId] ?? []
        let fired = current.filter { $0.condition.firesOn(transitionTo: newState) }
        let remaining = current.filter { !$0.condition.firesOn(transitionTo: newState) }
        if remaining.isEmpty {
            waiters.removeValue(forKey: surfaceId)
        } else {
            waiters[surfaceId] = remaining
        }
        lock.unlock()
        for entry in fired { entry.callback(newState) }
    }
}

extension TerminalController {
    nonisolated func v2SurfaceWaitProgramState(
        params: [String: Any],
        condition: ProgramStateWaitCondition,
        timeoutMs: Int,
        deadline: Date
    ) -> V2CallResult {
        let semaphore = DispatchSemaphore(value: 0)
        var setupError: V2CallResult?
        var workspaceId: UUID?
        var surfaceId: UUID?
        var windowId: UUID?
        var alreadySatisfied = false
        var waiterToken: UUID?
        // Written once, either in the main-thread hop below or from the registry callback before
        // it signals the semaphore, so reading it after a successful wait needs no extra lock.
        var resolved: ProgramStatusState?

        v2MainSync {
            guard let tabManager = self.v2ResolveTabManager(params: params) else {
                setupError = .err(code: "unavailable", message: "TabManager not available", data: nil)
                return
            }
            guard let ws = self.v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                setupError = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            guard let id = self.v2UUID(params, "surface_id") ?? ws.focusedPanelId else {
                setupError = .err(code: "not_found", message: "No focused surface", data: nil)
                return
            }
            workspaceId = ws.id
            surfaceId = id
            windowId = self.v2ResolveWindowId(tabManager: tabManager)
            guard let panel = ws.panels[id] else {
                setupError = .err(code: "not_found", message: "Surface not found", data: ["surface_id": id.uuidString])
                return
            }
            guard let terminal = panel as? TerminalPanel else {
                setupError = .err(code: "invalid_params", message: "Surface is not a terminal", data: ["surface_id": id.uuidString])
                return
            }
            let current = terminal.programStatus.root?.state
            if condition.isSatisfied(by: current) {
                alreadySatisfied = true
                resolved = current
            } else {
                waiterToken = ProgramStateWaitRegistry.shared.addWaiter(surfaceId: id, condition: condition) { newState in
                    resolved = newState
                    semaphore.signal()
                }
            }
        }

        if let setupError { return setupError }
        guard let workspaceId, let surfaceId else {
            return .err(code: "internal_error", message: "Failed to resolve surface", data: nil)
        }

        func result(waited: Bool, closed: Bool = false) -> V2CallResult {
            var payload: [String: Any] = [
                "workspace_id": workspaceId.uuidString,
                "workspace_ref": self.v2Ref(kind: .workspace, uuid: workspaceId),
                "surface_id": surfaceId.uuidString,
                "surface_ref": self.v2Ref(kind: .surface, uuid: surfaceId),
                "window_id": self.v2OrNull(windowId?.uuidString),
                "window_ref": self.v2Ref(kind: .window, uuid: windowId),
                "condition": "program_state",
                "waited": waited,
                "program_state": self.v2OrNull(resolved?.rawValue),
            ]
            if closed { payload["outcome"] = "closed" }
            return .ok(payload)
        }

        if alreadySatisfied { return result(waited: false) }
        guard let waiterToken else {
            return .err(code: "internal_error", message: "Failed to register program_state watcher", data: nil)
        }
        let outcome = v2WatchedWait(semaphore, until: deadline, surfaceId: surfaceId)
        if case .signaled = outcome { return result(waited: true) }
        ProgramStateWaitRegistry.shared.removeWaiter(surfaceId: surfaceId, token: waiterToken)
        switch outcome {
        case .surfaceClosed: return result(waited: true, closed: true)
        case .clientGone: return v2ClientGoneError
        case .signaled, .timedOut:
            return .err(
                code: "timeout",
                message: "Surface's program_state did not reach '\(condition.rawValue)' before timeout",
                data: ["timeout_ms": timeoutMs]
            )
        }
    }
}
