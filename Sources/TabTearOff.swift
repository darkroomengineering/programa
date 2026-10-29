import AppKit
import Bonsplit

/// Moves a pane tab into a new window when its drag ends outside every
/// Programa window. The surface is moved, never recreated, so its shell and
/// scrollback survive.
@MainActor
enum TabTearOff {
    /// Entry point for both tab-bar drag paths. A drag that ends with no
    /// accepted operation is either a drop outside every target or an
    /// Escape cancel; only a release outside every Programa window counts.
    static func handleDragEnded(bonsplitTabId: UUID, at screenPoint: NSPoint) {
#if DEBUG
        dlog(
            "tab.tearOff.dragEnded tab=\(bonsplitTabId.uuidString.prefix(5)) " +
            "point=\(Int(screenPoint.x)),\(Int(screenPoint.y)) buttons=\(NSEvent.pressedMouseButtons) " +
            "outside=\(isOutsideProgramaWindows(screenPoint) ? 1 : 0)"
        )
#endif
        // After Escape the user is usually still holding the button.
        guard NSEvent.pressedMouseButtons & 1 == 0,
              isOutsideProgramaWindows(screenPoint) else { return }
        // Window creation must not run inside the dragging-source callback
        // while AppKit is still tearing the session down.
        DispatchQueue.main.async {
            _ = tearOff(bonsplitTabId: bonsplitTabId, at: screenPoint)
        }
    }

    static func isOutsideProgramaWindows(_ screenPoint: NSPoint) -> Bool {
        !NSApp.windows.contains { $0.isVisible && $0.frame.contains(screenPoint) }
    }

    @discardableResult
    static func tearOff(bonsplitTabId: UUID, at screenPoint: NSPoint) -> UUID? {
        guard let app = AppDelegate.shared,
              let located = app.locateBonsplitSurface(tabId: bonsplitTabId) else { return nil }
        return tearOff(panelId: located.panelId, at: screenPoint)
    }

    /// Returns the new window's id, or nil when nothing moved. `focus` is false
    /// for socket callers, which must not steal the user's focus.
    @discardableResult
    static func tearOff(panelId: UUID, at screenPoint: NSPoint, focus: Bool = true) -> UUID? {
        guard let app = AppDelegate.shared,
              let source = app.locateSurface(surfaceId: panelId),
              let sourceWorkspace = source.tabManager.tabs.first(where: { $0.id == source.workspaceId }) else {
            return nil
        }
        // The last surface of the last window has nowhere better to go.
        if app.mainWindowContexts.count == 1,
           source.tabManager.tabs.count == 1,
           sourceWorkspace.panels.count == 1 {
#if DEBUG
            dlog("tab.tearOff.skip panel=\(panelId.uuidString.prefix(5)) reason=lastSurface")
#endif
            return nil
        }

        let windowId = app.createMainWindow(activates: focus)
        guard let manager = app.tabManagerFor(windowId: windowId),
              let workspaceId = manager.selectedTabId,
              let workspace = manager.tabs.first(where: { $0.id == workspaceId }) else {
            _ = app.closeMainWindow(windowId: windowId)
            return nil
        }
        if let window = app.mainWindow(for: windowId) {
            position(window, at: screenPoint)
        }
        let bootstrapPanelIds = Array(workspace.panels.keys)

        guard app.moveSurface(panelId: panelId, toWorkspace: workspaceId, focus: focus, focusWindow: focus) else {
#if DEBUG
            dlog("tab.tearOff.fail panel=\(panelId.uuidString.prefix(5)) reason=moveFailed")
#endif
            _ = app.closeMainWindow(windowId: windowId)
            return nil
        }
        // A new window arrives with its own terminal; the torn-off tab replaces it.
        for bootstrapPanelId in bootstrapPanelIds where bootstrapPanelId != panelId {
            _ = workspace.closePanel(bootstrapPanelId, force: true)
        }
        // The shell re-reports its title only at its next prompt; name the workspace now.
        if let title = workspace.panelTitles[panelId] {
            workspace.updatePanelTitle(panelId: panelId, title: title)
        }
#if DEBUG
        dlog(
            "tab.tearOff panel=\(panelId.uuidString.prefix(5)) window=\(windowId.uuidString.prefix(5)) " +
            "point=\(Int(screenPoint.x)),\(Int(screenPoint.y))"
        )
#endif
        return windowId
    }

    /// Puts the new window's tab strip under the release point, kept fully on
    /// the screen that contains it.
    private static func position(_ window: NSWindow, at screenPoint: NSPoint) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(screenPoint) })
                ?? window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        var frame = window.frame
        frame.size.width = min(frame.width, visible.width)
        frame.size.height = min(frame.height, visible.height)
        frame.origin.x = screenPoint.x - min(120, frame.width / 2)
        frame.origin.y = screenPoint.y + 20 - frame.height
        frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
        window.setFrame(frame, display: true)
    }
}
