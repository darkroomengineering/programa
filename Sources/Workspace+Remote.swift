// Extracted from Workspace.swift (nuclear-review #98): remote-connection glue members
// (configure/reconnect/disconnect/status plumbing).

import Foundation
import SwiftUI
import AppKit
import Bonsplit
import Combine
import CryptoKit
import Darwin
import Network
import CoreText

extension Workspace {
    var isRemoteWorkspace: Bool {
        remoteConfiguration != nil
    }

    @MainActor
    func isRemoteTerminalSurface(_ panelId: UUID) -> Bool {
        activeRemoteTerminalSurfaceIds.contains(panelId)
    }

    @MainActor
    func shouldDemoteWorkspaceAfterChildExit(surfaceId: UUID) -> Bool {
        isRemoteWorkspace || pendingRemoteTerminalChildExitSurfaceIds.contains(surfaceId)
    }

    var remoteDisplayTarget: String? {
        remoteConfiguration?.displayTarget
    }

    var hasActiveRemoteTerminalSessions: Bool {
        activeRemoteTerminalSessionCount > 0
    }

    @MainActor
    func uploadDroppedFilesForRemoteTerminal(
        _ fileURLs: [URL],
        operation: TerminalImageTransferOperation,
        completion: @escaping (Result<[String], Error>) -> Void
    ) {
        guard let controller = remoteSessionController else {
            completion(.failure(RemoteDropUploadError.unavailable))
            return
        }
        controller.uploadDroppedFiles(fileURLs, operation: operation, completion: completion)
    }

    @MainActor
    func uploadDroppedFilesForRemoteTerminal(
        _ fileURLs: [URL],
        completion: @escaping (Result<[String], Error>) -> Void
    ) {
        uploadDroppedFilesForRemoteTerminal(
            fileURLs,
            operation: TerminalImageTransferOperation(),
            completion: completion
        )
    }

    func syncRemotePortScanTTYs() {
        guard isRemoteWorkspace else { return }
        remoteSessionController?.updateRemotePortScanTTYs(surfaceTTYNames)
    }

    func kickRemotePortScan(panelId: UUID, reason: WorkspaceRemoteSessionController.PortScanKickReason = .command) {
        guard isRemoteWorkspace else { return }
        syncRemotePortScanTTYs()
        remoteSessionController?.kickRemotePortScan(panelId: panelId, reason: reason)
    }

    func remoteStatusPayload() -> [String: Any] {
        let heartbeatAgeSeconds: Any = {
            guard let last = remoteLastHeartbeatAt else { return NSNull() }
            return max(0, Date().timeIntervalSince(last))
        }()
        let heartbeatTimestamp: Any = {
            guard let last = remoteLastHeartbeatAt else { return NSNull() }
            return Self.remoteHeartbeatDateFormatter.string(from: last)
        }()
        var payload: [String: Any] = [
            "enabled": remoteConfiguration != nil,
            "state": remoteConnectionState.rawValue,
            "connected": remoteConnectionState == .connected,
            "active_terminal_sessions": activeRemoteTerminalSessionCount,
            "daemon": remoteDaemonStatus.payload(),
            "detected_ports": remoteDetectedPorts,
            "forwarded_ports": remoteForwardedPorts,
            "conflicted_ports": remotePortConflicts,
            "detail": remoteConnectionDetail ?? NSNull(),
            "heartbeat": [
                "count": remoteHeartbeatCount,
                "last_seen_at": heartbeatTimestamp,
                "age_seconds": heartbeatAgeSeconds,
            ],
        ]
        if let endpoint = remoteProxyEndpoint {
            payload["proxy"] = [
                "state": "ready",
                "host": endpoint.host,
                "port": endpoint.port,
                "schemes": ["socks5", "http_connect"],
                "url": "socks5://\(endpoint.host):\(endpoint.port)",
            ]
        } else {
            let proxyState: String
            if hasProxyOnlyRemoteSidebarError {
                proxyState = "error"
            } else {
                switch remoteConnectionState {
                case .connecting:
                    proxyState = "connecting"
                case .error:
                    proxyState = "error"
                default:
                    proxyState = "unavailable"
                }
            }
            payload["proxy"] = [
                "state": proxyState,
                "host": NSNull(),
                "port": NSNull(),
                "schemes": ["socks5", "http_connect"],
                "url": NSNull(),
                "error_code": proxyState == "error" ? "proxy_unavailable" : NSNull(),
            ]
        }
        if let remoteConfiguration {
            payload["destination"] = remoteConfiguration.destination
            payload["port"] = remoteConfiguration.port ?? NSNull()
            payload["has_identity_file"] = remoteConfiguration.identityFile != nil
            payload["has_ssh_options"] = !remoteConfiguration.sshOptions.isEmpty
            payload["local_proxy_port"] = remoteConfiguration.localProxyPort ?? NSNull()
        } else {
            payload["destination"] = NSNull()
            payload["port"] = NSNull()
            payload["has_identity_file"] = false
            payload["has_ssh_options"] = false
            payload["local_proxy_port"] = NSNull()
        }
        return payload
    }

    func configureRemoteConnection(_ configuration: WorkspaceRemoteConfiguration, autoConnect: Bool = true) {
        // Capture before resetRemoteState() nulls pendingRemoteForegroundAuthToken.
        let foregroundAuthToken = Self.normalizedForegroundAuthToken(configuration.foregroundAuthToken)
        let shouldAutoConnect =
            autoConnect
            || (foregroundAuthToken != nil && foregroundAuthToken == pendingRemoteForegroundAuthToken)

        remoteConfiguration = configuration
        resetRemoteState()
        // Seed after the reset so a reconfigure of an already-connected workspace doesn't see
        // stale per-panel bookkeeping from the previous destination and skip seeding. Refs #83.
        seedInitialRemoteTerminalSessionIfNeeded(configuration: configuration)
        recomputeListeningPorts()
        applyRemoteProxyEndpointUpdate(nil)
        applyBrowserRemoteWorkspaceStatusToPanels()

        guard shouldAutoConnect else {
            remoteConnectionState = .disconnected
            applyBrowserRemoteWorkspaceStatusToPanels()
            return
        }

        remoteConnectionState = .connecting
        applyBrowserRemoteWorkspaceStatusToPanels()
        let controllerID = UUID()
        let controller = WorkspaceRemoteSessionController(
            workspace: self,
            configuration: configuration,
            controllerID: controllerID
        )
        activeRemoteSessionControllerID = controllerID
        remoteSessionController = controller
        syncRemotePortScanTTYs()
        controller.start()
    }

    func reconnectRemoteConnection() {
        guard let configuration = remoteConfiguration else { return }
        configureRemoteConnection(configuration, autoConnect: true)
    }

    static func normalizedForegroundAuthToken(_ token: String?) -> String? {
        guard let token else { return nil }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func notifyRemoteForegroundAuthenticationReady(token: String? = nil) {
        guard let foregroundAuthToken = Self.normalizedForegroundAuthToken(token) else {
            return
        }

        guard let remoteConfiguration else {
            pendingRemoteForegroundAuthToken = foregroundAuthToken
            return
        }

        guard Self.normalizedForegroundAuthToken(remoteConfiguration.foregroundAuthToken) == foregroundAuthToken else {
            return
        }

        pendingRemoteForegroundAuthToken = nil
        guard remoteConnectionState == .disconnected else { return }
        reconnectRemoteConnection()
    }

    func disconnectRemoteConnection(clearConfiguration: Bool = false) {
        let shouldCleanupControlMaster =
            clearConfiguration
            && !isDetachingCloseTransaction
            && pendingDetachedSurfaces.isEmpty
            && !skipControlMasterCleanupAfterDetachedRemoteTransfer
        let configurationForCleanup = shouldCleanupControlMaster ? remoteConfiguration : nil
        resetRemoteState()
        remoteConnectionState = .disconnected
        if clearConfiguration {
            remoteConfiguration = nil
            skipControlMasterCleanupAfterDetachedRemoteTransfer = false
        }
        applyRemoteProxyEndpointUpdate(nil)
        applyBrowserRemoteWorkspaceStatusToPanels()
        recomputeListeningPorts()
        if let configurationForCleanup {
            Self.requestSSHControlMasterCleanupIfNeeded(configuration: configurationForCleanup)
        }
    }

    /// Resets all per-connection and per-panel remote-session bookkeeping. This is the
    /// complete union of what `configureRemoteConnection` and `disconnectRemoteConnection`
    /// each need to clear before establishing (or tearing down) a remote connection, so a
    /// reconfigure to a new destination can't leave stale state from the previous one. Refs #83.
    func resetRemoteState() {
        skipControlMasterCleanupAfterDetachedRemoteTransfer = false
        let previousController = remoteSessionController
        activeRemoteSessionControllerID = nil
        remoteSessionController = nil
        previousController?.stop()
        pendingRemoteForegroundAuthToken = nil
        activeRemoteTerminalSurfaceIds.removeAll()
        activeRemoteTerminalSessionCount = 0
        pendingRemoteSurfaceTTYName = nil
        pendingRemoteSurfaceTTYSurfaceId = nil
        pendingRemoteSurfacePortKickReason = nil
        pendingRemoteSurfacePortKickSurfaceId = nil
        clearRemoteDetectedSurfacePorts()
        remoteDetectedPorts = []
        remoteForwardedPorts = []
        remotePortConflicts = []
        remoteProxyEndpoint = nil
        remoteHeartbeatCount = 0
        remoteLastHeartbeatAt = nil
        remoteConnectionDetail = nil
        remoteDaemonStatus = WorkspaceRemoteDaemonStatus()
        statusEntries.removeValue(forKey: Self.remoteErrorStatusKey)
        statusEntries.removeValue(forKey: Self.remotePortConflictStatusKey)
        remoteLastErrorFingerprint = nil
        remoteLastDaemonErrorFingerprint = nil
        remoteLastPortConflictFingerprint = nil
    }

    func clearRemoteConfigurationIfWorkspaceBecameLocal() {
        guard !isDetachingCloseTransaction, panels.isEmpty, remoteConfiguration != nil else { return }
        disconnectRemoteConnection(clearConfiguration: true)
    }

    func seedInitialRemoteTerminalSessionIfNeeded(configuration: WorkspaceRemoteConfiguration) {
        guard configuration.terminalStartupCommand?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return
        }
        guard activeRemoteTerminalSurfaceIds.isEmpty else { return }
        let terminalIds = panels.compactMap { panelId, panel in
            panel is TerminalPanel ? panelId : nil
        }
        guard terminalIds.count == 1, let initialPanelId = terminalIds.first else { return }
        trackRemoteTerminalSurface(initialPanelId)
    }

    func trackRemoteTerminalSurface(_ panelId: UUID) {
        skipControlMasterCleanupAfterDetachedRemoteTransfer = false
        pendingRemoteTerminalChildExitSurfaceIds.remove(panelId)
        transferredRemoteCleanupConfigurationsByPanelId.removeValue(forKey: panelId)
        guard activeRemoteTerminalSurfaceIds.insert(panelId).inserted else { return }
        activeRemoteTerminalSessionCount = activeRemoteTerminalSurfaceIds.count
        applyPendingRemoteSurfaceTTYIfNeeded(to: panelId)
        _ = applyPendingRemoteSurfacePortKickIfNeeded(to: panelId)
    }

    func untrackRemoteTerminalSurface(_ panelId: UUID) {
        guard activeRemoteTerminalSurfaceIds.remove(panelId) != nil else { return }
        activeRemoteTerminalSessionCount = activeRemoteTerminalSurfaceIds.count
        guard !isDetachingCloseTransaction else { return }
        maybeDemoteRemoteWorkspaceAfterSSHSessionEnded()
    }

    func maybeDemoteRemoteWorkspaceAfterSSHSessionEnded() {
        guard activeRemoteTerminalSurfaceIds.isEmpty, remoteConfiguration != nil else { return }
        let hasBrowserPanels = panels.values.contains { $0 is BrowserPanel }
        if !hasBrowserPanels {
            if remoteConnectionState == .error || remoteDaemonStatus.state == .error || remoteConnectionState == .connecting {
                return
            }
            disconnectRemoteConnection(clearConfiguration: true)
        }
    }

    @MainActor
    func rememberPendingRemoteSurfaceTTY(_ ttyName: String, requestedSurfaceId: UUID?) {
        let trimmedTTY = ttyName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTTY.isEmpty else { return }
        pendingRemoteSurfaceTTYName = trimmedTTY
        pendingRemoteSurfaceTTYSurfaceId = requestedSurfaceId
    }

    @MainActor
    func rememberPendingRemoteSurfacePortKick(
        reason: WorkspaceRemoteSessionController.PortScanKickReason,
        requestedSurfaceId: UUID?
    ) {
        pendingRemoteSurfacePortKickReason = reason
        pendingRemoteSurfacePortKickSurfaceId = requestedSurfaceId
    }

    @MainActor
    func applyPendingRemoteSurfaceTTYIfNeeded(to panelId: UUID) {
        guard let ttyName = pendingRemoteSurfaceTTYName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !ttyName.isEmpty else {
            return
        }
        if let requestedSurfaceId = pendingRemoteSurfaceTTYSurfaceId, requestedSurfaceId != panelId {
            return
        }
        surfaceTTYNames[panelId] = ttyName
        pendingRemoteSurfaceTTYName = nil
        pendingRemoteSurfaceTTYSurfaceId = nil
        syncRemotePortScanTTYs()
        if !applyPendingRemoteSurfacePortKickIfNeeded(to: panelId) {
            kickRemotePortScan(panelId: panelId, reason: .command)
        }
    }

    @MainActor
    @discardableResult
    func applyPendingRemoteSurfacePortKickIfNeeded(to panelId: UUID) -> Bool {
        guard let reason = pendingRemoteSurfacePortKickReason else {
            return false
        }
        if let requestedSurfaceId = pendingRemoteSurfacePortKickSurfaceId,
           requestedSurfaceId != panelId {
            return false
        }
        guard let ttyName = surfaceTTYNames[panelId]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !ttyName.isEmpty else {
            return false
        }
        _ = ttyName
        pendingRemoteSurfacePortKickReason = nil
        pendingRemoteSurfacePortKickSurfaceId = nil
        kickRemotePortScan(panelId: panelId, reason: reason)
        return true
    }

    @MainActor
    func applyBootstrapRemoteTTY(_ ttyName: String) {
        let trimmedTTY = ttyName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTTY.isEmpty else { return }

        let candidateSurfaceId: UUID? = {
            if let focusedPanelId, activeRemoteTerminalSurfaceIds.contains(focusedPanelId) {
                return focusedPanelId
            }
            if activeRemoteTerminalSurfaceIds.count == 1 {
                return activeRemoteTerminalSurfaceIds.first
            }
            return nil
        }()

        guard let candidateSurfaceId else {
            rememberPendingRemoteSurfaceTTY(trimmedTTY, requestedSurfaceId: nil)
            return
        }

        surfaceTTYNames[candidateSurfaceId] = trimmedTTY
        syncRemotePortScanTTYs()
        if !applyPendingRemoteSurfacePortKickIfNeeded(to: candidateSurfaceId) {
            kickRemotePortScan(panelId: candidateSurfaceId, reason: .command)
        }
    }

    func cleanupTransferredRemoteConnectionIfNeeded(surfaceId: UUID, relayPort: Int?) -> Bool {
        guard let relayPort,
              relayPort > 0,
              let cleanupConfiguration = transferredRemoteCleanupConfigurationsByPanelId[surfaceId],
              cleanupConfiguration.relayPort == relayPort else {
            return false
        }
        transferredRemoteCleanupConfigurationsByPanelId.removeValue(forKey: surfaceId)
        Self.requestSSHControlMasterCleanupIfNeeded(configuration: cleanupConfiguration)
        return true
    }

    func markRemoteTerminalSessionEnded(surfaceId: UUID, relayPort: Int?) {
        if cleanupTransferredRemoteConnectionIfNeeded(surfaceId: surfaceId, relayPort: relayPort) {
            return
        }
        guard let relayPort,
              relayPort > 0,
              remoteConfiguration?.relayPort == relayPort else {
            return
        }
        pendingRemoteTerminalChildExitSurfaceIds.insert(surfaceId)
        untrackRemoteTerminalSurface(surfaceId)
    }

    func teardownRemoteConnection() {
        disconnectRemoteConnection(clearConfiguration: true)
    }

    static func requestSSHControlMasterCleanupIfNeeded(configuration: WorkspaceRemoteConfiguration) {
        guard let arguments = sshControlMasterCleanupArguments(configuration: configuration) else { return }
        if let override = runSSHControlMasterCommandOverrideForTesting {
            override(arguments)
            return
        }

        sshControlMasterCleanupQueue.async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            let exitSemaphore = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in
                exitSemaphore.signal()
            }

            do {
                try process.run()
                if exitSemaphore.wait(timeout: .now() + 5) == .timedOut {
                    if process.isRunning {
                        process.terminate()
                    }
                    _ = exitSemaphore.wait(timeout: .now() + 1)
                }
            } catch {
                return
            }
        }
    }

    static func sshControlMasterCleanupArguments(configuration: WorkspaceRemoteConfiguration) -> [String]? {
        let sshOptions = normalizedSSHControlCleanupOptions(configuration.sshOptions)
        var arguments: [String] = [
            "-o", "BatchMode=yes",
            "-o", "ControlMaster=no",
        ]
        if let port = configuration.port {
            arguments += ["-p", String(port)]
        }
        if let identityFile = configuration.identityFile?.trimmingCharacters(in: .whitespacesAndNewlines),
           !identityFile.isEmpty {
            arguments += ["-i", identityFile]
        }
        for option in sshOptions {
            arguments += ["-o", option]
        }
        arguments += ["-O", "exit", configuration.destination]
        return arguments
    }

    static func normalizedSSHControlCleanupOptions(_ options: [String]) -> [String] {
        let disallowedKeys: Set<String> = ["controlmaster", "controlpersist"]
        return options.compactMap { option in
            let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            guard let key = sshOptionKeyForControlCleanup(trimmed) else { return nil }
            return disallowedKeys.contains(key) ? nil : trimmed
        }
    }

    static func sshOptionKeyForControlCleanup(_ option: String) -> String? {
        let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
            .split(whereSeparator: { $0 == "=" || $0.isWhitespace })
            .first
            .map(String.init)?
            .lowercased()
    }

    func applyRemoteConnectionStateUpdate(
        _ state: WorkspaceRemoteConnectionState,
        detail: String?,
        target: String
    ) {
        let trimmedDetail = detail?.trimmingCharacters(in: .whitespacesAndNewlines)
        let proxyOnlyError = trimmedDetail.map(Self.isProxyOnlyRemoteError) ?? false
        let preserveConnectedStateForRetry =
            state == .connecting && preservesSSHTerminalConnection && hasProxyOnlyRemoteSidebarError
        let effectiveState: WorkspaceRemoteConnectionState
        if state == .error && proxyOnlyError && preservesSSHTerminalConnection {
            effectiveState = .connected
        } else if preserveConnectedStateForRetry {
            effectiveState = .connected
        } else {
            effectiveState = state
        }

        remoteConnectionState = effectiveState
        remoteConnectionDetail = detail
        applyBrowserRemoteWorkspaceStatusToPanels()

        if let trimmedDetail, !trimmedDetail.isEmpty, (state == .error || proxyOnlyError) {
            let statusPrefix = proxyOnlyError ? "Remote proxy unavailable" : "SSH error"
            let statusIcon = proxyOnlyError ? "exclamationmark.triangle.fill" : "network.slash"
            let notificationTitle = proxyOnlyError ? "Remote Proxy Unavailable" : "Remote SSH Error"
            let logSource = proxyOnlyError ? "remote-proxy" : "remote"
            statusEntries[Self.remoteErrorStatusKey] = SidebarStatusEntry(
                key: Self.remoteErrorStatusKey,
                value: "\(statusPrefix) (\(target)): \(trimmedDetail)",
                icon: statusIcon,
                color: nil,
                timestamp: Date()
            )

            let fingerprint = "connection:\(trimmedDetail)"
            if remoteLastErrorFingerprint != fingerprint {
                remoteLastErrorFingerprint = fingerprint
                appendSidebarLog(
                    message: "\(statusPrefix) (\(target)): \(trimmedDetail)",
                    level: .error,
                    source: logSource
                )
                AppDelegate.shared?.notificationStore?.addNotification(
                    tabId: id,
                    surfaceId: nil,
                    title: notificationTitle,
                    subtitle: target,
                    body: trimmedDetail,
                    cooldownKey: remoteNotificationCooldownKey(target: target),
                    cooldownInterval: Self.remoteNotificationCooldown
                )
            }
            return
        }

        if state == .connected {
            statusEntries.removeValue(forKey: Self.remoteErrorStatusKey)
            remoteLastErrorFingerprint = nil
        }
    }

    func applyRemoteDaemonStatusUpdate(_ status: WorkspaceRemoteDaemonStatus, target: String) {
        remoteDaemonStatus = status
        applyBrowserRemoteWorkspaceStatusToPanels()
        guard status.state == .error else {
            remoteLastDaemonErrorFingerprint = nil
            return
        }
        let trimmedDetail = status.detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "remote daemon error"
        let fingerprint = "daemon:\(trimmedDetail)"
        guard remoteLastDaemonErrorFingerprint != fingerprint else { return }
        remoteLastDaemonErrorFingerprint = fingerprint
        appendSidebarLog(
            message: "Remote daemon error (\(target)): \(trimmedDetail)",
            level: .error,
            source: "remote-daemon"
        )
    }

    func applyRemoteProxyEndpointUpdate(_ endpoint: BrowserProxyEndpoint?) {
        remoteProxyEndpoint = endpoint
        for panel in panels.values {
            guard let browserPanel = panel as? BrowserPanel else { continue }
            browserPanel.setRemoteProxyEndpoint(endpoint)
        }
        applyBrowserRemoteWorkspaceStatusToPanels()
    }

    func applyRemoteHeartbeatUpdate(count: Int, lastSeenAt: Date?) {
        remoteHeartbeatCount = max(0, count)
        remoteLastHeartbeatAt = lastSeenAt
        applyBrowserRemoteWorkspaceStatusToPanels()
    }

    func applyRemoteDetectedSurfacePortsSnapshot(
        detectedByPanel: [UUID: [Int]],
        detected: [Int],
        forwarded: [Int],
        conflicts: [Int],
        target: String
    ) {
        let trackedSurfaceIds = Set(detectedByPanel.keys)
        for panelId in remoteDetectedSurfaceIds.subtracting(trackedSurfaceIds) {
            surfaceListeningPorts.removeValue(forKey: panelId)
        }
        remoteDetectedSurfaceIds = trackedSurfaceIds

        for (panelId, ports) in detectedByPanel {
            if ports.isEmpty {
                surfaceListeningPorts.removeValue(forKey: panelId)
            } else {
                surfaceListeningPorts[panelId] = ports
            }
        }

        remoteDetectedPorts = detected
        remoteForwardedPorts = forwarded
        remotePortConflicts = conflicts
        recomputeListeningPorts()

        if conflicts.isEmpty {
            statusEntries.removeValue(forKey: Self.remotePortConflictStatusKey)
            remoteLastPortConflictFingerprint = nil
            return
        }

        let conflictsList = conflicts.map { ":\($0)" }.joined(separator: ", ")
        statusEntries[Self.remotePortConflictStatusKey] = SidebarStatusEntry(
            key: Self.remotePortConflictStatusKey,
            value: "SSH port conflicts (\(target)): \(conflictsList)",
            icon: "exclamationmark.triangle.fill",
            color: nil,
            timestamp: Date()
        )

        let fingerprint = conflicts.map(String.init).joined(separator: ",")
        guard remoteLastPortConflictFingerprint != fingerprint else { return }
        remoteLastPortConflictFingerprint = fingerprint
        appendSidebarLog(
            message: "Port conflicts while forwarding \(target): \(conflictsList)",
            level: .warning,
            source: "remote-forward"
        )
    }

    func clearRemoteDetectedSurfacePorts() {
        for panelId in remoteDetectedSurfaceIds {
            surfaceListeningPorts.removeValue(forKey: panelId)
        }
        remoteDetectedSurfaceIds.removeAll()
    }
}
