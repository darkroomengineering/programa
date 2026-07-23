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

// MARK: - Debug Render Instrumentation (split out, Nuclear Review #97; verbatim move)

/// Lightweight instrumentation to detect whether Ghostty is actually requesting Metal drawables.
/// This helps catch "frozen until refocus" regressions without relying on screenshots (which can
/// mask redraw issues by forcing a window server flush).
final class GhosttyMetalLayer: CAMetalLayer {
    private let lock = NSLock()
    private var drawableCount: Int = 0
    private var lastDrawableTime: CFTimeInterval = 0

    func debugStats() -> (count: Int, last: CFTimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        return (drawableCount, lastDrawableTime)
    }

    override func nextDrawable() -> CAMetalDrawable? {
        lock.lock()
        drawableCount += 1
        lastDrawableTime = CACurrentMediaTime()
        lock.unlock()
        return super.nextDrawable()
    }
}

final class TerminalSurfaceRegistry {
    static let shared = TerminalSurfaceRegistry()

    // `NSHashTable<AnyObject>.weakObjects()` does not reliably weak-store pure Swift
    // classes that aren't NSObject subclasses — confirmed empirically: TerminalSurface
    // instances registered via the old NSHashTable-backed storage never released even
    // after every other strong reference was dropped, permanently blocking `deinit`
    // (see testSearchOverlayMountDoesNotRetainTerminalSurface, and bisection notes in
    // that test's history). A plain Swift `weak` box array is the reliable way to hold
    // weak references to a non-NSObject class; ARC handles it correctly regardless of
    // Objective-C bridging.
    private struct WeakSurfaceBox {
        weak var surface: TerminalSurface?
    }

    private let lock = NSLock()
    private var surfaceBoxes: [WeakSurfaceBox] = []
    private var runtimeSurfaceOwners: [UInt: UUID] = [:]

    private init() {}

    func register(_ surface: TerminalSurface) {
        lock.lock()
        defer { lock.unlock() }
        surfaceBoxes.removeAll { $0.surface == nil }
        surfaceBoxes.append(WeakSurfaceBox(surface: surface))
    }

    func registerRuntimeSurface(_ surface: ghostty_surface_t, ownerId: UUID) {
        lock.lock()
        defer { lock.unlock() }
        runtimeSurfaceOwners[UInt(bitPattern: surface)] = ownerId
    }

    func unregisterRuntimeSurface(_ surface: ghostty_surface_t, ownerId: UUID) {
        lock.lock()
        defer { lock.unlock() }
        let key = UInt(bitPattern: surface)
        guard runtimeSurfaceOwners[key] == ownerId else { return }
        runtimeSurfaceOwners.removeValue(forKey: key)
    }

    func runtimeSurfaceOwnerId(_ surface: ghostty_surface_t) -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        return runtimeSurfaceOwners[UInt(bitPattern: surface)]
    }

    func allSurfaces() -> [TerminalSurface] {
        lock.lock()
        surfaceBoxes.removeAll { $0.surface == nil }
        let objects = surfaceBoxes.compactMap { $0.surface }
        lock.unlock()
        return objects.sorted { lhs, rhs in
            lhs.id.uuidString < rhs.id.uuidString
        }
    }
}

// MARK: - Terminal Surface (owns the ghostty_surface_t lifecycle)

final class TerminalSurface: Identifiable, ObservableObject {
    final class SearchState: ObservableObject {
        @Published var needle: String
        @Published var selected: UInt?
        @Published var total: UInt?

        init(needle: String = "") {
            self.needle = needle
            self.selected = nil
            self.total = nil
        }
    }

    private struct PendingKeyEvent {
        let keycode: UInt32
        let mods: ghostty_input_mods_e
        let label: String
    }

    private enum PendingSocketInput {
        case text(Data)
        case key(PendingKeyEvent)

        var estimatedBytes: Int {
            switch self {
            case .text(let data):
                return data.count
            case .key(let event):
                return max(event.label.utf8.count, 1)
            }
        }
    }

    private(set) var surface: ghostty_surface_t?
    private weak var attachedView: GhosttyNSView?

    /// Whether the runtime Ghostty surface exists and has not begun teardown.
    ///
    /// Use this as a quick availability check. Before passing `surface` to
    /// Ghostty C APIs that dereference the pointer (e.g.
    /// `ghostty_surface_inherited_config`, `ghostty_surface_quicklook_font`),
    /// call `liveSurfaceForGhosttyAccess(reason:)` so stale freed pointers are
    /// rejected and quarantined.
    var hasLiveSurface: Bool { surface != nil && portalLifecycleState == .live }

    /// Whether the terminal surface view is currently attached to a window.
    ///
    /// Use the hosted view rather than the inner surface view, since the surface can be
    /// temporarily unattached (surface not yet created / reparenting) even while the panel
    /// is already in the window.
    var isViewInWindow: Bool { hostedView.window != nil }
    /// Whether the runtime surface pointer is non-nil **and** the surface has
    /// not yet entered the close/teardown lifecycle.  Use this before passing
    /// `surface` to any Ghostty C API — a non-nil `surface` can become a
    /// dangling pointer once teardown is in progress (the actual free happens
    /// asynchronously on the next main-actor turn).
    var isSurfaceLive: Bool { surface != nil && portalLifecycleState == .live }
    let id: UUID
    private(set) var tabId: UUID
    /// Port ordinal for PROGRAMA_PORT range assignment
    var portOrdinal: Int = 0
    /// Snapshotted once per app session so all workspaces use consistent values
    static let sessionPortBase: Int = {
        let val = UserDefaults.standard.integer(forKey: "cmuxPortBase")
        return val > 0 ? val : 9100
    }()
    static let sessionPortRangeSize: Int = {
        let val = UserDefaults.standard.integer(forKey: "cmuxPortRange")
        return val > 0 ? val : 10
    }()
    private let surfaceContext: ghostty_surface_context_e
    private let configTemplate: ProgramaSurfaceConfigTemplate?
    private let workingDirectory: String?
    private let initialCommand: String?
    private let initialEnvironmentOverrides: [String: String]
    var requestedWorkingDirectory: String? { workingDirectory }
    private var additionalEnvironment: [String: String]
    let hostedView: GhosttySurfaceScrollView
    private let surfaceView: GhosttyNSView
    private var lastPixelWidth: UInt32 = 0
    private var lastPixelHeight: UInt32 = 0
    private var lastXScale: CGFloat = 0
    private var lastYScale: CGFloat = 0
    private let debugMetadataLock = NSLock()
    private let createdAt: Date = Date()
    private var runtimeSurfaceCreatedAt: Date?
    private var teardownRequestedAt: Date?
    private var teardownRequestReason: String?
    private var pendingSocketInputQueue: [PendingSocketInput] = []
    private var pendingSocketInputBytes: Int = 0
    private let maxPendingSocketInputBytes = 1_048_576
    private var backgroundSurfaceStartQueued = false
    private var surfaceCallbackContext: Unmanaged<GhosttySurfaceCallbackContext>?
    /// Per-surface userdata for the PTY output tap that feeds the session
    /// WAL. See SessionOutputTapSpike.swift (SessionWALStore) for the
    /// threading/lock tradeoff and full lifecycle contract. Registered right
    /// after `ghostty_surface_new` succeeds; cleared + released at every
    /// teardown site paired with `surfaceCallbackContext` below.
    private var outputTapContext: Unmanaged<SessionWALStore.Context>?
    /// The desired focus state for the Ghostty C surface. May be set before the
    /// C surface exists (e.g. during layout restoration); `createSurface`
    /// reapplies this value once the runtime surface exists, then keeps using it
    /// as a dedup guard to avoid redundant `ghostty_surface_set_focus` calls
    /// (prevents prompt redraws with P10k).
    ///
    /// Start unfocused and only opt into focus when the workspace/AppKit focus
    /// path explicitly requests it so background panes do not keep a focused
    /// state unless the workspace focus path requests it.
    private var desiredFocusState: Bool = false
#if DEBUG
    private var needsConfirmCloseOverrideForTesting: Bool?
    private var runtimeSurfaceFreedOutOfBandForTesting = false
#endif
    private enum PortalLifecycleState: String {
        case live
        case closing
        case closed
    }
    private struct PortalHostLease {
        let hostId: ObjectIdentifier
        let paneId: UUID
        let instanceSerial: UInt64
        let inWindow: Bool
        let area: CGFloat
    }
    private var portalLifecycleState: PortalLifecycleState = .live
    private var portalLifecycleGeneration: UInt64 = 1
    private var activePortalHostLease: PortalHostLease?
    @Published var searchState: SearchState? = nil {
	        didSet {
	            if let searchState {
	                hostedView.cancelFocusRequest()
#if DEBUG
                dlog("find.searchState created tab=\(tabId.uuidString.prefix(5)) surface=\(id.uuidString.prefix(5))")
#endif
                searchNeedleCancellable = searchState.$needle
                    .removeDuplicates()
                    .map { needle -> AnyPublisher<String, Never> in
                        if needle.isEmpty || needle.count >= 3 {
                            return Just(needle).eraseToAnyPublisher()
                        }

                        return Just(needle)
                            .delay(for: .milliseconds(300), scheduler: DispatchQueue.main)
                            .eraseToAnyPublisher()
                    }
                    .switchToLatest()
                    .sink { [weak self] needle in
#if DEBUG
                        dlog("find.needle updated tab=\(self?.tabId.uuidString.prefix(5) ?? "?") surface=\(self?.id.uuidString.prefix(5) ?? "?") chars=\(needle.count)")
#endif
                        _ = self?.performBindingAction("search:\(needle)")
                    }
            } else if oldValue != nil {
                searchNeedleCancellable = nil
#if DEBUG
                dlog("find.searchState cleared tab=\(tabId.uuidString.prefix(5)) surface=\(id.uuidString.prefix(5))")
#endif
                _ = performBindingAction("end_search")
            }
        }
    }
    @Published private(set) var keyboardCopyModeActive: Bool = false
    /// One-shot readiness flag for the underlying Ghostty surface. Flips false -> true exactly
    /// once, the moment `createSurface(for:)` successfully creates the runtime surface. Drives
    /// the terminal loading spinner in `TerminalPanelView`. Never read on keystroke-hot paths.
    @Published private(set) var isSurfaceReady: Bool = false
    private var searchNeedleCancellable: AnyCancellable?
    var currentKeyStateIndicatorText: String? { surfaceView.currentKeyStateIndicatorText }

    init(
        tabId: UUID,
        context: ghostty_surface_context_e,
        configTemplate: ProgramaSurfaceConfigTemplate?,
        workingDirectory: String? = nil,
        initialCommand: String? = nil,
        initialEnvironmentOverrides: [String: String] = [:],
        additionalEnvironment: [String: String] = [:]
    ) {
        self.id = UUID()
        self.tabId = tabId
        self.surfaceContext = context
        self.configTemplate = configTemplate
        self.workingDirectory = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCommand = initialCommand?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.initialCommand = (trimmedCommand?.isEmpty == false) ? trimmedCommand : nil
        self.initialEnvironmentOverrides = Self.mergedNormalizedEnvironment(base: [:], overrides: initialEnvironmentOverrides)
        self.additionalEnvironment = Self.mergedNormalizedEnvironment(base: [:], overrides: additionalEnvironment)
        // Match Ghostty's own SurfaceView: ensure a non-zero initial frame so the backing layer
        // has non-zero bounds and the renderer can initialize without presenting a blank/stretched
        // intermediate frame on the first real resize.
        let view = GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        self.surfaceView = view
        self.hostedView = GhosttySurfaceScrollView(surfaceView: view)
        // Surface is created when attached to a view
        hostedView.attachSurface(self)
        TerminalSurfaceRegistry.shared.register(self)
    }


    func updateWorkspaceId(_ newTabId: UUID) {
        tabId = newTabId
        attachedView?.tabId = newTabId
        surfaceView.tabId = newTabId
    }

    private static func mergedNormalizedEnvironment(
        base: [String: String],
        overrides: [String: String]
    ) -> [String: String] {
        var merged: [String: String] = [:]
        merged.reserveCapacity(base.count + overrides.count)
        for (rawKey, value) in base {
            let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            merged[key] = value
        }
        for (rawKey, value) in overrides {
            let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            merged[key] = value
        }
        return merged
    }

    static let managedTerminalType = "xterm-256color"
    static let managedTerminalProgram = "ghostty"
    static let managedColorTerm = "truecolor"

    static func applyManagedTerminalIdentityEnvironment(
        to environment: inout [String: String],
        protectedKeys: inout Set<String>
    ) {
        environment["TERM"] = managedTerminalType
        protectedKeys.insert("TERM")
        environment["COLORTERM"] = managedColorTerm
        protectedKeys.insert("COLORTERM")
        environment["TERM_PROGRAM"] = managedTerminalProgram
        protectedKeys.insert("TERM_PROGRAM")
    }

    static func mergedStartupEnvironment(
        base: [String: String],
        protectedKeys: Set<String>,
        additionalEnvironment: [String: String],
        initialEnvironmentOverrides: [String: String]
    ) -> [String: String] {
        var merged = base
        for (key, value) in additionalEnvironment where !key.isEmpty && !value.isEmpty && !protectedKeys.contains(key) {
            merged[key] = value
        }
        for (key, value) in initialEnvironmentOverrides where !protectedKeys.contains(key) {
            merged[key] = value
        }
        return merged
    }

    static func applyManagedFishStartupEnvironment(
        integrationDir: String,
        to environment: inout [String: String],
        protectedKeys: inout Set<String>
    ) {
        let normalizedIntegrationDir = URL(fileURLWithPath: integrationDir, isDirectory: true)
            .standardizedFileURL
            .path
        let integrationFile = URL(fileURLWithPath: normalizedIntegrationDir, isDirectory: true)
            .appendingPathComponent("fish/config.fish")
            .path

        environment["PROGRAMA_FISH_INTEGRATION_FILE"] = integrationFile
        environment["PROGRAMA_FISH_USER_CONFIG_ALREADY_LOADED"] = "1"
        protectedKeys.insert("PROGRAMA_FISH_INTEGRATION_FILE")
        protectedKeys.insert("PROGRAMA_FISH_USER_CONFIG_ALREADY_LOADED")
    }

    static func managedFishShellCommand(shell: String) -> String {
        let initCommand = #"source "$PROGRAMA_FISH_INTEGRATION_FILE""#
        return "\(shellSingleQuoted(shell)) -il --init-command \(shellSingleQuoted(initCommand))"
    }

    private static func shellSingleQuoted(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    func isAttached(to view: GhosttyNSView) -> Bool {
        attachedView === view && surface != nil
    }

    func portalBindingGeneration() -> UInt64 {
        portalLifecycleGeneration
    }

    func portalBindingStateLabel() -> String {
        portalLifecycleState.rawValue
    }

    private func withDebugMetadataLock<T>(_ body: () -> T) -> T {
        debugMetadataLock.lock()
        defer { debugMetadataLock.unlock() }
        return body()
    }

    func debugCreatedAt() -> Date {
        withDebugMetadataLock { createdAt }
    }

    func debugRuntimeSurfaceCreatedAt() -> Date? {
        withDebugMetadataLock { runtimeSurfaceCreatedAt }
    }

    func debugTeardownRequest() -> (requestedAt: Date?, reason: String?) {
        withDebugMetadataLock { (teardownRequestedAt, teardownRequestReason) }
    }

    func debugLastKnownWorkspaceId() -> UUID {
        tabId
    }

    func debugSurfaceContextLabel() -> String {
        programaSurfaceContextName(surfaceContext)
    }

    func debugInitialCommand() -> String? {
        initialCommand
    }

    func debugPortalHostLease() -> (hostId: String?, paneId: UUID?, inWindow: Bool?, area: CGFloat?) {
        guard let activePortalHostLease else {
            return (nil, nil, nil, nil)
        }
        return (
            hostId: String(describing: activePortalHostLease.hostId),
            paneId: activePortalHostLease.paneId,
            inWindow: activePortalHostLease.inWindow,
            area: activePortalHostLease.area
        )
    }

    func canAcceptPortalBinding(expectedSurfaceId: UUID?, expectedGeneration: UInt64?) -> Bool {
        guard portalLifecycleState == .live else { return false }
        if let expectedSurfaceId, expectedSurfaceId != id {
            return false
        }
        if let expectedGeneration, expectedGeneration != portalLifecycleGeneration {
            return false
        }
        return true
    }

    @MainActor
    func liveSurfaceForGhosttyAccess(reason: String) -> ghostty_surface_t? {
        guard hasLiveSurface, let surface else { return nil }
        let registry = TerminalSurfaceRegistry.shared
        let registeredOwnerId = registry.runtimeSurfaceOwnerId(surface)
        guard registeredOwnerId == id,
              programaSurfacePointerAppearsLive(surface) else {
            let callbackContext = surfaceCallbackContext
            surfaceCallbackContext = nil
            // Pointer may already be reowned/recycled here — do not touch the
            // C surface, just forget our bookkeeping (mirrors callbackContext
            // above). Not a real close: keep the WAL directory (default
            // deleteDirectory: false).
            SessionWALStore.shared.unregister(surface: nil, surfaceId: id.uuidString)
            outputTapContext?.release()
            outputTapContext = nil
            registry.unregisterRuntimeSurface(surface, ownerId: id)
            self.surface = nil
            activePortalHostLease = nil
            recordTeardownRequest(reason: reason)
            markPortalLifecycleClosed(reason: reason)
#if DEBUG
            let registeredOwnerToken = registeredOwnerId.map { String($0.uuidString.prefix(5)) } ?? "nil"
            dlog(
                "surface.lifecycle.stale surface=\(id.uuidString.prefix(5)) " +
                "workspace=\(tabId.uuidString.prefix(5)) reason=\(reason) " +
                "registryOwner=\(registeredOwnerToken)"
            )
#endif
            callbackContext?.release()
            return nil
        }
        return surface
    }

    private static let portalHostAreaThreshold: CGFloat = 4

    private static func portalHostArea(for bounds: CGRect) -> CGFloat {
        max(0, bounds.width) * max(0, bounds.height)
    }

    private static func portalHostIsUsable(_ lease: PortalHostLease) -> Bool {
        lease.inWindow && lease.area > portalHostAreaThreshold
    }

    @discardableResult
    func preparePortalHostReplacementIfOwned(hostId: ObjectIdentifier, reason: String) -> Bool {
        guard let current = activePortalHostLease, current.hostId == hostId else { return false }
        // SwiftUI can tear down and rebuild the host NSView during split churn. Keep the
        // existing portal binding alive, but make the old lease non-usable so the next
        // distinct host in the same pane can claim immediately instead of waiting for a
        // later layout-follow-up retry.
        activePortalHostLease = PortalHostLease(
            hostId: current.hostId,
            paneId: current.paneId,
            instanceSerial: current.instanceSerial,
            inWindow: false,
            area: current.area
        )
#if DEBUG
        dlog(
            "terminal.portal.host.rearm surface=\(id.uuidString.prefix(5)) " +
            "reason=\(reason) host=\(hostId) pane=\(current.paneId.uuidString.prefix(5)) " +
            "area=\(String(format: "%.1f", current.area))"
        )
#endif
        return true
    }

    func claimPortalHost(
        hostId: ObjectIdentifier,
        paneId: PaneID,
        instanceSerial: UInt64,
        inWindow: Bool,
        bounds: CGRect,
        reason: String
    ) -> Bool {
        let next = PortalHostLease(
            hostId: hostId,
            paneId: paneId.id,
            instanceSerial: instanceSerial,
            inWindow: inWindow,
            area: Self.portalHostArea(for: bounds)
        )

        if let current = activePortalHostLease {
            if current.hostId == hostId {
                activePortalHostLease = next
                return true
            }

            let currentUsable = Self.portalHostIsUsable(current)
            let nextUsable = Self.portalHostIsUsable(next)
            // During split churn SwiftUI can briefly keep the old host alive while the new
            // host for the same pane is already in the window. Prefer the newer live host
            // immediately so the surface moves with the pane instead of waiting for a later
            // update from unrelated focus/layout work.
            let newerSamePaneHostReady =
                current.paneId == paneId.id &&
                nextUsable &&
                next.instanceSerial > current.instanceSerial
            // A dragged terminal must hand off immediately when it moves to a different pane.
            // Waiting for the old host to become "worse" leaves the moved pane blank/stale.
            let shouldReplace =
                current.paneId != paneId.id ||
                !currentUsable ||
                newerSamePaneHostReady

            if shouldReplace {
#if DEBUG
                dlog(
                    "terminal.portal.host.claim surface=\(id.uuidString.prefix(5)) " +
                    "reason=\(reason) host=\(hostId) pane=\(paneId.id.uuidString.prefix(5)) " +
                    "inWin=\(inWindow ? 1 : 0) " +
                    "size=\(String(format: "%.1fx%.1f", bounds.width, bounds.height)) " +
                    "replacingHost=\(current.hostId) replacingPane=\(current.paneId.uuidString.prefix(5)) " +
                    "replacingInWin=\(current.inWindow ? 1 : 0) " +
                    "replacingArea=\(String(format: "%.1f", current.area))"
                )
#endif
                activePortalHostLease = next
                return true
            }

#if DEBUG
            dlog(
                "terminal.portal.host.skip surface=\(id.uuidString.prefix(5)) " +
                "reason=\(reason) host=\(hostId) pane=\(paneId.id.uuidString.prefix(5)) " +
                "inWin=\(inWindow ? 1 : 0) " +
                "size=\(String(format: "%.1fx%.1f", bounds.width, bounds.height)) " +
                "ownerHost=\(current.hostId) ownerPane=\(current.paneId.uuidString.prefix(5)) " +
                "ownerInWin=\(current.inWindow ? 1 : 0) " +
                "ownerArea=\(String(format: "%.1f", current.area))"
            )
#endif
            return false
        }

        activePortalHostLease = next
#if DEBUG
        dlog(
            "terminal.portal.host.claim surface=\(id.uuidString.prefix(5)) " +
            "reason=\(reason) host=\(hostId) pane=\(paneId.id.uuidString.prefix(5)) " +
            "inWin=\(inWindow ? 1 : 0) " +
            "size=\(String(format: "%.1fx%.1f", bounds.width, bounds.height)) replacingHost=nil"
        )
#endif
        return true
    }

    func releasePortalHostIfOwned(hostId: ObjectIdentifier, reason: String) {
        guard let current = activePortalHostLease, current.hostId == hostId else { return }
        activePortalHostLease = nil
#if DEBUG
        dlog(
            "terminal.portal.host.release surface=\(id.uuidString.prefix(5)) " +
            "reason=\(reason) host=\(hostId) pane=\(current.paneId.uuidString.prefix(5)) " +
            "inWin=\(current.inWindow ? 1 : 0) " +
            "area=\(String(format: "%.1f", current.area))"
        )
#endif
    }

    private func recordTeardownRequest(reason: String) {
        withDebugMetadataLock {
            if teardownRequestedAt == nil {
                teardownRequestedAt = Date()
            }
            if let existing = teardownRequestReason, !existing.isEmpty {
                return
            }
            teardownRequestReason = reason
        }
    }

    private func recordRuntimeSurfaceCreation() {
        withDebugMetadataLock {
            runtimeSurfaceCreatedAt = Date()
        }
    }

    private func allowsRuntimeSurfaceCreation() -> Bool {
        portalLifecycleState == .live
    }

    func beginPortalCloseLifecycle(reason: String) {
        guard portalLifecycleState != .closed else { return }
        guard portalLifecycleState != .closing else { return }
        recordTeardownRequest(reason: reason)
        portalLifecycleState = .closing
        portalLifecycleGeneration &+= 1
#if DEBUG
        dlog(
            "surface.lifecycle.close.begin surface=\(id.uuidString.prefix(5)) " +
            "workspace=\(tabId.uuidString.prefix(5)) reason=\(reason) " +
            "generation=\(portalLifecycleGeneration)"
        )
#endif
    }

    private func markPortalLifecycleClosed(reason: String) {
        guard portalLifecycleState != .closed else { return }
        portalLifecycleState = .closed
        portalLifecycleGeneration &+= 1
#if DEBUG
        dlog(
            "surface.lifecycle.close.sealed surface=\(id.uuidString.prefix(5)) " +
            "workspace=\(tabId.uuidString.prefix(5)) reason=\(reason) " +
            "generation=\(portalLifecycleGeneration)"
        )
#endif
    }

    /// Explicitly free the Ghostty runtime surface. Idempotent — safe to call
    /// before deinit; deinit will skip the free if already torn down.
    @MainActor
    func teardownSurface() {
        recordTeardownRequest(reason: "surface.teardown")
        markPortalLifecycleClosed(reason: "teardown")

        let callbackContext = surfaceCallbackContext
        surfaceCallbackContext = nil
        let tapContext = outputTapContext
        outputTapContext = nil

        let surfaceToFree = surface
        if let surfaceToFree {
            TerminalSurfaceRegistry.shared.unregisterRuntimeSurface(surfaceToFree, ownerId: id)
        }
        surface = nil

        guard let surfaceToFree else {
            callbackContext?.release()
            tapContext?.release()
            return
        }

#if DEBUG
        if runtimeSurfaceFreedOutOfBandForTesting {
            runtimeSurfaceFreedOutOfBandForTesting = false
            callbackContext?.release()
            tapContext?.release()
            return
        }
#endif

        Task { @MainActor in
            // Keep free behavior aligned with deinit: perform the runtime teardown on
            // the next main-actor turn so SIGHUP delivery is deterministic but non-reentrant.
            // Clear the output tap right before free, per the C API contract.
            // This is the surface's genuine normal-close path, so delete its
            // WAL directory now that it's torn down.
            SessionWALStore.shared.unregister(surface: surfaceToFree, surfaceId: id.uuidString, deleteDirectory: true)
            ghostty_surface_free(surfaceToFree)
            callbackContext?.release()
            tapContext?.release()
        }
    }

#if DEBUG
    private static let surfaceLogPath = "/tmp/programa-ghostty-surface.log"
    private static let sizeLogPath = "/tmp/programa-ghostty-size.log"

    func debugCurrentPixelSize() -> (width: UInt32, height: UInt32) {
        (lastPixelWidth, lastPixelHeight)
    }

    func debugDesiredFocusState() -> Bool {
        desiredFocusState
    }

    private static func surfaceLog(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        if let handle = FileHandle(forWritingAtPath: surfaceLogPath) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            handle.closeFile()
        } else {
            _ = FileManager.default.createFile(atPath: surfaceLogPath, contents: line.data(using: .utf8))
        }
    }

    private static func sizeLog(_ message: String) {
        let env = ProcessInfo.processInfo.environment
        guard env["PROGRAMA_UI_TEST_SPLIT_CLOSE_RIGHT_VISUAL"] == "1" else { return }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        if let handle = FileHandle(forWritingAtPath: sizeLogPath) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            handle.closeFile()
        } else {
            _ = FileManager.default.createFile(atPath: sizeLogPath, contents: line.data(using: .utf8))
        }
    }
    #endif

    /// Match upstream Ghostty AppKit sizing: framebuffer dimensions are derived
    /// from backing-space points and truncated (never rounded up).
    private func pixelDimension(from value: CGFloat) -> UInt32 {
        guard value.isFinite else { return 0 }
        let floored = floor(max(0, value))
        if floored >= CGFloat(UInt32.max) {
            return UInt32.max
        }
        return UInt32(floored)
    }

    private func scaleFactors(for view: GhosttyNSView) -> (x: CGFloat, y: CGFloat, layer: CGFloat) {
        let scale = max(
            1.0,
            view.window?.backingScaleFactor
                ?? view.layer?.contentsScale
                ?? NSScreen.main?.backingScaleFactor
                ?? 1.0
        )
        return (scale, scale, scale)
    }

    private func scaleApproximatelyEqual(_ lhs: CGFloat, _ rhs: CGFloat, epsilon: CGFloat = 0.0001) -> Bool {
        abs(lhs - rhs) <= epsilon
    }

    func attachToView(_ view: GhosttyNSView) {
#if DEBUG
        dlog(
            "surface.attach surface=\(id.uuidString.prefix(5)) view=\(Unmanaged.passUnretained(view).toOpaque()) " +
            "attached=\(attachedView != nil ? 1 : 0) hasSurface=\(surface != nil ? 1 : 0) inWindow=\(view.window != nil ? 1 : 0)"
        )
#endif

        // If already attached to this view, nothing to do.
        // Still re-assert the display id: during split close tree restructuring, the view can be
        // removed/re-added (or briefly have window/screen nil) without recreating the surface.
        // Ghostty's vsync-driven renderer depends on having a valid display id; if it is missing
        // or stale, the surface can appear visually frozen until a focus/visibility change.
        // SwiftUI also re-enters this path for ordinary state propagation (drag hover, active
        // markers, visibility flags), so avoid forcing a geometry refresh when the attachment
        // itself is unchanged.
        if attachedView === view && surface != nil {
#if DEBUG
            dlog("surface.attach.reuse surface=\(id.uuidString.prefix(5)) view=\(Unmanaged.passUnretained(view).toOpaque())")
#endif
            if let screen = view.window?.screen ?? NSScreen.main,
               let displayID = screen.displayID,
               displayID != 0,
               let s = surface {
                ghostty_surface_set_display_id(s, displayID)
            }
            return
        }

        if let attachedView, attachedView !== view {
#if DEBUG
            dlog(
                "surface.attach.skip surface=\(id.uuidString.prefix(5)) reason=alreadyAttachedToDifferentView " +
                "current=\(Unmanaged.passUnretained(attachedView).toOpaque()) new=\(Unmanaged.passUnretained(view).toOpaque())"
            )
#endif
            return
        }

        attachedView = view

        // If surface doesn't exist yet, create it once the view is in a real window so
        // content scale and pixel geometry are derived from the actual backing context.
        if surface == nil {
            guard allowsRuntimeSurfaceCreation() else {
#if DEBUG
                dlog(
                    "surface.attach.skip surface=\(id.uuidString.prefix(5)) " +
                    "reason=lifecycle.\(portalLifecycleState.rawValue)"
                )
#endif
                return
            }
            guard view.window != nil else {
#if DEBUG
                dlog(
                    "surface.attach.defer surface=\(id.uuidString.prefix(5)) reason=noWindow " +
                    "bounds=\(String(format: "%.1fx%.1f", view.bounds.width, view.bounds.height))"
                )
#endif
                return
            }
#if DEBUG
            dlog("surface.attach.create surface=\(id.uuidString.prefix(5))")
#endif
            createSurface(for: view)
#if DEBUG
            dlog("surface.attach.create.done surface=\(id.uuidString.prefix(5)) hasSurface=\(surface != nil ? 1 : 0)")
#endif
        } else if let screen = view.window?.screen ?? NSScreen.main,
                  let displayID = screen.displayID,
                  displayID != 0,
                  let s = surface {
            // Surface exists but we're (re)attaching after a view hierarchy move; ensure display id.
            ghostty_surface_set_display_id(s, displayID)
#if DEBUG
            dlog("surface.attach.displayId surface=\(id.uuidString.prefix(5)) display=\(displayID)")
#endif
        }
    }

    private func createSurface(for view: GhosttyNSView) {
        guard allowsRuntimeSurfaceCreation() else {
#if DEBUG
            dlog(
                "surface.create.skip surface=\(id.uuidString.prefix(5)) " +
                "reason=lifecycle.\(portalLifecycleState.rawValue)"
            )
            Self.surfaceLog(
                "createSurface SKIPPED surface=\(id.uuidString) tab=\(tabId.uuidString) lifecycle=\(portalLifecycleState.rawValue)"
            )
#endif
            return
        }
        #if DEBUG
        let resourcesDir = getenv("GHOSTTY_RESOURCES_DIR").flatMap { String(cString: $0) } ?? "(unset)"
        let terminfo = getenv("TERMINFO").flatMap { String(cString: $0) } ?? "(unset)"
        let xdg = getenv("XDG_DATA_DIRS").flatMap { String(cString: $0) } ?? "(unset)"
        let manpath = getenv("MANPATH").flatMap { String(cString: $0) } ?? "(unset)"
        Self.surfaceLog("createSurface start surface=\(id.uuidString) tab=\(tabId.uuidString) bounds=\(view.bounds) inWindow=\(view.window != nil) resources=\(resourcesDir) terminfo=\(terminfo) xdg=\(xdg) manpath=\(manpath)")
        #endif

        guard let app = GhosttyApp.shared.app else {
            print("Ghostty app not initialized")
            #if DEBUG
            Self.surfaceLog("createSurface FAILED surface=\(id.uuidString): ghostty app not initialized")
            #endif
            return
        }

        let scaleFactors = scaleFactors(for: view)

        var baseConfig = configTemplate ?? ProgramaSurfaceConfigTemplate()
        var surfaceConfig = ghostty_surface_config_new()
        surfaceConfig.font_size = baseConfig.fontSize
        surfaceConfig.wait_after_command = baseConfig.waitAfterCommand
        surfaceConfig.platform_tag = GHOSTTY_PLATFORM_MACOS
        surfaceConfig.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
            nsview: Unmanaged.passUnretained(view).toOpaque()
        ))
        let callbackContext = Unmanaged.passRetained(GhosttySurfaceCallbackContext(surfaceView: view, terminalSurface: self))
        surfaceConfig.userdata = callbackContext.toOpaque()
        surfaceCallbackContext?.release()
        surfaceCallbackContext = callbackContext
        surfaceConfig.scale_factor = scaleFactors.layer
        surfaceConfig.context = surfaceContext
#if DEBUG
        let templateFontText = String(format: "%.2f", surfaceConfig.font_size)
        dlog(
            "zoom.create surface=\(id.uuidString.prefix(5)) context=\(programaSurfaceContextName(surfaceContext)) " +
            "templateFont=\(templateFontText)"
        )
#endif
        var envVars: [ghostty_env_var_s] = []
        var envStorage: [(UnsafeMutablePointer<CChar>, UnsafeMutablePointer<CChar>)] = []
        defer {
            for (key, value) in envStorage {
                free(key)
                free(value)
            }
        }

        var env = baseConfig.environmentVariables

        var protectedStartupEnvironmentKeys: Set<String> = []
        Self.applyManagedTerminalIdentityEnvironment(
            to: &env,
            protectedKeys: &protectedStartupEnvironmentKeys
        )
        func setManagedEnvironmentValue(_ key: String, _ value: String) {
            env[key] = value
            protectedStartupEnvironmentKeys.insert(key)
        }

        setManagedEnvironmentValue("PROGRAMA_SURFACE_ID", id.uuidString)
        setManagedEnvironmentValue("PROGRAMA_WORKSPACE_ID", tabId.uuidString)
        // Backward-compatible shell integration keys used by existing scripts/tests.
        setManagedEnvironmentValue("PROGRAMA_PANEL_ID", id.uuidString)
        setManagedEnvironmentValue("PROGRAMA_TAB_ID", tabId.uuidString)
        let socketPath = SocketControlSettings.socketPath()
        setManagedEnvironmentValue("PROGRAMA_SOCKET_PATH", socketPath)
        // Backward-compatible alias expected by older scripts and third-party integrations.
        setManagedEnvironmentValue("PROGRAMA_SOCKET", socketPath)
        if let bundledCLIURL = Bundle.main.resourceURL?.appendingPathComponent("bin/programa"),
           FileManager.default.isExecutableFile(atPath: bundledCLIURL.path) {
            setManagedEnvironmentValue("PROGRAMA_BUNDLED_CLI_PATH", bundledCLIURL.path)
        }
        if let bundleId = Bundle.main.bundleIdentifier, !bundleId.isEmpty {
            setManagedEnvironmentValue("PROGRAMA_BUNDLE_ID", bundleId)
        }

        // Port range for this workspace (base/range snapshotted once per app session)
        do {
            let startPort = Self.sessionPortBase + portOrdinal * Self.sessionPortRangeSize
            setManagedEnvironmentValue("PROGRAMA_PORT", String(startPort))
            setManagedEnvironmentValue("PROGRAMA_PORT_END", String(startPort + Self.sessionPortRangeSize - 1))
            setManagedEnvironmentValue("PROGRAMA_PORT_RANGE", String(Self.sessionPortRangeSize))
        }

        let claudeHooksEnabled = ClaudeCodeIntegrationSettings.hooksEnabled()
        if !claudeHooksEnabled {
            setManagedEnvironmentValue("PROGRAMA_CLAUDE_HOOKS_DISABLED", "1")
        }
        if let customClaudePath = ClaudeCodeIntegrationSettings.customClaudePath() {
            setManagedEnvironmentValue("PROGRAMA_CUSTOM_CLAUDE_PATH", customClaudePath)
        }

        if let cliBinPath = Bundle.main.resourceURL?.appendingPathComponent("bin").path {
            let currentPath = env["PATH"]
                ?? getenv("PATH").map { String(cString: $0) }
                ?? ProcessInfo.processInfo.environment["PATH"]
                ?? ""
            if !currentPath.split(separator: ":").contains(Substring(cliBinPath)) {
                let separator = currentPath.isEmpty ? "" : ":"
                setManagedEnvironmentValue("PATH", "\(cliBinPath)\(separator)\(currentPath)")
            }
        }

        // Shell integration: inject ZDOTDIR wrapper for zsh shells.
        let shellIntegrationEnabled = UserDefaults.standard.object(forKey: "sidebarShellIntegration") as? Bool ?? true
        if shellIntegrationEnabled,
           let integrationDir = Bundle.main.resourceURL?.appendingPathComponent("shell-integration").path {
            setManagedEnvironmentValue("PROGRAMA_SHELL_INTEGRATION", "1")
            setManagedEnvironmentValue("PROGRAMA_SHELL_INTEGRATION_DIR", integrationDir)

            let shell = (env["SHELL"]?.isEmpty == false ? env["SHELL"] : nil)
                ?? getenv("SHELL").map { String(cString: $0) }
                ?? ProcessInfo.processInfo.environment["SHELL"]
                ?? "/bin/zsh"
            let shellName = URL(fileURLWithPath: shell).lastPathComponent
            if shellName == "zsh" {
                if GhosttyApp.shared.shellIntegrationMode() != "none" {
                    setManagedEnvironmentValue("PROGRAMA_LOAD_GHOSTTY_ZSH_INTEGRATION", "1")
                }
                let candidateZdotdir = (env["ZDOTDIR"]?.isEmpty == false ? env["ZDOTDIR"] : nil)
                    ?? getenv("ZDOTDIR").map { String(cString: $0) }
                    ?? (ProcessInfo.processInfo.environment["ZDOTDIR"]?.isEmpty == false ? ProcessInfo.processInfo.environment["ZDOTDIR"] : nil)

                if let candidateZdotdir, !candidateZdotdir.isEmpty {
                    var isGhosttyInjected = false
                    let ghosttyResources = (env["GHOSTTY_RESOURCES_DIR"]?.isEmpty == false ? env["GHOSTTY_RESOURCES_DIR"] : nil)
                        ?? getenv("GHOSTTY_RESOURCES_DIR").map { String(cString: $0) }
                        ?? (ProcessInfo.processInfo.environment["GHOSTTY_RESOURCES_DIR"]?.isEmpty == false ? ProcessInfo.processInfo.environment["GHOSTTY_RESOURCES_DIR"] : nil)
                    if let ghosttyResources {
                        let ghosttyZdotdir = URL(fileURLWithPath: ghosttyResources)
                            .appendingPathComponent("shell-integration/zsh").path
                        isGhosttyInjected = (candidateZdotdir == ghosttyZdotdir)
                    }
                    if !isGhosttyInjected {
                        setManagedEnvironmentValue("PROGRAMA_ZSH_ZDOTDIR", candidateZdotdir)
                    }
                }

                setManagedEnvironmentValue("ZDOTDIR", integrationDir)
            } else if shellName == "bash" {
                if GhosttyApp.shared.shellIntegrationMode() != "none" {
                    setManagedEnvironmentValue("PROGRAMA_LOAD_GHOSTTY_BASH_INTEGRATION", "1")
                }
                // macOS ships /bin/bash 3.2, where Ghostty's automatic bash
                // integration is unsupported and HOME-based wrapper startup is
                // not reliable. Bootstrap Programa bash integration on the
                // first interactive prompt by exporting the shared bootstrap
                // script as PROMPT_COMMAND. The script lives in
                // Resources/shell-integration so the app and the regression
                // test share one source of truth. Doc comments and blank
                // lines are stripped so users never see them in
                // $PROMPT_COMMAND; the test mirrors this.
                let bashBootstrapPath = (integrationDir as NSString)
                    .appendingPathComponent("programa-bash-bootstrap.bash")
                if let rawBootstrap = try? String(contentsOfFile: bashBootstrapPath, encoding: .utf8) {
                    let bootstrap = rawBootstrap
                        .components(separatedBy: "\n")
                        .filter { line in
                            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                            return !trimmed.isEmpty && !trimmed.hasPrefix("#")
                        }
                        .joined(separator: "\n")
                    if !bootstrap.isEmpty {
                        setManagedEnvironmentValue("PROMPT_COMMAND", bootstrap)
                    }
                }
            } else if shellName == "fish" {
                Self.applyManagedFishStartupEnvironment(
                    integrationDir: integrationDir,
                    to: &env,
                    protectedKeys: &protectedStartupEnvironmentKeys
                )
                if baseConfig.command?.isEmpty != false {
                    baseConfig.command = Self.managedFishShellCommand(shell: shell)
                }
            }
        }
        env = Self.mergedStartupEnvironment(
            base: env,
            protectedKeys: protectedStartupEnvironmentKeys,
            additionalEnvironment: additionalEnvironment,
            initialEnvironmentOverrides: initialEnvironmentOverrides
        )

        if !env.isEmpty {
            envVars.reserveCapacity(env.count)
            envStorage.reserveCapacity(env.count)
            for (key, value) in env {
                guard let keyPtr = strdup(key), let valuePtr = strdup(value) else { continue }
                envStorage.append((keyPtr, valuePtr))
                envVars.append(ghostty_env_var_s(key: keyPtr, value: valuePtr))
            }
        }

        let createSurface = { [self] in
            if !envVars.isEmpty {
                let envVarsCount = envVars.count
                envVars.withUnsafeMutableBufferPointer { buffer in
                    surfaceConfig.env_vars = buffer.baseAddress
                    surfaceConfig.env_var_count = envVarsCount
                    self.surface = ghostty_surface_new(app, &surfaceConfig)
                }
            } else {
                self.surface = ghostty_surface_new(app, &surfaceConfig)
            }
        }

        let resolvedWorkingDirectory: String? = {
            if let workingDirectory, !workingDirectory.isEmpty {
                return workingDirectory
            }
            return baseConfig.workingDirectory
        }()
        let resolvedCommand: String? = {
            if let initialCommand, !initialCommand.isEmpty {
                return initialCommand
            }
            return baseConfig.command
        }()
        let resolvedInitialInput = baseConfig.initialInput
        func withOptionalCString<T>(_ value: String?, _ body: (UnsafePointer<CChar>?) -> T) -> T {
            guard let value else {
                return body(nil)
            }
            return value.withCString(body)
        }

        let createWithCommandAndWorkingDirectory = {
            withOptionalCString(resolvedCommand) { cCommand in
                surfaceConfig.command = cCommand
                withOptionalCString(resolvedWorkingDirectory) { cWorkingDir in
                    surfaceConfig.working_directory = cWorkingDir
                    withOptionalCString(resolvedInitialInput) { cInitialInput in
                        surfaceConfig.initial_input = cInitialInput
                        createSurface()
                    }
                }
            }
        }

        createWithCommandAndWorkingDirectory()

        if surface == nil {
            surfaceCallbackContext?.release()
            surfaceCallbackContext = nil
            print("Failed to create ghostty surface")
            #if DEBUG
            Self.surfaceLog("createSurface FAILED surface=\(id.uuidString): ghostty_surface_new returned nil")
            if let cfg = GhosttyApp.shared.config {
                let count = Int(ghostty_config_diagnostics_count(cfg))
                Self.surfaceLog("createSurface diagnostics count=\(count)")
                for i in 0..<count {
                    let diag = ghostty_config_get_diagnostic(cfg, UInt32(i))
                    let msg = diag.message.flatMap { String(cString: $0) } ?? "(null)"
                    Self.surfaceLog("  [\(i)] \(msg)")
                }
            } else {
                Self.surfaceLog("createSurface diagnostics: config=nil")
            }
            #endif
            return
        }
        guard let createdSurface = surface else { return }
        TerminalSurfaceRegistry.shared.registerRuntimeSurface(createdSurface, ownerId: id)
        recordRuntimeSurfaceCreation()

        // Register the PTY output tap now that the runtime surface definitely
        // exists, wiring it into the session WAL writer. See
        // SessionOutputTapSpike.swift (SessionWALStore).
        outputTapContext?.release()
        outputTapContext = SessionWALStore.shared.register(
            surface: createdSurface,
            surfaceId: id.uuidString,
            workingDirectory: resolvedWorkingDirectory
        )

        // Session scrollback replay must be one-shot. Reusing it on a later runtime
        // surface recreation would inject stale restored output into a live shell.
        additionalEnvironment.removeValue(forKey: SessionScrollbackReplayStore.environmentKey)

        // For vsync-driven rendering, Ghostty needs to know which display we're on so it can
        // start a CVDisplayLink with the right refresh rate. If we don't set this early, the
        // renderer can believe vsync is "running" but never deliver frames, which looks like a
        // frozen terminal until focus/visibility changes force a synchronous draw.
        //
        // `view.window?.screen` can be transiently nil during early attachment; fall back to the
        // primary screen so we always set *some* display ID, then update again on screen changes.
        if let screen = view.window?.screen ?? NSScreen.main,
           let displayID = screen.displayID,
           displayID != 0 {
            ghostty_surface_set_display_id(createdSurface, displayID)
        }

        ghostty_surface_set_content_scale(createdSurface, scaleFactors.x, scaleFactors.y)
        let backingSize = view.convertToBacking(NSRect(origin: .zero, size: view.bounds.size)).size
        let wpx = pixelDimension(from: backingSize.width)
        let hpx = pixelDimension(from: backingSize.height)
        if wpx > 0, hpx > 0 {
            ghostty_surface_set_size(createdSurface, wpx, hpx)
            lastPixelWidth = wpx
            lastPixelHeight = hpx
            lastXScale = scaleFactors.x
            lastYScale = scaleFactors.y
        }

        // Some GhosttyKit builds can drop inherited font_size during post-create
        // config/scale reconciliation. If runtime points don't match the inherited
        // template points, re-apply via binding action so all creation paths
        // (new surface, split, new workspace) preserve zoom from the source terminal.
        if let inheritedFontPoints = configTemplate?.fontSize,
           inheritedFontPoints > 0 {
            let currentFontPoints = programaCurrentSurfaceFontSizePoints(createdSurface)
            let shouldReapply = {
                guard let currentFontPoints else { return true }
                return abs(currentFontPoints - inheritedFontPoints) > 0.05
            }()
            if shouldReapply {
                let action = String(format: "set_font_size:%.3f", inheritedFontPoints)
                _ = performBindingAction(action)
            }
        }

        // Re-apply the desired focus state after creation so the live runtime
        // surface converges with any focus changes that happened while the
        // surface was being initialized.
        ghostty_surface_set_focus(createdSurface, desiredFocusState)

        flushPendingSocketInputIfNeeded()

        // Kick an initial draw after creation/size setup. On some startup paths Ghostty can
        // miss the first vsync callback and sit on a blank frame until another focus/visibility
        // transition nudges the renderer.
        view.forceRefreshSurface()
        ghostty_surface_refresh(createdSurface)

        NotificationCenter.default.post(
            name: .terminalSurfaceDidBecomeReady,
            object: self,
            userInfo: [
                "surfaceId": id,
                "workspaceId": tabId
            ]
        )
        isSurfaceReady = true

#if DEBUG
        let runtimeFontText = programaCurrentSurfaceFontSizePoints(createdSurface).map {
            String(format: "%.2f", $0)
        } ?? "nil"
        dlog(
            "zoom.create.done surface=\(id.uuidString.prefix(5)) context=\(programaSurfaceContextName(surfaceContext)) " +
            "runtimeFont=\(runtimeFontText)"
        )
#endif
    }

    @discardableResult
    func updateSize(
        width: CGFloat,
        height: CGFloat,
        xScale: CGFloat,
        yScale: CGFloat,
        layerScale: CGFloat,
        backingSize: CGSize? = nil
    ) -> Bool {
        guard let surface = surface else { return false }
        _ = layerScale

        let resolvedBackingWidth = backingSize?.width ?? (width * xScale)
        let resolvedBackingHeight = backingSize?.height ?? (height * yScale)
        let wpx = pixelDimension(from: resolvedBackingWidth)
        let hpx = pixelDimension(from: resolvedBackingHeight)
        guard wpx > 0, hpx > 0 else { return false }

        let scaleChanged = !scaleApproximatelyEqual(xScale, lastXScale) || !scaleApproximatelyEqual(yScale, lastYScale)
        let sizeChanged = wpx != lastPixelWidth || hpx != lastPixelHeight

        #if DEBUG
        Self.sizeLog("updateSize-call surface=\(id.uuidString.prefix(8)) size=\(wpx)x\(hpx) prev=\(lastPixelWidth)x\(lastPixelHeight) changed=\((scaleChanged || sizeChanged) ? 1 : 0)")
        #endif

        guard scaleChanged || sizeChanged else { return false }

        #if DEBUG
        if sizeChanged {
            let win = attachedView?.window != nil ? "1" : "0"
            Self.sizeLog("updateSize surface=\(id.uuidString.prefix(8)) size=\(wpx)x\(hpx) prev=\(lastPixelWidth)x\(lastPixelHeight) win=\(win)")
        }
        #endif

        if scaleChanged {
            ghostty_surface_set_content_scale(surface, xScale, yScale)
            lastXScale = xScale
            lastYScale = yScale
        }

        if sizeChanged {
            ghostty_surface_set_size(surface, wpx, hpx)
            lastPixelWidth = wpx
            lastPixelHeight = hpx
        }

        // Let Ghostty continue rendering on its own wakeups for steady-state frames.
        return true
    }

    /// Force a full size recalculation and surface redraw.
    func forceRefresh(reason: String = "unspecified") {
        let hasSurface = surface != nil
        let viewState: String
        if let view = attachedView {
            let inWindow = view.window != nil
            let bounds = view.bounds
            let metalOK = (view.layer as? CAMetalLayer) != nil
            viewState = "inWindow=\(inWindow) bounds=\(bounds) metalOK=\(metalOK) hasSurface=\(hasSurface)"
        } else {
            viewState = "NO_ATTACHED_VIEW hasSurface=\(hasSurface)"
        }
        #if DEBUG
        dlog("forceRefresh: \(id) reason=\(reason) \(viewState)")
        #endif
        guard let view = attachedView,
              view.window != nil,
              view.bounds.width > 0,
              view.bounds.height > 0 else {
            return
        }
        guard let currentSurface = self.surface else { return }

        // Re-read self.surface before each ghostty call to guard against the surface
        // being freed during wake-from-sleep geometry reconciliation (issue #432).
        // The surface can be invalidated between calls when AppKit layout triggers
        // view lifecycle changes (e.g., forceRefreshSurface → layout → deinit → free).

        // Reassert display id on topology churn (split close/reparent) before forcing a refresh.
        // This avoids a first-run stuck-vsync state where Ghostty believes vsync is active
        // but callbacks have not resumed for the current display.
        if let displayID = (view.window?.screen ?? NSScreen.main)?.displayID,
           displayID != 0 {
            ghostty_surface_set_display_id(currentSurface, displayID)
        }

        view.forceRefreshSurface()
        guard let surface = self.surface else { return }
        ghostty_surface_refresh(surface)
    }

    func applyWindowBackgroundIfActive() {
        surfaceView.applyWindowBackgroundIfActive()
    }

    /// Keep `desiredFocusState` in sync when the hosted view's responder chain
    /// calls `ghostty_surface_set_focus` directly (bypassing `setFocus`).
    /// Without this, `createSurface` would replay a stale state on recreation.
    ///
    /// `desiredFocusState` must have exactly one writer per focus transition:
    /// either this method (paired with a direct `ghostty_surface_set_focus` call,
    /// or standing in for one that's deferred) or `setFocus`, never both for the
    /// same transition. Calling this immediately before `setFocus` for the same
    /// transition pre-sets the value `setFocus`'s dedup guard checks against,
    /// which makes it silently skip the real `ghostty_surface_set_focus` push.
    func recordExternalFocusState(_ focused: Bool) {
        desiredFocusState = focused
    }

    func setFocus(_ focused: Bool) {
        // Only send focus events when the state changes to avoid redundant
        // prompt redraws with zsh themes like Powerlevel10k.
        guard focused != desiredFocusState else { return }
        desiredFocusState = focused
        // Track desired state even before the C surface exists (e.g. during
        // layout restoration). createSurface syncs the state once created.
        guard let surface = surface else { return }
        ghostty_surface_set_focus(surface, focused)

        // If we focus a surface while it is being rapidly reparented (closing splits, etc),
        // Ghostty's CVDisplayLink can end up started before the display id is valid, leaving
        // hasVsync() true but with no callbacks ("stuck-vsync-no-frames"). Reasserting the
        // display id *after* focusing lets Ghostty restart the display link when needed.
        if focused {
            if let view = attachedView,
               let displayID = (view.window?.screen ?? NSScreen.main)?.displayID,
               displayID != 0 {
                ghostty_surface_set_display_id(surface, displayID)
            }
        }
    }

    func setOcclusion(_ visible: Bool) {
        guard let surface = surface else { return }
        ghostty_surface_set_occlusion(surface, visible)
    }

    func needsConfirmClose() -> Bool {
#if DEBUG
        if let needsConfirmCloseOverrideForTesting {
            return needsConfirmCloseOverrideForTesting
        }
#endif
        guard let surface = surface else { return false }
        return ghostty_surface_needs_confirm_quit(surface)
    }

    func sendText(_ text: String) {
        guard let data = text.data(using: .utf8), !data.isEmpty else { return }
        guard let surface = surface else {
            enqueuePendingSocketInput(.text(data))
            requestBackgroundSurfaceStartIfNeeded()
            return
        }
        writeTextData(data, to: surface)
    }

    @discardableResult
    func sendNamedKey(_ keyName: String) -> Bool {
        guard let event = pendingKeyEvent(for: keyName) else { return false }
        if let surface = surface {
            sendKeyEvent(surface: surface, keycode: event.keycode, mods: event.mods)
        } else {
            enqueuePendingSocketInput(.key(event))
            requestBackgroundSurfaceStartIfNeeded()
        }
        return true
    }

    /// Send text with control characters (Return, Tab, etc.) delivered as key
    /// events so the shell processes them, while regular text is sent via the
    /// normal key-text path.  Mirrors `TerminalController.sendSocketText`.
    func sendInput(_ text: String) {
        guard let surface = surface else { return }
        var bufferedText = ""
        var previousWasCR = false
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0A: // \n — skip if preceded by \r (already sent Return)
                if !previousWasCR {
                    flushText(&bufferedText, surface: surface)
                    sendKeyEvent(surface: surface, keycode: 0x24) // kVK_Return
                }
                previousWasCR = false
            case 0x0D:
                flushText(&bufferedText, surface: surface)
                sendKeyEvent(surface: surface, keycode: 0x24) // kVK_Return
                previousWasCR = true
            case 0x09:
                flushText(&bufferedText, surface: surface)
                sendKeyEvent(surface: surface, keycode: 0x30) // kVK_Tab
                previousWasCR = false
            case 0x1B:
                flushText(&bufferedText, surface: surface)
                sendKeyEvent(surface: surface, keycode: 0x35) // kVK_Escape
                previousWasCR = false
            default:
                bufferedText.unicodeScalars.append(scalar)
                previousWasCR = false
            }
        }
        flushText(&bufferedText, surface: surface)
    }

    private func flushText(_ buffer: inout String, surface: ghostty_surface_t) {
        guard !buffer.isEmpty else { return }
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = GHOSTTY_ACTION_PRESS
        keyEvent.keycode = 0
        keyEvent.mods = GHOSTTY_MODS_NONE
        keyEvent.consumed_mods = GHOSTTY_MODS_NONE
        keyEvent.unshifted_codepoint = 0
        keyEvent.composing = false
        buffer.withCString { ptr in
            keyEvent.text = ptr
            _ = ghostty_surface_key(surface, keyEvent)
        }
        buffer.removeAll(keepingCapacity: true)
    }

    private func sendKeyEvent(
        surface: ghostty_surface_t,
        keycode: UInt32,
        mods: ghostty_input_mods_e = GHOSTTY_MODS_NONE
    ) {
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = GHOSTTY_ACTION_PRESS
        keyEvent.keycode = keycode
        keyEvent.mods = mods
        keyEvent.consumed_mods = GHOSTTY_MODS_NONE
        keyEvent.unshifted_codepoint = 0
        keyEvent.composing = false
        keyEvent.text = nil
        _ = ghostty_surface_key(surface, keyEvent)
    }

    func requestBackgroundSurfaceStartIfNeeded() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.requestBackgroundSurfaceStartIfNeeded()
            }
            return
        }

        guard allowsRuntimeSurfaceCreation() else { return }
        guard surface == nil, attachedView != nil else { return }
        guard !backgroundSurfaceStartQueued else { return }
        backgroundSurfaceStartQueued = true

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.backgroundSurfaceStartQueued = false
            guard self.allowsRuntimeSurfaceCreation() else { return }
            guard self.surface == nil, let view = self.attachedView else { return }
            #if DEBUG
            let startedAt = ProcessInfo.processInfo.systemUptime
            #endif
            self.createSurface(for: view)
            #if DEBUG
            let elapsedMs = (ProcessInfo.processInfo.systemUptime - startedAt) * 1000.0
            dlog(
                "surface.background_start surface=\(self.id.uuidString.prefix(8)) inWindow=\(view.window != nil ? 1 : 0) ready=\(self.surface != nil ? 1 : 0) ms=\(String(format: "%.2f", elapsedMs))"
            )
            #endif
        }
    }

    private func writeTextData(_ data: Data, to surface: ghostty_surface_t) {
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
            ghostty_surface_text(surface, baseAddress, UInt(rawBuffer.count))
        }
    }

    private func keycodeForLetter(_ letter: Character) -> UInt32? {
        switch String(letter).lowercased() {
        case "a": return UInt32(kVK_ANSI_A)
        case "b": return UInt32(kVK_ANSI_B)
        case "c": return UInt32(kVK_ANSI_C)
        case "d": return UInt32(kVK_ANSI_D)
        case "e": return UInt32(kVK_ANSI_E)
        case "f": return UInt32(kVK_ANSI_F)
        case "g": return UInt32(kVK_ANSI_G)
        case "h": return UInt32(kVK_ANSI_H)
        case "i": return UInt32(kVK_ANSI_I)
        case "j": return UInt32(kVK_ANSI_J)
        case "k": return UInt32(kVK_ANSI_K)
        case "l": return UInt32(kVK_ANSI_L)
        case "m": return UInt32(kVK_ANSI_M)
        case "n": return UInt32(kVK_ANSI_N)
        case "o": return UInt32(kVK_ANSI_O)
        case "p": return UInt32(kVK_ANSI_P)
        case "q": return UInt32(kVK_ANSI_Q)
        case "r": return UInt32(kVK_ANSI_R)
        case "s": return UInt32(kVK_ANSI_S)
        case "t": return UInt32(kVK_ANSI_T)
        case "u": return UInt32(kVK_ANSI_U)
        case "v": return UInt32(kVK_ANSI_V)
        case "w": return UInt32(kVK_ANSI_W)
        case "x": return UInt32(kVK_ANSI_X)
        case "y": return UInt32(kVK_ANSI_Y)
        case "z": return UInt32(kVK_ANSI_Z)
        default: return nil
        }
    }

    private func keycodeForNamedKey(_ name: String) -> UInt32? {
        switch name {
        case "enter", "return": return UInt32(kVK_Return)
        case "tab": return UInt32(kVK_Tab)
        case "escape", "esc": return UInt32(kVK_Escape)
        case "backspace": return UInt32(kVK_Delete)
        case "delete": return UInt32(kVK_ForwardDelete)
        case "space": return UInt32(kVK_Space)
        case "up": return UInt32(kVK_UpArrow)
        case "down": return UInt32(kVK_DownArrow)
        case "left": return UInt32(kVK_LeftArrow)
        case "right": return UInt32(kVK_RightArrow)
        case "\\": return UInt32(kVK_ANSI_Backslash)
        default: return nil
        }
    }

    private func pendingKeyEvent(for keyName: String) -> PendingKeyEvent? {
        let normalized = keyName.lowercased()
        switch normalized {
        case "ctrl-c", "ctrl+c", "sigint":
            return PendingKeyEvent(keycode: UInt32(kVK_ANSI_C), mods: GHOSTTY_MODS_CTRL, label: normalized)
        case "ctrl-d", "ctrl+d", "eof":
            return PendingKeyEvent(keycode: UInt32(kVK_ANSI_D), mods: GHOSTTY_MODS_CTRL, label: normalized)
        case "ctrl-z", "ctrl+z", "sigtstp":
            return PendingKeyEvent(keycode: UInt32(kVK_ANSI_Z), mods: GHOSTTY_MODS_CTRL, label: normalized)
        case "ctrl-\\", "ctrl+\\", "sigquit":
            return PendingKeyEvent(keycode: UInt32(kVK_ANSI_Backslash), mods: GHOSTTY_MODS_CTRL, label: normalized)
        case "enter", "return":
            return PendingKeyEvent(keycode: UInt32(kVK_Return), mods: GHOSTTY_MODS_NONE, label: normalized)
        case "tab":
            return PendingKeyEvent(keycode: UInt32(kVK_Tab), mods: GHOSTTY_MODS_NONE, label: normalized)
        case "escape", "esc":
            return PendingKeyEvent(keycode: UInt32(kVK_Escape), mods: GHOSTTY_MODS_NONE, label: normalized)
        case "backspace":
            return PendingKeyEvent(keycode: UInt32(kVK_Delete), mods: GHOSTTY_MODS_NONE, label: normalized)
        case "up", "arrow_up", "arrowup":
            return PendingKeyEvent(keycode: UInt32(kVK_UpArrow), mods: GHOSTTY_MODS_NONE, label: normalized)
        case "down", "arrow_down", "arrowdown":
            return PendingKeyEvent(keycode: UInt32(kVK_DownArrow), mods: GHOSTTY_MODS_NONE, label: normalized)
        case "left", "arrow_left", "arrowleft":
            return PendingKeyEvent(keycode: UInt32(kVK_LeftArrow), mods: GHOSTTY_MODS_NONE, label: normalized)
        case "right", "arrow_right", "arrowright":
            return PendingKeyEvent(keycode: UInt32(kVK_RightArrow), mods: GHOSTTY_MODS_NONE, label: normalized)
        case "shift+tab", "shift-tab", "backtab":
            return PendingKeyEvent(keycode: UInt32(kVK_Tab), mods: GHOSTTY_MODS_SHIFT, label: normalized)
        case "home":
            return PendingKeyEvent(keycode: UInt32(kVK_Home), mods: GHOSTTY_MODS_NONE, label: normalized)
        case "end":
            return PendingKeyEvent(keycode: UInt32(kVK_End), mods: GHOSTTY_MODS_NONE, label: normalized)
        case "delete", "del", "forward_delete":
            return PendingKeyEvent(keycode: UInt32(kVK_ForwardDelete), mods: GHOSTTY_MODS_NONE, label: normalized)
        case "pageup", "page_up":
            return PendingKeyEvent(keycode: UInt32(kVK_PageUp), mods: GHOSTTY_MODS_NONE, label: normalized)
        case "pagedown", "page_down":
            return PendingKeyEvent(keycode: UInt32(kVK_PageDown), mods: GHOSTTY_MODS_NONE, label: normalized)
        default:
            let parts = normalized
                .split(separator: "+")
                .flatMap { $0.split(separator: "-") }
                .map(String.init)
                .filter { !$0.isEmpty }
            guard let baseKey = parts.last else { return nil }

            if parts.count == 1 {
                if let keycode = keycodeForNamedKey(baseKey) {
                    return PendingKeyEvent(keycode: keycode, mods: GHOSTTY_MODS_NONE, label: normalized)
                }
                if baseKey.count == 1,
                   let char = baseKey.first,
                   let keycode = keycodeForLetter(char) {
                    return PendingKeyEvent(keycode: keycode, mods: GHOSTTY_MODS_NONE, label: normalized)
                }
                return nil
            }

            var mods = GHOSTTY_MODS_NONE
            for mod in parts.dropLast() {
                switch mod {
                case "ctrl", "control":
                    mods = ghostty_input_mods_e(rawValue: mods.rawValue | GHOSTTY_MODS_CTRL.rawValue)
                case "shift":
                    mods = ghostty_input_mods_e(rawValue: mods.rawValue | GHOSTTY_MODS_SHIFT.rawValue)
                case "alt", "opt", "option":
                    mods = ghostty_input_mods_e(rawValue: mods.rawValue | GHOSTTY_MODS_ALT.rawValue)
                case "cmd", "command", "super":
                    mods = ghostty_input_mods_e(rawValue: mods.rawValue | GHOSTTY_MODS_SUPER.rawValue)
                default:
                    return nil
                }
            }

            if let keycode = keycodeForNamedKey(baseKey) {
                return PendingKeyEvent(keycode: keycode, mods: mods, label: normalized)
            }
            if baseKey.count == 1,
               let char = baseKey.first,
               let keycode = keycodeForLetter(char) {
                return PendingKeyEvent(keycode: keycode, mods: mods, label: normalized)
            }
            return nil
        }
    }

    private func enqueuePendingSocketInput(_ input: PendingSocketInput) {
        let incomingBytes = input.estimatedBytes
        while !pendingSocketInputQueue.isEmpty,
              pendingSocketInputBytes + incomingBytes > maxPendingSocketInputBytes {
            let dropped = pendingSocketInputQueue.removeFirst()
            pendingSocketInputBytes -= dropped.estimatedBytes
        }

        pendingSocketInputQueue.append(input)
        pendingSocketInputBytes += incomingBytes
#if DEBUG
        let pendingKeys = pendingSocketInputQueue.reduce(into: 0) { count, item in
            if case .key = item {
                count += 1
            }
        }
        dlog(
            "surface.socket_input.queue surface=\(id.uuidString.prefix(8)) items=\(pendingSocketInputQueue.count) " +
            "keys=\(pendingKeys) bytes=\(pendingSocketInputBytes)"
        )
#endif
    }

    private func flushPendingSocketInputIfNeeded() {
        guard let surface = surface, !pendingSocketInputQueue.isEmpty else { return }
        let queued = pendingSocketInputQueue
        let queuedBytes = pendingSocketInputBytes
        pendingSocketInputQueue.removeAll(keepingCapacity: false)
        pendingSocketInputBytes = 0

        var queuedKeys = 0
        for item in queued {
            switch item {
            case .text(let chunk):
                writeTextData(chunk, to: surface)
            case .key(let event):
                queuedKeys += 1
                sendKeyEvent(surface: surface, keycode: event.keycode, mods: event.mods)
            }
        }
#if DEBUG
        dlog(
            "surface.socket_input.flush surface=\(id.uuidString.prefix(8)) items=\(queued.count) " +
            "keys=\(queuedKeys) bytes=\(queuedBytes)"
        )
#endif
    }

    func performBindingAction(_ action: String) -> Bool {
        guard let surface = surface else { return false }
        return action.withCString { cString in
            ghostty_surface_binding_action(surface, cString, UInt(strlen(cString)))
        }
    }

    @discardableResult
    func toggleKeyboardCopyMode() -> Bool {
        let handled = surfaceView.toggleKeyboardCopyMode()
        if handled {
            setKeyboardCopyModeActive(surfaceView.isKeyboardCopyModeActive)
        }
        return handled
    }

    func setKeyboardCopyModeActive(_ active: Bool) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.setKeyboardCopyModeActive(active)
            }
            return
        }

        if keyboardCopyModeActive != active {
            keyboardCopyModeActive = active
        }
        hostedView.syncKeyStateIndicator(text: surfaceView.currentKeyStateIndicatorText)
    }

    func hasSelection() -> Bool {
        guard let surface = surface else { return false }
        return ghostty_surface_has_selection(surface)
    }

#if DEBUG
    @MainActor
    func setNeedsConfirmCloseOverrideForTesting(_ value: Bool?) {
        needsConfirmCloseOverrideForTesting = value
    }

    /// Test-only helper to deterministically simulate a released runtime surface.
    @MainActor
    func releaseSurfaceForTesting() {
        let callbackContext = surfaceCallbackContext
        surfaceCallbackContext = nil
        let tapContext = outputTapContext
        outputTapContext = nil

        guard let surfaceToFree = surface else {
            callbackContext?.release()
            tapContext?.release()
            return
        }

        TerminalSurfaceRegistry.shared.unregisterRuntimeSurface(surfaceToFree, ownerId: id)
        surface = nil
        // Test-only teardown, not a real close: keep the WAL directory.
        SessionWALStore.shared.unregister(surface: surfaceToFree, surfaceId: id.uuidString)
        ghostty_surface_free(surfaceToFree)
        callbackContext?.release()
        tapContext?.release()
    }

    /// Test-only helper to simulate a stale Swift wrapper whose native surface
    /// was already freed out-of-band.
    @MainActor
    func replaceSurfaceWithFreedPointerForTesting() {
        guard !runtimeSurfaceFreedOutOfBandForTesting else { return }

        let callbackContext = surfaceCallbackContext
        surfaceCallbackContext = nil
        let tapContext = outputTapContext
        outputTapContext = nil

        guard let surfaceToFree = surface else {
            callbackContext?.release()
            tapContext?.release()
            return
        }

        TerminalSurfaceRegistry.shared.unregisterRuntimeSurface(surfaceToFree, ownerId: id)
        // Test-only teardown, not a real close: keep the WAL directory.
        SessionWALStore.shared.unregister(surface: surfaceToFree, surfaceId: id.uuidString)
        ghostty_surface_free(surfaceToFree)
        runtimeSurfaceFreedOutOfBandForTesting = true
        callbackContext?.release()
        tapContext?.release()
    }
#endif

    deinit {
        markPortalLifecycleClosed(reason: "deinit")

        let callbackContext = surfaceCallbackContext
        surfaceCallbackContext = nil
        let tapContext = outputTapContext
        outputTapContext = nil
        // Deinit's Task closure below must not capture self, so snapshot the id
        // string now for the WAL tap teardown call.
        let surfaceIdForTap = id.uuidString

        // Nil out the surface pointer so any in-flight closures (e.g. geometry
        // reconcile dispatched via DispatchQueue.main.async) that read self.surface
        // before this object is fully deallocated will see nil and bail out,
        // rather than passing a freed pointer to ghostty_surface_refresh (#432).
        let surfaceToFree = surface
        if let surfaceToFree {
            TerminalSurfaceRegistry.shared.unregisterRuntimeSurface(surfaceToFree, ownerId: id)
        }
        surface = nil

        guard let surfaceToFree else {
#if DEBUG
            dlog(
                "surface.lifecycle.deinit.skip surface=\(id.uuidString.prefix(5)) " +
                "workspace=\(tabId.uuidString.prefix(5)) reason=noRuntimeSurface"
            )
#endif
            callbackContext?.release()
            tapContext?.release()
            return
        }

#if DEBUG
        if runtimeSurfaceFreedOutOfBandForTesting {
            runtimeSurfaceFreedOutOfBandForTesting = false
            callbackContext?.release()
            tapContext?.release()
            return
        }
#endif

#if DEBUG
        let surfaceToken = String(id.uuidString.prefix(5))
        let workspaceToken = String(tabId.uuidString.prefix(5))
        dlog(
            "surface.lifecycle.deinit.begin surface=\(surfaceToken) " +
            "workspace=\(workspaceToken) hasAttachedView=\(attachedView != nil ? 1 : 0) " +
            "hostedInWindow=\(hostedView.window != nil ? 1 : 0)"
        )
#endif

        // Keep teardown asynchronous to avoid re-entrant close/deinit loops, but retain
        // callback userdata until surface free completes so callbacks never dereference
        // a deallocated view pointer.
        Task { @MainActor in
            // Clear the output tap right before free, per the C API contract.
            // This is the surface's genuine normal-close path (when
            // teardownSurface() didn't already run it), so delete its WAL
            // directory now that it's torn down.
            SessionWALStore.shared.unregister(surface: surfaceToFree, surfaceId: surfaceIdForTap, deleteDirectory: true)
            ghostty_surface_free(surfaceToFree)
            callbackContext?.release()
            tapContext?.release()
#if DEBUG
            dlog(
                "surface.lifecycle.deinit.end surface=\(surfaceToken) " +
                "workspace=\(workspaceToken) freed=1"
            )
#endif
        }
    }
}

extension TerminalSurface {
    @MainActor
    func owningWorkspace() -> Workspace? {
        AppDelegate.shared?.workspaceFor(tabId: tabId)
    }
}
