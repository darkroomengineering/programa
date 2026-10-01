// Screen-manifest agent detection (docs/plans/screen-manifest-detection.md): v2 socket handlers
// backing the `programa agent-detection` CLI command (`list`/`scaffold`/`test`). `scaffold`
// itself is generated entirely client-side in CLI/programa.swift (it only needs a screen read,
// via `surface.read_text`, plus local file I/O -- no app state) so it has no handler here.
//
// `v2AgentDetectionClassify` mirrors `AgentScreenDetectionEngine`'s Phase A (recognize.screen_patterns)
// -> Phase B (classify(text:)) shape as a single-shot, on-demand call, without touching that
// engine's live sampling/hysteresis loop -- see that file's header. This keeps `agent-detection
// test` a faithful "what would the real detector see right now" check.
import Foundation

extension TerminalController {
    // MARK: - V2 Agent Detection Methods

    nonisolated func v2AgentDetectionList(params: [String: Any]) -> V2CallResult {
        // Re-read from disk so a manifest just written by `agent-detection scaffold` shows up
        // without relaunching the app.
        AgentManifestLoader.shared.reloadFromDisk()
        let entries = AgentManifestLoader.shared.allManifestEntries()
            .sorted { $0.manifest.agent < $1.manifest.agent }
        let payloads: [[String: Any]] = entries.map { entry in
            // A user override fully replaces the bundled manifest for the same agent id (see
            // AgentManifestLoader's header) -- `shadows_bundled` flags that case so `list` (and
            // `agent-detection scaffold`'s bundled-id guard) can warn about it instead of the
            // shadowing being invisible.
            let shadowsBundled = entry.source == .override
                && AgentManifestLoader.bundledAgentIds.contains(entry.manifest.agent)
            let states: [[String: Any]] = entry.manifest.states.map { state in
                [
                    "bucket": state.bucket,
                    "priority": state.priority,
                    "anchor_last_n_lines": state.anchorLastNLines,
                    "patterns": state.patterns,
                    "confidence": state.confidence,
                    "source_notes": v2OrNull(state.sourceNotes)
                ]
            }
            return [
                "agent": entry.manifest.agent,
                "display_name": entry.manifest.displayName,
                "source": entry.source.rawValue,
                "process_names": entry.manifest.recognize.processNames,
                "shadows_bundled": shadowsBundled,
                // Full state rules (including patterns), so `agent-detection scaffold --force`
                // on a bundled agent id can seed the new file from what's currently loaded
                // instead of starting from a blank/inert manifest.
                "states": states
            ]
        }
        let rejected: [[String: Any]] = AgentManifestLoader.shared.rejectedManifests().map { item in
            [
                "agent": item.agent,
                "path": item.path,
                "reason": "invalid patterns: " + item.invalidPatterns.joined(separator: ", ")
            ]
        }
        return .ok(["manifests": payloads, "rejected": rejected])
    }

    nonisolated func v2AgentDetectionClassify(params: [String: Any]) -> V2CallResult {
        // Same reason as `v2AgentDetectionList`: `test` exists to check patterns you just
        // edited, so it must read the file as it is on disk right now.
        AgentManifestLoader.shared.reloadFromDisk()
        let readResult = v2MainSync {
            v2SurfaceReadText(params: params)
        }
        let textPayload: [String: Any]
        switch readResult {
        case .ok(let value):
            guard let dict = value as? [String: Any] else {
                return .err(code: "internal_error", message: "Unexpected read-screen result shape", data: nil)
            }
            textPayload = dict
        case .err(let code, let message, let data):
            return .err(code: code, message: message, data: data)
        }

        let text = (textPayload["text"] as? String) ?? ""
        let requestedAgent = v2String(params, "agent")

        var resolvedManifest: AgentManifest?
        var recognizedVia: String?

        if let requestedAgent {
            guard let manifest = AgentManifestLoader.shared.manifest(forAgent: requestedAgent) else {
                return .err(code: "not_found", message: "No manifest loaded for agent '\(requestedAgent)'", data: nil)
            }
            resolvedManifest = manifest
            recognizedVia = "explicit"
        } else if !text.isEmpty {
            for manifest in AgentManifestLoader.shared.allManifests() {
                let matched = manifest.recognize.screenPatterns.contains { pattern in
                    guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
                    let range = NSRange(text.startIndex..<text.endIndex, in: text)
                    return regex.firstMatch(in: text, options: [], range: range) != nil
                }
                if matched {
                    resolvedManifest = manifest
                    recognizedVia = "screen_pattern"
                    break
                }
            }
        }

        var result: [String: Any] = [
            "requested_agent": v2OrNull(requestedAgent),
            "recognized_via": v2OrNull(recognizedVia),
            "agent": NSNull(),
            "display_name": NSNull(),
            "bucket": NSNull(),
            "confidence": NSNull(),
            "matched_pattern": NSNull()
        ]
        if let workspaceId = textPayload["workspace_id"] {
            result["workspace_id"] = workspaceId
            result["workspace_ref"] = textPayload["workspace_ref"] ?? NSNull()
        }
        if let surfaceId = textPayload["surface_id"] {
            result["surface_id"] = surfaceId
            result["surface_ref"] = textPayload["surface_ref"] ?? NSNull()
        }

        guard let manifest = resolvedManifest else {
            return .ok(result)
        }
        result["agent"] = manifest.agent
        result["display_name"] = manifest.displayName

        guard let classification = manifest.classify(text: text) else {
            return .ok(result)
        }
        result["bucket"] = classification.bucket
        result["matched_pattern"] = classification.matchedPattern
        if let matchingState = manifest.states.first(where: {
            $0.bucket == classification.bucket && $0.patterns.contains(classification.matchedPattern)
        }) {
            result["confidence"] = matchingState.confidence
        }
        return .ok(result)
    }
}
