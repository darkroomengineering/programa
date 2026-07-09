// Extracted from WorkspaceRemoteSession.swift (nuclear-review #98): ssh/scp argument assembly and the underlying Process execution primitive.

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
    func sshCommonArguments(batchMode: Bool) -> [String] {
        let effectiveSSHOptions: [String] = {
            if batchMode {
                return RemoteSSHConnectionPolicy.backgroundOptions(configuration.sshOptions)
            }
            return RemoteSSHConnectionPolicy.normalizedOptions(configuration.sshOptions)
        }()
        var args = RemoteSSHConnectionPolicy.keepaliveArguments
        args += RemoteSSHConnectionPolicy.strictHostKeyCheckingArguments(unlessSetIn: effectiveSSHOptions)
        if batchMode {
            args += RemoteSSHConnectionPolicy.batchModeArguments
        }
        if let port = configuration.port {
            args += ["-p", String(port)]
        }
        if let identityFile = configuration.identityFile,
           !identityFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["-i", identityFile]
        }
        for option in effectiveSSHOptions {
            args += ["-o", option]
        }
        return args
    }

    func sshExec(arguments: [String], stdin: Data? = nil, timeout: TimeInterval = 15) throws -> CommandResult {
        try runProcess(
            executable: "/usr/bin/ssh",
            arguments: arguments,
            stdin: stdin,
            timeout: timeout
        )
    }

    func scpExec(
        arguments: [String],
        timeout: TimeInterval = 30,
        operation: TerminalImageTransferOperation? = nil
    ) throws -> CommandResult {
        try runProcess(
            executable: "/usr/bin/scp",
            arguments: arguments,
            stdin: nil,
            timeout: timeout,
            operation: operation
        )
    }

    func runProcess(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        stdin: Data?,
        timeout: TimeInterval,
        operation: TerminalImageTransferOperation? = nil
    ) throws -> CommandResult {
        debugLog(
            "remote.proc.start exec=\(URL(fileURLWithPath: executable).lastPathComponent) " +
            "timeout=\(Int(timeout)) args=\(debugShellCommand(executable: executable, arguments: arguments))"
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }
        if let currentDirectory {
            process.currentDirectoryURL = currentDirectory
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        if stdin != nil {
            process.standardInput = Pipe()
        } else {
            process.standardInput = FileHandle.nullDevice
        }

        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading
        let captureQueue = DispatchQueue(label: "programa.remote.process.capture")
        let exitSemaphore = DispatchSemaphore(value: 0)
        var stdoutData = Data()
        var stderrData = Data()
        let captureGroup = DispatchGroup()
        process.terminationHandler = { _ in
            exitSemaphore.signal()
        }
        captureGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = stdoutHandle.readDataToEndOfFile()
            captureQueue.sync {
                stdoutData = data
            }
            captureGroup.leave()
        }
        captureGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = stderrHandle.readDataToEndOfFile()
            captureQueue.sync {
                stderrData = data
            }
            captureGroup.leave()
        }

        do {
            try operation?.throwIfCancelled()
            try process.run()
        } catch {
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
            debugLog(
                "remote.proc.launchFailed exec=\(URL(fileURLWithPath: executable).lastPathComponent) " +
                "error=\(error.localizedDescription)"
            )
            throw NSError(domain: "programa.remote.process", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to launch \(URL(fileURLWithPath: executable).lastPathComponent): \(error.localizedDescription)",
            ])
        }
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()
        operation?.installCancellationHandler {
            if process.isRunning {
                process.terminate()
            }
        }
        defer { operation?.clearCancellationHandler() }

        if let stdin, let pipe = process.standardInput as? Pipe {
            pipe.fileHandleForWriting.write(stdin)
            try? pipe.fileHandleForWriting.close()
        }

        func terminateProcessAndWait() {
            process.terminate()
            let terminatedGracefully = exitSemaphore.wait(timeout: .now() + 2.0) == .success
            if !terminatedGracefully, process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
        }

        let didExitBeforeTimeout = exitSemaphore.wait(timeout: .now() + max(0, timeout)) == .success
        if !didExitBeforeTimeout, process.isRunning {
            if operation?.isCancelled == true {
                terminateProcessAndWait()
                throw TerminalImageTransferExecutionError.cancelled
            }
            terminateProcessAndWait()
            debugLog(
                "remote.proc.timeout exec=\(URL(fileURLWithPath: executable).lastPathComponent) " +
                "timeout=\(Int(timeout)) args=\(debugShellCommand(executable: executable, arguments: arguments))"
            )
            throw NSError(domain: "programa.remote.process", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "\(URL(fileURLWithPath: executable).lastPathComponent) timed out after \(Int(timeout))s",
            ])
        }

        _ = captureGroup.wait(timeout: .now() + 2.0)
        try? stdoutHandle.close()
        try? stderrHandle.close()
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        if operation?.isCancelled == true {
            throw TerminalImageTransferExecutionError.cancelled
        }
        debugLog(
            "remote.proc.end exec=\(URL(fileURLWithPath: executable).lastPathComponent) " +
            "status=\(process.terminationStatus) stdout=\(Self.debugLogSnippet(stdout)) " +
            "stderr=\(Self.debugLogSnippet(stderr))"
        )
        return CommandResult(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }


}
