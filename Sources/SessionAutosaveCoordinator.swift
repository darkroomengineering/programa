import Foundation
import Bonsplit

/// Owns the periodic session-autosave timer, the typing-quiet-period debounce, deferred retry
/// scheduling, and fingerprint-based skip logic for background session snapshot persistence.
///
/// Extracted from `AppDelegate` (GitHub issue #187). `AppDelegate` still owns window state and
/// the actual snapshot build/save implementations; this coordinator receives them as injected
/// closures rather than a back-reference to `AppDelegate`, keeping the orchestration testable in
/// isolation with fakes.
final class SessionAutosaveCoordinator {
    typealias SnapshotProvider = (_ includeScrollback: Bool) -> AppSessionSnapshot?
    /// Completion runs on main and reports the completed disk write, not queue acceptance.
    typealias SnapshotSaver = (
        _ includeScrollback: Bool,
        _ prebuiltSnapshot: AppSessionSnapshot?,
        _ completion: @escaping (Bool) -> Void
    ) -> Void
    typealias TerminatingProvider = () -> Bool
    typealias XCTestRunningProvider = () -> Bool

    private var sessionAutosaveTimer: DispatchSourceTimer?
    private var sessionAutosaveTickInFlight = false
    private var autosaveGeneration = UUID()
    private var promptSaveScheduled = false
    private var promptSaveWaitingForWrite = false
    private var consecutiveDeclinedSaveRetries = 0
    private static let maxConsecutiveDeclinedSaveRetries = 5
    private var sessionAutosaveDeferredRetryPending = false
    private var lastSessionAutosaveFingerprint: Data?
    private var lastSessionAutosavePersistedAt: Date = .distantPast
    private var lastTypingActivityAt: TimeInterval = 0

    private static let sessionAutosaveTypingQuietPeriod: TimeInterval = 0.65

    private var sessionPersistenceQueue: DispatchQueue
    private var snapshotProvider: SnapshotProvider
    private var saveSnapshot: SnapshotSaver
    private var isTerminating: TerminatingProvider
    private var isRunningUnderXCTest: XCTestRunningProvider

    init(
        sessionPersistenceQueue: DispatchQueue,
        snapshotProvider: @escaping SnapshotProvider,
        saveSnapshot: @escaping SnapshotSaver,
        isTerminating: @escaping TerminatingProvider,
        isRunningUnderXCTest: @escaping XCTestRunningProvider
    ) {
        self.sessionPersistenceQueue = sessionPersistenceQueue
        self.snapshotProvider = snapshotProvider
        self.saveSnapshot = saveSnapshot
        self.isTerminating = isTerminating
        self.isRunningUnderXCTest = isRunningUnderXCTest
    }

    /// Rebinds the AppDelegate-dependent queue/closures.
    ///
    /// `AppDelegate` holds this coordinator as a non-optional `let`, constructed eagerly with
    /// placeholder dependencies at property-initializer time. Swift's two-phase initialization
    /// forbids capturing `self` in closures before `AppDelegate.init()` calls `super.init()`, so
    /// `AppDelegate.init()` calls `configure` immediately after `super.init()` returns, passing
    /// the real queue and closures. Nothing observes the placeholder dependencies in between.
    func configure(
        sessionPersistenceQueue: DispatchQueue,
        snapshotProvider: @escaping SnapshotProvider,
        saveSnapshot: @escaping SnapshotSaver,
        isTerminating: @escaping TerminatingProvider,
        isRunningUnderXCTest: @escaping XCTestRunningProvider
    ) {
        self.sessionPersistenceQueue = sessionPersistenceQueue
        self.snapshotProvider = snapshotProvider
        self.saveSnapshot = saveSnapshot
        self.isTerminating = isTerminating
        self.isRunningUnderXCTest = isRunningUnderXCTest
    }

    func startSessionAutosaveTimerIfNeeded() {
        guard sessionAutosaveTimer == nil else { return }
        guard !isRunningUnderXCTest() else { return }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        let interval = SessionPersistencePolicy.autosaveInterval
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            guard let self,
                  Self.shouldRunSessionAutosaveTick(isTerminatingApp: self.isTerminating()) else {
                return
            }
            self.runSessionAutosaveTick(source: "timer")
        }
        sessionAutosaveTimer = timer
        timer.resume()
    }

    func stopSessionAutosaveTimer() {
        sessionAutosaveTimer?.cancel()
        sessionAutosaveTimer = nil
        autosaveGeneration = UUID()
        sessionAutosaveTickInFlight = false
        sessionAutosaveDeferredRetryPending = false
        promptSaveScheduled = false
        promptSaveWaitingForWrite = false
        consecutiveDeclinedSaveRetries = 0
    }

    nonisolated static func shouldRunSessionAutosaveTick(isTerminatingApp: Bool) -> Bool {
        !isTerminatingApp
    }

    private func remainingSessionAutosaveTypingQuietPeriod(
        nowUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> TimeInterval? {
        guard lastTypingActivityAt > 0 else { return nil }
        let elapsed = nowUptime - lastTypingActivityAt
        guard elapsed < Self.sessionAutosaveTypingQuietPeriod else { return nil }
        return Self.sessionAutosaveTypingQuietPeriod - elapsed
    }

    private func scheduleDeferredSessionAutosaveRetry(after delay: TimeInterval) {
        guard delay.isFinite, delay > 0 else { return }
        guard !sessionAutosaveDeferredRetryPending else { return }
        sessionAutosaveDeferredRetryPending = true
        let generation = autosaveGeneration
        sessionPersistenceQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.autosaveGeneration == generation else { return }
                self.sessionAutosaveDeferredRetryPending = false
                self.runSessionAutosaveTick(source: "typingQuietRetry")
            }
        }
    }

    func runSessionAutosaveTick(source: String) {
        guard Self.shouldRunSessionAutosaveTick(isTerminatingApp: isTerminating()) else { return }
        guard !sessionAutosaveTickInFlight else { return }
        if let remainingQuietPeriod = remainingSessionAutosaveTypingQuietPeriod() {
#if DEBUG
            dlog(
                "session.save.skipped reason=typing_recent includeScrollback=0 source=\(source) " +
                "retryMs=\(Int((remainingQuietPeriod * 1000).rounded()))"
            )
#endif
            scheduleDeferredSessionAutosaveRetry(after: remainingQuietPeriod)
            return
        }

        sessionAutosaveTickInFlight = true
#if DEBUG
        let timingStart = ProgramaTypingTiming.start()
        let phaseStart = ProcessInfo.processInfo.systemUptime
        var fingerprintMs: Double = 0
        var saveMs: Double = 0
        defer {
            let totalMs = (ProcessInfo.processInfo.systemUptime - phaseStart) * 1000.0
            ProgramaTypingTiming.logBreakdown(
                path: "session.autosaveTick.phase",
                totalMs: totalMs,
                thresholdMs: 2.0,
                parts: [
                    ("fingerprintMs", fingerprintMs),
                    ("saveMs", saveMs),
                ],
                extra: "source=\(source)"
            )
            ProgramaTypingTiming.logDuration(
                path: "session.autosaveTick",
                startedAt: timingStart,
                extra: "source=\(source)"
            )
        }
#endif

        let now = Date()
#if DEBUG
        let fingerprintStart = ProcessInfo.processInfo.systemUptime
#endif
        let autosaveSnapshot = snapshotProvider(false)
        let autosaveFingerprint = autosaveSnapshot.flatMap {
            SessionPersistenceStore.contentIdentity(for: $0)
        }
#if DEBUG
        fingerprintMs = (ProcessInfo.processInfo.systemUptime - fingerprintStart) * 1000.0
#endif
        if Self.shouldSkipSessionAutosaveForUnchangedFingerprint(
            isTerminatingApp: isTerminating(),
            includeScrollback: false,
            previousFingerprint: lastSessionAutosaveFingerprint,
            currentFingerprint: autosaveFingerprint,
            lastPersistedAt: lastSessionAutosavePersistedAt,
            now: now
        ) {
            sessionAutosaveTickInFlight = false
#if DEBUG
            dlog(
                "session.save.skipped reason=unchanged_autosave_fingerprint includeScrollback=0 source=\(source)"
            )
#endif
            return
        }

#if DEBUG
        let saveStart = ProcessInfo.processInfo.systemUptime
#endif
        let generation = autosaveGeneration
        saveSnapshot(false, autosaveSnapshot) { [weak self] saved in
            guard let self, self.autosaveGeneration == generation else { return }
            self.sessionAutosaveTickInFlight = false
            guard !self.isTerminating() else { return }
            guard saved else {
                // Declined snapshots and failed disk writes must remain eligible even
                // when their content is unchanged. Bound retries for windowless apps
                // and persistent disk errors; the periodic timer keeps trying later.
                if self.consecutiveDeclinedSaveRetries < Self.maxConsecutiveDeclinedSaveRetries {
                    self.consecutiveDeclinedSaveRetries += 1
                    self.scheduleDeferredSessionAutosaveRetry(after: 1.0)
                }
                return
            }
            self.consecutiveDeclinedSaveRetries = 0
            self.updateSessionAutosaveSaveState(
                includeScrollback: false,
                persistedAt: Date(),
                fingerprint: autosaveFingerprint
            )
            if self.promptSaveWaitingForWrite {
                self.promptSaveWaitingForWrite = false
                self.requestPromptSave(source: "writeCompleted", after: 0)
            }
        }
#if DEBUG
        saveMs = (ProcessInfo.processInfo.systemUptime - saveStart) * 1000.0
#endif
    }

    /// Coalesced "save soon" for structural changes — a new panel finishing escrow
    /// registration, most importantly. The periodic timer leaves an 8-60s gap in
    /// which a session can be escrowed at the holder but absent from the persisted
    /// snapshot; a crash in that gap strands the process invisibly ("shadow"
    /// session) until the holder's unclaimed TTL fires, because restore never
    /// learns the panel existed. One pending request at a time: bursts (multi-pane
    /// restore, N tabs opened together) fold into a single snapshot build.
    func requestPromptSave(source: String, after delay: TimeInterval = 1.0) {
        guard !promptSaveScheduled else { return }
        promptSaveScheduled = true
        let generation = autosaveGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.autosaveGeneration == generation else { return }
            self.promptSaveScheduled = false
            if self.sessionAutosaveTickInFlight {
                self.promptSaveWaitingForWrite = true
                return
            }
            self.runSessionAutosaveTick(source: source)
        }
    }

    // Widened from `fileprivate` to `internal`: NSWindow.programa_sendEvent(_:) (in
    // WindowSwizzles.swift) calls AppDelegate.shared?.sessionAutosave.recordTypingActivity()
    // from a different file. Refs #95, #187.
    //
    // HOT PATH: called on every keyDown via NSWindow.programa_sendEvent. Keep this a single
    // property write -- no allocation, logging, formatting, or locks.
    func recordTypingActivity() {
        lastTypingActivityAt = ProcessInfo.processInfo.systemUptime
    }

    nonisolated static func shouldWriteSessionSnapshotSynchronously(
        isTerminatingApp: Bool,
        includeScrollback: Bool
    ) -> Bool {
        isTerminatingApp && includeScrollback
    }

    nonisolated static func shouldSkipSessionAutosaveForUnchangedFingerprint<Fingerprint: Equatable>(
        isTerminatingApp: Bool,
        includeScrollback: Bool,
        previousFingerprint: Fingerprint?,
        currentFingerprint: Fingerprint?,
        lastPersistedAt: Date,
        now: Date,
        maximumAutosaveSkippableInterval: TimeInterval = 60
    ) -> Bool {
        guard !isTerminatingApp,
              !includeScrollback,
              let previousFingerprint,
              let currentFingerprint,
              previousFingerprint == currentFingerprint else {
            return false
        }

        return now.timeIntervalSince(lastPersistedAt) < maximumAutosaveSkippableInterval
    }

    private func updateSessionAutosaveSaveState(
        includeScrollback: Bool,
        persistedAt: Date,
        fingerprint: Data?
    ) {
        guard !isTerminating(), !includeScrollback else { return }
        lastSessionAutosaveFingerprint = fingerprint
        lastSessionAutosavePersistedAt = persistedAt
    }
}
