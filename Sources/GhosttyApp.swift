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

// MARK: - GhosttyApp (split out, Nuclear Review #97; verbatim move)
// `GhosttySurfaceCallbackContext` widened private -> internal (also constructed from TerminalSurface.swift).

private func programaRuntimeReadClipboardCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ location: ghostty_clipboard_e,
    _ state: UnsafeMutableRawPointer?
) -> Bool {
    GhosttyApp.runtimeReadClipboardCallback(userdata, location, state)
}

/// Pinned Ghostty heap-allocates this opaque state for async completion and owns and
/// invalidates it after the corresponding completion. This wrapper never dereferences or frees it.
private struct GhosttyClipboardRequestState: @unchecked Sendable {
    let pointer: UnsafeMutableRawPointer
}

/// Preserves the previous raw-pointer equality semantics without transporting the pointer.
/// It carries the same allocator-reuse/ABA limitation, with no pointer ownership or access.
private struct GhosttyRuntimeSurfaceIdentity: Equatable, Sendable {
    let value: UInt

    init(_ surface: ghostty_surface_t) {
        value = UInt(bitPattern: surface)
    }
}

/// Transient provenance for Ghostty's synchronous read-to-confirm callback re-entry.
private enum GhosttyClipboardRequestIdentityRegistry {
    private static let lock = NSLock()
    private static var identities: [UnsafeMutableRawPointer: GhosttyRuntimeSurfaceIdentity] = [:]

    static func withIdentity<Result>(
        state: GhosttyClipboardRequestState,
        identity: GhosttyRuntimeSurfaceIdentity,
        body: () throws -> Result
    ) rethrows -> Result {
        lock.lock()
        identities[state.pointer] = identity
        lock.unlock()
        defer {
            lock.lock()
            if identities[state.pointer] == identity {
                identities.removeValue(forKey: state.pointer)
            }
            lock.unlock()
        }
        // Never hold the registry lock while calling Ghostty: confirmation re-enters here.
        return try body()
    }

    static func identity(for state: GhosttyClipboardRequestState) -> GhosttyRuntimeSurfaceIdentity? {
        lock.lock()
        let identity = identities[state.pointer]
        lock.unlock()
        return identity
    }
}

// Widened from private to internal: also constructed directly from
// TerminalSurface.swift (Nuclear Review #97 split).
//
// DATA-ONLY. Ghostty's IO thread invokes callbacks (clipboard, actions) that read this
// object SYNCHRONOUSLY, before any main-thread hop. It must therefore never hold a
// reference -- weak or strong -- to a Swift UI/runtime object such as `GhosttyNSView` or
// `TerminalSurface`. Reading a weak reference to an object that may be mid-deinit on
// another thread races Swift's ARC weak-reference side table; this is exactly what used
// to crash rapid window create/close cycles ("Object was retained too many times",
// "Weak reference loaded from ... not in the weak references table"). Mirrors
// `SessionWALStore.Context`'s data-only contract (see its doc comment).
//
// Live objects are resolved only from inside a main-thread hop, by looking up
// `(tabId, surfaceId)` through the tab manager / workspace panels registry -- see
// `GhosttyApp.resolveTerminalPanel(tabId:surfaceId:)` and friends.
final class GhosttySurfaceCallbackContext {
    /// Immutable for the lifetime of the surface. Kept only as an identity/lifetime token
    /// for `Unmanaged.passRetained`/`.release()` bookkeeping -- callbacks resolve
    /// `(surfaceId, tabId)` from `GhosttySurfaceUserdataRegistry`'s own dictionary (see its
    /// doc comment), never by dereferencing this object, so it carries no mutable state of
    /// its own.
    let surfaceId: UUID

    init(surfaceId: UUID) {
        self.surfaceId = surfaceId
    }
}

/// Registry of currently-live `GhosttySurfaceCallbackContext` userdata pointers, mapped to
/// a value snapshot of the data callbacks need (`surfaceId`/`tabId`).
///
/// Ghostty can invoke callbacks carrying a surface's `ghostty_surface_userdata` pointer
/// well after the surface itself has been torn down -- e.g. a `.scrollbar` surface message
/// enqueued by the renderer thread (ghostty/src/renderer/generic.zig:1477-1483) and later
/// drained on main via `App.tick` -> `drainMailbox` -> `Surface.updateScrollbar` ->
/// `performAction`, or a clipboard read/confirm callback invoked synchronously off-main
/// (see `runtimeReadClipboardCallback` and `confirm_read_clipboard_cb` below). Resolving
/// `Unmanaged.fromOpaque(_:).takeUnretainedValue()` on a pointer whose backing object was
/// already released is undefined behavior: it crashed as an `objc_retain` `EXC_BAD_ACCESS`
/// in `GhosttySurfaceCallbackContext.tabId.getter` in 6 identical CI minidumps (and once as
/// `doesNotRecognizeSelector`, when the freed page had been reused by a live object of a
/// different class).
///
/// `read_clipboard_cb`/`confirm_read_clipboard_cb` resolve this off the ghostty IO thread
/// (see the "off-main" comment on `runtimeReadClipboardCallback` below) -- so a
/// main-actor-only registry is NOT sound here. This uses a lock instead. Unlike the
/// original fix (#262), the registry now OWNS the data: `register`/`updateTabId` store the
/// snapshot directly, keyed by pointer, so `resolve(from:)` is a pure dictionary lookup --
/// it never calls `Unmanaged.fromOpaque(_:).takeUnretainedValue()` and never touches the
/// `GhosttySurfaceCallbackContext` instance at all. This removes two defects the pointer-set
/// version had: (1) the DEBUG stale-pointer `dlog` used to fire while `lock` was held, and
/// dlog does synchronous real-time file I/O -- on the frequent stale-teardown path under
/// surface churn that serialized every ghostty callback on file I/O; now the log is emitted
/// after the lock is released. (2) `resolve` used to read `context.tabId`, which took the
/// context's own lock while still holding the registry lock (a nested-lock pattern) and
/// required dereferencing a pointer that is exactly what we're trying to make un-dereferenceable.
enum GhosttySurfaceUserdataRegistry {
    private static let lock = NSLock()
    private static var liveContexts: [UnsafeMutableRawPointer: GhosttySurfaceCallbackSnapshot] = [:]

    /// Call once, right after creating the context, before handing its pointer to ghostty
    /// (`ghostty_surface_new`/`ghostty_surface_config_s.userdata`).
    static func register(_ pointer: UnsafeMutableRawPointer, surfaceId: UUID, tabId: UUID?) {
        lock.lock()
        liveContexts[pointer] = GhosttySurfaceCallbackSnapshot(surfaceId: surfaceId, tabId: tabId)
        lock.unlock()
    }

    /// Unregisters `unmanaged`'s pointer and releases it, atomically with respect to
    /// `resolve(from:)`. Use this instead of calling `.release()` directly at every
    /// teardown site, so a concurrent resolver can never observe a pointer as live after
    /// it's been freed.
    static func release(_ unmanaged: Unmanaged<GhosttySurfaceCallbackContext>?) {
        guard let unmanaged else { return }
        let pointer = unmanaged.toOpaque()
        lock.lock()
        liveContexts.removeValue(forKey: pointer)
        lock.unlock()
        unmanaged.release()
    }

    /// Updates the stored snapshot's `tabId` for an already-registered pointer, so a
    /// surface reassigned to a different workspace (`TerminalSurface.updateWorkspaceId`)
    /// doesn't leave callbacks resolving a stale `tabId`. No-op if `pointer` isn't
    /// currently registered (e.g. called racing a teardown).
    static func updateTabId(pointer: UnsafeMutableRawPointer, tabId: UUID?) {
        lock.lock()
        if let existing = liveContexts[pointer] {
            liveContexts[pointer] = GhosttySurfaceCallbackSnapshot(surfaceId: existing.surfaceId, tabId: tabId)
        }
        lock.unlock()
    }

    /// Resolves `pointer` to a value snapshot, or `nil` if `pointer` is nil or stale
    /// (already torn down). Safe to call from any thread. Does the minimum work under
    /// `lock` (a dictionary lookup/copy) and never dereferences the pointer as an object --
    /// the DEBUG stale-pointer log, if it fires, is emitted after the lock is released.
    static func resolve(from pointer: UnsafeMutableRawPointer?) -> GhosttySurfaceCallbackSnapshot? {
        guard let pointer else { return nil }
        lock.lock()
        let snapshot = liveContexts[pointer]
        lock.unlock()
#if DEBUG
        if snapshot == nil {
            dlog("surface.userdata stale pointer rejected ptr=\(pointer)")
        }
#endif
        return snapshot
    }
}

/// Value snapshot of the data a callback needs for a live `GhosttySurfaceCallbackContext`
/// pointer, owned directly by `GhosttySurfaceUserdataRegistry`'s dictionary. Callers never
/// see the live class reference itself -- there's no way to retain (or read a property of)
/// a `GhosttySurfaceCallbackContext` from a callback at all, since `resolve(from:)` never
/// dereferences the pointer.
struct GhosttySurfaceCallbackSnapshot: Sendable {
    let surfaceId: UUID
    let tabId: UUID?
}

// Minimal Ghostty wrapper for terminal rendering
// This uses libghostty (GhosttyKit.xcframework) for actual terminal emulation

// MARK: - Ghostty App Singleton

class GhosttyApp {
    static let shared = GhosttyApp()
    private static let releaseBundleIdentifier = "com.darkroom.programa"
    private static let backgroundLogTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private(set) var app: ghostty_app_t?
    private(set) var config: ghostty_config_t?
    /// Coalesce wakeup → tick dispatches.  The I/O thread may fire wakeup_cb
    /// thousands of times per second during bulk output.  We only need one
    /// pending tick on the main queue at any time.
    private var _tickScheduled = false
    private let _tickLock = NSLock()
    private(set) var defaultBackgroundColor: NSColor = .windowBackgroundColor
    private(set) var defaultBackgroundOpacity: Double = 1.0
    var effectiveTerminalBackgroundOpacity: Double {
        ProgramaGlassSettings.effectiveTerminalBackgroundOpacity(
            configuredOpacity: defaultBackgroundOpacity,
            windowGlassEnabled: cmuxShouldUseTransparentBackgroundWindow()
        )
    }
    private(set) var usesHostLayerBackground = true
    private static func resolveBackgroundLogURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let explicitPath = environment["PROGRAMA_DEBUG_BG_LOG"],
           !explicitPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: explicitPath)
        }

        if let debugLogPath = environment["PROGRAMA_DEBUG_LOG"],
           !debugLogPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let baseURL = URL(fileURLWithPath: debugLogPath)
            let extensionSeparatorIndex = baseURL.lastPathComponent.lastIndex(of: ".")
            let stem = extensionSeparatorIndex.map { String(baseURL.lastPathComponent[..<$0]) } ?? baseURL.lastPathComponent
            let bgName = "\(stem)-bg.log"
            return baseURL.deletingLastPathComponent().appendingPathComponent(bgName)
        }

        return URL(fileURLWithPath: "/tmp/programa-bg.log")
    }

    @MainActor
    private static var clipboardConfirmations: [UInt: ClipboardConfirmation] = [:]

    @MainActor
    private final class ClipboardConfirmation {
        let contents: String
        let kind: ghostty_clipboard_request_e
        let surfaceIdentity: UInt?
        weak var window: NSWindow?
        var completion: ((String) -> Void)?
        var alert: NSAlert?
        var closeObserver: NSObjectProtocol?

        init(
            contents: String,
            kind: ghostty_clipboard_request_e,
            window: NSWindow,
            surfaceIdentity: UInt?,
            completion: @escaping (String) -> Void
        ) {
            self.contents = contents
            self.kind = kind
            self.window = window
            self.surfaceIdentity = surfaceIdentity
            self.completion = completion
        }

        func finish(allow: Bool) {
            guard let completion else { return }
            self.completion = nil
            if let surfaceIdentity,
               GhosttyApp.clipboardConfirmations[surfaceIdentity] === self {
                GhosttyApp.clipboardConfirmations.removeValue(forKey: surfaceIdentity)
            }
            if let closeObserver {
                NotificationCenter.default.removeObserver(closeObserver)
                self.closeObserver = nil
            }
            if let alert, let parent = alert.window.sheetParent {
                parent.endSheet(alert.window, returnCode: .cancel)
            }
            alert = nil
            // confirmed=false re-enters Ghostty's confirmation callback. An empty
            // confirmed completion denies the content and releases the request state.
            completion(allow ? contents : "")
        }

        func present() {
            guard completion != nil else { return }
            guard let window, window.isVisible, window.attachedSheet == nil else {
                finish(allow: false)
                return
            }
            let alert = NSAlert()
            alert.alertStyle = .warning
            if kind == GHOSTTY_CLIPBOARD_REQUEST_PASTE {
                alert.messageText = String(localized: "dialog.clipboardConfirmation.paste.title", defaultValue: "Allow Unsafe Paste?")
                alert.informativeText = String(localized: "dialog.clipboardConfirmation.paste.message", defaultValue: "This clipboard text may execute commands when pasted into the terminal. Allow this paste?")
            } else {
                alert.messageText = String(localized: "dialog.clipboardConfirmation.read.title", defaultValue: "Allow Clipboard Access?")
                alert.informativeText = String(localized: "dialog.clipboardConfirmation.read.message", defaultValue: "A program running in this terminal requested your clipboard contents. Allow it to read the clipboard?")
            }
            let cancel = alert.addButton(withTitle: String(localized: "dialog.clipboardConfirmation.cancel", defaultValue: "Cancel"))
            cancel.keyEquivalent = "\r"
            let allow = alert.addButton(withTitle: String(localized: "dialog.clipboardConfirmation.allow", defaultValue: "Allow"))
            allow.keyEquivalent = ""
            self.alert = alert
            alert.beginSheetModal(for: window) { [self] response in
                finish(allow: response == .alertSecondButtonReturn)
            }
        }
    }

    @MainActor
    static func handleClipboardConfirmation(
        contents: String,
        kind: ghostty_clipboard_request_e? = nil,
        window: NSWindow? = nil,
        surface: ghostty_surface_t? = nil,
        completion: @escaping (String) -> Void
    ) {
        let identity = surface.map { UInt(bitPattern: $0) }
        if let identity {
            clipboardConfirmations[identity]?.finish(allow: false)
        }
        guard let window, let kind,
              kind == GHOSTTY_CLIPBOARD_REQUEST_PASTE || kind == GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ else {
            completion("")
            return
        }
        let request = ClipboardConfirmation(
            contents: contents,
            kind: kind,
            window: window,
            surfaceIdentity: identity,
            completion: completion
        )
        if let identity { clipboardConfirmations[identity] = request }
        request.closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak request] _ in
            MainActor.assumeIsolated { request?.finish(allow: false) }
        }
        DispatchQueue.main.async { request.present() }
    }

    @MainActor
    static func cancelConfirmationsBeforeFree(_ surface: ghostty_surface_t) {
        clipboardConfirmations[UInt(bitPattern: surface)]?.finish(allow: false)
    }

    fileprivate static func runtimeReadClipboardCallback(
        _ userdata: UnsafeMutableRawPointer?,
        _ location: ghostty_clipboard_e,
        _ state: UnsafeMutableRawPointer?
    ) -> Bool {
        // Only value fields are read here, off-main -- see GhosttySurfaceCallbackContext's
        // doc comment. All live-object resolution (including the ghostty_surface_t itself)
        // happens on main below.
        guard let state else { return false }
        let requestState = GhosttyClipboardRequestState(pointer: state)
        guard let callbackContext = Self.callbackContext(from: userdata) else { return false }
        let callbackSurfaceId = callbackContext.surfaceId
        let callbackTabId = callbackContext.tabId

        DispatchQueue.main.async {
            MainActor.assumeIsolated { () -> Void in
                guard let terminalSurface = Self.resolveTerminalSurface(
                    tabId: callbackTabId,
                    surfaceId: callbackSurfaceId
                ) else { return }
                // Deviation from the pre-fix synchronous behavior: we can no longer tell
                // off-main whether the surface is still live, so this callback always
                // returns `true` (accepted) below rather than synchronously falling back to
                // `false` when the surface is already gone. If resolution fails here, the
                // read silently completes as a no-op instead -- ghostty's clipboard-read
                // request is simply never fulfilled, matching what already happened when the
                // surface went away mid-flight in the old code.
                guard let requestSurface = terminalSurface.liveSurfaceForGhosttyAccess(
                    reason: "clipboard.read"
                ) else { return }
                let requestSurfaceIdentity = GhosttyRuntimeSurfaceIdentity(requestSurface)

                func completeClipboardRequest(with text: String) {
                    let finish = {
                        MainActor.assumeIsolated { () -> Void in
                            guard let currentSurface = Self.resolveLiveSurface(
                                tabId: callbackTabId,
                                surfaceId: callbackSurfaceId,
                                reason: "clipboard.complete"
                            ) else { return }
                            let currentSurfaceIdentity = GhosttyRuntimeSurfaceIdentity(currentSurface)
                            guard currentSurfaceIdentity == requestSurfaceIdentity else {
                                return
                            }
                            text.withCString { ptr in
                                GhosttyClipboardRequestIdentityRegistry.withIdentity(
                                    state: requestState,
                                    identity: currentSurfaceIdentity
                                ) {
                                    ghostty_surface_complete_clipboard_request(
                                        currentSurface,
                                        ptr,
                                        requestState.pointer,
                                        false
                                    )
                                }
                            }
                        }
                    }
                    if Thread.isMainThread {
                        finish()
                    } else {
                        DispatchQueue.main.async(execute: finish)
                    }
                }

                guard let pasteboard = GhosttyPasteboardHelper.pasteboard(for: location) else {
                    completeClipboardRequest(with: "")
                    return
                }

                switch TerminalPasteboardPlanner.plan(pasteboard: pasteboard, mode: .paste) {
                case .reject:
                    completeClipboardRequest(with: "")
                case .insertText(let text):
                    completeClipboardRequest(with: text)
                }
            }
        }

        return true
    }

    let backgroundLogEnabled = {
        if ProcessInfo.processInfo.environment["PROGRAMA_DEBUG_BG"] == "1" {
            return true
        }
        if ProcessInfo.processInfo.environment["PROGRAMA_DEBUG_LOG"] != nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: "programaDebugBG")
    }()
    private let backgroundLogURL = GhosttyApp.resolveBackgroundLogURL()
    private let backgroundLogStartUptime = ProcessInfo.processInfo.systemUptime
    // Guards only the cheap `backgroundLogSequence` increment below; the actual file
    // write is offloaded to `backgroundLogWriter`'s serial queue (ported from upstream
    // cmux cb2129a5a1) so callers never block on FileHandle open/seek/write/close.
    private let backgroundLogLock = NSLock()
    private var backgroundLogSequence: UInt64 = 0
    // Non-lazy: `handleAction`/`logBackground` run on Ghostty callback threads, and
    // `lazy var` initialization is not thread-safe.
    private let backgroundLogWriter: BackgroundLogWriter
    private let titleUpdateDispatcher = GhosttyTitleUpdateDispatcher()
    private var appObservers: [NSObjectProtocol] = []
    private var bellAudioSound: NSSound?
    private var backgroundEventCounter: UInt64 = 0
    private var defaultBackgroundUpdateScope: GhosttyDefaultBackgroundUpdateScope = .unscoped
    private var defaultBackgroundScopeSource: String = "initialize"
    private var lastAppearanceColorScheme: GhosttyConfig.ColorSchemePreference?
    private lazy var defaultBackgroundNotificationDispatcher: GhosttyDefaultBackgroundNotificationDispatcher =
        // Theme chrome should track terminal theme changes in the same frame.
        // Keep coalescing semantics, but flush in the next main turn instead of waiting ~1 frame.
        GhosttyDefaultBackgroundNotificationDispatcher(delay: 0, logEvent: { [weak self] message in
            guard let self, self.backgroundLogEnabled else { return }
            self.logBackground(message)
        })

    private init() {
        backgroundLogWriter = BackgroundLogWriter(url: backgroundLogURL)
        initializeGhostty()
    }

    #if DEBUG
    private static let initLogPath = "/tmp/programa-ghostty-init.log"

    private static func initLog(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        if let handle = FileHandle(forWritingAtPath: initLogPath) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            handle.closeFile()
        } else {
            _ = FileManager.default.createFile(atPath: initLogPath, contents: line.data(using: .utf8))
        }
    }

    private static func dumpConfigDiagnostics(_ config: ghostty_config_t, label: String) {
        let count = Int(ghostty_config_diagnostics_count(config))
        guard count > 0 else {
            initLog("ghostty diagnostics (\(label)): none")
            return
        }
        initLog("ghostty diagnostics (\(label)): count=\(count)")
        for i in 0..<count {
            let diag = ghostty_config_get_diagnostic(config, UInt32(i))
            let msg = diag.message.flatMap { String(cString: $0) } ?? "(null)"
            initLog("  [\(i)] \(msg)")
        }
    }
    #endif

    private func initializeGhostty() {
        // Ensure TUI apps can use colors even if NO_COLOR is set in the launcher env.
        if getenv("NO_COLOR") != nil {
            unsetenv("NO_COLOR")
        }

        // Initialize Ghostty library first
        let result = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
        if result != GHOSTTY_SUCCESS {
            print("Failed to initialize ghostty: \(result)")
            return
        }

        // Load config
        guard let primaryConfig = ghostty_config_new() else {
            print("Failed to create ghostty config")
            return
        }

        // Load default config (includes user config). If this fails hard (e.g. due to
        // invalid user config), ghostty_app_new may return nil; we fall back below.
        loadDefaultConfigFilesWithLegacyFallback(primaryConfig)
        updateDefaultBackground(from: primaryConfig, source: "initialize.primaryConfig")

        // Create runtime config with callbacks
        var runtimeConfig = ghostty_runtime_config_s()
        runtimeConfig.userdata = Unmanaged.passUnretained(self).toOpaque()
        runtimeConfig.supports_selection_clipboard = true
        runtimeConfig.wakeup_cb = { userdata in
            GhosttyApp.shared.scheduleTick()
        }
        runtimeConfig.action_cb = { app, target, action in
            return GhosttyApp.shared.handleAction(target: target, action: action)
        }
        runtimeConfig.read_clipboard_cb = programaRuntimeReadClipboardCallback
        runtimeConfig.confirm_read_clipboard_cb = { userdata, content, state, kind in
            guard let content else { return }
            guard let state else { return }
            let requestState = GhosttyClipboardRequestState(pointer: state)
            guard let callbackContext = GhosttyApp.callbackContext(from: userdata) else { return }
            let callbackSurfaceId = callbackContext.surfaceId
            let callbackTabId = callbackContext.tabId
            guard let originatingSurfaceIdentity = GhosttyClipboardRequestIdentityRegistry.identity(
                for: requestState
            ) else { return }
            // Snapshot the C string while it is valid. Recognized provenance comes
            // only from our main-actor completion above: pinned Ghostty invokes
            // confirmation synchronously before that completion returns.
            let contentString = String(cString: content)

            MainActor.assumeIsolated { () -> Void in
                guard let terminalSurface = GhosttyApp.resolveTerminalSurface(
                    tabId: callbackTabId,
                    surfaceId: callbackSurfaceId
                ), let surface = terminalSurface.liveSurfaceForGhosttyAccess(reason: "clipboard.confirm") else { return }
                guard GhosttyRuntimeSurfaceIdentity(surface) == originatingSurfaceIdentity else { return }
                // Register ownership before the presentation hop, so teardown can
                // complete this request while the native surface is still alive.
                GhosttyApp.handleClipboardConfirmation(
                    contents: contentString,
                    kind: kind,
                    window: terminalSurface.hostedView.window,
                    surface: surface
                ) { confirmedContent in
                    confirmedContent.withCString { ptr in
                        ghostty_surface_complete_clipboard_request(
                            surface,
                            ptr,
                            requestState.pointer,
                            true
                        )
                    }
                }
            }
        }
        runtimeConfig.write_clipboard_cb = { _, location, content, len, _ in
            // Write clipboard
            guard let content = content, len > 0 else { return }
            let buffer = UnsafeBufferPointer(start: content, count: Int(len))

            var fallback: String?
            for item in buffer {
                guard let dataPtr = item.data else { continue }
                let value = String(cString: dataPtr)

                if let mimePtr = item.mime {
                    let mime = String(cString: mimePtr)
                    if mime.hasPrefix("text/plain") {
                        GhosttyPasteboardHelper.writeString(value, to: location)
                        return
                    }
                }

                if fallback == nil {
                    fallback = value
                }
            }

            if let fallback {
                GhosttyPasteboardHelper.writeString(fallback, to: location)
            }
        }
        runtimeConfig.close_surface_cb = { userdata, needsConfirmClose in
            guard let callbackContext = GhosttyApp.callbackContext(from: userdata) else { return }
            let callbackSurfaceId = callbackContext.surfaceId
            let callbackTabId = callbackContext.tabId

#if DEBUG
            programaWriteChildExitProbe(
                [
                    "probeCloseSurfaceNeedsConfirm": needsConfirmClose ? "1" : "0",
                    "probeCloseSurfaceTabId": callbackTabId?.uuidString ?? "",
                    "probeCloseSurfaceSurfaceId": callbackSurfaceId.uuidString,
                ],
                increments: ["probeCloseSurfaceCbCount": 1]
            )
#endif

            DispatchQueue.main.async {
                guard let app = AppDelegate.shared else { return }
                // Close requests must be resolved by the callback's workspace/surface IDs only.
                // If the mapping is already gone (duplicate/stale callback), ignore it.
                if let callbackTabId,
                   let manager = app.tabManagerFor(tabId: callbackTabId) ?? app.tabManager,
                   let workspace = manager.tabs.first(where: { $0.id == callbackTabId }),
                   workspace.panels[callbackSurfaceId] != nil {
                    if needsConfirmClose {
                        manager.closeRuntimeSurfaceWithConfirmation(
                            tabId: callbackTabId,
                            surfaceId: callbackSurfaceId
                        )
                    } else {
                        manager.closeRuntimeSurface(
                            tabId: callbackTabId,
                            surfaceId: callbackSurfaceId
                        )
                    }
                }
            }
        }

        // Create app
        if let created = ghostty_app_new(&runtimeConfig, primaryConfig) {
            self.app = created
            self.config = primaryConfig
        } else {
            #if DEBUG
            Self.initLog("ghostty_app_new(primary) failed; attempting fallback config")
            Self.dumpConfigDiagnostics(primaryConfig, label: "primary")
            #endif

            // If the user config is invalid, prefer a minimal fallback configuration so
            // cmux still launches with working terminals.
            ghostty_config_free(primaryConfig)

            guard let fallbackConfig = ghostty_config_new() else {
                print("Failed to create ghostty fallback config")
                return
            }

            loadInlineGhosttyConfig(
                "macos-background-from-layer = true",
                into: fallbackConfig,
                prefix: "cmux-layer-bg",
                logLabel: "layer background (fallback)"
            )
            usesHostLayerBackground = true
            ghostty_config_finalize(fallbackConfig)
            updateDefaultBackground(from: fallbackConfig, source: "initialize.fallbackConfig")

            guard let created = ghostty_app_new(&runtimeConfig, fallbackConfig) else {
                #if DEBUG
                Self.initLog("ghostty_app_new(fallback) failed")
                Self.dumpConfigDiagnostics(fallbackConfig, label: "fallback")
                #endif
                print("Failed to create ghostty app")
                ghostty_config_free(fallbackConfig)
                return
            }

            self.app = created
            self.config = fallbackConfig
        }

        // Notify observers that a usable config is available (initial load).
        lastAppearanceColorScheme = GhosttyConfig.currentColorSchemePreference()
        NotificationCenter.default.post(name: .ghosttyConfigDidReload, object: nil)

        #if os(macOS)
        if let app {
            ghostty_app_set_focus(app, NSApp.isActive)
        }

        appObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let app = self?.app else { return }
            ghostty_app_set_focus(app, true)
        })

        appObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let app = self?.app else { return }
            ghostty_app_set_focus(app, false)
        })

        #endif
    }

    private func loadInlineGhosttyConfig(
        _ contents: String,
        into config: ghostty_config_t,
        prefix: String,
        logLabel: String
    ) {
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString).conf")
        do {
            try trimmed.write(to: tmpURL, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: tmpURL) }
            tmpURL.path.withCString { path in
                ghostty_config_load_file(config, path)
            }
        } catch {
            #if DEBUG
            dlog("ghostty.config.inlineLoad.failed label=\(logLabel) error=\(error.localizedDescription)")
            #endif
        }
    }

    private func hasConfiguredBackgroundImage(_ config: ghostty_config_t) -> Bool {
        var backgroundImage: UnsafePointer<Int8>?
        let key = "background-image"
        guard ghostty_config_get(config, &backgroundImage, key, UInt(key.lengthOfBytes(using: .utf8))),
              let backgroundImage else {
            return false
        }

        return !String(cString: backgroundImage).isEmpty
    }

    private func loadDefaultConfigFilesWithLegacyFallback(_ config: ghostty_config_t) {
        // The card layout rounds the terminal card to a corner concentric with
        // the window (18pt); ghostty's stock window-padding (2) lets glyphs sit
        // inside that curve at the card's bottom corners. Loaded BEFORE the
        // user's config files so any user-set window-padding still wins.
        // Matches the card layout's own gate: glass available AND Reduce
        // Transparency off -- without the rounded card there is no curve to
        // clear, so don't spend viewport on padding.
        if WindowGlassEffect.isAvailable,
           !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            loadInlineGhosttyConfig(
                "window-padding-x = 8\nwindow-padding-y = 8",
                into: config,
                prefix: "programa-card-padding",
                logLabel: "card layout padding default"
            )
        }
        ghostty_config_load_default_files(config)
        loadLegacyGhosttyConfigIfNeeded(config)
        ghostty_config_load_recursive_files(config)
        loadProgramaAppSupportGhosttyConfigIfNeeded(config)
        loadCJKFontFallbackIfNeeded(config)
        let useHostLayerBackground = !hasConfiguredBackgroundImage(config)
        usesHostLayerBackground = useHostLayerBackground
        if !useHostLayerBackground {
            // Background images need Ghostty's fullscreen background pass. Force
            // the layer-backed solid-color shortcut back off even if the user
            // config enabled it manually.
            loadInlineGhosttyConfig(
                "macos-background-from-layer = false",
                into: config,
                prefix: "cmux-layer-bg-image-override",
                logLabel: "layer background image override"
            )
        } else {
            // cmux provides the terminal background via backgroundView (CALayer)
            // instead of the GPU full-screen bg pass, so the layer can provide
            // instant coverage during sidebar toggle and other layout transitions.
            //
            // Keep Ghostty's native background rendering when a background image
            // is configured: the separate CALayer background only matches the
            // solid-color path, not Ghostty's combined image compositing.
            loadInlineGhosttyConfig(
                "macos-background-from-layer = true",
                into: config,
                prefix: "cmux-layer-bg",
                logLabel: "layer background"
            )
        }
        ghostty_config_finalize(config)
    }

    /// When the user has not configured `font-codepoint-map` for CJK ranges
    /// and has not already provided an explicit multi-entry `font-family`
    /// fallback chain, Ghostty's `CTFontCollection` scoring may pick an
    /// inappropriate fallback font for Hiragana, Katakana, and CJK symbols.
    /// The scoring prioritizes monospace fonts, so decorative fonts with
    /// monospace attributes (e.g. AB_appare from Adobe CC, or LingWai) can be
    /// selected depending on what is installed. This injects a sensible
    /// default based on the system's preferred languages without overriding
    /// user-managed fallback chains or configured fonts that already cover
    /// the affected CJK ranges.
    ///
    /// See: https://github.com/manaflow-ai/cmux/pull/1017
    private func loadCJKFontFallbackIfNeeded(_ config: ghostty_config_t) {
        guard let mappings = Self.autoInjectedCJKFontMappings() else { return }

        let lines = mappings.map { range, font in
            "font-codepoint-map = \(range)=\(font)"
        }.joined(separator: "\n")
        loadInlineGhosttyConfig(
            lines,
            into: config,
            prefix: "cmux-cjk-font-fallback",
            logLabel: "CJK font fallback"
        )
    }

    /// Unicode ranges shared by all CJK languages (Han ideographs, symbols, fullwidth forms).
    private static let sharedCJKRanges = [
        "U+3000-U+303F",  // CJK Symbols and Punctuation
        "U+4E00-U+9FFF",  // CJK Unified Ideographs
        "U+F900-U+FAFF",  // CJK Compatibility Ideographs
        "U+FF00-U+FFEF",  // Halfwidth and Fullwidth Forms
        "U+3400-U+4DBF",  // CJK Unified Ideographs Extension A
    ]

    /// Unicode ranges specific to Japanese (kana).
    private static let japaneseRanges = [
        "U+3040-U+309F",  // Hiragana
        "U+30A0-U+30FF",  // Katakana
    ]

    /// Representative scalars used to detect whether the configured primary
    /// font already covers the ranges cmux would otherwise auto-map.
    private static let cjkCoverageSampleCharactersByRange: [String: [UniChar]] = [
        "U+3000-U+303F": [0x3001, 0x300C],
        "U+4E00-U+9FFF": [0x4E00, 0x65E5, 0x6C34],
        "U+F900-U+FAFF": [0xF900],
        "U+FF00-U+FFEF": [0xFF10, 0xFF21],
        "U+3400-U+4DBF": [0x3400],
        "U+1100-U+11FF": [0x1100, 0x1161],
        "U+3130-U+318F": [0x3131, 0x314F],
        "U+3040-U+309F": [0x3042, 0x3093],
        "U+30A0-U+30FF": [0x30A2, 0x30F3],
        "U+AC00-U+D7AF": [0xAC00, 0xD55C],
    ]

    private struct UserFontConfigSummary {
        var containsCodepointMap = false
        var effectiveFontFamilies: [String] = []

        var hasExplicitFontFamilyFallbackChain: Bool {
            effectiveFontFamilies.count > 1
        }

        mutating func applyFontCodepointMap(_ value: String) {
            if value.isEmpty {
                containsCodepointMap = false
                return
            }

            guard value.contains("=") else {
                return
            }

            containsCodepointMap = true
        }

        mutating func recordFontFamily(_ value: String) {
            if value.isEmpty {
                effectiveFontFamilies.removeAll()
                return
            }

            guard !effectiveFontFamilies.contains(value) else {
                return
            }

            effectiveFontFamilies.append(value)
        }
    }

    /// Returns (range, font) pairs for CJK font fallback based on the system's
    /// preferred languages, or nil if no CJK language is detected. Each language
    /// only maps its own script ranges to avoid assigning glyphs to a font that
    /// lacks coverage (e.g. Hangul to Hiragino Sans).
    static func cjkFontMappings(
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> [(String, String)]? {
        var mappings: [(String, String)] = []
        var coveredShared = false

        for lang in preferredLanguages {
            let lower = lang.lowercased()
            let font: String
            var langRanges: [String] = []

            if lower.hasPrefix("ja") {
                font = "Hiragino Sans"
                langRanges = japaneseRanges
            } else if lower.hasPrefix("zh-hant") || lower.hasPrefix("zh-tw") || lower.hasPrefix("zh-hk") {
                font = "PingFang TC"
            } else if lower.hasPrefix("zh") {
                font = "PingFang SC"
            } else {
                continue
            }

            if !coveredShared {
                for range in sharedCJKRanges {
                    mappings.append((range, font))
                }
                coveredShared = true
            }

            for range in langRanges {
                mappings.append((range, font))
            }
        }

        return mappings.isEmpty ? nil : mappings
    }

    /// Returns only the CJK mappings cmux should auto-inject after respecting
    /// explicit user overrides and the glyph coverage of the configured
    /// primary font family.
    static func autoInjectedCJKFontMappings(
        preferredLanguages: [String] = Locale.preferredLanguages,
        configPaths: [String] = loadedCJKScanPaths(),
        rangeCoverageProbe: ((String, String) -> Bool)? = nil
    ) -> [(String, String)]? {
        guard var mappings = cjkFontMappings(preferredLanguages: preferredLanguages) else { return nil }

        let summary = userFontConfigSummary(configPaths: configPaths)
        if summary.containsCodepointMap || summary.hasExplicitFontFamilyFallbackChain {
            return nil
        }

        guard let configuredFontFamily = summary.effectiveFontFamilies.first else {
            return mappings
        }

        if let rangeCoverageProbe {
            mappings.removeAll { range, _ in
                rangeCoverageProbe(configuredFontFamily, range)
            }
        } else if let configuredFont = configuredCTFont(named: configuredFontFamily) {
            mappings.removeAll { range, _ in
                fontContainsGlyphs(configuredFont, forRange: range)
            }
        }

        return mappings.isEmpty ? nil : mappings
    }

    /// Checks whether the user's Ghostty config files already contain
    /// a `font-codepoint-map` entry covering CJK ranges. Also checks
    /// application-support config paths that cmux may load at runtime.
    static func userConfigContainsCJKCodepointMap(
        configPaths: [String] = loadedCJKScanPaths()
    ) -> Bool {
        userFontConfigSummary(configPaths: configPaths).containsCodepointMap
    }

    static func userConfigHasExplicitFontFamilyFallbackChain(
        configPaths: [String] = loadedCJKScanPaths()
    ) -> Bool {
        userFontConfigSummary(configPaths: configPaths).hasExplicitFontFamilyFallbackChain
    }

    static func shouldInjectCJKFontFallback(
        preferredLanguages: [String] = Locale.preferredLanguages,
        configPaths: [String] = loadedCJKScanPaths(),
        rangeCoverageProbe: ((String, String) -> Bool)? = nil
    ) -> Bool {
        autoInjectedCJKFontMappings(
            preferredLanguages: preferredLanguages,
            configPaths: configPaths,
            rangeCoverageProbe: rangeCoverageProbe
        ) != nil
    }

    private static func configuredCTFont(
        named name: String,
        size: CGFloat = 12
    ) -> CTFont? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let font = CTFontCreateWithName(trimmed as CFString, size, nil)
        let normalizedRequestedName = normalizedFontName(trimmed)
        let resolvedNames = [
            kCTFontFamilyNameKey,
            kCTFontFullNameKey,
            kCTFontPostScriptNameKey,
        ].compactMap { CTFontCopyName(font, $0) as String? }

        guard resolvedNames.contains(where: { normalizedFontName($0) == normalizedRequestedName }) else {
            return nil
        }

        return font
    }

    private static func fontContainsGlyphs(
        _ font: CTFont,
        forRange range: String
    ) -> Bool {
        guard let characters = cjkCoverageSampleCharactersByRange[range] else {
            return false
        }

        var glyphs = Array(repeating: CGGlyph(), count: characters.count)
        let hasGlyphs = CTFontGetGlyphsForCharacters(font, characters, &glyphs, characters.count)
        return hasGlyphs && !glyphs.contains(0)
    }

    private static func normalizedFontName(_ name: String) -> String {
        name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
    }

    private static func userFontConfigSummary(
        configPaths: [String] = loadedCJKScanPaths()
    ) -> UserFontConfigSummary {
        var summary = UserFontConfigSummary()
        var recursiveConfigPaths: [String] = []

        for path in configPaths.map({ NSString(string: $0).expandingTildeInPath }) {
            scanFontConfigFile(
                atPath: path,
                summary: &summary,
                recursiveConfigPaths: &recursiveConfigPaths
            )
        }

        var loadedRecursivePaths = Set<String>()
        var index = 0
        while index < recursiveConfigPaths.count {
            let path = recursiveConfigPaths[index]
            index += 1
            let resolved = (path as NSString).standardizingPath
            guard !loadedRecursivePaths.contains(resolved) else { continue }
            loadedRecursivePaths.insert(resolved)

            scanFontConfigFile(
                atPath: path,
                summary: &summary,
                recursiveConfigPaths: &recursiveConfigPaths
            )
        }

        return summary
    }

    /// Returns the top-level config paths that cmux will actually load before
    /// recursive `config-file` processing.
    static func loadedCJKScanPaths(
        currentBundleIdentifier: String? = Bundle.main.bundleIdentifier,
        appSupportDirectory: URL? = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first
    ) -> [String] {
        var paths = [
            "~/.config/ghostty/config",
            "~/.config/ghostty/config.ghostty",
        ]

        guard let bundleId = currentBundleIdentifier,
              !bundleId.isEmpty,
              let appSupportDirectory else { return paths }

        let appSupportConfigURLs = cmuxAppSupportConfigURLs(
            currentBundleIdentifier: bundleId,
            appSupportDirectory: appSupportDirectory
        )
        paths.append(contentsOf: appSupportConfigURLs.map(\.path))

        let releaseDir = appSupportDirectory.appendingPathComponent(releaseBundleIdentifier, isDirectory: true)
        let releaseLegacyConfig = releaseDir.appendingPathComponent("config", isDirectory: false)
        let releaseConfig = releaseDir.appendingPathComponent("config.ghostty", isDirectory: false)

        let releaseConfigSize = configFileSize(at: releaseConfig)
        let releaseLegacyConfigSize = configFileSize(at: releaseLegacyConfig)

        if shouldLoadLegacyGhosttyConfig(
            newConfigFileSize: releaseConfigSize,
            legacyConfigFileSize: releaseLegacyConfigSize
        ), !paths.contains(releaseLegacyConfig.path) {
            paths.append(releaseLegacyConfig.path)
        }

        return paths
    }

    private static func configFileSize(at url: URL) -> Int? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else { return nil }
        return size.intValue
    }

    /// Scans a single config file for font settings relevant to cmux's
    /// injected CJK fallback and updates the pending recursive config-file
    /// queue using Ghostty's repeatable path semantics.
    private static func scanFontConfigFile(
        atPath path: String,
        summary: inout UserFontConfigSummary,
        recursiveConfigPaths: inout [String]
    ) {
        let resolved = (path as NSString).standardizingPath
        guard let contents = try? String(contentsOfFile: resolved, encoding: .utf8) else {
            return
        }
        let parentDir = (resolved as NSString).deletingLastPathComponent

        for line in contents.components(separatedBy: .newlines) {
            guard let entry = parsedConfigEntry(from: line) else { continue }

            switch entry.key {
            case "font-codepoint-map":
                guard let value = entry.value else { continue }
                summary.applyFontCodepointMap(value)
            case "font-family":
                guard let value = entry.value else { continue }
                summary.recordFontFamily(value)
            case "config-file":
                guard let value = entry.value else { continue }
                applyConfigFileDirective(
                    value,
                    parentDir: parentDir,
                    recursiveConfigPaths: &recursiveConfigPaths
                )
            default:
                continue
            }
        }
    }

    private static func parsedConfigEntry(
        from rawLine: String
    ) -> (key: String, value: String?)? {
        var trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("\u{FEFF}") {
            trimmed.removeFirst()
        }
        if trimmed.isEmpty || trimmed.hasPrefix("#") { return nil }

        guard let separatorIndex = trimmed.firstIndex(of: "=") else {
            return (trimmed.trimmingCharacters(in: .whitespacesAndNewlines), nil)
        }

        let key = trimmed[..<separatorIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        var value = trimmed[trimmed.index(after: separatorIndex)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
            value.removeFirst()
            value.removeLast()
        }

        return (String(key), String(value))
    }

    private static func applyConfigFileDirective(
        _ value: String,
        parentDir: String,
        recursiveConfigPaths: inout [String]
    ) {
        if value.isEmpty {
            recursiveConfigPaths.removeAll()
            return
        }

        var includePath = value
        if includePath.hasPrefix("?") {
            includePath.removeFirst()
        }
        if includePath.count >= 2, includePath.hasPrefix("\""), includePath.hasSuffix("\"") {
            includePath.removeFirst()
            includePath.removeLast()
        }
        guard !includePath.isEmpty else { return }

        let expanded = NSString(string: includePath).expandingTildeInPath
        let absolute = (expanded as NSString).isAbsolutePath
            ? expanded
            : (parentDir as NSString).appendingPathComponent(expanded)
        recursiveConfigPaths.append(absolute)
    }

    static func shouldLoadLegacyGhosttyConfig(
        newConfigFileSize: Int?,
        legacyConfigFileSize: Int?
    ) -> Bool {
        guard let newConfigFileSize, newConfigFileSize == 0 else { return false }
        guard let legacyConfigFileSize, legacyConfigFileSize > 0 else { return false }
        return true
    }

    static func cmuxAppSupportConfigURLs(
        currentBundleIdentifier: String?,
        appSupportDirectory: URL,
        fileManager: FileManager = .default
    ) -> [URL] {
        guard let currentBundleIdentifier, !currentBundleIdentifier.isEmpty else { return [] }

        func existingConfigURLs(for bundleIdentifier: String) -> [URL] {
            let directory = appSupportDirectory.appendingPathComponent(bundleIdentifier, isDirectory: true)
            return [
                directory.appendingPathComponent("config", isDirectory: false),
                directory.appendingPathComponent("config.ghostty", isDirectory: false)
            ].filter { url in
                guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
                      let type = attrs[.type] as? FileAttributeType,
                      type == .typeRegular,
                      let size = attrs[.size] as? NSNumber else {
                    return false
                }
                return size.intValue > 0
            }
        }

        let currentURLs = existingConfigURLs(for: currentBundleIdentifier)
        if !currentURLs.isEmpty {
            return currentURLs
        }
        if SocketControlSettings.isDebugLikeBundleIdentifier(currentBundleIdentifier) {
            let releaseURLs = existingConfigURLs(for: releaseBundleIdentifier)
            if !releaseURLs.isEmpty {
                return releaseURLs
            }
        }
        return []
    }

    static func shouldApplyDefaultBackgroundUpdate(
        currentScope: GhosttyDefaultBackgroundUpdateScope,
        incomingScope: GhosttyDefaultBackgroundUpdateScope
    ) -> Bool {
        incomingScope.rawValue >= currentScope.rawValue
    }

    static func shouldReloadConfigurationForAppearanceChange(
        previousColorScheme: GhosttyConfig.ColorSchemePreference?,
        currentColorScheme: GhosttyConfig.ColorSchemePreference
    ) -> Bool {
        previousColorScheme != currentColorScheme
    }

    private func loadProgramaAppSupportGhosttyConfigIfNeeded(_ config: ghostty_config_t) {
        #if os(macOS)
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        guard let currentBundleIdentifier = Bundle.main.bundleIdentifier,
              !currentBundleIdentifier.isEmpty else { return }
        let urls = Self.cmuxAppSupportConfigURLs(
            currentBundleIdentifier: currentBundleIdentifier,
            appSupportDirectory: appSupport,
            fileManager: fm
        )
        guard !urls.isEmpty else { return }

        for url in urls {
            url.path.withCString { path in
                ghostty_config_load_file(config, path)
            }
        }

#if DEBUG
        dlog(
            "loaded cmux app support ghostty config from: \(urls.map(\.path).joined(separator: ", "))"
        )
#endif
        #endif
    }

    private func loadLegacyGhosttyConfigIfNeeded(_ config: ghostty_config_t) {
        #if os(macOS)
        // Ghostty 1.3+ prefers `config.ghostty`, but some users still have their real
        // settings in the legacy `config` file. If the new file exists but is empty,
        // load the legacy file as a compatibility fallback.
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let ghosttyDir = appSupport.appendingPathComponent("com.mitchellh.ghostty", isDirectory: true)
        let configNew = ghosttyDir.appendingPathComponent("config.ghostty", isDirectory: false)
        let configLegacy = ghosttyDir.appendingPathComponent("config", isDirectory: false)

        func fileSize(_ url: URL) -> Int? {
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let size = attrs[.size] as? NSNumber else { return nil }
            return size.intValue
        }

        guard Self.shouldLoadLegacyGhosttyConfig(
            newConfigFileSize: fileSize(configNew),
            legacyConfigFileSize: fileSize(configLegacy)
        ) else { return }

        configLegacy.path.withCString { path in
            ghostty_config_load_file(config, path)
        }

        #if DEBUG
        Self.initLog("loaded legacy ghostty config because config.ghostty was empty: \(configLegacy.path)")
        #endif
        #endif
    }

    /// Schedule a single tick on the main queue, coalescing multiple wakeups.
    func scheduleTick() {
        _tickLock.lock()
        defer { _tickLock.unlock() }
        guard !_tickScheduled else { return }
        _tickScheduled = true
        DispatchQueue.main.async {
            self.tick()
        }
    }

    func tick() {
        _tickLock.lock()
        _tickScheduled = false
        _tickLock.unlock()

        guard let app = app else { return }

        ghostty_app_tick(app)
    }

    func reloadConfiguration(
        soft: Bool = false,
        source: String = "unspecified",
        reloadSettingsFromFile: Bool = true
    ) {
        if reloadSettingsFromFile {
            KeyboardShortcutSettings.settingsFileStore.reload()
        }
        guard let app else {
            logThemeAction("reload skipped source=\(source) soft=\(soft) reason=no_app")
            return
        }
        logThemeAction("reload begin source=\(source) soft=\(soft)")
        resetDefaultBackgroundUpdateScope(source: "reloadConfiguration(source=\(source))")
        if soft, let config {
            ghostty_app_update_config(app, config)
            lastAppearanceColorScheme = GhosttyConfig.currentColorSchemePreference()
            NotificationCenter.default.post(name: .ghosttyConfigDidReload, object: nil)
            scheduleSurfaceRefreshAfterConfigurationReload(source: source)
            logThemeAction("reload end source=\(source) soft=\(soft) mode=soft")
            return
        }

        guard let newConfig = ghostty_config_new() else {
            logThemeAction("reload skipped source=\(source) soft=\(soft) reason=config_alloc_failed")
            return
        }
        loadDefaultConfigFilesWithLegacyFallback(newConfig)
        ghostty_app_update_config(app, newConfig)
        updateDefaultBackground(
            from: newConfig,
            source: "reloadConfiguration(source=\(source))",
            scope: .unscoped
        )
        DispatchQueue.main.async {
            self.applyBackgroundToKeyWindow()
        }
        if let oldConfig = config {
            ghostty_config_free(oldConfig)
        }
        config = newConfig
        lastAppearanceColorScheme = GhosttyConfig.currentColorSchemePreference()
        NotificationCenter.default.post(name: .ghosttyConfigDidReload, object: nil)
        scheduleSurfaceRefreshAfterConfigurationReload(source: source)
        logThemeAction("reload end source=\(source) soft=\(soft) mode=full")
    }

    private func scheduleSurfaceRefreshAfterConfigurationReload(source: String) {
        DispatchQueue.main.async {
            AppDelegate.shared?.refreshTerminalSurfacesAfterGhosttyConfigReload(source: source)
        }
    }

    func synchronizeThemeWithAppearance(_ appearance: NSAppearance?, source: String) {
        let currentColorScheme = GhosttyConfig.currentColorSchemePreference(
            appAppearance: appearance ?? NSApp?.effectiveAppearance
        )
        let shouldReload = Self.shouldReloadConfigurationForAppearanceChange(
            previousColorScheme: lastAppearanceColorScheme,
            currentColorScheme: currentColorScheme
        )
        if backgroundLogEnabled {
            let previousLabel: String
            switch lastAppearanceColorScheme {
            case .light:
                previousLabel = "light"
            case .dark:
                previousLabel = "dark"
            case nil:
                previousLabel = "nil"
            }
            let currentLabel: String = currentColorScheme == .dark ? "dark" : "light"
            logBackground(
                "appearance sync source=\(source) previous=\(previousLabel) current=\(currentLabel) reload=\(shouldReload)"
            )
        }
        guard shouldReload else { return }
        lastAppearanceColorScheme = currentColorScheme
        reloadConfiguration(
            source: "appearanceSync:\(source)",
            reloadSettingsFromFile: false
        )
    }

    func openConfigurationInTextEdit() {
        #if os(macOS)
        let path = ghosttyStringValue(ghostty_config_open_path())
        guard !path.isEmpty else { return }
        let fileURL = URL(fileURLWithPath: path)
        let editorURL = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([fileURL], withApplicationAt: editorURL, configuration: configuration)
        #endif
    }

    private func ghosttyStringValue(_ value: ghostty_string_s) -> String {
        defer { ghostty_string_free(value) }
        guard let ptr = value.ptr, value.len > 0 else { return "" }
        let rawPtr = UnsafeRawPointer(ptr).assumingMemoryBound(to: UInt8.self)
        let buffer = UnsafeBufferPointer(start: rawPtr, count: Int(value.len))
        return String(decoding: buffer, as: UTF8.self)
    }

    private func resetDefaultBackgroundUpdateScope(source: String) {
        let previousScope = defaultBackgroundUpdateScope
        let previousScopeSource = defaultBackgroundScopeSource
        defaultBackgroundUpdateScope = .unscoped
        defaultBackgroundScopeSource = "reset:\(source)"
        if backgroundLogEnabled {
            logBackground(
                "default background scope reset source=\(source) previousScope=\(previousScope.logLabel) previousSource=\(previousScopeSource)"
            )
        }
    }

    private func updateDefaultBackground(
        from config: ghostty_config_t?,
        source: String,
        scope: GhosttyDefaultBackgroundUpdateScope = .unscoped
    ) {
        guard let config else { return }

        var resolvedColor = defaultBackgroundColor
        var color = ghostty_config_color_s()
        let bgKey = "background"
        if ghostty_config_get(config, &color, bgKey, UInt(bgKey.lengthOfBytes(using: .utf8))) {
            resolvedColor = NSColor(
                red: CGFloat(color.r) / 255,
                green: CGFloat(color.g) / 255,
                blue: CGFloat(color.b) / 255,
                alpha: 1.0
            )
        }

        var opacity = defaultBackgroundOpacity
        let opacityKey = "background-opacity"
        _ = ghostty_config_get(config, &opacity, opacityKey, UInt(opacityKey.lengthOfBytes(using: .utf8)))
        opacity = min(1.0, max(0.0, opacity))
        applyDefaultBackground(
            color: resolvedColor,
            opacity: opacity,
            source: source,
            scope: scope
        )
    }

    func focusFollowsMouseEnabled() -> Bool {
        guard let config else { return false }
        var enabled = false
        let key = "focus-follows-mouse"
        let keyLength = UInt(key.lengthOfBytes(using: .utf8))
        let found = ghostty_config_get(config, &enabled, key, keyLength)
        return found && enabled
    }

    func shellIntegrationMode() -> String {
        guard let config else { return "detect" }
        var value: UnsafePointer<Int8>?
        let key = "shell-integration"
        guard ghostty_config_get(config, &value, key, UInt(key.lengthOfBytes(using: .utf8))),
              let value else {
            return "detect"
        }
        return String(cString: value)
    }

    private func bellFeatures() -> CUnsignedInt {
        guard let config else { return 0 }
        var features: CUnsignedInt = 0
        let key = "bell-features"
        _ = ghostty_config_get(config, &features, key, UInt(key.lengthOfBytes(using: .utf8)))
        return features
    }

    private func bellAudioPath() -> String? {
        guard let config else { return nil }
        var value: UnsafePointer<Int8>?
        let key = "bell-audio-path"
        guard ghostty_config_get(config, &value, key, UInt(key.lengthOfBytes(using: .utf8))),
              let rawPath = value else {
            return nil
        }
        let path = String(cString: rawPath)
        return path.isEmpty ? nil : path
    }

    private func bellAudioVolume() -> Float {
        guard let config else { return 0.5 }
        var value: Double = 0.5
        let key = "bell-audio-volume"
        _ = ghostty_config_get(config, &value, key, UInt(key.lengthOfBytes(using: .utf8)))
        return Float(min(1.0, max(0.0, value)))
    }

    private func ringBell() {
        let features = bellFeatures()

        if (features & (1 << 0)) != 0 {
            NSSound.beep()
        }

        if (features & (1 << 1)) != 0,
           let path = bellAudioPath(),
           let sound = NSSound(contentsOfFile: path, byReference: false) {
            sound.volume = bellAudioVolume()
            bellAudioSound = sound
            if !sound.play() {
                bellAudioSound = nil
            }
        }

        if (features & (1 << 2)) != 0 {
            NSApp.requestUserAttention(.informationalRequest)
        }
    }

    private func applyDefaultBackground(
        color: NSColor,
        opacity: Double,
        source: String,
        scope: GhosttyDefaultBackgroundUpdateScope
    ) {
        let previousScope = defaultBackgroundUpdateScope
        let previousScopeSource = defaultBackgroundScopeSource
        guard Self.shouldApplyDefaultBackgroundUpdate(currentScope: previousScope, incomingScope: scope) else {
            if backgroundLogEnabled {
                logBackground(
                    "default background skipped source=\(source) incomingScope=\(scope.logLabel) currentScope=\(previousScope.logLabel) currentSource=\(previousScopeSource) color=\(color.hexString()) opacity=\(String(format: "%.3f", opacity))"
                )
            }
            return
        }

        defaultBackgroundUpdateScope = scope
        defaultBackgroundScopeSource = source

        let previousHex = defaultBackgroundColor.hexString()
        let previousOpacity = defaultBackgroundOpacity
        defaultBackgroundColor = color
        defaultBackgroundOpacity = opacity
        let hasChanged = previousHex != defaultBackgroundColor.hexString() ||
            abs(previousOpacity - defaultBackgroundOpacity) > 0.0001
        if hasChanged {
            notifyDefaultBackgroundDidChange(source: source)
        }
        if backgroundLogEnabled {
            logBackground(
                "default background updated source=\(source) scope=\(scope.logLabel) previousScope=\(previousScope.logLabel) previousScopeSource=\(previousScopeSource) previousColor=\(previousHex) previousOpacity=\(String(format: "%.3f", previousOpacity)) color=\(defaultBackgroundColor) opacity=\(String(format: "%.3f", defaultBackgroundOpacity)) changed=\(hasChanged)"
            )
        }
    }

    private func nextBackgroundEventId() -> UInt64 {
        precondition(Thread.isMainThread, "Background event IDs must be generated on main thread")
        backgroundEventCounter &+= 1
        return backgroundEventCounter
    }

    private func notifyDefaultBackgroundDidChange(source: String) {
        let signal = { [self] in
            let eventId = nextBackgroundEventId()
            defaultBackgroundNotificationDispatcher.signal(
                backgroundColor: defaultBackgroundColor,
                opacity: defaultBackgroundOpacity,
                eventId: eventId,
                source: source
            )
        }
        if Thread.isMainThread {
            signal()
        } else {
            DispatchQueue.main.async(execute: signal)
        }
    }

    private func logThemeAction(_ message: String) {
        guard backgroundLogEnabled else { return }
        logBackground("theme action \(message)")
    }

    private func actionLabel(for action: ghostty_action_s) -> String {
        switch action.tag {
        case GHOSTTY_ACTION_RELOAD_CONFIG:
            return "reload_config"
        case GHOSTTY_ACTION_CONFIG_CHANGE:
            return "config_change"
        case GHOSTTY_ACTION_COLOR_CHANGE:
            return "color_change"
        default:
            return String(describing: action.tag)
        }
    }

    private func logAction(_ action: ghostty_action_s, target: ghostty_target_s, tabId: UUID?, surfaceId: UUID?) {
        guard backgroundLogEnabled else { return }
        let targetLabel = target.tag == GHOSTTY_TARGET_SURFACE ? "surface" : "app"
        logBackground(
            "action event target=\(targetLabel) action=\(actionLabel(for: action)) tab=\(tabId?.uuidString ?? "nil") surface=\(surfaceId?.uuidString ?? "nil")"
        )
    }

    private func performOnMain<T>(_ work: @MainActor () -> T) -> T {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { work() }
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated { work() }
        }
    }

    private func splitDirection(from direction: ghostty_action_split_direction_e) -> SplitDirection? {
        switch direction {
        case GHOSTTY_SPLIT_DIRECTION_RIGHT: return .right
        case GHOSTTY_SPLIT_DIRECTION_LEFT: return .left
        case GHOSTTY_SPLIT_DIRECTION_DOWN: return .down
        case GHOSTTY_SPLIT_DIRECTION_UP: return .up
        default: return nil
        }
    }

    private func focusDirection(from direction: ghostty_action_goto_split_e) -> NavigationDirection? {
        switch direction {
        // For previous/next, we use left/right as a reasonable default
        // Bonsplit doesn't have cycle-based navigation
        case GHOSTTY_GOTO_SPLIT_PREVIOUS: return .left
        case GHOSTTY_GOTO_SPLIT_NEXT: return .right
        case GHOSTTY_GOTO_SPLIT_UP: return .up
        case GHOSTTY_GOTO_SPLIT_DOWN: return .down
        case GHOSTTY_GOTO_SPLIT_LEFT: return .left
        case GHOSTTY_GOTO_SPLIT_RIGHT: return .right
        default: return nil
        }
    }

    private func resizeDirection(from direction: ghostty_action_resize_split_direction_e) -> ResizeDirection? {
        switch direction {
        case GHOSTTY_RESIZE_SPLIT_UP: return .up
        case GHOSTTY_RESIZE_SPLIT_DOWN: return .down
        case GHOSTTY_RESIZE_SPLIT_LEFT: return .left
        case GHOSTTY_RESIZE_SPLIT_RIGHT: return .right
        default: return nil
        }
    }

    private static func callbackContext(from userdata: UnsafeMutableRawPointer?) -> GhosttySurfaceCallbackSnapshot? {
        GhosttySurfaceUserdataRegistry.resolve(from: userdata)
    }

    // MARK: - Main-thread-only live object resolution
    //
    // `GhosttySurfaceCallbackContext` is data-only (see its doc comment) precisely because
    // resolving live Swift UI/runtime objects must never happen on ghostty's IO thread.
    // These helpers are the ONLY place callbacks resolve a live `TerminalPanel` /
    // `TerminalSurface` / `GhosttyNSView` from a callback's `(tabId, surfaceId)` pair --
    // callers MUST invoke them from inside a main-thread hop (`performOnMain`,
    // `DispatchQueue.main.async` + `MainActor.assumeIsolated`, or a context already known
    // to be on main).
    @MainActor
    private static func resolveTerminalPanel(tabId: UUID?, surfaceId: UUID?) -> TerminalPanel? {
        guard let tabId, let surfaceId,
              let app = AppDelegate.shared,
              let manager = app.tabManagerFor(tabId: tabId) ?? app.tabManager,
              let workspace = manager.tabs.first(where: { $0.id == tabId }) else {
            return nil
        }
        return workspace.panels[surfaceId] as? TerminalPanel
    }

    @MainActor
    private static func resolveTerminalSurface(tabId: UUID?, surfaceId: UUID?) -> TerminalSurface? {
        resolveTerminalPanel(tabId: tabId, surfaceId: surfaceId)?.surface
    }

    @MainActor
    private static func resolveSurfaceView(tabId: UUID?, surfaceId: UUID?) -> GhosttyNSView? {
        resolveTerminalPanel(tabId: tabId, surfaceId: surfaceId)?.hostedView.surfaceView
    }

    @MainActor
    private static func resolveLiveSurface(tabId: UUID?, surfaceId: UUID?, reason: String) -> ghostty_surface_t? {
        resolveTerminalSurface(tabId: tabId, surfaceId: surfaceId)?.liveSurfaceForGhosttyAccess(reason: reason)
    }

    private func handleAction(target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        if target.tag != GHOSTTY_TARGET_SURFACE {
            if action.tag == GHOSTTY_ACTION_RELOAD_CONFIG ||
                action.tag == GHOSTTY_ACTION_CONFIG_CHANGE ||
                action.tag == GHOSTTY_ACTION_COLOR_CHANGE {
                logAction(action, target: target, tabId: nil, surfaceId: nil)
            }

            if action.tag == GHOSTTY_ACTION_DESKTOP_NOTIFICATION {
                let actionTitle = action.action.desktop_notification.title
                    .flatMap { String(cString: $0) } ?? ""
                let actionBody = action.action.desktop_notification.body
                    .flatMap { String(cString: $0) } ?? ""
                return performOnMain {
                    guard let tabManager = AppDelegate.shared?.tabManager,
                          let tabId = tabManager.selectedTabId else {
                        return false
                    }
                    // Suppress OSC notifications for workspaces with active hook-managed agent
                    // sessions (Claude Code, Codex, etc.). The hook system manages notifications
                    // with proper lifecycle tracking; raw OSC notifications would duplicate or
                    // outlive the structured hooks.
                    let owningManager = AppDelegate.shared?.tabManagerFor(tabId: tabId) ?? tabManager
                    if let workspace = owningManager.tabs.first(where: { $0.id == tabId }),
                       workspace.hasHookManagedAgent {
                        return true
                    }
                    let tabTitle = owningManager.titleForTab(tabId) ?? "Terminal"
                    let command = actionTitle.isEmpty ? tabTitle : actionTitle
                    let body = actionBody
                    let surfaceId = tabManager.focusedSurfaceId(for: tabId)
                    TerminalNotificationStore.shared.addNotification(
                        tabId: tabId,
                        surfaceId: surfaceId,
                        title: command,
                        subtitle: "",
                        body: body
                    )
                    return true
                }
            }

            if action.tag == GHOSTTY_ACTION_RING_BELL {
                performOnMain {
                    self.ringBell()
                }
                return true
            }

            if action.tag == GHOSTTY_ACTION_RELOAD_CONFIG {
                let soft = action.action.reload_config.soft
                logThemeAction("reload request target=app soft=\(soft)")
                performOnMain {
                    GhosttyApp.shared.reloadConfiguration(soft: soft, source: "action.reload_config.app")
                }
                return true
            }

            if action.tag == GHOSTTY_ACTION_COLOR_CHANGE,
               action.action.color_change.kind == GHOSTTY_ACTION_COLOR_KIND_BACKGROUND {
                let change = action.action.color_change
                let resolvedColor = NSColor(
                    red: CGFloat(change.r) / 255,
                    green: CGFloat(change.g) / 255,
                    blue: CGFloat(change.b) / 255,
                    alpha: 1.0
                )
                applyDefaultBackground(
                    color: resolvedColor,
                    opacity: defaultBackgroundOpacity,
                    source: "action.color_change.app",
                    scope: .app
                )
                DispatchQueue.main.async {
                    GhosttyApp.shared.applyBackgroundToKeyWindow()
                }
                return true
            }

            if action.tag == GHOSTTY_ACTION_CONFIG_CHANGE {
                updateDefaultBackground(
                    from: action.action.config_change.config,
                    source: "action.config_change.app",
                    scope: .app
                )
                DispatchQueue.main.async {
                    GhosttyApp.shared.applyBackgroundToKeyWindow()
                }
                return true
            }

            return false
        }
        let callbackContext = Self.callbackContext(from: ghostty_surface_userdata(target.target.surface))
        let callbackTabId = callbackContext?.tabId
        let callbackSurfaceId = callbackContext?.surfaceId

        if action.tag == GHOSTTY_ACTION_SHOW_CHILD_EXITED {
            // The child (shell) exited. Ghostty will fall back to printing
            // "Process exited. Press any key..." into the terminal unless the host
            // handles this action. For cmux, the correct behavior is to close
            // the panel immediately (no prompt).
#if DEBUG
            dlog(
                "surface.action.showChildExited tab=\(callbackTabId?.uuidString.prefix(5) ?? "nil") " +
                "surface=\(callbackSurfaceId?.uuidString.prefix(5) ?? "nil")"
            )
#endif
#if DEBUG
            programaWriteChildExitProbe(
                [
                    "probeShowChildExitedTabId": callbackTabId?.uuidString ?? "",
                    "probeShowChildExitedSurfaceId": callbackSurfaceId?.uuidString ?? "",
                ],
                increments: ["probeShowChildExitedCount": 1]
            )
#endif
            // Keep host-close async to avoid re-entrant close/deinit while Ghostty is still
            // dispatching this action callback.
            DispatchQueue.main.async {
                // #166: fire any `surface.wait exit=true` watchers before (or even if) the panel
                // close below happens -- always on main, same as `addWaiter`/removeWaiter, so
                // ordering against a concurrently-arriving `surface.wait` call is well-defined
                // (see SurfaceExitWaitRegistry's doc comment).
                if let callbackSurfaceId {
                    SurfaceExitWaitRegistry.shared.fire(surfaceId: callbackSurfaceId)
                }
                guard let app = AppDelegate.shared else { return }
                if let callbackTabId,
                   let callbackSurfaceId,
                   let manager = app.tabManagerFor(tabId: callbackTabId) ?? app.tabManager,
                   let workspace = manager.tabs.first(where: { $0.id == callbackTabId }),
                   workspace.panels[callbackSurfaceId] != nil {
                    manager.closePanelAfterChildExited(tabId: callbackTabId, surfaceId: callbackSurfaceId)
                }
            }
            // Always report handled so Ghostty doesn't print the fallback prompt.
            return true
        }

        // The old code gated this whole switch on resolving `callbackContext?.surfaceView`
        // -- a synchronous, off-main weak-reference read. That resolution is exactly the
        // race that corrupted ARC's weak-ref side tables during rapid window teardown (see
        // GhosttySurfaceCallbackContext's doc comment). The context is now data-only, so we
        // gate on the presence of a live callback context instead; every case below
        // resolves any live view/surface it needs only from inside a main-thread hop, via
        // `callbackTabId`/`callbackSurfaceId`.
        guard callbackContext != nil else { return false }
        if action.tag == GHOSTTY_ACTION_RELOAD_CONFIG ||
            action.tag == GHOSTTY_ACTION_CONFIG_CHANGE ||
            action.tag == GHOSTTY_ACTION_COLOR_CHANGE {
            logAction(
                action,
                target: target,
                tabId: callbackTabId,
                surfaceId: callbackSurfaceId
            )
        }

        switch action.tag {
        // INVARIANT (stability sweep 2026-08-19): the split/focus actions below run
        // synchronously via performOnMain and end in makeFirstResponder ->
        // ghostty_surface_set_focus — the same re-entry shape as the OPEN_URL
        // recursive-lock crash fixed in b6d97fd741. They are safe ONLY because
        // ghostty dispatches these actions from performBindingAction call sites
        // that do not hold renderer_state.mutex. Nothing on the ghostty side
        // enforces that. When syncing the ghostty fork, re-verify the dispatch
        // stays unlocked, or defer these handlers like the other action cases.
        case GHOSTTY_ACTION_NEW_SPLIT:
            guard let tabId = callbackTabId,
                  let surfaceId = callbackSurfaceId,
                  let direction = splitDirection(from: action.action.new_split) else {
                return false
            }
            return performOnMain {
                guard let app = AppDelegate.shared,
                      let tabManager = app.tabManagerFor(tabId: tabId) ?? app.tabManager else {
                    return false
                }
                return tabManager.createSplit(tabId: tabId, surfaceId: surfaceId, direction: direction) != nil
            }
        case GHOSTTY_ACTION_RING_BELL:
            performOnMain {
                self.ringBell()
            }
            return true
        case GHOSTTY_ACTION_GOTO_SPLIT:
            guard let tabId = callbackTabId,
                  let surfaceId = callbackSurfaceId,
                  let direction = focusDirection(from: action.action.goto_split) else {
                return false
            }
            return performOnMain {
                guard let tabManager = AppDelegate.shared?.tabManager else { return false }
                return tabManager.moveSplitFocus(tabId: tabId, surfaceId: surfaceId, direction: direction)
            }
        case GHOSTTY_ACTION_RESIZE_SPLIT:
            guard let tabId = callbackTabId,
                  let surfaceId = callbackSurfaceId,
                  let direction = resizeDirection(from: action.action.resize_split.direction) else {
                return false
            }
            let amount = action.action.resize_split.amount
            return performOnMain {
                guard let tabManager = AppDelegate.shared?.tabManager else { return false }
                return tabManager.resizeSplit(
                    tabId: tabId,
                    surfaceId: surfaceId,
                    direction: direction,
                    amount: amount
                )
            }
        case GHOSTTY_ACTION_EQUALIZE_SPLITS:
            guard let tabId = callbackTabId else {
                return false
            }
            return performOnMain {
                guard let tabManager = AppDelegate.shared?.tabManager else { return false }
                return tabManager.equalizeSplits(tabId: tabId)
            }
        case GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM:
            guard let tabId = callbackTabId,
                  let surfaceId = callbackSurfaceId else {
                return false
            }
            return performOnMain {
                guard let tabManager = AppDelegate.shared?.tabManager else { return false }
                return tabManager.toggleSplitZoom(tabId: tabId, surfaceId: surfaceId)
            }
        case GHOSTTY_ACTION_SCROLLBAR:
            let scrollbar = GhosttyScrollbar(c: action.action.scrollbar)
            let scrollbarTabId = callbackTabId
            let scrollbarSurfaceId = callbackSurfaceId
            // `enqueueScrollbarUpdate` itself is thread-safe (internal lock + coalesced
            // main-thread flush), but resolving the view it's called on must happen on
            // main -- see the resolver helpers' doc comment.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    Self.resolveSurfaceView(tabId: scrollbarTabId, surfaceId: scrollbarSurfaceId)
                }?.enqueueScrollbarUpdate(scrollbar)
            }
            return true
        case GHOSTTY_ACTION_CELL_SIZE:
            let cellSize = CGSize(
                width: CGFloat(action.action.cell_size.width),
                height: CGFloat(action.action.cell_size.height)
            )
            let cellSizeTabId = callbackTabId
            let cellSizeSurfaceId = callbackSurfaceId
            DispatchQueue.main.async {
                guard let surfaceView = MainActor.assumeIsolated({
                    Self.resolveSurfaceView(tabId: cellSizeTabId, surfaceId: cellSizeSurfaceId)
                }) else { return }
                surfaceView.cellSize = cellSize
                NotificationCenter.default.post(
                    name: .ghosttyDidUpdateCellSize,
                    object: surfaceView,
                    userInfo: [GhosttyNotificationKey.cellSize: cellSize]
                )
            }
            return true
        case GHOSTTY_ACTION_START_SEARCH:
            let needle = action.action.start_search.needle.flatMap { String(cString: $0) }
            let searchTabId = callbackTabId
            let searchSurfaceId = callbackSurfaceId
            DispatchQueue.main.async {
                guard let terminalSurface = MainActor.assumeIsolated({
                    Self.resolveTerminalSurface(tabId: searchTabId, surfaceId: searchSurfaceId)
                }) else { return }
                if let searchState = terminalSurface.searchState {
                    if let needle, !needle.isEmpty {
                        searchState.needle = needle
                    }
                } else {
                    terminalSurface.searchState = TerminalSurface.SearchState(needle: needle ?? "")
                }
                NotificationCenter.default.post(name: .ghosttySearchFocus, object: terminalSurface)
            }
            return true
        case GHOSTTY_ACTION_END_SEARCH:
            let endSearchTabId = callbackTabId
            let endSearchSurfaceId = callbackSurfaceId
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    Self.resolveTerminalSurface(tabId: endSearchTabId, surfaceId: endSearchSurfaceId)
                }?.searchState = nil
            }
            return true
        case GHOSTTY_ACTION_SEARCH_TOTAL:
            let rawTotal = action.action.search_total.total
            let total: UInt? = rawTotal >= 0 ? UInt(rawTotal) : nil
            let searchTotalTabId = callbackTabId
            let searchTotalSurfaceId = callbackSurfaceId
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    Self.resolveTerminalSurface(tabId: searchTotalTabId, surfaceId: searchTotalSurfaceId)
                }?.searchState?.total = total
            }
            return true
        case GHOSTTY_ACTION_SEARCH_SELECTED:
            let rawSelected = action.action.search_selected.selected
            let selected: UInt? = rawSelected >= 0 ? UInt(rawSelected) : nil
            let searchSelectedTabId = callbackTabId
            let searchSelectedSurfaceId = callbackSurfaceId
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    Self.resolveTerminalSurface(tabId: searchSelectedTabId, surfaceId: searchSelectedSurfaceId)
                }?.searchState?.selected = selected
            }
            return true
        case GHOSTTY_ACTION_SET_TITLE:
            let title = action.action.set_title.title
                .flatMap { String(cString: $0) } ?? ""
            if let tabId = callbackTabId,
               let surfaceId = callbackSurfaceId {
                // Coalesced (ported from upstream cmux c30733e5e6): shells/agent CLIs
                // that rewrite the title on every render would otherwise flood the
                // main actor with one NotificationCenter post per keystroke. The
                // dispatcher guarantees the last title set within the window is
                // always delivered. Resolving `surfaceView` requires a main-thread hop
                // now, so this always dispatches to main first; `setTitle` itself is a
                // no-op re-hop once already there.
                DispatchQueue.main.async {
                    let surfaceView = MainActor.assumeIsolated {
                        Self.resolveSurfaceView(tabId: tabId, surfaceId: surfaceId)
                    }
                    self.titleUpdateDispatcher.setTitle(
                        surfaceView: surfaceView,
                        tabId: tabId,
                        surfaceId: surfaceId,
                        title: title
                    )
                }
            }
            return true
        case GHOSTTY_ACTION_PWD:
            guard let tabId = callbackTabId,
                  let surfaceId = callbackSurfaceId else { return true }
            let pwd = action.action.pwd.pwd.flatMap { String(cString: $0) } ?? ""
            DispatchQueue.main.async {
                AppDelegate.shared?.tabManagerFor(tabId: tabId)?.updateSurfaceDirectory(
                    tabId: tabId,
                    surfaceId: surfaceId,
                    directory: pwd
                )
            }
            return true
        case GHOSTTY_ACTION_PROGRESS_REPORT:
            // OSC 9;4 (ConEmu progress). Reuses `Workspace.progress`/`SidebarProgressState`
            // (already rendered by the sidebar tab row) rather than a new model. `_ERROR`,
            // `_PAUSE`, and `_INDETERMINATE` (and `_SET` with an unreported percent, -1) have
            // no representation in `SidebarProgressState` yet, so they retain the last known
            // value instead of guessing -- the run reads as "still going", not "finished".
            guard let tabId = callbackTabId,
                  let surfaceId = callbackSurfaceId else { return true }
            let report = action.action.progress_report
            let state = report.state
            let rawProgress = report.progress
            DispatchQueue.main.async {
                guard let workspace = AppDelegate.shared?.tabManagerFor(tabId: tabId)?.tabs
                    .first(where: { $0.id == tabId }) else { return }
                switch state {
                case GHOSTTY_PROGRESS_STATE_REMOVE:
                    if workspace.progress != nil {
                        workspace.progress = nil
                    }
                    if workspace.progressSourcePanelId != nil {
                        workspace.progressSourcePanelId = nil
                    }
                case GHOSTTY_PROGRESS_STATE_SET where rawProgress >= 0:
                    let clamped = max(0, min(100, Int(rawProgress)))
                    let value = Double(clamped) / 100.0
                    if TerminalController.shouldReplaceProgress(current: workspace.progress, value: value, label: nil) {
                        _ = workspace.setSidebarProgress(value: value, label: nil)
                    }
                    workspace.progressSourcePanelId = surfaceId
                default:
                    // _SET with progress == -1, _ERROR, _PAUSE, _INDETERMINATE: no-op, keep
                    // last known value.
                    break
                }
            }
            return true
        case GHOSTTY_ACTION_COMMAND_FINISHED:
            // OSC 133 semantic prompt tracking. Plumbing-only: stores exit code + duration on
            // `Workspace.lastCommand`; no UI reads this yet.
            guard let tabId = callbackTabId,
                  let surfaceId = callbackSurfaceId else { return true }
            let commandFinished = action.action.command_finished
            let exitCode = commandFinished.exit_code
            let durationNanoseconds = commandFinished.duration
            #if DEBUG
            dlog("command.finished exitCode=\(exitCode) durationNs=\(durationNanoseconds)")
            #endif
            DispatchQueue.main.async {
                guard let owningManager = AppDelegate.shared?.tabManagerFor(tabId: tabId),
                      let workspace = owningManager.tabs.first(where: { $0.id == tabId }) else { return }
                let outcome = LastCommandOutcome.from(
                    exitCode: exitCode,
                    durationNanoseconds: durationNanoseconds,
                    sourcePanelId: surfaceId
                )
                workspace.lastCommand = outcome

                // Experimental: notify when a long-running command finishes in a pane the
                // user isn't looking at. Default-ON with a conservative threshold; 0 disables.
                let threshold = LongCommandNotificationSettings.thresholdSeconds()
                guard threshold > 0, outcome.duration >= threshold else { return }
                guard !workspace.hasHookManagedAgent else { return }

                let isActiveTab = owningManager.selectedTabId == tabId
                let focusedSurfaceId = owningManager.focusedSurfaceId(for: tabId)
                let isFocusedSurface = focusedSurfaceId == surfaceId
                guard !(isActiveTab && isFocusedSurface && AppFocusState.isAppFocused()) else { return }

                let tabTitle = owningManager.titleForTab(tabId) ?? "Terminal"
                let formattedDuration = LastCommandOutcome.formattedDuration(outcome.duration)
                let body: String
                if let exitCode = outcome.exitCode, exitCode != 0 {
                    body = String.localizedStringWithFormat(
                        String(
                            localized: "notification.longCommand.failed",
                            defaultValue: "Failed (exit %@) after %@"
                        ),
                        String(exitCode),
                        formattedDuration
                    )
                } else {
                    body = String.localizedStringWithFormat(
                        String(
                            localized: "notification.longCommand.succeeded",
                            defaultValue: "Finished in %@"
                        ),
                        formattedDuration
                    )
                }
                TerminalNotificationStore.shared.addNotification(
                    tabId: tabId,
                    surfaceId: surfaceId,
                    title: tabTitle,
                    subtitle: "",
                    body: body,
                    cooldownKey: "long-command-\(surfaceId.uuidString)",
                    cooldownInterval: 5
                )
            }
            return true
        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            guard let tabId = callbackTabId else { return true }
            let surfaceId = callbackSurfaceId
            let actionTitle = action.action.desktop_notification.title
                .flatMap { String(cString: $0) } ?? ""
            let actionBody = action.action.desktop_notification.body
                .flatMap { String(cString: $0) } ?? ""
            performOnMain {
                // Suppress OSC notifications for workspaces with active hook-managed agent
                // sessions (Claude Code, Codex, etc.).
                let owningManager = AppDelegate.shared?.tabManagerFor(tabId: tabId) ?? AppDelegate.shared?.tabManager
                if let workspace = owningManager?.tabs.first(where: { $0.id == tabId }),
                   workspace.hasHookManagedAgent {
                    return
                }
                let tabTitle = owningManager?.titleForTab(tabId) ?? "Terminal"
                let command = actionTitle.isEmpty ? tabTitle : actionTitle
                let body = actionBody
                TerminalNotificationStore.shared.addNotification(
                    tabId: tabId,
                    surfaceId: surfaceId,
                    title: command,
                    subtitle: "",
                    body: body
                )
            }
            return true
        case GHOSTTY_ACTION_COLOR_CHANGE:
            if action.action.color_change.kind == GHOSTTY_ACTION_COLOR_KIND_BACKGROUND {
                let change = action.action.color_change
                let newColor = NSColor(
                    red: CGFloat(change.r) / 255,
                    green: CGFloat(change.g) / 255,
                    blue: CGFloat(change.b) / 255,
                    alpha: 1.0
                )
                if backgroundLogEnabled {
                    logBackground(
                        "surface override set tab=\(callbackTabId?.uuidString ?? "nil") surface=\(callbackSurfaceId?.uuidString ?? "nil") override=\(newColor.hexString()) default=\(defaultBackgroundColor.hexString()) source=action.color_change.surface"
                    )
                }
                DispatchQueue.main.async { [self] in
                    guard let surfaceView = MainActor.assumeIsolated({
                        Self.resolveSurfaceView(tabId: callbackTabId, surfaceId: callbackSurfaceId)
                    }) else { return }
                    surfaceView.backgroundColor = newColor
                    surfaceView.applySurfaceBackground()
                    if backgroundLogEnabled {
                        logBackground("OSC background change tab=\(callbackTabId?.uuidString ?? "unknown") color=\(surfaceView.backgroundColor?.description ?? "nil")")
                    }
                    surfaceView.applyWindowBackgroundIfActive()
                }
            }
            return true
        case GHOSTTY_ACTION_CONFIG_CHANGE:
            DispatchQueue.main.async { [self] in
                guard let surfaceView = MainActor.assumeIsolated({
                    Self.resolveSurfaceView(tabId: callbackTabId, surfaceId: callbackSurfaceId)
                }) else { return }
                if let staleOverride = surfaceView.backgroundColor {
                    surfaceView.backgroundColor = nil
                    if backgroundLogEnabled {
                        logBackground(
                            "surface override cleared tab=\(callbackTabId?.uuidString ?? "nil") surface=\(callbackSurfaceId?.uuidString ?? "nil") cleared=\(staleOverride.hexString()) source=action.config_change.surface"
                        )
                    }
                    surfaceView.applySurfaceBackground()
                    surfaceView.applyWindowBackgroundIfActive()
                }
            }
            updateDefaultBackground(
                from: action.action.config_change.config,
                source: "action.config_change.surface tab=\(callbackTabId?.uuidString ?? "nil") surface=\(callbackSurfaceId?.uuidString ?? "nil")",
                scope: .surface
            )
            if backgroundLogEnabled {
                logBackground(
                    "surface config change deferred terminal bg apply tab=\(callbackTabId?.uuidString ?? "nil") surface=\(callbackSurfaceId?.uuidString ?? "nil")"
                )
            }
            return true
        case GHOSTTY_ACTION_RELOAD_CONFIG:
            let soft = action.action.reload_config.soft
            logThemeAction(
                "reload request target=surface tab=\(callbackTabId?.uuidString ?? "nil") surface=\(callbackSurfaceId?.uuidString ?? "nil") soft=\(soft)"
            )
            return performOnMain {
                // Keep all runtime theme/default-background state in the same path.
                GhosttyApp.shared.reloadConfiguration(
                    soft: soft,
                    source: "action.reload_config.surface tab=\(callbackTabId?.uuidString ?? "nil") surface=\(callbackSurfaceId?.uuidString ?? "nil")"
                )
                return true
            }
        case GHOSTTY_ACTION_KEY_SEQUENCE:
            return performOnMain {
                Self.resolveSurfaceView(tabId: callbackTabId, surfaceId: callbackSurfaceId)?
                    .updateKeySequence(action.action.key_sequence)
                return true
            }
        case GHOSTTY_ACTION_KEY_TABLE:
            return performOnMain {
                Self.resolveSurfaceView(tabId: callbackTabId, surfaceId: callbackSurfaceId)?
                    .updateKeyTable(action.action.key_table)
                return true
            }
        case GHOSTTY_ACTION_OPEN_URL:
            let openUrl = action.action.open_url
            guard let cstr = openUrl.url else { return false }
            let urlString = String(
                data: Data(bytes: cstr, count: Int(openUrl.len)),
                encoding: .utf8
            ) ?? ""
            #if DEBUG
            dlog("link.openURL raw=\(urlString)")
            #endif
            guard let target = resolveTerminalOpenURLTarget(urlString) else {
                #if DEBUG
                dlog("link.openURL resolve failed, returning false")
                #endif
                return false
            }
            if !BrowserLinkOpenSettings.openTerminalLinksInProgramaBrowser() {
                #if DEBUG
                dlog("link.openURL cmuxBrowser=disabled, opening externally url=\(target.url)")
                #endif
                return performOnMain {
                    BrowserLinkOpenSettings.openExternally(target.url)
                }
            }
            switch target {
            case let .external(url):
                #if DEBUG
                dlog("link.openURL target=external, opening externally url=\(url)")
                #endif
                return performOnMain {
                    BrowserLinkOpenSettings.openExternally(url)
                }
            case let .embeddedBrowser(url):
                if BrowserLinkOpenSettings.shouldOpenExternally(url) {
                    #if DEBUG
                    dlog("link.openURL target=embedded but shouldOpenExternally=true url=\(url)")
                    #endif
                    return performOnMain {
                        BrowserLinkOpenSettings.openExternally(url)
                    }
                }
                guard let host = BrowserInsecureHTTPSettings.normalizeHost(url.host ?? "") else {
                    #if DEBUG
                    dlog("link.openURL target=embedded but normalizeHost=nil host=\(url.host ?? "nil") url=\(url)")
                    #endif
                    return performOnMain {
                        BrowserLinkOpenSettings.openExternally(url)
                    }
                }

                // If a host whitelist is configured and this host isn't in it, open externally.
                if !BrowserLinkOpenSettings.hostMatchesWhitelist(host) {
                    #if DEBUG
                    dlog("link.openURL target=embedded but hostWhitelist miss host=\(host) url=\(url)")
                    #endif
                    return performOnMain {
                        BrowserLinkOpenSettings.openExternally(url)
                    }
                }
                let sourceWorkspaceId = callbackTabId
                let sourcePanelId = callbackSurfaceId
                guard let sourceWorkspaceId,
                      let sourcePanelId else {
                    #if DEBUG
                    dlog("link.openURL target=embedded but tabId/surfaceId=nil")
                    #endif
                    return false
                }
                #if DEBUG
                dlog(
                    "link.openURL target=embedded, opening in browser pane " +
                    "host=\(host) url=\(url) tabId=\(sourceWorkspaceId) surfaceId=\(sourcePanelId)"
                )
                #endif
                // ghostty invokes this action from Surface.mouseUp with renderer_state.mutex
                // held (Surface.zig:4164). Running the split+focus inline re-enters
                // ghostty_surface_set_focus and recursively locks an os_unfair_lock (crash in
                // 0.4.233). Defer to the next main-queue turn so the callout returns and
                // releases the lock first. Claim the action now (return true) so ghostty
                // doesn't also run its own fallback opener.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let app = AppDelegate.shared,
                              let resolved = app.workspaceContainingPanel(
                                panelId: sourcePanelId,
                                preferredWorkspaceId: sourceWorkspaceId
                              ) else {
                            #if DEBUG
                            dlog(
                                "link.openURL embedded but workspace lookup failed " +
                                "tabId=\(sourceWorkspaceId) surfaceId=\(sourcePanelId)"
                            )
                            #endif
                            BrowserLinkOpenSettings.openExternally(url)
                            return
                        }
                        let workspace = resolved.workspace
                        #if DEBUG
                        if workspace.id != sourceWorkspaceId {
                            dlog(
                                "link.openURL workspace.remap sourceTab=\(sourceWorkspaceId) " +
                                "resolvedTab=\(workspace.id) surfaceId=\(sourcePanelId)"
                            )
                        }
                        #endif
                        if let targetPane = workspace.preferredBrowserTargetPane(fromPanelId: sourcePanelId) {
                            #if DEBUG
                            dlog("link.openURL opening in existing browser pane=\(targetPane)")
                            #endif
                            if workspace.newBrowserSurface(inPane: targetPane, url: url, focus: true) == nil {
                                BrowserLinkOpenSettings.openExternally(url)
                            }
                        } else {
                            #if DEBUG
                            dlog("link.openURL opening as new browser split from surface=\(sourcePanelId)")
                            #endif
                            if workspace.newBrowserSplit(from: sourcePanelId, orientation: .horizontal, url: url) == nil {
                                BrowserLinkOpenSettings.openExternally(url)
                            }
                        }
                    }
                }
                return true
            }
        default:
            return false
        }
    }

    private func applyBackgroundToKeyWindow() {
        guard let window = activeMainWindow() else { return }
        if cmuxShouldUseClearWindowBackground(for: defaultBackgroundOpacity) {
            window.backgroundColor = programaTransparentWindowBaseColor()
            window.isOpaque = false
            applyWindowBlurIfNeeded(window)
            if backgroundLogEnabled {
                logBackground("applied transparent window background opacity=\(String(format: "%.3f", defaultBackgroundOpacity))")
            }
        } else {
            let color = defaultBackgroundColor.withAlphaComponent(defaultBackgroundOpacity)
            window.backgroundColor = color
            window.isOpaque = color.alphaComponent >= 1.0
            if backgroundLogEnabled {
                logBackground("applied default window background color=\(color) opacity=\(String(format: "%.3f", color.alphaComponent))")
            }
        }
    }

    func applyWindowBlurIfNeeded(_ window: NSWindow) {
        guard let app = self.app else { return }
        // ghostty_set_window_background_blur reads background-blur and
        // background-opacity from the app config internally and calls
        // CGSSetWindowBackgroundBlurRadius — a compositor-level setter that is
        // idempotent.  It is a no-op when opacity >= 1.0 or blur is disabled,
        // so we can call it unconditionally whenever the window is transparent.
        ghostty_set_window_background_blur(app, Unmanaged.passUnretained(window).toOpaque())
    }

    private func activeMainWindow() -> NSWindow? {
        let keyWindow = NSApp.keyWindow
        if let raw = keyWindow?.identifier?.rawValue,
           raw == "cmux.main" || raw.hasPrefix("cmux.main.") {
            return keyWindow
        }
        return NSApp.windows.first(where: { window in
            guard let raw = window.identifier?.rawValue else { return false }
            return raw == "cmux.main" || raw.hasPrefix("cmux.main.")
        })
    }

    func logBackground(_ message: String) {
        let timestamp = Self.backgroundLogTimestampFormatter.string(from: Date())
        let uptimeMs = (ProcessInfo.processInfo.systemUptime - backgroundLogStartUptime) * 1000
        let frame60 = Int((CACurrentMediaTime() * 60.0).rounded(.down))
        let frame120 = Int((CACurrentMediaTime() * 120.0).rounded(.down))
        let threadLabel = Thread.isMainThread ? "main" : "background"
        backgroundLogLock.lock()
        backgroundLogSequence &+= 1
        let sequence = backgroundLogSequence
        backgroundLogLock.unlock()
        let line =
            "\(timestamp) seq=\(sequence) t+\(String(format: "%.3f", uptimeMs))ms thread=\(threadLabel) frame60=\(frame60) frame120=\(frame120) cmux bg: \(message)\n"
        backgroundLogWriter.append(line)
    }

#if DEBUG
    /// Test-only seam exposing the private `callbackContext(from:)` resolution (which
    /// wraps `GhosttySurfaceUserdataRegistry.resolve(from:)`) so tests can verify a stale
    /// userdata pointer resolves to `nil` instead of dereferencing freed memory. Widened
    /// from `private` to an internal, DEBUG-only static func rather than exposing the
    /// registry or the callback context type directly, matching the DEBUG-only test
    /// scaffolding pattern used elsewhere (e.g. `TerminalSurface.replaceSurfaceWithFreedPointerForTesting`).
    static func debugCallbackContextResolves(from userdata: UnsafeMutableRawPointer?) -> Bool {
        callbackContext(from: userdata) != nil
    }

    /// Test-only seam exposing the resolved snapshot's `tabId`, so a test can verify
    /// `TerminalSurface.updateWorkspaceId` propagates through to
    /// `GhosttySurfaceUserdataRegistry.updateTabId(pointer:tabId:)` and is visible to a
    /// subsequent `resolve(from:)` -- i.e. the same pointer callbacks would see. Callers
    /// should first assert `debugCallbackContextResolves(from:)` to distinguish "pointer is
    /// stale" from "tabId happens to be nil".
    static func debugCallbackContextTabId(from userdata: UnsafeMutableRawPointer?) -> UUID? {
        callbackContext(from: userdata)?.tabId
    }
#endif
}
