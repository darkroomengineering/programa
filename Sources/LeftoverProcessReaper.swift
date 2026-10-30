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

    private struct Leftover {
        let startTime: UInt64
        let name: String
    }

    private struct Owner {
        let startTime: UInt64
        let exitSource: DispatchSourceProcess
        var leftovers: [pid_t: Leftover] = [:]
        /// Set at exit, so a snapshot during the reap grace never sees the owner as live (a
        /// zombie keeps its start time) and wipes the leftovers its exit re-pointed.
        var exited = false
    }

    private let queue = DispatchQueue(label: "com.darkroom.programa.leftover-reaper", qos: .utility)
    /// Mirror of `owners.keys` readable from any thread, so the per-hook-event `trackAgent`
    /// call from main skips the queue hop for an owner that is already tracked.
    private let trackedLock = NSLock()
    private var trackedPids = Set<pid_t>()
    private var owners: [pid_t: Owner] = [:]
    private var snapshotTimer: DispatchSourceTimer?

    // SHORTCUT: ownership snapshots every 10 s. ceiling: anything an agent launches in its
    // last ~10 s of life is missed and survives. upgrade: if leftovers are still reported,
    // follow forks with kqueue NOTE_FORK on each owner instead of polling.
    private static let snapshotInterval: DispatchTimeInterval = .seconds(10)
    private static let initialSnapshotDelay: DispatchTimeInterval = .seconds(3)
    private static let reapGrace: DispatchTimeInterval = .seconds(2)
    private static let killGrace: DispatchTimeInterval = .seconds(3)
    private static let exitNotifyGrace: DispatchTimeInterval = .milliseconds(500)

    private typealias ResponsibleLookup = @convention(c) (pid_t) -> pid_t
    /// `responsibility_get_pid_responsible_for_pid` is private libsystem API; when it is
    /// missing the reaper does nothing.
    private static let responsibleLookup: ResponsibleLookup? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else {
            return nil
        }
        return unsafeBitCast(symbol, to: ResponsibleLookup.self)
    }()

    private init() {}

    /// Registers an agent pid as an owner of leftovers. Idempotent and cheap: called on every
    /// hook event that carries the agent's pid.
    func trackAgent(pid: pid_t) {
        guard pid > 1, pid != getpid(), Self.responsibleLookup != nil else { return }
        trackedLock.lock()
        let inserted = trackedPids.insert(pid).inserted
        trackedLock.unlock()
        guard inserted else { return }
        queue.async { [self] in startTracking(pid: pid) }
    }

    /// Re-reads which live processes `owner` is responsible for.
    func refreshSnapshot(owner: pid_t) {
        queue.async { [self] in snapshot(owners: [owner]) }
    }

    // MARK: - Queue-confined

    private func startTracking(pid: pid_t) {
        guard owners[pid] == nil else { return }
        guard let info = Self.processInfo(pid: pid) else {
            untrack(pid)
            return
        }
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        source.setEventHandler { [weak self] in self?.ownerExited(pid: pid, startTime: info.startTime) }
        owners[pid] = Owner(startTime: info.startTime, exitSource: source)
        source.resume()
        // A process source never fires for a pid that exited before it was armed.
        if kill(pid, 0) == -1, errno == ESRCH {
            ownerExited(pid: pid, startTime: info.startTime)
            return
        }
        ensureSnapshotTimer()
        // MCP servers start a moment after the agent reports in.
        queue.asyncAfter(deadline: .now() + Self.initialSnapshotDelay) { [weak self] in
            self?.snapshot(owners: [pid])
        }
    }

    private func ensureSnapshotTimer() {
        guard snapshotTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.snapshotInterval, repeating: Self.snapshotInterval, leeway: .seconds(2))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.snapshot(owners: Set(self.owners.keys))
        }
        snapshotTimer = timer
        timer.resume()
    }

    private func snapshot(owners requested: Set<pid_t>) {
        guard let lookup = Self.responsibleLookup else { return }
        let live = requested.filter { pid in
            guard let owner = owners[pid], !owner.exited else { return false }
            return Self.processInfo(pid: pid)?.startTime == owner.startTime
        }
        guard !live.isEmpty else { return }
        let selfPid = getpid()
        let uid = getuid()
        var found: [pid_t: [pid_t: Leftover]] = Dictionary(uniqueKeysWithValues: live.map { ($0, [:]) })
        for pid in Self.allPids() where pid > 1 && pid != selfPid && owners[pid] == nil {
            let responsible = lookup(pid)
            guard responsible > 0, live.contains(responsible),
                  let info = Self.processInfo(pid: pid), info.uid == uid else { continue }
            found[responsible]?[pid] = Leftover(startTime: info.startTime, name: Self.processName(pid: pid))
        }
        for (owner, leftovers) in found {
            owners[owner]?.leftovers = leftovers
        }
    }

    private func ownerExited(pid: pid_t, startTime: UInt64) {
        guard let owner = owners[pid], owner.startTime == startTime, !owner.exited else { return }
        owners[pid]?.exited = true
        owner.exitSource.cancel()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.exitNotifyGrace) { [weak self] in
            MainActor.assumeIsolated { self?.onAgentExit?(pid) }
        }
        queue.asyncAfter(deadline: .now() + Self.reapGrace) { [weak self] in
            self?.reap(owner: pid)
        }
    }

    private func reap(owner pid: pid_t) {
        guard let owner = owners[pid] else { return }
        let selfPid = getpid()
        var targets: [(pid: pid_t, leftover: Leftover)] = []
        var skippedNohup = 0
        for (leftoverPid, leftover) in owner.leftovers where leftoverPid != selfPid {
            guard let info = Self.processInfo(pid: leftoverPid), info.startTime == leftover.startTime else { continue }
            if info.ignoresSIGHUP {
                skippedNohup += 1
                continue
            }
            if kill(leftoverPid, SIGTERM) == 0 {
                targets.append((leftoverPid, leftover))
            }
        }
        let names = targets.prefix(10).map(\.leftover.name).joined(separator: ",")
        dilog("reaper", "owner=\(pid) exited reaped=\(targets.count) skippedNohup=\(skippedNohup) names=\(names)")
        owners.removeValue(forKey: pid)
        untrack(pid)
        if owners.isEmpty {
            snapshotTimer?.cancel()
            snapshotTimer = nil
        }
        guard !targets.isEmpty else { return }
        queue.asyncAfter(deadline: .now() + Self.killGrace) {
            for target in targets where Self.processInfo(pid: target.pid)?.startTime == target.leftover.startTime {
                kill(target.pid, SIGKILL)
            }
        }
    }

    private func untrack(_ pid: pid_t) {
        trackedLock.lock()
        trackedPids.remove(pid)
        trackedLock.unlock()
    }

    // MARK: - Kernel lookups

    private struct ProcessSnapshot {
        let startTime: UInt64
        let uid: uid_t
        let ignoresSIGHUP: Bool
    }

    private static func processInfo(pid: pid_t) -> ProcessSnapshot? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0,
              size > 0,
              info.kp_proc.p_pid == pid else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return ProcessSnapshot(
            startTime: UInt64(start.tv_sec) * 1_000_000 + UInt64(start.tv_usec),
            uid: info.kp_eproc.e_ucred.cr_uid,
            ignoresSIGHUP: info.kp_proc.p_sigignore & (sigset_t(1) << sigset_t(SIGHUP - 1)) != 0
        )
    }

    private static func allPids() -> [pid_t] {
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

    private static func processName(pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXCOMLEN) * 2 + 1)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return "?" }
        return String(cString: buffer)
    }
}
