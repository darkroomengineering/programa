import AppKit
import SwiftUI

struct SetupAssistantView: View {
    enum Step: Int, CaseIterable {
        case look
        case agents
        case permissions
        case finish

        var title: String {
            switch self {
            case .look:
                return String(localized: "setupAssistant.look.title", defaultValue: "Choose a Look")
            case .agents:
                return String(localized: "setupAssistant.agents.title", defaultValue: "Connect Your Agents")
            case .permissions:
                return String(localized: "setupAssistant.permissions.title", defaultValue: "Notifications and CLI")
            case .finish:
                return String(localized: "setupAssistant.finish.title", defaultValue: "You’re All Set")
            }
        }

        var subtitle: String {
            switch self {
            case .look:
                return String(
                    localized: "setupAssistant.look.subtitle",
                    defaultValue: "Pick a theme and font. You can change these later in Settings."
                )
            case .agents:
                return String(
                    localized: "setupAssistant.agents.subtitle",
                    defaultValue: "Install an integration so the sidebar shows when an agent is working, blocked or done."
                )
            case .permissions:
                return String(
                    localized: "setupAssistant.permissions.subtitle",
                    defaultValue: "Get notified when an agent needs you, and use the programa command in any terminal."
                )
            case .finish:
                return String(
                    localized: "setupAssistant.finish.subtitle",
                    defaultValue: "A few shortcuts to get you started. You can change them in Settings."
                )
            }
        }
    }

    static let pickerColumnWidth: CGFloat = 196

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step: Step = .look
    @State private var isMovingForward = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(String(
                    localized: "setupAssistant.stepCounter",
                    defaultValue: "Step \(step.rawValue + 1) of \(Step.allCases.count)"
                ))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(step.title)
                    .font(.title2.weight(.semibold))
                Text(step.subtitle)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 14)
            .id(step)
            .transition(.opacity)

            ZStack(alignment: .top) {
                stepContent
                    .id(step)
                    .transition(stepTransition)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .clipped()

            Divider()
            footer
        }
        .frame(width: SetupAssistantController.panelSize.width, height: SetupAssistantController.panelSize.height)
        .animation(.smooth, value: step)
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .look: SetupLookStep()
        case .agents: SetupAgentsStep()
        case .permissions: SetupPermissionsStep()
        case .finish: SetupFinishStep()
        }
    }

    /// The incoming step slides in from the side it comes from; the outgoing one only fades,
    /// because it keeps the transition it last rendered with. Reduce Motion crossfades.
    private var stepTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .move(edge: isMovingForward ? .trailing : .leading).combined(with: .opacity),
            removal: .opacity
        )
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if step != .finish {
                Button(String(localized: "setupAssistant.skipSetup", defaultValue: "Skip Setup")) {
                    SetupAssistantController.shared.dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }

            Spacer()

            if step != .look {
                Button(String(localized: "setupAssistant.back", defaultValue: "Back")) {
                    move(by: -1)
                }
            }
            if step == .finish {
                Button(String(localized: "setupAssistant.done", defaultValue: "Done")) {
                    SetupAssistantController.shared.dismiss()
                }
                .keyboardShortcut(.defaultAction)
            } else {
                Button(String(localized: "setupAssistant.skipStep", defaultValue: "Skip")) {
                    move(by: 1)
                }
                Button(String(localized: "setupAssistant.continue", defaultValue: "Continue")) {
                    move(by: 1)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func move(by offset: Int) {
        guard let next = Step(rawValue: step.rawValue + offset) else { return }
        isMovingForward = offset > 0
        step = next
    }
}

// MARK: - Look

private struct SetupLookStep: View {
    @AppStorage(AppearanceSettings.appearanceModeKey) private var appearanceMode = AppearanceSettings.defaultMode.rawValue
    @StateObject private var terminalThemeSettings = TerminalThemeSettingsModel()
    @StateObject private var settingsFileStatus = SettingsFileStatusModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                SettingsCard {
                    ThemePickerRow(selectedMode: appearanceMode, onSelect: { mode in appearanceMode = mode.rawValue })
                        .managedBySettingsFile(settingsFileStatus.isManaged(AppearanceSettings.appearanceModeKey))
                }
                SettingsCard {
                    TerminalThemeAndFontRows(
                        model: terminalThemeSettings,
                        pickerColumnWidth: SetupAssistantView.pickerColumnWidth
                    )
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
    }
}

// MARK: - Agents

@MainActor
private final class SetupAgentsModel: ObservableObject {
    struct Status: Equatable {
        var isOnPath: Bool
        var isIntegrationInstalled: Bool
    }

    @Published private(set) var statuses: [AgentIntegrationStatusStore.Agent: Status] = [:]
    private var generation = 0

    func refresh() {
        generation += 1
        let current = generation
        Task {
            let result = await Self.probe()
            guard current == generation else { return }
            statuses = result
        }
    }

    /// The app inherits launchd's minimal PATH when opened from Finder, so `isOnPath` also checks
    /// the usual install locations and only labels the row; Install stays available either way.
    private nonisolated static func probe() async -> [AgentIntegrationStatusStore.Agent: Status] {
        let installed = AgentIntegrationStatusStore.probeInstalledAgents()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var result: [AgentIntegrationStatusStore.Agent: Status] = [:]
        for agent in AgentIntegrationStatusStore.Agent.allCases {
            let executable: String
            var extraCandidates: [String] = []
            switch agent {
            case .claude:
                executable = "claude"
                extraCandidates = ["\(home)/.claude/local/claude"]
            case .codex:
                executable = "codex"
            case .openCode:
                executable = "opencode"
                extraCandidates = ["\(home)/.opencode/bin/opencode"]
            }
            let path = ClaudeProviderUsageFetcher.resolveExecutable(named: executable, extraCandidates: extraCandidates)
            result[agent] = Status(isOnPath: path != nil, isIntegrationInstalled: installed.contains(agent))
        }
        return result
    }
}

private struct SetupAgentsStep: View {
    @StateObject private var model = SetupAgentsModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsCard {
                ForEach(Array(AgentIntegrationStatusStore.Agent.allCases.enumerated()), id: \.offset) { index, agent in
                    if index > 0 { SettingsCardDivider() }
                    row(for: agent)
                }
            }
        }
        .padding(.horizontal, 20)
        .onAppear { model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            // The installers finish in a terminal; coming back to the assistant re-probes.
            if (note.object as? NSWindow)?.identifier == SetupAssistantController.windowIdentifier {
                model.refresh()
            }
        }
    }

    private func row(for agent: AgentIntegrationStatusStore.Agent) -> some View {
        let status = model.statuses[agent]
        return SettingsCardRow(Self.name(for: agent), subtitle: Self.subtitle(for: status)) {
            if status?.isIntegrationInstalled == true {
                Label(
                    String(localized: "setupAssistant.agents.installed", defaultValue: "Installed"),
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(.green)
            } else {
                Button(String(localized: "setupAssistant.agents.install", defaultValue: "Install…")) {
                    SetupAssistantController.shared.installIntegration(for: agent)
                }
                .accessibilityLabel(String(
                    localized: "setupAssistant.agents.installAccessibility",
                    defaultValue: "Install \(Self.name(for: agent)) integration"
                ))
            }
        }
    }

    private static func name(for agent: AgentIntegrationStatusStore.Agent) -> String {
        switch agent {
        case .claude: return String(localized: "setupAssistant.agents.claude", defaultValue: "Claude Code")
        case .codex: return String(localized: "setupAssistant.agents.codex", defaultValue: "Codex")
        case .openCode: return String(localized: "setupAssistant.agents.openCode", defaultValue: "OpenCode")
        }
    }

    private static func subtitle(for status: SetupAgentsModel.Status?) -> String {
        guard let status else {
            return String(localized: "setupAssistant.agents.checking", defaultValue: "Checking…")
        }
        if status.isIntegrationInstalled {
            return String(localized: "setupAssistant.agents.subtitle.installed", defaultValue: "Reports its status to the sidebar.")
        }
        if status.isOnPath {
            return String(localized: "setupAssistant.agents.subtitle.found", defaultValue: "Found on this Mac. The installer opens in a new workspace.")
        }
        return String(localized: "setupAssistant.agents.subtitle.notFound", defaultValue: "Not found on this Mac. You can still install the integration.")
    }
}

// MARK: - Notifications and CLI

private struct SetupPermissionsStep: View {
    @ObservedObject private var notificationStore = TerminalNotificationStore.shared
    @State private var isCLIInstalled = AppDelegate.shared?.isProgramaCLIInstalledInPATH() ?? false

    var body: some View {
        SettingsCard {
            SettingsCardRow(
                String(localized: "settings.notifications.desktop.title", defaultValue: "Desktop Notifications"),
                subtitle: notificationStore.authorizationState.permissionSubtitle
            ) {
                Button(notificationStore.authorizationState.permissionActionTitle) {
                    notificationStore.performPermissionAction()
                }
            }

            SettingsCardDivider()

            SettingsCardRow(
                String(localized: "setupAssistant.cli.title", defaultValue: "Command-Line Tool"),
                subtitle: isCLIInstalled
                    ? String(localized: "setupAssistant.cli.subtitle.installed", defaultValue: "The programa command works in any terminal.")
                    : String(
                        localized: "setupAssistant.cli.subtitle.notInstalled",
                        defaultValue: "Add the programa command to /usr/local/bin so it works outside Programa."
                    )
            ) {
                if isCLIInstalled {
                    Label(
                        String(localized: "setupAssistant.agents.installed", defaultValue: "Installed"),
                        systemImage: "checkmark.circle.fill"
                    )
                    .foregroundStyle(.green)
                } else {
                    Button(String(localized: "setupAssistant.cli.install", defaultValue: "Install")) {
                        AppDelegate.shared?.installProgramaCLIInPath(nil)
                        isCLIInstalled = AppDelegate.shared?.isProgramaCLIInstalledInPATH() ?? false
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .onAppear { notificationStore.refreshAuthorizationStatus() }
    }
}

// MARK: - Finish

private struct SetupFinishStep: View {
    /// Read in `body` so the list follows shortcut edits made while the assistant is open.
    @ObservedObject private var shortcutsObserver = KeyboardShortcutSettingsObserver.shared

    private static let actions: [KeyboardShortcutSettings.Action] = [
        .commandPalette,
        .newTab,
        .goToWorkspace,
        .splitRight,
        .splitDown,
        .toggleSidebar,
        .find,
        .openSettings,
    ]

    var body: some View {
        let _ = shortcutsObserver.revision
        SettingsCard {
            ForEach(Array(Self.actions.enumerated()), id: \.element) { index, action in
                if index > 0 { SettingsCardDivider() }
                HStack {
                    Text(action.label)
                    Spacer()
                    Text(action.displayedShortcutString(for: KeyboardShortcutSettings.shortcut(for: action)))
                        .font(.body.monospaced())
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, SettingsCardMetrics.textInset)
                .padding(.vertical, 7)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, 20)
    }
}
