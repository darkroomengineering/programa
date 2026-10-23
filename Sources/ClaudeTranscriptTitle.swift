import Foundation

/// Reads the topic of a Claude Code session out of its transcript JSONL. Claude appends
/// `{"type":"custom-title","customTitle":...}` (a `/rename`) and
/// `{"type":"ai-title","aiTitle":...}` lines as the session goes on, so the latest of each
/// sits near the end of the file. Compiled into both the app and the CLI.
enum ClaudeTranscriptTitle {
    static let defaultTailBytes = 512 * 1024

    private static let customMarker = Data(#""type":"custom-title""#.utf8)
    private static let aiMarker = Data(#""type":"ai-title""#.utf8)

    /// The latest `/rename` title, else the latest AI title, from the last `tailBytes` of the
    /// file. Nil when the file is unreadable or holds neither.
    static func latestTitle(atPath path: String, tailBytes: Int = defaultTailBytes) -> String? {
        guard tailBytes > 0, let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd() else { return nil }
        return latestTitle(in: data, dropsLeadingPartialLine: start > 0)
    }

    /// `dropsLeadingPartialLine` is true when `data` starts mid-file, so its first line may be cut.
    static func latestTitle(in data: Data, dropsLeadingPartialLine: Bool = false) -> String? {
        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        if dropsLeadingPartialLine, !lines.isEmpty { lines.removeFirst() }

        var aiTitle: String?
        for line in lines.reversed() {
            if line.range(of: customMarker) != nil,
               let title = value(of: "customTitle", in: line) {
                return title
            }
            if aiTitle == nil, line.range(of: aiMarker) != nil {
                aiTitle = value(of: "aiTitle", in: line)
            }
        }
        return aiTitle
    }

    private static func value(of key: String, in line: Data) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let raw = object[key] as? String else { return nil }
        let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }
}
