// Extracted from WorkspaceRemoteDaemon.swift (nuclear-review #98): the local<->remote proxy tunnel and its broker.

import Foundation
import SwiftUI
import AppKit
import Bonsplit
import Combine
import CryptoKit
import Darwin
import Network
import CoreText

struct WorkspaceRemoteLoopbackProxyRoute: Equatable {
    let targetHost: String
    let rewriteAliasHost: String?
}

/// Resolves the host contract used by the live proxy session. This is intentionally
/// factored out as a small runtime seam so browser URL rewriting and proxy routing
/// can be regression-tested together.
func workspaceRemoteLoopbackProxyRoute(for host: String) -> WorkspaceRemoteLoopbackProxyRoute {
    let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalized = trimmed
        .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        .lowercased()
    let recognizedAliasHost = "programa-loopback.localtest.me"
    if normalized == recognizedAliasHost {
        return WorkspaceRemoteLoopbackProxyRoute(
            targetHost: "127.0.0.1",
            rewriteAliasHost: recognizedAliasHost
        )
    }
    return WorkspaceRemoteLoopbackProxyRoute(targetHost: host, rewriteAliasHost: nil)
}

private final class WorkspaceRemoteDaemonProxyTunnel {
    private final class ProxySession {
        private static let maxHandshakeBytes = 64 * 1024

        private enum HandshakeProtocol {
            case undecided
            case socks5
            case connect
        }

        private enum SocksStage {
            case greeting
            case request
        }

        private struct SocksRequest {
            let host: String
            let port: Int
            let command: UInt8
            let consumedBytes: Int
        }

        let id = UUID()

        private let connection: NWConnection
        private let rpcClient: WorkspaceRemoteDaemonRPCClient
        private let queue: DispatchQueue
        private let onClose: (UUID) -> Void

        private var isClosed = false
        private var protocolKind: HandshakeProtocol = .undecided
        private var socksStage: SocksStage = .greeting
        private var handshakeBuffer = Data()
        private var streamID: String?
        private var localInputEOF = false
        private var rewritesLoopbackHTTPHeaders = false
        private var loopbackRewriteAliasHost: String?
        private var loopbackRequestHeaderRewriter: RemoteLoopbackHTTPRequestStreamRewriter?
        private var pendingRemoteHTTPHeaderBytes = Data()
        private var hasForwardedRemoteHTTPHeaders = false

        init(
            connection: NWConnection,
            rpcClient: WorkspaceRemoteDaemonRPCClient,
            queue: DispatchQueue,
            onClose: @escaping (UUID) -> Void
        ) {
            self.connection = connection
            self.rpcClient = rpcClient
            self.queue = queue
            self.onClose = onClose
        }

        func start() {
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .failed(let error):
                    self.close(reason: "proxy client connection failed: \(error)")
                case .cancelled:
                    self.close(reason: nil)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            receiveNext()
        }

        func stop() {
            close(reason: nil)
        }

        private func receiveNext() {
            guard !isClosed else { return }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 32768) { [weak self] data, _, isComplete, error in
                guard let self, !self.isClosed else { return }

                if let data, !data.isEmpty {
                    if self.streamID == nil {
                        if self.handshakeBuffer.count + data.count > Self.maxHandshakeBytes {
                            self.close(reason: "proxy handshake exceeded \(Self.maxHandshakeBytes) bytes")
                            return
                        }
                        self.handshakeBuffer.append(data)
                        self.processHandshakeBuffer()
                    } else {
                        self.forwardToRemote(data, eof: isComplete)
                    }
                }

                if isComplete {
                    // Treat local EOF as a half-close: keep remote read loop alive so we can
                    // drain upstream response bytes (for example curl closing write-side after
                    // sending an HTTP request through SOCKS/CONNECT).
                    self.localInputEOF = true
                    if self.streamID != nil, data?.isEmpty ?? true {
                        self.forwardToRemote(Data(), eof: true, allowAfterEOF: true)
                    }
                    if self.streamID == nil {
                        self.close(reason: nil)
                    }
                    return
                }
                if let error {
                    self.close(reason: "proxy client receive error: \(error)")
                    return
                }

                self.receiveNext()
            }
        }

        private func processHandshakeBuffer() {
            guard !isClosed else { return }
            while streamID == nil {
                switch protocolKind {
                case .undecided:
                    guard let first = handshakeBuffer.first else { return }
                    protocolKind = (first == 0x05) ? .socks5 : .connect
                case .socks5:
                    if !processSocksHandshakeStep() {
                        return
                    }
                case .connect:
                    if !processConnectHandshakeStep() {
                        return
                    }
                }
            }
        }

        private func processSocksHandshakeStep() -> Bool {
            switch socksStage {
            case .greeting:
                guard handshakeBuffer.count >= 2 else { return false }
                let methodCount = Int(handshakeBuffer[1])
                let total = 2 + methodCount
                guard handshakeBuffer.count >= total else { return false }

                let methods = [UInt8](handshakeBuffer[2..<total])
                handshakeBuffer = Data(handshakeBuffer.dropFirst(total))
                socksStage = .request

                if !methods.contains(0x00) {
                    sendAndClose(Data([0x05, 0xFF]))
                    return false
                }
                sendLocal(Data([0x05, 0x00]))
                return true

            case .request:
                let request: SocksRequest
                do {
                    guard let parsed = try parseSocksRequest(from: handshakeBuffer) else { return false }
                    request = parsed
                } catch {
                    sendAndClose(Data([0x05, 0x01, 0x00, 0x01, 0, 0, 0, 0, 0, 0]))
                    return false
                }

                let pending = handshakeBuffer.count > request.consumedBytes
                    ? Data(handshakeBuffer[request.consumedBytes...])
                    : Data()
                handshakeBuffer = Data()
                guard request.command == 0x01 else {
                    sendAndClose(Data([0x05, 0x07, 0x00, 0x01, 0, 0, 0, 0, 0, 0]))
                    return false
                }

                openRemoteStream(
                    host: request.host,
                    port: request.port,
                    successResponse: Data([0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]),
                    failureResponse: Data([0x05, 0x05, 0x00, 0x01, 0, 0, 0, 0, 0, 0]),
                    pendingPayload: pending
                )
                return false
            }
        }

        private func parseSocksRequest(from data: Data) throws -> SocksRequest? {
            let bytes = [UInt8](data)
            guard bytes.count >= 4 else { return nil }
            guard bytes[0] == 0x05 else {
                throw NSError(domain: "programa.remote.proxy", code: 1, userInfo: [NSLocalizedDescriptionKey: "invalid SOCKS version"])
            }

            let command = bytes[1]
            let addressType = bytes[3]
            var cursor = 4
            let host: String

            switch addressType {
            case 0x01:
                guard bytes.count >= cursor + 4 + 2 else { return nil }
                let octets = bytes[cursor..<(cursor + 4)].map { String($0) }
                host = octets.joined(separator: ".")
                cursor += 4

            case 0x03:
                guard bytes.count >= cursor + 1 else { return nil }
                let length = Int(bytes[cursor])
                cursor += 1
                guard bytes.count >= cursor + length + 2 else { return nil }
                let hostData = Data(bytes[cursor..<(cursor + length)])
                host = String(data: hostData, encoding: .utf8) ?? ""
                cursor += length

            case 0x04:
                guard bytes.count >= cursor + 16 + 2 else { return nil }
                var address = in6_addr()
                withUnsafeMutableBytes(of: &address) { target in
                    for i in 0..<16 {
                        target[i] = bytes[cursor + i]
                    }
                }
                var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                let pointer = withUnsafePointer(to: &address) {
                    inet_ntop(AF_INET6, UnsafeRawPointer($0), &text, socklen_t(INET6_ADDRSTRLEN))
                }
                host = pointer != nil ? String(cString: text) : ""
                cursor += 16

            default:
                throw NSError(domain: "programa.remote.proxy", code: 2, userInfo: [NSLocalizedDescriptionKey: "invalid SOCKS address type"])
            }

            guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw NSError(domain: "programa.remote.proxy", code: 3, userInfo: [NSLocalizedDescriptionKey: "empty SOCKS host"])
            }
            guard bytes.count >= cursor + 2 else { return nil }
            let port = Int(UInt16(bytes[cursor]) << 8 | UInt16(bytes[cursor + 1]))
            cursor += 2

            guard port > 0 && port <= 65535 else {
                throw NSError(domain: "programa.remote.proxy", code: 4, userInfo: [NSLocalizedDescriptionKey: "invalid SOCKS port"])
            }

            return SocksRequest(host: host, port: port, command: command, consumedBytes: cursor)
        }

        private func processConnectHandshakeStep() -> Bool {
            let marker = Data([0x0D, 0x0A, 0x0D, 0x0A])
            guard let headerRange = handshakeBuffer.range(of: marker) else { return false }

            let headerData = Data(handshakeBuffer[..<headerRange.upperBound])
            let pending = headerRange.upperBound < handshakeBuffer.count
                ? Data(handshakeBuffer[headerRange.upperBound...])
                : Data()
            handshakeBuffer = Data()
            guard let headerText = String(data: headerData, encoding: .utf8) else {
                sendAndClose(Self.httpResponse(status: "400 Bad Request"))
                return false
            }

            let firstLine = headerText.components(separatedBy: "\r\n").first ?? ""
            let parts = firstLine.split(whereSeparator: \.isWhitespace).map(String.init)
            guard parts.count >= 2, parts[0].uppercased() == "CONNECT" else {
                sendAndClose(Self.httpResponse(status: "400 Bad Request"))
                return false
            }

            guard let (host, port) = Self.parseConnectAuthority(parts[1]) else {
                sendAndClose(Self.httpResponse(status: "400 Bad Request"))
                return false
            }

            openRemoteStream(
                host: host,
                port: port,
                successResponse: Self.httpResponse(status: "200 Connection Established", closeAfterResponse: false),
                failureResponse: Self.httpResponse(status: "502 Bad Gateway", closeAfterResponse: true),
                pendingPayload: pending
            )
            return false
        }

        private func openRemoteStream(
            host: String,
            port: Int,
            successResponse: Data,
            failureResponse: Data,
            pendingPayload: Data
        ) {
            guard !isClosed else { return }
            do {
                let route = workspaceRemoteLoopbackProxyRoute(for: host)
                rewritesLoopbackHTTPHeaders = route.rewriteAliasHost != nil
                loopbackRewriteAliasHost = route.rewriteAliasHost
                if let rewriteAliasHost = route.rewriteAliasHost {
                    loopbackRequestHeaderRewriter = RemoteLoopbackHTTPRequestStreamRewriter(
                        aliasHost: rewriteAliasHost
                    )
                } else {
                    loopbackRequestHeaderRewriter = nil
                }
                pendingRemoteHTTPHeaderBytes = Data()
                hasForwardedRemoteHTTPHeaders = false
                let streamID = try rpcClient.openStream(host: route.targetHost, port: port)
                self.streamID = streamID
                try rpcClient.attachStream(streamID: streamID, queue: queue) { [weak self] event in
                    self?.handleRemoteStreamEvent(streamID: streamID, event: event)
                }
                connection.send(content: successResponse, completion: .contentProcessed { [weak self] error in
                    guard let self else { return }
                    if let error {
                        self.close(reason: "proxy client send error: \(error)")
                        return
                    }
                    if !pendingPayload.isEmpty {
                        self.forwardToRemote(pendingPayload, allowAfterEOF: true)
                    }
                })
            } catch {
                sendAndClose(failureResponse)
            }
        }

        private func forwardToRemote(_ data: Data, eof: Bool = false, allowAfterEOF: Bool = false) {
            guard !isClosed else { return }
            guard !localInputEOF || allowAfterEOF else { return }
            guard let streamID else { return }
            do {
                let outgoingData: Data
                if rewritesLoopbackHTTPHeaders {
                    outgoingData = loopbackRequestHeaderRewriter?.rewriteNextChunk(data, eof: eof) ?? data
                } else {
                    outgoingData = data
                }
                guard !outgoingData.isEmpty else { return }
                try rpcClient.writeStream(streamID: streamID, data: outgoingData)
            } catch {
                close(reason: "proxy.write failed: \(error.localizedDescription)")
            }
        }

        private func handleRemoteStreamEvent(
            streamID: String,
            event: WorkspaceRemoteDaemonRPCClient.StreamEvent
        ) {
            guard !isClosed else { return }
            guard self.streamID == streamID else { return }

            switch event {
            case .data(let data):
                forwardRemotePayloadToLocal(data, eof: false)

            case .eof(let data):
                forwardRemotePayloadToLocal(data, eof: true)

            case .error(let detail):
                close(reason: "proxy.stream failed: \(detail)")
            }
        }

        private func forwardRemotePayloadToLocal(_ data: Data, eof: Bool) {
            let localData = rewriteRemoteResponseIfNeeded(data, eof: eof)
            if !localData.isEmpty {
                connection.send(content: localData, completion: .contentProcessed { [weak self] error in
                    guard let self else { return }
                    if let error {
                        self.close(reason: "proxy client send error: \(error)")
                        return
                    }
                    if eof {
                        self.close(reason: nil)
                    }
                })
                return
            }

            if eof {
                close(reason: nil)
            }
        }

        private func rewriteRemoteResponseIfNeeded(_ data: Data, eof: Bool) -> Data {
            guard rewritesLoopbackHTTPHeaders else { return data }
            guard !data.isEmpty else { return data }
            guard !hasForwardedRemoteHTTPHeaders else { return data }

            pendingRemoteHTTPHeaderBytes.append(data)
            let marker = Data([0x0D, 0x0A, 0x0D, 0x0A])
            guard pendingRemoteHTTPHeaderBytes.range(of: marker) != nil else {
                guard eof else { return Data() }
                hasForwardedRemoteHTTPHeaders = true
                let payload = pendingRemoteHTTPHeaderBytes
                pendingRemoteHTTPHeaderBytes = Data()
                return payload
            }

            hasForwardedRemoteHTTPHeaders = true
            let payload = pendingRemoteHTTPHeaderBytes
            pendingRemoteHTTPHeaderBytes = Data()
            guard let rewriteAliasHost = loopbackRewriteAliasHost else {
                return payload
            }
            return RemoteLoopbackHTTPResponseRewriter.rewriteIfNeeded(
                data: payload,
                aliasHost: rewriteAliasHost
            )
        }

        private func close(reason: String?) {
            guard !isClosed else { return }
            isClosed = true

            let streamID = self.streamID
            self.streamID = nil

            if let streamID {
                rpcClient.closeStream(streamID: streamID)
            }
            connection.cancel()
            onClose(id)
        }

        private func sendLocal(_ data: Data) {
            guard !isClosed else { return }
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if let error {
                    self.close(reason: "proxy client send error: \(error)")
                }
            })
        }

        private func sendAndClose(_ data: Data) {
            guard !isClosed else { return }
            connection.send(content: data, completion: .contentProcessed { [weak self] _ in
                self?.close(reason: nil)
            })
        }

        private static func parseConnectAuthority(_ authority: String) -> (host: String, port: Int)? {
            let trimmed = authority.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }

            if trimmed.hasPrefix("[") {
                guard let closing = trimmed.firstIndex(of: "]") else { return nil }
                let host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<closing])
                let portStart = trimmed.index(after: closing)
                guard portStart < trimmed.endIndex, trimmed[portStart] == ":" else { return nil }
                let portString = String(trimmed[trimmed.index(after: portStart)...])
                guard let port = Int(portString), port > 0, port <= 65535 else { return nil }
                return (host, port)
            }

            guard let colon = trimmed.lastIndex(of: ":") else { return nil }
            let host = String(trimmed[..<colon])
            let portString = String(trimmed[trimmed.index(after: colon)...])
            guard !host.isEmpty else { return nil }
            guard let port = Int(portString), port > 0, port <= 65535 else { return nil }
            return (host, port)
        }

        private static func httpResponse(status: String, closeAfterResponse: Bool = true) -> Data {
            var text = "HTTP/1.1 \(status)\r\nProxy-Agent: cmux\r\n"
            if closeAfterResponse {
                text += "Connection: close\r\n"
            }
            text += "\r\n"
            return Data(text.utf8)
        }
    }

    private let configuration: WorkspaceRemoteConfiguration
    private let remotePath: String
    private let localPort: Int
    private let onFatalError: (String) -> Void
    private let queue = DispatchQueue(label: "com.cmux.remote-ssh.daemon-tunnel.\(UUID().uuidString)", qos: .utility)

    private var listener: NWListener?
    private var rpcClient: WorkspaceRemoteDaemonRPCClient?
    private var sessions: [UUID: ProxySession] = [:]
    private var isStopped = false

    init(
        configuration: WorkspaceRemoteConfiguration,
        remotePath: String,
        localPort: Int,
        onFatalError: @escaping (String) -> Void
    ) {
        self.configuration = configuration
        self.remotePath = remotePath
        self.localPort = localPort
        self.onFatalError = onFatalError
    }

    func start() throws {
        var capturedError: Error?
        queue.sync {
            guard !isStopped else {
                capturedError = NSError(domain: "programa.remote.proxy", code: 20, userInfo: [
                    NSLocalizedDescriptionKey: "proxy tunnel already stopped",
                ])
                return
            }
            do {
                let client = WorkspaceRemoteDaemonRPCClient(
                    configuration: configuration,
                    remotePath: remotePath
                ) { [weak self] detail in
                    self?.queue.async {
                        self?.failLocked("Remote daemon transport failed: \(detail)")
                    }
                }
                try client.start()

                let listener = try Self.makeLoopbackListener(port: localPort)
                listener.newConnectionHandler = { [weak self] connection in
                    self?.queue.async {
                        self?.acceptConnectionLocked(connection)
                    }
                }
                listener.stateUpdateHandler = { [weak self] state in
                    self?.queue.async {
                        self?.handleListenerStateLocked(state)
                    }
                }

                self.rpcClient = client
                self.listener = listener
                listener.start(queue: queue)
            } catch {
                capturedError = error
                stopLocked(notify: false)
            }
        }
        if let capturedError {
            throw capturedError
        }
    }

    func stop() {
        queue.sync {
            stopLocked(notify: false)
        }
    }

    private func handleListenerStateLocked(_ state: NWListener.State) {
        guard !isStopped else { return }
        switch state {
        case .failed(let error):
            failLocked("Local proxy listener failed: \(error)")
        default:
            break
        }
    }

    private func acceptConnectionLocked(_ connection: NWConnection) {
        guard !isStopped else {
            connection.cancel()
            return
        }
        guard let rpcClient else {
            connection.cancel()
            return
        }

        let session = ProxySession(
            connection: connection,
            rpcClient: rpcClient,
            queue: queue
        ) { [weak self] id in
            self?.queue.async {
                self?.sessions.removeValue(forKey: id)
            }
        }
        sessions[session.id] = session
        session.start()
    }

    private func failLocked(_ detail: String) {
        guard !isStopped else { return }
        stopLocked(notify: false)
        onFatalError(detail)
    }

    private func stopLocked(notify: Bool) {
        guard !isStopped else { return }
        isStopped = true

        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil

        let activeSessions = sessions.values
        sessions.removeAll()
        for session in activeSessions {
            session.stop()
        }

        rpcClient?.stop()
        rpcClient = nil
    }

    private static func makeLoopbackListener(port: Int) throws -> NWListener {
        guard let localPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw NSError(domain: "programa.remote.proxy", code: 21, userInfo: [
                NSLocalizedDescriptionKey: "invalid local proxy port \(port)",
            ])
        }
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host("127.0.0.1"), port: localPort)
        return try NWListener(using: parameters)
    }
}

final class WorkspaceRemoteProxyBroker {
    enum Update {
        case connecting
        case ready(BrowserProxyEndpoint)
        case error(String)
    }

    final class Lease {
        private let key: String
        private let subscriberID: UUID
        private weak var broker: WorkspaceRemoteProxyBroker?
        private var isReleased = false

        fileprivate init(key: String, subscriberID: UUID, broker: WorkspaceRemoteProxyBroker) {
            self.key = key
            self.subscriberID = subscriberID
            self.broker = broker
        }

        func release() {
            guard !isReleased else { return }
            isReleased = true
            broker?.release(key: key, subscriberID: subscriberID)
        }

        deinit {
            release()
        }
    }

    private final class Entry {
        let configuration: WorkspaceRemoteConfiguration
        var remotePath: String
        var tunnel: WorkspaceRemoteDaemonProxyTunnel?
        var endpoint: BrowserProxyEndpoint?
        var restartWorkItem: DispatchWorkItem?
        var restartRetryCount = 0
        var subscribers: [UUID: (Update) -> Void] = [:]

        init(configuration: WorkspaceRemoteConfiguration, remotePath: String) {
            self.configuration = configuration
            self.remotePath = remotePath
        }
    }

    static let shared = WorkspaceRemoteProxyBroker()

    private let queue = DispatchQueue(label: "com.cmux.remote-ssh.proxy-broker", qos: .utility)
    private var entries: [String: Entry] = [:]

    func acquire(
        configuration: WorkspaceRemoteConfiguration,
        remotePath: String,
        onUpdate: @escaping (Update) -> Void
    ) -> Lease {
        queue.sync {
            let key = Self.transportKey(for: configuration)
            let subscriberID = UUID()
            let entry: Entry
            if let existing = entries[key] {
                entry = existing
                if existing.remotePath != remotePath {
                    existing.remotePath = remotePath
                    existing.restartRetryCount = 0
                    if existing.tunnel != nil {
                        stopEntryRuntimeLocked(existing)
                        notifyLocked(existing, update: .connecting)
                    }
                }
            } else {
                entry = Entry(configuration: configuration, remotePath: remotePath)
                entries[key] = entry
            }

            entry.subscribers[subscriberID] = onUpdate
            if let endpoint = entry.endpoint {
                onUpdate(.ready(endpoint))
            } else {
                onUpdate(.connecting)
            }

            if entry.tunnel == nil, entry.restartWorkItem == nil {
                startEntryLocked(key: key, entry: entry)
            }

            return Lease(key: key, subscriberID: subscriberID, broker: self)
        }
    }

    private func release(key: String, subscriberID: UUID) {
        queue.async { [weak self] in
            guard let self, let entry = self.entries[key] else { return }
            entry.subscribers.removeValue(forKey: subscriberID)
            guard entry.subscribers.isEmpty else { return }
            self.teardownEntryLocked(key: key, entry: entry)
        }
    }

    private func startEntryLocked(key: String, entry: Entry) {
        entry.restartWorkItem?.cancel()
        entry.restartWorkItem = nil

        let localPort: Int
        if let forcedLocalPort = entry.configuration.localProxyPort {
            // Internal deterministic test hook used by docker regressions to force bind conflicts.
            localPort = forcedLocalPort
        } else {
            let retryDelay = Self.retryDelay(baseDelay: 3.0, retry: entry.restartRetryCount + 1)
            guard let allocatedPort = Self.allocateLoopbackPort() else {
                notifyLocked(
                    entry,
                    update: .error("Failed to allocate local proxy port\(Self.retrySuffix(delay: retryDelay))")
                )
                scheduleRestartLocked(key: key, entry: entry, baseDelay: 3.0)
                return
            }
            localPort = allocatedPort
        }

        do {
            let tunnel = WorkspaceRemoteDaemonProxyTunnel(
                configuration: entry.configuration,
                remotePath: entry.remotePath,
                localPort: localPort
            ) { [weak self] detail in
                self?.queue.async {
                    self?.handleTunnelFailureLocked(key: key, detail: detail)
                }
            }
            try tunnel.start()
            entry.tunnel = tunnel
            let endpoint = BrowserProxyEndpoint(host: "127.0.0.1", port: localPort)
            entry.endpoint = endpoint
            entry.restartRetryCount = 0
            notifyLocked(entry, update: .ready(endpoint))
        } catch {
            stopEntryRuntimeLocked(entry)
            let detail = "Failed to start local daemon proxy: \(error.localizedDescription)"
            let retryDelay = Self.retryDelay(baseDelay: 3.0, retry: entry.restartRetryCount + 1)
            notifyLocked(entry, update: .error("\(detail)\(Self.retrySuffix(delay: retryDelay))"))
            scheduleRestartLocked(key: key, entry: entry, baseDelay: 3.0)
        }
    }

    private func handleTunnelFailureLocked(key: String, detail: String) {
        guard let entry = entries[key], entry.tunnel != nil else { return }
        stopEntryRuntimeLocked(entry)
        let retryDelay = Self.retryDelay(baseDelay: 3.0, retry: entry.restartRetryCount + 1)
        notifyLocked(entry, update: .error("\(detail)\(Self.retrySuffix(delay: retryDelay))"))
        scheduleRestartLocked(key: key, entry: entry, baseDelay: 3.0)
    }

    private func scheduleRestartLocked(key: String, entry: Entry, baseDelay: TimeInterval) {
        guard !entry.subscribers.isEmpty else {
            teardownEntryLocked(key: key, entry: entry)
            return
        }
        guard entry.restartWorkItem == nil else { return }
        entry.restartRetryCount += 1
        let retryDelay = Self.retryDelay(baseDelay: baseDelay, retry: entry.restartRetryCount)

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, let currentEntry = self.entries[key] else { return }
            currentEntry.restartWorkItem = nil
            guard !currentEntry.subscribers.isEmpty else {
                self.teardownEntryLocked(key: key, entry: currentEntry)
                return
            }
            self.notifyLocked(currentEntry, update: .connecting)
            self.startEntryLocked(key: key, entry: currentEntry)
        }

        entry.restartWorkItem = workItem
        queue.asyncAfter(deadline: .now() + retryDelay, execute: workItem)
    }

    private func teardownEntryLocked(key: String, entry: Entry) {
        entry.restartWorkItem?.cancel()
        entry.restartWorkItem = nil
        stopEntryRuntimeLocked(entry)
        entries.removeValue(forKey: key)
    }

    private func stopEntryRuntimeLocked(_ entry: Entry) {
        entry.tunnel?.stop()
        entry.tunnel = nil
        entry.endpoint = nil
    }

    private func notifyLocked(_ entry: Entry, update: Update) {
        for callback in entry.subscribers.values {
            callback(update)
        }
    }

    private static func transportKey(for configuration: WorkspaceRemoteConfiguration) -> String {
        configuration.proxyBrokerTransportKey
    }

    private static func allocateLoopbackPort() -> Int? {
        for _ in 0..<8 {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { return nil }
            defer { close(fd) }

            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(0)
            addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

            let bindResult = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bindResult == 0 else { continue }

            var bound = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let nameResult = withUnsafeMutablePointer(to: &bound) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    getsockname(fd, sockaddrPtr, &len)
                }
            }
            guard nameResult == 0 else { continue }

            let port = Int(UInt16(bigEndian: bound.sin_port))
            if port > 0 && port <= 65535 {
                return port
            }
        }
        return nil
    }

    private static func retrySuffix(delay: TimeInterval) -> String {
        let seconds = max(1, Int(delay.rounded()))
        return " (retry in \(seconds)s)"
    }

    private static func retryDelay(baseDelay: TimeInterval, retry: Int) -> TimeInterval {
        let exponent = Double(max(0, retry - 1))
        return min(baseDelay * pow(2.0, exponent), 60.0)
    }
}
