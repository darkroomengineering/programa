import Foundation
import Security

enum TypeSafeCredentialSource: Equatable, Sendable {
    case saved
    case environment
}

struct TypeSafeCredential: Equatable, Sendable {
    let value: String
    let source: TypeSafeCredentialSource
}

enum TypeSafeCredentialLookup: Equatable, Sendable {
    case available(TypeSafeCredential)
    case missing
    case unavailable
}

enum TypeSafeCredentialStorageRead: Equatable, Sendable {
    case value(String)
    case missing
    case unavailable
}

enum TypeSafeCredentialOperation: Equatable, Sendable {
    case success
    case blank
    case invalidCharacters
    case unavailable
}

struct TypeSafeCredentialStore {
    static let environmentVariableName = "TYPESAFE_API_KEY"
    static let environmentDiscoveryEnabledKey = "typeSafeEnvironmentDiscoveryEnabled"
    static let defaultEnvironmentDiscoveryEnabled = true

    private static let keychainAccount = "jev-api-key"

    private let readSavedCredential: () -> TypeSafeCredentialStorageRead
    private let writeSavedCredential: (String) -> Bool
    private let removeSavedCredential: () -> Bool
    private let readEnvironmentCredential: () -> String?

    init(
        readSavedCredential: @escaping () -> TypeSafeCredentialStorageRead,
        writeSavedCredential: @escaping (String) -> Bool,
        removeSavedCredential: @escaping () -> Bool,
        readEnvironmentCredential: @escaping () -> String?
    ) {
        self.readSavedCredential = readSavedCredential
        self.writeSavedCredential = writeSavedCredential
        self.removeSavedCredential = removeSavedCredential
        self.readEnvironmentCredential = readEnvironmentCredential
    }

    static func live(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> Self {
        let service = keychainService(bundleIdentifier: bundleIdentifier)
        return Self(
            readSavedCredential: { readFromKeychain(service: service) },
            writeSavedCredential: { writeToKeychain($0, service: service) },
            removeSavedCredential: { removeFromKeychain(service: service) },
            readEnvironmentCredential: { ProcessInfo.processInfo.environment[environmentVariableName] }
        )
    }

    func credential(discoverEnvironment: Bool) -> TypeSafeCredentialLookup {
        switch readSavedCredential() {
        case .value(let value):
            guard case .valid(let credential) = Self.validate(value) else {
                return .unavailable
            }
            return .available(TypeSafeCredential(value: credential, source: .saved))
        case .unavailable:
            return .unavailable
        case .missing:
            break
        }

        guard discoverEnvironment else {
            return .missing
        }
        guard let environmentValue = readEnvironmentCredential(),
              case .valid(let credential) = Self.validate(environmentValue) else {
            return .missing
        }
        return .available(TypeSafeCredential(value: credential, source: .environment))
    }

    func save(_ candidate: String) -> TypeSafeCredentialOperation {
        switch Self.validate(candidate) {
        case .blank:
            return .blank
        case .invalidCharacters:
            return .invalidCharacters
        case .valid(let credential):
            return writeSavedCredential(credential) ? .success : .unavailable
        }
    }

    func remove() -> TypeSafeCredentialOperation {
        removeSavedCredential() ? .success : .unavailable
    }

    private enum ValidationResult {
        case valid(String)
        case blank
        case invalidCharacters
    }

    private static func validate(_ candidate: String) -> ValidationResult {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .blank
        }
        let disallowed = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        guard trimmed.unicodeScalars.allSatisfy({ !disallowed.contains($0) }) else {
            return .invalidCharacters
        }
        return .valid(trimmed)
    }

    private static func keychainService(bundleIdentifier: String?) -> String {
        let appIdentity = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedIdentity = appIdentity?.isEmpty == false ? appIdentity! : "com.darkroom.programa"
        return "\(resolvedIdentity).typesafe-jev"
    }

    private static func keychainQuery(service: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: keychainAccount,
        ]
    }

    private static func readFromKeychain(service: String) -> TypeSafeCredentialStorageRead {
        var query = keychainQuery(service: service)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return .missing
        }
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return .unavailable
        }
        return .value(value)
    }

    private static func writeToKeychain(_ credential: String, service: String) -> Bool {
        let query = keychainQuery(service: service)
        let value = Data(credential.utf8)
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData: value] as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return true
        }
        guard updateStatus == errSecItemNotFound else {
            return false
        }

        var attributes = query
        attributes[kSecValueData] = value
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    private static func removeFromKeychain(service: String) -> Bool {
        let status = SecItemDelete(keychainQuery(service: service) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

final class TypeSafeCredentialExecutor: @unchecked Sendable {
    static let shared = TypeSafeCredentialExecutor(store: .live())

    private let queue = DispatchQueue(
        label: "com.darkroom.programa.typesafe-credential-store",
        qos: .userInitiated
    )
    private let store: TypeSafeCredentialStore

    init(store: TypeSafeCredentialStore) {
        self.store = store
    }

    func credential(discoverEnvironment: Bool) async -> TypeSafeCredentialLookup {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: store.credential(discoverEnvironment: discoverEnvironment))
            }
        }
    }

    func save(_ candidate: String) async -> TypeSafeCredentialOperation {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: store.save(candidate))
            }
        }
    }

    func remove() async -> TypeSafeCredentialOperation {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: store.remove())
            }
        }
    }
}
