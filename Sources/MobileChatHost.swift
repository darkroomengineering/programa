import Foundation
import IrohLib
import Security

actor MobileChatHost {
    private struct Invitation {
        let token: String
        let expires: ContinuousClock.Instant
    }

    private let endpoint: Endpoint
    private let jobs: MobileChatJobs
    private let storage: MobileChatIdentityStore
    private let onDeviceChange: @Sendable (String?) -> Void
    private var identity: MobileChatIdentity
    private var invitation: Invitation?
    private var accepts: Task<Void, Never>?
    private var accepting = true
    private var admissions = Set<UUID>()
    private var attempts = 0
    private var connections: [UUID: Connection] = [:]

    static func start(
        jobs: MobileChatJobs,
        onDeviceChange: @escaping @Sendable (String?) -> Void
    ) async throws -> MobileChatHost {
        let storage = MobileChatIdentityStore()
        let identity = try storage.loadOrCreate()
        let endpoint = try await Endpoint.bind(options: EndpointOptions(
            preset: presetN0(),
            bindAddr: "0.0.0.0:0",
            secretKey: identity.secret,
            alpns: [MobileChatWire.alpn],
            relayMode: RelayMode.defaultMode(),
            portMappingEnabled: false,
            deferNatTraversalUntilAuthorized: true,
            initialMaxConcurrentBiStreams: 0,
            initialMaxConcurrentUniStreams: 0
        ))
        let host = MobileChatHost(
            endpoint: endpoint, jobs: jobs, storage: storage,
            identity: identity, onDeviceChange: onDeviceChange
        )
        await host.startAccepting()
        return host
    }

    private init(
        endpoint: Endpoint,
        jobs: MobileChatJobs,
        storage: MobileChatIdentityStore,
        identity: MobileChatIdentity,
        onDeviceChange: @escaping @Sendable (String?) -> Void
    ) {
        self.endpoint = endpoint
        self.jobs = jobs
        self.storage = storage
        self.identity = identity
        self.onDeviceChange = onDeviceChange
    }

    func pairedDeviceName() -> String? {
        identity.peer?.name
    }

    func newInvitation(macName: String) async throws -> MobileChatPairingCode {
        guard accepting, identity.peer == nil else { throw MobileChatHostError.unavailable }
        let deadline = ContinuousClock.now + .seconds(12)
        while endpoint.addr().relayUrl() == nil {
            guard accepting, ContinuousClock.now < deadline else { throw MobileChatHostError.unavailable }
            try await Task.sleep(for: .milliseconds(150))
        }
        guard accepting, identity.peer == nil else { throw MobileChatHostError.unavailable }
        let address = endpoint.addr()
        guard let relay = address.relayUrl() else { throw MobileChatHostError.unavailable }
        // The QR stays usable across networks and carries no LAN addresses.
        let relayAddress = EndpointAddr(id: address.id(), relayUrl: relay, addresses: [])
        let ticket = try EndpointTicket.fromAddr(addr: relayAddress).description
        let token = try MobileChatIdentityStore.randomSecret().map { String(format: "%02x", $0) }.joined()
        invitation = Invitation(token: token, expires: ContinuousClock.now + .seconds(300))
        return MobileChatPairingCode(ticket: ticket, token: token, macName: macName)
    }

    func cancelInvitation() {
        invitation = nil
    }

    func revoke() throws {
        let replacement = MobileChatIdentity(secret: identity.secret, peer: nil)
        try storage.save(replacement)
        identity = replacement
        invitation = nil
        for connection in connections.values {
            try? connection.close(errorCode: 0, reason: Data())
        }
        onDeviceChange(nil)
    }

    static func revokePersistedDevice() throws {
        let storage = MobileChatIdentityStore()
        let identity = try storage.loadOrCreate()
        try storage.save(MobileChatIdentity(secret: identity.secret, peer: nil))
    }

    func close() async {
        accepting = false
        invitation = nil
        accepts?.cancel()
        accepts = nil
        for connection in connections.values {
            try? connection.close(errorCode: 0, reason: Data())
        }
        try? await endpoint.close()
    }

    private func startAccepting() {
        accepts = Task {
            while !Task.isCancelled, let incoming = await endpoint.acceptNext() {
                guard accepting, admissions.count < 10, attempts < 16,
                      identity.peer != nil || (invitation?.expires ?? .now) > .now else {
                    try? await incoming.refuse()
                    continue
                }
                let id = UUID()
                admissions.insert(id)
                attempts += 1
                Task { await self.receive(incoming, id: id) }
            }
        }
    }

    private func receive(_ incoming: Incoming, id: UUID) async {
        defer {
            admissions.remove(id)
            attempts -= 1
            if let connection = connections.removeValue(forKey: id) {
                try? connection.close(errorCode: 0, reason: Data())
            }
        }
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
            admissions.remove(id)
            if let connection = connections[id] {
                try? connection.close(errorCode: 0, reason: Data())
            } else {
                try? await incoming.refuse()
            }
        }
        defer { deadline.cancel() }
        do {
            let handshake = try await incoming.accept()
            guard try await handshake.alpn() == MobileChatWire.alpn else { return }
            let connection = try await handshake.connect()
            guard accepting, admissions.contains(id) else {
                try? connection.close(errorCode: 0, reason: Data())
                return
            }
            connections[id] = connection
            let peerID = connection.remoteId().description
            guard accepting,
                  identity.peer?.id == peerID || (identity.peer == nil && invitation != nil) else { return }
            try connection.setMaxConcurrentBiStreams(count: 1)
            let stream = try await connection.acceptBi()
            let payload = try await stream.recv().readToEnd(sizeLimit: UInt32(MobileChatWire.maximumRequestBytes))
            let request = try JSONDecoder().decode(MobileChatRequest.self, from: payload)
            let response = await response(for: request, peerID: peerID)
            guard accepting, admissions.contains(id) else { return }
            let encoded = try JSONEncoder().encode(response)
            let output = encoded.count <= MobileChatWire.maximumResponseBytes
                ? encoded : try JSONEncoder().encode(MobileChatResponse.failure(.unavailable))
            let writer = stream.send()
            try await writer.writeAll(buf: output)
            try await writer.finish()
            // Keep the connection alive until the response's FIN is acknowledged.
            _ = try await writer.stopped()
        } catch {
            // Connection failures can contain dial strings and peer identifiers.
        }
    }

    private func response(for request: MobileChatRequest, peerID: String) async -> MobileChatResponse {
        guard accepting else { return .failure(.unavailable) }
        if case let .pair(code, deviceName) = request {
            guard let name = validName(deviceName) else { return .failure(.invalidRequest) }
            if identity.peer?.id == peerID { return .paired }
            guard identity.peer == nil, let invitation,
                  invitation.expires > .now,
                  Self.equal(invitation.token, code) else { return .failure(.unauthorized) }
            let replacement = MobileChatIdentity(secret: identity.secret, peer: .init(id: peerID, name: name))
            do {
                try storage.save(replacement)
            } catch {
                return .failure(.storage)
            }
            identity = replacement
            self.invitation = nil
            onDeviceChange(name)
            return .paired
        }
        guard identity.peer?.id == peerID else { return .failure(.unauthorized) }
        return await jobs.handle(request, peerID: peerID)
    }

    private func validName(_ value: String) -> String? {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 256,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        return name
    }

    private static func equal(_ lhs: String, _ rhs: String) -> Bool {
        guard lhs.utf8.count == rhs.utf8.count else { return false }
        return zip(lhs.utf8, rhs.utf8).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

private enum MobileChatHostError: Error {
    case unavailable, identity
}

private struct MobileChatIdentity: Codable {
    struct Peer: Codable {
        let id: String
        let name: String
    }

    let secret: Data
    let peer: Peer?
}

private struct MobileChatIdentityStore {
    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "com.darkroom.programa") + ".iphone",
            kSecAttrAccount as String: "endpoint-v1",
        ]
    }

    static func randomSecret() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw MobileChatHostError.identity
        }
        return Data(bytes)
    }

    func loadOrCreate() throws -> MobileChatIdentity {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data {
            let identity = try JSONDecoder().decode(MobileChatIdentity.self, from: data)
            guard identity.secret.count == 32 else { throw MobileChatHostError.identity }
            return identity
        }
        guard status == errSecItemNotFound else { throw MobileChatHostError.identity }
        let identity = MobileChatIdentity(secret: try Self.randomSecret(), peer: nil)
        try save(identity)
        return identity
    }

    func save(_ identity: MobileChatIdentity) throws {
        let data = try JSONEncoder().encode(identity)
        let attributes = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var creation = query
            creation[kSecValueData as String] = data
            guard SecItemAdd(creation as CFDictionary, nil) == errSecSuccess else {
                throw MobileChatHostError.identity
            }
        } else if status != errSecSuccess {
            throw MobileChatHostError.identity
        }
    }
}
