import Foundation

/// Low-level primitive for watching a single filesystem path (file or directory) via
/// `DispatchSource.makeFileSystemObjectSource`.
///
/// This extracts the open-fd / create-source / resume / cancel-and-close boilerplate that
/// used to be duplicated across `ProgramaConfigStore`'s local + global config watchers and
/// `ShortcutSettingsFileWatcher`'s primary + fallback watchers.
///
/// `FileWatcher` owns exactly one active `DispatchSourceFileSystemObject` at a time; starting
/// a new watch implicitly stops any previous one. It intentionally does NOT implement
/// retry/backoff or file-vs-directory fallback policy — callers own that, since it differs
/// (and has drifted) between call sites. See:
/// - `ProgramaConfigStore.startLocalFileWatcher` / `startGlobalFileWatcher` (programa.json watching)
/// - `ShortcutSettingsFileWatcher` in `ProgramaSettingsFileStore.swift` (settings.json watching)
final class FileWatcher {
    private let queue: DispatchQueue
    private var source: DispatchSourceFileSystemObject?

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    deinit {
        source?.cancel()
    }

    /// Opens `path` for event-only access and starts watching it for `eventMask` events,
    /// invoking `onEvent` with the fired event flags on `queue` each time. Stops any
    /// previously active watch first.
    ///
    /// Returns `false` without starting anything if `path` could not be opened (e.g. it
    /// doesn't exist yet) — callers use this to fall back to watching the containing
    /// directory instead.
    @discardableResult
    func start(
        path: String,
        eventMask: DispatchSource.FileSystemEvent,
        onEvent: @escaping (DispatchSource.FileSystemEvent) -> Void
    ) -> Bool {
        stop()

        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return false }

        let newSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: eventMask,
            queue: queue
        )
        newSource.setEventHandler { [weak self] in
            guard let self, let activeSource = self.source else { return }
            onEvent(activeSource.data)
        }
        newSource.setCancelHandler {
            Darwin.close(fd)
        }
        source = newSource
        newSource.resume()
        return true
    }

    /// Cancels the active watch, if any. Safe to call when nothing is active.
    func stop() {
        source?.cancel()
        source = nil
    }
}
