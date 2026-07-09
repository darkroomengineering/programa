// Extracted from Workspace.swift (nuclear-review N5): the remote-session
// infrastructure below is self-contained — its only edge back to Workspace
// is the weak reference held by WorkspaceRemoteSessionController.

import Foundation
import SwiftUI
import AppKit
import Bonsplit
import Combine
import CryptoKit
import Darwin
import Network
import CoreText

final class WorkspaceRemoteSessionController {
    enum PortScanKickReason: String {
        case command
        case refresh

        var burstOffsets: [Double] {
            switch self {
            case .command:
                return [0.5, 1.5, 3.0, 5.0, 7.5, 10.0]
            case .refresh:
                return [0.0]
            }
        }

        func merged(with other: Self) -> Self {
            switch (self, other) {
            case (.command, _), (_, .command):
                return .command
            case (.refresh, .refresh):
                return .refresh
            }
        }
    }

    private struct RetrySchedule {
        let retry: Int
        let delay: TimeInterval
    }

    private struct CommandResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    private struct RemotePlatform {
        let goOS: String
        let goArch: String
    }

    private struct RemoteBootstrapState {
        let platform: RemotePlatform
        let binaryExists: Bool
    }

    private struct DaemonHello {
        let name: String
        let version: String
        let capabilities: [String]
        let remotePath: String
    }

    private let queue = DispatchQueue(label: "com.cmux.remote-ssh.\(UUID().uuidString)", qos: .utility)
    private let queueKey = DispatchSpecificKey<Void>()
    private weak var workspace: Workspace?
    private let configuration: WorkspaceRemoteConfiguration
    private let controllerID: UUID

    private enum RemotePortPollingMode {
        case hostWide
        case hostWideDelta
        case ttyScoped

        var initialDelay: TimeInterval {
            switch self {
            case .hostWide:
                return 0.5
            case .hostWideDelta:
                return 0.5
            case .ttyScoped:
                return 1.0
            }
        }

        var repeatInterval: TimeInterval {
            switch self {
            case .hostWide:
                return 2.0
            case .hostWideDelta:
                return 5.0
            case .ttyScoped:
                return 5.0
            }
        }
    }

    private var isStopping = false
    private var proxyLease: WorkspaceRemoteProxyBroker.Lease?
    private var proxyEndpoint: BrowserProxyEndpoint?
    private var daemonReady = false
    private var daemonBootstrapVersion: String?
    private var daemonRemotePath: String?
    private var reverseRelayProcess: Process?
    private var reverseRelayControlMasterForwardSpec: String?
    private var cliRelayServer: WorkspaceRemoteCLIRelayServer?
    private var remotePortScanTTYNames: [UUID: String] = [:]
    private var remoteScannedPortsByPanel: [UUID: [Int]] = [:]
    private var remotePortScanBurstActive = false
    private var remotePortScanActiveReason: PortScanKickReason?
    private var remotePortScanPendingReason: PortScanKickReason?
    private var remotePortScanGeneration: UInt64 = 0
    private var remotePortScanCoalesceWorkItem: DispatchWorkItem?
    private var remotePortPollTimer: DispatchSourceTimer?
    private var remotePortPollMode: RemotePortPollingMode?
    private var polledRemotePorts: [Int] = []
    private var remotePortPollBaselinePorts: Set<Int>?
    private var keepPolledRemotePortsUntilTTYScan = false
    private var bootstrapRemoteTTYResolved = false
    private var bootstrapRemoteTTYRetryWorkItem: DispatchWorkItem?
    private var bootstrapRemoteTTYFetchInFlight = false
    private var bootstrapRemoteTTYRetryCount = 0
    private var reverseRelayStderrPipe: Pipe?
    private var reverseRelayRestartWorkItem: DispatchWorkItem?
    private var reverseRelayStderrBuffer = ""
    private var reconnectRetryCount = 0
    private var reconnectWorkItem: DispatchWorkItem?
    private var heartbeatCount: Int = 0
    private var connectionAttemptStartedAt: Date?

    private static let reverseRelayStartupGracePeriod: TimeInterval = 0.5

    init(workspace: Workspace, configuration: WorkspaceRemoteConfiguration, controllerID: UUID) {
        self.workspace = workspace
        self.configuration = configuration
        self.controllerID = controllerID
        queue.setSpecific(key: queueKey, value: ())
    }

    func start() {
        debugLog("remote.session.start \(debugConfigSummary())")
        queue.async { [weak self] in
            guard let self else { return }
            guard !self.isStopping else { return }
            self.beginConnectionAttemptLocked()
        }
    }

    func stop() {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            stopAllLocked()
            return
        }
        queue.async { [self] in
            stopAllLocked()
        }
    }

    func uploadDroppedFiles(
        _ fileURLs: [URL],
        operation: TerminalImageTransferOperation,
        completion: @escaping (Result<[String], Error>) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else {
                DispatchQueue.main.async {
                    completion(.failure(RemoteDropUploadError.unavailable))
                }
                return
            }

            do {
                try operation.throwIfCancelled()
                let remotePaths = try self.uploadDroppedFilesLocked(fileURLs, operation: operation)
                try operation.throwIfCancelled()
                DispatchQueue.main.async { [weak self] in
                    if operation.isCancelled {
                        guard let self else {
                            completion(.failure(TerminalImageTransferExecutionError.cancelled))
                            return
                        }
                        self.queue.async { [weak self] in
                            self?.cleanupUploadedRemotePaths(remotePaths)
                            DispatchQueue.main.async {
                                completion(.failure(TerminalImageTransferExecutionError.cancelled))
                            }
                        }
                    } else {
                        completion(.success(remotePaths))
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    func uploadDroppedFiles(
        _ fileURLs: [URL],
        completion: @escaping (Result<[String], Error>) -> Void
    ) {
        uploadDroppedFiles(
            fileURLs,
            operation: TerminalImageTransferOperation(),
            completion: completion
        )
    }

    private func stopAllLocked() {
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

    private func beginConnectionAttemptLocked() {
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

    private func startProxyLocked() {
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

    private func startReverseRelayLocked(remotePath: String) {
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

    private func installReverseRelayStderrHandlerLocked(_ stderrPipe: Pipe) {
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

    private func handleReverseRelayTerminationLocked(process: Process) {
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

    private func scheduleReverseRelayRestartLocked(remotePath: String, delay: TimeInterval) {
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

    private func stopReverseRelayLocked() {
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

    private func handleProxyBrokerUpdateLocked(_ update: WorkspaceRemoteProxyBroker.Update) {
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
    private func scheduleReconnectLocked(baseDelay: TimeInterval) -> RetrySchedule {
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

    private func publishState(_ state: WorkspaceRemoteConnectionState, detail: String?) {
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

    private func publishDaemonStatus(
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

    private func publishProxyEndpoint(_ endpoint: BrowserProxyEndpoint?) {
        let controllerID = self.controllerID
        DispatchQueue.main.async { [weak workspace] in
            guard let workspace else { return }
            guard workspace.activeRemoteSessionControllerID == controllerID else { return }
            workspace.applyRemoteProxyEndpointUpdate(endpoint)
        }
    }

    private func publishPortsSnapshotLocked() {
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

    private func recordHeartbeatActivityLocked() {
        heartbeatCount += 1
        publishHeartbeat(count: heartbeatCount, at: Date())
    }

    private func publishHeartbeat(count: Int, at date: Date?) {
        let controllerID = self.controllerID
        DispatchQueue.main.async { [weak workspace] in
            guard let workspace else { return }
            guard workspace.activeRemoteSessionControllerID == controllerID else { return }
            workspace.applyRemoteHeartbeatUpdate(count: count, lastSeenAt: date)
        }
    }

    private func requestBootstrapRemoteTTYIfNeededLocked() {
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

    private func scheduleBootstrapRemoteTTYRetryLocked() {
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

    private func publishBootstrapRemoteTTY(_ ttyName: String) {
        let controllerID = self.controllerID
        DispatchQueue.main.async { [weak workspace] in
            guard let workspace else { return }
            guard workspace.activeRemoteSessionControllerID == controllerID else { return }
            workspace.applyBootstrapRemoteTTY(ttyName)
        }
    }

    private func reverseRelayArguments(relayPort: Int, localRelayPort: Int) -> [String] {
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

    private func startReverseRelayViaControlMasterLocked(forwardSpec: String) -> Bool {
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

    private func stopReverseRelayViaControlMasterLocked() {
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

    private static let remotePlatformProbeOSMarker = "__PROGRAMA_REMOTE_OS__="
    private static let remotePlatformProbeArchMarker = "__PROGRAMA_REMOTE_ARCH__="
    private static let remotePlatformProbeExistsMarker = "__PROGRAMA_REMOTE_EXISTS__="
    private static let bootstrapRemoteTTYRetryDelay: TimeInterval = 0.5
    private static let bootstrapRemoteTTYRetryLimit = 8

    private func sshCommonArguments(batchMode: Bool) -> [String] {
        let effectiveSSHOptions: [String] = {
            if batchMode {
                return RemoteSSHConnectionPolicy.backgroundOptions(configuration.sshOptions)
            }
            return RemoteSSHConnectionPolicy.normalizedOptions(configuration.sshOptions)
        }()
        var args = RemoteSSHConnectionPolicy.keepaliveArguments
        args += RemoteSSHConnectionPolicy.strictHostKeyCheckingArguments(unlessSetIn: effectiveSSHOptions)
        if batchMode {
            args += RemoteSSHConnectionPolicy.batchModeArguments
        }
        if let port = configuration.port {
            args += ["-p", String(port)]
        }
        if let identityFile = configuration.identityFile,
           !identityFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["-i", identityFile]
        }
        for option in effectiveSSHOptions {
            args += ["-o", option]
        }
        return args
    }

    private func sshExec(arguments: [String], stdin: Data? = nil, timeout: TimeInterval = 15) throws -> CommandResult {
        try runProcess(
            executable: "/usr/bin/ssh",
            arguments: arguments,
            stdin: stdin,
            timeout: timeout
        )
    }

    private func scpExec(
        arguments: [String],
        timeout: TimeInterval = 30,
        operation: TerminalImageTransferOperation? = nil
    ) throws -> CommandResult {
        try runProcess(
            executable: "/usr/bin/scp",
            arguments: arguments,
            stdin: nil,
            timeout: timeout,
            operation: operation
        )
    }

    private func runProcess(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        stdin: Data?,
        timeout: TimeInterval,
        operation: TerminalImageTransferOperation? = nil
    ) throws -> CommandResult {
        debugLog(
            "remote.proc.start exec=\(URL(fileURLWithPath: executable).lastPathComponent) " +
            "timeout=\(Int(timeout)) args=\(debugShellCommand(executable: executable, arguments: arguments))"
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }
        if let currentDirectory {
            process.currentDirectoryURL = currentDirectory
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        if stdin != nil {
            process.standardInput = Pipe()
        } else {
            process.standardInput = FileHandle.nullDevice
        }

        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading
        let captureQueue = DispatchQueue(label: "programa.remote.process.capture")
        let exitSemaphore = DispatchSemaphore(value: 0)
        var stdoutData = Data()
        var stderrData = Data()
        let captureGroup = DispatchGroup()
        process.terminationHandler = { _ in
            exitSemaphore.signal()
        }
        captureGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = stdoutHandle.readDataToEndOfFile()
            captureQueue.sync {
                stdoutData = data
            }
            captureGroup.leave()
        }
        captureGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = stderrHandle.readDataToEndOfFile()
            captureQueue.sync {
                stderrData = data
            }
            captureGroup.leave()
        }

        do {
            try operation?.throwIfCancelled()
            try process.run()
        } catch {
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
            debugLog(
                "remote.proc.launchFailed exec=\(URL(fileURLWithPath: executable).lastPathComponent) " +
                "error=\(error.localizedDescription)"
            )
            throw NSError(domain: "programa.remote.process", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to launch \(URL(fileURLWithPath: executable).lastPathComponent): \(error.localizedDescription)",
            ])
        }
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()
        operation?.installCancellationHandler {
            if process.isRunning {
                process.terminate()
            }
        }
        defer { operation?.clearCancellationHandler() }

        if let stdin, let pipe = process.standardInput as? Pipe {
            pipe.fileHandleForWriting.write(stdin)
            try? pipe.fileHandleForWriting.close()
        }

        func terminateProcessAndWait() {
            process.terminate()
            let terminatedGracefully = exitSemaphore.wait(timeout: .now() + 2.0) == .success
            if !terminatedGracefully, process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
        }

        let didExitBeforeTimeout = exitSemaphore.wait(timeout: .now() + max(0, timeout)) == .success
        if !didExitBeforeTimeout, process.isRunning {
            if operation?.isCancelled == true {
                terminateProcessAndWait()
                throw TerminalImageTransferExecutionError.cancelled
            }
            terminateProcessAndWait()
            debugLog(
                "remote.proc.timeout exec=\(URL(fileURLWithPath: executable).lastPathComponent) " +
                "timeout=\(Int(timeout)) args=\(debugShellCommand(executable: executable, arguments: arguments))"
            )
            throw NSError(domain: "programa.remote.process", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "\(URL(fileURLWithPath: executable).lastPathComponent) timed out after \(Int(timeout))s",
            ])
        }

        _ = captureGroup.wait(timeout: .now() + 2.0)
        try? stdoutHandle.close()
        try? stderrHandle.close()
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        if operation?.isCancelled == true {
            throw TerminalImageTransferExecutionError.cancelled
        }
        debugLog(
            "remote.proc.end exec=\(URL(fileURLWithPath: executable).lastPathComponent) " +
            "status=\(process.terminationStatus) stdout=\(Self.debugLogSnippet(stdout)) " +
            "stderr=\(Self.debugLogSnippet(stderr))"
        )
        return CommandResult(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    private func bootstrapDaemonLocked() throws -> DaemonHello {
        debugLog("remote.bootstrap.begin \(debugConfigSummary())")
        let version = Self.remoteDaemonVersion()
        let bootstrapState = try probeRemoteBootstrapStateLocked(version: version)
        let platform = bootstrapState.platform
        let remotePath = Self.remoteDaemonPath(version: version, goOS: platform.goOS, goArch: platform.goArch)
        let explicitOverrideBinary = Self.explicitRemoteDaemonBinaryURL()
        let forceExplicitOverrideInstall = explicitOverrideBinary != nil
        debugLog(
            "remote.bootstrap.platform os=\(platform.goOS) arch=\(platform.goArch) " +
            "version=\(version) remotePath=\(remotePath) " +
            "allowLocalBuildFallback=\(Self.allowLocalDaemonBuildFallback() ? 1 : 0) " +
            "explicitOverride=\(forceExplicitOverrideInstall ? 1 : 0)"
        )

        let hadExistingBinary = bootstrapState.binaryExists
        debugLog("remote.bootstrap.binaryExists remotePath=\(remotePath) exists=\(hadExistingBinary ? 1 : 0)")
        if forceExplicitOverrideInstall || !hadExistingBinary {
            let localBinary = try buildLocalDaemonBinary(goOS: platform.goOS, goArch: platform.goArch, version: version)
            try uploadRemoteDaemonBinaryLocked(localBinary: localBinary, remotePath: remotePath)
        }

        var hello: DaemonHello
        do {
            hello = try helloRemoteDaemonLocked(remotePath: remotePath)
        } catch {
            guard hadExistingBinary else {
                throw error
            }
            debugLog(
                "remote.bootstrap.helloRetry remotePath=\(remotePath) " +
                "detail=\(error.localizedDescription)"
            )
            let localBinary = try buildLocalDaemonBinary(goOS: platform.goOS, goArch: platform.goArch, version: version)
            try uploadRemoteDaemonBinaryLocked(localBinary: localBinary, remotePath: remotePath)
            hello = try helloRemoteDaemonLocked(remotePath: remotePath)
        }
        if hadExistingBinary, !hello.capabilities.contains(WorkspaceRemoteDaemonRPCClient.requiredProxyStreamCapability) {
            debugLog("remote.bootstrap.capabilityMissing remotePath=\(remotePath) capabilities=\(hello.capabilities.joined(separator: ","))")
            let localBinary = try buildLocalDaemonBinary(goOS: platform.goOS, goArch: platform.goArch, version: version)
            try uploadRemoteDaemonBinaryLocked(localBinary: localBinary, remotePath: remotePath)
            hello = try helloRemoteDaemonLocked(remotePath: remotePath)
        }

        debugLog(
            "remote.bootstrap.ready name=\(hello.name) version=\(hello.version) " +
            "capabilities=\(hello.capabilities.joined(separator: ",")) remotePath=\(hello.remotePath)"
        )
        if let connectionAttemptStartedAt {
            debugLog(
                "remote.timing.bootstrap.ready elapsedMs=\(Int(Date().timeIntervalSince(connectionAttemptStartedAt) * 1000)) " +
                "\(debugConfigSummary())"
            )
        }
        return hello
    }

    private func ensureCLIRelayServerLocked(localSocketPath: String, relayID: String, relayToken: String) throws -> WorkspaceRemoteCLIRelayServer {
        if let cliRelayServer {
            return cliRelayServer
        }
        let relayServer = try WorkspaceRemoteCLIRelayServer(
            localSocketPath: localSocketPath,
            relayID: relayID,
            relayTokenHex: relayToken
        )
        cliRelayServer = relayServer
        return relayServer
    }

    private func installRemoteRelayMetadataLocked(
        remotePath: String,
        relayPort: Int,
        relayID: String,
        relayToken: String
    ) throws {
        let script = Self.remoteRelayMetadataInstallScript(
            daemonRemotePath: remotePath,
            relayPort: relayPort,
            relayID: relayID,
            relayToken: relayToken
        )
        let command = "sh -c \(RemoteSSHConnectionPolicy.shellSingleQuoted(script))"
        let result = try sshExec(arguments: sshCommonArguments(batchMode: true) + [configuration.destination, command], timeout: 8)
        guard result.status == 0 else {
            let detail = Self.bestErrorLine(stderr: result.stderr, stdout: result.stdout) ?? "ssh exited \(result.status)"
            throw NSError(domain: "programa.remote.relay", code: 70, userInfo: [
                NSLocalizedDescriptionKey: "failed to install remote relay metadata: \(detail)",
            ])
        }
    }

    private func removeRemoteRelayMetadataLocked() {
        guard let relayPort = configuration.relayPort, relayPort > 0 else { return }
        let script = Self.remoteRelayMetadataCleanupScript(relayPort: relayPort)
        let command = "sh -c \(RemoteSSHConnectionPolicy.shellSingleQuoted(script))"
        do {
            _ = try sshExec(arguments: sshCommonArguments(batchMode: true) + [configuration.destination, command], timeout: 8)
        } catch {
            debugLog("remote.relay.cleanup.error \(error.localizedDescription)")
        }
    }

    static func remoteRelayMetadataCleanupScript(relayPort: Int) -> String {
        """
        relay_socket='127.0.0.1:\(relayPort)'
        socket_addr_file="$HOME/.programa/socket_addr"
        if [ -r "$socket_addr_file" ] && [ "$(tr -d '\\r\\n' < "$socket_addr_file")" = "$relay_socket" ]; then
          rm -f "$socket_addr_file"
        fi
        rm -f "$HOME/.programa/relay/\(relayPort).auth" "$HOME/.programa/relay/\(relayPort).daemon_path" "$HOME/.programa/relay/\(relayPort).tty"
        """
    }

    private func probeRemoteBootstrapStateLocked(version: String) throws -> RemoteBootstrapState {
        let script = """
        programa_uname_os="$(uname -s)"
        programa_uname_arch="$(uname -m)"
        printf '%s%s\\n' '\(Self.remotePlatformProbeOSMarker)' "$programa_uname_os"
        printf '%s%s\\n' '\(Self.remotePlatformProbeArchMarker)' "$programa_uname_arch"
        case "$(printf '%s' "$programa_uname_os" | tr '[:upper:]' '[:lower:]')" in
          linux|darwin|freebsd) programa_go_os="$(printf '%s' "$programa_uname_os" | tr '[:upper:]' '[:lower:]')" ;;
          *) exit 70 ;;
        esac
        case "$(printf '%s' "$programa_uname_arch" | tr '[:upper:]' '[:lower:]')" in
          x86_64|amd64) programa_go_arch=amd64 ;;
          aarch64|arm64) programa_go_arch=arm64 ;;
          armv7l) programa_go_arch=arm ;;
          *) exit 71 ;;
        esac
        programa_remote_path="$HOME/.programa/bin/programad-remote/\(version)/${programa_go_os}-${programa_go_arch}/programad-remote"
        if [ -x "$programa_remote_path" ]; then
          printf '%syes\\n' '\(Self.remotePlatformProbeExistsMarker)'
        else
          printf '%sno\\n' '\(Self.remotePlatformProbeExistsMarker)'
        fi
        """
        let command = "sh -c \(RemoteSSHConnectionPolicy.shellSingleQuoted(script))"
        let result = try sshExec(arguments: sshCommonArguments(batchMode: true) + [configuration.destination, command], timeout: 20)

        let lines = result.stdout
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let unameOS = lines.first { $0.hasPrefix(Self.remotePlatformProbeOSMarker) }
            .map { String($0.dropFirst(Self.remotePlatformProbeOSMarker.count)) }
        let unameArch = lines.first { $0.hasPrefix(Self.remotePlatformProbeArchMarker) }
            .map { String($0.dropFirst(Self.remotePlatformProbeArchMarker.count)) }
        guard let unameOS, let unameArch else {
            let detail = Self.bestErrorLine(stderr: result.stderr, stdout: result.stdout) ?? "ssh exited \(result.status)"
            throw NSError(domain: "programa.remote.daemon", code: 11, userInfo: [
                NSLocalizedDescriptionKey: "failed to query remote platform: \(detail)",
            ])
        }

        guard let goOS = Self.mapUnameOS(unameOS),
              let goArch = Self.mapUnameArch(unameArch) else {
            throw NSError(domain: "programa.remote.daemon", code: 12, userInfo: [
                NSLocalizedDescriptionKey: "unsupported remote platform \(unameOS)/\(unameArch)",
            ])
        }

        let binaryExists = lines.first { $0.hasPrefix(Self.remotePlatformProbeExistsMarker) }
            .map { String($0.dropFirst(Self.remotePlatformProbeExistsMarker.count)) == "yes" }
        if result.status != 0, binaryExists == nil {
            let detail = Self.bestErrorLine(stderr: result.stderr, stdout: result.stdout) ?? "ssh exited \(result.status)"
            throw NSError(domain: "programa.remote.daemon", code: 13, userInfo: [
                NSLocalizedDescriptionKey: "failed to query remote daemon state: \(detail)",
            ])
        }

        return RemoteBootstrapState(
            platform: RemotePlatform(goOS: goOS, goArch: goArch),
            binaryExists: binaryExists ?? false
        )
    }

    static let remoteDaemonManifestInfoKey = "CMUXRemoteDaemonManifestJSON"

    static func remoteDaemonManifest(from infoDictionary: [String: Any]?) -> WorkspaceRemoteDaemonManifest? {
        guard let rawManifest = infoDictionary?[remoteDaemonManifestInfoKey] as? String else { return nil }
        let trimmed = rawManifest.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let data = trimmed.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(WorkspaceRemoteDaemonManifest.self, from: data)
    }

    private static func remoteDaemonManifest() -> WorkspaceRemoteDaemonManifest? {
        remoteDaemonManifest(from: Bundle.main.infoDictionary)
    }

    private static func remoteDaemonCacheRoot(fileManager: FileManager = .default) throws -> URL {
        let appSupportRoot = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let cacheRoot = appSupportRoot
            .appendingPathComponent("programa", isDirectory: true)
            .appendingPathComponent("remote-daemons", isDirectory: true)
        try fileManager.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        return cacheRoot
    }

    static func remoteDaemonCachedBinaryURL(
        version: String,
        goOS: String,
        goArch: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        try remoteDaemonCacheRoot(fileManager: fileManager)
            .appendingPathComponent(version, isDirectory: true)
            .appendingPathComponent("\(goOS)-\(goArch)", isDirectory: true)
            .appendingPathComponent("programad-remote", isDirectory: false)
    }

    private static func sha256Hex(forFile url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func allowLocalDaemonBuildFallback(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment["PROGRAMA_REMOTE_DAEMON_ALLOW_LOCAL_BUILD"] == "1"
    }

    private static func explicitRemoteDaemonBinaryURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        guard allowLocalDaemonBuildFallback(environment: environment) else { return nil }
        guard let path = environment["PROGRAMA_REMOTE_DAEMON_BINARY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: false).standardizedFileURL
    }

    private static func versionedRemoteDaemonBuildURL(goOS: String, goArch: String, version: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("programa-remote-daemon-build", isDirectory: true)
            .appendingPathComponent(version, isDirectory: true)
            .appendingPathComponent("\(goOS)-\(goArch)", isDirectory: true)
            .appendingPathComponent("programad-remote", isDirectory: false)
    }

    /// Fetch the live manifest JSON from the release, returning nil on any failure.
    private static func fetchRemoteManifestLocked(releaseURL: String, version: String) -> WorkspaceRemoteDaemonManifest? {
        guard let manifestURL = URL(string: "\(releaseURL)/programad-remote-manifest.json") else { return nil }
        let request = NSMutableURLRequest(url: manifestURL)
        request.timeoutInterval = 15
        request.setValue("cmux/\(version)", forHTTPHeaderField: "User-Agent")
        let session = URLSession(configuration: .ephemeral)
        let semaphore = DispatchSemaphore(value: 0)
        var resultData: Data?
        session.dataTask(with: request as URLRequest) { data, response, error in
            defer { semaphore.signal() }
            guard error == nil,
                  let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else { return }
            resultData = data
        }.resume()
        _ = semaphore.wait(timeout: .now() + 20.0)
        session.finishTasksAndInvalidate()
        guard let data = resultData else { return nil }
        return try? JSONDecoder().decode(WorkspaceRemoteDaemonManifest.self, from: data)
    }

    private func downloadRemoteDaemonBinaryLocked(entry: WorkspaceRemoteDaemonManifest.Entry, version: String, releaseURL: String? = nil) throws -> URL {
        guard let url = URL(string: entry.downloadURL) else {
            throw NSError(domain: "programa.remote.daemon", code: 25, userInfo: [
                NSLocalizedDescriptionKey: "remote daemon manifest has an invalid download URL",
            ])
        }

        let cacheURL = try Self.remoteDaemonCachedBinaryURL(version: version, goOS: entry.goOS, goArch: entry.goArch)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let request = NSMutableURLRequest(url: url)
        request.timeoutInterval = 60
        request.setValue("cmux/\(version)", forHTTPHeaderField: "User-Agent")
        let session = URLSession(configuration: .ephemeral)

        let semaphore = DispatchSemaphore(value: 0)
        var downloadedURL: URL?
        var downloadError: Error?
        session.downloadTask(with: request as URLRequest) { localURL, response, error in
            defer { semaphore.signal() }
            if let error {
                downloadError = error
                return
            }
            if let httpResponse = response as? HTTPURLResponse,
               !(200...299).contains(httpResponse.statusCode) {
                downloadError = NSError(domain: "programa.remote.daemon", code: 26, userInfo: [
                    NSLocalizedDescriptionKey: "remote daemon download failed with HTTP \(httpResponse.statusCode)",
                ])
                return
            }
            downloadedURL = localURL
        }.resume()
        _ = semaphore.wait(timeout: .now() + 75.0)
        session.finishTasksAndInvalidate()

        if let downloadError {
            throw downloadError
        }
        guard let downloadedURL else {
            throw NSError(domain: "programa.remote.daemon", code: 27, userInfo: [
                NSLocalizedDescriptionKey: "remote daemon download did not produce a file",
            ])
        }

        let downloadedSHA = try Self.sha256Hex(forFile: downloadedURL)
        if downloadedSHA != entry.sha256.lowercased() {
            // The embedded manifest's checksum doesn't match the downloaded binary.
            // This can happen when a newer build overwrites the shared release
            // asset after this build's manifest was embedded. As a fallback, fetch
            // the live manifest from the release and verify against that.
            if let releaseURL,
               let liveManifest = Self.fetchRemoteManifestLocked(releaseURL: releaseURL, version: version),
               let liveEntry = liveManifest.entry(goOS: entry.goOS, goArch: entry.goArch),
               downloadedSHA == liveEntry.sha256.lowercased() {
                debugLog("remote.download.checksum-fallback: embedded manifest checksum stale, live manifest matched for \(entry.assetName)")
            } else {
                throw NSError(domain: "programa.remote.daemon", code: 28, userInfo: [
                    NSLocalizedDescriptionKey: "remote daemon checksum mismatch for \(entry.assetName)",
                ])
            }
        }

        let tempURL = cacheURL.deletingLastPathComponent()
            .appendingPathComponent(".\(cacheURL.lastPathComponent).tmp-\(UUID().uuidString)")
        try? fileManager.removeItem(at: tempURL)
        try fileManager.moveItem(at: downloadedURL, to: tempURL)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempURL.path)
        try? fileManager.removeItem(at: cacheURL)
        try fileManager.moveItem(at: tempURL, to: cacheURL)
        return cacheURL
    }

    private func buildLocalDaemonBinary(goOS: String, goArch: String, version: String) throws -> URL {
        if let explicitBinary = Self.explicitRemoteDaemonBinaryURL(),
           FileManager.default.isExecutableFile(atPath: explicitBinary.path) {
            debugLog("remote.build.explicit path=\(explicitBinary.path)")
            return explicitBinary
        }

        if let manifest = Self.remoteDaemonManifest(),
           manifest.appVersion == version,
           let entry = manifest.entry(goOS: goOS, goArch: goArch) {
            let cacheURL = try Self.remoteDaemonCachedBinaryURL(version: manifest.appVersion, goOS: goOS, goArch: goArch)
            if FileManager.default.fileExists(atPath: cacheURL.path) {
                let cachedSHA = try Self.sha256Hex(forFile: cacheURL)
                if cachedSHA == entry.sha256.lowercased(),
                   FileManager.default.isExecutableFile(atPath: cacheURL.path) {
                    debugLog("remote.build.cached path=\(cacheURL.path)")
                    return cacheURL
                }
                try? FileManager.default.removeItem(at: cacheURL)
            }
            let downloadedURL = try downloadRemoteDaemonBinaryLocked(entry: entry, version: manifest.appVersion, releaseURL: manifest.releaseURL)
            debugLog("remote.build.downloaded path=\(downloadedURL.path)")
            return downloadedURL
        }

        guard Self.allowLocalDaemonBuildFallback() else {
            throw NSError(domain: "programa.remote.daemon", code: 20, userInfo: [
                NSLocalizedDescriptionKey: "this build does not include a verified programad-remote manifest for \(goOS)-\(goArch). Use a release build, or set PROGRAMA_REMOTE_DAEMON_ALLOW_LOCAL_BUILD=1 for a dev-only fallback.",
            ])
        }

        guard let repoRoot = Self.findRepoRoot() else {
            throw NSError(domain: "programa.remote.daemon", code: 20, userInfo: [
                NSLocalizedDescriptionKey: "cannot locate cmux repo root for dev-only programad-remote build fallback",
            ])
        }
        let daemonRoot = repoRoot.appendingPathComponent("daemon/remote", isDirectory: true)
        let goModPath = daemonRoot.appendingPathComponent("go.mod").path
        guard FileManager.default.fileExists(atPath: goModPath) else {
            throw NSError(domain: "programa.remote.daemon", code: 21, userInfo: [
                NSLocalizedDescriptionKey: "missing daemon module at \(goModPath)",
            ])
        }
        guard let goBinary = Self.which("go") else {
            throw NSError(domain: "programa.remote.daemon", code: 22, userInfo: [
                NSLocalizedDescriptionKey: "go is required for the dev-only programad-remote build fallback",
            ])
        }

        let output = Self.versionedRemoteDaemonBuildURL(goOS: goOS, goArch: goArch, version: version)
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)

        var env = ProcessInfo.processInfo.environment
        env["GOOS"] = goOS
        env["GOARCH"] = goArch
        env["CGO_ENABLED"] = "0"
        let ldflags = "-s -w -X main.version=\(version)"
        let result = try runProcess(
            executable: goBinary,
            arguments: ["build", "-trimpath", "-buildvcs=false", "-ldflags", ldflags, "-o", output.path, "./cmd/programad-remote"],
            environment: env,
            currentDirectory: daemonRoot,
            stdin: nil,
            timeout: 90
        )
        guard result.status == 0 else {
            let detail = Self.bestErrorLine(stderr: result.stderr, stdout: result.stdout) ?? "go build failed with status \(result.status)"
            throw NSError(domain: "programa.remote.daemon", code: 23, userInfo: [
                NSLocalizedDescriptionKey: "failed to build programad-remote: \(detail)",
            ])
        }
        guard FileManager.default.isExecutableFile(atPath: output.path) else {
            throw NSError(domain: "programa.remote.daemon", code: 24, userInfo: [
                NSLocalizedDescriptionKey: "programad-remote build output is not executable",
            ])
        }
        debugLog("remote.build.output path=\(output.path)")
        return output
    }

    private func uploadRemoteDaemonBinaryLocked(localBinary: URL, remotePath: String) throws {
        let remoteDirectory = (remotePath as NSString).deletingLastPathComponent
        let remoteTempPath = "\(remotePath).tmp-\(UUID().uuidString.prefix(8))"
        debugLog(
            "remote.upload.begin local=\(localBinary.path) remoteTemp=\(remoteTempPath) remote=\(remotePath)"
        )

        let mkdirScript = "mkdir -p \(RemoteSSHConnectionPolicy.shellSingleQuoted(remoteDirectory))"
        let mkdirCommand = "sh -c \(RemoteSSHConnectionPolicy.shellSingleQuoted(mkdirScript))"
        let mkdirResult = try sshExec(arguments: sshCommonArguments(batchMode: true) + [configuration.destination, mkdirCommand], timeout: 12)
        guard mkdirResult.status == 0 else {
            let detail = Self.bestErrorLine(stderr: mkdirResult.stderr, stdout: mkdirResult.stdout) ?? "ssh exited \(mkdirResult.status)"
            throw NSError(domain: "programa.remote.daemon", code: 30, userInfo: [
                NSLocalizedDescriptionKey: "failed to create remote daemon directory: \(detail)",
            ])
        }

        let scpSSHOptions = RemoteSSHConnectionPolicy.backgroundOptions(configuration.sshOptions)
        var scpArgs: [String] = ["-q"]
        scpArgs += RemoteSSHConnectionPolicy.strictHostKeyCheckingArguments(unlessSetIn: scpSSHOptions)
        scpArgs += ["-o", "ControlMaster=no"]
        if let port = configuration.port {
            scpArgs += ["-P", String(port)]
        }
        if let identityFile = configuration.identityFile,
           !identityFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            scpArgs += ["-i", identityFile]
        }
        for option in scpSSHOptions {
            scpArgs += ["-o", option]
        }
        scpArgs += [localBinary.path, "\(configuration.destination):\(remoteTempPath)"]
        let scpResult = try scpExec(arguments: scpArgs, timeout: 45)
        guard scpResult.status == 0 else {
            let detail = Self.bestErrorLine(stderr: scpResult.stderr, stdout: scpResult.stdout) ?? "scp exited \(scpResult.status)"
            throw NSError(domain: "programa.remote.daemon", code: 31, userInfo: [
                NSLocalizedDescriptionKey: "failed to upload programad-remote: \(detail)",
            ])
        }

        let finalizeScript = """
        chmod 755 \(RemoteSSHConnectionPolicy.shellSingleQuoted(remoteTempPath)) && \
        mv \(RemoteSSHConnectionPolicy.shellSingleQuoted(remoteTempPath)) \(RemoteSSHConnectionPolicy.shellSingleQuoted(remotePath))
        """
        let finalizeCommand = "sh -c \(RemoteSSHConnectionPolicy.shellSingleQuoted(finalizeScript))"
        let finalizeResult = try sshExec(arguments: sshCommonArguments(batchMode: true) + [configuration.destination, finalizeCommand], timeout: 12)
        guard finalizeResult.status == 0 else {
            let detail = Self.bestErrorLine(stderr: finalizeResult.stderr, stdout: finalizeResult.stdout) ?? "ssh exited \(finalizeResult.status)"
            throw NSError(domain: "programa.remote.daemon", code: 32, userInfo: [
                NSLocalizedDescriptionKey: "failed to install remote daemon binary: \(detail)",
            ])
        }
    }

    private func uploadDroppedFilesLocked(
        _ fileURLs: [URL],
        operation: TerminalImageTransferOperation
    ) throws -> [String] {
        let scpSSHOptions = RemoteSSHConnectionPolicy.backgroundOptions(configuration.sshOptions)
        return try performSCPUploadWithCancelCleanup(
            items: fileURLs,
            checkCancelled: { try operation.throwIfCancelled() },
            performUpload: { localURL, record in
                let normalizedLocalURL = localURL.standardizedFileURL
                guard normalizedLocalURL.isFileURL else {
                    throw RemoteDropUploadError.invalidFileURL
                }

                let remotePath = Self.remoteDropPath(for: normalizedLocalURL)
                record(remotePath)
                var scpArgs: [String] = ["-q", "-o", "ControlMaster=no"]
                scpArgs += RemoteSSHConnectionPolicy.strictHostKeyCheckingArguments(unlessSetIn: scpSSHOptions)
                if let port = configuration.port {
                    scpArgs += ["-P", String(port)]
                }
                if let identityFile = configuration.identityFile,
                   !identityFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    scpArgs += ["-i", identityFile]
                }
                for option in scpSSHOptions {
                    scpArgs += ["-o", option]
                }
                scpArgs += [normalizedLocalURL.path, "\(configuration.destination):\(remotePath)"]

                let scpResult = try scpExec(arguments: scpArgs, timeout: 45, operation: operation)
                guard scpResult.status == 0 else {
                    let detail = Self.bestErrorLine(stderr: scpResult.stderr, stdout: scpResult.stdout) ??
                        "scp exited \(scpResult.status)"
                    throw RemoteDropUploadError.uploadFailed(detail)
                }
            },
            cleanup: { cleanupUploadedRemotePaths($0) }
        )
    }

    static func remoteDropPath(for fileURL: URL, uuid: UUID = UUID()) -> String {
        let extensionSuffix = fileURL.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercasedSuffix = extensionSuffix.isEmpty ? "" : ".\(extensionSuffix.lowercased())"
        return "/tmp/programa-drop-\(uuid.uuidString.lowercased())\(lowercasedSuffix)"
    }

    private func cleanupUploadedRemotePaths(_ remotePaths: [String]) {
        guard !remotePaths.isEmpty else { return }
        let cleanupScript = "rm -f -- " + remotePaths.map(RemoteSSHConnectionPolicy.shellSingleQuoted).joined(separator: " ")
        let cleanupCommand = "sh -c \(RemoteSSHConnectionPolicy.shellSingleQuoted(cleanupScript))"
        _ = try? sshExec(
            arguments: sshCommonArguments(batchMode: true) + [configuration.destination, cleanupCommand],
            timeout: 8
        )
    }

    private func helloRemoteDaemonLocked(remotePath: String) throws -> DaemonHello {
        let request = #"{"id":1,"method":"hello","params":{}}"#
        let script = "printf '%s\\n' \(RemoteSSHConnectionPolicy.shellSingleQuoted(request)) | \(RemoteSSHConnectionPolicy.shellSingleQuoted(remotePath)) serve --stdio"
        let command = "sh -c \(RemoteSSHConnectionPolicy.shellSingleQuoted(script))"
        let result = try sshExec(arguments: sshCommonArguments(batchMode: true) + [configuration.destination, command], timeout: 12)
        guard result.status == 0 else {
            let detail = Self.bestErrorLine(stderr: result.stderr, stdout: result.stdout) ?? "ssh exited \(result.status)"
            throw NSError(domain: "programa.remote.daemon", code: 40, userInfo: [
                NSLocalizedDescriptionKey: "failed to start remote daemon: \(detail)",
            ])
        }

        let responseLine = result.stdout
            .split(separator: "\n")
            .map(String.init)
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? ""
        guard !responseLine.isEmpty,
              let data = responseLine.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            throw NSError(domain: "programa.remote.daemon", code: 41, userInfo: [
                NSLocalizedDescriptionKey: "remote daemon hello returned invalid JSON",
            ])
        }

        if let ok = payload["ok"] as? Bool, !ok {
            let errorMessage: String = {
                if let errorObject = payload["error"] as? [String: Any],
                   let message = errorObject["message"] as? String,
                   !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return message
                }
                return "hello call failed"
            }()
            throw NSError(domain: "programa.remote.daemon", code: 42, userInfo: [
                NSLocalizedDescriptionKey: "remote daemon hello failed: \(errorMessage)",
            ])
        }

        let resultObject = payload["result"] as? [String: Any] ?? [:]
        let name = (resultObject["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let version = (resultObject["version"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let capabilities = (resultObject["capabilities"] as? [String]) ?? []
        return DaemonHello(
            name: (name?.isEmpty == false ? name! : "programad-remote"),
            version: (version?.isEmpty == false ? version! : "dev"),
            capabilities: capabilities,
            remotePath: remotePath
        )
    }

    private func debugLog(_ message: @autoclosure () -> String) {
#if DEBUG
        dlog(message())
#endif
    }

    private func debugConfigSummary() -> String {
        let controlPath = Self.debugSSHOptionValue(named: "ControlPath", in: configuration.sshOptions) ?? "nil"
        return
            "target=\(configuration.displayTarget) port=\(configuration.port.map(String.init) ?? "nil") " +
            "relayPort=\(configuration.relayPort.map(String.init) ?? "nil") " +
            "localSocket=\(configuration.localSocketPath ?? "nil") " +
            "controlPath=\(controlPath)"
    }

    private func debugShellCommand(executable: String, arguments: [String]) -> String {
        ([URL(fileURLWithPath: executable).lastPathComponent] + arguments)
            .map(RemoteSSHConnectionPolicy.shellSingleQuoted)
            .joined(separator: " ")
    }

    private static func debugSSHOptionValue(named key: String, in options: [String]) -> String? {
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

    private static func debugLogSnippet(_ text: String, limit: Int = 160) -> String {
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

    private static func mapUnameOS(_ raw: String) -> String? {
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

    private static func mapUnameArch(_ raw: String) -> String? {
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

    private static func remoteDaemonVersion() -> String {
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

    private static let cachedRemoteDaemonSourceFingerprint: String? = computeRemoteDaemonSourceFingerprint()

    private static func remoteDaemonSourceFingerprint() -> String? {
        cachedRemoteDaemonSourceFingerprint
    }

    private static func computeRemoteDaemonSourceFingerprint(fileManager: FileManager = .default) -> String? {
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

    private static func remoteDaemonPath(version: String, goOS: String, goArch: String) -> String {
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

    private static func killOrphanedRemoteSSHProcesses(destination: String, relayPort: Int? = nil) {
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

    private static func captureCommandStandardOutput(
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

    private static func parsePSLine(_ line: Substring) -> (pid: Int, ppid: Int, command: String)? {
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

    private static func isOrphanedCMUXRemoteSSHCommand(
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

    private static func commandContainsDestination(_ command: String, destination: String) -> Bool {
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

    private static func pathHelperShellOutput() -> String {
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

    private static func which(_ executable: String) -> String? {
        for component in executableSearchPaths() {
            let candidate = (component as NSString).appendingPathComponent(executable)
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private static func findRepoRoot() -> URL? {
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

    private static func bestErrorLine(stderr: String, stdout: String = "") -> String? {
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

    private static func meaningfulErrorLine(in text: String) -> String? {
        let lines = text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for line in lines.reversed() where !isNoiseLine(line) {
            return line
        }
        return lines.last
    }

    private static func isNoiseLine(_ line: String) -> Bool {
        let lowered = line.lowercased()
        if lowered.hasPrefix("warning: permanently added") { return true }
        if lowered.hasPrefix("debug") { return true }
        if lowered.hasPrefix("transferred:") { return true }
        if lowered.hasPrefix("openbsd_") { return true }
        if lowered.contains("pseudo-terminal will not be allocated") { return true }
        return false
    }

    private static func retrySuffix(retry: Int, delay: TimeInterval) -> String {
        let seconds = max(1, Int(delay.rounded()))
        return " (retry \(retry) in \(seconds)s)"
    }

    private static func retryDelay(baseDelay: TimeInterval, retry: Int) -> TimeInterval {
        let exponent = Double(max(0, retry - 1))
        return min(baseDelay * pow(2.0, exponent), 60.0)
    }

    private static func shouldEscalateProxyErrorToBootstrap(_ detail: String) -> Bool {
        let lowered = detail.lowercased()
        return lowered.contains("remote daemon transport failed")
            || lowered.contains("daemon transport closed stdout")
            || lowered.contains("daemon transport exited")
            || lowered.contains("daemon transport is not connected")
            || lowered.contains("daemon transport stopped")
    }

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

    private func updateRemotePortScanTTYsLocked(_ ttyNames: [UUID: String]) {
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

    private func kickRemotePortScanLocked(panelId: UUID, reason: PortScanKickReason) {
        guard !isStopping else { return }
        guard daemonReady else { return }
        guard remotePortScanTTYNames[panelId] != nil else { return }
        if remotePortScanBurstActive, remotePortScanActiveReason == .command, reason == .refresh {
            return
        }
        remotePortScanPendingReason = remotePortScanPendingReason?.merged(with: reason) ?? reason
        scheduleRemotePortScanCoalesceLocked()
    }

    private func scheduleRemotePortScanCoalesceLocked() {
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

    private func runRemotePortScanBurstLocked(
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

    private func performRemotePortScanLocked() {
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

    private func scanRemotePortsByPanelLocked(ttyNamesByPanel: [UUID: String]) throws -> [UUID: [Int]] {
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

    private func startRemotePortPollingLocked(mode: RemotePortPollingMode) {
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

    private func stopRemotePortPollingLocked() {
        remotePortPollTimer?.setEventHandler {}
        remotePortPollTimer?.cancel()
        remotePortPollTimer = nil
        remotePortPollMode = nil
    }

    private func updateRemotePortPollingStateLocked() {
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

    private func pollRemotePortsLocked() {
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

    private func excludedRemoteScanPorts() -> Set<Int> {
        var excluded: Set<Int> = []
        if let relayPort = configuration.relayPort, relayPort > 0 {
            excluded.insert(relayPort)
        }
        if let configuredPort = configuration.port, configuredPort > 0 {
            excluded.insert(configuredPort)
        }
        return excluded
    }

    private func shouldUseFallbackRemotePortPollingLocked() -> Bool {
        // `cmux ssh` owns the remote shell bootstrap and can report the remote
        // TTY precisely. Falling back to host-wide port scans in that path leaks
        // unrelated listeners from the remote machine into the workspace card.
        let startupCommand = configuration.terminalStartupCommand?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return startupCommand?.isEmpty != false
    }

    private func shouldUseTTYFallbackRemotePortPollingLocked() -> Bool {
        // `cmux ssh` can still land in shells without our command hooks, such as
        // `/bin/sh` in the Docker fixture. Once the workspace knows the TTY,
        // keep a low-frequency TTY-scoped poll so unsupported shells still
        // surface ports without bringing back noisy host-wide scans.
        let startupCommand = configuration.terminalStartupCommand?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return startupCommand?.isEmpty == false
    }

    private func remotePortPollingModeLocked() -> RemotePortPollingMode? {
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

    private static func parseRemoteTTYPortPairs(output: String, trackedTTYNames: Set<String>) -> [String: [Int]] {
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

    private static func parseRemotePorts(output: String) -> [Int] {
        let values = output
            .split(whereSeparator: \.isWhitespace)
            .compactMap { Int($0) }
            .filter { $0 >= 1024 && $0 <= 65535 }
        return Array(Set(values)).sorted()
    }

    private static func normalizedRemotePortScanTTYName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.split(separator: "/").last.map(String.init) ?? trimmed
        guard !candidate.isEmpty else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard candidate.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return candidate
    }

    private static func remotePortScanScript(ttyNames: [String], excluding ports: Set<Int>) -> String {
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

    private static func remoteAllPortsScanScript(excluding ports: Set<Int>) -> String {
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

