import AppKit
import Combine
import SwiftUI

/// Whether a persistent agent hook integration (`programa <agent> install-integration`) is
/// installed, probed off the main thread at launch, on app activation, and on focus changes
/// while an installer workspace is pending. The probe mirrors the installers' targets and
/// ownership markers in CLI/CLI+HookSettingsIO.swift (Claude), CLI/CLI+CodexConfig.swift
/// (Codex) and CLI/CLI+Hooks.swift (OpenCode); change both sides together.
@MainActor
final class AgentIntegrationStatusStore: ObservableObject {
    enum State: Equatable {
        case unknown
        case notInstalled
        /// An installer workspace was opened; the CLI may still be waiting for confirmation.
        case awaitingInstaller
        case installed

        var showsSetupHint: Bool {
            self == .notInstalled || self == .awaitingInstaller
        }
    }

    static let shared = AgentIntegrationStatusStore()
    static let hintDismissedKey = "sidebarAgentSetupHintDismissed"

    @Published private(set) var state: State = .unknown
    private var probeGeneration = 0
    private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { AgentIntegrationStatusStore.shared.refresh() }
        })
        // The installer finishes inside its terminal, with no completion signal; the next
        // focus change after it (closing or leaving that workspace) re-probes.
        observers.append(center.addObserver(
            forName: .ghosttyDidFocusSurface,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                let store = AgentIntegrationStatusStore.shared
                if store.state == .awaitingInstaller { store.refresh() }
            }
        })
        refresh()
    }

    func noteInstallerOpened() {
        guard state != .installed else { return }
        state = .awaitingInstaller
    }

    func refresh() {
        probeGeneration += 1
        let generation = probeGeneration
        DispatchQueue.global(qos: .utility).async {
            let installed = Self.probeInstalled()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let store = AgentIntegrationStatusStore.shared
                    guard generation == store.probeGeneration else { return }
                    store.apply(installed: installed)
                }
            }
        }
    }

    private func apply(installed: Bool) {
        let next: State = installed ? .installed : (state == .awaitingInstaller ? .awaitingInstaller : .notInstalled)
        if next != state { state = next }
    }

    nonisolated static func probeInstalled(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        let home = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        func configDir(_ key: String, fallback: String) -> String {
            let raw = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let path = raw?.isEmpty == false ? raw! : fallback
            guard path == "~" || path.hasPrefix("~/") else { return path }
            return path == "~" ? home : (home as NSString).appendingPathComponent(String(path.dropFirst(2)))
        }
        let claudeSettings = (configDir("CLAUDE_CONFIG_DIR", fallback: "~/.claude") as NSString)
            .appendingPathComponent("settings.json")
        let codexHooks = (configDir("CODEX_HOME", fallback: "~/.codex") as NSString)
            .appendingPathComponent("hooks.json")
        let openCodePlugin = (configDir("OPENCODE_CONFIG_DIR", fallback: "~/.config/opencode") as NSString)
            .appendingPathComponent("plugins/programa.js")
        return FileManager.default.fileExists(atPath: openCodePlugin)
            || fileContains(claudeSettings, marker: "programa claude-hook")
            || fileContains(codexHooks, marker: "programa codex-hook")
    }

    private nonisolated static func fileContains(_ path: String, marker: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 8 * 1024 * 1024) else { return false }
        return data.range(of: Data(marker.utf8)) != nil
    }
}

/// One quiet footer line shown while no agent hook integration is installed. It owns its own
/// store observation so the sidebar root and its rows never re-render for it.
struct SidebarAgentSetupHint: View {
    @ObservedObject private var store = AgentIntegrationStatusStore.shared
    @AppStorage(AgentIntegrationStatusStore.hintDismissedKey) private var isDismissed = false

    private let title = String(localized: "sidebar.agentSetupHint.title", defaultValue: "Set up agent status")
    private let detail = String(
        localized: "sidebar.agentSetupHint.detail",
        defaultValue: "Install a hook integration so the sidebar shows when an agent is working, blocked or done."
    )
    private let dismissTitle = String(localized: "sidebar.agentSetupHint.dismiss", defaultValue: "Hide this hint")

    var body: some View {
        if !isDismissed && store.state.showsSetupHint {
            HStack(spacing: 4) {
                Menu {
                    Button(String(localized: "menu.file.installClaudeIntegration", defaultValue: "Install Claude Code Integration…")) {
                        AppDelegate.shared?.openClaudeIntegrationInstaller(debugSource: "sidebar.agentSetupHint")
                    }
                    Button(String(localized: "menu.file.installCodexIntegration", defaultValue: "Install Codex Integration…")) {
                        AppDelegate.shared?.openCodexIntegrationInstaller(debugSource: "sidebar.agentSetupHint")
                    }
                    Button(String(localized: "menu.file.installOpenCodeIntegration", defaultValue: "Install OpenCode Integration…")) {
                        AppDelegate.shared?.openOpenCodeIntegrationInstaller(debugSource: "sidebar.agentSetupHint")
                    }
                } label: {
                    Text(title)
                }
                .menuStyle(.button)
                .buttonStyle(.link)
                .menuIndicator(.hidden)
                .fixedSize()
                .safeHelp(detail)
                .accessibilityLabel(title)
                .accessibilityHint(detail)
                .accessibilityIdentifier("SidebarAgentSetupHint")

                Spacer(minLength: 0)

                Button {
                    isDismissed = true
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: SidebarFooterControlLayout.buttonSize, height: SidebarFooterControlLayout.buttonSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .safeHelp(dismissTitle)
                .accessibilityLabel(dismissTitle)
                .accessibilityIdentifier("SidebarAgentSetupHintDismiss")
            }
            .font(.subheadline)
            .controlSize(.small)
            // Text starts on the footer glyph column (edge 8 + the buttons' leading inset + hit inset).
            .padding(.leading, 8 + SidebarFooterControlLayout.leadingInset + SidebarFooterControlLayout.hitInset)
            .padding(.trailing, 8 - SidebarFooterControlLayout.hitInset)
        }
    }
}
