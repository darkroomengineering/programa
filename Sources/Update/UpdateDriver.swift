import Cocoa
import Sparkle

/// SPUUserDriver that updates the view model for custom update UI.
class UpdateDriver: NSObject, SPUUserDriver {
    let viewModel: UpdateViewModel
    private let minimumCheckDuration: TimeInterval = UpdateTiming.minimumCheckDisplayDuration
    private let checkTimeout: TimeInterval
    private var lastFeedURLString: String?
    private enum CheckPhase {
        case idle
        case checking(id: UUID, start: Date, timeout: DispatchWorkItem)
        case delayingResult(id: UUID, start: Date, work: DispatchWorkItem)
        case timedOut(id: UUID)

        var work: DispatchWorkItem? {
            switch self {
            case .checking(_, _, let timeout): return timeout
            case .delayingResult(_, _, let work): return work
            case .idle, .timedOut: return nil
            }
        }

        var id: UUID? {
            switch self {
            case .idle: return nil
            case .checking(let id, _, _), .delayingResult(let id, _, _), .timedOut(let id): return id
            }
        }
    }
    private let checkPhaseLock = NSLock()
    private var storedCheckPhase: CheckPhase = .idle
    private var checkPhase: CheckPhase {
        get {
            checkPhaseLock.lock()
            defer { checkPhaseLock.unlock() }
            return storedCheckPhase
        }
        set {
            checkPhaseLock.lock()
            defer { checkPhaseLock.unlock() }
            storedCheckPhase = newValue
        }
    }

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
        // Never show Sparkle's permission UI. programa always enables scheduled checks and keeps
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
        // Release notes are handled via link buttons.
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
        // No-op; programa never shows Sparkle dialogs.
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
            checkPhase.work?.cancel()
            let generation = UUID()
            let timeout = makeCheckTimeout(generation: generation)
            checkPhase = .checking(id: generation, start: Date(), timeout: timeout)
            applyState(.checking(.init(cancel: cancel)))
            DispatchQueue.main.asyncAfter(deadline: .now() + checkTimeout, execute: timeout)
        }
    }

    private func isLateCallbackForTimedOutCheck() -> Bool {
        if case .timedOut = checkPhase { return true }
        return false
    }

    private func setStateAfterMinimumCheckDelay(_ newState: UpdateState) {
        let expectedGeneration = checkPhase.id
        runOnMain { [weak self] in
            guard let self, checkPhase.id == expectedGeneration else { return }
            let generation: UUID
            let start: Date
            switch checkPhase {
            case .checking(let id, let date, _), .delayingResult(let id, let date, _):
                generation = id
                start = date
            case .timedOut:
                return
            case .idle:
                applyState(newState)
                return
            }
            checkPhase.work?.cancel()

            let elapsed = Date().timeIntervalSince(start)
            if elapsed >= minimumCheckDuration {
                checkPhase = .idle
                applyState(newState)
                return
            }

            let delay = minimumCheckDuration - elapsed
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                guard case .delayingResult(let current, _, _) = self.checkPhase,
                      current == generation,
                      case .checking = self.viewModel.state else { return }
                self.checkPhase = .idle
                self.applyState(newState)
            }
            checkPhase = .delayingResult(id: generation, start: start, work: workItem)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
    }

    private func setState(_ newState: UpdateState, logTransition: Bool = true) {
        runOnMain { [weak self] in
            guard let self else { return }
            checkPhase.work?.cancel()
            switch checkPhase {
            case .timedOut: break
            default: checkPhase = .idle
            }
            applyState(newState, logTransition: logTransition)
        }
    }

    private func makeCheckTimeout(generation: UUID) -> DispatchWorkItem {
        DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard case .checking(let current, _, _) = self.checkPhase,
                  generation == current else { return }
            guard case let .checking(checking) = self.viewModel.state else { return }
            self.checkPhase = .timedOut(id: generation)
            let details = "Update check timed out after \(Int(self.checkTimeout)) seconds"
            UpdateLogStore.shared.append("update check timed out after \(self.checkTimeout)s")
            checking.cancel()
            guard case .timedOut(let current) = self.checkPhase,
                  current == generation else { return }
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
