import Foundation
import CryptoKit
import Darwin
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
#if canImport(Security)
import Security
#endif

struct CLIError: Error, CustomStringConvertible {
    let message: String

    var description: String { message }
}

enum CLIIDFormat: String {
    case refs
    case uuids
    case both

    static func parse(_ raw: String?) throws -> CLIIDFormat? {
        guard let raw else { return nil }
        guard let parsed = CLIIDFormat(rawValue: raw.lowercased()) else {
            throw CLIError(message: "--id-format must be one of: refs, uuids, both")
        }
        return parsed
    }
}

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
        let prefixes = ["cmux-debug-", "cmux-"]
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

    private static func loadFromKeychain(socketPath: String) -> String? {
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
            if status == errSecItemNotFound || status == errSecInteractionNotAllowed || status == errSecAuthFailed {
                continue
            }
            guard status == errSecSuccess else {
                continue
            }
            guard let data = result as? Data,
                  let password = String(data: data, encoding: .utf8) else {
                continue
            }
            return password
        }
        return nil
    }
}

enum CLISocketPathSource {
    case explicitFlag
    case environment
    case implicitDefault
}

enum CLISocketPathResolver {
    private static let appSupportDirectoryName = "programa"
    private static let stableSocketFileName = "programa.sock"
    private static let lastSocketPathFileName = "last-socket-path"
    static let legacyDefaultSocketPath = "/tmp/programa.sock"
    private static let fallbackSocketPath = "/tmp/programa-debug.sock"
    private static let stagingSocketPath = "/tmp/programa-staging.sock"
    private static let legacyLastSocketPathFile = "/tmp/programa-last-socket-path"

    static var defaultSocketPath: String {
        let stablePath: String? = stableSocketDirectoryURL()?
            .appendingPathComponent(stableSocketFileName, isDirectory: false)
            .path
        return stablePath ?? legacyDefaultSocketPath
    }

    static func isImplicitDefaultPath(_ path: String) -> Bool {
        path == defaultSocketPath || path == legacyDefaultSocketPath
    }

    static func resolve(
        requestedPath: String,
        source: CLISocketPathSource,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        guard source == .implicitDefault else {
            return requestedPath
        }

        let candidates = dedupe(candidatePaths(requestedPath: requestedPath, environment: environment))

        // Prefer sockets that are currently accepting connections.
        for path in candidates where canConnect(to: path) {
            return path
        }

        // If the listener is still starting, prefer existing socket files.
        for path in candidates where isSocketFile(path) {
            return path
        }

        return requestedPath
    }

    private static func candidatePaths(requestedPath: String, environment: [String: String]) -> [String] {
        var candidates: [String] = []

        if let tag = normalized(environment["PROGRAMA_TAG"]) {
            let slug = sanitizeTagSlug(tag)
            candidates.append("/tmp/programa-debug-\(slug).sock")
            candidates.append("/tmp/programa-\(slug).sock")
        }

        candidates.append(requestedPath)
        candidates.append(defaultSocketPath)
        candidates.append(legacyDefaultSocketPath)
        candidates.append(fallbackSocketPath)
        candidates.append(stagingSocketPath)
        candidates.append(contentsOf: discoverTaggedSockets(limit: 12))
        if let last = readLastSocketPath() {
            candidates.append(last)
        }
        return candidates
    }

    private static func readLastSocketPath() -> String? {
        let primaryCandidate: String? = stableSocketDirectoryURL()?
            .appendingPathComponent(lastSocketPathFileName, isDirectory: false)
            .path
        let candidates = [primaryCandidate, legacyLastSocketPathFile].compactMap { $0 }

        for candidate in candidates {
            guard let data = try? String(contentsOfFile: candidate, encoding: .utf8) else {
                continue
            }
            if let value = normalized(data) {
                return value
            }
        }
        return nil
    }

    private static func discoverTaggedSockets(limit: Int) -> [String] {
        var discovered: [(path: String, mtime: TimeInterval)] = []
        for directory in socketDiscoveryDirectories() {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
                continue
            }
            discovered.reserveCapacity(min(limit, discovered.count + entries.count))
            for name in entries where name.hasPrefix("programa") && name.hasSuffix(".sock") {
                let path = URL(fileURLWithPath: directory)
                    .appendingPathComponent(name, isDirectory: false)
                    .path
                var st = stat()
                guard lstat(path, &st) == 0 else { continue }
                guard (st.st_mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK) else { continue }
                if path == defaultSocketPath || path == legacyDefaultSocketPath || path == fallbackSocketPath || path == stagingSocketPath {
                    continue
                }
                let modified = TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1_000_000_000
                discovered.append((path: path, mtime: modified))
            }
        }

        discovered.sort { $0.mtime > $1.mtime }
        return dedupe(discovered.prefix(limit).map(\.path))
    }

    private static func isSocketFile(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK)
    }

    private static func canConnect(to path: String) -> Bool {
        guard isSocketFile(path) else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLength = MemoryLayout.size(ofValue: addr.sun_path)
        path.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                let buf = UnsafeMutableRawPointer(pathPtr).assumingMemoryBound(to: CChar.self)
                strncpy(buf, ptr, maxLength - 1)
            }
        }

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return result == 0
    }

    private static func sanitizeTagSlug(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let slug = trimmed
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? "agent" : slug
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func stableSocketDirectoryURL() -> URL? {
        guard let appSupportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return appSupportDirectory.appendingPathComponent(appSupportDirectoryName, isDirectory: true)
    }

    private static func socketDiscoveryDirectories() -> [String] {
        let appSupportSocketDirectory: String = stableSocketDirectoryURL()?.path ?? ""
        return dedupe([
            "/tmp",
            appSupportSocketDirectory,
        ])
    }

    private static func dedupe(_ paths: [String]) -> [String] {
        var seen: Set<String> = []
        var ordered: [String] = []
        ordered.reserveCapacity(paths.count)
        for path in paths where !path.isEmpty {
            if seen.insert(path).inserted {
                ordered.append(path)
            }
        }
        return ordered
    }
}

final class SocketClient {
    private struct RelayEndpoint {
        let host: String
        let port: UInt16
    }

    private struct RelayCredentials {
        let relayID: String
        let relayToken: Data
    }

    private let path: String
    private var socketFD: Int32 = -1
    private static let defaultResponseTimeoutSeconds: TimeInterval = 15.0
    private static let multilineResponseIdleTimeoutSeconds: TimeInterval = 0.12
    private static let maxSocketTimeoutSeconds: TimeInterval = 9_007_199_254_740_991
    private static let responseTimeoutSeconds: TimeInterval = {
        let env = ProcessInfo.processInfo.environment
        if let raw = env["CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC"],
           let seconds = Double(raw),
           seconds.isFinite,
           seconds > 0 {
            return seconds
        }
        return defaultResponseTimeoutSeconds
    }()

    init(path: String) {
        self.path = path
    }

    var socketPath: String {
        path
    }

    private var relayEndpoint: RelayEndpoint? {
        Self.parseRelayEndpoint(path)
    }

    private static func trimmedEnvValue(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func socketTimeval(for timeout: TimeInterval) -> timeval {
        let sanitizedTimeout = timeout.isFinite ? timeout : defaultResponseTimeoutSeconds
        let clampedTimeout = min(max(sanitizedTimeout, 0.01), maxSocketTimeoutSeconds)
        let seconds = floor(clampedTimeout)
        let microseconds = min(
            max(Int((clampedTimeout - seconds) * 1_000_000), 0),
            999_999
        )
        return timeval(
            tv_sec: Int(seconds),
            tv_usec: __darwin_suseconds_t(microseconds)
        )
    }

    func connect() throws {
        if socketFD >= 0 { return }
        try connectOnce()
    }

    func close() {
        if socketFD >= 0 {
            Darwin.close(socketFD)
            socketFD = -1
        }
    }

    /// - Parameter minimumReceiveTimeout: overrides the default response-wait timeout when
    ///   larger than it, for commands that legitimately hold the connection open longer than
    ///   `CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC`'s default (e.g. `surface.wait` with a caller-chosen
    ///   `--timeout`). Ignored (falls back to the default) when `nil` or smaller.
    func send(command: String, minimumReceiveTimeout: TimeInterval? = nil) throws -> String {
        if relayEndpoint != nil, socketFD < 0 {
            try connect()
        }
        guard socketFD >= 0 else { throw CLIError(message: "Not connected") }
        let shouldCloseAfterSend = relayEndpoint != nil
        defer {
            if shouldCloseAfterSend {
                close()
            }
        }

        let payload = command + "\n"
        try writeAll(
            Data(payload.utf8),
            timeoutMessage: "Command timed out",
            failureMessage: "Failed to write to socket"
        )

        var data = Data()
        var sawNewline = false
        let initialReceiveTimeout: TimeInterval = {
            guard let minimumReceiveTimeout, minimumReceiveTimeout > Self.responseTimeoutSeconds else {
                return Self.responseTimeoutSeconds
            }
            return minimumReceiveTimeout
        }()

        while true {
            try configureReceiveTimeout(
                sawNewline ? Self.multilineResponseIdleTimeoutSeconds : initialReceiveTimeout
            )

            var buffer = [UInt8](repeating: 0, count: 8192)
            let count = Darwin.read(socketFD, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR {
                    continue
                }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    if sawNewline {
                        break
                    }
                    throw CLIError(message: "Command timed out")
                }
                throw CLIError(message: "Socket read error")
            }
            if count == 0 {
                break
            }
            data.append(buffer, count: count)
            if data.contains(UInt8(0x0A)) {
                sawNewline = true
            }
        }

        guard var response = String(data: data, encoding: .utf8) else {
            throw CLIError(message: "Invalid UTF-8 response")
        }
        if response.hasSuffix("\n") {
            response.removeLast()
        }
        return response
    }

    private func connectOnce() throws {
        if let relayEndpoint {
            try connectToRelay(endpoint: relayEndpoint)
            return
        }

        // Verify socket is owned by the current user to prevent fake-socket attacks.
        var st = stat()
        guard stat(path, &st) == 0 else {
            throw CLIError(message: "Socket not found at \(path)")
        }
        guard (st.st_mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK) else {
            throw CLIError(message: "Path exists at \(path) but is not a Unix socket")
        }
        guard st.st_uid == getuid() else {
            throw CLIError(message: "Socket at \(path) is not owned by the current user — refusing to connect")
        }

        socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        if socketFD < 0 {
            throw CLIError(message: "Failed to create socket")
        }
        do {
            try configureSocketWriteSafety(Self.responseTimeoutSeconds)
        } catch {
            close()
            throw error
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLength = MemoryLayout.size(ofValue: addr.sun_path)
        path.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                let buf = UnsafeMutableRawPointer(pathPtr).assumingMemoryBound(to: CChar.self)
                strncpy(buf, ptr, maxLength - 1)
            }
        }

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(socketFD, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result == 0 {
            return
        }

        let connectErrno = errno
        Darwin.close(socketFD)
        socketFD = -1
        throw CLIError(
            message: "Failed to connect to socket at \(path) (\(String(cString: strerror(connectErrno))), errno \(connectErrno))"
        )
    }

    private static func parseRelayEndpoint(_ raw: String) -> RelayEndpoint? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("/") else {
            return nil
        }
        let components = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard components.count == 2,
              let port = UInt16(components[1]),
              port > 0 else {
            return nil
        }
        let host = String(components[0]).lowercased()
        guard host == "127.0.0.1" || host == "localhost" else {
            return nil
        }
        return RelayEndpoint(host: host == "localhost" ? "127.0.0.1" : host, port: port)
    }

    private static func relayCredentials(for endpoint: RelayEndpoint) throws -> RelayCredentials {
        let environment = ProcessInfo.processInfo.environment
        if let relayID = trimmedEnvValue(environment["PROGRAMA_RELAY_ID"]),
           let relayTokenHex = trimmedEnvValue(environment["PROGRAMA_RELAY_TOKEN"]),
           let relayToken = hexData(from: relayTokenHex) {
            return RelayCredentials(relayID: relayID, relayToken: relayToken)
        }

        let authURL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".programa/relay/\(endpoint.port).auth", isDirectory: false)
        guard let authData = try? Data(contentsOf: authURL),
              let authObject = try? JSONSerialization.jsonObject(with: authData) as? [String: Any],
              let relayID = trimmedEnvValue(authObject["relay_id"] as? String),
              let relayTokenHex = trimmedEnvValue(authObject["relay_token"] as? String),
              let relayToken = hexData(from: relayTokenHex) else {
            throw CLIError(message: "Missing relay auth metadata for \(endpoint.host):\(endpoint.port)")
        }

        return RelayCredentials(relayID: relayID, relayToken: relayToken)
    }

    private static func hexData(from string: String) -> Data? {
        let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized.count.isMultiple(of: 2) else {
            return nil
        }

        var data = Data(capacity: normalized.count / 2)
        var cursor = normalized.startIndex
        while cursor < normalized.endIndex {
            let next = normalized.index(cursor, offsetBy: 2)
            guard let byte = UInt8(normalized[cursor..<next], radix: 16) else {
                return nil
            }
            data.append(byte)
            cursor = next
        }
        return data
    }

    private static func hexString(from data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private func connectToRelay(endpoint: RelayEndpoint) throws {
        let credentials = try Self.relayCredentials(for: endpoint)

        socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            throw CLIError(message: "Failed to create relay socket")
        }
        do {
            try configureSocketWriteSafety(Self.responseTimeoutSeconds)
            try configureReceiveTimeout(Self.responseTimeoutSeconds)
        } catch {
            close()
            throw error
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.stride)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = endpoint.port.bigEndian
        let parsedAddress = withUnsafeMutablePointer(to: &address.sin_addr) { pointer in
            endpoint.host.withCString { hostPointer in
                inet_pton(AF_INET, hostPointer, pointer)
            }
        }
        guard parsedAddress == 1 else {
            close()
            throw CLIError(message: "Invalid relay endpoint \(endpoint.host):\(endpoint.port)")
        }

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(socketFD, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.stride))
            }
        }
        if result != 0 {
            let connectErrno = errno
            close()
            throw CLIError(
                message: "Failed to connect to relay at \(endpoint.host):\(endpoint.port) (\(String(cString: strerror(connectErrno))), errno \(connectErrno))"
            )
        }

        do {
            try authenticateRelay(credentials: credentials)
        } catch {
            close()
            throw error
        }
    }

    private func authenticateRelay(credentials: RelayCredentials) throws {
        let challengeLine = try readLine()
        guard let challengeData = challengeLine.data(using: .utf8),
              let challenge = try JSONSerialization.jsonObject(with: challengeData) as? [String: Any],
              (challenge["protocol"] as? String) == "cmux-relay-auth",
              let version = challenge["version"] as? Int,
              let relayID = challenge["relay_id"] as? String,
              relayID == credentials.relayID,
              let nonce = challenge["nonce"] as? String,
              !nonce.isEmpty else {
            throw CLIError(message: "Invalid relay authentication challenge")
        }

        let authMessage = Data("relay_id=\(relayID)\nnonce=\(nonce)\nversion=\(version)".utf8)
        let key = SymmetricKey(data: credentials.relayToken)
        let mac = Data(HMAC<SHA256>.authenticationCode(for: authMessage, using: key))
        let authPayload = try JSONSerialization.data(withJSONObject: [
            "relay_id": relayID,
            "mac": Self.hexString(from: mac),
        ])
        try writeAll(
            authPayload + Data([0x0A]),
            timeoutMessage: "Relay command timed out",
            failureMessage: "Failed to write to relay socket"
        )

        let authResponseLine = try readLine()
        guard let authResponseData = authResponseLine.data(using: .utf8),
              let authResponse = try JSONSerialization.jsonObject(with: authResponseData) as? [String: Any],
              (authResponse["ok"] as? Bool) == true else {
            throw CLIError(message: "Relay authentication failed")
        }
    }

    private func writeAll(
        _ data: Data,
        timeoutMessage: String,
        failureMessage: String
    ) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return
            }
            var offset = 0
            while offset < data.count {
                let written = Darwin.write(socketFD, baseAddress.advanced(by: offset), data.count - offset)
                if written < 0 {
                    let errorCode = errno
                    if errorCode == EINTR {
                        continue
                    }
                    close()
                    if errorCode == EAGAIN || errorCode == EWOULDBLOCK || errorCode == ETIMEDOUT {
                        throw CLIError(message: timeoutMessage)
                    }
                    let reason = String(cString: strerror(errorCode))
                    throw CLIError(
                        message: "\(failureMessage) (\(reason), errno \(errorCode))"
                    )
                }
                if written == 0 {
                    close()
                    throw CLIError(message: failureMessage)
                }
                offset += written
            }
        }
    }

    private func configureSocketWriteSafety(_ timeout: TimeInterval) throws {
        var interval = Self.socketTimeval(for: timeout)
        let sendTimeoutResult = withUnsafePointer(to: &interval) { ptr in
            setsockopt(
                socketFD,
                SOL_SOCKET,
                SO_SNDTIMEO,
                ptr,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }
        guard sendTimeoutResult == 0 else {
            throw CLIError(message: "Failed to configure socket write timeout")
        }

#if os(macOS)
        var noSigPipe: Int32 = 1
        let noSigPipeResult = withUnsafePointer(to: &noSigPipe) { ptr in
            setsockopt(
                socketFD,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                ptr,
                socklen_t(MemoryLayout<Int32>.size)
            )
        }
        guard noSigPipeResult == 0 else {
            throw CLIError(message: "Failed to disable SIGPIPE on socket")
        }
#endif
    }

    private func readLine(maxBytes: Int = 16 * 1024) throws -> String {
        var data = Data()

        while data.count < maxBytes {
            try configureReceiveTimeout(Self.responseTimeoutSeconds)

            var byte: UInt8 = 0
            let count = Darwin.read(socketFD, &byte, 1)
            if count < 0 {
                if errno == EINTR {
                    continue
                }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    throw CLIError(message: "Relay command timed out")
                }
                throw CLIError(message: "Relay socket read error")
            }
            if count == 0 {
                break
            }
            if byte == 0x0A {
                break
            }
            data.append(byte)
        }

        guard !data.isEmpty else {
            throw CLIError(message: "Unexpected EOF from relay")
        }
        guard let line = String(data: data, encoding: .utf8) else {
            throw CLIError(message: "Invalid UTF-8 relay response")
        }
        return line.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func configureReceiveTimeout(_ timeout: TimeInterval) throws {
        var interval = Self.socketTimeval(for: timeout)
        let result = withUnsafePointer(to: &interval) { ptr in
            setsockopt(
                socketFD,
                SOL_SOCKET,
                SO_RCVTIMEO,
                ptr,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }
        guard result == 0 else {
            throw CLIError(message: "Failed to configure socket receive timeout")
        }
    }

    static func waitForConnectableSocket(path: String, timeout: TimeInterval) throws -> SocketClient {
        let client = SocketClient(path: path)
        if (try? client.connect()) != nil {
            if client.relayEndpoint != nil {
                client.close()
            }
            return client
        }

        guard let watchDirectory = existingWatchDirectory(forPath: path) else {
            throw CLIError(message: "programa app did not start in time (socket not found at \(path))")
        }
        let watchFD = open(watchDirectory, O_EVTONLY)
        guard watchFD >= 0 else {
            throw CLIError(message: "programa app did not start in time (socket not found at \(path))")
        }

        let queue = DispatchQueue(label: "com.programa.cli.socket-watch.\(UUID().uuidString)")
        let semaphore = DispatchSemaphore(value: 0)
        var connected = false
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: watchFD,
            eventMask: [.write, .rename, .delete, .attrib, .extend, .link],
            queue: queue
        )

        func attemptConnect() {
            guard !connected else { return }
            if (try? client.connect()) != nil {
                connected = true
                semaphore.signal()
            }
        }

        source.setEventHandler {
            attemptConnect()
        }
        source.setCancelHandler {
            Darwin.close(watchFD)
        }
        source.resume()
        queue.async {
            attemptConnect()
        }

        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            source.cancel()
            client.close()
            throw CLIError(message: "programa app did not start in time (socket not found at \(path))")
        }

        source.cancel()
        return client
    }

    static func waitForFilesystemPath(_ path: String, timeout: TimeInterval) throws {
        if FileManager.default.fileExists(atPath: path) {
            return
        }

        guard let watchDirectory = existingWatchDirectory(forPath: path) else {
            throw CLIError(message: "Timed out waiting for \(path)")
        }
        let watchFD = open(watchDirectory, O_EVTONLY)
        guard watchFD >= 0 else {
            throw CLIError(message: "Timed out waiting for \(path)")
        }

        let queue = DispatchQueue(label: "com.programa.cli.path-watch.\(UUID().uuidString)")
        let semaphore = DispatchSemaphore(value: 0)
        var found = false
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: watchFD,
            eventMask: [.write, .rename, .delete, .attrib, .extend, .link],
            queue: queue
        )

        func checkPath() {
            guard !found else { return }
            if FileManager.default.fileExists(atPath: path) {
                found = true
                semaphore.signal()
            }
        }

        source.setEventHandler {
            checkPath()
        }
        source.setCancelHandler {
            Darwin.close(watchFD)
        }
        source.resume()
        queue.async {
            checkPath()
        }

        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            source.cancel()
            throw CLIError(message: "Timed out waiting for \(path)")
        }

        source.cancel()
    }

    private static func existingWatchDirectory(forPath path: String) -> String? {
        let fileManager = FileManager.default
        var candidate = URL(fileURLWithPath: (path as NSString).deletingLastPathComponent, isDirectory: true)

        while !candidate.path.isEmpty {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return candidate.path
            }
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path {
                break
            }
            candidate = parent
        }
        return nil
    }

    func sendV2(method: String, params: [String: Any] = [:], minimumReceiveTimeout: TimeInterval? = nil) throws -> [String: Any] {
        let request: [String: Any] = [
            "id": UUID().uuidString,
            "method": method,
            "params": params
        ]
        guard JSONSerialization.isValidJSONObject(request) else {
            throw CLIError(message: "Failed to encode v2 request")
        }

        let requestData = try JSONSerialization.data(withJSONObject: request, options: [])
        guard let requestLine = String(data: requestData, encoding: .utf8) else {
            throw CLIError(message: "Failed to encode v2 request")
        }

        let raw = try send(command: requestLine, minimumReceiveTimeout: minimumReceiveTimeout)

        // The server may return plain-text errors (e.g., "ERROR: Access denied ...")
        // before the JSON protocol starts. Surface these directly instead of letting
        // JSONSerialization throw a confusing parse error.
        if raw.hasPrefix("ERROR:") {
            throw CLIError(message: raw)
        }

        guard let responseData = raw.data(using: .utf8) else {
            throw CLIError(message: "Invalid UTF-8 v2 response")
        }
        guard let response = try JSONSerialization.jsonObject(with: responseData, options: []) as? [String: Any] else {
            throw CLIError(message: "Invalid v2 response: \(raw)")
        }

        if let ok = response["ok"] as? Bool, ok {
            return (response["result"] as? [String: Any]) ?? [:]
        }

        if let error = response["error"] as? [String: Any] {
            let code = (error["code"] as? String) ?? "error"
            let message = (error["message"] as? String) ?? "Unknown v2 error"
            throw CLIError(message: "\(code): \(message)")
        }

        throw CLIError(message: "v2 request failed")
    }
}

struct CLIProcessResult {
    let status: Int32
    let stdout: String
    let stderr: String
    let timedOut: Bool
}

enum CLIProcessRunner {
    static func runProcess(
        executablePath: String,
        arguments: [String],
        stdinText: String? = nil,
        timeout: TimeInterval? = nil
    ) -> CLIProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdinPipe: Pipe?
        if stdinText != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            stdinPipe = pipe
        } else {
            stdinPipe = nil
        }

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            finished.signal()
        }

        do {
            try process.run()
        } catch {
            return CLIProcessResult(status: 1, stdout: "", stderr: String(describing: error), timedOut: false)
        }

        if let stdinText, let stdinPipe {
            if let data = stdinText.data(using: .utf8) {
                stdinPipe.fileHandleForWriting.write(data)
            }
            stdinPipe.fileHandleForWriting.closeFile()
        }

        let timedOut: Bool
        if let timeout {
            switch finished.wait(timeout: .now() + timeout) {
            case .success:
                timedOut = false
            case .timedOut:
                timedOut = true
                terminate(process: process, finished: finished)
            }
        } else {
            finished.wait()
            timedOut = false
        }

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        var stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if timedOut {
            let timeoutMessage = "process timed out"
            if stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                stderr = timeoutMessage
            } else if !stderr.contains(timeoutMessage) {
                stderr += "\n\(timeoutMessage)"
            }
        }

        return CLIProcessResult(
            status: timedOut ? 124 : process.terminationStatus,
            stdout: stdout,
            stderr: stderr,
            timedOut: timedOut
        )
    }

    private static func terminate(process: Process, finished: DispatchSemaphore) {
        guard process.isRunning else { return }
        process.terminate()
        if finished.wait(timeout: .now() + 0.5) == .success {
            return
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        _ = finished.wait(timeout: .now() + 0.5)
    }
}

/// Execution context passed to a `CommandDescriptor`'s `execute` closure.
///
/// Bundles everything a command body previously read from `run()`'s locals
/// (commandArgs, client, jsonOutput, idFormat, windowId, and the literal
/// command name, needed by handlers shared across several names such as
/// the tmux-compat group).
struct CommandContext {
    let command: String
    let commandArgs: [String]
    let client: SocketClient
    let jsonOutput: Bool
    let idFormat: CLIIDFormat
    /// True when the user passed `--id-format` explicitly (distinct from
    /// `idFormat`, which always has a concrete value). Only `rpc` cares
    /// about this distinction today.
    let idFormatArgProvided: Bool
    let windowId: String?
}

enum CLICommandConnectionPolicy {
    /// The command is parsed and validated first, then receives one connected client.
    case socket
    /// The command owns any process/socket work it needs and must not be preconnected.
    case local
}

enum CLICommandHelpPolicy {
    /// `--help` is handled by Programa without acquiring a socket.
    case programa
    /// Help flags are forwarded verbatim to the wrapped/internal command.
    case passthrough
}

/// Typed preflight contracts that must succeed before a socket client exists.
/// `.registered` routes through the exhaustive command grammar table; bespoke
/// cases retain additional semantic validation where the schema is richer.
enum CLICommandArgumentContract {
    case registered
    case noArguments
    case focusPanel
    case readScreen
    case waitSurface
    case setProgress
    case listLog
}

/// Single source of truth for a CLI command's name(s), its one-line entry in
/// the grouped `Commands:` help block, and how it executes.
///
/// This collapses what used to be independently maintained in three places:
/// the kebab-case dispatch switch, the free-text `usage()` help string, and
/// (implicitly) the "is this a known command" check used for unknown-command
/// handling. A command added to the table automatically gets dispatch,
/// help-list membership, and unknown-command exclusion in one place —
/// nothing else to keep in sync.
///
/// Commands whose implementation is intercepted in `run()` still have a
/// descriptor so their connection, help, and argument policies are decided
/// before any socket work begins.
///
/// A descriptor with `names: []` is a pure help-text spacer/section-comment
/// (e.g. the blank line + "# tmux compatibility commands" header) — it
/// contributes lines to the help block but never participates in dispatch.
///
/// Explicit non-goal: this table only unifies CLI-side name → behavior
/// knowledge. It does not attempt to unify with the app-side v2 method
/// switch (`Sources/TerminalController.swift`'s `processV2Command`) — that's
/// server code with different concerns (method routing, not CLI UX).
struct CommandDescriptor {
    /// Kebab-case name(s) that route to this descriptor. More than one name
    /// means the names are aliases sharing one handler (e.g. tmux-compat
    /// commands, or `rename-workspace`/`rename-window`).
    let names: [String]
    /// Lines contributed verbatim, in order, to the `Commands:` section of
    /// `usage()`. Empty means the command exists but is intentionally
    /// undocumented (matches several legacy/internal commands that were
    /// already missing from the old free-text help).
    let helpLines: [String]
    let connectionPolicy: CLICommandConnectionPolicy
    let helpPolicy: CLICommandHelpPolicy
    let argumentContract: CLICommandArgumentContract
    /// Full, verbatim `programa <command> --help` text (the `Usage: ...`
    /// block), or `nil` if this command has no detailed usage text (falls
    /// back to `helpLines` only, or to one of the per-family
    /// `*SubcommandUsage` helpers checked before the table lookup).
    let detailedUsage: String?
    /// Executes the command. `nil` for commands implemented directly by
    /// `run()` before generic socket dispatch.
    let execute: ((CommandContext) throws -> Void)?

    init(
        names: [String],
        helpLines: [String],
        connectionPolicy: CLICommandConnectionPolicy = .socket,
        helpPolicy: CLICommandHelpPolicy = .programa,
        argumentContract: CLICommandArgumentContract = .registered,
        detailedUsage: String? = nil,
        execute: ((CommandContext) throws -> Void)?
    ) {
        self.names = names
        self.helpLines = helpLines
        self.connectionPolicy = connectionPolicy
        self.helpPolicy = helpPolicy
        self.argumentContract = argumentContract
        self.detailedUsage = detailedUsage
        self.execute = execute
    }
}

struct ProgramaCLI {
    let args: [String]

    private static let debugLastSocketHintPath = "/tmp/programa-last-socket-path"

    static func normalizedEnvValue(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func pathIsSocket(_ path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFSOCK
    }

    private static func debugSocketPathFromHintFile() -> String? {
#if DEBUG
        guard let raw = try? String(contentsOfFile: debugLastSocketHintPath, encoding: .utf8) else {
            return nil
        }
        guard let hinted = normalizedEnvValue(raw),
              hinted.hasPrefix("/tmp/programa-debug"),
              hinted.hasSuffix(".sock"),
              pathIsSocket(hinted) else {
            return nil
        }
        return hinted
#else
        return nil
#endif
    }

    private static func defaultSocketPath(environment: [String: String]) -> String {
        if let explicit = normalizedEnvValue(environment["PROGRAMA_SOCKET_PATH"]) {
            return explicit
        }
#if DEBUG
        if let hinted = debugSocketPathFromHintFile() {
            return hinted
        }
        return "/tmp/programa-debug.sock"
#else
        return "/tmp/programa.sock"
#endif
    }

    func run() throws {
        let processEnv = ProcessInfo.processInfo.environment
        let envSocketPath: String? = {
            for key in ["PROGRAMA_SOCKET_PATH", "PROGRAMA_SOCKET"] {
                guard let raw = processEnv[key] else { continue }
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
            return nil
        }()
        var socketPath = envSocketPath ?? CLISocketPathResolver.defaultSocketPath
        var socketPathSource: CLISocketPathSource
        if let envSocketPath {
            socketPathSource = CLISocketPathResolver.isImplicitDefaultPath(envSocketPath) ? .implicitDefault : .environment
        } else {
            socketPathSource = .implicitDefault
        }
        var jsonOutput = false
        var idFormatArg: String? = nil
        var windowId: String? = nil
        var socketPasswordArg: String? = nil

        var index = 1
        while index < args.count {
            let arg = args[index]
            if arg == "--socket" {
                guard index + 1 < args.count else {
                    throw CLIError(message: "--socket requires a path")
                }
                socketPath = args[index + 1]
                socketPathSource = .explicitFlag
                index += 2
                continue
            }
            if arg == "--json" {
                jsonOutput = true
                index += 1
                continue
            }
            if arg == "--id-format" {
                guard index + 1 < args.count else {
                    throw CLIError(message: "--id-format requires a value (refs|uuids|both)")
                }
                idFormatArg = args[index + 1]
                index += 2
                continue
            }
            if arg == "--window" {
                guard index + 1 < args.count else {
                    throw CLIError(message: "--window requires a window id")
                }
                windowId = args[index + 1]
                index += 2
                continue
            }
            if arg == "--password" {
                guard index + 1 < args.count else {
                    throw CLIError(message: "--password requires a value")
                }
                socketPasswordArg = args[index + 1]
                index += 2
                continue
            }
            if arg == "-v" || arg == "--version" {
                print(versionSummary())
                return
            }
            if arg == "-h" || arg == "--help" {
                print(usage())
                return
            }
            if arg.hasPrefix("-") {
                throw CLIError(message: "Unknown global option: \(arg)")
            }
            break
        }

        guard index < args.count else {
            print(usage())
            throw CLIError(message: "Missing command")
        }

        let command = args[index]
        let commandArgs = Array(args[(index + 1)...])

        guard let descriptor = commandDescriptor(named: command) else {
            // Filesystem opening is a fallback only after command lookup, so a
            // registered command can never be mistaken for a path.
            if looksLikePath(command) {
                let resolvedSocketPath = CLISocketPathResolver.resolve(
                    requestedPath: socketPath,
                    source: socketPathSource,
                    environment: processEnv
                )
                try openPath(command, socketPath: resolvedSocketPath)
                return
            }
            throw CLIError(message: "Unknown command: \(command). Run 'programa help' to see available commands.")
        }

        if descriptor.helpPolicy == .programa,
           commandArgs.contains(where: { $0 == "--help" || $0 == "-h" }) {
            guard dispatchSubcommandHelp(command: command, commandArgs: commandArgs) else {
                throw CLIError(message: "No help is available for command: \(command)")
            }
            return
        }

        try validateArguments(commandArgs, for: command, contract: descriptor.argumentContract)
        let idFormat = try resolvedIDFormat(jsonOutput: jsonOutput, raw: idFormatArg)

        var resolvedSocketPathCache: String?
        func resolveSocketPath() -> String {
            if let resolvedSocketPathCache { return resolvedSocketPathCache }
            let resolved = CLISocketPathResolver.resolve(
                requestedPath: socketPath,
                source: socketPathSource,
                environment: processEnv
            )
            resolvedSocketPathCache = resolved
            return resolved
        }

        if command == "version" {
            print(versionSummary())
            return
        }

        if command == "remote-daemon-status" {
            try runRemoteDaemonStatus(commandArgs: commandArgs, jsonOutput: jsonOutput)
            return
        }

        if command == "help" {
            print(usage())
            return
        }

        if command == "welcome" {
            printWelcome()
            return
        }

        if command == "shortcuts" {
            try runShortcuts(
                commandArgs: commandArgs,
                socketPath: resolveSocketPath(),
                explicitPassword: socketPasswordArg,
                jsonOutput: jsonOutput
            )
            return
        }

        if command == "feedback" {
            try runFeedback(
                commandArgs: commandArgs,
                socketPath: resolveSocketPath(),
                explicitPassword: socketPasswordArg,
                jsonOutput: jsonOutput
            )
            return
        }

        if command == "themes" {
            try runThemes(
                commandArgs: commandArgs,
                jsonOutput: jsonOutput
            )
            return
        }

        if command == "claude-teams" {
            try runClaudeTeams(
                commandArgs: commandArgs,
                socketPath: resolveSocketPath(),
                explicitPassword: socketPasswordArg
            )
            return
        }

        if command == "omo" {
            try runOMO(
                commandArgs: commandArgs,
                socketPath: resolveSocketPath(),
                explicitPassword: socketPasswordArg
            )
            return
        }

        if command == "omx" {
            try runOMX(
                commandArgs: commandArgs,
                socketPath: resolveSocketPath(),
                explicitPassword: socketPasswordArg
            )
            return
        }

        if command == "omc" {
            try runOMC(
                commandArgs: commandArgs,
                socketPath: resolveSocketPath(),
                explicitPassword: socketPasswordArg
            )
            return
        }

        // Codex hooks management (no socket needed)
        if command == "codex" {
            let sub = commandArgs.first?.lowercased() ?? "help"
            if sub == "install-hooks" || sub == "install-integration" {
                try runCodexInstallHooks()
                return
            } else if sub == "uninstall-hooks" || sub == "uninstall-integration" {
                try runCodexUninstallHooks()
                return
            }
        }

        // Claude Code integration management (no socket needed)
        if command == "claude" {
            let sub = commandArgs.first?.lowercased() ?? "help"
            if sub == "install-integration" {
                try runClaudeInstallIntegration()
                return
            } else if sub == "uninstall-integration" {
                try runClaudeUninstallIntegration()
                return
            }
            print("Usage: programa claude <install-integration|uninstall-integration>")
            throw CLIError(message: "Unknown claude subcommand: \(sub)")
        }

        // OpenCode plugin integration management (no socket needed)
        if command == "opencode" {
            let sub = commandArgs.first?.lowercased() ?? "help"
            if sub == "install-integration" {
                try runOpenCodeInstallIntegration()
                return
            } else if sub == "uninstall-integration" {
                try runOpenCodeUninstallIntegration()
                return
            }
            print("Usage: programa opencode <install-integration|uninstall-integration>")
            throw CLIError(message: "Unknown opencode subcommand: \(sub)")
        }

        // Codex hook handler: gracefully no-op when not inside programa
        // (before socket connection, so it doesn't fail when no socket exists)
        if command == "codex-hook" {
            guard ProcessInfo.processInfo.environment["PROGRAMA_SURFACE_ID"] != nil else {
                print("{}")
                return
            }
        }

        // OpenCode hook handler: gracefully no-op when not inside programa
        // (before socket connection, so it doesn't fail when no socket exists)
        if command == "opencode-hook" {
            guard ProcessInfo.processInfo.environment["PROGRAMA_SURFACE_ID"] != nil else {
                print("{}")
                return
            }
        }

        guard descriptor.connectionPolicy == .socket else {
            throw CLIError(message: "Unsupported \(command) subcommand")
        }
        guard let execute = descriptor.execute else {
            throw CLIError(message: "Command is unavailable: \(command)")
        }

        let resolvedSocketPath = resolveSocketPath()

        let client = SocketClient(path: resolvedSocketPath)
        try client.connect()
        defer { client.close() }

        try authenticateClientIfNeeded(
            client,
            explicitPassword: socketPasswordArg,
            socketPath: resolvedSocketPath
        )

        // If the user explicitly targets a window, focus it first so commands route correctly.
        if let windowId {
            let normalizedWindow = try normalizeWindowHandle(windowId, client: client) ?? windowId
            _ = try client.sendV2(method: "window.focus", params: ["window_id": normalizedWindow])
        }

        let ctx = CommandContext(
            command: command,
            commandArgs: commandArgs,
            client: client,
            jsonOutput: jsonOutput,
            idFormat: idFormat,
            idFormatArgProvided: idFormatArg != nil,
            windowId: windowId
        )
        try execute(ctx)
    }

    /// Single source of truth for command existence, help text, and dispatch.
    /// See `CommandDescriptor` for the collapsed-knowledge rationale (CT1).
    ///
    /// Order matches the historical `Commands:` help block, since that order
    /// is externally visible; dispatch itself is by name lookup and does not
    /// depend on array order.
    private func commandDescriptors() -> [CommandDescriptor] {
        // Built imperatively (rather than as one large `[...] + f() + [...]`
        // expression) because the Swift type-checker times out trying to
        // infer a single expression spanning this many array-literal +
        // function-call concatenations.
        var descriptors: [CommandDescriptor] = [
            // MARK: - Pre-connection specials (dispatched earlier in run();
            // documented here only so usage() has one source for help text).
            CommandDescriptor(
                names: ["welcome"],
                helpLines: ["welcome"],
                connectionPolicy: .local,
                detailedUsage: """
                Usage: programa welcome

                Show a welcome screen with the programa logo and useful shortcuts.
                Auto-runs once on first launch.
                """,
                execute: nil
            ),
            CommandDescriptor(
                names: ["shortcuts"],
                helpLines: ["shortcuts"],
                connectionPolicy: .local,
                detailedUsage: """
                Usage: programa shortcuts

                Open the Settings window to Keyboard Shortcuts.
                """,
                execute: nil
            ),
            CommandDescriptor(
                names: ["feedback"],
                helpLines: ["feedback [--email <email> --body <text> [--image <path> ...]]  (opens GitHub issues; direct submission disabled)"],
                connectionPolicy: .local,
                detailedUsage: """
                Usage: programa feedback
                       programa feedback --email <email> --body <text> [--image <path> ...]

                Without args, opens the GitHub issues page (https://github.com/darkroomengineering/programa/issues) in your browser.

                Direct feedback submission is disabled; --email/--body/--image are accepted but the app will
                return an error telling you to report the issue on GitHub instead.

                Flags:
                  --email <email>   Contact email for follow-up (submission disabled)
                  --body <text>     Feedback body (submission disabled)
                  --image <path>    Attach an image file, repeat for multiple images (submission disabled)
                """,
                execute: nil
            ),
            CommandDescriptor(names: ["themes"], helpLines: ["themes [list|set|clear]"], connectionPolicy: .local, execute: nil),
            CommandDescriptor(names: ["claude-teams"], helpLines: ["claude-teams [claude-args...]"], connectionPolicy: .local, helpPolicy: .passthrough, execute: nil),
            CommandDescriptor(names: ["omo"], helpLines: ["omo [opencode-args...]"], connectionPolicy: .local, helpPolicy: .passthrough, execute: nil),
            CommandDescriptor(names: ["omx"], helpLines: ["omx [omx-args...]"], connectionPolicy: .local, helpPolicy: .passthrough, execute: nil),
            CommandDescriptor(names: ["omc"], helpLines: ["omc [omc-args...]"], connectionPolicy: .local, helpPolicy: .passthrough, execute: nil),
            CommandDescriptor(
                names: ["codex"],
                helpLines: ["codex <install-integration|uninstall-integration>"],
                connectionPolicy: .local,
                detailedUsage: """
                Usage: programa codex <install-integration|uninstall-integration>
                       programa codex <install-hooks|uninstall-hooks>  (legacy aliases, still supported)

                Install or remove Programa's Codex notification hooks in
                ~/.codex/hooks.json (or $CODEX_HOME/hooks.json), and the
                `programa` agent skill (SKILL.md) into ~/.agents/skills/programa/.
                """,
                execute: nil
            ),
            CommandDescriptor(
                names: ["claude"],
                helpLines: ["claude <install-integration|uninstall-integration>"],
                connectionPolicy: .local,
                detailedUsage: """
                Usage: programa claude <install-integration|uninstall-integration>

                Install or remove Programa's persistent Claude Code hooks in
                ~/.claude/settings.json (or $CLAUDE_CONFIG_DIR/settings.json),
                and the `programa` agent skill (SKILL.md) into
                ~/.claude/skills/programa/.
                Unlike the runtime wrapper, this makes the integration work from
                any terminal, not just programa's.
                """,
                execute: nil
            ),
            CommandDescriptor(
                names: ["opencode"],
                helpLines: ["opencode <install-integration|uninstall-integration>"],
                connectionPolicy: .local,
                detailedUsage: """
                Usage: programa opencode <install-integration|uninstall-integration>

                Install or remove Programa's OpenCode plugin in
                ~/.config/opencode/plugins/programa.js (or $OPENCODE_CONFIG_DIR/plugins/programa.js),
                and the `programa` agent skill (SKILL.md) into
                ~/.config/opencode/skills/programa/ (or $OPENCODE_CONFIG_DIR/skills/programa/).
                OpenCode auto-loads local plugin files, so no opencode.json edit or
                npm install is needed.
                """,
                execute: nil
            ),

            CommandDescriptor(
                names: ["ping"],
                helpLines: ["ping"],
                argumentContract: .noArguments,
                detailedUsage: """
                Usage: programa ping

                Check connectivity to the programa socket server.
                """,
                execute: { ctx in
                    _ = try ctx.client.sendV2(method: "system.ping")
                    print("PONG")
                }
            ),

            CommandDescriptor(names: ["version"], helpLines: ["version"], connectionPolicy: .local, execute: nil),

            CommandDescriptor(
                names: ["capabilities"],
                helpLines: ["capabilities"],
                detailedUsage: """
                Usage: programa capabilities

                Print server capabilities as JSON.
                """,
                execute: { ctx in
                    let response = try ctx.client.sendV2(method: "system.capabilities")
                    print(self.jsonString(self.formatIDs(response, mode: ctx.idFormat)))
                }
            ),

            CommandDescriptor(
                names: ["rpc"],
                helpLines: ["rpc <method> [json-params]"],
                detailedUsage: """
                Usage: programa rpc <method> [json-params]

                Call a raw v2 method with an optional JSON object for params.
                Example: programa rpc surface.report_tty '{"workspace_id":"...","surface_id":"...","tty_name":"ttys001"}'
                """,
                execute: { ctx in
                    guard let method = ctx.commandArgs.first?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !method.isEmpty else {
                        throw CLIError(message: "Usage: programa rpc <method> [json-params]")
                    }
                    let params = try self.parseRPCParams(Array(ctx.commandArgs.dropFirst()))
                    let response = try ctx.client.sendV2(method: method, params: params)
                    let output: Any = ctx.idFormatArgProvided ? self.formatIDs(response, mode: ctx.idFormat) : response
                    print(self.jsonString(output))
                }
            ),

            CommandDescriptor(
                names: ["identify"],
                helpLines: ["identify [--workspace <id|ref>] [--surface <id|ref>] [--no-caller]"],
                detailedUsage: """
                Usage: programa identify [--workspace <id|ref>] [--surface <id|ref>] [--no-caller]

                Print server identity and caller context details.

                Flags:
                  --workspace <id|ref>   Caller workspace context (default: $PROGRAMA_WORKSPACE_ID)
                  --surface <id|ref>     Caller surface context (default: $PROGRAMA_SURFACE_ID)
                  --no-caller                  Omit caller context from the request
                """,
                execute: { ctx in
                    var params: [String: Any] = [:]
                    let includeCaller = !self.hasFlag(ctx.commandArgs, name: "--no-caller")
                    if includeCaller {
                        let idWsFlag = self.optionValue(ctx.commandArgs, name: "--workspace")
                        let workspaceArg = idWsFlag ?? (ctx.windowId == nil ? ProcessInfo.processInfo.environment["PROGRAMA_WORKSPACE_ID"] : nil)
                        let surfaceArg = self.optionValue(ctx.commandArgs, name: "--surface") ?? (idWsFlag == nil && ctx.windowId == nil ? ProcessInfo.processInfo.environment["PROGRAMA_SURFACE_ID"] : nil)
                        if workspaceArg != nil || surfaceArg != nil {
                            let workspaceId = try self.normalizeWorkspaceHandle(
                                workspaceArg,
                                client: ctx.client,
                                allowCurrent: surfaceArg != nil
                            )
                            var caller: [String: Any] = [:]
                            if let workspaceId {
                                caller["workspace_id"] = workspaceId
                            }
                            if surfaceArg != nil {
                                guard let surfaceId = try self.normalizeSurfaceHandle(
                                    surfaceArg,
                                    client: ctx.client,
                                    workspaceHandle: workspaceId
                                ) else {
                                    throw CLIError(message: "Invalid surface handle")
                                }
                                caller["surface_id"] = surfaceId
                            }
                            if !caller.isEmpty {
                                params["caller"] = caller
                            }
                        }
                    }
                    let response = try ctx.client.sendV2(method: "system.identify", params: params)
                    print(self.jsonString(self.formatIDs(response, mode: ctx.idFormat)))
                }
            ),

            CommandDescriptor(
                names: ["list-windows"],
                helpLines: ["list-windows"],
                detailedUsage: """
                Usage: programa list-windows

                List open windows.
                """,
                execute: { ctx in
                    let listed = try ctx.client.sendV2(method: "window.list")
                    let windows = listed["windows"] as? [[String: Any]] ?? []
                    if ctx.jsonOutput {
                        let payload = windows.map { item -> [String: Any] in
                            var dict: [String: Any] = [
                                "index": self.intFromAny(item["index"]) ?? 0,
                                "id": (item["id"] as? String) ?? "",
                                "key": (item["key"] as? Bool) ?? false,
                                "workspace_count": self.intFromAny(item["workspace_count"]) ?? 0,
                            ]
                            dict["selected_workspace_id"] = item["selected_workspace_id"] as? String ?? NSNull()
                            return dict
                        }
                        print(self.jsonString(payload))
                    } else if windows.isEmpty {
                        print("No windows")
                    } else {
                        let lines = windows.map { item -> String in
                            let selected = ((item["key"] as? Bool) ?? false) ? "*" : " "
                            let idx = self.intFromAny(item["index"]) ?? 0
                            let id = (item["id"] as? String) ?? ""
                            let selectedWs = (item["selected_workspace_id"] as? String) ?? "none"
                            let workspaceCount = self.intFromAny(item["workspace_count"]) ?? 0
                            return "\(selected) \(idx): \(id) selected_workspace=\(selectedWs) workspaces=\(workspaceCount)"
                        }
                        print(lines.joined(separator: "\n"))
                    }
                }
            ),

            CommandDescriptor(
                names: ["current-window"],
                helpLines: ["current-window"],
                detailedUsage: """
                Usage: programa current-window

                Print the currently selected window ID.
                """,
                execute: { ctx in
                    let response = try ctx.client.sendV2(method: "window.current")
                    let windowId = (response["window_id"] as? String) ?? ""
                    if ctx.jsonOutput {
                        print(self.jsonString(["window_id": windowId]))
                    } else {
                        print(windowId)
                    }
                }
            ),

            CommandDescriptor(
                names: ["new-window"],
                helpLines: ["new-window"],
                detailedUsage: """
                Usage: programa new-window

                Create a new window.

                Example:
                  programa new-window
                """,
                execute: { ctx in
                    let response = try ctx.client.sendV2(method: "window.create")
                    print("OK \((response["window_id"] as? String) ?? "")")
                }
            ),

            CommandDescriptor(
                names: ["focus-window"],
                helpLines: ["focus-window --window <id>"],
                detailedUsage: """
                Usage: programa focus-window --window <id|ref>

                Focus (bring to front) the specified window.

                Flags:
                  --window <id|ref>   Window to focus (required)

                Example:
                  programa focus-window --window <window-uuid>
                  programa focus-window --window window:1
                """,
                execute: { ctx in
                    guard let target = self.optionValue(ctx.commandArgs, name: "--window") else {
                        throw CLIError(message: "focus-window requires --window")
                    }
                    // v1 only ever accepted a literal window UUID (no index/ref resolution) — preserve
                    // that exactly rather than widening acceptance via normalizeWindowHandle.
                    guard self.isUUID(target.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                        throw CLIError(message: "ERROR: Invalid window id")
                    }
                    do {
                        _ = try ctx.client.sendV2(method: "window.focus", params: ["window_id": target])
                        print("OK")
                    } catch {
                        throw CLIError(message: "ERROR: Window not found")
                    }
                }
            ),

            CommandDescriptor(
                names: ["close-window"],
                helpLines: ["close-window --window <id>"],
                detailedUsage: """
                Usage: programa close-window --window <id|ref>

                Close the specified window.

                Flags:
                  --window <id|ref>   Window to close (required)

                Example:
                  programa close-window --window 0
                  programa close-window --window window:1
                """,
                execute: { ctx in
                    guard let target = self.optionValue(ctx.commandArgs, name: "--window") else {
                        throw CLIError(message: "close-window requires --window")
                    }
                    guard self.isUUID(target.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                        throw CLIError(message: "ERROR: Invalid window id")
                    }
                    do {
                        _ = try ctx.client.sendV2(method: "window.close", params: ["window_id": target])
                        print("OK")
                    } catch {
                        throw CLIError(message: "ERROR: Window not found")
                    }
                }
            ),

            CommandDescriptor(
                names: ["move-workspace-to-window"],
                helpLines: ["move-workspace-to-window --workspace <id|ref> --window <id|ref>"],
                detailedUsage: """
                Usage: programa move-workspace-to-window --workspace <id|ref> --window <id|ref>

                Move a workspace to a different window.

                Flags:
                  --workspace <id|ref>   Workspace to move (required)
                  --window <id|ref>      Target window (required)

                Example:
                  programa move-workspace-to-window --workspace workspace:2 --window window:1
                """,
                execute: { ctx in
                    guard let workspaceRaw = self.optionValue(ctx.commandArgs, name: "--workspace") else {
                        throw CLIError(message: "move-workspace-to-window requires --workspace")
                    }
                    guard let windowRaw = self.optionValue(ctx.commandArgs, name: "--window") else {
                        throw CLIError(message: "move-workspace-to-window requires --window")
                    }
                    var params: [String: Any] = [:]
                    let wsId = try self.normalizeWorkspaceHandle(workspaceRaw, client: ctx.client)
                    if let wsId { params["workspace_id"] = wsId }
                    let winId = try self.normalizeWindowHandle(windowRaw, client: ctx.client)
                    if let winId { params["window_id"] = winId }
                    let payload = try ctx.client.sendV2(method: "workspace.move_to_window", params: params)
                    self.printV2Payload(payload, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat, fallbackText: self.v2OKSummary(payload, idFormat: ctx.idFormat, kinds: ["workspace", "window"]))
                }
            ),

            CommandDescriptor(
                names: ["reorder-workspace"],
                helpLines: ["reorder-workspace --workspace <id|ref> (--index <n> | --before <id|ref> | --after <id|ref>) [--window <id|ref>]"],
                detailedUsage: """
                Usage: programa reorder-workspace [--workspace <id|ref> | <id|ref>] [flags]

                Reorder a workspace within its window.

                Flags:
                  --workspace <id|ref>   Workspace to reorder (required unless passed positionally)
                  --index <n>                  Place at this index
                  --before <id|ref>      Place before this workspace
                  --before-workspace <id|ref>
                                             Alias for --before
                  --after <id|ref>       Place after this workspace
                  --after-workspace <id|ref>
                                             Alias for --after
                  --window <id|ref>      Window context

                Example:
                  programa reorder-workspace --workspace workspace:2 --index 0
                  programa reorder-workspace --workspace workspace:3 --after workspace:1
                """,
                execute: { ctx in
                    try self.runReorderWorkspace(commandArgs: ctx.commandArgs, client: ctx.client, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat)
                }
            ),

            CommandDescriptor(
                names: ["workspace-action"],
                helpLines: ["workspace-action --action <name> [--workspace <id|ref>] [--title <text>] [--color <name|#hex>] [--description <text>]"],
                detailedUsage: """
                Usage: programa workspace-action --action <name> [flags]

                Perform workspace context-menu actions from CLI/socket.

                Actions:
                  pin | unpin
                  rename | clear-name
                  set-description | clear-description
                  move-up | move-down | move-top
                  close-others | close-above | close-below
                  mark-read | mark-unread
                  set-color | clear-color

                Flags:
                  --action <name>              Action name (required if not positional)
                  --workspace <id|ref>   Target workspace (default: current/$PROGRAMA_WORKSPACE_ID)
                  --title <text>               Title for rename
                  --color <name|#hex>          Color for set-color (name or #RRGGBB hex)
                  --description <text>         Description for set-description

                Named colors:
                  Red, Crimson, Orange, Amber, Olive, Green, Teal, Aqua,
                  Blue, Navy, Indigo, Purple, Magenta, Rose, Brown, Charcoal

                Example:
                  programa workspace-action --workspace workspace:2 --action pin
                  programa workspace-action --action rename --title "infra"
                  programa workspace-action close-others
                  programa workspace-action --action set-color --color blue
                  programa workspace-action --action set-color --color "#C0392B"
                  programa workspace-action set-color Amber
                  programa workspace-action --action set-description --description "Ship checklist"
                  programa workspace-action --action set-description $'Ship checklist\n- verify build\n- post notes'
                  programa workspace-action clear-color
                """,
                execute: { ctx in
                    try self.runWorkspaceAction(commandArgs: ctx.commandArgs, client: ctx.client, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat, windowOverride: ctx.windowId)
                }
            ),

            CommandDescriptor(
                names: ["list-workspaces"],
                helpLines: ["list-workspaces"],
                detailedUsage: """
                Usage: programa list-workspaces

                List workspaces in the current window.

                Example:
                  programa list-workspaces
                """,
                execute: { ctx in
                    let payload = try ctx.client.sendV2(method: "workspace.list")
                    if ctx.jsonOutput {
                        print(self.jsonString(self.formatIDs(payload, mode: ctx.idFormat)))
                    } else {
                        let workspaces = payload["workspaces"] as? [[String: Any]] ?? []
                        if workspaces.isEmpty {
                            print("No workspaces")
                        } else {
                            for ws in workspaces {
                                let selected = (ws["selected"] as? Bool) == true
                                let handle = self.textHandle(ws, idFormat: ctx.idFormat)
                                let title = (ws["title"] as? String) ?? ""
                                let remoteTag: String = {
                                    guard let remote = ws["remote"] as? [String: Any],
                                          (remote["enabled"] as? Bool) == true else {
                                        return ""
                                    }
                                    let state = (remote["state"] as? String) ?? "unknown"
                                    return "  [ssh:\(state)]"
                                }()
                                let prefix = selected ? "* " : "  "
                                let selTag = selected ? "  [selected]" : ""
                                let titlePart = title.isEmpty ? "" : "  \(title)"
                                print("\(prefix)\(handle)\(titlePart)\(remoteTag)\(selTag)")
                            }
                        }
                    }
                }
            ),

            CommandDescriptor(
                names: ["new-workspace"],
                helpLines: ["new-workspace [--name <title>] [--description <text>] [--cwd <path>] [--command <text>]"],
                detailedUsage: """
                Usage: programa new-workspace [--name <title>] [--description <text>] [--cwd <path>] [--command <text>]

                Create a new workspace in the current window.

                Flags:
                  --name <title>     Set a custom name for the new workspace
                  --description <text> Set a custom description for the new workspace
                  --cwd <path>       Set the working directory for the new workspace
                  --command <text>   Send text+Enter to the new workspace after creation

                Example:
                  programa new-workspace
                  programa new-workspace --name "Build Server"
                  programa new-workspace --name "Launch" --description "Ship checklist"
                  programa new-workspace --cwd ~/projects/myapp
                  programa new-workspace --cwd . --command "npm test"
                """,
                execute: { ctx in
                    let (commandOpt, rem0) = self.parseOption(ctx.commandArgs, name: "--command")
                    let (cwdOpt, rem1) = self.parseOption(rem0, name: "--cwd")
                    let (nameOpt, rem2) = self.parseOption(rem1, name: "--name")
                    let (descriptionOpt, remaining) = self.parseOption(rem2, name: "--description")
                    if let unknown = remaining.first(where: { $0.hasPrefix("--") }) {
                        throw CLIError(message: "new-workspace: unknown flag '\(unknown)'. Known flags: --name <title>, --description <text>, --command <text>, --cwd <path>")
                    }
                    var params: [String: Any] = [:]
                    if let cwdOpt {
                        let resolved = self.resolvePath(cwdOpt)
                        params["cwd"] = resolved
                    }
                    if let nameOpt {
                        params["title"] = nameOpt
                    }
                    if let descriptionOpt {
                        params["description"] = descriptionOpt
                    }
                    let response = try ctx.client.sendV2(method: "workspace.create", params: params)
                    let wsId = (response["workspace_ref"] as? String) ?? (response["workspace_id"] as? String) ?? ""
                    print("OK \(wsId)")
                    if let commandText = commandOpt, !wsId.isEmpty {
                        let text = self.unescapeSendText(commandText + "\\n")
                        let sendParams: [String: Any] = ["text": text, "workspace_id": wsId]
                        _ = try ctx.client.sendV2(method: "surface.send_text", params: sendParams)
                    }
                }
            ),

            ]
        descriptors += self.sshDescriptors()
        descriptors += [

            CommandDescriptor(
                names: ["new-split"],
                helpLines: ["new-split <left|right|up|down> [--workspace <id|ref>] [--surface <id|ref>] [--panel <id|ref>]"],
                detailedUsage: """
                Usage: programa new-split <left|right|up|down> [flags]

                Split the current pane in the given direction.

                Flags:
                  --workspace <id|ref>   Target workspace (default: $PROGRAMA_WORKSPACE_ID)
                  --surface <id|ref>     Surface to split from (default: $PROGRAMA_SURFACE_ID)
                  --panel <id|ref>       Alias for --surface

                Example:
                  programa new-split right
                  programa new-split down --workspace workspace:1
                """,
                execute: { ctx in
                    let (wsArg, rem0) = self.parseOption(ctx.commandArgs, name: "--workspace")
                    let (panelArg, rem1) = self.parseOption(rem0, name: "--panel")
                    let (sfArg, rem2) = self.parseOption(rem1, name: "--surface")
                    let workspaceArg = wsArg ?? (ctx.windowId == nil ? ProcessInfo.processInfo.environment["PROGRAMA_WORKSPACE_ID"] : nil)
                    let surfaceRaw = sfArg ?? panelArg ?? (workspaceArg == nil && ctx.windowId == nil ? ProcessInfo.processInfo.environment["PROGRAMA_SURFACE_ID"] : nil)
                    guard let direction = rem2.first else {
                        throw CLIError(message: "new-split requires a direction")
                    }
                    var params: [String: Any] = ["direction": direction]
                    let wsId = try self.normalizeWorkspaceHandle(workspaceArg, client: ctx.client)
                    if let wsId { params["workspace_id"] = wsId }
                    let sfId = try self.normalizeSurfaceHandle(surfaceRaw, client: ctx.client, workspaceHandle: wsId)
                    if let sfId { params["surface_id"] = sfId }
                    let payload = try ctx.client.sendV2(method: "surface.split", params: params)
                    self.printV2Payload(payload, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat, fallbackText: self.v2OKSummary(payload, idFormat: ctx.idFormat))
                }
            ),

            CommandDescriptor(
                names: ["list-panes"],
                helpLines: ["list-panes [--workspace <id|ref>]"],
                detailedUsage: """
                Usage: programa list-panes [--workspace <id|ref>]

                List panes in a workspace.

                Flags:
                  --workspace <id|ref>   Workspace context (default: $PROGRAMA_WORKSPACE_ID)

                Example:
                  programa list-panes
                  programa list-panes --workspace workspace:2
                """,
                execute: { ctx in
                    let workspaceArg = self.workspaceFromArgsOrEnv(ctx.commandArgs, windowOverride: ctx.windowId)
                    var params: [String: Any] = [:]
                    let wsId = try self.normalizeWorkspaceHandle(workspaceArg, client: ctx.client)
                    if let wsId { params["workspace_id"] = wsId }
                    let payload = try ctx.client.sendV2(method: "pane.list", params: params)
                    if ctx.jsonOutput {
                        print(self.jsonString(self.formatIDs(payload, mode: ctx.idFormat)))
                    } else {
                        let panes = payload["panes"] as? [[String: Any]] ?? []
                        if panes.isEmpty {
                            print("No panes")
                        } else {
                            for pane in panes {
                                let focused = (pane["focused"] as? Bool) == true
                                let handle = self.textHandle(pane, idFormat: ctx.idFormat)
                                let count = pane["surface_count"] as? Int ?? 0
                                let prefix = focused ? "* " : "  "
                                let focusTag = focused ? "  [focused]" : ""
                                print("\(prefix)\(handle)  [\(count) surface\(count == 1 ? "" : "s")]\(focusTag)")
                            }
                        }
                    }
                }
            ),

            CommandDescriptor(
                names: ["list-pane-surfaces"],
                helpLines: ["list-pane-surfaces [--workspace <id|ref>] [--pane <id|ref>]"],
                detailedUsage: """
                Usage: programa list-pane-surfaces [--workspace <id|ref>] [--pane <id|ref>]

                List surfaces in a pane.

                Flags:
                  --workspace <id|ref>   Workspace context (default: $PROGRAMA_WORKSPACE_ID)
                  --pane <id|ref>        Restrict to a specific pane (default: focused pane)

                Example:
                  programa list-pane-surfaces
                  programa list-pane-surfaces --workspace workspace:2 --pane pane:1
                """,
                execute: { ctx in
                    let workspaceArg = self.workspaceFromArgsOrEnv(ctx.commandArgs, windowOverride: ctx.windowId)
                    let paneRaw = self.optionValue(ctx.commandArgs, name: "--pane")
                    var params: [String: Any] = [:]
                    let wsId = try self.normalizeWorkspaceHandle(workspaceArg, client: ctx.client)
                    if let wsId { params["workspace_id"] = wsId }
                    let paneId = try self.normalizePaneHandle(paneRaw, client: ctx.client, workspaceHandle: wsId)
                    if let paneId { params["pane_id"] = paneId }
                    let payload = try ctx.client.sendV2(method: "pane.surfaces", params: params)
                    if ctx.jsonOutput {
                        print(self.jsonString(self.formatIDs(payload, mode: ctx.idFormat)))
                    } else {
                        let surfaces = payload["surfaces"] as? [[String: Any]] ?? []
                        if surfaces.isEmpty {
                            print("No surfaces in pane")
                        } else {
                            for surface in surfaces {
                                let selected = (surface["selected"] as? Bool) == true
                                let handle = self.textHandle(surface, idFormat: ctx.idFormat)
                                let title = (surface["title"] as? String) ?? ""
                                let prefix = selected ? "* " : "  "
                                let selTag = selected ? "  [selected]" : ""
                                print("\(prefix)\(handle)  \(title)\(selTag)")
                            }
                        }
                    }
                }
            ),

            ]
        descriptors += self.treeDescriptors()
        descriptors += [

            CommandDescriptor(
                names: ["focus-pane"],
                helpLines: ["focus-pane --pane <id|ref> [--workspace <id|ref>]"],
                detailedUsage: """
                Usage: programa focus-pane [--pane <id|ref> | <id|ref>] [flags]

                Focus the specified pane.

                Flags:
                  --pane <id|ref>          Pane to focus (required unless passed positionally)
                  --workspace <id|ref>     Workspace context (default: $PROGRAMA_WORKSPACE_ID)

                Example:
                  programa focus-pane --pane pane:2
                  programa focus-pane pane:1
                  programa focus-pane --pane pane:1 --workspace workspace:2
                """,
                execute: { ctx in
                    let workspaceArg = self.workspaceFromArgsOrEnv(ctx.commandArgs, windowOverride: ctx.windowId)
                    guard let paneRaw = self.optionValue(ctx.commandArgs, name: "--pane") ?? ctx.commandArgs.first else {
                        throw CLIError(message: "focus-pane requires --pane <id|ref>")
                    }
                    var params: [String: Any] = [:]
                    let wsId = try self.normalizeWorkspaceHandle(workspaceArg, client: ctx.client)
                    if let wsId { params["workspace_id"] = wsId }
                    let paneId = try self.normalizePaneHandle(paneRaw, client: ctx.client, workspaceHandle: wsId)
                    if let paneId { params["pane_id"] = paneId }
                    let payload = try ctx.client.sendV2(method: "pane.focus", params: params)
                    self.printV2Payload(payload, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat, fallbackText: self.v2OKSummary(payload, idFormat: ctx.idFormat, kinds: ["pane", "workspace"]))
                }
            ),

            CommandDescriptor(
                names: ["new-pane"],
                helpLines: ["new-pane [--type <terminal|browser>] [--direction <left|right|up|down>] [--workspace <id|ref>] [--url <url>]"],
                detailedUsage: """
                Usage: programa new-pane [flags]

                Create a new pane in the workspace.

                Flags:
                  --type <terminal|browser>           Pane type (default: terminal)
                  --direction <left|right|up|down>    Split direction (default: right)
                  --workspace <id|ref>                Target workspace (default: $PROGRAMA_WORKSPACE_ID)
                  --url <url>                         URL for browser panes

                Example:
                  programa new-pane
                  programa new-pane --type browser --direction down --url https://example.com
                """,
                execute: { ctx in
                    let workspaceArg = self.workspaceFromArgsOrEnv(ctx.commandArgs, windowOverride: ctx.windowId)
                    let type = self.optionValue(ctx.commandArgs, name: "--type")
                    let direction = self.optionValue(ctx.commandArgs, name: "--direction") ?? "right"
                    let url = self.optionValue(ctx.commandArgs, name: "--url")
                    var params: [String: Any] = ["direction": direction]
                    let wsId = try self.normalizeWorkspaceHandle(workspaceArg, client: ctx.client)
                    if let wsId { params["workspace_id"] = wsId }
                    if let type { params["type"] = type }
                    if let url { params["url"] = url }
                    let payload = try ctx.client.sendV2(method: "pane.create", params: params)
                    self.printV2Payload(payload, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat, fallbackText: self.v2OKSummary(payload, idFormat: ctx.idFormat, kinds: ["surface", "pane", "workspace"]))
                }
            ),

            CommandDescriptor(
                names: ["new-surface"],
                helpLines: ["new-surface [--type <terminal|browser>] [--pane <id|ref>] [--workspace <id|ref>] [--url <url>]"],
                detailedUsage: """
                Usage: programa new-surface [flags]

                Create a new surface (tab) in a pane.

                Flags:
                  --type <terminal|browser>   Surface type (default: terminal)
                  --pane <id|ref>             Target pane
                  --workspace <id|ref>        Target workspace (default: $PROGRAMA_WORKSPACE_ID)
                  --url <url>                 URL for browser surfaces

                Example:
                  programa new-surface
                  programa new-surface --type browser --pane pane:1 --url https://example.com
                """,
                execute: { ctx in
                    let workspaceArg = self.workspaceFromArgsOrEnv(ctx.commandArgs, windowOverride: ctx.windowId)
                    let type = self.optionValue(ctx.commandArgs, name: "--type")
                    let paneRaw = self.optionValue(ctx.commandArgs, name: "--pane")
                    let url = self.optionValue(ctx.commandArgs, name: "--url")
                    var params: [String: Any] = [:]
                    let wsId = try self.normalizeWorkspaceHandle(workspaceArg, client: ctx.client)
                    if let wsId { params["workspace_id"] = wsId }
                    let paneId = try self.normalizePaneHandle(paneRaw, client: ctx.client, workspaceHandle: wsId)
                    if let paneId { params["pane_id"] = paneId }
                    if let type { params["type"] = type }
                    if let url { params["url"] = url }
                    let payload = try ctx.client.sendV2(method: "surface.create", params: params)
                    self.printV2Payload(payload, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat, fallbackText: self.v2OKSummary(payload, idFormat: ctx.idFormat, kinds: ["surface", "pane", "workspace"]))
                }
            ),

            CommandDescriptor(
                names: ["close-surface"],
                helpLines: ["close-surface [--surface <id|ref>] [--workspace <id|ref>]"],
                detailedUsage: """
                Usage: programa close-surface [flags]

                Close a surface. Defaults to the focused surface if none specified.

                Flags:
                  --surface <id|ref>     Surface to close (default: $PROGRAMA_SURFACE_ID)
                  --panel <id|ref>       Alias for --surface
                  --workspace <id|ref>   Workspace context (default: $PROGRAMA_WORKSPACE_ID)

                Example:
                  programa close-surface
                  programa close-surface --surface surface:3
                """,
                execute: { ctx in
                    let csWsFlag = self.optionValue(ctx.commandArgs, name: "--workspace")
                    let workspaceArg = csWsFlag ?? (ctx.windowId == nil ? ProcessInfo.processInfo.environment["PROGRAMA_WORKSPACE_ID"] : nil)
                    let surfaceRaw = self.optionValue(ctx.commandArgs, name: "--surface") ?? self.optionValue(ctx.commandArgs, name: "--panel") ?? (workspaceArg == nil && ctx.windowId == nil ? ProcessInfo.processInfo.environment["PROGRAMA_SURFACE_ID"] : nil)
                    var params: [String: Any] = [:]
                    let wsId = try self.normalizeWorkspaceHandle(workspaceArg, client: ctx.client)
                    if let wsId { params["workspace_id"] = wsId }
                    let sfId = try self.normalizeSurfaceHandle(surfaceRaw, client: ctx.client, workspaceHandle: wsId)
                    if let sfId { params["surface_id"] = sfId }
                    let payload = try ctx.client.sendV2(method: "surface.close", params: params)
                    if let closedWorkspaceId = (payload["workspace_id"] as? String) ?? wsId,
                       let closedSurfaceId = (payload["surface_id"] as? String) ?? sfId {
                        try? self.tmuxPruneCompatSurfaceState(
                            workspaceId: closedWorkspaceId,
                            surfaceId: closedSurfaceId,
                            client: ctx.client
                        )
                    }
                    self.printV2Payload(payload, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat, fallbackText: self.v2OKSummary(payload, idFormat: ctx.idFormat))
                }
            ),

            CommandDescriptor(
                names: ["move-surface"],
                helpLines: ["move-surface --surface <id|ref> [--pane <id|ref>] [--workspace <id|ref>] [--window <id|ref>] [--before <id|ref>] [--after <id|ref>] [--index <n>] [--focus <true|false>]"],
                detailedUsage: """
                Usage: programa move-surface [--surface <id|ref> | <id|ref>] [flags]

                Move a surface to a different pane, workspace, or window.

                Flags:
                  --surface <id|ref>   Surface to move (required unless passed positionally)
                  --pane <id|ref>      Target pane
                  --workspace <id|ref> Target workspace
                  --window <id|ref>    Target window
                  --before <id|ref>    Place before this surface
                  --before-surface <id|ref>
                                           Alias for --before
                  --after <id|ref>     Place after this surface
                  --after-surface <id|ref>
                                           Alias for --after
                  --index <n>                Place at this index
                  --focus <true|false>       Focus the surface after moving

                Example:
                  programa move-surface --surface surface:1 --workspace workspace:2
                  programa move-surface surface:1 --pane pane:2 --index 0
                """,
                execute: { ctx in
                    try self.runMoveSurface(commandArgs: ctx.commandArgs, client: ctx.client, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat)
                }
            ),

            CommandDescriptor(
                names: ["reorder-surface"],
                helpLines: ["reorder-surface --surface <id|ref> (--index <n> | --before <id|ref> | --after <id|ref>)"],
                detailedUsage: """
                Usage: programa reorder-surface [--surface <id|ref> | <id|ref>] [flags]

                Reorder a surface within its pane.

                Flags:
                  --surface <id|ref>   Surface to reorder (required unless passed positionally)
                  --workspace <id|ref> Workspace context
                  --before <id|ref>    Place before this surface
                  --before-surface <id|ref>
                                           Alias for --before
                  --after <id|ref>     Place after this surface
                  --after-surface <id|ref>
                                           Alias for --after
                  --index <n>                Place at this index

                Example:
                  programa reorder-surface --surface surface:1 --index 0
                  programa reorder-surface --surface surface:3 --after surface:1
                """,
                execute: { ctx in
                    try self.runReorderSurface(commandArgs: ctx.commandArgs, client: ctx.client, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat)
                }
            ),

            CommandDescriptor(
                names: ["tab-action"],
                helpLines: ["tab-action --action <name> [--tab <id|ref>] [--surface <id|ref>] [--workspace <id|ref>] [--title <text>] [--url <url>]"],
                detailedUsage: """
                Usage: programa tab-action --action <name> [flags]

                Perform horizontal tab context-menu actions from CLI/socket.

                Actions:
                  rename | clear-name
                  close-left | close-right | close-others
                  new-terminal-right | new-browser-right
                  reload | duplicate
                  pin | unpin
                  mark-unread

                Flags:
                  --action <name>              Action name (required if not positional)
                  --tab <id|ref>         Target tab (accepts tab:<n> or surface:<n>; default: $PROGRAMA_TAB_ID, then $PROGRAMA_SURFACE_ID, then focused tab)
                  --surface <id|ref>     Alias for --tab (backward compatibility)
                  --workspace <id|ref>   Workspace context (default: current/$PROGRAMA_WORKSPACE_ID)
                  --title <text>               Title for rename (or pass trailing title text)
                  --url <url>                  Optional URL for new-browser-right

                Example:
                  programa tab-action --tab tab:3 --action pin
                  programa tab-action --action close-right
                  programa tab-action --tab tab:2 --action rename --title "build logs"
                """,
                execute: { ctx in
                    try self.runTabAction(commandArgs: ctx.commandArgs, client: ctx.client, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat, windowOverride: ctx.windowId)
                }
            ),

            CommandDescriptor(
                names: ["rename-tab"],
                helpLines: ["rename-tab [--workspace <id|ref>] [--tab <id|ref>] [--surface <id|ref>] <title>"],
                detailedUsage: """
                Usage: programa rename-tab [--workspace <id|ref>] [--tab <id|ref>] [--surface <id|ref>] [--] <title>

                Compatibility alias for tab-action rename.

                Resolution order for target tab:
                1) --tab
                2) --surface
                3) $PROGRAMA_TAB_ID / $PROGRAMA_SURFACE_ID
                4) currently focused tab (optionally within --workspace)

                Flags:
                  --workspace <id|ref>   Workspace context (default: current/$PROGRAMA_WORKSPACE_ID)
                  --tab <id|ref>         Tab target (supports tab:<n> or surface:<n>)
                  --surface <id|ref>     Alias for --tab
                  --title <text>         Explicit title (or use trailing positional title)

                Examples:
                  programa rename-tab "build logs"
                  programa rename-tab --tab tab:3 "staging server"
                  programa rename-tab --workspace workspace:2 --surface surface:5 --title "agent run"
                """,
                execute: { ctx in
                    try self.runRenameTab(commandArgs: ctx.commandArgs, client: ctx.client, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat, windowOverride: ctx.windowId)
                }
            ),

            CommandDescriptor(
                names: ["drag-surface-to-split"],
                helpLines: ["drag-surface-to-split --surface <id|ref> <left|right|up|down>"],
                detailedUsage: """
                Usage: programa drag-surface-to-split --surface <id|ref> <left|right|up|down>

                Drag a surface into a new split in the given direction.

                Flags:
                  --surface <id|ref>   Surface to drag (required)
                  --panel <id|ref>     Alias for --surface

                Example:
                  programa drag-surface-to-split --surface surface:1 right
                  programa drag-surface-to-split --panel surface:2 down
                """,
                execute: { ctx in
                    let (surfaceArg, rem0) = self.parseOption(ctx.commandArgs, name: "--surface")
                    let (panelArg, rem1) = self.parseOption(rem0, name: "--panel")
                    let surface = surfaceArg ?? panelArg
                    guard let surface else {
                        throw CLIError(message: "drag-surface-to-split requires --surface <id|ref>")
                    }
                    guard let direction = rem1.first else {
                        throw CLIError(message: "drag-surface-to-split requires a direction")
                    }
                    // v1 always targeted the currently-selected workspace (no --workspace support);
                    // leave workspace_id unset so v2 falls back to the current selection identically.
                    let surfaceIdForDrag = try self.normalizeSurfaceHandle(surface, client: ctx.client, workspaceHandle: nil)
                    var dragParams: [String: Any] = ["direction": direction]
                    if let surfaceIdForDrag { dragParams["surface_id"] = surfaceIdForDrag }
                    let dragPayload = try ctx.client.sendV2(method: "surface.drag_to_split", params: dragParams)
                    print("OK \((dragPayload["pane_id"] as? String) ?? "")")
                }
            ),

            CommandDescriptor(
                names: ["refresh-surfaces"],
                helpLines: ["refresh-surfaces"],
                detailedUsage: """
                Usage: programa refresh-surfaces

                Refresh surface snapshots for the focused workspace.
                """,
                execute: { ctx in
                    // v1 always targeted the currently-selected workspace; no workspace_id here either.
                    let refreshPayload = try ctx.client.sendV2(method: "surface.refresh", params: [:])
                    print("OK Refreshed \(self.intFromAny(refreshPayload["refreshed"]) ?? 0) surfaces")
                }
            ),

            CommandDescriptor(
                names: ["reload-config"],
                helpLines: ["reload-config"],
                detailedUsage: """
                Usage: programa reload-config

                Run the same configuration reload as the Reload Configuration shortcut.
                This reloads Ghostty config, re-reads ~/.config/programa/settings.json, and refreshes terminals.

                Example:
                  programa reload-config
                """,
                execute: { ctx in
                    if let unexpected = ctx.commandArgs.first {
                        throw CLIError(message: "reload-config does not accept arguments. Unexpected argument '\(unexpected)'")
                    }
                    _ = try ctx.client.sendV2(method: "app.reload_config")
                    print("OK Reloaded config")
                }
            ),

            CommandDescriptor(
                names: ["surface-health"],
                helpLines: ["surface-health [--workspace <id|ref>]"],
                detailedUsage: """
                Usage: programa surface-health [--workspace <id|ref>]

                List health details for surfaces in a workspace.

                Flags:
                  --workspace <id|ref>   Workspace context (default: $PROGRAMA_WORKSPACE_ID)

                Example:
                  programa surface-health
                  programa surface-health --workspace workspace:2
                """,
                execute: { ctx in
                    let workspaceArg = self.workspaceFromArgsOrEnv(ctx.commandArgs, windowOverride: ctx.windowId)
                    var params: [String: Any] = [:]
                    let wsId = try self.normalizeWorkspaceHandle(workspaceArg, client: ctx.client)
                    if let wsId { params["workspace_id"] = wsId }
                    let payload = try ctx.client.sendV2(method: "surface.health", params: params)
                    if ctx.jsonOutput {
                        print(self.jsonString(self.formatIDs(payload, mode: ctx.idFormat)))
                    } else {
                        let surfaces = payload["surfaces"] as? [[String: Any]] ?? []
                        if surfaces.isEmpty {
                            print("No surfaces")
                        } else {
                            for surface in surfaces {
                                let handle = self.textHandle(surface, idFormat: ctx.idFormat)
                                let sType = (surface["type"] as? String) ?? ""
                                let inWindow = surface["in_window"]
                                let inWindowStr: String
                                if let b = inWindow as? Bool {
                                    inWindowStr = " in_window=\(b)"
                                } else {
                                    inWindowStr = ""
                                }
                                print("\(handle)  type=\(sType)\(inWindowStr)")
                            }
                        }
                    }
                }
            ),

            CommandDescriptor(
                names: ["debug-terminals"],
                helpLines: [],
                detailedUsage: """
                Usage: programa debug-terminals

                Print live Ghostty terminal runtime metadata across all windows and workspaces.
                Intended for debugging stray or detached terminal views.
                """,
                execute: { ctx in
                    let unexpected = ctx.commandArgs.filter { $0 != "--" }
                    if let extra = unexpected.first {
                        throw CLIError(message: "debug-terminals: unexpected argument '\(extra)'")
                    }
                    let payload = try ctx.client.sendV2(method: "debug.terminals")
                    if ctx.jsonOutput {
                        print(self.jsonString(self.formatIDs(payload, mode: ctx.idFormat)))
                    } else {
                        print(self.formatDebugTerminalsPayload(payload, idFormat: ctx.idFormat))
                    }
                }
            ),

            CommandDescriptor(
                names: ["trigger-flash"],
                helpLines: ["trigger-flash [--workspace <id|ref>] [--surface <id|ref>]"],
                detailedUsage: """
                Usage: programa trigger-flash [--workspace <id|ref>] [--surface <id|ref>] [--panel <id|ref>]

                Trigger the unread flash indicator for a surface.

                Flags:
                  --workspace <id|ref>   Workspace context (default: $PROGRAMA_WORKSPACE_ID)
                  --surface <id|ref>     Target surface (default: $PROGRAMA_SURFACE_ID)
                  --panel <id|ref>       Alias for --surface

                Example:
                  programa trigger-flash
                  programa trigger-flash --workspace workspace:2 --surface surface:3
                """,
                execute: { ctx in
                    let tfWsFlag = self.optionValue(ctx.commandArgs, name: "--workspace")
                    let explicitWorkspaceArg = tfWsFlag
                    let preferTTYFallback = ctx.windowId == nil && ProcessInfo.processInfo.environment["TMUX"] != nil
                    let callerWorkspaceArg = preferTTYFallback
                        ? nil
                        : (ctx.windowId == nil ? ProcessInfo.processInfo.environment["PROGRAMA_WORKSPACE_ID"] : nil)
                    let workspaceArg = explicitWorkspaceArg ?? callerWorkspaceArg
                    let explicitSurfaceArg = self.optionValue(ctx.commandArgs, name: "--surface") ?? self.optionValue(ctx.commandArgs, name: "--panel")
                    let callerSurfaceArg = explicitSurfaceArg == nil && preferTTYFallback == false && ctx.windowId == nil
                        ? ProcessInfo.processInfo.environment["PROGRAMA_SURFACE_ID"]
                        : nil
                    let surfaceArg = explicitSurfaceArg ?? callerSurfaceArg
                    var params: [String: Any] = [:]
                    let wsId = try {
                        if explicitWorkspaceArg != nil {
                            return try self.normalizeWorkspaceHandle(workspaceArg, client: ctx.client)
                        }
                        return try self.resolveWorkspaceIdAllowingFallback(workspaceArg, client: ctx.client)
                    }()
                    if let wsId { params["workspace_id"] = wsId }
                    let sfId = try {
                        if explicitSurfaceArg != nil {
                            return try self.normalizeSurfaceHandle(surfaceArg, client: ctx.client, workspaceHandle: wsId)
                        }
                        guard let wsId else { return nil }
                        return try self.resolveSurfaceIdAllowingFallback(
                            surfaceArg,
                            workspaceId: wsId,
                            client: ctx.client
                        )
                    }()
                    if let sfId { params["surface_id"] = sfId }
                    let payload = try ctx.client.sendV2(method: "surface.trigger_flash", params: params)
                    self.printV2Payload(payload, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat, fallbackText: self.v2OKSummary(payload, idFormat: ctx.idFormat))
                }
            ),

            CommandDescriptor(
                names: ["list-panels"],
                helpLines: ["list-panels [--workspace <id|ref>]"],
                detailedUsage: """
                Usage: programa list-panels [--workspace <id|ref>]

                List surfaces (panels) in a workspace.

                Flags:
                  --workspace <id|ref>   Workspace context (default: $PROGRAMA_WORKSPACE_ID)

                Example:
                  programa list-panels
                  programa list-panels --workspace workspace:2
                """,
                execute: { ctx in
                    let workspaceArg = self.workspaceFromArgsOrEnv(ctx.commandArgs, windowOverride: ctx.windowId)
                    var params: [String: Any] = [:]
                    let wsId = try self.normalizeWorkspaceHandle(workspaceArg, client: ctx.client)
                    if let wsId { params["workspace_id"] = wsId }
                    let payload = try ctx.client.sendV2(method: "surface.list", params: params)
                    if ctx.jsonOutput {
                        print(self.jsonString(self.formatIDs(payload, mode: ctx.idFormat)))
                    } else {
                        let surfaces = payload["surfaces"] as? [[String: Any]] ?? []
                        if surfaces.isEmpty {
                            print("No surfaces")
                        } else {
                            for surface in surfaces {
                                let focused = (surface["focused"] as? Bool) == true
                                let handle = self.textHandle(surface, idFormat: ctx.idFormat)
                                let sType = (surface["type"] as? String) ?? ""
                                let title = (surface["title"] as? String) ?? ""
                                let prefix = focused ? "* " : "  "
                                let focusTag = focused ? "  [focused]" : ""
                                let titlePart = title.isEmpty ? "" : "  \"\(title)\""
                                print("\(prefix)\(handle)  \(sType)\(focusTag)\(titlePart)")
                            }
                        }
                    }
                }
            ),

            CommandDescriptor(
                names: ["focus-panel"],
                helpLines: ["focus-panel --panel <id|ref> [--workspace <id|ref>]"],
                argumentContract: .focusPanel,
                detailedUsage: """
                Usage: programa focus-panel --panel <id|ref> [--workspace <id|ref>]

                Focus a specific panel (surface).

                Flags:
                  --panel <id|ref>       Panel/surface to focus (required)
                  --workspace <id|ref>   Workspace context (default: $PROGRAMA_WORKSPACE_ID)

                Example:
                  programa focus-panel --panel surface:2
                  programa focus-panel --panel surface:5 --workspace workspace:2
                """,
                execute: { ctx in
                    let workspaceArg = self.workspaceFromArgsOrEnv(ctx.commandArgs, windowOverride: ctx.windowId)
                    guard let panelRaw = self.optionValue(ctx.commandArgs, name: "--panel") else {
                        throw CLIError(message: "focus-panel requires --panel")
                    }
                    var params: [String: Any] = [:]
                    let wsId = try self.normalizeWorkspaceHandle(workspaceArg, client: ctx.client)
                    if let wsId { params["workspace_id"] = wsId }
                    let sfId = try self.normalizeSurfaceHandle(panelRaw, client: ctx.client, workspaceHandle: wsId)
                    if let sfId { params["surface_id"] = sfId }
                    let payload = try ctx.client.sendV2(method: "surface.focus", params: params)
                    self.printV2Payload(payload, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat, fallbackText: self.v2OKSummary(payload, idFormat: ctx.idFormat))
                }
            ),

            CommandDescriptor(
                names: ["close-workspace"],
                helpLines: ["close-workspace --workspace <id|ref>"],
                detailedUsage: """
                Usage: programa close-workspace --workspace <id|ref>

                Close the specified workspace.

                Flags:
                  --workspace <id|ref>   Workspace to close (required)

                Example:
                  programa close-workspace --workspace workspace:2
                """,
                execute: { ctx in
                    guard let workspaceRaw = self.optionValue(ctx.commandArgs, name: "--workspace") else {
                        throw CLIError(
                            message: "close-workspace: --workspace <id|ref> is required (UUID or short ref like workspace:2). Refusing to target the current workspace implicitly."
                        )
                    }
                    var params: [String: Any] = [:]
                    let wsId = try self.normalizeWorkspaceHandle(workspaceRaw, client: ctx.client)
                    if let wsId { params["workspace_id"] = wsId }
                    let payload = try ctx.client.sendV2(method: "workspace.close", params: params)
                    if let closedWorkspaceId = (payload["workspace_id"] as? String) ?? wsId {
                        try? self.tmuxPruneCompatWorkspaceState(workspaceId: closedWorkspaceId)
                    }
                    self.printV2Payload(payload, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat, fallbackText: self.v2OKSummary(payload, idFormat: ctx.idFormat, kinds: ["workspace"]))
                }
            ),

            CommandDescriptor(
                names: ["select-workspace"],
                helpLines: ["select-workspace --workspace <id|ref>"],
                detailedUsage: """
                Usage: programa select-workspace --workspace <id|ref>

                Select (switch to) the specified workspace.

                Flags:
                  --workspace <id|ref>   Workspace to select (required)

                Example:
                  programa select-workspace --workspace workspace:2
                  programa select-workspace --workspace 0
                """,
                execute: { ctx in
                    guard let workspaceRaw = self.optionValue(ctx.commandArgs, name: "--workspace") else {
                        throw CLIError(message: "select-workspace requires --workspace")
                    }
                    var params: [String: Any] = [:]
                    let wsId = try self.normalizeWorkspaceHandle(workspaceRaw, client: ctx.client)
                    if let wsId { params["workspace_id"] = wsId }
                    let payload = try ctx.client.sendV2(method: "workspace.select", params: params)
                    self.printV2Payload(payload, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat, fallbackText: self.v2OKSummary(payload, idFormat: ctx.idFormat, kinds: ["workspace"]))
                }
            ),

            CommandDescriptor(
                names: ["rename-workspace", "rename-window"],
                helpLines: [
                    "rename-workspace [--workspace <id|ref>] <title>",
                    "rename-window [--workspace <id|ref>] <title>",
                ],
                detailedUsage: """
                Usage: programa rename-workspace [--workspace <id|ref>] [--] <title>

                Rename a workspace. Defaults to the current workspace.
                tmux-compatible alias: rename-window

                Flags:
                  --workspace <id|ref>   Workspace to rename (default: current/$PROGRAMA_WORKSPACE_ID)

                Example:
                  programa rename-workspace "backend logs"
                  programa rename-window --workspace workspace:2 "agent run"
                """,
                execute: { ctx in
                    let (wsArg, rem0) = self.parseOption(ctx.commandArgs, name: "--workspace")
                    let workspaceArg = wsArg ?? (ctx.windowId == nil ? ProcessInfo.processInfo.environment["PROGRAMA_WORKSPACE_ID"] : nil)
                    let titleArgs = rem0.dropFirst(rem0.first == "--" ? 1 : 0)
                    let title = titleArgs.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !title.isEmpty else {
                        throw CLIError(message: "\(ctx.command) requires a title")
                    }
                    let wsId = try self.resolveWorkspaceId(workspaceArg, client: ctx.client)
                    let params: [String: Any] = ["title": title, "workspace_id": wsId]
                    let payload = try ctx.client.sendV2(method: "workspace.rename", params: params)
                    self.printV2Payload(payload, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat, fallbackText: self.v2OKSummary(payload, idFormat: ctx.idFormat, kinds: ["workspace"]))
                }
            ),

            CommandDescriptor(
                names: ["current-workspace"],
                helpLines: ["current-workspace"],
                detailedUsage: """
                Usage: programa current-workspace

                Print the currently selected workspace ID.
                """,
                execute: { ctx in
                    let response = try ctx.client.sendV2(method: "workspace.current")
                    if ctx.jsonOutput {
                        print(self.jsonString(self.formatIDs(response, mode: ctx.idFormat)))
                    } else {
                        let handle = self.formatHandle(response, kind: "workspace", idFormat: ctx.idFormat)
                            ?? (response["workspace_id"] as? String)
                            ?? ""
                        print(handle)
                    }
                }
            ),

            CommandDescriptor(
                names: ["read-screen"],
                helpLines: ["read-screen [--workspace <id|ref>] [--surface <id|ref>] [--scrollback] [--lines <n>]"],
                argumentContract: .readScreen,
                detailedUsage: """
                Usage: programa read-screen [flags]

                Read terminal text from a surface as plain text.

                Flags:
                  --workspace <id|ref>   Target workspace (default: $PROGRAMA_WORKSPACE_ID)
                  --surface <id|ref>     Target surface (default: $PROGRAMA_SURFACE_ID)
                  --scrollback           Include scrollback (not just visible viewport)
                  --lines <n>            Limit to the last n lines (implies --scrollback)

                Example:
                  programa read-screen
                  programa read-screen --surface surface:2 --scrollback --lines 200
                """,
                execute: { ctx in
                    let (wsArg, rem0) = self.parseOption(ctx.commandArgs, name: "--workspace")
                    let (sfArg, rem1) = self.parseOption(rem0, name: "--surface")
                    let (linesArg, rem2) = self.parseOption(rem1, name: "--lines")
                    let trailing = rem2.filter { $0 != "--scrollback" }
                    if !trailing.isEmpty {
                        throw CLIError(message: "read-screen: unexpected arguments: \(trailing.joined(separator: " "))")
                    }

                    let workspaceArg = wsArg ?? (ctx.windowId == nil ? ProcessInfo.processInfo.environment["PROGRAMA_WORKSPACE_ID"] : nil)
                    let surfaceArg = sfArg ?? (workspaceArg == nil && ctx.windowId == nil ? ProcessInfo.processInfo.environment["PROGRAMA_SURFACE_ID"] : nil)

                    var params: [String: Any] = [:]
                    let wsId = try self.normalizeWorkspaceHandle(workspaceArg, client: ctx.client)
                    if let wsId { params["workspace_id"] = wsId }
                    let sfId = try self.normalizeSurfaceHandle(surfaceArg, client: ctx.client, workspaceHandle: wsId)
                    if let sfId { params["surface_id"] = sfId }

                    let includeScrollback = rem2.contains("--scrollback")
                    if includeScrollback {
                        params["scrollback"] = true
                    }
                    if let linesArg {
                        guard let lineCount = Int(linesArg), lineCount > 0 else {
                            throw CLIError(message: "--lines must be greater than 0")
                        }
                        params["lines"] = lineCount
                        params["scrollback"] = true
                    }

                    let payload = try ctx.client.sendV2(method: "surface.read_text", params: params)
                    if ctx.jsonOutput {
                        print(self.jsonString(payload))
                    } else {
                        print((payload["text"] as? String) ?? "")
                    }
                }
            ),

            CommandDescriptor(
                names: ["wait-surface"],
                helpLines: ["wait-surface [--workspace <id|ref>] [--surface <id|ref>] (--pattern <regex> | --exit) [--timeout <seconds>] [--lines <n>]"],
                argumentContract: .waitSurface,
                detailedUsage: """
                Usage: programa wait-surface [flags]

                Block until a surface hits a condition, in one server-owned request -- no
                polling loop needed. Answers as soon as the condition is met (or is already
                true when the call arrives) or the timeout elapses.

                Flags:
                  --workspace <id|ref>   Target workspace (default: $PROGRAMA_WORKSPACE_ID)
                  --surface <id|ref>     Target surface (default: $PROGRAMA_SURFACE_ID)
                  --pattern <regex>      Wait until output (screen + scrollback) matches this regex
                  --exit                 Wait until the surface's child process exits
                  --timeout <seconds>    Give up after this long (default: 30)
                  --lines <n>            Cap how much scrollback --pattern rereads per check (default: 2000)

                Exactly one of --pattern / --exit is required. A marker already present when the
                call arrives (or a process that has already exited) resolves immediately --
                `waited: false` in JSON output distinguishes that from an actual wait.

                Example:
                  programa wait-surface --pattern 'BUILD (SUCCEEDED|FAILED)' --timeout 120
                  programa wait-surface --surface surface:2 --exit --timeout 10
                """,
                execute: { ctx in
                    let (wsArg, rem0) = self.parseOption(ctx.commandArgs, name: "--workspace")
                    let (sfArg, rem1) = self.parseOption(rem0, name: "--surface")
                    let (patternArg, rem2) = self.parseOption(rem1, name: "--pattern")
                    let (timeoutArg, rem3) = self.parseOption(rem2, name: "--timeout")
                    let (linesArg, rem4) = self.parseOption(rem3, name: "--lines")
                    let exitFlag = rem4.contains("--exit")
                    let trailing = rem4.filter { $0 != "--exit" }
                    if !trailing.isEmpty {
                        throw CLIError(message: "wait-surface: unexpected arguments: \(trailing.joined(separator: " "))")
                    }
                    guard (patternArg != nil) != exitFlag else {
                        throw CLIError(message: "wait-surface requires exactly one of --pattern <regex> or --exit")
                    }

                    let workspaceArg = wsArg ?? (ctx.windowId == nil ? ProcessInfo.processInfo.environment["PROGRAMA_WORKSPACE_ID"] : nil)
                    let surfaceArg = sfArg ?? (workspaceArg == nil && ctx.windowId == nil ? ProcessInfo.processInfo.environment["PROGRAMA_SURFACE_ID"] : nil)

                    var params: [String: Any] = [:]
                    let wsId = try self.normalizeWorkspaceHandle(workspaceArg, client: ctx.client)
                    if let wsId { params["workspace_id"] = wsId }
                    let sfId = try self.normalizeSurfaceHandle(surfaceArg, client: ctx.client, workspaceHandle: wsId)
                    if let sfId { params["surface_id"] = sfId }

                    if let patternArg {
                        params["pattern"] = patternArg
                    } else {
                        params["exit"] = true
                    }

                    var timeoutSeconds = 30.0
                    if let timeoutArg {
                        guard let parsed = Double(timeoutArg), parsed.isFinite, parsed > 0 else {
                            throw CLIError(message: "wait-surface: --timeout must be a positive number of seconds")
                        }
                        timeoutSeconds = parsed
                        params["timeout_ms"] = Int((parsed * 1000).rounded())
                    }
                    if let linesArg {
                        guard let lineCount = Int(linesArg), lineCount > 0 else {
                            throw CLIError(message: "wait-surface: --lines must be greater than 0")
                        }
                        params["lines"] = lineCount
                    }

                    // The server may legitimately hold this connection open for the full
                    // --timeout; give the client-side socket read at least that long (plus a
                    // buffer for the response round trip) rather than the default 15s.
                    let payload = try ctx.client.sendV2(
                        method: "surface.wait",
                        params: params,
                        minimumReceiveTimeout: timeoutSeconds + 5.0
                    )
                    if ctx.jsonOutput {
                        print(self.jsonString(payload))
                    } else if let match = payload["match"] as? String {
                        print(match)
                    } else if exitFlag {
                        print("exited")
                    } else {
                        print("ok")
                    }
                }
            ),

            CommandDescriptor(
                names: ["send"],
                helpLines: ["send [--workspace <id|ref>] [--surface <id|ref>] <text>"],
                detailedUsage: """
                Usage: programa send [flags] [--] <text>

                Send text to a terminal surface. Escape sequences: \\n and \\r send Enter, \\t sends Tab.

                Flags:
                  --workspace <id|ref>   Target workspace (default: $PROGRAMA_WORKSPACE_ID)
                  --surface <id|ref>     Target surface (default: $PROGRAMA_SURFACE_ID)

                Example:
                  programa send "echo hello"
                  programa send --surface surface:2 "ls -la\\n"
                """,
                execute: { ctx in
                    let (wsArg, rem0) = self.parseOption(ctx.commandArgs, name: "--workspace")
                    let (sfArg, rem1) = self.parseOption(rem0, name: "--surface")
                    let workspaceArg = wsArg ?? (ctx.windowId == nil ? ProcessInfo.processInfo.environment["PROGRAMA_WORKSPACE_ID"] : nil)
                    let surfaceArg = sfArg ?? (workspaceArg == nil && ctx.windowId == nil ? ProcessInfo.processInfo.environment["PROGRAMA_SURFACE_ID"] : nil)
                    let rawText = rem1.dropFirst(rem1.first == "--" ? 1 : 0).joined(separator: " ")
                    guard !rawText.isEmpty else { throw CLIError(message: "send requires text") }
                    let text = self.unescapeSendText(rawText)
                    var params: [String: Any] = ["text": text]
                    let wsId = try self.normalizeWorkspaceHandle(workspaceArg, client: ctx.client)
                    if let wsId { params["workspace_id"] = wsId }
                    let sfId = try self.normalizeSurfaceHandle(surfaceArg, client: ctx.client, workspaceHandle: wsId)
                    if let sfId { params["surface_id"] = sfId }
                    let payload = try ctx.client.sendV2(method: "surface.send_text", params: params)
                    self.printV2Payload(payload, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat, fallbackText: self.v2OKSummary(payload, idFormat: ctx.idFormat))
                }
            ),

            CommandDescriptor(
                names: ["send-key"],
                helpLines: ["send-key [--workspace <id|ref>] [--surface <id|ref>] <key>"],
                detailedUsage: """
                Usage: programa send-key [flags] [--] <key>

                Send a key event to a terminal surface.

                Flags:
                  --workspace <id|ref>   Target workspace (default: $PROGRAMA_WORKSPACE_ID)
                  --surface <id|ref>     Target surface (default: $PROGRAMA_SURFACE_ID)

                Example:
                  programa send-key enter
                  programa send-key --surface surface:2 ctrl+c
                """,
                execute: { ctx in
                    let (wsArg, rem0) = self.parseOption(ctx.commandArgs, name: "--workspace")
                    let (sfArg, rem1) = self.parseOption(rem0, name: "--surface")
                    let workspaceArg = wsArg ?? (ctx.windowId == nil ? ProcessInfo.processInfo.environment["PROGRAMA_WORKSPACE_ID"] : nil)
                    let surfaceArg = sfArg ?? (workspaceArg == nil && ctx.windowId == nil ? ProcessInfo.processInfo.environment["PROGRAMA_SURFACE_ID"] : nil)
                    let keyArgs = rem1.first == "--" ? Array(rem1.dropFirst()) : rem1
                    guard let key = keyArgs.first else { throw CLIError(message: "send-key requires a key") }
                    var params: [String: Any] = ["key": key]
                    let wsId = try self.normalizeWorkspaceHandle(workspaceArg, client: ctx.client)
                    if let wsId { params["workspace_id"] = wsId }
                    let sfId = try self.normalizeSurfaceHandle(surfaceArg, client: ctx.client, workspaceHandle: wsId)
                    if let sfId { params["surface_id"] = sfId }
                    let payload = try ctx.client.sendV2(method: "surface.send_key", params: params)
                    self.printV2Payload(payload, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat, fallbackText: self.v2OKSummary(payload, idFormat: ctx.idFormat))
                }
            ),

            CommandDescriptor(
                names: ["send-panel"],
                helpLines: ["send-panel --panel <id|ref> [--workspace <id|ref>] <text>"],
                detailedUsage: """
                Usage: programa send-panel --panel <id|ref> [flags] [--] <text>

                Send text to a specific panel (surface). Escape sequences: \\n and \\r send Enter, \\t sends Tab.

                Flags:
                  --panel <id|ref>       Target panel (required)
                  --workspace <id|ref>   Target workspace (default: $PROGRAMA_WORKSPACE_ID)

                Example:
                  programa send-panel --panel surface:2 "echo hello\\n"
                """,
                execute: { ctx in
                    let (wsArg, rem0) = self.parseOption(ctx.commandArgs, name: "--workspace")
                    let (panelArg, rem1) = self.parseOption(rem0, name: "--panel")
                    let workspaceArg = wsArg ?? (ctx.windowId == nil ? ProcessInfo.processInfo.environment["PROGRAMA_WORKSPACE_ID"] : nil)
                    guard let panelArg else {
                        throw CLIError(message: "send-panel requires --panel")
                    }
                    let rawText = rem1.dropFirst(rem1.first == "--" ? 1 : 0).joined(separator: " ")
                    guard !rawText.isEmpty else { throw CLIError(message: "send-panel requires text") }
                    let text = self.unescapeSendText(rawText)
                    var params: [String: Any] = ["text": text]
                    let wsId = try self.normalizeWorkspaceHandle(workspaceArg, client: ctx.client)
                    if let wsId { params["workspace_id"] = wsId }
                    let sfId = try self.normalizeSurfaceHandle(panelArg, client: ctx.client, workspaceHandle: wsId)
                    if let sfId { params["surface_id"] = sfId }
                    let payload = try ctx.client.sendV2(method: "surface.send_text", params: params)
                    self.printV2Payload(payload, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat, fallbackText: self.v2OKSummary(payload, idFormat: ctx.idFormat))
                }
            ),

            CommandDescriptor(
                names: ["send-key-panel"],
                helpLines: ["send-key-panel --panel <id|ref> [--workspace <id|ref>] <key>"],
                detailedUsage: """
                Usage: programa send-key-panel --panel <id|ref> [flags] [--] <key>

                Send a key event to a specific panel (surface).

                Flags:
                  --panel <id|ref>       Target panel (required)
                  --workspace <id|ref>   Target workspace (default: $PROGRAMA_WORKSPACE_ID)

                Example:
                  programa send-key-panel --panel surface:2 enter
                  programa send-key-panel --panel surface:2 ctrl+c
                """,
                execute: { ctx in
                    let (wsArg, rem0) = self.parseOption(ctx.commandArgs, name: "--workspace")
                    let (panelArg, rem1) = self.parseOption(rem0, name: "--panel")
                    let workspaceArg = wsArg ?? (ctx.windowId == nil ? ProcessInfo.processInfo.environment["PROGRAMA_WORKSPACE_ID"] : nil)
                    guard let panelArg else {
                        throw CLIError(message: "send-key-panel requires --panel")
                    }
                    let skpArgs = rem1.first == "--" ? Array(rem1.dropFirst()) : rem1
                    let key = skpArgs.first ?? ""
                    guard !key.isEmpty else { throw CLIError(message: "send-key-panel requires a key") }
                    var params: [String: Any] = ["key": key]
                    let wsId = try self.normalizeWorkspaceHandle(workspaceArg, client: ctx.client)
                    if let wsId { params["workspace_id"] = wsId }
                    let sfId = try self.normalizeSurfaceHandle(panelArg, client: ctx.client, workspaceHandle: wsId)
                    if let sfId { params["surface_id"] = sfId }
                    let payload = try ctx.client.sendV2(method: "surface.send_key", params: params)
                    self.printV2Payload(payload, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat, fallbackText: self.v2OKSummary(payload, idFormat: ctx.idFormat))
                }
            ),

            CommandDescriptor(
                names: ["notify"],
                helpLines: ["notify --title <text> [--subtitle <text>] [--body <text>] [--workspace <id|ref>] [--surface <id|ref>]"],
                detailedUsage: """
                Usage: programa notify [flags]

                Send a notification to a workspace/surface.

                Flags:
                  --title <text>         Notification title (default: "Notification")
                  --subtitle <text>      Notification subtitle
                  --body <text>          Notification body
                  --workspace <id|ref>   Target workspace (default: $PROGRAMA_WORKSPACE_ID)
                  --surface <id|ref>     Target surface (default: $PROGRAMA_SURFACE_ID)

                Example:
                  programa notify --title "Build done" --body "All tests passed"
                  programa notify --title "Error" --subtitle "test.swift" --body "Line 42: syntax error"
                """,
                execute: { ctx in
                    let title = self.optionValue(ctx.commandArgs, name: "--title") ?? "Notification"
                    let subtitle = self.optionValue(ctx.commandArgs, name: "--subtitle") ?? ""
                    let body = self.optionValue(ctx.commandArgs, name: "--body") ?? ""

                    let explicitWorkspaceArg = self.optionValue(ctx.commandArgs, name: "--workspace")
                    let preferTTYFallback = ctx.windowId == nil && ProcessInfo.processInfo.environment["TMUX"] != nil
                    let callerWorkspaceArg = preferTTYFallback
                        ? nil
                        : (ctx.windowId == nil ? ProcessInfo.processInfo.environment["PROGRAMA_WORKSPACE_ID"] : nil)
                    let workspaceArg = explicitWorkspaceArg ?? callerWorkspaceArg
                    let explicitSurfaceArg = self.optionValue(ctx.commandArgs, name: "--surface")
                    let callerSurfaceArg = explicitSurfaceArg == nil && workspaceArg == nil && preferTTYFallback == false && ctx.windowId == nil
                        ? ProcessInfo.processInfo.environment["PROGRAMA_SURFACE_ID"]
                        : nil
                    let surfaceArg = explicitSurfaceArg ?? callerSurfaceArg

                    let targetWorkspace = try {
                        if explicitWorkspaceArg != nil {
                            return try self.resolveWorkspaceId(workspaceArg, client: ctx.client)
                        }
                        return try self.resolveWorkspaceIdAllowingFallback(workspaceArg, client: ctx.client)
                    }()
                    let targetSurface = try {
                        if explicitSurfaceArg != nil {
                            return try self.resolveSurfaceId(surfaceArg, workspaceId: targetWorkspace, client: ctx.client)
                        }
                        return try self.resolveSurfaceIdAllowingFallback(
                            surfaceArg,
                            workspaceId: targetWorkspace,
                            client: ctx.client
                        )
                    }()

                    _ = try ctx.client.sendV2(method: "notification.create_for_target", params: [
                        "workspace_id": targetWorkspace,
                        "surface_id": targetSurface,
                        "title": title,
                        "subtitle": subtitle,
                        "body": body,
                    ])
                    print("OK")
                }
            ),

            CommandDescriptor(
                names: ["list-notifications"],
                helpLines: ["list-notifications"],
                detailedUsage: """
                Usage: programa list-notifications

                List queued notifications.
                """,
                execute: { ctx in
                    let listed = try ctx.client.sendV2(method: "notification.list")
                    let notifications = listed["notifications"] as? [[String: Any]] ?? []
                    if ctx.jsonOutput {
                        let payload = notifications.enumerated().map { _, item -> [String: Any] in
                            var dict: [String: Any] = [
                                "id": (item["id"] as? String) ?? "",
                                "workspace_id": (item["workspace_id"] as? String) ?? "",
                                "is_read": (item["is_read"] as? Bool) ?? false,
                                "title": (item["title"] as? String) ?? "",
                                "subtitle": (item["subtitle"] as? String) ?? "",
                                "body": (item["body"] as? String) ?? "",
                            ]
                            dict["surface_id"] = item["surface_id"] as? String ?? NSNull()
                            return dict
                        }
                        print(self.jsonString(payload))
                    } else if notifications.isEmpty {
                        print("No notifications")
                    } else {
                        let lines = notifications.enumerated().map { index, item -> String in
                            let surfaceText = (item["surface_id"] as? String) ?? "none"
                            let readText = ((item["is_read"] as? Bool) ?? false) ? "read" : "unread"
                            let id = (item["id"] as? String) ?? ""
                            let workspaceId = (item["workspace_id"] as? String) ?? ""
                            let title = (item["title"] as? String) ?? ""
                            let subtitle = (item["subtitle"] as? String) ?? ""
                            let body = (item["body"] as? String) ?? ""
                            return "\(index):\(id)|\(workspaceId)|\(surfaceText)|\(readText)|\(title)|\(subtitle)|\(body)"
                        }
                        print(lines.joined(separator: "\n"))
                    }
                }
            ),

            CommandDescriptor(
                names: ["clear-notifications"],
                helpLines: ["clear-notifications"],
                detailedUsage: """
                Usage: programa clear-notifications

                Clear all queued notifications.
                """,
                execute: { ctx in
                    if let wsFlag = self.optionValue(ctx.commandArgs, name: "--workspace") {
                        let wsId = try self.resolveWorkspaceId(wsFlag, client: ctx.client)
                        _ = try ctx.client.sendV2(method: "notification.clear", params: ["workspace_id": wsId])
                    } else if ctx.windowId == nil,
                              let envWs = ProcessInfo.processInfo.environment["PROGRAMA_WORKSPACE_ID"],
                              let wsId = try? self.resolveWorkspaceId(envWs, client: ctx.client) {
                        _ = try ctx.client.sendV2(method: "notification.clear", params: ["workspace_id": wsId])
                    } else {
                        _ = try ctx.client.sendV2(method: "notification.clear")
                    }
                    print("OK")
                }
            ),

            CommandDescriptor(
                names: ["set-status"],
                helpLines: [],
                detailedUsage: """
                Usage: programa set-status <key> <value> [flags]

                Set a sidebar status entry for a workspace. Status entries appear as
                pills in the sidebar tab row. Use a unique key so different tools
                (e.g. "claude_code", "build") can manage their own entries.

                Flags:
                  --icon <name>          Icon name (e.g. "sparkle", "hammer")
                  --color <#hex>         Pill color (e.g. "#ff9500")
                  --workspace <id|ref>   Target workspace (default: $PROGRAMA_WORKSPACE_ID)

                Example:
                  programa set-status build "compiling" --icon hammer --color "#ff9500"
                  programa set-status deploy "v1.2.3" --workspace workspace:2
                """,
                execute: { ctx in
                    let parsed = self.parseFlagArgs(ctx.commandArgs, stopAtDashDash: false)
                    guard parsed.positional.count >= 2 else {
                        throw CLIError(message: "ERROR: Missing status key or value — usage: set_status <key> <value> [--icon=X] [--color=#hex] [--url=X] [--priority=N] [--format=plain|markdown] [--tab=X]")
                    }
                    var params: [String: Any] = [
                        "key": parsed.positional[0],
                        "value": parsed.positional[1...].joined(separator: " "),
                    ]
                    if let icon = self.normalizedFlagValue(parsed.options["icon"]) { params["icon"] = icon }
                    if let color = self.normalizedFlagValue(parsed.options["color"]) { params["color"] = color }
                    if let url = self.normalizedFlagValue(parsed.options["url"] ?? parsed.options["link"]) { params["url"] = url }
                    if let priorityRaw = self.normalizedFlagValue(parsed.options["priority"]) {
                        guard let priority = Int(priorityRaw) else {
                            throw CLIError(message: "ERROR: Invalid metadata priority '\(priorityRaw)' — must be an integer")
                        }
                        params["priority"] = max(-9999, min(9999, priority))
                    }
                    if let formatRaw = self.normalizedFlagValue(parsed.options["format"]) {
                        guard ["plain", "markdown", "md"].contains(formatRaw.lowercased()) else {
                            throw CLIError(message: "ERROR: Invalid metadata format '\(formatRaw)' — use: plain, markdown")
                        }
                        params["format"] = formatRaw.lowercased() == "md" ? "markdown" : formatRaw.lowercased()
                    }
                    if let pidRaw = self.normalizedFlagValue(parsed.options["pid"]), let pid = Int(pidRaw), pid > 0 {
                        params["pid"] = pid
                    }
                    params["workspace_id"] = try self.resolveSidebarWorkspaceId(options: parsed.options, windowOverride: ctx.windowId, client: ctx.client)
                    _ = try ctx.client.sendV2(method: "workspace.set_status", params: params)
                    print("OK")
                }
            ),

            CommandDescriptor(
                names: ["clear-status"],
                helpLines: [],
                detailedUsage: """
                Usage: programa clear-status <key> [flags]

                Remove a sidebar status entry by key.

                Flags:
                  --workspace <id|ref>   Target workspace (default: $PROGRAMA_WORKSPACE_ID)

                Example:
                  programa clear-status build
                """,
                execute: { ctx in
                    let parsed = self.parseFlagArgs(ctx.commandArgs)
                    guard let key = parsed.positional.first, parsed.positional.count == 1 else {
                        throw CLIError(message: "ERROR: Missing metadata key — usage: clear_status <key> [--tab=X]")
                    }
                    let workspaceId = try self.resolveSidebarWorkspaceId(options: parsed.options, windowOverride: ctx.windowId, client: ctx.client)
                    _ = try ctx.client.sendV2(method: "workspace.clear_status", params: ["workspace_id": workspaceId, "key": key])
                    print("OK")
                }
            ),

            CommandDescriptor(
                names: ["list-status"],
                helpLines: [],
                detailedUsage: """
                Usage: programa list-status [flags]

                List all sidebar status entries for a workspace.

                Flags:
                  --workspace <id|ref>   Target workspace (default: $PROGRAMA_WORKSPACE_ID)

                Example:
                  programa list-status
                  programa list-status --workspace workspace:2
                """,
                execute: { ctx in
                    let parsed = self.parseFlagArgs(ctx.commandArgs)
                    let workspaceId = try self.resolveSidebarWorkspaceId(options: parsed.options, windowOverride: ctx.windowId, client: ctx.client)
                    let payload = try ctx.client.sendV2(method: "workspace.list_status", params: ["workspace_id": workspaceId])
                    let entries = payload["entries"] as? [[String: Any]] ?? []
                    if entries.isEmpty {
                        print("No status entries")
                    } else {
                        print(entries.map(self.sidebarMetadataLineText).joined(separator: "\n"))
                    }
                }
            ),

            CommandDescriptor(
                names: ["set-progress"],
                helpLines: [],
                argumentContract: .setProgress,
                detailedUsage: """
                Usage: programa set-progress <0.0-1.0> [flags]

                Set a progress bar in the sidebar for a workspace.

                Flags:
                  --label <text>         Label shown next to the progress bar
                  --workspace <id|ref>   Target workspace (default: $PROGRAMA_WORKSPACE_ID)

                Example:
                  programa set-progress 0.5 --label "Building..."
                  programa set-progress 1.0 --label "Done"
                """,
                execute: { ctx in
                    let parsed = self.parseFlagArgs(ctx.commandArgs)
                    guard let first = parsed.positional.first else {
                        throw CLIError(message: "ERROR: Missing progress value — usage: set_progress <0.0-1.0> [--label=X] [--tab=X]")
                    }
                    guard let value = Double(first), value.isFinite else {
                        throw CLIError(message: "ERROR: Invalid progress value '\(first)' — must be 0.0 to 1.0")
                    }
                    var params: [String: Any] = ["value": min(1.0, max(0.0, value))]
                    if let label = self.normalizedFlagValue(parsed.options["label"]) { params["label"] = label }
                    params["workspace_id"] = try self.resolveSidebarWorkspaceId(options: parsed.options, windowOverride: ctx.windowId, client: ctx.client)
                    _ = try ctx.client.sendV2(method: "workspace.set_progress", params: params)
                    print("OK")
                }
            ),

            CommandDescriptor(
                names: ["clear-progress"],
                helpLines: [],
                detailedUsage: """
                Usage: programa clear-progress [flags]

                Clear the sidebar progress bar for a workspace.

                Flags:
                  --workspace <id|ref>   Target workspace (default: $PROGRAMA_WORKSPACE_ID)

                Example:
                  programa clear-progress
                """,
                execute: { ctx in
                    let parsed = self.parseFlagArgs(ctx.commandArgs)
                    let workspaceId = try self.resolveSidebarWorkspaceId(options: parsed.options, windowOverride: ctx.windowId, client: ctx.client)
                    _ = try ctx.client.sendV2(method: "workspace.clear_progress", params: ["workspace_id": workspaceId])
                    print("OK")
                }
            ),

            CommandDescriptor(
                names: ["log"],
                helpLines: [],
                detailedUsage: """
                Usage: programa log [flags] [--] <message>

                Append a log entry to the sidebar for a workspace.

                Flags:
                  --level <level>        Log level: info, progress, success, warning, error (default: info)
                  --source <name>        Source label (e.g. "build", "test")
                  --workspace <id|ref>   Target workspace (default: $PROGRAMA_WORKSPACE_ID)

                Example:
                  programa log "Build started"
                  programa log --level error --source build "Compilation failed"
                  programa log --level success -- "All 42 tests passed"
                """,
                execute: { ctx in
                    let parsed = self.parseFlagArgs(ctx.commandArgs)
                    guard !parsed.positional.isEmpty else {
                        throw CLIError(message: "ERROR: Missing message — usage: log [--level=X] [--source=X] [--tab=X] -- <message>")
                    }
                    let levelStr = parsed.options["level"] ?? "info"
                    guard ["info", "progress", "success", "warning", "error"].contains(levelStr) else {
                        throw CLIError(message: "ERROR: Unknown log level '\(levelStr)' — use: info, progress, success, warning, error")
                    }
                    var params: [String: Any] = [
                        "message": parsed.positional.joined(separator: " "),
                        "level": levelStr,
                    ]
                    if let source = self.normalizedFlagValue(parsed.options["source"]) { params["source"] = source }
                    params["workspace_id"] = try self.resolveSidebarWorkspaceId(options: parsed.options, windowOverride: ctx.windowId, client: ctx.client)
                    _ = try ctx.client.sendV2(method: "workspace.log", params: params)
                    print("OK")
                }
            ),

            CommandDescriptor(
                names: ["clear-log"],
                helpLines: [],
                detailedUsage: """
                Usage: programa clear-log [flags]

                Clear all sidebar log entries for a workspace.

                Flags:
                  --workspace <id|ref>   Target workspace (default: $PROGRAMA_WORKSPACE_ID)

                Example:
                  programa clear-log
                """,
                execute: { ctx in
                    let parsed = self.parseFlagArgs(ctx.commandArgs)
                    let workspaceId = try self.resolveSidebarWorkspaceId(options: parsed.options, windowOverride: ctx.windowId, client: ctx.client)
                    _ = try ctx.client.sendV2(method: "workspace.clear_log", params: ["workspace_id": workspaceId])
                    print("OK")
                }
            ),

            CommandDescriptor(
                names: ["list-log"],
                helpLines: [],
                argumentContract: .listLog,
                detailedUsage: """
                Usage: programa list-log [flags]

                List sidebar log entries for a workspace.

                Flags:
                  --limit <n>            Show only the last N entries
                  --workspace <id|ref>   Target workspace (default: $PROGRAMA_WORKSPACE_ID)

                Example:
                  programa list-log
                  programa list-log --limit 5
                """,
                execute: { ctx in
                    let parsed = self.parseFlagArgs(ctx.commandArgs)
                    var params: [String: Any] = [:]
                    if let limitStr = parsed.options["limit"] {
                        guard !limitStr.isEmpty else {
                            throw CLIError(message: "ERROR: Missing limit value — usage: list_log [--limit=N] [--tab=X]")
                        }
                        guard let limit = Int(limitStr), limit >= 0 else {
                            throw CLIError(message: "ERROR: Invalid limit '\(limitStr)' — must be >= 0")
                        }
                        params["limit"] = limit
                    }
                    params["workspace_id"] = try self.resolveSidebarWorkspaceId(options: parsed.options, windowOverride: ctx.windowId, client: ctx.client)
                    let payload = try ctx.client.sendV2(method: "workspace.list_log", params: params)
                    let entries = payload["entries"] as? [[String: Any]] ?? []
                    if entries.isEmpty {
                        print("No log entries")
                    } else {
                        print(entries.map(self.sidebarLogLineText).joined(separator: "\n"))
                    }
                }
            ),

            CommandDescriptor(
                names: ["sidebar-state"],
                helpLines: [],
                detailedUsage: """
                Usage: programa sidebar-state [flags]

                Dump all sidebar metadata for a workspace (cwd, git branch, ports,
                status entries, progress, log entries).

                Flags:
                  --workspace <id|ref>   Target workspace (default: $PROGRAMA_WORKSPACE_ID)

                Example:
                  programa sidebar-state
                  programa sidebar-state --workspace workspace:2
                """,
                execute: { ctx in
                    let parsed = self.parseFlagArgs(ctx.commandArgs)
                    let workspaceId = try self.resolveSidebarWorkspaceId(options: parsed.options, windowOverride: ctx.windowId, client: ctx.client)
                    let payload = try ctx.client.sendV2(method: "workspace.sidebar_state", params: ["workspace_id": workspaceId])
                    print(self.sidebarStateText(payload))
                }
            ),

            ]
        descriptors += self.hooksDescriptors()
        descriptors += [

            CommandDescriptor(
                names: ["set-app-focus"],
                helpLines: ["set-app-focus <active|inactive|clear>"],
                detailedUsage: """
                Usage: programa set-app-focus <active|inactive|clear>

                Override app focus state for notification routing tests.

                Example:
                  programa set-app-focus inactive
                  programa set-app-focus clear
                """,
                execute: { ctx in
                    guard let value = ctx.commandArgs.first else { throw CLIError(message: "set-app-focus requires a value") }
                    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    let state: String
                    switch normalized {
                    case "active", "1", "true": state = "active"
                    case "inactive", "0", "false": state = "inactive"
                    case "clear", "none", "": state = "clear"
                    default:
                        throw CLIError(message: "ERROR: Expected active, inactive, or clear")
                    }
                    _ = try ctx.client.sendV2(method: "app.focus_override.set", params: ["state": state])
                    print("OK")
                }
            ),

            CommandDescriptor(
                names: ["simulate-app-active"],
                helpLines: ["simulate-app-active"],
                detailedUsage: """
                Usage: programa simulate-app-active

                Trigger the app-active handler used by notification focus tests.
                """,
                execute: { ctx in
                    _ = try ctx.client.sendV2(method: "app.simulate_active")
                    print("OK")
                }
            ),

            CommandDescriptor(
                names: ["__tmux-compat"],
                helpLines: [],
                helpPolicy: .passthrough,
                execute: { ctx in
                    try self.runClaudeTeamsTmuxCompat(
                        commandArgs: ctx.commandArgs,
                        client: ctx.client,
                        jsonOutput: ctx.jsonOutput,
                        idFormat: ctx.idFormat,
                        windowOverride: ctx.windowId
                    )
                }
            ),

            // MARK: - tmux compatibility commands (all share one bespoke
            // handler; help text preserves the original grouped layout,
            // including the two pipe-separated combo lines).
            CommandDescriptor(names: [], helpLines: ["", "# tmux compatibility commands"], execute: nil),
        ]
        descriptors += Self.tmuxCompatDescriptors(runTmuxCompatCommand: { ctx in
            try self.runTmuxCompatCommand(
                command: ctx.command,
                commandArgs: ctx.commandArgs,
                client: ctx.client,
                jsonOutput: ctx.jsonOutput,
                idFormat: ctx.idFormat,
                windowOverride: ctx.windowId
            )
        })
        descriptors += [
            CommandDescriptor(names: [], helpLines: [""], execute: nil),

            CommandDescriptor(
                names: ["markdown"],
                helpLines: ["markdown [open] <path>             (open markdown file in formatted viewer panel with live reload)"],
                execute: { ctx in
                    try self.runMarkdownCommand(commandArgs: ctx.commandArgs, client: ctx.client, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat)
                }
            ),

            CommandDescriptor(names: [], helpLines: [""], execute: nil),

            CommandDescriptor(
                names: ["browser"],
                helpLines: [
                    "browser [--surface <id|ref> | <surface>] <subcommand> ...",
                    "browser open [url]                   (create browser split in caller's workspace; if surface supplied, behaves like navigate)",
                    "browser open-split [url]",
                    "browser goto|navigate <url> [--snapshot-after]",
                    "browser back|forward|reload [--snapshot-after]",
                    "browser url|get-url",
                    "browser snapshot [--interactive|-i] [--cursor] [--compact] [--max-depth <n>] [--selector <css>]",
                    "browser eval <script>",
                    "browser wait [--selector <css>] [--text <text>] [--url-contains <text>] [--load-state <interactive|complete>] [--function <js>] [--timeout-ms <ms>]",
                    "browser click|dblclick|hover|focus|check|uncheck|scroll-into-view <selector> [--snapshot-after]",
                    "browser type <selector> <text> [--snapshot-after]",
                    "browser fill <selector> [text] [--snapshot-after]   (empty text clears input)",
                    "browser press|keydown|keyup <key> [--snapshot-after]",
                    "browser select <selector> <value> [--snapshot-after]",
                    "browser scroll [--selector <css>] [--dx <n>] [--dy <n>] [--snapshot-after]",
                    "browser screenshot [--out <path>] [--json]",
                    "browser get <url|title|text|html|value|attr|count|box|styles> [...]",
                    "browser is <visible|enabled|checked> <selector>",
                    "browser find <role|text|label|placeholder|alt|title|testid|first|last|nth> ...",
                    "browser frame <selector|main>",
                    "browser dialog <accept|dismiss> [text]",
                    "browser download [wait] [--path <path>] [--timeout-ms <ms>]",
                    "browser cookies <get|set|clear> [...]",
                    "browser storage <local|session> <get|set|clear> [...]",
                    "browser tab <new|list|switch|close|<index>> [...]",
                    "browser console <list|clear>",
                    "browser errors <list|clear>",
                    "browser highlight <selector>",
                    "browser state <save|load> <path>",
                    "browser addinitscript <script>",
                    "browser addscript <script>",
                    "browser addstyle <css>",
                    "browser identify [--surface <id|ref>]",
                ],
                execute: { ctx in
                    try self.runBrowserCommand(commandArgs: ctx.commandArgs, client: ctx.client, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat)
                }
            ),

            // Legacy aliases shimmed onto the v2 browser command surface.
            // Undocumented in the old help text; kept that way here too.
            CommandDescriptor(
                names: ["open-browser"],
                helpLines: [],
                execute: { ctx in
                    try self.runBrowserCommand(commandArgs: ["open"] + ctx.commandArgs, client: ctx.client, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat)
                }
            ),
            CommandDescriptor(
                names: ["navigate"],
                helpLines: [],
                execute: { ctx in
                    let bridged = self.replaceToken(ctx.commandArgs, from: "--panel", to: "--surface")
                    try self.runBrowserCommand(commandArgs: ["navigate"] + bridged, client: ctx.client, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat)
                }
            ),
            CommandDescriptor(
                names: ["browser-back"],
                helpLines: [],
                execute: { ctx in
                    let bridged = self.replaceToken(ctx.commandArgs, from: "--panel", to: "--surface")
                    try self.runBrowserCommand(commandArgs: ["back"] + bridged, client: ctx.client, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat)
                }
            ),
            CommandDescriptor(
                names: ["browser-forward"],
                helpLines: [],
                execute: { ctx in
                    let bridged = self.replaceToken(ctx.commandArgs, from: "--panel", to: "--surface")
                    try self.runBrowserCommand(commandArgs: ["forward"] + bridged, client: ctx.client, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat)
                }
            ),
            CommandDescriptor(
                names: ["browser-reload"],
                helpLines: [],
                execute: { ctx in
                    let bridged = self.replaceToken(ctx.commandArgs, from: "--panel", to: "--surface")
                    try self.runBrowserCommand(commandArgs: ["reload"] + bridged, client: ctx.client, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat)
                }
            ),
            CommandDescriptor(
                names: ["get-url"],
                helpLines: [],
                execute: { ctx in
                    let bridged = self.replaceToken(ctx.commandArgs, from: "--panel", to: "--surface")
                    try self.runBrowserCommand(commandArgs: ["get-url"] + bridged, client: ctx.client, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat)
                }
            ),
            CommandDescriptor(
                names: ["focus-webview"],
                helpLines: [],
                execute: { ctx in
                    let bridged = self.replaceToken(ctx.commandArgs, from: "--panel", to: "--surface")
                    try self.runBrowserCommand(commandArgs: ["focus-webview"] + bridged, client: ctx.client, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat)
                }
            ),
            CommandDescriptor(
                names: ["is-webview-focused"],
                helpLines: [],
                execute: { ctx in
                    let bridged = self.replaceToken(ctx.commandArgs, from: "--panel", to: "--surface")
                    try self.runBrowserCommand(commandArgs: ["is-webview-focused"] + bridged, client: ctx.client, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat)
                }
            ),

            CommandDescriptor(
                names: ["help"],
                helpLines: ["help"],
                connectionPolicy: .local,
                detailedUsage: """
                Usage: programa help

                Show top-level CLI usage and command list.
                """,
                execute: { ctx in
                    print(self.usage())
                }
            ),
        ]
        return descriptors
    }

    /// Looks up the descriptor whose `names` contains `command`, if any.
    private func commandDescriptor(named command: String) -> CommandDescriptor? {
        commandDescriptors().first { $0.names.contains(command) }
    }

    func resolvePath(_ path: String) -> String {
        let expanded = NSString(string: path).expandingTildeInPath
        if expanded.hasPrefix("/") { return expanded }
        let cwd = FileManager.default.currentDirectoryPath
        return (cwd as NSString).appendingPathComponent(expanded)
    }

    func sanitizedFilenameComponent(_ raw: String) -> String {
        let sanitized = raw.replacingOccurrences(
            of: #"[^\p{L}\p{N}._-]+"#,
            with: "-",
            options: .regularExpression
        )
        let trimmed = sanitized.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return trimmed.isEmpty ? "item" : trimmed
    }

    func bestEffortPruneTemporaryFiles(
        in directoryURL: URL,
        keepingMostRecent maxCount: Int = 50,
        maxAge: TimeInterval = 24 * 60 * 60
    ) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let now = Date()
        let datedEntries = entries.compactMap { url -> (url: URL, date: Date)? in
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .creationDateKey]),
                  values.isRegularFile == true else {
                return nil
            }
            return (url, values.contentModificationDate ?? values.creationDate ?? .distantPast)
        }.sorted { $0.date > $1.date }

        for (index, entry) in datedEntries.enumerated() {
            if index >= maxCount || now.timeIntervalSince(entry.date) > maxAge {
                try? FileManager.default.removeItem(at: entry.url)
            }
        }
    }

    /// Returns true if the argument looks like a filesystem path rather than a CLI command.
    func looksLikePath(_ arg: String) -> Bool {
        if arg == "." || arg == ".." { return true }
        if arg.hasPrefix("/") || arg.hasPrefix("./") || arg.hasPrefix("../") || arg.hasPrefix("~") { return true }
        if arg.contains("/") { return true }
        return false
    }

    /// Open a path in programa by creating a new workspace with the given directory.
    /// Launches the app if it isn't already running.
    private func openPath(_ path: String, socketPath: String) throws {
        let resolved = resolvePath(path)
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir)

        let directory: String
        if exists && isDir.boolValue {
            directory = resolved
        } else if exists {
            // It's a file; use its parent directory
            directory = (resolved as NSString).deletingLastPathComponent
        } else {
            throw CLIError(message: "Path does not exist: \(resolved)")
        }

        // Try connecting to the socket. If it fails, launch the app and retry.
        let client = SocketClient(path: socketPath)
        if (try? client.connect()) == nil {
            client.close()
            try launchApp()
            let launchedClient = try SocketClient.waitForConnectableSocket(path: socketPath, timeout: 10)
            defer { launchedClient.close() }
            let params: [String: Any] = ["cwd": directory]
            let response = try launchedClient.sendV2(method: "workspace.create", params: params)
            let wsRef = (response["workspace_ref"] as? String) ?? (response["workspace_id"] as? String) ?? ""
            if !wsRef.isEmpty {
                print("OK \(wsRef)")
            }
            try activateApp()
            return
        }
        defer { client.close() }

        let params: [String: Any] = ["cwd": directory]
        let response = try client.sendV2(method: "workspace.create", params: params)
        let wsRef = (response["workspace_ref"] as? String) ?? (response["workspace_id"] as? String) ?? ""
        if !wsRef.isEmpty {
            print("OK \(wsRef)")
        }

        // Bring the app to front
        try activateApp()
    }

    private func runFeedback(
        commandArgs: [String],
        socketPath: String,
        explicitPassword: String?,
        jsonOutput: Bool
    ) throws {
        let (emailOpt, rem0) = parseOption(commandArgs, name: "--email")
        let (bodyOpt, rem1) = parseOption(rem0, name: "--body")
        let (imagePaths, rem2) = parseRepeatedOption(rem1, name: "--image")
        let remaining = rem2.filter { $0 != "--" }

        if let unknown = remaining.first {
            throw CLIError(message: "feedback: unknown flag '\(unknown)'. Known flags: --email <email>, --body <text>, --image <path>")
        }

        let client = try connectClient(
            socketPath: socketPath,
            explicitPassword: explicitPassword,
            launchIfNeeded: true
        )
        defer { client.close() }

        if emailOpt == nil && bodyOpt == nil && imagePaths.isEmpty {
            var params: [String: Any] = [:]
            let env = ProcessInfo.processInfo.environment
            if let workspaceId = env["PROGRAMA_WORKSPACE_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !workspaceId.isEmpty {
                params["workspace_id"] = workspaceId
                params["activate"] = false
            } else {
                params["activate"] = true
            }
            let response = try client.sendV2(method: "feedback.open", params: params)
            if jsonOutput {
                print(jsonString(response))
            } else {
                print("OK")
            }
            return
        }

        guard let email = emailOpt?.trimmingCharacters(in: .whitespacesAndNewlines),
              email.isEmpty == false else {
            throw CLIError(message: "feedback requires --email <email> when sending feedback")
        }
        guard let body = bodyOpt, body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw CLIError(message: "feedback requires --body <text> when sending feedback")
        }

        let resolvedImages = imagePaths.map(resolvePath)
        let response = try client.sendV2(method: "feedback.submit", params: [
            "email": email,
            "body": body,
            "image_paths": resolvedImages,
        ])
        if jsonOutput {
            print(jsonString(response))
        } else {
            print("OK")
        }
    }

    private func runShortcuts(
        commandArgs: [String],
        socketPath: String,
        explicitPassword: String?,
        jsonOutput: Bool
    ) throws {
        let remaining = commandArgs.filter { $0 != "--" }
        if let unknown = remaining.first {
            throw CLIError(message: "shortcuts: unknown flag '\(unknown)'")
        }

        let client = try connectClient(
            socketPath: socketPath,
            explicitPassword: explicitPassword,
            launchIfNeeded: true
        )
        defer { client.close() }

        let response = try client.sendV2(method: "settings.open", params: [
            "target": "keyboardShortcuts",
            "activate": true,
        ])
        if jsonOutput {
            print(jsonString(response))
        } else {
            print("OK")
        }
    }

    private func connectClient(
        socketPath: String,
        explicitPassword: String?,
        launchIfNeeded: Bool
    ) throws -> SocketClient {
        let client = SocketClient(path: socketPath)
        if launchIfNeeded && (try? client.connect()) == nil {
            client.close()
            try launchApp()
            let launchedClient = try SocketClient.waitForConnectableSocket(path: socketPath, timeout: 10)
            try authenticateClientIfNeeded(
                launchedClient,
                explicitPassword: explicitPassword,
                socketPath: socketPath
            )
            return launchedClient
        }

        try client.connect()
        try authenticateClientIfNeeded(
            client,
            explicitPassword: explicitPassword,
            socketPath: socketPath
        )
        return client
    }

    func authenticateClientIfNeeded(
        _ client: SocketClient,
        explicitPassword: String?,
        socketPath: String
    ) throws {
        if let socketPassword = SocketPasswordResolver.resolve(
            explicit: explicitPassword,
            socketPath: socketPath
        ) {
            // v2 JSON-RPC auth.login. The server treats this the same whether or not
            // password auth is actually required: when required, the pre-protocol auth
            // gate verifies the password before any command is processed; when not
            // required, the server's own auth.login handler answers with
            // authenticated: true, required: false rather than an error.
            _ = try client.sendV2(method: "auth.login", params: ["password": socketPassword])
        }
    }

    private func launchApp() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Programa"]
        try process.run()
        process.waitUntilExit()
    }

    private func activateApp() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Programa"]
        try process.run()
        process.waitUntilExit()
    }

    private func resolvedIDFormat(jsonOutput: Bool, raw: String?) throws -> CLIIDFormat {
        _ = jsonOutput
        if let parsed = try CLIIDFormat.parse(raw) {
            return parsed
        }
        return .refs
    }

    func formatIDs(_ object: Any, mode: CLIIDFormat) -> Any {
        switch object {
        case let dict as [String: Any]:
            var out: [String: Any] = [:]
            for (k, v) in dict {
                out[k] = formatIDs(v, mode: mode)
            }

            switch mode {
            case .both:
                break
            case .refs:
                if out["ref"] != nil && out["id"] != nil {
                    out.removeValue(forKey: "id")
                }
                let keys = Array(out.keys)
                for key in keys where key.hasSuffix("_id") {
                    let prefix = String(key.dropLast(3))
                    if out["\(prefix)_ref"] != nil {
                        out.removeValue(forKey: key)
                    }
                }
                for key in keys where key.hasSuffix("_ids") {
                    let prefix = String(key.dropLast(4))
                    if out["\(prefix)_refs"] != nil {
                        out.removeValue(forKey: key)
                    }
                }
            case .uuids:
                if out["id"] != nil && out["ref"] != nil {
                    out.removeValue(forKey: "ref")
                }
                let keys = Array(out.keys)
                for key in keys where key.hasSuffix("_ref") {
                    let prefix = String(key.dropLast(4))
                    if out["\(prefix)_id"] != nil {
                        out.removeValue(forKey: key)
                    }
                }
                for key in keys where key.hasSuffix("_refs") {
                    let prefix = String(key.dropLast(5))
                    if out["\(prefix)_ids"] != nil {
                        out.removeValue(forKey: key)
                    }
                }
            }
            return out

        case let array as [Any]:
            return array.map { formatIDs($0, mode: mode) }

        default:
            return object
        }
    }

    func intFromAny(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String { return Int(s) }
        return nil
    }

    func doubleFromAny(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let f = value as? Float { return Double(f) }
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    func parseBoolString(_ raw: String) -> Bool? {
        switch raw.lowercased() {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return nil
        }
    }

    private func parsePositiveInt(_ raw: String?, label: String) throws -> Int? {
        guard let raw else { return nil }
        guard let value = Int(raw) else {
            throw CLIError(message: "\(label) must be an integer")
        }
        return value
    }

    func isHandleRef(_ value: String) -> Bool {
        let pieces = value.split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count == 2 else { return false }
        let kind = String(pieces[0]).lowercased()
        guard ["window", "workspace", "pane", "surface"].contains(kind) else { return false }
        return Int(String(pieces[1])) != nil
    }

    /// Generic handle normalizer shared by window/workspace/pane/surface lookups.
    /// Resolves a raw CLI argument (UUID or handle ref) to a canonical
    /// handle ref/id, optionally scoped to a parent handle and falling back to a
    /// caller-supplied "current"/"focused" resolver when `raw` is nil. Bare indexes
    /// are rejected with a clear error.
    private func normalizeHandle(
        _ raw: String?,
        client: SocketClient,
        kind: String,
        filterParam: (key: String, value: String)? = nil,
        fallback: () throws -> String?
    ) throws -> String? {
        guard let raw else {
            return try fallback()
        }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if isUUID(trimmed) || isHandleRef(trimmed) {
            return trimmed
        }
        if Int(trimmed) != nil {
            let listCommand = kind == "surface" ? "list-pane-surfaces" : "list-\(kind)s"
            throw CLIError(message: "\(kind): bare indexes are no longer accepted; use a UUID or short ref like \(kind):2 (see \(listCommand))")
        }
        throw CLIError(message: "Invalid \(kind) handle: \(trimmed) (expected UUID or ref like \(kind):1)")
    }

    func normalizeWindowHandle(_ raw: String?, client: SocketClient, allowCurrent: Bool = false) throws -> String? {
        try normalizeHandle(raw, client: client, kind: "window") {
            guard allowCurrent else { return nil }
            let current = try client.sendV2(method: "window.current")
            return (current["window_ref"] as? String) ?? (current["window_id"] as? String)
        }
    }

    func normalizeWorkspaceHandle(
        _ raw: String?,
        client: SocketClient,
        windowHandle: String? = nil,
        allowCurrent: Bool = false
    ) throws -> String? {
        try normalizeHandle(
            raw,
            client: client,
            kind: "workspace",
            filterParam: windowHandle.map { ("window_id", $0) }
        ) {
            guard allowCurrent else { return nil }
            let current = try client.sendV2(method: "workspace.current")
            return (current["workspace_ref"] as? String) ?? (current["workspace_id"] as? String)
        }
    }

    func normalizePaneHandle(
        _ raw: String?,
        client: SocketClient,
        workspaceHandle: String? = nil,
        allowFocused: Bool = false
    ) throws -> String? {
        try normalizeHandle(
            raw,
            client: client,
            kind: "pane",
            filterParam: workspaceHandle.map { ("workspace_id", $0) }
        ) {
            guard allowFocused else { return nil }
            let ident = try client.sendV2(method: "system.identify")
            let focused = ident["focused"] as? [String: Any] ?? [:]
            return (focused["pane_ref"] as? String) ?? (focused["pane_id"] as? String)
        }
    }

    func normalizeSurfaceHandle(
        _ raw: String?,
        client: SocketClient,
        workspaceHandle: String? = nil,
        allowFocused: Bool = false
    ) throws -> String? {
        try normalizeHandle(
            raw,
            client: client,
            kind: "surface",
            filterParam: workspaceHandle.map { ("workspace_id", $0) }
        ) {
            guard allowFocused else { return nil }
            let ident = try client.sendV2(method: "system.identify")
            let focused = ident["focused"] as? [String: Any] ?? [:]
            return (focused["surface_ref"] as? String) ?? (focused["surface_id"] as? String)
        }
    }

    private func canonicalSurfaceHandleFromTabInput(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let pieces = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count == 2,
              String(pieces[0]).lowercased() == "tab",
              let ordinal = Int(String(pieces[1])) else {
            return trimmed
        }
        return "surface:\(ordinal)"
    }

    private func normalizeTabHandle(
        _ raw: String?,
        client: SocketClient,
        workspaceHandle: String? = nil,
        allowFocused: Bool = false
    ) throws -> String? {
        guard let raw else {
            return try normalizeSurfaceHandle(
                nil,
                client: client,
                workspaceHandle: workspaceHandle,
                allowFocused: allowFocused
            )
        }

        let canonical = canonicalSurfaceHandleFromTabInput(raw)
        return try normalizeSurfaceHandle(
            canonical,
            client: client,
            workspaceHandle: workspaceHandle,
            allowFocused: false
        )
    }

    private func displayTabHandle(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let pieces = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count == 2,
              String(pieces[0]).lowercased() == "surface",
              let ordinal = Int(String(pieces[1])) else {
            return trimmed
        }
        return "tab:\(ordinal)"
    }

    func formatHandle(_ payload: [String: Any], kind: String, idFormat: CLIIDFormat) -> String? {
        let id = payload["\(kind)_id"] as? String
        let ref = payload["\(kind)_ref"] as? String
        switch idFormat {
        case .refs:
            return ref ?? id
        case .uuids:
            return id ?? ref
        case .both:
            if let ref, let id {
                return "\(ref) (\(id))"
            }
            return ref ?? id
        }
    }

    private func formatTabHandle(_ payload: [String: Any], idFormat: CLIIDFormat) -> String? {
        let id = (payload["tab_id"] as? String) ?? (payload["surface_id"] as? String)
        let refRaw = (payload["tab_ref"] as? String) ?? (payload["surface_ref"] as? String)
        let ref = displayTabHandle(refRaw)
        switch idFormat {
        case .refs:
            return ref ?? id
        case .uuids:
            return id ?? ref
        case .both:
            if let ref, let id {
                return "\(ref) (\(id))"
            }
            return ref ?? id
        }
    }

    private func formatCreatedTabHandle(_ payload: [String: Any], idFormat: CLIIDFormat) -> String? {
        let id = (payload["created_tab_id"] as? String) ?? (payload["created_surface_id"] as? String)
        let refRaw = (payload["created_tab_ref"] as? String) ?? (payload["created_surface_ref"] as? String)
        let ref = displayTabHandle(refRaw)
        switch idFormat {
        case .refs:
            return ref ?? id
        case .uuids:
            return id ?? ref
        case .both:
            if let ref, let id {
                return "\(ref) (\(id))"
            }
            return ref ?? id
        }
    }

    func printV2Payload(
        _ payload: [String: Any],
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        fallbackText: String
    ) {
        if jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
        } else {
            print(fallbackText)
        }
    }

    private func debugString(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        if let string = value as? String {
            return string
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return String(describing: value)
    }

    private func debugBool(_ value: Any?) -> Bool? {
        if let bool = value as? Bool {
            return bool
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        if let string = value as? String {
            return parseBoolString(string)
        }
        return nil
    }

    private func debugFlag(_ value: Any?) -> String {
        guard let bool = debugBool(value) else { return "nil" }
        return bool ? "1" : "0"
    }

    private func formatDebugRect(_ value: Any?) -> String? {
        guard let rect = value as? [String: Any],
              let x = doubleFromAny(rect["x"]),
              let y = doubleFromAny(rect["y"]),
              let width = doubleFromAny(rect["width"]),
              let height = doubleFromAny(rect["height"]) else {
            return nil
        }
        return String(format: "{%.1f,%.1f %.1fx%.1f}", x, y, width, height)
    }

    private func formatDebugPorts(_ value: Any?) -> String {
        guard let array = value as? [Any], !array.isEmpty else { return "[]" }
        let ports = array
            .compactMap { intFromAny($0) }
            .map(String.init)
        return ports.isEmpty ? "[]" : ports.joined(separator: ",")
    }

    private func formatDebugList(_ value: Any?) -> String? {
        guard let array = value as? [Any], !array.isEmpty else { return nil }
        let items = array.compactMap { item -> String? in
            if let string = item as? String {
                return string
            }
            return debugString(item)
        }
        guard !items.isEmpty else { return nil }
        return items.joined(separator: ">")
    }

    private func formatDebugAge(_ value: Any?) -> String? {
        guard let seconds = doubleFromAny(value) else { return nil }
        return String(format: "%.3fs", seconds)
    }

    private func formatDebugTerminalsPayload(_ payload: [String: Any], idFormat: CLIIDFormat) -> String {
        let terminals = payload["terminals"] as? [[String: Any]] ?? []
        guard !terminals.isEmpty else { return "No terminal surfaces" }

        return terminals.map { item in
            let index = intFromAny(item["index"]) ?? 0
            let surface = formatHandle(item, kind: "surface", idFormat: idFormat) ?? "?"
            let window = formatHandle(item, kind: "window", idFormat: idFormat) ?? "nil"
            let workspace = formatHandle(item, kind: "workspace", idFormat: idFormat) ?? "nil"
            let pane = formatHandle(item, kind: "pane", idFormat: idFormat) ?? "nil"
            let bonsplitTab = debugString(item["bonsplit_tab_id"]) ?? "nil"
            let lastKnownWorkspace = debugString(item["last_known_workspace_ref"]) ?? debugString(item["last_known_workspace_id"]) ?? "nil"
            let titleSuffix: String = {
                guard let title = debugString(item["surface_title"]), !title.isEmpty else { return "" }
                let escaped = title.replacingOccurrences(of: "\"", with: "\\\"")
                return " \"\(escaped)\""
            }()
            let branchLabel: String = {
                guard let branch = debugString(item["git_branch"]), !branch.isEmpty else { return "nil" }
                return debugBool(item["git_dirty"]) == true ? "\(branch)*" : branch
            }()
            let teardownLabel: String = {
                guard debugBool(item["teardown_requested"]) == true else { return "nil" }
                let reason = debugString(item["teardown_requested_reason"]) ?? "requested"
                let age = formatDebugAge(item["teardown_requested_age_seconds"]) ?? "unknown"
                return "\(reason)@\(age)"
            }()
            let portalHostLabel: String = {
                let hostId = debugString(item["portal_host_id"]) ?? "nil"
                let area = doubleFromAny(item["portal_host_area"]).map { String(format: "%.1f", $0) } ?? "nil"
                let inWindow = debugFlag(item["portal_host_in_window"])
                return "\(hostId)/win=\(inWindow)/area=\(area)"
            }()
            let windowMetaLabel: String = {
                let title = debugString(item["window_title"]) ?? "nil"
                let windowClass = debugString(item["window_class"]) ?? "nil"
                let controllerClass = debugString(item["window_controller_class"]) ?? "nil"
                let delegateClass = debugString(item["window_delegate_class"]) ?? "nil"
                return "title=\(title) class=\(windowClass) controller=\(controllerClass) delegate=\(delegateClass)"
            }()

            let line1 =
                "[\(index)] \(surface)\(titleSuffix) " +
                "mapped=\(debugFlag(item["mapped"])) tree=\(debugFlag(item["tree_visible"])) " +
                "window=\(window) workspace=\(workspace) pane=\(pane) bonsplitTab=\(bonsplitTab) " +
                "ctx=\(debugString(item["surface_context"]) ?? "nil")"

            let line2 =
                "    runtime=\(debugFlag(item["runtime_surface_ready"])) " +
                "focused=\(debugFlag(item["surface_focused"])) " +
                "selected=\(debugFlag(item["surface_selected_in_pane"])) " +
                "pinned=\(debugFlag(item["surface_pinned"])) " +
                "terminal=\(debugString(item["terminal_object_ptr"]) ?? "nil") " +
                "hosted=\(debugString(item["hosted_view_ptr"]) ?? "nil") " +
                "ghostty=\(debugString(item["ghostty_surface_ptr"]) ?? "nil") " +
                "portal=\(debugString(item["portal_binding_state"]) ?? "nil")#\(debugString(item["portal_binding_generation"]) ?? "nil") " +
                "teardown=\(teardownLabel)"

            let line3 =
                "    tty=\(debugString(item["tty"]) ?? "nil") " +
                "cwd=\(debugString(item["current_directory"]) ?? debugString(item["requested_working_directory"]) ?? "nil") " +
                "branch=\(branchLabel) " +
                "ports=\(formatDebugPorts(item["listening_ports"])) " +
                "visible=\(debugFlag(item["hosted_view_visible_in_ui"])) " +
                "inWindow=\(debugFlag(item["hosted_view_in_window"])) " +
                "superview=\(debugFlag(item["hosted_view_has_superview"])) " +
                "hidden=\(debugFlag(item["hosted_view_hidden"])) " +
                "ancestorHidden=\(debugFlag(item["hosted_view_hidden_or_ancestor_hidden"])) " +
                "firstResponder=\(debugFlag(item["surface_view_first_responder"])) " +
                "windowNum=\(debugString(item["window_number"]) ?? "nil") " +
                "windowKey=\(debugFlag(item["window_key"])) " +
                "frame=\(formatDebugRect(item["hosted_view_frame_in_window"]) ?? "nil")"

            let line4 =
                "    created=\(formatDebugAge(item["surface_age_seconds"]) ?? "nil") " +
                "runtimeCreated=\(formatDebugAge(item["runtime_surface_age_seconds"]) ?? "nil") " +
                "lastWorkspace=\(lastKnownWorkspace) " +
                "initialCommand=\(debugString(item["initial_command"]) ?? "nil") " +
                "portalHost=\(portalHostLabel)"

            let line5 =
                "    window=\(windowMetaLabel) " +
                "chain=\(formatDebugList(item["hosted_view_superview_chain"]) ?? "nil")"

            return [line1, line2, line3, line4, line5].joined(separator: "\n")
        }
        .joined(separator: "\n")
    }

    private func runMoveSurface(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let surfaceRaw = optionValue(commandArgs, name: "--surface") ?? commandArgs.first
        guard let surfaceRaw else {
            throw CLIError(message: "move-surface requires --surface <id|ref>")
        }

        let workspaceRaw = optionValue(commandArgs, name: "--workspace")
        let windowRaw = optionValue(commandArgs, name: "--window")
        let paneRaw = optionValue(commandArgs, name: "--pane")
        let beforeRaw = optionValue(commandArgs, name: "--before") ?? optionValue(commandArgs, name: "--before-surface")
        let afterRaw = optionValue(commandArgs, name: "--after") ?? optionValue(commandArgs, name: "--after-surface")

        let windowHandle = try normalizeWindowHandle(windowRaw, client: client)
        let workspaceHandle = try normalizeWorkspaceHandle(workspaceRaw, client: client, windowHandle: windowHandle)
        let surfaceHandle = try normalizeSurfaceHandle(surfaceRaw, client: client, workspaceHandle: workspaceHandle, allowFocused: false)
        let paneHandle = try normalizePaneHandle(paneRaw, client: client, workspaceHandle: workspaceHandle)
        let beforeHandle = try normalizeSurfaceHandle(beforeRaw, client: client, workspaceHandle: workspaceHandle)
        let afterHandle = try normalizeSurfaceHandle(afterRaw, client: client, workspaceHandle: workspaceHandle)

        var params: [String: Any] = [:]
        if let surfaceHandle { params["surface_id"] = surfaceHandle }
        if let paneHandle { params["pane_id"] = paneHandle }
        if let workspaceHandle { params["workspace_id"] = workspaceHandle }
        if let windowHandle { params["window_id"] = windowHandle }
        if let beforeHandle { params["before_surface_id"] = beforeHandle }
        if let afterHandle { params["after_surface_id"] = afterHandle }

        if let indexRaw = optionValue(commandArgs, name: "--index") {
            guard let index = Int(indexRaw) else {
                throw CLIError(message: "--index must be an integer")
            }
            params["index"] = index
        }
        if let focusRaw = optionValue(commandArgs, name: "--focus") {
            guard let focus = parseBoolString(focusRaw) else {
                throw CLIError(message: "--focus must be true|false")
            }
            params["focus"] = focus
        }

        let payload = try client.sendV2(method: "surface.move", params: params)
        let summary = "OK surface=\(formatHandle(payload, kind: "surface", idFormat: idFormat) ?? "unknown") pane=\(formatHandle(payload, kind: "pane", idFormat: idFormat) ?? "unknown") workspace=\(formatHandle(payload, kind: "workspace", idFormat: idFormat) ?? "unknown") window=\(formatHandle(payload, kind: "window", idFormat: idFormat) ?? "unknown")"
        printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: summary)
    }

    private func runReorderSurface(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let surfaceRaw = optionValue(commandArgs, name: "--surface") ?? commandArgs.first
        guard let surfaceRaw else {
            throw CLIError(message: "reorder-surface requires --surface <id|ref>")
        }

        let workspaceRaw = optionValue(commandArgs, name: "--workspace")
        let workspaceHandle = try normalizeWorkspaceHandle(workspaceRaw, client: client)
        let surfaceHandle = try normalizeSurfaceHandle(surfaceRaw, client: client, workspaceHandle: workspaceHandle)

        let beforeRaw = optionValue(commandArgs, name: "--before") ?? optionValue(commandArgs, name: "--before-surface")
        let afterRaw = optionValue(commandArgs, name: "--after") ?? optionValue(commandArgs, name: "--after-surface")
        let beforeHandle = try normalizeSurfaceHandle(beforeRaw, client: client, workspaceHandle: workspaceHandle)
        let afterHandle = try normalizeSurfaceHandle(afterRaw, client: client, workspaceHandle: workspaceHandle)

        var params: [String: Any] = [:]
        if let surfaceHandle { params["surface_id"] = surfaceHandle }
        if let beforeHandle { params["before_surface_id"] = beforeHandle }
        if let afterHandle { params["after_surface_id"] = afterHandle }
        if let indexRaw = optionValue(commandArgs, name: "--index") {
            guard let index = Int(indexRaw) else {
                throw CLIError(message: "--index must be an integer")
            }
            params["index"] = index
        }

        let payload = try client.sendV2(method: "surface.reorder", params: params)
        let summary = "OK surface=\(formatHandle(payload, kind: "surface", idFormat: idFormat) ?? "unknown") pane=\(formatHandle(payload, kind: "pane", idFormat: idFormat) ?? "unknown") workspace=\(formatHandle(payload, kind: "workspace", idFormat: idFormat) ?? "unknown")"
        printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: summary)
    }

    private func runReorderWorkspace(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let workspaceRaw = optionValue(commandArgs, name: "--workspace") ?? commandArgs.first
        guard let workspaceRaw else {
            throw CLIError(message: "reorder-workspace requires --workspace <id|ref>")
        }

        let windowRaw = optionValue(commandArgs, name: "--window")
        let windowHandle = try normalizeWindowHandle(windowRaw, client: client)
        let workspaceHandle = try normalizeWorkspaceHandle(workspaceRaw, client: client, windowHandle: windowHandle)

        let beforeRaw = optionValue(commandArgs, name: "--before") ?? optionValue(commandArgs, name: "--before-workspace")
        let afterRaw = optionValue(commandArgs, name: "--after") ?? optionValue(commandArgs, name: "--after-workspace")
        let beforeHandle = try normalizeWorkspaceHandle(beforeRaw, client: client, windowHandle: windowHandle)
        let afterHandle = try normalizeWorkspaceHandle(afterRaw, client: client, windowHandle: windowHandle)

        var params: [String: Any] = [:]
        if let workspaceHandle { params["workspace_id"] = workspaceHandle }
        if let beforeHandle { params["before_workspace_id"] = beforeHandle }
        if let afterHandle { params["after_workspace_id"] = afterHandle }
        if let indexRaw = optionValue(commandArgs, name: "--index") {
            guard let index = Int(indexRaw) else {
                throw CLIError(message: "--index must be an integer")
            }
            params["index"] = index
        }
        if let windowHandle {
            params["window_id"] = windowHandle
        }

        let payload = try client.sendV2(method: "workspace.reorder", params: params)
        let summary = "OK workspace=\(formatHandle(payload, kind: "workspace", idFormat: idFormat) ?? "unknown") window=\(formatHandle(payload, kind: "window", idFormat: idFormat) ?? "unknown") index=\(payload["index"] ?? "?")"
        printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: summary)
    }

    private func runWorkspaceAction(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        let (workspaceOpt, rem0) = parseOption(commandArgs, name: "--workspace")
        let (actionOpt, rem1) = parseOption(rem0, name: "--action")
        let (titleOpt, rem2) = parseOption(rem1, name: "--title")
        let (colorOpt, rem3) = parseOption(rem2, name: "--color")
        let (descriptionOpt, rem4) = parseOption(rem3, name: "--description")

        var positional = rem4
        let actionRaw: String
        if let actionOpt {
            actionRaw = actionOpt
        } else if let first = positional.first {
            actionRaw = first
            positional.removeFirst()
        } else {
            throw CLIError(message: "workspace-action requires --action <name>")
        }

        if let unknown = positional.first(where: { $0.hasPrefix("--") }) {
            throw CLIError(message: "workspace-action: unknown flag '\(unknown)'")
        }

        let action = actionRaw.lowercased().replacingOccurrences(of: "-", with: "_")
        let workspaceArg = workspaceOpt ?? (windowOverride == nil ? ProcessInfo.processInfo.environment["PROGRAMA_WORKSPACE_ID"] : nil)
        let workspaceId = try normalizeWorkspaceHandle(workspaceArg, client: client, allowCurrent: true)

        let inferredPositionalRaw = positional.joined(separator: " ")
        let inferredPositional = inferredPositionalRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (titleOpt ?? (action == "rename" && !inferredPositional.isEmpty ? inferredPositional : nil))?.trimmingCharacters(in: .whitespacesAndNewlines)

        if action == "rename", (title?.isEmpty ?? true) {
            throw CLIError(message: "workspace-action rename requires --title <text> (or a trailing title)")
        }

        let color = (
            colorOpt ?? (action == "set_color" ? (inferredPositional.isEmpty ? nil : inferredPositional) : nil)
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
        if action == "set_color", (color?.isEmpty ?? true) {
            throw CLIError(message: "workspace-action set-color requires --color <name|#hex> (or a trailing color)")
        }

        let description = (
            descriptionOpt ?? (action == "set_description" && !inferredPositional.isEmpty ? inferredPositionalRaw : nil)
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
        if action == "set_description", (description?.isEmpty ?? true) {
            throw CLIError(message: "workspace-action set-description requires --description <text> (or trailing text)")
        }

        var params: [String: Any] = ["action": action]
        if let workspaceId {
            params["workspace_id"] = workspaceId
        }
        if let title, !title.isEmpty {
            params["title"] = title
        }
        if let color, !color.isEmpty {
            params["color"] = color
        }
        if let description, !description.isEmpty {
            params["description"] = description
        }

        let payload = try client.sendV2(method: "workspace.action", params: params)
        var summaryParts = ["OK", "action=\(action)"]
        if let workspaceHandle = formatHandle(payload, kind: "workspace", idFormat: idFormat) {
            summaryParts.append("workspace=\(workspaceHandle)")
        }
        if let windowHandle = formatHandle(payload, kind: "window", idFormat: idFormat) {
            summaryParts.append("window=\(windowHandle)")
        }
        if let closed = payload["closed"] {
            summaryParts.append("closed=\(closed)")
        }
        if let index = payload["index"] {
            summaryParts.append("index=\(index)")
        }
        if let color = payload["color"] as? String {
            summaryParts.append("color=\(color)")
        }
        printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: summaryParts.joined(separator: " "))
    }

    private func runTabAction(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        let (workspaceOpt, rem0) = parseOption(commandArgs, name: "--workspace")
        let (tabOpt, rem1) = parseOption(rem0, name: "--tab")
        let (surfaceOpt, rem2) = parseOption(rem1, name: "--surface")
        let (actionOpt, rem3) = parseOption(rem2, name: "--action")
        let (titleOpt, rem4) = parseOption(rem3, name: "--title")
        let (urlOpt, rem5) = parseOption(rem4, name: "--url")

        var positional = rem5
        let actionRaw: String
        if let actionOpt {
            actionRaw = actionOpt
        } else if let first = positional.first {
            actionRaw = first
            positional.removeFirst()
        } else {
            throw CLIError(message: "tab-action requires --action <name>")
        }

        if let unknown = positional.first(where: { $0.hasPrefix("--") }) {
            throw CLIError(message: "tab-action: unknown flag '\(unknown)'")
        }

        let action = actionRaw.lowercased().replacingOccurrences(of: "-", with: "_")
        let workspaceArg = workspaceOpt ?? (windowOverride == nil ? ProcessInfo.processInfo.environment["PROGRAMA_WORKSPACE_ID"] : nil)
        let tabArg = tabOpt
            ?? surfaceOpt
            ?? (workspaceOpt == nil && windowOverride == nil
                ? (ProcessInfo.processInfo.environment["PROGRAMA_TAB_ID"] ?? ProcessInfo.processInfo.environment["PROGRAMA_SURFACE_ID"])
                : nil)

        let workspaceId = try normalizeWorkspaceHandle(workspaceArg, client: client, allowCurrent: true)
        // If a workspace is explicitly targeted and no tab/surface is provided, let server-side
        // tab.action resolve that workspace's focused tab instead of using global focus.
        let allowFocusedFallback = (workspaceId == nil)
        let surfaceId = try normalizeTabHandle(
            tabArg,
            client: client,
            workspaceHandle: workspaceId,
            allowFocused: allowFocusedFallback
        )

        let inferredTitle = positional.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (titleOpt ?? (inferredTitle.isEmpty ? nil : inferredTitle))?.trimmingCharacters(in: .whitespacesAndNewlines)

        if action == "rename", (title?.isEmpty ?? true) {
            throw CLIError(message: "tab-action rename requires --title <text> (or a trailing title)")
        }

        var params: [String: Any] = ["action": action]
        if let workspaceId {
            params["workspace_id"] = workspaceId
        }
        if let surfaceId {
            params["surface_id"] = surfaceId
        }
        if let title, !title.isEmpty {
            params["title"] = title
        }
        if let urlOpt, !urlOpt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            params["url"] = urlOpt.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let payload = try client.sendV2(method: "tab.action", params: params)
        var summaryParts = ["OK", "action=\(action)"]
        if let tabHandle = formatTabHandle(payload, idFormat: idFormat) {
            summaryParts.append("tab=\(tabHandle)")
        }
        if let workspaceHandle = formatHandle(payload, kind: "workspace", idFormat: idFormat) {
            summaryParts.append("workspace=\(workspaceHandle)")
        }
        if let closed = payload["closed"] {
            summaryParts.append("closed=\(closed)")
        }
        if let created = formatCreatedTabHandle(payload, idFormat: idFormat) {
            summaryParts.append("created=\(created)")
        }
        printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: summaryParts.joined(separator: " "))
    }

    private func runRenameTab(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        let (workspaceOpt, rem0) = parseOption(commandArgs, name: "--workspace")
        let (tabOpt, rem1) = parseOption(rem0, name: "--tab")
        let (surfaceOpt, rem2) = parseOption(rem1, name: "--surface")
        let (titleOpt, rem3) = parseOption(rem2, name: "--title")

        if rem3.contains("--action") {
            throw CLIError(message: "rename-tab does not accept --action (it always performs rename)")
        }
        if let unknown = rem3.first(where: { $0.hasPrefix("--") && $0 != "--" }) {
            throw CLIError(message: "rename-tab: unknown flag '\(unknown)'")
        }

        let inferredTitle = rem3
            .dropFirst(rem3.first == "--" ? 1 : 0)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (titleOpt ?? (inferredTitle.isEmpty ? nil : inferredTitle))?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let title, !title.isEmpty else {
            throw CLIError(message: "rename-tab requires a title")
        }

        var forwarded: [String] = ["--action", "rename", "--title", title]
        if let workspaceOpt {
            forwarded += ["--workspace", workspaceOpt]
        }
        if let tabOpt {
            forwarded += ["--tab", tabOpt]
        } else if let surfaceOpt {
            forwarded += ["--surface", surfaceOpt]
        }

        try runTabAction(
            commandArgs: forwarded,
            client: client,
            jsonOutput: jsonOutput,
            idFormat: idFormat,
            windowOverride: windowOverride
        )
    }
    struct SSHCommandOptions {
        let destination: String
        let port: Int?
        let identityFile: String?
        let workspaceName: String?
        let noFocus: Bool
        let sshOptions: [String]
        let extraArguments: [String]
        let localSocketPath: String
        let remoteRelayPort: Int
    }

    struct RemoteDaemonManifest: Decodable {
        struct Entry: Decodable {
            let goOS: String
            let goArch: String
            let assetName: String
            let downloadURL: String
            let sha256: String
        }

        let schemaVersion: Int
        let appVersion: String
        let releaseTag: String
        let releaseURL: String
        let checksumsAssetName: String
        let checksumsURL: String
        let entries: [Entry]

        func entry(goOS: String, goArch: String) -> Entry? {
            entries.first { $0.goOS == goOS && $0.goArch == goArch }
        }
    }

    func resolveWorkspaceId(_ raw: String?, client: SocketClient) throws -> String {
        if let raw, isUUID(raw) {
            return raw
        }
        if let raw, isHandleRef(raw) {
            // Resolve ref to UUID — search across all windows
            let windows = try client.sendV2(method: "window.list")
            let windowList = windows["windows"] as? [[String: Any]] ?? []
            for window in windowList {
                guard let windowId = window["id"] as? String else { continue }
                let listed = try client.sendV2(method: "workspace.list", params: ["window_id": windowId])
                let items = listed["workspaces"] as? [[String: Any]] ?? []
                for item in items where (item["ref"] as? String) == raw {
                    if let id = item["id"] as? String { return id }
                }
            }
            throw CLIError(message: "Workspace ref not found: \(raw)")
        }

        if let raw, Int(raw) != nil {
            throw CLIError(message: "workspace: bare indexes are no longer accepted; use a UUID or short ref like workspace:2 (see list-workspaces)")
        }

        let current = try client.sendV2(method: "workspace.current")
        if let wsId = current["workspace_id"] as? String { return wsId }
        throw CLIError(message: "No workspace selected")
    }

    func resolveSurfaceId(_ raw: String?, workspaceId: String, client: SocketClient) throws -> String {
        if let raw, isUUID(raw) {
            return raw
        }
        if let raw, isHandleRef(raw) {
            let listed = try client.sendV2(method: "surface.list", params: ["workspace_id": workspaceId])
            let items = listed["surfaces"] as? [[String: Any]] ?? []
            for item in items where (item["ref"] as? String) == raw {
                if let id = item["id"] as? String { return id }
            }
            throw CLIError(message: "Surface ref not found: \(raw)")
        }

        if let raw, Int(raw) != nil {
            throw CLIError(message: "surface: bare indexes are no longer accepted; use a UUID or short ref like surface:2 (see list-pane-surfaces)")
        }

        let listed = try client.sendV2(method: "surface.list", params: ["workspace_id": workspaceId])
        let items = listed["surfaces"] as? [[String: Any]] ?? []

        if let focused = items.first(where: { ($0["focused"] as? Bool) == true }) {
            if let id = focused["id"] as? String { return id }
        }

        throw CLIError(message: "Unable to resolve surface ID")
    }

    /// Return the help/usage text for a subcommand, or nil if the command is unknown.
    private func subcommandUsage(_ command: String) -> String? {
        if let text = tmuxCompatSubcommandUsage(command) { return text }
        if let text = sshSubcommandUsage(command) { return text }
        if let text = treeSubcommandUsage(command) { return text }
        if let text = hooksSubcommandUsage(command) { return text }
        if let text = browserSubcommandUsage(command) { return text }
        if let text = markdownSubcommandUsage(command) { return text }
        if let text = themesSubcommandUsage(command) { return text }
        if let text = agentWrapperSubcommandUsage(command) { return text }
        return commandDescriptor(named: command)?.detailedUsage
    }

    /// Dispatch help for a subcommand. Returns true if help was printed.
    private func dispatchSubcommandHelp(command: String, commandArgs: [String]) -> Bool {
        guard commandArgs.contains("--help") || commandArgs.contains("-h") else { return false }
        guard let text = subcommandUsage(command) else { return false }
        print("programa \(command)")
        print("")
        print(text)
        return true
    }

    /// Escape and quote a string for safe embedding in a v1 socket command.
    /// The socket tokenizer treats `\` and `"` as special inside quoted strings,
    /// so both must be escaped before wrapping in double quotes. Newlines and
    /// carriage returns must also be escaped since the socket protocol uses
    /// newline as the message terminator.
    private func socketQuote(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return "\"\(escaped)\""
    }
    /// Shared scan loop for `parseOption`/`parseRepeatedOption`: walks `args`,
    /// collecting every value that follows `name` (honoring a `--` terminator)
    /// and returning the leftover args with those option/value pairs removed.
    private func scanOption(_ args: [String], name: String) -> ([String], [String]) {
        var remaining: [String] = []
        var values: [String] = []
        var skipNext = false
        var pastTerminator = false
        for (idx, arg) in args.enumerated() {
            if skipNext {
                skipNext = false
                continue
            }
            if arg == "--" {
                pastTerminator = true
                remaining.append(arg)
                continue
            }
            if !pastTerminator, arg == name, idx + 1 < args.count {
                values.append(args[idx + 1])
                skipNext = true
                continue
            }
            remaining.append(arg)
        }
        return (values, remaining)
    }

    func parseOption(_ args: [String], name: String) -> (String?, [String]) {
        let (values, remaining) = scanOption(args, name: name)
        return (values.last, remaining)
    }

    private func parseRepeatedOption(_ args: [String], name: String) -> ([String], [String]) {
        scanOption(args, name: name)
    }

    func optionValue(_ args: [String], name: String) -> String? {
        guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    func hasFlag(_ args: [String], name: String) -> Bool {
        args.contains(name)
    }

    private func replaceToken(_ args: [String], from: String, to: String) -> [String] {
        args.map { $0 == from ? to : $0 }
    }

    /// Unescape CLI escape sequences to match legacy v1 send behavior.
    /// \n and \r → carriage return (Enter), \t → tab.
    private func unescapeSendText(_ text: String) -> String {
        return text
            .replacingOccurrences(of: "\\n", with: "\r")
            .replacingOccurrences(of: "\\r", with: "\r")
            .replacingOccurrences(of: "\\t", with: "\t")
    }

    func workspaceFromArgsOrEnv(_ args: [String], windowOverride: String? = nil) -> String? {
        if let explicit = optionValue(args, name: "--workspace") { return explicit }
        // When --window is explicitly targeted, don't fall back to env workspace from a different window
        if windowOverride != nil { return nil }
        return ProcessInfo.processInfo.environment["PROGRAMA_WORKSPACE_ID"]
    }

    /// Validates contracts whose failures can be determined without opening
    /// the socket. Handlers retain their checks as a defensive boundary, but
    /// malformed invocations now fail before they can affect a running app.
    private func preflightFlagArguments(
        _ args: [String],
        command: String,
        valueFlags: Set<String>,
        booleanFlags: Set<String> = [],
        allowEquals: Bool
    ) throws -> (positional: [String], options: [String: String]) {
        var positional: [String] = []
        var options: [String: String] = [:]
        var pastTerminator = false
        var index = 0

        while index < args.count {
            let token = args[index]
            if pastTerminator {
                positional.append(token)
                index += 1
                continue
            }
            if token == "--" {
                pastTerminator = true
                index += 1
                continue
            }
            guard token.hasPrefix("--") else {
                positional.append(token)
                index += 1
                continue
            }

            let body = String(token.dropFirst(2))
            let parts = body.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = String(parts[0])
            let hasEqualsValue = parts.count == 2

            guard valueFlags.contains(name) || booleanFlags.contains(name) else {
                throw CLIError(message: "\(command): unknown option --\(name)")
            }
            guard options[name] == nil else {
                throw CLIError(message: "\(command): duplicate option --\(name)")
            }

            if booleanFlags.contains(name) {
                guard !hasEqualsValue else {
                    throw CLIError(message: "\(command): --\(name) does not take a value")
                }
                options[name] = "true"
                index += 1
                continue
            }

            if hasEqualsValue {
                guard allowEquals else {
                    throw CLIError(message: "\(command): unexpected option syntax --\(name)=; use --\(name) <value>")
                }
                let value = String(parts[1])
                guard !value.isEmpty else {
                    throw CLIError(message: "\(command): --\(name) requires a value")
                }
                options[name] = value
                index += 1
                continue
            }

            guard index + 1 < args.count, !args[index + 1].hasPrefix("--") else {
                throw CLIError(message: "\(command): --\(name) requires a value")
            }
            options[name] = args[index + 1]
            index += 2
        }
        return (positional, options)
    }

    /// Exhaustive grammar table for commands that use the shared registry
    /// contract. Keeping this switch total makes a newly registered command
    /// fail closed before socket acquisition until its grammar is declared.
    private func validateRegisteredArguments(_ args: [String], for command: String) throws {
        func parse(
            values: Set<String> = [],
            booleans: Set<String> = [],
            minPositionals: Int = 0,
            maxPositionals: Int? = 0,
            allowEquals: Bool = false
        ) throws -> (positional: [String], options: [String: String]) {
            let parsed = try preflightFlagArguments(
                args,
                command: command,
                valueFlags: values,
                booleanFlags: booleans,
                allowEquals: allowEquals
            )
            guard parsed.positional.count >= minPositionals else {
                throw CLIError(message: "\(command): missing required argument")
            }
            if let maxPositionals, parsed.positional.count > maxPositionals {
                throw CLIError(message: "\(command): unexpected arguments: \(parsed.positional.dropFirst(maxPositionals).joined(separator: " "))")
            }
            return parsed
        }

        func require(_ names: [String], in options: [String: String]) throws {
            for name in names where options[name] == nil {
                throw CLIError(message: "\(command): --\(name) is required")
            }
        }

        switch command {
        // Socket commands with no command-specific arguments.
        case "capabilities", "list-windows", "current-window", "new-window",
             "list-workspaces", "refresh-surfaces", "reload-config", "debug-terminals",
             "current-workspace", "list-notifications",
             "simulate-app-active":
            _ = try parse()

        case "rpc":
            let parsed = try parse(minPositionals: 1, maxPositionals: 2)
            _ = try parseRPCParams(Array(parsed.positional.dropFirst()))

        case "identify":
            _ = try parse(values: ["workspace", "surface"], booleans: ["no-caller"])

        case "focus-window", "close-window":
            let parsed = try parse(values: ["window"])
            try require(["window"], in: parsed.options)
            guard let rawWindow = parsed.options["window"], isUUID(rawWindow.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw CLIError(message: "\(command): invalid window id")
            }

        case "move-workspace-to-window":
            let parsed = try parse(values: ["workspace", "window"])
            try require(["workspace", "window"], in: parsed.options)

        case "reorder-workspace":
            let parsed = try parse(values: ["workspace", "index", "before", "after", "window"])
            try require(["workspace"], in: parsed.options)
            let anchors = ["index", "before", "after"].filter { parsed.options[$0] != nil }
            guard anchors.count == 1 else {
                throw CLIError(message: "reorder-workspace requires exactly one of --index, --before, or --after")
            }
            if let raw = parsed.options["index"], (Int(raw) ?? -1) < 0 {
                throw CLIError(message: "reorder-workspace: --index must be a nonnegative integer")
            }

        case "workspace-action":
            let parsed = try parse(values: ["action", "workspace", "title", "color", "description"], maxPositionals: nil)
            guard let rawAction = parsed.options["action"] ?? parsed.positional.first else {
                throw CLIError(message: "workspace-action requires --action <name>")
            }
            let trailing = parsed.options["action"] == nil ? Array(parsed.positional.dropFirst()) : parsed.positional
            let action = rawAction.lowercased().replacingOccurrences(of: "-", with: "_")
            if action == "rename", parsed.options["title"] == nil, trailing.isEmpty {
                throw CLIError(message: "workspace-action rename requires a title")
            }
            if action == "set_color", parsed.options["color"] == nil, trailing.isEmpty {
                throw CLIError(message: "workspace-action set-color requires a color")
            }
            if action == "set_description", parsed.options["description"] == nil, trailing.isEmpty {
                throw CLIError(message: "workspace-action set-description requires a description")
            }

        case "new-workspace":
            _ = try parse(values: ["name", "description", "cwd", "command"])

        case "new-split":
            let parsed = try parse(values: ["workspace", "surface", "panel"], minPositionals: 1, maxPositionals: 1)
            guard ["left", "right", "up", "down"].contains(parsed.positional[0].lowercased()) else {
                throw CLIError(message: "new-split: direction must be left, right, up, or down")
            }

        case "list-panes", "surface-health", "list-panels":
            _ = try parse(values: ["workspace"])

        case "list-pane-surfaces":
            _ = try parse(values: ["workspace", "pane"])

        case "focus-pane":
            let parsed = try parse(values: ["workspace", "pane"], maxPositionals: 1)
            guard parsed.options["pane"] != nil || parsed.positional.count == 1 else {
                throw CLIError(message: "focus-pane requires --pane <id|ref>")
            }
            guard !(parsed.options["pane"] != nil && !parsed.positional.isEmpty) else {
                throw CLIError(message: "focus-pane: provide the pane once")
            }

        case "new-pane":
            let parsed = try parse(values: ["type", "direction", "workspace", "url"])
            if let type = parsed.options["type"], !["terminal", "browser"].contains(type.lowercased()) {
                throw CLIError(message: "new-pane: --type must be terminal or browser")
            }
            if let direction = parsed.options["direction"], !["left", "right", "up", "down"].contains(direction.lowercased()) {
                throw CLIError(message: "new-pane: invalid direction")
            }

        case "new-surface":
            let parsed = try parse(values: ["type", "pane", "workspace", "url"])
            if let type = parsed.options["type"], !["terminal", "browser"].contains(type.lowercased()) {
                throw CLIError(message: "new-surface: --type must be terminal or browser")
            }

        case "close-surface":
            _ = try parse(values: ["surface", "panel", "workspace"])

        case "move-surface":
            let parsed = try parse(values: ["surface", "pane", "workspace", "window", "before", "before-surface", "after", "after-surface", "index", "focus"], maxPositionals: 1)
            guard parsed.options["surface"] != nil || parsed.positional.count == 1 else {
                throw CLIError(message: "move-surface requires --surface <id|ref>")
            }
            guard !(parsed.options["surface"] != nil && !parsed.positional.isEmpty) else {
                throw CLIError(message: "move-surface: provide the surface once")
            }
            if let raw = parsed.options["index"], (Int(raw) ?? -1) < 0 {
                throw CLIError(message: "move-surface: --index must be a nonnegative integer")
            }
            if let raw = parsed.options["focus"], !["true", "false", "1", "0", "yes", "no", "on", "off"].contains(raw.lowercased()) {
                throw CLIError(message: "move-surface: --focus must be true or false")
            }
            let anchors = ["index", "before", "before-surface", "after", "after-surface"].filter { parsed.options[$0] != nil }
            guard anchors.count <= 1 else {
                throw CLIError(message: "move-surface accepts only one of --index, --before, or --after")
            }

        case "reorder-surface":
            let parsed = try parse(values: ["surface", "workspace", "index", "before", "before-surface", "after", "after-surface"], maxPositionals: 1)
            guard parsed.options["surface"] != nil || parsed.positional.count == 1 else {
                throw CLIError(message: "reorder-surface requires --surface <id|ref>")
            }
            guard !(parsed.options["surface"] != nil && !parsed.positional.isEmpty) else {
                throw CLIError(message: "reorder-surface: provide the surface once")
            }
            let anchors = ["index", "before", "before-surface", "after", "after-surface"].filter { parsed.options[$0] != nil }
            guard anchors.count == 1 else {
                throw CLIError(message: "reorder-surface requires exactly one of --index, --before, or --after")
            }
            if let raw = parsed.options["index"], (Int(raw) ?? -1) < 0 {
                throw CLIError(message: "reorder-surface: --index must be a nonnegative integer")
            }

        case "tab-action":
            let parsed = try parse(values: ["action", "tab", "surface", "workspace", "title", "url"], maxPositionals: nil)
            guard parsed.options["action"] != nil || !parsed.positional.isEmpty else {
                throw CLIError(message: "tab-action requires --action <name>")
            }

        case "rename-tab":
            let parsed = try parse(values: ["workspace", "tab", "surface", "title"], maxPositionals: nil)
            guard parsed.options["title"] != nil || !parsed.positional.isEmpty else {
                throw CLIError(message: "rename-tab requires a title")
            }

        case "drag-surface-to-split":
            let parsed = try parse(values: ["surface", "panel"], minPositionals: 1, maxPositionals: 1)
            guard (parsed.options["surface"] != nil) != (parsed.options["panel"] != nil) else {
                throw CLIError(message: "drag-surface-to-split requires exactly one of --surface or --panel")
            }
            guard ["left", "right", "up", "down"].contains(parsed.positional[0].lowercased()) else {
                throw CLIError(message: "drag-surface-to-split: invalid direction")
            }

        case "trigger-flash":
            _ = try parse(values: ["workspace", "surface", "panel"])

        case "close-workspace", "select-workspace":
            let parsed = try parse(values: ["workspace"])
            if parsed.options["workspace"] == nil {
                throw CLIError(
                    message: "\(command): --workspace <id|ref> is required (UUID or short ref like workspace:2). Refusing to target the current workspace implicitly."
                )
            }

        case "rename-workspace", "rename-window":
            _ = try parse(values: ["workspace"], minPositionals: 1, maxPositionals: nil)

        case "send":
            _ = try parse(values: ["workspace", "surface"], minPositionals: 1, maxPositionals: nil)

        case "send-key":
            _ = try parse(values: ["workspace", "surface"], minPositionals: 1, maxPositionals: 1)

        case "send-panel":
            let parsed = try parse(values: ["panel", "workspace"], minPositionals: 1, maxPositionals: nil)
            try require(["panel"], in: parsed.options)

        case "send-key-panel":
            let parsed = try parse(values: ["panel", "workspace"], minPositionals: 1, maxPositionals: 1)
            try require(["panel"], in: parsed.options)

        case "notify":
            _ = try parse(values: ["title", "subtitle", "body", "workspace", "surface"])

        case "clear-notifications":
            _ = try parse(values: ["workspace"])

        case "set-status":
            let parsed = try parse(
                values: ["icon", "color", "url", "link", "priority", "format", "pid", "workspace"],
                minPositionals: 2,
                maxPositionals: nil,
                allowEquals: true
            )
            if let priority = parsed.options["priority"], Int(priority) == nil {
                throw CLIError(message: "set-status: --priority must be an integer")
            }
            if let format = parsed.options["format"], !["plain", "markdown", "md"].contains(format.lowercased()) {
                throw CLIError(message: "set-status: --format must be plain or markdown")
            }
            if let pid = parsed.options["pid"], (Int(pid) ?? 0) <= 0 {
                throw CLIError(message: "set-status: --pid must be a positive integer")
            }

        case "clear-status":
            _ = try parse(values: ["workspace"], minPositionals: 1, maxPositionals: 1, allowEquals: true)

        case "list-status", "clear-progress", "clear-log", "sidebar-state":
            _ = try parse(values: ["workspace"], allowEquals: true)

        case "log":
            let parsed = try parse(values: ["level", "source", "workspace"], minPositionals: 1, maxPositionals: nil, allowEquals: true)
            if let level = parsed.options["level"], !["info", "progress", "success", "warning", "error"].contains(level) {
                throw CLIError(message: "log: invalid --level value")
            }

        case "set-app-focus":
            let parsed = try parse(minPositionals: 1, maxPositionals: 1)
            guard ["active", "inactive", "clear", "1", "0", "true", "false", "none"].contains(parsed.positional[0].lowercased()) else {
                throw CLIError(message: "set-app-focus: invalid state")
            }

        case "tree":
            _ = try parse(values: ["workspace"], booleans: ["all"])

        case "markdown":
            let parsed = try parse(minPositionals: 1, maxPositionals: 2)
            if parsed.positional.count == 2, parsed.positional[0].lowercased() != "open" {
                throw CLIError(message: "markdown: unexpected subcommand \(parsed.positional[0])")
            }

        case "ssh":
            try validateSSHCommandArguments(args)

        case "ssh-session-end":
            let parsed = try parse(values: ["relay-port", "workspace", "surface"])
            try require(["relay-port"], in: parsed.options)
            guard let rawPort = parsed.options["relay-port"], let port = Int(rawPort), port > 0, port <= 65535 else {
                throw CLIError(message: "ssh-session-end: --relay-port must be 1-65535")
            }
            if parsed.options["workspace"] == nil,
               ProcessInfo.processInfo.environment["PROGRAMA_WORKSPACE_ID"] == nil {
                throw CLIError(message: "ssh-session-end requires --workspace or PROGRAMA_WORKSPACE_ID")
            }
            if parsed.options["surface"] == nil,
               ProcessInfo.processInfo.environment["PROGRAMA_SURFACE_ID"] == nil {
                throw CLIError(message: "ssh-session-end requires --surface or PROGRAMA_SURFACE_ID")
            }

        case "claude-hook":
            let parsed = try parse(values: ["workspace", "surface"], maxPositionals: 1)
            if let subcommand = parsed.positional.first?.lowercased(),
               !["session-start", "active", "stop", "idle", "prompt-submit", "notification", "notify", "session-end", "pre-tool-use", "help", "--help", "-h"].contains(subcommand) {
                throw CLIError(message: "claude-hook: unknown event \(subcommand)")
            }

        case "codex-hook":
            guard ProcessInfo.processInfo.environment["PROGRAMA_SURFACE_ID"] != nil else { return }
            let parsed = try parse(values: ["workspace", "surface"], maxPositionals: 1)
            if let subcommand = parsed.positional.first?.lowercased(),
               !["session-start", "prompt-submit", "stop", "notification", "notify", "session-end", "help", "--help", "-h"].contains(subcommand) {
                throw CLIError(message: "codex-hook: unknown event \(subcommand)")
            }

        case "opencode-hook":
            guard ProcessInfo.processInfo.environment["PROGRAMA_SURFACE_ID"] != nil else { return }
            let parsed = try parse(values: ["workspace", "surface", "cwd", "session"], maxPositionals: 1)
            if let subcommand = parsed.positional.first?.lowercased(),
               !["session-start", "prompt-submit", "stop", "notification", "notify", "session-end", "help", "--help", "-h"].contains(subcommand) {
                throw CLIError(message: "opencode-hook: unknown event \(subcommand)")
            }

        case "capture-pane":
            let parsed = try parse(values: ["workspace", "surface", "lines"], booleans: ["scrollback"])
            if let lines = parsed.options["lines"], (Int(lines) ?? 0) <= 0 {
                throw CLIError(message: "capture-pane: --lines must be greater than 0")
            }
        case "resize-pane":
            let parsed = try parse(values: ["pane", "workspace", "amount"], minPositionals: 1, maxPositionals: 1)
            try require(["pane"], in: parsed.options)
            guard ["-L", "-R", "-U", "-D"].contains(parsed.positional[0]) else {
                throw CLIError(message: "resize-pane requires -L, -R, -U, or -D")
            }
            if let amount = parsed.options["amount"], (Int(amount) ?? 0) <= 0 {
                throw CLIError(message: "resize-pane: --amount must be greater than 0")
            }
        case "pipe-pane":
            let parsed = try parse(values: ["command", "workspace", "surface"], maxPositionals: nil)
            guard parsed.options["command"] != nil || !parsed.positional.isEmpty else {
                throw CLIError(message: "pipe-pane requires --command <shell-command>")
            }
        case "wait-for":
            let parsed = try parse(values: ["timeout"], booleans: ["signal"], minPositionals: 1, maxPositionals: 2)
            let positionals = parsed.positional.filter { $0 != "-S" }
            guard positionals.count == 1 else { throw CLIError(message: "wait-for requires one name") }
            if let timeout = parsed.options["timeout"] {
                guard let seconds = Double(timeout), seconds.isFinite, seconds >= 0 else {
                    throw CLIError(message: "wait-for: --timeout must be finite and nonnegative")
                }
            }
        case "swap-pane":
            let parsed = try parse(values: ["pane", "target-pane", "workspace"])
            try require(["pane", "target-pane"], in: parsed.options)
        case "break-pane":
            _ = try parse(values: ["workspace", "pane", "surface"], booleans: ["no-focus"])
        case "join-pane":
            let parsed = try parse(values: ["target-pane", "workspace", "pane", "surface"], booleans: ["no-focus"])
            try require(["target-pane"], in: parsed.options)
        case "next-window", "previous-window", "last-window", "list-buffers":
            _ = try parse()
        case "last-pane":
            _ = try parse(values: ["workspace"])
        case "find-window":
            _ = try parse(booleans: ["content", "select"], minPositionals: 1, maxPositionals: nil)
        case "clear-history":
            _ = try parse(values: ["workspace", "surface"])
        case "set-hook":
            let parsed = try parse(values: ["unset"], booleans: ["list"], maxPositionals: nil)
            if parsed.options["list"] == nil, parsed.options["unset"] == nil, parsed.positional.count < 2 {
                throw CLIError(message: "set-hook requires <event> <command>")
            }
        case "popup", "bind-key", "unbind-key", "copy-mode":
            throw CLIError(message: "\(command) is not supported yet in programa CLI parity mode")
        case "set-buffer":
            _ = try parse(values: ["name"], minPositionals: 1, maxPositionals: nil)
        case "paste-buffer":
            _ = try parse(values: ["name", "workspace", "surface"])
        case "respawn-pane":
            _ = try parse(values: ["workspace", "surface", "command"])
        case "display-message":
            let parsed = try parse(booleans: ["print"], minPositionals: 1, maxPositionals: nil)
            guard parsed.positional.filter({ $0 != "-p" }).isEmpty == false else {
                throw CLIError(message: "display-message requires text")
            }

        // These commands own nested or foreign grammars. Their handlers do
        // full parsing; flags must remain byte-for-byte passthrough here.
        case "__tmux-compat",
             "browser", "open-browser",
             "navigate", "browser-back", "browser-forward", "browser-reload", "get-url",
             "focus-webview", "is-webview-focused":
            return

        // Local commands are registered for unified lookup/help, but do not
        // acquire the app socket through the generic dispatcher.
        case "welcome", "version", "help":
            _ = try parse()
        case "shortcuts", "feedback", "themes", "claude-teams", "omo", "omx", "omc":
            return
        case "codex":
            let parsed = try parse(booleans: ["yes", "y"], minPositionals: 1, maxPositionals: 1)
            guard ["install-hooks", "uninstall-hooks", "install-integration", "uninstall-integration"].contains(parsed.positional[0].lowercased()) else {
                throw CLIError(message: "codex: expected install-integration or uninstall-integration")
            }
        case "claude":
            let parsed = try parse(booleans: ["yes", "y"], minPositionals: 1, maxPositionals: 1)
            guard ["install-integration", "uninstall-integration"].contains(parsed.positional[0].lowercased()) else {
                throw CLIError(message: "claude: expected install-integration or uninstall-integration")
            }
        case "opencode":
            let parsed = try parse(booleans: ["yes", "y"], minPositionals: 1, maxPositionals: 1)
            guard ["install-integration", "uninstall-integration"].contains(parsed.positional[0].lowercased()) else {
                throw CLIError(message: "opencode: expected install-integration or uninstall-integration")
            }
        case "remote-daemon-status":
            let parsed = try parse(values: ["os", "arch"])
            if let os = parsed.options["os"], !["darwin", "linux"].contains(os.lowercased()) {
                throw CLIError(message: "remote-daemon-status: unsupported --os value")
            }
            if let arch = parsed.options["arch"], !["arm64", "amd64"].contains(arch.lowercased()) {
                throw CLIError(message: "remote-daemon-status: unsupported --arch value")
            }

        // Commands with richer bespoke contracts are validated by their
        // dedicated cases in `validateArguments`.
        case "ping", "focus-panel", "read-screen", "wait-surface", "set-progress", "list-log":
            return

        default:
            throw CLIError(message: "Internal CLI registry error: no argument contract for \(command)")
        }
    }

    private func validateArguments(
        _ args: [String],
        for command: String,
        contract: CLICommandArgumentContract
    ) throws {
        switch contract {
        case .registered:
            try validateRegisteredArguments(args, for: command)

        case .noArguments:
            guard args.isEmpty else {
                throw CLIError(message: "\(command): unexpected arguments: \(args.joined(separator: " "))")
            }

        case .focusPanel:
            let parsed = try preflightFlagArguments(
                args,
                command: command,
                valueFlags: ["panel", "workspace"],
                allowEquals: false
            )
            guard parsed.positional.isEmpty else {
                throw CLIError(message: "focus-panel: unexpected arguments: \(parsed.positional.joined(separator: " "))")
            }
            guard parsed.options["panel"] != nil else {
                throw CLIError(message: "focus-panel requires --panel <id|ref>")
            }

        case .readScreen:
            let parsed = try preflightFlagArguments(
                args,
                command: command,
                valueFlags: ["workspace", "surface", "lines"],
                booleanFlags: ["scrollback"],
                allowEquals: false
            )
            guard parsed.positional.isEmpty else {
                throw CLIError(message: "read-screen: unexpected arguments: \(parsed.positional.joined(separator: " "))")
            }
            if let lines = parsed.options["lines"] {
                guard let count = Int(lines), count > 0 else {
                    throw CLIError(message: "read-screen: --lines must be greater than 0")
                }
            }

        case .waitSurface:
            let parsed = try preflightFlagArguments(
                args,
                command: command,
                valueFlags: ["workspace", "surface", "pattern", "timeout", "lines"],
                booleanFlags: ["exit"],
                allowEquals: false
            )
            guard parsed.positional.isEmpty else {
                throw CLIError(message: "wait-surface: unexpected arguments: \(parsed.positional.joined(separator: " "))")
            }
            guard (parsed.options["pattern"] != nil) != (parsed.options["exit"] != nil) else {
                throw CLIError(message: "wait-surface requires exactly one of --pattern <regex> or --exit")
            }
            if let timeout = parsed.options["timeout"] {
                guard let seconds = Double(timeout), seconds.isFinite, seconds > 0 else {
                    throw CLIError(message: "wait-surface: --timeout must be a positive number of seconds")
                }
            }
            if let lines = parsed.options["lines"] {
                guard let count = Int(lines), count > 0 else {
                    throw CLIError(message: "wait-surface: --lines must be greater than 0")
                }
            }

        case .setProgress:
            let parsed = try preflightFlagArguments(
                args,
                command: command,
                valueFlags: ["label", "workspace"],
                allowEquals: true
            )
            guard parsed.positional.count == 1, let rawValue = parsed.positional.first else {
                throw CLIError(message: "set-progress requires a progress value")
            }
            guard let value = Double(rawValue), value.isFinite, (0.0...1.0).contains(value) else {
                throw CLIError(message: "set-progress: invalid progress value '\(rawValue)'; must be between 0.0 and 1.0")
            }

        case .listLog:
            let parsed = try preflightFlagArguments(
                args,
                command: command,
                valueFlags: ["limit", "workspace"],
                allowEquals: true
            )
            guard parsed.positional.isEmpty else {
                throw CLIError(message: "list-log: unexpected arguments: \(parsed.positional.joined(separator: " "))")
            }
            if let rawLimit = parsed.options["limit"] {
                guard let limit = Int(rawLimit), limit >= 0 else {
                    throw CLIError(message: "list-log: invalid limit '\(rawLimit)'; must be >= 0")
                }
            }
        }
    }

    /// Parses CLI-style flags (`--name value` or `--name=value`) into positional args + an
    /// options dict, mirroring the v1 server-side `parseOptions`/`parseOptionsNoStop` grammar
    /// so v2-backed sidebar commands can rebuild the same structured params client-side.
    /// `stopAtDashDash: true` matches `parseOptions` (a bare `--` ends flag parsing, remaining
    /// tokens are positional); `false` matches `parseOptionsNoStop` (a bare `--` is skipped,
    /// used by `report_meta_block`-style commands where `--` separates key/options from markdown
    /// body but the caller already split that out).
    private func parseFlagArgs(_ args: [String], stopAtDashDash: Bool = true) -> (positional: [String], options: [String: String]) {
        var positional: [String] = []
        var options: [String: String] = [:]
        var stopParsingOptions = false
        var i = 0
        while i < args.count {
            let token = args[i]
            if stopParsingOptions {
                positional.append(token)
            } else if token == "--" {
                if stopAtDashDash {
                    stopParsingOptions = true
                }
            } else if token.hasPrefix("--") {
                if let eqIndex = token.firstIndex(of: "=") {
                    let key = String(token[token.index(token.startIndex, offsetBy: 2)..<eqIndex])
                    let value = String(token[token.index(after: eqIndex)...])
                    options[key] = value
                } else {
                    let key = String(token.dropFirst(2))
                    if i + 1 < args.count, !args[i + 1].hasPrefix("--") {
                        options[key] = args[i + 1]
                        i += 1
                    } else {
                        options[key] = ""
                    }
                }
            } else {
                positional.append(token)
            }
            i += 1
        }
        return (positional, options)
    }

    private func normalizedFlagValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Resolves the target workspace for a sidebar-metadata command: explicit `--workspace`
    /// flag, else `$PROGRAMA_WORKSPACE_ID` (unless a `--window` override is active), else the
    /// server's currently-selected workspace (mirrors v1's `resolveTabForReport`/
    /// `parseSidebarMutationTabTarget` fallback to `tabManager.selectedTabId`).
    private func resolveSidebarWorkspaceId(
        options: [String: String],
        windowOverride: String?,
        client: SocketClient
    ) throws -> String {
        let raw = options["workspace"] ?? (windowOverride == nil ? ProcessInfo.processInfo.environment["PROGRAMA_WORKSPACE_ID"] : nil)
        return try resolveWorkspaceId(raw, client: client)
    }

    /// Rebuilds v1's `key=value icon=X color=Y url=Z priority=N format=X` status-entry line
    /// from a `workspace.set_status`/`list_status`/`sidebar_state` v2 entry dict.
    private func sidebarMetadataLineText(_ entry: [String: Any]) -> String {
        let key = (entry["key"] as? String) ?? ""
        let value = (entry["value"] as? String) ?? ""
        var line = "\(key)=\(value)"
        if let icon = entry["icon"] as? String { line += " icon=\(icon)" }
        if let color = entry["color"] as? String { line += " color=\(color)" }
        if let url = entry["url"] as? String { line += " url=\(url)" }
        if let priority = intFromAny(entry["priority"]), priority != 0 { line += " priority=\(priority)" }
        if let format = entry["format"] as? String, format != "plain" { line += " format=\(format)" }
        return line
    }

    /// Rebuilds v1's `key=markdown priority=N` metadata-block line from a `sidebar_state`
    /// v2 `metadata_blocks` entry dict.
    private func sidebarMetadataBlockLineText(_ block: [String: Any]) -> String {
        let key = (block["key"] as? String) ?? ""
        let markdown = ((block["markdown"] as? String) ?? "").replacingOccurrences(of: "\n", with: "\\n")
        var line = "\(key)=\(markdown)"
        if let priority = intFromAny(block["priority"]), priority != 0 { line += " priority=\(priority)" }
        return line
    }

    /// Rebuilds v1's `[level] message` (optionally `[source] [level] message`) log line from
    /// a `workspace.list_log` v2 entry dict.
    private func sidebarLogLineText(_ entry: [String: Any]) -> String {
        let level = (entry["level"] as? String) ?? "info"
        let message = (entry["message"] as? String) ?? ""
        var line = "[\(level)] \(message)"
        if let source = entry["source"] as? String, !source.isEmpty {
            line = "[\(source)] \(line)"
        }
        return line
    }

    /// Rebuilds v1's `sidebar_state` multi-line text dump from a `workspace.sidebar_state`
    /// v2 payload. Field-for-field mirror of `TerminalController.sidebarState(_:)`.
    private func sidebarStateText(_ payload: [String: Any]) -> String {
        var lines: [String] = []
        lines.append("tab=\((payload["workspace_id"] as? String) ?? "")")
        lines.append("color=\((payload["color"] as? String) ?? "none")")
        lines.append("cwd=\((payload["cwd"] as? String) ?? "")")

        if let focusedCwd = payload["focused_cwd"] as? String {
            lines.append("focused_cwd=\(focusedCwd)")
            lines.append("focused_panel=\((payload["focused_surface_id"] as? String) ?? "unknown")")
        } else {
            lines.append("focused_cwd=unknown")
            lines.append("focused_panel=unknown")
        }

        if let git = payload["git_branch"] as? [String: Any], let branch = git["branch"] as? String {
            let dirty = (git["dirty"] as? Bool) ?? false
            lines.append("git_branch=\(branch)\(dirty ? " dirty" : " clean")")
        } else {
            lines.append("git_branch=none")
        }

        if let pr = payload["pull_request"] as? [String: Any],
           let number = intFromAny(pr["number"]),
           let status = pr["state"] as? String,
           let url = pr["url"] as? String {
            lines.append("pr=#\(number) \(status) \(url)")
            lines.append("pr_label=\((pr["label"] as? String) ?? "")")
            lines.append("pr_checks=\((pr["checks"] as? String) ?? "none")")
        } else {
            lines.append("pr=none")
            lines.append("pr_label=none")
            lines.append("pr_checks=none")
        }

        let ports = (payload["ports"] as? [Any])?.compactMap { intFromAny($0) } ?? []
        if ports.isEmpty {
            lines.append("ports=none")
        } else {
            lines.append("ports=\(ports.map(String.init).joined(separator: ","))")
        }

        if let progress = payload["progress"] as? [String: Any], let value = doubleFromAny(progress["value"]) {
            let label = (progress["label"] as? String) ?? ""
            lines.append("progress=\(String(format: "%.2f", value)) \(label)".trimmingCharacters(in: .whitespaces))
        } else {
            lines.append("progress=none")
        }

        let statusEntries = payload["status_entries"] as? [[String: Any]] ?? []
        lines.append("status_count=\(statusEntries.count)")
        for entry in statusEntries {
            lines.append("  \(sidebarMetadataLineText(entry))")
        }

        let metadataBlocks = payload["metadata_blocks"] as? [[String: Any]] ?? []
        lines.append("meta_block_count=\(metadataBlocks.count)")
        for block in metadataBlocks {
            lines.append("  \(sidebarMetadataBlockLineText(block))")
        }

        lines.append("log_count=\(intFromAny(payload["log_count"]) ?? 0)")
        let recentLogEntries = payload["recent_log_entries"] as? [[String: Any]] ?? []
        for entry in recentLogEntries {
            let level = (entry["level"] as? String) ?? "info"
            let message = (entry["message"] as? String) ?? ""
            lines.append("  [\(level)] \(message)")
        }

        return lines.joined(separator: "\n")
    }

    /// Pick the display handle for an item dict based on --id-format.
    func textHandle(_ item: [String: Any], idFormat: CLIIDFormat) -> String {
        let ref = item["ref"] as? String
        let id = item["id"] as? String
        switch idFormat {
        case .refs:  return ref ?? id ?? "?"
        case .uuids: return id ?? ref ?? "?"
        case .both:  return [ref, id].compactMap({ $0 }).joined(separator: " ")
        }
    }

    func v2OKSummary(_ payload: [String: Any], idFormat: CLIIDFormat, kinds: [String] = ["surface", "workspace"]) -> String {
        var parts = ["OK"]
        for kind in kinds {
            if let handle = formatHandle(payload, kind: kind, idFormat: idFormat) {
                parts.append(handle)
            }
        }
        return parts.joined(separator: " ")
    }

    func isUUID(_ value: String) -> Bool {
        return UUID(uuidString: value) != nil
    }

    func jsonString(_ object: Any) -> String {
        var options: JSONSerialization.WritingOptions = [.prettyPrinted]
        options.insert(.withoutEscapingSlashes)
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: options),
              let output = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return output
    }

    private func parseRPCParams(_ args: [String]) throws -> [String: Any] {
        guard !args.isEmpty else { return [:] }
        let raw = args.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return [:] }
        guard let data = raw.data(using: .utf8) else {
            throw CLIError(message: "rpc params must be valid UTF-8 JSON")
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw CLIError(message: "rpc params must be valid JSON: \(error.localizedDescription)")
        }
        guard let params = object as? [String: Any] else {
            throw CLIError(message: "rpc params must be a JSON object")
        }
        return params
    }

    private func versionSummary() -> String {
        let info = resolvedVersionInfo()
        let commit = info["ProgramaCommit"].flatMap { normalizedCommitHash($0) }
        let baseSummary: String
        if let version = info["CFBundleShortVersionString"], let build = info["CFBundleVersion"] {
            baseSummary = "programa \(version) (\(build))"
        } else if let version = info["CFBundleShortVersionString"] {
            baseSummary = "programa \(version)"
        } else if let build = info["CFBundleVersion"] {
            baseSummary = "programa build \(build)"
        } else {
            baseSummary = "programa version unknown"
        }
        guard let commit else { return baseSummary }
        return "\(baseSummary) [\(commit)]"
    }

    private func printWelcome() {
        let reset = "\u{001B}[0m"
        let bold = "\u{001B}[1m"
        func trueColor(_ red: Int, _ green: Int, _ blue: Int) -> String {
            "\u{001B}[38;2;\(red);\(green);\(blue)m"
        }

        let isDark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"

        // Row colors, light → dark red (develop gradient), plus the accent cursor cell.
        let r1: String, r2: String, r3: String, r4: String, cursor: String
        // Wordmark letter ramp (8 letters).
        let w: [String]
        let tagline: String
        let subdued: String

        if isDark {
            r1 = trueColor(255, 107, 82)   // #FF6B52
            r2 = trueColor(240, 64, 42)    // #F0402A
            r3 = trueColor(220, 46, 30)    // #DC2E1E
            r4 = trueColor(194, 31, 22)    // #C21F16
            cursor = trueColor(255, 138, 102) // #FF8A66
            w = [trueColor(255, 107, 82), trueColor(248, 90, 62), trueColor(240, 74, 46),
                 trueColor(230, 60, 36), trueColor(220, 46, 30), trueColor(210, 38, 26),
                 trueColor(194, 31, 22), trueColor(194, 31, 22)]
            tagline = trueColor(140, 130, 136)
            subdued = "\u{001B}[2m"
        } else {
            r1 = trueColor(232, 68, 46)    // #E8442E
            r2 = trueColor(212, 47, 31)    // #D42F1F
            r3 = trueColor(194, 31, 22)    // #C21F16
            r4 = trueColor(162, 24, 17)    // #A21811
            cursor = trueColor(232, 68, 46) // #E8442E
            w = [trueColor(232, 68, 46), trueColor(222, 56, 38), trueColor(212, 47, 31),
                 trueColor(202, 39, 26), trueColor(194, 31, 22), trueColor(178, 27, 19),
                 trueColor(162, 24, 17), trueColor(162, 24, 17)]
            tagline = trueColor(90, 90, 98)
            subdued = trueColor(100, 100, 108)
        }

        let wordmark = "\(w[0])p\(w[1])r\(w[2])o\(w[3])g\(w[4])r\(w[5])a\(w[6])m\(w[7])a\(reset)"

        // Shade-ramp cells are doubled so they stay square in 1:2 terminal cells.
        let logo = """
        \(r1)\u{2596}\u{2596} \u{2591}\u{2591} \u{2592}\u{2592} \u{2593}\u{2593}\(reset)        \(wordmark)
        \(r2)\u{2591}\u{2591} \u{2592}\u{2592} \u{2593}\u{2593} \u{2588}\u{2588}\(reset)
        \(r3)\u{2592}\u{2592} \u{2593}\u{2593} \u{2588}\u{2588} \u{2588}\u{2588}\(reset)        \(tagline)the open source terminal\(reset)
        \(r4)\u{2593}\u{2593} \u{2588}\u{2588} \u{2588}\u{2588} \(cursor)\u{2588}\u{2588}\(reset)        \(tagline)built for coding agents\(reset)
        """

        let shortcuts = """
          \(bold)Shortcuts\(reset)

          \(bold)\u{2318}N\(reset)\(subdued)                  New workspace\(reset)
          \(bold)\u{2318}T\(reset)\(subdued)                  New tab\(reset)
          \(bold)\u{2318}P\(reset)\(subdued)                  Go to workspace\(reset)
          \(bold)\u{2318}D\(reset)\(subdued)                  Split right\(reset)
          \(bold)\u{2318}\u{21E7}D\(reset)\(subdued)                 Split down\(reset)
          \(bold)\u{2318}\u{21E7}P\(reset)\(subdued)                 Command palette\(reset)
          \(bold)\u{2318}\u{21E7}R\(reset)\(subdued)                 Rename workspace\(reset)
          \(bold)\u{2318}\u{21E7}L\(reset)\(subdued)                 New browser\(reset)
          \(bold)\u{2318}\u{21E7}U\(reset)\(subdued)                 Jump to latest unread\(reset)
        """

        print()
        print(logo)
        print()
        print(shortcuts)
        print()
        print("  \(bold)Docs\(reset)\(subdued)                https://github.com/darkroomengineering/programa/tree/main/docs\(reset)")
        print("  \(bold)Discord\(reset)\(subdued)             https://discord.gg/xsgFEVrWCZ\(reset)")
        print("  \(bold)GitHub\(reset)\(subdued)              https://github.com/darkroomengineering/programa (please leave a star ⭐)\(reset)")
        print("  \(bold)Issues\(reset)\(subdued)              https://github.com/darkroomengineering/programa/issues\(reset)")
        print()
        print("  \(subdued)Run \(reset)\(bold)programa --help\(reset)\(subdued) for all commands.\(reset)")
        print("  \(subdued)Run \(reset)\(bold)programa shortcuts\(reset)\(subdued) to edit shortcuts.\(reset)")
        print("  \(subdued)Run \(reset)\(bold)programa feedback\(reset)\(subdued) to report a bug.\(reset)")
        print()
    }

    func resolvedVersionInfo() -> [String: String] {
        var info: [String: String] = [:]
        if let main = versionInfo(from: Bundle.main.infoDictionary) {
            info.merge(main, uniquingKeysWith: { current, _ in current })
        }

        let needsPlistFallback =
            info["CFBundleShortVersionString"] == nil ||
            info["CFBundleVersion"] == nil ||
            info["ProgramaCommit"] == nil
        if needsPlistFallback {
            for plistURL in candidateInfoPlistURLs() {
                guard let data = try? Data(contentsOf: plistURL),
                      let raw = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
                      let dictionary = raw as? [String: Any],
                      let parsed = versionInfo(from: dictionary)
                else {
                    continue
                }
                info.merge(parsed, uniquingKeysWith: { current, _ in current })
                if info["CFBundleShortVersionString"] != nil,
                   info["CFBundleVersion"] != nil,
                   info["ProgramaCommit"] != nil {
                    break
                }
            }
        }

        let needsProjectFallback =
            info["CFBundleShortVersionString"] == nil ||
            info["CFBundleVersion"] == nil ||
            info["ProgramaCommit"] == nil
        if needsProjectFallback, let fromProject = versionInfoFromProjectFile() {
            info.merge(fromProject, uniquingKeysWith: { current, _ in current })
        }

        if info["ProgramaCommit"] == nil,
           let commit = normalizedCommitHash(ProcessInfo.processInfo.environment["PROGRAMA_COMMIT"]) {
            info["ProgramaCommit"] = commit
        }

        return info
    }

    private func versionInfo(from dictionary: [String: Any]?) -> [String: String]? {
        guard let dictionary else { return nil }

        var info: [String: String] = [:]
        if let version = dictionary["CFBundleShortVersionString"] as? String {
            let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && !trimmed.contains("$(") {
                info["CFBundleShortVersionString"] = trimmed
            }
        }
        if let build = dictionary["CFBundleVersion"] as? String {
            let trimmed = build.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && !trimmed.contains("$(") {
                info["CFBundleVersion"] = trimmed
            }
        }
        if let commit = dictionary["ProgramaCommit"] as? String,
           let normalizedCommit = normalizedCommitHash(commit) {
            info["ProgramaCommit"] = normalizedCommit
        }
        return info.isEmpty ? nil : info
    }

    private func versionInfoFromProjectFile() -> [String: String]? {
        guard let executableURL = resolvedExecutableURL() else {
            return nil
        }

        let fileManager = FileManager.default
        var current = executableURL.deletingLastPathComponent().standardizedFileURL

        while true {
            let projectFile = current.appendingPathComponent("GhosttyTabs.xcodeproj/project.pbxproj")
            if fileManager.fileExists(atPath: projectFile.path),
               let contents = try? String(contentsOf: projectFile, encoding: .utf8) {
                var info: [String: String] = [:]
                if let version = firstProjectSetting("MARKETING_VERSION", in: contents) {
                    info["CFBundleShortVersionString"] = version
                }
                if let build = firstProjectSetting("CURRENT_PROJECT_VERSION", in: contents) {
                    info["CFBundleVersion"] = build
                }
                if let commit = gitCommitHash(at: current) {
                    info["ProgramaCommit"] = commit
                }
                if !info.isEmpty {
                    return info
                }
            }

            guard let parent = parentSearchURL(for: current) else {
                break
            }
            current = parent
        }

        return nil
    }

    private func firstProjectSetting(_ key: String, in source: String) -> String? {
        let pattern = NSRegularExpression.escapedPattern(for: key) + "\\s*=\\s*([^;]+);"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let searchRange = NSRange(source.startIndex..<source.endIndex, in: source)
        guard let match = regex.firstMatch(in: source, options: [], range: searchRange),
              match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: source)
        else {
            return nil
        }
        let value = source[valueRange]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        guard !value.isEmpty, !value.contains("$(") else {
            return nil
        }
        return value
    }

    private func gitCommitHash(at directory: URL) -> String? {
        let process = Process()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", directory.path, "rev-parse", "--short=9", "HEAD"]
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return nil
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else {
            return nil
        }
        return normalizedCommitHash(output)
    }

    private func normalizedCommitHash(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("$(") else {
            return nil
        }
        let normalized = trimmed.lowercased()
        let allowed = CharacterSet(charactersIn: "0123456789abcdef")
        guard normalized.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return nil
        }
        return String(normalized.prefix(12))
    }

    // Foundation can walk past "/" into "/.." when repeatedly deleting path
    // components, so stop once the canonical root is reached.
    func parentSearchURL(for url: URL) -> URL? {
        let standardized = url.standardizedFileURL
        let path = standardized.path
        guard !path.isEmpty, path != "/" else {
            return nil
        }

        let parent = standardized.deletingLastPathComponent().standardizedFileURL
        guard parent.path != path else {
            return nil
        }
        return parent
    }

    func candidateInfoPlistURLs() -> [URL] {
        guard let executableURL = resolvedExecutableURL() else {
            return []
        }

        let fileManager = FileManager.default

        var candidates: [URL] = []
        var seen: Set<String> = []
        func appendIfExisting(_ url: URL) {
            let path = url.path
            guard !path.isEmpty else { return }
            guard seen.insert(path).inserted else { return }
            guard fileManager.fileExists(atPath: path) else { return }
            candidates.append(url)
        }

        var current = executableURL.deletingLastPathComponent().standardizedFileURL
        while true {
            if current.pathExtension == "app" {
                appendIfExisting(current.appendingPathComponent("Contents/Info.plist"))
            }
            if current.lastPathComponent == "Contents" {
                appendIfExisting(current.appendingPathComponent("Info.plist"))
            }

            let projectMarker = current.appendingPathComponent("GhosttyTabs.xcodeproj/project.pbxproj")
            let repoInfo = current.appendingPathComponent("Resources/Info.plist")
            if fileManager.fileExists(atPath: projectMarker.path),
               fileManager.fileExists(atPath: repoInfo.path) {
                appendIfExisting(repoInfo)
                break
            }

            guard let parent = parentSearchURL(for: current) else {
                break
            }
            current = parent
        }

        // If we already found an ancestor bundle or repo Info.plist, avoid scanning
        // sibling app bundles. Large Resources directories can otherwise balloon RSS.
        guard candidates.isEmpty else {
            return candidates
        }

        let searchRoots = [
            executableURL.deletingLastPathComponent().standardizedFileURL,
            executableURL.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL
        ]
        for root in searchRoots {
            guard let entries = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants],
                errorHandler: { _, _ in true }
            ) else {
                continue
            }
            for case let entry as URL in entries where entry.pathExtension == "app" {
                appendIfExisting(entry.appendingPathComponent("Contents/Info.plist"))
            }
        }

        return candidates
    }

    private func currentExecutablePath() -> String? {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        if size > 0 {
            var buffer = Array<CChar>(repeating: 0, count: Int(size))
            if _NSGetExecutablePath(&buffer, &size) == 0 {
                let path = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
                if !path.isEmpty {
                    return path
                }
            }
        }
        return Bundle.main.executableURL?.path ?? args.first
    }

    func resolvedExecutableURL() -> URL? {
        guard let executable = currentExecutablePath(), !executable.isEmpty else {
            return nil
        }

        let expanded = (executable as NSString).expandingTildeInPath
        if let resolvedPath = realpath(expanded, nil) {
            defer { free(resolvedPath) }
            return URL(fileURLWithPath: String(cString: resolvedPath)).standardizedFileURL
        }

        return URL(fileURLWithPath: expanded).standardizedFileURL
    }

    /// The `Commands:` section body, generated from `commandDescriptors()` so
    /// it can never drift from what the dispatcher actually knows about.
    /// See `CommandDescriptor` for why this is the single source of truth.
    private func commandsHelpBlock() -> String {
        commandDescriptors()
            .flatMap { $0.helpLines }
            .map { $0.isEmpty ? "" : "  " + $0 }
            .joined(separator: "\n")
    }

    private func usage() -> String {
        return """
        programa - control programa via Unix socket

        Usage:
          programa <path>                Open a directory in a new workspace (launches programa if needed)
          programa [global-options] <command> [options]

        Handle Inputs:
          Use UUIDs or short refs (window:1/workspace:2/pane:3/surface:4) where commands accept window, workspace, pane, or surface inputs.
          `tab-action` also accepts `tab:<n>` in addition to `surface:<n>`.
          Output defaults to refs; pass --id-format uuids or --id-format both to include UUIDs.

        Socket Auth:
          --password takes precedence, then PROGRAMA_SOCKET_PASSWORD env var, then password saved in Settings.

        Commands:
        \(commandsHelpBlock())

        Environment:
          PROGRAMA_WORKSPACE_ID   Auto-set in programa terminals. Used as default --workspace for
                              ALL commands (send, list-panels, new-split, notify, etc.).
          PROGRAMA_TAB_ID         Optional alias used by `tab-action`/`rename-tab` as default --tab.
          PROGRAMA_SURFACE_ID     Auto-set in programa terminals. Used as default --surface.
          PROGRAMA_SOCKET_PATH    Override the Unix socket path. Without this, the CLI defaults
                              to ~/Library/Application Support/programa/programa.sock and auto-discovers tagged/debug sockets.
        """
    }

#if DEBUG
    func debugUsageTextForTesting() -> String {
        usage()
    }

    func debugFormatDebugTerminalsPayloadForTesting(
        _ payload: [String: Any],
        idFormat: CLIIDFormat = .refs
    ) -> String {
        formatDebugTerminalsPayload(payload, idFormat: idFormat)
    }
#endif
}

@main
struct CMUXTermMain {
    static func main() {
        // CLI tools should ignore SIGPIPE so closed stdout pipes do not terminate the process.
        _ = signal(SIGPIPE, SIG_IGN)
        let cli = ProgramaCLI(args: CommandLine.arguments)
        do {
            try cli.run()
        } catch {
            FileHandle.standardError.write(Data("Error: \(error)\n".utf8))
            exit(1)
        }
    }
}
