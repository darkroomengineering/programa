import AppKit
import Combine

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
