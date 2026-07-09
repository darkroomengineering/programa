// Extracted from WorkspaceRemoteSession.swift (nuclear-review #98): connection-attempt/reverse-relay/proxy orchestration and status publishing.

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
    func stopAllLocked() {
        debugLog("remote.session.stop \(debugConfigSummary())")
        isStopping = true
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        reconnectRetryCount = 0
        reverseRelayRestartWorkItem?.cancel()
        reverseRelayRestartWorkItem = nil
        remotePortScanCoalesceWorkItem?.cancel()
        remotePortScanCoalesceWorkItem = nil
        stopReverseRelayLocked()
        remotePortScanGeneration &+= 1
        remotePortScanBurstActive = false
        remotePortScanActiveReason = nil
        remotePortScanPendingReason = nil
        remotePortScanTTYNames.removeAll()
        remoteScannedPortsByPanel.removeAll()
        stopRemotePortPollingLocked()
        polledRemotePorts = []
        remotePortPollBaselinePorts = nil
        keepPolledRemotePortsUntilTTYScan = false
        bootstrapRemoteTTYResolved = false
        bootstrapRemoteTTYRetryWorkItem?.cancel()
        bootstrapRemoteTTYRetryWorkItem = nil
        bootstrapRemoteTTYFetchInFlight = false
        bootstrapRemoteTTYRetryCount = 0

        proxyLease?.release()
        proxyLease = nil
        proxyEndpoint = nil
        daemonReady = false
        daemonBootstrapVersion = nil
        daemonRemotePath = nil
        publishProxyEndpoint(nil)
        publishPortsSnapshotLocked()
    }

    func beginConnectionAttemptLocked() {
        guard !isStopping else { return }

        Self.killOrphanedRemoteSSHProcesses(
            destination: configuration.destination,
            relayPort: configuration.relayPort
        )
        connectionAttemptStartedAt = Date()
        debugLog("remote.session.connect.begin retry=\(reconnectRetryCount) \(debugConfigSummary())")
        reconnectWorkItem = nil
        bootstrapRemoteTTYRetryWorkItem?.cancel()
        bootstrapRemoteTTYRetryWorkItem = nil
        bootstrapRemoteTTYFetchInFlight = false
        if remotePortScanTTYNames.isEmpty {
            bootstrapRemoteTTYResolved = false
            bootstrapRemoteTTYRetryCount = 0
        }
        let connectDetail: String
        let bootstrapDetail: String
        if reconnectRetryCount > 0 {
            connectDetail = "Reconnecting to \(configuration.displayTarget) (retry \(reconnectRetryCount))"
            bootstrapDetail = "Bootstrapping remote daemon on \(configuration.displayTarget) (retry \(reconnectRetryCount))"
        } else {
            connectDetail = "Connecting to \(configuration.displayTarget)"
            bootstrapDetail = "Bootstrapping remote daemon on \(configuration.displayTarget)"
        }
        publishState(.connecting, detail: connectDetail)
        publishDaemonStatus(.bootstrapping, detail: bootstrapDetail)
        do {
            let hello = try bootstrapDaemonLocked()
            guard hello.capabilities.contains(WorkspaceRemoteDaemonRPCClient.requiredProxyStreamCapability) else {
                throw NSError(domain: "programa.remote.daemon", code: 43, userInfo: [
                    NSLocalizedDescriptionKey: "remote daemon missing required capability \(WorkspaceRemoteDaemonRPCClient.requiredProxyStreamCapability)",
                ])
            }
            daemonReady = true
            daemonBootstrapVersion = hello.version
            daemonRemotePath = hello.remotePath
            publishDaemonStatus(
                .ready,
                detail: "Remote daemon ready",
                version: hello.version,
                name: hello.name,
                capabilities: hello.capabilities,
                remotePath: hello.remotePath
            )
            recordHeartbeatActivityLocked()
            startReverseRelayLocked(remotePath: hello.remotePath)
            requestBootstrapRemoteTTYIfNeededLocked()
            startProxyLocked()
        } catch {
            daemonReady = false
            daemonBootstrapVersion = nil
            daemonRemotePath = nil
            let retrySchedule = scheduleReconnectLocked(baseDelay: 4.0)
            let retrySuffix = Self.retrySuffix(retry: retrySchedule.retry, delay: retrySchedule.delay)
            let detail = "Remote daemon bootstrap failed: \(error.localizedDescription)\(retrySuffix)"
            publishDaemonStatus(.error, detail: detail)
            publishState(.error, detail: detail)
        }
    }

    func startProxyLocked() {
        guard !isStopping else { return }
        guard daemonReady else { return }
        guard proxyLease == nil else { return }
        guard let remotePath = daemonRemotePath,
              !remotePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let retrySchedule = scheduleReconnectLocked(baseDelay: 4.0)
            let retrySuffix = Self.retrySuffix(retry: retrySchedule.retry, delay: retrySchedule.delay)
            let detail = "Remote daemon did not provide a valid remote path\(retrySuffix)"
            publishDaemonStatus(.error, detail: detail)
            publishState(.error, detail: detail)
            return
        }

        let lease = WorkspaceRemoteProxyBroker.shared.acquire(
            configuration: configuration,
            remotePath: remotePath
        ) { [weak self] update in
            self?.queue.async {
                self?.handleProxyBrokerUpdateLocked(update)
            }
        }
        proxyLease = lease
    }

    func startReverseRelayLocked(remotePath: String) {
        guard !isStopping else { return }
        guard daemonReady else { return }
        guard let relayPort = configuration.relayPort, relayPort > 0,
              let relayID = configuration.relayID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !relayID.isEmpty,
              let relayToken = configuration.relayToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !relayToken.isEmpty,
              let localSocketPath = configuration.localSocketPath?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !localSocketPath.isEmpty else {
            return
        }
        guard reverseRelayProcess == nil else { return }
        guard reverseRelayControlMasterForwardSpec == nil else { return }

        reverseRelayRestartWorkItem?.cancel()
        reverseRelayRestartWorkItem = nil
        var relayServer: WorkspaceRemoteCLIRelayServer?
        do {
            let server = try ensureCLIRelayServerLocked(
                localSocketPath: localSocketPath,
                relayID: relayID,
                relayToken: relayToken
            )
            relayServer = server
            let localRelayPort = try server.start()
            Self.killOrphanedRemoteSSHProcesses(
                destination: configuration.destination,
                relayPort: relayPort
            )
            let forwardSpec = "127.0.0.1:\(relayPort):127.0.0.1:\(localRelayPort)"

            if startReverseRelayViaControlMasterLocked(forwardSpec: forwardSpec) {
                cliRelayServer = relayServer
                reverseRelayStderrBuffer = ""
                do {
                    try installRemoteRelayMetadataLocked(
                        remotePath: remotePath,
                        relayPort: relayPort,
                        relayID: relayID,
                        relayToken: relayToken
                    )
                } catch {
                    debugLog("remote.relay.metadata.error \(error.localizedDescription)")
                    stopReverseRelayLocked()
                    scheduleReverseRelayRestartLocked(remotePath: remotePath, delay: 2.0)
                    return
                }
                recordHeartbeatActivityLocked()
                debugLog(
                    "remote.relay.start relayPort=\(relayPort) localRelayPort=\(localRelayPort) " +
                    "target=\(configuration.displayTarget) controlMaster=1"
                )
                return
            }

            let process = Process()
            let stderrPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = reverseRelayArguments(relayPort: relayPort, localRelayPort: localRelayPort)
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = stderrPipe

            process.terminationHandler = { [weak self] terminated in
                self?.queue.async {
                    self?.handleReverseRelayTerminationLocked(process: terminated)
                }
            }

            try process.run()
            if let startupFailure = Self.reverseRelayStartupFailureDetail(
                process: process,
                stderrPipe: stderrPipe
            ) {
                let retryDelay = 2.0
                let retrySeconds = max(1, Int(retryDelay.rounded()))
                debugLog(
                    "remote.relay.startFailed relayPort=\(relayPort) " +
                    "error=\(startupFailure)"
                )
                relayServer?.stop()
                publishDaemonStatus(
                    .error,
                    detail: "Remote SSH relay unavailable: \(startupFailure) (retry in \(retrySeconds)s)"
                )
                scheduleReverseRelayRestartLocked(remotePath: remotePath, delay: retryDelay)
                return
            }
            installReverseRelayStderrHandlerLocked(stderrPipe)
            reverseRelayProcess = process
            cliRelayServer = relayServer
            reverseRelayStderrPipe = stderrPipe
            reverseRelayStderrBuffer = ""
            do {
                try installRemoteRelayMetadataLocked(
                    remotePath: remotePath,
                    relayPort: relayPort,
                    relayID: relayID,
                    relayToken: relayToken
                )
            } catch {
                debugLog("remote.relay.metadata.error \(error.localizedDescription)")
                stopReverseRelayLocked()
                scheduleReverseRelayRestartLocked(remotePath: remotePath, delay: 2.0)
                return
            }
            recordHeartbeatActivityLocked()
            debugLog(
                "remote.relay.start relayPort=\(relayPort) localRelayPort=\(localRelayPort) " +
                "target=\(configuration.displayTarget) controlMaster=0"
            )
        } catch {
            debugLog(
                "remote.relay.startFailed relayPort=\(relayPort) " +
                "error=\(error.localizedDescription)"
            )
            relayServer?.stop()
            cliRelayServer = nil
            scheduleReverseRelayRestartLocked(remotePath: remotePath, delay: 2.0)
        }
    }

    func installReverseRelayStderrHandlerLocked(_ stderrPipe: Pipe) {
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self?.queue.async {
                guard let self else { return }
                if let chunk = String(data: data, encoding: .utf8), !chunk.isEmpty {
                    self.reverseRelayStderrBuffer.append(chunk)
                    if self.reverseRelayStderrBuffer.count > 8192 {
                        self.reverseRelayStderrBuffer.removeFirst(self.reverseRelayStderrBuffer.count - 8192)
                    }
                }
            }
        }
    }

    func handleReverseRelayTerminationLocked(process: Process) {
        guard reverseRelayProcess === process else { return }
        let stderrDetail = Self.bestErrorLine(stderr: reverseRelayStderrBuffer)
        reverseRelayStderrPipe?.fileHandleForReading.readabilityHandler = nil
        reverseRelayProcess = nil
        reverseRelayStderrPipe = nil

        guard !isStopping else { return }
        guard let remotePath = daemonRemotePath,
              !remotePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let detail = stderrDetail ?? "status=\(process.terminationStatus)"
        debugLog("remote.relay.exit \(detail)")
        scheduleReverseRelayRestartLocked(remotePath: remotePath, delay: 2.0)
    }

    func scheduleReverseRelayRestartLocked(remotePath: String, delay: TimeInterval) {
        guard !isStopping else { return }
        reverseRelayRestartWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.reverseRelayRestartWorkItem = nil
            guard !self.isStopping else { return }
            guard self.reverseRelayProcess == nil else { return }
            guard self.daemonReady else { return }
            self.startReverseRelayLocked(remotePath: self.daemonRemotePath ?? remotePath)
        }
        reverseRelayRestartWorkItem = workItem
        queue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    func stopReverseRelayLocked() {
        reverseRelayStderrPipe?.fileHandleForReading.readabilityHandler = nil
        if let reverseRelayProcess, reverseRelayProcess.isRunning {
            reverseRelayProcess.terminate()
        }
        reverseRelayProcess = nil
        stopReverseRelayViaControlMasterLocked()
        reverseRelayStderrPipe = nil
        reverseRelayStderrBuffer = ""
        cliRelayServer?.stop()
        cliRelayServer = nil
        removeRemoteRelayMetadataLocked()
    }

    func handleProxyBrokerUpdateLocked(_ update: WorkspaceRemoteProxyBroker.Update) {
        guard !isStopping else { return }
        switch update {
        case .connecting:
            debugLog("remote.proxy.connecting \(debugConfigSummary())")
            if proxyEndpoint == nil {
                publishState(.connecting, detail: "Connecting to \(configuration.displayTarget)")
            }
        case .ready(let endpoint):
            debugLog("remote.proxy.ready host=\(endpoint.host) port=\(endpoint.port) \(debugConfigSummary())")
            reconnectWorkItem?.cancel()
            reconnectWorkItem = nil
            reconnectRetryCount = 0
            guard proxyEndpoint != endpoint else {
                recordHeartbeatActivityLocked()
                return
            }
            proxyEndpoint = endpoint
            publishProxyEndpoint(endpoint)
            updateRemotePortPollingStateLocked()
            publishPortsSnapshotLocked()
            publishState(
                .connected,
                detail: "Connected to \(configuration.displayTarget) via shared local proxy \(endpoint.host):\(endpoint.port)"
            )
            requestBootstrapRemoteTTYIfNeededLocked()
            recordHeartbeatActivityLocked()
        case .error(let detail):
            debugLog("remote.proxy.error detail=\(detail) \(debugConfigSummary())")
            remotePortScanGeneration &+= 1
            remotePortScanBurstActive = false
            remotePortScanActiveReason = nil
            remotePortScanPendingReason = nil
            remotePortScanCoalesceWorkItem?.cancel()
            remotePortScanCoalesceWorkItem = nil
            remoteScannedPortsByPanel.removeAll()
            stopRemotePortPollingLocked()
            polledRemotePorts = []
            keepPolledRemotePortsUntilTTYScan = false
            proxyEndpoint = nil
            publishProxyEndpoint(nil)
            publishPortsSnapshotLocked()
            publishState(.error, detail: "Remote proxy to \(configuration.displayTarget) unavailable: \(detail)")
            guard Self.shouldEscalateProxyErrorToBootstrap(detail) else { return }

            proxyLease?.release()
            proxyLease = nil
            daemonReady = false
            daemonBootstrapVersion = nil
            daemonRemotePath = nil

            let retrySchedule = scheduleReconnectLocked(baseDelay: 2.0)
            let retrySuffix = Self.retrySuffix(retry: retrySchedule.retry, delay: retrySchedule.delay)
            publishDaemonStatus(
                .error,
                detail: "Remote daemon transport needs re-bootstrap after proxy failure\(retrySuffix)"
            )
        }
    }

    @discardableResult
    func scheduleReconnectLocked(baseDelay: TimeInterval) -> RetrySchedule {
        let retryNumber = reconnectRetryCount + 1
        let retryDelay = Self.retryDelay(baseDelay: baseDelay, retry: retryNumber)
        guard !isStopping else { return RetrySchedule(retry: retryNumber, delay: retryDelay) }
        reconnectWorkItem?.cancel()
        reconnectRetryCount = retryNumber
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.reconnectWorkItem = nil
            guard !self.isStopping else { return }
            guard self.proxyLease == nil else { return }
            self.beginConnectionAttemptLocked()
        }
        reconnectWorkItem = workItem
        queue.asyncAfter(deadline: .now() + retryDelay, execute: workItem)
        return RetrySchedule(retry: retryNumber, delay: retryDelay)
    }

    func publishState(_ state: WorkspaceRemoteConnectionState, detail: String?) {
        let controllerID = self.controllerID
        DispatchQueue.main.async { [weak workspace] in
            guard let workspace else { return }
            guard workspace.activeRemoteSessionControllerID == controllerID else { return }
            workspace.applyRemoteConnectionStateUpdate(
                state,
                detail: detail,
                target: workspace.remoteDisplayTarget ?? "remote host"
            )
        }
    }

    func publishDaemonStatus(
        _ state: WorkspaceRemoteDaemonState,
        detail: String?,
        version: String? = nil,
        name: String? = nil,
        capabilities: [String] = [],
        remotePath: String? = nil
    ) {
        let controllerID = self.controllerID
        let status = WorkspaceRemoteDaemonStatus(
            state: state,
            detail: detail,
            version: version,
            name: name,
            capabilities: capabilities,
            remotePath: remotePath
        )
        DispatchQueue.main.async { [weak workspace] in
            guard let workspace else { return }
            guard workspace.activeRemoteSessionControllerID == controllerID else { return }
            workspace.applyRemoteDaemonStatusUpdate(
                status,
                target: workspace.remoteDisplayTarget ?? "remote host"
            )
        }
    }

    func publishProxyEndpoint(_ endpoint: BrowserProxyEndpoint?) {
        let controllerID = self.controllerID
        DispatchQueue.main.async { [weak workspace] in
            guard let workspace else { return }
            guard workspace.activeRemoteSessionControllerID == controllerID else { return }
            workspace.applyRemoteProxyEndpointUpdate(endpoint)
        }
    }

    func publishPortsSnapshotLocked() {
        let controllerID = self.controllerID
        let detectedByPanel = remotePortScanTTYNames.keys.reduce(into: [UUID: [Int]]()) { result, panelId in
            result[panelId] = remoteScannedPortsByPanel[panelId] ?? []
        }
        let detected = Array(
            Set(polledRemotePorts)
                .union(detectedByPanel.values.flatMap { $0 })
        ).sorted()
        DispatchQueue.main.async { [weak workspace] in
            guard let workspace else { return }
            guard workspace.activeRemoteSessionControllerID == controllerID else { return }
            workspace.applyRemoteDetectedSurfacePortsSnapshot(
                detectedByPanel: detectedByPanel,
                detected: detected,
                forwarded: [],
                conflicts: [],
                target: workspace.remoteDisplayTarget ?? "remote host"
            )
        }
    }

    func recordHeartbeatActivityLocked() {
        heartbeatCount += 1
        publishHeartbeat(count: heartbeatCount, at: Date())
    }

    func publishHeartbeat(count: Int, at date: Date?) {
        let controllerID = self.controllerID
        DispatchQueue.main.async { [weak workspace] in
            guard let workspace else { return }
            guard workspace.activeRemoteSessionControllerID == controllerID else { return }
            workspace.applyRemoteHeartbeatUpdate(count: count, lastSeenAt: date)
        }
    }

    func requestBootstrapRemoteTTYIfNeededLocked() {
        guard !bootstrapRemoteTTYResolved else { return }
        guard let relayPort = configuration.relayPort, relayPort > 0 else { return }
        if !remotePortScanTTYNames.isEmpty {
            bootstrapRemoteTTYResolved = true
            bootstrapRemoteTTYRetryWorkItem?.cancel()
            bootstrapRemoteTTYRetryWorkItem = nil
            bootstrapRemoteTTYRetryCount = 0
            return
        }
        guard !bootstrapRemoteTTYFetchInFlight else { return }
        bootstrapRemoteTTYFetchInFlight = true
        defer { bootstrapRemoteTTYFetchInFlight = false }

        let command = "sh -c \(RemoteSSHConnectionPolicy.shellSingleQuoted("tty_path=\"$HOME/.programa/relay/\(relayPort).tty\"; if [ -r \"$tty_path\" ]; then cat \"$tty_path\"; fi"))"
        do {
            let result = try sshExec(
                arguments: sshCommonArguments(batchMode: true) + [configuration.destination, command],
                timeout: 2
            )
            guard result.status == 0 else {
                scheduleBootstrapRemoteTTYRetryLocked()
                return
            }
            guard let ttyName = Self.normalizedRemotePortScanTTYName(result.stdout) else {
                scheduleBootstrapRemoteTTYRetryLocked()
                return
            }
            bootstrapRemoteTTYResolved = true
            bootstrapRemoteTTYRetryWorkItem?.cancel()
            bootstrapRemoteTTYRetryWorkItem = nil
            bootstrapRemoteTTYRetryCount = 0
            debugLog("remote.tty.bootstrap.ready tty=\(ttyName) \(debugConfigSummary())")
            publishBootstrapRemoteTTY(ttyName)
        } catch {
            debugLog("remote.tty.bootstrap.failed error=\(error.localizedDescription) \(debugConfigSummary())")
            scheduleBootstrapRemoteTTYRetryLocked()
        }
    }

    func scheduleBootstrapRemoteTTYRetryLocked() {
        guard !isStopping else { return }
        guard daemonReady else { return }
        guard !bootstrapRemoteTTYResolved else { return }
        guard remotePortScanTTYNames.isEmpty else { return }
        guard bootstrapRemoteTTYRetryCount < Self.bootstrapRemoteTTYRetryLimit else { return }
        guard bootstrapRemoteTTYRetryWorkItem == nil else { return }

        bootstrapRemoteTTYRetryCount += 1
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.bootstrapRemoteTTYRetryWorkItem = nil
            self.requestBootstrapRemoteTTYIfNeededLocked()
        }
        bootstrapRemoteTTYRetryWorkItem = workItem
        queue.asyncAfter(deadline: .now() + Self.bootstrapRemoteTTYRetryDelay, execute: workItem)
    }

    func publishBootstrapRemoteTTY(_ ttyName: String) {
        let controllerID = self.controllerID
        DispatchQueue.main.async { [weak workspace] in
            guard let workspace else { return }
            guard workspace.activeRemoteSessionControllerID == controllerID else { return }
            workspace.applyBootstrapRemoteTTY(ttyName)
        }
    }

    func reverseRelayArguments(relayPort: Int, localRelayPort: Int) -> [String] {
        // Fallback standalone transport when dynamic forwarding through an existing
        // control master is unavailable.
        var args: [String] = ["-N", "-T", "-S", "none"]
        args += sshCommonArguments(batchMode: true)
        args += [
            "-o", "ExitOnForwardFailure=yes",
            "-o", "RequestTTY=no",
            "-R", "127.0.0.1:\(relayPort):127.0.0.1:\(localRelayPort)",
            configuration.destination,
        ]
        return args
    }

    func startReverseRelayViaControlMasterLocked(forwardSpec: String) -> Bool {
        guard let arguments = WorkspaceRemoteSSHBatchCommandBuilder.reverseRelayControlMasterArguments(
            configuration: configuration,
            controlCommand: "forward",
            forwardSpec: forwardSpec
        ) else {
            return false
        }

        do {
            let result = try sshExec(arguments: arguments, timeout: 6)
            guard result.status == 0 else {
                let detail = Self.bestErrorLine(stderr: result.stderr, stdout: result.stdout)
                    ?? "ssh exited \(result.status)"
                debugLog("remote.relay.controlmaster.forwardFailed \(detail) \(debugConfigSummary())")
                return false
            }
            reverseRelayControlMasterForwardSpec = forwardSpec
            return true
        } catch {
            debugLog("remote.relay.controlmaster.forwardFailed \(error.localizedDescription) \(debugConfigSummary())")
            return false
        }
    }

    func stopReverseRelayViaControlMasterLocked() {
        guard let forwardSpec = reverseRelayControlMasterForwardSpec else { return }
        reverseRelayControlMasterForwardSpec = nil
        guard let arguments = WorkspaceRemoteSSHBatchCommandBuilder.reverseRelayControlMasterArguments(
            configuration: configuration,
            controlCommand: "cancel",
            forwardSpec: forwardSpec
        ) else {
            return
        }
        _ = try? sshExec(arguments: arguments, timeout: 4)
    }

    static let bootstrapRemoteTTYRetryDelay: TimeInterval = 0.5
    static let bootstrapRemoteTTYRetryLimit = 8

}
