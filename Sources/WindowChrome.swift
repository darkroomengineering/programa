import AppKit
import ObjectiveC
import SwiftUI

/// Applies NSGlassEffectView (macOS 26+) to a window, falling back to NSVisualEffectView.
/// The glass path requires both a macOS 26 SDK at build time and macOS 26 at runtime.
enum WindowGlassEffect {
    private static var glassViewKey: UInt8 = 0
    private static var originalContentViewKey: UInt8 = 0
    private static var tintOverlayKey: UInt8 = 0

    static var isAvailable: Bool {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            return true
        }
        #endif
        return false
    }

    /// True when `view` is the native macOS 26 glass view.
    static func isGlassEffectView(_ view: NSView) -> Bool {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            return view is NSGlassEffectView
        }
        #endif
        return false
    }

    static func apply(to window: NSWindow, tintColor: NSColor? = nil) {
        guard let originalContentView = window.contentView else { return }

        // Check if we already applied glass (avoid re-wrapping)
        if let existingGlass = objc_getAssociatedObject(window, &glassViewKey) as? NSView {
            // Already applied, just update the tint
            updateTint(on: existingGlass, color: tintColor, window: window)
            return
        }

        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            applyGlass(to: window, originalContentView: originalContentView, tintColor: tintColor)
            return
        }
        #endif
        applyVisualEffectFallback(to: window, originalContentView: originalContentView, tintColor: tintColor)
    }

    #if compiler(>=6.2)
    @available(macOS 26.0, *)
    private static func applyGlass(to window: NSWindow, originalContentView: NSView, tintColor: NSColor?) {
        let glassView = NSGlassEffectView(frame: originalContentView.bounds)
        glassView.wantsLayer = true
        glassView.cornerRadius = 0
        glassView.tintColor = tintColor
        glassView.autoresizingMask = [.width, .height]

        // NSGlassEffectView is a full replacement for the contentView.
        objc_setAssociatedObject(window, &originalContentViewKey, originalContentView, .OBJC_ASSOCIATION_RETAIN)
        window.contentView = glassView

        // Re-add the original SwiftUI hosting view on top of the glass, filling entire area.
        // Kept as a manual subview (not NSGlassEffectView.contentView) so the window portal
        // installation code can rely on the subview hierarchy.
        originalContentView.translatesAutoresizingMaskIntoConstraints = false
        originalContentView.wantsLayer = true
        originalContentView.layer?.backgroundColor = NSColor.clear.cgColor
        glassView.addSubview(originalContentView)

        NSLayoutConstraint.activate([
            originalContentView.topAnchor.constraint(equalTo: glassView.topAnchor),
            originalContentView.bottomAnchor.constraint(equalTo: glassView.bottomAnchor),
            originalContentView.leadingAnchor.constraint(equalTo: glassView.leadingAnchor),
            originalContentView.trailingAnchor.constraint(equalTo: glassView.trailingAnchor)
        ])

        objc_setAssociatedObject(window, &glassViewKey, glassView, .OBJC_ASSOCIATION_RETAIN)
    }
    #endif

    private static func applyVisualEffectFallback(to window: NSWindow, originalContentView: NSView, tintColor: NSColor?) {
        let bounds = originalContentView.bounds
        let glassView = NSVisualEffectView(frame: bounds)
        glassView.blendingMode = .behindWindow
        // Favor a lighter fallback so behind-window glass reads more transparent.
        glassView.material = .underWindowBackground
        glassView.state = .active
        glassView.wantsLayer = true
        glassView.autoresizingMask = [.width, .height]

        // For the NSVisualEffectView fallback, do NOT replace window.contentView.
        // Replacing contentView can break traffic light rendering with
        // `.fullSizeContentView` + `titlebarAppearsTransparent`.
        glassView.translatesAutoresizingMaskIntoConstraints = false
        originalContentView.addSubview(glassView, positioned: .below, relativeTo: nil)

        NSLayoutConstraint.activate([
            glassView.topAnchor.constraint(equalTo: originalContentView.topAnchor),
            glassView.bottomAnchor.constraint(equalTo: originalContentView.bottomAnchor),
            glassView.leadingAnchor.constraint(equalTo: originalContentView.leadingAnchor),
            glassView.trailingAnchor.constraint(equalTo: originalContentView.trailingAnchor)
        ])

        // Add tint overlay between glass and content
        if let tintColor {
            let tintOverlay = NSView(frame: bounds)
            tintOverlay.translatesAutoresizingMaskIntoConstraints = false
            tintOverlay.wantsLayer = true
            tintOverlay.layer?.backgroundColor = tintColor.cgColor
            glassView.addSubview(tintOverlay)
            NSLayoutConstraint.activate([
                tintOverlay.topAnchor.constraint(equalTo: glassView.topAnchor),
                tintOverlay.bottomAnchor.constraint(equalTo: glassView.bottomAnchor),
                tintOverlay.leadingAnchor.constraint(equalTo: glassView.leadingAnchor),
                tintOverlay.trailingAnchor.constraint(equalTo: glassView.trailingAnchor)
            ])
            objc_setAssociatedObject(window, &tintOverlayKey, tintOverlay, .OBJC_ASSOCIATION_RETAIN)
        }

        objc_setAssociatedObject(window, &glassViewKey, glassView, .OBJC_ASSOCIATION_RETAIN)
    }

    /// Update the tint color on an existing glass effect
    static func updateTint(to window: NSWindow, color: NSColor?) {
        guard let glassView = objc_getAssociatedObject(window, &glassViewKey) as? NSView else { return }
        updateTint(on: glassView, color: color, window: window)
    }

    private static func updateTint(on glassView: NSView, color: NSColor?, window: NSWindow) {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *), let glass = glassView as? NSGlassEffectView {
            glass.tintColor = color
            return
        }
        #endif
        // For NSVisualEffectView fallback, update the tint overlay
        if let tintOverlay = objc_getAssociatedObject(window, &tintOverlayKey) as? NSView {
            tintOverlay.layer?.backgroundColor = color?.cgColor
        }
    }

    static func remove(from window: NSWindow) {
        guard let glassView = objc_getAssociatedObject(window, &glassViewKey) as? NSView else {
            return
        }

        if isGlassEffectView(glassView) {
            if let originalContentView = objc_getAssociatedObject(window, &originalContentViewKey) as? NSView {
                originalContentView.removeFromSuperview()
                originalContentView.translatesAutoresizingMaskIntoConstraints = true
                originalContentView.autoresizingMask = [.width, .height]
                originalContentView.frame = glassView.bounds
                window.contentView = originalContentView
            }
        } else {
            glassView.removeFromSuperview()
        }

        objc_setAssociatedObject(window, &glassViewKey, nil, .OBJC_ASSOCIATION_RETAIN)
        objc_setAssociatedObject(window, &originalContentViewKey, nil, .OBJC_ASSOCIATION_RETAIN)
        objc_setAssociatedObject(window, &tintOverlayKey, nil, .OBJC_ASSOCIATION_RETAIN)
    }
}

/// CALayer-backed titlebar background. Uses layer-level opacity (not per-pixel alpha)
/// to match how the terminal's Metal surface composites its background.
struct TitlebarLayerBackground: NSViewRepresentable {
    var backgroundColor: NSColor
    var opacity: CGFloat

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = backgroundColor.withAlphaComponent(1.0).cgColor
        view.layer?.opacity = Float(opacity)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.layer?.backgroundColor = backgroundColor.withAlphaComponent(1.0).cgColor
        nsView.layer?.opacity = Float(opacity)
    }
}
