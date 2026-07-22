import Foundation

/// A single line-range comment attached to a diff review panel. See
/// docs/plans/diff-review-panel.md §4 for the line-numbering convention: comments always
/// address the new-file (right-hand/`+`) line numbers, including for context lines. For a pure
/// deletion (no corresponding new-file line), the UI anchors the comment to the nearest
/// preceding new-file line.
///
/// Comments are never dropped on a refresh, even when the file/line range they reference no
/// longer exists (file deleted, or the diff shrank) -- they are flagged `isStale` instead. See
/// `ReviewPanel.refresh()`.
struct ReviewComment: Identifiable, Codable, Equatable {
    let id: UUID
    var filePath: String
    var startLine: Int
    var endLine: Int
    var text: String
    let createdAt: Date
    var isStale: Bool

    init(
        id: UUID = UUID(),
        filePath: String,
        startLine: Int,
        endLine: Int? = nil,
        text: String,
        createdAt: Date = Date(),
        isStale: Bool = false
    ) {
        self.id = id
        self.filePath = filePath
        self.startLine = startLine
        self.endLine = endLine ?? startLine
        self.text = text
        self.createdAt = createdAt
        self.isStale = isStale
    }
}
