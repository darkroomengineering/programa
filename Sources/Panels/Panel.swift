import Foundation
import Combine
import AppKit
import SwiftUI

public enum PanelType: String, Codable, Sendable {
    case terminal
    case markdown
    case review
}

public enum TerminalPanelFocusIntent: Equatable {
    case surface
    case findField
}

public enum PanelFocusIntent: Equatable {
    case panel
    case terminal(TerminalPanelFocusIntent)
}

@MainActor
final class FocusTransitionCoordinator {
    struct Owner: Equatable {
        let workspaceID: UUID
        let panelID: UUID
        let intent: PanelFocusIntent
    }

    enum Reason: Equatable {
        case workspaceSelection
        case nonFocusSplit
    }

    struct Request: Equatable {
        let generation: UInt64
        let owner: Owner
        let reason: Reason
    }

    private(set) var newestRequest: Request?
    private(set) var committedOwner: Owner?
    private var nextGeneration: UInt64 = 0

    func beginTransition(to owner: Owner, reason: Reason) -> Request {
        nextGeneration &+= 1
        let request = Request(
            generation: nextGeneration,
            owner: owner,
            reason: reason
        )
        newestRequest = request
        return request
    }

    func captureCurrentGeneration(for owner: Owner, reason: Reason) -> Request {
        Request(
            generation: nextGeneration,
            owner: owner,
            reason: reason
        )
    }

    func isCurrentGeneration(_ request: Request) -> Bool {
        request.generation == nextGeneration
    }

    @discardableResult
    func completeTransition(_ request: Request) -> Bool {
        guard newestRequest == request else { return false }
        committedOwner = request.owner
        return true
    }
}

public enum WorkspaceAttentionFlashReason: String, Equatable, Sendable {
    case navigation
    case notificationArrival
    case notificationDismiss
    case manualUnreadDismiss
    case debug
}

enum WorkspaceAttentionFlashAccent: Equatable, Sendable {
    case notificationBlue
    case navigationTeal

    var strokeColor: NSColor {
        switch self {
        case .notificationBlue:
            return .systemBlue
        case .navigationTeal:
            return .systemTeal
        }
    }
}

struct WorkspaceAttentionFlashPresentation: Equatable, Sendable {
    let accent: WorkspaceAttentionFlashAccent
    let glowOpacity: Double
    let glowRadius: CGFloat
}

struct WorkspaceAttentionPersistentState: Equatable, Sendable {
    var unreadPanelIDs: Set<UUID> = []
    var focusedReadPanelID: UUID?
    var manualUnreadPanelIDs: Set<UUID> = []

    var indicatorPanelIDs: Set<UUID> {
        var ids = unreadPanelIDs.union(manualUnreadPanelIDs)
        if let focusedReadPanelID {
            ids.insert(focusedReadPanelID)
        }
        return ids
    }

    func hasCompetingIndicator(for panelID: UUID) -> Bool {
        indicatorPanelIDs.contains(where: { $0 != panelID })
    }
}

struct WorkspaceAttentionFlashDecision: Equatable, Sendable {
    let panelID: UUID
    let reason: WorkspaceAttentionFlashReason
    let isAllowed: Bool
}

enum WorkspaceAttentionCoordinator {
    static func flashStyle(for reason: WorkspaceAttentionFlashReason) -> WorkspaceAttentionFlashPresentation {
        switch reason {
        case .navigation:
            return WorkspaceAttentionFlashPresentation(
                accent: .navigationTeal,
                glowOpacity: 0.14,
                glowRadius: 3
            )
        case .notificationArrival, .notificationDismiss, .manualUnreadDismiss, .debug:
            return WorkspaceAttentionFlashPresentation(
                accent: .notificationBlue,
                glowOpacity: 0.6,
                glowRadius: 6
            )
        }
    }

    static func decideFlash(
        targetPanelID: UUID,
        reason: WorkspaceAttentionFlashReason,
        persistentState: WorkspaceAttentionPersistentState
    ) -> WorkspaceAttentionFlashDecision {
        let isAllowed: Bool
        switch reason {
        case .navigation:
            isAllowed = !persistentState.hasCompetingIndicator(for: targetPanelID)
        case .notificationArrival, .notificationDismiss, .manualUnreadDismiss, .debug:
            isAllowed = true
        }

        return WorkspaceAttentionFlashDecision(
            panelID: targetPanelID,
            reason: reason,
            isAllowed: isAllowed
        )
    }
}

enum FocusFlashCurve: Equatable {
    case easeIn
    case easeOut
}

enum PanelOverlayRingMetrics {
    static let inset: CGFloat = 2
    static let cornerRadius: CGFloat = 6
    static let lineWidth: CGFloat = 2.5

    static func pathRect(in bounds: CGRect) -> CGRect {
        bounds.insetBy(dx: inset, dy: inset)
    }
}

struct FocusFlashSegment: Equatable {
    let delay: TimeInterval
    let duration: TimeInterval
    let targetOpacity: Double
    let curve: FocusFlashCurve
}

/// One flash timeline, shared by the terminal `CAKeyframeAnimation` and the SwiftUI
/// `PhaseAnimator` overlays so both render the same pulse.
struct FocusFlashTimeline {
    let values: [Double]
    let keyTimes: [Double]
    let duration: TimeInterval
    let curves: [FocusFlashCurve]

    var segments: [FocusFlashSegment] {
        let stepCount = min(curves.count, values.count - 1, keyTimes.count - 1)
        return (0..<stepCount).map { index in
            let startTime = keyTimes[index]
            let endTime = keyTimes[index + 1]
            return FocusFlashSegment(
                delay: startTime * duration,
                duration: (endTime - startTime) * duration,
                targetOpacity: values[index + 1],
                curve: curves[index]
            )
        }
    }

    /// Bounds-checked so a `PhaseAnimator` still holding a phase from a longer timeline
    /// (Reduce Motion toggled mid-flash) cannot index past the end.
    func opacity(atPhase index: Int) -> Double {
        values.indices.contains(index) ? values[index] : 0
    }

    func opacity(at elapsed: TimeInterval) -> Double {
        guard elapsed >= 0, elapsed <= duration else { return 0 }

        for index in 0..<segments.count {
            let startTime = keyTimes[index] * duration
            let endTime = keyTimes[index + 1] * duration
            if elapsed > endTime {
                continue
            }

            let segmentDuration = max(endTime - startTime, 0.0001)
            let rawProgress = max(0, min(1, (elapsed - startTime) / segmentDuration))
            let curvedProgress = Self.interpolatedProgress(rawProgress, curve: curves[index])
            let startOpacity = values[index]
            let endOpacity = values[index + 1]
            return startOpacity + ((endOpacity - startOpacity) * curvedProgress)
        }

        return values.last ?? 0
    }

    private static func interpolatedProgress(_ progress: Double, curve: FocusFlashCurve) -> Double {
        switch curve {
        case .easeIn:
            return progress * progress
        case .easeOut:
            let inverse = 1 - progress
            return 1 - (inverse * inverse)
        }
    }

    /// SwiftUI `Animation` to use when a `PhaseAnimator` transitions *into* `values[index]`
    /// from `values[index - 1]`. Plays the whole sequence as one atomic animator run per
    /// `focusFlashToken` change, instead of chained `asyncAfter` + `withAnimation` steps
    /// that SwiftUI can coalesce/interrupt.
    func phaseAnimation(at index: Int) -> Animation? {
        let segments = segments
        guard index > 0, index - 1 < segments.count else { return nil }
        let segment = segments[index - 1]
        switch segment.curve {
        case .easeIn:
            return .easeIn(duration: segment.duration)
        case .easeOut:
            return .easeOut(duration: segment.duration)
        }
    }
}

enum FocusFlashPattern {
    static let standard = FocusFlashTimeline(
        values: [0, 1, 0, 1, 0],
        keyTimes: [0, 0.25, 0.5, 0.75, 1],
        duration: 0.9,
        curves: [.easeOut, .easeOut, .easeOut, .easeOut]
    )
    /// Reduce Motion: a single shorter pulse instead of the double flash.
    static let reduced = FocusFlashTimeline(
        values: [0, 1, 0],
        keyTimes: [0, 0.3, 1],
        duration: 0.5,
        curves: [.easeOut, .easeOut]
    )
    static let ringInset: Double = Double(PanelOverlayRingMetrics.inset)
    static let ringCornerRadius: Double = Double(PanelOverlayRingMetrics.cornerRadius)

    static var values: [Double] { standard.values }
    static var keyTimes: [Double] { standard.keyTimes }
    static var duration: TimeInterval { standard.duration }
    static var curves: [FocusFlashCurve] { standard.curves }
    static var segments: [FocusFlashSegment] { standard.segments }

    static func timeline(reduceMotion: Bool) -> FocusFlashTimeline {
        reduceMotion ? reduced : standard
    }
}

@MainActor
public protocol Panel: AnyObject, Identifiable, ObservableObject where ID == UUID {
    var id: UUID { get }

    var panelType: PanelType { get }

    /// Display title shown in tab bar
    var displayTitle: String { get }

    /// Optional SF Symbol icon name for the tab
    var displayIcon: String? { get }

    /// Whether the panel has unsaved changes
    var isDirty: Bool { get }

    /// Close the panel and clean up resources
    func close()

    /// Focus the panel for input
    func focus()

    func unfocus()

    /// Trigger a focus flash animation for this panel.
    func triggerFlash(reason: WorkspaceAttentionFlashReason)

    /// Capture the panel-local focus target that should be restored later.
    func captureFocusIntent(in window: NSWindow?) -> PanelFocusIntent

    /// Return the best focus target to restore when this panel becomes active again.
    func preferredFocusIntentForActivation() -> PanelFocusIntent

    /// Prime panel-local focus state before activation side effects run.
    func prepareFocusIntentForActivation(_ intent: PanelFocusIntent)

    /// Restore a previously captured focus target.
    @discardableResult
    func restoreFocusIntent(_ intent: PanelFocusIntent) -> Bool

    /// Return the semantic focus target currently owned by this panel, if any.
    func ownedFocusIntent(for responder: NSResponder, in window: NSWindow) -> PanelFocusIntent?

    /// Explicitly yield a previously owned focus target before another panel restores focus.
    @discardableResult
    func yieldFocusIntent(_ intent: PanelFocusIntent, in window: NSWindow) -> Bool
}

extension Panel {
    public var displayIcon: String? { nil }
    public var isDirty: Bool { false }

    func captureFocusIntent(in window: NSWindow?) -> PanelFocusIntent {
        _ = window
        return preferredFocusIntentForActivation()
    }

    func preferredFocusIntentForActivation() -> PanelFocusIntent {
        .panel
    }

    func prepareFocusIntentForActivation(_ intent: PanelFocusIntent) {
        _ = intent
    }

    @discardableResult
    func restoreFocusIntent(_ intent: PanelFocusIntent) -> Bool {
        guard intent == .panel else { return false }
        focus()
        return true
    }

    func ownedFocusIntent(for responder: NSResponder, in window: NSWindow) -> PanelFocusIntent? {
        _ = responder
        _ = window
        return nil
    }

    @discardableResult
    func yieldFocusIntent(_ intent: PanelFocusIntent, in window: NSWindow) -> Bool {
        _ = intent
        _ = window
        return false
    }

    func triggerFlash() {
        triggerFlash(reason: .navigation)
    }
}
