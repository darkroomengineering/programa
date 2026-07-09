// Extracted from WorkspaceRemoteSession.swift (nuclear-review #98): debug logging, remote shell script builders, and process/PID utilities.

import Foundation
import SwiftUI
import AppKit
import Bonsplit
import Combine
import CryptoKit
import Darwin
import Network
import CoreText

extension WorkspaceRemoteSessionController {
    func debugLog(_ message: @autoclosure () -> String) {
#if DEBUG
        dlog(message())
#endif
    }

    func debugConfigSummary() -> String {
        let controlPath = Self.debugSSHOptionValue(named: "ControlPath", in: configuration.sshOptions) ?? "nil"
        return
            "target=\(configuration.displayTarget) port=\(configuration.port.map(String.init) ?? "nil") " +
            "relayPort=\(configuration.relayPort.map(String.init) ?? "nil") " +
            "localSocket=\(configuration.localSocketPath ?? "nil") " +
            "controlPath=\(controlPath)"
    }

    func debugShellCommand(executable: String, arguments: [String]) -> String {
        ([URL(fileURLWithPath: executable).lastPathComponent] + arguments)
            .map(RemoteSSHConnectionPolicy.shellSingleQuoted)
            .joined(separator: " ")
    }

    static func debugSSHOptionValue(named key: String, in options: [String]) -> String? {
        let loweredKey = key.lowercased()
        for option in options {
            let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2,
               parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == loweredKey {
                return parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    static func debugLogSnippet(_ text: String, limit: Int = 160) -> String {
        let normalized = text
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return "\"\"" }
        if normalized.count <= limit {
            return normalized
        }
        return String(normalized.prefix(limit)) + "..."
    }

    static func remoteCLIWrapperScript() -> String {
        """
        #!/bin/sh
        set -eu

        daemon="$HOME/.programa/bin/programad-remote-current"
        socket_path="${PROGRAMA_SOCKET_PATH:-}"
        if [ -z "$socket_path" ] && [ -r "$HOME/.programa/socket_addr" ]; then
          socket_path="$(tr -d '\\r\\n' < "$HOME/.programa/socket_addr")"
        fi

        if [ -n "$socket_path" ] && [ "${socket_path#/}" = "$socket_path" ] && [ "${socket_path#*:}" != "$socket_path" ]; then
          relay_port="${socket_path##*:}"
          relay_map="$HOME/.programa/relay/${relay_port}.daemon_path"
          if [ -r "$relay_map" ]; then
            mapped_daemon="$(tr -d '\\r\\n' < "$relay_map")"
            if [ -n "$mapped_daemon" ] && [ -x "$mapped_daemon" ]; then
              daemon="$mapped_daemon"
            fi
          fi
        fi

        exec "$daemon" "$@"
        """
    }

    static func remoteCLIWrapperInstallScript(daemonRemotePath: String) -> String {
        let trimmedRemotePath = daemonRemotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        mkdir -p "$HOME/.programa/bin" "$HOME/.programa/relay"
        ln -sf "$HOME/\(trimmedRemotePath)" "$HOME/.programa/bin/programad-remote-current"
        wrapper_tmp="$HOME/.programa/bin/.programa-wrapper.tmp.$$"
        cat > "$wrapper_tmp" <<'CMUXWRAPPER'
        \(remoteCLIWrapperScript())
        CMUXWRAPPER
        chmod 755 "$wrapper_tmp"
        mv -f "$wrapper_tmp" "$HOME/.programa/bin/programa"
        """
    }

    static func remoteRelayMetadataInstallScript(
        daemonRemotePath: String,
        relayPort: Int,
        relayID: String,
        relayToken: String
    ) -> String {
        let trimmedRemotePath = daemonRemotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let authPayload = """
        {"relay_id":"\(relayID)","relay_token":"\(relayToken)"}
        """
        return """
        umask 077
        mkdir -p "$HOME/.programa" "$HOME/.programa/relay"
        chmod 700 "$HOME/.programa/relay"
        \(remoteCLIWrapperInstallScript(daemonRemotePath: trimmedRemotePath))
        printf '%s' "$HOME/\(trimmedRemotePath)" > "$HOME/.programa/relay/\(relayPort).daemon_path"
        cat > "$HOME/.programa/relay/\(relayPort).auth" <<'PROGRAMARELAYAUTH'
        \(authPayload)
        PROGRAMARELAYAUTH
        chmod 600 "$HOME/.programa/relay/\(relayPort).auth"
        printf '%s' '127.0.0.1:\(relayPort)' > "$HOME/.programa/socket_addr"
        """
    }

    static func mapUnameOS(_ raw: String) -> String? {
        switch raw.lowercased() {
        case "linux":
            return "linux"
        case "darwin":
            return "darwin"
        case "freebsd":
            return "freebsd"
        default:
            return nil
        }
    }

    static func mapUnameArch(_ raw: String) -> String? {
        switch raw.lowercased() {
        case "x86_64", "amd64":
            return "amd64"
        case "aarch64", "arm64":
            return "arm64"
        case "armv7l":
            return "arm"
        default:
            return nil
        }
    }

    static func remoteDaemonVersion() -> String {
        let bundleVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let baseVersion = (bundleVersion?.isEmpty == false) ? bundleVersion! : "dev"
        guard allowLocalDaemonBuildFallback(),
              let sourceFingerprint = remoteDaemonSourceFingerprint(),
              !sourceFingerprint.isEmpty else {
            return baseVersion
        }
        return "\(baseVersion)-dev-\(sourceFingerprint)"
    }

    static let cachedRemoteDaemonSourceFingerprint: String? = computeRemoteDaemonSourceFingerprint()

    static func remoteDaemonSourceFingerprint() -> String? {
        cachedRemoteDaemonSourceFingerprint
    }

    static func computeRemoteDaemonSourceFingerprint(fileManager: FileManager = .default) -> String? {
        guard let repoRoot = findRepoRoot() else { return nil }
        let daemonRoot = repoRoot.appendingPathComponent("daemon/remote", isDirectory: true)
        guard let enumerator = fileManager.enumerator(
            at: daemonRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        var relativePaths: [String] = []
        for case let fileURL as URL in enumerator {
            guard let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                  resourceValues.isRegularFile == true else {
                continue
            }

            let relativePath = fileURL.path.replacingOccurrences(of: daemonRoot.path + "/", with: "")
            if relativePath == "go.mod" || relativePath == "go.sum" || relativePath.hasSuffix(".go") {
                relativePaths.append(relativePath)
            }
        }

        guard !relativePaths.isEmpty else { return nil }

        let digest = SHA256.hash(data: relativePaths.sorted().reduce(into: Data()) { partialResult, relativePath in
            let fileURL = daemonRoot.appendingPathComponent(relativePath, isDirectory: false)
            guard let fileData = try? Data(contentsOf: fileURL) else { return }
            partialResult.append(Data(relativePath.utf8))
            partialResult.append(0)
            partialResult.append(fileData)
            partialResult.append(0)
        })
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(12))
    }

    static func remoteDaemonPath(version: String, goOS: String, goArch: String) -> String {
        ".programa/bin/programad-remote/\(version)/\(goOS)-\(goArch)/programad-remote"
    }

    static func orphanedCMUXRemoteSSHPIDs(
        psOutput: String,
        destination: String,
        relayPort: Int? = nil
    ) -> [Int] {
        let trimmedDestination = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDestination.isEmpty else { return [] }

        return psOutput
            .split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { line -> Int? in
                guard let parsed = parsePSLine(line) else { return nil }
                guard parsed.ppid == 1 else { return nil }
                guard isOrphanedCMUXRemoteSSHCommand(
                    parsed.command,
                    destination: trimmedDestination,
                    relayPort: relayPort
                ) else {
                    return nil
                }
                return parsed.pid
            }
            .sorted()
    }

    static func killOrphanedRemoteSSHProcesses(destination: String, relayPort: Int? = nil) {
        guard let output = captureCommandStandardOutput(
            executablePath: "/bin/ps",
            arguments: ["-axo", "pid=,ppid=,command="]
        ) else {
            return
        }

        for pid in orphanedCMUXRemoteSSHPIDs(
            psOutput: output,
            destination: destination,
            relayPort: relayPort
        ) {
            _ = Darwin.kill(pid_t(pid), SIGTERM)
        }
    }

    static func captureCommandStandardOutput(
        executablePath: String,
        arguments: [String]
    ) -> String? {
        let process = Process()
        let stdoutPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let output = String(data: outputData, encoding: .utf8),
                  !output.isEmpty else {
                return nil
            }
            return output
        } catch {
            // Best effort cleanup only.
            return nil
        }
    }

    static func parsePSLine(_ line: Substring) -> (pid: Int, ppid: Int, command: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let scanner = Scanner(string: trimmed)
        var pidValue: Int = 0
        var ppidValue: Int = 0
        guard scanner.scanInt(&pidValue), scanner.scanInt(&ppidValue) else {
            return nil
        }

        let commandStart = scanner.currentIndex
        let command = String(trimmed[commandStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return nil }
        return (pidValue, ppidValue, command)
    }

    static func isOrphanedCMUXRemoteSSHCommand(
        _ command: String,
        destination: String,
        relayPort: Int?
    ) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard trimmed.hasPrefix("/usr/bin/ssh ") || trimmed.hasPrefix("ssh ") else { return false }
        guard commandContainsDestination(trimmed, destination: destination) else { return false }

        if let relayPort {
            return trimmed.contains(" -N ")
                && trimmed.contains(" -R 127.0.0.1:\(relayPort):127.0.0.1:")
        }

        if trimmed.contains(" -N ") && trimmed.contains(" -R 127.0.0.1:") {
            return true
        }
        if trimmed.contains("programad-remote") && trimmed.contains(" serve --stdio") {
            return true
        }
        return false
    }

    static func commandContainsDestination(_ command: String, destination: String) -> Bool {
        guard !destination.isEmpty else { return false }
        let escaped = NSRegularExpression.escapedPattern(for: destination)
        guard let regex = try? NSRegularExpression(
            pattern: "(^|[\\s'\\\"])\(escaped)($|[\\s'\\\"])",
            options: []
        ) else {
            return command.contains(destination)
        }
        let range = NSRange(command.startIndex..<command.endIndex, in: command)
        return regex.firstMatch(in: command, options: [], range: range) != nil
    }

    static func executableSearchPaths(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        pathHelperOutput: String? = nil
    ) -> [String] {
        var ordered: [String] = []
        var seen: Set<String> = []

        func appendSearchPath(_ rawPath: String?) {
            guard let rawPath else { return }
            let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            guard seen.insert(trimmed).inserted else { return }
            ordered.append(trimmed)
        }

        if let path = environment["PATH"] {
            for component in path.split(separator: ":") {
                appendSearchPath(String(component))
            }
        }

        if let home = environment["HOME"], !home.isEmpty {
            appendSearchPath((home as NSString).appendingPathComponent(".local/bin"))
            appendSearchPath((home as NSString).appendingPathComponent("go/bin"))
            appendSearchPath((home as NSString).appendingPathComponent("bin"))
        }

        let helperOutput = pathHelperOutput ?? pathHelperShellOutput()
        for component in parsePathHelperPaths(helperOutput) {
            appendSearchPath(component)
        }

        for component in [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ] {
            appendSearchPath(component)
        }

        return ordered
    }

    static func parsePathHelperPaths(_ output: String) -> [String] {
        for fragment in output.split(whereSeparator: { $0 == "\n" || $0 == ";" }) {
            let trimmed = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("PATH=\"") else { continue }
            let suffix = trimmed.dropFirst("PATH=\"".count)
            guard let closingQuote = suffix.firstIndex(of: "\"") else { return [] }
            return suffix[..<closingQuote]
                .split(separator: ":")
                .map(String.init)
        }
        return []
    }

    static func pathHelperShellOutput() -> String {
        let executable = "/usr/libexec/path_helper"
        guard FileManager.default.isExecutableFile(atPath: executable) else { return "" }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-s"]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            return ""
        }

        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return "" }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func which(_ executable: String) -> String? {
        for component in executableSearchPaths() {
            let candidate = (component as NSString).appendingPathComponent(executable)
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    static func findRepoRoot() -> URL? {
        var candidates: [URL] = []
        let compileTimeRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // repo root
        candidates.append(compileTimeRoot)
        let environment = ProcessInfo.processInfo.environment
        if let envRoot = environment["PROGRAMA_REMOTE_DAEMON_SOURCE_ROOT"],
           !envRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            candidates.append(URL(fileURLWithPath: envRoot, isDirectory: true))
        }
        if let envRoot = environment["PROGRAMATERM_REPO_ROOT"],
           !envRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            candidates.append(URL(fileURLWithPath: envRoot, isDirectory: true))
        }
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true))
        if let executable = Bundle.main.executableURL?.deletingLastPathComponent() {
            candidates.append(executable)
            candidates.append(executable.deletingLastPathComponent())
            candidates.append(executable.deletingLastPathComponent().deletingLastPathComponent())
        }

        let fm = FileManager.default
        for base in candidates {
            var cursor = base.standardizedFileURL
            for _ in 0..<10 {
                let marker = cursor.appendingPathComponent("daemon/remote/go.mod").path
                if fm.fileExists(atPath: marker) {
                    return cursor
                }
                let parent = cursor.deletingLastPathComponent()
                if parent.path == cursor.path {
                    break
                }
                cursor = parent
            }
        }
        return nil
    }

    static func bestErrorLine(stderr: String, stdout: String = "") -> String? {
        if let stderrLine = meaningfulErrorLine(in: stderr) {
            return stderrLine
        }
        if let stdoutLine = meaningfulErrorLine(in: stdout) {
            return stdoutLine
        }
        return nil
    }

    static func reverseRelayStartupFailureDetail(
        process: Process,
        stderrPipe: Pipe,
        gracePeriod: TimeInterval = reverseRelayStartupGracePeriod
    ) -> String? {
        if process.isRunning {
            let originalTerminationHandler = process.terminationHandler
            let exitSemaphore = DispatchSemaphore(value: 0)
            process.terminationHandler = { terminated in
                originalTerminationHandler?(terminated)
                exitSemaphore.signal()
            }
            if !process.isRunning {
                exitSemaphore.signal()
            }
            guard exitSemaphore.wait(timeout: .now() + max(0, gracePeriod)) == .success else {
                return nil
            }
        }
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        return bestErrorLine(stderr: stderr) ?? "status=\(process.terminationStatus)"
    }

    static func meaningfulErrorLine(in text: String) -> String? {
        let lines = text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for line in lines.reversed() where !isNoiseLine(line) {
            return line
        }
        return lines.last
    }

    static func isNoiseLine(_ line: String) -> Bool {
        let lowered = line.lowercased()
        if lowered.hasPrefix("warning: permanently added") { return true }
        if lowered.hasPrefix("debug") { return true }
        if lowered.hasPrefix("transferred:") { return true }
        if lowered.hasPrefix("openbsd_") { return true }
        if lowered.contains("pseudo-terminal will not be allocated") { return true }
        return false
    }

    static func retrySuffix(retry: Int, delay: TimeInterval) -> String {
        let seconds = max(1, Int(delay.rounded()))
        return " (retry \(retry) in \(seconds)s)"
    }

    static func retryDelay(baseDelay: TimeInterval, retry: Int) -> TimeInterval {
        let exponent = Double(max(0, retry - 1))
        return min(baseDelay * pow(2.0, exponent), 60.0)
    }

    static func shouldEscalateProxyErrorToBootstrap(_ detail: String) -> Bool {
        let lowered = detail.lowercased()
        return lowered.contains("remote daemon transport failed")
            || lowered.contains("daemon transport closed stdout")
            || lowered.contains("daemon transport exited")
            || lowered.contains("daemon transport is not connected")
            || lowered.contains("daemon transport stopped")
    }

}
