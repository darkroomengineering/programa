import Cocoa
import Sparkle

/// SPUUserDriver that updates the view model for custom update UI.
class UpdateDriver: NSObject, SPUUserDriver {
    let viewModel: UpdateViewModel
    private let minimumCheckDuration: TimeInterval = UpdateTiming.minimumCheckDisplayDuration
    private let checkTimeout: TimeInterval
    private var lastCheckStart: Date?
    private var pendingCheckTransition: DispatchWorkItem?
    private var checkTimeoutWorkItem: DispatchWorkItem?
    private var lastFeedURLString: String?
    /// Monotonically increasing id for each update check started via `beginChecking`.
    /// Used to reconcile late Sparkle callbacks with the check they belong to.
    private var checkGeneration: UInt64 = 0
    /// The generation that most recently timed out, if the timed-out check has not
    /// yet been superseded by a new `beginChecking` call.
    private var timedOutGeneration: UInt64?

    init(viewModel: UpdateViewModel, hostBundle _: Bundle, checkTimeout: TimeInterval = UpdateTiming.checkTimeoutDuration) {
        self.viewModel = viewModel
        self.checkTimeout = checkTimeout
        super.init()
    }

    func show(_ request: SPUUpdatePermissionRequest,
              reply: @escaping @Sendable (SUUpdatePermissionResponse) -> Void) {
#if DEBUG
        let env = ProcessInfo.processInfo.environment
        if env["PROGRAMA_UI_TEST_TRIGGER_UPDATE_CHECK"] == "1" || env["PROGRAMA_UI_TEST_AUTO_ALLOW_PERMISSION"] == "1" {
            UpdateLogStore.shared.append("auto-allow update permission (ui test)")
            DispatchQueue.main.async {
                reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
            }
            return
        }
#endif
        // Never show Sparkle's permission UI. cmux always enables scheduled checks and keeps
        // automatic downloads disabled so installs remain user-driven.
        UpdateLogStore.shared.append("auto-allow update permission (no UI)")
        DispatchQueue.main.async {
            reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
        }
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        UpdateLogStore.shared.append("show user-initiated update check")
        beginChecking(cancel: cancellation)
    }

    func showUpdateFound(with appcastItem: SUAppcastItem,
                         state: SPUUserUpdateState,
                         reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void) {
        if isLateCallbackForTimedOutCheck() {
            UpdateLogStore.shared.append("ignored late update found after timeout")
            reply(.dismiss)
            return
        }
        UpdateLogStore.shared.append("show update found: \(appcastItem.displayVersionString)")
        setStateAfterMinimumCheckDelay(.updateAvailable(.init(appcastItem: appcastItem, reply: reply)))
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        // cmux uses Sparkle's UI for release notes links instead.
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {
        // Release notes are handled via link buttons.
    }

    func showUpdateNotFoundWithError(_ error: any Error,
                                     acknowledgement: @escaping () -> Void) {
        if isLateCallbackForTimedOutCheck() {
            UpdateLogStore.shared.append("ignored late update not found after timeout")
            acknowledgement()
            return
        }
        UpdateLogStore.shared.append("show update not found: \(formatErrorForLog(error))")
        setStateAfterMinimumCheckDelay(.notFound(.init(acknowledgement: acknowledgement)))
    }

    func showUpdaterError(_ error: any Error,
                          acknowledgement: @escaping () -> Void) {
        if isLateCallbackForTimedOutCheck() {
            UpdateLogStore.shared.append("ignored late updater error after timeout")
            acknowledgement()
            return
        }
        let details = formatErrorForLog(error)
        UpdateLogStore.shared.append("show updater error: \(details)")
        setState(.error(.init(
            error: error,
            retry: { [weak viewModel] in
                viewModel?.state = .idle
                DispatchQueue.main.async {
                    guard let delegate = NSApp.delegate as? AppDelegate else { return }
                    delegate.checkForUpdates(nil)
                }
            },
            dismiss: { [weak viewModel] in
                viewModel?.state = .idle
            },
            technicalDetails: details,
            feedURLString: lastFeedURLString
        )))
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        UpdateLogStore.shared.append("show download initiated")
        setState(.downloading(.init(
            cancel: cancellation,
            expectedLength: nil,
            progress: 0)))
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        UpdateLogStore.shared.append("download expected length: \(expectedContentLength)")
        guard case let .downloading(downloading) = viewModel.state else {
            return
        }

        setState(.downloading(.init(
            cancel: downloading.cancel,
            expectedLength: expectedContentLength,
            progress: 0)))
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        guard case let .downloading(downloading) = viewModel.state else {
            return
        }

        setState(.downloading(.init(
            cancel: downloading.cancel,
            expectedLength: downloading.expectedLength,
            progress: downloading.progress + length)), logTransition: false)
    }

    func showDownloadDidStartExtractingUpdate() {
        UpdateLogStore.shared.append("show extraction started")
        setState(.extracting(.init(progress: 0)))
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        setState(.extracting(.init(progress: progress)), logTransition: false)
    }

    func showReady(toInstallAndRelaunch reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void) {
        UpdateLogStore.shared.append("show ready to install")
        reply(.install)
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        UpdateLogStore.shared.append("show installing update")
        setState(.installing(.init(
            retryTerminatingApplication: retryTerminatingApplication,
            dismiss: { [weak viewModel] in
                viewModel?.state = .idle
            }
        )))
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        UpdateLogStore.shared.append("show update installed (relaunched=\(relaunched))")
        setState(.idle)
        acknowledgement()
    }

    func showUpdateInFocus() {
        // No-op; cmux never shows Sparkle dialogs.
    }

    func dismissUpdateInstallation() {
        UpdateLogStore.shared.append("dismiss update installation")
        if case .error = viewModel.state {
            UpdateLogStore.shared.append("dismiss update installation ignored (error visible)")
            return
        }
        if case .notFound = viewModel.state {
            UpdateLogStore.shared.append("dismiss update installation ignored (notFound visible)")
            return
        }
        if case .checking = viewModel.state {
            UpdateLogStore.shared.append("dismiss update installation ignored (checking)")
            return
        }
        setState(.idle)
    }

    private func beginChecking(cancel: @escaping () -> Void) {
        runOnMain { [weak self] in
            guard let self else { return }
            viewModel.overrideState = nil
            pendingCheckTransition?.cancel()
            pendingCheckTransition = nil
            checkTimeoutWorkItem?.cancel()
            checkTimeoutWorkItem = nil
            checkGeneration += 1
            timedOutGeneration = nil
            lastCheckStart = Date()
            applyState(.checking(.init(cancel: cancel)))
            scheduleCheckTimeout(generation: checkGeneration)
        }
    }

    /// True when the current callback belongs to a check that already timed out and
    /// has not been superseded by a newer check. Callers must fulfil the callback's
    /// obligations (reply/acknowledgement) without touching `viewModel.state`.
    private func isLateCallbackForTimedOutCheck() -> Bool {
        timedOutGeneration == checkGeneration
    }

    private func setStateAfterMinimumCheckDelay(_ newState: UpdateState) {
        runOnMain { [weak self] in
            guard let self else { return }
            pendingCheckTransition?.cancel()
            pendingCheckTransition = nil
            checkTimeoutWorkItem?.cancel()
            checkTimeoutWorkItem = nil

            guard let start = lastCheckStart else {
                lastCheckStart = nil
                applyState(newState)
                return
            }

            let elapsed = Date().timeIntervalSince(start)
            if elapsed >= minimumCheckDuration {
                lastCheckStart = nil
                applyState(newState)
                return
            }

            let delay = minimumCheckDuration - elapsed
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                guard case .checking = self.viewModel.state else { return }
                self.lastCheckStart = nil
                self.applyState(newState)
            }
            pendingCheckTransition = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
    }

    private func setState(_ newState: UpdateState, logTransition: Bool = true) {
        runOnMain { [weak self] in
            guard let self else { return }
            pendingCheckTransition?.cancel()
            pendingCheckTransition = nil
            checkTimeoutWorkItem?.cancel()
            checkTimeoutWorkItem = nil
            lastCheckStart = nil
            applyState(newState, logTransition: logTransition)
        }
    }

    private func scheduleCheckTimeout(generation: UInt64) {
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard generation == self.checkGeneration else { return }
            guard case let .checking(checking) = self.viewModel.state else { return }
            self.timedOutGeneration = generation
            let details = "Update check timed out after \(Int(self.checkTimeout)) seconds"
            UpdateLogStore.shared.append("update check timed out after \(self.checkTimeout)s")
            checking.cancel()
            self.setState(.error(.init(
                error: URLError(.timedOut),
                retry: { [weak self] in
                    self?.viewModel.state = .idle
                    DispatchQueue.main.async {
                        guard let delegate = NSApp.delegate as? AppDelegate else { return }
                        delegate.checkForUpdates(nil)
                    }
                },
                dismiss: { [weak self] in
                    self?.viewModel.state = .idle
                },
                technicalDetails: details,
                feedURLString: self.lastFeedURLString
            )))
        }
        checkTimeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + checkTimeout, execute: workItem)
    }

    private func applyState(_ newState: UpdateState, logTransition: Bool = true) {
        viewModel.state = newState
        if logTransition {
            UpdateLogStore.shared.append("state -> \(describe(newState))")
        }
    }

    func resolvedFeedURLString() -> String? {
        lastFeedURLString
    }

    func recordFeedURLString(_ feedURLString: String, usedFallback: Bool) {
        if lastFeedURLString == feedURLString {
            return
        }
        lastFeedURLString = feedURLString
        let suffix = usedFallback ? " (fallback)" : ""
        UpdateLogStore.shared.append("feed url resolved\(suffix): \(feedURLString)")
    }

    func formatErrorForLog(_ error: Error) -> String {
        let nsError = error as NSError
        var parts: [String] = ["\(nsError.domain)(\(nsError.code))"]
        if !nsError.localizedDescription.isEmpty {
            parts.append(nsError.localizedDescription)
        }
        if let url = nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL {
            parts.append("url=\(url.absoluteString)")
        } else if let urlString = nsError.userInfo[NSURLErrorFailingURLStringErrorKey] as? String {
            parts.append("url=\(urlString)")
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            let detail = "\(underlying.domain)(\(underlying.code)) \(underlying.localizedDescription)"
            parts.append("underlying=\(detail)")
        }
        if let feed = lastFeedURLString {
            parts.append("feed=\(feed)")
        }
        return parts.joined(separator: " | ")
    }

    private func describe(_ state: UpdateState) -> String {
        switch state {
        case .idle:
            return "idle"
        case .permissionRequest:
            return "permissionRequest"
        case .checking:
            return "checking"
        case .updateAvailable(let update):
            return "updateAvailable(\(update.appcastItem.displayVersionString))"
        case .notFound:
            return "notFound"
        case .error(let err):
            return "error(\(err.error.localizedDescription))"
        case .downloading(let download):
            if let expected = download.expectedLength, expected > 0 {
                let percent = Double(download.progress) / Double(expected) * 100
                return String(format: "downloading(%.0f%%)", percent)
            }
            return "downloading"
        case .extracting(let extracting):
            return String(format: "extracting(%.0f%%)", extracting.progress * 100)
        case .installing(let installing):
            return "installing(auto=\(installing.isAutoUpdate))"
        }
    }

    private func runOnMain(_ action: @escaping () -> Void) {
        if Thread.isMainThread {
            action()
        } else {
            DispatchQueue.main.async(execute: action)
        }
    }
}
