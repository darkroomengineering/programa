import AppKit
import SwiftUI

/// Renders a `:::compare` block (parsed by `MarkdownAlertParser` in
/// `MarkdownDocumentView.swift`) as two labeled code panes, "Before" and
/// "After". Uses `ViewThatFits` to lay the panes out side by side when the
/// panel is wide enough, falling back to a vertical stack when it isn't, so
/// narrow panels never truncate either pane.
struct MarkdownCompareView: View {
    let language: String
    let beforeCode: String
    let afterCode: String
    let isDark: Bool

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                pane(title: beforeTitle, code: beforeCode, tint: beforeTint)
                pane(title: afterTitle, code: afterCode, tint: afterTint)
            }
            VStack(alignment: .leading, spacing: 12) {
                pane(title: beforeTitle, code: beforeCode, tint: beforeTint)
                pane(title: afterTitle, code: afterCode, tint: afterTint)
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

    private var beforeTint: Color { Color(red: 0.89, green: 0.33, blue: 0.33) }
    private var afterTint: Color { Color(red: 0.26, green: 0.72, blue: 0.46) }

    @ViewBuilder
    private func pane(title: String, code: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(tint)
                if !language.isEmpty {
                    Text("(\(language))")
                        .font(.system(size: 11))
                        .foregroundColor(tint.opacity(0.7))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(isDark ? 0.16 : 0.1))

            ScrollView(.horizontal, showsIndicators: true) {
                Text(code)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(isDark ? Color(red: 0.9, green: 0.9, blue: 0.9) : Color(red: 0.2, green: 0.2, blue: 0.2))
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(isDark
                ? Color(nsColor: NSColor(white: 0.08, alpha: 1.0))
                : Color(nsColor: NSColor(white: 0.93, alpha: 1.0)))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(tint.opacity(isDark ? 0.3 : 0.2), lineWidth: 1)
        )
    }
}
