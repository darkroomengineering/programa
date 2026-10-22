import Foundation

/// Plans registering the bundled `programa-mcp` server in OpenCode's global `opencode.json`
/// under `mcp.programa` (https://opencode.ai/docs/mcp-servers/), the file-based counterpart of
/// `CodexMCPRegistrationPlan`. Pure so the decision table can be exercised without OpenCode.
struct OpenCodeMCPRegistrationPlan: Equatable {
    static let serverName = CodexMCPRegistrationPlan.serverName
    static let binaryName = CodexMCPRegistrationPlan.binaryName

    /// The full `opencode.json` text to write after consent, or nil when nothing changes.
    let newConfig: String?
    /// One line explaining a skipped or manual change, for the install preview.
    let note: String?

    static func entry(_ mcpBinary: String) -> [String: Any] {
        ["type": "local", "command": [mcpBinary], "enabled": true]
    }

    /// Only an enabled local entry that runs a bare `programa-mcp`, with no other settings,
    /// counts as ours; anything else is the user's and is never replaced or removed.
    static func isOurs(_ value: Any) -> Bool {
        guard let entry = value as? [String: Any],
              entry["type"] as? String == "local",
              let command = entry["command"] as? [String], command.count == 1,
              (command[0] as NSString).lastPathComponent == binaryName,
              Set(entry.keys).isSubset(of: ["type", "command", "enabled"]) else { return false }
        return entry["enabled"] == nil || entry["enabled"] as? Bool == true
    }

    /// `existingConfig` is the text of `configPath` (nil when the file does not exist) and
    /// `existingJSONC` the text of `opencode.jsonc` beside it. A JSONC file or an
    /// `opencode.json` that is not strict JSON is never rewritten, since a round trip would
    /// drop its comments; the note tells the user what to change by hand instead.
    static func build(
        install: Bool,
        configPath: String,
        existingConfig: String?,
        jsoncPath: String,
        existingJSONC: String?,
        mcpBinary: String?
    ) -> OpenCodeMCPRegistrationPlan {
        let none = OpenCodeMCPRegistrationPlan(newConfig: nil, note: nil)
        if install, mcpBinary == nil {
            return OpenCodeMCPRegistrationPlan(newConfig: nil, note: "\(binaryName) not found next to this CLI; skipping the OpenCode MCP server.")
        }
        func manual(_ reason: String, text: String) -> OpenCodeMCPRegistrationPlan {
            if let mcpBinary, install {
                let shown = serialize([serverName: entry(mcpBinary)], pretty: false)
                return OpenCodeMCPRegistrationPlan(newConfig: nil, note: "\(reason); add \(shown.dropFirst().dropLast()) under \"mcp\" yourself.")
            }
            guard text.contains(binaryName) else { return none }
            return OpenCodeMCPRegistrationPlan(newConfig: nil, note: "\(reason); remove the \"\(serverName)\" entry under \"mcp\" yourself.")
        }

        guard let existingConfig else {
            if let existingJSONC {
                return manual("\(jsoncPath) is JSONC, which Programa does not rewrite", text: existingJSONC)
            }
            guard install, let mcpBinary else { return none }
            return OpenCodeMCPRegistrationPlan(newConfig: serialize(["mcp": [serverName: entry(mcpBinary)]]), note: nil)
        }

        var root: [String: Any] = [:]
        if !existingConfig.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let data = existingConfig.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return manual("\(configPath) is not plain JSON (it may contain comments), so Programa leaves it unchanged", text: existingConfig)
            }
            root = parsed
        }
        if let mcp = root["mcp"], !(mcp is [String: Any]) {
            return manual("\(configPath) has an \"mcp\" value that is not an object", text: existingConfig)
        }
        var servers = root["mcp"] as? [String: Any] ?? [:]
        let registered = servers[serverName]
        let registeredIsOurs = registered.map(isOurs) ?? false

        if install {
            guard let mcpBinary else { return none }
            if registered != nil, !registeredIsOurs {
                return OpenCodeMCPRegistrationPlan(
                    newConfig: nil,
                    note: "OpenCode already has an MCP server named \(serverName) in \(configPath); leaving it unchanged."
                )
            }
            if registeredIsOurs, (registered as? [String: Any])?["command"] as? [String] == [mcpBinary] {
                return none
            }
            servers[serverName] = entry(mcpBinary)
        } else {
            guard registeredIsOurs else { return none }
            servers[serverName] = nil
        }
        root["mcp"] = servers.isEmpty ? nil : servers
        return OpenCodeMCPRegistrationPlan(newConfig: serialize(root), note: nil)
    }

    private static func serialize(_ object: [String: Any], pretty: Bool = true) -> String {
        var options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
        if pretty { options.insert(.prettyPrinted) }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: options),
              let text = String(data: data, encoding: .utf8) else { return "{}\n" }
        return pretty ? text + "\n" : text
    }
}

extension ProgramaCLI {
    static func openCodeConfigFilePath() -> String {
        (openCodeConfigDir() as NSString).appendingPathComponent("opencode.json")
    }

    func openCodeMCPRegistrationPlan(install: Bool) -> OpenCodeMCPRegistrationPlan {
        let configPath = Self.openCodeConfigFilePath()
        let jsoncPath = (Self.openCodeConfigDir() as NSString).appendingPathComponent("opencode.jsonc")
        // A file that exists but cannot be read must not look missing, or install would overwrite it.
        var existing: [String: String] = [:]
        for path in [configPath, jsoncPath] where FileManager.default.fileExists(atPath: path) {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
                return OpenCodeMCPRegistrationPlan(
                    newConfig: nil,
                    note: "\(path) could not be read as UTF-8 text, so Programa leaves the OpenCode MCP server unchanged."
                )
            }
            existing[path] = text
        }
        return OpenCodeMCPRegistrationPlan.build(
            install: install,
            configPath: configPath,
            existingConfig: existing[configPath],
            jsoncPath: jsoncPath,
            existingJSONC: existing[jsoncPath],
            mcpBinary: bundledMCPBinaryPath()
        )
    }

    func printOpenCodeMCPPreview(_ plan: OpenCodeMCPRegistrationPlan) {
        guard plan.newConfig != nil || plan.note != nil else { return }
        print("  OpenCode MCP server:")
        if let newConfig = plan.newConfig {
            let path = Self.openCodeConfigFilePath()
            print("    \(path):")
            printSimpleDiff(old: (try? String(contentsOfFile: path, encoding: .utf8)) ?? "", new: newConfig)
        }
        if let note = plan.note { print("    \(note)") }
        print("")
    }

    /// Runs after the plugin and skill are written, so a failure here never leaves those
    /// half-written; it only fails the command.
    func applyOpenCodeMCPPlan(_ plan: OpenCodeMCPRegistrationPlan) throws {
        guard let newConfig = plan.newConfig else { return }
        try FileManager.default.createDirectory(atPath: Self.openCodeConfigDir(), withIntermediateDirectories: true, attributes: nil)
        try newConfig.write(toFile: Self.openCodeConfigFilePath(), atomically: true, encoding: .utf8)
    }
}
