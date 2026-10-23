import Foundation
import AppKit

/// Bounded in-memory ring of recent lines, mirrored to a file under `~/Library/Logs`.
class FileLogStore {
    private let queue: DispatchQueue
    private var entries: [String] = []
    private let maxEntries: Int
    /// `nil` lets the file grow without rotation.
    private let maxLogFileSize: UInt64?
    private let logURL: URL
    let formatter: ISO8601DateFormatter

    init(queueLabel: String, fileName: String, maxEntries: Int, maxLogFileSize: UInt64?) {
        queue = DispatchQueue(label: queueLabel)
        self.maxEntries = maxEntries
        self.maxLogFileSize = maxLogFileSize
        formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let logsDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        logURL = logsDir.appendingPathComponent("Logs/\(fileName)")
        ensureLogFile()
    }

    func appendLine(_ line: String) {
        queue.async { [weak self] in
            guard let self else { return }
            entries.append(line)
            if entries.count > maxEntries {
                entries.removeFirst(entries.count - maxEntries)
            }
            appendToFile(line: line)
        }
    }

    func snapshot() -> String {
        queue.sync {
            entries.joined(separator: "\n")
        }
    }

    func logPath() -> String {
        logURL.path
    }

    private func ensureLogFile() {
        let directory = logURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: logURL.path) {
            try? Data().write(to: logURL)
        }
    }

    private func appendToFile(line: String) {
        let data = Data((line + "\n").utf8)
        if let maxLogFileSize {
            rotateLogIfNeeded(appendingByteCount: data.count, maxLogFileSize: maxLogFileSize)
        }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: logURL, options: .atomic)
        }
    }

    private func rotateLogIfNeeded(appendingByteCount: Int, maxLogFileSize: UInt64) {
        let attributes = try? FileManager.default.attributesOfItem(atPath: logURL.path)
        let currentSize = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        guard currentSize > 0,
              currentSize + UInt64(appendingByteCount) > maxLogFileSize else {
            return
        }

        let backupURL = logURL.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: backupURL)
        do {
            try FileManager.default.moveItem(at: logURL, to: backupURL)
            ensureLogFile()
        } catch {
            // Best-effort logging must not interfere with the caller.
        }
    }
}

final class UpdateLogStore: FileLogStore {
    static let shared = UpdateLogStore()

    private init() {
        super.init(
            queueLabel: "programa.update.log",
            fileName: "programa-update.log",
            maxEntries: 200,
            maxLogFileSize: 1024 * 1024
        )
    }

    func append(_ message: String) {
        let timestamp = formatter.string(from: Date())
        let bundle = Bundle.main.bundleIdentifier ?? "<no.bundle.id>"
        let pid = ProcessInfo.processInfo.processIdentifier
        appendLine("[\(timestamp)] [\(bundle):\(pid)] \(message)")
    }
}

final class FocusLogStore: FileLogStore {
    static let shared = FocusLogStore()

    private init() {
        super.init(
            queueLabel: "programa.focus.log",
            fileName: "programa-focus.log",
            maxEntries: 400,
            maxLogFileSize: nil
        )
    }

    func append(_ message: String) {
        #if DEBUG
        let timestamp = formatter.string(from: Date())
        appendLine("[\(timestamp)] \(message)")
        #endif
    }
}
