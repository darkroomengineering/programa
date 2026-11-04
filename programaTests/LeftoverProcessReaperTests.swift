import Darwin
import XCTest

#if canImport(Programa_DEV)
@testable import Programa_DEV
#elseif canImport(Programa)
@testable import Programa
#endif

/// Drives `LeftoverProcessReaper` against a fake process table. Pids are above the macOS pid
/// limit (99998), so even a bug that reached `kill(2)` could not hit a real process.
final class LeftoverProcessReaperTests: XCTestCase {
    private let owner: pid_t = 200_000
    private var fake: FakeProcessTable!
    private var queue: DispatchQueue!
    private var reaper: LeftoverProcessReaper!

    override func setUp() {
        super.setUp()
        fake = FakeProcessTable()
        queue = DispatchQueue(label: "LeftoverProcessReaperTests")
        reaper = LeftoverProcessReaper(system: fake.system, queue: queue)
        fake.add(owner, responsible: owner)
    }

    override func tearDown() {
        reaper = nil
        queue = nil
        fake = nil
        super.tearDown()
    }

    func testReapsOnlyLiveLeftoversChargedToTheTrackedAgent() {
        fake.add(200_001, responsible: owner)
        fake.add(200_002, responsible: 200_100)
        fake.add(200_003, responsible: owner, uid: getuid() + 1)
        fake.add(200_004, responsible: owner)
        fake.add(200_005, responsible: 0)

        track(owner)
        runDelayed(LeftoverProcessReaper.initialSnapshotDelay)
        fake.add(200_004, responsible: 200_004, startTime: 99)
        exitOwner()
        runDelayed(LeftoverProcessReaper.reapGrace)

        XCTAssertEqual(fake.sentSignals, [Signal(pid: 200_001, signal: SIGTERM)])
    }

    func testOwnerPidReusedBeforeSnapshotChargesNothingToIt() {
        fake.add(200_001, responsible: owner)

        track(owner)
        fake.add(owner, responsible: owner, startTime: 2)
        runDelayed(LeftoverProcessReaper.initialSnapshotDelay)
        exitOwner()
        runDelayed(LeftoverProcessReaper.reapGrace)

        XCTAssertEqual(fake.sentSignals, [])
    }

    func testSkipsLeftoversThatIgnoreSIGHUP() {
        fake.add(200_001, responsible: owner, ignoresSIGHUP: true)
        fake.add(200_002, responsible: owner)

        track(owner)
        runDelayed(LeftoverProcessReaper.initialSnapshotDelay)
        exitOwner()
        runDelayed(LeftoverProcessReaper.reapGrace)

        XCTAssertEqual(fake.sentSignals, [Signal(pid: 200_002, signal: SIGTERM)])
    }

    func testEscalatesToSIGKILLOnlyAfterKillGraceAndOnlyForSurvivors() {
        fake.add(200_001, responsible: owner)
        fake.add(200_002, responsible: owner)
        fake.exitsOnSIGTERM = [200_002]

        track(owner)
        runDelayed(LeftoverProcessReaper.initialSnapshotDelay)
        exitOwner()
        runDelayed(LeftoverProcessReaper.reapGrace)

        XCTAssertEqual(
            Set(fake.sentSignals),
            [Signal(pid: 200_001, signal: SIGTERM), Signal(pid: 200_002, signal: SIGTERM)]
        )
        XCTAssertEqual(fake.delayed.map(\.delay), [LeftoverProcessReaper.killGrace])

        runDelayed(LeftoverProcessReaper.killGrace)

        XCTAssertEqual(fake.sentSignals.filter { $0.signal == SIGKILL }, [Signal(pid: 200_001, signal: SIGKILL)])
    }

    func testDoesNotPollOrSignalWhenSettingIsOffButStillReportsTheExit() {
        fake.enabled = false
        fake.add(200_001, responsible: owner)
        let exitReported = expectation(description: "onAgentExit")
        let expectedPid = owner
        reaper.onAgentExit = { pid in
            XCTAssertEqual(pid, expectedPid)
            exitReported.fulfill()
        }

        track(owner)

        XCTAssertEqual(fake.timerStarts, 0)
        XCTAssertEqual(fake.delayed.map(\.delay), [])

        exitOwner()
        runDelayed(LeftoverProcessReaper.reapGrace)

        XCTAssertEqual(fake.allPidsCalls, 0)
        XCTAssertEqual(fake.sentSignals, [])
        XCTAssertTrue(fake.delayed.isEmpty)
        wait(for: [exitReported], timeout: 5)
    }

    func testTurningSettingOffStopsPollingAndTurningItBackOnResumes() {
        fake.add(200_001, responsible: owner)

        track(owner)
        runDelayed(LeftoverProcessReaper.initialSnapshotDelay)
        XCTAssertEqual(fake.timerStarts, 1)
        let scansWhileOn = fake.allPidsCalls

        fake.enabled = false
        fireTimer()

        XCTAssertEqual(fake.timerCancels, 1)
        XCTAssertNil(fake.timerHandler)
        XCTAssertEqual(fake.allPidsCalls, scansWhileOn)

        fake.enabled = true
        track(owner)

        XCTAssertEqual(fake.timerStarts, 2)
        XCTAssertEqual(fake.allPidsCalls, scansWhileOn + 1)

        exitOwner()
        runDelayed(LeftoverProcessReaper.reapGrace)

        XCTAssertEqual(fake.sentSignals, [Signal(pid: 200_001, signal: SIGTERM)])
    }

    func testSettingOffAtExitForgetsLeftoversRecordedWhileOn() {
        fake.add(200_001, responsible: owner)

        track(owner)
        runDelayed(LeftoverProcessReaper.initialSnapshotDelay)
        fake.enabled = false
        exitOwner()
        runDelayed(LeftoverProcessReaper.reapGrace)

        XCTAssertEqual(fake.sentSignals, [])
        XCTAssertEqual(fake.timerCancels, 1)
    }

    // MARK: - Driving the reaper

    private func track(_ pid: pid_t) {
        reaper.trackAgent(pid: pid)
        queue.sync {}
    }

    /// Runs the first work item the reaper scheduled with `delay`, on the reaper's queue.
    private func runDelayed(_ delay: DispatchTimeInterval, file: StaticString = #filePath, line: UInt = #line) {
        queue.sync {
            guard let index = fake.delayed.firstIndex(where: { $0.delay == delay }) else {
                XCTFail("nothing scheduled after \(delay); scheduled: \(fake.delayed.map(\.delay))", file: file, line: line)
                return
            }
            fake.delayed.remove(at: index).work()
        }
    }

    private func fireTimer() {
        queue.sync { fake.timerHandler?() }
    }

    /// The owner exits and, as macOS does, each leftover's responsible pid points back at itself.
    private func exitOwner(file: StaticString = #filePath, line: UInt = #line) {
        for (pid, process) in fake.processes where process.responsible == owner && pid != owner {
            fake.processes[pid]?.responsible = pid
        }
        queue.sync {
            guard let handler = fake.exitHandlers[owner] else {
                XCTFail("owner exit is not watched", file: file, line: line)
                return
            }
            handler()
        }
    }
}

private struct Signal: Hashable, CustomStringConvertible {
    let pid: pid_t
    let signal: Int32

    var description: String { "\(pid):\(signal)" }
}

/// Every closure runs on the reaper's queue, which the tests only touch through `queue.sync`.
private final class FakeProcessTable {
    struct Process {
        var responsible: pid_t
        var info: LeftoverProcessReaper.ProcessSnapshot
    }

    var processes: [pid_t: Process] = [:]
    var enabled = true
    var exitsOnSIGTERM: Set<pid_t> = []
    private(set) var sentSignals: [Signal] = []
    private(set) var exitHandlers: [pid_t: () -> Void] = [:]
    var delayed: [(delay: DispatchTimeInterval, work: () -> Void)] = []
    private(set) var timerHandler: (() -> Void)?
    private(set) var timerStarts = 0
    private(set) var timerCancels = 0
    private(set) var allPidsCalls = 0

    func add(
        _ pid: pid_t,
        responsible: pid_t,
        startTime: UInt64 = 1,
        uid: uid_t = getuid(),
        ignoresSIGHUP: Bool = false
    ) {
        processes[pid] = Process(
            responsible: responsible,
            info: LeftoverProcessReaper.ProcessSnapshot(startTime: startTime, uid: uid, ignoresSIGHUP: ignoresSIGHUP)
        )
    }

    var system: LeftoverProcessReaper.System {
        LeftoverProcessReaper.System(
            responsiblePid: { [unowned self] pid in processes[pid]?.responsible ?? 0 },
            processInfo: { [unowned self] pid in processes[pid]?.info },
            allPids: { [unowned self] in
                allPidsCalls += 1
                return processes.keys.sorted()
            },
            processName: { pid in "proc\(pid)" },
            sendSignal: { [unowned self] pid, signal in
                guard processes[pid] != nil else { return ESRCH }
                guard signal != 0 else { return 0 }
                sentSignals.append(Signal(pid: pid, signal: signal))
                if signal == SIGKILL || (signal == SIGTERM && exitsOnSIGTERM.contains(pid)) {
                    processes[pid] = nil
                }
                return 0
            },
            watchExit: { [unowned self] pid, _, handler in
                exitHandlers[pid] = handler
                return { [unowned self] in exitHandlers[pid] = nil }
            },
            runAfter: { [unowned self] delay, _, work in delayed.append((delay, work)) },
            startTimer: { [unowned self] _, _, handler in
                timerStarts += 1
                timerHandler = handler
                return { [unowned self] in
                    timerCancels += 1
                    timerHandler = nil
                }
            },
            isEnabled: { [unowned self] in enabled }
        )
    }
}
