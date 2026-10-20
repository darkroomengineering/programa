import Foundation

// MARK: - BackgroundLogWriter
//
// Avoids a per-call FileManager.fileExists + FileHandle(forWritingTo:)
// open -> seekToEnd -> write -> close pattern, which would run synchronously under a lock
// on the calling thread (often the main thread) for every debug log line and block
// appearance-config resolution during bursts of background log activity.
//
// This writer serializes all file I/O onto a single serial background queue with one
// long-lived FileHandle. Callers append lines asynchronously and never block. The log
// file path/format is unchanged so existing tooling that tails the log keeps working.

/// Minimal sink abstraction so the writer's queueing/coalescing logic can be tested
/// independently of real file I/O. Upstream splits this into a protocol for their
/// package's unit tests; programa has no separate test target for this file, so the
/// concrete `FileBackgroundLogLineSink` is the only conformer today.
protocol BackgroundLogLineSink: AnyObject {
    func write(_ data: Data)
}

/// Owns a single long-lived `FileHandle` opened for appending, created lazily on first
/// write and reused for the lifetime of the sink. Must only be used from the writer's
/// serial queue.
final class FileBackgroundLogLineSink: BackgroundLogLineSink {
    private let url: URL
    private var handle: FileHandle?

    init(url: URL) {
        self.url = url
    }

    func write(_ data: Data) {
        if handle == nil {
            handle = Self.openHandle(at: url)
        }
        guard let handle else { return }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            // The handle may have become invalid (e.g. file removed out from under us).
            // Drop it so the next write reopens rather than repeatedly failing.
            try? handle.close()
            self.handle = nil
        }
    }

    /// The log path can sit in a shared directory such as /tmp, so the open refuses a symlink
    /// at the final component, anything that is not a regular file, and a file another user
    /// owns; otherwise another user could aim the log at a file of ours or read what we write.
    private static func openHandle(at url: URL) -> FileHandle? {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid() else {
            close(fd)
            return nil
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
}

/// Appends pre-formatted log lines to disk on a single serial background queue,
/// so callers (which may be on the main thread) never block on file I/O.
final class BackgroundLogWriter {
    private let queue = DispatchQueue(label: "com.darkroom.programa.background-log-writer", qos: .utility)
    private let sink: BackgroundLogLineSink

    convenience init(url: URL) {
        self.init(sink: FileBackgroundLogLineSink(url: url))
    }

    init(sink: BackgroundLogLineSink) {
        self.sink = sink
    }

    /// Appends `line` to the log file asynchronously. Safe to call from any thread;
    /// never blocks the caller on file I/O.
    func append(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        queue.async { [sink] in
            sink.write(data)
        }
    }
}
