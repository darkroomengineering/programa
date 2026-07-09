// Extracted from WorkspaceRemoteDaemon.swift (nuclear-review #98): the JSON-RPC client that talks to programad-remote over ssh -T.

import Foundation
import SwiftUI
import AppKit
import Bonsplit
import Combine
import CryptoKit
import Darwin
import Network
import CoreText

final class WorkspaceRemoteDaemonRPCClient {
    private static let maxStdoutBufferBytes = 256 * 1024
    static let requiredProxyStreamCapability = "proxy.stream.push"

    enum StreamEvent {
        case data(Data)
        case eof(Data)
        case error(String)
    }

    private struct StreamSubscription {
        let queue: DispatchQueue
        let handler: (StreamEvent) -> Void
    }

    private let configuration: WorkspaceRemoteConfiguration
    private let remotePath: String
    private let onUnexpectedTermination: (String) -> Void
    private let writeQueue = DispatchQueue(label: "com.cmux.remote-ssh.daemon-rpc.write.\(UUID().uuidString)")
    private let stateQueue = DispatchQueue(label: "com.cmux.remote-ssh.daemon-rpc.state.\(UUID().uuidString)")
    private let pendingCalls = WorkspaceRemoteDaemonPendingCallRegistry()

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?
    private var isClosed = true
    private var shouldReportTermination = true

    private var stdoutBuffer = Data()
    private var stderrBuffer = ""
    private var streamSubscriptions: [String: StreamSubscription] = [:]

    init(
        configuration: WorkspaceRemoteConfiguration,
        remotePath: String,
        onUnexpectedTermination: @escaping (String) -> Void
    ) {
        self.configuration = configuration
        self.remotePath = remotePath
        self.onUnexpectedTermination = onUnexpectedTermination
    }

    func start() throws {
        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        stateQueue.sync {
            self.stdinPipe = stdinPipe
            self.stdoutPipe = stdoutPipe
            self.stderrPipe = stderrPipe
        }

        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = Self.daemonArguments(configuration: configuration, remotePath: remotePath)
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.stateQueue.async {
                self?.consumeStdoutData(data)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.stateQueue.async {
                self?.consumeStderrData(data)
            }
        }
        process.terminationHandler = { [weak self] terminated in
            self?.stateQueue.async {
                self?.handleProcessTermination(terminated)
            }
        }

        do {
            try process.run()
        } catch {
            throw NSError(domain: "programa.remote.daemon.rpc", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to launch SSH daemon transport: \(error.localizedDescription)",
            ])
        }

        stateQueue.sync {
            self.process = process
            self.stdinHandle = stdinPipe.fileHandleForWriting
            self.stdoutHandle = stdoutPipe.fileHandleForReading
            self.stderrHandle = stderrPipe.fileHandleForReading
            self.isClosed = false
            self.shouldReportTermination = true
            self.stdoutBuffer = Data()
            self.stderrBuffer = ""
            self.streamSubscriptions.removeAll(keepingCapacity: false)
        }
        pendingCalls.reset()

        do {
            let hello = try call(method: "hello", params: [:], timeout: 8.0)
            let capabilities = (hello["capabilities"] as? [String]) ?? []
            guard capabilities.contains(Self.requiredProxyStreamCapability) else {
                throw NSError(domain: "programa.remote.daemon.rpc", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "remote daemon missing required capability \(Self.requiredProxyStreamCapability)",
                ])
            }
        } catch {
            stop(suppressTerminationCallback: true)
            throw error
        }
    }

    func stop() {
        stop(suppressTerminationCallback: true)
    }

    func openStream(host: String, port: Int, timeoutMs: Int = 10000) throws -> String {
        let result = try call(
            method: "proxy.open",
            params: [
                "host": host,
                "port": port,
                "timeout_ms": timeoutMs,
            ],
            timeout: 12.0
        )
        let streamID = (result["stream_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !streamID.isEmpty else {
            throw NSError(domain: "programa.remote.daemon.rpc", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "proxy.open missing stream_id",
            ])
        }
        return streamID
    }

    func writeStream(streamID: String, data: Data) throws {
        _ = try call(
            method: "proxy.write",
            params: [
                "stream_id": streamID,
                "data_base64": data.base64EncodedString(),
            ],
            timeout: 8.0
        )
    }

    func attachStream(
        streamID: String,
        queue: DispatchQueue,
        onEvent: @escaping (StreamEvent) -> Void
    ) throws {
        let trimmedStreamID = streamID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedStreamID.isEmpty else {
            throw NSError(domain: "programa.remote.daemon.rpc", code: 17, userInfo: [
                NSLocalizedDescriptionKey: "proxy.stream.subscribe requires stream_id",
            ])
        }

        stateQueue.sync {
            streamSubscriptions[trimmedStreamID] = StreamSubscription(queue: queue, handler: onEvent)
        }

        do {
            _ = try call(
                method: "proxy.stream.subscribe",
                params: ["stream_id": trimmedStreamID],
                timeout: 8.0
            )
        } catch {
            unregisterStream(streamID: trimmedStreamID)
            throw error
        }
    }

    func unregisterStream(streamID: String) {
        let trimmedStreamID = streamID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedStreamID.isEmpty else { return }
        _ = stateQueue.sync {
            streamSubscriptions.removeValue(forKey: trimmedStreamID)
        }
    }

    func closeStream(streamID: String) {
        unregisterStream(streamID: streamID)
        _ = try? call(
            method: "proxy.close",
            params: ["stream_id": streamID],
            timeout: 4.0
        )
    }

    private func call(method: String, params: [String: Any], timeout: TimeInterval) throws -> [String: Any] {
        let pendingCall = pendingCalls.register()
        let requestID = pendingCall.id

        let payload: Data
        do {
            payload = try Self.encodeJSON([
                "id": requestID,
                "method": method,
                "params": params,
            ])
        } catch {
            pendingCalls.remove(pendingCall)
            throw NSError(domain: "programa.remote.daemon.rpc", code: 10, userInfo: [
                NSLocalizedDescriptionKey: "failed to encode daemon RPC request \(method): \(error.localizedDescription)",
            ])
        }

        do {
            try writeQueue.sync {
                try writePayload(payload)
            }
        } catch {
            pendingCalls.remove(pendingCall)
            throw error
        }

        let response: [String: Any]
        switch pendingCalls.wait(for: pendingCall, timeout: timeout) {
        case .timedOut:
            stop(suppressTerminationCallback: false)
            throw NSError(domain: "programa.remote.daemon.rpc", code: 11, userInfo: [
                NSLocalizedDescriptionKey: "daemon RPC timeout waiting for \(method) response",
            ])
        case .failure(let failure):
            throw NSError(domain: "programa.remote.daemon.rpc", code: 12, userInfo: [
                NSLocalizedDescriptionKey: failure,
            ])
        case .missing:
            throw NSError(domain: "programa.remote.daemon.rpc", code: 13, userInfo: [
                NSLocalizedDescriptionKey: "daemon RPC \(method) returned empty response",
            ])
        case .response(let pendingResponse):
            response = pendingResponse
        }

        let ok = (response["ok"] as? Bool) ?? false
        if ok {
            return (response["result"] as? [String: Any]) ?? [:]
        }

        let errorObject = (response["error"] as? [String: Any]) ?? [:]
        let code = (errorObject["code"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "rpc_error"
        let message = (errorObject["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "daemon RPC call failed"
        throw NSError(domain: "programa.remote.daemon.rpc", code: 14, userInfo: [
            NSLocalizedDescriptionKey: "\(method) failed (\(code)): \(message)",
        ])
    }

    private func writePayload(_ payload: Data) throws {
        let stdinHandle: FileHandle = stateQueue.sync {
            self.stdinHandle ?? FileHandle.nullDevice
        }
        if stdinHandle === FileHandle.nullDevice {
            throw NSError(domain: "programa.remote.daemon.rpc", code: 15, userInfo: [
                NSLocalizedDescriptionKey: "daemon transport is not connected",
            ])
        }
        do {
            try stdinHandle.write(contentsOf: payload)
            try stdinHandle.write(contentsOf: Data([0x0A]))
        } catch {
            stop(suppressTerminationCallback: false)
            throw NSError(domain: "programa.remote.daemon.rpc", code: 16, userInfo: [
                NSLocalizedDescriptionKey: "failed writing daemon RPC request: \(error.localizedDescription)",
            ])
        }
    }

    private func consumeStdoutData(_ data: Data) {
        guard !data.isEmpty else {
            signalPendingFailureLocked("daemon transport closed stdout")
            return
        }

        stdoutBuffer.append(data)
        if stdoutBuffer.count > Self.maxStdoutBufferBytes {
            stdoutBuffer.removeAll(keepingCapacity: false)
            signalPendingFailureLocked("daemon transport stdout exceeded \(Self.maxStdoutBufferBytes) bytes without message framing")
            process?.terminate()
            return
        }
        while let newlineIndex = stdoutBuffer.firstIndex(of: 0x0A) {
            var lineData = Data(stdoutBuffer[..<newlineIndex])
            stdoutBuffer.removeSubrange(...newlineIndex)

            if let carriageIndex = lineData.lastIndex(of: 0x0D), carriageIndex == lineData.index(before: lineData.endIndex) {
                lineData.remove(at: carriageIndex)
            }
            guard !lineData.isEmpty else { continue }

            guard let payload = try? JSONSerialization.jsonObject(with: lineData, options: []) as? [String: Any] else {
                continue
            }

            if let responseID = Self.responseID(in: payload) {
                _ = pendingCalls.resolve(id: responseID, payload: payload)
                continue
            }

            consumeEventPayload(payload)
        }
    }

    private func consumeStderrData(_ data: Data) {
        guard !data.isEmpty else { return }
        guard let chunk = String(data: data, encoding: .utf8), !chunk.isEmpty else { return }
        stderrBuffer.append(chunk)
        if stderrBuffer.count > 8192 {
            stderrBuffer.removeFirst(stderrBuffer.count - 8192)
        }
    }

    private func consumeEventPayload(_ payload: [String: Any]) {
        guard let eventName = (payload["event"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !eventName.isEmpty,
              let streamID = (payload["stream_id"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !streamID.isEmpty else {
            return
        }

        let subscription: StreamSubscription?
        let event: StreamEvent?
        switch eventName {
        case "proxy.stream.data":
            subscription = streamSubscriptions[streamID]
            event = .data(Self.decodeBase64Data(payload["data_base64"]))

        case "proxy.stream.eof":
            subscription = streamSubscriptions.removeValue(forKey: streamID)
            event = .eof(Self.decodeBase64Data(payload["data_base64"]))

        case "proxy.stream.error":
            subscription = streamSubscriptions.removeValue(forKey: streamID)
            let detail = ((payload["error"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
                ?? "stream error"
            event = .error(detail)

        default:
            return
        }

        guard let subscription, let event else { return }
        subscription.queue.async {
            subscription.handler(event)
        }
    }

    private func handleProcessTermination(_ process: Process) {
        let shouldNotify: Bool = {
            guard self.process === process else { return false }
            return !isClosed && shouldReportTermination
        }()
        let detail = Self.bestErrorLine(stderr: stderrBuffer) ?? "daemon transport exited with status \(process.terminationStatus)"

        isClosed = true
        self.process = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil
        stdinHandle = nil
        stdoutHandle?.readabilityHandler = nil
        stdoutHandle = nil
        stderrHandle?.readabilityHandler = nil
        stderrHandle = nil
        streamSubscriptions.removeAll(keepingCapacity: false)
        signalPendingFailureLocked(detail)

        guard shouldNotify else { return }
        onUnexpectedTermination(detail)
    }

    private func stop(suppressTerminationCallback: Bool) {
        let captured: (Process?, FileHandle?, FileHandle?, FileHandle?, Bool, String) = stateQueue.sync {
            let detail = Self.bestErrorLine(stderr: stderrBuffer) ?? "daemon transport stopped"
            let shouldNotify = !suppressTerminationCallback && !isClosed
            shouldReportTermination = !suppressTerminationCallback
            if isClosed {
                return (nil, nil, nil, nil, false, detail)
            }

            isClosed = true
            signalPendingFailureLocked("daemon transport stopped")
            let capturedProcess = process
            let capturedStdin = stdinHandle
            let capturedStdout = stdoutHandle
            let capturedStderr = stderrHandle

            process = nil
            stdinPipe = nil
            stdoutPipe = nil
            stderrPipe = nil
            stdinHandle = nil
            stdoutHandle = nil
            stderrHandle = nil
            streamSubscriptions.removeAll(keepingCapacity: false)
            return (capturedProcess, capturedStdin, capturedStdout, capturedStderr, shouldNotify, detail)
        }

        captured.2?.readabilityHandler = nil
        captured.3?.readabilityHandler = nil
        try? captured.1?.close()
        try? captured.2?.close()
        try? captured.3?.close()
        if let process = captured.0, process.isRunning {
            process.terminate()
        }
        if captured.4 {
            onUnexpectedTermination(captured.5)
        }
    }

    private func signalPendingFailureLocked(_ message: String) {
        pendingCalls.failAll(message)
    }

    private static func responseID(in payload: [String: Any]) -> Int? {
        if let intValue = payload["id"] as? Int {
            return intValue
        }
        if let numberValue = payload["id"] as? NSNumber {
            return numberValue.intValue
        }
        return nil
    }

    private static func decodeBase64Data(_ value: Any?) -> Data {
        guard let encoded = value as? String, !encoded.isEmpty else { return Data() }
        return Data(base64Encoded: encoded) ?? Data()
    }

    private static func encodeJSON(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [])
    }

    private static func daemonArguments(configuration: WorkspaceRemoteConfiguration, remotePath: String) -> [String] {
        WorkspaceRemoteSSHBatchCommandBuilder.daemonTransportArguments(
            configuration: configuration,
            remotePath: remotePath
        )
    }

    private static func bestErrorLine(stderr: String) -> String? {
        let lines = stderr
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for line in lines.reversed() where !isNoiseLine(line) {
            return line
        }
        return lines.last
    }

    private static func isNoiseLine(_ line: String) -> Bool {
        let lowered = line.lowercased()
        if lowered.hasPrefix("warning: permanently added") { return true }
        if lowered.hasPrefix("debug") { return true }
        if lowered.hasPrefix("transferred:") { return true }
        if lowered.hasPrefix("openbsd_") { return true }
        if lowered.contains("pseudo-terminal will not be allocated") { return true }
        return false
    }
}
