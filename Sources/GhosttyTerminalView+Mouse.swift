import Foundation
import SwiftUI
import AppKit
import Metal
import QuartzCore
import Combine
import CoreText
import Darwin
import Carbon.HIToolbox
import Bonsplit
import IOSurface
import UniformTypeIdentifiers

// MARK: - GhosttyNSView + Mouse
//
// Mouse handling for GhosttyNSView: cmd-click path hover, mouse
// down/dragged/up, scroll wheel, and tracking-area maintenance.
//
// Split out of GhosttyTerminalView.swift (Nuclear Review TC5). Moving these
// methods into a same-type extension adds zero call-site indirection.
// Method bodies are moved verbatim. deinit and windowDidChangeScreen stay
// on the primary class declaration (deinit cannot live in an extension).

extension GhosttyNSView {
    // MARK: - Mouse Handling

    #if DEBUG
    func debugModifierString(_ flags: NSEvent.ModifierFlags) -> String {
        [
            flags.contains(.command) ? "cmd" : nil,
            flags.contains(.shift) ? "shift" : nil,
            flags.contains(.control) ? "ctrl" : nil,
            flags.contains(.option) ? "opt" : nil,
        ].compactMap { $0 }.joined(separator: "+")
    }

    func runtimeDebugLog(
        hypothesisID: String,
        name: String,
        expected: String? = nil,
        actual: String? = nil,
        data: [String: Any] = [:]
    ) {
        var payload = data
        payload["surface_id"] = terminalSurface?.id.uuidString ?? "nil"
        payload["word_path_hover_active"] = wordPathHoverActive
        ProgramaRuntimeDebugCapture.logIfConfigured(
            hypothesisID: hypothesisID,
            source: "GhosttyNSView.\(name)",
            name: name,
            expected: expected,
            actual: actual,
            data: payload
        )
    }

    private func runtimeDebugResolutionPayload(_ resolution: WordPathResolution?) -> [String: Any] {
        guard let resolution else {
            return [
                "resolution_source": "none",
                "resolved_path_basename": "",
                "raw_token": ""
            ]
        }

        return [
            "resolution_source": resolution.source.rawValue,
            "resolved_path_basename": URL(fileURLWithPath: resolution.path).lastPathComponent,
            "raw_token": resolution.rawToken
        ]
    }
    #endif

    private func requestPointerFocusRecovery() {
#if DEBUG
        dlog("focus.pointerDown surface=\(terminalSurface?.id.uuidString.prefix(5) ?? "nil")")
#endif
        onFocus?()
    }

    override func mouseDown(with event: NSEvent) {
        #if DEBUG
        let debugPoint = convert(event.locationInWindow, from: nil)
        dlog("terminal.mouseDown surface=\(terminalSurface?.id.uuidString.prefix(5) ?? "nil") mods=[\(debugModifierString(event.modifierFlags))] clickCount=\(event.clickCount) point=(\(String(format: "%.0f", debugPoint.x)),\(String(format: "%.0f", debugPoint.y)))")
        #endif
        // Split reparent/layout churn can suppress the later `becomeFirstResponder -> onFocus`
        // callback. Treat pointer-down as explicit focus intent so clicking a ghost pane still
        // repairs workspace/pane active state before key routing runs.
        requestPointerFocusRecovery()
        window?.makeFirstResponder(self)
        if let terminalSurface {
            AppDelegate.shared?.tabManager?.dismissNotificationOnDirectInteraction(
                tabId: terminalSurface.tabId,
                surfaceId: terminalSurface.id
            )
        }
        guard let surface = surface else { return }
        let eventPoint = convert(event.locationInWindow, from: nil)
        trackMousePointIfUsable(eventPoint)
        let point = preferredPointerPoint(from: eventPoint) ?? eventPoint
        // Only update mouse position on the first click to prevent unwanted cursor
        // movement during double-click selection (issue #1698)
        if event.clickCount == 1 {
            ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, modsFromEvent(event))
        }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, modsFromEvent(event))
    }

    override func mouseUp(with event: NSEvent) {
        #if DEBUG
        dlog("terminal.mouseUp surface=\(terminalSurface?.id.uuidString.prefix(5) ?? "nil") mods=[\(debugModifierString(event.modifierFlags))]")
        #endif
        guard let surface = surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        let consumed = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, modsFromEvent(event))
        _ = handleCommandClickRelease(at: point, modifierFlags: event.modifierFlags, ghosttyConsumed: consumed)
    }

    /// Attempt to open the word under the mouse cursor as a file path, resolved
    /// against the terminal panel's current working directory.
    private func tryOpenWordAsPath(at point: NSPoint? = nil) {
        guard let resolution = resolveWordUnderCursorPath(at: point) else { return }

        #if DEBUG
        dlog("link.wordFallback resolved=\(resolution.path) source=\(resolution.source.rawValue)")
        #endif

        PreferredEditorSettings.open(URL(fileURLWithPath: resolution.path))
    }

    /// Check if the word under the mouse cursor resolves to an existing file/directory
    /// in the terminal panel's CWD. Returns the resolved absolute path, or nil.
    private func resolveWordUnderCursorAsPath(at point: NSPoint? = nil) -> String? {
        resolveWordUnderCursorPath(at: point)?.path
    }

    private func resolveWordUnderCursorPath(at point: NSPoint? = nil) -> WordPathResolution? {
        guard let surface = surface else { return nil }

        guard let termSurface = terminalSurface,
              let workspace = termSurface.owningWorkspace(),
              !workspace.isRemoteTerminalSurface(termSurface.id) else { return nil }

        guard let cwd = resolvedWordPathWorkingDirectory(workspace: workspace, terminalSurface: termSurface) else {
            return nil
        }

        let snapshotPoint = preferredPointerPoint(from: point)
        let pointSnapshotResolution = snapshotPoint.flatMap {
            resolveVisibleWordPath(
                at: $0,
                cwd: cwd,
                workspace: workspace,
                terminalSurface: termSurface
            )
        }

        var text = ghostty_text_s()
        if ghostty_surface_quicklook_word(surface, &text) {
            defer { ghostty_surface_free_text(surface, &text) }
            var quicklookResolution: WordPathResolution?
            if text.text_len > 0, let ptr = text.text {
                let wordData = Data(bytes: ptr, count: Int(text.text_len))
                if let decodedWord = String(bytes: wordData, encoding: .utf8) {
#if DEBUG
                    let resolvedQuicklookWord = programaTerminalCmdClickQuicklookOverride(decodedWord)
#else
                    let resolvedQuicklookWord = decodedWord
#endif
                    if let resolvedPath = programaResolveQuicklookPath(resolvedQuicklookWord, cwd: cwd) {
                        quicklookResolution = makeWordPathResolution(
                            path: resolvedPath,
                            source: .quicklook,
                            rawToken: resolvedQuicklookWord
                        )
                    }
                }
            }

            var viewportResolution: WordPathResolution?
            if text.offset_len > 0 {
#if DEBUG
                let viewportOffsetStart = programaTerminalCmdClickViewportOffsetDelta(Int(text.offset_start))
#else
                let viewportOffsetStart = Int(text.offset_start)
#endif
                viewportResolution = resolveVisibleWordPathFromViewportOffset(
                    viewportOffsetStart,
                    cwd: cwd,
                    workspace: workspace,
                    terminalSurface: termSurface
                )
            }

            if let viewportResolution {
                // The pointer-anchored snapshot is the only source tied directly to the
                // actual click location. Prefer it over quicklook and viewport offsets,
                // which can lag or target a sibling entry in multi-column `ls` output.
                if let pointSnapshotResolution {
                    return pointSnapshotResolution
                }
                return viewportResolution
            }

            if let pointSnapshotResolution {
                return pointSnapshotResolution
            }

            if let quicklookResolution {
                return quicklookResolution
            }
        }

        return pointSnapshotResolution
    }

    #if DEBUG
    private func programaTerminalCmdClickQuicklookOverride(_ decodedWord: String) -> String {
        let env = ProcessInfo.processInfo.environment
        guard let override = env["PROGRAMA_UI_TEST_TERMINAL_CMD_CLICK_QUICKLOOK_OVERRIDE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !override.isEmpty else {
            return decodedWord
        }
        return override
    }

    private func programaTerminalCmdClickViewportOffsetDelta(_ viewportOffsetStart: Int) -> Int {
        let env = ProcessInfo.processInfo.environment
        guard let delta = env["PROGRAMA_UI_TEST_TERMINAL_CMD_CLICK_VIEWPORT_OFFSET_DELTA"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let parsedDelta = Int(delta) else {
            return viewportOffsetStart
        }
        return max(0, viewportOffsetStart + parsedDelta)
    }
    #endif

    /// Update the pointing-hand cursor when Cmd-hovering over a bare filename
    /// that exists in the terminal's CWD.
    func updateWordPathHover(
        at point: NSPoint? = nil,
        cmdHeld: Bool,
        suppressPathHover: Bool = false
    ) {
        let hoverWasActive = wordPathHoverActive
        guard cmdHeld, !suppressPathHover else {
            if wordPathHoverActive {
                wordPathHoverActive = false
                NSCursor.pop()
            }
#if DEBUG
            if cmdHeld || suppressPathHover || hoverWasActive {
                runtimeDebugLog(
                    hypothesisID: "h1",
                    name: "hover_update",
                    expected: "cmd-hover off while selection is active",
                    actual: suppressPathHover ? "suppressed" : "inactive",
                    data: [
                        "cmd_held": cmdHeld,
                        "suppress_path_hover": suppressPathHover,
                        "hover_active_before": hoverWasActive,
                        "hover_active_after": wordPathHoverActive
                    ]
                )
            }
#endif
            return
        }

        let resolution = resolveWordUnderCursorPath(at: point)
        if resolution != nil {
            if !wordPathHoverActive {
                wordPathHoverActive = true
                NSCursor.pointingHand.push()
            }
        } else if wordPathHoverActive {
            wordPathHoverActive = false
            NSCursor.pop()
        }
#if DEBUG
        if cmdHeld || hoverWasActive || wordPathHoverActive || resolution != nil {
            var payload: [String: Any] = [
                "cmd_held": cmdHeld,
                "suppress_path_hover": suppressPathHover,
                "hover_active_before": hoverWasActive,
                "hover_active_after": wordPathHoverActive
            ]
            for (key, value) in runtimeDebugResolutionPayload(resolution) {
                payload[key] = value
            }
            runtimeDebugLog(
                hypothesisID: resolution == nil ? "h1" : "h2",
                name: "hover_update",
                expected: "resolved path only when hover should activate",
                actual: wordPathHoverActive ? "hover_active" : "hover_inactive",
                data: payload
            )
        }
#endif
    }

    private func resolvedWordPathWorkingDirectory(
        workspace: Workspace,
        terminalSurface: TerminalSurface
    ) -> String? {
        if let dir = workspace.panelDirectories[terminalSurface.id]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !dir.isEmpty {
            return dir
        }
        if let dir = workspace.terminalPanel(for: terminalSurface.id)?
            .requestedWorkingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
           !dir.isEmpty {
            return dir
        }
        let dir = workspace.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        return dir.isEmpty ? nil : dir
    }

    private func pointIsUsableForWordResolution(_ point: NSPoint) -> Bool {
        bounds.width > 0 &&
        bounds.height > 0 &&
        point.x >= 0 &&
        point.y >= 0 &&
        point.x <= bounds.width &&
        point.y <= bounds.height
    }

    func trackMousePointIfUsable(_ point: NSPoint) {
        guard pointIsUsableForWordResolution(point) else { return }
        lastKnownMousePointInView = point
    }

    func preferredPointerPoint(from eventPoint: NSPoint? = nil) -> NSPoint? {
        if let eventPoint, pointIsUsableForWordResolution(eventPoint) {
            lastKnownMousePointInView = eventPoint
            return eventPoint
        }
        if let currentPoint = currentMousePointInView(), pointIsUsableForWordResolution(currentPoint) {
            lastKnownMousePointInView = currentPoint
            return currentPoint
        }
        return lastKnownMousePointInView ?? eventPoint
    }

    private func currentMousePointInView() -> NSPoint? {
        guard let window else { return nil }
        return convert(window.mouseLocationOutsideOfEventStream, from: nil)
    }

    private func resolveVisibleWordPathFromViewportOffset(
        _ viewportOffsetStart: Int,
        cwd: String,
        workspace: Workspace,
        terminalSurface: TerminalSurface
    ) -> WordPathResolution? {
        guard let panel = workspace.terminalPanel(for: terminalSurface.id),
              let surface else {
            return nil
        }

        let size = ghostty_surface_size(surface)
        let rows = max(Int(size.rows), 1)
        let cols = max(Int(size.columns), 1)
        let visibleText = TerminalController.shared.readTerminalTextForSnapshot(
            terminalPanel: panel,
            lineLimit: max(200, rows * 4)
        ) ?? ""
        let visibleLines = programaVisibleTerminalLines(from: visibleText, rows: rows)
        let rowOffset = max(0, rows - visibleLines.count)
        let rowFromTop = max(0, min(rows - 1, viewportOffsetStart / cols))
        let visibleRow = rowFromTop - rowOffset
        guard visibleRow >= 0, visibleRow < visibleLines.count else { return nil }

        let column = max(0, min(cols - 1, viewportOffsetStart % cols))
        guard let resolution = programaResolveVisibleLinePath(
            visibleLines[visibleRow],
            column: column,
            cwd: cwd
        ) else {
            return nil
        }

        return makeWordPathResolution(
            path: resolution.path,
            source: .snapshot,
            rawToken: resolution.rawToken
        )
    }

    private func resolveVisibleWordPath(
        at point: NSPoint,
        cwd: String,
        workspace: Workspace,
        terminalSurface: TerminalSurface
    ) -> WordPathResolution? {
        guard let panel = workspace.terminalPanel(for: terminalSurface.id),
              let surface else {
            return nil
        }

        let size = ghostty_surface_size(surface)
        let rows = max(Int(size.rows), 1)
        let cols = max(Int(size.columns), 1)
        let resolvedCellWidth = cellSize.width > 0 ? cellSize.width : CGFloat(size.cell_width_px)
        let resolvedCellHeight = cellSize.height > 0 ? cellSize.height : CGFloat(size.cell_height_px)
        guard resolvedCellWidth > 0, resolvedCellHeight > 0 else { return nil }

        let visibleText = TerminalController.shared.readTerminalTextForSnapshot(
            terminalPanel: panel,
            lineLimit: max(200, rows * 4)
        ) ?? ""
        let visibleLines = programaVisibleTerminalLines(from: visibleText, rows: rows)
        let rowOffset = max(0, rows - visibleLines.count)
        let xInset = max(0, (bounds.width - (CGFloat(cols) * resolvedCellWidth)) / 2)
        let yInset = max(0, (bounds.height - (CGFloat(rows) * resolvedCellHeight)) / 2)

        let yFromTop = bounds.height - point.y
        let rowFromTop = max(0, min(rows - 1, Int((yFromTop - yInset) / resolvedCellHeight)))
        let visibleRow = rowFromTop - rowOffset
        guard visibleRow >= 0, visibleRow < visibleLines.count else { return nil }

        let column = max(0, min(cols - 1, Int((point.x - xInset) / resolvedCellWidth)))
        guard let resolution = programaResolveVisibleLinePath(
            visibleLines[visibleRow],
            column: column,
            cwd: cwd
        ) else {
            return nil
        }

        return makeWordPathResolution(
            path: resolution.path,
            source: .snapshot,
            rawToken: resolution.rawToken
        )
    }

    @discardableResult
    private func handleCommandClickRelease(
        at point: NSPoint,
        modifierFlags: NSEvent.ModifierFlags,
        ghosttyConsumed: Bool
    ) -> WordPathResolution? {
        guard let surface else { return nil }
        let suppressCommandPathHover = shouldSuppressCommandPathHover(for: modifierFlags)
        let cmdHeld = modifierFlags.contains(.command)
        let resolvedPoint = preferredPointerPoint(from: point)
        guard cmdHeld, !suppressCommandPathHover else {
#if DEBUG
            if cmdHeld || suppressCommandPathHover {
                runtimeDebugLog(
                    hypothesisID: "h1",
                    name: "command_click_release",
                    expected: "cmd-click fallback only when selection is inactive",
                    actual: suppressCommandPathHover ? "suppressed" : "not_cmd_click",
                    data: [
                        "flags": debugModifierString(modifierFlags),
                        "ghostty_consumed": ghosttyConsumed,
                        "point_x": point.x,
                        "point_y": point.y,
                        "resolved_point_x": resolvedPoint?.x ?? -1,
                        "resolved_point_y": resolvedPoint?.y ?? -1,
                        "suppress_path_hover": suppressCommandPathHover
                    ]
                )
            }
#endif
            return nil
        }

        // Refresh ghostty's cached mouse position so quicklook_word reads
        // up-to-date coordinates (mouseDown skips pos update on double-click).
        if let resolvedPoint {
            ghostty_surface_mouse_pos(
                surface,
                resolvedPoint.x,
                bounds.height - resolvedPoint.y,
                modsFromFlags(modifierFlags)
            )
        }

        guard let resolution = resolveWordUnderCursorPath(at: resolvedPoint) else {
#if DEBUG
            runtimeDebugLog(
                hypothesisID: "h2",
                name: "command_click_release",
                expected: "cmd-click should resolve the token under the pointer",
                actual: "no_resolution",
                data: [
                    "flags": debugModifierString(modifierFlags),
                    "ghostty_consumed": ghosttyConsumed,
                    "point_x": point.x,
                    "point_y": point.y,
                    "resolved_point_x": resolvedPoint?.x ?? -1,
                    "resolved_point_y": resolvedPoint?.y ?? -1
                ]
            )
#endif
            return nil
        }
        guard !ghosttyConsumed || resolution.source == .snapshot else {
#if DEBUG
            var payload: [String: Any] = [
                "flags": debugModifierString(modifierFlags),
                "ghostty_consumed": ghosttyConsumed,
                "point_x": point.x,
                "point_y": point.y,
                "resolved_point_x": resolvedPoint?.x ?? -1,
                "resolved_point_y": resolvedPoint?.y ?? -1,
                "suppress_path_hover": suppressCommandPathHover
            ]
            for (key, value) in runtimeDebugResolutionPayload(resolution) {
                payload[key] = value
            }
            runtimeDebugLog(
                hypothesisID: "h3",
                name: "command_click_release",
                expected: "ghostty-consumed clicks should only skip fallback for real ghostty targets",
                actual: "consumed_quicklook_resolution_skipped",
                data: payload
            )
#endif
            return nil
        }

        #if DEBUG
        dlog(
            "link.wordFallback resolved=\(resolution.path) source=\(resolution.source.rawValue) consumed=\(ghosttyConsumed ? 1 : 0)"
        )
        var payload: [String: Any] = [
            "flags": debugModifierString(modifierFlags),
            "ghostty_consumed": ghosttyConsumed,
            "point_x": point.x,
            "point_y": point.y,
            "resolved_point_x": resolvedPoint?.x ?? -1,
            "resolved_point_y": resolvedPoint?.y ?? -1,
            "suppress_path_hover": suppressCommandPathHover
        ]
        for (key, value) in runtimeDebugResolutionPayload(resolution) {
            payload[key] = value
        }
        runtimeDebugLog(
            hypothesisID: resolution.source == .snapshot ? "h3" : "h2",
            name: "command_click_release",
            expected: "cmd-click should open the resolved path",
            actual: "opening_resolved_path",
            data: payload
        )
        #endif

        PreferredEditorSettings.open(URL(fileURLWithPath: resolution.path))
        return resolution
    }

    private func clampedDebugPoint(_ point: NSPoint) -> NSPoint {
        NSPoint(
            x: min(max(point.x, 1), max(bounds.width - 1, 1)),
            y: min(max(point.y, 1), max(bounds.height - 1, 1))
        )
    }

#if DEBUG
    func debugSimulateSelection(from startPoint: NSPoint, to endPoint: NSPoint) -> Bool {
        guard let surface else { return false }
        let start = clampedDebugPoint(startPoint)
        let end = clampedDebugPoint(endPoint)
        let mods = GHOSTTY_MODS_NONE

        window?.makeFirstResponder(self)
        ghostty_surface_mouse_pos(surface, start.x, bounds.height - start.y, mods)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, mods)

        let steps = max(4, Int(max(abs(end.x - start.x), abs(end.y - start.y)) / max(cellSize.width, 1)))
        for step in 1...steps {
            let progress = CGFloat(step) / CGFloat(steps)
            let intermediatePoint = NSPoint(
                x: start.x + ((end.x - start.x) * progress),
                y: start.y + ((end.y - start.y) * progress)
            )
            let clampedIntermediatePoint = clampedDebugPoint(intermediatePoint)
            ghostty_surface_mouse_pos(
                surface,
                clampedIntermediatePoint.x,
                bounds.height - clampedIntermediatePoint.y,
                mods
            )
        }

        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, mods)
        return ghostty_surface_has_selection(surface)
    }

    func debugSimulateCommandHover(at point: NSPoint) -> Bool {
        guard let surface else { return false }
        let clampedPoint = clampedDebugPoint(point)
        let flags: NSEvent.ModifierFlags = [.command]
        let suppressCommandPathHover = shouldSuppressCommandPathHover(for: flags)

        ghostty_surface_mouse_pos(
            surface,
            clampedPoint.x,
            bounds.height - clampedPoint.y,
            hoverModsFromFlags(
                flags,
                suppressCommandPathHover: suppressCommandPathHover
            )
        )
        updateWordPathHover(
            at: clampedPoint,
            cmdHeld: true,
            suppressPathHover: suppressCommandPathHover
        )
        return suppressCommandPathHover
    }

    func debugSimulateCommandHoverDetails(at point: NSPoint) -> [String: Any] {
        guard let surface else {
            return ["error": "Missing surface"]
        }

        let clampedPoint = clampedDebugPoint(point)
        let flags: NSEvent.ModifierFlags = [.command]
        let suppressCommandPathHover = shouldSuppressCommandPathHover(for: flags)

        ghostty_surface_mouse_pos(
            surface,
            clampedPoint.x,
            bounds.height - clampedPoint.y,
            hoverModsFromFlags(
                flags,
                suppressCommandPathHover: suppressCommandPathHover
            )
        )

        let resolution = suppressCommandPathHover ? nil : resolveWordUnderCursorPath(at: clampedPoint)
        updateWordPathHover(
            at: clampedPoint,
            cmdHeld: true,
            suppressPathHover: suppressCommandPathHover
        )

        var payload: [String: Any] = [
            "hoverActive": wordPathHoverActive ? "1" : "0",
            "suppressed": suppressCommandPathHover ? "1" : "0"
        ]
        if let resolution {
            payload["resolvedPath"] = resolution.path
            payload["resolutionSource"] = resolution.source.rawValue
            payload["rawToken"] = resolution.rawToken
        }
        return payload
    }

    func debugSimulateCommandClick(at point: NSPoint) -> [String: Any] {
        guard let surface else {
            return ["error": "Missing surface"]
        }

        let clampedPoint = clampedDebugPoint(point)
        let flags: NSEvent.ModifierFlags = [.command]
        let mods = modsFromFlags(flags)

        window?.makeFirstResponder(self)
        ghostty_surface_mouse_pos(surface, clampedPoint.x, bounds.height - clampedPoint.y, mods)
        let pressHandled = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, mods)
        let releaseConsumed = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, mods)
        let resolution = handleCommandClickRelease(
            at: clampedPoint,
            modifierFlags: flags,
            ghosttyConsumed: releaseConsumed
        )

        var payload: [String: Any] = [
            "pressHandled": pressHandled ? "1" : "0",
            "releaseConsumed": releaseConsumed ? "1" : "0",
        ]
        if let resolution {
            payload["openedPath"] = resolution.path
            payload["resolutionSource"] = resolution.source.rawValue
            payload["rawToken"] = resolution.rawToken
        }
        return payload
    }
#endif

    override func rightMouseDown(with event: NSEvent) {
        guard let surface = surface else { return }
        if !ghostty_surface_mouse_captured(surface) {
            requestPointerFocusRecovery()
            super.rightMouseDown(with: event)
            return
        }

        requestPointerFocusRecovery()
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, modsFromEvent(event))
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, modsFromEvent(event))
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let surface = surface else { return }
        if !ghostty_surface_mouse_captured(surface) {
            super.rightMouseUp(with: event)
            return
        }

        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, modsFromEvent(event))
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseDown(with: event)
            return
        }
        requestPointerFocusRecovery()
        window?.makeFirstResponder(self)
        guard let surface = surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, modsFromEvent(event))
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_MIDDLE, modsFromEvent(event))
    }

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseUp(with: event)
            return
        }
        guard let surface = surface else { return }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_MIDDLE, modsFromEvent(event))
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let surface = surface else { return nil }
        if ghostty_surface_mouse_captured(surface) {
            return nil
        }

        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, modsFromEvent(event))
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, modsFromEvent(event))

        let menu = NSMenu()
        if onTriggerFlash != nil {
            let flashItem = menu.addItem(
                withTitle: String(localized: "terminalContextMenu.triggerFlash", defaultValue: "Trigger Flash"),
                action: #selector(triggerFlash(_:)),
                keyEquivalent: ""
            )
            flashItem.target = self
            menu.addItem(.separator())
        }
        if ghostty_surface_has_selection(surface) {
            let item = menu.addItem(
                withTitle: String(localized: "terminalContextMenu.copy", defaultValue: "Copy"),
                action: #selector(copy(_:)),
                keyEquivalent: ""
            )
            item.target = self
        }
        let pasteItem = menu.addItem(
            withTitle: String(localized: "terminalContextMenu.paste", defaultValue: "Paste"),
            action: #selector(paste(_:)),
            keyEquivalent: ""
        )
        pasteItem.target = self
        menu.addItem(.separator())
        let splitHorizontallyItem = menu.addItem(
            withTitle: String(localized: "terminalContextMenu.splitHorizontally", defaultValue: "Split Horizontally"),
            action: #selector(splitHorizontally(_:)),
            keyEquivalent: "d"
        )
        splitHorizontallyItem.target = self
        splitHorizontallyItem.keyEquivalentModifierMask = [.command, .shift]
        splitHorizontallyItem.image = NSImage(
            systemSymbolName: "rectangle.bottomhalf.inset.filled",
            accessibilityDescription: nil
        )

        let splitVerticallyItem = menu.addItem(
            withTitle: String(localized: "terminalContextMenu.splitVertically", defaultValue: "Split Vertically"),
            action: #selector(splitVertically(_:)),
            keyEquivalent: "d"
        )
        splitVerticallyItem.target = self
        splitVerticallyItem.keyEquivalentModifierMask = [.command]
        splitVerticallyItem.image = NSImage(
            systemSymbolName: "rectangle.righthalf.inset.filled",
            accessibilityDescription: nil
        )
        menu.addItem(.separator())
        let resetTerminalItem = menu.addItem(
            withTitle: String(localized: "terminalContextMenu.resetTerminal", defaultValue: "Reset Terminal"),
            action: #selector(resetTerminal(_:)),
            keyEquivalent: ""
        )
        resetTerminalItem.target = self
        resetTerminalItem.image = NSImage(
            systemSymbolName: "arrow.trianglehead.2.clockwise",
            accessibilityDescription: nil
        )
        return menu
    }

    func canSplitCurrentSurface() -> Bool {
        guard let tabId,
              let surfaceId = terminalSurface?.id,
              let app = AppDelegate.shared,
              let manager = app.tabManagerFor(tabId: tabId) ?? app.tabManager,
              let workspace = manager.tabs.first(where: { $0.id == tabId }) else {
            return false
        }
        return workspace.panels[surfaceId] != nil
    }

    @objc func splitHorizontally(_ sender: Any?) {
        _ = splitCurrentSurface(direction: .down)
    }

    @objc func splitVertically(_ sender: Any?) {
        _ = splitCurrentSurface(direction: .right)
    }

    @discardableResult
    private func splitCurrentSurface(direction: SplitDirection) -> Bool {
        guard let tabId,
              let surfaceId = terminalSurface?.id,
              let app = AppDelegate.shared,
              let manager = app.tabManagerFor(tabId: tabId) ?? app.tabManager else {
            return false
        }
        return manager.createSplit(tabId: tabId, surfaceId: surfaceId, direction: direction) != nil
    }

    @objc private func triggerFlash(_ sender: Any?) {
        onTriggerFlash?()
    }

    @objc private func resetTerminal(_ sender: Any?) {
        _ = performBindingAction("reset")
    }

    override func mouseMoved(with event: NSEvent) {
        maybeRequestFirstResponderForMouseFocus()
        guard let surface = surface else { return }
        let suppressCommandPathHover = shouldSuppressCommandPathHover(for: event.modifierFlags)
        let eventPoint = convert(event.locationInWindow, from: nil)
        trackMousePointIfUsable(eventPoint)
        let point = preferredPointerPoint(from: eventPoint) ?? eventPoint
        ghostty_surface_mouse_pos(
            surface,
            point.x,
            bounds.height - point.y,
            hoverModsFromFlags(
                event.modifierFlags,
                suppressCommandPathHover: suppressCommandPathHover
            )
        )
        updateWordPathHover(
            at: point,
            cmdHeld: event.modifierFlags.contains(.command),
            suppressPathHover: suppressCommandPathHover
        )
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        maybeRequestFirstResponderForMouseFocus()
        guard let surface = surface else { return }
        let suppressCommandPathHover = shouldSuppressCommandPathHover(for: event.modifierFlags)
        let eventPoint = convert(event.locationInWindow, from: nil)
        trackMousePointIfUsable(eventPoint)
        let point = preferredPointerPoint(from: eventPoint) ?? eventPoint
        ghostty_surface_mouse_pos(
            surface,
            point.x,
            bounds.height - point.y,
            hoverModsFromFlags(
                event.modifierFlags,
                suppressCommandPathHover: suppressCommandPathHover
            )
        )
        updateWordPathHover(
            at: point,
            cmdHeld: event.modifierFlags.contains(.command),
            suppressPathHover: suppressCommandPathHover
        )
    }

    private func maybeRequestFirstResponderForMouseFocus() {
        guard let window else { return }
        let alreadyFirstResponder = window.firstResponder === self
        let shouldRequest = Self.shouldRequestFirstResponderForMouseFocus(
            focusFollowsMouseEnabled: GhosttyApp.shared.focusFollowsMouseEnabled(),
            pressedMouseButtons: NSEvent.pressedMouseButtons,
            appIsActive: NSApp.isActive,
            windowIsKey: window.isKeyWindow,
            alreadyFirstResponder: alreadyFirstResponder,
            visibleInUI: isVisibleInUI,
            hasUsableGeometry: hasUsableFocusGeometry,
            hiddenInHierarchy: isHiddenOrHasHiddenAncestor
        )
        guard shouldRequest else { return }
        window.makeFirstResponder(self)
    }

    override func mouseExited(with event: NSEvent) {
        if wordPathHoverActive {
            wordPathHoverActive = false
            NSCursor.pop()
        }
        guard let surface = surface else { return }
        if NSEvent.pressedMouseButtons != 0 {
            return
        }
        ghostty_surface_mouse_pos(surface, -1, -1, modsFromEvent(event))
    }

    override func mouseDragged(with event: NSEvent) {
        guard let surface = surface else { return }
        let eventPoint = convert(event.locationInWindow, from: nil)
        trackMousePointIfUsable(eventPoint)
        let point = preferredPointerPoint(from: eventPoint) ?? eventPoint
        ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, modsFromEvent(event))
    }

    override func scrollWheel(with event: NSEvent) {
        NotificationCenter.default.post(name: .ghosttyDidReceiveWheelScroll, object: self)
        guard let surface = surface else { return }
        lastScrollEventTime = CACurrentMediaTime()
        Self.focusLog("scrollWheel: surface=\(terminalSurface?.id.uuidString ?? "nil") firstResponder=\(String(describing: window?.firstResponder))")
        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        let precision = event.hasPreciseScrollingDeltas
        // Boost only gesture-driven precise deltas; high-res mouse wheels
        // report precise deltas with no phase and must not be doubled
        // (ported from upstream cmux da4e4bc460).
        if GhosttyTerminalScrollBoost(event: event).shouldDoublePreciseScrollDelta {
            x *= 2
            y *= 2
        }

        var mods: Int32 = 0
        if precision {
            mods |= 0b0000_0001
        }

        let momentum: Int32
        switch event.momentumPhase {
        case .began:
            momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_BEGAN.rawValue)
        case .stationary:
            momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_STATIONARY.rawValue)
        case .changed:
            momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_CHANGED.rawValue)
        case .ended:
            momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_ENDED.rawValue)
        case .cancelled:
            momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_CANCELLED.rawValue)
        case .mayBegin:
            momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_MAY_BEGIN.rawValue)
        default:
            momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_NONE.rawValue)
        }
        mods |= momentum << 1

        ghostty_surface_mouse_scroll(
            surface,
            x,
            y,
            ghostty_input_scroll_mods_t(mods)
        )
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [
                .mouseEnteredAndExited,
                .mouseMoved,
                .inVisibleRect,
                .activeAlways,
            ],
            owner: self,
            userInfo: nil
        )

        if let trackingArea {
            addTrackingArea(trackingArea)
        }
    }
}
