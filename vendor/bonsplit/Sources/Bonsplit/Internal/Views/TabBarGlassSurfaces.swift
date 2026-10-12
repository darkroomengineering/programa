import AppKit
import SwiftUI

enum TabBarGlassStyling {
    // Chrome spacing grid: 8pt above and below the 28pt pill row.
    static let verticalInset: CGFloat = 8
    static let barHeight: CGFloat = 28 + (verticalInset * 2)

    static var isAvailable: Bool {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            return true
        }
        #endif
        return false
    }
}

/// Hosts compact overlay content, such as a shortcut hint, inside native glass. The
/// actual tab controls never use this bridge; they are fully native AppKit controls above.
struct TabPillGlassHost<Content: View>: NSViewRepresentable {
    let content: Content
    let tintColor: NSColor?
    let cornerRadius: CGFloat

    final class Coordinator {
        let hostingView: NSHostingView<Content>

        init(content: Content) {
            hostingView = NSHostingView(rootView: content)
            hostingView.sizingOptions = [.intrinsicContentSize]
            hostingView.autoresizingMask = [.width, .height]
            hostingView.wantsLayer = true
            hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(content: content)
    }

    func makeNSView(context: Context) -> NSView {
        let hostingView = context.coordinator.hostingView
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: .zero)
            glass.autoresizingMask = [.width, .height]
            glass.style = .regular
            glass.cornerRadius = cornerRadius
            glass.tintColor = tintColor
            glass.contentView = hostingView
            return glass
        }
        #endif
        return hostingView
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.hostingView.rootView = content
        #if compiler(>=6.2)
        if #available(macOS 26.0, *), let glass = nsView as? NSGlassEffectView {
            glass.cornerRadius = cornerRadius
            glass.tintColor = tintColor
        }
        #endif
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        let fittingSize = context.coordinator.hostingView.fittingSize
        return CGSize(width: proposal.width ?? fittingSize.width, height: proposal.height ?? fittingSize.height)
    }
}
