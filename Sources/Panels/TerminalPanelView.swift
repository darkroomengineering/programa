import SwiftUI
import Foundation
import AppKit
import Bonsplit

/// View for rendering a terminal panel
struct TerminalPanelView: View {
    @ObservedObject var panel: TerminalPanel
    // Observed separately from `panel` so SwiftUI re-renders when the underlying
    // TerminalSurface's `@Published isSurfaceReady` flips, driving the loading overlay below.
    @ObservedObject private var surface: TerminalSurface
    let paneId: PaneID
    let isFocused: Bool
    let isVisibleInUI: Bool
    let portalPriority: Int
    let isSplit: Bool
    let appearance: PanelAppearance
    let hasUnreadNotification: Bool
    let onFocus: () -> Void
    let onTriggerFlash: () -> Void

    @MainActor
    init(
        panel: TerminalPanel,
        paneId: PaneID,
        isFocused: Bool,
        isVisibleInUI: Bool,
        portalPriority: Int,
        isSplit: Bool,
        appearance: PanelAppearance,
        hasUnreadNotification: Bool,
        onFocus: @escaping () -> Void,
        onTriggerFlash: @escaping () -> Void
    ) {
        self.panel = panel
        self._surface = ObservedObject(wrappedValue: panel.surface)
        self.paneId = paneId
        self.isFocused = isFocused
        self.isVisibleInUI = isVisibleInUI
        self.portalPriority = portalPriority
        self.isSplit = isSplit
        self.appearance = appearance
        self.hasUnreadNotification = hasUnreadNotification
        self.onFocus = onFocus
        self.onTriggerFlash = onTriggerFlash
    }

    var body: some View {
        // Layering contract: terminal find UI is mounted in GhosttySurfaceScrollView (AppKit portal layer)
        // via `searchState`. Rendering `SurfaceSearchOverlay` in this SwiftUI container can hide it.
        GhosttyTerminalView(
            terminalSurface: panel.surface,
            paneId: paneId,
            isActive: isFocused,
            isVisibleInUI: isVisibleInUI,
            portalZPriority: portalPriority,
            showsInactiveOverlay: isSplit && !isFocused,
            showsUnreadNotificationRing: hasUnreadNotification,
            inactiveOverlayColor: appearance.unfocusedOverlayNSColor,
            inactiveOverlayOpacity: appearance.unfocusedOverlayOpacity,
            searchState: panel.searchState,
            reattachToken: panel.viewReattachToken,
            onFocus: { _ in onFocus() },
            onTriggerFlash: onTriggerFlash
        )
        // Keep the NSViewRepresentable identity stable across bonsplit structural updates.
        // This prevents transient teardown/recreate that can momentarily detach the hosted terminal view.
        .id(panel.id)
        .background(Color.clear)
        .overlay {
            // Purely visual: never intercepts events, and the one-shot `isSurfaceReady` flag
            // is not read from any keystroke-hot path (forceRefresh/hitTest).
            if !surface.isSurfaceReady {
                ProgressView()
                    .controlSize(.small)
                    .allowsHitTesting(false)
            }
        }
    }
}

/// Shared appearance settings for panels
struct PanelAppearance {
    let dividerColor: Color
    let unfocusedOverlayNSColor: NSColor
    let unfocusedOverlayOpacity: Double

    static func fromConfig(_ config: GhosttyConfig) -> PanelAppearance {
        PanelAppearance(
            dividerColor: Color(nsColor: config.resolvedSplitDividerColor),
            unfocusedOverlayNSColor: config.unfocusedSplitOverlayFill,
            unfocusedOverlayOpacity: config.unfocusedSplitOverlayOpacity
        )
    }
}
