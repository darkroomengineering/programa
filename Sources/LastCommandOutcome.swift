import Foundation

/// Outcome of the most recently finished shell command in a workspace, derived from Ghostty's
/// OSC 133 semantic prompt tracking (`GHOSTTY_ACTION_COMMAND_FINISHED`). Plumbing-only model:
/// no UI reads this yet.
struct LastCommandOutcome: Equatable {
    /// `nil` when Ghostty reported no exit code (C value `-1`); otherwise 0-255.
    let exitCode: Int?
    /// Wall-clock duration the command ran for, in seconds.
    let duration: TimeInterval
    let finishedAt: Date
    /// Panel (surface) that reported this outcome.
    let sourcePanelId: UUID

    /// Builds a `LastCommandOutcome` from the raw C ABI values reported by Ghostty.
    /// - Parameters:
    ///   - exitCode: raw `int16_t` from `ghostty_action_command_finished_s.exit_code`;
    ///     `-1` means "no exit code was reported".
    ///   - durationNanoseconds: raw `uint64_t` from
    ///     `ghostty_action_command_finished_s.duration`.
    static func from(
        exitCode: Int16,
        durationNanoseconds: UInt64,
        sourcePanelId: UUID,
        finishedAt: Date = Date()
    ) -> LastCommandOutcome {
        LastCommandOutcome(
            exitCode: exitCode == -1 ? nil : Int(exitCode),
            duration: TimeInterval(durationNanoseconds) / 1_000_000_000,
            finishedAt: finishedAt,
            sourcePanelId: sourcePanelId
        )
    }

    /// Formats a duration human-readably: under 60s as "42s", otherwise "2m 14s".
    static func formattedDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = Int(duration.rounded())
        if totalSeconds < 60 {
            return "\(totalSeconds)s"
        }
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return "\(minutes)m \(seconds)s"
    }
}

/// Threshold-gated experimental notification: post a system notification when a long-running
/// command finishes in a pane the user is not currently looking at.
enum LongCommandNotificationSettings {
    static let thresholdSeconds: TimeInterval = 30
}
