// Extracted from WorkspaceRemoteSession.swift (nuclear-review #98): remote listening-port scan scheduling, polling, and script builders.

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
    func updateRemotePortScanTTYs(_ ttyNames: [UUID: String]) {
        queue.async { [weak self] in
            self?.updateRemotePortScanTTYsLocked(ttyNames)
        }
    }

    func kickRemotePortScan(panelId: UUID, reason: PortScanKickReason = .command) {
        queue.async { [weak self] in
            self?.kickRemotePortScanLocked(panelId: panelId, reason: reason)
        }
    }

    func updateRemotePortScanTTYsLocked(_ ttyNames: [UUID: String]) {
        let previousTTYNames = remotePortScanTTYNames
        let nextTTYNames = ttyNames.reduce(into: [UUID: String]()) { result, entry in
            guard let ttyName = Self.normalizedRemotePortScanTTYName(entry.value) else { return }
            result[entry.key] = ttyName
        }
        guard previousTTYNames != nextTTYNames else { return }
        if !nextTTYNames.isEmpty {
            bootstrapRemoteTTYResolved = true
            bootstrapRemoteTTYRetryWorkItem?.cancel()
            bootstrapRemoteTTYRetryWorkItem = nil
            bootstrapRemoteTTYRetryCount = 0
        }
        keepPolledRemotePortsUntilTTYScan =
            !previousTTYNames.isEmpty
            ? keepPolledRemotePortsUntilTTYScan
            : shouldUseFallbackRemotePortPollingLocked() && !polledRemotePorts.isEmpty && !nextTTYNames.isEmpty
        remoteScannedPortsByPanel = remoteScannedPortsByPanel.filter { panelId, _ in
            guard let oldTTY = previousTTYNames[panelId],
                  let newTTY = nextTTYNames[panelId] else {
                return false
            }
            return oldTTY == newTTY
        }
        remotePortScanTTYNames = nextTTYNames
        if nextTTYNames.isEmpty {
            keepPolledRemotePortsUntilTTYScan = false
        }
        updateRemotePortPollingStateLocked()
        publishPortsSnapshotLocked()
    }

    func kickRemotePortScanLocked(panelId: UUID, reason: PortScanKickReason) {
        guard !isStopping else { return }
        guard daemonReady else { return }
        guard remotePortScanTTYNames[panelId] != nil else { return }
        if remotePortScanBurstActive, remotePortScanActiveReason == .command, reason == .refresh {
            return
        }
        remotePortScanPendingReason = remotePortScanPendingReason?.merged(with: reason) ?? reason
        scheduleRemotePortScanCoalesceLocked()
    }

    func scheduleRemotePortScanCoalesceLocked() {
        guard !remotePortScanBurstActive else { return }
        guard remotePortScanCoalesceWorkItem == nil else { return }

        let generation = remotePortScanGeneration
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.remotePortScanGeneration == generation else { return }
            self.remotePortScanCoalesceWorkItem = nil
            guard let reason = self.remotePortScanPendingReason else { return }
            self.remotePortScanPendingReason = nil
            self.remotePortScanBurstActive = true
            self.remotePortScanActiveReason = reason
            self.runRemotePortScanBurstLocked(index: 0, generation: generation, reason: reason)
        }
        remotePortScanCoalesceWorkItem = workItem
        queue.asyncAfter(deadline: .now() + 0.2, execute: workItem)
    }

    func runRemotePortScanBurstLocked(
        index: Int,
        generation: UInt64,
        reason: PortScanKickReason,
        burstStart: DispatchTime? = nil
    ) {
        guard remotePortScanGeneration == generation else { return }

        let burstOffsets = reason.burstOffsets
        guard index < burstOffsets.count else {
            remotePortScanBurstActive = false
            remotePortScanActiveReason = nil
            if remotePortScanPendingReason != nil && remotePortScanCoalesceWorkItem == nil {
                scheduleRemotePortScanCoalesceLocked()
            }
            return
        }

        let start = burstStart ?? .now()
        let deadline = start + burstOffsets[index]
        queue.asyncAfter(deadline: deadline) { [weak self] in
            guard let self else { return }
            guard self.remotePortScanGeneration == generation else { return }
            self.performRemotePortScanLocked()
            self.runRemotePortScanBurstLocked(
                index: index + 1,
                generation: generation,
                reason: reason,
                burstStart: start
            )
        }
    }

    func performRemotePortScanLocked() {
        let ttyNamesByPanel = remotePortScanTTYNames
        guard !ttyNamesByPanel.isEmpty else {
            remoteScannedPortsByPanel.removeAll()
            keepPolledRemotePortsUntilTTYScan = false
            publishPortsSnapshotLocked()
            return
        }

        do {
            remoteScannedPortsByPanel = try scanRemotePortsByPanelLocked(ttyNamesByPanel: ttyNamesByPanel)
            keepPolledRemotePortsUntilTTYScan = false
            polledRemotePorts = []
            publishPortsSnapshotLocked()
        } catch {
            debugLog("remote.ports.scan.failed error=\(error.localizedDescription) \(debugConfigSummary())")
        }
    }

    func scanRemotePortsByPanelLocked(ttyNamesByPanel: [UUID: String]) throws -> [UUID: [Int]] {
        let ttyNames = Array(Set(ttyNamesByPanel.values)).sorted()
        guard !ttyNames.isEmpty else { return [:] }

        let command = "sh -c \(RemoteSSHConnectionPolicy.shellSingleQuoted(Self.remotePortScanScript(ttyNames: ttyNames, excluding: excludedRemoteScanPorts())))"
        let result = try sshExec(
            arguments: sshCommonArguments(batchMode: true) + [configuration.destination, command],
            timeout: 8
        )
        guard result.status == 0 else {
            let detail = Self.bestErrorLine(stderr: result.stderr, stdout: result.stdout) ?? "ssh exited \(result.status)"
            throw NSError(domain: "programa.remote.ports", code: 90, userInfo: [
                NSLocalizedDescriptionKey: "remote port scan failed: \(detail)",
            ])
        }

        let portsByTTY = Self.parseRemoteTTYPortPairs(
            output: result.stdout,
            trackedTTYNames: Set(ttyNames)
        )

        return ttyNamesByPanel.reduce(into: [UUID: [Int]]()) { result, entry in
            result[entry.key] = portsByTTY[entry.value] ?? []
        }
    }

    func startRemotePortPollingLocked(mode: RemotePortPollingMode) {
        if remotePortPollTimer != nil, remotePortPollMode == mode {
            return
        }
        stopRemotePortPollingLocked()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + mode.initialDelay, repeating: mode.repeatInterval)
        timer.setEventHandler { [weak self] in
            self?.pollRemotePortsLocked()
        }
        remotePortPollTimer = timer
        remotePortPollMode = mode
        timer.resume()
        pollRemotePortsLocked()
    }

    func stopRemotePortPollingLocked() {
        remotePortPollTimer?.setEventHandler {}
        remotePortPollTimer?.cancel()
        remotePortPollTimer = nil
        remotePortPollMode = nil
    }

    func updateRemotePortPollingStateLocked() {
        guard daemonReady, !isStopping, let pollingMode = remotePortPollingModeLocked() else {
            stopRemotePortPollingLocked()
            if !keepPolledRemotePortsUntilTTYScan {
                polledRemotePorts = []
            }
            remotePortPollBaselinePorts = nil
            return
        }
        startRemotePortPollingLocked(mode: pollingMode)
    }

    func pollRemotePortsLocked() {
        guard !isStopping else { return }
        guard daemonReady else { return }
        if !remotePortScanTTYNames.isEmpty {
            guard shouldUseTTYFallbackRemotePortPollingLocked() else {
                stopRemotePortPollingLocked()
                if !keepPolledRemotePortsUntilTTYScan {
                    polledRemotePorts = []
                }
                publishPortsSnapshotLocked()
                return
            }
            if remotePortScanBurstActive || remotePortScanCoalesceWorkItem != nil || remotePortScanPendingReason != nil {
                return
            }
            performRemotePortScanLocked()
            return
        }
        guard let pollingMode = remotePortPollingModeLocked() else {
            stopRemotePortPollingLocked()
            polledRemotePorts = []
            remotePortPollBaselinePorts = nil
            keepPolledRemotePortsUntilTTYScan = false
            publishPortsSnapshotLocked()
            return
        }
        guard remotePortScanTTYNames.isEmpty else {
            stopRemotePortPollingLocked()
            if !keepPolledRemotePortsUntilTTYScan {
                polledRemotePorts = []
            }
            remotePortPollBaselinePorts = nil
            publishPortsSnapshotLocked()
            return
        }

        let command = "sh -c \(RemoteSSHConnectionPolicy.shellSingleQuoted(Self.remoteAllPortsScanScript(excluding: excludedRemoteScanPorts())))"
        do {
            let result = try sshExec(
                arguments: sshCommonArguments(batchMode: true) + [configuration.destination, command],
                timeout: 8
            )
            guard result.status == 0 else {
                let detail = Self.bestErrorLine(stderr: result.stderr, stdout: result.stdout) ?? "ssh exited \(result.status)"
                throw NSError(domain: "programa.remote.ports", code: 90, userInfo: [
                    NSLocalizedDescriptionKey: "remote port scan failed: \(detail)",
                ])
            }
            let currentPorts = Set(Self.parseRemotePorts(output: result.stdout))
            switch pollingMode {
            case .hostWide:
                polledRemotePorts = currentPorts.sorted()
                remotePortPollBaselinePorts = nil
            case .hostWideDelta:
                if let baselinePorts = remotePortPollBaselinePorts {
                    polledRemotePorts = currentPorts.subtracting(baselinePorts).sorted()
                } else {
                    remotePortPollBaselinePorts = currentPorts
                    polledRemotePorts = []
                }
            case .ttyScoped:
                polledRemotePorts = []
                remotePortPollBaselinePorts = nil
            }
            keepPolledRemotePortsUntilTTYScan = false
            publishPortsSnapshotLocked()
        } catch {
            debugLog("remote.ports.poll.failed error=\(error.localizedDescription) \(debugConfigSummary())")
        }
    }

    func excludedRemoteScanPorts() -> Set<Int> {
        var excluded: Set<Int> = []
        if let relayPort = configuration.relayPort, relayPort > 0 {
            excluded.insert(relayPort)
        }
        if let configuredPort = configuration.port, configuredPort > 0 {
            excluded.insert(configuredPort)
        }
        return excluded
    }

    func shouldUseFallbackRemotePortPollingLocked() -> Bool {
        // `cmux ssh` owns the remote shell bootstrap and can report the remote
        // TTY precisely. Falling back to host-wide port scans in that path leaks
        // unrelated listeners from the remote machine into the workspace card.
        let startupCommand = configuration.terminalStartupCommand?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return startupCommand?.isEmpty != false
    }

    func shouldUseTTYFallbackRemotePortPollingLocked() -> Bool {
        // `cmux ssh` can still land in shells without our command hooks, such as
        // `/bin/sh` in the Docker fixture. Once the workspace knows the TTY,
        // keep a low-frequency TTY-scoped poll so unsupported shells still
        // surface ports without bringing back noisy host-wide scans.
        let startupCommand = configuration.terminalStartupCommand?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return startupCommand?.isEmpty == false
    }

    func remotePortPollingModeLocked() -> RemotePortPollingMode? {
        if !remotePortScanTTYNames.isEmpty {
            return shouldUseTTYFallbackRemotePortPollingLocked() ? .ttyScoped : nil
        }
        let startupCommand = configuration.terminalStartupCommand?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if startupCommand?.isEmpty == false {
            return .hostWideDelta
        }
        return shouldUseFallbackRemotePortPollingLocked() ? .hostWide : nil
    }

    static func parseRemoteTTYPortPairs(output: String, trackedTTYNames: Set<String>) -> [String: [Int]] {
        var portsByTTY = Dictionary(uniqueKeysWithValues: trackedTTYNames.map { ($0, Set<Int>()) })

        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let ttyName = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard trackedTTYNames.contains(ttyName),
                  let port = Int(parts[1]),
                  port >= 1024,
                  port <= 65535 else {
                continue
            }
            portsByTTY[ttyName, default: []].insert(port)
        }

        return portsByTTY.reduce(into: [String: [Int]]()) { result, entry in
            result[entry.key] = entry.value.sorted()
        }
    }

    static func parseRemotePorts(output: String) -> [Int] {
        let values = output
            .split(whereSeparator: \.isWhitespace)
            .compactMap { Int($0) }
            .filter { $0 >= 1024 && $0 <= 65535 }
        return Array(Set(values)).sorted()
    }

    static func normalizedRemotePortScanTTYName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.split(separator: "/").last.map(String.init) ?? trimmed
        guard !candidate.isEmpty else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard candidate.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return candidate
    }

    static func remotePortScanScript(ttyNames: [String], excluding ports: Set<Int>) -> String {
        let ttySet = ttyNames.joined(separator: " ")
        let ttyCSV = ttyNames.joined(separator: ",")
        let excludedPorts = ports.sorted().map(String.init).joined(separator: " ")

        return """
        set -eu
        programa_tracked_ttys=" \(ttySet) "
        programa_tty_csv='\(ttyCSV)'
        programa_excluded_ports=" \(excludedPorts) "

        programa_emit_port() {
          programa_tty="$1"
          programa_port="$2"
          case "$programa_tracked_ttys" in
            *" $programa_tty "*) ;;
            *) return 0 ;;
          esac
          case "$programa_excluded_ports" in
            *" $programa_port "*) return 0 ;;
          esac
          [ "$programa_port" -ge 1024 ] && [ "$programa_port" -le 65535 ] || return 0
          printf '%s\\t%s\\n' "$programa_tty" "$programa_port"
        }

        programa_used_ss=0
        if [ -d /proc ] && command -v ss >/dev/null 2>&1; then
          programa_ss_output="$(ss -ltnpH 2>/dev/null || true)"
          case "$programa_ss_output" in
            *pid=*)
              programa_used_ss=1
              printf '%s\\n' "$programa_ss_output" | while IFS= read -r programa_line; do
                [ -n "$programa_line" ] || continue
                programa_port="$(printf '%s\\n' "$programa_line" | awk '{print $4}' | sed -E 's/.*:([0-9]+)$/\\1/' | awk '/^[0-9]+$/ { print $1; exit }')"
                [ -n "$programa_port" ] || continue
                printf '%s\\n' "$programa_line" | awk '
                  {
                    line = $0
                    while (match(line, /pid=[0-9]+/)) {
                      print substr(line, RSTART + 4, RLENGTH - 4)
                      line = substr(line, RSTART + RLENGTH)
                    }
                  }
                ' | while IFS= read -r programa_pid; do
                  [ -n "$programa_pid" ] || continue
                  programa_tty_path="$(readlink "/proc/$programa_pid/fd/0" 2>/dev/null || true)"
                  [ -n "$programa_tty_path" ] || continue
                  programa_tty="${programa_tty_path##*/}"
                  [ -n "$programa_tty" ] || continue
                  programa_emit_port "$programa_tty" "$programa_port"
                done
              done
              ;;
          esac
        fi

        if [ "$programa_used_ss" -eq 0 ] && command -v lsof >/dev/null 2>&1 && [ -n "$programa_tty_csv" ]; then
          programa_tmpdir="$(mktemp -d 2>/dev/null || mktemp -d -t programa-ports)"
          trap 'rm -rf "$programa_tmpdir"' EXIT INT TERM
          programa_pid_tty_map="$programa_tmpdir/pid_tty"
          ps -t "$programa_tty_csv" -o pid=,tty= 2>/dev/null | awk '
            NF >= 2 {
              tty = $2
              sub(/^.*\\//, "", tty)
              print $1 "\\t" tty
            }
          ' > "$programa_pid_tty_map"
          [ -s "$programa_pid_tty_map" ] || exit 0
          programa_pid_csv="$(awk '{print $1}' "$programa_pid_tty_map" | paste -sd, -)"
          [ -n "$programa_pid_csv" ] || exit 0
          lsof -nP -a -p "$programa_pid_csv" -iTCP -sTCP:LISTEN -Fpn 2>/dev/null | awk -v map="$programa_pid_tty_map" '
            BEGIN {
              while ((getline < map) > 0) {
                pid_to_tty[$1] = $2
              }
              close(map)
            }
            $0 ~ /^p/ {
              pid = substr($0, 2)
              tty = pid_to_tty[pid]
              next
            }
            $0 ~ /^n/ && tty != "" {
              name = substr($0, 2)
              sub(/->.*/, "", name)
              sub(/^.*:/, "", name)
              sub(/[^0-9].*/, "", name)
              if (name != "") {
                print tty "\\t" name
              }
            }
          ' | while IFS=$'\\t' read -r programa_tty programa_port; do
            [ -n "$programa_tty" ] || continue
            [ -n "$programa_port" ] || continue
            programa_emit_port "$programa_tty" "$programa_port"
          done
        fi
        """
    }

    static func remoteAllPortsScanScript(excluding ports: Set<Int>) -> String {
        let excludedPorts = ports.sorted().map(String.init).joined(separator: " ")

        return """
        set -eu
        programa_excluded_ports=" \(excludedPorts) "

        programa_emit_port() {
          programa_port="$1"
          case "$programa_excluded_ports" in
            *" $programa_port "*) return 0 ;;
          esac
          [ "$programa_port" -ge 1024 ] && [ "$programa_port" -le 65535 ] || return 0
          printf '%s\\n' "$programa_port"
        }

        if command -v ss >/dev/null 2>&1; then
          ss -ltnH 2>/dev/null | awk '{print $4}' | sed -E 's/.*:([0-9]+)$/\\1/' | awk '/^[0-9]+$/ {print $1}' | while IFS= read -r programa_port; do
            [ -n "$programa_port" ] || continue
            programa_emit_port "$programa_port"
          done
        elif command -v netstat >/dev/null 2>&1; then
          netstat -lnt 2>/dev/null | awk 'NR > 2 {print $4}' | sed -E 's/.*:([0-9]+)$/\\1/' | awk '/^[0-9]+$/ {print $1}' | while IFS= read -r programa_port; do
            [ -n "$programa_port" ] || continue
            programa_emit_port "$programa_port"
          done
        elif command -v lsof >/dev/null 2>&1; then
          lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | awk 'NR > 1 {print $9}' | sed -E 's/.*:([0-9]+)$/\\1/' | awk '/^[0-9]+$/ {print $1}' | while IFS= read -r programa_port; do
            [ -n "$programa_port" ] || continue
            programa_emit_port "$programa_port"
          done
        fi
        """
    }

}
