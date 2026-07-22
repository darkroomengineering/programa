import Foundation

/// Why a file's content isn't rendered as a line-by-line diff. See
/// docs/plans/diff-review-panel.md §3 "Binary detection" / "Size cap".
enum ReviewNotDiffableReason: Equatable {
    case binary
    case tooLarge(sizeBytes: Int64)
    case newUntrackedFile
}

enum ReviewFileDiffStatus: String, Equatable {
    case added
    case modified
    case deleted
    case renamed
}

enum ReviewDiffLineKind: Equatable {
    case context
    case addition
    case deletion
}

struct ReviewDiffLine: Equatable {
    let kind: ReviewDiffLineKind
    /// 1-based line number in the pre-image (`nil` for pure additions).
    let oldLineNumber: Int?
    /// 1-based line number in the post-image (`nil` for pure deletions). Comments always
    /// address this side -- see `ReviewComment`'s doc comment.
    let newLineNumber: Int?
    let text: String
}

struct ReviewHunk: Equatable {
    let header: String
    let lines: [ReviewDiffLine]
}

struct ReviewFileDiff: Identifiable, Equatable {
    var id: String { newPath ?? oldPath ?? "unknown" }
    let oldPath: String?
    let newPath: String?
    let status: ReviewFileDiffStatus
    var hunks: [ReviewHunk]
    /// Non-nil when this file is rendered as a fixed "not diffable" row instead of hunks.
    var notDiffableReason: ReviewNotDiffableReason?

    var displayPath: String { newPath ?? oldPath ?? "unknown" }
}

/// Hand-rolled unified-diff-text parser. Pure value-type transform (`git diff` output in,
/// `[ReviewFileDiff]` out) -- no third-party diff-parsing dependency, no I/O, fully unit
/// testable by feeding it canned `git diff` text. See docs/plans/diff-review-panel.md §3.
enum ReviewDiffParser {
    /// Parses (potentially multi-file) `git diff --no-color` unified-diff output.
    static func parse(_ diffText: String) -> [ReviewFileDiff] {
        guard !diffText.isEmpty else { return [] }
        let lines = diffText.components(separatedBy: "\n")

        var result: [ReviewFileDiff] = []
        var index = 0
        while index < lines.count {
            guard lines[index].hasPrefix("diff --git ") else {
                index += 1
                continue
            }
            let (fileDiff, nextIndex) = parseFileDiff(lines: lines, startIndex: index)
            if let fileDiff {
                result.append(fileDiff)
            }
            index = max(nextIndex, index + 1)
        }
        return result
    }

    // MARK: - Per-file diff

    private static func parseFileDiff(lines: [String], startIndex: Int) -> (ReviewFileDiff?, Int) {
        let (fallbackOldPath, fallbackNewPath) = pathsFromGitDiffLine(lines[startIndex])

        var index = startIndex + 1
        var oldPath: String?
        var newPath: String?
        var status: ReviewFileDiffStatus = .modified
        var notDiffableReason: ReviewNotDiffableReason?
        var isRename = false

        while index < lines.count {
            let line = lines[index]
            if line.hasPrefix("diff --git ") || line.hasPrefix("@@") {
                break
            }
            if line.hasPrefix("--- ") {
                oldPath = pathFromMarkerLine(line, marker: "--- ")
            } else if line.hasPrefix("+++ ") {
                newPath = pathFromMarkerLine(line, marker: "+++ ")
            } else if line.hasPrefix("rename from ") {
                oldPath = String(line.dropFirst("rename from ".count))
                isRename = true
            } else if line.hasPrefix("rename to ") {
                newPath = String(line.dropFirst("rename to ".count))
                isRename = true
            } else if line.hasPrefix("new file mode") {
                status = .added
            } else if line.hasPrefix("deleted file mode") {
                status = .deleted
            } else if line.hasPrefix("Binary files ") || (line.hasPrefix("Binary file ") && line.hasSuffix("differ")) {
                notDiffableReason = .binary
            }
            index += 1
        }

        if isRename {
            status = .renamed
        }

        var hunks: [ReviewHunk] = []
        while index < lines.count, lines[index].hasPrefix("@@") {
            let (hunk, nextIndex) = parseHunk(lines: lines, startIndex: index)
            hunks.append(hunk)
            index = nextIndex
        }

        // Consume any remaining lines belonging to this file entry (defensive -- there
        // shouldn't normally be any once hunks are exhausted) until the next file or EOF.
        while index < lines.count, !lines[index].hasPrefix("diff --git ") {
            index += 1
        }

        let resolvedOldPath = normalizedGitPath(oldPath ?? fallbackOldPath)
        let resolvedNewPath = normalizedGitPath(newPath ?? fallbackNewPath)
        guard resolvedOldPath != nil || resolvedNewPath != nil else {
            return (nil, index)
        }

        let fileDiff = ReviewFileDiff(
            oldPath: resolvedOldPath,
            newPath: resolvedNewPath,
            status: status,
            hunks: hunks,
            notDiffableReason: notDiffableReason
        )
        return (fileDiff, index)
    }

    /// Fallback path extraction from the `diff --git a/<old> b/<new>` line itself, used when
    /// there are no `---`/`+++` marker lines at all (e.g. a binary-file diff has neither).
    private static func pathsFromGitDiffLine(_ line: String) -> (String?, String?) {
        let prefix = "diff --git a/"
        guard line.hasPrefix(prefix) else { return (nil, nil) }
        let rest = line.dropFirst(prefix.count)
        guard let separatorRange = rest.range(of: " b/") else { return (nil, nil) }
        let old = String(rest[rest.startIndex..<separatorRange.lowerBound])
        let new = String(rest[separatorRange.upperBound...])
        return (old, new)
    }

    private static func pathFromMarkerLine(_ line: String, marker: String) -> String? {
        let path = String(line.dropFirst(marker.count))
        return path == "/dev/null" ? nil : path
    }

    private static func normalizedGitPath(_ rawPath: String?) -> String? {
        guard var path = rawPath else { return nil }
        for prefix in ["a/", "b/"] where path.hasPrefix(prefix) {
            path = String(path.dropFirst(2))
            break
        }
        return path
    }

    // MARK: - Hunks

    private static func parseHunk(lines: [String], startIndex: Int) -> (ReviewHunk, Int) {
        let header = lines[startIndex]
        let (oldStart, newStart) = parseHunkHeader(header) ?? (1, 1)
        var oldLineNumber = oldStart
        var newLineNumber = newStart
        var diffLines: [ReviewDiffLine] = []

        var index = startIndex + 1
        while index < lines.count {
            let line = lines[index]
            if line.hasPrefix("@@") || line.hasPrefix("diff --git ") {
                break
            }
            if line.hasPrefix("\\ No newline at end of file") {
                index += 1
                continue
            }
            guard let marker = line.first else {
                // A genuinely empty line inside a hunk is unusual but is treated as blank
                // context rather than aborting the parse.
                diffLines.append(
                    ReviewDiffLine(kind: .context, oldLineNumber: oldLineNumber, newLineNumber: newLineNumber, text: "")
                )
                oldLineNumber += 1
                newLineNumber += 1
                index += 1
                continue
            }
            switch marker {
            case "+":
                diffLines.append(
                    ReviewDiffLine(kind: .addition, oldLineNumber: nil, newLineNumber: newLineNumber, text: String(line.dropFirst()))
                )
                newLineNumber += 1
            case "-":
                diffLines.append(
                    ReviewDiffLine(kind: .deletion, oldLineNumber: oldLineNumber, newLineNumber: nil, text: String(line.dropFirst()))
                )
                oldLineNumber += 1
            case " ":
                diffLines.append(
                    ReviewDiffLine(kind: .context, oldLineNumber: oldLineNumber, newLineNumber: newLineNumber, text: String(line.dropFirst()))
                )
                oldLineNumber += 1
                newLineNumber += 1
            default:
                // Resilience for unexpected marker characters in odd git output.
                diffLines.append(
                    ReviewDiffLine(kind: .context, oldLineNumber: oldLineNumber, newLineNumber: newLineNumber, text: line)
                )
                oldLineNumber += 1
                newLineNumber += 1
            }
            index += 1
        }

        return (ReviewHunk(header: header, lines: diffLines), index)
    }

    /// Parses `"@@ -oldStart[,oldCount] +newStart[,newCount] @@..."` into the two start lines.
    private static func parseHunkHeader(_ header: String) -> (oldStart: Int, newStart: Int)? {
        guard header.hasPrefix("@@ ") else { return nil }
        let body = header.dropFirst(3)
        let tokens = body.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard tokens.count >= 2 else { return nil }
        guard let oldStart = rangeStart(String(tokens[0]), expectedPrefix: "-") else { return nil }
        guard let newStart = rangeStart(String(tokens[1]), expectedPrefix: "+") else { return nil }
        return (oldStart, newStart)
    }

    private static func rangeStart(_ token: String, expectedPrefix: String) -> Int? {
        guard token.hasPrefix(expectedPrefix) else { return nil }
        let body = token.dropFirst(expectedPrefix.count)
        let startToken = body.split(separator: ",", maxSplits: 1).first.map(String.init) ?? String(body)
        return Int(startToken)
    }
}
