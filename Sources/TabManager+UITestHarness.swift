import AppKit
import SwiftUI
import Foundation
import Bonsplit
import CoreVideo
import Combine

// MARK: - DEBUG UI Test Harness
//
// Test-only setup helpers, gated behind PROGRAMA_UI_TEST_* environment variables, that
// drive deterministic UI-test scenarios (focus shortcuts, split-close-right visual capture,
// child-process-exit split/keyboard scenarios) from within programaUITests. Never compiled
// into Release builds.

#if DEBUG
// Sample the actual IOSurface-backed terminal layer at vsync cadence so UI tests can reliably
// catch a single compositor-frame blank flash and any transient compositor scaling (stretched text).
//
// This is DEBUG-only and used only for UI tests; no polling or display-link loops exist in normal app runtime.
fileprivate final class VsyncIOSurfaceTimelineState {
    struct Target {
        let label: String
        let sample: @MainActor () -> GhosttySurfaceScrollView.DebugFrameSample?
    }

    let frameCount: Int
    let closeFrame: Int
    let lock = NSLock()

    var framesWritten = 0
    var inFlight = false
    var finished = false

    var scheduledActions: [(frame: Int, action: () -> Void)] = []
    var nextActionIndex: Int = 0

    var targets: [Target] = []

    // Results
    var firstBlank: (label: String, frame: Int)?
    var firstSizeMismatch: (label: String, frame: Int, ios: String, expected: String)?
    var trace: [String] = []

    var link: CVDisplayLink?
    var continuation: CheckedContinuation<Void, Never>?

    init(frameCount: Int, closeFrame: Int) {
        self.frameCount = frameCount
        self.closeFrame = closeFrame
    }

    func tryBeginCapture() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if finished { return false }
        if inFlight { return false }
        inFlight = true
        return true
    }

    func endCapture() {
        lock.lock()
        inFlight = false
        lock.unlock()
    }

    func finish() {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume()
    }
}

fileprivate func programaVsyncIOSurfaceTimelineCallback(
    _ displayLink: CVDisplayLink,
    _ inNow: UnsafePointer<CVTimeStamp>,
    _ inOutputTime: UnsafePointer<CVTimeStamp>,
    _ flagsIn: CVOptionFlags,
    _ flagsOut: UnsafeMutablePointer<CVOptionFlags>,
    _ ctx: UnsafeMutableRawPointer?
) -> CVReturn {
    guard let ctx else { return kCVReturnSuccess }
    let st = Unmanaged<VsyncIOSurfaceTimelineState>.fromOpaque(ctx).takeUnretainedValue()
    if !st.tryBeginCapture() { return kCVReturnSuccess }

    // Sample on the main thread synchronously so we don't "miss" a single compositor frame.
    // (The previous Task/@MainActor hop could be delayed long enough to skip the blank frame.)
    DispatchQueue.main.sync {
        defer { st.endCapture() }
        guard st.framesWritten < st.frameCount else { return }

        while st.nextActionIndex < st.scheduledActions.count {
            let next = st.scheduledActions[st.nextActionIndex]
            if next.frame != st.framesWritten { break }
            st.nextActionIndex += 1
            next.action()
        }

        for t in st.targets {
            guard let s = t.sample() else { continue }

            let iosW = s.iosurfaceWidthPx
            let iosH = s.iosurfaceHeightPx
            let expW = s.expectedWidthPx
            let expH = s.expectedHeightPx
            let gravity = s.layerContentsGravity
            let hasDimensions = iosW > 0 && iosH > 0 && expW > 0 && expH > 0
            let dw = hasDimensions ? abs(iosW - expW) : 0
            let dh = hasDimensions ? abs(iosH - expH) : 0
            let hasSizeMismatch = hasDimensions && (dw > 2 || dh > 2)
            let stretchRisk = (gravity == CALayerContentsGravity.resize.rawValue)

            // Ignore setup/warmup frames before the close action. We only care about
            // regressions that happen at/after the close mutation.
            if st.firstBlank == nil, st.framesWritten >= st.closeFrame, s.isProbablyBlank {
                st.firstBlank = (label: t.label, frame: st.framesWritten)
            }

            if st.firstSizeMismatch == nil,
               st.framesWritten >= st.closeFrame,
               stretchRisk,
               hasSizeMismatch {
                st.firstSizeMismatch = (
                    label: t.label,
                    frame: st.framesWritten,
                    ios: "\(iosW)x\(iosH)",
                    expected: "\(expW)x\(expH)"
                )
            }

            if st.trace.count < 200 {
                st.trace.append("\(st.framesWritten):\(t.label):blank=\(s.isProbablyBlank ? 1 : 0):ios=\(iosW)x\(iosH):exp=\(expW)x\(expH):gravity=\(gravity):key=\(s.layerContentsKey)")
            }
        }

        st.framesWritten += 1
    }

    // Stop/resume outside the main-thread sync block to avoid reentrancy issues.
    if st.framesWritten >= st.frameCount, let link = st.link {
        CVDisplayLinkStop(link)
        st.finish()
        Unmanaged<VsyncIOSurfaceTimelineState>.fromOpaque(ctx).release()
    }

    return kCVReturnSuccess
}
#endif

extension TabManager {
#if DEBUG
    @MainActor
    private func waitForWorkspacePanelsCondition(
        tab: Workspace,
        timeoutSeconds: TimeInterval,
        condition: @escaping (Workspace) -> Bool
    ) async -> Bool {
        guard !condition(tab) else { return true }

        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            var resolved = false
            var cancellable: AnyCancellable?

            func finish(_ value: Bool) {
                guard !resolved else { return }
                resolved = true
                cancellable?.cancel()
                cont.resume(returning: value)
            }

            func evaluate() {
                if condition(tab) {
                    finish(true)
                }
            }

            cancellable = tab.$panels
                .map { _ in () }
                .sink { _ in evaluate() }

            DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSeconds) {
                Task { @MainActor in
                    finish(condition(tab))
                }
            }
            evaluate()
        }
    }

    @MainActor
    private func waitForTerminalPanelCondition(
        tab: Workspace,
        panelId: UUID,
        timeoutSeconds: TimeInterval,
        condition: @escaping (TerminalPanel) -> Bool
    ) async -> Bool {
        if let panel = tab.terminalPanel(for: panelId), condition(panel) {
            return true
        }

        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            var resolved = false
            var panelsCancellable: AnyCancellable?
            var readyObserver: NSObjectProtocol?
            var hostedViewObserver: NSObjectProtocol?

            @MainActor
            func finish(_ value: Bool) {
                guard !resolved else { return }
                resolved = true
                panelsCancellable?.cancel()
                if let readyObserver {
                    NotificationCenter.default.removeObserver(readyObserver)
                }
                if let hostedViewObserver {
                    NotificationCenter.default.removeObserver(hostedViewObserver)
                }
                cont.resume(returning: value)
            }

            @MainActor
            func evaluate() {
                guard let panel = tab.terminalPanel(for: panelId) else {
                    finish(false)
                    return
                }
                panel.surface.requestBackgroundSurfaceStartIfNeeded()
                if condition(panel) {
                    finish(true)
                }
            }

            panelsCancellable = tab.$panels
                .map { _ in () }
                .sink { _ in
                    Task { @MainActor in
                        evaluate()
                    }
                }
            readyObserver = NotificationCenter.default.addObserver(
                forName: .terminalSurfaceDidBecomeReady,
                object: nil,
                queue: .main
            ) { note in
                guard let readySurfaceId = note.userInfo?["surfaceId"] as? UUID,
                      readySurfaceId == panelId else { return }
                Task { @MainActor in
                    evaluate()
                }
            }
            hostedViewObserver = NotificationCenter.default.addObserver(
                forName: .terminalSurfaceHostedViewDidMoveToWindow,
                object: nil,
                queue: .main
            ) { note in
                guard let hostedSurfaceId = note.userInfo?["surfaceId"] as? UUID,
                      hostedSurfaceId == panelId else { return }
                Task { @MainActor in
                    evaluate()
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSeconds) {
                Task { @MainActor in
                    if let panel = tab.terminalPanel(for: panelId) {
                        finish(condition(panel))
                    } else {
                        finish(false)
                    }
                }
            }
            evaluate()
        }
    }

    @MainActor
    private func waitForTerminalPanelReadyForUITest(
        tab: Workspace,
        panelId: UUID,
        timeoutSeconds: TimeInterval = 6.0
    ) async -> (attached: Bool, hasSurface: Bool, firstResponder: Bool) {
        var attached = false
        var hasSurface = false
        var firstResponder = false

        let _ = await waitForTerminalPanelCondition(
            tab: tab,
            panelId: panelId,
            timeoutSeconds: timeoutSeconds
        ) { panel in
            panel.surface.requestBackgroundSurfaceStartIfNeeded()
            attached = panel.hostedView.window != nil
            hasSurface = panel.surface.surface != nil
            firstResponder = panel.hostedView.isSurfaceViewFirstResponder()
            return attached && hasSurface
        }

        return (attached, hasSurface, firstResponder)
    }

    // Widened from `private` to `internal`: called from TabManager.init() in TabManager.swift.
    func setupUITestFocusShortcutsIfNeeded() {
        guard !didSetupUITestFocusShortcuts else { return }
        didSetupUITestFocusShortcuts = true

        let env = ProcessInfo.processInfo.environment
        guard env["PROGRAMA_UI_TEST_FOCUS_SHORTCUTS"] == "1" else { return }

        // UI tests can't record arrow keys via the shortcut recorder. Use letter-based shortcuts
        // so tests can reliably drive pane navigation without mouse clicks.
        KeyboardShortcutSettings.setShortcut(
            StoredShortcut(key: "h", command: true, shift: false, option: false, control: true),
            for: .focusLeft
        )
        KeyboardShortcutSettings.setShortcut(
            StoredShortcut(key: "l", command: true, shift: false, option: false, control: true),
            for: .focusRight
        )
        KeyboardShortcutSettings.setShortcut(
            StoredShortcut(key: "k", command: true, shift: false, option: false, control: true),
            for: .focusUp
        )
        KeyboardShortcutSettings.setShortcut(
            StoredShortcut(key: "j", command: true, shift: false, option: false, control: true),
            for: .focusDown
        )
    }

    // Widened from `private` to `internal`: called from TabManager.init() in TabManager.swift.
    func setupSplitCloseRightUITestIfNeeded() {
        guard !didSetupSplitCloseRightUITest else { return }
        didSetupSplitCloseRightUITest = true

        let env = ProcessInfo.processInfo.environment
        guard env["PROGRAMA_UI_TEST_SPLIT_CLOSE_RIGHT_SETUP"] == "1" else { return }
        guard let path = env["PROGRAMA_UI_TEST_SPLIT_CLOSE_RIGHT_PATH"], !path.isEmpty else { return }
        let visualMode = env["PROGRAMA_UI_TEST_SPLIT_CLOSE_RIGHT_VISUAL"] == "1"
        let shotsDir = (env["PROGRAMA_UI_TEST_SPLIT_CLOSE_RIGHT_SHOTS_DIR"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let visualIterations = Int((env["PROGRAMA_UI_TEST_SPLIT_CLOSE_RIGHT_ITERATIONS"] ?? "20").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 20
        let burstFrames = Int((env["PROGRAMA_UI_TEST_SPLIT_CLOSE_RIGHT_BURST_FRAMES"] ?? "6").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 6
        let closeDelayMs = Int((env["PROGRAMA_UI_TEST_SPLIT_CLOSE_RIGHT_CLOSE_DELAY_MS"] ?? "70").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 70
        let pattern = (env["PROGRAMA_UI_TEST_SPLIT_CLOSE_RIGHT_PATTERN"] ?? "close_right")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let tab = self.selectedWorkspace else {
                    self.writeSplitCloseRightTestData(["setupError": "Missing selected workspace"], at: path)
                    return
                }

                guard let topLeftPanelId = tab.focusedPanelId else {
                    self.writeSplitCloseRightTestData(["setupError": "Missing initial focused panel"], at: path)
                    return
                }
                let initialTerminalReadiness = await self.waitForTerminalPanelReadyForUITest(
                    tab: tab,
                    panelId: topLeftPanelId
                )

                guard initialTerminalReadiness.attached,
                      initialTerminalReadiness.hasSurface,
                      let terminal = tab.terminalPanel(for: topLeftPanelId) else {
                    self.writeSplitCloseRightTestData([
                        "preTerminalAttached": initialTerminalReadiness.attached ? "1" : "0",
                        "preTerminalSurfaceNil": initialTerminalReadiness.hasSurface ? "0" : "1",
                        "setupError": "Initial terminal not ready (not attached or surface nil)"
                    ], at: path)
                    return
                }

                self.writeSplitCloseRightTestData([
                    "preTerminalAttached": "1",
                    "preTerminalSurfaceNil": terminal.surface.surface == nil ? "1" : "0"
                ], at: path)

                if visualMode {
                    // Visual repro mode: repeat the split/close sequence many times and write
                    // screenshots to `shotsDir`. This avoids relying on XCUITest to click hover-only
                    // close buttons, while still exercising the "close unfocused right tabs" path.
                    self.writeSplitCloseRightTestData([
                        "visualMode": "1",
                        "visualIterations": String(visualIterations),
                        "visualDone": "0"
                    ], at: path)

                    await self.runSplitCloseRightVisualRepro(
                        tab: tab,
                        topLeftPanelId: topLeftPanelId,
                        path: path,
                        shotsDir: shotsDir,
                        iterations: max(1, min(visualIterations, 60)),
                        burstFrames: max(0, min(burstFrames, 80)),
                        closeDelayMs: max(0, min(closeDelayMs, 500)),
                        pattern: pattern
                    )

                    self.writeSplitCloseRightTestData(["visualDone": "1"], at: path)
                    return
                }

                // Layout goal: 2x2 grid (2 top, 2 bottom), then close both right panels.
                // Order matters: split down first, then split right in each row (matches UI shortcut repro).
                guard let bottomLeft = tab.newTerminalSplit(from: topLeftPanelId, orientation: .vertical) else {
                    self.writeSplitCloseRightTestData(["setupError": "Failed to create bottom-left split"], at: path)
                    return
                }
                guard let bottomRight = tab.newTerminalSplit(from: bottomLeft.id, orientation: .horizontal) else {
                    self.writeSplitCloseRightTestData(["setupError": "Failed to create bottom-right split"], at: path)
                    return
                }
                tab.focusPanel(topLeftPanelId)
                guard let topRight = tab.newTerminalSplit(from: topLeftPanelId, orientation: .horizontal) else {
                    self.writeSplitCloseRightTestData(["setupError": "Failed to create top-right split"], at: path)
                    return
                }

                self.writeSplitCloseRightTestData([
                    "tabId": tab.id.uuidString,
                    "topLeftPanelId": topLeftPanelId.uuidString,
                    "bottomLeftPanelId": bottomLeft.id.uuidString,
                    "topRightPanelId": topRight.id.uuidString,
                    "bottomRightPanelId": bottomRight.id.uuidString,
                    "createdPaneCount": String(tab.bonsplitController.allPaneIds.count),
                    "createdPanelCount": String(tab.panels.count)
                ], at: path)

                DebugUIEventCounters.resetEmptyPanelAppearCount()

                // Close the two right panes via the same path as Cmd+W.
                tab.focusPanel(topRight.id)
                _ = tab.closePanel(topRight.id, force: true)
                tab.focusPanel(bottomRight.id)
                _ = tab.closePanel(bottomRight.id, force: true)


                // Capture final state after Bonsplit/AppKit/Ghostty geometry reconciliation.
                // We avoid sleep-based timing and converge over a few main-actor turns.
                 @MainActor func collectSplitCloseRightState() -> (data: [String: String], settled: Bool) {
                    let paneIds = tab.bonsplitController.allPaneIds
                    let bonsplitTabCount = tab.bonsplitController.allTabIds.count
                    let panelCount = tab.panels.count

                    var missingSelectedTabCount = 0
                    var missingPanelMappingCount = 0
                    var selectedTerminalCount = 0
                    var selectedTerminalAttachedCount = 0
                    var selectedTerminalZeroSizeCount = 0
                    var selectedTerminalSurfaceNilCount = 0

                    for paneId in paneIds {
                        guard let selected = tab.bonsplitController.selectedTab(inPane: paneId) else {
                            missingSelectedTabCount += 1
                            continue
                        }
                        guard let panel = tab.panel(for: selected.id) else {
                            missingPanelMappingCount += 1
                            continue
                        }
                        if let terminal = panel as? TerminalPanel {
                            selectedTerminalCount += 1
                            if terminal.hostedView.window != nil {
                                selectedTerminalAttachedCount += 1
                            }
                            let size = terminal.hostedView.bounds.size
                            if size.width < 5 || size.height < 5 {
                                selectedTerminalZeroSizeCount += 1
                            }
                            if terminal.surface.surface == nil {
                                selectedTerminalSurfaceNilCount += 1
                            }
                        }
                    }

                    let settled =
                        paneIds.count == 2 &&
                        missingSelectedTabCount == 0 &&
                        missingPanelMappingCount == 0 &&
                        DebugUIEventCounters.emptyPanelAppearCount == 0 &&
                        selectedTerminalCount == 2 &&
                        selectedTerminalAttachedCount == 2 &&
                        selectedTerminalZeroSizeCount == 0 &&
                        selectedTerminalSurfaceNilCount == 0

                    return (
                        data: [
                            "finalPaneCount": String(paneIds.count),
                            "finalBonsplitTabCount": String(bonsplitTabCount),
                            "finalPanelCount": String(panelCount),
                            "missingSelectedTabCount": String(missingSelectedTabCount),
                            "missingPanelMappingCount": String(missingPanelMappingCount),
                            "emptyPanelAppearCount": String(DebugUIEventCounters.emptyPanelAppearCount),
                            "selectedTerminalCount": String(selectedTerminalCount),
                            "selectedTerminalAttachedCount": String(selectedTerminalAttachedCount),
                            "selectedTerminalZeroSizeCount": String(selectedTerminalZeroSizeCount),
                            "selectedTerminalSurfaceNilCount": String(selectedTerminalSurfaceNilCount),
                        ],
                        settled: settled
                    )
                }
                 @MainActor func reconcileVisibleTerminalGeometry() {
                    NSApp.windows.forEach { window in
                        window.contentView?.layoutSubtreeIfNeeded()
                        window.contentView?.displayIfNeeded()
                    }
                    for paneId in tab.bonsplitController.allPaneIds {
                        guard let selected = tab.bonsplitController.selectedTab(inPane: paneId),
                              let terminal = tab.panel(for: selected.id) as? TerminalPanel else {
                            continue
                        }
                        terminal.hostedView.reconcileGeometryNow()
                        terminal.surface.forceRefresh()
                    }
                }

                var finalState = collectSplitCloseRightState()
                for attempt in 1...8 {
                    reconcileVisibleTerminalGeometry()
                    await Task.yield()
                    finalState = collectSplitCloseRightState()
                    var payload = finalState.data
                    payload["finalAttempt"] = String(attempt)
                    self.writeSplitCloseRightTestData(payload, at: path)
                    if finalState.settled {
                        break
                    }
                }
            }
        }
    }

	    @MainActor
	    private func runSplitCloseRightVisualRepro(
	        tab: Workspace,
	        topLeftPanelId: UUID,
	        path: String,
	        shotsDir: String,
	        iterations: Int,
	        burstFrames: Int,
	        closeDelayMs: Int,
	        pattern: String
	    ) async {
        _ = shotsDir // legacy: screenshots removed in favor of IOSurface sampling

        func sendText(_ panelId: UUID, _ text: String) {
            guard let tp = tab.terminalPanel(for: panelId) else { return }
            tp.surface.sendText(text)
        }

        // Sample a very top strip so the probe remains valid even after vertical expand/collapse.
        // We pin marker text to row 1 before each close sequence.
        let sampleCrop = CGRect(x: 0.04, y: 0.01, width: 0.92, height: 0.08)

        for i in 1...iterations {
            // Reset to a single pane: close everything except the top-left panel.
            tab.focusPanel(topLeftPanelId)
            let toClose = Array(tab.panels.keys).filter { $0 != topLeftPanelId }
            for pid in toClose {
                _ = tab.closePanel(pid, force: true)
            }

            // Create the repro layout. Most patterns use a 2x2 grid, but keep a single-split
            // variant for the exact "close right in a horizontal pair" user report.
            let topLeftId = topLeftPanelId
            let topRight: TerminalPanel
            var bottomLeft: TerminalPanel?
            var bottomRight: TerminalPanel?

            switch pattern {
            case "close_right_single":
                guard let tr = tab.newTerminalSplit(from: topLeftId, orientation: .horizontal) else {
                    writeSplitCloseRightTestData(["setupError": "Failed to split right from top-left (iteration \(i))"], at: path)
                    return
                }
                topRight = tr
            case "close_right_lrtd", "close_right_lrtd_bottom_first", "close_right_bottom_first", "close_right_lrtd_unfocused":
                // User repro: split left/right first, then split top/down in each column.
                guard let tr = tab.newTerminalSplit(from: topLeftId, orientation: .horizontal) else {
                    writeSplitCloseRightTestData(["setupError": "Failed to split right from top-left (iteration \(i))"], at: path)
                    return
                }
                guard let bl = tab.newTerminalSplit(from: topLeftId, orientation: .vertical) else {
                    writeSplitCloseRightTestData(["setupError": "Failed to split down from left (iteration \(i))"], at: path)
                    return
                }
                guard let br = tab.newTerminalSplit(from: tr.id, orientation: .vertical) else {
                    writeSplitCloseRightTestData(["setupError": "Failed to split down from right (iteration \(i))"], at: path)
                    return
                }
                topRight = tr
                bottomLeft = bl
                bottomRight = br
            default:
                // Default: split top/down first, then split left/right in each row.
                guard let bl = tab.newTerminalSplit(from: topLeftId, orientation: .vertical) else {
                    writeSplitCloseRightTestData(["setupError": "Failed to split down from top-left (iteration \(i))"], at: path)
                    return
                }
                guard let br = tab.newTerminalSplit(from: bl.id, orientation: .horizontal) else {
                    writeSplitCloseRightTestData(["setupError": "Failed to split right from bottom-left (iteration \(i))"], at: path)
                    return
                }
                guard let tr = tab.newTerminalSplit(from: topLeftId, orientation: .horizontal) else {
                    writeSplitCloseRightTestData(["setupError": "Failed to split right from top-left (iteration \(i))"], at: path)
                    return
                }
                topRight = tr
                bottomLeft = bl
                bottomRight = br
            }

            // Let newly created surfaces attach before priming content, so sampled panes have
            // stable non-blank text before the close timeline begins.
            try? await Task.sleep(nanoseconds: 180_000_000)

            // Fill left panes with visible content.
            sendText(topLeftId, "printf '\\033[2J\\033[H'; for i in {1..200}; do echo PROGRAMA_SPLIT_TOPLEFT_\(i); done; printf '\\033[HPROGRAMA_MARKER_TOPLEFT\\n'\r")
            sendText(topRight.id, "printf '\\033[2J\\033[H'; for i in {1..200}; do echo PROGRAMA_SPLIT_TOPRIGHT_\(i); done; printf '\\033[HPROGRAMA_MARKER_TOPRIGHT\\n'\r")
            if let bottomLeft {
                sendText(bottomLeft.id, "printf '\\033[2J\\033[H'; for i in {1..200}; do echo PROGRAMA_SPLIT_BOTTOMLEFT_\(i); done; printf '\\033[HPROGRAMA_MARKER_BOTTOMLEFT\\n'\r")
            }
            if let bottomRight {
                sendText(bottomRight.id, "printf '\\033[2J\\033[H'; for i in {1..200}; do echo PROGRAMA_SPLIT_BOTTOMRIGHT_\(i); done; printf '\\033[HPROGRAMA_MARKER_BOTTOMRIGHT\\n'\r")
            }
            // Give shell output a moment to paint before we start the close timeline.
            try? await Task.sleep(nanoseconds: 180_000_000)

            let desiredFrames = max(16, min(burstFrames, 60))
            let closeFrame = min(6, max(1, desiredFrames / 4))
            let delayFrames = max(0, Int((Double(max(0, closeDelayMs)) / 16.6667).rounded(.up)))
            let secondCloseFrame = min(desiredFrames - 1, closeFrame + delayFrames)

            var closeOrder = ""
            let actions: [(frame: Int, action: () -> Void)] = {
                switch pattern {
                case "close_right_single":
                    closeOrder = "TR_ONLY"
                    return [
                        (frame: closeFrame, action: {
                            tab.focusPanel(topRight.id)
                            _ = tab.closePanel(topRight.id, force: true)
                        }),
                    ]
                case "close_bottom":
                    guard let bottomRight, let bottomLeft else { return [] }
                    closeOrder = "BR_THEN_BL"
                    return [
                        (frame: closeFrame, action: {
                            tab.focusPanel(bottomRight.id)
                            _ = tab.closePanel(bottomRight.id, force: true)
                        }),
                        (frame: secondCloseFrame, action: {
                            tab.focusPanel(bottomLeft.id)
                            _ = tab.closePanel(bottomLeft.id, force: true)
                        }),
                    ]
                case "close_right_lrtd_bottom_first", "close_right_bottom_first":
                    guard let bottomRight else { return [] }
                    closeOrder = "BR_THEN_TR"
                    return [
                        (frame: closeFrame, action: {
                            tab.focusPanel(bottomRight.id)
                            _ = tab.closePanel(bottomRight.id, force: true)
                        }),
                        (frame: secondCloseFrame, action: {
                            tab.focusPanel(topRight.id)
                            _ = tab.closePanel(topRight.id, force: true)
                        }),
                    ]
                case "close_right_lrtd_unfocused":
                    guard let bottomRight else { return [] }
                    closeOrder = "TR_THEN_BR_UNFOCUSED"
                    return [
                        (frame: closeFrame, action: {
                            _ = tab.closePanel(topRight.id, force: true)
                        }),
                        (frame: secondCloseFrame, action: {
                            _ = tab.closePanel(bottomRight.id, force: true)
                        }),
                    ]
                default:
                    guard let bottomRight else { return [] }
                    closeOrder = "TR_THEN_BR"
                    return [
                        (frame: closeFrame, action: {
                            tab.focusPanel(topRight.id)
                            _ = tab.closePanel(topRight.id, force: true)
                        }),
                        (frame: secondCloseFrame, action: {
                            tab.focusPanel(bottomRight.id)
                            _ = tab.closePanel(bottomRight.id, force: true)
                        }),
                    ]
                }
            }()

            let targets: [(label: String, view: GhosttySurfaceScrollView)] = {
                switch pattern {
                case "close_right_single":
                    return [
                        ("TL", tab.terminalPanel(for: topLeftId)!.surface.hostedView),
                    ]
                case "close_bottom":
                    return [
                        ("TL", tab.terminalPanel(for: topLeftId)!.surface.hostedView),
                        ("TR", topRight.surface.hostedView),
                    ]
                case "close_right_lrtd_bottom_first", "close_right_bottom_first":
                    return [
                        ("TR", topRight.surface.hostedView),
                        ("TL", tab.terminalPanel(for: topLeftId)!.surface.hostedView),
                    ]
                default:
                    guard let bottomLeft else { return [] }
                    return [
                        ("TL", tab.terminalPanel(for: topLeftId)!.surface.hostedView),
                        ("BL", bottomLeft.surface.hostedView),
                    ]
                }
            }()

            let result = await captureVsyncIOSurfaceTimeline(
                frameCount: desiredFrames,
                closeFrame: closeFrame,
                crop: sampleCrop,
                targets: targets,
                actions: actions
            )

            let paneStateTrace: String = {
                tab.bonsplitController.allPaneIds.map { paneId in
                    let tabs = tab.bonsplitController.tabs(inPane: paneId)
                    let selected = tab.bonsplitController.selectedTab(inPane: paneId)
                    let selectedId = selected.map { String(describing: $0.id) } ?? "nil"
                    let selectedPanelId = selected.flatMap { tab.panelIdFromSurfaceId($0.id) }
                    let selectedPanelLive: String = {
                        guard let selected else { return "0" }
                        return tab.panel(for: selected.id) != nil ? "1" : "0"
                    }()
                    let mappedCount = tabs.filter { tab.panelIdFromSurfaceId($0.id) != nil }.count
                    let selectedPanel = selectedPanelId?.uuidString.prefix(8) ?? "nil"
                    return "pane=\(paneId.id.uuidString.prefix(8)):tabs=\(tabs.count):mapped=\(mappedCount):selected=\(selectedId.prefix(8)):selectedPanel=\(selectedPanel):selectedLive=\(selectedPanelLive)"
                }.joined(separator: ";")
            }()

            writeSplitCloseRightTestData([
                "pattern": pattern,
                "iteration": String(i),
                "closeDelayMs": String(closeDelayMs),
                "closeDelayFrames": String(delayFrames),
                "closeOrder": closeOrder,
                "timelineFrameCount": String(desiredFrames),
                "timelineCloseFrame": String(closeFrame),
                "timelineSecondCloseFrame": String(secondCloseFrame),
                "timelineFirstBlank": result.firstBlank.map { "\($0.label)@\($0.frame)" } ?? "",
                "timelineFirstSizeMismatch": result.firstSizeMismatch.map { "\($0.label)@\($0.frame):ios=\($0.ios):exp=\($0.expected)" } ?? "",
                "timelineTrace": result.trace.joined(separator: "|"),
                "timelinePaneState": paneStateTrace,
                "visualLastIteration": String(i),
            ], at: path)

            if let firstBlank = result.firstBlank {
                writeSplitCloseRightTestData([
                    "blankFrameSeen": "1",
                    "blankObservedIteration": String(i),
                    "blankObservedAt": "\(firstBlank.label)@\(firstBlank.frame)"
                ], at: path)
                return
            }

            if let firstMismatch = result.firstSizeMismatch {
                writeSplitCloseRightTestData([
                    "sizeMismatchSeen": "1",
                    "sizeMismatchObservedIteration": String(i),
                    "sizeMismatchObservedAt": "\(firstMismatch.label)@\(firstMismatch.frame):ios=\(firstMismatch.ios):exp=\(firstMismatch.expected)"
                ], at: path)
                return
            }
        }
	    }

	    @MainActor
	    private func captureVsyncIOSurfaceTimeline(
	        frameCount: Int,
	        closeFrame: Int,
	        crop: CGRect,
	        targets: [(label: String, view: GhosttySurfaceScrollView)],
	        actions: [(frame: Int, action: () -> Void)] = []
	    ) async -> (firstBlank: (label: String, frame: Int)?, firstSizeMismatch: (label: String, frame: Int, ios: String, expected: String)?, trace: [String]) {
	        guard frameCount > 0 else { return (nil, nil, []) }

	        let st = VsyncIOSurfaceTimelineState(frameCount: frameCount, closeFrame: closeFrame)
	        st.scheduledActions = actions.sorted(by: { $0.frame < $1.frame })
	        st.nextActionIndex = 0
	        st.targets = targets.map { t in
	            VsyncIOSurfaceTimelineState.Target(label: t.label, sample: { @MainActor in
	                t.view.debugSampleIOSurface(normalizedCrop: crop)
	            })
	        }

	        let unmanaged = Unmanaged.passRetained(st)
	        let ctx = unmanaged.toOpaque()

	        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
	            st.continuation = cont
	            var link: CVDisplayLink?
	            CVDisplayLinkCreateWithActiveCGDisplays(&link)
	            guard let link else {
	                st.finish()
	                Unmanaged<VsyncIOSurfaceTimelineState>.fromOpaque(ctx).release()
	                return
	            }
	            st.link = link

	            CVDisplayLinkSetOutputCallback(link, programaVsyncIOSurfaceTimelineCallback, ctx)
	            CVDisplayLinkStart(link)
	        }

	        return (st.firstBlank, st.firstSizeMismatch, st.trace)
	    }

    private func writeSplitCloseRightTestData(_ updates: [String: String], at path: String) {
        var payload = loadSplitCloseRightTestData(at: path)
        for (key, value) in updates {
            payload[key] = value
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private func loadSplitCloseRightTestData(at path: String) -> [String: String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return object
    }

    // Widened from `private` to `internal`: called from TabManager.init() in TabManager.swift.
    func setupChildExitSplitUITestIfNeeded() {
        guard !didSetupChildExitSplitUITest else { return }
        didSetupChildExitSplitUITest = true

        let env = ProcessInfo.processInfo.environment
        guard env["PROGRAMA_UI_TEST_CHILD_EXIT_SPLIT_SETUP"] == "1" else { return }
        guard let path = env["PROGRAMA_UI_TEST_CHILD_EXIT_SPLIT_PATH"], !path.isEmpty else { return }
        let requestedIterations = Int(env["PROGRAMA_UI_TEST_CHILD_EXIT_SPLIT_ITERATIONS"] ?? "1") ?? 1
        let iterations = max(1, min(requestedIterations, 20))

        func write(_ updates: [String: String]) {
            var payload: [String: String] = {
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
                    return [:]
                }
                return obj
            }()
            for (k, v) in updates { payload[k] = v }
            guard let out = try? JSONSerialization.data(withJSONObject: payload) else { return }
            try? out.write(to: URL(fileURLWithPath: path), options: .atomic)
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            // Small delay so the initial window/panel has completed first layout.
            try? await Task.sleep(nanoseconds: 200_000_000)

            guard let tab = self.selectedWorkspace else {
                write(["setupError": "Missing selected workspace", "done": "1"])
                return
            }
            write([
                "requestedIterations": String(requestedIterations),
                "iterations": String(iterations),
                "workspaceCountBefore": String(self.tabs.count),
                "panelCountBefore": String(tab.panels.count),
                "done": "0",
            ])

            var completedIterations = 0
            var timedOut = false
            var closedWorkspace = false

            for i in 1...iterations {
                guard self.tabs.contains(where: { $0.id == tab.id }) else {
                    closedWorkspace = true
                    break
                }

                guard let leftPanelId = tab.focusedPanelId ?? tab.panels.keys.first else {
                    write(["setupError": "Missing focused panel before iteration \(i)", "done": "1"])
                    return
                }

                // Start each iteration from a deterministic 1x1 workspace.
                if tab.panels.count > 1 {
                    for panelId in tab.panels.keys where panelId != leftPanelId {
                        _ = tab.closePanel(panelId, force: true)
                    }
                    let collapsed = await self.waitForWorkspacePanelsCondition(
                        tab: tab,
                        timeoutSeconds: 2.0
                    ) { workspace in
                        workspace.panels.count == 1
                    }
                    if !collapsed {
                        write(["setupError": "Timed out collapsing workspace before iteration \(i)", "done": "1"])
                        return
                    }
                }

                guard let rightPanel = tab.newTerminalSplit(from: leftPanelId, orientation: .horizontal) else {
                    write(["setupError": "Failed to create right split at iteration \(i)", "done": "1"])
                    return
                }

                write([
                    "iteration": String(i),
                    "leftPanelId": leftPanelId.uuidString,
                    "rightPanelId": rightPanel.id.uuidString,
                ])

                tab.focusPanel(rightPanel.id)
                // Wait for the split terminal surface to be attached before sending exit.
                // Without this, very early writes can be dropped during initial surface creation.
                _ = await self.waitForTerminalPanelCondition(
                    tab: tab,
                    panelId: rightPanel.id,
                    timeoutSeconds: 2.0
                ) { panel in
                    panel.hostedView.window != nil && panel.surface.surface != nil
                }
                // Use an explicit shell exit command for deterministic child-exit behavior across
                // startup timing variance; this still exercises the same SHOW_CHILD_EXITED path.
                rightPanel.surface.sendText("exit\r")

                // Wait for the right panel to close.
                let closed = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                    var cancellable: AnyCancellable?
                    var resolved = false

                    func finish(_ value: Bool) {
                        guard !resolved else { return }
                        resolved = true
                        cancellable?.cancel()
                        cont.resume(returning: value)
                    }

                    cancellable = tab.$panels
                        .map { $0.count }
                        .removeDuplicates()
                        .sink { count in
                            if count == 1 {
                                finish(true)
                            }
                        }

                    DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) {
                        finish(false)
                    }
                }

                if !closed {
                    timedOut = true
                    write(["timedOutIteration": String(i)])
                    break
                }

                if !self.tabs.contains(where: { $0.id == tab.id }) {
                    closedWorkspace = true
                    write(["closedWorkspaceIteration": String(i)])
                    break
                }

                completedIterations = i
            }

            let workspaceStillOpen = self.tabs.contains(where: { $0.id == tab.id })
            let effectiveClosedWorkspace = closedWorkspace || !workspaceStillOpen

            write([
                "workspaceCountAfter": String(self.tabs.count),
                "panelCountAfter": String(tab.panels.count),
                "workspaceStillOpen": workspaceStillOpen ? "1" : "0",
                "closedWorkspace": effectiveClosedWorkspace ? "1" : "0",
                "timedOut": timedOut ? "1" : "0",
                "completedIterations": String(completedIterations),
                "done": "1",
            ])
        }
    }

    // Widened from `private` to `internal`: called from TabManager.init() in TabManager.swift.
    func setupChildExitKeyboardUITestIfNeeded() {
        guard !didSetupChildExitKeyboardUITest else { return }
        didSetupChildExitKeyboardUITest = true

        let env = ProcessInfo.processInfo.environment
        guard env["PROGRAMA_UI_TEST_CHILD_EXIT_KEYBOARD_SETUP"] == "1" else { return }
        guard let path = env["PROGRAMA_UI_TEST_CHILD_EXIT_KEYBOARD_PATH"], !path.isEmpty else { return }
        let autoTrigger = env["PROGRAMA_UI_TEST_CHILD_EXIT_KEYBOARD_AUTO_TRIGGER"] == "1"
        let strictKeyOnly = env["PROGRAMA_UI_TEST_CHILD_EXIT_KEYBOARD_STRICT"] == "1"
        let triggerMode = (env["PROGRAMA_UI_TEST_CHILD_EXIT_KEYBOARD_TRIGGER_MODE"] ?? "shell_input")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let useEarlyCtrlShiftTrigger = triggerMode == "early_ctrl_shift_d"
        let useEarlyCtrlDTrigger = triggerMode == "early_ctrl_d"
        let useEarlyTrigger = useEarlyCtrlShiftTrigger || useEarlyCtrlDTrigger
        let triggerUsesShift = triggerMode == "ctrl_shift_d" || useEarlyCtrlShiftTrigger
        let layout = (env["PROGRAMA_UI_TEST_CHILD_EXIT_KEYBOARD_LAYOUT"] ?? "lr")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let expectedPanelsAfter = max(
            1,
            Int((env["PROGRAMA_UI_TEST_CHILD_EXIT_KEYBOARD_EXPECTED_PANELS_AFTER"] ?? "1")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            ) ?? 1
        )

        func write(_ updates: [String: String]) {
            var payload: [String: String] = {
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
                    return [:]
                }
                return obj
            }()
            for (k, v) in updates { payload[k] = v }
            guard let out = try? JSONSerialization.data(withJSONObject: payload) else { return }
            try? out.write(to: URL(fileURLWithPath: path), options: .atomic)
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 200_000_000)

            guard let tab = self.selectedWorkspace else {
                write(["setupError": "Missing selected workspace", "done": "1"])
                return
            }
            guard let leftPanelId = tab.focusedPanelId else {
                write(["setupError": "Missing initial focused panel", "done": "1"])
                return
            }
            guard let rightPanel = tab.newTerminalSplit(from: leftPanelId, orientation: .horizontal) else {
                write(["setupError": "Failed to create right split", "done": "1"])
                return
            }

            var bottomLeftPanelId = ""
            let topRightPanelId = rightPanel.id.uuidString
            var bottomRightPanelId = ""
            var exitPanelId = rightPanel.id

            if layout == "lr_left_vertical" {
                guard let bottomLeft = tab.newTerminalSplit(from: leftPanelId, orientation: .vertical) else {
                    write(["setupError": "Failed to create bottom-left split", "done": "1"])
                    return
                }
                bottomLeftPanelId = bottomLeft.id.uuidString
            } else if layout == "lrtd_close_right_then_exit_top_left" {
                guard let bottomLeft = tab.newTerminalSplit(from: leftPanelId, orientation: .vertical) else {
                    write(["setupError": "Failed to create bottom-left split", "done": "1"])
                    return
                }
                guard let bottomRight = tab.newTerminalSplit(from: rightPanel.id, orientation: .vertical) else {
                    write(["setupError": "Failed to create bottom-right split", "done": "1"])
                    return
                }
                bottomLeftPanelId = bottomLeft.id.uuidString
                bottomRightPanelId = bottomRight.id.uuidString

                // Repro flow: with a 2x2 (left/right then top/down), close both right panes,
                // then trigger Ctrl+D in top-left.
                tab.focusPanel(rightPanel.id)
                _ = tab.closePanel(rightPanel.id, force: true)
                tab.focusPanel(bottomRight.id)
                _ = tab.closePanel(bottomRight.id, force: true)
                exitPanelId = leftPanelId

                let collapsed = await self.waitForWorkspacePanelsCondition(
                    tab: tab,
                    timeoutSeconds: 2.0
                ) { workspace in
                    workspace.panels.count == 2
                }
                if !collapsed {
                    write([
                        "setupError": "Expected 2 panels after closing right column, got \(tab.panels.count)",
                        "done": "1",
                    ])
                    return
                }
            } else if layout == "tdlr_close_bottom_then_exit_top_left" {
                // Alternate repro flow:
                // 1) split top/down
                // 2) split left/right for each row (2x2)
                // 3) close both bottom panes
                // 4) trigger Ctrl+D in top-left
                guard let bottomLeft = tab.newTerminalSplit(from: leftPanelId, orientation: .vertical) else {
                    write(["setupError": "Failed to create bottom-left split", "done": "1"])
                    return
                }
                guard let topRight = tab.newTerminalSplit(from: leftPanelId, orientation: .horizontal) else {
                    write(["setupError": "Failed to create top-right split", "done": "1"])
                    return
                }
                guard let bottomRight = tab.newTerminalSplit(from: bottomLeft.id, orientation: .horizontal) else {
                    write(["setupError": "Failed to create bottom-right split", "done": "1"])
                    return
                }
                bottomLeftPanelId = bottomLeft.id.uuidString
                bottomRightPanelId = bottomRight.id.uuidString

                // Close every pane except the top row; do it one-by-one and wait for model convergence.
                let keepPanels: Set<UUID> = [leftPanelId, topRight.id]
                for panelId in Array(tab.panels.keys) where !keepPanels.contains(panelId) {
                    tab.focusPanel(panelId)
                    _ = tab.closePanel(panelId, force: true)
                    let closed = await self.waitForWorkspacePanelsCondition(
                        tab: tab,
                        timeoutSeconds: 1.0
                    ) { workspace in
                        workspace.panels[panelId] == nil
                    }
                    if !closed {
                        write([
                            "setupError": "Failed to close bottom pane \(panelId.uuidString)",
                            "done": "1",
                        ])
                        return
                    }
                }
                exitPanelId = leftPanelId

                let collapsed = await self.waitForWorkspacePanelsCondition(
                    tab: tab,
                    timeoutSeconds: 2.0
                ) { workspace in
                    workspace.panels.count == 2
                }
                if !collapsed {
                    write([
                        "setupError": "Expected 2 panels after closing bottom row, got \(tab.panels.count)",
                        "done": "1",
                    ])
                    return
                }
            }

            tab.focusPanel(exitPanelId)
            // Keep child-exit keyboard tests deterministic across user shell configs.
            // `exec cat` exits on a single Ctrl+D and avoids ignore-eof shell settings.
            if let exitPanel = tab.terminalPanel(for: exitPanelId) {
                exitPanel.sendText("exec cat\r")
            }

            var exitPanelAttachedBeforeCtrlD = false
            var exitPanelHasSurfaceBeforeCtrlD = false
            if !useEarlyTrigger {
                let readiness = await self.waitForTerminalPanelReadyForUITest(
                    tab: tab,
                    panelId: exitPanelId
                )
                exitPanelAttachedBeforeCtrlD = readiness.attached
                exitPanelHasSurfaceBeforeCtrlD = readiness.hasSurface
                if !(readiness.attached && readiness.hasSurface) {
                    write([
                        "exitPanelAttachedBeforeCtrlD": readiness.attached ? "1" : "0",
                        "exitPanelHasSurfaceBeforeCtrlD": readiness.hasSurface ? "1" : "0",
                        "setupError": "Exit panel not ready for Ctrl+D (not attached or surface nil)",
                        "done": "1",
                    ])
                    return
                }
                self.ensureFocusedTerminalFirstResponder()
            } else if let exitPanel = tab.terminalPanel(for: exitPanelId) {
                exitPanelAttachedBeforeCtrlD = exitPanel.hostedView.window != nil
                exitPanelHasSurfaceBeforeCtrlD = exitPanel.surface.surface != nil
            }

            let focusedPanelBefore = tab.focusedPanelId?.uuidString ?? ""
            let firstResponderPanelBefore = tab.panels.compactMap { (panelId, panel) -> UUID? in
                guard let terminal = panel as? TerminalPanel else { return nil }
                return terminal.hostedView.isSurfaceViewFirstResponder() ? panelId : nil
            }.first?.uuidString ?? ""

            write([
                "workspaceId": tab.id.uuidString,
                "leftPanelId": leftPanelId.uuidString,
                "rightPanelId": rightPanel.id.uuidString,
                "topRightPanelId": topRightPanelId,
                "bottomLeftPanelId": bottomLeftPanelId,
                "bottomRightPanelId": bottomRightPanelId,
                "exitPanelId": exitPanelId.uuidString,
                "panelCountBeforeCtrlD": String(tab.panels.count),
                "layout": layout,
                "expectedPanelsAfter": String(expectedPanelsAfter),
                "focusedPanelBefore": focusedPanelBefore,
                "firstResponderPanelBefore": firstResponderPanelBefore,
                "exitPanelAttachedBeforeCtrlD": exitPanelAttachedBeforeCtrlD ? "1" : "0",
                "exitPanelHasSurfaceBeforeCtrlD": exitPanelHasSurfaceBeforeCtrlD ? "1" : "0",
                "ready": "1",
                "done": "0",
            ])

            var finished = false
            var timeoutWork: DispatchWorkItem?

            @MainActor
            func finish(_ updates: [String: String]) {
                guard !finished else { return }
                finished = true
                timeoutWork?.cancel()
                write(updates.merging(["done": "1"], uniquingKeysWith: { _, new in new }))
                self.uiTestCancellables.removeAll()
            }

            tab.$panels
                .map { $0.count }
                .removeDuplicates()
                .sink { [weak self, weak tab] count in
                    Task { @MainActor in
                        guard let self, let tab else { return }
                        if count == expectedPanelsAfter {
                            // Require the post-exit state to be stable for a short window so
                            // we catch "close looked correct, then workspace vanished" races.
                            try? await Task.sleep(nanoseconds: 1_200_000_000)
                            guard tab.panels.count == expectedPanelsAfter else { return }

                            let firstResponderPanelAfter = tab.panels.compactMap { (panelId, panel) -> UUID? in
                                guard let terminal = panel as? TerminalPanel else { return nil }
                                return terminal.hostedView.isSurfaceViewFirstResponder() ? panelId : nil
                            }.first?.uuidString ?? ""

                            finish([
                                "workspaceCountAfter": String(self.tabs.count),
                                "panelCountAfter": String(tab.panels.count),
                                "closedWorkspace": self.tabs.contains(where: { $0.id == tab.id }) ? "0" : "1",
                                "focusedPanelAfter": tab.focusedPanelId?.uuidString ?? "",
                                "firstResponderPanelAfter": firstResponderPanelAfter,
                            ])
                        }
                    }
                }
                .store(in: &uiTestCancellables)

            $tabs
                .map { $0.contains(where: { $0.id == tab.id }) }
                .removeDuplicates()
                .sink { alive in
                    Task { @MainActor in
                        if !alive {
                            finish([
                                "workspaceCountAfter": "0",
                                "panelCountAfter": "0",
                                "closedWorkspace": "1",
                            ])
                        }
                    }
                }
                .store(in: &uiTestCancellables)

            let work = DispatchWorkItem {
                finish([
                    "workspaceCountAfter": String(self.tabs.count),
                    "panelCountAfter": String(tab.panels.count),
                    "closedWorkspace": self.tabs.contains(where: { $0.id == tab.id }) ? "0" : "1",
                    "timedOut": "1",
                ])
            }
            timeoutWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 8.0, execute: work)

            if autoTrigger {
                Task { @MainActor [weak tab] in
                    guard let tab else { return }
                    write(["autoTriggerStarted": "1"])

                    if triggerMode == "runtime_close_callback" {
                        write(["autoTriggerMode": "runtime_close_callback"])
                        self.closePanelAfterChildExited(tabId: tab.id, surfaceId: exitPanelId)
                        return
                    }

                    let triggerModifiers: NSEvent.ModifierFlags = triggerUsesShift
                        ? [.control, .shift]
                        : [.control]
                    let shouldWaitForSurface = !useEarlyTrigger

                    var attachedBeforeTrigger = false
                    var hasSurfaceBeforeTrigger = false
                    if shouldWaitForSurface {
                        let ready = await self.waitForTerminalPanelCondition(
                            tab: tab,
                            panelId: exitPanelId,
                            timeoutSeconds: 5.0
                        ) { panel in
                            attachedBeforeTrigger = panel.hostedView.window != nil
                            hasSurfaceBeforeTrigger = panel.surface.surface != nil
                            return attachedBeforeTrigger && hasSurfaceBeforeTrigger
                        }
                        if !ready,
                           tab.terminalPanel(for: exitPanelId) == nil {
                            write(["autoTriggerError": "missingExitPanelBeforeTrigger"])
                            return
                        }
                    } else if let panel = tab.terminalPanel(for: exitPanelId) {
                        attachedBeforeTrigger = panel.hostedView.window != nil
                        hasSurfaceBeforeTrigger = panel.surface.surface != nil
                    }
                    write([
                        "exitPanelAttachedBeforeTrigger": attachedBeforeTrigger ? "1" : "0",
                        "exitPanelHasSurfaceBeforeTrigger": hasSurfaceBeforeTrigger ? "1" : "0",
                    ])
                    if shouldWaitForSurface && !(attachedBeforeTrigger && hasSurfaceBeforeTrigger) {
                        write(["autoTriggerError": "exitPanelNotReadyBeforeTrigger"])
                        return
                    }

                    guard let panel = tab.terminalPanel(for: exitPanelId) else {
                        write(["autoTriggerError": "missingExitPanelAtTrigger"])
                        return
                    }
                    // Exercise the real key path (ghostty_surface_key for Ctrl+D).
                    if panel.hostedView.sendSyntheticCtrlDForUITest(modifierFlags: triggerModifiers) {
                        write(["autoTriggerSentCtrlDKey1": "1"])
                    } else {
                        write([
                            "autoTriggerCtrlDKeyUnavailable": "1",
                            "autoTriggerError": "ctrlDKeyUnavailable",
                        ])
                        return
                    }

                    // In strict mode, never mask routing bugs with fallback writes.
                    if strictKeyOnly {
                        let strictModeLabel: String = {
                            if useEarlyCtrlShiftTrigger { return "strict_early_ctrl_shift_d" }
                            if useEarlyCtrlDTrigger { return "strict_early_ctrl_d" }
                            if triggerUsesShift { return "strict_ctrl_shift_d" }
                            return "strict_ctrl_d"
                        }()
                        write(["autoTriggerMode": strictModeLabel])
                        return
                    }

                    // Non-strict mode keeps one additional Ctrl+D retry for startup timing variance.
                    try? await Task.sleep(nanoseconds: 450_000_000)
                    if tab.panels[exitPanelId] != nil,
                       panel.hostedView.sendSyntheticCtrlDForUITest(modifierFlags: triggerModifiers) {
                        write(["autoTriggerSentCtrlDKey2": "1"])
                    }
                }
            }
        }
    }
#endif
}
