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
import os

// MARK: - Debug Render Instrumentation (split out, Nuclear Review #97; verbatim move)

/// Lightweight instrumentation to detect whether Ghostty is actually requesting Metal drawables.
/// This helps catch "frozen until refocus" regressions without relying on screenshots (which can
/// mask redraw issues by forcing a window server flush).
/// Issue #182 slice 2 (`Sources/SessionEscrow.swift`): carries an
/// already-running child's pty master fd + pid (retrieved from the escrow
/// holder via `SessionEscrowClient.retrieve`) from
/// `Workspace+Persistence.swift`'s `createPanel(from:inPane:)` down to
/// `TerminalSurface.createSurface(for:)`, where it becomes
/// `ghostty_surface_config_s.revive_pty_fd`/`revive_child_pid` instead of
/// the normal openpty+fork+exec path.
struct TerminalSurfaceReviveDescriptor {
    /// Caller-owned master pty fd. Ownership transfers to the ghostty
    /// surface once `ghostty_surface_new` succeeds; on failure
    /// `createSurface` closes it itself, since ghostty never took
    /// ownership in that case.
    let masterFD: Int32
    let childPID: Int64
    /// Pre-crash screen text (frame + WAL delta,
    /// `SessionWALStore.readFallbackScrollbackText`) to seed into the
    /// fresh surface via `ghostty_surface_process_output` right after
    /// creation, so the user sees prior output above the now-live session.
    /// Nil if no usable scrollback was available.
    let scrollbackText: String?
    var retainedDescriptor: SessionEscrowRetainedDescriptor? = nil
}

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

struct ProgramaPortRangeAssignment: Equatable, Sendable {
    let start: Int
    let end: Int
    let size: Int
}

enum ProgramaPortRangePolicy {
    static let baseDefaultsKey = "cmuxPortBase"
    static let rangeDefaultsKey = "cmuxPortRange"
    static let defaultBase = 9_100
    static let defaultRange = 10
    static let minimumPort = 1
    static let maximumPort = 65_535

    static func isValid(base: Int, range: Int) -> Bool {
        guard (minimumPort ... maximumPort).contains(base),
              (minimumPort ... maximumPort).contains(range) else {
            return false
        }
        let (end, overflow) = base.addingReportingOverflow(range - 1)
        return !overflow && end <= maximumPort
    }

    static func clamped(base: Int, range: Int) -> (base: Int, range: Int) {
        let safeBase = min(max(base, minimumPort), maximumPort)
        let maximumRange = maximumPort - safeBase + 1
        return (safeBase, min(max(range, minimumPort), maximumRange))
    }

    static func assignment(
        base requestedBase: Int,
        range requestedRange: Int,
        ordinal requestedOrdinal: Int
    ) -> ProgramaPortRangeAssignment {
        let base: Int
        let range: Int
        if isValid(base: requestedBase, range: requestedRange) {
            base = requestedBase
            range = requestedRange
        } else {
            base = defaultBase
            range = defaultRange
        }

        let slotCount = max(1, (maximumPort - base + 1) / range)
        let ordinal = max(0, requestedOrdinal) % slotCount
        let (offset, offsetOverflow) = ordinal.multipliedReportingOverflow(by: range)
        let (start, startOverflow) = base.addingReportingOverflow(offset)
        let (end, endOverflow) = start.addingReportingOverflow(range - 1)

        guard !offsetOverflow, !startOverflow, !endOverflow,
              (minimumPort ... maximumPort).contains(start),
              (minimumPort ... maximumPort).contains(end) else {
            return ProgramaPortRangeAssignment(
                start: defaultBase,
                end: defaultBase + defaultRange - 1,
                size: defaultRange
            )
        }
        return ProgramaPortRangeAssignment(start: start, end: end, size: range)
    }

    static func assignment(defaults: UserDefaults, ordinal: Int) -> ProgramaPortRangeAssignment {
        let storedBase = defaults.integer(forKey: baseDefaultsKey)
        let storedRange = defaults.integer(forKey: rangeDefaultsKey)
        return assignment(
            base: storedBase > 0 ? storedBase : defaultBase,
            range: storedRange > 0 ? storedRange : defaultRange,
            ordinal: ordinal
        )
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

    /// Single-owner transport used only after registry removal and `surface` nil-ing.
    /// The replay queue orders this free after earlier replay work; only the main-actor
    /// task unwraps the pointer and frees it once.
    private struct DeferredSurfaceFree: @unchecked Sendable {
        let pointer: ghostty_surface_t
    }

    private(set) var surface: ghostty_surface_t?
    private weak var attachedView: GhosttyNSView?

    private var rendererRealized = true
    private(set) var rendererLastVisibleAt: TimeInterval = Date().timeIntervalSince1970
    private var rendererPortalVisible = false

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
    private let surfaceContext: ghostty_surface_context_e
    private let configTemplate: ProgramaSurfaceConfigTemplate?
    private let workingDirectory: String?
    private let initialCommand: String?
    private let initialEnvironmentOverrides: [String: String]
    private let initializedForSessionRestore: Bool
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
    /// Per-surface userdata for the PTY tee that feeds the session
    /// WAL. See SessionOutputTapSpike.swift (SessionWALStore) for the
    /// threading/lock tradeoff and full lifecycle contract. Registered right
    /// after `ghostty_surface_new` succeeds; cleared + released at every
    /// teardown site paired with `surfaceCallbackContext` below.
    private var outputTapContext: Unmanaged<SessionWALStore.Context>?
    /// Issue #182 slice 1 (`Sources/SessionEscrow.swift`): guards
    /// `attemptSessionEscrow` so the PTY master fd is dup'd and handed to
    /// the escrow holder at most once per surface, never on a timer. Set
    /// synchronously (main actor) the moment the attempt starts, before the
    /// async send even begins.
    private var hasAttemptedSessionEscrow = false

    /// Issue #182 slice 2: set from `init`, consumed (cleared) the moment
    /// `createSurface` copies it into `surfaceConfig` -- see
    /// `TerminalSurfaceReviveDescriptor`'s doc comment.
    private var reviveDescriptor: TerminalSurfaceReviveDescriptor?
    /// restore-replay-residuals (fresh-spawn scrollback collapse): prepared
    /// fallback-restore scrollback text for a FRESH (non-revived) spawn --
    /// e.g. session restore when no escrowed child could be reattached.
    /// Routed through the exact same deferred `pendingReviveSeed` /
    /// settle-gate machinery as the revive path below (see `createSurface`),
    /// rather than the old temp-file + shell-rc `cat` mechanism
    /// (`SessionScrollbackReplayStore`, removed). Set from `init`; consumed
    /// (cleared) the moment `createSurface` arms `pendingReviveSeed` from
    /// it, same one-shot discipline as `reviveDescriptor` above. Nil (not
    /// just empty) means "nothing to seed" -- the overwhelming majority of
    /// surface creations never touch the deferred-seed machinery at all.
    private var pendingFreshSeedText: String?
    /// restore-replay-residuals: pre-crash scrollback text (and whether the
    /// revived shell owns the terminal, so mouse-mode reset should run) that
    /// `createSurface` has captured but not yet replayed, because it must
    /// wait for the surface to reach a settled size. Set at most once per
    /// surface (in `createSurface`); consumed exactly once by
    /// `seedRevivedScrollbackIfPending()`, whichever trigger (the first
    /// post-creation `updateSize` call, or a bounded fallback timer) runs
    /// first. `text` may be empty -- a revive with no scrollback to seed
    /// still needs this set so the post-seed SIGWINCH nudge below still
    /// fires and the PTY tee still gets registered.
    private var pendingReviveSeed: (text: String, resetModes: Bool, workingDirectory: String?)?
    /// restore-replay-residuals (divider-race fix, garbled residual spinner
    /// output on multi-pane restore): `true` while this surface's
    /// `pendingReviveSeed` must not be consumed yet, because
    /// `TerminalSurface.isSessionRestoreSettling` was active when this surface
    /// was created -- the split tree's persisted divider fractions
    /// (`Workspace+Persistence.applySessionDividerPositions`) may not have
    /// finished propagating through SwiftUI/AppKit relayout, so any
    /// `updateSize` landing this early can still be at the wrong
    /// (pre-restore-divider) width. While gated, `seedRevivedScrollbackIfPending`
    /// no-ops for every trigger, and the fallback timer re-arms itself instead
    /// of firing early (see `scheduleReviveSeedFallbackTimer`). Cleared by
    /// `TerminalSurface.clearSessionRestoreGateAndFlushPendingSurfaces(generation:)`,
    /// which also immediately re-attempts the seed.
    private var isGatedForSessionRestoreSettle = false
    /// The restore generation this surface is gated under; nil once ungated.
    /// See `TerminalSurface.currentSessionRestoreGeneration`.
    private var gatedRestoreGeneration: Int?
    /// restore-replay-residuals: the revived pty's foreground process group
    /// and child pid, snapshotted in `createSurface` before ghostty takes
    /// ownership of the fd. Consumed exactly once by
    /// `seedRevivedScrollbackIfPending()` to deliver a one-shot SIGWINCH
    /// nudge after replay settles. `SIGWINCH`'s default disposition is
    /// ignore, so a stale or reused target is a silent no-op.
    private var pendingReviveWinchPGID: pid_t?
    private var pendingReviveWinchChildPID: Int64?

    /// Serial queue the revive-replay chunk loop runs on, off the main
    /// thread. See the 0.4.231 app-mailbox deadlock documented on
    /// `seedRevivedScrollbackIfPending` for why this cannot run on main.
    /// Also serializes this surface's deferred `ghostty_surface_free` (in
    /// `performSurfaceTeardown`) after any in-flight replay for this surface,
    /// via FIFO ordering on this same queue -- see that method's comment.
    private let reviveReplayQueue = DispatchQueue(
        label: "com.darkroom.programa.revive-replay",
        qos: .userInitiated
    )
    /// Set before the surface's C pointer is freed (`performSurfaceTeardown`)
    /// so an in-flight revive-replay chunk loop stops promptly instead of
    /// continuing to feed a surface that is about to disappear.
    private let reviveReplayCanceled = OSAllocatedUnfairLock(initialState: false)

    /// Pid registered with `TerminalController.registerRevivedRoot` for this
    /// surface, if it was revived from escrow. Held so teardown can withdraw
    /// the authorization again — see #286.
    private var authorizedRevivedRootPID: pid_t?
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
        additionalEnvironment: [String: String] = [:],
        reviveDescriptor: TerminalSurfaceReviveDescriptor? = nil,
        pendingScrollbackSeedText: String? = nil
    ) {
        self.id = UUID()
        self.tabId = tabId
        self.surfaceContext = context
        self.configTemplate = configTemplate
        self.workingDirectory = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCommand = initialCommand?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.initialCommand = (trimmedCommand?.isEmpty == false) ? trimmedCommand : nil
        self.initialEnvironmentOverrides = Self.mergedNormalizedEnvironment(base: [:], overrides: initialEnvironmentOverrides)
        self.initializedForSessionRestore = reviveDescriptor != nil || pendingScrollbackSeedText != nil
        self.additionalEnvironment = Self.mergedNormalizedEnvironment(base: [:], overrides: additionalEnvironment)
        self.reviveDescriptor = reviveDescriptor
        self.pendingFreshSeedText = pendingScrollbackSeedText
        // Match Ghostty's own SurfaceView: ensure a non-zero initial frame so the backing layer
        // has non-zero bounds and the renderer can initialize without presenting a blank/stretched
        // intermediate frame on the first real resize.
        let view = GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        self.surfaceView = view
        self.hostedView = GhosttySurfaceScrollView(surfaceView: view)
        // Surface is created when attached to a view
        hostedView.attachSurface(self)
        TerminalSurfaceRegistry.shared.register(self)

        // Deferred-realization revival fix (2026-08-20): a revived panel restored
        // into a hidden tab may never create its runtime surface this launch, so
        // the normal re-escrow trigger (resolveSessionWALIdentity, run from
        // createSurface) may never fire. Until it does, the retrieved master fd
        // exists ONLY in this process — the next quit or crash closes it and
        // SIGHUPs the child, which is the "every tab except the active one gets
        // reset on update" report. Hand the fd to the escrow holder immediately
        // instead of waiting for the tab to be shown.
        if let descriptor = reviveDescriptor, !SessionMachineryGate.isUnitTesting {
            escrowRevivedDescriptorImmediately(descriptor)
        }
    }


    func updateWorkspaceId(_ newTabId: UUID) {
        tabId = newTabId
        attachedView?.tabId = newTabId
        surfaceView.tabId = newTabId
        // Keep the registry's snapshot in sync so callbacks resolving this pointer see the
        // new tabId -- the registry (not this object) is what callbacks actually read.
        if let pointer = surfaceCallbackContext?.toOpaque() {
            GhosttySurfaceUserdataRegistry.updateTabId(pointer: pointer, tabId: newTabId)
        }
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

    // MARK: - Session-restore divider-settle gate (restore-replay-residuals)
    //
    // Fixes the multi-pane restore race where a revived surface's one-shot
    // `pendingReviveSeed` was consumed at the FIRST post-creation `updateSize`
    // call -- which, for any pane in a non-50/50 split, lands at bonsplit's
    // default divider fraction, not the persisted one
    // (`Workspace+Persistence.restoreSessionSnapshot` applies persisted divider
    // positions only after every pane's panels already exist). Replaying
    // \r-overwritten spinner output at a narrower-than-capture width makes every
    // wrapped frame visible instead of overwritten -- the exact garbled/repeated
    // "thinking" spinner symptom. A generation counter (not a plain bool) so two
    // restores overlapping in time (e.g. multiple windows relaunching at once)
    // can't have one restore's gate-clear prematurely release a still-in-flight
    // sibling restore's surfaces.

    /// Bumped once per `restoreSessionSnapshot` pass; the resulting value gates
    /// every surface that pass revives via `attemptSessionReattach`.
    static var currentSessionRestoreGeneration = 0
    /// Number of restore passes that have not yet finished applying divider
    /// positions + settled one extra main-queue turn. A counter, not a bool:
    /// app relaunch restores many workspaces back-to-back, and each pass must
    /// keep the gate open until its own clear runs -- a later pass starting
    /// must not let an earlier pass's clear release surfaces early, nor may an
    /// earlier pass's clear close the gate on a later in-flight pass.
    private static var settlingRestorePassCount = 0
    /// `true` while any restore pass is still settling.
    static var isSessionRestoreSettling: Bool { settlingRestorePassCount > 0 }
    /// Called by `Workspace+Persistence.restoreSessionSnapshot` at the top of
    /// each pass, before any panel/surface is created.
    static func beginSessionRestorePass() -> Int {
        currentSessionRestoreGeneration += 1
        settlingRestorePassCount += 1
        return currentSessionRestoreGeneration
    }
    /// Surfaces gated under the *current* generation, so
    /// `clearSessionRestoreGateAndFlushPendingSurfaces(generation:)` can nudge
    /// exactly the surfaces belonging to the restore pass it is closing out.
    /// Weak: a surface torn down mid-restore must not be kept alive here.
    private static var surfacesAwaitingRestoreSettle = NSHashTable<TerminalSurface>.weakObjects()

    /// Called by `Workspace+Persistence.restoreSessionSnapshot` after
    /// `applySessionDividerPositions` has run and one additional main-queue
    /// turn has elapsed. Releases exactly the surfaces gated under
    /// `generation` -- each restore pass clears its own generation, so
    /// back-to-back workspace restores (app relaunch) can't strand an earlier
    /// pass's surfaces on the fallback-timer ceiling.
    static func clearSessionRestoreGateAndFlushPendingSurfaces(generation: Int) {
        settlingRestorePassCount = max(0, settlingRestorePassCount - 1)
        let pending = surfacesAwaitingRestoreSettle.allObjects.filter { $0.gatedRestoreGeneration == generation }
        for surface in pending {
            surfacesAwaitingRestoreSettle.remove(surface)
        }
        for surface in pending {
            surface.isGatedForSessionRestoreSettle = false
            surface.gatedRestoreGeneration = nil
            surface.seedRevivedScrollbackIfPending(trigger: "restore-settle-gate-cleared")
        }
    }

    /// Bounded fallback re-arm ceiling for `scheduleReviveSeedFallbackTimer`:
    /// 40 attempts * 0.15s = 6s. A gate still open after 6s means
    /// `restoreSessionSnapshot` never reached its clear call for this
    /// generation (a bug elsewhere) -- force the seed through rather than hold
    /// it forever.
    private static let reviveSeedFallbackMaxAttempts = 40

    /// restore-replay-residuals: bounded fallback that guarantees
    /// `pendingReviveSeed` eventually gets consumed even if no `updateSize`
    /// call ever lands (a surface created already at its final size). While
    /// `isGatedForSessionRestoreSettle` is still active, firing here would
    /// just reintroduce the divider-race this gate exists to close, so the
    /// timer re-arms itself instead of consuming, up to
    /// `reviveSeedFallbackMaxAttempts`.
    private func scheduleReviveSeedFallbackTimer(attempt: Int = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            if self.isGatedForSessionRestoreSettle, attempt < Self.reviveSeedFallbackMaxAttempts {
                self.scheduleReviveSeedFallbackTimer(attempt: attempt + 1)
                return
            }
            if self.isGatedForSessionRestoreSettle {
                // Ceiling reached -- force through rather than hold the seed
                // forever; see `reviveSeedFallbackMaxAttempts`'s doc comment.
                self.isGatedForSessionRestoreSettle = false
                self.gatedRestoreGeneration = nil
            }
            self.seedRevivedScrollbackIfPending(trigger: "fallback-timer")
        }
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

    @MainActor
    var isPristineForCustomLayout: Bool {
        guard portalLifecycleState == .live,
              surface == nil,
              initialCommand == nil,
              initialEnvironmentOverrides.isEmpty,
              additionalEnvironment.isEmpty,
              configTemplate?.command?.isEmpty ?? true,
              configTemplate?.initialInput?.isEmpty ?? true,
              configTemplate?.environmentVariables.isEmpty ?? true,
              !backgroundSurfaceStartQueued,
              !initializedForSessionRestore,
              pendingSocketInputQueue.isEmpty,
              reviveDescriptor == nil,
              pendingFreshSeedText == nil,
              pendingReviveSeed == nil,
              !hasAttemptedSessionEscrow else { return false }
        return withDebugMetadataLock {
            runtimeSurfaceCreatedAt == nil && teardownRequestedAt == nil
        }
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
            GhosttySurfaceUserdataRegistry.release(callbackContext)
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

    /// Single teardown path (audit finding N12) for the runtime surface plus its
    /// callback/tap handoff state, shared by the two *real* close paths —
    /// `teardownSurface()` and `deinit` — which is where the forensic evidence
    /// (#250-era teardown-race audit) points: both can independently decide to
    /// tear the same surface down, and before this unification each had its own
    /// copy of the snapshot-and-free logic. Snapshots and nils every piece of
    /// state a second call could act on (surface, surfaceCallbackContext,
    /// outputTapContext, reviveDescriptor), so calling this from either site can
    /// never double-free or double-release: a second call sees `surface == nil`
    /// and no-ops at the `guard`.
    ///
    /// Deliberately NOT folded in here (real semantic differences that resist
    /// unification):
    /// - `liveSurfaceForGhosttyAccess(reason:)` — the pointer there may already
    ///   be reowned/recycled by another surface, so it must NOT call
    ///   `ghostty_surface_free` or touch the C surface at all; it only forgets
    ///   Swift-side bookkeeping.
    /// - `releaseSurfaceForTesting()` — deliberately does NOT call
    ///   `markPortalLifecycleClosed`, so `portalLifecycleState` stays `.live`
    ///   and a subsequent `requestBackgroundSurfaceStartIfNeeded()` /
    ///   `createSurface()` can still recreate the runtime surface. This is
    ///   load-bearing for the "detach race" regression tests in
    ///   `TerminalAndGhosttyTests.swift`, which release the surface and then
    ///   assert it gets recreated on next keystroke.
    /// - `replaceSurfaceWithFreedPointerForTesting()` — deliberately leaves
    ///   `self.surface` non-nil after freeing, to simulate a stale Swift
    ///   wrapper whose native surface was already freed out-of-band. Folding
    ///   it into the nil-as-idempotency-guard shape here would erase the exact
    ///   dangling-pointer scenario that fixture exists to test.
    ///
    /// Keeps the deferred `Task { @MainActor in }` free timing (#432) exactly
    /// as both prior call sites had it — this PR does not make the free
    /// synchronous.
    ///
    /// Deliberately not `@MainActor`: `deinit` is always nonisolated in Swift's
    /// concurrency model and cannot call a main-actor-isolated method
    /// synchronously, so this stays a plain nonisolated method callable from
    /// both `deinit` and the `@MainActor`-isolated `teardownSurface()`.
    private func performSurfaceTeardown(reason: String) {
        // Stop any in-flight revive-replay chunk loop for this surface
        // promptly, before the free below can enqueue behind it. Harmless
        // (and cheap) to set even when no replay is running.
        reviveReplayCanceled.withLock { $0 = true }

        if let leftoverReviveDescriptor = reviveDescriptor {
            leftoverReviveDescriptor.retainedDescriptor?.markRecoveryPending()
            close(leftoverReviveDescriptor.masterFD)
            reviveDescriptor = nil
        }
        // #286: withdraw this session's ancestry authorization before the pid
        // can be recycled by an unrelated process.
        if let authorizedRoot = authorizedRevivedRootPID {
            TerminalController.unregisterRevivedRoot(authorizedRoot)
            authorizedRevivedRootPID = nil
        }
        releaseEscrowedSessionIfClosedForGood(reason: reason)
        markPortalLifecycleClosed(reason: reason)

        let callbackContext = surfaceCallbackContext
        surfaceCallbackContext = nil
        let tapContext = outputTapContext
        outputTapContext = nil
        // Snapshot before any possible async hop so a deferred Task below
        // never needs to capture `self` for logging/unregistration.
        let surfaceIdForTap = id.uuidString

        let surfaceToFree = surface
        if let surfaceToFree {
            TerminalSurfaceRegistry.shared.unregisterRuntimeSurface(surfaceToFree, ownerId: id)
        }
        surface = nil

        guard let surfaceToFree else {
#if DEBUG
            dlog(
                "surface.lifecycle.\(reason).skip surface=\(surfaceIdForTap.prefix(5)) " +
                "workspace=\(tabId.uuidString.prefix(5))"
            )
#endif
            GhosttySurfaceUserdataRegistry.release(callbackContext)
            tapContext?.release()
            return
        }

#if DEBUG
        if runtimeSurfaceFreedOutOfBandForTesting {
            runtimeSurfaceFreedOutOfBandForTesting = false
            GhosttySurfaceUserdataRegistry.release(callbackContext)
            tapContext?.release()
            return
        }
#endif

        let deferredSurfaceFree = DeferredSurfaceFree(pointer: surfaceToFree)

#if DEBUG
        dlog(
            "surface.lifecycle.\(reason).begin surface=\(surfaceIdForTap.prefix(5)) " +
            "workspace=\(tabId.uuidString.prefix(5))"
        )
#endif

        // Route the free through `reviveReplayQueue` so it can never run
        // while a background revive-replay chunk loop for this surface still
        // holds `surfaceToFree`. That queue is serial (FIFO), so this block
        // only starts once any replay enqueued before this teardown call has
        // finished (or observed `reviveReplayCanceled` and broken out).
        // Deliberately does not capture `self` -- everything the Task body
        // needs is snapshotted above, same discipline as before.
        reviveReplayQueue.async {
            Task { @MainActor in
                let surfaceToFree = deferredSurfaceFree.pointer
                // Keep free behavior aligned across teardown sites: perform the runtime
                // teardown on the next main-actor turn so SIGHUP delivery is
                // deterministic but non-reentrant. Clear the PTY tee right before
                // free, per the C API contract. Both call sites are the surface's
                // genuine normal-close path, so delete its WAL directory now that
                // it's torn down.
                SessionWALStore.shared.unregister(surface: surfaceToFree, surfaceId: surfaceIdForTap, deleteDirectory: true)
                GhosttyApp.cancelConfirmationsBeforeFree(surfaceToFree)
                ghostty_surface_free(surfaceToFree)
                GhosttySurfaceUserdataRegistry.release(callbackContext)
                tapContext?.release()
#if DEBUG
                dlog(
                    "surface.lifecycle.\(reason).end surface=\(surfaceIdForTap.prefix(5)) freed=1"
                )
#endif
            }
        }
    }

    /// Explicitly free the Ghostty runtime surface. Idempotent — safe to call
    /// before deinit; deinit will skip the free if already torn down.
    @MainActor
    func teardownSurface() {
        recordTeardownRequest(reason: "surface.teardown")
        performSurfaceTeardown(reason: "teardown")
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
        // Issue #182 slice 2: consume the revive descriptor exactly once --
        // cleared immediately so a later `createSurface` retry (e.g. a
        // deferred background-start attempt) never tries to revive a
        // second time with an fd ghostty may already have taken ownership
        // of. Defaults (-1/-1 from `ghostty_surface_config_new()`) mean
        // "spawn normally" when there's nothing to revive.
        let consumedReviveDescriptor = reviveDescriptor
        reviveDescriptor = nil
        if let consumedReviveDescriptor {
            surfaceConfig.revive_pty_fd = consumedReviveDescriptor.masterFD
            surfaceConfig.revive_child_pid = consumedReviveDescriptor.childPID
        }
        // restore-replay-residuals (fresh-spawn scrollback collapse): same
        // exactly-once consumption discipline as the revive descriptor
        // above. Only meaningful when there's no revive descriptor -- a
        // surface can't simultaneously be an escrow revival (live child
        // already running) and a fresh spawn seeded from historical text.
        let consumedFreshSeedText = consumedReviveDescriptor == nil ? pendingFreshSeedText : nil
        pendingFreshSeedText = nil
        surfaceConfig.font_size = baseConfig.fontSize
        surfaceConfig.wait_after_command = baseConfig.waitAfterCommand
        surfaceConfig.platform_tag = GHOSTTY_PLATFORM_MACOS
        surfaceConfig.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
            nsview: Unmanaged.passUnretained(view).toOpaque()
        ))
        let callbackContext = Unmanaged.passRetained(GhosttySurfaceCallbackContext(surfaceId: id))
        GhosttySurfaceUserdataRegistry.register(callbackContext.toOpaque(), surfaceId: id, tabId: tabId)
        surfaceConfig.userdata = callbackContext.toOpaque()
        GhosttySurfaceUserdataRegistry.release(surfaceCallbackContext)
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
        // One Launch Services call per spawn, resolved and mapped through
        // BrowserAvailability so the env var and the `app.browsers` socket
        // command agree on short keys. Clear + protect both keys first so a
        // stale value inherited from the base/initial environment can't
        // survive a failed resolution -- these two are only populated on
        // success, so the "absent on failure" contract needs an explicit
        // clear, unlike the always-set managed keys above.
        env.removeValue(forKey: "PROGRAMA_DEFAULT_BROWSER")
        env.removeValue(forKey: "PROGRAMA_DEFAULT_BROWSER_BUNDLE_ID")
        protectedStartupEnvironmentKeys.insert("PROGRAMA_DEFAULT_BROWSER")
        protectedStartupEnvironmentKeys.insert("PROGRAMA_DEFAULT_BROWSER_BUNDLE_ID")
        if let defaultBrowser = BrowserAvailability.resolveDefaultBrowser() {
            setManagedEnvironmentValue("PROGRAMA_DEFAULT_BROWSER", defaultBrowser.shortKey)
            setManagedEnvironmentValue("PROGRAMA_DEFAULT_BROWSER_BUNDLE_ID", defaultBrowser.bundleIdentifier)
        }

        // Resolve settings for each new terminal so Settings changes take effect without a restart.
        // The policy validates the full range and wraps the monotonic ordinal within the available
        // port space, so malformed defaults and long-running sessions can never trap or emit an
        // invalid TCP port.
        do {
            let assignment = ProgramaPortRangePolicy.assignment(
                defaults: .standard,
                ordinal: portOrdinal
            )
            setManagedEnvironmentValue("PROGRAMA_PORT", String(assignment.start))
            setManagedEnvironmentValue("PROGRAMA_PORT_END", String(assignment.end))
            setManagedEnvironmentValue("PROGRAMA_PORT_RANGE", String(assignment.size))
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

        // Snapshot who owns the revived pty *before* ghostty takes the fd.
        // When the shell itself is the foreground process group there is no
        // live program left to re-arm mouse reporting after the scrollback
        // replay below, so the modes that replay restores have to be disarmed.
        // When a TUI is in the foreground it survived the relaunch inside the
        // escrowed pty and still expects those modes -- leave them alone.
        let revivedShellOwnsTerminal: Bool = {
            guard let consumedReviveDescriptor else { return false }
            let foregroundGroup = tcgetpgrp(consumedReviveDescriptor.masterFD)
            // No answer (closed fd, no foreground group): prefer a usable
            // prompt over a TUI's mouse, since the prompt is the common case.
            guard foregroundGroup >= 0 else { return true }
            return Int64(foregroundGroup) == consumedReviveDescriptor.childPID
        }()

        // restore-replay-residuals: snapshot the same foreground-group read's
        // raw value (still before ghostty takes ownership of the fd below),
        // plus the descriptor's childPID, for the one-shot post-replay
        // SIGWINCH nudge in `seedRevivedScrollbackIfPending()`. A live TUI
        // that survived the relaunch (and thus handles SIGWINCH) repaints
        // over any replay artifacts on its own -- this is what today's
        // manual window-resize workaround relies on happening incidentally.
        if let consumedReviveDescriptor {
            let foregroundGroup = tcgetpgrp(consumedReviveDescriptor.masterFD)
            pendingReviveWinchPGID = foregroundGroup > 0 ? foregroundGroup : nil
            pendingReviveWinchChildPID = consumedReviveDescriptor.childPID

            // #286: this child was forked by the previous app process and is
            // now reparented to launchd, so nothing running inside it can ever
            // walk its ancestry back to us. Authorize it explicitly, or every
            // `programa` command typed in this pane is refused for the life of
            // the session. Cleared in `teardownSurface()` and on the creation
            // failure path below.
            if consumedReviveDescriptor.childPID > 0 {
                let root = pid_t(consumedReviveDescriptor.childPID)
                authorizedRevivedRootPID = root
                TerminalController.registerRevivedRoot(root)
            }
        }

        createWithCommandAndWorkingDirectory()

        if surface == nil {
            // ghostty never took ownership of a revival fd when creation
            // itself failed -- close it here so it isn't leaked. This is
            // the one path in `createSurface` allowed to close it: every
            // other path either transfers ownership into ghostty (success)
            // or hasn't consumed the descriptor at all yet (early returns
            // above, which leave `reviveDescriptor` set for a later retry).
            if let consumedReviveDescriptor {
                consumedReviveDescriptor.retainedDescriptor?.markRecoveryPending()
                close(consumedReviveDescriptor.masterFD)
            }
            // A retry of `createSurface` reuses this same TerminalSurface
            // instance with `reviveDescriptor` already nil, so nothing would
            // otherwise clear these on a failed-then-retried creation --
            // leaving a stale seed/winch target for a surface the retry
            // creates without ever revisiting this revive branch.
            pendingReviveSeed = nil
            pendingReviveWinchPGID = nil
            pendingReviveWinchChildPID = nil
            if let root = authorizedRevivedRootPID {
                TerminalController.unregisterRevivedRoot(root)
                authorizedRevivedRootPID = nil
            }
            GhosttySurfaceUserdataRegistry.release(surfaceCallbackContext)
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
        consumedReviveDescriptor?.retainedDescriptor?.releaseAfterOwnershipTransfer()
        TerminalSurfaceRegistry.shared.registerRuntimeSurface(createdSurface, ownerId: id)
        rendererRealized = true
        recordRuntimeSurfaceCreation()

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

        // Size the grid BEFORE any scrollback replay below. `ghostty_surface_new`
        // births every surface at a hardcoded 800x600 placeholder
        // (`ghostty/src/apprt/embedded.zig`), so replaying a transcript first
        // parses it against a grid that is not this pane's width. Soft-wrapped
        // lines survive that -- a later resize reflows them -- but the absolute
        // cursor addressing in any captured TUI redraw writes glyphs to cells
        // chosen for the placeholder width, and no later resize can move them
        // back. That is layout damage baked in at replay time, which is why it
        // outlives every attempt to fix it by resizing the window.
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

        // restore-replay-residuals: pre-crash scrollback replay via
        // `ghostty_surface_process_output` -- bypasses the pty entirely
        // (writing to the pty *master* would appear as new keyboard INPUT to
        // the revived child, not output) -- is deferred to
        // `seedRevivedScrollbackIfPending()` rather than run here. Doing it
        // here would replay the transcript's absolute-cursor-positioned
        // redraws against whatever transitional size the surface happens to
        // have at `ghostty_surface_new` time; on the primary-window restore
        // path that size is not proven final yet (`restoreSessionSnapshot`
        // runs before `setFrame(restoredFrame)`), so replay damage gets
        // baked in at the wrong width and survives every later resize. The
        // actual `pendingReviveSeed` storage is armed last, near the end of
        // this function -- see that site for why and for the accepted
        // live-output interleaving tradeoff.
        // restore-replay-residuals (fresh-spawn scrollback collapse): a
        // fresh spawn with prepared seed text defers tap registration the
        // same way a revive does, below -- its seeded historical text must
        // not be captured into the new session's own `wal.log` either.
        let willDeferSeedAndTap = consumedReviveDescriptor != nil
            || (consumedFreshSeedText?.isEmpty == false)
        if !willDeferSeedAndTap {
            // Register the PTY tee now that the runtime surface
            // definitely exists, wiring it into the session WAL writer. See
            // SessionOutputTapSpike.swift (SessionWALStore). The revive case
            // and the fresh-spawn-with-seed-text case both register this
            // later, inside `seedRevivedScrollbackIfPending()`.
            outputTapContext?.release()
            outputTapContext = SessionWALStore.shared.register(
                surface: createdSurface,
                surfaceId: id.uuidString,
                workingDirectory: resolvedWorkingDirectory
            )
        }
        if SessionMachineryGate.isUnitTesting {
            return
        }
        // childPID/ptyPath may not be available yet (the child may not have
        // spawned). Bounded retry, re-reading `self.surface` fresh each
        // attempt rather than caching `createdSurface` across the delay --
        // see resolveSessionWALIdentity's doc comment. Also the trigger for
        // re-escrow (`attemptSessionEscrow`, inside the retry loop) after a
        // successful revival: it runs unconditionally for every surface, so
        // a revived surface's live fd gets handed back to the holder again
        // exactly like a freshly spawned one, with no special-casing needed
        // here.
        resolveSessionWALIdentity(surfaceId: id.uuidString, attempt: 0)

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

        // restore-replay-residuals: arm the deferred revive seed LAST, after
        // every other piece of post-creation setup above (WAL identity
        // resolution, font/focus reconciliation, pending socket input
        // flush, initial redraw kick). This closes a structural reentrancy
        // window: if any layout path calls `updateSize` reentrantly *during*
        // `createSurface` (unproven but untraced), it must find
        // `pendingReviveSeed` still nil and no-op -- only the first
        // `updateSize` call landing strictly after `createSurface` returns
        // (or the fallback timer below) is allowed to trigger the seed.
        //
        // Accepted tradeoff, stated honestly: the pty is live from the
        // moment `ghostty_surface_new` succeeds, so live output can render
        // before this deferred historical seed runs -- the old inline seed
        // had the same window, just at microsecond scale instead of up to
        // ~150ms (a minimum, not a cap: `asyncAfter` can slip further under
        // main-queue pressure). Any live output *painted* during that window
        // is overwritten on screen when the seed finally runs (seeding
        // always writes over whatever is currently displayed) -- that part
        // is cosmetic. But the PTY tee is also deferred until the same
        // point (see the tee-registration comment above), so any pty bytes
        // that arrive during this window are never appended to this
        // session's own `wal.log` at all -- a real, if small, WAL recording
        // gap, not just a cosmetic one. It is bounded and self-healing: the
        // next periodic frame capture (`SessionWALPolicy.frameCaptureInterval`
        // in SessionWALStore.swift, ~25s) re-snapshots the full on-screen
        // state regardless of what the WAL missed, so the durable loss from
        // this window is at most the delta between two frame captures, not
        // an unbounded gap. Combined with the SIGWINCH nudge fired
        // immediately after seeding (in `seedRevivedScrollbackIfPending`),
        // which makes any live TUI that survived the relaunch repaint over
        // whatever artifacts remain, this is judged an acceptable tradeoff.
        // A true ordering barrier -- buffering all live pty output until the
        // seed commits -- would need cooperation from ghostty itself and is
        // disproportionate to a bounded, self-healing window.
        if let consumedReviveDescriptor {
            pendingReviveSeed = (
                text: consumedReviveDescriptor.scrollbackText ?? "",
                resetModes: revivedShellOwnsTerminal,
                workingDirectory: resolvedWorkingDirectory
            )
            // Divider-race fix: if this surface is being created as part of an
            // in-flight `restoreSessionSnapshot` pass, gate seed consumption
            // until that pass explicitly clears it (after divider positions
            // are applied + one settled main-queue turn) -- see
            // `isGatedForSessionRestoreSettle`'s doc comment.
            if TerminalSurface.isSessionRestoreSettling {
                isGatedForSessionRestoreSettle = true
                gatedRestoreGeneration = TerminalSurface.currentSessionRestoreGeneration
                TerminalSurface.surfacesAwaitingRestoreSettle.add(self)
            }
            // Bounded fallback: covers a surface created already at its
            // final size, where no further `updateSize` call ever lands to
            // trigger the primary path in `seedRevivedScrollbackIfPending()`.
            // Also the safety net if the gate above is somehow never cleared
            // -- see `scheduleReviveSeedFallbackTimer`'s bounded re-arm.
            scheduleReviveSeedFallbackTimer()
        } else if let consumedFreshSeedText, !consumedFreshSeedText.isEmpty {
            // restore-replay-residuals (fresh-spawn scrollback collapse):
            // same deferred settle-gated seed path as a revived surface
            // above, minus the revive-specific bits -- there is no live
            // child to nudge with SIGWINCH (the fresh shell hasn't even
            // spawned yet at this point; see the ordering note above), and
            // `resetModes: false` because `consumedFreshSeedText` already
            // has `TerminalReplayModeReset.disableSequence` baked in by
            // `SessionFreshSpawnScrollbackSeed.preparedText` -- applying it
            // a second time here would be redundant. A fresh shell always
            // "owns" the terminal it is about to start in (there is never a
            // surviving TUI to leave modes armed for), which is exactly the
            // condition under which the revive path above also resets
            // modes -- so the reset itself is correct here, just already
            // applied once, upstream.
            pendingReviveSeed = (
                text: consumedFreshSeedText,
                resetModes: false,
                workingDirectory: resolvedWorkingDirectory
            )
            if TerminalSurface.isSessionRestoreSettling {
                isGatedForSessionRestoreSettle = true
                gatedRestoreGeneration = TerminalSurface.currentSessionRestoreGeneration
                TerminalSurface.surfacesAwaitingRestoreSettle.add(self)
            }
            scheduleReviveSeedFallbackTimer()
        }

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

    private static let sessionWALIdentityMaxRetries = 6
    private static let sessionWALIdentityRetryInterval: TimeInterval = 0.5

    /// Session WAL identity resolution: retries `SessionWALStore
    /// .resolveSurfaceIdentity` a bounded number of times, spaced out, so a
    /// child process that has not spawned yet at surface-creation time still
    /// gets its `childPID`/`ptyPath` recorded once it does. Re-reads
    /// `self.surface` fresh on every attempt (never captures the surface
    /// pointer passed into `createSurface` across the delay) so a surface
    /// torn down mid-retry is simply skipped rather than dereferenced --
    /// `surface` is set to nil synchronously at the top of
    /// `teardownSurface()`, before any async free runs. Not on the keystroke
    /// path: called once at surface creation, then at most
    /// `sessionWALIdentityMaxRetries` more times, spaced
    /// `sessionWALIdentityRetryInterval` apart.
    private func resolveSessionWALIdentity(surfaceId: String, attempt: Int) {
        guard let surface else { return }
        let identity = SessionWALStore.resolveSurfaceIdentity(surface: surface)
        if identity.childPID != nil || identity.ptyPath != nil {
            SessionWALStore.shared.updateSurfaceIdentity(
                surfaceId: surfaceId,
                childPID: identity.childPID,
                ptyPath: identity.ptyPath
            )
        }
        if !hasAttemptedSessionEscrow, let childPID = identity.childPID {
            attemptSessionEscrow(surface: surface, surfaceId: surfaceId, childPID: childPID)
        }
        let stillMissing = identity.childPID == nil || identity.ptyPath == nil
        guard stillMissing, attempt < Self.sessionWALIdentityMaxRetries else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.sessionWALIdentityRetryInterval) { [weak self] in
            self?.resolveSessionWALIdentity(surfaceId: surfaceId, attempt: attempt + 1)
        }
    }

    /// Issue #182 slice 1 escrow trigger (`Sources/SessionEscrow.swift`).
    /// Reads the raw pty master fd and `dup()`s it -- both on the main
    /// actor, matching the cost class of the sibling `child_pid`/
    /// `pty_path` accessors called just above -- then hands the dup off to
    /// `SessionEscrowClient` on its own background queue for the actual
    /// (potentially blocking) socket send. Guarded by
    /// `hasAttemptedSessionEscrow`, set before the dup even happens, so a
    /// surface only ever attempts this once regardless of how many
    /// `resolveSessionWALIdentity` retries follow. Never touches the
    /// ghostty-owned fd itself: `ghostty_surface_pty_master_fd` does not
    /// dup or transfer ownership, so `dup()` here is required before the
    /// fd can safely outlive this surface.
    /// Tells the escrow holder to drop this session, but only when the
    /// surface is going away because the user closed it for good.
    ///
    /// The holder keeps a dup of the pty master, so freeing the app-side
    /// surface is not enough to hang up the terminal: without this the shell
    /// and whatever agent is running in it stay alive, invisible to the app,
    /// until the holder exits. A session closed while the app keeps running
    /// is not even covered by `unclaimedSessionTTL`, which only starts once a
    /// session is draining.
    ///
    /// Two conditions, both required:
    ///
    /// - `reason == "teardown"`, i.e. `teardownSurface()`. That is the path
    ///   `ClosedTerminalUndoStore`'s `finalize` runs, so the close-undo grace
    ///   period has already elapsed and nothing can restore this surface.
    ///   `deinit` is deliberately excluded: a surface can be deallocated for
    ///   reasons that are not a user-visible close.
    /// - the app is not terminating. Sessions open at quit MUST stay
    ///   escrowed -- reattaching them on the next launch is the entire point
    ///   of escrow, and releasing here would silently kill every running
    ///   agent on every app update.
    nonisolated static func shouldReleaseEscrowOnTeardown(
        reason: String,
        isApplicationTerminating: Bool
    ) -> Bool {
        reason == "teardown" && !isApplicationTerminating
    }

    private func releaseEscrowedSessionIfClosedForGood(reason: String) {
        guard Self.shouldReleaseEscrowOnTeardown(
            reason: reason,
            isApplicationTerminating: SessionMachineryGate.isApplicationTerminating
        ) else { return }
        SessionEscrowClient.shared.release(surfaceId: id.uuidString)
    }

    /// Escrows a revive descriptor's master fd at panel construction, before any
    /// runtime surface exists. Sets `hasAttemptedSessionEscrow` first so the
    /// identity retry loop (`resolveSessionWALIdentity`, run at realization)
    /// keeps its one-shot discipline and never double-escrows the same surface.
    /// The escrow facts land via `SessionWALStore.stampDeferredReviveEscrow`,
    /// which is safe to call before the WAL writer's full registration.
    private func escrowRevivedDescriptorImmediately(_ descriptor: TerminalSurfaceReviveDescriptor) {
        guard !hasAttemptedSessionEscrow else { return }
        hasAttemptedSessionEscrow = true
        guard let childPID = Int32(exactly: descriptor.childPID) else { return }
        let dupedFD = dup(descriptor.masterFD)
        guard dupedFD >= 0 else { return }
        let surfaceId = id.uuidString
        let walWorkingDirectory = workingDirectory
        SessionEscrowClient.shared.escrow(
            surfaceId: surfaceId,
            dupedMasterFD: dupedFD,
            childPID: childPID,
            retainedDescriptor: descriptor.retainedDescriptor
        ) { result in
            guard let result else {
                dilog("escrow.reattach", "early_reescrow session=\(surfaceId.prefix(8)) outcome=failed")
                return
            }
            descriptor.retainedDescriptor?.releaseAfterOwnershipTransfer()
            dilog("escrow.reattach", "early_reescrow session=\(surfaceId.prefix(8)) outcome=ok")
            SessionWALStore.shared.stampDeferredReviveEscrow(
                surfaceId: surfaceId,
                socketPath: result.socketPath,
                token: result.tokenHex,
                childPID: childPID,
                workingDirectory: walWorkingDirectory
            )
        }
    }

    private func attemptSessionEscrow(surface: ghostty_surface_t, surfaceId: String, childPID: Int32) {
        guard !SessionMachineryGate.isUnitTesting else { return }
        hasAttemptedSessionEscrow = true
        let rawMasterFD = ghostty_surface_pty_master_fd(surface)
        guard rawMasterFD >= 0 else { return }
        let dupedFD = dup(rawMasterFD)
        guard dupedFD >= 0 else { return }
        SessionEscrowClient.shared.escrow(
            surfaceId: surfaceId,
            dupedMasterFD: dupedFD,
            childPID: childPID
        ) { result in
            guard let result else { return }
            SessionWALStore.shared.markEscrowed(
                surfaceId: surfaceId,
                socketPath: result.socketPath,
                token: result.tokenHex
            )
            DispatchQueue.main.async {
                // Escrowed must imply snapshotted: the periodic autosave leaves an
                // 8-60s gap where this session is held by the escrow holder but
                // missing from the persisted snapshot, so a crash in that gap
                // strands the live process invisibly until the unclaimed TTL.
                AppDelegate.shared?.sessionAutosave.requestPromptSave(source: "escrowRegistered")
            }
        }
    }

    /// restore-replay-residuals: seeds pre-crash scrollback into a revived
    /// surface once it has reached a settled size, then delivers the
    /// one-shot post-revive SIGWINCH nudge. Two triggers race to call this;
    /// whichever runs first wins and the other becomes a no-op because
    /// `pendingReviveSeed` is cleared under the same main-thread discipline
    /// the rest of this file uses for surface state:
    /// - `updateSize`, on the first call after creation, fired only after
    ///   that call has applied its geometry (`"updateSize-applied"`) or
    ///   determined the existing geometry already matches
    ///   (`"updateSize-unchanged"`) -- either way, real, laid-out geometry
    ///   pushed down from AppKit, unlike the transitional/placeholder size
    ///   `createSurface` sees.
    /// - a bounded fallback timer (`"fallback-timer"`, scheduled at the end
    ///   of `createSurface`) for the case where no `updateSize` call ever
    ///   arrives.
    /// - `"restore-settle-gate-cleared"`, from
    ///   `TerminalSurface.clearSessionRestoreGateAndFlushPendingSurfaces(generation:)`,
    ///   for a surface that arrived at every other trigger while still gated.
    ///
    /// Divider-race fix: no-ops entirely while `isGatedForSessionRestoreSettle`
    /// is still active, regardless of which trigger calls in -- an `updateSize`
    /// landing during an in-flight `restoreSessionSnapshot` pass can still be at
    /// bonsplit's pre-restore-divider width, not the persisted one.
    private func seedRevivedScrollbackIfPending(trigger: String) {
        guard !isGatedForSessionRestoreSettle else { return }
        guard let pending = pendingReviveSeed else { return }
        pendingReviveSeed = nil
        guard surface != nil else { return }

        // #285: the replay must not run inside the caller's AppKit layout pass,
        // and must not be handed to ghostty in one piece.
        //
        // `ghostty_surface_process_output` holds ghostty's
        // `renderer_state.mutex` for the entire buffer it is given
        // (ghostty/src/termio/Termio.zig:678), and the VT stream handler
        // pushes to the renderer mailbox with a *blocking* `.forever` policy
        // (ghostty/src/termio/stream_handler.zig:172). A transcript large
        // enough to fill that mailbox therefore parks the main thread while it
        // still holds the very mutex the renderer needs in order to drain it —
        // the app wedges with no way out, which is what shipped in 0.4.225.
        //
        // Hopping to the next main-queue turn gets this off the layout pass;
        // feeding bounded chunks means each `process_output` call returns (and
        // so releases the mutex) long enough for the renderer to drain between
        // them. Chunk boundaries are safe anywhere: the VT parser is a stream
        // parser and already handles escape sequences and UTF-8 code points
        // split across reads, because real PTY reads split them too.
        //
        // 0.4.231: chunking alone is not enough. Every OSC sequence in the
        // replayed transcript that produces an apprt surface message (title
        // set OSC 0/2, pwd report OSC 7 -- shells emit these on every prompt)
        // is pushed by ghostty's stream handler into the app mailbox
        // (`BlockingQueue(Message, 64)`, ghostty/src/App.zig:662), which also
        // blocks with a `.forever` policy once full
        // (ghostty/src/termio/stream_handler.zig:126-137). The ONLY drainer of
        // that mailbox is `ghostty_app_tick`, which Programa runs on the main
        // thread (`GhosttyApp.swift`). Chunking the renderer mailbox does
        // nothing for this one: the renderer mailbox has an independent
        // drainer thread, but the app mailbox's only drainer is the very
        // thread running the replay. A transcript with more than 64
        // surface-message-producing sequences self-deadlocks the main thread
        // on the 65th push no matter how small the chunks are. The chunk loop
        // (and the trailing mode-reset write) therefore runs on
        // `reviveReplayQueue`, a background serial queue, not on main.
        // `ghostty_surface_process_output` is safe to call off-main: it is
        // ghostty's documented "manual API that users can call"
        // (ghostty/src/termio/Termio.zig:764-767) and takes
        // `renderer_state.mutex` itself -- the PTY read thread already calls
        // it from a non-main thread.
        DispatchQueue.main.async { [weak self] in
            self?.replayRevivedScrollback(pending: pending, trigger: trigger)
        }
    }

    /// Largest slice handed to a single `ghostty_surface_process_output` call
    /// during a revive replay. Small enough that one call cannot fill the
    /// renderer mailbox while holding `renderer_state.mutex` — see the comment
    /// in `seedRevivedScrollbackIfPending`.
    private static let reviveReplayChunkBytes = 8 * 1024

#if DEBUG
    /// Test-only observation hook: invoked once per `ghostty_surface_process_output`
    /// chunk during a revive replay, with `Thread.isMainThread` captured at the
    /// moment of that call. Regression tests use this to assert the replay loop
    /// never runs on the main thread (see the 0.4.231 app-mailbox deadlock
    /// documented on `seedRevivedScrollbackIfPending`).
    static var reviveReplayChunkObserverForTesting: ((_ isMainThread: Bool) -> Void)?

    /// Test-only entry point that drives the SAME production replay pipeline
    /// (`replayRevivedScrollback`) with a caller-supplied transcript, calling
    /// `completion` once the replay — including its post-replay finish work —
    /// has completed.
    func replayRevivedScrollbackForTesting(text: String, completion: @escaping () -> Void) {
        let pending: (text: String, resetModes: Bool, workingDirectory: String?) = (
            text: text,
            resetModes: false,
            workingDirectory: nil
        )
        replayRevivedScrollback(pending: pending, trigger: "testing", completion: completion)
    }
#endif

    /// Feeds `pending`'s transcript to ghostty and performs the post-replay
    /// finish work. The chunk loop (and trailing mode-reset write) runs on
    /// `reviveReplayQueue`, off the main thread -- see the 0.4.231 comment on
    /// `seedRevivedScrollbackIfPending` for why. Finish work that touches
    /// `TerminalSurface` state (the debug log, PTY tee registration, SIGWINCH
    /// delivery) hops back to main afterward. `completion` -- used only by
    /// the DEBUG testing entry point above -- fires after that finish work
    /// completes, whether or not the surface was still live to receive it.
    private func replayRevivedScrollback(
        pending: (text: String, resetModes: Bool, workingDirectory: String?),
        trigger: String,
        completion: @escaping () -> Void = {}
    ) {
        // The surface can be torn down between the trigger and this hop (pane
        // closed mid-restore); dropping the replay is the correct outcome.
        guard let capturedSurface = surface else {
            completion()
            return
        }

        let surfaceIdString = id.uuidString
        let workingDirectory = pending.workingDirectory
        let pgid = pendingReviveWinchPGID
        let childPID = pendingReviveWinchChildPID
        pendingReviveWinchPGID = nil
        pendingReviveWinchChildPID = nil

        reviveReplayQueue.async { [reviveReplayCanceled] in
            // The chunk loop runs to completion here rather than yielding the
            // run loop between chunks. Releasing the mutex is what breaks the
            // deadlock; yielding as well would additionally let live output
            // from the revived shell land *between* chunks and interleave
            // itself into the middle of the historical transcript. A tight
            // loop keeps that window down to the gap between two calls.
            let bytes = Array(pending.text.utf8)
            var offset = 0
            while offset < bytes.count {
                if reviveReplayCanceled.withLock({ $0 }) { break }
                let end = min(offset + Self.reviveReplayChunkBytes, bytes.count)
                bytes.withUnsafeBufferPointer { buffer in
                    guard let baseAddress = buffer.baseAddress else { return }
                    UnsafeRawPointer(baseAddress + offset)
                        .withMemoryRebound(to: CChar.self, capacity: end - offset) { chunk in
                            ghostty_surface_process_output(capturedSurface, chunk, UInt(end - offset))
                        }
                }
                offset = end
#if DEBUG
                Self.reviveReplayChunkObserverForTesting?(Thread.isMainThread)
#endif
            }

            // The seeded transcript is historical: any DECSET inside it was
            // balanced by a DECRST that the relaunch-killed program never
            // sent, so replaying it re-arms the mode in this fresh terminal
            // for good. Disarm mouse tracking before live output resumes --
            // otherwise the revived shell's bare prompt fills with mouse
            // motion reports.
            if !bytes.isEmpty, pending.resetModes, !reviveReplayCanceled.withLock({ $0 }) {
                let modeReset = Data(TerminalReplayModeReset.disableSequence.utf8)
                modeReset.withUnsafeBytes { rawBuffer in
                    guard let baseAddress = rawBuffer.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
                    ghostty_surface_process_output(capturedSurface, baseAddress, UInt(rawBuffer.count))
                }
            }

            DispatchQueue.main.async { [weak self] in
                defer { completion() }
                guard let self, self.surface == capturedSurface else { return }

                #if DEBUG
                let currentSize = ghostty_surface_size(capturedSurface)
                dlog(
                    "session.escrow.revive.seed surface=\(surfaceIdString.prefix(8)) bytes=\(bytes.count) " +
                    "px=\(currentSize.width_px)x\(currentSize.height_px) grid=\(currentSize.columns)x\(currentSize.rows) trigger=\(trigger)"
                )
                #endif

                // Register the PTY tee now -- deliberately after seeding, so
                // this replay text is never captured into the new session's own
                // `wal.log`. Mirrors the non-revive registration in `createSurface`.
                self.outputTapContext?.release()
                self.outputTapContext = SessionWALStore.shared.register(
                    surface: capturedSurface,
                    surfaceId: surfaceIdString,
                    workingDirectory: workingDirectory
                )

                // Post-seed SIGWINCH: a live TUI that survived the relaunch (and
                // thus handles SIGWINCH) repaints over any replay artifacts on its
                // own, replacing the manual window-resize users otherwise do today.
                // SIGWINCH's default disposition is ignore, so delivering it to a
                // stale/reused pgid or pid is a silent no-op, not a hazard.
                if let pgid, pgid > 0 {
                    killpg(pgid, SIGWINCH)
                    #if DEBUG
                    dlog("session.escrow.revive.winch surface=\(surfaceIdString.prefix(8)) pgid=\(pgid) child=0")
                    #endif
                } else if let childPID, childPID > 0 {
                    kill(pid_t(childPID), SIGWINCH)
                    #if DEBUG
                    dlog("session.escrow.revive.winch surface=\(surfaceIdString.prefix(8)) pgid=0 child=\(childPID)")
                    #endif
                }
            }
        }
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
        // No valid geometry yet -- do not seed here, there is nothing settled
        // to seed against.
        guard wpx > 0, hpx > 0 else { return false }

        let scaleChanged = !scaleApproximatelyEqual(xScale, lastXScale) || !scaleApproximatelyEqual(yScale, lastYScale)
        let sizeChanged = wpx != lastPixelWidth || hpx != lastPixelHeight

        #if DEBUG
        Self.sizeLog("updateSize-call surface=\(id.uuidString.prefix(8)) size=\(wpx)x\(hpx) prev=\(lastPixelWidth)x\(lastPixelHeight) changed=\((scaleChanged || sizeChanged) ? 1 : 0)")
        #endif

        guard scaleChanged || sizeChanged else {
            // restore-replay-residuals: scale/size already match what this
            // surface was created with -- the "created already at its final
            // size, no further layout change ever arrives" case. Seed here,
            // against the size that is already correct, rather than relying
            // solely on the fallback timer to ever trigger the primary path.
            if pendingReviveSeed != nil {
                seedRevivedScrollbackIfPending(trigger: "updateSize-unchanged")
            }
            return false
        }

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

        // restore-replay-residuals: seed AFTER the geometry above has been
        // applied. Seeding any earlier in this function (e.g. at the top,
        // before `ghostty_surface_set_size` runs) would replay against the
        // size the surface had *before* this very call applies the new
        // geometry -- exactly the transitional-size replay damage this
        // deferred-seed mechanism exists to prevent.
        if pendingReviveSeed != nil {
            seedRevivedScrollbackIfPending(trigger: "updateSize-applied")
        }

        // Let Ghostty continue rendering on its own wakeups for steady-state frames.
        return true
    }

    /// Ask Ghostty to redraw after committed text input, without the geometry
    /// reconciliation `forceRefresh` does.
    ///
    /// PERF (#183): this runs after every printable keystroke. `forceRefresh`
    /// additionally reasserts the display id and calls `forceRefreshSurface()`,
    /// which exist for *topology* changes -- split close/reparent, and the
    /// stuck-vsync state after wake-from-sleep -- none of which a character can
    /// cause. Typing changes the grid contents, not the surface's size or which
    /// display it lives on.
    ///
    /// The early-out conditions are deliberately identical to `forceRefresh`'s,
    /// so *when* a redraw happens is unchanged; only the work done differs.
    func requestRedrawAfterInput() {
        guard let view = attachedView,
              view.window != nil,
              view.bounds.width > 0,
              view.bounds.height > 0 else {
            return
        }
        guard let surface = self.surface else { return }
        ghostty_surface_refresh(surface)
    }

    /// Force a full size recalculation and surface redraw.
    func forceRefresh(reason: String = "unspecified") {
        // PERF (#183): this diagnostic string is consumed only by the DEBUG-only `dlog` below,
        // but it used to be built unconditionally -- interpolating the view's bounds and doing a
        // CAMetalLayer cast on every call, including the one that runs after each text-input
        // keystroke. Keep the whole thing inside DEBUG so release builds allocate nothing here.
        #if DEBUG
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

    func setFocus(_ focused: Bool, force: Bool = false) {
        // Only send focus events when the state changes to avoid redundant
        // prompt redraws with zsh themes like Powerlevel10k.
        guard force || focused != desiredFocusState else { return }
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

    var isRendererRealized: Bool { hasLiveSurface && rendererRealized }
    var isRendererPortalVisible: Bool { rendererPortalVisible }

    func setRendererPortalVisible(_ visible: Bool) {
        let wasVisible = rendererPortalVisible
        rendererPortalVisible = visible
        if visible || wasVisible {
            noteBecameVisibleForRendererReclamation()
        }
    }

    func noteBecameVisibleForRendererReclamation() {
        rendererLastVisibleAt = Date().timeIntervalSince1970
    }

    @MainActor
    func releaseRenderer() {
        guard rendererRealized, !rendererPortalVisible else { return }
        guard let surface = liveSurfaceForGhosttyAccess(reason: "renderer.release") else { return }
        if ghostty_surface_set_renderer_realized(surface, false) {
            rendererRealized = false
        }
    }

    @MainActor
    func realizeRenderer() {
        guard !rendererRealized else { return }
        guard let surface = liveSurfaceForGhosttyAccess(reason: "renderer.realize") else { return }
        if ghostty_surface_set_renderer_realized(surface, true) {
            rendererRealized = true
        } else {
            RendererRealizationController.shared.scheduleImmediatePass()
        }
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

    /// Test-only seam exposing the raw `ghostty_surface_userdata` pointer this surface
    /// currently owns, so a test can capture it before teardown and then attempt to
    /// resolve it afterward (`GhosttyApp.debugCallbackContextResolves(from:)`) to prove a
    /// stale pointer is rejected instead of dereferencing freed memory.
    @MainActor
    func debugCallbackUserdataPointer() -> UnsafeMutableRawPointer? {
        surfaceCallbackContext?.toOpaque()
    }

    /// Test-only helper to deterministically simulate a released runtime surface.
    @MainActor
    func releaseSurfaceForTesting() {
        let callbackContext = surfaceCallbackContext
        surfaceCallbackContext = nil
        let tapContext = outputTapContext
        outputTapContext = nil

        guard let surfaceToFree = surface else {
            GhosttySurfaceUserdataRegistry.release(callbackContext)
            tapContext?.release()
            return
        }

        TerminalSurfaceRegistry.shared.unregisterRuntimeSurface(surfaceToFree, ownerId: id)
        surface = nil
        // Test-only teardown, not a real close: keep the WAL directory.
        SessionWALStore.shared.unregister(surface: surfaceToFree, surfaceId: id.uuidString)
        GhosttyApp.cancelConfirmationsBeforeFree(surfaceToFree)
        ghostty_surface_free(surfaceToFree)
        GhosttySurfaceUserdataRegistry.release(callbackContext)
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
            GhosttySurfaceUserdataRegistry.release(callbackContext)
            tapContext?.release()
            return
        }

        TerminalSurfaceRegistry.shared.unregisterRuntimeSurface(surfaceToFree, ownerId: id)
        // Test-only teardown, not a real close: keep the WAL directory.
        SessionWALStore.shared.unregister(surface: surfaceToFree, surfaceId: id.uuidString)
        GhosttyApp.cancelConfirmationsBeforeFree(surfaceToFree)
        ghostty_surface_free(surfaceToFree)
        runtimeSurfaceFreedOutOfBandForTesting = true
        GhosttySurfaceUserdataRegistry.release(callbackContext)
        tapContext?.release()
    }
#endif

    deinit {
        // Keep teardown asynchronous to avoid re-entrant close/deinit loops, but retain
        // callback userdata until surface free completes so callbacks never dereference
        // a deallocated view pointer. performSurfaceTeardown's revive-descriptor
        // leak-guard covers issue #182 slice 2 (fd leak if `createSurface` never
        // consumed `reviveDescriptor`) and is a no-op whenever `createSurface` did run.
        performSurfaceTeardown(reason: "deinit")
    }
}

extension TerminalSurface {
    @MainActor
    func owningWorkspace() -> Workspace? {
        AppDelegate.shared?.workspaceFor(tabId: tabId)
    }
}
