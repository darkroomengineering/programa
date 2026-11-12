import Darwin
import Foundation

enum PaneJob {
    private static let handshakeEnvironment = "PROGRAMA_PANE_JOB_HANDSHAKE_DIR"

    static func runIfRequested(_ arguments: [String]) {
        guard arguments.count > 1,
              arguments[1] == "__pane-job" || arguments[1] == "__pane-job-child" else { return }
        guard arguments.count >= 5, arguments[3] == "--",
              arguments[2].hasPrefix("/dev/"), !arguments[4].isEmpty else {
            fail("arguments", EINVAL)
        }
        let ttyPath = arguments[2]
        let target = Array(arguments.dropFirst(4))
        if arguments[1] == "__pane-job" {
            waitForAuthorization(gate: "prepare", ready: "leader", pid: getpid())
            runLeader(ttyPath: ttyPath, target: target)
        } else {
            runSession(ttyPath: ttyPath, target: target)
        }
    }

    private static func waitForAuthorization(gate: String, ready: String, pid: pid_t) {
        guard let directory = ProcessInfo.processInfo.environment[handshakeEnvironment] else {
            fail("missing handshake", EINVAL)
        }
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        do {
            try Data(String(pid).utf8).write(to: root.appendingPathComponent(ready), options: .atomic)
        } catch {
            fail("handshake ready", EIO)
        }
        // Longer than any app-side step between our report and its gate, which can include a
        // `launchctl print` on a loaded machine. The app cancels sooner by deleting the folder.
        let deadline = DispatchTime.now().uptimeNanoseconds + 20_000_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            guard FileManager.default.fileExists(atPath: directory) else { fail("handshake cancelled", ECANCELED) }
            if FileManager.default.fileExists(atPath: root.appendingPathComponent(gate).path) { return }
            usleep(1_000)
        }
        fail("handshake timeout", ETIMEDOUT)
    }

    private static func runLeader(ttyPath: String, target: [String]) -> Never {
        guard let executable = Bundle.main.executablePath else { fail("executable path", ENOENT) }
        var attributes: posix_spawnattr_t?
        check(posix_spawnattr_init(&attributes), "spawn attributes")
        configureSignals(&attributes, flags: Int16(POSIX_SPAWN_SETSID))
        var child: pid_t = 0
        let result = withArguments([executable, "__pane-job-child", ttyPath, "--"] + target) { argv in
            posix_spawn(&child, executable, nil, &attributes, argv, environ)
        }
        posix_spawnattr_destroy(&attributes)
        check(result, "session spawn")
        var status: Int32 = 0
        while waitpid(child, &status, 0) == -1 {
            if errno != EINTR { fail("session wait", errno) }
        }
        let signal = status & 0x7f
        exit(signal == 0 ? (status >> 8) & 0xff : 128 + signal)
    }

    private static func runSession(ttyPath: String, target: [String]) -> Never {
        // Open the slave before `ready` so it stays open once Ghostty closes its copy,
        // but make it the controlling tty only after `go`: a job cancelled earlier must
        // not be the terminal's session leader, or its exit revokes the tty.
        let fd = open(ttyPath, O_RDWR | O_NOCTTY)
        guard fd >= 0 else { fail("tty open", errno) }
        guard isatty(fd) == 1 else { fail("tty validation", ENOTTY) }
        waitForAuthorization(gate: "go", ready: "ready", pid: getppid())
        guard ioctl(fd, TIOCSCTTY, 0) == 0 else { fail("controlling tty", errno) }
        for destination in 0...2 {
            guard dup2(fd, Int32(destination)) >= 0 else { fail("tty dup", errno) }
        }
        // launchd owns the coalition leader; only this new session owns the tty.
        for descriptor in 3..<getdtablesize() { close(descriptor) }

        var attributes: posix_spawnattr_t?
        check(posix_spawnattr_init(&attributes), "exec attributes")
        configureSignals(&attributes, flags: Int16(POSIX_SPAWN_SETEXEC))
        typealias SetDisclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim") else {
            fail("responsibility SPI", ENOSYS)
        }
        let setDisclaim = unsafeBitCast(symbol, to: SetDisclaim.self)
        check(setDisclaim(&attributes, 1), "disclaim responsibility")
        unsetenv(handshakeEnvironment)
        var unused: pid_t = 0
        let result = withArguments(target) { argv in
            posix_spawnp(&unused, target[0], nil, &attributes, argv, environ)
        }
        posix_spawnattr_destroy(&attributes)
        fail("target exec", result)
    }

    private static func configureSignals(_ attributes: inout posix_spawnattr_t?, flags: Int16) {
        var defaults = sigset_t()
        sigfillset(&defaults)
        sigdelset(&defaults, SIGKILL)
        sigdelset(&defaults, SIGSTOP)
        var mask = sigset_t()
        sigemptyset(&mask)
        check(posix_spawnattr_setsigdefault(&attributes, &defaults), "signal defaults")
        check(posix_spawnattr_setsigmask(&attributes, &mask), "signal mask")
        check(posix_spawnattr_setflags(&attributes, flags | Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)), "spawn flags")
    }

    private static func withArguments<Result>(
        _ arguments: [String],
        body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Result
    ) -> Result {
        var pointers = arguments.map { strdup($0) }
        defer { pointers.forEach { free($0) } }
        guard pointers.allSatisfy({ $0 != nil }) else { fail("argv allocation", ENOMEM) }
        pointers.append(nil)
        return pointers.withUnsafeMutableBufferPointer { buffer in
            body(buffer.baseAddress!)
        }
    }

    private static func check(_ result: Int32, _ operation: String) {
        if result != 0 { fail(operation, result) }
    }

    private static func fail(_ operation: String, _ code: Int32) -> Never {
        FileHandle.standardError.write(Data("programa pane job: \(operation): \(String(cString: strerror(code)))\n".utf8))
        exit(126)
    }
}
