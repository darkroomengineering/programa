import Darwin
import Foundation

/// A process that holds at least one TCP listening socket.
struct ListeningProcess: Sendable, Equatable, Hashable {
    let pid: Int
    let command: String
    let ports: [Int]
}

/// One process's entry in `lsof -F pcn` output. `command` is empty when unknown.
struct LsofListener: Sendable, Equatable {
    var command: String
    var ports: Set<Int>

    func process(pid: Int) -> ListeningProcess {
        ListeningProcess(pid: pid, command: command, ports: ports.sorted())
    }
}

extension PortScanner {
    /// Parses `lsof -F pcn` output: `p` = pid, `c` = command (may contain spaces), `n` = name
    /// (`host:port`, `[::1]:3000`, `*:80`, or `local->remote`).
    static func parseLsofListen(_ output: String) -> [Int: LsofListener] {
        var result: [Int: LsofListener] = [:]
        var currentPid: Int?
        for line in output.split(separator: "\n") {
            guard let first = line.first else { continue }
            switch first {
            case "p":
                currentPid = Int(line.dropFirst())
            case "c":
                guard let pid = currentPid else { continue }
                result[pid, default: LsofListener(command: "", ports: [])].command = String(line.dropFirst())
            case "n":
                guard let pid = currentPid else { continue }
                var name = String(line.dropFirst())
                // Strip remote endpoint if present.
                if let arrowIdx = name.range(of: "->") {
                    name = String(name[..<arrowIdx.lowerBound])
                }
                // Port is after the last colon.
                if let colonIdx = name.lastIndex(of: ":") {
                    let portStr = name[name.index(after: colonIdx)...]
                    let cleaned = portStr.prefix(while: \.isNumber)
                    if let port = Int(cleaned), port > 0, port <= 65535 {
                        result[pid, default: LsofListener(command: "", ports: [])].ports.insert(port)
                    }
                }
            default:
                break
            }
        }
        // A process with a command line but no listening socket is not a listener.
        return result.filter { !$0.value.ports.isEmpty }
    }

    /// Per-workspace listening processes among the agent process trees.
    static func agentProcesses(
        listeners: [Int: LsofListener],
        agentPidToWorkspaces: [Int: Set<UUID>]
    ) -> [UUID: [ListeningProcess]] {
        var result: [UUID: [ListeningProcess]] = [:]
        for (pid, listener) in listeners {
            guard let workspaceIds = agentPidToWorkspaces[pid] else { continue }
            for workspaceId in workspaceIds {
                result[workspaceId, default: []].append(listener.process(pid: pid))
            }
        }
        return result.mapValues { $0.sorted { $0.pid < $1.pid } }
    }
}

/// Kernel lookups that identify a process and its listening sockets without a subprocess.
enum ProcessInspector {
    /// Kernel start time in microseconds since the epoch. Two processes that share a pid
    /// (pid reuse) never share a start time.
    static func startTime(pid: Int) -> UInt64? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, Int32(pid)]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0,
              size > 0,
              Int(info.kp_proc.p_pid) == pid else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return UInt64(start.tv_sec) * 1_000_000 + UInt64(start.tv_usec)
    }

    /// TCP ports `pid` is listening on, or nil when its file descriptors cannot be read
    /// (for example a process owned by another user).
    static func listeningTCPPorts(pid: Int) -> [Int]? {
        let fdInfoSize = MemoryLayout<proc_fdinfo>.stride
        let bufferSize = proc_pidinfo(Int32(pid), PROC_PIDLISTFDS, 0, nil, 0)
        guard bufferSize > 0 else { return nil }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bufferSize) / fdInfoSize)
        let used = proc_pidinfo(Int32(pid), PROC_PIDLISTFDS, 0, &fds, bufferSize)
        guard used > 0 else { return nil }
        let socketInfoSize = Int32(MemoryLayout<socket_fdinfo>.stride)
        var ports = Set<Int>()
        for fd in fds.prefix(Int(used) / fdInfoSize) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            guard proc_pidfdinfo(Int32(pid), fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, socketInfoSize) == socketInfoSize,
                  info.psi.soi_kind == Int32(SOCKINFO_TCP) else { continue }
            let tcp = info.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == Int32(TSI_S_LISTEN) else { continue }
            let port = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport)))
            if port > 0 { ports.insert(port) }
        }
        return ports.sorted()
    }
}
