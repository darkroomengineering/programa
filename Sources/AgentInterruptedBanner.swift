import AppKit
import Bonsplit
import Foundation
import SwiftUI

/// Why a panel shows the interrupted-agent banner.
enum InterruptedAgentState: Equatable, Sendable {
    /// The agent died without a clean SessionEnd; the shell in the pane is still running.
    case shellAlive
    /// Every process in the pane was killed (the pane's root exited) while an agent ran.
    case paneDead
}

enum AgentInterruptedBannerAction {
    case resume
    case dismiss
}

/// Turns a tracked agent's exit into an interrupted-agent banner when the exit was not clean.
@MainActor
enum AgentInterruptionTracker {
    static func install() {
        LeftoverProcessReaper.shared.onAgentExit = { pid in handleAgentExit(pid: pid) }
    }

    /// A clean SessionEnd hook clears the panel's agent presence before the process exits, so
    /// presence that still carries `pid` means the agent was killed.
    static func handleAgentExit(pid: pid_t) {
        var matched = false
        for workspace in allWorkspaces() {
            var panelIds = workspace.panelAgentPresence.filter { $0.value.sessionKey?.pid == pid }.map(\.key)
            // SessionEnd clears the workspace's Claude pid, so a pid still registered there
            // died without it. Presence only learns the pid on a tool call, so fall back to the
            // one Claude panel that has no pid yet. Program-source presence (OSC 7501) carries
            // no session key, so the panel's provider comes from its resume target.
            if panelIds.isEmpty, workspace.agentPIDs["claude_code"] == pid {
                workspace.agentPIDs.removeValue(forKey: "claude_code")
                let candidates = workspace.panelAgentPresence.filter {
                    $0.value.sessionKey?.pid == nil
                        && ["claude-code", "claude"].contains(AgentResumeStore.shared.target(panelId: $0.key)?.provider ?? "")
                }.map(\.key)
                if candidates.count == 1 { panelIds = candidates }
            }
            for panelId in panelIds {
                guard let presence = workspace.panelAgentPresence[panelId] else { continue }
                matched = true
                dilog("agent", "exit pid=\(pid) panel=\(panelId.uuidString.prefix(8)) clean=false")
                if workspace.interruptedAgentPanels[panelId] == nil, workspace.agentResumeLine(panelId: panelId) != nil {
                    workspace.interruptedAgentPanels[panelId] = .shellAlive
                }
                workspace.clearPanelAgentState(panelId: panelId, force: true)
                let sessionId = presence.sessionKey?.sessionId
                AgentSupervisionRegistry.shared.finishRunningHelpers(workspaceId: workspace.id) { record in
                    record.surfaceId == panelId || (sessionId != nil && record.session == sessionId)
                }
            }
        }
        if !matched {
            dilog("agent", "exit pid=\(pid) panel=none clean=true")
        }
    }

    private static func allWorkspaces() -> [Workspace] {
        var managers: [TabManager] = []
        if let app = AppDelegate.shared {
            managers.append(contentsOf: app.mainWindowContexts.values.map(\.tabManager))
            if let manager = app.tabManager { managers.append(manager) }
        }
        if let manager = TerminalController.shared.tabManager { managers.append(manager) }
        var seen = Set<ObjectIdentifier>()
        return managers
            .filter { seen.insert(ObjectIdentifier($0)).inserted }
            .flatMap(\.tabs)
    }
}

extension Workspace {
    /// The shell line that resumes the panel's last agent session, or nil when there is no
    /// session to resume (unsupported provider, unsafe id, or a Claude session that never got
    /// a first prompt).
    func agentResumeLine(panelId: UUID, paneDirectory: String? = nil) -> String? {
        guard let target = AgentResumeStore.shared.target(panelId: panelId),
              let line = AgentResumeCommand.line(
                for: target, paneDirectory: paneDirectory ?? panelDirectories[panelId]
              ),
              !AgentResumeCommand.claudeTranscriptIsMissing(for: target) else { return nil }
        return line
    }

    func handleInterruptedAgentAction(_ action: AgentInterruptedBannerAction, panelId: UUID) {
        guard let state = interruptedAgentPanels[panelId] else { return }
        switch (action, state) {
        case (.resume, .shellAlive):
            guard let terminalPanel = terminalPanel(for: panelId),
                  let line = agentResumeLine(panelId: panelId) else {
                NSSound.beep()
                return
            }
            interruptedAgentPanels.removeValue(forKey: panelId)
            terminalPanel.sendInput(line + "\r")
        case (.resume, .paneDead):
            // The new tab starts in the dead pane's directory, so the line is built for it.
            let directory = panelDirectories[panelId] ?? terminalPanel(for: panelId)?.requestedWorkingDirectory
            guard let paneId = paneId(forPanelId: panelId),
                  let line = agentResumeLine(panelId: panelId, paneDirectory: directory),
                  newTerminalSurface(inPane: paneId, focus: true, workingDirectory: directory, initialInput: line + "\n") != nil
            else {
                NSSound.beep()
                return
            }
            closeDeadPanel(panelId)
        case (.dismiss, .shellAlive):
            interruptedAgentPanels.removeValue(forKey: panelId)
        case (.dismiss, .paneDead):
            closeDeadPanel(panelId)
        }
    }

    private func closeDeadPanel(_ panelId: UUID) {
        if let owningTabManager {
            owningTabManager.closePanelAfterChildExitedUnconditionally(tab: self, surfaceId: panelId)
        } else {
            interruptedAgentPanels.removeValue(forKey: panelId)
            _ = closePanel(panelId, force: true)
        }
    }
}

/// Top-of-pane bar shown over a terminal whose agent was interrupted. Mounted from
/// `GhosttySurfaceScrollView` (the portal layer), never from a SwiftUI panel container.
struct AgentInterruptedBanner: View {
    let state: InterruptedAgentState
    let onAction: (AgentInterruptedBannerAction) -> Void

    private var message: String {
        switch state {
        case .shellAlive:
            return String(localized: "agentInterrupted.shellAlive.message", defaultValue: "Claude stopped unexpectedly.")
        case .paneDead:
            return String(localized: "agentInterrupted.paneDead.message", defaultValue: "This pane's processes were killed.")
        }
    }

    private var dismissTitle: String {
        switch state {
        case .shellAlive:
            return String(localized: "agentInterrupted.dismiss", defaultValue: "Dismiss")
        case .paneDead:
            return String(localized: "agentInterrupted.close", defaultValue: "Close")
        }
    }

    private var dismissAccessibilityLabel: String {
        switch state {
        case .shellAlive:
            return String(localized: "agentInterrupted.dismiss.accessibility", defaultValue: "Dismiss this notice")
        case .paneDead:
            return String(localized: "agentInterrupted.close.accessibility", defaultValue: "Close this pane")
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .accessibilityHidden(true)
            Text(message)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Button(String(localized: "agentInterrupted.resume", defaultValue: "Resume")) {
                onAction(.resume)
            }
            .accessibilityLabel(String(
                localized: "agentInterrupted.resume.accessibility", defaultValue: "Resume the Claude session"
            ))
            Button(dismissTitle) {
                onAction(.dismiss)
            }
            .accessibilityLabel(dismissAccessibilityLabel)
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
    }
}
