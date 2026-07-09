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

    struct RetrySchedule {
        let retry: Int
        let delay: TimeInterval
    }

    struct CommandResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    struct RemotePlatform {
        let goOS: String
        let goArch: String
    }

    struct RemoteBootstrapState {
        let platform: RemotePlatform
        let binaryExists: Bool
    }

    struct DaemonHello {
        let name: String
        let version: String
        let capabilities: [String]
        let remotePath: String
    }

    let queue = DispatchQueue(label: "com.cmux.remote-ssh.\(UUID().uuidString)", qos: .utility)
    let queueKey = DispatchSpecificKey<Void>()
    weak var workspace: Workspace?
    let configuration: WorkspaceRemoteConfiguration
    let controllerID: UUID

    enum RemotePortPollingMode {
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

    var isStopping = false
    var proxyLease: WorkspaceRemoteProxyBroker.Lease?
    var proxyEndpoint: BrowserProxyEndpoint?
    var daemonReady = false
    var daemonBootstrapVersion: String?
    var daemonRemotePath: String?
    var reverseRelayProcess: Process?
    var reverseRelayControlMasterForwardSpec: String?
    var cliRelayServer: WorkspaceRemoteCLIRelayServer?
    var remotePortScanTTYNames: [UUID: String] = [:]
    var remoteScannedPortsByPanel: [UUID: [Int]] = [:]
    var remotePortScanBurstActive = false
    var remotePortScanActiveReason: PortScanKickReason?
    var remotePortScanPendingReason: PortScanKickReason?
    var remotePortScanGeneration: UInt64 = 0
    var remotePortScanCoalesceWorkItem: DispatchWorkItem?
    var remotePortPollTimer: DispatchSourceTimer?
    var remotePortPollMode: RemotePortPollingMode?
    var polledRemotePorts: [Int] = []
    var remotePortPollBaselinePorts: Set<Int>?
    var keepPolledRemotePortsUntilTTYScan = false
    var bootstrapRemoteTTYResolved = false
    var bootstrapRemoteTTYRetryWorkItem: DispatchWorkItem?
    var bootstrapRemoteTTYFetchInFlight = false
    var bootstrapRemoteTTYRetryCount = 0
    var reverseRelayStderrPipe: Pipe?
    var reverseRelayRestartWorkItem: DispatchWorkItem?
    var reverseRelayStderrBuffer = ""
    var reconnectRetryCount = 0
    var reconnectWorkItem: DispatchWorkItem?
    var heartbeatCount: Int = 0
    var connectionAttemptStartedAt: Date?

    static let reverseRelayStartupGracePeriod: TimeInterval = 0.5

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

}
