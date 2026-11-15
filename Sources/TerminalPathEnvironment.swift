import Foundation

/// Composes the PATH values Programa exports to terminals and child processes.
/// Compiled into both the app and the `programa` CLI.
enum TerminalPathEnvironment {
    /// The PATH to export when `directory` must lead `currentPath`, or nil
    /// when `currentPath` already contains it and can be left alone.
    static func startupPath(prependingDirectory directory: String, to currentPath: String) -> String? {
        if currentPath.split(separator: ":").contains(Substring(directory)) {
            return nil
        }
        let separator = currentPath.isEmpty ? "" : ":"
        return "\(directory)\(separator)\(currentPath)"
    }

    /// Prepends `newEntries` to `currentPath`, keeping the first occurrence
    /// of each entry and dropping empty ones.
    static func prependingUniqueEntries(_ newEntries: [String], to currentPath: String?) -> String {
        var ordered: [String] = []
        var seen: Set<String> = []
        for entry in newEntries + (currentPath?.split(separator: ":").map(String.init) ?? []) where !entry.isEmpty {
            if seen.insert(entry).inserted {
                ordered.append(entry)
            }
        }
        return ordered.joined(separator: ":")
    }
}
