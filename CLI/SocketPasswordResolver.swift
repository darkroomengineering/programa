import Foundation
import Darwin
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
#if canImport(Security)
import Security
#endif

enum SocketPasswordResolver {
    private static let service = "com.darkroom.programa.socket-control"
    private static let account = "local-socket-password"
    private static let directoryName = "programa"
    private static let fileName = "socket-control-password"

    static func resolve(explicit: String?, socketPath: String) -> String? {
        if let explicit = normalized(explicit) {
            return explicit
        }
        if let env = normalized(ProcessInfo.processInfo.environment["PROGRAMA_SOCKET_PASSWORD"]) {
            return env
        }
        if let filePassword = loadFromFile() {
            return filePassword
        }
        return loadFromKeychain(socketPath: socketPath)
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .newlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func loadFromFile() -> String? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let passwordURL = appSupport
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)

        var pathStat = stat()
        guard lstat(passwordURL.path, &pathStat) == 0,
              (pathStat.st_mode & S_IFMT) == S_IFREG,
              pathStat.st_uid == geteuid(),
              (pathStat.st_mode & 0o077) == 0,
              pathStat.st_size >= 0,
              pathStat.st_size <= 64 * 1024 else {
            return nil
        }

        let descriptor = open(passwordURL.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }

        var openedStat = stat()
        guard fstat(descriptor, &openedStat) == 0,
              (openedStat.st_mode & S_IFMT) == S_IFREG,
              openedStat.st_uid == geteuid(),
              (openedStat.st_mode & 0o077) == 0,
              openedStat.st_dev == pathStat.st_dev,
              openedStat.st_ino == pathStat.st_ino,
              openedStat.st_size >= 0,
              openedStat.st_size <= 64 * 1024 else {
            return nil
        }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data = handle.readDataToEndOfFile()
        guard let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return normalized(value)
    }

    static func keychainServices(
        socketPath: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        guard let scope = keychainScope(socketPath: socketPath, environment: environment) else {
            return [service]
        }
        return ["\(service).\(scope)", service]
    }

    private static func keychainScope(
        socketPath: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        if let tag = normalized(environment["PROGRAMA_TAG"]) {
            let scoped = sanitizeScope(tag)
            if !scoped.isEmpty {
                return scoped
            }
        }

        let candidate = URL(fileURLWithPath: socketPath).lastPathComponent
        let prefixes = ["programa-debug-", "programa-"]
        for prefix in prefixes {
            guard candidate.hasPrefix(prefix), candidate.hasSuffix(".sock") else { continue }
            let start = candidate.index(candidate.startIndex, offsetBy: prefix.count)
            let end = candidate.index(candidate.endIndex, offsetBy: -".sock".count)
            guard start < end else { continue }
            let rawScope = String(candidate[start..<end])
            let scoped = sanitizeScope(rawScope)
            if !scoped.isEmpty {
                return scoped
            }
        }
        return nil
    }

    private static func sanitizeScope(_ raw: String) -> String {
        let lowered = raw.lowercased()
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-"))
        let mappedScalars = lowered.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "."
        }
        var normalizedScope = String(mappedScalars)
        normalizedScope = normalizedScope.replacingOccurrences(
            of: "\\.+",
            with: ".",
            options: .regularExpression
        )
        normalizedScope = normalizedScope.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return normalizedScope
    }

    /// The app keeps its password in the file above; the Keychain only holds a legacy copy.
    /// A scan that found nothing is remembered by a marker that stays valid until the login
    /// keychain changes, so calls without a password skip the Keychain query.
    private static func keychainEmptyMarkerPath(socketPath: String) -> String? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let scope = keychainScope(socketPath: socketPath) ?? "default"
        return appSupport.appendingPathComponent(directoryName, isDirectory: true).appendingPathComponent(".socket-keychain-empty-\(scope)").path
    }

    private static func modificationTime(_ path: String) -> Int? {
        var info = stat()
        return lstat(path, &info) == 0 ? Int(info.st_mtimespec.tv_sec) : nil
    }

    private static func loadFromKeychain(socketPath: String) -> String? {
        let marker = keychainEmptyMarkerPath(socketPath: socketPath)
        let keychainModified = modificationTime(NSHomeDirectory() + "/Library/Keychains/login.keychain-db")
        if let marker, let keychainModified, let markerModified = modificationTime(marker), markerModified > keychainModified {
            return nil
        }
        var everyServiceMissing = true
        for service in keychainServices(socketPath: socketPath) {
            let authContext = LAContext()
            authContext.interactionNotAllowed = true
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
                // Never trigger keychain UI from CLI commands; fail fast instead.
                kSecUseAuthenticationContext as String: authContext,
            ]
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            guard status == errSecSuccess else {
                // A locked or denied item is not proof of absence; only remember clean misses.
                everyServiceMissing = everyServiceMissing && status == errSecItemNotFound
                continue
            }
            guard let data = result as? Data,
                  let password = String(data: data, encoding: .utf8) else {
                continue
            }
            return password
        }
        if everyServiceMissing, keychainModified != nil, let marker {
            FileManager.default.createFile(atPath: marker, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        return nil
    }
}
