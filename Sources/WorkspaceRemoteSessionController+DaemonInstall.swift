// Extracted from WorkspaceRemoteSession.swift (nuclear-review #98): remote daemon bootstrap/build/download/upload and file-drop upload.

import Foundation
import SwiftUI
import AppKit
import Bonsplit
import Combine
import CryptoKit
import Darwin
import Network
import CoreText

extension WorkspaceRemoteSessionController {
    static let remotePlatformProbeOSMarker = "__PROGRAMA_REMOTE_OS__="
    static let remotePlatformProbeArchMarker = "__PROGRAMA_REMOTE_ARCH__="
    static let remotePlatformProbeExistsMarker = "__PROGRAMA_REMOTE_EXISTS__="

    func bootstrapDaemonLocked() throws -> DaemonHello {
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

    func ensureCLIRelayServerLocked(localSocketPath: String, relayID: String, relayToken: String) throws -> WorkspaceRemoteCLIRelayServer {
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

    func installRemoteRelayMetadataLocked(
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

    func removeRemoteRelayMetadataLocked() {
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

    func probeRemoteBootstrapStateLocked(version: String) throws -> RemoteBootstrapState {
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

    static func remoteDaemonManifest() -> WorkspaceRemoteDaemonManifest? {
        remoteDaemonManifest(from: Bundle.main.infoDictionary)
    }

    static func remoteDaemonCacheRoot(fileManager: FileManager = .default) throws -> URL {
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

    static func sha256Hex(forFile url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func allowLocalDaemonBuildFallback(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment["PROGRAMA_REMOTE_DAEMON_ALLOW_LOCAL_BUILD"] == "1"
    }

    static func explicitRemoteDaemonBinaryURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        guard allowLocalDaemonBuildFallback(environment: environment) else { return nil }
        guard let path = environment["PROGRAMA_REMOTE_DAEMON_BINARY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: false).standardizedFileURL
    }

    static func versionedRemoteDaemonBuildURL(goOS: String, goArch: String, version: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("programa-remote-daemon-build", isDirectory: true)
            .appendingPathComponent(version, isDirectory: true)
            .appendingPathComponent("\(goOS)-\(goArch)", isDirectory: true)
            .appendingPathComponent("programad-remote", isDirectory: false)
    }

    /// Fetch the live manifest JSON from the release, returning nil on any failure.
    static func fetchRemoteManifestLocked(releaseURL: String, version: String) -> WorkspaceRemoteDaemonManifest? {
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

    func downloadRemoteDaemonBinaryLocked(entry: WorkspaceRemoteDaemonManifest.Entry, version: String, releaseURL: String? = nil) throws -> URL {
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

    func buildLocalDaemonBinary(goOS: String, goArch: String, version: String) throws -> URL {
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

    func uploadRemoteDaemonBinaryLocked(localBinary: URL, remotePath: String) throws {
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

    func uploadDroppedFilesLocked(
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

    func cleanupUploadedRemotePaths(_ remotePaths: [String]) {
        guard !remotePaths.isEmpty else { return }
        let cleanupScript = "rm -f -- " + remotePaths.map(RemoteSSHConnectionPolicy.shellSingleQuoted).joined(separator: " ")
        let cleanupCommand = "sh -c \(RemoteSSHConnectionPolicy.shellSingleQuoted(cleanupScript))"
        _ = try? sshExec(
            arguments: sshCommonArguments(batchMode: true) + [configuration.destination, cleanupCommand],
            timeout: 8
        )
    }

    func helloRemoteDaemonLocked(remotePath: String) throws -> DaemonHello {
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

}
