import Foundation

/// Shared building blocks for constructing `ssh`/`scp` argument lists.
///
/// Consolidates the connection-policy flags (keepalive timeouts, the
/// `StrictHostKeyChecking` default, the `BatchMode`/`ControlMaster` pairing) and the
/// `-o key=value` option-parsing helpers that were previously copy-pasted across
/// `WorkspaceRemoteSession.swift`, `WorkspaceRemoteDaemon.swift`, and
/// `TerminalSSHSessionDetector.swift`. Each call site still assembles its own argument
/// list (they differ in scp/ssh flags, jump-host/proxy handling, and port-flag
/// spelling), but the identical policy fragments now have one definition. Refs #92.
enum RemoteSSHConnectionPolicy {
    /// `-o ConnectTimeout=6 -o ServerAliveInterval=20 -o ServerAliveCountMax=2`
    static let keepaliveArguments: [String] = [
        "-o", "ConnectTimeout=6",
        "-o", "ServerAliveInterval=20",
        "-o", "ServerAliveCountMax=2",
    ]

    /// `-o BatchMode=yes -o ControlMaster=no`, for non-interactive/background invocations.
    static let batchModeArguments: [String] = [
        "-o", "BatchMode=yes",
        "-o", "ControlMaster=no",
    ]

    /// `-o StrictHostKeyChecking=accept-new`, appended unless the caller's own `-o`
    /// options already set `StrictHostKeyChecking` explicitly.
    static func strictHostKeyCheckingArguments(unlessSetIn options: [String]) -> [String] {
        hasOptionKey(options, key: "StrictHostKeyChecking") ? [] : ["-o", "StrictHostKeyChecking=accept-new"]
    }

    static func hasOptionKey(_ options: [String], key: String) -> Bool {
        let loweredKey = key.lowercased()
        return options.contains { optionKey($0) == loweredKey }
    }

    static func normalizedOptions(_ options: [String]) -> [String] {
        options.compactMap { option in
            let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return trimmed
        }
    }

    private static let backgroundExcludedOptionKeys: Set<String> = [
        "controlmaster",
        "controlpersist",
    ]

    /// Strips `ControlMaster`/`ControlPersist` so a batch invocation can't negotiate (or
    /// collide with) an interactive control-master.
    static func backgroundOptions(_ options: [String]) -> [String] {
        normalizedOptions(options).filter { option in
            guard let key = optionKey(option) else { return false }
            return !backgroundExcludedOptionKeys.contains(key)
        }
    }

    /// Looks up the value of a named `-o key=value` option within a list of raw options.
    static func optionValue(named key: String, in options: [String]) -> String? {
        let loweredKey = key.lowercased()
        for option in normalizedOptions(options) {
            let parts = option.split(
                maxSplits: 1,
                omittingEmptySubsequences: true,
                whereSeparator: { $0 == "=" || $0.isWhitespace }
            )
            guard parts.count == 2, parts[0].lowercased() == loweredKey else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        return nil
    }

    static func optionKey(_ option: String) -> String? {
        let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
            .split(whereSeparator: { $0 == "=" || $0.isWhitespace })
            .first
            .map(String.init)?
            .lowercased()
    }

    /// POSIX single-quote a string for interpolation into a `sh -c '...'` command.
    static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
