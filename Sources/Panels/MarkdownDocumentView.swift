import AppKit
import Foundation
import MarkdownUI
import SwiftUI

/// Renderer-neutral presentation values supplied by the panel container.
struct MarkdownDocumentPresentation {
    let colorScheme: ColorScheme

    var backgroundColor: Color {
        colorScheme == .dark
            ? Color(nsColor: NSColor(white: 0.12, alpha: 1.0))
            : Color(nsColor: NSColor(white: 0.98, alpha: 1.0))
    }
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
        case .caution: return "flame.fill"
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

    func tintColor(isDark: Bool) -> Color {
        switch self {
        case .note: return Color(red: 0.34, green: 0.55, blue: 0.98)
        case .tip: return Color(red: 0.26, green: 0.72, blue: 0.46)
        case .important: return Color(red: 0.64, green: 0.44, blue: 0.98)
        case .warning: return Color(red: 0.85, green: 0.63, blue: 0.13)
        case .caution: return Color(red: 0.89, green: 0.33, blue: 0.33)
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
/// as a colored, icon-labeled box instead of a plain blockquote. The alert
/// body is itself rendered as Markdown so inline formatting, links, and code
/// spans inside the alert keep working.
private struct MarkdownAlertCalloutView: View {
    let kind: MarkdownAlertKind
    let text: String
    let baseURL: URL?
    let isDark: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: kind.symbolName)
                .foregroundColor(kind.tintColor(isDark: isDark))
                .font(.system(size: 13, weight: .semibold))
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(kind.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(kind.tintColor(isDark: isDark))
                Markdown(text, baseURL: baseURL)
                    .markdownTextStyle {
                        ForegroundColor(isDark ? .white.opacity(0.85) : .primary)
                        FontSize(14)
                    }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(kind.tintColor(isDark: isDark).opacity(isDark ? 0.14 : 0.08))
        )
        .overlay(
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(kind.tintColor(isDark: isDark))
                    .frame(width: 3)
                Spacer()
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
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
                    FontSize(13)
                    ForegroundColor(isDark ? Color(red: 0.9, green: 0.9, blue: 0.9) : Color(red: 0.2, green: 0.2, blue: 0.2))
                }
                .padding(12)
        }
        .background(isDark
            ? Color(nsColor: NSColor(white: 0.08, alpha: 1.0))
            : Color(nsColor: NSColor(white: 0.93, alpha: 1.0)))
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
                ForegroundColor(isDark ? .white.opacity(0.9) : .primary)
                FontSize(14)
            }
            .heading1 { configuration in
                VStack(alignment: .leading, spacing: 8) {
                    configuration.label
                        .markdownTextStyle {
                            FontWeight(.bold)
                            FontSize(28)
                            ForegroundColor(isDark ? .white : .primary)
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
                            FontSize(22)
                            ForegroundColor(isDark ? .white : .primary)
                        }
                    Divider()
                }
                .markdownMargin(top: 20, bottom: 12)
            }
            .heading3 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(18)
                        ForegroundColor(isDark ? .white : .primary)
                    }
                    .markdownMargin(top: 16, bottom: 8)
            }
            .heading4 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(16)
                        ForegroundColor(isDark ? .white : .primary)
                    }
                    .markdownMargin(top: 12, bottom: 6)
            }
            .heading5 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontWeight(.medium)
                        FontSize(14)
                        ForegroundColor(isDark ? .white : .primary)
                    }
                    .markdownMargin(top: 10, bottom: 4)
            }
            .heading6 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontWeight(.medium)
                        FontSize(13)
                        ForegroundColor(isDark ? .white.opacity(0.7) : .secondary)
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
                FontSize(13)
                ForegroundColor(isDark ? Color(red: 0.85, green: 0.6, blue: 0.95) : Color(red: 0.6, green: 0.2, blue: 0.7))
                BackgroundColor(isDark
                    ? Color(nsColor: NSColor(white: 0.18, alpha: 1.0))
                    : Color(nsColor: NSColor(white: 0.92, alpha: 1.0)))
            }
            .blockquote { configuration in
                HStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(isDark ? Color.white.opacity(0.2) : Color.gray.opacity(0.4))
                        .frame(width: 3)
                    configuration.label
                        .markdownTextStyle {
                            ForegroundColor(isDark ? .white.opacity(0.6) : .secondary)
                            FontSize(14)
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
                    .markdownTableBorderStyle(.init(color: isDark ? .white.opacity(0.15) : .gray.opacity(0.3)))
                    .markdownTableBackgroundStyle(
                        .alternatingRows(
                            isDark
                                ? Color(nsColor: NSColor(white: 0.14, alpha: 1.0))
                                : Color(nsColor: NSColor(white: 0.96, alpha: 1.0)),
                            isDark
                                ? Color(nsColor: NSColor(white: 0.10, alpha: 1.0))
                                : Color(nsColor: NSColor(white: 1.0, alpha: 1.0))
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
