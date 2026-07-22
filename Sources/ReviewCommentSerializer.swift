import Foundation

/// Serializes pending `ReviewComment`s into the plain-text format sent back into an agent's
/// terminal surface by `review.send_comments`. Pure function, unit-testable without any panel
/// or socket dependency. See docs/plans/diff-review-panel.md §4 for the exact format.
enum ReviewCommentSerializer {
    static let defaultPreamble = "Code review comments"

    /// Renders `comments` as:
    /// ```
    /// Code review comments (3):
    ///
    /// src/foo.swift:12-14 — this branch never runs when `x` is nil, please add a guard
    /// src/bar.swift:41 — typo: "recieve" -> "receive"
    /// ```
    /// Comments are grouped file-then-line order regardless of creation order, so the output is
    /// stable and scannable for the agent reading it. Returns an empty string for no comments
    /// (callers should treat that as "nothing to send", not call this at all).
    static func serialize(comments: [ReviewComment], preamble: String? = nil) -> String {
        guard !comments.isEmpty else { return "" }

        let ordered = comments.sorted { lhs, rhs in
            if lhs.filePath != rhs.filePath { return lhs.filePath < rhs.filePath }
            if lhs.startLine != rhs.startLine { return lhs.startLine < rhs.startLine }
            return lhs.endLine < rhs.endLine
        }

        let resolvedPreamble = preamble?.trimmingCharacters(in: .whitespacesAndNewlines)
        let header = "\((resolvedPreamble?.isEmpty == false ? resolvedPreamble! : defaultPreamble)) (\(ordered.count)):"

        var lines: [String] = [header, ""]
        for comment in ordered {
            lines.append("\(comment.filePath):\(lineRangeToken(comment)) — \(normalizedText(comment.text))")
        }
        return lines.joined(separator: "\n")
    }

    private static func lineRangeToken(_ comment: ReviewComment) -> String {
        comment.startLine == comment.endLine
            ? "\(comment.startLine)"
            : "\(comment.startLine)-\(comment.endLine)"
    }

    /// Embedded newlines are replaced with `" / "` so the whole serialization stays trivially
    /// line-parseable (one comment per line) if an agent or test wants to re-split it.
    private static func normalizedText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: " / ")
            .replacingOccurrences(of: "\n", with: " / ")
            .replacingOccurrences(of: "\r", with: " / ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
