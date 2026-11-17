import Foundation

extension ProgramaCLI {
    /// Rows of the welcome screen's shortcut list. `fallback` is shown when the app does not answer.
    private static let welcomeShortcuts: [(action: String, fallback: String, label: String)] = [
        ("newTab", "\u{2318}N", "New workspace"),
        ("newSurface", "\u{2318}T", "New tab"),
        ("goToWorkspace", "\u{2318}P", "Go to workspace"),
        ("splitRight", "\u{2318}D", "Split right"),
        ("splitDown", "\u{2318}\u{21E7}D", "Split down"),
        ("commandPalette", "\u{2318}\u{21E7}P", "Command palette"),
        ("renameWorkspace", "\u{2318}\u{21E7}R", "Rename workspace"),
        ("jumpToUnread", "\u{2318}\u{21E7}U", "Jump to latest unread"),
    ]

    /// The running app's bindings by action id. Empty when the app is unreachable or the call
    /// fails; welcome must never launch the app or fail on that.
    func welcomeShortcutBindings(socketPath: String, explicitPassword: String?) -> [String: String] {
        let client = SocketClient(path: socketPath)
        defer { client.close() }
        guard (try? client.connect()) != nil,
              (try? authenticateClientIfNeeded(client, explicitPassword: explicitPassword, socketPath: socketPath)) != nil,
              let result = try? client.sendV2(method: V2MethodNames.shortcutsList),
              let rows = result["shortcuts"] as? [[String: Any]] else { return [:] }
        var bindings: [String: String] = [:]
        for row in rows {
            guard let id = row["id"] as? String, let keys = row["display_string"] as? String, !keys.isEmpty else { continue }
            bindings[id] = keys
        }
        return bindings
    }

    func welcomeShortcutLines(bindings: [String: String], bold: String, subdued: String, reset: String) -> [String] {
        Self.welcomeShortcuts.map { row in
            let keys = bindings[row.action] ?? row.fallback
            let padding = String(repeating: " ", count: max(1, 20 - keys.count))
            return "  \(bold)\(keys)\(reset)\(subdued)\(padding)\(row.label)\(reset)"
        }
    }
}
