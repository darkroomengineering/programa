import SwiftUI
import AppKit
import Bonsplit

struct OmnibarSuggestionsView: View {
    let engineName: String
    let items: [OmnibarSuggestion]
    let selectedIndex: Int
    let isLoadingRemoteSuggestions: Bool
    let searchSuggestionsEnabled: Bool
    let onCommit: (OmnibarSuggestion) -> Void
    let onHighlight: (Int) -> Void
    @Environment(\.colorScheme) private var colorScheme

    // Keep radii below half of the smallest rendered heights so this keeps a
    // squircle silhouette instead of auto-clamping into a capsule.
    private let popupCornerRadius: CGFloat = 12
    private let rowHighlightCornerRadius: CGFloat = 9
    private let singleLineRowHeight: CGFloat = 24
    private let rowSpacing: CGFloat = 1
    private let topInset: CGFloat = 3
    private let bottomInset: CGFloat = 3
    private var horizontalInset: CGFloat { topInset }
    private let maxPopupHeight: CGFloat = 560

    private var totalRowCount: Int {
        max(1, items.count)
    }

    private func rowHeight(for item: OmnibarSuggestion) -> CGFloat {
        return singleLineRowHeight
    }

    private var contentHeight: CGFloat {
        let rowsHeight = items.isEmpty ? singleLineRowHeight : items.reduce(CGFloat(0)) { partial, item in
            partial + rowHeight(for: item)
        }
        let gaps = CGFloat(max(0, totalRowCount - 1))
        return rowsHeight + (gaps * rowSpacing) + topInset + bottomInset
    }

    private var minimumPopupHeight: CGFloat {
        singleLineRowHeight + topInset + bottomInset
    }

    private func snapToDevicePixels(_ value: CGFloat) -> CGFloat {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        return (value * scale).rounded(.toNearestOrAwayFromZero) / scale
    }

    private var popupHeight: CGFloat {
        snapToDevicePixels(min(max(contentHeight, minimumPopupHeight), maxPopupHeight))
    }

    private var isPointerDrivenSelectionEvent: Bool {
        guard let event = NSApp.currentEvent else { return false }
        switch event.type {
        case .mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp,
             .rightMouseDown, .rightMouseDragged, .rightMouseUp,
             .otherMouseDown, .otherMouseDragged, .otherMouseUp, .scrollWheel:
            return true
        default:
            return false
        }
    }

    private var shouldScroll: Bool {
        contentHeight > maxPopupHeight
    }

    private var listTextColor: Color {
        switch colorScheme {
        case .light:
            return Color(nsColor: .labelColor)
        case .dark:
            return Color.white.opacity(0.9)
        @unknown default:
            return Color(nsColor: .labelColor)
        }
    }

    private var badgeTextColor: Color {
        switch colorScheme {
        case .light:
            return Color(nsColor: .secondaryLabelColor)
        case .dark:
            return Color.white.opacity(0.72)
        @unknown default:
            return Color(nsColor: .secondaryLabelColor)
        }
    }

    private var badgeBackgroundColor: Color {
        switch colorScheme {
        case .light:
            return Color.black.opacity(0.06)
        case .dark:
            return Color.white.opacity(0.08)
        @unknown default:
            return Color.black.opacity(0.06)
        }
    }

    private var rowHighlightColor: Color {
        switch colorScheme {
        case .light:
            return Color.black.opacity(0.07)
        case .dark:
            return Color.white.opacity(0.12)
        @unknown default:
            return Color.black.opacity(0.07)
        }
    }

    private var popupOverlayGradientColors: [Color] {
        switch colorScheme {
        case .light:
            return [
                Color.white.opacity(0.55),
                Color.white.opacity(0.2),
            ]
        case .dark:
            return [
                Color.black.opacity(0.26),
                Color.black.opacity(0.14),
            ]
        @unknown default:
            return [
                Color.white.opacity(0.55),
                Color.white.opacity(0.2),
            ]
        }
    }

    private var popupBorderGradientColors: [Color] {
        switch colorScheme {
        case .light:
            return [
                Color.white.opacity(0.65),
                Color.black.opacity(0.12),
            ]
        case .dark:
            return [
                Color.white.opacity(0.22),
                Color.white.opacity(0.06),
            ]
        @unknown default:
            return [
                Color.white.opacity(0.65),
                Color.black.opacity(0.12),
            ]
        }
    }

    private var popupShadowColor: Color {
        switch colorScheme {
        case .light:
            return Color.black.opacity(0.18)
        case .dark:
            return Color.black.opacity(0.45)
        @unknown default:
            return Color.black.opacity(0.18)
        }
    }

    @ViewBuilder
    private var rowsView: some View {
        VStack(spacing: rowSpacing) {
            ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
            Button {
                #if DEBUG
                dlog("browser.suggestionClick index=\(idx) text=\"\(item.listText)\"")
                #endif
                onCommit(item)
            } label: {
                HStack(spacing: 6) {
                        Text(item.listText)
                            .font(.system(size: 11))
                            .foregroundStyle(listTextColor)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if let badge = item.trailingBadgeText {
                            Text(badge)
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(badgeTextColor)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(badgeBackgroundColor)
                                )
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: rowHeight(for: item),
                        maxHeight: rowHeight(for: item),
                        alignment: .leading
                    )
                    .background(
                        RoundedRectangle(cornerRadius: rowHighlightCornerRadius, style: .continuous)
                            .fill(
                                idx == selectedIndex
                                    ? rowHighlightColor
                                    : Color.clear
                            )
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("BrowserOmnibarSuggestions.Row.\(idx)")
                .accessibilityValue(
                    idx == selectedIndex
                        ? "selected \(item.listText)"
                        : item.listText
                )
                .onHover { hovering in
                    if hovering, idx != selectedIndex, isPointerDrivenSelectionEvent {
                        onHighlight(idx)
                    }
                }
                .animation(.none, value: selectedIndex)
            }

        }
        .padding(.horizontal, horizontalInset)
        .padding(.top, topInset)
        .padding(.bottom, bottomInset)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    var body: some View {
        Group {
            if shouldScroll {
                ScrollView {
                    rowsView
                }
            } else {
                rowsView
            }
        }
        .frame(height: popupHeight, alignment: .top)
        .overlay(alignment: .topTrailing) {
            if searchSuggestionsEnabled, isLoadingRemoteSuggestions {
                ProgressView()
                    .controlSize(.small)
                    .padding(.top, 7)
                    .padding(.trailing, 14)
                    .opacity(0.75)
                    .allowsHitTesting(false)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: popupCornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: popupCornerRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: popupOverlayGradientColors,
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: popupCornerRadius, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: popupBorderGradientColors,
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: popupCornerRadius, style: .continuous))
        .shadow(color: popupShadowColor, radius: 20, y: 10)
        .contentShape(RoundedRectangle(cornerRadius: popupCornerRadius, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityRespondsToUserInteraction(true)
        .accessibilityIdentifier("BrowserOmnibarSuggestions")
        .accessibilityLabel(String(localized: "browser.addressBarSuggestions", defaultValue: "Address bar suggestions"))
    }
}
