import XCTest
import Darwin
import Combine

#if canImport(Programa_DEV)
@testable import Programa_DEV
#elseif canImport(Programa)
@testable import Programa
#endif

private let appDelegateLastSurfaceCloseShortcutDefaultsKey = "closeWorkspaceOnLastSurfaceShortcut"
private final class FakeWKInspectorContainerView: NSView {}
private final class FocusableTestView: NSView {
    override var acceptsFirstResponder: Bool { true }
}
private final class CloseConfirmationButtonRecorder: NSObject {
    private(set) var clickCount = 0

    @objc func recordClick(_ sender: NSButton) {
        clickCount += 1
    }
}

@MainActor
final class AppDelegateShortcutRoutingTests: XCTestCase {
    private var savedShortcutsByAction: [KeyboardShortcutSettings.Action: StoredShortcut] = [:]
    private var actionsWithPersistedShortcut: Set<KeyboardShortcutSettings.Action> = []
    private var originalSettingsFileStore: KeyboardShortcutSettingsFileStore!

    /// Polls `condition` by spinning the run loop in short increments, returning as soon as
    /// it holds. Mirrors the poll style already used at this file's flake-prone fixed-spin
    /// sites (e.g. the fullscreen-tiling opt-out wait and the search-field mount wait below)
    /// rather than a fixed sleep: a fast pass returns almost immediately and a genuine failure
    /// still gets a generous window before failing, instead of a flake on a loaded CI runner.
    @discardableResult
    private func waitUntil(
        timeout: TimeInterval = 2.0,
        description: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Timed out waiting for \(description)", file: file, line: line)
                return false
            }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        return true
    }

    private func makeKeyEvent(
        modifierFlags: NSEvent.ModifierFlags,
        characters: String,
        charactersIgnoringModifiers: String,
        keyCode: UInt16
    ) -> NSEvent {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            isARepeat: false,
            keyCode: keyCode
        ) else {
            fatalError("Failed to construct key event")
        }
        return event
    }

    override func setUp() {
        super.setUp()
        // Prevent a single hanging test from consuming the entire CI timeout budget.
        executionTimeAllowance = 30
        actionsWithPersistedShortcut = Set(
            KeyboardShortcutSettings.Action.allCases.filter {
                UserDefaults.standard.object(forKey: $0.defaultsKey) != nil
            }
        )
        savedShortcutsByAction = Dictionary(
            uniqueKeysWithValues: actionsWithPersistedShortcut.map { action in
                (action, KeyboardShortcutSettings.shortcut(for: action))
            }
        )
        originalSettingsFileStore = KeyboardShortcutSettings.settingsFileStore
        KeyboardShortcutSettings.resetAll()
    }

    override func tearDown() {
        KeyboardShortcutSettings.settingsFileStore = originalSettingsFileStore
        AppDelegate.shared?.shortcutLayoutCharacterProvider = KeyboardLayout.character(forKeyCode:modifierFlags:)
        AppDelegate.shared?.debugCreateMainWindowSourceIsNativeFullScreenOverride = nil
        AppDelegate.shared?.dismissNotificationsPopoverIfShown()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        for action in KeyboardShortcutSettings.Action.allCases {
            if actionsWithPersistedShortcut.contains(action),
               let savedShortcut = savedShortcutsByAction[action] {
                KeyboardShortcutSettings.setShortcut(savedShortcut, for: action)
            } else {
                KeyboardShortcutSettings.resetShortcut(for: action)
            }
        }
        super.tearDown()
    }

    func testDuplicateInstanceArbitrationLetsLaterStartSecondWinAndEarlierStartLose() {
        let earlier = ProgramaSingleInstanceProcessKey(
            startSeconds: 1_000,
            startMicroseconds: 999_999,
            processIdentifier: 200
        )
        let later = ProgramaSingleInstanceProcessKey(
            startSeconds: 1_001,
            startMicroseconds: 0,
            processIdentifier: 100
        )

        XCTAssertTrue(AppDelegate.shouldTerminateDuplicateInstance(current: later, other: earlier))
        XCTAssertFalse(AppDelegate.shouldTerminateDuplicateInstance(current: earlier, other: later))
    }

    func testDuplicateInstanceArbitrationLetsLaterStartMicrosecondWinAndEarlierStartLose() {
        let earlier = ProgramaSingleInstanceProcessKey(
            startSeconds: 1_000,
            startMicroseconds: 100,
            processIdentifier: 200
        )
        let later = ProgramaSingleInstanceProcessKey(
            startSeconds: 1_000,
            startMicroseconds: 101,
            processIdentifier: 100
        )

        XCTAssertTrue(AppDelegate.shouldTerminateDuplicateInstance(current: later, other: earlier))
        XCTAssertFalse(AppDelegate.shouldTerminateDuplicateInstance(current: earlier, other: later))
    }

    func testDuplicateInstanceArbitrationUsesPIDToElectOneWinnerForIdenticalTimestamps() {
        let lowerPID = ProgramaSingleInstanceProcessKey(
            startSeconds: 1_000,
            startMicroseconds: 100,
            processIdentifier: 100
        )
        let higherPID = ProgramaSingleInstanceProcessKey(
            startSeconds: 1_000,
            startMicroseconds: 100,
            processIdentifier: 200
        )
        let higherPIDWins = AppDelegate.shouldTerminateDuplicateInstance(current: higherPID, other: lowerPID)
        let lowerPIDWins = AppDelegate.shouldTerminateDuplicateInstance(current: lowerPID, other: higherPID)

        XCTAssertTrue(higherPIDWins)
        XCTAssertFalse(lowerPIDWins)
        XCTAssertNotEqual(higherPIDWins, lowerPIDWins, "Identical kernel timestamps must elect exactly one winner")
    }

    func testDuplicateInstanceCandidateExcludesEmbeddedCLIExecutable() {
        let embeddedCLIURL = URL(
            fileURLWithPath: "/Applications/Programa.app/Contents/Resources/bin/programa"
        )

        XCTAssertFalse(AppDelegate.shouldConsiderDuplicateApplication(
            candidateBundleIdentifier: "com.darkroom.programa",
            candidateProcessIdentifier: 200,
            candidateExecutableURL: embeddedCLIURL,
            expectedBundleIdentifier: "com.darkroom.programa",
            currentProcessIdentifier: 100,
            embeddedCLIURL: embeddedCLIURL
        ))
    }

    func testDuplicateInstanceCandidateIncludesSameBundleGUIExecutable() {
        XCTAssertTrue(AppDelegate.shouldConsiderDuplicateApplication(
            candidateBundleIdentifier: "com.darkroom.programa",
            candidateProcessIdentifier: 200,
            candidateExecutableURL: URL(
                fileURLWithPath: "/Applications/Programa.app/Contents/MacOS/Programa"
            ),
            expectedBundleIdentifier: "com.darkroom.programa",
            currentProcessIdentifier: 100,
            embeddedCLIURL: URL(
                fileURLWithPath: "/Applications/Programa.app/Contents/Resources/bin/programa"
            )
        ))
    }

    func testDuplicateInstanceCandidateRejectsMissingExecutableMetadata() {
        XCTAssertFalse(AppDelegate.shouldConsiderDuplicateApplication(
            candidateBundleIdentifier: "com.darkroom.programa",
            candidateProcessIdentifier: 200,
            candidateExecutableURL: nil,
            expectedBundleIdentifier: "com.darkroom.programa",
            currentProcessIdentifier: 100,
            embeddedCLIURL: URL(
                fileURLWithPath: "/Applications/Programa.app/Contents/Resources/bin/programa"
            )
        ))
    }

    func testDuplicateInstanceTerminationWaitsForGraceBeforeRunningFallback() throws {
        var gracefulTerminationCount = 0
        var fallbackCount = 0
        var scheduledGraceAction: (@MainActor () -> Void)?

        AppDelegate.scheduleDuplicateTerminationForTesting(
            requestTermination: {
                gracefulTerminationCount += 1
                return true
            },
            scheduleGrace: { action in
                scheduledGraceAction = action
            },
            performFallbackAfterGrace: {
                fallbackCount += 1
            }
        )

        XCTAssertEqual(gracefulTerminationCount, 1)
        XCTAssertEqual(fallbackCount, 0, "The fallback must not run synchronously")

        let graceAction = try XCTUnwrap(scheduledGraceAction)
        graceAction()

        XCTAssertEqual(fallbackCount, 1)
    }

    func testValidatedDuplicateShutdownRequestTargetsExactCurrentProcessAndBypassesWarning() {
        let current = ProgramaSingleInstanceProcessKey(
            startSeconds: 1_000,
            startMicroseconds: 100,
            processIdentifier: 100
        )
        let requester = ProgramaSingleInstanceProcessKey(
            startSeconds: 1_001,
            startMicroseconds: 0,
            processIdentifier: 200
        )
        let request = AppDelegate.SingleInstanceShutdownRequest(
            target: current,
            requester: requester,
            createdAtUnixSeconds: 10_000
        )

        let accepted = AppDelegate.shouldAcceptDuplicateShutdownRequestForTesting(
            request,
            currentProcessKey: current,
            now: 10_001,
            resolvedRequesterKey: requester,
            requesterIsProgramaGUI: true
        )

        XCTAssertTrue(accepted)
        XCTAssertFalse(AppDelegate.shouldWarnBeforeTerminationForTesting(
            isTaggedDevBuild: false,
            isQuitWarningConfirmed: false,
            isInternalSingleInstanceLoserExit: false,
            hasValidatedDuplicateShutdownRequest: accepted,
            isQuitWarningEnabled: true
        ))
    }

    func testDuplicateShutdownRequestFailsClosedWhenMissingStaleMalformedOrMismatched() {
        let current = ProgramaSingleInstanceProcessKey(
            startSeconds: 1_000,
            startMicroseconds: 100,
            processIdentifier: 100
        )
        let requester = ProgramaSingleInstanceProcessKey(
            startSeconds: 1_001,
            startMicroseconds: 0,
            processIdentifier: 200
        )
        let wrongTarget = ProgramaSingleInstanceProcessKey(
            startSeconds: 999,
            startMicroseconds: 999,
            processIdentifier: 99
        )
        let staleRequest = AppDelegate.SingleInstanceShutdownRequest(
            target: current,
            requester: requester,
            createdAtUnixSeconds: 9_000
        )
        let malformedVersionRequest = AppDelegate.SingleInstanceShutdownRequest(
            version: AppDelegate.SingleInstanceShutdownRequest.currentVersion + 1,
            target: current,
            requester: requester,
            createdAtUnixSeconds: 10_000
        )
        let mismatchedTargetRequest = AppDelegate.SingleInstanceShutdownRequest(
            target: wrongTarget,
            requester: requester,
            createdAtUnixSeconds: 10_000
        )

        XCTAssertFalse(AppDelegate.shouldAcceptDuplicateShutdownRequestForTesting(
            nil,
            currentProcessKey: current,
            now: 10_001,
            resolvedRequesterKey: requester,
            requesterIsProgramaGUI: true
        ))
        XCTAssertFalse(AppDelegate.shouldAcceptDuplicateShutdownRequestForTesting(
            staleRequest,
            currentProcessKey: current,
            now: 10_001,
            resolvedRequesterKey: requester,
            requesterIsProgramaGUI: true
        ))
        XCTAssertFalse(AppDelegate.shouldAcceptDuplicateShutdownRequestForTesting(
            malformedVersionRequest,
            currentProcessKey: current,
            now: 10_001,
            resolvedRequesterKey: requester,
            requesterIsProgramaGUI: true
        ))
        XCTAssertFalse(AppDelegate.shouldAcceptDuplicateShutdownRequestForTesting(
            mismatchedTargetRequest,
            currentProcessKey: current,
            now: 10_001,
            resolvedRequesterKey: requester,
            requesterIsProgramaGUI: true
        ))
        XCTAssertFalse(AppDelegate.shouldAcceptDuplicateShutdownRequestForTesting(
            staleRequest,
            currentProcessKey: current,
            now: 9_001,
            resolvedRequesterKey: wrongTarget,
            requesterIsProgramaGUI: true
        ))
        XCTAssertFalse(AppDelegate.shouldAcceptDuplicateShutdownRequestForTesting(
            staleRequest,
            currentProcessKey: current,
            now: 9_001,
            resolvedRequesterKey: requester,
            requesterIsProgramaGUI: false
        ))
    }

    func testOrdinaryQuitStillWarnsWhenWarningIsEnabled() {
        XCTAssertTrue(AppDelegate.shouldWarnBeforeTerminationForTesting(
            isTaggedDevBuild: false,
            isQuitWarningConfirmed: false,
            isInternalSingleInstanceLoserExit: false,
            hasValidatedDuplicateShutdownRequest: false,
            isQuitWarningEnabled: true
        ))
    }

#if DEBUG
    func testFailedQuitSaveKeepsSessionsRunningAndSuccessfulRetryCanQuit() throws {
        let appDelegate = try XCTUnwrap(AppDelegate.shared)
        closeAllMainWindows()
        let windowId = UUID()
        let window = makeUnregisteredMainWindow(windowId: windowId)
        let manager = TabManager()
        let warningWasEnabled = QuitWarningSettings.isEnabled()
        QuitWarningSettings.setEnabled(false)
        defer {
            appDelegate.debugResetTerminationForTesting()
            appDelegate.debugSessionSnapshotSaverForTesting = nil
            appDelegate.debugQuitSaveFailureAlertForTesting = nil
            QuitWarningSettings.setEnabled(warningWasEnabled)
            _ = appDelegate.closeMainWindow(windowId: windowId)
            manager.teardownForWindowClose()
        }
        appDelegate.registerMainWindow(
            window, windowId: windowId, tabManager: manager,
            sidebarState: SidebarState(), sidebarSelectionState: SidebarSelectionState()
        )

        var saveAttempts = 0
        var failureAlerts = 0
        appDelegate.debugSessionSnapshotSaverForTesting = { _ in
            saveAttempts += 1
            return saveAttempts > 1
        }
        appDelegate.debugQuitSaveFailureAlertForTesting = { failureAlerts += 1 }

        XCTAssertEqual(appDelegate.applicationShouldTerminate(NSApp), .terminateCancel)
        XCTAssertEqual(saveAttempts, 1)
        XCTAssertEqual(failureAlerts, 1)
        XCTAssertFalse(SessionMachineryGate.isApplicationTerminating)
        XCTAssertTrue(appDelegate.tabManagerFor(windowId: windowId) === manager)
        XCTAssertFalse(manager.selectedWorkspace?.panels.isEmpty ?? true)

        XCTAssertEqual(appDelegate.applicationShouldTerminate(NSApp), .terminateNow)
        XCTAssertEqual(saveAttempts, 2)
        XCTAssertTrue(SessionMachineryGate.isApplicationTerminating)
    }

    func testWindowlessQuitDoesNotRequireAStoredSnapshot() throws {
        let appDelegate = try XCTUnwrap(AppDelegate.shared)
        closeAllMainWindows()
        let warningWasEnabled = QuitWarningSettings.isEnabled()
        QuitWarningSettings.setEnabled(false)
        defer {
            appDelegate.debugResetTerminationForTesting()
            appDelegate.debugSessionSnapshotSaverForTesting = nil
            appDelegate.debugQuitSaveFailureAlertForTesting = nil
            QuitWarningSettings.setEnabled(warningWasEnabled)
        }
        var failureAlerts = 0
        appDelegate.debugQuitSaveFailureAlertForTesting = { failureAlerts += 1 }
        appDelegate.debugSessionSnapshotSaverForTesting = { _ in
            XCTFail("An empty app must not attempt a snapshot write")
            return false
        }

        XCTAssertEqual(appDelegate.applicationShouldTerminate(NSApp), .terminateNow)
        XCTAssertEqual(failureAlerts, 0)
    }
#endif

    func testConcurrentDuplicateRequestGenerationsCannotOverwriteOrDeleteEachOther() throws {
        let rootDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "programa-single-instance-ownership-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: rootDirectory) }

        let target = ProgramaSingleInstanceProcessKey(
            startSeconds: 1_000,
            startMicroseconds: 100,
            processIdentifier: 100
        )
        let firstGeneration = UUID()
        let secondGeneration = UUID()
        let firstURL = AppDelegate.duplicateRequestURLForTesting(
            rootDirectory: rootDirectory,
            target: target,
            generation: firstGeneration
        )
        let secondURL = AppDelegate.duplicateRequestURLForTesting(
            rootDirectory: rootDirectory,
            target: target,
            generation: secondGeneration
        )

        try Data("first".utf8).write(to: firstURL, options: .atomic)
        try Data("second".utf8).write(to: secondURL, options: .atomic)

        XCTAssertNotEqual(firstURL, secondURL)
        XCTAssertEqual(try Data(contentsOf: firstURL), Data("first".utf8))
        XCTAssertEqual(try Data(contentsOf: secondURL), Data("second".utf8))

        try FileManager.default.removeItem(at: firstURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondURL.path))
    }

    func testThreeConcurrentShutdownGenerationsOwnRequestFilesAndShareTargetAcknowledgment() throws {
        let rootDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "programa-single-instance-three-generations-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: rootDirectory) }

        let target = ProgramaSingleInstanceProcessKey(
            startSeconds: 1_000,
            startMicroseconds: 100,
            processIdentifier: 100
        )
        let requests = (0..<3).map { index in
            AppDelegate.SingleInstanceShutdownRequest(
                generation: UUID(),
                target: target,
                requester: ProgramaSingleInstanceProcessKey(
                    startSeconds: 1_001,
                    startMicroseconds: Int64(index),
                    processIdentifier: pid_t(200 + index)
                ),
                createdAtUnixSeconds: 10_000
            )
        }
        var requestURLs: [URL] = []
        var acknowledgmentURLs: [URL] = []
        for request in requests {
            requestURLs.append(try XCTUnwrap(AppDelegate.writeDuplicateRequestForTesting(
                rootDirectory: rootDirectory,
                request: request
            )))
            let acknowledgmentURL = AppDelegate.duplicateAcknowledgmentURLForTesting(
                rootDirectory: rootDirectory,
                target: target,
                generation: request.generation
            )
            let acknowledgment = AppDelegate.SingleInstanceShutdownAcknowledgment(
                acceptedGeneration: request.generation,
                target: target,
                createdAtUnixSeconds: 10_001
            )
            try JSONEncoder().encode(acknowledgment).write(to: acknowledgmentURL, options: .atomic)
            acknowledgmentURLs.append(acknowledgmentURL)
        }

        XCTAssertEqual(Set(requestURLs).count, 3)
        XCTAssertEqual(Set(acknowledgmentURLs).count, 1)
        XCTAssertTrue(AppDelegate.removeDuplicateStateForTesting(
            rootDirectory: rootDirectory,
            request: requests[0]
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: requestURLs[0].path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: acknowledgmentURLs[0].path))
        for index in 1..<3 {
            XCTAssertTrue(FileManager.default.fileExists(atPath: requestURLs[index].path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: acknowledgmentURLs[index].path))
        }
    }

    func testDuplicateAcknowledgmentRequiresExactTargetAndTimingButNotGeneration() {
        let target = ProgramaSingleInstanceProcessKey(
            startSeconds: 1_000,
            startMicroseconds: 100,
            processIdentifier: 100
        )
        let requester = ProgramaSingleInstanceProcessKey(
            startSeconds: 1_001,
            startMicroseconds: 0,
            processIdentifier: 200
        )
        let request = AppDelegate.SingleInstanceShutdownRequest(
            generation: UUID(),
            target: target,
            requester: requester,
            createdAtUnixSeconds: 10_000
        )
        let valid = AppDelegate.SingleInstanceShutdownAcknowledgment(
            acceptedGeneration: request.generation,
            target: target,
            createdAtUnixSeconds: 10_001
        )
        let wrongTarget = AppDelegate.SingleInstanceShutdownAcknowledgment(
            acceptedGeneration: request.generation,
            target: requester,
            createdAtUnixSeconds: 10_001
        )
        let wrongGeneration = AppDelegate.SingleInstanceShutdownAcknowledgment(
            acceptedGeneration: UUID(),
            target: target,
            createdAtUnixSeconds: 10_001
        )
        let beforeRequest = AppDelegate.SingleInstanceShutdownAcknowledgment(
            acceptedGeneration: request.generation,
            target: target,
            createdAtUnixSeconds: 9_999
        )
        let tooLate = AppDelegate.SingleInstanceShutdownAcknowledgment(
            acceptedGeneration: request.generation,
            target: target,
            createdAtUnixSeconds: 10_011
        )
        let future = AppDelegate.SingleInstanceShutdownAcknowledgment(
            acceptedGeneration: request.generation,
            target: target,
            createdAtUnixSeconds: 10_004
        )

        XCTAssertTrue(AppDelegate.shouldAcceptDuplicateShutdownAcknowledgmentForTesting(
            valid,
            expectedRequest: request,
            now: 10_002
        ))
        for accepted in [wrongGeneration, beforeRequest] {
            XCTAssertTrue(AppDelegate.shouldAcceptDuplicateShutdownAcknowledgmentForTesting(
                accepted,
                expectedRequest: request,
                now: 10_002
            ))
        }
        for invalid in [wrongTarget, tooLate, future] {
            XCTAssertFalse(AppDelegate.shouldAcceptDuplicateShutdownAcknowledgmentForTesting(
                invalid,
                expectedRequest: request,
                now: 10_002
            ))
        }
    }

    func testFailedQuitCanRevokeOnlyItsOwnAcknowledgmentGeneration() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = ProgramaSingleInstanceProcessKey(
            startSeconds: 1_000, startMicroseconds: 1, processIdentifier: 100
        )
        let request = AppDelegate.SingleInstanceShutdownRequest(
            target: target,
            requester: ProgramaSingleInstanceProcessKey(
                startSeconds: 1_001, startMicroseconds: 1, processIdentifier: 200
            ),
            createdAtUnixSeconds: 10_000
        )
        let requestURL = try XCTUnwrap(AppDelegate.writeDuplicateRequestForTesting(
            rootDirectory: directory, request: request
        ))
        let acknowledgmentURL = AppDelegate.duplicateAcknowledgmentURLForTesting(
            rootDirectory: directory, target: target, generation: request.generation
        )
        let acknowledgment = AppDelegate.SingleInstanceShutdownAcknowledgment(
            acceptedGeneration: request.generation, target: target, createdAtUnixSeconds: 10_001
        )
        try JSONEncoder().encode(acknowledgment).write(to: acknowledgmentURL, options: .atomic)

        XCTAssertFalse(AppDelegate.removeExactAcknowledgment(
            target: target, acceptedGeneration: UUID(), url: acknowledgmentURL
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: acknowledgmentURL.path))
        XCTAssertTrue(AppDelegate.removeExactAcknowledgment(
            target: target, acceptedGeneration: request.generation, url: acknowledgmentURL
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: acknowledgmentURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: requestURL.path))
        XCTAssertFalse(AppDelegate.hasValidDuplicateAcknowledgmentForTesting(
            rootDirectory: directory, request: request, now: 10_002
        ))
        XCTAssertEqual(AppDelegate.duplicateFallbackActionForTesting(
            hasValidTargetAcknowledgment: false,
            requestGenerationIsPending: true,
            processIdentityMatches: true,
            isTerminated: false,
            response: nil
        ), .prompt)
    }

    func testStartupHandoffWaitsForEveryAuthenticatedOlderProcessToExit() {
        let first = ProgramaSingleInstanceProcessKey(
            startSeconds: 1_000, startMicroseconds: 1, processIdentifier: 100
        )
        let second = ProgramaSingleInstanceProcessKey(
            startSeconds: 1_001, startMicroseconds: 1, processIdentifier: 200
        )
        var firstLive = true
        var secondLive = true
        var readyCount = 0
        let handoff = StartupSessionHandoff(
            olderProcess: { firstLive ? first : (secondLive ? second : nil) },
            isLive: { key in key == first ? firstLive : secondLive },
            onReady: { readyCount += 1 }
        )

        XCTAssertTrue(handoff.shouldDefer())
        firstLive = false
        handoff.poll()
        XCTAssertTrue(handoff.isWaiting)
        XCTAssertEqual(readyCount, 0)
        secondLive = false
        handoff.poll()
        XCTAssertFalse(handoff.isWaiting)
        XCTAssertFalse(handoff.shouldDefer())
        XCTAssertEqual(readyCount, 1)
    }

    func testStartupHandoffDoesNotReadBeforeInitialArbitration() {
        var olderLookups = 0
        var readyCount = 0
        let handoff = StartupSessionHandoff(
            hasCompletedInitialArbitration: false,
            olderProcess: { olderLookups += 1; return nil },
            isLive: { _ in false },
            onReady: { readyCount += 1 }
        )

        XCTAssertTrue(handoff.shouldDefer())
        XCTAssertEqual(olderLookups, 0)
        handoff.initialArbitrationCompleted()
        XCTAssertFalse(handoff.shouldDefer())
        XCTAssertEqual(olderLookups, 1)
        XCTAssertEqual(readyCount, 1)
    }

    func testDuplicateStateRecoversFromMoreThanScanLimitRecognizedStaleEntries() throws {
        let rootDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "programa-single-instance-stale-cap-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: rootDirectory) }

        let target = ProgramaSingleInstanceProcessKey(
            startSeconds: 1_000,
            startMicroseconds: 100,
            processIdentifier: 100
        )
        for index in 0..<520 {
            let request = AppDelegate.SingleInstanceShutdownRequest(
                generation: UUID(),
                target: target,
                requester: ProgramaSingleInstanceProcessKey(
                    startSeconds: 1_001,
                    startMicroseconds: Int64(index),
                    processIdentifier: pid_t(200 + index)
                ),
                createdAtUnixSeconds: 9_000
            )
            _ = try XCTUnwrap(AppDelegate.writeDuplicateRequestForTesting(
                rootDirectory: rootDirectory,
                request: request
            ))
        }

        XCTAssertTrue(AppDelegate.prepareDuplicateStateForTesting(
            rootDirectory: rootDirectory,
            now: 10_000,
            isProcessLive: { _ in false }
        ))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: rootDirectory.path).count,
            0
        )
    }

    func testDuplicateStateRetainsStaleFilesForExactLiveProcesses() throws {
        let rootDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "programa-single-instance-live-retention-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: rootDirectory) }

        let target = ProgramaSingleInstanceProcessKey(
            startSeconds: 1_000,
            startMicroseconds: 100,
            processIdentifier: 100
        )
        let request = AppDelegate.SingleInstanceShutdownRequest(
            target: target,
            requester: ProgramaSingleInstanceProcessKey(
                startSeconds: 1_001,
                startMicroseconds: 0,
                processIdentifier: 200
            ),
            createdAtUnixSeconds: 9_000
        )
        let requestURL = try XCTUnwrap(AppDelegate.writeDuplicateRequestForTesting(
            rootDirectory: rootDirectory,
            request: request
        ))
        let acknowledgmentURL = AppDelegate.duplicateAcknowledgmentURLForTesting(
            rootDirectory: rootDirectory,
            target: target,
            generation: request.generation
        )
        let acknowledgment = AppDelegate.SingleInstanceShutdownAcknowledgment(
            acceptedGeneration: request.generation,
            target: target,
            createdAtUnixSeconds: 9_001
        )
        try JSONEncoder().encode(acknowledgment).write(to: acknowledgmentURL, options: .atomic)

        XCTAssertTrue(AppDelegate.prepareDuplicateStateForTesting(
            rootDirectory: rootDirectory,
            now: 10_000,
            isProcessLive: { $0 == target || $0 == request.requester }
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: requestURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: acknowledgmentURL.path))
    }

    func testDuplicateStateRefusesMalformedAndSymlinkEntriesWithoutDeletingThem() throws {
        let rootDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "programa-single-instance-unsafe-state-\(UUID().uuidString)",
            isDirectory: true
        )
        let symlinkTarget = FileManager.default.temporaryDirectory.appendingPathComponent(
            "programa-single-instance-symlink-target-\(UUID().uuidString)",
            isDirectory: false
        )
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: false)
        try Data("outside".utf8).write(to: symlinkTarget)
        defer {
            try? FileManager.default.removeItem(at: rootDirectory)
            try? FileManager.default.removeItem(at: symlinkTarget)
        }
        let malformedURL = rootDirectory.appendingPathComponent("request-malformed.json")
        let symlinkURL = rootDirectory.appendingPathComponent("ack-malformed.json")
        try Data("not-json".utf8).write(to: malformedURL)
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: symlinkTarget)

        XCTAssertFalse(AppDelegate.prepareDuplicateStateForTesting(
            rootDirectory: rootDirectory,
            now: 10_000,
            isProcessLive: { _ in false }
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: malformedURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: symlinkURL.path))
        XCTAssertEqual(try Data(contentsOf: symlinkTarget), Data("outside".utf8))
    }

    func testRejectedGracefulTerminationStillSchedulesConsentFallbackForOwnedRequest() {
        XCTAssertTrue(AppDelegate.shouldScheduleDuplicateFallbackForTesting(
            requestWasWritten: true,
            gracefulTerminationAccepted: false
        ))
        XCTAssertFalse(AppDelegate.shouldScheduleDuplicateFallbackForTesting(
            requestWasWritten: false,
            gracefulTerminationAccepted: false
        ))
    }

    func testDuplicateForcePromptDefaultsReturnAndEscapeToCancel() {
        XCTAssertEqual(AppDelegate.duplicateForcePromptResponseForTesting(button: .primary), .cancel)
        XCTAssertEqual(AppDelegate.duplicateForcePromptResponseForTesting(button: .secondary), .forceClose)
        XCTAssertEqual(AppDelegate.duplicateForcePromptResponseForTesting(button: .escape), .cancel)
    }

    func testDuplicateRequesterRequiresMatchingDesignatedSigningIdentity() {
        let releaseIdentity = AppDelegate.SingleInstanceCodeIdentity(
            signingIdentifier: "com.darkroom.programa",
            teamIdentifier: "DARKROOMTEAM"
        )
        XCTAssertTrue(AppDelegate.shouldTrustDuplicateCodeIdentityForTesting(
            current: releaseIdentity,
            candidate: releaseIdentity,
            designatedRequirementMatches: true,
            isDebugBuild: false
        ))
        XCTAssertFalse(AppDelegate.shouldTrustDuplicateCodeIdentityForTesting(
            current: releaseIdentity,
            candidate: AppDelegate.SingleInstanceCodeIdentity(
                signingIdentifier: "com.darkroom.programa",
                teamIdentifier: "SPOOFEDTEAM"
            ),
            designatedRequirementMatches: true,
            isDebugBuild: false
        ))
        XCTAssertFalse(AppDelegate.shouldTrustDuplicateCodeIdentityForTesting(
            current: releaseIdentity,
            candidate: AppDelegate.SingleInstanceCodeIdentity(
                signingIdentifier: "com.example.spoof",
                teamIdentifier: "DARKROOMTEAM"
            ),
            designatedRequirementMatches: true,
            isDebugBuild: false
        ))
        let adHocIdentity = AppDelegate.SingleInstanceCodeIdentity(
            signingIdentifier: "com.darkroom.programa.debug",
            teamIdentifier: nil
        )
        XCTAssertFalse(AppDelegate.shouldTrustDuplicateCodeIdentityForTesting(
            current: adHocIdentity,
            candidate: adHocIdentity,
            designatedRequirementMatches: true,
            isDebugBuild: false
        ))
        XCTAssertTrue(AppDelegate.shouldTrustDuplicateCodeIdentityForTesting(
            current: adHocIdentity,
            candidate: adHocIdentity,
            designatedRequirementMatches: true,
            isDebugBuild: true
        ))
        XCTAssertFalse(AppDelegate.shouldTrustDuplicateCodeIdentityForTesting(
            current: adHocIdentity,
            candidate: adHocIdentity,
            designatedRequirementMatches: false,
            isDebugBuild: true
        ))
    }

    func testDuplicateRequesterRequiresDynamicCodeValidationForUnchangedProcessIdentity() {
        let expected = ProgramaSingleInstanceProcessKey(
            startSeconds: 1_000,
            startMicroseconds: 100,
            processIdentifier: 100
        )
        let replaced = ProgramaSingleInstanceProcessKey(
            startSeconds: 1_001,
            startMicroseconds: 0,
            processIdentifier: 100
        )
        let identity = AppDelegate.SingleInstanceCodeIdentity(
            signingIdentifier: "com.darkroom.programa",
            teamIdentifier: "DARKROOMTEAM"
        )

        XCTAssertFalse(AppDelegate.shouldTrustDuplicateRunningCodeForTesting(
            expectedProcessKey: expected,
            resolvedProcessKeyBeforeValidation: expected,
            resolvedProcessKeyAfterValidation: replaced,
            currentIdentity: identity,
            candidateIdentity: identity,
            dynamicRequirementMatches: true,
            isDebugBuild: false
        ), "A PID whose kernel start key changes during validation must fail closed")
        XCTAssertFalse(AppDelegate.shouldTrustDuplicateRunningCodeForTesting(
            expectedProcessKey: expected,
            resolvedProcessKeyBeforeValidation: expected,
            resolvedProcessKeyAfterValidation: expected,
            currentIdentity: identity,
            candidateIdentity: identity,
            dynamicRequirementMatches: false,
            isDebugBuild: false
        ), "Matching static signing metadata must not replace dynamic running-code validation")
    }

    func testAcceptingOneGenerationAcknowledgesExactTargetForEveryRequester() throws {
        let rootDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "programa-single-instance-shared-ack-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: rootDirectory) }

        let target = ProgramaSingleInstanceProcessKey(
            startSeconds: 1_000,
            startMicroseconds: 100,
            processIdentifier: 100
        )
        let acceptedRequest = AppDelegate.SingleInstanceShutdownRequest(
            generation: UUID(),
            target: target,
            requester: ProgramaSingleInstanceProcessKey(
                startSeconds: 1_001,
                startMicroseconds: 0,
                processIdentifier: 200
            ),
            createdAtUnixSeconds: 10_000
        )
        _ = try XCTUnwrap(AppDelegate.writeDuplicateRequestForTesting(
            rootDirectory: rootDirectory,
            request: acceptedRequest
        ))
        XCTAssertTrue(AppDelegate.publishDuplicateAcknowledgmentForTesting(
            rootDirectory: rootDirectory,
            request: acceptedRequest,
            currentProcessKey: target,
            now: 10_001
        ))

        let lateRequests = (0..<2).map { index in
            AppDelegate.SingleInstanceShutdownRequest(
                generation: UUID(),
                target: target,
                requester: ProgramaSingleInstanceProcessKey(
                    startSeconds: 1_002,
                    startMicroseconds: Int64(index),
                    processIdentifier: pid_t(300 + index)
                ),
                createdAtUnixSeconds: 10_002
            )
        }
        for request in lateRequests {
            _ = try XCTUnwrap(AppDelegate.writeDuplicateRequestForTesting(
                rootDirectory: rootDirectory,
                request: request
            ))
        }

        for request in [acceptedRequest] + lateRequests {
            XCTAssertTrue(
                AppDelegate.hasValidDuplicateAcknowledgmentForTesting(
                    rootDirectory: rootDirectory,
                    request: request,
                    now: 10_003
                ),
                "The target's durable responsive state must defer force-close for existing and later request generations"
            )
            XCTAssertEqual(AppDelegate.duplicateFallbackActionForTesting(
                hasValidTargetAcknowledgment: true,
                requestGenerationIsPending: true,
                processIdentityMatches: true,
                isTerminated: false,
                response: nil
            ), .waitForAcknowledgedExit)
        }
    }

    func testDuplicateTargetFailsClosedWhenAcknowledgmentPublicationFails() throws {
        let rootDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "programa-single-instance-ack-failure-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: rootDirectory) }

        let target = ProgramaSingleInstanceProcessKey(
            startSeconds: 1_000,
            startMicroseconds: 100,
            processIdentifier: 100
        )
        let request = AppDelegate.SingleInstanceShutdownRequest(
            target: target,
            requester: ProgramaSingleInstanceProcessKey(
                startSeconds: 1_001,
                startMicroseconds: 0,
                processIdentifier: 200
            ),
            createdAtUnixSeconds: 10_000
        )

        XCTAssertFalse(AppDelegate.publishDuplicateAcknowledgmentForTesting(
            rootDirectory: rootDirectory,
            request: request,
            currentProcessKey: target,
            now: 10_001,
            allowWrite: false
        ))
        XCTAssertTrue(AppDelegate.shouldWarnBeforeTerminationForTesting(
            isTaggedDevBuild: false,
            isQuitWarningConfirmed: false,
            isInternalSingleInstanceLoserExit: false,
            hasValidatedDuplicateShutdownRequest: false,
            isQuitWarningEnabled: true
        ))
    }

    func testDelayedDuplicateTargetPromptsInsteadOfForcingAutomatically() {
        XCTAssertEqual(AppDelegate.duplicateFallbackActionForTesting(
            hasValidTargetAcknowledgment: false,
            requestGenerationIsPending: true,
            processIdentityMatches: true,
            isTerminated: false,
            response: nil
        ), .prompt)
    }

    func testDuplicateFallbackGraceLeavesRoomBeforeRequestExpiry() {
        XCTAssertEqual(
            AppDelegate.duplicateTerminationGraceIntervalForTesting,
            8,
            accuracy: 0.25
        )
        XCTAssertLessThan(AppDelegate.duplicateTerminationGraceIntervalForTesting, 10)
    }

    func testDuplicateForceRequiresConsentAndCurrentUnacknowledgedGeneration() {
        XCTAssertEqual(AppDelegate.duplicateFallbackActionForTesting(
            hasValidTargetAcknowledgment: false,
            requestGenerationIsPending: true,
            processIdentityMatches: true,
            isTerminated: false,
            response: .forceClose
        ), .force)
        XCTAssertEqual(AppDelegate.duplicateFallbackActionForTesting(
            hasValidTargetAcknowledgment: true,
            requestGenerationIsPending: true,
            processIdentityMatches: true,
            isTerminated: false,
            response: .forceClose
        ), .waitForAcknowledgedExit)
        XCTAssertEqual(AppDelegate.duplicateFallbackActionForTesting(
            hasValidTargetAcknowledgment: false,
            requestGenerationIsPending: false,
            processIdentityMatches: true,
            isTerminated: false,
            response: .forceClose
        ), .skip)
        XCTAssertEqual(AppDelegate.duplicateFallbackActionForTesting(
            hasValidTargetAcknowledgment: false,
            requestGenerationIsPending: true,
            processIdentityMatches: false,
            isTerminated: false,
            response: .forceClose
        ), .skip)
        XCTAssertEqual(AppDelegate.duplicateFallbackActionForTesting(
            hasValidTargetAcknowledgment: false,
            requestGenerationIsPending: true,
            processIdentityMatches: true,
            isTerminated: true,
            response: .forceClose
        ), .skip)
    }

    func testDuplicateForcePromptCancelSelectsCleanNewerProcessExit() {
        XCTAssertEqual(AppDelegate.duplicateFallbackActionForTesting(
            hasValidTargetAcknowledgment: false,
            requestGenerationIsPending: true,
            processIdentityMatches: true,
            isTerminated: false,
            response: .cancel
        ), .exitNewer)
        XCTAssertFalse(AppDelegate.shouldWarnBeforeTerminationForTesting(
            isTaggedDevBuild: false,
            isQuitWarningConfirmed: false,
            isInternalSingleInstanceLoserExit: true,
            hasValidatedDuplicateShutdownRequest: false,
            isQuitWarningEnabled: true
        ))

        let policy = AppDelegate.singleInstanceTerminationPersistencePolicyForTesting(
            isDiscardedDuplicate: true
        )
        XCTAssertFalse(policy.persistPreTerminationSnapshot)
        XCTAssertFalse(policy.persistCleanShutdownSnapshot)
        XCTAssertTrue(
            policy.performProcessLocalTeardown,
            "Discarding the empty newer process must still run its local teardown"
        )

        XCTAssertEqual(
            AppDelegate.singleInstanceTerminationPersistencePolicyForTesting(
                isDiscardedDuplicate: false
            ),
            AppDelegate.SingleInstanceTerminationPersistencePolicy(
                persistPreTerminationSnapshot: true,
                persistCleanShutdownSnapshot: true,
                performProcessLocalTeardown: true
            ),
            "Ordinary and update-driven termination must keep normal persistence and teardown"
        )
    }

    func testDuplicateInstanceCandidateRejectsCurrentProcessAndDifferentBundle() {
        let embeddedCLIURL = URL(
            fileURLWithPath: "/Applications/Programa.app/Contents/Resources/bin/programa"
        )
        let guiURL = URL(fileURLWithPath: "/Applications/Programa.app/Contents/MacOS/Programa")

        XCTAssertFalse(AppDelegate.shouldConsiderDuplicateApplication(
            candidateBundleIdentifier: "com.darkroom.programa",
            candidateProcessIdentifier: 100,
            candidateExecutableURL: guiURL,
            expectedBundleIdentifier: "com.darkroom.programa",
            currentProcessIdentifier: 100,
            embeddedCLIURL: embeddedCLIURL
        ))
        XCTAssertFalse(AppDelegate.shouldConsiderDuplicateApplication(
            candidateBundleIdentifier: "com.example.other",
            candidateProcessIdentifier: 200,
            candidateExecutableURL: guiURL,
            expectedBundleIdentifier: "com.darkroom.programa",
            currentProcessIdentifier: 100,
            embeddedCLIURL: embeddedCLIURL
        ))
    }

    func testSingleInstanceProcessKeyReadsCurrentKernelProcessIdentity() throws {
        let currentPID = getpid()
        let key = try XCTUnwrap(AppDelegate.singleInstanceProcessKey(for: currentPID))

        XCTAssertEqual(key.processIdentifier, currentPID)
        XCTAssertGreaterThan(key.startSeconds, 0, "The current process must have a positive kernel start timestamp")
    }

    func testSingleInstanceProcessKeyRejectsMissingKernelProcessRecord() {
        XCTAssertNil(AppDelegate.singleInstanceProcessKey(for: pid_t.max))
    }

    func testOrphanReconciliationRetainsOneRecoveryWorkspacePerSuccessfulSessionOnly() throws {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let candidates: [(sessionId: String, workingDirectory: String?)] = [
            ("failed-before-first-success", "/tmp/failed-before"),
            ("first-success", "/tmp/first-success"),
            ("failed-between-successes", "/tmp/failed-between"),
            ("second-success", "/tmp/second-success"),
        ]
        let successfulSessionIds: Set<String> = ["first-success", "second-success"]
        var attemptedSessionIds: [String] = []
        var attemptedWorkspaceIds: [UUID] = []
        var attemptedWorkspaceDirectories: [String] = []
        var successfulWorkspaceIds: Set<UUID> = []

        let result = try XCTUnwrap(appDelegate.reconcileOrphanedEscrowedSessions(
            candidates: candidates,
            attemptRecovery: { candidate, workspace in
                attemptedSessionIds.append(candidate.sessionId)
                attemptedWorkspaceIds.append(workspace.id)
                attemptedWorkspaceDirectories.append(workspace.currentDirectory)
                guard successfulSessionIds.contains(candidate.sessionId) else { return false }
                successfulWorkspaceIds.insert(workspace.id)
                return true
            }
        ))
        defer { closeWindow(withId: result.windowId) }

        let manager = try XCTUnwrap(appDelegate.tabManagerFor(windowId: result.windowId))
        XCTAssertEqual(result.recoveredCount, successfulSessionIds.count)
        XCTAssertEqual(
            attemptedSessionIds,
            candidates.map(\.sessionId),
            "Reconciliation must attempt every distinct orphan once and in enumeration order"
        )
        XCTAssertEqual(
            Set(attemptedSessionIds).count,
            attemptedSessionIds.count,
            "A session ID must not be attempted twice during one reconciliation pass"
        )
        guard attemptedWorkspaceIds.count == candidates.count else {
            XCTFail("Reconciliation must attempt all candidates before workspace-identity assertions")
            return
        }
        XCTAssertEqual(
            Set(attemptedWorkspaceIds).count,
            candidates.count,
            "Every orphan must get a fresh candidate workspace so failed-session metadata cannot leak into a later success"
        )
        XCTAssertEqual(
            attemptedWorkspaceDirectories,
            candidates.compactMap(\.workingDirectory),
            "Each recovery attempt must start in its own orphan session's working directory"
        )
        XCTAssertEqual(
            manager.tabs.count,
            successfulSessionIds.count,
            "Failed revive attempts must not leave empty workspaces in a partially successful recovery window"
        )
        XCTAssertEqual(
            Set(manager.tabs.map(\.id)),
            successfulWorkspaceIds,
            "The recovery window must retain exactly the workspaces whose revival succeeded"
        )
        XCTAssertTrue(
            manager.tabs.allSatisfy { !$0.panels.isEmpty },
            "Every retained recovery workspace must contain a recovered panel rather than an empty tab"
        )
    }

    func testOrphanReconciliationRemovesRecoveryWindowWhenEverySessionFails() throws {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let candidates: [(sessionId: String, workingDirectory: String?)] = [
            (sessionId: "first-failure", workingDirectory: "/tmp/first-failure"),
            (sessionId: "second-failure", workingDirectory: "/tmp/second-failure"),
        ]
        var attemptedSessionIds: [String] = []
        var attemptedWorkspaceIds: [UUID] = []
        let result = try XCTUnwrap(appDelegate.reconcileOrphanedEscrowedSessions(
            candidates: candidates,
            attemptRecovery: { candidate, workspace in
                attemptedSessionIds.append(candidate.sessionId)
                attemptedWorkspaceIds.append(workspace.id)
                return false
            }
        ))

        XCTAssertEqual(result.recoveredCount, 0)
        XCTAssertEqual(
            attemptedSessionIds,
            candidates.map(\.sessionId),
            "Even an all-fail pass must attempt each distinct orphan exactly once"
        )
        XCTAssertEqual(
            Set(attemptedWorkspaceIds).count,
            candidates.count,
            "Every failed orphan must get a distinct candidate workspace before that workspace is removed"
        )
        waitUntil(description: "all-fail recovery window context to be removed") {
            appDelegate.tabManagerFor(windowId: result.windowId) == nil
        }
        XCTAssertNil(
            appDelegate.tabManagerFor(windowId: result.windowId),
            "An all-fail reconciliation pass must close the recovery window and unregister its context"
        )
        XCTAssertFalse(
            window(withId: result.windowId)?.isVisible == true,
            "An all-fail reconciliation pass must not leave an empty recovery window visible"
        )
    }

    func testCmdNUsesEventWindowContextWhenActiveManagerIsStale() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let firstWindowId = appDelegate.createMainWindow()
        let secondWindowId = appDelegate.createMainWindow()

        defer {
            closeWindow(withId: firstWindowId)
            closeWindow(withId: secondWindowId)
        }

        guard let firstManager = appDelegate.tabManagerFor(windowId: firstWindowId),
              let secondManager = appDelegate.tabManagerFor(windowId: secondWindowId),
              let secondWindow = window(withId: secondWindowId) else {
            XCTFail("Expected both window contexts to exist")
            return
        }

        let firstCount = firstManager.tabs.count
        let secondCount = secondManager.tabs.count

        XCTAssertTrue(appDelegate.focusMainWindow(windowId: firstWindowId))

        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: secondWindow.windowNumber,
            context: nil,
            characters: "n",
            charactersIgnoringModifiers: "n",
            isARepeat: false,
            keyCode: 45
        ) else {
            XCTFail("Failed to construct Cmd+N event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        XCTAssertEqual(firstManager.tabs.count, firstCount, "Cmd+N should not add workspace to stale active window")
        XCTAssertEqual(secondManager.tabs.count, secondCount + 1, "Cmd+N should add workspace to the event's window")
    }

    func testChordedNewWorkspaceShortcutConsumesPrefixAndTriggersOnSecondKey() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId),
              let manager = appDelegate.tabManagerFor(windowId: windowId) else {
            XCTFail("Expected test window and manager")
            return
        }

        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        let initialCount = manager.tabs.count
        let shortcut = StoredShortcut(
            key: "b",
            command: false,
            shift: false,
            option: false,
            control: true,
            chordKey: "n"
        )

        withTemporaryShortcut(action: .newTab, shortcut: shortcut) {
            guard let prefixEvent = makeKeyDownEvent(
                key: "b",
                modifiers: [.control],
                keyCode: 11,
                windowNumber: window.windowNumber
            ) else {
                XCTFail("Failed to construct Ctrl+B prefix event")
                return
            }

            guard let actionEvent = makeKeyDownEvent(
                key: "n",
                modifiers: [],
                keyCode: 45,
                windowNumber: window.windowNumber
            ) else {
                XCTFail("Failed to construct N action event")
                return
            }

#if DEBUG
            XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: prefixEvent))
#else
            XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
            XCTAssertEqual(manager.tabs.count, initialCount, "Chord prefix must not fire the action early")

#if DEBUG
            XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: actionEvent))
#else
            XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
        }

        waitUntil(description: "chord to dispatch the configured shortcut") { manager.tabs.count == initialCount + 1 }
        XCTAssertEqual(manager.tabs.count, initialCount + 1, "Chord second key should dispatch the configured shortcut")
    }

    func testSettingsFileChordDispatchesNewWorkspaceShortcut() throws {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId),
              let manager = appDelegate.tabManagerFor(windowId: windowId) else {
            XCTFail("Expected test window and tab manager")
            return
        }

        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("settings.json", isDirectory: false)
        try """
        {
          "shortcuts": {
            "newTab": ["ctrl+b", "n"]
          }
        }
        """.write(to: settingsFileURL, atomically: true, encoding: .utf8)

        KeyboardShortcutSettings.settingsFileStore = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        let initialCount = manager.tabs.count

        guard let prefixEvent = makeKeyDownEvent(
            key: "b",
            modifiers: [.control],
            keyCode: 11,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Ctrl+B prefix event")
            return
        }

        guard let actionEvent = makeKeyDownEvent(
            key: "n",
            modifiers: [],
            keyCode: 45,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct N action event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: prefixEvent))
        XCTAssertEqual(manager.tabs.count, initialCount, "Chord prefix must not fire the action early")
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: actionEvent))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        waitUntil(description: "settings.json chord to dispatch the configured shortcut") { manager.tabs.count == initialCount + 1 }
        XCTAssertEqual(manager.tabs.count, initialCount + 1, "settings.json chord should dispatch the configured shortcut")
    }

    func testConfiguredChordPrefixIsClearedWhenAppResignsActive() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId),
              let manager = appDelegate.tabManagerFor(windowId: windowId) else {
            XCTFail("Expected test window and manager")
            return
        }

        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        let initialCount = manager.tabs.count
        let shortcut = StoredShortcut(
            key: "b",
            command: false,
            shift: false,
            option: false,
            control: true,
            chordKey: "n"
        )

        withTemporaryShortcut(action: .newTab, shortcut: shortcut) {
            guard let prefixEvent = makeKeyDownEvent(
                key: "b",
                modifiers: [.control],
                keyCode: 11,
                windowNumber: window.windowNumber
            ) else {
                XCTFail("Failed to construct Ctrl+B prefix event")
                return
            }

            guard let actionEvent = makeKeyDownEvent(
                key: "n",
                modifiers: [],
                keyCode: 45,
                windowNumber: window.windowNumber
            ) else {
                XCTFail("Failed to construct N action event")
                return
            }

#if DEBUG
            XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: prefixEvent))
            appDelegate.applicationWillResignActive(Notification(name: NSApplication.willResignActiveNotification))
            XCTAssertFalse(appDelegate.debugHandleCustomShortcut(event: actionEvent))
#else
            XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
        }

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(manager.tabs.count, initialCount, "Chord suffix should not fire after the app resigns active")
    }

    func testConfiguredChordPrefixBeatsConflictingSingleStrokeShortcut() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer {
            SettingsWindowController.shared.close()
            closeWindow(withId: windowId)
        }

        guard let window = window(withId: windowId),
              let manager = appDelegate.tabManagerFor(windowId: windowId) else {
            XCTFail("Expected test window and manager")
            return
        }

        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        let initialCount = manager.tabs.count
        let shortcut = StoredShortcut(
            key: ",",
            command: true,
            shift: false,
            option: false,
            control: false,
            chordKey: "n"
        )

        withTemporaryShortcut(action: .newTab, shortcut: shortcut) {
            guard let prefixEvent = makeKeyDownEvent(
                key: ",",
                modifiers: [.command],
                keyCode: 43,
                windowNumber: window.windowNumber
            ) else {
                XCTFail("Failed to construct Cmd+, prefix event")
                return
            }

            guard let actionEvent = makeKeyDownEvent(
                key: "n",
                modifiers: [],
                keyCode: 45,
                windowNumber: window.windowNumber
            ) else {
                XCTFail("Failed to construct N action event")
                return
            }

#if DEBUG
            XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: prefixEvent))
            XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: actionEvent))
#else
            XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
        }

        waitUntil(description: "chord prefix to arm and dispatch newTab instead of firing Settings") { manager.tabs.count == initialCount + 1 }
        XCTAssertEqual(manager.tabs.count, initialCount + 1, "Chord prefix should arm instead of firing Settings")
    }

    func testConfiguredChordPrefixBlocksUnrelatedSingleStrokeShortcutOnSecondKey() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId),
              let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace else {
            XCTFail("Expected test window and workspace")
            return
        }

        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        let initialWorkspaceCount = manager.tabs.count
        let initialPanelCount = workspace.panels.count
        let shortcut = StoredShortcut(
            key: "b",
            command: false,
            shift: false,
            option: false,
            control: true,
            chordKey: "d"
        )

        withTemporaryShortcut(action: .splitRight, shortcut: shortcut) {
            guard let prefixEvent = makeKeyDownEvent(
                key: "b",
                modifiers: [.control],
                keyCode: 11,
                windowNumber: window.windowNumber
            ) else {
                XCTFail("Failed to construct Ctrl+B prefix event")
                return
            }

            guard let conflictingSingleStrokeEvent = makeKeyDownEvent(
                key: "n",
                modifiers: [.command],
                keyCode: 45,
                windowNumber: window.windowNumber
            ) else {
                XCTFail("Failed to construct Cmd+N event")
                return
            }

#if DEBUG
            XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: prefixEvent))
            XCTAssertFalse(appDelegate.debugHandleCustomShortcut(event: conflictingSingleStrokeEvent))
#else
            XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
        }

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(manager.tabs.count, initialWorkspaceCount, "Pending chord should block unrelated single-stroke actions")
        XCTAssertEqual(workspace.panels.count, initialPanelCount, "Mismatched second key should not split the workspace")
    }

    func testConfiguredChordDoesNotCrossWindowBoundary() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let firstWindowId = appDelegate.createMainWindow()
        let secondWindowId = appDelegate.createMainWindow()
        defer {
            closeWindow(withId: firstWindowId)
            closeWindow(withId: secondWindowId)
        }

        guard let firstWindow = window(withId: firstWindowId),
              let secondWindow = window(withId: secondWindowId),
              let firstManager = appDelegate.tabManagerFor(windowId: firstWindowId),
              let secondManager = appDelegate.tabManagerFor(windowId: secondWindowId) else {
            XCTFail("Expected both test windows and managers")
            return
        }

        firstWindow.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        let initialFirstCount = firstManager.tabs.count
        let initialSecondCount = secondManager.tabs.count
        let shortcut = StoredShortcut(
            key: "b",
            command: false,
            shift: false,
            option: false,
            control: true,
            chordKey: "n"
        )

        withTemporaryShortcut(action: .newTab, shortcut: shortcut) {
            guard let prefixEvent = makeKeyDownEvent(
                key: "b",
                modifiers: [.control],
                keyCode: 11,
                windowNumber: firstWindow.windowNumber
            ) else {
                XCTFail("Failed to construct Ctrl+B prefix event")
                return
            }

            guard let actionEvent = makeKeyDownEvent(
                key: "n",
                modifiers: [],
                keyCode: 45,
                windowNumber: secondWindow.windowNumber
            ) else {
                XCTFail("Failed to construct N action event")
                return
            }

#if DEBUG
            XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: prefixEvent))
            XCTAssertFalse(appDelegate.debugHandleCustomShortcut(event: actionEvent))
#else
            XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
        }

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(firstManager.tabs.count, initialFirstCount, "Prefix window should not change without a matching suffix")
        XCTAssertEqual(secondManager.tabs.count, initialSecondCount, "Chord suffix in another window must not trigger the action")
    }

    func testShortcutChangeClearsPendingConfiguredChord() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId),
              let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace else {
            XCTFail("Expected test window and workspace")
            return
        }

        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        let initialPanelCount = workspace.panels.count
        let chordShortcut = StoredShortcut(
            key: "b",
            command: false,
            shift: false,
            option: false,
            control: true,
            chordKey: "d"
        )

        withTemporaryShortcut(action: .splitRight, shortcut: chordShortcut) {
            guard let prefixEvent = makeKeyDownEvent(
                key: "b",
                modifiers: [.control],
                keyCode: 11,
                windowNumber: window.windowNumber
            ) else {
                XCTFail("Failed to construct Ctrl+B prefix event")
                return
            }

            guard let suffixEvent = makeKeyDownEvent(
                key: "d",
                modifiers: [],
                keyCode: 2,
                windowNumber: window.windowNumber
            ) else {
                XCTFail("Failed to construct D suffix event")
                return
            }

#if DEBUG
            XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: prefixEvent))
#else
            XCTFail("debugHandleCustomShortcut is only available in DEBUG")
            return
#endif

            KeyboardShortcutSettings.setShortcut(
                StoredShortcut(key: "d", command: true, shift: false, option: false, control: false),
                for: .splitRight
            )
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

#if DEBUG
            XCTAssertFalse(appDelegate.debugHandleCustomShortcut(event: suffixEvent))
#endif
        }

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(workspace.panels.count, initialPanelCount, "Changing shortcuts should discard any pending chord prefix")
    }

    func testChordedShortcutMismatchDoesNotConsumeSecondKey() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId),
              let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace else {
            XCTFail("Expected test window and workspace")
            return
        }

        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        let initialPanelCount = workspace.panels.count
        let shortcut = StoredShortcut(
            key: "b",
            command: false,
            shift: false,
            option: false,
            control: true,
            chordKey: "d"
        )

        withTemporaryShortcut(action: .splitRight, shortcut: shortcut) {
            guard let prefixEvent = makeKeyDownEvent(
                key: "b",
                modifiers: [.control],
                keyCode: 11,
                windowNumber: window.windowNumber
            ) else {
                XCTFail("Failed to construct Ctrl+B prefix event")
                return
            }

            guard let mismatchEvent = makeKeyDownEvent(
                key: "x",
                modifiers: [],
                keyCode: 7,
                windowNumber: window.windowNumber
            ) else {
                XCTFail("Failed to construct mismatch event")
                return
            }

#if DEBUG
            XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: prefixEvent))
            XCTAssertFalse(appDelegate.debugHandleCustomShortcut(event: mismatchEvent))
#else
            XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
        }

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(workspace.panels.count, initialPanelCount, "Unmatched chord suffix must not trigger the action")
    }

    func testCreateMainWindowDoesNotDisallowFullScreenTilingByDefault() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer {
            closeWindow(withId: windowId)
        }

        guard let window = window(withId: windowId) else {
            XCTFail("Expected test window")
            return
        }

        XCTAssertFalse(
            window.collectionBehavior.contains(.fullScreenDisallowsTiling),
            "Main windows should still support standard macOS Split View when not created from a fullscreen source"
        )
    }

    func testCreateMainWindowTemporarilyDisallowsFullScreenTilingFromFullscreenSource() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        appDelegate.debugCreateMainWindowSourceIsNativeFullScreenOverride = true

        let newWindowId = appDelegate.createMainWindow()
        defer {
            closeWindow(withId: newWindowId)
        }

        guard let newWindow = window(withId: newWindowId) else {
            XCTFail("Expected new window")
            return
        }

        XCTAssertTrue(
            newWindow.collectionBehavior.contains(.fullScreenDisallowsTiling),
            "New windows should temporarily opt out of fullscreen tiling while opening from a fullscreen source"
        )

        appDelegate.debugCreateMainWindowSourceIsNativeFullScreenOverride = nil

        // The opt-out is cleared by a `DispatchQueue.main.async` scheduled during window
        // creation. That normally runs within microseconds of the next run-loop turn, but
        // a single fixed 0.05s spin is occasionally too short under CPU contention (e.g.
        // concurrent test/build activity), causing rare flakes. Poll instead of assuming
        // one spin is enough.
        let deadline = Date(timeIntervalSinceNow: 2.0)
        while newWindow.collectionBehavior.contains(.fullScreenDisallowsTiling), Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }

        XCTAssertFalse(
            newWindow.collectionBehavior.contains(.fullScreenDisallowsTiling),
            "The fullscreen tiling opt-out should be cleared after initial presentation so Split View keeps working"
        )
    }

    func testAddWorkspaceInPreferredMainWindowIgnoresStaleTabManagerPointer() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let firstWindowId = appDelegate.createMainWindow()
        let secondWindowId = appDelegate.createMainWindow()

        defer {
            closeWindow(withId: firstWindowId)
            closeWindow(withId: secondWindowId)
        }

        guard let firstManager = appDelegate.tabManagerFor(windowId: firstWindowId),
              let secondManager = appDelegate.tabManagerFor(windowId: secondWindowId),
              let secondWindow = window(withId: secondWindowId) else {
            XCTFail("Expected both window contexts to exist")
            return
        }

        let firstCount = firstManager.tabs.count
        let secondCount = secondManager.tabs.count

        // Activating the app (not just ordering the window front) is required for
        // NSApp.keyWindow to reliably reflect secondWindow when the test host process
        // isn't already the foreground app.
        NSApp.activate(ignoringOtherApps: true)
        secondWindow.makeKeyAndOrderFront(nil)
        waitUntil(description: "secondWindow to become NSApp.keyWindow") { NSApp.keyWindow === secondWindow }

        // Force a stale app-level pointer to a different manager.
        appDelegate.tabManager = firstManager
        XCTAssertTrue(appDelegate.tabManager === firstManager)

        _ = appDelegate.addWorkspaceInPreferredMainWindow()

        XCTAssertEqual(firstManager.tabs.count, firstCount, "Stale pointer must not receive menu-driven workspace creation")
        XCTAssertEqual(secondManager.tabs.count, secondCount + 1, "Workspace creation should target key/main window context")
    }

    func testCmdNResolvesEventWindowWhenObjectKeyLookupIsMismatched() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let firstWindowId = appDelegate.createMainWindow()
        let secondWindowId = appDelegate.createMainWindow()

        defer {
            closeWindow(withId: firstWindowId)
            closeWindow(withId: secondWindowId)
        }

        guard let firstManager = appDelegate.tabManagerFor(windowId: firstWindowId),
              let secondManager = appDelegate.tabManagerFor(windowId: secondWindowId),
              let secondWindow = window(withId: secondWindowId) else {
            XCTFail("Expected both window contexts to exist")
            return
        }

        secondWindow.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

#if DEBUG
        XCTAssertTrue(appDelegate.debugInjectWindowContextKeyMismatch(windowId: secondWindowId))
#else
        XCTFail("debugInjectWindowContextKeyMismatch is only available in DEBUG")
#endif

        // Ensure stale active-manager pointer does not mask routing errors.
        appDelegate.tabManager = firstManager

        let firstCount = firstManager.tabs.count
        let secondCount = secondManager.tabs.count

        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: secondWindow.windowNumber,
            context: nil,
            characters: "n",
            charactersIgnoringModifiers: "n",
            isARepeat: false,
            keyCode: 45
        ) else {
            XCTFail("Failed to construct Cmd+N event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        XCTAssertEqual(firstManager.tabs.count, firstCount, "Cmd+N should not route to another window when object-key lookup misses")
        XCTAssertEqual(secondManager.tabs.count, secondCount + 1, "Cmd+N should still route by event window metadata when object-key lookup misses")
    }

    func testDockMenuNewWindowItemCreatesMainWindow() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let existingWindowId = appDelegate.createMainWindow()
        var createdWindowId: UUID?
        defer {
            if let createdWindowId {
                closeWindow(withId: createdWindowId)
            }
            closeWindow(withId: existingWindowId)
        }

        let existingWindowIds = mainWindowIds()

        let delegate: NSApplicationDelegate = appDelegate
        guard let dockMenu = delegate.applicationDockMenu?(NSApp) else {
            XCTFail("Expected Dock menu")
            return
        }

        let expectedTitle = String(localized: "menu.file.newWindow", defaultValue: "New Window")
        guard let item = dockMenu.items.first(where: { $0.action == #selector(AppDelegate.openNewMainWindow(_:)) }) else {
            XCTFail("Expected New Window item in Dock menu")
            return
        }

        XCTAssertEqual(item.title, expectedTitle)
        XCTAssertTrue(NSApp.sendAction(#selector(AppDelegate.openNewMainWindow(_:)), to: item.target, from: item))
        waitUntil(description: "Dock menu New Window to create a main window") {
            mainWindowIds().subtracting(existingWindowIds).count == 1
        }

        let newWindowIds = mainWindowIds().subtracting(existingWindowIds)
        XCTAssertEqual(newWindowIds.count, 1, "Dock menu New Window should create one main window")
        createdWindowId = newWindowIds.first
    }

    func testAddWorkspaceInPreferredMainWindowUsesKeyWindowWhenObjectKeyLookupIsMismatched() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let firstWindowId = appDelegate.createMainWindow()
        let secondWindowId = appDelegate.createMainWindow()

        defer {
            closeWindow(withId: firstWindowId)
            closeWindow(withId: secondWindowId)
        }

        guard let firstManager = appDelegate.tabManagerFor(windowId: firstWindowId),
              let secondManager = appDelegate.tabManagerFor(windowId: secondWindowId),
              let secondWindow = window(withId: secondWindowId) else {
            XCTFail("Expected both window contexts to exist")
            return
        }

        // Activating the app (not just ordering the window front) is required for
        // NSApp.keyWindow to reliably reflect secondWindow when the test host process
        // isn't already the foreground app.
        NSApp.activate(ignoringOtherApps: true)
        secondWindow.makeKeyAndOrderFront(nil)
        waitUntil(description: "secondWindow to become NSApp.keyWindow") { NSApp.keyWindow === secondWindow }

#if DEBUG
        XCTAssertTrue(appDelegate.debugInjectWindowContextKeyMismatch(windowId: secondWindowId))
#else
        XCTFail("debugInjectWindowContextKeyMismatch is only available in DEBUG")
#endif

        // Stale pointer should not receive the new workspace.
        appDelegate.tabManager = firstManager

        let firstCount = firstManager.tabs.count
        let secondCount = secondManager.tabs.count

        _ = appDelegate.addWorkspaceInPreferredMainWindow()

        XCTAssertEqual(firstManager.tabs.count, firstCount, "Menu-driven add workspace should not route to stale window")
        XCTAssertEqual(secondManager.tabs.count, secondCount + 1, "Menu-driven add workspace should still route to key window context when object-key lookup misses")
    }

    func testAddWorkspaceInPreferredMainWindowPrunesOrphanedContextWithoutLiveWindow() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        // The app's own default WindowGroup window would otherwise always be a live,
        // eligible fallback target and defeat this test's "no live window" precondition.
        // Explicit disposal removes it rather than preserving a hidden session.
        closeAllMainWindows()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        let orphanWindowId = UUID()
        let orphanManager = TabManager()
        let orphanSidebarState = SidebarState()
        let orphanSidebarSelectionState = SidebarSelectionState()

        autoreleasepool {
            var orphanWindow: NSWindow? = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            orphanWindow?.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(orphanWindowId.uuidString)")
            appDelegate.registerMainWindow(
                orphanWindow!,
                windowId: orphanWindowId,
                tabManager: orphanManager,
                sidebarState: orphanSidebarState,
                sidebarSelectionState: orphanSidebarSelectionState
            )
            orphanWindow = nil
        }

        waitUntil(description: "orphaned window to finish deallocating") {
            appDelegate.mainWindow(for: orphanWindowId) == nil
        }

        XCTAssertNil(appDelegate.mainWindow(for: orphanWindowId), "Test precondition: orphaned context should not have a live window")

        // NOTE: `closeAllMainWindows()` above is best-effort hygiene, not a guarantee.
        // The app's `WindowGroup` scene (Sources/ProgramaApp.swift) recreates and
        // re-registers a fresh default window synchronously within the window-close
        // sequence itself -- confirmed by instrumenting `registerMainWindow` during
        // investigation, there is no run-loop gap in which the app can be observed
        // with zero live main windows while the WindowGroup scene is running. So
        // `addWorkspaceInPreferredMainWindow()` legitimately succeeds by routing to
        // that real (non-orphan) window here, which is correct production behavior,
        // not a bug. What this test actually needs to prove -- that the orphan is
        // never selected and gets pruned -- is captured by the two assertions below.
        let orphanCount = orphanManager.tabs.count
        _ = appDelegate.addWorkspaceInPreferredMainWindow()
        XCTAssertEqual(orphanManager.tabs.count, orphanCount, "Orphaned manager must not receive a new workspace")
        XCTAssertNil(appDelegate.tabManagerFor(windowId: orphanWindowId), "Orphaned context should be pruned after failed resolution")
    }

    func testCustomCmdTNewWorkspacePrunesOrphanedContextWithoutLiveWindow() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        // The app's own default WindowGroup window would otherwise always be a live,
        // eligible fallback target and defeat this test's "no live window" precondition.
        // Explicit disposal removes it rather than preserving a hidden session.
        closeAllMainWindows()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        let existingWindowIds = mainWindowIds()
        let orphanWindowId = UUID()
        let orphanManager = TabManager()
        let orphanSidebarState = SidebarState()
        let orphanSidebarSelectionState = SidebarSelectionState()

        autoreleasepool {
            var orphanWindow: NSWindow? = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            orphanWindow?.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(orphanWindowId.uuidString)")
            appDelegate.registerMainWindow(
                orphanWindow!,
                windowId: orphanWindowId,
                tabManager: orphanManager,
                sidebarState: orphanSidebarState,
                sidebarSelectionState: orphanSidebarSelectionState
            )
            orphanWindow = nil
        }

        waitUntil(description: "orphaned window to finish deallocating") {
            appDelegate.mainWindow(for: orphanWindowId) == nil
        }

        XCTAssertNil(appDelegate.mainWindow(for: orphanWindowId), "Test precondition: orphaned context should not have a live window")

        let orphanCount = orphanManager.tabs.count
        let remappedCmdT = StoredShortcut(key: "t", command: true, shift: false, option: false, control: false)

        withTemporaryShortcut(action: .newTab, shortcut: remappedCmdT) {
            guard let event = makeKeyDownEvent(
                key: "t",
                modifiers: [.command],
                keyCode: 17, // kVK_ANSI_T
                windowNumber: 0
            ) else {
                XCTFail("Failed to construct remapped Cmd+T event")
                return
            }

#if DEBUG
            XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
            XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
            waitUntil(description: "orphaned context to be pruned after failed resolution") {
                appDelegate.tabManagerFor(windowId: orphanWindowId) == nil
            }
        }

        XCTAssertEqual(orphanManager.tabs.count, orphanCount, "Orphaned manager must not receive a new workspace from remapped Cmd+T")
        XCTAssertNil(appDelegate.tabManagerFor(windowId: orphanWindowId), "Remapped Cmd+T should prune the orphaned context after failed resolution")

        let createdWindowIds = mainWindowIds().subtracting(existingWindowIds)
        for windowId in createdWindowIds {
            closeWindow(withId: windowId)
        }
    }

    func testCmdDigitRoutesToEventWindowWhenActiveManagerIsStale() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let firstWindowId = appDelegate.createMainWindow()
        let secondWindowId = appDelegate.createMainWindow()

        defer {
            closeWindow(withId: firstWindowId)
            closeWindow(withId: secondWindowId)
        }

        guard let firstManager = appDelegate.tabManagerFor(windowId: firstWindowId),
              let secondManager = appDelegate.tabManagerFor(windowId: secondWindowId),
              let secondWindow = window(withId: secondWindowId) else {
            XCTFail("Expected both window contexts to exist")
            return
        }

        _ = firstManager.addTab(select: true)
        _ = secondManager.addTab(select: true)

        guard let firstSelectedBefore = firstManager.selectedTabId,
              let secondSelectedBefore = secondManager.selectedTabId else {
            XCTFail("Expected selected tabs in both windows")
            return
        }
        guard let secondFirstTabId = secondManager.tabs.first?.id else {
            XCTFail("Expected at least one tab in second window")
            return
        }

        appDelegate.tabManager = firstManager
        XCTAssertTrue(appDelegate.tabManager === firstManager)

        guard let event = makeKeyDownEvent(
            key: "1",
            modifiers: [.command],
            keyCode: 18, // kVK_ANSI_1
            windowNumber: secondWindow.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+1 event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        XCTAssertEqual(firstManager.selectedTabId, firstSelectedBefore, "Cmd+1 must not select a tab in stale active window")
        XCTAssertNotEqual(secondManager.selectedTabId, secondSelectedBefore, "Cmd+1 should change tab selection in event window")
        XCTAssertEqual(secondManager.selectedTabId, secondFirstTabId, "Cmd+1 should select first tab in the event window")
        XCTAssertTrue(appDelegate.tabManager === secondManager, "Shortcut routing should retarget active manager to event window")
    }

    func testCmdTRoutesToEventWindowWhenActiveManagerIsStale() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let firstWindowId = appDelegate.createMainWindow()
        let secondWindowId = appDelegate.createMainWindow()

        defer {
            closeWindow(withId: firstWindowId)
            closeWindow(withId: secondWindowId)
        }

        guard let firstManager = appDelegate.tabManagerFor(windowId: firstWindowId),
              let secondManager = appDelegate.tabManagerFor(windowId: secondWindowId),
              let secondWindow = window(withId: secondWindowId),
              let firstWorkspace = firstManager.selectedWorkspace,
              let secondWorkspace = secondManager.selectedWorkspace else {
            XCTFail("Expected both window contexts to exist")
            return
        }

        let firstSurfaceCount = firstWorkspace.panels.count
        let secondSurfaceCount = secondWorkspace.panels.count

        appDelegate.tabManager = firstManager
        XCTAssertTrue(appDelegate.tabManager === firstManager)

        guard let event = makeKeyDownEvent(
            key: "t",
            modifiers: [.command],
            keyCode: 17, // kVK_ANSI_T
            windowNumber: secondWindow.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+T event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
        waitUntil(description: "Cmd+T to create a surface in the event window") {
            secondWorkspace.panels.count == secondSurfaceCount + 1
        }

        XCTAssertEqual(firstWorkspace.panels.count, firstSurfaceCount, "Cmd+T must not create a surface in stale active window")
        XCTAssertEqual(secondWorkspace.panels.count, secondSurfaceCount + 1, "Cmd+T should create a surface in the event window")
        XCTAssertTrue(appDelegate.tabManager === secondManager, "Shortcut routing should retarget active manager to event window")
    }

    func testCmdDRoutesSplitToEventWindowWhenKeyWindowIsDifferent() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let firstWindowId = appDelegate.createMainWindow()
        let secondWindowId = appDelegate.createMainWindow()

        defer {
            closeWindow(withId: firstWindowId)
            closeWindow(withId: secondWindowId)
        }

        guard let firstManager = appDelegate.tabManagerFor(windowId: firstWindowId),
              let secondManager = appDelegate.tabManagerFor(windowId: secondWindowId),
              let firstWindow = window(withId: firstWindowId),
              let secondWindow = window(withId: secondWindowId),
              let firstWorkspace = firstManager.selectedWorkspace,
              let secondWorkspace = secondManager.selectedWorkspace else {
            XCTFail("Expected both window contexts to exist")
            return
        }

        firstWindow.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        let firstSurfaceCount = firstWorkspace.panels.count
        let secondSurfaceCount = secondWorkspace.panels.count

        appDelegate.tabManager = firstManager
        XCTAssertTrue(appDelegate.tabManager === firstManager)

        guard let event = makeKeyDownEvent(
            key: "d",
            modifiers: [.command],
            keyCode: 2, // kVK_ANSI_D
            windowNumber: secondWindow.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+D event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
        waitUntil(description: "Cmd+D to create a split in the event window") {
            secondWorkspace.panels.count == secondSurfaceCount + 1
        }

        XCTAssertEqual(firstWorkspace.panels.count, firstSurfaceCount, "Cmd+D must not create a split in the stale key window")
        XCTAssertEqual(secondWorkspace.panels.count, secondSurfaceCount + 1, "Cmd+D should create a split in the event window")
        XCTAssertTrue(appDelegate.tabManager === secondManager, "Split shortcut routing should keep the event window active")
    }

    func testCmdDClicksOnlyCloseConfirmationInEventPanel() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let confirmationTitle = String(localized: "dialog.closeWindow.title", defaultValue: "Close window?")
        let closeTitle = String(localized: "common.close", defaultValue: "Close")
        let firstRecorder = CloseConfirmationButtonRecorder()
        let secondRecorder = CloseConfirmationButtonRecorder()

        func makePanel(recorder: CloseConfirmationButtonRecorder) -> NSPanel {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 140),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            let content = NSView(frame: panel.contentView?.bounds ?? .zero)
            let label = NSTextField(labelWithString: confirmationTitle)
            let button = NSButton(
                title: closeTitle,
                target: recorder,
                action: #selector(CloseConfirmationButtonRecorder.recordClick(_:))
            )
            content.addSubview(label)
            content.addSubview(button)
            panel.contentView = content
            panel.orderFrontRegardless()
            return panel
        }

        let firstPanel = makePanel(recorder: firstRecorder)
        let secondPanel = makePanel(recorder: secondRecorder)
        defer {
            firstPanel.orderOut(nil)
            secondPanel.orderOut(nil)
            firstPanel.close()
            secondPanel.close()
        }

        let panelsInGlobalOrder = NSApp.windows.compactMap { window -> NSPanel? in
            guard let panel = window as? NSPanel,
                  panel === firstPanel || panel === secondPanel else { return nil }
            return panel
        }
        guard panelsInGlobalOrder.count == 2 else {
            XCTFail("Expected both close-confirmation panels in NSApp.windows")
            return
        }
        let globallyFirstPanel = panelsInGlobalOrder[0]
        let eventPanel = panelsInGlobalOrder[1]
        let globallyFirstRecorder = globallyFirstPanel === firstPanel ? firstRecorder : secondRecorder
        let eventRecorder = eventPanel === firstPanel ? firstRecorder : secondRecorder

        guard let event = makeKeyDownEvent(
            key: "d",
            modifiers: [.command],
            keyCode: 2,
            windowNumber: eventPanel.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+D event for the second close-confirmation panel")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
        XCTAssertEqual(eventRecorder.clickCount, 1, "Cmd+D must confirm the alert in the shortcut event's window context")
        XCTAssertEqual(globallyFirstRecorder.clickCount, 0, "Cmd+D must not confirm a same-titled alert owned by another window")
    }

    func testCloseConfirmationSheetInAnotherWindowDoesNotInterceptCmdD() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let firstWindowId = appDelegate.createMainWindow()
        let secondWindowId = appDelegate.createMainWindow()
        guard let firstManager = appDelegate.tabManagerFor(windowId: firstWindowId),
              let firstWindow = window(withId: firstWindowId),
              let secondWindow = window(withId: secondWindowId),
              let secondWorkspace = appDelegate.tabManagerFor(windowId: secondWindowId)?.selectedWorkspace else {
            closeWindow(withId: firstWindowId)
            closeWindow(withId: secondWindowId)
            XCTFail("Expected both window contexts")
            return
        }

        let recorder = CloseConfirmationButtonRecorder()
        let sheet = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 140),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let content = NSView(frame: sheet.contentView?.bounds ?? .zero)
        content.addSubview(NSTextField(
            labelWithString: String(localized: "dialog.closeWindow.title", defaultValue: "Close window?")
        ))
        content.addSubview(NSButton(
            title: String(localized: "common.close", defaultValue: "Close"),
            target: recorder,
            action: #selector(CloseConfirmationButtonRecorder.recordClick(_:))
        ))
        sheet.contentView = content
        firstWindow.beginSheet(sheet)
        defer {
            if firstWindow.attachedSheet === sheet {
                firstWindow.endSheet(sheet)
            }
            sheet.orderOut(nil)
            sheet.close()
            closeWindow(withId: firstWindowId)
            closeWindow(withId: secondWindowId)
        }
        waitUntil(description: "close-confirmation sheet to attach to the first window") {
            firstWindow.attachedSheet === sheet && sheet.isVisible
        }

        secondWindow.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        appDelegate.tabManager = firstManager
        let secondSurfaceCount = secondWorkspace.panels.count

        guard let event = makeKeyDownEvent(
            key: "d",
            modifiers: [.command],
            keyCode: 2,
            windowNumber: secondWindow.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+D event for the window without a confirmation")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
        XCTAssertEqual(recorder.clickCount, 0, "A confirmation attached to another window must not consume Cmd+D")
        waitUntil(description: "Cmd+D to reach the event window while another window has a confirmation") {
            secondWorkspace.panels.count == secondSurfaceCount + 1
        }
        XCTAssertEqual(secondWorkspace.panels.count, secondSurfaceCount + 1)
    }

    func testConfiguredOpenReviewShortcutOpensReviewPanel() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId),
              let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace else {
            XCTFail("Expected test window and workspace")
            return
        }

        let panelCountBefore = workspace.panels.count
        let shortcut = StoredShortcut(
            key: "r",
            command: false,
            shift: false,
            option: true,
            control: true
        )

        withTemporaryShortcut(action: .openReview, shortcut: shortcut) {
            guard let event = makeKeyDownEvent(
                key: "r",
                modifiers: [.control, .option],
                keyCode: 15,
                windowNumber: window.windowNumber
            ) else {
                XCTFail("Failed to construct Ctrl+Option+R event")
                return
            }

#if DEBUG
            XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
            XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
        }

        waitUntil(description: "configured Open Review shortcut to create a review panel") {
            workspace.panels.count == panelCountBefore + 1
        }
        XCTAssertEqual(workspace.panels.values.compactMap { $0 as? ReviewPanel }.count, 1)
    }

    func testPerformSplitShortcutSplitsFocusedTerminalSurfaceWhenSelectedWorkspaceIsStale() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId),
              let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace,
              let leftPanelId = workspace.focusedPanelId,
              let leftPanel = workspace.terminalPanel(for: leftPanelId) else {
            XCTFail("Expected split terminal panels")
            return
        }

        let originalPanelIds = Set(workspace.panels.keys)

        guard let rightPanel = workspace.newTerminalSplit(from: leftPanelId, orientation: .horizontal) else {
            XCTFail("Expected split terminal panels")
            return
        }
        waitUntil(description: "split panels to receive Bonsplit pane IDs") {
            workspace.paneId(forPanelId: leftPanel.id) != nil && workspace.paneId(forPanelId: rightPanel.id) != nil
        }

        guard let leftPaneBefore = workspace.paneId(forPanelId: leftPanel.id),
              let rightPaneBefore = workspace.paneId(forPanelId: rightPanel.id) else {
            XCTFail("Expected split pane IDs")
            return
        }
        let layoutBefore = workspace.bonsplitController.layoutSnapshot()
        guard let leftPaneBeforeFrame = layoutBefore.panes.first(where: { $0.paneId == leftPaneBefore.id.uuidString })?.frame,
              let rightPaneBeforeFrame = layoutBefore.panes.first(where: { $0.paneId == rightPaneBefore.id.uuidString })?.frame else {
            XCTFail("Expected pane frames before shortcut split")
            return
        }
        XCTAssertLessThan(leftPaneBeforeFrame.x, rightPaneBeforeFrame.x, "Expected baseline layout to start left-to-right")

        guard let leftSurfaceView = surfaceView(in: leftPanel.hostedView) else {
            XCTFail("Expected left terminal surface view")
            return
        }

        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        workspace.focusPanel(rightPanel.id)
        XCTAssertEqual(workspace.focusedPanelId, rightPanel.id, "Expected Bonsplit selection to stay on the right pane")
        leftPanel.hostedView.suppressReparentFocus()
        XCTAssertTrue(window.makeFirstResponder(leftSurfaceView))
        leftPanel.hostedView.clearSuppressReparentFocus()
        XCTAssertTrue(window.firstResponder === leftSurfaceView, "Expected left Ghostty surface to stay first responder")
        XCTAssertEqual(workspace.focusedPanelId, rightPanel.id, "Expected selected pane to stay stale after first-responder change")
        XCTAssertEqual(leftSurfaceView.tabId, workspace.id, "Expected focused Ghostty view to keep its workspace ID")
        XCTAssertEqual(leftSurfaceView.terminalSurface?.id, leftPanel.id, "Expected focused Ghostty view to keep its surface ID")

        XCTAssertTrue(
            appDelegate.performSplitShortcut(direction: .right, preferredWindow: window),
            "Split shortcut should use the focused terminal surface even when selectedTabId is stale"
        )
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))

        let newPanelIds = Set(workspace.panels.keys)
            .subtracting(originalPanelIds)
            .subtracting([rightPanel.id])
        guard newPanelIds.count == 1, let newPanelId = newPanelIds.first else {
            XCTFail("Expected exactly one shortcut-created split panel")
            return
        }
        guard let newPaneId = workspace.paneId(forPanelId: newPanelId),
              let rightPaneAfter = workspace.paneId(forPanelId: rightPanel.id) else {
            XCTFail("Expected pane IDs after shortcut split")
            return
        }
        let layoutAfter = workspace.bonsplitController.layoutSnapshot()
        guard let newPaneFrame = layoutAfter.panes.first(where: { $0.paneId == newPaneId.id.uuidString })?.frame,
              let rightPaneAfterFrame = layoutAfter.panes.first(where: { $0.paneId == rightPaneAfter.id.uuidString })?.frame else {
            XCTFail("Expected pane frames after shortcut split")
            return
        }
        XCTAssertEqual(layoutAfter.panes.count, 3, "Cmd+D should create a third pane")
        XCTAssertLessThan(
            newPaneFrame.x,
            rightPaneAfterFrame.x,
            "Cmd+D should split the focused left terminal pane, not the stale selected right pane"
        )
    }

    func testCmdCtrlWHidesWindowAndPreservesItsSessions() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let targetWindow = window(withId: windowId) else {
            XCTFail("Expected test window")
            return
        }

        let manager = appDelegate.tabManagerFor(windowId: windowId)
        let workspace = manager?.selectedWorkspace
        let panelIds = workspace.map { Set($0.panels.keys) }

        guard let event = makeKeyDownEvent(
            key: "w",
            modifiers: [.command, .control],
            keyCode: 13,
            windowNumber: targetWindow.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+Ctrl+W event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        XCTAssertFalse(targetWindow.isVisible)
        XCTAssertTrue(appDelegate.tabManagerFor(windowId: windowId) === manager)
        XCTAssertTrue(manager?.selectedWorkspace === workspace)
        XCTAssertEqual(workspace.map { Set($0.panels.keys) }, panelIds)
        XCTAssertTrue(appDelegate.reopenMostRecentlyHiddenMainWindow(onlyIfNoVisibleMainWindows: false))
        XCTAssertTrue(targetWindow.isVisible)
        XCTAssertTrue(appDelegate.tabManagerFor(windowId: windowId) === manager)
    }

    func testNativeCloseReopensMostRecentlyHiddenWindowWithoutAddingWorkspace() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }
        guard let targetWindow = window(withId: windowId) else {
            XCTFail("Expected test window")
            return
        }

        let olderWindowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: olderWindowId) }
        guard let olderWindow = window(withId: olderWindowId) else {
            XCTFail("Expected second test window")
            return
        }
        olderWindow.close()
        let manager = appDelegate.tabManagerFor(windowId: windowId)
        let workspaceIds = manager?.tabs.map(\.id)
        targetWindow.performClose(nil)
        XCTAssertFalse(targetWindow.isVisible)
        XCTAssertTrue(appDelegate.reopenMostRecentlyHiddenMainWindow(onlyIfNoVisibleMainWindows: false))
        XCTAssertTrue(targetWindow.isVisible)
        XCTAssertFalse(olderWindow.isVisible, "Reopen must choose the last hidden window")
        XCTAssertEqual(manager?.tabs.map(\.id), workspaceIds)
        XCTAssertTrue(appDelegate.tabManagerFor(windowId: windowId) === manager)
    }

    func testSessionSnapshotFlagsClosedWindowHiddenAndOrdersItLast() throws {
        let appDelegate = try XCTUnwrap(AppDelegate.shared)
        closeAllMainWindows()
        let visibleWindowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: visibleWindowId) }
        let closedWindowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: closedWindowId) }
        let closedWindow = try XCTUnwrap(window(withId: closedWindowId))
        let closedManager = try XCTUnwrap(appDelegate.tabManagerFor(windowId: closedWindowId))
        _ = closedManager.addWorkspace()
        let closedWorkspaceCount = closedManager.tabs.count

        XCTAssertTrue(appDelegate.focusMainWindow(windowId: closedWindowId))
        closedWindow.performClose(nil)
        XCTAssertFalse(closedWindow.isVisible)
        XCTAssertTrue(
            appDelegate.tabManagerFor(windowId: closedWindowId) === closedManager,
            "An ordinary close keeps the window registered for Dock reopen"
        )

        let snapshot = try XCTUnwrap(appDelegate.buildSessionSnapshot(includeScrollback: false))
        XCTAssertEqual(snapshot.windows.count, 2)
        let visible = try XCTUnwrap(snapshot.windows.first)
        let hidden = try XCTUnwrap(snapshot.windows.last)
        XCTAssertFalse(visible.isHiddenWindow, "The window the user can see must stay the primary restore entry")
        XCTAssertTrue(hidden.isHiddenWindow, "A closed window is written flagged hidden, never as a visible one")
        XCTAssertEqual(hidden.tabManager.workspaces.count, closedWorkspaceCount)
        XCTAssertEqual(
            SessionPersistenceStore.windowsToRestore(from: snapshot).count, 1,
            "Restore must not bring a closed window back on the next launch"
        )
        XCTAssertEqual(SessionPersistenceStore.hiddenWindows(from: snapshot).count, 1)

        XCTAssertTrue(appDelegate.reopenMostRecentlyHiddenMainWindow(onlyIfNoVisibleMainWindows: false))
        XCTAssertTrue(closedWindow.isVisible)
        let reopened = try XCTUnwrap(appDelegate.buildSessionSnapshot(includeScrollback: false))
        XCTAssertTrue(
            reopened.windows.allSatisfy { !$0.isHiddenWindow },
            "Reopening from the Dock makes the window an ordinary restore entry again"
        )
    }

    func testHiddenPrimaryWindowRetainsItsWindowAndWorkspaceUntilExplicitDisposal() throws {
        let appDelegate = try XCTUnwrap(AppDelegate.shared)
        AppDelegate.installWindowResponderSwizzlesForTesting()
        let windowId = UUID()
        defer { _ = appDelegate.closeMainWindow(windowId: windowId) }
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        weak var retainedWindow: NSWindow?
        autoreleasepool {
            let primaryWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                styleMask: [.titled, .closable], backing: .buffered, defer: false
            )
            primaryWindow.isReleasedWhenClosed = false
            appDelegate.registerMainWindow(
                primaryWindow, windowId: windowId, tabManager: manager,
                sidebarState: SidebarState(), sidebarSelectionState: SidebarSelectionState()
            )
            retainedWindow = primaryWindow
            primaryWindow.close()
        }
        let window = try XCTUnwrap(retainedWindow)
        XCTAssertTrue(appDelegate.tabManagerFor(windowId: windowId) === manager)
        XCTAssertFalse(workspace.panels.isEmpty)
        XCTAssertTrue(appDelegate.closeMainWindow(windowId: windowId))
        XCTAssertNil(appDelegate.tabManagerFor(windowId: windowId))
        XCTAssertTrue(workspace.panels.isEmpty)
        XCTAssertFalse(window.isVisible)
    }

    func testDockNewWindowAndNewWorkspaceReopenHiddenSession() throws {
        let appDelegate = try XCTUnwrap(AppDelegate.shared)
        closeAllMainWindows()
        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }
        let targetWindow = try XCTUnwrap(window(withId: windowId))
        let manager = try XCTUnwrap(appDelegate.tabManagerFor(windowId: windowId))
        let workspaceIds = manager.tabs.map(\.id)
        targetWindow.close()
        XCTAssertFalse(appDelegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
        XCTAssertTrue(targetWindow.isVisible)

        targetWindow.close()
        XCTAssertFalse(appDelegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true),
                       "Visible auxiliary windows must not prevent reopening the main session")
        XCTAssertTrue(targetWindow.isVisible)

        targetWindow.close()
        appDelegate.openNewMainWindow(nil)
        XCTAssertTrue(targetWindow.isVisible)
        XCTAssertEqual(mainWindowIds(), Set([windowId]))

        targetWindow.close()
        let event = try XCTUnwrap(makeKeyDownEvent(
            key: "n", modifiers: [.command], keyCode: 45,
            windowNumber: targetWindow.windowNumber
        ))
        #if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
        #else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
        #endif
        XCTAssertTrue(targetWindow.isVisible)
        XCTAssertEqual(manager.tabs.map(\.id), workspaceIds)
        XCTAssertEqual(mainWindowIds(), Set([windowId]))
    }

    func testClosingMainWindowTearsDownEveryOwnedWorkspaceAndBrowserElementRef() throws {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        var surfaceIds: [UUID] = []
        defer {
            if appDelegate.tabManagerFor(windowId: windowId) != nil {
                closeWindow(withId: windowId)
            }
            for surfaceId in surfaceIds {
                TerminalController.shared.v2BrowserPermanentlyRemoveSurfaceState(surfaceId: surfaceId)
            }
        }

        let manager = try XCTUnwrap(appDelegate.tabManagerFor(windowId: windowId))
        let firstWorkspace = try XCTUnwrap(manager.tabs.first)
        let secondWorkspace = manager.addTab(select: false)
        let workspaces = [firstWorkspace, secondWorkspace]
        XCTAssertEqual(manager.tabs.count, 2)

        var refs: [(surfaceId: UUID, ref: String)] = []
        for (index, workspace) in workspaces.enumerated() {
            let surfaceId = try XCTUnwrap(workspace.panels.keys.first)
            surfaceIds.append(surfaceId)
            switch TerminalController.shared.browserRPCState.allocateElementRefs(
                surfaceId: surfaceId,
                selectors: ["#window-owned-workspace-\(index)"]
            ) {
            case .allocated(let allocated):
                let ref = try XCTUnwrap(allocated.first)
                refs.append((surfaceId, ref))
                XCTAssertNotNil(TerminalController.shared.v2BrowserResolveSelector(ref, surfaceId: surfaceId))
            case .resourceExhausted:
                XCTFail("A fresh workspace surface must accept its first browser element ref")
            }
        }

        closeWindow(withId: windowId)

        XCTAssertNil(appDelegate.tabManagerFor(windowId: windowId), "The real window close path must unregister its context")
        for workspace in workspaces {
            XCTAssertTrue(workspace.panels.isEmpty, "Closing a window must tear down every workspace it still owns")
        }
        for (surfaceId, ref) in refs {
            switch TerminalController.shared.v2BrowserSelectorResolutionError(ref, surfaceId: surfaceId) {
            case .err(let code, _, _):
                XCTAssertEqual(code, "not_found", "Whole-window teardown must permanently remove every owned surface ref")
            case .ok:
                XCTFail("A ref from a closed window must not remain resolvable")
            }
        }
    }

    func testTabManagerWindowCloseTeardownStopsEveryLifecycleResourceIdempotently() throws {
        let manager = TabManager()
        defer { manager.teardownForWindowClose() }

        let firstWorkspace = try XCTUnwrap(manager.selectedWorkspace)
        let firstPanelId = try XCTUnwrap(firstWorkspace.panels.keys.first)
        let probeKey = TabManager.WorkspaceGitProbeKey(
            workspaceId: firstWorkspace.id,
            panelId: firstPanelId
        )
        manager.scheduleWorkspaceGitMetadataRefresh(
            workspaceId: firstWorkspace.id,
            panelId: firstPanelId,
            directory: "/tmp",
            delays: [60],
            reason: "window-close-lifecycle-test"
        )
        manager.workspaceGitTrackedDirectoryByKey[probeKey] = "/tmp"

        _ = manager.addTab(select: false)
        manager.selectNextTab()
        NotificationCenter.default.post(
            name: .ghosttyDidSetTitle,
            object: nil,
            userInfo: [
                GhosttyNotificationKey.tabId: firstWorkspace.id,
                GhosttyNotificationKey.surfaceId: firstPanelId,
                GhosttyNotificationKey.title: "Pending lifecycle title"
            ]
        )
#if DEBUG
        manager.uiTestCancellables.insert(AnyCancellable {})
#endif

        let primed = manager.lifecycleResourceSnapshot
        XCTAssertFalse(primed.isStopped, "A live manager must not report a stopped lifecycle")
        XCTAssertGreaterThan(primed.observerCount, 0, "The test must exercise installed global observers")
        XCTAssertTrue(primed.hasAgentPIDSweepTimer, "The test must exercise the repeating PID sweep")
        XCTAssertTrue(primed.hasWorkspaceGitMetadataPollTimer, "The test must exercise the workspace metadata poll")
        XCTAssertTrue(
            primed.hasSelectedWorkspaceGitMetadataPollTimer,
            "The test must exercise the selected-workspace metadata poll"
        )
        XCTAssertGreaterThan(primed.workspaceGitProbeTimerCount, 0, "The test must schedule a cancellable git probe")
        XCTAssertGreaterThan(primed.workspaceGitProbeGenerationCount, 0, "The test must retain a live probe generation")
        XCTAssertGreaterThan(primed.workspaceGitTrackedDirectoryCount, 0, "The test must retain tracked probe state")
        XCTAssertTrue(primed.hasWorkspaceCycleCooldownTask, "The test must schedule workspace-cycle cooldown work")
        XCTAssertTrue(primed.hasPendingPanelTitleCoalescerWork, "The test must queue coalesced title work")
#if DEBUG
        XCTAssertGreaterThan(primed.uiTestCancellableCount, 0, "The test must retain a DEBUG cancellable")
#endif

        manager.teardownForWindowClose()
        assertLifecycleResourcesStopped(manager, reason: "The first teardown must stop every window-owned resource")

        manager.teardownForWindowClose()
        assertLifecycleResourcesStopped(manager, reason: "Repeated teardown must remain a safe no-op")

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.35))
        assertLifecycleResourcesStopped(
            manager,
            reason: "Queued title, selection, and cooldown work must not revive a stopped manager"
        )
    }

    func testPrimaryManagerStoreReplacesStoppedManagerAfterRealWindowClose() throws {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = UUID()
        let initialManager = TabManager()
        let initialWorkspace = try XCTUnwrap(initialManager.selectedWorkspace)
        let store = PrimaryTabManagerStore(initialManager: initialManager)
        let initialWindow = makeUnregisteredMainWindow(windowId: windowId)
        var replacementWindow: NSWindow?
        defer {
            if appDelegate.tabManagerFor(windowId: windowId) != nil {
                if let replacementWindow {
                    NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: replacementWindow)
                } else {
                    NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: initialWindow)
                }
            }
            appDelegate.disposeMainWindow(initialWindow)
            if let replacementWindow { appDelegate.disposeMainWindow(replacementWindow) }
            initialManager.teardownForWindowClose()
            store.manager.teardownForWindowClose()
        }

        appDelegate.registerMainWindow(
            initialWindow,
            windowId: windowId,
            tabManager: store.manager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState()
        )

        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: initialWindow)

        XCTAssertNil(appDelegate.tabManagerFor(windowId: windowId), "Closing the primary window must remove its context")
        assertLifecycleResourcesStopped(initialManager, reason: "The closed primary manager must remain stopped")
        XCTAssertTrue(initialWorkspace.panels.isEmpty, "The closed primary workspace must remain torn down")

        let replacementManager = store.manager
        XCTAssertFalse(replacementManager === initialManager, "The primary owner must replace, not reactivate, a stopped manager")
        assertLifecycleResourcesRunning(
            replacementManager,
            reason: "The replacement primary manager must own a fresh lifecycle"
        )
        let freshWorkspace = try XCTUnwrap(replacementManager.selectedWorkspace)
        XCTAssertFalse(
            freshWorkspace === initialWorkspace,
            "The replacement manager must not reuse the torn-down primary workspace"
        )
        XCTAssertFalse(freshWorkspace.panels.isEmpty, "The replacement workspace must contain a viable panel")
        let freshPanelId = try XCTUnwrap(freshWorkspace.panels.keys.first)
        XCTAssertFalse(replacementManager.lifecycleResourceSnapshot.hasPendingPanelTitleCoalescerWork)

        let nextWindow = makeUnregisteredMainWindow(windowId: windowId)
        replacementWindow = nextWindow
        appDelegate.registerMainWindow(
            nextWindow,
            windowId: windowId,
            tabManager: replacementManager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState()
        )

        NotificationCenter.default.post(
            name: .ghosttyDidSetTitle,
            object: nil,
            userInfo: [
                GhosttyNotificationKey.tabId: freshWorkspace.id,
                GhosttyNotificationKey.surfaceId: freshPanelId,
                GhosttyNotificationKey.title: "Replacement lifecycle title"
            ]
        )

        XCTAssertTrue(
            replacementManager.lifecycleResourceSnapshot.hasPendingPanelTitleCoalescerWork,
            "A title notification must reach the fresh primary manager's observers"
        )

        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: nextWindow)

        XCTAssertNil(appDelegate.tabManagerFor(windowId: windowId), "Closing the replacement window must remove its context")
        assertLifecycleResourcesStopped(replacementManager, reason: "The replacement manager must stop on close")
        let nextPrimaryManager = store.manager
        XCTAssertFalse(nextPrimaryManager === initialManager)
        XCTAssertFalse(nextPrimaryManager === replacementManager, "Each primary close must advance to another fresh manager")
        assertLifecycleResourcesRunning(nextPrimaryManager, reason: "The next primary manager must start live")
        XCTAssertFalse(try XCTUnwrap(nextPrimaryManager.selectedWorkspace).panels.isEmpty)
    }

    func testRebindingMainWindowReplacesAndRemovesCloseObserverWithoutStoppingLiveContext() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = UUID()
        let manager = TabManager()
        let sidebarState = SidebarState()
        let sidebarSelectionState = SidebarSelectionState()
        let firstWindow = makeUnregisteredMainWindow(windowId: windowId)
        let replacementWindow = makeUnregisteredMainWindow(windowId: windowId)
        var finalWindow: NSWindow?
        var finalManager: TabManager?
        defer {
            if let finalWindow {
                NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: finalWindow)
            } else if appDelegate.tabManagerFor(windowId: windowId) != nil {
                NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: replacementWindow)
            }
            appDelegate.disposeMainWindow(firstWindow)
            appDelegate.disposeMainWindow(replacementWindow)
            if let finalWindow { appDelegate.disposeMainWindow(finalWindow) }
            manager.teardownForWindowClose()
            finalManager?.teardownForWindowClose()
        }

        appDelegate.registerMainWindow(
            firstWindow,
            windowId: windowId,
            tabManager: manager,
            sidebarState: sidebarState,
            sidebarSelectionState: sidebarSelectionState
        )
        appDelegate.registerMainWindow(
            replacementWindow,
            windowId: windowId,
            tabManager: manager,
            sidebarState: sidebarState,
            sidebarSelectionState: sidebarSelectionState
        )

        XCTAssertTrue(appDelegate.mainWindow(for: windowId) === replacementWindow)
        XCTAssertTrue(appDelegate.tabManagerFor(windowId: windowId) === manager)

        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: firstWindow)

        XCTAssertTrue(
            appDelegate.mainWindow(for: windowId) === replacementWindow,
            "Closing a retired NSWindow must not unregister its replacement's context"
        )
        XCTAssertTrue(
            appDelegate.tabManagerFor(windowId: windowId) === manager,
            "Closing a retired NSWindow must not stop the manager still owned by its replacement"
        )
        XCTAssertFalse(manager.lifecycleResourceSnapshot.isStopped)

        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: replacementWindow)

        XCTAssertNil(appDelegate.tabManagerFor(windowId: windowId), "Closing the current window must unregister its context")
        assertLifecycleResourcesStopped(manager, reason: "Closing the current window must stop its manager")

        let nextManager = TabManager()
        let nextWindow = makeUnregisteredMainWindow(windowId: windowId)
        finalManager = nextManager
        finalWindow = nextWindow
        appDelegate.registerMainWindow(
            nextWindow,
            windowId: windowId,
            tabManager: nextManager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState()
        )

        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: replacementWindow)

        XCTAssertTrue(
            appDelegate.mainWindow(for: windowId) === nextWindow,
            "A close observer must be removed after teardown so it cannot unregister a later context with the same ID"
        )
        XCTAssertTrue(appDelegate.tabManagerFor(windowId: windowId) === nextManager)
        XCTAssertFalse(nextManager.lifecycleResourceSnapshot.isStopped)

        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: nextWindow)
        XCTAssertNil(appDelegate.tabManagerFor(windowId: windowId))
        assertLifecycleResourcesStopped(nextManager, reason: "The final current window must still own a working close observer")
    }

    func testReindexingIntoOccupiedWindowTearsDownDisplacedContextAndPreservesMovedContext() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let firstWindowId = UUID()
        let displacedWindowId = UUID()
        let firstManager = TabManager()
        let displacedManager = TabManager()
        let firstWindow = makeUnregisteredMainWindow(windowId: firstWindowId)
        let occupiedWindow = makeUnregisteredMainWindow(windowId: displacedWindowId)
        defer {
            if appDelegate.tabManagerFor(windowId: firstWindowId) != nil {
                NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: firstWindow)
                NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: occupiedWindow)
            }
            if appDelegate.tabManagerFor(windowId: displacedWindowId) != nil {
                NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: occupiedWindow)
            }
            appDelegate.disposeMainWindow(firstWindow)
            appDelegate.disposeMainWindow(occupiedWindow)
            firstManager.teardownForWindowClose()
            displacedManager.teardownForWindowClose()
        }

        appDelegate.registerMainWindow(
            firstWindow,
            windowId: firstWindowId,
            tabManager: firstManager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState()
        )
        appDelegate.registerMainWindow(
            occupiedWindow,
            windowId: displacedWindowId,
            tabManager: displacedManager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState()
        )

        appDelegate.registerMainWindow(
            occupiedWindow,
            windowId: firstWindowId,
            tabManager: firstManager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState()
        )

        XCTAssertNil(
            appDelegate.tabManagerFor(windowId: displacedWindowId),
            "Reindexing into an occupied NSWindow must remove the displaced context"
        )
        assertLifecycleResourcesStopped(
            displacedManager,
            reason: "The manager displaced from an occupied NSWindow must be torn down"
        )
        XCTAssertTrue(appDelegate.tabManagerFor(windowId: firstWindowId) === firstManager)
        XCTAssertTrue(
            appDelegate.mainWindow(for: firstWindowId) === occupiedWindow,
            "The moved context must own the destination NSWindow under its original ID"
        )

        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: firstWindow)

        XCTAssertTrue(
            appDelegate.tabManagerFor(windowId: firstWindowId) === firstManager,
            "Closing the moved context's stale NSWindow must not remove its destination context"
        )
        XCTAssertTrue(appDelegate.mainWindow(for: firstWindowId) === occupiedWindow)
        XCTAssertFalse(firstManager.lifecycleResourceSnapshot.isStopped)

        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: occupiedWindow)

        XCTAssertNil(appDelegate.tabManagerFor(windowId: firstWindowId))
        assertLifecycleResourcesStopped(firstManager, reason: "Closing the destination NSWindow must stop the moved manager")
    }

    func testCmdWClosesWindowWhenClosingLastSurfaceInLastWorkspace() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }


        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let targetWindow = window(withId: windowId),
              let manager = appDelegate.tabManagerFor(windowId: windowId) else {
            XCTFail("Expected test window and manager")
            return
        }

        XCTAssertEqual(manager.tabs.count, 1)
        XCTAssertEqual(manager.tabs[0].panels.count, 1)

        guard let event = makeKeyDownEvent(
            key: "w",
            modifiers: [.command],
            keyCode: 13,
            windowNumber: targetWindow.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+W event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        waitUntil(description: "Cmd+W on the last surface to close and unregister the window") {
            !targetWindow.isVisible && appDelegate.tabManagerFor(windowId: windowId) == nil
        }

        // `NSApp.windows` can retain a closed NSWindow in a headless test host. Visibility
        // plus MainWindowContext removal are the observable close contract, matching the
        // direct Cmd+Ctrl+W coverage above.
        XCTAssertFalse(targetWindow.isVisible)
        XCTAssertNil(appDelegate.tabManagerFor(windowId: windowId))
    }

    func testCmdWClosesAuxiliaryWindowInsteadOfMainTerminalPanel() throws {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        XCTAssertNotNil(window(withId: windowId), "Expected test window")

        guard let manager = appDelegate.tabManagerFor(windowId: windowId) else {
            XCTFail("Expected test manager")
            return
        }

        let mainWorkspaceCount = manager.tabs.count
        let auxiliaryWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        auxiliaryWindow.isReleasedWhenClosed = false
        auxiliaryWindow.identifier = NSUserInterfaceItemIdentifier("cmux.about")
        auxiliaryWindow.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        defer {
            if auxiliaryWindow.isVisible {
                auxiliaryWindow.performClose(nil)
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            }
        }

        guard let event = makeKeyDownEvent(
            key: "w",
            modifiers: [.command],
            keyCode: 13,
            windowNumber: auxiliaryWindow.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+W event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
        throw XCTSkip("debugHandleCustomShortcut is only available in DEBUG builds")
#endif

        waitUntil(description: "Cmd+W to close the auxiliary window") { !auxiliaryWindow.isVisible }

        XCTAssertFalse(auxiliaryWindow.isVisible, "Cmd+W should close the auxiliary window")
        XCTAssertNotNil(self.window(withId: windowId), "Cmd+W in auxiliary window should not close the main window")
        XCTAssertEqual(manager.tabs.count, mainWorkspaceCount, "Cmd+W in auxiliary window should not close a terminal panel")
        XCTAssertNotEqual(NSApp.keyWindow?.identifier?.rawValue, "cmux.about", "Closed auxiliary window should not remain key")
    }

    func testCmdPhysicalIWithDvorakCharactersDoesNotTriggerShowNotifications() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId) else {
            XCTFail("Expected test window")
            return
        }

        withTemporaryShortcut(action: .showNotifications) {
            // Dvorak: physical ANSI "I" key can produce the character "c".
            // This should behave like Cmd+C (copy), not match the Cmd+I app shortcut.
            guard let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.command],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: "c",
                charactersIgnoringModifiers: "c",
                isARepeat: false,
                keyCode: 34 // kVK_ANSI_I
            ) else {
                XCTFail("Failed to construct Dvorak Cmd+C event on physical ANSI I key")
                return
            }

#if DEBUG
            XCTAssertFalse(appDelegate.debugHandleCustomShortcut(event: event))
#else
            XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
        }
    }

    func testMinimalModeUsesZeroTopSafeAreaForMainWindowContentView() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let defaults = UserDefaults.standard
        let savedMode = defaults.object(forKey: WorkspacePresentationModeSettings.modeKey)
        defaults.set(WorkspacePresentationModeSettings.Mode.minimal.rawValue, forKey: WorkspacePresentationModeSettings.modeKey)
        defer {
            restoreDefaultsValue(savedMode, forKey: WorkspacePresentationModeSettings.modeKey, defaults: defaults)
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId),
              let contentView = window.contentView else {
            XCTFail("Expected main window content view")
            return
        }

        contentView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        // With window glass active, NSGlassEffectView wraps the hosting view as
        // the window's contentView; the zero-inset contract lives on the hosted
        // MainWindowHostingView, which owns the actual content layout.
        let effectiveContentView = WindowGlassEffect.hostedContentView(in: contentView) ?? contentView
        XCTAssertEqual(
            effectiveContentView.safeAreaInsets.top,
            0,
            accuracy: 0.5,
            "Minimal mode should not leave a top safe-area inset in the main window content view"
        )
    }

    func testAttachUpdateAccessoryRemovesTitlebarAccessoryWhenMinimalModeEnabled() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let defaults = UserDefaults.standard
        let savedMode = defaults.object(forKey: WorkspacePresentationModeSettings.modeKey)
        defaults.set(WorkspacePresentationModeSettings.Mode.standard.rawValue, forKey: WorkspacePresentationModeSettings.modeKey)
        defer {
            restoreDefaultsValue(savedMode, forKey: WorkspacePresentationModeSettings.modeKey, defaults: defaults)
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId) else {
            XCTFail("Expected main window")
            return
        }

        let hasTitlebarAccessory: () -> Bool = {
            window.titlebarAccessoryViewControllers.contains {
                $0.view.identifier?.rawValue == "cmux.titlebarControls"
            }
        }

        XCTAssertTrue(hasTitlebarAccessory(), "Expected visible-titlebar mode to attach the titlebar accessory")

        defaults.set(WorkspacePresentationModeSettings.Mode.minimal.rawValue, forKey: WorkspacePresentationModeSettings.modeKey)
        appDelegate.attachUpdateAccessory(to: window)
        waitUntil(description: "minimal mode to remove the titlebar accessory") { !hasTitlebarAccessory() }

        XCTAssertFalse(
            hasTitlebarAccessory(),
            "Minimal mode should remove the titlebar accessory instead of keeping a hidden controller attached"
        )
    }

    func testWorkspaceMinimalModeDefaultsToMinimalPresentation() {
        let defaults = UserDefaults.standard
        let savedMode = defaults.object(forKey: WorkspacePresentationModeSettings.modeKey)
        defer {
            restoreDefaultsValue(savedMode, forKey: WorkspacePresentationModeSettings.modeKey, defaults: defaults)
        }

        defaults.removeObject(forKey: WorkspacePresentationModeSettings.modeKey)

        XCTAssertEqual(
            WorkspacePresentationModeSettings.mode(defaults: defaults),
            .minimal
        )
    }

    func testKeyboardShortcutSettingsSetShortcutPostsSpecificChangeNotification() {
        let notificationName = Notification.Name("cmux.keyboardShortcutSettingsDidChange")
        let expectedAction = KeyboardShortcutSettings.Action.toggleSidebar.rawValue
        let expectation = expectation(forNotification: notificationName, object: nil) { notification in
            notification.userInfo?["action"] as? String == expectedAction
        }

        KeyboardShortcutSettings.setShortcut(
            StoredShortcut(key: "s", command: true, shift: false, option: false, control: true),
            for: .toggleSidebar
        )

        wait(for: [expectation], timeout: 0.2)
    }

    func testCmdPhysicalPWithDvorakCharactersDoesNotTriggerCommandPaletteSwitcher() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId) else {
            XCTFail("Expected test window")
            return
        }

        let switcherExpectation = expectation(description: "Cmd+L should not request command palette switcher")
        switcherExpectation.isInverted = true
        let token = NotificationCenter.default.addObserver(
            forName: .commandPaletteSwitcherRequested,
            object: nil,
            queue: nil
        ) { _ in
            switcherExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        // Dvorak: physical ANSI "P" key can produce "l".
        // This should behave as Cmd+L, not as physical Cmd+P.
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "l",
            charactersIgnoringModifiers: "l",
            isARepeat: false,
            keyCode: 35 // kVK_ANSI_P
        ) else {
            XCTFail("Failed to construct Dvorak Cmd+L event on physical ANSI P key")
            return
        }

#if DEBUG
        _ = appDelegate.debugHandleCustomShortcut(event: event)
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        wait(for: [switcherExpectation], timeout: 0.15)
    }

    func testCmdPWithCapsLockStillTriggersCommandPaletteSwitcher() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId) else {
            XCTFail("Expected test window")
            return
        }

        let switcherExpectation = expectation(description: "Cmd+P with Caps Lock should request command palette switcher")
        let token = NotificationCenter.default.addObserver(
            forName: .commandPaletteSwitcherRequested,
            object: nil,
            queue: nil
        ) { _ in
            switcherExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .capsLock],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "p",
            charactersIgnoringModifiers: "p",
            isARepeat: false,
            keyCode: 35 // kVK_ANSI_P
        ) else {
            XCTFail("Failed to construct Cmd+P + Caps Lock event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        wait(for: [switcherExpectation], timeout: 0.15)
    }

    func testCmdPFallsBackToANSIKeyCodeWhenCharactersAndLayoutTranslationAreUnavailable() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId) else {
            XCTFail("Expected test window")
            return
        }

        appDelegate.shortcutLayoutCharacterProvider = { _, _ in nil }
        defer {
            appDelegate.shortcutLayoutCharacterProvider = KeyboardLayout.character(forKeyCode:modifierFlags:)
        }

        let switcherExpectation = expectation(description: "Cmd+P with unavailable characters should request command palette switcher")
        let token = NotificationCenter.default.addObserver(
            forName: .commandPaletteSwitcherRequested,
            object: nil,
            queue: nil
        ) { _ in
            switcherExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 35 // kVK_ANSI_P
        ) else {
            XCTFail("Failed to construct Cmd+P event with unavailable characters")
            return
        }

        XCTAssertTrue(appDelegate.handleBrowserSurfaceKeyEquivalent(event))
        wait(for: [switcherExpectation], timeout: 0.15)
    }

    func testCmdPDoesNotFallbackToANSIKeyCodeWhenLayoutTranslationProvidesDifferentLetter() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId) else {
            XCTFail("Expected test window")
            return
        }

        appDelegate.shortcutLayoutCharacterProvider = { _, _ in "b" }
        defer {
            appDelegate.shortcutLayoutCharacterProvider = KeyboardLayout.character(forKeyCode:modifierFlags:)
        }

        let switcherExpectation = expectation(description: "Non-P layout translation should not request command palette switcher")
        switcherExpectation.isInverted = true
        let token = NotificationCenter.default.addObserver(
            forName: .commandPaletteSwitcherRequested,
            object: nil,
            queue: nil
        ) { _ in
            switcherExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 35 // kVK_ANSI_P
        ) else {
            XCTFail("Failed to construct Cmd+P event with unavailable characters")
            return
        }

        _ = appDelegate.handleBrowserSurfaceKeyEquivalent(event)
        wait(for: [switcherExpectation], timeout: 0.15)
    }

    func testCmdPFallsBackToCommandAwareLayoutTranslationWhenCharactersAreUnavailable() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId) else {
            XCTFail("Expected test window")
            return
        }

        appDelegate.shortcutLayoutCharacterProvider = { keyCode, modifierFlags in
            guard keyCode == 35 else { return nil } // kVK_ANSI_P
            return modifierFlags.contains(.command) ? "p" : "r"
        }
        defer {
            appDelegate.shortcutLayoutCharacterProvider = KeyboardLayout.character(forKeyCode:modifierFlags:)
        }

        let switcherExpectation = expectation(description: "Command-aware layout translation should request command palette switcher")
        let token = NotificationCenter.default.addObserver(
            forName: .commandPaletteSwitcherRequested,
            object: nil,
            queue: nil
        ) { _ in
            switcherExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 35 // kVK_ANSI_P
        ) else {
            XCTFail("Failed to construct Cmd+P event with unavailable characters")
            return
        }

        XCTAssertTrue(appDelegate.handleBrowserSurfaceKeyEquivalent(event))
        wait(for: [switcherExpectation], timeout: 0.15)
    }

    func testCmdShiftPhysicalPWithDvorakCharactersDoesNotTriggerCommandPalette() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId) else {
            XCTFail("Expected test window")
            return
        }

        let paletteExpectation = expectation(description: "Cmd+Shift+L should not request command palette")
        paletteExpectation.isInverted = true
        let token = NotificationCenter.default.addObserver(
            forName: .commandPaletteRequested,
            object: nil,
            queue: nil
        ) { _ in
            paletteExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        // Dvorak: physical ANSI "P" key can produce "l".
        // This should behave as Cmd+Shift+L, not as physical Cmd+Shift+P.
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .shift],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "l",
            charactersIgnoringModifiers: "l",
            isARepeat: false,
            keyCode: 35 // kVK_ANSI_P
        ) else {
            XCTFail("Failed to construct Dvorak Cmd+Shift+L event on physical ANSI P key")
            return
        }

#if DEBUG
        _ = appDelegate.debugHandleCustomShortcut(event: event)
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        wait(for: [paletteExpectation], timeout: 0.15)
    }

    func testCmdOptionPhysicalTWithDvorakCharactersDoesNotTriggerCloseOtherTabsShortcut() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId) else {
            XCTFail("Expected test window")
            return
        }

        // Dvorak: physical ANSI "T" key can produce "y".
        // This should not match the Cmd+Option+T app shortcut.
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .option],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "y",
            charactersIgnoringModifiers: "y",
            isARepeat: false,
            keyCode: 17 // kVK_ANSI_T
        ) else {
            XCTFail("Failed to construct Dvorak Cmd+Option+Y event on physical ANSI T key")
            return
        }

#if DEBUG
        XCTAssertFalse(appDelegate.debugHandleCustomShortcut(event: event))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
    }

    func testCmdShiftPRequestsCommandPaletteCommands() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId) else {
            XCTFail("Expected test window")
            return
        }

        let paletteExpectation = expectation(description: "Expected command palette commands request for Cmd+Shift+P")
        var observedPaletteWindow: NSWindow?
        let paletteToken = NotificationCenter.default.addObserver(
            forName: .commandPaletteRequested,
            object: nil,
            queue: nil
        ) { notification in
            observedPaletteWindow = notification.object as? NSWindow
            paletteExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(paletteToken) }

        let switcherExpectation = expectation(description: "Cmd+Shift+P should not request command palette switcher")
        switcherExpectation.isInverted = true
        let switcherToken = NotificationCenter.default.addObserver(
            forName: .commandPaletteSwitcherRequested,
            object: nil,
            queue: nil
        ) { _ in
            switcherExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(switcherToken) }

        guard let event = makeKeyDownEvent(
            key: "P",
            modifiers: [.command, .shift],
            keyCode: 35,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+Shift+P event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        wait(for: [paletteExpectation, switcherExpectation], timeout: 1.0)
        XCTAssertEqual(observedPaletteWindow?.windowNumber, window.windowNumber)
    }

    func testCmdPStillRequestsCommandPaletteSwitcherWhilePaletteIsVisible() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId) else {
            XCTFail("Expected test window")
            return
        }

        appDelegate.setCommandPaletteVisible(true, for: window)
        defer { appDelegate.setCommandPaletteVisible(false, for: window) }

        let switcherExpectation = expectation(description: "Expected switcher request while command palette is visible")
        var observedSwitcherWindow: NSWindow?
        let switcherToken = NotificationCenter.default.addObserver(
            forName: .commandPaletteSwitcherRequested,
            object: nil,
            queue: nil
        ) { notification in
            observedSwitcherWindow = notification.object as? NSWindow
            switcherExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(switcherToken) }

        guard let event = makeKeyDownEvent(
            key: "p",
            modifiers: [.command],
            keyCode: 35,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+P event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        wait(for: [switcherExpectation], timeout: 1.0)
        XCTAssertEqual(observedSwitcherWindow?.windowNumber, window.windowNumber)
    }

    func testCmdShiftPStillRequestsCommandPaletteCommandsWhilePaletteIsVisible() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId) else {
            XCTFail("Expected test window")
            return
        }

        appDelegate.setCommandPaletteVisible(true, for: window)
        defer { appDelegate.setCommandPaletteVisible(false, for: window) }

        let paletteExpectation = expectation(description: "Expected commands request while command palette is visible")
        var observedPaletteWindow: NSWindow?
        let paletteToken = NotificationCenter.default.addObserver(
            forName: .commandPaletteRequested,
            object: nil,
            queue: nil
        ) { notification in
            observedPaletteWindow = notification.object as? NSWindow
            paletteExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(paletteToken) }

        guard let event = makeKeyDownEvent(
            key: "P",
            modifiers: [.command, .shift],
            keyCode: 35,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+Shift+P event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        wait(for: [paletteExpectation], timeout: 1.0)
        XCTAssertEqual(observedPaletteWindow?.windowNumber, window.windowNumber)
    }

    func testCmdFFocusedBrowserKeepsWebContentFirstRouting() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId),
              let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace,
              manager.openBrowser(inWorkspace: workspace.id) != nil else {
            XCTFail("Expected focused browser panel")
            return
        }

        XCTAssertNotNil(manager.focusedBrowserPanel)
        XCTAssertNil(manager.focusedBrowserPanel?.searchState)

        guard let event = makeKeyDownEvent(
            key: "f",
            modifiers: [.command],
            keyCode: 3,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+F event")
            return
        }

#if DEBUG
        XCTAssertFalse(
            appDelegate.debugHandleCustomShortcut(event: event),
            "Cmd+F should fall through so browser web content gets first chance"
        )
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        XCTAssertNil(manager.focusedBrowserPanel?.searchState)
    }

    func testCmdPhysicalWWithDvorakCharactersDoesNotTriggerClosePanelShortcut() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer {
            SettingsWindowController.shared.close()
            closeWindow(withId: windowId)
        }

        guard let window = window(withId: windowId),
              let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace else {
            XCTFail("Expected test window and workspace")
            return
        }

        let panelCountBefore = workspace.panels.count

        // Dvorak: physical ANSI "W" key can produce ",". This must not match the Cmd+W
        // close-panel shortcut. NOTE: Cmd+, is independently bound to Settings
        // (`.openSettings`'s default shortcut, see KeyboardShortcutSettings.swift) --
        // that is a real, unrelated shortcut and legitimately fires for this character,
        // so this test only asserts on what it actually cares about (the panel wasn't
        // closed), not on `debugHandleCustomShortcut`'s return value.
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: ",",
            charactersIgnoringModifiers: ",",
            isARepeat: false,
            keyCode: 13 // kVK_ANSI_W
        ) else {
            XCTFail("Failed to construct Dvorak Cmd+, event on physical ANSI W key")
            return
        }

#if DEBUG
        _ = appDelegate.debugHandleCustomShortcut(event: event)
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
        XCTAssertEqual(workspace.panels.count, panelCountBefore, "Physical W producing a Dvorak comma must not close the focused panel")
    }

    func testCmdIStillTriggersShowNotificationsShortcut() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId) else {
            XCTFail("Expected test window")
            return
        }

        withTemporaryShortcut(action: .showNotifications) {
            guard let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.command],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: "i",
                charactersIgnoringModifiers: "i",
                isARepeat: false,
                keyCode: 34 // kVK_ANSI_I
            ) else {
                XCTFail("Failed to construct Cmd+I event")
                return
            }

#if DEBUG
            XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
            XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
        }
    }

    func testCmdUnshiftedSymbolDoesNotMatchDigitShortcut() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId) else {
            XCTFail("Expected test window")
            return
        }

        withTemporaryShortcut(
            action: .showNotifications,
            shortcut: StoredShortcut(key: "8", command: true, shift: false, option: false, control: false)
        ) {
            // Some non-US layouts can produce "*" without Shift.
            // This must not be coerced into "8" for a Cmd+8 shortcut match.
            guard let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.command],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: "*",
                charactersIgnoringModifiers: "*",
                isARepeat: false,
                keyCode: 30 // kVK_ANSI_RightBracket
            ) else {
                XCTFail("Failed to construct Cmd+* event")
                return
            }

#if DEBUG
            XCTAssertFalse(appDelegate.debugHandleCustomShortcut(event: event))
#else
            XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
        }
    }

    func testCmdDigitShortcutFallsBackByKeyCodeOnSymbolFirstLayouts() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId) else {
            XCTFail("Expected test window")
            return
        }

        withTemporaryShortcut(
            action: .showNotifications,
            shortcut: StoredShortcut(key: "1", command: true, shift: false, option: false, control: false)
        ) {
            // Symbol-first layouts (for example AZERTY) can report "&" for the ANSI 1 key.
            // Cmd+1 shortcuts should still match via keyCode fallback in this case.
            guard let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.command],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: "&",
                charactersIgnoringModifiers: "&",
                isARepeat: false,
                keyCode: 18 // kVK_ANSI_1
            ) else {
                XCTFail("Failed to construct Cmd+& event on ANSI 1 key")
                return
            }

#if DEBUG
            XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
            XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
        }
    }

    func testCmdShiftNonDigitKeySymbolDoesNotMatchShiftedDigitShortcut() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId) else {
            XCTFail("Expected test window")
            return
        }

        withTemporaryShortcut(
            action: .showNotifications,
            shortcut: StoredShortcut(key: "8", command: true, shift: true, option: false, control: false)
        ) {
            // Avoid unrelated default Cmd+Shift+] handling for this assertion.
            withTemporaryShortcut(
                action: .nextSurface,
                shortcut: StoredShortcut(key: "x", command: true, shift: true, option: false, control: false)
            ) {
                // On some non-US layouts, Shift+RightBracket can produce "*".
                // This must not be interpreted as Shift+8.
                guard let event = NSEvent.keyEvent(
                    with: .keyDown,
                    location: .zero,
                    modifierFlags: [.command, .shift],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber,
                    context: nil,
                    characters: "*",
                    charactersIgnoringModifiers: "*",
                    isARepeat: false,
                    keyCode: 30 // kVK_ANSI_RightBracket
                ) else {
                    XCTFail("Failed to construct Cmd+Shift+* event from non-digit key")
                    return
                }

#if DEBUG
                XCTAssertFalse(appDelegate.debugHandleCustomShortcut(event: event))
#else
                XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
            }
        }
    }

    func testCmdShiftDigitShortcutMatchesShiftedDigitKey() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId) else {
            XCTFail("Expected test window")
            return
        }

        withTemporaryShortcut(
            action: .showNotifications,
            shortcut: StoredShortcut(key: "8", command: true, shift: true, option: false, control: false)
        ) {
            guard let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.command, .shift],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: "*",
                charactersIgnoringModifiers: "*",
                isARepeat: false,
                keyCode: 28 // kVK_ANSI_8
            ) else {
                XCTFail("Failed to construct Cmd+Shift+8 event")
                return
            }

#if DEBUG
            XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
            XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
        }
    }

    func testCmdShiftQuestionMarkMatchesSlashShortcut() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId) else {
            XCTFail("Expected test window")
            return
        }

        withTemporaryShortcut(
            action: .triggerFlash,
            shortcut: StoredShortcut(key: "/", command: true, shift: true, option: false, control: false)
        ) {
            guard let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.command, .shift],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: "?",
                charactersIgnoringModifiers: "?",
                isARepeat: false,
                keyCode: 44 // kVK_ANSI_Slash
            ) else {
                XCTFail("Failed to construct Cmd+Shift+/ event")
                return
            }

#if DEBUG
            XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
            XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
        }
    }

    func testCmdShiftISOAngleBracketDoesNotMatchCommaShortcut() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId) else {
            XCTFail("Expected test window")
            return
        }

        withTemporaryShortcut(
            action: .showNotifications,
            shortcut: StoredShortcut(key: ",", command: true, shift: true, option: false, control: false)
        ) {
            guard let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.command, .shift],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: "<",
                charactersIgnoringModifiers: "<",
                isARepeat: false,
                keyCode: 10 // kVK_ISO_Section
            ) else {
                XCTFail("Failed to construct Cmd+Shift+< event from ISO key")
                return
            }

#if DEBUG
            XCTAssertFalse(appDelegate.debugHandleCustomShortcut(event: event))
#else
            XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
        }
    }

    func testCmdShiftRightBracketCanFallbackByKeyCodeOnNonUSLayouts() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId) else {
            XCTFail("Expected test window")
            return
        }

        withTemporaryShortcut(action: .nextSurface) {
            // Non-US layouts can report "*" (or other symbols) for kVK_ANSI_RightBracket with Shift.
            // Shortcut matching should still allow Cmd+Shift+] via keyCode fallback.
            guard let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.command, .shift],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: "*",
                charactersIgnoringModifiers: "*",
                isARepeat: false,
                keyCode: 30 // kVK_ANSI_RightBracket
            ) else {
                XCTFail("Failed to construct non-US Cmd+Shift+] event")
                return
            }

#if DEBUG
            XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
            XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
        }
    }

    func testCmdPhysicalOWithDvorakCharactersTriggersRenameTabShortcut() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId) else {
            XCTFail("Expected test window")
            return
        }

        let renameTabExpectation = expectation(description: "Expected rename tab request for semantic Cmd+R")
        var observedRenameTabWindow: NSWindow?
        let renameTabToken = NotificationCenter.default.addObserver(
            forName: .commandPaletteRenameTabRequested,
            object: nil,
            queue: nil
        ) { notification in
            observedRenameTabWindow = notification.object as? NSWindow
            renameTabExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(renameTabToken) }

        let switcherExpectation = expectation(description: "Cmd+R should not trigger command palette switcher")
        switcherExpectation.isInverted = true
        let switcherToken = NotificationCenter.default.addObserver(
            forName: .commandPaletteSwitcherRequested,
            object: nil,
            queue: nil
        ) { _ in
            switcherExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(switcherToken) }

        withTemporaryShortcut(action: .renameTab) {
            // Dvorak: physical ANSI "O" key can produce "r".
            // This should behave as semantic Cmd+R (rename tab), not Cmd+P.
            guard let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.command],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: "r",
                charactersIgnoringModifiers: "r",
                isARepeat: false,
                keyCode: 31 // kVK_ANSI_O
            ) else {
                XCTFail("Failed to construct Dvorak Cmd+R event on physical ANSI O key")
                return
            }

#if DEBUG
            XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
            XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
        }

        wait(for: [renameTabExpectation, switcherExpectation], timeout: 1.0)
        XCTAssertEqual(observedRenameTabWindow?.windowNumber, window.windowNumber)
    }

    func testCmdPhysicalRWithDvorakCharactersTriggersCommandPaletteSwitcher() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId) else {
            XCTFail("Expected test window")
            return
        }

        let switcherExpectation = expectation(description: "Expected command palette switcher request for semantic Cmd+P")
        var observedSwitcherWindow: NSWindow?
        let switcherToken = NotificationCenter.default.addObserver(
            forName: .commandPaletteSwitcherRequested,
            object: nil,
            queue: nil
        ) { notification in
            observedSwitcherWindow = notification.object as? NSWindow
            switcherExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(switcherToken) }

        let renameTabExpectation = expectation(description: "Physical R on Dvorak should not trigger rename tab")
        renameTabExpectation.isInverted = true
        let renameTabToken = NotificationCenter.default.addObserver(
            forName: .commandPaletteRenameTabRequested,
            object: nil,
            queue: nil
        ) { _ in
            renameTabExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(renameTabToken) }

        // Dvorak: physical ANSI "R" key can produce "p".
        // This should behave as semantic Cmd+P (palette switcher), not Cmd+R.
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "p",
            charactersIgnoringModifiers: "p",
            isARepeat: false,
            keyCode: 15 // kVK_ANSI_R
        ) else {
            XCTFail("Failed to construct Dvorak Cmd+P event on physical ANSI R key")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        wait(for: [switcherExpectation, renameTabExpectation], timeout: 1.0)
        XCTAssertEqual(observedSwitcherWindow?.windowNumber, window.windowNumber)
    }

    func testCmdShiftRRequestsRenameWorkspaceInCommandPalette() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer {
            closeWindow(withId: windowId)
        }

        guard let window = window(withId: windowId) else {
            XCTFail("Expected test window")
            return
        }

        let workspaceExpectation = expectation(description: "Expected command palette rename workspace notification")
        var observedWorkspaceWindow: NSWindow?
        var didObserveWorkspaceNotification = false
        let workspaceToken = NotificationCenter.default.addObserver(
            forName: .commandPaletteRenameWorkspaceRequested,
            object: nil,
            queue: nil
        ) { notification in
            guard !didObserveWorkspaceNotification else { return }
            didObserveWorkspaceNotification = true
            observedWorkspaceWindow = notification.object as? NSWindow
            workspaceExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(workspaceToken) }

        let renameTabExpectation = expectation(description: "Rename tab notification should not fire for Cmd+Shift+R")
        renameTabExpectation.isInverted = true
        let renameTabToken = NotificationCenter.default.addObserver(
            forName: .commandPaletteRenameTabRequested,
            object: nil,
            queue: nil
        ) { _ in
            renameTabExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(renameTabToken) }

        guard let event = makeKeyDownEvent(
            key: "r",
            modifiers: [.command, .shift],
            keyCode: 15, // kVK_ANSI_R
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+Shift+R event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        wait(for: [workspaceExpectation, renameTabExpectation], timeout: 1.0)
        XCTAssertEqual(observedWorkspaceWindow?.windowNumber, window.windowNumber)
    }

    func testCmdShiftERequestsEditWorkspaceDescriptionInCommandPalette() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer {
            closeWindow(withId: windowId)
        }

        guard let window = window(withId: windowId) else {
            XCTFail("Expected test window")
            return
        }

        let descriptionExpectation = expectation(description: "Expected command palette edit workspace description notification")
        var observedWorkspaceWindow: NSWindow?
        var didObserveDescriptionNotification = false
        let descriptionToken = NotificationCenter.default.addObserver(
            forName: .commandPaletteEditWorkspaceDescriptionRequested,
            object: nil,
            queue: nil
        ) { notification in
            guard !didObserveDescriptionNotification else { return }
            didObserveDescriptionNotification = true
            observedWorkspaceWindow = notification.object as? NSWindow
            descriptionExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(descriptionToken) }

        let renameWorkspaceExpectation = expectation(description: "Rename workspace notification should not fire for Cmd+Shift+E")
        renameWorkspaceExpectation.isInverted = true
        let renameWorkspaceToken = NotificationCenter.default.addObserver(
            forName: .commandPaletteRenameWorkspaceRequested,
            object: nil,
            queue: nil
        ) { _ in
            renameWorkspaceExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(renameWorkspaceToken) }

        guard let event = makeKeyDownEvent(
            key: "e",
            modifiers: [.command, .shift],
            keyCode: 14, // kVK_ANSI_E
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+Shift+E event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        wait(for: [descriptionExpectation, renameWorkspaceExpectation], timeout: 1.0)
        XCTAssertEqual(observedWorkspaceWindow?.windowNumber, window.windowNumber)
    }

    func testEscapeDismissesVisibleCommandPaletteAndIsConsumed() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer {
            closeWindow(withId: windowId)
        }

        guard let window = window(withId: windowId) else {
            XCTFail("Expected test window")
            return
        }

        appDelegate.setCommandPaletteVisible(true, for: window)
        defer {
            appDelegate.setCommandPaletteVisible(false, for: window)
        }

        let dismissExpectation = expectation(description: "Expected command palette toggle notification for Escape dismiss")
        var observedDismissWindow: NSWindow?
        let dismissToken = NotificationCenter.default.addObserver(
            forName: .commandPaletteToggleRequested,
            object: nil,
            queue: nil
        ) { notification in
            observedDismissWindow = notification.object as? NSWindow
            dismissExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(dismissToken) }

        guard let event = makeKeyDownEvent(
            key: "\u{1b}",
            modifiers: [],
            keyCode: 53, // kVK_Escape
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Escape event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        wait(for: [dismissExpectation], timeout: 1.0)
        XCTAssertEqual(observedDismissWindow?.windowNumber, window.windowNumber)
    }

    func testEscapeDoesNotDismissCommandPaletteWhenInputHasMarkedText() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer {
            closeWindow(withId: windowId)
        }

        guard let window = window(withId: windowId) else {
            XCTFail("Expected test window")
            return
        }

        let fieldEditor = CommandPaletteMarkedTextFieldEditor(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        fieldEditor.isFieldEditor = true
        fieldEditor.hasMarkedTextForTesting = true
        window.contentView?.addSubview(fieldEditor)
        XCTAssertTrue(window.makeFirstResponder(fieldEditor))

        appDelegate.setCommandPaletteVisible(true, for: window)
        defer {
            appDelegate.setCommandPaletteVisible(false, for: window)
            fieldEditor.removeFromSuperview()
        }

        let dismissExpectation = expectation(
            description: "Escape should not dismiss command palette while IME marked text is active"
        )
        dismissExpectation.isInverted = true
        let dismissToken = NotificationCenter.default.addObserver(
            forName: .commandPaletteToggleRequested,
            object: nil,
            queue: nil
        ) { notification in
            guard let dismissWindow = notification.object as? NSWindow,
                  dismissWindow.windowNumber == window.windowNumber else { return }
            dismissExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(dismissToken) }

        guard let escapeEvent = makeKeyDownEvent(
            key: "\u{1b}",
            modifiers: [],
            keyCode: 53,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Escape event")
            return
        }

#if DEBUG
        XCTAssertFalse(
            appDelegate.debugHandleCustomShortcut(event: escapeEvent),
            "Escape should pass through to IME composition instead of dismissing command palette"
        )
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        wait(for: [dismissExpectation], timeout: 0.2)
    }

    func testEscapeDismissesCommandPaletteWhenVisibilitySyncLagsAfterOpenRequest() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer {
            closeWindow(withId: windowId)
        }

        guard let window = window(withId: windowId) else {
            XCTFail("Expected test window")
            return
        }

        let dismissExpectation = expectation(description: "Expected command palette dismiss notification for Escape")
        var observedDismissWindow: NSWindow?
        let dismissToken = NotificationCenter.default.addObserver(
            forName: .commandPaletteToggleRequested,
            object: nil,
            queue: nil
        ) { notification in
            observedDismissWindow = notification.object as? NSWindow
            dismissExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(dismissToken) }

#if DEBUG
        appDelegate.debugMarkCommandPaletteOpenPending(window: window)
#else
        XCTFail("debugMarkCommandPaletteOpenPending is only available in DEBUG")
#endif

        // Model the normal open-palette state so the test reads like the user-facing scenario.
        appDelegate.setCommandPaletteVisible(true, for: window)

        guard let escapeEvent = makeKeyDownEvent(
            key: "\u{1b}",
            modifiers: [],
            keyCode: 53,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Escape event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: escapeEvent))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        wait(for: [dismissExpectation], timeout: 1.0)
        XCTAssertEqual(observedDismissWindow?.windowNumber, window.windowNumber)
    }

    func testArrowNavigationRoutesWhileCommandPaletteOverlayIsInteractiveBeforeVisibilitySync() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer {
            closeWindow(withId: windowId)
        }

        guard let window = window(withId: windowId) else {
            XCTFail("Expected test window")
            return
        }

        // `createMainWindow()` already installs a real command palette overlay
        // container (as a sibling of contentView, not nested inside it -- see
        // `findRealCommandPaletteOverlayContainer`). Simulating "the overlay is still
        // visually interactive" must mutate that real view directly: adding a second,
        // decoy view with the same identifier under contentView does not shadow it,
        // since AppDelegate's tree walk finds the real one first and never reaches a
        // separately-added decoy.
        guard let overlayContainer = findRealCommandPaletteOverlayContainer(in: window) else {
            XCTFail("Expected createMainWindow() to install a real command palette overlay container")
            return
        }
        let originalAlpha = overlayContainer.alphaValue
        let originalHidden = overlayContainer.isHidden
        overlayContainer.alphaValue = 1
        overlayContainer.isHidden = false

        let fieldEditor = CommandPaletteMarkedTextFieldEditor(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        fieldEditor.isFieldEditor = true
        overlayContainer.addSubview(fieldEditor)
        XCTAssertTrue(window.makeFirstResponder(fieldEditor))

        appDelegate.setCommandPaletteVisible(false, for: window)
        defer {
            fieldEditor.removeFromSuperview()
            overlayContainer.alphaValue = originalAlpha
            overlayContainer.isHidden = originalHidden
        }

        let moveExpectation = expectation(
            description: "Expected command palette move-selection notification while overlay is interactive"
        )
        var observedDelta: Int?
        var observedWindow: NSWindow?
        let moveToken = NotificationCenter.default.addObserver(
            forName: .commandPaletteMoveSelection,
            object: nil,
            queue: nil
        ) { notification in
            observedWindow = notification.object as? NSWindow
            observedDelta = notification.userInfo?["delta"] as? Int
            moveExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(moveToken) }

        guard let downArrowEvent = makeKeyDownEvent(
            key: String(UnicodeScalar(NSDownArrowFunctionKey)!),
            modifiers: [],
            keyCode: 125,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Down Arrow event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: downArrowEvent))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        wait(for: [moveExpectation], timeout: 1.0)
        XCTAssertEqual(observedWindow?.windowNumber, window.windowNumber)
        XCTAssertEqual(observedDelta, 1)
    }

    func testControlKDoesNotRoutePaletteMoveSelectionWhenSearchFieldIsFocused() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer {
            closeWindow(withId: windowId)
        }

        guard let window = window(withId: windowId),
              let contentView = window.contentView else {
            XCTFail("Expected test window")
            return
        }

        let overlayContainer = NSView(frame: contentView.bounds)
        overlayContainer.identifier = commandPaletteOverlayContainerIdentifier
        overlayContainer.alphaValue = 1
        overlayContainer.isHidden = false
        contentView.addSubview(overlayContainer)

        let fieldEditor = CommandPaletteMarkedTextFieldEditor(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        fieldEditor.isFieldEditor = true
        overlayContainer.addSubview(fieldEditor)
        XCTAssertTrue(window.makeFirstResponder(fieldEditor))

        appDelegate.setCommandPaletteVisible(false, for: window)
        defer {
            overlayContainer.removeFromSuperview()
            fieldEditor.removeFromSuperview()
        }

        let moveExpectation = expectation(
            description: "Ctrl+K should not be rerouted as command palette move-selection"
        )
        moveExpectation.isInverted = true
        let moveToken = NotificationCenter.default.addObserver(
            forName: .commandPaletteMoveSelection,
            object: nil,
            queue: nil
        ) { _ in
            moveExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(moveToken) }

        guard let controlKEvent = makeKeyDownEvent(
            key: "\u{0b}",
            modifiers: [.control],
            keyCode: 40,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Ctrl+K event")
            return
        }

#if DEBUG
        XCTAssertFalse(appDelegate.debugHandleCustomShortcut(event: controlKEvent))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        wait(for: [moveExpectation], timeout: 0.2)
    }

    func testEscapeDismissesCommandPaletteWhenVisibilityStateStaysStalePastInitialPendingWindow() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer {
            closeWindow(withId: windowId)
        }

        guard let window = window(withId: windowId) else {
            XCTFail("Expected test window")
            return
        }

#if DEBUG
        XCTAssertTrue(
            appDelegate.debugSetCommandPalettePendingOpenAge(window: window, age: 1.3),
            "Expected to backdate pending-open age for stale visibility test"
        )
#else
        XCTFail("debugSetCommandPalettePendingOpenAge is only available in DEBUG")
#endif

        // Simulate stale app-level visibility bookkeeping.
        appDelegate.setCommandPaletteVisible(false, for: window)

        let dismissExpectation = expectation(description: "Escape should dismiss stale-state command palette after delay")
        var observedDismissWindow: NSWindow?
        let dismissToken = NotificationCenter.default.addObserver(
            forName: .commandPaletteToggleRequested,
            object: nil,
            queue: nil
        ) { notification in
            observedDismissWindow = notification.object as? NSWindow
            dismissExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(dismissToken) }

        guard let escapeEvent = makeKeyDownEvent(
            key: "\u{1b}",
            modifiers: [],
            keyCode: 53,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Escape event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: escapeEvent))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        wait(for: [dismissExpectation], timeout: 1.0)
        XCTAssertEqual(observedDismissWindow?.windowNumber, window.windowNumber)
    }

    func testEscapeDismissesCommandPaletteWhenVisibilityStateRemainsStaleForExtendedDelay() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer {
            closeWindow(withId: windowId)
        }

        guard let window = window(withId: windowId) else {
            XCTFail("Expected test window")
            return
        }

#if DEBUG
        XCTAssertTrue(
            appDelegate.debugSetCommandPalettePendingOpenAge(window: window, age: 6.25),
            "Expected to backdate pending-open age for extended stale visibility test"
        )
#else
        XCTFail("debugSetCommandPalettePendingOpenAge is only available in DEBUG")
#endif

        // Simulate stale app-level visibility bookkeeping for a longer user delay.
        appDelegate.setCommandPaletteVisible(false, for: window)

        let dismissExpectation = expectation(description: "Escape should dismiss stale-state command palette after extended delay")
        var observedDismissWindow: NSWindow?
        let dismissToken = NotificationCenter.default.addObserver(
            forName: .commandPaletteToggleRequested,
            object: nil,
            queue: nil
        ) { notification in
            observedDismissWindow = notification.object as? NSWindow
            dismissExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(dismissToken) }

        guard let escapeEvent = makeKeyDownEvent(
            key: "\u{1b}",
            modifiers: [],
            keyCode: 53,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Escape event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: escapeEvent))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        wait(for: [dismissExpectation], timeout: 1.0)
        XCTAssertEqual(observedDismissWindow?.windowNumber, window.windowNumber)
    }

    func testEscapeDoesNotConsumeWhenMenuTriggeredPendingOpenStateExpires() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer {
            closeWindow(withId: windowId)
        }

        guard let window = window(withId: windowId) else {
            XCTFail("Expected test window")
            return
        }

        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

#if DEBUG
        XCTAssertTrue(
            appDelegate.debugSetCommandPalettePendingOpenAge(window: window, age: 20.0),
            "Expected to seed an expired pending-open request state"
        )
#else
        XCTFail("debugSetCommandPalettePendingOpenAge is only available in DEBUG")
#endif

        appDelegate.setCommandPaletteVisible(false, for: window)

        let dismissExpectation = expectation(description: "No dismiss notification for expired pending-open state")
        dismissExpectation.isInverted = true
        let dismissToken = NotificationCenter.default.addObserver(
            forName: .commandPaletteToggleRequested,
            object: nil,
            queue: nil
        ) { _ in
            dismissExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(dismissToken) }

        guard let escapeEvent = makeKeyDownEvent(
            key: "\u{1b}",
            modifiers: [],
            keyCode: 53,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Escape event")
            return
        }

#if DEBUG
        XCTAssertFalse(
            appDelegate.debugHandleCustomShortcut(event: escapeEvent),
            "Escape should pass through once pending-open grace has expired"
        )
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        wait(for: [dismissExpectation], timeout: 0.2)
    }

    func testTerminalMarkedTextBypassesRecentPalettePendingOpenEscapeGrace() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        guard let window = window(withId: windowId),
              let workspace = appDelegate.tabManagerFor(windowId: windowId)?.selectedWorkspace,
              let panelId = workspace.focusedPanelId,
              let terminalPanel = workspace.terminalPanel(for: panelId),
              let terminalView = surfaceView(in: terminalPanel.hostedView) else {
            closeWindow(withId: windowId)
            XCTFail("Expected focused terminal surface")
            return
        }
        defer {
            terminalView.markedText = NSMutableAttributedString()
            appDelegate.setCommandPaletteVisible(true, for: window)
            appDelegate.setCommandPaletteVisible(false, for: window)
            closeWindow(withId: windowId)
        }

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        terminalPanel.hostedView.suppressReparentFocus()
        XCTAssertTrue(window.makeFirstResponder(terminalView))
        terminalPanel.hostedView.clearSuppressReparentFocus()
        terminalView.markedText = NSMutableAttributedString(string: "composing")
        XCTAssertTrue(terminalView.hasMarkedText())
        XCTAssertTrue(window.firstResponder === terminalView)

#if DEBUG
        XCTAssertTrue(
            appDelegate.debugSetCommandPalettePendingOpenAge(window: window, age: 0.1),
            "Expected deterministic recent pending-open state"
        )
#else
        XCTFail("debugSetCommandPalettePendingOpenAge is only available in DEBUG")
#endif
        appDelegate.setCommandPaletteVisible(false, for: window)

        var toggleCount = 0
        var dismissCount = 0
        let toggleToken = NotificationCenter.default.addObserver(
            forName: .commandPaletteToggleRequested,
            object: nil,
            queue: nil
        ) { notification in
            guard notification.object as? NSWindow === window else { return }
            toggleCount += 1
        }
        let dismissToken = NotificationCenter.default.addObserver(
            forName: .commandPaletteDismissRequested,
            object: nil,
            queue: nil
        ) { notification in
            guard notification.object as? NSWindow === window else { return }
            dismissCount += 1
        }
        defer {
            NotificationCenter.default.removeObserver(toggleToken)
            NotificationCenter.default.removeObserver(dismissToken)
        }

        guard let escapeEvent = makeKeyDownEvent(
            key: "\u{1b}",
            modifiers: [],
            keyCode: 53,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Escape event")
            return
        }

#if DEBUG
        XCTAssertFalse(
            appDelegate.debugHandleCustomShortcut(event: escapeEvent),
            "Terminal IME composition must take precedence over pending-open Escape grace"
        )
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
        XCTAssertEqual(toggleCount, 0)
        XCTAssertEqual(dismissCount, 0)
    }

    func testEscapeDismissesMenuTriggeredCommandPaletteWhenVisibilitySyncIsStale() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer {
            closeWindow(withId: windowId)
        }

        guard let window = window(withId: windowId) else {
            XCTFail("Expected test window")
            return
        }

        // Reproduce the menu-command path (Cmd+Shift+P/Cmd+P) routed via AppDelegate.
        appDelegate.requestCommandPaletteCommands(
            preferredWindow: window,
            source: "test.menuCommandPalette"
        )
        // Simulate delayed/stale visibility sync from SwiftUI overlay state.
        appDelegate.setCommandPaletteVisible(false, for: window)
#if DEBUG
        XCTAssertTrue(
            appDelegate.debugSetCommandPalettePendingOpenAge(window: window, age: 0.1),
            "Expected deterministic pending-open state for menu-triggered stale-visibility path"
        )
#else
        XCTFail("debugSetCommandPalettePendingOpenAge is only available in DEBUG")
#endif

        let dismissExpectation = expectation(description: "Expected command palette dismiss notification for menu-triggered stale visibility")
        var observedDismissWindow: NSWindow?
        let dismissToken = NotificationCenter.default.addObserver(
            forName: .commandPaletteToggleRequested,
            object: nil,
            queue: nil
        ) { notification in
            observedDismissWindow = notification.object as? NSWindow
            dismissExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(dismissToken) }

        guard let escapeEvent = makeKeyDownEvent(
            key: "\u{1b}",
            modifiers: [],
            keyCode: 53,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Escape event")
            return
        }

#if DEBUG
        XCTAssertTrue(
            appDelegate.debugHandleCustomShortcut(event: escapeEvent),
            "Escape should still be consumed for menu-triggered command palette opens"
        )
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        wait(for: [dismissExpectation], timeout: 1.0)
        XCTAssertEqual(observedDismissWindow?.windowNumber, window.windowNumber)
    }

    func testEscapeRepeatIsConsumedImmediatelyAfterPaletteDismiss() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer {
            closeWindow(withId: windowId)
        }

        guard let window = window(withId: windowId) else {
            XCTFail("Expected test window")
            return
        }

        appDelegate.setCommandPaletteVisible(true, for: window)
        defer {
            appDelegate.setCommandPaletteVisible(false, for: window)
        }

        guard let firstEscape = makeKeyDownEvent(
            key: "\u{1b}",
            modifiers: [],
            keyCode: 53,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct first Escape event")
            return
        }

        guard let repeatedEscape = makeKeyDownEvent(
            key: "\u{1b}",
            modifiers: [],
            keyCode: 53,
            windowNumber: window.windowNumber,
            isARepeat: true
        ) else {
            XCTFail("Failed to construct repeated Escape event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: firstEscape))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        // Simulate the palette overlay synchronizing to closed state while the Escape key is still held.
        appDelegate.setCommandPaletteVisible(false, for: window)

#if DEBUG
        XCTAssertTrue(
            appDelegate.debugHandleCustomShortcut(event: repeatedEscape),
            "Repeated Escape immediately after dismiss should be consumed to prevent terminal passthrough"
        )
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
    }

    func testTerminalMarkedTextBypassesPostDismissEscapeSuppression() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        guard let window = window(withId: windowId),
              let workspace = appDelegate.tabManagerFor(windowId: windowId)?.selectedWorkspace,
              let panelId = workspace.focusedPanelId,
              let terminalPanel = workspace.terminalPanel(for: panelId),
              let terminalView = surfaceView(in: terminalPanel.hostedView) else {
            closeWindow(withId: windowId)
            XCTFail("Expected focused terminal surface")
            return
        }
        defer {
            terminalView.markedText = NSMutableAttributedString()
            appDelegate.setCommandPaletteVisible(false, for: window)
            closeWindow(withId: windowId)
        }

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        appDelegate.setCommandPaletteVisible(true, for: window)

        guard let firstEscape = makeKeyDownEvent(
            key: "\u{1b}",
            modifiers: [],
            keyCode: 53,
            windowNumber: window.windowNumber
        ), let repeatedEscape = makeKeyDownEvent(
            key: "\u{1b}",
            modifiers: [],
            keyCode: 53,
            windowNumber: window.windowNumber,
            isARepeat: true
        ) else {
            XCTFail("Failed to construct Escape events")
            return
        }

#if DEBUG
        XCTAssertTrue(
            appDelegate.debugHandleCustomShortcut(event: firstEscape),
            "The initial Escape must dismiss the visible palette and seed suppression"
        )
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
        appDelegate.setCommandPaletteVisible(false, for: window)

        terminalPanel.hostedView.suppressReparentFocus()
        XCTAssertTrue(window.makeFirstResponder(terminalView))
        terminalPanel.hostedView.clearSuppressReparentFocus()
        terminalView.markedText = NSMutableAttributedString(string: "composing")
        XCTAssertTrue(terminalView.hasMarkedText())
        XCTAssertTrue(window.firstResponder === terminalView)

#if DEBUG
        XCTAssertFalse(
            appDelegate.debugHandleCustomShortcut(event: repeatedEscape),
            "Terminal IME composition must take precedence over post-dismiss Escape suppression"
        )
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
    }

    func testEscapeKeyUpIsConsumedAfterPaletteDismissToPreventTerminalLeak() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer {
            closeWindow(withId: windowId)
        }

        guard let window = window(withId: windowId) else {
            XCTFail("Expected test window")
            return
        }

        appDelegate.setCommandPaletteVisible(true, for: window)
        defer {
            appDelegate.setCommandPaletteVisible(false, for: window)
        }

        guard let escapeKeyDown = makeKeyEvent(
            type: .keyDown,
            key: "\u{1b}",
            modifiers: [],
            keyCode: 53,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Escape keyDown event")
            return
        }

        guard let escapeKeyUp = makeKeyEvent(
            type: .keyUp,
            key: "\u{1b}",
            modifiers: [],
            keyCode: 53,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Escape keyUp event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleShortcutMonitorEvent(event: escapeKeyDown))
#else
        XCTFail("debugHandleShortcutMonitorEvent is only available in DEBUG")
#endif

        // Simulate the palette overlay synchronizing to closed state before Escape key-up arrives.
        appDelegate.setCommandPaletteVisible(false, for: window)

#if DEBUG
        XCTAssertTrue(
            appDelegate.debugHandleShortcutMonitorEvent(event: escapeKeyUp),
            "Escape keyUp after palette dismiss should be consumed to prevent terminal passthrough"
        )
#else
        XCTFail("debugHandleShortcutMonitorEvent is only available in DEBUG")
#endif
    }

    func testEscapeKeyUpIsConsumedAfterCmdPSwitcherDismiss() {
        assertEscapeKeyUpIsConsumedAfterCommandPaletteOpenRequest { appDelegate, window in
            appDelegate.requestCommandPaletteSwitcher(
                preferredWindow: window,
                source: "test.cmdP"
            )
        }
    }

    func testEscapeKeyUpIsConsumedAfterCmdShiftPCommandsDismiss() {
        assertEscapeKeyUpIsConsumedAfterCommandPaletteOpenRequest { appDelegate, window in
            appDelegate.requestCommandPaletteCommands(
                preferredWindow: window,
                source: "test.cmdShiftP"
            )
        }
    }

    func testEscapeDoesNotDismissPaletteInDifferentWindow() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let paletteWindowId = appDelegate.createMainWindow()
        let eventWindowId = appDelegate.createMainWindow()
        defer {
            closeWindow(withId: paletteWindowId)
            closeWindow(withId: eventWindowId)
        }

        guard let paletteWindow = window(withId: paletteWindowId),
              let eventWindow = window(withId: eventWindowId) else {
            XCTFail("Expected both test windows")
            return
        }

        appDelegate.setCommandPaletteVisible(true, for: paletteWindow)
        defer {
            appDelegate.setCommandPaletteVisible(false, for: paletteWindow)
        }

        let dismissExpectation = expectation(description: "Escape in another window should not dismiss palette")
        dismissExpectation.isInverted = true
        let dismissToken = NotificationCenter.default.addObserver(
            forName: .commandPaletteToggleRequested,
            object: nil,
            queue: nil
        ) { _ in
            dismissExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(dismissToken) }

        guard let escapeEvent = makeKeyDownEvent(
            key: "\u{1b}",
            modifiers: [],
            keyCode: 53,
            windowNumber: eventWindow.windowNumber
        ) else {
            XCTFail("Failed to construct Escape event")
            return
        }

#if DEBUG
        XCTAssertFalse(
            appDelegate.debugHandleCustomShortcut(event: escapeEvent),
            "Escape should remain scoped to the event window"
        )
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        wait(for: [dismissExpectation], timeout: 0.2)
    }

    func testCmdDigitDoesNotFallbackToOtherWindowWhenEventWindowContextIsMissing() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let firstWindowId = appDelegate.createMainWindow()
        let secondWindowId = appDelegate.createMainWindow()

        defer {
            closeWindow(withId: firstWindowId)
            closeWindow(withId: secondWindowId)
        }

        guard let firstManager = appDelegate.tabManagerFor(windowId: firstWindowId),
              let secondManager = appDelegate.tabManagerFor(windowId: secondWindowId),
              let secondWindow = window(withId: secondWindowId) else {
            XCTFail("Expected both window contexts to exist")
            return
        }

        _ = firstManager.addTab(select: true)
        _ = secondManager.addTab(select: true)
        guard let firstSelectedBefore = firstManager.selectedTabId,
              let secondSelectedBefore = secondManager.selectedTabId else {
            XCTFail("Expected selected tabs in both windows")
            return
        }

        secondWindow.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        // Force stale app-level manager to first window while keyboard event
        // references no known window.
        appDelegate.tabManager = firstManager

        guard let event = makeKeyDownEvent(
            key: "1",
            modifiers: [.command],
            keyCode: 18,
            windowNumber: Int.max
        ) else {
            XCTFail("Failed to construct Cmd+1 event")
            return
        }

#if DEBUG
        XCTAssertFalse(appDelegate.debugHandleCustomShortcut(event: event))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        XCTAssertEqual(firstManager.selectedTabId, firstSelectedBefore, "Unresolved event window must not route Cmd+1 into stale manager")
        XCTAssertEqual(secondManager.selectedTabId, secondSelectedBefore, "Unresolved event window must not route Cmd+1 into key/main fallback manager")
        XCTAssertTrue(appDelegate.tabManager === firstManager, "Unresolved event window should not retarget active manager")
    }

    func testCmdNDoesNotFallbackToOtherWindowWhenEventWindowContextIsMissing() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let firstWindowId = appDelegate.createMainWindow()
        let secondWindowId = appDelegate.createMainWindow()

        defer {
            closeWindow(withId: firstWindowId)
            closeWindow(withId: secondWindowId)
        }

        guard let firstManager = appDelegate.tabManagerFor(windowId: firstWindowId),
              let secondManager = appDelegate.tabManagerFor(windowId: secondWindowId),
              let secondWindow = window(withId: secondWindowId) else {
            XCTFail("Expected both window contexts to exist")
            return
        }

        secondWindow.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        let firstCount = firstManager.tabs.count
        let secondCount = secondManager.tabs.count
        appDelegate.tabManager = firstManager

        guard let event = makeKeyDownEvent(
            key: "n",
            modifiers: [.command],
            keyCode: 45,
            windowNumber: Int.max
        ) else {
            XCTFail("Failed to construct Cmd+N event")
            return
        }

#if DEBUG
        XCTAssertFalse(appDelegate.debugHandleCustomShortcut(event: event))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        XCTAssertEqual(firstManager.tabs.count, firstCount, "Unresolved event window must not create workspace in stale manager")
        XCTAssertEqual(secondManager.tabs.count, secondCount, "Unresolved event window must not create workspace in fallback window")
        XCTAssertTrue(appDelegate.tabManager === firstManager, "Unresolved event window should not retarget active manager")
    }

    func testCmdShiftMReturnsFalseWhenNoFocusedTerminalCanHandle() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        // Force unresolved shortcut routing context and no active manager.
        appDelegate.tabManager = nil

        guard let event = makeKeyDownEvent(
            key: "m",
            modifiers: [.command, .shift],
            keyCode: 46, // kVK_ANSI_M
            windowNumber: Int.max
        ) else {
            XCTFail("Failed to construct Cmd+Shift+M event")
            return
        }

#if DEBUG
        XCTAssertFalse(
            appDelegate.debugHandleCustomShortcut(event: event),
            "Cmd+Shift+M should not be consumed when no terminal can toggle copy mode"
        )
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
    }

    func testPresentPreferencesWindowShowsCustomSettingsWindowAndActivates() {
        var showFallbackSettingsWindowCallCount = 0
        var activateApplicationCallCount = 0
        var receivedNavigationTargets: [SettingsNavigationTarget?] = []

        AppDelegate.presentPreferencesWindow(
            showFallbackSettingsWindow: { navigationTarget in
                receivedNavigationTargets.append(navigationTarget)
                showFallbackSettingsWindowCallCount += 1
            },
            activateApplication: {
                activateApplicationCallCount += 1
            }
        )

        XCTAssertEqual(showFallbackSettingsWindowCallCount, 1)
        XCTAssertEqual(activateApplicationCallCount, 1)
        XCTAssertEqual(receivedNavigationTargets, [nil])
    }

    func testPresentPreferencesWindowSupportsRepeatedCalls() {
        var showFallbackSettingsWindowCallCount = 0
        var activateApplicationCallCount = 0
        var receivedNavigationTargets: [SettingsNavigationTarget?] = []

        AppDelegate.presentPreferencesWindow(
            showFallbackSettingsWindow: { navigationTarget in
                receivedNavigationTargets.append(navigationTarget)
                showFallbackSettingsWindowCallCount += 1
            },
            activateApplication: {
                activateApplicationCallCount += 1
            }
        )

        AppDelegate.presentPreferencesWindow(
            showFallbackSettingsWindow: { navigationTarget in
                receivedNavigationTargets.append(navigationTarget)
                showFallbackSettingsWindowCallCount += 1
            },
            activateApplication: {
                activateApplicationCallCount += 1
            }
        )

        XCTAssertEqual(showFallbackSettingsWindowCallCount, 2)
        XCTAssertEqual(activateApplicationCallCount, 2)
        XCTAssertEqual(receivedNavigationTargets, [nil, nil])
    }

    func testPresentPreferencesWindowForwardsNavigationTarget() {
        var receivedNavigationTarget: SettingsNavigationTarget?
        var activateApplicationCallCount = 0

        AppDelegate.presentPreferencesWindow(
            navigationTarget: .keyboardShortcuts,
            showFallbackSettingsWindow: { navigationTarget in
                receivedNavigationTarget = navigationTarget
            },
            activateApplication: {
                activateApplicationCallCount += 1
            }
        )

        XCTAssertEqual(receivedNavigationTarget, .keyboardShortcuts)
        XCTAssertEqual(activateApplicationCallCount, 1)
    }

    // MARK: - Non-Latin keyboard layout shortcut tests

    func testBrowserFirstFindShortcutRoutingRecognizesFindCommandFamily() {
        let cases: [(name: String, modifiers: NSEvent.ModifierFlags, chars: String, keyCode: UInt16)] = [
            ("cmd-f", [.command], "f", 3),
            ("cmd-g", [.command], "g", 5),
            ("cmd-shift-g", [.command, .shift], "g", 5),
            ("cmd-shift-f", [.command, .shift], "f", 3),
            ("cmd-e", [.command], "e", 14),
        ]

        for testCase in cases {
            let event = makeKeyEvent(
                modifierFlags: testCase.modifiers,
                characters: testCase.chars,
                charactersIgnoringModifiers: testCase.chars,
                keyCode: testCase.keyCode
            )
            XCTAssertTrue(
                shouldRouteBrowserFindCommandEquivalentThroughWebContentFirst(event),
                "Expected browser-first routing for \(testCase.name)"
            )
        }
    }

    func testBrowserFirstFindShortcutRoutingFallsBackToKeyCodeForNonLatinInput() {
        let event = makeKeyEvent(
            modifierFlags: [.command],
            characters: "",
            charactersIgnoringModifiers: "а", // Cyrillic a from a non-Latin input source
            keyCode: 3 // kVK_ANSI_F
        )

        XCTAssertTrue(
            shouldRouteBrowserFindCommandEquivalentThroughWebContentFirst(event),
            "Expected browser-first routing to keep Cmd+F eligible under non-Latin input"
        )
    }

    func testBrowserFirstFindShortcutRoutingDoesNotUseANSIPositionsForMismatchedASCIICharacters() {
        let cases: [(name: String, modifiers: NSEvent.ModifierFlags, chars: String, keyCode: UInt16)] = [
            ("cmd-u-on-ansi-f", [.command], "u", 3),
            ("cmd-o-on-ansi-g", [.command], "o", 5),
            ("cmd-period-on-ansi-e", [.command], ".", 14),
            ("cmd-shift-u-on-ansi-f", [.command, .shift], "u", 3),
            ("cmd-shift-o-on-ansi-g", [.command, .shift], "o", 5),
        ]

        for testCase in cases {
            let event = makeKeyEvent(
                modifierFlags: testCase.modifiers,
                characters: testCase.chars,
                charactersIgnoringModifiers: testCase.chars,
                keyCode: testCase.keyCode
            )

            XCTAssertFalse(
                shouldRouteBrowserFindCommandEquivalentThroughWebContentFirst(event),
                "Did not expect browser-first routing for mismatched ASCII shortcut \(testCase.name)"
            )
        }
    }

    func testBrowserFirstFindShortcutRoutingExcludesWebInspectorResponders() {
        let inspectorContainer = FakeWKInspectorContainerView(frame: .zero)
        let inspectorChild = NSView(frame: .zero)
        inspectorContainer.addSubview(inspectorChild)

        let event = makeKeyEvent(
            modifierFlags: [.command],
            characters: "f",
            charactersIgnoringModifiers: "f",
            keyCode: 3
        )

        XCTAssertFalse(
            shouldRouteBrowserFindCommandEquivalentThroughWebContentFirst(
                event,
                responder: inspectorChild
            ),
            "Did not expect browser-first routing while a Web Inspector responder is focused"
        )
    }

    func testBrowserFirstFindShortcutRoutingExcludesNonFindCommands() {
        let cases: [(name: String, modifiers: NSEvent.ModifierFlags, chars: String, keyCode: UInt16)] = [
            ("cmd-n", [.command], "n", 45),
            ("cmd-w", [.command], "w", 13),
            ("cmd-l", [.command], "l", 37),
            ("cmd-option-f", [.command, .option], "f", 3),
        ]

        for testCase in cases {
            let event = makeKeyEvent(
                modifierFlags: testCase.modifiers,
                characters: testCase.chars,
                charactersIgnoringModifiers: testCase.chars,
                keyCode: testCase.keyCode
            )
            XCTAssertFalse(
                shouldRouteBrowserFindCommandEquivalentThroughWebContentFirst(event),
                "Did not expect browser-first routing for \(testCase.name)"
            )
        }
    }

    func testCmdTWorksWithRussianKeyboardLayout() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId),
              let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace else {
            XCTFail("Expected test window context")
            return
        }

        let surfaceCountBefore = workspace.panels.count

        // Simulate Russian keyboard: layout provider returns "t" via ASCII fallback,
        // but event.charactersIgnoringModifiers returns Cyrillic "е".
        appDelegate.shortcutLayoutCharacterProvider = { keyCode, _ in
            keyCode == 17 ? "t" : nil
        }
        defer {
            appDelegate.shortcutLayoutCharacterProvider = KeyboardLayout.character(forKeyCode:modifierFlags:)
        }

        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "t",
            charactersIgnoringModifiers: "е", // Cyrillic е (Russian layout)
            isARepeat: false,
            keyCode: 17 // kVK_ANSI_T
        ) else {
            XCTFail("Failed to construct Russian-layout Cmd+T event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event), "Cmd+T should be handled with Russian keyboard layout")
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
        waitUntil(description: "Cmd+T to create a new surface with Russian keyboard layout") {
            workspace.panels.count == surfaceCountBefore + 1
        }

        XCTAssertEqual(workspace.panels.count, surfaceCountBefore + 1, "Cmd+T should create a new surface with Russian keyboard layout")
    }

    func testCmdTFallsBackToKeyCodeWithNonLatinLayoutWhenLayoutTranslationFails() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId),
              let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace else {
            XCTFail("Expected test window context")
            return
        }

        let surfaceCountBefore = workspace.panels.count

        // Simulate non-Latin layout where layout translation also fails (returns nil).
        // The ANSI keyCode fallback should still match the physical T key.
        appDelegate.shortcutLayoutCharacterProvider = { _, _ in nil }
        defer {
            appDelegate.shortcutLayoutCharacterProvider = KeyboardLayout.character(forKeyCode:modifierFlags:)
        }

        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "е", // Cyrillic е — non-ASCII
            isARepeat: false,
            keyCode: 17 // kVK_ANSI_T
        ) else {
            XCTFail("Failed to construct non-Latin Cmd+T event with failed layout translation")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event), "Cmd+T should fall back to keyCode with non-Latin layout")
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
        waitUntil(description: "Cmd+T keyCode fallback to create a new surface") {
            workspace.panels.count == surfaceCountBefore + 1
        }

        XCTAssertEqual(workspace.panels.count, surfaceCountBefore + 1, "Cmd+T keyCode fallback should create a new surface")
    }

    func testWindowSendEventRepairsLostFirstResponderForFocusedTerminalTyping() throws {
        // Same window-server family as the quarantined search-typing sibling:
        // responder-drift setup and repair both depend on first-responder
        // semantics hosted headless runners provide nondeterministically.
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["CI"] != nil,
            "first-responder semantics are nondeterministic in headless CI hosts"
        )
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId),
              let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace,
              let panelId = workspace.focusedPanelId,
              let terminalPanel = workspace.terminalPanel(for: panelId),
              let terminalView = surfaceView(in: terminalPanel.hostedView) else {
            XCTFail("Expected focused terminal surface")
            return
        }

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        terminalPanel.hostedView.setVisibleInUI(true)
        terminalPanel.hostedView.setActive(true)
        terminalPanel.hostedView.moveFocus()
        waitUntil(description: "terminal surface to become first responder") {
            terminalPanel.hostedView.isSurfaceViewFirstResponder()
        }

        XCTAssertTrue(
            terminalPanel.hostedView.isSurfaceViewFirstResponder(),
            "Expected terminal surface to own first responder before repair test"
        )

        // The setActive/moveFocus calls above can leave a reactive focus-reassert
        // cascade in flight (workspace/tab-manager observers reacting to
        // focusedPanelId/selectedTabId changes, per ensureFocus(for:surfaceId:) call
        // sites in Workspace.swift/TabManager.swift). That cascade can still be
        // queued when this test calls makeFirstResponder(nil) below and win the race,
        // silently restoring focus before the "lost first responder" assertion
        // observes it. Retry the clear until it actually sticks (bounded), rather
        // than assuming a single clear + one spin is enough.
        let clearDeadline = Date(timeIntervalSinceNow: 2.0)
        var responderStayedClear = false
        while Date() < clearDeadline {
            XCTAssertTrue(window.makeFirstResponder(nil), "Expected test to clear the window first responder")
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            if !terminalPanel.hostedView.isSurfaceViewFirstResponder() {
                responderStayedClear = true
                break
            }
        }

        XCTAssertTrue(responderStayedClear, "Expected terminal surface to lose first responder before repaired typing")
        XCTAssertTrue(window.firstResponder == nil || window.firstResponder is NSWindow, "Expected a broken key-routing responder")

#if DEBUG
        var forwardedKeyDownCount = 0
        let previousKeyEventObserver = GhosttyNSView.debugGhosttySurfaceKeyEventObserver
        GhosttyNSView.debugGhosttySurfaceKeyEventObserver = { keyEvent in
            previousKeyEventObserver?(keyEvent)
            guard keyEvent.action == GHOSTTY_ACTION_PRESS, keyEvent.keycode == 0 else { return }
            forwardedKeyDownCount += 1
        }
        defer {
            GhosttyNSView.debugGhosttySurfaceKeyEventObserver = previousKeyEventObserver
        }
#endif

        guard let keyDown = makeKeyDownEvent(
            key: "a",
            modifiers: [],
            keyCode: 0,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct typing event")
            return
        }

        window.sendEvent(keyDown)
        waitUntil(description: "typing to repair first responder back to the terminal surface") {
            terminalPanel.hostedView.isSurfaceViewFirstResponder()
        }

        XCTAssertTrue(
            terminalPanel.hostedView.isSurfaceViewFirstResponder(),
            "Typing should repair first responder back to the focused terminal surface"
        )
        XCTAssertTrue(window.firstResponder === terminalView, "Typing repair should restore the Ghostty surface view as first responder")
#if DEBUG
        // forwardedKeyDownCount is only observable through the DEBUG-only
        // GhosttyNSView.debugGhosttySurfaceKeyEventObserver seam; the first-
        // responder assertions above act as the Release-build proxy.
        XCTAssertGreaterThan(forwardedKeyDownCount, 0, "Typing repair should forward the keyDown into Ghostty")
#endif
    }

    func testWindowSendEventRepairsVisibleSameWindowResponderDriftForFocusedTerminalTyping() throws {
        // Same window-server family as the quarantined search-typing sibling:
        // responder-drift setup and repair both depend on first-responder
        // semantics hosted headless runners provide nondeterministically.
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["CI"] != nil,
            "first-responder semantics are nondeterministic in headless CI hosts"
        )
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId),
              let contentView = window.contentView,
              let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace,
              let panelId = workspace.focusedPanelId,
              let terminalPanel = workspace.terminalPanel(for: panelId),
              let terminalView = surfaceView(in: terminalPanel.hostedView) else {
            XCTFail("Expected focused terminal surface")
            return
        }

        let strayView = FocusableTestView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        contentView.addSubview(strayView)
        defer { strayView.removeFromSuperview() }

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        terminalPanel.hostedView.setVisibleInUI(true)
        terminalPanel.hostedView.setActive(true)
        terminalPanel.hostedView.moveFocus()
        waitUntil(description: "terminal surface to become first responder") {
            terminalPanel.hostedView.isSurfaceViewFirstResponder()
        }

        XCTAssertTrue(
            terminalPanel.hostedView.isSurfaceViewFirstResponder(),
            "Expected terminal surface to own first responder before repair test"
        )

        // The setActive/moveFocus calls above can leave a reactive focus-reassert
        // cascade in flight (workspace/tab-manager observers reacting to
        // focusedPanelId/selectedTabId changes, per ensureFocus(for:surfaceId:) call
        // sites in Workspace.swift/TabManager.swift). That cascade can still be
        // queued when this test calls makeFirstResponder(strayView) below and win the
        // race, silently restoring focus before the "lost first responder" assertion
        // observes it. Retry the drift-install until it actually sticks (bounded),
        // rather than assuming a single call + one spin is enough.
        let driftDeadline = Date(timeIntervalSinceNow: 2.0)
        var driftStuck = false
        while Date() < driftDeadline {
            XCTAssertTrue(window.makeFirstResponder(strayView), "Expected test to install a visible wrong first responder")
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            if !terminalPanel.hostedView.isSurfaceViewFirstResponder(), window.firstResponder === strayView {
                driftStuck = true
                break
            }
        }

        XCTAssertTrue(driftStuck, "Expected terminal surface to lose first responder before repaired typing")
        XCTAssertTrue(window.firstResponder === strayView, "Expected a visible same-window responder drift")

#if DEBUG
        var forwardedKeyDownCount = 0
        let previousKeyEventObserver = GhosttyNSView.debugGhosttySurfaceKeyEventObserver
        GhosttyNSView.debugGhosttySurfaceKeyEventObserver = { keyEvent in
            previousKeyEventObserver?(keyEvent)
            guard keyEvent.action == GHOSTTY_ACTION_PRESS, keyEvent.keycode == 0 else { return }
            forwardedKeyDownCount += 1
        }
        defer {
            GhosttyNSView.debugGhosttySurfaceKeyEventObserver = previousKeyEventObserver
        }
#endif

        guard let keyDown = makeKeyDownEvent(
            key: "a",
            modifiers: [],
            keyCode: 0,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct typing event")
            return
        }

        window.sendEvent(keyDown)
        waitUntil(description: "typing to repair first responder back to the terminal surface") {
            terminalPanel.hostedView.isSurfaceViewFirstResponder()
        }

        XCTAssertTrue(
            terminalPanel.hostedView.isSurfaceViewFirstResponder(),
            "Typing should repair first responder back to the focused terminal surface"
        )
        XCTAssertTrue(window.firstResponder === terminalView, "Typing repair should restore the Ghostty surface view as first responder")
#if DEBUG
        XCTAssertGreaterThan(forwardedKeyDownCount, 0, "Typing repair should forward the keyDown into Ghostty")
#endif
    }

    func testWindowSendEventRepairsFocusedTerminalSearchTypingAfterResponderDrift() throws {
        // Both the field-editor mount and the post-repair first-responder state
        // depend on window-server behavior the hosted headless runners provide
        // nondeterministically (fails at different stages across runs despite
        // key-window overrides, polling, and scaled deadlines). Covered locally.
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["CI"] != nil,
            "first-responder semantics are nondeterministic in headless CI hosts"
        )
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId),
              let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace,
              let panelId = workspace.focusedPanelId,
              let terminalPanel = workspace.terminalPanel(for: panelId) else {
            XCTFail("Expected focused terminal surface")
            return
        }

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        terminalPanel.hostedView.setVisibleInUI(true)
        terminalPanel.hostedView.setActive(true)
        terminalPanel.hostedView.moveFocus()
        waitUntil(description: "terminal surface to become first responder") {
            terminalPanel.hostedView.isSurfaceViewFirstResponder()
        }

        // requestMountedSearchFieldFocus gates on window.isKeyWindow (production guard
        // against stealing keyboard focus into a background window's field). This
        // XCTest host has no attached WindowServer session, so a plain NSWindow can
        // never genuinely become key here (same limitation documented in
        // TerminalAndGhosttyTests.testSearchOverlayFocusesSearchFieldAfterDeferredAttach) --
        // use the DEBUG-only override so this test can exercise the real focus-push
        // behavior without weakening the production guard for real windows.
#if DEBUG
        terminalPanel.hostedView.setIsKeyWindowOverrideForTesting(true)
        defer { terminalPanel.hostedView.setIsKeyWindowOverrideForTesting(nil) }
#endif

        let searchState = TerminalSurface.SearchState(needle: "")
        terminalPanel.surface.searchState = searchState
        terminalPanel.hostedView.setSearchOverlay(searchState: searchState)

        // Mounting the overlay's field editor and pushing focus into it happens via
        // `requestMountedSearchFieldFocus`'s internal retry loop (up to 4 attempts, 0.03s
        // apart, since the SwiftUI-hosted field may not be laid out yet on the first
        // attempt). A single fixed 0.05s spin can land before that loop finishes,
        // causing rare flakes. Poll instead of assuming one spin is enough.
        // See `ciScale` (TabManagerUnitTests.swift): scale the poll deadline under CI,
        // where this retry loop can legitimately need longer than a fast local machine.
        let searchFieldDeadline = Date(timeIntervalSinceNow: 2.0 * ciScale)
        var searchField: NSTextField?
        while Date() < searchFieldDeadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            if let candidate = findEditableTextField(in: terminalPanel.hostedView),
               firstResponderOwnsTextField(window.firstResponder, textField: candidate) {
                searchField = candidate
                break
            }
        }
        guard let searchField = searchField ?? findEditableTextField(in: terminalPanel.hostedView) else {
            if ProcessInfo.processInfo.environment["CI"] != nil {
                // The SwiftUI-hosted field editor never mounts in the hosted-runner
                // headless window server, even with the key-window override and a
                // scaled deadline. The repair path stays covered by local runs and
                // by GhosttySurfaceOverlayTests' mount coverage on CI.
                throw XCTSkip("terminal search field cannot mount in headless CI host")
            }
            XCTFail("Expected mounted terminal search field")
            return
        }

        XCTAssertTrue(
            firstResponderOwnsTextField(window.firstResponder, textField: searchField),
            "Expected terminal search field to own first responder before drift"
        )

        XCTAssertTrue(window.makeFirstResponder(nil), "Expected test to clear the window first responder")
        waitUntil(description: "search field to lose first responder") {
            !firstResponderOwnsTextField(window.firstResponder, textField: searchField)
        }

        XCTAssertFalse(
            firstResponderOwnsTextField(window.firstResponder, textField: searchField),
            "Expected terminal search field to lose first responder before repaired typing"
        )

        guard let keyDown = makeKeyDownEvent(
            key: "a",
            modifiers: [],
            keyCode: 0,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct typing event")
            return
        }

        window.sendEvent(keyDown)
        // The focus-repair path triggered by sendEvent runs asynchronously (see the
        // searchFieldDeadline poll above for the same class of flake). A single fixed
        // 0.05s spin can land before it completes under a full serial suite run with
        // CPU contention from hundreds of prior tests — poll instead.
        let repairDeadline = Date(timeIntervalSinceNow: 2.0 * ciScale)
        while Date() < repairDeadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            if firstResponderOwnsTextField(window.firstResponder, textField: searchField) {
                break
            }
        }

        XCTAssertTrue(
            firstResponderOwnsTextField(window.firstResponder, textField: searchField),
            "Typing should repair focus back to the terminal search field"
        )
        XCTAssertEqual(searchField.stringValue, "a", "Typing repair should preserve the first key in the search field")
    }

    private func makeKeyDownEvent(
        key: String,
        modifiers: NSEvent.ModifierFlags,
        keyCode: UInt16,
        windowNumber: Int,
        isARepeat: Bool = false
    ) -> NSEvent? {
        makeKeyEvent(
            type: .keyDown,
            key: key,
            modifiers: modifiers,
            keyCode: keyCode,
            windowNumber: windowNumber,
            isARepeat: isARepeat
        )
    }

    private func makeKeyEvent(
        type: NSEvent.EventType,
        key: String,
        modifiers: NSEvent.ModifierFlags,
        keyCode: UInt16,
        windowNumber: Int,
        isARepeat: Bool = false
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber,
            context: nil,
            characters: key,
            charactersIgnoringModifiers: key,
            isARepeat: isARepeat,
            keyCode: keyCode
        )
    }

    private func withTemporaryShortcut(
        action: KeyboardShortcutSettings.Action,
        shortcut: StoredShortcut? = nil,
        _ body: () -> Void
    ) {
        let hadPersistedShortcut = UserDefaults.standard.object(forKey: action.defaultsKey) != nil
        let originalShortcut = KeyboardShortcutSettings.shortcut(for: action)
        defer {
            if hadPersistedShortcut {
                KeyboardShortcutSettings.setShortcut(originalShortcut, for: action)
            } else {
                KeyboardShortcutSettings.resetShortcut(for: action)
            }
        }
        KeyboardShortcutSettings.setShortcut(shortcut ?? action.defaultShortcut, for: action)
        body()
    }

    private func assertEscapeKeyUpIsConsumedAfterCommandPaletteOpenRequest(
        _ openRequest: (_ appDelegate: AppDelegate, _ window: NSWindow) -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared", file: file, line: line)
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer {
            closeWindow(withId: windowId)
        }

        guard let window = window(withId: windowId) else {
            XCTFail("Expected test window", file: file, line: line)
            return
        }

        openRequest(appDelegate, window)
        appDelegate.setCommandPaletteVisible(true, for: window)

        guard let escapeKeyDown = makeKeyEvent(
            type: .keyDown,
            key: "\u{1b}",
            modifiers: [],
            keyCode: 53,
            windowNumber: window.windowNumber
        ), let escapeKeyUp = makeKeyEvent(
            type: .keyUp,
            key: "\u{1b}",
            modifiers: [],
            keyCode: 53,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Escape key events", file: file, line: line)
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleShortcutMonitorEvent(event: escapeKeyDown), file: file, line: line)
#else
        XCTFail("debugHandleShortcutMonitorEvent is only available in DEBUG", file: file, line: line)
#endif

        appDelegate.setCommandPaletteVisible(false, for: window)

#if DEBUG
        XCTAssertTrue(
            appDelegate.debugHandleShortcutMonitorEvent(event: escapeKeyUp),
            "Escape keyUp should be consumed after dismiss for command palette open requests",
            file: file,
            line: line
        )
#else
        XCTFail("debugHandleShortcutMonitorEvent is only available in DEBUG", file: file, line: line)
#endif
    }

    private func window(withId windowId: UUID) -> NSWindow? {
        let identifier = "cmux.main.\(windowId.uuidString)"
        return NSApp.windows.first(where: { $0.identifier?.rawValue == identifier })
    }

    private func makeUnregisteredMainWindow(windowId: UUID) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(windowId.uuidString)")
        return window
    }

    private func assertLifecycleResourcesStopped(
        _ manager: TabManager,
        reason: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let snapshot = manager.lifecycleResourceSnapshot
        XCTAssertTrue(snapshot.isStopped, reason, file: file, line: line)
        XCTAssertEqual(snapshot.observerCount, 0, reason, file: file, line: line)
        XCTAssertFalse(snapshot.hasAgentPIDSweepTimer, reason, file: file, line: line)
        XCTAssertFalse(snapshot.hasWorkspaceGitMetadataPollTimer, reason, file: file, line: line)
        XCTAssertFalse(snapshot.hasSelectedWorkspaceGitMetadataPollTimer, reason, file: file, line: line)
        XCTAssertEqual(snapshot.workspaceGitProbeTimerCount, 0, reason, file: file, line: line)
        XCTAssertEqual(snapshot.workspaceGitProbeGenerationCount, 0, reason, file: file, line: line)
        XCTAssertEqual(snapshot.workspaceGitTrackedDirectoryCount, 0, reason, file: file, line: line)
        XCTAssertFalse(snapshot.hasWorkspaceCycleCooldownTask, reason, file: file, line: line)
        XCTAssertFalse(snapshot.hasPendingPanelTitleCoalescerWork, reason, file: file, line: line)
#if DEBUG
        XCTAssertEqual(snapshot.uiTestCancellableCount, 0, reason, file: file, line: line)
#endif
    }

    private func assertLifecycleResourcesRunning(
        _ manager: TabManager,
        reason: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let snapshot = manager.lifecycleResourceSnapshot
        XCTAssertFalse(snapshot.isStopped, reason, file: file, line: line)
        XCTAssertEqual(snapshot.observerCount, 2, reason, file: file, line: line)
        XCTAssertTrue(snapshot.hasAgentPIDSweepTimer, reason, file: file, line: line)
        XCTAssertTrue(snapshot.hasWorkspaceGitMetadataPollTimer, reason, file: file, line: line)
        XCTAssertTrue(snapshot.hasSelectedWorkspaceGitMetadataPollTimer, reason, file: file, line: line)
    }

    private func surfaceView(in hostedView: GhosttySurfaceScrollView) -> GhosttyNSView? {
        var stack: [NSView] = [hostedView]
        while let current = stack.popLast() {
            if let surfaceView = current as? GhosttyNSView {
                return surfaceView
            }
            stack.append(contentsOf: current.subviews)
        }
        return nil
    }

    private func findEditableTextField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable {
            return field
        }
        for subview in view.subviews {
            if let field = findEditableTextField(in: subview) {
                return field
            }
        }
        return nil
    }

    private func firstResponderOwnsTextField(_ firstResponder: NSResponder?, textField: NSTextField) -> Bool {
        if firstResponder === textField {
            return true
        }
        if let editor = firstResponder as? NSTextView,
           editor.isFieldEditor,
           editor.delegate as? NSTextField === textField {
            return true
        }
        return false
    }

    private func mainWindowIds() -> Set<UUID> {
        Set(AppDelegate.shared?.listMainWindowSummaries().map(\.windowId) ?? [])
    }

    /// Regression test for the ghostty IO-thread callback-context teardown race.
    ///
    /// Root cause: `GhosttySurfaceCallbackContext` (the per-surface userdata handed to
    /// ghostty) used to hold `weak var surfaceView: GhosttyNSView?` and `weak var
    /// terminalSurface: TerminalSurface?`. Ghostty's IO thread invokes callbacks that
    /// read those weak refs SYNCHRONOUSLY, before any main-thread hop --
    /// `runtimeReadClipboardCallback` read `callbackContext.runtimeSurface` directly, and
    /// `handleAction`'s surface-target preamble read `callbackContext?.tabId` /
    /// `.surfaceId` immediately (title/pwd/mouse-shape/progress actions dispatch from
    /// ghostty's VT/IO path, not the main-thread `ghostty_app_tick` mailbox, so this runs
    /// on the IO thread during ordinary prompt chatter). Reading/retaining a weak
    /// reference to an object mid-deinit on another thread races Swift's ARC
    /// weak-reference side tables and can corrupt them.
    ///
    /// This loops rapid window create/close under forced occlusion
    /// (`PROGRAMA_FORCE_OCCLUDED=1`, honored by
    /// `GhosttySurfaceScrollView.applyEffectiveOcclusion()`) with a live shell in each
    /// window -- exactly the kind of concurrent IO-thread callback traffic vs. main-thread
    /// teardown that used to race. This same rapid create/close shape is also the one the
    /// `windowObserverGeneration` guard in `GhosttySurfaceScrollView.viewDidMoveToWindow`
    /// targets (a second, distinct teardown-race mechanism: an
    /// `NSNotificationCenter.addObserver(queue: .main)` block already handed off to the
    /// main `OperationQueue` before `removeObserver` runs for it). Making that exact
    /// enqueue race deterministic would require a dedicated seam into
    /// `GhosttySurfaceScrollView`'s private observer bookkeeping that doesn't exist today,
    /// so per the test-quality policy for cases where a targeted deterministic repro isn't
    /// practical yet, this tripwire's iteration count is bumped modestly (20 -> 28) instead
    /// of adding a new seam-dependent test. Bounded rather than large: this is inherently
    /// probabilistic, and a much higher count would only buy marginal extra confidence at
    /// the cost of runtime; it is not meant to chase local determinism.
    ///
    /// NOTE: against the CURRENT (reverted, pre-occluded-render) ghostty framework, the
    /// crash this guards against is masked by incidental renderer serialization, so this
    /// test is expected to pass reliably even without the fix. It is only expected to
    /// fail reliably against the occluded-render ghostty framework -- see the companion
    /// fix commit's repro loop for that comparison.
    func testRapidWindowTeardownDoesNotRaceCallbackContext() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        for iteration in 0..<28 {
            let windowId = appDelegate.createMainWindow()
            guard window(withId: windowId) != nil else {
                XCTFail("iteration \(iteration): expected test window")
                return
            }
            // Give the shell a brief window to start emitting its own startup/prompt OSC
            // title+pwd chatter before tearing the surface down -- narrows the race
            // window without making the test flaky-slow.
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
            closeWindow(withId: windowId)
            XCTAssertNil(
                appDelegate.tabManagerFor(windowId: windowId),
                "iteration \(iteration): expected window to be fully torn down"
            )
        }
    }

    /// Closes every currently-registered main window, including the app's own default
    /// window from its `WindowGroup` scene (which exists for the lifetime of the test
    /// process regardless of which test is running). Some tests need to assert on
    /// behavior that only holds when literally no live main window exists anywhere in
    /// the app, and that default window would otherwise always be available as a
    /// legitimate fallback target and defeat that precondition.
    private func closeAllMainWindows() {
        for id in mainWindowIds() {
            closeWindow(withId: id)
        }
    }

    /// Every main window built via `createMainWindow()` already hosts a real command
    /// palette overlay container (installed by `ContentView`, tagged with
    /// `commandPaletteOverlayContainerIdentifier`) as a sibling of `contentView`, not
    /// nested inside it. Adding a second, decoy view with the same identifier under
    /// `contentView` does not shadow it -- the production tree walk
    /// (`AppDelegate.commandPaletteOverlayContainer(in:)`) finds the real one first and
    /// returns immediately, so it never reaches a test's own decoy node. Tests that need
    /// to simulate the overlay's visual state must locate and mutate this real view.
    private func findRealCommandPaletteOverlayContainer(in window: NSWindow) -> NSView? {
        guard let searchRoot = window.contentView?.superview ?? window.contentView else { return nil }
        var stack: [NSView] = [searchRoot]
        while let candidate = stack.popLast() {
            if candidate.identifier == commandPaletteOverlayContainerIdentifier {
                return candidate
            }
            stack.append(contentsOf: candidate.subviews)
        }
        return nil
    }

    /// Explicit disposal keeps test cleanup destructive after ordinary window close
    /// became a session-preserving hide operation.
    private func closeWindow(withId windowId: UUID) {
        // NSApp.windows can retain already-closed windows with the same identifier.
        // Resolve the registered context so cleanup always disposes its live owner.
        guard AppDelegate.shared?.closeMainWindow(windowId: windowId) == true else { return }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }

    private func restoreDefaultsValue(_ value: Any?, forKey key: String, defaults: UserDefaults) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}

private final class CommandPaletteMarkedTextFieldEditor: NSTextView {
    var hasMarkedTextForTesting = false

    override func hasMarkedText() -> Bool {
        hasMarkedTextForTesting
    }
}

@MainActor
final class AppLifecycleCoordinatorTests: XCTestCase {
    func testTerminationDecisionAndCancellationOwnLifecycleState() {
        let coordinator = AppLifecycleCoordinator()

        let decision = coordinator.beginTermination(
            hasValidatedDuplicateShutdownRequest: false,
            isTaggedDevBuild: false,
            isQuitWarningEnabled: true
        )

        XCTAssertTrue(decision.shouldWarn)
        XCTAssertEqual(decision.logReason, "warning_bypassed")
        XCTAssertTrue(coordinator.isTerminating)
        coordinator.cancelTermination()
        XCTAssertFalse(coordinator.isTerminating)
    }

    func testPowerOffAndOneShotLifecycleClaimsAreStateful() {
        let coordinator = AppLifecycleCoordinator()

        coordinator.beginPowerOff()
        XCTAssertTrue(coordinator.isAwaitingPowerOff)
        XCTAssertTrue(coordinator.resumeAfterCancelledPowerOff())
        XCTAssertFalse(coordinator.resumeAfterCancelledPowerOff())
        XCTAssertTrue(coordinator.claimSnapshotObserverInstallation())
        XCTAssertFalse(coordinator.claimSnapshotObserverInstallation())
        XCTAssertTrue(coordinator.claimSuddenTerminationDisable())
        XCTAssertFalse(coordinator.claimSuddenTerminationDisable())
        XCTAssertTrue(coordinator.claimSuddenTerminationEnable())
        XCTAssertFalse(coordinator.claimSuddenTerminationEnable())
    }

    func testDuplicateLoserAndConfirmedQuitBypassWarning() {
        let duplicate = AppLifecycleCoordinator()
        duplicate.confirmSingleInstanceLoser()
        XCTAssertFalse(duplicate.beginTermination(
            hasValidatedDuplicateShutdownRequest: false,
            isTaggedDevBuild: false,
            isQuitWarningEnabled: true
        ).shouldWarn)

        let confirmed = AppLifecycleCoordinator()
        confirmed.confirmQuit()
        XCTAssertFalse(confirmed.beginTermination(
            hasValidatedDuplicateShutdownRequest: false,
            isTaggedDevBuild: false,
            isQuitWarningEnabled: true
        ).shouldWarn)
    }
}
