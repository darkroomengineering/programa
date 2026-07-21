#if DEBUG
import Foundation

/// Unified ring-buffer event log for key, mouse, focus, and split events.
/// Writes every entry to a debug log path so `tail -f` works in real time.
public final class DebugEventLog: @unchecked Sendable {
    public static let shared = DebugEventLog()

    private var entries: [String] = []
    private let capacity = 500
    private let queue = DispatchQueue(label: "cmux.debug-event-log")
    private static let logPath = resolveLogPath()

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private static func sanitizePathToken(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let unicode = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let sanitized = String(unicode).trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return sanitized.isEmpty ? "debug" : sanitized
    }

    static func resolveLogPath(env: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let explicit = env["PROGRAMA_DEBUG_LOG"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty {
            return explicit
        }
        if let explicit = env["CMUX_DEBUG_LOG"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty {
            return explicit
        }

        if let tag = env["PROGRAMA_TAG"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !tag.isEmpty {
            return "/tmp/programa-debug-\(sanitizePathToken(tag)).log"
        }
        if let tag = env["CMUX_TAG"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !tag.isEmpty {
            return "/tmp/cmux-debug-\(sanitizePathToken(tag)).log"
        }

        if let socketPath = env["PROGRAMA_SOCKET_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !socketPath.isEmpty {
            let socketBase = URL(fileURLWithPath: socketPath).deletingPathExtension().lastPathComponent
            if socketBase.hasPrefix("programa-debug-") {
                return "/tmp/\(socketBase).log"
            }
        }
        if let socketPath = env["CMUX_SOCKET_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !socketPath.isEmpty {
            let socketBase = URL(fileURLWithPath: socketPath).deletingPathExtension().lastPathComponent
            if socketBase.hasPrefix("cmux-debug-") {
                return "/tmp/\(socketBase).log"
            }
        }

        if let bundleId = Bundle.main.bundleIdentifier,
           bundleId != "com.cmuxterm.app.debug", bundleId != "com.darkroom.programa.debug" {
            return "/tmp/programa-debug-\(sanitizePathToken(bundleId)).log"
        }
        return "/tmp/programa-debug.log"
    }

    public func log(_ msg: String) {
        let ts = Self.formatter.string(from: Date())
        let entry = "\(ts) \(msg)"
        queue.async {
            if self.entries.count >= self.capacity {
                self.entries.removeFirst()
            }
            self.entries.append(entry)
            // Append to file for real-time tail -f
            let line = entry + "\n"
            if let data = line.data(using: .utf8) {
                if let handle = FileHandle(forWritingAtPath: Self.logPath) {
                    // Throwing APIs instead of the deprecated seekToEndOfFile/write/closeFile
                    // trio, which raise ObjC exceptions (uncatchable from Swift) if the file
                    // disappears out from under us. Ported from upstream bonsplit cffd9a6.
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                    try? handle.close()
                } else {
                    FileManager.default.createFile(atPath: Self.logPath, contents: data)
                }
            }
        }
    }

    /// Write all buffered entries to the log file (full dump, replacing contents).
    public func dump() {
        queue.async {
            let content = self.entries.joined(separator: "\n") + "\n"
            try? content.write(toFile: Self.logPath, atomically: true, encoding: .utf8)
        }
    }
}

/// Convenience free function. Logs the message and appends to the configured debug log path.
public func dlog(_ msg: String) {
    DebugEventLog.shared.log(msg)
}
#endif
