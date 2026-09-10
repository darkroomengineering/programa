import XCTest
import AppKit
import Combine
import Darwin
import os

#if canImport(Programa_DEV)
@testable import Programa_DEV
#elseif canImport(Programa)
@testable import Programa
#endif

private final class TestSocketPasswordCredentialHolder: Sendable {
    private let password: OSAllocatedUnfairLock<String>

    init(password: String) {
        self.password = OSAllocatedUnfairLock(initialState: password)
    }

    func update(password: String) {
        self.password.withLock { storedPassword in
            storedPassword = password
        }
    }

    var source: TerminalController.SocketPasswordCredentialSource {
        TerminalController.SocketPasswordCredentialSource(
            hasConfiguredPassword: { [self] in
                password.withLock { !$0.isEmpty }
            },
            verify: { [self] candidate in
                password.withLock { $0 == candidate }
            }
        )
    }
}

private struct MainQueueBlockedTelemetryObservation: Sendable {
    var responseReceived = false
    var responseOK = false
    var responseWorkspaceID: String?
    var responseKey: String?
    var responseValue: String?
    var mainQueueWasBlockedAtResponse = false
    var statusPublicationCountBeforeRelease: Int?
    var errorDescription: String?
}

private struct MainQueueBlockedQueryObservation: Sendable {
    var confirmedNoResponseWhileBlocked = false
    var responseArrivedWhileBlocked = false
    var responseOK = false
    var windowCount: Int?
    var errorDescription: String?
}

private struct MainQueueBlockedInvalidTelemetryObservation: Sendable {
    var reportTTYResponseOK: Bool?
    var reportTTYErrorCode: String?
    var reportTTYErrorMessage: String?
    var reportTTYResponseWhileBlocked = false
    var portsKickResponseOK: Bool?
    var portsKickErrorCode: String?
    var portsKickErrorMessage: String?
    var portsKickResponseWhileBlocked = false
    var reportPWDResponseOK: Bool?
    var reportPWDErrorCode: String?
    var reportPWDErrorMessage: String?
    var reportPWDResponseWhileBlocked = false
    var reportShellStateResponseOK: Bool?
    var reportShellStateErrorCode: String?
    var reportShellStateErrorMessage: String?
    var reportShellStateResponseWhileBlocked = false
    var reportAgentStateResponseOK: Bool?
    var reportAgentStateErrorCode: String?
    var reportAgentStateErrorMessage: String?
    var reportAgentStateResponseWhileBlocked = false
    var clearAgentStateResponseOK: Bool?
    var clearAgentStateErrorCode: String?
    var clearAgentStateErrorMessage: String?
    var clearAgentStateResponseWhileBlocked = false
    var setAgentPIDResponseOK: Bool?
    var setAgentPIDErrorCode: String?
    var setAgentPIDErrorMessage: String?
    var setAgentPIDResponseWhileBlocked = false
    var clearAgentPIDResponseOK: Bool?
    var clearAgentPIDErrorCode: String?
    var clearAgentPIDErrorMessage: String?
    var clearAgentPIDResponseWhileBlocked = false
    var setStatusResponseOK: Bool?
    var setStatusErrorCode: String?
    var setStatusErrorMessage: String?
    var setStatusResponseWhileBlocked = false
    var clearStatusResponseOK: Bool?
    var clearStatusErrorCode: String?
    var clearStatusErrorMessage: String?
    var clearStatusResponseWhileBlocked = false
    var errorDescription: String?
}

private struct PendingSurfaceWaitObservation: Sendable {
    var completed = false
    var responseOK = false
    var condition: String?
    var waited: Bool?
    var state: String?
    var source: String?
    var workspaceID: String?
    var surfaceID: String?
    var errorDescription: String?
}

private actor AgentPortPublicationGate {
    private var isReleased = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func pause() async {
        await withCheckedContinuation { continuation in
            if isReleased {
                continuation.resume()
            } else {
                releaseContinuation = continuation
            }
        }
    }

    func release() {
        isReleased = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

@MainActor
final class TerminalControllerSocketSecurityTests: XCTestCase {
    private func makeSocketPath(_ name: String) -> String {
        let shortID = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("csec-\(name.prefix(4))-\(shortID).sock")
            .path
    }

    override func setUp() {
        super.setUp()
        #if DEBUG
        TerminalController.shared.setSocketPasswordCredentialSourceForTesting(nil)
        #endif
        TerminalController.shared.stop()
    }

    override func tearDown() {
        TerminalController.shared.stop()
        #if DEBUG
        TerminalController.shared.setSocketPeerPIDProviderForTesting(nil)
        TerminalController.shared.setSocketPasswordCredentialSourceForTesting(nil)
        #endif
        super.tearDown()
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }

    private func makeIsolatedSurfaceTelemetryFixture() async throws -> (
        tabManager: TabManager,
        workspace: Workspace,
        surfaceId: UUID,
        directoryURL: URL
    ) {
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "programa-surface-telemetry-nonrepo-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        do {
            let tabManager = TabManager(initialWorkingDirectory: directoryURL.path)
            let workspace = try XCTUnwrap(tabManager.selectedWorkspace)
            let surfaceId = try XCTUnwrap(workspace.focusedPanelId)

            // The initial git probe applies its directory snapshot asynchronously via an
            // unstructured `Task { @MainActor in ... }` hop from a background probe queue.
            // That hop is only ever serviced by suspending this async test's own Task (so the
            // MainActor executor can drain its queue) -- a synchronous XCTWaiter/run-loop spin
            // (the old `waitUntil` helper) never observes it and hangs for the full timeout,
            // because XCTWaiter's nested CFRunLoop does not pump Swift Concurrency's MainActor
            // executor. Poll with real suspension points instead. Seed the same directory value
            // first, then wait for the non-repository probe to finish so no setup publication
            // can race the exact objectWillChange counts below.
            workspace.updatePanelDirectory(panelId: surfaceId, directory: directoryURL.path)
            let deadline = Date().addingTimeInterval(12.0)
            while !tabManager.activeWorkspaceGitProbePanelIdsForTesting(workspaceId: workspace.id).isEmpty {
                guard Date() < deadline else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(ETIMEDOUT), userInfo: [
                        NSLocalizedDescriptionKey: "Timed out waiting for the isolated workspace git probe",
                    ])
                }
                try await Task.sleep(nanoseconds: 20_000_000)
            }

            return (tabManager, workspace, surfaceId, directoryURL)
        } catch {
            try? FileManager.default.removeItem(at: directoryURL)
            throw error
        }
    }

#if DEBUG
    func testDebugCaptureLabelsCannotEscapeTheScreenshotDirectory() {
        let expectedDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-screenshots", isDirectory: true)
            .standardizedFileURL
        let captureID = "capture-id"
        let untrustedLabels = [
            "../escaped",
            "../../escaped",
            "nested/escaped",
            "nested\\escaped",
            "..",
        ]

        for label in untrustedLabels {
            let outputURL = TerminalController.debugCaptureOutputURL(
                label: label,
                captureID: captureID
            ).standardizedFileURL

            XCTAssertEqual(
                outputURL.deletingLastPathComponent(),
                expectedDirectory,
                "debug capture labels are caller-controlled and must never select a parent or nested directory: \(label)"
            )
            XCTAssertEqual(
                outputURL.pathComponents.count,
                expectedDirectory.pathComponents.count + 1,
                "a capture must always be one direct file child of the screenshot directory: \(label)"
            )
            XCTAssertFalse(outputURL.lastPathComponent.contains(".."))
            XCTAssertFalse(outputURL.lastPathComponent.contains("/"))
            XCTAssertFalse(outputURL.lastPathComponent.contains("\\"))
            XCTAssertTrue(outputURL.lastPathComponent.hasSuffix("_\(captureID).png"))
        }
    }

    func testDebugCapturePreservesAFilesystemSafeLabel() {
        let outputURL = TerminalController.debugCaptureOutputURL(
            label: "release-compare",
            captureID: "capture-id"
        )

        XCTAssertEqual(
            outputURL.lastPathComponent,
            "release-compare_capture-id.png",
            "confining untrusted labels must not discard an already-safe label used to identify a capture"
        )
    }

    /// A long-lived wait must occupy only its own client connection. Exact model queries from
    /// another client still need prompt main-actor access while that wait remains registered.
    func testPendingSurfaceWaitDoesNotBlockExactSurfaceQueryOnAnotherClient() async throws {
        let fixture = try await makeIsolatedSurfaceTelemetryFixture()
        let socketPath = makeSocketPath("surface-wait")
        let workspaceID = fixture.workspace.id.uuidString
        let surfaceID = fixture.surfaceId.uuidString

        XCTAssertTrue(
            fixture.tabManager.updateSurfaceAgentState(
                tabId: fixture.workspace.id,
                surfaceId: fixture.surfaceId,
                state: .idle,
                source: .hooks
            )
        )
        XCTAssertEqual(fixture.workspace.panelAgentStates[fixture.surfaceId], .idle)
        XCTAssertEqual(fixture.workspace.panelAgentStateSources[fixture.surfaceId], .hooks)

        TerminalController.shared.start(
            tabManager: fixture.tabManager,
            socketPath: socketPath,
            accessMode: .allowAll
        )
        defer {
            _ = fixture.tabManager.updateSurfaceAgentState(
                tabId: fixture.workspace.id,
                surfaceId: fixture.surfaceId,
                state: .working,
                source: .hooks
            )
            TerminalController.shared.stop()
            try? FileManager.default.removeItem(at: fixture.directoryURL)
        }
        try waitForSocket(at: socketPath)

        let waitObservation = OSAllocatedUnfairLock(initialState: PendingSurfaceWaitObservation())
        let waitFinished = expectation(description: "surface.wait returned after the public state report")
        DispatchQueue.global(qos: .userInitiated).async {
            defer {
                waitObservation.withLock { $0.completed = true }
                waitFinished.fulfill()
            }

            do {
                let response = try self.sendV2Request(
                    method: "surface.wait",
                    params: [
                        "workspace_id": workspaceID,
                        "surface_id": surfaceID,
                        "agent_state": "working",
                        "timeout_ms": 5_000,
                    ],
                    to: socketPath
                )
                let result = response["result"] as? [String: Any]
                waitObservation.withLock {
                    $0.responseOK = response["ok"] as? Bool == true
                    $0.condition = result?["condition"] as? String
                    $0.waited = result?["waited"] as? Bool
                    $0.state = result?["state"] as? String
                    $0.source = result?["source"] as? String
                    $0.workspaceID = result?["workspace_id"] as? String
                    $0.surfaceID = result?["surface_id"] as? String
                }
            } catch {
                waitObservation.withLock { $0.errorDescription = String(describing: error) }
            }
        }

        let registrationDeadline = Date().addingTimeInterval(2.0)
        while !AgentStateWaitRegistry.shared.hasPendingWaiterForTesting(
            surfaceId: fixture.surfaceId,
            condition: .working
        ), Date() < registrationDeadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        guard AgentStateWaitRegistry.shared.hasPendingWaiterForTesting(
            surfaceId: fixture.surfaceId,
            condition: .working
        ) else {
            _ = fixture.tabManager.updateSurfaceAgentState(
                tabId: fixture.workspace.id,
                surfaceId: fixture.surfaceId,
                state: .working,
                source: .hooks
            )
            await fulfillment(of: [waitFinished], timeout: 6.0)
            XCTFail("surface.wait did not register its working-state waiter before the deadline")
            return
        }
        XCTAssertFalse(
            waitObservation.withLock { $0.completed },
            "Registration must be observed while client A is still pending"
        )

        let currentResponse: [String: Any]
        do {
            currentResponse = try await sendV2RequestAsync(
                method: "surface.current",
                params: ["workspace_id": workspaceID],
                to: socketPath
            )
        } catch {
            _ = fixture.tabManager.updateSurfaceAgentState(
                tabId: fixture.workspace.id,
                surfaceId: fixture.surfaceId,
                state: .working,
                source: .hooks
            )
            await fulfillment(of: [waitFinished], timeout: 6.0)
            throw error
        }
        let currentResult = currentResponse["result"] as? [String: Any]
        XCTAssertTrue(currentResponse["ok"] as? Bool == true)
        XCTAssertEqual(currentResult?["workspace_id"] as? String, workspaceID)
        XCTAssertEqual(currentResult?["surface_id"] as? String, surfaceID)
        XCTAssertEqual(currentResult?["surface_type"] as? String, "terminal")
        XCTAssertFalse(
            waitObservation.withLock { $0.completed },
            "Client A must remain pending when client B receives the exact surface snapshot"
        )

        let reportResponse: [String: Any]
        do {
            reportResponse = try await sendV2RequestAsync(
                method: "surface.report_agent_state",
                params: [
                    "workspace_id": workspaceID,
                    "surface_id": surfaceID,
                    "state": "working",
                    "source": "hooks",
                ],
                to: socketPath
            )
        } catch {
            _ = fixture.tabManager.updateSurfaceAgentState(
                tabId: fixture.workspace.id,
                surfaceId: fixture.surfaceId,
                state: .working,
                source: .hooks
            )
            await fulfillment(of: [waitFinished], timeout: 6.0)
            throw error
        }
        let reportResult = reportResponse["result"] as? [String: Any]
        XCTAssertTrue(reportResponse["ok"] as? Bool == true)
        XCTAssertEqual(reportResult?["workspace_id"] as? String, workspaceID)
        XCTAssertEqual(reportResult?["surface_id"] as? String, surfaceID)
        XCTAssertEqual(reportResult?["state"] as? String, "working")
        XCTAssertEqual(reportResult?["source"] as? String, "hooks")

        await fulfillment(of: [waitFinished], timeout: 6.0)

        let observation = waitObservation.withLock { $0 }
        XCTAssertNil(observation.errorDescription)
        XCTAssertTrue(observation.completed)
        XCTAssertTrue(observation.responseOK)
        XCTAssertEqual(observation.condition, "agent_state")
        XCTAssertEqual(observation.waited, true)
        XCTAssertEqual(observation.state, "working")
        XCTAssertEqual(observation.source, "hooks")
        XCTAssertEqual(observation.workspaceID, workspaceID)
        XCTAssertEqual(observation.surfaceID, surfaceID)
        XCTAssertFalse(
            AgentStateWaitRegistry.shared.hasPendingWaiterForTesting(
                surfaceId: fixture.surfaceId,
                condition: .working
            )
        )
    }
#endif

    func testDuplicateSurfacePortsReportDoesNotRepublishWorkspace() async throws {
        let fixture = try await makeIsolatedSurfaceTelemetryFixture()
        let tabManager = fixture.tabManager
        let workspace = fixture.workspace
        let surfaceId = fixture.surfaceId
        let reportedPorts = [4242, 5173]

        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }

        TerminalController.shared.start(
            tabManager: tabManager,
            socketPath: makeSocketPath("ports-dedup"),
            accessMode: .allowAll
        )

        _ = TerminalController.shared.v2SurfaceReportPorts(params: [
            "workspace_id": workspace.id.uuidString,
            "surface_id": surfaceId.uuidString,
            "ports": reportedPorts,
        ])
        await drainMainQueue()
        XCTAssertEqual(workspace.surfaceListeningPorts[surfaceId], reportedPorts)
        XCTAssertEqual(workspace.listeningPorts, reportedPorts)

        var publishCount = 0
        let cancellable = workspace.objectWillChange.sink { _ in
            publishCount += 1
        }
        defer { cancellable.cancel() }

        _ = TerminalController.shared.v2SurfaceReportPorts(params: [
            "workspace_id": workspace.id.uuidString,
            "surface_id": surfaceId.uuidString,
            "ports": reportedPorts,
        ])
        await drainMainQueue()

        XCTAssertEqual(
            publishCount,
            0,
            "An identical ports report must not invalidate every workspace observer"
        )
        XCTAssertEqual(workspace.surfaceListeningPorts[surfaceId], reportedPorts)
        XCTAssertEqual(workspace.listeningPorts, reportedPorts)
    }

    func testSurfacePortsReportEnforcesInclusiveCountBoundThroughSocket() async throws {
        let fixture = try await makeIsolatedSurfaceTelemetryFixture()
        let workspace = fixture.workspace
        let surfaceId = fixture.surfaceId
        let socketPath = makeSocketPath("ports-bound")
        let maximumReportedPorts = 65_535
        let acceptedPorts = Array(1...maximumReportedPorts)

        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }

        TerminalController.shared.start(
            tabManager: fixture.tabManager,
            socketPath: socketPath,
            accessMode: .allowAll
        )
        try waitForSocket(at: socketPath)

        let acceptedResult = TerminalController.shared.v2SurfaceReportPorts(params: [
            "workspace_id": workspace.id.uuidString,
            "surface_id": surfaceId.uuidString,
            "ports": acceptedPorts,
        ])
        guard case .ok = acceptedResult else {
            XCTFail("The inclusive reported-port count limit must remain accepted")
            return
        }
        await drainMainQueue()
        XCTAssertTrue(
            workspace.surfaceListeningPorts[surfaceId] == acceptedPorts,
            "An accepted boundary-sized report must reach the surface telemetry model"
        )

        let oversizedResponse = try await sendV2RequestAsync(
            method: "surface.report_ports",
            params: [
                "workspace_id": workspace.id.uuidString,
                "surface_id": surfaceId.uuidString,
                "ports": Array(repeating: 5173, count: maximumReportedPorts + 1),
            ],
            to: socketPath
        )
        let oversizedError = oversizedResponse["error"] as? [String: Any]
        XCTAssertEqual(
            oversizedResponse["ok"] as? Bool,
            false,
            "A report above the count limit must be rejected before model mutation"
        )
        XCTAssertEqual(oversizedError?["code"] as? String, "invalid_params")

        await drainMainQueue()
        XCTAssertTrue(
            workspace.surfaceListeningPorts[surfaceId] == acceptedPorts,
            "Rejected ingress must not replace the last accepted surface ports after main-queue work drains"
        )
    }

    func testSurfacePortsReportCanonicalizesDuplicateUnorderedPortsThroughSocket() async throws {
        let fixture = try await makeIsolatedSurfaceTelemetryFixture()
        let workspace = fixture.workspace
        let surfaceId = fixture.surfaceId
        let socketPath = makeSocketPath("ports-canonical")
        let canonicalPorts = [3000, 5173]

        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }

        TerminalController.shared.start(
            tabManager: fixture.tabManager,
            socketPath: socketPath,
            accessMode: .allowAll
        )
        try waitForSocket(at: socketPath)

        let response = try await sendV2RequestAsync(
            method: "surface.report_ports",
            params: [
                "workspace_id": workspace.id.uuidString,
                "surface_id": surfaceId.uuidString,
                "ports": [5173, 3000, 5173],
            ],
            to: socketPath
        )
        let result = response["result"] as? [String: Any]
        XCTAssertEqual(response["ok"] as? Bool, true, "Unexpected JSON-RPC response: \(response)")
        XCTAssertEqual(
            result?["ports"] as? [Int],
            canonicalPorts,
            "The acknowledgement must expose the set semantics of reported listening ports"
        )
        XCTAssertTrue(
            waitUntil { workspace.surfaceListeningPorts[surfaceId] == canonicalPorts },
            "Surface telemetry must store ports in the same canonical form returned to callers"
        )
        XCTAssertEqual(workspace.listeningPorts, canonicalPorts)
    }

    func testSurfacePortsReportPrunesOnlyChangedPublishedMetadata() async throws {
        let fixture = try await makeIsolatedSurfaceTelemetryFixture()
        let tabManager = fixture.tabManager
        let workspace = fixture.workspace
        let surfaceId = fixture.surfaceId
        let staleSurfaceId = UUID()
        let reportedPorts = [4242, 5173]

        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }

        TerminalController.shared.start(
            tabManager: tabManager,
            socketPath: makeSocketPath("ports-prune"),
            accessMode: .allowAll
        )

        _ = TerminalController.shared.v2SurfaceReportPorts(params: [
            "workspace_id": workspace.id.uuidString,
            "surface_id": surfaceId.uuidString,
            "ports": reportedPorts,
        ])
        await drainMainQueue()

        workspace.panelTitles[surfaceId] = "Valid surface"
        workspace.panelTitles[staleSurfaceId] = "Closed surface"

        var publishCount = 0
        let cancellable = workspace.objectWillChange.sink { _ in
            publishCount += 1
        }
        defer { cancellable.cancel() }

        _ = TerminalController.shared.v2SurfaceReportPorts(params: [
            "workspace_id": workspace.id.uuidString,
            "surface_id": surfaceId.uuidString,
            "ports": reportedPorts,
        ])
        await drainMainQueue()

        XCTAssertNil(workspace.panelTitles[staleSurfaceId])
        XCTAssertEqual(workspace.panelTitles[surfaceId], "Valid surface")
        XCTAssertEqual(workspace.surfaceListeningPorts[surfaceId], reportedPorts)
        XCTAssertEqual(workspace.listeningPorts, reportedPorts)
        XCTAssertEqual(
            publishCount,
            1,
            "Pruning one stale published collection must emit once without republishing unchanged collections"
        )
    }

    func testSurfacePortsReportPrunesStaleTTYAndPortsWithoutDisturbingLiveSurface() async throws {
        let fixture = try await makeIsolatedSurfaceTelemetryFixture()
        let tabManager = fixture.tabManager
        let workspace = fixture.workspace
        let surfaceId = fixture.surfaceId
        let staleSurfaceId = UUID()
        let reportedPorts = [4242, 5173]

        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }

        TerminalController.shared.start(
            tabManager: tabManager,
            socketPath: makeSocketPath("tty-port-prune"),
            accessMode: .allowAll
        )

        _ = TerminalController.shared.v2SurfaceReportPorts(params: [
            "workspace_id": workspace.id.uuidString,
            "surface_id": surfaceId.uuidString,
            "ports": reportedPorts,
        ])
        await drainMainQueue()

        workspace.surfaceTTYNames[surfaceId] = "ttys-live"
        workspace.surfaceTTYNames[staleSurfaceId] = "ttys-stale"
        workspace.surfaceListeningPorts[staleSurfaceId] = reportedPorts

        var publishCount = 0
        let cancellable = workspace.objectWillChange.sink { _ in
            publishCount += 1
        }
        defer { cancellable.cancel() }

        _ = TerminalController.shared.v2SurfaceReportPorts(params: [
            "workspace_id": workspace.id.uuidString,
            "surface_id": surfaceId.uuidString,
            "ports": reportedPorts,
        ])
        await drainMainQueue()

        XCTAssertNil(workspace.surfaceTTYNames[staleSurfaceId])
        XCTAssertNil(workspace.surfaceListeningPorts[staleSurfaceId])
        XCTAssertEqual(workspace.surfaceTTYNames[surfaceId], "ttys-live")
        XCTAssertEqual(workspace.surfaceListeningPorts[surfaceId], reportedPorts)
        XCTAssertEqual(workspace.listeningPorts, reportedPorts)
        XCTAssertEqual(
            publishCount,
            1,
            "Removing stale TTY bookkeeping and one stale published ports entry must emit only for the published change"
        )
    }

    func testClearingEmptyWorkspaceTelemetryDoesNotRepublishWorkspace() async {
        let tabManager = TabManager()
        let workspace = tabManager.addWorkspace(select: true, eagerLoadTerminal: false)
        let socketPath = makeSocketPath("empty-telemetry")

        TerminalController.shared.start(
            tabManager: tabManager,
            socketPath: socketPath,
            accessMode: .allowAll
        )
        await drainMainQueue()

        workspace.statusEntries["present"] = SidebarStatusEntry(key: "present", value: "running")
        workspace.logEntries = [
            SidebarLogEntry(message: "running", level: .progress, source: nil, timestamp: Date()),
        ]
        workspace.progress = SidebarProgressState(value: 0.5, label: "running")

        var publishCount = 0
        let cancellable = workspace.objectWillChange.sink { _ in
            publishCount += 1
        }
        defer { cancellable.cancel() }

        _ = TerminalController.shared.v2WorkspaceClearStatus(params: [
            "workspace_id": workspace.id.uuidString,
            "key": "present",
        ])
        _ = TerminalController.shared.v2WorkspaceClearLog(params: [
            "workspace_id": workspace.id.uuidString,
        ])
        _ = TerminalController.shared.v2WorkspaceClearProgress(params: [
            "workspace_id": workspace.id.uuidString,
        ])
        await drainMainQueue()

        XCTAssertNil(workspace.statusEntries["present"])
        XCTAssertTrue(workspace.logEntries.isEmpty)
        XCTAssertNil(workspace.progress)
        XCTAssertGreaterThanOrEqual(
            publishCount,
            3,
            "Populated clear commands should reach the workspace and publish their removals"
        )

        publishCount = 0

        _ = TerminalController.shared.v2WorkspaceClearStatus(params: [
            "workspace_id": workspace.id.uuidString,
            "key": "missing",
        ])
        _ = TerminalController.shared.v2WorkspaceClearLog(params: [
            "workspace_id": workspace.id.uuidString,
        ])
        _ = TerminalController.shared.v2WorkspaceClearProgress(params: [
            "workspace_id": workspace.id.uuidString,
        ])
        await drainMainQueue()

        XCTAssertEqual(
            publishCount,
            0,
            "Clearing telemetry that is already absent should not invalidate workspace observers"
        )
    }

    func testExplicitInvalidWorkspaceSelectorCannotReadOrMutateSelectedWorkspaceThroughSocket() async throws {
        let socketPath = makeSocketPath("invalid-workspace")
        let manager = TabManager()
        let selectedWorkspace = try XCTUnwrap(manager.selectedWorkspace)
        let otherWorkspace = manager.addWorkspace(select: false, eagerLoadTerminal: false)
        let selectedStatus = SidebarStatusEntry(key: "selected-status", value: "selected-running")
        let selectedMetadata = SidebarMetadataBlock(
            key: "selected-metadata",
            markdown: "selected-details",
            priority: 7,
            timestamp: Date(timeIntervalSince1970: 1)
        )
        let selectedLog = SidebarLogEntry(
            message: "selected-log",
            level: .warning,
            source: "selected-source",
            timestamp: Date(timeIntervalSince1970: 2)
        )
        let selectedProgress = SidebarProgressState(value: 0.75, label: "selected-progress")

        selectedWorkspace.statusEntries[selectedStatus.key] = selectedStatus
        selectedWorkspace.metadataBlocks[selectedMetadata.key] = selectedMetadata
        selectedWorkspace.logEntries = [selectedLog]
        selectedWorkspace.progress = selectedProgress
        otherWorkspace.statusEntries["other-status"] = SidebarStatusEntry(
            key: "other-status",
            value: "other-running"
        )
        otherWorkspace.metadataBlocks["other-metadata"] = SidebarMetadataBlock(
            key: "other-metadata",
            markdown: "other-details",
            priority: 3,
            timestamp: Date(timeIntervalSince1970: 3)
        )

        XCTAssertEqual(manager.selectedTabId, selectedWorkspace.id)

        TerminalController.shared.start(
            tabManager: manager,
            socketPath: socketPath,
            accessMode: .allowAll
        )
        try waitForSocket(at: socketPath)

        for invalidWorkspaceID in ["not-a-workspace-id", "workspace:0", UUID().uuidString] {
            let response = try await sendV2RequestAsync(
                method: "workspace.list_status",
                params: ["workspace_id": invalidWorkspaceID],
                to: socketPath
            )

            XCTAssertEqual(
                response["ok"] as? Bool,
                false,
                "An explicit invalid workspace_id must not fall back to the selected workspace: \(response)"
            )
            XCTAssertNotNil(response["error"], "Expected an error response for \(invalidWorkspaceID)")
            XCTAssertEqual(selectedWorkspace.statusEntries[selectedStatus.key], selectedStatus)
        }

        let clearResponse = try await sendV2RequestAsync(
            method: "workspace.clear_meta_block",
            params: [
                "workspace_id": "not-a-workspace-id",
                "key": selectedMetadata.key,
            ],
            to: socketPath
        )

        XCTAssertEqual(
            clearResponse["ok"] as? Bool,
            false,
            "An explicit malformed workspace_id must not clear metadata from the selected workspace: \(clearResponse)"
        )
        XCTAssertNotNil(clearResponse["error"])
        XCTAssertEqual(selectedWorkspace.metadataBlocks[selectedMetadata.key], selectedMetadata)

        // Restore the sentinel independently so reset_sidebar proves its own destructive boundary
        // even when the pre-fix clear_meta_block assertion above records a failure and removes it.
        selectedWorkspace.metadataBlocks[selectedMetadata.key] = selectedMetadata

        let resetResponse = try await sendV2RequestAsync(
            method: "workspace.reset_sidebar",
            params: ["workspace_id": "not-a-workspace-id"],
            to: socketPath
        )

        XCTAssertEqual(
            resetResponse["ok"] as? Bool,
            false,
            "An explicit malformed workspace_id must not reset the selected workspace: \(resetResponse)"
        )
        XCTAssertNotNil(resetResponse["error"])
        XCTAssertEqual(selectedWorkspace.statusEntries[selectedStatus.key], selectedStatus)
        XCTAssertEqual(selectedWorkspace.metadataBlocks[selectedMetadata.key], selectedMetadata)
        XCTAssertEqual(selectedWorkspace.logEntries, [selectedLog])
        XCTAssertEqual(selectedWorkspace.progress, selectedProgress)
        XCTAssertEqual(otherWorkspace.statusEntries["other-status"]?.value, "other-running")
        XCTAssertEqual(otherWorkspace.metadataBlocks["other-metadata"]?.markdown, "other-details")
    }

    /// Regression for #6618: `shouldPublishShellActivity` used to record the state
    /// it was queried with (write-on-read). When a report arrived before the panel
    /// existed, that premature write suppressed every later identical report, so the
    /// panel's shell state stayed `.unknown` forever. The read and the write are now
    /// split — `recordShellActivity` is the only writer and runs only after a
    /// confirmed main-thread apply.
    func testShellActivityDedupDoesNotSuppressWhenApplyWasNeverRecorded() {
        let fastPath = TerminalController.SocketFastPathState()
        let workspaceId = UUID()
        let panelId = UUID()
        let idle = Workspace.PanelShellActivityState.promptIdle

        // First report for this surface must publish.
        XCTAssertTrue(fastPath.shouldPublishShellActivity(
            workspaceId: workspaceId, panelId: panelId, state: idle))

        // The panel was absent, so the apply was never recorded. Querying again must
        // NOT have been suppressed by the previous read (the core of the #6618 bug).
        XCTAssertTrue(fastPath.shouldPublishShellActivity(
            workspaceId: workspaceId, panelId: panelId, state: idle))

        // After a confirmed apply is recorded, the identical report is deduped.
        // recordShellActivity hops a serial queue; the subsequent sync read is FIFO-
        // ordered behind it, so this is deterministic without sleeping.
        fastPath.recordShellActivity(workspaceId: workspaceId, panelId: panelId, state: idle)
        XCTAssertFalse(fastPath.shouldPublishShellActivity(
            workspaceId: workspaceId, panelId: panelId, state: idle))

        // A different state always publishes.
        XCTAssertTrue(fastPath.shouldPublishShellActivity(
            workspaceId: workspaceId, panelId: panelId, state: .commandRunning))
    }

    func testSocketPermissionsFollowAccessMode() throws {
        let tabManager = TabManager()

        let allowAllPath = makeSocketPath("allow-all")
        TerminalController.shared.start(
            tabManager: tabManager,
            socketPath: allowAllPath,
            accessMode: .allowAll
        )
        try waitForSocket(at: allowAllPath)
        XCTAssertEqual(try socketMode(at: allowAllPath), 0o666)

        TerminalController.shared.stop()

        let restrictedPath = makeSocketPath("cmux-only")
        TerminalController.shared.start(
            tabManager: tabManager,
            socketPath: restrictedPath,
            accessMode: .cmuxOnly
        )
        try waitForSocket(at: restrictedPath)
        XCTAssertEqual(try socketMode(at: restrictedPath), 0o600)
    }

    #if DEBUG
    func testCmuxOnlyRejectsSameUserWhenPeerProcessCannotBeVerified() throws {
        TerminalController.shared.setSocketPeerPIDProviderForTesting { _ in nil }
        let path = makeSocketPath("unverified-peer")
        TerminalController.shared.start(tabManager: TabManager(), socketPath: path, accessMode: .cmuxOnly)
        try waitForSocket(at: path)
        let client = try connectPersistentClient(to: path)
        defer { Darwin.close(client) }
        // The rejection is sent before request processing, so do not race it with a write.
        XCTAssertEqual(try readLine(from: client, timeout: 1), "ERROR: Unable to verify client process")
    }

    func testVerifiedOwnedProcessAndAutomationClientsCanStillPing() throws {
        let path = makeSocketPath("verified-peer")
        TerminalController.shared.start(tabManager: TabManager(), socketPath: path, accessMode: .cmuxOnly)
        try waitForSocket(at: path)
        XCTAssertTrue(isSuccessfulV2Ping(try sendV2Request(method: "system.ping", params: [:], to: path)))
        TerminalController.shared.stop()
        TerminalController.shared.setSocketPeerPIDProviderForTesting { _ in nil }
        TerminalController.shared.start(tabManager: TabManager(), socketPath: path, accessMode: .automation)
        try waitForSocket(at: path)
        XCTAssertTrue(isSuccessfulV2Ping(try sendV2Request(method: "system.ping", params: [:], to: path)))
    }
    #endif

    func testStopRevokesEstablishedAllowAllClient() throws {
        let socketPath = makeSocketPath("stop-revocation")
        TerminalController.shared.start(
            tabManager: TabManager(),
            socketPath: socketPath,
            accessMode: .allowAll
        )
        try waitForSocket(at: socketPath)

        let clientFD = try connectPersistentClient(to: socketPath)
        defer { Darwin.close(clientFD) }

        let initialResponse = try sendV2Ping(to: clientFD, id: 1)
        XCTAssertTrue(
            isSuccessfulV2Ping(initialResponse),
            "The established client must reach the real JSON-RPC handler before revocation is tested"
        )

        TerminalController.shared.stop()

        let postStopResponse = try? sendV2Ping(to: clientFD, id: 2, timeout: 1.0)
        XCTAssertFalse(
            postStopResponse.map(isSuccessfulV2Ping) ?? false,
            "Stopping socket control must revoke established clients, not only reject new connections"
        )
    }

    func testRestartOnSamePathRevokesOldClientAndAcceptsNewClient() throws {
        let socketPath = makeSocketPath("restart-revocation")
        let tabManager = TabManager()
        TerminalController.shared.start(
            tabManager: tabManager,
            socketPath: socketPath,
            accessMode: .allowAll
        )
        try waitForSocket(at: socketPath)

        let oldClientFD = try connectPersistentClient(to: socketPath)
        defer { Darwin.close(oldClientFD) }

        let initialResponse = try sendV2Ping(to: oldClientFD, id: 1)
        XCTAssertTrue(
            isSuccessfulV2Ping(initialResponse),
            "The old client must be established before the listener restarts"
        )

        TerminalController.shared.stop()
        TerminalController.shared.start(
            tabManager: tabManager,
            socketPath: socketPath,
            accessMode: .allowAll
        )
        try waitForSocket(at: socketPath)

        let oldClientResponse = try? sendV2Ping(to: oldClientFD, id: 2, timeout: 1.0)
        XCTAssertFalse(
            oldClientResponse.map(isSuccessfulV2Ping) ?? false,
            "Restarting the listener must not preserve authority held by a client from the previous listener"
        )

        let newClientResponse = try sendV2Request(
            method: "system.ping",
            params: [:],
            to: socketPath
        )
        XCTAssertTrue(
            isSuccessfulV2Ping(newClientResponse),
            "The restarted listener must accept newly connected clients"
        )
    }

    func testAccessModeChangeOnSamePathRevokesOldClientAndAcceptsNewClient() throws {
        let socketPath = makeSocketPath("mode-revocation")
        let tabManager = TabManager()
        TerminalController.shared.start(
            tabManager: tabManager,
            socketPath: socketPath,
            accessMode: .allowAll
        )
        try waitForSocket(at: socketPath)

        let oldClientFD = try connectPersistentClient(to: socketPath)
        defer { Darwin.close(oldClientFD) }

        let initialResponse = try sendV2Ping(to: oldClientFD, id: 1)
        XCTAssertTrue(
            isSuccessfulV2Ping(initialResponse),
            "The old client must be established under the original access mode"
        )

        TerminalController.shared.start(
            tabManager: tabManager,
            socketPath: socketPath,
            accessMode: .automation
        )
        try waitForSocket(at: socketPath)

        let oldClientResponse = try? sendV2Ping(to: oldClientFD, id: 2, timeout: 1.0)
        XCTAssertFalse(
            oldClientResponse.map(isSuccessfulV2Ping) ?? false,
            "Changing access mode must revoke authority granted by the previous mode"
        )

        let newClientResponse = try sendV2Request(
            method: "system.ping",
            params: [:],
            to: socketPath
        )
        XCTAssertTrue(
            isSuccessfulV2Ping(newClientResponse),
            "The replacement listener must accept clients under the new access mode"
        )
    }

    func testPasswordModeRejectsUnauthenticatedCommands() throws {
        let socketPath = makeSocketPath("password-mode")
        let tabManager = TabManager()

        TerminalController.shared.start(
            tabManager: tabManager,
            socketPath: socketPath,
            accessMode: .password
        )
        try waitForSocket(at: socketPath)

        let pingOnly = try sendCommands(["ping"], to: socketPath)
        XCTAssertEqual(pingOnly.count, 1)
        XCTAssertTrue(pingOnly[0].hasPrefix("ERROR:"))
        XCTAssertFalse(pingOnly[0].localizedCaseInsensitiveContains("PONG"))

        let wrongAuthThenPing = try sendCommands(
            ["auth not-the-password", "ping"],
            to: socketPath
        )
        XCTAssertEqual(wrongAuthThenPing.count, 2)
        XCTAssertTrue(wrongAuthThenPing[0].hasPrefix("ERROR:"))
        XCTAssertTrue(wrongAuthThenPing[1].hasPrefix("ERROR:"))
    }

    #if DEBUG
    func testPasswordRotationRevokesAuthenticatedClientAndRequiresNewCredential() throws {
        let oldPassword = "old-test-password"
        let newPassword = "new-test-password"
        let credentials = TestSocketPasswordCredentialHolder(password: oldPassword)
        TerminalController.shared.setSocketPasswordCredentialSourceForTesting(credentials.source)

        let socketPath = makeSocketPath("password-rotation")
        TerminalController.shared.start(
            tabManager: TabManager(),
            socketPath: socketPath,
            accessMode: .password
        )
        try waitForSocket(at: socketPath)

        let oldClientFD = try connectPersistentClient(to: socketPath)
        defer { Darwin.close(oldClientFD) }

        let oldAuthentication = try sendV2Request(
            method: "auth.login",
            params: ["password": oldPassword],
            id: 1,
            to: oldClientFD
        )
        XCTAssertTrue(
            isSuccessfulV2Authentication(oldAuthentication),
            "The persistent client must authenticate with the credential active when it connects"
        )
        XCTAssertTrue(
            isSuccessfulV2Ping(try sendV2Ping(to: oldClientFD, id: 2)),
            "An authenticated password-mode client must be able to execute commands before rotation"
        )

        credentials.update(password: newPassword)
        NotificationCenter.default.post(
            name: SocketControlPasswordStore.didChangeNotification,
            object: nil
        )

        let revokedClientResponse = try? sendV2Ping(to: oldClientFD, id: 3, timeout: 1.0)
        XCTAssertFalse(
            revokedClientResponse.map(isSuccessfulV2Ping) ?? false,
            "Rotating the socket password must revoke clients authenticated with the previous credential"
        )

        let newClientFD = try connectPersistentClient(to: socketPath)
        defer { Darwin.close(newClientFD) }

        let staleAuthentication = try sendV2Request(
            method: "auth.login",
            params: ["password": oldPassword],
            id: 4,
            to: newClientFD
        )
        XCTAssertEqual(
            v2ErrorCode(staleAuthentication),
            "auth_failed",
            "A new client must not authenticate with the credential that was rotated away"
        )

        let newAuthentication = try sendV2Request(
            method: "auth.login",
            params: ["password": newPassword],
            id: 5,
            to: newClientFD
        )
        XCTAssertTrue(
            isSuccessfulV2Authentication(newAuthentication),
            "A new client must authenticate with the replacement credential"
        )
        XCTAssertTrue(
            isSuccessfulV2Ping(try sendV2Ping(to: newClientFD, id: 6)),
            "A client authenticated after rotation must retain normal command access"
        )
    }
    #endif

    func testSocketCommandPolicyDistinguishesFocusIntent() throws {
#if DEBUG
        // The v1 line protocol was removed: isV2: false is now unreachable from any real
        // socket command (only v2 JSON-RPC is dispatched), and always denies focus
        // mutation regardless of commandKey — verify that fallback explicitly.
        let nonFocus = TerminalController.debugSocketCommandPolicySnapshot(
            commandKey: "ping",
            isV2: false
        )
        XCTAssertTrue(nonFocus.insideSuppressed)
        XCTAssertFalse(nonFocus.insideAllowsFocus)
        XCTAssertFalse(nonFocus.outsideSuppressed)
        XCTAssertFalse(nonFocus.outsideAllowsFocus)

        let windowFocus = TerminalController.debugSocketCommandPolicySnapshot(
            commandKey: "window.focus",
            isV2: true
        )
        XCTAssertTrue(windowFocus.insideSuppressed)
        XCTAssertTrue(windowFocus.insideAllowsFocus)
        XCTAssertFalse(windowFocus.outsideSuppressed)

        let focusV2 = TerminalController.debugSocketCommandPolicySnapshot(
            commandKey: "workspace.select",
            isV2: true
        )
        XCTAssertTrue(focusV2.insideSuppressed)
        XCTAssertTrue(focusV2.insideAllowsFocus)
        XCTAssertFalse(focusV2.outsideSuppressed)

        let moveWorkspace = TerminalController.debugSocketCommandPolicySnapshot(
            commandKey: "workspace.move_to_window",
            isV2: true
        )
        XCTAssertTrue(moveWorkspace.insideSuppressed)
        XCTAssertFalse(moveWorkspace.insideAllowsFocus)

        let triggerFlash = TerminalController.debugSocketCommandPolicySnapshot(
            commandKey: "surface.trigger_flash",
            isV2: true
        )
        XCTAssertTrue(triggerFlash.insideSuppressed)
        XCTAssertFalse(triggerFlash.insideAllowsFocus)

        let simulateShortcut = TerminalController.debugSocketCommandPolicySnapshot(
            commandKey: "debug.shortcut.simulate",
            isV2: true
        )
        XCTAssertTrue(simulateShortcut.insideSuppressed)
        XCTAssertFalse(simulateShortcut.insideAllowsFocus)

        let settingsOpen = TerminalController.debugSocketCommandPolicySnapshot(
            commandKey: "settings.open",
            isV2: true
        )
        XCTAssertTrue(settingsOpen.insideSuppressed)
        XCTAssertFalse(settingsOpen.insideAllowsFocus)

        let feedbackOpen = TerminalController.debugSocketCommandPolicySnapshot(
            commandKey: "feedback.open",
            isV2: true
        )
        XCTAssertTrue(feedbackOpen.insideSuppressed)
        XCTAssertFalse(feedbackOpen.insideAllowsFocus)

        let debugType = TerminalController.debugSocketCommandPolicySnapshot(
            commandKey: "debug.type",
            isV2: true
        )
        XCTAssertTrue(debugType.insideSuppressed)
        XCTAssertFalse(debugType.insideAllowsFocus)
#else
        throw XCTSkip("Socket command policy snapshot helper is debug-only.")
#endif
    }

    func testNotificationCreateUsesExplicitSurfaceIDWhenProvided() async throws {
        let socketPath = makeSocketPath("notify-surface")
        let store = TerminalNotificationStore.shared
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = appDelegate.tabManager ?? TabManager()

        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore

        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, _ in }
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store

        let workspace = manager.addWorkspace(select: true)
        defer {
            if manager.tabs.contains(where: { $0.id == workspace.id }) {
                manager.closeWorkspace(workspace)
            }
            store.replaceNotificationsForTesting([])
            store.resetNotificationDeliveryHandlerForTesting()
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
        }

        guard let focusedPanelId = workspace.focusedPanelId else {
            XCTFail("Expected selected workspace with a focused panel")
            return
        }
        guard let targetPanel = workspace.newTerminalSplit(from: focusedPanelId, orientation: .horizontal) else {
            XCTFail("Expected split panel to be created")
            return
        }
        workspace.focusPanel(focusedPanelId)

        TerminalController.shared.start(
            tabManager: manager,
            socketPath: socketPath,
            accessMode: .allowAll
        )
        try waitForSocket(at: socketPath)

        let response = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let response = try self.sendV2Request(
                        method: "notification.create",
                        params: [
                            "workspace_id": workspace.id.uuidString,
                            "surface_id": targetPanel.id.uuidString,
                            "title": "Targeted"
                        ],
                        to: socketPath
                    )
                    continuation.resume(returning: response)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }

        XCTAssertEqual(response["ok"] as? Bool, true, "Unexpected JSON-RPC response: \(response)")
        let result = try XCTUnwrap(response["result"] as? [String: Any], "Unexpected JSON-RPC response: \(response)")
        XCTAssertEqual(result["surface_id"] as? String, targetPanel.id.uuidString)
        XCTAssertTrue(store.hasUnreadNotification(forTabId: workspace.id, surfaceId: targetPanel.id))
        XCTAssertFalse(store.hasUnreadNotification(forTabId: workspace.id, surfaceId: focusedPanelId))
    }

    /// High-frequency telemetry must acknowledge independently of the main queue so shell-side
    /// reporters cannot stall behind UI work. The model mutation remains main-queue confined and
    /// is applied only after that queue becomes available.
    func testWorkspaceStatusTelemetryAcknowledgesWhileMainQueueIsOccupiedThenMutatesAfterRelease() async throws {
        let socketPath = makeSocketPath("status-lane")
        let manager = TabManager()
        let workspace = manager.addWorkspace(select: true, eagerLoadTerminal: false)
        let workspaceID = workspace.id.uuidString
        let statusKey = "build"
        let statusValue = "running"

        defer {
            if manager.tabs.contains(where: { $0.id == workspace.id }) {
                manager.closeWorkspace(workspace)
            }
        }

        TerminalController.shared.start(
            tabManager: manager,
            socketPath: socketPath,
            accessMode: .allowAll
        )
        defer { TerminalController.shared.stop() }
        try waitForSocket(at: socketPath)

        let clientFD = try connectPersistentClient(to: socketPath)
        defer {
            _ = Darwin.shutdown(clientFD, SHUT_RDWR)
            Darwin.close(clientFD)
        }

        let statusPublicationCount = OSAllocatedUnfairLock(initialState: 0)
        let statusCancellable = workspace.$statusEntries.dropFirst().sink { _ in
            statusPublicationCount.withLock { $0 += 1 }
        }
        defer { statusCancellable.cancel() }

        let mainQueueEntered = DispatchSemaphore(value: 0)
        let mainQueueRelease = DispatchSemaphore(value: 0)
        defer { mainQueueRelease.signal() }

        let mainQueueBlockReturned = OSAllocatedUnfairLock(initialState: false)
        let mainQueueBlockTimedOut = OSAllocatedUnfairLock(initialState: false)
        let observation = OSAllocatedUnfairLock(initialState: MainQueueBlockedTelemetryObservation())
        let clientFinished = expectation(description: "telemetry response received while main queue is occupied")

        DispatchQueue.main.async {
            mainQueueEntered.signal()
            let waitResult = mainQueueRelease.wait(timeout: .now() + 3.0)
            mainQueueBlockTimedOut.withLock { $0 = waitResult == .timedOut }
            mainQueueBlockReturned.withLock { $0 = true }
        }

        DispatchQueue.global(qos: .userInitiated).async {
            defer {
                mainQueueRelease.signal()
                clientFinished.fulfill()
            }

            guard mainQueueEntered.wait(timeout: .now() + 1.0) == .success else {
                observation.withLock {
                    $0.errorDescription = "Timed out waiting for the main-queue blocker to start"
                }
                return
            }

            do {
                let response = try self.sendV2Request(
                    method: "workspace.set_status",
                    params: [
                        "workspace_id": workspaceID,
                        "key": statusKey,
                        "value": statusValue,
                    ],
                    id: 1,
                    to: clientFD,
                    timeout: 1.0
                )
                let result = response["result"] as? [String: Any]
                let queueWasStillBlocked = !mainQueueBlockReturned.withLock { $0 }
                let publicationsBeforeRelease = statusPublicationCount.withLock { $0 }

                observation.withLock {
                    $0.responseReceived = true
                    $0.responseOK = response["ok"] as? Bool == true
                    $0.responseWorkspaceID = result?["workspace_id"] as? String
                    $0.responseKey = result?["key"] as? String
                    $0.responseValue = result?["value"] as? String
                    $0.mainQueueWasBlockedAtResponse = queueWasStillBlocked
                    $0.statusPublicationCountBeforeRelease = publicationsBeforeRelease
                }
            } catch {
                observation.withLock {
                    $0.errorDescription = String(describing: error)
                }
            }
        }

        await fulfillment(of: [clientFinished], timeout: 5.0)

        let responseObservation = observation.withLock { $0 }
        XCTAssertNil(responseObservation.errorDescription)
        XCTAssertTrue(
            responseObservation.responseReceived,
            "Telemetry must respond before a busy main queue is released"
        )
        XCTAssertTrue(responseObservation.responseOK)
        XCTAssertEqual(responseObservation.responseWorkspaceID, workspaceID)
        XCTAssertEqual(responseObservation.responseKey, statusKey)
        XCTAssertEqual(responseObservation.responseValue, statusValue)
        XCTAssertTrue(
            responseObservation.mainQueueWasBlockedAtResponse,
            "The optimistic response must not wait for main-queue model resolution"
        )
        XCTAssertEqual(
            responseObservation.statusPublicationCountBeforeRelease,
            0,
            "The workspace mutation must remain deferred while the main queue is occupied"
        )
        XCTAssertFalse(
            mainQueueBlockTimedOut.withLock { $0 },
            "The client must release the bounded main-queue blocker after receiving its response"
        )

        await drainMainQueue()
        XCTAssertEqual(
            workspace.statusEntries[statusKey]?.value,
            statusValue,
            "The acknowledged telemetry mutation must apply after the main queue is released"
        )
    }

    /// Exact UI/model queries must wait for the main queue so their response describes one
    /// coherent point in time rather than racing window-context mutation.
    func testWindowListWaitsForMainQueueBeforeReturningExactSnapshot() async throws {
        let originalAppDelegate = AppDelegate.shared
        let isolatedAppDelegate = AppDelegate()
        defer {
            if AppDelegate.shared === isolatedAppDelegate {
                AppDelegate.shared = originalAppDelegate
            }
        }

        let socketPath = makeSocketPath("window-snapshot")
        TerminalController.shared.start(
            tabManager: TabManager(),
            socketPath: socketPath,
            accessMode: .allowAll
        )
        defer { TerminalController.shared.stop() }
        try waitForSocket(at: socketPath)

        let clientFD = try connectPersistentClient(to: socketPath)
        defer {
            _ = Darwin.shutdown(clientFD, SHUT_RDWR)
            Darwin.close(clientFD)
        }
        guard isSuccessfulV2Ping(try sendV2Ping(to: clientFD, id: 1)) else {
            XCTFail("Expected the persistent Unix client handler to be ready before blocking main")
            return
        }
        guard !TerminalController.shouldSuppressSocketCommandActivation() else {
            XCTFail("Expected no socket command policy scope after the preflight response was consumed")
            return
        }

        let mainQueueEntered = DispatchSemaphore(value: 0)
        let mainQueueRelease = DispatchSemaphore(value: 0)
        defer { mainQueueRelease.signal() }

        let mainQueueBlockTimedOut = OSAllocatedUnfairLock(initialState: false)
        let observation = OSAllocatedUnfairLock(initialState: MainQueueBlockedQueryObservation())
        let clientFinished = expectation(description: "exact window snapshot received after main queue release")

        DispatchQueue.main.async {
            mainQueueEntered.signal()
            let waitResult = mainQueueRelease.wait(timeout: .now() + 3.0)
            mainQueueBlockTimedOut.withLock { $0 = waitResult == .timedOut }
        }

        DispatchQueue.global(qos: .userInitiated).async {
            defer {
                mainQueueRelease.signal()
                clientFinished.fulfill()
            }

            guard mainQueueEntered.wait(timeout: .now() + 1.0) == .success else {
                observation.withLock {
                    $0.errorDescription = "Timed out waiting for the main-queue blocker to start"
                }
                return
            }

            do {
                try self.writeLine(
                    #"{"jsonrpc":"2.0","id":2,"method":"window.list","params":{}}"#,
                    to: clientFD
                )
            } catch {
                observation.withLock { $0.errorDescription = String(describing: error) }
                return
            }

            // This class serializes access to the shared TerminalController. With the preflight
            // response fully consumed above, a positive policy depth identifies request 2's
            // parsed dispatch scope without making that internal signal part of the assertion.
            var dispatchEntryObserved = false
            let dispatchEntryDeadline = DispatchTime.now() + 1.0
            while !dispatchEntryObserved {
                if TerminalController.shouldSuppressSocketCommandActivation() {
                    dispatchEntryObserved = true
                    break
                }

                let now = DispatchTime.now().uptimeNanoseconds
                guard now < dispatchEntryDeadline.uptimeNanoseconds else {
                    observation.withLock {
                        $0.errorDescription = "Timed out waiting for window.list to enter parsed dispatch"
                    }
                    break
                }

                let remainingNanoseconds = dispatchEntryDeadline.uptimeNanoseconds - now
                let remainingMilliseconds = max(1, (remainingNanoseconds + 999_999) / 1_000_000)
                var descriptor = pollfd(fd: clientFD, events: Int16(POLLIN), revents: 0)
                let pollResult = Darwin.poll(
                    &descriptor,
                    1,
                    Int32(min(UInt64(5), remainingMilliseconds))
                )
                if pollResult > 0 {
                    observation.withLock { $0.responseArrivedWhileBlocked = true }
                    break
                }
                if pollResult < 0, errno != EINTR {
                    observation.withLock {
                        $0.errorDescription = String(describing: self.posixError("poll while waiting for parsed dispatch"))
                    }
                    break
                }
            }

            if dispatchEntryObserved {
                do {
                    try self.waitForReadable(
                        from: clientFD,
                        until: .now() + 0.2,
                        operation: "checking for an off-main window.list response"
                    )
                    observation.withLock { $0.responseArrivedWhileBlocked = true }
                } catch let error as NSError
                    where error.domain == NSPOSIXErrorDomain && error.code == Int(ETIMEDOUT) {
                    observation.withLock { $0.confirmedNoResponseWhileBlocked = true }
                } catch {
                    observation.withLock { $0.errorDescription = String(describing: error) }
                }
            }

            mainQueueRelease.signal()

            do {
                let responseLine = try self.readLine(from: clientFD, timeout: 1.0)
                let responseData = Data(responseLine.utf8)
                guard let response = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                      let result = response["result"] as? [String: Any],
                      let windows = result["windows"] as? [[String: Any]] else {
                    observation.withLock {
                        $0.errorDescription = "Expected a window.list JSON-RPC result"
                    }
                    return
                }
                observation.withLock {
                    $0.responseOK = response["ok"] as? Bool == true
                    $0.windowCount = windows.count
                }
            } catch {
                observation.withLock { $0.errorDescription = String(describing: error) }
            }
        }

        await fulfillment(of: [clientFinished], timeout: 5.0)

        let queryObservation = observation.withLock { $0 }
        XCTAssertNil(queryObservation.errorDescription)
        XCTAssertTrue(
            queryObservation.confirmedNoResponseWhileBlocked,
            "An exact window snapshot must not return while the main queue is occupied"
        )
        XCTAssertFalse(
            queryObservation.responseArrivedWhileBlocked,
            "window.list must not read AppDelegate window state off-main"
        )
        XCTAssertTrue(queryObservation.responseOK)
        XCTAssertEqual(
            queryObservation.windowCount,
            0,
            "The isolated delegate's exact snapshot must contain no windows"
        )
        XCTAssertFalse(
            mainQueueBlockTimedOut.withLock { $0 },
            "The bounded main-queue blocker must be released by the client observation"
        )
    }

    /// A successful subscribe response defines the stream boundary: clients must be able to
    /// parse that acknowledgment before any asynchronous event frame. Events published after
    /// the acknowledgment must then flow on the same connection without another request.
    func testSubscribeAcknowledgmentPrecedesPushedEvents() throws {
        var sockets: [Int32] = [-1, -1]
        let socketPairResult = sockets.withUnsafeMutableBufferPointer { buffer in
            Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, buffer.baseAddress)
        }
        guard socketPairResult == 0 else {
            throw posixError("socketpair(AF_UNIX)")
        }

        let connection = SocketConnection(socket: sockets[0])
        defer {
            connection.teardown()
            _ = Darwin.shutdown(sockets[0], SHUT_RDWR)
            _ = Darwin.shutdown(sockets[1], SHUT_RDWR)
            Darwin.close(sockets[0])
            Darwin.close(sockets[1])
        }

        let subscribeResult = TerminalController.shared.v2Subscribe(
            params: ["classes": ["workspace_lifecycle"]],
            connection: connection
        )
        guard case .ok(let resultPayload) = subscribeResult else {
            XCTFail("Expected workspace_lifecycle subscription to be accepted")
            return
        }

        let acknowledgmentObject: [String: Any] = [
            "id": 1,
            "ok": true,
            "result": resultPayload,
        ]
        let acknowledgmentData = try JSONSerialization.data(withJSONObject: acknowledgmentObject)
        let acknowledgmentLine = try XCTUnwrap(String(data: acknowledgmentData, encoding: .utf8))

        let beforeAcknowledgmentWorkspaceID = UUID()
        SocketEventBroadcaster.shared.publishWorkspaceLifecycle(
            kind: "before_ack",
            workspaceId: beforeAcknowledgmentWorkspaceID,
            title: nil
        )

        var frameBeforeAcknowledgment: [String: Any]?
        do {
            try waitForReadable(
                from: sockets[1],
                until: .now() + 1.0,
                operation: "checking for an event before the subscribe acknowledgment"
            )
            let line = try readLine(from: sockets[1], timeout: 1.0)
            frameBeforeAcknowledgment = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            )
        } catch let error as NSError
            where error.domain == NSPOSIXErrorDomain && error.code == Int(ETIMEDOUT) {
            frameBeforeAcknowledgment = nil
        }

        XCTAssertTrue(
            connection.writeLine(acknowledgmentLine),
            "The real subscription acknowledgment must be writable to the live connection"
        )

        let afterAcknowledgmentWorkspaceID = UUID()
        SocketEventBroadcaster.shared.publishWorkspaceLifecycle(
            kind: "after_ack",
            workspaceId: afterAcknowledgmentWorkspaceID,
            title: nil
        )

        let firstLineAfterAcknowledgmentWrite = try readLine(from: sockets[1], timeout: 1.0)
        let firstFrameAfterAcknowledgmentWrite = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(firstLineAfterAcknowledgmentWrite.utf8)) as? [String: Any]
        )

        XCTAssertNil(
            frameBeforeAcknowledgment,
            "No pushed event may overtake a successful subscribe acknowledgment"
        )
        XCTAssertEqual(firstFrameAfterAcknowledgmentWrite["id"] as? Int, 1)
        XCTAssertEqual(firstFrameAfterAcknowledgmentWrite["ok"] as? Bool, true)
        XCTAssertNil(
            firstFrameAfterAcknowledgmentWrite["event"],
            "The first stream frame must be the subscribe acknowledgment, not an event"
        )

        let nextLine = try readLine(from: sockets[1], timeout: 1.0)
        var postAcknowledgmentFrame = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(nextLine.utf8)) as? [String: Any]
        )
        if postAcknowledgmentFrame["workspace_id"] as? String != afterAcknowledgmentWorkspaceID.uuidString {
            let followingLine = try readLine(from: sockets[1], timeout: 1.0)
            postAcknowledgmentFrame = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(followingLine.utf8)) as? [String: Any]
            )
        }

        XCTAssertEqual(postAcknowledgmentFrame["event"] as? String, "workspace_lifecycle")
        XCTAssertEqual(postAcknowledgmentFrame["kind"] as? String, "after_ack")
        XCTAssertEqual(
            postAcknowledgmentFrame["workspace_id"] as? String,
            afterAcknowledgmentWorkspaceID.uuidString,
            "An event published after acknowledgment must flow on the activated subscription"
        )
    }

    /// Regression for #82: `surface.report_tty`/`surface.ports_kick` used to block the socket
    /// thread with `DispatchQueue.main.sync` so the response could echo the surface resolved on
    /// main (e.g. falling back to the focused surface when `surface_id` is omitted). They now
    /// follow the same off-main-parse + main.async-mutate telemetry shape as
    /// `workspace.set_status`/`workspace.report_meta_block`: the JSON-RPC response acknowledges
    /// immediately (echoing the request, not a value resolved on main) and the surface-resolving
    /// model mutation is fire-and-forget.
    func testSurfaceRelayRPCsAcknowledgeImmediatelyAndResolveFocusedSurfaceAsync() async throws {
        let socketPath = makeSocketPath("relay-fallback")
        let manager = TabManager()
        let workspace = manager.addWorkspace(select: true)

        defer {
            if manager.tabs.contains(where: { $0.id == workspace.id }) {
                manager.closeWorkspace(workspace)
            }
        }

        guard let focusedPanelId = workspace.focusedPanelId else {
            XCTFail("Expected selected workspace with a focused panel")
            return
        }

        TerminalController.shared.start(
            tabManager: manager,
            socketPath: socketPath,
            accessMode: .allowAll
        )
        try waitForSocket(at: socketPath)

        let reportTTYResponse = try await sendV2RequestAsync(
            method: "surface.report_tty",
            params: [
                "workspace_id": workspace.id.uuidString,
                "tty_name": "ttys999"
            ],
            to: socketPath
        )

        XCTAssertEqual(reportTTYResponse["ok"] as? Bool, true, "Unexpected JSON-RPC response: \(reportTTYResponse)")
        let reportTTYResult = try XCTUnwrap(reportTTYResponse["result"] as? [String: Any], "Unexpected JSON-RPC response: \(reportTTYResponse)")
        // surface_id was omitted from the request, so the immediate ack echoes null — the actual
        // surface is resolved asynchronously on main.
        XCTAssertNil(reportTTYResult["surface_id"] as? String)
        XCTAssertTrue(waitUntil { workspace.surfaceTTYNames[focusedPanelId] == "ttys999" },
                      "Expected fire-and-forget mutation to eventually register the TTY on the focused surface")

        let portsKickResponse = try await sendV2RequestAsync(
            method: "surface.ports_kick",
            params: ["workspace_id": workspace.id.uuidString],
            to: socketPath
        )

        XCTAssertEqual(portsKickResponse["ok"] as? Bool, true, "Unexpected JSON-RPC response: \(portsKickResponse)")
        _ = try XCTUnwrap(portsKickResponse["result"] as? [String: Any], "Unexpected JSON-RPC response: \(portsKickResponse)")
    }

    func testSurfaceRelayRPCsAcknowledgeImmediatelyAndNoOpForUnknownSurfaceID() async throws {
        let socketPath = makeSocketPath("relay-invalid")
        let manager = TabManager()
        let workspace = manager.addWorkspace(select: true)

        defer {
            if manager.tabs.contains(where: { $0.id == workspace.id }) {
                manager.closeWorkspace(workspace)
            }
        }

        let unknownSurfaceId = UUID()

        TerminalController.shared.start(
            tabManager: manager,
            socketPath: socketPath,
            accessMode: .allowAll
        )
        try waitForSocket(at: socketPath)

        let reportTTYResponse = try await sendV2RequestAsync(
            method: "surface.report_tty",
            params: [
                "workspace_id": workspace.id.uuidString,
                "surface_id": unknownSurfaceId.uuidString,
                "tty_name": "ttys999"
            ],
            to: socketPath
        )

        // The unknown surface_id can no longer be validated synchronously (that check now
        // happens inside the fire-and-forget main.async mutation), so the request is acked
        // immediately and the mutation silently no-ops once it resolves.
        XCTAssertEqual(reportTTYResponse["ok"] as? Bool, true, "Unexpected JSON-RPC response: \(reportTTYResponse)")
        let reportTTYResult = try XCTUnwrap(reportTTYResponse["result"] as? [String: Any], "Unexpected JSON-RPC response: \(reportTTYResponse)")
        XCTAssertEqual(reportTTYResult["surface_id"] as? String, unknownSurfaceId.uuidString)

        let portsKickResponse = try await sendV2RequestAsync(
            method: "surface.ports_kick",
            params: [
                "workspace_id": workspace.id.uuidString,
                "surface_id": unknownSurfaceId.uuidString
            ],
            to: socketPath
        )

        XCTAssertEqual(portsKickResponse["ok"] as? Bool, true, "Unexpected JSON-RPC response: \(portsKickResponse)")
        let portsKickResult = try XCTUnwrap(portsKickResponse["result"] as? [String: Any], "Unexpected JSON-RPC response: \(portsKickResponse)")
        XCTAssertEqual(portsKickResult["surface_id"] as? String, unknownSurfaceId.uuidString)

        // Give the async mutation a beat to run, then confirm it never registered a TTY for the
        // nonexistent surface.
        waitUntil(timeout: 0.5) { false }
        XCTAssertTrue(workspace.surfaceTTYNames.isEmpty)
    }

    /// Unknown handles are rejected from the telemetry lane's existing handle cache. Validation
    /// must not fall back to a generic main-actor handle refresh, or malformed telemetry can
    /// stall behind unrelated UI work instead of failing promptly with an actionable field name.
    func testCacheOnlyTelemetryRejectsUnknownHandlesWhileMainQueueIsOccupied() async throws {
        let socketPath = makeSocketPath("relay-handles")
        let manager = TabManager()
        let workspace = manager.addWorkspace(select: true, eagerLoadTerminal: false)
        let workspaceID = workspace.id.uuidString

        defer {
            if manager.tabs.contains(where: { $0.id == workspace.id }) {
                manager.closeWorkspace(workspace)
            }
        }

        TerminalController.shared.start(
            tabManager: manager,
            socketPath: socketPath,
            accessMode: .allowAll
        )
        defer { TerminalController.shared.stop() }
        try waitForSocket(at: socketPath)

        let clientFD = try connectPersistentClient(to: socketPath)
        defer {
            _ = Darwin.shutdown(clientFD, SHUT_RDWR)
            Darwin.close(clientFD)
        }
        guard isSuccessfulV2Ping(try sendV2Ping(to: clientFD, id: 1)) else {
            XCTFail("Expected the persistent Unix client handler to be ready before blocking main")
            return
        }

        let mainQueueEntered = DispatchSemaphore(value: 0)
        let mainQueueRelease = DispatchSemaphore(value: 0)
        defer { mainQueueRelease.signal() }

        let mainQueueBlockReturned = OSAllocatedUnfairLock(initialState: false)
        let mainQueueBlockTimedOut = OSAllocatedUnfairLock(initialState: false)
        let observation = OSAllocatedUnfairLock(initialState: MainQueueBlockedInvalidTelemetryObservation())
        let clientFinished = expectation(description: "unknown telemetry handles rejected while main queue is occupied")

        DispatchQueue.main.async {
            mainQueueEntered.signal()
            let waitResult = mainQueueRelease.wait(timeout: .now() + 3.0)
            mainQueueBlockTimedOut.withLock { $0 = waitResult == .timedOut }
            mainQueueBlockReturned.withLock { $0 = true }
        }

        DispatchQueue.global(qos: .userInitiated).async {
            defer {
                mainQueueRelease.signal()
                clientFinished.fulfill()
            }

            guard mainQueueEntered.wait(timeout: .now() + 1.0) == .success else {
                observation.withLock {
                    $0.errorDescription = "Timed out waiting for the main-queue blocker to start"
                }
                return
            }

            do {
                let reportTTYResponse = try self.sendV2Request(
                    method: "surface.report_tty",
                    params: [
                        "workspace_id": workspaceID,
                        "surface_id": "surface:0",
                        "tty_name": "ttys999",
                    ],
                    id: 2,
                    to: clientFD,
                    timeout: 1.0
                )
                let reportTTYError = reportTTYResponse["error"] as? [String: Any]
                observation.withLock {
                    $0.reportTTYResponseOK = reportTTYResponse["ok"] as? Bool
                    $0.reportTTYErrorCode = reportTTYError?["code"] as? String
                    $0.reportTTYErrorMessage = reportTTYError?["message"] as? String
                    $0.reportTTYResponseWhileBlocked = !mainQueueBlockReturned.withLock { $0 }
                }

                let portsKickResponse = try self.sendV2Request(
                    method: "surface.ports_kick",
                    params: ["workspace_id": "workspace:0"],
                    id: 3,
                    to: clientFD,
                    timeout: 1.0
                )
                let portsKickError = portsKickResponse["error"] as? [String: Any]
                observation.withLock {
                    $0.portsKickResponseOK = portsKickResponse["ok"] as? Bool
                    $0.portsKickErrorCode = portsKickError?["code"] as? String
                    $0.portsKickErrorMessage = portsKickError?["message"] as? String
                    $0.portsKickResponseWhileBlocked = !mainQueueBlockReturned.withLock { $0 }
                }

                let reportPWDResponse = try self.sendV2Request(
                    method: "surface.report_pwd",
                    params: [
                        "workspace_id": workspaceID,
                        "surface_id": "surface:0",
                        "path": "/tmp/programa-cache-only-telemetry",
                    ],
                    id: 4,
                    to: clientFD,
                    timeout: 1.0
                )
                let reportPWDError = reportPWDResponse["error"] as? [String: Any]
                observation.withLock {
                    $0.reportPWDResponseOK = reportPWDResponse["ok"] as? Bool
                    $0.reportPWDErrorCode = reportPWDError?["code"] as? String
                    $0.reportPWDErrorMessage = reportPWDError?["message"] as? String
                    $0.reportPWDResponseWhileBlocked = !mainQueueBlockReturned.withLock { $0 }
                }

                let reportShellStateResponse = try self.sendV2Request(
                    method: "surface.report_shell_state",
                    params: [
                        "workspace_id": "workspace:0",
                        "surface_id": UUID().uuidString,
                        "state": "busy",
                    ],
                    id: 5,
                    to: clientFD,
                    timeout: 1.0
                )
                let reportShellStateError = reportShellStateResponse["error"] as? [String: Any]
                observation.withLock {
                    $0.reportShellStateResponseOK = reportShellStateResponse["ok"] as? Bool
                    $0.reportShellStateErrorCode = reportShellStateError?["code"] as? String
                    $0.reportShellStateErrorMessage = reportShellStateError?["message"] as? String
                    $0.reportShellStateResponseWhileBlocked = !mainQueueBlockReturned.withLock { $0 }
                }

                let reportAgentStateResponse = try self.sendV2Request(
                    method: "surface.report_agent_state",
                    params: [
                        "workspace_id": workspaceID,
                        "surface_id": "surface:0",
                        "state": "blocked",
                        "source": "hooks",
                    ],
                    id: 6,
                    to: clientFD,
                    timeout: 1.0
                )
                let reportAgentStateError = reportAgentStateResponse["error"] as? [String: Any]
                observation.withLock {
                    $0.reportAgentStateResponseOK = reportAgentStateResponse["ok"] as? Bool
                    $0.reportAgentStateErrorCode = reportAgentStateError?["code"] as? String
                    $0.reportAgentStateErrorMessage = reportAgentStateError?["message"] as? String
                    $0.reportAgentStateResponseWhileBlocked = !mainQueueBlockReturned.withLock { $0 }
                }

                let clearAgentStateResponse = try self.sendV2Request(
                    method: "surface.clear_agent_state",
                    params: [
                        "workspace_id": "workspace:0",
                        "surface_id": UUID().uuidString,
                    ],
                    id: 7,
                    to: clientFD,
                    timeout: 1.0
                )
                let clearAgentStateError = clearAgentStateResponse["error"] as? [String: Any]
                observation.withLock {
                    $0.clearAgentStateResponseOK = clearAgentStateResponse["ok"] as? Bool
                    $0.clearAgentStateErrorCode = clearAgentStateError?["code"] as? String
                    $0.clearAgentStateErrorMessage = clearAgentStateError?["message"] as? String
                    $0.clearAgentStateResponseWhileBlocked = !mainQueueBlockReturned.withLock { $0 }
                }

                let setAgentPIDResponse = try self.sendV2Request(
                    method: "workspace.set_agent_pid",
                    params: [
                        "workspace_id": "workspace:0",
                        "key": "cache-only-agent",
                        "pid": 42,
                    ],
                    id: 8,
                    to: clientFD,
                    timeout: 1.0
                )
                let setAgentPIDError = setAgentPIDResponse["error"] as? [String: Any]
                observation.withLock {
                    $0.setAgentPIDResponseOK = setAgentPIDResponse["ok"] as? Bool
                    $0.setAgentPIDErrorCode = setAgentPIDError?["code"] as? String
                    $0.setAgentPIDErrorMessage = setAgentPIDError?["message"] as? String
                    $0.setAgentPIDResponseWhileBlocked = !mainQueueBlockReturned.withLock { $0 }
                }

                let clearAgentPIDResponse = try self.sendV2Request(
                    method: "workspace.clear_agent_pid",
                    params: [
                        "workspace_id": "workspace:0",
                        "key": "cache-only-agent",
                    ],
                    id: 9,
                    to: clientFD,
                    timeout: 1.0
                )
                let clearAgentPIDError = clearAgentPIDResponse["error"] as? [String: Any]
                observation.withLock {
                    $0.clearAgentPIDResponseOK = clearAgentPIDResponse["ok"] as? Bool
                    $0.clearAgentPIDErrorCode = clearAgentPIDError?["code"] as? String
                    $0.clearAgentPIDErrorMessage = clearAgentPIDError?["message"] as? String
                    $0.clearAgentPIDResponseWhileBlocked = !mainQueueBlockReturned.withLock { $0 }
                }

                let setStatusResponse = try self.sendV2Request(
                    method: "workspace.set_status",
                    params: [
                        "workspace_id": "workspace:0",
                        "key": "cache-only-status",
                        "value": "running",
                    ],
                    id: 10,
                    to: clientFD,
                    timeout: 1.0
                )
                let setStatusError = setStatusResponse["error"] as? [String: Any]
                observation.withLock {
                    $0.setStatusResponseOK = setStatusResponse["ok"] as? Bool
                    $0.setStatusErrorCode = setStatusError?["code"] as? String
                    $0.setStatusErrorMessage = setStatusError?["message"] as? String
                    $0.setStatusResponseWhileBlocked = !mainQueueBlockReturned.withLock { $0 }
                }

                let clearStatusResponse = try self.sendV2Request(
                    method: "workspace.clear_status",
                    params: [
                        "workspace_id": "workspace:0",
                        "key": "cache-only-status",
                    ],
                    id: 11,
                    to: clientFD,
                    timeout: 1.0
                )
                let clearStatusError = clearStatusResponse["error"] as? [String: Any]
                observation.withLock {
                    $0.clearStatusResponseOK = clearStatusResponse["ok"] as? Bool
                    $0.clearStatusErrorCode = clearStatusError?["code"] as? String
                    $0.clearStatusErrorMessage = clearStatusError?["message"] as? String
                    $0.clearStatusResponseWhileBlocked = !mainQueueBlockReturned.withLock { $0 }
                }
            } catch {
                observation.withLock {
                    $0.errorDescription = String(describing: error)
                }
            }
        }

        await fulfillment(of: [clientFinished], timeout: 5.0)

        let responseObservation = observation.withLock { $0 }
        XCTAssertNil(responseObservation.errorDescription)
        XCTAssertEqual(responseObservation.reportTTYResponseOK, false)
        XCTAssertEqual(responseObservation.reportTTYErrorCode, "invalid_params")
        XCTAssertTrue(
            responseObservation.reportTTYErrorMessage?.contains("surface_id") == true,
            "The validation error must identify the unknown surface_id"
        )
        XCTAssertTrue(
            responseObservation.reportTTYResponseWhileBlocked,
            "surface.report_tty must reject an unknown cached handle without waiting for main"
        )
        XCTAssertEqual(responseObservation.portsKickResponseOK, false)
        XCTAssertEqual(responseObservation.portsKickErrorCode, "invalid_params")
        XCTAssertTrue(
            responseObservation.portsKickErrorMessage?.contains("workspace_id") == true,
            "The validation error must identify the unknown workspace_id"
        )
        XCTAssertTrue(
            responseObservation.portsKickResponseWhileBlocked,
            "surface.ports_kick must reject an unknown cached handle without waiting for main"
        )
        XCTAssertEqual(responseObservation.reportPWDResponseOK, false)
        XCTAssertEqual(responseObservation.reportPWDErrorCode, "invalid_params")
        XCTAssertTrue(
            responseObservation.reportPWDErrorMessage?.contains("surface_id") == true,
            "The validation error must identify the unknown surface_id"
        )
        XCTAssertTrue(
            responseObservation.reportPWDResponseWhileBlocked,
            "surface.report_pwd must reject an unknown cached handle without waiting for main"
        )
        XCTAssertEqual(responseObservation.reportShellStateResponseOK, false)
        XCTAssertEqual(responseObservation.reportShellStateErrorCode, "invalid_params")
        XCTAssertTrue(
            responseObservation.reportShellStateErrorMessage?.contains("workspace_id") == true,
            "The validation error must identify the unknown workspace_id"
        )
        XCTAssertTrue(
            responseObservation.reportShellStateResponseWhileBlocked,
            "surface.report_shell_state must reject an unknown cached handle without waiting for main"
        )
        XCTAssertEqual(responseObservation.reportAgentStateResponseOK, false)
        XCTAssertEqual(responseObservation.reportAgentStateErrorCode, "invalid_params")
        XCTAssertTrue(
            responseObservation.reportAgentStateErrorMessage?.contains("surface_id") == true,
            "The validation error must identify the unknown surface_id"
        )
        XCTAssertTrue(
            responseObservation.reportAgentStateResponseWhileBlocked,
            "surface.report_agent_state must reject an unknown cached handle without waiting for main"
        )
        XCTAssertEqual(responseObservation.clearAgentStateResponseOK, false)
        XCTAssertEqual(responseObservation.clearAgentStateErrorCode, "invalid_params")
        XCTAssertTrue(
            responseObservation.clearAgentStateErrorMessage?.contains("workspace_id") == true,
            "The validation error must identify the unknown workspace_id"
        )
        XCTAssertTrue(
            responseObservation.clearAgentStateResponseWhileBlocked,
            "surface.clear_agent_state must reject an unknown cached handle without waiting for main"
        )
        XCTAssertEqual(responseObservation.setAgentPIDResponseOK, false)
        XCTAssertEqual(responseObservation.setAgentPIDErrorCode, "invalid_params")
        XCTAssertTrue(
            responseObservation.setAgentPIDErrorMessage?.contains("workspace_id") == true,
            "The validation error must identify the unknown workspace_id"
        )
        XCTAssertTrue(
            responseObservation.setAgentPIDResponseWhileBlocked,
            "workspace.set_agent_pid must reject an unknown cached handle without waiting for main"
        )
        XCTAssertEqual(responseObservation.clearAgentPIDResponseOK, false)
        XCTAssertEqual(responseObservation.clearAgentPIDErrorCode, "invalid_params")
        XCTAssertTrue(
            responseObservation.clearAgentPIDErrorMessage?.contains("workspace_id") == true,
            "The validation error must identify the unknown workspace_id"
        )
        XCTAssertTrue(
            responseObservation.clearAgentPIDResponseWhileBlocked,
            "workspace.clear_agent_pid must reject an unknown cached handle without waiting for main"
        )
        XCTAssertEqual(responseObservation.setStatusResponseOK, false)
        XCTAssertEqual(responseObservation.setStatusErrorCode, "invalid_params")
        XCTAssertTrue(
            responseObservation.setStatusErrorMessage?.contains("workspace_id") == true,
            "The validation error must identify the unknown workspace_id"
        )
        XCTAssertTrue(
            responseObservation.setStatusResponseWhileBlocked,
            "workspace.set_status must reject an unknown cached handle without waiting for main"
        )
        XCTAssertEqual(responseObservation.clearStatusResponseOK, false)
        XCTAssertEqual(responseObservation.clearStatusErrorCode, "invalid_params")
        XCTAssertTrue(
            responseObservation.clearStatusErrorMessage?.contains("workspace_id") == true,
            "The validation error must identify the unknown workspace_id"
        )
        XCTAssertTrue(
            responseObservation.clearStatusResponseWhileBlocked,
            "workspace.clear_status must reject an unknown cached handle without waiting for main"
        )
        XCTAssertFalse(
            mainQueueBlockTimedOut.withLock { $0 },
            "All ten responses must arrive before the bounded main-queue blocker times out"
        )
    }

    func testWorkspaceCloseRejectsPinnedWorkspace() async throws {
        let socketPath = makeSocketPath("close-pinned")
        let manager = TabManager()
        let pinnedWorkspace = manager.addWorkspace(select: false)
        manager.setPinned(pinnedWorkspace, pinned: true)

        TerminalController.shared.start(
            tabManager: manager,
            socketPath: socketPath,
            accessMode: .allowAll
        )
        try waitForSocket(at: socketPath)

        let response = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let response = try self.sendV2Request(
                        method: "workspace.close",
                        params: ["workspace_id": pinnedWorkspace.id.uuidString],
                        to: socketPath
                    )
                    continuation.resume(returning: response)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }

        XCTAssertEqual(response["ok"] as? Bool, false, "Unexpected JSON-RPC response: \(response)")
        let error = try XCTUnwrap(response["error"] as? [String: Any], "Unexpected JSON-RPC response: \(response)")
        XCTAssertEqual(error["code"] as? String, "protected")

        let data = try XCTUnwrap(error["data"] as? [String: Any], "Expected error data payload")
        XCTAssertEqual(data["workspace_id"] as? String, pinnedWorkspace.id.uuidString)
        XCTAssertEqual(data["pinned"] as? Bool, true)
        XCTAssertTrue(manager.tabs.contains(where: { $0.id == pinnedWorkspace.id }))
    }

    func testSocketPreservesRequestIDWhenUTF8ScalarSpansReads() throws {
        let socketPath = makeSocketPath("split-utf8")
        TerminalController.shared.start(
            tabManager: TabManager(),
            socketPath: socketPath,
            accessMode: .allowAll
        )
        try waitForSocket(at: socketPath)

        let fd = try connect(to: socketPath)
        defer { Darwin.close(fd) }

        let requestID = "request-🐈"
        let request = #"{"jsonrpc":"2.0","id":"request-🐈","method":"system.ping","params":{}}"#
        let bytes = Array((request + "\n").utf8)
        let emojiBytes = Array("🐈".utf8)
        let emojiStart = try XCTUnwrap(
            bytes.indices.first { index in
                index + emojiBytes.count <= bytes.count &&
                    Array(bytes[index..<(index + emojiBytes.count)]) == emojiBytes
            }
        )
        let splitIndex = emojiStart + 2

        let firstWrite = bytes.withUnsafeBytes { raw in
            Darwin.write(fd, raw.baseAddress, splitIndex)
        }
        XCTAssertEqual(firstWrite, splitIndex)
        // Give the listener time to consume the first syscall before completing the scalar.
        // Without this gap, the kernel may coalesce both writes into one read and stop the test
        // from exercising the framing boundary that caused the regression.
        usleep(50_000)
        let secondWrite = bytes.withUnsafeBytes { raw in
            Darwin.write(fd, raw.baseAddress!.advanced(by: splitIndex), bytes.count - splitIndex)
        }
        XCTAssertEqual(secondWrite, bytes.count - splitIndex)

        let responseData = Data(try readLine(from: fd).utf8)
        let response = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        )
        XCTAssertEqual(response["ok"] as? Bool, true, "Unexpected JSON-RPC response: \(response)")
        XCTAssertEqual(
            response["id"] as? String,
            requestID,
            "A valid request identifier must survive when the kernel splits a UTF-8 scalar across reads"
        )
    }

    func testSocketRejectsInvalidUTF8AndClosesConnection() throws {
        let socketPath = makeSocketPath("invalid-utf8")
        TerminalController.shared.start(
            tabManager: TabManager(),
            socketPath: socketPath,
            accessMode: .allowAll
        )
        try waitForSocket(at: socketPath)

        let fd = try connect(to: socketPath)
        defer { Darwin.close(fd) }

        let invalidFrame = Array(#"{"jsonrpc":"2.0","id":""#.utf8) +
            [0xF0, 0x28, 0x8C, 0x28] +
            Array(#"","method":"system.ping","params":{}}"#.utf8) + [0x0A]
        let wrote = invalidFrame.withUnsafeBytes { raw in
            Darwin.write(fd, raw.baseAddress, invalidFrame.count)
        }
        XCTAssertEqual(wrote, invalidFrame.count)

        let responseData = Data(try readLine(from: fd).utf8)
        let response = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        )
        XCTAssertEqual(response["ok"] as? Bool, false, "Unexpected JSON-RPC response: \(response)")
        let error = try XCTUnwrap(response["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "invalid_utf8")

        var byte: UInt8 = 0
        try waitForReadable(
            from: fd,
            until: .now() + 5.0,
            operation: "waiting for the invalid-UTF-8 connection to close"
        )
        let closeRead = Darwin.read(fd, &byte, 1)
        guard closeRead >= 0 else { throw posixError("read after invalid UTF-8") }
        XCTAssertEqual(
            closeRead,
            0,
            "Invalid UTF-8 is a framing error, so the server must close instead of parsing later bytes on the connection"
        )
    }

    func testWorkspaceTelemetryEnforcesPayloadAndCollectionBoundsThroughSocket() async throws {
        let socketPath = makeSocketPath("telemetry-limits")
        let manager = TabManager()
        let workspace = manager.addWorkspace(select: true, eagerLoadTerminal: false)
        TerminalController.shared.start(
            tabManager: manager,
            socketPath: socketPath,
            accessMode: .allowAll
        )
        try waitForSocket(at: socketPath)

        let acceptedPayloads: [(method: String, field: String, limit: Int)] = [
            ("workspace.set_status", "value", SidebarTelemetryLimits.maxStatusValueBytes),
            ("workspace.log", "message", SidebarTelemetryLimits.maxLogMessageBytes),
            ("workspace.report_meta_block", "markdown", SidebarTelemetryLimits.maxMetadataMarkdownBytes),
        ]
        for target in acceptedPayloads {
            let payload = String(repeating: "x", count: target.limit)
            var params: [String: Any] = [
                "workspace_id": workspace.id.uuidString,
                target.field: payload,
            ]
            if target.method != "workspace.log" {
                params["key"] = "boundary-\(target.field)"
            }
            let response = try await sendV2RequestAsync(method: target.method, params: params, to: socketPath)
            XCTAssertEqual(
                response["ok"] as? Bool,
                true,
                "The documented maximum UTF-8 payload must remain accepted for \(target.method): \(response)"
            )

            params[target.field] = payload + "x"
            let oversized = try await sendV2RequestAsync(method: target.method, params: params, to: socketPath)
            XCTAssertEqual(oversized["ok"] as? Bool, false, "Unexpected JSON-RPC response: \(oversized)")
            let error = try XCTUnwrap(oversized["error"] as? [String: Any])
            XCTAssertEqual(error["code"] as? String, "invalid_params")
        }

        let oversizedURLPrefix = "https://example.com/"
        let oversizedAuxiliaryFields: [(method: String, field: String, value: String)] = [
            ("workspace.set_status", "key", String(repeating: "k", count: SidebarTelemetryLimits.maxKeyBytes + 1)),
            ("workspace.set_status", "icon", String(repeating: "i", count: SidebarTelemetryLimits.maxStatusIconBytes + 1)),
            ("workspace.set_status", "color", String(repeating: "c", count: SidebarTelemetryLimits.maxStatusColorBytes + 1)),
            (
                "workspace.set_status",
                "url",
                oversizedURLPrefix + String(
                    repeating: "u",
                    count: SidebarTelemetryLimits.maxStatusURLBytes - oversizedURLPrefix.utf8.count + 1
                )
            ),
            ("workspace.log", "source", String(repeating: "s", count: SidebarTelemetryLimits.maxLogSourceBytes + 1)),
            ("workspace.report_meta_block", "key", String(repeating: "k", count: SidebarTelemetryLimits.maxKeyBytes + 1)),
        ]
        for target in oversizedAuxiliaryFields {
            var params: [String: Any] = ["workspace_id": workspace.id.uuidString]
            switch target.method {
            case "workspace.set_status":
                params["key"] = "aux-status"
                params["value"] = "ok"
            case "workspace.log":
                params["message"] = "ok"
            default:
                params["key"] = "aux-metadata"
                params["markdown"] = "ok"
            }
            params[target.field] = target.value

            let response = try await sendV2RequestAsync(method: target.method, params: params, to: socketPath)
            XCTAssertEqual(response["ok"] as? Bool, false, "Unexpected JSON-RPC response: \(response)")
            let error = try XCTUnwrap(response["error"] as? [String: Any])
            XCTAssertEqual(error["code"] as? String, "invalid_params")
            XCTAssertTrue(
                (error["message"] as? String)?.contains(target.field) == true,
                "The validation error must identify the oversized \(target.field): \(response)"
            )
        }

        let surfaceId = UUID()
        let exactTTYName = String(repeating: "t", count: SidebarTelemetryLimits.maxTTYNameBytes)
        let acceptedTTY = try await sendV2RequestAsync(
            method: "surface.report_tty",
            params: [
                "workspace_id": workspace.id.uuidString,
                "surface_id": surfaceId.uuidString,
                "tty_name": exactTTYName,
            ],
            to: socketPath
        )
        XCTAssertEqual(acceptedTTY["ok"] as? Bool, true, "The maximum TTY name must remain accepted: \(acceptedTTY)")

        let pullRequestURL = "https://example.com/pull/1"
        let oversizedPullRequestURL = oversizedURLPrefix + String(
            repeating: "u",
            count: SidebarTelemetryLimits.maxPullRequestURLBytes - oversizedURLPrefix.utf8.count + 1
        )
        let oversizedRetainedFields: [(method: String, field: String, limit: Int, params: [String: Any])] = [
            (
                "surface.report_pwd",
                "path",
                SidebarTelemetryLimits.maxDirectoryBytes,
                [
                    "workspace_id": workspace.id.uuidString,
                    "surface_id": surfaceId.uuidString,
                    "path": String(repeating: "p", count: SidebarTelemetryLimits.maxDirectoryBytes + 1),
                ]
            ),
            (
                "surface.report_git_branch",
                "branch",
                SidebarTelemetryLimits.maxGitBranchBytes,
                [
                    "workspace_id": workspace.id.uuidString,
                    "surface_id": surfaceId.uuidString,
                    "branch": String(repeating: "b", count: SidebarTelemetryLimits.maxGitBranchBytes + 1),
                ]
            ),
            (
                "surface.report_pr",
                "url",
                SidebarTelemetryLimits.maxPullRequestURLBytes,
                [
                    "workspace_id": workspace.id.uuidString,
                    "surface_id": surfaceId.uuidString,
                    "number": 1,
                    "url": oversizedPullRequestURL,
                ]
            ),
            (
                "surface.report_pr",
                "branch",
                SidebarTelemetryLimits.maxGitBranchBytes,
                [
                    "workspace_id": workspace.id.uuidString,
                    "surface_id": surfaceId.uuidString,
                    "number": 1,
                    "url": pullRequestURL,
                    "branch": String(repeating: "b", count: SidebarTelemetryLimits.maxGitBranchBytes + 1),
                ]
            ),
            (
                "surface.report_pr",
                "label",
                SidebarTelemetryLimits.maxPullRequestLabelBytes,
                [
                    "workspace_id": workspace.id.uuidString,
                    "surface_id": surfaceId.uuidString,
                    "number": 1,
                    "url": pullRequestURL,
                    // Sixteen grapheme clusters pass the UI character truncation but exceed 64 UTF-8 bytes.
                    "label": String(repeating: "👨‍👩‍👧‍👦", count: 16),
                ]
            ),
            (
                "workspace.set_progress",
                "label",
                SidebarTelemetryLimits.maxProgressLabelBytes,
                [
                    "workspace_id": workspace.id.uuidString,
                    "value": 0.5,
                    "label": String(repeating: "l", count: SidebarTelemetryLimits.maxProgressLabelBytes + 1),
                ]
            ),
            (
                "surface.report_tty",
                "tty_name",
                SidebarTelemetryLimits.maxTTYNameBytes,
                [
                    "workspace_id": workspace.id.uuidString,
                    "surface_id": surfaceId.uuidString,
                    "tty_name": exactTTYName + "t",
                ]
            ),
        ]
        for target in oversizedRetainedFields {
            let response = try await sendV2RequestAsync(method: target.method, params: target.params, to: socketPath)
            XCTAssertEqual(response["ok"] as? Bool, false, "Unexpected JSON-RPC response: \(response)")
            let error = try XCTUnwrap(response["error"] as? [String: Any])
            XCTAssertEqual(error["code"] as? String, "invalid_params")
            let message = try XCTUnwrap(error["message"] as? String)
            XCTAssertTrue(message.contains(target.field), "The validation error must identify \(target.field): \(response)")
            XCTAssertTrue(message.contains(String(target.limit)), "The validation error must identify the byte limit: \(response)")
        }

        let hostlessPullRequest = try await sendV2RequestAsync(
            method: "surface.report_pr",
            params: [
                "workspace_id": workspace.id.uuidString,
                "surface_id": surfaceId.uuidString,
                "number": 1,
                "url": "https:///missing-host",
            ],
            to: socketPath
        )
        XCTAssertEqual(hostlessPullRequest["ok"] as? Bool, false, "Unexpected JSON-RPC response: \(hostlessPullRequest)")
        let hostlessError = try XCTUnwrap(hostlessPullRequest["error"] as? [String: Any])
        XCTAssertEqual(hostlessError["code"] as? String, "invalid_params")

        workspace.statusEntries.removeAll()
        workspace.metadataBlocks.removeAll()
        workspace.agentPIDs.removeAll()
        let oldTimestamp = Date(timeIntervalSince1970: 1)
        for index in 0..<SidebarTelemetryLimits.maxStatusEntries {
            workspace.statusEntries["old-status-\(index)"] = SidebarStatusEntry(
                key: "old-status-\(index)",
                value: "old",
                timestamp: oldTimestamp.addingTimeInterval(TimeInterval(index))
            )
        }
        workspace.agentPIDs["old-status-0"] = 101
        workspace.agentPIDs["old-status-1"] = 102
        let newestStatusKey = "new-status"
        let statusResponse = try await sendV2RequestAsync(
            method: "workspace.set_status",
            params: [
                "workspace_id": workspace.id.uuidString,
                "key": newestStatusKey,
                "value": "new",
                "pid": 303,
            ],
            to: socketPath
        )
        XCTAssertEqual(statusResponse["ok"] as? Bool, true)
        XCTAssertTrue(waitUntil {
            workspace.statusEntries.count == SidebarTelemetryLimits.maxStatusEntries &&
                workspace.statusEntries[newestStatusKey] != nil &&
                workspace.agentPIDs["old-status-0"] == nil &&
                workspace.agentPIDs[newestStatusKey] == 303
        })
        XCTAssertNil(workspace.statusEntries["old-status-0"], "The oldest status must be evicted at the collection bound")
        XCTAssertEqual(workspace.agentPIDs["old-status-1"], 102, "Eviction must preserve PID state for retained statuses")

        for index in 0..<SidebarTelemetryLimits.maxMetadataBlocks {
            workspace.metadataBlocks["old-meta-\(index)"] = SidebarMetadataBlock(
                key: "old-meta-\(index)",
                markdown: "old",
                priority: 0,
                timestamp: oldTimestamp.addingTimeInterval(TimeInterval(index))
            )
        }
        let newestMetadataKey = "new-meta"
        let metadataResponse = try await sendV2RequestAsync(
            method: "workspace.report_meta_block",
            params: [
                "workspace_id": workspace.id.uuidString,
                "key": newestMetadataKey,
                "markdown": "new",
            ],
            to: socketPath
        )
        XCTAssertEqual(metadataResponse["ok"] as? Bool, true)
        XCTAssertTrue(waitUntil {
            workspace.metadataBlocks.count == SidebarTelemetryLimits.maxMetadataBlocks &&
                workspace.metadataBlocks[newestMetadataKey] != nil
        })
        XCTAssertNil(workspace.metadataBlocks["old-meta-0"], "The oldest metadata block must be evicted at the collection bound")
    }

    func testWorkspaceAgentPIDCommandsEnforceIntegerAndKeyBounds() async throws {
        let socketPath = makeSocketPath("agent-pid-limits")
        let manager = TabManager()
        let workspace = manager.addWorkspace(select: true, eagerLoadTerminal: false)
        TerminalController.shared.start(
            tabManager: manager,
            socketPath: socketPath,
            accessMode: .allowAll
        )
        try waitForSocket(at: socketPath)

        let oversizedPID = Int(pid_t.max) + 1
        let oversizedKey = String(repeating: "k", count: SidebarTelemetryLimits.maxKeyBytes + 1)
        let rejectedRequests: [(method: String, params: [String: Any])] = [
            (
                "workspace.set_agent_pid",
                ["workspace_id": workspace.id.uuidString, "key": "zero", "pid": 0]
            ),
            (
                "workspace.set_agent_pid",
                ["workspace_id": workspace.id.uuidString, "key": "overflow", "pid": oversizedPID]
            ),
            (
                "workspace.set_agent_pid",
                ["workspace_id": workspace.id.uuidString, "key": oversizedKey, "pid": 1]
            ),
            (
                "workspace.clear_agent_pid",
                ["workspace_id": workspace.id.uuidString, "key": oversizedKey]
            ),
            (
                "workspace.set_status",
                ["workspace_id": workspace.id.uuidString, "key": "status-zero", "value": "ok", "pid": 0]
            ),
            (
                "workspace.set_status",
                ["workspace_id": workspace.id.uuidString, "key": "status-invalid", "value": "ok", "pid": "invalid"]
            ),
            (
                "workspace.set_status",
                ["workspace_id": workspace.id.uuidString, "key": "status-overflow", "value": "ok", "pid": oversizedPID]
            ),
        ]
        for request in rejectedRequests {
            let response = try await sendV2RequestAsync(
                method: request.method,
                params: request.params,
                to: socketPath
            )
            XCTAssertEqual(response["ok"] as? Bool, false, "Unexpected JSON-RPC response: \(response)")
            let error = try XCTUnwrap(response["error"] as? [String: Any])
            XCTAssertEqual(error["code"] as? String, "invalid_params")
        }

        let accepted = try await sendV2RequestAsync(
            method: "workspace.set_agent_pid",
            params: [
                "workspace_id": workspace.id.uuidString,
                "key": "maximum",
                "pid": Int(pid_t.max),
            ],
            to: socketPath
        )
        XCTAssertEqual(accepted["ok"] as? Bool, true, "The maximum pid_t value must remain accepted: \(accepted)")
        XCTAssertTrue(waitUntil { workspace.agentPIDs["maximum"] == pid_t.max })
    }

    func testWorkspaceTelemetryModelRejectsOversizedAuxiliaryFields() throws {
        let manager = TabManager()
        let workspace = manager.addWorkspace(select: true, eagerLoadTerminal: false)
        let oversizedURLPrefix = "https://example.com/"
        let oversizedURL = try XCTUnwrap(URL(string:
            oversizedURLPrefix + String(
                repeating: "u",
                count: SidebarTelemetryLimits.maxStatusURLBytes - oversizedURLPrefix.utf8.count + 1
            )
        ))
        let oversizedStatusEntries = [
            SidebarStatusEntry(
                key: String(repeating: "k", count: SidebarTelemetryLimits.maxKeyBytes + 1),
                value: "ok"
            ),
            SidebarStatusEntry(
                key: "oversized-icon",
                value: "ok",
                icon: String(repeating: "i", count: SidebarTelemetryLimits.maxStatusIconBytes + 1)
            ),
            SidebarStatusEntry(
                key: "oversized-color",
                value: "ok",
                color: String(repeating: "c", count: SidebarTelemetryLimits.maxStatusColorBytes + 1)
            ),
            SidebarStatusEntry(key: "oversized-url", value: "ok", url: oversizedURL),
        ]
        for entry in oversizedStatusEntries {
            XCTAssertFalse(workspace.setSidebarStatusEntry(entry).inserted)
        }
        XCTAssertTrue(workspace.statusEntries.isEmpty)

        XCTAssertFalse(workspace.setSidebarMetadataBlock(SidebarMetadataBlock(
            key: String(repeating: "k", count: SidebarTelemetryLimits.maxKeyBytes + 1),
            markdown: "ok",
            priority: 0,
            timestamp: Date()
        )))
        XCTAssertTrue(workspace.metadataBlocks.isEmpty)

        XCTAssertFalse(workspace.appendSidebarLogEntry(SidebarLogEntry(
            message: "ok",
            level: .info,
            source: String(repeating: "s", count: SidebarTelemetryLimits.maxLogSourceBytes + 1),
            timestamp: Date()
        )))
        XCTAssertTrue(workspace.logEntries.isEmpty)

        let panelId = UUID()
        let exactDirectory = String(repeating: "d", count: SidebarTelemetryLimits.maxDirectoryBytes)
        workspace.updatePanelDirectory(panelId: panelId, directory: exactDirectory)
        XCTAssertEqual(workspace.panelDirectories[panelId], exactDirectory)
        workspace.updatePanelDirectory(
            panelId: panelId,
            directory: String(repeating: "d", count: SidebarTelemetryLimits.maxDirectoryBytes + 1)
        )
        workspace.updatePanelDirectory(panelId: panelId, directory: "   ")
        XCTAssertEqual(workspace.panelDirectories[panelId], exactDirectory)

        let exactBranch = String(repeating: "b", count: SidebarTelemetryLimits.maxGitBranchBytes)
        workspace.updatePanelGitBranch(panelId: panelId, branch: exactBranch, isDirty: false)
        XCTAssertEqual(workspace.panelGitBranches[panelId]?.branch, exactBranch)
        workspace.updatePanelGitBranch(
            panelId: panelId,
            branch: String(repeating: "b", count: SidebarTelemetryLimits.maxGitBranchBytes + 1),
            isDirty: true
        )
        workspace.updatePanelGitBranch(panelId: panelId, branch: "   ", isDirty: true)
        XCTAssertEqual(workspace.panelGitBranches[panelId], SidebarGitBranchState(branch: exactBranch, isDirty: false))

        let pullRequestURLPrefix = "https://example.com/"
        let exactPullRequestURL = try XCTUnwrap(URL(string:
            pullRequestURLPrefix + String(
                repeating: "u",
                count: SidebarTelemetryLimits.maxPullRequestURLBytes - pullRequestURLPrefix.utf8.count
            )
        ))
        XCTAssertEqual(exactPullRequestURL.absoluteString.utf8.count, SidebarTelemetryLimits.maxPullRequestURLBytes)
        let exactLabel = String(repeating: "l", count: SidebarTelemetryLimits.maxPullRequestLabelBytes)
        workspace.updatePanelPullRequest(
            panelId: panelId,
            number: 1,
            label: exactLabel,
            url: exactPullRequestURL,
            status: .open,
            branch: exactBranch
        )
        XCTAssertEqual(workspace.panelPullRequests[panelId]?.label, exactLabel)
        XCTAssertEqual(workspace.panelPullRequests[panelId]?.url, exactPullRequestURL)
        XCTAssertEqual(workspace.panelPullRequests[panelId]?.branch, exactBranch)

        let retainedPullRequest = workspace.panelPullRequests[panelId]
        let oversizedPullRequestURL = try XCTUnwrap(URL(string:
            pullRequestURLPrefix + String(
                repeating: "u",
                count: SidebarTelemetryLimits.maxPullRequestURLBytes - pullRequestURLPrefix.utf8.count + 1
            )
        ))
        workspace.updatePanelPullRequest(
            panelId: panelId,
            number: 2,
            label: String(repeating: "l", count: SidebarTelemetryLimits.maxPullRequestLabelBytes + 1),
            url: exactPullRequestURL,
            status: .open,
            branch: exactBranch
        )
        workspace.updatePanelPullRequest(
            panelId: panelId,
            number: 2,
            label: "PR",
            url: oversizedPullRequestURL,
            status: .open,
            branch: exactBranch
        )
        workspace.updatePanelPullRequest(
            panelId: panelId,
            number: 2,
            label: "PR",
            url: exactPullRequestURL,
            status: .open,
            branch: String(repeating: "b", count: SidebarTelemetryLimits.maxGitBranchBytes + 1)
        )
        workspace.updatePanelPullRequest(
            panelId: panelId,
            number: 2,
            label: "PR",
            url: try XCTUnwrap(URL(string: "https:///missing-host")),
            status: .open,
            branch: exactBranch
        )
        XCTAssertEqual(workspace.panelPullRequests[panelId], retainedPullRequest)

        let exactProgressLabel = String(repeating: "p", count: SidebarTelemetryLimits.maxProgressLabelBytes)
        XCTAssertTrue(workspace.setSidebarProgress(value: 1.0, label: exactProgressLabel))
        XCTAssertEqual(workspace.progress, SidebarProgressState(value: 1.0, label: exactProgressLabel))
        XCTAssertFalse(workspace.setSidebarProgress(
            value: 0.5,
            label: String(repeating: "p", count: SidebarTelemetryLimits.maxProgressLabelBytes + 1)
        ))
        XCTAssertFalse(workspace.setSidebarProgress(value: -.infinity, label: nil))
        XCTAssertFalse(workspace.setSidebarProgress(value: 1.01, label: nil))
        XCTAssertEqual(workspace.progress, SidebarProgressState(value: 1.0, label: exactProgressLabel))

        let exactTTYName = String(repeating: "t", count: SidebarTelemetryLimits.maxTTYNameBytes)
        XCTAssertTrue(workspace.setSidebarTTYName(panelId: panelId, ttyName: exactTTYName))
        XCTAssertEqual(workspace.surfaceTTYNames[panelId], exactTTYName)
        XCTAssertFalse(workspace.setSidebarTTYName(panelId: panelId, ttyName: exactTTYName + "t"))
        XCTAssertEqual(workspace.surfaceTTYNames[panelId], exactTTYName)

        let exactPIDKey = String(repeating: "k", count: SidebarTelemetryLimits.maxKeyBytes)
        XCTAssertTrue(workspace.setSidebarAgentPID(key: exactPIDKey, pid: pid_t.max))
        XCTAssertEqual(workspace.agentPIDs.removeValue(forKey: exactPIDKey), pid_t.max)
        XCTAssertFalse(workspace.setSidebarAgentPID(
            key: String(repeating: "k", count: SidebarTelemetryLimits.maxKeyBytes + 1),
            pid: 1
        ))
        XCTAssertFalse(workspace.setSidebarAgentPID(key: "zero", pid: 0))

        for index in 0..<SidebarTelemetryLimits.maxAgentPIDs {
            XCTAssertTrue(workspace.setSidebarAgentPID(key: "agent-\(index)", pid: pid_t(index + 1)))
        }
        XCTAssertEqual(workspace.agentPIDs.count, SidebarTelemetryLimits.maxAgentPIDs)
        XCTAssertFalse(workspace.setSidebarAgentPID(key: "overflow", pid: 1))
        XCTAssertTrue(workspace.setSidebarAgentPID(key: "agent-0", pid: pid_t.max))
        XCTAssertEqual(workspace.agentPIDs["agent-0"], pid_t.max)
        XCTAssertEqual(workspace.agentPIDs.count, SidebarTelemetryLimits.maxAgentPIDs)

    }

    func testNewAgentRefreshInvalidatesResultsAlreadyValidatedForPublication() async {
        let manager = TabManager()
        let workspace = manager.addWorkspace(select: true, eagerLoadTerminal: false)
        let workspaceId = workspace.id
        let gate = AgentPortPublicationGate()
        let staleNonemptyPublication = OSAllocatedUnfairLock(initialState: false)
        let validationPaused = expectation(description: "old agent ports validate before the newer refresh")
        let emptyPublication = expectation(description: "current empty agent ports publish")
        let oldApplyCompleted = expectation(description: "old validated agent ports finish the apply phase")
        let scanner = PortScanner(
            observesAppVisibility: false,
            agentScanOverride: { workspaceIds, agentPIDsByWorkspace in
                guard !agentPIDsByWorkspace.isEmpty else { return [:] }
                return Dictionary(uniqueKeysWithValues: workspaceIds.map { ($0, Set([5173])) })
            },
            agentResultsValidatedHook: { results in
                guard results.contains(where: { !$0.1.isEmpty }) else { return }
                validationPaused.fulfill()
                await gate.pause()
            },
            agentResultsApplyCompletedHook: { results in
                guard results.contains(where: { $0.0 == workspaceId && !$0.1.isEmpty }) else { return }
                oldApplyCompleted.fulfill()
            }
        )
        scanner.onAgentPortsUpdated = { publishedWorkspaceId, ports in
            guard publishedWorkspaceId == workspace.id else { return }
            if !ports.isEmpty {
                staleNonemptyPublication.withLock { $0 = true }
            }
            if workspace.agentListeningPorts != ports {
                workspace.agentListeningPorts = ports
                workspace.recomputeListeningPorts()
            }
            if ports.isEmpty {
                emptyPublication.fulfill()
            }
        }

        XCTAssertTrue(workspace.setSidebarAgentPID(key: "test-agent", pid: 42))
        workspace.agentListeningPorts = [4242]
        workspace.recomputeListeningPorts()
        XCTAssertEqual(workspace.agentListeningPorts, [4242])
        XCTAssertEqual(workspace.listeningPorts, [4242])

        scanner.refreshAgentPorts(workspaceId: workspaceId, agentPIDs: [42])
        await fulfillment(of: [validationPaused], timeout: 2.0)

        workspace.resetSidebarContext(reason: "test-agent-port-reset", portScanner: scanner)
        await fulfillment(of: [emptyPublication], timeout: 2.0)

        await gate.release()
        await fulfillment(of: [oldApplyCompleted], timeout: 2.0)

        XCTAssertFalse(staleNonemptyPublication.withLock { $0 })
        XCTAssertTrue(workspace.agentPIDs.isEmpty)
        XCTAssertTrue(workspace.agentListeningPorts.isEmpty)
        XCTAssertTrue(workspace.listeningPorts.isEmpty)
    }

    private func waitForSocket(at path: String, timeout: TimeInterval = 5.0) throws {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                FileManager.default.fileExists(atPath: path)
            },
            object: NSObject()
        )
        if XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed {
            return
        }
        XCTFail("Timed out waiting for socket at \(path)")
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(ETIMEDOUT))
    }

    /// Polls `condition` on the main run loop until it returns true or `timeout` elapses.
    /// Used to observe fire-and-forget telemetry mutations (see #82: `surface.report_tty` /
    /// `surface.ports_kick` schedule their model mutation via `DispatchQueue.main.async` and
    /// acknowledge the JSON-RPC request before it runs).
    @discardableResult
    private func waitUntil(timeout: TimeInterval = 5.0, _ condition: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in condition() },
            object: NSObject()
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func socketMode(at path: String) throws -> UInt16 {
        var fileInfo = stat()
        guard lstat(path, &fileInfo) == 0 else {
            throw posixError("lstat(\(path))")
        }
        return UInt16(fileInfo.st_mode & 0o777)
    }

    private func sendCommands(_ commands: [String], to socketPath: String) throws -> [String] {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw posixError("socket(AF_UNIX)")
        }
        defer { Darwin.close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let bytes = Array(socketPath.utf8)
        let maxPathLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < maxPathLen else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENAMETOOLONG))
        }

        withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
            let cPath = UnsafeMutableRawPointer(pathPtr).assumingMemoryBound(to: CChar.self)
            cPath.initialize(repeating: 0, count: maxPathLen)
            for (index, byte) in bytes.enumerated() {
                cPath[index] = CChar(bitPattern: byte)
            }
        }

        let addrLen = socklen_t(MemoryLayout<sa_family_t>.size + bytes.count + 1)
        let connectResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(fd, sockaddrPtr, addrLen)
            }
        }
        guard connectResult == 0 else {
            throw posixError("connect(\(socketPath))")
        }

        var responses: [String] = []
        for command in commands {
            try writeLine(command, to: fd)
            responses.append(try readLine(from: fd))
        }
        return responses
    }

    private nonisolated func sendV2Request(
        method: String,
        params: [String: Any],
        to socketPath: String
    ) throws -> [String: Any] {
        let fd = try connect(to: socketPath)
        defer { Darwin.close(fd) }

        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": method,
            "params": params
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let line = String(data: data, encoding: .utf8) else {
            throw NSError(domain: NSCocoaErrorDomain, code: 0, userInfo: [
                NSLocalizedDescriptionKey: "Failed to encode JSON-RPC request"
            ])
        }
        try writeLine(line, to: fd)

        let responseLine = try readLine(from: fd)
        let responseData = Data(responseLine.utf8)
        return try XCTUnwrap(
            try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
            "Expected JSON-RPC response object"
        )
    }

    private func sendV2RequestAsync(
        method: String,
        params: [String: Any],
        to socketPath: String
    ) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let response = try self.sendV2Request(
                        method: method,
                        params: params,
                        to: socketPath
                    )
                    continuation.resume(returning: response)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private nonisolated func connect(to socketPath: String) throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw posixError("socket(AF_UNIX)")
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let bytes = Array(socketPath.utf8)
        let maxPathLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < maxPathLen else {
            Darwin.close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENAMETOOLONG))
        }

        withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
            let cPath = UnsafeMutableRawPointer(pathPtr).assumingMemoryBound(to: CChar.self)
            cPath.initialize(repeating: 0, count: maxPathLen)
            for (index, byte) in bytes.enumerated() {
                cPath[index] = CChar(bitPattern: byte)
            }
        }

        let addrLen = socklen_t(MemoryLayout<sa_family_t>.size + bytes.count + 1)
        let connectResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(fd, sockaddrPtr, addrLen)
            }
        }
        guard connectResult == 0 else {
            let error = posixError("connect(\(socketPath))")
            Darwin.close(fd)
            throw error
        }
        return fd
    }

    private nonisolated func connectPersistentClient(to socketPath: String) throws -> Int32 {
        let fd = try connect(to: socketPath)
        do {
            try suppressSIGPIPE(on: fd)
        } catch {
            Darwin.close(fd)
            throw error
        }
        return fd
    }

    private nonisolated func suppressSIGPIPE(on fd: Int32) throws {
        var enabled: Int32 = 1
        let result = withUnsafePointer(to: &enabled) { pointer in
            Darwin.setsockopt(
                fd,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                pointer,
                socklen_t(MemoryLayout<Int32>.size)
            )
        }
        guard result == 0 else {
            throw posixError("setsockopt(SO_NOSIGPIPE)")
        }
    }

    private nonisolated func sendV2Ping(
        to fd: Int32,
        id: Int,
        timeout: TimeInterval = 5.0
    ) throws -> [String: Any] {
        try sendV2Request(
            method: "system.ping",
            params: [:],
            id: id,
            to: fd,
            timeout: timeout
        )
    }

    private nonisolated func sendV2Request(
        method: String,
        params: [String: Any],
        id: Int,
        to fd: Int32,
        timeout: TimeInterval = 5.0
    ) throws -> [String: Any] {
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let line = String(data: data, encoding: .utf8) else {
            throw NSError(domain: NSCocoaErrorDomain, code: 0, userInfo: [
                NSLocalizedDescriptionKey: "Failed to encode JSON-RPC request"
            ])
        }
        try writeLine(line, to: fd)

        let responseLine = try readLine(from: fd, timeout: timeout)
        let responseData = Data(responseLine.utf8)
        return try XCTUnwrap(
            try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
            "Expected JSON-RPC response object"
        )
    }

    private nonisolated func isSuccessfulV2Ping(_ response: [String: Any]) -> Bool {
        guard response["ok"] as? Bool == true,
              let result = response["result"] as? [String: Any]
        else { return false }
        return result["pong"] as? Bool == true
    }

    private nonisolated func isSuccessfulV2Authentication(_ response: [String: Any]) -> Bool {
        guard response["ok"] as? Bool == true,
              let result = response["result"] as? [String: Any]
        else { return false }
        return result["authenticated"] as? Bool == true
    }

    private nonisolated func v2ErrorCode(_ response: [String: Any]) -> String? {
        guard response["ok"] as? Bool == false,
              let error = response["error"] as? [String: Any]
        else { return nil }
        return error["code"] as? String
    }

    private nonisolated func writeLine(_ command: String, to fd: Int32) throws {
        let payload = Array((command + "\n").utf8)
        var offset = 0
        while offset < payload.count {
            let wrote = payload.withUnsafeBytes { raw in
                Darwin.write(fd, raw.baseAddress!.advanced(by: offset), payload.count - offset)
            }
            guard wrote >= 0 else {
                throw posixError("write(\(command))")
            }
            offset += wrote
        }
    }

    private nonisolated func readLine(from fd: Int32, timeout: TimeInterval = 5.0) throws -> String {
        var buffer = [UInt8](repeating: 0, count: 1)
        var data = Data()
        let deadline = DispatchTime.now() + timeout

        while true {
            try waitForReadable(from: fd, until: deadline, operation: "waiting for a socket response line")
            let count = Darwin.read(fd, &buffer, 1)
            guard count >= 0 else {
                throw posixError("read")
            }
            if count == 0 {
                if data.isEmpty {
                    // The peer closed the connection before sending any bytes for this
                    // line (e.g. a revoked client after a password rotation). Surface this
                    // distinctly from a legitimate empty response so callers using `try?`
                    // (to tolerate revocation) don't trip an unconditional XCTUnwrap
                    // failure on the caller side when they parse this as JSON.
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNRESET), userInfo: [
                        NSLocalizedDescriptionKey: "Connection closed before a response line was received",
                    ])
                }
                break
            }
            if buffer[0] == 0x0A { break }
            data.append(buffer[0])
        }

        guard let line = String(data: data, encoding: .utf8) else {
            throw NSError(domain: NSCocoaErrorDomain, code: 0, userInfo: [
                NSLocalizedDescriptionKey: "Invalid UTF-8 response from socket"
            ])
        }
        return line
    }

    private nonisolated func waitForReadable(
        from fd: Int32,
        until deadline: DispatchTime,
        operation: String
    ) throws {
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline.uptimeNanoseconds else {
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(ETIMEDOUT),
                    userInfo: [NSLocalizedDescriptionKey: "Timed out \(operation)"]
                )
            }
            let remainingNanoseconds = deadline.uptimeNanoseconds - now
            let remainingMilliseconds = max(1, (remainingNanoseconds + 999_999) / 1_000_000)
            let pollTimeout = Int32(min(UInt64(Int32.max), remainingMilliseconds))
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let result = Darwin.poll(&descriptor, 1, pollTimeout)
            if result > 0 { return }
            if result == 0 { continue }
            if errno == EINTR { continue }
            throw posixError("poll while \(operation)")
        }
    }

    private nonisolated func posixError(_ operation: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: "\(operation) failed: \(String(cString: strerror(errno)))"]
        )
    }

    // MARK: - Session escrow: SIGPIPE-safe retrieve-response send (issue #182)

    /// Regression for a real relaunch incident: the escrow holder
    /// (`SessionEscrowHolder.handleRetrieveRequest`) can finish stopping a
    /// session's drain thread (bounded by `SessionEscrowPolicy
    /// .retrieveDrainStopTimeout`, 3s) after the app-side client has
    /// already given up waiting and closed its end of the connection (see
    /// `SessionEscrowPolicy.retrieveRecvTimeout`'s invariant comment).
    /// Writing the retrieve-response frame into that now-peer-closed
    /// connection raises `SIGPIPE` unless the accepted socket has
    /// `SO_NOSIGPIPE` set -- default disposition kills the WHOLE holder
    /// process, dropping every OTHER escrowed session it still holds, not
    /// just the one send that failed.
    ///
    /// This reproduces the exact primitive sequence
    /// `SessionEscrowHolder.run()`'s accept loop uses
    /// (`UnixDomainFDPassing.bindListening` -> `.connect` -> raw
    /// `accept()` -> `UnixDomainFDPassing.suppressSigPipe(on:)`) against a
    /// peer that has already hung up, and asserts the send fails cleanly
    /// (`false`, `EPIPE`) rather than crashing. Confirmed separately
    /// (outside this test, not committed) that omitting the
    /// `suppressSigPipe` call reproduces a hard process crash (terminated
    /// by `SIGPIPE`) on this exact sequence -- deliberately not exercised
    /// as a literal "red without the fix" commit here, since a crash would
    /// take down the entire shared XCTest process for this whole test
    /// bundle, not just this one test method.
    func testEscrowRetrieveResponseSendSurvivesClosedPeerWithoutCrashing() {
        let socketPath = makeSocketPath("escrow-nosigpipe")
        defer { unlink(socketPath) }

        guard let listenFD = UnixDomainFDPassing.bindListening(socketPath: socketPath) else {
            XCTFail("bindListening failed")
            return
        }
        defer { close(listenFD) }

        guard let clientFD = UnixDomainFDPassing.connect(to: socketPath) else {
            XCTFail("connect failed")
            return
        }

        let acceptedFD = accept(listenFD, nil, nil)
        guard acceptedFD >= 0 else {
            close(clientFD)
            XCTFail("accept failed")
            return
        }
        defer { close(acceptedFD) }

        // Mirrors `SessionEscrowHolder.run()`'s accept loop exactly: every
        // accepted connection gets `SO_NOSIGPIPE` before it's ever handed
        // to `serve(connectionFD:)`.
        UnixDomainFDPassing.suppressSigPipe(on: acceptedFD)

        // The app-side client abandoning the connection -- `retrieve()`
        // closes its socket via `defer` on every exit path, including a
        // timeout -- so the holder's `acceptedFD` is now writing into a
        // peer that has already hung up.
        close(clientFD)

        guard let frame = EscrowWireFormat.encodeRetrieveResponseFrame(
            sessionId: String(repeating: "a", count: EscrowWireFormat.sessionIdSize),
            granted: false
        ) else {
            XCTFail("failed to encode frame")
            return
        }

        let sendResult = UnixDomainFDPassing.send(fd: nil, payload: frame, over: acceptedFD)

        // Reaching this assertion at all is most of the point -- pre-fix,
        // the process does not survive the `send` call above.
        XCTAssertFalse(sendResult, "send to a closed peer must fail cleanly (EPIPE), not succeed")
    }

    // MARK: - Session escrow: per-socket-path circuit breaker (escrow follow-up #6)

    /// Thread-safe bookkeeping for the background "wedged holder" accept
    /// loop below: it accepts every connection but never responds, so a
    /// `retrieve()` call against it always times out rather than seeing EOF
    /// -- the exact failure mode the circuit breaker exists for.
    private final class AcceptedConnections: @unchecked Sendable {
        private let lock = NSLock()
        private var fds: [Int32] = []

        func append(_ fd: Int32) {
            lock.lock()
            fds.append(fd)
            lock.unlock()
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return fds.count
        }

        func closeAll() {
            lock.lock()
            let all = fds
            fds = []
            lock.unlock()
            for fd in all { close(fd) }
        }

        /// Polls (bounded) until the accept thread has recorded at least
        /// `expected` connections, or `timeout` elapses. A plain `count`
        /// read races the accept thread: `retrieve()` returning (its recv
        /// timeout having elapsed) only guarantees the kernel completed the
        /// connection, not that this thread's `accept()` call has returned
        /// and appended the fd yet. Returns whatever count was actually
        /// observed so the caller's assertion message stays meaningful on
        /// a genuine failure.
        func waitForCount(atLeast expected: Int, timeout: TimeInterval = 2.0) -> Int {
            let deadline = Date().addingTimeInterval(timeout)
            while true {
                let current = count
                if current >= expected || Date() >= deadline {
                    return current
                }
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
    }

    /// Regression for the escrow follow-up ("per-socket-path circuit
    /// breaker for wedged holders"): app-launch restore
    /// (`Workspace+Persistence.swift`'s `attemptSessionReattach`) calls
    /// `SessionEscrowClient.retrieve` SERIALLY on the main thread, once per
    /// escrowed panel, and almost every panel shares the SAME deterministic
    /// holder socket path. Without a breaker, N sessions against one
    /// wedged (accepts but never answers) holder would each pay the full
    /// `retrieveRecvTimeout` -- N times the stall for one dead holder.
    ///
    /// This drives a real wedged holder (accepts, never responds) against
    /// an injectable short `recvTimeout` (avoiding the real 5s
    /// `SessionEscrowPolicy.retrieveRecvTimeout`) and asserts: the first
    /// retrieve pays the full timeout and opens the breaker for that path;
    /// a second retrieve against the SAME path returns near-instantly
    /// without attempting a new connection at all (the listener sees no
    /// second connection); and after resetting the breaker, a retrieve
    /// against that path attempts a genuinely fresh connect again.
    func testEscrowRetrieveCircuitBreakerSkipsSecondCallToWedgedHolder() {
        SessionEscrowClient.resetCircuitBreakerForTesting()
        defer { SessionEscrowClient.resetCircuitBreakerForTesting() }

        let socketPath = makeSocketPath("escrow-cb")
        defer { unlink(socketPath) }

        guard let listenFD = UnixDomainFDPassing.bindListening(socketPath: socketPath) else {
            XCTFail("bindListening failed")
            return
        }

        let accepted = AcceptedConnections()
        let holderThread = Thread {
            while true {
                let clientFD = accept(listenFD, nil, nil)
                guard clientFD >= 0 else { break }
                // Wedged: accept the connection but never send a response
                // and never close it -- the client's own recv timeout is
                // the only thing that ever ends this connection.
                accepted.append(clientFD)
            }
        }
        holderThread.start()
        defer {
            close(listenFD) // unblocks the accept() loop so the thread exits
            accepted.closeAll()
        }

        let sessionId = String(repeating: "a", count: EscrowWireFormat.sessionIdSize)
        let tokenHex = String(repeating: "00", count: EscrowWireFormat.tokenSize)
        let shortTimeout: TimeInterval = 0.2

        let firstStart = Date()
        let firstResult = SessionEscrowClient.retrieve(
            sessionId: sessionId,
            tokenHex: tokenHex,
            socketPath: socketPath,
            recvTimeout: shortTimeout
        )
        let firstElapsed = Date().timeIntervalSince(firstStart)
        XCTAssertNil(firstResult, "a wedged holder must never grant a retrieval")
        XCTAssertGreaterThanOrEqual(firstElapsed, shortTimeout, "first retrieve must actually wait out the recv timeout")
        XCTAssertEqual(accepted.waitForCount(atLeast: 1), 1, "the wedged holder must have accepted exactly one connection so far")

        let secondStart = Date()
        let secondResult = SessionEscrowClient.retrieve(
            sessionId: sessionId,
            tokenHex: tokenHex,
            socketPath: socketPath,
            recvTimeout: shortTimeout
        )
        let secondElapsed = Date().timeIntervalSince(secondStart)
        XCTAssertNil(secondResult)
        XCTAssertLessThan(secondElapsed, 0.15, "second retrieve against the same path must be skipped by the open breaker, not pay another timeout (still well under the 0.2s injected timeout)")
        XCTAssertEqual(accepted.count, 1, "an open breaker must prevent a second connection attempt to the wedged holder")

        SessionEscrowClient.resetCircuitBreakerForTesting()

        let thirdStart = Date()
        let thirdResult = SessionEscrowClient.retrieve(
            sessionId: sessionId,
            tokenHex: tokenHex,
            socketPath: socketPath,
            recvTimeout: shortTimeout
        )
        let thirdElapsed = Date().timeIntervalSince(thirdStart)
        XCTAssertNil(thirdResult)
        XCTAssertGreaterThanOrEqual(thirdElapsed, shortTimeout, "after resetting the breaker, retrieve must attempt a genuinely fresh connect")
        XCTAssertEqual(accepted.waitForCount(atLeast: 2), 2, "the reset breaker must allow a new connection attempt, which the holder accepts")
    }

    // MARK: - Revived-session ancestry authorization (#286)

    /// Spawns a live process that is deliberately **not** a descendant of this
    /// one: a short-lived `sh` backgrounds a `sleep` and exits, so the `sleep`
    /// is orphaned and reparented to launchd. That is exactly the shape an
    /// escrow-revived shell has — forked by the previous app process, adopted
    /// by launchd when that process died — which is why its ancestry can never
    /// walk back to us. Returns the orphan's pid, killed again on teardown.
    private func spawnOrphanedProcess() throws -> pid_t {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 30 >/dev/null 2>&1 & echo $!"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try XCTUnwrap(pid_t(text), "could not read the orphan's pid from sh")
        XCTAssertGreaterThan(pid, 1)
        addTeardownBlock { kill(pid, SIGKILL) }

        // The intermediate `sh` has exited, so the orphan is now launchd's.
        // Give the reparent a moment to land before anyone walks the tree.
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, TerminalController.shared.isDescendant(pid) {
            usleep(20_000)
        }
        return pid
    }

    func testRevivedRootAuthorizesAPidThatIsNotADescendant() throws {
        let orphan = try spawnOrphanedProcess()
        TerminalController.unregisterRevivedRoot(orphan)

        XCTAssertFalse(
            TerminalController.shared.isDescendant(orphan),
            "a reparented process must be rejected while unregistered — this is the #286 failure"
        )

        TerminalController.registerRevivedRoot(orphan)
        defer { TerminalController.unregisterRevivedRoot(orphan) }

        XCTAssertTrue(
            TerminalController.shared.isDescendant(orphan),
            "a pid adopted from escrow must be accepted as an ancestry root"
        )
    }

    func testUnregisteringARevivedRootWithdrawsAuthorization() throws {
        let orphan = try spawnOrphanedProcess()
        TerminalController.registerRevivedRoot(orphan)
        XCTAssertTrue(TerminalController.shared.isDescendant(orphan))

        TerminalController.unregisterRevivedRoot(orphan)

        XCTAssertFalse(
            TerminalController.shared.isDescendant(orphan),
            "authorization must not outlive the session that owned the pid, or a recycled pid stays trusted"
        )
    }

    func testRevivedRootRegistrationRejectsLaunchdAndInvalidPids() {
        // Registering pid 1 would authorize the ancestry root of every process
        // on the machine, which is the whole boundary `cmuxOnly` protects.
        TerminalController.registerRevivedRoot(1)
        TerminalController.registerRevivedRoot(0)
        TerminalController.registerRevivedRoot(-1)

        XCTAssertFalse(TerminalController.isRevivedRoot(1))
        XCTAssertFalse(TerminalController.isRevivedRoot(0))
        XCTAssertFalse(TerminalController.isRevivedRoot(-1))
    }

    func testOwnDescendantsStillPassWithoutAnyRegistration() {
        // The ordinary path must be untouched by the revived-root addition.
        XCTAssertTrue(
            TerminalController.shared.isDescendant(getpid()),
            "this process must still count as inside its own tree"
        )
    }
}
