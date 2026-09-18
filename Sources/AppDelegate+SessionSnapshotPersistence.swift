import AppKit
import Bonsplit
import Foundation

/// Session snapshot build/save/persist machinery, extracted from `AppDelegate.swift` to stay
/// under its structural line budget (`scripts/check-structural-budgets.py`). Behavior-neutral
/// split: everything here still runs on `AppDelegate`, just from a sibling file.
extension AppDelegate {
    /// A synchronous save returns the disk-write result; an asynchronous save returns queue
    /// acceptance and reports the completed disk write through its main-queue completion.
    @discardableResult
    func saveSessionSnapshot(
        includeScrollback: Bool,
        removeWhenEmpty: Bool = false,
        cleanShutdown: Bool = false,
        prebuiltSnapshot: AppSessionSnapshot? = nil,
        completion: SessionAutosaveCoordinator.SaveCompletion? = nil
    ) -> Bool {
        if startupHandoff.shouldDefer() {
            completion?(false)
            return false
        }
        if Self.shouldSkipSessionSaveDuringStartupRestore(
            isApplyingStartupSessionRestore: isApplyingStartupSessionRestore,
            includeScrollback: includeScrollback
        ) {
#if DEBUG
            dlog("session.save.skipped reason=startup_restore_in_progress includeScrollback=0")
#endif
            completion?(false)
            return false
        }

        let writeSynchronously = SessionAutosaveCoordinator.shouldWriteSessionSnapshotSynchronously(
            isTerminatingApp: isTerminatingApp,
            includeScrollback: includeScrollback
        )
#if DEBUG
        let timingStart = ProgramaTypingTiming.start()
        defer {
            ProgramaTypingTiming.logDuration(
                path: "session.saveSnapshot",
                startedAt: timingStart,
                extra: "includeScrollback=\(includeScrollback ? 1 : 0) removeWhenEmpty=\(removeWhenEmpty ? 1 : 0) sync=\(writeSynchronously ? 1 : 0)"
            )
        }
#endif

        guard let snapshot = prebuiltSnapshot ?? buildSessionSnapshot(includeScrollback: includeScrollback, cleanShutdown: cleanShutdown) else {
            _ = persistSessionSnapshot(
                nil,
                removeWhenEmpty: removeWhenEmpty,
                persistedGeometryData: nil,
                synchronously: writeSynchronously,
                completion: completion
            )
            return false
        }

        let persistedGeometryData = snapshot.windows.first.flatMap { primaryWindow in
            Self.encodedPersistedWindowGeometryData(
                frame: primaryWindow.frame,
                display: primaryWindow.display
            )
        }

#if DEBUG
        debugLogSessionSaveSnapshot(snapshot, includeScrollback: includeScrollback)
#endif
        return persistSessionSnapshot(
            snapshot,
            removeWhenEmpty: false,
            persistedGeometryData: persistedGeometryData,
            synchronously: writeSynchronously,
            completion: completion
        )
    }

    nonisolated static func shouldPersistSnapshotOnWindowUnregister(isTerminatingApp: Bool) -> Bool {
        !isTerminatingApp
    }

    nonisolated static func shouldRemoveSnapshotWhenNoWindowsRemainOnWindowUnregister(
        isTerminatingApp: Bool
    ) -> Bool {
        !isTerminatingApp
    }

    nonisolated static func shouldSkipSessionSaveDuringStartupRestore(
        isApplyingStartupSessionRestore: Bool,
        includeScrollback: Bool
    ) -> Bool {
        isApplyingStartupSessionRestore && !includeScrollback
    }

    nonisolated static func performSessionPersistenceWrite(
        on queue: DispatchQueue,
        synchronously: Bool,
        operation: @escaping () -> Void
    ) {
        if synchronously {
            queue.sync(execute: operation)
        } else {
            queue.async(execute: DispatchWorkItem(block: operation))
        }
    }

    fileprivate func persistSessionSnapshot(
        _ snapshot: AppSessionSnapshot?,
        removeWhenEmpty: Bool,
        persistedGeometryData: Data?,
        synchronously: Bool,
        completion: SessionAutosaveCoordinator.SaveCompletion?
    ) -> Bool {
        guard snapshot != nil || removeWhenEmpty || persistedGeometryData != nil else {
            completion?(false)
            return false
        }

        // The production seam: defaults to the core session-snapshot store, and can be
        // redirected in tests to point disk writes at a scratch location.
        let snapshotWriter = sessionSnapshotWriter
        let capturePolicy = SessionWALStore.shared.currentCapturePolicy()
#if DEBUG
        let saveOverride = debugSessionSnapshotSaverForTesting
#endif
        // Preferences can synchronously notify main-queue observers; never write them
        // from the disk queue while quit is synchronously waiting for that queue.
        Self.removeLegacyPersistedWindowGeometry()
        if let persistedGeometryData {
            UserDefaults.standard.set(persistedGeometryData, forKey: Self.persistedWindowGeometryDefaultsKey)
        }

        let writeBlock = { () -> Bool in
            if let snapshot {
                let saved = Self.writeSessionSnapshot(
                    snapshot,
                    policyPaths: SessionScrollbackPolicyPaths.make(),
                    capturedGeneration: capturePolicy.enabled ? capturePolicy.generation : nil,
                    writer: { candidate in
#if DEBUG
                        saveOverride?(candidate) ?? snapshotWriter(candidate)
#else
                        snapshotWriter(candidate)
#endif
                    }
                )
                if !saved { dilog("session.save", "outcome=failed") }
                return saved
            } else if removeWhenEmpty {
                SessionPersistenceStore.removeSnapshot()
            }
            return true
        }

        if synchronously {
            var saved = false
            Self.performSessionPersistenceWrite(on: sessionPersistenceQueue, synchronously: true) {
                saved = writeBlock()
            }
            completion?(saved)
            return saved
        }
        Self.performSessionPersistenceWrite(on: sessionPersistenceQueue, synchronously: false) {
            let saved = writeBlock()
            if let completion {
                DispatchQueue.main.async { completion(saved) }
            }
        }
        return true
    }

    nonisolated static func writeSessionSnapshot(
        _ snapshot: AppSessionSnapshot,
        policyPaths: SessionScrollbackPolicyPaths?,
        capturedGeneration: UUID?,
        writer: (AppSessionSnapshot) -> Bool
    ) -> Bool {
        if let capturedGeneration,
           let saved = try? SessionScrollbackPolicyStore.withContentPermission(
            at: policyPaths, capturedGeneration: capturedGeneration,
            { writer(snapshot) }
           ) {
            return saved
        }
        return writer(SessionPersistenceStore.withoutScrollback(snapshot))
    }

    func buildSessionSnapshot(includeScrollback: Bool, cleanShutdown: Bool = false) -> AppSessionSnapshot? {
        // Hidden windows (closed by the user, kept alive by `preserveMainWindowOnClose`) sort
        // last so `windows.first` -- the entry restore applies to the launch window -- is
        // always one the user could see. They are still written, flagged `isHidden`, so the
        // next launch knows which escrowed shells to end instead of reviving.
        let contexts = mainWindowContexts.values.sorted { lhs, rhs in
            let lhsIsHidden = lhs.hiddenWindow != nil
            let rhsIsHidden = rhs.hiddenWindow != nil
            if lhsIsHidden != rhsIsHidden {
                return !lhsIsHidden
            }
            let lhsWindow = lhs.window ?? windowForMainWindowId(lhs.windowId)
            let rhsWindow = rhs.window ?? windowForMainWindowId(rhs.windowId)
            let lhsIsKey = lhsWindow?.isKeyWindow ?? false
            let rhsIsKey = rhsWindow?.isKeyWindow ?? false
            if lhsIsKey != rhsIsKey {
                return lhsIsKey && !rhsIsKey
            }
            return lhs.windowId.uuidString < rhs.windowId.uuidString
        }

        guard !contexts.isEmpty else { return nil }

        let windows: [SessionWindowSnapshot] = contexts
            .prefix(SessionPersistencePolicy.maxWindowsPerSnapshot)
            .map { context in
                let window = context.window ?? windowForMainWindowId(context.windowId)
                let isHidden = context.hiddenWindow != nil
                return SessionWindowSnapshot(
                    frame: window.map { SessionRectSnapshot($0.frame) },
                    display: displaySnapshot(for: window),
                    // A hidden window is never shown again, so its scrollback is dead weight.
                    tabManager: context.tabManager.sessionSnapshot(includeScrollback: includeScrollback && !isHidden),
                    sidebar: SessionSidebarSnapshot(
                        isVisible: context.sidebarState.isVisible,
                        selection: SessionSidebarSelection(selection: context.sidebarSelectionState.selection),
                        width: SessionPersistencePolicy.sanitizedSidebarWidth(Double(context.sidebarState.persistedWidth))
                    ),
                    isHidden: isHidden ? true : nil
                )
            }

        guard !windows.isEmpty else { return nil }
        return AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion,
            createdAt: Date().timeIntervalSince1970,
            windows: windows,
            cleanShutdown: cleanShutdown
        )
    }

#if DEBUG
    fileprivate func debugLogSessionSaveSnapshot(
        _ snapshot: AppSessionSnapshot,
        includeScrollback: Bool
    ) {
        dlog(
            "session.save includeScrollback=\(includeScrollback ? 1 : 0) " +
                "windows=\(snapshot.windows.count)"
        )
        for (index, windowSnapshot) in snapshot.windows.enumerated() {
            let workspaceCount = windowSnapshot.tabManager.workspaces.count
            let selectedWorkspace = windowSnapshot.tabManager.selectedWorkspaceIndex.map(String.init) ?? "nil"
            dlog(
                "session.save.window idx=\(index) " +
                    "frame={\(debugSessionRectDescription(windowSnapshot.frame))} " +
                    "display={\(debugSessionDisplayDescription(windowSnapshot.display))} " +
                    "workspaces=\(workspaceCount) selected=\(selectedWorkspace) hidden=\(windowSnapshot.isHiddenWindow ? 1 : 0)"
            )
        }
    }
#endif
}
