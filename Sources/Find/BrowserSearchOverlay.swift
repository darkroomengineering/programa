import AppKit
import Bonsplit
import SwiftUI

struct BrowserSearchOverlay: View {
    let panelId: UUID
    let browserColorScheme: ColorScheme
    @ObservedObject var searchState: BrowserSearchState
    let focusRequestGeneration: UInt64
    let canApplyFocusRequest: (UInt64) -> Bool
    let onNext: () -> Void
    let onPrevious: () -> Void
    let onClose: () -> Void
    let onFieldDidFocus: () -> Void
    @State private var corner: Corner = .topRight
    @State private var dragOffset: CGSize = .zero
    @State private var barSize: CGSize = .zero
    @State private var isSearchFieldFocused: Bool = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(ProgramaGlassSettings.overlaysEnabledKey)
    private var overlayLiquidGlassEnabled = false

    private let padding: CGFloat = 8

    private var usesNativeOverlayGlass: Bool {
        WindowGlassEffect.isAvailable && ProgramaGlassSettings.resolvedEnabled(
            for: .overlays,
            persistedValue: overlayLiquidGlassEnabled
        )
    }

    private var searchControls: some View {
        HStack(spacing: 4) {
            SearchTextFieldHost(
                text: $searchState.needle,
                isFocused: $isSearchFieldFocused,
                accessibilityIdentifier: "BrowserFindSearchTextField",
                focusNotificationName: .browserSearchFocus,
                shouldApplyFocusNotification: { notification in
                    guard let notifiedPanelId = notification.object as? UUID else { return false }
                    return notifiedPanelId == panelId
                },
                canApplyFocusRequest: {
                    canApplyFocusRequest(focusRequestGeneration)
                },
                focusSelection: .caretAtEnd,
                debugContext: nil,
                onFieldDidFocus: onFieldDidFocus,
                onEscape: { _ in onClose() },
                onReturn: { isShift in
                    if isShift {
                        onPrevious()
                    } else {
                        onNext()
                    }
                }
            )
                .frame(width: 180)
                .padding(.leading, 8)
                .padding(.trailing, 50)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.1))
                .cornerRadius(6)
                .overlay(alignment: .trailing) {
                if let selected = searchState.selected {
                    let totalText = searchState.total.map { String($0) } ?? "?"
                    Text("\(selected + 1)/\(totalText)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                        .padding(.trailing, 8)
                } else if let total = searchState.total {
                    Text(total == 0 ? "0/0" : "-/\(total)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                        .padding(.trailing, 8)
                }
            }
            Button(action: {
                #if DEBUG
                dlog("browser.findbar.next panel=\(panelId.uuidString.prefix(5))")
                #endif
                onNext()
            }) {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(SearchButtonStyle())
            .safeHelp(String(localized: "search.nextMatch.help", defaultValue: "Next match (Return)"))

            Button(action: {
                #if DEBUG
                dlog("browser.findbar.prev panel=\(panelId.uuidString.prefix(5))")
                #endif
                onPrevious()
            }) {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(SearchButtonStyle())
            .safeHelp(String(localized: "search.previousMatch.help", defaultValue: "Previous match (Shift+Return)"))

            Button(action: {
                #if DEBUG
                dlog("browser.findbar.close panel=\(panelId.uuidString.prefix(5))")
                #endif
                onClose()
            }) {
                Image(systemName: "xmark")
            }
            .buttonStyle(SearchButtonStyle())
            .safeHelp(String(localized: "search.close.help", defaultValue: "Close (Esc)"))
        }
        .padding(8)
    }

    @ViewBuilder
    private var searchBarSurface: some View {
        if usesNativeOverlayGlass {
            ProgramaNativeGlassContentHost(
                content: searchControls,
                tintColor: nil,
                cornerRadius: 8
            )
            .fixedSize(horizontal: true, vertical: true)
            .shadow(radius: 4)
        } else {
            searchControls
                .background(.background)
                .clipShape(clipShape)
                .shadow(radius: 4)
        }
    }

    var body: some View {
        GeometryReader { geo in
            searchBarSurface
            .environment(\.colorScheme, browserColorScheme)
            .onAppear {
#if DEBUG
                dlog("browser.findbar.appear panel=\(panelId.uuidString.prefix(5))")
#endif
                isSearchFieldFocused = true
            }
            .background(
                GeometryReader { barGeo in
                    Color.clear.onAppear {
                        barSize = barGeo.size
                    }
                }
            )
            .padding(padding)
            .offset(dragOffset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: corner.alignment)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        dragOffset = value.translation
                    }
                    .onEnded { value in
                        let centerPos = centerPosition(for: corner, in: geo.size, barSize: barSize)
                        let newCenter = CGPoint(
                            x: centerPos.x + value.translation.width,
                            y: centerPos.y + value.translation.height
                        )
                        let newCorner = closestCorner(to: newCenter, in: geo.size)
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                            corner = newCorner
                            dragOffset = .zero
                        }
                    }
            )
        }
    }

    private var clipShape: some Shape {
        RoundedRectangle(cornerRadius: 8)
    }

    enum Corner {
        case topLeft
        case topRight
        case bottomLeft
        case bottomRight

        var alignment: Alignment {
            switch self {
            case .topLeft: return .topLeading
            case .topRight: return .topTrailing
            case .bottomLeft: return .bottomLeading
            case .bottomRight: return .bottomTrailing
            }
        }
    }

    private func centerPosition(for corner: Corner, in containerSize: CGSize, barSize: CGSize) -> CGPoint {
        let halfWidth = barSize.width / 2 + padding
        let halfHeight = barSize.height / 2 + padding

        switch corner {
        case .topLeft:
            return CGPoint(x: halfWidth, y: halfHeight)
        case .topRight:
            return CGPoint(x: containerSize.width - halfWidth, y: halfHeight)
        case .bottomLeft:
            return CGPoint(x: halfWidth, y: containerSize.height - halfHeight)
        case .bottomRight:
            return CGPoint(x: containerSize.width - halfWidth, y: containerSize.height - halfHeight)
        }
    }

    private func closestCorner(to point: CGPoint, in containerSize: CGSize) -> Corner {
        let midX = containerSize.width / 2
        let midY = containerSize.height / 2

        if point.x < midX {
            return point.y < midY ? .topLeft : .bottomLeft
        }
        return point.y < midY ? .topRight : .bottomRight
    }
}
