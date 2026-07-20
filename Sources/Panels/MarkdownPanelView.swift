import AppKit
import Bonsplit
import SwiftUI

/// SwiftUI view that presents a MarkdownPanel without depending on a concrete renderer.
struct MarkdownPanelView: View {
    @ObservedObject var panel: MarkdownPanel
    let isFocused: Bool
    let isVisibleInUI: Bool
    let portalPriority: Int
    let onRequestPanelFocus: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if panel.isFileUnavailable {
                fileUnavailableView
            } else {
                markdownContentView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(backgroundColor)
        .overlay {
            // Single-transaction keyframe sequence (PhaseAnimator, macOS 14+): see
            // BrowserPanelView's identical overlay for why this replaced a chained
            // asyncAfter+withAnimation sequence (SwiftUI could coalesce/interrupt it).
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
        .overlay {
            if isVisibleInUI {
                // Observe left-clicks without intercepting them so markdown text
                // selection and link activation continue to use the native path.
                MarkdownPointerObserver(onPointerDown: onRequestPanelFocus)
            }
        }
        .overlay(alignment: .top) {
            if let state = panel.searchState {
                MarkdownSearchOverlay(
                    panelId: panel.id,
                    searchState: state,
                    onNext: { panel.findNext() },
                    onPrevious: { panel.findPrevious() },
                    onClose: { panel.hideFind() }
                )
            }
        }
    }

    // MARK: - Content

    private var markdownContentView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // File path breadcrumb
                filePathHeader
                    .padding(.horizontal, 24)
                    .padding(.top, 16)
                    .padding(.bottom, 8)

                Divider()
                    .padding(.horizontal, 16)

                MarkdownDocumentView(
                    content: panel.content,
                    baseURL: URL(fileURLWithPath: panel.filePath).deletingLastPathComponent(),
                    presentation: markdownPresentation
                )
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
            }
        }
    }

    private var filePathHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.richtext")
                .symbolRasterSize(12)
                .foregroundColor(.secondary)
            Text(panel.filePath)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
    }

    private var fileUnavailableView: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.questionmark")
                .symbolRasterSize(40)
                .foregroundColor(.secondary)
            Text(String(localized: "markdown.fileUnavailable.title", defaultValue: "File unavailable"))
                .font(.headline)
                .foregroundColor(.primary)
            Text(panel.filePath)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)
            Text(String(localized: "markdown.fileUnavailable.message", defaultValue: "The file may have been moved or deleted."))
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var markdownPresentation: MarkdownDocumentPresentation {
        MarkdownDocumentPresentation(colorScheme: colorScheme)
    }

    private var backgroundColor: Color {
        markdownPresentation.backgroundColor
    }
}

// MARK: - MarkdownSearchOverlay

/// Find bar overlay for MarkdownPanelView. Mirrors BrowserSearchOverlay's visual style
/// and drag-to-corner behaviour, but uses a SwiftUI TextField since markdown panels
/// have no webview focus concerns.
struct MarkdownSearchOverlay: View {
    let panelId: UUID
    @ObservedObject var searchState: MarkdownSearchState
    let onNext: () -> Void
    let onPrevious: () -> Void
    let onClose: () -> Void

    @FocusState private var isSearchFieldFocused: Bool
    @State private var corner: Corner = .topRight
    @State private var dragOffset: CGSize = .zero
    @State private var barSize: CGSize = .zero

    private let padding: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 4) {
                TextField(
                    String(localized: "search.placeholder", defaultValue: "Search"),
                    text: $searchState.needle
                )
                .focused($isSearchFieldFocused)
                .textFieldStyle(.plain)
                .frame(width: 180)
                .padding(.leading, 8)
                .padding(.trailing, 50)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.1))
                .cornerRadius(6)
                .overlay(alignment: .trailing) {
                    counterView
                }
                .onSubmit {
                    let isShift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
                    if isShift {
                        onPrevious()
                    } else {
                        onNext()
                    }
                }
                .onExitCommand {
                    onClose()
                }

                Button(action: {
#if DEBUG
                    dlog("markdown.findbar.next panel=\(panelId.uuidString.prefix(5))")
#endif
                    onNext()
                }) {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(SearchButtonStyle())
                .safeHelp(String(localized: "search.nextMatch.help", defaultValue: "Next match (Return)"))

                Button(action: {
#if DEBUG
                    dlog("markdown.findbar.prev panel=\(panelId.uuidString.prefix(5))")
#endif
                    onPrevious()
                }) {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(SearchButtonStyle())
                .safeHelp(String(localized: "search.previousMatch.help", defaultValue: "Previous match (Shift+Return)"))

                Button(action: {
#if DEBUG
                    dlog("markdown.findbar.close panel=\(panelId.uuidString.prefix(5))")
#endif
                    onClose()
                }) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(SearchButtonStyle())
                .safeHelp(String(localized: "search.close.help", defaultValue: "Close (Esc)"))
            }
            .padding(8)
            .background(.background)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .shadow(radius: 4)
            .onAppear {
#if DEBUG
                dlog("markdown.findbar.appear panel=\(panelId.uuidString.prefix(5))")
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
                        withAnimation(.easeOut(duration: 0.2)) {
                            corner = closestCorner(to: newCenter, in: geo.size)
                            dragOffset = .zero
                        }
                    }
            )
        }
    }

    @ViewBuilder
    private var counterView: some View {
        if let currentIndex = searchState.currentIndex {
            Text("\(currentIndex + 1)/\(searchState.matches.count)")
                .font(.caption)
                .foregroundColor(.secondary)
                .monospacedDigit()
                .padding(.trailing, 8)
        } else if !searchState.needle.isEmpty {
            Text("0/0")
                .font(.caption)
                .foregroundColor(.secondary)
                .monospacedDigit()
                .padding(.trailing, 8)
        }
    }

    // MARK: - Corner drag helpers (mirrors BrowserSearchOverlay)

    enum Corner {
        case topLeft, topRight, bottomLeft, bottomRight

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
        case .topLeft:    return CGPoint(x: halfWidth, y: halfHeight)
        case .topRight:   return CGPoint(x: containerSize.width - halfWidth, y: halfHeight)
        case .bottomLeft: return CGPoint(x: halfWidth, y: containerSize.height - halfHeight)
        case .bottomRight: return CGPoint(x: containerSize.width - halfWidth, y: containerSize.height - halfHeight)
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

// MARK: - MarkdownPointerObserver

private struct MarkdownPointerObserver: NSViewRepresentable {
    let onPointerDown: () -> Void

    func makeNSView(context: Context) -> MarkdownPanelPointerObserverView {
        let view = MarkdownPanelPointerObserverView()
        view.onPointerDown = onPointerDown
        return view
    }

    func updateNSView(_ nsView: MarkdownPanelPointerObserverView, context: Context) {
        nsView.onPointerDown = onPointerDown
    }
}

final class MarkdownPanelPointerObserverView: NSView {
    var onPointerDown: (() -> Void)?
    private var eventMonitor: Any?
    private weak var forwardedMouseTarget: NSView?

    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        installEventMonitorIfNeeded()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard PaneFirstClickFocusSettings.isEnabled(),
              window?.isKeyWindow != true,
              bounds.contains(point) else { return nil }
        return self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        PaneFirstClickFocusSettings.isEnabled()
    }

    override func mouseDown(with event: NSEvent) {
        onPointerDown?()
        forwardedMouseTarget = forwardedTarget(for: event)
        forwardedMouseTarget?.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        forwardedMouseTarget?.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        forwardedMouseTarget?.mouseUp(with: event)
        forwardedMouseTarget = nil
    }

    func shouldHandle(_ event: NSEvent) -> Bool {
        guard event.type == .leftMouseDown,
              let window,
              event.window === window,
              !isHiddenOrHasHiddenAncestor else { return false }
        if PaneFirstClickFocusSettings.isEnabled(), window.isKeyWindow != true {
            return false
        }
        let point = convert(event.locationInWindow, from: nil)
        return bounds.contains(point)
    }

    func handleEventIfNeeded(_ event: NSEvent) -> NSEvent {
        guard shouldHandle(event) else { return event }
        DispatchQueue.main.async { [weak self] in
            self?.onPointerDown?()
        }
        return event
    }

    private func installEventMonitorIfNeeded() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            self?.handleEventIfNeeded(event) ?? event
        }
    }

    private func forwardedTarget(for event: NSEvent) -> NSView? {
        guard let window else {
#if DEBUG
            NSLog("MarkdownPanelPointerObserverView.forwardedTarget skipped, window=0 contentView=0")
#endif
            return nil
        }
        guard let contentView = window.contentView else {
#if DEBUG
            NSLog("MarkdownPanelPointerObserverView.forwardedTarget skipped, window=1 contentView=0")
#endif
            return nil
        }
        isHidden = true
        defer { isHidden = false }
        let point = contentView.convert(event.locationInWindow, from: nil)
        let target = contentView.hitTest(point)
        return target === self ? nil : target
    }
}
