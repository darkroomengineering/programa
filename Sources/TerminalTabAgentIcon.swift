// Agent logos on terminal tabs. A terminal whose panel has agent presence shows that agent's
// logo (asset catalog `Assets.xcassets/AgentIcons`) instead of the terminal symbol; the logo
// goes away when the presence clears. Both tab renderers (the SwiftUI bar in Bonsplit and the
// AppKit glass bar in WindowPaneChromePortal) read `Tab.iconAsset`.

import Bonsplit
import Foundation

enum TerminalTabAgentIconResolver {
    /// Detected agent identifier -> asset name. Identifiers are the screen-manifest ids
    /// (`Resources/AgentDetection/*.json`), the hook provider names, and the short names an agent
    /// goes by in its own CLI. Aider is absent because Lobe Icons ships no Aider mark.
    private static let assetNamesByIdentifier: [String: String] = [
        "claude-code": "AgentIconClaudeCode",
        "claude": "AgentIconClaudeCode",
        "codex": "AgentIconCodex",
        "copilot-cli": "AgentIconCopilot",
        "copilot": "AgentIconCopilot",
        "github-copilot": "AgentIconCopilot",
        "cursor-agent": "AgentIconCursor",
        "cursor": "AgentIconCursor",
        "gemini-cli": "AgentIconGeminiCLI",
        "gemini": "AgentIconGeminiCLI",
        "opencode": "AgentIconOpenCode",
    ]

    static func assetName(forAgent identifier: String) -> String? {
        let normalized = identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return assetNamesByIdentifier[normalized]
    }
}

extension Workspace {
    /// The logo for one terminal panel's current agent, or nil when no agent is present or the
    /// agent has no logo. Identity comes from the first source that names a known agent: the
    /// hook session key, the screen-manifest id, then the OSC 7501 root record's `app`.
    func terminalTabAgentIconAsset(forPanelId panelId: UUID) -> String? {
        guard let presence = panelAgentPresence[panelId] else { return nil }
        let identifiers = [
            presence.sessionKey?.provider,
            presence.inferredAgent,
            presence.source == .program ? terminalPanel(for: panelId)?.programStatus.root?.app : nil,
        ]
        return identifiers.lazy.compactMap { $0 }.compactMap(TerminalTabAgentIconResolver.assetName(forAgent:)).first
    }

    /// Reconciles one terminal tab's logo with its panel's agent presence. No-op when the tab
    /// already shows the right asset.
    func syncTerminalTabAgentIconAsset(forPanelId panelId: UUID) {
        guard panels[panelId] is TerminalPanel,
              let tabId = surfaceIdFromPanelId(panelId),
              let tab = bonsplitController.tab(tabId) else { return }
        let asset = terminalTabAgentIconAsset(forPanelId: panelId)
#if DEBUG
        if let presence = panelAgentPresence[panelId] {
            let app = terminalPanel(for: panelId)?.programStatus.root?.app
            dlog(
                "tab.agentIcon panel=\(panelId.uuidString.prefix(5)) source=\(presence.source) " +
                "provider=\(presence.sessionKey?.provider ?? "nil") inferred=\(presence.inferredAgent ?? "nil") " +
                "app=\(app ?? "nil") asset=\(asset ?? "nil")"
            )
        }
#endif
        guard tab.iconAsset != asset else { return }
        bonsplitController.updateTab(tabId, iconAsset: .some(asset))
    }

    /// Runs after any write to `panelAgentPresence`, whichever path made it (hook, screen
    /// inference, OSC 7501, sweep, detach/attach, prune).
    func syncTerminalTabAgentIconAssets(previous: [UUID: AgentPresence]) {
        for panelId in Set(previous.keys).union(panelAgentPresence.keys)
        where previous[panelId] != panelAgentPresence[panelId] {
            syncTerminalTabAgentIconAsset(forPanelId: panelId)
        }
    }
}
