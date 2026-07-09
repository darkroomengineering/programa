import AppKit
import SwiftUI
import Bonsplit
import CoreServices
import UserNotifications
import WebKit
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
private var programaBrowserReturnForwardingDepth = 0
private var programaWindowFirstResponderBypassDepth = 0
private var programaFieldEditorOwningWebViewAssociationKey: UInt8 = 0

@discardableResult
func cmuxWithWindowFirstResponderBypass<T>(_ body: () -> T) -> T {
    programaWindowFirstResponderBypassDepth += 1
    defer {
        programaWindowFirstResponderBypassDepth = max(0, programaWindowFirstResponderBypassDepth - 1)
    }
    return body()
}

func programaIsWindowFirstResponderBypassActive() -> Bool {
    programaWindowFirstResponderBypassDepth > 0
}

private final class ProgramaFieldEditorOwningWebViewBox: NSObject {
    weak var webView: ProgramaWebView?

    init(webView: ProgramaWebView?) {
        self.webView = webView
    }
}

// Widened from `private extension` to `extension`: AppDelegate.installWindowResponderSwizzles()
// (in AppDelegate.swift) references these @objc methods via #selector(...) for method swizzling. Refs #95.
extension NSApplication {
    @objc func programa_applicationSendEvent(_ event: NSEvent) {
#if DEBUG
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
#endif
        programa_applicationSendEvent(event)
    }
}

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

        let currentEvent = Self.programaCurrentEvent(for: self)
        let responderWebView = responder.flatMap {
            Self.programaOwningWebView(for: $0, in: self, event: currentEvent)
        }
        var pointerInitiatedWebFocus = false

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

        if let responder,
           let webView = responderWebView,
           !webView.allowsFirstResponderAcquisitionEffective {
            let pointerInitiatedFocus = Self.programaShouldAllowPointerInitiatedWebViewFocus(
                window: self,
                webView: webView,
                event: currentEvent
            )
            if pointerInitiatedFocus {
                pointerInitiatedWebFocus = true
#if DEBUG
                dlog(
                    "focus.guard allowPointerFirstResponder responder=\(String(describing: type(of: responder))) " +
                    "window=\(ObjectIdentifier(self)) " +
                    "web=\(ObjectIdentifier(webView)) " +
                    "policy=\(webView.allowsFirstResponderAcquisition ? 1 : 0) " +
                    "pointerDepth=\(webView.debugPointerFocusAllowanceDepth) " +
                    "eventType=\(currentEvent.map { String(describing: $0.type) } ?? "nil")"
                )
#endif
            } else {
#if DEBUG
                dlog(
                    "focus.guard blockedFirstResponder responder=\(String(describing: type(of: responder))) " +
                    "window=\(ObjectIdentifier(self)) " +
                    "web=\(ObjectIdentifier(webView)) " +
                    "policy=\(webView.allowsFirstResponderAcquisition ? 1 : 0) " +
                    "pointerDepth=\(webView.debugPointerFocusAllowanceDepth) " +
                    "eventType=\(currentEvent.map { String(describing: $0.type) } ?? "nil")"
                )
#endif
                return false
            }
        }
#if DEBUG
        if let responder,
           let webView = responderWebView {
            dlog(
                "focus.guard allowFirstResponder responder=\(String(describing: type(of: responder))) " +
                "window=\(ObjectIdentifier(self)) " +
                "web=\(ObjectIdentifier(webView)) " +
                "policy=\(webView.allowsFirstResponderAcquisition ? 1 : 0) " +
                "pointerDepth=\(webView.debugPointerFocusAllowanceDepth)"
            )
        }
#endif
        let result: Bool
        if pointerInitiatedWebFocus, let webView = responderWebView {
            // `NSWindow.makeFirstResponder` may run before `ProgramaWebView.mouseDown(with:)`.
            // Preserve pointer intent during this synchronous responder change.
            result = webView.withPointerFocusAllowance {
                programa_makeFirstResponder(responder)
            }
        } else {
            result = programa_makeFirstResponder(responder)
        }
        if result {
            if let fieldEditor = responder as? NSTextView, fieldEditor.isFieldEditor {
                Self.programaTrackFieldEditor(fieldEditor, owningWebView: responderWebView)
            } else if let fieldEditor = self.firstResponder as? NSTextView, fieldEditor.isFieldEditor {
                Self.programaTrackFieldEditor(fieldEditor, owningWebView: responderWebView)
            }
        }
        return result
    }

    @objc func programa_sendEvent(_ event: NSEvent) {
#if DEBUG
        let typingTimingStart = event.type == .keyDown ? ProgramaTypingTiming.start() : nil
        let phaseTotalStart = event.type == .keyDown ? ProcessInfo.processInfo.systemUptime : 0
        var contextSetupMs: Double = 0
        var focusRepairMs: Double = 0
        var folderGuardMs: Double = 0
        var originalDispatchMs: Double = 0
        let typingTimingExtra: String? = {
            guard event.type == .keyDown else { return nil }
            let responderWebView = self.firstResponder.flatMap {
                Self.programaOwningWebView(for: $0, in: self, event: event)
            }
            let hitWebView = Self.programaHitViewForEventDispatch(in: self, event: event).flatMap {
                Self.programaOwningWebView(for: $0)
            }
            let firstResponderType = self.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
            return "browser=\((responderWebView != nil || hitWebView != nil) ? 1 : 0) firstResponder=\(firstResponderType)"
        }()
        if event.type == .keyDown {
            ProgramaTypingTiming.logEventDelay(path: "window.sendEvent", event: event)
        }
#endif
        // recordTypingActivity must run in all builds so runSessionAutosaveTick
        // can honor the typing quiet period in release.
        if event.type == .keyDown {
            AppDelegate.shared?.recordTypingActivity()
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
                    extra: typingTimingExtra
                )
                ProgramaTypingTiming.logDuration(
                    path: "window.sendEvent",
                    startedAt: typingTimingStart,
                    event: event,
                    extra: typingTimingExtra
                )
            }
        }
        let contextSetupStart = event.type == .keyDown ? ProcessInfo.processInfo.systemUptime : 0
#endif
        let previousContextEvent = programaFirstResponderGuardCurrentEventContext
        let previousContextHitView = programaFirstResponderGuardHitViewContext
        let previousContextWindowNumber = programaFirstResponderGuardContextWindowNumber
        programaFirstResponderGuardCurrentEventContext = event
        programaFirstResponderGuardHitViewContext = Self.programaHitViewForEventDispatch(in: self, event: event)
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
        // After a browser panel (WKWebView) has been in the responder chain,
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
        let firstResponderGhosttyView = cmuxOwningGhosttyView(for: self.firstResponder)
        let firstResponderWebView = self.firstResponder.flatMap {
            Self.programaOwningWebView(for: $0, in: self, event: event)
        }
        let firstResponderHasMarkedText = browserResponderHasMarkedText(self.firstResponder)
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
            // the terminal is focused. Otherwise our browser menu shortcuts can
            // consume the event even when no browser panel is focused.
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

        // Web forms rely on Return/Enter flowing through keyDown. If the original
        // NSWindow.performKeyEquivalent consumes Enter first, submission never reaches
        // WebKit. Route Return/Enter directly to the current first responder and
        // mark handled to avoid the AppKit alert sound path.
        if shouldDispatchBrowserReturnViaFirstResponderKeyDown(
            keyCode: event.keyCode,
            firstResponderIsBrowser: firstResponderWebView != nil,
            firstResponderHasMarkedText: firstResponderHasMarkedText,
            flags: event.modifierFlags
        ) {
            // Forwarding keyDown can re-enter performKeyEquivalent in WebKit/AppKit internals.
            // On re-entry, fall back to normal dispatch to avoid an infinite loop.
            if programaBrowserReturnForwardingDepth > 0 {
#if DEBUG
                dlog("  → browser Return/Enter reentry; using normal dispatch")
#endif
                return false
            }
            programaBrowserReturnForwardingDepth += 1
            defer { programaBrowserReturnForwardingDepth = max(0, programaBrowserReturnForwardingDepth - 1) }
#if DEBUG
            dlog("  → browser Return/Enter routed to firstResponder.keyDown")
#endif
            self.firstResponder?.keyDown(with: event)
            return true
        }

        if let firstResponderWebView,
           shouldRouteBrowserFindCommandEquivalentThroughWebContentFirst(
               event,
               responder: self.firstResponder,
               owningWebView: firstResponderWebView
           ) {
            let result = firstResponderWebView.performKeyEquivalent(with: event)
#if DEBUG
            if result {
                dlog("  → browser find command resolved before window menu path")
            } else {
                dlog("  → browser find command preflight left unclaimed; suppressing replay")
            }
#endif
            // The focused web view has already received this Find-family shortcut once.
            // Do not fall through into the original NSWindow.performKeyEquivalent path,
            // or WebKit can observe the same key equivalent a second time before AppKit
            // reaches keyDown/menu fallback.
            return true
        }

        if AppDelegate.shared?.handleBrowserSurfaceKeyEquivalent(event) == true {
#if DEBUG
            dlog("  → consumed by handleBrowserSurfaceKeyEquivalent")
#endif
            return true
        }

        // When the terminal is focused, skip the full NSWindow.performKeyEquivalent
        // (which walks the SwiftUI content view hierarchy) and dispatch Command-key
        // events directly to the main menu. This avoids the broken SwiftUI focus path.
        if firstResponderGhosttyView != nil,
           shouldRouteCommandEquivalentDirectlyToMainMenu(event),
           let mainMenu = NSApp.mainMenu {
            let consumedByMenu = mainMenu.performKeyEquivalent(with: event)
#if DEBUG
            if browserZoomShortcutTraceCandidate(
                flags: event.modifierFlags,
                chars: event.charactersIgnoringModifiers ?? "",
                keyCode: event.keyCode,
                literalChars: event.characters
            ) {
                dlog(
                    "zoom.shortcut stage=window.mainMenuBypass event=\(Self.keyDescription(event)) " +
                    "consumed=\(consumedByMenu ? 1 : 0) fr=GhosttyNSView"
                )
            }
#endif
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

    private static func programaOwningWebView(for responder: NSResponder) -> ProgramaWebView? {
        if let webView = responder as? ProgramaWebView {
            return webView
        }

        if let view = responder as? NSView,
           let webView = programaOwningWebView(for: view) {
            return webView
        }

        // NSTextView.delegate is unsafe-unretained in AppKit. Reading it here while
        // a responder chain is tearing down can trap with "unowned reference".
        var current = responder.nextResponder
        while let next = current {
            if let webView = next as? ProgramaWebView {
                return webView
            }
            if let view = next as? NSView,
               let webView = programaOwningWebView(for: view) {
                return webView
            }
            current = next.nextResponder
        }

        return nil
    }

    private static func programaOwningWebView(
        for responder: NSResponder,
        in window: NSWindow,
        event: NSEvent?
    ) -> ProgramaWebView? {
        // Browser find runs in the portal slot alongside the hosted WKWebView.
        // Treat its native field editor chain as browser chrome, not as web content,
        // so Cmd+F can move first responder into the find field while web focus is suppressed.
        if BrowserWindowPortalRegistry.searchOverlayPanelId(for: responder, in: window) != nil {
            return nil
        }

        if let webView = programaOwningWebView(for: responder) {
            return webView
        }

        guard let textView = responder as? NSTextView, textView.isFieldEditor else {
            return nil
        }

        if let event,
           let hitWebView = programaPointerHitWebView(in: window, event: event) {
            programaTrackFieldEditor(textView, owningWebView: hitWebView)
            return hitWebView
        }

        return programaTrackedOwningWebView(for: textView)
    }

    private static func programaOwningWebView(for view: NSView) -> ProgramaWebView? {
        if let webView = view as? ProgramaWebView {
            return webView
        }

        var current: NSView? = view.superview
        while let candidate = current {
            if let webView = candidate as? ProgramaWebView {
                return webView
            }
            if String(describing: type(of: candidate)).contains("WindowBrowserSlotView"),
               let portalWebView = programaUniqueBrowserWebView(in: candidate) {
                // Portal-hosted browser chrome (for example the Cmd+F overlay) is a
                // sibling of the hosted WKWebView inside WindowBrowserSlotView, not a
                // descendant of it. Allow native text-entry controls in that slot to
                // acquire first responder directly, but keep generic sibling views
                // associated with the hosted web view so blocked browser focus policy
                // still protects inspector/overlay chrome from stray focus changes.
                if view === portalWebView || view.isDescendant(of: portalWebView) {
                    return portalWebView
                }
                if programaAllowsPortalSlotTextEntryFocus(view) {
                    return nil
                }
                return portalWebView
            }
            current = candidate.superview
        }

        return nil
    }

    private static func programaAllowsPortalSlotTextEntryFocus(_ view: NSView) -> Bool {
        var current: NSView? = view
        while let candidate = current {
            if let textField = candidate as? NSTextField {
                return textField.isEditable || textField.acceptsFirstResponder
            }
            if let textView = candidate as? NSTextView {
                return textView.isEditable || textView.isSelectable || textView.isFieldEditor
            }
            current = candidate.superview
        }
        return false
    }

    private static func programaUniqueBrowserWebView(in root: NSView) -> ProgramaWebView? {
        var stack: [NSView] = [root]
        var found: ProgramaWebView?
        while let current = stack.popLast() {
            if let webView = current as? ProgramaWebView {
                if found == nil {
                    found = webView
                } else if found !== webView {
                    return nil
                }
            }
            stack.append(contentsOf: current.subviews)
        }
        return found
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

    private static func programaTrackFieldEditor(_ fieldEditor: NSTextView, owningWebView webView: ProgramaWebView?) {
        if let webView {
            objc_setAssociatedObject(
                fieldEditor,
                &programaFieldEditorOwningWebViewAssociationKey,
                ProgramaFieldEditorOwningWebViewBox(webView: webView),
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        } else {
            objc_setAssociatedObject(
                fieldEditor,
                &programaFieldEditorOwningWebViewAssociationKey,
                nil,
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
    }

    private static func programaTrackedOwningWebView(for fieldEditor: NSTextView) -> ProgramaWebView? {
        guard let box = objc_getAssociatedObject(
            fieldEditor,
            &programaFieldEditorOwningWebViewAssociationKey
        ) as? ProgramaFieldEditorOwningWebViewBox else {
            return nil
        }
        guard let webView = box.webView else {
            programaTrackFieldEditor(fieldEditor, owningWebView: nil)
            return nil
        }
        return webView
    }

    private static func programaIsPointerDownEvent(_ event: NSEvent) -> Bool {
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            return true
        default:
            return false
        }
    }

    private static func programaPointerHitWebView(in window: NSWindow, event: NSEvent) -> ProgramaWebView? {
        guard programaIsPointerDownEvent(event) else { return nil }
        if event.windowNumber != 0, event.windowNumber != window.windowNumber {
            return nil
        }
        if let eventWindow = event.window, eventWindow !== window {
            return nil
        }
        if let portalWebView = BrowserWindowPortalRegistry.webViewAtWindowPoint(
            event.locationInWindow,
            in: window
        ) as? ProgramaWebView {
            return portalWebView
        }
        guard let hitView = programaHitViewForCurrentEvent(in: window, event: event) else {
            return nil
        }
        return programaOwningWebView(for: hitView)
    }

    private static func programaShouldAllowPointerInitiatedWebViewFocus(
        window: NSWindow,
        webView: ProgramaWebView,
        event: NSEvent?
    ) -> Bool {
        guard let event,
              let hitWebView = programaPointerHitWebView(in: window, event: event) else {
            return false
        }
        return hitWebView === webView
    }

}
