import Foundation
import IrohLib
import Security

struct PairedMac: Codable, Sendable {
    let ticket: String
    let name: String
}

enum CompanionIssue: Error, Sendable {
    case malformedCode
    case pairingRefused
    case credential
    case unreachable
    case unexpectedReply
    case refused(MobileChatFailure)

    var label: String {
        switch self {
        case .malformedCode:
            String(localized: "error.pairCode", defaultValue: "Scan or paste the full pairing code from your Mac.")
        case .pairingRefused:
            String(localized: "error.pairExpired", defaultValue: "The Mac refused this pairing code. Generate a new code and try again.")
        case .credential:
            String(localized: "error.keychain", defaultValue: "Programa could not access its credentials. Unlock your iPhone and try again.")
        case .unreachable:
            String(localized: "error.unreachable", defaultValue: "Could not reach your Mac. Check that it is awake and Programa is running.")
        case .unexpectedReply:
            String(localized: "error.reply", defaultValue: "Programa received an unexpected reply. Check that both apps are up to date.")
        case .refused(.unauthorized):
            String(localized: "error.revoked", defaultValue: "This iPhone no longer has access. Pair it again on your Mac.")
        case .refused(.invalidRequest):
            String(localized: "error.request", defaultValue: "The Mac could not accept this request.")
        case .refused(.notFound):
            String(localized: "error.missing", defaultValue: "This job or repository is unavailable on your Mac.")
        case .refused(.busy):
            String(localized: "error.busy", defaultValue: "The Mac is busy. Try again in a moment.")
        case .refused(.unavailable):
            String(localized: "error.host", defaultValue: "Programa is unavailable on your Mac.")
        case .refused(.storage):
            String(localized: "error.storage", defaultValue: "The Mac could not read or save this job.")
        }
    }

    init(_ error: any Error) {
        self = (error as? Self) ?? .unreachable
    }
}

actor CompanionClient {
    private var endpoint: (id: UUID, task: Task<Endpoint, Error>)?

    func savedMac() throws -> PairedMac? {
        guard let data = try CompanionKeychain.data(account: "paired-mac") else { return nil }
        do {
            return try JSONDecoder().decode(PairedMac.self, from: data)
        } catch {
            throw CompanionIssue.credential
        }
    }

    func pair(with text: String, deviceName: String) async throws -> PairedMac {
        guard let code = MobileChatPairingCode.parse(text) else { throw CompanionIssue.malformedCode }
        let mac = PairedMac(ticket: code.ticket, name: code.macName)
        let response = try await exchange(.pair(code: code.token, deviceName: deviceName), with: mac)
        guard case .paired = response else { throw CompanionIssue.pairingRefused }
        try CompanionKeychain.set(JSONEncoder().encode(mac), account: "paired-mac")
        return mac
    }

    func forget() async throws {
        try CompanionKeychain.remove(account: "paired-mac")
        try CompanionKeychain.remove(account: "iroh-identity")
        await disconnect()
    }

    func disconnect() async {
        let pending = endpoint?.task
        endpoint = nil
        pending?.cancel()
        if let bound = try? await pending?.value { try? await bound.close() }
    }

    func request(_ request: MobileChatRequest, on mac: PairedMac) async throws -> MobileChatResponse {
        let response = try await exchange(request, with: mac)
        if case let .failure(reason) = response { throw CompanionIssue.refused(reason) }
        return response
    }

    private func boundEndpoint() async throws -> Endpoint {
        if let endpoint { return try await endpoint.task.value }
        let id = UUID()
        let task = Task<Endpoint, Error> {
            let secret = try CompanionKeychain.identity()
            let options = EndpointOptions(
                preset: presetN0(),
                secretKey: secret,
                alpns: [MobileChatWire.alpn],
                relayMode: RelayMode.defaultMode(),
                portMappingEnabled: false,
                deferNatTraversalUntilAuthorized: true,
                initialMaxConcurrentBiStreams: 0,
                initialMaxConcurrentUniStreams: 0
            )
            return try await Endpoint.bind(options: options)
        }
        endpoint = (id, task)
        do {
            return try await task.value
        } catch {
            if endpoint?.id == id { endpoint = nil }
            throw error
        }
    }

    private func exchange(_ request: MobileChatRequest, with mac: PairedMac) async throws -> MobileChatResponse {
        let ticket: EndpointTicket
        do {
            ticket = try EndpointTicket.fromString(str: mac.ticket)
        } catch {
            throw CompanionIssue.malformedCode
        }
        let data = try JSONEncoder().encode(request)
        guard data.count <= MobileChatWire.maximumRequestBytes else { throw CompanionIssue.refused(.invalidRequest) }
        let address = ticket.endpointAddr()
        let bound = try await boundEndpoint()
        let connection = try await Self.withDeadline(.seconds(20)) {
            try await bound.connect(addr: address, alpn: MobileChatWire.alpn)
        }
        defer { try? connection.close(errorCode: 0, reason: Data()) }
        let close: @Sendable () -> Void = { try? connection.close(errorCode: 0, reason: Data()) }
        let response = try await withTaskCancellationHandler {
            try await Self.withDeadline(.seconds(15), abort: close) {
                let stream = try await connection.openBi()
                let send = stream.send()
                try await send.writeAll(buf: data)
                try await send.finish()
                return try await stream.recv().readToEnd(sizeLimit: UInt32(MobileChatWire.maximumResponseBytes))
            }
        } onCancel: {
            close()
        }
        do {
            return try JSONDecoder().decode(MobileChatResponse.self, from: response)
        } catch {
            throw CompanionIssue.unexpectedReply
        }
    }

    private static func withDeadline<Value: Sendable>(
        _ duration: Duration,
        abort: @escaping @Sendable () -> Void = {},
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await withThrowingTaskGroup(of: Value.self) { group in
            defer { group.cancelAll() }
            group.addTask(operation: operation)
            group.addTask {
                try await Task.sleep(for: duration)
                abort()
                throw CompanionIssue.unreachable
            }
            guard let result = try await group.next() else { throw CompanionIssue.unreachable }
            return result
        }
    }
}

private enum CompanionKeychain {
    private static let service = "com.darkroom.programa.iphone.companion"

    static func data(account: String) throws -> Data? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &item) {
        case errSecSuccess:
            guard let data = item as? Data else { throw CompanionIssue.credential }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw CompanionIssue.credential
        }
    }

    static func set(_ data: Data, account: String) throws {
        let query = query(account)
        let content = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, content as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw CompanionIssue.credential }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw CompanionIssue.credential }
    }

    static func remove(account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CompanionIssue.credential }
    }

    static func identity() throws -> Data {
        if let saved = try data(account: "iroh-identity") {
            guard saved.count == 32 else { throw CompanionIssue.credential }
            return saved
        }
        var secret = Data(count: 32)
        let status = secret.withUnsafeMutableBytes { bytes in
            guard let address = bytes.baseAddress else { return errSecAllocate }
            return SecRandomCopyBytes(kSecRandomDefault, bytes.count, address)
        }
        guard status == errSecSuccess else { throw CompanionIssue.credential }
        try set(secret, account: "iroh-identity")
        return secret
    }

    private static func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
    }
}
