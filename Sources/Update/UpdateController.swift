import Sparkle
import Cocoa
import Combine
import SwiftUI

/// Returns `true` when the Sparkle updater should be suppressed for the given bundle identifier.
///
/// Tagged DEV builds (`com.darkroom.programa.debug.<tag>`) and staging builds
/// (`com.darkroom.programa.staging`) must never start the public Sparkle update feed:
/// they are not release binaries and should never show the "Update Available" pill.
func updateControllerShouldSkipStartup(bundleIdentifier: String?) -> Bool {
    SocketControlSettings.isDebugLikeBundleIdentifier(bundleIdentifier)
        || SocketControlSettings.isStagingBundleIdentifier(bundleIdentifier)
}

enum UpdateSettings {
    static let automaticChecksKey = "SUEnableAutomaticChecks"
    static let automaticallyUpdateKey = "SUAutomaticallyUpdate"
    static let scheduledCheckIntervalKey = "SUScheduledCheckInterval"
    static let sendProfileInfoKey = "SUSendProfileInfo"
    static let migrationKey = "programa.sparkle.automaticChecksMigration.v2"
    static let autoInstallMigrationKey = "programa.sparkle.autoInstallMigration.v3"
    static let previousDefaultScheduledCheckInterval: TimeInterval = 60 * 60 * 24
    static let scheduledCheckInterval: TimeInterval = 60 * 60

    static func apply(to defaults: UserDefaults) {
        defaults.register(defaults: [
            automaticChecksKey: true,
            automaticallyUpdateKey: true,
            scheduledCheckIntervalKey: scheduledCheckInterval,
            sendProfileInfoKey: false,
        ])

        applyAutoInstallMigration(to: defaults)

        guard !defaults.bool(forKey: migrationKey) else { return }

        // Repair older installs that may have ended up with automatic checks disabled
        // before the updater defaults were embedded in Info.plist.
        defaults.set(true, forKey: automaticChecksKey)

        if let interval = defaults.object(forKey: scheduledCheckIntervalKey) as? NSNumber {
            let currentInterval = interval.doubleValue
            if currentInterval <= 0 ||
                abs(currentInterval - previousDefaultScheduledCheckInterval) < 1 {
                defaults.set(scheduledCheckInterval, forKey: scheduledCheckIntervalKey)
            }
        } else {
            defaults.set(scheduledCheckInterval, forKey: scheduledCheckIntervalKey)
        }

        // automaticallyUpdateKey is deliberately NOT written here: the
        // registered default (true) covers the nil case, and writing a
        // concrete value would defeat `applyAutoInstallMigration` for
        // installs that reach this migration first.
        if defaults.object(forKey: sendProfileInfoKey) == nil {
            defaults.set(false, forKey: sendProfileInfoKey)
        }

        defaults.set(true, forKey: migrationKey)
    }

    /// Silent auto-install is the default: the single-lane, fix-forward
    /// release model only works if fixes reach users, and a crash-looping
    /// user never clicks the pill. Installs migrated by an earlier build hold
    /// a stored `false` that would mask the registered default (true); this
    /// one-time migration clears that stored value. The Settings toggle writes
    /// a concrete value afterwards and wins permanently — this runs once.
    private static func applyAutoInstallMigration(to defaults: UserDefaults) {
        guard !defaults.bool(forKey: autoInstallMigrationKey) else { return }
        defaults.removeObject(forKey: automaticallyUpdateKey)
        defaults.set(true, forKey: autoInstallMigrationKey)
    }
}

class UpdateController {
    private(set) var updater: SPUUpdater
    private let userDriver: UpdateDriver
    private enum Installation {
        case idle
        case subscribing(UUID)
        case monitoring(UUID, AnyCancellable)
    }

    private enum Attempt {
        case idle
        case waiting(UUID, AnyCancellable)
        case observedProgress(UUID, AnyCancellable)
    }

    private enum Check {
        case idle
        case preparing(UUID)
        case waiting(UUID, DispatchWorkItem)
        case cancelling(UUID, DispatchWorkItem)
        case checking(UUID)

        var token: UUID? {
            switch self {
            case .idle: nil
            case .preparing(let token), .waiting(let token, _),
                 .cancelling(let token, _), .checking(let token): token
            }
        }
    }

    private enum Startup {
        case stopped
        case starting(UUID)
        case started
        case failed(UUID)
    }

    private enum Dismissal {
        case idle
        case scheduled(UUID, DispatchWorkItem)
    }

    private var installation: Installation = .idle
    private var attempt: Attempt = .idle
    private var check: Check = .idle
    private var startup: Startup = .stopped
    private var dismissal: Dismissal = .idle
    private var noUpdateDismissCancellable: AnyCancellable?
    private let noUpdateDismissObserverToken = UUID()
    private let readyRetryDelay: TimeInterval = 0.25
    private let readyRetryCount: Int = 20

    var viewModel: UpdateViewModel {
        userDriver.viewModel
    }

    init() {
        let defaults = UserDefaults.standard
        UpdateSettings.apply(to: defaults)

        let hostBundle = Bundle.main
        self.userDriver = UpdateDriver(viewModel: .init(), hostBundle: hostBundle)
        self.updater = SPUUpdater(
            hostBundle: hostBundle,
            applicationBundle: hostBundle,
            userDriver: userDriver,
            delegate: userDriver
        )
        installNoUpdateDismissObserver()
    }

    deinit {
        if case .monitoring(_, let subscription) = installation { subscription.cancel() }
        switch attempt {
        case .waiting(_, let subscription), .observedProgress(_, let subscription): subscription.cancel()
        case .idle: break
        }
        noUpdateDismissCancellable?.cancel()
        if case .scheduled(_, let work) = dismissal { work.cancel() }
        switch check {
        case .waiting(_, let work), .cancelling(_, let work): work.cancel()
        default: break
        }
    }

    /// Start the updater. If startup fails, the error is shown via the custom UI.
    func startUpdaterIfNeeded() {
        guard !updateControllerShouldSkipStartup(bundleIdentifier: Bundle.main.bundleIdentifier) else { return }
        switch startup {
        case .starting, .started: return
        case .stopped, .failed: break
        }
        let token = UUID()
        startup = .starting(token)
        ensureSparkleInstallationCache()
#if DEBUG
        // Keep the permission-related defaults resettable for UI tests even though the
        // delegate suppresses Sparkle's permission UI entirely.
        if ProcessInfo.processInfo.environment["PROGRAMA_UI_TEST_RESET_SPARKLE_PERMISSION"] == "1" {
            let defaults = UserDefaults.standard
            defaults.removeObject(forKey: UpdateSettings.automaticChecksKey)
            defaults.removeObject(forKey: UpdateSettings.automaticallyUpdateKey)
            defaults.removeObject(forKey: UpdateSettings.scheduledCheckIntervalKey)
            defaults.removeObject(forKey: UpdateSettings.sendProfileInfoKey)
            defaults.removeObject(forKey: UpdateSettings.migrationKey)
            defaults.removeObject(forKey: UpdateSettings.autoInstallMigrationKey)
            defaults.synchronize()
            UpdateLogStore.shared.append("reset sparkle permission defaults (ui test)")
        }
#endif
        do {
            try updater.start()
            guard case .starting(token) = startup else { return }
            startup = .started
            let interval = Int(updater.updateCheckInterval.rounded())
            UpdateLogStore.shared.append(
                "updater started (autoChecks=\(updater.automaticallyChecksForUpdates), interval=\(interval)s, autoDownloads=\(updater.automaticallyDownloadsUpdates))"
            )
            startLaunchUpdateProbeIfNeeded()
        } catch {
            guard case .starting(token) = startup else { return }
            startup = .failed(token)
            userDriver.viewModel.state = .error(.init(
                error: error,
                retry: { [weak self] in
                    guard let self, case .failed(token) = self.startup else { return }
                    self.startup = .stopped
                    self.userDriver.viewModel.state = .idle
                    self.startUpdaterIfNeeded()
                },
                dismiss: { [weak self] in
                    guard let self, case .failed(token) = self.startup else { return }
                    self.startup = .stopped
                    self.userDriver.viewModel.state = .idle
                }
            ))
        }
    }

    private func startLaunchUpdateProbeIfNeeded() {
        guard updater.automaticallyChecksForUpdates else {
            UpdateLogStore.shared.append("launch update probe skipped (automatic checks disabled)")
            return
        }

        // Probe immediately on launch so the sidebar can surface a passive update indicator
        // without waiting for Sparkle's scheduled check or opening interactive update UI.
        UpdateLogStore.shared.append("starting launch update probe")
        updater.checkForUpdateInformation()
    }

    /// Force install the current update by auto-confirming all installable states.
    func installUpdate() {
        guard viewModel.state.isInstallable else { return }
        guard case .idle = installation else { return }
        switch check {
        case .waiting(_, let work), .cancelling(_, let work): work.cancel()
        default: break
        }
        check = .idle
        let token = UUID()
        installation = .subscribing(token)

        let subscription = viewModel.$state.sink { [weak self] state in
            guard let self else { return }
            switch self.installation {
            case .subscribing(token), .monitoring(token, _): break
            default: return
            }
            guard state.isInstallable else {
                self.installation = .idle
                return
            }
            state.confirm()
        }
        if case .subscribing(token) = installation {
            installation = .monitoring(token, subscription)
        } else {
            subscription.cancel()
        }
    }

    /// Check for updates and auto-confirm install if one is found.
    func attemptUpdate() {
        stopAttemptUpdateMonitoring()
        let token = UUID()

        let subscription = viewModel.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                let subscription: AnyCancellable
                let didObserveProgress: Bool
                switch self.attempt {
                case .waiting(token, let current):
                    subscription = current
                    didObserveProgress = false
                case .observedProgress(token, let current):
                    subscription = current
                    didObserveProgress = true
                default: return
                }
                if state.isInstallable || !state.isIdle {
                    self.attempt = .observedProgress(token, subscription)
                }

                if case .updateAvailable = state {
                    UpdateLogStore.shared.append("attemptUpdate auto-confirming available update")
                    state.confirm()
                    return
                }

                // Only stop on terminal failure states (.notFound, .error).
                // Don't stop on .idle — the check may still be starting up
                // (e.g. retry loop, background probe finishing).
                guard didObserveProgress || state.isInstallable || !state.isIdle,
                      !state.isInstallable, !state.isIdle else {
                    return
                }
                self.stopAttemptUpdateMonitoring()
            }
        attempt = .waiting(token, subscription)

        checkForUpdates()
    }

    /// Check for updates (used by the menu item).
    @objc func checkForUpdates() {
        UpdateLogStore.shared.append("checkForUpdates invoked (state=\(viewModel.state.isIdle ? "idle" : "busy"))")
        checkForUpdatesWhenReady(retries: readyRetryCount)
    }

    /// Check for updates using the custom popover-based UI.
    func checkForUpdatesInCustomUI() {
        checkForUpdatesWhenReady(retries: readyRetryCount)
    }

    private func performCheckForUpdates(token: UUID) {
        guard check.token == token else { return }
        startUpdaterIfNeeded()
        guard check.token == token else { return }
        ensureSparkleInstallationCache()
        if viewModel.state == .idle {
            check = .checking(token)
            updater.checkForUpdates()
            return
        }

        if case .monitoring(_, let subscription) = installation { subscription.cancel() }
        installation = .idle
        viewModel.state.cancel()
        guard check.token == token else { return }

        let work = DispatchWorkItem { [weak self] in
            guard let self, case .cancelling(token, _) = self.check else { return }
            self.check = .checking(token)
            self.updater.checkForUpdates()
        }
        check = .cancelling(token, work)
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100), execute: work)
    }

    /// Check for updates once the updater is ready (used by UI tests).
    func checkForUpdatesWhenReady(retries: Int = 10) {
        switch check {
        case .waiting(_, let work), .cancelling(_, let work): work.cancel()
        default: break
        }
        let token = UUID()
        check = .preparing(token)
        checkForUpdatesWhenReady(retries: retries, token: token)
    }

    private func checkForUpdatesWhenReady(retries: Int, token: UUID) {
        guard check.token == token else { return }
        check = .preparing(token)
        startUpdaterIfNeeded()
        guard check.token == token else { return }
        ensureSparkleInstallationCache()
        let canCheck = updater.canCheckForUpdates
        UpdateLogStore.shared.append("checkForUpdatesWhenReady invoked (canCheck=\(canCheck))")
        if canCheck {
            performCheckForUpdates(token: token)
            return
        }
        if viewModel.state.isIdle {
            viewModel.state = .checking(.init(cancel: {}))
        }
        guard check.token == token else { return }
        guard retries > 0 else {
            UpdateLogStore.shared.append("checkForUpdatesWhenReady timed out")
            if case .checking = viewModel.state {
                viewModel.state = .error(.init(
                    error: NSError(
                        domain: "programa.update",
                        code: 1,
                        userInfo: [
                            NSLocalizedDescriptionKey: String(
                                localized: "update.error.stillStarting",
                                defaultValue: "Updater is still starting. Try again in a moment."
                            )
                        ]
                    ),
                    retry: { [weak self] in
                        guard let self, self.check.token == token else { return }
                        self.checkForUpdates()
                    },
                    dismiss: { [weak self] in
                        guard let self, self.check.token == token else { return }
                        self.viewModel.state = .idle
                    }
                ))
            }
            return
        }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, case .waiting(token, _) = self.check else { return }
            self.checkForUpdatesWhenReady(retries: retries - 1, token: token)
        }
        check = .waiting(token, workItem)
        DispatchQueue.main.asyncAfter(deadline: .now() + readyRetryDelay, execute: workItem)
    }

    /// Validate the check for updates menu item.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(checkForUpdates) {
            // Always allow user-initiated checks; Sparkle can safely surface current progress.
            return true
        }
        return true
    }

    private func stopAttemptUpdateMonitoring() {
        let previous = attempt
        attempt = .idle
        switch previous {
        case .waiting(_, let subscription), .observedProgress(_, let subscription): subscription.cancel()
        case .idle: break
        }
    }

    private func installNoUpdateDismissObserver() {
        let token = noUpdateDismissObserverToken
        noUpdateDismissCancellable = Publishers.CombineLatest(viewModel.$state, viewModel.$overrideState)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state, overrideState in
                guard let self, self.noUpdateDismissObserverToken == token else { return }
                self.scheduleNoUpdateDismiss(for: state, overrideState: overrideState)
            }
    }

    private func scheduleNoUpdateDismiss(for state: UpdateState, overrideState: UpdateState?) {
        if case .scheduled(_, let work) = dismissal { work.cancel() }
        dismissal = .idle

        guard overrideState == nil else { return }
        guard case .notFound(let notFound) = state else { return }

        recordUITestTimestamp(key: "noUpdateShownAt")
        let token = UUID()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, case .scheduled(token, _) = self.dismissal else { return }
            self.dismissal = .idle
            guard self.viewModel.overrideState == nil,
                  case .notFound = self.viewModel.state else { return }

            let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                self.recordUITestTimestamp(key: "noUpdateHiddenAt")
                self.viewModel.state = .idle
            }
            notFound.acknowledgement()
        }
        dismissal = .scheduled(token, workItem)
        DispatchQueue.main.asyncAfter(
            deadline: .now() + UpdateTiming.noUpdateDisplayDuration,
            execute: workItem
        )
    }

    private func recordUITestTimestamp(key: String) {
#if DEBUG
        let env = ProcessInfo.processInfo.environment
        guard env["PROGRAMA_UI_TEST_MODE"] == "1" else { return }
        guard let path = env["PROGRAMA_UI_TEST_TIMING_PATH"] else { return }

        let url = URL(fileURLWithPath: path)
        var payload: [String: Double] = [:]
        if let data = try? Data(contentsOf: url),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Double] {
            payload = object
        }
        payload[key] = Date().timeIntervalSince1970
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            try? data.write(to: url)
        }
#endif
    }

    private func ensureSparkleInstallationCache() {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }
        guard let cachesURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }

        let baseURL = cachesURL
            .appendingPathComponent(bundleIdentifier)
            .appendingPathComponent("org.sparkle-project.Sparkle")
        let installURL = baseURL.appendingPathComponent("Installation")

        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: installURL.path, isDirectory: &isDirectory) {
            if !isDirectory.boolValue {
                do {
                    try FileManager.default.removeItem(at: installURL)
                } catch {
                    UpdateLogStore.shared.append("Failed removing Sparkle installation cache file: \(error)")
                    return
                }
            } else {
                return
            }
        }

        do {
            try FileManager.default.createDirectory(
                at: installURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            UpdateLogStore.shared.append("Ensured Sparkle installation cache at \(installURL.path)")
        } catch {
            UpdateLogStore.shared.append("Failed creating Sparkle installation cache: \(error)")
        }
    }
}
