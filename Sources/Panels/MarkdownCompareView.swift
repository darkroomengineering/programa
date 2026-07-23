import AppKit
import SwiftUI

/// Renders a `:::compare` block (parsed by `MarkdownAlertParser` in
/// `MarkdownDocumentView.swift`) as two labeled code panes, "Before" and
/// "After". Uses `ViewThatFits` to lay the panes out side by side when the
/// panel is wide enough, falling back to a vertical stack when it isn't, so
/// narrow panels never truncate either pane. Styled as a grouped-box native
/// pair rather than GitHub's red/green diff coloring: a neutral rounded
/// container per side, with only the header row lightly tinted.
struct MarkdownCompareView: View {
    let language: String
    let beforeCode: String
    let afterCode: String
    let isDark: Bool

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                pane(title: beforeTitle, code: beforeCode, headerTint: Color(nsColor: .systemRed))
                pane(title: afterTitle, code: afterCode, headerTint: Color(nsColor: .systemGreen))
            }
            VStack(alignment: .leading, spacing: 12) {
                pane(title: beforeTitle, code: beforeCode, headerTint: Color(nsColor: .systemRed))
                pane(title: afterTitle, code: afterCode, headerTint: Color(nsColor: .systemGreen))
            }
        }
        .padding(.vertical, 8)
    }

    private var beforeTitle: String {
        String(localized: "markdown.compare.before", defaultValue: "Before")
    }

    private var afterTitle: String {
        String(localized: "markdown.compare.after", defaultValue: "After")
    }

    @ViewBuilder
    private func pane(title: String, code: String, headerTint: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(.caption, weight: .semibold))
                    .foregroundColor(Color(nsColor: .secondaryLabelColor))
                if !language.isEmpty {
                    Text("(\(language))")
                        .font(.system(.caption2))
                        .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(headerTint.opacity(isDark ? 0.1 : 0.07))

            Divider()

            ScrollView(.horizontal, showsIndicators: true) {
                Text(code)
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(Color(nsColor: .labelColor))
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .underPageBackgroundColor))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }
}
