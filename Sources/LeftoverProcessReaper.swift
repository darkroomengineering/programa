import Bonsplit
import Darwin
import Foundation

/// Terminates the processes a Claude agent launched and left behind when it exits.
///
/// macOS charges each process to a "responsible process", and a Dock force-quit of an app
/// also kills its responsible process. Claude Code disclaims responsibility for itself, so
/// everything it launches (MCP servers that register as background apps, debug binaries run
/// directly) is charged to the `claude` pid; force-quitting one of those leftovers kills the
/// agent. Reaping them when their agent exits keeps them from piling up in the Dock.
///
/// When the owner dies, macOS re-points each leftover's responsible pid at the leftover
/// itself, so ownership is snapshotted while the owner is alive and the reap works from the
/// last snapshot. Only agent pids are tracked: daemons a user starts from a plain shell
/// (colima and the like) are deliberate and stay alive.
final class LeftoverProcessReaper {
    static let shared = LeftoverProcessReaper()

    /// Main-thread notification that a tracked agent exited, delivered after a short grace so a
    /// clean SessionEnd hook has had time to clear the panel's agent presence.
    var onAgentExit: (@MainActor (pid_t) -> Void)?

    struct ProcessSnapshot {
        let startTime: UInt64
        let uid: uid_t
        let ignoresSIGHUP: Bool
    }

    /// The kernel lookups, signals and timers the reaper uses, so tests can run it against fake
    /// processes.
    struct System {
        /// `nil` when the private lookup is missing; the reaper then does nothing.
        var responsiblePid: ((pid_t) -> pid_t)?
        var processInfo: (pid_t) -> ProcessSnapshot?
        var allPids: () -> [pid_t]
        var processName: (pid_t) -> String
        /// `kill(2)`: returns 0, or the errno it failed with.
        var sendSignal: (pid_t, Int32) -> Int32
        /// Calls the handler on the queue once the pid exits; returns the cancel function.
        var watchExit: (pid_t, DispatchQueue, @escaping () -> Void) -> () -> Void
        var runAfter: (DispatchTimeInterval, DispatchQueue, @escaping () -> Void) -> Void
        /// Starts a repeating timer on the queue; returns the cancel function.
        var startTimer: (DispatchTimeInterval, DispatchQueue, @escaping () -> Void) -> () -> Void
        var isEnabled: () -> Bool
    }

    private struct Leftover {
        let startTime: UInt64
        let name: String
    }

    private struct Owner {
        let startTime: UInt64
        let cancelExitWatch: () -> Void
        var leftovers: [pid_t: Leftover] = [:]
        /// Set at exit, so a snapshot during the reap grace never sees the owner as live (a
        /// zombie keeps its start time) and wipes the leftovers its exit re-pointed.
        var exited = false
    }

    private let system: System
    private let queue: DispatchQueue
    /// Guards `trackedPids` and `pollingSuspended`, which the per-hook-event `trackAgent` call
    /// reads from main without a queue hop.
    private let trackedLock = NSLock()
    /// Mirror of `owners.keys`.
    private var trackedPids = Set<pid_t>()
    /// Set while the setting is off and owners are tracked, so the next hook event restarts
    /// polling once the setting is back on.
    private var pollingSuspended = false
    private var owners: [pid_t: Owner] = [:]
    private var cancelSnapshotTimer: (() -> Void)?

    // SHORTCUT: ownership snapshots every 10 s. ceiling: anything an agent launches in its
    // last ~10 s of life is missed and survives. upgrade: if leftovers are still reported,
    // follow forks with kqueue NOTE_FORK on each owner instead of polling.
    static let snapshotInterval: DispatchTimeInterval = .seconds(10)
    static let initialSnapshotDelay: DispatchTimeInterval = .seconds(3)
    static let reapGrace: DispatchTimeInterval = .seconds(2)
    static let killGrace: DispatchTimeInterval = .seconds(3)
    private static let exitNotifyGrace: DispatchTimeInterval = .milliseconds(500)

    init(
        system: System = .live,
        queue: DispatchQueue = DispatchQueue(label: "com.darkroom.programa.leftover-reaper", qos: .utility)
    ) {
        self.system = system
        self.queue = queue
    }

    /// Registers an agent pid as an owner of leftovers. Idempotent and cheap: called on every
    /// hook event that carries the agent's pid.
    func trackAgent(pid: pid_t) {
        guard pid > 1, pid != getpid(), system.responsiblePid != nil else { return }
        trackedLock.lock()
        let inserted = trackedPids.insert(pid).inserted
        let suspended = pollingSuspended
        trackedLock.unlock()
        if inserted {
            queue.async { [self] in startTracking(pid: pid) }
        } else if suspended {
            queue.async { [self] in resumePolling() }
        }
    }

    /// Re-reads which live processes `owner` is responsible for.
    func refreshSnapshot(owner: pid_t) {
        queue.async { [self] in snapshot(owners: [owner]) }
    }

    // MARK: - Queue-confined

    private func startTracking(pid: pid_t) {
        guard owners[pid] == nil else { return }
        guard let info = system.processInfo(pid) else {
            untrack(pid)
            return
        }
        // Exits are watched even with reaping off: `onAgentExit` drives the interrupted-agent banner.
        let cancelExitWatch = system.watchExit(pid, queue) { [weak self] in
            self?.ownerExited(pid: pid, startTime: info.startTime)
        }
        owners[pid] = Owner(startTime: info.startTime, cancelExitWatch: cancelExitWatch)
        // A process source never fires for a pid that exited before it was armed.
        if system.sendSignal(pid, 0) == ESRCH {
            ownerExited(pid: pid, startTime: info.startTime)
            return
        }
        guard pollingEnabled() else { return }
        ensureSnapshotTimer()
        // MCP servers start a moment after the agent reports in.
        system.runAfter(Self.initialSnapshotDelay, queue) { [weak self] in
            self?.snapshot(owners: [pid])
        }
    }

    /// Reads the setting; when it is off, stops polling and forgets every snapshot.
    private func pollingEnabled() -> Bool {
        let enabled = system.isEnabled()
        if !enabled {
            stopSnapshotTimer()
            for pid in owners.keys {
                owners[pid]?.leftovers = [:]
            }
        }
        trackedLock.lock()
        pollingSuspended = !enabled && !owners.isEmpty
        trackedLock.unlock()
        return enabled
    }

    private func resumePolling() {
        guard !owners.isEmpty, pollingEnabled() else { return }
        ensureSnapshotTimer()
        snapshot(owners: Set(owners.keys))
    }

    private func ensureSnapshotTimer() {
        guard cancelSnapshotTimer == nil else { return }
        cancelSnapshotTimer = system.startTimer(Self.snapshotInterval, queue) { [weak self] in
            guard let self else { return }
            self.snapshot(owners: Set(self.owners.keys))
        }
    }

    private func stopSnapshotTimer() {
        cancelSnapshotTimer?()
        cancelSnapshotTimer = nil
    }

    private func snapshot(owners requested: Set<pid_t>) {
        guard let lookup = system.responsiblePid, pollingEnabled() else { return }
        let live = requested.filter { pid in
            guard let owner = owners[pid], !owner.exited else { return false }
            return system.processInfo(pid)?.startTime == owner.startTime
        }
        guard !live.isEmpty else { return }
        let selfPid = getpid()
        let uid = getuid()
        var found: [pid_t: [pid_t: Leftover]] = Dictionary(uniqueKeysWithValues: live.map { ($0, [:]) })
        for pid in system.allPids() where pid > 1 && pid != selfPid && owners[pid] == nil {
            let responsible = lookup(pid)
            guard responsible > 0, live.contains(responsible),
                  let info = system.processInfo(pid), info.uid == uid else { continue }
            found[responsible]?[pid] = Leftover(startTime: info.startTime, name: system.processName(pid))
        }
        for (owner, leftovers) in found {
            owners[owner]?.leftovers = leftovers
        }
    }

    private func ownerExited(pid: pid_t, startTime: UInt64) {
        guard let owner = owners[pid], owner.startTime == startTime, !owner.exited else { return }
        owners[pid]?.exited = true
        owner.cancelExitWatch()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.exitNotifyGrace) { [weak self] in
            MainActor.assumeIsolated { self?.onAgentExit?(pid) }
        }
        system.runAfter(Self.reapGrace, queue) { [weak self] in
            self?.reap(owner: pid)
        }
    }

    private func reap(owner pid: pid_t) {
        guard let owner = owners.removeValue(forKey: pid) else { return }
        untrack(pid)
        if owners.isEmpty {
            stopSnapshotTimer()
        }
        guard system.isEnabled() else {
            dilog("reaper", "owner=\(pid) exited reaping=off")
            return
        }
        let selfPid = getpid()
        var targets: [(pid: pid_t, leftover: Leftover)] = []
        var skippedNohup = 0
        for (leftoverPid, leftover) in owner.leftovers where leftoverPid != selfPid {
            guard let info = system.processInfo(leftoverPid), info.startTime == leftover.startTime else { continue }
            if info.ignoresSIGHUP {
                skippedNohup += 1
                continue
            }
            if system.sendSignal(leftoverPid, SIGTERM) == 0 {
                targets.append((leftoverPid, leftover))
            }
        }
        let names = targets.prefix(10).map(\.leftover.name).joined(separator: ",")
        dilog("reaper", "owner=\(pid) exited reaped=\(targets.count) skippedNohup=\(skippedNohup) names=\(names)")
        guard !targets.isEmpty else { return }
        system.runAfter(Self.killGrace, queue) { [system] in
            for target in targets where system.processInfo(target.pid)?.startTime == target.leftover.startTime {
                _ = system.sendSignal(target.pid, SIGKILL)
            }
        }
    }

    private func untrack(_ pid: pid_t) {
        trackedLock.lock()
        trackedPids.remove(pid)
        if trackedPids.isEmpty {
            pollingSuspended = false
        }
        trackedLock.unlock()
    }
}

// MARK: - Kernel lookups

extension LeftoverProcessReaper.System {
    static var live: Self {
        Self(
            responsiblePid: responsibleLookup.map { lookup in { pid in lookup(pid) } },
            processInfo: liveProcessInfo(pid:),
            allPids: liveAllPids,
            processName: liveProcessName(pid:),
            sendSignal: { pid, signal in kill(pid, signal) == 0 ? 0 : errno },
            watchExit: { pid, queue, handler in
                let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
                source.setEventHandler(handler: handler)
                source.resume()
                return { source.cancel() }
            },
            runAfter: { delay, queue, work in queue.asyncAfter(deadline: .now() + delay, execute: work) },
            startTimer: { interval, queue, handler in
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(2))
                timer.setEventHandler(handler: handler)
                timer.resume()
                return { timer.cancel() }
            },
            isEnabled: { LeftoverProcessReaperSettings.isEnabled() }
        )
    }

    private typealias ResponsibleLookup = @convention(c) (pid_t) -> pid_t
    /// `responsibility_get_pid_responsible_for_pid` is private libsystem API; when it is
    /// missing the reaper does nothing.
    private static let responsibleLookup: ResponsibleLookup? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else {
            return nil
        }
        return unsafeBitCast(symbol, to: ResponsibleLookup.self)
    }()

    private static func liveProcessInfo(pid: pid_t) -> LeftoverProcessReaper.ProcessSnapshot? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0,
              size > 0,
              info.kp_proc.p_pid == pid else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return LeftoverProcessReaper.ProcessSnapshot(
            startTime: UInt64(start.tv_sec) * 1_000_000 + UInt64(start.tv_usec),
            uid: info.kp_eproc.e_ucred.cr_uid,
            ignoresSIGHUP: info.kp_proc.p_sigignore & (sigset_t(1) << sigset_t(SIGHUP - 1)) != 0
        )
    }

    private static func liveAllPids() -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        // Headroom for processes spawned between the sizing call and the read.
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard count > 0 else { return [] }
        return Array(pids.prefix(Int(count)))
    }

    private static func liveProcessName(pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXCOMLEN) * 2 + 1)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return "?" }
        return String(cString: buffer)
    }
}
