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

    /// Rewrites a destination for `scp`'s combined `host:path` argument syntax by
    /// bracketing a bare IPv6 literal host (`user@2001:db8::1` -> `user@[2001:db8::1]`).
    ///
    /// `ssh` takes the destination as its own argument, so a bare IPv6 literal like
    /// `2001:db8::1` is unambiguous there (see `CLI+SSH.swift`'s `normalizeSSHDestination`,
    /// which instead *strips* brackets for that call). `scp` glues the destination and the
    /// remote path together with a colon (`host:path`), so an un-bracketed IPv6 host's own
    /// colons collide with that separator and scp misparses the path. Only bare/unbracketed
    /// IPv6 hosts are rewritten — `user@host`, hostnames, IPv4 literals, and already-bracketed
    /// hosts pass through unchanged (#4948 follow-up: the ssh-only fix in `CLI+SSH.swift`
    /// didn't cover our scp call sites).
    static func scpRemoteDestination(_ destination: String) -> String {
        let trimmedDestination = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDestination.isEmpty else { return destination }

        let parts = trimmedDestination.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        let userPart: String?
        let hostPart: String
        if parts.count == 2 {
            userPart = String(parts[0])
            hostPart = String(parts[1])
        } else {
            userPart = nil
            hostPart = trimmedDestination
        }

        guard shouldBracketIPv6LiteralForSCP(hostPart) else {
            return trimmedDestination
        }

        let bracketedHost = "[\(hostPart)]"
        if let userPart {
            return "\(userPart)@\(bracketedHost)"
        }
        return bracketedHost
    }

    private static func shouldBracketIPv6LiteralForSCP(_ host: String) -> Bool {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmedHost.isEmpty &&
            trimmedHost.contains(":") &&
            !trimmedHost.hasPrefix("[") &&
            !trimmedHost.hasSuffix("]")
    }
}
