import AppKit
import Carbon.HIToolbox
import Foundation
import Bonsplit
import WebKit

extension Notification.Name {
    static let socketListenerDidStart = Notification.Name("programa.socketListenerDidStart")
    static let terminalSurfaceDidBecomeReady = Notification.Name("programa.terminalSurfaceDidBecomeReady")
    static let terminalSurfaceHostedViewDidMoveToWindow = Notification.Name("programa.terminalSurfaceHostedViewDidMoveToWindow")
    static let mainWindowContextsDidChange = Notification.Name("programa.mainWindowContextsDidChange")
    static let browserDownloadEventDidArrive = Notification.Name("programa.browserDownloadEventDidArrive")
    static let reactGrabDidCopySelection = Notification.Name("programa.reactGrabDidCopySelection")
}

/// Unix socket-based controller for programmatic terminal control
/// Allows automated testing and external control of terminal tabs
@MainActor
class TerminalController {
    struct SocketListenerHealth: Sendable {
        let isRunning: Bool
        let acceptLoopAlive: Bool
        let socketPathMatches: Bool
        let socketPathExists: Bool

        var failureSignals: [String] {
            var signals: [String] = []
            if !isRunning { signals.append("not_running") }
            if !acceptLoopAlive { signals.append("accept_loop_dead") }
            if !socketPathMatches { signals.append("socket_path_mismatch") }
            if !socketPathExists { signals.append("socket_missing") }
            return signals
        }

        var isHealthy: Bool {
            failureSignals.isEmpty
        }
    }

    static let shared = TerminalController()

    nonisolated(unsafe) var socketPath = SocketControlSettings.stableDefaultSocketPath
    private nonisolated(unsafe) var serverSocket: Int32 = -1
    private nonisolated(unsafe) var isRunning = false
    private nonisolated(unsafe) var acceptLoopAlive = false
    private nonisolated(unsafe) var activeAcceptLoopGeneration: UInt64 = 0
    private nonisolated(unsafe) var nextAcceptLoopGeneration: UInt64 = 0
    private nonisolated(unsafe) var pendingAcceptLoopRearmGeneration: UInt64?
    private nonisolated(unsafe) var pendingAcceptLoopResumeGeneration: UInt64?
    private nonisolated(unsafe) var listenerStartInProgress = false
    private nonisolated let listenerStateLock = NSLock()
    private var clientHandlers: [Int32: Thread] = [:]
    var tabManager: TabManager?
    private var accessMode: SocketControlMode = .cmuxOnly
    private let myPid = getpid()
    private nonisolated(unsafe) static var socketCommandPolicyDepth: Int = 0
    private nonisolated(unsafe) static var socketCommandFocusAllowanceStack: [Bool] = []
    private nonisolated static let socketCommandPolicyLock = NSLock()
    private nonisolated static let socketListenBacklog: Int32 = 128
    private nonisolated static let acceptFailureBaseBackoffMs = 10
    private nonisolated static let acceptFailureMaxBackoffMs = 5_000
    private nonisolated static let acceptFailureMinimumRearmDelayMs = 100
    private nonisolated static let acceptFailureRearmThreshold = 50
    private nonisolated static let socketProbePollTimeoutMs: Int32 = 100
    private nonisolated static let socketProbePollAttempts = 3
    private nonisolated static let socketProbePollRetryBackoffUs: useconds_t = 50_000
    private nonisolated static let unixSocketPathMaxLength: Int = {
        var addr = sockaddr_un()
        // Reserve one byte for the null terminator.
        return MemoryLayout.size(ofValue: addr.sun_path) - 1
    }()

    private struct ListenerStateSnapshot {
        let socketPath: String
        let serverSocket: Int32
        let isRunning: Bool
        let acceptLoopAlive: Bool
        let activeGeneration: UInt64
        let pendingRearmGeneration: UInt64?
        let pendingResumeGeneration: UInt64?
        let listenerStartInProgress: Bool
    }

    enum AcceptFailureRecoveryAction: Equatable {
        case retryImmediately
        case resumeAfterDelay(delayMs: Int)
        case rearmAfterDelay(delayMs: Int)

        var delayMs: Int {
            switch self {
            case .retryImmediately:
                return 0
            case .resumeAfterDelay(let delayMs), .rearmAfterDelay(let delayMs):
                return delayMs
            }
        }

        var debugLabel: String {
            switch self {
            case .retryImmediately:
                return "retry_immediately"
            case .resumeAfterDelay:
                return "resume_after_delay"
            case .rearmAfterDelay:
                return "rearm_after_delay"
            }
        }
    }

    private enum SocketBindAttemptResult {
        case success(path: String)
        case pathTooLong(path: String)
        case failure(path: String, stage: String, errnoCode: Int32)
    }

    private static let focusIntentV2Methods: Set<String> = [
        "window.focus",
        "workspace.select",
        "workspace.next",
        "workspace.previous",
        "workspace.last",
        "surface.focus",
        "pane.focus",
        "pane.last",
        "browser.focus_webview",
        "browser.focus",
        "browser.tab.switch",
        "debug.command_palette.toggle",
        "debug.notification.focus",
        "debug.app.activate"
    ]

    enum V2HandleKind: String, CaseIterable {
        case window
        case workspace
        case pane
        case surface
    }

    private var v2NextHandleOrdinal: [V2HandleKind: Int] = [
        .window: 1,
        .workspace: 1,
        .pane: 1,
        .surface: 1,
    ]
    private var v2RefByUUID: [V2HandleKind: [UUID: String]] = [
        .window: [:],
        .workspace: [:],
        .pane: [:],
        .surface: [:],
    ]
    private var v2UUIDByRef: [V2HandleKind: [String: UUID]] = [
        .window: [:],
        .workspace: [:],
        .pane: [:],
        .surface: [:],
    ]

    struct V2BrowserElementRefEntry {
        let surfaceId: UUID
        let selector: String
    }

    struct V2BrowserPendingDialog {
        let type: String
        let message: String
        let defaultText: String?
        let responder: (_ accept: Bool, _ text: String?) -> Void
    }

    final class V2BrowserUndefinedSentinel {}

    static let v2BrowserEvalEnvelopeTypeKey = "__programa_t"
    static let v2BrowserEvalEnvelopeValueKey = "__programa_v"
    static let v2BrowserEvalEnvelopeTypeUndefined = "undefined"
    static let v2BrowserEvalEnvelopeTypeValue = "value"

    var v2BrowserNextElementOrdinal: Int = 1
    var v2BrowserElementRefs: [String: V2BrowserElementRefEntry] = [:]
    var v2BrowserFrameSelectorBySurface: [UUID: String] = [:]
    var v2BrowserInitScriptsBySurface: [UUID: [String]] = [:]
    var v2BrowserInitStylesBySurface: [UUID: [String]] = [:]
    var v2BrowserDialogQueueBySurface: [UUID: [V2BrowserPendingDialog]] = [:]
    var v2BrowserDownloadEventsBySurface: [UUID: [[String: Any]]] = [:]
    var v2BrowserUnsupportedNetworkRequestsBySurface: [UUID: [[String: Any]]] = [:]
    var v2BrowserUndefinedSentinel = V2BrowserUndefinedSentinel()
    private var browserDownloadObserver: NSObjectProtocol?

    private init() {
        browserDownloadObserver = NotificationCenter.default.addObserver(
            forName: .browserDownloadEventDidArrive,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let surfaceId = note.userInfo?["surfaceId"] as? UUID,
                  let event = note.userInfo?["event"] as? [String: Any] else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                var queue = self.v2BrowserDownloadEventsBySurface[surfaceId] ?? []
                queue.append(event)
                self.v2BrowserDownloadEventsBySurface[surfaceId] = queue
            }
        }
    }

    private nonisolated func withListenerState<T>(_ body: () -> T) -> T {
        listenerStateLock.lock()
        defer { listenerStateLock.unlock() }
        return body()
    }

    private nonisolated func listenerStateSnapshot() -> ListenerStateSnapshot {
        withListenerState {
            ListenerStateSnapshot(
                socketPath: socketPath,
                serverSocket: serverSocket,
                isRunning: isRunning,
                acceptLoopAlive: acceptLoopAlive,
                activeGeneration: activeAcceptLoopGeneration,
                pendingRearmGeneration: pendingAcceptLoopRearmGeneration,
                pendingResumeGeneration: pendingAcceptLoopResumeGeneration,
                listenerStartInProgress: listenerStartInProgress
            )
        }
    }

    nonisolated func activeSocketPath(preferredPath: String) -> String {
        let snapshot = listenerStateSnapshot()
        if snapshot.isRunning || snapshot.acceptLoopAlive || snapshot.listenerStartInProgress || snapshot.serverSocket >= 0 {
            return snapshot.socketPath
        }
        return preferredPath
    }

    private nonisolated func shouldContinueAcceptLoop(generation: UInt64) -> Bool {
        withListenerState {
            isRunning && generation == activeAcceptLoopGeneration
        }
    }

    nonisolated static func shouldSuppressSocketCommandActivation() -> Bool {
        socketCommandPolicyLock.lock()
        defer { socketCommandPolicyLock.unlock() }
        return socketCommandPolicyDepth > 0
    }

    nonisolated static func socketCommandAllowsInAppFocusMutations() -> Bool {
        allowsInAppFocusMutationsForActiveSocketCommand()
    }

    private nonisolated static func allowsInAppFocusMutationsForActiveSocketCommand() -> Bool {
        socketCommandPolicyLock.lock()
        defer { socketCommandPolicyLock.unlock() }
        return socketCommandFocusAllowanceStack.last ?? false
    }

    func socketCommandAllowsInAppFocusMutations() -> Bool {
        Self.allowsInAppFocusMutationsForActiveSocketCommand()
    }

    func v2FocusAllowed(requested: Bool = true) -> Bool {
        requested && socketCommandAllowsInAppFocusMutations()
    }

    func v2MaybeFocusWindow(for tabManager: TabManager) {
        guard socketCommandAllowsInAppFocusMutations(),
              let windowId = v2ResolveWindowId(tabManager: tabManager) else { return }
        _ = AppDelegate.shared?.focusMainWindow(windowId: windowId)
        setActiveTabManager(tabManager)
    }

    func v2MaybeSelectWorkspace(_ tabManager: TabManager, workspace: Workspace) {
        guard socketCommandAllowsInAppFocusMutations() else { return }
        if tabManager.selectedTabId != workspace.id {
            tabManager.selectWorkspace(workspace)
        }
    }

    private static func socketCommandAllowsInAppFocusMutations(commandKey: String, isV2: Bool) -> Bool {
        // The v1 line protocol is gone; only v2 JSON-RPC methods can carry focus intent.
        guard isV2 else { return false }
        return focusIntentV2Methods.contains(commandKey)
    }

    private func withSocketCommandPolicy<T>(commandKey: String, isV2: Bool, _ body: () -> T) -> T {
        let allowsFocusMutation = Self.socketCommandAllowsInAppFocusMutations(commandKey: commandKey, isV2: isV2)
        Self.socketCommandPolicyLock.lock()
        Self.socketCommandPolicyDepth += 1
        Self.socketCommandFocusAllowanceStack.append(allowsFocusMutation)
        Self.socketCommandPolicyLock.unlock()
        defer {
            Self.socketCommandPolicyLock.lock()
            if !Self.socketCommandFocusAllowanceStack.isEmpty {
                _ = Self.socketCommandFocusAllowanceStack.popLast()
            }
            Self.socketCommandPolicyDepth = max(0, Self.socketCommandPolicyDepth - 1)
            Self.socketCommandPolicyLock.unlock()
        }
        return body()
    }

#if DEBUG
    static func debugSocketCommandPolicySnapshot(
        commandKey: String,
        isV2: Bool
    ) -> (insideSuppressed: Bool, insideAllowsFocus: Bool, outsideSuppressed: Bool, outsideAllowsFocus: Bool) {
        var insideSuppressed = false
        var insideAllowsFocus = false
        _ = Self.shared.withSocketCommandPolicy(commandKey: commandKey, isV2: isV2) {
            insideSuppressed = Self.shouldSuppressSocketCommandActivation()
            insideAllowsFocus = Self.socketCommandAllowsInAppFocusMutations()
            return 0
        }
        return (
            insideSuppressed: insideSuppressed,
            insideAllowsFocus: insideAllowsFocus,
            outsideSuppressed: Self.shouldSuppressSocketCommandActivation(),
            outsideAllowsFocus: Self.socketCommandAllowsInAppFocusMutations()
        )
    }
#endif

    nonisolated static func shouldReplaceStatusEntry(
        current: SidebarStatusEntry?,
        key: String,
        value: String,
        icon: String?,
        color: String?,
        url: URL?,
        priority: Int,
        format: SidebarMetadataFormat
    ) -> Bool {
        guard let current else { return true }
        return current.key != key ||
            current.value != value ||
            current.icon != icon ||
            current.color != color ||
            current.url != url ||
            current.priority != priority ||
            current.format != format
    }

    nonisolated static func shouldReplaceMetadataBlock(
        current: SidebarMetadataBlock?,
        key: String,
        markdown: String,
        priority: Int
    ) -> Bool {
        guard let current else { return true }
        return current.key != key || current.markdown != markdown || current.priority != priority
    }

    nonisolated static func shouldReplaceProgress(
        current: SidebarProgressState?,
        value: Double,
        label: String?
    ) -> Bool {
        guard let current else { return true }
        return current.value != value || current.label != label
    }

    nonisolated static func shouldReplaceGitBranch(
        current: SidebarGitBranchState?,
        branch: String,
        isDirty: Bool
    ) -> Bool {
        guard let current else { return true }
        return current.branch != branch || current.isDirty != isDirty
    }

    nonisolated static func shouldReplacePullRequest(
        current: SidebarPullRequestState?,
        number: Int,
        label: String,
        url: URL,
        status: SidebarPullRequestStatus,
        branch: String?,
        checks: SidebarPullRequestChecksStatus?
    ) -> Bool {
        guard let current else { return true }
        let normalizedBranch = branch?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveBranch: String? = {
            if let normalizedBranch, !normalizedBranch.isEmpty {
                return normalizedBranch
            }
            guard current.number == number,
                  current.label == label,
                  current.url == url,
                  current.status == status else {
                return nil
            }
            return current.branch
        }()
        let effectiveChecks: SidebarPullRequestChecksStatus? = {
            if let checks {
                return checks
            }
            guard current.number == number,
                  current.label == label,
                  current.url == url,
                  current.status == status else {
                return nil
            }
            return current.checks
        }()
        return current.number != number
            || current.label != label
            || current.url != url
            || current.status != status
            || current.branch != effectiveBranch
            || current.checks != effectiveChecks
    }

    nonisolated static func shouldReplacePorts(current: [Int]?, next: [Int]) -> Bool {
        let currentSorted = Array(Set(current ?? [])).sorted()
        let nextSorted = Array(Set(next)).sorted()
        return currentSorted != nextSorted
    }

    private struct SocketSurfaceKey: Hashable {
        let workspaceId: UUID
        let panelId: UUID
    }

    // `internal` (not `private`) so the dedup logic can be exercised by
    // `TerminalControllerSocketSecurityTests` via `@testable import` (regression #6618).
    final class SocketFastPathState: @unchecked Sendable {
        private let queue = DispatchQueue(label: "com.cmux.socket-fast-path")
        private var lastReportedDirectories: [SocketSurfaceKey: String] = [:]
        private var lastReportedShellStates: [SocketSurfaceKey: Workspace.PanelShellActivityState] = [:]
        private let maxTrackedDirectories = 4096
        private let maxTrackedShellStates = 4096

        func shouldPublishDirectory(workspaceId: UUID, panelId: UUID, directory: String) -> Bool {
            let key = SocketSurfaceKey(workspaceId: workspaceId, panelId: panelId)
            return queue.sync {
                if lastReportedDirectories[key] == directory {
                    return false
                }
                if lastReportedDirectories.count >= maxTrackedDirectories {
                    lastReportedDirectories.removeAll(keepingCapacity: true)
                }
                lastReportedDirectories[key] = directory
                return true
            }
        }

        /// Returns `true` when the incoming state differs from the last *applied* state,
        /// meaning the report is worth dispatching to the main thread.
        ///
        /// This method only reads the dedup dict; it does NOT record the new state.
        /// Call `recordShellActivity` after the update is confirmed applied on the main
        /// thread so that a failed apply (panel absent) never suppresses the next
        /// identical report.
        func shouldPublishShellActivity(
            workspaceId: UUID,
            panelId: UUID,
            state: Workspace.PanelShellActivityState
        ) -> Bool {
            let key = SocketSurfaceKey(workspaceId: workspaceId, panelId: panelId)
            return queue.sync {
                lastReportedShellStates[key] != state
            }
        }

        /// Records that the given state was successfully applied to the given panel.
        /// Must be called only when `updateSurfaceShellActivity` returned `true`.
        func recordShellActivity(
            workspaceId: UUID,
            panelId: UUID,
            state: Workspace.PanelShellActivityState
        ) {
            let key = SocketSurfaceKey(workspaceId: workspaceId, panelId: panelId)
            queue.async {
                if self.lastReportedShellStates.count >= self.maxTrackedShellStates {
                    self.lastReportedShellStates.removeAll(keepingCapacity: true)
                }
                self.lastReportedShellStates[key] = state
            }
        }
    }

    static let socketFastPathState = SocketFastPathState()
    nonisolated static func explicitSocketScope(
        options: [String: String]
    ) -> (workspaceId: UUID, panelId: UUID)? {
        guard let tabRaw = options["tab"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !tabRaw.isEmpty,
              let panelRaw = (options["panel"] ?? options["surface"])?.trimmingCharacters(in: .whitespacesAndNewlines),
              !panelRaw.isEmpty,
              let workspaceId = UUID(uuidString: tabRaw),
              let panelId = UUID(uuidString: panelRaw) else {
            return nil
        }
        return (workspaceId, panelId)
    }

    nonisolated static func normalizeReportedDirectory(_ directory: String) -> String {
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return directory }
        if trimmed.hasPrefix("file://"), let url = URL(string: trimmed), !url.path.isEmpty {
            return url.path
        }
        return trimmed
    }

    nonisolated static func normalizedExportedScreenPath(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed),
           url.isFileURL,
           !url.path.isEmpty {
            return url.path
        }
        return trimmed.hasPrefix("/") ? trimmed : nil
    }

    nonisolated static func shouldRemoveExportedScreenFile(
        fileURL: URL,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> Bool {
        let standardizedFile = fileURL.standardizedFileURL
        let temporary = temporaryDirectory.standardizedFileURL
        return standardizedFile.path.hasPrefix(temporary.path + "/")
    }

    nonisolated static func shouldRemoveExportedScreenDirectory(
        fileURL: URL,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> Bool {
        let directory = fileURL.deletingLastPathComponent().standardizedFileURL
        let temporary = temporaryDirectory.standardizedFileURL
        return directory.path.hasPrefix(temporary.path + "/")
    }

    nonisolated static func parseReportedShellActivityState(
        _ rawState: String
    ) -> Workspace.PanelShellActivityState? {
        switch rawState.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "prompt", "idle":
            return .promptIdle
        case "running", "busy", "command":
            return .commandRunning
        case "unknown", "clear":
            return .unknown
        default:
            return nil
        }
    }

    nonisolated static func parseRemotePortScanKickReason(
        _ rawReason: String
    ) -> WorkspaceRemoteSessionController.PortScanKickReason? {
        switch rawReason.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "command", "running", "foreground", "start":
            return .command
        case "refresh", "prompt", "idle":
            return .refresh
        default:
            return nil
        }
    }

    /// Update which window's TabManager receives socket commands.
    /// This is used when the user switches between multiple terminal windows.
    func setActiveTabManager(_ tabManager: TabManager?) {
        self.tabManager = tabManager
    }

    // MARK: - Process Ancestry Check

    /// Get the peer PID of a connected Unix domain socket using LOCAL_PEERPID.
    private nonisolated func getPeerPid(_ socket: Int32) -> pid_t? {
        var pid: pid_t = 0
        var pidSize = socklen_t(MemoryLayout<pid_t>.size)
        let result = getsockopt(socket, SOL_LOCAL, LOCAL_PEERPID, &pid, &pidSize)
        if result != 0 || pid <= 0 {
            return nil
        }
        return pid
    }

    /// Check if the peer has the same UID as this process using LOCAL_PEERCRED.
    /// This works even after the peer has disconnected (unlike LOCAL_PEERPID).
    private func peerHasSameUID(_ socket: Int32) -> Bool {
        var cred = xucred()
        var credLen = socklen_t(MemoryLayout<xucred>.size)
        let result = getsockopt(socket, SOL_LOCAL, LOCAL_PEERCRED, &cred, &credLen)
        guard result == 0 else { return false }
        return cred.cr_uid == getuid()
    }

    /// Check if `pid` is a descendant of this process by walking the process tree.
    func isDescendant(_ pid: pid_t) -> Bool {
        var current = pid
        // Walk up to 128 levels to avoid infinite loops from kernel bugs
        for _ in 0..<128 {
            if current == myPid {
                return true
            }
            if current <= 1 {
                return false
            }
            let parent = parentPid(of: current)
            if parent == current || parent < 0 {
                return false
            }
            current = parent
        }
        return false
    }

    /// Get the parent PID of a process using sysctl.
    private func parentPid(of pid: pid_t) -> pid_t {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else {
            return -1
        }
        return info.kp_eproc.e_ppid
    }

    nonisolated static func acceptErrorClassification(errnoCode: Int32) -> String {
        switch errnoCode {
        case EINTR, ECONNABORTED, EAGAIN, EWOULDBLOCK:
            return "immediate_retry"
        case EMFILE, ENFILE, ENOBUFS, ENOMEM:
            return "resource_pressure"
        case EBADF, EINVAL, ENOTSOCK:
            return "fatal"
        default:
            return "retry_with_backoff"
        }
    }

    nonisolated static func shouldRearmListenerForAcceptError(errnoCode: Int32) -> Bool {
        acceptErrorClassification(errnoCode: errnoCode) == "fatal"
    }

    nonisolated static func shouldRetryAcceptImmediately(errnoCode: Int32) -> Bool {
        acceptErrorClassification(errnoCode: errnoCode) == "immediate_retry"
    }

    nonisolated static func shouldRearmForConsecutiveAcceptFailures(consecutiveFailures: Int) -> Bool {
        consecutiveFailures >= acceptFailureRearmThreshold
    }

    nonisolated static func acceptFailureBackoffMilliseconds(consecutiveFailures: Int) -> Int {
        guard consecutiveFailures > 0 else { return 0 }
        var delay = acceptFailureBaseBackoffMs
        var remaining = consecutiveFailures - 1
        while remaining > 0 {
            if delay >= acceptFailureMaxBackoffMs {
                return acceptFailureMaxBackoffMs
            }
            delay = min(delay * 2, acceptFailureMaxBackoffMs)
            remaining -= 1
        }
        return delay
    }

    nonisolated static func acceptFailureRearmDelayMilliseconds(consecutiveFailures: Int) -> Int {
        max(
            acceptFailureBackoffMilliseconds(consecutiveFailures: consecutiveFailures),
            acceptFailureMinimumRearmDelayMs
        )
    }

    nonisolated static func acceptFailureRecoveryAction(
        errnoCode: Int32,
        consecutiveFailures: Int
    ) -> AcceptFailureRecoveryAction {
        let classification = acceptErrorClassification(errnoCode: errnoCode)
        if classification == "immediate_retry" {
            return .retryImmediately
        }

        if classification == "fatal"
            || shouldRearmForConsecutiveAcceptFailures(consecutiveFailures: consecutiveFailures) {
            return .rearmAfterDelay(
                delayMs: acceptFailureRearmDelayMilliseconds(
                    consecutiveFailures: consecutiveFailures
                )
            )
        }

        return .resumeAfterDelay(
            delayMs: acceptFailureBackoffMilliseconds(
                consecutiveFailures: consecutiveFailures
            )
        )
    }

    nonisolated static func shouldUnlinkSocketPathAfterAcceptLoopCleanup(
        pathMatches: Bool,
        isRunning: Bool,
        activeGeneration: UInt64,
        listenerStartInProgress: Bool
    ) -> Bool {
        guard pathMatches else { return false }
        guard !listenerStartInProgress else { return false }
        return !isRunning && activeGeneration == 0
    }

    private nonisolated static func unixSocketAddress(path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let maxLength = unixSocketPathMaxLength + 1
        var didFit = false
        path.withCString { source in
            let sourceLength = strlen(source)
            guard sourceLength < maxLength else { return }

            _ = withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
                buffer.initializeMemory(as: UInt8.self, repeating: 0)
            }
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                let destination = UnsafeMutableRawPointer(pathPtr).assumingMemoryBound(to: CChar.self)
                strncpy(destination, source, maxLength - 1)
            }
            didFit = true
        }
        return didFit ? addr : nil
    }

    private nonisolated static func bindUnixSocket(_ socket: Int32, path: String) -> Int32? {
        guard var addr = unixSocketAddress(path: path) else { return nil }
        return withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(socket, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    private nonisolated static func makeSocketTimeout(_ timeout: TimeInterval) -> timeval {
        let normalizedTimeout = max(timeout, 0)
        let seconds = floor(normalizedTimeout)
        let microseconds = (normalizedTimeout - seconds) * 1_000_000
        return timeval(tv_sec: Int(seconds), tv_usec: Int32(microseconds.rounded()))
    }

    private nonisolated static func configureSocketTimeouts(_ fd: Int32, timeout: TimeInterval) {
        var socketTimeout = makeSocketTimeout(timeout)
        _ = withUnsafePointer(to: &socketTimeout) { ptr in
            setsockopt(
                fd,
                SOL_SOCKET,
                SO_RCVTIMEO,
                ptr,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }
        _ = withUnsafePointer(to: &socketTimeout) { ptr in
            setsockopt(
                fd,
                SOL_SOCKET,
                SO_SNDTIMEO,
                ptr,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }
    }

    private nonisolated static func bindListenerSocket(_ socket: Int32, path: String) -> SocketBindAttemptResult {
        if let errnoCode = ensureSocketParentDirectoryExists(path: path) {
            return .failure(path: path, stage: "create_directory", errnoCode: errnoCode)
        }
        if unlink(path) != 0, errno != ENOENT {
            return .failure(path: path, stage: "unlink", errnoCode: errno)
        }

        guard let bindResult = bindUnixSocket(socket, path: path) else {
            return .pathTooLong(path: path)
        }
        guard bindResult >= 0 else {
            return .failure(path: path, stage: "bind", errnoCode: errno)
        }
        return .success(path: path)
    }

    private nonisolated static func ensureSocketParentDirectoryExists(path: String) -> Int32? {
        let parentURL = URL(fileURLWithPath: path).deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: parentURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            return nil
        } catch let error as NSError {
            if error.domain == NSPOSIXErrorDomain {
                return Int32(error.code)
            }
            return EIO
        }
    }

    nonisolated static func fallbackSocketPathAfterBindFailure(
        requestedPath: String,
        stage: String,
        errnoCode: Int32,
        currentUserID: uid_t = getuid()
    ) -> String? {
        guard requestedPath == SocketControlSettings.stableDefaultSocketPath else {
            return nil
        }

        switch stage {
        case "unlink" where errnoCode == EACCES || errnoCode == EPERM:
            return SocketControlSettings.userScopedStableSocketPath(currentUserID: currentUserID)
        case "bind" where errnoCode == EACCES || errnoCode == EPERM || errnoCode == EADDRINUSE:
            return SocketControlSettings.userScopedStableSocketPath(currentUserID: currentUserID)
        default:
            return nil
        }
    }

    func start(tabManager: TabManager, socketPath: String, accessMode: SocketControlMode) {
        self.tabManager = tabManager
        self.accessMode = accessMode

        let existing = withListenerState {
            (isRunning: isRunning, socketPath: self.socketPath, acceptLoopAlive: acceptLoopAlive)
        }

        if existing.isRunning && existing.socketPath == socketPath && existing.acceptLoopAlive {
            self.accessMode = accessMode
            applySocketPermissions()
            return
        }

        if existing.isRunning {
            stop()
        }

        var activeSocketPath = socketPath
        withListenerState {
            self.socketPath = activeSocketPath
            listenerStartInProgress = true
        }
        var listenerActivated = false
        defer {
            if !listenerActivated {
                withListenerState {
                    listenerStartInProgress = false
                }
            }
        }

        // Create socket
        let newServerSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard newServerSocket >= 0 else {
            print("TerminalController: Failed to create socket")
            return
        }

        var bindAttempt = Self.bindListenerSocket(newServerSocket, path: activeSocketPath)
        if case .failure(let failedPath, let failedStage, let failedErrnoCode) = bindAttempt,
           let fallbackPath = Self.fallbackSocketPathAfterBindFailure(
               requestedPath: failedPath,
               stage: failedStage,
               errnoCode: failedErrnoCode
           ),
           fallbackPath != failedPath {
            activeSocketPath = fallbackPath
            withListenerState {
                self.socketPath = activeSocketPath
            }
            bindAttempt = Self.bindListenerSocket(newServerSocket, path: activeSocketPath)
        }

        switch bindAttempt {
        case .success(let boundPath):
            activeSocketPath = boundPath
            withListenerState {
                self.socketPath = activeSocketPath
            }
        case .pathTooLong:
            close(newServerSocket)
            return
        case .failure:
            print("TerminalController: Failed to bind socket")
            close(newServerSocket)
            return
        }

        applySocketPermissions()

        // Listen
        guard listen(newServerSocket, Self.socketListenBacklog) >= 0 else {
            print("TerminalController: Failed to listen on socket")
            close(newServerSocket)
            return
        }

        SocketControlSettings.recordLastSocketPath(activeSocketPath)

        let generation = withListenerState {
            isRunning = true
            pendingAcceptLoopRearmGeneration = nil
            pendingAcceptLoopResumeGeneration = nil
            nextAcceptLoopGeneration &+= 1
            let generation = nextAcceptLoopGeneration
            activeAcceptLoopGeneration = generation
            serverSocket = newServerSocket
            listenerStartInProgress = false
            return generation
        }
        listenerActivated = true
        let listenerSocket = newServerSocket
        print("TerminalController: Listening on \(activeSocketPath)")
        NotificationCenter.default.post(
            name: .socketListenerDidStart,
            object: self,
            userInfo: ["path": activeSocketPath]
        )

        // Wire batched port scanner results back to workspace state.
        PortScanner.shared.onPortsUpdated = { [weak self] workspaceId, panelId, ports in
            guard let self, let tabManager = self.tabManager else { return }
            guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) else { return }
            let validSurfaceIds = Set(workspace.panels.keys)
            guard validSurfaceIds.contains(panelId) else { return }
            workspace.surfaceListeningPorts[panelId] = ports.isEmpty ? nil : ports
            workspace.recomputeListeningPorts()
        }
        PortScanner.shared.onAgentPortsUpdated = { [weak self] workspaceId, ports in
            guard let self, let tabManager = self.tabManager else { return }
            guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) else { return }
            if workspace.agentListeningPorts != ports {
                workspace.agentListeningPorts = ports
                workspace.recomputeListeningPorts()
            }
        }
        PortScanner.shared.agentPIDsProvider = { [weak self] workspaceIds in
            guard let self, let tabManager = self.tabManager else { return [:] }
            var pidsByWorkspace: [UUID: Set<Int>] = [:]
            for workspaceId in workspaceIds {
                guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) else { continue }
                let pids = Set(workspace.agentPIDs.values.compactMap { $0 > 0 ? Int($0) : nil })
                if !pids.isEmpty {
                    pidsByWorkspace[workspaceId] = pids
                }
            }
            return pidsByWorkspace
        }

        // Accept connections in background thread
        Thread.detachNewThread { [weak self] in
            self?.acceptLoop(listenerSocket: listenerSocket, generation: generation)
        }
    }

    nonisolated func socketListenerHealth(expectedSocketPath: String) -> SocketListenerHealth {
        let snapshot = listenerStateSnapshot()
        let pathMatches = snapshot.socketPath == expectedSocketPath

        var st = stat()
        let exists = lstat(expectedSocketPath, &st) == 0 && (st.st_mode & S_IFMT) == S_IFSOCK

        return SocketListenerHealth(
            isRunning: snapshot.isRunning,
            acceptLoopAlive: snapshot.acceptLoopAlive,
            socketPathMatches: pathMatches,
            socketPathExists: exists
        )
    }

    nonisolated static func probeSocketCommand(
        _ command: String,
        at socketPath: String,
        timeout: TimeInterval
    ) -> String? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        Self.configureSocketTimeouts(fd, timeout: timeout)

#if os(macOS)
        var noSigPipe: Int32 = 1
        _ = withUnsafePointer(to: &noSigPipe) { ptr in
            setsockopt(
                fd,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                ptr,
                socklen_t(MemoryLayout<Int32>.size)
            )
        }
#endif

        var addr = sockaddr_un()
        memset(&addr, 0, MemoryLayout<sockaddr_un>.size)
        addr.sun_family = sa_family_t(AF_UNIX)

        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        let pathBytes = Array(socketPath.utf8CString)
        guard pathBytes.count <= maxLen else { return nil }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            let raw = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self)
            memset(raw, 0, maxLen)
            for index in 0..<pathBytes.count {
                raw[index] = pathBytes[index]
            }
        }

        let pathOffset = MemoryLayout<sockaddr_un>.offset(of: \.sun_path) ?? 0
        let addrLen = socklen_t(pathOffset + pathBytes.count)
#if os(macOS)
        addr.sun_len = UInt8(min(Int(addrLen), 255))
#endif

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                connect(fd, sockaddrPtr, addrLen)
            }
        }
        guard connectResult == 0 else { return nil }

        let payload = command + "\n"
        let wroteAll = payload.withCString { cString in
            var remaining = strlen(cString)
            var pointer = UnsafeRawPointer(cString)
            while remaining > 0 {
                let written = write(fd, pointer, remaining)
                if written <= 0 { return false }
                remaining -= written
                pointer = pointer.advanced(by: written)
            }
            return true
        }
        guard wroteAll else { return nil }

        var buffer = [UInt8](repeating: 0, count: 4096)
        var response = ""

        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0 {
                let readErrno = errno
                if readErrno == EAGAIN || readErrno == EWOULDBLOCK {
                    break
                }
                return nil
            }
            if count == 0 {
                break
            }
            if let chunk = String(bytes: buffer[0..<count], encoding: .utf8) {
                response.append(chunk)
                if let newlineIndex = response.firstIndex(of: "\n") {
                    return String(response[..<newlineIndex])
                }
            }
        }

        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    nonisolated func stop() {
        let (socketToClose, socketPathToUnlink) = withListenerState {
            isRunning = false
            acceptLoopAlive = false
            pendingAcceptLoopRearmGeneration = nil
            pendingAcceptLoopResumeGeneration = nil
            listenerStartInProgress = false
            nextAcceptLoopGeneration &+= 1
            activeAcceptLoopGeneration = 0
            let socketToClose = serverSocket
            serverSocket = -1
            return (socketToClose, socketPath)
        }
        if socketToClose >= 0 {
            close(socketToClose)
        }
        unlink(socketPathToUnlink)
    }

    private nonisolated func unlinkSocketPathIfListenerStillInactive(_ path: String) {
        let shouldUnlink = withListenerState {
            Self.shouldUnlinkSocketPathAfterAcceptLoopCleanup(
                pathMatches: socketPath == path,
                isRunning: isRunning,
                activeGeneration: activeAcceptLoopGeneration,
                listenerStartInProgress: listenerStartInProgress
            )
        }
        if shouldUnlink {
            unlink(path)
        }
    }

    private func applySocketPermissions() {
        let permissions = mode_t(accessMode.socketFilePermissions)
        let currentSocketPath = withListenerState { socketPath }
        if chmod(currentSocketPath, permissions) != 0 {
            print(
                "TerminalController: Failed to set socket permissions to \(String(permissions, radix: 8)) for \(currentSocketPath)"
            )
        }
    }

    private func writeSocketResponse(_ response: String, to socket: Int32) {
        let payload = response + "\n"
        payload.withCString { ptr in
            _ = write(socket, ptr, strlen(ptr))
        }
    }

    private func passwordAuthRequiredResponse(for command: String) -> String {
        let message = "Authentication required. Send auth <password> first."
        guard command.hasPrefix("{"),
              let data = command.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] else {
            return "ERROR: Authentication required — send auth <password> first"
        }
        let id = dict["id"]
        return v2Error(id: id, code: "auth_required", message: message)
    }

    private func passwordLoginV1ResponseIfNeeded(for command: String, authenticated: inout Bool) -> String? {
        let lowered = command.lowercased()
        guard lowered == "auth" || lowered.hasPrefix("auth ") else {
            return nil
        }
        guard SocketControlPasswordStore.hasConfiguredPassword(allowLazyKeychainFallback: true) else {
            return "ERROR: Password mode is enabled but no socket password is configured in Settings."
        }

        let provided: String
        if lowered == "auth" {
            provided = ""
        } else {
            provided = String(command.dropFirst(5))
        }
        guard !provided.isEmpty else {
            return "ERROR: Missing password. Usage: auth <password>"
        }
        guard SocketControlPasswordStore.verify(password: provided, allowLazyKeychainFallback: true) else {
            return "ERROR: Invalid password"
        }
        authenticated = true
        return "OK: Authenticated"
    }

    private func passwordLoginV2ResponseIfNeeded(for command: String, authenticated: inout Bool) -> String? {
        guard command.hasPrefix("{"),
              let data = command.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] else {
            return nil
        }
        let id = dict["id"]
        let method = (dict["method"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard method == "auth.login" else {
            return nil
        }

        guard let params = dict["params"] as? [String: Any],
              let provided = params["password"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "auth.login requires params.password")
        }

        guard SocketControlPasswordStore.hasConfiguredPassword(allowLazyKeychainFallback: true) else {
            return v2Error(
                id: id,
                code: "auth_unconfigured",
                message: "Password mode is enabled but no socket password is configured in Settings."
            )
        }

        guard SocketControlPasswordStore.verify(password: provided, allowLazyKeychainFallback: true) else {
            return v2Error(id: id, code: "auth_failed", message: "Invalid password")
        }
        authenticated = true
        return v2Ok(id: id, result: ["authenticated": true])
    }

    private func authResponseIfNeeded(for command: String, authenticated: inout Bool) -> String? {
        guard accessMode.requiresPasswordAuth else {
            return nil
        }
        if let v2Response = passwordLoginV2ResponseIfNeeded(for: command, authenticated: &authenticated) {
            return v2Response
        }
        if let v1Response = passwordLoginV1ResponseIfNeeded(for: command, authenticated: &authenticated) {
            return v1Response
        }
        if !authenticated {
            return passwordAuthRequiredResponse(for: command)
        }
        return nil
    }

    private nonisolated func acceptLoop(listenerSocket: Int32, generation: UInt64) {
        let armedAcceptLoop = withListenerState {
            guard generation == activeAcceptLoopGeneration else { return false }
            acceptLoopAlive = true
            return true
        }
        guard armedAcceptLoop else {
            return
        }

        var exitReason = "stopped"
        var rearmRequested = false
        var resumeRequested = false

        defer {
            let cleanup = withListenerState {
                guard generation == activeAcceptLoopGeneration else {
                    return (
                        shouldCaptureExit: false,
                        socketToClose: Int32(-1),
                        pathToUnlink: nil as String?
                    )
                }

                if resumeRequested && exitReason == "accept_backoff_resume" {
                    acceptLoopAlive = false
                    return (
                        shouldCaptureExit: false,
                        socketToClose: Int32(-1),
                        pathToUnlink: nil as String?
                    )
                }

                if isRunning && exitReason == "stopped" {
                    exitReason = "unexpected_loop_exit"
                }
                let shouldCaptureExit = exitReason != "stopped"

                acceptLoopAlive = false
                isRunning = false
                activeAcceptLoopGeneration = 0
                pendingAcceptLoopResumeGeneration = nil

                var socketToClose: Int32 = -1
                var pathToUnlink: String?
                if serverSocket == listenerSocket {
                    socketToClose = serverSocket
                    serverSocket = -1
                    if shouldCaptureExit {
                        pathToUnlink = socketPath
                    }
                }
                return (shouldCaptureExit, socketToClose, pathToUnlink)
            }

            if cleanup.socketToClose >= 0 {
                close(cleanup.socketToClose)
            }
            if let pathToUnlink = cleanup.pathToUnlink {
                unlinkSocketPathIfListenerStillInactive(pathToUnlink)
            }

        }

        var consecutiveFailures = 0

        while shouldContinueAcceptLoop(generation: generation) {
            var clientAddr = sockaddr_un()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)

            let clientSocket = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    accept(listenerSocket, sockaddrPtr, &clientAddrLen)
                }
            }

            guard clientSocket >= 0 else {
                if !shouldContinueAcceptLoop(generation: generation) {
                    exitReason = "stopped"
                    break
                }

                let errnoCode = errno

                if Self.shouldRetryAcceptImmediately(errnoCode: errnoCode) {
                    continue
                }

                consecutiveFailures += 1
                let recoveryAction = Self.acceptFailureRecoveryAction(
                    errnoCode: errnoCode,
                    consecutiveFailures: consecutiveFailures
                )

                let shouldRearmForFatalErrno = Self.shouldRearmListenerForAcceptError(errnoCode: errnoCode)

                if case .rearmAfterDelay(let delayMs) = recoveryAction {
                    exitReason = shouldRearmForFatalErrno
                        ? "fatal_accept_error"
                        : "persistent_accept_failures"
                    rearmRequested = true
                    withListenerState {
                        pendingAcceptLoopRearmGeneration = generation
                    }
                    scheduleListenerRearm(
                        generation: generation,
                        delayMs: delayMs
                    )
                    break
                }

                if case .resumeAfterDelay(let delayMs) = recoveryAction {
                    exitReason = "accept_backoff_resume"
                    resumeRequested = true
                    withListenerState {
                        pendingAcceptLoopResumeGeneration = generation
                    }
                    scheduleAcceptLoopResume(
                        listenerSocket: listenerSocket,
                        generation: generation,
                        delayMs: delayMs
                    )
                    break
                }

                continue
            }

            consecutiveFailures = 0

            // Capture peer PID immediately — before the client can disconnect.
            // ncat --send-only closes the connection right after writing, so by
            // the time a new thread starts the peer may already be gone.
            let peerPid = getPeerPid(clientSocket)

            // Handle client in new thread
            Thread.detachNewThread { [weak self] in
                self?.handleClient(clientSocket, peerPid: peerPid)
            }
        }
    }

    private nonisolated func scheduleAcceptLoopResume(
        listenerSocket: Int32,
        generation: UInt64,
        delayMs: Int
    ) {
        let deadline = DispatchTime.now() + .milliseconds(delayMs)
        DispatchQueue.main.asyncAfter(deadline: deadline) { [weak self] in
            guard let self else { return }
            let shouldResume = self.withListenerState {
                guard self.pendingAcceptLoopResumeGeneration == generation else { return false }
                guard self.activeAcceptLoopGeneration == generation else {
                    self.pendingAcceptLoopResumeGeneration = nil
                    return false
                }
                guard self.isRunning, self.serverSocket == listenerSocket else {
                    self.pendingAcceptLoopResumeGeneration = nil
                    return false
                }
                self.pendingAcceptLoopResumeGeneration = nil
                return true
            }
            guard shouldResume else { return }

            Thread.detachNewThread { [weak self] in
                self?.acceptLoop(listenerSocket: listenerSocket, generation: generation)
            }
        }
    }

    private nonisolated func scheduleListenerRearm(
        generation: UInt64,
        delayMs: Int
    ) {
        let deadline = DispatchTime.now() + .milliseconds(delayMs)
        DispatchQueue.main.asyncAfter(deadline: deadline) { [weak self] in
            guard let self else { return }
            guard let tabManager = self.tabManager else { return }
            guard let restartPath = self.withListenerState({ () -> String? in
                guard self.pendingAcceptLoopRearmGeneration == generation else { return nil }
                self.pendingAcceptLoopRearmGeneration = nil
                return self.socketPath
            }) else { return }

            let restartMode = self.accessMode

            self.stop()
            self.start(tabManager: tabManager, socketPath: restartPath, accessMode: restartMode)
        }
    }

    private func handleClient(_ socket: Int32, peerPid: pid_t? = nil) {
        defer { close(socket) }

        // In cmuxOnly mode, verify the connecting process is a descendant of cmux.
        // In allowAll mode (env-var only), skip the ancestry check.
        if accessMode == .cmuxOnly {
            // Use pre-captured peer PID if available (captured in accept loop before
            // the peer can disconnect), falling back to live lookup.
            let pid = peerPid ?? getPeerPid(socket)
            if let pid {
                guard isDescendant(pid) else {
                    let msg = "ERROR: Access denied — only processes started inside cmux can connect\n"
                    msg.withCString { ptr in _ = write(socket, ptr, strlen(ptr)) }
                    return
                }
            }
            // If pid is nil, LOCAL_PEERPID failed (peer disconnected before we
            // could read it — common with ncat --send-only). We still verify the
            // peer runs as the same user via LOCAL_PEERCRED. This is the same
            // security boundary as the socket file permissions (0600), so it does
            // not widen the attack surface. We also require that the peer actually
            // sent data (checked in the read loop below) — a connect-only probe
            // with no data is harmless.
            if pid == nil {
                guard peerHasSameUID(socket) else {
                    let msg = "ERROR: Unable to verify client process\n"
                    msg.withCString { ptr in _ = write(socket, ptr, strlen(ptr)) }
                    return
                }
            }
        }

        var buffer = [UInt8](repeating: 0, count: 4096)
        var pending = ""
        var authenticated = false

        while withListenerState({ isRunning }) {
            let bytesRead = read(socket, &buffer, buffer.count - 1)
            guard bytesRead > 0 else { break }

            let chunk = String(bytes: buffer[0..<bytesRead], encoding: .utf8) ?? ""
            pending.append(chunk)

            while let newlineIndex = pending.firstIndex(of: "\n") {
                let line = String(pending[..<newlineIndex])
                pending = String(pending[pending.index(after: newlineIndex)...])
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }

                if let authResponse = authResponseIfNeeded(for: trimmed, authenticated: &authenticated) {
                    writeSocketResponse(authResponse, to: socket)
                    continue
                }

                let response = processCommand(trimmed)
                writeSocketResponse(response, to: socket)
            }
        }
    }

    private func processCommand(_ command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "ERROR: Empty command" }

        // The v1 line-based protocol was removed; v2 JSON-RPC is the only protocol.
        // Stale clients still speaking v1 get a terse, identifiable error rather than
        // a confusing JSON parse failure.
        guard trimmed.hasPrefix("{") else {
            return v2Error(
                id: nil,
                code: "v1_removed",
                message: "The v1 line-based socket protocol has been removed. Use the v2 JSON-RPC protocol (see docs/v2-api-migration.md)."
            )
        }

        return processV2Command(trimmed)
    }

    // MARK: - V2 JSON Socket Protocol

    private func processV2Command(_ jsonLine: String) -> String {
        // v1 access-mode gating applies to v2 as well. We can't know which v2 method maps
        // to which v1 command without parsing, so parse first and then apply allow-list.

        guard let data = jsonLine.data(using: .utf8) else {
            return v2Encode(["ok": false, "error": ["code": "invalid_utf8", "message": "Invalid UTF-8"]])
        }

        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            return v2Encode(["ok": false, "error": ["code": "parse_error", "message": "Invalid JSON"]])
        }

        guard let dict = object as? [String: Any] else {
            return v2Encode(["ok": false, "error": ["code": "invalid_request", "message": "Expected JSON object"]])
        }

        let id: Any? = dict["id"]
        let method = (dict["method"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let params = dict["params"] as? [String: Any] ?? [:]

        guard !method.isEmpty else {
            return v2Error(id: id, code: "invalid_request", message: "Missing method")
        }

        v2MainSync { self.v2RefreshKnownRefs() }

        return withSocketCommandPolicy(commandKey: method, isV2: true) {
            switch method {
        case "system.ping":
            return v2Ok(id: id, result: ["pong": true])
        case "system.capabilities":
            return v2Ok(id: id, result: v2Capabilities())

        case "system.identify":
            return v2Ok(id: id, result: v2Identify(params: params))
        case "system.tree":
            return v2Result(id: id, self.v2SystemTree(params: params))
        case "auth.login":
            return v2Ok(
                id: id,
                result: [
                    "authenticated": true,
                    "required": accessMode.requiresPasswordAuth
                ]
            )

        // Windows
        case "window.list":
            return v2Result(id: id, self.v2WindowList(params: params))
        case "window.current":
            return v2Result(id: id, self.v2WindowCurrent(params: params))
        case "window.focus":
            return v2Result(id: id, self.v2WindowFocus(params: params))
        case "window.create":
            return v2Result(id: id, self.v2WindowCreate(params: params))
        case "window.close":
            return v2Result(id: id, self.v2WindowClose(params: params))

        // Workspaces
        case "workspace.list":
            return v2Result(id: id, self.v2WorkspaceList(params: params))
        case "workspace.create":
            return v2Result(id: id, self.v2WorkspaceCreate(params: params))
        case "workspace.select":
            return v2Result(id: id, self.v2WorkspaceSelect(params: params))
        case "workspace.current":
            return v2Result(id: id, self.v2WorkspaceCurrent(params: params))
        case "workspace.close":
            return v2Result(id: id, self.v2WorkspaceClose(params: params))
        case "workspace.move_to_window":
            return v2Result(id: id, self.v2WorkspaceMoveToWindow(params: params))
        case "workspace.reorder":
            return v2Result(id: id, self.v2WorkspaceReorder(params: params))
        case "workspace.rename":
            return v2Result(id: id, self.v2WorkspaceRename(params: params))
        case "workspace.action":
            return v2Result(id: id, self.v2WorkspaceAction(params: params))
        case "workspace.next":
            return v2Result(id: id, self.v2WorkspaceNext(params: params))
        case "workspace.previous":
            return v2Result(id: id, self.v2WorkspacePrevious(params: params))
        case "workspace.last":
            return v2Result(id: id, self.v2WorkspaceLast(params: params))
        case "workspace.equalize_splits":
            return v2Result(id: id, self.v2WorkspaceEqualizeSplits(params: params))
        case "workspace.remote.configure":
            return v2Result(id: id, self.v2WorkspaceRemoteConfigure(params: params))
        case "workspace.remote.foreground_auth_ready":
            return v2Result(id: id, self.v2WorkspaceRemoteForegroundAuthReady(params: params))
        case "workspace.remote.reconnect":
            return v2Result(id: id, self.v2WorkspaceRemoteReconnect(params: params))
        case "workspace.remote.disconnect":
            return v2Result(id: id, self.v2WorkspaceRemoteDisconnect(params: params))
        case "workspace.remote.status":
            return v2Result(id: id, self.v2WorkspaceRemoteStatus(params: params))
        case "workspace.remote.terminal_session_end":
            return v2Result(id: id, self.v2WorkspaceRemoteTerminalSessionEnd(params: params))
        case "workspace.set_status":
            return v2Result(id: id, self.v2WorkspaceSetStatus(params: params))
        case "workspace.clear_status":
            return v2Result(id: id, self.v2WorkspaceClearStatus(params: params))
        case "workspace.list_status":
            return v2Result(id: id, self.v2WorkspaceListStatus(params: params))
        case "workspace.log":
            return v2Result(id: id, self.v2WorkspaceLog(params: params))
        case "workspace.clear_log":
            return v2Result(id: id, self.v2WorkspaceClearLog(params: params))
        case "workspace.list_log":
            return v2Result(id: id, self.v2WorkspaceListLog(params: params))
        case "workspace.set_progress":
            return v2Result(id: id, self.v2WorkspaceSetProgress(params: params))
        case "workspace.clear_progress":
            return v2Result(id: id, self.v2WorkspaceClearProgress(params: params))
        case "workspace.sidebar_state":
            return v2Result(id: id, self.v2WorkspaceSidebarState(params: params))
        case "workspace.clear_agent_pid":
            return v2Result(id: id, self.v2WorkspaceClearAgentPID(params: params))
        case "workspace.set_agent_pid":
            return v2Result(id: id, self.v2WorkspaceSetAgentPID(params: params))
        case "workspace.report_meta_block":
            return v2Result(id: id, self.v2WorkspaceReportMetaBlock(params: params))
        case "workspace.clear_meta_block":
            return v2Result(id: id, self.v2WorkspaceClearMetaBlock(params: params))
        case "workspace.list_meta_blocks":
            return v2Result(id: id, self.v2WorkspaceListMetaBlocks(params: params))
        case "workspace.reset_sidebar":
            return v2Result(id: id, self.v2WorkspaceResetSidebar(params: params))

        // Settings
        case "settings.open":
            return v2Result(id: id, self.v2SettingsOpen(params: params))

        // Feedback
        case "feedback.open":
            return v2Result(id: id, self.v2FeedbackOpen(params: params))
        case "feedback.submit":
            return v2Result(id: id, self.v2FeedbackSubmit(params: params))

        // Surfaces / input
        case "surface.list":
            return v2Result(id: id, self.v2SurfaceList(params: params))
        case "surface.current":
            return v2Result(id: id, self.v2SurfaceCurrent(params: params))
        case "surface.focus":
            return v2Result(id: id, self.v2SurfaceFocus(params: params))
        case "surface.split":
            return v2Result(id: id, self.v2SurfaceSplit(params: params))
        case "surface.create":
            return v2Result(id: id, self.v2SurfaceCreate(params: params))
        case "surface.close":
            return v2Result(id: id, self.v2SurfaceClose(params: params))
        case "surface.move":
            return v2Result(id: id, self.v2SurfaceMove(params: params))
        case "surface.reorder":
            return v2Result(id: id, self.v2SurfaceReorder(params: params))
        case "surface.action":
            return v2Result(id: id, self.v2TabAction(params: params))
        case "tab.action":
            return v2Result(id: id, self.v2TabAction(params: params))
        case "surface.drag_to_split":
            return v2Result(id: id, self.v2SurfaceDragToSplit(params: params))
        case "surface.refresh":
            return v2Result(id: id, self.v2SurfaceRefresh(params: params))
        case "surface.health":
            return v2Result(id: id, self.v2SurfaceHealth(params: params))
        case "debug.terminals":
            return v2Result(id: id, self.v2DebugTerminals(params: params))
        case "surface.send_text":
            return v2Result(id: id, self.v2SurfaceSendText(params: params))
        case "surface.send_key":
            return v2Result(id: id, self.v2SurfaceSendKey(params: params))
        case "surface.report_tty":
            return v2Result(id: id, self.v2SurfaceReportTTY(params: params))
        case "surface.ports_kick":
            return v2Result(id: id, self.v2SurfacePortsKick(params: params))
        case "surface.clear_history":
            return v2Result(id: id, self.v2SurfaceClearHistory(params: params))
        case "surface.trigger_flash":
            return v2Result(id: id, self.v2SurfaceTriggerFlash(params: params))
        case "surface.report_pwd":
            return v2Result(id: id, self.v2SurfaceReportPwd(params: params))
        case "surface.report_shell_state":
            return v2Result(id: id, self.v2SurfaceReportShellState(params: params))
        case "surface.report_git_branch":
            return v2Result(id: id, self.v2SurfaceReportGitBranch(params: params))
        case "surface.clear_git_branch":
            return v2Result(id: id, self.v2SurfaceClearGitBranch(params: params))
        case "surface.report_pr":
            return v2Result(id: id, self.v2SurfaceReportPullRequest(params: params))
        case "surface.clear_pr":
            return v2Result(id: id, self.v2SurfaceClearPullRequest(params: params))
        case "surface.report_ports":
            return v2Result(id: id, self.v2SurfaceReportPorts(params: params))
        case "surface.clear_ports":
            return v2Result(id: id, self.v2SurfaceClearPorts(params: params))

        // Panes
        case "pane.list":
            return v2Result(id: id, self.v2PaneList(params: params))
        case "pane.focus":
            return v2Result(id: id, self.v2PaneFocus(params: params))
        case "pane.surfaces":
            return v2Result(id: id, self.v2PaneSurfaces(params: params))
        case "pane.create":
            return v2Result(id: id, self.v2PaneCreate(params: params))
        case "pane.resize":
            return v2Result(id: id, self.v2PaneResize(params: params))
        case "pane.swap":
            return v2Result(id: id, self.v2PaneSwap(params: params))
        case "pane.break":
            return v2Result(id: id, self.v2PaneBreak(params: params))
        case "pane.join":
            return v2Result(id: id, self.v2PaneJoin(params: params))
        case "pane.last":
            return v2Result(id: id, self.v2PaneLast(params: params))

        // Notifications
        case "notification.create":
            return v2Result(id: id, self.v2NotificationCreate(params: params))
        case "notification.create_for_surface":
            return v2Result(id: id, self.v2NotificationCreateForSurface(params: params))
        case "notification.create_for_target":
            return v2Result(id: id, self.v2NotificationCreateForTarget(params: params))
        case "notification.list":
            return v2Ok(id: id, result: self.v2NotificationList())
        case "notification.clear":
            return v2Result(id: id, self.v2NotificationClear(params: params))

        // App focus
        case "app.focus_override.set":
            return v2Result(id: id, self.v2AppFocusOverride(params: params))
        case "app.simulate_active":
            return v2Result(id: id, self.v2AppSimulateActive())
        case "app.reload_config":
            return v2Result(id: id, self.v2AppReloadConfig(params: params))

        // Browser
        case "browser.open_split":
            return v2Result(id: id, self.v2BrowserOpenSplit(params: params))
        case "browser.navigate":
            return v2Result(id: id, self.v2BrowserNavigate(params: params))
        case "browser.back":
            return v2Result(id: id, self.v2BrowserBack(params: params))
        case "browser.forward":
            return v2Result(id: id, self.v2BrowserForward(params: params))
        case "browser.reload":
            return v2Result(id: id, self.v2BrowserReload(params: params))
        case "browser.url.get":
            return v2Result(id: id, self.v2BrowserGetURL(params: params))
        case "browser.focus_webview":
            return v2Result(id: id, self.v2BrowserFocusWebView(params: params))
        case "browser.is_webview_focused":
            return v2Result(id: id, self.v2BrowserIsWebViewFocused(params: params))
        case "browser.snapshot":
            return v2Result(id: id, self.v2BrowserSnapshot(params: params))
        case "browser.eval":
            return v2Result(id: id, self.v2BrowserEval(params: params))
        case "browser.wait":
            return v2Result(id: id, self.v2BrowserWait(params: params))
        case "browser.click":
            return v2Result(id: id, self.v2BrowserClick(params: params))
        case "browser.dblclick":
            return v2Result(id: id, self.v2BrowserDblClick(params: params))
        case "browser.hover":
            return v2Result(id: id, self.v2BrowserHover(params: params))
        case "browser.focus":
            return v2Result(id: id, self.v2BrowserFocusElement(params: params))
        case "browser.type":
            return v2Result(id: id, self.v2BrowserType(params: params))
        case "browser.fill":
            return v2Result(id: id, self.v2BrowserFill(params: params))
        case "browser.press":
            return v2Result(id: id, self.v2BrowserPress(params: params))
        case "browser.keydown":
            return v2Result(id: id, self.v2BrowserKeyDown(params: params))
        case "browser.keyup":
            return v2Result(id: id, self.v2BrowserKeyUp(params: params))
        case "browser.check":
            return v2Result(id: id, self.v2BrowserCheck(params: params, checked: true))
        case "browser.uncheck":
            return v2Result(id: id, self.v2BrowserCheck(params: params, checked: false))
        case "browser.select":
            return v2Result(id: id, self.v2BrowserSelect(params: params))
        case "browser.scroll":
            return v2Result(id: id, self.v2BrowserScroll(params: params))
        case "browser.scroll_into_view":
            return v2Result(id: id, self.v2BrowserScrollIntoView(params: params))
        case "browser.screenshot":
            return v2Result(id: id, self.v2BrowserScreenshot(params: params))
        case "browser.get.text":
            return v2Result(id: id, self.v2BrowserGetText(params: params))
        case "browser.get.html":
            return v2Result(id: id, self.v2BrowserGetHTML(params: params))
        case "browser.get.value":
            return v2Result(id: id, self.v2BrowserGetValue(params: params))
        case "browser.get.attr":
            return v2Result(id: id, self.v2BrowserGetAttr(params: params))
        case "browser.get.title":
            return v2Result(id: id, self.v2BrowserGetTitle(params: params))
        case "browser.get.count":
            return v2Result(id: id, self.v2BrowserGetCount(params: params))
        case "browser.get.box":
            return v2Result(id: id, self.v2BrowserGetBox(params: params))
        case "browser.get.styles":
            return v2Result(id: id, self.v2BrowserGetStyles(params: params))
        case "browser.is.visible":
            return v2Result(id: id, self.v2BrowserIsVisible(params: params))
        case "browser.is.enabled":
            return v2Result(id: id, self.v2BrowserIsEnabled(params: params))
        case "browser.is.checked":
            return v2Result(id: id, self.v2BrowserIsChecked(params: params))
        case "browser.find.role":
            return v2Result(id: id, self.v2BrowserFindRole(params: params))
        case "browser.find.text":
            return v2Result(id: id, self.v2BrowserFindText(params: params))
        case "browser.find.label":
            return v2Result(id: id, self.v2BrowserFindLabel(params: params))
        case "browser.find.placeholder":
            return v2Result(id: id, self.v2BrowserFindPlaceholder(params: params))
        case "browser.find.alt":
            return v2Result(id: id, self.v2BrowserFindAlt(params: params))
        case "browser.find.title":
            return v2Result(id: id, self.v2BrowserFindTitle(params: params))
        case "browser.find.testid":
            return v2Result(id: id, self.v2BrowserFindTestId(params: params))
        case "browser.find.first":
            return v2Result(id: id, self.v2BrowserFindFirst(params: params))
        case "browser.find.last":
            return v2Result(id: id, self.v2BrowserFindLast(params: params))
        case "browser.find.nth":
            return v2Result(id: id, self.v2BrowserFindNth(params: params))
        case "browser.frame.select":
            return v2Result(id: id, self.v2BrowserFrameSelect(params: params))
        case "browser.frame.main":
            return v2Result(id: id, self.v2BrowserFrameMain(params: params))
        case "browser.dialog.accept":
            return v2Result(id: id, self.v2BrowserDialogRespond(params: params, accept: true))
        case "browser.dialog.dismiss":
            return v2Result(id: id, self.v2BrowserDialogRespond(params: params, accept: false))
        case "browser.download.wait":
            return v2Result(id: id, self.v2BrowserDownloadWait(params: params))
        case "browser.cookies.get":
            return v2Result(id: id, self.v2BrowserCookiesGet(params: params))
        case "browser.cookies.set":
            return v2Result(id: id, self.v2BrowserCookiesSet(params: params))
        case "browser.cookies.clear":
            return v2Result(id: id, self.v2BrowserCookiesClear(params: params))
        case "browser.storage.get":
            return v2Result(id: id, self.v2BrowserStorageGet(params: params))
        case "browser.storage.set":
            return v2Result(id: id, self.v2BrowserStorageSet(params: params))
        case "browser.storage.clear":
            return v2Result(id: id, self.v2BrowserStorageClear(params: params))
        case "browser.tab.new":
            return v2Result(id: id, self.v2BrowserTabNew(params: params))
        case "browser.tab.list":
            return v2Result(id: id, self.v2BrowserTabList(params: params))
        case "browser.tab.switch":
            return v2Result(id: id, self.v2BrowserTabSwitch(params: params))
        case "browser.tab.close":
            return v2Result(id: id, self.v2BrowserTabClose(params: params))
        case "browser.console.list":
            return v2Result(id: id, self.v2BrowserConsoleList(params: params))
        case "browser.console.clear":
            return v2Result(id: id, self.v2BrowserConsoleClear(params: params))
        case "browser.errors.list":
            return v2Result(id: id, self.v2BrowserErrorsList(params: params))
        case "browser.highlight":
            return v2Result(id: id, self.v2BrowserHighlight(params: params))
        case "browser.state.save":
            return v2Result(id: id, self.v2BrowserStateSave(params: params))
        case "browser.state.load":
            return v2Result(id: id, self.v2BrowserStateLoad(params: params))
        case "browser.addinitscript":
            return v2Result(id: id, self.v2BrowserAddInitScript(params: params))
        case "browser.addscript":
            return v2Result(id: id, self.v2BrowserAddScript(params: params))
        case "browser.addstyle":
            return v2Result(id: id, self.v2BrowserAddStyle(params: params))
        case "browser.viewport.set":
            return v2Result(id: id, self.v2BrowserViewportSet(params: params))
        case "browser.geolocation.set":
            return v2Result(id: id, self.v2BrowserGeolocationSet(params: params))
        case "browser.offline.set":
            return v2Result(id: id, self.v2BrowserOfflineSet(params: params))
        case "browser.trace.start":
            return v2Result(id: id, self.v2BrowserTraceStart(params: params))
        case "browser.trace.stop":
            return v2Result(id: id, self.v2BrowserTraceStop(params: params))
        case "browser.network.route":
            return v2Result(id: id, self.v2BrowserNetworkRoute(params: params))
        case "browser.network.unroute":
            return v2Result(id: id, self.v2BrowserNetworkUnroute(params: params))
        case "browser.network.requests":
            return v2Result(id: id, self.v2BrowserNetworkRequests(params: params))
        case "browser.screencast.start":
            return v2Result(id: id, self.v2BrowserScreencastStart(params: params))
        case "browser.screencast.stop":
            return v2Result(id: id, self.v2BrowserScreencastStop(params: params))
        case "browser.input_mouse":
            return v2Result(id: id, self.v2BrowserInputMouse(params: params))
        case "browser.input_keyboard":
            return v2Result(id: id, self.v2BrowserInputKeyboard(params: params))
        case "browser.input_touch":
            return v2Result(id: id, self.v2BrowserInputTouch(params: params))

        // Markdown
        case "markdown.open":
            return v2Result(id: id, self.v2MarkdownOpen(params: params))

        case "surface.read_text":
            return v2Result(id: id, self.v2SurfaceReadText(params: params))

#if DEBUG
        // Debug / test-only
        case "debug.shortcut.set":
            return v2Result(id: id, self.v2DebugShortcutSet(params: params))
        case "debug.shortcut.simulate":
            return v2Result(id: id, self.v2DebugShortcutSimulate(params: params))
        case "debug.type":
            return v2Result(id: id, self.v2DebugType(params: params))
        case "debug.app.activate":
            return v2Result(id: id, self.v2DebugActivateApp())
        case "debug.command_palette.toggle":
            return v2Result(id: id, self.v2DebugToggleCommandPalette(params: params))
        case "debug.command_palette.rename_tab.open":
            return v2Result(id: id, self.v2DebugOpenCommandPaletteRenameTabInput(params: params))
        case "debug.command_palette.visible":
            return v2Result(id: id, self.v2DebugCommandPaletteVisible(params: params))
        case "debug.command_palette.selection":
            return v2Result(id: id, self.v2DebugCommandPaletteSelection(params: params))
        case "debug.command_palette.results":
            return v2Result(id: id, self.v2DebugCommandPaletteResults(params: params))
        case "debug.command_palette.rename_input.interact":
            return v2Result(id: id, self.v2DebugCommandPaletteRenameInputInteraction(params: params))
        case "debug.command_palette.rename_input.delete_backward":
            return v2Result(id: id, self.v2DebugCommandPaletteRenameInputDeleteBackward(params: params))
        case "debug.command_palette.rename_input.selection":
            return v2Result(id: id, self.v2DebugCommandPaletteRenameInputSelection(params: params))
        case "debug.command_palette.rename_input.select_all":
            return v2Result(id: id, self.v2DebugCommandPaletteRenameInputSelectAll(params: params))
        case "debug.browser.address_bar_focused":
            return v2Result(id: id, self.v2DebugBrowserAddressBarFocused(params: params))
        case "debug.browser.favicon":
            return v2Result(id: id, self.v2DebugBrowserFavicon(params: params))
        case "debug.sidebar.visible":
            return v2Result(id: id, self.v2DebugSidebarVisible(params: params))
        case "debug.terminal.is_focused":
            return v2Result(id: id, self.v2DebugIsTerminalFocused(params: params))
        case "debug.terminal.read_text":
            return v2Result(id: id, self.v2DebugReadTerminalText(params: params))
        case "debug.terminal.render_stats":
            return v2Result(id: id, self.v2DebugRenderStats(params: params))
        case "debug.layout":
            return v2Result(id: id, self.v2DebugLayout())
        case "debug.portal.stats":
            return v2Result(id: id, self.v2DebugPortalStats())
        case "debug.bonsplit_underflow.count":
            return v2Result(id: id, self.v2DebugBonsplitUnderflowCount())
        case "debug.bonsplit_underflow.reset":
            return v2Result(id: id, self.v2DebugResetBonsplitUnderflowCount())
        case "debug.empty_panel.count":
            return v2Result(id: id, self.v2DebugEmptyPanelCount())
        case "debug.empty_panel.reset":
            return v2Result(id: id, self.v2DebugResetEmptyPanelCount())
        case "debug.notification.focus":
            return v2Result(id: id, self.v2DebugFocusNotification(params: params))
        case "debug.flash.count":
            return v2Result(id: id, self.v2DebugFlashCount(params: params))
        case "debug.flash.reset":
            return v2Result(id: id, self.v2DebugResetFlashCounts())
        case "debug.panel_snapshot":
            return v2Result(id: id, self.v2DebugPanelSnapshot(params: params))
        case "debug.panel_snapshot.reset":
            return v2Result(id: id, self.v2DebugPanelSnapshotReset(params: params))
        case "debug.window.screenshot":
            return v2Result(id: id, self.v2DebugScreenshot(params: params))
#endif

            default:
                return v2Error(id: id, code: "method_not_found", message: "Unknown method")
            }
        }
    }

    private func v2Capabilities() -> [String: Any] {
        var methods: [String] = [
            "system.ping",
            "system.capabilities",
            "system.identify",
            "system.tree",
            "auth.login",
            "window.list",
            "window.current",
            "window.focus",
            "window.create",
            "window.close",
            "workspace.list",
            "workspace.create",
            "workspace.select",
            "workspace.current",
            "workspace.close",
            "workspace.move_to_window",
            "workspace.reorder",
            "workspace.rename",
            "workspace.action",
            "workspace.next",
            "workspace.previous",
            "workspace.last",
            "workspace.equalize_splits",
            "workspace.remote.configure",
            "workspace.remote.foreground_auth_ready",
            "workspace.remote.reconnect",
            "workspace.remote.disconnect",
            "workspace.remote.status",
            "workspace.remote.terminal_session_end",
            "workspace.set_status",
            "workspace.clear_status",
            "workspace.list_status",
            "workspace.log",
            "workspace.clear_log",
            "workspace.list_log",
            "workspace.set_progress",
            "workspace.clear_progress",
            "workspace.sidebar_state",
            "workspace.clear_agent_pid",
            "workspace.set_agent_pid",
            "workspace.report_meta_block",
            "workspace.clear_meta_block",
            "workspace.list_meta_blocks",
            "workspace.reset_sidebar",
            "settings.open",
            "feedback.open",
            "feedback.submit",
            "surface.list",
            "surface.current",
            "surface.focus",
            "surface.split",
            "surface.create",
            "surface.close",
            "surface.drag_to_split",
            "surface.move",
            "surface.reorder",
            "surface.action",
            "tab.action",
            "surface.refresh",
            "surface.health",
            "debug.terminals",
            "surface.send_text",
            "surface.send_key",
            "surface.report_tty",
            "surface.ports_kick",
            "surface.read_text",
            "surface.clear_history",
            "surface.trigger_flash",
            "surface.report_pwd",
            "surface.report_shell_state",
            "surface.report_git_branch",
            "surface.clear_git_branch",
            "surface.report_pr",
            "surface.clear_pr",
            "surface.report_ports",
            "surface.clear_ports",
            "pane.list",
            "pane.focus",
            "pane.surfaces",
            "pane.create",
            "pane.resize",
            "pane.swap",
            "pane.break",
            "pane.join",
            "pane.last",
            "notification.create",
            "notification.create_for_surface",
            "notification.create_for_target",
            "notification.list",
            "notification.clear",
            "app.focus_override.set",
            "app.simulate_active",
            "app.reload_config",
            "markdown.open",
            "browser.open_split",
            "browser.navigate",
            "browser.back",
            "browser.forward",
            "browser.reload",
            "browser.url.get",
            "browser.snapshot",
            "browser.eval",
            "browser.wait",
            "browser.click",
            "browser.dblclick",
            "browser.hover",
            "browser.focus",
            "browser.type",
            "browser.fill",
            "browser.press",
            "browser.keydown",
            "browser.keyup",
            "browser.check",
            "browser.uncheck",
            "browser.select",
            "browser.scroll",
            "browser.scroll_into_view",
            "browser.screenshot",
            "browser.get.text",
            "browser.get.html",
            "browser.get.value",
            "browser.get.attr",
            "browser.get.title",
            "browser.get.count",
            "browser.get.box",
            "browser.get.styles",
            "browser.is.visible",
            "browser.is.enabled",
            "browser.is.checked",
            "browser.focus_webview",
            "browser.is_webview_focused",
            "browser.find.role",
            "browser.find.text",
            "browser.find.label",
            "browser.find.placeholder",
            "browser.find.alt",
            "browser.find.title",
            "browser.find.testid",
            "browser.find.first",
            "browser.find.last",
            "browser.find.nth",
            "browser.frame.select",
            "browser.frame.main",
            "browser.dialog.accept",
            "browser.dialog.dismiss",
            "browser.download.wait",
            "browser.cookies.get",
            "browser.cookies.set",
            "browser.cookies.clear",
            "browser.storage.get",
            "browser.storage.set",
            "browser.storage.clear",
            "browser.tab.new",
            "browser.tab.list",
            "browser.tab.switch",
            "browser.tab.close",
            "browser.console.list",
            "browser.console.clear",
            "browser.errors.list",
            "browser.highlight",
            "browser.state.save",
            "browser.state.load",
            "browser.addinitscript",
            "browser.addscript",
            "browser.addstyle",
            "browser.viewport.set",
            "browser.geolocation.set",
            "browser.offline.set",
            "browser.trace.start",
            "browser.trace.stop",
            "browser.network.route",
            "browser.network.unroute",
            "browser.network.requests",
            "browser.screencast.start",
            "browser.screencast.stop",
            "browser.input_mouse",
            "browser.input_keyboard",
            "browser.input_touch",
        ]
#if DEBUG
        methods.append(contentsOf: [
            "debug.shortcut.set",
            "debug.shortcut.simulate",
            "debug.type",
            "debug.app.activate",
            "debug.command_palette.toggle",
            "debug.command_palette.rename_tab.open",
            "debug.command_palette.visible",
            "debug.command_palette.selection",
            "debug.command_palette.results",
            "debug.command_palette.rename_input.interact",
            "debug.command_palette.rename_input.delete_backward",
            "debug.command_palette.rename_input.selection",
            "debug.command_palette.rename_input.select_all",
            "debug.browser.address_bar_focused",
            "debug.browser.favicon",
            "debug.sidebar.visible",
            "debug.terminal.is_focused",
            "debug.terminal.read_text",
            "debug.terminal.render_stats",
            "debug.layout",
            "debug.portal.stats",
            "debug.bonsplit_underflow.count",
            "debug.bonsplit_underflow.reset",
            "debug.empty_panel.count",
            "debug.empty_panel.reset",
            "debug.notification.focus",
            "debug.flash.count",
            "debug.flash.reset",
            "debug.panel_snapshot",
            "debug.panel_snapshot.reset",
            "debug.window.screenshot",
        ])
#endif

        return [
            "protocol": "cmux-socket",
            "version": 2,
            "socket_path": socketPath,
            "access_mode": accessMode.rawValue,
            "methods": methods.sorted()
        ]
    }

    // MARK: - V2 Helpers (encoding + result plumbing)
    // MARK: - V2 Helpers (encoding + result plumbing)

    func v2OrNull(_ value: Any?) -> Any {
        // Avoid relying on `?? NSNull()` inference (Swift toolchains can disagree).
        if let value { return value }
        return NSNull()
    }

    func v2MainSync<T>(_ body: () -> T) -> T {
        if Thread.isMainThread {
            return body()
        }
        return DispatchQueue.main.sync(execute: body)
    }

    private func v2Ok(id: Any?, result: Any) -> String {
        return v2Encode([
            "id": v2OrNull(id),
            "ok": true,
            "result": result
        ])
    }

    private func v2Error(id: Any?, code: String, message: String, data: Any? = nil) -> String {
        var err: [String: Any] = ["code": code, "message": message]
        if let data {
            err["data"] = data
        }
        return v2Encode([
            "id": v2OrNull(id),
            "ok": false,
            "error": err
        ])
    }

    enum V2CallResult {
        case ok(Any)
        case err(code: String, message: String, data: Any?)
    }

    private func v2Result(id: Any?, _ res: V2CallResult) -> String {
        switch res {
        case .ok(let payload):
            return v2Ok(id: id, result: payload)
        case .err(let code, let message, let data):
            return v2Error(id: id, code: code, message: message, data: data)
        }
    }

    private func v2Encode(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: []),
              var s = String(data: data, encoding: .utf8) else {
            return "{\"ok\":false,\"error\":{\"code\":\"encode_error\",\"message\":\"Failed to encode JSON\"}}"
        }

        // Ensure single-line responses for the line-oriented socket protocol.
        s = s.replacingOccurrences(of: "\n", with: "\\n")
        return s
    }

    private func v2EnsureHandleRef(kind: V2HandleKind, uuid: UUID) -> String {
        if let existing = v2RefByUUID[kind]?[uuid] {
            return existing
        }
        let next = v2NextHandleOrdinal[kind] ?? 1
        let ref = "\(kind.rawValue):\(next)"
        var byUUID = v2RefByUUID[kind] ?? [:]
        var byRef = v2UUIDByRef[kind] ?? [:]
        byUUID[uuid] = ref
        byRef[ref] = uuid
        v2RefByUUID[kind] = byUUID
        v2UUIDByRef[kind] = byRef
        v2NextHandleOrdinal[kind] = next + 1
        return ref
    }

    private func v2ResolveHandleRef(_ handle: String) -> UUID? {
        for kind in V2HandleKind.allCases {
            if let id = v2UUIDByRef[kind]?[handle] {
                return id
            }
        }
        // Tab refs are aliases for surface refs in tab-facing APIs.
        let trimmed = handle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("tab:"),
           let ordinal = Int(trimmed.replacingOccurrences(of: "tab:", with: "")),
           let id = v2UUIDByRef[.surface]?["surface:\(ordinal)"] {
            return id
        }
        return nil
    }

    func v2Ref(kind: V2HandleKind, uuid: UUID?) -> Any {
        guard let uuid else { return NSNull() }
        return v2EnsureHandleRef(kind: kind, uuid: uuid)
    }

    func v2TabRef(uuid: UUID?) -> Any {
        guard let uuid else { return NSNull() }
        let surfaceRef = v2EnsureHandleRef(kind: .surface, uuid: uuid)
        return surfaceRef.replacingOccurrences(of: "surface:", with: "tab:")
    }

    private func v2RefreshKnownRefs() {
        guard let app = AppDelegate.shared else { return }

        let windows = app.listMainWindowSummaries()
        for item in windows {
            _ = v2EnsureHandleRef(kind: .window, uuid: item.windowId)
            if let tm = app.tabManagerFor(windowId: item.windowId) {
                for ws in tm.tabs {
                    _ = v2EnsureHandleRef(kind: .workspace, uuid: ws.id)
                    for paneId in ws.bonsplitController.allPaneIds {
                        _ = v2EnsureHandleRef(kind: .pane, uuid: paneId.id)
                    }
                    for panelId in ws.panels.keys {
                        _ = v2EnsureHandleRef(kind: .surface, uuid: panelId)
                    }
                }
            }
        }
    }

    // MARK: - V2 Param Parsing

    func v2String(_ params: [String: Any], _ key: String) -> String? {
        guard let raw = params[key] as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func v2StringArray(_ params: [String: Any], _ key: String) -> [String]? {
        if let raw = params[key] as? [String] {
            let normalized = raw
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return normalized
        }
        if let raw = params[key] as? [Any] {
            let normalized = raw
                .compactMap { $0 as? String }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return normalized
        }
        if let single = v2String(params, key) {
            return [single]
        }
        return nil
    }

    func v2StringMap(_ params: [String: Any], _ key: String) -> [String: String]? {
        guard let raw = params[key] else { return nil }
        if let dict = raw as? [String: String] {
            return dict
        }
        if let anyDict = raw as? [String: Any] {
            var out: [String: String] = [:]
            for (k, value) in anyDict {
                guard let stringValue = value as? String else { continue }
                out[k] = stringValue
            }
            return out
        }
        return nil
    }

    func v2ActionKey(_ params: [String: Any], _ key: String = "action") -> String? {
        guard let action = v2String(params, key) else { return nil }
        return action.lowercased().replacingOccurrences(of: "-", with: "_")
    }

    func v2RawString(_ params: [String: Any], _ key: String) -> String? {
        params[key] as? String
    }

    func v2UUID(_ params: [String: Any], _ key: String) -> UUID? {
        guard let s = v2String(params, key) else { return nil }
        if let uuid = UUID(uuidString: s) {
            return uuid
        }
        return v2ResolveHandleRef(s)
    }

    func v2UUIDAny(_ raw: Any?) -> UUID? {
        guard let s = raw as? String else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let uuid = UUID(uuidString: trimmed) {
            return uuid
        }
        return v2ResolveHandleRef(trimmed)
    }
    func v2Bool(_ params: [String: Any], _ key: String) -> Bool? {
        if let b = params[key] as? Bool { return b }
        if let n = params[key] as? NSNumber { return n.boolValue }
        if let s = params[key] as? String {
            switch s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true", "yes", "on":
                return true
            case "0", "false", "no", "off":
                return false
            default:
                return nil
            }
        }
        return nil
    }

    func v2LocatePane(_ paneUUID: UUID) -> (windowId: UUID, tabManager: TabManager, workspace: Workspace, paneId: PaneID)? {
        guard let app = AppDelegate.shared else { return nil }
        let windows = app.listMainWindowSummaries()
        for item in windows {
            guard let tm = app.tabManagerFor(windowId: item.windowId) else { continue }
            for ws in tm.tabs {
                if let paneId = ws.bonsplitController.allPaneIds.first(where: { $0.id == paneUUID }) {
                    return (item.windowId, tm, ws, paneId)
                }
            }
        }
        return nil
    }
    func v2Int(_ params: [String: Any], _ key: String) -> Int? {
        if let i = params[key] as? Int { return i }
        if let n = params[key] as? NSNumber { return n.intValue }
        if let s = params[key] as? String { return Int(s) }
        return nil
    }

    func v2Double(_ params: [String: Any], _ key: String) -> Double? {
        if let d = params[key] as? Double { return d }
        if let n = params[key] as? NSNumber { return n.doubleValue }
        if let s = params[key] as? String { return Double(s) }
        return nil
    }

    /// Parses an array-of-integers param (e.g. `ports`), also accepting a single scalar value.
    /// Returns `nil` if the param is present but contains a non-integer element.
    func v2IntArray(_ params: [String: Any], _ key: String) -> [Int]? {
        guard let raw = params[key] as? [Any] else {
            if let single = v2Int(params, key) { return [single] }
            return nil
        }
        var result: [Int] = []
        result.reserveCapacity(raw.count)
        for element in raw {
            if let i = element as? Int {
                result.append(i)
            } else if let n = element as? NSNumber {
                result.append(n.intValue)
            } else if let s = element as? String, let i = Int(s) {
                result.append(i)
            } else {
                return nil
            }
        }
        return result
    }


    func v2HasNonNullParam(_ params: [String: Any], _ key: String) -> Bool {
        guard let raw = params[key] else { return false }
        return !(raw is NSNull)
    }

    func v2StrictInt(_ params: [String: Any], _ key: String) -> Int? {
        v2StrictIntAny(params[key])
    }

    private func v2StrictIntAny(_ raw: Any?) -> Int? {
        guard let raw else { return nil }

        if let numberValue = raw as? NSNumber {
            if CFGetTypeID(numberValue) == CFBooleanGetTypeID() {
                return nil
            }
            let doubleValue = numberValue.doubleValue
            guard doubleValue.isFinite, floor(doubleValue) == doubleValue else {
                return nil
            }
            return Int(exactly: doubleValue)
        }

        if let intValue = raw as? Int {
            return intValue
        }

        if let stringValue = raw as? String {
            return Int(stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return nil
    }

    func v2PanelType(_ params: [String: Any], _ key: String) -> PanelType? {
        guard let s = v2String(params, key) else { return nil }
        return PanelType(rawValue: s.lowercased())
    }

    // MARK: - V2 Context Resolution

    func v2ResolveTabManager(params: [String: Any]) -> TabManager? {
        // Prefer explicit window_id routing. Fall back to global lookup by workspace_id/surface_id/tab_id,
        // and finally to the active window's TabManager.
        if let windowId = v2UUID(params, "window_id") {
            return v2MainSync { AppDelegate.shared?.tabManagerFor(windowId: windowId) }
        }
        if let wsId = v2UUID(params, "workspace_id") {
            if let tm = v2MainSync({ AppDelegate.shared?.tabManagerFor(tabId: wsId) }) {
                return tm
            }
        }
        if let surfaceId = v2UUID(params, "surface_id") ?? v2UUID(params, "tab_id") {
            if let tm = v2MainSync({ AppDelegate.shared?.locateSurface(surfaceId: surfaceId)?.tabManager }) {
                return tm
            }
        }
        return tabManager
    }

    func v2ResolveWindowId(tabManager: TabManager?) -> UUID? {
        guard let tabManager else { return nil }
        return v2MainSync { AppDelegate.shared?.windowId(for: tabManager) }
    }

    // MARK: - Shared Cross-Domain Helpers (used by multiple TerminalController+*.swift files)
    //
    // v2ResolveWorkspace, the terminal-text-snapshot helpers below, orderedPanels, and
    // parseSplitDirection stay here rather than in TerminalController+Surface.swift because they
    // are called from Workspace/Pane/Notification/BrowserAutomation handlers as well as from
    // AppDelegate+UITestCmdClick.swift, GhosttyTerminalView+Mouse.swift, and Workspace.swift.

    func v2ResolveWorkspace(params: [String: Any], tabManager: TabManager) -> Workspace? {
        if let wsId = v2UUID(params, "workspace_id") {
            return tabManager.tabs.first(where: { $0.id == wsId })
        }
        if let surfaceId = v2UUID(params, "surface_id") ?? v2UUID(params, "tab_id") {
            return tabManager.tabs.first(where: { $0.panels[surfaceId] != nil })
        }
        guard let wsId = tabManager.selectedTabId else { return nil }
        return tabManager.tabs.first(where: { $0.id == wsId })
    }

    func readTerminalTextBase64(terminalPanel: TerminalPanel, includeScrollback: Bool = false, lineLimit: Int? = nil) -> String {
        guard let surface = terminalPanel.surface.surface else { return "ERROR: Terminal surface not found" }

        func readSelectionText(pointTag: ghostty_point_tag_e) -> String? {
            let topLeft = ghostty_point_s(
                tag: pointTag,
                coord: GHOSTTY_POINT_COORD_TOP_LEFT,
                x: 0,
                y: 0
            )
            let bottomRight = ghostty_point_s(
                tag: pointTag,
                coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
                x: 0,
                y: 0
            )
            let selection = ghostty_selection_s(
                top_left: topLeft,
                bottom_right: bottomRight,
                rectangle: false
            )

            var text = ghostty_text_s()
            guard ghostty_surface_read_text(surface, selection, &text) else {
                return nil
            }
            defer {
                ghostty_surface_free_text(surface, &text)
            }

            guard let ptr = text.text, text.text_len > 0 else {
                return ""
            }
            let rawData = Data(bytes: ptr, count: Int(text.text_len))
            return String(decoding: rawData, as: UTF8.self)
        }

        var output: String
        if includeScrollback {
            func candidateScore(_ text: String) -> (lines: Int, bytes: Int) {
                let lines = text.isEmpty ? 0 : text.split(separator: "\n", omittingEmptySubsequences: false).count
                return (lines, text.utf8.count)
            }

            // Read all available regions and pick the most complete candidate.
            // Different point tags can lose different rows around resize/reflow boundaries.
            let screen = readSelectionText(pointTag: GHOSTTY_POINT_SCREEN)
            let history = readSelectionText(pointTag: GHOSTTY_POINT_SURFACE)
            let active = readSelectionText(pointTag: GHOSTTY_POINT_ACTIVE)

            var candidates: [String] = []
            if let screen {
                candidates.append(screen)
            }
            if history != nil || active != nil {
                var merged = history ?? ""
                if let active {
                    if !merged.isEmpty, !merged.hasSuffix("\n"), !active.isEmpty {
                        merged.append("\n")
                    }
                    merged.append(active)
                }
                candidates.append(merged)
            }

            if let best = candidates.max(by: { lhs, rhs in
                let left = candidateScore(lhs)
                let right = candidateScore(rhs)
                if left.lines != right.lines {
                    return left.lines < right.lines
                }
                return left.bytes < right.bytes
            }) {
                output = best
            } else {
                return "ERROR: Failed to read terminal text"
            }
        } else {
            guard let viewport = readSelectionText(pointTag: GHOSTTY_POINT_VIEWPORT) else {
                return "ERROR: Failed to read terminal text"
            }
            output = viewport
        }

        if let lineLimit {
            output = tailTerminalLines(output, maxLines: lineLimit)
        }

        let base64 = output.data(using: .utf8)?.base64EncodedString() ?? ""
        return "OK \(base64)"
    }

    private struct PasteboardItemSnapshot {
        let representations: [(type: NSPasteboard.PasteboardType, data: Data)]
    }

    private func snapshotPasteboardItems(_ pasteboard: NSPasteboard) -> [PasteboardItemSnapshot] {
        guard let items = pasteboard.pasteboardItems else { return [] }
        return items.map { item in
            let representations = item.types.compactMap { type -> (type: NSPasteboard.PasteboardType, data: Data)? in
                guard let data = item.data(forType: type) else { return nil }
                return (type: type, data: data)
            }
            return PasteboardItemSnapshot(representations: representations)
        }
    }

    private func restorePasteboardItems(
        _ snapshots: [PasteboardItemSnapshot],
        to pasteboard: NSPasteboard
    ) {
        _ = pasteboard.clearContents()
        guard !snapshots.isEmpty else { return }

        let restoredItems = snapshots.compactMap { snapshot -> NSPasteboardItem? in
            guard !snapshot.representations.isEmpty else { return nil }
            let item = NSPasteboardItem()
            for representation in snapshot.representations {
                item.setData(representation.data, forType: representation.type)
            }
            return item
        }
        guard !restoredItems.isEmpty else { return }
        _ = pasteboard.writeObjects(restoredItems)
    }

    private func readGeneralPasteboardString(_ pasteboard: NSPasteboard) -> String? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
           let firstURL = urls.first,
           firstURL.isFileURL {
            return firstURL.path
        }
        if let value = pasteboard.string(forType: .string) {
            return value
        }
        return pasteboard.string(forType: NSPasteboard.PasteboardType("public.utf8-plain-text"))
    }

    private func readTerminalTextFromVTExportForSnapshot(
        terminalPanel: TerminalPanel,
        lineLimit: Int?
    ) -> String? {
        let pasteboard = NSPasteboard.general
        let snapshot = snapshotPasteboardItems(pasteboard)
        defer {
            restorePasteboardItems(snapshot, to: pasteboard)
        }

        let initialChangeCount = pasteboard.changeCount
        guard terminalPanel.performBindingAction("write_screen_file:copy,vt") else {
            return nil
        }
        guard pasteboard.changeCount != initialChangeCount else {
            return nil
        }
        guard let exportedPath = Self.normalizedExportedScreenPath(readGeneralPasteboardString(pasteboard)) else {
            return nil
        }

        let fileURL = URL(fileURLWithPath: exportedPath)
        defer {
            if Self.shouldRemoveExportedScreenFile(fileURL: fileURL) {
                try? FileManager.default.removeItem(at: fileURL)
                if Self.shouldRemoveExportedScreenDirectory(fileURL: fileURL) {
                    try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
                }
            }
        }

        guard let data = try? Data(contentsOf: fileURL),
              var output = String(data: data, encoding: .utf8) else {
            return nil
        }
        if let lineLimit {
            output = tailTerminalLines(output, maxLines: lineLimit)
        }
        return output
    }

    func readTerminalTextForSnapshot(
        terminalPanel: TerminalPanel,
        includeScrollback: Bool = false,
        lineLimit: Int? = nil
    ) -> String? {
        if includeScrollback,
           let vtOutput = readTerminalTextFromVTExportForSnapshot(
               terminalPanel: terminalPanel,
               lineLimit: lineLimit
           ) {
            return vtOutput
        }

        let response = readTerminalTextBase64(
            terminalPanel: terminalPanel,
            includeScrollback: includeScrollback,
            lineLimit: lineLimit
        )
        guard response.hasPrefix("OK ") else { return nil }
        let base64 = String(response.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        if base64.isEmpty {
            return ""
        }
        guard let data = Data(base64Encoded: base64),
              let decoded = String(data: data, encoding: .utf8) else {
            return nil
        }
        return decoded
    }

    func readTerminalTextForSessionSnapshot(
        terminalPanel: TerminalPanel,
        includeScrollback: Bool = false,
        lineLimit: Int? = nil
    ) -> String? {
        readTerminalTextForSnapshot(
            terminalPanel: terminalPanel,
            includeScrollback: includeScrollback,
            lineLimit: lineLimit
        )
    }


    deinit {
        if let browserDownloadObserver {
            NotificationCenter.default.removeObserver(browserDownloadObserver)
        }
        stop()
    }
}
