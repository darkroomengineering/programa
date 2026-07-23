import AppKit
import Foundation
import MarkdownUI
import SwiftUI

/// Renderer-neutral presentation values supplied by the panel container.
struct MarkdownDocumentPresentation {
    let colorScheme: ColorScheme

    /// Follows the system text-surface color so the panel matches native
    /// app chrome in both light and dark mode instead of a fixed light
    /// background. `textBackgroundColor` is the same semantic surface
    /// AppKit text/document views use, so it reads correctly against the
    /// system appearance without any manual light/dark branching.
    var backgroundColor: Color {
        Color(nsColor: .textBackgroundColor)
    }
}

// MARK: - System text sizes

/// Point sizes resolved from macOS's Dynamic Type text styles, so headings
/// and body text track the user's system text-size preference the same way
/// `.system(.largeTitle)` etc. do in plain SwiftUI. MarkdownUI's `FontSize`
/// text style only accepts a raw point value or a relative multiplier, not a
/// `Font.TextStyle` directly, so this resolves the point size once via
/// `NSFont.preferredFont(forTextStyle:)` and feeds that into `FontSize`.
private enum SystemTextSize {
    static func points(_ style: NSFont.TextStyle) -> CGFloat {
        NSFont.preferredFont(forTextStyle: style).pointSize
    }

    static var largeTitle: CGFloat { points(.largeTitle) }
    static var title: CGFloat { points(.title1) }
    static var title2: CGFloat { points(.title2) }
    static var title3: CGFloat { points(.title3) }
    static var headline: CGFloat { points(.headline) }
    static var subheadline: CGFloat { points(.subheadline) }
    static var body: CGFloat { points(.body) }
    static var callout: CGFloat { points(.callout) }
}

// MARK: - GitHub-style alerts

/// GitHub-style alert kinds recognized in blockquotes: `> [!NOTE]`, `> [!TIP]`,
/// `> [!IMPORTANT]`, `> [!WARNING]`, `> [!CAUTION]`.
enum MarkdownAlertKind: String {
    case note = "NOTE"
    case tip = "TIP"
    case important = "IMPORTANT"
    case warning = "WARNING"
    case caution = "CAUTION"

    var symbolName: String {
        switch self {
        case .note: return "info.circle.fill"
        case .tip: return "lightbulb.fill"
        case .important: return "exclamationmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .caution: return "exclamationmark.octagon.fill"
        }
    }

    /// The reserved GFM alert keyword, title-cased for display. Not run
    /// through `String(localized:)`: this mirrors a fixed English marker
    /// from the markdown source itself (like a code fence's language tag),
    /// not free-form UI copy.
    var displayName: String {
        switch self {
        case .note: return "Note"
        case .tip: return "Tip"
        case .important: return "Important"
        case .warning: return "Warning"
        case .caution: return "Caution"
        }
    }

    /// Semantic macOS accent color per alert kind. These wrap dynamic
    /// `NSColor`s that already adapt between light and dark appearance, so
    /// no manual light/dark branching is needed here.
    var tintColor: Color {
        switch self {
        case .note: return Color(nsColor: .systemBlue)
        case .tip: return Color(nsColor: .systemGreen)
        case .important: return Color(nsColor: .systemPurple)
        case .warning: return Color(nsColor: .systemOrange)
        case .caution: return Color(nsColor: .systemRed)
        }
    }
}

/// A single top-level chunk of a document: plain Markdown handed to
/// MarkdownUI as-is, a recognized GitHub-style alert blockquote, or a
/// `:::compare` before/after code block, each rendered with a dedicated view.
enum MarkdownDocumentSegment {
    case markdown(String)
    case alert(kind: MarkdownAlertKind, body: String)
    case compare(language: String, before: String, after: String)
}

/// Splits raw Markdown source into segments, extracting GitHub-style alert
/// blockquotes (`> [!NOTE]` ...) so they render as styled callouts instead of
/// plain blockquotes. swift-markdown-ui 2.4.1 has no native GFM-alert support
/// and its `BlockquoteConfiguration` only exposes the rendered label (no raw
/// text), so alert detection happens here, on the raw source, before content
/// reaches MarkdownUI. Everything else passes through untouched.
enum MarkdownAlertParser {
    private static let markerPattern = try! NSRegularExpression(
        pattern: #"^\s{0,3}>\s?\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\]\s*$"#,
        options: [.caseInsensitive]
    )
    private static let quoteLinePattern = try! NSRegularExpression(
        pattern: #"^\s{0,3}>\s?(.*)$"#
    )
    private static let compareStartPattern = try! NSRegularExpression(
        pattern: #"^\s{0,3}:::compare\s*$"#,
        options: [.caseInsensitive]
    )
    private static let compareEndPattern = try! NSRegularExpression(
        pattern: #"^\s{0,3}:::\s*$"#
    )

    static func segments(from content: String) -> [MarkdownDocumentSegment] {
        let lines = content.components(separatedBy: "\n")
        var result: [MarkdownDocumentSegment] = []
        var plainBuffer: [String] = []

        func flushPlain() {
            guard !plainBuffer.isEmpty else { return }
            result.append(.markdown(plainBuffer.joined(separator: "\n")))
            plainBuffer.removeAll()
        }

        var index = 0
        while index < lines.count {
            let line = lines[index]
            if let kind = alertKind(in: line) {
                var bodyLines: [String] = []
                var cursor = index + 1
                while cursor < lines.count, let stripped = quoteContent(of: lines[cursor]) {
                    bodyLines.append(stripped)
                    cursor += 1
                }
                flushPlain()
                result.append(.alert(kind: kind, body: bodyLines.joined(separator: "\n")))
                index = cursor
            } else if isCompareStart(line) {
                var bodyLines: [String] = []
                var cursor = index + 1
                var foundEnd = false
                while cursor < lines.count {
                    if isCompareEnd(lines[cursor]) {
                        foundEnd = true
                        break
                    }
                    bodyLines.append(lines[cursor])
                    cursor += 1
                }
                if foundEnd, let segment = compareSegment(from: bodyLines) {
                    flushPlain()
                    result.append(segment)
                    index = cursor + 1
                } else {
                    // Malformed `:::compare` block (missing closing `:::`, or
                    // not exactly two fenced code blocks inside): degrade to
                    // plain text rather than dropping content.
                    plainBuffer.append(line)
                    index += 1
                }
            } else {
                plainBuffer.append(line)
                index += 1
            }
        }
        flushPlain()
        return result
    }

    private static func alertKind(in line: String) -> MarkdownAlertKind? {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = markerPattern.firstMatch(in: line, range: range),
              match.numberOfRanges > 1,
              let typeRange = Range(match.range(at: 1), in: line) else {
            return nil
        }
        return MarkdownAlertKind(rawValue: line[typeRange].uppercased())
    }

    private static func quoteContent(of line: String) -> String? {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = quoteLinePattern.firstMatch(in: line, range: range),
              match.numberOfRanges > 1,
              let contentRange = Range(match.range(at: 1), in: line) else {
            return nil
        }
        return String(line[contentRange])
    }

    private static func isCompareStart(_ line: String) -> Bool {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        return compareStartPattern.firstMatch(in: line, range: range) != nil
    }

    private static func isCompareEnd(_ line: String) -> Bool {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        return compareEndPattern.firstMatch(in: line, range: range) != nil
    }

    /// Parses the lines between `:::compare` and `:::` into a `.compare`
    /// segment. Expects exactly two fenced code blocks; each fence's info
    /// string is `<language> [before|after]` (e.g. ```swift before```). If a
    /// fence carries a `before`/`after` label, that decides its side;
    /// otherwise the first fence found is treated as "before" and the second
    /// as "after". Returns nil if the block does not contain exactly two
    /// fenced code blocks, so the caller can fall back to plain text.
    private static func compareSegment(from bodyLines: [String]) -> MarkdownDocumentSegment? {
        struct Fence {
            let language: String
            let label: String?
            let code: String
        }

        var fences: [Fence] = []
        var index = 0
        while index < bodyLines.count {
            let line = bodyLines[index]
            guard line.hasPrefix("```") else {
                index += 1
                continue
            }
            let info = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
            let tokens = info.split(separator: " ").map(String.init)
            let language = tokens.first ?? ""
            let label = tokens.dropFirst().first.map { $0.lowercased() }

            var codeLines: [String] = []
            var cursor = index + 1
            while cursor < bodyLines.count, !bodyLines[cursor].hasPrefix("```") {
                codeLines.append(bodyLines[cursor])
                cursor += 1
            }
            guard cursor < bodyLines.count else {
                // Unclosed fence inside the compare block.
                return nil
            }
            fences.append(Fence(language: language, label: label, code: codeLines.joined(separator: "\n")))
            index = cursor + 1
        }

        guard fences.count == 2 else { return nil }
        let before = fences.first(where: { $0.label == "before" }) ?? fences[0]
        let after = fences.first(where: { $0.label == "after" }) ?? fences[1]
        let language = !before.language.isEmpty ? before.language : after.language
        return .compare(language: language, before: before.code, after: after.code)
    }
}

/// A GitHub-style alert callout (`> [!NOTE]`, `> [!WARNING]`, etc.) rendered
/// as a native macOS callout: a tinted rounded container with a leading
/// accent bar and an SF Symbol, instead of GitHub's pastel web treatment.
/// The alert body is itself rendered as Markdown so inline formatting,
/// links, and code spans inside the alert keep working.
private struct MarkdownAlertCalloutView: View {
    let kind: MarkdownAlertKind
    let text: String
    let baseURL: URL?
    let isDark: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: kind.symbolName)
                .foregroundColor(kind.tintColor)
                .font(.system(size: SystemTextSize.callout, weight: .semibold))
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(kind.displayName)
                    .font(.system(size: SystemTextSize.callout, weight: .semibold))
                    .foregroundColor(kind.tintColor)
                Markdown(text, baseURL: baseURL)
                    .markdownTextStyle {
                        ForegroundColor(Color(nsColor: .labelColor))
                        FontSize(SystemTextSize.body)
                    }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(kind.tintColor.opacity(isDark ? 0.12 : 0.08))
        )
        .overlay(
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(kind.tintColor)
                    .frame(width: 3)
                Spacer()
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .padding(.vertical, 8)
    }
}

// MARK: - Code blocks

/// The default (non-Mermaid) code block presentation, extracted so it can
/// also be used as the graceful-degradation fallback for Mermaid blocks when
/// the bundled mermaid.js asset is unavailable.
struct MarkdownCodeBlockView: View {
    let configuration: CodeBlockConfiguration
    let isDark: Bool

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            configuration.label
                .markdownTextStyle {
                    FontFamilyVariant(.monospaced)
                    FontSize(SystemTextSize.body)
                    ForegroundColor(Color(nsColor: .labelColor))
                }
                .padding(12)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - MarkdownDocumentView

/// The full-document Markdown rendering boundary.
///
/// MarkdownUI types and styling stay private to this view so the panel and its
/// model remain independent of the concrete renderer.
struct MarkdownDocumentView: View {
    let content: String
    let baseURL: URL?
    let presentation: MarkdownDocumentPresentation

    private var segments: [MarkdownDocumentSegment] {
        MarkdownAlertParser.segments(from: content)
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .markdown(let text):
                    Markdown(text, baseURL: baseURL)
                        .markdownTheme(theme)
                        .textSelection(.enabled)
                case .alert(let kind, let text):
                    MarkdownAlertCalloutView(
                        kind: kind,
                        text: text,
                        baseURL: baseURL,
                        isDark: presentation.colorScheme == .dark
                    )
                case .compare(let language, let before, let after):
                    MarkdownCompareView(
                        language: language,
                        beforeCode: before,
                        afterCode: after,
                        isDark: presentation.colorScheme == .dark
                    )
                }
            }
        }
    }

    private var theme: Theme {
        let isDark = presentation.colorScheme == .dark

        return Theme()
            .text {
                ForegroundColor(Color(nsColor: .labelColor))
                FontSize(SystemTextSize.body)
            }
            .heading1 { configuration in
                VStack(alignment: .leading, spacing: 8) {
                    configuration.label
                        .markdownTextStyle {
                            FontWeight(.bold)
                            FontSize(SystemTextSize.largeTitle)
                            ForegroundColor(Color(nsColor: .labelColor))
                        }
                    Divider()
                }
                .markdownMargin(top: 24, bottom: 16)
            }
            .heading2 { configuration in
                VStack(alignment: .leading, spacing: 6) {
                    configuration.label
                        .markdownTextStyle {
                            FontWeight(.bold)
                            FontSize(SystemTextSize.title)
                            ForegroundColor(Color(nsColor: .labelColor))
                        }
                    Divider()
                }
                .markdownMargin(top: 20, bottom: 12)
            }
            .heading3 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(SystemTextSize.title2)
                        ForegroundColor(Color(nsColor: .labelColor))
                    }
                    .markdownMargin(top: 16, bottom: 8)
            }
            .heading4 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(SystemTextSize.title3)
                        ForegroundColor(Color(nsColor: .labelColor))
                    }
                    .markdownMargin(top: 12, bottom: 6)
            }
            .heading5 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontWeight(.medium)
                        FontSize(SystemTextSize.headline)
                        ForegroundColor(Color(nsColor: .labelColor))
                    }
                    .markdownMargin(top: 10, bottom: 4)
            }
            .heading6 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontWeight(.medium)
                        FontSize(SystemTextSize.subheadline)
                        ForegroundColor(Color(nsColor: .secondaryLabelColor))
                    }
                    .markdownMargin(top: 8, bottom: 4)
            }
            .codeBlock { configuration in
                Group {
                    if MermaidBlockView.isMermaidLanguage(configuration.language) {
                        MermaidBlockView(source: configuration.content, isDark: isDark)
                    } else {
                        MarkdownCodeBlockView(configuration: configuration, isDark: isDark)
                    }
                }
                .markdownMargin(top: 8, bottom: 8)
            }
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(SystemTextSize.callout)
                ForegroundColor(Color(nsColor: .systemPurple))
                BackgroundColor(Color(nsColor: .quaternaryLabelColor))
            }
            .blockquote { configuration in
                HStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color(nsColor: .separatorColor))
                        .frame(width: 3)
                    configuration.label
                        .markdownTextStyle {
                            ForegroundColor(Color(nsColor: .secondaryLabelColor))
                            FontSize(SystemTextSize.body)
                        }
                        .padding(.leading, 12)
                }
                .markdownMargin(top: 8, bottom: 8)
            }
            .link {
                ForegroundColor(Color.accentColor)
            }
            .strong {
                FontWeight(.semibold)
            }
            .table { configuration in
                configuration.label
                    .markdownTableBorderStyle(.init(color: Color(nsColor: .separatorColor)))
                    .markdownTableBackgroundStyle(
                        .alternatingRows(
                            Color(nsColor: .controlBackgroundColor).opacity(0.6),
                            Color.clear
                        )
                    )
                    .markdownMargin(top: 8, bottom: 8)
            }
            .thematicBreak {
                Divider()
                    .markdownMargin(top: 16, bottom: 16)
            }
            .listItem { configuration in
                configuration.label
                    .markdownMargin(top: 4, bottom: 4)
            }
            .paragraph { configuration in
                configuration.label
                    .markdownMargin(top: 4, bottom: 8)
            }
    }
}
