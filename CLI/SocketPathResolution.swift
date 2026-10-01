import Foundation
import Darwin

/// Programa control-socket path resolution, shared between `programa-cli`
/// (`CLI/programa.swift`) and the MCP sidecar (`CLI-MCP/MCPSocketBridge.swift`).
///
/// This file is compiled into BOTH the `programa-cli` and `programa-mcp`
/// Xcode targets (see `GhosttyTabs.xcodeproj/project.pbxproj`'s Sources build
/// phases for each target) rather than being duplicated, so the two clients'
/// socket-discovery logic cannot drift apart.

enum CLISocketPathSource {
    case explicitFlag
    case environment
    case implicitDefault
}

/// Checks applied by every client before and after it connects to a control socket.
enum CLISocketSafety {
    enum PathCheck: Equatable {
        case ok
        case missing(errno: Int32)
        case symlink
        case notSocket
        case foreignOwner
    }

    /// Uses `lstat`, so a symlink planted at the socket path is rejected instead of followed.
    static func checkPath(_ path: String) -> PathCheck {
        var st = stat()
        guard lstat(path, &st) == 0 else { return .missing(errno: errno) }
        let type = st.st_mode & mode_t(S_IFMT)
        if type == mode_t(S_IFLNK) { return .symlink }
        guard type == mode_t(S_IFSOCK) else { return .notSocket }
        guard st.st_uid == getuid() else { return .foreignOwner }
        return .ok
    }

    /// True when the process on the other end of the connected socket runs as the current user.
    static func peerUIDMatchesCurrentUser(fd: Int32) -> Bool {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0 else { return false }
        return uid == geteuid()
    }
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

        // Never auto-select another live instance (a tagged dev build, staging, the last
        // socket some build wrote): a command meant for the user's app would silently land
        // in that one. Name them so the caller can opt in explicitly.
        let others = dedupe([fallbackSocketPath, stagingSocketPath] + discoverTaggedSockets(limit: 12) + [readLastSocketPath()].compactMap { $0 })
            .filter { !candidates.contains($0) && canConnect(to: $0) }
        if !others.isEmpty {
            FileHandle.standardError.write(Data((
                "No Programa socket at \(requestedPath). Other Programa sockets are running: "
                + others.joined(separator: ", ")
                + ". To use one, set PROGRAMA_SOCKET_PATH and PROGRAMA_SOCKET (or pass --socket).\n"
            ).utf8))
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

        // The App Support socket lives in an owner-only directory; /tmp is world-writable, so the
        // legacy /tmp path is tried after it. Only the stable defaults are implicit candidates.
        if requestedPath != legacyDefaultSocketPath {
            candidates.append(requestedPath)
        }
        candidates.append(defaultSocketPath)
        candidates.append(legacyDefaultSocketPath)
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
        guard CLISocketSafety.checkPath(path) == .ok else { return false }
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
        return result == 0 && CLISocketSafety.peerUIDMatchesCurrentUser(fd: fd)
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
