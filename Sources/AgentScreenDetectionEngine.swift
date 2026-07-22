// Screen-manifest agent detection, v2 tier of #164's agent activity state model. See
// docs/plans/screen-manifest-detection.md for the full design; this file implements its §1.5
// two-phase engine.
//
// Phase A trigger research outcome (plan §4 risk #1, resolved during implementation): shell
// integration's foreground-command telemetry (`surface.report_shell_state` /
// `_cmux_report_shell_activity_state` in the zsh/bash/fish integration scripts) only ever sends
// a bare "prompt"/"running" state -- the actual command string (`$1` in zsh's `preexec`) is read
// locally by the shell script but never put on the wire. So there is no usable foreground-command
// signal to hook Phase A recognition off of today. Per the plan's documented fallback (§4 risk 1),
// this engine instead runs Phase A recognition (`recognize.screen_patterns`) against the sampled
// screen text itself, on its own slow ~3s cadence, for every open terminal surface that is not
// already a candidate and not already hooks-owned. This is still not a continuous per-keystroke
// poll and still fully respects the settings gate (§4 risk 5) -- see `runRecognitionScanOnce()`.
//
// Threading (mirrors `TerminalController.v2StartOutputPollLoopIfNeeded`, per root CLAUDE.md's
// "Socket command threading policy" and the typing-latency-sensitive-paths pitfalls): a single
// `Thread.detachNewThread` background loop drives both phases. Each tick does one
// `DispatchQueue.main.sync { MainActor.assumeIsolated { ... } }` hop only to copy terminal text
// (never to run regex or mutate state) -- see `runRecognitionScanOnce`'s doc comment for why this
// engine can't just call `TerminalController.v2MainSync` the way the output-poll loop does. All
// classification/hysteresis work happens back on the background thread, and only
// `DispatchQueue.main.async` hops to main when a surface's *reported* state actually changes.
import Foundation

/// Singleton screen-manifest detection engine. Samples recognized (candidate) terminal surfaces
/// on a background thread and reports inferred `working`/`blocked`/`idle` states through the same
/// funnel lifecycle hooks use (`TabManager.updateSurfaceAgentState(..., source: .inferred)`),
/// which silently drops the write if a hook already authoritatively owns that surface.
final class AgentScreenDetectionEngine: @unchecked Sendable {
    static let shared = AgentScreenDetectionEngine()

    /// Phase B classification-sampling cadence (§1.5: "500ms-1s").
    private static let sampleInterval: TimeInterval = 0.75
    /// Phase A recognition-scan cadence (§1.5 fallback: "every ~3s"), expressed as a multiple of
    /// `sampleInterval` so the engine only ever runs one background thread/timer.
    private static let recognitionScanEveryNTicks = 4
    /// How many trailing lines of screen+scrollback Phase B reads per candidate sample (§2.2:
    /// "enough for any spinner/prompt UI, far short of full scrollback").
    private static let sampleTailLineLimit = 60
    /// How many trailing lines Phase A's recognition scan reads per not-yet-candidate surface.
    /// Smaller than the Phase B tail since recognition patterns are typically short banner/UI
    /// fragments, not full state-classification anchors.
    private static let recognitionTailLineLimit = 40
    /// Consecutive matching samples required before `working`/`idle`/`done` flips the reported
    /// state (§1.6 hysteresis). `blocked` bypasses this entirely (applied immediately).
    private static let hysteresisRequiredSamples = 2
    /// A candidate stops matching *any* state pattern for this long -> demoted back out of the
    /// sampling set (§1.5 demotion conditions).
    private static let demotionGracePeriod: TimeInterval = 30.0

    private struct CandidateState {
        let workspaceId: UUID
        let manifest: AgentManifest
        var lastSampledText: String?
        /// Cached result of classifying `lastSampledText`, reused (instead of re-running regex)
        /// on a tick whose freshly-read text is byte-identical to the last one (§1.5 step 2).
        /// Crucially, a cache hit still flows through the *same* hysteresis/demotion bookkeeping
        /// below as a fresh classification would -- a persistently-static idle prompt or
        /// approval box must still accumulate consecutive samples and refresh the demotion
        /// timer, not stall forever just because nothing on screen changed between ticks.
        var lastClassification: AgentManifest.ClassificationResult?
        var pendingBucket: String?
        var pendingCount: Int
        var lastAnyMatchAt: Date
        var lastReportedState: AgentActivityState?
    }

    private let lock = NSLock()
    private var candidates: [UUID: CandidateState] = [:]

    private static let startLock = NSLock()
    private nonisolated(unsafe) static var started = false

    private init() {}

    /// Lazily starts (once, process-lifetime) the shared background thread driving both phases.
    /// Safe to call multiple times/from multiple places -- only the first call actually starts
    /// anything. No-op cost when the setting is off: the loop still ticks (cheap sleep + a single
    /// `UserDefaults` read) but never samples or scans (§1.5: "checked once at the top of both
    /// phases... true zero-cost when off").
    func startIfNeeded() {
        Self.startLock.lock()
        defer { Self.startLock.unlock() }
        guard !Self.started else { return }
        Self.started = true
        Thread.detachNewThread { [weak self] in
            var tick: UInt64 = 0
            while true {
                Thread.sleep(forTimeInterval: Self.sampleInterval)
                guard let self else { return }
                guard AgentScreenDetectionSettings.enabled() else {
                    self.clearAllCandidates()
                    continue
                }
                self.sampleCandidatesOnce()
                tick += 1
                if tick % UInt64(Self.recognitionScanEveryNTicks) == 0 {
                    self.runRecognitionScanOnce()
                }
            }
        }
    }

    private func clearAllCandidates() {
        lock.lock()
        candidates.removeAll()
        lock.unlock()
    }

    private func promoteCandidate(surfaceId: UUID, workspaceId: UUID, manifest: AgentManifest) {
        lock.lock()
        if candidates[surfaceId] == nil {
            candidates[surfaceId] = CandidateState(
                workspaceId: workspaceId,
                manifest: manifest,
                lastSampledText: nil,
                lastClassification: nil,
                pendingBucket: nil,
                pendingCount: 0,
                lastAnyMatchAt: Date(),
                lastReportedState: nil
            )
        }
        lock.unlock()
    }

    private func removeCandidate(surfaceId: UUID) {
        lock.lock()
        candidates.removeValue(forKey: surfaceId)
        lock.unlock()
    }

    // MARK: - Phase A: recognition (fallback: slow-cadence screen-pattern scan)

    /// Scans every open terminal surface that is neither already a candidate nor already
    /// hooks-owned, checking each loaded manifest's `recognize.screen_patterns`. A single match
    /// promotes that surface into the Phase B candidate set with the matching manifest. One
    /// `v2MainSync` hop total per scan (batched across every surface), never per-surface, keeping
    /// this a coalesced "read a small tail" operation rather than a per-surface poll storm.
    private func runRecognitionScanOnce() {
        let manifests = AgentManifestLoader.shared.allManifests()
        guard !manifests.isEmpty else { return }

        lock.lock()
        let alreadyCandidates = Set(candidates.keys)
        lock.unlock()

        // `AgentScreenDetectionEngine` is a plain nonisolated class (this method runs on the
        // engine's own background thread), so it can't call an @MainActor-isolated method like
        // `TerminalController.v2MainSync` directly -- unlike `v2StartOutputPollLoopIfNeeded`,
        // whose enclosing methods are themselves @MainActor (inherited from the TerminalController
        // class annotation) and get away with a synchronous call because `Thread.detachNewThread`'s
        // closure parameter isn't `@Sendable`, so the compiler treats that closure as still
        // running on the main actor even though `Thread` actually runs it on a background thread.
        // Here there's no such inherited isolation to lean on, so hop over explicitly with a raw
        // `DispatchQueue.main.sync` (a real, actor-agnostic thread hop) and assert the isolation
        // once inside via `MainActor.assumeIsolated` -- the same idiom already used in this
        // codebase for genuinely-off-main-thread-but-runtime-on-main-thread callbacks (see
        // `TerminalWindowPortal.swift`'s NotificationCenter `queue: .main` observers).
        var samples: [(surfaceId: UUID, workspaceId: UUID, text: String)] = []
        DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                guard let contexts = AppDelegate.shared?.mainWindowContexts.values else { return }
                for context in contexts {
                    for workspace in context.tabManager.tabs {
                        for (panelId, panel) in workspace.panels {
                            guard let terminalPanel = panel as? TerminalPanel else { continue }
                            guard !alreadyCandidates.contains(panelId) else { continue }
                            guard workspace.panelAgentStateSources[panelId] != .hooks else { continue }
                            guard let text = TerminalController.shared.v2SurfaceWaitReadText(
                                terminalPanel: terminalPanel,
                                lineLimit: Self.recognitionTailLineLimit
                            ) else { continue }
                            samples.append((panelId, workspace.id, text))
                        }
                    }
                }
            }
        }

        for sample in samples {
            for manifest in manifests {
                let matched = manifest.recognize.screenPatterns.contains { pattern in
                    guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
                    let range = NSRange(sample.text.startIndex..<sample.text.endIndex, in: sample.text)
                    return regex.firstMatch(in: sample.text, options: [], range: range) != nil
                }
                guard matched else { continue }
                promoteCandidate(surfaceId: sample.surfaceId, workspaceId: sample.workspaceId, manifest: manifest)
                break
            }
        }
    }

    // MARK: - Phase B: classification sampling

    /// One sampling tick over the current candidate set. For each candidate: a single main-hop
    /// (see `runRecognitionScanOnce`'s doc comment for why this is a raw `DispatchQueue.main.sync`
    /// + `MainActor.assumeIsolated` rather than `TerminalController.v2MainSync`) copies its
    /// current text (and checks it hasn't gone hooks-owned or closed), then all further work --
    /// the identical-text skip, regex classification, hysteresis, and demotion bookkeeping --
    /// happens back on this background thread.
    private func sampleCandidatesOnce() {
        let snapshot: [UUID: AgentManifest]
        lock.lock()
        snapshot = candidates.mapValues { $0.manifest }
        lock.unlock()
        guard !snapshot.isEmpty else { return }

        for (surfaceId, manifest) in snapshot {
            var workspaceId: UUID?
            var sampledText: String?
            var hooksOwned = false
            var surfaceGone = false

            DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    guard let located = AppDelegate.shared?.locateSurface(surfaceId: surfaceId),
                          let ws = located.tabManager.tabs.first(where: { $0.id == located.workspaceId }),
                          let terminalPanel = ws.panels[surfaceId] as? TerminalPanel else {
                        surfaceGone = true
                        return
                    }
                    guard ws.panelAgentStateSources[surfaceId] != .hooks else {
                        hooksOwned = true
                        return
                    }
                    workspaceId = ws.id
                    sampledText = TerminalController.shared.v2SurfaceWaitReadText(
                        terminalPanel: terminalPanel,
                        lineLimit: Self.sampleTailLineLimit
                    )
                }
            }

            if surfaceGone || hooksOwned {
                removeCandidate(surfaceId: surfaceId)
                continue
            }
            guard let workspaceId, let sampledText else { continue }

            processSample(surfaceId: surfaceId, workspaceId: workspaceId, manifest: manifest, text: sampledText)
        }
    }

    /// Classifies one freshly-read sample against `manifest` and resolves hysteresis. Runs
    /// entirely off-main. Only dispatches to main (to actually mutate `Workspace.panelAgentStates`)
    /// when the resolved state differs from what was last reported for this surface.
    ///
    /// Hysteresis counts *sampling ticks*, not distinct text observations: a tick whose text is
    /// byte-identical to the previous one reuses the cached classification (skipping regex work,
    /// §1.5 step 2) but still runs through the exact same bookkeeping below. Without this, a
    /// surface sitting at a static idle prompt or approval box (nothing redraws between ticks)
    /// would classify once, then stall at `pendingCount == 1` forever, since every subsequent
    /// tick would bail out on the identical-text check before ever incrementing it.
    private func processSample(surfaceId: UUID, workspaceId: UUID, manifest: AgentManifest, text: String) {
        lock.lock()
        guard let candidateForClassification = candidates[surfaceId] else { lock.unlock(); return }
        let textUnchanged = candidateForClassification.lastSampledText == text
        let cachedClassification = candidateForClassification.lastClassification
        lock.unlock()

        let classification = textUnchanged ? cachedClassification : manifest.classify(text: text)

        lock.lock()
        guard var current = candidates[surfaceId] else { lock.unlock(); return }
        current.lastSampledText = text
        current.lastClassification = classification

        var resolvedState: AgentActivityState?
        if let classification {
            current.lastAnyMatchAt = Date()
            if classification.bucket == "blocked" {
                // Hysteresis §1.6: blocked applies immediately, no dwell.
                current.pendingBucket = nil
                current.pendingCount = 0
                resolvedState = .blocked
            } else if let mapped = AgentActivityState(manifestBucket: classification.bucket) {
                if current.pendingBucket == classification.bucket {
                    current.pendingCount += 1
                } else {
                    current.pendingBucket = classification.bucket
                    current.pendingCount = 1
                }
                if current.pendingCount >= Self.hysteresisRequiredSamples {
                    resolvedState = mapped
                }
            }
        }
        let shouldDemote = classification == nil
            && Date().timeIntervalSince(current.lastAnyMatchAt) > Self.demotionGracePeriod
        let previousReportedState = current.lastReportedState
        if let resolvedState {
            current.lastReportedState = resolvedState
        }
        candidates[surfaceId] = current
        lock.unlock()

        if shouldDemote {
            removeCandidate(surfaceId: surfaceId)
            return
        }

        guard let resolvedState, resolvedState != previousReportedState else { return }

        DispatchQueue.main.async {
            guard let tabManager = AppDelegate.shared?.tabManagerFor(tabId: workspaceId) else { return }
            _ = tabManager.updateSurfaceAgentState(
                tabId: workspaceId,
                surfaceId: surfaceId,
                state: resolvedState,
                source: .inferred
            )
        }
    }
}
