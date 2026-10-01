import Foundation

extension ProgramaCLI {
    // MARK: - Agent detection commands (docs/agent-detection-manifests.md)

    func runAgentDetectionCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowId: String?
    ) throws {
        var positional = commandArgs
        guard let subcommandRaw = positional.first else {
            throw CLIError(message: "agent-detection requires a subcommand: list, scaffold, test")
        }
        positional.removeFirst()

        switch subcommandRaw.lowercased() {
        case "list":
            try runAgentDetectionList(args: positional, client: client, jsonOutput: jsonOutput, idFormat: idFormat)
        case "scaffold":
            try runAgentDetectionScaffold(args: positional, client: client, jsonOutput: jsonOutput, windowId: windowId)
        case "test":
            try runAgentDetectionTest(args: positional, client: client, jsonOutput: jsonOutput, idFormat: idFormat, windowId: windowId)
        default:
            throw CLIError(message: "agent-detection: unknown subcommand '\(subcommandRaw)' (expected list, scaffold, test)")
        }
    }

    private func runAgentDetectionList(
        args: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        if let unknown = args.first(where: { $0.hasPrefix("--") && $0 != "--json" }) {
            throw CLIError(message: "agent-detection list: unknown flag '\(unknown)'")
        }

        let payload = try client.sendV2(method: V2MethodNames.agentDetectionList)
        if jsonOutput {
            print(jsonString(payload))
            return
        }

        let manifests = payload["manifests"] as? [[String: Any]] ?? []
        guard !manifests.isEmpty else {
            print("No agent-detection manifests loaded")
            return
        }
        for entry in manifests {
            let agent = entry["agent"] as? String ?? "?"
            let displayName = entry["display_name"] as? String ?? agent
            let source = entry["source"] as? String ?? "?"
            let processNames = (entry["process_names"] as? [String] ?? []).joined(separator: ", ")
            let shadowsBundled = (entry["shadows_bundled"] as? Bool) ?? false
            var line = "\(agent)  (\(displayName), source=\(source), process_names=[\(processNames)])"
            if shadowsBundled {
                line += "  [shadows bundled manifest]"
            }
            print(line)
        }
    }

    /// Mirrors `AgentManifestLoader.bundledAgentIds`
    /// (Sources/AgentManifestLoader.swift:21-29) -- this CLI target can't import that type, so
    /// this is a manually-kept-in-sync copy, used only to gate `agent-detection scaffold`'s
    /// bundled-shadowing guard below.
    private static let agentDetectionBundledIds: Set<String> = [
        "claude-code", "codex", "gemini-cli", "opencode", "copilot-cli", "cursor-agent", "aider"
    ]

    private func runAgentDetectionScaffold(
        args: [String],
        client: SocketClient,
        jsonOutput: Bool,
        windowId: String?
    ) throws {
        let (wsArg, rem0) = parseOption(args, name: "--workspace")
        let (sfArg, rem1) = parseOption(rem0, name: "--surface")
        let force = hasFlag(rem1, name: "--force")
        var positional = rem1.filter { $0 != "--force" }

        guard let agentId = positional.first, !agentId.hasPrefix("--") else {
            throw CLIError(message: "agent-detection scaffold requires <agent-id>")
        }
        positional.removeFirst()
        if let unknown = positional.first(where: { $0.hasPrefix("--") }) {
            throw CLIError(message: "agent-detection scaffold: unknown flag '\(unknown)'")
        }
        guard isValidAgentDetectionId(agentId) else {
            throw CLIError(message: "agent-detection scaffold: <agent-id> must be lowercase letters, digits, and hyphens only")
        }

        let destinationDirectory = ("~/.config/programa/agent-detection" as NSString).expandingTildeInPath
        let destinationPath = (destinationDirectory as NSString).appendingPathComponent("\(agentId).json")

        // A user override at `destinationPath` fully replaces the bundled manifest for this
        // agent id (no field merge -- AgentManifestLoader.swift's header), and a freshly
        // scaffolded manifest starts with empty `patterns` (safe -- see
        // `agentDetectionScaffoldJSON`'s doc comment -- but inert). Scaffolding one of the seven
        // bundled ids without --force would therefore silently replace working screen-based
        // detection with a manifest that detects nothing at all. Refuse by default; --force
        // seeds the new file from the bundled manifest's own patterns instead of starting blank,
        // so forcing degrades to "edit a copy of what already worked."
        var seedStates: [[String: Any]]?
        if Self.agentDetectionBundledIds.contains(agentId) {
            guard force else {
                throw CLIError(message: """
                agent-detection scaffold: '\(agentId)' is one of programa's bundled agents. A user override at \(destinationPath) fully replaces its bundled manifest (no merge) -- and a freshly scaffolded manifest starts with empty patterns, so screen-based detection for '\(agentId)' would silently stop working until you fill them back in. Pass --force to proceed anyway; the bundled manifest's existing patterns will be seeded into the new file so you start from a working copy, not a blank one.
                """)
            }
            let listPayload = try client.sendV2(method: V2MethodNames.agentDetectionList)
            let manifests = listPayload["manifests"] as? [[String: Any]] ?? []
            if let match = manifests.first(where: { ($0["agent"] as? String) == agentId }) {
                seedStates = match["states"] as? [[String: Any]]
            }
        }

        let workspaceArg = wsArg ?? (windowId == nil ? ProcessInfo.processInfo.environment["PROGRAMA_WORKSPACE_ID"] : nil)

        var readParams: [String: Any] = [:]
        let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
        if let wsId { readParams["workspace_id"] = wsId }
        let sfId = try resolveCommandSurface(
            explicitSurface: sfArg, explicitWorkspace: wsArg,
            windowId: windowId, workspaceHandle: wsId, client: client
        )
        if let sfId { readParams["surface_id"] = sfId }

        // Capture the currently visible screen only (no --scrollback/--lines), same socket
        // method 'read-screen' calls, via the same client -- see CommandDescriptor(names:
        // ["read-screen"]) above.
        let readPayload = try client.sendV2(method: V2MethodNames.surfaceReadText, params: readParams)
        let capturedText = (readPayload["text"] as? String) ?? ""

        if !force, FileManager.default.fileExists(atPath: destinationPath) {
            throw CLIError(message: "agent-detection scaffold: \(destinationPath) already exists (use --force to overwrite)")
        }

        do {
            try FileManager.default.createDirectory(atPath: destinationDirectory, withIntermediateDirectories: true)
        } catch {
            throw CLIError(message: "agent-detection scaffold: failed to create \(destinationDirectory): \(error.localizedDescription)")
        }

        let manifestJSON = agentDetectionScaffoldJSON(agentId: agentId, capturedText: capturedText, seedStates: seedStates)
        do {
            try manifestJSON.write(toFile: destinationPath, atomically: true, encoding: .utf8)
        } catch {
            throw CLIError(message: "agent-detection scaffold: failed to write \(destinationPath): \(error.localizedDescription)")
        }

        if jsonOutput {
            print(jsonString(["path": destinationPath, "agent": agentId, "seeded_from_bundled": seedStates != nil]))
        } else {
            print("Wrote starter manifest: \(destinationPath)")
            if seedStates != nil {
                print("Seeded from the bundled '\(agentId)' manifest's existing patterns -- review them, they were verified against the bundled agent's UI, not necessarily yours.")
            }
            print("Next: review/fill in its \"patterns\" arrays, then run 'programa agent-detection test \(agentId)' to check them against the live screen.")
        }
    }

    private func runAgentDetectionTest(
        args: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowId: String?
    ) throws {
        let (wsArg, rem0) = parseOption(args, name: "--workspace")
        let (sfArg, rem1) = parseOption(rem0, name: "--surface")
        var positional = rem1

        var agentId: String?
        if let first = positional.first, !first.hasPrefix("--") {
            agentId = first
            positional.removeFirst()
        }
        if let unknown = positional.first {
            throw CLIError(message: "agent-detection test: unexpected arguments: \(unknown)")
        }

        let workspaceArg = wsArg ?? (windowId == nil ? ProcessInfo.processInfo.environment["PROGRAMA_WORKSPACE_ID"] : nil)

        var params: [String: Any] = [:]
        let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
        if let wsId { params["workspace_id"] = wsId }
        let sfId = try resolveCommandSurface(
            explicitSurface: sfArg, explicitWorkspace: wsArg,
            windowId: windowId, workspaceHandle: wsId, client: client
        )
        if let sfId { params["surface_id"] = sfId }
        if let agentId { params["agent"] = agentId }

        let payload = try client.sendV2(method: V2MethodNames.agentDetectionClassify, params: params)
        if jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
            return
        }

        guard let recognizedAgent = payload["agent"] as? String else {
            if let agentId {
                print("No manifest loaded for '\(agentId)'")
            } else {
                print("No loaded manifest recognized this screen")
            }
            return
        }
        let displayName = payload["display_name"] as? String ?? recognizedAgent
        guard let bucket = payload["bucket"] as? String else {
            print("\(recognizedAgent) (\(displayName)) recognized, but no state pattern matched the current screen")
            return
        }
        let confidence = payload["confidence"] as? String ?? "?"
        let matchedPattern = payload["matched_pattern"] as? String ?? "?"
        print("\(recognizedAgent) (\(displayName)): \(bucket)  [confidence=\(confidence), pattern=\(matchedPattern)]")
    }

    private func isValidAgentDetectionId(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "-" }
    }

    private func agentDetectionDisplayName(forAgentId agentId: String) -> String {
        agentId
            .split(separator: "-")
            .map { $0.isEmpty ? "" : $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    /// Wraps `value` as a single JSON string literal (quotes + escaping) via JSONSerialization,
    /// so arbitrary captured terminal text (quotes, backslashes, control characters, unicode) can
    /// be embedded into hand-assembled JSON safely, without a bespoke escaper.
    private func jsonEscapedString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value], options: [.withoutEscapingSlashes]),
              let arrayJSON = String(data: data, encoding: .utf8),
              arrayJSON.hasPrefix("["), arrayJSON.hasSuffix("]") else {
            return "\"\""
        }
        return String(arrayJSON.dropFirst().dropLast())
    }

    private func lastLines(_ text: String, maxLines: Int) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > maxLines else { return text }
        return lines.suffix(maxLines).joined(separator: "\n")
    }

    /// Encodes `values` as a compact JSON string array literal (e.g. `["a","b"]`) via
    /// `JSONSerialization`, so a bundled manifest's existing `patterns` (fetched over the wire
    /// from `agent.detection.list`) can be re-embedded into scaffolded JSON verbatim and safely,
    /// without a bespoke escaper.
    private func jsonEncodedStringArray(_ values: [String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: values, options: [.withoutEscapingSlashes]),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }

    private func agentDetectionStateBlockLiteral(
        bucket: String,
        priority: Int,
        anchorLines: Int,
        patternsJSON: String,
        confidence: String,
        notes: String
    ) -> String {
        "    {\n"
            + "      \"bucket\": \(jsonEscapedString(bucket)),\n"
            + "      \"priority\": \(priority),\n"
            + "      \"anchor_last_n_lines\": \(anchorLines),\n"
            + "      \"patterns\": \(patternsJSON),\n"
            + "      \"confidence\": \(jsonEscapedString(confidence)),\n"
            + "      \"source_notes\": \(jsonEscapedString(notes))\n"
            + "    }"
    }

    /// Builds a starter manifest matching `AgentManifest`'s schema (Sources/AgentManifest.swift)
    /// -- this CLI target cannot import that type directly, so the shape is mirrored by hand.
    ///
    /// When `seedStates` is nil (the common case: scaffolding an agent with no bundled
    /// manifest), all three `states[].patterns` are left empty -- confirmed safe:
    /// `AgentManifest.classify(text:)` iterates a state's patterns with a `for` loop, so an
    /// empty array matches nothing, never everything -- with a TODO in `source_notes` plus the
    /// captured screen as reference text, since JSON has no comments.
    ///
    /// When `seedStates` is non-nil (forced scaffold of a bundled agent id -- see
    /// `runAgentDetectionScaffold`'s bundled-shadowing guard), those states' own patterns are
    /// reused verbatim instead, so the result is an editable copy of a working manifest rather
    /// than a blank one.
    private func agentDetectionScaffoldJSON(
        agentId: String,
        capturedText: String,
        seedStates: [[String: Any]]?
    ) -> String {
        let displayName = agentDetectionDisplayName(forAgentId: agentId)
        let truncated = lastLines(capturedText, maxLines: 30)
        let screenReference: String
        if truncated.isEmpty {
            screenReference = "No screen text was captured (surface appeared empty at scaffold time)."
        } else {
            let lineCount = truncated.split(separator: "\n", omittingEmptySubsequences: false).count
            screenReference = "Captured screen (last \(lineCount) lines) for reference, delete once patterns are reviewed:\n\(truncated)"
        }

        let stateBlocks: [String]
        if let seedStates, !seedStates.isEmpty {
            stateBlocks = seedStates.map { state in
                let bucket = state["bucket"] as? String ?? "idle"
                let priority = (state["priority"] as? Int) ?? ((state["priority"] as? NSNumber)?.intValue ?? 0)
                let anchorLines = (state["anchor_last_n_lines"] as? Int) ?? ((state["anchor_last_n_lines"] as? NSNumber)?.intValue ?? 6)
                let patterns = (state["patterns"] as? [String]) ?? []
                let confidence = state["confidence"] as? String ?? "low"
                let notes = "SEEDED from the bundled '\(agentId)' manifest (forced override) -- "
                    + "review these, they were verified against the bundled agent's UI, not "
                    + "necessarily yours. \(screenReference)"
                return agentDetectionStateBlockLiteral(
                    bucket: bucket,
                    priority: priority,
                    anchorLines: anchorLines,
                    patternsJSON: jsonEncodedStringArray(patterns),
                    confidence: confidence,
                    notes: notes
                )
            }
        } else {
            let templates: [(bucket: String, priority: Int, anchorLines: Int, hint: String)] = [
                (
                    "blocked", 100, 12,
                    "Add regex patterns that appear when \(displayName) is waiting on you -- a y/n confirmation, a permission prompt, etc."
                ),
                (
                    "working", 50, 6,
                    "Add regex patterns that appear while \(displayName) is actively working -- a spinner, \"Thinking\", token counters, etc."
                ),
                (
                    "idle", 0, 4,
                    "Add regex patterns that match \(displayName)'s prompt when it's idle and ready for the next instruction."
                )
            ]
            stateBlocks = templates.map { template in
                let notes = "TODO: \(template.hint) Patterns are intentionally empty -- an empty "
                    + "list matches nothing (never everything; see AgentManifest.classify). \(screenReference)"
                return agentDetectionStateBlockLiteral(
                    bucket: template.bucket,
                    priority: template.priority,
                    anchorLines: template.anchorLines,
                    patternsJSON: "[]",
                    confidence: "low",
                    notes: notes
                )
            }
        }

        let states = stateBlocks.joined(separator: ",\n")

        return """
        {
          "version": 1,
          "agent": \(jsonEscapedString(agentId)),
          "display_name": \(jsonEscapedString(displayName)),
          "recognize": {
            "process_names": [\(jsonEscapedString(agentId))],
            "screen_patterns": []
          },
          "states": [
        \(states)
          ]
        }
        """
    }
}
