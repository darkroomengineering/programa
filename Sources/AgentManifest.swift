// Screen-manifest agent detection (docs/plans/screen-manifest-detection.md), v2 tier of #164's
// agent activity state model. `AgentManifest` is the Codable schema for a single agent's
// declarative screen-pattern rules (bundled JSON in Resources/AgentDetection/*.json, optionally
// overlaid by a user override at ~/.config/programa/agent-detection/<agent>.json — see
// AgentManifestLoader.swift). Full schema spec + authoring guidance: docs/agent-detection-manifests.md.
//
// `classify(text:)` is a pure function (no threading/engine dependency) so it's directly
// unit-testable (programaTests/AgentManifestTests.swift) without touching AgentScreenDetectionEngine.
import Foundation

/// A single agent's screen-pattern manifest (schema v1). Decoded from bundled or user-override
/// JSON — see the file header for locations/precedence.
struct AgentManifest: Codable, Sendable, Equatable {
    let version: Int
    /// Stable identifier, e.g. "claude-code" — matches the bundled JSON filename (without
    /// extension) and is the key manifests are looked up by (`AgentManifestLoader.manifest(forAgent:)`).
    let agent: String
    let displayName: String
    let recognize: Recognizer
    /// State classification rules, checked in descending `priority` order — see `classify(text:)`.
    let states: [StateRule]

    enum CodingKeys: String, CodingKey {
        case version
        case agent
        case displayName = "display_name"
        case recognize
        case states
    }

    /// Phase A ("recognition") signals: what makes a surface a *candidate* for Phase B sampling
    /// in the first place. `processNames` is the ideal signal (an exact foreground-command match
    /// from shell-integration telemetry); `screenPatterns` is the always-available fallback used
    /// by `AgentScreenDetectionEngine`'s slow-cadence recognition scan when no foreground-command
    /// signal exists on the wire (see that file's header for why v1 uses the fallback exclusively).
    struct Recognizer: Codable, Sendable, Equatable {
        let processNames: [String]
        let screenPatterns: [String]

        enum CodingKeys: String, CodingKey {
            case processNames = "process_names"
            case screenPatterns = "screen_patterns"
        }
    }

    /// One classification bucket's rules. `bucket` is one of "working" | "blocked" | "idle" |
    /// "done" (manifest-internal vocabulary — "done" collapses to the wire's `.idle` at report
    /// time; see docs/plans/screen-manifest-detection.md §1.2 for why a 4th wire state was
    /// rejected). `confidence` / `sourceNotes` are documentation-only (never read by code) —
    /// greppable markers for which patterns are verified vs. best-effort guesses.
    struct StateRule: Codable, Sendable, Equatable {
        let bucket: String
        /// Higher priority is checked first within one sample; the first matching bucket wins.
        let priority: Int
        /// Only the last N lines of the sampled text are matched against this rule's patterns —
        /// keeps matching cheap and reduces false positives from scrollback-adjacent text.
        let anchorLastNLines: Int
        /// `NSRegularExpression` (ICU) syntax.
        let patterns: [String]
        let confidence: String
        let sourceNotes: String?

        enum CodingKeys: String, CodingKey {
            case bucket
            case priority
            case anchorLastNLines = "anchor_last_n_lines"
            case patterns
            case confidence
            case sourceNotes = "source_notes"
        }
    }
}

extension AgentManifest {
    /// Result of a single `classify(text:)` call.
    struct ClassificationResult: Equatable, Sendable {
        let bucket: String
        let matchedPattern: String
    }

    /// Classifies `text` (typically the last ~60 lines of a terminal surface's visible screen +
    /// scrollback, per `AgentScreenDetectionEngine`'s Phase B sample) against this manifest's
    /// `states`, checked in descending `priority` order — first matching bucket wins. Each rule
    /// is matched only against the last `anchorLastNLines` lines of `text`, not the whole sample.
    ///
    /// Pure function: no engine/threading dependency, safe to call from any thread (the engine
    /// always calls this off-main — see AgentScreenDetectionEngine.swift).
    func classify(text: String) -> ClassificationResult? {
        guard !text.isEmpty else { return nil }
        let orderedStates = states.sorted { $0.priority > $1.priority }
        for stateRule in orderedStates {
            let anchoredText = Self.tailLines(text, maxLines: stateRule.anchorLastNLines)
            guard !anchoredText.isEmpty else { continue }
            let range = NSRange(anchoredText.startIndex..<anchoredText.endIndex, in: anchoredText)
            for pattern in stateRule.patterns {
                guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                if regex.firstMatch(in: anchoredText, options: [], range: range) != nil {
                    return ClassificationResult(bucket: stateRule.bucket, matchedPattern: pattern)
                }
            }
        }
        return nil
    }

    private static func tailLines(_ text: String, maxLines: Int) -> String {
        guard maxLines > 0 else { return text }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > maxLines else { return text }
        return lines.suffix(maxLines).joined(separator: "\n")
    }
}

extension AgentActivityState {
    /// Maps a manifest's internal bucket name (`AgentManifest.StateRule.bucket`) to the 3-value
    /// wire state. "done" collapses to `.idle` — see docs/plans/screen-manifest-detection.md
    /// §1.2 for why a 4th wire state was rejected for v1 (hooks don't distinguish "just
    /// finished" from "idle" either, so this keeps both detection tiers reporting the same
    /// vocabulary). Returns `nil` for an unrecognized bucket string (e.g. a user-authored
    /// override manifest with a typo) so callers can skip the sample rather than crash/guess.
    init?(manifestBucket: String) {
        switch manifestBucket {
        case "working": self = .working
        case "blocked": self = .blocked
        case "idle", "done": self = .idle
        default: return nil
        }
    }
}
