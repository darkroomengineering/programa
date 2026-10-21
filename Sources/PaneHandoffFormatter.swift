import Foundation

/// Formats another pane's recent output as context to paste into an agent prompt. Compiled into
/// both the app (command palette) and the `programa` CLI (`programa handoff`), so keep it
/// Foundation-only.
enum PaneHandoffFormatter {
    static let defaultLineCount = 200
    static let maxLineCount = 1000

    /// The pasted block ends with a newline so text the user types next starts on its own line.
    static func format(sourceLabel: String, text: String, note: String?) -> String {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        let body = lines.isEmpty ? "(no output)" : lines.joined(separator: "\n")
        var result = "Context from \(sourceLabel):\n\(body)\n"
        if let note = note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
            result += "\nNote: \(note)\n"
        }
        return result
    }
}
