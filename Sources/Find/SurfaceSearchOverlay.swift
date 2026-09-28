import AppKit
import Bonsplit
import SwiftUI

private extension NSView {
    func programaAncestor<T: NSView>(of type: T.Type) -> T? {
        var current: NSView? = self
        while let view = current {
            if let target = view as? T {
                return target
            }
            current = view.superview
        }
        return nil
    }
}

struct SurfaceSearchOverlay: View {
    let tabId: UUID
    let surfaceId: UUID
    @ObservedObject var searchState: TerminalSurface.SearchState
    let canApplyFocusRequest: () -> Bool
    let onMoveFocusToTerminal: () -> Void
    let onNavigateSearch: (_ action: String) -> Void
    let onFieldDidFocus: () -> Void
    let onClose: () -> Void
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
                accessibilityIdentifier: "TerminalFindSearchTextField",
                focusNotificationName: .ghosttySearchFocus,
                shouldApplyFocusNotification: { notification in
                    guard let surface = notification.object as? TerminalSurface else { return false }
                    return surface.id == surfaceId
                },
                canApplyFocusRequest: canApplyFocusRequest,
                focusSelection: .preserve,
                debugContext: "surface=\(surfaceId.uuidString.prefix(5))",
                onFieldDidFocus: onFieldDidFocus,
                onEscape: { field in
                    field.programaAncestor(of: GhosttySurfaceScrollView.self)?.beginFindEscapeSuppression()
                    #if DEBUG
                    dlog("find.nativeField.escape surface=\(surfaceId.uuidString.prefix(5)) needleEmpty=\(searchState.needle.isEmpty)")
                    #endif
                    if searchState.needle.isEmpty {
                        onClose()
                    } else {
                        onMoveFocusToTerminal()
                    }
                },
                onReturn: { isShift in
                    let action = isShift
                        ? "navigate_search:previous"
                        : "navigate_search:next"
                    onNavigateSearch(action)
                }
            )
            .accessibilityIdentifier("TerminalFindSearchTextField")
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
                    Text("-/\(total)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                        .padding(.trailing, 8)
                }
            }

            Button(action: {
                #if DEBUG
                dlog("findbar.next surface=\(surfaceId.uuidString.prefix(5))")
                #endif
                onNavigateSearch("navigate_search:next")
            }) {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(SearchButtonStyle())
            .safeHelp(String(localized: "search.nextMatch.help", defaultValue: "Next match (Return)"))

            Button(action: {
                #if DEBUG
                dlog("findbar.prev surface=\(surfaceId.uuidString.prefix(5))")
                #endif
                onNavigateSearch("navigate_search:previous")
            }) {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(SearchButtonStyle())
            .safeHelp(String(localized: "search.previousMatch.help", defaultValue: "Previous match (Shift+Return)"))

            Button(action: {
                #if DEBUG
                dlog("findbar.close surface=\(surfaceId.uuidString.prefix(5))")
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
            .onAppear {
                #if DEBUG
                dlog("find.overlay.appear tab=\(tabId.uuidString.prefix(5)) surface=\(surfaceId.uuidString.prefix(5))")
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

struct SearchButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isHovered || configuration.isPressed ? .primary : .secondary)
            .padding(.horizontal, 2)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(backgroundColor(isPressed: configuration.isPressed))
            )
            .onHover { hovering in
                isHovered = hovering
            }
            .backport.pointerStyle(.link)
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        if isPressed {
            return Color.primary.opacity(0.2)
        }
        if isHovered {
            return Color.primary.opacity(0.1)
        }
        return Color.clear
    }
}
