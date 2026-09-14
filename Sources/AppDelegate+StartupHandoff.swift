import AppKit
import Darwin

@MainActor
final class StartupSessionHandoff {
    private let olderProcess: @MainActor () -> ProgramaSingleInstanceProcessKey?
    private let isLive: (ProgramaSingleInstanceProcessKey) -> Bool
    private let onReady: @MainActor () -> Void
    private(set) var hasCompletedInitialArbitration: Bool
    private var checked = false
    private var target: ProgramaSingleInstanceProcessKey?
    var isWaiting: Bool { target != nil }

    init(
        hasCompletedInitialArbitration: Bool = SessionMachineryGate.isUnitTesting,
        olderProcess: @escaping @MainActor () -> ProgramaSingleInstanceProcessKey?,
        isLive: @escaping (ProgramaSingleInstanceProcessKey) -> Bool,
        onReady: @escaping @MainActor () -> Void
    ) {
        self.hasCompletedInitialArbitration = hasCompletedInitialArbitration
        self.olderProcess = olderProcess
        self.isLive = isLive
        self.onReady = onReady
    }

    func shouldDefer() -> Bool {
        guard hasCompletedInitialArbitration else { return true }
        guard !checked else { return isWaiting }
        checked = true
        target = olderProcess()
        if isWaiting { schedulePoll() }
        return isWaiting
    }

    func initialArbitrationCompleted() {
        guard !hasCompletedInitialArbitration else { return }
        hasCompletedInitialArbitration = true
        if !shouldDefer() { onReady() }
    }

    func poll() {
        guard isWaiting else { return }
        if target.map(isLive) == true { schedulePoll(); return }
        target = olderProcess()
        if isWaiting { schedulePoll() } else { onReady() }
    }

    private func schedulePoll() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            Task { @MainActor [weak self] in self?.poll() }
        }
    }

    static func authenticatedOlderProcess() -> ProgramaSingleInstanceProcessKey? {
        guard !SessionMachineryGate.isUnitTesting, let bundleIdentifier = Bundle.main.bundleIdentifier,
              let currentKey = AppDelegate.singleInstanceProcessKey(for: getpid()) else { return nil }
        let embeddedCLIURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/bin/programa", isDirectory: false)
            .standardizedFileURL.resolvingSymlinksInPath()
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier) {
            guard AppDelegate.shouldConsiderDuplicateApplication(
                candidateBundleIdentifier: app.bundleIdentifier,
                candidateProcessIdentifier: app.processIdentifier,
                candidateExecutableURL: app.executableURL,
                expectedBundleIdentifier: bundleIdentifier,
                currentProcessIdentifier: currentKey.processIdentifier,
                embeddedCLIURL: embeddedCLIURL
            ), let otherKey = AppDelegate.singleInstanceProcessKey(for: app.processIdentifier),
               AppDelegate.shouldTerminateDuplicateInstance(current: currentKey, other: otherKey),
               AppDelegate.isAuthenticatedProgramaApplication(expectedProcessKey: otherKey) else { continue }
            return otherKey
        }
        return nil
    }
}
