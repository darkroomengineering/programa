// Routes OSC 7501 program status actions from Ghostty's action callback to the per-terminal
// `ProgramStatusStore`, then projects the root record into the workspace's agent presence.
import Foundation
import Bonsplit

/// The action callback can fire at high rates from a misbehaving program, so events queue per
/// surface and drain in one main-queue hop. A report replaces an earlier queued report for the
/// same id unless a prompt, reset or clear sits between them.
final class ProgramStatusDispatcher: @unchecked Sendable {
    static let shared = ProgramStatusDispatcher()

    enum Event: Equatable {
        case report(ProgramStatusReport)
        case prompt
        case resetAll
    }

    private struct Key: Hashable {
        let tabId: UUID
        let surfaceId: UUID
    }

    private let lock = NSLock()
    private var pending: [Key: [Event]] = [:]

    /// Safe to call from any thread. `body` must already be copied out of Ghostty's buffer.
    static func handle(
        tabId: UUID,
        surfaceId: UUID,
        event: ghostty_action_program_status_event_e,
        state: ghostty_action_program_status_state_e,
        body: Data
    ) {
        let parsed: Event?
        switch event {
        case GHOSTTY_PROGRAM_STATUS_EVENT_REPORT:
            let legacy: ProgramStatusState?
            switch state {
            case GHOSTTY_PROGRAM_STATUS_STATE_IDLE: legacy = .idle
            case GHOSTTY_PROGRAM_STATUS_STATE_WORKING: legacy = .working
            case GHOSTTY_PROGRAM_STATUS_STATE_DONE: legacy = .done
            case GHOSTTY_PROGRAM_STATUS_STATE_BLOCKED: legacy = .blocked
            case GHOSTTY_PROGRAM_STATUS_STATE_ERROR: legacy = .error
            default: legacy = nil // CLEAR
            }
            if legacy == nil, state != GHOSTTY_PROGRAM_STATUS_STATE_CLEAR {
                parsed = nil
            } else {
                parsed = ProgramStatusReport.parse(state: legacy, body: body).map(Event.report)
            }
        case GHOSTTY_PROGRAM_STATUS_EVENT_PROMPT:
            parsed = .prompt
        case GHOSTTY_PROGRAM_STATUS_EVENT_RESET_ALL:
            parsed = .resetAll
        default:
            parsed = nil
        }
        guard let parsed else { return }
        shared.enqueue(Key(tabId: tabId, surfaceId: surfaceId), parsed)
    }

    private func enqueue(_ key: Key, _ event: Event) {
        lock.lock()
        var events = pending[key] ?? []
        let wasEmpty = events.isEmpty
        Self.coalesce(&events, event)
        pending[key] = events
        lock.unlock()
        guard wasEmpty else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.drain(key) }
        }
    }

    private static func coalesce(_ events: inout [Event], _ event: Event) {
        switch event {
        case .report(let report) where report.state != nil:
            for index in events.indices.reversed() {
                guard case .report(let queued) = events[index], queued.state != nil else { break }
                // Only a same-state update (progress, text) may replace a queued report; a state
                // change must reach waiters and notifications even inside one burst.
                if queued.id == report.id {
                    guard queued.state == report.state else { break }
                    events[index] = event
                    return
                }
            }
        case .prompt, .resetAll:
            if events.last == event { return }
        default:
            break
        }
        events.append(event)
    }

    @MainActor
    private func drain(_ key: Key) {
        lock.lock()
        let events = pending.removeValue(forKey: key) ?? []
        lock.unlock()
        guard let manager = AppDelegate.shared?.tabManagerFor(tabId: key.tabId),
              let workspace = manager.tabs.first(where: { $0.id == key.tabId }),
              let panel = workspace.panels[key.surfaceId] as? TerminalPanel else { return }

        var lastRootState = panel.programStatus.root?.state
        var transitions: [ProgramStatusRecord?] = []
        var projectRoot = false
        for event in events {
            defer {
                let root = panel.programStatus.root
                if root?.state != lastRootState {
                    transitions.append(root)
                    lastRootState = root?.state
                }
            }
            switch event {
            case .report(let report):
                if case .applied(let rootTouched) = panel.programStatus.apply(report) {
                    projectRoot = projectRoot || rootTouched
                }
#if DEBUG
                dlog(
                    "programStatus.report surface=\(key.surfaceId.uuidString.prefix(5)) " +
                    "id=\(report.id) state=\(report.state?.rawValue ?? "clear") " +
                    "records=\(panel.programStatus.count)"
                )
#endif
            case .prompt:
                projectRoot = panel.programStatus.dropTransient() || projectRoot
#if DEBUG
                dlog("programStatus.prompt surface=\(key.surfaceId.uuidString.prefix(5)) records=\(panel.programStatus.count)")
#endif
            case .resetAll:
                projectRoot = panel.programStatus.resetAll() || projectRoot
#if DEBUG
                dlog("programStatus.reset surface=\(key.surfaceId.uuidString.prefix(5))")
#endif
            }
        }
        guard projectRoot else { return }

        // Only a change to the root record projects. Re-projecting on every event would let a
        // resting `done` record overwrite a hook agent that legitimately took over the surface.
        if let root = panel.programStatus.root {
            manager.updateSurfaceAgentState(
                tabId: key.tabId,
                surfaceId: key.surfaceId,
                state: root.state.legacyAgentState,
                source: .program,
                programState: root.state
            )
        } else {
            manager.clearSurfaceAgentState(tabId: key.tabId, surfaceId: key.surfaceId, source: .program)
        }

        for root in transitions {
            ProgramStateWaitRegistry.shared.notify(surfaceId: key.surfaceId, newState: root?.state)
            if let root {
                postNotificationIfNeeded(for: root, manager: manager, workspace: workspace, surfaceId: key.surfaceId)
            }
        }
    }

    /// Notifies when the root record enters blocked, done or error on a surface the user is not
    /// looking at. The hook-managed path already posts for the same moment, so it is skipped.
    /// Title is Programa's tab title and the body is Programa's own wording: `notification.list`
    /// returns notification text over the socket, and the spec forbids revealing a record's
    /// `msg` or `title` back to programs.
    @MainActor
    private func postNotificationIfNeeded(
        for root: ProgramStatusRecord,
        manager: TabManager,
        workspace: Workspace,
        surfaceId: UUID
    ) {
        guard root.state == .blocked || root.state == .done || root.state == .error else { return }
        guard !workspace.hasHookManagedAgent else { return }
        let isFocused = manager.selectedTabId == workspace.id
            && manager.focusedSurfaceId(for: workspace.id) == surfaceId
        guard !(isFocused && AppFocusState.isAppFocused()) else { return }

        let body = Self.defaultNotificationBody(for: root)
        TerminalNotificationStore.shared.addNotification(
            tabId: workspace.id,
            surfaceId: surfaceId,
            title: manager.titleForTab(workspace.id) ?? "Terminal",
            subtitle: "",
            body: body,
            cooldownKey: "program-status-\(surfaceId.uuidString)",
            cooldownInterval: 10
        )
    }

    private static func defaultNotificationBody(for root: ProgramStatusRecord) -> String {
        switch root.state {
        case .blocked:
            switch root.kind {
            case .permission:
                return String(localized: "notification.programStatus.blockedPermission", defaultValue: "Needs your permission")
            case .question:
                return String(localized: "notification.programStatus.blockedQuestion", defaultValue: "Has a question for you")
            case .auth:
                return String(localized: "notification.programStatus.blockedAuth", defaultValue: "Needs you to sign in")
            case nil:
                return String(localized: "notification.programStatus.blocked", defaultValue: "Needs your input")
            }
        case .error:
            return String(localized: "notification.programStatus.error", defaultValue: "Failed")
        default:
            return String(localized: "notification.programStatus.done", defaultValue: "Finished")
        }
    }
}
