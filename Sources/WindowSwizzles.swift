import AppKit
import SwiftUI
import Bonsplit
import CoreServices
import UserNotifications
import Combine
import ObjectiveC.runtime
import Darwin

#if DEBUG
// Widened from `private` to `internal`: AppDelegate.setWindowFirstResponderGuardTesting(...)
// / .clearWindowFirstResponderGuardTesting() (in AppDelegate.swift) write these directly. Refs #95.
var programaFirstResponderGuardCurrentEventOverride: NSEvent?
var programaFirstResponderGuardHitViewOverride: NSView?
#endif
private var programaFirstResponderGuardCurrentEventContext: NSEvent?
private var programaFirstResponderGuardHitViewContext: NSView?
private var programaFirstResponderGuardContextWindowNumber: Int?
private var programaWindowFirstResponderBypassDepth = 0

@discardableResult
func programaWithWindowFirstResponderBypass<T>(_ body: () -> T) -> T {
    programaWindowFirstResponderBypassDepth += 1
    defer {
        programaWindowFirstResponderBypassDepth = max(0, programaWindowFirstResponderBypassDepth - 1)
    }
    return body()
}

func programaIsWindowFirstResponderBypassActive() -> Bool {
    programaWindowFirstResponderBypassDepth > 0
}

#if DEBUG
// Widened from `private extension` to `extension`: AppDelegate.installWindowResponderSwizzles()
// (in AppDelegate.swift) references these @objc methods via #selector(...) for method swizzling. Refs #95.
// DEBUG-only: the swizzle exists solely for typing-timing instrumentation.
extension NSApplication {
    @objc func programa_applicationSendEvent(_ event: NSEvent) {
        let typingTimingStart = event.type == .keyDown ? ProgramaTypingTiming.start() : nil
        let phaseTotalStart = event.type == .keyDown ? ProcessInfo.processInfo.systemUptime : 0
        if event.type == .keyDown {
            ProgramaTypingTiming.logEventDelay(path: "app.sendEvent", event: event)
        }
        defer {
            if event.type == .keyDown {
                let totalMs = (ProcessInfo.processInfo.systemUptime - phaseTotalStart) * 1000.0
                ProgramaTypingTiming.logBreakdown(
                    path: "app.sendEvent.phase",
                    totalMs: totalMs,
                    event: event,
                    thresholdMs: 1.0,
                    parts: [("dispatchMs", totalMs)]
                )
                ProgramaTypingTiming.logDuration(
                    path: "app.sendEvent",
                    startedAt: typingTimingStart,
                    event: event
                )
            }
        }
        programa_applicationSendEvent(event)
    }
}
#endif

// Widened from `private extension` to `extension`: AppDelegate.installWindowResponderSwizzles()
// (in AppDelegate.swift) references these @objc methods via #selector(...) for method swizzling. Refs #95.
extension NSWindow {
    @objc func programa_makeFirstResponder(_ responder: NSResponder?) -> Bool {
        if programaIsWindowFirstResponderBypassActive() {
#if DEBUG
            dlog(
                "focus.guard bypassFirstResponder responder=\(String(describing: responder.map { type(of: $0) })) " +
                "window=\(ObjectIdentifier(self))"
            )
#endif
            return false
        }

        if AppDelegate.shared?.shouldBlockFirstResponderChangeWhileCommandPaletteVisible(
            window: self,
            responder: responder
        ) == true {
#if DEBUG
            dlog(
                "focus.guard commandPaletteBlocked responder=\(String(describing: responder.map { type(of: $0) })) " +
                "window=\(ObjectIdentifier(self))"
            )
#endif
            return false
        }

        return programa_makeFirstResponder(responder)
    }

    @objc func programa_sendEvent(_ event: NSEvent) {
#if DEBUG
        let typingTimingStart = event.type == .keyDown ? ProgramaTypingTiming.start() : nil
        let phaseTotalStart = event.type == .keyDown ? ProcessInfo.processInfo.systemUptime : 0
        var contextSetupMs: Double = 0
        var focusRepairMs: Double = 0
        var folderGuardMs: Double = 0
        var originalDispatchMs: Double = 0
        if event.type == .keyDown {
            ProgramaTypingTiming.logEventDelay(path: "window.sendEvent", event: event)
        }
#endif
        // recordTypingActivity must run in all builds so runSessionAutosaveTick
        // can honor the typing quiet period in release.
        if event.type == .keyDown {
            AppDelegate.shared?.sessionAutosave.recordTypingActivity()
        }
#if DEBUG
        defer {
            if event.type == .keyDown {
                let totalMs = (ProcessInfo.processInfo.systemUptime - phaseTotalStart) * 1000.0
                ProgramaTypingTiming.logBreakdown(
                    path: "window.sendEvent.phase",
                    totalMs: totalMs,
                    event: event,
                    thresholdMs: 1.0,
                    parts: [
                        ("contextSetupMs", contextSetupMs),
                        ("focusRepairMs", focusRepairMs),
                        ("folderGuardMs", folderGuardMs),
                        ("originalDispatchMs", originalDispatchMs),
                    ],
                    extra: nil
                )
                ProgramaTypingTiming.logDuration(
                    path: "window.sendEvent",
                    startedAt: typingTimingStart,
                    event: event,
                    extra: nil
                )
            }
        }
        let contextSetupStart = event.type == .keyDown ? ProcessInfo.processInfo.systemUptime : 0
#endif
        let previousContextEvent = programaFirstResponderGuardCurrentEventContext
        let previousContextHitView = programaFirstResponderGuardHitViewContext
        let previousContextWindowNumber = programaFirstResponderGuardContextWindowNumber
        programaFirstResponderGuardCurrentEventContext = event
        // PERF (#183): this context is a cache for `programaHitViewForCurrentEvent`, whose only
        // reader is `programaPointerHitWebView` -- and that bails on `programaIsPointerDownEvent`
        // before ever reading it. Filling it for a keyDown therefore ran a full recursive AppKit
        // hit-test, on every keystroke, for a value nothing could observe. Compute it only for the
        // events that can actually consume it. When it is nil, `programaHitViewForCurrentEvent`
        // already falls through to computing the hit view on demand, so no reader loses anything.
        programaFirstResponderGuardHitViewContext = Self.programaIsPointerDownEvent(event)
            ? Self.programaHitViewForEventDispatch(in: self, event: event)
            : nil
        programaFirstResponderGuardContextWindowNumber = self.windowNumber
#if DEBUG
        if event.type == .keyDown {
            contextSetupMs = (ProcessInfo.processInfo.systemUptime - contextSetupStart) * 1000.0
        }
        let focusRepairStart = event.type == .keyDown ? ProcessInfo.processInfo.systemUptime : 0
#endif
        if event.type == .keyDown {
            AppDelegate.shared?.repairFocusedTerminalKeyboardRoutingIfNeeded(
                window: self,
                event: event
            )
        }
#if DEBUG
        if event.type == .keyDown {
            focusRepairMs = (ProcessInfo.processInfo.systemUptime - focusRepairStart) * 1000.0
        }
        let folderGuardStart = event.type == .keyDown ? ProcessInfo.processInfo.systemUptime : 0
#endif
        defer {
            programaFirstResponderGuardCurrentEventContext = previousContextEvent
            programaFirstResponderGuardHitViewContext = previousContextHitView
            programaFirstResponderGuardContextWindowNumber = previousContextWindowNumber
        }

        // The card's dead top-edge sliver (the padding-ring WindowDragHandleView
        // mount in ContentView.swift doesn't fully cover it -- AppKit's hit-test
        // bottoms out at the bare content host there) has no native drag:
        // isMovable=false and isMovableByWindowBackground=false disable AppKit's
        // own titlebar drag globally. Handle it here for genuine unclaimed
        // background only -- real controls (traffic lights, titlebar accessory
        // buttons) and real content (terminal surfaces, bonsplit's tab bar, which
        // are portal-hosted outside contentView's subtree by design) keep their
        // own gestures -- and folder-icon drag suppression keeps priority over
        // this (checked first, matching the guard below).
        if event.type == .leftMouseDown,
           !shouldSuppressWindowMoveForFolderDrag(window: self, event: event),
           let hitView = programaFirstResponderGuardHitViewContext,
           Self.programaIsTitlebarBackgroundDragTarget(hitView, in: self) {
            #if DEBUG
            dlog(
                "titlebar.chromeDrag start clickCount=\(event.clickCount) " +
                "hit=\(type(of: hitView))"
            )
            #endif
            if event.clickCount >= 2 {
                let action = performStandardTitlebarDoubleClick(window: self)
                #if DEBUG
                dlog("titlebar.chromeDrag doubleClick action=\(String(describing: action))")
                #endif
            } else {
                withTemporaryWindowMovableEnabled(window: self) {
                    self.performDrag(with: event)
                }
                #if DEBUG
                dlog("titlebar.chromeDrag dragComplete nowMovable=\(self.isMovable)")
                #endif
            }
            return
        }

        guard shouldSuppressWindowMoveForFolderDrag(window: self, event: event),
              let contentView = self.contentView else {
#if DEBUG
            if event.type == .keyDown {
                folderGuardMs = (ProcessInfo.processInfo.systemUptime - folderGuardStart) * 1000.0
                let originalDispatchStart = ProcessInfo.processInfo.systemUptime
                programa_sendEvent(event)
                originalDispatchMs = (ProcessInfo.processInfo.systemUptime - originalDispatchStart) * 1000.0
                return
            }
#endif
            programa_sendEvent(event)
            return
        }
#if DEBUG
        if event.type == .keyDown {
            folderGuardMs = (ProcessInfo.processInfo.systemUptime - folderGuardStart) * 1000.0
        }
        let originalDispatchStart = event.type == .keyDown ? ProcessInfo.processInfo.systemUptime : 0
#endif

        let contentPoint = contentView.convert(event.locationInWindow, from: nil)
        let hitView = contentView.hitTest(contentPoint)
        let previousMovableState = isMovable
        if previousMovableState {
            isMovable = false
        }

        #if DEBUG
        let hitDesc = hitView.map { String(describing: type(of: $0)) } ?? "nil"
        dlog("window.sendEvent.folderDown suppress=1 hit=\(hitDesc) wasMovable=\(previousMovableState)")
        #endif

        programa_sendEvent(event)
#if DEBUG
        if event.type == .keyDown {
            originalDispatchMs = (ProcessInfo.processInfo.systemUptime - originalDispatchStart) * 1000.0
        }
#endif

        if previousMovableState {
            isMovable = previousMovableState
        }

        #if DEBUG
        dlog("window.sendEvent.folderDown restore nowMovable=\(isMovable)")
        #endif
    }

    @objc func programa_performKeyEquivalent(with event: NSEvent) -> Bool {
#if DEBUG
        let typingTimingStart = ProgramaTypingTiming.start()
        defer {
            ProgramaTypingTiming.logDuration(
                path: "window.performKeyEquivalent",
                startedAt: typingTimingStart,
                event: event
            )
        }
        let frType = self.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        dlog("performKeyEquiv: \(Self.keyDescription(event)) fr=\(frType)")
#endif

        // When the terminal surface is the first responder, prevent SwiftUI's
        // hosting view from consuming key events via performKeyEquivalent.
        // SwiftUI's internal focus system can get into a broken state where it
        // intercepts key events in the content view hierarchy, returns true
        // (claiming consumption), but never actually fires the action closure.
        //
        // For non-Command keys: bypass the view hierarchy entirely and send
        // directly to the terminal so arrow keys, Ctrl+N/P, etc. reach keyDown.
        //
        // For Command keys: bypass the SwiftUI content view hierarchy and
        // dispatch directly to the main menu. No SwiftUI view should be handling
        // Command shortcuts when the terminal is focused — the local event monitor
        // (handleCustomShortcut) already handles app-level shortcuts, and anything
        // remaining should be menu items.
        let firstResponderGhosttyView = programaOwningGhosttyView(for: self.firstResponder)
        if let ghosttyView = firstResponderGhosttyView {
            // If the IME is composing and the key has no Cmd modifier, don't intercept —
            // let it flow through normal AppKit event dispatch so the input method can
            // process it. Cmd-based shortcuts should still work during composition since
            // Cmd is never part of IME input sequences.
            if ghosttyView.hasMarkedText(), !event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command) {
                return programa_performKeyEquivalent(with: event)
            }

            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if !flags.contains(.command) {
                let result = ghosttyView.performKeyEquivalent(with: event)
#if DEBUG
                dlog("  → ghostty direct: \(result)")
#endif
                return result
            }

            // Preserve Ghostty's terminal font-size shortcuts (Cmd +/−/0) when
            // the terminal is focused.
            if shouldRouteTerminalFontZoomShortcutToGhostty(
                firstResponderIsGhostty: true,
                flags: event.modifierFlags,
                chars: event.charactersIgnoringModifiers ?? "",
                keyCode: event.keyCode,
                literalChars: event.characters
            ) {
                ghosttyView.keyDown(with: event)
#if DEBUG
                dlog("zoom.shortcut stage=window.ghosttyKeyDownDirect event=\(Self.keyDescription(event)) handled=1")
#endif
                return true
            }
        }

        // When the terminal is focused, skip the full NSWindow.performKeyEquivalent
        // (which walks the SwiftUI content view hierarchy) and dispatch Command-key
        // events directly to the main menu. This avoids the broken SwiftUI focus path.
        if firstResponderGhosttyView != nil,
           shouldRouteCommandEquivalentDirectlyToMainMenu(event),
           let mainMenu = NSApp.mainMenu {
            let consumedByMenu = mainMenu.performKeyEquivalent(with: event)
            if !consumedByMenu {
                // Fall through to the original performKeyEquivalent path below.
            } else {
#if DEBUG
                dlog("  → consumed by mainMenu (bypassed SwiftUI)")
#endif
                return true
            }
        }

        let result = programa_performKeyEquivalent(with: event)
#if DEBUG
        if result { dlog("  → consumed by original performKeyEquivalent") }
#endif
        return result
    }

    static func keyDescription(_ event: NSEvent) -> String {
        var parts: [String] = []
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { parts.append("Cmd") }
        if flags.contains(.shift) { parts.append("Shift") }
        if flags.contains(.option) { parts.append("Opt") }
        if flags.contains(.control) { parts.append("Ctrl") }
        let chars = event.charactersIgnoringModifiers ?? "?"
        parts.append("'\(chars)'(\(event.keyCode))")
        return parts.joined(separator: "+")
    }

    private static func programaCurrentEvent(for window: NSWindow) -> NSEvent? {
#if DEBUG
        if let override = programaFirstResponderGuardCurrentEventOverride {
            return override
        }
#endif
        if programaFirstResponderGuardContextWindowNumber == window.windowNumber {
            return programaFirstResponderGuardCurrentEventContext
        }
        return NSApp.currentEvent
    }

    private static func programaHitViewInThemeFrame(in window: NSWindow, event: NSEvent) -> NSView? {
        guard let contentView = window.contentView,
              let themeFrame = contentView.superview else {
            return nil
        }
        let pointInTheme = themeFrame.convert(event.locationInWindow, from: nil)
        return themeFrame.hitTest(pointInTheme)
    }

    private static func programaHitViewInContentView(in window: NSWindow, event: NSEvent) -> NSView? {
        guard let contentView = window.contentView else {
            return nil
        }
        let pointInContent = contentView.convert(event.locationInWindow, from: nil)
        return contentView.hitTest(pointInContent)
    }

    private static func programaTopHitViewForEvent(in window: NSWindow, event: NSEvent) -> NSView? {
        if let hitInThemeFrame = programaHitViewInThemeFrame(in: window, event: event) {
            return hitInThemeFrame
        }
        return programaHitViewInContentView(in: window, event: event)
    }

    private static func programaHitViewForEventDispatch(in window: NSWindow, event: NSEvent) -> NSView? {
        if event.windowNumber != 0, event.windowNumber != window.windowNumber {
            return nil
        }
        if let eventWindow = event.window, eventWindow !== window {
            return nil
        }
        return programaTopHitViewForEvent(in: window, event: event)
    }

    /// True when `hitView` is exactly `window.contentView` (its root SwiftUI host) --
    /// what AppKit's hit-test falls back to when nothing more specific (no SwiftUI
    /// view, no WindowDragHandleView mount) claims the point, observed for the top
    /// gap ring where the padding-ring mount's own frame doesn't extend.
    ///
    /// Deliberately NOT "walk up and see if we ever pass through contentView":
    /// portal-hosted content (GhosttyNSView terminal surfaces)
    /// is mounted as a theme-frame sibling outside contentView's subtree by design
    /// (see WindowTerminalHostView / the terminal find layering contract in
    /// CLAUDE.md), so that walk classified live terminal content as dead chrome --
    /// caught by the card-center negative test, which must never regress.
    /// Scoped to the main window's hosting view: in any window whose contentView
    /// is a plain NSHostingView (NSPopover content, About/Settings panels), pure
    /// SwiftUI controls are not NSViews, so EVERY click bottoms out at
    /// contentView — treating that as dead chrome swallowed the update popover's
    /// Install button (0.4.249 regression), and the accessory check downstream
    /// even throws on popover-style windows.
    private static func programaIsTitlebarChromeHit(_ hitView: NSView, contentView: NSView) -> Bool {
        hitView === contentView && contentView is MainWindowHostingViewMarker
    }

    private static func programaIsControlOrControlDescendant(_ view: NSView) -> Bool {
        var current: NSView? = view
        while let candidate = current {
            if candidate is NSControl {
                return true
            }
            current = candidate.superview
        }
        return false
    }

    /// True when `hitView` is owned by a `TitlebarControlsAccessoryViewController`
    /// (the help/notifications/new-tab cluster) installed on `window`, so its own
    /// gestures (including non-`NSControl` hover chrome inside it) are preserved.
    private static func programaIsWithinTitlebarControlsAccessory(_ hitView: NSView, in window: NSWindow) -> Bool {
        for controller in window.titlebarAccessoryViewControllers {
            guard controller is TitlebarControlsAccessoryViewController else { continue }
            if hitView === controller.view || hitView.isDescendant(of: controller.view) {
                return true
            }
        }
        return false
    }

    /// True when a `leftMouseDown` hit on `hitView` should start a titlebar-style
    /// window drag (or, on double-click, the standard zoom): unclaimed background
    /// (see `programaIsTitlebarChromeHit`), and not a real control or the titlebar
    /// controls accessory cluster. Internal (not private) as the unit-test seam
    /// for the popover-click regression in WindowAndDragTests.
    static func programaIsTitlebarBackgroundDragTarget(_ hitView: NSView, in window: NSWindow) -> Bool {
        guard let contentView = window.contentView else { return false }
        guard programaIsTitlebarChromeHit(hitView, contentView: contentView) else { return false }
        if programaIsControlOrControlDescendant(hitView) { return false }
        if programaIsWithinTitlebarControlsAccessory(hitView, in: window) { return false }
        return true
    }

    private static func programaHitViewForCurrentEvent(in window: NSWindow, event: NSEvent) -> NSView? {
#if DEBUG
        if let override = programaFirstResponderGuardHitViewOverride {
            return override
        }
#endif
        if programaFirstResponderGuardContextWindowNumber == window.windowNumber,
           let contextHitView = programaFirstResponderGuardHitViewContext {
            return contextHitView
        }
        return programaTopHitViewForEvent(in: window, event: event)
    }

    private static func programaIsPointerDownEvent(_ event: NSEvent) -> Bool {
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            return true
        default:
            return false
        }
    }


}

// User-initiated main-window close (red button, File > Close, Close Window shortcut)
// confirms like closing the last workspace when a workspace has a running process.
// Programmatic `close()` (socket `window.close`, last-workspace close, termination) skips
// this gate. The red button's action is proxied rather than using `windowShouldClose`
// because SwiftUI owns the launch window's delegate; `performClose:` reaches the same
// proxy because AppKit implements it by clicking the close button.
private var programaCloseButtonOriginalActionKey: UInt8 = 0

private final class ProgramaCloseButtonOriginalAction: NSObject {
    let action: Selector
    weak var target: AnyObject?

    init(action: Selector, target: AnyObject?) {
        self.action = action
        self.target = target
    }
}

extension NSWindow {
    /// Idempotent; re-run on every main-window register because AppKit can rebuild titlebar buttons.
    func programaInstallMainWindowCloseConfirmation() {
        guard let button = standardWindowButton(.closeButton),
              let originalAction = button.action,
              originalAction != #selector(NSWindow.programa_mainWindowCloseButtonPressed(_:)) else { return }
        objc_setAssociatedObject(
            self,
            &programaCloseButtonOriginalActionKey,
            ProgramaCloseButtonOriginalAction(action: originalAction, target: button.target),
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        button.target = self
        button.action = #selector(NSWindow.programa_mainWindowCloseButtonPressed(_:))
    }

    @objc func programa_mainWindowCloseButtonPressed(_ sender: Any?) {
        if let app = AppDelegate.shared, !app.isTerminatingApp,
           let context = app.mainWindowContexts[ObjectIdentifier(self)],
           !context.tabManager.confirmCloseWindowIfNeeded() {
            return
        }
        guard let original = objc_getAssociatedObject(self, &programaCloseButtonOriginalActionKey)
            as? ProgramaCloseButtonOriginalAction else {
            close()
            return
        }
        NSApp.sendAction(original.action, to: original.target ?? self, from: sender)
    }
}
