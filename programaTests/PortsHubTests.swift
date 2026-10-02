import Foundation
import XCTest

#if canImport(Programa_DEV)
@testable import Programa_DEV
#elseif canImport(Programa)
@testable import Programa
#endif

final class LsofListenParserTests: XCTestCase {
    func testParsesCommandNamesWithSpacesAndIPv6Listeners() {
        let output = """
        p100
        cGoogle Chrome Helper
        n*:3000
        n[::1]:3000
        p200
        cnode
        n127.0.0.1:8080
        n127.0.0.1:8080->127.0.0.1:55000
        p300
        cidle-no-socket
        """
        let parsed = PortScanner.parseLsofListen(output)

        XCTAssertEqual(parsed[100], LsofListener(command: "Google Chrome Helper", ports: [3000]))
        XCTAssertEqual(parsed[200], LsofListener(command: "node", ports: [8080]))
        XCTAssertNil(parsed[300], "a process without a listening socket is not a listener")
    }

    func testIgnoresOutOfRangePortsAndSortsListeningProcess() {
        let parsed = PortScanner.parseLsofListen("p7\ncpython3\nn*:0\nn*:70000\nn*:9000\nn*:80\n")
        XCTAssertEqual(parsed[7]?.process(pid: 7), ListeningProcess(pid: 7, command: "python3", ports: [80, 9000]))
    }
}

@MainActor
final class PortsHubStoreTests: XCTestCase {
    private final class Fakes {
        var alive: Set<Int> = []
        var names: [Int: String] = [:]
        /// Overrides the default start time (the pid itself) to simulate pid reuse.
        var startTimes: [Int: UInt64] = [:]
        /// Live listening ports per pid; a missing entry means "cannot be read".
        var listeningPorts: [Int: [Int]] = [:]
        var signals: [(pid: Int, signal: Int32)] = []
        var scheduled: [(delay: TimeInterval, work: @MainActor () -> Void)] = []
        var rescans: [PortScanner.PanelKey] = []
        var signalSucceeds = true
        let workspaceId = UUID()

        @MainActor
        func makeStore() -> PortsHubStore {
            let workspaceId = workspaceId
            return PortsHubStore(
                dependencies: PortsHubStore.Dependencies(
                    sendSignal: { [unowned self] pid, signal in
                        signals.append((pid, signal))
                        return signalSucceeds
                    },
                    isAlive: { [unowned self] in alive.contains($0) },
                    processName: { [unowned self] in names[$0] },
                    startTime: { [unowned self] pid in
                        guard alive.contains(pid) else { return nil }
                        return startTimes[pid] ?? UInt64(pid)
                    },
                    listeningPorts: { [unowned self] in listeningPorts[$0] },
                    now: { Date(timeIntervalSince1970: 1_000) },
                    schedule: { [unowned self] delay, work in scheduled.append((delay, work)) },
                    rescan: { [unowned self] workspace, panel in
                        rescans.append(PortScanner.PanelKey(workspaceId: workspace, panelId: panel))
                    },
                    workspaces: { [(id: workspaceId, title: "api")] },
                    panelExists: { _, _ in true }
                ),
                scanner: nil
            )
        }

        @MainActor
        func runScheduled() {
            let pending = scheduled
            scheduled = []
            for entry in pending { entry.work() }
        }
    }

    func testClosedPanelKeepsOnlySurvivorsWithMatchingName() {
        let fakes = Fakes()
        let store = fakes.makeStore()
        let panel = UUID()
        fakes.alive = [10, 11, 12]
        fakes.names = [10: "node", 11: "python3", 12: "ssh"]

        store.applyPanelProcesses(workspaceId: fakes.workspaceId, panelId: panel, processes: [
            ListeningProcess(pid: 10, command: "node", ports: [3000]),
            ListeningProcess(pid: 11, command: "python3", ports: [8000]),
            ListeningProcess(pid: 12, command: "node", ports: [4000]),
            ListeningProcess(pid: 13, command: "vite", ports: [5173]),
        ])
        XCTAssertEqual(store.badgeCount, 4)

        store.panelClosed(workspaceId: fakes.workspaceId, panelId: panel)
        XCTAssertEqual(fakes.scheduled.first?.delay, PortsHubStore.leftoverCheckDelay)
        fakes.runScheduled()

        // 12 was reused by another program, 13 died with its shell.
        XCTAssertEqual(store.leftovers.map(\.pid), [10, 11])
        XCTAssertEqual(store.leftovers.first?.workspaceTitle, "api")
        XCTAssertEqual(store.badgeCount, 2, "two leftover processes, no live ports remain")
    }

    func testRevalidateDropsLeftoverThatExited() {
        let fakes = Fakes()
        let store = fakes.makeStore()
        let panel = UUID()
        fakes.alive = [10]
        fakes.names = [10: "node"]
        store.applyPanelProcesses(workspaceId: fakes.workspaceId, panelId: panel, processes: [
            ListeningProcess(pid: 10, command: "node", ports: [3000]),
        ])
        store.panelClosed(workspaceId: fakes.workspaceId, panelId: panel)
        fakes.runScheduled()
        XCTAssertEqual(store.leftovers.count, 1)

        fakes.alive = []
        store.revalidateLeftovers()

        XCTAssertTrue(store.leftovers.isEmpty)
        XCTAssertEqual(store.badgeCount, 0)
    }

    func testLeftoversAreCapped() {
        let fakes = Fakes()
        let store = fakes.makeStore()
        let total = PortsHubStore.leftoverCap + 5
        for index in 0..<total {
            let pid = 1_000 + index
            fakes.alive.insert(pid)
            fakes.names[pid] = "node"
            let panel = UUID()
            store.applyPanelProcesses(workspaceId: fakes.workspaceId, panelId: panel, processes: [
                ListeningProcess(pid: pid, command: "node", ports: [20_000 + index]),
            ])
            store.panelClosed(workspaceId: fakes.workspaceId, panelId: panel)
        }
        fakes.runScheduled()

        XCTAssertEqual(store.leftovers.count, PortsHubStore.leftoverCap)
        XCTAssertEqual(store.leftovers.first?.pid, 1_005, "oldest leftovers are evicted first")
    }

    func testStopRefusesUntrackedAndProtectedPIDs() {
        let fakes = Fakes()
        let store = fakes.makeStore()
        fakes.alive = [1, 4242, Int(getpid())]

        XCTAssertEqual(store.stop(pid: 1), .refused(.invalidPID))
        XCTAssertEqual(store.stop(pid: Int(getpid())), .refused(.invalidPID))
        XCTAssertEqual(store.stop(pid: 4242), .refused(.notTracked))
        XCTAssertTrue(fakes.signals.isEmpty)
    }

    func testStopRefusesWhenPIDNowBelongsToAnotherProgram() {
        let fakes = Fakes()
        let store = fakes.makeStore()
        let panel = UUID()
        fakes.alive = [10]
        fakes.names = [10: "ssh"]
        store.applyPanelProcesses(workspaceId: fakes.workspaceId, panelId: panel, processes: [
            ListeningProcess(pid: 10, command: "node", ports: [3000]),
        ])

        XCTAssertEqual(store.stop(pid: 10), .refused(.processChanged))
        XCTAssertTrue(fakes.signals.isEmpty)
    }

    func testStopSendsTermThenKillWhenProcessSurvives() {
        let fakes = Fakes()
        let store = fakes.makeStore()
        let panel = UUID()
        fakes.alive = [10]
        fakes.names = [10: "node"]
        store.applyPanelProcesses(workspaceId: fakes.workspaceId, panelId: panel, processes: [
            ListeningProcess(pid: 10, command: "node", ports: [3000]),
        ])

        XCTAssertEqual(store.stop(pid: 10), .signaled)
        XCTAssertEqual(fakes.signals.map(\.signal), [SIGTERM])
        XCTAssertEqual(fakes.scheduled.last?.delay, PortsHubStore.killEscalationDelay)
        XCTAssertTrue(store.stoppingPIDs.contains(10))
        XCTAssertEqual(fakes.rescans.first?.panelId, panel)

        fakes.runScheduled()

        XCTAssertEqual(fakes.signals.map(\.signal), [SIGTERM, SIGKILL])
        XCTAssertTrue(store.stoppingPIDs.isEmpty)
    }

    func testStopDoesNotKillWhenProcessExitedAfterTerm() {
        let fakes = Fakes()
        let store = fakes.makeStore()
        let panel = UUID()
        fakes.alive = [10]
        fakes.names = [10: "node"]
        store.applyPanelProcesses(workspaceId: fakes.workspaceId, panelId: panel, processes: [
            ListeningProcess(pid: 10, command: "node", ports: [3000]),
        ])

        XCTAssertEqual(store.stop(pid: 10), .signaled)
        fakes.alive = []
        fakes.runScheduled()

        XCTAssertEqual(fakes.signals.map(\.signal), [SIGTERM])
    }

    func testStopRefusesWhenPIDWasReusedBySameNamedProcess() {
        let fakes = Fakes()
        let store = fakes.makeStore()
        let panel = UUID()
        fakes.alive = [10]
        fakes.names = [10: "node"]
        store.applyPanelProcesses(workspaceId: fakes.workspaceId, panelId: panel, processes: [
            ListeningProcess(pid: 10, command: "node", ports: [3000]),
        ])

        // The original node exited and a different node process received pid 10.
        fakes.startTimes[10] = 99_999

        XCTAssertEqual(store.stop(pid: 10), .refused(.processChanged))
        XCTAssertTrue(fakes.signals.isEmpty)
    }

    func testStopDoesNotEscalateToKillAfterPIDReuse() {
        let fakes = Fakes()
        let store = fakes.makeStore()
        let panel = UUID()
        fakes.alive = [10]
        fakes.names = [10: "node"]
        store.applyPanelProcesses(workspaceId: fakes.workspaceId, panelId: panel, processes: [
            ListeningProcess(pid: 10, command: "node", ports: [3000]),
        ])

        XCTAssertEqual(store.stop(pid: 10), .signaled)
        fakes.startTimes[10] = 99_999
        fakes.runScheduled()

        XCTAssertEqual(fakes.signals.map(\.signal), [SIGTERM])
    }

    func testLeftoverThatClosedItsPortsIsDroppedAndPortsAreRefreshed() {
        let fakes = Fakes()
        let store = fakes.makeStore()
        fakes.alive = [10, 11]
        fakes.names = [10: "node", 11: "python3"]
        for (pid, port) in [(10, 3000), (11, 8000)] {
            let panel = UUID()
            store.applyPanelProcesses(workspaceId: fakes.workspaceId, panelId: panel, processes: [
                ListeningProcess(pid: pid, command: fakes.names[pid]!, ports: [port]),
            ])
            store.panelClosed(workspaceId: fakes.workspaceId, panelId: panel)
        }
        fakes.listeningPorts = [10: [], 11: [8001]]
        fakes.runScheduled()

        XCTAssertEqual(store.leftovers.map(\.pid), [11], "pid 10 survived but no longer listens")
        XCTAssertEqual(store.leftovers.first?.ports, [8001])

        fakes.listeningPorts[11] = []
        store.revalidateLeftovers()

        XCTAssertTrue(store.leftovers.isEmpty)
        XCTAssertEqual(store.badgeCount, 0)
    }
}
