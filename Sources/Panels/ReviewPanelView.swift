import AppKit
import SwiftUI

/// SwiftUI view for a `ReviewPanel`: per-file collapsible diff sections, click-a-line (or
/// shift-click a range) to attach a comment, and a "Send to agent" action. Modeled on
/// `MarkdownPanelView.swift`'s structure (focus-flash overlay, read-only content). No syntax
/// highlighting in v1 -- diff lines render as colored +/- rows in a monospace font, mirroring
/// git's own coloring model. See docs/plans/diff-review-panel.md §1/§3.
struct ReviewPanelView: View {
    @ObservedObject var panel: ReviewPanel
    let isFocused: Bool
    let isVisibleInUI: Bool
    let portalPriority: Int
    let onRequestPanelFocus: () -> Void

    @State private var collapsedFilePaths: Set<String> = []
    @State private var composer: InlineComposerState?

    private struct InlineComposerState {
        let filePath: String
        let anchorLine: Int
        var startLine: Int
        var endLine: Int
        var text: String = ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let lastError = panel.lastError {
                        errorBanner(for: lastError)
                            .padding(16)
                    } else if panel.files.isEmpty {
                        emptyStateView
                            .padding(24)
                    } else {
                        ForEach(panel.files) { file in
                            fileSection(file)
                        }
                    }

                    if !panel.comments.isEmpty {
                        pendingCommentsSection
                            .padding(16)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .background {
            if isVisibleInUI {
                // Low-priority tap target so clicking empty panel chrome requests focus
                // without stealing taps from line rows / buttons rendered above it.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { onRequestPanelFocus() }
            }
        }
        .overlay {
            PhaseAnimator(FocusFlashPattern.values.indices, trigger: panel.focusFlashToken) { phaseIndex in
                RoundedRectangle(cornerRadius: FocusFlashPattern.ringCornerRadius)
                    .stroke(programaAccentColor().opacity(FocusFlashPattern.values[phaseIndex]), lineWidth: 3)
                    .shadow(color: programaAccentColor().opacity(FocusFlashPattern.values[phaseIndex] * 0.35), radius: 10)
                    .padding(FocusFlashPattern.ringInset)
                    .allowsHitTesting(false)
            } animation: { phaseIndex in
                FocusFlashPattern.phaseAnimation(at: phaseIndex)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "checklist")
                .foregroundColor(.secondary)
            Text(panel.displayTitle)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            Spacer()
            if panel.isRefreshing {
                ProgressView()
                    .controlSize(.small)
            }
            Button {
                panel.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .safeHelp(String(localized: "review.refresh.help", defaultValue: "Refresh diff"))
        }
    }

    // MARK: - Empty / error states

    private var emptyStateView: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 28))
                .foregroundColor(.secondary)
            Text(String(localized: "review.empty.title", defaultValue: "No changes to review"))
                .font(.headline)
            Text(String(localized: "review.empty.message", defaultValue: "The reviewed surface's worktree has no diffable changes right now."))
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private func errorBanner(for error: ReviewDiffError) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 24))
                .foregroundColor(.orange)
            Text(errorTitle(for: error))
                .font(.headline)
            if let detail = errorDetail(for: error) {
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func errorTitle(for error: ReviewDiffError) -> String {
        switch error {
        case .notGitRepository:
            return String(localized: "review.error.notGitRepository.title", defaultValue: "Not a git repository")
        case .unknownBaseBranch:
            return String(localized: "review.error.unknownBaseBranch.title", defaultValue: "Unknown base branch")
        }
    }

    private func errorDetail(for error: ReviewDiffError) -> String? {
        switch error {
        case .notGitRepository:
            return String(localized: "review.error.notGitRepository.message", defaultValue: "This surface's working directory isn't inside a git worktree.")
        case .unknownBaseBranch(let branch):
            return String(localized: "review.error.unknownBaseBranch.message", defaultValue: "Couldn't resolve '\(branch)', 'main', or 'master'.")
        }
    }

    // MARK: - Per-file sections

    @ViewBuilder
    private func fileSection(_ file: ReviewFileDiff) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            fileHeader(file)
            if let reason = file.notDiffableReason {
                notDiffableRow(reason)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            } else if !collapsedFilePaths.contains(file.id) {
                ForEach(Array(file.hunks.enumerated()), id: \.offset) { _, hunk in
                    hunkView(hunk, file: file)
                }
            }
        }
        .padding(.bottom, 4)
    }

    private func fileHeader(_ file: ReviewFileDiff) -> some View {
        Button {
            if collapsedFilePaths.contains(file.id) {
                collapsedFilePaths.remove(file.id)
            } else {
                collapsedFilePaths.insert(file.id)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: collapsedFilePaths.contains(file.id) ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary)
                statusBadge(file.status)
                Text(file.displayPath)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color.primary.opacity(0.04))
    }

    private func statusBadge(_ status: ReviewFileDiffStatus) -> some View {
        let (label, color): (String, Color) = {
            switch status {
            case .added:
                return (String(localized: "review.status.added", defaultValue: "A"), .green)
            case .modified:
                return (String(localized: "review.status.modified", defaultValue: "M"), .yellow)
            case .deleted:
                return (String(localized: "review.status.deleted", defaultValue: "D"), .red)
            case .renamed:
                return (String(localized: "review.status.renamed", defaultValue: "R"), .blue)
            }
        }()
        return Text(label)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundColor(color)
            .frame(width: 14)
    }

    private func notDiffableRow(_ reason: ReviewNotDiffableReason) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.questionmark")
                .foregroundColor(.secondary)
            Text(notDiffableLabel(reason))
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private func notDiffableLabel(_ reason: ReviewNotDiffableReason) -> String {
        switch reason {
        case .binary:
            return String(localized: "review.notDiffable.binary", defaultValue: "Binary file -- not diffable")
        case .tooLarge(let sizeBytes):
            let kilobytes = sizeBytes / 1024
            return String(localized: "review.notDiffable.tooLarge", defaultValue: "Too large to diff (\(kilobytes) KB)")
        case .newUntrackedFile:
            return String(localized: "review.notDiffable.newUntrackedFile", defaultValue: "New file")
        }
    }

    // MARK: - Hunks / lines

    private func hunkView(_ hunk: ReviewHunk, file: ReviewFileDiff) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(hunk.header)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.02))

            ForEach(Array(annotatedRows(for: hunk).enumerated()), id: \.offset) { _, row in
                lineRow(row, file: file)
                if let composer, composer.filePath == file.id, composer.endLine == row.anchorLine {
                    inlineComposer(composer)
                }
            }
        }
    }

    private struct AnnotatedLine {
        let line: ReviewDiffLine
        /// The new-file line number a comment attached at this row would address: the line's
        /// own `newLineNumber` when present, otherwise the nearest preceding new-file line (for
        /// pure-deletion rows). See docs/plans/diff-review-panel.md §4.
        let anchorLine: Int
    }

    private func annotatedRows(for hunk: ReviewHunk) -> [AnnotatedLine] {
        var anchor = hunk.lines.first(where: { $0.newLineNumber != nil })?.newLineNumber ?? 0
        return hunk.lines.map { line in
            if let newLineNumber = line.newLineNumber {
                anchor = newLineNumber
            }
            return AnnotatedLine(line: line, anchorLine: anchor)
        }
    }

    private func lineRow(_ row: AnnotatedLine, file: ReviewFileDiff) -> some View {
        HStack(spacing: 0) {
            Text(row.line.oldLineNumber.map(String.init) ?? "")
                .frame(width: 36, alignment: .trailing)
                .foregroundColor(.secondary)
            Text(row.line.newLineNumber.map(String.init) ?? "")
                .frame(width: 36, alignment: .trailing)
                .foregroundColor(.secondary)
                .padding(.trailing, 8)
            Text(row.line.text.isEmpty ? " " : row.line.text)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.vertical, 1)
        .padding(.horizontal, 4)
        .background(backgroundColor(for: row.line.kind))
        .contentShape(Rectangle())
        .onTapGesture {
            handleLineTap(file: file, anchorLine: row.anchorLine)
        }
    }

    private func backgroundColor(for kind: ReviewDiffLineKind) -> Color {
        switch kind {
        case .addition:
            return Color.green.opacity(0.14)
        case .deletion:
            return Color.red.opacity(0.14)
        case .context:
            return Color.clear
        }
    }

    private func handleLineTap(file: ReviewFileDiff, anchorLine: Int) {
        let isShiftHeld = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
        if isShiftHeld,
           var existing = composer,
           existing.filePath == file.id {
            existing.startLine = min(existing.anchorLine, anchorLine)
            existing.endLine = max(existing.anchorLine, anchorLine)
            composer = existing
        } else {
            composer = InlineComposerState(filePath: file.id, anchorLine: anchorLine, startLine: anchorLine, endLine: anchorLine)
        }
    }

    private func inlineComposer(_ state: InlineComposerState) -> some View {
        HStack(spacing: 6) {
            TextField(
                String(localized: "review.composer.placeholder", defaultValue: "Add a comment…"),
                text: Binding(
                    get: { composer?.text ?? state.text },
                    set: { newValue in
                        var updated = composer ?? state
                        updated.text = newValue
                        composer = updated
                    }
                )
            )
            .textFieldStyle(.plain)
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .background(Color.primary.opacity(0.06))
            .cornerRadius(4)
            .onSubmit { commitComposer() }

            Button(String(localized: "review.composer.add", defaultValue: "Add")) {
                commitComposer()
            }
            .disabled(state.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Button(String(localized: "review.composer.cancel", defaultValue: "Cancel")) {
                composer = nil
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    private func commitComposer() {
        guard let state = composer else { return }
        let trimmedText = state.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }
        panel.addComment(filePath: state.filePath, startLine: state.startLine, endLine: state.endLine, text: trimmedText)
        composer = nil
    }

    // MARK: - Pending comments

    private var pendingCommentsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Text(String(localized: "review.pendingComments.title", defaultValue: "Pending comments (\(panel.comments.count))"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)

            ForEach(panel.comments) { comment in
                pendingCommentRow(comment)
            }

            Button {
                sendComments()
            } label: {
                Text(String(localized: "review.sendToAgent.button", defaultValue: "Send to agent"))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func pendingCommentRow(_ comment: ReviewComment) -> some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text("\(comment.filePath):\(comment.startLine == comment.endLine ? "\(comment.startLine)" : "\(comment.startLine)-\(comment.endLine)")")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                    if comment.isStale {
                        Text(String(localized: "review.comment.stale", defaultValue: "line numbers may have shifted"))
                            .font(.system(size: 9))
                            .foregroundColor(.orange)
                    }
                }
                Text(comment.text)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
            Button {
                panel.removeComment(id: comment.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .safeHelp(String(localized: "review.comment.remove.help", defaultValue: "Remove comment"))
        }
        .padding(6)
        .background(Color.primary.opacity(0.04))
        .cornerRadius(4)
    }

    private func sendComments() {
        panel.sendPendingComments()
    }
}
