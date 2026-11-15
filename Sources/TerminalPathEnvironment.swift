import Foundation

/// Composes the PATH values Programa exports to terminals and child processes.
/// Compiled into both the app and the `programa` CLI.
enum TerminalPathEnvironment {
    /// The components of `path`, minus any that cannot be re-exported intact.
    ///
    /// Foundation and `String(cString:)` decode malformed inherited bytes as
    /// U+FFFD, so such a component no longer names the directory it came
    /// from, and strict tools reject the PATH that carries it. Components with
    /// control characters are dropped for the same reason. Empty components
    /// are kept, since they mean the current directory.
    static func components(from path: String) -> [String] {
        path.split(separator: ":", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.unicodeScalars.contains(where: isMalformedScalar) }
    }

    /// The PATH to export when `directory` must lead `currentPath`, or nil
    /// when `currentPath` already contains it and has nothing to drop.
    static func startupPath(prependingDirectory directory: String, to currentPath: String) -> String? {
        let entries = components(from: currentPath)
        let sanitizedPath = entries.joined(separator: ":")
        if entries.contains(directory) {
            return sanitizedPath == currentPath ? nil : sanitizedPath
        }
        return sanitizedPath.isEmpty ? directory : "\(directory):\(sanitizedPath)"
    }

    /// Prepends `newEntries` to `currentPath`, keeping the first occurrence
    /// of each entry and dropping empty and malformed ones.
    static func prependingUniqueEntries(_ newEntries: [String], to currentPath: String?) -> String {
        var ordered: [String] = []
        var seen: Set<String> = []
        for entry in newEntries + components(from: currentPath ?? "") where !entry.isEmpty {
            if seen.insert(entry).inserted {
                ordered.append(entry)
            }
        }
        return ordered.joined(separator: ":")
    }

    private static func isMalformedScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "\u{FFFD}" || CharacterSet.controlCharacters.contains(scalar)
    }
}
